<#
  repair-unitless-buy.ps1 - give every COUNT amount the noun it was always missing.

  THE DEFECT (2026-08-04, found while building income\reels\build-reel.ps1). FriendlyAmt in
  build-v2-spec.ps1 renders a whole-item amount from densities.json's 'each' weight, and its branch
  returned the bare number while all nine of its sibling branches append a unit (' lb', ' cups',
  ' cans', ' large eggs', ' oz'):

      Potato (generic): 18.4 (3909 g)          <- reads as a typo, or a units bug
      Yellow Onion: 1.5 (163 g)
      Carrots (generic): 4.7 (285 g)

  661 lines across 339 of the 513 specs shipped that way. The number is right (3909/18.4 = 212 g, a
  medium russet; 163/1.5 = 109 g, a medium onion) - only the noun is missing, and without it the line
  is recoverable only from the gram restatement beside it.

  WHY A NOUN AND NOT A WEIGHT. Three reasons, all measured rather than assumed:
    1. The catalog already decided. Of the 6,338 lines that DO carry a unit, the same items overwhelmingly
       use the count noun: 57 of 71 Yellow Onion lines say "N onions", 17 of 20 Green Bell Peppers say
       "N peppers", 5 of 5 Zucchini say "N zucchinis".
    2. The spec's own JSON-LD already carries the noun. head.recipeIngredient - hand-written by the
       writers from the source recipe - says "6.4 potatoes", "3.5 celery stalks", "1.7 heads green
       cabbage", "7 boxes Japanese curry roux", "3 lemons worth of lemon juice". Converting the visible
       list to pounds would make the card disagree with the structured data it publishes to Google.
    3. A count is load-bearing in some recipes. bbq-pulled-pork-stuffed-sweet-potatoes uses 14 sweet
       potatoes for 14 servings - one each. "4 lb" would destroy the point of the recipe. Same for
       17.5 refrigerated biscuits and 26.4 keto buns, which have no useful weight form at all.

  WHY THE COUNTS ARE NOT ROUNDED. cook-measure-lib has a "a countable is a whole thing" rule, and it is
  right for labels it derives itself. Here it would desynchronise four fields that currently agree:
  ingredients_display, scaler.ing[].buy, cost_lines and head.recipeIngredient all state the same
  quantity today. The gram figure beside the count already carries the precision.

  WHAT THIS TOUCHES, and why all three together: the two parallel arrays must always agree (the widget
  re-renders the list from scaler.ing[].buy the moment a reader changes servings, so a display-only fix
  silently changes the list under them), and cost_lines restates the same size token.
      scaler.ing[].buy        "4.3"            -> "4.3 oranges worth"
      ingredients_display[]   "... 4.3 (387 g)" -> "... 4.3 oranges worth (387 g)"
      cost_lines[]            "Orange Juice, 4.3: ~$0.95." -> "Orange Juice, 4.3 oranges worth: ~$0.95."

  The splice itself lives in pipeline\buy-label-lib.ps1, shared with repair-range-buy.ps1 - see the
  header there for why it is not duplicated. SPEC-SCHEMA.md forbids ConvertFrom-Json | ConvertTo-Json on
  a spec, and each file's existing BOM state is preserved.

  Read-only unless -Apply.
  Usage: .\repair-unitless-buy.ps1 [-Apply]   |   .\repair-unitless-buy.ps1 -SelfTest
#>
param([switch]$Apply, [switch]$SelfTest, [string]$Root = "")
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp = if ($Root) { $Root } else { Split-Path -Parent $here }
. (Join-Path $mp 'lib\json-db-io.ps1')
. (Join-Path $here 'buy-label-lib.ps1')

function Get-EachNouns([string]$path) {
    $m = @{}
    foreach ($p in ((Get-Content $path -Raw -Encoding utf8 | ConvertFrom-Json).items.PSObject.Properties)) { $m[$p.Name] = $p.Value }
    return $m
}

function Resolve-CountNoun($nouns, [string]$item, [string]$bare) {
    <# 'one' at exactly one of the thing, 'many' otherwise - including fractions, because 1.5 onions is
       more than one onion. Returns $null when we have no noun for the item, and the caller REFUSES to
       guess rather than inventing a word for a food it does not know. #>
    if (-not $nouns.ContainsKey($item)) { return $null }
    $n = 0.0
    if (-not [double]::TryParse($bare, [ref]$n)) { return $null }
    if ([Math]::Abs($n - 1.0) -lt 1e-9) { return [string]$nouns[$item].one }
    return [string]$nouns[$item].many
}

function Repair-SpecUnitlessBuy {
    <# Returns @{ changed=<int>; text=<patched raw>; notes=@() } for ONE spec. Pure text in, text out,
       so the self-test drives exactly the same code path the catalog run does. #>
    param(
        [Parameter(Mandatory)][string]$Raw,
        [Parameter(Mandatory)]$Spec,
        [Parameter(Mandatory)]$Nouns,
        $Overrides = $null          # @{ "<item>" = "<explicit new buy>" } for hand-supplied labels
    )
    $ing  = @($Spec.scaler.ing)
    $disp = @($Spec.ingredients_display)
    if ($ing.Count -ne $disp.Count) { throw ("parallel arrays disagree: scaler.ing $($ing.Count) vs ingredients_display $($disp.Count)") }

    # Decide every edit BEFORE touching the text, so a spec is either fully patched or not at all.
    $edits = New-Object System.Collections.Generic.List[object]
    $notes = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $ing.Count; $i++) {
        $buy = [string]$ing[$i].buy
        if ($buy -match '[A-Za-z]') { continue }             # already carries a unit word - not our defect
        $item = [string]$ing[$i].item
        $new = $null
        if ($Overrides -and $Overrides.ContainsKey($item)) { $new = [string]$Overrides[$item] }
        else {
            $noun = Resolve-CountNoun $Nouns $item $buy
            if (-not $noun) { $notes.Add("no each-noun for '$item' (buy '$buy') - left alone"); continue }
            $new = ($buy.Trim() + ' ' + $noun)
        }
        $edits.Add([pscustomobject]@{ Index = $i; Item = $item; Old = $buy; New = $new; Grams = [int]$ing[$i].grams })
    }
    if ($edits.Count -eq 0) { return @{ changed = 0; text = $Raw; notes = @($notes.ToArray()); edits = @() } }

    # The splice across every surface that restates the label. head.recipeIngredient is NOT included:
    # for this defect the JSON-LD was already correct (it is where the count nouns were read FROM - see
    # reason 2 in the header), so reaching into it would be a change with no defect behind it.
    $sp = Invoke-BuyLabelSplice -Raw $Raw -Spec $Spec -Edits @($edits.ToArray())
    foreach ($n in $sp.notes) { $notes.Add($n) }

    return @{ changed = $edits.Count; text = $sp.text; notes = @($notes.ToArray()); edits = @($edits.ToArray()) }
}

function Invoke-UnitlessBuyRepair([string]$specDir, [string]$nounsPath, [bool]$apply, $overridesBySlug) {
    $nouns = Get-EachNouns $nounsPath
    $lines = 0; $recipes = 0
    $slugs = New-Object System.Collections.Generic.List[string]
    $samples = New-Object System.Collections.Generic.List[string]
    $notes = New-Object System.Collections.Generic.List[string]
    foreach ($f in @(Get-ChildItem (Join-Path $specDir '*.json') | Where-Object { $_.Name -ne '_index.json' })) {
        $io = Read-SpecText $f.FullName
        $spec = $io.Text | ConvertFrom-Json
        if (-not $spec.scaler -or -not $spec.scaler.ing) { continue }
        $ov = $null
        if ($overridesBySlug -and $overridesBySlug.ContainsKey($f.BaseName)) { $ov = $overridesBySlug[$f.BaseName] }
        $r = Repair-SpecUnitlessBuy -Raw $io.Text -Spec $spec -Nouns $nouns -Overrides $ov
        foreach ($n in $r.notes) { $notes.Add($f.BaseName + ' :: ' + $n) }
        if ($r.changed -eq 0) { continue }
        foreach ($e in $r.edits) {
            if ($samples.Count -lt 14) { $samples.Add(("{0,-30} '{1}' -> '{2}'   ({3} g)" -f $e.Item, $e.Old, $e.New, $e.Grams)) }
        }
        # POST-CONDITION on every file, before it is written: the two parallel surfaces must still agree,
        # or the reader sees the list change the moment they touch the servings control.
        Assert-BuyLabelSurfacesAgree -Text $r.text -Slug $f.BaseName
        $lines += $r.changed; $recipes++; $slugs.Add($f.BaseName)
        if ($apply) { Write-SpecText -Path $f.FullName -Text $r.text -Bom $io.Bom }
    }
    return @{ lines = $lines; recipes = $recipes; slugs = @($slugs.ToArray()); samples = @($samples.ToArray()); notes = @($notes.ToArray()) }
}

# ---------------------------------------------------------------------------------------------------
# HAND-SUPPLIED LABELS. An intake may pass its own `buy` straight through FriendlyAmt, so a unitless
# amount can also arrive from a writer rather than the generator. One did: a range copied off the source
# recipe, which is unitless AND unscalable - the widget's scaleBuy only moves the LEADING number, so
# "1-2" at double servings renders "2-2". The replacement is the count the generator itself would derive
# from the grams (45 g / 14 g per jalapeno, snapped to whole by FriendlyAmt's own +/-0.25 rule).
# ---------------------------------------------------------------------------------------------------
$OVERRIDES = @{
    'slow-cooker-pork-green-chili-bowls' = @{ 'Jalapeno' = '3 jalapenos' }
}

if ($SelfTest) {
    $fail = 0
    function Chk([string]$label, [bool]$cond, [string]$got) {
        if ($cond) { Write-Output ("ok    " + $label) } else { Write-Output ("FAIL  " + $label + "   got: " + $got); $script:fail++ }
    }
    $T = Join-Path $env:TEMP ('unitless-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path (Join-Path $T 'recipes') -Force | Out-Null
    try {
        @{ items = @{
            'Potato'       = @{ one = 'potato'; many = 'potatoes' }
            'Yellow Onion' = @{ one = 'onion';  many = 'onions' }
            'Bay Leaves'   = @{ one = 'leaf';   many = 'leaves' }
            'Lemon Juice'  = @{ one = 'lemon worth'; many = 'lemons worth' }
        } } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $T 'each-nouns.json') -Encoding UTF8

        # FROZEN FIXTURE - the founding bug verbatim off Brad's cards, plus a clean twin of each refusal.
        # Written as raw text, not ConvertTo-Json, because the point is the SPLICE: the prose below
        # carries < escapes, braces and a bracket inside string literals, which is exactly what
        # broke naive brace counting and is why lib\json-db-io.ps1 grew string-aware scanners.
        $fx = @'
{
    "slug":  "fx",
    "intro_html":  "A <strong>brace { and a bracket [ inside prose</strong>, plus a quote \" for good measure.",
    "ingredients_display": ["<strong>Potato (generic):</strong> 18.4 (3909 g)","<strong>Yellow Onion:</strong> 1 (110 g)","<strong>Bay Leaves (Great Value):</strong> 1 (1 g)","<strong>Lemon Juice (ReaLemon):</strong> 3 (141 g)","<strong>Pork Loin:</strong> 5.75 lb (2646 g)","<strong>Mystery Gourd:</strong> 2 (300 g)"],
    "cost_lines":  [
                       "Potato, 18.4: ~$4.10. <strong>Buy 9 lbs: $4.41.</strong>",
                       "Yellow Onion, 1: ~$0.28. <strong>Buy 1 lb: $1.14.</strong>",
                       "Lemon Juice, 3: ~$0.53. <strong>Buy 1 (lasts several batches).</strong>",
                       "Pork Loin, 5.75 lb: ~$12.48. <strong>Buy 6 lbs: $12.84.</strong>"
                   ],
    "scaler":  {
                   "cost":  "35.29",
                   "ing":  [
                               { "item": "Potato",       "grams": 3909, "buy": "18.4", "bid": "russet-potatoes", "gpu": "453.592" },
                               { "item": "Yellow Onion", "grams": 110,  "buy": "1",    "bid": "onions",          "gpu": "453.592" },
                               { "item": "Bay Leaves",   "grams": 1,    "buy": "1",    "bid": "bay-leaves",      "gpu": "28.350" },
                               { "item": "Lemon Juice",  "grams": 141,  "buy": "3",    "bid": "lemon-juice",     "gpu": "29.570" },
                               { "item": "Pork Loin",    "grams": 2646, "buy": "5.75 lb", "bid": "pork-loin",    "gpu": "453.592" },
                               { "item": "Mystery Gourd","grams": 300,  "buy": "2",    "bid": "mystery-gourd",   "gpu": "453.592" }
                           ]
               }
}
'@
        [System.IO.File]::WriteAllText((Join-Path $T 'recipes\fx.json'), $fx, (New-Object System.Text.UTF8Encoding($false)))

        $r = Invoke-UnitlessBuyRepair (Join-Path $T 'recipes') (Join-Path $T 'each-nouns.json') $true $null
        $io2 = Read-SpecText (Join-Path $T 'recipes\fx.json')
        $s = $io2.Text | ConvertFrom-Json
        $by = @{}; foreach ($i in @($s.scaler.ing)) { $by[[string]$i.item] = [string]$i.buy }
        $dl = @($s.ingredients_display)
        $cl = @($s.cost_lines) -join ' || '

        Chk 'MUST FIRE  a bare count gets its noun (18.4 -> 18.4 potatoes)' ($by['Potato'] -eq '18.4 potatoes') ($by['Potato'])
        Chk 'MUST FIRE  exactly one of the thing is SINGULAR (1 -> 1 onion)' ($by['Yellow Onion'] -eq '1 onion') ($by['Yellow Onion'])
        Chk 'MUST FIRE  an irregular plural comes from the map, never from +s (1 -> 1 leaf)' ($by['Bay Leaves'] -eq '1 leaf') ($by['Bay Leaves'])
        Chk 'MUST FIRE  a bottled juice counts the fruit, not the bottle (3 -> 3 lemons worth)' ($by['Lemon Juice'] -eq '3 lemons worth') ($by['Lemon Juice'])
        Chk 'CLEAN TWIN a label that already has a unit is untouched' ($by['Pork Loin'] -eq '5.75 lb') ($by['Pork Loin'])
        Chk 'CLEAN TWIN an item with no noun in the map is REFUSED, not guessed' ($by['Mystery Gourd'] -eq '2') ($by['Mystery Gourd'])
        Chk 'the display line keeps its item, brand, markup and gram count' ($dl[0] -eq '<strong>Potato (generic):</strong> 18.4 potatoes (3909 g)') ($dl[0])
        Chk 'the display line for the SINGULAR case matches too' ($dl[1] -eq '<strong>Yellow Onion:</strong> 1 onion (110 g)') ($dl[1])
        Chk 'display and buy always agree' ((@($s.scaler.ing) | Where-Object { ($dl -join '|') -notmatch [regex]::Escape([string]$_.buy) }).Count -eq 0) 'a display line disagrees with its buy'
        Chk 'parallel arrays keep their length and order' ((@($s.scaler.ing).Count -eq 6) -and (@($dl).Count -eq 6) -and ($dl[4] -match 'Pork Loin')) 'arrays moved'
        Chk 'cost_lines restate the same size token' ($cl -match 'Potato, 18\.4 potatoes: ~\$4\.10' -and $cl -match 'Yellow Onion, 1 onion: ~\$0\.28') ($cl)
        Chk 'a cost line whose ingredient was untouched is left alone' ($cl -match 'Pork Loin, 5\.75 lb: ~\$12\.48') ($cl)
        # THE SCANNER'S REASON FOR EXISTING: prose with braces, brackets and an escaped quote survives.
        Chk 'prose with { [ and an escaped quote survives byte for byte' ($s.intro_html -eq 'A <strong>brace { and a bracket [ inside prose</strong>, plus a quote " for good measure.') ($s.intro_html)
        Chk 'no BOM was added to a file that had none' ((-not $io2.Bom)) ('bom=' + $io2.Bom)

        $r2 = Invoke-UnitlessBuyRepair (Join-Path $T 'recipes') (Join-Path $T 'each-nouns.json') $true $null
        Chk 'idempotent - a second pass rewrites nothing' ($r2.lines -eq 0) ("lines=" + $r2.lines)

        # ---- the SERVING SCALER must survive the labels this repair writes -------------------------
        # scaleBuy moves only the leading quantity, so a count noun has to ride through untouched.
        . (Join-Path $here 'cook-measure-lib.ps1')
        $sc = @(
            # The widget renders kitchen fractions below 10, so a halved count reads "9 1/4 potatoes".
            # That is its behaviour for EVERY unit ("9 1/4 lb" too), not something a count noun introduces.
            @('18.4 potatoes', 0.5, '9 1/4 potatoes', 'halving a large count keeps the widget fraction style'),
            # UPDATED 2026-09-03 (queue 2026-09-03-539ff0). These two rows used to expect "2 onion" and
            # "3 leaf" and said "the widget never re-plurals" - the defect written into a self-test as
            # intended behaviour. It does re-plural now: the noun this repair writes is re-derived from
            # the scaled quantity against a closed vocabulary, and "leaf" is in it precisely because an
            # irregular plural cannot be guessed by a rule. Measured before the change: 3,340 disagreeing
            # renders across 328 labels and 564 recipes at f = 2 / 0.5 / 4 / 0.25.
            @('1 onion', 2.0, '2 onions', 'the count noun this repair writes agrees with the scaled number'),
            @('3 lemons worth', 2.0, '6 lemons worth', 'a two-word noun is not mistaken for a quantity, and "worth" behind the unit is note text the agreement never touches'),
            @('1 leaf', 3.0, '3 leaves', 'an IRREGULAR plural, which is why the vocabulary is a table of pairs and not a rule that appends an s')
        )
        $scBad = @()
        foreach ($c in $sc) {
            $got = Invoke-CmScaleBuy ([string]$c[0]) ([double]$c[1])
            if ($got -ne [string]$c[2]) { $scBad += ("'{0}' x{1} -> '{2}' want '{3}'" -f $c[0], $c[1], $got, $c[2]) }
        }
        Chk 'serving scaler: only the leading quantity moves, and the count noun agrees with it' ($scBad.Count -eq 0) ($scBad -join ' | ')

        # ---- repair-cook-measures must not undo this work ------------------------------------------
        # Its package-noun test is guilty-until-proven-innocent, so any noun we write that is ALSO a
        # package word (heads, boxes) has to prove itself against densities or it gets rewritten away.
        $dens = (Read-JsonFile (Join-Path $mp 'db\densities.json')).items
        $pkgNouns = @(
            @('Green Cabbage', '1.7 heads', 1512),
            @('Green Cabbage', '2 heads', 2016),
            @('Japanese Curry Roux', '7 boxes', 644)
        )
        $pkgBad = @()
        foreach ($c in $pkgNouns) {
            if (-not (Test-CmLabelTrue $dens ([string]$c[0]) ([string]$c[1]) ([double]$c[2]))) { $pkgBad += ("{0}: '{1}' @ {2} g" -f $c[0], $c[1], $c[2]) }
        }
        Chk 'nouns that are also PACKAGE words prove true to repair-cook-measures' ($pkgBad.Count -eq 0) ($pkgBad -join ' | ')
    } finally { Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue }
    if ($fail -eq 0) { Write-Output 'SELF-TEST PASS'; exit 0 } else { Write-Output "SELF-TEST FAIL: $fail case(s)"; exit 1 }
}

$res = Invoke-UnitlessBuyRepair (Join-Path $mp 'db\recipes') (Join-Path $mp 'db\each-nouns.json') ([bool]$Apply) $OVERRIDES
Write-Output ("unitless-buy repair: {0} line(s) across {1} recipe(s){2}" -f $res.lines, $res.recipes, $(if ($Apply) { '' } else { '  [read-only - pass -Apply]' }))
foreach ($s in $res.samples) { Write-Output ('    ' + $s) }
if ($res.notes.Count) {
    Write-Output ("  REFUSED - no noun for these, so the count was left as it is rather than guessed ({0}):" -f $res.notes.Count)
    foreach ($n in ($res.notes | Select-Object -First 12)) { Write-Output ('    ' + $n) }
}
if ($Apply -and $res.slugs.Count) {
    New-Item -ItemType Directory -Force (Join-Path $mp 'out') | Out-Null
    ($res.slugs -join "`n") | Set-Content (Join-Path $mp 'out\unitless-buy-slugs.txt') -Encoding UTF8
    Write-Output '  slug list -> out\unitless-buy-slugs.txt (rebuild + republish these cards)'
}
exit 0
