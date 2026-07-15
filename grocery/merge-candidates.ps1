<#
  merge-candidates.ps1 - assemble + VALIDATE the 500-run candidate list from the agent drafts in
  out\staples500\gen\agent-*.json. Nothing from the agents is trusted raw: every candidate must clear
    1. unit is one of lb|oz|floz|each|dozen|gallon
    2. category is an EXACT label from categories.json
    3. id is a clean kebab slug, not already in commodities.json, not a dupe of another candidate
    4. normalized label does not collide with an existing commodity label (a different id for the same staple
       is still a dupe)
  Rejects are PRINTED with reasons, never silently dropped. Output: out\staples500\candidates-500.json +
  candidates-500.csv (Brad's review copy). This list is REVIEW MATERIAL - nothing here touches the board until
  a batch is explicitly registered (commodities.json + categories.json), apply-category-excludes is run, and
  the batch passes build-vet-sheet review.
#>
param([string]$OutDir = "")
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $root 'out\staples500' }
$genDir = Join-Path $OutDir 'gen'

$UNITS = @('lb','oz','floz','each','dozen','gallon')
$catLabels = @()
foreach ($c in (Get-Content (Join-Path $root 'categories.json') -Raw | ConvertFrom-Json).categories) { $catLabels += [string]$c.label }
function NormLabel([string]$s) { ((($s.ToLower() -replace '[^a-z0-9 ]',' ') -replace '\s+',' ').Trim() -replace 's\b','') }

$existingIds = @{}; $existingLabels = @{}
foreach ($cm in (Get-Content (Join-Path $root 'commodities.json') -Raw | ConvertFrom-Json)) {
  $existingIds[[string]$cm.id] = $true
  $existingLabels[(NormLabel ([string]$cm.label))] = [string]$cm.id
}

$keep = New-Object System.Collections.Generic.List[object]
$rejects = New-Object System.Collections.Generic.List[string]
$seenIds = @{}; $seenLabels = @{}
foreach ($f in (Get-ChildItem (Join-Path $genDir 'agent-*.json') -ErrorAction SilentlyContinue | Sort-Object Name)) {
  $arr = @()
  try { $arr = @(Get-Content $f.FullName -Raw | ConvertFrom-Json) } catch { $rejects.Add("$($f.Name): UNPARSEABLE JSON - entire file skipped"); continue }
  foreach ($x in $arr) {
    $id = ([string]$x.id).Trim().ToLower()
    $name = ([string]$x.name).Trim()
    $unit = ([string]$x.unit).Trim().ToLower()
    $catL = ([string]$x.category).Trim()
    $why = $null
    if (-not $name) { $why = 'blank name' }
    elseif ($id -notmatch '^[a-z0-9]+(-[a-z0-9]+)*$') { $why = "bad id slug '$id'" }
    elseif ($UNITS -notcontains $unit) { $why = "bad unit '$unit'" }
    elseif ($catLabels -notcontains $catL) { $why = "unknown category '$catL'" }
    elseif ($existingIds.ContainsKey($id)) { $why = 'id already on the board' }
    elseif ($seenIds.ContainsKey($id)) { $why = "cross-agent dupe id (also in $($seenIds[$id]))" }
    else {
      $nl = NormLabel $name
      if ($existingLabels.ContainsKey($nl)) { $why = "label collides with existing commodity '$($existingLabels[$nl])'" }
      elseif ($seenLabels.ContainsKey($nl)) { $why = "cross-agent dupe label (also in $($seenLabels[$nl]))" }
    }
    if ($why) { $rejects.Add(("  {0,-28} [{1}] {2}" -f $id, $f.Name, $why)); continue }
    $seenIds[$id] = $f.Name
    $seenLabels[(NormLabel $name)] = $f.Name
    $keep.Add([pscustomobject]@{
      id = $id; name = $name; unit = $unit; typical_size = [string]$x.typical_size
      category = $catL; search_term = [string]$x.search_term; notes = [string]$x.notes; source = $f.Name
    })
  }
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
($keep | ConvertTo-Json -Depth 4) | Set-Content (Join-Path $OutDir 'candidates-500.json') -Encoding UTF8
$keep | Export-Csv (Join-Path $OutDir 'candidates-500.csv') -NoTypeInformation -Encoding UTF8

Write-Output ("candidates kept: " + $keep.Count + "   rejected: " + $rejects.Count)
Write-Output 'per-category:'
$keep | Group-Object category | Sort-Object Name | ForEach-Object { Write-Output ("  {0,-26} {1}" -f $_.Name, $_.Count) }
if ($rejects.Count) { Write-Output ''; Write-Output 'REJECTS (reasoned, not silent):'; foreach ($r in ($rejects | Select-Object -First 40)) { Write-Output $r }; if ($rejects.Count -gt 40) { Write-Output ("  ... and " + ($rejects.Count - 40) + " more") } }
Write-Output ''
Write-Output ("review copy -> " + (Join-Path $OutDir 'candidates-500.csv'))
