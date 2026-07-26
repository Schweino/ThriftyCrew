<#
  resolve-worklist.ps1 - Core of the "product URL" automation.
  Reads the current weekly comparison + recipe board (every priced item x store chip) and the durable
  product-urls.json, then emits a per-store worklist of chips that need a URL resolved:
    - MISSING: that store has a price for the item but no stored product URL, OR
    - STALE:   the stored product's per-unit price now differs from the board's per-unit by > tolerance
               (i.e. the sale/price moved, so the link may point at the wrong product).
  This is what the weekly automation runs so it only re-resolves what changed (incremental refresh).
  Output: out\url-worklist.json  { generated, tolerance, stores{ <store>: [ {id,commodity,term,unit,price_per_unit,reason} ] } }
#>
param([double]$Tolerance = 0.15, [string]$OutDir = "")
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }

$cmpFile = (Get-ChildItem (Join-Path $OutDir 'comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1).FullName
$cmp = (Get-Content $cmpFile -Raw | ConvertFrom-Json).comparison
$ri  = @()
$riFile = Join-Path $OutDir 'recipe-board.json'
if (Test-Path $riFile) { $ri = (Get-Content $riFile -Raw | ConvertFrom-Json).comparison }
$terms = (Get-Content (Join-Path $root 'commodity-search.json') -Raw | ConvertFrom-Json).terms

# durable URLs: id -> store -> {url, price, size, name}
$purls = @{}
$pf = Join-Path $root 'product-urls.json'
if (Test-Path $pf) {
  $pd = Get-Content $pf -Raw | ConvertFrom-Json
  foreach ($p in $pd.items.PSObject.Properties) {
    $sm = @{}; foreach ($sp in $p.Value.PSObject.Properties) { if ($sp.Name -ne 'commodity') { $sm[[string]$sp.Name] = $sp.Value } }
    $purls[[string]$p.Name] = $sm
  }
}

# size -> per-unit parser (mirror of the collectors) so we can compare stored product to current board per_unit
function ParsePU([string]$size, [string]$basis, [double]$price) {
  if ($price -le 0) { return $null }
  $s = ([string]$size).ToLower(); $m = [regex]::Match($s, '([0-9]+(\.[0-9]+)?)'); $num = if ($m.Success) { [double]$m.Groups[1].Value } else { 1.0 }
  switch ($basis) {
    'oz'   { if ($s -match 'gal') { return $price/(128*$num) }; if ($s -match 'lb') { return $price/(16*$num) }; if ($s -match 'oz') { return $price/$num }; return $null }
    'lb'   { if ($s -match 'lb') { if ($num -ge 1.5) { return $price/$num } else { return $price } }; if ($s -match 'oz') { return $price/($num/16) }; return $price }
    'each' { if ($s -match 'dozen') { return $price/12 }; $c=[regex]::Match($s,'([0-9.]+)\s*(ct|ea|pk|count)'); if ($c.Success) { return $price/[double]$c.Groups[1].Value }; return $price }
    'floz' { if ($s -match 'oz') { return $price/$num }; if ($s -match 'gal') { return $price/(128*$num) }; return $null }
  }
  return $null
}

# Compute the LINKED product's per-unit in $unit from its stored {price,size}. Handles unit-price-string
# sizes ("$2.74/lb","$0.28/oz") as well as quantities ("16 oz","3 lb","12 ct","dozen"). Used for the
# 'mismatch' check: does the linked product's price actually equal the board price shown next to it?
function LinkPerUnit([string]$size, [string]$unit, [double]$price) {
  $s = ([string]$size).ToLower().Trim()
  $up = [regex]::Match($s, '\$?\s*([0-9]+(?:\.[0-9]+)?)\s*/\s*(fl\s*oz|floz|oz|lb|ea|each|ct|count)')
  if ($up.Success) {
    $v = [double]$up.Groups[1].Value; $un = ($up.Groups[2].Value -replace '\s','') -replace 'fl',''
    switch ($unit) {
      'lb'    { if ($un -eq 'lb') { return $v }; if ($un -eq 'oz') { return $v*16 } }
      'oz'    { if ($un -eq 'oz') { return $v }; if ($un -eq 'lb') { return $v/16 } }
      'floz'  { if ($un -match 'oz') { return $v }; if ($un -eq 'lb') { return $v/16 } }
      'each'  { return $price }
      'dozen' { return $price }
    }
  }
  if ($price -le 0) { return $null }
  $q = [regex]::Match($s, '([0-9]+(?:\.[0-9]+)?)\s*(fl\s*oz|floz|oz|lbs?|ct|count|ea|pk|gal|dozen|doz)')
  $n = if ($q.Success) { [double]$q.Groups[1].Value } else { $null }
  $un = if ($q.Success) { ($q.Groups[2].Value -replace '\s','') -replace 'fl','' } else { '' }
  # bare-unit size ("lb","per lb","gallon","dozen","each") = one of that unit, so per-unit = the price itself.
  # Without this, no digit -> $n stays null -> the price-match check is silently SKIPPED for by-weight/each links.
  if (-not $q.Success) { $bu = [regex]::Match($s, '\b(lbs?|gal|gallon|dozen|doz|each|ea)\b'); if ($bu.Success) { $n = 1; $un = $bu.Groups[1].Value -replace '^gallon$','gal' -replace '^doz$','dozen' } }   # anchored: unanchored 'doz'->'dozen' corrupts 'dozen' into 'dozenen'
  # multipack: "40 oz 2 pk" = 80 oz total. Multiply the weight/volume qty by the pack count.
  $pk = [regex]::Match($s, '([0-9]+)\s*(pk|pack)\b')
  if ($pk.Success -and $n -and ($un -match '^(oz|lbs?|gal)$')) { $n = $n * [double]$pk.Groups[1].Value }
  switch ($unit) {
    'lb'    { if ($un -match '^lbs?$' -and $n) { return $price/$n }; if ($un -eq 'oz' -and $n) { return $price/($n/16) }; return $null }
    'oz'    { if ($un -eq 'oz' -and $n) { return $price/$n }; if ($un -match '^lbs?$' -and $n) { return $price/(16*$n) }; if ($un -eq 'gal' -and $n) { return $price/(128*$n) }; return $null }
    'floz'  { if ($un -match 'oz' -and $n) { return $price/$n }; if ($un -eq 'gal' -and $n) { return $price/(128*$n) }; return $null }
    'each'  { if ($un -match '^(ct|count|ea|pk)$' -and $n) { return $price/$n }; if ($un -match '^(dozen|doz)$') { return $price/12 }; if ($s -match 'each' -or $s -eq '' -or $s -eq '1 ct') { return $price }; return $null }
    'dozen' { if ($un -match '^(dozen|doz)$') { return $price }; if ($un -match '^(ct|count|ea)$' -and $n) { return $price/($n/12) }; return $null }
    'gallon'{ if ($un -eq 'gal' -and $n) { return $price/$n }; return $null }
    default { return $null }
  }
  return $null
}

$work = [ordered]@{}
$seenChips = @{}   # id|store dedup: weekly + recipe occurrences of the same chip must not double-list it
function AddChip($id, $commodity, $unit, $store, $curPU, $boardItem, $srcBoard) {
  if ($seenChips.ContainsKey($id + '|' + $store)) { return }
  # Prefer the board's exact source product name as the search term - that's the item whose price is shown,
  # so searching for it links the RIGHT product (e.g. "That's Smart! Large Eggs" not just "eggs"). Falls back
  # to the generic commodity search term only when the board did not record a source item.
  $genTerm = if ($terms.PSObject.Properties.Name -contains $id) { [string]$terms.$id } else { $commodity }
  $term = if ($boardItem -and ([string]$boardItem).Trim()) { [string]$boardItem } else { $genTerm }
  $reason = $null
  if (-not ($purls.ContainsKey($id)) -or -not ($purls[$id].ContainsKey($store)) -or -not $purls[$id][$store].url) {
    $reason = 'missing'
  } else {
    $st = $purls[$id][$store]
    # Staleness = the BOARD (ad) per-unit for this item moved since the link was resolved.
    # Each occurrence compares against ITS OWN board's snapshot (board_pu = weekly, recipe_pu = recipe):
    # the two boards legitimately differ for shared ids (butter $/lb weekly vs $/oz recipe; ad-sale vs
    # everyday floor), so a single shared snapshot false-flagged every dual-board id at every store.
    $snapField = if ($srcBoard -eq 'recipe') { 'recipe_pu' } else { 'board_pu' }
    $snap = if ($st.PSObject.Properties.Name -contains $snapField) { [double]$st.$snapField } else { $null }
    if ($snap -ne $null -and $snap -gt 0 -and $curPU -gt 0) {
      $delta = [math]::Abs($snap - $curPU) / $snap
      # 'stale' is ALSO the ad-roll-off trigger: when a sale ends the board per_unit moves off the snapshot,
      # so the store's link gets re-resolved to whatever product is now cheapest for that commodity.
      if ($delta -gt $Tolerance) { $reason = 'stale(' + [math]::Round($delta*100) + '%)' }
    }
    # 'mismatch' = the LINKED product's own price does not equal the board price shown next to it
    # (the eggs bug: board is the budget-brand price, link points at a pricier brand of the same commodity).
    # Compared per-occurrence so a link that matches an equivalent unit elsewhere is not falsely flagged.
    if (-not $reason -and $curPU -gt 0) {
      # sanitize: some resolver snapshots stored display text ("$6.17"); a bare [double] cast errored
      # and silently SKIPPED the mismatch check for those rows (surfaced 2026-07-26)
      $stPrice = 0.0; [void][double]::TryParse((([string]$st.price) -replace '[^0-9.]',''), [ref]$stPrice)
      $lpu = LinkPerUnit ([string]$st.size) $unit $stPrice
      if ($lpu -ne $null) {
        $md = [math]::Abs($lpu - $curPU) / $curPU
        if ($md -gt $Tolerance) { $reason = 'mismatch(' + [math]::Round($md*100) + '%)' }
      }
    }
    # No board_pu snapshot yet (link predates stamping): treat as current, not stale.
  }
  if ($reason) {
    $seenChips[$id + '|' + $store] = $true
    if (-not $work.Contains($store)) { $work[$store] = @() }
    $work[$store] += [pscustomobject]@{ id=$id; commodity=$commodity; term=$term; board_item=([string]$boardItem); unit=$unit; price_per_unit=$curPU; reason=$reason }
  }
}

foreach ($it in $cmp) {
  foreach ($s in $it.stores) { AddChip ([string]$it.id) ([string]$it.commodity) ([string]$it.unit) ([string]$s.store) ([double]$s.per_unit) ([string]$s.item) 'weekly' }
}
foreach ($it in $ri) {
  foreach ($s in $it.stores) { AddChip ([string]$it.id) ([string]$it.commodity) ([string]$it.unit) ([string]$s.store) ([double]$s.per_unit) ([string]$s.item) 'recipe' }
}

$out = [ordered]@{ generated = (Get-Date -Format 'yyyy-MM-dd'); tolerance = $Tolerance; stores = $work }
$out | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $OutDir 'url-worklist.json') -Encoding UTF8
$total = 0
Write-Output "URL worklist (chips needing resolution):"
foreach ($k in $work.Keys) { $n = @($work[$k]).Count; $total += $n; Write-Output ("  {0,-14} {1}" -f $k, $n) }
Write-Output ("  TOTAL          " + $total)