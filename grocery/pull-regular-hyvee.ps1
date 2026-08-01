<#
  pull-regular-hyvee.ps1 - refresh Hy-Vee to the CURRENT Omaha #01 shelf price. Headless; no browser needed.

  WHY THIS EXISTS. Hy-Vee was the only priced store with no automated pull. Its everyday file was refreshed by
  hand through a browser, went stale between runs, and - worse - whatever captured it read the WRONG NUMBER.
  A Hy-Vee product page carries three different prices and it is very easy to grab the wrong one:

      basePrice             13.99   the REGULAR price
      ssrPricing.price      12.99   *** a DIFFERENT STORE (storeId 1759), not Omaha at all ***
      storeProducts.price   11.99   what Omaha #01 actually charges today   <-- the only correct one

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
param([string]$OutDir = "", [int]$StoreId = 1465, [switch]$Quick)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
$regDir = Join-Path $OutDir 'regular'
if (-not (Test-Path $regDir)) { New-Item -ItemType Directory -Path $regDir -Force | Out-Null }
$todayS = (Get-Date -Format 'yyyy-MM-dd')
. (Join-Path $root 'pu-lib.ps1')   # shared per-unit math - used to prove a productId really is our row's size

$qFile = Join-Path $root 'hyvee\query-b64.txt'
if (-not (Test-Path $qFile)) { throw "missing $qFile (the persisted GraphQL document - it must be sent verbatim)" }
$QUERY = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(((Get-Content $qFile -Raw) -replace '\s','')))

$EP  = 'https://www.hy-vee.com/aisles-online/api/graphql/two-legged/getProductDetailsWithPrice'
$LOC = 'adcb2ae1-f440-4512-bfe8-9624832c72a9'   # Omaha #01 pickup location
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
        return [pscustomobject]@{
          sp = $sp
          soldBy = if ($ri) { [string]$ri.soldByUnitOfMeasure.code } else { '' }
          rawSize = ([string]$r.data.product.size).Trim()
        }
      }
      return $null
    } catch { Start-Sleep -Milliseconds 500 }
  }
  return $null
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

$refreshable = @($work | Where-Object { $_.pid -gt 0 }).Count
Write-Output ("Hy-Vee: " + @($work).Count + " products (" + $refreshable + " refreshable via GraphQL; " + (@($work).Count - $refreshable) + " have no link so their price cannot be re-verified)")

$startT = Get-Date
$MAXMIN = 14
$deals = New-Object System.Collections.ArrayList
$fresh = 0; $fail = 0; $markdown = 0; $stale = 0; $newProd = 0; $mismatch = 0
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
foreach ($w in $work) {
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
      $got = Get-HyVeeStoreProduct ([int]$w.pid)
      Start-Sleep -Milliseconds 120
    }
  }

  if ($got) {
    $sp = $got.sp
    $mult = if ($sp.priceMultiple -and ([double]$sp.priceMultiple) -gt 0) { [double]$sp.priceMultiple } else { 1 }
    $price = [math]::Round(([double]$sp.price) / $mult, 4)
    if ($price -le 0) { $fail++; $got = $null }
    else {
      $bmult = if ($sp.basePriceMultiple -and ([double]$sp.basePriceMultiple) -gt 0) { [double]$sp.basePriceMultiple } else { 1 }
      $base  = if ($sp.basePrice) { [math]::Round(([double]$sp.basePrice) / $bmult, 4) } else { $null }

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
            [void]$sizeConflicts.Add(('{0}  ours=[{1}] hy-vee=[{2}]  qty {3} vs {4}  (productId {5})' -f $w.name, $size, $theirSize, [math]::Round($ourQty,2), [math]::Round($theirQty,2), $w.pid))
            $got = $null   # refuse the refresh; fall through to "could not re-verify"
          }
        }
      }
      if ($got) {
        if (-not $size) { $size = 'each' }

        $isDown = ([bool]$sp.onSale) -and ($null -ne $base) -and ($price -lt $base)
        if ($isDown) { $markdown++ }

        $row = [ordered]@{
          store='Hy-Vee'; item=$w.name; ad_price=('$' + $price); size=$size; regular=$price
          # THE CONTRACT (guards invariant 10). Record what the STORE CHARGES, separately from what we choose
          # to PUBLISH. If anyone ever edits this puller to reach for basePrice again, ad_price and
          # current_price stop agreeing and the guard catches it from the outside. Drop this field and the
          # guard goes blind - which is exactly the state Baker's, Fareway, Sam's and Walmart are still in.
          current_price=[double]$sp.price
          source_ad='Aisles Online current shelf price (storeId 1465, Omaha #01)'
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
        $fresh++
        continue
      }
    }
  }

  # could not re-verify: keep the last known price, but SAY SO with an honest as_of rather than passing it off
  # as today's number. A price we cannot check is not a price we get to call fresh.
  if ($w.prow) {
    $asOf = if ($w.prow.as_of) { [string]$w.prow.as_of } elseif ($prevF.BaseName -match '(\d{4}-\d{2}-\d{2})$') { $Matches[1] } else { $todayS }
    $row = [ordered]@{
      store='Hy-Vee'; item=$w.name; ad_price=[string]$w.prow.ad_price; size=[string]$w.prow.size; regular=$w.prow.regular
      source_ad=[string]$w.prow.source_ad; as_of=$asOf; not_reverified=$true
    }
    [void]$deals.Add($row)
    $stale++
  } else { $fail++ }
}

Write-Output ("Hy-Vee: " + $fresh + " refreshed today (" + $markdown + " marked down), " + $newProd + " newly priced, " + $stale + " not re-verified, " + $mismatch + " REFUSED (productId is a different size than our row), " + $capSkipped + " never asked (wall-clock cap), " + $fail + " failed")

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
  store='Hy-Vee'; week_of=$todayS; price_type='everyday'; price_mode='in-store'
  source='Hy-Vee Aisles Online GraphQL storeProducts.price - the CURRENT shelf price at storeId 1465 (Omaha #01). NOT basePrice (the regular price) and NOT ssrPricing (a different store).'
  size_policy='sizes are OUR verified ones, not Hy-Vee''s - their size field mixes totals, single units of a multipack, and mislabelled units'
  # cap_skipped is ADDITIVE and sits beside the counts that were already here. Every consumer of this file
  # reads .deals or a named top-level field (guards 9/10, generate-board-overrides, refresh-hyvee-links,
  # resolve-hyvee-links - checked, none enumerate the key set), so a new sibling key is safe. It is recorded
  # in the FILE and not just on the console because the console is exactly where this information kept going
  # to die.
  deal_count=$deals.Count; refreshed_today=$fresh; marked_down=$markdown; newly_priced=$newProd; not_reverified=$stale; cap_skipped=$capSkipped; failed=$fail
  deals=$deals.ToArray()
}
($out | ConvertTo-Json -Depth 6) | Set-Content $file -Encoding UTF8
Write-Output ("Hy-Vee everyday prices -> " + $file)
