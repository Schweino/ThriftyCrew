<#
  build-fareway-regular.ps1 - turns the Fareway STOREFRONT extracts (shop.fareway.com, no-markup in-store
  prices, Omaha) into an engine-ready everyday-price file: out\regular\fareway-regular-<date>.json.
  compare-deals.ps1 auto-discovers out\regular\<store>-regular-*.json (price_type=everyday) with NO code
  change, so writing this file is all it takes to put Fareway's current shelf prices into the comparison.

  Input: one or more raw extract files (default: out\fareway\fareway-shop-*.json), each a JSON array of
  { id, name, price, per, orig, unit, size } as produced by the browser DOM extractor. For each commodity id
  we emit the engine's {store,item,ad_price,size,regular} using the store's existing unit conventions:
    - weighted goods (unit like "$4.99/lb")  -> ad_price="$4.99", size="lb"   (per-unit price)
    - "$X per pound"                          -> ad_price="$X",    size="lb"
    - sold each (per="each", no /lb)          -> ad_price="$X",    size="each"
    - packaged                                -> ad_price="$price",size=<package size>
    - milk  -> size "gallon"     (1-gal pack price is per gallon)
    - eggs  -> size "dozen"      (per-dozen price computed from the count)
  Last writer wins per id (pass core first, then the rest). Skips NOT FOUND / empty-price rows.
#>
param([string[]]$In = @(), [string]$OutDir = "", [string]$Today = "", [string]$ModeVerified = "", [switch]$Force)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
$asofS = if ($Today) { $Today } else { (Get-Date).ToString('yyyy-MM-dd') }
if (-not $In -or $In.Count -eq 0) {
  $In = @(Get-ChildItem (Join-Path $OutDir 'fareway\fareway-shop-*.json') -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { $_.FullName })
}
. (Join-Path $root 'capture-lib.ps1')   # UTF-8 capture read + mojibake repair, shared by every builder
$commod = Get-Content (Join-Path $root 'commodities.json') -Raw | ConvertFrom-Json
$validSet = @{}; $unitMap = @{}; $pintMap = @{}; foreach ($c in $commod) { $validSet[[string]$c.id] = $true; $unitMap[[string]$c.id] = [string]$c.unit; if ($c.PSObject.Properties['pint_oz'] -and $c.pint_oz) { $pintMap[[string]$c.id] = [double]$c.pint_oz } }

$byId = [ordered]@{}
$byUrl = [ordered]@{}
# Rows dropped because the catalog slug and the commodity's canonical unit state different bases. Reported
# below rather than silently swallowed: a dropped cell must always be a named decision, never a quiet gap.
$basisConflicts = 0
$basisConflictIds = @()
foreach ($f in $In) {
  if (-not (Test-Path $f)) { continue }
  foreach ($r in (Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json)) {
  # The storefront capture is UTF-8; reading it under the system ANSI codepage turned brand names into
  # mojibake that then shipped to the board ("Mott(junk)s", "Saran(junk)"). Repair on ingest - see capture-lib.
  if ($r.PSObject.Properties['name']) { $r.name = Repair-Mojibake ([string]$r.name) }
    $id = [string]$r.id
    if (-not $validSet.ContainsKey($id)) { continue }
    $name = [string]$r.name
    if (-not $name -or $name -match 'NOT FOUND') { continue }
    # Fareway's capture writes price either bare ("5.39") or already-signed ("$5.39"); every branch below
    # prefixes '$', so the signed form shipped "$$5.39" to the board (mirin + chipotle-adobo chips, 2026-07-28).
    # Strip the sign once here so there is exactly one, whatever the capture handed us.
    $price = ([string]$r.price).Trim().TrimStart('$'); if (-not $price) { continue }
    $per = ([string]$r.per).ToLower()
    $unit = [string]$r.unit
    $size = [string]$r.size
    $adp = ''; $sz = ''
    $um = [regex]::Match($unit, '\$?\s*([\d.]+)\s*/\s*(lb|oz|gal|kg|ct|ea|each|pound)')
    if ($um.Success) {
      $adp = '$' + $um.Groups[1].Value
      $u = $um.Groups[2].Value; if ($u -eq 'pound') { $u = 'lb' }; if ($u -eq 'ea') { $u = 'each' }
      $sz = $u
    } elseif ($per -eq 'pound') { $adp = '$' + $price; $sz = 'lb' }
      elseif ($per -eq 'each')  { $adp = '$' + $price; $sz = 'each' }
      else { $adp = '$' + $price; $sz = $size }
    # SLUG BASIS OVERRIDE (2026-07-23): Fareway's catalog slug names the sell basis for by-weight
    # produce - ".../products/16606119-cantaloupe-melon-1-lb" is priced PER POUND even when the tile's
    # DOM says "each". Trusting the DOM published $0.88 as the price of a WHOLE melon (real price
    # ~3x that); the band caught it and Fareway just vanished from the row. The slug is the catalog's
    # own statement of basis, so it outranks the tile text.
    if ($r.url -and "$($r.url)" -match '(?i)-1-lb(?:-|$)' -and $sz -eq 'each') { $sz = 'lb' }
    # Did anything above establish a WEIGHT basis for this row? Either the tile's own unit rate ("$1.49/lb"),
    # or the catalog slug. Both are the store stating that the price is per pound, not per item.
    $weightBasis = ($sz -match '^(lb|oz|kg)$')
    # canonical-unit fixups so the engine can price the item in the commodity's unit
    $cu = if ($unitMap.ContainsKey($id)) { $unitMap[$id] } else { '' }
    # A PER-POUND RATE MUST NEVER BE RELABELLED AS A PER-ITEM PRICE (2026-07-30).
    # The $cu -eq 'each' branch below rewrites $sz to 'each' while KEEPING whatever $adp was parsed. When the
    # tile stated a weight rate, $adp is that rate, and the rewrite silently turns "$1.49 per pound" into
    # "$1.49 for one item". Honeydew is the live case: Fareway's capture reads price=5.96, per=package,
    # unit=$1.49/lb, size="About 4.0 lb / package", url=.../17668522-honeydew-melon-1-lb. Every one of those
    # says four pounds for $5.96. The board published $1.49 EACH, took the CROWN from Baker's genuine $2.99
    # each, was written up with the store's own arithmetic on 2026-07-29, and was still the published cheapest
    # price the day after.
    # The fix is NOT to pick a winner between the two bases, and NOT to compute $5.96 x something here: the
    # capture's own package price is right there, but re-deriving a published number from a plausible reading
    # is the blind-swap trap that has twice removed correct data in this repo. Two statements of basis
    # disagree, so the honest output is no number. The row is dropped and NAMED - a missing cell is visible on
    # the page and a wrong crown is not.
    # A counted pack ("12 ct") is NOT a conflict: the count is the quantity, not a weight claim.
    if ($weightBasis -and $cu -eq 'each' -and $size -notmatch '\d+\s*ct\b') {
      $basisConflicts++
      $basisConflictIds += ("$id (" + $name + ")")
      continue
    }
    if ($cu -eq 'each') {
      # a loaf / avocado / ear / whole melon = one each; the current price IS the per-each price.
      # BUT a counted pack ("12 ct" buns/popsicles/tampons) must KEEP its count so the engine divides
      # to a true per-item price - force-writing 'each' here made $3.99/12ct read as $3.99 PER ITEM.
      if ($size -match '\d+\s*ct\b') { $sz = $size }
      else { $sz = 'each' }
      if ($adp -notmatch '^\$[0-9.]+$') { $adp = '$' + $price }
    } elseif ($cu -eq 'gallon') { $sz = 'gallon' }
      elseif ($cu -eq 'dozen') {
        $ct = [regex]::Match($size, '([\d.]+)\s*ct')
        if ($ct.Success) { $n=[double]$ct.Groups[1].Value; if ($n -gt 0) { $adp = '$' + ([math]::Round([double]$price / ($n/12), 2)); $sz = 'dozen' } }
        else { $sz = 'dozen' }
      }
    # by-VOLUME container -> canonical dry weight: a fresh-berry "pint" is a dry clamshell with no weight on the
    # label, so normalize it to the commodity's declared pint_oz (blueberries = 11.2 oz, US retail standard). This
    # makes BOTH the board price and the "See item" link size a real weight, so it prices per-ounce like the
    # 18-oz clamshells and the link's per-unit matches the board by construction. Only bare pints, never a size
    # that already states a weight.
    if ($pintMap.ContainsKey($id) -and ($sz.ToLower() -match '\b(pt|pint)s?\b') -and ($sz.ToLower() -notmatch '\b(oz|ounce|ounces|lb|lbs|pound|pounds|gram|grams|\bg\b|ml|liter|litre)\b')) {
      $pnM = [regex]::Match($sz.ToLower(), '(\d+(?:\.\d+)?)\s*(?:pt|pint)s?\b'); $pn = if ($pnM.Success) { [double]$pnM.Groups[1].Value } else { 1 }
      $sz = ('{0} oz' -f ($pn * $pintMap[$id]))
    }
    $reg = if ($r.orig -and "$($r.orig)" -ne '') { '$' + ([string]$r.orig).Trim().TrimStart('$') } else { '' }

    # THE CONTRACT (guards invariant 10): record what the STORE CHARGES, separately from what we publish.
    # `current_price` is parsed from the number the storefront is showing right now, in the SAME basis as
    # ad_price (per-lb for weighted goods, pack price for packaged). ad_price is built from that same store
    # number - but as a SEPARATE assignment, which is the whole point: if anyone ever rewires ad_price to
    # publish `orig` (the was-price) instead, the two stop agreeing and guard 10 fails the publish. That is
    # exactly the bug that had Hy-Vee sirloin at $13.99/lb while the store charged $11.99.
    $curNum = 0.0
    [void][double]::TryParse(($adp -replace '[^0-9.]',''), [ref]$curNum)
    $row = [ordered]@{ store='Fareway'; item=$name; ad_price=$adp; size=$sz; regular=$reg; source_ad='shop.fareway.com'; as_of=$asofS }
    # identity rule: the link belongs ON the price row (derive-links reads link_url verbatim), not only in
    # the url-inputs side file - two homes for one fact is how they drift.
    if ($r.url -and "$($r.url)" -ne '') { $row['link_url'] = [string]$r.url }
    if ($curNum -gt 0) { $row['current_price'] = $curNum }

    # base_price (the was-price) ONLY when it is in the same basis as what we publish. For a weighted good we
    # publish a per-POUND price while `orig` is the PACK's was-price - recording that as base_price would be
    # comparing a per-lb number to a per-pack one, which is how you end up "verifying" nonsense.
    $origNum = 0.0
    [void][double]::TryParse((([string]$r.orig) -replace '[^0-9.]',''), [ref]$origNum)
    if (($origNum -gt 0) -and ($sz -ne 'lb')) { $row['base_price'] = $origNum }
    if (($origNum -gt 0) -and ($sz -ne 'lb') -and ($curNum -lt ($origNum - 0.005))) { $row['marked_down'] = $true }

    $byId[$id] = $row
    # emit the product-URL input using the SAME price+size the board uses, so the "See item" link's per-unit
    # equals the board per-unit by construction (a Fareway price can never render without a matching link).
    if ($r.url -and "$($r.url)" -ne '') { $byUrl[$id] = [ordered]@{ id=$id; url=[string]$r.url; price=($adp -replace '[^0-9.]',''); size=$sz; name=$name } }
  }
}
$deals = @($byId.Values)
# price_mode/mode_verified come from the CAPTURE, not an assumption here.
# Fareway is an Instacart storefront whose DEFAULT session serves a marked-up DELIVERY price. This script used to
# hard-code price_mode='in-store' to satisfy audit-price-mode - which DEFEATED the guard: on 2026-07-15 the whole
# storefront extract was found to be delivery-priced (butter +14%, cream cheese +50%, OJ +37%) yet stamped
# in-store, putting 320 marked-up cells on the board. FIX: only claim in-store when the browser capture PROVES it
# by passing -ModeVerified <yyyy-MM-dd> (it set the In-Store fulfilment toggle and confirmed it that day). With no
# proof we emit price_mode='unverified' (no mode_verified) so audit-price-mode fails AND compare-deals drops the
# file - the marked-up prices can never silently reach the board again.
$pmode = if ($ModeVerified) { 'in-store' } else { 'unverified' }
$doc = [ordered]@{ store='Fareway'; price_type='everyday'; price_mode=$pmode; mode_verified=$ModeVerified; source='shop.fareway.com (Instacart Storefront, Omaha); mode proven at capture only'; generated=$asofS; deals=$deals }
if (-not $ModeVerified) { Write-Warning "build-fareway-regular: no -ModeVerified passed -> price_mode='unverified'. The capture MUST set In-Store fulfilment and pass -ModeVerified <date>, or Fareway is (correctly) excluded from the board." }
$regDir = Join-Path $OutDir 'regular'
New-Item -ItemType Directory -Force -Path $regDir | Out-Null
# NEVER-SHRINK GUARD (2026-07-17, same rule as the Family Fare throttle-wipeout guard). The regular file can
# hold MORE rows than any one shop capture: walled-store passes accumulate verified rows into it that a rebuild
# from shop files alone cannot reproduce (382 verified rows vs 89 in the newest shop file, the day this nearly
# overwrote them). Replacing a bigger file with a smaller one is a partial-pull-as-overwrite bug, not a refresh.
$regPath = Join-Path $regDir "fareway-regular-$asofS.json"
if (Test-Path $regPath) {
  $old = $null; try { $old = Get-Content $regPath -Raw | ConvertFrom-Json } catch {}
  if ($old -and (@($old.deals).Count -gt ($deals.Count * 1.2)) -and -not $Force) {
    throw ("REFUSING to overwrite " + (Split-Path $regPath -Leaf) + ": it holds " + @($old.deals).Count + " rows, this rebuild produced only " + $deals.Count + ". That file accumulated verified rows a shop-file rebuild cannot reproduce. Pass -Force only if the shrink is intended.")
  }
}
$doc | ConvertTo-Json -Depth 5 | Set-Content $regPath -Encoding UTF8
# product-URL input for merge-product-urls.ps1 (store key 'fareway'): every priced Fareway cell that has a
# storefront product page gets a link whose price+size match the board exactly.
$urlRows = @($byUrl.Values)
if ($urlRows.Count) {
  $uiDir = Join-Path $OutDir 'url-inputs'; New-Item -ItemType Directory -Force -Path $uiDir | Out-Null
  ($urlRows | ConvertTo-Json -Depth 4) | Set-Content (Join-Path $uiDir 'store-fareway1-urls.json') -Encoding UTF8
  Write-Output ("store-fareway1-urls.json: $($urlRows.Count) Fareway product links")
}
Write-Output ("fareway-regular-$asofS.json: $($deals.Count) commodities")
if ($basisConflicts -gt 0) {
  Write-Output ("  BASIS CONFLICT - dropped $basisConflicts row(s): the catalog slug says per-pound but the commodity is priced per-each, so the price could mean either a pound or a whole item. No number is honest here; these cells are absent by decision, not by accident: " + (($basisConflictIds | Sort-Object -Unique) -join ', '))
}
$deals | ForEach-Object { "  {0,-20} {1,-8} {2}" -f $_.item.Substring(0,[Math]::Min(20,$_.item.Length)), $_.ad_price, $_.size }
# 2026-07-23: a partial storefront pull must not shrink the board - carry items the previous capture had
# and this one missed (as_of-stamped, 14-day cap). See carry-forward-regular.ps1 for why these stores
# can't use the Walmart/Sam's union instead.
& powershell -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'carry-forward-regular.ps1') -Store fareway | Write-Output
# 2026-07-23: a shallow pull can also DEGRADE rows it does return - same item, same shelf price, but the
# pack count gone from the size field ("48 ct" -> "each"). The per-unit engine then computes a per-item
# price 48x too high and the band drops the store from the row. Re-adopt the prior capture's size when
# item AND price are identical. See heal-degraded-sizes.ps1.
& powershell -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'heal-degraded-sizes.ps1') -Store fareway | Write-Output

