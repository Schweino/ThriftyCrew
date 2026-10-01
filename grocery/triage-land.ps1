<#
  triage-land.ps1 - land a triage run's commits with NO model waiting on it, and say in one line what happened.

  WHY THIS EXISTS (2026-09-24, design/PLAN-triage-lean-2026-09-24.md). Measured over three triage sessions, 75 to 83%
  of all cache WRITES were full re-writes of an agent's context after an idle gap of more than five minutes (median
  about 9 minutes on 09-19: 13 of the 16 big re-writes) - an agent holding a 300k to 600k context and waiting on
  run-gates, a push or the chain, then paying to re-cache all of it. On 09-19 that was about a quarter of the run.
  The wait itself is deterministic work (ops\push-main.ps1 gates, rebases and lands), so it runs here, as a plain
  process, and the agents commit and exit instead of waiting. The orchestrator runs this ONCE per run, in the
  background, and reads only the TRIAGE-LAND-COMPLETE line.

  IT WEAKENS NOTHING: it runs ops\push-main.ps1, whose pre-push hook runs every gate, and a red gate refuses exactly
  as it would for anyone. It never retries a refusal: a second attempt is the orchestrator's call, made once.

  Run:       powershell -NoProfile -File grocery\triage-land.ps1 [-CheckFeed] [-Park -RunBase <sha>]
             -CheckFeed  after a landing, run grocery\audit-feed-week-parity.ps1 (the board and the feed must quote the
                         SAME week; the Worker lags a push by about 90 s, so it is tried up to 3 times, 60 s apart)
             -Park       on a refusal, move the run's commits (RunBase..HEAD) to triage/<day>-unlanded and reset main to
                         RunBase, under the capture-run mutex; only on branch main, never over a bot commit. Pass it on
                         the run's LAST allowed landing. -RunBase is the HEAD the orchestrator recorded at STEP 0.5.
             A refusal from run-gates also runs the test-auditors leg push-main never reached, so ONE refusal names
             every red (TRIAGE-LAND-COMPLETE gains second_leg=pass|fail|blind|n/a).
  Rehearse:  powershell -NoProfile -File grocery\triage-land.ps1 -Rehearse
             runs run-gates AND test-auditors on HEAD at once, each in its own seeded detached worktree, pushes nothing,
             and ends TRIAGE-REHEARSE-COMPLETE gates=<v> ta=<v>. The orchestrator starts it in the background as soon as
             the money lane commits, so its reds are fixed before the landing rather than discovered by it.
  Self-test: powershell -NoProfile -File grocery\triage-land.ps1 -SelfTest
  Exit: 0 landed (or nothing to land), 1 refused, 3 could not evaluate. The full push-main output goes to a log whose
  path the last line names; read that only when the outcome is not `landed`.
#>
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop (2026-09-07)
param(
  [switch]$CheckFeed,
  [switch]$Rehearse,
  [switch]$Park,
  [string]$RunBase = '',
  [switch]$SelfTest,
  [string]$PushScript = '',
  [string]$LogDir = ''
)
$ErrorActionPreference = 'Stop'
# The self-test is pure over in-file lines and a fixture push script it writes to temp; it reads no repo file but this one.
# gate-inputs: grocery\triage-land.ps1
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\grocery' }
$repo = Split-Path $here -Parent

function Get-TcLandOutcome {
  <# Pure. push-main's exit code and output -> outcome. The words decide, never the code alone: push-main's own
     vocabulary is LANDED / REFUSED / COULD NOT EVALUATE, and a run that printed none of them is BLIND whatever it
     exited with. #>
  param([string[]]$Lines, [int]$Code)
  $said = @($Lines | Where-Object { $_ -match '^push-main: (LANDED|REFUSED|COULD NOT EVALUATE)' })
  if ($said.Count -eq 0) { return [pscustomobject]@{ Outcome = 'blind'; Sha = ''; Line = 'push-main printed no LANDED, REFUSED or COULD NOT EVALUATE line'; Rc = 3 } }
  $last = [string]$said[$said.Count - 1]
  if ($last -match '^push-main: LANDED on \S+ at ([0-9a-f]{7,40})') {
    if ($Code -ne 0) { return [pscustomobject]@{ Outcome = 'blind'; Sha = $Matches[1]; Line = "push-main said LANDED but exited $Code"; Rc = 3 } }
    return [pscustomobject]@{ Outcome = 'landed'; Sha = $Matches[1]; Line = $last; Rc = 0 }
  }
  if ($last -match '^push-main: REFUSED') { return [pscustomobject]@{ Outcome = 'refused'; Sha = ''; Line = $last; Rc = 1 } }
  return [pscustomobject]@{ Outcome = 'blind'; Sha = ''; Line = $last; Rc = 3 }
}

function Invoke-TcLandChild {
  <# Runs a PowerShell script as a child with its whole output going to a log, and returns the exit code and the
     lines. stderr goes to the same log through cmd so no redirect of a native child happens under EAP=Stop. #>
  param([string]$Script, [string]$Log, [string]$WorkDir, [string[]]$ScriptArgs = @())
  $argLine = '/c powershell -NoProfile -ExecutionPolicy Bypass -File "' + $Script + '"'
  foreach ($a in $ScriptArgs) { $argLine += ' ' + $a }
  $argLine += ' > "' + $Log + '" 2>&1'
  $p = Start-Process -FilePath 'cmd.exe' -ArgumentList $argLine -WorkingDirectory $WorkDir -NoNewWindow -Wait -PassThru
  $lines = @()
  if (Test-Path -LiteralPath $Log) { $lines = @([IO.File]::ReadAllLines($Log)) }
  return [pscustomobject]@{ Code = [int]$p.ExitCode; Lines = $lines }
}

# ---- BOTH LEGS, ONE REFUSAL (2026-10-01). push-main runs run-gates and THEN test-auditors, so a red run-gates hides
# every test-auditors red until the next attempt. On 2026-10-01 landing 1 was refused on 8 gates; they were fixed,
# and landing 2 was refused on 5 test-auditors cases nobody had seen. The SKILL allows one re-land, so the run ended
# unlanded with the second layer's cause found only after the budget was spent. Here each leg runs in its OWN
# detached worktree (one shared tree would let one leg's writes trip the other's gate-leftovers check), at once.
function Get-TcLegVerdict {
  <# Pure. One leg's exit code and output -> {Leg, Verdict pass|fail|blind, Failed}. A leg passes only with its own
     completion marker AND exit 0; a missing marker is blind whatever the code said. #>
  param([string]$Leg, [string[]]$Lines, [int]$Code)
  $failed = New-Object System.Collections.Generic.List[string]
  if ($Leg -eq 'gates') {
    $m = @($Lines | Where-Object { $_ -match '^RUN-GATES-COMPLETE pass=\d+ fail=(\d+)' })
    foreach ($l in $Lines) { if ($l -match '^\s+failed:\s+(.+)$') { [void]$failed.Add($Matches[1].Trim()) } }
    if ($m.Count -eq 0) { return [pscustomobject]@{ Leg = $Leg; Verdict = 'blind'; Failed = $failed.ToArray() } }
    if ($Code -eq 0) { return [pscustomobject]@{ Leg = $Leg; Verdict = 'pass'; Failed = @() } }
    if ($Code -eq 1) { return [pscustomobject]@{ Leg = $Leg; Verdict = 'fail'; Failed = $failed.ToArray() } }
    return [pscustomobject]@{ Leg = $Leg; Verdict = 'blind'; Failed = $failed.ToArray() }
  }
  if ($Leg -eq 'ta') {
    $nonEmpty = @($Lines | Where-Object { $_ -and $_.Trim() })
    $complete = ($nonEmpty.Count -gt 0) -and ([string]$nonEmpty[$nonEmpty.Count - 1] -match '^PREPUSH-TEST-AUDITORS-COMPLETE')
    foreach ($l in $Lines) { if ($l -match 'NEW FAILING CASE\s+(.+)$') { $t = $Matches[1].Trim(); [void]$failed.Add($t.Substring(0, [Math]::Min(200, $t.Length))) } }
    if (-not $complete) { return [pscustomobject]@{ Leg = $Leg; Verdict = 'blind'; Failed = $failed.ToArray() } }
    if ($Code -eq 0) { return [pscustomobject]@{ Leg = $Leg; Verdict = 'pass'; Failed = @() } }
    if ($Code -eq 1) { return [pscustomobject]@{ Leg = $Leg; Verdict = 'fail'; Failed = $failed.ToArray() } }
    return [pscustomobject]@{ Leg = $Leg; Verdict = 'blind'; Failed = $failed.ToArray() }
  }
  throw "unknown leg: $Leg"
}

function Invoke-TcGitQuiet {
  <# git under EAP=Continue (a native stderr line must never throw here); returns {Code, Out}. #>
  param([string]$Dir, [string[]]$GitArgs)
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $o = @(& git -C $Dir @GitArgs 2>$null); return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $o } }
  finally { $ErrorActionPreference = $prev }
}

function Invoke-TcLandLegs {
  <# Runs the named legs (gates, ta) of HEAD of $Repo at once, each in its own seeded detached worktree, and returns
     one Get-TcLegVerdict per leg. Nothing is pushed. A worktree that cannot be made or seeded is that leg BLIND. #>
  param([string]$Repo, [string]$LogDir, [string]$Stamp, [string[]]$Legs)
  $head = ([string]@((Invoke-TcGitQuiet $Repo @('rev-parse', 'HEAD')).Out)[0]).Trim()
  $base = ([string]@((Invoke-TcGitQuiet $Repo @('rev-parse', 'origin/main')).Out)[0]).Trim()
  $runs = @()
  foreach ($leg in $Legs) {
    $wt = Join-Path $Repo ('.claude\worktrees\tland-' + $leg + '-' + $Stamp)
    $log = Join-Path $LogDir ('leg-' + $leg + '-' + $Stamp + '.log')
    $add = Invoke-TcGitQuiet $Repo @('worktree', 'add', '--detach', $wt, $head)
    if ($add.Code -ne 0) { $runs += [pscustomobject]@{ Leg = $leg; Wt = $null; Log = $log; Proc = $null; Why = 'worktree add failed' }; continue }
    $seed = Invoke-TcLandChild -Script (Join-Path $wt 'ops\seed-worktree.ps1') -Log ($log + '.seed') -WorkDir $wt -ScriptArgs @('-Target', ('"' + $wt + '"'))
    if ($seed.Code -ne 0) { $runs += [pscustomobject]@{ Leg = $leg; Wt = $wt; Log = $log; Proc = $null; Why = 'seed-worktree exited ' + $seed.Code }; continue }
    if ($leg -eq 'gates') {
      $argLine = '/c powershell -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $wt 'ops\run-gates.ps1') + '" > "' + $log + '" 2>&1'
    } else {
      $refIn = $log + '.ref'
      [IO.File]::WriteAllText($refIn, ('HEAD ' + $head + ' refs/heads/main ' + $base + "`n"), (New-Object Text.UTF8Encoding($false)))
      $argLine = '/c powershell -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $wt 'ops\prepush-test-auditors.ps1') + '" -RefsFromStdin < "' + $refIn + '" > "' + $log + '" 2>&1'
    }
    $p = Start-Process -FilePath 'cmd.exe' -ArgumentList $argLine -WorkingDirectory $wt -NoNewWindow -PassThru
    $null = $p.Handle
    $runs += [pscustomobject]@{ Leg = $leg; Wt = $wt; Log = $log; Proc = $p; Why = '' }
  }
  $out = @()
  foreach ($r in $runs) {
    if ($null -eq $r.Proc) { $out += [pscustomobject]@{ Leg = $r.Leg; Verdict = 'blind'; Failed = @($r.Why); Log = $r.Log } }
    else {
      $r.Proc.WaitForExit()
      $lines = @(); if (Test-Path -LiteralPath $r.Log) { $lines = @([IO.File]::ReadAllLines($r.Log)) }
      $v = Get-TcLegVerdict -Leg $r.Leg -Lines $lines -Code ([int]$r.Proc.ExitCode)
      $out += [pscustomobject]@{ Leg = $v.Leg; Verdict = $v.Verdict; Failed = $v.Failed; Log = $r.Log }
    }
    if ($r.Wt) {
      $null = Invoke-TcGitQuiet $Repo @('worktree', 'remove', '--force', $r.Wt)
      # a half-removed worktree resolves to the MAIN checkout for git; never leave a husk behind
      if (Test-Path -LiteralPath $r.Wt) { Remove-Item -LiteralPath $r.Wt -Recurse -Force -ErrorAction SilentlyContinue; $null = Invoke-TcGitQuiet $Repo @('worktree', 'prune') }
    }
  }
  return ,$out
}

function Write-TcLegLines {
  param([object[]]$Verdicts)
  foreach ($v in $Verdicts) {
    Write-Output ('  leg ' + $v.Leg + ': ' + $v.Verdict.ToUpper() + $(if (@($v.Failed).Count) { ' - ' + @($v.Failed).Count + ' red' } else { '' }) + '  (log ' + $v.Log + ')')
    foreach ($f in @($v.Failed)) { Write-Output ('    ' + $f) }
  }
}

# ---- PARK A REFUSED RUN OFF main (2026-10-01). Commits a run cannot land do not stay on the production checkout's
# main: the 08:00 bot pushes main, so they would ride out with its push or get it refused. Brad's CLAUDE.md: "A
# COMMIT YOU ARE NOT READY TO PUSH DOES NOT GO ON main". Until this, the orchestrator parked by hand (09-30 and
# 10-01, both by hand). It parks only the run's own commits (RunBase..HEAD), never one the bot made.
function Test-TcParkAllowed {
  <# Pure. The subjects of RunBase..HEAD -> '' when parking is safe, else why not. A bot commit ([daily] / [ad])
     inside the range means resetting would take the bot's work off main: refuse and say so. #>
  param([string[]]$Subjects)
  $s = @($Subjects | Where-Object { $_ })
  if ($s.Count -eq 0) { return 'no commits between the run base and HEAD' }
  $bot = @($s | Where-Object { $_ -match '\[(daily|ad)\]\s*$' })
  if ($bot.Count) { return ('a bot commit sits inside the range (' + $bot[0] + '); park by hand') }
  return ''
}

if ($SelfTest) {
  $fail = 0; $ran = 0
  function _T([string]$Label, [bool]$Ok, $Got) {
    $script:ran++
    if ($Ok) { Write-Output "ok    $Label" } else { Write-Output ("FAIL  $Label  got=" + $Got); $script:fail++ }
  }
  $o = Get-TcLandOutcome @('run-gates: ...', 'push-main: LANDED on origin/main at fc55f4f29, on the first attempt, after 1 rehearsal round(s).') 0
  _T 'CLEAN TWIN: a LANDED line with exit 0 is landed and carries its sha' (($o.Outcome -eq 'landed') -and ($o.Sha -eq 'fc55f4f29') -and ($o.Rc -eq 0)) ($o.Outcome + ' ' + $o.Sha)
  $o = Get-TcLandOutcome @('push-main: REFUSED - run-gates exited 1 before the lock was taken') 1
  _T 'MUST FIRE: a REFUSED line is refused, exit 1' (($o.Outcome -eq 'refused') -and ($o.Rc -eq 1)) $o.Outcome
  $o = Get-TcLandOutcome @('some noise', 'RUN-GATES-COMPLETE pass=10 fail=0') 0
  _T 'MUST FIRE: exit 0 with no push-main verdict line is BLIND, never landed' (($o.Outcome -eq 'blind') -and ($o.Rc -eq 3)) $o.Outcome
  $o = Get-TcLandOutcome @('push-main: LANDED on origin/main at abc1234, on the first attempt') 1
  _T 'MUST FIRE: a LANDED line with a non-zero exit is BLIND, not landed' (($o.Outcome -eq 'blind') -and ($o.Rc -eq 3)) $o.Outcome
  $o = Get-TcLandOutcome @('push-main: COULD NOT EVALUATE - blind=fetch') 3
  _T 'MUST FIRE: COULD NOT EVALUATE is blind, exit 3' (($o.Outcome -eq 'blind') -and ($o.Rc -eq 3)) $o.Outcome
  # the child runner, end to end, against a fixture push script in a per-run temp directory
  $tmp = Join-Path $env:TEMP ('tland-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $tmp -ErrorAction Stop | Out-Null
  try {
    $fx = Join-Path $tmp 'fake-push.ps1'
    [IO.File]::WriteAllText($fx, "Write-Output 'gate noise'`r`n[Console]::Error.WriteLine('a warning on stderr')`r`nWrite-Output 'push-main: REFUSED - fixture'`r`nexit 1`r`n")
    $r = Invoke-TcLandChild -Script $fx -Log (Join-Path $tmp 'l.log') -WorkDir $tmp
    $o = Get-TcLandOutcome $r.Lines $r.Code
    _T 'CLEAN TWIN: the child runner keeps stdout and stderr in the log and returns the exit code (refused, 1)' (($o.Outcome -eq 'refused') -and ($r.Code -eq 1) -and (($r.Lines -join "`n") -match 'a warning on stderr')) ($o.Outcome + ' rc=' + $r.Code)
  } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
  # BOTH LEGS (2026-10-01): the founding case is landing 2 of that day, where test-auditors' reds hid behind run-gates'.
  $v = Get-TcLegVerdict 'gates' @('  failed: grocery\test-hold-scope.ps1', '  failed: gate-leftovers', 'RUN-GATES-COMPLETE pass=554 fail=8 noverdict=0') 1
  _T 'MUST FIRE: a red run-gates leg is fail and names each failed gate' (($v.Verdict -eq 'fail') -and (@($v.Failed).Count -eq 2) -and (@($v.Failed)[1] -eq 'gate-leftovers')) ($v.Verdict + ' ' + (@($v.Failed) -join ','))
  $v = Get-TcLegVerdict 'ta' @('  NEW FAILING CASE      the clean twin was REFUSED (rc=1)', 'PREPUSH-TEST-AUDITORS-COMPLETE rc=1') 1
  _T 'MUST FIRE: a red test-auditors leg is fail and names its NEW FAILING CASE' (($v.Verdict -eq 'fail') -and (@($v.Failed)[0] -match '^the clean twin was REFUSED')) ($v.Verdict + ' ' + (@($v.Failed) -join ','))
  $v = Get-TcLegVerdict 'ta' @('PREPUSH-TEST-AUDITORS-COMPLETE rc=0') 0
  _T 'CLEAN TWIN: a test-auditors leg with exit 0 and its marker last is pass' ($v.Verdict -eq 'pass') $v.Verdict
  $v = Get-TcLegVerdict 'gates' @('run-gates: 12 passed') 0
  _T 'MUST FIRE: a gates leg with exit 0 but no RUN-GATES-COMPLETE marker is BLIND, never pass' ($v.Verdict -eq 'blind') $v.Verdict
  $pk = Test-TcParkAllowed @('Triage 2026-10-01 3851d2: a soundness finding ...', 'Daily pipeline: refresh prices + feed (2026-10-01) [daily]')
  _T 'MUST FIRE: parking refuses a range holding a bot [daily] commit' ($pk -match 'bot commit') $pk
  $pk = Test-TcParkAllowed @('Triage 2026-10-01 3851d2: a soundness finding ...', 'triage 2026-10-01: close no-code items')
  _T 'CLEAN TWIN: a range of only the run''s own commits may be parked' ($pk -eq '') $pk
  $expected = 12
  if ($ran -ne $expected) { Write-Output "FAIL  ran $ran case(s), expected $expected"; $fail++ }
  if ($fail -gt 0) { Write-Output "triage-land self-test FAIL ($fail of $ran)"; exit 1 }
  Write-Output "triage-land self-test pass ($ran of $ran)"
  exit 0
}

if (-not $PushScript) { $PushScript = Join-Path $repo 'ops\push-main.ps1' }
if (-not $LogDir) { $LogDir = Join-Path $env:LOCALAPPDATA 'ThriftyCrew\triage-land' }
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
$log = Join-Path $LogDir ("land-" + $stamp + ".log")

$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
  $null = & git -C $repo fetch --quiet origin main 2>&1
  $ahead = [string](& git -C $repo rev-list --count origin/main..HEAD 2>$null)
} finally { $ErrorActionPreference = $prevEap }
if (-not ($ahead -match '^\s*\d+\s*$')) {
  Write-Output ("triage-land: could not count the commits to land in " + $repo)
  Write-Output ("TRIAGE-LAND-COMPLETE outcome=blind sha= feed=skipped log=")
  exit 3
}
if ([int]$ahead -eq 0) {
  if ($Rehearse) { Write-Output 'TRIAGE-REHEARSE-COMPLETE gates=n/a ta=n/a nothing-ahead log='; exit 0 }
  Write-Output ("triage-land: nothing to land - HEAD of " + $repo + " is already on origin/main")
  Write-Output 'TRIAGE-LAND-COMPLETE outcome=nothing-to-land sha= feed=skipped log='
  exit 0
}
if ($Rehearse) {
  Write-Output ("triage-land: rehearsing " + $ahead.Trim() + " commit(s) of " + $repo + ": run-gates and test-auditors at once, nothing pushed")
  $legs = Invoke-TcLandLegs -Repo $repo -LogDir $LogDir -Stamp $stamp -Legs @('gates', 'ta')
  Write-TcLegLines $legs
  $gv = [string](@($legs | Where-Object { $_.Leg -eq 'gates' })[0].Verdict)
  $tv = [string](@($legs | Where-Object { $_.Leg -eq 'ta' })[0].Verdict)
  $rc = 0; if ($gv -eq 'blind' -or $tv -eq 'blind') { $rc = 3 }; if ($gv -eq 'fail' -or $tv -eq 'fail') { $rc = 1 }
  Write-Output ('TRIAGE-REHEARSE-COMPLETE gates=' + $gv + ' ta=' + $tv + ' log=' + $LogDir)
  exit $rc
}
Write-Output ("triage-land: landing " + $ahead.Trim() + " commit(s) from " + $repo + " through ops\push-main.ps1 (full output: " + $log + ")")
$r = Invoke-TcLandChild -Script $PushScript -Log $log -WorkDir $repo
$o = Get-TcLandOutcome $r.Lines $r.Code
Write-Output ("  " + $o.Line)

$second = 'n/a'
$parked = ''
if ($o.Outcome -eq 'refused') {
  # The leg push-main never reached: a run-gates refusal leaves test-auditors unrun, so run it now (both layers in ONE refusal).
  if ($o.Line -match 'run-gates') {
    Write-Output '  run-gates refused, so test-auditors never ran; running it now on the same HEAD so this refusal names every red:'
    $legs = Invoke-TcLandLegs -Repo $repo -LogDir $LogDir -Stamp $stamp -Legs @('ta')
    Write-TcLegLines $legs
    $second = [string]@($legs)[0].Verdict
  }
  if ($Park) {
    $why = ''
    $branchNow = ([string]@((Invoke-TcGitQuiet $repo @('symbolic-ref', '--short', 'HEAD')).Out)[0]).Trim()
    if ($branchNow -ne 'main') { $why = 'HEAD is on ' + $branchNow + ', not main, so nothing needs moving off main' }
    elseif (-not ($RunBase -match '^[0-9a-fA-F]{7,40}$')) { $why = 'no -RunBase sha was given' }
    elseif ((Invoke-TcGitQuiet $repo @('merge-base', '--is-ancestor', $RunBase, 'HEAD')).Code -ne 0) { $why = 'RunBase ' + $RunBase + ' is not an ancestor of HEAD' }
    else { $why = Test-TcParkAllowed @((Invoke-TcGitQuiet $repo @('log', '--format=%s', ($RunBase + '..HEAD'))).Out) }
    if (-not $why) {
      # Lock order 0 (ops-and-gates.md og-27): the capture-run mutex, so the bot never commits mid-reset. Zero wait.
      $mx = New-Object System.Threading.Mutex($false, 'Global\tc-capture-run')
      $held = $false
      try { $held = $mx.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $held = $true }
      if (-not $held) { $why = 'a capture run holds Global\tc-capture-run' }
      else {
        try {
          $day = (Get-Date).ToString('yyyy-MM-dd'); $name = 'triage/' + $day + '-unlanded'; $n = 1
          while ((Invoke-TcGitQuiet $repo @('rev-parse', '--verify', '--quiet', ('refs/heads/' + $name))).Code -eq 0) { $n++; $name = 'triage/' + $day + '-unlanded-' + $n }
          if ((Invoke-TcGitQuiet $repo @('branch', $name, 'HEAD')).Code -ne 0) { $why = 'git branch ' + $name + ' failed' }
          elseif ((Invoke-TcGitQuiet $repo @('reset', '--keep', $RunBase)).Code -ne 0) { $why = 'git reset --keep ' + $RunBase + ' refused (a dirty file overlaps the run''s commits); the branch ' + $name + ' holds them' }
          else { $parked = $name }
        } finally { $mx.ReleaseMutex(); $mx.Dispose() }
      }
    }
    if ($parked) { Write-Output ('  parked: the run''s commits are on ' + $parked + '; main is back at ' + $RunBase + '. triage-due lists the branch as UNLANDED until it lands.') }
    else { Write-Output ('  NOT parked: ' + $why + '. The commits are still on HEAD; park by hand before the next bot push.') }
  }
}

$feed = 'skipped'
if ($o.Outcome -eq 'landed' -and $CheckFeed) {
  $feed = 'blind'
  $fs = Join-Path $here 'audit-feed-week-parity.ps1'
  for ($try = 1; $try -le 3; $try++) {
    if ($try -gt 1) { Start-Sleep -Seconds 60 }
    $fl = Join-Path $LogDir ("feed-" + $stamp + "-" + $try + ".log")
    $fr = Invoke-TcLandChild -Script $fs -Log $fl -WorkDir $repo
    if ($fr.Code -eq 0) { $feed = 'match'; break }
    if ($fr.Code -eq 2) { $feed = 'mismatch' } else { $feed = 'blind' }
  }
  $fv = @($fr.Lines | Where-Object { $_ -match 'board|feed' } | Select-Object -Last 1)
  Write-Output ("  feed week parity after " + $try + " attempt(s): " + $feed + $(if ($fv.Count) { ' - ' + [string]$fv[0] } else { '' }))
  if ($feed -ne 'match' -and $o.Rc -eq 0) { $o.Rc = 2 }
}
Write-Output ("TRIAGE-LAND-COMPLETE outcome=" + $o.Outcome + " sha=" + $o.Sha + " feed=" + $feed + " second_leg=" + $second + " parked=" + $parked + " log=" + $log)
exit $o.Rc
