<#
  resolve-bakers-from-blr.ps1 - turn the BLR board-match output (id~slug~upc, captured from the warm Baker's
  tab) into the merge-format store-bakers-urls.json. URL = /p/<slug>/<upc>. Price/size/name are ANCHORED to the
  board's Baker's cell so the link per-unit equals the board's by construction (prune-bad-links can't drop it).
  Drops any id with no Baker's cell on the current board.
#>
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
# id~slug~upc (apples excluded: matched a 5 lb bag vs the board's 3 lb - uncertain size, left unlinked)
$raw = @'
heavy-cream~kroger-heavy-whipping-cream-quart~0001111050312
string-cheese~frigo-cheese-heads-original-mozzarella-string-cheese~0004171623221
blueberries~fresh-blueberries-1-pt-clamshell~0003338322101
chili-beans~kroger-original-chili-with-beans~0001111013516
canned-white-beans~kroger-great-northern-beans~0001111089594
canned-mixed-vegetables~kroger-no-salt-added-mixed-vegetables-15oz-can~0001111081118
canned-beets~kroger-shoestring-beets-15oz-can~0001111080515
sauerkraut~kroger-shredded-sauerkraut~0001111097759
cranberry-sauce~kroger-whole-berry-cranberry-sauce~0001111089665
'@

$cmpF = (Get-ChildItem (Join-Path $root 'out\comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1).FullName
$cmp = Get-Content $cmpF -Raw | ConvertFrom-Json
$cellOf = @{}
foreach ($it in $cmp.comparison) { $c = $it.stores | Where-Object { $_.store -eq "Baker's" } | Select-Object -First 1; if ($c) { $cellOf[[string]$it.id] = $c } }

$rows = New-Object System.Collections.ArrayList
foreach ($ln in ($raw -split "`n")) {
  $ln = $ln.Trim(); if (-not $ln) { continue }
  $p = $ln -split '~'
  if ($p.Count -lt 3) { continue }
  $id = $p[0]; $slug = $p[1]; $upc = $p[2]
  $cell = $cellOf[$id]
  if (-not $cell) { Write-Output "  SKIP $id (no Baker's cell)"; continue }
  $price = 0.0; [void][double]::TryParse((([string]$cell.ad) -replace '[^0-9.]', ''), [ref]$price)
  $url = 'https://www.bakersplus.com/p/' + $slug + '/' + $upc
  [void]$rows.Add([ordered]@{ id = $id; url = $url; price = $price; size = [string]$cell.size; name = [string]$cell.item })
}
$out = Join-Path $root 'out\url-inputs\store-bakers-urls.json'
($rows | ConvertTo-Json -Depth 4) | Set-Content $out -Encoding UTF8
Write-Output ("wrote $($rows.Count) Baker's links -> $out")
