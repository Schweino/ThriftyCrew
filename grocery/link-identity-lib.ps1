# link-identity-lib.ps1 - THE per-store rule for turning a priced capture row into its product URL.
#
# ONE copy, dot-sourced by compare-deals.ps1 (which stamps the URL on every tile, so price and link are one record)
# and derive-links-from-prices.ps1 (the bridge it replaces). design/PLAN-link-rides-with-price-2026-09-27.md L1.
# Brad, 2026-09-27: "You cant have a price but no link to the item - that doesnt make any sense, because then where
# did the price come from?"
#
# Fixtures: test-link-identity-lib.ps1 (run by run-gates; 11 cases, MUST FIRE / MUST NOT FIRE / CLEAN TWIN).
#
# Pure functions only: a lifted $script: constant does not travel (rules:grocery.md gr-04).
#
# SCOPE OF A CLEAN REPORT: not a detector. Get-TcRowUrl returns $null when the row names no proven identity; the
# caller decides what that means (Get-TcLinkSource names it).

# ---- SAM'S ALPHANUMERIC /ip/<id> IS PROVEN BY A FILE (2026-09-22, plan-2026-09-22-10 bec597) ----------------------
# The numeric /ip/<id> shape was proven in Brad's browser on 2026-07-17; the alphanumeric one is proven only by
# out\sams\sams-url-shape-<date>.json, written by the Sam's browser pass. Only the NEWEST file counts, and only a
# clean 3 of 3: 2 of 3, a wall, a parse failure or no file leave the alphanumeric id refused.
function Test-SamsAlnumShapeProven([string]$Dir) {
  $f = Get-ChildItem (Join-Path $Dir 'sams\sams-url-shape-*.json') -ErrorAction SilentlyContinue |
    Where-Object { $_.BaseName -match '^sams-url-shape-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending | Select-Object -First 1
  if (-not $f) { return @{ proven = $false; why = 'no sams-url-shape file' } }
  $d = $null
  try { $d = (Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return @{ proven = $false; why = ($f.Name + ' does not parse') } }
  $cases = @($d.cases | Where-Object { $_ })
  $allMatch = ($cases.Count -eq 3) -and (@($cases | Where-Object { $_.match -eq $true -and $_.blocked -ne $true }).Count -eq 3)
  $ok = ([string]$d.verdict -eq 'proven') -and ([int]$d.proven -eq 3) -and ([int]$d.checked -eq 3) -and $allMatch
  $why = ($f.Name + ': verdict ' + [string]$d.verdict + ', ' + [string]$d.proven + ' of ' + [string]$d.checked)
  return @{ proven = $ok; why = $why }
}

function Get-TcRowUrl($Store, $Row, [bool]$SamsAlnumProven = $false) {
  if ($null -eq $Row) { return $null }
  # A URL the row already holds always wins - it was observed, not built.
  if ($Row.link_url -and ([string]$Row.link_url) -match '^https?://') { return [string]$Row.link_url }
  if ($Row.canonical_url -and ([string]$Row.canonical_url) -match '^https?://') { return [string]$Row.canonical_url }
  # Otherwise build one ONLY from an id whose URL shape is proven for that store.
  switch ([string]$Store) {
    'Hy-Vee' {
      if ($Row.product_id -and ([string]$Row.product_id) -match '^\d+$') {
        $slug = ((([string]$Row.item).ToLower() -replace '[^a-z0-9]+', '-').Trim('-'))
        if ($slug.Length -gt 80) { $slug = $slug.Substring(0, 80).TrimEnd('-') }
        return ('https://www.hy-vee.com/aisles-online/p/' + [string]$Row.product_id + '/' + $slug)
      }
    }
    'Walmart' { if ($Row.item_id -and ([string]$Row.item_id) -match '^\d+$') { return ('https://www.walmart.com/ip/' + [string]$Row.item_id) } }
    "Sam's Club" {
      # quarantine-recovery rows stamp sams_item_id; older rows used item_id. Bare numeric /ip/<id> is PROVEN
      # (2026-07-17): Sam's 301s it to the canonical page and a bogus id renders "Uh-oh", so it cannot silently lie.
      $sid = if ($Row.sams_item_id) { [string]$Row.sams_item_id } elseif ($Row.item_id) { [string]$Row.item_id } else { '' }
      if ($sid -match '^\d+$') { return ('https://www.samsclub.com/ip/' + $sid) }
      if ($SamsAlnumProven -and $sid -match '^[A-Za-z0-9]{6,20}$') { return ('https://www.samsclub.com/ip/' + $sid) }
    }
    # Every other store: an observed URL (above) or nothing. Family Fare's canonical_url is taken verbatim and
    # never constructed; Baker's, Aldi and Fareway carry link_url.
    default { }
  }
  return $null
}

# link_source, keyed on the row's SOURCE, never on type=sale (memory grocery-links-consistency: a storefront
# sale row has a product page; a flyer line does not):
#   row   the priced capture row names its product, and $Url is that product
#   none  a storefront capture row with no identity: a capture defect
#   ad    no capture row at all (a flyer or ad-feed line). Under Brad's D1 ruling (2026-09-27) this is NOT a
#         resting state: "its the systems job to find the link". It is labelled so it can be counted and resolved.
function Get-TcLinkSource([string]$Url, [bool]$HasCaptureRow) {
  if ($Url) { return 'row' }
  if ($HasCaptureRow) { return 'none' }
  return 'ad'
}

# A PRICED TILE WITH NO LINK IS AN OWED RE-READ (PLAN-link-rides-with-price L5). The commodities whose tile at $Store is
# link_source=none on the newest board: a storefront row priced it but carried no URL, which on 2026-09-27 was every
# Family Fare row captured before 2026-09-06 and every Aldi row before its href capture. Get-CaptureWorklist leads with
# their terms, so a fresh read (which does carry the URL) replaces the row instead of waiting up to 90 days for the
# rotation. EMPTIES ITSELF: once the re-read lands, the next board stamps that tile 'row' and the id leaves this list;
# nothing here is ever edited by hand. A board with no link_source at all (built before L1) is BLIND and owes nothing.
# Cost: one parse of the newest comparison file per worklist call.
function Get-TcLinkOwed {
  param([string]$OutDir, [Parameter(Mandatory)][string]$Store)
  $none = [pscustomobject]@{ Ids = @(); Blind = $false; Why = '' }
  $f = Get-ChildItem (Join-Path $OutDir 'comparison-*.json') -ErrorAction SilentlyContinue |
    Where-Object { $_.BaseName -match '^comparison-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending | Select-Object -First 1
  if (-not $f) { return [pscustomobject]@{ Ids = @(); Blind = $true; Why = 'no comparison board in ' + $OutDir } }
  $doc = $null
  try { $doc = ConvertFrom-Json ([IO.File]::ReadAllText($f.FullName)) } catch { $doc = $null }
  if ($null -eq $doc) { return [pscustomobject]@{ Ids = @(); Blind = $true; Why = ($f.Name + ' is unparseable, so the tiles owed a link are unknown') } }
  $ids = New-Object System.Collections.ArrayList
  $tagged = 0
  foreach ($c in @($doc.comparison)) {
    foreach ($s in @($c.stores)) {
      if ($null -eq $s -or -not $s.PSObject.Properties['link_source']) { continue }
      $tagged++
      if ([string]$s.store -ne $Store -or [string]$s.link_source -ne 'none') { continue }
      if ($null -eq $s.per_unit) { continue }
      if (-not ($ids -contains [string]$c.id)) { [void]$ids.Add([string]$c.id) }
    }
  }
  if ($tagged -eq 0) { return [pscustomobject]@{ Ids = @(); Blind = $true; Why = ($f.Name + ' carries no link_source (built before the tile carried its link)') } }
  if ($ids.Count -eq 0) { return $none }
  return [pscustomobject]@{ Ids = $ids.ToArray(); Blind = $false; Why = '' }
}

# The terms Get-CaptureWorklist leads with for tiles owed a link: after the price-flag verifications ($SkipIds), capped
# at HALF the room left ($Room is what remains after the verifications), never all of it: an ended sale still on the
# board is a wrong price and a missing link is not, so sale expiries keep at least half. Uncapped, 2026-09-27's board
# gave link terms 28 of Family Fare's 37 lead slots and 35 of Aldi's. First plausible value, 1 variant tried.
# Lives here, not in capture-policy-lib, which is over its file-size mark.
function Select-TcLinkOwedTerms {
  param([Parameter(Mandatory)][string]$Store, [string]$OutDir, $All, $SkipIds, [int]$Room)
  $out = New-Object System.Collections.Generic.List[object]
  $lo = Get-TcLinkOwed -OutDir $OutDir -Store $Store
  $cap = [math]::Floor([math]::Max(0, $Room) / 2)
  foreach ($lid in @($lo.Ids)) {
    if (@($SkipIds) -contains [string]$lid) { continue }
    $hits = @($All | Where-Object { [string]$_.id -eq [string]$lid })
    if ($hits.Count -eq 0 -or ($out.Count + $hits.Count) -gt $cap) { continue }
    foreach ($hit in $hits) { $out.Add($hit) }
  }
  return ,$out.ToArray()
}

# THE LINK A READER IS SHOWN for a store tile (PLAN-link-rides-with-price L2): the tile's own link when it carries one
# proven from the priced row, otherwise $Fallback (product-urls.json until L6 retires it). One rule for the page and the feed.
function Get-TcTileLink($Tile, [string]$Fallback = '') {
  if ($null -ne $Tile -and @('row', 'flyer') -contains [string]$Tile.link_source -and ([string]$Tile.link) -match '^https?://') { return [string]$Tile.link }
  return $Fallback
}
