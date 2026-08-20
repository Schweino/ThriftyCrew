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
  <# Friendly kitchen fractions. A recipe says 1/2 cup, never 0.47 cup. Above 10 nothing is fractional. #>
  if ($n -ge 10) { return [string][int][math]::Round($n) }
  $whole = [math]::Floor($n)
  $frac = $n - $whole
  $names = @(@(0.0,''), @(0.25,'1/4'), @(0.3333,'1/3'), @(0.5,'1/2'), @(0.6667,'2/3'), @(0.75,'3/4'), @(1.0,''))
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

function Invoke-CmScaleBuy([string]$buy, [double]$f) {
  <#
    THE POWERSHELL TWIN of scaleBuy() in tpl2-scaler-prefix.html, so the browser behaviour is testable
    without a browser. It exists because the JS version had a real bug that only showed when a reader
    touched the servings control: it multiplied EVERY number in the label, so "1/2 tsp" at 2x became
    "2/4 tsp" (numerator and denominator both scaled) and "2 pk 12 oz" had its pack SIZE scaled too.
    A recipe label is "<quantity> <unit> <note>" - the quantity is the only number allowed to move.
    test-auditors pins this against the JS source so the two cannot drift apart silently.
  #>
  $m = [regex]::Match($buy, '^(\s*)(\d+\s+\d+/\d+|\d+/\d+|\d+(?:\.\d+)?)')
  if (-not $m.Success) { return $buy }
  $q = Get-CmQty $m.Groups[2].Value
  return ($m.Groups[1].Value + (Format-CmQty ($q * $f)) + $buy.Substring($m.Value.Length))
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
      # plural the moment there is more than one of the thing: "1 3/4 cup" reads wrong, "1 3/4 cups" is
      # right. tbsp and tsp are already correct in both numbers and are left alone.
      if ($n -gt 1) {
        if ($p -eq 'cup') { $unit = 'cups' }
        elseif ($countable -and $p -ne 'each') { $unit = $p + 's' }
      }
      $q = Format-CmQty $n
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
