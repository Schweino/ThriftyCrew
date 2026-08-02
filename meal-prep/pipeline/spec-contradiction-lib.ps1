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

function Get-SpecContradictions($spec) {
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
    # A bare "$12" is the takeout comparison the sentence is built on; a $N.NN in the two COST fields is a
    # per-serving claim by construction, because spec-guards requires both to quote the current cost exactly.
    if ($k -eq 'cost_closing_html' -or $k -eq 'upsell_html') {
      foreach ($m in [regex]::Matches($t, '\$\d+\.\d{2}')) {
        if ($m.Value -ne ('$' + $cps)) { $f.Add(@{ cls = 'STALE-MONEY'; why = ("$k quotes " + $m.Value + " but the per-serving cost is `$$cps") }) }
      }
    }
    foreach ($m in [regex]::Matches($t, '(?i)\b\d{1,3}\s*cents\b')) {
      $f.Add(@{ cls = 'STALE-MONEY'; why = ("$k quotes '" + $m.Value + "' - a per-line cents figure from a basis the cost redesign removed") })
    }
  }

  foreach ($li in (@(@($spec.ingredients_display) + @($spec.cost_lines)) | Where-Object { $_ })) {
    $s = [string]$li
    $clean = (($s -replace '<[^>]+>', '') -replace '\s+', ' ').Trim()
    foreach ($m in [regex]::Matches($s, '(?<![\d.])0\s*(lb|lbs|oz|cups?|tbsp|tsp)\b')) {
      $f.Add(@{ cls = 'ZERO-QTY'; why = ("a line reads '" + $m.Value.Trim() + "': " + $clean) })
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

  $steps = (@($spec.make_it) -join ' ').ToLower()
  if ($steps) {
    foreach ($key in $disp.Keys) {
      if ($key.Length -lt 4) { continue }
      $head = ($key -split ' ')[-1]
      if ($head.Length -lt 4) { $head = $key }
      if ($steps -notmatch ('\b' + [regex]::Escape($head))) { $f.Add(@{ cls = 'UNUSED'; why = ("'" + $key + "' is bought and costed but never named in a step") }) }
    }
  }
  return $f
}
