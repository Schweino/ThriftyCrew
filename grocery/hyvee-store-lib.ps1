<#
  hyvee-store-lib.ps1 - WHICH Hy-Vee the board speaks for, in one place.

  BRAD'S RULING (2026-08-21): "we should just switch to Omaha 2 for hyvee pricing. It has less
  'variables' and more 'straight forward' with pricing with regular vs ads."

  WHY THIS FILE EXISTS. Hy-Vee prices PER STORE, and the identity was hard-coded in six production
  files - the puller, discovery, the batch primer, the link refresher, the field probe and the ad
  feed - while stores.json, the registry that is supposed to BE the store list, did not carry it at
  all. Switching stores by editing the puller would have left five callers still pulling Omaha #01 and
  writing rows labelled Omaha #01 into a board that claimed to be Omaha #02, with nothing able to
  notice: every row would be real, every price would reproduce, and the board would be a blend of two
  stores. That is the shape `two copies of a rule` describes, with five copies.

  THE TWO IDENTIFIERS ARE NOT INTERCHANGEABLE, AND THIS IS THE TRAP THAT COST THE MOST TIME:

      storeId      selects storeProducts  -> price, basePrice, onSale
      locationIds  selects retailItems    -> tagPrice, ecommerceTagPrice, memberTagPrice

  They are independent request variables. Measured 2026-08-21 on cherries (productId 8641):

      storeId 1466 + loc adcb2ae1(#01)   sp.price 6.99   tagPrice 5.99   <- MISMATCHED, reads as a defect
      storeId 1466 + loc 09e8f4f0(#02)   sp.price 6.99   tagPrice 6.99   <- matched, agrees
      storeId 1465 + loc adcb2ae1(#01)   sp.price 5.99   tagPrice 5.99   <- matched, agrees

  A mismatched pair grades one store's price against another store's shelf tag and manufactures
  disagreements out of nothing: it reported 11 of 21 rows "wrong" at Omaha #02 when the true number,
  once the location matched the store, was ZERO. Any code that moves one of these MUST move both,
  which is why they are a single object here and not two settings.

  WHAT WAS ACTUALLY WRONG AT OMAHA #01, and it is the reason this ruling has evidence behind it:
  with the pair correctly matched, storeProducts.price still disagreed with that store's own shelf tag
  on 2 of 22 sampled products - both Morton & Bassett spices, published at $5.31 and $5.81 against a
  $9.99 tag. Brad's own Omaha #01 product page showed $9.99. Those two cells published a number no
  shopper could pay. At Omaha #02 the same sample disagreed on 0 of 21.

  ADS ARE STORE-SPECIFIC TOO. pull-grocery-ads.ps1 keys the Hy-Vee flyer on a Flipp collection id that
  happens to read '1465'. Whether Flipp's collection id equals Hy-Vee's storeId is an ASSUMPTION, not
  a fact, so it is recorded here as unverified and pull-grocery-ads is NOT switched off it until
  somebody proves the mapping. Guessing it would silently pair Omaha #02 shelf prices with Omaha #01's
  weekly ad, which is the exact blend this file exists to prevent.

  Usage:
      . hyvee-store-lib.ps1
      $s = Get-HyVeeStore          # -> @{ store_id; location_id; label; ... }
      $s.store_id                  # 1466
      $s.location_id               # '09e8f4f0-...'
      $s.label                     # 'Omaha #02'
#>

# The identity lives in stores.json (the canonical registry) when it is there, and falls back to these
# literals when it is not, so this library cannot become the SECOND home for the same fact. The fallback
# is what the registry is seeded with, never a competing answer - Test-HyVeeStoreDrift below fails loudly
# if the two ever disagree rather than silently preferring one.
$script:HyVeeStoreFallback = [ordered]@{
  store_id    = 1466
  location_id = '09e8f4f0-e614-4b86-9285-c9c3dbff0d85'
  label       = 'Omaha #02'
  # Kept so a future switch has the prior identity written down rather than reconstructed from git.
  previous    = [ordered]@{ store_id = 1465; location_id = 'adcb2ae1-f440-4512-bfe8-9624832c72a9'; label = 'Omaha #01'; retired = '2026-08-21' }
  # UNVERIFIED. See the header. Do not wire this into pull-grocery-ads without proving the mapping.
  ads_collection_unverified = '1465'
}

function Get-HyVeeStore {
  <#
    .SYNOPSIS The Hy-Vee store the board speaks for: storeId AND the matching pickup locationId.
    .DESCRIPTION Reads stores.json when it carries hyvee_store_identity, else the seeded fallback.
                 Always returns BOTH identifiers together - see the header for why they cannot be
                 moved independently.
  #>
  param([string]$Root = '')
  if (-not $Root) { $Root = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\grocery' } }
  $f = Join-Path $Root 'stores.json'
  if (Test-Path $f) {
    try {
      $doc = ConvertFrom-Json ([IO.File]::ReadAllText($f))
      $hv = @($doc.stores) | Where-Object { [string]$_.name -eq 'Hy-Vee' } | Select-Object -First 1
      if ($hv -and $hv.store_identity -and $hv.store_identity.store_id) {
        return [ordered]@{
          store_id    = [int]$hv.store_identity.store_id
          location_id = [string]$hv.store_identity.location_id
          label       = [string]$hv.store_identity.label
        }
      }
    } catch { }
  }
  return [ordered]@{
    store_id    = [int]$script:HyVeeStoreFallback.store_id
    location_id = [string]$script:HyVeeStoreFallback.location_id
    label       = [string]$script:HyVeeStoreFallback.label
  }
}

function Get-HyVeeSourceLabel {
  <#
    .SYNOPSIS The source_ad string, built from the identity rather than typed beside it.
    .DESCRIPTION Every row records which store it came from. Hand-typing "storeId 1465, Omaha #01" into
                 each writer is how rows kept claiming a store the puller had stopped querying - the
                 label is derived here so it cannot drift from the request that produced the price.
  #>
  param([string]$Root = '', [string]$Kind = 'current shelf price')
  $s = Get-HyVeeStore -Root $Root
  return ("Aisles Online $Kind (storeId $($s.store_id), $($s.label))")
}

function Test-HyVeeStoreDrift {
  <#
    .SYNOPSIS Do the registry and the seeded fallback still name the same store?
    .DESCRIPTION Returns $null when they agree (or the registry is silent), else a description of the
                 disagreement. A registry that quietly diverges from the library everything dot-sources
                 is worse than having only one of them.
  #>
  param([string]$Root = '')
  if (-not $Root) { $Root = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\grocery' } }
  $f = Join-Path $Root 'stores.json'
  if (-not (Test-Path $f)) { return $null }
  try { $doc = ConvertFrom-Json ([IO.File]::ReadAllText($f)) } catch { return "stores.json is unreadable: $($_.Exception.Message)" }
  $hv = @($doc.stores) | Where-Object { [string]$_.name -eq 'Hy-Vee' } | Select-Object -First 1
  if (-not $hv -or -not $hv.store_identity) { return $null }   # registry silent is fine; the fallback answers
  $bad = @()
  if ([int]$hv.store_identity.store_id -ne [int]$script:HyVeeStoreFallback.store_id) {
    $bad += "store_id: registry says $($hv.store_identity.store_id), hyvee-store-lib says $($script:HyVeeStoreFallback.store_id)"
  }
  if ([string]$hv.store_identity.location_id -ne [string]$script:HyVeeStoreFallback.location_id) {
    $bad += "location_id: registry says '$($hv.store_identity.location_id)', hyvee-store-lib says '$($script:HyVeeStoreFallback.location_id)'"
  }
  if (-not $bad.Count) { return $null }
  return ("Hy-Vee store identity DISAGREES between stores.json and hyvee-store-lib.ps1 - " + ($bad -join '; ') +
          ". These select the price and the shelf tag respectively; a board built from a split identity blends two stores.")
}
