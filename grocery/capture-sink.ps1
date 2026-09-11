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

    ALWAYS SEND ?chars=<n>, and send it as a plain csv.length - the length of the string the page
    built, its \n line breaks counted once each. Do NOT try to predict the length that goes on the
    wire: the sink undoes the transport's envelope before it compares, so csv.length is the number
    that agrees. The sink then prints AGREE or MISMATCH. Without a count the line reads UNVERIFIED,
    which is what the 2026-08-26 cp1252 corruption hid behind: the counts were printed and disagreed
    by 774 characters, and nothing and no one compared them.

    THE ENVELOPE, AND WHY THIS SIDE UNDOES IT. The form uses enctype="text/plain", whose encoding
    algorithm does three things to the value on the way out: it prefixes "<field>=", it rewrites
    every lone LF as CRLF, and it appends one CRLF as the pair terminator. So the raw body is always
    (csv.length + line breaks + 2) characters, and a page that honestly reports csv.length is
    GUARANTEED to fail the agreement check on every healthy multi-line CSV. Measured 2026-08-27,
    both posts in the same run:

        walmart-quarantine-store3153  page 47974 (csv.length)   raw body 48390  delta 416
                                      = 414 line breaks rewritten + the 2-char terminator
        aldi-capture                  page 71053 (csv.replace(/\n/g,'\r\n').length + 2)
                                                                raw body 71053  AGREE

    Both payloads were intact - the Walmart file's cent signs arrived correctly - so the whole delta
    was envelope, not corruption. The fix belongs here and not on the page, for two reasons. The
    artefact is the transport's, and a capture page hand-written against a 45-second tool timeout
    should not have to model it: the obvious number has to be the right one, or the next page will
    send the obvious number anyway and be told its capture is broken. And a verdict that reads
    MISMATCH on every healthy capture is the fastest way to get the REAL one waved through, which is
    the exact failure this check was built to end.

    So the sink strips the envelope - field name, rewritten line breaks, terminator - before it
    compares and before it writes. What lands on disk is then character-for-character the string the
    page built, which is what makes "chars=AGREE" mean something. Nothing downstream notices the
    CRLFs going: the builders read these files with Get-Content -Encoding UTF8, which drops CR either
    way.

    Stop it with -Stop, or by killing the process; it also exits on its own after -MaxIdleMinutes
    with no request, so a forgotten sink does not sit listening forever.
#>
[CmdletBinding()]
param(
    [int]    $Port           = 8791,
    [string] $OutDir         = "$PSScriptRoot\out\captures\_sink",
    [int]    $MaxIdleMinutes = 30,
    [switch] $Stop,
    # NO SPACE after [switch], against the alignment of every line above it, because ops\run-gates.ps1
    # discovers self-tests by matching the literal '\[switch\]\$SelfTest' against the file's text. With
    # the space this switch works perfectly by hand and is INVISIBLE to the gate - the test would sit
    # here passing and never once be run, which is the same silence the artefact below hid in.
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# WHICH PROCESSES -Stop MAY KILL: a real listener, and nothing else (2026-09-11).
#
# The first cut killed every powershell.exe whose command line was like '*-File*capture-sink.ps1*'.
# A command line is not a process's identity, only the text it was started with, and two kinds of
# shell carry that text without being a sink. Measured by the grocery-browser-stores-refresh agent and
# reproduced the same morning with a dry-run copy, -Stop selected three pids:
#   the listener   "...\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File grocery\capture-sink.ps1 -OutDir ...
#   its wrapper    powershell.exe ... -Command "...; powershell ... -File grocery\capture-sink.ps1 -OutDir ...; ..."
#   the CALLER     powershell.exe ... -Command "...; powershell ... -File grocery\capture-sink.ps1 -Stop; ..."
# Killing the caller ended the agent's own command with exit 255 after its earlier steps had already
# run, so a clean stop read as a failed step.
#
# So a process is stopped only when all three hold:
#   1. It is not the stopping process or any ANCESTOR of it - whatever launched this -Stop mentions it.
#      capture-watchdog.ps1 learned the same thing naming a log holder ("NEVER ACCUSE OURSELVES").
#   2. powershell.exe was started in FILE mode on capture-sink.ps1. -File and -Command each end
#      powershell.exe's own parameters and hand the rest on, so whichever comes FIRST decides what the
#      process is. A -Command shell that merely quotes the -File line is a wrapper, not a sink; it
#      exits on its own when its listener dies.
#   3. The script was not given -Stop or -SelfTest (or an abbreviation, or -Stop:$true), read as
#      TOKENS after the script path. A -Stop process is a stopper and a -SelfTest process is
#      run-gates' child. Tokens, not a substring, so a quoted -OutDir containing "-Stop" still counts.
function Test-CaptureSinkListenerLine {
    param([string] $CommandLine)
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $false }
    $tokens = [System.Collections.Generic.List[string]]::new()
    foreach ($m in [regex]::Matches($CommandLine, '"[^"]*"|\S+')) { $tokens.Add($m.Value) }

    # Token 0 is the executable. The first -File or -Command after it is the mode.
    $scriptAt = -1
    for ($i = 1; $i -lt $tokens.Count; $i++) {
        if (-not $tokens[$i].StartsWith('-', [StringComparison]::Ordinal)) { continue }
        $name = $tokens[$i].Substring(1).Split(':')[0].ToLowerInvariant()
        if ($name.Length -eq 0) { continue }
        if ('file'.StartsWith($name, [StringComparison]::Ordinal)) { $scriptAt = $i + 1; break }
        if ('command'.StartsWith($name, [StringComparison]::Ordinal) -or
            'encodedcommand'.StartsWith($name, [StringComparison]::Ordinal) -or $name -eq 'ec') { return $false }
    }
    if ($scriptAt -lt 1 -or $scriptAt -ge $tokens.Count) { return $false }
    if ($tokens[$scriptAt].Trim('"') -notmatch '(?i)(^|[\\/])capture-sink\.ps1$') { return $false }

    for ($i = $scriptAt + 1; $i -lt $tokens.Count; $i++) {
        if (-not $tokens[$i].StartsWith('-', [StringComparison]::Ordinal)) { continue }
        $name = $tokens[$i].Substring(1).Split(':')[0].ToLowerInvariant()
        if ($name.Length -eq 0) { continue }
        if ('stop'.StartsWith($name, [StringComparison]::Ordinal) -or
            'selftest'.StartsWith($name, [StringComparison]::Ordinal)) { return $false }
    }
    return $true
}

# The stopping process and its ancestors, as a set of pids. PID REUSE: a parent that has exited can
# have its pid handed to a new process, which is not our ancestor - and may be a real listener. A
# "parent" created after its child is not the parent, so the walk stops there instead of sparing it.
function Get-ProcessAncestorIds {
    param([object[]] $Rows, [int] $ProcessId)
    $byPid = @{}
    foreach ($r in @($Rows)) { if ($null -ne $r) { $byPid[[int]$r.ProcessId] = $r } }
    $ids = @{ $ProcessId = $true }
    $cur = $byPid[$ProcessId]
    for ($h = 0; $h -lt 64 -and $null -ne $cur; $h++) {
        $parentId = [int]$cur.ParentProcessId
        if ($parentId -le 0 -or $ids.ContainsKey($parentId)) { break }
        $parent = $byPid[$parentId]
        if ($null -eq $parent) { break }
        if ($null -ne $parent.CreationDate -and $null -ne $cur.CreationDate -and $parent.CreationDate -gt $cur.CreationDate) { break }
        $ids[$parentId] = $true
        $cur = $parent
    }
    return $ids
}

# The rows that ARE listeners. Pure over its arguments, so the self-test drives it with no process
# touched. Emits rows to the pipeline (never a comma-returned array): assign, then filter out nulls.
function Select-CaptureSinkListener {
    param([object[]] $Rows, [int] $Self)
    $mine = Get-ProcessAncestorIds -Rows $Rows -ProcessId $Self
    foreach ($r in @($Rows)) {
        if ($null -eq $r) { continue }
        if ($mine.ContainsKey([int]$r.ProcessId)) { continue }
        if (-not [string]::Equals([string]$r.Name, 'powershell.exe', [StringComparison]::OrdinalIgnoreCase)) { continue }
        if (Test-CaptureSinkListenerLine -CommandLine ([string]$r.CommandLine)) { $r }
    }
}

if ($Stop) {
    # Every process, not only powershell.exe: the ancestor walk has to see claude.exe, bash.exe and the rest.
    $rows    = Get-CimInstance Win32_Process
    $targets = Select-CaptureSinkListener -Rows $rows -Self $PID
    $targets = @($targets | Where-Object { $null -ne $_ })
    $stuck   = 0
    foreach ($t in $targets) {
        try {
            Stop-Process -Id $t.ProcessId -Force -ErrorAction Stop
            Write-Output "stopped capture-sink pid $($t.ProcessId)"
        } catch {
            if (Get-Process -Id $t.ProcessId -ErrorAction SilentlyContinue) {
                Write-Output "could NOT stop capture-sink pid $($t.ProcessId), still running: $($_.Exception.Message)"
                $stuck++
            } else {
                Write-Output "capture-sink pid $($t.ProcessId) had already exited"
            }
        }
    }
    if (-not $targets.Count) { Write-Output 'no capture-sink process running' }
    if ($stuck) { exit 1 }
    return
}

# ---------------------------------------------------------------------------
# THE enctype="text/plain" ENVELOPE, UNDONE. The header carries the measurements; the short version
# is that the browser prefixes "<field>=", rewrites every lone LF to CRLF, and appends one CRLF as
# the pair terminator, so the raw body overstates the page's csv.length by (line breaks + 2).
#
# Order matters. The terminator has to come off while it is still distinguishable from a CRLF that
# belongs to the data: strip the prefix, strip ONE trailing CRLF, then rewrite what is left.
#
# Only when the prefix is actually there. No "<field>=" means this was not a text/plain form post -
# a fetch() from a store that sets no CSP, a curl probe - and such a body is returned exactly as it
# arrived rather than having its line endings quietly rewritten underneath it. Inventing a delta on
# this side would be the same bug wearing the other hat.
function ConvertFrom-TextPlainFormBody {
    param([string] $Raw)
    if ($Raw -notmatch '^[A-Za-z0-9_]+=') { return $Raw }
    $v = [regex]::Replace($Raw, '^[A-Za-z0-9_]+=', '')
    if ($v.EndsWith("`r`n")) { $v = $v.Substring(0, $v.Length - 2) }
    return $v.Replace("`r`n", "`n")
}

# The ruling itself, lifted out of the request loop so a test can hold it to its word.
function Get-AgreementVerdict {
    param($Expected, [int] $Actual)
    if ($null -eq $Expected) { return 'chars=UNVERIFIED (page sent no ?chars= count)' }
    $e = [int]$Expected
    if ($e -eq $Actual) { return "chars=AGREE ($e)" }
    return "chars=MISMATCH page=$e sink=$Actual delta=$($Actual - $e)"
}

# WHICH SIDE TO GO AND LOOK AT. A MISMATCH has two quite different causes and the SIGN separates
# them, because a decoding fault can only ever ADD characters: cp1252-decoding UTF-8 turns one
# character into two or three, and nothing about it drops any. So sink > page is a payload problem -
# the mojibake this listener was built to catch. sink < page can only be the page over-reporting,
# and there is one known way to do that: sending the old pre-2026-08-27 wire-length workaround
# (csv.replace(/\n/g,'\r\n').length + 2) now that the sink undoes the envelope itself. Saying so
# here costs one line and saves an operator from re-auditing an intact capture; the 2026-08-27 Aldi
# post is exactly this case.
function Get-MismatchAdvice {
    param([int] $Expected, [int] $Actual)
    if ($Actual -gt $Expected) {
        return 'The sink holds MORE characters than the page built, so suspect the PAYLOAD - a decoding fault adds characters. Do NOT build from it until you know why.'
    }
    return 'The sink holds FEWER characters than the page built, so suspect the COUNT, not the payload - a decoding fault cannot remove characters. Most likely the page sent the old wire-length workaround (csv.replace(/\n/g,''\r\n'').length + 2) instead of a plain csv.length; the sink already undoes that envelope.'
}

# ---------------------------------------------------------------------------
if ($SelfTest) {
    # A guard ships a frozen fixture of the bug that created it plus a clean twin, so the test can
    # FAIL as well as pass. The founding bug here is "MISMATCH on every healthy multi-line CSV",
    # measured 2026-08-27 on a live Walmart capture - so the must-fire fixture is that wire shape
    # replayed at its real size, and the twin is a genuinely corrupt body that must STILL be caught.
    # No temp files and no listener: this all runs before the port is bound.
    $fail = 0

    # The browser's encoding algorithm, in one line. Our CSVs are LF-only, so the spec's other half
    # - "a CR not followed by LF" - has nothing to do here.
    function New-TextPlainWire {
        param([string] $Field, [string] $Value)
        return ($Field + '=' + $Value.Replace("`n", "`r`n") + "`r`n")
    }

    # What the sink measured BEFORE this fix, and the point the 2026-08-27 deltas were read at: the
    # field name stripped, the rewritten line breaks and the terminator left in. Comparing anywhere
    # else pins the wrong number - the first draft of this test compared the whole wire and was off
    # by len('csv='), which the 416 caught.
    function Get-PreFixBody {
        param([string] $Wire)
        return [regex]::Replace($Wire, '^[A-Za-z0-9_]+=', '')
    }

    # ---- MUST-FIRE: the 2026-08-27 Walmart shape, to scale. 415 rows, no trailing newline, and
    # cent signs - the characters whose safe arrival proved the payload was intact at the moment the
    # verdict was calling it corrupt.
    $cent = [string][char]0x00A2
    $csv  = (1..415 | ForEach-Object { "q$_|item $_|`$1.74|34.0 $cent/oz|id$_|0" }) -join "`n"
    $wire = New-TextPlainWire -Field 'csv' -Value $csv

    $preFix   = Get-PreFixBody -Wire $wire
    $rawDelta = $preFix.Length - $csv.Length
    if ($rawDelta -ne 416) {
        Write-Output "FAIL  fixture is not the measured shape: raw delta $rawDelta, expected 416"; $fail++
    } else {
        Write-Output 'ok    fixture reproduces the measured 2026-08-27 delta of 416 (414 line breaks + terminator)'
    }

    # The raw body is what the sink used to compare, and this is the verdict it printed on a file
    # that was perfectly healthy. If this case ever stops firing, the fixture has drifted.
    if ((Get-AgreementVerdict -Expected $csv.Length -Actual $preFix.Length) -notlike 'chars=MISMATCH*') {
        Write-Output 'FAIL  the raw wire body no longer reproduces the false MISMATCH - fixture has drifted'; $fail++
    } else {
        Write-Output 'ok    raw wire body still reproduces the false MISMATCH this fix exists to end'
    }

    $got = ConvertFrom-TextPlainFormBody -Raw $wire
    if ($got -ne $csv) {
        Write-Output "FAIL  unwrapped body is not the string the page built ($($got.Length) vs $($csv.Length))"; $fail++
    } else {
        Write-Output 'ok    unwrapped body is character-for-character the string the page built'
    }
    if ($got.IndexOf($cent) -lt 0) {
        Write-Output 'FAIL  cent signs did not survive the unwrap'; $fail++
    } else {
        Write-Output 'ok    multi-byte characters survive the unwrap'
    }
    $v = Get-AgreementVerdict -Expected $csv.Length -Actual $got.Length
    if ($v -ne "chars=AGREE ($($csv.Length))") {
        Write-Output "FAIL  a healthy multi-line capture still does not AGREE: $v"; $fail++
    } else {
        Write-Output 'ok    a healthy multi-line capture reads AGREE'
    }
    $lineCount = ($got -split "`n").Count
    if ($lineCount -ne 415) {
        Write-Output "FAIL  line count is $lineCount, expected the 415 rows the page built"; $fail++
    } else {
        Write-Output 'ok    the printed line count is the row count, not row count + 1'
    }

    # ---- CLEAN TWIN: real corruption must STILL be caught. Undoing the envelope is only safe if it
    # cannot also swallow the mojibake this check was built for. cp1252-decoding one UTF-8 cent sign
    # yields two characters, once per row.
    $corrupt = $wire.Replace($cent, ([string][char]0x00C2 + $cent))
    $gotc    = ConvertFrom-TextPlainFormBody -Raw $corrupt
    $vc      = Get-AgreementVerdict -Expected $csv.Length -Actual $gotc.Length
    if ($vc -notlike 'chars=MISMATCH*') {
        Write-Output "FAIL  mojibake passed as clean after unwrapping - the fix swallowed the fault: $vc"; $fail++
    } elseif (($gotc.Length - $csv.Length) -ne 415) {
        Write-Output "FAIL  mojibake delta is $($gotc.Length - $csv.Length), expected 415 - one per row, envelope excluded"; $fail++
    } else {
        Write-Output 'ok    mojibake is still caught, and its delta is now the corruption alone'
    }

    # ---- A CSV that ends with its own newline. The terminator comes off; the data's own trailing LF
    # stays. The two are indistinguishable on the wire, which is why exactly one is removed.
    $csv2 = "a|1`nb|2`n"
    $got2 = ConvertFrom-TextPlainFormBody -Raw (New-TextPlainWire -Field 'csv' -Value $csv2)
    if ($got2 -ne $csv2) {
        Write-Output "FAIL  a CSV ending in its own newline came back as $($got2 | ConvertTo-Json)"; $fail++
    } else {
        Write-Output 'ok    a CSV ending in its own newline keeps it, and loses only the terminator'
    }

    # ---- A single-line CSV: no line breaks, so the terminator is the whole artefact.
    $csv3 = 'only|one|row'
    $w3   = New-TextPlainWire -Field 'csv' -Value $csv3
    $d3   = (Get-PreFixBody -Wire $w3).Length - $csv3.Length
    if ($d3 -ne 2) {
        Write-Output "FAIL  single-line raw delta is $d3, expected 2"; $fail++
    } elseif ((ConvertFrom-TextPlainFormBody -Raw $w3) -ne $csv3) {
        Write-Output 'FAIL  a single-line CSV did not survive the unwrap'; $fail++
    } else {
        Write-Output 'ok    a single-line CSV loses the terminator and nothing else'
    }

    # ---- Only the FIELD NAME is stripped. A capture whose data carries '=' must keep every one.
    $csv4 = "q=1|n=2`nx|y"
    $got4 = ConvertFrom-TextPlainFormBody -Raw (New-TextPlainWire -Field 'csv' -Value $csv4)
    if ($got4 -ne $csv4) {
        Write-Output "FAIL  '=' inside the data was eaten: got $($got4 | ConvertTo-Json)"; $fail++
    } else {
        Write-Output "ok    only the field name is stripped, never the data's own '='"
    }

    # ---- MUST-FIRE: a body that is NOT a text/plain form post comes back untouched.
    $raw5 = "a|1`r`nb|2`r`n"
    $got5 = ConvertFrom-TextPlainFormBody -Raw $raw5
    if ($got5 -ne $raw5) {
        Write-Output 'FAIL  a body with no <field>= prefix had its line endings rewritten'; $fail++
    } else {
        Write-Output 'ok    a non-form body is left exactly as it arrived'
    }

    # ---- And a page that sends no ?chars= at all must still say so out loud.
    if ((Get-AgreementVerdict -Expected $null -Actual 123) -notlike 'chars=UNVERIFIED*') {
        Write-Output 'FAIL  a missing ?chars= no longer reads UNVERIFIED'; $fail++
    } else {
        Write-Output 'ok    a missing ?chars= still reads UNVERIFIED'
    }

    # ---- The two directions of a MISMATCH point at different sides, and the sign is the only thing
    # that separates them. Getting this backwards sends an operator to re-audit an intact capture.
    if ((Get-MismatchAdvice -Expected 47000 -Actual 47311) -notmatch 'PAYLOAD') {
        Write-Output 'FAIL  sink > page no longer points at the payload'; $fail++
    } elseif ((Get-MismatchAdvice -Expected 71053 -Actual 70578) -notmatch 'COUNT') {
        Write-Output 'FAIL  sink < page no longer points at the count - that is the 2026-08-27 Aldi post'; $fail++
    } else {
        Write-Output 'ok    a MISMATCH names the side to look at, and the sign decides which'
    }

    # ---- THE ROOTED-PATH REFUSAL, frozen against the artifact that found it (2026-09-09).
    # MUST FIRE on the real collapsed string, which is the directory name that turned up at the repo
    # root; MUST NOT FIRE on the rooted paths this parameter legitimately receives, including the
    # default. Built by concatenation so this block cannot pass by matching its own source text.
    # THE COLLAPSE SIGNATURE, frozen against the real artifact - the directory name that turned up at
    # the repo root. Built by concatenation so this block cannot pass by matching its own source text.
    $collapseRe = '^[A-Za-z][A-Za-z0-9_]{15,}$'
    $mangled = 'C' + 'CodexThriftyCrewgroceryoutcaptures_sink'
    if ($mangled -match $collapseRe) {
        Write-Output 'ok    MUST FIRE   the real collapsed path is recognised and refused'
    } else {
        Write-Output 'FAIL  the collapsed path is no longer recognised - the refusal can never fire'; $fail++
    }
    # MUST NOT FIRE, and this half is the one the first cut of this guard got wrong: it refused every
    # unrooted path, which would have cost a capture the first morning the scheduled task passed the
    # relative directory its own SKILL.md documents.
    $legit = @("C:\Codex\ThriftyCrew\grocery\out\captures\_sink", $OutDir, '\\server\share\sink',
               'out\captures\_sink', 'out/captures/_sink', '..\out\_sink', 'sink', '_sink')
    $wrongly = @($legit | Where-Object { $_ -match $collapseRe })
    if ($wrongly.Count) {
        Write-Output ('FAIL  a legitimate path was read as collapsed: ' + ($wrongly -join ', ')); $fail++
    } else {
        Write-Output ('ok    MUST NOT FIRE  ' + $legit.Count + ' real path(s) pass - absolute, UNC, relative with separators, and a bare name')
    }
    # CLEAN TWIN: a relative path is anchored to THIS script, never to whatever the caller's CWD is.
    $anchored = Join-Path $PSScriptRoot 'out\captures\_sink'
    if ([System.IO.Path]::IsPathRooted($anchored) -and $anchored -like "*grocery*") {
        Write-Output 'ok    CLEAN TWIN  a relative -OutDir resolves under grocery\, not under the current directory'
    } else {
        Write-Output ('FAIL  a relative -OutDir no longer anchors to the script: ' + $anchored); $fail++
    }

    # ---- WHICH PROCESSES -Stop KILLS, frozen against the 2026-09-11 reproduction. Pids are the ones
    # observed; command lines are shortened to the parts the rule reads. The stopping process is pid
    # 5000, a child of the calling tool shell. Pure over rows: nothing here touches a real process.
    function Row([int]$ProcId, [int]$ParentId, [string]$Name, [string]$Cmd, $Created = $null) {
        [pscustomobject]@{ ProcessId = $ProcId; ParentProcessId = $ParentId; Name = $Name; CommandLine = $Cmd; CreationDate = $Created }
    }
    function PidsOf($Rows, [int]$Self) {
        $m = Select-CaptureSinkListener -Rows $Rows -Self $Self
        $m = @($m | Where-Object { $null -ne $_ })
        return (($m | ForEach-Object { [int]$_.ProcessId } | Sort-Object) -join ',')
    }
    # The INNER ESCAPED QUOTES in the two -Command lines are load-bearing. The live tool shell's line
    # carries \" pairs, which break a quoted -Command payload into bare tokens and expose its -File to
    # the parser. Without them the payload reads as one quoted token and the -Command rule is never
    # exercised - the first cut of this fixture had none, and a mutation that disabled the rule survived
    # every case but one.
    $claudeCmd   = 'C:\Users\Owner\AppData\Roaming\Claude\claude-code\claude.exe --output-format stream-json'
    $wrapperCmd  = 'C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "try { $PSDefaultParameterValues[''Out-File:Encoding''] = ''utf8'' } catch {}; \"starting sink\"; powershell -NoProfile -ExecutionPolicy Bypass -File grocery\capture-sink.ps1 -Port 8797 -OutDir C:\sink -MaxIdleMinutes 10; $_ec = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 1 }"'
    $listenerCmd = '"C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File grocery\capture-sink.ps1 -Port 8797 -OutDir C:\sink -MaxIdleMinutes 10'
    $callerCmd   = 'C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "git status; \"stopping sink\"; powershell -NoProfile -ExecutionPolicy Bypass -File capture-sink.ps1 -Stop; $_ec = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 1 }"'
    $stopperCmd  = '"C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File capture-sink.ps1 -Stop'
    $bashCmd     = 'C:\Program Files\Git\usr\bin\bash.exe -c "powershell -NoProfile -File grocery/capture-sink.ps1 -OutDir x"'
    # cmd.exe's /c is not a dash token, so its line parses as -File mode: only the NAME filter refuses it.
    $cmdCmd      = 'C:\WINDOWS\system32\cmd.exe /c powershell -NoProfile -File grocery\capture-sink.ps1 -OutDir x'
    $box = @(
        (Row 49648 26128 'claude.exe'     $claudeCmd),
        (Row 2484  49648 'powershell.exe' $wrapperCmd),
        (Row 43264 2484  'powershell.exe' $listenerCmd),
        (Row 10736 49648 'powershell.exe' $callerCmd),
        (Row 5000  10736 'powershell.exe' $stopperCmd),
        (Row 6000  49648 'bash.exe'       $bashCmd),
        (Row 6100  49648 'cmd.exe'        $cmdCmd)
    )

    # The founding bug, replayed: the pre-fix filter over these rows selects all three measured pids.
    # If this stops firing, the fixture has drifted away from what was measured.
    $oldHits = @($box | Where-Object { $_.Name -eq 'powershell.exe' -and $_.ProcessId -ne 5000 -and $_.CommandLine -like '*-File*capture-sink.ps1*' })
    $oldPids = (($oldHits | ForEach-Object { [int]$_.ProcessId } | Sort-Object) -join ',')
    if ($oldPids -ne '2484,10736,43264') {
        Write-Output "FAIL  fixture is not the measured shape: the pre-fix filter selects '$oldPids', expected '2484,10736,43264'"; $fail++
    } else {
        Write-Output 'ok    MUST FIRE   the pre-fix filter still selects listener, wrapper AND caller on this fixture'
    }

    # MUST FIRE: the listener, and only the listener.
    $got = PidsOf $box 5000
    if ($got -ne '43264') {
        Write-Output "FAIL  -Stop would kill pid(s) '$got', expected only the listener '43264'"; $fail++
    } else {
        Write-Output 'ok    MUST FIRE   only the listener is selected - not its wrapper, the caller, the stopper, bash or cmd'
    }

    # MUST NOT FIRE, line by line, so each rule is held on its own rather than hidden behind another.
    $notListeners = [ordered]@{
        'the caller, whose -Command text runs capture-sink.ps1 -Stop' = $callerCmd
        'the -Stop process itself'                                    = $stopperCmd
        'the wrapper, whose -Command text starts the listener'        = $wrapperCmd
        'a -SelfTest run'                                             = 'powershell.exe -NoProfile -File C:\Codex\ThriftyCrew\grocery\capture-sink.ps1 -SelfTest'
        '-Stop:$true'                                                 = 'powershell.exe -NoProfile -File grocery\capture-sink.ps1 -Stop:$true'
        'the abbreviation -sto'                                       = 'powershell.exe -NoProfile -File grocery\capture-sink.ps1 -sto'
        'an -EncodedCommand shell'                                    = 'powershell.exe -NoProfile -ec ZQBjAGgAbwA= -File grocery\capture-sink.ps1'
        'a different script whose name ends the same'                 = 'powershell.exe -NoProfile -File grocery\old-capture-sink.ps1 -OutDir x'
    }
    $wrongly = @($notListeners.Keys | Where-Object { Test-CaptureSinkListenerLine -CommandLine $notListeners[$_] })
    if ($wrongly.Count) {
        Write-Output ('FAIL  read as a listener: ' + ($wrongly -join '; ')); $fail++
    } else {
        Write-Output ('ok    MUST NOT FIRE  ' + $notListeners.Count + ' non-listener line(s) refused, including the shell that runs capture-sink.ps1 -Stop')
    }

    # MUST NOT FIRE: the ancestor rule on its own. A parent whose line reads exactly like a listener is
    # still spared when it launched the stopper; an unrelated listener beside it is still selected.
    $anc = @(
        (Row 7000 1    'powershell.exe' $listenerCmd),
        (Row 7001 7000 'powershell.exe' $stopperCmd),
        (Row 7002 1    'powershell.exe' $listenerCmd)
    )
    $gotAnc = PidsOf $anc 7001
    if ($gotAnc -ne '7002') {
        Write-Output "FAIL  ancestor rule: selected '$gotAnc', expected only the unrelated listener '7002'"; $fail++
    } else {
        Write-Output 'ok    MUST NOT FIRE  an ancestor of the stopper is spared even when its line reads as a listener'
    }

    # MUST NOT FIRE: a box with no listener selects nothing, and the empty result counts 0, not 1.
    $none = Select-CaptureSinkListener -Rows @($box[0], $box[1], $box[3], $box[4]) -Self 5000
    $none = @($none | Where-Object { $null -ne $_ })
    if ($none.Count -ne 0) {
        Write-Output "FAIL  a box with no listener selected $($none.Count) process(es)"; $fail++
    } else {
        Write-Output 'ok    MUST NOT FIRE  a box with no listener selects nothing'
    }

    # CLEAN TWIN: real listeners in the shapes this change was most likely to break on its way past.
    $stillListeners = [ordered]@{
        'the measured listener'               = $listenerCmd
        'a quoted absolute script path'       = '"C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -File "C:\Codex\ThriftyCrew\grocery\capture-sink.ps1" -OutDir C:\sink'
        # -Stop MID-VALUE, not at its end: at the end a quote-blind tokenizer reads '-Stop"', which no
        # longer looks like -Stop, and this case passed under exactly the mutation it exists to catch.
        'a quoted -OutDir containing -Stop'   = 'powershell.exe -NoProfile -File grocery\capture-sink.ps1 -OutDir "C:\my sinks\before -Stop after"'
        'an -OutDir named Stop'               = 'powershell.exe -File grocery/capture-sink.ps1 -OutDir C:\sinks\Stop'
        'no script arguments at all'          = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File grocery\capture-sink.ps1'
    }
    $missed = @($stillListeners.Keys | Where-Object { -not (Test-CaptureSinkListenerLine -CommandLine $stillListeners[$_]) })
    if ($missed.Count) {
        Write-Output ('FAIL  a real listener is no longer recognised: ' + ($missed -join '; ')); $fail++
    } else {
        Write-Output ('ok    CLEAN TWIN  ' + $stillListeners.Count + ' real listener line(s) still recognised, including an -OutDir that contains -Stop')
    }

    # CLEAN TWIN: PID reuse. The stopper's parent exited and a listener was later given its pid. A
    # "parent" created after its child is not the parent, so that listener is still stopped.
    $t0 = [datetime]'2026-09-11T09:00:00'
    $reuse = @(
        (Row 8000 1    'powershell.exe' $listenerCmd ($t0.AddMinutes(5))),
        (Row 8001 8000 'powershell.exe' $stopperCmd  $t0)
    )
    $gotReuse = PidsOf $reuse 8001
    if ($gotReuse -ne '8000') {
        Write-Output "FAIL  a listener holding a dead parent's reused pid was spared: selected '$gotReuse'"; $fail++
    } else {
        Write-Output 'ok    CLEAN TWIN  a listener that reused a dead ancestor''s pid is still stopped'
    }

    if ($fail) { Write-Output "$fail FAILED"; exit 1 }
    Write-Output 'capture-sink: all self-tests pass'
    exit 0
}

# AN UNROOTED -OutDir IS REFUSED, NOT CREATED (2026-09-09).
#
# THE ARTIFACT THAT FOUND THIS was an empty directory at the repo root literally named
# `CodexThriftyCrewgroceryoutcaptures` - a Windows path with its colon and every separator gone. It
# turned `ops\audit-stray-root-artifacts.ps1` red, and that audit's instruction is to find the WRITER
# before deleting anything, because the artifact is the only evidence of the bug that made it. This is
# the writer. `New-Item -Force` does not object to a path that lost its separators: it treats the whole
# mangled string as ONE directory name and creates it relative to the current directory, which for a
# scheduled run is the repo root. Nothing fails, nothing is logged, and the sink then writes captures
# into a directory nobody meant to exist.
#
# `[CORRECTED 2026-09-09, hours later, before it ever ran unattended. The first cut of this fix
# REFUSED every unrooted path, and that was the wrong trade.]`
#
# The scheduled task's own SKILL.md documents the call as `-OutDir <dir>`, and a relative `<dir>` is
# legitimate usage that has worked for months. Refusing it would have cost the 07:00 or 08:00 capture
# on a live paid board the first morning an agent filled that placeholder in the ordinary way.
# **Weigh the two failures rather than the two tidinesses**: the bug being fixed leaves an EMPTY
# directory that an audit catches the same day, and the over-strict guard loses a day of prices. A
# guard must not be more expensive than the defect.
#
# So this does two narrower things instead:
#   1. A RELATIVE path resolves against THIS SCRIPT'S directory, never the current one. That is the
#      actual defect - `New-Item -Force` resolved it against whatever the CWD happened to be, which
#      for a scheduled run is the repo root. Anchored here, a relative path lands where the caller
#      plainly meant and a collapsed one lands under grocery\ rather than at the top of the repo.
#   2. Only the COLLAPSE SIGNATURE is refused: a long run of path characters carrying no separator at
#      all, which is what `C:\Codex\ThriftyCrew\grocery\out\captures` becomes when a shell or a native
#      exe boundary eats its backslashes. A real relative path has separators; a real single-segment
#      name is short. That is a narrow, checkable shape rather than a proxy for one.
if ($OutDir -match '^[A-Za-z][A-Za-z0-9_]{15,}$') {
    Write-Output ("capture-sink: REFUSING -OutDir '" + $OutDir + "' - that is a path with its separators eaten.")
    Write-Output '  A Windows path crossing a shell or a native exe boundary arrives looking exactly'
    Write-Output '  like this, and New-Item -Force would create the whole mangled string as ONE'
    Write-Output '  directory. Check the layer that mangled it; do not pass this through.'
    exit 2
}
if (-not [System.IO.Path]::IsPathRooted($OutDir)) { $OutDir = Join-Path $PSScriptRoot $OutDir }
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

            # Undo the enctype="text/plain" envelope - field name, rewritten line breaks, terminator -
            # so what is counted and written below is the string the page actually built.
            $body = ConvertFrom-TextPlainFormBody -Raw $body

            $path  = Join-Path $OutDir "$name.txt"
            $lines = ($body -split "`n").Count
            [System.IO.File]::WriteAllText($path, $body, [System.Text.UTF8Encoding]::new($false))

            # THE AGREEMENT CHECK, MADE MACHINE-READABLE.
            #
            # The counts below have always been printed - and on 2026-08-26 they were printed, they
            # DISAGREED, and the run carried on anyway: the page had counted 46,929 characters and the
            # sink wrote 47,703. That 774-character gap was written down as 774 characters of mojibake.
            # It was not, and the difference is the whole point of the unwrap above: re-measured
            # 2026-08-27 off the file still on disk, it holds 462 CRLF pairs, so 461 rewritten line
            # breaks plus the 2-character terminator account for 463 of the gap, and the mojibake this
            # listener was adding was the other 311. Strip the envelope and the body is 47,240
            # characters against the page's 46,929 - the same 311, reached a second way. The line
            # counts matched exactly (463 = 463) the whole time, so whichever side was compared, it
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
            $verdict = Get-AgreementVerdict -Expected $expected -Actual $body.Length

            # Print the counts so the caller can verify them against what the page reported
            # BEFORE any builder consumes the file.
            Write-Output ("RECV {0}  chars={1}  lines={2}  {3}  -> {4}" -f $name, $body.Length, $lines, $verdict, $path)
            if ($verdict -like 'chars=MISMATCH*') {
                Write-Output ("  !! {0} DID NOT ARRIVE INTACT - {1}." -f $name, $verdict)
                Write-Output ("     {0}" -f (Get-MismatchAdvice -Expected $expected -Actual $body.Length))
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
