<#
  pull-regular-hyvee.ps1 - refresh Hy-Vee to the CURRENT shelf price at the store the board speaks for.
  Headless; no browser needed. WHICH store that is lives in hyvee-store-lib.ps1, never in this file:
  it was Omaha #01 until 2026-08-21 and is Omaha #02 now, on Brad's ruling, and it was hard-coded here
  plus in five other callers, so "switching stores" meant editing six files and hoping.

  A FOURTH PRICE, FOUND 2026-08-21, AND IT IS THE ONE THAT MATTERS NOW:

      retailItems.tagPrice / ecommerceTagPrice   the SHELF TAG at the pickup location

  storeProducts.price can disagree with it. Measured at Omaha #01 with the store and location correctly
  matched: 2 of 22 sampled products, both Morton & Bassett spices, published at $5.31 and $5.81 against a
  $9.99 tag - and Brad's own Omaha #01 product page showed $9.99. So the board was publishing a number no
  shopper could pay, on a row that looked perfect from the inside (real product, real store, onSale true,
  a plausible was-price). Test-HyVeeTagAgreement below is the cross-check that catches it, and it is only
  meaningful because the tag comes from a DIFFERENT part of the response than the price - the same reason
  guard 10 keeps ad_price and current_price as separate assignments.

  WHY THIS EXISTS. Hy-Vee was the only priced store with no automated pull. Its everyday file was refreshed by
  hand through a browser, went stale between runs, and - worse - whatever captured it read the WRONG NUMBER.
  A Hy-Vee product page carries three different prices and it is very easy to grab the wrong one:

      basePrice             13.99   the REGULAR price
      ssrPricing.price      12.99   *** a DIFFERENT STORE (storeId 1759), not Omaha at all ***
      storeProducts.price   11.99   what the store charges today   <-- what we publish, cross-checked below

  The board was publishing 13.99. Brad found it through sirloin steak: we showed $6.99/lb (a stale markdown),
  the store charged $11.99/lb, and our "fresh" everyday file said $13.99/lb. Three numbers, none of them right.

  WHAT THIS REFRESHES, AND WHAT IT DELIBERATELY DOES NOT.
  It refreshes the PRICE and keeps the SIZE we already hold. Hy-Vee's own `product.size` cannot be trusted:

      "12 fl oz Cans"  for a 12-PACK  -> one can, not the total (a 12x error if taken at face value)
      "13 ea"          for pudding    -> that is 13 OUNCES, mislabelled as a count
      "6.7 ea"         for granola    -> 6.7 ounces, again mislabelled
      "16 oz Sleeve"   for fruit cups -> this one IS the total

  Sometimes the total, sometimes a single unit, sometimes the wrong unit entirely. Our stored sizes, by
  contrast, are already correct and already validated by the price guards ("12 pk 12 fl oz", "8 pk 20 fl oz").
  So: take the number Hy-Vee is authoritative about (the price) and keep the number we have verified (the size).
  Trusting their size field cost 26 board cells and would have published sparkling water at 12x.

  Prices come back as `price` (current) with `basePrice` (regular) kept alongside, so a markdown can be shown
  honestly as "was $X" with NO invented end date. And because this price is the same number the product page
  shows, the board and its "See item" link agree by construction - these cells are fully covered by the price
  guards instead of hiding behind the `sale` exemption.

  Persisted-query API: the GraphQL document must be sent VERBATIM (a hand-written query is rejected 400), so
  the exact document lives base64'd in hyvee\query-b64.txt. storeId is a request VARIABLE, not a cookie, which
  is why this runs with no session and can sit in the daily cloud pipeline like Family Fare's.
#>
# $StoreId defaults to 0 = "ask hyvee-store-lib", so the store identity has exactly ONE home. Passing an
# explicit -StoreId still works for probing another store, but it then ALSO needs -LocationId: the two
# select different halves of the response and a mismatched pair grades one store's price against another
# store's shelf tag. That mismatch reported 11 of 21 Omaha #02 rows as wrong on 2026-08-21 when the real
# number was zero, so the two are deliberately awkward to move apart.
param([string]$OutDir = "", [int]$StoreId = 0, [string]$LocationId = "", [switch]$Quick, [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $root 'omaha-time.ps1')
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
$regDir = Join-Path $OutDir 'regular'
if (-not (Test-Path $regDir)) { New-Item -ItemType Directory -Path $regDir -Force | Out-Null }
$todayS = Get-OmahaDateKey
. (Join-Path $root 'pu-lib.ps1')   # shared per-unit math - used to prove a productId really is our row's size

# THE CARRY-FORWARD ROW, AS ONE PURE FUNCTION (2026-08-22). A product we could not re-verify keeps its last
# known price - but the last known price has a SHAPE, not just a number. The old carry copied ad_price and
# nothing else, so a markdown captured on Monday ($3.99, base_price 5.99, marked_down) was re-emitted on
# Tuesday as a bare $3.99 row: no base_price, no marked_down, no product_id, no current_price. price-split-lib
# then had no discount signal and typed it EVERYDAY at the sale price - the exact laundering Brad's rule
# forbids ("ad pricing must never enter the every day pricing value"), and under the 90-day carry it held.
# Measured on the two newest files: Wish Farms California Strawberries 16 oz, 08-18 marked_down $3.99
# (base_price 5.99), 08-21 carried as a bare $3.99 row with no discount field at all.
# BRAD'S RULING (2026-08-22): when a sale's date ends, the sale price drops away and the everyday (base)
# price is what remains. So a carried row whose window has PASSED is emitted as everyday AT base_price;
# one whose window is still open, or that carries no window at all (Hy-Vee markdowns are undated), keeps
# every discount field so the split can type it as the markdown it is. The key list mirrors Family Fare's
# Norm-Row so the two lanes preserve the same contract fields.
$script:HvCarryKeys = @('current_price', 'base_price', 'marked_down', 'product_id', 'price_multiple',
                        'ad_from', 'ad_to', 'store_department', 'store_department_group', 'store_category')
function Get-HyVeeCarryRow($prow, [string]$name, [string]$asOf, [string]$today) {
  $row = [ordered]@{
    store='Hy-Vee'; item=$name; ad_price=[string]$prow.ad_price; size=[string]$prow.size; regular=$prow.regular
    source_ad=[string]$prow.source_ad; as_of=$asOf; not_reverified=$true
  }
  foreach ($k in $script:HvCarryKeys) { if ($null -ne $prow.$k) { $row[$k] = $prow.$k } }
  $to = [string]$prow.ad_to
  $base = $null
  if ($null -ne $prow.base_price) { try { $base = [double]$prow.base_price } catch { $base = $null } }
  if ($to -match '^\d{4}-\d{2}-\d{2}$' -and $today -match '^\d{4}-\d{2}-\d{2}$' -and $to -lt $today -and $null -ne $base -and $base -gt 0) {
    # THE SALE HAS ENDED. What remains is the everyday price the store told us it was cut FROM. The sale
    # price, the flag and the window all go; current_price follows ad_price so guard 10's contract
    # (ad_price == what the store charges) still holds on the reverted row. sale_expired_on keeps the
    # reason visible on the row rather than making the reversion look like a silent re-price.
    $row['ad_price'] = ('$' + $base); $row['regular'] = $base; $row['current_price'] = $base
    foreach ($k in @('marked_down', 'ad_from', 'ad_to')) { if ($row.Contains($k)) { $row.Remove($k) } }
    $row['sale_expired_on'] = $to
  }
  return $row
}

# EVERYTHING THE FIXTURES MUST REACH LIVES ABOVE THE -SelfTest BLOCK. -SelfTest exits before the store
# registry, the query document and the first request, so a function defined below that line cannot be
# reached by a fixture at all. That is not a style preference: the 2026-08-22 budget bug (below) lived in
# code no self-test could execute, and it collapsed the file to 7 rows for two days. Normalize-Size and
# Test-HyVeeTagAgreement were MOVED up here unchanged for the same reason.

# Fallback size normaliser - used ONLY for a product we have never priced before, where we have no verified
# size to preserve. See the header: Hy-Vee's size field is not dependable, so this is a last resort, and any
# row that comes out of it is still policed by the multipack + factor guards.
function Normalize-Size([string]$raw, [string]$unit, [string]$name) {
  $s = ([string]$raw).Trim()
  $s = $s -replace '(?i)\bfl\.\s*oz\b', 'fl oz'
  $s = $s -replace '(?i)\s+(bags?|bottles?|cans?|jars?|box(es)?|rolls?|shakers?|jugs?|tubs?|sleeves?|pouch(es)?|cartons?|trays?|containers?|zip\s*pak|cup\\tub|spray\s+bottle)\s*$', ''
  $s = ($s -replace '\s+', ' ').Trim()
  if ($s -match '(?i)^\s*1\s*dz\s*$') { $s = 'dozen' }

  # the NAME is the reliable source for pack structure: "12 Pack", "4-3.25 oz Cups", "8-0.84 oz Bars"
  $pk = 0
  $m = [regex]::Match(([string]$name).ToLower(), '(\d+)\s*[- ]?\s*(pack|pk)\b')
  if ($m.Success) { $pk = [int]$m.Groups[1].Value }
  if ($pk -le 1) {
    $m = [regex]::Match(([string]$name).ToLower(), '(\d+)\s*-\s*\d+(\.\d+)?\s*(fl\s*oz|oz)\b')
    if ($m.Success) { $pk = [int]$m.Groups[1].Value }
  }
  if ($unit -eq 'each') {
    if ($pk -gt 1) { return ("$pk ct") }
    $c = [regex]::Match($s, '(?i)(\d+)\s*(ct|count|ea|pk|pack)\b')
    if ($c.Success -and ([int]$c.Groups[1].Value) -gt 0) { return ($c.Groups[1].Value + ' ct') }
    return 'each'
  }
  if ($unit -eq 'dozen') {
    if ($s -match '(?i)dozen') { return 'dozen' }
    $c = [regex]::Match($s, '(?i)(\d+)\s*(ct|count|ea)\b')
    if ($c.Success) { return ($c.Groups[1].Value + ' ct') }
    return 'dozen'
  }
  # a weight/volume commodity sold as a multipack: Hy-Vee's size is ONE unit, so state the pack explicitly
  if ($pk -gt 1 -and ($s -match '(?i)^\d+(\.\d+)?\s*(fl\s*oz|floz|oz|lbs?|ml|l|gal|qt|pt)\b')) { return ("$pk pk $s") }
  return $s
}

function Test-HyVeeTagAgreement {
  <#
    .SYNOPSIS Does the price we are about to publish match the store's own shelf tag?
    .DESCRIPTION Returns '' when they agree or when there is nothing to compare, else a description of
                 the disagreement. Pure, so the frozen fixtures reach the real decision.

    THE FOUNDING BUG (2026-08-21). Brad checked Morton & Bassett Black Sesame Seed on his own Omaha #01
    page and saw $9.99. The board published $5.31 as a 47% markdown off $9.99. Everything about that row
    looked right from the inside: real productId 40112, real store, onSale true, basePrice 9.99, the
    arithmetic reproduces, every existing guard green. The store's retail record said:
        tagPrice 9.99   ecommerceTagPrice 9.99   basePrice 9.99   memberTagPrice null
    while storeProducts.price said 5.31. Two of 22 sampled products were like this. There is no guard
    anywhere in this estate that could see it, because every guard reads the same storeProducts.price.

    WHY IT ONLY REFUSES WHEN THE PRICE IS *LOWER* THAN THE TAG. A published price ABOVE the tag makes us
    look expensive and costs a reader nothing they can be surprised by; a published price BELOW the tag is
    a promise the till will break. The asymmetry is deliberate and it also keeps this from firing on the
    legitimate case it would otherwise destroy - a genuine promotion IS a price below the regular price,
    but it is not below the TAG, because the tag is what the shelf says today including the promotion.
    Confirmed across the sample: all 20 clean rows had promotional prices and every one matched its tag.

    MULTIBUY IS NOT A DISAGREEMENT. tagPriceQuantity states how many the tag price covers, exactly as
    priceMultiple does for the price. Comparing a 3-for total against a single-unit tag is the
    two-different-bases mistake guard 10 already exists for, so a row whose quantities do not match is
    left alone rather than judged on a comparison that does not mean anything.
  #>
  param([double]$Price, [double]$Mult, $TagPrice, $EcomTagPrice, $TagQty)
  $tag = if ($null -ne $EcomTagPrice) { [double]$EcomTagPrice } elseif ($null -ne $TagPrice) { [double]$TagPrice } else { $null }
  if ($null -eq $tag -or $tag -le 0) { return '' }              # nothing to compare against, not a pass
  $tq = if ($null -ne $TagQty -and [double]$TagQty -gt 0) { [double]$TagQty } else { 1.0 }
  $pm = if ($Mult -gt 0) { [double]$Mult } else { 1.0 }
  if ([math]::Abs($tq - $pm) -gt 0.0001) { return '' }          # different bases; see the note above
  $perUnitTag = $tag / $tq
  $perUnitPrice = $Price / $pm
  if ($perUnitPrice -ge ($perUnitTag - 0.005)) { return '' }    # at or above the tag: allowed, see above
  return ("storeProducts.price {0} is BELOW this store's own shelf tag {1} - the till will not honour it" -f $perUnitPrice, $perUnitTag)
}

function Get-HyVeeProductBudget {
  <#
    .SYNOPSIS How many PRODUCTS may this lane ask Hy-Vee about today?
    .DESCRIPTION
      THE DEFECT THIS REPLACES (found 2026-08-22). The budget block took Get-CapturePlan's TermBudget,
      which is derived from the SEARCH TERM count - 596 terms / 90 days = 7 a day. This lane does not
      search. It re-verifies PRODUCTS by product id, one request each, 1,554 of them, and the comment
      above the budget block already said so in capitals - "Products, not terms, is the right unit HERE" -
      while the code took the term number anyway. At 7 a day a full rotation takes 222 days against a
      90-day carry, so roughly 60% of the catalogue would expire before its turn came round: precisely
      the starvation the 90-day carry was raised to prevent (capture-policy-lib: MaxCarryDays "MUST be
      >= QuarterDays or a term's rows die before the rotation comes back to them").

      So the budget is derived from THIS lane's own population, with the quarter read from the policy so
      the two can never drift apart: ceil(1554 / 90) = 18 a day, and moving QuarterDays moves this with it.
      Expiring sales are EXTRA on top, exactly as Get-CapturePlan adds them to TermBudget - they are
      events, not part of the daily drip.

      MaxAskable is the wall-clock ceiling. The run stops ASKING at $MAXMIN minutes whatever the budget
      says, so a budget bigger than that is a budget that lies: it would report N products asked and
      quietly carry the tail. Passing the ceiling in keeps the two numbers arguing here, once, rather than
      in the loop every day. At today's population the budget is 18 and the ceiling ~1,400, so this
      clamps nothing - it exists so a future 100k-product population cannot silently promise a pull the
      clock cannot serve.
  #>
  param([int]$Population, [int]$QuarterDays = 90, [int]$Expiries = 0, [int]$MaxAskable = 0)
  if ($Population -le 0) { return 0 }
  if ($QuarterDays -le 0) { $QuarterDays = 90 }
  $b = [int][math]::Ceiling($Population / [double]$QuarterDays)
  if ($b -lt 1) { $b = 1 }
  if ($Expiries -gt 0) { $b += $Expiries }
  if ($MaxAskable -gt 0 -and $b -gt $MaxAskable) { $b = $MaxAskable }
  if ($b -gt $Population) { $b = $Population }
  return $b
}

function Get-HyVeeAskableCount {
  <#
    .SYNOPSIS How many products may this run ASK Hy-Vee about today, and hold a productId to ask with?
    .DESCRIPTION
      THE COVERAGE DENOMINATOR FOR A BUDGETED LANE. It is a function rather than the inline loop it
      replaces because the console line and the coverage ledger must read the SAME number: the day those
      two disagree, the ledger is describing a run that did not happen.
      $AskIndex $null means unbudgeted - every product holding an id is askable, which is the pre-budget
      denominator unchanged.
  #>
  param($Work, $AskIndex = $null)
  $n = 0; $i = -1
  foreach ($w in $Work) {
    $i++
    if (($null -ne $AskIndex) -and (-not $AskIndex.ContainsKey($i))) { continue }
    if ([int]$w.pid -gt 0) { $n++ }
  }
  return $n
}

function Test-HyVeeWipeout([int]$RowCount, [int]$PrevMax) {
  <#
    The THROTTLE-WIPEOUT rule as ONE expression, so the run and the fixtures read the same text and the
    guard cannot be weakened by accident in one of two places. Unchanged from the inline test it replaces:
    a file under half the recent high-water mark is quarantined, never written over good data.
    It is NOT the thing to relax when a budgeted run collapses - see Invoke-HyVeeWorkPass: the fix is to
    stop handing this guard a collapsed file.
  #>
  return ($PrevMax -gt 100 -and $RowCount -lt ($PrevMax * 0.5))
}

function Invoke-HyVeeWorkPass {
  <#
    .SYNOPSIS One pass over the work list: ask about the products we are allowed to ask about today, and
              emit a row for EVERY product either way.
    .DESCRIPTION
      THE BUG THIS SHAPE EXISTS TO MAKE IMPOSSIBLE (live 2026-08-20 -> 2026-08-22). The capture-policy
      budget was applied by REPLACING the work list with today's slice - `$work = @($hvSlice.Items)` -
      and everything downstream built the output file by looping over $work. So the ~1,547 products
      outside the slice were not merely unasked, they were DROPPED FROM THE FILE. The run produced 7 rows
      against 1,554, the THROTTLE-WIPEOUT guard correctly refused to overwrite good data with it, the file
      was quarantined and the script exited 2 - before the rotation cursor was ever written. The cursor
      therefore never existed, every run took the same first 7 products, and those 7 happen to carry no
      product link, so "0 refreshed today, 7 not re-verified" repeated forever. Hy-Vee's everyday prices
      were frozen at 2026-08-21 with every mechanism reporting success.

      The file already stated the principle it was breaking, twelve lines above, about the wall-clock cap:
      THE CAP IS MEANT TO STOP US ASKING, NOT STOP US WRITING. A budget is the same kind of thing. So a
      product we may not ask about today takes exactly the path a capped product takes: carried at its
      last known price through Get-HyVeeCarryRow, marked not_reverified, counted, and WRITTEN.

      Pure enough to be tested: no disk, no cursor, no network. -Fetch is the only door out (the real run
      passes Get-HyVeeStoreProduct; the fixtures pass a stub), so the fixtures below exercise this exact
      text rather than a transcription of it.

    .PARAMETER Work       the full work list, every product, in rotation order
    .PARAMETER AskIndex   hashtable of WORK INDEX -> $true for the products we may ask about today.
                          $null means unbudgeted: ask about all of them.
    .PARAMETER Fetch      scriptblock: productId -> the store-product object, or $null
    .OUTPUTS  the rows, the counters, and what the run actually did (Attempted/Answered/SliceUnaskable),
              which is what decides whether the rotation cursor has earned its advance.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][AllowEmptyCollection()]$Work,
    [Parameter(Mandatory)][scriptblock]$Fetch,
    $AskIndex = $null,
    [Parameter(Mandatory)][string]$Today,
    [string]$PrevDate = '',
    [hashtable]$Units = @{},
    [string]$SourceLabel = '',
    [double]$MaxMinutes = 14,
    $StartTime = $null,
    [int]$SleepMs = 0
  )
  if ($null -eq $StartTime) { $StartTime = Get-Date }
  $deals = New-Object System.Collections.ArrayList
  $captureTerms = New-Object System.Collections.ArrayList
  $sizeConflicts = New-Object System.Collections.Generic.List[string]
  $tagRefusedRows = New-Object System.Collections.ArrayList
  $fresh = 0; $fail = 0; $markdown = 0; $stale = 0; $newProd = 0; $mismatch = 0
  $tagRefused = 0; $multRefused = 0; $multDescriptive = 0
  # CAP-SKIPPED IS ITS OWN NUMBER, AND SO IS BUDGET-SKIPPED. $stale counts a carry-forward row for four
  # unrelated reasons - the wall-clock cap stopped us asking, the capture-policy budget did not select
  # this product today, the size-mismatch check refused the answer, or the product has no productId to
  # ask with - so a truncated run and a healthy run would otherwise produce the same $stale and be
  # indistinguishable from the outside. Counting them apart is what makes each visible.
  $capSkipped = 0; $budgetSkipped = 0
  # What the run actually DID at the store, for the cursor decision. "Attempted" is requests issued;
  # "Answered" is usable offers returned. A slice where every request failed is a dead API, not a day's
  # work, and must not burn the slice.
  $attempted = 0; $answered = 0; $sliceSize = 0; $sliceUnaskable = 0
  $capWarned = $false
  $workOrdinal = 0
  $wIndex = -1
  foreach ($w in $Work) {
    $wIndex++
    # NOT $w.pid -gt 0: whether a product is IN today's slice is a separate question from whether it can
    # be priced at all, and conflating them is what made the stuck slice invisible.
    $mayAsk = ($null -eq $AskIndex) -or ($AskIndex.ContainsKey($wIndex))
    if ($mayAsk) { $sliceSize++; if ([int]$w.pid -le 0) { $sliceUnaskable++ } }
    $workKey = ('product-{0:d4}-{1}' -f $workOrdinal, $(if ([int]$w.pid -gt 0) { [string][int]$w.pid } else { 'unidentified' }))
    $asked = $false
    $workReason = ''
    $overCap = (((Get-Date) - $StartTime).TotalMinutes -gt $MaxMinutes)
    # Warn ONCE. This used to sit bare inside the loop, so it re-fired for every remaining product - hundreds
    # of identical lines that say nothing about scale, which is its own kind of silence.
    if ($overCap -and -not $capWarned) {
      $capWarned = $true
      Write-Warning ('Hy-Vee: wall-clock cap of ' + $MaxMinutes + ' min hit after ' + $fresh + ' refreshed; every remaining product is kept at its last known price and marked not_reverified')
    }

    $got = $null
    if ($w.pid -gt 0) {
      if ($overCap) { $capSkipped++ }
      elseif (-not $mayAsk) { $budgetSkipped++ }
      else {
        $asked = $true
        $attempted++
        $got = & $Fetch ([int]$w.pid)
        if (-not $got) { $workReason = 'store product lookup returned no usable offer' } else { $answered++ }
        if ($SleepMs -gt 0) { Start-Sleep -Milliseconds $SleepMs }
      }
    }

    if ($got) {
      $sp = $got.sp
      $mult = if ($sp.priceMultiple -and ([double]$sp.priceMultiple) -gt 0) { [double]$sp.priceMultiple } else { 1 }
      $bmult = if ($sp.basePriceMultiple -and ([double]$sp.basePriceMultiple) -gt 0) { [double]$sp.basePriceMultiple } else { 1 }
      $base  = if ($sp.basePrice) { [math]::Round(([double]$sp.basePrice) / $bmult, 4) } else { $null }

      # PRICEMULTIPLE IS NOT ALWAYS A DIVISOR (2026-08-08 accuracy sample, crushed red pepper 3225646).
      # The contract this code was written against is "3 for $4" -> price=4, priceMultiple=3, so price/mult is
      # the per-item number. Hy-Vee also returns rows where `price` is ALREADY the per-item price and the
      # multiple is just describing the promo: crushed red pepper came back price=1.25, priceMultiple=3 while
      # its siblings came back price=3, priceMultiple=3. Dividing that row published $0.4167 a jar - a number
      # that matches NEITHER the $1.25 regular NOR the $1.00 shelf tag, i.e. a price no shopper can ever pay.
      # It reached the board as red-pepper-flakes @ Hy-Vee = $0.2050/oz and the out-of-band sample caught it.
      #
      # THE TELL IS basePrice. A multibuy TOTAL cannot equal the single-unit regular price, so price == basePrice
      # means the multiple is descriptive, not a divisor. Anchoring on the store's own second number keeps this
      # from being a guess about which rows "look wrong".
      $descriptiveMult = $false
      if ($mult -gt 1 -and $null -ne $base -and $base -gt 0) {
        if ([math]::Abs(([double]$sp.price) - $base) -le 0.005) { $descriptiveMult = $true }
      }
      if ($descriptiveMult) { $mult = 1; $multDescriptive++ }
      $price = [math]::Round(([double]$sp.price) / $mult, 4)
      # A DEEP DIVISION IS NOT SILENTLY PUBLISHED. If the divided price still lands implausibly far under the
      # regular price, the divisor is more likely wrong than the promo is deep. Refuse the row rather than ship
      # an unpayable number - a gap is recoverable, a wrong price on the board is what this whole program exists
      # to stop. 0.40 is below every real Hy-Vee multibuy observed (the deepest, 4-for, lands at 0.50 of base).
      if ($mult -gt 1 -and $null -ne $base -and $base -gt 0 -and $price -lt ($base * 0.40)) {
        $multRefused++
        $fail++; $got = $null
      }
      if ($got -and $price -le 0) { $fail++; $got = $null }
      if ($got) {

        # KEEP the verified size. Only a product we have never priced falls back to Hy-Vee's own size field.
        $size = [string]$w.size
        $unit = ''
        if ($w.cid) { $unit = [string]$Units[[string]$w.cid] }
        if (-not $size) {
          if (([bool]$sp.isWeighted) -and ($got.soldBy -eq 'LB')) { $size = 'lb' }
          else { $size = Normalize-Size $got.rawSize $unit $w.name }
          $newProd++
        }
        elseif ($unit) {
          # DOES THIS PRODUCT ID ACTUALLY MATCH THE ROW WE ARE REFRESHING?
          # Rows are bound to a productId by NAME, and Hy-Vee reuses names across sizes: "Hy-Vee 100% Orange
          # Juice" is BOTH a 64 fl oz carton and a 1 gallon jug. Bind the wrong one and we stamp the GALLON's
          # $8.99 onto a 64 fl oz row - publishing orange juice at half its true per-unit price, with the board
          # and the link each internally consistent and both wrong. Same trap on peanut butter (a 40 oz price
          # landing on a 16 oz row).
          # So: compare the quantity WE hold against the quantity Hy-Vee just returned. Equal is fine. An exact
          # pack multiple is fine too - their size field reports ONE unit of a multipack ("12 fl oz Cans" for a
          # 12-pack) while ours records the total. Anything else means the id points at a different variant, and
          # we must not put that price on this row.
          $theirSize = Normalize-Size $got.rawSize $unit $w.name
          if (([bool]$sp.isWeighted) -and ($got.soldBy -eq 'LB')) { $theirSize = 'lb' }
          $ourPU   = Get-LinkPerUnit -size $size      -unit $unit -price 1 -name $w.name
          $theirPU = Get-LinkPerUnit -size $theirSize -unit $unit -price 1 -name $w.name
          if (($null -ne $ourPU) -and ($null -ne $theirPU) -and ($ourPU -gt 0) -and ($theirPU -gt 0)) {
            $ourQty   = 1.0 / [double]$ourPU
            $theirQty = 1.0 / [double]$theirPU
            $ratio = $ourQty / $theirQty
            $ok = ([math]::Abs($ratio - 1) -le 0.05)
            if (-not $ok) {
              $pkm = [regex]::Match(([string]$w.name).ToLower(), '(\d+)\s*[- ]?\s*(pack|pk|ct)\b')
              if ($pkm.Success) {
                $pc = [double]$pkm.Groups[1].Value
                if ($pc -gt 1 -and ([math]::Abs($ratio - $pc) -le ($pc * 0.05))) { $ok = $true }
              }
            }
            if (-not $ok) {
              $mismatch++
              $workReason = 'source product size conflicts with the worklist variant'
              [void]$sizeConflicts.Add(('{0}  ours=[{1}] hy-vee=[{2}]  qty {3} vs {4}  (productId {5})' -f $w.name, $size, $theirSize, [math]::Round($ourQty,2), [math]::Round($theirQty,2), $w.pid))
              $got = $null   # refuse the refresh; fall through to "could not re-verify"
            }
          }
        }
        if ($got) {
          if (-not $size) { $size = 'each' }

          # THE SHELF-TAG CROSS-CHECK. A price BELOW the store's own tag is refused outright rather than
          # published and flagged: this is the one failure mode where the row looks perfect from every
          # angle we already measure, so a warning nobody reads would be the same as shipping it. The
          # commodity falls through to another store, which is what a shopper should have been seeing.
          $tagWhy = Test-HyVeeTagAgreement -Price $price -Mult $mult -TagPrice $got.tagPrice -EcomTagPrice $got.ecomTagPrice -TagQty $got.tagQty
          if ($tagWhy) {
            $tagRefused++
            # $got, not $res. This read $res - a variable that has never existed in this script - so every
            # refusal line printed a blank tag, on the one report whose whole purpose is to show the tag
            # the price disagreed with. Found while extracting this loop, 2026-08-22.
            [void]$tagRefusedRows.Add([ordered]@{ item = [string]$w.name; product_id = [int]$w.pid; price = $price; tag = $(if ($null -ne $got.ecomTagPrice) { $got.ecomTagPrice } else { $got.tagPrice }); why = $tagWhy })
            [void]$captureTerms.Add([ordered]@{ term = $workKey; ordinal = $workOrdinal; outcome = 'refused-below-shelf-tag'; row_count = 0 })
            $workOrdinal++
            continue
          }
          $isDown = ([bool]$sp.onSale) -and ($null -ne $base) -and ($price -lt $base)
          if ($isDown) { $markdown++ }

          $row = [ordered]@{
            store='Hy-Vee'; item=$w.name; ad_price=('$' + $price); size=$size; regular=$price
            # THE CONTRACT (guards invariant 10). Record what the STORE CHARGES, separately from what we choose
            # to PUBLISH. If anyone ever edits this puller to reach for basePrice again, ad_price and
            # current_price stop agreeing and the guard catches it from the outside. Drop this field and the
            # guard goes blind - which is exactly the state Baker's, Fareway, Sam's and Walmart are still in.
            current_price=[double]$sp.price
            source_ad=$SourceLabel
            as_of=$Today; product_id=[int]$w.pid
          }
          # THE STORE'S OWN SHELF, RECORDED AT LAST. The persisted GraphQL document in hyvee\query-b64.txt has
          # ALWAYS asked for these - it selects departmentGroup{name}, department{name} and category{name} on
          # storeProducts, which is the exact object $sp is - and this row threw all three away, the same way
          # Freshop's canonical_url was thrown away by a fields= whitelist until 2026-07-16.
          # WHY IT MATTERS: there is exactly one statement anywhere in this estate about what commodity a
          # product IS, the include regex, and every guard inherits it. 47 of the 99 wrong numbers that reached
          # shoppers in 22 days were that one premise being wrong, and SKU identity cannot help - all four of
          # the 2026-07-30 wrong products had a verified first-party product id. Hy-Vee saying "Health &
          # Beauty" over our saying "coconut oil" is a genuinely independent second opinion, and it costs zero
          # extra requests: the fields are already in the response we already parse.
          # ADDITIVE ONLY: three optional properties. A product Hy-Vee returns no department for simply does
          # not get them, and audit-store-taxonomy.ps1 reports the covered-row count out loud rather than
          # treating an uncovered store as a clean one.
          if ($sp.department -and $sp.department.name)           { $row['store_department']       = [string]$sp.department.name }
          if ($sp.departmentGroup -and $sp.departmentGroup.name) { $row['store_department_group'] = [string]$sp.departmentGroup.name }
          if ($sp.category -and $sp.category.name)               { $row['store_category']         = [string]$sp.category.name }
          # RECORD THE MULTIBUY DIVISOR, or the contract above compares two different bases and the guard fires on
          # correct data. `price` is the MULTIBUY TOTAL ("3 for $4" -> sp.price=4, priceMultiple=3) and we publish
          # the per-item $1.3333, so ad_price and current_price legitimately differ by exactly $mult. Guard 10 was
          # reading that as "we publish $1.3333, the store charges $4 - the puller took the wrong price field" and
          # hard-failed 18 rows of perfectly good data (Hass Avocados, 2-liter Pepsi, Chips Ahoy...). It only
          # surfaced now because the id fix took refreshed rows from ~450 to 838, so far more multibuys got priced.
          # Storing the divisor keeps the guard INDEPENDENT: it can still prove ad_price came from
          # storeProducts.price and not basePrice (basePrice * mult would not equal sp.price), which is the whole
          # reason the field exists. Dividing current_price here instead would have made both sides the same
          # expression and the guard vacuous - the two-copies-of-the-same-math trap.
          if ($mult -gt 1) { $row['price_multiple'] = $mult }
          if ($null -ne $base) { $row['base_price'] = $base }
          if ($isDown) { $row['marked_down'] = $true }
          [void]$deals.Add($row)
          [void]$captureTerms.Add([ordered]@{ term=$workKey; ordinal=$workOrdinal; outcome='success'; row_count=1 })
          $workOrdinal++
          $fresh++
          continue
        }
      }
    }

    # could not re-verify: keep the last known price, but SAY SO with an honest as_of rather than passing it off
    # as today's number. A price we cannot check is not a price we get to call fresh.
    if ($w.prow) {
      $asOf = if ($w.prow.as_of) { [string]$w.prow.as_of } elseif ($PrevDate) { $PrevDate } else { $Today }
      # Through Get-HyVeeCarryRow, never an inline key list: see its header for the markdown that was being
      # laundered into an everyday price here, and Brad's ruling on what an ended sale must revert to.
      $row = Get-HyVeeCarryRow $w.prow $w.name $asOf $Today
      [void]$deals.Add($row)
      $stale++
    } else { $fail++ }
    if (-not $asked) {
      $reason = if ($overCap) { 'wall-clock cap before request' } elseif (-not $mayAsk) { 'outside today''s capture-policy slice - carried at its last known price' } elseif ([int]$w.pid -le 0) { 'worklist product has no retailer product id' } else { 'request not attempted' }
      [void]$captureTerms.Add([ordered]@{ term = $workKey; ordinal = $workOrdinal; outcome='not_attempted'; row_count=0; reason=$reason })
    } else {
      if (-not $workReason) { $workReason = 'source offer could not be verified' }
      [void]$captureTerms.Add([ordered]@{ term = $workKey; ordinal = $workOrdinal; outcome='rejected'; row_count=0; reason=$workReason })
    }
    $workOrdinal++
  }
  return [pscustomobject]@{
    Deals = $deals; CaptureTerms = $captureTerms; SizeConflicts = $sizeConflicts
    TagRefusedRows = $tagRefusedRows
    Fresh = $fresh; Fail = $fail; Markdown = $markdown; Stale = $stale; NewProd = $newProd
    Mismatch = $mismatch; CapSkipped = $capSkipped; BudgetSkipped = $budgetSkipped
    TagRefused = $tagRefused; MultRefused = $multRefused; MultDescriptive = $multDescriptive
    Attempted = $attempted; Answered = $answered; SliceSize = $sliceSize; SliceUnaskable = $sliceUnaskable
  }
}

if ($SelfTest) {
  # Pure, no network, no writes - placed above the store registry and every request so nothing can skip it.
  . (Join-Path $root 'price-split-lib.ps1')
  . (Join-Path $root 'capture-policy-lib.ps1')
  $fail = 0
  function _T([string]$label, [bool]$cond) { if ($cond) { Write-Output "ok    $label" } else { Write-Output "FAIL  $label"; $script:fail++ } }
  # MUST-FIRE: the founding row. An undated Hy-Vee markdown carried forward must still READ as a markdown.
  $src = [pscustomobject]@{ item='Wish Farms California Strawberries'; ad_price='$3.99'; size='16 oz'; regular=3.99; current_price=3.99; source_ad='x'; as_of='2026-08-18'; product_id=12345; base_price=5.99; marked_down=$true; store_department='Produce' }
  $c = Get-HyVeeCarryRow $src $src.item '2026-08-18' '2026-08-21'
  _T 'carry keeps base_price / marked_down / product_id / current_price' (($c.base_price -eq 5.99) -and ([bool]$c.marked_down) -and ($c.product_id -eq 12345) -and ($c.current_price -eq 3.99))
  $spl = Get-PriceSplit ([pscustomobject]$c) 'Hy-Vee'
  _T 'price-split types the carried row as a MARKDOWN with everyday = base_price (5.99), not everyday at 3.99' (($spl.sale_price -eq 3.99) -and ($spl.everyday_price -eq 5.99) -and ($spl.sale_kind -eq 'markdown'))
  # BRAD'S RULING: a carried row whose sale window has PASSED reverts to everyday at base_price.
  $src2 = [pscustomobject]@{ item='Hy-Vee Butter'; ad_price='$2.48'; size='16 oz'; regular=2.48; current_price=2.48; source_ad='x'; as_of='2026-08-21'; product_id=777; base_price=4.19; marked_down=$true; ad_from='2026-08-21'; ad_to='2026-08-23' }
  $e = Get-HyVeeCarryRow $src2 $src2.item '2026-08-21' '2026-08-24'
  $spl2 = Get-PriceSplit ([pscustomobject]$e) 'Hy-Vee'
  _T 'expired window -> everyday at base_price (4.19), sale fields dropped, reversion recorded' (($e.ad_price -eq '$4.19') -and ($null -eq $spl2.sale_price) -and ($spl2.everyday_price -eq 4.19) -and (-not $e.Contains('marked_down')) -and ($e.sale_expired_on -eq '2026-08-23'))
  # CLEAN TWIN: the same window still open stays a dated sale at the cut price with its everyday half intact.
  $o = Get-HyVeeCarryRow $src2 $src2.item '2026-08-21' '2026-08-22'
  $spl3 = Get-PriceSplit ([pscustomobject]$o) 'Hy-Vee'
  _T 'open window -> still the sale (2.48) with everyday 4.19 and the window carried' (($spl3.sale_price -eq 2.48) -and ($spl3.everyday_price -eq 4.19) -and ($o.ad_to -eq '2026-08-23'))
  # a plain everyday row carries as a plain everyday row (no invented discount)
  $src3 = [pscustomobject]@{ item='Hy-Vee Milk'; ad_price='$3.19'; size='gallon'; regular=3.19; current_price=3.19; source_ad='x'; as_of='2026-08-18'; product_id=5 }
  $p = Get-HyVeeCarryRow $src3 $src3.item '2026-08-18' '2026-08-21'
  _T 'an everyday row stays everyday (no discount invented)' (($null -eq (Get-PriceSplit ([pscustomobject]$p) 'Hy-Vee').sale_price) -and ([bool]$p.not_reverified))

  # ==================================================================================================
  # THE BUDGET WIPEOUT (live 2026-08-20 -> 2026-08-22, and these fixtures fail on the code that shipped
  # it). The capture-policy budget replaced the work list with today's slice, so ~1,547 of 1,554
  # products vanished from the OUTPUT FILE rather than merely going unasked. Every case below is about
  # one sentence: A BUDGET LIMITS WHAT WE ASK, NEVER WHAT WE WRITE.
  # A synthetic 240-product population, a stub store, no network and no disk.
  # ==================================================================================================
  $POP = 240
  $fixWork = New-Object System.Collections.ArrayList
  $fixUnits = @{}
  for ($i = 0; $i -lt $POP; $i++) {
    $prow = [pscustomobject]@{ store='Hy-Vee'; item=("Fixture Product $i"); ad_price='$2.50'; size='16 oz'
                               regular=2.5; current_price=2.5; source_ad='x'; as_of='2026-08-21'
                               product_id=(9000 + $i); base_price=3.99; marked_down=$true; store_department='Grocery' }
    [void]$fixWork.Add([pscustomobject]@{ name=([string]$prow.item); size='16 oz'; prow=$prow; pid=(9000 + $i); cid=("fix-$i") })
    $fixUnits["fix-$i"] = 'oz'
  }
  # The store, stubbed: one honest answer, at the shelf tag, on promotion. -Fetch is the ONLY door to the
  # network in Invoke-HyVeeWorkPass, which is what lets these fixtures drive the real pass.
  $fixFetch = {
    param($productId)
    [pscustomobject]@{
      sp = [pscustomobject]@{ price=2.29; basePrice=3.99; priceMultiple=1; basePriceMultiple=1; onSale=$true; isWeighted=$false }
      soldBy='OZ'; rawSize='16 oz'; tagPrice=2.29; ecomTagPrice=2.29; tagQty=1
    }
  }

  # --- the budget number itself: PRODUCTS / QUARTER, not the search-term count ----------------------
  $fixBudget = Get-HyVeeProductBudget -Population $POP -QuarterDays 90
  _T "budget comes from this lane's own PRODUCT population (240/90 = 3 a day)" ($fixBudget -eq 3)
  _T 'the live population gets 18 a day, not the 7 the TERM count produced (222-day rotation vs a 90-day carry)' ((Get-HyVeeProductBudget -Population 1554 -QuarterDays 90) -eq 18)
  _T 'moving the quarter moves the budget with it (the carry and the rotation cannot drift apart)' ((Get-HyVeeProductBudget -Population 1554 -QuarterDays 45) -eq 35)
  _T 'an expiring sale is EXTRA on top of the daily drip' ((Get-HyVeeProductBudget -Population 1554 -QuarterDays 90 -Expiries 2) -eq 20)
  # 1,000,000 / 90 = 11,112 a day, which 14 minutes at ~0.6s a product cannot serve; the ceiling wins.
  # At today's 1,554 it clamps nothing (18 << 1,400) - it exists so a future population cannot silently
  # promise a pull the clock stops halfway through.
  _T 'the wall-clock ceiling clamps a budget the 14-minute cap could never serve' ((Get-HyVeeProductBudget -Population 1000000 -QuarterDays 90 -MaxAskable 1400) -eq 1400)
  _T 'and it clamps nothing at the real population (18 a day, ceiling ~1,400)' ((Get-HyVeeProductBudget -Population 1554 -QuarterDays 90 -MaxAskable 1400) -eq 18)

  # --- (a) a budget smaller than the population still yields a row for EVERY product ----------------
  $fixSlots = New-Object System.Collections.Generic.List[object]
  for ($i = 0; $i -lt $POP; $i++) { [void]$fixSlots.Add([pscustomobject]@{ i = $i; w = $fixWork[$i] }) }
  $sliceA = Select-ExpiryFirstSlice -Items $fixSlots.ToArray() -Expiring @() -Budget $fixBudget -CursorStart 0 -KeyOf { param($s) @([string]$s.w.cid) }
  $askA = @{}; foreach ($s in @($sliceA.Items)) { $askA[[int]$s.i] = $true }
  $passA = Invoke-HyVeeWorkPass -Work $fixWork -AskIndex $askA -Fetch $fixFetch -Today '2026-08-22' -PrevDate '2026-08-21' -Units $fixUnits -SourceLabel 'fixture' -SleepMs 0
  _T "MUST-FIRE (a): a budget of $fixBudget against $POP products still writes a row for EVERY product" (@($passA.Deals).Count -eq $POP)
  _T "(a) the budget limited ASKING only: $($passA.Fresh) fresh + $($passA.BudgetSkipped) carried outside the slice = $POP" (($passA.Fresh -eq $fixBudget) -and ($passA.BudgetSkipped -eq ($POP - $fixBudget)) -and ($passA.Stale -eq ($POP - $fixBudget)))
  _T "(a) the run asked about exactly its budget and no more ($($passA.Attempted) request(s))" (($passA.Attempted -eq $fixBudget) -and ($passA.Answered -eq $fixBudget))
  $frA = @($passA.Deals | Where-Object { $_['item'] -eq 'Fixture Product 0' })[0]
  _T "(a) the asked slice is genuinely fresh (as_of today, at the price the store just gave)" (($frA['as_of'] -eq '2026-08-22') -and ($frA['ad_price'] -eq '$2.29') -and (-not $frA.Contains('not_reverified')))

  # --- (b) the carried remainder keeps the SHAPE of its last known price ----------------------------
  $carA = @($passA.Deals | Where-Object { $_['item'] -eq 'Fixture Product 100' })[0]
  _T '(b) a product outside the slice is carried through Get-HyVeeCarryRow: base_price, marked_down, product_id, current_price, honest as_of' (
      ($null -ne $carA) -and ($carA['base_price'] -eq 3.99) -and ([bool]$carA['marked_down']) -and
      ($carA['product_id'] -eq 9100) -and ($carA['current_price'] -eq 2.5) -and
      ($carA['as_of'] -eq '2026-08-21') -and ([bool]$carA['not_reverified']))
  # -and short-circuits: on the pre-fix code $carA is $null (the row is not in the file at all) and this
  # must report FAIL, not throw an exception that swallows every case after it.
  _T '(b) and price-split still reads that carried row as the markdown it is (everyday stays 3.99)' (
      ($null -ne $carA) -and ((Get-PriceSplit ([pscustomobject]$carA) 'Hy-Vee').everyday_price -eq 3.99))
  _T "(b) every carried product says WHY it was not asked, in capture_terms" (
      @($passA.CaptureTerms | Where-Object { $_['reason'] -match "outside today's capture-policy slice" }).Count -eq ($POP - $fixBudget))

  # --- (c) the wipeout guard does not trip on a budgeted run, and DID on the old one ----------------
  _T '(c) the THROTTLE-WIPEOUT guard does not trip on a budgeted run (240 rows vs a 240 high-water mark)' (
      -not (Test-HyVeeWipeout -RowCount @($passA.Deals).Count -PrevMax $POP))
  _T '(c) MUST-FIRE: the OLD behaviour - the work list REPLACED by the slice - trips it, which is exactly what quarantined the file for two days' (
      Test-HyVeeWipeout -RowCount $fixBudget -PrevMax $POP)
  _T '(c) the guard itself is untouched: a genuinely collapsed run is still refused' (
      (Test-HyVeeWipeout -RowCount 60 -PrevMax 240) -and (-not (Test-HyVeeWipeout -RowCount 121 -PrevMax 240)))

  # --- (d) the cursor moves, so tomorrow asks about DIFFERENT products ------------------------------
  $sliceB = Select-ExpiryFirstSlice -Items $fixSlots.ToArray() -Expiring @() -Budget $fixBudget -CursorStart ([int]$sliceA.CursorNext) -KeyOf { param($s) @([string]$s.w.cid) }
  $askB = @{}; foreach ($s in @($sliceB.Items)) { $askB[[int]$s.i] = $true }
  $passB = Invoke-HyVeeWorkPass -Work $fixWork -AskIndex $askB -Fetch $fixFetch -Today '2026-08-23' -PrevDate '2026-08-22' -Units $fixUnits -SourceLabel 'fixture' -SleepMs 0
  _T "(d) the next run asks a DIFFERENT slice (cursor 0 -> $($sliceA.CursorNext) -> $($sliceB.CursorNext))" (
      ([int]$sliceA.CursorNext -eq $fixBudget) -and (@($askA.Keys | Where-Object { $askB.ContainsKey([int]$_) }).Count -eq 0))
  _T '(d) and the second run also writes every product' ((@($passB.Deals).Count -eq $POP) -and ($passB.Fresh -eq $fixBudget))

  # --- (d) WHEN the cursor may move: on what the run ASKED, not on what it managed to write ---------
  _T '(d) a run that asked and was answered advances - even if the write is refused afterwards' (
      (Test-HyVeeCursorAdvance -Attempted 3 -Answered 3 -SliceSize 3 -SliceUnaskable 0).Advance)
  _T '(d) MUST-FIRE: a slice with NOTHING to ask advances past itself (the live deadlock: 7 unlinked products, re-picked every day since 2026-08-20)' (
      (Test-HyVeeCursorAdvance -Attempted 0 -Answered 0 -SliceSize 7 -SliceUnaskable 7).Advance)
  _T '(d) a run whose every request failed does NOT burn its slice (a dead endpoint is not a day of work)' (
      -not (Test-HyVeeCursorAdvance -Attempted 5 -Answered 0 -SliceSize 5 -SliceUnaskable 0).Advance)
  _T '(d) an askable slice we never got to (the wall-clock cap) is still owed its turn' (
      -not (Test-HyVeeCursorAdvance -Attempted 0 -Answered 0 -SliceSize 5 -SliceUnaskable 0).Advance)

  # --- (d) the cursor FILE: created on the first run, one advance a day, never on a replay ----------
  $ctmp = Join-Path ([IO.Path]::GetTempPath()) ('hvcur-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $ctmp -Force | Out-Null
  try {
    $realToday = (Get-Date).ToString('yyyy-MM-dd')
    $c1 = Step-HyVeeProductCursor -Next $fixBudget -From 0 -Today $realToday -OutDir $ctmp -Attempted $fixBudget -Answered $fixBudget -SliceSize $fixBudget -SliceUnaskable 0
    $cFile = Join-Path $ctmp 'hyvee-rotation-cursor.json'
    $onDisk = -1
    if (Test-Path $cFile) { $onDisk = [int](ConvertFrom-Json ([IO.File]::ReadAllText($cFile))).next_index }
    _T "(d) the cursor file is CREATED and carries the next index ($fixBudget) - it had never existed on the live tree" (
        ($c1.Advanced) -and ($onDisk -eq $fixBudget))
    $c2 = Step-HyVeeProductCursor -Next 99 -From $fixBudget -Today $realToday -OutDir $ctmp -Attempted $fixBudget -Answered $fixBudget -SliceSize $fixBudget -SliceUnaskable 0
    $stillDisk = [int](ConvertFrom-Json ([IO.File]::ReadAllText($cFile))).next_index
    _T '(d) a second run the same day does not rotate again (one product slice per day)' ((-not $c2.Advanced) -and ($stillDisk -eq $fixBudget))
    $c3 = Step-HyVeeProductCursor -Next 500 -From 0 -Today '2026-01-01' -OutDir $ctmp -Attempted 5 -Answered 5 -SliceSize 5 -SliceUnaskable 0
    _T '(d) a REPLAY (or a self-test on a frozen date) never moves the live rotation' (
        (-not $c3.Advanced) -and ([int](ConvertFrom-Json ([IO.File]::ReadAllText($cFile))).next_index -eq $fixBudget))
  } finally { Remove-Item -LiteralPath $ctmp -Recurse -Force -ErrorAction SilentlyContinue }

  # --- the unbudgeted pass is unchanged: ask about everything ---------------------------------------
  $passU = Invoke-HyVeeWorkPass -Work $fixWork -AskIndex $null -Fetch $fixFetch -Today '2026-08-22' -PrevDate '2026-08-21' -Units $fixUnits -SourceLabel 'fixture' -SleepMs 0
  _T 'unbudgeted (no capture policy loaded): every product is asked about and every product is written' (
      (@($passU.Deals).Count -eq $POP) -and ($passU.Fresh -eq $POP) -and ($passU.BudgetSkipped -eq 0))

  # --- (e) THE COVERAGE DENOMINATOR: today's slice, not the whole catalogue -------------------------
  # The ledger row this lane writes used to be eligible=every product holding an id / examined=refreshed
  # today. Under a budget that reads as a ~98% collapse EVERY DAY - a permanent finding nobody can act on.
  # These pin the pair that replaced it. See the coverage block near the end of this file.
  _T '(e) a healthy budgeted day is FULL coverage of its slice: eligible 3, answered 3 - not 3 of 240' (
      ((Get-HyVeeAskableCount -Work $fixWork -AskIndex $askA) -eq $fixBudget) -and ($passA.Answered -eq $fixBudget))
  # The live shape is mixed: 490 of the 1,554 rows in the 2026-08-21 file carry a product id, and they
  # CLUSTER, so what a slice can ask about is not its size.
  $mixWork = New-Object System.Collections.ArrayList
  for ($i = 0; $i -lt 20; $i++) {
    $mpid = 0; if ($i % 4 -eq 0) { $mpid = 500 + $i }
    [void]$mixWork.Add([pscustomobject]@{ name = ("Mixed $i"); size = ''; prow = $null; pid = $mpid; cid = ("mix-$i") })
  }
  _T '(e) unbudgeted, the denominator is every product holding an id (the pre-budget number, unchanged)' (
      (Get-HyVeeAskableCount -Work $mixWork -AskIndex $null) -eq 5)
  $mixAsk = @{}; foreach ($i in @(0, 1, 2, 3)) { $mixAsk[$i] = $true }
  _T "(e) budgeted, it is what TODAY'S SLICE may ask about - 1 of the 4 selected, NOT 5 of 20" (
      (Get-HyVeeAskableCount -Work $mixWork -AskIndex $mixAsk) -eq 1)
  $mixNone = @{}; foreach ($i in @(1, 2, 3)) { $mixNone[$i] = $true }
  # ~6% of 18-wide windows in the live rotation hold no linkable product at all. Eligible 0 is the truth on
  # that day - the lane verified no price - and the ledger calls it INERT, which is a finding worth having:
  # it is the no-discovery-path problem (1,064 of 1,554 rows carry no link) in its actionable form.
  _T '(e) a slice holding no linkable product is ZERO eligible, not a 98% collapse' (
      (Get-HyVeeAskableCount -Work $mixWork -AskIndex $mixNone) -eq 0)

  if ($fail -eq 0) { Write-Output 'SELF-TEST PASS'; exit 0 } else { Write-Output "SELF-TEST FAIL: $fail case(s)"; exit 1 }
}

$qFile = Join-Path $root 'hyvee\query-b64.txt'
if (-not (Test-Path $qFile)) { throw "missing $qFile (the persisted GraphQL document - it must be sent verbatim)" }
$QUERY = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(((Get-Content $qFile -Raw) -replace '\s','')))

$EP  = 'https://www.hy-vee.com/aisles-online/api/graphql/two-legged/getProductDetailsWithPrice'
# THE STORE, FROM THE ONE PLACE THAT KNOWS IT. Both identifiers move together or neither does.
. (Join-Path $root 'hyvee-store-lib.ps1')
$drift = Test-HyVeeStoreDrift -Root $root
if ($drift) { throw $drift }
$HVSTORE = Get-HyVeeStore -Root $root
if ($StoreId -le 0) { $StoreId = [int]$HVSTORE.store_id }
elseif (-not $LocationId) {
  throw ("-StoreId $StoreId was passed without -LocationId. storeId selects the PRICE and locationId " +
         "selects the SHELF TAG; querying one store's price against another store's tag manufactures " +
         "false disagreements (11 of 21 on 2026-08-21). Pass both, or pass neither and take the registry's.")
}
$LOC = if ($LocationId) { $LocationId } else { [string]$HVSTORE.location_id }
$STORE_LABEL = [string]$HVSTORE.label
# DERIVED, NEVER TYPED. Every row records which store it came from, and that label used to be a string
# literal sitting next to the request rather than built from it - so a store switch could move the query
# while the rows kept claiming the old store, and nothing downstream could tell.
$SRC_LABEL = Get-HyVeeSourceLabel -Root $root
$HDR = @{
  'content-type'              = 'application/json'
  'x-operation-name'          = 'getProductDetailsWithPrice'
  'apollographql-client-name' = 'aisles-online-web'
  'User-Agent'                = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148 Safari/537.36'
}

function Get-HyVeeStoreProduct([int]$productId) {
  $body = @{
    operationName = 'getProductDetailsWithPrice'
    query         = $QUERY
    variables     = @{
      productId = $productId; storeId = $StoreId; locationIds = @($LOC)
      pickupLocationHasLocker = $false; retailItemEnabled = $true
      targeted = $false; foodHealthScoreEnabled = $false
    }
  } | ConvertTo-Json -Depth 6 -Compress
  for ($a = 1; $a -le 2; $a++) {
    try {
      $r = Invoke-RestMethod -Uri $EP -Method Post -Headers $HDR -Body $body -TimeoutSec 20
      $sp = @($r.data.storeProducts.storeProducts) | Where-Object { [int]$_.storeId -eq $StoreId } | Select-Object -First 1
      if ($sp) {
        $ri = @($r.data.product.item.retailItems) | Select-Object -First 1
        # THE SHELF TAG, CARRIED OUT ALONGSIDE THE PRICE (2026-08-21). It comes from retailItems, which
        # locationIds selects, while the price comes from storeProducts, which storeId selects. Two
        # independent halves of one response is exactly what makes the cross-check below worth anything:
        # a puller bug that reached for the wrong price field cannot also move the tag.
        return [pscustomobject]@{
          sp = $sp
          soldBy = if ($ri) { [string]$ri.soldByUnitOfMeasure.code } else { '' }
          rawSize = ([string]$r.data.product.size).Trim()
          tagPrice = if ($ri -and $null -ne $ri.tagPrice) { [double]$ri.tagPrice } else { $null }
          ecomTagPrice = if ($ri -and $null -ne $ri.ecommerceTagPrice) { [double]$ri.ecommerceTagPrice } else { $null }
          tagQty = if ($ri -and $null -ne $ri.tagPriceQuantity) { [double]$ri.tagPriceQuantity } else { $null }
        }
      }
      return $null
    } catch { Start-Sleep -Milliseconds 500 }
  }
  return $null
}

# ---- what to refresh: our existing Hy-Vee rows (validated sizes) + any Hy-Vee product we hold a link for ----
$units = @{}
foreach ($c in (Get-Content (Join-Path $root 'commodities.json') -Raw | ConvertFrom-Json)) { $units[[string]$c.id] = [string]$c.unit }

$pd = (Get-Content (Join-Path $root 'product-urls.json') -Raw | ConvertFrom-Json).items
$idByName = @{}   # product name -> {productId, commodityId}
foreach ($p in $pd.PSObject.Properties) {
  $e = $p.Value.'Hy-Vee'
  if (-not ($e -and $e.url -and $e.name)) { continue }
  if (([string]$e.url) -notmatch '/p/(\d+)/') { continue }
  # NOT $pid - that is a read-only automatic variable in PowerShell and assigning to it throws.
  $prodId = [int]$Matches[1]
  # KEY BY NAME **AND SIZE**. Hy-Vee sells one name in several sizes (Spice World Minced Garlic is both
  # 32 oz/$8.99 and 4.5 oz/$3.49), and two commodities can legitimately link to those two different products.
  # Keyed by name alone, the first one won and the other product became invisible to this pull.
  $k = ([string]$e.name).ToLower().Trim() + '|' + ([string]$e.size).Trim()
  if (-not $idByName.ContainsKey($k)) { $idByName[$k] = [pscustomobject]@{ pid = $prodId; cid = [string]$p.Name; nm = ([string]$e.name).ToLower().Trim() } }
}

$prevF = Get-ChildItem (Join-Path $regDir 'hyvee-regular-*.json') -EA SilentlyContinue |
  Where-Object { $_.BaseName -match '^hyvee-regular-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending | Select-Object -First 1
$prevRows = @()
if ($prevF) { $prevRows = @((Get-Content $prevF.FullName -Raw | ConvertFrom-Json).deals) }
# The date the carried rows actually come from, for a row that has no as_of of its own. Read here rather
# than inside the pass so the pass stays free of the filesystem and its fixtures can state the date.
$prevDate = ''
if ($prevF -and ($prevF.BaseName -match '(\d{4}-\d{2}-\d{2})$')) { $prevDate = $Matches[1] }

# every product we want a price for: existing rows first (they carry the verified size), then link-only products
$work = New-Object System.Collections.ArrayList
$seen = @{}
# DEDUPE ON NAME **AND SIZE**, NOT NAME. $seen used to hold the bare name, so when Hy-Vee sells one name in two
# sizes the SECOND row was `continue`d straight out of the work list and never re-priced - it simply vanished
# from the next file. That is what collapsed 14 multi-size variants on the 2026-07-16 run (Dinty Moore Beef
# Stew 38oz -> only 15oz survived; Hy-Vee Mild Green Chiles 7oz -> only 4oz). A product the board prices
# silently disappearing from the catalogue is the "partial pull is an overwrite" failure wearing a new hat.
# Sixth instance of the name-keyed collapse family - see memory board-data-integrity.
$seenName = @{}
foreach ($r in $prevRows) {
  $nm = [string]$r.item
  $kn = $nm.ToLower().Trim()
  $k = $kn + '|' + ([string]$r.size).Trim()
  if ($seen.ContainsKey($k)) { continue }
  $seen[$k] = $true; $seenName[$kn] = $true
  # PowerShell 5.1 has no `if` EXPRESSION - "pid=(if(...){..}else{..})" is a parse error, not a ternary.
  $wpid = 0; $wcid = ''
  # THE ROW ALREADY KNOWS ITS OWN PRODUCT - USE IT. This only ever read the id back out of $idByName, i.e. out
  # of product-urls, so a row whose commodity has no stored link was re-priced as if we had never identified it:
  # 808 rows carried a product_id on 2026-07-15 but only 440 were refreshable today, and the other 368 were
  # written out not_reverified - carrying yesterday's price with no way to check it. The link is not the only
  # place a product identity lives; the row stamped one when it was last priced. Absence of a link is not
  # absence of knowledge (same lesson as the Family Fare carry-forward).
  if ($r.product_id) { $wpid = [int]$r.product_id }
  # a stored link still WINS: it is the product we publish a "See item" chip for, so it is what the price must
  # describe. Only the exact name+size link, or an unambiguous name, may override the row's own id.
  if ($idByName.ContainsKey($k)) { $wpid = [int]$idByName[$k].pid; $wcid = [string]$idByName[$k].cid }
  else {
    $byNm = @($idByName.Values | Where-Object { $_.nm -eq $kn })
    if ($byNm.Count -eq 1) { $wpid = [int]$byNm[0].pid; $wcid = [string]$byNm[0].cid }
  }
  [void]$work.Add([pscustomobject]@{ name=$nm; size=[string]$r.size; prow=$r; pid=$wpid; cid=$wcid })
}
foreach ($k in $idByName.Keys) {
  if ($seenName.ContainsKey($idByName[$k].nm)) { continue }
  $seenName[$idByName[$k].nm] = $true
  $e = $pd.($idByName[$k].cid).'Hy-Vee'
  [void]$work.Add([pscustomobject]@{ name=[string]$e.name; size=''; prow=$null; pid=$idByName[$k].pid; cid=$idByName[$k].cid })
}

# ---- THIRD SOURCE: ADJUDICATED CATALOGUE ADDITIONS -------------------------------------------------
# The two sources above are CLOSED SETS - yesterday's own file, and the Hy-Vee links in product-urls.json.
# A product in neither can never enter, which is why 1,538 rows is a fixed point rather than a bound and why
# 89.3% of the catalogue is absent. This is the only door in, and it opens exactly one way: a human ruled a
# discovery candidate to be the commodity (adjudicate-discovery.ps1 -Accept, which demands a named reviewer
# and written evidence), and that wrote hyvee-catalog-adds.json. Discovery on its own writes NOTHING here -
# ~14% of its candidates are wrong products and Hy-Vee publishes no department to test them against.
# An entry supplies an id and a name only. The PRICE comes from the store's API like every other row, and the
# SIZE is derived on the never-priced-before path below, because this file's own header is a list of the ways
# Hy-Vee's size field lies. A ruling gets a product asked about; it does not get to answer for the store.
$addF = Join-Path $root 'hyvee-catalog-adds.json'
$addWork = 0; $addDup = 0
if (Test-Path $addF) {
  $adoc = $null
  try {
    $araw = ((Get-Content $addF -Raw -Encoding UTF8) + '').Trim()
    if ($araw -ne '') { $adoc = $araw | ConvertFrom-Json }
  } catch { $adoc = $null }
  if ($null -eq $adoc) {
    # LOUD. An unreadable work list must not read like an empty one - that is the throttled-file-outsorts-
    # real-data failure, and here it would silently un-add every product a human already ruled on.
    Write-Warning ('Hy-Vee: hyvee-catalog-adds.json is present but UNREADABLE - every adjudicated catalogue addition is being skipped this run')
  } else {
    $seenPid = @{}
    foreach ($w in $work) { if ([int]$w.pid -gt 0) { $seenPid[[string][int]$w.pid] = $true } }
    foreach ($a in @($adoc.items)) {
      if (-not $a) { continue }
      $apid = 0
      if (-not [int]::TryParse((([string]$a.product_id).Trim()), [ref]$apid) -or $apid -le 0) {
        Write-Warning ('Hy-Vee: catalogue addition "' + [string]$a.name + '" has no usable productId - skipped (it can never be priced)')
        continue
      }
      $anm = ([string]$a.name).Trim()
      # Already in the work list under this id or this name: it is being refreshed, not missing.
      if ($seenPid.ContainsKey([string]$apid) -or ($anm -ne '' -and $seenName.ContainsKey($anm.ToLower()))) { $addDup++; continue }
      $seenPid[[string]$apid] = $true
      if ($anm -ne '') { $seenName[$anm.ToLower()] = $true }
      [void]$work.Add([pscustomobject]@{ name=$anm; size=''; prow=$null; pid=$apid; cid=[string]$a.commodity })
      $addWork++
    }
  }
}
if ($addWork -gt 0 -or $addDup -gt 0) {
  Write-Output ("Hy-Vee: {0} adjudicated catalogue addition(s) joined the work list ({1} already covered by the refresh)" -f $addWork, $addDup)
}
if ($Quick) { $work = @($work | Where-Object { $_.pid -gt 0 } | Select-Object -First 10) }

# ---- HOW MUCH WE MAY ASK THE STORE FOR TODAY --------------------------------------------------------
# The wall-clock cap is hoisted above the budget so the two numbers can argue with each other in ONE
# place. 14 minutes at roughly 0.6s a product (one request plus the 120ms courtesy sleep) is about 1,400
# products: the real ceiling on any budget, whatever the policy computes. A budget above it would be a
# budget that lies - it would promise a pull the clock stops halfway through.
$MAXMIN = 14
$HV_SEC_PER_PRODUCT = 0.6

# CAPTURE POLICY BUDGET (added 2026-08-20, repaired 2026-08-22). Hy-Vee re-verified 1010 products a run
# at baseline and the coverage ledger has it REGRESSED to 356 - a lane pulling as hard as it can until
# something upstream pushes back. Family Fare showed what that eventually costs: Freshop now answers its
# search with HTTP 400 / error_code 429. Asking for less, on a schedule, is the fix.
#
# TWO THINGS WERE WRONG WITH THE FIRST VERSION, AND BOTH ARE FIXED HERE.
#
#   1. IT LIMITED WRITING, NOT ASKING. It ended with `$work = @($hvSlice.Items)`, replacing the work list
#      with today's slice - and every row of the output file is built by looping over $work, so the ~1,547
#      products outside the slice were dropped from the FILE, not merely left unasked. 7 rows against
#      1,554; the THROTTLE-WIPEOUT guard quarantined the file and exited 2, which is exactly what it is
#      for. The principle this broke was already written down twelve lines further on, about the
#      wall-clock cap: THE CAP IS MEANT TO STOP US ASKING, NOT STOP US WRITING. A budget is the same kind
#      of thing. So the slice is now a set of INDICES into an unchanged work list, and a product outside
#      it is carried forward exactly as a capped product is - through Get-HyVeeCarryRow, in the file,
#      marked not_reverified.
#
#   2. IT WAS THE WRONG NUMBER. It took Get-CapturePlan's TermBudget, which counts SEARCH TERMS
#      (596/90 = 7 a day). This lane rotates by PRODUCT ID. See Get-HyVeeProductBudget: 7 a day is a
#      222-day rotation against a 90-day carry, so ~60% of rows would expire before their turn - the very
#      starvation the 90-day carry exists to prevent. The budget now comes from this lane's own
#      population with the quarter read from the policy: ceil(1554/90) = 18 a day, plus any expiring sale.
$askIndex = $null       # $null = unbudgeted, ask about everything
$hvBudget = 0
if (-not $Quick) {
  try {
    . (Join-Path $root 'capture-policy-lib.ps1')
    $hvPlan = Get-CapturePlan -Store 'Hy-Vee' -Today $todayS
    $hvAll = @($work); $hvN = $hvAll.Count
    $hvMaxAskable = [int][math]::Floor(($MAXMIN * 60.0) / $HV_SEC_PER_PRODUCT)
    $hvBudget = Get-HyVeeProductBudget -Population $hvN -QuarterDays ([int]$hvPlan.QuarterDays) -Expiries (@($hvPlan.SaleExpiries).Count) -MaxAskable $hvMaxAskable
    if ($hvBudget -gt 0 -and $hvN -gt $hvBudget) {
      # Rotate rather than always taking the head of the list, or the tail is never
      # re-verified and ages out silently - the exact shape of the Sam's 19-day file.
      $hvCur = 0
      $hvCurFile = Join-Path $OutDir 'hyvee-rotation-cursor.json'
      if (Test-Path $hvCurFile) { try { $hvCur = [int](ConvertFrom-Json ([IO.File]::ReadAllText($hvCurFile))).next_index } catch { } }
      # THE EXPIRING SALES GO FIRST (2026-08-22). The budget above counts one slot per sale reverting
      # today, but the slot was spent on whatever sat at the cursor; the product whose sale just ended
      # waited its quarter. A product answers to its commodity id (from product-urls) - and, for a row
      # with no stored link, to the commodity whose product-urls name matches its name. Brad's rule:
      # "reprice whenever an ad price / sale price / rollback price / instant-savings price drops off."
      $hvExpNames = @{}
      foreach ($xid in @($hvPlan.SaleExpiries)) {
        $xe = $pd.$xid.'Hy-Vee'
        if ($xe -and $xe.name) { $hvExpNames[([string]$xe.name).ToLower().Trim()] = [string]$xid }
      }
      # SLICE OVER POSITIONS, NOT OVER THE ITEMS THEMSELVES. Select-ExpiryFirstSlice returns the chosen
      # items, and the old code used that array AS the work list. Wrapping each product with its index
      # means the slice can only ever answer "which products do we ASK about today"; it is structurally
      # incapable of answering "which products EXIST", which is the question the founding bug let it
      # answer by accident.
      $hvSlots = New-Object System.Collections.Generic.List[object]
      for ($i = 0; $i -lt $hvN; $i++) { [void]$hvSlots.Add([pscustomobject]@{ i = $i; w = $hvAll[$i] }) }
      $hvSlice = Select-ExpiryFirstSlice -Items $hvSlots.ToArray() -Expiring @($hvPlan.SaleExpiries) -Budget $hvBudget -CursorStart $hvCur -KeyOf {
        param($s)
        $ks = @()
        if ($s.w.cid) { $ks += [string]$s.w.cid }
        $nk = ([string]$s.w.name).ToLower().Trim()
        if ($hvExpNames.ContainsKey($nk)) { $ks += $hvExpNames[$nk] }
        return $ks
      }
      $askIndex = @{}
      foreach ($s in @($hvSlice.Items)) { $askIndex[[int]$s.i] = $true }
      if ($hvSlice.Prepended -gt 0) {
        Write-Output ("Hy-Vee: " + $hvSlice.Prepended + " product(s) for " + @($hvPlan.SaleExpiries).Count + " expiring sale(s) placed at the FRONT of today's slice: " + ((@($hvSlice.Items | Select-Object -First $hvSlice.Prepended) | ForEach-Object { $_.w.name }) -join '; '))
      }
      # Advance by the rotation positions actually walked, not the whole budget: the expiry
      # products at the front were not rotation positions (Select-ExpiryFirstSlice reports it).
      # The COMMIT is below, beside the run's own account of what it asked - see there for why it no
      # longer waits for the file to land.
      $script:HvCursorNext = [int]$hvSlice.CursorNext
      $script:HvCursorFile = $hvCurFile
      $script:HvCursorFrom = $hvCur
      Write-Output ("Hy-Vee: capture-policy budget = $hvBudget product(s) to ASK about today (rotation $hvCur/$hvN; quarter $($hvPlan.QuarterDays)d; every one of the $hvN products is still written)")
    }
  } catch {
    Write-Warning ("Hy-Vee: capture-policy did not load (" + $_.Exception.Message + ") - running unbudgeted this pass")
  }
}

$refreshable = @($work | Where-Object { $_.pid -gt 0 }).Count
$askableToday = Get-HyVeeAskableCount -Work $work -AskIndex $askIndex
Write-Output ("Hy-Vee: " + @($work).Count + " products (" + $refreshable + " refreshable via GraphQL; " + (@($work).Count - $refreshable) + " have no link so their price cannot be re-verified; " + $askableToday + " will be asked about today)")

# THE PASS ITSELF LIVES IN Invoke-HyVeeWorkPass, ABOVE -SelfTest. It was inline here until 2026-08-22,
# which meant the code that decides what the FILE contains had no fixtures at all - and that is exactly
# where the budget wipeout hid for two days. -Fetch is the only door to the network, so the fixtures
# drive this exact text with a stub.
$startT = Get-Date
$pass = Invoke-HyVeeWorkPass -Work $work -AskIndex $askIndex -Today $todayS -PrevDate $prevDate `
  -Units $units -SourceLabel $SRC_LABEL -MaxMinutes $MAXMIN -StartTime $startT -SleepMs 120 `
  -Fetch { param($productId) Get-HyVeeStoreProduct ([int]$productId) }

$deals = $pass.Deals
$captureTerms = $pass.CaptureTerms
$sizeConflicts = $pass.SizeConflicts
$tagRefusedRows = $pass.TagRefusedRows
$fresh = $pass.Fresh; $fail = $pass.Fail; $markdown = $pass.Markdown; $stale = $pass.Stale
$newProd = $pass.NewProd; $mismatch = $pass.Mismatch; $capSkipped = $pass.CapSkipped
$budgetSkipped = $pass.BudgetSkipped; $tagRefused = $pass.TagRefused
$multRefused = $pass.MultRefused; $multDescriptive = $pass.MultDescriptive

Write-Output ("Hy-Vee: " + $fresh + " refreshed today (" + $markdown + " marked down), " + $newProd + " newly priced, " + $stale + " not re-verified, " + $mismatch + " REFUSED (productId is a different size than our row), " + $capSkipped + " never asked (wall-clock cap), " + $budgetSkipped + " outside today's budget slice (carried, not dropped), " + $fail + " failed")

# THE ROTATION COMMIT, AND IT NOW HAPPENS HERE - BEFORE THE WRITE, NOT AFTER IT (2026-08-22).
# It used to be the last thing the run did, on the rule that "the cursor is a promise that those products
# were actually re-verified, so it must never be written by a run that did not finish". That rule is right
# about the direction of the danger and wrong about the event to hang it on, and the difference cost two
# days of frozen Hy-Vee prices: the budget bug collapsed the file, the THROTTLE-WIPEOUT guard quarantined
# it and exited 2 twelve lines before the commit, so the cursor was NEVER CREATED. Every run then re-read
# 0, took the same seven products, and reported "0 refreshed, 7 not re-verified" forever. A refused write
# refused the rotation as well, and that is what turned a bad day into a deadlock.
# So the cursor now hangs on WHAT THE RUN ASKED, which is the thing the cursor is actually about, and the
# judgement lives in Test-HyVeeCursorAdvance in capture-policy-lib beside the term-cursor guards: a run
# that issued requests and got nothing back does NOT burn its slice, while a run whose whole slice had
# nothing to ask does advance past it. Replay and one-per-day are enforced there too.
if ($null -ne $script:HvCursorNext) {
  try {
    . (Join-Path $root 'capture-policy-lib.ps1')
    $cs = Step-HyVeeProductCursor -Next $script:HvCursorNext -From $script:HvCursorFrom -Today $todayS -OutDir $OutDir `
      -Attempted $pass.Attempted -Answered $pass.Answered -SliceSize $pass.SliceSize -SliceUnaskable $pass.SliceUnaskable
    if ($cs.Advanced) { Write-Output ("Hy-Vee: rotation cursor advanced #$($cs.From) -> #$($cs.To) ($($cs.Reason))") }
    else { Write-Warning ("Hy-Vee: rotation cursor HELD at #$($script:HvCursorFrom) - " + $cs.Reason) }
  } catch {
    Write-Warning ("Hy-Vee: the rotation cursor could not be written (" + $_.Exception.Message + ") - the next run re-verifies this same slice; nothing is lost.")
  }
}
# Reported on its own line, and only when non-zero, so the divisor class stays VISIBLE. The bug it guards
# against published a price no shopper could pay and survived every internal check for as long as nobody
# looked; a silent counter would recreate exactly that.
if ($multDescriptive -gt 0 -or $multRefused -gt 0) {
  Write-Output ("Hy-Vee: priceMultiple reconciliation - " + $multDescriptive + " row(s) treated the multiple as DESCRIPTIVE (price already per-item, price == basePrice), " + $multRefused + " row(s) REFUSED (divided price landed under 40% of the regular price, so the divisor is more likely wrong than the promo is deep)")
# THE SHELF-TAG REFUSALS, NAMED. A count alone would have hidden what made this worth building: the two
# rows it caught first were the same brand, both phantom markdowns of 40%+ off a tag that had not moved.
Write-Output ("Hy-Vee: shelf-tag cross-check - " + $tagRefused + " row(s) REFUSED for pricing BELOW the store's own tagPrice (a price the till will not honour)")
foreach ($x in $tagRefusedRows) {
  Write-Output ("  below-tag: [{0}] '{1}' price {2} vs shelf tag {3}" -f $x.product_id, $x.item, $x.price, $x.tag)
}
}

# COVERAGE. THE DENOMINATOR CHANGED ON 2026-08-22 AND THE NUMBERS BELOW ARE NOT COMPARABLE TO THE OLD ONES.
#
# It used to be Eligible = every product we hold a productId for (~535) and Examined = $fresh, the products
# refreshed today. That was the right pair while this lane re-verified EVERYTHING it could, every day, and
# it measured 1,006-1,065 for a month. The capture-policy budget made it a lie: the lane now deliberately
# asks about ceil(1554/90) = 18 products a day (see Get-HyVeeProductBudget), of which only those holding a
# link can be asked at all - median 3, measured over a full 90-day rotation of the 2026-08-21 file. Against
# a 1,010 baseline that is a ~98% collapse EVERY MORNING: a permanent finding nobody can act on, which is
# the ledger's own founding failure - a confident answer about nothing - pointing the other way. A watcher
# that cries every day is a watcher that gets ignored, and then it is watching nothing.
#
# THE HONEST DENOMINATOR FOR A BUDGETED LANE IS TODAY'S SLICE:
#     Eligible = the products this run was ALLOWED to ask about today and holds an id to ask with
#     Examined = the ones Aisles Online actually came back with a usable offer for
# so a healthy budgeted day records 3 of 3, not 3 of 535. The two numbers separate only when something
# stopped us ASKING (the wall-clock cap) or stopped the store ANSWERING (GraphQL refusing), which is
# precisely the truncation the ledger was put on this puller to catch. Because the slice legitimately
# swings 0-18 from one day to the next, that separation is watched as a RATIO - min_ratio in
# coverage-baseline.json - and not as an absolute count: no fixed floor can tell a throttled day from an
# ordinary one in that range, and a fixed floor is exactly what produced the permanent finding above.
#
# EXAMINED IS Answered, NOT Fresh. A row whose answer was REFUSED - a size that disagrees with ours, a
# price below the store's own shelf tag - WAS examined; we looked at it and rejected what we saw. Counting
# a refusal as an unexamined row would report a coverage collapse on a day the accuracy checks did their job.
#
# Wrapped in its own try/catch inside coverage-lib, which is function-scoped, so a missing or broken ledger
# can never take the price pull down with it.
# -Quick MUST NOT RECORD. It caps the work list at 10 products and writes to hyvee-quick-test.json instead of
# the real capture, but the coverage ledger is a single shared file: a -Quick run would stamp a smoke test's
# numbers over the real lane's row.
try {
  $covLib = Join-Path $root 'coverage-lib.ps1'
  if ((-not $Quick) -and (Test-Path $covLib)) {
    . $covLib
    $covExamined = [int]$pass.Answered
    # The detail line carries the whole account, because a finding is only actionable if it says which of
    # the three ways to examine nothing actually happened: no slice, no asking, or no answer.
    $covDetail = ("Hy-Vee products in TODAY'S capture-policy slice that Aisles Online answered for: budget " +
      $hvBudget + ", asked " + $pass.Attempted + ", answered " + $covExamined + ", " + $capSkipped +
      " never asked (wall-clock cap), " + $budgetSkipped + " outside today's slice and carried forward. " +
      $refreshable + " of " + @($work).Count + " products hold an id at all - that whole-catalogue number is " +
      "NOT the denominator any more; see coverage-baseline.json for why.")
    if ($covExamined -le 0 -and $askableToday -gt 0) {
      Write-CoverageRecord -Check 'pull-regular-hyvee' -OutDir $OutDir -Eligible $askableToday -Examined $covExamined -Detail $covDetail -Blind
    } else {
      Write-CoverageRecord -Check 'pull-regular-hyvee' -OutDir $OutDir -Eligible $askableToday -Examined $covExamined -Detail $covDetail
    }
  }
} catch { }
foreach ($sc in $sizeConflicts) { Write-Warning ("  size conflict, refresh refused: " + $sc) }

# THROTTLE-WIPEOUT GUARD: never let a broken run clobber good data.
# ITS RULE LIVES IN Test-HyVeeWipeout, above -SelfTest, so the fixtures read the same text the run does.
# It was NOT relaxed when the capture-policy budget started collapsing the file to 7 rows on 2026-08-22 -
# it was doing its job, and it is the only reason two days of budget-collapsed files did not overwrite
# 1,554 good rows with 7. The fix was upstream: stop handing it a collapsed file.
$prevMax = 0
foreach ($pf in (Get-ChildItem (Join-Path $regDir 'hyvee-regular-*.json') -EA SilentlyContinue |
    Where-Object { $_.BaseName -match '^hyvee-regular-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending | Select-Object -First 4)) {
  try { $c = @((Get-Content $pf.FullName -Raw | ConvertFrom-Json).deals).Count; if ($c -gt $prevMax) { $prevMax = $c } } catch {}
}
if ((-not $Quick) -and (Test-HyVeeWipeout -RowCount $deals.Count -PrevMax $prevMax)) {
  $qDir = Join-Path $OutDir 'throttled'
  if (-not (Test-Path $qDir)) { New-Item -ItemType Directory -Path $qDir -Force | Out-Null }
  $pfile = Join-Path $qDir ("hyvee-$todayS.throttled.json")   # NOT out\regular - see guards invariant 7
  ([ordered]@{ store='Hy-Vee'; week_of=$todayS; price_type='everyday'; throttled=$true; deal_count=$deals.Count; deals=$deals.ToArray() } | ConvertTo-Json -Depth 6) | Set-Content $pfile -Encoding UTF8
  Write-Warning ("Hy-Vee: THROTTLE-WIPEOUT guard tripped - only " + $deals.Count + " rows vs " + $prevMax + " last time. NOT overwriting.")
  # EXIT 2, NOT a bare return. A bare `return` at script scope exits with code ZERO, so this - the single
  # worst outcome this puller has, the run collapsing below half its normal size and being quarantined to
  # out\throttled\ instead of written - reported SUCCESS to its caller. check-ad-cycles piped the whole thing
  # to Out-Null and logged 'Hy-Vee everyday refreshed (current shelf price, Omaha #01)' either way. This
  # script had no `exit` statement anywhere, so there was no exit code to read even if the caller had looked.
  exit 2
}

$file = if ($Quick) { Join-Path $OutDir 'hyvee-quick-test.json' } else { Join-Path $regDir ("hyvee-regular-$todayS.json") }
$out = [ordered]@{
  store='Hy-Vee'; week_of=$todayS; price_type='everyday'; price_mode='in-store'; mode_verified=$todayS
  coverage_mode='partial'
  source=("Hy-Vee Aisles Online GraphQL storeProducts.price - the CURRENT shelf price at storeId $StoreId ($STORE_LABEL), cross-checked against retailItems.ecommerceTagPrice at the matching pickup location. NOT basePrice (the regular price) and NOT ssrPricing (a different store).")
  size_policy='sizes are OUR verified ones, not Hy-Vee''s - their size field mixes totals, single units of a multipack, and mislabelled units'
  # cap_skipped is ADDITIVE and sits beside the counts that were already here. Every consumer of this file
  # reads .deals or a named top-level field (guards 9/10, generate-board-overrides, refresh-hyvee-links,
  # resolve-hyvee-links - checked, none enumerate the key set), so a new sibling key is safe. It is recorded
  # in the FILE and not just on the console because the console is exactly where this information kept going
  # to die.
  deal_count=$deals.Count; refreshed_today=$fresh; marked_down=$markdown; newly_priced=$newProd; not_reverified=$stale; cap_skipped=$capSkipped; failed=$fail
  # budget_skipped is the other half of cap_skipped: products we CHOSE not to ask about today because the
  # capture-policy budget did not select them. Recorded, like cap_skipped, because "not asked" and "not
  # present" must never be the same number again - that conflation is what froze this file for two days.
  budget_skipped=$budgetSkipped; ask_budget=$hvBudget; asked=$pass.Attempted; answered=$pass.Answered
  multiple_descriptive=$multDescriptive; multiple_refused=$multRefused
  capture_terms=$captureTerms.ToArray()
  deals=$deals.ToArray()
}
($out | ConvertTo-Json -Depth 6) | Set-Content $file -Encoding UTF8
Write-Output ("Hy-Vee everyday prices -> " + $file)

# THE ROTATION COMMIT USED TO BE HERE, and this note is left in its place on purpose. It was the last
# statement in the file, gated on the everyday file existing, and it never ran once - the wipeout guard
# above exits 2 before reaching it, which is precisely what happened on 2026-08-21 and 2026-08-22 and is
# why hyvee-rotation-cursor.json had never been created. The commit now sits beside the run's own account
# of what it ASKED, above the coverage record; see the comment there. Do not re-add a second one: two
# commit sites is how a cursor advances twice in a day, which the one-slice-per-day guard would then have
# to catch instead of the code simply not doing it.

# THE EXPIRY LEDGER MOVES WITH THE CURSOR (2026-08-22). Hy-Vee's slice of expiring sales is
# now CAPPED (104 of its windows revert on 2026-08-24 against a 120-product cap), and
# build-sale-windows now keeps an unprocessed window instead of pruning it by date - so
# something has to say which ones were actually done, or the whole backlog is re-queued
# forever. Written only when the everyday file landed, for the same reason the cursor is:
# a run that fetched nothing must repeat its slice, not retire it.
if (Test-Path $file) {
  try {
    . (Join-Path $root 'capture-policy-lib.ps1')
    $mk = Set-SaleExpiryProcessed -Store 'Hy-Vee' -Today $todayS -OutDir $OutDir -Landed $true
    if ($mk.Marked -gt 0) { Write-Output ("Hy-Vee: recorded " + $mk.Marked + " sale re-price(s) in sale-windows.json") }
  } catch { Write-Warning ("Hy-Vee: sale-expiry ledger not updated (" + $_.Exception.Message + ") - those re-prices stay owed and lead tomorrow's slice") }
}

