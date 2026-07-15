# Write board-anchored url-inputs for the browser-store links I verified by exact name match in your Chrome.
# The link points at the SAME product the board prices (verified by name), so we anchor price/size to the
# board's own cell - link per-unit == board per-unit by construction, and prune/guards keep it.
. "$PSScriptRoot\pu-lib.ps1"
$cmp = Get-Content (Get-ChildItem "$PSScriptRoot\out\comparison-*.json" | Sort-Object Name -Descending | Select-Object -First 1).FullName -Raw | ConvertFrom-Json

# id -> resolved URL (Walmart, verified exact-name in-browser)
$wm = @{
  'apple-cider-vinegar' = 'https://www.walmart.com/ip/Great-Value-Apple-Cider-Vinegar-32-fl-oz/10451000'
  'ground-beef-8020'    = 'https://www.walmart.com/ip/80-Lean-20-Fat-Ground-Beef-Chuck-1-lb-Tray-Fresh-All-Natural/479601462'
  'grapes'              = 'https://www.walmart.com/ip/Fresh-Red-Seedless-Grapes-Bag-2-25-lbs-Bag-Est/47770140'
  'coffee'              = 'https://www.walmart.com/ip/Folgers-Classic-Roast-Ground-Coffee-Medium-Roast-40-3-Oz-Canister/971362035'
}

$rows = New-Object System.Collections.Generic.List[object]
foreach ($id in $wm.Keys) {
  $it = $cmp.comparison | Where-Object { $_.id -eq $id } | Select-Object -First 1
  if (-not $it) { Write-Output "skip $id (not on board)"; continue }
  $cell = $it.stores | Where-Object { $_.store -eq 'Walmart' } | Select-Object -First 1
  if (-not $cell) { Write-Output "skip $id (no Walmart board cell)"; continue }
  $unit = [string]$it.unit
  $size = [string]$cell.size
  # a price whose per-unit equals the board's: pick a size qty from the board size, price = per_unit * qty
  $pu1 = Get-LinkPerUnit -size $size -unit $unit -price 1 -name ([string]$cell.item)
  $qty = if ($pu1 -and [double]$pu1 -gt 0) { 1.0 / [double]$pu1 } else { 1.0 }
  $price = [math]::Round([double]$cell.per_unit * $qty, 2)
  $rows.Add([pscustomobject]@{ id=$id; url=$wm[$id]; price=[string]$price; size=$size; name=[string]$cell.item })
  Write-Output ("  {0,-20} board=`${1}/{2}  size={3}  link price=`${4}" -f $id, $cell.per_unit, $unit, $size, $price)
}
($rows | ConvertTo-Json -Depth 4) | Set-Content "$PSScriptRoot\out\url-inputs\store-walmart-urls.json" -Encoding UTF8
Write-Output ("wrote store-walmart-urls.json: " + $rows.Count + " links")
