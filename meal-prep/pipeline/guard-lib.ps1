# guard-lib.ps1 - reusable spec-guard PREDICATES, shared across recipe runs (dot-sourced by
# <run>/spec-guards.ps1). The logic lives here so it compounds run-over-run instead of being
# re-ported (and drifting) each run. pipeline/test-guards.ps1 covers these. Run-specific guards
# (canon rules, overrides, the run's numeric invariants) stay in the run's own spec-guards.

$script:PROTEIN_MARKERS = @('italian sausage','pork sausage','andouille','kielbasa','bratwurst','chorizo',
  'ground beef','ground turkey','ground pork','ground chicken','chicken thigh','chicken breast',
  'chicken drumstick','turkey breast','pork shoulder','pork loin','pork tenderloin','pork chop',
  'pork belly','corned beef','chuck roast','beef chuck','sirloin','flank','beef brisket','diced ham')

# Prose-ingredient drift: a protein/cut marker in head.recipeIngredient must be backed by an actual
# ingredient. Catches an ingredient swap that left the old meat's name in the writer's prose (the
# cassoulet Italian-sausage bug, the 5 breast->thigh / ground->sliced swaps). Returns the unbacked markers.
function Get-ProseIngredientDrift {
  param([string[]]$RecipeIngredientLines, [string[]]$IngredientNames)
  $ingBlob = (($IngredientNames -join ' | ')).ToLower()
  $riBlob  = (($RecipeIngredientLines -join ' ')).ToLower()
  $hits = @()
  foreach ($mk in $script:PROTEIN_MARKERS) {
    if ($riBlob -match [regex]::Escape($mk) -and -not $ingBlob.Contains($mk.TrimEnd('s'))) { $hits += $mk }
  }
  return $hits
}

# Stale superlative: only the actual protein rank-#1 recipe may assert unscoped batch primacy. The
# softened TRUE forms ("one of the highest", "among the") and subset-scoped claims ("highest protein
# SOUP", "in the BEEF half") are exempt. Returns the stale claim strings (empty if $IsRank1).
$script:SUPERLATIVE_PRIMACY_RX = '(?i)(?<!one of )(?<!among )\b(?:the|second)\s+(?:highest|most|biggest)\s+protein\b[^.<"]{0,28}?\b(?:batch|collection|page|group|lineup|library|section)\b'
$script:SUPERLATIVE_SUBSET_RX  = '(?i)\b(?:soup|stew|chili|bowl|bake|casserole|skillet|noodle|beef|chicken|pork|turkey|half)\b'
function Get-StaleSuperlativeClaims {
  param([string[]]$ReaderStrings, [bool]$IsRank1)
  if ($IsRank1) { return @() }
  $hits = @()
  foreach ($s in $ReaderStrings) {
    if (-not $s) { continue }
    foreach ($m in [regex]::Matches([string]$s, $script:SUPERLATIVE_PRIMACY_RX)) {
      if ($m.Value -notmatch $script:SUPERLATIVE_SUBSET_RX) { $hits += $m.Value.Trim() }
    }
  }
  return $hits
}

# ---------------------------------------------------------------------------------------------------
# BULLET-FIELD SHAPE (2026-09-02). A spec field the card renders as a LIST must BE a list.
#
# THE FOUNDING BUG, measured. build-card2.ps1 renders three fields with the same shape:
#     foreach($li in $spec.shop_smart){ $L.Add('<li>' + $li + '</li>') }
# In PowerShell 5.1 `foreach` over a STRING iterates the string ONCE, not per character and not per
# line. So a spec that stored shop_smart as one newline-joined string shipped all three of its tips
# inside a SINGLE <li>, and HTML collapses those newlines to spaces - one run-on bullet with three
# shopping tips jammed end to end. It renders without erroring, the card builds, every other gate is
# green, and only a reader can see it. 51 of 584 specs stored shop_smart as a string; 48 of those held
# more than one tip, and 47 of them were live and paid.
#
# There were TWO string populations and the second is why this is a SHAPE rule and not a newline rule:
# 37 specs joined their tips with a newline (no visible separator at all on the card), and 11 wrapped
# them in <p> tags inside the one string (one bullet marker carrying two to four paragraphs). A guard
# written against the newline would have passed all eleven.
#
# WHY IT REFUSES RATHER THAN COERCING. Splitting a string here would guess where the tips divide, and
# the two populations divide differently. The spec is the artifact worth fixing; a renderer that
# silently repairs its input hides the defect in every spec written afterwards.
#
# Returns '' when the shape is right, or the reason it is not. $null is a problem too: an absent field
# renders as nothing at all, which is the could-not-look-is-not-a-clean-bill shape.
function Get-BulletFieldShapeProblem {
  param([string]$Field, $Value)
  if ($null -eq $Value) { return ("{0} is absent - the card would render an empty list rather than fail" -f $Field) }
  if ($Value -is [string]) {
    return ("{0} is a STRING, not an array. PowerShell 5.1 iterates a string ONCE, so build-card2 would ship every item in it inside one <li>. Store one array element per bullet." -f $Field)
  }
  if ($Value -is [System.Collections.IEnumerable]) { return '' }
  return ("{0} is a {1}, not an array" -f $Field, $Value.GetType().Name)
}

# The fields build-card2 renders with `foreach($li in $spec.<field>){ ... <li> ... }`. Kept beside the
# predicate so adding a rendered list field to the card is one edit, not two.
$script:BULLET_FIELDS = @('ingredients_display', 'shop_smart', 'make_it')

function Get-SpecBulletShapeProblems {
  param($Spec)
  $out = @()
  foreach ($f in $script:BULLET_FIELDS) {
    $p = Get-BulletFieldShapeProblem $f $Spec.$f
    if ($p) { $out += $p }
  }
  # `,@(...)`: PS 5.1 UNROLLS a one-element array on function output, so a single problem would come
  # back as a bare string and .Count would read its LENGTH. The same trap wave-publish documents on
  # Get-StaleAuditProblems. Do not simplify to `return @($out)`.
  return , @($out)
}
