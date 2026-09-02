# render-tokens.ps1 - expand {{stat}} tokens in a spec's prose at RENDER time.
#
# WHY THIS EXISTS (2026-08-08 architecture review, Brad's call). Until now every price and calorie figure a
# reader sees was a LITERAL baked into the prose text, which meant the sentence had to be re-edited every
# time the number moved. That one decision generated most of the estate's recurring defects: the reanchor
# pair (machine fields moved, prose left quoting the old price - happened twice in one day), the 15
# slow-cooker specs understating cost by up to $1.75 for weeks, the prose disaster that rewrote 11 bounds,
# and six scripts whose whole job was moving numbers already known elsewhere.
#
# The cure: prose stores TOKENS ("at roughly ${{cost_ps}} a bowl"), and the render boundary substitutes the
# spec's own stat at build/publish time. The number can never disagree with the sentence again, because the
# sentence does not contain a number.
#
# TOKENS (all resolved from the spec's own stat block - never from a manifest, never from the wall clock):
#   {{cost_ps}}   stat.cost_ps   (string, 2dp - the everyday per-serving cost)
#   {{cal}}       stat.cal       (int)
#   {{protein}}   stat.protein   (int)
#   {{carbs}}     stat.carbs     (int)
#   {{fat}}       stat.fat       (int)
#
# CARBS AND FAT ADDED 2026-08-31, and the reason is a wave blocker. This map had cal, protein and
# cost_ps but NOT carbs or fat, so a writer who wanted to state either had no choice but a literal -
# and a literal is exactly what the token mechanism exists to prevent. creamy-roasted-garlic-chicken
# said "about 15 grams of carbs" in intro_html and head.description while its stat said 17: its macros
# were recomputed off the Fairlife-vs-ordinary-milk basis (563/64/15/27 -> 583/61/17/30 on unchanged
# grams) and the two tokenised numbers in the same sentence moved with it while the untokenised one did
# not. Measured across all 585 specs: 5 state carbs or fat as a literal and 1 of them had gone stale.
# Small, but it is the same class the 2026-08-07 prose disaster came from, and the fix is five lines.
#
# BOUNDS ARE NOT TOKENS, deliberately. "under 400 calories" is a CLAIM whose truth the bounded-claim gate
# already checks against stat; tokenizing it would rewrite the promise whenever the stat moved, which is
# exactly the corruption the 2026-08-07 prose disaster produced by accident.
#
# Dot-source:  . (Join-Path $mp 'lib\render-tokens.ps1')
# Self-test:   powershell -File lib\render-tokens.ps1 -SelfTest
param([switch]$SelfTest)

$script:TOKEN_FIELDS = @('intro_html','portion_html','cost_closing_html','upsell_html')  # + head.description

function Expand-SpecTokens { param([string]$Text, $Spec)
  if ([string]::IsNullOrEmpty($Text)) { return $Text }
  if ($Text.IndexOf('{{') -lt 0) { return $Text }
  # BUILT CONDITIONALLY, because [int]$null IS 0. Casting a missing stat straight to [int] produced
  # the string "0", which is not empty, so the empty-stat guard below could never fire and the reader
  # got "0 grams of carbs" - a confident wrong number, which is worse than the unexpanded token the
  # guard exists to prevent. Found 2026-08-31 while adding carbs/fat; the same hole was already open
  # for cal and protein and had simply never been reached, because every spec happens to carry both.
  $map = @{ 'cost_ps' = [string]$Spec.stat.cost_ps }
  foreach ($k in @('cal', 'protein', 'carbs', 'fat')) {
    $v = $Spec.stat.$k
    $map[$k] = if ($null -eq $v -or [string]::IsNullOrEmpty([string]$v)) { '' } else { [string][int]$v }
  }
  $out = [regex]::Replace($Text, '\{\{(\w+)\}\}', {
    param($m)
    $k = $m.Groups[1].Value
    if (-not $map.ContainsKey($k)) { throw ("render-tokens: unknown token '{{{{{0}}}}}' - a typo in prose would otherwise ship to a reader verbatim" -f $k) }
    if ([string]::IsNullOrEmpty($map[$k])) { throw ("render-tokens: token '{{{{{0}}}}}' resolves to an EMPTY stat - the spec is missing the number its prose promises" -f $k) }
    $map[$k]
  })
  if ($out.IndexOf('{{') -ge 0) { throw 'render-tokens: unexpanded token survived - refusing to render it to a reader' }
  return $out
}

# Expand every prose field of a parsed spec IN MEMORY, returning the spec. This is the one call the render
# boundary (build-card2, publish) makes; nothing downstream ever sees a token.
function Expand-SpecProse { param($Spec)
  foreach ($k in $script:TOKEN_FIELDS) {
    $v = [string]$Spec.$k
    if ($v) { $Spec.$k = Expand-SpecTokens -Text $v -Spec $Spec }
  }
  if ($Spec.head -and $Spec.head.PSObject.Properties['description']) {
    $d = [string]$Spec.head.description
    if ($d) { $Spec.head.description = Expand-SpecTokens -Text $d -Spec $Spec }
  }
  return $Spec
}

# Ghost owns recipe prose, never grocery-price authority. Replace this recipe's
# old static cost token with a live hydration target in HTML fields, and remove
# it from non-hydratable metadata. The $1 membership sentence is intentionally
# untouched because it is not a grocery price and does not equal stat.cost_ps.
function Move-SpecPriceToReleaseHydration { param($Spec)
  $cost = [string]$Spec.stat.cost_ps
  if ([string]::IsNullOrEmpty($cost)) { return $Spec }
  $pattern = '\$' + [regex]::Escape($cost)
  $markup = '<span data-tc-live-price>current release price loading</span>'
  foreach ($k in $script:TOKEN_FIELDS) {
    $v = [string]$Spec.$k
    if ($v) { $Spec.$k = [regex]::Replace($v, $pattern, $markup) }
  }
  if ($Spec.head -and $Spec.head.PSObject.Properties['description']) {
    $description = [string]$Spec.head.description
    $priceClause = '(?i),?\s*(?:for\s+)?(?:about|roughly|around)\s+' + $pattern + '\s+(?:a|per|each\b)\s*[^.]*\.?'
    $description = [regex]::Replace($description, $priceClause, ', with live pricing shown on the page.')
    $Spec.head.description = Remove-GhostStaticCurrencyClaims ([regex]::Replace($description, $pattern, 'current pricing shown on the page'))
  }
  return $Spec
}

function Remove-GhostStaticCurrencyClaims { param([string]$Text)
  <#
    A card's OWN price is hydrated live (Move-SpecPriceToReleaseHydration). Every OTHER dollar figure in
    the prose is a static claim about what somebody else charges, and those go stale too, so they are
    replaced with a qualitative phrase that cannot rot. That purpose is unchanged: nothing here ever
    emits a number.

    A SUBSTITUTION HAS TO KNOW WHAT PART OF SPEECH IT IS REPLACING (2026-09-01). Until today the last
    rule swapped any surviving "$12" for the adjective "restaurant-priced" regardless of where it sat.
    In the attributive slot that reads: "the $12 chain bowl" -> "the restaurant-priced chain bowl". In an
    object slot it does not: "a plate a Filipino restaurant would happily charge you $12 for" became
    "...charge you restaurant-priced for". MEASURED on the built corpus that day: 60 rendered sentences
    carried the token and 53 of them were ungrammatical, live, on 52 cards. It survived 1,133 commits
    because the one self-test case was "runs $14 to $17" - a noun phrase, caught by the range rule above,
    which never reaches the catch-all at all.

    So the figure is now read in context, and each slot gets a phrase that fits it:
      is/are/was/were $N        -> predicate adjective     "the restaurant version is restaurant-priced"
      $N more                   -> "extra"                 "add protein for extra"
      the/a/an/this/that $N X   -> attributive adjective    "the restaurant-priced chain bowl"
      $N a plate / per serving  -> noun, unit absorbed      "would charge you restaurant prices for"
      bare $N                   -> noun                     "would happily charge you restaurant money for"
    The article is corrected on the attributive path, because "an $18 entree" would otherwise render as
    "an restaurant-priced entree". Order matters: the widest-context rules run first so a narrower one
    cannot eat half of their match.
  #>
  if ([string]::IsNullOrEmpty($Text) -or $Text -notmatch '\$\d') { return $Text }
  $membership = '__TC_MEMBERSHIP_PRICE__'
  $out = $Text.Replace('$1 a month', $membership)
  $amount = '\$\d+(?:\.\d+)?'
  # A TRAILING UNIT BELONGS TO THE FIGURE. "$13 to $16 a plate" is one noun phrase, and replacing only
  # the figures stranded the unit: "runs far more a plate". Same for the colloquial "$11 to $13 easy".
  $unit = '(?:\s+(?:a|per|each)\s+[a-z]+)?'
  # ---- hedged and bounded amounts ----
  $out = [regex]::Replace($out, '(?i)' + $amount + '\s*(?:to|[-–])\s*' + $amount + $unit + '(?:\s+easy)?', 'far more')
  # "starts around $15" is a verb that wants a preposition, not a bare amount: "starts restaurant money"
  # does not parse. This is the one hedge shape that has to keep a preposition of its own.
  $out = [regex]::Replace($out, '(?i)\bstarts\s+(?:around|about|at|near)\s+' + $amount + $unit, 'starts at restaurant prices')
  # A HEDGED AMOUNT IS A NOUN PHRASE, NOT AN ADVERB (2026-09-01). This rule used to emit "substantially",
  # which reads only after a verb that can take an adverb: "saves you substantially" is fine, "you are
  # keeping substantially every time" is not. The noun form fits both.
  $out = [regex]::Replace($out, '(?i)(?:roughly|around|about|near)\s+' + $amount + $unit, 'restaurant money')
  $out = [regex]::Replace($out, '(?i)under\s+' + $amount + $unit, 'well under restaurant money')
  $out = [regex]::Replace($out, '(?i)' + $amount + '\s+or more', 'far more')
  # ---- grammatical slots ----
  $out = [regex]::Replace($out, '(?i)\b(is|are|was|were)\s+' + $amount + '(?:\s+(?:a|per|each)\s+[a-z]+)?', '$1 restaurant-priced')
  $out = [regex]::Replace($out, '(?i)' + $amount + '\s+more\b', 'extra')
  # ATTRIBUTIVE. A determiner in front and a word behind means the figure is modifying a noun. The
  # evaluator exists for the article: "an" must become "a" before a consonant, and the capital has to
  # survive a sentence-initial "An".
  $adj = [System.Text.RegularExpressions.MatchEvaluator] {
    param($m)
    $d = $m.Groups[1].Value
    if ($d -match '^(?i)an?$') { $d = if ($d -cmatch '^A') { 'A' } else { 'a' } }
    return ($d + ' restaurant-priced')
  }
  # ATTRIBUTIVE MEANS A NOUN FOLLOWS. The lookahead has to refuse a unit word (which belongs to the
  # figure) and a function word (which means the figure was an OBJECT, not a modifier): "vs $16 for the
  # same plate" is not "vs restaurant-priced for the same plate". Anything not listed is taken to be a
  # noun, and the cost of being wrong there is one adjective where a noun would also have read.
  $notUnit = '(?=\s+(?!a\b|an\b|per\b|each\b|more\b|for\b|to\b|at\b|and\b|or\b|with\b|plus\b|before\b|once\b|after\b|when\b|than\b|but\b|so\b|if\b|that\b|which\b|in\b|on\b|from\b|up\b|every\b|instead\b|versus\b|vs\b)[a-z])'
  $out = [regex]::Replace($out, '(?i)\b(an?|the|that|this)\s+' + $amount + $notUnit, $adj)
  # ATTRIBUTIVE WITHOUT A DETERMINER. A comparison drops the article and leaves the figure modifying the
  # noun anyway: "instead of $12 delivery", "vs $15 takeout". Falling through to the noun form here reads
  # as "instead of restaurant money delivery", so the comparison words are named explicitly. A whitelist,
  # not a blocklist: an unlisted shape lands on the noun form below, which is the grammatical default.
  $out = [regex]::Replace($out, '(?i)\b(instead of|compared to|versus|vs\.?|than)\s+' + $amount + $notUnit, '$1 restaurant-priced')
  # PER-PHRASE. "$12 a plate" is one noun phrase; replacing only the figure strands the unit.
  $out = [regex]::Replace($out, '(?i)' + $amount + '\s+(?:a|per|each)\s+[a-z]+', 'restaurant prices')
  $out = [regex]::Replace($out, $amount, 'restaurant money')
  return $out.Replace($membership, '$1 a month')
}

if ($SelfTest) {
  $f = 0
  function T($m, $c, $g) { if ($c) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $g); $script:f++ } }
  $spec = '{"stat":{"cal":460,"protein":38,"carbs":17,"fat":30,"cost_ps":"5.76"}}' | ConvertFrom-Json

  T 'money token expands to the spec''s own stat' `
    ((Expand-SpecTokens 'about ${{cost_ps}} a bowl' $spec) -eq 'about $5.76 a bowl') (Expand-SpecTokens 'about ${{cost_ps}} a bowl' $spec)
  T 'cal + protein expand together' `
    ((Expand-SpecTokens 'near {{cal}} calories with {{protein}} grams of protein' $spec) -eq 'near 460 calories with 38 grams of protein') 'mismatch'
  T 'carbs and fat expand from the stat too (added 2026-08-31 - their absence is why one spec went stale)' `
    ((Expand-SpecTokens '{{carbs}}g carbs and {{fat}}g fat' $spec) -eq '17g carbs and 30g fat') (Expand-SpecTokens '{{carbs}}g carbs and {{fat}}g fat' $spec)
  T 'MUST FIRE  a carbs token over a spec with NO carbs stat throws, and does NOT render "0"' `
    (& { $t = $false; try { Expand-SpecTokens '{{carbs}}g' ('{"stat":{"cal":1,"protein":1,"cost_ps":"1.00"}}' | ConvertFrom-Json) | Out-Null } catch { $t = $true }; $t }) 'rendered a hole'
  T 'MUST FIRE  ...and the same holds for cal, whose [int]$null-is-0 hole was open all along' `
    (& { $t = $false; try { Expand-SpecTokens '{{cal}} cal' ('{"stat":{"protein":1,"cost_ps":"1.00"}}' | ConvertFrom-Json) | Out-Null } catch { $t = $true }; $t }) 'rendered 0 calories to a reader'
  T 'CLEAN TWIN text with no tokens is returned untouched (fast path)' `
    ((Expand-SpecTokens 'no tokens here, just $1 a month' $spec) -eq 'no tokens here, just $1 a month') 'rewritten'

  # MUST FIRE: a typo'd token must throw, never ship "{{cost_p}}" to a reader.
  $threw = $false; try { Expand-SpecTokens 'about ${{cost_p}} a bowl' $spec | Out-Null } catch { $threw = $true }
  T 'MUST FIRE  an unknown token throws instead of rendering verbatim' $threw 'shipped a typo'

  # MUST FIRE: a token resolving to an empty stat is the turkey-pozole class (five empty fields shipped
  # because nothing checked what a write resolved to).
  $bad = '{"stat":{"cal":460,"protein":38,"cost_ps":""}}' | ConvertFrom-Json
  $threw2 = $false; try { Expand-SpecTokens 'about ${{cost_ps}} a bowl' $bad | Out-Null } catch { $threw2 = $true }
  T 'MUST FIRE  a token resolving to an empty stat throws' $threw2 'rendered "about $ a bowl"'

  # Expand-SpecProse touches all five surfaces including head.description.
  $full = '{"stat":{"cal":610,"protein":57,"cost_ps":"3.58"},"intro_html":"x {{protein}}g","portion_html":"{{cal}} cal","cost_closing_html":"${{cost_ps}}","upsell_html":"${{cost_ps}} a bowl","head":{"description":"about ${{cost_ps}} each","costPerServing":3.58}}' | ConvertFrom-Json
  $e = Expand-SpecProse $full
  T 'Expand-SpecProse expands all four prose fields + head.description' `
    ($e.intro_html -eq 'x 57g' -and $e.portion_html -eq '610 cal' -and $e.upsell_html -eq '$3.58 a bowl' -and $e.head.description -eq 'about $3.58 each') `
    ($e.head.description)

  $h = Move-SpecPriceToReleaseHydration $e
  T 'Ghost prose price becomes a live release hydration target while membership pricing is untouched' `
    ($h.upsell_html -eq '<span data-tc-live-price>current release price loading</span> a bowl' -and $h.head.description -notmatch '\$3\.58') `
    ($h.upsell_html + ' / ' + $h.head.description)
  $h2 = '{"stat":{"cost_ps":"5.91"},"head":{"description":"678 calories, 37g protein, about $5.91 a serving (at everyday cost). Takeout, dethroned."}}' | ConvertFrom-Json
  $h2 = Move-SpecPriceToReleaseHydration $h2
  T 'metadata removes the price clause as a grammatical sentence' `
    ($h2.head.description -eq '678 calories, 37g protein, with live pricing shown on the page. Takeout, dethroned.') $h2.head.description
  T 'non-release currency claims become qualitative while membership pricing remains' `
    ((Remove-GhostStaticCurrencyClaims 'runs $14 to $17, saves around $12, members pay $1 a month') -eq 'runs far more, saves restaurant money, members pay $1 a month') `
    (Remove-GhostStaticCurrencyClaims 'runs $14 to $17, saves around $12, members pay $1 a month')

  # ================================================================================================
  # THE GRAMMAR CASES, 2026-09-01. Every `buy` string below is lifted VERBATIM off the spec that was
  # rendering it wrong on a live card, so these cannot pass by finding nothing. The case above is the
  # one this function shipped with for 1,133 commits, and it is exactly why the defect survived: both
  # of its figures are noun phrases caught by the hedge rules, so the catch-all never ran at all.
  # ================================================================================================
  function TC($m, $in, $want) {
    $got = Remove-GhostStaticCurrencyClaims $in
    T $m ($got -eq $want) $got
  }

  # MUST FIRE - object of a verb. THE founding case, filipino-pork-giniling cost_closing_html.
  TC 'MUST FIRE  a figure in an OBJECT slot takes a noun, not the adjective (filipino-pork-giniling, live)' `
    'for a plate a Filipino restaurant would happily charge you $12 for.' `
    'for a plate a Filipino restaurant would happily charge you restaurant money for.'

  # MUST FIRE - the article. marry-me-pork-chops-over-pasta rendered "an restaurant-priced".
  TC 'MUST FIRE  an attributive figure fixes the article it leaves behind (marry-me-pork-chops-over-pasta, live)' `
    'a dinner that reads like an $18 date-night entree at an Italian place.' `
    'a dinner that reads like a restaurant-priced date-night entree at an Italian place.'

  # MUST FIRE - the stranded unit. million-dollar-baked-spaghetti.
  TC 'MUST FIRE  a per-phrase moves as one noun phrase, unit and all (million-dollar-baked-spaghetti, live)' `
    'an Italian restaurant would price at $14 a plate, and this makes fourteen servings.' `
    'an Italian restaurant would price at restaurant prices, and this makes fourteen servings.'

  # MUST FIRE - after a copula the slot wants the adjective back. thai-red-curry-chicken-rice-bowls.
  TC 'MUST FIRE  after is/are the adjective is right again (thai-red-curry-chicken-rice-bowls, live)' `
    'The restaurant version is $15 a plate, which means this batch pays for itself.' `
    'The restaurant version is restaurant-priced, which means this batch pays for itself.'

  # MUST FIRE - a comparison with no determiner. chicken-lo-mein-noodle-bowls head.description.
  # The card's OWN price is already a hydration span by the time this function runs
  # (Move-SpecPriceToReleaseHydration goes first), so the fixture carries the span, not a figure. Written
  # the other way round it fails, and that failure is worth keeping in mind: the only dollar figures this
  # function ever sees are somebody ELSE's prices.
  # NOT a must-fire, and labelled honestly: the OLD blind catch-all happened to get this shape right,
  # because an attributive slot is the one place an adjective belonged. It is here as a REGRESSION pin -
  # adding the noun form without the comparison whitelist turns it into "instead of restaurant money
  # delivery", which is how it read during this fix before the whitelist went in.
  TC 'CLEAN TWIN  a comparison keeps the attributive reading without a determiner (chicken-lo-mein-noodle-bowls, live)' `
    'about <span data-tc-live-price>current release price loading</span> a serving (at everyday cost) instead of $12 delivery.' `
    'about <span data-tc-live-price>current release price loading</span> a serving (at everyday cost) instead of restaurant-priced delivery.'

  # CLEAN TWIN - the shape that already read correctly must not move. ground-turkey-burrito-bowl carries
  # BOTH slots in one sentence, which is what makes it the right twin: the fix has to tell them apart.
  TC 'CLEAN TWIN  an attributive figure still renders as the adjective, in the same sentence as an object one' `
    'Same idea as the $12 chain bowl, minus the $12.' `
    'Same idea as the restaurant-priced chain bowl, minus the restaurant money.'

  # CLEAN TWIN - the release price is NOT this function's business and must survive untouched.
  TC 'CLEAN TWIN  a hydration span and the membership price are both left alone' `
    'about <span data-tc-live-price>current release price loading</span> a bowl, members pay $1 a month' `
    'about <span data-tc-live-price>current release price loading</span> a bowl, members pay $1 a month'

  # CLEAN TWIN - text with no figure at all takes the fast path.
  TC 'CLEAN TWIN  prose carrying no dollar figure is returned byte-identical' `
    'A plate like this runs far more at any Southern diner.' `
    'A plate like this runs far more at any Southern diner.'

  # ------------------------------------------------------------------------------------------------
  # AND IT HAS TO HOLD OVER THE REAL CORPUS, NOT JUST EIGHT FROZEN LINES. Fixtures prove the shapes I
  # knew about; this sweeps every authored prose field in the catalog and fails on the SIGNATURES of a
  # misfire. It is the half that will catch the next shape somebody writes, which is the whole reason
  # the original defect reached 52 live cards - nothing ever looked at the output.
  # run-gates.ps1 discovers this -SelfTest on every push, so it has a caller that is not itself.
  # ------------------------------------------------------------------------------------------------
  $specDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'db\recipes'
  if (Test-Path $specDir) {
    $bad = @(); $swept = 0
    $units = 'plate|plates|serving|servings|bowl|bowls|person|container|portion|slab|pound|order|meal|head|box'
    foreach ($sf in (Get-ChildItem (Join-Path $specDir '*.json'))) {
      $sp = Get-Content $sf.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
      $texts = @()
      foreach ($k in $script:TOKEN_FIELDS) { if ($sp.PSObject.Properties[$k]) { $texts += [string]$sp.$k } }
      if ($sp.head -and $sp.head.PSObject.Properties['description']) { $texts += [string]$sp.head.description }
      foreach ($txt in $texts) {
        if ([string]::IsNullOrEmpty($txt)) { continue }
        if ($txt.Replace('$1 a month','') -notmatch '\$\d') { continue }
        $swept++
        $r = Remove-GhostStaticCurrencyClaims $txt
        # (a) a figure survived, so a claim is still going to go stale on a live card
        if ($r.Replace('$1 a month','') -match '\$\d') { $bad += ($sf.BaseName + ': a dollar figure survived -> ' + $r) }
        # (b) the noun form landed in front of a noun, which is the ungrammatical reading
        if ($r -match 'restaurant (?:money|prices) (?!for\b|at\b|and\b|or\b|to\b|with\b|plus\b|once\b|before\b|after\b|when\b|every\b|instead\b|versus\b|than\b|up\b)[a-z]') {
          $bad += ($sf.BaseName + ': noun form used attributively -> ' + $r)
        }
        # (c) a unit was stranded when its figure moved
        if ($r -match ('(?:far more|restaurant money|restaurant prices|restaurant-priced|extra)\s+(?:a|per|each)\s+(?:' + $units + ')\b')) {
          $bad += ($sf.BaseName + ': a unit was stranded -> ' + $r)
        }
        # (d) the article was left disagreeing with the adjective
        if ($r -match '\ban restaurant-priced\b') { $bad += ($sf.BaseName + ': article disagreement -> ' + $r) }
      }
    }
    T ("CORPUS  all $swept authored prose fields carrying a static dollar figure render as English") `
      ($bad.Count -eq 0) (($bad | Select-Object -First 5) -join ' || ')
  } else {
    T 'CORPUS  the spec corpus is readable' $false "no db\recipes at $specDir - the sweep could not run, which is not a pass"
  }

  if ($f -eq 0) { Write-Output 'SELF-TEST PASS'; exit 0 } else { Write-Output "SELF-TEST FAIL: $f case(s)"; exit 1 }
}
