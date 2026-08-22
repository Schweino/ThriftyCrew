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
[int]$SamsMaxAgeDays = 90,   # = capture policy MaxCarryDays; see regular-fileset-lib.ps1
  # Walmart's out\regular captures are unioned the same way (see the everyday-price loader): a partial daily
  # refresh must not shrink the board, so every Walmart capture inside this window is loaded and the freshest
  # one covering each commodity wins. Walmart is everyday-priced, so an older capture is only ever a gap-filler.
  [int]$WalmartMaxAgeDays = 90,   # = capture policy MaxCarryDays; see regular-fileset-lib.ps1
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
  # Pin the sanity bands the same way -CommoditiesFile pins the rules. The regression harness needs BOTH
  # frozen or it is not hermetic: it froze the data, then read the LIVE rule + band files, so every ordinary
  # rule edit tripped it and it sat red for weeks until nobody read it. See regression-test.ps1.
  [string]$BandsFile = "",
  [switch]$SelfTest,
  # -Explain <commodity-id>: read-only ownership dump for ONE cell, then exit. See the block near
  # Match-Category. Writes no board, so it is safe to run against a live tree mid-pipeline.
  [string]$Explain = ""
)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
# The one place that decides what is EVERYDAY and what is a SALE on a captured row. See its header.
. (Join-Path $root 'price-split-lib.ps1')
if (-not $OutDir)  { $OutDir  = Join-Path $root 'out' }
if (-not $AdsFile) { $AdsFile = (Get-ChildItem (Join-Path $OutDir 'ads-*.json') | Sort-Object Name -Descending | Select-Object -First 1).FullName }
# WHICH FILES THIS BUILD ACTUALLY OPENS (2026-08-21). grocery\out holds 870 tracked files, and the ones
# the engine still NEEDS are named exactly like the ones it has finished with - a dated capture looks
# identical to a disposable output. The board reads a UNION of dated captures (up to 14 days for
# Walmart, up to the 90-day quarter elsewhere) because the rotation only re-prices ~7 items per store
# per day, so a three-week-old file can be the only place a store's price for a commodity exists.
# Deleting by date bins prices the board is ranking on, and it does not error - it just publishes a
# different store as cheapest. The engine always knew which files it opened; it never wrote it down.
. (Join-Path $PSScriptRoot 'input-usage-lib.ps1')
$inputUsage = New-InputUsageTracker
Add-InputUsed -Tracker $inputUsage -Path $AdsFile -Role 'ads'
if (-not $CommoditiesFile) { $CommoditiesFile = Join-Path $root 'commodities.json' }
$cdoc = Get-Content $CommoditiesFile -Raw | ConvertFrom-Json
# a rule FILE may be a bare array (staples) or a wrapper { global_exclude:[...], commodities:[...] } (recipe
# set, which relaxes sauce/canned/frozen since those items legitimately ARE those forms).
if ($cdoc.PSObject.Properties['commodities']) { $commodities = $cdoc.commodities; $GEX_OVERRIDE = @($cdoc.global_exclude) } else { $commodities = $cdoc; $GEX_OVERRIDE = $null }
# sanity price bands (magnitude/garbage net + health check)
$BANDS = @{}
$bandsFile = if ($BandsFile) { $BandsFile } else { Join-Path $root 'price-bands.json' }
if (Test-Path $bandsFile) { $bDoc = Get-Content $bandsFile -Raw | ConvertFrom-Json; foreach ($p in $bDoc.bands.PSObject.Properties) { $BANDS[$p.Name] = $p.Value } }
# rules may carry their own inline band_min/band_max (recipe set) - these OVERRIDE price-bands.json because a
# recipe commodity that shares an id with a staple (butter/milk/peanut-butter) may use a DIFFERENT unit (oz vs
# lb), so the staple's per-lb band would wrongly reject every per-oz match.
foreach ($c in $commodities) { if ($c.PSObject.Properties['band_min']) { $BANDS[[string]$c.id] = [pscustomobject]@{ min=[double]$c.band_min; max=[double]$c.band_max } } }
function Test-Band($id, $up) { if (-not $BANDS.ContainsKey($id)) { return $true }; $b = $BANDS[$id]; return ([double]$up -ge [double]$b.min -and [double]$up -le [double]$b.max) }
# UNIVERSAL IMPLAUSIBILITY FLOOR (2026-07-27, overhaul-1): only 29 of 503 commodities carry a hand-tuned
# band, so 474 have NO low-end floor - a dropped decimal / unit-confusion parse ships unchecked (the
# $0.0023/oz grits price that sat live for days was exactly this, on a band-less commodity). These per-unit
# floors are ~1/4 of the cheapest REAL staple observed in each unit (oz salt $0.0304, floz vinegar $0.0234,
# lb litter $0.2796, gal milk $2.99, dozen eggs $1.426), so no real cell is at risk but any decimal-drop is
# caught. 'each' is deliberately unfloored (a 500-ct swab box is legitimately ~$0.004 each). Units absent
# from this table are simply not floored (no false blocks on exotic units).
$FLOOR = @{ oz=0.008; floz=0.006; lb=0.07; gallon=0.75; dozen=0.35 }
function Test-Floor($unit, $up) { $u=[string]$unit; if (-not $FLOOR.ContainsKey($u)) { return $true }; return ([double]$up -ge [double]$FLOOR[$u]) }
# PACK-FORM CAP (2026-08-08, Brad's "packet means packet" ruling from the accuracy sample).
# Some commodities are defined by their PACK FORM, not just their contents: "Taco Seasoning (packet)" and
# "Ranch Seasoning Mix (packet)" are the single-use packet a shopper actually buys. The board was filling both
# with the BULK CANISTER - McCormick 8.5 oz on taco seasoning, Great Value 8 oz Canister on ranch - which is a
# different product at a different per-oz rate, so the published number is not what a packet buyer pays.
# A price band cannot express this (both forms sit inside the same per-oz band) and neither can a name regex,
# because the size is not reliably in the name. So the constraint is declared where it belongs: on the
# commodity, in the same shape as pack_is_package. A commodity without the field is completely unaffected.
$MAXPACK = @{}
foreach ($c in $commodities) { if ($c.PSObject.Properties['max_pack_oz']) { $MAXPACK[[string]$c.id] = [double]$c.max_pack_oz } }
function Get-PackOz([string]$size, [string]$name) {
  # Total package weight in ounces, ONLY when the size string states one plainly. Returns $null otherwise -
  # an unknown size must never be treated as a violation, or every store that omits sizes loses the cell.
  $t = (("" + $size + " " + $name)).ToLower()
  $m = [regex]::Match($t, '(\d+(?:\.\d+)?)\s*(?:fl\s*)?oz\b')
  if ($m.Success) { return [double]$m.Groups[1].Value }
  $m = [regex]::Match($t, '(\d+(?:\.\d+)?)\s*(?:lbs?|pounds?)\b')
  if ($m.Success) { return ([double]$m.Groups[1].Value * 16) }
  return $null
}
function Test-PackSize($id, $size, $name) {
  if (-not $MAXPACK.ContainsKey([string]$id)) { return $true }
  $oz = Get-PackOz $size $name
  if ($null -eq $oz -or $oz -le 0) { return $true }
  return ($oz -le $MAXPACK[[string]$id])
}
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
  # 'x' (and the U+00D7 times sign) are the same count-first form with a different separator ("12 x 12 fl
  # oz" - Hy-Vee's everyday feed): without them the scan slid to the SECOND number and priced a 144-floz
  # case as 12 fl oz ($0.3933 vs true $0.0328 on soda|Hy-Vee, band-flagged 2026-07-29). The times sign
  # rides as the \u00d7 regex escape, NEVER a literal: this file is BOM-less, PS 5.1 reads it as ANSI, and
  # a literal times sign saved as UTF-8 decodes to two ANSI chars, so that branch silently never matches.
  # (The 2026-07-30 batch SHIPPED exactly that literal despite documenting the trap - the branch was dead
  # on arrival, caught by the post-batch review; the cent sign in Get-ItemPrice's cents regex still has the
  # mojibake as a worked example. The self-test now carries a real [char]0x00D7 case so it cannot go dead
  # silently again.)
  # THE x/times BRANCH REQUIRES THE EACH-NUMBER IMMEDIATELY (whitespace/hyphen only, no \D+? gap): with the
  # lazy gap, concentration-marketing tokens parse as pack counts - 'Fabuloso ... 2X Concentrated Formula,
  # ..., 33.8 fl oz' read count=2, each=33.8 and HALVED the per-unit (4 live names measured, all currently
  # masked by their parsable size_text; Hy-Vee ad rows are name-parsed and would have published it). The
  # word tokens (ct/pk/...) keep the lazy gap for '6 pk of 12 oz' forms - a marketing word cannot follow
  # them, only 'x' has that ambiguity.
  # \D+? is lazy and both each-size groups take leading-dot decimals, so "6 pk .5 gal" reads 0.5, not 5.
  $mm = [regex]::Match($s, '(\d+(?:\.\d+)?)\s*[- ]?\s*(?:(?:ct|count|pk|packs?)\D+?|(?:x|\u00d7)\s*-?\s*)(\d+(?:\.\d+)?|\.\d+)\s*(fl\s*oz|floz|oz|ml|l\b|gal|gallon|qt|quart|pt|pint|lbs?|pound)\b')
  if ($mm.Success -and ($unit -eq 'oz' -or $unit -eq 'floz' -or $unit -eq 'gallon' -or $unit -eq 'lb')) {
    $cnt = [double]$mm.Groups[1].Value; $each = [double]$mm.Groups[2].Value; $tok = $mm.Groups[3].Value
    $per = Convert-ToUnit $each $tok $unit
    if ($per -ne $null) { return $cnt * $per }
  }
  # Same pack-first shape on a COUNT commodity: "12 pk 2 oz" is 12 ITEMS (1 dozen), the per-item weight is
  # incidental. 'each' already got here via the first-number scan (pk is in its count class); 'dozen' did NOT
  # (Convert-ToUnit dozen has no pk), so eggs in the Kroger-API canonical form went unpriced (2026-07-24).
  # The regex REQUIRES the trailing weight, so a bare "2 pk" (2 cartons, count unknown) can never match here.
  if ($mm.Success -and ($unit -eq 'each' -or $unit -eq 'dozen')) {
    $cnt = [double]$mm.Groups[1].Value
    if ($cnt -gt 0) { if ($unit -eq 'each') { return $cnt } else { return $cnt / 12.0 } }
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
  $m = [regex]::Match($s, '(\d+(?:\.\d+)?|\.\d+)\s*(fl\s*oz|floz|oz|ounce|ounces|lb|lbs|pound|pounds|#|gal|gallon|qt|quart|pt|pint|liter|litre|\bl\b|ml|g|gram|grams|dozen|doz|ct|count|ea|each|pk|pack|pkg|bunch|head|loaf)\b')
  if ($m.Success) {
    $num = [double]$m.Groups[1].Value; $tok = $m.Groups[2].Value
    $conv = Convert-ToUnit $num $tok $unit
    # WEIGHT-FIRST multipack ("16 oz 6 pk", or "1.51 oz., 40 pk." via the name fallback): a pack count
    # elsewhere in the string multiplies a WEIGHT/VOLUME size. pu-lib step 4 has always done this; the engine
    # did not, so Bush's "16 oz 6 pk" priced as ONE can ($0.3988/oz, band-flagged) and Sam's grits PUBLISHED
    # at $0.1049/oz off a ".98 oz., 46 pk." name (the leading-dot group above reads 0.98, not 98). Guarded to
    # weight units + weight tokens so "12 pk" on an each/dozen commodity is never multiplied twice.
    if ($conv -ne $null -and ($unit -eq 'oz' -or $unit -eq 'floz' -or $unit -eq 'lb' -or $unit -eq 'gallon') -and $tok -match '^(fl\s*oz|floz|oz|ounce|ounces|lb|lbs|pound|pounds|gal|gallon)$') {
      $wf = [regex]::Match($s, '(\d+)\s*-?\s*(?:pk|pack)\b')
      if ($wf.Success) { return $conv * [double]$wf.Groups[1].Value }
    }
    return $conv
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

  # Hy-Vee PERKS (member-only) dual price: "...$2.98 PERKS PRICES, NON-MEMBER PRICE $3.48". Brad's call (c):
  # publish the PERKS price (the lower, member price) and let the caller flag the cell membership-gated. This
  # MUST run before the cents and plain-dollar branches below, or a "SAVE! 50c" savings gets read as the price
  # and the LAST dollar in the string is the NON-MEMBER price - both wrong. Grab the $ right before "PERKS PRICE".
  $mkPerks = [regex]::Match($p, '(?i)\$\s*(\d+(?:\.\d{1,2})?)\s*perks\s*price')
  if ($mkPerks.Success) {
    return @{ per_item = [double]$mkPerks.Groups[1].Value; kind=@{perlb=$perlb;pereach=$pereach}; note='' }
  }

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
  $m = [regex]::Match($p, '(\d+)\s*(?:Â¢|cents?)')
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
  # A PER-LB MARKER FOUND ONLY IN THE NAME LOSES TO AN EXPLICIT MULTI-POUND SIZE (2026-08-21).
  # Get-ItemPrice searches priceText + nameText together, so a product NAMED "Cabbage, Per LB" sets the
  # marker even when its price is a package total. Aldi published cabbage at $2.37/lb - 3x every other
  # store - because of exactly that, while Fareway (1.92 / 2.5 lb) and Walmart (2.59 / 3.047 lb) divided
  # their sizes and landed at $0.77 and $0.85. Aldi's own earlier capture proves the intended number:
  # 2026-08-05 read "Cabbage Per LB" $0.79 size "lb"; 2026-08-15 read the same cabbage as $2.37 with size
  # "3.0 lb" - a 3 lb head and its total. 2.37 / 3.0 = 0.79, the store's own price.
  #
  # It sat at 2.7x of the row median, under audit-unit-basis-outlier's 4x bar, so nothing flagged it.
  #
  # THE TWO CASES THIS MUST NOT BREAK, both already paid for in comments above:
  #   * a real per-lb PRICE ("$1.68 lb.") - so the marker is re-tested against the price text ALONE, and
  #     when the price itself carries it, the price still wins.
  #   * Hy-Vee's random-weight rate-in-the-size ("2.85 lbs ($8.99/lb)"), where the price IS the per-pound
  #     rate and dividing published corned beef 65% under shelf - so a size stating a $/lb rate is left
  #     to the clause below that was written for it.
  # What remains is the narrow case: the name says per-lb, the price does not, and the size states a
  # package of more than one pound. There the size is the only party describing what was actually bought.
  if ($unit -eq 'lb' -and $pr.kind.perlb) {
    $szlb  = [regex]::Match(("" + $deal.size_text), '(?i)^\s*(\d+(?:\.\d+)?)\s*-?\s*lbs?\b')
    $rate  = (("" + $deal.size_text) -match '(?i)\$\s*\d+(?:\.\d+)?\s*/\s*lb')
    $inPrc = ((ConvertTo-DigitNumerals ("" + $deal.price_text)) -match '(?i)(per\s*lb|/\s*lb|\blb\.?\b|a\s*pound|per\s*pound)')
    # AND NOT Sam's "priced per pound" SUFFIX. That phrase is Sam's own label for a random-weight item
    # whose listed price really IS the per-pound rate - the engine strips it in Get-MatchTexts for exactly
    # that reason. build-walmart-deals.ps1 extracts this pricing code (its line 24) and asks it what the
    # engine would do, then chooses which SHAPE to emit; its self-test case 4 exists because the package
    # shape used to publish a $10.35 tray at $10.35/lb. Letting this clause price the package shape
    # correctly flips that decision and fails a test that encodes a real, paid-for lesson. Aldi's
    # "Cabbage, Per LB" carries no such suffix, so the narrow fix stays narrow.
    $samsSuffix = (("" + $deal.name) -match '(?i),?\s*priced\s+per\s+\w+')
    if ($szlb.Success -and ([double]$szlb.Groups[1].Value -gt 1) -and (-not $rate) -and (-not $inPrc) -and (-not $samsSuffix)) {
      $szn = [double]$szlb.Groups[1].Value
      return @{ unit_price=($pr.per_item/$szn); basis="size $szn lb (per-lb marker was in the NAME only)"; note=$pr.note }
    }
    return @{ unit_price=$pr.per_item; basis='per-lb marker'; note=$pr.note }
  }
  if ($unit -eq 'each' -and $pr.kind.pereach) { return @{ unit_price=$pr.per_item; basis='per-each marker'; note=$pr.note } }
  # PER-LB RATE PRINTED IN THE SIZE, NOT THE PRICE. Hy-Vee's random-weight items carry the rate in the size
  # text ("2.85 lbs ($8.99/lb)") while the captured price is that same per-pound rate - the perlb marker above
  # only reads the PRICE text, so this fell through to the size division below and published $8.99/2.85 =
  # $3.15/lb for corned beef brisket (65% under the real shelf price), and $1.28/0.85 = $1.51/lb for red
  # onions (18% over). The tell is exact and self-checking: the captured price EQUALS the rate the size text
  # spells out, so the price is already per-pound. When it differs the price is a genuine package total and
  # the division below is right - a 0.15 lb B-size potato at $0.19 with a $1.29/lb rate must still divide.
  # Restricted to plain prices: a multibuy's computed per-item price could coincide with the rate by accident.
  if ($unit -eq 'lb' -and $plain) {
    $slb = [regex]::Match(("" + $deal.size_text), '\(\s*\$\s*(\d+(?:\.\d+)?)\s*/\s*lb\.?\s*\)')
    if ($slb.Success) {
      $rate = [double]$slb.Groups[1].Value
      if ($rate -gt 0 -and [math]::Abs($pr.per_item - $rate) -lt 0.005) {
        return @{ unit_price=$rate; basis='per-lb rate in size'; note=$pr.note }
      }
    }
  }
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
    # PORTION COUNT INSIDE ONE PACKAGE IS NOT A PACK COUNT (2026-07-30, garlic bread).
    # For most 'each' commodities the count IS the unit a shopper buys - a bagel, a bun, a popsicle, an ear of
    # corn - so dividing is right, and 55 of the 56 each-commodities on the board price that way at every store.
    # Garlic bread is the exception that proves the rule: Baker's "New York Bakery Texas Toast" lists "6 ct" (six
    # SLICES baked into one package) and priced out at $1.165/each, while the SAME commodity at Fareway and
    # Hy-Vee is a loaf/tray whose size carries no count at all and prices per PACKAGE ($3.99, $4.48). So the
    # cheapest-store verdict was one slice against a whole loaf - a 3.4x wrong basis, published, and invisible
    # to every band/freshness check because both numbers are REAL prices (the [[board-basis-ambiguity]] class).
    # A commodity whose stores cannot all express the portion count must be compared on the coarser basis they
    # ALL share: the package. Declared per commodity (same pattern as pint_oz above) so nothing else changes.
    if ($pk -and $cat.PSObject.Properties['pack_is_package'] -and $cat.pack_is_package) {
      return @{ unit_price=$pr.per_item; basis="per-package ($pk ct inside)"; note=$pr.note }
    }
    if ($plain -and $pk)  { return @{ unit_price=($pr.per_item/$pk); basis="per-$pk-pack"; note=$pr.note } }
    # A Hy-Vee PERKS ad price is a single retail unit; with no pack count it prices per-each (a pack count above
    # still divides). Scoped to the Perks pattern so the general "bare package, unknown count -> drop" guard holds.
    if ((-not $plain) -or ($deal.size_text -match '(?i)^\s*(1\s*)?(ct|count|ea|each)\.?\s*$') -or ([string]$deal.price_text -match '(?i)perks\s*price')) { return @{ unit_price=$pr.per_item; basis='per-each'; note=$pr.note } }
    return $null   # bare package price with unknown count -> not confident, drop
  }
  return $null
}

# A "Buy N, get K ..." conditional deal that NEEDS a captured regular price + a unit basis to be priceable.
# (Plain "N for $M" is NOT included here - it prices on its own without a regular.)
function Test-IsMultibuy([string]$t) { return ((ConvertTo-DigitNumerals ("" + $t)) -match '(?i)buy\s*\d+\s*,?\s*get\s*\d+') }

function Get-RegularSrcDate([string]$store, [string]$baseName) {
  # WHICH out\regular ROWS CARRY THEIR CAPTURE DATE. src_date is what lets the ranker below keep, per
  # commodity, only the FRESHEST capture that covers it. A row with no src_date is exempt from that test
  # forever, so this one decision is the difference between "a 16-day-old price" and "a 16-day-old price
  # that OUT-RANKS today's".
  #   Walmart  - unions several captures, so every row must be dated or the union has no ordering.
  #   Sam's    - the ONE store with a SECOND everyday source. Its prices reach the board through
  #              out\sams\sams-deals-*.json (dated), while out\regular\sams-regular-2026-07-14.json is a
  #              60-row hand-promotion nothing refreshes. Left date-less it was exempt from the ranker, and
  #              "cheapest row per store" then let the 16-day-old copy BEAT today's real price. Measured on
  #              the 2026-07-30 board: 5 cells, and the onions verdict published Sam's $0.737/lb while Sam's
  #              own 07-29 feed says $0.8267/lb and Aldi was actually cheapest at $0.7967/lb.
  #   everyone else - their out\regular file is their ONLY everyday source and their alt feed is the weekly
  #              AD, a different KIND of price. Dating them would let the ad's date filter the everyday rows
  #              out from under the store. That is the near-miss this rule must not cross; case 23 pins it.
  if (@('Walmart', "Sam's Club") -notcontains $store) { return '' }
  # A PROMOTED FILE IS NOT A CAPTURE, AND MUST NOT RANK LIKE ONE (2026-08-21).
  # hunter-*-regular-<date>.json holds prices the Recipe Hunter's agent looked up one at a time. It is
  # a handful of rows, not a sweep - and the freshness ranker reads "newest capture" as an authority
  # about coverage. Dating it made a NINE-row file the newest Walmart capture, with depth 1 for any
  # commodity it touched, so every older capture holding more than one row became eligible again:
  #     bouillon / Walmart   0.1681 (08-11 capture)  ->  0.0813 from a 2026-07-18 vegetable base
  # One promoted row re-opened five weeks of superseded captures and handed the cell to a 34-day-old
  # product whose link could not even be derived. audit-tile-integrity hard-failed it at 2.07x.
  # Left UNDATED these rows are treated the way every non-Walmart store's rows already are: always
  # eligible, competing on price, never displacing a real capture and never admitting one. The Beef
  # Base row it was carrying is $0.3506/oz against the capture's $0.1681, so it simply loses - which
  # is the correct outcome for a single hand-checked price against a full sweep.
  if ($baseName -match '^hunter-') { return '' }
  $m = [regex]::Match($baseName, '(\d{4}-\d{2}-\d{2})$')   # [regex]::Match, never -match: $Matches is global
  if (-not $m.Success) { return '' }
  return $m.Groups[1].Value
}

function Get-RowSrcDate([string]$store, $row, [string]$fileDate) {
  # A ROW IS AS OLD AS ITS OWN EVIDENCE, NEVER AS YOUNG AS ITS FILE (2026-08-02).
  # Get-RegularSrcDate above dates every row in a file by the file's NAME. That was fine while a store's
  # out\regular file was written whole by one capture. It stopped being fine the moment a file could hold
  # rows of MIXED age: refresh-sams-verified.ps1 re-prices the ~20 hand-verified Sam's rows a fresh capture
  # confirms and carries the other 40 unchanged, so naming the result sams-regular-2026-08-01.json handed
  # all 60 rows an 08-01 stamp. The 40 carried rows then out-ranked Sam's real 2026-07-29 feed and took
  # cells off it: sandwich-bags flipped from the 580-ct Ziploc at $0.0168/ea to a 300-ct SNACK bag at
  # $0.0309/ea - 84% dearer, on a row nothing had re-verified. The guards caught it before it published.
  # DIRECTIONAL ON PURPOSE. A row's own as_of is used only when it is OLDER than the file date, which can
  # only ever make a row rank LOWER. The opposite direction - trusting a row that claims to be fresher than
  # the file it lives in - is the as_of laundering fixed in the Fareway builder the same day, and it is the
  # one mistake that could let a stale price out-rank a live one.
  # SAM'S ONLY, and that limit was MEASURED, not assumed. Applied to Walmart as well, this moved three cells
  # the wrong way in one rebuild (lime-juice, pudding-cups and taco-sauce all landed at ~2x their own stored
  # link) because Walmart's rows are carried forward across a 14-day UNION with their original as_of: re-dating
  # them changes which capture is "newest" for a commodity, and a different product wins the cell. That union
  # has its own ordering discipline and its own guard; perturbing it is a separate piece of work with its own
  # evidence. Sam's is the store with a mixed-age file, so Sam's is the store this fixes.
  if (-not $fileDate) { return '' }
  if ($store -ne "Sam's Club") { return $fileDate }
  $ao = ''
  if ($row.PSObject.Properties['as_of']) { $ao = [string]$row.as_of }
  if (($ao -match '^\d{4}-\d{2}-\d{2}$') -and ($ao -lt $fileDate)) { return $ao }
  return $fileDate
}

# SELECT-FRESHESTCAPTUREROWS NOW LIVES IN capture-depth-lib.ps1 (2026-08-21), because this engine is not
# its only reader: audit-capture-eviction checks the published board against the same rule and used to do
# it from a hand-restated copy, kept honest by a test-auditors grep for a shared literal. A grep can see a
# literal change and cannot see a change in MEANING - and the meaning did change the day the everyday/sale
# split made one product emit two rows. The lib's header carries the full history: the onions bug the
# freshness rule exists for, the baby-formula bug the depth exception exists for, and the cherries cell
# that made depth count distinct products instead of rows.
. (Join-Path $PSScriptRoot 'capture-depth-lib.ps1')


# IS THIS AD FILE LIVE ON THE BOARD'S OWN DATE? Pure, so the self-test below can reach the real code instead
# of a copy of it - the inline version of this check had no test at all, and an inline copy is how a guard
# ends up proven against something the pipeline does not run. Returns $null when the file is live, or the
# reason string when it is not. Judged against the BOARD's date, never the wall clock, so a pinned regression
# run stays reproducible. Absent evidence is not evidence: no ad_to is never expired, no ad_from never early.
function Test-AdWindowClosed {
  param($Doc, [datetime]$BoardDate)
  if ($Doc.ad_to) {
    $adTo = $null; try { $adTo = [datetime]$Doc.ad_to } catch {}
    if ($adTo -and $adTo -lt $BoardDate) { return ("its ad window closed " + $Doc.ad_to + " (" + [int](($BoardDate - $adTo).TotalDays) + "d before this board's " + $BoardDate.ToString('yyyy-MM-dd') + ")") }
  }
  if ($Doc.ad_from) {
    $adFrom = $null; try { $adFrom = [datetime]$Doc.ad_from } catch {}
    if ($adFrom -and $adFrom -gt $BoardDate) { return ("its ad window does not open until " + $Doc.ad_from + " (" + [int](($adFrom - $BoardDate).TotalDays) + "d after this board's " + $BoardDate.ToString('yyyy-MM-dd') + ")") }
  }
  return $null
}

# ---------------------------------------------------------------- SELF-TEST (provable multibuy math; -SelfTest exits here)
# Which everyday-price files (out\regular\<store>-regular-<date>.json) to load per store. EVERYDAY-ONLY stores
# (Walmart) run no weekly ad cycle, so a partial daily refresh (a throttled ~50-item pull) must UNION with the
# recent captures or it collapses the board - the 2026-07-23 incident, when a 50-of-410 Walmart pull cut the
# store to 80 cells and the coverage guard blocked the publish. Every OTHER store here runs weekly SALES, and
# dating its everyday rows would let today's everyday price filter a still-valid sale out of the freshness
# ranker - so they stay newest-file-only. PURE function (operates on a passed file list, reads no disk) so
# `compare-deals.ps1 -SelfTest` can prove the union never silently regresses to newest-only.
# Select-RegularFileSet + the everyday-only store list now live in regular-fileset-lib.ps1, shared with
# guards.ps1. They used to be here only, and guards.ps1 answered "which files does the board price from?"
# with its own simpler "newest per store" - which is a DIFFERENT answer for Walmart, the one store this
# function unions. 332 live Walmart cells were priced from files guards 5 and 10 never opened. A guard must
# iterate the same file set the engine priced from, or it is guarding a different board than the one that
# ships. The self-test cases below still exercise it through the lib.
. (Join-Path $PSScriptRoot 'regular-fileset-lib.ps1')

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
  # a commodity carrying the pack_is_package declaration (see the 'each' branch of Get-UnitPrice)
  function _CP($unit) { [pscustomobject]@{ unit=$unit; pack_is_package=$true } }

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

  # --- 11b: Hy-Vee PERKS dual price -> publish the PERKS (member) price, never the non-member or the savings ---
  # garlic bread: "$2.98 PERKS PRICES, NON-MEMBER PRICE $3.48" -> 2.98 (not 3.48; a Perks each-item with no pack prices per-each)
  _Near 'Hy-Vee Perks each ($2.98)'   (Get-UnitPrice (_D 'Hy-Vee garlic bread, SAVE! .50, $2.98 PERKS PRICES, NON-MEMBER PRICE $3.48' 'Hy-Vee garlic bread, SAVE! .50, $2.98 PERKS PRICES, NON-MEMBER PRICE $3.48' $null $null) (_C 'each')).unit_price 2.98 0.001
  # cauliflower with a "SAVE! 50c" savings must NOT be read as 0.50 -> 3.49
  _Near 'Hy-Vee Perks vs cents-save'  (Get-UnitPrice (_D ([char]0x201C+'Bud by Dole cauliflower, SAVE! 50'+[char]0x00A2+', $3.49 PERKS PRICES. NON-MEMBER PRICE $3.99') 'Bud by Dole cauliflower' $null $null) (_C 'each')).unit_price 3.49 0.001
  # bare "$1 PERKS" (no decimal) -> 1.00
  _Near 'Hy-Vee Perks whole-dollar'   (Get-UnitPrice (_D 'Larabar protein bars, $1 PERKS PRICES. NON-MEMBER PRICE $1.25' 'Larabar protein bars, $1 PERKS PRICES. NON-MEMBER PRICE $1.25' $null $null) (_C 'each')).unit_price 1.00 0.001
  # membership detection (the flag the board uses to gate the nomem column) fires on the Perks pattern, not on plain rows
  if ('Hy-Vee garlic bread, $2.98 PERKS PRICES, NON-MEMBER PRICE $3.48' -match '(?i)perks\s*price') { Write-Output 'ok    Perks membership flag detected' } else { Write-Output 'FAIL  Perks membership flag NOT detected'; $script:fail++ }
  if ('Hy-Vee milk $2.98' -notmatch '(?i)perks\s*price') { Write-Output 'ok    plain Hy-Vee row not flagged membership' } else { Write-Output 'FAIL  plain row wrongly flagged membership'; $script:fail++ }

  # --- 11b2: MUST-FIRE FIXTURE for this guard's FOUNDING BUG - the weight-package divisor ------------------
  # Added 2026-07-29. The golden regression test exists because of one bug: the first weight-package divisor
  # read the pack size out of the item NAME, so "Kroger Yellow Onions (3 lb bag)" priced per POUND got divided
  # by 3 and published at $0.33/lb. The fix was to read the PRICE TEXT only. Nothing in the suite actually
  # proved the guard could still catch that, so a green run could equally have meant "working" or "blind" -
  # the [[guard-fixture-rule]] failure mode. These are the founding bug and its clean twin, pinned:
  #   MUST-FIRE  : pack size in the NAME + a plain per-lb price  -> must NOT divide
  #   CLEAN TWIN : pack size in the PRICE TEXT                   -> must divide
  _Near 'onions (3 lb bag) in NAME - must NOT divide' (Get-UnitPrice (_D '$0.99' 'Kroger Yellow Onions (3 lb bag)' $null 'lb') (_C 'lb')).unit_price 0.99 0.001
  _Near 'onions "Per 3-Lb Bag" in PRICE - must divide' (Get-UnitPrice (_D '$4.99 Per 3-Lb Bag' 'Kroger Yellow Onions' $null 'lb') (_C 'lb')).unit_price 1.6633 0.001
  # the sibling that produced the same class on Aldi grapes: "$4.99 Per 2-Lb. Pkg" published as $4.99/lb
  _Near 'grapes "Per 2-Lb. Pkg" - must divide'        (Get-UnitPrice (_D '$4.99 Per 2-Lb. Pkg' 'Aldi Red Seedless Grapes' $null 'lb') (_C 'lb')).unit_price 2.495 0.001

  # --- 11c: per-lb RATE printed in the size text (2026-07-28 corned-beef / red-onion mispricing) -----------
  # Hy-Vee random-weight rows read "2.85 lbs ($8.99/lb)" with the per-POUND rate captured as the price. The
  # price must be published as-is, NOT divided by the weight. These three cases pin all three outcomes.
  _Near 'per-lb rate in size (heavy pkg)' (Get-UnitPrice (_D '$8.99' 'TableMakers, Corned Beef Brisket Point Cut' $null '2.85 lbs ($8.99/lb)') (_C 'lb')).unit_price 8.99 0.001
  _Near 'per-lb rate in size (light pkg)' (Get-UnitPrice (_D '$1.28' 'Sweet Red Onions' $null '0.85 lbs ($1.28/lb)') (_C 'lb')).unit_price 1.28 0.001
  # price != the stated rate -> it IS a package total and must still divide: $0.19 / 0.15 lb = $1.267/lb
  _Near 'package total w/ rate shown'     (Get-UnitPrice (_D '$0.19' 'B-Size Gold Potatoes' $null '0.15 lbs ($1.29/lb)') (_C 'lb')).unit_price 1.2667 0.001

  # --- 11d: SIZE-PARSER DIVERGENCE FIXES (2026-07-30) - the engine vs pu-lib split, closed --------------
  # Every case is a REAL row from 2026-07-29: Bush's beans band-flagged at $0.3988/oz, Hy-Vee Cola flagged
  # at $0.3933/floz, Sam's grits PUBLISHED at $0.1049/oz (".98 oz" read as 98 oz), Kemps OJ band-dropped
  # at $0.007/floz (".5 Gal." read as 5 gal). MUST-FIRE: cases 1,3,4,5 all fail on the pre-fix engine.
  _Near 'weight-first pack "16 oz 6 pk"'   (Get-UnitPrice (_D '$6.38' "Bush's Garbanzo Beans, 6 pk" $null '16 oz 6 pk') (_C 'oz')).unit_price 0.0665 0.001
  _Near 'pack-first order (must stay)'     (Get-UnitPrice (_D '$6.38' "Bush's Garbanzo Beans, 6 pk" $null '6 pk 16 oz') (_C 'oz')).unit_price 0.0665 0.001
  _Near 'x-separator "12 x 12 fl oz"'      (Get-UnitPrice (_D '$4.72' 'Hy-Vee Cola 12Pk' $null '12 x 12 fl oz') (_C 'floz')).unit_price 0.0328 0.001
  # the times-sign twin, built from [char]0x00D7 so this ASCII file never carries the literal. MUST-FIRE:
  # the 2026-07-30 batch shipped the times branch as a literal in this BOM-less (ANSI-read) file - two
  # mojibake chars that can never match a real U+00D7 - and every suite stayed green because only ASCII 'x'
  # was fixtured. This case is the one that goes red if the escape ever regresses to a literal again.
  _Near ('times-sign "12 ' + [char]0x00D7 + ' 12 fl oz"') (Get-UnitPrice (_D '$4.72' 'Hy-Vee Cola 12Pk' $null ('12 ' + [char]0x00D7 + ' 12 fl oz')) (_C 'floz')).unit_price 0.0328 0.001
  # the x-branch must NOT read marketing '2X' as a pack count (the each-number is required immediately):
  # with the lazy gap this halved 4 live cleaner names ('2X Concentrated ... 33.8 fl oz' -> 67.6).
  _Near '2X-marketing not a pack count'     (Get-UnitPrice (_D '$4.24' 'cleaner' $null 'fabuloso multi-purpose cleaner, 2x concentrated formula, lavender, 33.8 fl oz') (_C 'floz')).unit_price 0.1254 0.001
  _Near 'leading-dot ".98 oz" + name pack' (Get-UnitPrice (_D '$10.28' 'Quaker Instant Grits, Variety Pack, .98 oz., 46 pk.' $null '46 ct') (_C 'oz')).unit_price 0.228 0.001
  _Near 'leading-dot ".5 Gal." via name'   (Get-UnitPrice (_D '$4.49' 'Kemps 100% Pure Orange Juice From Concentrate .5 Gal. Jug' $null '0.5 gll') (_C 'floz')).unit_price 0.0702 0.001
  # --- 11e: pack_is_package - portion count inside ONE package (2026-07-30 garlic-bread basis bug) ---------
  # The live row: Baker's "New York Bakery Gluten Free Texas Toast" $6.99 / "6 ct" published $1.165/each and
  # took the cheapest slot from Fareway's whole $3.99 loaf. MUST-FIRE: with the declaration the price stays the
  # PACKAGE price. CLEAN TWIN: the identical row on an undeclared commodity must still divide, because that is
  # what every other each-commodity (bagels, buns, popsicles, corn) needs.
  _Near 'pack_is_package: 6 ct stays per-package' (Get-UnitPrice (_D '$6.99' 'New York Bakery Texas Toast with Real Garlic' $null '6 ct') (_CP 'each')).unit_price 6.99 0.001
  _Near 'undeclared commodity still divides'      (Get-UnitPrice (_D '$6.99' 'New York Bakery Texas Toast with Real Garlic' $null '6 ct') (_C  'each')).unit_price 1.165 0.001
  # the declaration must not invent a basis where there is no count at all - a bare loaf is still per-each
  _Near 'pack_is_package: no count -> per-each'   (Get-UnitPrice (_D '$3.99' 'Fareway Garlic Bread' $null 'each') (_CP 'each')).unit_price 3.99 0.001

  # --- 11f: max_pack_oz - the PACK FORM cap (2026-08-08 packet-vs-canister ruling) -------------------------
  # The live rows: "Taco Seasoning (packet)" was filled with McCormick Mild Taco Seasoning Mix 8.5 Oz, and
  # "Ranch Seasoning Mix (packet)" with Great Value Classic Ranch 8 oz Canister. Both are the bulk form of the
  # right contents, at a per-oz rate a packet buyer never pays. MUST-FIRE: the canister is rejected. CLEAN
  # TWINS: the real packet passes, an undeclared commodity is untouched, and an item whose size cannot be read
  # passes (an unknown size is not a violation - treating it as one would empty every store that omits sizes).
  $MAXPACK['_selftest-packet'] = 4
  if (-not (Test-PackSize '_selftest-packet' '8.5 oz' 'Mc Cormick Mild Taco Seasoning Mix 8.5 Oz')) { Write-Output 'ok    max_pack_oz rejects the 8.5 oz canister' } else { Write-Output 'FAIL  max_pack_oz let the bulk canister through'; $script:fail++ }
  if (-not (Test-PackSize '_selftest-packet' '8 oz' 'Great Value Classic Ranch Salad Dressing & Recipe Mix, 8 oz Canister')) { Write-Output 'ok    max_pack_oz rejects the 8 oz canister' } else { Write-Output 'FAIL  max_pack_oz let the ranch canister through'; $script:fail++ }
  if (Test-PackSize '_selftest-packet' '1.25 oz' 'Our Family Seasoning Mix, Taco 1.25 Oz') { Write-Output 'ok    max_pack_oz keeps the real 1.25 oz packet' } else { Write-Output 'FAIL  max_pack_oz rejected a real packet'; $script:fail++ }
  if (Test-PackSize '_selftest-packet' '4 oz' 'Great Value Classic Ranch Mix, 1 oz Packets, 4 Count') { Write-Output 'ok    max_pack_oz keeps a 4-count of packets' } else { Write-Output 'FAIL  max_pack_oz rejected a multi-packet box'; $script:fail++ }
  if (Test-PackSize '_selftest-packet' '' 'Taco Seasoning Mix') { Write-Output 'ok    max_pack_oz: unreadable size is NOT a violation' } else { Write-Output 'FAIL  max_pack_oz rejected an item whose size it could not read'; $script:fail++ }
  if (Test-PackSize 'undeclared-commodity' '8.5 oz' 'Mc Cormick Mild Taco Seasoning Mix 8.5 Oz') { Write-Output 'ok    max_pack_oz: undeclared commodity untouched' } else { Write-Output 'FAIL  max_pack_oz fired on a commodity that never declared it'; $script:fail++ }
  $MAXPACK.Remove('_selftest-packet')

  # the 'snax' GLOBAL_EXCLUDE token (blocks snack TRAYS from winning real-commodity cells). $GLOBAL_EXCLUDE
  # is defined AFTER this block exits, so read the token from this script's own source (the extraction regex
  # audit-match-soundness.ps1 already uses) - a hard-coded 'snax' literal here would pass whether or not the
  # engine still carries the token, i.e. a gate that can never arm. MUST-FIRE while the token is absent.
  $gexBody = [regex]::Match((Get-Content $PSCommandPath -Raw), '\$GLOBAL_EXCLUDE = @\((?<b>[\s\S]*?)\r?\n\)').Groups['b'].Value
  $snaxTok = [regex]::Match($gexBody, "'([^']*snax[^']*)'").Groups[1].Value
  if ($snaxTok -and ('go2snax, hard salami, mild cheddar cheese' -match $snaxTok)) { Write-Output "ok    'snax' exclude catches the GO2snax tray" } else { Write-Output "FAIL  'snax' token absent from GLOBAL_EXCLUDE or no longer catches GO2snax"; $script:fail++ }
  if ($snaxTok -and ("member's mark standard shredded mild yellow cheddar cheese 5 lbs." -notmatch $snaxTok)) { Write-Output "ok    real shredded cheese not excluded by 'snax'" } else { Write-Output "FAIL  'snax' wrongly excludes real cheese (or token absent)"; $script:fail++ }

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

  # --- 15: universal implausibility floor (the band-less dropped-decimal backstop) --------------------------
  # a decimal-drop below the per-unit floor is dropped; a real cheap staple and the exempt 'each' unit survive.
  if (-not (Test-Floor 'oz' 0.0023))  { Write-Output 'ok    floor drops $0.0023/oz decimal-drop (the grits bug)' } else { Write-Output 'FAIL  floor let a $0.0023/oz price through'; $script:fail++ }
  if (Test-Floor 'oz' 0.0304)         { Write-Output 'ok    floor keeps real $0.0304/oz salt' } else { Write-Output 'FAIL  floor wrongly dropped real salt'; $script:fail++ }
  if (-not (Test-Floor 'lb' 0.03))    { Write-Output 'ok    floor drops $0.03/lb decimal-drop' } else { Write-Output 'FAIL  floor let a $0.03/lb price through'; $script:fail++ }
  if (Test-Floor 'each' 0.0043)       { Write-Output "ok    'each' exempt (500-ct swab box legitimately sub-cent)" } else { Write-Output "FAIL  'each' should be unfloored"; $script:fail++ }

  # --- 16-19: the file set GUARDS iterate must be the one the BOARD was priced from ------------------------
  # Item 9 (2026-07-30) gave guards.ps1 this function; it then reopened its own hole by re-deriving the AS-OF
  # from (Get-Date).Date while the engine resolves it against $ads.today - the value it also NAMES the board
  # with. FROZEN founding bug, measured 2026-07-30 08:19: comparison-2026-07-29.json was rebuilt from
  # ads-2026-07-29 on 07-30, so walmart-regular-2026-07-15.json (711 rows, 323 carrying current_price) was
  # priced into the shipped board and sat outside guard 5's and guard 10's file set. These cases run the REAL
  # entry point guards.ps1 calls, over a synthetic out\ tree in TEMP, so they cannot pass while the production
  # path stops using it. Synthetic and frozen - never regenerated from the live board.
  $sd = Join-Path $env:TEMP ('regfileset-selftest-' + [guid]::NewGuid())
  New-Item -ItemType Directory (Join-Path $sd 'regular') -Force | Out-Null
  # THE EDGE CAPTURE. Cases 16/17/19 all turn on a Walmart capture that is exactly ONE WINDOW old
  # relative to the 07-29 board: in reach for that board, out of reach for 07-30's. That date was
  # frozen at 2026-07-15 because the window was then 14 days. When the capture policy moved the
  # window to the 90-day quarter (2026-08-20), the literal quietly became a 15-day-old file sitting
  # INSIDE a 90-day window, and cases 17 and 19 inverted - the fixture stopped testing the boundary
  # and started asserting the opposite of it. Deriving the date from the window keeps the boundary
  # under test at whatever the window becomes next. Still synthetic and still never regenerated
  # from the live board - that freeze is about not reading the answer off the thing under test.
  $edgeW = 'walmart-regular-' + ([datetime]'2026-07-29').AddDays(-(Get-RegularUnionDays)).ToString('yyyy-MM-dd')
  foreach ($n in @($edgeW,'walmart-regular-2026-07-29','hyvee-regular-2026-07-15','hyvee-regular-2026-07-29')) {
    '{}' | Set-Content (Join-Path $sd ('regular\' + $n + '.json')) -Encoding UTF8
  }
  try {
    # 16. MUST FIRE: board dated 07-29, clock 07-30 -> the capture the board WAS priced from stays in reach.
    '{}' | Set-Content (Join-Path $sd 'comparison-2026-07-29.json') -Encoding UTF8
    $g1 = @(Select-EngineRegularFiles $sd ([datetime]'2026-07-30') | ForEach-Object { $_.BaseName })
    if ($g1 -contains $edgeW) { Write-Output 'ok    guards as-of follows the BOARD, not the wall clock' }
    else { Write-Output 'FAIL  guards as-of re-derived from the clock - a file the board WAS priced from is out of guard 5/10 reach again'; $script:fail++ }
    # 17. CLEAN TWIN: board dated 07-30 -> that same capture is now one day PAST the window and must stay
    #     OUT. Proves the fix follows the board's own date rather than widening the window unconditionally.
    '{}' | Set-Content (Join-Path $sd 'comparison-2026-07-30.json') -Encoding UTF8
    $g2 = @(Select-EngineRegularFiles $sd ([datetime]'2026-07-30') | ForEach-Object { $_.BaseName })
    if ($g2 -notcontains $edgeW) { Write-Output 'ok    a capture outside the BOARD''s own window stays excluded' }
    else { Write-Output ('FAIL  the guards file set widened unconditionally - ' + $edgeW + ' is one day past the window and is being guarded as live'); $script:fail++ }
    # 18. an ad-cycling store is still newest-only whatever the as-of (unioning one would guard expired sales)
    if ($g1 -notcontains 'hyvee-regular-2026-07-15') { Write-Output 'ok    ad-cycling store stays newest-only under the board as-of' }
    else { Write-Output 'FAIL  a non-everyday store started unioning - expired sale prices would be guarded as live'; $script:fail++ }
    # 20. MUST FIRE: the founding bug. Fareway's 08-09 flyer prints "prices good August 10-15", so priced
    #     against an 08-09 board it is tomorrow's sale and must not reach a cell.
    $early = Test-AdWindowClosed ([pscustomobject]@{ ad_from='2026-08-10'; ad_to='2026-08-15' }) ([datetime]'2026-08-09')
    if ($early) { Write-Output 'ok    an ad whose window has not opened yet is refused (not-yet-live sale)' }
    else { Write-Output 'FAIL  a future-dated ad was priced onto the board - tomorrow''s sale prices publish today'; $script:fail++ }
    # 21. CLEAN TWIN: the same window on its OPENING day is live. Proves 20 is a date test, not a blanket refusal.
    if (-not (Test-AdWindowClosed ([pscustomobject]@{ ad_from='2026-08-10'; ad_to='2026-08-15' }) ([datetime]'2026-08-10'))) { Write-Output 'ok    that same ad goes live on the day its window opens' }
    else { Write-Output 'FAIL  the ad-window gate refuses a LIVE ad - every sale row would drop off the board'; $script:fail++ }
    # 22. the ad_to half still fires, and absent evidence is still not evidence (no window = never refused)
    if (Test-AdWindowClosed ([pscustomobject]@{ ad_from='2026-07-26'; ad_to='2026-08-01' }) ([datetime]'2026-08-09')) { Write-Output 'ok    an expired ad is still refused' }
    else { Write-Output 'FAIL  the expired-ad half of the window gate stopped firing'; $script:fail++ }
    if (-not (Test-AdWindowClosed ([pscustomobject]@{ deals=@() }) ([datetime]'2026-08-09'))) { Write-Output 'ok    an ad file declaring no window is never refused' }
    else { Write-Output 'FAIL  a file with no ad window was refused - the frozen bakers fixture would drop out'; $script:fail++ }
    # 19. no board on disk -> the wall clock (guard 12 hard-fails that state on its own)
    Remove-Item (Join-Path $sd 'comparison-*.json') -Force
    $g3 = @(Select-EngineRegularFiles $sd ([datetime]'2026-07-30') | ForEach-Object { $_.BaseName })
    if ($g3 -notcontains $edgeW) { Write-Output 'ok    no board on disk falls back to the wall clock' }
    else { Write-Output 'FAIL  the no-board fallback did not use the wall clock'; $script:fail++ }
  } finally { Remove-Item $sd -Recurse -Force -ErrorAction SilentlyContinue }

  # --- 20: the union WINDOW is single-sourced too ----------------------------------------------------------
  # guards.ps1 repeated the literal 14 next to this param's default, and nothing noticed if one of them moved.
  if (-not $PSBoundParameters.ContainsKey('WalmartMaxAgeDays')) {
    if ($WalmartMaxAgeDays -eq (Get-RegularUnionDays)) { Write-Output 'ok    union window single-sourced (compare-deals default == regular-fileset-lib)' }
    else { Write-Output ('FAIL  union window drift: -WalmartMaxAgeDays default is ' + $WalmartMaxAgeDays + ' but regular-fileset-lib says ' + (Get-RegularUnionDays) + ' - guards would iterate a different window than the engine'); $script:fail++ }
  }
  # Sam's unions on the same window and had no such check, so its default could drift alone.
  if (-not $PSBoundParameters.ContainsKey('SamsMaxAgeDays')) {
    if ($SamsMaxAgeDays -eq (Get-RegularUnionDays)) { Write-Output 'ok    union window single-sourced (-SamsMaxAgeDays default == regular-fileset-lib)' }
    else { Write-Output ('FAIL  union window drift: -SamsMaxAgeDays default is ' + $SamsMaxAgeDays + ' but regular-fileset-lib says ' + (Get-RegularUnionDays)); $script:fail++ }
  }
  # --- 20b: and the window must still equal the CAPTURE POLICY that justifies it ---------------------------
  # The window is only safe because the rotation promises to re-capture every term within it. If someone
  # shortens the quarter (or lengthens the window) without moving the other, rows again expire before their
  # turn comes round - the 2026-08-20 failure, where a 14-day window under a 90-day rotation had already
  # queued 100% of Walmart's cells for deletion. $null = policy unreadable, which is reported, not passed.
  $polDays = Get-PolicyCarryDaysFromText
  if ($null -eq $polDays) { Write-Output 'FAIL  capture-policy.ps1 MaxCarryDays could not be read - the union window has nothing to agree WITH'; $script:fail++ }
  elseif ($polDays -eq (Get-RegularUnionDays)) { Write-Output "ok    union window equals the capture policy ($polDays d rotation carry)" }
  else { Write-Output ('FAIL  policy drift: capture-policy.ps1 MaxCarryDays=' + $polDays + ' but the union window is ' + (Get-RegularUnionDays) + ' - everyday rows will expire before the rotation re-captures them'); $script:fail++ }

  # --- 21-24: a stale out\regular capture must not out-rank the store's own live feed ---------------------
  # FROZEN FOUNDING BUG (2026-07-30). out\regular\sams-regular-2026-07-14.json is a 60-row hand-promotion
  # that NOTHING refreshes. It loaded date-less, so Select-FreshestCaptureRows could never filter it, and
  # "cheapest row per store" handed 5 board cells to a 16-day-old price - including the ONIONS verdict,
  # published as Sam's $0.737/lb while Sam's own 2026-07-29 feed says $0.8267/lb and Aldi was cheapest at
  # $0.7967/lb. Synthetic and FROZEN: the pair below is the real founding case, never re-read from the board.
  # These compose the REAL loader decision with the REAL ranker filter, so neither can quietly stop being used.
  function _Eq($label, $got, $want) {
    if (("" + $got) -eq ("" + $want)) { Write-Output "ok    $label" }
    else { Write-Output ("FAIL  $label  got '" + $got + "' want '" + $want + "'"); $script:fail++ }
  }
  function _Row($n,$up,$sd) { [pscustomobject]@{ name=$n; unit_price=$up; src_date=$sd } }
  # 21. MUST FIRE: the Sam's out\regular capture carries its own capture date.
  _Eq "Sam's out\regular capture is dated" (Get-RegularSrcDate "Sam's Club" 'sams-regular-2026-07-14') '2026-07-14'
  # 22. MUST FIRE: dated, the 07-14 onions row LOSES to the 07-29 feed even though it is the cheaper number.
  $onion = @(Select-FreshestCaptureRows @(
    (_Row 'Yellow Onions, 10 lbs.' 0.737  (Get-RegularSrcDate "Sam's Club" 'sams-regular-2026-07-14')),
    (_Row 'Sweet Onions, 6 lbs.'   0.8267 '2026-07-29')
  ) | Sort-Object unit_price | Select-Object -First 1)
  _Eq "stale Sam's capture loses to today's feed" $onion.name 'Sweet Onions, 6 lbs.'
  # 23. CLEAN TWIN: a store whose out\regular file is its ONLY everyday source stays date-less, so its rows
  #     survive beside a newer weekly-AD row. Dating Baker's here would filter its whole everyday catalogue.
  _Eq "Baker's out\regular stays date-less" (Get-RegularSrcDate "Baker's" 'bakers-regular-2026-07-30') ''
  $bk = @(Select-FreshestCaptureRows @(
    (_Row 'Kroger 80/20 Ground Beef Roll 3 LB' 5.99 (Get-RegularSrcDate "Baker's" 'bakers-regular-2026-07-30')),
    (_Row "Baker's weekly ad row"              6.49 '2026-07-30')
  ))
  _Eq 'a single-source everyday store is never filtered out' $bk.Count 2
  # 24. CLEAN TWIN: with no fresher capture the stale rows are still the only Sam's price we have and must
  #     stay on the board - this fix corrects a stale-LOW, it must never silently drop coverage.
  $only = @(Select-FreshestCaptureRows @(
    (_Row "Member's Mark Whole Pork Tenderloins, Cryovac" 2.98 (Get-RegularSrcDate "Sam's Club" 'sams-regular-2026-07-14'))
  ))
  _Eq 'sole stale capture still prices its commodity' $only.Count 1

  # --- 25-27: a file of MIXED age must not lend its date to the rows it merely carries -------------------
  # FROZEN FOUNDING BUG (2026-08-02). refresh-sams-verified.ps1 re-prices the hand-verified Sam's rows a
  # fresh capture confirms and carries the rest unchanged, so out\regular\sams-regular-2026-08-01.json holds
  # 20 rows dated 08-01 and 40 still dated 07-26. Get-RegularSrcDate dates by FILENAME, so all 60 claimed
  # 08-01 and the carried ones out-ranked Sam's real 07-29 feed. Measured on the board that produced this
  # fix: sandwich-bags flipped from the 580-ct Ziploc at $0.0168/ea to a 300-ct SNACK bag at $0.0309/ea,
  # 84% dearer and re-verified by nobody. Guard 4 caught it at 0.54x against the stored link.
  _Eq 'a carried row keeps its OWN older date, not the file''s' (Get-RowSrcDate "Sam's Club" ([pscustomobject]@{ as_of = '2026-07-26' }) '2026-08-01') '2026-07-26'
  $mixed = @(Select-FreshestCaptureRows @(
    (_Row 'Ziploc Snack Bags'                  0.0309 (Get-RowSrcDate "Sam's Club" ([pscustomobject]@{ as_of = '2026-07-26' }) '2026-08-01')),
    (_Row 'Ziploc Brand Sandwich Bags, 580 ct' 0.0168 '2026-07-29')
  ) | Sort-Object unit_price | Select-Object -First 1)
  _Eq 'the real feed still wins over a merely-carried row' $mixed.name 'Ziploc Brand Sandwich Bags, 580 ct'

  # --- 25-28: COVERAGE DEPTH. A capture only displaces an older one if it knows at least as much. -------
  # FROZEN FOUNDING BUG (2026-08-06). Sam's baby-formula: sams-deals-2026-08-05 held ONE formula row (Bubs
  # Goat Milk, $1.4445/oz) and sams-deals-2026-07-29 held twenty-plus including Member's Mark Advantage
  # Premium at $0.7704/oz. Under "newest wins outright" the 1-row capture took the commodity and the live
  # cell jumped +87%, with every price, basis and crown guard reading green because both rows are real.
  # 58 cells estate-wide. Synthetic and FROZEN, never re-read from the board.
  # 25. MUST FIRE: the richer OLDER capture stays eligible, so the cheap real row still prices the cell.
  $formula = @(Select-FreshestCaptureRows @(
    (_Row 'Bubs Goat Milk Infant Formula Powder With Iron, 20 oz., 2 pk.' 1.4445 '2026-08-05'),
    (_Row "Member's Mark, Advantage Premium, Infant Formula, 48 oz." 0.7704 '2026-07-29'),
    (_Row "Member's Mark, Infant Premium, Infant Formula, 48 oz."     0.8017 '2026-07-29'),
    (_Row "Member's Mark Sensitivity Premium Baby Formula, 48 oz."    0.8329 '2026-07-29')
  ) | Sort-Object unit_price | Select-Object -First 1)
  _Eq 'a 1-row capture does not evict a 3-row one' $formula.name "Member's Mark, Advantage Premium, Infant Formula, 48 oz."
  # 26. CLEAN TWIN, AND IT IS THE ONIONS BUG ITSELF: when the newer capture is RICHER it still displaces the
  #     older one outright. If this ever flips, the depth rule has been written as "cheapest in the window"
  #     and case 22 above is being argued with. The stale-LOW $0.737 must stay dead.
  $onionDepth = @(Select-FreshestCaptureRows @(
    (_Row 'Yellow Onions, 10 lbs.'   0.737  '2026-07-14'),
    (_Row 'Sweet Onions, 6 lbs.'     0.8267 '2026-07-29'),
    (_Row 'Red Onions, 5 lbs.'       0.9100 '2026-07-29'),
    (_Row 'Vidalia Onions, 10 lbs.'  0.9500 '2026-07-29')
  ) | Sort-Object unit_price | Select-Object -First 1)
  _Eq 'a RICHER newer capture still evicts the stale-low' $onionDepth.name 'Sweet Onions, 6 lbs.'
  # 27. TIES GO TO THE FRESHER CAPTURE. Equal coverage means the newer one is strictly better information,
  #     and this is the shape of case 22's real data (1 row vs 1 row), so it must not regress.
  $tie = @(Select-FreshestCaptureRows @(
    (_Row 'Old Yellow Onions, 10 lbs.' 0.737  '2026-07-14'),
    (_Row 'New Sweet Onions, 6 lbs.'   0.8267 '2026-07-29')
  ) | Sort-Object unit_price | Select-Object -First 1)
  _Eq 'equal coverage still goes to the newer capture' $tie.name 'New Sweet Onions, 6 lbs.'
  # 28. CLEAN TWIN: a thinner newer capture that is also CHEAPER still wins on price. Keeping the richer
  #     capture eligible must never mean preferring it - it competes, it does not outrank.
  $cheapThin = @(Select-FreshestCaptureRows @(
    (_Row "Member's Mark Butter, 4 lb."   2.98 '2026-08-05'),
    (_Row 'Land O Lakes Butter, 2 lb.'    4.15 '2026-07-29'),
    (_Row 'Kerrygold Butter, 1 lb.'       6.20 '2026-07-29')
  ) | Sort-Object unit_price | Select-Object -First 1)
  _Eq 'a thin but genuinely cheaper capture still wins' $cheapThin.name "Member's Mark Butter, 4 lb."
  # 28b. MUST FIRE - THE FROZEN CHERRIES CASE (2026-08-21). One product, split into its everyday half and
  #      its sale half, must not present as a two-product capture. This is the real data: Walmart item id
  #      46491694 in the 2026-07-14 capture, against the single row the 2026-08-11 capture holds.
  #      Under row-counting the July capture scored 2 against August's 1, survived, and its $2.50/lb sale
  #      won the cell while Walmart was charging $6.97/lb - a price 38 days dead, one cent off the crown.
  $splitInflated = @(Select-FreshestCaptureRows @(
    (_Row 'Fresh Red Cherries'               2.5000 '2026-07-14'),   # the SAME product, sale half
    (_Row 'Fresh Red Cherries'               4.9600 '2026-07-14'),   # ...and everyday half
    (_Row 'Fresh Red Cherries, 2.25 lb Bag'  6.9689 '2026-08-11')
  ) | Sort-Object unit_price | Select-Object -First 1)
  _Eq 'a split one-product capture does not out-depth a live one' $splitInflated.name 'Fresh Red Cherries, 2.25 lb Bag'
  # 28c. CLEAN TWIN for 28b, and it is the guard against over-correcting into "distinct is per capture-wide
  #      name". TWO GENUINELY DIFFERENT products in the older capture still out-depth the newer single row -
  #      the baby-formula fix must survive the cherries fix. Same prices as 28b so the only variable is
  #      whether the older capture's two rows name one product or two.
  $twoRealProducts = @(Select-FreshestCaptureRows @(
    (_Row 'Fresh Red Cherries'               2.5000 '2026-07-14'),
    (_Row 'Rainier Cherries, 2 lb Bag'       4.9600 '2026-07-14'),
    (_Row 'Fresh Red Cherries, 2.25 lb Bag'  6.9689 '2026-08-11')
  ) | Sort-Object unit_price | Select-Object -First 1)
  _Eq 'two REAL products still out-depth a newer single row' $twoRealProducts.name 'Fresh Red Cherries'
  # CLEAN TWIN: the direction that must NOT work. A row claiming to be FRESHER than the file it lives in is
  # the as_of laundering fixed in the Fareway builder the same day; taking its word would let a stale price
  # out-rank a live one, which is the exact failure this whole family of fixes exists to prevent.
  _Eq 'a row claiming to be FRESHER than its file is ignored' (Get-RowSrcDate "Sam's Club" ([pscustomobject]@{ as_of = '2026-08-05' }) '2026-08-01') '2026-08-01'
  # MUST FIRE: A PROMOTED FILE IS NOT A CAPTURE (2026-08-21). hunter-*-regular-<date>.json holds a
  # handful of hand-looked-up prices, but the freshness ranker reads "newest capture" as an authority
  # about COVERAGE. Dated, a nine-row file became Walmart's newest capture at depth 1 for every
  # commodity it touched, which re-admitted five weeks of superseded captures: bouillon/Walmart went
  # from 0.1681 to a 2026-07-18 vegetable base at 0.0813, and tile-integrity hard-failed it at 2.07x.
  # Undated, these rows behave like every non-Walmart store's - always eligible, competing on price,
  # never displacing a real capture and never admitting one.
  _Eq 'a hunter- promoted file is UNDATED, so it cannot become the newest capture' (Get-RegularSrcDate 'Walmart' 'hunter-walmart-regular-2026-08-16') ''
  _Eq 'a hunter- Sam''s file is undated too' (Get-RegularSrcDate "Sam's Club" 'hunter-samsclub-regular-2026-08-16') ''
  # CLEAN TWIN: a REAL Walmart capture must still be dated, or the ranker loses its ordering entirely
  # and the onions bug walks straight back in.
  _Eq 'a real walmart capture is still dated' (Get-RegularSrcDate 'Walmart' 'walmart-regular-2026-08-11') '2026-08-11'
  # CLEAN TWIN: Walmart is deliberately OUT of scope. Its 14-day union carries rows forward with their
  # original as_of, so re-dating them changes which capture owns a commodity - measured live on 2026-08-02 as
  # three cells landing at ~2x their own link. Pinned here so nobody widens the rule without redoing that work.
  _Eq 'Walmart rows still take the FILE date (its union owns their ordering)' (Get-RowSrcDate 'Walmart' ([pscustomobject]@{ as_of = '2026-07-18' }) '2026-08-01') '2026-08-01'

  # --- 28-40: ROUTING fixtures for the 2026-08-06 rule edits (triage plan-2026-08-06) ---------------------
  # A rule change's whole effect is WHERE A PRODUCT ENDS UP after first-match-wins, so these run the REAL
  # Match-Category over the REAL commodities.json rather than asserting a regex in isolation. Match-Category
  # and $GLOBAL_EXCLUDE are defined AFTER this block exits, so they are extracted from this script's own
  # source and evaluated here - the same trick the 'snax' case above uses, and for the same reason: a
  # transcribed copy would pass whether or not the engine still does this.
  # MUST-FIRE / CLEAN-TWIN pairs, every name a REAL captured row:
  #   R1 oat-milk needed a word boundary  - 'oat milk' matches inside 'GOAT milk'
  #   R2 eggs ate an Aldi breakfast PIZZA it could never price per dozen
  #   R3 canned-green-beans claimed FRESH steam-in-bag beans
  #   R4 whipped-cream's adjacency could not cross the word Dairy
  #   R5 frozen-lasagna's blanket 'pasta' exclude (aimed at dry noodle boxes) ate a real frozen lasagna
  #   R6 acorn-squash could not read the store's 'Acorn/Table Queen Squash' naming
  #   R7 storage-bags is labelled (gallon) and had no size guard at all - a PINT cell was live at Fareway
  $cdSelfSrc = Get-Content $PSCommandPath -Raw
  $mcSrc = [regex]::Match($cdSelfSrc, '(?s)\r?\nfunction Get-MatchTexts.*?\r?\n\}\r?\nfunction Match-Category.*?\r?\n  return \$null\r?\n\}')
  $gexSrc = [regex]::Match($cdSelfSrc, '(?s)\$GLOBAL_EXCLUDE = @\([\s\S]*?\r?\n\)')
  if (-not $mcSrc.Success -or -not $gexSrc.Success) {
    Write-Output 'FAIL  could not extract Match-Category / GLOBAL_EXCLUDE from this script - the routing fixtures EXAMINED NOTHING'; $script:fail++
  } else {
    Invoke-Expression $gexSrc.Value
    Invoke-Expression $mcSrc.Value
    function _Route($label, $name, $want) {
      $c = Match-Category $name
      $got = if ($c) { [string]$c.id } else { '<unmatched>' }
      if ($got -eq $want) { Write-Output ("ok    route: $label -> $got") }
      else { Write-Output ("FAIL  route: $label -> got '$got' want '$want'  [" + $name + ']'); $script:fail++ }
    }
    # MUST-FIRE (each of these routes WRONG on the pre-2026-08-06 rules)
    _Route 'R1 goat-milk formula reaches baby-formula' "Bubs Goat Milk Infant Formula Powder With Iron, 20 oz., 2 pk." 'baby-formula'
    _Route 'R1 evaporated goat milk leaves oat-milk'   'Meyenberg Evaporated Vitamin D Goat Milk Unsweetened, 12 fl oz' '<unmatched>'
    _Route 'R2 breakfast pizza leaves eggs'            'Breakfast Best Sausage Egg Cheese Breakfast Pizza 2pk 112 OZ' 'frozen-pizza'
    _Route 'R3 fresh steam-bag beans leave canned'     "Member's Mark Extra Fine Whole Green Beans 16 oz. steam bags, 5 ct." '<unmatched>'
    _Route 'R4 whipped DAIRY topping is admitted'      'Friendly Farms Whipped Dairy Topping 13 FL OZ' 'whipped-cream'
    _Route 'R5 Stouffers Party Size Pasta (Frozen)'    "Stouffer's Classic Lasagna with Meat and Sauce, Party Size Pasta, Frozen Meals, 90 oz (Frozen)" 'frozen-lasagna'
    _Route 'R6 store slash-naming acorn squash'        'Acorn/Table Queen Squash' 'acorn-squash'
    # R7's quart case expected '<unmatched>' when it shipped, because quart bags had NO home - being
    # excluded from the gallon commodity meant falling off the board entirely. R14 below gives them one,
    # so the expectation moves from "nowhere" to "the quart commodity". The ASSERTION is unchanged and is
    # the one that matters: a quart bag must never be priced as a gallon bag.
    _Route 'R7 QUART bags leave the (gallon) commodity' 'Boulder Quart Slider Storage Bags 40 CT' 'quart-storage-bags'
    _Route 'R7 PINT bags leave the (gallon) commodity'  'Bright Essentials Freezer Bags, Zipper, Pint Size' '<unmatched>'
    # HALF GALLON, added by the developer the same day: with only quart+pint excluded, the Sam's cell moved
    # from a QUART box to a HALF GALLON box ($0.0764/each) while Sam's own true gallon box sat at $0.0792 -
    # the same misleading comparison one size down. Measured over the 14-day corpus: exactly 2 names carry
    # 'half gallon' into this commodity (this one and a Baker's Kroger slider that loses to its own store's
    # gallon box anyway), so the whole cost is Sam's cell moving 3.7% up to a like-for-like gallon price.
    _Route 'R7 HALF-GALLON bags leave it too'           "Ziploc Brand Half Gallon Freezer Storage Bags, Expandable Bottom, Grip 'n Seal Technology, 160 ct." '<unmatched>'
    _Route 'a plain GALLON Ziploc box still routes'     'Ziploc Brand Gallon Storage Bags, Stay Open Design, Easy to Fill, 208 ct.' 'storage-bags'
    # CLEAN TWINS (a token too broad shows up here, not on the board)
    _Route 'real oat milk still routes'                'Planet Oat Original Oatmilk, 52 oz' 'oat-milk'
    _Route 'Aldi oat milk still routes'                'Friendly Farms Original Oatmilk 64 FL OZ' 'oat-milk'
    _Route 'a real dozen of eggs still routes'         'Goldhen Grade A Large Eggs 12 CT' 'eggs'
    _Route 'canned cut green beans still route'        'Del Monte Fancy Cut Green Beans, 101 oz.' 'canned-green-beans'
    _Route 'plain whipped topping still routes'        'Kroger Original Whipped Topping' 'whipped-cream'
    # R5's twin, in two halves. First a REAL captured row: a dry box is claimed by lasagna-noodles (index 201)
    # long before frozen-lasagna (252), so it can never become a frozen dinner. Then a SYNTHETIC name that
    # actually isolates the guard - it reaches frozen-lasagna's include, carries 'pasta', and carries NO frozen
    # marker, so the exclude must still bite. Measured 2026-08-06: every real dry lasagna-pasta row in the
    # corpus is claimed by pasta / brown-rice / lasagna-noodles first, so only a synthetic row can reach here.
    _Route 'a DRY lasagna box lands on lasagna-noodles' 'Great Value Lasagna Pasta, 16 oz' 'lasagna-noodles'
    _Route 'pasta still excludes when NOT frozen'       'Store Brand Lasagna with Meat Sauce, Pasta, 38 oz' '<unmatched>'
    _Route 'a GALLON bag box still routes'             'Great Value Freezer Guard Double Zipper Gallon Freezer Bag, 80 Count' 'storage-bags'
    _Route 'the Aldi crown bag row is untouched'       'Boulder Twin Lock Storage Bags 40 CT' 'storage-bags'

    # --- R8-R13, 2026-08-06 second pass: SIX WRONG PRODUCTS THAT WERE LIVE ON THE BOARD --------------------
    # Found by audit-capture-eviction.ps1 on the day it was written, not by any existing guard. All six had
    # been matching their commodity for a long time and losing on price, so nothing ever surfaced them. Then
    # the resumed partial Walmart pull of 2026-08-06 landed a capture holding ONE row for each of these
    # commodities, that capture won the commodity outright under Select-FreshestCaptureRows, and the wrong
    # product became the cell. A latent routing bug and a thin capture are individually survivable; together
    # they put shredded CARROTS on the oranges row at $3.09/lb.
    # Each exclude was measured against every candidate row in the live corpus first: 9 rows leave in total,
    # all nine wrong products, and no store loses coverage (every one falls through to a correct cheaper row).
    _Route 'R8 shredded orange CARROTS leave oranges'  'Fresh Shredded Orange Carrots, 10 Oz Bag' 'carrots'
    _Route 'R9 garlic parmesan SEASONING leaves cheese' 'Weber Garlic Parmesan Seasoning, Gluten Free, 4.3 oz' '<unmatched>'
    _Route 'R9 Sams parmesan pepper seasoning too'     "Member's Mark Parmesan Pepper Seasoning, 7.5 oz." '<unmatched>'
    _Route 'R10 the SEASONING brand named Cookies'     'Cookies Flavor Enhancer All Purpose Seasoning & Rub, 8 oz' '<unmatched>'
    _Route 'R11 worcestershire SEASONING is not sauce' 'Grill Mates Kosher Cracked Peppercorn & Worcestershire Seasoning, 2.75 oz Bottle' '<unmatched>'
    _Route 'R12 teriyaki BEEF BITES are not sauce'     "Jack Link's 100% Beef Teriyaki Tender Bites 10Ounce Resealable Bag" '<unmatched>'
    _Route 'R12 the Bakers teriyaki beef sticks too'   "Jack Link's x MrBeast Teriyaki Beef Sticks, 9.20 ounce, 10 count of .92 oz meat sticks" '<unmatched>'
    _Route 'R13 jarred BRUSCHETTA is not fresh tomato' 'Cara Mia Tomato Bruschetta, 14.8 oz. Jar' '<unmatched>'
    # CLEAN TWINS: the real product of each of the six must be untouched, or a token is too broad.
    _Route 'R8 twin: real navel oranges still route'   'Fresh Navel Oranges, 4 lb Bag' 'oranges'
    _Route 'R9 twin: real grated parmesan still routes' 'Great Value Grated Parmesan Cheese, 16 oz Bottle' 'parmesan'
    _Route 'R10 twin: real cookies still route'        'Great Value Classic Chocolate Chip Cookies, 18.2 oz' 'cookies'
    _Route 'R11 twin: real worcestershire still routes' 'Great Value Worcestershire Sauce, 10 fl oz' 'worcestershire'
    _Route 'R12 twin: real teriyaki sauce still routes' 'Great Value Teriyaki Sauce, 15 fl oz, 1 Count' 'teriyaki-sauce'
    _Route 'R13 twin: fresh tomatoes still route'      'Fresh Beefsteak Tomatoes, Each' 'tomatoes'

    # --- R14, 2026-08-06: BAGS SPLIT BY SIZE (Brad's call) ----------------------------------------------
    # storage-bags was one commodity labelled "(gallon)" that excluded every other size, so quart bags had
    # no home at all - 8 real products across Aldi, Sam's and Walmart priced nothing. Now gallon / quart /
    # sandwich are three commodities. Measured over the 14-day corpus first: 95 distinct bag names, 44
    # gallon, 35 sandwich, 7 quart, 4 half-gallon, 1 pint.
    # THE TRAP IS THE COMBO PACK. Sam's sells "Gallon & Quart" and "Variety Pack" boxes whose count mixes
    # sizes, so they can price NEITHER per-gallon-bag nor per-quart-bag honestly - the count is a blend and
    # any per-bag figure invents a split that is not on the label. Both sides exclude them on purpose, which
    # is why half-gallon and pint also stay unmatched rather than being folded into the nearest size.
    _Route 'R14 Aldi quart bags get a home'            'Boulder Quart Slider Storage Bags 40 CT' 'quart-storage-bags'
    _Route 'R14 Sams quart bags too'                   'Ziploc Brand Quart Storage Bags, Stay Open Design, Easy to Fill, 216 ct.' 'quart-storage-bags'
    _Route 'R14 quart wording can be mid-name'         "Ziploc Freezer Quart Food Storage Bags, School Supplies, Stay Open Design, Grip 'n Seal Technology, Zipper, 100 Count" 'quart-storage-bags'
    # MUST-FIRE: the mixed-size boxes belong to NEITHER size.
    _Route 'R14 a GALLON+QUART combo box is neither'   'Ziploc Brand Gallon & Quart  Storage Bags, Stay Open Design, Easy to Fill, 204 ct.' '<unmatched>'
    _Route 'R14 a VARIETY pack is neither'             'Ziploc Gallon Quart Freezer and Storage Slider Bags Variety Pack, Power Shield Technology, 149 ct.' '<unmatched>'
    _Route 'R14 half gallon still has no home'         'Kroger Slider Half Gallon Freezer Storage Bags' '<unmatched>'
    # CLEAN TWINS: the other two sizes are untouched by the new commodity.
    _Route 'R14 twin: gallon still routes'             'Bright Essentials Storage Bags, Double Zipper, 20 Gallon' 'storage-bags'
    _Route 'R14 twin: the Aldi gallon crown is safe'   'Boulder Twin Lock Storage Bags 40 CT' 'storage-bags'
    _Route 'R14 twin: sandwich bags still route'       'Great Value Sandwich Bags, 180 Count' 'sandwich-bags'
    # R15: the loose 'zipper bags?' include is GONE. Measured over 27,659 corpus names it admitted exactly
    # ONE product and that product was dried fruit - every real bag row is caught by the storage/freezer/
    # slider tokens. A food package described by its packaging is not a storage bag.
    _Route 'R15 dried fruit in a zipper bag is not a bag' 'Sun-Maid Dried Mangos 15oz Resealable Stand-Up Zipper Bag' '<unmatched>'
    _Route 'R15 a mylar food pouch is not a quart bag'  'Dehydrated Zucchini, 1 Full Quart Mylar Bag' 'zucchini'

    # --- R16, 2026-08-06: WOOD POLISH IS NOT CITRUS -----------------------------------------------------
    # audit-household-in-food HARD-FAILED the publish on the full Walmart re-pull: Pledge "Orange Enhancing"
    # wood polish was landing in the EDIBLE commodity 'oranges'. The gap was a disarmed sibling, not a new
    # class - 'lemons' has excluded 'polish' for a while and 'oranges'/'limes' never got the same guard, so
    # the defence existed and simply was not applied across the family. Measured over the 14-day corpus:
    # 7 rows leave oranges, all seven wood-care products, zero real fruit; limes loses nothing today and is
    # guarded anyway so the family stops depending on which citrus a brand happens to scent this season.
    # 'pledge' is carried alongside 'polish' because one row is "Pledge Wood Oil ... Orange Scent" with no
    # word "polish" in it at all - the brand token is what makes the class complete.
    # Both land in furniture-polish, which is their real home - releasing them from a fruit commodity does
    # not orphan them, it lets the household commodity that was always right for them finally claim them.
    _Route 'R16 orange-scented wood polish is not fruit' 'Pledge Expert Care, Wood Polish Shines and Protects, Orange Enhancing, Aerosol, 9.7 oz., Pack of 3' 'furniture-polish'
    _Route 'R16 Pledge wood OIL has no word polish'      'Pledge Wood Oil, Expert Care, Trigger Spray - Moisturizes & Revives with Orange Scent, 16 oz' 'furniture-polish'
    _Route 'R16 twin: real navel oranges are untouched'  'Fresh Navel Oranges, 4 lb Bag' 'oranges'
    _Route 'R16 twin: real limes are untouched'          'Fresh Limes, Each' 'limes'

    # --- R17, 2026-08-06: INFANT PUREE NAMING TWO VEGETABLES IS NOT PRODUCE ------------------------------
    # THE FOUNDING BUG: "Cerebelly 6+ Months Organic Spinach Apple Sweet Potato Puree 4 Oz" matched the
    # include of THREE produce commodities (apples \bapple(s)?\b, spinach, sweet-potatoes) and was excluded
    # by none, so first-match-wins gave a 4 oz baby-food jar to whichever sorts first and priced fresh
    # produce at a baby-food per-ounce rate. audit-match-soundness flagged it 'new-contested' and it was then
    # ACCEPTED into the baseline as part of an unrelated tortilla move, so it would never have re-surfaced.
    # THE SHAPE: this is the third instance (happy\s*tot 07-28, serenity\s*kids 08-01). Every one is a
    # baby/toddler brand whose name happens to list the produce inside it. baby-food sits at index 297 and
    # apples at 20, so widening baby-food's include can never win the race - the fix has to be an EXCLUDE,
    # which is why all three live in $GLOBAL_EXCLUDE.
    # Measured over all 28,526 estate names before shipping: 17 routing changes, nothing left a commodity it
    # belonged to. The simulation also caught a defect in the FIX - carrying the brand token into baby-food's
    # include dragged in "Little Journey Gentle Baby Wash Shampoo", so baby-food now excludes personal-care
    # forms. That row is the clean twin below.
    _Route 'R17 the founding Cerebelly jar leaves produce' 'Cerebelly 6+ Months Organic Spinach Apple Sweet Potato Puree 4 Oz' 'baby-food'
    _Route 'R17 Aldi Little Journey puree leaves apples'   'Little Journey Apple Sweet Potato Puree 4 OZ' 'baby-food'
    _Route 'R17 a toddler pouch leaves apples'             'Once Upon A Farm No Added Sugar Apple, Sweet Potato & Spinach Toddler Tractor Wheels 5 Ea' 'baby-food'
    _Route 'R17 infant yogurt cup leaves yogurt'           'Little Journey Apple Banana Peach Yogurt 4 OZ' 'baby-food'
    _Route 'R17 infant puree leaves bananas'               'Little Journey Apple Blueberry Banana Puree 4 OZ' 'baby-food'
    # These two were globally excluded but had no home - the include widening is what recovers them.
    _Route 'R17 Happy Tot pouch is no longer orphaned'     'Happy Tot Stage 4 Organic Pears Blueberries & Spinach Pouch' 'baby-food'
    _Route 'R17 Serenity Kids pouch is no longer orphaned' 'Serenity Kids Free Range Chicken & Thyme with Organic Parsnip & Beet Pouch, 3.5oz' 'baby-food'
    # CLEAN TWINS. The first is the fix's own near-miss; the rest prove the brand tokens did not evict the
    # commodities that legitimately sell these brands (the eviction the serenity\s*kids note warns about).
    _Route 'R17 twin: the brand SHAMPOO is not baby food'  'Little Journey Gentle Baby Wash Shampoo With Oatmeal Extract 16 FL OZ' '<unmatched>'
    _Route 'R17 twin: Little Journey wipes keep their cell' 'Little Journey Sensitive Baby Wipes 192 CT' 'baby-wipes'
    _Route 'R17 twin: Little Journey diapers keep theirs'  'Little Journey Size 4 Club Pack Diapers 82 CT' 'diapers'
    _Route 'R17 twin: real apples are untouched'           'Fresh Gala Apples, 3 lb Bag' 'apples'
    _Route 'R17 twin: real spinach is untouched'           'Fresh Baby Spinach, 10 oz Clamshell' 'spinach'
    _Route 'R17 twin: real sweet potatoes are untouched'   'Sweet Potatoes, 3 lb Bag' 'sweet-potatoes'
    _Route 'R17 twin: real yogurt is untouched'            'Great Value Plain Greek Yogurt, 32 oz' 'yogurt'
  }

  Write-Output ('-'*54)
  if ($script:fail -eq 0) { Write-Output 'SELF-TEST PASS  (all multibuy / BOGO cases correct)'; exit 0 }
  else { Write-Output ("SELF-TEST FAIL: $script:fail case(s)"); exit 1 }
}

# ---------------------------------------------------------------- load + normalize all sources
$deals = New-Object System.Collections.Generic.List[object]
function Add-Norm($store,$name,$price,$size,$regular,$src,$ptype='sale',$srcDate='',$adFrom='',$adTo='',$adBasis='') {
  if (-not $name) { return }
  # src_date = the date of the CAPTURE FILE this row came from (not the ad cycle). Only rows loaded from dated
  # per-store capture files carry it; it is how the ranking step below can prefer the freshest capture that
  # covers a commodity instead of letting an older capture's price compete with it.
  # ad_from / ad_to = THE WINDOW THIS PARTICULAR DEAL RUNS IN, carried from the feed that supplied it.
  # Added 2026-08-21 (Brad: "we MUST log ad dates and pricing"). Before this the engine had no per-deal
  # window at all, so build-sale-windows fell back to the ONE store-level window in ad-schedule.json -
  # and Hy-Vee runs THREE flyers at once (Weekly 08-17..08-23, monthly 08-03..08-30, 3 Day Sale
  # 08-21..08-23). All 28 of its sale cells collapsed onto the weekly window, retiring the 216
  # monthly-ad deals seven days early while the ad was still running.
  # BLANK STAYS BLANK: a row whose source states no window must not inherit a neighbour's. That is the
  # borrowed-window bug guard 8 exists for, and it is why this is carried rather than defaulted.
  # AN EXPIRED SALE DOES NOT PRICE THE BOARD, PER ROW (2026-08-21).
  # Test-AdWindowClosed already refuses a whole flyer FILE outside its window, which was the only
  # granularity available while the engine had no per-row dates. It is not enough now: Hy-Vee runs
  # three flyers at once inside ONE ads file, and Baker's per-item promos in one capture legitimately
  # end 7, 14, 28 and 32 days apart. Without this check the dates would be decorative - captured,
  # carried, displayed, and never acted on - which is the shape this whole session keeps finding.
  # Judged against the BOARD's date ($today from the ads file), never the wall clock, so a pinned
  # regression run stays reproducible - the same rule Test-AdWindowClosed follows.
  # A row with no ad_to is NOT expired: absent evidence is not evidence, and an undated markdown is
  # handled by its own TTL rather than by being silently dropped here.
  if ($ptype -eq 'sale' -and $adTo -match '^\d{4}-\d{2}-\d{2}$' -and $script:BoardToday) {
    if ([string]$adTo -lt [string]$script:BoardToday) { $script:ExpiredSaleRows++; return }
  }
  $deals.Add([pscustomobject]@{ store=$store; name=[string]$name; price_text=[string]$price; size_text=[string]$size; regular=$regular; source_ad=$src; price_type=$ptype; src_date=[string]$srcDate; ad_from=[string]$adFrom; ad_to=[string]$adTo; ad_basis=[string]$adBasis })
}
$ads = Get-Content $AdsFile -Raw | ConvertFrom-Json
$today = $ads.today
# The board's own date, visible to Add-Norm so it can refuse an expired sale row. Script-scoped
# because Add-Norm is a function and cannot see this scope otherwise; set from the ads file rather
# than the clock so a pinned regression run stays reproducible.
$script:BoardToday = [string]$today
$script:ExpiredSaleRows = 0
foreach ($d in $ads.deals) {                                                                # weekly ads = 'sale'
  switch ($d.store) {
    # pull-grocery-ads stamps ad_from/ad_to on EVERY deal now - per FLYER for Hy-Vee (it runs three at
    # once), per ITEM for Aldi (flyerkit gives each product its own), per CIRCULAR for Family Fare.
    # Passing them through is the entire point of having captured them.
    # Aldi also now carries original_price as `regular`, so an Aldi ad row can state what it was cut from.
    'Hy-Vee'      { Add-Norm $d.store $d.item $d.item $null $null $d.source_ad 'sale' '' $d.ad_from $d.ad_to }      # price+size embedded in item text
    'Aldi'        { Add-Norm $d.store $d.item $d.ad_price $d.size $d.regular $d.source_ad 'sale' '' $d.ad_from $d.ad_to }
    'Family Fare' { Add-Norm $d.store $d.item $d.ad_price $d.size $d.regular $d.source_ad 'sale' '' $d.ad_from $d.ad_to }
    default       { Add-Norm $d.store $d.item ($d.ad_price + ' ' + $d.item) $d.size $d.regular $d.source_ad 'sale' '' $d.ad_from $d.ad_to }
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

# FAREWAY RUNS TWO ADS AT ONCE (2026-08-09). A weekly Sun-Sat flyer AND a ~4-week monthly one, with
# overlapping windows - on 08-09 the monthly covered 08-03..08-29 while the weekly covered 08-10..08-15.
# Both are real sale prices, and "newest fareway-deals-*.json by name" can only ever see one of them, so the
# monthly ad had NEVER reached a board: every deals file this estate produced read the weekly only. Picking
# the newest is also actively wrong the moment the next weekly is captured early, because that file shadows a
# monthly that is still live for another three weeks.
# Safe to load them all now only because each file self-gates on its own ad_from/ad_to (Test-AdWindowClosed) -
# an out-of-window file refuses itself rather than leaking into the board. Explicit -FarewayFile still wins,
# and the sibling pick-up is skipped entirely when the caller pinned one, so a regression run stays pinned.
# SCOPED TO THE PINNED FILE'S OWN FOLDER, not to $OutDir. A regression harness that pins a fixture pulls in
# only that fixture's siblings and stays hermetic; production pins out\fareway\... and picks up the real ones.
# Pinning one file must never mean silently ignoring a second ad that is live at the same time.
$farewayExtra = @()
if ($FarewayFile -and (Test-Path $FarewayFile)) {
  $fwDir = Split-Path $FarewayFile -Parent
  $pinned = Split-Path $FarewayFile -Leaf
  foreach ($f in (Get-ChildItem (Join-Path $fwDir 'fareway-deals-*.json') -EA SilentlyContinue | Sort-Object Name -Descending)) {
    if ($f.Name -eq $pinned) { continue }
    $farewayExtra += $f.FullName
  }
  if ($farewayExtra.Count) { Write-Warning ("compare-deals: Fareway runs concurrent ad windows; also loading " + $farewayExtra.Count + " sibling deals file(s): " + (($farewayExtra | ForEach-Object { Split-Path $_ -Leaf }) -join ', ') + " (each self-gates on its own window)") }
}

# Sam's is captured in PARTIAL SLICES - the club catalog is CAPTCHA-walled, so each run only gets the categories
# it got through before the wall. "Newest file wins" is right for a store we pull whole every week and WRONG for
# Sam's: the 2026-07-15 Omaha-club capture (428 rows) covers ~118 commodities where the 2026-07-08 national
# capture (263 rows) covered ~251, so taking only the newest cut 153 priced cells off the board with no warning.
# Load EVERY Sam's capture inside the age window instead, and let the ranking step keep - per commodity - only
# the rows from the freshest capture that actually covers it. A blind union would be worse than the bug it fixes:
# "cheapest per store" would let a stale-low price from an old capture beat today's real one.
# An explicit -SamsFile still wins (the regression harness pins one file).
Add-InputUsed -Tracker $inputUsage -Path $BakersFile -Role 'bakers-ad'
Add-InputUsed -Tracker $inputUsage -Path $FarewayFile -Role 'fareway-ad'
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
# Sam's is the clearest case for the ledger: it unions up to 11 captures at once, so "which of these is
# still doing work" is not answerable by eye at all.
foreach ($sfu in $samsFiles) { Add-InputUsed -Tracker $inputUsage -Path $sfu -Role 'sams-deals' }
# EXPIRED ADS DO NOT PRICE THE BOARD (2026-08-07, Brad's call). A weekly-ad supplement declares its own
# window in ad_from/ad_to, and these rows OVERRIDE the everyday storefront price whenever they are cheaper.
# Nothing retired them when the window closed, so a missed ad pull left a dead sale winning cells forever.
# Measured the day this landed: Fareway's newest ad file covered 2026-07-26..08-01 and its $1.99
# "All-Natural Iowa Pork Chops" was still the LIVE board's crown on 08-07, six days after the sale ended,
# against a real Fareway everyday price near $4.00/lb. 15 recipes were costed off it.
#
# This is deliberately NOT the carry-forward case guards.ps1 protects. A carried EVERYDAY row is old but
# still the store's honest price, and dropping it would be a silent cell drop, which is strictly worse.
# An expired SALE price is not old, it is FALSE - the sale is over and the store will not honour it.
#
# Judged against $today (the board date from the ads file), never the wall clock, so a pinned regression
# run stays reproducible. A file with no ad_to is never expired: absent evidence is not evidence of expiry,
# and the frozen bakers-deals-2026-07-05 fixture declares no window at all.
foreach ($extra in (@($BakersFile,$FarewayFile) + $farewayExtra + $samsFiles)) {
  if ($extra -and (Test-Path $extra)) {
    $ex = Get-Content $extra -Raw | ConvertFrom-Json
    # A WINDOW HAS TWO ENDS (2026-08-09). The ad_to half retires a sale after it closes; nothing stopped one
    # from going live BEFORE it opened, and a price the store will not honour yet is exactly as false as one
    # it will not honour any more. Found the day Fareway's flyer was downloaded on 08-09 and printed "Prices
    # good August 10-15" - capturing it that morning would have published tomorrow's sale prices today, and
    # ad-schedule.json's own current.from said 08-09, so nothing else would have caught it either.
    $why = Test-AdWindowClosed $ex ([datetime]$today)
    if ($why) {
      Write-Warning ("compare-deals: SKIPPING " + (Split-Path $extra -Leaf) + " - " + $why + ". " + @($ex.deals).Count + " sale row(s) not priced.")
      continue
    }
    $pt = if ($ex.price_type) { [string]$ex.price_type } else { 'sale' }
    $sd = ''
    if ([IO.Path]::GetFileNameWithoutExtension($extra) -match '(\d{4}-\d{2}-\d{2})$') { $sd = $Matches[1] }
    # A FLYER FILE DECLARES ITS WINDOW AT THE DOCUMENT LEVEL, and Test-AdWindowClosed above has already
    # refused the whole file if today falls outside it. Carry that window down onto each row so a cell
    # can be dated individually - and let a row that states its OWN window win, because Fareway runs a
    # weekly and a monthly ad concurrently whose rows legitimately expire on different days.
    foreach ($d in $ex.deals) {
      $rFrom = if ($d.ad_from) { [string]$d.ad_from } else { [string]$ex.ad_from }
      $rTo   = if ($d.ad_to)   { [string]$d.ad_to }   else { [string]$ex.ad_to }
      Add-Norm $d.store $d.item $d.ad_price $d.size $d.regular $d.source_ad $pt $sd $rFrom $rTo
    }
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
# ---- the ad rows a storefront markdown can INHERIT its window from --------------------------------
# Brad, 2026-08-21: "if an item has a sale price, it MUST of been on some ad previously." Largely
# true, and where it is true the store has ALREADY told us when the sale ends - so the honest move is
# to go and get that date rather than invent a TTL. Measured on this board: 176 of 377 undated sale
# cells match a real ad row (Hy-Vee 60 of 82). Hy-Vee's butter is the case that proved it - published
# as an undated sale at $2.48 while sitting in the 3 Day Sale flyer as "Hy-Vee butter, 16 oz., $2.48"
# valid 08-21..08-23.
# LIVE ADS ONLY here, deliberately: an expired flyer's dates would retire the cell the moment they
# were applied, and a flyer that has not opened would keep it alive past its real end. The
# sale-without-ad ledger asks the other question ("was it EVER advertised") and passes -IncludeExpired.
. (Join-Path $root 'ad-match-lib.ps1')
. (Join-Path $root 'rollback-ttl-lib.ps1')   # the LAST-RESORT window: see the TTL block in the split below
$script:AdIndex = $null
try { $script:AdIndex = Import-AdRows -OutDir $OutDir -BoardDate ([string]$today) } catch { Write-Warning ("ad-match index unavailable (" + $_.Exception.Message + ") - undated sales stay undated") }
$script:AdInherited = 0
$script:TtlDated = 0
# Sales dated by the STORE's own stated countdown (Fareway saleDisclaimerString). Counted separately
# from ad-inherited and TTL windows so the three sources stay distinguishable in the health block -
# a real date from the store and a 30-day guess must never read as the same fact.
$script:StoreCountdown = 0

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
  # Recorded on the SELECTED set, not on everything in the directory. Which captures the union actually
  # ADMITTED is the whole question a cleanup has to answer; what is merely present on disk is not.
  foreach ($rfu in $regFiles) { Add-InputUsed -Tracker $inputUsage -Path $rfu.FullName -Role 'everyday' }
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
    # WHICH out\regular rows carry their capture date: see Get-RegularSrcDate. Walmart unions captures, and
    # Sam's has a SECOND everyday source (out\sams) that its out\regular copy has to be ranked against; every
    # other store's out\regular file is its only everyday source and stays date-less.
    $sd = Get-RegularSrcDate ([string]$ex.store) ([string]$rf.BaseName)
    # $sd is the FILE's date. Get-RowSrcDate lets a row carrying an OLDER as_of keep it, so a file that holds
    # rows of mixed age (refresh-sams-verified re-prices some rows and carries the rest) cannot hand the
    # carried ones the refreshed file's freshness. Backward only - see that function.
    # THE EVERYDAY/SALE SPLIT (2026-08-21, Brad: "Ad pricing must never enter the every day pricing
    # value"). An out\regular file is nominally the store's EVERYDAY channel, but the row it carries is
    # simply "what you pay today" - which for 357 board cells was really a markdown, typed everyday,
    # 27 of them holding the Cheapest crown and none of them expiring under the 90-day carry.
    # price-split-lib reads each store's own discount signal (see its header for what each one is) and
    # returns the two halves. Applied HERE rather than in seven producers so it covers the rows already
    # on disk - the board is mostly carried-forward rows, which a producer-side fix could not reach for
    # a quarter - and so the capture files stay the honest record of what the store showed us.
    foreach ($d in $ex.deals) {
      $rsd = Get-RowSrcDate ([string]$ex.store) $d $sd
      $spl = Get-PriceSplit $d ([string]$ex.store)
      $script:LastBasis = if ($spl.sale_from) { 'store' } else { '' }
      if ($spl.sale_price) {
        # THE STORE STATED A COUNTDOWN. Highest precedence after its own explicit dates, because it
        # IS the store's own answer - Fareway's saleDisclaimerString, "Sale ends in N days", captured
        # from the storefront's Apollo cache. Brad found this by opening a product page and asking why
        # a row with a visible end date was being given a 30-day guess.
        #
        # DERIVED FROM THE ROW'S OWN as_of, NEVER FROM TODAY. The countdown is relative to the day it
        # was captured: "ends in 1 day" seen on 08-21 means 08-22, and still means 08-22 when the row
        # is read on 08-25. Reading it against today would push the expiry forward every single build
        # and produce a sale that never ends - the same infinite-TTL shape the rollback anchor exists
        # to prevent, arriving through a different door.
        # Verified against an independent source before shipping: the ribs read "Sale ends in 1 day"
        # on 2026-08-21 -> 2026-08-22, and fareway-deals-2026-08-20.json independently states the
        # weekly ad runs 2026-08-17 to 2026-08-22.
        # The derivation lives in price-split-lib beside the split it belongs to, so the frozen
        # fixtures exercise the REAL decision rather than a transcription of it.
        # ANCHORED ON THE ROW'S as_of, not $rsd's file date and not today - see that function's header.
        if (-not $spl.sale_from -and $null -ne $d.sale_ends_days) {
          $anchorDate = if ([string]$d.as_of -match '^\d{4}-\d{2}-\d{2}$') { [string]$d.as_of } else { $rsd }
          $sw = Get-StatedSaleWindow $d.sale_ends_days $anchorDate
          if ($sw) {
            $spl.sale_from = $sw.from; $spl.sale_to = $sw.to
            $script:StoreCountdown++; $script:LastBasis = 'store'
          }
        }
        # INHERIT THE AD'S WINDOW when the store's own row carried none. This is what turns "a sale
        # we cannot date" into "a sale that ends on the day the flyer says", and it is the difference
        # between a TTL guess and the store's own answer.
        if (-not $spl.sale_from -and $script:AdIndex) {
          $adHit = Find-AdForCell -Index $script:AdIndex -Store ([string]$ex.store) -Item ([string]$d.item) -PriceText ('$' + $spl.sale_price)
          if ($adHit -and $adHit.from -match '^\d{4}-\d{2}-\d{2}$' -and $adHit.to -match '^\d{4}-\d{2}-\d{2}$') {
            $spl.sale_from = $adHit.from; $spl.sale_to = $adHit.to; $script:AdInherited++; $script:LastBasis = 'ad'
          }
        }
        # LAST RESORT: a TTL, anchored to the first day we saw this exact cut price (Brad's rule for
        # Fareway, Walmart and Sam's - the three stores that publish no end date). Deliberately AFTER
        # the ad lookup: a real window from the store's own flyer always beats a number we chose.
        # Keyed on the store's product id, never the name, so a re-listing cannot restart the clock;
        # a row with no identity gets no window rather than a name-keyed guess.
        if (-not $spl.sale_from -and (Test-RollbackTtlStore ([string]$ex.store))) {
          $ttlKey = ''
          if ($d.item_id)   { $ttlKey = [string]$d.item_id }
          elseif ($d.sams_item_id) { $ttlKey = [string]$d.sams_item_id }
          elseif ($d.product_id)   { $ttlKey = [string]$d.product_id }
          elseif ($d.link_url -match '/products/(\d+)') { $ttlKey = $Matches[1] }
          if ($ttlKey) {
            # -AsOf IS THE ROW'S OWN CAPTURE DATE. Brad's ruling (2026-08-22): the TTL runs from DETECTION,
            # and detection is the capture that first showed the cut price, not the day this ledger met
            # the row. Passing only -Today handed a five-week-old Fareway markdown a fresh 30 days on
            # the day the ledger was created. Row as_of first, the file's date as the fallback.
            $ttlAsOf = if ([string]$d.as_of -match '^\d{4}-\d{2}-\d{2}$') { [string]$d.as_of } else { [string]$rsd }
            $rw = Get-RollbackWindow -Store ([string]$ex.store) -ItemId $ttlKey -Price ([double]$spl.sale_price) -Today ([string]$today) -AsOf $ttlAsOf -Root $root
            if ($rw) { $spl.sale_from = $rw.ad_from; $spl.sale_to = $rw.ad_to; $script:TtlDated++; $script:LastBasis = 'ttl' }
          }
        }
        # A CUT PRICE IS A SALE, AND IT CARRIES ITS OWN WINDOW. Typed 'sale' so build-sale-windows
        # dates it, the page badges it, and it can expire. Its everyday half is emitted separately
        # below so the cell the shopper reverts to is never lost.
        Add-Norm $d.store $d.item ('$' + $spl.sale_price) $d.size $d.regular $d.source_ad 'sale' $rsd $spl.sale_from $spl.sale_to $script:LastBasis
        # AND THE PRICE IT REVERTS TO. Without this row the everyday value disappears the moment a
        # store discounts an item, which is the other half of Brad's rule - everyday must not be
        # replaced by the ad. Only emitted when the store told us what it was cut FROM; a flagged row
        # with no was-price would otherwise publish the sale price twice under two labels.
        if ($spl.everyday_price -and $spl.everyday_price -gt $spl.sale_price) {
          Add-Norm $d.store $d.item ('$' + $spl.everyday_price) $d.size $null $d.source_ad 'everyday' $rsd '' ''
        }
      } else {
        Add-Norm $d.store $d.item $d.ad_price $d.size $d.regular $d.source_ad $pt $rsd
      }
    }
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
  # 'snax' (2026-07-30): GO2snax/PRO2snax are meat+cheese+candy snack TRAYS whose names contain a real
  # commodity phrase ('Mild Cheddar Cheese', 'Red Grapes'), and the existing '\bsnack\b' token cannot match
  # 'snax'. The GO2snax tray sat band-hidden at $0.7721/oz; the weight-first pack fix re-prices it at
  # $0.1287/oz by dividing its $1.66 "each" (per-tray, Sam's unit-price feed) price across all 6 trays -
  # a wrong basis on top of the wrong product - which would make a salami/caramel tray the published
  # CHEAPEST shredded cheese. No staple ever contains 'snax' ('\bsnax\b' cannot match inside GO2snax -
  # '2' is a word char - so the token is deliberately unanchored).
  # CORRECTION (post-batch review 2026-07-30): THREE snax products exist live, not the "exactly 2" the
  # batch measured - 'Outlaw Snax Crazy Queso Flavored Tortilla Snack Chips' also sits in the Walmart
  # regular files. It changes nothing here (its name never matched any include; pinned <unmatched> in the
  # baseline), and a Snax-brand product that ever legitimately belongs to a snack commodity has the
  # relax_global escape hatch, which waives exact global tokens per commodity.
  # NOTE: 'GO2snax...' -> shredded-cheese is pinned in out\audit\match-baseline.json, so the FIRST
  # audit-match-soundness.ps1 run after this change reports it DROPPED and exits 2 (publish holds). That
  # is the audit working as designed: review the snax drops, then bless via audit-match-soundness.ps1 -Accept.
  'snax',
  # pet + baby food: no human staple is ever "dog food"/"cat litter"/"Beech Nut" - keep them out of every human
  # commodity (chicken/bacon/rice/sweet-corn were stealing dog food & baby food). The pet/baby commodities
  # relax_global exactly the token they need, so they still match their own products.
    # 'happy\s*tot' added 2026-07-28: the Stage-token exclusions stop at "Stage 1-3", so "Happy Tot Stage 4
  # Organic Pears Blueberries & Spinach Pouch" evaded every baby-food rule and kept surfacing as fresh
  # spinach (and as a contested match on other produce). The brand is baby/toddler food only, so name it.
  # 'serenity\s*kids' added 2026-08-01 (triage 2026-08-01-08b14e): the SAME evasion, one brand later.
  # "Serenity Kids Free Range Chicken & Thyme with Organic Parsnip & Beet Pouch" carries no Stage token and
  # no 'baby food' phrase, so it reached canned-beets - and estate-wide it is 10 names on produce commodities.
  # The brand is baby/toddler food only. baby-food declares this token in relax_global so its OWN 9 pouches
  # keep routing to baby-food: the first simulation without that relax EVICTED all nine, which is the
  # opposite of the fix. Never add a brand here without checking who legitimately sells under it.
  # 'cerebelly','little\s+journey','once\s+upon\s+a\s+farm','plum\s+organics' added 2026-08-06: the THIRD
  # instance of this same evasion, and the one that showed the shape of the hole. "Cerebelly 6+ Months Organic
  # Spinach Apple Sweet Potato Puree 4 Oz" matches the include of THREE produce commodities (apples, spinach,
  # sweet-potatoes) and is excluded by none, so first-match-wins handed a 4 oz baby-food jar to whichever is
  # ordered first - pricing fresh produce at a baby-food per-ounce rate. It reached none of baby-food's own
  # rules: brand not listed, age marker "6+ Months" is not "Stage 1/2", form "Puree" is not "pouches".
  # WHY THIS LIST AND NOT baby-food's include: baby-food sits at index 297 and apples at 20, so Match-Category
  # returns apples long before baby-food is ever considered. Widening baby-food's include CANNOT fix an
  # earlier commodity's theft - only a global (or per-commodity) EXCLUDE can. That is why every fix in this
  # class lands here.
  # Measured over all 28,526 estate product names before shipping: 17 routing changes, no product left a
  # commodity it legitimately belonged to. 8 were the defect itself (3 apples, 3 yogurt, 2 bananas), 8 were
  # Happy Tot / Serenity Kids pouches that were globally excluded but orphaned (<unmatched> -> baby-food),
  # and 1 was a 0.35 oz Plum Organics toddler fruit snack leaving fruit-snacks.
  # Little Journey is Aldi's baby line and also sells wipes, diapers and formula, so baby-wipes, diapers and
  # baby-formula each relax_global this token - without that they lose their own products, the same eviction
  # the serenity\s*kids note warns about.
'dog\s+food','dog\s+treats?','dog\s+biscuits?','cat\s+food','cat\s+litter','beech[\s-]?nut','gerber','happy\s*baby','happy\s*tot','baby\s+food','serenity\s*kids','cerebelly','little\s+journey','once\s+upon\s+a\s+farm','plum\s+organics',
  # 'naan' added 2026-08-15 (board-collision fix, hunt-2026-08-15-shakedown mapping): "Marketside Tandoori
  # Style Garlic Naan Bites" held the WALMART CHEAPEST garlic cell at $0.268/each - naan bread priced as
  # fresh garlic bulbs. No commodity owns naan (zero includes match it; measured over all 31,097 estate
  # names: 13 naan products, 11 already <unmatched>), so no relax_global is needed anywhere. The other
  # mapped one, "Stonefire Original Mini Naan Bread ... for Dipping & Pizza" -> frozen-pizza, is ALSO a
  # wrong match (shelf-stable flatbread, not frozen pizza) and dropping it is intended.
  '\bnaan\b'
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

# ---------------------------------------------------------------- -Explain: why does this cell say that?
# READ-ONLY. Prints the ownership decision for one commodity and exits WITHOUT writing a board.
#
# Added 2026-08-21 after working out by hand why Family Fare's whole-cloves cell published $11.92/oz when a
# $2.99 jar sat in the same capture. That took about ten passes of throwaway script re-deriving what this
# engine already knows. The answer, once found, was one line long: ground-cloves' include list contained
# 'whole\s+cloves?', so it claimed the cheap jars first and whole-cloves never saw them.
#
# That is the CONTESTED failure - two commodities match one product and the winner is whichever sits earlier
# in commodities.json. audit-match-contested finds them in bulk; this answers the opposite question, the one
# actually asked when a single cell looks wrong: which rows could this commodity have had, and who took them.
#
# It lives HERE, inside the engine, on purpose. Match-Category is already copied into two auditors (see
# design\FINDINGS-contested-2026-08-21.md #6); a diagnostic that re-implemented the matcher would be the
# fourth copy and the first one anyone actually trusts, which is how a debugging tool starts lying.
if ($Explain) {
  $target = @($commodities | Where-Object { [string]$_.id -eq $Explain })
  if (-not $target.Count) { Write-Output ("-Explain: no commodity with id '" + $Explain + "'"); exit 1 }
  $tc = $target[0]
  $pos = [array]::IndexOf(@($commodities | ForEach-Object { [string]$_.id }), [string]$tc.id)
  Write-Output ("EXPLAIN  " + $tc.id + "  (" + $tc.label + ")   unit=" + $tc.unit + "   position " + $pos + " of " + @($commodities).Count + " in commodities.json")
  Write-Output ("  include: " + (@($tc.include) -join '  |  '))
  Write-Output ""
  $mine = 0; $lost = 0
  foreach ($d in $deals) {
    $nm = [string]$d.name
    if (-not $nm) { continue }
    $texts = Get-MatchTexts $nm
    $hit = $false
    foreach ($inc in $tc.include) { foreach ($t in $texts) { if ($t -match $inc) { $hit = $true; break } }; if ($hit) { break } }
    if (-not $hit) { continue }                       # this commodity's patterns never wanted it
    $winner = Match-Category $nm
    $wid = if ($winner) { [string]$winner.id } else { '<unmatched>' }
    if ($wid -eq [string]$tc.id) {
      $mine++
      Write-Output ("  OURS      {0,-12} {1,-9} {2,-10} {3}" -f $d.store, $d.price_text, $d.size_text, $nm)
    } else {
      $lost++
      # WHY it went elsewhere: our own exclude threw it out, or another commodity simply got there first.
      $n0 = $texts[0]; $selfExc = @()
      foreach ($exc in $tc.exclude) { if ($n0 -match $exc) { $selfExc += $exc } }
      $why = if ($selfExc.Count) { "our exclude " + $selfExc[0] }
             elseif ($wid -eq '<unmatched>') { "global exclude / no commodity" }
             else {
               $wpos = [array]::IndexOf(@($commodities | ForEach-Object { [string]$_.id }), $wid)
               if ($wpos -ge 0 -and $wpos -lt $pos) { "CONTESTED - '" + $wid + "' sits earlier (position " + $wpos + ")" }
               else { "claimed by '" + $wid + "'" }
             }
      Write-Output ("  LOST ->   {0,-12} {1,-9} {2,-10} {3}" -f $d.store, $d.price_text, $d.size_text, $nm)
      Write-Output ("            {0}" -f $why)
    }
  }
  Write-Output ""
  Write-Output ("  {0} row(s) this commodity keeps, {1} its patterns matched but lost." -f $mine, $lost)
  Write-Output "  A LOST row reading CONTESTED is decided by array order, not by a rule. Fix it with an"
  Write-Output "  explicit exclude on the commodity that should not have it - never by reordering the file."
  Write-Output "  (read-only: no board was written)"
  exit 0
}

# dedup identical rows (Family Fare's circular API repeats items across pages)
$seen = @{}; $ded = New-Object System.Collections.Generic.List[object]
foreach ($d in $deals) { $k = ($d.store + '|' + $d.name + '|' + $d.price_text + '|' + $d.size_text + '|' + $d.price_type); if (-not $seen.ContainsKey($k)) { $seen[$k]=$true; $ded.Add($d) } }
$deals = $ded

# Flat list of every matched deal (priced or not). Grouping by id afterward avoids per-id hashtable indexing.
$matched = New-Object System.Collections.Generic.List[object]
$flagged = New-Object System.Collections.Generic.List[object]
$mbUnpriced = New-Object System.Collections.Generic.List[object]   # Buy-N-Get-K deals we recognized but could NOT price -> surfaced, never silently dropped
# THE HOT LOOP RUNS THE PRECOMPILED MATCHER (2026-08-22). Profiled: 139 of 159 seconds per build was
# Match-Category - 45.7 million `-match` evaluations from an interpreted triple loop. match-lib makes
# the SAME decision (first-match-wins, global-exclude + relax_global, excludes on the raw name) from
# compiled regexes behind a sound literal prefilter, 17x faster on the full corpus.
# Match-Category above is NOT deleted and is NOT dead: it is the reference implementation. -Explain and
# the routing fixtures still call it, and test-match-lib.ps1 extracts it verbatim from this file every
# suite run and demands match-lib agree with it on every distinct name the engine feeds it - zero
# divergences or the suite goes red. That is what lets a second copy of the one rule that decides which
# product owns a cell exist at all.
. (Join-Path $PSScriptRoot 'match-lib.ps1')
$fastMatcher = New-CommodityMatcher -Commodities $commodities -GlobalExclude $GLOBAL_EXCLUDE
foreach ($d in $deals) {
  $c = Resolve-Commodity -Matcher $fastMatcher -Name $d.name
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
    elseif (-not (Test-Floor $c.unit $uprice)) {
      # in-band (or band-less) but below the universal per-unit floor -> a dropped-decimal / unit error.
      $flagged.Add([pscustomobject]@{ id=$c.id; label=$c.label; store=$d.store; name=$d.name; unit=$c.unit; unit_price=$uprice; band=("floor>=$($FLOOR[[string]$c.unit])"); price_text=$d.price_text; size_text=$d.size_text })
      $uprice = $null; $basis = 'IMPLAUSIBLE-LOW'   # drop from ranking; board still ships via runner-up
    }
    elseif (-not (Test-PackSize $c.id $d.size_text $d.name)) {
      # right contents, WRONG PACK FORM for a commodity that is defined by its form (see Test-PackSize).
      # Flagged rather than silently dropped, so a cap set too tight shows up as findings instead of as a
      # quietly emptier board.
      $flagged.Add([pscustomobject]@{ id=$c.id; label=$c.label; store=$d.store; name=$d.name; unit=$c.unit; unit_price=$uprice; band=("max_pack_oz<=$($MAXPACK[[string]$c.id])"); price_text=$d.price_text; size_text=$d.size_text })
      $uprice = $null; $basis = 'WRONG-PACK-FORM'   # drop from ranking; board still ships via runner-up
    }
  }
  # SAFETY NET: a recognized multibuy that came back UNPRICED means the capture is incomplete
  # (this is exactly how the Baker's chicken-thighs Buy-1-Get-2 was lost). Surface it loudly.
  if ((-not $up) -and (Test-IsMultibuy $d.price_text)) {
    $why = if (-not $d.regular -or ("" + $d.regular) -eq '') { 'missing regular price - a Buy-N-Get-K needs the "regular retail" number to price' }
           else { 'has regular but no unit basis - add the pack size (e.g. "12 pk 12 fl oz"), or "lb" for a per-pound item' }
    $mbUnpriced.Add([pscustomobject]@{ id=$c.id; label=$c.label; store=$d.store; name=$d.name; price_text=$d.price_text; regular=$d.regular; size_text=$d.size_text; reason=$why })
  }
  # PER-CELL membership (not whole-store): a Hy-Vee row whose price is the PERKS member price is membership-gated
  # just like a Sam's Club cell, so it is excluded from the "cheapest without membership" column. Hy-Vee's regular
  # (non-Perks) prices stay no-membership. Label is Brad's exact wording.
  $perks = ([string]$d.price_text -match '(?i)perks\s*price')
  $memLabel = if ($perks) { 'Perks membership required' } elseif (Test-Membership $d.store) { 'membership' } else { '' }
  $matched.Add([pscustomobject]@{
    id=$c.id; label=$c.label; unit=$c.unit; store=$d.store; name=$d.name; price_type=$d.price_type;
    price_text=$d.price_text; size_text=$d.size_text; regular=$d.regular; bulk=(Test-Bulk $d.size_text $d.name); membership=((Test-Membership $d.store) -or $perks); member_label=$memLabel;
    # Carry the SOURCE through to the page. Without it build-deals-page cannot tell an ad-backed sale from a
    # one-off price snapshot, so it stamped every sale chip with the store's ad-cycle end date - dressing an
    # undated Aisles Online markdown up as "Sale thru Jul 19". A date we invented is worse than no date.
    source_ad=$d.source_ad; src_date=$d.src_date; ad_from=$d.ad_from; ad_to=$d.ad_to; ad_basis=$d.ad_basis;
    unit_price=$uprice; basis=$basis; note=$note })
}

# candidates audit file (includes matched-but-UNPRICED deals so the semantic pass can recover / reject them)
$candList = New-Object System.Collections.Generic.List[object]
foreach ($g in ($matched | Group-Object id)) {
  $f = $g.Group[0]
  # price_type added 2026-07-23 so derive-recipe-floors.ps1 can tell an EVERYDAY candidate from a sale -
  # the everyday floor per store is the cheapest everyday-typed candidate, which the comparison row hides
  # whenever a sale is winning that store.
  # src_date added 2026-08-06. The candidates artifact used to drop the ONE field the per-store ranking
  # actually turns on (Select-FreshestCaptureRows filters on src_date), so every auditor reading this file
  # was structurally blind to a freshness EVICTION: a row visible here, cheaper than the board cell, with
  # no way to tell whether it lost on price or was filtered out before price was ever compared. That is how
  # Sam's baby-formula shipped at $1.4445/oz on 2026-08-06 with a real $0.7704/oz row sitting in this file.
  # audit-capture-eviction.ps1 reads it. An artifact that omits the deciding field cannot be audited.
  $candList.Add([pscustomobject]@{ id=$g.Name; label=$f.label; unit=$f.unit; candidates=@($g.Group | Select-Object store,name,price_text,size_text,regular,unit_price,basis,price_type,src_date) })
}
$candPfx = if ($OutName -eq 'comparison') { 'candidates' } else { "$OutName-candidates" }
(@{ week_of=$today; commodities=$candList } | ConvertTo-Json -Depth 8) | Set-Content (Join-Path $OutDir ("$candPfx-"+$today+".json")) -Encoding UTF8

# ---------------------------------------------------------------- adjudicated-wrong cells, dropped HERE
# known-wrong.json used to be read only by audit-known-wrong.ps1 and guards.ps1, and both of those run
# AFTER the board is built. A ruling could therefore block a publish but never correct a board: the wrong
# cell stayed, the gate went red, and every publish stopped until a human hand-edited a commodity rule.
# That made twenty-two accuracy findings into tripwires instead of fixes. Dropping the row here lets the
# store fall through to its own next-best REAL row, which is what the shopper should have been seeing.
# The matching lives in known-wrong-lib.ps1 and is shared with the audit, so the two can never disagree
# about what a ruling covers.
. (Join-Path $PSScriptRoot 'known-wrong-lib.ps1')
$KW_BLOCKS = Get-KnownWrongBlocks -Path (Join-Path $PSScriptRoot 'known-wrong.json')
$kwDropped = 0
if ($KW_BLOCKS.Count) {
  $kept = New-Object System.Collections.Generic.List[object]
  foreach ($m in $matched) {
    if ($m.unit_price -ne $null -and (Test-KnownWrong -Blocks $KW_BLOCKS -CommodityId ([string]$m.id) -Store ([string]$m.store) -ProductName ([string]$m.name))) {
      $kwDropped++
      Write-Output ("  known-wrong: dropped [{0}] {1} '{2}' (unit_price {3}) - already adjudicated wrong; the store falls through to its next-best row" -f $m.store, $m.id, $m.name, $m.unit_price)
      continue
    }
    [void]$kept.Add($m)
  }
  $matched = $kept
}
Write-Output ("known-wrong: $($KW_BLOCKS.Count) active blocked cell(s) in the ruling file, $kwDropped priced row(s) dropped from this board")

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
    $rows = Select-FreshestCaptureRows $_.Group
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
    # ad_from / ad_to ON THE CELL (2026-08-21). This is the field build-sale-windows needs in order to
    # date a sale from the deal that actually won the cell instead of from the store's one ad cycle.
    # Emitted for every cell; empty on an everyday cell, which is correct - an everyday price has no
    # window and must never be given one.
    stores = @($ranked | ForEach-Object { [pscustomobject]@{ store=$_.store; per_unit=$_.unit_price; unit=$f.unit; type=$_.price_type; bulk=$_.bulk; membership=$_.membership; member_label=$_.member_label; item=$_.name; ad=$_.price_text; size=$_.size_text; basis=$_.basis; note=$_.note; source_ad=$_.source_ad; ad_from=$_.ad_from; ad_to=$_.ad_to; ad_basis=$_.ad_basis } })
  })
}
$report = @($report | Sort-Object commodity)

# ---------------------------------------------------------------- health + flagged (drive the automation alert)
$flagPfx = if ($OutName -eq 'comparison') { 'flagged' } else { "$OutName-flagged" }
(@{ week_of=$today; flagged_count=$flagged.Count; flagged=$flagged.ToArray(); multibuy_unpriced=$mbUnpriced.ToArray() } | ConvertTo-Json -Depth 6) | Set-Content (Join-Path $OutDir ("$flagPfx-"+$today+".json")) -Encoding UTF8
$storesWithData = @($matched | Where-Object { $_.unit_price -ne $null } | ForEach-Object { $_.store } | Select-Object -Unique | Sort-Object)
$health = [ordered]@{ stores_with_data=$storesWithData; store_count=$storesWithData.Count; commodities_compared=$report.Count; flagged_out_of_band=$flagged.Count; multibuy_unpriced=$mbUnpriced.Count; expired_sale_rows_dropped=$script:ExpiredSaleRows; sale_windows_inherited_from_ads=$script:AdInherited; sale_windows_from_ttl=$script:TtlDated; sale_windows_from_store_countdown=$script:StoreCountdown }

# ---------------------------------------------------------------- output
$out = [ordered]@{ built_at=(Get-Date).ToString('s'); week_of=$today; source=$AdsFile; commodities_compared=$report.Count; health=$health; comparison=$report }
$file = Join-Path $OutDir ($OutName + "-" + $today + ".json")
($out | ConvertTo-Json -Depth 8) | Set-Content $file -Encoding UTF8

# PERSIST THE TTL ANCHORS, or the whole mechanism is a no-op that looks like it works.
# Get-RollbackWindow records first_seen in memory; without this write it is discarded at process
# exit, every build re-anchors every markdown to ITS OWN run date, and a 30-day TTL silently becomes
# a rolling 30-days-from-now that never expires. That is precisely the failure rollback-ttl-lib's
# must-fire fixture exists to catch, reintroduced one layer up by simply not saving.
# Caught because the ledger file was absent after a build that dated 372 cells from it.
try { [void](Save-RollbackLedger $root) } catch { Write-Warning ('rollback ledger not saved (' + $_.Exception.Message + ') - TTL anchors will re-date on the next build') }

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

# ---------------------------------------------------------------- THE WIDE PRICE TABLE (2026-08-21)
# Brad's model: one row per ITEM, carrying every store's everyday price, ad price and ad window as
# columns, and pages show the cheaper of the two. When the ad's window closes the ad column nulls out
# and the everyday price returns BY ARITHMETIC - no re-capture needed. Under the 90-day carry that is
# the difference between a finished sale falling off by itself and one publishing for a quarter.
#
# BUILT HERE, NOT IN A SEPARATE PASS, and that is the load-bearing decision. Every price in the table
# is chosen from the SAME $priced rows by the SAME Select-FreshestCaptureRows the ranking above used.
# A standalone builder reading comparison-*.json could only ever see the ONE winning row per store,
# so it could not know the everyday price behind a sale cell - and a builder re-reading the candidate
# pool would be a second implementation of "which row wins", which is precisely how a table and the
# board it describes drift while both look correct.
# The parity check below then proves, per cell, that they still agree.
. (Join-Path $PSScriptRoot 'price-table-lib.ps1')
$ptRows = New-Object System.Collections.Generic.List[object]
foreach ($g in ($matched | Where-Object { $_.unit_price -ne $null } | Group-Object id)) {
  $f0 = $g.Group[0]
  [void]$ptRows.Add((Build-PriceTableRow -Id $g.Name -Commodity ([string]$f0.label) -Unit ([string]$f0.unit) -Rows $g.Group -Today $today))
}
$ptTable = @($ptRows | Sort-Object id)
$ptStoreOrder = @('Hy-Vee', 'Aldi', 'Family Fare', 'Fareway', "Baker's", "Sam's Club", 'Walmart')
$ptDoc = [ordered]@{
  week_of = $today
  built_at = (Get-Date).ToString('s')
  note = 'WIDE price table, one row per item. Per store: everyday price, ad price, and the ad window. ad is NULL when the item is not on ad - Brad''s founding rule - and an ad whose ad_to has passed is nulled at build time rather than cleaned up later. `shown` is the cheaper of the two, which is what a page must display. Derived from the same candidate rows and the same eligibility rule the board ranks with; price-table-parity proves they agree per cell.'
  stores = $ptStoreOrder
  rows = $ptTable.Count
  items = $ptTable
}
$ptFile = Join-Path $OutDir (($(if ($OutName -eq 'comparison') { 'price-table' } else { "$OutName-price-table" })) + '-' + $today + '.json')
[IO.File]::WriteAllText($ptFile, ($ptDoc | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
# The CSV is a RENDERING of the JSON, regenerated every build, never authored - so the two cannot
# disagree about a price the way two hand-maintained files would.
$ptCsv = ConvertTo-PriceTableCsv -Table $ptTable -StoreOrder $ptStoreOrder
$ptCsvFile = [IO.Path]::ChangeExtension($ptFile, 'csv')
[IO.File]::WriteAllText($ptCsvFile, $ptCsv, (New-Object System.Text.UTF8Encoding($false)))

$ptCells = 0; $ptWithAd = 0; $ptWithEv = 0; $ptBoth = 0
foreach ($r in $ptTable) {
  foreach ($k in $r.stores.Keys) {
    $ptCells++
    $c = $r.stores[$k]
    if ($null -ne $c.ad) { $ptWithAd++ }
    if ($null -ne $c.everyday) { $ptWithEv++ }
    if ($null -ne $c.ad -and $null -ne $c.everyday) { $ptBoth++ }
  }
}
Write-Output ("price-table: {0} item(s), {1} store cell(s) - {2} carry an everyday price, {3} carry a LIVE ad, {4} carry both" -f $ptTable.Count, $ptCells, $ptWithEv, $ptWithAd, $ptBoth)
# PARITY, EVERY BUILD, NOT ON A SCHEDULE. A table that disagrees with the board it describes is worse
# than no table, because it will be believed. This is cheap and it is the only thing standing between
# "derived from the same rows" and "actually still the same answer".
$ptBad = @(Test-PriceTableParity -Table $ptTable -Comparison ([pscustomobject]@{ comparison = $report }))
if ($ptBad.Count) {
  Write-Output ("!! PRICE-TABLE PARITY: {0} cell(s) disagree with the published board - the table and the ranker have drifted:" -f $ptBad.Count)
  foreach ($b in ($ptBad | Select-Object -First 12)) { Write-Output ("   [{0}] {1}: {2}" -f $b.id, $b.store, $b.why) }
} else {
  Write-Output ("price-table: parity OK - every one of the {0} cell(s) matches the price the board published" -f $ptCells)
}
Write-Output ("Saved: " + $ptFile)
Write-Output ("Saved: " + $ptCsvFile)

# ---------------------------------------------------------------- THE INPUT LEDGER (2026-08-21)
# -IsLiveBuild only when this run built the PUBLISHED board. A regression or fixture run reads a PINNED
# set of inputs, and stamping those would mark files the live board has not touched in weeks as alive -
# worse than no record, because it reads as evidence. $OutName is the honest test: every pinned harness
# passes its own name so its artifacts do not collide with the real ones.
$liveBuild = ($OutName -eq 'comparison') -and (-not $RegularDir) -and (-not $ExtraDir)
$iuCount = Save-InputUsage -Tracker $inputUsage -OutDir $OutDir -Today $today -IsLiveBuild:$liveBuild
if ($iuCount -ge 0) {
  Write-Output ("input-usage: recorded {0} file(s) this build -> {1}" -f $iuCount, (Join-Path $OutDir 'input-usage.json'))
} else {
  Write-Output "input-usage: NOT recorded (this is a pinned/regression run, not the live board)"
}
