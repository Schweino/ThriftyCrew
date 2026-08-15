<#
  normalize-recipe-ids.ps1 - stamp CANONICAL BOARD IDS into recipes-db (2026-07-25, Brad: "redo ALL the
  recipes so it uses the same ID format across the entire site").

  Adds to every ingredient row:   item_id  = the board commodity id from ingredient-map.json (null when the
                                             map has no entry - the 8 evidence-rejected names stay null on
                                             purpose; null means "pantry-static pricing", exactly today's
                                             behavior, never a guess)
  Adds to every recipe:           protein  = chicken|turkey|seafood|beef|pork|other, derived from the
                                             PROTEIN ingredient WITH THE MOST GRAMS (id-based table below -
                                             display names are never regexed again). 'other' = vegetarian
                                             or no classifiable protein.

  ADDITIVE ONLY: no existing field is touched, so every current consumer (top5-weekly, gen-planner-data,
  card generators) is unaffected until it opts into the new fields. Idempotent - safe to re-run after
  recipe adds; run it whenever recipes-db gains recipes (the r100-style pipelines should call it last).
  -Verify prints the classification and writes nothing.
#>
param([switch]$Verify)
$ErrorActionPreference = 'Stop'
$root = 'C:\Codex\ThriftyCrew'
$dbFile = Join-Path $root 'meal-prep\recipes-db.json'

$mp = Get-Content (Join-Path $root 'meal-prep\ingredient-map.json') -Raw | ConvertFrom-Json
$map = @{}
foreach ($e in $mp.mappings) { $map[([string]$e.item).ToLower().Trim()] = [string]$e.board_id }

# id -> protein class. IDs are canonical, so prefix/word matching on them is deterministic - the whole
# point of this normalization. Broths, soups, sauces and snacks are NOT dinner proteins.
function Get-ProteinClass([string]$id) {
  if (-not $id) { return $null }
  if ($id -match 'broth|soup|sauce|jerky|cracker|nugget|bouillon') { return $null }
  # SUBSTRING matches, no anchors: recipe-board ids compose ("boneless-skinless-chicken-thigh",
  # "93-7-ground-turkey") and an anchored pattern silently drops them - that bug classified a chicken
  # dinner as 'other' on the first run. \b works at hyphens, and keeps 'graham-crackers' out of 'ham'.
  if ($id -match 'chicken') { return 'chicken' }
  if ($id -match 'turkey') { return 'turkey' }
  if ($id -match 'salmon|shrimp|tilapia|tuna|\bcod\b|fish') { return 'seafood' }
  if ($id -match 'beef|sirloin|ribeye|chuck|flank|brisket') { return 'beef' }
  if ($id -match '\bpork|bacon|\bham\b|sausage|bratwurst|kielbasa|carnitas|\bribs?\b') { return 'pork' }
  return $null
}

$db = Get-Content $dbFile -Raw | ConvertFrom-Json
$stats = [ordered]@{ recipes=0; ing_rows=0; ing_mapped=0; ing_null=0 }
$protCounts = [ordered]@{ chicken=0; turkey=0; seafood=0; beef=0; pork=0; other=0 }

foreach ($r in $db.recipes) {
  $stats.recipes++
  $best = $null; $bestGrams = -1
  foreach ($ing in @($r.ingredients)) {
    $stats.ing_rows++
    $k = ([string]$ing.item).ToLower().Trim()
    $id = if ($map.ContainsKey($k)) { $map[$k] } else { $null }
    if ($id) { $stats.ing_mapped++ } else { $stats.ing_null++ }
    if ($ing.PSObject.Properties['item_id']) { $ing.item_id = $id }
    else { $ing | Add-Member -NotePropertyName item_id -NotePropertyValue $id }
    $pc = Get-ProteinClass $id
    if ($pc) {
      $g = 0.0; [void][double]::TryParse([string]$ing.grams, [ref]$g)
      if ($g -gt $bestGrams) { $bestGrams = $g; $best = $pc }
    }
  }
  $prot = if ($best) { $best } else { 'other' }
  $protCounts[$prot] = [int]$protCounts[$prot] + 1
  if ($r.PSObject.Properties['protein']) { $r.protein = $prot }
  else { $r | Add-Member -NotePropertyName protein -NotePropertyValue $prot }
  if ($Verify) { Write-Output (($r.slug).PadRight(46) + $prot) }
}

Write-Output ("normalize: {0} recipes, {1} ingredient rows -> {2} mapped to board ids, {3} null (pantry-static, incl. the 8 evidence-rejected names)" -f $stats.recipes, $stats.ing_rows, $stats.ing_mapped, $stats.ing_null)
Write-Output ("proteins: " + (($protCounts.GetEnumerator() | ForEach-Object { $_.Key + '=' + $_.Value }) -join '  '))
if ($Verify) { Write-Output 'VERIFY ONLY - nothing written.'; exit 0 }

Copy-Item $dbFile ($dbFile + '.bak-idnorm') -Force
$db | ConvertTo-Json -Depth 8 | Set-Content $dbFile -Encoding UTF8
Write-Output ("recipes-db.json updated (backup at recipes-db.json.bak-idnorm)")
