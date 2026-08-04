# json-db-io.ps1 - shared IO helpers for the meal-prep pipeline. Dot-source it:
#   . (Join-Path $PSScriptRoot '..\lib\json-db-io.ps1')
# Exists because two PS 5.1 traps bit the R300 run repeatedly (2026-07-25/26):
#   (1) ConvertTo-Json on an array can emit {"value":[...],"Count":N} (propagates from a file
#       already in that shape) OR collapse a 1-element array to a bare {object}. Empirically
#       neither -InputObject nor @() nor ,$x is reliable across all cases.
#   (2) recipes-db.json is 1.6 MB pretty-printed; removing one recipe by hand (brace matching)
#       was re-implemented three separate times, each a chance to corrupt the file.

# Save-JsonArray: write an array of objects as a TOP-LEVEL JSON array, always. Bulletproof because
# it serializes each ELEMENT (an object, which ConvertTo-Json handles correctly) and controls the
# array brackets itself - no wrap, no 1-element collapse possible. Writes UTF-8 no-BOM.
# USE for full rewrites of small/medium data files (labels, board maps, candidate lists).
# DO NOT use to rewrite the 1.6 MB commodities.json - a full re-serialize there is a giant churn
# diff; edit that file with targeted text ops or the registration scripts (standing rule).
function Save-JsonArray {
    param(
        # AllowNull too: an empty PS pipeline assigns $null (not @()), so a run with zero new items
        # (every ingredient already board-tracked) would otherwise crash here. Treat null as empty.
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()]$Array,
        [Parameter(Mandatory)][string]$Path,
        [int]$Depth = 8
    )
    $items = if ($null -eq $Array) { @() } else { @($Array) }
    if ($items.Count -eq 0) {
        [System.IO.File]::WriteAllText($Path, "[]`n", (New-Object System.Text.UTF8Encoding($false)))
        return 0
    }
    $parts = foreach ($el in $items) {
        $j = ConvertTo-Json -InputObject $el -Depth $Depth
        # indent each line by 2 spaces so the array reads cleanly
        ($j -split "`r?`n" | ForEach-Object { '  ' + $_ }) -join "`n"
    }
    $json = "[`n" + ($parts -join ",`n") + "`n]`n"
    # parse-verify before writing - never ship a file that will not round-trip
    $null = $json | ConvertFrom-Json
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
    return $items.Count
}

# Read-JsonArrayFile: read a data file that SHOULD be a top-level array but might be a stored
# {"value":[...],"Count":N} wrap from a prior bad write. Returns the plain array either way.
function Read-JsonArrayFile {
    param([Parameter(Mandatory)][string]$Path)
    $obj = Get-Content $Path -Raw -Encoding utf8 | ConvertFrom-Json
    if ($obj -is [System.Management.Automation.PSCustomObject] -and
        $obj.PSObject.Properties.Name -contains 'value' -and
        $obj.PSObject.Properties.Name -contains 'Count') {
        return @($obj.value)
    }
    return @($obj)
}

# Remove-RecipeRow: delete exactly one recipe object from recipes-db.json by slug, format-agnostic
# (works whether the row is compact or pretty-printed), via brace matching. Removes one adjacent
# comma so the array stays valid. Parse-verifies. Returns the new recipe count. Pair with
# update-recipes-db.ps1 (which rebuilds the row from the spec) to REPLACE a row: remove, then re-add.
function Remove-RecipeRow {
    param(
        [Parameter(Mandatory)][string]$DbPath,
        [Parameter(Mandatory)][string]$Slug
    )
    $raw = [System.IO.File]::ReadAllText($DbPath)
    $anchor = '"' + $Slug + '"'
    $si = $raw.IndexOf($anchor)
    if ($si -lt 0) { throw "Remove-RecipeRow: slug not found: $Slug" }
    if ($raw.IndexOf($anchor, $si + 1) -ge 0) { throw "Remove-RecipeRow: slug not unique: $Slug" }
    $depth = 0; $objStart = -1
    for ($i = $si; $i -ge 0; $i--) {
        $ch = $raw[$i]
        if ($ch -eq '}') { $depth++ }
        elseif ($ch -eq '{') { if ($depth -eq 0) { $objStart = $i; break } else { $depth-- } }
    }
    $depth = 0; $objEnd = -1
    for ($i = $si; $i -lt $raw.Length; $i++) {
        $ch = $raw[$i]
        if ($ch -eq '{') { $depth++ }
        elseif ($ch -eq '}') { if ($depth -eq 0) { $objEnd = $i; break } else { $depth-- } }
    }
    if ($objStart -lt 0 -or $objEnd -lt 0) { throw "Remove-RecipeRow: brace match failed for $Slug" }
    $seg = $raw.Substring($objStart, $objEnd - $objStart + 1)
    if (($seg -split '"slug"').Count -ne 2) { throw "Remove-RecipeRow: segment spans !=1 slug for $Slug (abort)" }
    $delStart = $objStart; $delEnd = $objEnd
    if ($objStart -gt 0) {
        $k = $objStart - 1
        while ($k -ge 0 -and [char]::IsWhiteSpace($raw[$k])) { $k-- }
        if ($k -ge 0 -and $raw[$k] -eq ',') { $delStart = $k }
    }
    if ($delStart -eq $objStart -and $objEnd -lt $raw.Length - 1) {
        $k = $objEnd + 1
        while ($k -lt $raw.Length -and [char]::IsWhiteSpace($raw[$k])) { $k++ }
        if ($k -lt $raw.Length -and $raw[$k] -eq ',') { $delEnd = $k }
    }
    $new = $raw.Substring(0, $delStart) + $raw.Substring($delEnd + 1)
    $parsed = $new | ConvertFrom-Json
    [System.IO.File]::WriteAllText($DbPath, $new)
    return @($parsed.recipes).Count
}

# ---------------------------------------------------------------------------------------------------
# STRING-AWARE STRUCTURAL SCANNERS. SPEC-SCHEMA.md forbids re-serializing a recipe spec, so a structured
# edit has to find its target by walking the raw text. Brace counting alone is not enough here: recipe
# prose is full of braces and brackets inside string literals, and every '<' is stored as the escape
# <, so a naive scan desynchronises on the first intro paragraph. These skip string literals (and
# the backslash escapes inside them) properly, which is the whole reason they exist.
# ---------------------------------------------------------------------------------------------------

# Find-JsonValueStart: index of the first character of the VALUE for "key": , searching from $From.
# Returns -1 when the key is not found. $Nth picks a later occurrence (1-based) for repeated keys.
function Find-JsonValueStart {
    param(
        [Parameter(Mandatory)][string]$Raw,
        [Parameter(Mandatory)][string]$Key,
        [int]$From = 0,
        [int]$Nth = 1
    )
    $rx = New-Object System.Text.RegularExpressions.Regex ('"' + [regex]::Escape($Key) + '"\s*:\s*')
    $at = $From; $n = 0
    while ($true) {
        $m = $rx.Match($Raw, $at)
        if (-not $m.Success) { return -1 }
        $n++
        if ($n -ge $Nth) { return ($m.Index + $m.Length) }
        $at = $m.Index + $m.Length
    }
}

# Get-JsonArraySpans: the [Start,End] character span of every TOP-LEVEL element of the array whose '['
# sits at $OpenIndex. Spans are trimmed of surrounding whitespace, so Raw.Substring(Start, End-Start+1)
# is exactly the element text (including its quotes for a string element).
#
# ALWAYS CALL THIS AS  $spans = @(Get-JsonArraySpans ...)  - the @() is load-bearing. PS 5.1 unrolls a
# one-element return to a bare object, and a bare PSCustomObject has no .Count, so `$spans.Count` reads
# $null and `for ($k=0; $k -lt $spans.Count; ...)` never executes its body. That is a repair that finds
# nothing, reports nothing and exits 0 - the same silent-wrong-answer shape as the rest of
# ps51-json-array-traps. Measured 2026-08-04 on a recipes-db row holding a single ingredient.
function Get-JsonArraySpans {
    param(
        [Parameter(Mandatory)][string]$Raw,
        [Parameter(Mandatory)][int]$OpenIndex
    )
    if ($OpenIndex -lt 0 -or $OpenIndex -ge $Raw.Length -or $Raw[$OpenIndex] -ne '[') {
        throw "Get-JsonArraySpans: index $OpenIndex is not the '[' of an array"
    }
    $spans = New-Object System.Collections.Generic.List[object]
    $i = $OpenIndex + 1
    $depth = 0; $inStr = $false; $elStart = -1
    while ($i -lt $Raw.Length) {
        $c = $Raw[$i]
        if ($inStr) {
            if ($c -eq '\') { $i += 2; continue }      # an escape consumes the next char, including \" and \\
            if ($c -eq '"') { $inStr = $false }
            $i++; continue
        }
        if ($c -eq '"') {
            if ($depth -eq 0 -and $elStart -lt 0) { $elStart = $i }
            $inStr = $true; $i++; continue
        }
        if ($c -eq '[' -or $c -eq '{') {
            if ($depth -eq 0 -and $elStart -lt 0) { $elStart = $i }
            $depth++; $i++; continue
        }
        if ($c -eq ']' -or $c -eq '}') {
            if ($depth -eq 0) {
                if ($elStart -ge 0) {
                    $e = $i - 1
                    while ($e -gt $elStart -and [char]::IsWhiteSpace($Raw[$e])) { $e-- }
                    if ($e -ge $elStart) { $spans.Add([pscustomobject]@{ Start = $elStart; End = $e }) }
                }
                return @($spans.ToArray())
            }
            $depth--; $i++; continue
        }
        if ($c -eq ',' -and $depth -eq 0) {
            if ($elStart -ge 0) {
                $e = $i - 1
                while ($e -gt $elStart -and [char]::IsWhiteSpace($Raw[$e])) { $e-- }
                if ($e -ge $elStart) { $spans.Add([pscustomobject]@{ Start = $elStart; End = $e }) }
                $elStart = -1
            }
            $i++; continue
        }
        if ($depth -eq 0 -and $elStart -lt 0 -and -not [char]::IsWhiteSpace($c)) { $elStart = $i }
        $i++
    }
    throw "Get-JsonArraySpans: unterminated array from $OpenIndex"
}

# Get-JsonStringSpan: the span of the JSON string literal whose opening quote sits at $OpenIndex,
# returned as the span of its CONTENT (between the quotes) so a caller can splice a new value in.
function Get-JsonStringSpan {
    param(
        [Parameter(Mandatory)][string]$Raw,
        [Parameter(Mandatory)][int]$OpenIndex
    )
    if ($Raw[$OpenIndex] -ne '"') { throw ("Get-JsonStringSpan: index " + $OpenIndex + " is not a quote") }
    $i = $OpenIndex + 1
    while ($i -lt $Raw.Length) {
        $c = $Raw[$i]
        if ($c -eq '\') { $i += 2; continue }
        if ($c -eq '"') { return [pscustomobject]@{ Start = ($OpenIndex + 1); End = ($i - 1) } }
        $i++
    }
    throw "Get-JsonStringSpan: unterminated string from $OpenIndex"
}

# Read-SpecText / Write-SpecText: byte-faithful spec IO. The 513 spec files are NOT uniform - some carry
# a UTF-8 BOM and some do not - so a repair that normalises the BOM rewrites the first bytes of files it
# did not otherwise change and buries the real edit in the diff. Round-trip whatever the file already had.
function Read-SpecText {
    param([Parameter(Mandatory)][string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $off = if ($bom) { 3 } else { 0 }
    return [pscustomobject]@{
        Text = [System.Text.Encoding]::UTF8.GetString($bytes, $off, $bytes.Length - $off)
        Bom  = $bom
    }
}
function Write-SpecText {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][bool]$Bom
    )
    $null = $Text | ConvertFrom-Json    # never write a spec that will not parse
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($Bom)))
}

# Set-RecipeVisibility: patch the "visibility" field of one-or-many recipe rows IN PLACE, key-scoped by
# slug, without re-serializing the file. rotate-free-dinners.ps1 used to round-trip the ENTIRE
# recipes-db.json (3.9 MB now, ~11.5 MB at 1500 recipes) through ConvertTo-Json -Depth 8 just to flip
# ~40 visibility flags - slow, and the estate's own "never round-trip big JSON" rule (Depth 8 silently
# truncates deeper nesting; a full re-serialize risks unicode mojibake in recipe prose). This edits ONLY
# the visibility values of the named rows via the same brace-match Remove-RecipeRow uses, leaving 99.6%
# of the bytes untouched. $Map = @{ slug = 'public'|'paid'; ... }. Parse-verifies. Returns rows changed.
function Set-RecipeVisibility {
    param(
        [Parameter(Mandatory)][string]$DbPath,
        [Parameter(Mandatory)][hashtable]$Map
    )
    $raw = [System.IO.File]::ReadAllText($DbPath)
    $changed = 0
    foreach ($slug in $Map.Keys) {
        $vis = [string]$Map[$slug]
        if ($vis -ne 'public' -and $vis -ne 'paid') { throw "Set-RecipeVisibility: bad visibility '$vis' for $slug" }
        $anchor = '"' + $slug + '"'
        $si = $raw.IndexOf($anchor)
        if ($si -lt 0) { continue }   # slug not in db - skip (not fatal; the rotation may free a slug the index lacks)
        if ($raw.IndexOf($anchor, $si + 1) -ge 0) { throw "Set-RecipeVisibility: slug not unique: $slug" }
        $depth = 0; $objStart = -1
        for ($i = $si; $i -ge 0; $i--) { $ch = $raw[$i]; if ($ch -eq '}') { $depth++ } elseif ($ch -eq '{') { if ($depth -eq 0) { $objStart = $i; break } else { $depth-- } } }
        $depth = 0; $objEnd = -1
        for ($i = $si; $i -lt $raw.Length; $i++) { $ch = $raw[$i]; if ($ch -eq '{') { $depth++ } elseif ($ch -eq '}') { if ($depth -eq 0) { $objEnd = $i; break } else { $depth-- } } }
        if ($objStart -lt 0 -or $objEnd -lt 0) { throw "Set-RecipeVisibility: brace match failed for $slug" }
        $seg = $raw.Substring($objStart, $objEnd - $objStart + 1)
        if (($seg -split '"slug"').Count -ne 2) { throw "Set-RecipeVisibility: segment spans !=1 slug for $slug (abort)" }
        $newSeg = [regex]::Replace($seg, '"visibility"\s*:\s*"(?:public|paid)"', ('"visibility":"' + $vis + '"'), 1)
        if ($newSeg -eq $seg) { continue }   # already the target value (or no visibility field) - no-op
        $raw = $raw.Substring(0, $objStart) + $newSeg + $raw.Substring($objEnd + 1)
        $changed++
    }
    $null = $raw | ConvertFrom-Json   # verify the whole file still parses before writing
    [System.IO.File]::WriteAllText($DbPath, $raw)
    return $changed
}
