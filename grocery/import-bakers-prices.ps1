<#
  import-bakers-prices.ps1 - fold Baker's (Kroger) CURRENT shelf prices into bakers-regular-<date>.json,
  recording current_price so guard 10 can police them. A byte-for-byte-in-spirit copy of
  import-walmart-prices.ps1, adapted for the Baker's capture:

    * INPUT is CSV, not JSON:  out\bakers-prices-raw.csv  with columns  upc,price,was,unitVal,unitOf,elp
      (produced by hyvee\bakers-browser-pull.js  BK.dump()). Matching is ALWAYS by UPC, never by name -
      the UPC is taken from each board row's Baker's product URL (/p/<slug>/<upc>).
    * The per-unit basis is unitVal + unitOf ("$0.19 /oz" -> 0.19, "oz") instead of Walmart's uv + priceString.

  SAME TRAP, SAME RULE (see import-walmart-prices.ps1 header): Baker's `price` is the WHOLE-PACK / display
  price. Publishing it onto a per-lb or per-oz row would republish a pack price as a per-unit price. So:

        ad_price = (Baker's price per commodity-unit)  x  (the quantity our `size` represents)

  where the per-unit number comes from unitVal/unitOf. The pack cross-check (price / unitVal = pack qty, must
  match our size within 5%) and the factor rail (>3x/<0.33x = wrong item or bad basis, refused) are identical.
  A row we cannot verify is LEFT ALONE. Silence beats a confident lie.
#>
param([switch]$WhatIf)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
. (Join-Path $root 'pu-lib.ps1')
$today = (Get-Date -Format 'yyyy-MM-dd')

# Baker's unit-price basis (unitVal in unitOf units) -> a price per ONE unit of the commodity.
# unitOf comes straight from the card regex (fl oz|oz|lb|ea|ct|sq ft); it is already the clean basis unit.
# STRICT: a fl-oz commodity matches only Baker's "fl oz", never bare "oz" (weight) - guessing across the
# weight/volume line is how a per-oz jar price lands on a per-fl-oz row.
function Convert-BakersUnit([double]$val, [string]$of, [string]$commodityUnit) {
  if ($val -le 0) { return $null }
  $b = (([string]$of).ToLower() -replace '\s','')   # "fl oz"->"floz", "oz"->"oz", "lb","ea","ct","sqft"
  if (-not $b) { return $null }
  switch ($commodityUnit) {
    'lb'     { if ($b -eq 'lb') { return $val }; if ($b -eq 'oz') { return ($val * 16) }; return $null }
    'oz'     { if ($b -eq 'oz') { return $val }; if ($b -eq 'lb') { return ($val / 16) }; return $null }
    'floz'   { if ($b -eq 'floz') { return $val }; return $null }
    'gallon' { if ($b -eq 'floz') { return ($val * 128) }; return $null }
    'each'   { if ($b -match '^(ea|ct)$') { return $val }; return $null }
    'dozen'  { if ($b -match '^(ea|ct)$') { return ($val * 12) }; return $null }
    default  { return $null }
  }
}

# ---- read the capture CSV: upc,price,was,unitVal,unitOf,elp ----
$rawF = Join-Path $root 'out\bakers-prices-raw.csv'
if (-not (Test-Path $rawF)) { throw "missing $rawF - run the browser capture (BK.dump()) first" }
$price = @{}
foreach ($ln in (Get-Content $rawF)) {
  $t = ([string]$ln).Trim(); if (-not $t) { continue }
  $c = $t -split ','
  if ($c.Count -lt 6) { continue }
  $upc = $c[0].Trim(); if (-not $upc) { continue }
  $pnum = 0.0; [void][double]::TryParse((($c[1]) -replace '[^0-9.]',''), [ref]$pnum)
  if ($pnum -le 0) { continue }
  $wnum = 0.0; [void][double]::TryParse((($c[2]) -replace '[^0-9.]',''), [ref]$wnum)
  $uvnum = 0.0; [void][double]::TryParse((($c[3]) -replace '[^0-9.]',''), [ref]$uvnum)
  $price[$upc] = [pscustomobject]@{ cur=$pnum; was=$(if ($wnum -gt 0) { $wnum } else { $null }); uv=$(if ($uvnum -gt 0) { $uvnum } else { $null }); uof=([string]$c[4]).Trim(); elp=($c[5].Trim() -eq '1') }
}
Write-Output ("Baker's prices captured from the store  : " + $price.Count)

$pd = (Get-Content (Join-Path $root 'product-urls.json') -Raw | ConvertFrom-Json).items
$units = @{}
foreach ($c in (Get-Content (Join-Path $root 'commodities.json') -Raw | ConvertFrom-Json)) { $units[[string]$c.id] = [string]$c.unit }

# map each board row (by its Baker's product NAME, our own data on both sides) -> {upc, cid}. The UPC is the
# only thing we ever match the STORE price on. A second, NORMALIZED index (trailing size/count/pack descriptor
# stripped: "...Eggs 12 ct" == "...Eggs") recovers rows whose regular-file name differs from the product-urls
# name only by such a suffix - but ONLY when the normalized key maps to exactly ONE Baker's product (unique),
# and the match still has to clear the pack cross-check and the factor rail below. Both are our own data, so
# this is not the store-search name-guessing the pull script warns against.
function NKey([string]$s) {
  $x = ([string]$s).ToLower()
  $x = $x -replace '\(.*?\)',' '
  $x = $x -replace '\b\d+(\.\d+)?\s*(ct|count|oz|lb|lbs|fl\s*oz|pk|pack|gal|gallon|qt|ea|each|dozen|doz|sq\s*ft)\b',' '
  $x = $x -replace '\b\d+\s*-\s*\d+\s*[a-z]+\b',' '
  $x = $x -replace '\bfamily\s+(pack|size)\b',' '
  $x = $x -replace '\b(big deal!?|bag|clamshell|tub|roll|rolls|jumbo|sticks?|stick)\b',' '
  $x = ($x -replace '[^a-z0-9 ]',' ') -replace '\s+',' '
  $x.Trim()
}
$idByName = @{}
$normIdx = @{}
foreach ($p in $pd.PSObject.Properties) {
  $e = $p.Value.'Baker''s'
  if (-not ($e -and $e.url -and $e.name)) { continue }
  if (([string]$e.url) -notmatch '/p/[^/]+/(\d+)') { continue }
  $rec = [pscustomobject]@{ upc=$Matches[1]; cid=[string]$p.Name }
  $k = ([string]$e.name).ToLower().Trim()
  if (-not $idByName.ContainsKey($k)) { $idByName[$k] = $rec }
  $nk = NKey ([string]$e.name)
  if ($nk) { if (-not $normIdx.ContainsKey($nk)) { $normIdx[$nk] = New-Object System.Collections.Generic.List[object] }; $normIdx[$nk].Add($rec) }
}

$regF = (Get-ChildItem (Join-Path $root 'out\regular\bakers-regular-*.json') |
  Where-Object { $_.BaseName -match '^bakers-regular-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending | Select-Object -First 1)
$doc = Get-Content $regF.FullName -Raw | ConvertFrom-Json

$rows = New-Object System.Collections.ArrayList
$upd=0; $down=0; $noId=0; $noPrice=0; $noBasis=0; $packMismatch=0; $same=0
$changed = New-Object System.Collections.Generic.List[string]
$refused = New-Object System.Collections.Generic.List[string]

foreach ($d in $doc.deals) {
  $row = [ordered]@{ store="Baker's"; item=[string]$d.item; ad_price=[string]$d.ad_price; size=[string]$d.size; regular=$d.regular; source_ad=[string]$d.source_ad }
  foreach ($k in @('as_of','restored','restored_for','carried_forward')) { if ($d.$k) { $row[$k] = $d.$k } }

  $k = ([string]$d.item).ToLower().Trim()
  $hit = $null
  if ($idByName.ContainsKey($k)) { $hit = $idByName[$k] }
  else { $nk = NKey ([string]$d.item); if ($normIdx.ContainsKey($nk) -and $normIdx[$nk].Count -eq 1) { $hit = $normIdx[$nk][0] } }
  if ($null -eq $hit) { $noId++; [void]$rows.Add($row); continue }
  if (-not $price.ContainsKey([string]$hit.upc)) { $noPrice++; [void]$rows.Add($row); continue }
  $pv = $price[[string]$hit.upc]

  $cur  = [double]$pv.cur
  $unit = [string]$units[[string]$hit.cid]
  $size = [string]$d.size
  if ($cur -le 0 -or -not $unit) { $noPrice++; [void]$rows.Add($row); continue }

  # Baker's price per ONE commodity unit, from unitVal/unitOf
  $bpu = $null
  if ($null -ne $pv.uv) { $bpu = Convert-BakersUnit ([double]$pv.uv) ([string]$pv.uof) $unit }
  if ($null -eq $bpu -or $bpu -le 0) {
    $noBasis++
    $refused.Add(('  {0,-46} no usable unit basis (Baker''s says "{1}{2}", our unit is {3}) - left alone' -f ([string]$d.item), ([string]$pv.uv), ([string]$pv.uof), $unit))
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

  # CROSS-CHECK: cur / bpu = the quantity in Baker's pack. If our size states a QUANTITY it must match that
  # pack (within 5%). A bare per-unit basis (qty 1: lb / each / dozen / gallon) legitimately differs.
  $packQty = $cur / $bpu
  if (([math]::Abs($ourQty - 1.0) -gt 0.001) -and ([math]::Abs($packQty - $ourQty) -gt ($ourQty * 0.05))) {
    $packMismatch++
    $refused.Add(('  {0,-46} our size says {1} {2}, Baker''s pack is {3} {2} - different pack, price REFUSED' -f ([string]$d.item), [math]::Round($ourQty,2), $unit, [math]::Round($packQty,2)))
    [void]$rows.Add($row); continue
  }

  # THE FORMULA. Correct in both bases.
  $newAd = [math]::Round($bpu * $ourQty, 2)
  if ($newAd -le 0) { $noPrice++; [void]$rows.Add($row); continue }

  # FACTOR RAIL: a price change moves a few percent; a wrong product or bad unit-price parse moves by a FACTOR.
  # The pack cross-check cannot catch this on a per-lb commodity (no pack size to compare), so gate on factor.
  $oldForFactor = 0.0; [void][double]::TryParse((([string]$d.ad_price) -replace '[^0-9.]',''), [ref]$oldForFactor)
  if ($oldForFactor -gt 0) {
    $fac = $newAd / $oldForFactor
    if ($fac -ge 3.0 -or $fac -le 0.33) {
      $packMismatch++
      $refused.Add(('  {0,-46} ${1} -> ${2} is a {3}x jump (per-unit {4}/{5}) - a factor move is a wrong item or bad basis, REFUSED' -f ([string]$d.item), $oldForFactor, $newAd, [math]::Round($fac,1), [math]::Round($bpu,3), $unit))
      [void]$rows.Add($row); continue
    }
  }

  # the was-price ("Discounted From"), brought into OUR basis (it is a PACK/display price like cur)
  $newBase = $null
  if (($null -ne $pv.was) -and ([double]$pv.was -gt 0) -and ($packQty -gt 0)) {
    $newBase = [math]::Round(([double]$pv.was / $packQty) * $ourQty, 2)
  }

  $old = [string]$d.ad_price
  $oldN = 0.0; [void][double]::TryParse(($old -replace '[^0-9.]',''), [ref]$oldN)

  $row['ad_price'] = ('$' + $newAd)
  $row['regular']  = $newAd
  # THE CONTRACT (guards invariant 10): what the STORE CHARGES, in the SAME BASIS as what we publish, its own
  # assignment. Rewire ad_price to the was-price and these two stop agreeing, and guard 10 blocks the publish.
  $row['current_price'] = $newAd
  if ($null -ne $newBase -and $newBase -gt $newAd) { $row['base_price'] = $newBase }
  if (($null -ne $newBase) -and ($newAd -lt ($newBase - 0.005))) { $row['marked_down'] = $true; $down++ }
  $row['source_ad'] = 'bakersplus.com search card price/unit price (Saddlecreek, Omaha) - the price the store charges today'
  $row['as_of'] = $today
  $row['upc'] = [string]$hit.upc

  if ([math]::Abs($oldN - $newAd) -gt 0.005) {
    $changed.Add(('  {0,-46} {1,-9} -> ${2,-8} ({3} per {4}{5})' -f ([string]$d.item), $old, $newAd, [math]::Round($bpu,4), $unit, $(if($newBase){', was $' + $newBase}else{''})))
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
  foreach ($c in ($refused | Select-Object -First 15)) { Write-Output $c }
  if ($refused.Count -gt 15) { Write-Output ("  ... and " + ($refused.Count - 15) + " more") }
}

if ($WhatIf) { Write-Output ''; Write-Output 'WhatIf: nothing written'; return }
$doc.deals = $rows.ToArray()
$doc | Add-Member -NotePropertyName price_mode -NotePropertyValue 'in-store' -Force
$doc | Add-Member -NotePropertyName refreshed_today -NotePropertyValue $upd -Force
($doc | ConvertTo-Json -Depth 6) | Set-Content $regF.FullName -Encoding UTF8
Write-Output ''
Write-Output ("wrote -> " + $regF.Name)
