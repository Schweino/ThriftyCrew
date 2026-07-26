<#
  build-capture-worklist.ps1 - emit the walled-store capture worklist for the r300 batch.

  New commodities get ZERO free coverage at the walled stores (staples-500 lesson): Walmart / Sam's / Aldi /
  Fareway are captured through the owner's warm Chrome, and their pulls only ever search terms that were
  already committed - so a brand-new id is invisible to them until a human-driven capture runs. This file is
  the hand-off: per store, the ids still missing a cell, with the search term, the include patterns the
  in-browser reducer needs, and the unit the row must be able to price in.

  Written to C:\Codex\income\meal-prep\r300\board-capture-worklist.json for the MAIN session.
#>
$ErrorActionPreference = 'Stop'
$g = 'C:\Codex\income\grocery'
$ids = ((Get-Content (Join-Path $g 'out\r300\r300-ids.txt') -Raw).Trim() -split ',')
$cands = Get-Content (Join-Path $g 'out\r300\batch-r300.json') -Raw | ConvertFrom-Json
$candById = @{}; foreach ($c in $cands) { $candById[[string]$c.id] = $c }
$com = Get-Content (Join-Path $g 'commodities.json') -Raw | ConvertFrom-Json
$comById = @{}; foreach ($c in $com) { $comById[[string]$c.id] = $c }
$board = Get-Content (Join-Path $g 'out\comparison-2026-07-25.json') -Raw | ConvertFrom-Json

$WALLED = @('Walmart', "Sam's Club", 'Aldi', 'Fareway')
$NOTES = @{
  'corned-beef-brisket' = 'SEASONAL (peaks around March). If a store does not carry it today, record NOT-CARRIED - do not substitute canned corned beef or hash.'
  'dried-guajillo-chiles' = 'ZERO coverage at all three headless stores - Hispanic-aisle cello bags. Whole pods only; powder/molido is chili-powder.'
  'doubanjiang' = 'ZERO coverage at all three headless stores. Look for Lee Kum Kee Chili Bean Sauce (Toban Djan) or Pixian broad bean paste in the Asian aisle. Do NOT accept a canned chili-bean product.'
  'aji-amarillo-paste' = 'ZERO coverage at all three headless stores. Goya jar, Hispanic aisle. Do NOT accept Arroz Amarillo (yellow rice).'
  'rye-bread' = 'BLOCKED ON UNIT, not on data: 31 rye loaves are already in the FF/Hy-Vee/Bakers files but the commodity unit is each and those rows carry oz sizes, which the engine refuses to convert to a count. A Walmart capture whose size reads each/1 ct WILL price. See RUN-STATE for the unit decision Brad/main session needs to make.'
  'turkey-breast' = 'RAW whole-muscle only (bone-in, boneless roast, tenderloin). Deli/lunchmeat and frozen dinners are excluded by rule - do not capture them.'
  'sweet-soy-sauce' = 'Kecap manis / sweet soy. NOT regular soy sauce (that row already exists).'
  'wild-rice' = '100% wild rice only - long grain & wild BLENDS are excluded by rule (mostly white rice, they would undercut the real per-oz).'
  'snow-peas' = 'FRESH snow / sugar snap peas. Frozen bags are excluded by rule.'
  'diced-ham' = 'Diced/cubed tubs. Deli sliced ham is the existing deli-ham row.'
  'horseradish-sauce' = 'Creamy SAUCE. Prepared horseradish root is the existing horseradish row.'
}

$out = New-Object System.Collections.ArrayList
foreach ($store in $WALLED) {
  $items = New-Object System.Collections.ArrayList
  foreach ($id in $ids) {
    $it = $board.comparison | Where-Object { $_.id -eq $id }
    $has = $false
    if ($it) { $has = @($it.stores | Where-Object { $_.store -eq $store -and [double]$_.per_unit -gt 0 }).Count -gt 0 }
    if ($has) { continue }
    $c = $comById[$id]
    [void]$items.Add([ordered]@{
      id = $id
      label = [string]$c.label
      unit = [string]$c.unit
      search_term = [string]$candById[$id].search_term
      typical_size = [string]$candById[$id].typical_size
      include = @($c.include)                       # for the in-browser reducer's {id:"pat|pat"} map
      note = [string]$NOTES[$id]
    })
  }
  [void]$out.Add([ordered]@{ store = $store; missing = $items.Count; items = $items.ToArray() })
}

$doc = [ordered]@{
  generated = (Get-Date).ToString('yyyy-MM-dd HH:mm')
  batch = 'r300 (21 new commodities)'
  readme = 'Walled-store capture worklist. These stores are captured through the owner Chrome (Walmart/Sams = __NEXT_DATA__ fetch; Aldi/Fareway = Instacart offscreen-iframe, IN-STORE fulfillment mode REQUIRED - the Pickup/Delivery price is marked up and violates the in-store rule). A new commodity gets ZERO coverage from their scheduled pulls, so every id below needs a human-driven capture. After importing: compare-deals -> diff-board vs out\comparison-<date>.json -> any EXISTING cell that moves is a collision to fix, not noise.'
  price_mode_rule = 'in-store shelf price ONLY (audit-price-mode.ps1 enforces it for Aldi/Fareway).'
  importers = @{ walmart = 'grocery\import-walmart-batch.ps1'; sams = 'grocery\import-sams-prices.ps1 / build-sams-deals.ps1'; aldi = 'grocery\import-aldi-batch.ps1'; fareway = 'grocery\import-instacart-batch.ps1 -Store Fareway' }
  stores = $out.ToArray()
}
$target = 'C:\Codex\income\meal-prep\r300\board-capture-worklist.json'
($doc | ConvertTo-Json -Depth 8) | Set-Content $target -Encoding UTF8
$null = Get-Content $target -Raw | ConvertFrom-Json
foreach ($s in $out) { Write-Output ("  {0,-12} {1} id(s) to capture" -f $s.store, $s.missing) }
Write-Output ("wrote -> " + $target)
