<#
  repair-scaled-notes.ps1 - take the writer's scaling note off the card and put the recipe's OWN
  quantity in front of it.

  THE DEFECT (2026-08-04, found alongside the unitless-buy repair and deliberately held back from it
  because it needed a source check rather than a mechanical rewrite). Seven ingredient labels across two
  specs shipped an authoring note to the reader, with the UNSCALED quantity still in front of it:

      Yellow Onion: 1 (scaled ~3) (330 g)              <- 330 g is three onions, not one
      Garlic: 1 clove (scaled ~4) (25 g)               <- 25 g is ~3 tbsp minced, not one clove
      Olive Oil: 1/2 tbsp (scaled ~2-3 tbsp) (40 g)    <- half a tbsp will not sweat 540 g of vegetables

  Two defects in one string. "(scaled ~N)" is a note-to-self about scaling a base recipe up to 14
  servings and was never meant for a reader, and the leading amount is the UNSCALED base, so the label
  contradicts the gram figure printed beside it.

  WHICH SIDE IS WRONG, and why this is NOT the inference cook-measure-lib refuses to make.
  cook-measure-lib.ps1:152-158 refuses to rewrite a measure-vs-grams disagreement, because there either
  the label or the GRAMS may be the error and the grams drive cost and macros - agreeing with a gram
  figure that is itself wrong would launder a data bug into a confident-looking measurement. That refusal
  is right, and it does not apply here, for a reason visible in the label itself: "(scaled ~3)" is the
  writer stating that the leading number is NOT this recipe's amount. The label is not a competing
  measurement to be weighed against the grams; it is a confession that no amount was ever stated. There
  is nothing to launder, because replacing it moves no number - cost, macros and the gram figure are all
  untouched. Only the sentence changes.

  The grams were still checked before being trusted, one recipe at a time:

    slow-cooker-salsa-verde-chicken-bowl - source (realfoodwholelife.com, 5 servings) contains NO onion
    and NO bell pepper; both are this recipe's own additions, so the "1" was never a source quantity to
    preserve. Three independent signals fix the scale-up at ~3x: chicken 2 lb -> 6 lb, cumin 1 tsp ->
    1 tbsp, servings 5 -> 14. The grams land exactly there - 330 g / 110 g per onion = 3.0, and
    350 g / 120 g per pepper = 2.9. Confirmed.

    turkey-bolognese-penne - has NO source_url and never had one (archive\orig\specs agrees), so it
    cannot be checked against a source at all. What can be said: the label is wrong on its face whatever
    the grams say (one clove of garlic and half a tablespoon of oil do not season a 14-serving pot), and
    the grams are a textbook soffritto for the batch they sit in - 200 g onion, 200 g carrot, 140 g
    celery, 25 g garlic against 1587 g turkey and 1076 g sauce. Judged sound, and flagged as
    source-unverifiable rather than quietly treated as verified.

  THE REPLACEMENT IS THE GENERATOR'S OWN. Every label below is what build-v2-spec.ps1's FriendlyAmt
  derives from the grams, run verbatim rather than hand-computed, so a future regeneration is idempotent
  instead of re-introducing a hand-written string. That also keeps them on the catalog's convention:
  302 of 331 Yellow Onion labels say "N onions", 72 of 78 Carrots say "N carrots", 282 Garlic labels say
  "N tbsp", 29 Celery say "N stalks".

  WHY THIS IS A SEPARATE PASS FROM repair-unitless-buy.ps1. Its $OVERRIDES table cannot reach these rows:
  it skips any buy containing a letter (line 88, `if ($buy -match '[A-Za-z]') { continue }`) BEFORE the
  override lookup on line 91, and every one of these strings contains "scaled". Moving the override above
  that guard would change what the guard means for the other 512 specs. This defect also reaches a
  surface that repair has no reason to touch - see below.

  WHAT THIS TOUCHES. The unitless repair patches three surfaces; this one patches FOUR, because the note
  also leaked into the JSON-LD published to Google (turkey-bolognese-penne carries "1/2 onion
  (scaled ~1.75) Yellow Onion" and "1 clove (scaled ~4) Garlic" in head.recipeIngredient). A three-surface
  fix would have left the note live in the structured data while the visible card read clean.
      scaler.ing[].buy         "1 (scaled ~3)"                    -> "3 onions"
      ingredients_display[]    "... 1 (scaled ~3) (330 g)"        -> "... 3 onions (330 g)"
      cost_lines[]             "Yellow Onion, 1 (scaled ~3): ..." -> "Yellow Onion, 3 onions: ..."
      head.recipeIngredient[]  "1 clove (scaled ~4) Garlic"       -> "3 tbsp Garlic"

  Every edit is a targeted splice via the string-aware scanners in lib\json-db-io.ps1. SPEC-SCHEMA.md
  forbids ConvertFrom-Json | ConvertTo-Json on a spec, and each file's existing BOM state is preserved.

  Read-only unless -Apply.
  Usage: .\repair-scaled-notes.ps1 [-Apply]   |   .\repair-scaled-notes.ps1 -SelfTest
#>
param([switch]$Apply, [switch]$SelfTest, [string]$Root = "")
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp = if ($Root) { $Root } else { Split-Path -Parent $here }
. (Join-Path $mp 'lib\json-db-io.ps1')

# The marker that identifies an authoring note. Deliberately narrow: a parenthetical is NOT by itself a
# defect ("2 boxes (14.5 oz each)" and "3 oz, from a jar" are real, reader-facing detail), so only the
# literal "(scaled ~" opener counts, and only a row named in $LABELS is ever rewritten.
$NOTE_RX = '\(scaled ~'

# ---------------------------------------------------------------------------------------------------
# HAND-CHECKED LABELS. slug -> item -> the replacement buy. Each value is FriendlyAmt's own output for
# that item at that gram weight; the self-test re-derives them so a densities edit that would change one
# fails here instead of silently disagreeing with the rest of the catalog.
# ---------------------------------------------------------------------------------------------------
$LABELS = @{
    'slow-cooker-salsa-verde-chicken-bowl' = @{
        'Yellow Onion'       = '3 onions'      # 330 g / 110 g each
        'Green Bell Peppers' = '3 peppers'     # 350 g / 120 g each
    }
    'turkey-bolognese-penne' = @{
        'Yellow Onion' = '2 onions'           # 200 g / 110 g each = 1.8, snapped by FriendlyAmt's +/-0.25 rule
        'Garlic'       = '3 tbsp'             # 25 g / 8.5 g per tbsp minced
        'Olive Oil'    = '3 tbsp'             # 40 g / 13.5 g per tbsp
        'Carrots'      = '3.3 carrots'        # 200 g / 61 g each - outside the snap window, so it stays fractional
        'Celery'       = '2.5 stalks'         # 140 g / 55 g per stalk
    }
}

# ORPHAN NAME - RESOLVED 2026-08-04, kept because it is why the bell pepper row was hand-labelled at all.
# This spec used to call the item "Green Bell Pepper" while the other 65 rows in the catalog call it
# "Green Bell Peppers", and densities.json is keyed on the plural. So Den missed on BOTH 'can' and 'each',
# FriendlyAmt fell all the way through to its final oz fallback, and derived "12.25 oz" for 350 g - which
# is why a writer typed a label by hand. The singular was a pre-r100 legacy name: archive\orig\
# cost-engine.ps1 lists 'Green Bell Pepper'=@{g=119}, and every era after it lists 'Green Bell
# Peppers'=@{g=120}. It survived migration in this one spec and in the four dictionaries seeded from that
# era (db\ingredients.json, ingredient-map.json, planner-extra-packages.json, db\each-nouns.json), the
# ingredients row still carrying the stale 119 g package.
#
# Fixed by RENAME rather than by an alias: an alias would have left two names for one food - and left the
# 119/120 package split in place, so this recipe alone would keep costing a 119 g pepper. The name is now
# plural everywhere in live data, so FriendlyAmt('Green Bell Peppers', 350) resolves the each branch on
# its own and re-derives "3 peppers"; the label below is no longer load-bearing, and a regeneration of
# this spec can no longer re-introduce the nonsense one. The singular survives ONLY in archive\ and in
# sync-recipesdb-buy.ps1's third frozen fixture, where it is the founding bug and must NOT be renamed.

function Repair-SpecScaledNotes {
    <# Returns @{ changed; text; notes; edits } for ONE spec. Pure text in, text out, so the self-test
       drives exactly the same code path the catalog run does. #>
    param(
        [Parameter(Mandatory)][string]$Raw,
        [Parameter(Mandatory)]$Spec,
        $Labels = $null              # @{ "<item>" = "<explicit new buy>" } for this slug
    )
    $ing  = @($Spec.scaler.ing)
    $disp = @($Spec.ingredients_display)
    if ($ing.Count -ne $disp.Count) { throw ("parallel arrays disagree: scaler.ing $($ing.Count) vs ingredients_display $($disp.Count)") }

    # Decide every edit BEFORE touching the text, so a spec is either fully patched or not at all.
    $edits = New-Object System.Collections.Generic.List[object]
    $notes = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $ing.Count; $i++) {
        $buy = [string]$ing[$i].buy
        if ($buy -notmatch $NOTE_RX) { continue }            # no authoring note - not our defect
        $item = [string]$ing[$i].item
        # REFUSE RATHER THAN GUESS. Stripping the note and keeping the leading number would leave the
        # label stating the unscaled amount as if it were the recipe's - a quieter version of the same
        # bug, and one no reader could detect. A row we have not checked by hand is reported, not fixed.
        if (-not $Labels -or -not $Labels.ContainsKey($item)) {
            $notes.Add("no hand-checked label for '$item' (buy '$buy', $([int]$ing[$i].grams) g) - LEFT ALONE, still leaking")
            continue
        }
        $edits.Add([pscustomobject]@{ Index = $i; Item = $item; Old = $buy; New = [string]$Labels[$item]; Grams = [int]$ing[$i].grams })
    }
    if ($edits.Count -eq 0) { return @{ changed = 0; text = $Raw; notes = @($notes.ToArray()); edits = @() } }

    $text = $Raw

    # ---- 1. scaler.ing[i].buy ------------------------------------------------------------------
    # Scoped: locate the scaler object, then its ing array, then the i-th element, then buy INSIDE it.
    # A bare search for "buy" would hit the first ingredient every time.
    $scalerAt = Find-JsonValueStart -Raw $text -Key 'scaler'
    if ($scalerAt -lt 0) { throw 'no "scaler" key' }
    $ingAt = Find-JsonValueStart -Raw $text -Key 'ing' -From $scalerAt
    if ($ingAt -lt 0) { throw 'no "scaler"."ing" key' }
    $spans = @(Get-JsonArraySpans -Raw $text -OpenIndex $ingAt)
    if ($spans.Count -ne $ing.Count) { throw ("scaler.ing span walk found $($spans.Count) elements, parser says $($ing.Count)") }
    # Apply from the LAST edit backwards so earlier spans keep their offsets.
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

    # ---- 2. ingredients_display[i] -------------------------------------------------------------
    # The amount is the tail "<old> (<grams> g)" at the very end of the element, so anchoring on the
    # grams as well as the amount makes the match unambiguous even when two ingredients share a label.
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

    # ---- 3. cost_lines --------------------------------------------------------------------------
    # Neither affected spec carries one today, but the sweep is written for the defect and not for the
    # two files that happen to have it, and spec-guards reads this array.
    $clAt = Find-JsonValueStart -Raw $text -Key 'cost_lines'
    if ($clAt -ge 0) {
        $cspans = @(Get-JsonArraySpans -Raw $text -OpenIndex $clAt)
        foreach ($e in @($edits | Sort-Object Index -Descending)) {
            $prefix = '"' + $e.Item + ', ' + $e.Old + ':'
            $hits = @($cspans | Where-Object { $text.Substring($_.Start, [Math]::Min($prefix.Length, $_.End - $_.Start + 1)) -eq $prefix })
            if ($hits.Count -eq 0) { continue }                 # bulk/pantry items have no buy line - fine
            if ($hits.Count -gt 1) { $notes.Add("cost_lines: '$($e.Item), $($e.Old):' matched $($hits.Count) lines - skipped"); continue }
            $sp = $hits[0]
            $newPrefix = '"' + $e.Item + ', ' + $e.New + ':'
            $text = $text.Substring(0, $sp.Start) + $newPrefix + $text.Substring($sp.Start + $prefix.Length)
            $cspans = @(Get-JsonArraySpans -Raw $text -OpenIndex (Find-JsonValueStart -Raw $text -Key 'cost_lines'))
        }
    }

    # ---- 4. head.recipeIngredient ---------------------------------------------------------------
    # THE SURFACE A THREE-SURFACE FIX MISSES. Hand-written by the writers, published as JSON-LD, and it
    # carries the note verbatim. These entries are free prose ("1 clove (scaled ~4) Garlic"), so the edit
    # is a substring replace of the old label inside the one element that holds it - and it must hold it
    # exactly once, or we do not know which occurrence is the amount.
    $headAt = Find-JsonValueStart -Raw $text -Key 'head'
    if ($headAt -ge 0) {
        $riAt = Find-JsonValueStart -Raw $text -Key 'recipeIngredient' -From $headAt
        if ($riAt -ge 0) {
            # .ToArray() and NOT @($edits) - measured on PS 5.1.26100: wrapping a
            # System.Collections.Generic.List[object] in @() throws "Argument types do not match", even
            # when the list is EMPTY. The @($pipeline | Sort-Object ...) forms above are safe because the
            # pipeline unrolls to an array before @() ever sees the List. Sibling of the ps51 array traps
            # already documented in lib\json-db-io.ps1.
            foreach ($e in $edits.ToArray()) {
                $rspans = @(Get-JsonArraySpans -Raw $text -OpenIndex (Find-JsonValueStart -Raw $text -Key 'recipeIngredient' -From (Find-JsonValueStart -Raw $text -Key 'head')))
                $hits = @($rspans | Where-Object { $text.Substring($_.Start, $_.End - $_.Start + 1).Contains($e.Old) })
                if ($hits.Count -eq 0) { continue }             # most items are not restated in the JSON-LD
                if ($hits.Count -gt 1) { $notes.Add("head.recipeIngredient: '$($e.Old)' matched $($hits.Count) entries - skipped"); continue }
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

function Invoke-ScaledNoteRepair([string]$specDir, [bool]$apply, $labelsBySlug) {
    $lines = 0; $recipes = 0
    $slugs = New-Object System.Collections.Generic.List[string]
    $samples = New-Object System.Collections.Generic.List[string]
    $notes = New-Object System.Collections.Generic.List[string]
    $carry = New-Object System.Collections.Generic.List[object]
    foreach ($f in @(Get-ChildItem (Join-Path $specDir '*.json') | Where-Object { $_.Name -ne '_index.json' })) {
        $io = Read-SpecText $f.FullName
        if ($io.Text -notmatch $NOTE_RX) { continue }           # cheap pre-filter over 513 files
        $spec = $io.Text | ConvertFrom-Json
        if (-not $spec.scaler -or -not $spec.scaler.ing) { continue }
        $lb = $null
        if ($labelsBySlug -and $labelsBySlug.ContainsKey($f.BaseName)) { $lb = $labelsBySlug[$f.BaseName] }
        $r = Repair-SpecScaledNotes -Raw $io.Text -Spec $spec -Labels $lb
        foreach ($n in $r.notes) { $notes.Add($f.BaseName + ' :: ' + $n) }
        if ($r.changed -eq 0) { continue }
        foreach ($e in $r.edits) {
            $samples.Add(("{0,-38} {1,-20} '{2}' -> '{3}'   ({4} g)" -f $f.BaseName, $e.Item, $e.Old, $e.New, $e.Grams))
            $carry.Add([pscustomobject]@{ slug = $f.BaseName; item = $e.Item; old = $e.Old; new = $e.New; grams = $e.Grams })
        }

        # POST-CONDITIONS on every file, before it is written.
        $after = $r.text | ConvertFrom-Json
        $ai = @($after.scaler.ing); $ad = @($after.ingredients_display)
        if ($ai.Count -ne $ad.Count) { throw ("$($f.BaseName): parallel arrays diverged during repair") }
        for ($k = 0; $k -lt $ai.Count; $k++) {
            # the widget re-renders the list from scaler.ing[].buy the moment a reader changes servings,
            # so a display-only fix would silently change the list under them
            if ([string]$ad[$k] -notmatch [regex]::Escape([string]$ai[$k].buy)) {
                throw ("$($f.BaseName): display line $k no longer carries its buy '$([string]$ai[$k].buy)'")
            }
        }
        # THE WHOLE POINT: not one authoring note may survive anywhere in the file, including the
        # JSON-LD. A file with an unlabelled row still leaking is caught here rather than shipped.
        if ($r.text -match $NOTE_RX) {
            throw ("$($f.BaseName): an authoring note SURVIVED the repair - " + (($r.notes) -join '; '))
        }
        $lines += $r.changed; $recipes++; $slugs.Add($f.BaseName)
        if ($apply) { Write-SpecText -Path $f.FullName -Text $r.text -Bom $io.Bom }
    }
    return @{ lines = $lines; recipes = $recipes; slugs = @($slugs.ToArray()); samples = @($samples.ToArray()); notes = @($notes.ToArray()); carry = @($carry.ToArray()) }
}

if ($SelfTest) {
    $fail = 0
    function Chk([string]$label, [bool]$cond, [string]$got) {
        if ($cond) { Write-Output ("ok    " + $label) } else { Write-Output ("FAIL  " + $label + "   got: " + $got); $script:fail++ }
    }
    $T = Join-Path $env:TEMP ('scalednote-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path (Join-Path $T 'recipes') -Force | Out-Null
    try {
        # FROZEN FIXTURE - the founding bug verbatim off Brad's two cards, plus a clean twin of every
        # refusal. Written as raw text, not ConvertTo-Json, because the point is the SPLICE: the prose
        # below carries < escapes, braces and a bracket inside string literals, which is what broke naive
        # brace counting and is why lib\json-db-io.ps1 grew string-aware scanners.
        #
        # Row 3 (Penne Pasta) is the CLEAN TWIN that matters most: a legitimate parenthetical, in the same
        # shape as the defect, which must survive untouched. A repair that stripped parentheses generally
        # would eat it.
        $fx = @'
{
    "slug":  "fx",
    "intro_html":  "A <strong>brace { and a bracket [ inside prose</strong>, plus a quote \" for good measure.",
    "ingredients_display": ["<strong>93/7 Ground Turkey (Jennie-O):</strong> 3.5 lb raw (1587 g)","<strong>Yellow Onion:</strong> 1 (scaled ~3) (330 g)","<strong>Garlic:</strong> 1 clove (scaled ~4) (25 g)","<strong>Penne Pasta (Barilla):</strong> 7 1/4 cups (14.5 oz each) (719 g)","<strong>Celery:</strong> 1 rib (scaled ~3) (140 g)"],
    "cost_lines":  [
                       "Yellow Onion, 1 (scaled ~3): ~$0.84. <strong>Buy 1 lb: $1.14.</strong>",
                       "Garlic, 1 clove (scaled ~4): ~$0.35. <strong>Buy 1 bulb: $0.68.</strong>"
                   ],
    "scaler":  {
                   "cost":  "35.05",
                   "ing":  [
                               { "item": "93/7 Ground Turkey", "grams": 1587, "buy": "3.5 lb raw", "bid": "93-7-ground-turkey", "gpu": "453.592" },
                               { "item": "Yellow Onion", "grams": 330, "buy": "1 (scaled ~3)",     "bid": "onions", "gpu": "453.592" },
                               { "item": "Garlic",       "grams": 25,  "buy": "1 clove (scaled ~4)", "bid": "garlic", "gpu": "50.000" },
                               { "item": "Penne Pasta",  "grams": 719, "buy": "7 1/4 cups (14.5 oz each)", "bid": "penne", "gpu": "453.592" },
                               { "item": "Celery",       "grams": 140, "buy": "1 rib (scaled ~3)", "bid": "celery", "gpu": "453.592" }
                           ]
               },
    "head":  {
                 "description":  "A lean bolognese.",
                 "recipeIngredient":  [
                                          "3.5 lb raw 93/7 Ground Turkey",
                                          "1 (scaled ~3) Yellow Onion",
                                          "1 clove (scaled ~4) Garlic",
                                          "7 1/4 cups (14.5 oz each) Penne Pasta"
                                      ]
             }
}
'@
        [System.IO.File]::WriteAllText((Join-Path $T 'recipes\fx.json'), $fx, (New-Object System.Text.UTF8Encoding($false)))

        $labels = @{ 'fx' = @{ 'Yellow Onion' = '3 onions'; 'Garlic' = '3 tbsp'; 'Celery' = '2.5 stalks' } }
        $r = Invoke-ScaledNoteRepair (Join-Path $T 'recipes') $true $labels
        $io2 = Read-SpecText (Join-Path $T 'recipes\fx.json')
        $s = $io2.Text | ConvertFrom-Json
        $by = @{}; foreach ($i in @($s.scaler.ing)) { $by[[string]$i.item] = [string]$i.buy }
        $dl = @($s.ingredients_display)
        $cl = @($s.cost_lines) -join ' || '
        $ri = @($s.head.recipeIngredient) -join ' || '

        Chk 'MUST FIRE  the note is gone and the SCALED amount replaces the unscaled one' ($by['Yellow Onion'] -eq '3 onions') ($by['Yellow Onion'])
        Chk 'MUST FIRE  a label whose unit also changes (clove -> tbsp) is replaced whole' ($by['Garlic'] -eq '3 tbsp') ($by['Garlic'])
        Chk 'MUST FIRE  a fractional count is not rounded away' ($by['Celery'] -eq '2.5 stalks') ($by['Celery'])
        Chk 'MUST FIRE  the note is gone from the JSON-LD too, not just the visible card' ($ri -notmatch $NOTE_RX) ($ri)
        Chk 'MUST FIRE  the JSON-LD keeps its trailing item name' ($ri -match '3 onions Yellow Onion' -and $ri -match '3 tbsp Garlic') ($ri)
        Chk 'CLEAN TWIN a LEGITIMATE parenthetical is untouched' ($by['Penne Pasta'] -eq '7 1/4 cups (14.5 oz each)') ($by['Penne Pasta'])
        Chk 'CLEAN TWIN the same parenthetical survives in the JSON-LD' ($ri -match '7 1/4 cups \(14\.5 oz each\) Penne Pasta') ($ri)
        Chk 'CLEAN TWIN a label with no note at all is untouched' ($by['93/7 Ground Turkey'] -eq '3.5 lb raw') ($by['93/7 Ground Turkey'])
        Chk 'the display line keeps its item, brand, markup and gram count' ($dl[1] -eq '<strong>Yellow Onion:</strong> 3 onions (330 g)') ($dl[1])
        Chk 'display and buy always agree' ((@($s.scaler.ing) | Where-Object { ($dl -join '|') -notmatch [regex]::Escape([string]$_.buy) }).Count -eq 0) 'a display line disagrees with its buy'
        Chk 'parallel arrays keep their length and order' ((@($s.scaler.ing).Count -eq 5) -and (@($dl).Count -eq 5) -and ($dl[0] -match 'Ground Turkey')) 'arrays moved'
        Chk 'cost_lines restate the same size token' ($cl -match 'Yellow Onion, 3 onions: ~\$0\.84' -and $cl -match 'Garlic, 3 tbsp: ~\$0\.35') ($cl)
        Chk 'no authoring note survives ANYWHERE in the file' ($io2.Text -notmatch $NOTE_RX) 'a note survived'
        # THE SCANNER'S REASON FOR EXISTING: prose with braces, brackets and an escaped quote survives.
        Chk 'prose with { [ and an escaped quote survives byte for byte' ($s.intro_html -eq 'A <strong>brace { and a bracket [ inside prose</strong>, plus a quote " for good measure.') ($s.intro_html)
        Chk 'no BOM was added to a file that had none' ((-not $io2.Bom)) ('bom=' + $io2.Bom)

        $r2 = Invoke-ScaledNoteRepair (Join-Path $T 'recipes') $true $labels
        Chk 'idempotent - a second pass rewrites nothing' ($r2.lines -eq 0) ("lines=" + $r2.lines)

        # ---- REFUSE RATHER THAN GUESS -------------------------------------------------------------
        # An unlabelled row must be REPORTED and left alone, and because a surviving note then trips the
        # post-condition, the whole file is refused rather than half-fixed.
        [System.IO.File]::WriteAllText((Join-Path $T 'recipes\fx.json'), $fx, (New-Object System.Text.UTF8Encoding($false)))
        $partial = @{ 'fx' = @{ 'Yellow Onion' = '3 onions' } }        # Garlic and Celery deliberately absent
        $threw = $false; $msg = ''
        try { Invoke-ScaledNoteRepair (Join-Path $T 'recipes') $true $partial } catch { $threw = $true; $msg = $_.Exception.Message }
        Chk 'MUST FIRE  an unlabelled leaking row REFUSES the whole file instead of half-fixing it' ($threw -and $msg -match 'SURVIVED') ($msg)
        $io3 = Read-SpecText (Join-Path $T 'recipes\fx.json')
        Chk 'and the refused file is left byte-identical on disk' ($io3.Text -eq $fx) 'the file was modified despite the refusal'

        # ---- the SERVING SCALER must survive the labels this repair writes -------------------------
        # scaleBuy moves only the leading quantity, so the noun has to ride through untouched.
        . (Join-Path $here 'cook-measure-lib.ps1')
        $sc = @(
            @('3 onions',    2.0, '6 onions',    'a whole count doubles cleanly'),
            @('3 tbsp',      0.5, '1 1/2 tbsp',  'a measure halves into the widget fraction style'),
            @('2.5 stalks',  2.0, '5 stalks',    'a fractional count scales to a whole one'),
            # 3.3 x 3 = 9.9, and the widget quarter-rounds every unit it renders (the same rule as Frac),
            # so it prints "10 carrots". That is its behaviour for "9.9 lb" too - not something a count
            # noun introduces - and it is why the label carries the gram figure beside it.
            @('3.3 carrots', 3.0, '10 carrots',  'a fractional count quarter-rounds on scale-up')
        )
        $scBad = @()
        foreach ($c in $sc) {
            $got = Invoke-CmScaleBuy ([string]$c[0]) ([double]$c[1])
            if ($got -ne [string]$c[2]) { $scBad += ("'{0}' x{1} -> '{2}' want '{3}'" -f $c[0], $c[1], $got, $c[2]) }
        }
        Chk 'serving scaler: only the leading quantity moves, the noun is carried verbatim' ($scBad.Count -eq 0) ($scBad -join ' | ')

        # ---- repair-cook-measures must not undo this work ------------------------------------------
        # Its package-noun test is guilty-until-proven-innocent. None of our nouns are package words, so
        # all four must read as innocent measuring units and survive a later sweep untouched.
        $dens = (Get-Content (Join-Path $mp 'db\densities.json') -Raw | ConvertFrom-Json).items
        $survives = @(
            @('Yellow Onion',       '3 onions',    330),
            @('Garlic',             '3 tbsp',      25),
            @('Olive Oil',          '3 tbsp',      40),
            @('Celery',             '2.5 stalks',  140),
            @('Carrots',            '3.3 carrots', 200),
            @('Green Bell Peppers', '3 peppers',   350)
        )
        $bad = @()
        foreach ($c in $survives) {
            if (-not (Test-CmLabelTrue $dens ([string]$c[0]) ([string]$c[1]) ([double]$c[2]))) { $bad += ("{0}: '{1}' @ {2} g" -f $c[0], $c[1], $c[2]) }
        }
        Chk 'every label written here proves true to repair-cook-measures' ($bad.Count -eq 0) ($bad -join ' | ')

        # ---- the labels are the GENERATOR's, not hand-typed ----------------------------------------
        # Re-derive each one from densities the way FriendlyAmt does. If a densities edit ever moves a
        # per-unit weight, this fails here instead of leaving the card quietly off-convention.
        $dn = @{}; foreach ($p in $dens.PSObject.Properties) { $dn[$p.Name] = $p.Value }
        $derive = @(
            @('Yellow Onion',       330, 'each', 110, '3'),
            @('Yellow Onion',       200, 'each', 110, '2'),
            @('Carrots',            200, 'each', 61,  '3.3'),
            @('Celery',             140, 'each', 55,  '2.5'),
            # The row the ORPHAN NAME note above is about. It could not be listed here until the rename,
            # because under the singular there was no densities entry to re-derive it FROM - the label was
            # hand-typed and unprovable, which is exactly how it stayed wrong-looking for so long.
            @('Green Bell Peppers', 350, 'each', 120, '3'),
            @('Garlic',              25, 'tbsp', 8.5, '3'),
            @('Olive Oil',           40, 'tbsp', 13.5,'3')
        )
        $dbad = @()
        foreach ($c in $derive) {
            $item = [string]$c[0]; $g = [double]$c[1]; $u = [string]$c[2]; $expectPer = [double]$c[3]; $want = [string]$c[4]
            if (-not $dn.ContainsKey($item)) { $dbad += "$item missing from densities"; continue }
            $per = [double]$dn[$item].$u
            if ([Math]::Abs($per - $expectPer) -gt 0.001) { $dbad += ("$item $u is now $per g, was $expectPer when '$want' was derived"); continue }
            if ($u -eq 'each') {
                $n = [Math]::Round($g / $per, 1); if ([Math]::Abs($n - [Math]::Round($n)) -lt 0.25) { $n = [Math]::Round($n) }
                $got = [string]$n
            } else {
                $q = [Math]::Round(($g / $per) * 4) / 4
                $got = if ($q -eq [Math]::Floor($q)) { [string][int]$q } else { $q.ToString('0.##') }
            }
            if ($got -ne $want) { $dbad += ("$item $g g -> '$got', label says '$want'") }
        }
        Chk 'every label re-derives from densities exactly as FriendlyAmt would' ($dbad.Count -eq 0) ($dbad -join ' | ')
    } finally { Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue }
    if ($fail -eq 0) { Write-Output 'SELF-TEST PASS'; exit 0 } else { Write-Output "SELF-TEST FAIL: $fail case(s)"; exit 1 }
}

$res = Invoke-ScaledNoteRepair (Join-Path $mp 'db\recipes') ([bool]$Apply) $LABELS
Write-Output ("scaled-note repair: {0} line(s) across {1} recipe(s){2}" -f $res.lines, $res.recipes, $(if ($Apply) { '' } else { '  [read-only - pass -Apply]' }))
foreach ($s in $res.samples) { Write-Output ('    ' + $s) }
if ($res.notes.Count) {
    Write-Output ("  REFUSED - a leaking row with no hand-checked label; the grams need a source check before a label can be written ({0}):" -f $res.notes.Count)
    foreach ($n in $res.notes) { Write-Output ('    ' + $n) }
}
if ($Apply -and $res.slugs.Count) {
    New-Item -ItemType Directory -Force (Join-Path $mp 'out') | Out-Null
    ($res.slugs -join "`n") | Set-Content (Join-Path $mp 'out\scaled-note-slugs.txt') -Encoding UTF8
    Write-Output '  slug list -> out\scaled-note-slugs.txt (rebuild + republish these cards)'
    # THE CARRY MANIFEST. recipes-db.json keeps its own copy of every buy string and gen-planner-data.ps1
    # reads THAT, so a repair that stops at the specs leaves the Meal Plan Builder's grocery list showing
    # the authoring note indefinitely - the exact failure sync-recipesdb-buy.ps1 was built for after it
    # happened once already. That script refuses to carry anything it cannot prove, and rightly: this
    # file is the proof. It records the precise rows this run rewrote, so the sync's scaled-note class
    # can only ever FINISH a repair that actually ran, on the exact rows it touched - never ratify a hand
    # edit, and never fire on a spec nobody reviewed.
    ($res.carry | ConvertTo-Json -Depth 4) | Set-Content (Join-Path $mp 'out\scaled-note-carry.json') -Encoding UTF8
    Write-Output ('  carry manifest -> out\scaled-note-carry.json (' + $res.carry.Count + ' row(s); sync-recipesdb-buy.ps1 -Apply reads this)')
}
exit 0
