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
