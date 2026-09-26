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

  Run:       powershell -NoProfile -File grocery\triage-land.ps1 [-CheckFeed]
             -CheckFeed  after a landing, run grocery\audit-feed-week-parity.ps1 (the board and the feed must quote the
                         SAME week; the Worker lags a push by about 90 s, so it is tried up to 3 times, 60 s apart)
  Self-test: powershell -NoProfile -File grocery\triage-land.ps1 -SelfTest
  Exit: 0 landed (or nothing to land), 1 refused, 3 could not evaluate. The full push-main output goes to a log whose
  path the last line names; read that only when the outcome is not `landed`.
#>
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop (2026-09-07)
param(
  [switch]$CheckFeed,
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
  $expected = 6
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
  Write-Output ("triage-land: nothing to land - HEAD of " + $repo + " is already on origin/main")
  Write-Output 'TRIAGE-LAND-COMPLETE outcome=nothing-to-land sha= feed=skipped log='
  exit 0
}
Write-Output ("triage-land: landing " + $ahead.Trim() + " commit(s) from " + $repo + " through ops\push-main.ps1 (full output: " + $log + ")")
$r = Invoke-TcLandChild -Script $PushScript -Log $log -WorkDir $repo
$o = Get-TcLandOutcome $r.Lines $r.Code
Write-Output ("  " + $o.Line)

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
Write-Output ("TRIAGE-LAND-COMPLETE outcome=" + $o.Outcome + " sha=" + $o.Sha + " feed=" + $feed + " log=" + $log)
exit $o.Rc
