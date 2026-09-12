<#
  audit-published-macros.ps1 - does every published recipe still carry the macros its own ingredients make?

  WHY THIS EXISTS (2026-09-12). The macro recompute that guards a recipe runs at WRITE time only:
  build-v2-spec.ps1 throws past 5 cal / 2 g, and pipeline\wave-preaudit.ps1 recomputes a wave before it
  publishes. Both arrived 2026-08-23/24. 557 of the 583 live recipes (537 paid) were published before that,
  and nothing has recomputed a single one of them since. Two defects sat in that gap:

    * STAT vs RECOMPUTE. Every live spec recomputed from its own ingredients_grams at the guard's own
      tolerance read 560 of 584 pass and 24 fail. Every failure is CARBS recomputing HIGHER, all 24 are paid
      and published before the guard, and Rice is in every one against a base rate of 306 of 584. Consistent
      with the 2026-08-07 Rice re-point (5a884e07f), which moved carbs per gram 0.780 -> 0.800 while its own
      note measured only the calorie and protein effect. About 2 g a serving low on paid pages.

    * INDEX GRAMS vs SPEC GRAMS. recipes-db.json's ingredient list is a COPY of the spec's, and it can keep a
      stale weight while its item NAMES still agree. engine\audit-db-agreement.ps1 compares slug sets,
      protein, the cost block and ingredient count and names - never grams - so it read CLEAN over all of
      this. On 2026-09-12 a restatement of turkey-pozole-rojo was built on the index's 1,914 g of tortillas,
      where the spec carried the 575 g Brad had checked on 2026-08-07, and a correct 460 cal page was
      republished as 652 before it was reverted the same afternoon. The Meal Plan Builder reads the INDEX,
      so a stale index weight is a wrong shopping quantity as well as a trap for the next recompute. On the
      day this shipped, 20 index rows disagreed with their spec: 17 Sweet Whole Kernel Corn at a spec/index
      ratio of 0.689-0.692 and 2 Pineapple Chunks at 0.726-0.727 (the specs moved to drained weight on
      2026-09-02, the index kept whole-can weight), and 1 Salt at 0.667, which is a different shape.

  THE SPEC IS THE AUTHORITY. Recompute from db\recipes\<slug>.json's ingredients_grams, never from the index.
  pipeline\sync-recipesdb-macros.ps1 measured it before this file existed: across 127 disagreeing recipes the
  recompute agreed with the SPEC 108 times and the INDEX zero times.

  A RATCHET, NOT A GATE, deliberately: 24 + 20 findings on day one, and a check that is red every morning is a
  check people learn to scroll past. The baseline records WHICH recipes fail, not only how many, because a
  count cannot see a swap - one recipe fixed while another breaks reads as "held". A NEW name fails the run
  even when the count did not move.

  A PLAIN RUN WRITES NOTHING (the rule ops\audit-write-only-reports.ps1 is the exemplar for). A fall is SPOKEN
  and the committed baseline KEPT; -Tighten records it through lib\ratchet.ps1's plausibility bar, in the
  bytes git stores (lib\lf-write.ps1). A MISSING baseline is exit 3, never a silent first write: -Accept is
  the only way one is created.

  SCOPE OF A CLEAN REPORT: every published stat recomputes from its OWN ingredients_grams under TODAY's
  food-macros-db within 5 cal and 2 g, and every index ingredient weight equals its spec's. It does NOT mean
  the food DB row is the right food, nor that the grams are what the recipe really uses - a wrong row or a
  wrong weight on BOTH sides agrees with itself and passes. It is an internal-consistency check, sound for
  the arithmetic over what it reads and silent about what it cannot read.

  THE TOLERANCES ARE INHERITED, NOT TUNED. 5 cal and 2 g are build-v2-spec.ps1's and wave-preaudit.ps1's, so a
  recipe that passes at build passes here. No other value was tried. The honest cost is that 2 g is a sharp
  edge: on 2026-09-12 the median carb miss was 2.2 g, and a second pass over the same catalogue with a
  different rounding order read 28 failures instead of 24.

  WHAT IT DOES WHEN THE PRODUCER STOPS. If the spec directory is empty or unreadable nothing is judged, and
  zero judged is exit 3, not a pass. A fall to zero findings is refused by Test-RatchetMove unless -Accept.

  Usage:
    .\audit-published-macros.ps1            recompute and compare, ratchet against meal-prep\out\published-macros-baseline.json; writes nothing
    .\audit-published-macros.ps1 -Tighten   the same, and record a believable FALL as the new baseline
    .\audit-published-macros.ps1 -Accept    record the CURRENT findings as the baseline, whatever they are
    .\audit-published-macros.ps1 -SelfTest  frozen fixtures, plus this script's live path run against a temp tree

  Exit: 0 = no finding outside the baseline. 2 = a NEW failing recipe or index row, or -Tighten refused.
  3 = could not evaluate: no baseline, or nothing could be judged.
#>
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop
param([switch]$SelfTest, [switch]$Accept, [switch]$Tighten, [string]$Root = '', [string]$BaselineFile = '')
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent (Split-Path -Parent $here)
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\ratchet.ps1')     # Test-RatchetMove, Add-RatchetHistory
. (Join-Path $repo 'lib\lf-write.ps1')    # Write-TcLfFile: the baseline is tracked and stored eol=lf
. (Join-Path $repo 'meal-prep\pipeline\macro-recompute-lib.ps1')   # Get-MacroRecompute - the ONE per-serving arithmetic

$script:PM_CAL_TOL  = 5.0
$script:PM_GRAM_TOL = 2.0
# Grams are stored as whole numbers on both masters, so a half-gram gap is rounding and not drift.
$script:PM_WEIGHT_TOL = 0.5
$script:PM_STAT_PAIRS = @(
  @{ Stat = 'cal';     Rc = 'cal';     Tol = 5.0 },
  @{ Stat = 'protein'; Rc = 'protein'; Tol = 2.0 },
  @{ Stat = 'carbs';   Rc = 'carbs';   Tol = 2.0 },
  @{ Stat = 'fat';     Rc = 'fat';     Tol = 2.0 }
)

function Get-PmStatFinding {
  <# One spec's published stat against the recompute of its own ingredients_grams. Pure.
     Returns Verdict PASS, FAIL or BLIND. BLIND is a could-not-look and is NEVER scored as a pass: a spec
     with an ingredient the food DB cannot resolve would otherwise read as agreeing on a partial sum. #>
  # NOT "Db": [Parameter()] makes this an ADVANCED function, which gets -Debug and its alias -db, so a parameter
  # named Db fails the WHOLE SCRIPT at load with ParameterNameConflictsWithAlias (hit 2026-09-12). The lib's
  # Get-MacroRecompute can say -Db only because it declares no parameter attributes.
  param([Parameter(Mandatory=$true)]$Spec, [Parameter(Mandatory=$true)]$FoodDb)
  $slug = [string]$Spec.slug
  $rows = $Spec.ingredients_grams
  $sv = 0
  if ($Spec.PSObject.Properties['servings']) { $sv = [int]$Spec.servings }
  if ($null -eq $rows -or @($rows).Count -eq 0) { return [pscustomobject]@{ Verdict = 'BLIND'; Key = $slug; Detail = 'no ingredients_grams' } }
  if ($sv -le 0) { return [pscustomobject]@{ Verdict = 'BLIND'; Key = $slug; Detail = 'no servings' } }
  if (-not $Spec.PSObject.Properties['stat'] -or $null -eq $Spec.stat) { return [pscustomobject]@{ Verdict = 'BLIND'; Key = $slug; Detail = 'no stat block' } }
  $rc = Get-MacroRecompute -Rows @($rows) -Db $FoodDb -Servings $sv
  $miss = @($rc.missing)
  if ($miss.Count -gt 0) { return [pscustomobject]@{ Verdict = 'BLIND'; Key = $slug; Detail = ('food DB has no usable row for: ' + ($miss -join ', ')) } }
  $bad = New-Object System.Collections.Generic.List[string]
  foreach ($p in $script:PM_STAT_PAIRS) {
    if (-not $Spec.stat.PSObject.Properties[$p.Stat]) { continue }
    $pub = [double]$Spec.stat.($p.Stat)
    $got = [double]$rc[$p.Rc]
    if ([Math]::Abs($got - $pub) -gt $p.Tol) { $bad.Add(('{0} published {1:0.#} recomputes {2:0.#}' -f $p.Stat, $pub, $got)) }
  }
  if ($bad.Count -gt 0) { return [pscustomobject]@{ Verdict = 'FAIL'; Key = $slug; Detail = ($bad -join '; ') } }
  return [pscustomobject]@{ Verdict = 'PASS'; Key = $slug; Detail = '' }
}

function Get-PmGramFindings {
  <# One recipe's index ingredient weights against its spec's. Pure.
     Keyed on the CANONICAL name - scaler.canon when the card renames an ingredient, else scaler.item - which
     is the key engine\audit-db-agreement.ps1's INGREDIENT-NAME check uses and update-recipes-db.ps1 writes.
     A name on one side only is NOT reported here: that is audit-db-agreement's INGREDIENT-NAME finding, and
     it is counted as Unpaired so a recipe that paired nothing cannot read as agreeing.
     Returns a wrapper object, never a bare array, so a one-finding result is not unrolled by PS 5.1. #>
  param([Parameter(Mandatory=$true)]$Spec, [Parameter(Mandatory=$true)]$Row)
  $slug = [string]$Spec.slug
  $specG = @{}
  $ing = $null
  if ($Spec.PSObject.Properties['scaler'] -and $Spec.scaler -and $Spec.scaler.PSObject.Properties['ing']) { $ing = $Spec.scaler.ing }
  if ($null -ne $ing) {
    foreach ($i in @($ing)) {
      $k = if ($i.PSObject.Properties['canon'] -and $i.canon) { [string]$i.canon } else { [string]$i.item }
      if ($specG.ContainsKey($k)) { $specG[$k] += [double]$i.grams } else { $specG[$k] = [double]$i.grams }
    }
  }
  $idxG = @{}
  if ($Row.PSObject.Properties['ingredients'] -and $null -ne $Row.ingredients) {
    foreach ($i in @($Row.ingredients)) {
      $k = [string]$i.item
      if ($idxG.ContainsKey($k)) { $idxG[$k] += [double]$i.grams } else { $idxG[$k] = [double]$i.grams }
    }
  }
  $found = New-Object System.Collections.Generic.List[object]
  $paired = 0; $unpaired = 0
  foreach ($k in @($specG.Keys) + @($idxG.Keys | Where-Object { -not $specG.ContainsKey($_) })) {
    if (-not ($specG.ContainsKey($k) -and $idxG.ContainsKey($k))) { $unpaired++; continue }
    $paired++
    if ([Math]::Abs($specG[$k] - $idxG[$k]) -gt $script:PM_WEIGHT_TOL) {
      $found.Add([pscustomobject]@{ Key = ($slug + '|' + $k); SpecG = $specG[$k]; IdxG = $idxG[$k] })
    }
  }
  return [pscustomobject]@{ Findings = $found.ToArray(); Paired = $paired; Unpaired = $unpaired }
}

function Get-PmNameList {
  <# A family's names out of a baseline document. ASSIGN, THEN WRAP, and never wrap $null: @($null).Count is 1
     in PS 5.1, so an absent list would read as a one-name baseline and hide a rise. #>
  param($Doc, [string]$Family)
  if ($null -eq $Doc -or -not $Doc.PSObject.Properties['families']) { return ,@() }
  $f = $Doc.families.$Family
  if ($null -eq $f) { return ,@() }
  $n0 = $f.names
  if ($null -eq $n0) { return ,@() }
  return ,@($n0 | ForEach-Object { [string]$_ })
}

if ($SelfTest) {
  $bad = 0; $ran = 0
  function T($n, $c, $g = '') { $script:ran++; if ($c) { Write-Output ("ok    " + $n) } else { Write-Output ("FAIL  " + $n + "   got: " + $g); $script:bad++ } }

  # A two-row food DB. Rice 900 g + Turkey 1,400 g over 10 servings recomputes to exactly
  # cal 488.0, protein 42.4, carbs 72.0, fat 2.8 - worked by hand so the fixtures do not trust the lib.
  $fdb = @{
    'Rice'   = [pscustomobject]@{ item = 'Rice';   serving_grams = 45;  calories = 160; protein_g = 3;  carbs_g = 36; fat_g = 0 }
    'Turkey' = [pscustomobject]@{ item = 'Turkey'; serving_grams = 100; calories = 120; protein_g = 26; carbs_g = 0;  fat_g = 2 }
  }
  function New-PmFxSpec($slug, $stat, $extra) {
    $g = @([pscustomobject]@{ item = 'Rice'; grams = 900 }, [pscustomobject]@{ item = 'Turkey'; grams = 1400 })
    if ($extra) { $g += $extra }
    return [pscustomobject]@{ slug = $slug; servings = 10; stat = $stat; ingredients_grams = $g }
  }

  # MUST FIRE - the founding stat shape: carbs published 3 g under what the ingredients make.
  $s1 = Get-PmStatFinding -Spec (New-PmFxSpec 'rice-short' ([pscustomobject]@{ cal = 488; protein = 42; carbs = 69; fat = 3 }) $null) -FoodDb $fdb
  T 'MUST FIRE  a stat 3 g under its own recompute on carbs is a FAIL that names carbs' ($s1.Verdict -eq 'FAIL' -and $s1.Detail -match 'carbs published 69 recomputes 72') ("{0} :: {1}" -f $s1.Verdict, $s1.Detail)
  # MUST NOT FIRE - inside every tolerance, and carbs EXACTLY on the 2 g edge, which pins the strict comparison.
  $s2 = Get-PmStatFinding -Spec (New-PmFxSpec 'inside' ([pscustomobject]@{ cal = 484; protein = 44; carbs = 70; fat = 1 }) $null) -FoodDb $fdb
  T 'MUST NOT FIRE  4 cal / 1.6 g / exactly 2.0 g / 1.8 g off is inside the build tolerance' ($s2.Verdict -eq 'PASS') ("{0} :: {1}" -f $s2.Verdict, $s2.Detail)
  # MUST FIRE - an ingredient the food DB cannot resolve is BLIND, never a pass on a partial sum.
  $s3 = Get-PmStatFinding -Spec (New-PmFxSpec 'unknown-row' ([pscustomobject]@{ cal = 488; protein = 42; carbs = 72; fat = 3 }) @([pscustomobject]@{ item = 'Unobtainium'; grams = 50 })) -FoodDb $fdb
  T 'MUST FIRE  a missing food-DB row is BLIND and names the row, not a PASS on the rows it could read' ($s3.Verdict -eq 'BLIND' -and $s3.Detail -match 'Unobtainium') ("{0} :: {1}" -f $s3.Verdict, $s3.Detail)
  # CLEAN TWIN - a stat that matches is JUDGED and passes: a positive verdict, so "judged nothing" cannot pose as clean.
  $s4 = Get-PmStatFinding -Spec (New-PmFxSpec 'exact' ([pscustomobject]@{ cal = 488; protein = 42; carbs = 72; fat = 3 }) $null) -FoodDb $fdb
  T 'CLEAN TWIN  a matching stat is judged PASS' ($s4.Verdict -eq 'PASS' -and $s4.Key -eq 'exact') ("{0}/{1}" -f $s4.Verdict, $s4.Key)
  $s5 = Get-PmStatFinding -Spec ([pscustomobject]@{ slug = 'no-grams'; servings = 10; stat = ([pscustomobject]@{ cal = 1 }) }) -FoodDb $fdb
  T 'MUST FIRE  a spec with no ingredients_grams is BLIND, not PASS' ($s5.Verdict -eq 'BLIND') $s5.Verdict

  # MUST FIRE - the pozole shape: one name on both masters, 575 g in the spec and 1,914 g in the index.
  $pSpec = [pscustomobject]@{ slug = 'pozole'; scaler = [pscustomobject]@{ ing = @(
    [pscustomobject]@{ item = 'Corn Tortillas'; canon = 'Corn Tortillas'; grams = 575 },
    [pscustomobject]@{ item = 'Hominy'; grams = 1726 }) } }
  $pRow = [pscustomobject]@{ slug = 'pozole'; ingredients = @(
    [pscustomobject]@{ item = 'Corn Tortillas'; grams = 1914 },
    [pscustomobject]@{ item = 'Hominy'; grams = 1726 }) }
  $g1 = Get-PmGramFindings -Spec $pSpec -Row $pRow
  $g1f = @($g1.Findings)
  T 'MUST FIRE  an index weight that disagrees with its spec under the same name is reported with both weights' `
    ($g1f.Count -eq 1 -and $g1f[0].Key -eq 'pozole|Corn Tortillas' -and [double]$g1f[0].SpecG -eq 575 -and [double]$g1f[0].IdxG -eq 1914) ("n={0} key={1}" -f $g1f.Count, $(if ($g1f.Count) { $g1f[0].Key }))
  # MUST NOT FIRE - equal weights, and a 0.4 g gap that is rounding.
  $qRow = [pscustomobject]@{ slug = 'pozole'; ingredients = @(
    [pscustomobject]@{ item = 'Corn Tortillas'; grams = 575.4 },
    [pscustomobject]@{ item = 'Hominy'; grams = 1726 }) }
  $g2 = Get-PmGramFindings -Spec $pSpec -Row $qRow
  T 'MUST NOT FIRE  equal weights and a 0.4 g rounding gap report nothing' (@($g2.Findings).Count -eq 0) ("n=" + @($g2.Findings).Count)
  # CLEAN TWIN - and both rows were actually PAIRED, so the silence above is agreement and not a skipped recipe.
  T 'CLEAN TWIN  both ingredients were paired and compared' ($g2.Paired -eq 2 -and $g2.Unpaired -eq 0) ("paired={0} unpaired={1}" -f $g2.Paired, $g2.Unpaired)
  # MUST FIRE - a card that RENAMES an ingredient is keyed on its canon, exactly as audit-db-agreement keys names.
  $rSpec = [pscustomobject]@{ slug = 'renamed'; scaler = [pscustomobject]@{ ing = @(
    [pscustomobject]@{ item = 'Tortilla (La Banderita)'; canon = 'Corn Tortillas'; grams = 575 }) } }
  $rRow = [pscustomobject]@{ slug = 'renamed'; ingredients = @([pscustomobject]@{ item = 'Corn Tortillas'; grams = 1914 }) }
  $g3 = Get-PmGramFindings -Spec $rSpec -Row $rRow
  T 'MUST FIRE  a renamed card ingredient pairs on its canon and its weight drift is still reported' (@($g3.Findings).Count -eq 1 -and $g3.Paired -eq 1) ("n={0} paired={1}" -f @($g3.Findings).Count, $g3.Paired)

  # THE LIVE PATH, DRIVEN. These run THIS script as a child against a temp meal-prep tree and a temp baseline,
  # so they exercise the code the daily chain runs, not a copy of it. One directory per run, removed in finally.
  $wt = Join-Path $env:TEMP ('pmx-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $wt -ErrorAction Stop | Out-Null
  try {
    $mpx = Join-Path $wt 'mp'
    New-Item -ItemType Directory -Path (Join-Path $mpx 'db\recipes') -Force -ErrorAction Stop | Out-Null
    $utf8 = New-Object Text.UTF8Encoding($false)
    $dbDoc = [ordered]@{ readme = 'fixture'; items = @(@($fdb.Values | ForEach-Object { $_ })) } | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText((Join-Path $mpx 'food-macros-db.json'), $dbDoc, $utf8)
    function Write-PmFxSpec($slug, $stat, $turkeyIdx) {
      $spec = [ordered]@{ slug = $slug; servings = 10; stat = $stat
        ingredients_grams = @([ordered]@{ item = 'Rice'; grams = 900 }, [ordered]@{ item = 'Turkey'; grams = 1400 })
        scaler = [ordered]@{ ing = @([ordered]@{ item = 'Rice'; grams = 900 }, [ordered]@{ item = 'Turkey'; grams = 1400 }) } }
      [IO.File]::WriteAllText((Join-Path $mpx ("db\recipes\" + $slug + '.json')), ($spec | ConvertTo-Json -Depth 6), $utf8)
      return [ordered]@{ slug = $slug; ingredients = @([ordered]@{ item = 'Rice'; grams = 900 }, [ordered]@{ item = 'Turkey'; grams = $turkeyIdx }) }
    }
    $rowA = Write-PmFxSpec 'a-rice-short' ([ordered]@{ cal = 488; protein = 42; carbs = 69; fat = 3 }) 1400   # stat FAILS, index agrees
    $rowB = Write-PmFxSpec 'b-clean-stat' ([ordered]@{ cal = 488; protein = 42; carbs = 72; fat = 3 }) 1500   # stat passes, index Turkey drifts
    [IO.File]::WriteAllText((Join-Path $mpx 'recipes-db.json'), ([ordered]@{ recipes = @($rowA, $rowB) } | ConvertTo-Json -Depth 6), $utf8)
    function Write-PmFxBaseline($path, [string[]]$statNames, [string[]]$gramNames) {
      $doc = [ordered]@{ note = 'fixture note (kept across a tighten)'; generated = '2026-01-01T00:00:00'
        families = [ordered]@{
          stat_vs_recompute   = [ordered]@{ count = $statNames.Count; names = [string[]]$statNames }
          index_grams_vs_spec = [ordered]@{ count = $gramNames.Count; names = [string[]]$gramNames } } }
      $null = Write-TcLfFile $path ($doc | ConvertTo-Json -Depth 6)
    }
    function Invoke-PmChild([string[]]$argv) {
      $o = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @argv
      return [pscustomobject]@{ Rc = $LASTEXITCODE; Text = (@($o) -join "`n") }
    }

    # A FALL: the baseline names a stat failure that is gone. Spoken, not written.
    $blFall = Join-Path $wt 'fall.json'
    Write-PmFxBaseline $blFall @('a-rice-short', 'z-retired') @('b-clean-stat|Turkey')
    $seed = [Convert]::ToBase64String([IO.File]::ReadAllBytes($blFall))
    $c1 = Invoke-PmChild @('-Root', $mpx, '-BaselineFile', $blFall)
    $same1 = [string]::Equals($seed, [Convert]::ToBase64String([IO.File]::ReadAllBytes($blFall)), [StringComparison]::Ordinal)
    T 'a FALL without -Tighten is spoken and NOT written, so a gate run leaves its checkout clean' ($c1.Rc -eq 0 -and $same1 -and $c1.Text -match 'CAN tighten') ("rc={0} unchanged={1}" -f $c1.Rc, $same1)
    # -Tighten records it, in the bytes git stores, keeping the note.
    $c2 = Invoke-PmChild @('-Root', $mpx, '-BaselineFile', $blFall, '-Tighten')
    $b2 = [IO.File]::ReadAllBytes($blFall)
    $cr2 = 0; foreach ($x in $b2) { if ($x -eq 13) { $cr2++ } }
    $bom2 = ($b2.Length -ge 3 -and $b2[0] -eq 0xEF -and $b2[1] -eq 0xBB -and $b2[2] -eq 0xBF)
    $doc2 = $null
    if ($bom2) { $doc2 = [Text.Encoding]::UTF8.GetString($b2, 3, $b2.Length - 3) | ConvertFrom-Json }
    $n2 = Get-PmNameList $doc2 'stat_vs_recompute'
    T '-Tighten records the fall: no CR, the BOM, one trailing LF, the note kept, and only the surviving name' `
      ($c2.Rc -eq 0 -and $cr2 -eq 0 -and $bom2 -and $b2[-1] -eq 10 -and $n2.Count -eq 1 -and $n2[0] -eq 'a-rice-short' -and [string]$doc2.note -eq 'fixture note (kept across a tighten)') `
      ("rc={0} cr={1} bom={2} names={3}" -f $c2.Rc, $cr2, $bom2, ($n2 -join ','))
    # CLEAN TWIN - a NEW failing recipe still fails the run, so not writing on a fall did not disarm the ratchet.
    $blRise = Join-Path $wt 'rise.json'
    Write-PmFxBaseline $blRise @() @('b-clean-stat|Turkey')
    $c3 = Invoke-PmChild @('-Root', $mpx, '-BaselineFile', $blRise)
    T 'CLEAN TWIN  a recipe failing outside the baseline exits 2 and is named' ($c3.Rc -eq 2 -and $c3.Text -match 'NEW.*a-rice-short') ("rc=" + $c3.Rc)
    # MUST FIRE - a SWAP: the same count, a different recipe. A count ratchet reads "held"; this one must not.
    $blSwap = Join-Path $wt 'swap.json'
    Write-PmFxBaseline $blSwap @('z-other-recipe') @('b-clean-stat|Turkey')
    $c4 = Invoke-PmChild @('-Root', $mpx, '-BaselineFile', $blSwap)
    T 'MUST FIRE  one recipe fixed and another broken at the same count still exits 2' ($c4.Rc -eq 2) ("rc=" + $c4.Rc)
    # MUST FIRE - no baseline is a could-not-evaluate, and a plain run does not create one.
    $blNone = Join-Path $wt 'absent.json'
    $c5 = Invoke-PmChild @('-Root', $mpx, '-BaselineFile', $blNone)
    T 'MUST FIRE  a missing baseline is exit 3 and no file is written' ($c5.Rc -eq 3 -and -not (Test-Path -LiteralPath $blNone)) ("rc={0} created={1}" -f $c5.Rc, (Test-Path -LiteralPath $blNone))
    # MUST FIRE - the producer stopped: zero specs resolved is exit 3, never a clean 0.
    $mpEmpty = Join-Path $wt 'empty'
    New-Item -ItemType Directory -Path (Join-Path $mpEmpty 'db\recipes') -Force -ErrorAction Stop | Out-Null
    [IO.File]::WriteAllText((Join-Path $mpEmpty 'food-macros-db.json'), $dbDoc, $utf8)
    [IO.File]::WriteAllText((Join-Path $mpEmpty 'recipes-db.json'), '{"recipes":[]}', $utf8)
    $c6 = Invoke-PmChild @('-Root', $mpEmpty, '-BaselineFile', $blFall)
    T 'MUST FIRE  a catalogue with no specs is exit 3, not a clean run' ($c6.Rc -eq 3) ("rc=" + $c6.Rc)
  } finally {
    Remove-Item -LiteralPath $wt -Recurse -Force -ErrorAction SilentlyContinue
  }

  # A LITERAL CASE LIST KNOWS ITS OWN NUMBER, so a case that never ran is a failure and not a smaller suite.
  $EXPECTED = 15
  if ($ran -ne $EXPECTED) { Write-Output ("FAIL  the suite ran {0} case(s) and declares {1}" -f $ran, $EXPECTED); $bad++ }
  if ($bad -eq 0) { Write-Output ("PUBLISHED-MACROS SELF-TEST PASS ({0} cases)" -f $ran); Write-GuardComplete -Name 'published-macros' -Summary 'selftest ok'; exit 0 }
  Write-Output ("PUBLISHED-MACROS SELF-TEST FAILED ($bad)"); Write-GuardComplete -Name 'published-macros' -Summary "selftest failed=$bad"; exit 2
}

# ---- live run ----
$mpRoot = if ($Root) { $Root } else { Join-Path $repo 'meal-prep' }
$specDir = Join-Path $mpRoot 'db\recipes'
$blF = if ($BaselineFile) { $BaselineFile } else { Join-Path $repo 'meal-prep\out\published-macros-baseline.json' }

$db = @{}
$dbDocLive = [IO.File]::ReadAllText((Join-Path $mpRoot 'food-macros-db.json')) | ConvertFrom-Json
foreach ($it in @($dbDocLive.items)) { $db[[string]$it.item] = $it }
$idxDoc = [IO.File]::ReadAllText((Join-Path $mpRoot 'recipes-db.json')) | ConvertFrom-Json
$idxRows = if ($idxDoc.PSObject.Properties['recipes']) { $idxDoc.recipes } else { $idxDoc }
$idxBySlug = @{}
foreach ($r in @($idxRows)) { if ($r -and $r.slug) { $idxBySlug[[string]$r.slug] = $r } }

$specFiles = @()
if (Test-Path -LiteralPath $specDir) { $specFiles = @([IO.Directory]::GetFiles($specDir, '*.json') | Sort-Object) }

$statFail = New-Object System.Collections.Generic.List[object]
$statBlind = New-Object System.Collections.Generic.List[object]
$gramFind = New-Object System.Collections.Generic.List[object]
$judged = 0; $gramRecipes = 0; $paired = 0; $unpaired = 0
foreach ($sf in $specFiles) {
  $spec = [IO.File]::ReadAllText($sf) | ConvertFrom-Json
  $sr = Get-PmStatFinding -Spec $spec -FoodDb $db
  if ($sr.Verdict -eq 'BLIND') { $statBlind.Add($sr) } else { $judged++; if ($sr.Verdict -eq 'FAIL') { $statFail.Add($sr) } }
  if ($idxBySlug.ContainsKey([string]$spec.slug)) {
    $gramRecipes++
    $gr = Get-PmGramFindings -Spec $spec -Row $idxBySlug[[string]$spec.slug]
    $paired += $gr.Paired; $unpaired += $gr.Unpaired
    foreach ($x in @($gr.Findings)) { $gramFind.Add($x) }
  }
}

Write-Output ("published-macros: {0} spec(s) resolved under {1}" -f $specFiles.Count, $specDir)
Write-Output ("  stat vs recompute: judged {0} of {1}, FAIL {2} of {0} judged, BLIND {3} (tolerance {4} cal / {5} g, from build-v2-spec)" -f $judged, $specFiles.Count, $statFail.Count, $statBlind.Count, $script:PM_CAL_TOL, $script:PM_GRAM_TOL)
Write-Output ("  index grams vs spec: {0} recipe(s) in both masters, {1} ingredient row(s) paired, {2} unpaired (a name on one side only is audit-db-agreement's finding), {3} disagreeing" -f $gramRecipes, $paired, $unpaired, $gramFind.Count)
foreach ($b in $statBlind) { Write-Output ("  BLIND  {0} :: {1}" -f $b.Key, $b.Detail) }

if ($specFiles.Count -eq 0 -or $judged -eq 0) {
  Write-Output 'published-macros: BLIND - nothing could be judged, so a clean result would prove nothing'
  Exit-Guard -Name 'published-macros' -Summary ("specs={0} judged=0 blind" -f $specFiles.Count) -Code 3
}

$cur = @{
  stat_vs_recompute   = @($statFail | ForEach-Object { [string]$_.Key })
  index_grams_vs_spec = @($gramFind | ForEach-Object { [string]$_.Key })
}
$detail = @{}
foreach ($x in $statFail) { $detail[[string]$x.Key] = [string]$x.Detail }
foreach ($x in $gramFind) { $detail[[string]$x.Key] = ('spec {0:0.#} g, index {1:0.#} g' -f $x.SpecG, $x.IdxG) }

$blDoc = $null
if (Test-Path -LiteralPath $blF) {
  try { $blDoc = [IO.File]::ReadAllText($blF) | ConvertFrom-Json } catch { $blDoc = $null }
}
$script:PM_NOTE = 'Baseline for audit-published-macros (2026-09-12). Names, not only counts: a NEW name fails the run even when the count held. Both lists may only SHRINK, and only through -Tighten or -Accept.'
function Write-PmBaseline([hashtable]$Names) {
  $note = if ($blDoc -and $blDoc.PSObject.Properties['note'] -and $blDoc.note) { [string]$blDoc.note } else { $script:PM_NOTE }
  $total = @($Names.stat_vs_recompute).Count + @($Names.index_grams_vs_spec).Count
  $hist = Add-RatchetHistory -Doc $(if ($blDoc) { $blDoc } else { [pscustomobject]@{} }) -Count $total
  $doc = [ordered]@{
    note = $note; generated = (Get-Date).ToString('s')
    tolerance = [ordered]@{ cal = $script:PM_CAL_TOL; gram = $script:PM_GRAM_TOL; weight = $script:PM_WEIGHT_TOL }
    families = [ordered]@{
      stat_vs_recompute   = [ordered]@{ count = @($Names.stat_vs_recompute).Count;   names = [string[]]@($Names.stat_vs_recompute | Sort-Object) }
      index_grams_vs_spec = [ordered]@{ count = @($Names.index_grams_vs_spec).Count; names = [string[]]@($Names.index_grams_vs_spec | Sort-Object) } }
    history = $hist
  }
  return (Write-TcLfFile $blF ($doc | ConvertTo-Json -Depth 6))
}

if ($Accept) {
  $null = Write-PmBaseline $cur
  Write-Output ("  baseline written: stat_vs_recompute={0} index_grams_vs_spec={1}{2}. From here each list may only SHRINK." -f $cur.stat_vs_recompute.Count, $cur.index_grams_vs_spec.Count, $(if ($statBlind.Count) { " (with $($statBlind.Count) spec(s) BLIND - they were not judged)" } else { '' }))
  Exit-Guard -Name 'published-macros' -Summary ("specs={0} judged={1} stat_fail={2} gram_drift={3} accepted" -f $specFiles.Count, $judged, $statFail.Count, $gramFind.Count) -Code 0
}
if ($null -eq $blDoc) {
  Write-Output ("published-macros: NO BASELINE at {0}. A plain run never writes one; record it deliberately with -Accept and commit it." -f $blF)
  Exit-Guard -Name 'published-macros' -Summary ("specs={0} judged={1} no-baseline" -f $specFiles.Count, $judged) -Code 3
}

$rose = $false; $refused = $false
$next = @{ stat_vs_recompute = @(Get-PmNameList $blDoc 'stat_vs_recompute'); index_grams_vs_spec = @(Get-PmNameList $blDoc 'index_grams_vs_spec') }
$canTighten = $false
foreach ($fam in @('stat_vs_recompute', 'index_grams_vs_spec')) {
  $base = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  foreach ($n in (Get-PmNameList $blDoc $fam)) { [void]$base.Add($n) }
  $now = @($cur[$fam])
  $new = @($now | Where-Object { -not $base.Contains($_) })
  if ($new.Count -gt 0) {
    $rose = $true
    Write-Output ("published-macros: {0} has {1} NEW finding(s) outside the baseline:" -f $fam, $new.Count)
    foreach ($n in $new) { Write-Output ("  NEW  {0} :: {1}" -f $n, $detail[$n]) }
    continue
  }
  if ($now.Count -lt $base.Count) {
    $move = Test-RatchetMove -Name ('published-macros ' + $fam) -Count $now.Count -Baseline $base.Count
    if ($move.Verdict -eq 'implausible') {
      Write-Output ('  ' + $move.Message + ' (-Accept is this script''s -AcceptDrop.)')
      if ($Tighten) { $refused = $true }
    } elseif ($statBlind.Count -gt 0) {
      Write-Output ("  {0} fell {1} -> {2}, but {3} spec(s) are BLIND and one may be hiding a baseline failure, so the fall is not believed and not recorded." -f $fam, $base.Count, $now.Count, $statBlind.Count)
      if ($Tighten) { $refused = $true }
    } else {
      $canTighten = $true
      $next[$fam] = $now
      if (-not $Tighten) { Write-Output ("  ratchet CAN tighten: {0} {1} -> {2}. NOT written: record it with -Tighten and commit meal-prep\out\published-macros-baseline.json." -f $fam, $base.Count, $now.Count) }
    }
  }
}
if ($rose) {
  Exit-Guard -Name 'published-macros' -Summary ("specs={0} judged={1} stat_fail={2} gram_drift={3} rose" -f $specFiles.Count, $judged, $statFail.Count, $gramFind.Count) -Code 2
}
if ($refused) {
  Exit-Guard -Name 'published-macros' -Summary ("specs={0} judged={1} stat_fail={2} gram_drift={3} refused-to-lower" -f $specFiles.Count, $judged, $statFail.Count, $gramFind.Count) -Code 2
}
if ($Tighten -and $canTighten) {
  $null = Write-PmBaseline $next
  Write-Output '  ratchet tightened. New baseline written - commit it, or it protects only this checkout.'
}
Write-Output ("published-macros: stat_vs_recompute {0}, index_grams_vs_spec {1} - all inside the baseline, the known backlog and not a regression." -f $cur.stat_vs_recompute.Count, $cur.index_grams_vs_spec.Count)
Exit-Guard -Name 'published-macros' -Summary ("specs={0} judged={1} stat_fail={2} gram_drift={3}" -f $specFiles.Count, $judged, $statFail.Count, $gramFind.Count) -Code 0
