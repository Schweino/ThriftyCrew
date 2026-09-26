<#
  audit-nutrient-claims.ps1 - MEASURES every FDA nutrient content claim word in the committed recipe
  catalogue against the numeric bar behind it. A REPORT over the live catalogue, not a gate.

  WHY THIS EXISTS (Brad's ruling, 2026-09-19, backlog I143): "rule for new, measure old". A NEW recipe may
  use a nutrient content claim word ("high protein", "low fat", "light", "lean"...) only where its own
  per-serving macros clear that claim's FDA bar; that rule is enforced at build-v2-spec's import door and in
  wave-preaudit's nutrient-claims check. The LIVE catalogue is measured here and changed nowhere: this
  script writes design\ready-for-brad\I143-claim-words.md when asked, so Brad can rule on a sweep with the
  list in front of him.

  THE RULE IT MEASURES IS ONE FUNCTION: nutrient-claim-lib.ps1's Get-TcNutrientClaimUse, over the list in
  forbidden-prose-global.json's nutrient_claims block - the same function both enforcing doors call. So the
  report cannot count a use the doors would pass, or pass one they would refuse.

  SCOPE OF A CLEAN REPORT: UNSOUND. It finds the listed SPELLINGS, on word boundaries, in the reader-facing
  fields of the committed specs, after four exemptions (ingredient-rendered fields, a word beside a product
  whose own name carries it, a store-variant word directly before a product word, and each claim's exempt_contexts). A claim phrased in words nobody listed, or
  assembled at render time from tokens, is invisible to it. A reported use is real; a clean report proves
  only that no listed spelling appears.

  EXIT CODES: 0 measured (whatever it found: the live uses are grandfathered by the ruling), 2 self-test
  regression, 3 BLIND (no specs resolved, or the list missing or empty).

    meal-prep\pipeline\audit-nutrient-claims.ps1                         measure and print the summary
    meal-prep\pipeline\audit-nutrient-claims.ps1 -ReportFile <md>        ...and write the per-use list
    meal-prep\pipeline\audit-nutrient-claims.ps1 -SelfTest               fixtures: must fire, must not, clean twins
#>
# Self-test: the claim list, build-v2-spec and wave-preaudit read as text, and a count of the recipe specs (the discovery case).
# gate-inputs: meal-prep\pipeline\nutrient-claim-lib.ps1, meal-prep\pipeline\forbidden-prose-lib.ps1, meal-prep\pipeline\forbidden-prose-global.json, meal-prep\db\recipes\*.json
# gate-inputs-text: meal-prep\pipeline\build-v2-spec.ps1, meal-prep\pipeline\wave-preaudit.ps1
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop
param([switch]$SelfTest, [string]$RecipeDir = '', [string]$ReportFile = '')
$ErrorActionPreference = 'Stop'
$runSelfTest = [bool]$SelfTest
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }   # ...\meal-prep\pipeline
$mp   = Split-Path $here -Parent
$repo = Split-Path $mp -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $here 'nutrient-claim-lib.ps1')

function Get-NcSpecFiles {
  param([string]$Dir)
  if (-not (Test-Path -LiteralPath $Dir)) { return @() }
  return @(Get-ChildItem -LiteralPath $Dir -Filter '*.json' -File | Sort-Object Name)
}

# ------------------------------------------------------------------------------------------------ self-test
if ($runSelfTest) {
  $script:fail = 0
  $script:cases = 0
  function Assert-NcCase {
    param([string]$Name, [bool]$Ok, [string]$Got = '')
    $script:cases++
    if ($Ok) { Write-Output ('  ok    ' + $Name) }
    else { $script:fail++; Write-Output ('  X     ' + $Name + '   got: ' + $Got) }
  }
  function New-NcSpec {
    # A 14-serving spec: 5,600 g of ingredients is a 400 g serving, a main dish under 21 CFR 101.13(m).
    param([hashtable]$Stat, [hashtable]$Prose, [string[]]$Items = @('Chicken Breast'), [double]$BatchG = 5600)
    $each = $BatchG / [Math]::Max(1, $Items.Count)
    $o = [ordered]@{ name = 'Fixture Bowl'; servings = 14; stat = [pscustomobject]$Stat
      ingredients_grams = @($Items | ForEach-Object { [pscustomobject]@{ item = $_; grams = $each } }) }
    foreach ($k in $Prose.Keys) { $o[$k] = $Prose[$k] }
    return [pscustomobject]$o
  }
  function Get-NcIds { param($Uses) return (@($Uses | ForEach-Object { $_.ClaimId + '=' + $_.Verdict }) -join ',') }
  $C = Get-TcNutrientClaim
  $big = @{ cal = 679; protein = 50; fat = 23 }

  # ---- MUST FIRE: claim words whose bar the recipe does not clear
  $u1 = @(Get-TcNutrientClaimFinding -Spec (New-NcSpec $big @{ head = [pscustomobject]@{ keywords = 'high protein meal prep, low calorie burrito, budget dinner' } }) -Claims $C)
  Assert-NcCase 'MUST FIRE      the live keyword "low calorie burrito" on a 679-calorie, 400 g serving fails (170 cal per 100 g against 120)' `
    ($u1.Count -eq 1 -and $u1[0].ClaimId -eq 'low-calorie' -and $u1[0].Verdict -eq 'fail' -and $u1[0].Shown -match '169\.8 calories per 100 g') (Get-NcIds $u1)

  $u2 = @(Get-TcNutrientClaimFinding -Spec (New-NcSpec @{ cal = 300; protein = 8; fat = 9 } @{ intro_html = 'A high-protein pasta bake for the week.' }) -Claims $C)
  Assert-NcCase 'MUST FIRE      "high-protein" on 8 g protein a serving fails the 10 g bar (20% of the 50 g DRV)' `
    ($u2.Count -eq 1 -and $u2[0].ClaimId -eq 'high-protein' -and $u2[0].Verdict -eq 'fail') (Get-NcIds $u2)

  $u3 = @(Get-TcNutrientClaimFinding -Spec (New-NcSpec $big @{ intro_html = 'A sugar-free glaze keeps it sweet.' }) -Claims $C)
  Assert-NcCase 'MUST FIRE      a sugar-free DISH claim is NOT-COMPUTABLE (no sugars anywhere in the estate) and is refused' `
    ($u3.Count -eq 1 -and $u3[0].ClaimId -eq 'sugar-free' -and $u3[0].Verdict -eq 'not-computable') (Get-NcIds $u3)

  # The 2026-09-12 draft's load-bearing case: chicken IS an ingredient, but no ingredient is NAMED low fat.
  $u4 = @(Get-TcNutrientClaimUse -Spec (New-NcSpec $big @{ intro_html = 'A high-protein, low-fat Tex-Mex chicken, rice and bean meal prep.' }) -Claims $C)
  Assert-NcCase 'MUST FIRE      "high-protein, low-fat Tex-Mex chicken" is two DISH claims although chicken is an ingredient' `
    ((Get-NcIds $u4) -eq 'high-protein=pass,low-fat=fail') (Get-NcIds $u4)

  $u5 = @(Get-TcNutrientClaimFinding -Spec (New-NcSpec $big @{ shop_smart = @('Trim the thighs, which keeps it lean and cheap.') }) -Claims $C)
  Assert-NcCase 'MUST FIRE      "keeps it lean" is a dish claim and NOT-COMPUTABLE (no saturated fat or cholesterol recorded)' `
    ($u5.Count -eq 1 -and $u5[0].ClaimId -eq 'lean' -and $u5[0].Verdict -eq 'not-computable') (Get-NcIds $u5)

  $u6 = @(Get-TcNutrientClaimFinding -Spec (New-NcSpec $big @{ intro_html = 'The yogurt sauce keeps this bowl light and cheap.' }) -Claims $C)
  Assert-NcCase 'MUST FIRE      "keeps this bowl light" is a light claim and fails: neither low fat nor low calorie' `
    ($u6.Count -eq 1 -and $u6[0].ClaimId -eq 'light' -and $u6[0].Verdict -eq 'fail') (Get-NcIds $u6)

  $u7 = @(Get-TcNutrientClaimFinding -Spec (New-NcSpec $big @{ intro_html = 'HIGH PROTEIN and Low-Sodium, every time.' }) -Claims $C)
  Assert-NcCase 'MUST FIRE      matching ignores case: "Low-Sodium" is found (and high protein at 50 g passes, so it is not)' `
    ($u7.Count -eq 1 -and $u7[0].ClaimId -eq 'sodium') (Get-NcIds $u7)

  $u8 = @(Get-TcNutrientClaimFinding -Spec (New-NcSpec $big @{ intro_html = 'Every bowl is fat free, and the cheddar still melts.' } @('Cheddar Cheese')) -Claims $C)
  Assert-NcCase 'MUST FIRE      "every bowl is fat free," is a DISH claim (no product word follows it) and fails at 23 g fat' `
    ($u8.Count -eq 1 -and $u8[0].ClaimId -eq 'fat-free' -and $u8[0].Verdict -eq 'fail') (Get-NcIds $u8)

  # The product-variant carve-out must not reach a claim that is not marked product_variant.
  $u10 = @(Get-TcNutrientClaimFinding -Spec (New-NcSpec @{ cal = 300; protein = 8; fat = 9 } @{ intro_html = 'These high-protein chicken bowls reheat well.' } @('Chicken Breast')) -Claims $C)
  Assert-NcCase 'MUST FIRE      "high-protein chicken bowls" at 8 g is a dish claim though chicken is bought: protein is not a product variant' `
    ($u10.Count -eq 1 -and $u10[0].ClaimId -eq 'high-protein' -and $u10[0].Verdict -eq 'fail') (Get-NcIds $u10)

  $u9 = @(Get-TcNutrientClaimFinding -Spec ([pscustomobject]@{ name = 'x'; intro_html = 'a high protein dinner' }) -Claims $C)
  Assert-NcCase 'MUST FIRE      a spec with NO stat block cannot show the number, so its claim is not-computable, never a pass' `
    ($u9.Count -eq 1 -and $u9[0].Verdict -eq 'not-computable') (Get-NcIds $u9)

  # ---- MUST NOT FIRE: legal uses and non-claims
  $n1 = @(Get-TcNutrientClaimFinding -Spec (New-NcSpec @{ cal = 520; protein = 41; fat = 14 } @{ intro_html = 'A high protein bowl at 41 grams a serving.'; head = [pscustomobject]@{ keywords = 'high-protein meal prep' } }) -Claims $C)
  Assert-NcCase 'MUST NOT FIRE  "high protein" on 41 g a serving clears the 10 g bar and is legal on a new recipe' ($n1.Count -eq 0) (Get-NcIds $n1)

  $n2 = @(Get-TcNutrientClaimUse -Spec (New-NcSpec $big @{ make_it = @('Sprinkle the fat free cheddar over the top.'); ingredients_display = @('<strong>Fat Free Cheddar (Great Value):</strong> 1 cup') } @('Fat Free Cheddar')) -Claims $C)
  Assert-NcCase 'MUST NOT FIRE  "fat free cheddar" beside a product whose OWN name carries it is the manufacturer''s claim, not ours' ($n2.Count -eq 0) (Get-NcIds $n2)

  # The two live sentences the wave-preaudit drill's real spec carries, both descriptions of a product.
  $n2b = @(Get-TcNutrientClaimUse -Spec (New-NcSpec $big @{ shop_smart = @('Use real full-fat cheddar rather than the low-fat kind, because the fat is what melts smooth.', 'An eight ounce brick of 1/3 less fat cream cheese melts into the broth.', 'Buy the fat free version and it melts fine.') } @('Cheddar Cheese', '1/3 Fat Cream Cheese')) -Claims $C)
  Assert-NcCase 'MUST NOT FIRE  a store-variant word before a product word describes the product: the low-fat kind, 1/3 less fat cream cheese, the fat free version' ($n2b.Count -eq 0) (Get-NcIds $n2b)

  $n3 = @(Get-TcNutrientClaimUse -Spec (New-NcSpec $big @{ make_it = @('Brown the lean ground turkey.', 'Lean on the spice rack here.', 'The 93/7 lean browns fast.', 'Use 90% lean if it is cheaper.') }) -Claims $C)
  Assert-NcCase 'MUST NOT FIRE  the USDA meat descriptor and the verb: lean ground turkey, lean on, 93/7 lean, 90% lean' ($n3.Count -eq 0) (Get-NcIds $n3)

  $n4 = @(Get-TcNutrientClaimUse -Spec (New-NcSpec $big @{ shop_smart = @('Stored away from light, dried chiles last a year.', 'Cook the rice separately so it stays light and fluffy.', 'Light sour cream costs the same as regular.', 'A markdown is your green light.') }) -Claims $C)
  Assert-NcCase 'MUST NOT FIRE  light as texture (101.56(e)), as a product name, and as an unrelated sense' ($n4.Count -eq 0) (Get-NcIds $n4)

  $n5 = @(Get-TcNutrientClaimUse -Spec (New-NcSpec $big @{ credit_html = 'Recipe adapted from High Protein Low Fat Kitchen.'; writer_notes = @('no low calorie claims'); scaler = [pscustomobject]@{ ing = @([pscustomobject]@{ item = 'BBQ Sauce (Sugar Free)' }) } }) -Claims $C)
  Assert-NcCase 'MUST NOT FIRE  attribution, writer notes and the ingredient-rendered scaler are not read' ($n5.Count -eq 0) (Get-NcIds $n5)

  # ---- CLEAN TWIN: the computable bars still PASS a recipe that clears them
  $t1 = @(Get-TcNutrientClaimUse -Spec (New-NcSpec @{ cal = 300; protein = 30; fat = 2 } @{ intro_html = 'A low fat stew.' }) -Claims $C)
  Assert-NcCase 'CLEAN TWIN     low fat PASSES a main dish at 0.5 g fat per 100 g and 6% of calories from fat' `
    ((Get-NcIds $t1) -eq 'low-fat=pass' -and $t1[0].Shown -match '0\.5 g fat per 100 g') ((Get-NcIds $t1) + ' ' + $(if ($t1.Count) { $t1[0].Shown }))

  $t2 = @(Get-TcNutrientClaimUse -Spec (New-NcSpec @{ cal = 400; protein = 30; fat = 2 } @{ intro_html = 'This one is light on fat and still fills you up.' }) -Claims $C)
  Assert-NcCase 'CLEAN TWIN     light PASSES a main dish that is low fat though not low calorie (101.56(d)(1): either one)' `
    ((Get-NcIds $t2) -eq 'light=pass') (Get-NcIds $t2)

  $t3 = @(Get-TcNutrientClaimUse -Spec (New-NcSpec $big @{ shop_smart = @('Buy the kind with no sugar added.') }) -Claims $C)
  Assert-NcCase 'CLEAN TWIN     overlapping spellings count ONCE, as the longest: "no sugar added" is no-added-sugar, not also sugar-free' `
    ((Get-NcIds $t3) -eq 'no-added-sugar=not-computable') (Get-NcIds $t3)

  $t4 = @(Get-TcNutrientClaimUse -Spec (New-NcSpec @{ cal = 300; protein = 30; fat = 2 } @{ intro_html = 'A low fat snack.' } @('Chicken') 1400) -Claims $C)
  Assert-NcCase 'CLEAN TWIN     a 100 g serving is NOT a main dish, so low fat is judged per serving (2 g against 3)' `
    ((Get-NcIds $t4) -eq 'low-fat=pass' -and $t4[0].Shown -match 'per serving') ((Get-NcIds $t4) + ' ' + $(if ($t4.Count) { $t4[0].Shown }))

  Assert-NcCase 'CLEAN TWIN     every claim on the list carries a CFR citation and a reason' `
    (@($C | Where-Object { -not $_.Cfr -or -not $_.Reason }).Count -eq 0 -and @($C).Count -ge 15) ('claims=' + @($C).Count)

  # ---- the list cannot fail open
  $threw = $false
  try { $null = Get-TcNutrientClaim -ListFile (Join-Path $here 'a-list-that-does-not-exist.json') } catch { $threw = $true }
  Assert-NcCase 'MUST FIRE      a MISSING list throws rather than measuring against nothing' $threw 'it measured with no claims'
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ('nc-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
  New-Item -ItemType Directory -Path $tmp -ErrorAction Stop | Out-Null
  try {
    $bad = Join-Path $tmp 'list.json'
    [IO.File]::WriteAllText($bad, '{ "terms": [], "nutrient_claims": { "claims": [ { "id": "x", "label": "x", "patterns": ["x"], "cfr": "c", "reason": "r", "bar": { "kind": "at_least_vibes" } } ] } }')
    $threw2 = $false; $msg = ''
    try { $null = Get-TcNutrientClaim -ListFile $bad } catch { $threw2 = $true; $msg = $_.Exception.Message }
    Assert-NcCase 'MUST FIRE      an UNKNOWN bar kind throws: the vocabulary is closed, so nothing decides by fall-through' ($threw2 -and $msg -match 'closed vocabulary') $msg
  } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }

  # ---- THE SEAL: the two production doors call the same function this measures with
  $needle = 'Get-TcNutrientClaim' + 'Finding'
  $bvs = [IO.File]::ReadAllText((Join-Path $here 'build-v2-spec.ps1'))
  Assert-NcCase 'CLEAN TWIN     build-v2-spec (the import door) calls the rule on its write path and throws for a NEW spec' `
    ($bvs -match [regex]::Escape($needle) -and $bvs -match '(?s)if\(\$ncHits\.Count\)\{[\s\S]{0,400}?if\(\$script:specIsNew\)\{[\s\S]{0,300}?throw') 'the import door does not refuse a new spec'
  $wpa = [IO.File]::ReadAllText((Join-Path $here 'wave-preaudit.ps1'))
  Assert-NcCase 'CLEAN TWIN     wave-preaudit carries the nutrient-claims check over the same function' `
    ($wpa -match [regex]::Escape($needle) -and $wpa -match "New-Check 'nutrient-claims'") 'the pre-audit does not call it'

  $live = Get-NcSpecFiles -Dir (Join-Path $mp 'db\recipes')
  Assert-NcCase 'CLEAN TWIN     the discovery resolves this checkout''s catalogue' (@($live).Count -gt 100) ('resolved=' + @($live).Count)

  if ($script:cases -eq 0) { $script:fail++ }
  ''
  if ($script:fail) {
    Write-Output ('nutrient-claims selftest: {0} FAILED of {1}' -f $script:fail, $script:cases)
    Exit-Guard -Name 'NUTRIENT-CLAIMS-SELFTEST' -Code 2 -Summary ('failed={0} of {1}' -f $script:fail, $script:cases)
  }
  Write-Output ('nutrient-claims selftest: {0} of {0} cases pass' -f $script:cases)
  Exit-Guard -Name 'NUTRIENT-CLAIMS-SELFTEST' -Code 0 -Summary ('cases={0}' -f $script:cases)
}

# ------------------------------------------------------------------------------------------------- live run
if (-not $RecipeDir) { $RecipeDir = Join-Path $mp 'db\recipes' }
$claims = $null
try { $claims = Get-TcNutrientClaim }
catch {
  Write-Output ('audit-nutrient-claims: BLIND - ' + $_.Exception.Message)
  Exit-Guard -Name 'AUDIT-NUTRIENT-CLAIMS' -Code 3 -Summary 'blind=no-claim-list'
}
$specs = Get-NcSpecFiles -Dir $RecipeDir
if (-not @($specs).Count) {
  Write-Output ('audit-nutrient-claims: BLIND - resolved 0 spec(s) under ' + $RecipeDir + ', which means the discovery is broken, not that the catalogue is clean')
  Exit-Guard -Name 'AUDIT-NUTRIENT-CLAIMS' -Code 3 -Summary 'blind=no-specs'
}

$rows = New-Object System.Collections.ArrayList
$read = 0; $unreadable = @(); $withUse = 0; $withFail = 0; $mainDish = 0
foreach ($f in $specs) {
  $spec = $null
  try { $spec = Get-Content -LiteralPath $f.FullName -Raw -Encoding utf8 | ConvertFrom-Json }
  catch { $unreadable += $f.Name; continue }
  $read++
  if ((Get-TcNutritionBasis $spec).main_dish) { $mainDish++ }
  $uses = @(Get-TcNutrientClaimUse -Spec $spec -Claims $claims)
  if ($uses.Count) { $withUse++ }
  if (@($uses | Where-Object { $_.Verdict -ne 'pass' }).Count) { $withFail++ }
  foreach ($u in $uses) { [void]$rows.Add([pscustomobject]@{ Slug = $f.BaseName; Use = $u }) }
}

$byClaim = [ordered]@{}
foreach ($c in $claims) { $byClaim[$c.Id] = [ordered]@{ label = $c.Label; cfr = $c.Cfr; uses = 0; pass = 0; fail = 0; nc = 0; beside = 0; recipes = @{} } }
foreach ($r in $rows) {
  $b = $byClaim[$r.Use.ClaimId]; $b.uses++; $b.recipes[$r.Slug] = 1
  switch ($r.Use.Verdict) { 'pass' { $b.pass++ } 'fail' { $b.fail++ } default { $b.nc++ } }
  if ($r.Use.Verdict -ne 'pass' -and $r.Use.BesideProduct) { $b.beside++ }
}
$nPass = @($rows | Where-Object { $_.Use.Verdict -eq 'pass' }).Count
$nFail = @($rows | Where-Object { $_.Use.Verdict -eq 'fail' }).Count
$nNc   = @($rows | Where-Object { $_.Use.Verdict -eq 'not-computable' }).Count

Write-Output ('audit-nutrient-claims: {0} spec(s) resolved, {1} read ({2} unreadable), {3} claim(s) on the list; {4} use(s) in {5} recipe(s): {6} pass, {7} fail, {8} not computable ({9} recipe(s) carry at least one use that does not pass)' -f @($specs).Count, $read, $unreadable.Count, @($claims).Count, $rows.Count, $withUse, $nPass, $nFail, $nNc, $withFail)
foreach ($k in $byClaim.Keys) {
  $b = $byClaim[$k]
  if ($b.uses) { Write-Output ('  {0,-22} uses={1,4} recipes={2,4} pass={3,4} fail={4,4} not-computable={5,4}' -f $k, $b.uses, $b.recipes.Count, $b.pass, $b.fail, $b.nc) }
}
foreach ($u in $unreadable) { Write-Output ('  unreadable (not judged)  ' + $u) }

if ($ReportFile) {
  $commit = ''
  try { $commit = (& git -C $repo rev-parse --short HEAD) } catch { $commit = 'unknown' }
  $blob = ''
  # hash-object, not rev-parse HEAD:<path>: it names the bytes that RAN, committed or not, and a rebase cannot move it
  try { $blob = (& git -C $repo hash-object (Join-Path $here 'nutrient-claim-lib.ps1')) } catch { $blob = 'unknown' }
  $sb = New-Object System.Text.StringBuilder
  $L = { param($s) [void]$sb.Append($s + "`n") }
  & $L '# I143: FDA nutrient content claim words on the live catalogue'
  & $L ''
  & $L ('Measured ' + (Get-Date -Format 'yyyy-MM-dd') + ' by `meal-prep\pipeline\audit-nutrient-claims.ps1 -ReportFile`, which calls `Get-TcNutrientClaimUse` in `meal-prep\pipeline\nutrient-claim-lib.ps1` (lib blob ' + $blob + ') over the list in the `nutrient_claims` block of `meal-prep\pipeline\forbidden-prose-global.json`, at base commit ' + $commit + '. Re-run the same command to refresh it.')
  & $L ''
  & $L '**Brad''s ruling (2026-09-19): "rule for new, measure old".** A NEW recipe may use one of these words only where its own per-serving macros clear the FDA bar; that is enforced at the import door and in the wave pre-audit. **This page is the "measure old" half. No live page was changed and nothing was published.** The question it puts to Brad is whether, and in what order, to sweep the uses below.'
  & $L ''
  & $L '## The count'
  & $L ''
  & $L ('- **{0} of {1} live recipes** carry at least one claim word as our own claim; **{2} uses** in all.' -f $withUse, $read, $rows.Count)
  & $L ('- **{0} pass** their bar, **{1} fail** it, and **{2} cannot be computed** because the bar needs a number no spec carries (sodium, sugars, fibre, saturated fat, cholesterol, or a reference food).' -f $nPass, $nFail, $nNc)
  & $L ('- **{0} of {1} recipes** carry at least one use that does not pass (fail or not computable).' -f $withFail, $read)
  & $L ('- {0} of {1} recipes weigh 6 oz or more a serving (raw ingredient weight over servings) and are judged as a main dish under 21 CFR 101.13(m); the rest by the per-serving conditions.' -f $mainDish, $read)
  & $L ''
  & $L '**Why this is not the item''s 767.** The item counted 12 spellings of 7 claims over 10 named prose fields. This counts 19 claims (the closed list, cited below) over every reader-facing field except the five rendered from the ingredient list, and it does NOT count a word that sits beside a product whose own name carries it (Fat Free Cheddar, BBQ Sauce (Sugar Free)) or a store-variant word (fat free, low sodium, sugar free, less fat...) directly before a product word (the low-fat kind, 1/3 less fat cream cheese, a high fiber tortilla), or a claim''s listed non-claim contexts (lean on, 93/7 lean, lean ground turkey, light and fluffy). Attribution, writer notes and the slug are not read. Different test, stated; neither number is wrong about its own test.'
  & $L ''
  & $L '## Per claim word'
  & $L ''
  & $L '| Claim | Rule | Uses | Recipes | Pass | Fail | Not computable | of the non-passing, beside a product word |'
  & $L '|---|---|---:|---:|---:|---:|---:|---:|'
  foreach ($k in $byClaim.Keys) {
    $b = $byClaim[$k]
    & $L ('| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} |' -f $b.label, $b.cfr, $b.uses, $b.recipes.Count, $b.pass, $b.fail, $b.nc, $b.beside)
  }
  & $L ''
  & $L '"Beside a product word" means the word sits directly next to a word of an ingredient the recipe buys, although that product''s recorded name does not carry the claim ("the sugar-free BBQ sauce" where the recipe buys plain "BBQ Sauce"). Those are usually a description of a product rather than of the dish, and the cheapest sweep for them is to name the product the recipe actually buys. The rest are claims about the dish.'
  & $L ''
  & $L '## How each bar is computed'
  & $L ''
  & $L 'Per serving is the spec''s own `stat` block (cal, protein, fat), which is what the card prints. Per 100 g divides by the serving weight, taken as the sum of `ingredients_grams` over servings: RAW weight, because the spec carries no cooked weight, which is an approximation in both directions. Two stricter legal readings are recorded and NOT applied, because the ruling names per-serving macros: a protein claim wants PDCAAS-corrected protein (21 CFR 101.9(c)(7)(i)), and 101.54(b) lets a main dish say "high" only of an identified component food. The CFR text was read on law.cornell.edu; ecfr.gov refused the fetch.'
  & $L ''
  & $L '## Every use that does not pass'
  & $L ''
  foreach ($k in $byClaim.Keys) {
    $list = @($rows | Where-Object { $_.Use.ClaimId -eq $k -and $_.Use.Verdict -ne 'pass' })
    if (-not $list.Count) { continue }
    & $L ('### ' + $byClaim[$k].label + ' (' + $list.Count + ')')
    & $L ''
    foreach ($r in $list) {
      $ex = ($r.Use.Excerpt -replace '\s+', ' ' -replace '\|', '/' -replace '<[^>]+>', '')
      & $L ('- `' + $r.Slug + '` ' + $r.Use.Field + ' - ' + $r.Use.Verdict.ToUpper() + ' (' + $r.Use.Shown + ')' + $(if ($r.Use.BesideProduct) { ' - beside a product word' } else { '' }) + ': "...' + $ex.Trim() + '..."')
    }
    & $L ''
  }
  & $L '## Uses that pass'
  & $L ''
  & $L ('{0} uses clear their bar and need nothing. By claim: ' -f $nPass)
  $pp = @(); foreach ($k in $byClaim.Keys) { if ($byClaim[$k].pass) { $pp += ($byClaim[$k].label + ' ' + $byClaim[$k].pass) } }
  & $L (($pp -join '; ') + '.')
  $dir = Split-Path -Parent $ReportFile
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  [IO.File]::WriteAllText($ReportFile, $sb.ToString(), (New-Object Text.UTF8Encoding($false)))
  Write-Output ('  report written: ' + $ReportFile)
}

Exit-Guard -Name 'AUDIT-NUTRIENT-CLAIMS' -Code 0 -Summary ('scanned={0} claims={1} uses={2} pass={3} fail={4} not_computable={5} unreadable={6}' -f $read, @($claims).Count, $rows.Count, $nPass, $nFail, $nNc, $unreadable.Count)
