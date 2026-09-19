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
# -DryRun (2026-09-19) builds the work list, recovers product ids, orders and budgets today's asks and runs the
# pass against a stub store that answers nothing - so every count below is printed - then exits 0 before the
# first request, the cursor, the coverage ledger or any file write. It is how a change to this lane is checked
# against real seeded data without touching the store or grocery\out.
param([string]$OutDir = "", [int]$StoreId = 0, [string]$LocationId = "", [switch]$Quick, [switch]$DryRun, [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $root 'omaha-time.ps1')
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
$regDir = Join-Path $OutDir 'regular'
if ((-not $DryRun) -and (-not $SelfTest) -and (-not (Test-Path $regDir))) { New-Item -ItemType Directory -Path $regDir -Force | Out-Null }
$todayS = Get-OmahaDateKey
. (Join-Path $root 'pu-lib.ps1')   # shared per-unit math - used to prove a productId really is our row's size
# The store identity AND Get-HyVeeRowStoreId, loaded here rather than beside the first request so the carry row
# and the fixtures below read the same store-stamp rule the run does.
. (Join-Path $root 'hyvee-store-lib.ps1')

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
# requeued / requeued_on / product_id_recovered_from (2026-09-19) travel with the carry so a shelf-tag re-queue
# and a recovered product id survive every day the product is not re-asked; see Invoke-HyVeeWorkPass.
$script:HvCarryKeys = @('current_price', 'base_price', 'marked_down', 'product_id', 'price_multiple',
                        'ad_from', 'ad_to', 'store_department', 'store_department_group', 'store_category',
                        'requeued', 'requeued_on', 'product_id_recovered_from')
function Get-HyVeeCarryRow($prow, [string]$name, [string]$asOf, [string]$today) {
  # store_id: THE STORE THE PRICE WAS READ AT, NEVER THE STORE THIS RUN ASKS. The carry used to copy source_ad
  # and nothing else about the store, so 202 of 462 Hy-Vee cells on the 2026-09-17 board still spoke for
  # Omaha #01 four weeks after the switch to #02, with no field anything could refuse on. A carried row keeps
  # its own stamp; a pre-stamp row gets the storeId its source_ad text names, or '' (unknown) - see
  # Get-HyVeeRowStoreId. Nothing here drops a row for its store: compare-deals' admission gate refuses a
  # store_id that is not the pinned identity, and the re-verify order asks those products first.
  $row = [ordered]@{
    store='Hy-Vee'; item=$name; ad_price=[string]$prow.ad_price; size=[string]$prow.size; regular=$prow.regular
    source_ad=[string]$prow.source_ad; store_id=(Get-HyVeeRowStoreId $prow); as_of=$asOf; not_reverified=$true
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

      THE SECOND DEFECT (2026-09-19, PLAN-board-accuracy). That repair derived the budget from the
      QUARTER: ceil(1554 / 90) = 18 a day, a 90-day cycle, and the carry kept a row alive for exactly as
      long. Nothing measured what a 90-day-old price does to accuracy; the blind verification of the
      2026-09-17 board found the defect rate climbing with the age of the price, and on that board 202 of
      462 Hy-Vee cells still came from the store retired on 2026-08-21, because at 18 a day the switch
      would have taken a full quarter to reach every product.

      So the budget now comes from the FRESHNESS RULE in capture-policy-lib: every product this lane can
      ask about is re-read inside RotationDays (14), so the drip is ceil(askable / RotationDays), capped
      by the store's call cap (Get-StoreCallCap 'Hy-Vee', 120 product ids). Population is the ASKABLE
      count - products holding a product id - because a product with no id costs no request and can never
      be re-read however big the budget is; counting it would spend slots on nothing.

      Expiring sales take only the ROOM LEFT under the cap once the rotation is reserved. They used to be
      extra on top, which was harmless at 18 a day; at 111 a day an uncapped expiry list would push the
      rotation off the end of the cap, and the oldest-first order (Get-HyVeeAskOrder) is what makes a
      squeezed day recoverable, not a reason to squeeze it.

      MaxAskable is the wall-clock ceiling. The run stops ASKING at $MAXMIN minutes whatever the budget
      says, so a budget bigger than that is a budget that lies: it would report N products asked and
      quietly carry the tail. At ~0.6 s a product the ceiling is ~1,400, so it clamps nothing at 120.
  #>
  param([int]$Population, [int]$RotationDays = 14, [int]$Cap = 0, [int]$Expiries = 0, [int]$MaxAskable = 0)
  if ($Population -le 0) { return 0 }
  if ($RotationDays -le 0) { throw "RotationDays must be positive (got $RotationDays): it comes from capture-policy-lib's FRESHNESS RULE" }
  $rot = [int][math]::Ceiling($Population / [double]$RotationDays)
  if ($rot -lt 1) { $rot = 1 }
  $b = $rot
  if ($Expiries -gt 0) {
    $room = if ($Cap -gt 0) { [math]::Max(0, $Cap - $rot) } else { $Expiries }
    $b += [int][math]::Min($Expiries, $room)
  }
  if ($Cap -gt 0 -and $b -gt $Cap) { $b = $Cap }
  if ($MaxAskable -gt 0 -and $b -gt $MaxAskable) { $b = $MaxAskable }
  if ($b -gt $Population) { $b = $Population }
  return $b
}

function Test-HyVeeCapacity {
  <#
    .SYNOPSIS Can this lane re-read every askable product inside RotationDays without passing its call cap?
    .DESCRIPTION The same arithmetic test-capture-policy.ps1 asserts for the term-rotation stores, for the one
                 store that rotates by PRODUCT ID and therefore is not in that table. Ok = Need <= Cap. A
                 shortfall is SPOKEN with its arithmetic every run; it is never silently clamped, because a
                 clamped budget is a rotation slower than the publish limit wearing a normal day's numbers.
  #>
  param([int]$Population, [int]$RotationDays = 14, [int]$Cap = 120)
  $need = if ($Population -le 0) { 0 } else { [int][math]::Ceiling($Population / [double]$RotationDays) }
  $over = [math]::Max(0, $need - $Cap)
  [pscustomobject]@{
    Population = $Population; RotationDays = $RotationDays; Need = $need; Cap = $Cap; Over = $over
    Ok = ($need -le $Cap)
    Why = if ($need -le $Cap) { '' } else { "$Population askable products / $RotationDays days = $need a day, $over over the Hy-Vee call cap of $($Cap): the tail cannot be re-read inside the publish limit" }
  }
}

function Get-HyVeeAskOrder {
  <#
    .SYNOPSIS Which products does today's run ask about, in what order? OLDEST FIRST, the wrong store first.
    .DESCRIPTION
      THE CURSOR THIS REPLACES (2026-09-19). The lane walked a rotation cursor: today's slice was the next N
      positions in work-list order. A missed day did not heal - every product's turn was simply pushed back
      one day - and the order had no idea which prices were oldest or which were read at the store the board
      no longer speaks for. After the 2026-08-21 switch it re-read Omaha #01 rows in whatever order the file
      happened to hold them, 18 a day.

      Ranks, lowest first; within a rank the OLDEST as_of first ('' - a product never priced - is oldest of
      all), then work order so two runs over the same list pick the same products:
        0  a product whose commodity has a sale reverting today (Brad: "reprice whenever an ad price ...
           drops off"), exactly as the old expiry-first slice did
        1  a row whose store_id is not the pinned store, or unstamped, or never priced; and a row
           re-queued by a shelf-tag refusal. These are the rows the board's admission gate refuses, so
           asking them first is what completes the Omaha #02 migration in days instead of a quarter
        2  every other product, oldest first
      A product with no product id is never in the order: it cannot be asked (see the -DryRun report for
      how many there are). Pure: no disk, no network, so the fixtures below drive this exact text.
    .OUTPUTS Index (hashtable work index -> $true, the AskIndex Invoke-HyVeeWorkPass takes), Order (the
             chosen indices in ask order), and the rank counts inside the slice.
  #>
  param([Parameter(Mandatory)][AllowEmptyCollection()]$Work, [int]$Budget, [string]$TargetStoreId,
        [hashtable]$ExpiringIdx = @{})
  $cands = New-Object System.Collections.Generic.List[object]
  $i = -1
  foreach ($w in $Work) {
    $i++
    if ([int]$w.pid -le 0) { continue }
    $asOf = ''; $sid = ''; $req = $false
    if ($w.prow) {
      $asOf = [string]$w.prow.as_of
      $sid = Get-HyVeeRowStoreId $w.prow
      $req = [bool]([string]$w.prow.requeued)
    }
    $rank = 2
    if ($ExpiringIdx.ContainsKey($i)) { $rank = 0 }
    elseif ($req -or (-not $sid) -or (-not [string]::Equals($sid, $TargetStoreId, [StringComparison]::Ordinal))) { $rank = 1 }
    [void]$cands.Add([pscustomobject]@{ i = $i; rank = $rank; asOf = $asOf; off = (-not [string]::Equals($sid, $TargetStoreId, [StringComparison]::Ordinal)) })
  }
  # Ordinal-safe: as_of is yyyy-MM-dd or '', and '' sorts first under any comparer.
  $sorted = @($cands.ToArray() | Sort-Object -Property @{ Expression = { $_.rank } }, @{ Expression = { $_.asOf } }, @{ Expression = { $_.i } })
  $take = [math]::Min([math]::Max(0, $Budget), $sorted.Count)
  $idx = @{}; $order = New-Object System.Collections.Generic.List[int]
  $nExp = 0; $nOff = 0
  for ($k = 0; $k -lt $take; $k++) {
    $c = $sorted[$k]
    $idx[[int]$c.i] = $true; [void]$order.Add([int]$c.i)
    if ($c.rank -eq 0) { $nExp++ }
    if ($c.off) { $nOff++ }
  }
  $offAll = @($sorted | Where-Object { $_.off }).Count
  return [pscustomobject]@{ Index = $idx; Order = $order.ToArray(); Askable = $sorted.Count
    ExpiringInSlice = $nExp; OffTargetInSlice = $nOff; OffTargetAskable = $offAll }
}

function Get-HyVeeHistoryProductIds {
  <#
    .SYNOPSIS Recover a product id for a row that lost its own, from this lane's own earlier files.
    .DESCRIPTION
      WHY (2026-09-19). 1,006 of 1,541 rows in the 2026-09-18 file had no product id to ask with, so no
      budget, however large, could ever re-read them. 744 of them are the same name and size as a row an
      EARLIER hyvee-regular file priced by product id through this lane's own GraphQL; the id was lost by
      the pre-2026-08-22 carry, which copied ad_price and nothing else (see Get-HyVeeCarryRow's header).
      This hands those ids back. It is not a search: the id is the one this lane itself already asked the
      store with, for a row of the same name AND size.
      A key that two files give DIFFERENT ids is not recovered - two ids for one name and size means we
      cannot say which one the row is, and guessing writes one product's price onto another. Counted, never
      guessed. The size cross-check in Invoke-HyVeeWorkPass still judges every recovered id when it is asked.
    .PARAMETER Files  the hyvee-regular files to read, newest first (the caller bounds them to MaxCarryDays)
    .PARAMETER Needed hashtable of 'name-lowercased|size' -> $true
    .OUTPUTS Map (key -> @{ pid; file_date }), Conflicts (keys with two ids), Scanned (files read), Unreadable
  #>
  param($Files, [hashtable]$Needed)
  $map = @{}; $seenIds = @{}; $scanned = 0; $unreadable = 0
  if ($Needed.Count -gt 0) {
    foreach ($f in @($Files)) {
      $fd = ''
      if ([string]$f.Name -match '(\d{4}-\d{2}-\d{2})') { $fd = $Matches[1] }
      $doc = $null
      try { $doc = ConvertFrom-Json ([IO.File]::ReadAllText([string]$f.FullName)) } catch { $unreadable++; continue }
      $scanned++
      foreach ($r in @($doc.deals)) {
        if (-not $r -or -not $r.product_id) { continue }
        $k = ([string]$r.item).ToLower().Trim() + '|' + ([string]$r.size).Trim()
        if (-not $Needed.ContainsKey($k)) { continue }
        $rp = 0
        if (-not [int]::TryParse(([string]$r.product_id), [ref]$rp) -or $rp -le 0) { continue }
        if (-not $seenIds.ContainsKey($k)) { $seenIds[$k] = @{} }
        $seenIds[$k][[string]$rp] = $true
        if (-not $map.ContainsKey($k)) { $map[$k] = [pscustomobject]@{ pid = $rp; file_date = $fd } }
      }
    }
  }
  $conflicts = 0
  foreach ($k in @($seenIds.Keys)) {
    if ($seenIds[$k].Count -gt 1) { $conflicts++; if ($map.ContainsKey($k)) { $map.Remove($k) } }
  }
  return [pscustomobject]@{ Map = $map; Conflicts = $conflicts; Scanned = $scanned; Unreadable = $unreadable }
}

function Test-HyVeeCarryExpired {
  <#
    .SYNOPSIS Is a carried row past MaxCarryDays? Age strictly greater than the limit expires, as in every
              other lane (pull-regular-bakers-api, pull-regular-familyfare): exactly 90 days is kept.
    .DESCRIPTION This lane never expired a carried row at all, so rows read 2026-07-14 were still being written
                 on 2026-09-18. An unparseable date is not judged here (returns $false) and is counted by the
                 caller; the board's publish-age gate withholds it either way.
  #>
  param([string]$AsOf, [string]$Today, [int]$MaxCarryDays)
  if ($MaxCarryDays -le 0) { return $false }
  $a = $null; $t = $null
  try { $a = [datetime]::ParseExact($AsOf, 'yyyy-MM-dd', $null); $t = [datetime]::ParseExact($Today, 'yyyy-MM-dd', $null) } catch { return $false }
  return (($t - $a).TotalDays -gt $MaxCarryDays)
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

    .PARAMETER Work       the full work list, every product (the order asked is Get-HyVeeAskOrder's, via AskIndex)
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
    # THE STORE THAT ANSWERS $Fetch, stamped on every fresh row as store_id. Mandatory and non-empty: a fresh
    # row that cannot say where it was read is the defect this stamp exists to end.
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$StoreId,
    # Carried rows whose as_of is more than this many days before -Today are DROPPED and counted (0 = never).
    [int]$MaxCarryDays = 0,
    [double]$MaxMinutes = 14,
    $StartTime = $null,
    [int]$SleepMs = 0
  )
  if ($null -eq $StartTime) { $StartTime = Get-Date }
  $expired = 0; $undatedCarry = 0; $requeued = 0; $pidRecoveredStamped = 0
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
    $tagRequeue = $false
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
          # angle we already measure, so a warning nobody reads would be the same as shipping it.
          # THE REFUSAL MUST NOT DELETE THE PRODUCT (2026-09-19). It used to `continue` here with no row at
          # all, and the work list is rebuilt from yesterday's file, so a refused product left the catalogue
          # for good unless a link happened to name it: Hy-Vee's own 100% apple juice (productId 24371) went
          # that way and the cell fell to a dearer product. What a refusal proves is that TODAY'S answer is
          # untrustworthy, not that the product is gone. So the refused answer is discarded, the row is
          # CARRIED at its last trusted read (its own as_of and store_id, so the board's age and store gates
          # still judge it honestly), and it is marked requeued so Get-HyVeeAskOrder asks it again FIRST next
          # run instead of waiting for its turn. A product with no earlier row has nothing to carry; it
          # re-enters from the link or the catalogue addition that put it in today's work list, and is
          # counted as requeued all the same.
          $tagWhy = Test-HyVeeTagAgreement -Price $price -Mult $mult -TagPrice $got.tagPrice -EcomTagPrice $got.ecomTagPrice -TagQty $got.tagQty
          if ($tagWhy) {
            $tagRefused++
            # $got, not $res. This read $res - a variable that has never existed in this script - so every
            # refusal line printed a blank tag, on the one report whose whole purpose is to show the tag
            # the price disagreed with. Found while extracting this loop, 2026-08-22.
            [void]$tagRefusedRows.Add([ordered]@{ item = [string]$w.name; product_id = [int]$w.pid; price = $price; tag = $(if ($null -ne $got.ecomTagPrice) { $got.ecomTagPrice } else { $got.tagPrice }); why = $tagWhy })
            $tagRequeue = $true
            $workReason = 'refused-below-shelf-tag'
            $got = $null   # fall through to the carry below, never to a deletion
          }
        }
        if ($got) {
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
            # THE STORE THAT ANSWERED, as a field the board's admission gate compares with stores.json's
            # pinned identity. From -StoreId, which the run takes from hyvee-store-lib, never a literal.
            store_id=$StoreId
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
    $carriedRow = $false
    if ($w.prow) {
      $asOf = if ($w.prow.as_of) { [string]$w.prow.as_of } elseif ($PrevDate) { $PrevDate } else { $Today }
      if (Test-HyVeeCarryExpired -AsOf $asOf -Today $Today -MaxCarryDays $MaxCarryDays) {
        # AGE EXPIRY (2026-09-19). Every other lane drops a carried row past MaxCarryDays; this one never did,
        # so rows read 2026-07-14 were still written on 2026-09-18. Dropped, counted, and named in
        # capture_terms. A product still holding an id is asked long before this under the 14-day rotation,
        # so what reaches here is a product the store stopped answering for, or one with no id to ask with.
        $expired++
        [void]$captureTerms.Add([ordered]@{ term = $workKey; ordinal = $workOrdinal; outcome = 'expired'; row_count = 0
          reason = ("carried row read $asOf is past the $MaxCarryDays-day carry - dropped, not published stale") })
        $workOrdinal++
        continue
      }
      if ($MaxCarryDays -gt 0 -and $asOf -notmatch '^\d{4}-\d{2}-\d{2}$') { $undatedCarry++ }
      # Through Get-HyVeeCarryRow, never an inline key list: see its header for the markdown that was being
      # laundered into an everyday price here, and Brad's ruling on what an ended sale must revert to.
      $row = Get-HyVeeCarryRow $w.prow $w.name $asOf $Today
      # A product id RECOVERED from this lane's own history (Get-HyVeeHistoryProductIds) is written onto the
      # carried row with where it came from, so the recovery survives into tomorrow's file instead of being
      # re-derived forever - and so a reader can tell a recovered id from one the row was priced with.
      if ([string]$w.pidFrom -eq 'history' -and [int]$w.pid -gt 0 -and -not $row.Contains('product_id')) {
        $row['product_id'] = [int]$w.pid
        $row['product_id_recovered_from'] = ('hyvee-regular-' + [string]$w.pidFile)
        $pidRecoveredStamped++
      }
      if ($tagRequeue) { $row['requeued'] = 'below-shelf-tag'; $row['requeued_on'] = $Today }
      [void]$deals.Add($row)
      $stale++
      $carriedRow = $true
    } elseif (-not $tagRequeue) { $fail++ }
    if ($tagRequeue) {
      $requeued++
      [void]$captureTerms.Add([ordered]@{ term = $workKey; ordinal = $workOrdinal; outcome = 'refused-below-shelf-tag'
        row_count = $(if ($carriedRow) { 1 } else { 0 }); requeued = $true
        reason = $(if ($carriedRow) { 'answer below the shelf tag discarded; last trusted read carried and re-queued first for tomorrow' } else { 'answer below the shelf tag discarded; no earlier read to carry, re-asked from its link or catalogue addition' }) })
      $workOrdinal++
      continue
    }
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
    Expired = $expired; UndatedCarry = $undatedCarry; Requeued = $requeued; PidRecoveredStamped = $pidRecoveredStamped
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

  # --- the budget number itself: ASKABLE PRODUCTS / RotationDays, capped at the call cap -------------
  # THE FOUNDING NUMBER (2026-09-19): ceil(1554 / 90) = 18 a day, a 90-day cycle, is what left 202 of 462
  # Hy-Vee board cells on the retired store. RotationDays is capture-policy-lib's, read here, never typed.
  $fixRot = [int]$script:RotationDays
  $fixCap = [int](Get-StoreCallCap 'Hy-Vee')
  _T "the fixture reads the FRESHNESS RULE from capture-policy-lib (RotationDays 14, Hy-Vee cap 120)" (($fixRot -eq 14) -and ($fixCap -eq 120))
  $fixBudget = Get-HyVeeProductBudget -Population $POP -RotationDays $fixRot -Cap $fixCap
  _T "budget comes from this lane's own ASKABLE population over RotationDays (240/14 = 18 a day)" ($fixBudget -eq 18)
  _T 'MUST FIRE: the live 1,554 products get 111 a day, not the 18 the 90-day quarter produced' ((Get-HyVeeProductBudget -Population 1554 -RotationDays 14 -Cap 120) -eq 111)
  _T 'moving RotationDays moves the budget with it (7 days -> 223, clamped at the 120 cap)' ((Get-HyVeeProductBudget -Population 1554 -RotationDays 7 -Cap 120) -eq 120)
  _T 'expiring sales take only the ROOM LEFT under the cap (111 rotation + 9 of 30 expiries = 120)' ((Get-HyVeeProductBudget -Population 1554 -RotationDays 14 -Cap 120 -Expiries 30) -eq 120)
  _T 'CLEAN TWIN: with room, an expiring sale is still extra on top (111 + 2 = 113)' ((Get-HyVeeProductBudget -Population 1554 -RotationDays 14 -Cap 120 -Expiries 2) -eq 113)
  _T 'the wall-clock ceiling still clamps a budget the 14-minute cap could never serve' ((Get-HyVeeProductBudget -Population 1000000 -RotationDays 14 -Cap 0 -MaxAskable 1400) -eq 1400)
  # THE CAPACITY BAR, AT IT AND ONE PRODUCT PAST IT (I196): 1,680 / 14 = 120 exactly = the cap; 1,681 needs 121.
  $capAt = Test-HyVeeCapacity -Population 1680 -RotationDays 14 -Cap 120
  $capPast = Test-HyVeeCapacity -Population 1681 -RotationDays 14 -Cap 120
  _T 'MUST NOT FIRE at the bar: 1,680 askable / 14 days = 120 = the 120 cap is OK' ($capAt.Ok -and $capAt.Need -eq 120 -and $capAt.Over -eq 0)
  _T 'MUST FIRE one product past the bar: 1,681 / 14 = 121, over the 120 cap by 1, and says so' ((-not $capPast.Ok) -and $capPast.Over -eq 1 -and ($capPast.Why -match '121 a day, 1 over'))
  _T 'and the budget at 1,681 is clamped to the cap, never above it (the shortfall is spoken, not hidden in a bigger number)' ((Get-HyVeeProductBudget -Population 1681 -RotationDays 14 -Cap 120) -eq 120)
  _T 'RotationDays 0 is refused loudly rather than dividing into a nonsense budget' ($(try { [void](Get-HyVeeProductBudget -Population 10 -RotationDays 0 -Cap 120); $false } catch { $true }))

  # --- (a) a budget smaller than the population still yields a row for EVERY product ----------------
  $ordA = Get-HyVeeAskOrder -Work $fixWork -Budget $fixBudget -TargetStoreId '1466'
  $askA = $ordA.Index
  $passA = Invoke-HyVeeWorkPass -Work $fixWork -AskIndex $askA -Fetch $fixFetch -Today '2026-08-22' -PrevDate '2026-08-21' -Units $fixUnits -SourceLabel 'fixture' -StoreId '1466' -SleepMs 0
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

  # --- (d) OLDEST FIRST: tomorrow asks the products today did not, and a missed day heals ------------
  # Tomorrow's work list is built from today's file, exactly as the run builds it from the previous file.
  $fixWorkB = New-Object System.Collections.ArrayList
  foreach ($r in $passA.Deals) { [void]$fixWorkB.Add([pscustomobject]@{ name=[string]$r['item']; size=[string]$r['size']; prow=$r; pid=[int]$r['product_id']; cid=('fix-' + ([int]$r['product_id'] - 9000)) }) }
  $ordB = Get-HyVeeAskOrder -Work $fixWorkB -Budget $fixBudget -TargetStoreId '1466'
  $askB = $ordB.Index
  _T "(d) the next run asks a DIFFERENT slice: none of today's $fixBudget fresh products is asked again tomorrow" (
      (@($askA.Keys | Where-Object { $askB.ContainsKey([int]$_) }).Count -eq 0) -and ($askB.Count -eq $fixBudget))
  $passB = Invoke-HyVeeWorkPass -Work $fixWorkB -AskIndex $askB -Fetch $fixFetch -Today '2026-08-23' -PrevDate '2026-08-22' -Units $fixUnits -SourceLabel 'fixture' -StoreId '1466' -SleepMs 0
  _T '(d) and the second run also writes every product' ((@($passB.Deals).Count -eq $POP) -and ($passB.Fresh -eq $fixBudget))
  # A MISSED DAY HEALS. The cursor pushed every product's turn back a day when a run did not happen; oldest
  # first asks the very same products the day after, because they are still the oldest.
  $ordSkip = Get-HyVeeAskOrder -Work $fixWorkB -Budget $fixBudget -TargetStoreId '1466'
  _T '(d) MUST FIRE: a day with no run changes nothing - the next run asks exactly the products the missed one would have' (
      (@($ordSkip.Order) -join ',') -eq (@($ordB.Order) -join ','))
  _T '(d) and after 240/18 = 14 runs every product has had its turn (the 14-day rotation, not a quarter)' (
      [int][math]::Ceiling($POP / [double]$fixBudget) -le $fixRot)

  # --- (d) THE DAILY STEP: the cursor file is still stepped once a day, never on a replay --------------
  _T '(d) a run that asked and was answered advances - even if the write is refused afterwards' (
      (Test-HyVeeCursorAdvance -Attempted 3 -Answered 3 -SliceSize 3 -SliceUnaskable 0).Advance)
  _T '(d) a run whose every request failed does NOT record a day of work (a dead endpoint is not a day of work)' (
      -not (Test-HyVeeCursorAdvance -Attempted 5 -Answered 0 -SliceSize 5 -SliceUnaskable 0).Advance)
  $ctmp = Join-Path ([IO.Path]::GetTempPath()) ('hvcur-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $ctmp -Force -ErrorAction Stop | Out-Null
  try {
    $realToday = (Get-Date).ToString('yyyy-MM-dd')
    $c1 = Step-HyVeeProductCursor -Next $fixBudget -From 0 -Today $realToday -OutDir $ctmp -Attempted $fixBudget -Answered $fixBudget -SliceSize $fixBudget -SliceUnaskable 0
    $cFile = Join-Path $ctmp 'hyvee-rotation-cursor.json'
    $onDisk = -1
    if (Test-Path $cFile) { $onDisk = [int](ConvertFrom-Json ([IO.File]::ReadAllText($cFile))).next_index }
    _T "(d) the daily step is CREATED and records the products asked ($fixBudget)" (($c1.Advanced) -and ($onDisk -eq $fixBudget))
    $c2 = Step-HyVeeProductCursor -Next 99 -From 0 -Today $realToday -OutDir $ctmp -Attempted $fixBudget -Answered $fixBudget -SliceSize $fixBudget -SliceUnaskable 0
    $stillDisk = [int](ConvertFrom-Json ([IO.File]::ReadAllText($cFile))).next_index
    _T '(d) a second run the same day does not step again (one record per day)' ((-not $c2.Advanced) -and ($stillDisk -eq $fixBudget))
    $c3 = Step-HyVeeProductCursor -Next 500 -From 0 -Today '2026-01-01' -OutDir $ctmp -Attempted 5 -Answered 5 -SliceSize 5 -SliceUnaskable 0
    _T '(d) a REPLAY (or a self-test on a frozen date) never steps the live record' (
        (-not $c3.Advanced) -and ([int](ConvertFrom-Json ([IO.File]::ReadAllText($cFile))).next_index -eq $fixBudget))
  } finally { Remove-Item -LiteralPath $ctmp -Recurse -Force -ErrorAction SilentlyContinue }

  # --- the unbudgeted pass is unchanged: ask about everything ---------------------------------------
  $passU = Invoke-HyVeeWorkPass -Work $fixWork -AskIndex $null -Fetch $fixFetch -Today '2026-08-22' -PrevDate '2026-08-21' -Units $fixUnits -SourceLabel 'fixture' -StoreId '1466' -SleepMs 0
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


  # ==================================================================================================
  # 2026-09-19, PLAN-board-accuracy: THE STORE STAMP, OLDEST FIRST, AGE EXPIRY, THE SHELF-TAG RE-QUEUE,
  # AND PRODUCT IDS RECOVERED FROM HISTORY. Founding bugs, each measured on the 2026-09-17/18 files:
  # 202 of 462 Hy-Vee board cells from the retired store; rows dated 2026-07-14 still written; Hy-Vee
  # 100% apple juice (productId 24371) deleted by a shelf-tag refusal; 1,006 of 1,541 rows with no id.
  # ==================================================================================================

  # --- THE STORE STAMP ---------------------------------------------------------------------------------
  $old1465 = [pscustomobject]@{ item='Hy-Vee Large Eggs'; ad_price='$2.99'; size='dozen'; regular=2.99; current_price=2.99; source_ad='Aisles Online current shelf price (storeId 1465, Omaha #01)'; as_of='2026-08-10'; product_id=4401 }
  $cOld = Get-HyVeeCarryRow $old1465 $old1465.item '2026-08-10' '2026-09-19'
  _T "MUST FIRE: a carried pre-stamp row read at storeId 1465 is stamped store_id '1465' - never relabelled as the store this run asks" ([string]$cOld['store_id'] -eq '1465')
  $stamped = [pscustomobject]@{ item='Hy-Vee Olives'; ad_price='$1.99'; size='6 oz'; regular=1.99; source_ad='Aisles Online current shelf price (storeId 1466, Omaha #02)'; store_id='1465'; as_of='2026-09-01'; product_id=77 }
  _T "CLEAN TWIN: a row that already carries store_id keeps IT, even where its source_ad text names another store" ([string](Get-HyVeeCarryRow $stamped $stamped.item '2026-09-01' '2026-09-19')['store_id'] -eq '1465')
  $noStore = [pscustomobject]@{ item='Gold Potatoes'; ad_price='$3.49'; size='3 lb'; regular=3.49; source_ad='everyday shelf price'; as_of='2026-07-14' }
  _T "a legacy row whose text names no storeId is stamped '' (unknown), never guessed" ([string](Get-HyVeeCarryRow $noStore $noStore.item '2026-07-14' '2026-09-19')['store_id'] -eq '')
  $labelOnly = [pscustomobject]@{ item='X'; source_ad='Aisles Online (Omaha #1, staples300)' }
  _T "MUST NOT FIRE on a store NAME: 'Omaha #1' is not an id, so the row stays unstamped" ((Get-HyVeeRowStoreId $labelOnly) -eq '')
  $dictRow = [ordered]@{ item='Y'; source_ad='Aisles Online current shelf price (storeId 1465, Omaha #01)'; store_id='' }
  _T "a PRESENT but empty store_id wins over the text (the field is the stamp, the text is history)" ((Get-HyVeeRowStoreId $dictRow) -eq '')
  _T "Get-HyVeeRowStoreId reads an ordered row and a JSON row the same way" (((Get-HyVeeRowStoreId ([ordered]@{ source_ad='(storeId 1466, Omaha #02)' })) -eq '1466') -and ((Get-HyVeeRowStoreId $old1465) -eq '1465'))
  $stWork = New-Object System.Collections.ArrayList
  [void]$stWork.Add([pscustomobject]@{ name='Hy-Vee Large Eggs'; size='dozen'; prow=$old1465; pid=4401; cid='eggs' })
  $stFetch = { param($productId) [pscustomobject]@{ sp = [pscustomobject]@{ price=3.19; basePrice=3.19; priceMultiple=1; basePriceMultiple=1; onSale=$false; isWeighted=$false }; soldBy='EA'; rawSize='12 ct'; tagPrice=3.19; ecomTagPrice=3.19; tagQty=1 } }
  $stPass = Invoke-HyVeeWorkPass -Work $stWork -AskIndex $null -Fetch $stFetch -Today '2026-09-19' -Units @{} -SourceLabel 'fixture' -StoreId '1466' -SleepMs 0
  $stRow = @($stPass.Deals)[0]
  _T "MUST FIRE: a row READ from the API is stamped with the storeId that answered (1466), and re-reading a 1465 row moves it to 1466" (($stPass.Fresh -eq 1) -and ([string]$stRow['store_id'] -eq '1466') -and ($stRow['as_of'] -eq '2026-09-19'))
  _T 'a fresh row cannot be written without a store: -StoreId is mandatory and non-empty' ($(try { [void](Invoke-HyVeeWorkPass -Work $stWork -AskIndex $null -Fetch $stFetch -Today '2026-09-19' -Units @{} -SourceLabel 'x' -StoreId '' -SleepMs 0); $false } catch { $true }))

  # --- OLDEST FIRST, THE WRONG STORE FIRST -------------------------------------------------------------
  $ow = New-Object System.Collections.ArrayList
  function _OW([string]$n, [string]$asOf, [string]$sid, [int]$wpid, [string]$req = '') {
    $pr = [ordered]@{ item = $n; ad_price = '$1.00'; size = '1 ct'; source_ad = 'x'; store_id = $sid; as_of = $asOf }
    if ($req) { $pr['requeued'] = $req }
    [void]$ow.Add([pscustomobject]@{ name = $n; size = '1 ct'; prow = [pscustomobject]$pr; pid = $wpid; cid = '' })
  }
  _OW 'on-target old'       '2026-09-01' '1466' 1          # 0
  _OW 'on-target newest'    '2026-09-18' '1466' 2          # 1
  _OW 'off-target NEWER'    '2026-09-10' '1465' 3          # 2
  _OW 'unstamped'           '2026-09-12' ''     4          # 3
  _OW 'no id, oldest of all' '2026-07-14' '1465' 0         # 4
  _OW 'on-target requeued'  '2026-09-17' '1466' 6 'below-shelf-tag'  # 5
  _OW 'on-target oldest'    '2026-08-20' '1466' 7          # 6
  [void]$ow.Add([pscustomobject]@{ name = 'never priced'; size = ''; prow = $null; pid = 8; cid = '' })   # 7
  $o1 = Get-HyVeeAskOrder -Work $ow -Budget 3 -TargetStoreId '1466'
  _T "MUST FIRE: an off-target row (1465, read 09-10) is asked BEFORE an on-target row read three weeks earlier (08-20)" ($o1.Index.ContainsKey(2) -and -not $o1.Index.ContainsKey(6))
  _T "the first bucket is off-target, unstamped, never-priced and re-queued, oldest first: order 7,2,3 at a budget of 3" ((@($o1.Order) -join ',') -eq '7,2,3')
  $o2 = Get-HyVeeAskOrder -Work $ow -Budget 7 -TargetStoreId '1466'
  _T "a shelf-tag re-queue comes ahead of every plain on-target row, then on-target OLDEST first (08-20, 09-01, 09-18)" ((@($o2.Order) -join ',') -eq '7,2,3,5,6,0,1')
  _T "MUST NOT FIRE: a product with no id is never in the order, whatever its age (it cannot be asked)" ((-not $o2.Index.ContainsKey(4)) -and ($o2.Askable -eq 7))
  _T "the slice reports how many of its asks were off target or unstamped (3 of 7; 3 askable in all)" (($o2.OffTargetInSlice -eq 3) -and ($o2.OffTargetAskable -eq 3))
  $o3 = Get-HyVeeAskOrder -Work $ow -Budget 2 -TargetStoreId '1466' -ExpiringIdx @{ 1 = $true }
  _T "an expiring sale still goes first of all (the 2026-08-22 rule survives the new order)" ((@($o3.Order) -join ',') -eq '1,7' -and $o3.ExpiringInSlice -eq 1)
  $o4 = Get-HyVeeAskOrder -Work $ow -Budget 0 -TargetStoreId '1466'
  _T "a budget of 0 asks nothing (and an empty order is not an error)" ($o4.Index.Count -eq 0)

  # --- AGE EXPIRY: exactly MaxCarryDays is kept, one day past it is dropped ------------------------------
  $fixCarry = [int](Get-PolicyMaxCarryDays)
  _T "the carry limit is read from capture-policy-lib ($fixCarry days)" ($fixCarry -eq 90)
  _T "MUST NOT FIRE at the bar: a row read exactly 90 days ago (2026-06-21 on 2026-09-19) is KEPT" (-not (Test-HyVeeCarryExpired -AsOf '2026-06-21' -Today '2026-09-19' -MaxCarryDays 90))
  _T "MUST FIRE one day past the bar: a row read 91 days ago (2026-06-20) is EXPIRED" (Test-HyVeeCarryExpired -AsOf '2026-06-20' -Today '2026-09-19' -MaxCarryDays 90)
  _T "an unparseable date is not judged here (the caller counts it; the board's age gate withholds it)" (-not (Test-HyVeeCarryExpired -AsOf 'last week' -Today '2026-09-19' -MaxCarryDays 90))
  $ew = New-Object System.Collections.ArrayList
  foreach ($d in @('2026-06-20', '2026-06-21', '2026-09-18')) {
    $pr = [pscustomobject]@{ item = "aged $d"; ad_price = '$1.00'; size = '1 ct'; regular = 1.0; source_ad = 'x'; as_of = $d }
    [void]$ew.Add([pscustomobject]@{ name = "aged $d"; size = '1 ct'; prow = $pr; pid = 0; cid = '' })
  }
  $ePass = Invoke-HyVeeWorkPass -Work $ew -AskIndex @{} -Fetch $stFetch -Today '2026-09-19' -Units @{} -SourceLabel 'x' -StoreId '1466' -MaxCarryDays 90 -SleepMs 0
  $eNames = @($ePass.Deals | ForEach-Object { [string]$_['item'] })
  _T "MUST FIRE: the pass DROPS the 91-day row, keeps the 90-day and the 1-day rows, and counts the drop" (($ePass.Expired -eq 1) -and ($eNames -notcontains 'aged 2026-06-20') -and ($eNames -contains 'aged 2026-06-21') -and ($eNames -contains 'aged 2026-09-18'))
  _T "the drop is named in capture_terms, not silent" (@($ePass.CaptureTerms | Where-Object { $_['outcome'] -eq 'expired' }).Count -eq 1)
  $e0 = Invoke-HyVeeWorkPass -Work $ew -AskIndex @{} -Fetch $stFetch -Today '2026-09-19' -Units @{} -SourceLabel 'x' -StoreId '1466' -MaxCarryDays 0 -SleepMs 0
  _T "CLEAN TWIN: -MaxCarryDays 0 (the old behaviour, never used by the run) still writes all three" (@($e0.Deals).Count -eq 3)
  $agedAsked = New-Object System.Collections.ArrayList
  [void]$agedAsked.Add([pscustomobject]@{ name = 'Hy-Vee Large Eggs'; size = 'dozen'; prow = ([pscustomobject]@{ item = 'Hy-Vee Large Eggs'; ad_price = '$2.99'; size = 'dozen'; regular = 2.99; source_ad = 'x'; as_of = '2026-05-01' }); pid = 4401; cid = 'eggs' })
  $aPass = Invoke-HyVeeWorkPass -Work $agedAsked -AskIndex $null -Fetch $stFetch -Today '2026-09-19' -Units @{} -SourceLabel 'x' -StoreId '1466' -MaxCarryDays 90 -SleepMs 0
  _T "CLEAN TWIN: an old row the store ANSWERS for today is re-read, not expired" (($aPass.Fresh -eq 1) -and ($aPass.Expired -eq 0))

  # --- THE SHELF-TAG REFUSAL RE-QUEUES, IT NEVER DELETES ---------------------------------------------
  # The founding row: Hy-Vee's own 100% apple juice, productId 24371, deleted from the file by a refusal.
  $aj = [pscustomobject]@{ item='Hy-Vee 100% Apple Juice'; ad_price='$2.79'; size='64 fl oz'; regular=2.79; current_price=2.79; source_ad='Aisles Online current shelf price (storeId 1466, Omaha #02)'; store_id='1466'; as_of='2026-09-10'; product_id=24371 }
  $ajWork = New-Object System.Collections.ArrayList
  [void]$ajWork.Add([pscustomobject]@{ name=$aj.item; size='64 fl oz'; prow=$aj; pid=24371; cid='apple-juice' })
  $belowTag = { param($productId) [pscustomobject]@{ sp = [pscustomobject]@{ price=1.99; basePrice=2.79; priceMultiple=1; basePriceMultiple=1; onSale=$true; isWeighted=$false }; soldBy='EA'; rawSize='64 fl oz'; tagPrice=2.79; ecomTagPrice=2.79; tagQty=1 } }
  $tPass = Invoke-HyVeeWorkPass -Work $ajWork -AskIndex $null -Fetch $belowTag -Today '2026-09-19' -Units @{} -SourceLabel 'x' -StoreId '1466' -MaxCarryDays 90 -SleepMs 0
  $tRow = @($tPass.Deals | Where-Object { [int]$_['product_id'] -eq 24371 })
  _T "MUST FIRE: a shelf-tag refusal on productId 24371 keeps the product IN the file (the refusal used to delete it)" ($tRow.Count -eq 1)
  _T "the refused answer is discarded: the row is the last trusted read (2.79, as_of 2026-09-10, not_reverified), never the 1.99 below the tag" (($tRow.Count -eq 1) -and ($tRow[0]['ad_price'] -eq '$2.79') -and ($tRow[0]['as_of'] -eq '2026-09-10') -and ([bool]$tRow[0]['not_reverified']))
  _T "it is RE-QUEUED and counted: requeued=below-shelf-tag, requeued_on today, TagRefused 1, Requeued 1, not a failure" (($tRow.Count -eq 1) -and ($tRow[0]['requeued'] -eq 'below-shelf-tag') -and ($tRow[0]['requeued_on'] -eq '2026-09-19') -and ($tPass.TagRefused -eq 1) -and ($tPass.Requeued -eq 1) -and ($tPass.Fail -eq 0) -and ($tPass.Fresh -eq 0))
  _T "the refusal is still named in capture_terms, with the re-queue" (@($tPass.CaptureTerms | Where-Object { $_['outcome'] -eq 'refused-below-shelf-tag' -and $_['requeued'] -and $_['row_count'] -eq 1 }).Count -eq 1)
  $rqWork = New-Object System.Collections.ArrayList
  [void]$rqWork.Add([pscustomobject]@{ name='plain on-target, older'; size='1 ct'; prow=([pscustomobject]@{ item='p'; store_id='1466'; as_of='2026-09-01' }); pid=11; cid='' })
  [void]$rqWork.Add([pscustomobject]@{ name=$aj.item; size='64 fl oz'; prow=([pscustomobject]$tRow[0]); pid=24371; cid='apple-juice' })
  _T "and the NEXT run asks it FIRST, ahead of an older on-target product" ((@((Get-HyVeeAskOrder -Work $rqWork -Budget 1 -TargetStoreId '1466').Order) -join ',') -eq '1')
  $tCarry = Get-HyVeeCarryRow ([pscustomobject]$tRow[0]) $aj.item '2026-09-10' '2026-09-20'
  _T "the re-queue survives a day it is not asked (the carry keeps requeued)" ($tCarry['requeued'] -eq 'below-shelf-tag')
  $okTag = { param($productId) [pscustomobject]@{ sp = [pscustomobject]@{ price=2.59; basePrice=2.79; priceMultiple=1; basePriceMultiple=1; onSale=$true; isWeighted=$false }; soldBy='EA'; rawSize='64 fl oz'; tagPrice=2.59; ecomTagPrice=2.59; tagQty=1 } }
  $rqWork2 = New-Object System.Collections.ArrayList
  [void]$rqWork2.Add([pscustomobject]@{ name=$aj.item; size='64 fl oz'; prow=([pscustomobject]$tRow[0]); pid=24371; cid='apple-juice' })
  $okPass = Invoke-HyVeeWorkPass -Work $rqWork2 -AskIndex $null -Fetch $okTag -Today '2026-09-20' -Units @{} -SourceLabel 'x' -StoreId '1466' -SleepMs 0
  _T "CLEAN TWIN: once the store's answer agrees with its tag the row is fresh again and the re-queue mark is gone" (($okPass.Fresh -eq 1) -and (-not @($okPass.Deals)[0].Contains('requeued')) -and (@($okPass.Deals)[0]['ad_price'] -eq '$2.59'))
  $newWork = New-Object System.Collections.ArrayList
  [void]$newWork.Add([pscustomobject]@{ name='brand new product'; size=''; prow=$null; pid=555; cid='apple-juice' })
  $nPass = Invoke-HyVeeWorkPass -Work $newWork -AskIndex $null -Fetch $belowTag -Today '2026-09-19' -Units @{} -SourceLabel 'x' -StoreId '1466' -SleepMs 0
  _T "a never-priced product refused below its tag writes no row (nothing trusted to carry) but is counted re-queued, not failed" ((@($nPass.Deals).Count -eq 0) -and ($nPass.Requeued -eq 1) -and ($nPass.Fail -eq 0))

  # --- PRODUCT IDS RECOVERED FROM THIS LANE'S OWN HISTORY -------------------------------------------
  $htmp = Join-Path ([IO.Path]::GetTempPath()) ('hvhist-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $htmp -Force -ErrorAction Stop | Out-Null
  try {
    $h1 = [ordered]@{ deals = @(
      [ordered]@{ item = 'Hy-Vee Mild Green Chiles'; size = '7 oz'; product_id = 3301 },
      [ordered]@{ item = 'Dinty Moore Beef Stew'; size = '38 oz'; product_id = 5501 },
      [ordered]@{ item = 'Twin Name'; size = '16 oz'; product_id = 7001 }) }
    $h2 = [ordered]@{ deals = @(
      [ordered]@{ item = 'Twin Name'; size = '16 oz'; product_id = 7002 },
      [ordered]@{ item = 'Dinty Moore Beef Stew'; size = '15 oz'; product_id = 5500 }) }
    [IO.File]::WriteAllText((Join-Path $htmp 'hyvee-regular-2026-08-12.json'), ($h1 | ConvertTo-Json -Depth 5))
    [IO.File]::WriteAllText((Join-Path $htmp 'hyvee-regular-2026-08-10.json'), ($h2 | ConvertTo-Json -Depth 5))
    [IO.File]::WriteAllText((Join-Path $htmp 'hyvee-regular-2026-08-01.json'), '{ not json')
    $hFiles = @(Get-ChildItem (Join-Path $htmp 'hyvee-regular-*.json') | Sort-Object Name -Descending)
    $need = @{ 'hy-vee mild green chiles|7 oz' = $true; 'dinty moore beef stew|38 oz' = $true; 'twin name|16 oz' = $true; 'never had one|1 ct' = $true }
    $hr = Get-HyVeeHistoryProductIds -Files $hFiles -Needed $need
    _T "MUST FIRE: an id-less row is given back the id this lane priced its SAME NAME AND SIZE with (3301, from the 08-12 file)" ($hr.Map.ContainsKey('hy-vee mild green chiles|7 oz') -and $hr.Map['hy-vee mild green chiles|7 oz'].pid -eq 3301 -and $hr.Map['hy-vee mild green chiles|7 oz'].file_date -eq '2026-08-12')
    _T "the SIZE is part of the key: Dinty Moore 38 oz gets 5501, never the 15 oz's 5500" ($hr.Map['dinty moore beef stew|38 oz'].pid -eq 5501)
    _T "MUST NOT FIRE on a disagreement: two files naming two ids for one name and size recover NOTHING, and it is counted" ((-not $hr.Map.ContainsKey('twin name|16 oz')) -and ($hr.Conflicts -eq 1))
    _T "a key no file ever priced stays unrecovered, and an unreadable file is counted, not fatal (2 read, 1 unreadable)" ((-not $hr.Map.ContainsKey('never had one|1 ct')) -and ($hr.Scanned -eq 2) -and ($hr.Unreadable -eq 1))
    $hr0 = Get-HyVeeHistoryProductIds -Files $hFiles -Needed @{}
    _T "nothing needed, nothing read" ($hr0.Scanned -eq 0)
  } finally { Remove-Item -LiteralPath $htmp -Recurse -Force -ErrorAction SilentlyContinue }
  $recW = New-Object System.Collections.ArrayList
  [void]$recW.Add([pscustomobject]@{ name='Hy-Vee Mild Green Chiles'; size='7 oz'; prow=([pscustomobject]@{ item='Hy-Vee Mild Green Chiles'; ad_price='$1.29'; size='7 oz'; regular=1.29; source_ad='Aisles Online current shelf price (storeId 1465, Omaha #01)'; as_of='2026-08-12' }); pid=3301; cid=''; pidFrom='history'; pidFile='2026-08-12' })
  $recP = Invoke-HyVeeWorkPass -Work $recW -AskIndex @{} -Fetch $stFetch -Today '2026-09-19' -Units @{} -SourceLabel 'x' -StoreId '1466' -MaxCarryDays 90 -SleepMs 0
  $recRow = @($recP.Deals)[0]
  _T "a recovered id is written onto the carried row with where it came from, so tomorrow's file holds it" (($recRow['product_id'] -eq 3301) -and ($recRow['product_id_recovered_from'] -eq 'hyvee-regular-2026-08-12') -and ($recP.PidRecoveredStamped -eq 1))
  _T "CLEAN TWIN: the recovered row keeps its OWN store (1465), so the board's store gate still refuses it until it is re-read" ([string]$recRow['store_id'] -eq '1465')

  # --- refresh-hyvee-links.ps1 STAMPS THE STORE FROM THE LIBRARY -------------------------------------
  $lnkTmp = Join-Path ([IO.Path]::GetTempPath()) ('hvlnk-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $lnkTmp -Force -ErrorAction Stop | Out-Null
  try {
    $sj = [ordered]@{ stores = @([ordered]@{ name = 'Hy-Vee'; store_identity = [ordered]@{ store_id = 1466; location_id = 'loc'; label = 'Omaha #02' } }) }
    [IO.File]::WriteAllText((Join-Path $lnkTmp 'stores.json'), ($sj | ConvertTo-Json -Depth 5))
    _T "the link snapshot's verified stamp names the store the library names (1466)" ((Get-HyVeeVerifiedLabel -Root $lnkTmp -Date '2026-09-19') -eq '2026-09-19 Hy-Vee GraphQL (storeId 1466, current shelf price)')
  } finally { Remove-Item -LiteralPath $lnkTmp -Recurse -Force -ErrorAction SilentlyContinue }
  # The needle is built by concatenation so this file can never match itself (rules: a self-test that greps its
  # own source cannot fail). It reads the OTHER file, the one that carried the literal.
  $lnkSrc = [IO.File]::ReadAllText((Join-Path $root 'refresh-hyvee-links.ps1'))
  $needle = 'store' + 'Id 14' + '65'
  _T "MUST FIRE on the founding literal: refresh-hyvee-links.ps1 no longer types a storeId and takes its stamp from Get-HyVeeVerifiedLabel" ((-not $lnkSrc.Contains($needle)) -and ($lnkSrc -match 'Get-HyVeeVerifiedLabel'))

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
# READ JSON WITHOUT INVENTING MOJIBAKE (2026-09-05).
# `Get-Content -Raw | ConvertFrom-Json` with no -Encoding decodes as the system ANSI codepage in Windows
# PowerShell 5.1. This pull READS ITS OWN PREVIOUS FILE and writes the result back as UTF-8, so the moment
# any other tool rewrites hyvee-regular-*.json without a BOM, every non-ASCII name in it is re-encoded one
# generation deeper on the NEXT run - and again the run after that. Measured: at commit 9f609468 the 08-29
# file was 1,497,192 bytes beginning EF BB BF with 2 mangled names; at 5abe529d the same path was 836,171
# bytes beginning 7B 0A 20 (a Python json.dump shape, no BOM) with the same content, and the 08-30 file that
# read it has 8. The Campbell's turkey gravy row reached FIVE generations, 117 characters long, and it was
# the Hy-Vee jarred-gravy cell the reader saw.
# ReadAllText defaults to UTF-8 and honours a BOM when there is one, so both shapes decode correctly. Lines
# 643 and 911 already read the cursor files this way; this is the same fix on the paths that carry names.
foreach ($c in (ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $root 'commodities.json'))))) { $units[[string]$c.id] = [string]$c.unit }

$pd = (ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $root 'product-urls.json')))).items
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
if ($prevF) { $prevRows = @((ConvertFrom-Json ([IO.File]::ReadAllText($prevF.FullName))).deals) }
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
  $wfrom = ''
  if ($r.product_id) { $wpid = [int]$r.product_id; $wfrom = 'row' }
  # a stored link still WINS: it is the product we publish a "See item" chip for, so it is what the price must
  # describe. Only the exact name+size link, or an unambiguous name, may override the row's own id.
  if ($idByName.ContainsKey($k)) { $wpid = [int]$idByName[$k].pid; $wcid = [string]$idByName[$k].cid; $wfrom = 'link' }
  else {
    $byNm = @($idByName.Values | Where-Object { $_.nm -eq $kn })
    if ($byNm.Count -eq 1) { $wpid = [int]$byNm[0].pid; $wcid = [string]$byNm[0].cid; $wfrom = 'link' }
  }
  [void]$work.Add([pscustomobject]@{ name=$nm; size=[string]$r.size; prow=$r; pid=$wpid; cid=$wcid; pidFrom=$wfrom; pidFile='' })
}
foreach ($k in $idByName.Keys) {
  if ($seenName.ContainsKey($idByName[$k].nm)) { continue }
  $seenName[$idByName[$k].nm] = $true
  $e = $pd.($idByName[$k].cid).'Hy-Vee'
  [void]$work.Add([pscustomobject]@{ name=[string]$e.name; size=''; prow=$null; pid=$idByName[$k].pid; cid=$idByName[$k].cid; pidFrom='link'; pidFile='' })
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
      [void]$work.Add([pscustomobject]@{ name=$anm; size=''; prow=$null; pid=$apid; cid=[string]$a.commodity; pidFrom='catalog-add'; pidFile='' })
      $addWork++
    }
  }
}
if ($addWork -gt 0 -or $addDup -gt 0) {
  Write-Output ("Hy-Vee: {0} adjudicated catalogue addition(s) joined the work list ({1} already covered by the refresh)" -f $addWork, $addDup)
}
# ---- FOURTH SOURCE OF A PRODUCT ID: THIS LANE'S OWN HISTORY (2026-09-19) ----------------------------
# A row with no product id can never be re-asked, however big the budget, and the board's 14-day publish
# limit withholds it once its last read ages out - so every such row is a Hy-Vee cell the board will lose.
# Most of them had an id once: the pre-2026-08-22 carry copied ad_price and dropped product_id. The files
# that still hold it are this lane's own outputs, so the id is the one this lane itself asked the store with
# for a row of the SAME NAME AND SIZE. Get-HyVeeHistoryProductIds refuses any key two files disagree on, and
# the size cross-check in the pass still judges the id the day it is asked. Bounded to files inside
# MaxCarryDays: a row older than that is expiring anyway. Measured on the 2026-09-18 file: 744 of 1,006
# id-less rows recovered, 0 conflicts, 65 files parsed in about 2 s.
$hvPidRecovered = 0; $hvPidConflicts = 0
try {
  $hvHistDays = 90
  try { . (Join-Path $root 'capture-policy-lib.ps1'); $hvHistDays = [int](Get-PolicyMaxCarryDays) } catch { }
  $hvNeed = @{}
  foreach ($w in $work) {
    if ([int]$w.pid -gt 0 -or -not $w.prow) { continue }
    $hvNeed[([string]$w.name).ToLower().Trim() + '|' + ([string]$w.size).Trim()] = $true
  }
  if ($hvNeed.Count -gt 0) {
    $hvFloor = ([datetime]::ParseExact($todayS, 'yyyy-MM-dd', $null)).AddDays(-$hvHistDays).ToString('yyyy-MM-dd')
    $hvHistFiles = @(Get-ChildItem (Join-Path $regDir 'hyvee-regular-*.json') -EA SilentlyContinue |
      Where-Object { $_.BaseName -match '^hyvee-regular-(\d{4}-\d{2}-\d{2})$' -and $Matches[1] -ge $hvFloor } | Sort-Object Name -Descending)
    $hvHist = Get-HyVeeHistoryProductIds -Files $hvHistFiles -Needed $hvNeed
    $hvPidConflicts = [int]$hvHist.Conflicts
    foreach ($w in $work) {
      if ([int]$w.pid -gt 0 -or -not $w.prow) { continue }
      $hk = ([string]$w.name).ToLower().Trim() + '|' + ([string]$w.size).Trim()
      if ($hvHist.Map.ContainsKey($hk)) {
        $w.pid = [int]$hvHist.Map[$hk].pid; $w.pidFrom = 'history'; $w.pidFile = [string]$hvHist.Map[$hk].file_date
        $hvPidRecovered++
      }
    }
    Write-Output ("Hy-Vee: product ids recovered from this lane's own history: " + $hvPidRecovered + " of " + $hvNeed.Count + " id-less row key(s), over " + $hvHist.Scanned + " file(s) since " + $hvFloor + " (" + $hvPidConflicts + " key(s) refused: two files gave two different ids; " + $hvHist.Unreadable + " file(s) unreadable)")
  }
} catch {
  Write-Warning ("Hy-Vee: product-id recovery from history did not run (" + $_.Exception.Message + ") - those rows stay un-askable this run, exactly as before")
}
if ($Quick) { $work = @($work | Where-Object { $_.pid -gt 0 } | Select-Object -First 10) }

# ---- HOW MUCH WE MAY ASK THE STORE FOR TODAY, AND WHICH PRODUCTS --------------------------------------
# The wall-clock cap is hoisted above the budget so the two numbers can argue with each other in ONE
# place. 14 minutes at roughly 0.6s a product (one request plus the 120ms courtesy sleep) is about 1,400
# products: the real ceiling on any budget, whatever the policy computes. A budget above it would be a
# budget that lies - it would promise a pull the clock stops halfway through.
$MAXMIN = 14
$HV_SEC_PER_PRODUCT = 0.6

# THE BUDGET HISTORY, SHORT. 2026-08-20: a budget was added and REPLACED the work list with the slice, so
# the file collapsed to 7 rows (fixed 2026-08-22: the slice is a set of indices; every product is still
# written). 2026-08-22: it took the SEARCH-TERM count; fixed to this lane's own PRODUCT count over the
# 90-day quarter, 18 a day. 2026-09-19: 18 a day was the defect - see Get-HyVeeProductBudget's header and
# design\PLAN-board-accuracy-2026-09-19.md. The budget is now ceil(askable / RotationDays) capped by the
# store's call cap, and the products asked are chosen OLDEST FIRST by Get-HyVeeAskOrder, off-target and
# re-queued rows ahead of the rest, instead of by a rotation cursor.
#
# THE ROTATION CURSOR (hyvee-rotation-cursor.json) NO LONGER CHOOSES ANYTHING. Oldest-first needs no
# position: the as_of on each row IS the queue, and a missed day heals because the products it did not ask
# stay the oldest. Nothing else reads the cursor's index (commit-capture-cursor.ps1 only names the file in a
# comment). It is still STEPPED once a day through Step-HyVeeProductCursor, from 0 to the number of products
# asked, because that call keeps its guards (no replay, one advance a day, no advance when every request
# failed) and writes the daily Hy-Vee line in capture-cursor-log.jsonl, which is the log the board-accuracy
# triage counted "days the cursor moved" from.
$askIndex = $null       # $null = unbudgeted, ask about everything
$hvBudget = 0
$hvOrder = $null
$hvCap = $null
$hvPlan = $null
$askablePop = @($work | Where-Object { [int]$_.pid -gt 0 }).Count
if (-not $Quick) {
  try {
    . (Join-Path $root 'capture-policy-lib.ps1')
    $hvPlan = Get-CapturePlan -Store 'Hy-Vee' -Today $todayS
    $hvRotDays = [int]$hvPlan.RotationDays
    $hvCallCap = [int](Get-StoreCallCap 'Hy-Vee')
    $hvMaxAskable = [int][math]::Floor(($MAXMIN * 60.0) / $HV_SEC_PER_PRODUCT)
    $hvCap = Test-HyVeeCapacity -Population $askablePop -RotationDays $hvRotDays -Cap $hvCallCap
    if (-not $hvCap.Ok) {
      # SPOKEN, NEVER SILENTLY CLAMPED. The cap is capture-policy-lib's to move, with evidence; this lane
      # says by how much it is short every run so the shortfall cannot hide behind a normal-looking day.
      Write-Warning ("Hy-Vee: CAPACITY SHORTFALL - " + $hvCap.Why + ". Raising the cap is a capture-policy-lib change with evidence behind it (this lane re-verified 1,010 products in one run at baseline with no refusal).")
    }
    $hvBudget = Get-HyVeeProductBudget -Population $askablePop -RotationDays $hvRotDays -Cap $hvCallCap -Expiries (@($hvPlan.SaleExpiries).Count) -MaxAskable $hvMaxAskable
    # THE EXPIRING SALES GO FIRST (2026-08-22). A product answers to its commodity id (from product-urls) -
    # and, for a row with no stored link, to the commodity whose product-urls name matches its name. Brad's
    # rule: "reprice whenever an ad price / sale price / rollback price / instant-savings price drops off."
    $hvExpIds = @{}
    foreach ($xid in @($hvPlan.SaleExpiries)) { $hvExpIds[[string]$xid] = $true }
    $hvExpNames = @{}
    foreach ($xid in @($hvPlan.SaleExpiries)) {
      $xe = $pd.$xid.'Hy-Vee'
      if ($xe -and $xe.name) { $hvExpNames[([string]$xe.name).ToLower().Trim()] = [string]$xid }
    }
    $hvExpIdx = @{}
    $wi = -1
    foreach ($w in $work) {
      $wi++
      if (($w.cid -and $hvExpIds.ContainsKey([string]$w.cid)) -or $hvExpNames.ContainsKey(([string]$w.name).ToLower().Trim())) { $hvExpIdx[$wi] = $true }
    }
    $hvOrder = Get-HyVeeAskOrder -Work $work -Budget $hvBudget -TargetStoreId ([string]$StoreId) -ExpiringIdx $hvExpIdx
    $askIndex = $hvOrder.Index
    Write-Output ("Hy-Vee: capture-policy budget = $hvBudget product(s) to ASK about today = ceil($askablePop askable / $hvRotDays days), cap $hvCallCap, " +
      "$(@($hvPlan.SaleExpiries).Count) expiring sale(s); chosen OLDEST FIRST: $($hvOrder.ExpiringInSlice) for an expiring sale, " +
      "$($hvOrder.OffTargetInSlice) read at another store or unstamped (of $($hvOrder.OffTargetAskable) askable), every one of the $(@($work).Count) products is still written")
  } catch {
    Write-Warning ("Hy-Vee: capture-policy did not load (" + $_.Exception.Message + ") - running unbudgeted this pass")
    $askIndex = $null
  }
}

$refreshable = @($work | Where-Object { $_.pid -gt 0 }).Count
$askableToday = Get-HyVeeAskableCount -Work $work -AskIndex $askIndex
Write-Output ("Hy-Vee: " + @($work).Count + " products (" + $refreshable + " refreshable via GraphQL, " + $hvPidRecovered + " of them by a product id recovered from this lane's own history; " + (@($work).Count - $refreshable) + " hold no product id so their price cannot be re-verified; " + $askableToday + " will be asked about today)")

# THE PASS ITSELF LIVES IN Invoke-HyVeeWorkPass, ABOVE -SelfTest. It was inline here until 2026-08-22,
# which meant the code that decides what the FILE contains had no fixtures at all - and that is exactly
# where the budget wipeout hid for two days. -Fetch is the only door to the network, so the fixtures
# drive this exact text with a stub.
$hvCarryDays = 90
try { . (Join-Path $root 'capture-policy-lib.ps1'); $hvCarryDays = [int](Get-PolicyMaxCarryDays) } catch { }

if ($DryRun) {
  # NO REQUEST, NO WRITE. The pass runs against a store that answers nothing, so every product that would
  # have been asked is counted as asked-and-unanswered and carried; the point is the shape of the file the
  # carry, the expiry and the store stamp produce, and the order and budget above.
  $dry = Invoke-HyVeeWorkPass -Work $work -AskIndex $askIndex -Today $todayS -PrevDate $prevDate `
    -Units $units -SourceLabel $SRC_LABEL -StoreId ([string]$StoreId) -MaxCarryDays $hvCarryDays -MaxMinutes 1000 -SleepMs 0 `
    -Fetch { param($productId) $null }
  $dryRows = @($dry.Deals)
  $byStoreDry = @{}
  foreach ($r in $dryRows) { $k = [string]$r['store_id']; if (-not $k) { $k = 'unstamped' }; if (-not $byStoreDry.ContainsKey($k)) { $byStoreDry[$k] = 0 }; $byStoreDry[$k]++ }
  $noIdRows = @($dryRows | Where-Object { -not $_.Contains('product_id') }).Count
  $pubLimit = if ($hvPlan) { [int]$hvPlan.MaxPublishAgeDays } else { 14 }
  $withinPub = 0
  foreach ($r in $dryRows) { if (-not (Test-HyVeeCarryExpired -AsOf ([string]$r['as_of']) -Today $todayS -MaxCarryDays $pubLimit)) { $withinPub++ } }
  Write-Output ("HYVEE-DRYRUN products=" + @($work).Count + " askable=" + $askablePop + " pid_recovered=" + $hvPidRecovered + " pid_conflicts=" + $hvPidConflicts +
    " budget=" + $hvBudget + " need=" + $(if ($hvCap) { $hvCap.Need } else { 'n/a' }) + " cap=" + $(if ($hvCap) { $hvCap.Cap } else { 'n/a' }) +
    " over=" + $(if ($hvCap) { $hvCap.Over } else { 'n/a' }))
  $byStoreTxt = (($byStoreDry.Keys | Sort-Object) | ForEach-Object { "$_=$($byStoreDry[$_])" }) -join ' '
  Write-Output ("HYVEE-DRYRUN rows_written=" + $dryRows.Count + " expired_past_" + $hvCarryDays + "d=" + $dry.Expired + " undated_carried=" + $dry.UndatedCarry +
    " rows_without_product_id=" + $noIdRows + " rows_within_" + $pubLimit + "d_publish_limit=" + $withinPub + " of " + $dryRows.Count +
    " by_store_id=" + $byStoreTxt)
  if ($hvOrder) {
    $firstTen = @($hvOrder.Order | Select-Object -First 10 | ForEach-Object { $w = $work[$_]; ('[' + $w.pid + '] ' + $w.name + ' (' + $(if ($w.prow) { [string]$w.prow.as_of + ', store ' + (Get-HyVeeRowStoreId $w.prow) } else { 'never priced' }) + ')') })
    Write-Output ("HYVEE-DRYRUN first asks: " + ($firstTen -join '; '))
  }
  Write-Output 'HYVEE-DRYRUN-COMPLETE no request issued, nothing written'
  exit 0
}

$startT = Get-Date
$pass = Invoke-HyVeeWorkPass -Work $work -AskIndex $askIndex -Today $todayS -PrevDate $prevDate `
  -Units $units -SourceLabel $SRC_LABEL -StoreId ([string]$StoreId) -MaxCarryDays $hvCarryDays -MaxMinutes $MAXMIN -StartTime $startT -SleepMs 120 `
  -Fetch { param($productId) Get-HyVeeStoreProduct ([int]$productId) }

$deals = $pass.Deals
$captureTerms = $pass.CaptureTerms
$sizeConflicts = $pass.SizeConflicts
$tagRefusedRows = $pass.TagRefusedRows
$fresh = $pass.Fresh; $fail = $pass.Fail; $markdown = $pass.Markdown; $stale = $pass.Stale
$newProd = $pass.NewProd; $mismatch = $pass.Mismatch; $capSkipped = $pass.CapSkipped
$budgetSkipped = $pass.BudgetSkipped; $tagRefused = $pass.TagRefused
$multRefused = $pass.MultRefused; $multDescriptive = $pass.MultDescriptive

Write-Output ("Hy-Vee: " + $fresh + " refreshed today (" + $markdown + " marked down), " + $newProd + " newly priced, " + $stale + " not re-verified, " + $mismatch + " REFUSED (productId is a different size than our row), " + $capSkipped + " never asked (wall-clock cap), " + $budgetSkipped + " outside today's budget slice (carried, not dropped), " + $pass.Expired + " carried row(s) past the " + $hvCarryDays + "-day carry DROPPED, " + $pass.Requeued + " re-queued after a shelf-tag refusal, " + $fail + " failed")

# THE DAILY CURSOR STEP (see the note above the budget: it no longer chooses products). It hangs on WHAT THE
# RUN ASKED, never on the write, for the reason written 2026-08-22: a refused write that also refused the
# rotation froze this lane for two days. Replay, one-per-day and "every request failed" are judged in
# capture-policy-lib (Step-HyVeeProductCursor / Test-HyVeeCursorAdvance).
if ($null -ne $hvOrder) {
  try {
    . (Join-Path $root 'capture-policy-lib.ps1')
    $cs = Step-HyVeeProductCursor -Next ([int]$pass.Attempted) -From 0 -Today $todayS -OutDir $OutDir `
      -Attempted $pass.Attempted -Answered $pass.Answered -SliceSize $pass.SliceSize -SliceUnaskable $pass.SliceUnaskable
    if ($cs.Advanced) { Write-Output ("Hy-Vee: daily step recorded ($($cs.To) product(s) asked; $($cs.Reason))") }
    else { Write-Warning ("Hy-Vee: daily step NOT recorded - " + $cs.Reason) }
  } catch {
    Write-Warning ("Hy-Vee: the daily step could not be recorded (" + $_.Exception.Message + ") - the order is oldest-first, so nothing is lost.")
  }
}
# Reported on its own line, and only when non-zero, so the divisor class stays VISIBLE. The bug it guards
# against published a price no shopper could pay and survived every internal check for as long as nobody
# looked; a silent counter would recreate exactly that.
if ($multDescriptive -gt 0 -or $multRefused -gt 0) {
  Write-Output ("Hy-Vee: priceMultiple reconciliation - " + $multDescriptive + " row(s) treated the multiple as DESCRIPTIVE (price already per-item, price == basePrice), " + $multRefused + " row(s) REFUSED (divided price landed under 40% of the regular price, so the divisor is more likely wrong than the promo is deep)")
}
# THE SHELF-TAG REFUSALS, NAMED. A count alone would have hidden what made this worth building: the two
# rows it caught first were the same brand, both phantom markdowns of 40%+ off a tag that had not moved.
# Printed on its own since 2026-09-19: it sat inside the priceMultiple `if` above, so a day with tag
# refusals and no multibuy reconciliation printed nothing about them at all.
if ($tagRefused -gt 0) {
  Write-Output ("Hy-Vee: shelf-tag cross-check - " + $tagRefused + " row(s) REFUSED for pricing BELOW the store's own tagPrice (a price the till will not honour); " + $pass.Requeued + " re-queued to be asked first next run, their last trusted read carried")
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
# so a healthy budgeted day records 3 of 3, not 3 of 535. (Since 2026-09-19 the slice is ~92 products a day, oldest
# first, every one holding an id, so a healthy day reads about 92 of 92; the pair is unchanged.) The two numbers separate only when something
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
  try { $c = @((ConvertFrom-Json ([IO.File]::ReadAllText($pf.FullName))).deals).Count; if ($c -gt $prevMax) { $prevMax = $c } } catch {}
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
  # 2026-09-19, additive like cap_skipped: the carry's age expiry, the shelf-tag re-queue, the history id
  # recovery and the store every fresh row in this file was read at.
  expired_past_carry=$pass.Expired; max_carry_days=$hvCarryDays; requeued_below_tag=$pass.Requeued
  product_ids_recovered=$hvPidRecovered; product_id_conflicts=$hvPidConflicts; read_at_store_id=[string]$StoreId
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

