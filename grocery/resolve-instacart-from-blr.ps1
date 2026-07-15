<#
  resolve-instacart-from-blr.ps1 - turn the ILR iframe board-match output (id~path) for the Instacart stores
  (Aldi, Fareway) into merge-format store-<slug>-urls.json. URL = <host> + path. Price/size/name anchored to the
  board cell (per-unit == board by construction). Only size-verified, correct-brand matches are included here
  (wrong-brand / wrong-size matches were dropped manually - the ILR pass did not enforce size).
#>
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$cmpF = (Get-ChildItem (Join-Path $root 'out\comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1).FullName
$cmp = Get-Content $cmpF -Raw | ConvertFrom-Json

$jobs = @(
  @{ store = 'Aldi'; slug = 'aldi'; host = 'https://www.aldi.us'; raw = @'
shredded-cheese~/store/aldi/products/19335029-happy-farms-shredded-mild-cheddar-cheese-16-oz
zucchini~/store/aldi/products/193785-zucchini-squash-1-lb
canned-white-beans~/store/aldi/products/19688306-dakota-s-pride-cannellini-beans-15-5-oz
tomatoes-green-chilies~/store/aldi/products/18648903-casa-mamita-diced-tomatoes-with-green-chilies-10-oz
miracle-whip~/store/aldi/products/20243936-burman-s-whipped-dressing-30-fl-oz
caesar-dressing~/store/aldi/products/18649500-tuscan-garden-dressing-and-dip-classic-caesar-16-fl-oz
green-olives~/store/aldi/products/56530188-tuscan-garden-manzanilla-olives-stuffed-with-pimiento-10-oz
'@ },
  @{ store = 'Fareway'; slug = 'fareway'; host = 'https://shop.fareway.com'; raw = @'
clam-chowder~/store/fareway-meat-grocery/products/37431-campbell-s-chunky-new-england-clam-chowder-18-8-oz
blue-cheese-dressing~/store/fareway-meat-grocery/products/16752065-wish-bone-chunky-blue-cheese-dressing-15-oz
balsamic-vinegar~/store/fareway-meat-grocery/products/27987867-bertolli-balsamic-vinegar-of-modena-16-9-fl-oz
horseradish~/store/fareway-meat-grocery/products/71185-inglehoffer-horseradish-thick-n-creamy-3-75-oz
floor-cleaner~/store/fareway-meat-grocery/products/94670-swiffer-wetjet-multi-purpose-and-hardwood-liquid-floor-cleaner-solution-refill-42-3-fl-oz
'@ }
)

foreach ($j in $jobs) {
  $cellOf = @{}
  foreach ($it in $cmp.comparison) { $c = $it.stores | Where-Object { $_.store -eq $j.store } | Select-Object -First 1; if ($c) { $cellOf[[string]$it.id] = $c } }
  $rows = New-Object System.Collections.ArrayList
  foreach ($ln in ($j.raw -split "`n")) {
    $ln = $ln.Trim(); if (-not $ln) { continue }
    $p = $ln -split '~', 2
    if ($p.Count -lt 2) { continue }
    $id = $p[0]; $path = $p[1]
    $cell = $cellOf[$id]
    if (-not $cell) { Write-Output "  SKIP $id (no $($j.store) cell)"; continue }
    $price = 0.0; [void][double]::TryParse((([string]$cell.ad) -replace '[^0-9.]', ''), [ref]$price)
    $url = $j.host + $path
    [void]$rows.Add([ordered]@{ id = $id; url = $url; price = $price; size = [string]$cell.size; name = [string]$cell.item })
  }
  $out = Join-Path $root ('out\url-inputs\store-' + $j.slug + '-urls.json')
  ($rows | ConvertTo-Json -Depth 4) | Set-Content $out -Encoding UTF8
  Write-Output ("wrote $($rows.Count) $($j.store) links -> $(Split-Path $out -Leaf)")
}
