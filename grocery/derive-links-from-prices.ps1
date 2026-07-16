<#
  derive-links-from-prices.ps1 - THE LINK IS NOT A SEPARATE FACT. IT IS PART OF THE PRICE.

  Brad, correctly: "We cannot have our system fetch a price but not have a link. That doesn't make sense."

  He is right, and the whole wrong-link bug class comes from the architecture being built the other way:

      PRICES  come from out\regular\<store>-regular-<date>.json, fetched from a specific product.
      LINKS   come from product-urls.json, resolved LATER by SEARCHING the store for that product again.

  Two independent pipelines for one fact. They can always disagree, and they did: the board published
  "Hy Vee Almondmilk Original Unsweetened" while its link opened "Blue Diamond Almond Breeze"; storage-bags was
  crowned CHEAPEST advertising Ziploc 105ct at $0.04/each while its link opened That's Smart 12ct at $0.099
  (138% off). Nobody wrote those bugs. They are what a second pipeline does.

  The pullers ALREADY hold the identity - they fetched the price FROM a product that had an id and a URL - and
  then threw it away. So the fix is not a better search. It is to stop searching: carry the id with the price
  and DERIVE the link from the same row the board priced. A price and its link then cannot drift apart, because
  they are one record.

  This reads each store's regular file and writes product-urls entries for every board cell whose price row
  carries an identity. Derived links need no verification pass to trust - they are, by construction, the
  product the price came from - but prune-bad-links still checks them, because a claim that something cannot
  break is exactly the claim worth testing.

  Identity per store (what the row must carry):
    Hy-Vee       product_id      -> /aisles-online/p/<id>/<slug>
    Family Fare  canonical_url   -> used verbatim (NEVER construct a Freshop URL; that is how 4 dead links
                                    nearly shipped - the real shape is shopfamilyfare.com/shop/<cat>/<slug>/p/<id>)
    Walmart      item_id         -> /ip/<id>
    Sam's Club   item_id         -> /ip/<id>
    Baker's      link_url        -> used verbatim (stamped by the price pull)
    any store    link_url        -> used verbatim (the browser capture's third field)

  Read-only unless -Apply.
#>
param([switch]$Apply, [string]$OutDir = "")
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }

$STORES = @(
  @{ store = 'Hy-Vee'; glob = 'hyvee-regular-*.json' }
  @{ store = 'Family Fare'; glob = 'family-fare-regular-*.json' }
  @{ store = 'Walmart'; glob = 'walmart-regular-*.json' }
  @{ store = "Sam's Club"; glob = 'sams-regular-*.json' }
  @{ store = "Baker's"; glob = 'bakers-regular-*.json' }
  @{ store = 'Aldi'; glob = 'aldi-regular-*.json' }
  @{ store = 'Fareway'; glob = 'fareway-regular-*.json' }
)

function Get-RowUrl($store, $r) {
  # A URL the row already holds always wins - it was observed, not built.
  if ($r.link_url -and ([string]$r.link_url) -match '^https?://') { return [string]$r.link_url }
  if ($r.canonical_url -and ([string]$r.canonical_url) -match '^https?://') { return [string]$r.canonical_url }
  # Otherwise build one ONLY from an id whose URL shape is proven for that store.
  switch ($store) {
    'Hy-Vee' {
      if ($r.product_id -and ([string]$r.product_id) -match '^\d+$') {
        $slug = ((([string]$r.item).ToLower() -replace '[^a-z0-9]+', '-').Trim('-'))
        if ($slug.Length -gt 80) { $slug = $slug.Substring(0, 80).TrimEnd('-') }
        return ('https://www.hy-vee.com/aisles-online/p/' + [string]$r.product_id + '/' + $slug)
      }
    }
    'Walmart' { if ($r.item_id -and ([string]$r.item_id) -match '^\d+$') { return ('https://www.walmart.com/ip/' + [string]$r.item_id) } }
    "Sam's Club" { if ($r.item_id -and ([string]$r.item_id) -match '^\d+$') { return ('https://www.samsclub.com/ip/' + [string]$r.item_id) } }
  }
  return $null
}

$cmpF = Get-ChildItem (Join-Path $OutDir 'comparison-*.json') | Sort-Object Name -Desc | Select-Object -First 1
$cmp = (Get-Content $cmpF.FullName -Raw | ConvertFrom-Json).comparison
$puPath = Join-Path $root 'product-urls.json'
$puDoc = Get-Content $puPath -Raw | ConvertFrom-Json

# index each store's rows by name+SIZE. Never by name alone: stores sell one name in several sizes, and a
# name-keyed map silently keeps the last - the bug family this repo has now hit six times.
$rowsByStore = @{}
foreach ($sp in $STORES) {
  $f = Get-ChildItem (Join-Path $OutDir ('regular\' + $sp.glob)) -EA SilentlyContinue |
    Where-Object { $_.BaseName -match '-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Desc | Select-Object -First 1
  if (-not $f) { continue }
  $ix = @{}
  foreach ($r in @((Get-Content $f.FullName -Raw | ConvertFrom-Json).deals)) {
    $ix[(([string]$r.item).Trim() + '|' + ([string]$r.size).Trim())] = $r
  }
  $rowsByStore[$sp.store] = $ix
}

$derived = 0; $already = 0; $noIdentity = @{}; $rowMissing = 0
$changes = New-Object System.Collections.Generic.List[string]
foreach ($row in $cmp) {
  $id = [string]$row.id
  foreach ($s in $row.stores) {
    $store = [string]$s.store
    if ([double]$s.per_unit -le 0) { continue }              # not a priced tile
    if (-not $rowsByStore.ContainsKey($store)) { continue }
    $key = (([string]$s.item).Trim() + '|' + ([string]$s.size).Trim())
    $r = $rowsByStore[$store][$key]
    if (-not $r) { $rowMissing++; continue }                  # board cell not traceable to a row (ad-only)
    $url = Get-RowUrl $store $r
    if (-not $url) {
      if (-not $noIdentity.ContainsKey($store)) { $noIdentity[$store] = 0 }
      $noIdentity[$store]++
      continue
    }
    $cur = $puDoc.items.$id.$store
    if ($cur -and ([string]$cur.url) -eq $url) { $already++; continue }
    $changes.Add(('  {0,-13}{1,-24}{2}' -f $store, $id, ([string]$s.item)))
    $derived++
    if ($Apply) {
      if (-not $puDoc.items.$id) { $puDoc.items | Add-Member -NotePropertyName $id -NotePropertyValue ([pscustomobject]@{}) }
      $entry = [pscustomobject]@{
        url      = $url
        name     = [string]$r.item
        price    = [string]$r.ad_price
        size     = [string]$r.size
        verified = ((Get-Date -Format 'yyyy-MM-dd') + ' DERIVED from the price row (same record the board priced)')
      }
      $puDoc.items.$id | Add-Member -NotePropertyName $store -NotePropertyValue $entry -Force
    }
  }
}

Write-Output ("links DERIVED from the price row : " + $derived)
foreach ($c in ($changes | Select-Object -First 15)) { Write-Output $c }
if ($changes.Count -gt 15) { Write-Output ('  ... and ' + ($changes.Count - 15) + ' more') }
Write-Output ("already correct                  : " + $already)
Write-Output ("board cell has no matching row   : " + $rowMissing + "  (ad-only cells - the ad is the source; there is no product page)")
Write-Output ''
Write-Output 'priced rows carrying NO product identity (these CANNOT be linked - the puller/capture dropped it):'
foreach ($k in ($noIdentity.Keys | Sort-Object)) { Write-Output ('  ' + $k.PadRight(14) + $noIdentity[$k]) }
if ($Apply) {
  ($puDoc | ConvertTo-Json -Depth 8) | Set-Content $puPath -Encoding UTF8
  Write-Output ''
  Write-Output ("APPLIED: " + $derived + " link(s) written from the rows the board priced.")
}
else { Write-Output ''; Write-Output 'DRY RUN. Pass -Apply to write.' }
exit 0
