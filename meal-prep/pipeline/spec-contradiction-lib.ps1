<#
  spec-contradiction-lib.ps1 - the shared reading of a recipe spec's self-contradictions.

  ONE COPY ON PURPOSE. audit-spec-contradictions.ps1 reports these and repair-spec-contradictions.ps1 fixes
  them; if each carried its own matcher they would disagree the first time either was tightened, and the
  audit would then certify a repair it did not actually describe. That is the same class of bug as
  specs\prose drifting from the specs, one level up, so the matcher lives here and both dot-source it.
#>

# cal / cals / calorie / calories. The singular is not a nicety: head.description writes "a 499 calorie
# bowl", and a pattern that only knew cal\b|calories\b matched neither - so the founding STAT-PROSE case was
# invisible in one of the two fields it lived in.
$script:RX_CAL     = '(?i)\b(\d{3,4})\s*cal(?:orie)?s?\b'
# DECIMAL-BLIND, AND IT REPORTED THE FRAGMENT AS THE CLAIM (2026-08-27). The leading \b sat happily
# between the '.' and the '3' of "47.3g protein", so the matcher captured "3g protein" and the gate
# reported 'says 3g protein, stat says 47' - against a spec whose 47.3 was CORRECT and had already
# been allowed by a prior ruling. It went red on chicken-rice-and-broccoli and, because a wave cannot
# publish over a red shared gate, it blocked a wave containing neither that recipe nor that number.
# Measured: "packs 8.5 g protein" was read as 5 the same way.
#
# The guard is (?<![\d.]) - a digit run preceded by a digit or a decimal point is a FRAGMENT, never a
# claim. The capture then takes the whole decimal rather than exempting it, which keeps the check
# alive: "99.9g protein" on a 47 g stat still fires. Blinding the matcher to decimals would have
# cleared the false positive by giving up the true ones, and every high-protein card writes decimals.
# The consumer casts with [int], which ROUNDS in PowerShell ([int]'47.3' -> 47), so 47.3 agrees with a
# stat of 47 and no finding is raised - which is the behaviour the prior ruling described.
$script:RX_PROTEIN = '(?i)(?<![\d.])(\d{1,3}(?:\.\d+)?)\s*(?:g\b|grams?\b)\s*(?:of\s+)?protein'
# CARBS AND FAT (2026-09-01). THIS CLASS COULD NOT SEE HALF THE STAT BLOCK, and three live cards paid
# for it. lib\render-tokens.ps1 grew {{carbs}} and {{fat}} on 2026-08-31; nothing swept the literals
# behind them and nothing read them, so bbq-chicken-rice-bowls shipped "just 4 grams of fat" on a 10 g
# stat, hot-honey-chicken-bowls "only 3 grams of fat" on a 10, ground-beef-gyro-bowls "just 11 grams of
# fat" on a 13. Each one was a nutrition claim on paid content, and each one sat beside a stat block
# stating the true number on the same page. That is the definition of a contradiction this class exists
# to read, and it was invisible purely because the pattern list stopped at two macros.
#
# NOT A NEW RULE - A TWIN THAT WAS ONLY EVER BUILT ON ONE SIDE. coverage_check.py has carried this exact
# reading as RX_MACRO since the v3 prose gate, with the comment "NO POWERSHELL TWIN: spec-contradiction-
# lib carries calorie and protein patterns only". The Python half ran per-recipe before QA, the
# PowerShell half gates the catalogue at publish, and the catalogue half was the one that could not see
# fat. Both sides are now registered in ops\twin-rules.json as prose-macro-claim so the next tightening
# cannot reach one and miss the other, which is the failure this exact pair already produced once.
$script:RX_MACRO = '(?i)(?<![\d.])(\d{1,3}(?:\.\d+)?)\s*(?:g\b|grams?\b)\s*(?:of\s+)?(carbohydrates?|carbs?|fat)\b'

# BOUNDED CALORIE CLAIMS (2026-08-07, Brad's ruling). RX_CAL exists to catch a STALE number: a card that
# says "499 calories" when its stat says 373 is quoting a figure that moved. It cannot distinguish that
# from a TRUE UPPER BOUND. "under 400 calories" on a 396-cal recipe is not stale, it is correct, and it is
# the entire premise of the wrapped-burrito format (every one of those recipes is capped at 400 by design).
# So a match preceded by an upper-bound word is exempt ONLY WHEN THE BOUND IS ACTUALLY SATISFIED.
# "under 300 calories" on a 396-cal recipe still fires, because that claim is false - which is the whole
# point: this narrows the rule to true statements, it does not switch it off. A bare "400 calories" with no
# bound word still fires too.
# NOT extended to protein: a LOWER bound ("at least 25g protein") is the mirror case and would need the
# comparison inverted. No recipe currently needs it, and an untested second branch is how an exemption
# becomes a hole. Fixtures live in pipeline\test-guards.ps1.
# HARDENED 2026-08-07 (audit pass 4, both holes measured at ZERO occurrences across 542 live + 29 batch
# specs before changing anything, so this is prophylactic):
#   (?<!not\s)(?<!never\s)  a NEGATED bound is not a bound. "not under 400 calories" on a 396-cal recipe
#                           claims the opposite of what the exemption assumes, and would have passed.
#   (?<![a-z])              without a left boundary any word ENDING in a bound word reads as one
#                           ("thunder 400 calories"). The lookback is a raw 24-char window, not a token
#                           scan, so the boundary has to be in the pattern.
# Both failure modes leaked toward PASSING a false claim, which is the direction an exemption must never
# fail in. Fixtures for both are in pipeline\test-guards.ps1.
$script:RX_CAL_BOUND = '(?i)(?<!\bnot\s)(?<!\bnever\s)(?<![a-z])(?:under|below|beneath|less than|fewer than|no more than|at most)\s*$'
function Test-MacroClaimContradiction {
  <# Reads what the sentence actually CLAIMS, then checks that claim against the stat.
     A bound word makes it "figure < N", true only when the real figure is strictly below N.
     With no bound word the figure is a direct quote and must BE the stat, which is the original rule.
     Written this way rather than as an equality test plus an exemption because the equality shortcut
     silently passed "under 396 calories" on a 396-cal recipe: a false claim that skipped the bound
     logic entirely by matching the stat. Measured before tightening - zero live specs are affected.

     NAMED FOR MACROS, NOT CALORIES, SINCE 2026-09-01, because carbs and fat now read through it and a
     function called Test-CalClaimContradiction deciding a fat claim is a comment that lies. The rename
     is why test-guards' mirror pointer moved in the same commit: that pointer named a function that no
     longer existed for one revision once already, and a mirror contract with a dead address is the same
     failure as the mirror drifting, only harder to notice.

     IT PROVED ITSELF ON CARBS IMMEDIATELY. stuffed-chicken-breast said "with under 10 grams of carbs"
     beside a stat block reading 10 g carbs - the exact-equal bound this function exists to catch, sitting
     live on a card, invisible for as long as the class stopped at calories and protein. #>
  param([string]$Text,[int]$MatchIndex,[int]$Claimed,[int]$Actual)
  $start = [Math]::Max(0, $MatchIndex - 24)
  $bounded = ($Text.Substring($start, $MatchIndex - $start) -match $script:RX_CAL_BOUND)
  if($bounded){ return ($Actual -ge $Claimed) }
  return ($Claimed -ne $Actual)
}
# UNMEASURABLE-QTY: a quantity below a QUARTER of its stated unit is one no kitchen can act on. There is
# no quarter-tablespoon in the drawer and no home scale that resolves 0.07 oz, so the reader is being
# handed a number they can only ignore.
#
# ZERO WAS ONLY THE EXTREME CASE. Until 2026-08-05 this class read `0\s*(lb|oz|...)` and could see nothing
# else, so "Bay Leaves: 0 oz" failed the gate while "Bay Leaves: 0.07 oz" - the same three grams, one
# rounding step away - passed it 44 times. Fixing the 15 zero labels moved four of them to 0.11 oz and the
# gate went quiet, which is the failure mode of measuring a defect by the spelling of its worst example.
# The threshold is the same 0.25 the repair uses to decide a label is usable; repair-unmeasurable-qty's
# self-test asserts against this line so the two cannot drift.
$script:UNMEASURABLE_UNDER = 0.25
# Adjectives that sit between the quantity and the ingredient name on a head line ("5.5 cups DRY rice").
# They are skipped when testing whether the display key is the head line's trailing ingredient phrase.
$script:HEAD_ADJ = '(?:dry|fresh|frozen|minced|grated|ground|chopped|diced|sliced|shredded|boneless|skinless|large|small|whole|low\s*sodium|reduced\s*fat|extra\s*virgin|uncooked|cooked|raw|lean)'

function Get-DisplayQuantities($spec) {
  <# name -> {n, u} for every costed display line that states a quantity in a countable unit. #>
  $disp = @{}
  foreach ($li in @($spec.ingredients_display)) {
    $s = ([string]$li) -replace '<[^>]+>', ''
    $nm = [regex]::Match($s, '^\s*([^:(]+?)\s*(?:\([^)]*\))?\s*:')
    if (-not $nm.Success) { continue }
    $key = ($nm.Groups[1].Value.ToLower() -replace '[^a-z ]', '').Trim()
    $q = [regex]::Match($s, ':\s*([\d.]+)\s*(cups?|tbsp|tsp|lbs?|oz)\b')
    if ($key -and $q.Success) { $disp[$key] = @{ n = [double]$q.Groups[1].Value; u = ($q.Groups[2].Value -replace 's$', '') } }
  }
  return $disp
}

function Get-HeadQtyMismatch([string]$headLine, $disp) {
  <#
    Decide whether a head.recipeIngredient line disagrees with the costed line for the SAME ingredient.
    Returns $null unless the answer is unambiguous. Three refusals, each one a wrong rewrite this function
    actually produced before they were added:

    1. MORE THAN ONE QUANTITY ON THE LINE. "4.75 tbsp minced garlic and 1.5 tbsp grated ginger" names two
       ingredients; matching on ginger and then rewriting the LEADING number turned garlic's 4.75 into 1.5.
       A line with two quantities has no single leading amount to correct.
    2. THE KEY IS NOT THE TRAILING INGREDIENT. "0.75 cups rice vinegar" matched the key 'rice' from the
       RICE display line and would have rewritten rice vinegar to 3.75 cups. The ingredient a head line is
       about is the phrase it ENDS with, not any word it contains.
    3. TWO KEYS TIE. If two display ingredients both qualify, nothing in the line says which amount to use.
  #>
  $s = [string]$headLine
  $qs = @([regex]::Matches($s, '(?<![\d.])[\d.]+\s*(?:cups?|tbsp|tsp|lbs?|oz)\b'))
  if ($qs.Count -ne 1) { return $null }                                   # refusal 1
  $q = [regex]::Match($s, '^\s*([\d.]+)\s*(cups?|tbsp|tsp|lbs?|oz)\b')
  if (-not $q.Success) { return $null }
  $u = ($q.Groups[2].Value -replace 's$', '')
  # Everything after the quantity, lower-cased and reduced to letters and spaces. Then a LADDER of readings:
  # the full phrase first, then the phrase with one leading adjective removed, and so on. The key has to
  # EQUAL one of them - equality, not "ends with" - and the least-stripped reading wins.
  #   equality, because "wild rice" ENDS WITH "rice" and is not the plain rice the recipe costs; accepting
  #     that rewrote a wild-rice casserole's head line to the plain-rice amount and left the name wrong,
  #     which trades a visible contradiction for a quieter one.
  #   the ladder, because the adjective list cannot be applied blindly: "93/7 ground turkey" is an
  #     INGREDIENT whose name begins with 'ground', and stripping it first left "turkey", which matched
  #     nothing and silently dropped a real 3.5 lb vs 5.25 lb disagreement.
  $tail0 = ($s.Substring($q.Length)).ToLower()
  $tail0 = ($tail0 -replace '[^a-z ]', ' ')
  $tail0 = ($tail0 -replace '\s+', ' ').Trim()
  if (-not $tail0) { return $null }
  $ladder = New-Object System.Collections.Generic.List[string]
  $t = $tail0
  $ladder.Add($t)
  while ($t -match ('^' + $script:HEAD_ADJ + '\s+')) {
    $t = ($t -replace ('^' + $script:HEAD_ADJ + '\s+'), '').Trim()
    if (-not $t) { break }
    $ladder.Add($t)
  }

  $best = $null; $bestLen = -1; $tie = $false
  foreach ($cand in $ladder) {
    foreach ($key in $disp.Keys) {
      if ($disp[$key].u -ne $u) { continue }
      if ($key -ne $cand) { continue }                                    # refusal 2: equality only
      if ($key.Length -gt $bestLen) { $best = $key; $bestLen = $key.Length; $tie = $false }
      elseif ($key.Length -eq $bestLen -and $disp[$key].n -ne $disp[$best].n) { $tie = $true }
    }
    if ($best) { break }                                                  # least-stripped reading wins
  }
  if (-not $best -or $tie) { return $null }                               # refusal 3
  $have = [double]$q.Groups[1].Value
  $want = [double]$disp[$best].n
  if ([math]::Abs($have - $want) -le ([math]::Max(0.05, $want * 0.1))) { return $null }
  return @{ key = $best; unit = $u; head = $have; costed = $want; prefixLen = $q.Groups[1].Length + $q.Index }
}

# ---- UNUSED: is everything bought also used? ------------------------------------------------------
# Words that describe a FORM rather than an identity. They cannot carry a mention on their own: a step
# saying "ground" or "fresh" tells you nothing about which ingredient it means.
$script:UNUSED_STOP = @('fresh','dried','ground','shredded','grated','minced','chopped','diced','sliced',
    'frozen','canned','whole','large','small','light','reduced','free','low','sodium','value','great',
    'generic','boneless','skinless','lean','raw','cooked','sweet','hot','mild','plain','style')

function Test-IngredientNamedInSteps {
    <#
      Does any step name this ingredient? Returns $true when it does.

      MATCHING THE HEAD NOUN ALONE WAS THE BUG, and it made this class useless. Until 2026-08-05 the rule
      took the LAST word of the display key and required it verbatim in the steps, so "Parmesan Cheese"
      was searched for as "cheese" while the step said "stir in the PARMESAN", and "Boneless Skinless
      Chicken Breast" was searched for as "breast" while the step said "cube the CHICKEN". English names
      an ingredient by its distinctive word, not its category noun. That single rule produced 150 of the
      150 findings this class carried, essentially all of them false, and a gate that cries wolf 149 times
      out of 150 is one nobody reads - the same reasoning that kept PHANTOM off the board until its noise
      was cut.

      SO A DISTINCTIVE TOKEN COUNTS. But token matching alone over-forgives in the other direction, and
      the PHANTOM matcher already names the trap: a step saying "rice" would forgive a bought Rice
      Vinegar.

      WHAT MAKES A SHARED WORD AMBIGUOUS IS NOT THAT IT IS SHARED. It is that another ingredient has
      ALREADY CLAIMED it by being exactly that word. A recipe buying Rice and Rice Vinegar spends its
      "rice" on the Rice - so "cook the rice" says nothing about the vinegar. A recipe buying Chicken
      Breast and Chicken Broth has no ingredient simply called "chicken", so "cube the chicken" is
      unclaimed and can only mean the breast. Requiring a wholly UNSHARED token instead was this
      function's own second bug: it left 25 findings that were the first bug one level down, reporting
      Chicken Breast in a recipe whose step cubes the chicken, Black Pepper where the step says salt and
      pepper, Ground Beef where the step browns the beef.

      An ingredient with nothing left to look for falls back to demanding its full name rather than
      guessing.
    #>
    param([string]$Key, [string[]]$AllKeys, [string]$Steps)
    $mine = @(($Key -split ' ') | Where-Object { $_.Length -ge 4 -and $script:UNUSED_STOP -notcontains $_ })
    if ($mine.Count -eq 0) { $mine = @(($Key -split ' ') | Where-Object { $_ }) }
    # a word ANOTHER ingredient is wholly named by belongs to that ingredient, not this one
    $claimed = @{}
    foreach ($other in $AllKeys) {
        if ($other -eq $Key) { continue }
        if ($other -notmatch ' ') { $claimed[$other] = 1 }
    }
    $usable = @($mine | Where-Object { -not $claimed.ContainsKey($_) })
    if ($usable.Count -eq 0) {
        # every word this ingredient has is spoken for - demand the whole name rather than guess
        return ($Steps -match ('\b' + [regex]::Escape($Key)))
    }
    foreach ($t in $usable) {
        if ($Steps -match ('\b' + (Get-PluralPattern $t))) { return $true }
    }
    return $false
}

# SINGULAR/PLURAL. "Cherry Tomatoes" is bought and every step says "dice the TOMATO" - the verbatim
# match failed on the final 's' and the ingredient read as never used, on a live recipe that plainly
# uses it (chili-lime-chicken-burrito, found 2026-08-16). This is UNUSED-only: PHANTOM has its own
# matcher (PHANTOM_TAIL / PHANTOM_FREE / PHANTOM_MADE below) and is untouched by this, so the gate that
# just caught nine real defects keeps exactly the strictness it had.
#
# Deliberately NOT a stemmer. Only the regular English plural endings, and only as an OPTIONAL suffix,
# so the match can gain "tomato"<->"tomatoes" without gaining "rice"<->"riced" - the simile that already
# produced a false phantom the same day. A looser rule here forgives an ingredient that is genuinely
# never used, which is the one thing this class exists to find.
function Get-PluralPattern {
    param([string]$Token)
    $t = [regex]::Escape($Token)
    if ($Token -match '(?i)ies$')      { return ('(?:' + $t + '|' + [regex]::Escape($Token.Substring(0, $Token.Length - 3)) + 'y)') }
    if ($Token -match '(?i)(ss|us)$')  { return $t }                       # 'grass', 'hummus' - the s is not a plural
    if ($Token -match '(?i)es$')       { return ('(?:' + [regex]::Escape($Token.Substring(0, $Token.Length - 2)) + '(?:es)?)') }
    if ($Token -match '(?i)s$')        { return ('(?:' + [regex]::Escape($Token.Substring(0, $Token.Length - 1)) + 's?)') }
    return ('(?:' + $t + '(?:e?s)?)')
}

# ---- PHANTOM: a step names an ingredient the recipe never buys -----------------------------------
# The mirror of UNUSED. UNUSED asks "is everything bought also used"; PHANTOM asks "is everything used
# also bought", and only the second one can see slow-cooker-dr-pepper-pulled-pork-bowls, whose step 2
# pours a zero-sugar soda that appears in NO ingredient list, cost line or scaler row. The braise cannot
# be made as shopped and the recipe is named after the missing bottle.
#
# This was measured and deliberately NOT shipped on 2026-08-02 (out\fidelity\engine-pass-notes.md): the
# naive reading gave 295 hits, almost all containment artifacts, and "a gate that cries wolf gets
# switched off". Six rules below are what took it from 555 raw hits to a readable handful. Each one is a
# false positive this matcher actually produced against the live catalogue.

# A noun that turns the food name in front of it into a DIFFERENT food: "apple cider VINEGAR", "rice
# WINE", "milk CHOCOLATE". When the compound is not itself a name we know, we cannot judge it, so we say
# nothing rather than report the head word.
$script:PHANTOM_TAIL = '(?:vinegar|oil|sauce|powder|juice|milk|wine|paste|seed|seeds|extract|butter|salt|sugar|flour|stock|broth|cream|water|syrup|zest|flakes|leaves|chocolate|cake|cakes|bread|crumbs)'
# "sugar-free BBQ sauce" names sugar in order to say the sauce has none of it. X-free is the absence of
# X, never its use - the one case where a match must be read as the opposite of a mention.
$script:PHANTOM_FREE = '^\s*[-\s]?free(?![a-z])'
# A step that MAKES something is not shopping for it: four recipes blend tomatillos, chiles and cilantro
# "into a rough salsa", and salsa is a name this estate knows, so all four reported a phantom salsa they
# cook in the step. Anchored on "into a/the" and "make a/the" rather than on the verb, because the verb
# can be a whole clause away ("blend them with the jalapenos, most of the cilantro, and the garlic into
# a rough green salsa"). Bare "to the" is deliberately NOT accepted - "add the broth to the rice" would
# swallow a real one.
$script:PHANTOM_MADE = '(?:^|\s)into\s+(?:a|the)\s+(?:\w+\s+){0,3}$|(?:^|\s)makes?\s+(?:a|the)\s+(?:\w+\s+){0,3}$'
# A comparison is not an instruction. "honey burns faster THAN sugar does" is a warning about the honey.
$script:PHANTOM_CMP = '(?:^|\s)than\s+$'
# A word right after a subject pronoun is a VERB, whatever else it spells. "day-old rice, so it FRIES up
# instead of turning mushy" is the ingredient Fries, spelled identically, in the one grammatical slot an
# ingredient can never occupy. English does not put a bare noun there.
$script:PHANTOM_SUBJ = '(?:^|\s)(?:it|they|we|you|i|he|she|that|this|which|who)\s+$'
# A CONSTITUENT of a bought product is not a missing ingredient. baked-ziti's make_it says the turkey
# "soaks up the tomato flavor" - the marinara IS the tomato, and the matcher reported a phantom Tomato in a
# recipe that buys Marinara Sauce (the one PHANTOM finding on the live board for weeks, 2026-08-08). Keyed
# on a token of the OWNED ingredient; the values are foods a step may name that the product accounts for.
# Deliberately tiny: each entry is a measured false positive, not a food-knowledge project.
#
# KEYS AND VALUES ARE PHRASES, EVERY WORD REQUIRED (2026-08-28). They were single tokens until the
# coconut entry below needed a two-word key. Keyed on the single token 'coconut' with the single value
# 'oil', that entry would have forgiven a step naming Olive Oil, Sesame Oil or Vegetable Oil in any
# recipe holding a can of coconut milk, because 'oil' is a token of all three. So both sides now match
# on ALL of their words: the owned line must carry every word of the key, the named food every word of
# the value. The two entries here are single-word and read identically under the stricter rule.
$script:PHANTOM_CONSTITUENT = @{
  'marinara' = @('tomato')
  'ketchup'  = @('tomato')
}

# A SUBSTANCE THAT COMES OUT OF A BOUGHT INGREDIENT IS NOT SHOPPED FOR (2026-08-28).
# beef-rendang-rice-bowls: "the beef starts frying in the coconut oil THAT SEPARATES OUT and everything
# turns deep brown". The recipe buys four cans of Coconut Milk; the oil renders out of it during the
# reduction, which is the entire technique the step is describing. Nobody puts coconut oil in the basket.
#
# TWO CONDITIONS, AND IT NEEDS BOTH - this is the merge of two sessions' fixes for the same finding, and
# each caught something the other missed. Sentence shape alone forgives "the butter that separates out"
# in a recipe that buys no butter and no cream: prose can ASSERT an emergence that nothing in the basket
# could produce. Ownership alone forgives "HEAT the coconut oil" in any recipe holding a can of coconut
# milk, which is a step asking for a fat the shopper never bought. Requiring the phrasing AND the source
# is strictly tighter than either, and both floors are frozen in the self-test.
#
# Kept SEPARATE from PHANTOM_CONSTITUENT above on purpose. A constituent is simply PRESENT - the marinara
# IS the tomato however the sentence is worded - so that map must stay unconditional. A rendered
# substance only exists when the cooking makes it, so its map may not be.
$script:PHANTOM_RENDERED = '^\s+(?:that\s+|which\s+)?(?:separates|renders|cooks|melts|comes|leaches|fries)\s+out\b'
$script:PHANTOM_RENDERED_FROM = @{
  'coconut milk' = @('coconut oil')
}

# AN ALTERNATIVE THE READER CAN ALREADY MEET IS NOT A MISSING INGREDIENT (2026-08-28).
# mediterranean-chicken-w-marinade: "a casserole dish sprayed with cooking spray OR BRUSHED WITH OLIVE
# OIL". Olive Oil is on the ingredient list, so the step offers two ways to do one thing and the reader
# can already do it. Only fires when the OTHER branch names a food this recipe owns - a bare "or" is not
# enough, or "salt or pepper to taste" would excuse a genuinely missing salt.
#
# The card was ALSO fixed (the unbought branch is gone from the prose, 0f1a70ae), so this rule has no
# live case today. It stays because the shape is real recipe English and the next one should not re-open
# the gate - and because the floor below is what proves it is a rule and not a switch.
$script:PHANTOM_ALT = '^\s+or\s+'
$script:PHANTOM_ALT_SPAN = 90

# NOT A RULE, AND DELIBERATELY SO: "a food named in the DISH TITLE is assembled, not shopped".
# It was proposed and built for blackened-chicken-with-mango-salsa's "Start with the salsa", and it is
# unsafe at any width. This class was founded on slow-cooker-dr-pepper-pulled-pork-bowls, whose step
# pours a soda that appears in no ingredient list - and THAT RECIPE IS NAMED AFTER THE MISSING BOTTLE.
# A title rule is precisely a rule that forgives the founding case; the self-test twin only survives it
# because the fixture's food is "Zero-Sugar Soda", which shares no word with the slug. A recipe called
# "Chicken with Mango Salsa" that genuinely forgot to book its salsa would be waved through forever.
# The blackened-chicken prose was fixed instead (0f1a70ae): the step now says it MAKES the salsa, which
# is true, and which PHANTOM_MADE already reads. The floor below pins this refusal.
function Test-FoodPhraseMap($map, $ownTok, $namTok) {
  <# Does an owned line match a KEY phrase of $map, and the named food one of that key's VALUE phrases?
     Every word of both sides must be present - see the phrase note above PHANTOM_CONSTITUENT. #>
  $ownTok = @($ownTok); $namTok = @($namTok)
  foreach ($k in $map.Keys) {
    $kt = @($k -split ' ')
    if (@($kt | Where-Object { $ownTok -notcontains $_ }).Count -gt 0) { continue }
    foreach ($v in @($map[$k])) {
      $vt = @($v -split ' ')
      if (@($vt | Where-Object { $namTok -notcontains $_ }).Count -eq 0) { return $true }
    }
  }
  return $false
}
function Test-FoodConstituent($ownTok, $namTok) { return (Test-FoodPhraseMap $script:PHANTOM_CONSTITUENT $ownTok $namTok) }
function Test-FoodRenderedFrom($ownTok, $namTok) { return (Test-FoodPhraseMap $script:PHANTOM_RENDERED_FROM $ownTok $namTok) }

function Get-FoodStem([string]$w) {
  <# Plural -> singular, enough for ingredient nouns. The 'oes' arm is not decoration: without it
     "potatoes" stems to "potatoe" while "potato" stems to itself, so a recipe that BUYS Sweet Potatoes
     reported a phantom Potato in every one of its own steps - five recipes at once. #>
  if ($w.Length -le 3) { return $w }
  if ($w -match 'ies$') { return ($w -replace 'ies$', 'y') }
  if ($w -match '(o|ch|sh|ss|x|z)es$') { return ($w -replace 'es$', '') }
  if ($w -match '[^s]s$') { return ($w -replace 's$', '') }
  return $w
}
function Get-FoodTokens([string]$s) {
  # The parenthetical is a brand or a variant note ("(Great Value)", "(generic)"), never the identity.
  $t = (($s.ToLower() -replace '\([^)]*\)', ' ') -replace '[^a-z ]', ' ') -replace '\s+', ' '
  return @(($t.Trim() -split ' ') | Where-Object { $_ })
}
function Get-FoodStemTokens([string]$s) { return @(@(Get-FoodTokens $s) | ForEach-Object { Get-FoodStem $_ }) }

function New-FoodVocabulary([string[]]$names) {
  <#
    The food names this estate knows, compiled widest-first so LONGEST MATCH WINS. That ordering is the
    single biggest noise cut: read narrowest-first, a step saying "brown sugar" trips the shorter known
    name Sugar, "olive oil" trips Olives (183 times), "garlic powder" trips Garlic. Widest-first plus
    span masking reads each phrase once, as the longest name that fits it.
    Matching is on the SURFACE words with an optional plural on the last one - never on the stem - because
    stemming both sides put the ingredient "Fries" on the cooking verb "fry" in 50 recipes.
  #>
  $seen = @{}
  $out = New-Object System.Collections.Generic.List[object]
  foreach ($n0 in $names) {
    if (-not $n0) { continue }
    # "Cheddar Cheese, Shredded" is Cheddar Cheese with a prep note; register both readings or a step
    # that says "cheddar cheese" looks like a phantom in the recipe that buys exactly that.
    foreach ($n in @($n0, (($n0 -split ',')[0]))) {
      $t = @(Get-FoodTokens $n)
      if ($t.Count -eq 0) { continue }
      $key = ($t -join ' ')
      if ($seen.ContainsKey($key)) { continue }
      $seen[$key] = 1
      $last = $t[-1] + '(?:e?s)?'
      $body = if ($t.Count -eq 1) { $last } else { (@($t[0..($t.Count - 2)]) + @($last)) -join '\s+' }
      $out.Add([pscustomobject]@{
        name = $n0
        stem = @(Get-FoodStemTokens $n)
        rx   = [regex]::new('(?<![a-z])' + $body + '(?![a-z])')
        w    = $t.Count
      })
    }
  }
  return @($out.ToArray() | Sort-Object -Property @{ Expression = { $_.w }; Descending = $true }, @{ Expression = { $_.name.Length }; Descending = $true })
}

function Test-FoodCovered($ownTok, $namTok) {
  <#
    Does an ingredient this recipe DOES buy account for the name a step used? Either direction of token
    containment counts, and neither needs the head noun to agree:
      the recipe buys the more specific thing - a step saying "diced tomatoes" in a recipe that buys
        "Diced Tomatoes & Green Chilies" is naming its own can (4 recipes);
      the recipe buys the more general thing - a step saying "frozen peas" over a bought "Peas".
    Containment BOTH ways is deliberately generous. It costs real findings (a step saying "rice" is
    forgiven in a recipe that only buys Rice Vinegar) and that is the right trade for a gate: a missed
    phantom stays on the worklist, a false one gets the whole check switched off.
  #>
  $ownTok = @($ownTok); $namTok = @($namTok)
  if ($ownTok.Count -eq 0 -or $namTok.Count -eq 0) { return $false }
  $a = @($namTok | Where-Object { $ownTok -notcontains $_ }).Count
  $b = @($ownTok | Where-Object { $namTok -notcontains $_ }).Count
  return ($a -eq 0 -or $b -eq 0)
}

function Get-PhantomIngredients($spec, $vocab, $bidMap) {
  <# Known food names the make_it steps use that no line of this recipe's ingredient list accounts for. #>
  $hits = New-Object System.Collections.Generic.List[object]
  if (-not $vocab) { return $hits }
  $steps = (@($spec.make_it) -join ' ')
  if (-not $steps) { return $hits }
  $hay = ((($steps.ToLower() -replace '[^a-z ]', ' ') -replace '\s+', ' ')).Trim()
  if (-not $hay) { return $hits }

  # What this recipe actually buys, read from every place a bought food is named: the scaler item, its
  # canonical name when the card renames an ingredient for the reader (the japchae glass noodles), the
  # scaler BUY string, and the WHOLE de-HTML'd display line - not just the display key before the colon.
  #
  # THE KEY-ONLY READING WAS A HOLE (2026-08-24). A COMPOSITE buy line names two foods on one costed row -
  # "Paprika: 3 1/2 teaspoons EACH paprika and dried thyme", "Garlic Powder: ...garlic powder and onion
  # powder", "Salt: ...scant 1 teaspoon EACH salt and black pepper". The rider food (dried thyme, onion
  # powder, the sauce's second black pepper, dried basil) lives AFTER the colon, is genuinely bought, and is
  # on the reader-facing ingredient list - but $own read only the pre-colon key, so a step that named the
  # rider looked like a phantom. Five false findings across two slugs reached the gate this way. Reading the
  # full line and the buy string closes it. A food named in NO line and NO buy string still fires: the
  # dr-pepper soda twin in the self-test proves the coverage did not go slack.
  $own = New-Object System.Collections.Generic.List[object]
  foreach ($sc in @($spec.scaler.ing)) {
    $buy = if (($sc.PSObject.Properties.Name -contains 'buy') -and $sc.buy) { [string]$sc.buy } else { '' }
    foreach ($v in @([string]$sc.item, [string]$sc.canon, $buy)) { if ($v) { $own.Add(@(Get-FoodStemTokens $v)) } }
  }
  foreach ($li in @($spec.ingredients_display)) {
    $s = ([string]$li) -replace '<[^>]+>', ''
    if ($s.Trim()) { $own.Add(@(Get-FoodStemTokens $s)) }          # whole line: covers riders in the buy string after the colon
    $m = [regex]::Match($s, '^\s*([^:]+?)\s*:')
    if ($m.Success) { $own.Add(@(Get-FoodStemTokens $m.Groups[1].Value)) }
  }
  if ($own.Count -eq 0) { return $hits }

  $mask = $hay.ToCharArray()
  foreach ($v in $vocab) {
    # MADE is decided per NAME, the other exemptions per occurrence. A recipe that blends tomatillos
    # "into a rough salsa" also says "for a smoother salsa, pulse it in a blender" two clauses later;
    # exempting only the sentence that makes it reported the second sentence instead, which is the same
    # false positive wearing a different mention. If the recipe makes the thing anywhere, it makes it.
    $made = $false
    $said = $null
    foreach ($m in $v.rx.Matches($hay)) {
      $freeSpan = $true
      for ($i = $m.Index; $i -lt ($m.Index + $m.Length); $i++) { if ($mask[$i] -eq '#') { $freeSpan = $false; break } }
      if (-not $freeSpan) { continue }
      for ($i = $m.Index; $i -lt ($m.Index + $m.Length); $i++) { $mask[$i] = '#' }
      $before = $hay.Substring(0, $m.Index)
      if ($before -match $script:PHANTOM_MADE) { $made = $true; continue }
      if ($said) { continue }
      $rest = $hay.Substring($m.Index + $m.Length)
      if ($rest -match ('^\s+' + $script:PHANTOM_TAIL + '(?![a-z])')) { continue }
      if ($rest -match $script:PHANTOM_FREE) { continue }
      if ($before -match $script:PHANTOM_SUBJ) { continue }
      if ($before -match $script:PHANTOM_CMP) { continue }
      if ($rest -match $script:PHANTOM_RENDERED) {
        # The prose says this came OUT of something. It must have come out of something BOUGHT -
        # see the two-conditions note on PHANTOM_RENDERED_FROM.
        $src = $false
        foreach ($o in $own) { if (Test-FoodRenderedFrom $o $v.stem) { $src = $true; break } }
        if ($src) { continue }
      }
      if ($rest -match $script:PHANTOM_ALT) {
        # Read only the alternative's own span - far enough to carry "brushed with olive oil",
        # not so far it reaches the next sentence and forgives an unrelated food.
        $span = $rest.Substring(0, [Math]::Min($script:PHANTOM_ALT_SPAN, $rest.Length))
        $spanTok = @(Get-FoodStemTokens $span)
        $satisfied = $false
        foreach ($o in $own) {
          if (@($o).Count -eq 0) { continue }
          $all = $true
          foreach ($t in @($o)) { if ($spanTok -notcontains $t) { $all = $false; break } }
          # EVERY token of an owned name must be in the span. That is what keeps this tight: a whole
          # ingredient_display line (with its buy string) can never fit, so only a real food NAME
          # like "olive oil" can satisfy an alternative.
          if ($all) { $satisfied = $true; break }
        }
        if ($satisfied) { continue }
      }
      $said = $m.Value
    }
    if ($made -or -not $said) { continue }
    $cov = $false
    foreach ($o in $own) { if ((Test-FoodCovered $o $v.stem) -or (Test-FoodConstituent $o $v.stem)) { $cov = $true; break } }
    if ($cov) { continue }
    # SAME COMMODITY IS NOT A PHANTOM (2026-08-27). PHANTOM asks whether the dish can be made AS SHOPPED,
    # and the honest test of that is what the reader put in the basket, not which synonym the step used.
    # Four live specs say "shredded cheese" in a step while their ingredient line reads "Mexican Cheese
    # Blend" - and both names carry the bid `shredded-cheese`, so the reader demonstrably bought the very
    # thing the step asks for. The dishes were always makeable; the finding appeared the day a vocabulary
    # row named "Shredded Cheese" was added, because the class is vocabulary-driven and the phrase only
    # then became a food this matcher could see. Token coverage cannot close that: "Mexican Cheese Blend"
    # and "Shredded Cheese" share no word.
    #
    # Deliberately narrower than an alias table: it fires only when BOTH sides resolve to the SAME priced
    # commodity id, which is the estate's own definition of one purchase. A step naming a food the recipe
    # does NOT buy still fires, because no line will carry its bid.
    if ($bidMap) {
      $vb = [string]$bidMap[[string]$v.name]
      if ($vb) {
        $boughtSame = $false
        foreach ($sc in @($spec.scaler.ing)) {
          if (($sc.PSObject.Properties.Name -contains 'bid') -and ([string]$sc.bid -eq $vb)) { $boughtSame = $true; break }
        }
        if ($boughtSame) { continue }
      }
    }
    $hits.Add(@{ name = $v.name; said = $said })
  }
  return $hits
}

# ---- BUY-COVERAGE: the buy sentence disagrees with the package the recipe needs -------------------
# THE HOLE THIS CLOSES (2026-08-15). country-captain-chicken carried, in ONE spec:
#     cost_lines  "Golden Raisins, 1.25 cups: ... Buy 1 (lasts several batches)."
#     shop_smart  "One box of golden raisins covers this batch and most of a second. ... Not several
#                  batches, but the box is not a one-and-done either."
# Two sentences about the same box, flatly opposed, and this audit walked straight past it - because every
# class above reads NUMBERS against NUMBERS, and nothing read a buy instruction against the amount the
# recipe uses. A self-contradiction gate that cannot see two sentences disagreeing about one box is only
# checking the disagreements it was told about.
#
# WHY THIS ONE NEEDS EVIDENCE PASSED IN. The rest of this file judges a spec against itself, on purpose.
# "Buy 1" beside "2.25 cups" is not decidable from the spec alone - cups are not cartons, and only the
# package definition says how many cups a carton holds. So this follows the PHANTOM precedent exactly: the
# caller supplies the map, and a caller that has none (repair-spec-contradictions, reading one spec in
# isolation) skips the class rather than guessing. The one shape that IS decidable unaided - an amount
# stated in packages, "3.5 cans ... Buy 1" - still needs the map to know 'cans' is this item's package noun.
#
# The thresholds are NOT redefined here. Get-BulkCoverageWords in cost-render-lib.ps1 is what the renderer
# prints and what repair-bulk-buy-line writes, so the gate asks that same function what the line SHOULD
# say and compares. A second copy of the ladder here is how a gate ends up certifying wording the renderer
# never produces.
. (Join-Path $PSScriptRoot 'cost-render-lib.ps1')

function Get-BuyCoverageFindings($spec, $pkgMap) {
  <# $pkgMap: canonical item name -> @{ g = pantry_pkg_g; label = pantry_pkg_label }. #>
  $out = New-Object System.Collections.Generic.List[object]
  if (-not $pkgMap) { return $out }
  $disp = @{}
  foreach ($se in @($spec.scaler.ing)) {
    $nm = [string]$se.item
    if (-not $nm) { continue }
    $canon = if (($se.PSObject.Properties.Name -contains 'canon') -and $se.canon) { [string]$se.canon } else { $nm }
    $disp[$nm] = @{ canon = $canon; grams = [double]$se.grams }
  }
  foreach ($li in @($spec.cost_lines)) {
    $s = [string]$li
    $m = [regex]::Match($s, '^(?<nm>[^,]+),\s.*?<strong>Buy 1 \((?<words>[^)]*)\)\.')
    if (-not $m.Success) { $m = [regex]::Match($s, '^(?<nm>[^,]+),\s.*?Buy 1 \((?<words>[^)]*)\)\.') }
    if (-not $m.Success) { continue }
    $nm = $m.Groups['nm'].Value
    if (-not $disp.ContainsKey($nm)) { continue }
    $d = $disp[$nm]
    if (-not $pkgMap.ContainsKey($d.canon)) { continue }
    $pk = $pkgMap[$d.canon]
    $pkgG = [double]$pk.g
    if ($pkgG -le 0 -or $d.grams -le 0) { continue }
    $need = Get-PackageBuyCount $d.grams $pkgG
    if ($need -ge 2) {
      $out.Add(@{ cls = 'BUY-COVERAGE'; why = ("'" + $nm + "' says Buy 1 but this batch needs " + $need + " " + [string]$pk.label + " (" + $d.grams + " g from a " + $pkgG + " g package)") })
      continue
    }
    $want = Get-BulkCoverageWords ($pkgG / $d.grams)
    if ($m.Groups['words'].Value -ne $want) {
      $out.Add(@{ cls = 'BUY-COVERAGE'; why = ("'" + $nm + "' says '" + $m.Groups['words'].Value + "' but one " + [string]$pk.label + " covers " + ($pkgG / $d.grams).ToString('0.00') + " batches") })
    }
  }
  return $out
}

function Get-SpecContradictions($spec, $vocab, $pkgMap, $bidMap) {
  <# Every finding for one spec: @{ cls, why }. Shared by the audit and the repair. #>
  $f = New-Object System.Collections.Generic.List[object]
  $cal = 0; $pro = 0
  [void][int]::TryParse(([string]$spec.stat.cal), [ref]$cal)
  [void][int]::TryParse(([string]$spec.stat.protein), [ref]$pro)
  $cps = [string]$spec.stat.cost_ps

  foreach ($k in @('intro_html','portion_html','cost_closing_html','upsell_html','head.description')) {
    $t = if ($k -eq 'head.description') { [string]$spec.head.description } else { [string]$spec.$k }
    if (-not $t) { continue }
    if ($cal -gt 0) {
      foreach ($m in [regex]::Matches($t, $script:RX_CAL)) {
        $claimed = [int]$m.Groups[1].Value
        if (Test-MacroClaimContradiction -Text $t -MatchIndex $m.Index -Claimed $claimed -Actual $cal) {
          $f.Add(@{ cls = 'STAT-PROSE'; why = ("$k says " + $m.Groups[1].Value + " calories, stat says " + $cal) })
        }
      }
    }
    if ($pro -gt 0) {
      foreach ($m in [regex]::Matches($t, $script:RX_PROTEIN)) {
        if ([int]$m.Groups[1].Value -ne $pro) { $f.Add(@{ cls = 'STAT-PROSE'; why = ("$k says " + $m.Groups[1].Value + "g protein, stat says " + $pro) }) }
      }
    }
    # CARBS AND FAT read through the SAME bounded-claim logic as calories, and they need it: 57 of the
    # 59 carb figures in this catalogue are the lowcarb sentence "with under 20 grams of carbs" over a
    # 16 g stat, every one of them true. Reading those as quotes would fire 57 times on correct copy.
    # Fat carries no bound today (measured 2026-09-01, zero occurrences) but shares the reading because
    # an upper bound on fat is the same claim shape, and a second copy of this logic is how the two
    # halves of a rule drift apart.
    foreach ($m in [regex]::Matches($t, $script:RX_MACRO)) {
      $key = if ($m.Groups[2].Value.ToLower().StartsWith('fat')) { 'fat' } else { 'carbs' }
      $actual = 0
      [void][int]::TryParse(([string]$spec.stat.$key), [ref]$actual)
      if ($actual -le 0) { continue }
      # [int] on the WHOLE decimal, matching RX_PROTEIN's consumer and coverage_check's _claimed_int:
      # a stat is a rounded integer, so "9.6 grams of fat" on a 10 g stat is the same claim, not a
      # contradiction. The capture takes the whole decimal so "99.9g fat" on a 10 g stat still fires.
      $claimed = [int]$m.Groups[1].Value
      if (Test-MacroClaimContradiction -Text $t -MatchIndex $m.Index -Claimed $claimed -Actual $actual) {
        $f.Add(@{ cls = 'STAT-PROSE'; why = ("$k says " + $m.Groups[1].Value + "g $key, stat says " + $actual) })
      }
    }
    # A bare "$12" is the takeout comparison the sentence is built on, and the cents-less regex below never
    # sees it. A $N.NN in ANY of these five fields is a per-serving claim by construction: spec-guards'
    # POST-SYNC NUMERIC VERIFICATION fails a spec whose intro/portion/closing/upsell/head.description quotes
    # a $N.NN that is not stat.cost_ps, so this reading is that same contract, not a new rule.
    #   SCOPED TO TWO FIELDS UNTIL 2026-08-07, and portion_html is the field that paid for it. 15 slow-cooker
    # specs shipped a portion line reading "at roughly $2.00 a bowl" beside a closing line reading "$4.87 a
    # bowl" - the SAME unit, two numbers, one of them on a live card since the specs were born (git shows
    # $2.00 never matched cost_ps, cost_per_serving OR cost_per_serving_true at birth: the writer wave
    # invented it). Nothing caught it for the same reason in three places at once - this class skipped the
    # field, repair-spec-contradictions skipped it, and the ONE check that did cover it (spec-guards line
    # 183) lives in full mode, which needs prose-<slug>.json files the engine stopped writing. A number the
    # contract already forbids must be READ in every field the contract names, or the contract is decoration.
    # Widening cost 0 false positives across all 513 live specs; the 7 takeout comparisons are all bare $NN.
    foreach ($m in [regex]::Matches($t, '\$\d+\.\d{2}')) {
      if ($m.Value -ne ('$' + $cps)) { $f.Add(@{ cls = 'STALE-MONEY'; why = ("$k quotes " + $m.Value + " but the per-serving cost is `$$cps") }) }
    }
    foreach ($m in [regex]::Matches($t, '(?i)\b\d{1,3}\s*cents\b')) {
      $f.Add(@{ cls = 'STALE-MONEY'; why = ("$k quotes '" + $m.Value + "' - a per-line cents figure from a basis the cost redesign removed") })
    }
  }

  foreach ($li in (@(@($spec.ingredients_display) + @($spec.cost_lines)) | Where-Object { $_ })) {
    $s = [string]$li
    $clean = (($s -replace '<[^>]+>', '') -replace '\s+', ' ').Trim()
    foreach ($m in [regex]::Matches($s, '(?<![\d.])(\d+(?:\.\d+)?)\s*(lb|lbs|oz|cups?|tbsp|tsp)\b')) {
      if ([double]$m.Groups[1].Value -lt $script:UNMEASURABLE_UNDER) {
        $f.Add(@{ cls = 'UNMEASURABLE-QTY'; why = ("a line asks for '" + $m.Value.Trim() + "', which no kitchen measure shows: " + $clean) })
      }
    }
    foreach ($m in [regex]::Matches($s, '(?<![\d.])(\d{2,4}(?:\.\d+)?)\s*tbsp\b')) {
      if ([double]$m.Groups[1].Value -gt 24) { $f.Add(@{ cls = 'ABSURD-UNIT'; why = ($m.Groups[1].Value + " tbsp is over a cup and a half measured a spoon at a time: " + $clean) }) }
    }
  }

  $disp = Get-DisplayQuantities $spec
  foreach ($hi in @($spec.head.recipeIngredient)) {
    $mm = Get-HeadQtyMismatch ([string]$hi) $disp
    if ($mm) { $f.Add(@{ cls = 'HEAD-QTY'; why = ("head asks for " + $mm.head + " " + $mm.unit + " of " + $mm.key + ", the costed line uses " + $mm.costed + " " + $mm.unit) }) }
  }

  # The display KEY is reduced to letters and spaces (Get-DisplayQuantities), which closes "Five-Spice"
  # up into "fivespice". The steps must be reduced the SAME way or the two can never meet: a step saying
  # "five-spice" was reported as an unused five-spice powder in two live recipes purely because one side
  # of the comparison had dropped a hyphen the other kept.
  $steps = ((@($spec.make_it) -join ' ').ToLower() -replace '[^a-z ]', '')
  if ($steps) {
    $keys = @($disp.Keys)
    foreach ($key in $keys) {
      if ($key.Length -lt 4) { continue }
      if (-not (Test-IngredientNamedInSteps $key $keys $steps)) {
        $f.Add(@{ cls = 'UNUSED'; why = ("'" + $key + "' is bought and costed but never named in a step") })
      }
    }
  }

  # PHANTOM needs the catalogue's food lexicon, so it only runs when a caller supplies one. Callers that
  # read one spec in isolation (repair-spec-contradictions) pass nothing and skip the class.
  foreach ($p in (Get-PhantomIngredients $spec $vocab $bidMap)) {
    $f.Add(@{ cls = 'PHANTOM'; why = ("a step says '" + $p.said + "' but " + $p.name + " is in no ingredient line - it cannot be made as shopped") })
  }

  # BUY-COVERAGE, like PHANTOM, runs only when the caller supplies the evidence it needs.
  foreach ($b in (Get-BuyCoverageFindings $spec $pkgMap)) { $f.Add($b) }
  return $f
}
