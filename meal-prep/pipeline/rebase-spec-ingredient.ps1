<#
  rebase-spec-ingredient.ps1 - move ONE ingredient on a built spec onto a DIFFERENT food-DB item, and
  recompute the spec's per-serving macros from the change.

  WHY THIS EXISTS (2026-08-16). rebid-ingredient.ps1 moves what an ingredient COSTS. Nothing moved what it
  IS. The two are separate keys by design (build-v2-spec resolves price by ingredient row and macros by
  food-DB item, independently), so a spec can name one product, carry a second product's macros, and be
  priced off a third - which is exactly what five cream-cheese recipes were doing: cards reading "full-fat
  brick", macros from the USDA full-fat row, price from the 1/3-fat commodity. Brad ruled 2026-08-16 that
  the recipes should USE the lower-calorie product, which makes the price the correct field and the macros
  and the copy the wrong ones. Repointing macros on a built spec had no gated path, the same gap
  add-ingredient-row.ps1 closed for the vocabulary layer.

  IT RECOMPUTES THE WHOLE SPEC, NOT THE DELTA. Macros are re-derived by summing every ingredients_grams
  row against food-macros-db and dividing by servings - the same arithmetic build-v2-spec does. Before it
  writes anything it re-derives the spec's EXISTING macros the same way and requires them to match the
  stored stat within 1 unit. If the recompute cannot reproduce what is already there, it does not
  understand the spec and has no business writing new numbers into it. That check is the whole safety
  argument and it is not optional.

  PROSE-SAFE. Targeted string edits, never a re-serialize: the prose carries \uXXXX escapes that a
  ConvertTo-Json round trip rewrites. Four surfaces carry the name and all four move together -
  ingredients_grams, scaler.ing (item + canon), ingredients_display (with the food-DB brand), and the
  cost_lines label - because a spec that renames three of four is worse than one that renames none.

  IT DOES NOT TOUCH PRICE, GRAMS, OR PROSE ARGUMENT. The bid is left exactly as it is (on the cream-cheese
  recipes it was already correct). Grams never move. And it CANNOT fix a shop_smart bullet that argues for
  the old product - "buy the real full-fat brick, not the light tub" is a sentence, not a field, and
  rewriting it is the writer's job. This script REPORTS any prose that still argues the old product so the
  caller cannot ship a card that contradicts its own macros.

  AFTER RUNNING: engine\cost-recipes.ps1 -> pipeline\recost-spec-cost-block.ps1 -Slugs <slugs>
  -> pipeline\reanchor-machine-fields.ps1 -Slugs <slugs>, then re-QA.

  Usage:
    .\rebase-spec-ingredient.ps1 -Slug keto-cheeseburger-skillet -From 'Cream Cheese' -To '1/3 Fat Cream Cheese'
    .\rebase-spec-ingredient.ps1 ... -Apply
    .\rebase-spec-ingredient.ps1 -SelfTest
#>
param(
  [string]$Slug = '',
  [string]$From = '',
  [string]$To = '',
  [string]$SpecsDir = '',
  [string]$FoodDbFile = '',
  [switch]$Restat,          # recompute macros in place: the item did not move, its food-DB NUMBERS did
  [string]$PriorFoodDb = '',# the food DB as it was BEFORE that change - the proof that we understand the spec
  [string]$PriorSpecDir = '',# the specs as they were BEFORE their GRAMS moved - the other half of that proof
  [switch]$Apply,
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp   = Split-Path -Parent $here
if (-not $SpecsDir)   { $SpecsDir   = Join-Path $mp 'db\recipes' }
if (-not $FoodDbFile) { $FoodDbFile = Join-Path $mp 'food-macros-db.json' }

function Say([string]$s) { Write-Output $s }
function Die([string]$s) { Write-Output ('rebase-spec-ingredient: ' + $s); exit 1 }

# Per-serving macros for a spec, from food-macros-db. Returns $null when any ingredient has no food-DB
# row, because a partial sum is a wrong number that looks like a right one.
function Get-SpecMacros($gramsRows, [int]$servings, $macroMap) {
  $c = 0.0; $p = 0.0; $cb = 0.0; $f = 0.0
  foreach ($g in @($gramsRows)) {
    $row = $macroMap[[string]$g.item]
    if (-not $row) { return $null }
    $sg = [double]$row.serving_grams
    if ($sg -le 0) { return $null }
    $k = [double]$g.grams / $sg
    $c += $k * [double]$row.calories; $p += $k * [double]$row.protein_g
    $cb += $k * [double]$row.carbs_g; $f += $k * [double]$row.fat_g
  }
  if ($servings -le 0) { return $null }
  return @{ cal = $c / $servings; protein = $p / $servings; carbs = $cb / $servings; fat = $f / $servings }
}

# THE BRAND PAREN RULE IS BUILD-V2-SPEC'S, NOT THIS SCRIPT'S OWN (2026-08-28).
#
# This script used to build the display label as "<name> (<brand>):" unconditionally, which is only the
# rule when a brand exists. Two live specs proved both halves wrong in one run:
#   * 'Potatoes' -> 'Potato'. The Potatoes food-DB row has NO brand, so the display line reads
#     "<strong>Potatoes:</strong>" with no paren at all - and a search for "Potatoes ():" matched
#     nothing. The move renamed three structured fields, reported success, and left the reader-facing
#     line naming the OLD food. That is exactly the "renames three of four" this file's header calls
#     worse than renaming none, and nothing detected it.
#   * 'Baby Bella (Crimini) Mushrooms' (brand "fresh (USDA)") -> 'White Mushrooms' (no brand). The
#     paren was built from an empty string, so the card shipped "<strong>White Mushrooms ():</strong>".
# So the label is derived HERE the way build-v2-spec.ps1:243-246 derives it - empty/"fresh"/"store"
# brands take no paren, and a slashed brand keeps its first name - because two tools writing the same
# reader-facing string by different rules is the diverged-check family, and build-v2-spec is the
# authority: it is what wrote the line this script is editing.
function Get-BrandParen { param([string]$Brand)
  if (-not $Brand) { return '' }
  if ($Brand -match '^fresh$|store') { return '' }
  return ' (' + (($Brand -split '/')[0].Trim()) + ')'
}
# ANCHOR THE DISPLAY RENAME ON THE TAG, IN BOTH SPELLINGS. This script edits the spec as RAW TEXT to
# protect the prose escapes, so it sees whichever spelling the file stores - a literal "<strong>" or the
# JSON-escaped "<strong>" that every spec written by the v2 intake carries. Without the anchor
# a brandless label is the bare string "Potato:", which would also fire inside a sentence; with it, the
# only thing that can match is the head of an ingredients_display line.
# The escaped spelling is BUILT, not typed: a literal backslash-u in a PowerShell string is one keystroke
# away from being read as a .NET regex \uXXXX escape by the next person to touch this line.
# WHICH ROWS DOES THE PROOF RECOMPUTE? (2026-09-02)
#
# -Restat proves it understands a spec by reproducing the stored stat from the world as it was when that
# stat was written. Until now "the world" meant only the food DB, because the only restat anyone had
# needed was a corrected food-DB row. The corn basis migration moves BOTH halves at once: the food row
# goes to the USDA drained-solids basis AND 17 specs' corn grams are re-expressed x 298/432. Against a
# prior DB alone the proof then fails by construction - turkey-taco-soup reproduces 604.7 against a stored
# 619, because the recompute is reading NEW grams out of a spec whose stat was written from OLD ones - and
# the tool refuses a change it does in fact understand perfectly.
#
# So the prior SPEC is the other half of the snapshot, and it is supplied rather than inferred: there is no
# way to guess what the grams used to be, and guessing would be the whole safety argument thrown away. The
# proof is unchanged in strength - prior grams + prior DB must still reproduce the stored stat to the same
# tolerance - it is simply evaluated against a complete snapshot instead of half of one.
#
# IT MUST BE THIS SPEC'S OWN PAST, and that is checked, not assumed. A prior file for a different recipe,
# a different serving count, or a different ingredient LIST would let any number reproduce any other. Only
# the grams may differ; everything that identifies the spec has to match.
function Select-ProofRows { param($Current, $Prior)
  if (-not $Prior) { return @{ rows = $Current.ingredients_grams; why = '' } }
  if ([string]$Prior.slug -ne [string]$Current.slug) {
    return @{ rows = $null; why = ("the prior spec is slug '" + [string]$Prior.slug + "', not '" + [string]$Current.slug + "'") }
  }
  if ([int]$Prior.servings -ne [int]$Current.servings) {
    return @{ rows = $null; why = ("the prior spec has " + [int]$Prior.servings + " servings, the current one " + [int]$Current.servings + " - a per-serving stat cannot be proved across a servings change") }
  }
  # @() is load-bearing on both sides: PS 5.1 unrolls a one-element array and the -join would then read a
  # bare object's ToString(), which matches nothing and would refuse every single-ingredient spec.
  $pn = @(@($Prior.ingredients_grams)   | ForEach-Object { [string]$_.item })
  $cn = @(@($Current.ingredients_grams) | ForEach-Object { [string]$_.item })
  if (($pn -join '|') -ne ($cn -join '|')) {
    return @{ rows = $null; why = ("the prior spec's ingredient list differs (" + $pn.Count + ' vs ' + $cn.Count + " rows) - only GRAMS may move between the two") }
  }
  return @{ rows = $Prior.ingredients_grams; why = '' }
}

function Get-DisplayLabelPattern { param([string]$Label)
  $bs  = [string][char]0x5C
  $pre = '(' + [regex]::Escape('<strong>') + '|' + [regex]::Escape($bs + 'u003cstrong' + $bs + 'u003e') + ')'
  return $pre + [regex]::Escape($Label)
}

if ($SelfTest) {
  $bad = 0
  function T([string]$n, [bool]$ok, [string]$got) {
    if ($ok) { Say ('  ok    ' + $n) } else { Say ('  X     ' + $n + '   got: ' + $got); $script:bad++ }
  }
  $mm = @{}
  $mm['A'] = [pscustomobject]@{ serving_grams = 100; calories = 350; protein_g = 6.2; carbs_g = 5.5; fat_g = 34.4 }
  $mm['B'] = [pscustomobject]@{ serving_grams = 28;  calories = 70;  protein_g = 2;   carbs_g = 2;   fat_g = 6 }
  $rows = @([pscustomobject]@{ item = 'A'; grams = 200 })
  $m = Get-SpecMacros $rows 2 $mm
  T 'sums per 100 g and divides by servings' ([math]::Abs($m.cal - 350) -lt 1e-6) ([string]$m.cal)
  $rows2 = @([pscustomobject]@{ item = 'B'; grams = 280 })
  $m2 = Get-SpecMacros $rows2 2 $mm
  T 'handles a 28 g label basis'             ([math]::Abs($m2.cal - 350) -lt 1e-6) ([string]$m2.cal)
  # MUST FIRE: a missing food-DB row must abort the whole sum, never silently contribute zero.
  $rows3 = @([pscustomobject]@{ item = 'A'; grams = 100 }, [pscustomobject]@{ item = 'GONE'; grams = 100 })
  T 'MUST FIRE  a missing food-DB row returns null' ($null -eq (Get-SpecMacros $rows3 2 $mm)) 'got a number'
  $rows4 = @([pscustomobject]@{ item = 'A'; grams = 100 })
  T 'MUST FIRE  zero servings returns null'         ($null -eq (Get-SpecMacros $rows4 0 $mm))  'got a number'
  $mmBad = @{}; $mmBad['A'] = [pscustomobject]@{ serving_grams = 0; calories = 10; protein_g = 1; carbs_g = 1; fat_g = 1 }
  T 'MUST FIRE  a zero serving_grams returns null'  ($null -eq (Get-SpecMacros $rows4 2 $mmBad)) 'got a number'
  # --- the display label, the surface that failed silently (2026-08-28) --------------------------------
  # Both live defects are pinned here: a brandless FROM (the label has no paren, so the old
  # "From ():" search matched nothing and the reader kept the old name) and a brandless TO (the old code
  # emitted "White Mushrooms ():" onto a card). The rule is build-v2-spec.ps1:243-246's, so its two
  # filters are pinned too.
  T 'no brand takes NO paren, not an empty one'  ((Get-BrandParen '') -eq '')                    ("'" + (Get-BrandParen '') + "'")
  T 'a brand takes a paren'                      ((Get-BrandParen 'Great Value') -eq ' (Great Value)') (Get-BrandParen 'Great Value')
  T 'a slashed brand keeps its first name'       ((Get-BrandParen 'Eckrich/Armour') -eq ' (Eckrich)')  (Get-BrandParen 'Eckrich/Armour')
  T 'bare "fresh" is not a brand'                ((Get-BrandParen 'fresh') -eq '')               ("'" + (Get-BrandParen 'fresh') + "'")
  T '"fresh (USDA)" IS kept - it is not bare'    ((Get-BrandParen 'fresh (USDA)') -eq ' (fresh (USDA))') (Get-BrandParen 'fresh (USDA)')
  T 'a store brand is not a brand'               ((Get-BrandParen 'store brand') -eq '')         ("'" + (Get-BrandParen 'store brand') + "'")
  # The anchor: the label must move at the head of a display line in EITHER spelling, and must NOT fire
  # on the same words inside prose - the reason a bare brandless label cannot be replaced blindly.
  $escOpen = [string][char]0x5C + 'u003cstrong' + [string][char]0x5C + 'u003e'
  $pat = Get-DisplayLabelPattern 'Potato:'
  T 'MUST FIRE  matches the literal tag spelling'  ([regex]::IsMatch('<strong>Potato:</strong> 2 lb', $pat)) 'missed'
  T 'MUST FIRE  matches the escaped tag spelling'  ([regex]::IsMatch($escOpen + 'Potato:' , $pat))           'missed'
  T 'MUST FIRE  a brandless label is not replaced mid-sentence' (-not [regex]::IsMatch('and the Potato: see below', $pat)) 'fired on prose'
  T 'a longer name is not a prefix match'         (-not [regex]::IsMatch('<strong>Potatoes:</strong> 2 lb', $pat)) 'matched Potatoes'

  # --- THE PRIOR SPEC, the other half of the restat proof (2026-09-02) --------------------------------
  # FROZEN from turkey-taco-soup as the corn basis migration moved it: 866 g of corn re-expressed to 597 g
  # drained, 14 servings, stored stat.cal 619. The prior food DB priced corn at the undrained label
  # (80 cal / 125 g = 0.64 cal/g); the current one at USDA drained solids (67 cal / 100 g).
  $curSpec = [pscustomobject]@{ slug = 'turkey-taco-soup'; servings = 14
    ingredients_grams = @([pscustomobject]@{ item = 'Sweet Whole Kernel Corn'; grams = 597 },
                          [pscustomobject]@{ item = 'Rest of recipe'; grams = 1000 }) }
  $prvSpec = [pscustomobject]@{ slug = 'turkey-taco-soup'; servings = 14
    ingredients_grams = @([pscustomobject]@{ item = 'Sweet Whole Kernel Corn'; grams = 866 },
                          [pscustomobject]@{ item = 'Rest of recipe'; grams = 1000 }) }
  $sel1 = Select-ProofRows $curSpec $prvSpec
  T 'the prior spec supplies the grams the stored stat was written from (866, not 597)' `
    ($null -ne $sel1.rows -and [double]$sel1.rows[0].grams -eq 866) `
    ("rows=" + $(if ($sel1.rows) { [string]$sel1.rows[0].grams } else { 'refused: ' + $sel1.why }))
  # CLEAN TWIN: no prior spec given (a food-DB-only restat, every use before today) still proves against
  # the current rows, exactly as it did. This mode must not change behaviour for its existing callers.
  $sel2 = Select-ProofRows $curSpec $null
  T 'CLEAN TWIN with no -PriorSpecDir the proof still reads the CURRENT rows' `
    ($null -ne $sel2.rows -and [double]$sel2.rows[0].grams -eq 597) `
    ("rows=" + $(if ($sel2.rows) { [string]$sel2.rows[0].grams } else { 'refused: ' + $sel2.why }))
  # MUST FIRE: another recipe's file would let any stat reproduce any other.
  $wrongSlug = [pscustomobject]@{ slug = 'turkey-corn-chowder'; servings = 14; ingredients_grams = $prvSpec.ingredients_grams }
  T 'MUST FIRE  a prior file for a DIFFERENT recipe is refused' `
    ($null -eq (Select-ProofRows $curSpec $wrongSlug).rows) 'accepted another recipe as this one''s past'
  # MUST FIRE: a per-serving stat cannot be proved across a servings change.
  $wrongServ = [pscustomobject]@{ slug = 'turkey-taco-soup'; servings = 12; ingredients_grams = $prvSpec.ingredients_grams }
  T 'MUST FIRE  a prior file with different servings is refused' `
    ($null -eq (Select-ProofRows $curSpec $wrongServ).rows) 'accepted a servings change'
  # MUST FIRE: only GRAMS may move. An added or dropped ingredient is a different spec, not a re-gram.
  $wrongList = [pscustomobject]@{ slug = 'turkey-taco-soup'; servings = 14
    ingredients_grams = @([pscustomobject]@{ item = 'Sweet Whole Kernel Corn'; grams = 866 }) }
  T 'MUST FIRE  a prior file with a different ingredient LIST is refused' `
    ($null -eq (Select-ProofRows $curSpec $wrongList).rows) 'accepted a changed ingredient list'
  # CLEAN TWIN: a single-ingredient spec must still resolve - the PS 5.1 one-element unroll would
  # otherwise make the name join compare a bare object and refuse every one of them.
  $one  = [pscustomobject]@{ slug = 'x'; servings = 2; ingredients_grams = @([pscustomobject]@{ item = 'A'; grams = 100 }) }
  $oneP = [pscustomobject]@{ slug = 'x'; servings = 2; ingredients_grams = @([pscustomobject]@{ item = 'A'; grams = 200 }) }
  T 'CLEAN TWIN a ONE-ingredient spec is not refused by the array unroll' `
    ($null -ne (Select-ProofRows $one $oneP).rows) ((Select-ProofRows $one $oneP).why)
  # AND THE PROOF MUST STILL BITE. Supplying a prior spec does not excuse a stat that neither snapshot
  # can reproduce - the arithmetic below is what the caller's tolerance check then runs on.
  $mmPrior = @{}; $mmPrior['Sweet Whole Kernel Corn'] = [pscustomobject]@{ serving_grams = 125; calories = 80; protein_g = 1; carbs_g = 14; fat_g = 1 }
  $mmPrior['Rest of recipe'] = [pscustomobject]@{ serving_grams = 100; calories = 500; protein_g = 10; carbs_g = 10; fat_g = 10 }
  $provedCal = (Get-SpecMacros (Select-ProofRows $curSpec $prvSpec).rows 14 $mmPrior).cal
  $naiveCal  = (Get-SpecMacros (Select-ProofRows $curSpec $null).rows    14 $mmPrior).cal
  T 'the prior-grams proof and the current-grams proof are DIFFERENT numbers (so this is not a no-op)' `
    ([math]::Abs($provedCal - $naiveCal) -gt 5) ("prior=$provedCal current=$naiveCal")

  if ($bad) { Say ("rebase-spec-ingredient SELF-TEST FAIL ({0})" -f $bad); exit 1 }
  Say 'rebase-spec-ingredient SELF-TEST PASS'; exit 0
}

if (-not $Slug) { Die 'pass -Slug (or -SelfTest)' }
# -Restat: THE ITEM DID NOT MOVE, ITS NUMBERS DID (2026-08-27).
#
# WHY THIS MODE EXISTS. A food-DB row can be CORRECTED - and when it is, every built spec that used it
# carries stale macros with nothing in the estate able to refresh them. rebase-spec-ingredient was the
# only thing that recomputes a live spec's stat block, and it only did so for an item MOVE, so a
# corrected row simply never reached the recipes. Measured: Brad ruled the generic "Milk" row is
# store-brand 2% and not Fairlife, and 49 live specs needed their macros recomputed with no tool that
# could do it.
#
# THE SAFETY ARGUMENT IS KEPT WHOLE, WHICH IS THE ONLY REASON THIS IS SAFE. The rebase path proves it
# understands a spec by reproducing the stored stat from the CURRENT DB before writing anything. For a
# restat that check must fail by construction - the stored numbers are exactly what is stale. So the
# proof moves to the PRIOR DB: recomputing with the food DB as it was BEFORE the correction must
# reproduce the stored stat, and only then are the numbers from the CURRENT DB written. Same argument,
# same strength, evaluated against the right snapshot. Without -PriorFoodDb there is no proof and the
# script refuses rather than rewriting macros it cannot vouch for.
if ($Restat) {
  if (-not $From) { Die 'pass -From <the food-DB item whose numbers changed>' }
  if ($To -and $To -ne $From) { Die '-Restat recomputes in place; do not pass a different -To' }
  $To = $From
  if (-not $PriorFoodDb) { Die '-Restat needs -PriorFoodDb <the food DB before the change> - it is the proof that this script understands the spec, and without it macros would be rewritten on trust' }
  if (-not (Test-Path $PriorFoodDb)) { Die ('no prior food DB at ' + $PriorFoodDb) }
} else {
  if (-not $From) { Die 'pass -From <the food-DB item the spec carries today>' }
  if (-not $To)   { Die 'pass -To <the food-DB item it should carry>' }
  if ($From -eq $To) { Die '-From and -To are the same item (did you mean -Restat?)' }
}

$db = Get-Content $FoodDbFile -Raw -Encoding utf8 | ConvertFrom-Json
$items = @($db.items)
if ($items.Count -lt 100) { Die ('parsed only ' + $items.Count + ' food-DB items - implausible; parse error, not data.') }
$M = @{}; foreach ($i in $items) { $M[[string]$i.item] = $i }
if (-not $M.ContainsKey($From)) { Die ("no food-DB item '" + $From + "'") }
if (-not $M.ContainsKey($To))   { Die ("no food-DB item '" + $To + "' - capture its label first (meal-macro), never invent one") }

# The target must also be a name the vocabulary can price, or the cost chain will refuse after this runs.
# ASSIGN THEN WRAP - `@(Get-Content -Raw | ConvertFrom-Json)` collapses the array to ONE element in PS 5.1.
$ingParsed = Get-Content (Join-Path $mp 'db\ingredients.json') -Raw -Encoding utf8 | ConvertFrom-Json
$ing = @($ingParsed)
if ($ing.Count -lt 200) { Die ('parsed only ' + $ing.Count + ' vocabulary rows - implausible; parse error, not data.') }
$ingNames = @{}
foreach ($r in $ing) {
  if ([string]$r.item) { $ingNames[[string]$r.item] = $true }
  foreach ($a in @($r.aliases)) { if ([string]$a) { $ingNames[[string]$a] = $true } }
}
if (-not $ingNames.ContainsKey($To)) { Die ("'" + $To + "' is not in the ingredient vocabulary - the cost chain would refuse. Add the row first (add-ingredient-row.ps1).") }

$path = Join-Path $SpecsDir ($Slug + '.json')
if (-not (Test-Path $path)) { Die ('no spec at ' + $path) }
$raw = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) -replace '^\xEF\xBB\xBF', ''
$before = $raw | ConvertFrom-Json

$hit = @(@($before.ingredients_grams) | Where-Object { [string]$_.item -eq $From })
if ($hit.Count -eq 0) { Die ($Slug + " does not carry ingredient '" + $From + "'") }
if ($hit.Count -gt 1) { Die ($Slug + " carries '" + $From + "' more than once - refusing rather than guessing which") }

# THE SAFETY ARGUMENT: reproduce what is already stored before writing anything new.
# THE PROOF SNAPSHOT. For a rebase this is the current DB; for a restat it MUST be the prior one,
# because the stored stat is stale against the current DB by definition - that is the whole point.
$proofM = $M
if ($Restat) {
  $priorDb = Get-Content $PriorFoodDb -Raw -Encoding utf8 | ConvertFrom-Json
  $priorItems = @($priorDb.items)
  if ($priorItems.Count -lt 100) { Die ('prior food DB parsed only ' + $priorItems.Count + ' items - implausible; parse error, not data.') }
  $proofM = @{}; foreach ($i in $priorItems) { $proofM[[string]$i.item] = $i }
  if (-not $proofM.ContainsKey($From)) { Die ("the prior food DB has no item '" + $From + "' - it is not the snapshot this spec was built against") }
}
$priorSpec = $null
if ($Restat -and $PriorSpecDir) {
  $psPath = Join-Path $PriorSpecDir ($Slug + '.json')
  if (-not (Test-Path $psPath)) { Die ('-PriorSpecDir has no ' + $Slug + '.json - it is not the snapshot this spec was built against') }
  $priorSpec = Get-Content $psPath -Raw -Encoding utf8 | ConvertFrom-Json
}
$sel = Select-ProofRows $before $priorSpec
if ($null -eq $sel.rows) { Die ('-PriorSpecDir refused: ' + $sel.why) }
$check = Get-SpecMacros $sel.rows $before.servings $proofM
if ($null -eq $check) { Die 'could not re-derive the spec''s existing macros (an ingredient has no food-DB row); refusing to write new ones' }
foreach ($k in @('cal', 'protein', 'carbs', 'fat')) {
  $storedVal = [double]$before.stat.$k
  # THE TOLERANCE IS THE ESTATE'S, NOT THIS SCRIPT'S OWN (2026-08-27).
  #
  # A spec's stat is certified against a food-DB recompute at build time by build-v2-spec.ps1:335-336,
  # at 5 cal / 2 g protein - 'same as spec-guards', its header says. This script demanded 1.0 on every
  # field, with no rationale recorded, so it refused specs the estate's own build gate had passed.
  # Measured: of the 49 live specs carrying Milk, twelve reproduce to within 2.2-4.9 cal - inside the
  # gate that certified them, outside this one - and every one was blocked from a correction it needed.
  # Two tools measuring the same agreement with different rulers is the diverged-check family; the
  # build gate is the authority because it is what admitted the number in the first place.
  #
  # A MOVE KEEPS THE STRICTER RULER. Changing which food an ingredient IS deserves tighter confidence
  # than recomputing the same food's numbers, and 1.0 has been the move path's standard all along.
  $tol = if ($Restat) { if ($k -eq 'cal') { 5.0 } else { 2.0 } } else { 1.0 }
  if ([math]::Abs($check[$k] - $storedVal) -gt $tol) {
    Die ("recompute does not reproduce the stored stat." + $k + " (" + ("{0:N1}" -f $check[$k]) + " vs " + $storedVal + ") using " + $(if ($Restat) { "the PRIOR food DB - so this spec was not built against that snapshot" } else { "the current food DB" }) + " beyond a tolerance of " + $tol + " - this script does not understand this spec, so it will not rewrite its macros")
  }
}

# ---- the rename, across all four surfaces ----------------------------------------------------------------
# THE BRAND THE SPEC CARRIES TODAY comes from the snapshot it was BUILT against, which for a restat
# is the PRIOR db - the whole reason a restat exists is that the current row differs. Reading both
# ends from the current DB made the display rename a no-op, so a card would keep printing
# "(Fairlife)" while its macros had been recomputed as store brand: the worst of both, and silent.
$fromB = [string]$proofM[$From].brand; $toB = [string]$M[$To].brand
$new = $raw
$n = 0
# 1+2. ingredients_grams and scaler.ing item/canon: every bare "From" string value.
$new = [regex]::Replace($new, '("(?:item|canon)":\s*")' + [regex]::Escape($From) + '(")', { param($m) $script:n++; $m.Groups[1].Value + $To + $m.Groups[2].Value })
# 3. ingredients_display: "<strong>From (brand):</strong> ..." - or "<strong>From:</strong>" when the
# food-DB row carries no brand. See Get-BrandParen: both ends of the label are derived, never assembled
# here, and the count is asserted below because this surface failed silently before.
$fromLbl = $From + (Get-BrandParen $fromB) + ':'
$toLbl   = $To   + (Get-BrandParen $toB)   + ':'
$dispBefore = @([regex]::Matches($new, (Get-DisplayLabelPattern $fromLbl))).Count
$new = [regex]::Replace($new, (Get-DisplayLabelPattern $fromLbl), { param($m) $m.Groups[1].Value + $toLbl })
# 4. cost_lines / head.recipeIngredient labels: "From, <buy>"
$new = $new.Replace(('"' + $From + ', '), ('"' + $To + ', '))
# On a RESTAT the text may legitimately be untouched - if only the numbers changed and the brand did
# not, there is nothing to rename and the macro rewrite below is the whole edit.
if (-not $Restat -and $new -eq $raw) { Die 'the rename matched nothing in the raw text; refusing' }

$after = $null
try { $after = $new | ConvertFrom-Json } catch { Die ('the edit produced invalid JSON, nothing written: ' + $_.Exception.Message) }

# ---- prove the rename is complete and nothing else moved -------------------------------------------------
if (@($after.ingredients_grams).Count -ne @($before.ingredients_grams).Count) { Die 'ingredient count moved; refusing' }
$still = @(@($after.ingredients_grams) | Where-Object { [string]$_.item -eq $From }).Count +
         @(@($after.scaler.ing) | Where-Object { [string]$_.item -eq $From -or [string]$_.canon -eq $From }).Count
# A RESTAT IS NOT A MOVE, so the item name SHOULD still be there - that is the point. What must have
# changed is the brand-bearing display text and the macros. Applying the move's completeness check to
# a restat refuses every one of them.
if (-not $Restat -and $still -gt 0) { Die ("'" + $From + "' still appears in " + $still + ' structured field(s) after the rename; refusing a half-done move') }
if ($Restat -and $still -eq 0) { Die ("'" + $From + "' vanished from the structured fields during a RESTAT - the item was supposed to stay put; refusing") }
# THE DISPLAY SURFACE GETS THE SAME PROOF THE STRUCTURED ONES GET. A move that renamed three fields and
# left the reader-facing line naming the old food reported success for a whole run before this check
# existed. Only meaningful when the label actually changes: on a restat whose brand did not move, and on
# a spec whose display carries a reader-facing display_name instead of the canon name, the old label was
# never in the text and zero matches is the correct answer.
if ($fromLbl -ne $toLbl -and $dispBefore -gt 0) {
  $dispAfter = @([regex]::Matches($new, (Get-DisplayLabelPattern $fromLbl))).Count
  if ($dispAfter -gt 0) { Die ("the display label '" + $fromLbl + "' survives " + $dispAfter + ' time(s) after the rename; refusing a half-done move') }
}
for ($i = 0; $i -lt @($before.ingredients_grams).Count; $i++) {
  if ([double]@($after.ingredients_grams)[$i].grams -ne [double]@($before.ingredients_grams)[$i].grams) { Die 'a gram figure moved; refusing' }
}
foreach ($i in @($after.scaler.ing)) {
  $b = @($before.scaler.ing) | Where-Object { [string]$_.grams -eq [string]$i.grams -and [string]$_.bid -eq [string]$i.bid }
  if (-not $b) { Die 'a scaler bid moved; this script never touches price' }
}

# ---- the new macros --------------------------------------------------------------------------------------
$macros = Get-SpecMacros $after.ingredients_grams $after.servings $M
if ($null -eq $macros) { Die 'could not derive macros after the rename; nothing written' }
$rounded = @{}
foreach ($k in @('cal', 'protein', 'carbs', 'fat')) { $rounded[$k] = [int][math]::Round($macros[$k], 0) }

Say ('rebase-spec-ingredient: ' + $Slug)
Say ("    '{0}' ({1})  ->  '{2}' ({3})   {4} structured field(s) + {5} display line(s) renamed" -f $From, $fromB, $To, $toB, $n, $dispBefore)
Say ("    macros/serving  {0}/{1}/{2}/{3}  ->  {4}/{5}/{6}/{7}   (cal {8:+#;-#;0})" -f `
  $before.stat.cal, $before.stat.protein, $before.stat.carbs, $before.stat.fat, `
  $rounded.cal, $rounded.protein, $rounded.carbs, $rounded.fat, ($rounded.cal - [int]$before.stat.cal))

# stat + head are the two stamped surfaces; both are scalar and key-scoped.
$new = [regex]::Replace($new, '("stat":\s*\{[^}]*?"cal":\s*)\d+',     ('${1}' + $rounded.cal))
$new = [regex]::Replace($new, '("stat":\s*\{[^}]*?"protein":\s*)\d+', ('${1}' + $rounded.protein))
$new = [regex]::Replace($new, '("stat":\s*\{[^}]*?"carbs":\s*)\d+',   ('${1}' + $rounded.carbs))
$new = [regex]::Replace($new, '("stat":\s*\{[^}]*?"fat":\s*)\d+',     ('${1}' + $rounded.fat))
$final = $null
try { $final = $new | ConvertFrom-Json } catch { Die ('the stat rewrite produced invalid JSON: ' + $_.Exception.Message) }
foreach ($k in @('cal', 'protein', 'carbs', 'fat')) {
  if ([int]$final.stat.$k -ne $rounded[$k]) { Die ('stat.' + $k + ' did not take the new value; refusing') }
}

# ---- the part this script cannot do: prose that argues the OLD product -----------------------------------
$argue = @()
foreach ($b in @($final.shop_smart)) { if ($b -match '(?i)full.?fat|not the light|real .{0,12}brick|low.?fat kind') { $argue += ('shop_smart: ' + (($b -replace '<[^>]+>', '').Substring(0, [Math]::Min(150, ($b -replace '<[^>]+>', '').Length)))) } }
foreach ($b in @($final.cost_lines + $final.intro_html + $final.cost_closing_html)) { if ($b -match '(?i)full.?fat') { $argue += ('prose: ' + (($b -replace '<[^>]+>', '').Substring(0, [Math]::Min(120, ($b -replace '<[^>]+>', '').Length)))) } }
if ($argue.Count -gt 0) {
  Say ('    !! ' + $argue.Count + ' reader-facing line(s) still argue the OLD product - a WRITER must rewrite these:')
  foreach ($a in $argue) { Say ('       ' + $a) }
}

if (-not $Apply) { Say '    DRY RUN - nothing written. Re-run with -Apply.'; exit 0 }
[IO.File]::WriteAllText($path, $new, (New-Object System.Text.UTF8Encoding($false)))
Say ('    wrote ' + $path)
Say '    NEXT: cost-recipes -> recost-spec-cost-block -Slugs <slug> -> reanchor-machine-fields -Slugs <slug>, then re-QA.'
exit 0
