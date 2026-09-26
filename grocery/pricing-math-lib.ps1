# pricing-math-lib.ps1 - the pricing functions, as a PROVIDED interface.
# ---------------------------------------------------------------------------------------------------
# WHY THIS FILE EXISTS (2026-09-09, backlog I82). `compare-deals.ps1` was a component with a required
# interface and no provided one, so twelve scripts jammed the socket onto its source file: they read
# the engine's TEXT with Get-Content, cut function bodies out of it with a regex, and re-executed them
# with Invoke-Expression, driven by a HAND-MAINTAINED list of names in each caller.
#
# THE REASON NOBODY JUST DOT-SOURCED IT is written in build-walmart-deals.ps1's own comment: "it runs a
# pipeline on load, so we can't dot-source it". That was true of the ENGINE and never true of these
# functions - they are pure over their arguments. Measured before the move: the eleven are CLOSED UNDER
# CALLING (none calls an engine function outside the set) and reference NO $script: or $global: state.
# So the whole obstacle was that they lived in the same file as a pipeline, and moving them out removes
# it. Nothing here changed a character of any function body.
#
# WHAT THIS BUYS, beyond tidiness. The lift had one failure mode that had already fired: add a function
# that Get-UnitPrice calls, forget to add it to a caller's hand-maintained list, and the lifted copy
# calls something that does not exist - at RUN time, as "not recognized as the name of a cmdlet". That
# class of bug cannot occur through a dot-source, because the file arrives whole.
#
# THE RULE THAT REPLACES THE OLD ONE: this file has NO side effects on load and must keep it that way.
# Adding a line here that runs work at import re-creates the exact obstacle that produced the lifting.
# ---------------------------------------------------------------------------------------------------
# USE WHEN: a builder, audit or test needs the board's size, price or unit-price math (Get-UnitPrice, Get-ItemPrice, Get-SizeAmount, Convert-ToUnit); dot-source this file, never cut functions out of compare-deals.ps1's source text
# REPLACES: (?im)^(?![ \t]*#)[^\r\n#]*\[regex\]::Match\([^\r\n#]*\^function\\s\+
# REPLACES-FIRE: $m = [regex]::Match($engineSrc, "(?ms)^function\s+$([regex]::Escape($fn))\s*\(.*?^\}")
# REPLACES-FIRE: $m = [regex]::Match($src, '(?ms)^function\s+' + [regex]::Escape($fn) + '\s*\(.*?^\}')
# REPLACES-SILENT: . (Join-Path $PSScriptRoot 'pricing-math-lib.ps1')
# REPLACES-SILENT: $u = Get-UnitPrice $deal $cat
# REPLACES-SILENT: $p = Get-ItemPrice $deal.price $deal.name $regular
# ENFORCED BY: none (none)

function Test-Bulk([string]$size, [string]$name) {
  $t = (("" + $size + " " + $name)).ToLower()
  if ($t -match '\bcase\b|\broll\b|\bvalue pack\b|family pack|bulk') { return $true }
  $m = [regex]::Match($t, '(\d+(?:\.\d+)?)\s*(lb|lbs|pound)')  ; if ($m.Success -and [double]$m.Groups[1].Value -ge 4)  { return $true }
  $m = [regex]::Match($t, '(\d+(?:\.\d+)?)\s*oz')             ; if ($m.Success -and [double]$m.Groups[1].Value -ge 32) { return $true }
  $m = [regex]::Match($t, '(\d+)\s*(ct|count|pk|pack|dozen)') ; if ($m.Success -and [double]$m.Groups[1].Value -ge 18) { return $true }
  return $false
}
function Get-TcEachCountTokens() {
  return 'ct|count|ea|each|pk|pack|pkg|package|bunch|bunches|head|loaf'
}
function Get-TcWholePurchaseTokens() {
  return 'ct|count|ea|each|bunch|bunches|head|loaf'
}
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
      if ($t -match ('^(' + (Get-TcEachCountTokens) + ')$')) { return $num }
      if ($t -match '^(dozen|doz)$') { return $num * 12.0 }
      return $null
    }
    'dozen' {
      if ($t -match '^(dozen|doz)$')          { return $num }
      if ($t -match '^(ct|count|ea|each)$')   { return $num / 12.0 }
      return $null
    }
    # AREA (2026-09-06, Brad's ruling). aluminum-foil is the catalog's only sq_ft commodity and had NO arm
    # here at all, so all 47 of its matched rows returned null and the commodity was absent from the board
    # entirely - indistinguishable, from outside, from a foil Omaha does not sell. unit-vocabulary-lib.ps1
    # measured exactly this on 2026-08-30 and deliberately changed nothing, pending the ruling.
    # WHY sq_ft AND NOT each: the rolls run 25 to 223 sq ft at $1.79 to $20.99, so a per-each cell ranks by
    # roll SIZE rather than value - Family Fare's $1.79 25 sq ft roll would beat its own $12.99 200 sq ft
    # roll, which is false by 22%.
    # NO CROSS-UNIT LEAKAGE, IN EITHER DIRECTION. A count is not an area: that is what keeps the "50 ct"
    # pre-cut pop-up SHEETS and the "6 ct" bucket liners unpriced instead of crowning them, and it is why no
    # weight or volume arm above learned an area token. 'square fee' is not a typo - Baker's truncates its
    # product names at 60 characters and its foil rows land mid-word.
    'sq_ft' {
      if ($t -match '^(sq\s*\.?\s*ft|sqft|sq\s*feet|square\s*fee|square\s*feet)$') { return $num }
      return $null
    }
  }
  return $null
}
function Get-SizeAmount([string]$sizeText, [string]$unit) {
  if (-not $sizeText) { return $null }
  $s = ($sizeText -replace "`n", ' ').ToLower()
  # bare unit token (e.g. size just "lb" or "each") => the ad is priced PER that unit => amount = 1 unit
  $st = $s.Trim().TrimEnd('.')
  if ($st -match ('^(lb|lbs|pound|pounds|#|oz|ounce|ounces|fl\s*oz|floz|dozen|doz|gal|gallon|qt|quart|pt|pint|liter|litre|l|ml|' + (Get-TcWholePurchaseTokens) + ')$')) {
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
  # rides as the \u00d7 regex escape, NEVER a literal. CORRECTED 2026-08-26: this file DOES carry a
  # UTF-8 BOM now, so PS 5.1 reads it as UTF-8 and a literal would in fact survive - but the escape
  # stays, because that BOM is the only thing holding the guarantee up and nothing tests for it. Strip
  # it and PS 5.1 falls back to ANSI, and every non-ASCII literal in this file silently decodes to a
  # pair that can never match. (The 2026-07-30 batch SHIPPED exactly that literal despite documenting
  # the trap - the branch was dead on arrival, caught by the post-batch review. The self-test carries a
  # real [char]0x00D7 case so it cannot go dead silently again, and as of 2026-08-26 a [char]0x00A2 twin
  # guards the cents branch, which had been carrying the MOJIBAKE pair as a deliberate worked example
  # and so could price only CORRUPTED input - see the cents branch in Get-ItemPrice.)
  # THE x/times BRANCH REQUIRES THE EACH-NUMBER IMMEDIATELY (whitespace/hyphen only, no \D+? gap): with the
  # lazy gap, concentration-marketing tokens parse as pack counts - 'Fabuloso ... 2X Concentrated Formula,
  # ..., 33.8 fl oz' read count=2, each=33.8 and HALVED the per-unit (4 live names measured, all currently
  # masked by their parsable size_text; Hy-Vee ad rows are name-parsed and would have published it). The
  # word tokens (ct/pk/...) keep the lazy gap for '6 pk of 12 oz' forms - a marketing word cannot follow
  # them, only 'x' has that ambiguity.
  # A TRAILING PARENTHESISED TOTAL, WHEN THE ARITHMETIC PROVES IT IS ONE (2026-08-28).
  # "16 oz x 2 pk (32 oz)" - the shape the Recipe Hunter's pricing agent records for a club multipack -
  # reached the pack-first branch below and matched on "2 pk (32 oz)", because that branch's \D+? gap
  # happily crosses an opening bracket. It then read TWO PACKS OF 32 oz and returned 64 oz: the pack
  # count applied twice, against a size string that had already stated the total. Live effect measured
  # 2026-08-28: shaved-beef-steak|Sam's Club published at $4.3675/lb against a true $8.735/lb, which
  # also handed Sam's the "Cheapest" badge on a row Aldi actually wins, and drove the recipe card for
  # philly-cheesesteak-stuffed-peppers to a $18.28 cheapest-per-serving against a $4.37 everyday.
  #
  # THE ARITHMETIC DECIDES, NOT THE BRACKET - the rule multipack-lib already applies to this same
  # question. "6 pk (12 fl oz)" is SIX BOTTLES of 12 fl oz and its parenthetical is a per-item size, so
  # a blanket "trailing bracket wins" would break it in the opposite direction. The parenthetical is
  # taken as the total ONLY when the string states a per-item weight W and a count N elsewhere and
  # N x W reproduces it (16 x 2 = 32). That is the store telling us the sum itself; anything else
  # falls through to the branches below unchanged.
  # 3% matches Test-MpSizeIsPackTotal's tolerance, for the stores' own rounding of a pack total.
  # add-recipe-board-rows.ps1's Resolve-Size and pu-lib both already read this string as 32 oz; this is
  # the third copy of the rule catching up, and the parity case in the self-test holds them together.
  $pt = [regex]::Match($s, '\(\s*(\d+(?:\.\d+)?|\.\d+)\s*(fl\s*oz|floz|oz|ounce|ounces|lb|lbs|pound|pounds|gal|gallon|qt|quart|pt|pint|liter|litre|ltr|ml)\s*\)')
  if ($pt.Success) {
    $ptv = [double]$pt.Groups[1].Value; $pttok = $pt.Groups[2].Value
    $lead = $s.Substring(0, $pt.Index)
    $counts = @(); foreach ($cm in [regex]::Matches($lead, '(\d+)\s*[- ]?\s*(?:pk\b|packs?\b|ct\b|count\b|x|\u00d7)')) { $cv = [double]$cm.Groups[1].Value; if ($cv -gt 1) { $counts += $cv } }
    $proved = $false
    foreach ($wm in [regex]::Matches($lead, '(\d+(?:\.\d+)?|\.\d+)\s*(fl\s*oz|floz|oz|ounce|ounces|lb|lbs|pound|pounds|gal|gallon|qt|quart|pt|pint|liter|litre|ltr|ml)\b')) {
      $wv = Convert-ToUnit ([double]$wm.Groups[1].Value) $wm.Groups[2].Value $pttok
      if ($wv -eq $null -or $wv -le 0) { continue }
      foreach ($c in $counts) { if ($ptv -gt 0 -and ([math]::Abs(($wv * $c) - $ptv) / $ptv) -le 0.03) { $proved = $true; break } }
      if ($proved) { break }
    }
    if ($proved) {
      $ptc = Convert-ToUnit $ptv $pttok $unit
      if ($ptc -ne $null) { return $ptc }
    }
  }
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
    # THE LEAST FAVOURABLE READING (2026-09-22, plan-2026-09-22-5, on the coordinator's order after the laundry crown).
    # The comment above was the rule until today: the larger size, as "the honest achievable price". It was not: the
    # price names BOTH sizes and the board cannot know which one the store has on the shelf, so the larger reading
    # promises the reader the best per-unit the line could possibly mean. "Xtra laundry detergent, 56 or 67.5 oz.,
    # 3/ $10.00" took the laundry-detergent crown at 0.0494/fl oz on the larger size; at 56 oz it is 0.0595. A board
    # that must be right in the direction that costs the reader reads the SMALLER size, so the per-unit is the most a
    # shopper pays. Whether the two sizes are different PRODUCTS is not decidable from the line and is not attempted.
    $lo = [double]$rng.Groups[1].Value; $tok = $rng.Groups[3].Value
    $rc = Convert-ToUnit $lo $tok $unit; if ($rc -ne $null) { return $rc }
  }
  # first "<number> <unit-token>" occurrence
  # The AREA tokens lead the alternation, longest form first, so "200 square feet" cannot be clipped to the
  # 60-char-truncation spelling "square fee" and "sq. ft." cannot be read as a bare "ft".
  $m = [regex]::Match($s, '(\d+(?:\.\d+)?|\.\d+)\s*(square\s*feet|square\s*fee|sq\s*feet|sq\s*\.?\s*ft|sqft|fl\s*oz|floz|oz|ounce|ounces|lb|lbs|pound|pounds|#|gal|gallon|qt|quart|pt|pint|liters|litres|liter|litre|ltr|\bl\b|ml|g|gram|grams|dozen|doz|ct|count|ea|each|pk|pack|pkg|bunch|head|loaf)\b')
  if ($m.Success) {
    $num = [double]$m.Groups[1].Value; $tok = $m.Groups[2].Value
    $conv = Convert-ToUnit $num $tok $unit
    # WEIGHT-FIRST multipack ("16 oz 6 pk", or "1.51 oz., 40 pk." via the name fallback): a pack count
    # elsewhere in the string multiplies a WEIGHT/VOLUME size. pu-lib step 4 has always done this; the engine
    # did not, so Bush's "16 oz 6 pk" priced as ONE can ($0.3988/oz, band-flagged) and Sam's grits PUBLISHED
    # at $0.1049/oz off a ".98 oz., 46 pk." name (the leading-dot group above reads 0.98, not 98). Guarded to
    # weight units + weight tokens so "12 pk" on an each/dozen commodity is never multiplied twice.
    # LITRE / ML / QUART JOINED THE TOKEN LIST 2026-08-22: "2 l 6 pk" (a soda six-pack of 2-litre bottles)
    # was multiplied for oz/lb/gal only, so it priced as ONE bottle - 6x over. pu-lib step 4 carries the same
    # addition; the parity test holds the two copies of this rule together.
    if ($conv -ne $null -and ($unit -eq 'oz' -or $unit -eq 'floz' -or $unit -eq 'lb' -or $unit -eq 'gallon') -and $tok -match '^(fl\s*oz|floz|oz|ounce|ounces|lb|lbs|pound|pounds|gal|gallon|qt|quart|liters|litres|liter|litre|ltr|l|ml)$') {
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
# THE VOLUME A NAME STATES, IN FLUID OUNCES (2026-09-10, queue 2026-09-10-d9e085).
# Sam's prices a gallon jug of ranch dressing "$0.09/oz", and build-sams-deals derives the pack size as
# linePrice / unitPrice because the name's "1 gal." is not in the ounce family Sam's priced by. So the
# capture's size '122 oz' is 10.98 / 0.09, a PRICE QUOTIENT carrying the cent rounding of Sam's unit price
# (+/- 0.005 / 0.09 = 5.6%), and the previous capture of the same jug derived '135.25 oz' from $10.82 / $0.08.
# The name is the only party stating the quantity, and it says one gallon. Get-UnitPrice asks this function
# only for a fl-oz commodity whose size field is a bare 'oz' label; see the branch there for the bar.
#
# RETURNS $null UNLESS THE NAME STATES EXACTLY ONE VOLUME. Zero is nothing to say; two is an either/or or a
# multi-size name, which is the biased coin flip Test-NameOffersTwoSizes exists to refuse.
# READS FRACTIONS AND LEADING-DOT DECIMALS WHOLE. A bare '\d+' scan reads ".5 Gal." as FIVE gallons (10x) and
# "1/2 Gal" as TWO (4x); the lookbehind stops a match starting inside either, and the fraction is honoured only
# when it is a real one (numerator smaller than denominator), the same test Get-SizeAmount applies.
# LITRE SPELLINGS ARE MAPPED HERE rather than through Convert-ToUnit, whose floz arm has no 'litre'.
function Get-NameVolumeFloz([string]$name) {
  if (-not $name) { return $null }
  $t = ('' + $name).ToLower()
  $vm = [regex]::Matches($t, '(?<![\d./])(\d+\s*/\s*\d+|\d+(?:\.\d+)?|\.\d+)\s*-?\s*(gallons?|gal|quarts?|qt|pints?|pt|liters?|litres?|ltr|l)\b')
  if ($vm.Count -ne 1) { return $null }
  $q = ($vm[0].Groups[1].Value -replace '\s', '')
  $n = 0.0
  $fm = [regex]::Match($q, '^(\d+)/(\d+)$')
  if ($fm.Success) {
    $fa = [double]$fm.Groups[1].Value; $fb = [double]$fm.Groups[2].Value
    if ($fb -le 0 -or $fa -ge $fb) { return $null }
    $n = $fa / $fb
  } elseif (-not [double]::TryParse($q, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$n)) {
    return $null
  }
  if ($n -le 0) { return $null }
  $tok = $vm[0].Groups[2].Value
  if ($tok -match '^gal')             { return ($n * 128.0) }
  if ($tok -match '^(qt|quart)')      { return ($n * 32.0) }
  if ($tok -match '^(pt|pint)')       { return ($n * 16.0) }
  return ($n * 33.814)
}
# WHICH SIZE A PRICED ROW CARRIES ONTO THE BOARD CELL (2026-09-10, queue 2026-09-10-d9e085). Pure, so
# compare-deals -SelfTest reaches the exact emission the engine runs at its matched-row add. The store's
# size_text stays the answer unless Get-UnitPrice priced the row from a different quantity and said so in
# size_override - otherwise audit-unit-basis-outlier reads the KIND off a label the arithmetic never used
# ('122 oz', a weight, on a cell divided by 128 fl oz).
function Resolve-CellSizeText([string]$sizeText, $priced) {
  if (($priced -is [hashtable]) -and $priced.ContainsKey('size_override') -and $priced['size_override']) { return [string]$priced['size_override'] }
  return $sizeText
}
function ConvertTo-DigitNumerals([string]$t) {
  if (-not $t) { return $t }
  return ($t -replace '(?i)\bone\b','1' -replace '(?i)\btwo\b','2' -replace '(?i)\bthree\b','3' -replace '(?i)\bfour\b','4' -replace '(?i)\bfive\b','5' -replace '(?i)\bsix\b','6' -replace '(?i)\bseven\b','7' -replace '(?i)\beight\b','8' -replace '(?i)\bnine\b','9' -replace '(?i)\bten\b','10')
}
function Get-ItemPrice([string]$priceText, [string]$nameText, $regular) {
  $p = ConvertTo-DigitNumerals ((("" + $priceText + " " + $nameText) -replace "`n", ' '))
  # A FUEL-SAVER REWARD IS NOT A PRICE (2026-09-07, queue 2026-09-07-05e4c3). Hy-Vee's weekly ad hangs a
  # loyalty clause off the front of an item line - "Gain Flings, EARN 10<cent> OFF PER GALLON, -3.00 off with
  # manufacturer's digital coupon, $12.94" - and the cents branch below reads the FIRST cents-shaped token
  # anywhere in the line. So the engine published Gain Flings at $0.10 a pod, and it held the laundry-pods
  # CROWN from 2026-08-31 to 2026-09-06 with every guard green, because guard 10 verifies rows against their
  # own current_price and a Hy-Vee ad row does not carry one. Two more sat on the same live board (diapers
  # $0.25, dryer-sheets $0.05) and two more on the next build (disinfecting-wipes $0.10, facial-tissues
  # $0.03). Strip the clause before ANY extraction, so the cents branch, the N-for-$M branch and the
  # last-dollar branch all read the line the ad actually prices.
  # ANCHORED ON "OFF PER GALLON", not on the cents sign: "Bananas, 49<cent> lb." is a real cents price and
  # must keep working. The FUEL SAVE(R|D) prefix is OPTIONAL because the founding row does not carry it -
  # five of the six live rows say FUEL SAVER and the crown-holder just says EARN.
  # The trailing eat is `\s*,?` and NOT `[^,]*,?`: a line whose price follows the clause with no comma
  # ("... OFF PER GALLON $2.29") would lose its own price to a greedy run-to-the-next-comma.
  # THE GLYPH RIDES AS \u00XX ESCAPES, NEVER A LITERAL - the same rule the cents branch below states, and
  # for the same reason: a literal cent sign in this source has been re-encoded by an editor before now.
  # The leading U+00C2 stays optional so a mojibaked capture still inside the carry window is stripped too.
  $p = [regex]::Replace($p, '(?i)(?:\bFUEL\s+SAVE[RD]?\b[,\s]*)?(?:\bEARN\s+)?\d+\s*(?:\u00C2?\u00A2|cents?)\s*OFF\s+PER\s+GALLON\s*,?', ' ')
  # A SAVINGS CLAUSE IS NOT A PRICE EITHER (2026-09-18, queue 2026-09-18-f90ba6, triage-plans\plan-2026-09-18.json).
  # The fuel-saver strip above taught the parser ONE savings shape. Hy-Vee's 09-14 ad carried the next two:
  #     "Hy-Vee mini donuts, SAVE 50<cent>, $1.99"      -> published at $0.50 a donut
  #     "Quaker protein bars, SAVE 50<cent>, $3.98"     -> published at $0.50 a bar
  # and guards held the whole board from 09-14 to 09-18 on them (guard 8d, ad-line price provenance). The
  # coupon shape "- 50<cent> off with digital coupon, $1.99" is the same class and was on disk too. Strip both
  # before ANY extraction, exactly as the fuel clause is stripped, so every branch below reads the line the ad
  # actually prices. Same glyph rule as above: \u00XX escapes, never a literal, and U+00C2 optional.
  $p = [regex]::Replace($p, '(?i)\bSAVE!?\s*\.?\d+\s*(?:\u00C2?\u00A2|cents?)\s*,?', ' ')
  $p = [regex]::Replace($p, '(?i)-?\s*\d+\s*(?:\u00C2?\u00A2|cents?)\s+off\s+with\s+(?:manufacturer.s\s+)?digital\s+coupon\s*,?', ' ')
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
  # cents: "88" with cent sign or explicit cents.
  # THE GLYPH RIDES AS \u00XX ESCAPES, NEVER A LITERAL - same rule as the times sign above. Until
  # 2026-08-26 this alternative was the literal PAIR U+00C2 U+00A2, i.e. the MOJIBAKE, because the
  # capture sink decoded every POST body as cp1252 and a real cent sign never reached here. The sink
  # now decodes UTF-8, so a clean U+00A2 is what arrives - and the old pattern could not match it,
  # returning no price at all rather than a wrong one. The leading U+00C2 stays OPTIONAL so captures
  # still inside the carry window, written before that fix, keep pricing.
  # AND A SECOND LINE OF DEFENCE ON THE SAME CLAUSE (2026-09-07, 05e4c3). The strip at the top of this
  # function removes the shapes Hy-Vee writes today; the lookahead refuses the READING regardless of how the
  # clause is worded around it, so a fuel-saver line the strip has not learned yet goes UNPRICED instead of
  # publishing a reward as a price. Understating is wrong, but a $0.10 laundry pod is wrong AND believable.
  # AND THE STRUCTURAL RULE UNDER BOTH STRIPS (2026-09-18, f90ba6): A CENTS TOKEN IS NEVER THE PRICE WHEN THE
  # LINE ALSO CARRIES A DOLLAR AMOUNT. Each strip above knows one wording, and the parser has been taught the
  # savings shapes one incident at a time (PERKS, then FUEL SAVER on 09-07, then SAVE 50c today). Measured by
  # the reviewer over every ads-*.json on disk: 145 distinct lines carry a cents token AND a $ token, and in all
  # 145 the cents token is a reward or a savings, never the price (139 fuel-saver, 4 SAVE-cents, 2 coupon);
  # the 60 cents-only lines carry no $ at all. So a line with a $ amount skips this branch and falls through to
  # the last-dollar read below, and a wording no strip has learned yet prices off its dollar instead of its
  # savings. "Bananas, 49<cent> lb." and a bare "88<cent>" carry no $ and keep pricing here.
  $m = [regex]::Match($p, '(\d+)\s*(?:\u00C2?\u00A2|cents?)(?!\s*OFF\s*PER\s*GALLON)')
  if ($m.Success -and ($p -notmatch '\$\s*\d')) { return @{ per_item = ([double]$m.Groups[1].Value)/100.0; kind=@{perlb=$perlb;pereach=$pereach}; note='cents' } }
  # plain dollar amount (take the LAST one, which is usually the sale/ad price)
  $dm = [regex]::Matches($p, '\$\s*([\d]+(?:\.\d{1,2})?)')
  if ($dm.Count -gt 0) {
    $val=[double]$dm[$dm.Count-1].Groups[1].Value
    return @{ per_item = $val; kind=@{perlb=$perlb;pereach=$pereach}; note='' }
  }
  return $null
}
function Test-NameOffersTwoSizes([string]$name) {
  if (-not $name) { return $false }
  $t = ("" + $name).ToLower()
  if ($t -notmatch '\bor\b') { return $false }
  $parts = @([regex]::Split($t, '\bor\b'))
  if ($parts.Count -lt 2) { return $false }
  $sizeRx = '(\d+(?:\.\d+)?)\s*(fl\s?oz|floz|oz|ounces?|lbs?|pounds?|gal|gallons?|qt|quarts?|pt|pints?|liters?|litres?|ml|ct|count|pk|packs?|ea|each)\b'
  # "EACH" IS A SIZE, AND IT IS THE ONE THIS FUNCTION KEPT MISSING (2026-08-31, queue 2026-08-31-8018b5).
  # Every unit above needs a NUMBER in front of it, so a side that says plainly "cauliflower each" stated no
  # size at all and the either/or could never be seen. The live row:
  #     Hy-Vee  "Bud by Dole romaine hearts 3 ct. pkg. or cauliflower each, $3.48"
  # $3.48 buys EITHER a 3-count romaine pack OR one cauliflower. The name fallback read "3 ct", divided,
  # and published the cheapest cauliflower in Omaha at $1.16 against a real $3.48 - and it took the CROWN,
  # which is exactly the biased direction the note above predicts, because dividing by the other side's
  # pack count is always the reading that looks cheapest.
  # A bare 'each'/'ea' means a quantity of ONE, so it is recorded as 1 in BOTH counting families (a single
  # unit is 1 ct and 1 pk) - otherwise "3 pk or ... each" would still slip through on a family mismatch.
  # It only ever speaks when the OTHER side states a count too, so a lone "sold each" stays priceable.
  $eachRx = '(?<![\d.])\b(?:ea|each)\b'
  # per side: unit family -> the set of numbers stated in it
  $sides = @()
  foreach ($p in $parts) {
    $byUnit = @{}
    foreach ($m in [regex]::Matches($p, $sizeRx)) {
      $u = $m.Groups[2].Value -replace '\s+', ''
      $u = $u -replace '^(ounces?)$', 'oz' -replace '^(fl\s?oz)$', 'floz' -replace '^(lbs?|pounds?)$', 'lb' `
              -replace '^(gallons?|gal)$', 'gal' -replace '^(quarts?|qt)$', 'qt' -replace '^(pints?|pt)$', 'pt' `
              -replace '^(liters?|litres?)$', 'l' -replace '^(count|ct)$', 'ct' -replace '^(packs?|pk)$', 'pk' `
              -replace '^(ea|each)$', 'ct'
      if (-not $byUnit.ContainsKey($u)) { $byUnit[$u] = New-Object 'System.Collections.Generic.List[string]' }
      [void]$byUnit[$u].Add($m.Groups[1].Value)
    }
    # a BARE 'each' (no number in front) is a count of one - see the note above. Recorded in both counting
    # families so it can meet a 'ct' or a 'pk' on the other side; a numbered "12 ea" was already taken by
    # $sizeRx above and normalises to ct, so this only fires for the plain word.
    if ($p -match $eachRx) {
      foreach ($cf in @('ct', 'pk')) {
        if (-not $byUnit.ContainsKey($cf)) { $byUnit[$cf] = New-Object 'System.Collections.Generic.List[string]' }
        if (-not ($byUnit[$cf] -contains '1')) { [void]$byUnit[$cf].Add('1') }
      }
    }
    $sides += ,$byUnit
  }
  # a genuine either/or: some unit family appears on two different sides with DIFFERENT numbers
  for ($i = 0; $i -lt $sides.Count; $i++) {
    for ($j = $i + 1; $j -lt $sides.Count; $j++) {
      foreach ($u in @($sides[$i].Keys)) {
        if (-not $sides[$j].ContainsKey($u)) { continue }
        $a = (@($sides[$i][$u] | Sort-Object -Unique) -join '|')
        $b = (@($sides[$j][$u] | Sort-Object -Unique) -join '|')
        if ($a -ne $b) { return $true }
      }
    }
  }
  return $false
}
# ---------------------------------------------------------------------------------------------------
# TWO PRODUCTS, ONE FLYER LINE (2026-09-11, queue 2026-09-10-582032).
# Every weekly-ad supplement row is ONE product by construction: the Baker's transcription writes one item
# and one size per flyer line, and compare-deals normalises whatever it is handed as one name with one size.
# A Kroger flyer line that sells two DIFFERENT products at one price therefore routes by whichever product's
# words first-match-wins over commodities.json and divides by whichever size the transcriber happened to
# write, so the basis is right only when both belong to the same product. Measured on
# bakers-deals-2026-09-09 (146 rows, 70 carrying ' or '): 45 lines carry the two-product shape, and four of
# them priced a wrong basis on the live ad - three too dear, one too cheap. The founding case:
#     "Simply Orange Juice, 46 fl oz or Post Large Size Cereal, 13.5-20.5 oz"  $4.49  size "46 fl oz"
# routed to CEREAL and divided by the ORANGE JUICE's 46 fl oz -> $0.0976/oz against an honest $0.219, and
# it took the crown. The direction is whichever product the transcriber sized, so the too-cheap case lands
# on a crown again as soon as the next flyer puts the size on the other product.
#
# THE RULE IS STRICT ON PURPOSE, AND THE LOOSE ONE WAS MEASURED AND REJECTED. Splitting on any segment that
# carries a size ANYWHERE also fired on 39 Hy-Vee lines of the shape "A size, B size, $price" (where 'or'
# also joins varieties and size options), produced parts like "cans 12 fl. oz., $9.99", and would have
# created a WRONG-PRODUCT coffee crown out of "ice coffee 50.7 oz., 3/ $10.00" (coffee | Hy-Vee 0.3857 ->
# 0.0657, taking the crown off Aldi at 0.3825). So a line is split ONLY when EVERY ' or '-separated segment
# ends in its own size expression; anything else is left whole, and Get-UnitPrice refuses to price a whole
# line that states two sizes rather than picking one of them at random.
#
# A SEGMENT WITH NO SIZE IS A VARIETY ALTERNATION, not a second product: "Simply Fruit Drink or Ade, 52 fl
# oz" is one product sold in two flavours at one size, so it is glued to the following segment and the
# 'or' stays inside the part. Returns ONE element (the name unchanged) whenever the line must not be split,
# so the caller has a single code path.
$script:TcAdSizeTailRx = '(?i)\d[\d.\-]*\s*-?\s*(?:fl\.?\s*oz|oz|ct|lbs?|pk|pack|mega\s+rolls?|double\s+rolls?|rolls?|ml|liters?|litres?|\bl\b|gal|qt|pt|count|ea)\b\.?(?:\s+(?:bag|bottles?|cans?|jar|box|pkg|package|carton))?\.?$'
# A whole-line qualifier, not part of either product's name. Stripped before the size test, because
# "..., 4.8-8 oz, Select Varieties" ends in prose and would refuse a line that is otherwise clean.
$script:TcAdLineQualifierRx = '(?i)\s*,\s*(?:in\s+the\s+bakery|select\s+varieties)\s*\.?\s*$'
function Split-TwoProductAdLine([string]$name) {
  if (-not $name) { return ,@() }
  $whole = "" + $name
  if ($whole -notmatch '(?i)\s+or\s+') { return ,@($whole) }
  $stripped = ([regex]::Replace($whole, $script:TcAdLineQualifierRx, '')).Trim()
  $segs = @([regex]::Split($stripped, '(?i)\s+or\s+'))
  if ($segs.Count -lt 2) { return ,@($whole) }
  # glue every size-less segment onto the one that FOLLOWS it, keeping the 'or' it was joined by
  $parts = New-Object System.Collections.Generic.List[string]
  $pending = ''
  foreach ($s in $segs) {
    $seg = ("" + $s).Trim()
    if (-not $seg) { return ,@($whole) }
    $cur = if ($pending) { $pending + ' or ' + $seg } else { $seg }
    if ([regex]::IsMatch($cur, $script:TcAdSizeTailRx)) { [void]$parts.Add($cur); $pending = '' }
    else { $pending = $cur }
  }
  # a trailing segment that never found a size means the LAST product states none: leave the line whole
  if ($pending) { return ,@($whole) }
  if ($parts.Count -lt 2) { return ,@($whole) }
  return ,@($parts.ToArray())
}
# ONE ROW PER NAMED PRODUCT (Brad's ruling Q-adline-two-products, 2026-09-22: "Split per product"). An ad line that
# offers two or more PRODUCTS at one price with ONE size ("Old Orchard Organic 100% apple or grape juice, 64 fl.
# oz., 2/ $7.00", "Alexia fries, tots or onion rings, 13.5 to 28 oz.", "Hy-Vee party cheese or cheese dip") used
# to reach matching whole, and first-match-wins handed it to whichever commodity came first. The ad price is real
# for EACH product named, so each becomes its own row, sharing the line's size and price text. Different SIZES of
# one product ('56 or 67.5 oz', '3 or 4 ct') are one product and never split here (batch 2 prices the smaller).
# STRICT, like Split-TwoProductAdLine: the product list is the comma items BEFORE the first item that starts with
# a digit, '$' or '.', and it is split only when the LAST of those items holds a word-level ' or ' and NO item of
# the list holds a digit (a size inside the list is the "A size, B size" shape the loose rule turned into a
# wrong coffee crown; that line stays whole). Naming, for the last item's 'L or R':
#   R opens with a capital (a second brand: 'Lean Cuisine or Stouffer''s entree') -> L (+ R's noun when L is short), and R
#   R starts with L's last word ('party cheese or cheese dip')  -> distinct products: L, and L's brand + R
#   R is one word ('wieners or sausage', 'Raspberries or Blackberries') -> shared lead: L, and L less its last word + R
#   otherwise ('apple or grape juice')                           -> shared head: L + R's last word, and L less its last word + R
# Earlier comma items are products of their own, prefixed with the first item's brand word when the later items
# start lower-case ('Alexia fries, tots or onion rings'). Returns ONE element (the name unchanged) otherwise.
function Split-AdLineProducts([string]$name) {
  if (-not $name) { return ,@() }
  $whole = "" + $name
  if (-not [regex]::IsMatch($whole, '(?i)(?<![\d.])\b[a-z][a-z''.]*\s+or\s+(?!\d)[a-z]')) { return ,@($whole) }
  $items = @($whole -split ',')
  $k = -1
  for ($i = 0; $i -lt $items.Count; $i++) { if ($items[$i].Trim() -match '^[\d$.]') { break }; $k = $i }
  if ($k -lt 0) { return ,@($whole) }
  $list = @($items[0..$k] | ForEach-Object { $_.Trim() })
  $tail = if ($k -lt $items.Count - 1) { (@($items[($k + 1)..($items.Count - 1)]) -join ',').Trim() } else { '' }
  # a SIZE inside the list (a digit and a unit) is the 'A size, B size' shape: whole. '100%' is not a size.
  foreach ($it in $list) { if (-not $it -or $it -match '(?i)\d[\d.\-]*\s*-?\s*(?:fl\.?\s*oz|oz|ct|lbs?|pk|pack|ml|liters?|gal|qt|pt|count|ea|g|kg)\b') { return ,@($whole) } }
  $last = $list[$list.Count - 1]
  $lr = @([regex]::Split($last, '(?i)\s+or\s+'))
  if ($lr.Count -ne 2 -or -not $lr[0].Trim() -or -not $lr[1].Trim()) { return ,@($whole) }
  $L = $lr[0].Trim(); $R = $lr[1].Trim()
  $lw = @($L -split '\s+'); $rw = @($R -split '\s+')
  $lLess = if ($lw.Count -gt 1) { ($lw[0..($lw.Count - 2)] -join ' ') } else { '' }
  $brand = (@($lw | Where-Object { $_ -cmatch '^[A-Z0-9]' }) | Select-Object -First 1)
  $names = New-Object System.Collections.Generic.List[string]
  if ($list.Count -gt 1) {
    # the BRAND prefix is the first item's leading capitalised words ('Nature Raised Farms chicken strips' ->
    # 'Nature Raised Farms'), lent to later items only when they start lower-case ('nuggets or bites')
    $pre = ''
    $firstWords = @($list[0] -split '\s+')
    $capRun = @(); foreach ($fw in $firstWords) { if ($fw -cmatch '^[A-Z0-9]') { $capRun += $fw } else { break } }
    if ($capRun.Count -gt 0 -and $capRun.Count -lt $firstWords.Count -and (@($list[1..($list.Count - 1)] | Where-Object { $_ -cmatch '^[A-Z]' }).Count -eq 0)) { $pre = ($capRun -join ' ') + ' ' }
    [void]$names.Add($list[0])
    for ($i = 1; $i -lt $list.Count - 1; $i++) { [void]$names.Add($pre + $list[$i]) }
    [void]$names.Add($pre + $L); [void]$names.Add($pre + $R)
  } elseif ($rw[0] -cmatch '^[A-Z]') {
    # R opens with a capital: a second BRAND or product name ('Cocoa Krispies or Raisin Bran cereal', 'Lean Cuisine or
    # Stouffer''s entree'). R stands alone; a short L (two words or fewer) takes R's last word as its product noun.
    # ...and only a LOWER-CASE last word is a product noun: 'Pepsi or Mountain Dew' must never make 'Pepsi Dew'
    # A SHORT L beside a multi-word R whose last word is CAPITALISED is undecidable from the words alone: in Aldi's
    # 'VitaLife Turmeric or Ginger Shot' that word is the shared noun L lacks, in 'Coke Zero or Mountain Dew' it is not.
    # Splitting emitted a bare 'VitaLife Turmeric' (a wellness shot) that took the Aldi ground-turmeric cell at
    # 0.845/oz on the 2026-09-23 rebuild. A line that cannot be named safely stays WHOLE, as it did before the ruling.
    if ($lw.Count -le 2 -and $rw.Count -gt 1 -and $rw[$rw.Count - 1] -cmatch '^[A-Z]') { return ,@($whole) }
    [void]$names.Add($(if ($lw.Count -le 2 -and $rw.Count -gt 1 -and $rw[$rw.Count - 1] -cmatch '^[a-z]') { $L + ' ' + $rw[$rw.Count - 1] } else { $L })); [void]$names.Add($R)
  } elseif ($rw[0] -ieq $lw[$lw.Count - 1]) {
    [void]$names.Add($L); [void]$names.Add($(if ($brand -and $lw.Count -gt 1) { $brand + ' ' + $R } else { $R }))
  } elseif ($rw.Count -eq 1) {
    [void]$names.Add($L); [void]$names.Add((($lLess + ' ' + $R).Trim()))
  } else {
    [void]$names.Add($L + ' ' + $rw[$rw.Count - 1]); [void]$names.Add((($lLess + ' ' + $R).Trim()))
  }
  # A ONE-WORD PART is a fragment ('lasagna', 'Barq''s', 'sausage'), not a product name matching can route on
  # safely: the line stays whole unless EVERY part is one word of a plain two-way alternation ('Raspberries or
  # Blackberries'). Measured on ads-2026-09-22: without this, 'Take Home, Rana meal kit or lasagna' emitted a bare
  # 'lasagna' row priced as a Rana meal kit.
  $oneWord = @($names | Where-Object { @($_.Trim() -split '\s+').Count -lt 2 }).Count
  if ($oneWord -gt 0 -and -not ($list.Count -eq 1 -and $oneWord -eq $names.Count)) { return ,@($whole) }
  $out = @($names | ForEach-Object { if ($tail) { $_ + ', ' + $tail } else { $_ } })
  if ($out.Count -lt 2) { return ,@($whole) }
  return ,$out
}
# The rows ONE ad line becomes, with each row's size: the two-product-with-sizes split first (each part keeps its
# own size), then the one-size product split (each part shares the line's size). One copy of the rule, used by
# both ingest loops in compare-deals and by its fixture. .split is true when the line became more than one row.
function Get-AdLineParts([string]$item, $fileSize) {
  $p1 = Split-TwoProductAdLine $item
  $p1 = @($p1)
  if ($p1.Count -gt 1) { return ,@($p1 | ForEach-Object { [pscustomobject]@{ name = [string]$_; size = (Get-SplitPartSizeText $_ ([string]$fileSize)); split = $true } }) }
  $p2 = Split-AdLineProducts $item
  $p2 = @($p2)
  if ($p2.Count -gt 1) { return ,@($p2 | ForEach-Object { [pscustomobject]@{ name = [string]$_; size = $fileSize; split = $true } }) }
  return ,@([pscustomobject]@{ name = $item; size = $fileSize; split = $false })
}
# The size text a split part must be priced by. The file row's size field is the transcriber's pick and is
# NOT reliably the first product's ("Nature Valley Bars, 5-12 ct or Pepperidge Farm Goldfish, 4.8-8 oz"
# carries size '4.8-8 oz'), so it is handed to a part only when it actually contains that part's own size
# expression; otherwise the size is cut from the part's own tail. Never invents a size: a part with no
# readable tail gets '' and prices exactly as an unsized row does.
function Get-SplitPartSizeText([string]$part, [string]$fileSize) {
  $m = [regex]::Match(("" + $part), $script:TcAdSizeTailRx)
  if (-not $m.Success) { return '' }
  $tail = $m.Value.Trim().TrimEnd('.')
  $fs = ("" + $fileSize).Trim()
  if ($fs) {
    $norm = { param($t) (($t -replace '\s+', ' ') -replace '\.', '').Trim().ToLower() }
    if ((& $norm $fs) -eq (& $norm $tail) -or (& $norm $fs).Contains((& $norm $tail))) { return $fs }
  }
  return $tail
}
# ---------------------------------------------------------------------------------------------------
# READING A SAM'S PRINTED UNIT PRICE, AND THE PRECISION IT WAS PRINTED TO (2026-09-20).
#
# Sam's prints a unit price two ways, and on 2026-09-20 it started using the second one:
#     "$1.66/lb"     at or above $1.00 per unit
#     "92.8 <cent>/lb"  below $1.00 per unit
# Over 29 capture files and 25,434 rows the split is mechanical and had ZERO exceptions on the day it
# changed; the same item ids read the other way the day before, so this is a RENDERING change by Sam's.
# grocery/probe-sams-unit-price-shapes.ps1 is the committed harness for that question.
#
# WHY THIS RETURNS A BOUND AND NOT JUST A NUMBER, which is the whole reason it exists. The cents form is
# not a re-spelling, it is a MORE PRECISE number: "$0.25/oz" became "24.8 <cent>/oz" and "$0.99/ea" became
# "99.2 <cent>/ea". Everything downstream of here back-solves a pack size out of linePrice / unitPrice, so
# the rounding in the unit price IS the error bar on the derived size, and the whole builder was written
# around one hard-coded 0.005 because until 2026-09-20 every Sam's unit price on disk - all 24,073 of them -
# carried exactly two decimal places. A cents-form price is rounded to a TENTH of a cent. Carrying 0.005
# for it would state an error bar TEN TIMES too wide, which is not a cosmetic overstatement: it is the
# window inside which a name's stated size is accepted as reproducing Sam's own arithmetic, so too wide a
# window accepts a size that is simply wrong and publishes a per-unit price to match. .claude/rules/grocery.md
# calls a wrong per-unit basis the hardest defect in this estate to find later.
#
# halfUlp is half of the LAST PRINTED DIGIT, expressed in dollars, which makes the old constant a special
# case of the new rule rather than a parallel path: two-decimal dollars gives exactly 0.005, so every one of
# those 24,073 historical rows reads identically to before. Only the cents form, and a dollar form printed
# to more than two decimals, get a tighter bound - and tightening can only ever REJECT an ambiguous size
# (which falls back to Sam's own arithmetic, or to a NAME CONFLICT reject), never mis-price one.
#
# THE GLYPH IS ANCHORED, deliberately unlike walmart-row-lib.ps1, which accepts any 1-3 non-digit characters
# in that position. The loose form reads a hypothetical "0.20 USD/oz" as $0.0020/oz - a silent hundredfold
# basis error on a live paid board. Returning $null here is an ordinary per-row reject: a row we decline to
# price, never a row we price wrongly. U+00A2 is what arrives today, read off the 2026-09-20 capture
# codepoint by codepoint; U+00C2 U+00A2 is the cp1252-mangled spelling walmart-row-lib.ps1's header records
# the capture sink producing; a bare "c" is unambiguous in this position.
#
# Returns @{ value; halfUlp; unit; decimals; form } in DOLLARS per unit, or $null if the text is not a unit
# price this estate knows how to read.
function Get-SamsUnitPriceReading([string]$Text) {
  $t = ("" + $Text).Trim()
  if (-not $t) { return $null }

  $m = [regex]::Match($t, '^\$\s*([\d,]+(?:\.(\d{1,4}))?)\s*/\s*(.+)$')
  $form = 'dollar'
  if (-not $m.Success) {
    # Built from codepoints, never typed: a cent glyph as a literal puts non-ASCII bytes in a .ps1 that
    # PowerShell 5.1 reads as ANSI, and the script then fails to PARSE.
    $centClass = '(?:' + ([string][char]0x00C2) + '?' + ([string][char]0x00A2) + '|[cC])'
    $m = [regex]::Match($t, ('^([\d,]+(?:\.(\d{1,4}))?)\s*' + $centClass + '\s*/\s*(.+)$'))
    $form = 'cents'
  }
  if (-not $m.Success) { return $null }

  $v = 0.0
  if (-not [double]::TryParse(($m.Groups[1].Value -replace ',', ''), [ref]$v)) { return $null }
  $dec = $m.Groups[2].Value.Length
  # In dollars: a cents figure printed to N decimals is a dollar figure printed to N+2.
  $dollarDec = if ($form -eq 'cents') { $dec + 2 } else { $dec }
  if ($form -eq 'cents') { $v = $v / 100.0 }
  return @{ value = $v; halfUlp = (0.5 * [math]::Pow(10, -1 * $dollarDec)); unit = $m.Groups[3].Value.Trim()
            decimals = $dec; form = $form }
}

# ---------------------------------------------------------------------------------------------------
# THE ERROR BAR ON A SAM'S DERIVED SIZE (2026-09-11, queue 2026-09-10-c8eb72).
# build-sams-deals derives every pack size Sam's did not state in its priced unit as linePrice / unitPrice,
# and Sam's prints unitPrice rounded to the CENT, so that size carries a relative error of 0.005/unitPrice -
# 7.1% at $0.07/oz, 10% at $0.05/oz. The row says so in qty_basis ('qty derived lp/up') and carries Sam's
# printed unit price beside it, but nothing downstream read either, so the board ranked a quotient as an
# exact number: "Sweet Baby Ray's Original Barbecue Sauce, 1 gal." took the bbq-sauce crown at $0.07/oz by a
# 6% margin over Walmart's $0.0743 with a 7.1% error bar on its own size. Pure, so the pricing library owns
# it and both the builder and the board compute the same number from the same two fields.
# Returns $null for anything that is not a derived row - absent means "no quotient here", never "no error".
# READS THE CENTS FORM TOO, AND TAKES ITS BOUND FROM THE PRINTED PRECISION (2026-09-20). Until that day
# this required a '$' and hard-coded 0.005. Both halves were load-bearing and both were about to be wrong:
# a cents-form unit price does not match a dollars-only regex, so this returned $null - and $null here does
# not mean "a wide band", it means NO BAND AT ALL. Get-CellRoundingPct then reports no uncertainty,
# Get-RoundingBandTies returns empty, and THE CROWN TEST IS SILENTLY SKIPPED: the board would have crowned
# a store cheapest on a back-solved size while stating that size had no error in it. That is the quiet
# failure mode, and it would have arrived on the same day the capture stopped being rejected.
# The bound now comes from the number's own printed precision (Get-SamsUnitPriceReading), which leaves all
# 24,073 historical two-decimal dollar rows computing exactly 0.005 as before.
function Get-DerivedRoundingPct([string]$qtyBasis, [string]$samsUnitPrice) {
  if (-not $qtyBasis) { return $null }
  if (("" + $qtyBasis) -notmatch '(?i)derived\s+lp\s*/\s*up') { return $null }
  $r = Get-SamsUnitPriceReading $samsUnitPrice
  if ($null -eq $r) { return $null }
  if ($r.value -le 0) { return $null }
  return [math]::Round(100.0 * $r.halfUlp / $r.value, 2)
}
# Which CELLS that error bar actually describes, and it is one copy of the rule. A Sam's row whose qty_basis
# says 'derived lp/up' had its size back-solved out of a rounded unit price - but a cell the engine priced from
# the NAME's volume instead was NOT divided by that quotient (the 2026-09-10 gallon-jug path: ranch-dressing
# and hot-sauce divide by the 128 fl oz the name states). Stamping a band on those would publish an uncertainty
# their number does not have, so the basis string decides it, here, once, for the board and the audit alike.
function Get-CellRoundingPct($row) {
  if ($null -eq $row) { return $null }
  if ($null -eq $row.pu_rounding_pct) { return $null }
  if (([string]$row.basis) -match 'from the NAME volume') { return $null }
  return [double]$row.pu_rounding_pct
}
# THE CROWN TEST. Given the cheapest row and the rows it beat, name every store whose own per-unit falls inside
# the cheapest row's rounding band. A non-empty answer means the ranking was decided by less precision than the
# winner's size has, so the board must not claim one of them is cheaper. Returns an EMPTY array when the winner
# carries no band, which is the common case and the right answer: no quotient, no doubt.
# The crown is never reassigned on this - the runner-up is not proven cheaper either.
function Get-RoundingBandTies($cheapest, $others) {
  $ties = New-Object System.Collections.Generic.List[string]
  $pct = Get-CellRoundingPct $cheapest
  if ($null -eq $pct -or $pct -le 0) { return ,@() }
  $cp = [double]$cheapest.unit_price
  if ($cp -le 0) { return ,@() }
  $e = [double]$pct / 100.0
  $lo = $cp * (1.0 - $e); $hi = $cp * (1.0 + $e)
  foreach ($o in @($others)) {
    if ($null -eq $o) { continue }
    $opu = [double]$o.unit_price
    if ($opu -ge $lo -and $opu -le $hi) { [void]$ties.Add([string]$o.store) }
  }
  return ,@($ties.ToArray())
}
function Get-PackCount($text) {
  if (-not $text) { return $null }
  $t = ("" + $text).ToLower()
  # 'ea'/'each' belong here: stores write a pack count as "42 Ea" / "12 Ea" every bit as often as "12 ct"
  # (Family Fare's Freshop feed does it throughout). Without them a 42-pod tub of laundry pacs had NO pack count
  # at all and priced as ONE pod. Safe next to a weight: "About 1.56 lb each" cannot match, because the count
  # must sit immediately before the unit and " lb " breaks it.
  # THE COUNT MUST NOT START INSIDE A NUMBER (2026-08-22). "$3.87 each" used to match "87 each" and read an
  # 87-pack out of a price. It never surfaced because the per-each marker returned before this ran; now that
  # the pack count is checked FIRST for each-commodities (see Get-UnitPrice) it would have divided a $3.87
  # bottle by 87. Same lookbehind the per-lb / per-each marker strips use.
  $m = [regex]::Match($t, '(?:per\s*)?(?<![\d.$])(\d+)\s*[- ]?\s*(?:pack|pk|count|ct|each|ea)\b')
  if ($m.Success) { $n = [int]$m.Groups[1].Value; if ($n -gt 1) { return $n } }
  return $null
}
# A COUNT RANGE TAKES ITS LEAST FAVOURABLE END, LIKE A WEIGHT RANGE (2026-09-25, queue 2026-09-19-dc1b5b,
# plan-2026-09-25-15). Get-SizeAmount's range rule (plan-2026-09-22-5: the SMALLER size, so the per-unit is the most a
# shopper pays) sits in the size path, and the each branch of Get-UnitPrice returns on a pack count before it gets
# there. Get-PackCount reads '25-42 ct' from its unit-adjacent end, 42, so the founding row
#     Fareway 'Bright Essentials Storage Bags' $3.99 size '25-42 ct' (storage-bags, comparison-2026-09-23)
# priced 0.095/bag against a least-favourable 0.1596. ASCENDING pairs only, the same guard the weight path uses:
# '24-12 ct' is not a range. Used ONLY where Get-UnitPrice reads an each-commodity pack count; Get-PackCount itself is
# unchanged, because the multibuy resolver and Get-EachCountConflict read it and neither prices a range. A '31-40 ct'
# shrimp grade never reaches this: shrimp is per-lb, and the weight branch never reads a count.
function Get-EachPackCount($text) {
  if (-not $text) { return $null }
  $t = ("" + $text).ToLower()
  $r = [regex]::Match($t, '(?<![\d.$])(\d+)\s*(?:to|or|-|&ndash;|thru)\s*(\d+)\s*[- ]?\s*(?:count|ct)\b')
  if ($r.Success) {
    $lo = [int]$r.Groups[1].Value; $hi = [int]$r.Groups[2].Value
    if ($lo -lt $hi -and $lo -gt 1) { return $lo }
  }
  return (Get-PackCount $text)
}
# A SIZE-FIELD COUNT THAT DISAGREES WITH THE NAME'S OWN COUNT IS NOT A BASIS (2026-09-25, queue 2026-09-22-8d2ad5,
# plan-2026-09-25-15). The each branch of Get-UnitPrice takes its pack count from the size field before the name, and
# nothing checked the two against each other. Founding rows, comparison-2026-09-23 (both live cells, as_of 2026-08-05):
#     Aldi  'Benner Black Tea Bags 100 CT'  $1.49  size '24 ct'   -> per-24-pack 0.0621 (the name's 100: 0.0149)
#     Aldi  'Willow Facial Tissue 144 CT'          size '160 ct'  -> 0.0087 (the name's 144: 0.0097)
# and the sub-unit shape that keeps Walmart off paper towels (133 of 136 rows):
#     Walmart 'Bounty Paper Towels Select-A-Size White, 2 Triple Rolls, 123 Sheets per Roll' $6.97 size '246 ct'
# where 246 is 2 x 123 SHEETS, priced as 246 towels. RESOLVED BY ARITHMETIC, NEVER BY A BAR (no hard-coded bands):
#   1. the name states pack counts {N...} and the basis count M (read from the size field) is none of them, and for
#      every N neither of M and N divides the other. 'Marathon ... 6 pk., 3000 ct.' with M=3000 names M itself, and a
#      name of 100 against a size of 200 is a count-times-pack total, so both stay legal;
#   2. the name or size states a SUB-UNIT count S (sheets or slices PER a container) and M is S or a multiple of it:
#      the basis is the sub-unit, not the thing the shopper buys.
# A count range ('31-40 ct', a shrimp grade; '12-18 ct') is not a pack count and is never read. An either/or name
# (Test-NameOffersTwoSizes) is not a statement about one product and is never read. Returns the reason, or $null.
# NARROWER THAN THE PLAN'S TEXT, on purpose: "'N count' on a loaf" (bread slices written '20 Count') has no word in
# the row that says the count is slices, so it is not refused here; those rows sit under the floor already.
function Get-NameCountSet([string]$text) {
  $set = New-Object 'System.Collections.Generic.List[int]'
  if (-not $text) { return ,$set }
  $t = $text.ToLower()
  # an optional single adjective before rolls/bags ('2 Triple Rolls', '12 Mega Rolls'); never before ct/pk/ea
  $rx = '(?<![\d.$])(?<!\d\s*-\s*)(?<!\d\s*to\s*)(\d+)\s*[- ]?\s*(?:(?:pack|pk|count|ct|each|ea)\b|(?:[a-z]+\s+)?(?:rolls?|bags?)\b)'
  foreach ($m in [regex]::Matches($t, $rx)) {
    $after = $t.Substring($m.Index + $m.Length)
    if ($after -match '^\s*-\s*\d') { continue }   # '12-18 ct' read from its left end
    $n = [int]$m.Groups[1].Value
    if ($n -gt 1 -and -not $set.Contains($n)) { $set.Add($n) }
  }
  return ,$set
}
function Get-EachCountConflict([string]$size, [string]$name, $pieces) {
  $m = Get-PackCount $size
  if (-not $m) { return $null }
  if ($null -eq $pieces -or [double]$pieces -ne [double]$m) { return $null }   # the basis did not come from the size count
  if (Test-NameOffersTwoSizes $name) { return $null }
  # a sub-unit is counted PER a container ('123 Sheets per Roll', '20 slices/loaf'); a bare '70 Sheets' is not one,
  # because on dryer-sheets the sheet IS the unit (Suavitel ... 70 Sheets, size 70 ct, candidates-2026-09-23)
  $sub = [regex]::Match(("$name $size").ToLower(), '(?<![\d.$])(\d+)\s*(?:sheets?|slices?)\s*(?:per\s+|/\s*)[a-z]')
  if ($sub.Success) {
    $s = [int]$sub.Groups[1].Value
    if ($s -gt 1 -and $m -ge $s -and ($m % $s) -eq 0) { return "size count $m is a sub-unit count ($s $($sub.Value -replace '^\d+\s*',''))" }
  }
  $nameSet = Get-NameCountSet $name
  if ($nameSet.Count -eq 0 -or $nameSet.Contains([int]$m)) { return $null }
  foreach ($n in $nameSet) { if ((($m % $n) -eq 0) -or (($n % $m) -eq 0)) { return $null } }
  return ("name states " + (($nameSet | ForEach-Object { [string]$_ }) -join '/') + " ct, size field states $m ct")
}
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
  # A PACK COUNT BEATS A PER-EACH MARKER (2026-08-22). "Bottled Water 24 Pack, $3.87 each" carries both: the
  # marker says the $3.87 is for one unit of SALE, the pack count says that unit is 24 bottles. For an
  # each-commodity the bottle is the thing being compared, so the marker returning here first published
  # $3.87/each against a true $0.161 (pu-lib step 5 already divided the same row by the name's pack count,
  # so the two copies of this math disagreed - the parity test's whole reason to exist). Plain prices only,
  # and never for a pack_is_package commodity, exactly as the plain path below decides it.
  # A PER-EACH MARKER IN THE NAME DOES NOT MAKE A PER-POUND PRICE PER EACH (2026-09-18, backlog I222).
  # Walmart sells weighed produce under names ending ", Each" and writes the size as a weight when its own
  # unit price is the shelf price per pound: "Fresh Purple Eggplant, Each | $1.82 | $1.82/lb"
  # (walmart-capture-2026-08-31.csv) reached the board as $1.82 EACH with size "lb", and the 2026-07-25
  # sighting of the same product carries "1 lb". The marker was read out of the NAME and returned before
  # anything looked at the size. The same shape as the per-lb rule above: the NAME says one thing, the size
  # field says a weight, and the price text says neither. So a name-only marker over a WEIGHT-ONLY size does
  # not take this branch: the row falls to the plain each branch below, which prices a weight as one unit only
  # for a commodity that declares weight_is_one_unit (Brad's 2026-09-06 ruling: a 14 oz loaf is one loaf, a
  # pound of produce is an unknown number of items) and otherwise refuses it. A price text that itself says
  # each ("$2.99 each") is the store's own statement about the priced unit and still takes this branch.
  $nameOnlyEachOverWeight = $false
  if ($unit -eq 'each' -and $pr.kind.pereach) {
    $weightOnlySize = [regex]::IsMatch(("" + $deal.size_text), '(?i)^\s*(?:/|per|a)?\s*(?:\d+(?:\.\d+)?\s*)?(?:lbs?|pounds?|oz|ounces?|kg)\.?\s*$')
    $eachInPrice = ((ConvertTo-DigitNumerals ("" + $deal.price_text)) -match '(?i)(per\s*ea|/\s*ea|\bea\.?\b|\beach\b)')
    $nameOnlyEachOverWeight = ($weightOnlySize -and -not $eachInPrice)
  }
  if ($unit -eq 'each' -and $pr.kind.pereach -and -not $nameOnlyEachOverWeight) {
    if ($pr.note -eq '' -and -not ($cat.PSObject.Properties['pack_is_package'] -and $cat.pack_is_package)) {
      # SAME EITHER/OR REFUSAL AS THE BRANCH BELOW (2026-08-31, queue 2026-08-31-8018b5). This was the THIRD
      # place in this function that reads a pack count and the only one with no guard at all, so the whole
      # refusal was reachable only by rows that missed the per-each marker. The founding row carries the
      # marker in the very word that makes it ambiguous:
      #     "Bud by Dole romaine hearts 3 ct. pkg. or cauliflower each, $3.48"
      # 'each' fires pereach, this line then took "3 ct" out of the name, and cauliflower published at $1.16
      # against a real $3.48 - and it took the crown. Refusing here lets the per-each marker below answer
      # $3.48, which is the price the ad actually states for one cauliflower.
      $pkm = $null
      if (-not (Test-NameOffersTwoSizes $deal.price_text)) { $pkm = Get-EachPackCount $deal.price_text }
      if (-not $pkm) { $pkm = Get-EachPackCount $deal.size_text }
      if ((-not $pkm) -and -not (Test-NameOffersTwoSizes $deal.name)) { $pkm = Get-EachPackCount $deal.name }
      if ($pkm) { return @{ unit_price=($pr.per_item/$pkm); basis="per-$pkm-pack (pack count beats the per-each marker)"; note=$pr.note } }
    }
    return @{ unit_price=$pr.per_item; basis='per-each marker'; note=$pr.note }
  }
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
  # A PER-POUND PRICE ON AN OUNCE COMMODITY IS A RATE, NOT A PACK WEIGHT (2026-09-07, queue 2026-09-07-e9edb9).
  # Hy-Vee's deli lines put the price LAST and label it per pound: "Di Lusso premium sliced cheese, $9.99 lb."
  # Get-ItemPrice reads 9.99 as the price (right) and sets the perlb marker (right), but sliced-cheese is an
  # OZ commodity, so the lb branch above never runs and the size parser below reads the SAME "9.99 lb" out of
  # the name as a 9.99-POUND package: 9.99 / (9.99 x 16) = 1/16 = 0.0625 for ANY price. That is a fingerprint,
  # not a coincidence, and five Hy-Vee rows carried it on 2026-09-07 (parmesan $21.99 lb., turkey-lunchmeat
  # $8.99 lb., deli-ham $8.99 lb., sliced-cheese $9.99 lb., queso $9.99 lb.). The band refused all five, which
  # is what held the whole board on the band-censorship ratchet that morning. The same token on an LB
  # commodity has always been read correctly ("Gala or Granny Smith apples, $1.88 lb." publishes 1.88/lb).
  #
  # THE TELL IS SELF-CHECKING, the same shape as 'per-lb rate in size' just above: the number glued to "lb"
  # IS the number Get-ItemPrice took as the price, so the row states a RATE and no package weight at all.
  # And it only fires when the SIZE field has no usable amount - when the store gave a real size ("12 oz"),
  # that size is a statement about the package and the division below is right.
  #
  # THE BASIS STRING IS LOAD-BEARING: export-feed.ps1:116 matches the substring 'per-lb marker' and ships the
  # cell as variableWeight, so a recipe card charges the exact amount used instead of rounding up to a
  # package. That is correct for these rows - a deli counter sells cheese and ham by weight, there is no
  # package - so the substring is kept deliberately, not by accident.
  if ($unit -eq 'oz' -and $plain -and $pr.kind.perlb) {
    $rateTxt = ConvertTo-DigitNumerals ((("" + $deal.price_text + " " + $deal.name) -replace "`n", ' '))
    $rm = [regex]::Match($rateTxt, '(?i)\$\s*(\d+(?:\.\d{1,2})?)\s*(?:/\s*|per\s*)?lbs?\.?(?![\w-])')
    if ($rm.Success -and ([math]::Abs([double]$rm.Groups[1].Value - $pr.per_item) -lt 0.005)) {
      $szAmtLb = Get-SizeAmount ([string]$deal.size_text) $unit
      if (($null -eq $szAmtLb) -or ($szAmtLb -le 0)) {
        return @{ unit_price=($pr.per_item/16.0); basis='per-lb marker (converted to oz)'; note=$pr.note }
      }
    }
  }
  if ($unit -in @('lb','oz','floz','gallon','dozen','sq_ft')) {
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
    # A GALLON JUG IS A GALLON, WHATEVER A QUOTIENT SIZE SAYS (2026-09-10, queue 2026-09-10-d9e085).
    # On a fl-oz commodity Get-SizeAmount reads a bare 'oz' label as fluid ounces, which is right for the
    # near-water rows that print "16 oz" on a bottle - and wrong when the label is not a measurement at all.
    # Sam's "Member's Mark Ranch Dressing, 1 gal." carries size '122 oz' = $10.98 / $0.09, its own cent-rounded
    # unit price turned back into a quantity, so the cell published 0.09/fl oz for a jug the name calls 128 fl oz
    # (true 0.0858, 4.9% over), and the size string re-keyed basis-kind-allowlist on every cent Sam's moved.
    # When the size is a BARE oz label and the name states exactly ONE volume, the name's volume is the divisor
    # and size_override tells compare-deals to put that quantity on the cell (Resolve-CellSizeText).
    # SCOPE: fl-oz commodities ONLY. On an oz/lb commodity Sam's derived weight is the right KIND - Sweet Baby
    # Ray's '1 gal.' at 171.143 oz is a 1.3 g/ml sauce and must not become 128.
    # THE PLAUSIBILITY BAR, 0.8x to 1.25x of the name's volume: the size must be a noisy statement of the SAME
    # quantity. It brackets the measured population (plan-2026-09-10.routing.json s5: the 11 rows on fl-oz
    # commodities sit at 0.953 to 1.008 of their name volume) and refuses a multipack, whose size is the pack
    # total ("Cola 2 L, 6 pk" at 405.6 oz is 6.0x one bottle). First plausible bar, not swept; a row outside it
    # keeps today's size-based price, never a guessed one. An either/or name is refused outright, exactly as the
    # name fallback below refuses it.
    if ($unit -eq 'floz' -and $deal.name -and [regex]::IsMatch($sizeForAmt, '^\s*\d+(?:\.\d+)?\s*oz\.?\s*$', 'IgnoreCase') -and -not (Test-NameOffersTwoSizes ([string]$deal.name))) {
      $nvFloz = Get-NameVolumeFloz ([string]$deal.name)
      $szFloz = Get-SizeAmount $sizeForAmt $unit
      if ($nvFloz -and $szFloz -and ($szFloz -gt 0) -and (($szFloz / $nvFloz) -ge 0.8) -and (($szFloz / $nvFloz) -le 1.25)) {
        $nvR = [math]::Round($nvFloz, 3)
        return @{ unit_price=($pr.per_item/$nvFloz); basis=("size $nvR floz from the NAME volume (size field '" + $sizeForAmt + "' is a bare-oz label on a fl-oz commodity)"); size_override=($nvR.ToString([Globalization.CultureInfo]::InvariantCulture) + ' fl oz'); note=$pr.note }
      }
    }
    # FAIL CLOSED ON A LINE THAT STATES TWO SIZES AND COULD NOT BE SPLIT (2026-09-11, queue 2026-09-10-582032).
    # Split-TwoProductAdLine handles the shape the Baker's flyer writes ("A, size or B, size") at the ingest
    # seam, and a row it produced carries split_from, so the size below is that part's OWN size. What is left
    # is the shape it deliberately refuses: Hy-Vee's "A size, B size, $price", where 'or' also joins varieties
    # and size options (10 such lines on ads-2026-09-11, 4 routing, 0 holding a cell). For those the size field
    # and the name each name two different quantities and NOTHING here can tell which one the price belongs to,
    # so the division below was picking one at arbitrary - which is how the founding cereal line published
    # $0.0976/oz against an honest $0.219 and crowned the commodity.
    # UNPRICED IS THE HONEST ANSWER: the row drops out of the ranking and the cell falls to a store we can
    # divide correctly, instead of publishing a real price against the wrong product's size. The refusal sits
    # AFTER the name-volume branch above, which already carries its own either/or refusal, so the 2026-09-10
    # gallon-jug path is untouched.
    if ($deal.name -and (Test-NameOffersTwoSizes ([string]$deal.name)) -and -not $deal.split_from) { return $null }
    $amt = Get-SizeAmount $sizeForAmt $unit
    # The NAME is a last resort, and it is only usable when it states ONE size. An either/or ad names two
    # (see Test-NameOffersTwoSizes) and the first-match regex would silently pick the larger, cheaper-looking
    # one. Refuse instead: $amt stays null, the row returns UNPRICED and drops from the ranking.
    if (($amt -eq $null) -and $deal.name -and -not (Test-NameOffersTwoSizes $deal.name)) { $amt = Get-SizeAmount $deal.name $unit }
    if ($amt -ne $null -and $amt -gt 0) { return @{ unit_price=($pr.per_item/$amt); basis="size $([math]::Round($amt,3)) $unit"; note=$pr.note } }
    return $null
  }
  if ($unit -eq 'each') {
    # Same either/or refusal as the weight/volume branch above: "Kroger Freezer Pops 36 ct or Budget Saver
    # Twin Ice Pops 12-18 ct" at $2.99 read a 36-pack out of the name and published popsicles at $0.0831
    # each. The price and the size field are the store's own statements about the priced unit and are still
    # trusted; only reading a COUNT out of a name that offers two of them is refused.
    # THE REFUSAL HAS TO COVER price_text TOO (2026-08-31, queue 2026-08-31-8018b5). It used to guard only
    # the NAME fallback, on the reasoning that "the price and the size field are the store's own statements
    # about the priced unit". That reasoning does not hold for Hy-Vee: its loader passes the WHOLE ad line as
    # price_text (`Add-Norm -Store $d.store -Name $pn -PriceText $pn ...`), so price_text IS the ambiguous prose, and the
    # count was read out of it before the name guard was ever consulted. Live consequence:
    #     "Bud by Dole romaine hearts 3 ct. pkg. or cauliflower each, $3.48"
    # took "3 ct" from price_text, divided, and crowned cauliflower at $1.16 against a real $3.48.
    # size_text stays trusted - that one really is a statement about the unit being priced, not prose.
    $pk = $null
    if (-not (Test-NameOffersTwoSizes $deal.price_text)) { $pk = Get-EachPackCount $deal.price_text }
    if (-not $pk) { $pk = Get-EachPackCount $deal.size_text }
    if ((-not $pk) -and -not (Test-NameOffersTwoSizes $deal.name)) { $pk = Get-EachPackCount $deal.name }
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
      # pieces=1: the declaration says the PACKAGE is the unit being compared, so the package is the piece.
      return @{ unit_price=$pr.per_item; basis="per-package ($pk ct inside)"; note=$pr.note; pieces=1 }
    }
    if ($plain -and $pk)  { return @{ unit_price=($pr.per_item/$pk); basis="per-$pk-pack"; note=$pr.note; pieces=$pk } }
    # A PACKAGED GOOD'S WEIGHT IS ITS COUNT (2026-09-06, Brad's ruling; PLAN-top5-2026-09-06 section 1).
    # The drop on the last line of this branch refuses any each-row whose only stated size is a weight. That
    # refusal is RIGHT for produce - a 2 lb bag of kiwi is an unknown number of kiwis - and WRONG for a
    # packaged good, where a 14 oz loaf is one loaf. Nothing in commodities.json said which kind an id was,
    # so the engine could not tell them apart and refused both.
    #
    # THE FOUNDING CASE IS A STALE CELL, NOT A MISSING ONE. french-bread|Walmart published $1.25 from a
    # 07-18 capture whose size was the word "each"; Walmart's current capture writes the real weight
    # ("Freshness Guaranteed French Bakery Bread Loaf, 14 oz, 1 Loaf | $1.47 | 14 oz"), which was unpriceable,
    # so Update-PriceFromNewerSighting correctly refused it and the July number outlived its own product's
    # newer sighting. Three more cells sat in that state (gelatin, rotisserie-chicken, frozen-pizza at
    # Walmart). The fix is to make the newer row PRICEABLE - letting an unpriced newer sighting retire an
    # older price instead would blank all four.
    #
    # WHICH COMMODITIES MAY DECLARE IT, and the test that decides: the commodity's OWN existing cells say so.
    # `basis` reads per-each at some store for bread, brownie-mix, cake-mix, french-bread, gelatin,
    # frozen-pizza and rotisserie-chicken - a package there IS one unit. It reads per-8-pack / per-6-pack /
    # per-20-pack for hamburger-buns, english-muffins, bar-soap, donuts, corn-dogs, pita-bread, hot-dog-buns,
    # breakfast-sandwiches and microwave-popcorn, where a package is MANY units, and the flag would publish
    # Aldi's "$1.39 | 12 oz" buns as $1.39 A BUN against a real $0.174. Those nine are NOT declared; they are
    # reported as a basis gap instead. (band_max happens to block all nine on today's prices, which is the
    # accidental-duty problem PLAN section 2 exists to end - it is not a reason to lean on it.)
    #
    # A REAL PACK COUNT STILL WINS: this sits AFTER the per-$pk-pack line, so a declaring commodity handed
    # "2 pack ... 30 oz" still prices per-2-pack. garlic-bread declares both this and pack_is_package, and
    # they do not collide - pack_is_package answers a row that HAS a count, this one answers a row that
    # has none.
    if ($plain -and (-not $pk) -and $cat.PSObject.Properties['weight_is_one_unit'] -and $cat.weight_is_one_unit) {
      # size_text is the store's own statement about the priced unit and is read first. The NAME is a last
      # resort under the same either/or refusal the weight branch above uses: an ad naming two sizes is not
      # a statement about one package.
      $wRx = '(?i)(\d+(?:\.\d+)?|\.\d+)\s*(oz|ounce|ounces|lb|lbs|pound|pounds|g|gram|grams)\b'
      $wHit = ([string]$deal.size_text -match $wRx)
      if ((-not $wHit) -and $deal.name -and -not (Test-NameOffersTwoSizes $deal.name)) { $wHit = ([string]$deal.name -match $wRx) }
      if ($wHit) { return @{ unit_price=$pr.per_item; basis='per-each (weight is one unit)'; note=$pr.note; pieces=1 } }
    }
    # A Hy-Vee PERKS ad price is a single retail unit; with no pack count it prices per-each (a pack count above
    # still divides). Scoped to the Perks pattern so the general "bare package, unknown count -> drop" guard holds.
    # 'BUNCH' IS A WHOLE PURCHASE (2026-08-31), and its absence here cost a live cell. Hy-Vee prices green
    # onions "$1.49 / bunch"; green-onions is an `each` commodity, `bunch` matched none of the tokens below,
    # so the row fell through to the drop on the next line and Hy-Vee LEFT the green-onions row entirely -
    # reported as an unexplained cell-drop against a capture that plainly contained the product.
    #
    # THIS IS THE LINE THAT DECIDES IT, and the first cut of this fix patched the wrong one. Get-SizeAmount
    # also learned `bunch` that day - and never runs for this case, because the branch that calls it is
    # scoped to lb/oz/floz/gallon/dozen. That edit was reverted rather than left in looking useful.
    # Scoped to the size being ONLY the word, so "3 bunches" still falls through to the count logic above,
    # and it says nothing about weight - a weight commodity never reaches this branch at all.
    # THE WHOLE-PURCHASE LIST, NOT A HAND COPY (2026-09-06). This line used to spell its own tokens, and it
    # had drifted to bunch(es) only - so Hy-Vee's "Bud Iceberg Lettuce | head | $1.97" fell through to the
    # drop below and Hy-Vee simply had no lettuce cell. It now reads $script:TC_WholePurchaseTokens, the same
    # list Get-SizeAmount's bare-token gate reads, so the two cannot drift again. What it must NOT gain is
    # pk/pkg/package: those name a container of unknown count, and the mystery-tray fixture pins the drop.
    # A MULTIBUY DIVIDES ITS PACK COUNT TOO (2026-09-25, queue 2026-09-23-9459a1, plan-2026-09-25-15). The plain
    # line above divides a stated pack count; a multibuy never reached it, so the line below returned the multibuy's
    # per-PACK price as the price of ONE unit. Founding rows (Family Fare, flagged-2026-09-23, bar-soap):
    #     'Dove Beauty Bar Soap Sensitive, 6 Ea' | Buy 1 get 1 40% off | reg 13.59 | size '6 ea'  -> 10.872 "per bar"
    # against a true 1.812, refused by the band and paged as "a bad multibuy parse". The count is RESOLVED BY PROOF,
    # the way build-aldi-regular resolves a pack basis: every party that states a count (price text, size field,
    # name) must state the SAME one, and two different counts are a conflict that is REFUSED, never guessed. An
    # either/or line is not a party (the same Test-NameOffersTwoSizes refusal the plain path uses).
    # SCOPED TO BUY-N-GET-K (Test-IsMultibuy), NOT EVERY NON-PLAIN PRICE: an "N for $M" deal is non-plain too and has
    # the same per-pack defect (18 each-unit Family Fare rows on candidates-2026-09-23: Eggo 10 Ea, Bomb Pop 12 Ea,
    # Little Bites 5 Ea ...), but those move cells the plan never measured, so they are left for their own item.
    if ((-not $plain) -and (Test-IsMultibuy ([string]$deal.price_text))) {
      $mbPack = Resolve-MultibuyPackCount $deal
      if ($mbPack.conflict) { return $null }
      if ($mbPack.count) { return @{ unit_price=($pr.per_item/$mbPack.count); basis=('per-' + $mbPack.count + '-pack (multibuy, count from ' + $mbPack.from + ')'); note=$pr.note; pieces=$mbPack.count } }
    }
    if ((-not $plain) -or ($deal.size_text -match ('(?i)^\s*(1\s*)?(' + (Get-TcWholePurchaseTokens) + ')\.?\s*$')) -or ([string]$deal.price_text -match '(?i)perks\s*price')) { return @{ unit_price=$pr.per_item; basis='per-each'; note=$pr.note; pieces=1 } }
    return $null   # bare package price with unknown count -> not confident, drop
  }
  return $null
}
function Test-IsMultibuy([string]$t) { return ((ConvertTo-DigitNumerals ("" + $t)) -match '(?i)buy\s*\d+\s*,?\s*get\s*\d+') }

# THE PACK COUNT A MULTIBUY ROW PROVES (2026-09-25, queue 2026-09-23-9459a1). Each party that states a count - the
# price text and the name unless they offer two sizes, and the size field always - is read with Get-PackCount.
# One distinct count: that is the pack. Two different counts: a CONFLICT, and the caller refuses the row (UNPRICED)
# rather than choosing. None: no count, the caller keeps its old per-each answer.
function Resolve-MultibuyPackCount($deal) {
  $seen = [ordered]@{}
  if (-not (Test-NameOffersTwoSizes ([string]$deal.price_text))) { $n = Get-PackCount $deal.price_text; if ($n) { $seen['price'] = $n } }
  $n = Get-PackCount $deal.size_text; if ($n) { $seen['size'] = $n }
  if (-not (Test-NameOffersTwoSizes ([string]$deal.name))) { $n = Get-PackCount $deal.name; if ($n) { $seen['name'] = $n } }
  $distinct = @($seen.Values | Sort-Object -Unique)
  if ($distinct.Count -gt 1) { return @{ count = $null; conflict = $true; from = (@($seen.Keys | ForEach-Object { $_ + '=' + $seen[$_] }) -join ' ') } }
  if ($distinct.Count -eq 1) { return @{ count = [int]$distinct[0]; conflict = $false; from = (@($seen.Keys) -join '+') } }
  return @{ count = $null; conflict = $false; from = '' }
}

# WHICH HALF AN OUT-OF-BAND MULTIBUY REFUSAL IS (2026-09-25, queue 2026-09-23-9459a1). compare-deals used to call
# every one "likely a bad multibuy size/regular parse", so a real premium sale on a complete basis (Dove Hand Wash
# 12 fl oz, BOGO 40% at 0.3993/fl oz) paged exactly like a basis bug. The basis string decides it: a price divided
# by a stated size or a stated pack count is COMPLETE, so the band refused a real price (band review owns it); an
# each-unit row that fell through to 'per-each' with no stated count or whole-purchase size is UNRESOLVED (review
# the capture). A row with no basis at all (the safety net's UNPRICED rows) is unresolved.
function Get-MultibuyRefusalHalf([string]$basis, [string]$unit) {
  if (-not $basis) { return 'unresolved' }
  if ($unit -eq 'each' -and $basis -eq 'per-each') { return 'unresolved' }
  return 'complete-basis'
}

# ---------------------------------------------------------------- A QUANTITY-CONDITIONAL DEAL IS THE PRICE, AND ITS CONDITION IS SHOWN
# (Brad's ruling, 2026-09-22, queue 2026-09-22-a2af45: "A - just make sure that we add this to the UI and also make
# sure we handle this in other instances of this type of promo (When you buy 2, 3, 4 etc)").
# "N for $X", "N for $X with purchase of N", "buy N get M" and BOGO price the cell at the effective per-unit (Get-ItemPrice
# above already does, and writes its note), and the cell CARRIES the store's condition so the board can show it and the
# price verifier can read it. THIS IS THE ONE READER OF THE CONDITION: the engine stamps deal_qty / deal_condition on the
# row through Add-TcDealConditionFields at emit, build-deals-page renders deal_condition beside the price, and
# flag-verify-lib reads deal_qty OFF THE ENGINE'S ROW (a verifier that re-derives the basis is gap F1 of
# design/RCA-holistic-2026-09-22.md: it judged the Family Fare yellow pepper $1.00 "wrong-price" against the $1.99 single).
# It reads the ENGINE'S NOTE, never the ad text alone: a condition exists only when the engine actually priced the row
# through a deal branch, so a "2 for $5" row the engine priced some other way never claims a condition it did not use.
# The ad text is read for ONE thing, the "with purchase of N" / "must buy N" qualifier, which the note does not carry.
# BOGO is folded into the ruling as "when you buy N+M"; its displayed text keeps the store's own wording.
function Format-TcDealMoney([double]$v) {
  $ic = [Globalization.CultureInfo]::InvariantCulture
  if ([math]::Abs($v - [math]::Round($v)) -lt 0.000001) { return ('$' + ([int64][math]::Round($v)).ToString($ic)) }
  return ('$' + $v.ToString('0.00', $ic))
}
function Get-TcDealCondition([string]$PriceText, [string]$Note) {
  # Returns $null (the engine priced no quantity condition) or [pscustomobject]@{ qty; text; kind }.
  $n = ([string]$Note).Trim()
  if (-not $n) { return $null }
  $ic = [Globalization.CultureInfo]::InvariantCulture
  $ad = ConvertTo-DigitNumerals ([string]$PriceText)
  $m = [regex]::Match($n, '^(\d+) for \$([\d.]+)$')
  if ($m.Success) {
    $q = [int]$m.Groups[1].Value
    if ($q -le 1) { return $null }   # "1 for $2" is a plain price, not a condition
    $req = [regex]::Match([string]$ad, '(?i)(?:with\s+(?:the\s+)?purchase\s+of|must\s+buy|when\s+you\s+buy)\s*(\d+)')
    if ($req.Success -and [int]$req.Groups[1].Value -gt 1) {
      return [pscustomobject]@{ qty = [int]$req.Groups[1].Value; text = ('when you buy ' + $req.Groups[1].Value); kind = 'must-buy' }
    }
    return [pscustomobject]@{ qty = $q; text = ([string]$q + ' for ' + (Format-TcDealMoney ([double]::Parse($m.Groups[2].Value, $ic)))); kind = 'n-for' }
  }
  $m = [regex]::Match($n, '^BOGO buy (\d+) get (\d+) free')
  if ($m.Success) {
    $b = [int]$m.Groups[1].Value; $g = [int]$m.Groups[2].Value
    return [pscustomobject]@{ qty = ($b + $g); text = ('buy ' + $b + ' get ' + $g + ' free'); kind = 'bogo' }
  }
  $m = [regex]::Match($n, '^buy (\d+) get (\d+) for \$([\d.]+)')
  if ($m.Success) {
    $b = [int]$m.Groups[1].Value; $g = [int]$m.Groups[2].Value
    return [pscustomobject]@{ qty = ($b + $g); text = ('buy ' + $b + ' get ' + $g + ' for ' + (Format-TcDealMoney ([double]::Parse($m.Groups[3].Value, $ic)))); kind = 'buy-get' }
  }
  $m = [regex]::Match($n, '^buy (\d+) get (\d+) ([\d.]+)% off')
  if ($m.Success) {
    $b = [int]$m.Groups[1].Value; $g = [int]$m.Groups[2].Value
    return [pscustomobject]@{ qty = ($b + $g); text = ('buy ' + $b + ' get ' + $g + ' ' + $m.Groups[3].Value + '% off'); kind = 'buy-get' }
  }
  return $null   # 'cents', '' and every non-deal note: the engine priced no quantity condition
}
function Add-TcDealConditionFields($Row, [string]$PriceText, [string]$Note) {
  # The engine's emit calls this on every store row (compare-deals, the comparison 'stores' block), so the board's
  # cell carries the condition it was priced under. Absent means the price holds for ONE unit.
  $dc = Get-TcDealCondition $PriceText $Note
  if ($null -ne $dc) { $Row['deal_qty'] = [int]$dc.qty; $Row['deal_condition'] = [string]$dc.text }
  return $Row
}

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
