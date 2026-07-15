<#
  resolve-bakers-burst.ps1 - second Baker's BLR pass (cooldown burst after the Akamai wall lifted on re-warm).
  23 vetted matches (excluded 5: apples 5lb-vs-3lb, canned-yams Kroger-vs-Bruce's, coconut-milk half-gal-vs-13.5oz,
  minced-garlic 4.5-vs-32oz, black-olives Large-vs-Small). URL = /p/<slug>/<upc>, price/size/name anchored to board.
#>
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$raw = @'
chicken-wings~heritage-farm-bone-in-skin-on-chicken-wings~0025313500000
coffee-creamer~kroger-italian-sweet-cream-coffee-creamer~0001111015107
beef-stew~kroger-beef-stew~0001111084956
corned-beef-hash~hormel-mary-kitchen-corned-beef-hash~0003760080744
canned-pumpkin~kroger-100-pure-pumpkin~0001111089978
tomatoes-green-chilies~kroger-diced-tomatoes-w-green-chilies-mild~0001111011966
canned-green-chilies~kroger-diced-green-chile-peppers~0001111084009
artichoke-hearts~kroger-quartered-artichoke-hearts-in-brine~0001111090676
bouillon~knorr-chicken-bouillon-cubes~0006264607009
canned-potatoes~kroger-whole-white-potatoes-15oz-can~0001111081365
hominy~juanita-s-foods-mexican-style-hominy-110-oz-can~0007013200600
jarred-gravy~campbell-s-turkey-gravy-10-5-oz-can~0005100002554
honey-mustard~kroger-honey-mustard~0001111009619
caesar-dressing~ken-s-steak-house-creamy-caesar-salad-dressing~0004133500176
horseradish~silver-spring-coarse-cut-prepared-horseradish~0004154302008
bottled-marinade~lawry-s-steak-chop-marinade-12-0-fl-oz~0002150004217
pickled-jalapenos~la-costena-sliced-jalapeno-peppers~0007639700212
banana-peppers~mezzetta-mild-banana-pepper-rings~0007321400162
lime-juice~realime-100-lime-juice-15-fl-oz-bottle~0001480058205
cereal~kroger-bite-size-frosted-shredded-wheat-cereal~0001111086705
peanut-butter~kroger-creamy-peanut-butter~0001111009853
oven-cleaner~easy-off-heavy-duty-oven-cleaner-destroys-tough-burnt-on-food-and-grease-14-5-oz~0006233887979
bread-crumbs~kikkoman-panko-japanese-style-bread-crumbs~0004139005004
'@
$cmpF = (Get-ChildItem (Join-Path $root 'out\comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1).FullName
$cmp = Get-Content $cmpF -Raw | ConvertFrom-Json
$cellOf = @{}
foreach ($it in $cmp.comparison) { $c = $it.stores | Where-Object { $_.store -eq "Baker's" } | Select-Object -First 1; if ($c) { $cellOf[[string]$it.id] = $c } }
$rows = New-Object System.Collections.ArrayList
foreach ($ln in ($raw -split "`n")) {
  $ln = $ln.Trim(); if (-not $ln) { continue }
  $p = $ln -split '~'; if ($p.Count -lt 3) { continue }
  $id = $p[0]; $slug = $p[1]; $upc = $p[2]
  $cell = $cellOf[$id]; if (-not $cell) { Write-Output "  SKIP $id (no cell)"; continue }
  $price = 0.0; [void][double]::TryParse((([string]$cell.ad) -replace '[^0-9.]', ''), [ref]$price)
  [void]$rows.Add([ordered]@{ id = $id; url = 'https://www.bakersplus.com/p/' + $slug + '/' + $upc; price = $price; size = [string]$cell.size; name = [string]$cell.item })
}
($rows | ConvertTo-Json -Depth 4) | Set-Content (Join-Path $root 'out\url-inputs\store-bakers-urls.json') -Encoding UTF8
Write-Output ("wrote $($rows.Count) Baker's links (burst 2)")
