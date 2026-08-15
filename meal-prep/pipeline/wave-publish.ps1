# wave-publish.ps1 - the ONLY sanctioned path from a green wave audit to live recipe posts.
#
# WHY THIS EXISTS (2026-08-15). The Recipe Hunter v2 publishes automatically: Brad approved removing the
# human gate, which means the gates that remain are the only thing between a hunted recipe and the site.
# This script is where they are enforced, in one place, so "did the audit pass" cannot be answered from a
# session's memory of what it thinks it did.
#
# IT PUBLISHES THROUGH THE ENGINE, NOT THROUGH ITS OWN GHOST CALL. engine\publish.ps1 already owns the
# hard-won behaviour: it PRESERVES visibility on update (rotate-free-dinners owns visibility, and a
# hardcoded 'paid' upsert would re-paywall every hand-freed dinner), it distinguishes a 404 from a
# transport error so a swallowed failure cannot mint a paid <slug>-2 orphan, it isolates per-slug
# failures, and it verifies the live page after each post. propagate-recipes.ps1 wraps it with the rest of
# the chain (recipes-db sync -> audit-db-agreement hard gate -> planner data -> cards -> hash-gated
# publish) and only advances its stamps after every stage succeeds. Re-implementing any of that here would
# be a second copy of a rule the estate has already paid to get right.
#
# WHAT IT DELIBERATELY DOES NOT RUN: pipeline\spec-guards.ps1 full mode. It CANNOT run against db\recipes
# specs - it merges prose from specs\prose\prose-<slug>.json files the engine no longer produces, and on
# pass it re-serialises the whole spec, which is the documented \uXXXX prose-corruption trap
# (NEXT-RUN-PLAYBOOK, "SPEC-GUARDS ON THE v2 PATH"). Its invariants are still the contract; the v2
# enforcers are build-v2-spec's write-time guards plus the audits run below.
#
# Usage:
#   .\wave-publish.ps1 -RunDir <p> -Wave 1 -DryRun     walk every gate, print what would ship, publish nothing
#   .\wave-publish.ps1 -RunDir <p> -Wave 1             for real
#   .\wave-publish.ps1 -SelfTest
param(
  [string]$RunDir = '', [int]$Wave = 0,
  [switch]$DryRun, [switch]$SelfTest, [switch]$SkipGit, [switch]$SkipGhostCheck,
  # -LedgerPath exists ONLY so the gate drill can run over a scratch ledger instead of writing a fake
  # batch into the live one (a test row there would never close cleanly and batch-ledger -Verify would
  # report it as a stalled batch forever). The default is the live path, exactly as cost-recipes.ps1's
  # -DbRoot works for the golden test. It does not weaken the gate: the audit stamp still has to exist.
  [string]$LedgerPath = ''
)
$ErrorActionPreference = 'Stop'
# capture switches before dot-sourcing anything (a dot-sourced param() block binds in THIS scope)
$runSelfTest = [bool]$SelfTest; $runDryRun = [bool]$DryRun
$runSkipGit = [bool]$SkipGit; $runSkipGhost = [bool]$SkipGhostCheck

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp   = Split-Path -Parent $here                      # ...\meal-prep
$repo = Split-Path -Parent $mp                        # ...\income
. (Join-Path $repo 'lib\guard-contract.ps1')

# ===================================================================================================
# PURE GATE PREDICATES - so each founding bug can be pinned without touching a live file or Ghost.
# ===================================================================================================

# THE AUDIT VERDICT. Only an explicit GO publishes. Anything else - a NO-GO, an empty file, or a report
# that merely reads encouragingly - refuses. "Sounds positive" is not a verdict, and a wave that cannot
# state GO on its first line has not been audited as far as this script is concerned.
function Get-AuditVerdict {
  param($Lines)
  $first = @(@($Lines) | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() -ne '' })
  if (-not $first.Count) { return 'UNREADABLE' }
  $t = $first[0].Trim()
  if ($t -match '^(?i)NO[-\s]?GO\b') { return 'NO-GO' }     # tested BEFORE GO: "NO-GO" contains "GO"
  if ($t -match '^(?i)GO\b')         { return 'GO' }
  return 'UNREADABLE'
}

# EVERY SLUG IN THE MANIFEST MUST BE SITTING IN THIS WAVE. A slug that slipped back to `written` (a QA
# repair) or into another wave is not covered by this wave's audit, and this wave's audit is the only
# thing authorising a publish.
function Get-WaveStateProblems {
  param($Entries, $Slugs, [int]$K)
  $byslug = @{}
  foreach ($e in @($Entries)) { $byslug[[string]$e.slug] = $e }
  $problems = @()
  foreach ($s in @($Slugs)) {
    if (-not $byslug.ContainsKey($s)) { $problems += ("{0}: no state file" -f $s); continue }
    $e = $byslug[$s]
    $st = [string]$e.state
    if ($st -eq 'published' -or $st -eq 'verified') { continue }   # resume: already shipped, upsert is safe
    if ($st -ne 'waved') { $problems += ("{0}: state is '{1}', expected 'waved'" -f $s, $st); continue }
    if ([int]$e.wave -ne $K) { $problems += ("{0}: sits in wave {1}, not {2}" -f $s, [int]$e.wave, $K) }
  }
  return @($problems)
}

# A dirty spec outside this wave is not ours. propagate carries everything dirty by design (that is what
# makes it the one command after any spec edit), so this does not block - but it must be SAID, or a wave
# quietly ships another session's half-finished edit and the ledger records it as ours.
function Get-ForeignDirty {
  param($Dirty, $Slugs)
  return @(@($Dirty) | Where-Object { @($Slugs) -notcontains $_ })
}

function Test-LedgerStamped {
  param($Row, [string]$Stage)
  return (@(@($Row.stages) | ForEach-Object { [string]$_.stage }) -contains $Stage)
}

# THE COST BASIS. Every live spec carries stat.cost_ps on the EVERYDAY basis (cost_first_run / servings),
# which is what pipeline\v2-perserving.json publishes as everyday_ps. A brand-new recipe is not in that
# manifest when build-v2-spec runs, so it silently falls back to batch/14 - roughly HALF. Shipping that
# both understates the price to the reader and, because the free-dinner rotation and hub Top 5 rank a
# pooled set, lets the wrongly-based recipe falsely dominate the cheapest lists.
function Get-CostBasisProblems {
  param($Specs, $ManifestRows, [double]$Tolerance = 0.02)
  $problems = @()
  foreach ($s in @($Specs)) {
    $slug = [string]$s.slug
    if (-not $ManifestRows.ContainsKey($slug)) { $problems += ("{0}: absent from v2-perserving.json" -f $slug); continue }
    $want = [double]$ManifestRows[$slug].everyday_ps
    $got  = [double]$s.cost_ps
    if ([Math]::Abs($want - $got) -gt $Tolerance) { $problems += ("{0}: stat.cost_ps {1} but manifest everyday {2}" -f $slug, $got, $want) }
  }
  return @($problems)
}

# ===================================================================================================
# SELF-TEST
# ===================================================================================================
if ($runSelfTest) {
  $f = 0
  function T($msg, $cond, $got) { if ($cond) { Write-Output ("ok    " + $msg) } else { Write-Output ("FAIL  " + $msg + "   got: " + $got); $script:f++ } }

  # ---- THE FOUNDING GATE, frozen. An auditor NO-GO blocks publish, full stop.
  T 'MUST FIRE  a NO-GO audit refuses to publish' `
    ((Get-AuditVerdict @('NO-GO', '', 'blocked: 3 recipes quote a stale price')) -eq 'NO-GO') 'not refused'
  T 'MUST FIRE  an empty audit file is not a GO'      ((Get-AuditVerdict @()) -eq 'UNREADABLE') 'read as GO'
  T 'MUST FIRE  a blank-only audit file is not a GO'  ((Get-AuditVerdict @('', '   ')) -eq 'UNREADABLE') 'read as GO'
  # the dangerous near-miss: a report that READS positive but never states the verdict
  T 'MUST FIRE  prose that merely sounds approving is not a GO' `
    ((Get-AuditVerdict @('Everything checks out, no blockers found.')) -eq 'UNREADABLE') 'read as GO'
  T 'MUST FIRE  "NO-GO" is not parsed as "GO" because it contains it' `
    ((Get-AuditVerdict @('NO-GO - macros disagree on 2 recipes')) -eq 'NO-GO') 'parsed as GO'
  T 'CLEAN TWIN a GO first line publishes'            ((Get-AuditVerdict @('GO', 'all 10 recipes clean')) -eq 'GO') 'refused a GO'
  T 'CLEAN TWIN GO with a trailing summary on the same line' ((Get-AuditVerdict @('GO - 10/10 clean')) -eq 'GO') 'refused a GO'
  T 'leading blank lines do not defeat the verdict'   ((Get-AuditVerdict @('', 'GO')) -eq 'GO') 'refused a GO'

  # ---- the wave must actually contain what the manifest claims
  $entries = @(
    [pscustomobject]@{ slug = 'a'; state = 'waved';  wave = 1 },
    [pscustomobject]@{ slug = 'b'; state = 'waved';  wave = 1 },
    [pscustomobject]@{ slug = 'c'; state = 'written'; wave = $null }
  )
  T 'CLEAN TWIN a wave whose slugs are all waved has no problems' `
    ((Get-WaveStateProblems $entries @('a', 'b') 1).Count -eq 0) 'spurious problem'
  T 'MUST FIRE  a slug that fell back to `written` blocks the wave' `
    ((Get-WaveStateProblems $entries @('a', 'c') 1).Count -eq 1) 'let an unaudited recipe publish'
  T 'MUST FIRE  a slug with no state file blocks the wave' `
    ((Get-WaveStateProblems $entries @('a', 'zzz') 1).Count -eq 1) 'published a slug with no state'
  T 'MUST FIRE  a slug belonging to a different wave blocks' `
    ((Get-WaveStateProblems @([pscustomobject]@{ slug = 'a'; state = 'waved'; wave = 2 }) @('a') 1).Count -eq 1) 'published out of wave'
  T 'CLEAN TWIN an already-published slug is fine on a resume' `
    ((Get-WaveStateProblems @([pscustomobject]@{ slug = 'a'; state = 'published'; wave = 1 }) @('a') 1).Count -eq 0) 'blocked a resume'

  # ---- foreign dirt is reported, never silently carried
  T 'MUST FIRE  a dirty spec outside the wave is reported' `
    ((Get-ForeignDirty @('a', 'b', 'someone-elses-recipe') @('a', 'b')) -contains 'someone-elses-recipe') 'carried silently'
  T 'CLEAN TWIN a wave whose dirt is exactly its own reports nothing' `
    ((Get-ForeignDirty @('a', 'b') @('a', 'b')).Count -eq 0) 'spurious report'

  # ---- the ledger stamp the auditor owes before this script will run
  $row = [pscustomobject]@{ stages = @([pscustomobject]@{ stage = 'select' }, [pscustomobject]@{ stage = 'audit' }) }
  T 'CLEAN TWIN an audit-stamped batch passes the ledger gate' (Test-LedgerStamped $row 'audit') 'refused'
  T 'MUST FIRE  a batch with no audit stamp is refused' `
    (-not (Test-LedgerStamped ([pscustomobject]@{ stages = @([pscustomobject]@{ stage = 'select' }) }) 'audit')) 'allowed'
  T 'MUST FIRE  a batch with NO stages at all is refused' `
    (-not (Test-LedgerStamped ([pscustomobject]@{ stages = @() }) 'audit')) 'allowed'

  # ---- THE COST BASIS, frozen from the 2026-08-15 shakedown. Both recipes built with stat.cost_ps on
  # the batch/14 fallback because a new slug is not in the manifest yet: Country Captain would have
  # published $1.87 against a real everyday cost of $3.73, Florentine $1.66 against $3.26.
  $mrows = @{ 'country-captain-chicken' = [pscustomobject]@{ everyday_ps = 3.73 }
              'chicken-florentine'      = [pscustomobject]@{ everyday_ps = 3.26 } }
  $halfPriced = @([pscustomobject]@{ slug = 'country-captain-chicken'; cost_ps = 1.87 })
  T 'MUST FIRE  a spec still on the batch/14 fallback is caught before publish' `
    ((Get-CostBasisProblems $halfPriced $mrows).Count -eq 1) 'published at half price'
  $corrected = @([pscustomobject]@{ slug = 'country-captain-chicken'; cost_ps = 3.73 },
                 [pscustomobject]@{ slug = 'chicken-florentine';      cost_ps = 3.26 })
  T 'CLEAN TWIN specs re-anchored to the everyday basis pass' `
    ((Get-CostBasisProblems $corrected $mrows).Count -eq 0) 'spurious problem'
  T 'MUST FIRE  a slug missing from the manifest entirely is caught' `
    ((Get-CostBasisProblems @([pscustomobject]@{ slug = 'brand-new'; cost_ps = 2.00 }) $mrows).Count -eq 1) 'let an unmeasured slug through'
  T 'penny rounding does not trip the basis check' `
    ((Get-CostBasisProblems @([pscustomobject]@{ slug = 'chicken-florentine'; cost_ps = 3.27 }) $mrows).Count -eq 0) 'too strict'

  if ($f -eq 0) { Write-Output 'wave-publish SELF-TEST PASS'; exit 0 }
  Write-Output ("wave-publish SELF-TEST FAIL: {0} case(s)" -f $f); exit 1
}

# ===================================================================================================
# LIVE
# ===================================================================================================
if (-not $RunDir -or $Wave -le 0) { Write-Output 'wave-publish: -RunDir and -Wave are required'; exit 1 }
if (-not (Test-Path $RunDir)) { Write-Output ("wave-publish: RunDir not found: {0}" -f $RunDir); exit 1 }

$UTF8 = New-Object System.Text.UTF8Encoding($false)
function Read-Json { param([string]$P) return (([IO.File]::ReadAllText($P, [Text.Encoding]::UTF8) -replace "^﻿", '') | ConvertFrom-Json) }
function Fail { param([string]$M) Write-Output ("wave-publish: REFUSED - " + $M); Write-GuardComplete -Name 'wave-publish' -Summary 'refused'; exit 1 }

$manPath = Join-Path $RunDir ("waves\wave-{0}.json" -f $Wave)
if (-not (Test-Path $manPath)) { Fail ("no manifest at {0} - close the wave first (hunt-run.ps1 -WaveClose)" -f $manPath) }
$man   = Read-Json $manPath
$slugs = @(@($man.slugs) | ForEach-Object { [string]$_ })
$batch = [string]$man.batch
if (-not $slugs.Count) { Fail 'the wave manifest lists no slugs' }

Write-Output ("wave-publish: {0}  wave {1}  ({2} recipe(s)){3}" -f $man.run, $Wave, $slugs.Count, $(if ($runDryRun) { '   [DRY RUN]' } else { '' }))
Write-Output ''
Write-Output '== PREFLIGHT =============================================================='

# ---- P1. the audit verdict -----------------------------------------------------------------------
$auditPath = Join-Path $RunDir ("waves\wave-{0}.audit.md" -f $Wave)
if (-not (Test-Path $auditPath)) { Fail ("no audit report at {0}. The recipe-batch-auditor must write one whose FIRST line is GO or NO-GO." -f $auditPath) }
$verdict = Get-AuditVerdict (Get-Content $auditPath -Encoding UTF8)
if ($verdict -ne 'GO') {
  Fail ("the wave audit reads '{0}', not GO ({1}). A NO-GO blocks publish, full stop - repair the named recipes, re-audit, then re-run." -f $verdict, $auditPath)
}
Write-Output ("  P1  audit verdict          GO   ({0})" -f (Split-Path $auditPath -Leaf))

# ---- P2. the ledger must carry the audit stamp ----------------------------------------------------
$ledgerPath = if ($LedgerPath) { $LedgerPath } else { Join-Path $mp 'db\batch-ledger.json' }
if (-not (Test-Path $ledgerPath)) { Fail ("no batch ledger at {0}" -f $ledgerPath) }
$ledger = @(Read-Json $ledgerPath)
$row = @($ledger | Where-Object { [string]$_.batch -eq $batch })[0]
if (-not $row) { Fail ("no ledger row for batch '{0}' - hunt-run.ps1 -WaveClose opens it" -f $batch) }
if (-not (Test-LedgerStamped $row 'audit')) {
  Fail ("batch '{0}' has no 'audit' stamp. The orchestrator stamps it AFTER the auditor returns GO: batch-ledger.ps1 -Stamp -Batch {0} -Stage audit -Detail '<n>/<n> GO'" -f $batch)
}
Write-Output ("  P2  ledger audit stamp     present   (batch {0})" -f $batch)

# ---- P3. every slug is sitting in this wave -------------------------------------------------------
$stateDir = Join-Path $RunDir 'state'
$entries = @()
if (Test-Path $stateDir) { $entries = @(Get-ChildItem (Join-Path $stateDir '*.json') -File | ForEach-Object { Read-Json $_.FullName }) }
$problems = @(Get-WaveStateProblems $entries $slugs $Wave)
if ($problems.Count) { $problems | ForEach-Object { Write-Output ("      ! " + $_) }; Fail ("{0} slug(s) are not in wave {1}" -f $problems.Count, $Wave) }
Write-Output ("  P3  recipe states          all {0} in wave {1}" -f $slugs.Count, $Wave)

# ---- P4. the spec and its card source actually exist ----------------------------------------------
$missing = @()
foreach ($s in $slugs) { if (-not (Test-Path (Join-Path $mp ("db\recipes\{0}.json" -f $s)))) { $missing += $s } }
if ($missing.Count) { Fail ("no v2 spec in db\recipes for: " + ($missing -join ', ')) }
Write-Output ("  P4  v2 specs               {0}/{0} present in db\recipes" -f $slugs.Count)

# ---- P5. the v2 spec audits (NOT spec-guards full mode - see the header) ---------------------------
# rc=0 is the VERDICT; the completion marker is COMPLETION, and the estate has been bitten five times by
# conflating them - a detector that dies mid-run is silent, because "no findings" and "never ran" look
# identical from outside. So a clean bill here needs both: exit 0 AND the guard's own end-of-run line.
function Invoke-Gate {
  param([string]$Label, [string]$Script, [string[]]$GateArgs = @(), [string]$Marker = '', [string]$MarkerText = '')
  $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $Script @GateArgs 2>&1
  $rc = $LASTEXITCODE
  $lines = @($out | ForEach-Object { [string]$_ })
  $reason = ''
  if ($rc -ne 0) { $reason = "exited $rc" }
  elseif ($Marker -and -not (Test-GuardComplete $lines $Marker)) { $reason = "exited 0 but never printed $($Marker.ToUpper())-COMPLETE, so it did not finish" }
  elseif ($MarkerText -and -not (@($lines | Where-Object { $_ -match [regex]::Escape($MarkerText) }).Count)) { $reason = "exited 0 but never printed '$MarkerText', so it did not finish" }
  if ($reason) {
    Write-Output ("      ! {0} {1}:" -f $Label, $reason)
    @($lines | Select-Object -Last 25) | ForEach-Object { Write-Output ("        " + $_) }
    return $false
  }
  return $true
}
$gates = @(
  @{ label = 'audit-spec-contradictions'; path = (Join-Path $here 'audit-spec-contradictions.ps1'); args = @('-Quiet'); marker = 'spec-contradictions'; text = '' },
  @{ label = 'audit-store-integrity';     path = (Join-Path $here 'audit-store-integrity.ps1');     args = @();         marker = 'store-integrity';     text = '' },
  @{ label = 'test-guards';               path = (Join-Path $here 'test-guards.ps1');               args = @();         marker = '';                    text = 'ALL GUARD PREDICATE TESTS PASS' }
)
foreach ($g in $gates) {
  if (-not (Test-Path $g.path)) { Fail ("gate script missing: " + $g.path) }
  if (-not (Invoke-Gate $g.label $g.path $g.args $g.marker $g.text)) {
    Fail ("{0} is not clean. Fix it through the owning stage - never weaken a gate to pass a wave." -f $g.label)
  }
  Write-Output ("  P5  {0,-26} clean" -f $g.label)
}

# ---- P6. THE DEDUP ESCAPE GUARD -------------------------------------------------------------------
# The last net under the selector. A slug that is already live and was NOT published by this estate's
# recipe publisher is somebody else's post: publishing over it would clobber a hand-made page, and the
# hand-freed free-dinner posts are exactly the ones that must never be silently re-paywalled.
if ($runSkipGhost) {
  Write-Output '  P6  dedup escape guard     SKIPPED (-SkipGhostCheck)'
} else {
  . (Join-Path $repo 'lib\ghost-lib.ps1')
  $apiUrl = 'https://map-to-success.ghost.io'
  $adminKey = Get-GhostKey -Root $repo
  $hashFile = Join-Path $mp 'db\published-hashes.json'
  $known = @{}
  if (Test-Path $hashFile) { try { $o = Read-Json $hashFile; foreach ($p in $o.PSObject.Properties) { $known[$p.Name] = $true } } catch {} }
  $collisions = @()
  foreach ($s in $slugs) {
    $jwt = Get-GhostJWT -Key $adminKey
    $exists = $false
    try {
      $r = Invoke-GhostApi -Uri "$apiUrl/ghost/api/admin/posts/slug/$s/?fields=id,slug,visibility" -Headers @{ Authorization = "Ghost $jwt"; 'Accept-Version' = 'v5.0' }
      $exists = [bool]$r.posts[0]
    } catch {
      $code = 0; try { $code = [int]$_.Exception.Response.StatusCode } catch {}
      # a 404 is the answer we want; anything else means we could not look, and could-not-look is never
      # a clean bill on a guard whose whole job is to catch a collision
      if ($code -ne 404) { Fail ("could not check slug '{0}' on Ghost (HTTP {1}). Not publishing on an unchecked collision guard." -f $s, $code) }
    }
    if ($exists -and -not $known.ContainsKey($s)) { $collisions += $s }
  }
  if ($collisions.Count) {
    Fail ("these slugs already exist live and were NOT published by this pipeline: " + ($collisions -join ', ') +
          ". That is a dedup escape or a hand-made post. Re-slug the recipe or resolve it by hand; do not upsert over it.")
  }
  Write-Output ("  P6  dedup escape guard     clean   ({0} slug(s) checked against live)" -f $slugs.Count)
}

# ---- P7. recipes-db delta preview ------------------------------------------------------------------
$slugListPath = Join-Path $RunDir ("waves\wave-{0}.slugs.txt" -f $Wave)
[IO.File]::WriteAllText($slugListPath, ((@($slugs) -join "`r`n") + "`r`n"), $UTF8)
$specsDir = Join-Path $mp 'db\recipes'
$dry = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'update-recipes-db.ps1') `
        -RunDir $RunDir -SpecsDir $specsDir -SpecList $slugListPath -RunLabel $batch -DryRun 2>&1
if ($LASTEXITCODE -ne 0) {
  @($dry | Select-Object -Last 20) | ForEach-Object { Write-Output ("        " + [string]$_) }
  Fail 'update-recipes-db -DryRun failed'
}
Write-Output '  P7  recipes-db delta (dry run):'
@($dry | Select-Object -Last 8) | ForEach-Object { Write-Output ("        " + [string]$_) }

Write-Output ''
if ($runDryRun) {
  Write-Output '== DRY RUN - every gate above passed. These steps were NOT run: ============'
  Write-Output ("  E1  migrate-prose-tokens.ps1 -Slugs <{0} slugs> -Apply" -f $slugs.Count)
  Write-Output "  E2  compute-v2-perserving.ps1 + reanchor-machine-fields.ps1 (everyday cost basis)"
  Write-Output ("  E3  update-recipes-db.ps1 -SpecList {0}" -f (Split-Path $slugListPath -Leaf))
  Write-Output '  E4  propagate-recipes.ps1  (recipes-db sync -> db-agreement gate -> planner -> cards -> publish)'
  Write-Output '  E5  git add <scoped> && git commit && git push'
  Write-Output ''
  Write-Output '  Would publish:'
  foreach ($s in $slugs) { Write-Output ("    https://www.thriftycrew.com/{0}/" -f $s) }
  Write-GuardComplete -Name 'wave-publish' -Summary ("dry-run wave {0} n={1} all gates green" -f $Wave, $slugs.Count)
  exit 0
}

# ===================================================================================================
# EXECUTE. Each step is stamped AFTER it completes - a stamp written before the work it certifies turns
# a failure into a silently skipped stage.
# ===================================================================================================
Write-Output '== PUBLISH ================================================================'
$bl = Join-Path $here 'batch-ledger.ps1'
function Stamp { param([string]$Stage, [string]$Detail)
  & powershell -NoProfile -ExecutionPolicy Bypass -File $bl -Stamp -Batch $batch -Stage $Stage -Detail $Detail | Out-Null
}

# ---- E1. prose tokens. Idempotent, and it only swaps a literal that PROVABLY equals the spec's own
# stat, so running it here guarantees the templating rule holds for everything this wave publishes.
# IN-PROCESS: -Slugs is [string[]], and `powershell -File` marshals it as command-line strings. On the
# first live run that made PowerShell try to load a slug as a MODULE and the publish died at E1. Fourth
# instance of this trap in one session (ledger, reanchor, a probe, and here). Anything taking a
# [string[]] parameter gets `&`, never `-File`.
$mig = @()
try {
  Push-Location $mp
  try { $mig = @(& '.\pipeline\migrate-prose-tokens.ps1' -Slugs $slugs -Apply) } finally { Pop-Location }
} catch {
  Write-Output ("    " + $_.Exception.Message)
  Fail 'migrate-prose-tokens failed'
}
Write-Output ("  E1  prose tokens           " + [string](@($mig | Where-Object { "$_".Trim() -ne '' } | Select-Object -Last 1)))

# ---- E2. THE COST BASIS. A NEW recipe is not in pipeline\v2-perserving.json yet, so build-v2-spec
# stamps stat.cost_ps from batch/14 and WARNS. Every one of the 542 live specs instead carries the
# EVERYDAY basis (cost_first_run/14), which is roughly double. Shipping the fallback would advertise a
# recipe at about half its real price AND, because the free-dinner rotation and the hub Top 5 rank a
# pooled set, let the wrongly-based recipe falsely dominate the cheapest lists - the mixed-basis trap
# the 2026-07-26 cost redesign exists to prevent. Measured on the 2026-08-15 shakedown: Country Captain
# would have published $1.87 instead of $3.73, Florentine $1.66 instead of $3.26.
# propagate does NOT do this: it is built for spec EDITS, where cost has not moved.
Write-Output '  E2  cost basis (new recipes are not in the manifest yet)'
$cv = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'compute-v2-perserving.ps1') 2>&1
if ($LASTEXITCODE -ne 0) { @($cv | Select-Object -Last 10) | ForEach-Object { Write-Output ("    " + [string]$_) }; Fail 'compute-v2-perserving failed' }
# IN-PROCESS, never `powershell -File`: that path marshals a [string[]] as one command-line string, so a
# multi-slug array binds as ONE slug and the script reports a cheerful "re-anchored 1 spec". That is
# exactly what happened on the first shakedown attempt with a 2-slug wave.
Push-Location $mp
try { & '.\pipeline\reanchor-machine-fields.ps1' -Slugs $slugs | Select-Object -Last 1 | ForEach-Object { Write-Output ("      " + [string]$_) } }
finally { Pop-Location }

# VERIFY the basis actually landed, per slug. A silent fallback is the whole failure mode here.
$manPath = Join-Path $here 'v2-perserving.json'
$manRows = @{}
foreach ($e in @(Read-Json $manPath)) { $manRows[[string]$e.slug] = $e }
$specRows = @()
foreach ($s in $slugs) {
  $sp = Read-Json (Join-Path $mp ("db\recipes\{0}.json" -f $s))
  $specRows += [pscustomobject]@{ slug = $s; cost_ps = [double]$sp.stat.cost_ps }
}
$badBasis = @(Get-CostBasisProblems $specRows $manRows)   # ONE implementation, the one the self-test pins
if ($badBasis.Count) { $badBasis | ForEach-Object { Write-Output ("      ! " + $_) }; Fail 'cost basis did not land on every slug - refusing to publish a half-price recipe' }
Write-Output ("      cost basis verified on {0}/{0} slug(s) against the everyday manifest" -f $slugs.Count)
Stamp 'cost-basis' ("compute-v2-perserving + reanchor on {0} slug(s)" -f $slugs.Count)

# ---- E3. recipes-db rows
$upd = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'update-recipes-db.ps1') `
        -RunDir $RunDir -SpecsDir $specsDir -SpecList $slugListPath -RunLabel $batch 2>&1
if ($LASTEXITCODE -ne 0) { @($upd | Select-Object -Last 20) | ForEach-Object { Write-Output ("    " + [string]$_) }; Fail 'update-recipes-db failed' }
Write-Output ("  E3  recipes-db             " + [string](@($upd | Select-Object -Last 1)))
Stamp 'recipes-db' ("{0} row(s) via {1}" -f $slugs.Count, $batch)

# ---- E4. what is dirty, and is any of it not ours?
$pd = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'propagate-recipes.ps1') -DryRun 2>&1
$pdLines = @($pd | ForEach-Object { [string]$_ })
# propagate's -DryRun LISTS only its first 30 slugs but reports the true total on its header line. Read the
# TOTAL from there, never from the listing: counting the visible lines reported "30 dirty" on the first
# live run when the real number was 517, which is the silent-cap shape the estate forbids - a truncated
# listing read as a complete one. The header is authoritative; the listing is a sample.
$dirtyTotal = 0
foreach ($l in $pdLines) { if ($l -match 'propagate:\s+(\d+)\s+dirty spec') { $dirtyTotal = [int]$Matches[1]; break } }
$dirtySample = @($pdLines | Where-Object { $_ -match '^\s{2}\S' } | ForEach-Object { $_.Trim() })
$foreignSample = @(Get-ForeignDirty $dirtySample $slugs)
$foreignTotal = [Math]::Max(0, $dirtyTotal - @($slugs).Count)
if ($foreignTotal -gt 0) {
  Write-Output ("  E4  NOTE propagate reports {0} dirty spec(s) in total, so about {1} OUTSIDE this wave will be" -f $dirtyTotal, $foreignTotal)
  Write-Output ("        carried and republished with it. That is propagate's design (it is the one command after")
  Write-Output ("        any spec edit), but this wave's ledger should not be read as having shipped only {0}." -f @($slugs).Count)
  @($foreignSample | Select-Object -First 10) | ForEach-Object { Write-Output ("        " + $_) }
  if ($foreignSample.Count -lt $foreignTotal) { Write-Output ("        ... listing truncated by propagate at 30; {0} more not shown" -f ($foreignTotal - $foreignSample.Count)) }
}

# ---- E4. THE CHAIN. sync-recipesdb-buy -> audit-db-agreement (hard gate) -> planner -> build-cards
# -> engine\publish (hash-gated, visibility-preserving, live-verified). Stamps advance only on success.
$prop = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'propagate-recipes.ps1') 2>&1
$propRc = $LASTEXITCODE
@($prop | ForEach-Object { Write-Output ("    " + [string]$_) })
if ($propRc -ne 0) { Fail 'propagate-recipes failed - nothing was stamped, the next run retries the same slugs' }
if (-not (@($prop | Where-Object { $_ -match 'propagate COMPLETE' }).Count)) {
  Fail 'propagate did not report COMPLETE - treating an unfinished chain as unfinished'
}
Stamp 'build-cards' ("{0} card(s) rebuilt via propagate" -f $slugs.Count)
Stamp 'publish' ("{0}/{0} published through engine\publish (visibility preserved)" -f $slugs.Count)
Write-Output ("  E5  propagate               COMPLETE")

# ---- E5. push. The push IS the deploy here. NEVER `git add -A`: it sweeps whatever else is in Brad's
# real tree into this commit.
if ($runSkipGit) { Write-Output '  E6  git                    SKIPPED (-SkipGit)' }
else {
  $paths = @(
    ('meal-prep/runs/' + (Split-Path $RunDir -Leaf)),
    'meal-prep/recipes-db.json', 'meal-prep/db/costed.json', 'meal-prep/db/published-hashes.json',
    'meal-prep/db/batch-ledger.json', 'meal-prep/pipeline/propagate-stamps.json',
    'meal-prep/pipeline/v2-perserving.json', 'meal-prep/planner-data.js'
  )
  # db\built is DERIVED and gitignored on purpose - build-cards regenerates it from the spec, so staging
  # it would only ever produce "paths are ignored by .gitignore" noise on every publish. The spec is the
  # artifact worth committing; the card is a build product of it.
  foreach ($s in $slugs) { $paths += ('meal-prep/db/recipes/' + $s + '.json') }
  $add = @($paths | Where-Object { Test-Path (Join-Path $repo ($_ -replace '/', '\')) })
  # NEVER `2>&1` ON git HERE. In PS 5.1 redirecting a native command's stderr wraps every line in a
  # NativeCommandError, and with $ErrorActionPreference='Stop' that THROWS - even when git exited 0. On
  # the first live run git's routine "LF will be replaced by CRLF" WARNING killed this script at the last
  # step, after all 359 recipes had already published and verified. A benign message on stderr must never
  # be able to fail a publish that succeeded. Exit codes carry the verdict; stderr just prints.
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    & git -C $repo add -- @add | Out-Null
    $staged = @(& git -C $repo diff --cached --name-only | Where-Object { "$_".Trim() -ne '' })
    if (-not $staged.Count) {
      Write-Output '  E6  git                    nothing staged (already committed on a previous run)'
    } else {
      $msg = ("recipes: publish {0} ({1} recipes in the wave, audit GO)" -f $batch, $slugs.Count)
      & git -C $repo commit -m $msg | Out-Null
      if ($LASTEXITCODE -ne 0) { Fail ("git commit failed AFTER a successful publish - the recipes ARE live, only the repo is behind") }
      & git -C $repo push | Out-Null
      if ($LASTEXITCODE -ne 0) { Fail ("git push failed AFTER a successful publish - the recipes ARE live, but the repo is unpushed and the push is the deploy for everything else") }
      Write-Output ("  E6  git                    committed and pushed ({0} path(s))" -f $staged.Count)
    }
  } finally { $ErrorActionPreference = $prevEap }
}

# ---- advance the recipes to `published`
foreach ($s in $slugs) {
  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'hunt-run.ps1') -Advance -RunDir $RunDir -Slug $s -To published -By 'wave-publish' -Detail ("wave {0}" -f $Wave) | Out-Null
}

Write-Output ''
Write-Output '== LIVE ==================================================================='
foreach ($s in $slugs) { Write-Output ("  https://www.thriftycrew.com/{0}/" -f $s) }
Write-Output ''
Write-Output ("  NEXT (not optional): dispatch post-publish-reviewer scoped to these {0} slug(s), then" -f $slugs.Count)
Write-Output ("    batch-ledger.ps1 -Stamp -Batch {0} -Stage post-publish-review -Detail '<verdict>'" -f $batch)
Write-Output ("    batch-ledger.ps1 -Close -Batch {0} -Detail '<verdict>'" -f $batch)
Write-GuardComplete -Name 'wave-publish' -Summary ("wave {0} published n={1}" -f $Wave, $slugs.Count)
exit 0
