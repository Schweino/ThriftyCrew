<#
  prime-batch-headless.ps1 - price a specific BATCH of newly-registered commodities at the two HEADLESS stores
  (Family Fare via Freshop, Hy-Vee via its search API) by querying ONLY that batch's search terms, then
  ADD-MERGING the returned priced products into today's regular files. compare-deals then matches them to
  commodities with the same include/exclude rules it uses for every other cell - this primer NEVER decides a
  match, it only makes sure the priced products EXIST in the store files so a match is possible.

  WHY targeted, not a full pull: the full Family Fare / Hy-Vee pulls iterate all ~380 commodity terms, and the
  shared IP gets rate-limited by a burst that size into near-emptiness - that is exactly why a fresh batch's 48
  items came back blank. Querying only the batch's ~50 terms, paced, with a cooldown on a throttle streak, stays
  under the limit. The merge is ADD-ONLY (dedup by item|size): it can never remove or overwrite an existing row,
  so a throttled term just contributes nothing and the last good data stays put.

  WHAT IT DELIBERATELY DOES NOT DO: it does not write product-urls links. A raw search result is not a vetted
  board match - resolve-hyvee-links / the browser board-match resolvers do that AFTER compare-deals knows which
  product actually won the cell. The primer only gets a fresh price onto the board; the link is resolved next.

  Usage:
    .\prime-batch-headless.ps1 -Ids (Get-Content out\staples500\batch1-ids.txt) -Store both
    .\prime-batch-headless.ps1 -Ids beef-stew,chili-beans -Store ff -WhatIf
  After a real run: compare-deals.ps1 -> diff-board.ps1 (did any EXISTING cell move?) -> audit-food-category ->
  build-vet-sheet -Ids <batch>.
#>
param([string[]]$Ids, [ValidateSet('ff','hyvee','both')][string]$Store = 'both', [switch]$WhatIf, [string]$OutDir = '')
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
$regDir = Join-Path $OutDir 'regular'
if (-not (Test-Path $regDir)) { New-Item -ItemType Directory -Path $regDir -Force | Out-Null }
$todayS = (Get-Date).ToString('yyyy-MM-dd')
$UA = @{ 'User-Agent' = 'Mozilla/5.0' }

$terms = (Get-Content (Join-Path $root 'commodity-search.json') -Raw | ConvertFrom-Json).terms
$Ids = @($Ids | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
if ($Ids.Count -eq 0) { throw 'no -Ids supplied' }
Write-Output ("priming " + $Ids.Count + " commodities at: " + $Store)

# RULE FILTER - the primer only contributes ON-TARGET candidates. A raw search dump (every result for a term)
# pollutes the SHARED store files: a fuzzy search returns off-target products (a raspberry vinaigrette under a
# marinade query, a store-brand milk under a soup query), those land in the file, and compare-deals then matches
# them to a DIFFERENT commodity and silently re-prices an existing board cell. Filtering each term's results to
# the include/exclude of the commodity we searched FOR keeps the primer surgical - it can only affect its own
# items. (Same include/exclude the daily pull + compare-deals use, so a kept product is one the board would match
# anyway; the diff still catches any residual on-target collision.)
$rules = @{}
foreach ($c in (Get-Content (Join-Path $root 'commodities.json') -Raw | ConvertFrom-Json)) {
  $rules[[string]$c.id] = [pscustomobject]@{ inc = @($c.include); exc = @($c.exclude) }
}
function Test-Match([string]$name, [string]$id) {
  $r = $rules[$id]; if (-not $r) { return $false }
  $ok = $false; foreach ($p in $r.inc) { if ($p -and $name -imatch $p) { $ok = $true; break } }
  if (-not $ok) { return $false }
  foreach ($p in $r.exc) { if ($p -and $name -imatch $p) { return $false } }
  return $true
}

# ---- ADD-ONLY merge into today's regular file (never removes/overwrites an existing row) ----
function Merge-Rows([string]$fileFor, $newRows, [string]$store) {
  $prev = Get-ChildItem (Join-Path $regDir ($fileFor + '-*.json')) -EA SilentlyContinue |
    Where-Object { $_.BaseName -match ('^' + [regex]::Escape($fileFor) + '-\d{4}-\d{2}-\d{2}$') } |
    Sort-Object Name -Descending | Select-Object -First 1
  $doc = $null
  $merged = New-Object System.Collections.ArrayList
  $seen = @{}
  if ($prev) {
    $doc = Get-Content $prev.FullName -Raw | ConvertFrom-Json
    foreach ($r in @($doc.deals)) { [void]$merged.Add($r); $seen[(([string]$r.item) + '|' + ([string]$r.size)).ToLower()] = $true }
  }
  $added = 0
  foreach ($r in @($newRows)) {
    $k = (([string]$r.item) + '|' + ([string]$r.size)).ToLower()
    if ($seen.ContainsKey($k)) { continue }
    $seen[$k] = $true; [void]$merged.Add($r); $added++
  }
  if ($WhatIf) { return $added }
  $outFile = Join-Path $regDir ($fileFor + "-$todayS.json")
  if ($doc) {
    $doc.deals = $merged.ToArray()
    if ($doc.PSObject.Properties['deal_count']) { $doc.deal_count = $merged.Count } else { $doc | Add-Member -NotePropertyName deal_count -NotePropertyValue $merged.Count -Force }
    $doc | Add-Member -NotePropertyName primed_batch -NotePropertyValue $todayS -Force
    ($doc | ConvertTo-Json -Depth 6) | Set-Content $outFile -Encoding UTF8
  } else {
    ([ordered]@{ store = $store; week_of = $todayS; price_type = 'everyday'; price_mode = 'in-store'; deal_count = $merged.Count; primed_batch = $todayS; deals = $merged.ToArray() } | ConvertTo-Json -Depth 6) | Set-Content $outFile -Encoding UTF8
  }
  return $added
}

# =================================  FAMILY FARE (Freshop)  =================================
if ($Store -eq 'ff' -or $Store -eq 'both') {
  $ak = 'family_fare'; $sid = '6401'; $b = 'https://api.freshop.ncrcloud.com/1'
  $tok = $null
  foreach ($tu in @("https://api.freshop.ncrcloud.com/2/sessions?app_key=$ak", "$b/sessions?app_key=$ak")) {
    try { $ts = Invoke-RestMethod -Uri $tu -Method Post -Headers $UA -TimeoutSec 20; if ($ts.token) { $tok = [string]$ts.token; break } } catch {}
  }
  function FF-Query($term) {
    for ($a = 1; $a -le 3; $a++) {
      try {
        $u = "$b/products?app_key=$ak&store_id=$sid&q=" + [uri]::EscapeDataString($term) + "&limit=25&fields=name,size,price,base_price,unit_price"
        return @((Invoke-RestMethod -Uri $u -Headers $UA -TimeoutSec 25).items)
      } catch { Start-Sleep -Seconds (2 * $a) }
    }
    return @()
  }
  $ffRows = New-Object System.Collections.ArrayList
  function FF-Ingest($items, $rows, $id) {
    foreach ($it in @($items)) {
      if (-not $it.name) { continue }
      if (-not (Test-Match ([string]$it.name) $id)) { continue }
      $cur = 0.0; [void][double]::TryParse((([string]$it.price) -replace '[^0-9.]', ''), [ref]$cur)
      $base = 0.0; [void][double]::TryParse((([string]$it.base_price) -replace '[^0-9.]', ''), [ref]$base)
      $val = $cur; if ($val -le 0) { $val = $base }; if ($val -le 0) { continue }
      $row = [ordered]@{ store = 'Family Fare'; item = [string]$it.name; ad_price = ('$' + $val); size = [string]$it.size; regular = $val; current_price = $cur; source_ad = 'everyday shelf price (batch primer)'; as_of = $todayS }
      if ($base -gt 0) { $row['base_price'] = $base }
      if ($base -gt 0 -and $val -lt ($base - 0.005)) { $row['marked_down'] = $true }
      [void]$rows.Add($row)
    }
  }
  $empty = New-Object System.Collections.Generic.List[string]; $streak = 0
  foreach ($id in $Ids) {
    $term = [string]$terms.$id
    if (-not $term) { Write-Warning "FF: no search term for $id"; continue }
    $items = FF-Query $term; Start-Sleep -Milliseconds 500
    if (@($items).Count -eq 0) { $empty.Add($id); $streak++; if ($streak -ge 6) { Write-Output 'FF: throttle streak - cooling 60s'; Start-Sleep -Seconds 60; $streak = 0 } }
    else { $streak = 0; FF-Ingest $items $ffRows $id; Write-Output ("  ff  {0,-26} {1} products" -f $id, @($items).Count) }
  }
  if ($empty.Count) {
    Write-Output ("FF: recovery pass for " + $empty.Count + " empty term(s)..."); Start-Sleep -Seconds 20
    foreach ($id in $empty) { $term = [string]$terms.$id; $items = FF-Query $term; Start-Sleep -Milliseconds 600; if (@($items).Count) { FF-Ingest $items $ffRows $id; Write-Output ("  ff  {0,-26} {1} products (recovered)" -f $id, @($items).Count) } }
  }
  $ffAdded = Merge-Rows 'family-fare-regular' $ffRows 'Family Fare'
  Write-Output ("Family Fare: " + $ffRows.Count + " product rows fetched, " + $ffAdded + " new after add-merge")
}

# =================================  HY-VEE (search API)  =================================
if ($Store -eq 'hyvee' -or $Store -eq 'both') {
  $EP = 'https://www.hy-vee.com/aisles-online/api/search/products'
  $HUA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148 Safari/537.36'
  $HStore = 1465
  function HV-Search($term) {
    $h = @{ 'content-type' = 'application/json'; 'User-Agent' = $HUA; 'x-hy-vee-correlation-id' = [guid]::NewGuid().ToString() }
    # pageSize 90, was 40 (F1(c), 2026-08-01). Cheap - one request either way - but MEASURED to be a small
    # lever, not the one the plan assumed: Hy-Vee's own "baking soda" search returns 10 products in TOTAL,
    # so the extra 50 slots only do anything for genuinely broad terms. Taken because it costs nothing, not
    # because it fixes the depth problem; the depth problem is discover-hyvee.ps1.
    $body = @{ pageNumber = 1; pageSize = 90; searchFilters = @(); searchTerm = $term; sortDirection = 'RELEVANCE'; storeId = $HStore; pageViewId = [guid]::NewGuid().ToString() } | ConvertTo-Json -Compress
    for ($a = 1; $a -le 3; $a++) { try { return @((Invoke-RestMethod -Uri $EP -Method Post -Headers $h -Body $body -TimeoutSec 25).results) } catch { Start-Sleep -Seconds (2 * $a) } }
    return @()
  }
  $hvRows = New-Object System.Collections.ArrayList
  foreach ($id in $Ids) {
    $term = [string]$terms.$id
    if (-not $term) { Write-Warning "Hy-Vee: no search term for $id"; continue }
    $res = HV-Search $term; Start-Sleep -Milliseconds 400
    $n = 0
    foreach ($x in @($res)) {
      if (-not $x.id) { continue }
      $price = 0.0; try { $price = [double]$x.pricing.tagPriceValue } catch {}
      if ($price -le 0) { continue }
      $desc = [string]$x.description; if (-not $desc) { continue }
      if (-not (Test-Match $desc $id)) { continue }
      $size = [string]$x.unitOfMeasure
      $base = 0.0; try { if ($x.pricing.regularPriceValue) { $base = [double]$x.pricing.regularPriceValue } } catch {}
      $slug = (((([string]$desc).ToLower()) -replace '[^a-z0-9 ]', ' ') -replace '\s+', ' ').Trim() -replace ' ', '-'
      if ($slug.Length -gt 80) { $slug = $slug.Substring(0, 80).TrimEnd('-') }
      $url = 'https://www.hy-vee.com/aisles-online/p/' + [string]$x.id + '/' + $slug
      $row = [ordered]@{ store = 'Hy-Vee'; item = $desc; ad_price = ('$' + $price); size = $size; regular = $price; current_price = $price; source_ad = 'Aisles Online search current price (batch primer, storeId 1465, Omaha #01)'; as_of = $todayS; product_id = [int]$x.id; link_url = $url }
      if ($base -gt 0) { $row['base_price'] = $base; if ($price -lt ($base - 0.005)) { $row['marked_down'] = $true } }
      [void]$hvRows.Add($row); $n++
    }
    if ($n) { Write-Output ("  hv  {0,-26} {1} priced products" -f $id, $n) } else { Write-Output ("  hv  {0,-26} (none priced)" -f $id) }
  }
  $hvAdded = Merge-Rows 'hyvee-regular' $hvRows 'Hy-Vee'
  Write-Output ("Hy-Vee: " + $hvRows.Count + " product rows fetched, " + $hvAdded + " new after add-merge")
}

if ($WhatIf) { Write-Output ''; Write-Output 'WhatIf: no regular files written' }
else { Write-Output ''; Write-Output 'NEXT: compare-deals.ps1 -> diff-board.ps1 -> audit-food-category.ps1 -> build-vet-sheet.ps1 -Ids <batch>' }
