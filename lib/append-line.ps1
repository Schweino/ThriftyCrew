# append-line.ps1 - append one line to a file that several processes append to at once, and never lose it.
#
# WHY THIS EXISTS (2026-09-11). grocery\send-alert.ps1 spools an alert it could not put in the triage queue
# with `Add-Content -Path <spool> -Value <line> -Encoding UTF8`. The spool is the one write whose whole job is
# not to be lost, and it runs exactly when several senders are contending for the queue lock. Measured in a
# scratch harness: child processes appending ~220-char JSON lines, all released together by a go-file.
#   * 1 writer x 300, bare Add-Content:       300 of 300 lines landed.
#   * 2 writers x 100, bare Add-Content:       13 of 200 landed. Every other call threw "Stream was not readable."
#   * 4 writers x 300, bare Add-Content:        5 of 1,200 landed.
#   * 4 writers x 300, the open below:      1,200 of 1,200 landed, every one well-formed and distinct, no retry.
#
# THE RULE. Open with FileSystemRights.AppendData ONLY and FileShare.ReadWrite, and hand the whole line to ONE
# unbuffered Write. With append-only rights Windows places every write at the end of the file as one step, so
# concurrent appenders interleave whole lines and never overwrite or split each other, and ReadWrite sharing
# lets them all hold the file at once. Only the OPEN is retried, with a growing sleep, because a handle that
# shares less - a bare Add-Content, a reader that denies writers - still refuses it. The WRITE is never
# retried: a write that failed part-way could land twice. The bytes are UTF-8 with NO BOM, the text, CRLF.
#
# WHAT IT DOES NOT FIX. A reader can see a file that ends mid-line while an append is in flight, so a JSONL
# reader must skip a line that does not parse. Text containing line breaks is written verbatim, so one call is
# then several lines: compress JSON first.
#
# THE TUNING CONSTANTS: 40 attempts with a sleep of 25 ms x min(attempt, 8), about 7.3 s in all. Copied from
# lib\atomic-write.ps1, NOT the survivor of a sweep: the concurrent appenders above never needed a retry at all,
# so the budget only matters against a handle that shares less. What it does when the producer stops: nothing -
# it runs only when a writer calls it.
#
# SCOPE OF A CLEAN REPORT: the self-test drives real child processes and a real held handle on this machine's
# file system. A pass proves that concurrent appends through this function all land whole, and that a handle
# denying writers makes it refuse loudly without appending, on NTFS under this Windows build. It proves nothing
# about a network share, where append-only positioning is not guaranteed. NOR DOES IT PROVE THE SHARED OPEN IS
# NEEDED: mutation-probed on 2026-09-11, a bare Add-Content with no retry went red (7 of 600 lines landed), but an
# append-only open sharing Read only, WITH the retry, stayed green. So the concurrency case proves the retry; the
# ReadWrite share is why the harness above needed no retry at all, and no case asserts that.
#
# Dot-source:  . (Join-Path $repoRoot 'lib\append-line.ps1')
# Self-test:   powershell -File lib\append-line.ps1 -SelfTest
#
# NO param() BLOCK HERE, DELIBERATELY - dot-sourced under PS 5.1 a param() block runs in the CALLER's scope and
# would reset the caller's own -SelfTest. Same rule as lib\atomic-write.ps1.
$__alSelfTest = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-SelfTest')

$script:TcAppendAttempts = 40
$script:TcAppendBaseSleepMs = 25

function Add-TcLine {
  <# Appends $Text and a CRLF to $Path as ONE write, creating the file if it is missing. Returns the number of
     open attempts it took (1 when nothing was in the way). Throws when the budget runs out, and then NOTHING
     was appended. #>
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Text,
    [int]$MaxAttempts = $script:TcAppendAttempts,
    [int]$BaseSleepMs = $script:TcAppendBaseSleepMs
  )
  # PowerShell LOCATION semantics for a relative path, as in lib\atomic-write.ps1.
  $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
  $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($Text + "`r`n")
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $last = ''
  for ($a = 1; $a -le $MaxAttempts; $a++) {
    $fs = $null
    try {
      # bufferSize 1 is unbuffered: the line reaches the file as the single write below, never split by a buffer.
      $fs = New-Object IO.FileStream($full, [IO.FileMode]::Append, [Security.AccessControl.FileSystemRights]::AppendData, [IO.FileShare]::ReadWrite, 1, [IO.FileOptions]::None)
    } catch {
      $last = $_.Exception.Message
      if ($a -lt $MaxAttempts) { Start-Sleep -Milliseconds ($BaseSleepMs * [Math]::Min($a, 8)) }
      continue
    }
    try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }
    return $a
  }
  throw ("Add-TcLine: could not open {0} for append after {1} attempt(s) over {2} ms - another handle denied writers. NOTHING was appended. Last error: {3}" -f $full, $MaxAttempts, $sw.ElapsedMilliseconds, $last.Trim())
}

if ($__alSelfTest) {
  $ErrorActionPreference = 'Stop'
  $script:cases = 0; $script:failed = 0
  function Case([string]$Label, [string]$Name, [bool]$Ok, [string]$Got) {
    $script:cases++
    if ($Ok) { Write-Output ("  ok    {0}  {1}" -f $Label, $Name) }
    else { $script:failed++; Write-Output ("  X     {0}  {1}   got: {2}" -f $Label, $Name, $Got) }
  }
  # A handle opened the way a writer-denying reader opens a file (read, shared Read only), held from a SECOND
  # runspace until a release file appears. No clock decides the case: it holds until told.
  function Start-DenyHold([string]$Path) {
    $ready = $Path + '.held'; $release = $Path + '.release'
    $ps = [powershell]::Create()
    [void]$ps.AddScript({
      param($p, $ready, $release)
      $fs = New-Object IO.FileStream($p, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
      try {
        [IO.File]::WriteAllText($ready, 'x')
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while (-not [IO.File]::Exists($release) -and $sw.Elapsed.TotalSeconds -lt 120) { Start-Sleep -Milliseconds 10 }
      } finally { $fs.Dispose() }
    }).AddArgument($Path).AddArgument($ready).AddArgument($release)
    $h = $ps.BeginInvoke()
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not [IO.File]::Exists($ready) -and $sw.Elapsed.TotalSeconds -lt 30) { Start-Sleep -Milliseconds 5 }
    return [pscustomobject]@{ PS = $ps; Handle = $h; Ready = $ready; Release = $release; Opened = [IO.File]::Exists($ready) }
  }
  function Stop-DenyHold($Hold) {
    [IO.File]::WriteAllText($Hold.Release, 'x')
    try { $Hold.PS.EndInvoke($Hold.Handle) } catch { }
    $Hold.PS.Dispose()
    Remove-Item -LiteralPath $Hold.Ready, $Hold.Release -Force -ErrorAction SilentlyContinue
  }

  $dir = Join-Path ([IO.Path]::GetTempPath()) ('tc-al-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $dir -Force | Out-Null
  $procs = @()
  try {
    # ---- the bytes: a first append creates the file, UTF-8 with no BOM, each line CRLF-terminated ----
    $one = Join-Path $dir 'one.jsonl'
    $text = '{"subject":"caf' + [char]0x00E9 + '"}'
    $n1 = Add-TcLine -Path $one -Text $text
    $n2 = Add-TcLine -Path $one -Text 'second'
    $want = [Convert]::ToBase64String((New-Object Text.UTF8Encoding($false)).GetBytes($text + "`r`nsecond`r`n"))
    $got = [Convert]::ToBase64String([IO.File]::ReadAllBytes($one))
    Case 'CLEAN TWIN' 'a first append creates the file and a second follows it: UTF-8 with no BOM, each line CRLF-terminated' ($got -eq $want -and $n1 -eq 1 -and $n2 -eq 1) ("attempts=$n1,$n2 bytes=$got")

    # ---- the founding shape: several PROCESSES appending at once ----
    # Each child says it is ready and then waits on a go-file, so all of them are appending in the same stretch
    # however slowly they started. Every tenth line is 6,000 chars, past a default 4,096-byte buffer, so a line
    # that reached the file in two writes would show up torn.
    $W = 4; $N = 150
    $conc = Join-Path $dir 'concurrent.jsonl'
    $go = Join-Path $dir 'go'
    $childPs1 = Join-Path $dir 'child.ps1'
    $child = @'
param([string]$Lib, [string]$Target, [string]$Go, [string]$Tag, [int]$N)
. $Lib
[IO.File]::WriteAllText($Target + '.' + $Tag + '.ready', 'x')
$sw = [Diagnostics.Stopwatch]::StartNew()
while (-not [IO.File]::Exists($Go) -and $sw.Elapsed.TotalSeconds -lt 180) { Start-Sleep -Milliseconds 5 }
$fail = 0
for ($i = 0; $i -lt $N; $i++) {
  $pad = 'x' * $(if ($i % 10 -eq 0) { 6000 } else { 300 })
  try { [void](Add-TcLine -Path $Target -Text ('{"tag":"' + $Tag + '","i":' + $i + ',"pad":"' + $pad + '"}')) } catch { $fail++ }
}
[IO.File]::WriteAllText($Target + '.' + $Tag + '.done', [string]$fail)
'@
    [IO.File]::WriteAllText($childPs1, $child, (New-Object Text.UTF8Encoding($false)))
    $PS = (Get-Command powershell).Source
    foreach ($k in 1..$W) {
      $p = Start-Process -FilePath $PS -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $childPs1 + '"'),
        '-Lib', ('"' + $PSCommandPath + '"'), '-Target', ('"' + $conc + '"'), '-Go', ('"' + $go + '"'), '-Tag', ('c' + $k), '-N', $N) -PassThru -NoNewWindow
      $null = $p.Handle
      $procs += $p
    }
    # HANG GUARDS, not speed bars: nothing below is asserted on time.
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (@(Get-ChildItem -LiteralPath $dir -Filter 'concurrent.jsonl.c*.ready').Count -lt $W -and $sw.Elapsed.TotalSeconds -lt 120) { Start-Sleep -Milliseconds 20 }
    $readyN = @(Get-ChildItem -LiteralPath $dir -Filter 'concurrent.jsonl.c*.ready').Count
    [IO.File]::WriteAllText($go, 'go')
    foreach ($p in $procs) { [void]$p.WaitForExit(180000) }
    $childFails = 0; $doneN = 0
    foreach ($k in 1..$W) {
      $df = $conc + '.c' + $k + '.done'
      if (Test-Path -LiteralPath $df) { $doneN++; $childFails += [int]([IO.File]::ReadAllText($df).Trim()) }
    }
    $lines = @()
    if (Test-Path -LiteralPath $conc) { $lines = [IO.File]::ReadAllLines($conc) }
    $whole = 0
    foreach ($ln in $lines) { if ($ln -match '^\{"tag":"c\d","i":\d+,"pad":"x+"\}$') { $whole++ } }
    $distinct = @($lines | Sort-Object -Unique).Count
    $expect = $W * $N
    Case 'MUST FIRE' ("{0} processes appending {1} lines each at once land all {2}, whole and distinct (a bare Add-Content landed 5 of 1,200)" -f $W, $N, $expect) `
      ($readyN -eq $W -and $doneN -eq $W -and $childFails -eq 0 -and $lines.Count -eq $expect -and $whole -eq $expect -and $distinct -eq $expect) `
      ("ready=$readyN of $W done=$doneN of $W child_failures=$childFails lines=$($lines.Count) whole=$whole distinct=$distinct of $expect")

    # ---- a handle that denies writers: the refusal is loud and appends nothing ----
    $held = Join-Path $dir 'held.jsonl'
    [void](Add-TcLine -Path $held -Text 'before')
    $before = [Convert]::ToBase64String([IO.File]::ReadAllBytes($held))
    $hold = Start-DenyHold $held
    $err = ''
    try { [void](Add-TcLine -Path $held -Text 'during' -MaxAttempts 3 -BaseSleepMs 10) } catch { $err = $_.Exception.Message }
    $during = [Convert]::ToBase64String([IO.File]::ReadAllBytes($held))
    Stop-DenyHold $hold
    Case 'MUST FIRE' 'a handle that denies writers makes an exhausted budget THROW, naming the file and the attempts, and saying nothing was appended' ($hold.Opened -and $err -match 'after 3 attempt\(s\)' -and $err -match 'NOTHING was appended' -and $err.Contains($held)) ("opened=$($hold.Opened) error='$err'")
    Case 'MUST NOT FIRE' 'and the refused file still holds exactly its previous bytes' ($during -eq $before) 'bytes changed'
    $n3 = 0; $err3 = ''
    try { $n3 = Add-TcLine -Path $held -Text 'after' } catch { $err3 = $_.Exception.Message }
    Case 'CLEAN TWIN' 'once the handle lets go the next append lands after the earlier line' ($err3 -eq '' -and ([IO.File]::ReadAllLines($held) -join '|') -eq 'before|after') ("attempts=$n3 error='$err3' lines=" + ([IO.File]::ReadAllLines($held) -join '|'))
  } finally {
    foreach ($p in $procs) { try { if (-not $p.HasExited) { $p.Kill() } } catch { } }
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
  }
  if ($script:failed) {
    Write-Output ("append-line SELF-TEST FAIL ({0} of {1})" -f $script:failed, $script:cases)
    Write-Output ("APPEND-LINE-COMPLETE cases={0} failed={1}" -f $script:cases, $script:failed)
    exit 1
  }
  Write-Output ("append-line SELF-TEST PASS ({0} cases)" -f $script:cases)
  Write-Output ("APPEND-LINE-COMPLETE cases={0} failed=0" -f $script:cases)
  exit 0
}
