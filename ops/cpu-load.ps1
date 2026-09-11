<#
  cpu-load.ps1 - THE way to put deliberate CPU load on this machine. It takes its cores from the same
  machine-wide budget run-gates uses, refuses more than that budget, and its burners die with it.

  Usage:     powershell -File ops\cpu-load.ps1 -Cores 4 -Seconds 300 [-ReadyFile <path>] [-StopFile <path>]
  Self-test: powershell -File ops\cpu-load.ps1 -SelfTest

  WHY (2026-09-11, Brad: "fix the code so it doesnt do this again and honors the cap"). Several sessions were
  fixing tests that fail "under load", and each built its own load to reproduce that: one launched 32 Python
  burners, one ran run-gates three at a time back to back, one started 32 more burners after being asked not
  to, and one looped run-gates with no end. This 32-processor box - shared by every session and by every
  push's gate - sat at 100% for over an hour. Each harness also recorded a load level it did not control,
  because the others' load came and went underneath it.

  WHAT THIS DOES. -Cores slots are taken ALL OR NOTHING from lib\gate-slots.ps1's machine-wide budget (10,
  Brad's ruling), so load and gate workers together never exceed it: a load test holding 8 leaves gate runs 2.
  When they are not all free it waits, says so, and exits 3 after -WaitSec rather than burning fewer cores
  than it was asked for. It then starts exactly -Cores busy processes, writes -ReadyFile as JSON once they are
  up, and holds the slots until -Seconds pass or -StopFile appears.

  BURNERS DIE WITH THE TOOL. Each burner watches a heartbeat file this process touches every second and exits
  when it is more than 5 seconds stale, so killing this tool - a Ctrl+C, a TaskStop, a session that ends -
  cannot leave 32 orphans burning, and the slots come back as abandoned mutexes. A burner also stops at its
  own deadline.

  A BURNER REACHING ITS OWN DEADLINE IS NOT AN EARLY EXIT (2026-09-11). Each burner's deadline is -Seconds from
  when IT started, and the hold loop's clock used to start later, after the burners, a line of output and the
  ready file. On a loaded box that gap let a burner reach its deadline before the loop's last alive check, which
  then reported "a burner exited early" and exit 3 for a load that ran exactly as asked: a copy with 1.5s
  injected there exited 3 in 2 of 2 runs at -Seconds 2, and the unmodified tool 0. The clock now starts before
  any burner, so no burner's deadline comes before the loop's. Every check reads the burners FIRST and the clock
  SECOND, so a burner seen dead while the clock still reads under -Seconds died before any burner's deadline -
  an early exit by construction, never a race. -StartDelayMs stands in for that gap in the self-test.

  A REFUSAL IS EXIT 3, NEVER A SILENT CLAMP, AND IT IS SPOKEN AS IT HAPPENS. -Cores above the budget or -Seconds
  above $MaxSeconds is refused: a harness that asked for 32 and quietly got 10 would tag its rows "32". The
  first draft returned its exit code through the function's output stream and kept only the last item, which
  threw every refusal and waiting line away - the self-test caught it, and the code now travels in a script
  variable so the lines reach stdout live.

  MUTATION-PROBED 2026-09-11, single mutants from temp mirrors, 2 runs each, the original verified byte-identical
  by md5 afterwards. Killed 6 of 7, each red 2 of 2: slots given back right after the burners start, one burner
  past the lease, the stop file ignored, burners never killed in the finally (seen only through the killed
  burner's exit code), a burner ignoring its heartbeat, and the hold loop's clock started after the burners. The
  survivor reads the loop's clock before its burners, predicted before the run: no seam can put a delay between
  those two reads, so no case can see their order. The order stays because the paragraph above needs it.

  Exit 0 ran, 3 could not run (refused, no slots in time, no Python, burners did not start), 2 self-test
  regression.
#>
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop (2026-09-07)
param(
  [int]$Cores = 4,
  [int]$Seconds = 300,
  [string]$ReadyFile = '',
  [string]$StopFile = '',
  [int]$WaitSec = 600,
  # Test seams: the self-test points these at a private Local\ budget so it never takes the real slots,
  # which the run-gates executing it is holding.
  [string]$SlotPrefix = '',
  [int]$SlotTotal = 0,
  # Test seam: a pause between starting the burners and the first alive check, standing in for a loaded box.
  [int]$StartDelayMs = 0,
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\gate-slots.ps1')   # Enter-TcGateSlots -Exact - no param() block, so it cannot reset ours

# THE LONGEST A LOAD MAY RUN. First plausible value, NOT a sweep: the longest harness that day needed about 15
# minutes per arm, and anything longer should be several runs that each give the slots back. Registered in
# docs\CONTROL-CONSTANTS.md.
$MaxSeconds = 900
$PythonExe = 'C:\Codex\Python312\python.exe'

# The burner. A busy loop that checks the heartbeat and its deadline every 500,000 iterations (a few ms).
$BurnerPy = @'
import os, sys, time
hb = sys.argv[1]
end = time.time() + float(sys.argv[2])
n = 0
while True:
    n += 1
    if n % 500000 == 0:
        t = time.time()
        if t > end:
            break
        try:
            if t - os.path.getmtime(hb) > 5:
                break
        except OSError:
            break
'@

# THE EXIT CODE TRAVELS HERE, NOT THROUGH THE OUTPUT STREAM, so every line Invoke-CpuLoad writes reaches stdout.
$script:CpuLoadRc = 3

function Invoke-CpuLoad {
  param([int]$Cores, [int]$Seconds, [string]$ReadyFile, [string]$StopFile, [int]$WaitSec, [string]$Prefix, [int]$Total, [int]$StartDelayMs = 0)
  $script:CpuLoadRc = 3
  if ($Cores -lt 1) {
    Write-Output ("cpu-load: REFUSED - -Cores {0}; at least 1 core is needed" -f $Cores)
    return
  }
  if ($Cores -gt $Total) {
    Write-Output ("cpu-load: REFUSED - asked for {0} cores, and the machine-wide budget shared with run-gates is {1}. Nothing was started. Ask for {1} or fewer, and record the number you ran." -f $Cores, $Total)
    return
  }
  if ($Seconds -lt 1 -or $Seconds -gt $MaxSeconds) {
    Write-Output ("cpu-load: REFUSED - -Seconds {0} is outside 1..{1}. Nothing was started. Run longer load as several runs, so the slots are given back between them." -f $Seconds, $MaxSeconds)
    return
  }
  if (-not (Test-Path -LiteralPath $PythonExe)) {
    Write-Output ("cpu-load: COULD NOT RUN - {0} is missing, so no burner can start" -f $PythonExe)
    return
  }
  $lease = Enter-TcGateSlots -Want $Cores -Total $Total -Prefix $Prefix -Exact -WaitSec $WaitSec -OnWait {
    Write-Output ("cpu-load: waiting for {0} free core slot(s) of the machine-wide {1} - gate runs or other load hold the rest (up to {2}s)" -f $Cores, $Total, $WaitSec)
  }
  if ($lease.TimedOut) {
    Write-Output ("cpu-load: COULD NOT RUN - {0} core slot(s) were never free together in {1:N0}s. Nothing was started." -f $Cores, ($lease.WaitedMs / 1000))
    return
  }
  $dir = Join-Path $env:TEMP ('tc-cpu-load-' + [guid]::NewGuid().ToString('N'))
  $burners = [Collections.Generic.List[object]]::new()
  try {
    $null = New-Item -ItemType Directory -Force $dir
    $hb = Join-Path $dir 'heartbeat'
    $py = Join-Path $dir 'burn.py'
    [IO.File]::WriteAllText($hb, 'alive')
    [IO.File]::WriteAllText($py, $BurnerPy, (New-Object Text.UTF8Encoding($false)))
    # THE CLOCK STARTS BEFORE ANY BURNER, so no burner's own deadline comes before this loop's (see the header).
    $sw = [Diagnostics.Stopwatch]::StartNew()
    for ($k = 0; $k -lt $lease.Count; $k++) {
      $psi = New-Object Diagnostics.ProcessStartInfo
      $psi.FileName = $PythonExe
      $psi.Arguments = ('"{0}" "{1}" {2}' -f $py, $hb, $Seconds)
      $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
      $burners.Add([Diagnostics.Process]::Start($psi))
    }
    if ($StartDelayMs -gt 0) { Start-Sleep -Milliseconds $StartDelayMs }
    # BURNERS FIRST, CLOCK SECOND, here and in the loop.
    $alive = @($burners | Where-Object { -not $_.HasExited }).Count
    if ($alive -ne $lease.Count -and $sw.Elapsed.TotalSeconds -lt $Seconds) {
      Write-Output ("cpu-load: COULD NOT RUN - started {0} burner(s) and only {1} are alive" -f $lease.Count, $alive)
      return
    }
    Write-Output ("cpu-load: burning {0} core(s) for up to {1}s, holding {0} of the machine-wide {2} slots (waited {3:N1}s for them)" -f $lease.Count, $Seconds, $Total, ($lease.WaitedMs / 1000))
    if ($ReadyFile) {
      $ready = [ordered]@{ cores = $lease.Count; seconds = $Seconds; budget = $Total; waited_s = [math]::Round($lease.WaitedMs / 1000, 1); burn_dir = $dir; started_utc = [DateTime]::UtcNow.ToString('o') }
      [IO.File]::WriteAllText($ReadyFile, ($ready | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
    }
    $why = 'deadline'
    $rc = 0
    while ($true) {
      $alive = @($burners | Where-Object { -not $_.HasExited }).Count
      if ($sw.Elapsed.TotalSeconds -ge $Seconds) { break }
      if ($alive -lt $lease.Count) { $why = 'a burner exited early'; $rc = 3; break }
      if ($StopFile -and (Test-Path -LiteralPath $StopFile)) { $why = 'stop-file'; break }
      [IO.File]::SetLastWriteTimeUtc($hb, [DateTime]::UtcNow)
      Start-Sleep -Milliseconds 1000
    }
    Write-Output ("cpu-load: stopped after {0:N0}s ({1})" -f $sw.Elapsed.TotalSeconds, $why)
    $script:CpuLoadRc = $rc
  } finally {
    foreach ($b in $burners) { try { if (-not $b.HasExited) { $b.Kill() } } catch { } }
    Exit-TcGateSlots $lease
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
  }
}

if ($SelfTest) {
  $ErrorActionPreference = 'Continue'
  $fail = 0; $cases = 0
  function T([string]$m, [bool]$c, [string]$got = '') {
    $script:cases++
    if ($c) { Write-Output ('  ok    ' + $m) } else { Write-Output ('  FAIL  ' + $m + '   got: ' + $got); $script:fail++ }
  }
  $PS = (Get-Command powershell).Source
  $prefix = 'Local\tc-cpu-load-selftest-' + [guid]::NewGuid().ToString('N') + '-'
  $tmp = Join-Path $env:TEMP ('tc-cpu-load-st-' + [guid]::NewGuid().ToString('N'))
  $null = New-Item -ItemType Directory -Force $tmp
  $kids = [Collections.Generic.List[object]]::new()
  # NO VERDICT BELOW RESTS ON A CLOCK (2026-09-11). Every running case waits on a condition - a ready file, a
  # process exit, a stop file this test writes - and each remaining timeout is a hang guard far above what the
  # mechanism needs. See the first clean twin for the case that taught it.
  function Get-BurnerIds([string]$Dir) {
    $ids = [Collections.Generic.List[int]]::new()
    if ($Dir) {
      foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='python.exe'")) {
        if (([string]$p.CommandLine).Contains($Dir)) { $ids.Add([int]$p.ProcessId) }
      }
    }
    return ,$ids
  }
  function Get-BurnersIn([string]$Dir) {
    $ids = Get-BurnerIds $Dir
    return $ids.Count
  }
  function Start-Tool([string[]]$ToolArgs, [string]$Name) {
    $o = Join-Path $tmp ($Name + '.out')
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath) + $ToolArgs + @('-SlotPrefix', $prefix, '-SlotTotal', '2')
    $p = Start-Process -FilePath $PS -ArgumentList $a -PassThru -WindowStyle Hidden -RedirectStandardOutput $o -RedirectStandardError ($o + '.err')
    $null = $p.Handle
    $script:kids.Add($p)
    [pscustomobject]@{ Proc = $p; Out = $o }
  }
  function Read-Out($Tool) { if (Test-Path $Tool.Out) { [IO.File]::ReadAllText($Tool.Out) } else { '' } }
  # The ready file, or the tool gone without writing one. The exit is read BEFORE the file, so a tool seen gone
  # has already written everything it ever will.
  function Read-Ready([string]$Path, $Proc, [int]$WithinSec = 180) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $WithinSec) {
      $gone = $Proc.HasExited
      if (Test-Path -LiteralPath $Path) { try { return ([IO.File]::ReadAllText($Path) | ConvertFrom-Json) } catch { } }
      if ($gone) { return $null }
      Start-Sleep -Milliseconds 100
    }
    return $null
  }
  # Until none of one load's burners is left. The guard stays BELOW the 120s the held cases give their burners,
  # so a burner that nothing stops goes red here rather than quietly reaching its own deadline.
  function Wait-NoBurners([string]$Dir, [int]$WithinSec = 60) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $left = Get-BurnersIn $Dir
    while ($left -gt 0 -and $sw.Elapsed.TotalSeconds -lt $WithinSec) { Start-Sleep -Milliseconds 500; $left = Get-BurnersIn $Dir }
    return $left
  }
  function Get-StopReason([string]$Text) { if ($Text -match '\((stop-file|deadline|a burner exited early)\)') { $Matches[1] } else { 'none' } }
  try {
    # MUST FIRE - refusals, and the budget.
    $r = Start-Tool @('-Cores', '3', '-Seconds', '2') 'over-budget'
    [void]$r.Proc.WaitForExit(60000)
    $txt = if (Test-Path $r.Out) { [IO.File]::ReadAllText($r.Out) } else { '' }
    T 'MUST FIRE  THE ONE THIS EXISTS FOR - asking for more cores than the machine-wide budget is REFUSED with exit 3, says so, and starts nothing - never quietly clamped to a number the caller did not record' `
      ($r.Proc.ExitCode -eq 3 -and $txt -match 'REFUSED' -and $txt -notmatch 'burning') ("exit={0} out={1}" -f $r.Proc.ExitCode, $txt.Trim())

    $r = Start-Tool @('-Cores', '1', '-Seconds', ([string]($MaxSeconds + 1))) 'too-long'
    [void]$r.Proc.WaitForExit(60000)
    $txt = if (Test-Path $r.Out) { [IO.File]::ReadAllText($r.Out) } else { '' }
    T 'MUST FIRE  a load longer than the cap is refused with exit 3 and says so, so a harness cannot hold the slots for an hour' `
      ($r.Proc.ExitCode -eq 3 -and $txt -match 'REFUSED') ("exit={0} out={1}" -f $r.Proc.ExitCode, $txt.Trim())

    # With both budget slots held by THIS process, a 1-core load in another process must wait and give up.
    $held = Enter-TcGateSlots -Want 2 -Total 2 -Prefix $prefix -WaitSec 5 -PollMs 100
    $r = Start-Tool @('-Cores', '1', '-Seconds', '2', '-WaitSec', '2', '-ReadyFile', (Join-Path $tmp 'full.ready')) 'budget-full'
    [void]$r.Proc.WaitForExit(60000)
    $txt = if (Test-Path $r.Out) { [IO.File]::ReadAllText($r.Out) } else { '' }
    T 'MUST FIRE  when gate runs hold the whole budget, a load test waits, says so, and exits 3 without starting a burner' `
      ($held.Count -eq 2 -and $r.Proc.ExitCode -eq 3 -and $txt -match 'waiting' -and $txt -match 'COULD NOT RUN' -and -not (Test-Path (Join-Path $tmp 'full.ready'))) ("held={0} exit={1} out={2}" -f $held.Count, $r.Proc.ExitCode, $txt.Trim())
    Exit-TcGateSlots $held

    # CLEAN TWIN - the load really runs, really holds its slot, and really stops.
    # HELD OPEN BY ITS STOP FILE, NEVER SAMPLED AGAINST ITS DEADLINE (2026-09-11). This case used to run a 4s load
    # and sample it "during". In a pre-push run-gates on a box shared by about ten sessions it read ready=True
    # burnersDuring=0 slotsLeftForOthers=2 exit=0: the load had finished and given its slot back before the
    # process query returned. A copy instrumented to time it took 0.8s to 2.5s from the ready file to its last
    # sample on a 90-100% box, against that 4s window. Now the load cannot end until this case writes the stop
    # file, the case reads the tool STILL RUNNING after its last sample, and what it asserts about the ending is
    # what the tool and the OS recorded. Load makes it slower, never red.
    $rf = Join-Path $tmp 'run.ready'; $stop = Join-Path $tmp 'run.STOP'
    $r = Start-Tool @('-Cores', '1', '-Seconds', '120', '-ReadyFile', $rf, '-StopFile', $stop) 'run'
    $ready = Read-Ready $rf $r.Proc
    $burnDir = if ($ready) { [string]$ready.burn_dir } else { '' }
    $ids = Get-BurnerIds $burnDir
    $during = $ids.Count
    # A handle opened NOW, while the burner runs, keeps its exit code readable once it is gone.
    $burner = $null
    if ($during -eq 1) { try { $burner = [Diagnostics.Process]::GetProcessById($ids[0]); $null = $burner.Handle } catch { $burner = $null } }
    $probe = Enter-TcGateSlots -Want 2 -Total 2 -Prefix $prefix -WaitSec 1 -PollMs 100
    $probeGot = $probe.Count
    Exit-TcGateSlots $probe
    $heldOpen = -not $r.Proc.HasExited
    [IO.File]::WriteAllText($stop, 'stop')
    $exited = $r.Proc.WaitForExit(180000)
    # Process.Kill is TerminateProcess with exit code -1. A burner that stopped by itself - on its heartbeat, its
    # deadline, or its directory vanishing - exits 0, so -1 is the tool's finally having killed it.
    $burnerExit = 'no-handle'
    if ($burner) { if ($burner.WaitForExit(60000)) { $burnerExit = [string]$burner.ExitCode } else { $burnerExit = 'still-running' } }
    $after = Wait-NoBurners $burnDir
    $txt = Read-Out $r
    T 'CLEAN TWIN a 1-core load held open by its stop file starts exactly 1 burner, holds exactly 1 of the 2 budget slots, says what it burned, and on the stop file exits 0 having killed its burner' `
      ($ready -and [int]$ready.cores -eq 1 -and $heldOpen -and $during -eq 1 -and $probeGot -eq 1 -and $exited -and $r.Proc.ExitCode -eq 0 -and $txt -match 'burning 1 core' -and (Get-StopReason $txt) -eq 'stop-file' -and $burnerExit -eq '-1' -and $after -eq 0) `
      ("ready={0} stillRunningAfterSampling={1} burnersDuring={2} slotsLeftForOthers={3} exited={4} exit={5} stopReason={6} burnerExit={7} burnersAfter={8}" -f [bool]$ready, $heldOpen, $during, $probeGot, $exited, $(if ($exited) { $r.Proc.ExitCode } else { 'running' }), (Get-StopReason $txt), $burnerExit, $after)

    # CLEAN TWIN - with no stop file the load ends on its own -Seconds. Nothing is sampled while it runs, so there
    # is nothing for a slow box to race.
    $rf2 = Join-Path $tmp 'deadline.ready'
    $r = Start-Tool @('-Cores', '1', '-Seconds', '2', '-ReadyFile', $rf2) 'deadline'
    $exited = $r.Proc.WaitForExit(180000)
    $ready2 = Read-Ready $rf2 $r.Proc
    $dir2 = if ($ready2) { [string]$ready2.burn_dir } else { '' }
    $after2 = Wait-NoBurners $dir2
    $txt = Read-Out $r
    T 'CLEAN TWIN a load with no stop file runs to its own -Seconds deadline, says so, and exits 0 with no burner left' `
      ($ready2 -and $exited -and $r.Proc.ExitCode -eq 0 -and (Get-StopReason $txt) -eq 'deadline' -and $after2 -eq 0) `
      ("ready={0} exited={1} exit={2} stopReason={3} burnersAfter={4}" -f [bool]$ready2, $exited, $(if ($exited) { $r.Proc.ExitCode } else { 'running' }), (Get-StopReason $txt), $after2)

    # MUST NOT FIRE - A BURNER REACHING ITS OWN DEADLINE IS NOT AN EARLY EXIT (see the header). -StartDelayMs holds
    # the tool for 1.5s after its burners start, as a loaded box does; on the tool as first committed this shape
    # exited 3 with "a burner exited early" in 2 of 2 runs.
    $r = Start-Tool @('-Cores', '1', '-Seconds', '2', '-StartDelayMs', '1500') 'slow-start'
    $exited = $r.Proc.WaitForExit(180000)
    $txt = Read-Out $r
    T 'MUST NOT FIRE  a load slow to reach its hold loop does not report its burner reaching its own deadline as an early exit - exit 0, stopped on the deadline' `
      ($exited -and $r.Proc.ExitCode -eq 0 -and (Get-StopReason $txt) -eq 'deadline') `
      ("exited={0} exit={1} stopReason={2}" -f $exited, $(if ($exited) { $r.Proc.ExitCode } else { 'running' }), (Get-StopReason $txt))

    # THE ORPHAN CASE: the tool is killed outright, its finally never runs, and the burners must still stop.
    $rf3 = Join-Path $tmp 'kill.ready'
    $r = Start-Tool @('-Cores', '1', '-Seconds', '120', '-ReadyFile', $rf3) 'kill'
    $ready3 = Read-Ready $rf3 $r.Proc
    $killDir = if ($ready3) { [string]$ready3.burn_dir } else { '' }
    $before = Get-BurnersIn $killDir
    try { $r.Proc.Kill() } catch { }
    # GONE BEFORE ITS SLOT IS ASKED FOR: the slot comes back when the owner's thread ends, and a non-exact Enter
    # that ran first would take the one other free slot and stop at 1.
    [void]$r.Proc.WaitForExit(60000)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $left = Wait-NoBurners $killDir
    $back = Enter-TcGateSlots -Want 2 -Total 2 -Prefix $prefix -WaitSec 5 -PollMs 100
    $backGot = $back.Count
    Exit-TcGateSlots $back
    T 'CLEAN TWIN a load tool KILLED outright leaves no burner running - they stop on the stale heartbeat - and its slot comes back' `
      ($before -eq 1 -and $left -eq 0 -and $backGot -eq 2) ("burnersBeforeKill={0} burnersAfter={1} slotsBack={2} after={3:N1}s" -f $before, $left, $backGot, $sw.Elapsed.TotalSeconds)
    if ($killDir) { Remove-Item -LiteralPath $killDir -Recurse -Force -ErrorAction SilentlyContinue }
  } finally {
    foreach ($p in $kids) { try { if (-not $p.HasExited) { $p.Kill() } } catch { } }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }
  ''
  if ($fail) {
    Write-Output ("cpu-load selftest: $fail FAILED of $cases")
    Exit-Guard -Name 'CPU-LOAD-SELFTEST' -Code 2 -Summary "failed=$fail of $cases"
  }
  Write-Output ("cpu-load selftest: $cases of $cases cases pass")
  Exit-Guard -Name 'CPU-LOAD-SELFTEST' -Code 0 -Summary "cases=$cases"
}

$prefixUse = if ($SlotPrefix) { $SlotPrefix } else { $script:TcGateSlotPrefix }
$totalUse = if ($SlotTotal -gt 0) { $SlotTotal } else { $script:TcGateSlotTotal }
Invoke-CpuLoad -Cores $Cores -Seconds $Seconds -ReadyFile $ReadyFile -StopFile $StopFile -WaitSec $WaitSec -Prefix $prefixUse -Total $totalUse -StartDelayMs $StartDelayMs
Exit-Guard -Name 'CPU-LOAD' -Code ([int]$script:CpuLoadRc) -Summary ("cores={0} seconds={1} budget={2}" -f $Cores, $Seconds, $totalUse)
