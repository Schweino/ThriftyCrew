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
  if ($bad) { Say ("rebase-spec-ingredient SELF-TEST FAIL ({0})" -f $bad); exit 1 }
  Say 'rebase-spec-ingredient SELF-TEST PASS'; exit 0
}

if (-not $Slug) { Die 'pass -Slug (or -SelfTest)' }
if (-not $From) { Die 'pass -From <the food-DB item the spec carries today>' }
if (-not $To)   { Die 'pass -To <the food-DB item it should carry>' }
if ($From -eq $To) { Die '-From and -To are the same item' }

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
$check = Get-SpecMacros $before.ingredients_grams $before.servings $M
if ($null -eq $check) { Die 'could not re-derive the spec''s existing macros (an ingredient has no food-DB row); refusing to write new ones' }
foreach ($k in @('cal', 'protein', 'carbs', 'fat')) {
  $storedVal = [double]$before.stat.$k
  if ([math]::Abs($check[$k] - $storedVal) -gt 1.0) {
    Die ("recompute does not reproduce the stored stat." + $k + " (" + ("{0:N1}" -f $check[$k]) + " vs " + $storedVal + ") - this script does not understand this spec, so it will not rewrite its macros")
  }
}

# ---- the rename, across all four surfaces ----------------------------------------------------------------
$fromB = [string]$M[$From].brand; $toB = [string]$M[$To].brand
$new = $raw
$n = 0
# 1+2. ingredients_grams and scaler.ing item/canon: every bare "From" string value.
$new = [regex]::Replace($new, '("(?:item|canon)":\s*")' + [regex]::Escape($From) + '(")', { param($m) $script:n++; $m.Groups[1].Value + $To + $m.Groups[2].Value })
# 3. ingredients_display: "<strong>From (brand):</strong> ..."
$new = $new.Replace(($From + ' (' + $fromB + '):'), ($To + ' (' + $toB + '):'))
# 4. cost_lines / head.recipeIngredient labels: "From, <buy>"
$new = $new.Replace(('"' + $From + ', '), ('"' + $To + ', '))
if ($new -eq $raw) { Die 'the rename matched nothing in the raw text; refusing' }

$after = $null
try { $after = $new | ConvertFrom-Json } catch { Die ('the edit produced invalid JSON, nothing written: ' + $_.Exception.Message) }

# ---- prove the rename is complete and nothing else moved -------------------------------------------------
if (@($after.ingredients_grams).Count -ne @($before.ingredients_grams).Count) { Die 'ingredient count moved; refusing' }
$still = @(@($after.ingredients_grams) | Where-Object { [string]$_.item -eq $From }).Count +
         @(@($after.scaler.ing) | Where-Object { [string]$_.item -eq $From -or [string]$_.canon -eq $From }).Count
if ($still -gt 0) { Die ("'" + $From + "' still appears in " + $still + ' structured field(s) after the rename; refusing a half-done move') }
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
Say ("    '{0}' ({1})  ->  '{2}' ({3})   {4} structured field(s) renamed" -f $From, $fromB, $To, $toB, $n)
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
