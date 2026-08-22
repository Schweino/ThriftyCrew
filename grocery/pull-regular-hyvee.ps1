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

if ($SelfTest) {
  # Pure, no network, no writes - placed above the store registry and every request so nothing can skip it.
  . (Join-Path $root 'price-split-lib.ps1')
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

# CAPTURE POLICY BUDGET (2026-08-20). Hy-Vee re-verified 1010 products a run at
# baseline and the coverage ledger has it REGRESSED to 356 - a lane pulling as hard
# as it can until something upstream pushes back. Family Fare showed what that
# eventually costs: Freshop now answers its search with HTTP 400 / error_code 429.
# The budget is total terms / 90 days, decided in capture-policy.ps1 for all seven
# stores so no lane can quietly set its own.
# Products, not terms, is the right unit HERE - this lane re-verifies by product id
# rather than by search term, so the per-request cost is per product.
if (-not $Quick) {
  try {
    . (Join-Path $root 'capture-policy-lib.ps1')
    $hvPlan = Get-CapturePlan -Store 'Hy-Vee' -Today $todayS
    $hvBudget = [int]$hvPlan.TermBudget
    if ($hvBudget -gt 0 -and @($work).Count -gt $hvBudget) {
      # Rotate rather than always taking the head of the list, or the tail is never
      # re-verified and ages out silently - the exact shape of the Sam's 19-day file.
      $hvCur = 0
      $hvCurFile = Join-Path $OutDir 'hyvee-rotation-cursor.json'
      if (Test-Path $hvCurFile) { try { $hvCur = [int](ConvertFrom-Json ([IO.File]::ReadAllText($hvCurFile))).next_index } catch { } }
      $hvAll = @($work); $hvN = $hvAll.Count
      # THE EXPIRING SALES GO FIRST (2026-08-22). The budget above counted one slot per sale reverting
      # today, but the slot was spent on whatever sat at the cursor; the product whose sale just ended
      # waited its quarter. A product answers to its commodity id (from product-urls) - and, for a row
      # with no stored link, to the commodity whose product-urls name matches its name. Brad's rule:
      # "reprice whenever an ad price / sale price / rollback price / instant-savings price drops off."
      $hvExpNames = @{}
      foreach ($xid in @($hvPlan.SaleExpiries)) {
        $xe = $pd.$xid.'Hy-Vee'
        if ($xe -and $xe.name) { $hvExpNames[([string]$xe.name).ToLower().Trim()] = [string]$xid }
      }
      $hvSlice = Select-ExpiryFirstSlice -Items $hvAll -Expiring @($hvPlan.SaleExpiries) -Budget $hvBudget -CursorStart $hvCur -KeyOf {
        param($w)
        $ks = @()
        if ($w.cid) { $ks += [string]$w.cid }
        $nk = ([string]$w.name).ToLower().Trim()
        if ($hvExpNames.ContainsKey($nk)) { $ks += $hvExpNames[$nk] }
        return $ks
      }
      $work = @($hvSlice.Items)
      if ($hvSlice.Prepended -gt 0) {
        Write-Output ("Hy-Vee: " + $hvSlice.Prepended + " product(s) for " + @($hvPlan.SaleExpiries).Count + " expiring sale(s) placed at the FRONT of today's slice: " + ((@($work | Select-Object -First $hvSlice.Prepended) | ForEach-Object { $_.name }) -join '; '))
      }
      # COMMIT AFTER THE CAPTURE LANDS, NOT HERE (2026-08-21). This used to write the
      # cursor at slice time, so a run that then failed - a throttle, a torn write, an
      # exception anywhere in the next 250 lines - moved the rotation past products it
      # never re-verified, and they waited a full quarter for another chance. That is
      # exactly the failure pull-regular-familyfare documented on 2026-08-20, where a
      # cursor advanced ahead of a write that then threw and 686 rows were discarded
      # while their terms were skipped. Only the INTENT is computed here; the write
      # happens beside the output file at the end of the run.
      # Advance by the rotation positions actually walked, not the whole budget: the expiry
      # products at the front were not rotation positions (Select-ExpiryFirstSlice reports it).
      $script:HvCursorNext = [int]$hvSlice.CursorNext
      $script:HvCursorFile = $hvCurFile
      $script:HvCursorFrom = $hvCur
      Write-Output ("Hy-Vee: capture-policy budget = $hvBudget product(s) today (rotation $hvCur/$hvN; quarter $($hvPlan.QuarterDays)d)")
    }
  } catch {
    Write-Warning ("Hy-Vee: capture-policy did not load (" + $_.Exception.Message + ") - running unbudgeted this pass")
  }
}

$refreshable = @($work | Where-Object { $_.pid -gt 0 }).Count
Write-Output ("Hy-Vee: " + @($work).Count + " products (" + $refreshable + " refreshable via GraphQL; " + (@($work).Count - $refreshable) + " have no link so their price cannot be re-verified)")

$startT = Get-Date
$MAXMIN = 14
$deals = New-Object System.Collections.ArrayList
$fresh = 0; $fail = 0; $markdown = 0; $stale = 0; $newProd = 0; $mismatch = 0
# Rows refused because the price sat below the store's own shelf tag. Counted and LISTED, never just
# counted: the two rows this caught on its first run were a 47% and a 42% phantom markdown on the same
# brand, which is a pattern worth seeing rather than a number worth logging.
$tagRefused = 0; $tagRefusedRows = New-Object System.Collections.ArrayList
# rows whose priceMultiple did not reconcile against basePrice - refused, never published (see the divisor
# note at the price calculation below). Counted separately from $fail so a rise in it is visible as its own
# signal rather than blending into ordinary lookup failures.
$multRefused = 0; $multDescriptive = 0
# CAP-SKIPPED IS ITS OWN NUMBER. $stale counts a carry-forward row for THREE unrelated reasons - the
# wall-clock cap stopped us asking, the size-mismatch check refused the answer, or the product has no
# productId to ask with - so a run truncated at $MAXMIN minutes and a healthy run produce the same $stale
# and are indistinguishable from the outside. Counting the cap separately is what makes truncation visible.
# DO NOT "fix" the cap by breaking the loop: every remaining product still needs its pass through the
# carry-forward branch below, and a break would delete those rows from the file outright - real cell drops
# on the board instead of honest not_reverified rows. The cap is meant to stop us ASKING, not stop us WRITING.
$capSkipped = 0
$capWarned = $false
$sizeConflicts = New-Object System.Collections.Generic.List[string]
$captureTerms = New-Object System.Collections.ArrayList
$workOrdinal = 0
foreach ($w in $work) {
  $workKey = ('product-{0:d4}-{1}' -f $workOrdinal, $(if ([int]$w.pid -gt 0) { [string][int]$w.pid } else { 'unidentified' }))
  $asked = $false
  $workReason = ''
  $overCap = (((Get-Date) - $startT).TotalMinutes -gt $MAXMIN)
  # Warn ONCE. This used to sit bare inside the loop, so it re-fired for every remaining product - hundreds
  # of identical lines that say nothing about scale, which is its own kind of silence.
  if ($overCap -and -not $capWarned) {
    $capWarned = $true
    Write-Warning ('Hy-Vee: wall-clock cap of ' + $MAXMIN + ' min hit after ' + $fresh + ' refreshed; every remaining product is kept at its last known price and marked not_reverified')
  }

  $got = $null
  if ($w.pid -gt 0) {
    if ($overCap) { $capSkipped++ }
    else {
      $asked = $true
      $got = Get-HyVeeStoreProduct ([int]$w.pid)
      if (-not $got) { $workReason = 'store product lookup returned no usable offer' }
      Start-Sleep -Milliseconds 120
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
      if ($w.cid) { $unit = [string]$units[[string]$w.cid] }
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
          [void]$tagRefusedRows.Add([ordered]@{ item = [string]$w.name; product_id = [int]$w.pid; price = $price; tag = $(if ($null -ne $res.ecomTagPrice) { $res.ecomTagPrice } else { $res.tagPrice }); why = $tagWhy })
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
          source_ad=$SRC_LABEL
                    as_of=$todayS; product_id=[int]$w.pid
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
    $asOf = if ($w.prow.as_of) { [string]$w.prow.as_of } elseif ($prevF.BaseName -match '(\d{4}-\d{2}-\d{2})$') { $Matches[1] } else { $todayS }
    # Through Get-HyVeeCarryRow, never an inline key list: see its header for the markdown that was being
    # laundered into an everyday price here, and Brad's ruling on what an ended sale must revert to.
    $row = Get-HyVeeCarryRow $w.prow $w.name $asOf $todayS
    [void]$deals.Add($row)
    $stale++
  } else { $fail++ }
  if (-not $asked) {
    $reason = if ($overCap) { 'wall-clock cap before request' } elseif ([int]$w.pid -le 0) { 'worklist product has no retailer product id' } else { 'request not attempted' }
    [void]$captureTerms.Add([ordered]@{ term=$workKey; ordinal=$workOrdinal; outcome='not_attempted'; row_count=0; reason=$reason })
  } else {
    if (-not $workReason) { $workReason = 'source offer could not be verified' }
    [void]$captureTerms.Add([ordered]@{ term=$workKey; ordinal=$workOrdinal; outcome='rejected'; row_count=0; reason=$workReason })
  }
  $workOrdinal++
}

Write-Output ("Hy-Vee: " + $fresh + " refreshed today (" + $markdown + " marked down), " + $newProd + " newly priced, " + $stale + " not re-verified, " + $mismatch + " REFUSED (productId is a different size than our row), " + $capSkipped + " never asked (wall-clock cap), " + $fail + " failed")
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

# COVERAGE, SO THE EXISTING RATCHET CATCHES TRUNCATION - no new threshold invented here. $refreshable is
# every product we hold a productId for, $fresh is how many of them Hy-Vee actually answered for. If the cap
# starts biting, or the GraphQL endpoint starts refusing, examined falls against the baseline and
# audit-coverage-ledger reports it. Measured across the retained history for the baseline entry: refreshed
# sits at 1,006-1,065 since 2026-07-19, worst day-over-day drop -8.1% (07-24), so a 0.15 band gives zero
# findings on real history. Wrapped in its own try/catch inside coverage-lib, which is function-scoped, so a
# missing or broken ledger can never take the price pull down with it.
# -Quick MUST NOT RECORD. It caps the work list at 10 products and writes to hyvee-quick-test.json instead of
# the real capture, but the coverage ledger is a single shared file: a -Quick run would stamp examined=10
# against a baseline of ~1,010 and the ratchet would report a 99% collapse on a deliberate smoke test.
try {
  $covLib = Join-Path $root 'coverage-lib.ps1'
  if ((-not $Quick) -and (Test-Path $covLib)) {
    . $covLib
    if ($fresh -le 0 -and $refreshable -gt 0) {
      Write-CoverageRecord -Check 'pull-regular-hyvee' -OutDir $OutDir -Eligible $refreshable -Examined $fresh -Detail 'Hy-Vee products re-verified against Aisles Online GraphQL' -Blind
    } else {
      Write-CoverageRecord -Check 'pull-regular-hyvee' -OutDir $OutDir -Eligible $refreshable -Examined $fresh -Detail 'Hy-Vee products re-verified against Aisles Online GraphQL'
    }
  }
} catch { }
foreach ($sc in $sizeConflicts) { Write-Warning ("  size conflict, refresh refused: " + $sc) }

# THROTTLE-WIPEOUT GUARD: never let a broken run clobber good data.
$prevMax = 0
foreach ($pf in (Get-ChildItem (Join-Path $regDir 'hyvee-regular-*.json') -EA SilentlyContinue |
    Where-Object { $_.BaseName -match '^hyvee-regular-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending | Select-Object -First 4)) {
  try { $c = @((Get-Content $pf.FullName -Raw | ConvertFrom-Json).deals).Count; if ($c -gt $prevMax) { $prevMax = $c } } catch {}
}
if ((-not $Quick) -and $prevMax -gt 100 -and $deals.Count -lt ($prevMax * 0.5)) {
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
  multiple_descriptive=$multDescriptive; multiple_refused=$multRefused
  capture_terms=$captureTerms.ToArray()
  deals=$deals.ToArray()
}
($out | ConvertTo-Json -Depth 6) | Set-Content $file -Encoding UTF8
Write-Output ("Hy-Vee everyday prices -> " + $file)

# THE ROTATION COMMIT. Deliberately the last thing the run does, and only once the
# everyday file above is on disk: the cursor is a promise that those products were
# actually re-verified, so it must never be written by a run that did not finish.
# Hy-Vee keeps its own cursor file rather than joining capture-cursor.json because it
# rotates by PRODUCT ID while that one indexes commodity-search TERMS - the same
# integer would otherwise mean two different things depending on who read it.
if ($null -ne $script:HvCursorNext -and (Test-Path $file)) {
  try {
    $tmp = "$($script:HvCursorFile).tmp"
    Set-Content -Path $tmp -Encoding UTF8 -Value (@{
      next_index = $script:HvCursorNext
      updated    = (Get-Date).ToString('s')
      note       = 'PRODUCT-index rotation cursor for the Hy-Vee re-verify lane (NOT the commodity-search term cursor in capture-cursor.json). Written only after the everyday file landed.'
    } | ConvertTo-Json)
    Move-Item -LiteralPath $tmp -Destination $script:HvCursorFile -Force
    Write-Output ("Hy-Vee: rotation cursor advanced #$($script:HvCursorFrom) -> #$($script:HvCursorNext) (capture landed)")
  } catch {
    Write-Warning ("Hy-Vee: everyday file landed but the rotation cursor could not be written (" + $_.Exception.Message + ") - the next run re-verifies this same slice; nothing is lost.")
  }
}

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

