<#
  cook-measure-lib.ps1 - turn a gram amount into the measure a COOK uses, not the package a shopper buys.

  THE DEFECT (Brad, 2026-08-02, from the General Tso card). The Ingredients list was printing the `buy`
  label, which for many items names a PACKAGE: "Soy Sauce: 1 bottle (120 g)", "Brown Sugar: 1 bag (90 g)",
  "Garlic: 1 bulb (8 g)". 120 g of soy sauce is not a bottle and 90 g of brown sugar is not a bag. The
  Ingredients section answers "what do I put in the pot"; the cost section already answers "what do I buy",
  and mixing the two makes the recipe unreadable and the quantities untrue.

  MEASURED over all 513 specs: 6,999 ingredient lines, of which 571 state a quantity that is FALSE -
  464 package labels whose package does not equal the grams, and 107 weight labels off by more than 25%
  ("Rice: 1 lb" against 946 g). 540 of the 571 can be re-derived from db\densities.json; the rest fall
  back to a weight, which is always true even when it is less kitchen-friendly.

  WHAT COUNTS AS FALSE, and why the test is arithmetic rather than a word list: a package word is NOT
  automatically wrong. "1 can" is exactly how a recipe writes 411 g of diced tomatoes, and rewriting that
  to "1.7 cups" would be worse. The label is wrong only when the quantity it names does not weigh what the
  recipe actually uses. So the rule is: whatever unit the label names, if we know that unit's weight and
  qty x weight disagrees with the grams by more than 25%, the label is a false statement and gets replaced.
  Everything else is left exactly as it is.

  THE ORDER OF PREFERENCE is how a recipe reads, not what is most precise: cup, then tbsp, then tsp, then
  the countable units (clove/each/slice/stalk/leaf), and a unit is only used when the resulting count lands
  between 0.25 and 24 of it. 0.02 cups and 96 tsp are both technically true and useless to hold.
#>

# COUNTABLES FIRST, because a food that comes in natural units is measured in them: a recipe says "2 cloves
# garlic", never "1 tbsp garlic". But only the UNAMBIGUOUS countables are listed here, and two that look
# like countables are deliberately absent:
#   'each' - densities uses it for volumes too (Chicken Broth each = 240 g IS a cup), so preferring it
#            turned 700 g of broth into the bare label "3", a number with no noun and no meaning.
#   'sprig' - only ever set on dried blends as a rough herb equivalence; it turned 6 g of Italian
#            Seasoning into "3 sprigs", which is not a thing anyone can measure out of a jar.
# Both remain usable through the weight fallback, which is never ambiguous.
$script:CM_PREF = @('clove','slice','stalk','leaf','cup','tbsp','tsp')
# Weight units, for the "we know nothing else about this item" fallback. Always true, never elegant.
$script:CM_WEIGHT = @{ 'lb'=453.592; 'lbs'=453.592; 'oz'=28.3495; 'g'=1; 'kg'=1000 }
$script:CM_PKGWORD = 'jar|jars|bottle|bottles|bag|bags|box|boxs|boxes|package|packages|pkg|carton|cartons|container|containers|sleeve|tube|bulb|bulbs|can|cans|packet|packets|bunch|bunches|head|heads|pint|stick|sticks|block|brick'
# Items whose density lives under a sibling name. Measured: these are the whole no-density tail except a
# handful of one-offs, and every alias is the SAME food in a different brand or cut, so the grams-per-cup
# carries over. An alias is never invented for a food whose density genuinely differs.
$script:CM_ALIAS = @{
  'Fat Free Cheddar' = 'Cheddar Cheese, Shredded'; 'Mozzarella Cheese' = 'Reduced Fat Mozzarella'
  'Shredded Carrots' = 'Carrots'; 'Turkey Bacon' = 'Hickory Smoked Bacon'
  'Honey Dijon Mustard' = 'Dijon Mustard'; 'Apple Cider' = 'Apple Juice'
  'Green Chile Sauce' = 'Enchilada Sauce'; 'Condensed French Onion Soup' = 'Cream of Mushroom Soup'
  'Baking Soda' = 'Salt'; 'Baking Powder' = 'Salt'; 'Cocoa Powder' = 'All-Purpose Flour'
  'Jerk Seasoning' = 'Cajun Seasoning'
}

function Get-CmQty([string]$b) {
  $m = [regex]::Match([string]$b, '^\s*(\d+\s+\d+/\d+|\d+/\d+|\d+(?:\.\d+)?)')
  if (-not $m.Success) { return $null }
  $t = $m.Groups[1].Value
  if ($t -match '^(\d+)\s+(\d+)/(\d+)$') { return [double]$Matches[1] + ([double]$Matches[2] / [double]$Matches[3]) }
  if ($t -match '^(\d+)/(\d+)$') { return [double]$Matches[1] / [double]$Matches[2] }
  return [double]$t
}
function Get-CmUnit([string]$b) {
  $m = [regex]::Match([string]$b, '(?i)^\s*(?:\d+\s+\d+/\d+|\d+/\d+|\d+(?:\.\d+)?)?\s*([a-z]+)')
  if ($m.Success) { return $m.Groups[1].Value.ToLower() }
  return ''
}
function Get-CmTail([string]$b) {
  <# Everything after the quantity+unit: ", drained", " dry", ", finely chopped". These are COOKING
     instructions the writer put there and they survive the rewrite - dropping them would lose real
     information to fix a units problem. #>
  $m = [regex]::Match([string]$b, '(?i)^\s*(?:\d+\s+\d+/\d+|\d+/\d+|\d+(?:\.\d+)?)?\s*[a-z]*\.?\s*(.*)$')
  if ($m.Success) { return $m.Groups[1].Value.Trim() }
  return ''
}

function Join-CmTail([string]$measure, [string]$tail) {
  <# A tail that already starts with punctuation joins tight: "2 stalks, finely chopped", never
     "2 stalks , finely chopped". #>
  if ($tail -match '^[,;]') { return ($measure + $tail) }
  return ($measure + ' ' + $tail)
}

function Format-CmQty([double]$n) {
  <# Friendly kitchen fractions. A recipe says 1/2 cup, never 0.47 cup. Above 10 nothing is fractional.

     AwayFromZero IS LOAD-BEARING, not a style choice (2026-09-01). PowerShell's [math]::Round defaults
     to banker's rounding and JavaScript's Math.round does not, so this mirror and the scaleBuy it
     mirrors disagreed on every exact .5 at or above 10: "7 tbsp" at 21 servings rendered 11 in the
     browser and 10 here. Measured over the whole catalog at every serving count from 2 to 42 - 321,645
     renders - that was 874 distinct label/serving disagreements, and not one of them was visible from
     either side alone. The browser is what a reader runs, so the browser's rounding is the one that is
     right and this is the copy that had to move. #>
  if ($n -ge 10) { return [string][int][math]::Round($n, [MidpointRounding]::AwayFromZero) }
  $whole = [math]::Floor($n)
  $frac = $n - $whole
  # EXACT THIRDS, NOT 0.3333/0.6667 (2026-09-03). Same lesson as AwayFromZero directly above: fmtCook in
  # tpl2-scaler-prefix.html writes 1/3 and 2/3, and the browser is what a reader runs, so this is the copy
  # that moves. A rounded literal sits 3.33e-5 below a true third, which changes the nearest-bucket winner
  # for any value within that distance of a boundary - "0.29165" rendered 1/3 here and 1/4 in the browser.
  # Invisible from either side alone and invisible to a coarse grid: measured at 1e-6 resolution across the
  # six bucket boundaries, 396 of 30,861 values disagreed before this line changed, 0 after.
  $third = 1.0 / 3.0
  $twoThirds = 2.0 / 3.0
  $names = @(@(0.0,''), @(0.25,'1/4'), @($third,'1/3'), @(0.5,'1/2'), @($twoThirds,'2/3'), @(0.75,'3/4'), @(1.0,''))
  $best = ''; $bestD = 99.0; $carry = 0
  foreach ($p in $names) {
    $d = [math]::Abs($frac - [double]$p[0])
    if ($d -lt $bestD) { $bestD = $d; $best = [string]$p[1]; $carry = $(if ([double]$p[0] -ge 1.0) { 1 } else { 0 }) }
  }
  $whole += $carry
  if ($best -eq '') { if ($whole -lt 1) { return ('{0:0.##}' -f $n) } ; return [string][int]$whole }
  if ($whole -lt 1) { return $best }
  return ([string][int]$whole + ' ' + $best)
}

# THE SHAPES scaleBuy UNDERSTANDS. Kept as script-scope literals so the JS and this twin can be compared
# term for term rather than by eye (see run-scaler-label-test.ps1, which drives the REAL template).
$script:CM_SB_Q    = '(?:\d+\s+\d+/\d+|\d+/\d+|\d+(?:\.\d+)?)'
# Hedge words only. NOT "to taste", NOT "juice of", NOT "for frying": each of those introduces a number
# that is a restatement or a garnish, not the amount the reader measures out.
$script:CM_SB_LEAD = '(?:~|about|approximately|approx\.?|around|roughly|nearly|a\s+scant|scant|a\s+generous|generous|optional)\s*[:,]?\s*'
$script:CM_SB_LBOZ = '^(\s*(?:' + $script:CM_SB_LEAD + ')?)(' + $script:CM_SB_Q + ')\s*(lbs?|pounds?)\.?\s+(' + $script:CM_SB_Q + ')\s*(oz|ounces?)\b'
# ADMITTED 2026-09-03 (queue 2026-09-02-corn06), in lockstep with SMPOF in the JS. Four live rows state
# their amount ONLY as "juice of N limes" / "zest of N limes"; their gram figures double at 28 servings
# while the label sat literal. Admitted for the LEAD path only, exactly as in the JS.
$script:CM_SB_OF   = '(?:juice|zest)\s+of\s+'
# The closed cook-unit list. A second quantity is a PORTION only when it carries one of these. This is the
# whole safety property: the 14 must-not-move labels carry a knife cut, a can size, a per-unit weight, a
# product name or a cook time, and none of those is a portion. Keep it closed; never add "minutes".
$script:CM_SB_UNIT = '(?:tsp|teaspoons?|tbsp|tablespoons?|cups?|oz|ounces?|lbs?|pounds?|cloves?|slices?|sticks?|cans?|g|ml)'
# The closed connector set. "and" is deliberately absent (every "and" label in the corpus is a
# two-ingredient sentence). "to" is present because a range is one amount in parts, and it demands
# whitespace on both sides so it cannot fire inside "cut into 1-inch cubes".
$script:CM_SB_CONN = '^(\s*\+\s*|\s+plus\s+|\s*;\s*|\s+to\s+)'
$script:CM_SB_PART0 = '^(\s*(?:' + $script:CM_SB_LEAD + ')?(?:' + $script:CM_SB_OF + ')?)(' + $script:CM_SB_Q + ')(?![\d/])'
$script:CM_SB_PARTN = '^(\s*(?:' + $script:CM_SB_LEAD + ')?)(' + $script:CM_SB_Q + ')(?=\s*' + $script:CM_SB_UNIT + '\b)'
$script:CM_SB_HEAD = '^(\s*(?:' + $script:CM_SB_OF + ')?)(' + $script:CM_SB_Q + ')'
$script:CM_SB_QUAL = '^(\s*' + $script:CM_SB_LEAD + ')(' + $script:CM_SB_Q + ')'

<#
  THE UNIT NOUN IS PART OF THE QUANTITY (2026-09-03, queue 2026-09-03-539ff0).

  Every arm below re-derived the NUMBER and copied the tail through byte for byte, so a label rendered
  "2 cup grated" and "1 onion, diced" the moment a reader touched the servings control - and, in the
  larger half nobody had measured, "1/2 cups" when a plural label scaled BELOW one. The unit word is as
  much a function of the new quantity as the digits are, so it is re-derived in the same place they are.

  MEASURED before the fix, over all 7,838 live buy labels in meal-prep\recipes-db.json:
    factors 2 / 0.5 / 4 / 0.25, the reviewer's 21-pair word list ....... 3,340 disagreeing renders,
                                                                         328 labels, 564 recipes
    the same, checking connector PARTS as well as the label head ....... 3,377
    the same plus f=1, which every page load runs ....................... 3,616 (239 at base servings)
    the same over every word the live corpus actually carries .......... 3,925 renders, 415 labels
  The fractional side is the bigger half: f=0.25 alone was 1,690 of the 3,377.

  THE RULE IS PLURAL IFF THE VALUE IS GREATER THAN ONE. "1/2 cup" and "1 cup" are singular, "1 1/2 cups"
  and "2 cups" are plural. That is recipe convention, and it is what makes the fractional half real.

  THE TABLE IS CLOSED AND IT IS MEASURED, not guessed. It holds exactly the words that lead the unit
  slot of a live label, plus their counterpart form. A word that is not in it is returned BYTE-IDENTICAL,
  which is the whole safety property, so what is left OUT matters more than what is in:

    ABBREVIATIONS ARE ABSENT ON PURPOSE - tbsp, tsp, lb, oz, g, ml, pk, ct, qt, pt. 541 of the 1,365
    distinct labels lead their tail with one, and none of them takes a plural here ("4 lb", not "4 lbs").
    Format-CmLbOz already agrees the spelled-out weight words on its own path and keeps abbreviations
    invariant; nothing here changes that.

    A MODIFIER IS NOT A UNIT. "13 corn tortillas", "8 garlic cloves", "10 sweet potatoes", "14 large
    eggs", "3 1/2 red bell peppers" all lead the unit slot with a word that is not the unit. corn,
    garlic, sweet, large, medium, small, green, red, yellow, whole, frozen, dried, ground, thin,
    boneless, thick-cut, poblano and root are therefore all EXCLUDED, measured one by one against every
    live label they appear in. Agreeing them would print "13 corns tortillas".

    egg, breast, thigh, stick and bag ARE ON THE REVIEWER'S LIST AND ARE STILL EXCLUDED. Not one of them
    leads the unit slot in any of the 1,365 distinct live labels, so an entry for them could never fire
    and could never be tested - and "egg" is this catalogue's likeliest noun-adjunct trap the day it
    does ("2 egg whites" -> "2 eggs whites"). A word that cannot fire is untestable; a word that can
    fire wrongly is a corruption. Both are worth more than the zero renders they would move today.

  MATCHED ON THE LEADING WORD ONLY, which is the unit slot. A vocabulary word deeper in the tail is
  NOTE text and is never touched: "3 1/2 cups shredded cheddar, added the last 2 minutes" agrees "cups"
  and leaves everything after it alone, and "12 cloves garlic, minced" agrees "cloves" and not "garlic".

  CASE-SENSITIVE, and the dictionary is built with an ORDINAL comparer for exactly that reason:
  PowerShell hashtables are case-insensitive by default and JavaScript objects are not, so a default
  hashtable would have made the two twins disagree on "1 Cup". The only capitalised unit-slot word in
  the whole corpus is the abbreviation "Tbsp", on 3 labels, and an abbreviation is outside the table
  anyway, so a capitalised word rides through untouched either way.
#>
$script:CM_UNIT_PAIRS = 'apple=apples|avocado=avocados|biscuit=biscuits|box=boxes|bun=buns|can=cans|carrot=carrots|carton=cartons|chile=chiles|clove=cloves|cucumber=cucumbers|cup=cups|eggplant=eggplants|head=heads|inch=inches|jalapeno=jalapenos|jar=jars|leaf=leaves|lemon=lemons|lime=limes|mango=mangoes|onion=onions|orange=oranges|ounce=ounces|pack=packs|packet=packets|pepper=peppers|pickle=pickles|potato=potatoes|pound=pounds|quart=quarts|sheet=sheets|slice=slices|stalk=stalks|tablespoon=tablespoons|teaspoon=teaspoons|tortilla=tortillas|tub=tubs|zucchini=zucchinis'
# The leading word of a tail, and nothing else. The lookahead refuses a hyphen as well as a letter so a
# hyphenated compound ("thick-cut slices") is never mistaken for a bare unit noun.
$script:CM_UNIT_RX = '^(\s*)([A-Za-z]+)(?![A-Za-z\-])'
$script:CM_UNIT_FORMS = New-Object 'System.Collections.Generic.Dictionary[string,string[]]' ([StringComparer]::Ordinal)
foreach ($cmPair in $script:CM_UNIT_PAIRS.Split('|')) {
  $cmKv = $cmPair.Split('=')
  $script:CM_UNIT_FORMS[$cmKv[0]] = $cmKv
  $script:CM_UNIT_FORMS[$cmKv[1]] = $cmKv
}

function Set-CmUnitAgreement([double]$v, [string]$tail) {
  <# THE POWERSHELL TWIN of smpUnitAgree() in tpl2-scaler-prefix.html. Make the tail's leading word
     agree with the value that was just rendered in front of it, or return the tail byte-identical.
     ops\audit-twin-drift.ps1 pins the vocabulary and this pattern against the JS copy on every push.

     $v IS THE RENDERED VALUE, NOT THE COMPUTED ONE. See Format-CmScaled below: the caller re-reads the
     number back out of the string it just printed. #>
  $m = [regex]::Match($tail, $script:CM_UNIT_RX)
  if (-not $m.Success) { return $tail }
  $w = $m.Groups[2].Value
  if (-not $script:CM_UNIT_FORMS.ContainsKey($w)) { return $tail }
  $want = $script:CM_UNIT_FORMS[$w][[int]($v -gt 1)]
  if ($want -ceq $w) { return $tail }
  return ($m.Groups[1].Value + $want + $tail.Substring($m.Value.Length))
}

function Format-CmScaled([string]$prefix, [double]$v, [string]$tail) {
  <# THE ONE PLACE A SCALED QUANTITY IS RENDERED. Every arm of Invoke-CmScaleBuy and of
     Invoke-CmScaleConnector returns through here, so it is not possible to add a scaling arm that
     renders a number without agreeing the word beside it - which is the whole reason this is a choke
     point rather than a line repeated per arm. Mirrors smpRender in the JS twin.

     THE NOUN AGREES WITH THE NUMBER THE READER SEES, so the value is read back OUT of the rendered
     string rather than taken from the arithmetic. Format-CmQty can only say seven fractional values, so
     a quantity between them is rounded to one that IS sayable, and the two can land on opposite sides
     of one: "2 1/4 cups" halved is 1.125, an exact tie between 0 and 1/4 that the table breaks
     downward, so the card prints the digit 1. Agreeing against 1.125 printed "1 cups" - the fix
     reproducing its own defect one rounding step later. Measured on the first pass of this change:
     109 renders across 23 labels, every one of them a value that rounds onto 1 from above. A reader
     can only check the noun against the number in front of it, so that is the number it agrees with. #>
  $q = Format-CmQty $v
  return ($prefix + $q + (Set-CmUnitAgreement (Get-CmQty $q) $tail))
}

function Split-CmConnector([string]$s) {
  <# Split on the closed connector set, but ONLY outside parentheses. A bracketed note holds package
     sizes, can counts and restatements - "(2 sticks plus 5 tbsp)", "(10 1/2 teaspoons total)" - and those
     stay exactly as authored, the same rule Test-CmBareNumber already runs on. Mirrors smpSplitConn. #>
  $parts = New-Object System.Collections.Generic.List[string]
  $seps  = New-Object System.Collections.Generic.List[string]
  $d = 0; $last = 0; $i = 0
  while ($i -lt $s.Length) {
    $c = $s[$i]
    if ($c -eq '(') { $d++; $i++; continue }
    if ($c -eq ')') { if ($d -gt 0) { $d-- }; $i++; continue }
    if ($d -eq 0) {
      $m = [regex]::Match($s.Substring($i), $script:CM_SB_CONN, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
      if ($m.Success) {
        [void]$parts.Add($s.Substring($last, $i - $last))
        [void]$seps.Add($m.Groups[1].Value)
        $i += $m.Groups[1].Value.Length; $last = $i; continue
      }
    }
    $i++
  }
  [void]$parts.Add($s.Substring($last))
  return [pscustomobject]@{ parts = $parts; seps = $seps }
}

function Invoke-CmScaleConnector([string]$buy, [double]$f) {
  <# ONE AMOUNT IN PARTS, or $null. $null means the caller falls through to today's behaviour untouched.
     Refusing the WHOLE label when any part fails is the point: moving one half of a two-quantity sentence
     is worse than moving neither. Mirrors smpScaleConn. #>
  $sp = Split-CmConnector $buy
  if ($sp.seps.Count -eq 0) { return $null }
  $out = New-Object System.Collections.Generic.List[string]
  for ($i = 0; $i -lt $sp.parts.Count; $i++) {
    $rx = if ($i -eq 0) { $script:CM_SB_PART0 } else { $script:CM_SB_PARTN }
    $m = [regex]::Match($sp.parts[$i], $rx, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $m.Success) { return $null }
    $q = Get-CmQty $m.Groups[2].Value
    # Per PART, because each part renders its own quantity and carries its own unit slot: a SUM agrees
    # each portion with itself ("1 cup plus 5 tbsp" -> "2 cups plus 10 tbsp"), and a RANGE agrees its
    # unit with the endpoint the unit sits beside ("1/8 to 1/2 tsp", "10 to 11 cloves").
    [void]$out.Add((Format-CmScaled $m.Groups[1].Value ($q * $f) $sp.parts[$i].Substring($m.Value.Length)))
  }
  $res = $out[0]
  for ($i = 0; $i -lt $sp.seps.Count; $i++) { $res += $sp.seps[$i] + $out[$i + 1] }
  return $res
}

function Test-CmBareNumber([string]$s) {
  <# A digit that is NOT inside a parenthetical. A bracketed note holds package sizes, can counts and
     restatements, none of which are the amount being scaled, so they never veto a scale. #>
  $d = 0
  foreach ($c in [char[]]$s) {
    if ($c -eq '(') { $d++ }
    elseif ($c -eq ')') { if ($d -gt 0) { $d-- } }
    elseif ($d -eq 0 -and [char]::IsDigit($c)) { return $true }
  }
  return $false
}

function Format-CmLbOz([double]$totOz, [string]$lbw, [string]$ozw) {
  <# Re-render a scaled ounce total as normalised lb + oz, carrying when the rounded remainder hits 16.
     Abbreviations are invariant ("1 lb", "4 lb"); only the spelled-out words take a plural. #>
  $lb = [math]::Floor($totOz / 16 + 1e-9)
  $oz = $totOz - ($lb * 16)
  $os = if ($oz -gt 0.005) { Format-CmQty $oz } else { '' }
  if ($os -eq '16') { $lb += 1; $os = '' }
  $ozWord = { param($v) if ($ozw -match '^(?i)ou') { if ($v -eq 1) { 'ounce' } else { 'ounces' } } else { 'oz' } }
  if ($lb -lt 1) { $t = if ($os) { $os } else { '0' }; return ($t + ' ' + (& $ozWord (Get-CmQty $t))) }
  $lbWord = if ($lbw -match '^(?i)p') { if ($lb -eq 1) { 'pound' } else { 'pounds' } } else { 'lb' }
  $head = [string][int]$lb + ' ' + $lbWord
  if ($os) { return ($head + ' ' + $os + ' ' + (& $ozWord (Get-CmQty $os))) }
  return $head
}

function Test-CmAuthoredFraction([string]$buy) {
  <# THE POWERSHELL TWIN of smpAuthoredFrac() in tpl2-scaler-prefix.html. Did the AUTHOR write this
     label's quantity as a fraction?

     It asks the question of the QUANTITY only, using the same three shapes in the same order as
     Invoke-CmScaleBuy, so the two can never disagree about which characters are the quantity. A slash
     anywhere else in the label - "1 lb ground beef, 80/20" - is not a quantity and must not count, which
     is why this matches rather than scanning the string.

     Only Invoke-CmScaleBuy calls it, and only at f=1. NEVER use it to decide whether to scale: at any
     other factor the quantity genuinely changes and the fraction table is the intended vocabulary. #>
  $m = [regex]::Match($buy, $script:CM_SB_LBOZ, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
  if ($m.Success) { return ($m.Groups[2].Value.Contains('/') -or $m.Groups[4].Value.Contains('/')) }
  # The connector path answers this too, or a label whose parts are authored fractions is re-snapped at
  # f=1 - the same 4,326-render defect described below, on a new path. Mirrors smpAuthoredFrac.
  $sp = Split-CmConnector $buy
  if ($sp.seps.Count -gt 0) {
    $all = $true; $any = $false
    for ($i = 0; $i -lt $sp.parts.Count; $i++) {
      $rx = if ($i -eq 0) { $script:CM_SB_PART0 } else { $script:CM_SB_PARTN }
      $pm = [regex]::Match($sp.parts[$i], $rx, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
      if (-not $pm.Success) { $all = $false; break }
      if ($pm.Groups[2].Value.Contains('/')) { $any = $true }
    }
    if ($all) { return $any }
  }
  $m = [regex]::Match($buy, $script:CM_SB_HEAD, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
  if ($m.Success) { return $m.Groups[2].Value.Contains('/') }
  $m = [regex]::Match($buy, $script:CM_SB_QUAL, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
  if ($m.Success -and -not (Test-CmBareNumber $buy.Substring($m.Value.Length))) { return $m.Groups[2].Value.Contains('/') }
  return $false
}

function Invoke-CmScaleBuy([string]$buy, [double]$f) {
  <#
    THE POWERSHELL TWIN of scaleBuy() in tpl2-scaler-prefix.html, so the browser behaviour is testable
    without a browser. It exists because the JS version had a real bug that only showed when a reader
    touched the servings control: it multiplied EVERY number in the label, so "1/2 tsp" at 2x became
    "2/4 tsp" (numerator and denominator both scaled) and "2 pk 12 oz" had its pack SIZE scaled too.
    A recipe label is "<quantity> <unit> <note>" - the quantity is the only number allowed to move.
    test-auditors pins this against the JS source so the two cannot drift apart silently.

    WIDENED 2026-09-01, in lockstep with the JS, after nine live recipes were reviewed post-publish:
      COMPOUND  "2 lb 5 oz" is ONE quantity in two units. Moving only the leading number rendered
                "4 lb 5 oz" at 28 servings where the truth is 4 lb 10 oz. 8 labels, 6 live specs.
      QUALIFIED "about 14 cups prepared (...)" and "optional: 2/3 cup ..." never scaled at all, because
                the match is anchored and a word stood in front of the number. 44 labels, 27 specs.
    The qualified path REFUSES a label carrying a second bare quantity outside parentheses ("About 1
    tablespoon salt and 1 1/2 teaspoons black pepper"): moving one half of a two-quantity sentence is
    worse than moving neither, and that shape belongs to repair-range-buy. The plain leading-number path
    is unchanged on purpose, so nothing that scales correctly today can start scaling differently.

    AT BASE SERVINGS AN AUTHORED FRACTION IS LEFT ALONE (2026-09-01), in lockstep with the JS.
    The browser re-renders the ingredient list on every page load, so a reader who never touches the
    servings control still sees this function's output rather than the authored string. Format-CmQty can
    only express the seven values in its table, so an authored eighth cannot survive the round trip:
    "about 7/8 cup grated" parmesan (98 g against a 112 g cup, 0.875 exactly) sits at an exact tie
    between 3/4 and 1, strict less-than takes the first, and the label rendered "about 3/4 cup" - the
    renderer understating a quantity the author measured.

    BOTH OBVIOUS FIXES ARE WRONG, AND BOTH WERE MEASURED OVER ALL 321,645 RENDERS (584 specs x 7,845
    labels x servings 2..42) BEFORE THIS ONE WAS WRITTEN:
      * adding eighths to the table moves 114,800 renders, most of them worse ("2/3 onions" -> "5/8").
      * returning the authored label whenever f=1 moves 4,326 renders, ALL of them worse: 4,299 authored
        labels carry a machine DECIMAL ("2.25 oz", "0.6 onions", "3.3 cans"), and rendering those as
        kitchen fractions is the service this function exists to perform, not a defect.
    The real defect is narrower than either: re-snapping a quantity the AUTHOR already wrote as a
    fraction, where the only possible outcome is a DIFFERENT fraction. A decimal is still formatted. A
    fraction the author chose is returned as written, and only at f=1, where there is nothing to compute.

    A RENDERED QUANTITY IS NOT FINISHED UNTIL THE WORD BESIDE IT AGREES (2026-09-03, queue
    2026-09-03-539ff0), in lockstep with the JS. Every arm here now returns through Format-CmScaled, so
    the noun is re-derived wherever the number is. See the CM_UNIT_PAIRS block above for the measurement
    and for what the closed vocabulary deliberately leaves out.
  #>
  # THE TWO ARMS THAT DO NOT AGREE A NOUN, and why, measured rather than assumed:
  #   the authored-fraction return below renders nothing - it hands back the author's own bytes at f=1.
  #     Of the 20 distinct labels that disagree at f=1, ZERO reach this arm (they are machine decimals
  #     below one, "0.5 cups" -> "1/2 cups", which the LEAD arm renders and now agrees). So the arm that
  #     deliberately does not compute also has nothing to agree, and the 2026-09-01 rule stands intact.
  #   the lb+oz arm's remaining tail is NOTE text, not a unit slot: its unit slot is the lb and the oz,
  #     and Format-CmLbOz has agreed those two words itself since it was written. Running the vocabulary
  #     over "raw, cooked and roughly chopped" would be agreeing a note, which is the one thing this
  #     rule must never do.
  if ($f -eq 1 -and (Test-CmAuthoredFraction $buy)) { return $buy }
  $m = [regex]::Match($buy, $script:CM_SB_LBOZ, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
  if ($m.Success) {
    $tot = ((Get-CmQty $m.Groups[2].Value) * 16 + (Get-CmQty $m.Groups[4].Value)) * $f
    return ($m.Groups[1].Value + (Format-CmLbOz $tot $m.Groups[3].Value $m.Groups[5].Value) + $buy.Substring($m.Value.Length))
  }
  # AFTER the lb+oz pair, BEFORE the plain leading number - the same order as the JS.
  $cn = Invoke-CmScaleConnector $buy $f
  if ($null -ne $cn) { return $cn }
  $m = [regex]::Match($buy, $script:CM_SB_HEAD, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
  if ($m.Success) {
    $q = Get-CmQty $m.Groups[2].Value
    return (Format-CmScaled $m.Groups[1].Value ($q * $f) $buy.Substring($m.Value.Length))
  }
  $m = [regex]::Match($buy, $script:CM_SB_QUAL, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
  if ($m.Success -and -not (Test-CmBareNumber $buy.Substring($m.Value.Length))) {
    $q = Get-CmQty $m.Groups[2].Value
    return (Format-CmScaled $m.Groups[1].Value ($q * $f) $buy.Substring($m.Value.Length))
  }
  return $buy
}

function Get-CmDensity($densItems, [string]$item) {
  <# An item's OWN entry wins, but only if it actually carries a unit. Several items are present in
     densities.json as an empty object - the key exists, the knowledge does not - and treating that as a
     hit sent Fat Free Cheddar to a raw ounce weight while its sibling entry knew a cup is 113 g. Presence
     is not the same as usefulness; fall through to the alias when the entry is empty. #>
  $direct = $null
  if ($densItems.PSObject.Properties.Name -contains $item) { $direct = $densItems.$item }
  if ($direct -and @($direct.PSObject.Properties).Count -gt 0) { return $direct }
  if ($script:CM_ALIAS.ContainsKey($item)) {
    $a = $script:CM_ALIAS[$item]
    if ($densItems.PSObject.Properties.Name -contains $a) {
      $al = $densItems.$a
      if ($al -and @($al.PSObject.Properties).Count -gt 0) { return $al }
    }
  }
  return $direct
}

function Test-CmLabelTrue($densItems, [string]$item, [string]$buy, [double]$grams) {
  <#
    Does the label state a quantity the recipe actually uses?

    THE BURDEN OF PROOF SITS DIFFERENTLY ON THE TWO KINDS OF UNIT, and getting that backwards is what made
    the first version of this pass over the whole defect:

      A MEASURING unit (cup, tbsp, lb, oz) is innocent until proven guilty. If we cannot weigh it we do not
      understand it, and replacing a label we do not understand is how a units fix invents a wrong number.

      A PACKAGE noun (bottle, bag, jar, bulb, carton) is guilty until proven innocent. It is not a cooking
      measure at all - it is what the shopper carries to the till - so it earns its place on an Ingredients
      list ONLY by proving it equals the grams. "1 can" survives because densities knows a can of diced
      tomatoes is 411 g and the recipe uses 411. "1 bottle" against 120 g of soy sauce does not survive,
      and the fact that we have no gram weight for a bottle is not a defence: it is the reason the label
      was never a statement about the food in the first place.
  #>
  if (-not $buy -or $grams -le 0) { return $true }
  $u = Get-CmUnit $buy
  $q = Get-CmQty $buy
  if (-not $u) { return $true }
  $isPkg = ($u -match ("^($script:CM_PKGWORD)$"))
  # ONLY PACKAGE NOUNS ARE IN SCOPE, and the limit is deliberate. A measure-vs-grams disagreement
  # ("1 tbsp" of olive oil carrying 42 g) is a REAL defect, but it is a two-sided one: either the label is
  # wrong or the GRAMS are, and the grams drive the cost and the macros. Rewriting the label to agree with
  # a gram figure that might itself be the error would launder a data bug into a confident-looking
  # measurement - the same shape as a builder stamping today's date on a stale price. Those stay on the
  # engine worklist for someone who can check the source. A package noun has no such ambiguity: it was
  # never a statement about the food in the first place.
  if (-not $isPkg) { return $true }
  if (-not $q) { return $false }
  $per = $null
  $dm = Get-CmDensity $densItems $item
  if ($dm) { foreach ($k in @($u, ($u -replace 's$', ''))) { if ($dm.PSObject.Properties.Name -contains $k) { $per = [double]$dm.$k; break } } }
  if (-not $per -or $per -le 0) { return $false }
  return (([math]::Abs(($q * $per) - $grams) / [math]::Max(1, $grams)) -le 0.25)
}

function Get-CmPrintedValue([string]$q) {
  <#
    What the PRINTED quantity is actually worth, so the unit can agree with the number a reader sees.

    WHY NOT JUST USE $n (2026-08-29). Pluralising off the raw ratio printed "1 cups": 300 g of BBQ sauce
    is 1.10 cups, Format-CmQty rounds it to "1", and 1.10 > 1 so the unit went plural against a bare 1.
    WHY NOT JUST TEST $q -ne '1' EITHER - that was the first attempt and it broke the other end: "1/2" is
    not the string "1", so every half-cup became "1/2 cups". The only rule that holds at both ends is the
    printed VALUE, so parse the mixed number back: "1 3/4" -> 1.75 (plural), "1" -> 1 (singular),
    "1/2" -> 0.5 (singular), "18" -> 18 (plural).
  #>
  $t = ([string]$q).Trim()
  if (-not $t) { return 0 }
  $m = [regex]::Match($t, '^\s*(?:(\d+)\s+)?(\d+)\s*/\s*(\d+)\s*$')   # "1 3/4" or "3/4"
  if ($m.Success) {
    $whole = if ($m.Groups[1].Success) { [double]$m.Groups[1].Value } else { 0 }
    $den = [double]$m.Groups[3].Value
    if ($den -eq 0) { return $whole }
    return ($whole + ([double]$m.Groups[2].Value / $den))
  }
  $v = 0.0
  if ([double]::TryParse($t, [ref]$v)) { return $v }
  return 0
}
function Get-CookMeasure($densItems, [string]$item, [double]$grams, [string]$oldBuy) {
  <# The replacement label. Returns $null when nothing honest can be produced. #>
  if ($grams -le 0) { return $null }
  $tail = Get-CmTail $oldBuy
  # A TAIL THAT RESTATES A QUANTITY IS NOT A COOKING INSTRUCTION (2026-08-20). Get-CmTail exists to carry
  # ", drained" and ", finely chopped" through a rewrite. "(about 18 oz)" is a second statement of the
  # AMOUNT, and the moment the leading measure is rewritten it goes stale - agreeing by luck or
  # contradicting outright. The founding case shipped "1 1/4 lb (about 18 oz)" for 511 g: 567 g stated in
  # front, 510 g in the parentheses, and the display layer appended the true "(511 g)" after both - three
  # quantities on one line, two of them wrong. Only a PURE parenthetical amount is dropped (a number and a
  # measuring unit, nothing else), so "(from 2 lemons)" and every comma tail survive untouched.
  if ($tail -match '(?i)^\(\s*(?:about|approx\.?|~|roughly)?\s*[\d\s/.]+\s*(?:lbs?|oz|g|kg|ml|l|cups?|tbsp|tsp|fl\s*oz)\.?\s*\)$') { $tail = '' }
  $dm = Get-CmDensity $densItems $item
  if ($dm) {
    foreach ($p in $script:CM_PREF) {
      if ($dm.PSObject.Properties.Name -notcontains $p) { continue }
      $per = [double]$dm.$p
      if ($per -le 0) { continue }
      $n = $grams / $per
      if ($n -lt 0.25 -or $n -gt 24) { continue }
      $countable = ($p -in @('clove','each','slice','stalk','leaf','sprig'))
      # A COUNTABLE IS A WHOLE THING. Nobody minces 1 2/3 cloves of garlic or peels 3 1/4 carrots, and
      # printing the fraction makes the list read like a spreadsheet instead of a recipe. Round to the
      # nearest whole, never below one, and let the gram figure beside it carry the precision.
      if ($countable) { $n = [math]::Max(1, [math]::Round($n)) }
      $unit = $p
      # PLURAL FROM THE PRINTED QUANTITY, NOT THE RAW ONE (2026-08-29). This used to test $n before
      # formatting, so any amount that is over one but ROUNDS to one printed the plural against a bare
      # "1": 300 g of BBQ sauce is 1.10 cups, Format-CmQty prints "1", and the line read "1 cups".
      # The number a reader sees is $q, so $q is what has to agree with the unit.
      $q = Format-CmQty $n
      if ((Get-CmPrintedValue $q) -gt 1) {
        if ($p -eq 'cup') { $unit = 'cups' }
        elseif ($countable -and $p -ne 'each') { $unit = $p + 's' }
      }
      $out = if ($p -eq 'each') { $q } else { "$q $unit" }
      if ($tail) { $out = Join-CmTail $out $tail }
      return $out.Trim()
    }
  }
  # weight fallback - always a true statement about the grams. TRUE INCLUDES THE ROUNDING (2026-08-20):
  # Format-CmQty snaps to friendly kitchen fractions, and a snap that is harmless at 1/4 cup can be an 11%
  # error at 1/4 lb. The founding case: 511 g picked lb on the old hard >=340 threshold, snapped
  # 1.127 -> "1 1/4 lb" (567 g), and told the cook to use 11% more broccolini than the macros and cost
  # were computed from - while "18 oz" (510 g, 0.2% off) sat one unit down the ladder. So the unit is now
  # chosen by what SURVIVES friendly formatting: largest unit first, accepted only when the formatted
  # label round-trips within 5% of the grams (the same tolerance the macros gate holds recipes to), else
  # the next unit down. Grams are the floor and are stated exactly, so the ladder always lands somewhere
  # honest. The friendly fraction is kept whenever it is accurate: 567 g still reads "1 1/4 lb".
  $out = $null
  foreach ($cand in @(@(453.592, 'lb', 340), @(28.3495, 'oz', 28), @(1, 'g', 0))) {
    if ($grams -lt [double]$cand[2]) { continue }
    $q = Format-CmQty ($grams / [double]$cand[0])
    $back = (Get-CmQty $q) * [double]$cand[0]
    if (([math]::Abs($back - $grams) / [math]::Max(1, $grams)) -le 0.05) { $out = "$q $($cand[1])"; break }
  }
  if (-not $out) { $out = ('{0:0.##} g' -f $grams) }   # unreachable in practice; never return nothing
  # Join-CmTail, same as the density path: a comma tail joins tight ("18 oz, drained", never "18 oz , drained").
  if ($tail) { $out = Join-CmTail $out $tail }
  return $out.Trim()
}

# ---------------------------------------------------------------------------------------------------
# RANGE LABELS. A label stating "2-3 cloves" names two quantities where the card can only mean one, and
# Invoke-CmScaleBuy above moves only the first of them - so doubling the servings renders "4-3 cloves".
# The full account of the defect, and of why the range is resolved rather than the widget taught to
# scale both ends, is in the header of pipeline\repair-range-buy.ps1.
#
# THESE LIVE HERE, not in that script, because sync-recipesdb-buy.ps1 needs the same predicate to decide
# whether a recipes-db label is in the class, and a script that runs a catalog pass at the bottom cannot
# be dot-sourced for its functions. One matcher, both dot-source it - the same arrangement as
# spec-contradiction-lib.
# ---------------------------------------------------------------------------------------------------

# A number: mixed fraction, bare fraction, or decimal. The FRACTION alternatives must come first - with
# the plain-number branch leading, "1/4-1/2" parses its high end as "1" (the regex matches "1", is
# satisfied, and never sees "/2"), which silently turns a 1/4-1/2 range into a 1/4-1 one.
$script:CM_NUM = '(?:\d+\s+\d+/\d+|\d+/\d+|\d+(?:\.\d+)?)'
# Range, unit, note. The dash class carries the en and em dashes because a writer pasting from a source
# page brings whatever that page used.
$script:CM_RANGE_RX = '^\s*(' + $script:CM_NUM + ')\s*[-–—]\s*(' + $script:CM_NUM + ')\s*([A-Za-z]+)?\.?\s*(.*)$'
# Units that never take a plural s. The abbreviations are invariant in recipe writing ("2 tbsp", never
# "2 tbsps"); spelled-out forms do pluralise and are handled by the general rule.
$script:CM_INVARIANT = @('tsp', 'tbsp', 'oz', 'fl', 'lb', 'g', 'kg', 'ml', 'l', 'qt', 'pt')

function Test-RangeBuy {
  <# Is this label in scope? A range at the HEAD of the label, where the quantity belongs. A hyphen
     elsewhere is not a range: "12-oz bag" and "1 lb (16-oz package)" are ordinary labels, and the
     anchor plus the requirement of a NUMBER after the dash is what keeps them out. #>
  param([Parameter(Mandatory)][AllowEmptyString()][string]$Buy)
  return [regex]::IsMatch($Buy, $script:CM_RANGE_RX)
}

function Resolve-RangeBuy {
  <#
    Turn one range label into the single quantity the grams state, or return $null with the reason.
    Pure, so every refusal below is a case the self-test can pin.

    The refusals matter more than the rewrites. A range whose unit we cannot weigh ("3-4 dry chiles")
    is a label we do not understand, and the honest move is to leave it and say so - the same rule
    Get-CookMeasure follows. Inventing a number for it would be exactly the defect this exists to
    remove, committed by the tool instead of the writer.
  #>
  param(
    [Parameter(Mandatory)][AllowEmptyString()][string]$Buy,
    [Parameter(Mandatory)][AllowEmptyString()][string]$Item,
    [Parameter(Mandatory)][double]$Grams,
    $Dens = $null
  )
  $m = [regex]::Match($Buy, $script:CM_RANGE_RX)
  if (-not $m.Success) { return [pscustomobject]@{ New = $null; Reason = 'not a range label' } }
  if ($Grams -le 0) { return [pscustomobject]@{ New = $null; Reason = 'the spec states no grams to resolve against' } }
  $unit = [string]$m.Groups[3].Value
  $tail = [string]$m.Groups[4].Value
  if (-not $unit) { return [pscustomobject]@{ New = $null; Reason = 'the range names no unit (a bare count - repair-unitless-buy owns that shape)' } }
  if (-not $Dens) { return [pscustomobject]@{ New = $null; Reason = 'no densities loaded' } }

  # Weigh the unit the WRITER named, not one of our choosing. The unit was never the bug, and swapping a
  # correct "1 tsp" for a technically-equal "1/3 tbsp" would be a readability regression dressed up as a
  # fix. Spelled-out forms resolve to the abbreviation densities.json actually stores.
  $stem = ($unit -replace 's$', '').ToLower()
  $keys = @($unit.ToLower(), $stem)
  if ($stem -eq 'teaspoon')   { $keys += 'tsp' }
  if ($stem -eq 'tablespoon') { $keys += 'tbsp' }
  $dm = Get-CmDensity $Dens $Item
  $per = $null
  if ($dm) { foreach ($k in $keys) { if ($k -and $dm.PSObject.Properties.Name -contains $k) { $per = [double]$dm.$k; break } } }
  if (-not $per -or $per -le 0) {
    return [pscustomobject]@{ New = $null; Reason = ("no weight for a '{0}' of {1} - refusing to guess" -f $unit, $Item) }
  }

  $n = $Grams / $per
  # A COUNTABLE IS A WHOLE THING - the same rule Get-CookMeasure follows, for the same reason: nobody
  # minces 8 1/3 cloves of garlic. The gram figure printed beside it carries the precision.
  $countable = ($stem -in @('clove', 'each', 'slice', 'stalk', 'leaf', 'sprig'))
  if ($countable) { $n = [math]::Max(1, [math]::Round($n)) }
  if ($n -le 0) { return [pscustomobject]@{ New = $null; Reason = 'the grams resolve to nothing of that unit' } }

  # Plural follows the NEW quantity, not the old label: "2-3 cloves" resolving to one clove must not
  # print "1 cloves", and "1/2-1 cup" resolving to three must not print "3 cup".
  #
  # AND IT FOLLOWS THE NUMBER THE READER SEES, not the raw division. Format-CmQty rounds to kitchen
  # fractions, so 2 g of cayenne over 1.8 g per tsp is 1.11 - greater than one - but prints as "1".
  # Pluralising on the raw value gave "1 teaspoons"; the rendered string is the only quantity on the
  # card, so it is the one the noun has to agree with.
  $shown = Format-CmQty $n
  $shownVal = Get-CmQty $shown
  $outUnit = $unit
  if ($stem -notin $script:CM_INVARIANT) {
    if ($shownVal -gt 1) { $outUnit = $stem + 's' } else { $outUnit = $stem }
    # keep the writer's capitalisation of the first letter
    if ($unit.Substring(0, 1) -cmatch '[A-Z]') { $outUnit = $outUnit.Substring(0, 1).ToUpper() + $outUnit.Substring(1) }
  }

  $out = ($shown + ' ' + $outUnit)
  if ($tail) { $out = Join-CmTail $out $tail }
  return [pscustomobject]@{ New = $out.Trim(); Reason = '' }
}
