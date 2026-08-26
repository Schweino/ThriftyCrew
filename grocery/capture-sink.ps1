<#
    capture-sink.ps1 - local file drop for browser captures.

    WHAT THIS IS
    ------------
    A small HTTP listener bound to localhost. The capture page POSTs its finished CSV to it and
    this writes that CSV to a file on disk. Nothing leaves the machine: the listener binds to
    127.0.0.1 only, and the payload is the product rows we just read off a store's own search
    results - public catalogue data, on Brad's machine, for Brad's price board.

    WHY A LOCAL LISTENER AND NOT THE TOOL CHANNEL
    --------------------------------------------
    A full store sweep is 40-60 KB of CSV. The browser tool channel truncates a returned string
    at roughly 1 KB, so handing the CSV back through the tool result would take ~60 round trips
    per store and still risk a partial read. A localhost file drop moves it in one shot and lets
    us verify the byte and line counts on both sides before any builder touches it.

    WHY A FORM POST AND NOT fetch()
    -------------------------------
    Store pages set a Content-Security-Policy that restricts where the PAGE may send data.
    walmart.com sets connect-src 'self', so fetch() and sendBeacon() from the page are not
    available for this handoff. A plain HTML form POST is a different mechanism and is not
    covered by connect-src, so that is what the page uses. aldi.us sets no CSP at all, but
    fetch() hung there anyway, so every store uses the same form POST for consistency.

    The page submits inside setTimeout(..., 0) so the tool call returns instead of blocking on
    the navigation.

    USAGE
    -----
        # start it (run as a BACKGROUND command - a PowerShell Start-Job dies with its shell)
        powershell -NoProfile -ExecutionPolicy Bypass -File grocery\capture-sink.ps1 -OutDir <dir>

        # page side: POST to http://localhost:8791/<name>?chars=<n>  ->  writes <OutDir>\<name>.txt

    ALWAYS SEND ?chars=<n>, the length of the string the page is posting. The sink compares it to
    what it decoded and prints AGREE or MISMATCH. Without it the line reads UNVERIFIED, which is
    what the 2026-08-26 cp1252 corruption hid behind: the counts were printed and disagreed by 774
    characters, and nothing and no one compared them.

    The form uses enctype="text/plain", which produces a body of "<field>=<value>", so the
    leading "<field>=" is stripped before the file is written.

    Stop it with -Stop, or by killing the process; it also exits on its own after -MaxIdleMinutes
    with no request, so a forgotten sink does not sit listening forever.
#>
[CmdletBinding()]
param(
    [int]    $Port           = 8791,
    [string] $OutDir         = "$PSScriptRoot\out\captures\_sink",
    [int]    $MaxIdleMinutes = 30,
    [switch] $Stop
)

$ErrorActionPreference = 'Stop'

if ($Stop) {
    $found = $false
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*-File*capture-sink.ps1*' } |
        ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            Write-Output "stopped capture-sink pid $($_.ProcessId)"
            $found = $true
        }
    if (-not $found) { Write-Output 'no capture-sink process running' }
    return
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$listener = New-Object System.Net.HttpListener
# localhost only - never a wildcard prefix, so nothing off this machine can reach it.
$listener.Prefixes.Add("http://localhost:$Port/")

try {
    $listener.Start()
} catch {
    Write-Output "FAILED to bind localhost:$Port - $($_.Exception.Message)"
    exit 1
}

Write-Output "capture-sink LISTENING on localhost:$Port -> $OutDir (idle timeout ${MaxIdleMinutes}m)"

$lastActivity = Get-Date

try {
    while ($listener.IsListening) {

        # Async wait so an idle sink can time out instead of blocking forever on GetContext().
        $async = $listener.BeginGetContext($null, $null)
        while (-not $async.AsyncWaitHandle.WaitOne(5000)) {
            if ((Get-Date) -gt $lastActivity.AddMinutes($MaxIdleMinutes)) {
                Write-Output "idle ${MaxIdleMinutes}m with no request - shutting down"
                return
            }
        }
        $ctx = $listener.EndGetContext($async)
        $lastActivity = Get-Date

        # ONE BAD REQUEST MUST NOT TAKE THE LISTENER DOWN WITH IT. $ErrorActionPreference is 'Stop' at
        # script scope, so before this try/catch a single throw in here - a full disk, a locked file -
        # unwound straight past the loop to the outer finally and killed the sink mid-sweep. The capture
        # is the one part of a run that cannot be redone later, because the store's prices move on; the
        # builders always can. So log the failure, tell the page, and stay up for the next POST.
        try {
            $req = $ctx.Request

            # Path becomes the output filename. Sanitised so a request can only ever write inside
            # $OutDir - no traversal, no absolute paths, no alternate extensions. AbsolutePath excludes
            # the query string, so ?chars= below cannot reach the name.
            $name = $req.Url.AbsolutePath.Trim('/')
            if ([string]::IsNullOrWhiteSpace($name)) { $name = 'drop' }
            $name = ($name -replace '[^A-Za-z0-9._-]', '_')
            $name = $name.TrimStart('.')
            if ([string]::IsNullOrWhiteSpace($name)) { $name = 'drop' }

            # ALWAYS decode as UTF-8 - never $req.ContentEncoding.
            #
            # The form posts enctype="text/plain" with no charset parameter, so HttpListener has nothing
            # to go on and $req.ContentEncoding falls back to the machine's ANSI codepage (Windows-1252
            # here). The browser sent UTF-8 regardless - the capture page is a UTF-8 document - so that
            # fallback decodes every multi-byte character one byte at a time and bakes a mojibake layer
            # into the file we write. 2026-08-26: a Walmart capture arrived with every "34.0 <cent>/oz"
            # written as A-circumflex + cent, 278 times over. And it is not cheaply undone downstream:
            # the five bytes cp1252 leaves undefined (0x81 0x8D 0x8F 0x90 0x9D) come back as raw C1
            # characters, so a plain 1252 round-trip cannot even re-encode them without a per-character
            # fallback. Decode it right the first time.
            #
            # StreamReader's own BOM sniffing stays on: a UTF-8 BOM, if one ever led the body, is
            # consumed rather than landing in the file as a stray U+FEFF.
            $body = ''
            if ($req.HasEntityBody) {
                $sr = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
                $body = $sr.ReadToEnd()
                $sr.Close()
            }

            # enctype=text/plain sends "<field>=<value>"; drop the field name.
            $body = [regex]::Replace($body, '^[A-Za-z0-9_]+=', '')

            $path  = Join-Path $OutDir "$name.txt"
            $lines = ($body -split "`n").Count
            [System.IO.File]::WriteAllText($path, $body, [System.Text.UTF8Encoding]::new($false))

            # THE AGREEMENT CHECK, MADE MACHINE-READABLE.
            #
            # The counts below have always been printed - and on 2026-08-26 they were printed, they
            # DISAGREED, and the run carried on anyway: the page had counted 46,929 characters and the
            # sink wrote 47,703, the 774-character gap being the mojibake this listener was adding. The
            # line counts matched exactly (463 = 463) the whole time, so whichever side was compared, it
            # was compared with the instrument blind to the fault. Nothing in the repo ever read this
            # line; the check lived entirely in whoever was watching.
            #
            # So the page now states what it sent - POST /<name>?chars=<n> - and the sink rules on it
            # here. A mismatch STILL WRITES THE FILE: a capture cannot be retaken later at the price it
            # had, and a flagged file beats no file. It just can no longer pass for clean.
            $expected = $null
            if ($req.Url.Query) {
                $qm = [regex]::Match($req.Url.Query, '[?&]chars=(\d+)')
                if ($qm.Success) { $expected = [int]$qm.Groups[1].Value }
            }
            $verdict = 'chars=UNVERIFIED (page sent no ?chars= count)'
            if ($null -ne $expected) {
                if ($expected -eq $body.Length) {
                    $verdict = "chars=AGREE ($expected)"
                } else {
                    $verdict = "chars=MISMATCH page=$expected sink=$($body.Length) delta=$($body.Length - $expected)"
                }
            }

            # Print the counts so the caller can verify them against what the page reported
            # BEFORE any builder consumes the file.
            Write-Output ("RECV {0}  chars={1}  lines={2}  {3}  -> {4}" -f $name, $body.Length, $lines, $verdict, $path)
            if ($verdict -like 'chars=MISMATCH*') {
                Write-Output ("  !! {0} DID NOT ARRIVE INTACT - {1}. Do NOT build from it until you know why." -f $name, $verdict)
            }

            $resp = $ctx.Response
            $buf  = [System.Text.Encoding]::UTF8.GetBytes("ok $($body.Length) $lines $verdict")
            $resp.ContentLength64 = $buf.Length
            $resp.OutputStream.Write($buf, 0, $buf.Length)
            $resp.OutputStream.Close()
        } catch {
            Write-Output ("  !! REQUEST FAILED ({0}) - listener staying up: {1}" -f $ctx.Request.Url.AbsolutePath, $_.Exception.Message)
            try {
                $resp = $ctx.Response
                $resp.StatusCode = 500
                $buf = [System.Text.Encoding]::UTF8.GetBytes("error " + $_.Exception.Message)
                $resp.ContentLength64 = $buf.Length
                $resp.OutputStream.Write($buf, 0, $buf.Length)
                $resp.OutputStream.Close()
            } catch { }
        }
    }
} finally {
    if ($listener.IsListening) { $listener.Stop() }
    $listener.Close()
    Write-Output 'capture-sink stopped'
}
