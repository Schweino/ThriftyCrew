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

$proteins = @('turkey','pork','beef','chicken')
$all = New-Object System.Collections.Generic.List[object]
$cutAll = New-Object System.Collections.Generic.List[object]
foreach ($p in $proteins) {
    $f = Join-Path $RunDir ("selected-$p.json")
    if (-not (Test-Path $f)) { Write-Warning "missing $f - skipping $p"; continue }
    $sel = Get-Content $f -Raw -Encoding utf8 | ConvertFrom-Json
    foreach ($r in @($sel.selected)) { $all.Add($r) }
    foreach ($r in @($sel.cut)) { $cutAll.Add($r) }
    Write-Output ("$p : {0} selected, {1} cut" -f @($sel.selected).Count, @($sel.cut).Count)
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
