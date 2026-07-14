<#
  import-walmart-prices.ps1 - fold Walmart's CURRENT prices into walmart-regular-<date>.json.

  *** THE TRAP THIS SCRIPT EXISTS TO AVOID ***
  `priceInfo.currentPrice.price` is the price of the WHOLE PACK. For a weighted item that is the price of the
  tray, not the price of a pound: chicken breast comes back as $10.35 (a ~4 lb tray), chuck roast as $17.93,
  pork ribs as $11.15. Our board rows for meat and produce are PER POUND. A first version of this importer
  wrote currentPrice straight onto them and would have republished chicken breast at $10.35/LB instead of
  $2.48/lb - a real, freshly-captured, correctly-timestamped number that is completely false in the basis we
  publish in. That is the worst failure mode there is: internally consistent, confidently dated, and invisible
  to any check that only compares our own numbers to each other. It was caught by reading the diff, not by a
  guard. Our existing Walmart prices were already right; the "fix" was the bug.

  *** THE RULE ***
  ad_price is the price of ONE `size`. So:

        ad_price = (Walmart's price per commodity-unit)  x  (the quantity our `size` represents)

  That single formula is correct in BOTH bases and needs no special-casing:
        size "lb"    unit lb   -> qty 1   -> ad_price = per-lb price          ($2.48)
        size "16 oz" unit oz   -> qty 16  -> ad_price = the pack price        ($3.24)
  The per-unit number comes from `priceInfo.unitPrice` (whose `priceString` names its basis: "$5.31/lb",
  "12.4 c/oz", "2.4 c/fl oz"), converted into the commodity's own unit.

  *** THE CROSS-CHECK ***
  currentPrice / unitPrice = the quantity in Walmart's pack. If our `size` states a quantity, it MUST match
  that pack (within 5%) - otherwise the itemId now points at a different pack, and its price is a true number
  attached to a false amount. Those are refused and named, never published. A bare per-unit basis (`lb`,
  `each`, `dozen`, `gallon` -> qty 1) legitimately differs from the pack size, and is allowed through.

  A row we cannot verify is LEFT ALONE. Silence beats a confident lie.
#>
param([switch]$WhatIf)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
. (Join-Path $root 'pu-lib.ps1')
$today = (Get-Date -Format 'yyyy-MM-dd')

# ---- Walmart's unit-price basis -> a price per ONE unit of the commodity ------------------------------
# unitPrice.price is already numeric per its own basis (5.31 for "$5.31/lb", 0.124 for "12.4 c/oz").
# priceString is the only thing that names that basis, so it is what we read.
function Convert-UnitPrice([double]$val, [string]$basisStr, [string]$commodityUnit) {
  if ($val -le 0) { return $null }
  $b = ''
  $m = [regex]::Match(([string]$basisStr).ToLower(), '/\s*(fl\s*oz|floz|oz|lb|ea|each|ct|count|gal|gallon)')
  if ($m.Success) { $b = ($m.Groups[1].Value -replace '\s','') }
  if (-not $b) { return $null }
  switch ($commodityUnit) {
    'lb'     { if ($b -eq 'lb') { return $val }; if ($b -eq 'oz') { return ($val * 16) }; return $null }
    'oz'     { if ($b -eq 'oz') { return $val }; if ($b -eq 'lb') { return ($val / 16) }; return $null }
    'floz'   { if ($b -match '^(floz)$') { return $val }; if ($b -match '^(gal|gallon)$') { return ($val / 128) }; return $null }
    'gallon' { if ($b -match '^(gal|gallon)$') { return $val }; if ($b -eq 'floz') { return ($val * 128) }; return $null }
    'each'   { if ($b -match '^(ea|each|ct|count)$') { return $val }; return $null }
    'dozen'  { if ($b -match '^(ea|each|ct|count)$') { return ($val * 12) }; return $null }
    default  { return $null }
  }
}

$rawF = Join-Path $root 'out\walmart-prices-raw.json'
if (-not (Test-Path $rawF)) { throw "missing $rawF - run the browser capture first" }
$raw = Get-Content $rawF -Raw | ConvertFrom-Json
$price = @{}
foreach ($p in $raw.PSObject.Properties) { if ($p.Value -and ($null -ne $p.Value.cur)) { $price[[string]$p.Name] = $p.Value } }
Write-Output ("Walmart prices captured from the store : " + $price.Count)

$pd = (Get-Content (Join-Path $root 'product-urls.json') -Raw | ConvertFrom-Json).items
$units = @{}
foreach ($c in (Get-Content (Join-Path $root 'commodities.json') -Raw | ConvertFrom-Json)) { $units[[string]$c.id] = [string]$c.unit }

$idByName = @{}
foreach ($p in $pd.PSObject.Properties) {
  $e = $p.Value.Walmart
  if (-not ($e -and $e.url -and $e.name)) { continue }
  if (([string]$e.url) -notmatch '/ip/(?:[^/]+/)?(\d+)') { continue }
  $k = ([string]$e.name).ToLower().Trim()
  if (-not $idByName.ContainsKey($k)) { $idByName[$k] = [pscustomobject]@{ id=$Matches[1]; cid=[string]$p.Name } }
}

$regF = (Get-ChildItem (Join-Path $root 'out\regular\walmart-regular-*.json') |
  Where-Object { $_.BaseName -match '^walmart-regular-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending | Select-Object -First 1)
$doc = Get-Content $regF.FullName -Raw | ConvertFrom-Json

$rows = New-Object System.Collections.ArrayList
$upd=0; $down=0; $noId=0; $noPrice=0; $noBasis=0; $packMismatch=0; $same=0
$changed = New-Object System.Collections.Generic.List[string]
$refused = New-Object System.Collections.Generic.List[string]

foreach ($d in $doc.deals) {
  $row = [ordered]@{ store='Walmart'; item=[string]$d.item; ad_price=[string]$d.ad_price; size=[string]$d.size; regular=$d.regular; source_ad=[string]$d.source_ad }
  foreach ($k in @('as_of','restored','restored_for','carried_forward')) { if ($d.$k) { $row[$k] = $d.$k } }

  $k = ([string]$d.item).ToLower().Trim()
  if (-not $idByName.ContainsKey($k)) { $noId++; [void]$rows.Add($row); continue }
  $hit = $idByName[$k]
  if (-not $price.ContainsKey([string]$hit.id)) { $noPrice++; [void]$rows.Add($row); continue }
  $pv = $price[[string]$hit.id]

  $cur  = [double]$pv.cur
  $unit = [string]$units[[string]$hit.cid]
  $size = [string]$d.size
  if ($cur -le 0 -or -not $unit) { $noPrice++; [void]$rows.Add($row); continue }

  # Walmart's price per ONE commodity unit
  $wpu = $null
  if ($null -ne $pv.uv) { $wpu = Convert-UnitPrice ([double]$pv.uv) ([string]$pv.us) $unit }
  if ($null -eq $wpu -or $wpu -le 0) {
    $noBasis++
    $refused.Add(('  {0,-46} no usable unit basis (Walmart says "{1}", our unit is {2}) - left alone' -f ([string]$d.item), ([string]$pv.us), $unit))
    [void]$rows.Add($row); continue
  }

  # the quantity OUR size represents, in the commodity's unit
  $pu1 = Get-LinkPerUnit -size $size -unit $unit -price 1 -name ([string]$d.item)
  if (($null -eq $pu1) -or ([double]$pu1 -le 0)) {
    $noBasis++
    $refused.Add(('  {0,-46} our size "{1}" yields no quantity - left alone' -f ([string]$d.item), $size))
    [void]$rows.Add($row); continue
  }
  $ourQty = 1.0 / [double]$pu1

  # CROSS-CHECK: currentPrice / wpu = the quantity in Walmart's pack. If our size states a QUANTITY it must
  # match that pack. A bare per-unit basis (qty 1: lb / each / dozen / gallon) legitimately differs.
  $packQty = $cur / $wpu
  if (([math]::Abs($ourQty - 1.0) -gt 0.001) -and ([math]::Abs($packQty - $ourQty) -gt ($ourQty * 0.05))) {
    $packMismatch++
    $refused.Add(('  {0,-46} our size says {1} {2}, Walmart''s pack is {3} {2} - different pack, price REFUSED' -f ([string]$d.item), [math]::Round($ourQty,2), $unit, [math]::Round($packQty,2)))
    [void]$rows.Add($row); continue
  }

  # THE FORMULA. Correct in both bases.
  $newAd = [math]::Round($wpu * $ourQty, 2)
  if ($newAd -le 0) { $noPrice++; [void]$rows.Add($row); continue }

  # the was-price, brought into OUR basis (wasPrice is a PACK price, like currentPrice)
  $newBase = $null
  if (($null -ne $pv.was) -and ([double]$pv.was -gt 0) -and ($packQty -gt 0)) {
    $newBase = [math]::Round(([double]$pv.was / $packQty) * $ourQty, 2)
  }

  $old = [string]$d.ad_price
  $oldN = 0.0; [void][double]::TryParse(($old -replace '[^0-9.]',''), [ref]$oldN)

  $row['ad_price'] = ('$' + $newAd)
  $row['regular']  = $newAd
  # THE CONTRACT (guards invariant 10): what the STORE CHARGES, in the SAME BASIS as what we publish, recorded
  # as its own assignment. Rewire ad_price to the was-price and these two stop agreeing, and guard 10 blocks.
  $row['current_price'] = $newAd
  if ($null -ne $newBase -and $newBase -gt $newAd) { $row['base_price'] = $newBase }
  if ($pv.red -and ($null -ne $newBase) -and ($newAd -lt ($newBase - 0.005))) { $row['marked_down'] = $true; $down++ }
  $row['source_ad'] = 'walmart.com currentPrice/unitPrice (Omaha L St Supercenter) - the price the store charges today'
  $row['as_of'] = $today
  $row['item_id'] = [string]$hit.id

  if ([math]::Abs($oldN - $newAd) -gt 0.005) {
    $changed.Add(('  {0,-46} {1,-9} -> ${2,-8} ({3} per {4}{5})' -f ([string]$d.item), $old, $newAd, [math]::Round($wpu,4), $unit, $(if($newBase){', was $' + $newBase}else{''})))
  } else { $same++ }
  $upd++
  [void]$rows.Add($row)
}

Write-Output ("rows refreshed from the store          : $upd   ($down marked down, $same unchanged)")
Write-Output ("REFUSED - different pack than our size : $packMismatch")
Write-Output ("skipped - no usable unit basis         : $noBasis")
Write-Output ("no link / no price captured            : $noId / $noPrice")
Write-Output ''
if ($changed.Count) {
  Write-Output ("PRICE CHANGES (" + $changed.Count + "):")
  foreach ($c in ($changed | Select-Object -First 30)) { Write-Output $c }
  if ($changed.Count -gt 30) { Write-Output ("  ... and " + ($changed.Count - 30) + " more") }
  Write-Output ''
}
if ($refused.Count) {
  Write-Output ("REFUSED / SKIPPED (" + $refused.Count + ") - left at their existing price:")
  foreach ($c in ($refused | Select-Object -First 12)) { Write-Output $c }
  if ($refused.Count -gt 12) { Write-Output ("  ... and " + ($refused.Count - 12) + " more") }
}

if ($WhatIf) { Write-Output ''; Write-Output 'WhatIf: nothing written'; return }
$doc.deals = $rows.ToArray()
$doc | Add-Member -NotePropertyName price_mode -NotePropertyValue 'in-store' -Force
$doc | Add-Member -NotePropertyName refreshed_today -NotePropertyValue $upd -Force
($doc | ConvertTo-Json -Depth 6) | Set-Content $regF.FullName -Encoding UTF8
Write-Output ''
Write-Output ("wrote -> " + $regF.Name)
