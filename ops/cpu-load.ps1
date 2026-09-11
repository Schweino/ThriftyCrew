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

  A REFUSAL IS EXIT 3, NEVER A SILENT CLAMP, AND IT IS SPOKEN AS IT HAPPENS. -Cores above the budget or -Seconds
  above $MaxSeconds is refused: a harness that asked for 32 and quietly got 10 would tag its rows "32". The
  first draft returned its exit code through the function's output stream and kept only the last item, which
  threw every refusal and waiting line away - the self-test caught it, and the code now travels in a script
  variable so the lines reach stdout live.

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
  # AND THE QUEUE IS A SEAM FOR THE SAME REASON (2026-09-11). Slots alone stopped deciding order when
  # lib\gate-slots.ps1 gained a ticket queue: a fixture left on the production queue would wait behind real
  # pushes, and its own tickets would tell every real waiter that somebody was ahead of them. The private
  # Local\ budget is only half the isolation now.
  [string]$SlotQueueDir = '',
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
  param([int]$Cores, [int]$Seconds, [string]$ReadyFile, [string]$StopFile, [int]$WaitSec, [string]$Prefix, [int]$Total)
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
    for ($k = 0; $k -lt $lease.Count; $k++) {
      $psi = New-Object Diagnostics.ProcessStartInfo
      $psi.FileName = $PythonExe
      $psi.Arguments = ('"{0}" "{1}" {2}' -f $py, $hb, $Seconds)
      $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
      $burners.Add([Diagnostics.Process]::Start($psi))
    }
    $alive = @($burners | Where-Object { -not $_.HasExited }).Count
    if ($alive -ne $lease.Count) {
      Write-Output ("cpu-load: COULD NOT RUN - started {0} burner(s) and only {1} are alive" -f $lease.Count, $alive)
      return
    }
    Write-Output ("cpu-load: burning {0} core(s) for up to {1}s, holding {0} of the machine-wide {2} slots (waited {3:N1}s for them)" -f $lease.Count, $Seconds, $Total, ($lease.WaitedMs / 1000))
    if ($ReadyFile) {
      $ready = [ordered]@{ cores = $lease.Count; seconds = $Seconds; budget = $Total; waited_s = [math]::Round($lease.WaitedMs / 1000, 1); burn_dir = $dir; started_utc = [DateTime]::UtcNow.ToString('o') }
      [IO.File]::WriteAllText($ReadyFile, ($ready | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
    }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $why = 'deadline'
    $rc = 0
    while ($sw.Elapsed.TotalSeconds -lt $Seconds) {
      if ($StopFile -and (Test-Path -LiteralPath $StopFile)) { $why = 'stop-file'; break }
      [IO.File]::SetLastWriteTimeUtc($hb, [DateTime]::UtcNow)
      $alive = @($burners | Where-Object { -not $_.HasExited }).Count
      if ($alive -lt $lease.Count) { $why = 'a burner exited early'; $rc = 3; break }
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
  # THE QUEUE IS REDIRECTED TOO, for this process and for every child the cases start. The Local\ prefix keeps
  # the fixture off the real slots; without this the fixture would still QUEUE on the real ticket directory,
  # where it would wait behind live pushes and, worse, tell every live push that somebody was ahead of it.
  $script:TcGateQueueDir = Join-Path $tmp 'queue'
  $null = New-Item -ItemType Directory -Force $script:TcGateQueueDir
  $kids = [Collections.Generic.List[object]]::new()
  function Get-BurnersIn([string]$Dir) {
    if (-not $Dir) { return 0 }
    $all = @(Get-CimInstance Win32_Process -Filter "Name='python.exe'" | Where-Object { ([string]$_.CommandLine).Contains($Dir) })
    return $all.Count
  }
  function Start-Tool([string[]]$ToolArgs, [string]$Name) {
    $o = Join-Path $tmp ($Name + '.out')
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath) + $ToolArgs + @('-SlotPrefix', $prefix, '-SlotTotal', '2', '-SlotQueueDir', $script:TcGateQueueDir)
    $p = Start-Process -FilePath $PS -ArgumentList $a -PassThru -WindowStyle Hidden -RedirectStandardOutput $o -RedirectStandardError ($o + '.err')
    $null = $p.Handle
    $script:kids.Add($p)
    [pscustomobject]@{ Proc = $p; Out = $o }
  }
  function Read-Ready([string]$Path, [int]$WithinSec) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $WithinSec) {
      if (Test-Path -LiteralPath $Path) { try { return ([IO.File]::ReadAllText($Path) | ConvertFrom-Json) } catch { } }
      Start-Sleep -Milliseconds 100
    }
    return $null
  }
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
    $rf = Join-Path $tmp 'run.ready'
    $r = Start-Tool @('-Cores', '1', '-Seconds', '4', '-ReadyFile', $rf) 'run'
    $ready = Read-Ready $rf 30
    $burnDir = if ($ready) { [string]$ready.burn_dir } else { '' }
    $during = Get-BurnersIn $burnDir
    $probe = Enter-TcGateSlots -Want 2 -Total 2 -Prefix $prefix -WaitSec 1 -PollMs 100
    $probeGot = $probe.Count
    Exit-TcGateSlots $probe
    [void]$r.Proc.WaitForExit(60000)
    Start-Sleep -Milliseconds 500
    $after = Get-BurnersIn $burnDir
    $txt = if (Test-Path $r.Out) { [IO.File]::ReadAllText($r.Out) } else { '' }
    T 'CLEAN TWIN a 1-core load starts exactly 1 burner, holds exactly 1 of the 2 budget slots while it runs, says what it burned, and exits 0 with no burner left' `
      ($ready -and [int]$ready.cores -eq 1 -and $during -eq 1 -and $probeGot -eq 1 -and $r.Proc.ExitCode -eq 0 -and $after -eq 0 -and $txt -match 'burning 1 core') `
      ("ready={0} burnersDuring={1} slotsLeftForOthers={2} exit={3} burnersAfter={4}" -f [bool]$ready, $during, $probeGot, $r.Proc.ExitCode, $after)

    $rf2 = Join-Path $tmp 'stop.ready'; $stop = Join-Path $tmp 'STOP'
    $r = Start-Tool @('-Cores', '1', '-Seconds', '120', '-ReadyFile', $rf2, '-StopFile', $stop) 'stop'
    $ready2 = Read-Ready $rf2 30
    [IO.File]::WriteAllText($stop, 'stop')
    $exited = $r.Proc.WaitForExit(20000)
    T 'CLEAN TWIN the stop file ends a long load within seconds, with exit 0' `
      ($ready2 -and $exited -and $r.Proc.ExitCode -eq 0) ("ready={0} exitedInTime={1}" -f [bool]$ready2, $exited)

    # THE ORPHAN CASE: the tool is killed outright, its finally never runs, and the burners must still stop.
    $rf3 = Join-Path $tmp 'kill.ready'
    $r = Start-Tool @('-Cores', '1', '-Seconds', '120', '-ReadyFile', $rf3) 'kill'
    $ready3 = Read-Ready $rf3 30
    $killDir = if ($ready3) { [string]$ready3.burn_dir } else { '' }
    $before = Get-BurnersIn $killDir
    try { $r.Proc.Kill() } catch { }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $left = $before
    while ($sw.Elapsed.TotalSeconds -lt 20 -and $left -gt 0) { Start-Sleep -Milliseconds 500; $left = Get-BurnersIn $killDir }
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

# The queue seam is applied by REDIRECTING the library's own default, so every call below - Enter's, and the
# growth check inside it - reads the same directory without threading a parameter through each one.
if ($SlotQueueDir) { $script:TcGateQueueDir = $SlotQueueDir }
$prefixUse = if ($SlotPrefix) { $SlotPrefix } else { $script:TcGateSlotPrefix }
$totalUse = if ($SlotTotal -gt 0) { $SlotTotal } else { $script:TcGateSlotTotal }
Invoke-CpuLoad -Cores $Cores -Seconds $Seconds -ReadyFile $ReadyFile -StopFile $StopFile -WaitSec $WaitSec -Prefix $prefixUse -Total $totalUse
Exit-Guard -Name 'CPU-LOAD' -Code ([int]$script:CpuLoadRc) -Summary ("cores={0} seconds={1} budget={2}" -f $Cores, $Seconds, $totalUse)
