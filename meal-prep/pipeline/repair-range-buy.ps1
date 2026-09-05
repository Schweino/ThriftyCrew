<#
  repair-range-buy.ps1 - resolve an ingredient label that states a RANGE to the single quantity the
  recipe actually uses.

  THE DEFECT (2026-08-04, found alongside the unitless-buy repair). Ten labels across the 513 specs
  state a range where the quantity belongs:

      ground-turkey-stir-fry-bowls                Garlic             "2-3 cloves, minced"
      slow-cooker-chicken-tikka-masala-rice-bowls Tomato Paste       "1-2 tbsp"
      slow-cooker-mongolian-chicken-bowls         Sriracha           "1-2 tsp"
      swedish-meatball-potato-bowls               Vegetable Oil      "1-2 tbsp (meatballs)"
      ... and six more

  A recipe label is "<quantity> <unit> <note>" and the serving widget's scaleBuy() moves the quantity
  and nothing else - deliberately, because the version that multiplied every number in the string turned
  "1/2 tsp" into "2/4 tsp". A range breaks that premise: the second number is part of the quantity but
  sits where the unit should be, so doubling the servings renders "4-3 cloves" and "2-2 tbsp".

  WHY THE FIX IS TO RESOLVE THE RANGE AND NOT TO TEACH THE WIDGET TO SCALE BOTH ENDS. Scaling both ends
  was the obvious repair and it is the wrong one, because the range is not a live "to taste" latitude -
  it is UNSCALED SOURCE TEXT. Measured on all ten, against db\densities.json:

      slug                       label            grams   the grams state
      ground-turkey-stir-fry     2-3 cloves        42 g   8.4 cloves      (2.8x the label)
      turkey-sloppy-joe          1/2-1 tsp         12 g   2 tsp           (2x)
      slow-cooker-mongolian      1-2 tsp           25 g   5 tsp           (2.5x)
      slow-cooker-kung-pao       1/4-1/2 tsp        3 g   1 2/3 tsp       (3.3x)
      ... nine of the ten state a quantity the recipe does not use, every one of them LOW

  The reason they are low is recorded, independently, in the 2026-08-02 source-fidelity sweep, which read
  each source page and wrote down what it said: "source sauce includes 1-2 tsp Sriracha", "source sauce
  includes 1/4-1/2 tsp dried chili flakes", "cayenne is part of the source's dry rub". The range is the
  SOURCE recipe's own quantity at the SOURCE's serving count; the grams are Brad's 14-serving batch. The
  writer copied one and scaled the other. Multiply each range by the batch factor and it lands on the
  grams every time.

  So teaching scaleBuy() to scale both ends would faithfully re-render a quantity that has been wrong on
  the live card since the day it shipped - "2-3 cloves" becoming a well-maintained-looking "4-6 cloves"
  while the recipe uses, and the reader is charged for, 16.8. That is a confident number nobody measured,
  the same shape as a builder stamping today's date on a stale price. It would also have cost a widget
  change on all 513 cards to ship it. Resolving the label finishes the conversion the writer left half
  done, touches ten cards, and leaves the widget's one-number premise intact and true.

  WHY THIS IS NOT THE MEASURE-VS-GRAMS LAUNDERING cook-measure-lib refuses. That refusal is right and
  still stands: when "1 tbsp" of olive oil carries 42 g, either side could be the error, and rewriting
  the label to agree with a gram figure that might itself be wrong would launder a data bug. Here the
  grams are corroborated from outside the spec - the range times the source's serving count IS the gram
  figure - so this is not a coin flip between two numbers. Only labels stating a range are in scope, and
  the repair REFUSES rather than guesses whenever it cannot weigh the unit the writer named.

  WHAT IT WRITES. The writer's own unit is kept and only the quantity moves; the unit was never the bug,
  and "1/3 tbsp" in place of a correct "1 tsp" would be a readability regression dressed up as a fix.
  Countables round to whole things (cook-measure-lib's rule: nobody minces 8 1/3 cloves). Notes after the
  unit survive - ", minced" and "(meatballs)" are the writer's instructions, not part of the quantity.

  Read-only unless -Apply.
  Usage: .\repair-range-buy.ps1 [-Apply]   |   .\repair-range-buy.ps1 -SelfTest
#>
param([switch]$Apply, [switch]$SelfTest, [string]$Root = "")
$ErrorActionPreference = 'Stop'
$__jioRoot = $PSScriptRoot; while ($__jioRoot -and -not (Test-Path (Join-Path $__jioRoot 'lib\json-io.ps1'))) { $__jioRoot = Split-Path $__jioRoot -Parent }
if (-not $__jioRoot) { throw 'json-io.ps1 not found walking up from ' + $PSScriptRoot + " - Read-JsonFile is unavailable and a bare Get-Content would decode a BOM-less file as cp1252" }
. (Join-Path $__jioRoot 'lib\json-io.ps1')   # walk UP to find it: this file is two levels below the repo root, and a fixed -Parent hop assumed one
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp = if ($Root) { $Root } else { Split-Path -Parent $here }
. (Join-Path $mp 'lib\json-db-io.ps1')
. (Join-Path $here 'buy-label-lib.ps1')
. (Join-Path $here 'cook-measure-lib.ps1')

# Test-RangeBuy and Resolve-RangeBuy live in cook-measure-lib.ps1, dot-sourced above. They are there
# rather than here because sync-recipesdb-buy.ps1 needs the same predicate to decide whether a
# recipes-db label is in this class, and a script that runs a catalog pass at the bottom cannot be
# dot-sourced for its functions. One matcher, both scripts read it.
#
# A NOTE ON A NEIGHBOURING DEFECT found while writing the plural rule here, NOT repaired by this pass:
# FriendlyAmt in build-v2-spec.ps1 appends a hardcoded ' cups' with no singular branch (lines 183 and
# 201), and Frac() rounds anything from 0.875 up to "1", so 91 live labels read "1 cups" - "Soy Sauce:
# 1 cups (224 g)". Different generator, different cards, and repair-cook-measures cannot reach them
# because "cups" is not a package noun. Brad's call whether 91 cards are worth a republish.

function Repair-SpecRangeBuy {
    <# Returns @{ changed=<int>; text=<patched raw>; notes=@(); edits=@() } for ONE spec.
       Pure text in, text out, so the self-test drives exactly the code path the catalog run does. #>
    param(
        [Parameter(Mandatory)][string]$Raw,
        [Parameter(Mandatory)]$Spec,
        $Dens = $null,
        $Overrides = $null          # @{ "<item>" = "<explicit new buy>" } for hand-adjudicated labels
    )
    $ing  = @($Spec.scaler.ing)
    $disp = @($Spec.ingredients_display)
    if ($ing.Count -ne $disp.Count) { throw ("parallel arrays disagree: scaler.ing $($ing.Count) vs ingredients_display $($disp.Count)") }

    # Decide every edit BEFORE touching the text, so a spec is either fully patched or not at all.
    $edits = New-Object System.Collections.Generic.List[object]
    $notes = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $ing.Count; $i++) {
        $buy = [string]$ing[$i].buy
        if (-not (Test-RangeBuy -Buy $buy)) { continue }
        $item = [string]$ing[$i].item
        $g = if ($ing[$i].PSObject.Properties.Name -contains 'grams' -and $ing[$i].grams) { [double]$ing[$i].grams } else { 0 }
        $new = $null
        if ($Overrides -and $Overrides.ContainsKey($item)) { $new = [string]$Overrides[$item] }
        else {
            $r = Resolve-RangeBuy -Buy $buy -Item $item -Grams $g -Dens $Dens
            if (-not $r.New) { $notes.Add("'$item' buy '$buy': $($r.Reason) - left alone"); continue }
            $new = $r.New
        }
        if ($new -eq $buy) { continue }
        $edits.Add([pscustomobject]@{ Index = $i; Item = $item; Old = $buy; New = $new; Grams = [int]$g })
    }
    if ($edits.Count -eq 0) { return @{ changed = 0; text = $Raw; notes = @($notes.ToArray()); edits = @() } }

    # -IncludeHead, unlike the unitless repair: these labels DID reach the JSON-LD. slow-cooker-jerk-pork
    # ships "1/2-1 cup low-sodium vegetable or chicken broth Chicken Broth" to Google today.
    $sp = Invoke-BuyLabelSplice -Raw $Raw -Spec $Spec -Edits @($edits.ToArray()) -IncludeHead
    foreach ($n in $sp.notes) { $notes.Add($n) }

    return @{ changed = $edits.Count; text = $sp.text; notes = @($notes.ToArray()); edits = @($edits.ToArray()) }
}

function Invoke-RangeBuyRepair {
    param([string]$specDir, $dens, [bool]$apply, $overridesBySlug)
    $lines = 0; $recipes = 0
    $slugs = New-Object System.Collections.Generic.List[string]
    $samples = New-Object System.Collections.Generic.List[string]
    $notes = New-Object System.Collections.Generic.List[string]
    $carry = New-Object System.Collections.Generic.List[object]
    foreach ($f in @(Get-ChildItem (Join-Path $specDir '*.json') | Where-Object { $_.Name -ne '_index.json' })) {
        $io = Read-SpecText $f.FullName
        $spec = $io.Text | ConvertFrom-Json
        if (-not $spec.scaler -or -not $spec.scaler.ing) { continue }
        $ov = $null
        if ($overridesBySlug -and $overridesBySlug.ContainsKey($f.BaseName)) { $ov = $overridesBySlug[$f.BaseName] }
        $r = Repair-SpecRangeBuy -Raw $io.Text -Spec $spec -Dens $dens -Overrides $ov
        foreach ($n in $r.notes) { $notes.Add($f.BaseName + ' :: ' + $n) }
        if ($r.changed -eq 0) { continue }
        foreach ($e in $r.edits) {
            $samples.Add(("{0,-44} {1,-18} '{2}' -> '{3}'   ({4} g)" -f $f.BaseName, $e.Item, $e.Old, $e.New, $e.Grams))
            # THE CARRY MANIFEST, in the shape repair-scaled-notes.ps1 established. sync-recipesdb-buy
            # will only move a label into recipes-db if this run claims that exact row, both sides byte
            # for byte, so the sync can finish a repair that actually ran and can never ratify a hand
            # edit. It is also what lets the two hand-adjudicated OVERRIDES below carry: they are not
            # what Resolve-RangeBuy writes, so no arithmetic test could clear them, but they ARE what
            # this run wrote and the manifest is the evidence of that.
            $carry.Add([pscustomobject]@{ slug = $f.BaseName; item = [string]$e.Item; old = [string]$e.Old; new = [string]$e.New })
        }
        Assert-BuyLabelSurfacesAgree -Text $r.text -Slug $f.BaseName
        $lines += $r.changed; $recipes++; $slugs.Add($f.BaseName)
        if ($apply) { Write-SpecText -Path $f.FullName -Text $r.text -Bom $io.Bom }
    }
    return @{ lines = $lines; recipes = $recipes; slugs = @($slugs.ToArray()); samples = @($samples.ToArray()); notes = @($notes.ToArray()); carry = @($carry.ToArray()) }
}

# ---------------------------------------------------------------------------------------------------
# HAND-ADJUDICATED LABELS. Two of the ten cannot be resolved mechanically and must not be guessed, so
# they are decided here in the open with the arithmetic that decided them.
#
#   thai-turkey-larb-bowls / Jalapeno - "3-4 dry chiles or 1.5 Tbsp chile powder" against 35 g. The unit
#     is unweighable because the label names a DIFFERENT FOOD than the line it sits on: the costed
#     ingredient is fresh Jalapeno and the step says "stir in the chopped jalapeno", but the text is the
#     source's dried-chile instruction, kept when the mapper substituted fresh. 35 g at densities.json's
#     14 g per jalapeno is 2.5. Left as an exact half rather than rounded: the countable rule exists so
#     nobody is asked to mince 1 2/3 cloves, and half a jalapeno is an ordinary thing to chop, whereas
#     rounding would restate a 20% error on the one line whose entire job is how hot the dish is.
#
#   slow-cooker-jerk-pork-bowls / Chicken Broth - "1/2-1 cup low-sodium vegetable or chicken broth"
#     against 240 g, which is exactly 1 cup. The mechanical path would keep the note and print "1 cup
#     low-sodium vegetable or chicken broth" on a line already labelled Chicken Broth (Swanson) - the
#     note restates the ingredient, and offers a vegetable broth the costed line is not pricing. The
#     tail goes with the range. This is also the one spec whose head.recipeIngredient carries the whole
#     string, so the JSON-LD line becomes "1 cup Chicken Broth".
# ---------------------------------------------------------------------------------------------------
$OVERRIDES = @{
    'thai-turkey-larb-bowls'      = @{ 'Jalapeno'      = '2 1/2 jalapenos' }
    'slow-cooker-jerk-pork-bowls' = @{ 'Chicken Broth' = '1 cup' }
}

if ($SelfTest) {
    $fail = 0
    function Chk([string]$label, [bool]$cond, [string]$got) {
        if ($cond) { Write-Output ("ok    " + $label) } else { Write-Output ("FAIL  " + $label + "   got: " + $got); $script:fail++ }
    }
    $T = Join-Path $env:TEMP ('rangebuy-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path (Join-Path $T 'recipes') -Force | Out-Null
    try {
        # Densities in the same shape as db\densities.json, holding only what the fixture weighs.
        $densFx = (@{ items = @{
            'Garlic'            = @{ clove = 5; tbsp = 8.5; tsp = 2.8; each = 5; head = 40; cup = 136 }
            'Salt'              = @{ tsp = 6; tbsp = 18; pinch = 0.4 }
            'Vegetable Oil'     = @{ cup = 218; tbsp = 14; tsp = 4.5 }
            'Cayenne Pepper'    = @{ tsp = 1.8; tbsp = 5.4 }
            'Chicken Broth'     = @{ cup = 240; can = 411; floz = 29.6; carton = 946; each = 240 }
            'Jalapeno'          = @{ each = 14; tbsp = 9 }
        } } | ConvertTo-Json -Depth 6 | ConvertFrom-Json).items

        # FROZEN FIXTURE - the founding bug verbatim off Brad's live cards on 2026-08-04, plus a clean
        # twin of every way a label can look like this defect and not be it. Written as raw text, not
        # ConvertTo-Json, because the point is the SPLICE: the prose below carries < escapes, braces
        # and a bracket inside string literals, which is what broke naive brace counting.
        $fx = @'
{
    "slug":  "fx",
    "intro_html":  "A <strong>brace { and a bracket [ inside prose</strong>, plus a quote \" for good measure.",
    "ingredients_display": ["<strong>Garlic:</strong> 2-3 cloves, minced (42 g)","<strong>Salt (Morton):</strong> 1/4-1/2 tsp (6 g)","<strong>Vegetable Oil (Great Value):</strong> 1-2 tbsp (meatballs) (40 g)","<strong>Cayenne Pepper:</strong> 1/4-1/2 teaspoon (2 g)","<strong>Chicken Broth (Swanson):</strong> 1/2-1 cup low-sodium vegetable or chicken broth (240 g)","<strong>Jalapeno:</strong> 3-4 dry chiles or 1.5 Tbsp chile powder (35 g)","<strong>Pork Loin:</strong> 5.75 lb (2646 g)","<strong>Tortillas:</strong> 12-oz bag (340 g)","<strong>Mystery Gourd:</strong> 1-2 cups (300 g)"],
    "cost_lines":  [
                       "Garlic, 2-3 cloves, minced: ~$0.84. <strong>Buy 1 head: $0.68.</strong>",
                       "Salt, 1/4-1/2 tsp: ~$0.01. <strong>Buy 1 box: $0.98.</strong>",
                       "Chicken Broth, 1/2-1 cup low-sodium vegetable or chicken broth: ~$0.42. <strong>Buy 1 carton: $1.64.</strong>",
                       "Pork Loin, 5.75 lb: ~$12.48. <strong>Buy 6 lbs: $12.84.</strong>"
                   ],
    "scaler":  {
                   "cost":  "35.29",
                   "ing":  [
                               { "item": "Garlic",         "grams": 42,   "buy": "2-3 cloves, minced", "bid": "garlic",       "gpu": "28.350" },
                               { "item": "Salt",           "grams": 6,    "buy": "1/4-1/2 tsp",        "bid": "salt",         "gpu": "737.000" },
                               { "item": "Vegetable Oil",  "grams": 40,   "buy": "1-2 tbsp (meatballs)","bid": "vegetable-oil","gpu": "1330.00" },
                               { "item": "Cayenne Pepper", "grams": 2,    "buy": "1/4-1/2 teaspoon",   "bid": "cayenne",      "gpu": "28.350" },
                               { "item": "Chicken Broth",  "grams": 240,  "buy": "1/2-1 cup low-sodium vegetable or chicken broth", "bid": "chicken-broth", "gpu": "946.000" },
                               { "item": "Jalapeno",       "grams": 35,   "buy": "3-4 dry chiles or 1.5 Tbsp chile powder", "bid": "jalapenos", "gpu": "453.592" },
                               { "item": "Pork Loin",      "grams": 2646, "buy": "5.75 lb",            "bid": "pork-loin",    "gpu": "453.592" },
                               { "item": "Tortillas",      "grams": 340,  "buy": "12-oz bag",          "bid": "tortillas",    "gpu": "453.592" },
                               { "item": "Mystery Gourd",  "grams": 300,  "buy": "1-2 cups",           "bid": "mystery-gourd","gpu": "453.592" }
                           ]
               },
    "head":  {
                 "description":  "A bowl.",
                 "recipeIngredient":  ["2-3 cloves, minced Garlic","1/2-1 cup low-sodium vegetable or chicken broth Chicken Broth","5.75 lb Pork Loin"],
                 "steps":  ["Cook it."]
             }
}
'@
        [System.IO.File]::WriteAllText((Join-Path $T 'recipes\fx.json'), $fx, (New-Object System.Text.UTF8Encoding($false)))

        $ovFx = @{ 'fx' = @{ 'Jalapeno' = '2 1/2 jalapenos'; 'Chicken Broth' = '1 cup' } }
        $r = Invoke-RangeBuyRepair (Join-Path $T 'recipes') $densFx $true $ovFx
        $io2 = Read-SpecText (Join-Path $T 'recipes\fx.json')
        $s = $io2.Text | ConvertFrom-Json
        $by = @{}; foreach ($i in @($s.scaler.ing)) { $by[[string]$i.item] = [string]$i.buy }
        $dl = @($s.ingredients_display)
        $cl = @($s.cost_lines) -join ' || '
        $hd = @($s.head.recipeIngredient)
        $nt = ($r.notes -join ' || ')

        # ---- MUST FIRE: the founding bug and one of each rendering shape -----------------------------
        Chk 'MUST FIRE  the founding bug: 42 g of garlic is 8 cloves, not "2-3" (and countables stay whole)' ($by['Garlic'] -eq '8 cloves, minced') ($by['Garlic'])
        Chk 'MUST FIRE  the writers unit is KEPT, not re-picked (6 g of salt is 1 tsp, never 1/3 tbsp)' ($by['Salt'] -eq '1 tsp') ($by['Salt'])
        Chk 'MUST FIRE  a note after the unit survives the rewrite (40 g oil -> 2 3/4 tbsp (meatballs))' ($by['Vegetable Oil'] -eq '2 3/4 tbsp (meatballs)') ($by['Vegetable Oil'])
        Chk 'MUST FIRE  a spelled-out unit resolves through its abbreviation (2 g cayenne -> 1 teaspoon)' ($by['Cayenne Pepper'] -eq '1 teaspoon') ($by['Cayenne Pepper'])
        Chk 'MUST FIRE  an OVERRIDE drops a note that merely restates the ingredient (broth -> 1 cup)' ($by['Chicken Broth'] -eq '1 cup') ($by['Chicken Broth'])
        Chk 'MUST FIRE  an OVERRIDE reaches a label the mechanical path refused (jalapeno)' ($by['Jalapeno'] -eq '2 1/2 jalapenos') ($by['Jalapeno'])

        # ---- CLEAN TWINS: every way to look like this defect without being it ------------------------
        Chk 'CLEAN TWIN a label with no range is untouched (5.75 lb)' ($by['Pork Loin'] -eq '5.75 lb') ($by['Pork Loin'])
        Chk 'CLEAN TWIN a hyphen that is not a range is untouched ("12-oz bag" - no number after the dash)' ($by['Tortillas'] -eq '12-oz bag') ($by['Tortillas'])
        Chk 'CLEAN TWIN a range whose unit cannot be weighed is REFUSED, not guessed (Mystery Gourd)' (($by['Mystery Gourd'] -eq '1-2 cups') -and ($nt -match 'refusing to guess')) ($by['Mystery Gourd'] + ' / ' + $nt)

        # ---- every surface moved together ------------------------------------------------------------
        Chk 'the display line keeps its item, brand and gram count' ($dl[0] -eq '<strong>Garlic:</strong> 8 cloves, minced (42 g)') ($dl[0])
        Chk 'the display line for the OVERRIDE case matches too' ($dl[4] -eq '<strong>Chicken Broth (Swanson):</strong> 1 cup (240 g)') ($dl[4])
        Chk 'a REFUSED line is left alone on the display surface as well' ($dl[8] -eq '<strong>Mystery Gourd:</strong> 1-2 cups (300 g)') ($dl[8])
        Chk 'display and buy always agree' ((@($s.scaler.ing) | Where-Object { ($dl -join '|') -notmatch [regex]::Escape([string]$_.buy) }).Count -eq 0) 'a display line disagrees with its buy'
        Chk 'parallel arrays keep their length and order' ((@($s.scaler.ing).Count -eq 9) -and (@($dl).Count -eq 9) -and ($dl[6] -match 'Pork Loin')) 'arrays moved'
        Chk 'cost_lines restate the same size token' (($cl -match 'Garlic, 8 cloves, minced: ~\$0\.84') -and ($cl -match 'Salt, 1 tsp: ~\$0\.01')) ($cl)
        Chk 'a cost line whose ingredient was untouched is left alone' ($cl -match 'Pork Loin, 5\.75 lb: ~\$12\.48') ($cl)
        # THE FOURTH SURFACE. This is the one the unitless repair does not touch, and the jerk-pork spec
        # really does ship the whole range string to Google today.
        Chk 'MUST FIRE  head.recipeIngredient is patched too (the JSON-LD Google reads)' ($hd[0] -eq '8 cloves, minced Garlic') ($hd[0])
        Chk 'MUST FIRE  the head line carrying the whole redundant string is fixed (-> "1 cup Chicken Broth")' ($hd[1] -eq '1 cup Chicken Broth') ($hd[1])
        Chk 'CLEAN TWIN a head line for an untouched ingredient is left alone' ($hd[2] -eq '5.75 lb Pork Loin') ($hd[2])

        Chk 'prose with { [ and an escaped quote survives byte for byte' ($s.intro_html -eq 'A <strong>brace { and a bracket [ inside prose</strong>, plus a quote " for good measure.') ($s.intro_html)
        Chk 'no BOM was added to a file that had none' ((-not $io2.Bom)) ('bom=' + $io2.Bom)
        Chk 'exactly six labels were repaired, three left alone' ($r.lines -eq 6) ('lines=' + $r.lines)

        $r2 = Invoke-RangeBuyRepair (Join-Path $T 'recipes') $densFx $true $ovFx
        Chk 'idempotent - a second pass rewrites nothing' ($r2.lines -eq 0) ("lines=" + $r2.lines)

        # ---- THE POINT OF THE WHOLE REPAIR: these labels now survive the serving scaler --------------
        # The first row is the founding evidence, kept as a live assertion rather than a comment: this is
        # what the widget renders for a range, and it is why resolving the range beats scaling both ends.
        $before = Invoke-CmScaleBuy '2-3 cloves, minced' 2.0
        Chk 'the OLD label really did render nonsense at 2x ("2-3 cloves" -> "4-3 cloves")' ($before -eq '4-3 cloves, minced') ($before)
        $sc = @(
            @('8 cloves, minced', 2.0, '16 cloves, minced', 'the repaired garlic label doubles cleanly'),
            @('1 tsp', 3.0, '3 tsp', 'a whole-number tsp scales'),
            @('2 3/4 tbsp (meatballs)', 2.0, '5 1/2 tbsp (meatballs)', 'a fraction scales and the note rides through'),
            @('1 cup', 0.5, '1/2 cup', 'halving reaches a kitchen fraction, not 0.5'),
            @('2 1/2 jalapenos', 2.0, '5 jalapenos', 'the hand-adjudicated half doubles to a whole')
        )
        $scBad = @()
        foreach ($c in $sc) {
            $got = Invoke-CmScaleBuy ([string]$c[0]) ([double]$c[1])
            if ($got -ne [string]$c[2]) { $scBad += ("'{0}' x{1} -> '{2}' want '{3}'" -f $c[0], $c[1], $got, $c[2]) }
        }
        Chk 'every repaired label scales to exactly one moving number' ($scBad.Count -eq 0) ($scBad -join ' | ')

        # ---- and the repair must not hand repair-cook-measures something it would undo ----------------
        $dens = (Read-JsonFile (Join-Path $mp 'db\densities.json')).items
        $undo = @()
        foreach ($c in @(@('Garlic', '8 cloves, minced', 42), @('Chicken Broth', '1 cup', 240), @('Jalapeno', '2 1/2 jalapenos', 35))) {
            if (-not (Test-CmLabelTrue $dens ([string]$c[0]) ([string]$c[1]) ([double]$c[2]))) { $undo += ("{0}: '{1}' @ {2} g" -f $c[0], $c[1], $c[2]) }
        }
        Chk 'the labels this writes prove TRUE to repair-cook-measures (nothing gets undone next run)' ($undo.Count -eq 0) ($undo -join ' | ')
    } finally { Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue }
    if ($fail -eq 0) { Write-Output 'SELF-TEST PASS'; exit 0 } else { Write-Output "SELF-TEST FAIL: $fail case(s)"; exit 1 }
}

$densPath = Join-Path $mp 'db\densities.json'
if (-not (Test-Path $densPath)) { throw "no db\densities.json - this repair cannot weigh anything without it" }
$dens = (Read-JsonFile $densPath).items
$res = Invoke-RangeBuyRepair (Join-Path $mp 'db\recipes') $dens ([bool]$Apply) $OVERRIDES
Write-Output ("range-buy repair: {0} label(s) across {1} recipe(s){2}" -f $res.lines, $res.recipes, $(if ($Apply) { '' } else { '  [read-only - pass -Apply]' }))
foreach ($s in $res.samples) { Write-Output ('    ' + $s) }
if ($res.notes.Count) {
    Write-Output ("  REFUSED - a range this pass will not resolve on its own ({0}):" -f $res.notes.Count)
    foreach ($n in $res.notes) { Write-Output ('    ' + $n) }
}
if ($Apply -and $res.slugs.Count) {
    New-Item -ItemType Directory -Force (Join-Path $mp 'out') | Out-Null
    ($res.slugs -join "`n") | Set-Content (Join-Path $mp 'out\range-buy-slugs.txt') -Encoding UTF8
    Save-JsonArray -Array @($res.carry) -Path (Join-Path $mp 'out\range-buy-carry.json') | Out-Null
    Write-Output '  slug list -> out\range-buy-slugs.txt   carry manifest -> out\range-buy-carry.json'
    Write-Output '  next: sync-recipesdb-buy.ps1 -Apply, gen-planner-data.ps1, then rebuild + republish these cards'
}
exit 0
