<#
  test-cadence.ps1 - self-test for the CADENCE gate in check-ad-cycles.ps1.

  WHY IT EXISTS. On 2026-08-22 the daily chain took 27-42 minutes on a 32-thread machine idling at 14%
  CPU, and most of the tail was checks re-answering a question whose inputs had not moved (test-auditors
  877 s over frozen fixtures, the embedding sweep 136-900 s, commodity-dupes 110 s over a registry only a
  human edits). Test-CadenceDue skips those unless the clock OR their own inputs say otherwise.

  TWO PROPERTIES THIS MUST HOLD, and the first version broke the second:
    1. A SKIP IS NOT A PASS. An unreadable or missing stamp must run the check, never skip it.
    2. AN INPUT EDIT IS DUE TODAY. A commit that blinds a guard has to be caught the same day, not up to
       seven days later - otherwise the cadence trades minutes for exactly the blindness the estate's
       whole guard culture exists to prevent.
  The founding bug: Set-CadenceRan stamped with ToString('s'), which truncates to the second, so an input
  written in the SAME second read as newer than the stamp and every check was due forever - the cadence
  would have cost its full runtime while looking like it worked. Round-trip 'o' fixes it, and case 2
  below is what caught it.

  Extracts the real functions out of check-ad-cycles.ps1 (it cannot be dot-sourced - that runs the whole
  daily chain) and drives them against a sandbox, so this tests the shipped code, not a copy of it.
#>
$src = Get-Content 'C:\Codex\ThriftyCrew\grocery\check-ad-cycles.ps1' -Raw
$m = [regex]::Match($src, '(?s)function Test-CadenceDue \{.*?\n\}\r?\nfunction Set-CadenceRan.*?\n\}\r?\nfunction Get-CadenceLast.*?\n\}')
if (-not $m.Success) { 'FAIL: could not extract the helpers'; exit 1 }
$sandbox = Join-Path $env:TEMP ('cad-' + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
$script:CadenceRoot = $sandbox
$script:CadenceDir  = Join-Path $sandbox 'cadence'
New-Item -ItemType Directory -Path $script:CadenceDir -Force | Out-Null
Invoke-Expression $m.Value
$fail = 0
function T($ok,$m){ if($ok){"  ok    $m"}else{"  FAIL  $m"; $script:fail++} }

$inp = Join-Path $sandbox 'thing.ps1'
Set-Content $inp -Value 'x'

T (Test-CadenceDue -Name 'x' -EveryDays 7 -InputGlobs @('thing.ps1')) 'never run before -> DUE'
Set-CadenceRan 'x'
T (-not (Test-CadenceDue -Name 'x' -EveryDays 7 -InputGlobs @('thing.ps1'))) 'just ran, input unchanged -> SKIP'
Start-Sleep -Seconds 1
Set-Content $inp -Value 'y'          # the input moves
T (Test-CadenceDue -Name 'x' -EveryDays 7 -InputGlobs @('thing.ps1')) 'INPUT CHANGED -> DUE the same day (a commit that blinds a guard is still caught)'
Set-CadenceRan 'x'
T (-not (Test-CadenceDue -Name 'x' -EveryDays 7 -InputGlobs @('thing.ps1'))) 're-ran after the edit -> SKIP again'
# clock path
Set-Content (Join-Path $script:CadenceDir 'cadence-old.txt') -Value ((Get-Date).AddDays(-8).ToString('s'))
T (Test-CadenceDue -Name 'old' -EveryDays 7 -InputGlobs @()) '8 days since last run -> DUE on the clock alone'
# fail-open
Set-Content (Join-Path $script:CadenceDir 'cadence-bad.txt') -Value 'not-a-date'
T (Test-CadenceDue -Name 'bad' -EveryDays 7 -InputGlobs @()) 'unreadable stamp -> DUE (fails OPEN, never silently skips)'
T ((Get-CadenceLast 'nope') -eq 'never') 'a never-run check reports "never", not a fake date'

# ---- THE WEEKLY GUARD PROOF (2026-09-10, queue 2026-09-10-267ba6), lifted from the SHIPPED source like the helpers above ----
# Frozen from the founding morning: chain-verdict.json guards_rc=2 at 08:11:12, the weekly stamp last written
# 2026-09-03, and the runner rc=3 at 08:26:38 that stamped the week closed anyway.
$m2 = [regex]::Match($src, '(?s)function Get-TestGuardsWeeklyPlan \{.*?\n\}\r?\nfunction Get-TestGuardsStampPlan \{.*?\n\}\r?\nfunction Get-TestGuardsSubject \{.*?\n\}')
if (-not $m2.Success) { T $false 'could not extract the test-guards weekly helpers from check-ad-cycles.ps1' }
else {
  Invoke-Expression $m2.Value
  $now = [datetime]'2026-09-10T08:26:38'
  $red   = [pscustomobject]@{ date = '2026-09-10'; guards_rc = 2; guards_blocked = $true }
  $green = [pscustomobject]@{ date = '2026-09-10'; guards_rc = 0; guards_blocked = $false }
  $p1 = Get-TestGuardsWeeklyPlan -Verdict $red -Today '2026-09-10' -WeeklyLast $now.AddDays(-7.2) -ProvedLast $now.AddDays(-3) -UnprovenAlertLast ([datetime]'2000-01-01') -Now $now
  T ($p1.action -eq 'defer') 'MUST FIRE  guards_rc=2 with the weekly stamp over 7 days old -> DEFER (the 2026-09-10 slot was spent on a red baseline)'
  $st3 = Get-TestGuardsStampPlan -Rc 3
  T ((-not $st3.weekly) -and (-not $st3.proved)) 'MUST FIRE  an unevaluable run (rc 3) writes NEITHER stamp, so the week stays open'
  $p2 = Get-TestGuardsWeeklyPlan -Verdict $red -Today '2026-09-10' -WeeklyLast $now.AddDays(-8) -ProvedLast $now.AddDays(-15) -UnprovenAlertLast ([datetime]'2000-01-01') -Now $now
  T ($p2.alert_unproven) 'MUST FIRE  a proved stamp 15 days old pages the unproven alert'
  $p3 = Get-TestGuardsWeeklyPlan -Verdict $green -Today '2026-09-10' -WeeklyLast $now.AddDays(-8) -ProvedLast $now.AddDays(-8) -UnprovenAlertLast ([datetime]'2000-01-01') -Now $now
  T (($p3.action -eq 'run') -and (-not $p3.alert_unproven)) 'CLEAN TWIN  guards_rc=0 with the weekly stamp 8 days old -> RUN, and an 8-day-old proof does not page'
  $st0 = Get-TestGuardsStampPlan -Rc 0
  $st1 = Get-TestGuardsStampPlan -Rc 1
  T ($st0.weekly -and $st0.proved) 'CLEAN TWIN  runner rc=0 writes both stamps'
  T ($st1.weekly -and (-not $st1.proved) -and ((Get-TestGuardsSubject -Rc 1) -match 'BLOCKING invariant can no longer fail')) 'CLEAN TWIN  runner rc=1 writes the weekly stamp only and still sends "a BLOCKING invariant can no longer fail"'
  $p5 = Get-TestGuardsWeeklyPlan -Verdict $null -Today '2026-09-10' -WeeklyLast $now.AddDays(-8) -ProvedLast $now -UnprovenAlertLast $now -Now $now
  T ($p5.action -eq 'defer') 'MUST FIRE  no verdict on disk is a DEFER, never a run on an unknown baseline'
  $p6 = Get-TestGuardsWeeklyPlan -Verdict ([pscustomobject]@{ date = '2026-09-09'; guards_rc = 0 }) -Today '2026-09-10' -WeeklyLast $now.AddDays(-8) -ProvedLast $now -UnprovenAlertLast $now -Now $now
  T ($p6.action -eq 'defer') 'MUST FIRE  yesterday''s green verdict does not green-light today''s run'
  $p7 = Get-TestGuardsWeeklyPlan -Verdict $green -Today '2026-09-10' -WeeklyLast $now.AddDays(-2) -ProvedLast $now -UnprovenAlertLast $now -Now $now
  T ($p7.action -eq 'not-due') 'CLEAN TWIN  a week not yet due stays not-due on a green day'
  $p8 = Get-TestGuardsWeeklyPlan -Verdict $red -Today '2026-09-10' -WeeklyLast $now.AddDays(-8) -ProvedLast $now.AddDays(-20) -UnprovenAlertLast $now.AddDays(-3) -Now $now
  T (-not $p8.alert_unproven) 'MUST NOT FIRE  the unproven alert does not repeat within 14 days of the last one'
  # AND THE CHAIN CALLS THEM - a helper nothing invokes is decoration.
  T (($src -match 'Get-TestGuardsWeeklyPlan -Verdict \$tgVerdict') -and ($src -match 'Get-TestGuardsStampPlan -Rc \$tgRc') -and ($src -match 'Get-TestGuardsSubject -Rc \$tgRc') -and ($src -match 'test-guards weekly DEFERRED')) 'MUST FIRE  check-ad-cycles.ps1 drives its weekly block through these three functions'
}
Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue
if ($fail) { "CADENCE SELF-TEST FAILED ($fail)"; exit 1 } else { 'CADENCE SELF-TEST PASS'; exit 0 }
