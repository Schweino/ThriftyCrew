<#
  import-walmart-batch.ps1 - turn the Walmart __NEXT_DATA__ capture (name~~linePrice~~unitPrice~~usItemId per
  product, tab-keyed by commodity) into walmart-regular rows. Walmart gives the UNIT price ("17.9 ¢/oz",
  "$5.31/lb"), not a size, so we back the size out: size = linePrice / per-unit. compare-deals then matches by
  the same rules and recomputes per-unit (which equals Walmart's, by construction). Also stashes name->usItemId
  so the winning product's /ip/<id> link can be resolved after compare-deals picks the cell.
  NOTE: store is Bellevue 68123 (Omaha metro, Brad OK'd 2026-07-15 - Walmart zone-prices are uniform across the
  metro). Usage: .\import-walmart-batch.ps1 ; then compare-deals -> diff-board -> vet.
#>
param([string]$Raw = 'out\staples500\walmart-batch1-raw.txt')
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$today = (Get-Date).ToString('yyyy-MM-dd')
$regDir = Join-Path $root 'out\regular'

function Parse-WMSize([string]$unitStr, [double]$total) {
  # ASCII-only: the cents symbol encodes unreliably, so detect cents by the ABSENCE of a '$' (Walmart shows
  # "17.9 (cent)/oz" vs "$5.31/lb"). \D* swallows whatever the cents glyph decoded to, between number and '/'.
  $hasDollar = $unitStr.Contains('$')
  $m = [regex]::Match($unitStr, '([\d.]+)\D*/\s*(fl\s*oz|floz|oz|lb|ea|ct|each|count)', 'IgnoreCase')
  if (-not $m.Success) { return $null }
  $num = [double]$m.Groups[1].Value
  $unit = ($m.Groups[2].Value.ToLower() -replace '\s+', ' ')
  if ($unit -match '^(ea|each|ct|count)$') { return $null }   # per-each basis: no weight to back out
  $perunit = $num; if (-not $hasDollar) { $perunit = $num / 100.0 }
  if ($perunit -le 0) { return $null }
  $qty = [math]::Round($total / $perunit, 1)
  if ($qty -le 0) { return $null }
  $u = 'oz'; if ($unit -match 'fl') { $u = 'fl oz' } elseif ($unit -match 'lb') { $u = 'lb' }
  return ("$qty $u")
}

$lines = Get-Content (Join-Path $root $Raw)
$rows = New-Object System.Collections.ArrayList
$ids = @{}
foreach ($ln in $lines) {
  if (-not ($ln -match "`t")) { continue }
  $prodStr = ($ln -split "`t", 2)[1]
  foreach ($p in ($prodStr -split '\|')) {
    $f = $p -split '~~'
    if ($f.Count -lt 3) { continue }
    $nm = ($f[0]).Trim()
    $price = 0.0; [void][double]::TryParse((($f[1]) -replace '[^0-9.]', ''), [ref]$price)
    $unitStr = [string]$f[2]
    $itemId = ''; if ($f.Count -ge 4) { $itemId = ($f[3]).Trim() }
    if ($price -le 0 -or -not $nm) { continue }
    $size = Parse-WMSize $unitStr $price
    if (-not $size) { continue }
    [void]$rows.Add([ordered]@{ store = 'Walmart'; item = $nm; ad_price = ('$' + $price); size = $size; regular = $price; current_price = $price; source_ad = 'Walmart Bellevue 68123 shelf price (batch capture)'; as_of = $today })
    if ($itemId) { $ids[$nm] = $itemId }
  }
}

# ADD-only merge into today's walmart-regular
$prefix = 'walmart-regular'
$prev = Get-ChildItem (Join-Path $regDir ($prefix + '-*.json')) -EA SilentlyContinue | Where-Object { $_.BaseName -match ('^' + $prefix + '-\d{4}-\d{2}-\d{2}$') } | Sort-Object Name -Descending | Select-Object -First 1
$merged = New-Object System.Collections.ArrayList; $seen = @{}; $doc = $null
if ($prev) { $doc = Get-Content $prev.FullName -Raw | ConvertFrom-Json; foreach ($r in @($doc.deals)) { [void]$merged.Add($r); $seen[(([string]$r.item) + '|' + ([string]$r.size)).ToLower()] = $true } }
$added = 0
foreach ($r in $rows) { $k = (([string]$r.item) + '|' + ([string]$r.size)).ToLower(); if ($seen.ContainsKey($k)) { continue }; $seen[$k] = $true; [void]$merged.Add([pscustomobject]$r); $added++ }
$outFile = Join-Path $regDir ($prefix + "-$today.json")
if ($doc) { $doc.deals = $merged.ToArray(); if ($doc.PSObject.Properties['deal_count']) { $doc.deal_count = $merged.Count } else { $doc | Add-Member deal_count $merged.Count -Force }; ($doc | ConvertTo-Json -Depth 6) | Set-Content $outFile -Encoding UTF8 }
else { ([ordered]@{ store = 'Walmart'; week_of = $today; price_type = 'everyday'; price_mode = 'in-store'; deal_count = $merged.Count; deals = $merged.ToArray() } | ConvertTo-Json -Depth 6) | Set-Content $outFile -Encoding UTF8 }
($ids | ConvertTo-Json) | Set-Content (Join-Path $root 'out\staples500\walmart-itemids.json') -Encoding UTF8
Write-Output ("Walmart: parsed $($rows.Count) sized rows, added $added new, total $($merged.Count); name->itemId map: $($ids.Count) -> $(Split-Path $outFile -Leaf)")
