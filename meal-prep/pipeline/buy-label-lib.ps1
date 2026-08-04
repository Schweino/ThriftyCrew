<#
  buy-label-lib.ps1 - THE splice that carries one ingredient label change through every surface of a
  spec that restates it.

  WHY A LIB (2026-08-04). `buy` is copied into three places inside the spec and a fourth in the JSON-LD,
  and they must always agree: the serving widget re-renders the Ingredients list from scaler.ing[].buy
  the moment a reader touches the servings control, so a display-only fix silently changes the list under
  them, and spec-guards plus the contradiction sweep both read cost_lines. repair-unitless-buy.ps1 grew
  this splice first; repair-range-buy.ps1 needs exactly the same one. Two copies of a fiddly text edit
  over the same four fields is the "two copies of the same math" failure mode - the day someone fixes a
  splice bug in one of them, the other keeps shipping it. One implementation, both scripts dot-source it.

  SPEC-SCHEMA.md forbids ConvertFrom-Json | ConvertTo-Json on a spec (the prose carries \uXXXX escapes
  and the round trip rewrites them), so every edit here is a targeted splice found by the string-aware
  scanners in lib\json-db-io.ps1. The caller owns Read-SpecText / Write-SpecText and the BOM.

  THE FOUR SURFACES, and why the fourth is opt-in:
      scaler.ing[i].buy        always
      ingredients_display[i]   always   (anchored on the grams as well as the amount)
      cost_lines[]             always   (best-effort: bulk/pantry items have no buy line)
      head.recipeIngredient    -IncludeHead only

  head.recipeIngredient is written ONCE, at intake, by build-v2-spec.ps1 - hand-supplied by the writer
  when they give one, otherwise derived as "<buy> <item lowercased>". Nothing regenerates it afterwards,
  so it can hold a label the other three surfaces no longer state. That makes it a real surface, but a
  hand-written line is prose, not a field: it may name the ingredient differently, carry two quantities,
  or not mention the amount at all. So the patch here is deliberately narrow - it fires only on a head
  line that literally BEGINS with the old label, and refuses (loudly, via notes) when more than one line
  could match. Anything subtler belongs to repair-spec-contradictions.ps1, which owns the HEAD-QTY class.
#>

function Test-BuyLabelSpliceSafe {
    <# A value spliced RAW into a JSON string literal must need no escaping. Every label the repairs
       write today is plain ASCII, but a writer-supplied override could carry a quote or a backslash and
       silently produce a spec that no longer parses - or worse, one that parses differently. Refuse
       first; Write-SpecText's parse-verify is a backstop, not a plan. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    if ($Value -match '["\\]') { return $false }
    if ($Value -match '[\x00-\x1f]') { return $false }
    return $true
}

function Invoke-BuyLabelSplice {
    <#
      Apply a decided set of label edits to one spec's raw text. Pure text in, text out, so a self-test
      drives exactly the same code path a catalog run does.

      $Edits: objects carrying Index (position in scaler.ing / ingredients_display), Item, Old, New and
      Grams. The caller decides every edit BEFORE any text is touched, so a spec is either fully patched
      or not at all - a half-patched spec is the one state where the surfaces disagree.

      Returns @{ text = <patched raw>; notes = @(...) }.
    #>
    param(
        [Parameter(Mandatory)][string]$Raw,
        [Parameter(Mandatory)]$Spec,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Edits,
        [switch]$IncludeHead
    )
    $notes = New-Object System.Collections.Generic.List[string]
    if ($Edits.Count -eq 0) { return @{ text = $Raw; notes = @() } }

    $ing  = @($Spec.scaler.ing)
    $disp = @($Spec.ingredients_display)
    if ($ing.Count -ne $disp.Count) { throw ("parallel arrays disagree: scaler.ing $($ing.Count) vs ingredients_display $($disp.Count)") }
    foreach ($e in $Edits) {
        if (-not (Test-BuyLabelSpliceSafe -Value ([string]$e.New))) { throw ("refusing to splice a label that needs JSON escaping: '$($e.New)'") }
    }

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
    foreach ($e in @($Edits | Sort-Object Index -Descending)) {
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
    # grams as well as the amount makes the match unambiguous even when two ingredients share a count.
    $dispAt = Find-JsonValueStart -Raw $text -Key 'ingredients_display'
    if ($dispAt -lt 0) { throw 'no "ingredients_display" key' }
    $dspans = @(Get-JsonArraySpans -Raw $text -OpenIndex $dispAt)
    if ($dspans.Count -ne $disp.Count) { throw ("ingredients_display span walk found $($dspans.Count) elements, parser says $($disp.Count)") }
    foreach ($e in @($Edits | Sort-Object Index -Descending)) {
        $sp = $dspans[$e.Index]
        $el = $text.Substring($sp.Start, $sp.End - $sp.Start + 1)
        $tail = ' ' + $e.Old + ' (' + $e.Grams + ' g)"'
        if (-not $el.EndsWith($tail)) { throw ("ingredients_display[$($e.Index)] does not end with '$tail': $el") }
        $newEl = $el.Substring(0, $el.Length - $tail.Length) + ' ' + $e.New + ' (' + $e.Grams + ' g)"'
        $text = $text.Substring(0, $sp.Start) + $newEl + $text.Substring($sp.End + 1)
    }

    # ---- 3. cost_lines --------------------------------------------------------------------------
    # Not rendered by build-card2 (the widget builds the receipt), but spec-guards and the contradiction
    # sweep both read it, and leaving the old token here would mean the fix half-landed in the data.
    $clAt = Find-JsonValueStart -Raw $text -Key 'cost_lines'
    if ($clAt -ge 0) {
        $cspans = @(Get-JsonArraySpans -Raw $text -OpenIndex $clAt)
        foreach ($e in @($Edits | Sort-Object Index -Descending)) {
            $prefix = '"' + $e.Item + ', ' + $e.Old + ':'
            $hits = @($cspans | Where-Object { $text.Substring($_.Start, [Math]::Min($prefix.Length, $_.End - $_.Start + 1)) -eq $prefix })
            if ($hits.Count -eq 0) { continue }                 # bulk/pantry items have no buy line - fine
            if ($hits.Count -gt 1) { $notes.Add("cost_lines: '$($e.Item), $($e.Old):' matched $($hits.Count) lines - skipped"); continue }
            $sp = $hits[0]
            $newPrefix = '"' + $e.Item + ', ' + $e.New + ':'
            $text = $text.Substring(0, $sp.Start) + $newPrefix + $text.Substring($sp.Start + $prefix.Length)
            # spans after this one shifted; recompute rather than track deltas
            $cspans = @(Get-JsonArraySpans -Raw $text -OpenIndex (Find-JsonValueStart -Raw $text -Key 'cost_lines'))
        }
    }

    # ---- 4. head.recipeIngredient (opt-in) ------------------------------------------------------
    # The JSON-LD Google reads. Narrow on purpose: a line qualifies only by BEGINNING with the old label,
    # so "1/2-1 cup low-sodium vegetable or chicken broth Chicken Broth" is reachable while a hand-written
    # line that merely mentions the ingredient is not. Silence when nothing matches is correct - most
    # specs' head lines were written by hand and never carried the buy string at all.
    if ($IncludeHead) {
        $headAt = Find-JsonValueStart -Raw $text -Key 'head'
        if ($headAt -ge 0) {
            $riAt = Find-JsonValueStart -Raw $text -Key 'recipeIngredient' -From $headAt
            if ($riAt -ge 0) {
                foreach ($e in @($Edits | Sort-Object Index -Descending)) {
                    $hspans = @(Get-JsonArraySpans -Raw $text -OpenIndex (Find-JsonValueStart -Raw $text -Key 'recipeIngredient' -From (Find-JsonValueStart -Raw $text -Key 'head')))
                    $hits = @()
                    foreach ($sp in $hspans) {
                        if ($text[$sp.Start] -ne '"') { continue }
                        $vs = Get-JsonStringSpan -Raw $text -OpenIndex $sp.Start
                        $val = $text.Substring($vs.Start, $vs.End - $vs.Start + 1)
                        if ($val.StartsWith($e.Old)) { $hits += $vs }
                    }
                    if ($hits.Count -eq 0) { continue }
                    if ($hits.Count -gt 1) { $notes.Add("head.recipeIngredient: '$($e.Old)' begins $($hits.Count) lines - skipped"); continue }
                    $vs = $hits[0]
                    $text = $text.Substring(0, $vs.Start) + $e.New + $text.Substring($vs.Start + $e.Old.Length)
                }
            }
        }
    }

    return @{ text = $text; notes = @($notes.ToArray()) }
}

function Assert-BuyLabelSurfacesAgree {
    <# POST-CONDITION, run on every file before it is written: the two parallel surfaces must still
       agree, or the reader sees the Ingredients list change the moment they touch the servings control.
       Throws with the slug named; returns nothing on success. #>
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Slug
    )
    $after = $Text | ConvertFrom-Json
    $ai = @($after.scaler.ing); $ad = @($after.ingredients_display)
    if ($ai.Count -ne $ad.Count) { throw ("$($Slug): parallel arrays diverged during repair") }
    for ($k = 0; $k -lt $ai.Count; $k++) {
        if ([string]$ad[$k] -notmatch [regex]::Escape([string]$ai[$k].buy)) {
            throw ("$($Slug): display line $k no longer carries its buy '$([string]$ai[$k].buy)'")
        }
    }
}
