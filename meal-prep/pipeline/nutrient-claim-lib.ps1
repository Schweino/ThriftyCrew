# nutrient-claim-lib.ps1 - THE FDA nutrient content claim rule over a recipe spec (Brad's ruling, I143).
#
# THE RULING (2026-09-19): "rule for new, measure old". A NEW recipe may use an FDA-defined nutrient content
# claim word ("high protein", "low fat", "light", "lean"...) only where the recipe meets that claim's FDA
# numeric bar computed from its own per-serving macros. The live catalogue is MEASURED
# (audit-nutrient-claims.ps1 writes design\ready-for-brad\I143-claim-words.md) and no live page changes.
#
# WHY THESE WORDS ARE DIFFERENT FROM THE HEALTH WORDS (I138). "Healthy" has no definition a recipe could
# clear here, so forbidden-prose-lib bans it outright. A nutrient content claim HAS one: it is a closed,
# FDA-defined vocabulary with codified numeric conditions, and pre-approval is not required precisely
# BECAUSE the condition is written in regulation - so writing the word IS the assertion that the food meets
# it. That makes the rule a computation, not a ban: the word is legal exactly when the number clears.
#
# THE LIST IS DATA: the nutrient_claims block of meal-prep\pipeline\forbidden-prose-global.json, beside the
# health words, carrying each claim's patterns, its CFR citation and its bar. One list, so the import door,
# the pre-audit and the measurement cannot disagree about what a claim word is.
#
# THE BAR VOCABULARY IS CLOSED (see bar_kinds in the JSON) and an unknown kind THROWS: an unrecognised bar
# would otherwise decide by falling through to whichever branch happened to be last. A bar whose number
# the spec does not carry (sodium, sugars, fibre, saturated fat, cholesterol, a reference food) is
# NOT-COMPUTABLE, and a not-computable claim is REFUSED on a new recipe: a claim we cannot show is a claim
# we cannot make, which is the direction that does not lose a reader's trust.
#
# AN INGREDIENT'S OWN PRODUCT NAME IS NOT OUR CLAIM. "Fat Free Cottage Cheese" and "BBQ Sauce (Sugar Free)"
# are the manufacturers' claims, correctly transcribed. Four layers keep them out (same design as the
# 2026-09-12 draft on approvals-i143, which found the second layer's load-bearing half):
#   1. fields RENDERED from the ingredient list are not read ($TC_NUTRIENT_CLAIM_SKIP);
#   2. in prose, an occurrence immediately beside a word of an ingredient this recipe buys WHOSE OWN NAME OR
#      BUY LABEL CARRIES THE SAME CLAIM WORD is exempt. The second half matters: without it
#      "high-protein chicken bowls" is exempt because chicken is an ingredient, which is the dish claim
#      this file exists to find;
#   3. a claim marked product_variant (fat free, low sodium, sugar free, reduced fat...: words a STORE names a
#      variant with) directly BEFORE a product word - a word of any ingredient bought, or a generic product noun -
#      describes that product: 'the low-fat kind', '1/3 less fat cream cheese'. Protein, low calorie and the
#      light shapes are not marked: 'high-protein chicken bowls' is a claim about the bowls;
#   4. a claim's exempt_contexts (lean ON, 93/7 lean, lean ground turkey - a USDA meat descriptor).
#
# UNSOUND BY CONSTRUCTION: this is a pattern matcher over prose, so a reported claim is real and a clean
# report proves only that none of the listed spellings appears.
#
# NO param() BLOCK, DELIBERATELY - a dot-sourced param block runs in the CALLER's scope under PS 5.1 and
# would reset the caller's own -SelfTest switch (guard-contract.ps1's header records the case).
#
# Dot-source:  . (Join-Path $here 'nutrient-claim-lib.ps1')

$script:TC_NUTRIENT_CLAIM_DIR = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $script:TC_NUTRIENT_CLAIM_DIR 'forbidden-prose-lib.ps1')   # the ONE list file and the ONE field walk

# The fields this rule does not read: the health-word skip list plus the five RENDERED from the ingredient
# list, where a claim word is the product's name by construction:
#   ingredients_display  "<strong>Fat Free Cheddar (Great Value):</strong> 1 3/4 cups (196 g)"
#   ingredients_grams    the canonical item name and its batch grams
#   scaler               item / canon / buy / bid, the live scaler's copy of the same names
#   cost_lines           "Fat Free Cheddar, 1 3/4 cups: ~$1.94."
#   recipeIngredient     head.recipeIngredient, the JSON-LD copy of ingredients_display
$script:TC_NUTRIENT_CLAIM_SKIP = @(
  'forbidden_prose_terms', 'writer_notes', 'tuning',
  'credit_html', 'source_url', 'source_site', 'slug',
  'ingredients_display', 'ingredients_grams', 'scaler', 'cost_lines', 'recipeIngredient'
)

# 21 CFR 101.13(m): a main dish weighs at least 6 oz per labeled serving. 6 x 28.3495 g. Regulatory, not tuned.
$script:TC_MAIN_DISH_MIN_G = 170.1
$script:TC_NUTRIENT_BAR_KINDS = @('min_protein_g', 'lt_fat_g_per_serving', 'lt_cal_per_serving', 'low_fat', 'low_calorie', 'light', 'not_computable')

# The claims, as objects carrying the compiled regex, the exempt regexes and the bar. Reads the JSON every
# call: it is one small file and a cached copy is one more thing that can be stale inside a long lane.
function Get-TcNutrientClaim {
  param([string]$ListFile = '')
  if (-not $ListFile) { $ListFile = Get-TcForbiddenProsePath -Root $script:TC_NUTRIENT_CLAIM_DIR }
  if (-not (Test-Path -LiteralPath $ListFile)) {
    throw ("nutrient-claim-lib: the global list is missing: " + $ListFile + " - a sweep with no list is a clean report that proves nothing, so this refuses rather than passing")
  }
  $doc = Get-Content -LiteralPath $ListFile -Raw -Encoding utf8 | ConvertFrom-Json
  $out = New-Object System.Collections.Generic.List[object]
  foreach ($c in @($doc.nutrient_claims.claims)) {
    if (-not $c -or -not $c.id) { continue }
    $kind = [string]$c.bar.kind
    if ($script:TC_NUTRIENT_BAR_KINDS -notcontains $kind) {
      throw ("nutrient-claim-lib: claim '" + [string]$c.id + "' carries bar kind '" + $kind + "', which is not in the closed vocabulary (" + ($script:TC_NUTRIENT_BAR_KINDS -join ', ') + ").")
    }
    $pats = @($c.patterns | Where-Object { $_ })
    if (-not $pats.Count) { throw ("nutrient-claim-lib: claim '" + [string]$c.id + "' has no patterns") }
    $rx = [regex]::new('(?i)\b(?:' + ($pats -join '|') + ')\b')
    $ex = @()
    foreach ($e in @($c.exempt_contexts | Where-Object { $_ })) { $ex += [regex]::new('(?i)' + [string]$e) }
    $out.Add([pscustomobject]@{
      Id = [string]$c.id; Label = [string]$c.label; Cfr = [string]$c.cfr; Reason = [string]$c.reason
      Kind = $kind; Value = $(if ($null -ne $c.bar.value) { [double]$c.bar.value } else { $null }); Missing = [string]$c.bar.missing
      Rx = $rx; Exempt = $ex; ProductVariant = [bool]$c.product_variant
    })
  }
  # The generic product nouns (kind, version, tub...) ride on every claim object as ONE shared set, so a caller
  # still passes a single value around. The set is ::new with the comparer, never New-Object (see Get-TcClaimWordSet).
  $nouns = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach ($n in @($doc.nutrient_claims.product_nouns)) { if ($n) { [void]$nouns.Add([string]$n) } }
  foreach ($o in $out) { $o | Add-Member -NotePropertyName ProductNouns -NotePropertyValue $nouns }
  if ($out.Count -eq 0) {
    throw ("nutrient-claim-lib: the list parsed to ZERO nutrient claims: " + $ListFile + " - an empty list cannot fire, so this refuses rather than reporting clean")
  }
  return $out.ToArray()
}

# What the spec says about one serving. Every number comes from the spec itself: stat (what the card prints)
# and ingredients_grams / servings (the raw serving weight - the spec carries no cooked weight).
function Get-TcNutritionBasis {
  param($Spec)
  $b = [ordered]@{ cal = $null; protein = $null; fat = $null; serving_g = $null; main_dish = $false; why = '' }
  $st = $Spec.stat
  if ($null -eq $st) { $b.why = 'the spec carries no stat block'; return [pscustomobject]$b }
  foreach ($k in @('cal', 'protein', 'fat')) {
    $v = $st.$k
    if ($null -ne $v -and "$v" -ne '') { $b[$k] = [double]$v }
  }
  $serv = 0; if ($null -ne $Spec.servings) { $serv = [double]$Spec.servings }
  $grams = 0.0
  foreach ($g in @($Spec.ingredients_grams)) { if ($g -and $null -ne $g.grams) { $grams += [double]$g.grams } }
  if ($serv -gt 0 -and $grams -gt 0) {
    $b.serving_g = [Math]::Round($grams / $serv, 1)
    $b.main_dish = ($b.serving_g -ge $script:TC_MAIN_DISH_MIN_G)
  }
  return [pscustomobject]$b
}

# One claim against one basis. Returns Verdict (pass | fail | not-computable) and Shown, the calculation in
# words, because the ruling is that we can SHOW the number behind the word.
function Test-TcNutrientClaimBar {
  param($Claim, $Basis)
  $r = { param($v, $s) [pscustomobject]@{ Verdict = $v; Shown = $s } }
  switch ($Claim.Kind) {
    'not_computable' { return (& $r 'not-computable' ('needs ' + $Claim.Missing)) }
    'min_protein_g' {
      if ($null -eq $Basis.protein) { return (& $r 'not-computable' 'the spec states no protein per serving') }
      $ok = ($Basis.protein -ge $Claim.Value)
      return (& $r $(if ($ok) { 'pass' } else { 'fail' }) ('{0} g protein per serving against {1} g or more' -f $Basis.protein, $Claim.Value))
    }
    'lt_fat_g_per_serving' {
      if ($null -eq $Basis.fat) { return (& $r 'not-computable' 'the spec states no fat per serving') }
      $ok = ($Basis.fat -lt $Claim.Value)
      return (& $r $(if ($ok) { 'pass' } else { 'fail' }) ('{0} g fat per serving against under {1} g' -f $Basis.fat, $Claim.Value))
    }
    'lt_cal_per_serving' {
      if ($null -eq $Basis.cal) { return (& $r 'not-computable' 'the spec states no calories per serving') }
      $ok = ($Basis.cal -lt $Claim.Value)
      return (& $r $(if ($ok) { 'pass' } else { 'fail' }) ('{0} calories per serving against under {1}' -f $Basis.cal, $Claim.Value))
    }
    'low_fat' { return (Test-TcLowFat $Basis) }
    'low_calorie' { return (Test-TcLowCalorie $Basis) }
    'light' {
      if (-not $Basis.main_dish) { return (& $r 'not-computable' 'light on a serving under 6 oz needs a reference food (101.56(b)), which the spec names none of') }
      $lf = Test-TcLowFat $Basis; $lc = Test-TcLowCalorie $Basis
      if ($lf.Verdict -eq 'pass' -or $lc.Verdict -eq 'pass') { return (& $r 'pass' ('meets low fat or low calorie: ' + $lf.Shown + '; ' + $lc.Shown)) }
      if ($lf.Verdict -eq 'not-computable' -and $lc.Verdict -eq 'not-computable') { return (& $r 'not-computable' ($lf.Shown + '; ' + $lc.Shown)) }
      return (& $r 'fail' ('meets neither: ' + $lf.Shown + '; ' + $lc.Shown))
    }
    default { throw ("nutrient-claim-lib: unhandled bar kind '" + $Claim.Kind + "'") }
  }
}

function Test-TcLowFat {
  param($Basis)
  if ($null -eq $Basis.fat) { return [pscustomobject]@{ Verdict = 'not-computable'; Shown = 'the spec states no fat per serving' } }
  if ($Basis.main_dish) {
    if ($null -eq $Basis.cal -or $Basis.cal -le 0) { return [pscustomobject]@{ Verdict = 'not-computable'; Shown = 'the spec states no calories per serving' } }
    $per100 = [Math]::Round($Basis.fat * 100.0 / $Basis.serving_g, 2)
    $pct = [Math]::Round($Basis.fat * 9.0 * 100.0 / $Basis.cal, 1)
    $ok = ($per100 -le 3.0 -and $pct -le 30.0)
    return [pscustomobject]@{ Verdict = $(if ($ok) { 'pass' } else { 'fail' }); Shown = ('{0} g fat per 100 g (3 or less) and {1}% of calories from fat (30 or less), main dish at {2} g a serving' -f $per100, $pct, $Basis.serving_g) }
  }
  $ok2 = ($Basis.fat -le 3.0)
  return [pscustomobject]@{ Verdict = $(if ($ok2) { 'pass' } else { 'fail' }); Shown = ('{0} g fat per serving (3 or less)' -f $Basis.fat) }
}

function Test-TcLowCalorie {
  param($Basis)
  if ($null -eq $Basis.cal) { return [pscustomobject]@{ Verdict = 'not-computable'; Shown = 'the spec states no calories per serving' } }
  if ($Basis.main_dish) {
    $per100 = [Math]::Round($Basis.cal * 100.0 / $Basis.serving_g, 1)
    $ok = ($per100 -le 120.0)
    return [pscustomobject]@{ Verdict = $(if ($ok) { 'pass' } else { 'fail' }); Shown = ('{0} calories per 100 g (120 or less), main dish at {1} g a serving' -f $per100, $Basis.serving_g) }
  }
  $ok2 = ($Basis.cal -le 40.0)
  return [pscustomobject]@{ Verdict = $(if ($ok2) { 'pass' } else { 'fail' }); Shown = ('{0} calories per serving (40 or less)' -f $Basis.cal) }
}

# One entry per ingredient row: every string that names it, and the words inside them. The strings decide
# whether the product's own name carries a claim word; the words decide adjacency.
function Get-TcClaimIngredientEntry {
  param($Spec)
  $rows = New-Object System.Collections.Generic.List[object]
  foreach ($g in @($Spec.ingredients_grams)) { if ($g) { $rows.Add(@([string]$g.item)) } }
  if ($Spec.scaler) {
    foreach ($s in @($Spec.scaler.ing)) {
      if (-not $s) { continue }
      $rows.Add(@([string]$s.item, [string]$s.canon, [string]$s.buy, [string]$s.bid))
    }
  }
  $out = New-Object System.Collections.Generic.List[object]
  foreach ($r in $rows) {
    $strs = @($r | Where-Object { $_ })
    if (-not $strs.Count) { continue }
    $words = New-Object System.Collections.Generic.List[string]
    foreach ($str in $strs) { foreach ($w in ([regex]::Split($str, '[^A-Za-z0-9]+'))) { if ($w.Length -ge 2) { $words.Add($w) } } }
    $out.Add([pscustomobject]@{ Strings = $strs; Words = $words.ToArray() })
  }
  return ,$out.ToArray()
}

# The words of every ingredient whose own name or buy label matches $Rx (the claim), and separately the
# words of EVERY ingredient (for the report's "sits beside a product" column). ::new with the comparer, and
# the unary comma on return: PS 5.1 enumerates a returned HashSet into an Object[] whose .Contains is
# ORDINAL and case-sensitive, which is how the 2026-09-12 draft's first run reported 78 false findings.
function Get-TcClaimWordSet {
  param($Entries, $Rx)
  $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach ($e in @($Entries)) {
    if ($null -ne $Rx) {
      $carries = $false
      foreach ($str in $e.Strings) { if ($Rx.IsMatch($str)) { $carries = $true; break } }
      if (-not $carries) { continue }
    }
    foreach ($w in $e.Words) { [void]$set.Add($w) }
  }
  return ,$set
}

function Test-TcClaimAdjacent {
  param([string]$Text, [int]$Index, [int]$Length, $Words)
  if ($null -eq $Words -or $Words.Count -eq 0) { return $false }
  $m = [regex]::Match($Text.Substring($Index + $Length), '^[- ]([A-Za-z0-9]+)')
  if ($m.Success -and $Words.Contains($m.Groups[1].Value)) { return $true }
  $m2 = [regex]::Match($Text.Substring(0, $Index), '([A-Za-z0-9]+)[- ]$')
  if ($m2.Success -and $Words.Contains($m2.Groups[1].Value)) { return $true }
  return $false
}

# A product-variant claim word directly BEFORE a product word describes that product: the next word is a word of any
# ingredient this recipe buys, or a generic product noun (kind, version, tub...). Only the FOLLOWING word counts,
# because a claim word modifies what comes after it; 'the chicken, low fat' is not a product name.
function Test-TcClaimBeforeProduct {
  param([string]$Text, [int]$Index, [int]$Length, $Words, $Nouns)
  $m = [regex]::Match($Text.Substring($Index + $Length), '^[- ]([A-Za-z0-9]+)')
  if (-not $m.Success) { return $false }
  $w = $m.Groups[1].Value
  if ($null -ne $Nouns -and $Nouns.Contains($w)) { return $true }
  if ($null -ne $Words -and $Words.Contains($w)) { return $true }
  return $false
}

# Every use of a claim word in this spec that IS our claim (after the three exemptions), with its verdict.
# Overlapping matches (no sugar / no sugar added, low sodium / very low sodium) keep the LONGEST span once.
function Get-TcNutrientClaimUse {
  param($Spec, $Claims = $null)
  if ($null -eq $Claims) { $Claims = Get-TcNutrientClaim }
  $strings = Get-TcReaderProseString -Spec $Spec -Skip $script:TC_NUTRIENT_CLAIM_SKIP
  $basis = Get-TcNutritionBasis $Spec
  $entries = Get-TcClaimIngredientEntry $Spec
  $allWords = Get-TcClaimWordSet $entries $null
  $cand = New-Object System.Collections.Generic.List[object]
  foreach ($c in @($Claims)) {
    $carry = $null
    foreach ($s in $strings) {
      $ms = $c.Rx.Matches($s.Text)
      if ($ms.Count -eq 0) { continue }
      if ($null -eq $carry) { $carry = Get-TcClaimWordSet $entries $c.Rx }
      $exSpans = New-Object System.Collections.Generic.List[object]
      foreach ($erx in $c.Exempt) { foreach ($em in $erx.Matches($s.Text)) { $exSpans.Add(@($em.Index, ($em.Index + $em.Length))) } }
      foreach ($m in $ms) {
        $inEx = $false
        foreach ($sp in $exSpans) { if ($m.Index -ge $sp[0] -and ($m.Index + $m.Length) -le $sp[1]) { $inEx = $true; break } }
        if ($inEx) { continue }
        if (Test-TcClaimAdjacent -Text $s.Text -Index $m.Index -Length $m.Length -Words $carry) { continue }
        if ($c.ProductVariant -and (Test-TcClaimBeforeProduct -Text $s.Text -Index $m.Index -Length $m.Length -Words $allWords -Nouns $c.ProductNouns)) { continue }
        $cand.Add([pscustomobject]@{ Claim = $c; Field = $s.Field; Text = $s.Text; Index = $m.Index; Length = $m.Length; Matched = $m.Value })
      }
    }
  }
  # longest span wins where two claims matched overlapping text in one field
  $sorted = @($cand | Sort-Object -Property @{ Expression = 'Field' }, @{ Expression = 'Index' }, @{ Expression = 'Length'; Descending = $true })
  $out = New-Object System.Collections.Generic.List[object]
  $lastField = $null; $lastEnd = -1
  foreach ($u in $sorted) {
    if ($u.Field -eq $lastField -and $u.Index -lt $lastEnd) { continue }
    $lastField = $u.Field; $lastEnd = $u.Index + $u.Length
    $bar = Test-TcNutrientClaimBar $u.Claim $basis
    $st = [Math]::Max(0, $u.Index - 40)
    $out.Add([pscustomobject]@{
      ClaimId = $u.Claim.Id; Label = $u.Claim.Label; Cfr = $u.Claim.Cfr
      Field = $u.Field; Matched = $u.Matched
      Excerpt = $u.Text.Substring($st, [Math]::Min(120, $u.Text.Length - $st))
      Verdict = $bar.Verdict; Shown = $bar.Shown
      BesideProduct = (Test-TcClaimAdjacent -Text $u.Text -Index $u.Index -Length $u.Length -Words $allWords)
    })
  }
  return $out.ToArray()
}

# The uses a NEW recipe may not carry: every use whose bar did not pass.
function Get-TcNutrientClaimFinding {
  param($Spec, $Claims = $null)
  return @(Get-TcNutrientClaimUse -Spec $Spec -Claims $Claims | Where-Object { $_.Verdict -ne 'pass' })
}

function Format-TcNutrientClaimFinding {
  param($Hit, [string]$Slug = '')
  $who = if ($Slug) { $Slug + ': ' } else { '' }
  return ($who + "nutrient content claim '" + $Hit.Matched + "' (" + $Hit.Label + ", " + $Hit.Cfr + ") is " + $Hit.Verdict.ToUpper() + " - " + $Hit.Shown + " - in " + $Hit.Field + ": ..." + $Hit.Excerpt + "...")
}

# The refusal text, in ONE place, so the import door and the pre-audit say the same thing.
function Get-TcNutrientClaimRefusal {
  return ("An FDA nutrient content claim word asserts the recipe meets that claim's numeric condition per serving " +
          "(Brad's ruling, 2026-09-19, backlog I143: a NEW recipe may use one only where its own macros clear the bar). " +
          "Print the number instead ('41 g protein per serving'), or, where the word names a product the recipe buys, " +
          "name that product so its own label carries the word. A NOT-COMPUTABLE claim needs a number the spec does not carry, so it cannot be shown and cannot be made.")
}
