# audit-allergen-line.ps1
# ===================================================================================================
# THE PUBLISH CHECK Brad's ruling asks for (2026-09-12, backlog I144): it refuses a card whose
# 'Contains' line is MISSING or DISAGREES with its ingredients.
#
# HOW "DISAGREES" IS DECIDED, and it is the reason this is worth having. The check does not re-implement
# the rule and compare conclusions; it re-derives the line through the SAME Format-TcAllergenLine that
# build-card2.ps1 rendered it with, and compares the bytes. So the only way to pass is to carry the line
# this estate's one allergen rule produces for this spec's CURRENT ingredients. Two implementations of
# one rule drift - the price formatter had five copies, and the notes-vs-bid check still has two.
#
# WHAT IT CATCHES THAT THE BUILD CANNOT. build-card2 generates the line, so a freshly built card can
# never be missing one. The failure this exists for is a STALE card: a spec whose ingredients changed
# after the card was built, or a card built before the ruling landed. Those cards are still on disk and
# still publishable, and their line is wrong in the direction that matters.
#
# SCOPE OF A CLEAN REPORT: SOUND for the question it asks, which is narrow. Given a spec and its built
# card it decides exactly whether the card's line equals the derivation from db\allergens.json, and it
# cannot miss a disagreement. It says NOTHING about whether the classification in db\allergens.json is
# correct for the real product on the shelf - that is a judgement recorded in that file's own `rule`
# field, not something any detector here verifies.
#
# WIRED, DELIBERATELY, WHERE THE CARDS ARE FRESH. wave-publish.ps1's P5 gate table runs it scoped to the
# wave's slugs, and those cards were built by the wave, so the gate is green on day one - the ops rule
# against a gate that is red on its first run. An UNSCOPED run over the whole catalogue is a REPORT and
# is red today on purpose: the 584 cards built before this ruling carry no line, and republishing them
# is its own tracked piece of work (backlog, I144 backfill), not something to smuggle into a gate.
#
#   .\audit-allergen-line.ps1                      report over every built card (red until the backfill)
#   .\audit-allergen-line.ps1 -Slugs a,b,c         wave-publish preflight
#   .\audit-allergen-line.ps1 -Json                machine-readable
#   .\audit-allergen-line.ps1 -SelfTest            frozen fixtures, hermetic
# Exit 0 clean, 1 findings, 2 self-test failure.
# ===================================================================================================
param(
  [string[]]$Slugs = @(),
  [string]$RecipesDir,
  [string]$BuiltDir,
  [string]$TablePath,
  [switch]$Json,
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
# Captured BEFORE the dot-sources below: a dot-sourced param() block binds in THIS scope under PS 5.1
# and would reset them (lib\guard-contract.ps1's header records the measured case).
$runSelfTest = [bool]$SelfTest; $runJson = [bool]$Json

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp   = Split-Path -Parent $here
$repo = Split-Path -Parent $mp
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $mp 'lib\allergen-lib.ps1')

if (-not $RecipesDir) { $RecipesDir = Join-Path $mp 'db\recipes' }
if (-not $BuiltDir)   { $BuiltDir   = Join-Path $mp 'db\built' }
if (-not $TablePath)  { $TablePath  = Join-Path $mp 'db\allergens.json' }

# ---------------------------------------------------------------------------------------------------
# THE PREDICATE, pure, so every founding case is pinned without a spec, a card or a file. Returns the
# finding kind for one card, or '' when the card agrees.
# ---------------------------------------------------------------------------------------------------
function Get-AllergenLineVerdict {
  param([string]$CardHtml, [string]$Expected)
  $found = Get-TcCardAllergenLine $CardHtml
  if ($null -eq $found) { return 'missing' }
  # ORDINAL, because this compares text that came off disk and may carry damage. PowerShell's default
  # string comparison is culture-sensitive and a culture-sensitive compare IGNORES an embedded NUL, so
  # the default operator is blind to exactly the corruption a byte check exists to find.
  if (-not [string]::Equals($found, $Expected, [StringComparison]::Ordinal)) { return 'disagrees' }
  return ''
}

# ---- self-test ------------------------------------------------------------------------------------
if ($runSelfTest) {
  $bad = 0
  $ran = 0
  function T([string]$name, [bool]$ok, [string]$got) {
    $script:ran++
    if ($ok) { Write-Output ("  ok    " + $name) } else { Write-Output ("  X     " + $name + "   got: " + $got); $script:bad++ }
  }
  # A frozen table, not the live one, for every behavioural case: the live file is edited whenever an
  # ingredient is added, and a fixture that moves with its subject stops being a fixture.
  $FX = @{
    'Worcestershire Sauce' = [pscustomobject]@{ contains=@('fish:anchovy'); hidden=@{ 'fish'='the anchovies in Worcestershire sauce' } }
    'Oyster Sauce'         = [pscustomobject]@{ contains=@('shellfish:oyster'); hidden=@{ 'shellfish'='the oysters in oyster sauce' } }
    'Penne Pasta'          = [pscustomobject]@{ contains=@('wheat'); hidden=@{} }
    'Parmesan Cheese'      = [pscustomobject]@{ contains=@('milk'); hidden=@{} }
    '93/7 Ground Beef'     = [pscustomobject]@{ contains=@(); hidden=@{} }
    'Salt'                 = [pscustomobject]@{ contains=@(); hidden=@{} }
    'Almonds'              = [pscustomobject]@{ contains=@('tree_nuts:almond'); hidden=@{} }
    'Walnuts'              = [pscustomobject]@{ contains=@('tree_nuts:walnut'); hidden=@{} }
    'Soy Sauce'            = [pscustomobject]@{ contains=@('soy','wheat'); hidden=@{ 'wheat'='the wheat soy sauce is brewed with' } }
    'Teriyaki Sauce'       = [pscustomobject]@{ contains=@('soy','wheat'); hidden=@{ 'wheat'='the wheat soy sauce is brewed with' } }
  }
  function Ing([string[]]$Names) { $o = @(); foreach ($n in $Names) { $o += [pscustomobject]@{ item=$n; grams=100 } }; return ,$o }

  # ---- MUST FIRE: the two hidden sources Brad's ruling names by name ------------------------------
  # 42 of 583 recipes carry Worcestershire and its ingredient list never said anchovy. This is the
  # founding case of the whole item.
  $rW = Get-TcRecipeAllergens (Ing @('93/7 Ground Beef','Penne Pasta','Worcestershire Sauce')) $FX
  $lW = Format-TcAllergenLine $rW 'fixture-worcestershire'
  T 'MUST FIRE  Worcestershire puts FISH on the line and names the anchovy' `
    ($lW -match 'fish \(anchovy\)') $lW
  T 'MUST FIRE  ...and calls it out as a hidden source in the reader''s words' `
    ($lW -match 'Easy to miss: fish, from the anchovies in Worcestershire sauce\.') $lW
  $rO = Get-TcRecipeAllergens (Ing @('Salt','Oyster Sauce')) $FX
  $lO = Format-TcAllergenLine $rO 'fixture-oyster'
  T 'MUST FIRE  oyster sauce puts SHELLFISH on the line and names the oyster' `
    ($lO -match 'shellfish \(oyster\)' -and $lO -match 'the oysters in oyster sauce') $lO

  # ---- MUST FIRE: an ingredient the table cannot classify REFUSES, never renders ------------------
  # The agreeing-zero shape. An unclassified ingredient that contributed nothing would render a line
  # saying the recipe contains less than it does, and it would look like a clean lookup.
  $rU = Get-TcRecipeAllergens (Ing @('Penne Pasta','Something Nobody Classified')) $FX
  T 'MUST FIRE  an unclassified ingredient is reported as unknown, not skipped' `
    (@($rU.unknown).Count -eq 1 -and @($rU.unknown)[0] -eq 'Something Nobody Classified') (@($rU.unknown) -join ',')
  $threw = $false
  try { $null = Format-TcAllergenLine $rU 'fixture-unknown' } catch { $threw = $true }
  T 'MUST FIRE  and rendering a line over an unclassified ingredient THROWS rather than understating' `
    $threw 'it rendered a line anyway'

  # ---- MUST FIRE: the two failures the publish check exists to refuse -----------------------------
  $goodCard = '<h2>Ingredients</h2><ul class="smp-ing"><li>x</li></ul>' + $lW + '<!--TC-PAYWALL-->'
  $noLineCard = '<h2>Ingredients</h2><ul class="smp-ing"><li>x</li></ul><!--TC-PAYWALL-->'
  T 'MUST FIRE  a card with NO allergen line is refused as missing' `
    ((Get-AllergenLineVerdict $noLineCard $lW) -eq 'missing') (Get-AllergenLineVerdict $noLineCard $lW)
  # The stale card: built when the recipe had no Worcestershire, published after somebody added it.
  $staleCard = '<ul class="smp-ing"><li>x</li></ul>' + (Format-TcAllergenLine (Get-TcRecipeAllergens (Ing @('93/7 Ground Beef','Penne Pasta')) $FX) 'fixture-stale')
  T 'MUST FIRE  a card whose line predates an added Worcestershire is refused as disagreeing' `
    ((Get-AllergenLineVerdict $staleCard $lW) -eq 'disagrees') (Get-AllergenLineVerdict $staleCard $lW)

  # ---- MUST NOT FIRE: the legal input -------------------------------------------------------------
  T 'MUST NOT FIRE a card carrying exactly the derived line is silent' `
    ((Get-AllergenLineVerdict $goodCard $lW) -eq '') (Get-AllergenLineVerdict $goodCard $lW)

  # ---- CLEAN TWIN: the behaviours this fix was most likely to have broken -------------------------
  # A recipe with none of the nine must say so OUT LOUD. An empty line, or no line, is the shape a
  # reader cannot tell from "nobody checked".
  $rN = Get-TcRecipeAllergens (Ing @('93/7 Ground Beef','Salt')) $FX
  $lN = Format-TcAllergenLine $rN 'fixture-none'
  T 'CLEAN TWIN a recipe with none of the nine states that explicitly, rather than rendering nothing' `
    ($lN -match 'Contains:</strong> none of the nine major US allergens\.' -and $lN -match 'smp-allergen') $lN
  T 'CLEAN TWIN ...and carries no Easy-to-miss clause when nothing is hidden' `
    ($lN -notmatch 'Easy to miss') $lN
  # Two different tree nuts are ONE entry naming both, which is the whole point of naming the specific
  # nut: "tree nuts" alone tells an almond-allergic reader nothing they can act on.
  $r2 = Get-TcRecipeAllergens (Ing @('Walnuts','Almonds','Salt')) $FX
  $l2 = Format-TcAllergenLine $r2 'fixture-twonuts'
  T 'CLEAN TWIN two tree nuts render as one entry naming both, alphabetically' `
    ($l2 -match 'tree nuts \(almond, walnut\)') $l2
  # Determinism: the same recipe in a different ingredient order must produce the SAME bytes, or a card
  # fails its own publish check on a rebuild that changed nothing.
  $rA = Get-TcRecipeAllergens (Ing @('Worcestershire Sauce','Parmesan Cheese','Penne Pasta')) $FX
  $rB = Get-TcRecipeAllergens (Ing @('Penne Pasta','Worcestershire Sauce','Parmesan Cheese')) $FX
  $lA = Format-TcAllergenLine $rA 's'; $lB = Format-TcAllergenLine $rB 's'
  T 'CLEAN TWIN ingredient ORDER does not move a single byte of the line' `
    ([string]::Equals($lA, $lB, [StringComparison]::Ordinal)) ("A=" + $lA + " B=" + $lB)
  # Statutory order is milk, eggs, fish, shellfish, tree nuts, peanuts, wheat, soy, sesame. $rA's
  # ingredients arrive Worcestershire (fish), Parmesan (milk), Penne (wheat), so ingredient order and
  # statutory order disagree and the assertion can actually fail.
  $iMilk = $lA.IndexOf('milk'); $iFish = $lA.IndexOf('fish (anchovy)'); $iWheat = $lA.IndexOf('wheat')
  T 'CLEAN TWIN the nine render in their statutory order, not in ingredient order' `
    ($iMilk -gt 0 -and $iMilk -lt $iFish -and $iFish -lt $iWheat) ("milk@$iMilk fish@$iFish wheat@$iWheat in " + $lA)
  # Two ingredients hiding the SAME allergen for the same reason must not print the clause twice.
  $rD = Get-TcRecipeAllergens (Ing @('Soy Sauce','Teriyaki Sauce')) $FX
  $lD = Format-TcAllergenLine $rD 'fixture-dupe'
  T 'CLEAN TWIN two ingredients hiding the same allergen print ONE clause, not two' `
    (@([regex]::Matches($lD, 'the wheat soy sauce is brewed with')).Count -eq 1) $lD
  # canon is what the costing and the vocabulary audits key on; the display name drifts from it.
  $rC = Get-TcRecipeAllergens @([pscustomobject]@{ item='Lea &amp; Perrins'; canon='Worcestershire Sauce'; grams=30 }) $FX
  T 'CLEAN TWIN the lookup keys on canon, not on the drifting display name' `
    (@($rC.unknown).Count -eq 0 -and @($rC.present).Count -eq 1) (@($rC.unknown) -join ',')

  # ---- MUST FIRE: the note Brad's ruling requires is part of the line -----------------------------
  T 'MUST FIRE  every line carries the note that it is the recipe as written and brands differ' `
    ($lW -match 'the recipe as written' -and $lW -match 'read the label on the brands you buy') $lW

  # ---- MUST FIRE: the live TABLE, not just the code -----------------------------------------------
  # A generator with a perfect renderer and a wrong table ships a wrong line. These read the real file.
  $liveTable = Get-TcAllergenTable -Path $TablePath
  $liveMap = $liveTable.Items
  T 'MUST FIRE  the live table classifies Worcestershire Sauce as fish (anchovy)' `
    ($liveMap.ContainsKey('Worcestershire Sauce') -and (@($liveMap['Worcestershire Sauce'].contains) -join ',') -eq 'fish:anchovy') `
    $(if ($liveMap.ContainsKey('Worcestershire Sauce')) { (@($liveMap['Worcestershire Sauce'].contains) -join ',') } else { 'absent' })
  T 'MUST FIRE  the live table classifies Oyster Sauce as shellfish (oyster)' `
    ($liveMap.ContainsKey('Oyster Sauce') -and (@($liveMap['Oyster Sauce'].contains) -join ',') -eq 'shellfish:oyster') `
    $(if ($liveMap.ContainsKey('Oyster Sauce')) { (@($liveMap['Oyster Sauce'].contains) -join ',') } else { 'absent' })
  # COMPLETENESS, held at push time. gen_allergen_table.py refuses to write an incomplete table, but a
  # generator's refusal only binds whoever runs the generator: a hand-edited ingredients.json would add
  # a row nobody classified, and the first card using it would throw at build. This turns that into a
  # named case at push time instead.
  $ingRows = Get-Content -LiteralPath (Join-Path $mp 'db\ingredients.json') -Raw -Encoding utf8 | ConvertFrom-Json
  $tableDoc = Get-Content -LiteralPath $TablePath -Raw -Encoding utf8 | ConvertFrom-Json
  $exempt = @{}
  foreach ($nf in @($tableDoc.not_a_food)) { $exempt[[string]$nf] = 1 }
  $unclassified = @()
  foreach ($row in @($ingRows)) {
    $nm = [string]$row.item
    if (-not $nm -or $exempt.ContainsKey($nm)) { continue }
    if (-not $liveMap.ContainsKey($nm)) { $unclassified += $nm }
  }
  T ('MUST FIRE  every food row of the ingredient map is classified (examined ' + @($ingRows).Count + ' row(s), ' + $exempt.Count + ' exempt)') `
    (@($unclassified).Count -eq 0) (@($unclassified) -join ', ')

  # ---- MUST FIRE: the WIRING. A generator nothing calls renders nothing ---------------------------
  $bc = Get-Content -LiteralPath (Join-Path $here 'build-card2.ps1') -Raw -Encoding utf8
  T 'MUST FIRE  build-card2.ps1 actually calls the line generator' `
    ($bc -match 'Format-TcAllergenLine') 'the renderer has no caller in build-card2'
  # ABOVE THE PAYWALL, and this is an assertion on the MECHANISM rather than on prose: a reader with a
  # peanut allergy must not have to buy a membership to learn the recipe has peanuts.
  $idxLine = $bc.IndexOf('Format-TcAllergenLine $allergenResult')
  $idxWall = $bc.IndexOf("'<!--TC-PAYWALL-->'")
  T 'MUST FIRE  the line is rendered ABOVE the paywall cut, so it is free to read' `
    ($idxLine -gt 0 -and $idxWall -gt 0 -and $idxLine -lt $idxWall) ("line@$idxLine wall@$idxWall")
  $wp = Get-Content -LiteralPath (Join-Path $here 'wave-publish.ps1') -Raw -Encoding utf8
  T 'MUST FIRE  wave-publish.ps1 runs this check as a publish gate' `
    ($wp -match 'audit-allergen-line') 'the publish gate is not wired'

  # ---- MUST FIRE: the -Slugs comma-marshalling trap, in this script''s own interface ---------------
  # `powershell -File script.ps1 -Slugs a,b` hands this ONE element. A receiver that does not split
  # sweeps zero cards and prints ok, which is a silent false pass on a gate.
  $joined = @('a,b') | Where-Object { $_ } | ForEach-Object { ([string]$_).Split(',') } | ForEach-Object { $_.Trim() } | Where-Object { $_ }
  T 'MUST FIRE  a comma-joined -Slugs string splits into TWO slugs, not one' (@($joined).Count -eq 2) ([string]@($joined).Count)

  # THE CASES ARE A LITERAL LIST, so this suite knows its own number and a shortfall is a defect rather
  # than a smaller tree. One branch of this estate once printed PASS with a case never reached.
  $expectedCases = 23
  if ($ran -ne $expectedCases) {
    Write-Output ("audit-allergen-line SELF-TEST FAIL: ran {0} case(s), expected {1} - a case did not run" -f $ran, $expectedCases)
    exit 2
  }
  if ($bad -gt 0) { Write-Output ("audit-allergen-line SELF-TEST FAIL ({0} of {1} case(s))" -f $bad, $ran); exit 2 }
  Write-Output ("audit-allergen-line SELF-TEST PASS: {0} of {0} case(s)" -f $ran)
  Exit-Guard -Name 'audit-allergen-line' -Summary ("selftest pass cases={0}" -f $ran) -Code 0
}

# ---- sweep -----------------------------------------------------------------------------------------
# SPLIT ON COMMA: wave-publish invokes gates across the -File boundary, where a list arrives joined.
$slugList = @($Slugs | Where-Object { $_ } | ForEach-Object { ([string]$_).Split(',') } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

if (-not (Test-Path -LiteralPath $RecipesDir)) {
  Write-Output ("audit-allergen-line: no recipes directory at {0}" -f $RecipesDir)
  Exit-Guard -Name 'audit-allergen-line' -Summary 'no-recipes-dir' -Code 1
}
$table = Get-TcAllergenTable -Path $TablePath

$missingSpecs = @()
$files = if (@($slugList).Count -gt 0) {
  $acc = @()
  foreach ($s in $slugList) {
    $p = Join-Path $RecipesDir ($s + '.json')
    if (Test-Path -LiteralPath $p) { $acc += $p } else { $missingSpecs += $s }
  }
  @($acc)
} else {
  $walked = Get-ChildItem -LiteralPath $RecipesDir -Filter *.json -ErrorAction SilentlyContinue
  @($walked | ForEach-Object { $_.FullName })
}
# A named slug with no spec is a finding, not a silent skip: "swept 0 of 2" must never read as clean.
if (@($missingSpecs).Count -gt 0) {
  Write-Output ("audit-allergen-line: {0} named slug(s) have NO spec in {1}: {2}" -f @($missingSpecs).Count, $RecipesDir, (@($missingSpecs) -join ', '))
  Exit-Guard -Name 'audit-allergen-line' -Summary ("missing-specs={0}" -f @($missingSpecs).Count) -Code 1
}

$findings = @()
$swept = 0
foreach ($f in $files) {
  $slug = [IO.Path]::GetFileNameWithoutExtension($f)
  $spec = $null
  try { $spec = Get-Content -LiteralPath $f -Raw -Encoding utf8 | ConvertFrom-Json } catch { }
  if (-not $spec) { $findings += [pscustomobject]@{ slug=$slug; kind='unreadable-spec'; detail='the spec would not parse' }; continue }
  $ing = @()
  if (($spec.PSObject.Properties.Name -contains 'scaler') -and $spec.scaler -and ($spec.scaler.PSObject.Properties.Name -contains 'ing')) { $ing = @($spec.scaler.ing) }
  if (@($ing).Count -eq 0) { continue }
  $swept++
  $result = Get-TcRecipeAllergens $ing $table.Items
  if (@($result.unknown).Count -gt 0) {
    $findings += [pscustomobject]@{ slug=$slug; kind='unclassified'; detail=("not in db\allergens.json: " + (@($result.unknown) -join ', ')) }
    continue
  }
  $expected = Format-TcAllergenLine $result $slug
  $cardPath = Join-Path $BuiltDir ($slug + '.body.html')
  if (-not (Test-Path -LiteralPath $cardPath)) {
    # A named slug whose card was never built is a FINDING, never a skip. "could not look" is not a
    # clean bill on a page we are about to sell.
    $findings += [pscustomobject]@{ slug=$slug; kind='no-card'; detail=('no built card at ' + $cardPath) }
    continue
  }
  $card = Get-Content -LiteralPath $cardPath -Raw -Encoding utf8
  $verdict = Get-AllergenLineVerdict $card $expected
  if ($verdict) {
    $found = Get-TcCardAllergenLine $card
    $findings += [pscustomobject]@{ slug=$slug; kind=$verdict; detail=$(if ($verdict -eq 'missing') { 'the card carries no Contains line' } else { 'card: ' + $found }); expected=$expected }
  }
}

if ($runJson) {
  ([pscustomobject]@{ swept=$swept; findings=@($findings) } | ConvertTo-Json -Depth 6)
  if (@($findings).Count -gt 0) { exit 1 }
  exit 0
}

Write-Output ("audit-allergen-line: examined {0} of {1} spec(s) with ingredients" -f $swept, @($files).Count)
if (@($findings).Count -eq 0) {
  Write-Output '  ok - every card carries the allergen line its own ingredients derive'
  Exit-Guard -Name 'audit-allergen-line' -Summary ("clean n={0}" -f $swept) -Code 0
}
$byKind = @{}
foreach ($x in $findings) { if (-not $byKind.ContainsKey($x.kind)) { $byKind[$x.kind] = 0 }; $byKind[$x.kind]++ }
Write-Output ("  {0} of {1} card(s) do not carry the allergen line their ingredients derive:" -f @($findings).Count, $swept)
foreach ($k in (@($byKind.Keys) | Sort-Object)) { Write-Output ("    {0,-16} {1}" -f $k, $byKind[$k]) }
foreach ($x in (@($findings) | Select-Object -First 25)) {
  Write-Output ("    {0,-52} {1,-16} {2}" -f $x.slug, $x.kind, $x.detail)
}
if (@($findings).Count -gt 25) { Write-Output ("    ... and {0} more" -f (@($findings).Count - 25)) }
Write-Output '  Fix: rebuild the card (engine\build-cards.ps1, or the wave''s own build step). The line is generated,'
Write-Output '       so it is never hand-repaired - a hand-written allergen line is the thing this check exists to refuse.'
Write-Output '       An "unclassified" finding needs the ingredient added to pipeline\gen_allergen_table.py and the generator rerun.'
Exit-Guard -Name 'audit-allergen-line' -Summary ("findings={0} swept={1}" -f @($findings).Count, $swept) -Code 1
