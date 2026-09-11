<#
  build-walmart-deals.ps1 - turn a RAW Walmart capture into out\walmart-regular-<date>.json. (Header previously said build-sams-deals - copy-paste error, fixed 2026-07-26.)

  Input CSV (pipe-delimited, from the in-page pull): q|n|lp|up|id
     q  = the search term        n  = product name
     lp = priceInfo.linePrice    ("$3.27")  - the price of the whole pack
     up = priceInfo.unitPrice    ("$1.09/ea") - Walmart's OWN price per unit of measure
     id = usItemId

  *** WHY THIS SCRIPT EXISTS ***
  The 2026-07-15 capture was QUARANTINED (see out\sams\quarantine\README.md). It wrote Sam's per-unit price
  as ad_price with a BARE unit in size ("$1.09" + size:"each"). Every other feed writes a PACKAGE price with a
  pack size. The conventions collide in compare-deals' Get-UnitPrice, which for unit='each' divides by a pack
  count read out of the product NAME:

        if ($plain -and $pk) { return $pr.per_item / $pk }      # compare-deals.ps1 ~line 301

  So "Seedless English Cucumbers, 3 ct." at $1.09 PER EACH became $0.3633/each - wrong by 3x. That divide is
  CORRECT for every other feed (size='each' + "24 Pack" in the name really does mean divide-by-24, asserted in
  guards.ps1 guard 0), so it cannot be changed. The ambiguity has to die at INGEST - here.

  *** THE RULE (from import-sams-prices.ps1, unchanged) ***
        ad_price = (price per commodity-unit) x (the quantity `size` represents)
  i.e. ad_price is the price of ONE `size`. We therefore emit the PACKAGE shape - ad_price = linePrice, and
  size = the real pack quantity - which is what every other feed means and what the engine already reads
  correctly for ANY commodity unit. Emitting a bare per-unit basis instead would be unit-fragile: for a
  commodity measured in `each` whose Sam's unitPrice is per-OZ (ramen, bottled water), the engine would divide
  a per-ounce price by the pack count and publish a number ~50x too low.

  *** WHERE THE PACK QUANTITY COMES FROM ***
  Not from guessing - from Sam's own arithmetic:  qty = linePrice / unitPrice.
  That is exact by construction, but unitPrice is ROUNDED to cents, so for a cheap per-unit item the quotient
  drifts (110-ct trash bags at $0.11/ea derive as 163). So we SNAP to the quantity stated in the name when the
  two agree within 5% - the same 5% pack cross-check import-sams-prices.ps1 already prescribes - and fall back
  to the derived value when the name states nothing.

  *** THE INVARIANT ***
  Because ad_price = lp and size = lp/up, the engine MUST compute lp/(lp/up) = up. So every emitted row is
  checked against the REAL Get-UnitPrice, from the pricing-math-lib.ps1 the engine itself dot-sources: engine(row) must equal Sam's own
  unitPrice. A row that fails is NOT published - it is written to the .rejects.json beside the output. This is
  what the quarantined capture had no way to detect.

  *** THE FISH-SAUCE NAME-OVERRIDE IS DELIBERATELY *NOT* PORTED HERE (decided 2026-07-30) ***
  import-walmart-batch.ps1 carries a rule that lets the product NAME beat Walmart's own unitPrice when the two
  diverge >10%, added 2026-07-27 after a 6.8 fl oz bottle listed at 28.4 c/fl oz backed out to 10 fl oz.
  Backlog item 27 proposed porting it into this builder. IT WAS MEASURED AND REFUSED, and the measurement is
  the point: lifting Build-Row plus the six engine functions and running the override across the full live
  capture (out\captures\walmart-capture-2026-07-29.csv, 4,626 rows, 3,444 built) fires it 74 times and APPLIES
  it 74 times - zero rejections. Its "re-verify the overridden shape through the real engine" step is
  CIRCULAR: for a plain "N unit" size on an lb/oz/floz commodity, Get-UnitPrice returns price/N, which is
  exactly lp/nameQty, which is exactly the value being checked against. The only path that could disagree
  (Get-PackCount) is excluded by Parse-NameSize's own pack guard, a strict subset of Get-PackCount's regex.
  So the check cannot fail, and porting it would replace this builder's REAL invariant - engine output must
  reproduce the store's own published unit price - with a rule that always says yes. That is a gate that can
  never arm, on the one path in this file that decides a published size.
  If it is ever ported, the re-verification must come from something the override does not derive from
  (the store page, a second capture, a cross-store plausibility rail) - not from the name it just trusted.

  Usage: .\build-walmart-deals.ps1 -In <capture.csv> -Date 2026-07-17
         .\build-walmart-deals.ps1 -SelfTest
#>
param(
  [string]$In = "",
  [string]$Date = "",
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\grocery' }
# WHO AM I. This file is a fork of build-sams-deals.ps1 (capture-lib.ps1:14-19) and inherited that name in
# every operator-facing string, so a Walmart failure sent you to the Sam's builder and the Sam's capture.
# Read the name off the file itself so the next fork renames itself. Captured ONCE at script scope on
# purpose: inside a function $MyInvocation.MyCommand.Name returns the FUNCTION name, not the file.
$Me = $MyInvocation.MyCommand.Name
# The CAPTURE date every emitted row is stamped with. Script-scoped for the same reason $Me is: the row
# builder is a function and cannot see the param block's $Date. Falls back to the date in the input
# filename, then to today - in that order, because the filename is evidence and today is a guess.
$script:CaptureDate = $Date
if (-not $script:CaptureDate -and $In) { $m = [regex]::Match($In, '\d{4}-\d{2}-\d{2}'); if ($m.Success) { $script:CaptureDate = $m.Value } }
if (-not $script:CaptureDate) { $script:CaptureDate = (Get-Date).ToString('yyyy-MM-dd') }
. (Join-Path $root 'capture-lib.ps1')   # UTF-8 capture read + mojibake repair, shared by every builder

# ---- the REAL pricing math: the same library compare-deals.ps1 dot-sources ----
. (Join-Path $root 'pricing-math-lib.ps1')   # I82: the pricing math is a LIBRARY now, not a
# regex cut out of compare-deals.ps1's source. The hand-maintained name list this replaced had
# one failure mode that had already fired: add a function Get-UnitPrice calls, forget to list it
# here, and the lifted copy calls something that does not exist - at RUN time. A dot-source
# cannot have that bug, because the file arrives whole. compare-deals.ps1 -SelfTest (section 30)
# asserts this file dot-sources the library and that the library calls nothing outside itself.
# ENCODING: PS 5.1 decodes a BOM-less script as the ANSI codepage. The library is pure ASCII
# (0 non-ASCII bytes on 2026-09-10), so that costs nothing today; a non-ASCII literal added to it
# needs a BOM or a code-point escape.
# ---- the REAL row builder: Build-Row, its six helpers and $script:UnitFamily ----
. (Join-Path $root 'walmart-row-lib.ps1')   # moved out of THIS file on 2026-09-11. import-walmart-batch.ps1
# used to cut Build-Row and its helpers out of this file's source by regex, off a hand-maintained name
# list; both Walmart writers now dot-source the same library, so there is one Build-Row and no lift.
# Build-Row stamps as_of from $script:CaptureDate (set above) and calls Get-UnitPrice (pricing-math-lib,
# dot-sourced above). See design\PLAN-walmart-row-lib-2026-09-11.md.

# ---- multipack pre-filter: reject exactly what guards.ps1 guard 5 would reject, so the board never sees it ----
# 2026-07-23: a broadened Walmart pull dragged in bulk multipacks ("(4 pack) Domino Sugar, 10 lb" = 40 lb) and
# ice-cream novelties whose name states only the pack TOTAL. All 32 hard-failed guard 5 and blocked the whole
# nightly publish, firing ~20 alert emails. These are never a normal shopper's single-buy unit, so they do not
# belong on the board. The arithmetic is ONE shared function (multipack-lib.ps1, dot-sourced by guards.ps1 too),
# so builder and gate can never drift apart - a row this rejects is a row the guard would have hard-failed,
# BY CONSTRUCTION, not by two hand-synced copies. (Defined ABOVE the self-test so -SelfTest proves it.)
. (Join-Path $root 'multipack-lib.ps1')
$bwAllow = Get-MpAllowKeys $root
function BW-IsMultipackReject($item, $size) {
  return ((Test-MpClassify 'Walmart' ([string]$item) ([string]$size) $script:bwAllow) -eq 'reject')
}

if ($SelfTest) {
  $fail = 0
  function _R($n,$lp,$up) { [pscustomobject]@{ q='t'; n=$n; lp=$lp; up=$up; id='1' } }
  function _Chk($label,$raw,$wantSize,$wantAd) {
    $r = Build-Row $raw
    if ($r.err) { Write-Output "FAIL  $label -> $($r.err)"; $script:fail++; return }
    if ($r.row.size -eq $wantSize -and $r.row.ad_price -eq $wantAd) { Write-Output "ok    $label -> ad=$($r.row.ad_price) size='$($r.row.size)'" }
    else { Write-Output "FAIL  $label -> got ad=$($r.row.ad_price) size='$($r.row.size)' want ad=$wantAd size='$wantSize'"; $script:fail++ }
  }
  # 1. THE REGRESSION: the row that got 07-15 quarantined. Package shape -> engine divides 3.27/3 = 1.09.
  _Chk 'cucumbers 3 ct'        (_R 'Seedless English Cucumbers, 3 ct.' '$3.27' '$1.09/ea')      '3 ct'   '$3.27'
  # 2. per-lb bag: qty from name agrees with lp/up
  _Chk 'mini cucumbers 2 lbs'  (_R 'Mini Cucumbers, 2 lbs.' '$3.96' '$1.98/lb')                 '2 lb'   '$3.96'
  # 3. single item, no count in the name -> bare 'each'
  _Chk 'watermelon each'       (_R 'Whole Seedless Watermelon' '$4.98' '$4.98/ea')              'each'   '$4.98'
  # 4. BY-WEIGHT TRAY: the name says "priced per pound", which trips the engine's per-lb marker and makes it
  #    read ad_price AS the per-lb price. The package shape would publish the $10.35 TRAY at $10.35/LB, so the
  #    per-unit shape must win here. This is the exact failure import-sams-prices.ps1 documents.
  _Chk 'chicken breast tray'   (_R "Member's Mark Boneless Skinless Chicken Breast, priced per pound" '$10.35' '$2.88/lb') 'lb' '$2.88'
  # 5. multipack stated size-then-count ("16.9 fl oz, 40 pk") - the ORDER the engine's multipack regex cannot
  #    read. We emit the TOTAL (40 x 16.9 = 676), so order never matters.
  #    This is also the clearest case for the rounding-aware snap: at $0.01/foz the cent-rounding is +/-50%,
  #    so lp/up derives a meaningless 498. The name's 676 is the true size (4.98/676 = $0.0074 -> prints as
  #    the $0.01 Sam's shows). A flat 5% snap would have published the 498.
  _Chk 'water 40 pk 16.9 floz' (_R "Member's Mark Purified Water, 16.9 fl oz, 40 pk" '$4.98' '$0.01/fl oz') '676 fl oz' '$4.98'
  # 6. cheap per-each where the rounded unitPrice derives a WRONG count (163) - the name (110) must win
  _Chk 'trash bags 110 ct'     (_R 'Glad ForceFlex Tall Kitchen Trash Bags, 13 Gallon, 110 ct.' '$17.98' '$0.16/ea') '110 ct' '$17.98'
  # 7. oz block
  _Chk 'cheddar 32 oz'         (_R "Member's Mark Sharp Cheddar, 32 oz." '$15.04' '$0.47/oz')   '32 oz'  '$15.04'
  # 7b. Sam's spells fluid ounce "foz". If this mapping is ever lost, every liquid silently leaves the board.
  _Chk 'foz = fluid ounce'     (_R 'Mr. Clean Multi-Surface Cleaner, 128 fl oz' '$20.48' '$0.16/foz') '128 fl oz' '$20.48'
  # 7c. ...and dozen "dz", which is EGGS - a headline commodity.
  _Chk 'dz = dozen (eggs)'     (_R "Member's Mark Cage Free Grade A Large White Eggs, 2 dozen" '$4.62' '$2.31/dz') '2 dozen' '$4.62'
  # 7d. A COUNT MUST BE A WHOLE NUMBER. Real row: 200-ct bags at a cent-rounded $0.09/ea derive as 210.9. A
  #     fractional "210.889 ct" makes Get-PackCount read the pack as 889 and prices the bags 4x low.
  _Chk 'trash bags 200 ct (rounding-aware snap)' (_R "Member's Mark Power Flex 13-Gallon Tall Kitchen Trash Bags, Fresh Scent, 200 ct." '$18.98' '$0.09/ea') '200 ct' '$18.98'
  # 7e. no count anywhere in the name -> the count is derived, and must still be a whole number
  $r7e = Build-Row (_R 'Member''s Mark Unnamed Count Bags' '$18.98' '$0.09/ea')
  if ($r7e.row -and $r7e.row.size -notmatch '\.') { Write-Output "ok    derived count is a whole number -> size='$($r7e.row.size)'" }
  else { Write-Output "FAIL  derived count not integral: $($r7e.row.size)$($r7e.err)"; $fail++ }

  # 7j. THE COTTON-SWAB CASE (caught by guard 4 against the product link, not by any check in here).
  #     Sam's prints "$0.01/ea" for a 1665-ct box because it rounds 0.0053 UP. lp/up then derives 888, an 87%
  #     "drift" from the true 1665 - so a drift threshold generous enough to accept it would accept anything.
  #     The name wins because 8.88/1665 = $0.0053 rounds to the $0.01 Sam's shows.
  #     The REAL row also carries TWO counts in the opposite order to Pampers below, so no fixed
  #     first/last rule works: 9.34/1750 = $0.0053 (rounds to $0.01, and matches the product link exactly),
  #     while 3 and 5250 do not.
  _Chk 'q-tips 1750 ct 3 pk (rounded $0.01/ea)' (_R 'Q-tips Cotton Swabs, 1750 ct., 3 pk.' '$9.34' '$0.01/ea') '1750 ct' '$9.34'
  #     ...and the opposite order must still take the LAST count. One rule, both names.
  _Chk 'pampers 13 pk., 728 ct.' (_R 'Pampers Aqua Pure Baby Wipes, 13 pk., 728 ct.' '$30.98' '$0.04/ea') '728 ct' '$30.98'

  # 7k. LEADING-DOT DECIMALS (ported from build-sams-deals 2026-07-30): ".98 oz., 46 pk." must read 0.98,
  #     not 98. MUST-FIRE: the old pattern gave name candidates [98, 4508]; neither reproduces $0.23/oz, so
  #     the builder shipped a fractional lp/up-derived '44.696 oz' where the true 45.08 (0.98 x 46) was
  #     invisible. (The sams grits case, alive in the walmart parser until today.)
  _Chk 'grits .98 oz 46 pk (leading-dot)' (_R 'Quaker Instant Grits, Variety Pack, .98 oz., 46 pk.' '$10.28' '$0.23/oz') '45.08 oz' '$10.28'
  #     clean twin: plain leading-dot single item - the name's 0.59 reproduces the unit price exactly
  _Chk 'parsley .59 oz (leading-dot)' (_R 'Watkins Gourmet Organic Spice Jar, Parsley Flakes, .59 oz' '$7.70' '$13.05/oz') '0.59 oz' '$7.70'

  # 7g. THE NAME'S UNIT NEED NOT BE SAM'S UNIT. Milk is sold as "1 gal." but priced per fluid ounce, where a
  #     cent of rounding is +/-16% - lp/up derives 124 fl oz and publishes $3.84/gal for milk that costs
  #     $3.72. Converting the name's gallon into fl oz lets the exact 128 win.
  _Chk 'milk 1 gal priced per foz' (_R "Member's Mark 2% Reduced Fat Milk 1 gal." '$3.72' '$0.03/foz') '128 fl oz' '$3.72'
  # 7h. a name unit from ANOTHER family must be ignored, never converted
  $r7h = Build-Row (_R 'Mystery Item 12 ct' '$6.00' '$0.50/lb')
  if ($r7h.row -and $r7h.row.size -eq '12 lb') { Write-Output "ok    foreign name-unit ignored -> size='$($r7h.row.size)'" }
  else { Write-Output "FAIL  foreign name-unit: $($r7h.row.size)$($r7h.err)"; $fail++ }

  # 7i. Sam's punctuates "fl. oz." and slips a word between the measure and the count. Both broke the pairing,
  #     so this canned coconut milk fell back to a bare "6 ct", which a per-FL-OZ commodity cannot convert -
  #     the engine then read the per-CAN 13.66 fl oz off the name and priced it 6x high, out of band, gone.
  $r7i = (Build-Row (_R 'Thai Kitchen Unsweetened Coconut Milk 13.66 fl. oz. cans, 6 pk.' '$11.24' '$1.87/ea')).row
  if ($r7i -and $r7i.size -eq '6 ct 13.66 fl oz') {
    $fz = Get-UnitPrice ([pscustomobject]@{price_text=$r7i.ad_price;name=$r7i.item;size_text=$r7i.size;regular=$null}) ([pscustomobject]@{unit='floz'})
    if ([math]::Abs($fz.unit_price - 0.1371) -lt 0.005) { Write-Output ("ok    'fl. oz.' + word gap paired -> " + [math]::Round($fz.unit_price,4) + '/floz') }
    else { Write-Output "FAIL  coconut floz = $($fz.unit_price)"; $fail++ }
  } else { Write-Output "FAIL  coconut size='$($r7i.size)' want '6 ct 13.66 fl oz'"; $fail++ }

  # 7f. THE CROSS-UNIT TRAP. Sam's prices these per POUCH, but our applesauce commodity is measured in OZ.
  #     A size of "32 ct" alone has no weight, so the engine falls back to the NAME and finds the per-pouch
  #     "3.2 oz" -> $4.99/oz instead of $0.156/oz. The full descriptor must satisfy BOTH readings.
  $r7f = (Build-Row (_R 'GoGo SqueeZ Applesauce Pouches, Apple Apple, 3.2 oz., 32 ct.' '$15.98' '$0.50/ea')).row
  if ($r7f -and $r7f.size -eq '32 ct 3.2 oz') {
    $asEach = Get-UnitPrice ([pscustomobject]@{price_text=$r7f.ad_price;name=$r7f.item;size_text=$r7f.size;regular=$null}) ([pscustomobject]@{unit='each'})
    $asOz   = Get-UnitPrice ([pscustomobject]@{price_text=$r7f.ad_price;name=$r7f.item;size_text=$r7f.size;regular=$null}) ([pscustomobject]@{unit='oz'})
    if ([math]::Abs($asEach.unit_price - 0.4994) -lt 0.01 -and [math]::Abs($asOz.unit_price - 0.1561) -lt 0.01) {
      Write-Output ("ok    cross-unit: '32 ct 3.2 oz' -> " + [math]::Round($asEach.unit_price,4) + '/each AND ' + [math]::Round($asOz.unit_price,4) + '/oz')
    } else { Write-Output "FAIL  cross-unit: each=$($asEach.unit_price) oz=$($asOz.unit_price)"; $fail++ }
  } else { Write-Output "FAIL  cross-unit size = '$($r7f.size)' want '32 ct 3.2 oz'"; $fail++ }

  # 8. a row whose name lies about the pack by >5% must fall back to Sam's arithmetic, never publish the lie
  $r8 = Build-Row (_R 'Bogus Beans, 99 ct.' '$3.27' '$1.09/ea')
  if ($r8.row -and $r8.row.size -eq '3 ct' -and $r8.row.qty_basis -match 'no name quantity') { Write-Output "ok    name-vs-arithmetic conflict -> trusts lp/up ($($r8.row.qty_basis))" }
  else { Write-Output "FAIL  conflict row: $($r8.err)$($r8.row.size)"; $fail++ }
  # MUST-FIRE (2026-07-30). qty_basis is the provenance a human reads when a Walmart price looks wrong, and it
  # shipped on 2,531 of 2,784 rows crediting "Sam's" arithmetic - the noun this builder inherited when it was
  # forked from build-sams-deals.ps1 - pointing the investigation at the wrong store's method doc. BOTH emitting
  # branches are pinned, because they are separate literals: $r8 above takes the derived-fallback branch (205 of
  # today's rows) and $r7f above takes the name-snap branch (2,326 rows), so asserting on only one would leave
  # the other free to revert green. CLEAN TWIN: the mirrored assertion in build-sams-deals.ps1, which must keep
  # saying Sam's - proving this is a store-specific fix and not "delete the word Sam's everywhere".
  if ($r8.row -and $r8.row.qty_basis -match 'Walmart' -and $r8.row.qty_basis -notmatch 'Sam') { Write-Output 'ok    derived-fallback qty_basis credits Walmart, not the store this builder was forked from' }
  else { Write-Output "FAIL  derived-fallback qty_basis names the wrong store: $($r8.row.qty_basis)"; $fail++ }
  if ($r7f -and $r7f.qty_basis -match 'Walmart' -and $r7f.qty_basis -notmatch 'Sam') { Write-Output 'ok    name-snap qty_basis credits Walmart, not the store this builder was forked from' }
  else { Write-Output "FAIL  name-snap qty_basis names the wrong store: $($r7f.qty_basis)"; $fail++ }

  # 8b. THE "/ea" DENOMINATOR THAT IS NOT AN EACH (2026-07-31). All three rows are FROZEN from the live
  #     2026-07-31 Walmart capture (name / linePrice / unitPrice copied verbatim), one per branch.
  #     MUST-FIRE: the achiote row held the CROWN on achiote-paste at $4.64/oz - 12x its real $0.3867/oz -
  #     because "38.7 c/ea" is per OUNCE and the derived 42 was stamped as a COUNT. Drop the branch and this
  #     goes back to '42 ct', which is exactly how the bug shipped.
  $r8d = (Build-Row (_R 'Chef Merito Achiote Condimentado Spiced Annatto Seed Paste, 3.5 oz, (Pack of 12)' '$16.24' ('38.7 ' + [string][char]0x00A2 + '/ea'))).row
  if ($r8d -and $r8d.size -eq '42 oz' -and $r8d.ad_price -eq '$16.24' -and $r8d.qty_basis -match 'proven by name arithmetic') {
    $achOz = Get-UnitPrice ([pscustomobject]@{price_text=$r8d.ad_price;name=$r8d.item;size_text=$r8d.size;regular=$null}) ([pscustomobject]@{unit='oz'})
    if ([math]::Abs($achOz.unit_price - 0.3867) -lt 0.001) { Write-Output ("ok    pack-of-N '/ea' proven to be OUNCES: 12 x 3.5 = 42 oz -> " + [math]::Round($achOz.unit_price,4) + '/oz (shipped as $4.64/oz)') }
    else { Write-Output "FAIL  achiote restamped but prices $($achOz.unit_price)/oz, want 0.3867"; $fail++ }
  } else { Write-Output "FAIL  achiote MUST-FIRE: size='$($r8d.size)' basis='$($r8d.qty_basis)' - want '42 oz' proven by name arithmetic"; $fail++ }
  # CLEAN TWIN: derived 50 equals the stated Pack of 50, so the count is REAL and ct must survive. If the
  # branch were written as "a pack of N is never a count", this row would break.
  $r8e = (Build-Row (_R 'Great Value Uncoated White Paper Plates, 6 Inch, Pack of 50' '$2.12' '$4.24/100 ct')).row
  if ($r8e -and $r8e.size -eq '50 ct' -and $r8e.qty_basis -notmatch 'proven by name arithmetic') { Write-Output "ok    clean twin: derived 50 = Pack of 50, the count is real -> '50 ct' untouched" }
  else { Write-Output "FAIL  paper plates clean twin: size='$($r8e.size)' basis='$($r8e.qty_basis)' - want '50 ct', no restamp"; $fail++ }
  # REJECT: 33 is neither the 12-pack count nor the 384 oz pack total. The store contradicts itself and
  # neither number is publishable - quarantine beats guessing (build-aldi-regular's rule).
  $r8f = Build-Row (_R 'Almond Breeze Almondmilk, Unsweetened Original 32 oz (Pack of 12)' '$54.47' '$1.65/ea')
  if ($r8f.err -and $r8f.err -match 'name/unit-price divergence') { Write-Output "ok    rejects an unprovable pack denominator -> $($r8f.err)" }
  else { Write-Output "FAIL  almond breeze should have been rejected, got size='$($r8f.row.size)'"; $fail++ }

  # 8g. MUST FIRE - A PRINTED WEIGHT THE UNIT PRICE DENIES (2026-09-05). FROZEN from walmart-regular-2026-08-31
  #     (name / linePrice / unitPrice verbatim, item_id 198431752). The name says 1.82 pounds; $17.97 over
  #     Walmart's own "$1.65/lb" derives 10.891 lb, 5.98x more, and nothing in the name is a pack. Published,
  #     this row held the bouillon CROWN at $0.0813/oz against a real $0.6169/oz. It must be refused outright.
  $r8g = Build-Row (_R 'Knorr Select Vegetable Base, Shelf Stable Granulated Bouillon, 1.82 pounds' '$17.97' '$1.65/lb')
  if ($r8g.err -and $r8g.err -match 'REFUSED: name quantity disagrees with unit price, no pack count') {
    Write-Output "ok    refuses a printed weight the unit price denies -> $($r8g.err)"
  } else { Write-Output "FAIL  Knorr Select should have been REFUSED, got size='$($r8g.row.size)' basis='$($r8g.row.qty_basis)'"; $fail++ }
  #     CLEAN TWIN 1: the disagreement IS explained by a pack the name states in a wording the snap parser
  #     never had ("Pack of 24"). 24 x 16.9 = 405.6, which is the derived 405.5 to within rounding, so the
  #     row publishes exactly as it did before. If the refusal were written without the pack test, every
  #     multipack whose count is spelled this way would leave the board.
  $r8h = (Build-Row (_R '(Pack of 24) Sample Spring Water, 16.9 fl oz' '$8.11' '$0.02/fl oz')).row
  if ($r8h -and $r8h.qty_basis -match 'a pack count in the name explains the multiple') {
    Write-Output "ok    clean twin: 'Pack of 24' explains the multiple -> size='$($r8h.size)'"
  } else { Write-Output "FAIL  Pack-of-24 twin was refused or unexplained: size='$($r8h.size)' basis='$($r8h.qty_basis)' $($r8h.err)"; $fail++ }
  #     CLEAN TWIN 2: the name is SILENT in the priced unit, so there is no disagreement to refuse and the
  #     derived quantity is all we have. This is the 7e shape at a weight unit (Hefty's "13 Gallon" bags).
  $r8i = (Build-Row (_R 'Great Value Boneless Skinless Chicken Thighs, Value Pack' '$10.00' '$2.00/lb')).row
  if ($r8i -and $r8i.size -eq '5 lb') { Write-Output "ok    clean twin: a name silent in the priced unit still publishes on lp/up -> '5 lb'" }
  else { Write-Output "FAIL  silent-name weight row: size='$($r8i.size)'"; $fail++ }
  #     CLEAN TWIN 3: the name agrees to within Walmart's cent rounding but not to the strict snap. 10.5 vs
  #     a derived 10.866 is 3.4% - rounding, not a contradiction - and must publish, or the refusal deletes
  #     correct rows for being imprecise.
  $r8j = (Build-Row (_R 'Sample Harissa Paste, 10.5 oz' '$8.91' '$0.82/oz')).row
  if ($r8j -and $r8j.ad_price -eq '$8.91') { Write-Output "ok    clean twin: a name within rounding of lp/up still publishes -> size='$($r8j.size)'" }
  else { Write-Output "FAIL  rounding twin refused: $($r8j.size)"; $fail++ }
  #     CLEAN TWIN 4: THE COUNT PATH IS UNTOUCHED. Case 8 above ('Bogus Beans, 99 ct.') is a frozen fixture
  #     ruling that a count the arithmetic denies falls back to lp/up. This scoping note is here so that a
  #     later reader does not "finish the job" by extending the refusal to counts and silently retire it.
  $r8k = Build-Row (_R 'Bogus Beans, 99 ct.' '$3.27' '$1.09/ea')
  if ($r8k.row -and $r8k.row.size -eq '3 ct') { Write-Output 'ok    clean twin: the COUNT path still trusts lp/up (case 8 unchanged)' }
  else { Write-Output "FAIL  the refusal leaked into the count path: $($r8k.err)"; $fail++ }

  # 9. rows the engine cannot price are REJECTED, not published
  foreach ($bad in @(@{r=(_R 'No Unit Price Item' '$5.00' ''); l='missing unitPrice'},
                     @{r=(_R 'Weird Unit' '$5.00' '$1.00/sqft'); l='unknown unit'})) {
    $x = Build-Row $bad.r
    if ($x.err) { Write-Output "ok    rejected $($bad.l) -> $($x.err)" } else { Write-Output "FAIL  $($bad.l) should have been rejected"; $fail++ }
  }

  # 10. THE POINT OF THE WHOLE SCRIPT: prove the emitted cucumber row prices to 1.09/each, and that the
  #     OLD (quarantined) shape prices the same product to 0.3633.
  $good = (Build-Row (_R 'Seedless English Cucumbers, 3 ct.' '$3.27' '$1.09/ea')).row
  $ge = Get-UnitPrice ([pscustomobject]@{ price_text=$good.ad_price; name=$good.item; size_text=$good.size; regular=$null }) ([pscustomobject]@{ unit='each' })
  $old = Get-UnitPrice ([pscustomobject]@{ price_text='$1.09'; name='Seedless English Cucumbers, 3 ct.'; size_text='each'; regular=$null }) ([pscustomobject]@{ unit='each' })
  if ([math]::Abs($ge.unit_price - 1.09) -lt 0.005) { Write-Output ("ok    emitted row prices to " + [math]::Round($ge.unit_price,4) + "/each [" + $ge.basis + "]  (quarantined shape gave " + [math]::Round($old.unit_price,4) + " [" + $old.basis + "])") }
  else { Write-Output "FAIL  emitted cucumber row -> $($ge.unit_price)"; $fail++ }

  # 11. THE 2026-07-23 MULTIPACK FILTER. The exact junk that flooded the inbox must be REJECTED, and a real
  #     single-buy unit must be KEPT. This is what stops the builder from producing what guard 5 blocks.
  $mpReject = @(
    @{ n='(4 pack) Domino Premium Pure Cane Granulated Sugar, 10 lb'; s='640 oz' }  # 40 lb bulk case
    @{ n='(8 pack) Gold Medal All Purpose Flour, 5 lb Bag';           s='640 oz' }  # 40 lb bulk case
    @{ n="Great Value Vanilla Ice Cream Sandwiches, 42 fl oz, 12 Pack"; s='42 fl oz' }  # novelty multipack
  )
  foreach ($m in $mpReject) {
    if (BW-IsMultipackReject $m.n $m.s) { Write-Output "ok    rejects bulk multipack: $($m.n.Substring(0,[Math]::Min(38,$m.n.Length)))" }
    else { Write-Output "FAIL  did NOT reject multipack '$($m.n)' - the 2026-07-23 junk would ship"; $fail++ }
  }
  $mpKeep = @(
    @{ n='Great Value Granulated Sugar, 4 lb'; s='4 lb' }                              # real single unit
    @{ n='(12 pack) Great Northern Beans, 15.5 oz'; s='186 oz' }                       # size IS the arithmetic pack total -> keep
  )
  foreach ($m in $mpKeep) {
    if (-not (BW-IsMultipackReject $m.n $m.s)) { Write-Output "ok    keeps legit unit: $($m.n.Substring(0,[Math]::Min(38,$m.n.Length)))" }
    else { Write-Output "FAIL  wrongly rejected '$($m.n)' - real product would vanish"; $fail++ }
  }

  # ---- THE SHELF SIGNAL carries through, and ABSENCE IS UNKNOWN (2026-08-29).
  # The whole safety property of adding sel/ff is that a capture written before the SKILL emitted them
  # must behave EXACTLY as it did yesterday. The 90-day union is full of those, so if absence read as
  # "shipped" the board would lose most of its Walmart cells the moment anything gated on it.
  $csvNew = Join-Path $env:TEMP ('bw-shelf-new-' + [Guid]::NewGuid().ToString('N') + '.csv')
  $csvOld = Join-Path $env:TEMP ('bw-shelf-old-' + [Guid]::NewGuid().ToString('N') + '.csv')
  try {
    # 9-column shape (post-2026-08-29 SKILL) and the 7-column shape that predates it, same product.
    @('q|n|lp|up|id|was|rb|sel|ff',
      'oregano|Frontier Co-op Oregano Leaf Organic, 16 oz|$15.12|94.5 c/oz|111|||Walmart.com|SHIP') |
      Set-Content -LiteralPath $csvNew -Encoding UTF8
    @('q|n|lp|up|id|was|rb',
      'oregano|Frontier Co-op Oregano Leaf Organic, 16 oz|$15.12|94.5 c/oz|111||') |
      Set-Content -LiteralPath $csvOld -Encoding UTF8
    $rowsNew = @(Import-CaptureCsv -Path $csvNew)
    $rowsOld = @(Import-CaptureCsv -Path $csvOld)
    if ([string]$rowsNew[0].sel -eq 'Walmart.com' -and ([string]$rowsNew[0].ff).ToUpper() -eq 'SHIP') {
      Write-Output 'ok    a 9-column capture carries seller + fulfillment through the reader'
    } else { Write-Output "FAIL  9-column capture lost sel/ff (sel='$($rowsNew[0].sel)' ff='$($rowsNew[0].ff)')"; $fail++ }
    if ([string]$rowsOld[0].sel -eq '' -and [string]$rowsOld[0].ff -eq '') {
      Write-Output 'ok    a 7-column capture reads sel/ff as EMPTY, which downstream must treat as unknown - not as shipped'
    } else { Write-Output "FAIL  7-column capture invented sel/ff (sel='$($rowsOld[0].sel)' ff='$($rowsOld[0].ff)')"; $fail++ }
    # And the ROW must carry them, because the reader seeing them is worth nothing if the builder drops them.
    # BEHAVIOURAL SINCE 2026-09-11. This used to grep THIS file's source for the `seller = [string]$raw.sel`
    # line. Build-Row moved to walmart-row-lib.ps1, and the grep would have gone red about a line that was
    # merely somewhere else. It now builds the same two rows and reads the fields off Build-Row's OUTPUT, so it
    # fails when the fields stop travelling and not when the code moves. The second half is the CLEAN TWIN:
    # the 7-column row must still BUILD, carrying both fields empty rather than invented.
    $bNew = Build-Row $rowsNew[0]
    $bOld = Build-Row $rowsOld[0]
    if ($bNew.row -and [string]$bNew.row.seller -eq 'Walmart.com' -and [string]$bNew.row.fulfillment -eq 'SHIP' -and
        $bOld.row -and [string]$bOld.row.seller -eq '' -and [string]$bOld.row.fulfillment -eq '') {
      Write-Output 'ok    the emitted row carries seller + fulfillment'
    } else { Write-Output ("FAIL  the row object does not carry seller/fulfillment - the signal stops at the reader (9-col: seller='" + [string]$bNew.row.seller + "' ff='" + [string]$bNew.row.fulfillment + "' err='" + [string]$bNew.err + "'; 7-col: seller='" + [string]$bOld.row.seller + "' ff='" + [string]$bOld.row.fulfillment + "' err='" + [string]$bOld.err + "')"); $fail++ }
  } finally {
    foreach ($t in @($csvNew, $csvOld)) { if (Test-Path $t) { Remove-Item $t -Force -ErrorAction SilentlyContinue } }
  }

  if ($fail -eq 0) { Write-Output 'SELF-TEST PASS' ; exit 0 } else { Write-Output "SELF-TEST FAIL: $fail case(s)"; exit 1 }
}

# ---------------------------------------------------------------- build
if (-not $In -or -not (Test-Path $In)) { throw "${Me}: -In not found: $In" }
if (-not $Date) { $Date = (Get-Date).ToString('yyyy-MM-dd') }
$raw = Import-CaptureCsv -Path $In -Delimiter '|'   # UTF-8 + repairs names mangled by an upstream ANSI read
if ($script:CaptureRepairCount -gt 0) { Write-Output ("  repaired $($script:CaptureRepairCount) mangled field(s) on ingest (UTF-8 read as ANSI upstream)") }
if ($script:CapturePlaceholderCount -gt 0) { Write-Output ("  dropped $($script:CapturePlaceholderCount) vendor placeholder row(s) at ingest ($($script:CapturePlaceholderPct)% of what was read)") }
if ($script:CaptureIngestWarning) { Write-Output ("  " + $script:CaptureIngestWarning) }
$rows = New-Object System.Collections.Generic.List[object]
$rejects = New-Object System.Collections.Generic.List[object]
# THE ROLLBACK WINDOW (2026-08-21). Brad: a rollback gets "a 30 day TTL from when we first detect".
# Walmart publishes no end date for one - measured on a live search, the ROLLBACK badge carries six keys
# and not one is temporal, promoData is Affirm financing, promoDiscount null - so the window is ours to
# anchor, and the anchor MUST be the first sighting. A rollback is re-observed on every capture covering
# its term, so re-stamping today+30 each time would push the expiry forward forever: a 30-day rule that
# silently means never. rollback-ttl-lib owns that rule and refuses to re-anchor one it has seen before.
# Inert until the capture actually carries a was-price, so an older CSV is unaffected.
. (Join-Path $root 'rollback-ttl-lib.ps1')
$rollbacks = 0
foreach ($r in $raw) {
  $b = Build-Row $r
  if ($b.row) {
    # ONE implementation, three callers (rollback-ttl-lib). This was ten inline lines here and ten more in
    # build-sams-deals; import-walmart-batch is the third caller and got none of it.
    if (Set-RollbackFields -Row $b.row -Was $r.was -Store 'Walmart' -ItemId ([string]$r.id) -Date $script:CaptureDate -Root $root) { $rollbacks++ }
    $rows.Add($b.row)
  } else { $rejects.Add([pscustomobject]@{ name=$r.n; lp=$r.lp; up=$r.up; reason=$b.err }) }
}
# NEVER FATAL (2026-09-11). This save runs BEFORE the rows below are written, and it can now refuse - the ledger lock
# not free within its budget, or a ledger on disk it cannot read and will not overwrite - so an uncaught throw here
# would cost the whole capture over one ledger.
try { [void](Save-RollbackLedger $root) } catch { Write-Warning ("${Me}: rollback ledger NOT saved (" + $_.Exception.Message + ") - the first sightings this build dated are not recorded, and the next build that sees them anchors them to its own later capture") }
if ($rollbacks -gt 0) { Write-Output ("${Me}: $rollbacks rollback(s) dated from first detection (" + (Get-RollbackTtlDays) + "-day TTL; Walmart publishes no end date)") }
# de-dupe identical products (the same SKU is returned by several search terms)
$seen = @{}; $ded = New-Object System.Collections.Generic.List[object]
foreach ($r in $rows) { $k = $r.item + '|' + $r.ad_price + '|' + $r.size; if (-not $seen.ContainsKey($k)) { $seen[$k]=$true; $ded.Add($r) } }

# drop bulk multipacks / novelties the board should never carry (guard-5 lockstep, above)
$kept = New-Object System.Collections.Generic.List[object]
foreach ($r in $ded) {
  if (BW-IsMultipackReject $r.item $r.size) {
    $rejects.Add([pscustomobject]@{ name=$r.item; lp=$r.ad_price; up=$r.wm_unit_price; reason='multipack: pack priced as a single board unit (guard 5) - not a shopper single-buy unit' })
  } else { $kept.Add($r) }
}
$ded = $kept

$outDir = Join-Path $root 'out\regular'
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
$outFile = Join-Path $outDir ("walmart-regular-$Date.json")
[ordered]@{
  store      = "Walmart"
  week_of    = $Date
  price_type = 'everyday'
  source     = 'walmart.com in-page __NEXT_DATA__ priceDetails.priceLines (Omaha L St Supercenter 68137); built by build-walmart-deals.ps1, every row verified to reproduce Walmart''s own unitPrice through compare-deals'' real Get-UnitPrice.'
  captured   = $Date
  # HOW COMPREHENSIVE was this pull? Distinct search terms in the raw capture. A full worklist pull runs ~400+
  # terms (commodity-search.json holds 447); a PerimeterX-throttled partial runs ~50. Deal COUNT cannot tell
  # them apart (the 2026-07-23 partial had 1329 deals vs the full pull's 886 - deep on few commodities), so the
  # term count is the machine-readable partial/full marker that audit-walmart-fullpull.ps1 watches. Without it,
  # a string of partials silently ages the last full capture toward the union window's 14-day cliff.
  pull_terms = @($raw | Select-Object -ExpandProperty q -Unique).Count
  deals      = $ded
} | ConvertTo-Json -Depth 6 | Set-Content $outFile -Encoding UTF8

if ($rejects.Count) {
  # NOT "sams-deals-*.rejects.json": compare-deals globs out\sams\sams-deals-*.json to find captures. Today it
  # skips this file only because its BaseName does not end in a date - one refactor of that check away from
  # feeding rejected rows back into the board. Keep the name outside the glob entirely.
  $rj = Join-Path $root ("out\walmart-rejects-$Date.json")
  $rejects | ConvertTo-Json -Depth 4 | Set-Content $rj -Encoding UTF8
}
Write-Output ("${Me}: {0} raw -> {1} priced ({2} after de-dupe), {3} rejected -> {4}" -f $raw.Count, $rows.Count, $ded.Count, $rejects.Count, (Split-Path $outFile -Leaf))
if ($rejects.Count) {
  Write-Output "  reject reasons:"
  $rejects | Group-Object { ($_.reason -split ':')[0] -replace '\d+','N' } | Sort-Object Count -Descending | Select-Object -First 8 | ForEach-Object { Write-Output ("   {0,4}x {1}" -f $_.Count, $_.Name) }
}


# ---------------------------------------------------------------------------
# ADVANCE THE QUARTERLY ROTATION CURSOR (2026-08-21).
# The capture only counts once it has become a priced file, so the commit belongs
# here rather than in the browser agent that fetched it - the same placement rule
# the placeholder-name guard follows. Step-CaptureCursor re-checks that the file
# really landed and holds rows, so this cannot advance on an empty build.
# Never fatal: a cursor that fails to move costs one repeated slice tomorrow,
# while a builder that dies after writing its rows costs the rows.
if (-not $SelfTest) {
  try {
  & (Join-Path $PSScriptRoot 'commit-capture-cursor.ps1') -Store 'Walmart' -Date $Date | Write-Output
  } catch { Write-Warning ("cursor commit skipped: " + $_.Exception.Message) }
}
