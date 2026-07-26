# merge-protein-selections.ps1 - the merge pass for PARALLEL-BY-PROTEIN dedup (R300 speed lesson:
# one selector on a ~450 pool ran ~40 min serially; four per-protein selectors run in ~1/4 that).
#
# Each parallel recipe-dedup-selector handles ONE protein against the live catalog + its own pool and
# writes selected-<protein>.json ({selected:[...],cut:[...]}). This script concatenates them into the
# run's selected.json AND does the ONE thing a per-protein selector cannot: flag candidate-vs-candidate
# same-dish-different-protein TWINS across the four files (a turkey chili candidate vs a beef chili
# candidate) for the main session to resolve. Cross-protein twins vs the LIVE catalog are already each
# selector's job; only candidate-vs-candidate twins need this pass.
#
# Usage: .\merge-protein-selections.ps1 -RunDir C:\Codex\income\meal-prep\r400
param([Parameter(Mandatory)][string]$RunDir)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\json-db-io.ps1')

# Derive the protein set from the files ACTUALLY present (2026-07-26): the hardcoded 4-array silently
# skipped any run that included vegetarian/seafood/a new protein class (recipe-sourcer allows them). One
# selected-<protein>.json per parallel selector; the protein is the filename suffix.
$selFiles = @(Get-ChildItem (Join-Path $RunDir 'selected-*.json') -ErrorAction SilentlyContinue | Sort-Object Name)
if (-not $selFiles.Count) { throw "merge-protein-selections: no selected-*.json in $RunDir (did the parallel selectors write their output?)" }
$all = New-Object System.Collections.Generic.List[object]
$cutAll = New-Object System.Collections.Generic.List[object]
foreach ($f in $selFiles) {
    $p = $f.BaseName -replace '^selected-',''
    $sel = Get-Content $f.FullName -Raw -Encoding utf8 | ConvertFrom-Json
    # HARD FAIL on a malformed selector file rather than silently merging nothing (the schema-drift bug):
    # the selector contract is { selected:[...], rejected_dupes|cut:[...], ... }.
    if (-not ($sel.PSObject.Properties.Name -contains 'selected')) { throw "merge-protein-selections: $($f.Name) has no 'selected' array - selector output is malformed (expected {selected, rejected_dupes})" }
    # accept either field name for the cut list (selector def says rejected_dupes; older files used cut).
    $cut = if ($sel.PSObject.Properties.Name -contains 'rejected_dupes') { $sel.rejected_dupes } elseif ($sel.PSObject.Properties.Name -contains 'cut') { $sel.cut } else { @() }
    foreach ($r in @($sel.selected)) { $all.Add($r) }
    foreach ($r in @($cut) | Where-Object { $_ }) { $cutAll.Add($r) }
    Write-Output ("$p : {0} selected, {1} cut" -f @($sel.selected).Count, @($cut | Where-Object { $_ }).Count)
}

# dish-key for twin detection: strip the protein words + common filler, normalize
function DishKey([string]$name) {
    $k = $name.ToLower()
    $k = $k -replace '\b(turkey|pork|beef|chicken|ground|smoked|boneless|skinless)\b', ''
    $k = $k -replace '[^a-z ]', ' ' -replace '\s+', ' '
    $k.Trim()
}
$byKey = @{}
foreach ($r in $all) {
    $k = DishKey ([string]$r.name)
    if (-not $byKey.ContainsKey($k)) { $byKey[$k] = @() }
    $byKey[$k] += $r
}
$twins = @()
foreach ($k in $byKey.Keys) {
    $grp = $byKey[$k]
    $prots = @($grp | ForEach-Object { $_.protein } | Select-Object -Unique)
    if ($grp.Count -ge 2 -and $prots.Count -ge 2) {
        $twins += [pscustomobject]@{ dish_key = $k; members = @($grp | ForEach-Object { $_.slug + ' [' + $_.protein + ']' }) }
    }
}

$out = [pscustomobject]@{
    targets  = $null
    selected = $all.ToArray()
    cut      = $cutAll.ToArray()
    cross_protein_twins_to_review = $twins
}
$outFile = Join-Path $RunDir 'selected.json'
$json = $out | ConvertTo-Json -Depth 8   # a single OBJECT root (not a bare array) - safe
[System.IO.File]::WriteAllText($outFile, $json, (New-Object System.Text.UTF8Encoding($false)))
Write-Output ("merged: {0} selected, {1} cut -> {2}" -f $all.Count, $cutAll.Count, (Split-Path -Leaf $outFile))
if ($twins.Count -gt 0) {
    Write-Output ("CROSS-PROTEIN TWINS to resolve ({0}) - the run's 'max 2 protein-variants per dish' rule applies:" -f $twins.Count)
    $twins | ForEach-Object { Write-Output ('  ' + $_.dish_key + ' :: ' + ($_.members -join ', ')) }
} else { Write-Output 'no candidate-vs-candidate cross-protein twins' }
