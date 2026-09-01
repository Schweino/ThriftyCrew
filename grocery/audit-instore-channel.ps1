<#
  audit-instore-channel.ps1 - CHANNEL DOUBT on a published cell, made visible instead of silent.

  WHY. The board is supposed to publish IN-STORE shelf prices. Test-InStore refuses a row whose
  fulfillment says the item ships from a fulfillment centre or a marketplace seller, and it deliberately
  PASSES a row whose fulfillment field is absent, because most captures predate that field and removing
  that valve empties the Walmart column. That valve is correct and this audit does not touch it. What the
  valve cannot see is two shapes where absence is not innocent:

    (a) BLANK INSIDE A FIELD-BEARING CAPTURE. walmart-regular-2026-08-31.json populates fulfillment on
        11,603 of its 11,694 rows. A row in THAT file with an empty fulfillment is not a pre-field row -
        it is a row the puller could not attribute, and over half of them are "(N pack)" online bundles.
        Measured 2026-09-01: 13 such rows were winning Walmart board cells.

    (b) A PRE-FIELD ROW OUTLIVING ITS OWN REFUSAL. The engine unions 90 days of captures. A ship-only
        product whose FRESH row is correctly refused as FC can still price the board through an older,
        pre-field row of the SAME item id, which passes because the field is absent. Founding pair:
        red-curry-paste published $23.40 from a carried 07-30 row while the 08-31 row for item 754814279
        read $19.32 FC and was refused.

  WHAT IT DOES NOT DO: drop anything. El Guapo bay leaves and Great Value apple cider vinegar are almost
  certainly real Omaha shelf items, and an automatic refusal would overstate those cells in the other
  direction. The only instrument that can answer is a shelf-badge check by the browser agent, so every
  doubted cell is queued into out\research-worklist.json for it. That check is not theoretical: run on
  2026-09-01 it cleared Shirakiku white miso (Pickup today, price stands) and condemned the Nalley
  "(4 pack)" beef stew (out of stock in both pack sizes, no pickup, no delivery), which had been holding
  the beef-stew crown at 5.2 c/oz against a true cheapest of 15.4.

  HOW A ROW IS ATTRIBUTED, and why NOT by newest. The first draft matched the board item to the NEWEST
  capture row carrying that name, and it missed the founding case outright: all five Walmart captures
  carry "Thai Kitchen Red Curry Paste, 35.0 oz Cup" under item 754814279, so the newest row is the 08-31
  one at $19.32 FC - clean-looking, correctly refused, and not the row on the board. The board publishes
  $23.40, which is the PRE-FIELD 07-30 row. Matching on the name alone reads the row the engine REJECTED.
  So a cell is attributed to the row whose ad price equals the price the board published, newest such row
  first, and only falls back to the newest row of that name when no price matches (recorded per finding as
  attribution=name-only). This is still a DOUBT list rather than a verdict, because a repeated name at a
  repeated price across files cannot be told apart - but it now reads the row that is actually on the page.

  Advisory: exit 0 even with findings, because the answer lives at the store and not here. A doubted cell
  that is ALSO the commodity crown prints a loud CROWN line so guards output carries it.

  Output: out\instore-channel-doubt.json, plus APPENDED entries in out\research-worklist.json.
  It APPENDS: audit-sale-fallback.ps1 rewrites that file wholesale, so this must run AFTER it in the chain
  and must preserve what it wrote. Overwriting would silently drop the sale-fallback queue.
#>
param([string]$OutDir = "", [string]$CompareFile = "", [string]$WorklistFile = "", [switch]$NoWorklist)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$contract = Join-Path (Split-Path $root -Parent) 'lib\guard-contract.ps1'
if (Test-Path $contract) { . $contract }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
if (-not $WorklistFile) { $WorklistFile = Join-Path $OutDir 'research-worklist.json' }

# ---- the store capture files this audit reads -------------------------------------------------------
# Same globs audit-sale-fallback uses, so the two agree on what "this store's capture" means.
$storeGlob = @{
  'Family Fare' = 'regular\family-fare-regular-*.json'
  'Hy-Vee'      = 'regular\hyvee-regular-*.json'
  'Aldi'        = 'regular\aldi-regular-*.json'
  'Walmart'     = 'regular\walmart-regular-*.json'
  "Baker's"     = 'regular\bakers-regular-*.json'
  "Sam's Club"  = 'sams\sams-deals-*.json'
  'Fareway'     = 'regular\fareway-regular-*.json'
}
$SHIP_ONLY = @('FC', 'MARKETPLACE')

function Get-Rows($doc) {
  # PS 5.1: member enumeration on a bare array yields an empty collection that is NOT $null, so probing
  # .deals to decide the shape reads nothing and reports a clean file. Discriminate on the TYPE.
  if ($doc -is [System.Object[]] -or $doc -is [System.Collections.IList]) { return @($doc) }
  if ($null -ne $doc.deals) { return @($doc.deals) }
  return @()
}

# name -> newest row, per store; plus item_id -> every (date, fulfillment) seen in a FIELD-BEARING file
$byName = @{}
$byItemId = @{}
$fileStats = New-Object System.Collections.Generic.List[object]
foreach ($st in $storeGlob.Keys) {
  foreach ($f in (Get-ChildItem (Join-Path $OutDir $storeGlob[$st]) -ErrorAction SilentlyContinue | Sort-Object Name)) {
    $doc = $null
    try { $doc = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
    $rows = Get-Rows $doc
    if (-not $rows.Count) { continue }
    $withField = 0
    foreach ($r in $rows) { if (($r.PSObject.Properties.Name -contains 'fulfillment') -and ("" + $r.fulfillment).Trim()) { $withField++ } }
    # FIELD-BEARING means the puller was recording the channel when this file was written. Half is a wide
    # margin on purpose: the real files sit at ~99% or at 0%, never near the line.
    $bearing = ($rows.Count -gt 0 -and ($withField / $rows.Count) -ge 0.5)
    $fileStats.Add([pscustomobject]@{ store = $st; file = $f.Name; rows = $rows.Count; with_field = $withField; field_bearing = $bearing })
    foreach ($r in $rows) {
      $nm = "" + $r.item; if (-not $nm) { $nm = "" + $r.name }
      if (-not $nm) { continue }
      $ff = ("" + $r.fulfillment).Trim()
      $iid = ("" + $r.item_id).Trim()
      $px = $null
      $pxRaw = ("" + $r.ad_price) -replace '[^0-9.]', ''
      if ($pxRaw) { try { $px = [double]$pxRaw } catch { $px = $null } }
      # EVERY row of that name is kept, oldest-first, because the engine does not always price from the
      # newest one - see the attribution note in the header.
      # FLAT KEY holding a PLAIN ARRAY, and both halves are deliberate. Nested $byName[$store][$name]
      # binds the chained index against the inner value's own indexer; and storing a
      # System.Collections.Generic.List[object] as a hashtable VALUE makes even a flat $h[$key] throw
      # "Argument types do not match" under PS 5.1 while $h.ContainsKey($key) happily returns True -
      # reproduced in isolation 2026-09-01. An array value has neither problem, and the row count per
      # (store, name) is single digits, so the append cost is nothing.
      $key = $st + '|' + $nm
      $entry = [pscustomobject]@{ file = $f.Name; fulfillment = $ff; item_id = $iid; field_bearing = $bearing; price = $px }
      if ($byName.ContainsKey($key)) { $byName[$key] = @($byName[$key]) + $entry } else { $byName[$key] = @($entry) }
      if ($bearing -and $iid) {
        $ide = [pscustomobject]@{ store = $st; file = $f.Name; fulfillment = $ff; name = $nm }
        if ($byItemId.ContainsKey($iid)) { $byItemId[$iid] = @($byItemId[$iid]) + $ide } else { $byItemId[$iid] = @($ide) }
      }
    }
  }
}

if (-not $CompareFile) {
  $cf = Get-ChildItem (Join-Path $OutDir 'comparison-*.json') -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
  if (-not $cf) { Write-Output 'instore-channel: CANNOT RUN - no comparison-*.json to read'; if (Get-Command Write-GuardComplete -EA SilentlyContinue) { Write-GuardComplete -Name 'instore-channel' }; exit 0 }
  $CompareFile = $cf.FullName
}
$board = (Get-Content $CompareFile -Raw -Encoding UTF8 | ConvertFrom-Json)
$all = @($board.comparison)

$doubt = New-Object System.Collections.Generic.List[object]
foreach ($it in $all) {
  $cid = "" + $it.id
  $stores = @($it.stores)
  if (-not $stores.Count) { continue }
  # the crown is the cheapest per_unit on the row, which is how the board itself ranks
  $crown = ($stores | Sort-Object { [double]$_.per_unit } | Select-Object -First 1)
  foreach ($s in $stores) {
    $st = "" + $s.store
    if (-not $storeGlob.ContainsKey($st)) { continue }
    $nm = "" + $s.item
    if (-not $nm) { continue }
    $key = $st + '|' + $nm
    if (-not $byName.ContainsKey($key)) { continue }
    $cands = @($byName[$key])
    if (-not $cands.Count) { continue }
    # THE ROW THE BOARD IS ACTUALLY SHOWING: the one whose ad price is the published price, newest first.
    $boardPx = $null
    $bpRaw = ("" + $s.ad) -replace '[^0-9.]', ''
    if ($bpRaw) { try { $boardPx = [double]$bpRaw } catch { $boardPx = $null } }
    $row = $null; $attribution = 'price-match'
    if ($null -ne $boardPx) {
      for ($i = $cands.Count - 1; $i -ge 0; $i--) {
        if ($null -ne $cands[$i].price -and [math]::Abs($cands[$i].price - $boardPx) -lt 0.005) { $row = $cands[$i]; break }
      }
    }
    if (-not $row) { $row = $cands[$cands.Count - 1]; $attribution = 'name-only' }
    $why = $null; $detail = $null
    if ($row.field_bearing -and -not $row.fulfillment) {
      $why = 'BLANK-IN-FIELD-BEARING-CAPTURE'
      $detail = ("its row in {0} has an EMPTY fulfillment while that capture populates the field, so the channel was never recorded rather than never collected" -f $row.file)
    }
    elseif (-not $row.field_bearing -and $row.item_id -and $byItemId.ContainsKey($row.item_id)) {
      $fresher = @($byItemId[$row.item_id] | Where-Object { $_.store -eq $st -and ($SHIP_ONLY -contains $_.fulfillment.ToUpper()) })
      if ($fresher.Count) {
        $why = 'PRE-FIELD-ROW-OUTLIVING-A-REFUSAL'
        $detail = ("this cell prices from the PRE-FIELD row in {0}, but item {1} appears in the fresher {2} as {3}, where the in-store gate refuses it" -f $row.file, $row.item_id, $fresher[0].file, $fresher[0].fulfillment)
      }
    }
    if (-not $why) { continue }
    $isCrown = ($crown -and ("" + $crown.store) -eq $st)
    $doubt.Add([pscustomobject]@{
      commodity = $cid; store = $st; item = $nm; per_unit = [double]$s.per_unit
      ad = "" + $s.ad; size = "" + $s.size; is_crown = $isCrown
      why = $why; detail = $detail; source_file = $row.file; item_id = $row.item_id
      attribution = $attribution
    })
  }
}

$rep = [ordered]@{
  generated  = (Get-Date -Format 'yyyy-MM-dd HH:mm')
  board      = (Split-Path $CompareFile -Leaf)
  note       = 'Cells whose winning row cannot prove it is an in-store shelf row. NOT a verdict and nothing is dropped: the shelf-badge check by the browser agent is the only instrument that can answer, and these are queued for it in research-worklist.json.'
  doubt_count = $doubt.Count
  crown_count = @($doubt | Where-Object { $_.is_crown }).Count
  files_read = $fileStats
  doubt      = $doubt
}
$rep | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $OutDir 'instore-channel-doubt.json') -Encoding UTF8

# ---- APPEND to the worklist, never overwrite it -----------------------------------------------------
if (-not $NoWorklist -and $doubt.Count) {
  $existing = New-Object System.Collections.Generic.List[object]
  if (Test-Path $WorklistFile) {
    try {
      $wl = Get-Content $WorklistFile -Raw -Encoding UTF8 | ConvertFrom-Json
      foreach ($e in @($wl.items)) { if ($e) { $existing.Add($e) } }
    } catch { }
  }
  $have = @{}
  foreach ($e in $existing) { $have[(("" + $e.commodity) + '|' + ("" + $e.store))] = $true }
  $added = 0
  foreach ($d in $doubt) {
    $k = $d.commodity + '|' + $d.store
    if ($have.ContainsKey($k)) { continue }
    $have[$k] = $true; $added++
    $existing.Add([pscustomobject]@{
      commodity = $d.commodity; store = $d.store
      reason = ("channel doubt ({0}) - check the SHELF BADGE for '{1}': is it actually stocked in the Omaha store, or is this an online-only listing? {2}" -f $d.why, $d.item, $d.detail)
    })
  }
  ([ordered]@{ generated = (Get-Date -Format 'yyyy-MM-dd HH:mm'); items = $existing }) | ConvertTo-Json -Depth 5 | Set-Content $WorklistFile -Encoding UTF8
  # PARENTHESES ARE LOAD-BEARING: `-f $a, $b - $c` binds as `($string -f $a, $b) - $c`, which tries to
  # cast the formatted line to an int and dies with "Input string was not in a correct format".
  $kept = ($existing.Count - $added)
  Write-Output ("instore-channel: {0} cell(s) queued into research-worklist.json (kept {1} pre-existing entries)" -f $added, $kept)
}

if ($doubt.Count) {
  Write-Output ("instore-channel: {0} published cell(s) cannot prove an in-store channel ({1} of them hold the commodity crown)" -f $doubt.Count, $rep.crown_count)
  foreach ($d in ($doubt | Sort-Object { -[int]$_.is_crown }, commodity)) {
    $tag = if ($d.is_crown) { 'CROWN ' } else { '      ' }
    Write-Output ("  {0}{1,-24} {2,-12} {3}" -f $tag, $d.commodity, $d.store, $d.item)
    Write-Output ("         {0}" -f $d.detail)
  }
  Write-Output '  -> nothing dropped; each is queued for the browser agent shelf-badge check'
} else {
  Write-Output 'instore-channel: every published cell traces to a row that either records an in-store channel or predates the field with no fresher refusal'
}
if (Get-Command Write-GuardComplete -EA SilentlyContinue) { Write-GuardComplete -Name 'instore-channel' }
exit 0
