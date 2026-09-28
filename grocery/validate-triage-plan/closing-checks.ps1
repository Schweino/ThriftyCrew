<#
  grocery\validate-triage-plan\closing-checks.ps1 - a PIECE of grocery\validate-triage-plan.ps1, dot-sourced by it
  (the host-plus-pieces shape ops\audit-file-size-budget.ps1 judges per piece). It holds the -Closing checks that
  read something outside the plan: the cost ledger (2026-09-24) and the fix on origin/main (2026-09-28), with their
  self-test cases in Invoke-ClosingChecksSelfTest, which the host's -SelfTest calls and counts in its own tally.
  Nothing here runs at load time.
#>
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'native-lib.ps1')                         # Invoke-Native: the landed check's git calls
. (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'lib\git-repo-env.ps1')  # Clear-TcGitRepoEnv: the self-test's temp repo
function Test-PlanCostLedger {
  param([string]$LedgerPath, [string]$PlanName)
  if (-not (Test-Path -LiteralPath $LedgerPath)) { return @{ ok = $false; why = "no cost ledger at $LedgerPath" } }
  $n = 0
  foreach ($ln in [IO.File]::ReadAllLines($LedgerPath)) {
    if (-not $ln.Trim()) { continue }
    try { $r = $ln | ConvertFrom-Json } catch { continue }
    if ([string]$r.schema -ne '2') { continue }
    $names = @(@($r.plans) | ForEach-Object { [string]$_ })
    if ($names -contains $PlanName) { $n++ }
  }
  if ($n -gt 0) { return @{ ok = $true; why = "$n schema-2 row(s) name $PlanName" } }
  return @{ ok = $false; why = "no schema-2 row of $LedgerPath names $PlanName - run grocery\triage-cost.py --append --plan $PlanName (it derives the rows from the session transcripts)" }
}

# THE FIX IS ON origin/main, NOT ONLY WRITTEN (2026-09-28). The 2026-09-27 run committed 8 fixes on
# origin/triage/2026-09-27 and closed their items done (1d9d8229f "plan item done (shipped 2e83fb11f ...)"); none
# reached origin/main, and the next morning's chain ran without them. -Closing checked that every item had an outcome,
# never that the outcome had landed. So now, for each item whose status is done or deviated and whose shipped_commit
# is non-empty:
#   * every commit hash in it (7-40 hex, holding a digit and a letter when inside prose) must RESOLVE here, and be
#     reachable from origin/main OR have a patch-equivalent there (`git cherry`: a rebase rewrites the hash, so
#     reachability alone would refuse every rebased landing);
#   * a value naming no hash ("see git log: ... (this commit)", 115 of 154 values in plans 09-20..09-29 at this
#     writing, because a developer commits the plan WITH its fix and cannot know that commit's hash) is judged by the
#     plan itself: origin/main's copy of this plan must carry the item as done or deviated. That holds exactly when
#     the plan commit landed, and the plan is committed with the fix.
# An unresolvable hash, a plan absent from origin/main, or a git that cannot answer is a finding, never a pass.
# Plans dated on or after $LandedCutoff are REFUSED; older plans WARN (they predate the rule, and re-closing one
# must report honestly without reddening history). -PreLanding skips this check and SAYS so: it is for the
# developer's own run, which by TOKEN DISCIPLINE never pushes; the orchestrator's closing after triage-land.ps1 is
# the one that judges landing. A stale local origin/main can only REFUSE wrongly, never pass wrongly (main only moves
# forward), and the main flow fetches first unless -NoFetch, printing which it did.
$LandedCutoff = '2026-09-28'
function Get-VtpLastLine($R) {
  # the last non-empty stdout line of an Invoke-Native result, or '' (a [string] cast of an EMPTY pipeline is $null)
  $o = @(@($R.Output) | Where-Object { $_ })
  if ($o.Count) { return ([string]$o[$o.Count - 1]).Trim() }
  return ''
}
function Get-ShippedCommitHashes([string]$Value) {
  $v = ([string]$Value).Trim()
  if ($v -match '^[0-9a-fA-F]{7,40}$') { return ,@($v) }
  $hs = @([regex]::Matches($v, '(?<![0-9A-Za-z])[0-9a-f]{7,40}(?![0-9A-Za-z])') | ForEach-Object { $_.Value } | Where-Object { $_ -match '\d' -and $_ -match '[a-f]' })
  return ,$hs
}
function Test-CommitLanded([string]$Repo, [string]$Sha, [string]$MainRef) {
  $rv = Invoke-Native git -C $Repo rev-parse --verify --quiet ($Sha + '^{commit}')
  $full = (Get-VtpLastLine $rv)
  if ($rv.ExitCode -ne 0 -or -not $full) { return @{ state = 'unresolved'; why = '' } }
  $anc = Invoke-Native git -C $Repo merge-base --is-ancestor $full $MainRef
  if ($anc.ExitCode -eq 0) { return @{ state = 'ancestor'; why = '' } }
  if ($anc.ExitCode -ne 1) { return @{ state = 'blind'; why = ('git merge-base exited ' + $anc.ExitCode + ': ' + (@($anc.Error) -join ' ')) } }
  $ch = Invoke-Native git -C $Repo cherry $MainRef $full ($full + '^')
  if ($ch.ExitCode -ne 0) { return @{ state = 'blind'; why = ('git cherry exited ' + $ch.ExitCode + ': ' + (@($ch.Error) -join ' ')) } }
  if (@(@($ch.Output) | Where-Object { ([string]$_) -match '^-\s' }).Count) { return @{ state = 'equivalent'; why = '' } }
  return @{ state = 'not-landed'; why = '' }
}
function Get-MainPlanStatuses([string]$Repo, [string]$PlanRel, [string]$MainRef) {
  # queue_id -> status in $MainRef's copy of the plan, or $null when that copy is absent or unreadable
  $sh = Invoke-Native git -C $Repo show ($MainRef + ':' + $PlanRel)
  if ($sh.ExitCode -ne 0) { return $null }
  try { $md = (@($sh.Output) -join "`n") | ConvertFrom-Json } catch { return $null }
  $m = @{}
  foreach ($mi in @($md.items)) { if ($mi) { $m[[string]$mi.queue_id] = ([string]$mi.status).Trim() } }
  return $m
}
function Test-PlanLanded {
  param($Doc, [string]$PlanName, [string]$PlanRel, [string]$RepoRoot, [string]$MainRef = 'origin/main', [string]$Cutoff = $script:LandedCutoff)
  $found = New-Object System.Collections.Generic.List[string]
  $states = New-Object System.Collections.Generic.List[string]
  $judged = 0; $landed = 0; $mainPlan = $null; $mainPlanRead = $false
  foreach ($i in @($Doc.items)) {
    if (-not $i) { continue }
    if (@('done','deviated') -notcontains ([string]$i.status).Trim()) { continue }
    $sc = ([string]$i.shipped_commit).Trim()
    if (-not $sc) { continue }
    $id = [string]$i.queue_id
    $judged++
    $hs = Get-ShippedCommitHashes $sc; $hs = @($hs)
    if ($hs.Count -eq 0) {
      if (-not $mainPlanRead) { $mainPlan = Get-MainPlanStatuses $RepoRoot $PlanRel $MainRef; $mainPlanRead = $true }
      $st = ''
      if ($null -ne $mainPlan -and $mainPlan.ContainsKey($id)) { $st = [string]$mainPlan[$id] }
      if (@('done','deviated') -contains $st) { $landed++; $states.Add("${id}:plan:landed"); continue }
      $where = if ($null -eq $mainPlan) { "$MainRef has no readable copy of $PlanRel" } elseif (-not $st) { "$MainRef's copy of $PlanRel does not carry it" } else { "$MainRef's copy of $PlanRel carries it as '$st'" }
      $found.Add("$id shipped_commit '$sc' names no commit hash, and $where - not on ${MainRef}: the fix is written, not landed (land the run with grocery\triage-land.ps1, then close)")
      $states.Add("${id}:plan:not-landed")
      continue
    }
    $bad = 0
    foreach ($h in $hs) {
      $r = Test-CommitLanded $RepoRoot $h $MainRef
      $states.Add("${id}:${h}:" + $r.state)
      switch ($r.state) {
        'ancestor'   { }
        'equivalent' { }
        'unresolved' { $bad++; $found.Add("$id shipped_commit $h does not resolve in this checkout - a hash git cannot find is never a pass (fetch the branch that holds it, or correct the hash)") }
        'not-landed' { $bad++; $found.Add("$id shipped_commit $h is not on ${MainRef}, and no equivalent patch is: the fix is written, not landed (land the run with grocery\triage-land.ps1, then close)") }
        'blind'      { $bad++; $found.Add("$id shipped_commit ${h}: could not verify it against $MainRef - " + $r.why) }
        default      { throw ("unknown landed state: " + $r.state) }
      }
    }
    if ($bad -eq 0) { $landed++ }
  }
  $dk = Get-PlanDateKey $PlanName $Doc
  $refuse = (-not $dk) -or ([string]::CompareOrdinal($dk, $Cutoff) -ge 0)
  $arr = $found.ToArray()
  return @{ judged = $judged; landed = $landed; refuse = $refuse; states = $states.ToArray()
            problems = $(if ($refuse) { $arr } else { @() }); warnings = $(if ($refuse) { @() } else { $arr }) }
}
function Invoke-ClosingLandedCheck([string]$Plan, $Doc, [string]$PlanLeaf, [switch]$PreLanding, [switch]$NoFetch) {
  $landSaid = ''; $landWarn = @(); $landProb = @()
  if ($PreLanding) {
    $landSaid = 'not judged (-PreLanding: the orchestrator''s closing after grocery\triage-land.ps1 judges it)'
  } else {
    $planDir = Split-Path (Resolve-Path -LiteralPath $Plan).Path -Parent
    $top = Invoke-Native git -C $planDir rev-parse --show-toplevel
    $topPath = (Get-VtpLastLine $top)
    if ($top.ExitCode -ne 0 -or -not $topPath) {
      $landProb += "could not verify that the shipped commits are on origin/main: the plan is not inside a git checkout (git rev-parse exited $($top.ExitCode))"
      $landSaid = 'could not evaluate (no git checkout)'
    } else {
      $fetchSaid = 'not fetched (-NoFetch)'
      if (-not $NoFetch) {
        $fe = Invoke-Native git -C $topPath fetch origin main --quiet
        $fetchSaid = if ($fe.ExitCode -eq 0) { 'fetched' } else { "FETCH FAILED (exit $($fe.ExitCode)), judged against the local ref, which can only refuse wrongly, never pass wrongly" }
      }
      $topFull = [IO.Path]::GetFullPath(($topPath -replace '/', '\')).TrimEnd('\')
      $planFull = (Resolve-Path -LiteralPath $Plan).Path
      $planRel = if ($planFull.StartsWith($topFull + '\', [StringComparison]::OrdinalIgnoreCase)) { $planFull.Substring($topFull.Length + 1) -replace '\\', '/' } else { $PlanLeaf }
      $ld = Test-PlanLanded -Doc $Doc -PlanName $PlanLeaf -PlanRel $planRel -RepoRoot $topPath -MainRef 'origin/main'
      $landProb += @($ld.problems)
      $landWarn = @($ld.warnings)
      $landSaid = ("{0} of {1} done/deviated item(s) with a shipped_commit are on origin/main ({2}); {3}" -f $ld.landed, $ld.judged, $fetchSaid, $(if ($ld.refuse) { 'an unlanded one is refused' } else { "dated before $LandedCutoff, so an unlanded one WARNS" }))
    }
  }
  return @{ problems = @($landProb); warnings = @($landWarn); said = $landSaid }
}

function Invoke-ClosingChecksSelfTest {
  # runs in the host's -SelfTest, adding to its $script:ran and $script:fail
  $ldRoot = Join-Path $env:TEMP ('vtp-ledger-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $ldRoot -ErrorAction Stop | Out-Null
  try {
    $ld = Join-Path $ldRoot 'cost-ledger.jsonl'
    # a TYPED row, even one that copies the new plans field, is not a derived row: only schema 2 counts
    [IO.File]::WriteAllText($ld, '{"date":"2026-09-25","plan":"plan-2026-09-25.json","plans":["plan-2026-09-25.json"],"agent":"triage-reviewer","tokens":317364}' + "`n", (New-Object Text.UTF8Encoding($false)))
    $script:ran++
    $c1 = Test-PlanCostLedger $ld 'plan-2026-09-25.json'
    if (-not $c1.ok) { Write-Output 'ok    MUST FIRE: a plan named only by a typed row (final-context tokens, no schema 2) is not on the ledger' }
    else { Write-Output ('FAIL  MUST FIRE: old-schema row accepted: ' + $c1.why); $script:fail++ }
    [IO.File]::AppendAllText($ld, '{"schema":2,"agent_id":"orchestrator:s1","plans":["plan-2026-09-25.json"],"cost_units":582}' + "`n", (New-Object Text.UTF8Encoding($false)))
    $script:ran++
    $c2 = Test-PlanCostLedger $ld 'plan-2026-09-25.json'
    $c3 = Test-PlanCostLedger $ld 'plan-2026-09-25-2.json'
    if ($c2.ok -and -not $c3.ok) { Write-Output 'ok    CLEAN TWIN: a schema-2 row naming the plan puts it on the ledger, and names no other plan' }
    else { Write-Output ('FAIL  CLEAN TWIN: ledger row c2=' + $c2.ok + ' c3=' + $c3.ok); $script:fail++ }
  } finally { Remove-Item -LiteralPath $ldRoot -Recurse -Force -ErrorAction SilentlyContinue }

  # --- THE FIX IS ON main, NOT ONLY WRITTEN (2026-09-28): a temp repo per run, its git environment cleared (og-23) ---
  # main: base (a plan whose p1 is 'planned' and p2 'done') -> m. side, off m: s -> r. main then cherry-picks r, so r's
  # patch is on main under ANOTHER hash (a rebased landing) while s exists only on side (the 2026-09-27 branch).
  $lrRoot = Join-Path $env:TEMP ('vtp-land-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
  New-Item -ItemType Directory -Path $lrRoot -ErrorAction Stop | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $lrRoot 'nohooks') -ErrorAction Stop | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $lrRoot 'r\plans') -ErrorAction Stop | Out-Null
  $lrRepo = Join-Path $lrRoot 'r'
  $u8l = New-Object Text.UTF8Encoding($false)
  try {
    Clear-TcGitRepoEnv
    function _LGit {
      $g = Invoke-Native git -C $lrRepo -c user.name=vtp -c user.email=vtp@example.invalid -c commit.gpgsign=false -c core.autocrlf=false -c ('core.hooksPath=' + (Join-Path $lrRoot 'nohooks')) @args
      if ($g.ExitCode -ne 0) { throw ('temp repo git ' + ($args -join ' ') + ' exited ' + $g.ExitCode + ': ' + (@($g.Error) -join ' ')) }
      return (Get-VtpLastLine $g)
    }
    function _LFile([string]$rel, [string]$text) { [IO.File]::WriteAllText((Join-Path $lrRepo $rel), $text, $u8l) }
    _LGit init -q -b main | Out-Null
    _LFile 'plans\plan-2026-09-28.json' '{"items":[{"queue_id":"p1","status":"planned"},{"queue_id":"p2","status":"done"}]}'
    _LFile 'a.txt' "base`n"
    _LGit add -- a.txt plans/plan-2026-09-28.json | Out-Null
    _LGit commit -q -m base | Out-Null
    _LFile 'm.txt' "on main`n"; _LGit add -- m.txt | Out-Null; _LGit commit -q -m m | Out-Null
    $shaMain = _LGit rev-parse HEAD
    _LGit checkout -q -b side | Out-Null
    _LFile 's.txt' "side only`n"; _LGit add -- s.txt | Out-Null; _LGit commit -q -m s | Out-Null
    $shaSide = _LGit rev-parse HEAD
    _LFile 'r.txt' "rebased`n"; _LGit add -- r.txt | Out-Null; _LGit commit -q -m r | Out-Null
    $shaRebase = _LGit rev-parse HEAD
    _LGit checkout -q main | Out-Null
    _LGit cherry-pick $shaRebase | Out-Null
    $shaPicked = _LGit rev-parse HEAD
    function _LDoc($id, $status, $sc) { return [pscustomobject]@{ items = @([pscustomobject]@{ queue_id = $id; status = $status; shipped_commit = $sc }) } }
    function _LCase($label, $doc, [string]$name, [string]$probMatch, [string]$warnMatch, [string]$stateMatch) {
      $script:ran++
      $r = Test-PlanLanded -Doc $doc -PlanName $name -PlanRel ('plans/' + $name) -RepoRoot $lrRepo -MainRef 'main'
      $pt = (@($r.problems) -join ' | '); $wt = (@($r.warnings) -join ' | '); $stt = (@($r.states) -join ' ')
      $okP = if ($probMatch) { $pt -match $probMatch } else { -not $pt }
      $okW = if ($warnMatch) { $wt -match $warnMatch } else { -not $wt }
      $okS = if ($stateMatch) { $stt -match $stateMatch } else { $true }
      if ($okP -and $okW -and $okS) { Write-Output "ok    $label" }
      else { Write-Output ("FAIL  $label  problems: " + $pt + "  warnings: " + $wt + "  states: " + $stt); $script:fail++ }
    }
    $atCut = 'plan-' + $LandedCutoff + '.json'
    _LCase "MUST FIRE: a done item whose shipped_commit is only on a side branch is refused (plan dated AT the cutoff $LandedCutoff)" (_LDoc 'q1' 'done' $shaSide) $atCut ('q1 shipped_commit ' + $shaSide + ' is not on main') '' ':not-landed'
    _LCase 'CLEAN TWIN: a done item whose commit was rebased onto main (another hash, the same patch) passes by patch-id' (_LDoc 'q1' 'done' $shaRebase) $atCut '' '' (':' + $shaRebase + ':equivalent')
    _LCase 'CLEAN TWIN: a deviated item whose exact commit is on main passes by ancestry' (_LDoc 'q1' 'deviated' $shaMain.Substring(0, 9)) $atCut '' '' ':ancestor'
    _LCase 'MUST FIRE: a shipped_commit git cannot resolve is its own problem, never a pass' (_LDoc 'q1' 'done' 'deadbee1234') $atCut 'shipped_commit deadbee1234 does not resolve in this checkout' '' ':unresolved'
    _LCase 'MUST FIRE: prose naming no hash, while main''s copy of the plan still carries the item as planned, is refused' (_LDoc 'p1' 'deviated' 'see git log: triage 2026-09-28 p1 (this commit)') 'plan-2026-09-28.json' "names no commit hash, and main's copy of plans/plan-2026-09-28.json carries it as 'planned'" '' 'p1:plan:not-landed'
    _LCase 'CLEAN TWIN: prose naming no hash passes when main''s copy of the plan carries the item as done' (_LDoc 'p2' 'done' 'this commit') 'plan-2026-09-28.json' '' '' 'p2:plan:landed'
    _LCase 'MUST NOT FIRE: a plan dated one day before the cutoff only WARNS on an unlanded commit' (_LDoc 'q1' 'done' $shaSide) 'plan-2026-09-27.json' '' ('q1 shipped_commit ' + $shaSide + ' is not on main') ':not-landed'
    $script:ran++
    $nm = Test-PlanLanded -Doc (_LDoc 'q1' 'needs-more-time' $shaSide) -PlanName $atCut -PlanRel ('plans/' + $atCut) -RepoRoot $lrRepo -MainRef 'main'
    if ($nm.judged -eq 0 -and -not @($nm.problems).Count -and -not @($nm.warnings).Count -and $shaPicked -ne $shaRebase) { Write-Output 'ok    MUST NOT FIRE: a needs-more-time item is not judged, and the rebased fixture really carries two hashes' }
    else { Write-Output ('FAIL  MUST NOT FIRE: needs-more-time judged=' + $nm.judged + ' picked=' + $shaPicked + ' rebase=' + $shaRebase); $script:fail++ }
  } catch { Write-Output ('FAIL  landed-check fixture threw: ' + $_.Exception.Message + ' at line ' + $_.InvocationInfo.ScriptLineNumber); $script:fail++ }
  finally { Remove-Item -LiteralPath $lrRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
