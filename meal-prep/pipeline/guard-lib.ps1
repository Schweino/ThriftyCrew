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
