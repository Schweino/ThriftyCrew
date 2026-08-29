# audit-unbid-ingredients.ps1
# ---------------------------------------------------------------------------------------------------
# Sweeps db\recipes for scaler ingredients carrying NO bid. Such a line cannot be priced by the
# BROWSER, so the card's interactive scaler goes dark - see WHAT IT ACTUALLY BREAKS below.
#
# FOUNDING BUG (2026-08-16). build-v2-spec.ps1 threw on the LESSER defect (a bid that resolves to
# nothing on the live feed - CHEAPEST-FALLBACK) but merely printed a report line for the WORSE one (no
# bid at all), after the spec had already been written. 23 specs carried the defect and four were LIVE:
# turkey-meatball-sub-bake (Keto Bun, 1320 g), dak-galbi-chicken-cabbage-skillet (Korean Rice Cakes,
# 1300 g), baked-turkey-kibbeh-casserole (Bulgur Wheat, 957 g) and musakhan-sumac-chicken (Sumac,
# 62 g). The build now refuses; this sweep is the standing guard so the class cannot re-enter by a
# hand-edit, a migration, or a future bug.
#
# THIS FILE USED TO SAY THE PRICE WAS $0.00, AND THAT WAS FALSE (corrected 2026-08-29). The claim was
# "cost-recipes prices an unbid line at $0.00 WITHOUT failing, so the recipe ships a cost that silently
# excludes that ingredient". It does not. cost-recipes.ps1 lifts canon+grams from the spec (line 37)
# and resolves the bid from db\ingredients.json (line 187) - it never reads the spec's bid at all.
# NEUTER-PROVED: stripping a WORKING bid ("fresh-mint" + gpu) out of the kibbeh spec and recosting
# produced a byte-identical costed record (ps=2.81, batch=39.32, lines_priced=9, mint still $3.77).
# All four founding recipes were priced correctly the whole time, three of them off label captures.
# The wrong diagnosis outlived the bug by 13 days and sent a later session hunting an understated
# price that never existed, so the correction is written here rather than quietly applied.
#
# WHAT IT ACTUALLY BREAKS is the card's INTERACTIVE scaler, which is fail-closed by design.
# tpl2-scaler-prefix.html line 317 returns null for the whole batch total if ANY line prices to null,
# and price() returns null when `it.bid` is falsy. So the reader sees the ingredient row read "Price
# unavailable in this release", the grand total read "Unavailable - one or more release prices are
# missing" (line 385), the composition chart hidden (line 333), and the shopping-list total read
# "Unavailable". The static prose number beside it stays correct. A dark feature on a paid page, not
# an understated price - real, but the opposite severity, and it must be reported as what it is.
#
#   .\audit-unbid-ingredients.ps1                     sweep every spec in db\recipes
#   .\audit-unbid-ingredients.ps1 -Slugs a,b,c        sweep only these (wave-publish preflight)
#   .\audit-unbid-ingredients.ps1 -Json               machine-readable
#   .\audit-unbid-ingredients.ps1 -SelfTest
# Exit 0 clean, 1 findings, 2 self-test failure.
# ---------------------------------------------------------------------------------------------------
param(
  [string[]]$Slugs = @(),
  [string]$RecipesDir,
  [string]$NotTrackedOkFile,
  [switch]$Json,
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$runSelfTest = [bool]$SelfTest; $runJson = [bool]$Json

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp   = Split-Path -Parent $here
$repo = Split-Path -Parent $mp
. (Join-Path $repo 'lib\guard-contract.ps1')

if(-not $RecipesDir){ $RecipesDir = Join-Path $mp 'db\recipes' }
if(-not $NotTrackedOkFile){ $NotTrackedOkFile = Join-Path $mp 'db\not-price-tracked-ok.json' }

# ---------------------------------------------------------------------------------------------------
# THE PREDICATE, kept pure so the fixtures below test the same code the sweep runs. Returns the canon
# names of ingredients that carry no bid AND are not allowlisted.
# ---------------------------------------------------------------------------------------------------
function Get-UnbidItems {
  param($ScalerIng, $AllowMap)
  $out = @()
  foreach($e in @($ScalerIng)){
    $hasBid = $false
    if($e -and ($e.PSObject.Properties.Name -contains 'bid')){
      $b = [string]$e.bid
      if($b -and $b.Trim() -ne ''){ $hasBid = $true }
    }
    if($hasBid){ continue }
    $canon = if($e -and ($e.PSObject.Properties.Name -contains 'canon') -and $e.canon){ [string]$e.canon } else { [string]$e.item }
    if($AllowMap -and $AllowMap.ContainsKey($canon)){ continue }
    $out += $canon
  }
  return @($out | Select-Object -Unique)
}

# ---- self-test -------------------------------------------------------------------------------------
if($runSelfTest){
  $bad = 0
  function T([string]$name, [bool]$ok, [string]$got){
    if($ok){ Write-Output ("  ok    " + $name) } else { Write-Output ("  X     " + $name + "   got: " + $got); $script:bad++ }
  }
  $allow = @{ 'Water' = 1 }

  # MUST FIRE: an ingredient with no bid property at all
  $f1 = @([pscustomobject]@{ item='Portobello Mushrooms'; canon='Portobello Mushrooms'; grams=1588 })
  T 'MUST FIRE  an ingredient with no bid property is a finding' ((Get-UnbidItems $f1 $allow).Count -eq 1) ([string](Get-UnbidItems $f1 $allow).Count)

  # MUST FIRE: bid present but empty string - the shape a half-written map row leaves
  $f2 = @([pscustomobject]@{ item='Sumac'; canon='Sumac'; grams=62; bid='' })
  T 'MUST FIRE  an EMPTY bid string counts as unbid, not as bid' ((Get-UnbidItems $f2 $allow).Count -eq 1) ([string](Get-UnbidItems $f2 $allow).Count)

  # MUST FIRE: whitespace-only bid
  $f2b = @([pscustomobject]@{ item='Keto Bun'; canon='Keto Bun'; grams=1320; bid='   ' })
  T 'MUST FIRE  a whitespace-only bid counts as unbid' ((Get-UnbidItems $f2b $allow).Count -eq 1) ([string](Get-UnbidItems $f2b $allow).Count)

  # CLEAN TWIN: every ingredient bid
  $f3 = @([pscustomobject]@{ item='Chicken Breast'; canon='Chicken Breast'; grams=3175; bid='chicken-breast' },
          [pscustomobject]@{ item='Salt'; canon='Salt'; grams=21; bid='salt' })
  T 'CLEAN TWIN a fully bid spec is silent' ((Get-UnbidItems $f3 $allow).Count -eq 0) ([string](Get-UnbidItems $f3 $allow).Count)

  # CLEAN TWIN: unbid but allowlisted
  $f4 = @([pscustomobject]@{ item='Water'; canon='Water'; grams=500 })
  T 'CLEAN TWIN an allowlisted unbid item is pardoned' ((Get-UnbidItems $f4 $allow).Count -eq 0) ([string](Get-UnbidItems $f4 $allow).Count)

  # MUST FIRE: the allowlist pardons only its own item, not the whole spec
  $f5 = @([pscustomobject]@{ item='Water'; canon='Water'; grams=500 },
          [pscustomobject]@{ item='Bulgur Wheat'; canon='Bulgur Wheat'; grams=957 })
  # @() at the call site is load-bearing: a single returned element unrolls to a bare string, and
  # $r5[0] on a string is its first CHARACTER. Same collapse hunt-run.ps1 freezes a fixture for.
  $r5 = @(Get-UnbidItems $f5 $allow)
  T 'MUST FIRE  an allowlisted item does not pardon its neighbours' ($r5.Count -eq 1 -and $r5[0] -eq 'Bulgur Wheat') ($r5 -join ',')

  # MUST FIRE: several unbid items are counted individually, not joined into one blob
  #   (the -Terms comma bug of 2026-08-16 was exactly this class - a list collapsing to one string)
  $f6 = @([pscustomobject]@{ item='Portobello Mushrooms'; canon='Portobello Mushrooms'; grams=1588 },
          [pscustomobject]@{ item='Sour Cream'; canon='Sour Cream'; grams=270 },
          [pscustomobject]@{ item='Egg Yolk'; canon='Egg Yolk'; grams=68 })
  T 'MUST FIRE  three unbid items count as THREE, not as one joined blob' ((Get-UnbidItems $f6 $allow).Count -eq 3) ([string](Get-UnbidItems $f6 $allow).Count)

  # CLEAN TWIN: canon preferred over item for the allowlist key (display name may differ)
  $f7 = @([pscustomobject]@{ item='Filtered Water'; canon='Water'; grams=500 })
  T 'CLEAN TWIN allowlist matches on canon, not the display name' ((Get-UnbidItems $f7 $allow).Count -eq 0) ([string](Get-UnbidItems $f7 $allow).Count)

  # MUST FIRE: the live founding cases, as a frozen regression
  $f8 = @([pscustomobject]@{ item='Keto Bun'; canon='Keto Bun'; grams=1320 })
  T 'MUST FIRE  the turkey-meatball-sub-bake founding case (Keto Bun 1320 g)' ((Get-UnbidItems $f8 $allow).Count -eq 1) ([string](Get-UnbidItems $f8 $allow).Count)

  # MUST FIRE: the -Slugs comma-marshalling trap (B8's shape, in this script's own interface).
  # `powershell -File ... -Slugs a,b` arrives as ONE element; if the receiver does not split, it sweeps
  # zero specs and prints "ok", which is a silent false pass on a gate.
  $joined = @('a,b') | Where-Object { $_ } | ForEach-Object { ([string]$_).Split(',') } | ForEach-Object { $_.Trim() } | Where-Object { $_ }
  T 'MUST FIRE  a comma-joined -Slugs string splits into TWO slugs, not one' (@($joined).Count -eq 2) ([string]@($joined).Count)
  $spaced = @('a, b') | Where-Object { $_ } | ForEach-Object { ([string]$_).Split(',') } | ForEach-Object { $_.Trim() } | Where-Object { $_ }
  T 'CLEAN TWIN whitespace after the comma is trimmed, not kept in the slug' ((@($spaced)[1]) -eq 'b') ([string](@($spaced)[1]))

  # the build-time guard must be wired, or this sweep is the only thing standing
  $bvs = Get-Content (Join-Path $here 'build-v2-spec.ps1') -Raw -Encoding utf8
  T 'MUST FIRE  build-v2-spec.ps1 THROWS on an unbid ingredient' ($bvs -match 'UNBID INGREDIENT') 'guard text not found'
  T 'MUST FIRE  build-v2-spec.ps1 reads the not-price-tracked allowlist' ($bvs -match 'notTrackedOk') 'allowlist not read'

  # THE DIAGNOSIS IS PINNED (2026-08-29). This guard spent 13 days telling readers an unbid line was
  # "priced at $0.00" and quoting stat.cost_ps as the recipe's claim. Both were false, and the wrong
  # story cost a later session most of a run chasing a price bug that did not exist. A guard's words
  # are part of its contract: these cases fail if the false diagnosis is ever restored.
  $self = Get-Content $PSCommandPath -Raw -Encoding utf8
  $reportBody = ($self -split '# ---- sweep ')[-1]
  T 'MUST NOT FIRE  the report never claims an unbid line is priced at $0.00' `
    ($reportBody -notmatch 'priced at .?\$0\.00') 'the $0.00 claim is back in the report'
  T 'MUST FIRE  the finding quotes cost_per_serving, not stat.cost_ps' `
    ($reportBody -match '\$j\.cost_per_serving' -and $reportBody -notmatch '\$j\.stat\.cost_ps') 'wrong field quoted as the page price'
  T 'MUST FIRE  the report names the real symptom (the live scaler reads Unavailable)' `
    ($reportBody -match "live scaler reads 'Unavailable'") 'symptom not named'
  T 'MUST FIRE  the report points at the repair that heals a known-bid block' `
    ($reportBody -match 'repair-missing-scaler-bid\.ps1') 'no fix path offered'
  # And the repair it names must actually exist - a guard citing a script nobody wrote is worse than
  # a guard citing none, because the reader stops looking.
  T 'MUST FIRE  the repair this guard names exists on disk' `
    (Test-Path (Join-Path $here 'repair-missing-scaler-bid.ps1')) 'repair-missing-scaler-bid.ps1 not found'

  if($bad -gt 0){ Write-Output ("audit-unbid-ingredients SELF-TEST FAIL ({0})" -f $bad); exit 2 }
  Write-Output 'audit-unbid-ingredients SELF-TEST PASS'
  Write-GuardComplete -Name 'audit-unbid-ingredients' -Summary 'selftest pass'
  exit 0
}

# ---- sweep -----------------------------------------------------------------------------------------
$allowMap = @{}
if(Test-Path $NotTrackedOkFile){
  foreach($i in ((Get-Content $NotTrackedOkFile -Raw -Encoding utf8 | ConvertFrom-Json).items)){ $allowMap[[string]$i] = 1 }
}

# SPLIT ON COMMA. `powershell -File script.ps1 -Slugs a,b` hands this script ONE element, the literal
# string "a,b" - the same [string[]] marshalling that made hunt-run's -Terms store a composite term and
# park two recipes forever on 2026-08-16. wave-publish invokes gates across exactly that boundary, so a
# joined string is the only shape that survives it and the receiver must cope. Splitting is safe HERE
# (a slug can never contain a comma) whereas -Terms correctly refuses instead, because there the joined
# string signalled a caller bug worth surfacing rather than papering over.
$slugList = @($Slugs | Where-Object { $_ } | ForEach-Object { ([string]$_).Split(',') } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

$missingSpecs = @()
$files = if(@($slugList).Count -gt 0){
  $acc = @()
  foreach($s in $slugList){
    $p = Join-Path $RecipesDir ($s + '.json')
    if(Test-Path $p){ $acc += $p } else { $missingSpecs += $s }
  }
  @($acc)
} else {
  @(Get-ChildItem $RecipesDir -Filter *.json -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
}
# A named slug with no spec is a finding, not a silent skip: "swept 0 of 2" must never read as clean.
if(@($missingSpecs).Count -gt 0){
  Write-Output ("audit-unbid-ingredients: {0} named slug(s) have NO spec in {1}: {2}" -f @($missingSpecs).Count, $RecipesDir, (@($missingSpecs) -join ', '))
  Write-GuardComplete -Name 'audit-unbid-ingredients' -Summary ("missing-specs={0}" -f @($missingSpecs).Count)
  exit 1
}

$findings = @()
foreach($f in $files){
  $slug = [IO.Path]::GetFileNameWithoutExtension($f)
  try { $j = Get-Content $f -Raw -Encoding utf8 | ConvertFrom-Json } catch { continue }
  $ing = @()
  if($j.PSObject.Properties.Name -contains 'scaler' -and $j.scaler -and ($j.scaler.PSObject.Properties.Name -contains 'ing')){ $ing = @($j.scaler.ing) }
  if(@($ing).Count -eq 0){ continue }
  $unbid = Get-UnbidItems $ing $allowMap
  if(@($unbid).Count -gt 0){
    # cost_per_serving is the everyday per-serving number the card and recipes-db both render. It is
    # reported here as CONTEXT (which page is affected), never as an accusation: it is not wrong.
    #
    # THIS USED TO READ stat.cost_ps AND PRINT IT AS "claims $X" (fixed 2026-08-29). stat.cost_ps is a
    # different quantity and diverges from cost_per_serving on ALL 587 specs - it printed "claims $4.51"
    # for a recipe whose page says $2.60, which is not a discrepancy this guard found but one it
    # manufactured. A guard that quotes the wrong field to dramatise a finding teaches the next reader
    # to distrust the finding.
    $cps = $null
    if($j.PSObject.Properties.Name -contains 'cost_per_serving' -and $null -ne $j.cost_per_serving){ $cps = [string]$j.cost_per_serving }
    $findings += [pscustomobject]@{ slug=$slug; unbid=@($unbid); count=@($unbid).Count; claimed_cps=$cps; total_ingredients=@($ing).Count }
  }
}

if($runJson){
  ([pscustomobject]@{ swept=@($files).Count; findings=@($findings) } | ConvertTo-Json -Depth 6)
  if(@($findings).Count -gt 0){ exit 1 }
  exit 0
}

Write-Output ("audit-unbid-ingredients: swept {0} spec(s)" -f @($files).Count)
if(@($findings).Count -eq 0){
  Write-Output '  ok - every scaler ingredient carries a bid (or is allowlisted as not price-tracked)'
  Write-GuardComplete -Name 'audit-unbid-ingredients' -Summary ("clean n={0}" -f @($files).Count)
  exit 0
}
Write-Output ("  {0} spec(s) carry an ingredient the browser cannot price (the card's live scaler reads 'Unavailable'):" -f @($findings).Count)
foreach($f in ($findings | Sort-Object count -Descending)){
  Write-Output ("    {0,-46} page {1,-7} unbid {2}: {3}" -f $f.slug, $(if($f.claimed_cps){'$'+$f.claimed_cps}else{'(uncosted)'}), $f.count, (@($f.unbid) -join ', '))
}
Write-Output '  The per-serving number beside it is NOT wrong: cost-recipes resolves the bid from db\ingredients.json, not from the spec.'
Write-Output '  Fix: pipeline\repair-missing-scaler-bid.ps1 -Apply heals any block whose vocabulary row already knows the bid, then recost,'
Write-Output '       reanchor and rebuild the card. A vocabulary row that is deliberately bid-less needs a product-class ruling, not a repair.'
Write-GuardComplete -Name 'audit-unbid-ingredients' -Summary ("findings={0}" -f @($findings).Count)
exit 1
