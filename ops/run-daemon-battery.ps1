<#
  run-daemon-battery.ps1 - run the Recipe Hunter daemon's full self-test battery the way a scheduled task can trust.

  Real run:   powershell -File ops\run-daemon-battery.ps1 [-Commit origin/main] [-NoFetch]
  Scheduled:  TC Daemon Battery 0230 (ops\scheduled-tasks\tc-daemon-battery-0230.xml), through ops\run-once-a-day.ps1
  Self-test:  powershell -File ops\run-daemon-battery.ps1 -SelfTest

  WHY (2026-09-11). ops\run-gates.ps1 skips meal-prep\pipeline\hunt_daemon_selftest.py because it runs for minutes,
  and its reason said "exercised nightly". Nothing exercised it: no committed .ps1, .py, .json, .xml or .yml named
  `hunt-daemon.py --selftest`, and none of the box's 193 scheduled tasks ran it. It ran when somebody remembered to.
  The same day it was found rewriting the tracked meal-prep\db\fdc-cache.json 36 times per run,   # reach-fixture-ok: named in prose, never opened
  which one run followed by `git status --short` would have shown on the first night.

  WHY A TASK OF ITS OWN. The rubric: a red battery must page on its OWN exit code, must not share fate with a money
  chain, must run when the box is quiet, and should look like the other TC tasks.
    - A stage in TC Graph Nightly Matching: the graph lane's chain, budgeted by -MaxMinutes 150 inside the GPU
      window, and its exit code describes the graph. A red battery would be one line in somebody else's status.
    - A stage in the 08:00 daily capture chain: the money lane. A daemon fixture must never delay a board.
    - Leaving it manual and fixing only the reason text: d2ee101cb did exactly that, and it left the battery running
      only when remembered, which is the defect.
  A Windows task (Brad's 2026-08-22 rule) watched in grocery\expected-automations.json gets health-heartbeat's
  per-task exit-code page without anything new being built to read it.

  WHAT A RUN DOES, IN ORDER
    1. takes ONE slot of lib\gate-slots.ps1's machine-wide budget and holds it for the whole run, so the battery and
       every push's run-gates share the box's 10 rather than stacking on top of them
    2. fetches origin and resolves -Commit to a sha
    3. makes a THROWAWAY detached checkout of that sha under %TEMP%, core.autocrlf off so its bytes are the committed
       bytes, and refuses to run (exit 3) unless `git status --short` there is empty first
    4. runs `hunt-daemon.py --selftest --names-diff <checkout>\meal-prep\pipeline\hunt_daemon_selftest.names.txt`
       under a hang guard that kills the whole process tree, not only python
    5. reads the EXIT CODE FIRST, then the completion marker, then the case-name diff, then `git status --short`
    6. removes the checkout in a finally, and writes ops\out\logs\daemon-battery-green.json only on a green verdict

  WHY A THROWAWAY CHECKOUT AND NOT THE MAIN ONE. The suite's convention is that no fixture writes a tracked path, and
  the direct test of that is an empty `git status --short` afterwards. The main checkout read 86 status lines on
  2026-09-11 - other sessions' work and the pipeline's data - so there the check would be red every night for reasons
  that are not the battery's, or would need a before/after diff that a concurrent session moves underneath it. A
  fresh checkout is empty by construction, so every line afterwards is the battery's. It also tests what is
  COMMITTED on origin/main, rather than whatever happens to be uncommitted in the main checkout tonight.

  WHY THE NAMES REFERENCE IS COMMITTED. `--names-diff` needs a list to diff against, and a list this runner pinned
  for itself would bless whatever last night's run happened to execute. The reference is read from the commit under
  test, so a change that deletes a case must delete its name from the reference in the same diff, where a reviewer
  reads it; a deletion that does not is exit 2. A case ADDED since the pin is not an error, and the green line says
  how many are unprotected. Re-pin from a checkout at the commit, after a deliberate removal or to protect additions:
      C:\Codex\Python312\python.exe meal-prep\pipeline\hunt-daemon.py --selftest --names-out meal-prep\pipeline\hunt_daemon_selftest.names.txt

  WHY THE STAMP IS WRITTEN ONLY WHEN GREEN. health-heartbeat excuses a nonzero task result whose 'proves' output is
  fresh and no older than the run. TC Recall Sleep stamps on every path, which is right for a task whose work is the
  pass itself. Here the work IS the verdict: a stamp written on a red run would excuse the red run it describes.
  The transcript under ops\out\logs\ is the every-path record.

  EXIT CODES (lib\guard-contract.ps1 vocabulary): 0 green; 2 a hard finding - a red case, a pinned case name that did
  not run, a nonzero battery exit this cannot explain, or any status line in the checkout afterwards; 3 could not
  evaluate - no slot, no commit, no checkout, a checkout dirty BEFORE the run, no reference, the hang guard fired, or
  the battery died before its completion marker. A run with a hard finding AND a blind reason exits 2: a proven
  defect is not demoted by an unknown beside it.

  SCOPE OF A CLEAN REPORT: SOUND for what it names at the commit it names - the battery's own exit code, every pinned
  case name, and every change `git status` can see in the checkout. UNSOUND past that: a write to an IGNORED path, to
  %TEMP%, or anywhere outside the checkout is invisible here, and a case whose assertion is too weak is green however
  the daemon behaves.
#>
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop (2026-09-07)
param(
  [string]$Commit = 'origin/main',
  [switch]$NoFetch,
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\ops' }
$repo = Split-Path $here -Parent
# NO REPOSITORY ENVIRONMENT IS INHERITED. Every git call here names its repository with -C, and an inherited GIT_DIR
# overrides -C: run from a hook in a linked worktree, `worktree add` and the self-test's `git init` would land in the
# hook's repository (ops-and-gates.md, 2026-09-10). This script is its own process, so clearing is safe.
. (Join-Path $repo 'lib\git-repo-env.ps1')
Clear-TcGitRepoEnv
. (Join-Path $repo 'lib\guard-contract.ps1')     # Test-GuardComplete, Exit-Guard
. (Join-Path $repo 'lib\gate-slots.ps1')         # Enter-TcGateSlots / Exit-TcGateSlots: the machine-wide budget
. (Join-Path $repo 'lib\git-blob-lib.ps1')       # Invoke-GitCaptured: both pipes drained, never throws
. (Join-Path $repo 'lib\parallel-run.ps1')       # ConvertTo-TcOutputLines
. (Join-Path $repo 'grocery\run-log-lib.ps1')    # Start-RunLog / Stop-RunLog: a hidden task leaves a transcript

# THE HANG GUARD. First plausible value, NOT a sweep: four times the slowest full battery measured on this box (677 s
# under load, 2026-09-11; the exploratory run for this file took 248 s), so load alone should not trip it, and a hung
# lane is still killed inside the task's 2 h ExecutionTimeLimit with room for the slot wait and the checkout (8 s to
# add, 1.6 s to remove, measured). Registered in docs\CONTROL-CONSTANTS.md.
$script:HangGuardSec = 2700
# THE SLOT WAIT. First plausible value, NOT a sweep. The first draft said 1800 s; the exploratory run that measured the
# battery on 2026-09-11 waited 1,629 s for its one slot behind about fifteen concurrent run-gates in the afternoon, so
# 1800 would refuse a catch-up occurrence on a busy day. 3600 + the hang guard + about 10 s of checkout still fits the
# task's 2 h ExecutionTimeLimit. Registered in docs\CONTROL-CONSTANTS.md.
$script:SlotWaitSec = 3600
# ONE SLOT. Measured 2026-09-11 over a full run (548 cases, 248 s of wall): the process tree used at least 42.8 s of
# CPU - python plus 82 powershell.exe children sampled every 2 s, so short-lived children are undercounted and this is a
# LOWER bound. Nothing in it suggests a sustained second core; a burst of concurrent children can exceed one briefly.
$script:SlotWant = 1
$script:PythonExe = 'C:\Codex\Python312\python.exe'
$script:NamesRel = 'meal-prep\pipeline\hunt_daemon_selftest.names.txt'
$script:BatteryArgs = '"{checkout}\meal-prep\pipeline\hunt-daemon.py" --selftest --names-diff "{names}"'
$script:StampPath = Join-Path $repo 'ops\out\logs\daemon-battery-green.json'

function Get-BatteryVerdict {
  <# The judgement, pure over what one run produced, so the self-test drives the code a real run uses.
     Returns Code (0/2/3), Hard and Blind (string[]), Cases, Removed, Added (null when not printed) and Red.

     THE EXIT CODE IS READ FIRST, and nothing below can turn a nonzero exit into a pass: every reading of the output
     only EXPLAINS a nonzero exit, and one it cannot explain is still a hard finding. The completion marker comes
     next because an exit code from a battery that died halfway describes no verdict at all. #>
  param(
    [int]$ExitCode,
    [AllowEmptyCollection()][string[]]$Output = @(),
    [AllowEmptyCollection()][string[]]$StatusLines = @(),
    [bool]$TimedOut = $false,
    [bool]$PipeHeld = $false
  )
  $hard = New-Object System.Collections.Generic.List[string]
  $blind = New-Object System.Collections.Generic.List[string]
  $red = New-Object System.Collections.Generic.List[string]
  $gone = New-Object System.Collections.Generic.List[string]
  $lines = @($Output | ForEach-Object { [string]$_ })
  $cases = $null; $removed = $null; $added = $null; $pass = $false; $cannot = ''; $inDiff = $false
  foreach ($ln in $lines) {
    $m = [regex]::Match($ln, '^\s*(\d+) case\(s\) ran\s*$')
    if ($m.Success) { $cases = [int]$m.Groups[1].Value; continue }
    # hunt_lib.names_report: "  vs <ref>: <n> removed, <n> added", then "    +  <name>" / "    -  <name>"
    $m = [regex]::Match($ln, '^\s*vs .*: (\d+) removed, (\d+) added\s*$')
    if ($m.Success) { $removed = [int]$m.Groups[1].Value; $added = [int]$m.Groups[2].Value; $inDiff = $true; continue }
    # hunt_daemon_selftest's T(): "  ok    <name>" or "  X     <name>   got: <detail>"
    $m = [regex]::Match($ln, '^  X     (.+?)(?:   got: .*)?$')
    if ($m.Success) { $red.Add($m.Groups[1].Value); continue }
    if ($inDiff) { $m = [regex]::Match($ln, '^    -  (.+)$'); if ($m.Success) { $gone.Add($m.Groups[1].Value); continue } }
    $m = [regex]::Match($ln, '^\s*CANNOT DIFF - (.+)$')
    if ($m.Success) { $cannot = $m.Groups[1].Value.Trim(); continue }
    if ($ln -match '^hunt-daemon SELF-TEST PASS\s*$') { $pass = $true }
  }

  if ($TimedOut) {
    $blind.Add('the hang guard killed the battery''s whole process tree before it finished, so no verdict was reached')
  } elseif (-not (Test-GuardComplete -Output $lines -Name 'hunt-daemon')) {
    $blind.Add(("the battery exited {0} without HUNT-DAEMON-COMPLETE as its last line: it died before its verdict, so that exit code describes nothing" -f $ExitCode))
  } else {
    if ($red.Count) {
      $hard.Add(("{0} case(s) red: {1}" -f $red.Count, ($red.GetRange(0, [Math]::Min(10, $red.Count)) -join ' | ')))
    }
    if ($gone.Count -or ($removed -gt 0)) {
      $n = if ($null -ne $removed) { $removed } else { $gone.Count }
      $hard.Add(("{0} case name(s) in the pinned reference did not run - a deleted case is not a pass: {1}" -f $n, ($gone.GetRange(0, [Math]::Min(10, $gone.Count)) -join ' | ')))
    }
    if ($cannot) { $blind.Add('the case-name diff could not run: ' + $cannot) }
    if ($ExitCode -ne 0) {
      if (-not $hard.Count -and -not $blind.Count) {
        $said = if ($pass) { ', and this output even printed PASS' } else { '' }
        $hard.Add(("exit {0} with no red case and no missing case name this runner can read; a nonzero exit is never a pass{1}" -f $ExitCode, $said))
      }
    } else {
      if (-not $pass) { $blind.Add('exit 0 without the PASS line: the exit code and the printed verdict disagree') }
      if (($null -eq $removed) -and -not $cannot) {
        $blind.Add('exit 0 with no case-name diff line, so the battery ran without its pinned reference and a deleted case would have read green')
      }
    }
  }
  if ($PipeHeld) {
    $blind.Add('a process the battery started still held its output pipe 60 s after the battery exited, so the output read here may be incomplete')
  }
  $status = @($StatusLines | Where-Object { ([string]$_).Trim() })
  if ($status.Count) {
    $hard.Add(("the battery left {0} git status line(s) in a checkout that was empty before it ran, and no fixture may write into the tree: {1}" -f $status.Count, (($status | ForEach-Object { ([string]$_).Trim() }) -join ' | ')))
  }
  $code = if ($hard.Count) { 2 } elseif ($blind.Count) { 3 } else { 0 }
  return [pscustomobject]@{ Code = $code; Hard = $hard.ToArray(); Blind = $blind.ToArray()
                            Cases = $cases; Removed = $removed; Added = $added; Red = $red.Count }
}

function Stop-ProcessTree {
  <# taskkill /T /F: the battery starts powershell.exe children, and killing python alone leaves them running. #>
  param([int]$Id)
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = Join-Path $env:SystemRoot 'System32\taskkill.exe'
  $psi.Arguments = '/T /F /PID ' + $Id
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $k = [Diagnostics.Process]::Start($psi)
  $null = $k.StandardOutput.ReadToEndAsync(); $null = $k.StandardError.ReadToEndAsync()
  [void]$k.WaitForExit(30000)
  $k.Dispose()
}

function Invoke-TreeProcess {
  <# One child, both pipes drained while it runs, under a hang guard that kills its WHOLE TREE. Returns ExitCode,
     Out (string[]), Err, TimedOut, PipeHeld and Seconds.

     WHY NOT lib\parallel-run.ps1's Invoke-TcParallel: it kills only the process it started. A grandchild that
     inherited the stdout pipe keeps that pipe open, so the read after a one-process kill can wait forever - a hang
     guard that hangs. -KillWhen is a seam for the self-test, polled with the clock: it lets a case end the wait
     on an event instead of a stopwatch, and a separate case drives the real clock with no seam. #>
  param([string]$Exe, [string]$ArgLine, [string]$WorkDir, [int]$GuardSec, [scriptblock]$KillWhen = $null)
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = $Exe
  $psi.Arguments = $ArgLine
  $psi.WorkingDirectory = $WorkDir
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $p = [Diagnostics.Process]::Start($psi)
  # THE READS START BEFORE THE WAIT, or a child that fills the pipe buffer blocks on its write while we block on it.
  $tOut = $p.StandardOutput.ReadToEndAsync()
  $tErr = $p.StandardError.ReadToEndAsync()
  $killed = $false
  while (-not $p.WaitForExit(250)) {
    if (($sw.Elapsed.TotalSeconds -ge $GuardSec) -or ($KillWhen -and (& $KillWhen))) {
      $killed = $true
      Stop-ProcessTree -Id $p.Id
      [void]$p.WaitForExit(30000)
      break
    }
  }
  $sw.Stop()
  $outText = ''; $errText = ''; $held = $false
  if ($tOut.Wait(60000)) { $outText = [string]$tOut.Result } else { $held = $true }
  if ($tErr.Wait(60000)) { $errText = [string]$tErr.Result } else { $held = $true }
  $rc = if ($p.HasExited) { $p.ExitCode } else { -1 }
  $p.Dispose()
  $lines = ConvertTo-TcOutputLines $outText
  return [pscustomobject]@{ ExitCode = $rc; Out = $lines; Err = $errText; TimedOut = $killed; PipeHeld = $held
                            Seconds = $sw.Elapsed.TotalSeconds }
}

function Get-CheckoutStatus {
  param([string]$Dir)
  $r = Invoke-GitCaptured -Repo $Dir -GitArgs @('status', '--short', '--untracked-files=all')
  $split = ConvertTo-TcOutputLines ([string]$r.stdout)
  $lines = @($split | Where-Object { ([string]$_).Trim() })
  return [pscustomobject]@{ Rc = [int]$r.rc; Lines = $lines; Err = [string]$r.stderr }
}

function Remove-BatteryCheckout {
  <# Never throws: cleanup must not replace the verdict. `git worktree remove --force` can exit 0 and leave the
     directory behind (ops\seed-worktree.ps1 measured that on 2026-09-11), so a directory still there is deleted and
     prune drops the registration of one that is gone. #>
  param([string]$RepoDir, [string]$Dir)
  $notes = @()
  $r = Invoke-GitCaptured -Repo $RepoDir -GitArgs @('worktree', 'remove', '--force', $Dir)
  if (($r.rc -ne 0) -and (Test-Path -LiteralPath $Dir)) { $notes += ('git worktree remove exited {0}: {1}' -f $r.rc, ([string]$r.stderr).Trim()) }
  if (Test-Path -LiteralPath $Dir) {
    try { Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction Stop } catch { $notes += ('could not delete {0}: {1}' -f $Dir, $_.Exception.Message) }
  }
  $null = Invoke-GitCaptured -Repo $RepoDir -GitArgs @('worktree', 'prune')
  return [pscustomobject]@{ Left = (Test-Path -LiteralPath $Dir); Notes = $notes }
}

function Invoke-DaemonBattery {
  <# Everything between the slot and the stamp, with every external named by a parameter so the self-test drives
     this against a temp repository and a fake battery. Returns the verdict plus what was run. {checkout} and {names}
     in -ArgTemplate are replaced with the checkout directory and the reference path inside it. #>
  param(
    [Parameter(Mandatory=$true)][string]$RepoDir,
    [Parameter(Mandatory=$true)][string]$Sha,
    [Parameter(Mandatory=$true)][string]$Exe,
    [Parameter(Mandatory=$true)][string]$ArgTemplate,
    [string]$WorkDirRel = '',
    [Parameter(Mandatory=$true)][string]$NamesRel,
    [int]$GuardSec = 2700,
    [string]$TempRoot = $env:TEMP,
    [scriptblock]$KillWhen = $null
  )
  $res = [pscustomobject]@{
    Code = 3; Hard = @(); Blind = @(); Cases = $null; Removed = $null; Added = $null; Red = 0
    Ran = $false; ExitCode = $null; TimedOut = $false; Seconds = 0.0; Output = @(); Err = ''
    # Short on purpose: every character lands on every path in an 8,000-file checkout, and PS 5.1 stops at 260.
    Checkout = (Join-Path $TempRoot ('tcdb-' + [guid]::NewGuid().ToString('N').Substring(0, 8)))
    StatusAfter = @(); CheckoutLeft = $false; CleanupNotes = @()
  }
  try {
    $add = Invoke-GitCaptured -Repo $RepoDir -GitArgs @('-c', 'core.autocrlf=false', 'worktree', 'add', '-q', '--detach', $res.Checkout, $Sha)
    if ($add.rc -ne 0) {
      $res.Blind = @(('could not create the checkout (git worktree add exited {0}): {1}' -f $add.rc, ([string]$add.stderr).Trim()))
      return $res
    }
    $pre = Get-CheckoutStatus -Dir $res.Checkout
    if (($pre.Rc -ne 0) -or $pre.Lines.Count) {
      $res.Blind = @(('the fresh checkout was not provably clean before the battery ran (status exit {0}, {1} line(s): {2}), so a dirty tree afterwards could not be blamed on the battery; it was not run' -f $pre.Rc, $pre.Lines.Count, ($pre.Lines -join ' | ')))
      return $res
    }
    $names = Join-Path $res.Checkout $NamesRel
    if (-not (Test-Path -LiteralPath $names)) {
      $res.Blind = @(('{0} does not exist at {1}, so a deleted case could not be seen; the battery was not run' -f $NamesRel, $Sha))
      return $res
    }
    $argLine = $ArgTemplate.Replace('{checkout}', $res.Checkout).Replace('{names}', $names)
    $work = if ($WorkDirRel) { Join-Path $res.Checkout $WorkDirRel } else { $res.Checkout }
    $run = Invoke-TreeProcess -Exe $Exe -ArgLine $argLine -WorkDir $work -GuardSec $GuardSec -KillWhen $KillWhen
    $res.Ran = $true; $res.ExitCode = $run.ExitCode; $res.TimedOut = $run.TimedOut; $res.Seconds = $run.Seconds
    $res.Output = $run.Out; $res.Err = $run.Err
    $post = Get-CheckoutStatus -Dir $res.Checkout
    $res.StatusAfter = $post.Lines
    $v = Get-BatteryVerdict -ExitCode $run.ExitCode -Output $run.Out -StatusLines $post.Lines -TimedOut $run.TimedOut -PipeHeld $run.PipeHeld
    $blind = @($v.Blind)
    if ($post.Rc -ne 0) { $blind += ('git status could not run in the checkout after the battery (exit {0}), so whether it wrote into the tree is unknown' -f $post.Rc) }
    $res.Hard = @($v.Hard); $res.Blind = $blind
    $res.Code = if ($res.Hard.Count) { 2 } elseif ($res.Blind.Count) { 3 } else { 0 }
    $res.Cases = $v.Cases; $res.Removed = $v.Removed; $res.Added = $v.Added; $res.Red = $v.Red
    return $res
  } finally {
    $rm = Remove-BatteryCheckout -RepoDir $RepoDir -Dir $res.Checkout
    $res.CheckoutLeft = $rm.Left; $res.CleanupNotes = $rm.Notes
  }
}

function Read-GreenStamp {
  param([string]$Path)
  try { if (Test-Path -LiteralPath $Path) { return ([IO.File]::ReadAllText($Path) | ConvertFrom-Json) } } catch { }
  return $null
}

function Format-Count {
  param($Value)
  if ($null -eq $Value) { return '?' }
  return [string]$Value
}

# ======================================================================================================== self-test
if ($SelfTest) {
  $script:stFail = 0; $script:stRan = 0
  function Assert-Case([string]$Name, [bool]$Ok, $Got = '') {
    $script:stRan++
    if ($Ok) { Write-Output ('ok    ' + $Name) } else { Write-Output ('FAIL  ' + $Name + '   got: ' + $Got); $script:stFail++ }
  }
  function Show-Verdict($V) { return ('code={0} cases={1} removed={2} added={3} hard=[{4}] blind=[{5}]' -f $V.Code, $V.Cases, $V.Removed, $V.Added, (@($V.Hard) -join ' | '), (@($V.Blind) -join ' | ')) }

  # PER-RUN SCRATCH (ops-and-gates.md, 2026-09-11): run-gates runs this from concurrent pushes in one %TEMP%.
  $st = Join-Path $env:TEMP ('tcdb-st-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  try {
    # ---- the verdict, over output shaped exactly as hunt_daemon_selftest.py and hunt_lib.names_report print it --
    $marker = 'HUNT-DAEMON-COMPLETE'
    $greenOut = @('  ok    a case that passed', '', '  548 case(s) ran', '  vs C:\t\names.txt: 0 removed, 1 added',
                  '    +  a case the reference does not pin yet', '', 'hunt-daemon SELF-TEST PASS', $marker)
    $v = Get-BatteryVerdict -ExitCode 0 -Output $greenOut -StatusLines @()
    Assert-Case 'CLEAN TWIN  a green battery reads 0, and its counts come back: 548 cases, 0 removed, 1 added' `
      (($v.Code -eq 0) -and ($v.Cases -eq 548) -and ($v.Removed -eq 0) -and ($v.Added -eq 1)) (Show-Verdict $v)

    $goneOut = @('  ok    a case that passed', '  547 case(s) ran', '  vs C:\t\names.txt: 1 removed, 0 added',
                 '    -  price hold releases when upstream goes idle', '',
                 '  A CASE THAT VANISHED IS NOT A PASS. 1 case name(s) in the reference did not run.', '',
                 'hunt-daemon SELF-TEST: every case that RAN passed, and the pinned reference names cases that did not run', $marker)
    $v = Get-BatteryVerdict -ExitCode 2 -Output $goneOut
    Assert-Case 'MUST FIRE  a case deleted from the battery is exit 2 and NAMES the case, though every case that ran passed' `
      (($v.Code -eq 2) -and ((@($v.Hard) -join ' ') -like '*price hold releases when upstream goes idle*')) (Show-Verdict $v)

    $redOut = @('  ok    a case that passed', '  X     F1 concurrent FDC fills union   got: one fill lost', '  548 case(s) ran',
                '  vs C:\t\names.txt: 0 removed, 0 added', 'hunt-daemon SELF-TEST FAIL (1)', $marker)
    $v = Get-BatteryVerdict -ExitCode 2 -Output $redOut
    Assert-Case 'MUST FIRE  a red case is exit 2 and names the case' `
      (($v.Code -eq 2) -and ((@($v.Hard) -join ' ') -like '*F1 concurrent FDC fills union*')) (Show-Verdict $v)

    $v = Get-BatteryVerdict -ExitCode 2 -Output $greenOut
    Assert-Case 'MUST FIRE  EXIT CODE FIRST: a nonzero exit is a finding even when the output reads PASS with nothing removed' `
      ($v.Code -eq 2) (Show-Verdict $v)

    $diedOut = @($greenOut[0..($greenOut.Count - 2)]) + @('Traceback (most recent call last):')
    $v = Get-BatteryVerdict -ExitCode 0 -Output $diedOut
    Assert-Case 'MUST FIRE  exit 0 with no completion marker as the LAST line is could-not-evaluate, never green' `
      ($v.Code -eq 3) (Show-Verdict $v)

    # THE FOUNDING DEFECT, frozen: 2026-09-11, the battery rewrote this tracked file on every run and exited 0.
    $v = Get-BatteryVerdict -ExitCode 0 -Output $greenOut -StatusLines @(' M meal-prep/db/fdc-cache.json')   # reach-fixture-ok: a git status line quoted as input, opened by nothing here
    Assert-Case 'MUST FIRE  a green battery that left a tracked file modified is exit 2 and names the file' `
      (($v.Code -eq 2) -and ((@($v.Hard) -join ' ') -like '*meal-prep/db/fdc-cache.json*')) (Show-Verdict $v)   # reach-fixture-ok: matches the quoted line above

    $v = Get-BatteryVerdict -ExitCode 0 -Output @('  548 case(s) ran', 'hunt-daemon SELF-TEST PASS', $marker)
    Assert-Case 'MUST FIRE  exit 0 with no case-name diff line (run without its reference) is could-not-evaluate' `
      ($v.Code -eq 3) (Show-Verdict $v)

    $cannotOut = @('  548 case(s) ran', '  CANNOT DIFF - no reference at C:\t\names.txt (missing)',
                   'hunt-daemon SELF-TEST: every case that RAN passed, and the pinned reference names cases that did not run', $marker)
    $v = Get-BatteryVerdict -ExitCode 2 -Output $cannotOut
    Assert-Case 'MUST FIRE  a names diff that could not run is could-not-evaluate, not a removal and not a pass' `
      (($v.Code -eq 3) -and ((@($v.Blind) -join ' ') -like '*no reference at*')) (Show-Verdict $v)

    $v = Get-BatteryVerdict -ExitCode 1 -Output @('  ok    a case that passed') -TimedOut $true
    Assert-Case 'MUST FIRE  a battery the hang guard killed is could-not-evaluate' ($v.Code -eq 3) (Show-Verdict $v)

    $v = Get-BatteryVerdict -ExitCode 1 -Output @('  ok    a case') -StatusLines @('?? meal-prep/db/stray.tmp') -TimedOut $true   # reach-fixture-ok: an invented status line, no such file
    Assert-Case 'MUST FIRE  a proven write into the tree is exit 2 even beside a killed run, and the kill is still reported' `
      (($v.Code -eq 2) -and (@($v.Blind).Count -ge 1)) (Show-Verdict $v)

    # ---- end to end: a real temp repository, a real throwaway checkout, a fake battery ---------------------------
    New-Item -ItemType Directory -Path $st -ErrorAction Stop | Out-Null
    $src = Join-Path $st 'repo'
    New-Item -ItemType Directory -Path (Join-Path $src 'data') -Force -ErrorAction Stop | Out-Null
    $utf8 = New-Object Text.UTF8Encoding($false)
    $fake = @'
param([string]$Mode = 'clean', [string]$Names = '', [string]$PidDir = '')
[IO.File]::WriteAllText((Join-Path $PidDir 'parent.tmp'), [string]$PID)
Move-Item -LiteralPath (Join-Path $PidDir 'parent.tmp') -Destination (Join-Path $PidDir 'parent.pid') -Force
if ($Mode -eq 'hang') {
  $t = Join-Path $PidDir 'child.tmp'; $f = Join-Path $PidDir 'child.pid'
  & powershell.exe -NoProfile -Command ("[IO.File]::WriteAllText('" + $t + "', [string]`$PID); Move-Item -LiteralPath '" + $t + "' -Destination '" + $f + "'; Start-Sleep -Seconds 600")
  exit 0
}
if ($Mode -eq 'dirty') { [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'data\tracked.txt'), "written by a fixture`n") }
'  ok    fixture case'
'  1 case(s) ran'
('  vs ' + $Names + ': 0 removed, 0 added')
''
'hunt-daemon SELF-TEST PASS'
'HUNT-DAEMON-COMPLETE'
exit 0
'@
    [IO.File]::WriteAllText((Join-Path $src 'battery.ps1'), $fake, $utf8)
    [IO.File]::WriteAllText((Join-Path $src 'names.txt'), "fixture case`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $src 'data\tracked.txt'), "fixture`n", $utf8)
    $id = @('-c', 'user.name=battery-selftest', '-c', 'user.email=battery@selftest.invalid', '-c', 'commit.gpgsign=false', '-c', 'core.autocrlf=false')
    $g1 = Invoke-GitCaptured -Repo $src -GitArgs @('init', '-q')
    $g2 = Invoke-GitCaptured -Repo $src -GitArgs ($id + @('add', '--', 'battery.ps1', 'names.txt', 'data/tracked.txt'))
    $g3 = Invoke-GitCaptured -Repo $src -GitArgs ($id + @('commit', '-q', '-m', 'fixture'))
    $g4 = Invoke-GitCaptured -Repo $src -GitArgs @('rev-parse', 'HEAD')
    if (($g1.rc -ne 0) -or ($g2.rc -ne 0) -or ($g3.rc -ne 0) -or ($g4.rc -ne 0)) {
      throw ('the fixture repository could not be built: init {0}, add {1}, commit {2} ({3}), rev-parse {4}' -f $g1.rc, $g2.rc, $g3.rc, ([string]$g3.stderr).Trim(), $g4.rc)
    }
    $fxSha = ([string]$g4.stdout).Trim()
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    function New-FakeArgs([string]$Mode, [string]$PidDir) {
      New-Item -ItemType Directory -Path $PidDir -ErrorAction Stop | Out-Null
      return ('-NoProfile -ExecutionPolicy Bypass -File "{checkout}\battery.ps1" -Mode ' + $Mode + ' -Names "{names}" -PidDir "' + $PidDir + '"')
    }

    $pd = Join-Path $st 'p1'
    $e = Invoke-DaemonBattery -RepoDir $src -Sha $fxSha -Exe $psExe -ArgTemplate (New-FakeArgs 'clean' $pd) -NamesRel 'names.txt' -GuardSec 120 -TempRoot $st
    $wl = Invoke-GitCaptured -Repo $src -GitArgs @('worktree', 'list', '--porcelain')
    $wtLines = @((([string]$wl.stdout) -split "`n") | Where-Object { $_ -like 'worktree *' })
    Assert-Case 'CLEAN TWIN  a green fake battery in a real throwaway checkout reads 0, and the checkout and its registration are gone afterwards' `
      (($e.Code -eq 0) -and ($e.Cases -eq 1) -and -not $e.CheckoutLeft -and ($wtLines.Count -eq 1) -and -not (Test-Path -LiteralPath $e.Checkout)) `
      ((Show-Verdict $e) + (' left={0} worktrees={1} err={2}' -f $e.CheckoutLeft, $wtLines.Count, $e.Err))

    $pd = Join-Path $st 'p2'
    $e = Invoke-DaemonBattery -RepoDir $src -Sha $fxSha -Exe $psExe -ArgTemplate (New-FakeArgs 'dirty' $pd) -NamesRel 'names.txt' -GuardSec 120 -TempRoot $st
    Assert-Case 'MUST FIRE  a fake battery that writes a tracked file and exits 0 is exit 2 through the real git status, naming the file, and the checkout is still removed' `
      (($e.Code -eq 2) -and ((@($e.Hard) -join ' ') -like '*data/tracked.txt*') -and -not $e.CheckoutLeft) ((Show-Verdict $e) + ' left=' + $e.CheckoutLeft)

    $pd = Join-Path $st 'p3'
    $e = Invoke-DaemonBattery -RepoDir $src -Sha $fxSha -Exe $psExe -ArgTemplate (New-FakeArgs 'clean' $pd) -NamesRel 'no-such-names.txt' -GuardSec 120 -TempRoot $st
    Assert-Case 'MUST FIRE  a commit with no pinned reference is could-not-evaluate and the battery is never started' `
      (($e.Code -eq 3) -and -not $e.Ran -and -not (Test-Path -LiteralPath (Join-Path $pd 'parent.pid'))) ((Show-Verdict $e) + ' ran=' + $e.Ran)

    # THE TREE KILL, ended on an EVENT: the kill fires once the grandchild has written its pid, never on a clock.
    $pd = Join-Path $st 'p4'
    $childPid = Join-Path $pd 'child.pid'
    $when = { Test-Path -LiteralPath $childPid }.GetNewClosure()
    $e = Invoke-DaemonBattery -RepoDir $src -Sha $fxSha -Exe $psExe -ArgTemplate (New-FakeArgs 'hang' $pd) -NamesRel 'names.txt' -GuardSec 120 -TempRoot $st -KillWhen $when
    $alive = @()
    foreach ($pf in @((Join-Path $pd 'parent.pid'), $childPid)) {
      if (-not (Test-Path -LiteralPath $pf)) { $alive += ('no pid file ' + $pf); continue }
      $procId = [int]([IO.File]::ReadAllText($pf).Trim())
      Wait-Process -Id $procId -Timeout 30 -ErrorAction SilentlyContinue   # a hang guard on the kill landing, not a verdict
      if (Get-Process -Id $procId -ErrorAction SilentlyContinue) { $alive += ('pid ' + $procId + ' still running') }
    }
    Assert-Case 'MUST FIRE  a hung battery is killed with its GRANDCHILD, which holds the output pipe, and the read still returns' `
      ($e.TimedOut -and ($e.Code -eq 3) -and ($alive.Count -eq 0)) ((Show-Verdict $e) + ' timedOut=' + $e.TimedOut + ' ' + ($alive -join '; '))

    # AND THE REAL CLOCK, with no seam: what the swap above gives up. Asserts the guard ENDS in a kill, never how long.
    $pd = Join-Path $st 'p5'
    $e = Invoke-DaemonBattery -RepoDir $src -Sha $fxSha -Exe $psExe -ArgTemplate (New-FakeArgs 'hang' $pd) -NamesRel 'names.txt' -GuardSec 1 -TempRoot $st
    Assert-Case 'CLEAN TWIN  the unswapped hang guard still ends a battery that never finishes in a kill' `
      ($e.TimedOut -and ($e.Code -eq 3)) ((Show-Verdict $e) + ' timedOut=' + $e.TimedOut)
  } catch {
    $script:stFail++
    Write-Output ('FAIL  the self-test threw at line {0}: {1}' -f $_.InvocationInfo.ScriptLineNumber, $_.Exception.Message)
  } finally {
    Remove-Item -LiteralPath $st -Recurse -Force -ErrorAction SilentlyContinue
  }
  # A FLOOR ON CASES RUN: a self-test that errors past its cases must not read as a pass over fewer of them.
  if ($script:stRan -lt 15) { $script:stFail++; Write-Output ('FAIL  only {0} of 15 cases ran' -f $script:stRan) }
  if ($script:stFail) { Write-Output ('run-daemon-battery SELF-TEST FAIL ({0} failure(s), {1} case(s) ran)' -f $script:stFail, $script:stRan); exit 1 }
  Write-Output ('run-daemon-battery SELF-TEST PASS ({0} of {0}: the verdict over green, deleted-case, red-case, exit-code-first, no-marker, founding fdc-cache write, no-reference, cannot-diff, killed and killed-but-dirty output; then a real throwaway checkout of a temp repository driving a fake battery green, dirty, with no reference, hung with a pipe-holding grandchild killed on an event, and hung under the real clock)' -f $script:stRan)
  exit 0
}

# ============================================================================================================ a run
$script:RunLog = Start-RunLog -Name 'daemon-battery' -OutDir (Join-Path $repo 'ops\out')
$code = 1   # what the transcript records if anything below throws: a crash is never rc 0
$summary = ''
$lease = $null
try {
  $lease = Enter-TcGateSlots -Want $script:SlotWant -WaitSec $script:SlotWaitSec -OnWait {
    'daemon-battery: every slot of the machine-wide gate budget is held; waiting for one rather than running over it'
  }
  if ($lease.TimedOut) {
    Write-Output ('DAEMON BATTERY COULD NOT EVALUATE: no gate slot came free in {0} s, and running over the machine-wide budget is the pile-up that budget exists to stop' -f $script:SlotWaitSec)
    $code = 3; $summary = 'blind=no-slot'
  } else {
    if (-not $NoFetch) {
      $f = Invoke-GitCaptured -Repo $repo -GitArgs @('fetch', '-q', 'origin')
      if ($f.rc -ne 0) { Write-Output ('daemon-battery: git fetch origin exited {0}, so {1} is tested as this box last saw it: {2}' -f $f.rc, $Commit, ([string]$f.stderr).Trim()) }
    }
    $rv = Invoke-GitCaptured -Repo $repo -GitArgs @('rev-parse', '--verify', '-q', ($Commit + '^{commit}'))
    if ($rv.rc -ne 0) {
      Write-Output ("DAEMON BATTERY COULD NOT EVALUATE: '{0}' does not resolve to a commit in {1}" -f $Commit, $repo)
      $code = 3; $summary = 'blind=no-commit'
    } else {
      $sha = ([string]$rv.stdout).Trim()
      $last = Read-GreenStamp -Path $script:StampPath
      Write-Output ('daemon-battery: {0} = {1}, in a throwaway checkout under {2}, {3} gate slot(s), hang guard {4} s' -f $Commit, $sha, $env:TEMP, $lease.Count, $script:HangGuardSec)
      $r = Invoke-DaemonBattery -RepoDir $repo -Sha $sha -Exe $script:PythonExe -ArgTemplate $script:BatteryArgs `
             -WorkDirRel 'meal-prep\pipeline' -NamesRel $script:NamesRel -GuardSec $script:HangGuardSec
      if ($r.Ran) {
        Write-Output '--- battery stdout ---'
        foreach ($ln in @($r.Output)) { Write-Output $ln }
        if (([string]$r.Err).Trim()) { Write-Output '--- battery stderr ---'; Write-Output ([string]$r.Err).TrimEnd() }
        Write-Output '--- end of battery output ---'
      }
      Write-Output ('  commit tested  : {0} ({1})' -f $sha, $Commit)
      if ($r.Ran) {
        $killedNote = if ($r.TimedOut) { ' - KILLED by the hang guard' } else { '' }
        Write-Output ('  battery exit   : {0} after {1} s{2}' -f (Format-Count $r.ExitCode), [int]$r.Seconds, $killedNote)
      } else {
        Write-Output '  battery exit   : not run'
      }
      Write-Output ('  case names     : {0} ran; against the pinned reference {1} removed, {2} added' -f (Format-Count $r.Cases), (Format-Count $r.Removed), (Format-Count $r.Added))
      Write-Output ('  checkout after : {0} status line(s); checkout removed: {1}' -f @($r.StatusAfter).Count, (-not $r.CheckoutLeft))
      foreach ($n in @($r.CleanupNotes)) { Write-Output ('  WARN   ' + $n) }
      foreach ($h in @($r.Hard)) { Write-Output ('  HARD   ' + $h) }
      foreach ($b in @($r.Blind)) { Write-Output ('  BLIND  ' + $b) }
      $code = [int]$r.Code
      $summary = ('commit={0} exit={1} cases={2} removed={3} added={4} status={5} hard={6} blind={7}' -f $sha.Substring(0, 9), (Format-Count $r.ExitCode), (Format-Count $r.Cases), (Format-Count $r.Removed), (Format-Count $r.Added), @($r.StatusAfter).Count, @($r.Hard).Count, @($r.Blind).Count)
      if ($code -eq 0) {
        try {
          $d = Split-Path $script:StampPath -Parent
          if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
          $stamp = [ordered]@{ commit = $sha; ref = $Commit; tested_at = (Get-Date).ToString('s'); cases = $r.Cases
                               removed = $r.Removed; added = $r.Added; battery_seconds = [int]$r.Seconds; runner = 'ops\run-daemon-battery.ps1' }
          [IO.File]::WriteAllText($script:StampPath, ($stamp | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
        } catch { Write-Output ('  WARN   the green stamp could not be written ({0}); the exit code still reads 0' -f $_.Exception.Message) }
        Write-Output ('DAEMON BATTERY GREEN: {0} case(s) at {1}, every pinned case name ran, and the checkout was clean afterwards' -f $r.Cases, $sha.Substring(0, 9))
        if ($r.Added -gt 0) {
          Write-Output ('  {0} case(s) ran that the reference does not pin, so deleting one of them would not be seen. Re-pin: see this file''s header.' -f $r.Added)
        }
      } else {
        $word = if ($code -eq 2) { 'RED' } else { 'COULD NOT EVALUATE' }
        Write-Output ('DAEMON BATTERY {0} at {1}: {2} hard finding(s), {3} blind reason(s), listed above' -f $word, $sha.Substring(0, 9), @($r.Hard).Count, @($r.Blind).Count)
        if ($last -and $last.commit) {
          Write-Output ('  last green     : {0} at {1}' -f $last.commit, $last.tested_at)
          $lg = Invoke-GitCaptured -Repo $repo -GitArgs @('log', '--oneline', '-20', ([string]$last.commit + '..' + $sha), '--', 'meal-prep/pipeline')
          if ($lg.rc -eq 0) {
            Write-Output '  commits since then that touch meal-prep/pipeline (newest 20):'
            $lgLines = ConvertTo-TcOutputLines ([string]$lg.stdout)
            foreach ($ln in @($lgLines)) { if (([string]$ln).Trim()) { Write-Output ('    ' + $ln) } }
          }
        } else {
          Write-Output '  last green     : none recorded on this box'
        }
      }
    }
  }
} finally {
  if ($lease) { Exit-TcGateSlots $lease }
  Stop-RunLog -ExitCode $code -Path $script:RunLog
}
Exit-Guard -Name 'DAEMON-BATTERY' -Code $code -Summary $summary
