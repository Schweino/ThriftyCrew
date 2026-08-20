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

  HOW IT WRITES (ported 2026-08-04 to lib\json-db-io.ps1's splice path). Until now this rewrote each
  touched spec with `$spec | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8`, the one thing
  db\SPEC-SCHEMA.md forbids outright. Three live hazards, none of them theoretical:
    1. -Depth 8 silently TRUNCATES anything nested deeper - no error, just a flattened value.
    2. Set-Content -Encoding UTF8 stamps a BOM on every file it writes, and the 513 specs are not uniform
       (measured 2026-08-04: 186 carry one, 327 do not). An -Apply run therefore rewrote the leading bytes
       of files whose content it had not otherwise changed.
    3. A whole-file re-serialize makes a one-token label repair unreviewable in a diff, and PS5.1
       serializers have corrupted this file class before.
  Every edit is now a targeted splice located by the string-aware scanners in lib\json-db-io.ps1 (recipe
  prose carries braces and brackets inside string literals and stores every '<' as a unicode escape, so
  naive brace counting desynchronises on the first intro paragraph). Write-SpecText parse-verifies, and
  Read-SpecText/Write-SpecText round-trip each file's existing BOM state instead of normalising it.

  Read-only unless -Apply.
  Usage: .\repair-cook-measures.ps1 [-Apply]   |   .\repair-cook-measures.ps1 -SelfTest
#>
param([switch]$Apply, [switch]$SelfTest, [string]$Root = "")
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp = if ($Root) { $Root } else { Split-Path -Parent $here }
. (Join-Path $here 'cook-measure-lib.ps1')
. (Join-Path $mp 'lib\json-db-io.ps1')

function Update-DisplayLine([string]$line, [string]$newBuy, [double]$grams) {
  <# ingredients_display is "<strong>Item (Brand):</strong> BUY (N g)". Rebuild only the part after the
     colon so the item name, the brand parenthetical and the markup all survive byte for byte. #>
  $m = [regex]::Match($line, '(?s)^(.*?</strong>)\s*(.*)$')
  if (-not $m.Success) { return $null }
  return ($m.Groups[1].Value + ' ' + $newBuy + ' (' + [int]$grams + ' g)')
}

function ConvertTo-CmJsonBody([string]$s) {
  <# The BODY of a JSON string literal (no surrounding quotes), escaped exactly the way PS 5.1's own
     serializer escapes it, which turns '<', '&' and an apostrophe into unicode escapes. The specs were
     written by that serializer and every other string in them carries those escapes, so a spliced value
     that escapes the same way stays byte-consistent with the file it lands in. #>
  $j = ConvertTo-Json -InputObject $s
  return $j.Substring(1, $j.Length - 2)
}

function ConvertFrom-CmJsonBody([string]$body) {
  <# The inverse: the VALUE a raw string-literal body decodes to, so a pre-condition compares like with
     like ("2 cans, drained" against the file's own escaping) instead of comparing an escape to a char. #>
  return [string](('"' + $body + '"') | ConvertFrom-Json)
}

function Repair-SpecCookMeasures {
  <# Returns @{ changed=<int>; text=<patched raw>; skipped=@(); edits=@() } for ONE spec. Pure text in,
     text out, so the self-test drives exactly the same code path the catalog run does. #>
  param(
    [Parameter(Mandatory)][string]$Raw,
    [Parameter(Mandatory)]$Spec,
    [Parameter(Mandatory)]$Dens
  )
  $ing = @($Spec.scaler.ing)
  $disp = @($Spec.ingredients_display)

  # Decide every edit BEFORE touching the text, so a spec is either fully patched or not at all. The two
  # surfaces are kept in step here: an ingredient whose display line cannot be found is REFUSED outright
  # rather than half-repaired, because a buy the static list does not restate is the servings-control bug.
  $edits = New-Object System.Collections.Generic.List[object]
  $skipped = New-Object System.Collections.Generic.List[string]
  for ($i = 0; $i -lt $ing.Count; $i++) {
    $item = [string]$ing[$i].item; $buy = [string]$ing[$i].buy; $g = [double]$ing[$i].grams
    if (Test-CmLabelTrue $Dens $item $buy $g) { continue }
    $new = Get-CookMeasure $Dens $item $g $buy
    if (-not $new -or $new -eq $buy) { continue }
    # find the display line for this ingredient by its item name at the head of the <strong>
    $idx = -1
    for ($j = 0; $j -lt $disp.Count; $j++) {
      $nm = [regex]::Match([string]$disp[$j], '<strong>\s*([^:(<]+?)\s*(?:\([^)]*\))?\s*:')
      if ($nm.Success -and $nm.Groups[1].Value.Trim() -eq $item) { $idx = $j; break }
    }
    if ($idx -lt 0) { $skipped.Add($item); continue }
    $newLine = Update-DisplayLine ([string]$disp[$idx]) $new $g
    if (-not $newLine) { $skipped.Add($item + ' (unparseable display line)'); continue }
    $edits.Add([pscustomobject]@{
      Index = $i; DispIndex = $idx; Item = $item; Old = $buy; New = $new; Grams = [int]$g; NewLine = $newLine
    })
  }
  if ($edits.Count -eq 0) { return @{ changed = 0; text = $Raw; skipped = @($skipped.ToArray()); edits = @() } }

  $text = $Raw

  # ---- 1. scaler.ing[i].buy ------------------------------------------------------------------------
  # Scoped: locate the scaler object, then its ing array, then the i-th element, then buy INSIDE it.
  # A bare search for "buy" would hit the first ingredient every time.
  $scalerAt = Find-JsonValueStart -Raw $text -Key 'scaler'
  if ($scalerAt -lt 0) { throw 'no "scaler" key' }
  $ingAt = Find-JsonValueStart -Raw $text -Key 'ing' -From $scalerAt
  if ($ingAt -lt 0) { throw 'no "scaler"."ing" key' }
  # The @() is load-bearing: PS 5.1 unrolls a one-element return, .Count then reads $null and the loop
  # below never runs - a repair that finds nothing, reports nothing and exits 0. See json-db-io.ps1.
  $spans = @(Get-JsonArraySpans -Raw $text -OpenIndex $ingAt)
  if ($spans.Count -ne $ing.Count) { throw ("scaler.ing span walk found $($spans.Count) elements, parser says $($ing.Count)") }
  # Apply from the LAST edit backwards so earlier spans keep their offsets.
  foreach ($e in @($edits | Sort-Object Index -Descending)) {
    $sp = $spans[$e.Index]
    $el = $text.Substring($sp.Start, $sp.End - $sp.Start + 1)
    $bAt = Find-JsonValueStart -Raw $el -Key 'buy'
    if ($bAt -lt 0) { throw ("no buy key in scaler.ing[$($e.Index)]") }
    $vs = Get-JsonStringSpan -Raw $el -OpenIndex $bAt
    $cur = ConvertFrom-CmJsonBody ($el.Substring($vs.Start, $vs.End - $vs.Start + 1))
    if ($cur -ne $e.Old) { throw ("scaler.ing[$($e.Index)] buy is '$cur', expected '$($e.Old)'") }
    $newEl = $el.Substring(0, $vs.Start) + (ConvertTo-CmJsonBody $e.New) + $el.Substring($vs.End + 1)
    $text = $text.Substring(0, $sp.Start) + $newEl + $text.Substring($sp.End + 1)
  }

  # ---- 2. ingredients_display[idx] -----------------------------------------------------------------
  # Same rebuild Update-DisplayLine performs, done as a splice: keep everything up to and including the
  # first </strong> byte for byte (item name, brand parenthetical, markup) and rewrite only the amount
  # tail after it. The marker is matched in EITHER form - a spec stores '<' as a unicode escape, a
  # hand-written file may not - and the post-condition in the caller then proves the spliced bytes decode
  # to exactly the string the old whole-file rewrite would have produced.
  $dispAt = Find-JsonValueStart -Raw $text -Key 'ingredients_display'
  if ($dispAt -lt 0) { throw 'no "ingredients_display" key' }
  $dspans = @(Get-JsonArraySpans -Raw $text -OpenIndex $dispAt)
  if ($dspans.Count -ne $disp.Count) { throw ("ingredients_display span walk found $($dspans.Count) elements, parser says $($disp.Count)") }
  foreach ($e in @($edits | Sort-Object DispIndex -Descending)) {
    $sp = $dspans[$e.DispIndex]
    $el = $text.Substring($sp.Start, $sp.End - $sp.Start + 1)
    $m = [regex]::Match($el, '(?s)^.*?(?:</strong>|\\u003[cC]/strong\\u003[eE])')
    if (-not $m.Success) { throw ("ingredients_display[$($e.DispIndex)] has no </strong> to rebuild after: $el") }
    $newEl = $el.Substring(0, $m.Length) + ' ' + (ConvertTo-CmJsonBody ($e.New + ' (' + $e.Grams + ' g)')) + '"'
    $text = $text.Substring(0, $sp.Start) + $newEl + $text.Substring($sp.End + 1)
  }

  return @{ changed = $edits.Count; text = $text; skipped = @($skipped.ToArray()); edits = @($edits.ToArray()) }
}

function Invoke-CookMeasureRepair([string]$specDir, [string]$densPath, [bool]$apply) {
  $dens = (Get-Content $densPath -Raw | ConvertFrom-Json).items
  $changed = 0; $lines = 0; $skippedNoDisp = New-Object System.Collections.Generic.List[string]
  $slugs = New-Object System.Collections.Generic.List[string]
  $samples = New-Object System.Collections.Generic.List[string]
  foreach ($f in @(Get-ChildItem (Join-Path $specDir '*.json') | Where-Object { $_.Name -ne '_index.json' })) {
    $io = $null; $spec = $null
    try { $io = Read-SpecText $f.FullName; $spec = $io.Text | ConvertFrom-Json } catch { continue }
    if (-not $spec.scaler -or -not $spec.scaler.ing) { continue }
    try { $r = Repair-SpecCookMeasures -Raw $io.Text -Spec $spec -Dens $dens }
    catch { throw ($f.BaseName + ': ' + $_.Exception.Message) }
    foreach ($s in $r.skipped) { $skippedNoDisp.Add($f.BaseName + ' :: ' + $s) }
    if ($r.changed -eq 0) { continue }
    foreach ($e in $r.edits) {
      if ($samples.Count -lt 12) { $samples.Add(("{0,-28} '{1}'  ->  '{2}'   ({3} g)" -f $e.Item, $e.Old, $e.New, $e.Grams)) }
    }
    # POST-CONDITION on every file, before it is written. Two checks, and the first is what makes a splice
    # safe to trust: each patched line must decode to EXACTLY the string the old whole-file rewrite
    # produced, so the escaping done above is proven right rather than assumed. The second is the
    # invariant the whole script exists to protect - the two surfaces still restate the same amount.
    $after = $r.text | ConvertFrom-Json
    $ad = @($after.ingredients_display); $ai = @($after.scaler.ing)
    foreach ($e in $r.edits) {
      if ([string]$ad[$e.DispIndex] -ne $e.NewLine) { throw ("$($f.BaseName): display line $($e.DispIndex) spliced to '$([string]$ad[$e.DispIndex])', expected '$($e.NewLine)'") }
      if ([string]$ai[$e.Index].buy -ne $e.New) { throw ("$($f.BaseName): scaler.ing[$($e.Index)].buy spliced to '$([string]$ai[$e.Index].buy)', expected '$($e.New)'") }
    }
    if ($ai.Count -ne $ad.Count) { throw ("$($f.BaseName): parallel arrays diverged during repair") }
    foreach ($e in $r.edits) {
      if ([string]$ad[$e.DispIndex] -notmatch [regex]::Escape($e.New)) {
        throw ("$($f.BaseName): display line $($e.DispIndex) no longer carries its buy '$($e.New)'")
      }
    }
    $lines += $r.changed; $changed++; $slugs.Add($f.BaseName)
    if ($apply) { Write-SpecText -Path $f.FullName -Text $r.text -Bom $io.Bom }
  }
  return @{ recipes = $changed; lines = $lines; slugs = @($slugs.ToArray()); samples = @($samples.ToArray()); skipped = @($skippedNoDisp.ToArray()) }
}

if ($SelfTest) {
  $fail = 0
  function Chk([string]$label, [bool]$cond, [string]$got) {
    if ($cond) { Write-Output ("ok    " + $label) } else { Write-Output ("FAIL  " + $label + "   got: " + $got); $script:fail++ }
  }
  function Test-Bom([string]$p) {
    $b = [System.IO.File]::ReadAllBytes($p)
    return ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
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
    # Written as RAW TEXT rather than ConvertTo-Json, for two reasons that are the point of this file:
    #   1. ConvertTo-Json | Set-Content -Encoding UTF8 is the write path being removed, and it stamps a
    #      BOM - a fixture built that way cannot see the BOM regression it is here to catch.
    #   2. The bytes below are what a LIVE spec looks like: every '<', '&' and apostrophe stored as a
    #      unicode escape, and prose carrying a brace, a bracket and an escaped quote inside a string
    #      literal. That is exactly what desynchronises naive brace counting, and why the splice uses
    #      the string-aware scanners in lib\json-db-io.ps1 instead.
    $fx = @'
{
    "slug":  "fx",
    "name":  "Fixture",
    "intro_html":  "A \u003cstrong\u003ebrace { and a bracket [ inside prose\u003c/strong\u003e, plus a quote \" for good measure.",
    "ingredients_display":  [
                                "\u003cstrong\u003eSoy Sauce (generic):\u003c/strong\u003e 1 bottle (120 g)",
                                "\u003cstrong\u003eBrown Sugar (generic):\u003c/strong\u003e 1 bag (90 g)",
                                "\u003cstrong\u003eGarlic:\u003c/strong\u003e 1 bulb (8 g)",
                                "\u003cstrong\u003eDiced Tomatoes (Hunt\u0027s):\u003c/strong\u003e 1 can (411 g)",
                                "\u003cstrong\u003eRice (Member\u0027s Mark):\u003c/strong\u003e 1 lb (900 g)",
                                "\u003cstrong\u003eFat Free Cheddar (Kraft):\u003c/strong\u003e 1 bag (200 g)",
                                "\u003cstrong\u003eMystery Powder:\u003c/strong\u003e 1 jar (50 g)",
                                "\u003cstrong\u003eKidney Beans:\u003c/strong\u003e 2 cans, drained (510 g)",
                                "\u003cstrong\u003eCheddar Cheese, Shredded (Sam\u0027s Choice):\u003c/strong\u003e 1 bag, Brad\u0027s mac \u0026 cheese blend (226 g)",
                                "\u003cstrong\u003eFixture Greens:\u003c/strong\u003e 2 1/4 bunches (about 18 oz) (511 g)",
                                "\u003cstrong\u003eFixture Roast:\u003c/strong\u003e 1 bag (567 g)"
                            ],
    "scaler":  {
                   "ing":  [
                               { "item": "Soy Sauce",                "grams": 120, "buy": "1 bottle" },
                               { "item": "Brown Sugar",              "grams": 90,  "buy": "1 bag" },
                               { "item": "Garlic",                   "grams": 8,   "buy": "1 bulb" },
                               { "item": "Diced Tomatoes",           "grams": 411, "buy": "1 can" },
                               { "item": "Rice",                     "grams": 900, "buy": "1 lb" },
                               { "item": "Fat Free Cheddar",         "grams": 200, "buy": "1 bag" },
                               { "item": "Mystery Powder",           "grams": 50,  "buy": "1 jar" },
                               { "item": "Kidney Beans",             "grams": 510, "buy": "2 cans, drained" },
                               { "item": "Cheddar Cheese, Shredded", "grams": 226, "buy": "1 bag, Brad\u0027s mac \u0026 cheese blend" },
                               { "item": "Fixture Greens",           "grams": 511, "buy": "2 1/4 bunches (about 18 oz)" },
                               { "item": "Fixture Roast",            "grams": 567, "buy": "1 bag" }
                           ]
               }
}
'@
    # A ONE-INGREDIENT spec, in both BOM states. Two regressions in one pair of files:
    #   the @() at the Get-JsonArraySpans call site (a one-element array unrolls in PS 5.1, .Count reads
    #   $null and the splice loop never runs - a repair that silently does nothing), and the BOM, which
    #   the removed Set-Content -Encoding UTF8 added to every file it touched.
    $fx1 = @'
{
    "slug":  "fx-one",
    "ingredients_display":  ["\u003cstrong\u003eSoy Sauce (generic):\u003c/strong\u003e 1 bottle (120 g)"],
    "scaler":  { "ing":  [ { "item": "Soy Sauce", "grams": 120, "buy": "1 bottle" } ] }
}
'@
    [System.IO.File]::WriteAllText((Join-Path $T 'recipes\fx.json'), $fx, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText((Join-Path $T 'recipes\fx-one.json'), $fx1, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText((Join-Path $T 'recipes\fx-bom.json'), ($fx1 -replace '"fx-one"', '"fx-bom"'), (New-Object System.Text.UTF8Encoding($true)))

    $r = Invoke-CookMeasureRepair (Join-Path $T 'recipes') (Join-Path $T 'densities.json') $true
    $io2 = Read-SpecText (Join-Path $T 'recipes\fx.json')
    $s = $io2.Text | ConvertFrom-Json
    $rawAfter = $io2.Text
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
    # THE BROCCOLINI FOUNDING CASE (2026-08-20), both defects in one string. 511 g labelled
    # "2 1/4 bunches (about 18 oz)" used to repair to "1 1/4 lb (about 18 oz)": the hard >=340 g
    # threshold picked lb, the kitchen-fraction snap made that 567 g (11% over the grams the macros
    # and cost were computed from), and the quantity-restating parenthetical rode along as a "tail" -
    # so the shipped line stated three amounts and two were wrong. The repair must state ONE amount,
    # in the unit that survives friendly formatting, and drop a tail that restates the quantity.
    Chk 'MUST FIRE  511 g labelled in bunches repairs to the ACCURATE unit, restating tail dropped' ($by['Fixture Greens'] -eq '18 oz') ($by['Fixture Greens'])
    Chk 'CLEAN TWIN the friendly fraction survives when it IS accurate (567 g -> 1 1/4 lb)' ($by['Fixture Roast'] -eq '1 1/4 lb') ($by['Fixture Roast'])
    Chk 'the display line keeps its item, brand and gram count' (($dl[0] -eq '<strong>Soy Sauce (generic):</strong> 1/2 cup (120 g)')) ($dl[0])
    Chk 'display and buy always agree' ((@($s.scaler.ing) | Where-Object { $dl -join '|' -notmatch [regex]::Escape([string]$_.buy) }).Count -eq 0) 'a display line disagrees with its buy'
    $r2 = Invoke-CookMeasureRepair (Join-Path $T 'recipes') (Join-Path $T 'densities.json') $true
    Chk 'idempotent - a second pass rewrites nothing' ($r2.lines -eq 0) ("lines=" + $r2.lines)

    # ---- the SPLICE, which is what changed on 2026-08-04 ---------------------------------------------
    # The old write path re-serialized the whole file. These pin what a targeted splice must preserve.
    Chk 'NO BOM IS ADDED to a spec that had none (the regression the old Set-Content -Encoding UTF8 shipped)' (-not $io2.Bom) ('bom=' + $io2.Bom)
    Chk 'a spec that HAD a BOM keeps it (round-trip, not normalise)' (Test-Bom (Join-Path $T 'recipes\fx-bom.json')) 'the BOM was stripped'
    $one = (Read-SpecText (Join-Path $T 'recipes\fx-one.json')).Text | ConvertFrom-Json
    $bom1 = (Read-SpecText (Join-Path $T 'recipes\fx-bom.json')).Text | ConvertFrom-Json
    Chk 'a ONE-INGREDIENT spec is repaired (@(Get-JsonArraySpans) - unrolled, .Count reads $null and the loop never runs)' ([string]@($one.scaler.ing)[0].buy -eq '1/2 cup') ([string]@($one.scaler.ing)[0].buy)
    Chk 'the one-ingredient display line was spliced too, not just the buy' (@($one.ingredients_display)[0] -eq '<strong>Soy Sauce (generic):</strong> 1/2 cup (120 g)') (@($one.ingredients_display)[0])
    Chk 'the BOM twin was repaired as well (a BOM is not an excuse to skip the file)' ([string]@($bom1.scaler.ing)[0].buy -eq '1/2 cup') ([string]@($bom1.scaler.ing)[0].buy)
    # THE SCANNER'S REASON FOR EXISTING: prose with braces, brackets and an escaped quote survives.
    Chk 'prose with { [ and an escaped quote survives byte for byte' ($s.intro_html -eq 'A <strong>brace { and a bracket [ inside prose</strong>, plus a quote " for good measure.') ($s.intro_html)
    Chk 'an UNEDITED line is not re-serialized - it keeps its own unicode escapes byte for byte' ($rawAfter -match 'Member\\u0027s Mark') 'an untouched line was rewritten'
    # What the splice WRITES has to be escaped the way the rest of the file is, or a label repair also
    # swaps every escape on that line for a raw character and the diff stops being about the label.
    Chk 'a rewritten label re-escapes what it writes in the same style as the rest of the file' (($by['Cheddar Cheese, Shredded'] -eq "2 cups, Brad's mac & cheese blend") -and ($rawAfter -match '2 cups, Brad\\u0027s mac \\u0026 cheese blend') -and ($rawAfter -notmatch "Brad's mac & cheese")) ($by['Cheddar Cheese, Shredded'])
    Chk 'every file still parses and every spec still has all 11 / 1 / 1 ingredients' ((@($s.scaler.ing).Count -eq 11) -and (@($dl).Count -eq 11) -and (@($one.scaler.ing).Count -eq 1)) 'an array changed length'

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
  New-Item -ItemType Directory -Force (Join-Path $mp 'out') | Out-Null
  ($res.slugs -join "`n") | Set-Content (Join-Path $mp 'out\cook-measure-slugs.txt') -Encoding UTF8
  Write-Output '  slug list -> out\cook-measure-slugs.txt'
}
if ($res.lines -gt 0) {
  # THE GAP THIS CLOSES (found 2026-08-04, two days after the fact). The 2026-08-02 run repaired 462
  # labels in the specs and printed the slug list above, and that read like the whole job. It was not.
  # recipes-db.json keeps its OWN copy of every ingredient's buy string, gen-planner-data.ps1 is built
  # from THAT copy, and so the Meal Plan Builder's merged grocery list went on telling members to buy
  # "2 cans" of the beans this script had just proved were 5 1/4 cups. Nothing flagged it for two days:
  # engine\audit-db-agreement.ps1 compares slug and protein, not labels.
  #
  # The specs are where a label is AUTHORED. They are not the only place it is STORED, and a repair that
  # stops at the author's copy has fixed only the half of the estate that reads from it. So the steps are
  # printed by the repair itself rather than left in a runbook: a step you have to remember is a step
  # that gets skipped the one time it matters.
  Write-Output ''
  Write-Output '  NEXT - a label repair is NOT finished at the specs. Three surfaces store these labels:'
  Write-Output '    1. .\pipeline\sync-recipesdb-buy.ps1 -Apply   carry them into recipes-db.json (cook-measure class)'
  Write-Output '    2. .\gen-planner-data.ps1                     rebuild the Meal Plan Builder feed off that db'
  Write-Output '    3. rebuild + republish the cards for the slugs above (those read the specs directly)'
  if (-not $Apply) { Write-Output '       (read-only run - nothing was written, so there is nothing to carry yet)' }
}
exit 0
