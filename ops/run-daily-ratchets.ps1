<#
  run-daily-ratchets.ps1 - run the tree-wide ratchets a PUSH no longer pays for, once a day.

  Run:        powershell -File ops\run-daily-ratchets.ps1
  Self-test:  powershell -File ops\run-daily-ratchets.ps1 -SelfTest

  WHY THIS EXISTS (Brad, 2026-09-12). Six tree-wide ratchets cost 184s of a 699s push and one of them,
  audit-mustfire-census at 54s, was the wall-clock FLOOR - no pool finishes sooner than its longest single job.
  What they protect is the estate's own guard quality over months: a deleted must-fire fixture, a self-test resting
  on an unfrozen rulings file, a stray control byte, a write-only report family, a walk that breaks inside
  worktrees, a statement keyword glued onto a command line. NOT ONE OF THEM CAN PUT A WRONG NUMBER IN FRONT OF A
  PAYING READER. Being able to fail is not the same as needing to fail within 60 seconds, so they moved here.

  IT IS NOT A NIGHTLY FULL SWEEP, which Brad refused and was right to: a net nobody reads is worse than none,
  because it licenses looser selection elsewhere. This is six named audits, about two minutes.

  ONE LIST, NOT TWO. The names are not repeated here. They are read from ops\run-gates.ps1's own $static list, from
  the entries marked `daily = $true` - the same mark that makes a push skip them. A name carried in two files goes
  stale, and this estate has paid for that shape repeatedly; here it would mean an audit that neither runs.

  SCOPE OF A CLEAN REPORT: exit 0 means every audit marked daily ran and passed at this commit. It says nothing
  about the gates a push runs, and nothing about a day this task did not fire - which is why a run that did not
  happen has to be as visible as a run that failed. THAT IS THE FAILURE MODE OF THIS FILE: it goes quiet.
  Exit 0 = all passed. 1 = at least one failed. 3 = could not evaluate, which is never a pass.
#>
[CmdletBinding()]
param([switch]$SelfTest, [string]$Root = '')

$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = if ($Root) { $Root } else { Split-Path $here -Parent }
. (Join-Path $repo 'lib\git-repo-env.ps1')
Clear-TcGitRepoEnv

function Get-TcDailyRatchets {
  <# The files ops\run-gates.ps1 marks `daily = $true`, read out of its source so the two can never disagree.
     Returns the relative paths in the order they appear. Pure over the text, so the fixture drives it. #>
  param([string]$Text)
  $out = [Collections.Generic.List[string]]::new()
  foreach ($m in [regex]::Matches($Text, "(?m)^\s*@\{\s*daily\s*=\s*\`$true;\s*f\s*=\s*'([^']+)'")) {
    [void]$out.Add($m.Groups[1].Value)
  }
  return @($out)
}

function Get-TcJudgedCommit {
  <# WHICH COMMIT DID THIS GREEN JUDGE, AND IS IT MAIN? (2026-09-18, backlog I232)
     The 09-18 03:17 stamp was written at 59b7fefa5, a local graph-nightly commit that was not on origin/main, and
     the stamp said only `commit`: a green from a checkout holding unpushed work, or one BEHIND main, read exactly
     like a green of main. So the stamp now carries both directions against the checkout's own origin/main ref:
       on_origin_main        HEAD is an ancestor of origin/main - everything judged is on main
       contains_origin_main  origin/main is an ancestor of HEAD - the checkout was not behind main
     Both true means the judged tree IS origin/main. $null means it could not be asked (no origin/main ref, or git
     failed), never false: a could-not-look is not a finding. origin_main names the ref as this checkout last
     fetched it, so a reader can tell a stale fetch from a stale checkout. Git only, no network. #>
  param([string]$Repo)
  $r = [ordered]@{ commit = ''; commit_full = ''; origin_main = ''; on_origin_main = $null; contains_origin_main = $null }
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $full = [string](& git -C $Repo rev-parse --verify -q HEAD)
    if ($LASTEXITCODE -ne 0 -or -not $full.Trim()) { return [pscustomobject]$r }
    $r.commit_full = $full.Trim()
    $r.commit = $r.commit_full.Substring(0, [Math]::Min(9, $r.commit_full.Length))
    $om = [string](& git -C $Repo rev-parse --verify -q 'refs/remotes/origin/main')
    if ($LASTEXITCODE -ne 0 -or -not $om.Trim()) { return [pscustomobject]$r }
    $r.origin_main = $om.Trim()
    & git -C $Repo merge-base --is-ancestor $r.commit_full $r.origin_main
    if ($LASTEXITCODE -eq 0) { $r.on_origin_main = $true } elseif ($LASTEXITCODE -eq 1) { $r.on_origin_main = $false }
    & git -C $Repo merge-base --is-ancestor $r.origin_main $r.commit_full
    if ($LASTEXITCODE -eq 0) { $r.contains_origin_main = $true } elseif ($LASTEXITCODE -eq 1) { $r.contains_origin_main = $false }
  } catch { } finally { $ErrorActionPreference = $prevEap }
  return [pscustomobject]$r
}

if ($SelfTest) {
  $f = 0; $cases = 0
  function T([string]$m, [bool]$c, [string]$got = '') {
    $script:cases++
    if ($c) { Write-Output ('ok    ' + $m) } else { Write-Output ('FAIL  ' + $m + '   got: ' + $got); $script:f++ }
  }
  $kMF = 'MUST' + ' FIRE'; $kMNF = 'MUST' + ' NOT FIRE'; $kCT = 'CLEAN' + ' TWIN'

  # The parser, against text this file writes, so the cases cannot drift with run-gates.
  $one = "@{ daily = `$true; f = 'ops\a.ps1';   n = 'x' }"
  $two = "@{ f = 'ops\b.ps1'; n = 'y' }"
  T ($kMF + '  an entry marked daily is read as a daily ratchet') `
    ((Get-TcDailyRatchets -Text $one).Count -eq 1) ((Get-TcDailyRatchets -Text $one) -join ',')
  T ($kMNF + '  an UNMARKED entry is not read as one, or a push would stop running it too') `
    ((Get-TcDailyRatchets -Text $two).Count -eq 0) ((Get-TcDailyRatchets -Text $two) -join ',')
  T ($kCT + '  both together yield exactly the marked one, in order') `
    (((Get-TcDailyRatchets -Text ($two + "`n" + $one)) -join ',') -eq 'ops\a.ps1') ((Get-TcDailyRatchets -Text ($two + "`n" + $one)) -join ',')

  # THE LIVE JOIN. A parser that reads its own fixtures and never the real list is the shape that lets the two
  # silently disagree, so this case asks run-gates itself - and an EMPTY answer is a failure, never a clean run.
  $rgPath = Join-Path $repo 'ops\run-gates.ps1'
  $live = @()
  if (Test-Path -LiteralPath $rgPath) { $live = @(Get-TcDailyRatchets -Text ([IO.File]::ReadAllText($rgPath))) }
  T ($kMF + '  run-gates really does mark audits daily, and this file can see them - an empty list is a lost mark, not a quiet day') `
    ($live.Count -ge 1) ("found={0}" -f $live.Count)
  $missing = @($live | Where-Object { -not (Test-Path -LiteralPath (Join-Path $repo $_)) })
  T ($kMF + '  every file run-gates defers actually exists, so a rename cannot leave a ratchet running nowhere') `
    ($missing.Count -eq 0) ($missing -join ',')

  # WHICH COMMIT A GREEN JUDGED (2026-09-18, backlog I232). A real scratch repository per run, with origin/main as
  # a plain ref, so the three shapes are git's own answers: ahead of main (the 09-18 59b7fefa5 shape, a local
  # commit nobody pushed), behind main, and exactly main. No network, no remote.
  $jr = Join-Path ([IO.Path]::GetTempPath()) ('drj-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
  $null = [IO.Directory]::CreateDirectory($jr)
  $prevEapJ = $ErrorActionPreference
  try {
    Clear-TcGitRepoEnv
    $ErrorActionPreference = 'Continue'
    $gid = @('-c', 'user.name=fixture', '-c', 'user.email=fixture@example.invalid', '-c', 'commit.gpgsign=false')
    $null = & git -C $jr init -q
    $null = & git -C $jr @gid commit -q --allow-empty -m a
    $shaA = ([string](& git -C $jr rev-parse HEAD)).Trim()
    $ErrorActionPreference = $prevEapJ
    $none = Get-TcJudgedCommit -Repo $jr
    T ($kMNF + '  with NO origin/main ref the answer is unknown ($null), never a false "not on main"') `
      (($null -eq $none.on_origin_main) -and ($null -eq $none.contains_origin_main) -and ($none.commit_full -eq $shaA)) ("on=" + $none.on_origin_main + " contains=" + $none.contains_origin_main)
    $ErrorActionPreference = 'Continue'
    $null = & git -C $jr update-ref refs/remotes/origin/main $shaA
    $ErrorActionPreference = $prevEapJ
    $same = Get-TcJudgedCommit -Repo $jr
    T ($kCT + '  a checkout AT origin/main is recorded as both on it and containing it') `
      (($same.on_origin_main -eq $true) -and ($same.contains_origin_main -eq $true) -and ($same.origin_main -eq $shaA)) ("on=" + $same.on_origin_main + " contains=" + $same.contains_origin_main)
    $ErrorActionPreference = 'Continue'
    $null = & git -C $jr @gid commit -q --allow-empty -m local-nightly
    $shaB = ([string](& git -C $jr rev-parse HEAD)).Trim()
    $ErrorActionPreference = $prevEapJ
    $ahead = Get-TcJudgedCommit -Repo $jr
    T ($kMF + '  a green judged at a LOCAL commit not on origin/main (the 09-18 03:17 shape) says on_origin_main=false') `
      (($ahead.on_origin_main -eq $false) -and ($ahead.contains_origin_main -eq $true) -and ($ahead.commit_full -eq $shaB)) ("on=" + $ahead.on_origin_main + " contains=" + $ahead.contains_origin_main)
    $ErrorActionPreference = 'Continue'
    $null = & git -C $jr update-ref refs/remotes/origin/main $shaB
    $null = & git -C $jr checkout -q $shaA
    $ErrorActionPreference = $prevEapJ
    $behind = Get-TcJudgedCommit -Repo $jr
    T ($kMF + '  a green judged in a checkout BEHIND origin/main says contains_origin_main=false') `
      (($behind.on_origin_main -eq $true) -and ($behind.contains_origin_main -eq $false)) ("on=" + $behind.on_origin_main + " contains=" + $behind.contains_origin_main)
  } finally {
    $ErrorActionPreference = $prevEapJ
    Remove-Item -LiteralPath $jr -Recurse -Force -ErrorAction SilentlyContinue
  }

  if ($f) { Write-Output ("run-daily-ratchets self-test FAIL: {0} of {1} check(s)" -f $f, $cases); exit 1 }
  Write-Output ("run-daily-ratchets self-test PASS: {0} cases - led by the live join against run-gates' own list, where an empty answer is a failure" -f $cases)
  exit 0
}

$rg = Join-Path $repo 'ops\run-gates.ps1'
if (-not (Test-Path -LiteralPath $rg)) {
  Write-Output "run-daily-ratchets: COULD NOT EVALUATE - ops\run-gates.ps1 is not in this checkout, so the list cannot be read."
  exit 3
}
$names = @(Get-TcDailyRatchets -Text ([IO.File]::ReadAllText($rg)))
if (-not $names.Count) {
  # AN EMPTY LIST IS NOT A CLEAN DAY. It means the mark was lost or renamed, and the six would then run nowhere:
  # not in a push, because the push defers them, and not here. That is the exact absence this file must be loud about.
  Write-Output 'run-daily-ratchets: COULD NOT EVALUATE - run-gates marks NO audit daily. Either the mark was lost, or this checkout predates it. These ratchets are running NOWHERE until that is fixed.'
  exit 3
}

$PSEXE = (Get-Process -Id $PID).Path
$fails = [Collections.Generic.List[string]]::new()
$blind = [Collections.Generic.List[string]]::new()
$swAll = [Diagnostics.Stopwatch]::StartNew()
foreach ($rel in $names) {
  $full = Join-Path $repo $rel
  if (-not (Test-Path -LiteralPath $full)) {
    Write-Output ("  BLIND {0} - run-gates defers it but this checkout does not have it" -f $rel)
    [void]$blind.Add($rel)
    continue
  }
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $p = Start-Process -FilePath $PSEXE -WorkingDirectory $repo -NoNewWindow -PassThru -ErrorAction Stop `
    -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $full)
  $null = $p.Handle   # PS 5.1 leaves ExitCode empty without it, and an empty code read as 0 is a false pass
  $p.WaitForExit()
  $sw.Stop()
  $code = $p.ExitCode
  if ($null -eq $code) {
    Write-Output ("  BLIND {0} - it ran but its exit code could not be read, which is never a pass" -f $rel)
    [void]$blind.Add($rel)
  } elseif ([int]$code -eq 0) {
    Write-Output ("  ok    {0}  ({1:N0}s)" -f $rel, ($sw.ElapsedMilliseconds / 1000))
  } else {
    Write-Output ("  FAIL  {0}  (exit {1}, {2:N0}s)" -f $rel, $code, ($sw.ElapsedMilliseconds / 1000))
    [void]$fails.Add($rel)
  }
}
$swAll.Stop()
Write-Output ("run-daily-ratchets: {0} ratchet(s), {1} passed, {2} failed, {3} could not be evaluated, {4:N0}s" -f `
  $names.Count, ($names.Count - $fails.Count - $blind.Count), $fails.Count, $blind.Count, ($swAll.ElapsedMilliseconds / 1000))
if ($fails.Count) {
  Write-Output ('  failed: ' + ($fails -join ', '))
  Write-Output '  These are the tree-wide ratchets a push no longer runs. Fix the cause; do not retrain a baseline to make a red go away.'
}
$judged = Get-TcJudgedCommit -Repo $repo
if ($judged.on_origin_main -ne $true -or $judged.contains_origin_main -ne $true) {
  Write-Output ("  NOTE  this run judged {0}, which is not origin/main as this checkout last fetched it ({1}; on_origin_main={2}, contains_origin_main={3}). A green stamp records that." -f `
    $judged.commit, $judged.origin_main, $judged.on_origin_main, $judged.contains_origin_main)
}
Write-Output ("DAILY-RATCHETS-COMPLETE ratchets={0} failed={1} blind={2}" -f $names.Count, $fails.Count, $blind.Count)

# THE STAMP IS WRITTEN ONLY ON A GREEN VERDICT, and that is deliberate. A stamp written on every path would let a RED
# run prove it happened, and the watcher reads "work landed" from exactly that file - so a failing ratchet would
# excuse its own nonzero exit. The same reasoning is recorded on TC Daemon Battery 0230's row in
# grocery\expected-automations.json, and it is the reason a red or blind run leaves yesterday's stamp standing:
# health-heartbeat then sees it go stale and pages, which is what should happen when these stop passing.
if (-not $blind.Count -and -not $fails.Count) {
  $stampDir = Join-Path $repo 'ops\out\logs'
  try {
    if (-not [IO.Directory]::Exists($stampDir)) { $null = [IO.Directory]::CreateDirectory($stampDir) }
    $stamp = [ordered]@{
      written_utc          = [DateTime]::UtcNow.ToString('o')
      commit               = $judged.commit
      commit_full          = $judged.commit_full
      origin_main          = $judged.origin_main
      on_origin_main       = $judged.on_origin_main
      contains_origin_main = $judged.contains_origin_main
      ratchets             = $names.Count
      names       = @($names)
      seconds     = [int]($swAll.ElapsedMilliseconds / 1000)
    }
    $json = ($stamp | ConvertTo-Json -Depth 4)
    [IO.File]::WriteAllText((Join-Path $stampDir 'daily-ratchets-green.json'), ($json -replace "`r`n", "`n") + "`n", (New-Object Text.UTF8Encoding($false)))
  } catch {
    # A STAMP THAT COULD NOT BE WRITTEN IS NOT A FAILED RATCHET, but it must not read as a silent success either:
    # the run passed, and the watcher will page on the stale stamp, which is the correct outcome.
    Write-Output ("run-daily-ratchets: the ratchets PASSED but the stamp could not be written ({0}) - the watcher will page on a stale stamp, which is right." -f $_.Exception.Message)
  }
}
$rc = 0
if ($blind.Count) { $rc = 3 } elseif ($fails.Count) { $rc = 1 }
exit $rc
