# audit-cost-plausibility.ps1
# ---------------------------------------------------------------------------------------------------
# Refuses a recipe whose published cost is arithmetically incomplete or physically implausible.
#
# FOUNDING BUG (2026-08-16, the SECOND silent-zero path found that day). build-v2-spec.ps1 learned to
# resolve adjudicated ingredient aliases; engine\cost-recipes.ps1 did not. So a spec BUILT fine - the
# alias resolved and the bid was written into the scaler - while the cost engine looked up the raw
# canon name, found no row, and dropped the line as NO PRICE BASIS. The result was
# sheet-pan-smoked-sausage-broccoli-cheddar published at $2.12 for the batch and $0.15 a serving, for a
# recipe containing 3 lb of andouille sausage and 5.25 lb of broccoli. Every guard in place at the time
# passed it: the bid EXISTED (unbid sweep clean), the name RESOLVED (vocab-integrity clean), and the
# bid was ON THE FEED (CHEAPEST-FALLBACK clean). Only the number itself was absurd, and nothing was
# looking at the number.
#
# TWO CHECKS, deliberately different in kind:
#   UNPRICED-LINE  exact, not heuristic: cost-recipes itself reports lines_unpriced per recipe. Any
#                  value above zero means the published cost EXCLUDES an ingredient the reader must buy.
#                  This is the precise statement of the defect and it needs no threshold.
#   IMPLAUSIBLE    a backstop for the case where every line prices but the total is still impossible -
#                  a floor no real dinner can sit under. Catches a future failure mode we have not met
#                  yet, which is the whole point of a backstop.
#
#   .\audit-cost-plausibility.ps1                  sweep every costed recipe
#   .\audit-cost-plausibility.ps1 -Slugs a,b,c     scoped (wave-publish preflight)
#   .\audit-cost-plausibility.ps1 -SelfTest
# Exit 0 clean, 1 findings, 2 self-test failure.
# ---------------------------------------------------------------------------------------------------
param(
  [string[]]$Slugs = @(), [string]$CostedFile, [double]$FloorCps = 0.25, [switch]$Json, [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$runJson=[bool]$Json; $runSelfTest=[bool]$SelfTest

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp   = Split-Path -Parent $here
$repo = Split-Path -Parent $mp
. (Join-Path $repo 'lib\guard-contract.ps1')
if (-not $CostedFile) { $CostedFile = Join-Path $mp 'db\costed.json' }

$script:MIN_ROWS = 400   # plausibility floor on the FILE itself - see ingredient-vocab.ps1's 8-row misread

function Test-CostRow {
  param($Row, [double]$Floor)
  $findings = @()
  $unpriced = 0
  if ($Row.PSObject.Properties.Name -contains 'lines_unpriced' -and $null -ne $Row.lines_unpriced) { $unpriced = [int]$Row.lines_unpriced }
  if ($unpriced -gt 0) {
    $findings += [pscustomobject]@{ class='UNPRICED-LINE'; detail=("{0} ingredient line(s) carry no price, so the published cost EXCLUDES them" -f $unpriced) }
  }
  $cps = $null
  if ($Row.PSObject.Properties.Name -contains 'cost_per_serving' -and $null -ne $Row.cost_per_serving) { $cps = [double]$Row.cost_per_serving }
  # An uncosted recipe (no cps at all) is not this guard's business - build-v2-spec's -AllowUncosted
  # path exists for staging, and flagging it here would fire on every work-in-progress spec.
  if ($null -ne $cps -and $cps -gt 0 -and $cps -lt $Floor) {
    $findings += [pscustomobject]@{ class='IMPLAUSIBLE'; detail=("`$${0} per serving is below the `$${1} floor - no real dinner costs this little" -f $cps, $Floor) }
  }
  return @($findings)
}

if ($runSelfTest) {
  $bad = 0
  function T([string]$n,[bool]$ok,[string]$got){ if($ok){Write-Output ("  ok    "+$n)}else{Write-Output ("  X     "+$n+"   got: "+$got); $script:bad++} }

  # the founding case, frozen
  $founding = [pscustomobject]@{ slug='sheet-pan-smoked-sausage-broccoli-cheddar'; cost_per_serving=0.15; lines_unpriced=2 }
  $f = @(Test-CostRow $founding 0.25)
  T 'MUST FIRE  the founding case fires (0.15/serving with 2 unpriced lines)' (@($f).Count -eq 2) ([string]@($f).Count)
  T '   ...and names BOTH the unpriced lines and the implausible total' ((@($f | ForEach-Object { $_.class }) -join ',') -eq 'UNPRICED-LINE,IMPLAUSIBLE') (@($f | ForEach-Object { $_.class }) -join ',')

  T 'MUST FIRE  ONE unpriced line is enough, whatever the total looks like' (
      (@(Test-CostRow ([pscustomobject]@{ slug='x'; cost_per_serving=4.50; lines_unpriced=1 }) 0.25)).Count -eq 1
    ) 'missed'
  T 'MUST FIRE  an implausible total fires even when every line priced' (
      (@(Test-CostRow ([pscustomobject]@{ slug='x'; cost_per_serving=0.10; lines_unpriced=0 }) 0.25)).Count -eq 1
    ) 'missed'
  T 'CLEAN TWIN a normal recipe is silent' (
      (@(Test-CostRow ([pscustomobject]@{ slug='x'; cost_per_serving=2.35; lines_unpriced=0 }) 0.25)).Count -eq 0
    ) 'false positive'
  T 'CLEAN TWIN a genuinely cheap but real recipe passes (rice and beans territory)' (
      (@(Test-CostRow ([pscustomobject]@{ slug='x'; cost_per_serving=0.64; lines_unpriced=0 }) 0.25)).Count -eq 0
    ) 'floor set too high - it would reject real recipes'
  T 'CLEAN TWIN an UNCOSTED row is not this guard''s business' (
      (@(Test-CostRow ([pscustomobject]@{ slug='x'; lines_unpriced=0 }) 0.25)).Count -eq 0
    ) 'fired on an uncosted row'
  T 'MUST FIRE  a row missing lines_unpriced entirely is treated as zero, not as absent evidence' (
      (@(Test-CostRow ([pscustomobject]@{ slug='x'; cost_per_serving=2.00 }) 0.25)).Count -eq 0
    ) 'crashed or fired'

  # the alias resolver must exist in the COST engine, or this class returns by the same door
  $cr = Get-Content (Join-Path $mp 'engine\cost-recipes.ps1') -Raw -Encoding utf8
  T 'MUST FIRE  cost-recipes.ps1 resolves ingredient ALIASES (the founding gap)' ($cr -match 'Resolve-ItemRow') 'alias resolver missing from the cost engine'

  if ($bad -gt 0) { Write-Output ("audit-cost-plausibility SELF-TEST FAIL ({0})" -f $bad); exit 2 }
  Write-Output 'audit-cost-plausibility SELF-TEST PASS'
  Write-GuardComplete -Name 'audit-cost-plausibility' -Summary 'selftest pass'; exit 0
}

$parsed = Get-Content $CostedFile -Raw -Encoding utf8 | ConvertFrom-Json
$rows = @($parsed)
if ($rows.Count -lt $script:MIN_ROWS) {
  Write-Output ("audit-cost-plausibility: PARSED ONLY {0} costed rows - implausible for this estate, refusing to report. Fix the parse." -f $rows.Count)
  exit 1
}

$slugList = @($Slugs | Where-Object { $_ } | ForEach-Object { ([string]$_).Split(',') } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if (@($slugList).Count) {
  $want = @{}; foreach ($s in $slugList) { $want[$s] = 1 }
  $rows = @($rows | Where-Object { $want.ContainsKey([string]$_.slug) })
  $missing = @($slugList | Where-Object { $sl = $_; -not @($rows | Where-Object { [string]$_.slug -eq $sl }).Count })
  if (@($missing).Count) { Write-Output ("audit-cost-plausibility: no costed row for: {0}" -f ($missing -join ', ')); exit 1 }
}

$findings = @()
foreach ($r in $rows) {
  foreach ($f in (Test-CostRow $r $FloorCps)) {
    $findings += [pscustomobject]@{ slug=[string]$r.slug; class=$f.class; detail=$f.detail; cps=$r.cost_per_serving }
  }
}

if ($runJson) { ([pscustomobject]@{ swept=@($rows).Count; findings=@($findings) } | ConvertTo-Json -Depth 5); if(@($findings).Count){exit 1}; exit 0 }

Write-Output ("audit-cost-plausibility: swept {0} costed recipe(s)" -f @($rows).Count)
if (-not @($findings).Count) {
  Write-Output '  ok - every recipe prices every line, and no total is implausible'
  Write-GuardComplete -Name 'audit-cost-plausibility' -Summary ("clean n={0}" -f @($rows).Count); exit 0
}
foreach ($f in ($findings | Sort-Object class, slug)) {
  Write-Output ("  {0,-14} {1,-48} {2}" -f $f.class, $f.slug, $f.detail)
}
Write-Output '  A cost that excludes an ingredient is a false claim on a card readers budget from.'
Write-GuardComplete -Name 'audit-cost-plausibility' -Summary ("findings={0}" -f @($findings).Count)
exit 1
