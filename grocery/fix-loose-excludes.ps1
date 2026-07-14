$ErrorActionPreference = 'Stop'
$f = Join-Path $PSScriptRoot 'commodities.json'
$c = Get-Content $f -Raw | ConvertFrom-Json

# category-excludes that legitimate versions of each food never contain. Confirmed by the wrong matches the
# resolver + price pull produced: blueberries->Bai beverage (LIVE mispricing), grapes->electrolyte drink,
# strawberries->spiked malt beverage, sweet-corn->baby food, vegetable-oil->oil spread, hot-dogs->dog treats.
$add = @{
  'blueberries'   = @('beverage','\bdrink\b','antioxidant','electrolyte','sparkling','kombucha','\bsoda\b','\bjuice\b','\bbai\b')
  'grapes'        = @('beverage','\bdrink\b','electrolyte','electrolit','gatorade','powerade','antioxidant','\bsoda\b','energy')
  'strawberries'  = @('beverage','\bmalt\b','spiked','\bbeer\b','hard\s+seltzer','\bdrink\b','electrolyte','\bsoda\b')
  'sweet-corn'    = @('beech\s*nut','gerber','\bstage\s*\d','\bbaby\b','puree','green\s+beans')
  'vegetable-oil' = @('\bspread\b','margarine')
  'hot-dogs'      = @('\bcanine\b','dog\s+snack','dog\s+treat','carry\s*outs','\bpet\b')
}

$changed = 0
foreach ($id in $add.Keys) {
  $x = $c | Where-Object { $_.id -eq $id } | Select-Object -First 1
  if (-not $x) { Write-Output "WARN: no commodity '$id'"; continue }
  $have = @($x.exclude)
  $new = @()
  foreach ($p in $add[$id]) { if ($have -notcontains $p) { $new += $p } }
  if ($new.Count) { $x.exclude = @($have + $new); $changed += $new.Count; Write-Output ("  {0,-16} +{1} excludes: {2}" -f $id, $new.Count, ($new -join ', ')) }
}
($c | ConvertTo-Json -Depth 6) | Set-Content $f -Encoding UTF8
Write-Output "added $changed exclude patterns across $($add.Count) commodities"
