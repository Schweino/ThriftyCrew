<#
  sync-recipesdb-macros.ps1 - carry the PER-SERVING MACROS from the specs into recipes-db.json.

  THE GAP THIS FILLS (found 2026-08-27, measured and fixed 2026-08-29). db\recipes\<slug>.json's `stat`
  block is where a recipe's macros are AUTHORED; recipes-db.json keeps its own `per_serving` copy, written
  once at import and never refreshed. The two surfaces then SPLIT: the cards and the JSON-LD Google indexes
  print the SPEC numbers, while the feed, the hub grid and the related-recipe cards print the INDEX numbers.
  On 127 recipes a reader could see two different calorie counts for the same dish - worst gap 249 cal
  (slow-cooker-king-ranch-chicken-bowls, spec 816 vs index 567).

  Nothing said so. engine\audit-db-agreement.ps1 compared slug sets, protein, the COST block and ingredient
  lists, and had no macro check at all - the exact blind-spot shape the cost block had before 2026-08-04,
  and sync-recipesdb-cost.ps1 is this file's direct model.

  DIRECTION WAS NOT ASSUMED, IT WAS MEASURED. The founding alert warned that the direction might not be
  uniform and that a triage read was needed before any bulk sync. So the arithmetic was asked instead of a
  preference: for all 127, Get-MacroRecompute was run over the spec's OWN ingredients_grams x
  food-macros-db - the same rule build-v2-spec.ps1 throws on at write time - and compared to both stored
  blocks. The recompute agreed with the SPEC 108 times and with the INDEX exactly ZERO times; the other 19
  were cases where the spec matched the recompute to the calorie and the index was 1-4 out. The spec is
  authoritative in 127 of 127, so this is a derived-copy refresh and not a judgement call.

  THE GATE: A SPEC MUST EARN THE RIGHT TO OVERWRITE. Same rule sync-recipesdb-cost applies to the cost
  block - a spec whose own numbers do not survive recomputation is broken at the source, and a sync that
  copied it anyway would launder a bad number into the index and call the result agreement. Any spec whose
  stat disagrees with the recompute of its own ingredients is REFUSED and named, never carried.

  AND `batch` MOVES WITH `per_serving`, because it is derived from it: batch = per_serving x servings holds
  in all 576 rows today. Patching per_serving alone would leave 127 rows internally inconsistent - breaking
  an invariant that is currently perfect, in the name of fixing a different one.

  TEXT SURGERY, NOT A ROUND TRIP. recipes-db.json is 3.6 MB; PS 5.1's ConvertTo-Json on a file that size is
  a documented OOM/corruption trap in this estate (refree-clobbered.ps1's own note). The macro keys appear
  TWICE per row - once in per_serving, once in batch - so every patch is scoped to the named object first.

  Read-only unless -Apply.
  Usage: .\sync-recipesdb-macros.ps1 [-Apply]   |   .\sync-recipesdb-macros.ps1 -SelfTest
#>
param([switch]$Apply, [switch]$SelfTest, [string]$Root = '')
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
# $PSScriptRoot is meal-prep\pipeline, so meal-prep is one level up and the repo root is two.
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp = Split-Path $here -Parent
if (-not $Root) { $Root = Split-Path $mp -Parent }
. (Join-Path $mp 'lib\json-db-io.ps1')
. (Join-Path $mp 'pipeline\macro-recompute-lib.ps1')

# spec key -> index key. They are NOT the same names, which is what made a naive comparison return a
# confident zero the first time this was measured: every field lookup missed on one side and was skipped.
$script:MACRO_PAIRS = @(
  @{ Spec = 'cal';     Idx = 'calories'  },
  @{ Spec = 'protein'; Idx = 'protein_g' },
  @{ Spec = 'carbs';   Idx = 'carbs_g'   },
  @{ Spec = 'fat';     Idx = 'fat_g'     }
)

function Get-FoodDb([string]$path) {
  $h = @{}
  $fd = Read-JsonFile $path
  foreach ($r in @($fd.items)) { if ($r.item) { $h[[string]$r.item] = $r } }
  return $h
}

function Test-SpecStatEarnsTrust {
  <# Returns '' when the spec's own stat survives a recompute of its own ingredients, else the reason. #>
  param($Spec, $Db)
  $rows = @($Spec.ingredients_grams)
  $sv = [double]$Spec.servings
  if (-not $rows -or $rows.Count -eq 0) { return 'no ingredients_grams to recompute from' }
  if ($sv -le 0) { return 'servings is not a positive number' }
  $rc = Get-MacroRecompute -Rows $rows -Db $Db -Servings $sv
  if (-not $rc -or $null -eq $rc.cal) { return 'the recompute produced nothing' }
  if (@($rc.missing).Count -gt 0) { return ('food-DB rows missing for: ' + ((@($rc.missing) | Select-Object -First 4) -join ', ')) }
  if ([math]::Abs([double]$rc.cal - [double]$Spec.stat.cal) -gt 5) {
    return ('spec cal ' + $Spec.stat.cal + ' does not survive its own recompute (' + [math]::Round($rc.cal) + ')')
  }
  if ([math]::Abs([double]$rc.protein - [double]$Spec.stat.protein) -gt 2) {
    return ('spec protein ' + $Spec.stat.protein + ' does not survive its own recompute (' + [math]::Round($rc.protein) + ')')
  }
  return ''
}

if ($SelfTest) {
  $f = 0; $p = 0
  function T($cond, $msg, $got = '') { if ($cond) { Write-Output ('  PASS  ' + $msg); $script:p++ } else { Write-Output ('  FAIL  ' + $msg + $(if ($got) { "  got: $got" } else { '' })); $script:f++ } }
  Write-Output 'sync-recipesdb-macros -SelfTest'

  # THE FIELD-NAME PAIRING IS THE WHOLE POINT. spec.stat is cal/protein/carbs/fat and index.per_serving is
  # calories/protein_g/carbs_g/fat_g. Comparing like-for-like names finds NOTHING and reports it as clean.
  T ($script:MACRO_PAIRS.Count -eq 4) 'all four macros are paired'
  # @() BEFORE .Count: in PS 5.1 a single hashtable's .Count is its KEY count, so a Where-Object that
  # matches exactly one pair reported 2 and this case failed against a correct table.
  T (@($script:MACRO_PAIRS | Where-Object { $_.Spec -eq $_.Idx }).Count -eq 0) 'no pair uses the same name on both sides - the names genuinely differ'
  T (@($script:MACRO_PAIRS | Where-Object { $_.Spec -eq 'cal' -and $_.Idx -eq 'calories' }).Count -eq 1) 'cal maps to calories, not to itself'

  $db = @{ 'Chicken' = [pscustomobject]@{ item='Chicken'; serving_grams=100; calories=200; protein_g=30; carbs_g=0; fat_g=8 } }
  $good = [pscustomobject]@{ servings = 2; ingredients_grams = @([pscustomobject]@{ item='Chicken'; grams=200 })
                             stat = [pscustomobject]@{ cal=200; protein=30; carbs=0; fat=8 } }
  T ((Test-SpecStatEarnsTrust -Spec $good -Db $db) -eq '') 'a spec whose stat survives its own recompute is trusted'
  # MUST REFUSE: the founding rule. A spec that cannot reproduce its own numbers must never overwrite the index.
  $bad = [pscustomobject]@{ servings = 2; ingredients_grams = @([pscustomobject]@{ item='Chicken'; grams=200 })
                            stat = [pscustomobject]@{ cal=900; protein=30; carbs=0; fat=8 } }
  T ((Test-SpecStatEarnsTrust -Spec $bad -Db $db) -ne '') 'a spec whose stat does NOT survive its own recompute is REFUSED, not laundered into the index'
  $miss = [pscustomobject]@{ servings = 2; ingredients_grams = @([pscustomobject]@{ item='Unknown Food'; grams=200 })
                             stat = [pscustomobject]@{ cal=200; protein=30; carbs=0; fat=8 } }
  T ((Test-SpecStatEarnsTrust -Spec $miss -Db $db) -match 'missing') 'a missing food row is a refusal with a reason, not a silent pass'
  $nosv = [pscustomobject]@{ servings = 0; ingredients_grams = @([pscustomobject]@{ item='Chicken'; grams=200 })
                             stat = [pscustomobject]@{ cal=200; protein=30; carbs=0; fat=8 } }
  T ((Test-SpecStatEarnsTrust -Spec $nosv -Db $db) -ne '') 'servings of zero is refused rather than divided by'

  # batch = per_serving x servings holds in every row today; the patcher must keep it that way.
  # Scoped to the PATCH half deliberately: grepping the whole file matches this assertion's OWN text,
  # which is the self-referential trap that made the first version of this case fail against a correct
  # script. ConvertFrom-Json (parsing) is fine and is used for the per-row proofs; what must never appear
  # is a ConvertTo-Json re-serialisation of the 3.6 MB index.
  $src = Get-Content $PSCommandPath -Raw
  $patchHalf = ($src -split '(?m)^# -+ patch')[-1]
  T ($patchHalf -match "(?s)'per_serving'.*'batch'") 'the patcher touches BOTH per_serving and batch'
  T ($patchHalf -notmatch 'ConvertTo-Json') 'the patch half never round-trips the index through ConvertTo-Json (PS 5.1 OOM/corruption trap)'
  T ($patchHalf -match 'WriteAllText') 'the write goes through WriteAllText with an explicit BOM-less UTF8 encoding'
  T ($patchHalf -match 'recipe count moved') 'the whole file is re-parsed and the recipe count proved unchanged BEFORE anything is written'

  if ($f -gt 0) { Write-Output ("sync-recipesdb-macros SELFTEST: $f FAILED"); exit 2 }
  Write-Output ("sync-recipesdb-macros SELFTEST: all $p passed"); exit 0
}

# ---------------------------------------------------------------- gather
$dbFile = Join-Path $mp 'recipes-db.json'
$foodDb = Get-FoodDb (Join-Path $mp 'food-macros-db.json')
Write-Output ("sync-recipesdb-macros: food-DB rows " + $foodDb.Count)
if ($foodDb.Count -eq 0) { Write-Output 'BLIND: the food DB loaded zero rows - nothing can be verified, so nothing will be carried.'; exit 3 }

$want = @{}      # slug -> @{ cal; protein; carbs; fat }
$refused = New-Object System.Collections.Generic.List[string]
foreach ($sf in (Get-ChildItem (Join-Path $mp 'db\recipes\*.json'))) {
  $spec = Read-JsonFile $sf.FullName
  if (-not $spec.stat) { continue }
  $why = Test-SpecStatEarnsTrust -Spec $spec -Db $foodDb
  if ($why) { $refused.Add(($sf.BaseName + ' : ' + $why)); continue }
  $want[$sf.BaseName] = $spec.stat
}
Write-Output ("sync-recipesdb-macros: " + $want.Count + " spec(s) earned the right to carry, " + $refused.Count + " refused")

$raw = Get-Content $dbFile -Raw -Encoding UTF8
$db = $raw | ConvertFrom-Json
$before = @($db.recipes).Count

$changes = New-Object System.Collections.Generic.List[object]
foreach ($r in @($db.recipes)) {
  $slug = [string]$r.slug
  if (-not $want.ContainsKey($slug)) { continue }
  if (-not $r.per_serving) { continue }
  $sv = [double]$r.servings
  $st = $want[$slug]
  foreach ($pr in $script:MACRO_PAIRS) {
    $have = [double]$r.per_serving.($pr.Idx)
    $target = [double]$st.($pr.Spec)
    if ([math]::Abs($have - $target) -le 0.5) { continue }
    $changes.Add([pscustomobject]@{ Slug = $slug; Obj = 'per_serving'; Key = $pr.Idx; Old = $have; New = [math]::Round($target) })
    if ($r.batch -and $sv -gt 0 -and $null -ne $r.batch.($pr.Idx)) {
      $bHave = [double]$r.batch.($pr.Idx)
      $bTarget = [math]::Round([double]$target * $sv)
      if ([math]::Abs($bHave - $bTarget) -gt 0.5) {
        $changes.Add([pscustomobject]@{ Slug = $slug; Obj = 'batch'; Key = $pr.Idx; Old = $bHave; New = $bTarget })
      }
    }
  }
}

$slugsTouched = @($changes | Select-Object -ExpandProperty Slug -Unique)
Write-Output ("sync-recipesdb-macros: " + $changes.Count + " field(s) differ across " + $slugsTouched.Count + " recipe(s)")
foreach ($g in ($changes | Group-Object Slug | Select-Object -First 8)) {
  $bits = @($g.Group | ForEach-Object { $_.Obj + '.' + $_.Key + ' ' + $_.Old + '->' + $_.New })
  Write-Output ('    ' + $g.Name + '  ' + (($bits | Select-Object -First 4) -join ', '))
}
if ($refused.Count) {
  Write-Output ('  REFUSED (spec cannot reproduce its own macros - not carried):')
  foreach ($x in ($refused | Select-Object -First 10)) { Write-Output ('    ' + $x) }
  if ($refused.Count -gt 10) { Write-Output ('    ... ' + ($refused.Count - 10) + ' more') }
}
if ($changes.Count -eq 0) { Write-Output 'MACRO-SYNC-COMPLETE changed=0'; exit 0 }
if (-not $Apply) { Write-Output 'DRY RUN - nothing written. Re-run with -Apply.'; Write-Output ('MACRO-SYNC-COMPLETE changed=0 pending=' + $changes.Count); exit 0 }

# ---------------------------------------------------------------- patch
$text = $raw
foreach ($g in ($changes | Group-Object Slug)) {
  $slug = $g.Name
  $anchor = '"' + $slug + '"'
  $si = $text.IndexOf($anchor)
  if ($si -lt 0) { throw "macro-sync: slug not found: $slug" }
  if ($text.IndexOf($anchor, $si + 1) -ge 0) { throw "macro-sync: slug not unique: $slug" }
  $depth = 0; $rowStart = -1
  for ($i = $si; $i -ge 0; $i--) { $c = $text[$i]; if ($c -eq '}') { $depth++ } elseif ($c -eq '{') { if ($depth -eq 0) { $rowStart = $i; break } else { $depth-- } } }
  $depth = 0; $rowEnd = -1
  for ($i = $si; $i -lt $text.Length; $i++) { $c = $text[$i]; if ($c -eq '{') { $depth++ } elseif ($c -eq '}') { if ($depth -eq 0) { $rowEnd = $i; break } else { $depth-- } } }
  if ($rowStart -lt 0 -or $rowEnd -lt 0) { throw "macro-sync: brace match failed for $slug" }
  $row = $text.Substring($rowStart, $rowEnd - $rowStart + 1)
  if (($row -split '"slug"').Count -ne 2) { throw "macro-sync: row spans !=1 slug for $slug (abort)" }

  foreach ($objName in @('per_serving', 'batch')) {
    $mine = @($g.Group | Where-Object { $_.Obj -eq $objName })
    if ($mine.Count -eq 0) { continue }
    # SCOPE TO THE NAMED OBJECT FIRST. calories/protein_g/carbs_g/fat_g each appear TWICE in a row - once
    # under per_serving and once under batch - so a bare key search would patch whichever came first.
    $oAt = Find-JsonValueStart -Raw $row -Key $objName
    if ($oAt -lt 0) { throw "macro-sync: $slug has no $objName key" }
    if ((Find-JsonValueStart -Raw $row -Key $objName -Nth 2) -ge 0) { throw "macro-sync: $slug has $objName twice (abort)" }
    $oStart = $row.IndexOf('{', $oAt)
    if ($oStart -lt 0) { throw "macro-sync: $slug $objName is not an object" }
    $d2 = 0; $oEnd = -1
    for ($i = $oStart; $i -lt $row.Length; $i++) { $c = $row[$i]; if ($c -eq '{') { $d2++ } elseif ($c -eq '}') { $d2--; if ($d2 -eq 0) { $oEnd = $i; break } } }
    if ($oEnd -lt 0) { throw "macro-sync: $slug $objName brace match failed" }
    $obj = $row.Substring($oStart, $oEnd - $oStart + 1)

    $todo = New-Object System.Collections.Generic.List[object]
    foreach ($ch in $mine) {
      $at = Find-JsonValueStart -Raw $obj -Key $ch.Key
      if ($at -lt 0) { throw "macro-sync: $slug $objName has no $($ch.Key)" }
      $sp = Get-JsonNumberSpan -Raw $obj -Start $at
      $cur = [double]$obj.Substring($sp.Start, $sp.End - $sp.Start + 1)
      if ([math]::Abs($cur - [double]$ch.Old) -gt 0.5) { throw "macro-sync: $slug $objName.$($ch.Key) is $cur, expected $($ch.Old)" }
      $todo.Add([pscustomobject]@{ Span = $sp; Ch = $ch })
    }
    foreach ($t in @($todo | Sort-Object { $_.Span.Start } -Descending)) {
      $sp = $t.Span
      $obj = $obj.Substring(0, $sp.Start) + ([string][int]$t.Ch.New) + $obj.Substring($sp.End + 1)
    }
    $null = $obj | ConvertFrom-Json   # the patched object must still parse on its own
    $row = $row.Substring(0, $oStart) + $obj + $row.Substring($oEnd + 1)
  }
  $null = $row | ConvertFrom-Json     # and so must the whole row
  $text = $text.Substring(0, $rowStart) + $row + $text.Substring($rowEnd + 1)
}

# WHOLE-FILE PROOF BEFORE ANYTHING IS WRITTEN.
$after = $text | ConvertFrom-Json
if (@($after.recipes).Count -ne $before) { throw ("macro-sync: recipe count moved " + $before + ' -> ' + @($after.recipes).Count + ' (abort, nothing written)') }
$bak = $dbFile + '.bak-macrosync'
Copy-Item $dbFile $bak -Force
[IO.File]::WriteAllText($dbFile, $text, (New-Object System.Text.UTF8Encoding($false)))
Write-Output ('  wrote recipes-db.json (backup -> ' + (Split-Path $bak -Leaf) + ')')
Write-Output ("MACRO-SYNC-COMPLETE changed=" + $changes.Count + " recipes=" + $slugsTouched.Count)
exit 0
