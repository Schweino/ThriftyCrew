<#
  repair-cook-measures.ps1 - replace every ingredient label that states a quantity the recipe does not use.

  See cook-measure-lib.ps1 for the WHY and the measurement. In short: the Ingredients list was printing the
  purchase label, so a recipe using 120 g of soy sauce said "1 bottle" and one using 90 g of brown sugar
  said "1 bag". The Ingredients section answers "what goes in the pot"; the cost section already answers
  "what do I buy".

  This rewrites TWO fields that must always agree, because two different surfaces read them:
    scaler.ing[].buy       the serving widget re-renders the list from this when a reader changes servings
    ingredients_display[]  the static <ul class="smp-ing"> the page ships with
  Changing one without the other means the list silently changes the moment a reader touches the servings
  control, which is a worse bug than the one being fixed.

  ONLY PROVABLY FALSE LABELS ARE TOUCHED. A package word is not automatically wrong - "1 can" is exactly how
  a recipe writes a whole 411 g can of tomatoes. The test is arithmetic: if the label's own quantity times
  that unit's known weight disagrees with the recipe's grams by more than 25%, it is a false statement.
  Labels whose unit we cannot weigh are left alone; we replace what we can prove wrong, never what we
  merely fail to understand.

  Read-only unless -Apply.
  Usage: .\repair-cook-measures.ps1 [-Apply]   |   .\repair-cook-measures.ps1 -SelfTest
#>
param([switch]$Apply, [switch]$SelfTest, [string]$Root = "")
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp = if ($Root) { $Root } else { Split-Path -Parent $here }
. (Join-Path $here 'cook-measure-lib.ps1')

function Update-DisplayLine([string]$line, [string]$newBuy, [double]$grams) {
  <# ingredients_display is "<strong>Item (Brand):</strong> BUY (N g)". Rebuild only the part after the
     colon so the item name, the brand parenthetical and the markup all survive byte for byte. #>
  $m = [regex]::Match($line, '(?s)^(.*?</strong>)\s*(.*)$')
  if (-not $m.Success) { return $null }
  return ($m.Groups[1].Value + ' ' + $newBuy + ' (' + [int]$grams + ' g)')
}

function Invoke-CookMeasureRepair([string]$specDir, [string]$densPath, [bool]$apply) {
  $dens = (Get-Content $densPath -Raw | ConvertFrom-Json).items
  $changed = 0; $lines = 0; $skippedNoDisp = New-Object System.Collections.Generic.List[string]
  $slugs = New-Object System.Collections.Generic.List[string]
  $samples = New-Object System.Collections.Generic.List[string]
  foreach ($f in @(Get-ChildItem (Join-Path $specDir '*.json') | Where-Object { $_.Name -ne '_index.json' })) {
    $spec = $null
    try { $spec = Get-Content $f.FullName -Raw | ConvertFrom-Json } catch { continue }
    if (-not $spec.scaler -or -not $spec.scaler.ing) { continue }
    $disp = @($spec.ingredients_display)
    $touched = $false
    foreach ($ing in @($spec.scaler.ing)) {
      $item = [string]$ing.item; $buy = [string]$ing.buy; $g = [double]$ing.grams
      if (Test-CmLabelTrue $dens $item $buy $g) { continue }
      $new = Get-CookMeasure $dens $item $g $buy
      if (-not $new -or $new -eq $buy) { continue }
      # find the display line for this ingredient by its item name at the head of the <strong>
      $idx = -1
      for ($i = 0; $i -lt $disp.Count; $i++) {
        $nm = [regex]::Match([string]$disp[$i], '<strong>\s*([^:(<]+?)\s*(?:\([^)]*\))?\s*:')
        if ($nm.Success -and $nm.Groups[1].Value.Trim() -eq $item) { $idx = $i; break }
      }
      if ($idx -lt 0) { $skippedNoDisp.Add(($f.BaseName + ' :: ' + $item)); continue }
      $newLine = Update-DisplayLine ([string]$disp[$idx]) $new $g
      if (-not $newLine) { $skippedNoDisp.Add(($f.BaseName + ' :: ' + $item + ' (unparseable display line)')); continue }
      if ($samples.Count -lt 12) { $samples.Add(("{0,-28} '{1}'  ->  '{2}'   ({3} g)" -f $item, $buy, $new, [int]$g)) }
      $ing.buy = $new
      $disp[$idx] = $newLine
      $lines++; $touched = $true
    }
    if ($touched) {
      $spec.ingredients_display = @($disp)
      $changed++; $slugs.Add($f.BaseName)
      if ($apply) { $spec | ConvertTo-Json -Depth 8 | Set-Content $f.FullName -Encoding UTF8 }
    }
  }
  return @{ recipes = $changed; lines = $lines; slugs = @($slugs.ToArray()); samples = @($samples.ToArray()); skipped = @($skippedNoDisp.ToArray()) }
}

if ($SelfTest) {
  $fail = 0
  function Chk([string]$label, [bool]$cond, [string]$got) {
    if ($cond) { Write-Output ("ok    " + $label) } else { Write-Output ("FAIL  " + $label + "   got: " + $got); $script:fail++ }
  }
  $T = Join-Path $env:TEMP ('cookm-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path (Join-Path $T 'recipes') -Force | Out-Null
  try {
    @{ items = @{
      'Soy Sauce' = @{ cup = 255; tbsp = 16; tsp = 5.3 }
      'Brown Sugar' = @{ cup = 213; tbsp = 13.5; tsp = 4.5 }
      'Garlic' = @{ clove = 5; tbsp = 8.5; head = 40 }
      'Diced Tomatoes' = @{ can = 411; cup = 240 }
      'Rice' = @{ cup = 185 }
      'Fat Free Cheddar' = @{}
      'Cheddar Cheese, Shredded' = @{ cup = 113 }
      'Mystery Powder' = @{}
    } } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $T 'densities.json') -Encoding UTF8

    # FROZEN FIXTURE - the exact lines off Brad's General Tso card, plus one of each refusal.
    @{
      name = 'Fixture'
      ingredients_display = @(
        '<strong>Soy Sauce (generic):</strong> 1 bottle (120 g)',
        '<strong>Brown Sugar (generic):</strong> 1 bag (90 g)',
        '<strong>Garlic:</strong> 1 bulb (8 g)',
        '<strong>Diced Tomatoes (Hunt''s):</strong> 1 can (411 g)',
        '<strong>Rice (Member''s Mark):</strong> 1 lb (900 g)',
        '<strong>Fat Free Cheddar (Kraft):</strong> 1 bag (200 g)',
        '<strong>Mystery Powder:</strong> 1 jar (50 g)',
        '<strong>Kidney Beans:</strong> 2 cans, drained (510 g)'
      )
      scaler = @{ ing = @(
        @{ item = 'Soy Sauce';   grams = 120; buy = '1 bottle' },
        @{ item = 'Brown Sugar'; grams = 90;  buy = '1 bag' },
        @{ item = 'Garlic';      grams = 8;   buy = '1 bulb' },
        @{ item = 'Diced Tomatoes'; grams = 411; buy = '1 can' },
        @{ item = 'Rice';        grams = 900; buy = '1 lb' },
        @{ item = 'Fat Free Cheddar'; grams = 200; buy = '1 bag' },
        @{ item = 'Mystery Powder'; grams = 50; buy = '1 jar' },
        @{ item = 'Kidney Beans'; grams = 510; buy = '2 cans, drained' }
      ) }
    } | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $T 'recipes\fx.json') -Encoding UTF8

    $r = Invoke-CookMeasureRepair (Join-Path $T 'recipes') (Join-Path $T 'densities.json') $true
    $s = Get-Content (Join-Path $T 'recipes\fx.json') -Raw | ConvertFrom-Json
    $by = @{}; foreach ($i in @($s.scaler.ing)) { $by[[string]$i.item] = [string]$i.buy }
    $dl = @($s.ingredients_display)

    Chk 'MUST FIRE  120 g of soy sauce is not a bottle -> 1/2 cup' ($by['Soy Sauce'] -eq '1/2 cup') ($by['Soy Sauce'])
    Chk 'MUST FIRE  90 g of brown sugar is not a bag -> a scant 1/2 cup' ($by['Brown Sugar'] -match '^(1/2|1/3) cup$') ($by['Brown Sugar'])
    Chk 'MUST FIRE  8 g of garlic is not a bulb -> 2 cloves' ($by['Garlic'] -eq '2 cloves') ($by['Garlic'])
    Chk 'CLEAN TWIN a WEIGHT label is NOT touched (two-sided defect, engine worklist)' ($by['Rice'] -eq '1 lb') ($by['Rice'])
    Chk 'CLEAN TWIN a WHOLE can really is 1 can - a package noun that PROVES it equals the grams stays' ($by['Diced Tomatoes'] -eq '1 can') ($by['Diced Tomatoes'])
    # A package noun we cannot weigh has not proven anything, so it goes - to a weight, which is always a
    # true statement about the food even when we know no household measure for it.
    Chk 'MUST FIRE  an unweighable JAR still is not a cooking measure -> a weight' ($by['Mystery Powder'] -match '^\d.*\s(oz|g|lb)$') ($by['Mystery Powder'])
    Chk 'the ALIAS carries a sibling density (fat free cheddar -> cheddar)' ($by['Fat Free Cheddar'] -match 'cups?$') ($by['Fat Free Cheddar'])
    Chk 'a cooking qualifier survives the rewrite (", drained")' ($by['Kidney Beans'] -match 'drained') ($by['Kidney Beans'])
    Chk 'the display line keeps its item, brand and gram count' (($dl[0] -eq '<strong>Soy Sauce (generic):</strong> 1/2 cup (120 g)')) ($dl[0])
    Chk 'display and buy always agree' ((@($s.scaler.ing) | Where-Object { $dl -join '|' -notmatch [regex]::Escape([string]$_.buy) }).Count -eq 0) 'a display line disagrees with its buy'
    $r2 = Invoke-CookMeasureRepair (Join-Path $T 'recipes') (Join-Path $T 'densities.json') $true
    Chk 'idempotent - a second pass rewrites nothing' ($r2.lines -eq 0) ("lines=" + $r2.lines)

    # ---- the SERVING SCALER must survive the labels this repair writes ----
    # Frozen cases for the scaleBuy rewrite. The old JS multiplied every number in the string, so a reader
    # who changed servings turned "1/2 tsp" into "2/4 tsp" - a bug this repair would have multiplied by
    # writing many more fraction labels.
    $sc = @(
      @('1/2 tsp', 2.0, '1 tsp', 'THE BUG: numerator AND denominator were both scaled'),
      @('1/4 tsp', 2.0, '1/2 tsp', 'same shape, quarter'),
      @('1/2 cup', 0.5, '1/4 cup', 'halving a fraction'),
      @('2 cloves', 2.0, '4 cloves', 'plain integer'),
      @('1 1/2 cups', 2.0, '3 cups', 'mixed number'),
      @('2 stalks, finely chopped', 2.0, '4 stalks, finely chopped', 'the cooking note survives untouched'),
      @('2 pk 12 oz', 2.0, '4 pk 12 oz', 'THE OTHER BUG: only the leading quantity moves, not the pack SIZE'),
      @('a pinch', 2.0, 'a pinch', 'no leading quantity: left exactly alone')
    )
    $scBad = @()
    foreach ($c in $sc) {
      $got = Invoke-CmScaleBuy ([string]$c[0]) ([double]$c[1])
      if ($got -ne [string]$c[2]) { $scBad += ("'{0}' x{1} -> '{2}' want '{3}'" -f $c[0], $c[1], $got, $c[2]) }
    }
    Chk 'serving scaler: fractions scale as VALUES and only the leading quantity moves' ($scBad.Count -eq 0) ($scBad -join ' | ')
  } finally { Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue }
  if ($fail -eq 0) { Write-Output 'SELF-TEST PASS'; exit 0 } else { Write-Output "SELF-TEST FAIL: $fail case(s)"; exit 1 }
}

$res = Invoke-CookMeasureRepair (Join-Path $mp 'db\recipes') (Join-Path $mp 'db\densities.json') ([bool]$Apply)
Write-Output ("cook-measure repair: {0} false label(s) across {1} recipe(s){2}" -f $res.lines, $res.recipes, $(if ($Apply) { '' } else { '  [read-only - pass -Apply]' }))
foreach ($s in $res.samples) { Write-Output ('    ' + $s) }
if ($res.skipped.Count) {
  Write-Output ("  SKIPPED - no matching display line to keep in step with ({0}); the two surfaces must always agree, so buy was left alone too:" -f $res.skipped.Count)
  foreach ($s in ($res.skipped | Select-Object -First 10)) { Write-Output ('    ' + $s) }
}
if ($Apply -and $res.slugs.Count) {
  ($res.slugs -join "`n") | Set-Content (Join-Path $mp 'out\cook-measure-slugs.txt') -Encoding UTF8
  Write-Output '  slug list -> out\cook-measure-slugs.txt (rebuild + republish these cards)'
}
exit 0

