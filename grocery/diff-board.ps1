<#
  diff-board.ps1 - per-cell diff of two comparison files (id x store -> matched item). Run after any rules
  change (apply-category-excludes, include/exclude edits) to see exactly which board cells changed hands,
  dropped, or appeared - so a rules change is a reviewed correction, never a silent surprise.
#>
param([Parameter(Mandatory=$true)][string]$Base, [Parameter(Mandatory=$true)][string]$NewFile)
$ErrorActionPreference = 'Stop'

$mapA = @{}
foreach ($it in (Get-Content $Base -Raw | ConvertFrom-Json).comparison) {
  foreach ($s in $it.stores) {
    if ([double]$s.per_unit -gt 0) { $mapA[($it.id + '|' + $s.store)] = [pscustomobject]@{ item=[string]$s.item; pu=[double]$s.per_unit } }
  }
}
$mapB = @{}
foreach ($it in (Get-Content $NewFile -Raw | ConvertFrom-Json).comparison) {
  foreach ($s in $it.stores) {
    if ([double]$s.per_unit -gt 0) { $mapB[($it.id + '|' + $s.store)] = [pscustomobject]@{ item=[string]$s.item; pu=[double]$s.per_unit } }
  }
}

$changed = 0; $dropped = 0; $addedN = 0
foreach ($k in ($mapA.Keys | Sort-Object)) {
  if (-not $mapB.ContainsKey($k)) { $dropped++; Write-Output ("  DROPPED  {0,-34} was <{1}> `${2}" -f $k, $mapA[$k].item, $mapA[$k].pu); continue }
  if ($mapB[$k].item -ne $mapA[$k].item) { $changed++; Write-Output ("  CHANGED  {0,-34} <{1}> `${2}  ->  <{3}> `${4}" -f $k, $mapA[$k].item, $mapA[$k].pu, $mapB[$k].item, $mapB[$k].pu) }
}
foreach ($k in ($mapB.Keys | Sort-Object)) { if (-not $mapA.ContainsKey($k)) { $addedN++; Write-Output ("  ADDED    {0,-34} <{1}> `${2}" -f $k, $mapB[$k].item, $mapB[$k].pu) } }
Write-Output ''
Write-Output ("cells: base={0} new={1}   changed={2} dropped={3} added={4}" -f $mapA.Count, $mapB.Count, $changed, $dropped, $addedN)
