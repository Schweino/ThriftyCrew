<#
  head-ingredients-lib.ps1 - derive head.recipeIngredient (the schema.org JSON-LD ingredient list) from
  the ONE list the card actually renders, ingredients_display.

  THE DEFECT (2026-08-04). head.recipeIngredient was never derived from anything. build-v2-spec takes it
  from the intake file's head block when present (writers hand-typed it) and only falls back to a
  derivation when it is absent; the 500-recipe archive runs emitted it EMPTY and the writer wave filled it
  in by hand. So the field is prose, and prose about a list of numbers drifts:

    MEASURED over 513 specs - 507 disagree with ingredients_display on COUNT alone.
    american-goulash-pasta: 6 lines in the JSON-LD against 16 on the page. Ten real ingredients
    (beef broth, parmesan, garlic, italian seasoning, olive oil, celery, worcestershire, salt, pepper,
    sugar) are absent from the structured data entirely.

  Worse than incomplete, it also DISAGREES. The writers typed a SHOPPING list - what you put in the cart,
  in package units - while the page's Ingredients section states the COOK measure (the 2026-08-02
  cook-measure work: the Ingredients list answers "what goes in the pot", the cost section answers "what
  do I buy"). The JSON-LD said "3 boxs Penne Pasta" where the card said "10 cups (1050 g)". Two different
  unit bases for the same food, one of them carrying a pluralization typo from a retired generator.

  Google's Recipe structured-data guidance is that the markup must represent the visible page. A list that
  names 6 of 16 ingredients in units the page never uses is not that list.

  THE FIX is to stop maintaining a second ingredient list. ingredients_display is already the reader's
  list, already parallel to scaler.ing/ingredients_grams, already guarded by spec-guards' format lint and
  kept honest by repair-cook-measures. This derives the JSON-LD from it, so the two cannot disagree.

  THE LINE SHAPE is "<name>, <amount> (<grams> g)" - the house convention already used by cost_lines
  ("Penne Pasta, 10 cups: ~$0.64."). Amount-first reads wrong here because many `buy` labels carry their
  own noun ("3 onions", "4 cloves", "4 large eggs"), which yields "3 onions Yellow Onion".

  THE BRAND PARENTHETICAL is dropped. The card says "Carrots (generic)" and "93/7 Ground Beef
  (Member's Mark)" because build-v2-spec appends a brand from food-macros-db; a store brand is a shopping
  detail, and "(generic)" - 1,029 of the 5,019 branded lines - is actively worse than no brand at all in
  structured data. It is removed the same way it was added (exact suffix match against the food DB brand),
  never by stripping whatever happens to be in the last parentheses: 8 display names carry a REAL
  parenthetical ("BBQ Sauce (Sugar Free)", "Korean glass noodles (dangmyeon)") that must survive.

  Dot-source it:  . (Join-Path $PSScriptRoot 'head-ingredients-lib.ps1')
  Self-test:      .\repair-head-ingredients.ps1 -SelfTest   (runs Invoke-HiSelfTest below first)

  DELIBERATELY NO param() BLOCK. A dot-sourced script's param block executes in the CALLER's scope, so a
  `param([switch]$SelfTest)` here silently reset the caller's own -SelfTest switch to $false and turned a
  self-test run into a live dry run. A library that is dot-sourced must declare no parameters.
#>

# The display line build-v2-spec writes and build-card2 renders verbatim into <ul class="smp-ing">:
#   <strong>Penne Pasta (Barilla):</strong> 10 cups (1050 g)
# Verified against all 6,999 lines in the catalog - every one matches.
$script:HI_DISPLAY_RE = '^<strong>(.+?):</strong>\s*(.+)$'

function Get-HiFoodDbMap {
  <# item name -> food-macros-db row. The brand source, so the strip below is the exact inverse of the
     append in build-v2-spec. #>
  param([Parameter(Mandatory)][string]$FoodDbPath)
  $m = @{}
  foreach ($i in ((Get-Content $FoodDbPath -Raw -Encoding utf8 | ConvertFrom-Json).items)) { $m[[string]$i.item] = $i }
  return $m
}

function Get-HiBrandSuffix {
  <# EXACTLY what build-v2-spec appends: ' (' + first brand before a slash + ')', and nothing at all for
     the 'fresh'/'store' brands it filters out. Returns '' when the item is unknown to the DB, which makes
     an unrecognised ingredient a no-op rather than a guess. #>
  param($FoodDbMap, [string]$CanonItem)
  if (-not $FoodDbMap -or -not $CanonItem) { return '' }
  if (-not $FoodDbMap.ContainsKey($CanonItem)) { return '' }
  $d = $FoodDbMap[$CanonItem]
  if ($d.PSObject.Properties.Name -notcontains 'brand') { return '' }
  $b = [string]$d.brand
  if (-not $b -or $b -match '^fresh$|store') { return '' }
  return (' (' + (($b -split '/')[0].Trim()) + ')')
}

function Get-HiCanonName {
  <# scaler.ing carries the machine identity in `canon` and the reader-facing name in `item`. Specs built
     before that convention have no `canon` at all, where `item` IS the canonical name. #>
  param($ScalerEntry)
  if ($null -eq $ScalerEntry) { return '' }
  if (($ScalerEntry.PSObject.Properties.Name -contains 'canon') -and $ScalerEntry.canon) { return [string]$ScalerEntry.canon }
  return [string]$ScalerEntry.item
}

function Get-HeadRecipeIngredient {
  <#
    The derivation. Returns one JSON-LD ingredient string per display line, in display order.

    Throws rather than degrading: a display line that does not parse, or a scaler list that is not
    parallel to the display list, means the spec is malformed in a way that would silently ship a WRONG
    ingredient list, which is the defect this exists to end. spec-guards already fails both conditions,
    so a throw here can only fire on a spec that was never valid.
  #>
  param(
    [Parameter(Mandatory)][AllowEmptyCollection()]$DisplayLines,
    [Parameter(Mandatory)][AllowEmptyCollection()]$ScalerIng,
    $FoodDbMap
  )
  $disp = @($DisplayLines)
  $ing = @($ScalerIng)
  if ($disp.Count -ne $ing.Count) {
    throw ("head-ingredients: ingredients_display ({0}) and scaler.ing ({1}) are not parallel" -f $disp.Count, $ing.Count)
  }
  $out = New-Object System.Collections.Generic.List[string]
  for ($k = 0; $k -lt $disp.Count; $k++) {
    $line = [string]$disp[$k]
    $m = [regex]::Match($line, $script:HI_DISPLAY_RE)
    if (-not $m.Success) { throw ("head-ingredients: display line does not parse: " + $line) }
    $name = $m.Groups[1].Value.Trim()
    $amount = $m.Groups[2].Value.Trim()
    $suffix = Get-HiBrandSuffix $FoodDbMap (Get-HiCanonName $ing[$k])
    if ($suffix -and $name.EndsWith($suffix)) { $name = $name.Substring(0, $name.Length - $suffix.Length).Trim() }
    if (-not $name -or -not $amount) { throw ("head-ingredients: empty name or amount from: " + $line) }
    $out.Add($name + ', ' + $amount)
  }
  return $out.ToArray()
}

function Invoke-HiSelfTest {
  <# Leaves the failure count in $script:hiFails for the caller to add to its own. It does NOT return the
     count: every Write-Output in a PowerShell function joins its return value, so a `return $n` here
     hands the caller an object[] of the test log with the number on the end. #>
  $script:hiFails = 0
  function Chk([string]$what, [bool]$ok, [string]$got) {
    if ($ok) { Write-Output ("  ok   " + $what) } else { $script:hiFails++; Write-Output ("  FAIL " + $what + "  got: " + $got) }
  }
  $db = @{
    '93/7 Ground Beef' = [pscustomobject]@{ brand = "Member's Mark" }
    'Penne Pasta'      = [pscustomobject]@{ brand = 'Barilla' }
    'Carrots'          = [pscustomobject]@{ brand = 'generic' }
    'Celery'           = [pscustomobject]@{ brand = 'fresh' }
    'BBQ Sauce'        = [pscustomobject]@{ brand = 'Great Value' }
    'Yellow Onion'     = [pscustomobject]@{ }
  }
  $disp = @(
    '<strong>93/7 Ground Beef (Member''s Mark):</strong> 6 lb (2450 g)'
    '<strong>Penne Pasta (Barilla):</strong> 10 cups (1050 g)'
    '<strong>Carrots (generic):</strong> 1 lb (200 g)'
    '<strong>Celery:</strong> 2 stalks, finely chopped (120 g)'
    '<strong>BBQ Sauce (Sugar Free) (Great Value):</strong> 1 1/2 cups (360 g)'
    '<strong>Yellow Onion:</strong> 3 onions (300 g)'
  )
  $ing = @(
    [pscustomobject]@{ item = '93/7 Ground Beef'; canon = '93/7 Ground Beef' }
    [pscustomobject]@{ item = 'Penne Pasta' }
    [pscustomobject]@{ item = 'Carrots'; canon = 'Carrots' }
    [pscustomobject]@{ item = 'Celery'; canon = 'Celery' }
    [pscustomobject]@{ item = 'BBQ Sauce (Sugar Free)'; canon = 'BBQ Sauce' }
    [pscustomobject]@{ item = 'Yellow Onion'; canon = 'Yellow Onion' }
  )
  $r = Get-HeadRecipeIngredient $disp $ing $db
  Write-Output 'head-ingredients-lib self-test'
  Chk 'every display line produces exactly one JSON-LD line' ($r.Count -eq 6) ([string]$r.Count)
  Chk 'brand paren dropped, cook measure and grams kept' ($r[0] -eq '93/7 Ground Beef, 6 lb (2450 g)') $r[0]
  Chk 'the goulash line: cups basis, never "3 boxs"' ($r[1] -eq 'Penne Pasta, 10 cups (1050 g)') $r[1]
  Chk '"(generic)" is a brand and goes' ($r[2] -eq 'Carrots, 1 lb (200 g)') $r[2]
  Chk 'a "fresh" brand was never appended, name untouched; tail survives' ($r[3] -eq 'Celery, 2 stalks, finely chopped (120 g)') $r[3]
  Chk 'a REAL parenthetical survives while the brand after it goes' ($r[4] -eq 'BBQ Sauce (Sugar Free), 1 1/2 cups (360 g)') $r[4]
  Chk 'item with no DB brand is passed through whole' ($r[5] -eq 'Yellow Onion, 3 onions (300 g)') $r[5]
  $threw = $false
  try { $null = Get-HeadRecipeIngredient $disp @($ing[0]) $db } catch { $threw = $true }
  Chk 'non-parallel arrays throw rather than emit a short list' $threw 'no throw'
  $threw = $false
  try { $null = Get-HeadRecipeIngredient @('Penne Pasta: 10 cups') @($ing[0]) $db } catch { $threw = $true }
  Chk 'an unparseable display line throws' $threw 'no throw'
}
