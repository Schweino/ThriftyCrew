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
param([double]$Tolerance = 0.15, [string]$OutDir = "", [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }

# -SelfTest exercises the per-unit parsers against frozen fixtures and never touches the boards, the
# durable link file, or out\url-worklist.json. The board reads below are skipped for it: this script
# had NO self-test until 2026-08-31, so run-gates could not see it at all and a silent arithmetic
# error in LinkPerUnit sat behind 6 "mismatch" rows that looked like ordinary re-resolve work.
if (-not $SelfTest) {
$cmpFile = (Get-ChildItem (Join-Path $OutDir 'comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1).FullName
$cmp = (Get-Content $cmpFile -Raw | ConvertFrom-Json).comparison
$ri  = @()
$riFile = Join-Path $OutDir 'recipe-board.json'
if (Test-Path $riFile) { $ri = (Get-Content $riFile -Raw | ConvertFrom-Json).comparison }
. (Join-Path $root 'search-terms-lib.ps1')
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
}   # end: if (-not $SelfTest)

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

<#
  Compute the LINKED product's per-unit in $unit from its stored {price,size,name}. Used for the
  'mismatch' check: does the linked product's price actually equal the board price shown next to it?

  2026-08-31: this DELEGATES to pu-lib's Get-LinkPerUnit, the single per-unit parser. It used to carry
  a private copy of that arithmetic, and the 2026-07-26 consolidation that pointed every other caller
  at pu-lib (see audit-board-consistency.ps1 LinkPU) missed this one - so the estate had two
  implementations of one calculation and they drifted, which is the duplicated-constant trap the lib
  exists to prevent. The private copy was the older, weaker one; measured across all 3,342 stored
  links, the two agreed on 3,029, pu-lib parsed 55 shapes the copy returned null for, the copy was
  better on NONE, and they disagreed on 13 - pu-lib correct in all 13:

    "12 x 4 oz"   the pack count precedes the qty with an x and carries no pk token, so the private
                  copy kept only the 4: canned-peaches $7.48 -> $1.87/oz against a true $0.1558/oz.
                  That is where mismatch(1100%) came from, and the percentages were clean multiples of
                  the pack count (tuna 8x = 700%, chicken 2x = 100%) because the divisor was the bug.
    "each" + name the count lives only in the product NAME ("...10 Count", "6 ct"): tortillas $1.99
                  each -> $0.199. pu-lib takes $name for exactly this and reads it under its own
                  two-counts-in-a-name guard, which is why the count is not guessed at here.
    "1/2 gal"     the copy's regex matched the "2 gal" and divided by 256 fl oz instead of 64, so
                  three Baker's dairy links (almond-milk, buttermilk, half-and-half) read 4x LOW.

  None of these ever cleared by re-resolving the chip - a hand-resolved link re-derives the same wrong
  number and re-flags the next day - so they were arithmetic, not capture work.
#>
. (Join-Path $PSScriptRoot 'pu-lib.ps1')
function LinkPerUnit([string]$size, [string]$unit, [double]$price, [string]$name = '') {
  Get-LinkPerUnit -size $size -unit $unit -price $price -name $name
}

if ($SelfTest) {
  <#
    Frozen fixtures for the two per-unit parsers. Every expected value below is arithmetic done by
    hand from the stored {price,size} of a REAL link in product-urls.json, not a value copied out of
    a previous run - a fixture built from the code's own output cannot fail when the code is wrong.
  #>
  $fail = 0
  function T($label, $got, $want) {
    if ($null -eq $want) {
      if ($null -eq $got) { Write-Output "ok    $label -> null" } else { Write-Output "FAIL  $label -> expected null, got $got"; $script:fail++ }
      return
    }
    if ($null -ne $got -and [math]::Abs([double]$got - [double]$want) -lt 0.0005) { Write-Output ("ok    $label -> {0:N4}" -f $got) }
    else { Write-Output "FAIL  $label -> expected $want, got $got"; $script:fail++ }
  }

  # --- the 2026-08-31 bug: "N x M unit" multipacks, all six of them Fareway links ---
  # 12 x 4 oz = 48 oz total; 7.48/48. Before the fix this returned 7.48/4 = 1.8700 (= 1100% high).
  T 'canned-peaches "12 x 4 oz" $7.48 per oz'   (LinkPerUnit '12 x 4 oz'    'oz'   7.48) (7.48/48)
  T 'canned-tuna    "8 x 5 oz"  $6.99 per oz'   (LinkPerUnit '8 x 5 oz'     'oz'   6.99) (6.99/40)
  T 'canned-chicken "2 x 12.5 oz" $5.99 per oz' (LinkPerUnit '2 x 12.5 oz'  'oz'   5.99) (5.99/25)
  T 'sports-drinks  "8 x 20 fl oz" $6.99 /floz' (LinkPerUnit '8 x 20 fl oz' 'floz' 6.99) (6.99/160)
  T 'peaches        "4 x 4.3 oz" $2.99 per oz'  (LinkPerUnit '4 x 4.3 oz'   'oz'   2.99) (2.99/17.2)
  # The literal U+00D7 MULTIPLICATION SIGN, not an ASCII x - the regex accepts [x×] and a store that
  # renders the real sign must not fall back to the un-multiplied qty.
  T 'unicode multiply sign "6 × 12 oz" $9.00'   (LinkPerUnit ('6 ' + [char]0x00D7 + ' 12 oz') 'oz' 9.00) (9.00/72)

  # --- the shape that already worked: must not regress ---
  T 'existing "40 oz 2 pk" $8.00 per oz'        (LinkPerUnit '40 oz 2 pk'   'oz'   8.00) (8.00/80)

  # --- the count lives ONLY in the product name; inert unless the call site passes $name ---
  # These are the rows that read as mismatch(900%)/(500%)/(300%) and could never clear by re-resolving.
  T 'tortillas "each" + "10 Count" name'        (LinkPerUnit 'each' 'each' 1.99 'Mission Super Soft Flour Tortillas, Fajita Size, 10 Count') (1.99/10)
  T 'english-muffins "each" + "6 ct" name'      (LinkPerUnit 'each' 'each' 3.99 'Bays 6 ct, Original, English Muffins, Kosher, 12 oz')      (3.99/6)
  T 'sweet-corn "1 pk" + "(4 Ct)" name'         (LinkPerUnit '1 pk' 'each' 5.99 'Fresh Sweet Corn (4 Ct)')                                  (5.99/4)
  # ...and a name with NO count must fall back to the price, not invent a divisor.
  T 'name without a count -> price itself'      (LinkPerUnit 'each' 'each' 1.99 'Inglehoffer Sweet Honey Mustard')                          1.99

  # --- fractional gallon: the private copy matched the "2 gal" and divided by 256 instead of 64 ---
  T '"1/2 gal" $6.99 per floz = 64 fl oz'       (LinkPerUnit '1/2 gal'      'floz' 6.99) (6.99/64)

  # --- negatives: a decimal or a bare qty must never be treated as a pack count ---
  T 'plain "4.3 oz" $2.99 is NOT a multipack'   (LinkPerUnit '4.3 oz'       'oz'   2.99) (2.99/4.3)
  T 'plain "16 oz" $3.00'                       (LinkPerUnit '16 oz'        'oz'   3.00) (3.00/16)
  T 'bare "lb" $6.99 = one pound'               (LinkPerUnit 'lb'           'lb'   6.99) 6.99
  T 'bare "each" $1.99'                         (LinkPerUnit 'each'         'each' 1.99) 1.99
  T 'unit-price string "$0.28/oz"'              (LinkPerUnit '$0.28/oz'     'oz'   9.99) 0.28
  T '"dozen" $2.40 per each'                    (LinkPerUnit 'dozen'        'each' 2.40) (2.40/12)

  # --- the mismatch check must not fire on an AD price (2026-09-01) ------------------------------
  # Every string below is a real source_ad value taken off the 2026-08-31 boards, not invented: a
  # fixture built from shapes no store writes is the failure this file's own header describes.
  function TB($label, $got, $want) {
    if ([bool]$got -eq [bool]$want) { Write-Output "ok    $label" }
    else { Write-Output "FAIL  $label -> expected $want, got $got"; $script:fail++ }
  }
  TB 'AD  "Weekly Ad" is an ad price, so the gap to a stored everyday price is the discount' `
     (Test-AdPricedCell 'Weekly Ad') $true
  TB 'AD  a dated store ad reads the same'                                                   `
     (Test-AdPricedCell 'Fareway Weekly Ad 2026-08-31 to 2026-09-06') $true
  TB "AD  and Baker's, whose label leads with the store name"                                `
     (Test-AdPricedCell "Baker's Weekly Ad 2026-08-26 to 2026-09-01") $true
  # THE OTHER HALF, and the reason this reads source_ad instead of the cell's `type`. All four of
  # these sit on cells tagged type=sale, yet their price came from a live shelf reading, so the
  # comparison IS valid and skipping them would blind the check on 10 real rows.
  TB 'SHELF a type=sale cell priced from the shelf is still comparable'                      `
     (Test-AdPricedCell 'everyday shelf price') $false
  TB 'SHELF shop.fareway.com is a shelf read, not an ad'                                     `
     (Test-AdPricedCell 'shop.fareway.com') $false
  TB 'SHELF Aisles Online current shelf price'                                               `
     (Test-AdPricedCell 'Aisles Online current shelf price') $false
  TB 'SHELF kroger-api'                                                                      `
     (Test-AdPricedCell 'kroger-api') $false
  TB 'SHELF a cell with no source_ad at all is not an ad price'                              `
     (Test-AdPricedCell '') $false
  TB 'SHELF and neither is $null'                                                            `
     (Test-AdPricedCell $null) $false
  # "weekly ad" must be matched as the phrase, not by either word alone: a shelf source that merely
  # contains "weekly" would otherwise be skipped and its wrong links would never surface.
  TB 'SHELF "weekly circular pickup" is not a weekly AD'                                     `
     (Test-AdPricedCell 'weekly circular pickup') $false

  if ($fail) { Write-Output "SELF-TEST FAIL ($fail)"; exit 1 }
  Write-Output 'SELF-TEST PASS'
  exit 0
}

$work = [ordered]@{}
$seenChips = @{}   # id|store dedup: weekly + recipe occurrences of the same chip must not double-list it
function AddChip($id, $commodity, $unit, $store, $curPU, $boardItem, $srcBoard, $sourceAd) {
  if ($seenChips.ContainsKey($id + '|' + $store)) { return }
  # Prefer the board's exact source product name as the search term - that's the item whose price is shown,
  # so searching for it links the RIGHT product (e.g. "That's Smart! Large Eggs" not just "eggs"). Falls back
  # to the generic commodity search term only when the board did not record a source item.
  # Get-PrimarySearchTerm: [string]$terms.$id JOINS a multi-term commodity into one dead search string.
  $genTerm = if ($terms.PSObject.Properties.Name -contains $id) { Get-PrimarySearchTerm $terms $id } else { $commodity }
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
    # An ad price and a stored everyday price are not comparable, so the gap between them is not
    # evidence of anything. `stale` is deliberately still evaluated above: it compares this board's
    # own snapshot against this board's current value, both on the same footing, and it is the
    # ad-roll-off trigger by design.
    if (-not $reason -and $curPU -gt 0 -and -not (Test-AdPricedCell $sourceAd)) {
      # sanitize: some resolver snapshots stored display text ("$6.17"); a bare [double] cast errored
      # and silently SKIPPED the mismatch check for those rows (surfaced 2026-07-26)
      $stPrice = 0.0; [void][double]::TryParse((([string]$st.price) -replace '[^0-9.]',''), [ref]$stPrice)
      # $st.name is passed because for a "each"/"1 pk" size the pack count exists ONLY in the product
      # name ("...10 Count", "6 ct"). Without it pu-lib's name fallback is inert and the link reads as
      # a single item - tortillas $1.99/each against a true $0.199/each, i.e. mismatch(900%) forever.
      $lpu = LinkPerUnit ([string]$st.size) $unit $stPrice ([string]$st.name)
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
  foreach ($s in $it.stores) { AddChip ([string]$it.id) ([string]$it.commodity) ([string]$it.unit) ([string]$s.store) ([double]$s.per_unit) ([string]$s.item) 'weekly' ([string]$s.source_ad) }
}
foreach ($it in $ri) {
  foreach ($s in $it.stores) { AddChip ([string]$it.id) ([string]$it.commodity) ([string]$it.unit) ([string]$s.store) ([double]$s.per_unit) ([string]$s.item) 'recipe' ([string]$s.source_ad) }
}

$out = [ordered]@{ generated = (Get-Date -Format 'yyyy-MM-dd'); tolerance = $Tolerance; stores = $work }
$out | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $OutDir 'url-worklist.json') -Encoding UTF8
$total = 0
Write-Output "URL worklist (chips needing resolution):"
foreach ($k in $work.Keys) { $n = @($work[$k]).Count; $total += $n; Write-Output ("  {0,-14} {1}" -f $k, $n) }
Write-Output ("  TOTAL          " + $total)