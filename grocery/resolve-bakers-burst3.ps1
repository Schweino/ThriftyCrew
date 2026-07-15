<#
  resolve-bakers-burst3.ps1 - third Baker's pass (targeted retry with the size check relaxed + brand-specific
  queries). 6 vetted matches; excluded 3 brand-mismatches (Baker's search returned Bertolli/McCormick/Louisiana
  where the board records Filippo Berio/Kroger/Kroger). URL = /p/<slug>/<upc>, anchored to the board cell.
#>
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$raw = @'
canned-pears~del-monte-pear-halves~0002400001022
vegetable-broth~kroger-fat-free-vegetable-broth~0001111004968
canned-yams~bruce-s-cut-sweet-potato-yams-in-syrup~0001760004386
black-olives~kroger-small-pitted-ripe-olives~0001111082201
minced-garlic~spice-world-minced-garlic-32-oz~0007096900111
bell-peppers~fresh-large-green-bell-pepper~0000000004065
'@
$cmpF = (Get-ChildItem (Join-Path $root 'out\comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1).FullName
$cmp = Get-Content $cmpF -Raw | ConvertFrom-Json
$cellOf = @{}
foreach ($it in $cmp.comparison) { $c = $it.stores | Where-Object { $_.store -eq "Baker's" } | Select-Object -First 1; if ($c) { $cellOf[[string]$it.id] = $c } }
$rows = New-Object System.Collections.ArrayList
foreach ($ln in ($raw -split "`n")) {
  $ln = $ln.Trim(); if (-not $ln) { continue }
  $p = $ln -split '~'; if ($p.Count -lt 3) { continue }
  $cell = $cellOf[$p[0]]; if (-not $cell) { Write-Output "  SKIP $($p[0]) (no cell)"; continue }
  $price = 0.0; [void][double]::TryParse((([string]$cell.ad) -replace '[^0-9.]', ''), [ref]$price)
  [void]$rows.Add([ordered]@{ id = $p[0]; url = 'https://www.bakersplus.com/p/' + $p[1] + '/' + $p[2]; price = $price; size = [string]$cell.size; name = [string]$cell.item })
}
($rows | ConvertTo-Json -Depth 4) | Set-Content (Join-Path $root 'out\url-inputs\store-bakers-urls.json') -Encoding UTF8
Write-Output ("wrote $($rows.Count) Baker's links (burst 3)")
