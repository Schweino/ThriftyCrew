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
# -Store scopes the derivation to one store. Added 2026-07-29 after a global -Apply re-pointed ~40 FAREWAY
# links onto pack prices where the board holds per-unit (24x, 100x, 120x factor mismatches on the publish
# gate) while fixing the Sam's links it was actually run for. When only one store's prices moved, only that
# store's links should move: a link layer this wide should never be rewritten wholesale to fix one store.
param([switch]$Apply, [string]$OutDir = "", [string]$Store = "")
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
. (Join-Path $PSScriptRoot 'regular-fileset-lib.ps1')
$UNION_DAYS = Get-RegularUnionDays
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
. (Join-Path $root 'pu-lib.ps1')   # store what you audit: every entry re-prices through the same lib prune uses

$STORES = @(
  @{ store = 'Hy-Vee'; glob = 'hyvee-regular-*.json' }
  @{ store = 'Family Fare'; glob = 'family-fare-regular-*.json' }
  @{ store = 'Walmart'; glob = 'walmart-regular-*.json' }
  @{ store = "Sam's Club"; glob = 'sams-regular-*.json' }
  @{ store = "Baker's"; glob = 'bakers-regular-*.json' }
  @{ store = 'Aldi'; glob = 'aldi-regular-*.json' }
  @{ store = 'Fareway'; glob = 'fareway-regular-*.json' }
)
if ($Store) {
  $STORES = @($STORES | Where-Object { $_.store -eq $Store })
  if ($STORES.Count -eq 0) { throw ("derive-links-from-prices: unknown -Store '$Store'") }
  Write-Output ("scoped to $Store only - no other store's links will be touched")
}

# The board is NOT priced from out\regular\ alone: compare-deals also ingests out\bakers\bakers-deals-*.json,
# out\fareway\fareway-deals-*.json, and EVERY out\sams\sams-deals-*.json inside a 14-day window (Sam's is
# captured in CAPTCHA-walled partial slices, so one file never covers the catalog). When this script indexed
# only out\regular\, every cell priced from those files read as "no matching row" and its identity was thrown
# away - 1,296 fresh Sam's rows carrying sams_item_id produced zero links. That is the two-pipeline bug this
# script exists to kill, one level down. Index the SAME files the engine priced from.
#   Order = price authority: for Sam's the deals captures ARE the primary source (its regular file is a
#   29-row vestige), newest capture first; elsewhere regular leads and deal files fill gaps.
#   First writer wins per name|size key, so a fresher capture's row beats an older one.
function Get-StoreFiles([string]$store) {
  $reg = Get-ChildItem (Join-Path $OutDir ('regular\' + (($STORES | Where-Object { $_.store -eq $store }).glob))) -EA SilentlyContinue |
    Where-Object { $_.BaseName -match '-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Desc | Select-Object -First 1
  $files = @()
  switch ($store) {
    "Sam's Club" {
      foreach ($f in (Get-ChildItem (Join-Path $OutDir 'sams\sams-deals-*.json') -EA SilentlyContinue | Sort-Object Name -Descending)) {
        if ($f.BaseName -notmatch '(\d{4}-\d{2}-\d{2})$') { continue }
        # $UNION_DAYS, not 14: the engine unions Sam's captures over the SAME window, so a private copy
        # here silently refuses to derive links for cells the board is actively pricing.
        if ([math]::Abs(([datetime]$Matches[1] - (Get-Date)).TotalDays) -gt $UNION_DAYS) { continue }
        $files += $f.FullName
      }
      if ($reg) { $files += $reg.FullName }
    }
    "Baker's" {
      if ($reg) { $files += $reg.FullName }
      $f = Get-ChildItem (Join-Path $OutDir 'bakers\bakers-deals-*.json') -EA SilentlyContinue | Sort-Object Name -Desc | Select-Object -First 1
      if ($f) { $files += $f.FullName }
    }
    'Fareway' {
      if ($reg) { $files += $reg.FullName }
      $f = Get-ChildItem (Join-Path $OutDir 'fareway\fareway-deals-*.json') -EA SilentlyContinue | Sort-Object Name -Desc | Select-Object -First 1
      if ($f) { $files += $f.FullName }
    }
    'Walmart' {
      # THE SAME TWO-PIPELINE BUG AS SAM'S, one store later (2026-08-30, queue loose-end-e). Walmart's
      # board is a UNION too: compare-deals ingests every walmart-regular-*.json inside the union window
      # because the daily rotation only re-prices a couple of dozen terms, so most Walmart cells are
      # priced from an older comprehensive capture. Indexing only the newest file left 485 of Walmart's
      # priced cells reading as "board cell has no matching row" - their identity was on disk the whole
      # time and thrown away, so relink-drifted-cells could REPORT their drift forever and never repair
      # it. That is how the frozen-fruit Walmart chip sat pointing at Great Value Cherry Berry Blend
      # while the cell priced Great Value Whole Strawberries: reported daily, repairable never.
      # Newest first, because first writer wins per name|size key - a fresher capture's row beats an
      # older one, and the write-time re-pricing check still refuses any row whose per-unit disagrees
      # with the board by more than the pruner's tolerance.
      foreach ($f in (Get-ChildItem (Join-Path $OutDir 'regular\walmart-regular-*.json') -EA SilentlyContinue |
          Where-Object { $_.BaseName -match '-(\d{4}-\d{2}-\d{2})$' } | Sort-Object Name -Descending)) {
        if ($f.BaseName -notmatch '(\d{4}-\d{2}-\d{2})$') { continue }
        if ([math]::Abs(([datetime]$Matches[1] - (Get-Date)).TotalDays) -gt $UNION_DAYS) { continue }
        $files += $f.FullName
      }
    }
    default { if ($reg) { $files += $reg.FullName } }
  }
  return $files
}

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
    "Sam's Club" {
      # the quarantine-recovery rows stamp the id as sams_item_id; older rows used item_id. Accept both.
      # Bare /ip/<id> is PROVEN (2026-07-17, Brad's browser): Sam's 301s it to the canonical /ip/<slug>/<id>
      # and renders the exact product; a bogus id renders an "Uh-oh" page, so the shape cannot silently lie.
      $sid = if ($r.sams_item_id) { [string]$r.sams_item_id } elseif ($r.item_id) { [string]$r.item_id } else { '' }
      if ($sid -match '^\d+$') { return ('https://www.samsclub.com/ip/' + $sid) }
    }
  }
  return $null
}

$cmpF = Get-ChildItem (Join-Path $OutDir 'comparison-*.json') | Sort-Object Name -Desc | Select-Object -First 1
$cmp = (Read-JsonFile $cmpF.FullName).comparison
$puPath = Join-Path $root 'product-urls.json'
$puDoc = Read-JsonFile $puPath

# index each store's rows by name+SIZE. Never by name alone: stores sell one name in several sizes, and a
# name-keyed map silently keeps the last - the bug family this repo has now hit six times.
$rowsByStore = @{}
foreach ($sp in $STORES) {
  $ix = @{}
  foreach ($file in (Get-StoreFiles $sp.store)) {
    foreach ($r in @((Read-JsonFile $file).deals)) {
      $key = (([string]$r.item).Trim() + '|' + ([string]$r.size).Trim())
      # duplicate name+size = same product; keep the copy that can actually be linked. A row carrying
      # identity beats one that doesn't; among carriers the freshest file (listed first) wins.
      $have = $ix[$key]
      if (-not $have) { $ix[$key] = $r }
      elseif (-not (Get-RowUrl $sp.store $have)) { if (Get-RowUrl $sp.store $r) { $ix[$key] = $r } }
    }
  }
  if ($ix.Count) { $rowsByStore[$sp.store] = $ix }
}

$derived = 0; $already = 0; $noIdentity = @{}; $rowMissing = 0; $unwritable = 0
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
    # STORE WHAT YOU AUDIT. Before writing, re-price the entry exactly as tomorrow's pruner will. An entry the
    # pruner cannot compute a per-unit for would be written today and deleted tomorrow - churn that reads as
    # link flapping. Refuse it here and count it, so the gap is visible instead of laundered through prune.
    if (([string]$s.type) -eq 'everyday') {
      $sp = 0.0; [void][double]::TryParse((([string]$r.ad_price) -replace '[^0-9.]',''), [ref]$sp)
      $lpu = Get-LinkPerUnit -size ([string]$r.size) -unit ([string]$row.unit) -price $sp -name ([string]$r.item)
      $bpu = [double]$s.per_unit
      if ($null -eq $lpu -or ($bpu -gt 0 -and ([math]::Abs($lpu - $bpu) / $bpu -gt 0.32) -and ([math]::Abs($lpu - $bpu) -gt 0.005))) {
        $unwritable++
        continue
      }
    }
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
Write-Output ("refused at write time            : " + $unwritable + "  (the pruner could not verify these; writing them would be churn)")
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
