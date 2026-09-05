<#
  import-walmart-batch.ps1 - turn the Walmart __NEXT_DATA__ capture (name~~linePrice~~unitPrice~~usItemId per
  product, tab-keyed by commodity) into walmart-regular rows.

  *** EVERY ROW GOES THROUGH THE BUILDER'S OWN VERIFICATION (2026-07-30 refactor) ***
  This script used to carry its own, weaker size math (back the size out of Walmart's unit price, round to ONE
  decimal, no engine check, no multipack filter). Measured cost on the 23 rows it put into
  walmart-regular-2026-07-25.json: 6 of 23 failed build-walmart-deals' engine-reproduces-the-unit-price
  invariant (3.3-7.1% off), and one of them was CROWNED cheapest on the 2026-07-29 board
  (brown-gravy-mix at $0.5333/oz vs Walmart's real $0.552/oz). So now the importer LIFTS Build-Row out of
  build-walmart-deals.ps1 - the same AST extraction the builder itself uses on compare-deals.ps1 - and every
  batch row must pass:
    1. Build-Row: exact size from Walmart's own arithmetic (lp/up), name-snap when the name reproduces the
       unit price, package-vs-per-unit shape decided by the REAL engine, and the emit invariant:
       Get-UnitPrice(row) must reproduce Walmart's own unitPrice or the row is rejected, never published.
    2. The 2026-07-27 fish-sauce rule (kept from the old importer; Build-Row alone would REGRESS it):
       Walmart's unit price is occasionally WRONG, and lp/up then backs out a wrong size. When the name
       states a single same-family size that diverges >10% from Build-Row's quantity, the NAME wins - and the
       overridden shape is re-verified through the real engine against lp/nameQty. The override is stamped
       into qty_basis so the divergence is visible in the file.
    3. The guard-5 multipack pre-filter (multipack-lib.ps1, dot-sourced same as the builder) - a row guard 5
       would hard-fail is rejected at ingest, by construction.
  Writer provenance: every row carries written_by='import-walmart-batch.ps1' + seller_check, and the merged
  file gets a batch_imports stamp - so a divergent row can be traced to its writer instead of hiding under
  the builder's "every row verified" header.

  NOTE: store is Bellevue 68123 (Omaha metro, Brad OK'd 2026-07-15 - Walmart zone-prices are uniform across the
  metro). Usage: .\import-walmart-batch.ps1 [-TrustNoSeller] ; then compare-deals -> diff-board -> vet.
  -OutRoot writes out\regular + the itemid map under a different root (sandbox testing; default = live).
#>
param([string]$Raw = 'out\staples500\walmart-batch1-raw.txt', [switch]$SelfTest, [switch]$TrustNoSeller, [string]$OutRoot = '',
      [switch]$Reheal, [string]$Shape = '(?i)\bpacks?\s+of\s+\d+')
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$today = (Get-Date).ToString('yyyy-MM-dd')
$outRootDir = if ($OutRoot) { $OutRoot } else { $root }
$regDir = Join-Path $outRootDir 'out\regular'

# ---- lift the REAL pricing math + the REAL row builder (one rule, one home - the importer borrows, never forks) ----
$engineSrc = Get-Content (Join-Path $root 'compare-deals.ps1') -Raw
# One of THREE hand-maintained copies of this list (build-walmart-deals.ps1, build-sams-deals.ps1 carry the
# others). A helper that a lifted function calls must be named here too, or the lift silently produces a
# function whose callee is undefined and it dies at CALL time, not load time. See the note in
# build-sams-deals.ps1; compare-deals.ps1 -SelfTest proves all three lists are closed.
foreach ($fn in @('ConvertTo-DigitNumerals','Get-ItemPrice','Get-PackCount','Test-NameOffersTwoSizes','Get-UnitPrice','Get-SizeAmount','Convert-ToUnit')) {
  $m = [regex]::Match($engineSrc, "(?ms)^function\s+$([regex]::Escape($fn))\s*\(.*?^\}")
  if (-not $m.Success) { throw "import-walmart-batch: could not lift $fn from compare-deals.ps1" }
  Invoke-Expression $m.Value
}
$builderSrc = Get-Content (Join-Path $root 'build-walmart-deals.ps1') -Raw
# Get-NamePackMultipliers joined this list 2026-09-05, with Build-Row's refusal branch. It is a HAND-MAINTAINED
# copy of Build-Row's dependency set, so adding a helper to the builder without adding it here leaves the lift
# short and Build-Row throws CommandNotFound at run time. That is not a silent failure - the throw below and
# guards' walmart-batch self-test both fired within the hour - but it is a copy, and the next helper will cost
# the same trip.
foreach ($fn in @('Resolve-Unit','Get-NameQtyCandidates','Get-NamePackMultipliers','Get-SameFamilyNameQty','Get-NamePack','Format-Qty','Build-Row')) {
  $m = [regex]::Match($builderSrc, "(?ms)^function\s+$([regex]::Escape($fn))\s*\(.*?^\}")
  if (-not $m.Success) { throw "import-walmart-batch: could not lift $fn from build-walmart-deals.ps1" }
  Invoke-Expression $m.Value
}
$m = [regex]::Match($builderSrc, '(?ms)^\$script:UnitFamily = @\{.*?^\}')
if (-not $m.Success) { throw 'import-walmart-batch: could not lift $script:UnitFamily from build-walmart-deals.ps1' }
Invoke-Expression $m.Value
. (Join-Path $root 'multipack-lib.ps1')      # guard-5 lockstep, exactly as the builder dot-sources it
$script:iwbAllow = Get-MpAllowKeys $root

# Walmart's own unit price is occasionally WRONG, and backing the size out of it then ships a wrong
# per-unit price (2026-07-27: "Kikkoman Gluten-Free Fish Sauce, 6.8 fl oz" was listed at 28.4 c/fl oz,
# which backs out to 10 fl oz - the store page itself says 6.8 fl oz, so we published $0.284/fl oz
# instead of $0.418, understating by 32%). The product NAME is the seller's stated pack size and beat
# the computed unit price every time we checked, so when the two disagree the NAME wins.
function Parse-NameSize([string]$name) {
  if (-not $name) { return $null }
  # packs legitimately multiply the stated unit size - no clean single-unit claim to trust. Get-PackCount is
  # the ENGINE'S own pack detector (lifted above), so this and compare-deals agree by construction; the extra
  # lines are the shapes it cannot see. MEASURED 2026-07-30 on the 4,626-row live capture: the shipped guard
  # let 46 multipacks through ("pack of 12", "(4 Cans)", "2 Blocks", "6-pack", "12 Bulk Pack").
  $nsPk = Get-PackCount $name
  if ($nsPk -and $nsPk -gt 1) { return $null }
  if ($name -match '(?i)\bpacks?\s+of\s+\d+') { return $null }
  if ($name -match '(?i)\b\d+\s*x\s*[\d.]+') { return $null }
  if ($name -match '(?i)\b\d+\s+(?:cans?|bottles?|cups?|blocks?|bowls?|jars?|pouches|boxes|bars?|tubs?|trays?|sticks?|sleeves?)\b') { return $null }
  if ($name -match '(?i)\b(twin|multi|variety|value|bulk)\s*pack\b') { return $null }
  # weight RANGES ("1.0 - 3.0 lb", "2.1 to 3.4 lb") state no single size
  if ($name -match '(?i)\d[\d.]*\s*(?:-|to)\s*\d[\d.]*\s*(fl\s*oz|floz|oz|lbs?)\b') { return $null }
  # nutrition / serving text is not a pack size ("16g Protein Per Serving", "20 Grams of Protein per 4 oz Serving")
  $clean = $name -replace '(?i)\d+\s*g\b[^,]*?protein[^,]*', '' -replace '(?i)\bper\s+serving\b', '' -replace '(?i)per\s+[\d.]+\s*(?:fl\s*oz|floz|oz|lbs?|g)\s*serving', ''
  # LEADING-DOT DECIMAL. ".59 oz" read as 59 oz is a 100x error in the CHEAP direction - the phantom-cheapest
  # shape. Item 15 fixed this in the other three size parsers; this one never got it. 6 of the 74 divergences
  # measured on the 2026-07-29 capture were exactly that (Watkins Parsley Flakes .59 oz -> "59 oz").
  $ms = [regex]::Matches($clean, '(?i)(\d+(?:\.\d+)?|\.\d+)\s*(fl\s*oz|floz|oz|lbs?)\b')
  if ($ms.Count -eq 0) { return $null }
  $m = $ms[$ms.Count - 1]          # the size conventionally trails the name
  $qty = [double]$m.Groups[1].Value
  if ($qty -le 0) { return $null }
  $raw = ($m.Groups[2].Value.ToLower() -replace '\s+', '')
  $u = 'oz'; if ($raw -match '^fl') { $u = 'fl oz' } elseif ($raw -match '^lb') { $u = 'lb' }
  return ("$qty $u")
}

# The in-store seller gate. 6-field captures prove first-party; 4-field captures CANNOT, and warn-and-keep
# already cost us once: 15 of the 38 rows in the r300 capture were 3P marketplace listings (a pool-cue shop
# was the "Walmart price" for Goya pigeon peas) that had to be hand-pruned - any re-run would have silently
# re-imported them. Default is now QUARANTINE; -TrustNoSeller restores import for a hand-verified capture
# and stamps seller_check='manual-trust' on every row it lets through.
function Test-IwbSeller($fields, [bool]$trust) {
  if (@($fields).Count -ge 6) {
    $seller = ([string]$fields[4]).Trim(); $fulfill = ([string]$fields[5]).Trim().ToUpper()
    $firstParty = ($fulfill -eq 'STORE' -or $fulfill -eq 'FC' -or $fulfill -eq 'SHIP') -and
                  ($seller -eq '' -or $seller -match '(?i)^walmart(\.com)?$')
    if ($fulfill -eq 'MARKETPLACE' -or -not $firstParty) { return @{ drop3p = $true; seller = $seller; fulfill = $fulfill } }
    return @{ take = $true; check = 'capture' }
  }
  if ($trust) { return @{ take = $true; check = 'manual-trust' } }
  return @{ quarantine = $true }
}

# One raw batch product -> a fully verified board row (or @{err=..}). This is the whole point of the file:
# a row this returns is a row build-walmart-deals would have emitted, plus the fish-sauce name override.
function Convert-BatchRow($raw, [System.Collections.ArrayList]$log) {
  $b = Build-Row $raw
  if ($b.err) {
    # THE FISH-SAUCE CLASS NOW ARRIVES ONE LAYER EARLIER (2026-09-05). Build-Row itself refuses a row whose
    # name states a quantity in the SAME physical family as the priced unit that neither reproduces Walmart's
    # unit price nor is explained by a pack count. That is the same finding this function's own >10%
    # divergence check makes, on the same evidence, so it is relabelled rather than re-derived: the row still
    # goes to out\walmart-batch-rejects-<date>.json for a human, and the reject keeps the provenance the
    # 2026-07-27 incident earned it. What changed is that build-walmart-deals now refuses it too, where
    # before only this importer did.
    if (([string]$b.err) -like 'REFUSED: name quantity disagrees with unit price*') {
      return @{ err = ("name/unit-price divergence: " + ([string]$b.err -replace '^REFUSED: ', '') +
                       " - the store contradicts itself, verify by hand (fish-sauce class 2026-07-27)") }
    }
    return $b
  }
  $row = $b.row
  # fish-sauce rule: name single-size (same family) diverging >10% from the emitted quantity -> name wins
  $named = Parse-NameSize $row.item
  $em = [regex]::Match([string]$row.size, '^([\d.]+)\s+(lb|oz|fl oz)$')
  if ($named -and $em.Success) {
    $pn = [regex]::Match($named, '^([\d.]+)\s+(.+)$')
    $famE = $(if ($em.Groups[2].Value -eq 'fl oz') { 'vol' } else { 'wt' })
    $famN = $(if ($pn.Groups[2].Value -eq 'fl oz') { 'vol' } else { 'wt' })
    if ($famE -eq $famN) {
      $ozE = [double]$em.Groups[1].Value; if ($em.Groups[2].Value -eq 'lb') { $ozE *= 16 }
      $ozN = [double]$pn.Groups[1].Value; if ($pn.Groups[2].Value -eq 'lb') { $ozN *= 16 }
      if ($ozE -gt 0 -and $ozN -gt 0 -and [math]::Abs($ozN / $ozE - 1) -gt 0.10) {
        # FAIL CLOSED, 2026-07-30. This used to SILENTLY PICK THE NAME, "verified" by re-running the engine on
        # the overridden shape. That check cannot reject: for a plain "N unit" size and a unit in
        # lb/oz/floz, Get-UnitPrice returns price/N, which IS lp/nameQty, which IS $want - and the one path
        # that could differ (Get-PackCount) is excluded by Parse-NameSize's own pack guard, which is a subset
        # of Get-PackCount's regex. MEASURED on the 4,626-row 2026-07-29 capture: 74 divergences reached the
        # check and 74 were accepted. 0 rejections. Of those 74, 6 were leading-dot decimals (100x low) and 46
        # were multipacks whose name states ONE unit - so the "gate" was a rubber stamp on 52 wrong sizes.
        # A >10% disagreement between the store's own arithmetic and the store's own name is not something this
        # script can adjudicate. It is a REJECT: the row goes to out\walmart-batch-rejects-<date>.json for a
        # human, and no number is published. Guessing here is worse than no cell (build-aldi-regular's rule).
        return @{ err = ("name/unit-price divergence: Walmart's unit price " + $row.wm_unit_price + " implies [" + $row.size + "] but the name states [" + $named + "] - the store contradicts itself, verify by hand (fish-sauce class 2026-07-27)") }
      }
    }
  }
  # guard-5 lockstep: reject at ingest exactly what the publish gate would hard-fail
  if ((Test-MpClassify 'Walmart' ([string]$row.item) ([string]$row.size) $script:iwbAllow) -eq 'reject') {
    return @{ err = 'multipack: pack priced as a single board unit (guard 5) - not a shopper single-buy unit' }
  }
  # writer provenance: visible in the file, per row
  $row.source_ad = 'Walmart Bellevue 68123 shelf price (batch capture)'
  $row | Add-Member -NotePropertyName written_by -NotePropertyValue 'import-walmart-batch.ps1' -Force
  return @{ row = $row }
}

# REPLACE-by-identity merge, one home, self-tested. EVERY slot per identity is tracked, not just the
# first: the base file can already hold two rows with the same identity (live today: item_id 13908573,
# two Imperial Sugar rows at different prices, inherited from an old capture), and replacing only the
# FIRST indexed slot left the stale sibling live and rank-eligible - the exact 'corrected row and the row
# it corrects coexist' class this merge exists to kill (post-batch review 2026-07-30). A replacement takes
# the first slot and NULLS every other slot with that identity; duplicate identities with NO correction
# are preserved as-is (dropping data on a mere re-run is not this function's call to make).
function Get-RowKey($r) { if ($r.PSObject.Properties['item_id'] -and $r.item_id) { return ('id:' + $r.item_id) } return ('nm:' + (([string]$r.item).ToLower())) }
function Merge-IwbRows($prevDeals, $newRows) {
  $merged = New-Object System.Collections.ArrayList; $idx = @{}
  foreach ($r in @($prevDeals)) {
    if ($null -eq $r) { continue }
    $k = Get-RowKey $r
    if (-not $idx.ContainsKey($k)) { $idx[$k] = New-Object System.Collections.ArrayList }
    [void]$idx[$k].Add($merged.Count)
    [void]$merged.Add($r)
  }
  $added = 0; $replaced = 0
  foreach ($r in @($newRows)) {
    $k = Get-RowKey $r
    if ($idx.ContainsKey($k)) {
      $slots = $idx[$k]
      $merged[[int]$slots[0]] = $r; $replaced++
      for ($si = 1; $si -lt $slots.Count; $si++) { $merged[[int]$slots[$si]] = $null }   # stale siblings die with the row they duplicate
      $idx[$k] = New-Object System.Collections.ArrayList; [void]$idx[$k].Add([int]$slots[0])
    } else {
      $idx[$k] = New-Object System.Collections.ArrayList; [void]$idx[$k].Add($merged.Count); [void]$merged.Add($r); $added++
    }
  }
  $out = New-Object System.Collections.ArrayList
  foreach ($r in $merged) { if ($null -ne $r) { [void]$out.Add($r) } }
  return @{ merged = $out; added = $added; replaced = $replaced }
}

if ($SelfTest) {
  # Pure computation, no writes. Locks (a) the 2026-07-25 one-decimal rounding bug through the builder
  # invariant, (b) the 2026-07-27 fish-sauce override ON TOP of Build-Row (Build-Row alone regresses it),
  # (c) the guard-5 multipack lockstep, (d) the malformed-unit-price rejects the old parser crashed on,
  # (e) the seller gate. Expectations were measured through the real lifted engine on 2026-07-30.
  $CENT = [string][char]0x00A2
  $fail = 0
  $log = New-Object System.Collections.ArrayList
  function _R($n, $lp, $up) { [pscustomobject]@{ q = 't'; n = $n; lp = $lp; up = $up; id = '1' } }
  $cases = @(
    # THE FOUNDING BUG (live on the 2026-07-29 board as the brown-gravy-mix CROWN): old path rounded the
    # backed-out 0.8696 oz to "0.9 oz" and published $0.5333/oz vs Walmart's real $0.552/oz.
    @{ n='Great Value Brown Gravy Mix, 0.87 oz Packet';                lp='$0.48';  up=('55.2 ' + $CENT + '/oz'); e='0.87 oz';    ad='$0.48'  }
    # worst live drift of the 23: rounding shipped 7.1% under Walmart's own number
    @{ n='McCormick Kosher Poultry Seasoning, 0.65 oz Bottle';         lp='$3.18';  up='$4.89/oz';                e='0.65 oz';    ad='$3.18'  }
    # when no name qty reproduces the unit price, the derived size stays EXACT (old path rounded 1.298 -> 1.3)
    @{ n='Tyson All Natural Chicken Livers, 1.25 lb';                  lp='$1.96';  up='$1.51/lb';                e='1.298 lb';   ad='$1.96'  }
    # 2026-07-27 fish-sauce incident: lp/up backs out 10 fl oz, the bottle says 6.8 - the NAME wins
    # (the 2026-07-27 fish-sauce incident now REJECTS instead of overriding - see the rejCases block)
    # clean twin: name agrees -> name-snap inside Build-Row, exact name size, NO override stamped
    @{ n='Thai Kitchen Gluten Free Premium Fish Sauce, 6.76 fl oz';    lp='$4.76';  up=('70.0 ' + $CENT + '/fl oz'); e='6.76 fl oz'; ad='$4.76' }
    # a WEIGHT name size must never override a VOLUME unit price (cross-family)
    @{ n='Some Sauce, 32 oz Jar';                                      lp='$6.40';  up=('10.0 ' + $CENT + '/fl oz'); e='64 fl oz';  ad='$6.40'  }
    # per-lb marker in the name: the engine reads ad_price AS the per-lb price, so the per-unit shape must
    # win. The old importer never ran the engine and would have shipped the $10.35 tray as $10.35/LB.
    @{ n="Member's Mark Boneless Skinless Chicken Breast, priced per pound"; lp='$10.35'; up='$2.88/lb';           e='lb';         ad='$2.88'  }
    # a weight RANGE states no single size -> derived, exact
    @{ n='Sanderson Farms Whole Chicken, 11.0 - 12.2 lb';              lp='$15.27'; up='$1.32/lb';                e='11.568 lb';  ad='$15.27' }
    # nutrition grams are not a pack size
    @{ n='Armour Corned Beef Hash, 16g Protein Per Serving, 14 oz';    lp='$2.72';  up=('19.4 ' + $CENT + '/oz'); e='14 oz';      ad='$2.72'  }
    # CLEAN TWIN for the leading-dot fix: ".59 oz" must parse as 0.59 and AGREE with lp/up, so no divergence,
    # no reject, exact size. Under the shipped parser this read "59 oz", diverged 100x, and was published at
    # $0.1305/oz for a $13.05/oz spice jar - the phantom-cheapest shape.
    @{ n='Watkins Gourmet Organic Spice Jar, Parsley Flakes, .59 oz';  lp='$7.70';  up='$13.05/oz';               e='0.59 oz';    ad='$7.70'  }
    # CLEAN TWIN for the pack-guard fix: "4 oz Cup (Pack of 12)" states ONE cup's size. The shipped guard only
    # sees a digit BEFORE a pack word, so it overrode Walmart's correct 48.105 oz to 4 oz - $0.19/oz published
    # as $2.285/oz, 12x over. Fixed, the name is silent and Walmart's own arithmetic stands.
    @{ n='Del Monte Diced Peaches Fruit Cup Snacks in 100% Fruit Juice, 4 oz Cup (Pack of 12)'; lp='$9.14'; up=('19.0 ' + $CENT + '/oz'); e='48.105 oz'; ad='$9.14' }
    # MUST-FIRE (2026-07-31), FROZEN from walmart-regular-2026-07-31.json: Walmart's "/ea" denominator on this
    # 12 x 3.5 oz pack is provably OUNCES (16.24/0.387 = 42 = 12 x 3.5). Stamped "42 ct" it CROWNED
    # achiote-paste at $4.64/oz - 12x the real $0.3867/oz - because a ct size on an oz commodity sends the
    # engine back to the name's single 3.5 oz jar while keeping the whole pack's price. Run through the
    # importer (not just Build-Row) this ALSO proves the guard-5 multipack lockstep accepts the restamped row.
    @{ n='Chef Merito Achiote Condimentado Spiced Annatto Seed Paste, 3.5 oz, (Pack of 12)'; lp='$16.24'; up=('38.7 ' + $CENT + '/ea'); e='42 oz'; ad='$16.24' }
    # CLEAN TWIN, same shape, count is REAL: derived 50 equals the stated Pack of 50, so ct must survive.
    @{ n='Great Value Uncoated White Paper Plates, 6 Inch, Pack of 50'; lp='$2.12'; up='$4.24/100 ct'; e='50 ct'; ad='$2.12' }
  )
  foreach ($c in $cases) {
    $r = Convert-BatchRow (_R $c.n $c.lp $c.up) $log
    if ($r.err) { Write-Output "FAIL  [$($c.n)] -> $($r.err)"; $fail++; continue }
    if ($r.row.size -ne $c.e -or $r.row.ad_price -ne $c.ad) { Write-Output "FAIL  [$($c.n)] got ad=$($r.row.ad_price) size='$($r.row.size)' want ad=$($c.ad) size='$($c.e)'"; $fail++ }
    elseif ([string]$r.row.qty_basis -match 'OVERRIDDEN by name') { Write-Output "FAIL  [$($c.n)] still carries a silent name override - the rule is REJECT now, not override"; $fail++ }
    else { Write-Output "ok    [$($c.n)] -> ad=$($r.row.ad_price) size='$($r.row.size)'" }
  }
  # rows that must be REJECTED, never published
  $rejCases = @(
    @{ n='Great Value Vanilla Ice Cream Sandwiches, 42 fl oz, 12 Pack'; lp='$5.96'; up=('14.2 ' + $CENT + '/fl oz'); want='multipack' }   # guard-5 lockstep
    @{ n='(4 pack) Skinner Thin Spaghetti Pasta, 12-Ounce Bag';         lp='$4.75'; up=('9.9 ' + $CENT + '/oz');     want='multipack' }   # old importer SHIPPED this; guard 5 would have blocked the publish
    @{ n='Malformed Unit Price';                                        lp='$5.00'; up='1.2.3/oz';                   want='no unitPrice' } # old Parse-WMSize THREW here and EAP=Stop killed the whole import
    @{ n='Leading Dot Cents';                                           lp='$2.00'; up=('.9 ' + $CENT + '/oz');     want='no unitPrice' } # old path backed a fabricated 222.2 oz size out of this
    # MUST-FIRE (2026-07-30): the fish-sauce shape. The store contradicts itself (unit price implies 10 fl oz,
    # the bottle says 6.8) - neither number is publishable, so the row is quarantined for a human.
    @{ n='Kikkoman Gluten-Free Fish Sauce, 6.8 fl oz Glass Bottle';    lp='$2.84';  up=('28.4 ' + $CENT + '/fl oz'); want='name/unit-price divergence' }
    # MUST-FIRE (2026-07-31), FROZEN from walmart-regular-2026-07-31.json: 54.47/1.65 derives 33, which is
    # neither the stated 12-pack nor its 384 oz total. The store contradicts itself on both readings, so no
    # number here is publishable - quarantine beats guessing (build-aldi-regular's rule).
    @{ n='Almond Breeze Almondmilk, Unsweetened Original 32 oz (Pack of 12)'; lp='$54.47'; up='$1.65/ea'; want='name/unit-price divergence' }
  )
  foreach ($c in $rejCases) {
    $r = Convert-BatchRow (_R $c.n $c.lp $c.up) $log
    if ($r.err -and $r.err -match $c.want) { Write-Output "ok    rejects [$($c.n)] -> $($r.err)" }
    else { Write-Output "FAIL  [$($c.n)] should have been rejected ($($c.want)), got $(if($r.err){$r.err}else{'size '+$r.row.size})"; $fail++ }
  }
  # MUST-FIRE: the exact shape the old importer shipped on 2026-07-25 does NOT verify through the engine -
  # this is the check that was missing, demonstrated on the founding bug's frozen row.
  $old = Get-UnitPrice ([pscustomobject]@{ price_text = '$0.48'; name = 'Great Value Brown Gravy Mix, 0.87 oz Packet'; size_text = '0.9 oz'; regular = $null }) ([pscustomobject]@{ unit = 'oz' })
  $wm = 0.552; $tol = [math]::Max(0.02, (0.005 / $wm) + 0.005)
  if ($old -and (([math]::Abs($old.unit_price - $wm) / $wm) -gt $tol)) { Write-Output ("ok    MUST-FIRE: the shipped 0.9-oz shape fails the builder tolerance (engine " + [math]::Round($old.unit_price,4) + " vs Walmart 0.552, tol " + [math]::Round($tol*100,1) + "%)") }
  else { Write-Output 'FAIL  the founding-bug shape passed the tolerance - the invariant went blind'; $fail++ }
  # writer provenance is stamped on every emitted row
  $p = (Convert-BatchRow (_R 'Great Value Poultry Seasoning, 1.5 oz' '$1.97' '$1.31/oz') $log).row
  if ($p.written_by -eq 'import-walmart-batch.ps1' -and $p.source_ad -match 'batch capture' -and $p.engine_check) { Write-Output 'ok    provenance: written_by + batch source_ad + engine_check on every row' }
  else { Write-Output 'FAIL  provenance fields missing'; $fail++ }
  # seller gate
  $s1 = Test-IwbSeller @('n','$1','$1/oz','1','Pool Cue Emporium','MARKETPLACE') $false
  $s2 = Test-IwbSeller @('n','$1','$1/oz','1') $false
  $s3 = Test-IwbSeller @('n','$1','$1/oz','1') $true
  $s4 = Test-IwbSeller @('n','$1','$1/oz','1','','STORE') $false
  if ($s1.drop3p -and $s2.quarantine -and $s3.check -eq 'manual-trust' -and $s4.check -eq 'capture') { Write-Output 'ok    seller gate: 3P dropped, seller-less quarantined by default, -TrustNoSeller stamped, 6-field first-party passes' }
  else { Write-Output 'FAIL  seller gate'; $fail++ }
  # merge: a corrective row must supersede EVERY stale sibling of its identity, not just the first slot
  # (must-fire for the post-batch-review stale-sibling hole; the no-correction dupe pair is the clean twin)
  $mPrev = @(
    [pscustomobject]@{ item = 'Dup Sugar 32 oz'; item_id = '999'; ad_price = '$7.08' },
    [pscustomobject]@{ item = 'Dup Sugar 32 oz'; item_id = '999'; ad_price = '$12.10' },
    [pscustomobject]@{ item = 'Other Thing';     item_id = '111'; ad_price = '$1.00' }
  )
  $mr = Merge-IwbRows $mPrev @([pscustomobject]@{ item = 'Dup Sugar 32 oz'; item_id = '999'; ad_price = '$6.50' })
  $mDup = @($mr.merged | Where-Object { $_.item_id -eq '999' })
  if ($mr.merged.Count -eq 2 -and $mDup.Count -eq 1 -and $mDup[0].ad_price -eq '$6.50' -and $mr.replaced -eq 1 -and $mr.added -eq 0) { Write-Output 'ok    merge: correction supersedes ALL duplicate-identity siblings (stale twin cannot outlive its fix)' }
  else { Write-Output "FAIL  merge left a stale sibling or wrong counts (total=$($mr.merged.Count) dup=$($mDup.Count) repl=$($mr.replaced) add=$($mr.added))"; $fail++ }
  $mr2 = Merge-IwbRows $mPrev @()
  if ($mr2.merged.Count -eq 3 -and $mr2.added -eq 0 -and $mr2.replaced -eq 0) { Write-Output 'ok    merge: uncorrected duplicate identities are preserved (no silent data drops on a bare re-run)' }
  else { Write-Output "FAIL  merge altered rows with no corrections (total=$($mr2.merged.Count))"; $fail++ }
  if ($fail -eq 0) { Write-Output 'SELF-TEST PASS'; exit 0 } else { Write-Output "SELF-TEST FAIL: $fail case(s)"; exit 1 }
}

# ---- -Reheal: re-emit ALREADY-WRITTEN rows through the fixed row builder, from the row's own recorded numbers ----
# A row carries everything Build-Row was given: item (name), ad_price (the linePrice, for the 'package' shape)
# and wm_unit_price (the raw unit-price string). So a builder fix can be applied to rows that are already in the
# file WITHOUT re-running a capture - which matters, because re-running build-walmart-deals over a PARTIAL raw
# capture would overwrite a comprehensive everyday file with a slice (the partial-overwrite rule) and that is a
# far bigger accident than the bug being fixed.
# SCOPED ON PURPOSE. It touches only rows matching -Shape, so the change set is the measured blast radius and
# nothing else; a whole-file re-heal would re-decide 4,864 rows nobody reviewed. It is also FAIL-CLOSED on the
# per-unit shape: there ad_price is the UNIT price, the linePrice is not recoverable from the row, and guessing
# it would invent a number. Rows the fixed builder now REJECTS are removed and written to the rejects file -
# a rejected row is one the store contradicts itself about, and a wrong cell is worse than no cell.
if ($Reheal) {
  $regDirR = Join-Path $outRootDir 'out\regular'
  $prevR = Get-ChildItem (Join-Path $regDirR 'walmart-regular-*.json') -EA SilentlyContinue |
             Where-Object { $_.BaseName -match '^walmart-regular-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending | Select-Object -First 1
  if (-not $prevR) { Write-Output 'reheal: no walmart-regular file to heal'; exit 0 }
  $docR = Get-Content $prevR.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
  $log2 = New-Object System.Collections.ArrayList
  $kept = New-Object System.Collections.ArrayList
  $healed = 0; $tossed = 0; $same = 0; $skipped = 0
  $rejR = New-Object System.Collections.ArrayList
  foreach ($r in @($docR.deals)) {
    if ($null -eq $r -or ([string]$r.item) -notmatch $Shape -or -not $r.wm_unit_price) { [void]$kept.Add($r); continue }
    if (([string]$r.qty_basis) -notmatch '^package') {
      Write-Output ("  skip (per-unit shape, linePrice not recoverable from the row): " + $r.item); $skipped++; [void]$kept.Add($r); continue
    }
    $res = Convert-BatchRow ([pscustomobject]@{ q=''; n=[string]$r.item; lp=[string]$r.ad_price; up=[string]$r.wm_unit_price; id=[string]$r.item_id }) $log2
    if ($res.err) {
      Write-Output ("  REJECT " + $r.item + "`n         was size='" + $r.size + "' -> " + $res.err)
      [void]$rejR.Add([pscustomobject]@{ name=[string]$r.item; lp=[string]$r.ad_price; up=[string]$r.wm_unit_price; was_size=[string]$r.size; reason=$res.err; removed_from=$prevR.Name })
      $tossed++; continue
    }
    $new = $res.row
    # carry forward every field the builder does not emit (as_of, seller_check, product_url, ...) so a re-heal
    # never silently drops provenance or a verified link
    foreach ($p in $r.PSObject.Properties) { if (-not $new.PSObject.Properties[$p.Name]) { $new | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force } }
    $new.source_ad = $r.source_ad          # keep the original capture's provenance string
    if ([string]$new.size -eq [string]$r.size) { $same++ } else {
      Write-Output ("  healed " + $r.item + "`n         size '" + $r.size + "' -> '" + $new.size + "'  (" + $r.engine_check + ' -> ' + $new.engine_check + ')')
      $healed++
    }
    [void]$kept.Add($new)
  }
  if ($healed -or $tossed) {
    $docR.deals = $kept.ToArray()
    if ($docR.PSObject.Properties['deal_count']) { $docR.deal_count = $kept.Count }
    $stampR = [pscustomobject]@{ date=$today; raw=('reheal:' + $Shape); added=0; replaced=$healed; quarantined=0; rejected=$tossed; by='import-walmart-batch.ps1 -Reheal' }
    if ($docR.PSObject.Properties['batch_imports']) { $docR.batch_imports = @(@($docR.batch_imports) + $stampR) } else { $docR | Add-Member batch_imports @($stampR) -Force }
    ($docR | ConvertTo-Json -Depth 6) | Set-Content $prevR.FullName -Encoding UTF8
    if ($rejR.Count) {
      $rf = Join-Path $outRootDir ("out\walmart-batch-rejects-$today.json")
      # ASSIGN FIRST, THEN WRAP. `@(Get-Content | ConvertFrom-Json)` does NOT unroll a bare top-level JSON
      # array in PS 5.1 - it yields ONE element that is the array - so appending to it nests the old rejects
      # inside the new file instead of extending it. test-auditors greps for this exact shape; it caught this
      # line the first time it ran. (Same trap, same fix, as add-known-wrong.ps1.)
      $existing = @()
      if (Test-Path $rf) { $prevRej = Get-Content $rf -Raw -Encoding UTF8 | ConvertFrom-Json; $existing = @($prevRej) }
      ((@($existing) + @($rejR)) | ConvertTo-Json -Depth 4) | Set-Content $rf -Encoding UTF8
    }
  }
  Write-Output ("reheal[$Shape] on $($prevR.Name): $healed healed, $tossed rejected+removed, $same unchanged, $skipped skipped, $($kept.Count) rows remain")
  exit 0
}

# Raw row format (~~-delimited): name~~linePrice~~unitPrice~~usItemId[~~sellerName~~fulfillmentType]
# The last two fields are OPTIONAL (6-field reducer, 2026-07-26): a 3P MARKETPLACE listing is NOT a Bellevue
# shelf price and violates the in-store rule. Present -> non-first-party rows are DROPPED. Absent -> the row
# is QUARANTINED to out\walmart-batch-needs-seller-<date>.json (see Test-IwbSeller above for why warn-and-keep
# was not enough); -TrustNoSeller imports a hand-verified capture and stamps it. Update the browser reducer:
#   ...+'~~'+(p.sellerName||'')+'~~'+(((p.fulfillmentType)||'').toUpperCase())
# READ THE CAPTURE AS UTF-8, AND REPAIR ANYTHING ALREADY MANGLED UPSTREAM.
# A browser Blob download is UTF-8; PowerShell 5.1's Get-Content defaults to the system ANSI codepage
# (Windows-1252 here), so a bare read corrupts every non-ASCII byte and then the row is SAVED that way - the
# damage is baked into the bytes, so reading correctly later does not undo it. That shipped 16 mangled board
# rows on 2026-07-29, 6 of them CROWNS. Walmart hits EVERY line because its unit price carries a cent glyph -
# so the corruption lands in the PRICE field, not just the name. Repair-Mojibake is a no-op on clean text.
. (Join-Path $root 'capture-lib.ps1')
$lines = @(Get-Content (Join-Path $root $Raw) -Encoding UTF8) | ForEach-Object { Repair-Mojibake $_ }   # test-auditors.ps1 greps this exact read shape - keep it verbatim
$rows = New-Object System.Collections.ArrayList
$ids = @{}
$dropped3P = New-Object System.Collections.ArrayList
$droppedTest = New-Object System.Collections.ArrayList
$quarantined = New-Object System.Collections.ArrayList
$rejects = New-Object System.Collections.ArrayList
$overrides = New-Object System.Collections.ArrayList
foreach ($ln in $lines) {
  if (-not ($ln -match "`t")) { continue }
  $prodStr = ($ln -split "`t", 2)[1]
  foreach ($p in ($prodStr -split '\|')) {
    $f = $p -split '~~'
    if ($f.Count -lt 3) { continue }
    $nm = ($f[0]).Trim()
    if (-not $nm) { continue }
    # VENDOR TEST LISTING. This parser reads the reducer output directly rather than through
    # Import-CaptureCsv, so it does not inherit that reader's guard and needs its own. It is checked here,
    # ahead of the seller and unit-price checks, because a test row can pass BOTH: "Test Id 1 Homekist Fudge
    # Grahams" (item 105676485) was first-party, correctly priced at $2.26, and reproduced its own unit price
    # exactly. It reached the graph's confirm-match review as a live graham-crackers candidate on 2026-08-20
    # and was caught by a human reading the name. See placeholder-name-patterns.json.
    if (Test-PlaceholderProductName $nm) { [void]$droppedTest.Add(("{0}  [id={1}, {2}]" -f $nm, $(if ($f.Count -ge 4) { ($f[3]).Trim() } else { '' }), [string]$f[1])); continue }
    $itemId = ''; if ($f.Count -ge 4) { $itemId = ($f[3]).Trim() }
    $sv = Test-IwbSeller $f $TrustNoSeller.IsPresent
    if ($sv.drop3p) { [void]$dropped3P.Add(("{0}  [seller={1}, fulfill={2}]" -f $nm, $sv.seller, $sv.fulfill)); continue }
    if ($sv.quarantine) { [void]$quarantined.Add([pscustomobject]@{ name = $nm; lp = [string]$f[1]; up = [string]$f[2]; id = $itemId; reason = 'no seller/fulfillment fields - marketplace filter cannot run; re-capture with the 6-field reducer, or hand-verify sellers and re-run with -TrustNoSeller' }); continue }
    $res = Convert-BatchRow ([pscustomobject]@{ q = ''; n = $nm; lp = [string]$f[1]; up = [string]$f[2]; id = $itemId }) $overrides
    if ($res.err) { [void]$rejects.Add([pscustomobject]@{ name = $nm; lp = [string]$f[1]; up = [string]$f[2]; reason = $res.err }); continue }
    $row = $res.row
    $row | Add-Member -NotePropertyName as_of -NotePropertyValue $today -Force
    $row | Add-Member -NotePropertyName seller_check -NotePropertyValue $sv.check -Force
    [void]$rows.Add($row)
    if ($itemId) { $ids[$nm] = $itemId }
  }
}
if ($dropped3P.Count -gt 0) { Write-Output ("Walmart: DROPPED {0} third-party/marketplace row(s) (in-store rule):" -f $dropped3P.Count); $dropped3P | ForEach-Object { Write-Output ('  - ' + $_) } }
if ($droppedTest.Count -gt 0) { Write-Output ("Walmart: DROPPED {0} vendor TEST listing(s) (placeholder-name-patterns.json):" -f $droppedTest.Count); $droppedTest | ForEach-Object { Write-Output ('  - ' + $_) } }
if ($overrides.Count -gt 0) { Write-Output ("Walmart: {0} row(s) where the name size beat Walmart's own unit price:" -f $overrides.Count); $overrides | ForEach-Object { Write-Output ('  - ' + $_) } }

# REPLACE-by-identity merge into today's walmart-regular. ADD-only (item|size key) kept BOTH a corrected row
# and the row it corrects; the ranker takes the cheapest row of a store's newest capture, so whenever the old
# bug UNDERSTATED the price (5 of the 6 bad r300 rows) the wrong row kept the board cell forever.
$prefix = 'walmart-regular'
if (-not (Test-Path $regDir)) { New-Item -ItemType Directory -Path $regDir -Force | Out-Null }
$prev = Get-ChildItem (Join-Path $regDir ($prefix + '-*.json')) -EA SilentlyContinue | Where-Object { $_.BaseName -match ('^' + $prefix + '-\d{4}-\d{2}-\d{2}$') } | Sort-Object Name -Descending | Select-Object -First 1
$doc = $null
if ($prev) { $doc = Get-Content $prev.FullName -Raw -Encoding UTF8 | ConvertFrom-Json }
$m = Merge-IwbRows @(if ($doc) { @($doc.deals) } else { @() }) $rows
$merged = $m.merged; $added = $m.added; $replaced = $m.replaced
$outFile = Join-Path $regDir ($prefix + "-$today.json")
# file-level writer provenance: the copied header still says "built by build-walmart-deals.ps1, every row
# verified" - batch_imports makes the second writer visible so a divergence is traceable in the file itself.
$stamp = [pscustomobject]@{ date = $today; raw = $Raw; added = $added; replaced = $replaced; quarantined = $quarantined.Count; rejected = $rejects.Count; by = 'import-walmart-batch.ps1' }
if ($doc) {
  $doc.deals = $merged.ToArray()
  if ($doc.PSObject.Properties['deal_count']) { $doc.deal_count = $merged.Count } else { $doc | Add-Member deal_count $merged.Count -Force }
  if ($doc.PSObject.Properties['batch_imports']) { $doc.batch_imports = @(@($doc.batch_imports) + $stamp) } else { $doc | Add-Member batch_imports @($stamp) -Force }
  ($doc | ConvertTo-Json -Depth 6) | Set-Content $outFile -Encoding UTF8
} else {
  ([ordered]@{ store = 'Walmart'; week_of = $today; price_type = 'everyday'; price_mode = 'in-store'; deal_count = $merged.Count; batch_imports = @($stamp); deals = $merged.ToArray() } | ConvertTo-Json -Depth 6) | Set-Content $outFile -Encoding UTF8
}
if ($rejects.Count) { ($rejects | ConvertTo-Json -Depth 4) | Set-Content (Join-Path $outRootDir ("out\walmart-batch-rejects-$today.json")) -Encoding UTF8 }
if ($quarantined.Count) {
  $qf = Join-Path $outRootDir ("out\walmart-batch-needs-seller-$today.json")
  ($quarantined | ConvertTo-Json -Depth 4) | Set-Content $qf -Encoding UTF8
  Write-Warning ("Walmart: {0} row(s) QUARANTINED (no seller/fulfillment field - marketplace filter could not run). Worklist: {1}. Re-capture with the 6-field reducer, or hand-verify and re-run with -TrustNoSeller." -f $quarantined.Count, $qf)
}
$idsDir = Join-Path $outRootDir 'out\staples500'
if (-not (Test-Path $idsDir)) { New-Item -ItemType Directory -Path $idsDir -Force | Out-Null }
# MERGE, DO NOT OVERWRITE (2026-09-05). This line used to write $ids - THIS BATCH's map only - straight over
# the file, while the deals file three lines above it merges into what is already there. Same function, two
# artifacts, opposite behaviour, and only one of them said so. A 22-row staleness repair therefore cut the
# accumulated name->itemId map from 508 entries to 22, silently: nothing reads this file during the import,
# so the run reported "22 verified, 22 added, 0 rejected" and looked perfect. The map is what lets later
# passes resolve a product to its Walmart item page, so 486 lost entries are 486 links that quietly stop
# resolving, discovered whenever someone next needs one.
# It is also NOT tracked by git, so there is no restoring it from HEAD - the only copy is the one on disk.
# A file with no version history and no merge is one careless write away from gone.
$idsFile = Join-Path $idsDir 'walmart-itemids.json'
$idsOut = @{}
if (Test-Path $idsFile) {
  # An unreadable existing map is NOT an empty one. Throwing here loses today's 22; silently starting fresh
  # loses the other 500. Keep the file, write nothing, and say so - the import's real output is the deals.
  try {
    $prev = Get-Content $idsFile -Raw | ConvertFrom-Json
    foreach ($p in $prev.PSObject.Properties) { $idsOut[$p.Name] = $p.Value }
  } catch {
    Write-Warning ("Walmart: walmart-itemids.json exists but could not be parsed (" + $_.Exception.Message + "). REFUSING to overwrite it with this batch's " + $ids.Count + " entries - that would discard every entry it holds. The deals import above is unaffected; fix or delete the map by hand.")
    $idsOut = $null
  }
}
if ($null -ne $idsOut) {
  $before = $idsOut.Count
  foreach ($k in $ids.Keys) { $idsOut[$k] = $ids[$k] }   # this batch wins on a name it re-captured
  ($idsOut | ConvertTo-Json) | Set-Content $idsFile -Encoding UTF8
  Write-Output ("Walmart: name->itemId map $before -> $($idsOut.Count) entries ($($ids.Count) from this batch, merged not replaced)")
}
Write-Output ("Walmart: verified $($rows.Count) row(s) through the builder invariants ($added added, $replaced replaced, $($rejects.Count) rejected, $($quarantined.Count) quarantined), total $($merged.Count); name->itemId map: $($ids.Count) -> $(Split-Path $outFile -Leaf)")
