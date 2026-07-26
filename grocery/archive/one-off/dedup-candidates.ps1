<#
  dedup-candidates.ps1 - clean the 500-run candidate list of items already covered, BEFORE registering more
  batches. An "overlap" is any approved candidate that is already one of:
    - a registered commodity id (commodities.json)
    - a normalized-label match of a registered commodity (a different id for the same staple)
    - an ORPHAN product-urls link: an id that already carries store links but lost its commodity entry. This is
      the trap that put 7 items into batch 1 as "new" when they already had full multi-store links (hominy,
      dijon-mustard, balsamic-vinegar, rice-vinegar, red-wine-vinegar, teriyaki-sauce, enchilada-sauce).
  Output: out\staples500\candidates-clean.json (the genuinely-new pool for batches 2..N, batch1 + overlaps
  removed) + out\staples500\overlaps-report.csv (every flagged item, with why). Nothing is registered here.
#>
param([string]$OutDir = "")
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $root 'out\staples500' }

# PS 5.1: @(pipe | ConvertFrom-Json) NESTS a JSON array as ONE element - iterate/assign the parse result directly.
$approved = Get-Content (Join-Path $OutDir 'approved.json') -Raw | ConvertFrom-Json
$batch1 = @{}; foreach ($x in (Get-Content (Join-Path $OutDir 'batch1.json') -Raw | ConvertFrom-Json)) { $batch1[[string]$x.id] = $true }

function NormLabel([string]$s) { ((($s.ToLower() -replace '[^a-z0-9 ]', ' ') -replace '\s+', ' ').Trim() -replace 's\b', '') }

$regIds = @{}; $regLabels = @{}
foreach ($c in (Get-Content (Join-Path $root 'commodities.json') -Raw | ConvertFrom-Json)) {
  $regIds[[string]$c.id] = $true
  $nl = NormLabel ([string]$c.label); if ($nl) { $regLabels[$nl] = [string]$c.id }
}
$linked = @{}
$pd = (Get-Content (Join-Path $root 'product-urls.json') -Raw | ConvertFrom-Json).items
foreach ($p in $pd.PSObject.Properties) {
  $has = @($p.Value.PSObject.Properties | Where-Object { $_.Value -and $_.Value.url }).Count -gt 0
  if ($has) { $linked[[string]$p.Name] = $true }
}

$new = New-Object System.Collections.Generic.List[object]
$flagged = New-Object System.Collections.Generic.List[object]
foreach ($x in $approved) {
  $id = [string]$x.id; $nl = NormLabel ([string]$x.name); $reason = $null
  if ($batch1.ContainsKey($id)) { $reason = 'batch1-registered' }
  elseif ($regIds.ContainsKey($id)) { $reason = 'id-in-commodities' }
  elseif ($nl -and $regLabels.ContainsKey($nl)) { $reason = "label-dupe-of:$($regLabels[$nl])" }
  elseif ($linked.ContainsKey($id)) { $reason = 'orphan-product-urls-link' }
  if ($reason) { $flagged.Add([pscustomobject]@{ id = $id; name = [string]$x.name; category = [string]$x.category; reason = $reason }) }
  else { $new.Add($x) }
}

($new | ConvertTo-Json -Depth 5) | Set-Content (Join-Path $OutDir 'candidates-clean.json') -Encoding UTF8
$flagged | Export-Csv (Join-Path $OutDir 'overlaps-report.csv') -NoTypeInformation -Encoding UTF8

Write-Output ("approved: {0}   clean-new pool: {1}   flagged: {2}" -f @($approved).Count, $new.Count, $flagged.Count)
Write-Output 'flagged breakdown:'
$flagged | Group-Object { ($_.reason -split ':')[0] } | Sort-Object Count -Descending | ForEach-Object { Write-Output ("  {0,-26} {1}" -f $_.Name, $_.Count) }
Write-Output ''
Write-Output 'overlaps that are NOT batch1 (the real cleanup - would have been redundant new items):'
$nb = @($flagged | Where-Object { $_.reason -ne 'batch1-registered' })
foreach ($f in ($nb | Select-Object -First 60)) { Write-Output ("  {0,-26} [{1,-18}] {2}" -f $f.id, $f.category, $f.reason) }
if ($nb.Count -gt 60) { Write-Output ("  ... and " + ($nb.Count - 60) + " more (see overlaps-report.csv)") }
