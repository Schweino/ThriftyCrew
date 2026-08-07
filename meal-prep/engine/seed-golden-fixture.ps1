# seed-golden-fixture.ps1 - builds the FROZEN input fixture that engine\golden-test.ps1's hermetic lane
# runs against. Run ONCE (2026-08-06). It is kept in the repo so the fixture's provenance is readable,
# not so it gets re-run.
#
# WHY A FROZEN-INPUT FIXTURE (2026-08-06). The old golden test diffed a DAILY-REGENERATED output
# (db\costed.json) against a FROZEN output (archive\*\recipes-costed.json). That comparison proves
# something only while the two share inputs, which they did for exactly one day; by 2026-08-04 it was
# emitting 10,339 diffs and had honestly disabled itself, leaving THE cost engine behind every price on
# the site with no regression test for eleven days. The fix is not a fresher output baseline - that ages
# out again on the next price move. It is to freeze the INPUTS too. With inputs frozen the expected
# output can only change when the ENGINE changes, which is the only thing a regression test was ever
# meant to detect.
#
# DO NOT RE-RUN THIS TO "REFRESH" THE FIXTURE. Regenerating fixture inputs from live data is how a
# frozen fixture stops testing anything (grocery\test-auditors.ps1 header, same lesson). If the engine
# changes on purpose, review the diff and accept it with `golden-test.ps1 -Rebaseline`, which re-runs the
# engine over THESE inputs and rewrites only the expected output. -Reseed exists for the one legitimate
# case: the engine starts reading an input this fixture does not carry at all.
param([switch]$Reseed)
$ErrorActionPreference='Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$mp   = Split-Path -Parent $here
$db   = Join-Path $mp 'db'
$gout = Join-Path (Split-Path $mp -Parent) 'grocery\out'
$fx   = Join-Path $here 'regression-inputs\golden'
$fin  = Join-Path $fx 'inputs'

if((Test-Path $fin) -and -not $Reseed){ throw "fixture already exists at $fin - it is FROZEN. Use -Rebaseline on golden-test.ps1 to accept an engine change; -Reseed here only when the engine reads a NEW input file." }

# ---------------------------------------------------------------- the slice
# Every slug is here because it is the only cheap way to reach a branch of the engine. Losing one of
# these loses coverage of that branch, so the reason travels with the slug.
$SLUGS = [ordered]@{
  'al-pastor-pork-taco-bowl-with-cilantro-lime-rice' = 'board price + buy package + drained-can basis (Seasoned Black Beans) + bulk pantry package'
  'beef-birria-burrito'                              = 'smp-feed fallback basis; allowlisted no-board bid (dried-guajillo-chiles -> register estimate)'
  'ants-climbing-a-tree-pork-noodles'                = 'label-price basis on a bulk item; buy_cost clamped up to util_cost'
  'baked-turkey-kibbeh-casserole'                    = 'label-price basis on a BUY package (the non-bulk label branch)'
  'peruvian-pollo-saltado'                           = 'second allowlisted bid (aji-amarillo-paste)'
  'sichuan-dan-dan-noodles-with-pork'                = 'label NAME FOLD (Chili Crisp) - folds are data in label-folds.json, not code'
  'beef-stuffed-shells'                              = 'second label name fold (Pasta Shells)'
  'turkey-pozole-rojo'                               = 'multi-package buy_n on Tortilla (the item whose package def changed 2026-08-06)'
  'andong-jjimdak-braised-chicken'                   = 'buy_cost floor: ceil packages priced BELOW utilization'
  'chili-cornbread-casserole'                        = 'drained-can pkg_g (Kidney Beans 425 net / 255 drained) with buy_n > 1'
  'greek-ground-turkey-lemon-rice-bowls'             = 'starter_n > 1 on a pantry package (Lemon Juice) - the pantry fold arithmetic'
  'korean-turkey-japchae'                            = 'Rice Noodles line; one of the 2026-08-05 phantom-recipe adjudications'
  'ranch-chicken-burrito'                            = 'a 2026-08-06 burrito - the batch that exposed the -Slugs append bug'
}
$synthSlug = 'zz-synthetic-flag-cases'

$null = New-Item -ItemType Directory (Join-Path $fin 'db\recipes') -Force
$null = New-Item -ItemType Directory (Join-Path $fin 'grocery-out') -Force

# ---- specs (whole, unedited copies - a real slice, not a hand-written stub) ----
$items = New-Object System.Collections.Generic.HashSet[string]
foreach($slug in $SLUGS.Keys){
  $src = Join-Path $db "recipes\$slug.json"
  if(-not (Test-Path $src)){ throw "fixture slug has no spec: $slug" }
  Copy-Item $src (Join-Path $fin "db\recipes\$slug.json") -Force
  $s = Get-Content $src -Raw | ConvertFrom-Json
  foreach($i in $s.scaler.ing){
    $k = if($i.PSObject.Properties.Name -contains 'canon' -and $i.canon){ [string]$i.canon } else { [string]$i.item }
    $null = $items.Add($k)
  }
}

# ---- synthetic spec: the five flag branches, none of which any live recipe reaches ----
# A clean catalogue means cost-flags.txt is empty, which means the engine's entire error-reporting path
# is exercised by nothing. These lines pin it. They are clearly marked ZZ so nobody mistakes them for food.
$SYNTH = @(
  @{ item='ZZ Unpriced Item';    grams=100 }   # no bid, no label      -> NO PRICE BASIS
  @{ item='ZZ Offboard Bid';     grams=100 }   # bid on no board       -> MAPPED BID NOT ON ANY BOARD + NO PRICE BASIS
  @{ item='ZZ Bulk No Pantry';   grams=100 }   # bulk, no pantry pkg   -> BULK ITEM WITHOUT PANTRY PACKAGE DEF
  @{ item='ZZ No Package Def';   grams=100 }   # priced, no buy pkg    -> counted at util in true cost
  @{ item='ZZ Unit Mismatch';    grams=100 }   # each vs lb board row  -> UNIT MISMATCH
)
foreach($z in $SYNTH){ $null = $items.Add($z.item) }
([ordered]@{
  name  = 'ZZ Synthetic Flag Cases'
  slug  = $synthSlug
  _doc  = 'NOT A RECIPE. Frozen fixture row that reaches the five cost-flag branches no live recipe reaches. See seed-golden-fixture.ps1.'
  scaler = [ordered]@{ ing = @($SYNTH | ForEach-Object { [ordered]@{ item=$_.item; grams=$_.grams } }) }
}) | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $fin "db\recipes\$synthSlug.json") -Encoding UTF8

# ---- ingredients.json trimmed to the slice ----
$allIng = Get-Content (Join-Path $db 'ingredients.json') -Raw | ConvertFrom-Json
$keep = @($allIng | Where-Object { $items.Contains([string]$_.item) })
$bids = New-Object System.Collections.Generic.HashSet[string]
foreach($r in $keep){ if($r.PSObject.Properties.Name -contains 'bid' -and $r.bid){ $null = $bids.Add([string]$r.bid) } }

# donor row for the synthetic items that must PRICE successfully: first kept row that is board-mapped
# with a weight unit. Deterministic over a frozen input, so the fixture is reproducible from this script.
$donor = @($keep | Where-Object { $_.bid -and $_.unit -and ($_.unit -in @('lb','oz','g','kg')) } | Sort-Object item) | Select-Object -First 1
if(-not $donor){ throw 'no weight-unit board-mapped donor row in the slice' }
$lbRow = @($keep | Where-Object { $_.bid -and $_.unit -eq 'lb' } | Sort-Object item) | Select-Object -First 1
if(-not $lbRow){ throw 'no lb-unit donor row in the slice' }
$keep = @($keep) + @(
  [pscustomobject]@{ item='ZZ Unpriced Item' }
  [pscustomobject]@{ item='ZZ Offboard Bid';   bid='zz-not-on-any-board'; gpu=1.0; unit='lb' }
  [pscustomobject]@{ item='ZZ Bulk No Pantry'; bid=$donor.bid; gpu=$donor.gpu; unit=$donor.unit; bulk=$true }
  [pscustomobject]@{ item='ZZ No Package Def'; bid=$donor.bid; gpu=$donor.gpu; unit=$donor.unit }
  [pscustomobject]@{ item='ZZ Unit Mismatch';  bid=$lbRow.bid; gpu=1.0; unit='each' }
)
$keep | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $fin 'db\ingredients.json') -Encoding UTF8

# ---- densities / label-prices trimmed; folds + allowlist copied whole (both tiny, both all-or-nothing) ----
$dens = (Get-Content (Join-Path $db 'densities.json') -Raw | ConvertFrom-Json)
$dkeep = [ordered]@{}
foreach($p in $dens.items.PSObject.Properties){ if($items.Contains($p.Name)){ $dkeep[$p.Name] = $p.Value } }
([ordered]@{ _doc='FROZEN fixture slice of db\densities.json'; items=$dkeep }) | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $fin 'db\densities.json') -Encoding UTF8

$folds = @((Get-Content (Join-Path $db 'label-folds.json') -Raw | ConvertFrom-Json).folds)
$lab = Get-Content (Join-Path $db 'label-prices.json') -Raw | ConvertFrom-Json
$lkeep = @($lab | Where-Object {
  $nm = [string]$_.item
  foreach($f in $folds){ if($nm -match [string]$f.match){ $nm = [string]$f.to; break } }
  $items.Contains($nm) -or $items.Contains([string]$_.item)
})
$lkeep | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $fin 'db\label-prices.json') -Encoding UTF8
Copy-Item (Join-Path $db 'label-folds.json')      (Join-Path $fin 'db\label-folds.json') -Force
Copy-Item (Join-Path $db 'no-board-price-ok.json') (Join-Path $fin 'db\no-board-price-ok.json') -Force

# ---- boards trimmed to the slice's bids, stamped with a frozen date ----
# All three are filtered by the SAME bid set, so the engine's resolution order (comparison -> recipe-board
# -> smp-feed) resolves each bid from exactly the same layer it does live. A bid dropped from only one
# layer would silently promote the next one and change every basis string in the expected output.
$cmpFile = Get-ChildItem (Join-Path $gout 'comparison-*.json') | Where-Object { $_.BaseName -match '^comparison-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending | Select-Object -First 1
$cmp = Get-Content $cmpFile.FullName -Raw | ConvertFrom-Json
[pscustomobject]@{
  _doc='FROZEN fixture slice'; source_file=$cmpFile.Name; built_at='2026-01-01T00:00:00'; week_of='2026-01-01'
  comparison=@($cmp.comparison | Where-Object { $bids.Contains([string]$_.id) })
} | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $fin 'grocery-out\comparison-2026-01-01.json') -Encoding UTF8

$rb = Get-Content (Join-Path $gout 'recipe-board.json') -Raw | ConvertFrom-Json
[pscustomobject]@{
  _doc='FROZEN fixture slice'; week_of='2026-01-01'; built_at='2026-01-01T00:00:00'
  comparison=@($rb.comparison | Where-Object { $bids.Contains([string]$_.id) })
} | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $fin 'grocery-out\recipe-board.json') -Encoding UTF8

$feed = Get-Content (Join-Path $gout 'smp-feed.json') -Raw | ConvertFrom-Json
$fkeep = [ordered]@{}
foreach($p in $feed.ingredients.PSObject.Properties){ if($bids.Contains($p.Name)){ $fkeep[$p.Name] = $p.Value } }
[pscustomobject]@{ _doc='FROZEN fixture slice'; generated='2026-01-01T00:00:00'; week_of='2026-01-01'; ingredients=$fkeep } |
  ConvertTo-Json -Depth 12 | Set-Content (Join-Path $fin 'grocery-out\smp-feed.json') -Encoding UTF8

Write-Output ("seeded {0} real specs + 1 synthetic; {1} ingredient rows; {2} bids; comparison {3} rows" -f $SLUGS.Count, $keep.Count, $bids.Count, @($cmp.comparison | Where-Object { $bids.Contains([string]$_.id) }).Count)
Write-Output "next: engine\golden-test.ps1 -Rebaseline   (writes expected\ + MANIFEST.json)"
