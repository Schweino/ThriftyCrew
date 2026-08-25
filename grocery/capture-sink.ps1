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

        # page side: POST to http://localhost:8791/<name>  ->  writes <OutDir>\<name>.txt

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

        $req = $ctx.Request

        # Path becomes the output filename. Sanitised so a request can only ever write inside
        # $OutDir - no traversal, no absolute paths, no alternate extensions.
        $name = $req.Url.AbsolutePath.Trim('/')
        if ([string]::IsNullOrWhiteSpace($name)) { $name = 'drop' }
        $name = ($name -replace '[^A-Za-z0-9._-]', '_')
        $name = $name.TrimStart('.')
        if ([string]::IsNullOrWhiteSpace($name)) { $name = 'drop' }

        $body = ''
        if ($req.HasEntityBody) {
            $sr = New-Object System.IO.StreamReader($req.InputStream, $req.ContentEncoding)
            $body = $sr.ReadToEnd()
            $sr.Close()
        }

        # enctype=text/plain sends "<field>=<value>"; drop the field name.
        $body = [regex]::Replace($body, '^[A-Za-z0-9_]+=', '')

        $path  = Join-Path $OutDir "$name.txt"
        $lines = ($body -split "`n").Count
        [System.IO.File]::WriteAllText($path, $body, [System.Text.UTF8Encoding]::new($false))

        # Print the counts so the caller can verify them against what the page reported
        # BEFORE any builder consumes the file.
        Write-Output ("RECV {0}  chars={1}  lines={2}  -> {3}" -f $name, $body.Length, $lines, $path)

        $resp = $ctx.Response
        $buf  = [System.Text.Encoding]::UTF8.GetBytes("ok $($body.Length) $lines")
        $resp.ContentLength64 = $buf.Length
        $resp.OutputStream.Write($buf, 0, $buf.Length)
        $resp.OutputStream.Close()
    }
} finally {
    if ($listener.IsListening) { $listener.Stop() }
    $listener.Close()
    Write-Output 'capture-sink stopped'
}
