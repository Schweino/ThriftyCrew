<#
  import-walmart-prices.ps1

  Takes the CURRENT Walmart prices captured in the browser (out\walmart-prices-raw.json, produced by the
  __NEXT_DATA__ loop) and folds them into walmart-regular-<date>.json under the guard-10 contract:

      ad_price      what we PUBLISH
      current_price what the STORE CHARGES   (priceInfo.currentPrice.price)
      base_price    the REGULAR price        (priceInfo.wasPrice.price, present only when reduced)

  Recording current_price separately from ad_price is the whole point: if this importer - or any future edit -
  ever reaches for wasPrice instead, the two numbers stop agreeing and guard 10 fails the publish. That is the
  bug that had the board publishing Hy-Vee sirloin at $13.99/lb while Omaha #01 charged $11.99, and Baker's
  chicken breast at $2.89/lb against $2.29.

  WE KEEP OUR SIZE, NOT WALMART'S. Same discipline as Hy-Vee: the price is the number Walmart is authoritative
  about; the size is the number OUR guards have already validated. Walmart's own size strings are inconsistent
  (its unitPrice is sometimes per fl oz on a per-lb item), and trusting a store's size field cost Hy-Vee 26
  board cells and would have published sparkling water at 12x.

  IDENTITY IS BY itemId, never by name. The itemId comes straight out of the product URL we already hold.

  SAFETY: a price is only accepted when the linked product's per-unit still agrees with what our row's size
  implies. If Walmart's itemId now points at a different pack, its price would be a REAL number attached to
  the WRONG quantity - the most dangerous kind of wrong, because it is internally consistent and completely
  false. Those are refused and reported, not published.
#>
param([switch]$WhatIf)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
. (Join-Path $root 'pu-lib.ps1')
$today = (Get-Date -Format 'yyyy-MM-dd')

$rawF = Join-Path $root 'out\walmart-prices-raw.json'
if (-not (Test-Path $rawF)) { throw "missing $rawF - run the browser capture first" }
$raw = Get-Content $rawF -Raw | ConvertFrom-Json

# itemId -> {cur, was, reduced}
$price = @{}
foreach ($p in $raw.PSObject.Properties) {
  $v = $p.Value
  if (-not $v) { continue }
  if ($null -eq $v.cur) { continue }
  $price[[string]$p.Name] = $v
}
Write-Output ("Walmart prices captured from the store: " + $price.Count)

# commodity -> itemId, from the product URLs we already hold
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
$upd = 0; $down = 0; $noId = 0; $noPrice = 0; $refused = 0; $changed = New-Object System.Collections.Generic.List[string]
foreach ($d in $doc.deals) {
  $row = [ordered]@{ store='Walmart'; item=[string]$d.item; ad_price=[string]$d.ad_price; size=[string]$d.size; regular=$d.regular; source_ad=[string]$d.source_ad }
  foreach ($k in @('as_of','restored','restored_for','carried_forward')) { if ($d.$k) { $row[$k] = $d.$k } }

  $k = ([string]$d.item).ToLower().Trim()
  if (-not $idByName.ContainsKey($k)) { $noId++; [void]$rows.Add($row); continue }
  $hit = $idByName[$k]
  if (-not $price.ContainsKey([string]$hit.id)) { $noPrice++; [void]$rows.Add($row); continue }
  $pv = $price[[string]$hit.id]

  $cur = [double]$pv.cur
  if ($cur -le 0) { $noPrice++; [void]$rows.Add($row); continue }
  $unit = [string]$units[[string]$hit.cid]

  # SANITY: does this itemId's price still fit the size we hold? Compare the per-unit our row implies against
  # Walmart's own unitPrice. A factor apart means the id now points at a different pack - refuse it.
  if ($pv.unit -and ([double]$pv.unit) -gt 0 -and $unit) {
    $ourPU = Get-LinkPerUnit -size ([string]$d.size) -unit $unit -price $cur -name ([string]$d.item)
    if ($null -ne $ourPU -and [double]$ourPU -gt 0) {
      $ratio = [double]$ourPU / [double]$pv.unit
      # allow a wide band: Walmart's unitPrice basis (fl oz vs oz vs lb) does not always match ours. Only a
      # gross factor (>3x or <0.33x) is evidence of a different pack rather than a different basis.
      if (($ratio -gt 3.0) -or ($ratio -lt 0.33)) {
        # only refuse when the bases plausibly agree - otherwise this is basis noise, not a wrong product
        if (([string]$pv.unitStr) -match '(?i)/\s*(oz|fl oz|lb|ea|ct)' ) {
          $refused++
          [void]$rows.Add($row)
          continue
        }
      }
    }
  }

  $old = [string]$d.ad_price
  $row['ad_price'] = ('$' + $cur)
  $row['regular']  = $cur
  # THE CONTRACT. current_price is read from the STORE's currentPrice field; ad_price is set from it as a
  # SEPARATE assignment. Rewire ad_price to wasPrice and the two disagree, and guard 10 blocks the publish.
  $row['current_price'] = $cur
  if ($null -ne $pv.was -and ([double]$pv.was) -gt 0) { $row['base_price'] = [double]$pv.was }
  if ($pv.reduced -and ($null -ne $pv.was) -and ($cur -lt ([double]$pv.was - 0.005))) { $row['marked_down'] = $true; $down++ }
  $row['source_ad'] = 'walmart.com currentPrice (Omaha L St Supercenter) - the price the store charges today'
  $row['as_of'] = $today
  $row['item_id'] = [string]$hit.id

  $oldN = 0.0; [void][double]::TryParse(($old -replace '[^0-9.]',''), [ref]$oldN)
  if ([math]::Abs($oldN - $cur) -gt 0.005) { $changed.Add(('  {0,-44} {1,-9} -> ${2}' -f ([string]$d.item), $old, $cur)) }
  $upd++
  [void]$rows.Add($row)
}

Write-Output ("rows refreshed from the store : $upd   ($down are marked down below their regular price)")
Write-Output ("refused (itemId is a different pack than our size) : $refused")
Write-Output ("no link / no price captured   : $noId / $noPrice")
Write-Output ''
Write-Output 'prices that CHANGED (we were publishing a different number):'
foreach ($c in ($changed | Select-Object -First 25)) { Write-Output $c }
if ($changed.Count -gt 25) { Write-Output ("  ... and " + ($changed.Count - 25) + " more") }

if ($WhatIf) { Write-Output ''; Write-Output 'WhatIf: nothing written'; return }
$doc.deals = $rows.ToArray()
$doc | Add-Member -NotePropertyName price_mode -NotePropertyValue 'in-store' -Force
$doc | Add-Member -NotePropertyName refreshed_today -NotePropertyValue $upd -Force
($doc | ConvertTo-Json -Depth 6) | Set-Content $regF.FullName -Encoding UTF8
Write-Output ''
Write-Output ("wrote -> " + $regF.Name)
