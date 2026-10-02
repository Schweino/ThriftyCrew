<#
  test-ruled-step-lib.ps1 -SelfTest - the frozen fixtures for grocery\ruled-step-lib.ps1 (design/
  PLAN-weekly-root-families-2026-10-02.md Phase 1, Brad's ruling D3 A).

  Two jobs, each with its founding case:
    1. A residual may be owned by 'step:<plan>#<label>' only when the plan's Status reads RULED or under way and the
       step exists and is not [DONE. MUST FIRE: a step of a DONE plan, of a PROPOSED plan, of a missing plan.
       MUST NOT FIRE: a RULED plan's step. CLEAN TWIN: a '### 3b. ... TRIAL DONE, NOT BUILT' heading is not finished.
    2. A ruled step not under way 14 days after its ruling, with attributed alerts, reads STALLED. The founding case is
       steps 8, 9 and 11, ruled 2026-09-10 and unmoved on 2026-10-02. The bar is 14 days: the case AT it (14, fires)
       and one day short of it (13, silent) sit on integers, plus one past it (15). When the producer stops (og-13):
       alerts raised and none attributed reads BLIND.
  Hermetic: plans are written to a per-run temp directory (og-38), and the plan state is a stub, so no python child
  runs. The real --plan-state answer is fixtured in ops/plan_citation.py's own self-test.
#>
# gate-inputs: grocery\test-ruled-step-lib.ps1, grocery\ruled-step-lib.ps1
# gate-inputs-text: grocery\ruled-steps.json
[CmdletBinding()]
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
. (Join-Path $root 'ruled-step-lib.ps1')
if (-not $SelfTest) { Write-Output 'usage: test-ruled-step-lib.ps1 -SelfTest'; exit 0 }

$script:rPass = 0; $script:rFail = 0; $script:rCases = 0
function Assert-RCase([string]$Label, [scriptblock]$Check) {
  $script:rCases++
  $ok = $false; $err = ''
  try { $ok = [bool](& $Check) } catch { $err = $_.Exception.Message }
  if ($ok) { $script:rPass++; Write-Output ('  PASS  ' + $Label) }
  else { $script:rFail++; Write-Output ('  FAIL  ' + $Label + $(if ($err) { '  [threw: ' + $err + ']' } else { '' })) }
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('rsl-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
New-Item -ItemType Directory -Path (Join-Path $tmp 'design') -ErrorAction Stop | Out-Null
New-Item -ItemType Directory -Path (Join-Path $tmp 'grocery') -ErrorAction Stop | Out-Null
try {
  $planBody = "`n`n## 2. Steps`n`n### 8. Ruling 2, the row contract`n`ntext`n`n### 3b. Family Fare catalog walk: TRIAL DONE, NOT BUILT`n`ntext`n`n### 9. Ruling 3, two-signal identity [DONE 2026-11-01]`n`ntext`n`n### Phase 5. Chain data flow`n`ntext`n"
  $plans = @{
    'design/PLAN-ruled.md'    = '**Status: RULED 2026-09-10, not started.**'
    'design/PLAN-done.md'     = '**Status: DONE 2026-09-30 (ruled 2026-09-10).**'
    'design/PLAN-proposed.md' = '**Status: PROPOSED 2026-10-02, awaiting rulings.**'
  }
  foreach ($k in $plans.Keys) { [IO.File]::WriteAllText((Join-Path $tmp $k), ('# PLAN: fixture' + "`n`n" + $plans[$k] + $planBody)) }
  # The stub answers what ops/plan_citation.py would for each Status line above (its own self-test fixtures that).
  $stub = { param($full) switch -Regex ($full) { 'PLAN-ruled' { 'under-way' } 'PLAN-done' { 'finished' } 'PLAN-proposed' { 'not-yet' } default { 'missing' } } }

  Assert-RCase 'MUST NOT FIRE  a step of a RULED plan owns a residual (step:design/PLAN-ruled.md#8)' {
    (Test-StepOwner 'step:design/PLAN-ruled.md#8' $tmp $stub) -eq '' }
  Assert-RCase 'MUST FIRE  a step of a DONE plan is refused, and the reason says DONE' {
    (Test-StepOwner 'step:design/PLAN-done.md#8' $tmp $stub) -match 'refused - its Status reads DONE' }
  Assert-RCase 'MUST FIRE  a step of a PROPOSED plan is refused' {
    (Test-StepOwner 'step:design/PLAN-proposed.md#8' $tmp $stub) -match 'refused - its Status reads PROPOSED' }
  Assert-RCase 'MUST FIRE  a plan that does not exist resolves to nothing' {
    (Test-StepOwner 'step:design/PLAN-absent.md#8' $tmp $stub) -match 'resolves to nothing - no plan' }
  Assert-RCase 'MUST FIRE  a label the plan has no heading for is refused' {
    (Test-StepOwner 'step:design/PLAN-ruled.md#12' $tmp $stub) -match "no heading labelled '12'" }
  Assert-RCase 'MUST FIRE  a step whose heading reads [DONE owns no new work' {
    (Test-StepOwner 'step:design/PLAN-ruled.md#9' $tmp $stub) -match 'reads \[DONE' }
  Assert-RCase 'CLEAN TWIN  3b''s heading "TRIAL DONE, NOT BUILT" is not finished, so 3b may own a residual' {
    (Test-StepOwner 'step:design/PLAN-ruled.md#3b' $tmp $stub) -eq '' }
  Assert-RCase 'CLEAN TWIN  a "### Phase 5." heading is addressed as #phase-5, any letter case' {
    ((Test-StepOwner 'step:design/PLAN-ruled.md#phase-5' $tmp $stub) -eq '') -and ((Test-StepOwner 'step:design/PLAN-ruled.md#Phase-5' $tmp $stub) -eq '') }
  Assert-RCase 'CLEAN TWIN  a ref followed by sentence punctuation ("#8." or "#phase-5:") resolves to its step (2026-10-02: closing notes read "step:<plan>#8. The shadow...")' {
    ((Test-StepOwner 'step:design/PLAN-ruled.md#8.' $tmp $stub) -eq '') -and ((Test-StepOwner 'step:design/PLAN-ruled.md#phase-5:' $tmp $stub) -eq '') }
  Assert-RCase 'MUST FIRE  a rooted plan path is refused (the owner must be a file the repo versions)' {
    (Test-StepOwner ('step:' + (Join-Path $tmp 'design/PLAN-ruled.md') + '#8') $tmp $stub) -match 'repo-relative' }
  Assert-RCase 'MUST FIRE  a plan state the stub has never heard of throws loudly (og-16), never a quiet pass' {
    $threw = $false; try { Test-StepOwner 'step:design/PLAN-ruled.md#8' $tmp { param($f) 'sideways' } | Out-Null } catch { $threw = ($_.Exception.Message -match 'unknown plan state: sideways') }; $threw }

  # ---- attribution and the stall clock ----
  $steps = @(
    [pscustomobject]@{ ref = 'design/PLAN-ruled.md#8'; family = '1'; ruled = '2026-09-10'; under_way_evidence = @('grocery/row-contract-lib.ps1'); type_prefixes = @('grocery a price band refused rows') },
    [pscustomobject]@{ ref = 'design/PLAN-ruled.md#3b'; family = '4'; ruled = '2026-09-10'; under_way_evidence = @(); type_prefixes = @() }
  )
  $census = @(
    [pscustomobject]@{ date = '2026-09-20'; type = 'grocery a price band refused rows it cannot explain'; alerts = 1 },
    [pscustomobject]@{ date = '2026-09-23'; type = 'grocery a price band refused rows it cannot explain'; alerts = 2 },
    [pscustomobject]@{ date = '2026-09-23'; type = 'grocery capture watchdog issue s'; alerts = 4 }
  )
  $queue = @(
    [pscustomobject]@{ id = 'q1'; status = 'resolved'; disposition = 'owned-by-step'; resolved_ts = '2026-09-22T10:00:00'; notes = 'owned by step:design/PLAN-ruled.md#8 (Phase 1 re-home)' },
    [pscustomobject]@{ id = 'q2'; status = 'resolved'; disposition = 'confirmed'; resolved_ts = '2026-09-22T10:00:00'; notes = 'step:design/PLAN-ruled.md#8' }
  )
  $planItems = @([pscustomobject]@{ date = '2026-09-21'; leaves_open_followup = 'step: design/PLAN-ruled.md#8' })
  $att = Get-RuledStepAttribution $steps $census $queue $planItems ([datetime]'2026-09-23') 14
  $a8 = @($att.steps | Where-Object { $_.ref -eq 'design/PLAN-ruled.md#8' })[0]
  Assert-RCase 'MUST FIRE  attribution counts the census type, the owned-by-step close and the plan owner (3 + 1 + 1), and not a confirmed close' {
    ($a8.census -eq 3) -and ($a8.owned -eq 1) -and ($a8.plan_owned -eq 1) -and ($a8.attributed -eq 5) -and ($att.total_alerts -eq 7) }

  $at = { param([string]$day) $v = @(Get-RuledStepVerdicts $steps (Get-RuledStepAttribution $steps $census $queue $planItems ([datetime]$day) 14) ([datetime]$day) $tmp); @($v | Where-Object { $_.ref -eq 'design/PLAN-ruled.md#8' })[0] }
  $v13 = & $at '2026-09-23'   # 13 days after the 2026-09-10 ruling
  $v14 = & $at '2026-09-24'   # exactly 14: the bar
  $v15 = & $at '2026-09-25'   # one past it
  Assert-RCase 'MUST NOT FIRE  13 days after its ruling (one short of the 14-day bar) the step is not stalled' { ($v13.days -eq 13) -and (-not $v13.stalled) }
  Assert-RCase 'MUST FIRE  AT the 14-day bar, not under way and with attributed alerts, the step is STALLED' { ($v14.days -eq 14) -and $v14.stalled -and (-not $v14.under_way) }
  Assert-RCase 'MUST FIRE  one day past the bar (15) it is still STALLED' { ($v15.days -eq 15) -and $v15.stalled }
  $v3b = @(Get-RuledStepVerdicts $steps (Get-RuledStepAttribution $steps $census $queue $planItems ([datetime]'2026-10-02') 14) ([datetime]'2026-10-02') $tmp | Where-Object { $_.ref -eq 'design/PLAN-ruled.md#3b' })[0]
  Assert-RCase 'MUST NOT FIRE  a step past the bar with NO attributed alerts is not stalled (nothing is paying for it)' { ($v3b.days -eq 22) -and ($v3b.attributed -eq 0) -and (-not $v3b.stalled) }
  [IO.File]::WriteAllText((Join-Path $tmp 'grocery/row-contract-lib.ps1'), '# evidence')
  $v14b = & $at '2026-09-24'
  Assert-RCase 'CLEAN TWIN  the same step at the bar with its evidence file present is under way and not stalled' { $v14b.under_way -and (-not $v14b.stalled) -and ($v14b.attributed -eq 5) }

  # ---- og-13: the producer stops ----
  Assert-RCase 'MUST FIRE  alerts raised in 7 days and none attributed reads BLIND (a renamed type)' {
    $renamed = @([pscustomobject]@{ date = '2026-09-23'; type = 'grocery band refused rows renamed'; alerts = 2 })
    (Get-RuledStepBlind $steps $renamed ([datetime]'2026-09-23')) -match '^2 alert\(s\) were raised .* attributed 0' }
  Assert-RCase 'MUST NOT FIRE  a week with attributed alerts is not BLIND' { (Get-RuledStepBlind $steps $census ([datetime]'2026-09-23')) -eq '' }
  Assert-RCase 'CLEAN TWIN  a quiet week (no alerts at all) is not BLIND: nothing raised, nothing to attribute' { (Get-RuledStepBlind $steps @() ([datetime]'2026-09-23')) -eq '' }

  # ---- the live map parses, and every ref in it resolves to a heading (a typo would never attribute) ----
  $repo = Split-Path $root -Parent
  $map = Read-RuledSteps (Join-Path $root 'ruled-steps.json')
  Assert-RCase 'CLEAN TWIN  grocery\ruled-steps.json reads, and every step ref names a heading in its plan' {
    $bad = @(); foreach ($s in @($map.steps)) { $p = ([string]$s.ref).Split('#'); $f = Join-Path $repo $p[0]; if (-not (Test-Path -LiteralPath $f) -or -not (Get-PlanStepHeading ([IO.File]::ReadAllText($f)) $p[1])) { $bad += [string]$s.ref } }
    $map.ok -and (@($map.steps).Count -ge 7) -and ($bad.Count -eq 0) }
  Assert-RCase 'CLEAN TWIN  no census type prefix is claimed by two steps (a total over steps never counts an alert twice)' {
    $seen = @{}; $dup = 0; foreach ($s in @($map.steps)) { foreach ($t in @($s.type_prefixes)) { if ($seen.ContainsKey([string]$t)) { $dup++ } else { $seen[[string]$t] = 1 } } }; $dup -eq 0 }
} finally {
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

$expected = 22
if ($script:rCases -ne $expected) { Write-Output ("test-ruled-step-lib self-test: FAIL (ran {0} case(s), expected {1})" -f $script:rCases, $expected); exit 1 }
if ($script:rFail -gt 0) { Write-Output ("test-ruled-step-lib self-test: FAIL ({0} of {1} case(s) failed)" -f $script:rFail, $script:rCases); exit 1 }
Write-Output ("test-ruled-step-lib self-test: PASS ({0} of {0} case(s))" -f $script:rCases)
exit 0
