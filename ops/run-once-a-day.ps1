<#
  run-once-a-day.ps1 - run ONE child command at most once per calendar day, stamping it when the child EXITS.

  WHY THIS EXISTS (2026-09-10, queue 2026-09-10-2b79d3). Every TC scheduled task was an Interactive
  one-occurrence daily trigger, so a Windows Update restart before a sign-in made that day's occurrence
  unrunnable: StartWhenAvailable does not re-queue an occurrence refused for want of a session. The repair is
  hourly catch-up occurrences inside a per-task window, and that is only safe for a task whose repeat is a
  no-op. This wrapper supplies the no-op for the tasks whose script this repo cannot or should not edit, or
  whose repeat is provably NOT a no-op:
    TC Brain Digest 0645          ops\brain-digest.ps1 belongs to the Brain v3 session, and it mails through
                                  send-alert -Force, so a second fire is a second mail and a second queue count.
    TC Recall Sleep 0435          recall-sleep.py lives in ~/.claude/skills, outside this repo.
    TC Grocery Capture Watchdog   capture-watchdog.ps1 runs Family Fare shard window 3 of 3 on EVERY invocation
                                  (capture-watchdog.ps1:1257-1271; measured 2026-09-10, the 10:30 run moved the
                                  Family Fare cursor 219 -> 227 at 10:33:59), so an hourly repeat would buy
                                  Family Fare terms every hour against a deliberate daily budget.
    TC Daemon Battery 0230        ops\run-daemon-battery.ps1 runs the daemon's 548-case battery, 388-677 s of wall
                                  on 2026-09-11, on a box every session shares; an hourly repeat would run it up to
                                  nine times a day. Born wrapped on 2026-09-11, never unwrapped.

  THE ARGUMENT SHAPE IS -Exe AND -ArgLine, NOT '-- <exe> <args...>'. Measured 2026-09-10 on this estate's
  PowerShell 5.1: `powershell.exe -File <script> -Key x -- exe --flag` fails parameter binding before the
  script runs ("the parameter name '' is ambiguous"), so a '--' form cannot appear in a task action at all.
  -ArgLine carries the child's argument string VERBATIM - exactly what the task's Arguments field said before
  it was wrapped - and a quoted value that begins with a dash binds correctly. A double quote INSIDE it is
  written \" in the task definition. -SelfTest proves that form end to end, and proves that every committed
  definition naming this script hands its child exactly the command the task ran before it was wrapped.

  WHAT "RAN" MEANS: <StampDir>\<Key>-<yyyy-MM-dd>.stamp exists. It is written when the child EXITS, whatever its
  exit code, so a child that failed does not re-run every hour; a wrapper KILLED before the child exits writes
  no stamp, and neither does a child that could not be started, so the next occurrence retries both. The
  stamps live in ops\out\logs\run-once\, which .gitignore already ignores: they are local run state, not
  evidence, and a tracked home would leave a new untracked file on the shared tree every day for every key.

  A NO-OP REPORTS THE DAY'S EXIT CODE, NOT 0 (measured 2026-09-10). grocery\health-heartbeat.ps1 reads each
  watched task's LastTaskResult and pages a nonzero one (:164-201), and among this repo's scripts it is the only
  reader of these three tasks' exit codes. A no-op exiting 0 an hour after a failed 06:45 digest would overwrite
  the failure before the 10:30 heartbeat read it, on every day it failed: the repair would blind the detector.
  So a no-op exits with the code today's stamp recorded, and a stamp that records none exits 2. The cost,
  stated: a no-op also moves LastRunTime, so on a day the child exited nonzero AFTER writing its 'proves'
  output, Test-ProofLanded reads that output as older than the run and the heartbeat pages TASK FAILED where it
  used to say the work landed. That over-reports a real nonzero exit; it never hides one. capture-run.ps1 is
  not wrapped and its own skip exits 0, because its exit code is also written to out\logs\capture-run-status.json
  and capture-watchdog reads it there (section 2b), where a skip never writes.

  Task action shape (ops\scheduled-tasks\tc-brain-digest-0645.xml):
    powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\Codex\ThriftyCrew\ops\run-once-a-day.ps1"
        -Key brain-digest -Exe "C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe"
        -ArgLine "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"C:\Codex\ThriftyCrew\ops\brain-digest.ps1\" -Alert -Quiet"
  Self-test:
    powershell -File ops\run-once-a-day.ps1 -SelfTest

  EXIT: the child's own exit code when it ran; the exit code today's stamp recorded when it had already run (a
        no-op repetition); 2 when the arguments are unusable, the child could not be started, or today's stamp
        records no exit code. -SelfTest: 0 pass, 1 fail.
#>
[CmdletBinding(PositionalBinding = $false)]
param(
  [string]$Key = '',
  [string]$Exe = '',
  [string]$ArgLine = '',
  [string]$StampDir = '',
  [string]$Today = '',
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\ops' }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'grocery\run-log-lib.ps1')   # Start-RunLog / Stop-RunLog: a hidden task leaves a transcript (ops\audit-run-log-claims.ps1 reads for this)

function Test-RunOnceKey {
  <# A key becomes part of a file name, so anything that could climb out of the stamp directory is refused. #>
  param([string]$Key)
  return ([string]$Key -match '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')
}

function Get-RunOnceStampPath {
  param([string]$Dir, [string]$Key, [string]$Day)
  return (Join-Path $Dir ($Key + '-' + $Day + '.stamp'))
}

function Get-StampedExitCode {
  <# The exit code a stamp recorded ('<time> rc=<n> exe=<path>'), or $null when it records none. #>
  param([string]$Text)
  $m = [regex]::Match([string]$Text, '(?:^|\s)rc=(-?\d+)(?=\s|$)')
  if (-not $m.Success) { return $null }
  $n = 0
  if (-not [int]::TryParse($m.Groups[1].Value, [ref]$n)) { return $null }
  return $n
}

function Invoke-RunOnce {
  <# The decision and the run. Returns [pscustomobject]@{ ran; rc; stamp; message }. Separated from the
     script body so -SelfTest drives the code a task runs rather than a paraphrase of it. #>
  param([string]$Key, [string]$Exe, [string]$ArgLine, [string]$StampDir, [string]$Day)
  if (-not (Test-RunOnceKey $Key)) {
    return [pscustomobject]@{ ran = $false; rc = 2; stamp = ''; message = ("run-once-a-day: REFUSED - '" + $Key + "' is not a usable key (letters, digits, dot, dash or underscore, at most 64)") }
  }
  if (-not $Exe) {
    return [pscustomobject]@{ ran = $false; rc = 2; stamp = ''; message = ('run-once-a-day: REFUSED - ' + $Key + ' names no -Exe, so there is nothing to run') }
  }
  $stamp = Get-RunOnceStampPath -Dir $StampDir -Key $Key -Day $Day
  if (Test-Path -LiteralPath $stamp) {
    $was = ''
    try { $was = ([IO.File]::ReadAllText($stamp)).Trim() } catch { $was = '' }
    $prevRc = Get-StampedExitCode $was
    if ($null -eq $prevRc) {
      return [pscustomobject]@{ ran = $false; rc = 2; stamp = $stamp; message = ('run-once-a-day: ' + $Key + ' has a stamp for today that records no exit code (' + $(if ($was) { $was } else { 'empty or unreadable' }) + '); not re-running it, and reporting rc 2 because what today''s run did is unknown') }
    }
    return [pscustomobject]@{ ran = $false; rc = $prevRc; stamp = $stamp; message = ('run-once-a-day: ' + $Key + ' already ran today (' + $was + '); this repetition is a no-op and reports that run''s exit code, ' + $prevRc) }
  }
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $Exe
  $psi.Arguments = $ArgLine
  $psi.UseShellExecute = $false
  $p = $null
  try { $p = [System.Diagnostics.Process]::Start($psi) }
  catch {
    return [pscustomobject]@{ ran = $false; rc = 2; stamp = ''; message = ('run-once-a-day: ' + $Key + " could NOT start '" + $Exe + "' (" + $_.Exception.Message + ') - no stamp written, so the next occurrence retries') }
  }
  $p.WaitForExit()
  $rc = $p.ExitCode
  $p.Dispose()
  try {
    if (-not (Test-Path -LiteralPath $StampDir)) { New-Item -ItemType Directory -Path $StampDir -Force | Out-Null }
    [IO.File]::WriteAllText($stamp, ((Get-Date).ToString('s') + ' rc=' + $rc + ' exe=' + $Exe), (New-Object Text.UTF8Encoding($false)))
  } catch {
    return [pscustomobject]@{ ran = $true; rc = $rc; stamp = ''; message = ('run-once-a-day: ' + $Key + ' ran (child exit ' + $rc + ') but the stamp could NOT be written (' + $_.Exception.Message + ') - the next occurrence will run it again') }
  }
  return [pscustomobject]@{ ran = $true; rc = $rc; stamp = $stamp; message = ('run-once-a-day: ' + $Key + ' ran, child exit ' + $rc + '; stamped ' + $stamp) }
}

if ($SelfTest) {
  $script:stFail = 0; $script:stRan = 0
  function T([string]$n, [bool]$ok, $got = '') {
    $script:stRan++
    if ($ok) { Write-Output ('ok    ' + $n) } else { Write-Output ('FAIL  ' + $n + '   got: ' + $got); $script:stFail++ }
  }
  function Invoke-Hidden([string]$FileName, [string]$Arguments) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FileName; $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
    $pp = [System.Diagnostics.Process]::Start($psi)
    $tOut = $pp.StandardOutput.ReadToEndAsync(); $tErr = $pp.StandardError.ReadToEndAsync()
    $tOut.Wait(); $tErr.Wait(); $pp.WaitForExit()
    $res = [pscustomobject]@{ rc = $pp.ExitCode; out = [string]$tOut.Result; err = [string]$tErr.Result }
    $pp.Dispose()
    return $res
  }
  $tmp = Join-Path $env:TEMP ('run-once-selftest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $tmp -Force | Out-Null
  $cmdExe = Join-Path $env:SystemRoot 'System32\cmd.exe'
  $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $utf8 = New-Object Text.UTF8Encoding($false)
  try {
    T 'MUST FIRE  a key that could climb out of the stamp directory is refused' (-not (Test-RunOnceKey '..\brain-digest')) 'accepted'
    T 'CLEAN TWIN  a task key is accepted' (Test-RunOnceKey 'capture-watchdog') 'refused'
    T 'CLEAN TWIN  the stamp is one file per key per day' ((Get-RunOnceStampPath -Dir 'D' -Key 'k' -Day '2026-09-10') -eq (Join-Path 'D' 'k-2026-09-10.stamp')) (Get-RunOnceStampPath -Dir 'D' -Key 'k' -Day '2026-09-10')

    T 'CLEAN TWIN  a stamp''s exit code reads back, 0 included' ((Get-StampedExitCode '2026-09-10T06:45:15 rc=0 exe=C:\x.exe') -eq 0) (Get-StampedExitCode '2026-09-10T06:45:15 rc=0 exe=C:\x.exe')
    T 'CLEAN TWIN  a crash code (a negative NTSTATUS) reads back' ((Get-StampedExitCode '2026-09-10T06:45:15 rc=-1073741510 exe=C:\x.exe') -eq -1073741510) (Get-StampedExitCode '2026-09-10T06:45:15 rc=-1073741510 exe=C:\x.exe')
    T 'CLEAN TWIN  the form seeded at install on 2026-09-10 reads back' ((Get-StampedExitCode '2026-09-10T10:30:01 rc=1 exe=seeded at install from Task Scheduler LastRunTime') -eq 1) (Get-StampedExitCode '2026-09-10T10:30:01 rc=1 exe=seeded at install from Task Scheduler LastRunTime')
    T 'MUST FIRE  a stamp that records no exit code is recognised as recording none' ($null -eq (Get-StampedExitCode 'stamped by hand')) (Get-StampedExitCode 'stamped by hand')

    $r1 = Invoke-RunOnce -Key 'st' -Exe $cmdExe -ArgLine '/c exit 1' -StampDir $tmp -Day '2026-09-10'
    T 'MUST FIRE  a child that exits 1 still writes the stamp, and its exit code is the wrapper''s' ($r1.ran -and ($r1.rc -eq 1) -and (Test-Path -LiteralPath (Get-RunOnceStampPath -Dir $tmp -Key 'st' -Day '2026-09-10'))) $r1.message
    $r2 = Invoke-RunOnce -Key 'st' -Exe $cmdExe -ArgLine '/c exit 5' -StampDir $tmp -Day '2026-09-10'
    T 'MUST FIRE  with today''s stamp present the child is NOT started, and the no-op reports the day''s exit 1, not 0 (a 0 would hide the failed run from health-heartbeat)' ((-not $r2.ran) -and ($r2.rc -eq 1) -and ($r2.message -match 'already ran today')) ('rc=' + $r2.rc + ' ' + $r2.message)
    $r2b = Invoke-RunOnce -Key 'okday' -Exe $cmdExe -ArgLine '/c exit 0' -StampDir $tmp -Day '2026-09-10'
    $r2c = Invoke-RunOnce -Key 'okday' -Exe $cmdExe -ArgLine '/c exit 5' -StampDir $tmp -Day '2026-09-10'
    T 'CLEAN TWIN  a successful day''s no-op reports 0' ($r2b.ran -and ($r2b.rc -eq 0) -and (-not $r2c.ran) -and ($r2c.rc -eq 0)) ('first rc=' + $r2b.rc + '; second ran=' + $r2c.ran + ' rc=' + $r2c.rc)
    [IO.File]::WriteAllText((Get-RunOnceStampPath -Dir $tmp -Key 'handmade' -Day '2026-09-10'), 'stamped by hand', $utf8)
    $r2d = Invoke-RunOnce -Key 'handmade' -Exe $cmdExe -ArgLine '/c exit 5' -StampDir $tmp -Day '2026-09-10'
    T 'MUST FIRE  a stamp that records no exit code is not re-run and reports rc 2 (unknown is not success)' ((-not $r2d.ran) -and ($r2d.rc -eq 2)) ('ran=' + $r2d.ran + ' rc=' + $r2d.rc + ' ' + $r2d.message)
    $r3 = Invoke-RunOnce -Key 'st' -Exe $cmdExe -ArgLine '/c exit 7' -StampDir $tmp -Day '2026-09-11'
    T 'CLEAN TWIN  yesterday''s stamp does not block today: the child runs and its exit 7 comes back' ($r3.ran -and ($r3.rc -eq 7)) $r3.message
    $r4 = Invoke-RunOnce -Key 'nostart' -Exe (Join-Path $tmp 'no-such-program.exe') -ArgLine '' -StampDir $tmp -Day '2026-09-10'
    T 'MUST FIRE  a child that could not be started writes NO stamp, so the next occurrence retries' ((-not $r4.ran) -and ($r4.rc -eq 2) -and -not (Test-Path -LiteralPath (Get-RunOnceStampPath -Dir $tmp -Key 'nostart' -Day '2026-09-10'))) $r4.message

    # END TO END IN THE TASK ACTION'S OWN SHAPE: a fresh powershell.exe -File, -ArgLine quoted, and a child
    # argument string that BEGINS WITH A DASH. This is the half a direct call cannot prove - the '--' form this
    # replaced passed every in-process test and failed binding the moment it went through powershell -File.
    $e2eArgs = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Key e2e -StampDir "' + $tmp + '" -Today 2026-09-10 -Exe "' + $psExe + '" -ArgLine "-NoProfile -Command exit 4"'
    $runs = @()
    foreach ($i in 1..2) { $runs += Invoke-Hidden $psExe $e2eArgs }
    T 'MUST FIRE  the task-action shape runs a dash-leading child through powershell -File and returns its exit code' (($runs[0].rc -eq 4) -and (Test-Path -LiteralPath (Get-RunOnceStampPath -Dir $tmp -Key 'e2e' -Day '2026-09-10'))) ('rc=' + $runs[0].rc + ' err=' + $runs[0].err)
    T 'MUST FIRE  and the second occurrence of that same action the same day is a no-op reporting the day''s exit 4' (($runs[1].rc -eq 4) -and ($runs[1].out -match 'already ran today')) ('rc=' + $runs[1].rc + ' out=' + $runs[1].out)

    # NESTED QUOTES, the form every wrapped definition uses: the child's own -File path sits inside -ArgLine as
    # \"...\", and here it also carries a space, the case a naive split gets wrong.
    $childDir = Join-Path $tmp 'child dir'
    New-Item -ItemType Directory -Path $childDir -Force | Out-Null
    $childPs1 = Join-Path $childDir 'child.ps1'
    [IO.File]::WriteAllText($childPs1, ('param([int]$Code = 0)' + "`r`n" + 'exit $Code' + "`r`n"), $utf8)
    $nestedArgs = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Key nested -StampDir "' + $tmp + '" -Today 2026-09-10 -Exe "' + $psExe + '" -ArgLine "-NoProfile -ExecutionPolicy Bypass -File \"' + $childPs1 + '\" -Code 6"'
    $rn = Invoke-Hidden $psExe $nestedArgs
    T 'MUST FIRE  a child -File path written \"...\" inside -ArgLine, with a space in it, reaches the child whole: its exit 6 comes back' (($rn.rc -eq 6) -and (Test-Path -LiteralPath (Get-RunOnceStampPath -Dir $tmp -Key 'nested' -Day '2026-09-10'))) ('rc=' + $rn.rc + ' out=' + $rn.out + ' err=' + $rn.err)

    # EACH COMMITTED DEFINITION HANDS ITS CHILD EXACTLY WHAT THE TASK RAN BEFORE IT WAS WRAPPED. The Arguments of
    # every ops\scheduled-tasks\*.xml that names this script go through a real powershell.exe -File with this
    # script's path swapped for an echo of the same param block, so the binding is Windows' and PowerShell's own
    # rather than a regex's. $preWrap is FROZEN from those three definitions as committed before they were
    # wrapped (a3952ca0f). A new wrapped task fails the resolved-set case until it adds its own frozen row.
    # daemon-battery was BORN wrapped (2026-09-11), so it has no pre-wrap command: its row is the command its
    # definition was committed to hand the child, frozen here so a later edit to the XML must edit this too.
    # daily-ratchets likewise, born wrapped at 88c7a835c (2026-09-12). Its row was NOT added with the task, and
    # main was red for every checkout on the box until it was - both this case and the resolved-set case below
    # failed, the latter reporting found=5 missing= against a frozen 4, which reads as a passing set until you
    # notice the count is what is compared. That is the failure this comment exists to prevent a third time,
    # and the resolved-set case's own got line now states both counts and names the unfrozen key, so the next
    # one is legible from the gate output without reading this file.
    $preWrap = @{
      'daemon-battery'   = @{ Exe = 'C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe'; ArgLine = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\Codex\ThriftyCrew\ops\run-daemon-battery.ps1"' }
      'daily-ratchets'   = @{ Exe = 'C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe'; ArgLine = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\Codex\ThriftyCrew\ops\run-daily-ratchets.ps1"' }
      'brain-digest'     = @{ Exe = 'C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe'; ArgLine = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\Codex\ThriftyCrew\ops\brain-digest.ps1" -Alert -Quiet' }
      'recall-sleep'     = @{ Exe = 'C:\Codex\Python312\python.exe'; ArgLine = '"C:\Users\Owner\.claude\skills\recall-sleep.py" --cwd "C:\Codex\ThriftyCrew" --commit --push' }
      'capture-watchdog' = @{ Exe = 'C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe'; ArgLine = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\Codex\ThriftyCrew\grocery\capture-watchdog.ps1" -Alert' }
    }
    $echoPs1 = Join-Path $tmp 'echo-args.ps1'
    [IO.File]::WriteAllText($echoPs1, ('[CmdletBinding(PositionalBinding = $false)]' + "`r`n" +
      'param([string]$Key = '''', [string]$Exe = '''', [string]$ArgLine = '''', [string]$StampDir = '''', [string]$Today = '''')' + "`r`n" +
      '[Console]::Out.Write((ConvertTo-Json -Compress -InputObject ([ordered]@{ Key = $Key; Exe = $Exe; ArgLine = $ArgLine })))' + "`r`n"), $utf8)
    function Get-EchoedBinding([string]$Arguments) {
      $swapped = [regex]::Replace($Arguments, '-File\s+"[^"]*\\run-once-a-day\.ps1"', ('-File "' + $echoPs1.Replace('$', '$$') + '"'))
      $e = Invoke-Hidden $psExe $swapped
      try { return ($e.out | ConvertFrom-Json) } catch { return $null }
    }
    $found = @{}
    foreach ($xf in @(Get-ChildItem -Path (Join-Path $repo 'ops\scheduled-tasks') -Filter '*.xml' -File -ErrorAction SilentlyContinue)) {
      $am = [regex]::Match([IO.File]::ReadAllText($xf.FullName), '<Arguments>(.*?)</Arguments>', 'Singleline')
      if (-not $am.Success) { continue }
      $xargs = [System.Net.WebUtility]::HtmlDecode($am.Groups[1].Value)
      if ($xargs -notmatch '\\run-once-a-day\.ps1"') { continue }
      $b = Get-EchoedBinding $xargs
      $k = if ($b) { [string]$b.Key } else { '' }
      $want = if ($k -and $preWrap.ContainsKey($k)) { $preWrap[$k] } else { $null }
      if ($k) { $found[$k] = $xf.Name }
      T ('CLEAN TWIN  ' + $xf.Name + ' hands its child exactly the command the task ran before it was wrapped') (($null -ne $want) -and [string]::Equals([string]$b.Exe, [string]$want.Exe, [StringComparison]::Ordinal) -and [string]::Equals([string]$b.ArgLine, [string]$want.ArgLine, [StringComparison]::Ordinal)) ('key=' + $k + ' exe=' + $(if ($b) { $b.Exe }) + ' argline=' + $(if ($b) { $b.ArgLine }))
    }
    $missingKeys = @($preWrap.Keys | Where-Object { -not $found.ContainsKey($_) })
    # THE GOT LINE STATES THE TWO COUNTS IT COMPARES, and names the surplus as well as the shortfall. This
    # assertion is a COUNT test wearing a list: on 2026-09-12 it failed reporting 'found=<five names> missing='
    # for a task committed without its frozen row, which reads as a passing set - nothing in the message said
    # the frozen side held four. A rate is printed with its denominator (.claude\rules\measurement.md) and the
    # same rule applies to a set: print what was found AND what it was judged against, or the reader has to
    # re-derive the assertion from the source to see why a green-looking line is red. 'unfrozen' is the side
    # that actually fires when a new wrapped task ships without its row, so it is named, not just counted.
    $unfrozenKeys = @($found.Keys | Where-Object { -not $preWrap.ContainsKey($_) })
    $setGot = 'found=' + @($found.Keys).Count + ' frozen=' + $preWrap.Count + ' missing=' + $(if ($missingKeys.Count) { $missingKeys -join ',' } else { 'none' }) + ' unfrozen=' + $(if ($unfrozenKeys.Count) { $unfrozenKeys -join ',' } else { 'none' }) + ' keys=' + (@($found.Keys | Sort-Object) -join ',')
    T ('the committed definitions naming this wrapper resolved to exactly the frozen set: ' + (@($found.Keys | Sort-Object) -join ', ')) ((@($found.Keys).Count -eq $preWrap.Count) -and ($missingKeys.Count -eq 0)) $setGot
    $broken = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\Codex\ThriftyCrew\ops\run-once-a-day.ps1" -Key brain-digest -Exe "C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgLine "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\Codex\ThriftyCrew\ops\brain-digest.ps1" -Alert -Quiet"'
    $bb = Get-EchoedBinding $broken
    T 'MUST FIRE  the same definition with its inner quotes left unescaped does NOT hand the child its command, so the case above can fail' (-not ($bb -and [string]::Equals([string]$bb.ArgLine, [string]$preWrap['brain-digest'].ArgLine, [StringComparison]::Ordinal))) ('argline=' + $(if ($bb) { $bb.ArgLine }))
  } finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }
  if ($script:stFail) { Write-Output ('run-once-a-day SELF-TEST FAIL (' + $script:stFail + ' of ' + $script:stRan + ')'); exit 1 }
  Write-Output ('run-once-a-day SELF-TEST PASS (' + $script:stRan + ' of ' + $script:stRan + ': key refusal, per-day stamp, the stamped exit code read back, stamp on a failed child, a no-op that reports the day''s exit code, an unreadable stamp reported as 2, new day runs, unstartable child leaves no stamp, the task-action shape end to end twice, nested quotes with a space, and every committed wrapped definition bound by a real powershell.exe against its frozen pre-wrap command)')
  exit 0
}

$day = if ($Today) { $Today } else { (Get-Date).ToString('yyyy-MM-dd') }
if (-not $StampDir) { $StampDir = Join-Path $repo 'ops\out\logs\run-once' }
$logName = 'run-once-' + $(if (Test-RunOnceKey $Key) { $Key } else { 'invalid-key' })
$runLog = Start-RunLog -Name $logName -OutDir (Join-Path $repo 'ops\out') -Today $day
$res = Invoke-RunOnce -Key $Key -Exe $Exe -ArgLine $ArgLine -StampDir $StampDir -Day $day
Write-Output $res.message
Stop-RunLog -ExitCode ([int]$res.rc) -Path $runLog
exit ([int]$res.rc)
