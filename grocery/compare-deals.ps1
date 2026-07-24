<#
  compare-deals.ps1 - The Omaha cross-store comparison engine.
  Brand-agnostic: every deal is bucketed into a COMMODITY (chicken breast, cottage cheese, ...),
  its price + size normalized to ONE canonical unit (per lb / oz / fl oz / each / dozen), then the
  cheapest store per commodity is named. Brand does not matter; unit price does.

  Input : the latest out\ads-YYYY-MM-DD.json from pull-grocery-ads.ps1 (Hy-Vee/Aldi/Family Fare),
          plus optional out\bakers\bakers-deals-*.json and out\sams\sams-deals-*.json (same shape).
  Output: out\comparison-YYYY-MM-DD.json + a "Cheapest in Omaha this week" report.

  Usage:  powershell -ExecutionPolicy Bypass -File compare-deals.ps1
          powershell -ExecutionPolicy Bypass -File compare-deals.ps1 -MinStores 1   (show single-store too)
#>
param(
  [string]$AdsFile = "",
  [string]$BakersFile = "",
  [string]$SamsFile = "",
# Sam's captures are partial (see the loader below): every capture inside this window is loaded, and the
# freshest one that covers a given commodity wins it. Warehouse "everyday" prices are stable enough for this;
# tighten it if Sam's starts moving prices weekly.
[int]$SamsMaxAgeDays = 14,
  # Walmart's out\regular captures are unioned the same way (see the everyday-price loader): a partial daily
  # refresh must not shrink the board, so every Walmart capture inside this window is loaded and the freshest
  # one covering each commodity wins. Walmart is everyday-priced, so an older capture is only ever a gap-filler.
  [int]$WalmartMaxAgeDays = 14,
  [string]$FarewayFile = "",
  # DEFAULT 1, matching the daily pipeline (check-ad-cycles passes -MinStores 1 explicitly). It was 2 until
  # 2026-07-23, when a MANUAL rerun during the Fareway incident silently dropped every single-store tail
  # commodity (achiote-paste, berbere, onion-soup-mix...) from the board - the pipeline and a human running
  # the same script must produce the same board.
  [int]$MinStores = 1,
  [string]$OutDir = "",
  [string]$CommoditiesFile = "",
  [string]$OutName = "comparison",
  [string]$RegularDir = "",
  [string]$ExtraDir = "",
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir)  { $OutDir  = Join-Path $root 'out' }
if (-not $AdsFile) { $AdsFile = (Get-ChildItem (Join-Path $OutDir 'ads-*.json') | Sort-Object Name -Descending | Select-Object -First 1).FullName }
if (-not $CommoditiesFile) { $CommoditiesFile = Join-Path $root 'commodities.json' }
$cdoc = Get-Content $CommoditiesFile -Raw | ConvertFrom-Json
# a rule FILE may be a bare array (staples) or a wrapper { global_exclude:[...], commodities:[...] } (recipe
# set, which relaxes sauce/canned/frozen since those items legitimately ARE those forms).
if ($cdoc.PSObject.Properties['commodities']) { $commodities = $cdoc.commodities; $GEX_OVERRIDE = @($cdoc.global_exclude) } else { $commodities = $cdoc; $GEX_OVERRIDE = $null }
# sanity price bands (magnitude/garbage net + health check)
$BANDS = @{}
$bandsFile = Join-Path $root 'price-bands.json'
if (Test-Path $bandsFile) { $bDoc = Get-Content $bandsFile -Raw | ConvertFrom-Json; foreach ($p in $bDoc.bands.PSObject.Properties) { $BANDS[$p.Name] = $p.Value } }
# rules may carry their own inline band_min/band_max (recipe set) - these OVERRIDE price-bands.json because a
# recipe commodity that shares an id with a staple (butter/milk/peanut-butter) may use a DIFFERENT unit (oz vs
# lb), so the staple's per-lb band would wrongly reject every per-oz match.
foreach ($c in $commodities) { if ($c.PSObject.Properties['band_min']) { $BANDS[[string]$c.id] = [pscustomobject]@{ min=[double]$c.band_min; max=[double]$c.band_max } } }
function Test-Band($id, $up) { if (-not $BANDS.ContainsKey($id)) { return $true }; $b = $BANDS[$id]; return ([double]$up -ge [double]$b.min -and [double]$up -le [double]$b.max) }
# bulk / non-single-unit heuristic on a size string (so the winner line can flag "10 lb pack" etc.)
function Test-Bulk([string]$size, [string]$name) {
  $t = (("" + $size + " " + $name)).ToLower()
  if ($t -match '\bcase\b|\broll\b|\bvalue pack\b|family pack|bulk') { return $true }
  $m = [regex]::Match($t, '(\d+(?:\.\d+)?)\s*(lb|lbs|pound)')  ; if ($m.Success -and [double]$m.Groups[1].Value -ge 4)  { return $true }
  $m = [regex]::Match($t, '(\d+(?:\.\d+)?)\s*oz')             ; if ($m.Success -and [double]$m.Groups[1].Value -ge 32) { return $true }
  $m = [regex]::Match($t, '(\d+)\s*(ct|count|pk|pack|dozen)') ; if ($m.Success -and [double]$m.Groups[1].Value -ge 18) { return $true }
  return $false
}
# Sam's Club is the only store requiring a paid membership (100% deterministic) - drives the "no-membership" winner.
function Test-Membership([string]$store) { return ($store -eq "Sam's Club") }

# ---------------------------------------------------------------- unit conversion
# canonical amount = how many <category unit> are in "$num $token"
function Convert-ToUnit([double]$num, [string]$token, [string]$unit) {
  $t = $token.ToLower().Trim().TrimEnd('.')
  switch ($unit) {
    'lb' {
      if ($t -match '^(lb|lbs|pound|pounds|#)$') { return $num }
      if ($t -match '^(oz|ounce|ounces)$')       { return $num / 16.0 }
      if ($t -match '^(g|gram|grams)$')          { return $num / 453.592 }
      return $null
    }
    'oz' {
      if ($t -match '^(oz|ounce|ounces|fl\s*oz)$') { return $num }
      if ($t -match '^(lb|lbs|pound|pounds|#)$')   { return $num * 16.0 }
      if ($t -match '^(g|gram|grams)$')            { return $num / 28.3495 }
      return $null
    }
    'floz' {
      if ($t -match '^(fl\s*oz|floz|oz|ounce|ounces)$') { return $num }
      if ($t -match '^(gal|gallon|gallons)$')           { return $num * 128.0 }
      if ($t -match '^(qt|quart|quarts)$')              { return $num * 32.0 }
      if ($t -match '^(pt|pint|pints)$')                { return $num * 16.0 }
      if ($t -match '^(l|liter|liters|ltr)$')           { return $num * 33.814 }
      if ($t -match '^(ml)$')                           { return $num / 29.5735 }
      return $null
    }
    'gallon' {
      if ($t -match '^(gal|gallon|gallons)$')           { return $num }
      if ($t -match '^(fl\s*oz|floz|oz|ounce|ounces)$') { return $num / 128.0 }
      if ($t -match '^(qt|quart|quarts)$')              { return $num / 4.0 }
      if ($t -match '^(pt|pint|pints)$')                { return $num / 8.0 }
      if ($t -match '^(l|liter|liters|ltr)$')           { return $num * 0.264172 }
      return $null
    }
    'each' {
      if ($t -match '^(ct|count|ea|each|pk|pack|pkg|package|bunch|head|loaf)$') { return $num }
      if ($t -match '^(dozen|doz)$') { return $num * 12.0 }
      return $null
    }
    'dozen' {
      if ($t -match '^(dozen|doz)$')          { return $num }
      if ($t -match '^(ct|count|ea|each)$')   { return $num / 12.0 }
      return $null
    }
  }
  return $null
}

# ---------------------------------------------------------------- size parsing
# returns canonical amount (in category unit) from a size string, or $null if not derivable
function Get-SizeAmount([string]$sizeText, [string]$unit) {
  if (-not $sizeText) { return $null }
  $s = ($sizeText -replace "`n", ' ').ToLower()
  # bare unit token (e.g. size just "lb" or "each") => the ad is priced PER that unit => amount = 1 unit
  $st = $s.Trim().TrimEnd('.')
  if ($st -match '^(lb|lbs|pound|pounds|#|oz|ounce|ounces|fl\s*oz|floz|each|ea|ct|count|dozen|doz|gal|gallon|qt|quart|pt|pint|liter|litre|l|ml)$') {
    $one = Convert-ToUnit 1 $st $unit
    if ($one -ne $null) { return $one }
  }
  # fractional size like "1/2 gal" or "3/4 lb" -> 0.5 / 0.75 of that unit (must run before the plain-number match)
  # A FRACTION HAS THE SMALLER NUMBER ON TOP. "6/4 oz" is not six-quarters of an ounce, it is the count/size
  # pack idiom stores print for cup multipacks: 6 cups of 4 oz = 24 oz. Dividing it gave 1.5 oz, so Mott's Apple
  # Sauce priced at $2.33/oz - 9x its band, dropped, and Family Fare vanished from the applesauce row.
  # So: numerator < denominator is a real fraction; otherwise it is <count>/<each-size> and the total is a
  # product, not a quotient.
  $mf = [regex]::Match($s, '(\d+)\s*/\s*(\d+(?:\.\d+)?)\s*(fl\s*oz|floz|oz|ounce|ounces|lb|lbs|pound|pounds|gal|gallon|qt|quart|pt|pint|liter|litre|ml)\b')
  if ($mf.Success -and ([double]$mf.Groups[2].Value -ne 0)) {
    $fa = [double]$mf.Groups[1].Value; $fb = [double]$mf.Groups[2].Value
    if ($fa -lt $fb) {
      $conv = Convert-ToUnit ($fa / $fb) $mf.Groups[3].Value $unit
      if ($conv -ne $null) { return $conv }
    } else {
      $per = Convert-ToUnit $fb $mf.Groups[3].Value $unit
      if ($per -ne $null) { return $fa * $per }
    }
  }
  # "24 ct 16.9 oz" style multipack -> total = count * each-size.
  # The each-size token must include GAL/QT/PT/LB, not just oz: Sam's "Member's Mark Distilled White
  # Vinegar, 1 gal., 2 pk." is TWO gallons, and with gal missing here it fell through and was priced
  # as ONE, making Sam's look 2x more expensive than it is.
  # The count and its token may be HYPHENATED. "6-pack 12 fl oz" failed here (\s* cannot cross the "-"), fell
  # through to the plain first-number scan, and became 12 fl oz - so Liquid Death sparkling water priced at
  # $0.58/fl oz instead of $0.097, 5x its band, and Baker's dropped off the row. "6 pk 4 oz" matched fine, which
  # is exactly why it went unnoticed: the bug only bites the spelled-out, hyphenated form.
  $mm = [regex]::Match($s, '(\d+(?:\.\d+)?)\s*[- ]?\s*(?:ct|count|pk|packs?)\D+(\d+(?:\.\d+)?)\s*(fl\s*oz|floz|oz|ml|l\b|gal|gallon|qt|quart|pt|pint|lbs?|pound)\b')
  if ($mm.Success -and ($unit -eq 'oz' -or $unit -eq 'floz' -or $unit -eq 'gallon' -or $unit -eq 'lb')) {
    $cnt = [double]$mm.Groups[1].Value; $each = [double]$mm.Groups[2].Value; $tok = $mm.Groups[3].Value
    $per = Convert-ToUnit $each $tok $unit
    if ($per -ne $null) { return $cnt * $per }
  }
  # size RANGE like "4 to 6 oz" / "9 or 12 oz": in grocery ads this means CHOOSE YOUR SIZE at one price, so
  # the LARGER size is genuinely purchasable and its per-unit is the honest achievable price (a shopper picks
  # the 12 oz at $3.99). Using the smaller end would inflate per-units and band-drop real deals - the frozen
  # regression exposed exactly that. Max also matches the engine's long-standing behavior (the old first
  # "<number><unit>" scan landed on the unit-adjacent, larger number).
  $rng = [regex]::Match($s, '(\d+(?:\.\d+)?)\s*(?:to|or|-|&ndash;|thru)\s*(\d+(?:\.\d+)?)\s*(fl\s*oz|floz|oz|ounce|ounces|lb|lbs|pound|pounds|gal|gallon|qt|quart|pt|pint|liter|litre|ml|g|gram|grams|ct|count)\b')
  if ($rng.Success -and ([double]$rng.Groups[1].Value -lt [double]$rng.Groups[2].Value)) {
    # ASCENDING pairs only: "24-12 oz cans" is the count-x-size print idiom (24 cans of 12 oz), not a range -
    # let it fall through to the multipack/first-number logic instead of misreading it as 24 oz total.
    $hi = [double]$rng.Groups[2].Value; $tok = $rng.Groups[3].Value
    $rc = Convert-ToUnit $hi $tok $unit; if ($rc -ne $null) { return $rc }
  }
  # first "<number> <unit-token>" occurrence
  $m = [regex]::Match($s, '(\d+(?:\.\d+)?)\s*(fl\s*oz|floz|oz|ounce|ounces|lb|lbs|pound|pounds|#|gal|gallon|qt|quart|pt|pint|liter|litre|\bl\b|ml|g|gram|grams|dozen|doz|ct|count|ea|each|pk|pack|pkg|bunch|head|loaf)\b')
  if ($m.Success) {
    $num = [double]$m.Groups[1].Value; $tok = $m.Groups[2].Value
    return (Convert-ToUnit $num $tok $unit)
  }
  # bare count like "1 ct" already caught; bare number with no unit -> treat as each count
  $m2 = [regex]::Match($s, '^\s*(\d+(?:\.\d+)?)\s*$')
  if ($m2.Success -and ($unit -eq 'each' -or $unit -eq 'dozen')) { return (Convert-ToUnit ([double]$m2.Groups[1].Value) 'ct' $unit) }
  return $null
}

# ---------------------------------------------------------------- price parsing
# Normalize spelled-out small numbers to digits so a word-form BOGO ("buy two, get one free" -
# how Hy-Vee's Flipp feed writes them) parses like "buy 2 get 1 free". Only touches the price text,
# never the stored name or category matching, so it can't create a false commodity match.
function ConvertTo-DigitNumerals([string]$t) {
  if (-not $t) { return $t }
  return ($t -replace '(?i)\bone\b','1' -replace '(?i)\btwo\b','2' -replace '(?i)\bthree\b','3' -replace '(?i)\bfour\b','4' -replace '(?i)\bfive\b','5' -replace '(?i)\bsix\b','6' -replace '(?i)\bseven\b','7' -replace '(?i)\beight\b','8' -replace '(?i)\bnine\b','9' -replace '(?i)\bten\b','10')
}
# returns @{ per_item; kind; note } where per_item = dollars for ONE package of the listed size,
# or $null if price can't be read. kind flags per-lb / per-each markers found in the text.
function Get-ItemPrice([string]$priceText, [string]$nameText, $regular) {
  $p = ConvertTo-DigitNumerals ((("" + $priceText + " " + $nameText) -replace "`n", ' '))
  $note = ''
  # PACKAGE SIZE vs PER-LB PRICE. This string is priceText + nameText, so a product NAMED
  # "Yellow Onions, 3 lb Bag" used to trip the per-lb marker and its $2.39 BAG price got published
  # as $2.39 PER POUND (3x the real price). Hy-Vee's identical bag escaped only because its name
  # reads "3-Pound Bag". The tell: a real per-lb price has the number attached to a $ ("$1.68 lb."),
  # while a package size does not ("3 lb Bag"). So strip un-priced "<n> lb" quantities before
  # looking for the marker; "$1.68 lb." survives and still marks per-lb.
  # The lookbehind must reject a preceding $, digit OR dot: without (?<![\d.]) the engine skips the
  # blocked "$1" and instead matches the "88 lb" INSIDE "$1.88 lb.", stripping a real per-lb marker
  # and pricing Hy-Vee grapes at exactly $1.00/lb (1.88 / 1.88). Decimal fragments must never match.
  $pForMarker = $p -replace '(?i)(?<![\d.$])(?<!\$\s)\b\d+(?:\.\d+)?\s*-?\s*lbs?\.?\b', ' '
  $perlb = ($pForMarker -match '(?i)(per\s*lb|/\s*lb|\blb\.?\b|a\s*pound|per\s*pound)')
  # THE PER-LB TRAP ABOVE, TWICE OVER, ON PER-EACH (found 2026-07-16):
  # (1) "each" carried NO WORD BOUNDARY, so any product whose name contains it set the per-each marker and the
  #     engine published the PACK price as the price of ONE ITEM. "Clorox Disinfecting BLEACH Free Wipes"
  #     ($3.99, 35 ct) priced at $3.99 PER WIPE; "Member's Mark Diced PEACH Cups" ($10.98, 24 pk) at $10.98 PER
  #     CUP. B-l-each. P-each. Both 24-35x over, both silently dropped by the band, so the stores just vanished
  #     from those rows instead of publishing an obvious lie - which is why it survived so long.
  # (2) "\bea\b" matched a pack COUNT, not a price marker: "Arm & Hammer ... Power Paks 42 Ea" ($12.49) came out
  #     $12.49 per POD instead of $0.297.
  # The tell is the same one $pForMarker uses for lb: a real per-each price has its number attached to a $
  # ("$1.99 ea"), a pack size does not ("42 Ea"). So strip un-priced "<n> ea/each/ct/pk" quantities BEFORE
  # looking for the marker, and require a whole word for "each".
  $pForEach = $p -replace '(?i)(?<![\d.$])(?<!\$\s)\b\d+(?:\.\d+)?\s*-?\s*(?:ea|each|ct|count|pk|packs?)\.?\b', ' '
  $pereach = ($pForEach -match '(?i)(per\s*ea|/\s*ea|\bea\.?\b|\beach\b|per\s*ct|/\s*ct)')
  $reg = $null; if ($regular -ne $null -and "$regular" -ne '') { try { $reg = [double]$regular } catch {} }

  # BOGO: buy N get K free
  $m = [regex]::Match($p, '(?i)buy\s*(\d+)\s*,?\s*get\s*(\d+)\s*(?:of\s*equal[^,]*)?free')
  if ($m.Success -and $reg) {
    $n=[double]$m.Groups[1].Value; $k=[double]$m.Groups[2].Value
    return @{ per_item = ($n*$reg)/($n+$k); kind=@{perlb=$perlb;pereach=$pereach}; note="BOGO buy $n get $k free (reg $reg)" }
  }
  # buy N get K for $Z
  $m = [regex]::Match($p, '(?i)buy\s*(\d+)\s*,?\s*get\s*(\d+)\s*for\s*\$?\s*([\d.]+)')
  if ($m.Success -and $reg) {
    $n=[double]$m.Groups[1].Value; $k=[double]$m.Groups[2].Value; $z=[double]$m.Groups[3].Value
    return @{ per_item = (($n*$reg)+($k*$z))/($n+$k); kind=@{perlb=$perlb;pereach=$pereach}; note="buy $n get $k for `$$z (reg $reg)" }
  }
  # buy N get K PERCENT off
  $m = [regex]::Match($p, '(?i)buy\s*(\d+)\s*,?\s*get\s*(\d+)\s*(\d+)\s*%\s*off')
  if ($m.Success -and $reg) {
    $n=[double]$m.Groups[1].Value; $k=[double]$m.Groups[2].Value; $pct=[double]$m.Groups[3].Value/100.0
    return @{ per_item = (($n*$reg)+($k*$reg*(1-$pct)))/($n+$k); kind=@{perlb=$perlb;pereach=$pereach}; note="buy $n get $k $($pct*100)% off (reg $reg)" }
  }
  # N for $M  /  N/ $M
  $m = [regex]::Match($p, '(?i)(\d+)\s*(?:for|/)\s*\$\s*([\d.]+)')
  if ($m.Success) {
    $n=[double]$m.Groups[1].Value; $tot=[double]$m.Groups[2].Value
    if ($n -gt 0) { return @{ per_item = $tot/$n; kind=@{perlb=$perlb;pereach=$pereach}; note="$n for `$$tot" } }
  }
  # cents: "88" with cent sign or explicit cents
  $m = [regex]::Match($p, '(\d+)\s*(?:¢|cents?)')
  if ($m.Success) { return @{ per_item = ([double]$m.Groups[1].Value)/100.0; kind=@{perlb=$perlb;pereach=$pereach}; note='cents' } }
  # plain dollar amount (take the LAST one, which is usually the sale/ad price)
  $dm = [regex]::Matches($p, '\$\s*([\d]+(?:\.\d{1,2})?)')
  if ($dm.Count -gt 0) {
    $val=[double]$dm[$dm.Count-1].Groups[1].Value
    return @{ per_item = $val; kind=@{perlb=$perlb;pereach=$pereach}; note='' }
  }
  return $null
}

# ---------------------------------------------------------------- unit price for a categorized deal
function Get-PackCount($text) {
  if (-not $text) { return $null }
  $t = ("" + $text).ToLower()
  # 'ea'/'each' belong here: stores write a pack count as "42 Ea" / "12 Ea" every bit as often as "12 ct"
  # (Family Fare's Freshop feed does it throughout). Without them a 42-pod tub of laundry pacs had NO pack count
  # at all and priced as ONE pod. Safe next to a weight: "About 1.56 lb each" cannot match, because the count
  # must sit immediately before the unit and " lb " breaks it.
  $m = [regex]::Match($t, '(?:per\s*)?(\d+)\s*[- ]?\s*(?:pack|pk|count|ct|each|ea)\b')
  if ($m.Success) { $n = [int]$m.Groups[1].Value; if ($n -gt 1) { return $n } }
  return $null
}
# Conservative: return a unit price ONLY when confidently derivable; else $null (dropped, not guessed).
function Get-UnitPrice($deal, $cat) {
  $pr = Get-ItemPrice $deal.price_text $deal.name $deal.regular
  if (-not $pr) { return $null }
  $unit = $cat.unit
  $plain = ($pr.note -eq '')   # plain price (not a multibuy/BOGO that already yields per-item)
  # weight-based PACKAGE descriptor (e.g. "$4.99 Per 2-Lb. Pkg", "3 lb bag") -> the price is for N lb, DIVIDE.
  # (only fires on an explicit package cue so it never eats a real per-lb price like "$1.68 lb.")
  if ($unit -eq 'lb') {
    # look ONLY at the price string (not the name) - "$4.99 Per 2-Lb. Pkg" means the price is for 2 lb.
    # (a "3 lb bag" in the NAME with a per-lb price must NOT be divided - that was a real regression.)
    $wp = [regex]::Match((("" + $deal.price_text)), '(?i)(?:per\s+(\d+(?:\.\d+)?)\s*-?\s*lb|(\d+(?:\.\d+)?)\s*-?\s*lb\.?\s*(?:pkg|package|bag))')
    if ($wp.Success) { $wn = if ($wp.Groups[1].Success) { [double]$wp.Groups[1].Value } else { [double]$wp.Groups[2].Value }; if ($wn -gt 1) { return @{ unit_price=($pr.per_item/$wn); basis="per-$wn-lb pkg"; note=$pr.note } } }
  }
  if ($unit -eq 'lb' -and $pr.kind.perlb)     { return @{ unit_price=$pr.per_item; basis='per-lb marker'; note=$pr.note } }
  if ($unit -eq 'each' -and $pr.kind.pereach) { return @{ unit_price=$pr.per_item; basis='per-each marker'; note=$pr.note } }
  if ($unit -in @('lb','oz','floz','gallon','dozen')) {
    # By-VOLUME container with a commodity-declared dry weight: fresh berries sold by the "pint" are a dry-volume
    # clamshell, not a liquid pint, so their label carries no weight and Convert-ToUnit (which reads pint as 16
    # fl oz) can't rank them against the weight-labeled 18-oz clamshells. When commodities.json declares pint_oz
    # (e.g. blueberries = 11.2, the US retail blueberry-pint standard) and the size is a bare pint with NO weight
    # token, substitute the canonical weight so it prices per-ounce like every other store. Scoped to declaring
    # commodities only, so milk/other liquid pints are never touched.
    $sizeForAmt = [string]$deal.size_text
    if ($cat.PSObject.Properties['pint_oz'] -and $cat.pint_oz -and ($unit -eq 'oz' -or $unit -eq 'lb')) {
      $sl = $sizeForAmt.ToLower()
      if ($sl -match '\b(pt|pint)s?\b' -and $sl -notmatch '\b(oz|ounce|ounces|lb|lbs|pound|pounds|gram|grams|\bg\b|ml|liter|litre)\b') {
        $pnM = [regex]::Match($sl, '(\d+(?:\.\d+)?)\s*(?:pt|pint)s?\b')
        $pn = if ($pnM.Success) { [double]$pnM.Groups[1].Value } else { 1 }
        $sizeForAmt = ('{0} oz' -f ($pn * [double]$cat.pint_oz))
      }
    }
    $amt = Get-SizeAmount $sizeForAmt $unit
    if (($amt -eq $null) -and $deal.name) { $amt = Get-SizeAmount $deal.name $unit }
    if ($amt -ne $null -and $amt -gt 0) { return @{ unit_price=($pr.per_item/$amt); basis="size $([math]::Round($amt,3)) $unit"; note=$pr.note } }
    return $null
  }
  if ($unit -eq 'each') {
    $pk = Get-PackCount $deal.price_text; if (-not $pk) { $pk = Get-PackCount $deal.size_text }; if (-not $pk) { $pk = Get-PackCount $deal.name }
    if ($plain -and $pk)  { return @{ unit_price=($pr.per_item/$pk); basis="per-$pk-pack"; note=$pr.note } }
    if ((-not $plain) -or ($deal.size_text -match '(?i)^\s*(1\s*)?(ct|count|ea|each)\.?\s*$')) { return @{ unit_price=$pr.per_item; basis='per-each'; note=$pr.note } }
    return $null   # bare package price with unknown count -> not confident, drop
  }
  return $null
}

# A "Buy N, get K ..." conditional deal that NEEDS a captured regular price + a unit basis to be priceable.
# (Plain "N for $M" is NOT included here - it prices on its own without a regular.)
function Test-IsMultibuy([string]$t) { return ((ConvertTo-DigitNumerals ("" + $t)) -match '(?i)buy\s*\d+\s*,?\s*get\s*\d+') }

# ---------------------------------------------------------------- SELF-TEST (provable multibuy math; -SelfTest exits here)
# Which everyday-price files (out\regular\<store>-regular-<date>.json) to load per store. EVERYDAY-ONLY stores
# (Walmart) run no weekly ad cycle, so a partial daily refresh (a throttled ~50-item pull) must UNION with the
# recent captures or it collapses the board - the 2026-07-23 incident, when a 50-of-410 Walmart pull cut the
# store to 80 cells and the coverage guard blocked the publish. Every OTHER store here runs weekly SALES, and
# dating its everyday rows would let today's everyday price filter a still-valid sale out of the freshness
# ranker - so they stay newest-file-only. PURE function (operates on a passed file list, reads no disk) so
# `compare-deals.ps1 -SelfTest` can prove the union never silently regresses to newest-only.
$EVERYDAY_ONLY_STORES = @('walmart')   # out\regular stores with no ad cycle; safe (and required) to union
function Select-RegularFileSet($fileObjs, [datetime]$asof, [int]$unionMaxAgeDays) {
  $fileObjs |
    Where-Object { $_.BaseName -match '^[a-z0-9-]+-regular-\d{4}-\d{2}-\d{2}$' } |
    Group-Object { ($_.BaseName -replace '-regular-.*$','') } |
    ForEach-Object {
      $grp = $_.Group | Sort-Object Name -Descending
      if ($EVERYDAY_ONLY_STORES -contains $_.Name) {
        $grp | Where-Object {
          $m = [regex]::Match($_.BaseName, '(\d{4}-\d{2}-\d{2})$')
          $m.Success -and [math]::Abs(([datetime]$m.Groups[1].Value - $asof).TotalDays) -le $unionMaxAgeDays
        }
      } else {
        $grp | Select-Object -First 1
      }
    }
}

if ($SelfTest) {
  $script:fail = 0
  function _Near($label, $got, $want, $tol) {
    if ($null -eq $got) { Write-Output ("FAIL  $label  got <null> want $want"); $script:fail++; return }
    if ([math]::Abs([double]$got - [double]$want) -le $tol) { Write-Output ("ok    $label  = " + ('{0:N4}' -f [double]$got)) }
    else { Write-Output ("FAIL  $label  got " + ('{0:N4}' -f [double]$got) + " want $want"); $script:fail++ }
  }
  function _Null($label, $got) {
    if ($null -eq $got) { Write-Output ("ok    $label  correctly UNPRICED") } else { Write-Output ("FAIL  $label  should be null, got " + $got.unit_price); $script:fail++ }
  }
  function _D($price,$name,$reg,$size) { [pscustomobject]@{ price_text=$price; name=$name; regular=$reg; size_text=$size } }
  function _C($unit) { [pscustomobject]@{ unit=$unit } }

  # 1. soda-style Buy 2 Get 3 Free, regular $11.99/pack, 12-pack x 12 fl oz = 144 fl oz -> (2*11.99/5)/144
  _Near 'B2G3 soda /floz'        (Get-UnitPrice (_D 'Buy 2 Get 3 Free' 'Coca-Cola 12 pk' 11.99 '12 pk 12 fl oz') (_C 'floz')).unit_price 0.0333 0.0005
  # 2. chicken thighs Buy 1 Get 2 Free, regular $5.98/lb, per-lb basis -> 5.98/3
  _Near 'B1G2 chicken /lb'       (Get-UnitPrice (_D 'Buy 1 Get 2 Free' 'Tyson chicken thighs' 5.98 'lb') (_C 'lb')).unit_price 1.9933 0.001
  # 3. same deal, per-lb regular but NO size -> must be UNPRICED so the safety net flags it (not a silent wrong price)
  _Null 'B1G2 chicken no-size'   (Get-UnitPrice (_D 'Buy 1 Get 2 Free' 'Tyson chicken thighs' 5.98 '') (_C 'lb'))
  # 4. Buy 2 Get 1 50% off, regular $3.00 each -> (2*3 + 1*3*0.5)/3
  _Near 'B2G1-50off /each'       (Get-UnitPrice (_D 'Buy 2 Get 1 50% off' 'yogurt cup' 3.00 'each') (_C 'each')).unit_price 2.50 0.001
  # 5. Buy 3 Get 2 for $1, regular $2.50 -> (3*2.50 + 2*1)/5
  _Near 'B3G2-for-1 /each'       (Get-UnitPrice (_D 'Buy 3 Get 2 for $1' 'bread loaf' 2.50 'each') (_C 'each')).unit_price 1.90 0.001
  # 6. plain N-for-$M (no regular needed): milk 2 for $5 -> 2.50/gal
  _Near '2-for-5 milk /gal'      (Get-UnitPrice (_D '2 for $5' 'milk gallon' $null 'gallon') (_C 'gallon')).unit_price 2.50 0.001
  # 7. multibuy MISSING regular -> UNPRICED (can't compute the discount without it)
  _Null 'B2G3 missing-regular'   (Get-UnitPrice (_D 'Buy 2 Get 3 Free' 'soda' $null '12 pk 12 fl oz') (_C 'floz'))
  # 8. detector recognizes the phrasings that need a regular (digit AND word-numeral forms - Hy-Vee spells them out)
  foreach ($t in @('Buy 2 Get 3 Free','Buy 2, Get 3 Free','BUY 1 GET 2 FREE','Buy 2 Get 1 50% off','buy one, get one FREE','buy two, get one free')) {
    if (Test-IsMultibuy $t) { Write-Output "ok    detect '$t'" } else { Write-Output "FAIL  detect '$t'"; $script:fail++ }
  }
  # 9. word-numeral BOGO prices like its digit form: "buy two, get one free" reg $3.00/each -> (2*3)/3
  _Near 'word B2G1-free /each'   (Get-UnitPrice (_D 'buy two, get one free' 'bread loaf' 3.00 'each') (_C 'each')).unit_price 2.00 0.001
  # 10. classic word BOGO "buy one, get one free" reg $4.00/each -> (1*4)/2
  _Near 'word BOGO /each'        (Get-UnitPrice (_D 'buy one, get one free' 'bread loaf' 4.00 'each') (_C 'each')).unit_price 2.00 0.001
  # 11. the tightened GLOBAL_EXCLUDE 'mix' token must SKIP "mix & match" (a multibuy) but still catch "drink mix"
  $mixTok = '(?i)\bmix\b(?!\s*(?:&|and)\s*match)'
  if ('tyson chicken thighs, mix & match buy 1 get 2 free' -notmatch $mixTok) { Write-Output "ok    'mix & match' not excluded" } else { Write-Output "FAIL  'mix & match' wrongly excluded"; $script:fail++ }
  if ('grape drink mix' -match $mixTok) { Write-Output "ok    'drink mix' still excluded" } else { Write-Output "FAIL  'drink mix' no longer excluded"; $script:fail++ }

  # --- 12-14: partial-pull coverage (reproduces the 2026-07-23 Walmart flood) -----------------------------
  # A throttled Walmart pull returns ~50 of 410 commodities. Under newest-file-wins that partial REPLACED the
  # last full capture and cut the store to 80 cells; the coverage guard blocked the publish and the un-deduped
  # alerts flooded. These cases fail the build if the union ever regresses, so the automated job proves the fix
  # is intact on every run (guards.ps1 runs this self-test as a blocking invariant).
  function _RegFiles($names){ $names | ForEach-Object { [pscustomobject]@{ BaseName=$_; Name=($_ + '.json') } } }
  $asof = [datetime]'2026-07-23'
  # 12. the partial pull must UNION with the last full capture, not replace it (both files load)
  $u = @(Select-RegularFileSet (_RegFiles @('walmart-regular-2026-07-18','walmart-regular-2026-07-23')) $asof 14 | ForEach-Object { $_.BaseName })
  if ($u.Count -eq 2) { Write-Output 'ok    Walmart partial pull UNIONS with last full capture (no collapse)' }
  else { Write-Output ("FAIL  Walmart union regressed to newest-only ({0} file) - the 2026-07-23 collapse would recur" -f $u.Count); $script:fail++ }
  # 13. an ad-cycling store stays newest-only (dating its everyday rows would filter a still-valid weekly sale)
  $b = @(Select-RegularFileSet (_RegFiles @('bakers-regular-2026-07-11','bakers-regular-2026-07-18')) $asof 14 | ForEach-Object { $_.BaseName })
  if ($b.Count -eq 1 -and $b[0] -eq 'bakers-regular-2026-07-18') { Write-Output 'ok    ad-cycling store stays newest-only (sales not filtered out)' }
  else { Write-Output "FAIL  ad-cycling store must stay newest-only (union would drop valid sales)"; $script:fail++ }
  # 14. a Walmart capture older than the union window is excluded (never resurrect ancient prices)
  $o = @(Select-RegularFileSet (_RegFiles @('walmart-regular-2026-06-01','walmart-regular-2026-07-23')) $asof 14 | ForEach-Object { $_.BaseName })
  if ($o.Count -eq 1 -and $o[0] -eq 'walmart-regular-2026-07-23') { Write-Output 'ok    stale-beyond-window Walmart capture excluded' }
  else { Write-Output "FAIL  union age window not enforced (would load ancient prices)"; $script:fail++ }

  Write-Output ('-'*54)
  if ($script:fail -eq 0) { Write-Output 'SELF-TEST PASS  (all multibuy / BOGO cases correct)'; exit 0 }
  else { Write-Output ("SELF-TEST FAIL: $script:fail case(s)"); exit 1 }
}

# ---------------------------------------------------------------- load + normalize all sources
$deals = New-Object System.Collections.Generic.List[object]
function Add-Norm($store,$name,$price,$size,$regular,$src,$ptype='sale',$srcDate='') {
  if (-not $name) { return }
  # src_date = the date of the CAPTURE FILE this row came from (not the ad cycle). Only rows loaded from dated
  # per-store capture files carry it; it is how the ranking step below can prefer the freshest capture that
  # covers a commodity instead of letting an older capture's price compete with it.
  $deals.Add([pscustomobject]@{ store=$store; name=[string]$name; price_text=[string]$price; size_text=[string]$size; regular=$regular; source_ad=$src; price_type=$ptype; src_date=[string]$srcDate })
}
$ads = Get-Content $AdsFile -Raw | ConvertFrom-Json
$today = $ads.today
foreach ($d in $ads.deals) {                                                                # weekly ads = 'sale'
  switch ($d.store) {
    'Hy-Vee'      { Add-Norm $d.store $d.item $d.item $null $null $d.source_ad 'sale' }      # price+size embedded in item text
    'Aldi'        { Add-Norm $d.store $d.item $d.ad_price $d.size $null $d.source_ad 'sale' }
    'Family Fare' { Add-Norm $d.store $d.item $d.ad_price $d.size $d.regular $d.source_ad 'sale' }
    default       { Add-Norm $d.store $d.item ($d.ad_price + ' ' + $d.item) $d.size $d.regular $d.source_ad 'sale' }
  }
}
# ad-based extra files (Baker's ad, Sam's, Fareway weekly-ad sales). Each file may declare price_type (Sam's
# warehouse price = everyday); default sale. Fareway's EVERYDAY storefront prices load from out\regular\ above;
# -FarewayFile is only its weekly-ad SALE supplement (vision-read promos the storefront may not show online).
#
# AUTO-DISCOVER when not passed (2026-07-16). These used to be caller-supplied ONLY, while out\regular\ was
# auto-discovered - so running `compare-deals.ps1` bare silently built a board with NO Sam's ad prices (Sam's
# has no out\regular\ file at all: its prices come only from out\sams\sams-deals-*.json). That is exactly what
# happened today: a bare re-run cut Sam's from 201 priced chips to 112 and quietly dropped 125 chips across
# Sam's/Baker's/Hy-Vee/Walmart, and the publish coverage gate did not catch it because 112 > its MinPerStore.
# A store must never disappear because of how the engine was invoked. Explicit args still win.
if (-not $BakersFile)  { $f = Get-ChildItem (Join-Path $OutDir 'bakers\bakers-deals-*.json')   -EA SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1; if ($f) { $BakersFile  = $f.FullName; Write-Warning ("compare-deals: -BakersFile not passed; auto-using "  + $f.Name) } }
if (-not $FarewayFile) { $f = Get-ChildItem (Join-Path $OutDir 'fareway\fareway-deals-*.json') -EA SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1; if ($f) { $FarewayFile = $f.FullName; Write-Warning ("compare-deals: -FarewayFile not passed; auto-using " + $f.Name) } }

# Sam's is captured in PARTIAL SLICES - the club catalog is CAPTCHA-walled, so each run only gets the categories
# it got through before the wall. "Newest file wins" is right for a store we pull whole every week and WRONG for
# Sam's: the 2026-07-15 Omaha-club capture (428 rows) covers ~118 commodities where the 2026-07-08 national
# capture (263 rows) covered ~251, so taking only the newest cut 153 priced cells off the board with no warning.
# Load EVERY Sam's capture inside the age window instead, and let the ranking step keep - per commodity - only
# the rows from the freshest capture that actually covers it. A blind union would be worse than the bug it fixes:
# "cheapest per store" would let a stale-low price from an old capture beat today's real one.
# An explicit -SamsFile still wins (the regression harness pins one file).
$samsFiles = @()
if ($SamsFile) { $samsFiles = @($SamsFile) }
else {
  foreach ($f in (Get-ChildItem (Join-Path $OutDir 'sams\sams-deals-*.json') -EA SilentlyContinue | Sort-Object Name -Descending)) {
    if ($f.BaseName -notmatch '(\d{4}-\d{2}-\d{2})$') { continue }
    $age = [math]::Abs(([datetime]$Matches[1] - [datetime]$today).TotalDays)
    if ($age -gt $SamsMaxAgeDays) { Write-Warning ("compare-deals: skipping " + $f.Name + " (" + [int]$age + "d old > -SamsMaxAgeDays $SamsMaxAgeDays)"); continue }
    $samsFiles += $f.FullName
  }
  if ($samsFiles.Count) { Write-Warning ("compare-deals: -SamsFile not passed; auto-using " + $samsFiles.Count + " Sam's capture(s): " + (($samsFiles | ForEach-Object { Split-Path $_ -Leaf }) -join ', ')) }
}
foreach ($extra in (@($BakersFile,$FarewayFile) + $samsFiles)) {
  if ($extra -and (Test-Path $extra)) {
    $ex = Get-Content $extra -Raw | ConvertFrom-Json
    $pt = if ($ex.price_type) { [string]$ex.price_type } else { 'sale' }
    $sd = ''
    if ([IO.Path]::GetFileNameWithoutExtension($extra) -match '(\d{4}-\d{2}-\d{2})$') { $sd = $Matches[1] }
    foreach ($d in $ex.deals) { Add-Norm $d.store $d.item $d.ad_price $d.size $d.regular $d.source_ad $pt $sd }
  }
}
# supplemental agent-authored deals: out\extra-deals-<date>.json (newest). This is how a Hy-Vee/Aldi BOGO gets
# PRICED - the ad feed carries no regular (Flipp returns it empty), so the Wednesday agent looks the item's
# regular shelf price up in Aisles Online and writes it here as {store,item,ad_price:"buy one get one free",
# regular,size}. Same shape as the Baker's file; default price_type 'sale'.
# GUARD: only load an extra file dated within ~7 days of the ads week - "newest" is NOT "current": a leftover
# BOGO file from a prior week would otherwise be re-priced as a live sale forever.
$exDir = if ($ExtraDir) { $ExtraDir } else { $OutDir }   # -ExtraDir: pinnable for the regression harness
$extraF = Get-ChildItem (Join-Path $exDir 'extra-deals-*.json') -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
$exDate = ''
if ($extraF -and $extraF.BaseName -match '(\d{4}-\d{2}-\d{2})$') { $exDate = $Matches[1]; try { if ([math]::Abs(([datetime]$exDate - [datetime]$today).TotalDays) -gt 7) { $extraF = $null } } catch {} }
if ($extraF) {
  $ex = Get-Content $extraF.FullName -Raw | ConvertFrom-Json
  $pt = if ($ex.price_type) { [string]$ex.price_type } else { 'sale' }

  # A DISCOUNT WE CANNOT DATE IS A DISCOUNT WE CANNOT PUBLISH.
  # Two very different kinds of row live in this file:
  #   * BOGO/multibuy pricing tied to the CURRENT weekly ad. The ad feed carries no regular price, so the
  #     Wednesday agent looks one up and writes it here. Those belong to an ad cycle with a known window and
  #     stay valid for the ad week - that is what the 7-day gate above is for.
  #   * "Aisles Online markdown" snapshots: a cut price an agent happened to SEE on some day. These belong to
  #     no ad cycle, carry no end date, and move constantly.
  # We were replaying the second kind as a live sale for a full week. On 2026-07-14 the board published Hy-Vee
  # sirloin at $6.99/lb off a 2026-07-12 markdown; the store's real price that day was $11.99/lb. FIFTY-ONE
  # cells were being served this way. Worse, build-deals-page stamped them "Sale thru Jul 19" - a date
  # borrowed from the store's ad cycle, which these rows have nothing to do with - so an unverifiable
  # two-day-old snapshot wore the costume of a dated, ad-backed sale. And because the cell is typed `sale`,
  # every price audit SKIPS it by design (a sale is supposed to differ from its product page). The whole class
  # was structurally invisible: it could not be caught by any check we had.
  # Rule: a row claiming a discount, with no end date, is honoured only on the day it was captured.
  $todayReal = (Get-Date -Format 'yyyy-MM-dd')
  $staleDiscount = 0
  foreach ($d in @($ex.deals)) {
    $ap = 0.0; $rg = 0.0
    [void][double]::TryParse((([string]$d.ad_price) -replace '[^0-9.]',''), [ref]$ap)
    [void][double]::TryParse((([string]$d.regular)  -replace '[^0-9.]',''), [ref]$rg)
    $claimsDiscount = ($ap -gt 0 -and $rg -gt 0 -and $ap -lt $rg)
    $dated = [bool]$d.sale_end
    if ($claimsDiscount -and (-not $dated) -and ($exDate -ne $todayReal)) { $staleDiscount++; continue }
    Add-Norm $d.store $d.item $d.ad_price $d.size $d.regular $d.source_ad $pt
  }
  if ($staleDiscount -gt 0) {
    Write-Warning ("extra-deals: skipped $staleDiscount undated discount row(s) from $exDate (captured before today, no end date - cannot be shown as a live sale). The board falls back to each store's everyday shelf price, which IS verified against its product link.")
  }
}
# everyday/regular shelf-price files (out\regular\<store>-regular-<date>.json), newest per store; price_type=everyday.
# -RegularDir lets the regression harness pin the everyday-price channel to a FROZEN copy - the default
# newest-per-store auto-load is exactly the unpinned input that made the "frozen" regression drift.
$regDir = if ($RegularDir) { $RegularDir } else { Join-Path $OutDir 'regular' }
if (Test-Path $regDir) {
  # ONLY canonically-named files are data: "<store>-regular-<yyyy-MM-dd>.json", nothing else. This glob used
  # to be a bare '*.json', which made every file dropped in out\regular a "store". A throttled 0-row diagnostic
  # named "family-fare-regular-2026-07-14.PARTIAL.json" therefore (a) matched, and (b) sorted AFTER the good
  # "...-07-14.json" (case-insensitively 'p' > 'j'), so -Descending picked the EMPTY file and Family Fare
  # contributed zero everyday rows to the board while every log said the pull had succeeded. Anchor the name.
  # Newest-per-store, EXCEPT Walmart. Walmart is EVERYDAY-priced (no weekly ad cycle), and its browser capture
  # can run as a partial daily refresh (e.g. a 50-item core-staple pull). "Newest file wins" then SHRINKS the
  # board to whatever that partial covered - on 2026-07-23 a 50-term refresh cut Walmart from 410 cells to 80
  # and the coverage guard (correctly) blocked the publish. So Walmart UNIONS its recent captures and tags each
  # row with src_date; the freshness-per-commodity ranker (see "rank" below) then keeps today's price where it
  # exists and the last full capture everywhere else - no stale-low, no coverage loss. This is the same
  # multi-capture pattern Sam's already uses. Every OTHER store here can run weekly sales, so unioning old files
  # would resurrect expired prices; they stay newest-only.
  $regFiles = Select-RegularFileSet (Get-ChildItem (Join-Path $regDir '*-regular-*.json') -ErrorAction SilentlyContinue) ([datetime]$today) $WalmartMaxAgeDays
  foreach ($rf in $regFiles) {
    $ex = Get-Content $rf.FullName -Raw | ConvertFrom-Json
    # PRICE-MODE GATE (2026-07-15): Aldi/Fareway are Instacart storefronts whose DELIVERY catalog is marked up
    # ~10-50%. A file that does not MACHINE-PROVE it was captured in-store (price_mode='in-store' AND a
    # mode_verified date) is DROPPED here so its marked-up prices can never enter the board. Fareway shipped
    # 320 delivery-priced cells exactly this way. audit-price-mode.ps1 reports it; this is what enforces it.
    if (@('Aldi','Fareway') -contains [string]$ex.store -and ([string]$ex.price_mode -ne 'in-store' -or -not [string]$ex.mode_verified)) {
      Write-Warning ("price-mode: DROPPED $([string]$ex.store) everyday file (price_mode='$([string]$ex.price_mode)' mode_verified='$([string]$ex.mode_verified)') - not proven in-store; its prices are EXCLUDED from the board until re-captured In-Store and stamped")
      continue
    }
    $pt = if ($ex.price_type) { [string]$ex.price_type } else { 'everyday' }
    # Only Walmart's rows get a src_date (it unions multiple captures); everyone else loads one file and must
    # stay date-less so the ranker never filters their single source out from under them.
    $sd = ''
    if ([string]$ex.store -eq 'Walmart') { $mm = [regex]::Match($rf.BaseName, '(\d{4}-\d{2}-\d{2})$'); if ($mm.Success) { $sd = $mm.Groups[1].Value } }
    foreach ($d in $ex.deals) { Add-Norm $d.store $d.item $d.ad_price $d.size $d.regular $d.source_ad $pt $sd }
  }
}

# ---------------------------------------------------------------- categorize + price
# Prepared/processed/different-form terms: none of our raw staples are these, so a deal
# whose name contains one is NOT the plain commodity and is dropped (protects accuracy).
$GLOBAL_EXCLUDE = @(
  'drink\s*mix','kool[\s-]?aid','probiotic','kombucha','\bdip\b','\bsauce\b','wrapped',
  '\bbake\b','\bbaked\b','seasoned','marinated','stuffed','\bkit\b','flavored','\bsoup\b',
  'helper','lunchable','smoothie','\bpudding\b','ice\s*cream','\bcreamer\b','\bfrozen\b',
  '\bcanned\b','breaded','\bsnack\b','\bmeal\b','casserole','\bwrap\b','poppers',
  'muffin','pretzel','filled','strudel','\bcake\b','drinkable','(?<!orange\s)\bjuice\b',
  '\bsoda\b','sparkling','seltzer','\bwater\b','energy\s*drink','sports\s*drink','tonic','lemonade','faygo','cocktail',
  'pop[\s-]?tart','pastr','toaster','\btart\b','cereal','granola\s*bar','fruit\s*snack',
  '\bmalt\b','spiked','\bbeer\b','\bale\b','\bgum\b','\bwine\b','liquor','vodka','whiskey','tequila','bourbon','hard\s+seltzer','\bmix\b(?!\s*(?:&|and)\s*match)',
  # pet + baby food: no human staple is ever "dog food"/"cat litter"/"Beech Nut" - keep them out of every human
  # commodity (chicken/bacon/rice/sweet-corn were stealing dog food & baby food). The pet/baby commodities
  # relax_global exactly the token they need, so they still match their own products.
  'dog\s+food','dog\s+treats?','dog\s+biscuits?','cat\s+food','cat\s+litter','beech[\s-]?nut','gerber','happy\s*baby','baby\s+food'
)
# a wrapper rule-file can replace the global list (the recipe set relaxes sauce/canned/frozen/juice)
if ($GEX_OVERRIDE) { $GLOBAL_EXCLUDE = $GEX_OVERRIDE }
# A store can rename a product without changing the product, and the rename silently un-matches it. Sam's moved
# from hand-shortened names to real catalog titles: "Member's Mark Boneless Skinless Chicken Breast" became
# "Member's Mark Boneless and Skinless Chicken Breast, priced per pound". Every include pattern here was written
# against the short form, so one inserted "and" turned a priced cell into a "doesn't carry" tile - and NOTHING
# caught it, because "doesn't carry" is a legitimate state that no audit can tell apart from a real gap.
# So: test includes against the raw name AND a normalized variant (drop the store's per-unit suffix, treat
# "X and Y" as "X Y"). The variant is used for INCLUDES ONLY. Excludes and the global list keep matching the RAW
# name, which is what makes this safe in one direction: normalizing can only ever ADD an include match, it can
# never quietly un-exclude something. (It matters concretely: "mix and match" normalizes to "mix match", which
# WOULD fall into the '\bmix\b' global whose lookahead is written to spare "mix & match".)
function Get-MatchTexts([string]$name) {
  $n = $name.ToLower()
  $v = $n -replace ',?\s*priced per\s+\w+', ''            # Sam's "..., priced per pound" / "per each" suffix
  $v = (($v -replace '\band\b', ' ') -replace '\s{2,}', ' ').Trim()
  return ,@($n, $v)                                        # [0] is always the RAW name
}
function Match-Category($name) {
  $texts = Get-MatchTexts $name
  $n = $texts[0]
  # Which global prepared-food tokens hit this name (usually none). A commodity whose PLAIN form legitimately
  # IS one of these (pasta-sauce is a sauce, soda is soda, ice-cream is ice cream...) declares relax_global:
  # ["\\bsauce\\b", ...] in commodities.json to waive EXACTLY those tokens for itself - every other commodity
  # still gets the full global protection (a "chicken sauce" can never enter chicken-breast).
  $ghits = @(); foreach ($g in $GLOBAL_EXCLUDE) { if ($n -match $g) { $ghits += $g } }
  foreach ($c in $commodities) {
    $hit = $false
    foreach ($inc in $c.include) { foreach ($t in $texts) { if ($t -match $inc) { $hit=$true; break } }; if ($hit) { break } }
    if (-not $hit) { continue }
    if ($ghits.Count) {
      $relax = @($c.relax_global | Where-Object { $_ })
      $blocked = $false
      foreach ($g in $ghits) { if ($relax -notcontains $g) { $blocked = $true; break } }
      if ($blocked) { continue }
    }
    $bad = $false
    foreach ($exc in $c.exclude) { if ($n -match $exc) { $bad=$true; break } }
    if ($bad) { continue }
    return $c
  }
  return $null
}

# dedup identical rows (Family Fare's circular API repeats items across pages)
$seen = @{}; $ded = New-Object System.Collections.Generic.List[object]
foreach ($d in $deals) { $k = ($d.store + '|' + $d.name + '|' + $d.price_text + '|' + $d.size_text + '|' + $d.price_type); if (-not $seen.ContainsKey($k)) { $seen[$k]=$true; $ded.Add($d) } }
$deals = $ded

# Flat list of every matched deal (priced or not). Grouping by id afterward avoids per-id hashtable indexing.
$matched = New-Object System.Collections.Generic.List[object]
$flagged = New-Object System.Collections.Generic.List[object]
$mbUnpriced = New-Object System.Collections.Generic.List[object]   # Buy-N-Get-K deals we recognized but could NOT price -> surfaced, never silently dropped
foreach ($d in $deals) {
  $c = Match-Category $d.name
  if (-not $c) { continue }
  $up = Get-UnitPrice $d $c
  $uprice = $null; $basis = 'UNPRICED'; $note = ''
  if ($up) {
    $uprice = [math]::Round($up.unit_price,4); $basis = $up.basis; $note = $up.note
    if (-not (Test-Band $c.id $uprice)) {
      $bn = $BANDS[$c.id]
      $flagged.Add([pscustomobject]@{ id=$c.id; label=$c.label; store=$d.store; name=$d.name; unit=$c.unit; unit_price=$uprice; band=("$($bn.min)-$($bn.max)"); price_text=$d.price_text; size_text=$d.size_text })
      # if the out-of-band price came from a multibuy, it's a bad multibuy parse - reflect it in the multibuy
      # signal too (not just the generic out-of-band bucket the human is told is "usually normal").
      if (Test-IsMultibuy $d.price_text) {
        $mbUnpriced.Add([pscustomobject]@{ id=$c.id; label=$c.label; store=$d.store; name=$d.name; price_text=$d.price_text; regular=$d.regular; size_text=$d.size_text; reason=("priced but OUT-OF-BAND (`$$uprice outside $($bn.min)-$($bn.max)) - likely a bad multibuy size/regular parse, review capture") })
      }
      $uprice = $null; $basis = 'OUT-OF-BAND'   # bad parse -> drop from ranking
    }
  }
  # SAFETY NET: a recognized multibuy that came back UNPRICED means the capture is incomplete
  # (this is exactly how the Baker's chicken-thighs Buy-1-Get-2 was lost). Surface it loudly.
  if ((-not $up) -and (Test-IsMultibuy $d.price_text)) {
    $why = if (-not $d.regular -or ("" + $d.regular) -eq '') { 'missing regular price - a Buy-N-Get-K needs the "regular retail" number to price' }
           else { 'has regular but no unit basis - add the pack size (e.g. "12 pk 12 fl oz"), or "lb" for a per-pound item' }
    $mbUnpriced.Add([pscustomobject]@{ id=$c.id; label=$c.label; store=$d.store; name=$d.name; price_text=$d.price_text; regular=$d.regular; size_text=$d.size_text; reason=$why })
  }
  $matched.Add([pscustomobject]@{
    id=$c.id; label=$c.label; unit=$c.unit; store=$d.store; name=$d.name; price_type=$d.price_type;
    price_text=$d.price_text; size_text=$d.size_text; regular=$d.regular; bulk=(Test-Bulk $d.size_text $d.name); membership=(Test-Membership $d.store);
    # Carry the SOURCE through to the page. Without it build-deals-page cannot tell an ad-backed sale from a
    # one-off price snapshot, so it stamped every sale chip with the store's ad-cycle end date - dressing an
    # undated Aisles Online markdown up as "Sale thru Jul 19". A date we invented is worse than no date.
    source_ad=$d.source_ad; src_date=$d.src_date;
    unit_price=$uprice; basis=$basis; note=$note })
}

# candidates audit file (includes matched-but-UNPRICED deals so the semantic pass can recover / reject them)
$candList = New-Object System.Collections.Generic.List[object]
foreach ($g in ($matched | Group-Object id)) {
  $f = $g.Group[0]
  # price_type added 2026-07-23 so derive-recipe-floors.ps1 can tell an EVERYDAY candidate from a sale -
  # the everyday floor per store is the cheapest everyday-typed candidate, which the comparison row hides
  # whenever a sale is winning that store.
  $candList.Add([pscustomobject]@{ id=$g.Name; label=$f.label; unit=$f.unit; candidates=@($g.Group | Select-Object store,name,price_text,size_text,regular,unit_price,basis,price_type) })
}
$candPfx = if ($OutName -eq 'comparison') { 'candidates' } else { "$OutName-candidates" }
(@{ week_of=$today; commodities=$candList } | ConvertTo-Json -Depth 8) | Set-Content (Join-Path $OutDir ("$candPfx-"+$today+".json")) -Encoding UTF8

# ---------------------------------------------------------------- rank: cheapest per store, then across stores
$report = New-Object System.Collections.Generic.List[object]
foreach ($g in ($matched | Where-Object { $_.unit_price -ne $null } | Group-Object id)) {
  $priced = $g.Group
  # Per store: the FRESHEST capture that covers this commodity wins it outright; only then take that capture's
  # cheapest row. Without this, loading Sam's partial captures together (see the loader) would let a stale-low
  # price from an old capture out-rank today's real price - a worse bug than the coverage gap it fixes.
  # Rows with NO src_date (weekly ads, out\regular\ everyday files) are never filtered out - they are a store's
  # only source and carry no capture-date to compare, so they always stay eligible alongside the newest capture.
  $byStore = $priced | Group-Object store | ForEach-Object {
    $rows = $_.Group
    $dated = @($rows | Where-Object { $_.src_date })
    if ($dated.Count) {
      $newest = @($dated | ForEach-Object { [string]$_.src_date } | Sort-Object -Descending)[0]
      $rows = @($rows | Where-Object { -not $_.src_date -or [string]$_.src_date -eq $newest })
    }
    $rows | Sort-Object unit_price | Select-Object -First 1
  }
  $ranked = @($byStore | Sort-Object unit_price)
  if ($ranked.Count -lt $MinStores) { continue }
  $f = $priced[0]
  $nm = @($ranked | Where-Object { -not $_.membership } | Select-Object -First 1)
  $report.Add([pscustomobject]@{
    commodity = $f.label; id=$g.Name; unit=$f.unit
    cheapest_store = $ranked[0].store
    cheapest_price = $ranked[0].unit_price
    cheapest_type = $ranked[0].price_type
    nomem_store = $(if($nm.Count){$nm[0].store}else{$null})
    nomem_price = $(if($nm.Count){$nm[0].unit_price}else{$null})
    nomem_type  = $(if($nm.Count){$nm[0].price_type}else{$null})
    stores = @($ranked | ForEach-Object { [pscustomobject]@{ store=$_.store; per_unit=$_.unit_price; unit=$f.unit; type=$_.price_type; bulk=$_.bulk; membership=$_.membership; item=$_.name; ad=$_.price_text; size=$_.size_text; basis=$_.basis; note=$_.note; source_ad=$_.source_ad } })
  })
}
$report = @($report | Sort-Object commodity)

# ---------------------------------------------------------------- health + flagged (drive the automation alert)
$flagPfx = if ($OutName -eq 'comparison') { 'flagged' } else { "$OutName-flagged" }
(@{ week_of=$today; flagged_count=$flagged.Count; flagged=$flagged.ToArray(); multibuy_unpriced=$mbUnpriced.ToArray() } | ConvertTo-Json -Depth 6) | Set-Content (Join-Path $OutDir ("$flagPfx-"+$today+".json")) -Encoding UTF8
$storesWithData = @($matched | Where-Object { $_.unit_price -ne $null } | ForEach-Object { $_.store } | Select-Object -Unique | Sort-Object)
$health = [ordered]@{ stores_with_data=$storesWithData; store_count=$storesWithData.Count; commodities_compared=$report.Count; flagged_out_of_band=$flagged.Count; multibuy_unpriced=$mbUnpriced.Count }

# ---------------------------------------------------------------- output
$out = [ordered]@{ built_at=(Get-Date).ToString('s'); week_of=$today; source=$AdsFile; commodities_compared=$report.Count; health=$health; comparison=$report }
$file = Join-Path $OutDir ($OutName + "-" + $today + ".json")
($out | ConvertTo-Json -Depth 8) | Set-Content $file -Encoding UTF8

Write-Output ("CHEAPEST IN OMAHA  -  week of " + $today + "   (commodities with >= $MinStores stores: " + $report.Count + ")")
Write-Output ("=" * 78)
foreach ($row in $report) {
  $u = $row.unit
  Write-Output ""
  $nmtxt = if ($row.nomem_store -and ($row.nomem_store -ne $row.cheapest_store)) { ('   |  no-membership: {0} ${1}' -f $row.nomem_store, ('{0:N2}' -f $row.nomem_price)) } else { '' }
  Write-Output ('{0}  ->  cheapest: {1} ${2}/{3} ({4}){5}' -f $row.commodity, $row.cheapest_store, ('{0:N2}' -f $row.cheapest_price), $u, $row.cheapest_type, $nmtxt)
  foreach ($s in $row.stores) {
    $mk = ''
    if ($s.membership) { $mk += '(member) ' }
    if ($s.bulk) { $mk += '(bulk) ' }
    Write-Output ('    {0,-13} ${1,-8}/{2,-6} {3,-10} {4}{5}' -f $s.store, ('{0:N2}' -f $s.per_unit), $u, ('['+$s.type+']'), $mk, ($s.item.Substring(0,[math]::Min(40,$s.item.Length))))
  }
}
if ($mbUnpriced.Count -gt 0) {
  Write-Output ""
  Write-Output ("!! MULTIBUY UNPRICED: " + $mbUnpriced.Count + " Buy-N-Get-K deal(s) recognized but NOT priced - fix the capture, do not publish as-is:")
  foreach ($m in $mbUnpriced.ToArray()) { Write-Output ("   [" + $m.label + "] " + $m.store + ": '" + $m.price_text + "' - " + $m.reason) }
}
Write-Output ""
Write-Output ("Saved: " + $file)
