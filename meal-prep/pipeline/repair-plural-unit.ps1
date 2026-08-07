<#
  repair-plural-unit.ps1 - retire the labels that read "1 cups".

  THE DEFECT. 96 ingredient rows across 78 specs print a quantity of exactly one against a plural unit:

      <strong>Salsa (Pace):</strong> 1 cups (260 g)
      <strong>Soy Sauce:</strong> 1 cups (255 g)
      <strong>BBQ Sauce:</strong> 1 cups (285 g)          <- grilled-pork-tenderloin-burrito-bowl, LIVE

  FriendlyAmt's cup branches are `(Frac $g/$cup) + ' cups'`: Frac returns the bare number and the branch
  appends a hardcoded plural, so the one quantity that needs a singular never gets one.

  WHY IT KEPT COMING BACK, which is the part worth remembering. friendly-amt-lib.ps1 has carried the fix
  since it was written. It never reached a card, because the two builders that actually write specs -
  build-v2-spec.ps1 and build-run-specs.ps1 - each carried their OWN INLINE COPY of FriendlyAmt and
  called that instead. The library was fixed and the bug shipped anyway, for as long as the copies
  existed. Same shape as the "per bowl" sentence that lived in both cost-render-lib.ps1 and
  build-run-specs.ps1. Both builders now dot-source the library (2026-08-07) and the copies are gone;
  this script cleans up what they already wrote.

  THE SAFETY RULE, and why this is not a string replace. A blanket s/1 cups/1 cup/ would also "fix" any
  row whose amount is wrong for a different reason, laundering a bad number into a tidy-looking label.
  So an edit is accepted only when the stored label and the label the generator writes TODAY are the
  same string once the unit's plural is normalised away - i.e. the quantity, the unit and any tail
  ("dry") are identical and the ONLY difference is the s. Anything where the number also moved is
  reported, never rewritten: that is a basis question (db\densities.json) and it is not this sweep's.

  NO GRAM FIGURE, COST FIELD OR MACRO MOVES. Only the letter s.

  Four surfaces, spliced by pipeline\buy-label-lib.ps1: scaler.ing[].buy, ingredients_display[],
  cost_lines[], head.recipeIngredient[]. head is included - it is derived from ingredients_display and
  audit-db-agreement fails on the drift if it is left behind.

  Read-only unless -Apply.
  Usage: .\repair-plural-unit.ps1 [-Apply] | -SelfTest
#>
param([switch]$Apply, [switch]$SelfTest, [string]$Root = "")
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp = if ($Root) { $Root } else { Split-Path -Parent $here }
. (Join-Path $mp 'lib\json-db-io.ps1')
. (Join-Path $here 'buy-label-lib.ps1')
. (Join-Path $here 'friendly-amt-lib.ps1')

# Units whose plural the generator hardcodes. Only 'cups' today; the list exists so that the day another
# branch grows the same tail, the fix is a word here rather than a second copy of this script.
$script:PluralUnits = @('cups')

function Get-PluralNormalizedLabel {
    <# Fold a label's plural unit token to its singular, so two labels that differ ONLY in the s compare
       equal. Deliberately anchored on the unit token, not a bare substring: "2 cups" must stay "2 cups"
       distinct from "2 cup" for no reason other than that neither is ever produced. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Label)
    $out = $Label
    foreach ($u in $script:PluralUnits) {
        $single = $u.Substring(0, $u.Length - 1)
        $out = [regex]::Replace($out, "(?i)\b$u\b", $single)
    }
    return $out
}

# ---------------------------------------------------------------------------------------------------
# THE ONE ROW THE GENERATOR CANNOT ADJUDICATE, stated rather than smuggled past the rule above.
#
# slow-cooker-italian-chicken-penne carries "Parmesan Cheese: 1 cups (98 g)". FriendlyAmt sends anything
# matching Cheese|Parmesan down the WEIGHT branch, so it would write "3.5 oz" - the label was never
# generated, it was hand-supplied, and the safety rule correctly refuses it because the derived string
# differs by a whole unit and not by an s.
#
# It is still "1 cups" on a card, and the grammar fix is TRUE HERE INDEPENDENT OF THE OPEN BASIS
# QUESTION: 98 g is one cup at the densities figure (90 g/cup -> 1.09) AND at the food-macros-db label
# figure (112 g/cup -> 0.875); both land on 1 after Get-FaFrac's quarter-unit rounding. So the singular
# is safe to write while which of those two numbers is right is still undecided.
#
# What is NOT decided here is whether this row should say cups at all. Parmesan is sold by weight and
# the cheese branch exists for that reason, so "3.5 oz" is arguably the better label - but that is a
# unit change, a different class, and it belongs to whoever settles the Parmesan basis. Grammar only.
$OVERRIDES = @{
    'slow-cooker-italian-chicken-penne' = @{ 'Parmesan Cheese' = @{ Old = '1 cups'; New = '1 cup' } }
}

function Resolve-PluralUnitLabel {
    <# The corrected label for one row, or $null when this sweep must not touch it.
       $null covers: a label the generator agrees with, a row whose derived label differs by more than
       the plural (a basis/grams question), and an item the generator refuses (no each-noun). #>
    param(
        [Parameter(Mandatory)][string]$Item,
        [Parameter(Mandatory)][double]$Grams,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Buy,
        $Override
    )
    if ($Grams -le 0 -or -not $Buy) { return $null }
    # An override is a decision already made and written down; it still has to match the label actually
    # in the file, so a spec that moved on underneath it fails closed instead of rewriting the wrong row.
    if ($Override -and $Override.ContainsKey($Item)) {
        $o = $Override[$Item]
        if ([string]$o.Old -ne $Buy) { return $null }
        return [string]$o.New
    }
    $derived = $null
    try { $derived = Get-FriendlyAmt $Item $Grams } catch { return $null }
    if (-not $derived -or $derived -eq $Buy) { return $null }
    if ((Get-PluralNormalizedLabel $Buy) -ne (Get-PluralNormalizedLabel $derived)) { return $null }
    return $derived
}

function Repair-SpecPluralUnit {
    <# Returns @{ changed; text; notes; edits } for ONE spec. Pure text in, text out. #>
    param([Parameter(Mandatory)][string]$Raw, [Parameter(Mandatory)]$Spec, $Override)
    $ing  = @($Spec.scaler.ing)
    $disp = @($Spec.ingredients_display)
    if ($ing.Count -ne $disp.Count) { throw ("parallel arrays disagree: scaler.ing $($ing.Count) vs ingredients_display $($disp.Count)") }

    $edits = New-Object System.Collections.Generic.List[object]
    $notes = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $ing.Count; $i++) {
        $buy = [string]$ing[$i].buy
        if (-not $buy) { continue }
        # TWO NAMES, TWO JOBS, AND THEY ARE NOT INTERCHANGEABLE. On a spec that renames an ingredient for
        # the reader, `item` is the rename ("Korean glass noodles (dangmyeon)") and `canon` is the DB
        # identity ("Rice Noodles"). densities, each-nouns and recipes-db are keyed by CANON; cost_lines
        # are written with the DISPLAY name, and buy-label-lib matches its cost_lines prefix on whatever
        # Item it is handed. Pass canon there and the cost line silently fails to match - and the lib
        # treats a miss as "this is a bulk item with no buy line", so it is silent by design and the
        # repair still reports success. No row in the 2026-08-07 sweep was renamed, so nothing was lost;
        # this is the trap set for the next run, not a report of damage.
        $canon = if (($ing[$i].PSObject.Properties.Name -contains 'canon') -and $ing[$i].canon) { [string]$ing[$i].canon } else { [string]$ing[$i].item }
        $disp  = [string]$ing[$i].item
        $g = if (($ing[$i].PSObject.Properties.Name -contains 'grams') -and $ing[$i].grams) { [double]$ing[$i].grams } else { 0 }
        $new = Resolve-PluralUnitLabel -Item $canon -Grams $g -Buy $buy -Override $Override
        if (-not $new) { continue }
        $edits.Add([pscustomobject]@{ Index = $i; Item = $disp; Canon = $canon; Old = $buy; New = $new; Grams = [int]$g })
    }
    if ($edits.Count -eq 0) { return @{ changed = 0; text = $Raw; notes = @($notes.ToArray()); edits = @() } }
    $sp = Invoke-BuyLabelSplice -Raw $Raw -Spec $Spec -Edits @($edits.ToArray()) -IncludeHead
    foreach ($n in $sp.notes) { $notes.Add($n) }
    return @{ changed = $edits.Count; text = $sp.text; notes = @($notes.ToArray()); edits = @($edits.ToArray()) }
}

function Invoke-PluralUnitRepair([string]$specDir, [bool]$apply, $overridesBySlug) {
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
        $r = Repair-SpecPluralUnit -Raw $io.Text -Spec $spec -Override $ov
        foreach ($n in $r.notes) { $notes.Add($f.BaseName + ' :: ' + $n) }
        if ($r.changed -eq 0) { continue }
        foreach ($e in $r.edits) {
            if ($samples.Count -lt 14) { $samples.Add(("{0,-34} {1,-30} '{2}' -> '{3}'" -f $f.BaseName, $e.Item, $e.Old, $e.New)) }
            # CARRY MANIFEST, keyed by CANON because recipes-db stores the canonical name. sync-recipesdb-buy
            # carries only classes that a manifest proves a repair actually performed - without this the
            # specs and the cards say "1 cup" while planner-data.js goes on printing "1 cups" forever,
            # which is exactly how the cook-measure repair left the Meal Plan Builder stale for two days.
            $carry.Add([pscustomobject]@{ slug = $f.BaseName; item = $e.Canon; old = $e.Old; new = $e.New })
        }
        Assert-BuyLabelSurfacesAgree -Text $r.text -Slug $f.BaseName
        $lines += $r.changed; $recipes++; $slugs.Add($f.BaseName)
        if ($apply) { Write-SpecText -Path $f.FullName -Text $r.text -Bom $io.Bom }
    }
    return @{ lines = $lines; recipes = $recipes; slugs = @($slugs.ToArray()); samples = @($samples.ToArray()); notes = @($notes.ToArray()); carry = @($carry.ToArray()) }
}

if ($SelfTest) {
    $fail = 0
    function Chk([string]$label, [bool]$cond, [string]$got) {
        if ($cond) { Write-Output ('ok    ' + $label) } else { Write-Output ('FAIL  ' + $label + '   got: ' + $got); $script:fail++ }
    }
    Write-Output 'repair-plural-unit self-test'
    Initialize-FriendlyAmt -Root $mp

    Chk 'normaliser folds the plural'      ((Get-PluralNormalizedLabel '1 cups') -eq '1 cup') (Get-PluralNormalizedLabel '1 cups')
    Chk 'normaliser keeps the tail'        ((Get-PluralNormalizedLabel '1 cups dry') -eq '1 cup dry') (Get-PluralNormalizedLabel '1 cups dry')
    Chk 'normaliser leaves tbsp alone'     ((Get-PluralNormalizedLabel '3 tbsp') -eq '3 tbsp') (Get-PluralNormalizedLabel '3 tbsp')
    # THE SAFETY RULE. Same item, same label, but grams that do NOT render as one cup: the sweep must
    # refuse, because the number moving is a basis question and rewriting it here would hide that.
    Chk 'refuses when the QUANTITY also moves' ($null -eq (Resolve-PluralUnitLabel -Item 'Salsa' -Grams 700 -Buy '1 cups')) 'expected null'
    Chk 'takes the plural-only case'       ((Resolve-PluralUnitLabel -Item 'Salsa' -Grams 260 -Buy '1 cups') -eq '1 cup') (Resolve-PluralUnitLabel -Item 'Salsa' -Grams 260 -Buy '1 cups')
    Chk 'leaves an already-correct label'  ($null -eq (Resolve-PluralUnitLabel -Item 'Salsa' -Grams 520 -Buy '2 cups')) 'expected null'

    # THE OVERRIDE, and the thing that makes it safe: it is keyed to the label it expects to find. If the
    # spec moved on, the override must NOT fire - a hand-written decision aimed at a row that no longer
    # exists is how a repair rewrites the wrong ingredient and still reports success.
    $ovFx = @{ 'Parmesan Cheese' = @{ Old = '1 cups'; New = '1 cup' } }
    Chk 'override fires on the label it names' ((Resolve-PluralUnitLabel -Item 'Parmesan Cheese' -Grams 98 -Buy '1 cups' -Override $ovFx) -eq '1 cup') 'override did not fire'
    Chk 'override REFUSES a moved label'       ($null -eq (Resolve-PluralUnitLabel -Item 'Parmesan Cheese' -Grams 98 -Buy '3.5 oz' -Override $ovFx)) 'stale override fired anyway'
    Chk 'override does not leak to other items'($null -eq (Resolve-PluralUnitLabel -Item 'Cheddar Cheese' -Grams 98 -Buy '1 cups' -Override $ovFx)) 'override applied to the wrong item'
    # WITHOUT the override the generator must still refuse it - proving the rule is intact, not loosened.
    Chk 'no override: parmesan still refused'  ($null -eq (Resolve-PluralUnitLabel -Item 'Parmesan Cheese' -Grams 98 -Buy '1 cups')) 'the safety rule was weakened'
    # 98 g is one cup at BOTH candidate bases, which is why the override is honest while the basis is open.
    $pFrac = { param($b) $v = 98.0 / $b; $r = [Math]::Round($v * 4) / 4; return $r }
    Chk 'override true at densities 90 g/cup'  ((& $pFrac 90.0) -eq 1.0)  ("got " + (& $pFrac 90.0))
    Chk 'override true at label 112 g/cup'     ((& $pFrac 112.0) -eq 1.0) ("got " + (& $pFrac 112.0))

    # FROZEN MUST-FIRE FIXTURE: the founding bug verbatim (BBQ Sauce off the live burrito-bowl card),
    # a rice row that proves the "dry" tail survives, a clean plural twin that must not move, and a row
    # whose grams contradict its label so the refusal is exercised, not just asserted.
    $fx = @'
{
    "slug":  "fx-plural",
    "intro_html":  "Prose with a brace { and a bracket [ and a quote \" so the splice must be string-aware.",
    "ingredients_display": ["<strong>BBQ Sauce (Sweet Baby Rays):</strong> 1 cups (285 g)","<strong>Rice (Member's Mark):</strong> 1 cups dry (185 g)","<strong>Salsa (Pace):</strong> 2 cups (520 g)","<strong>Soy Sauce:</strong> 1 cups (700 g)"],
    "cost_lines":  [
                       "BBQ Sauce, 1 cups: ~$0.62. <strong>Buy 1 bottle: $1.98.</strong>",
                       "Rice, 1 cups dry: ~$0.18. <strong>Buy 1 bag: $1.12.</strong>"
                   ],
    "head":  {
                 "recipeIngredient":  ["BBQ Sauce, 1 cups (285 g)","Rice, 1 cups dry (185 g)","Salsa, 2 cups (520 g)","Soy Sauce, 1 cups (700 g)"]
             },
    "scaler":  {
                   "ing":  [
                               { "item": "BBQ Sauce", "canon": "BBQ Sauce", "grams": 285, "buy": "1 cups",     "bid": "bbq-sauce", "gpu": "29.570" },
                               { "item": "Rice",      "canon": "Rice",      "grams": 185, "buy": "1 cups dry", "bid": "rice",      "gpu": "453.592" },
                               { "item": "Salsa",     "canon": "Salsa",     "grams": 520, "buy": "2 cups",     "bid": "salsa",     "gpu": "28.350" },
                               { "item": "Soy Sauce", "canon": "Soy Sauce", "grams": 700, "buy": "1 cups",     "bid": "soy-sauce", "gpu": "29.570" }
                           ]
               }
}
'@
    $fspec = $fx | ConvertFrom-Json
    $r = Repair-SpecPluralUnit -Raw $fx -Spec $fspec
    Chk 'fixture: exactly two edits'        ($r.changed -eq 2) ("changed=" + $r.changed)
    Chk 'fixture: BBQ Sauce singularised'   ($r.text -match '\<strong\>BBQ Sauce \(Sweet Baby Rays\):\</strong\> 1 cup \(285 g\)') 'display not rewritten'
    Chk 'fixture: rice KEEPS its dry tail'  ($r.text -match '1 cup dry \(185 g\)') 'the dry tail was eaten'
    Chk 'fixture: no bare "1 cups" left on the card' (-not ($r.text -match 'strong\>BBQ Sauce \(Sweet Baby Rays\):\</strong\> 1 cups')) 'old label still on the card'
    Chk 'fixture: clean 2 cups twin intact' ($r.text -match '\<strong\>Salsa \(Pace\):\</strong\> 2 cups \(520 g\)') 'clean twin moved'
    Chk 'fixture: contradicted row REFUSED' ($r.text -match '\<strong\>Soy Sauce:\</strong\> 1 cups \(700 g\)') 'a wrong-quantity row was laundered'
    Chk 'fixture: cost_lines followed'      ($r.text -match 'BBQ Sauce, 1 cup: ') 'cost_lines not spliced'
    # HEAD IS NOT THIS SCRIPT'S TO FIX, AND THE FIXTURE PINS THAT. buy-label-lib's head patch fires only
    # on a line that BEGINS with the old label, and head.recipeIngredient is derived as
    # "<Name>, <amount> (<g> g)" - it begins with the ingredient name, so nothing matches and -IncludeHead
    # correctly does nothing. That is not a gap, it is the division of labour: repair-head-ingredients.ps1
    # re-derives the whole list from ingredients_display. This assertion exists so that anyone who reads
    # "head untouched" as a bug finds out here that the tail step is what closes it - and so that skipping
    # that step is a visible choice rather than an oversight. audit-db-agreement fails on the drift.
    Chk 'fixture: head still stale (repair-head-ingredients owns it)' ($r.text -match '"BBQ Sauce, 1 cups \(285 g\)"') 'head changed unexpectedly'
    Chk 'fixture: still valid JSON'         ($null -ne ($r.text | ConvertFrom-Json)) 'splice produced unparseable JSON'

    # THE RENAMED-INGREDIENT FIXTURE. `item` is the reader-facing rename, `canon` is the DB identity.
    # The cost line is written with the RENAME, densities are keyed by CANON, and recipes-db stores CANON.
    # An edit that carries only one of the two names silently half-lands: derive off the rename and
    # nothing resolves, splice cost_lines with canon and the receipt keeps the old label while the repair
    # reports success. No row in the founding sweep was renamed, so this case is here to keep it that way.
    $fxRn = @'
{
    "slug":  "fx-rename",
    "ingredients_display": ["<strong>Korean glass noodles (dangmyeon):</strong> 1 cups (240 g)"],
    "cost_lines":  ["Korean glass noodles (dangmyeon), 1 cups: ~$1.20. <strong>Buy 1 box: $2.40.</strong>"],
    "scaler":  { "ing":  [ { "item": "Korean glass noodles (dangmyeon)", "canon": "Rice Vinegar", "grams": 240, "buy": "1 cups", "bid": "rice-vinegar", "gpu": "29.570" } ] }
}
'@
    $rRn = Repair-SpecPluralUnit -Raw $fxRn -Spec ($fxRn | ConvertFrom-Json)
    Chk 'rename: derived through CANON'     ($rRn.changed -eq 1) ("changed=" + $rRn.changed)
    Chk 'rename: display line rewritten'    ($rRn.text -match 'dangmyeon\):\</strong\> 1 cup \(240 g\)') 'display not rewritten'
    Chk 'rename: cost_line used the RENAME' ($rRn.text -match 'Korean glass noodles \(dangmyeon\), 1 cup: ') 'cost_lines missed - Item was not the display name'
    Chk 'rename: manifest key is CANON'     ($rRn.edits[0].Canon -eq 'Rice Vinegar') ("canon=" + $rRn.edits[0].Canon)
    Assert-BuyLabelSurfacesAgree -Text $r.text -Slug 'fx-plural'
    Chk 'fixture: surfaces agree'           $true ''

    if ($fail -eq 0) { Write-Output 'SELF-TEST PASS'; exit 0 } else { Write-Output "SELF-TEST FAIL: $fail case(s)"; exit 1 }
}

Initialize-FriendlyAmt -Root $mp
$res = Invoke-PluralUnitRepair (Join-Path $mp 'db\recipes') ([bool]$Apply) $OVERRIDES
Write-Output ("plural-unit repair: {0} line(s) across {1} recipe(s){2}" -f $res.lines, $res.recipes, $(if ($Apply) { '' } else { '  [read-only - pass -Apply]' }))
foreach ($s in $res.samples) { Write-Output ('    ' + $s) }
if ($res.notes.Count) {
    Write-Output ("  notes ({0}):" -f $res.notes.Count)
    foreach ($n in ($res.notes | Select-Object -First 12)) { Write-Output ('    ' + $n) }
}
if ($Apply -and $res.slugs.Count) {
    New-Item -ItemType Directory -Force (Join-Path $mp 'out') | Out-Null
    ($res.slugs -join "`n") | Set-Content (Join-Path $mp 'out\plural-unit-slugs.txt') -Encoding UTF8
    Write-Output '  slug list -> out\plural-unit-slugs.txt (rebuild + republish these cards)'
    # ConvertTo-Json on a 1-element array emits a bare object in PS 5.1, and the reader does
    # @(ConvertFrom-Json) - which would then be one object, not one row. Force the array.
    $json = if ($res.carry.Count -eq 1) { '[' + ($res.carry[0] | ConvertTo-Json -Depth 4 -Compress) + ']' } else { $res.carry | ConvertTo-Json -Depth 4 }
    $json | Set-Content (Join-Path $mp 'out\plural-unit-carry.json') -Encoding UTF8
    Write-Output ("  carry manifest -> out\plural-unit-carry.json ({0} row(s)); now run pipeline\repair-head-ingredients.ps1 -Apply -Slugs <list> and pipeline\sync-recipesdb-buy.ps1 -Apply" -f $res.carry.Count)
}
exit 0
