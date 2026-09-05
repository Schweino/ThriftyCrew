<#
  repair-measure-vs-grams.ps1 - make the ingredient label state the amount THIS recipe uses, on the rows
  where a source check has settled that the label is the side that is wrong.

  THE DEFECT. 331 ingredient labels across 91 specs state a quantity that disagrees with the gram figure
  printed beside them by 2x or more:

      Salt: 1/4 tsp (8 g)                 <- 8 g is about 1 1/2 tsp
      Black Pepper: 1/2 tsp (4 g)         <- 4 g is about 1 3/4 tsp
      Dried Oregano: 1 tsp (7 g)          <- 7 g is about 2 1/4 tbsp
      Rice: 1 lb (1201 g)                 <- 1201 g is 2.6 lb

  This is the same defect as the seven "(scaled ~N)" rows repair-scaled-notes.ps1 fixed, minus the
  writer's note that made those findable. The writer scaled the GRAMS to 14 servings and left the source
  recipe's own amount sitting in front of them.

  WHY THIS COULD NOT BE SWEPT, and what was done instead. cook-measure-lib.ps1:152-158 refuses this class
  deliberately: for a measuring unit either the label or the GRAMS can be the error, the grams drive cost
  and macros, and rewriting a label to agree with a gram figure that is itself wrong launders a data bug
  into a confident-looking measurement. That refusal is right and it still stands. What unlocks these
  rows is not a cleverer rule, it is EVIDENCE: each recipe's source_url was fetched and the source's own
  amount read for every flagged ingredient. The result is out\measure-vs-grams-verdicts.csv, and this
  script repairs only what that file has already decided.

  WHAT THE SOURCES SAID (87 of the 91 specs cite a source; 86 could be read):
    label-is-source-unscaled  272  the label is the SOURCE's amount, verbatim, at the SOURCE's serving
                                   count - parentheticals and all: "1/4 cup beef broth (or water)",
                                   "1 tsp (meatballs) + 1 tsp (sauce)", "1/2 tsp + 1/4 tsp (turkey +
                                   sauce)". The label is not a competing measurement of this recipe; it
                                   is a measurement of a DIFFERENT, smaller recipe.
    filler-label               32  "1 lb" - a label that does not move. 71 Rice rows across the catalog
                                   carry the literal string "1 lb" against grams from 420 g to 1201 g. A
                                   label constant across a 2.9x span measures nothing, and the sources
                                   confirm it: they state rice in CUPS ("1 cup long grain white rice") or
                                   have no rice at all.
    label-near-source           5  same shape, but the copied amount was not byte-identical to the source
    own-addition                7  the ingredient is NOT in the source, so nothing external decides which
                                   side is wrong.                                          NOT REPAIRED
    unverifiable               13  no source_url on the spec (4 specs), or the cited URL is dead
                                   (cheeseburger-rice-bowls -> HTTP 404).                   NOT REPAIRED
    grams-suspect               2  the label is LARGER than the grams and matches the correctly SCALED
                                   source amount, so the GRAMS are the doubtful side.       NOT REPAIRED

  THE TWO grams-suspect ROWS ARE THE REASON THE REFUSAL EXISTS. slow-cooker-kalua-pork-bowls says
  "Salt: 2 tbsp" against 15 g. The source (downshiftology, 6 servings, 4 lb pork) calls for 1 tablespoon;
  this spec uses 7.5 lb, so ~2 tbsp is the correctly scaled amount and the LABEL IS RIGHT. A sweep that
  rewrote labels to agree with grams would have replaced a correct label with "2.5 tsp" and called it a
  repair. Both rows are left exactly as they are and reported for a decision on the GRAM figure.

  KNOWING WHICH SIDE IS WRONG IS NOT THE SAME AS BEING ABLE TO WRITE THE RIGHT ONE. Every replacement is
  re-derived from the grams by the generator's own function (pipeline\friendly-amt-lib.ps1) and then put
  through Test-CmReplacement below, which refuses anything that would not read as a recipe: a fraction of
  a tablespoon, a sub-ounce weight, a package noun on an Ingredients list, a fractional count of a
  countable thing, or a label whose writer tail carries a SECOND quantity that splicing the head would
  contradict ("3 oz cubed + 3/4 cup shredded"). 26 rows fail that gate and are reported, not guessed.

  WHAT THIS TOUCHES - four surfaces, the same four repair-scaled-notes.ps1 learned to patch:
      scaler.ing[].buy         "1/2 tsp"                       -> "1.75 tsp"
      ingredients_display[]    "... 1/2 tsp (4 g)"             -> "... 1.75 tsp (4 g)"
      cost_lines[]             "Black Pepper, 1/2 tsp: ..."    -> "Black Pepper, 1.75 tsp: ..."
      head.recipeIngredient[]  "1/2 tsp Black Pepper"          -> "1.75 tsp Black Pepper"
  Every edit is a targeted splice via the string-aware scanners in lib\json-db-io.ps1. SPEC-SCHEMA.md
  forbids ConvertFrom-Json | ConvertTo-Json on a spec, and each file's BOM state is preserved.

  NO GRAM FIGURE, COST FIELD OR MACRO MOVES. Only the sentence changes.

  Read-only unless -Apply.
  Usage: .\repair-measure-vs-grams.ps1 [-Apply]  |  -SelfTest  |  -Report
#>
param([switch]$Apply, [switch]$SelfTest, [switch]$Report, [string]$Root = "")
$ErrorActionPreference = 'Stop'
$__jioRoot = $PSScriptRoot; while ($__jioRoot -and -not (Test-Path (Join-Path $__jioRoot 'lib\json-io.ps1'))) { $__jioRoot = Split-Path $__jioRoot -Parent }
if (-not $__jioRoot) { throw 'json-io.ps1 not found walking up from ' + $PSScriptRoot + " - Read-JsonFile is unavailable and a bare Get-Content would decode a BOM-less file as cp1252" }
. (Join-Path $__jioRoot 'lib\json-io.ps1')   # walk UP to find it: this file is two levels below the repo root, and a fixed -Parent hop assumed one
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp = if ($Root) { $Root } else { Split-Path -Parent $here }
. (Join-Path $mp 'lib\json-db-io.ps1')
. (Join-Path $mp 'pipeline\cook-measure-lib.ps1')
. (Join-Path $mp 'pipeline\friendly-amt-lib.ps1')

# Verdicts this script is willing to act on. Everything else is reported and left alone.
$script:MVG_REPAIRABLE = @('label-is-source-unscaled', 'filler-label', 'label-near-source')
$script:MVG_PKG = '^(jar|jars|bottle|bottles|bag|bags|box|boxes|package|packages|pkg|carton|cartons|container|containers|sleeve|tube|bulb|bulbs|can|cans|packet|packets|bunch|bunches|head|heads|stick|sticks|block|brick)$'

function Test-CmReplacement {
    <# '' when the derived label is fit to print, otherwise the reason it is not. #>
    param([string]$Item, [string]$OldBuy, [string]$Tail, [string]$New, [double]$Grams)
    if (-not $New) { return 'no derivation' }
    # A tail with a digit in it is a SECOND quantity, not a cooking note: "3 oz cubed + 3/4 cup shredded",
    # "1 tbsp + 1/2 tsp". Replacing the head leaves the label arguing with itself.
    if ($Tail -match '\d') { return "tail carries a second quantity ('$Tail') - splicing the head would leave a self-contradicting label" }
    $oldU = Get-CmUnit $OldBuy
    if ($oldU -and $oldU -match $script:MVG_PKG) { return "old label names a package ('$oldU') - a count has to be written by hand, not derived" }
    $nq = Get-CmQty $New
    $nu = Get-CmUnit $New
    # A fraction of a TABLESPOON is not a measure anyone owns - the spoon in the drawer is a teaspoon.
    # A fraction of a CUP is: 1/4, 1/3, 1/2, 2/3 and 3/4 cup are all standard measuring cups, so those
    # stand. Only a sliver of a cup, below a quarter, has no cup to scoop it with.
    if ($null -ne $nq -and $nq -lt 1 -and $nu -eq 'tbsp')            { return "derives '$New' - nobody owns a fraction of a tablespoon; that amount belongs in teaspoons" }
    if ($null -ne $nq -and $nq -lt 0.25 -and $nu -match '^cups?$')   { return "derives '$New' - less than a quarter cup has no cup to measure it with" }
    if ($nu -match '^(oz|lb)$' -and $Grams -lt 30) { return "derives '$New' - a sub-ounce weight cannot be measured at the counter" }
    if ($nu -match $script:MVG_PKG) { return "derives a package noun ('$nu') - that is the defect cook-measure-lib exists to prevent" }
    if ($null -ne $nq -and $nu -and $nu -notmatch '^(tbsp|tsp|cup|cups|oz|lb|g)$' -and [math]::Abs($nq - [math]::Round($nq)) -gt 0.01) { return "derives a fractional count ('$New')" }
    if ($New -match '^1 (cups|lb)\b') { return "derives '$New' - plural noun on a quantity of one" }
    return ''
}

function Get-CmNewLabel {
    <# The replacement: the generator's own derivation from the grams, with the writer's tail carried. #>
    param([string]$Item, [double]$Grams, [string]$OldBuy)
    $tail = Get-CmTail $OldBuy
    $base = $null
    try { $base = Get-FriendlyAmt $Item $Grams } catch { return @{ new = $null; tail = $tail } }
    if (-not $base) { return @{ new = $null; tail = $tail } }
    $new = if ($tail) { Join-CmTail $base $tail } else { $base }
    return @{ new = $new; tail = $tail }
}

function Repair-SpecMeasures {
    <# @{ changed; text; notes; edits } for ONE spec. Pure text in, text out, so the self-test drives
       exactly the code path the catalog run drives. $Decided is @{ "<item>" = @{verdict; evidence} }. #>
    param(
        [Parameter(Mandatory)][string]$Raw,
        [Parameter(Mandatory)]$Spec,
        [Parameter(Mandatory)]$Decided
    )
    $ing  = @($Spec.scaler.ing)
    $disp = @($Spec.ingredients_display)
    if ($ing.Count -ne $disp.Count) { throw ("parallel arrays disagree: scaler.ing $($ing.Count) vs ingredients_display $($disp.Count)") }

    $edits = New-Object System.Collections.Generic.List[object]
    $notes = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $ing.Count; $i++) {
        $item = [string]$ing[$i].item
        if (-not $Decided.ContainsKey($item)) { continue }
        $d = $Decided[$item]
        $buy = [string]$ing[$i].buy
        $g   = [double]$ing[$i].grams
        # The verdict was reached against a SPECIFIC label. If the stored label has changed since, the
        # evidence no longer describes this row and the row is not ours to touch.
        if ($buy -ne [string]$d.buy) { $notes.Add("'$item' label is now '$buy', the verdict was reached against '$($d.buy)' - LEFT ALONE"); continue }
        if ($script:MVG_REPAIRABLE -notcontains [string]$d.verdict) { $notes.Add("'$item' ($buy, $([int]$g) g) is '$($d.verdict)' - LEFT ALONE: $($d.evidence)"); continue }
        $r = Get-CmNewLabel $item $g $buy
        $why = Test-CmReplacement -Item $item -OldBuy $buy -Tail $r.tail -New $r.new -Grams $g
        if ($why) { $notes.Add("'$item' ($buy, $([int]$g) g) - NOT REPAIRED, $why"); continue }
        if ($r.new -eq $buy) { continue }
        $edits.Add([pscustomobject]@{ Index = $i; Item = $item; Old = $buy; New = [string]$r.new; Grams = [int]$g; Verdict = [string]$d.verdict })
    }
    if ($edits.Count -eq 0) { return @{ changed = 0; text = $Raw; notes = @($notes.ToArray()); edits = @() } }

    $text = $Raw

    # ---- 1. scaler.ing[i].buy ---------------------------------------------------------------------
    $scalerAt = Find-JsonValueStart -Raw $text -Key 'scaler'
    if ($scalerAt -lt 0) { throw 'no "scaler" key' }
    $ingAt = Find-JsonValueStart -Raw $text -Key 'ing' -From $scalerAt
    if ($ingAt -lt 0) { throw 'no "scaler"."ing" key' }
    $spans = @(Get-JsonArraySpans -Raw $text -OpenIndex $ingAt)
    if ($spans.Count -ne $ing.Count) { throw ("scaler.ing span walk found $($spans.Count) elements, parser says $($ing.Count)") }
    foreach ($e in @($edits | Sort-Object Index -Descending)) {
        $sp = $spans[$e.Index]
        $el = $text.Substring($sp.Start, $sp.End - $sp.Start + 1)
        $bAt = Find-JsonValueStart -Raw $el -Key 'buy'
        if ($bAt -lt 0) { throw ("no buy key in scaler.ing[$($e.Index)]") }
        $vs = Get-JsonStringSpan -Raw $el -OpenIndex $bAt
        $cur = $el.Substring($vs.Start, $vs.End - $vs.Start + 1)
        if ($cur -ne $e.Old) { throw ("scaler.ing[$($e.Index)] buy is '$cur', expected '$($e.Old)'") }
        $newEl = $el.Substring(0, $vs.Start) + $e.New + $el.Substring($vs.End + 1)
        $text = $text.Substring(0, $sp.Start) + $newEl + $text.Substring($sp.End + 1)
    }

    # ---- 2. ingredients_display[i] ----------------------------------------------------------------
    $dispAt = Find-JsonValueStart -Raw $text -Key 'ingredients_display'
    if ($dispAt -lt 0) { throw 'no "ingredients_display" key' }
    $dspans = @(Get-JsonArraySpans -Raw $text -OpenIndex $dispAt)
    if ($dspans.Count -ne $disp.Count) { throw ("ingredients_display span walk found $($dspans.Count) elements, parser says $($disp.Count)") }
    foreach ($e in @($edits | Sort-Object Index -Descending)) {
        $sp = $dspans[$e.Index]
        $el = $text.Substring($sp.Start, $sp.End - $sp.Start + 1)
        $tail = ' ' + $e.Old + ' (' + $e.Grams + ' g)"'
        if (-not $el.EndsWith($tail)) { throw ("ingredients_display[$($e.Index)] does not end with '$tail': $el") }
        $newEl = $el.Substring(0, $el.Length - $tail.Length) + ' ' + $e.New + ' (' + $e.Grams + ' g)"'
        $text = $text.Substring(0, $sp.Start) + $newEl + $text.Substring($sp.End + 1)
    }

    # ---- 3. cost_lines -----------------------------------------------------------------------------
    $clAt = Find-JsonValueStart -Raw $text -Key 'cost_lines'
    if ($clAt -ge 0) {
        $cspans = @(Get-JsonArraySpans -Raw $text -OpenIndex $clAt)
        foreach ($e in @($edits | Sort-Object Index -Descending)) {
            $prefix = '"' + $e.Item + ', ' + $e.Old + ':'
            $hits = @($cspans | Where-Object { $text.Substring($_.Start, [Math]::Min($prefix.Length, $_.End - $_.Start + 1)) -eq $prefix })
            if ($hits.Count -eq 0) { continue }
            if ($hits.Count -gt 1) { $notes.Add("cost_lines: '$($e.Item), $($e.Old):' matched $($hits.Count) lines - skipped"); continue }
            $sp = $hits[0]
            $newPrefix = '"' + $e.Item + ', ' + $e.New + ':'
            $text = $text.Substring(0, $sp.Start) + $newPrefix + $text.Substring($sp.Start + $prefix.Length)
            $cspans = @(Get-JsonArraySpans -Raw $text -OpenIndex (Find-JsonValueStart -Raw $text -Key 'cost_lines'))
        }
    }

    # ---- 4. head.recipeIngredient (the JSON-LD Google reads) --------------------------------------
    $headAt = Find-JsonValueStart -Raw $text -Key 'head'
    if ($headAt -ge 0) {
        $riAt = Find-JsonValueStart -Raw $text -Key 'recipeIngredient' -From $headAt
        if ($riAt -ge 0) {
            # .ToArray() and NOT @($edits): wrapping a List[object] in @() throws on PS 5.1 even when
            # empty - the trap already documented in lib\json-db-io.ps1 and repair-scaled-notes.ps1.
            foreach ($e in $edits.ToArray()) {
                $rspans = @(Get-JsonArraySpans -Raw $text -OpenIndex (Find-JsonValueStart -Raw $text -Key 'recipeIngredient' -From (Find-JsonValueStart -Raw $text -Key 'head')))
                # anchor on "<amount> <item>" so a bare "1 tsp" cannot match another ingredient's line
                $hits = @($rspans | Where-Object {
                    $s = $text.Substring($_.Start, $_.End - $_.Start + 1)
                    $s.Contains($e.Old) -and $s -match ([regex]::Escape($e.Item))
                })
                if ($hits.Count -eq 0) { continue }
                if ($hits.Count -gt 1) { $notes.Add("head.recipeIngredient: '$($e.Old)' + '$($e.Item)' matched $($hits.Count) entries - skipped"); continue }
                $sp = $hits[0]
                $el = $text.Substring($sp.Start, $sp.End - $sp.Start + 1)
                $occ = ([regex]::Matches($el, [regex]::Escape($e.Old))).Count
                if ($occ -ne 1) { $notes.Add("head.recipeIngredient: '$($e.Old)' appears $occ times in one entry - skipped"); continue }
                $newEl = $el.Replace($e.Old, $e.New)
                $text = $text.Substring(0, $sp.Start) + $newEl + $text.Substring($sp.End + 1)
            }
        }
    }

    return @{ changed = $edits.Count; text = $text; notes = @($notes.ToArray()); edits = @($edits.ToArray()) }
}

function Invoke-MeasureRepair([string]$specDir, [string]$verdictCsv, [bool]$apply) {
    $decided = @{}
    foreach ($v in (Import-Csv $verdictCsv)) {
        if (-not $decided.ContainsKey($v.Slug)) { $decided[$v.Slug] = @{} }
        $decided[$v.Slug][$v.Item] = @{ buy = [string]$v.Buy; grams = [int]$v.Grams; verdict = [string]$v.Verdict; evidence = [string]$v.Evidence }
    }
    $lines = 0; $recipes = 0
    $slugs   = New-Object System.Collections.Generic.List[string]
    $samples = New-Object System.Collections.Generic.List[string]
    $notes   = New-Object System.Collections.Generic.List[string]
    $carry   = New-Object System.Collections.Generic.List[object]
    foreach ($slug in ($decided.Keys | Sort-Object)) {
        $path = Join-Path $specDir ($slug + '.json')
        if (-not (Test-Path $path)) { $notes.Add("$slug :: no spec file"); continue }
        $io = Read-SpecText $path
        $spec = $io.Text | ConvertFrom-Json
        if (-not $spec.scaler -or -not $spec.scaler.ing) { $notes.Add("$slug :: no scaler.ing"); continue }
        $r = Repair-SpecMeasures -Raw $io.Text -Spec $spec -Decided $decided[$slug]
        foreach ($n in $r.notes) { $notes.Add($slug + ' :: ' + $n) }
        if ($r.changed -eq 0) { continue }
        foreach ($e in $r.edits) {
            $samples.Add(("{0,-42} {1,-22} '{2}' -> '{3}'   ({4} g)" -f $slug, $e.Item, $e.Old, $e.New, $e.Grams))
            $carry.Add([pscustomobject]@{ slug = $slug; item = $e.Item; old = $e.Old; new = $e.New; grams = $e.Grams; verdict = $e.Verdict })
        }

        # ---- POST-CONDITIONS, on every file, before it is written --------------------------------
        $after = $r.text | ConvertFrom-Json
        $ai = @($after.scaler.ing); $ad = @($after.ingredients_display)
        if ($ai.Count -ne $ad.Count) { throw ("${slug}: parallel arrays diverged during repair") }
        for ($k = 0; $k -lt $ai.Count; $k++) {
            # the widget re-renders the list from scaler.ing[].buy the moment a reader moves the servings
            # control, so a display-only fix would change the list under them
            if ([string]$ad[$k] -notmatch [regex]::Escape([string]$ai[$k].buy)) {
                throw ("${slug}: display line $k no longer carries its buy '$([string]$ai[$k].buy)'")
            }
        }
        # NOT ONE GRAM MAY MOVE. This repair changes sentences, never quantities - if a gram figure or a
        # cost field differs after the splice, the splice hit something it had no business touching.
        $bi = @($spec.scaler.ing)
        for ($k = 0; $k -lt $ai.Count; $k++) {
            if ([double]$ai[$k].grams -ne [double]$bi[$k].grams) { throw ("${slug}: grams moved on '$([string]$ai[$k].item)' - $([double]$bi[$k].grams) -> $([double]$ai[$k].grams)") }
            if ([string]$ai[$k].item -ne [string]$bi[$k].item)   { throw ("${slug}: ingredient order changed at index $k") }
            if ([string]$ai[$k].bid  -ne [string]$bi[$k].bid)    { throw ("${slug}: bid changed on '$([string]$ai[$k].item)'") }
            if ([string]$ai[$k].gpu  -ne [string]$bi[$k].gpu)    { throw ("${slug}: gpu changed on '$([string]$ai[$k].item)'") }
        }
        foreach ($f in @('cost_first_run','cost_batch','cost_batch_true','cost_per_serving','cost_per_serving_true','cost_pantry_add')) {
            if ([string]$spec.$f -ne [string]$after.$f) { throw ("${slug}: cost field $f moved") }
        }
        if ([string]$spec.stat.cal -ne [string]$after.stat.cal -or [string]$spec.stat.protein -ne [string]$after.stat.protein) { throw ("${slug}: macros moved") }

        $lines += $r.changed; $recipes++; $slugs.Add($slug)
        if ($apply) { Write-SpecText -Path $path -Text $r.text -Bom $io.Bom }
    }
    return @{ lines = $lines; recipes = $recipes; slugs = @($slugs.ToArray()); samples = @($samples.ToArray()); notes = @($notes.ToArray()); carry = @($carry.ToArray()) }
}

if ($SelfTest) {
    $fail = 0
    function Chk([string]$label, [bool]$cond, [string]$got) {
        if ($cond) { Write-Output ("ok    " + $label) } else { Write-Output ("FAIL  " + $label + "   got: " + $got); $script:fail++ }
    }
    Initialize-FriendlyAmt -Root $mp
    $T = Join-Path $env:TEMP ('mvg-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path (Join-Path $T 'recipes') -Force | Out-Null
    try {
        # FROZEN FIXTURE - the founding bug taken off the real cards, with a clean twin for every refusal.
        # Written as raw text and not ConvertTo-Json, because the point is the SPLICE: the prose below
        # carries escapes, braces and a bracket inside string literals, which is what broke naive brace
        # counting and is why lib\json-db-io.ps1 grew string-aware scanners.
        $fx = @'
{
    "slug":  "fx",
    "intro_html":  "A <strong>brace { and a bracket [ inside prose</strong>, plus a quote \" for good measure.",
    "ingredients_display": ["<strong>93/7 Ground Beef (Great Value):</strong> 5 lb (2240 g)","<strong>Black Pepper (Great Value):</strong> 1/2 tsp (4 g)","<strong>Rice (Great Value):</strong> 1 lb (1000 g)","<strong>Olive Oil (Great Value):</strong> 3 tbsp (42 g)","<strong>Diced Tomatoes (Great Value):</strong> 1 can (411 g)","<strong>Mozzarella Cheese:</strong> 3 oz cubed + 3/4 cup shredded (510 g)","<strong>Salt (Morton):</strong> 2 tbsp (15 g)","<strong>Garlic:</strong> 3 tsp minced (35 g)"],
    "cost_lines":  [
                       "Black Pepper, 1/2 tsp: ~$0.12. <strong>Buy 1 jar: $1.14.</strong>",
                       "Rice, 1 lb: ~$1.20. <strong>Buy 1 bag: $3.48.</strong>"
                   ],
    "cost_first_run": "31.20",
    "cost_per_serving": "2.23",
    "stat": { "cal": 540, "protein": 44, "carbs": 51, "fat": 16, "cost_ps": "2.23" },
    "scaler":  {
                   "cost":  "31.20",
                   "ing":  [
                               { "item": "93/7 Ground Beef", "grams": 2240, "buy": "5 lb", "bid": "93-7-ground-beef", "gpu": "453.592" },
                               { "item": "Black Pepper", "grams": 4, "buy": "1/2 tsp", "bid": "black-pepper", "gpu": "50.000" },
                               { "item": "Rice", "grams": 1000, "buy": "1 lb", "bid": "rice", "gpu": "453.592" },
                               { "item": "Olive Oil", "grams": 42, "buy": "3 tbsp", "bid": "olive-oil", "gpu": "453.592" },
                               { "item": "Diced Tomatoes", "grams": 411, "buy": "1 can", "bid": "diced-tomatoes", "gpu": "411.000" },
                               { "item": "Mozzarella Cheese", "grams": 510, "buy": "3 oz cubed + 3/4 cup shredded", "bid": "mozzarella", "gpu": "453.592" },
                               { "item": "Salt", "grams": 15, "buy": "2 tbsp", "bid": "salt", "gpu": "737.000" },
                               { "item": "Garlic", "grams": 35, "buy": "3 tsp minced", "bid": "garlic", "gpu": "50.000" }
                           ]
               },
    "head":  {
                 "description":  "A skillet dinner.",
                 "recipeIngredient":  [
                                          "5 lb 93/7 Ground Beef",
                                          "1/2 tsp Black Pepper",
                                          "1 lb Rice",
                                          "3 tbsp Olive Oil"
                                      ]
             }
}
'@
        [System.IO.File]::WriteAllText((Join-Path $T 'recipes\fx.json'), $fx, (New-Object System.Text.UTF8Encoding($false)))
        # The verdict table the repair reads. Note Salt is grams-suspect (the kalua row's shape) and
        # Mozzarella carries a second quantity in its tail - both must survive untouched.
        @'
"Slug","Item","Buy","Grams","Ratio","Verdict","Evidence"
"fx","Black Pepper","1/2 tsp","4","3.48","label-is-source-unscaled","source says 1/2 teaspoon at 4 servings"
"fx","Rice","1 lb","1000","2.2","filler-label","constant label across the catalog"
"fx","Salt","2 tbsp","15","0.42","grams-suspect","label matches the scaled source amount; the GRAMS are the doubtful side"
"fx","Mozzarella Cheese","3 oz cubed + 3/4 cup shredded","510","6","label-is-source-unscaled","source states both parts verbatim"
"fx","Garlic","3 tsp minced","35","4.17","label-is-source-unscaled","source says 3 teaspoons minced garlic"
"fx","Diced Tomatoes","1 can","411","1","label-is-source-unscaled","not flagged - a true package label"
'@ | Set-Content (Join-Path $T 'verdicts.csv') -Encoding UTF8

        $r = Invoke-MeasureRepair (Join-Path $T 'recipes') (Join-Path $T 'verdicts.csv') $true
        $io2 = Read-SpecText (Join-Path $T 'recipes\fx.json')
        $s = $io2.Text | ConvertFrom-Json
        $by = @{}; foreach ($i in @($s.scaler.ing)) { $by[[string]$i.item] = [string]$i.buy }
        $dl = @($s.ingredients_display)
        $cl = @($s.cost_lines) -join ' || '
        $ri = @($s.head.recipeIngredient) -join ' || '
        $notes = ($r.notes -join ' ;; ')

        # ---- MUST FIRE ---------------------------------------------------------------------------
        Chk 'MUST FIRE  a source-unscaled spice label becomes the amount the recipe uses' ($by['Black Pepper'] -eq '1.75 tsp') ($by['Black Pepper'])
        Chk 'MUST FIRE  the filler "1 lb" becomes a real rice measure' ($by['Rice'] -eq '5.5 cups dry') ($by['Rice'])
        Chk 'MUST FIRE  the writer tail rides through the rewrite' ($by['Garlic'] -eq '4 tbsp minced') ($by['Garlic'])
        Chk 'MUST FIRE  the display line keeps item, brand, markup and gram count' ($dl[1] -eq '<strong>Black Pepper (Great Value):</strong> 1.75 tsp (4 g)') ($dl[1])
        Chk 'MUST FIRE  cost_lines restate the new size token' ($cl -match 'Black Pepper, 1\.75 tsp: ~\$0\.12' -and $cl -match 'Rice, 5\.5 cups dry:') ($cl)
        Chk 'MUST FIRE  the JSON-LD Google reads is repaired too, not just the visible card' ($ri -match '1\.75 tsp Black Pepper' -and $ri -match '5\.5 cups dry Rice') ($ri)

        # ---- REFUSALS - the whole reason this script is not a sweep -------------------------------
        Chk 'REFUSE    a grams-suspect row is left EXACTLY as it was (the kalua salt shape)' ($by['Salt'] -eq '2 tbsp') ($by['Salt'])
        Chk 'REFUSE    and it says why, naming the grams as the doubtful side' ($notes -match 'grams-suspect') ($notes)
        Chk 'REFUSE    a tail carrying a SECOND quantity is not spliced' ($by['Mozzarella Cheese'] -eq '3 oz cubed + 3/4 cup shredded') ($by['Mozzarella Cheese'])
        Chk 'REFUSE    and it says why' ($notes -match 'second quantity') ($notes)

        # ---- CLEAN TWINS - labels that must survive a sweep untouched -----------------------------
        Chk 'CLEAN TWIN a label that already agrees with its grams is untouched' ($by['Olive Oil'] -eq '3 tbsp') ($by['Olive Oil'])
        Chk 'CLEAN TWIN a TRUE package label ("1 can" = 411 g) is untouched' ($by['Diced Tomatoes'] -eq '1 can') ($by['Diced Tomatoes'])
        Chk 'CLEAN TWIN the untouched bulk row keeps its label' ($by['93/7 Ground Beef'] -eq '5 lb') ($by['93/7 Ground Beef'])

        # ---- INVARIANTS ---------------------------------------------------------------------------
        Chk 'NOT ONE GRAM MOVED' ((@($s.scaler.ing) | Where-Object { $_.grams -notin @(2240,4,1000,42,411,510,15,35) }).Count -eq 0) 'a gram figure changed'
        Chk 'no cost field moved' (([string]$s.cost_first_run -eq '31.20') -and ([string]$s.cost_per_serving -eq '2.23')) 'a cost field changed'
        Chk 'no macro moved' (([string]$s.stat.cal -eq '540') -and ([string]$s.stat.protein -eq '44')) 'a macro changed'
        Chk 'display and buy always agree' ((@($s.scaler.ing) | Where-Object { ($dl -join '|') -notmatch [regex]::Escape([string]$_.buy) }).Count -eq 0) 'a display line disagrees with its buy'
        Chk 'parallel arrays keep length and order' ((@($s.scaler.ing).Count -eq 8) -and (@($dl).Count -eq 8) -and ($dl[0] -match 'Ground Beef')) 'arrays moved'
        Chk 'prose with { [ and an escaped quote survives byte for byte' ($s.intro_html -eq 'A <strong>brace { and a bracket [ inside prose</strong>, plus a quote " for good measure.') ($s.intro_html)
        Chk 'no BOM was added to a file that had none' ((-not $io2.Bom)) ('bom=' + $io2.Bom)

        $r2 = Invoke-MeasureRepair (Join-Path $T 'recipes') (Join-Path $T 'verdicts.csv') $true
        Chk 'idempotent - a second pass rewrites nothing' ($r2.lines -eq 0) ("lines=" + $r2.lines)

        # ---- A STALE VERDICT MUST NOT FIRE --------------------------------------------------------
        # The evidence was gathered against a specific label. If the spec has moved on, the verdict no
        # longer describes that row, and acting on it would be ratifying a judgement nobody made.
        @'
"Slug","Item","Buy","Grams","Ratio","Verdict","Evidence"
"fx","Olive Oil","1 tbsp","42","3.11","label-is-source-unscaled","stale - the spec now says 3 tbsp"
'@ | Set-Content (Join-Path $T 'stale.csv') -Encoding UTF8
        $r3 = Invoke-MeasureRepair (Join-Path $T 'recipes') (Join-Path $T 'stale.csv') $true
        Chk 'MUST FIRE  a verdict whose label no longer matches the spec is REFUSED, not applied' (($r3.lines -eq 0) -and (($r3.notes -join ' ') -match 'the verdict was reached against')) (($r3.notes -join ' '))

        # ---- the SERVING SCALER must survive every label this repair writes -----------------------
        # scaleBuy moves only the leading quantity, so the unit and any tail have to ride through.
        # NOTE the style change on the way out: these labels are STORED in FriendlyAmt's decimal style
        # ("1.75 tsp") and the widget re-renders them through Format-CmQty's kitchen fractions
        # ("3 1/2 tsp"). That is the catalog's existing behaviour on all 5,704 builder-written labels,
        # not something this repair introduces, and the fraction form is the friendlier of the two.
        $sc = @(
            @('1.75 tsp',       2.0, '3 1/2 tsp',      'a decimal tsp doubles into the widget fraction style'),
            @('5.5 cups dry',   2.0, '11 cups dry',    'the "dry" tail is carried, not scaled'),
            @('4 tbsp minced',  2.0, '8 tbsp minced',  'a word tail is carried'),
            @('3 tbsp',         0.5, '1 1/2 tbsp',     'halving lands on the widget fraction style')
        )
        $scBad = @()
        foreach ($c in $sc) {
            $got = Invoke-CmScaleBuy ([string]$c[0]) ([double]$c[1])
            if ($got -ne [string]$c[2]) { $scBad += ("'{0}' x{1} -> '{2}' want '{3}'" -f $c[0], $c[1], $got, $c[2]) }
        }
        Chk 'serving scaler: only the leading quantity moves' ($scBad.Count -eq 0) ($scBad -join ' | ')

        # ---- repair-cook-measures must not undo this work ------------------------------------------
        $dens = (Read-JsonFile (Join-Path $mp 'db\densities.json')).items
        $survives = @( @('Black Pepper','1.75 tsp',4), @('Rice','5.5 cups dry',1000), @('Olive Oil','3 tbsp',42) )
        $bad = @()
        foreach ($c in $survives) {
            if (-not (Test-CmLabelTrue $dens ([string]$c[0]) ([string]$c[1]) ([double]$c[2]))) { $bad += ("{0}: '{1}' @ {2} g" -f $c[0], $c[1], $c[2]) }
        }
        Chk 'every label written here proves true to repair-cook-measures' ($bad.Count -eq 0) ($bad -join ' | ')

        # ---- the port this repair derives through still matches the builder ----------------------
        $fid = Test-FriendlyAmtAgainstCatalog -Root $mp
        Chk 'friendly-amt-lib still reproduces the builder (>=5000 catalog labels byte for byte)' ($fid.exact -ge 5000) ("exact=" + $fid.exact + "/" + $fid.rows)
    } finally { Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue }
    if ($fail -eq 0) { Write-Output 'SELF-TEST PASS'; exit 0 } else { Write-Output "SELF-TEST FAIL: $fail case(s)"; exit 1 }
}

Initialize-FriendlyAmt -Root $mp
$verdicts = Join-Path $mp 'out\measure-vs-grams-verdicts.csv'
if (-not (Test-Path $verdicts)) { throw "no verdict table at $verdicts - this repair acts only on rows a source check has decided" }

if ($Report) {
    $v = Import-Csv $verdicts
    "measure-vs-grams verdicts ({0} rows across {1} recipes)" -f $v.Count, (@($v | Group-Object Slug)).Count
    $v | Group-Object Verdict | Sort-Object Count -Descending | ForEach-Object { "  {0,5}  {1}" -f $_.Count, $_.Name }
    ""
    "rows this repair will NOT touch, and why:"
    foreach ($row in ($v | Where-Object { $script:MVG_REPAIRABLE -notcontains $_.Verdict } | Sort-Object Verdict, Slug)) {
        "  [{0}] {1,-42} {2,-20} '{3}' vs {4} g" -f $row.Verdict, $row.Slug, $row.Item, $row.Buy, $row.Grams
    }
    exit 0
}

$res = Invoke-MeasureRepair (Join-Path $mp 'db\recipes') $verdicts ([bool]$Apply)
Write-Output ("measure-vs-grams repair: {0} line(s) across {1} recipe(s){2}" -f $res.lines, $res.recipes, $(if ($Apply) { '' } else { '  [read-only - pass -Apply]' }))
foreach ($s in $res.samples) { Write-Output ('    ' + $s) }
if ($res.notes.Count) {
    Write-Output ("`n  LEFT ALONE ({0}) - a row this repair will not decide on its own:" -f $res.notes.Count)
    foreach ($n in $res.notes) { Write-Output ('    ' + $n) }
}
if ($Apply -and $res.slugs.Count) {
    New-Item -ItemType Directory -Force (Join-Path $mp 'out') | Out-Null
    ($res.slugs -join "`n") | Set-Content (Join-Path $mp 'out\measure-vs-grams-slugs.txt') -Encoding UTF8
    Write-Output "`n  slug list -> out\measure-vs-grams-slugs.txt (rebuild + republish these cards)"
    # THE CARRY MANIFEST. recipes-db.json keeps its own copy of every buy string and gen-planner-data.ps1
    # reads THAT, so a repair that stops at the specs leaves the Meal Plan Builder's grocery list showing
    # the old label indefinitely. sync-recipesdb-buy.ps1 refuses to carry anything it cannot prove; this
    # file is the proof, recording the exact rows this run rewrote, old and new byte for byte.
    ($res.carry | ConvertTo-Json -Depth 4) | Set-Content (Join-Path $mp 'out\measure-vs-grams-carry.json') -Encoding UTF8
    Write-Output ('  carry manifest -> out\measure-vs-grams-carry.json (' + $res.carry.Count + ' row(s); sync-recipesdb-buy.ps1 reads this)')
}
exit 0
