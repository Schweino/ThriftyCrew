<#
  purge-offtarget-primer-rows.ps1 - the primer's contract is "contribute ONLY on-target candidates". A row the
  primer added that, after the round-2 exclude tightening, no longer matches ANY of the batch's own commodities
  is pollution: it sits in the SHARED store file forever and can be claimed by some OTHER commodity, silently
  re-pricing an existing board cell (that is exactly how 'Marie Callender's Turkey Breast & Stuffing' ended up
  pricing STUFFING-MIX at Family Fare).

  Scope is deliberately tiny and reversible: only rows whose source_ad says 'batch primer' AND whose as_of is
  today are eligible, so nothing captured by any other pull can ever be touched.
#>
param([switch]$WhatIf, [string]$IdsFile = 'out\r300\r300-ids.txt')
$ErrorActionPreference = 'Stop'
$root = 'C:\Codex\income\grocery'
$today = (Get-Date).ToString('yyyy-MM-dd')
# every registered batch id must be considered, not just the batch being purged: a row primed for batch A that
# legitimately belongs to batch B must not be deleted as "off-target".
$ids = @()
foreach ($f in @('out\r300\r300-ids.txt', 'out\r300\batch8-ids.txt')) {
  $p = Join-Path $root $f
  if (Test-Path $p) { $ids += ((Get-Content $p -Raw).Trim() -split ',') }
}
$ids = @($ids | Where-Object { $_ })

$rules = @{}
foreach ($c in (Get-Content (Join-Path $root 'commodities.json') -Raw | ConvertFrom-Json)) { $rules[[string]$c.id] = $c }
function Test-Match([string]$name, [string]$id) {
  $r = $rules[$id]; if (-not $r) { return $false }
  $ok = $false; foreach ($p in $r.include) { if ($p -and $name -imatch $p) { $ok = $true; break } }
  if (-not $ok) { return $false }
  foreach ($p in $r.exclude) { if ($p -and $name -imatch $p) { return $false } }
  return $true
}

foreach ($f in @("family-fare-regular-$today.json", "hyvee-regular-$today.json")) {
  $p = Join-Path $root ('out\regular\' + $f)
  if (-not (Test-Path $p)) { Write-Output ("  (no file) " + $f); continue }
  $doc = Get-Content $p -Raw | ConvertFrom-Json
  $keep = New-Object System.Collections.ArrayList
  $drop = New-Object System.Collections.Generic.List[string]
  foreach ($r in @($doc.deals)) {
    $isPrimer = ([string]$r.source_ad -match 'batch primer') -and ([string]$r.as_of -eq $today)
    if (-not $isPrimer) { [void]$keep.Add($r); continue }
    $onTarget = $false
    foreach ($id in $ids) { if (Test-Match ([string]$r.item) $id) { $onTarget = $true; break } }
    if ($onTarget) { [void]$keep.Add($r) } else { $drop.Add([string]$r.item) }
  }
  Write-Output ("  {0}: {1} rows -> keep {2}, purge {3}" -f $f, @($doc.deals).Count, $keep.Count, $drop.Count)
  foreach ($d in $drop) { Write-Output ("      purge: " + $d) }
  if (-not $WhatIf -and $drop.Count) {
    $doc.deals = $keep.ToArray()
    if ($doc.PSObject.Properties['deal_count']) { $doc.deal_count = $keep.Count }
    ($doc | ConvertTo-Json -Depth 6) | Set-Content $p -Encoding UTF8
    $null = Get-Content $p -Raw | ConvertFrom-Json
  }
}
if ($WhatIf) { Write-Output ''; Write-Output 'WhatIf: nothing written' }
