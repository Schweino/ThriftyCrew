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
$script:RX_PROTEIN = '(?i)\b(\d{1,3})\s*(?:g\b|grams?\b)\s*(?:of\s+)?protein'
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
        if ($Steps -match ('\b' + [regex]::Escape($t))) { return $true }
    }
    return $false
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

function Get-PhantomIngredients($spec, $vocab) {
  <# Known food names the make_it steps use that no line of this recipe's ingredient list accounts for. #>
  $hits = New-Object System.Collections.Generic.List[object]
  if (-not $vocab) { return $hits }
  $steps = (@($spec.make_it) -join ' ')
  if (-not $steps) { return $hits }
  $hay = ((($steps.ToLower() -replace '[^a-z ]', ' ') -replace '\s+', ' ')).Trim()
  if (-not $hay) { return $hits }

  # What this recipe actually buys, read from all three parallel arrays: the scaler item, its canonical
  # name when the card renames an ingredient for the reader (the japchae glass noodles), and the display
  # key. Any one of them accounting for the word is enough.
  $own = New-Object System.Collections.Generic.List[object]
  foreach ($sc in @($spec.scaler.ing)) {
    foreach ($v in @([string]$sc.item, [string]$sc.canon)) { if ($v) { $own.Add(@(Get-FoodStemTokens $v)) } }
  }
  foreach ($li in @($spec.ingredients_display)) {
    $s = ([string]$li) -replace '<[^>]+>', ''
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
      $said = $m.Value
    }
    if ($made -or -not $said) { continue }
    $cov = $false
    foreach ($o in $own) { if (Test-FoodCovered $o $v.stem) { $cov = $true; break } }
    if ($cov) { continue }
    $hits.Add(@{ name = $v.name; said = $said })
  }
  return $hits
}

function Get-SpecContradictions($spec, $vocab) {
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
        if ([int]$m.Groups[1].Value -ne $cal) { $f.Add(@{ cls = 'STAT-PROSE'; why = ("$k says " + $m.Groups[1].Value + " calories, stat says " + $cal) }) }
      }
    }
    if ($pro -gt 0) {
      foreach ($m in [regex]::Matches($t, $script:RX_PROTEIN)) {
        if ([int]$m.Groups[1].Value -ne $pro) { $f.Add(@{ cls = 'STAT-PROSE'; why = ("$k says " + $m.Groups[1].Value + "g protein, stat says " + $pro) }) }
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
  foreach ($p in (Get-PhantomIngredients $spec $vocab)) {
    $f.Add(@{ cls = 'PHANTOM'; why = ("a step says '" + $p.said + "' but " + $p.name + " is in no ingredient line - it cannot be made as shopped") })
  }
  return $f
}
