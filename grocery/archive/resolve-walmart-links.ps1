<#
  resolve-walmart-links.ps1 - offline "See item" link resolver for the Batch-1 Walmart no-link chips.
  The batch capture saved name->usItemId in out\staples500\walmart-itemids.json, and the SAME capture
  string is the board winner's name, so board_item matches the map key exactly. For each Walmart chip the
  worklist flags reason='missing' (no link), look up its usItemId and write a /ip/<id> link into
  product-urls.json (price+size from walmart-regular). ADD-only: never touches existing links or other stores.
#>
$ErrorActionPreference = 'Stop'
$root = 'C:\Codex\income\grocery'

$wl    = Get-Content (Join-Path $root 'out\url-worklist.json') -Raw | ConvertFrom-Json
$chips = @($wl.stores.Walmart) | Where-Object { $_.reason -eq 'missing' }

$ids = Get-Content (Join-Path $root 'out\staples500\walmart-itemids.json') -Raw | ConvertFrom-Json
$idMap = @{}; foreach ($p in $ids.PSObject.Properties) { $idMap[$p.Name] = [string]$p.Value }

# Auto-discover the NEWEST canonical file. This was hardcoded to walmart-regular-2026-07-15.json, so every run
# after that date silently resolved links against a frozen snapshot - the price it stamped on a link was
# whatever Walmart charged the day the path was typed. Same shape as the regression where bare compare-deals
# dropped Sam's: a hardcoded input is a stale input the moment the calendar moves.
$regF = Get-ChildItem (Join-Path $root 'out\regular\walmart-regular-*.json') |
  Where-Object { $_.BaseName -match '^walmart-regular-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Desc | Select-Object -First 1
if (-not $regF) { Write-Output 'no canonical walmart-regular-<date>.json found'; exit 1 }
Write-Output ("walmart regular file: " + $regF.Name)
$reg = Get-Content $regF.FullName -Raw | ConvertFrom-Json
# keyed name+SIZE: Walmart ships 5 duplicate names, and a name-keyed map silently keeps only the last row.
$regMap = @{}; $regSizes = @{}
foreach ($r in @($reg.deals)) {
  $rn = [string]$r.item
  $regMap[$rn + '|' + ([string]$r.size).Trim()] = $r
  if (-not $regSizes.ContainsKey($rn)) { $regSizes[$rn] = @() }
  $regSizes[$rn] = $regSizes[$rn] + @(([string]$r.size).Trim())
}

$comm = Get-Content (Join-Path $root 'commodities.json') -Raw | ConvertFrom-Json
$labelMap = @{}; foreach ($c in $comm) { $labelMap[[string]$c.id] = [string]$c.label }

$pf = Join-Path $root 'product-urls.json'
$pd = Get-Content $pf -Raw | ConvertFrom-Json

$added = 0; $nomatch = New-Object System.Collections.ArrayList
foreach ($ch in $chips) {
  $name = [string]$ch.board_item
  if (-not $name -or -not $idMap.ContainsKey($name)) { [void]$nomatch.Add(($ch.id + ' | ' + $name)); continue }
  $itemId = $idMap[$name]
  $price = 0.0; $size = ''
  # take the row matching the chip's own size; where the name is sold in several sizes and none matches, leave
  # price/size empty rather than stamp the wrong product's numbers onto the link.
  if ($regSizes.ContainsKey($name)) {
    $csz = @($regSizes[$name])
    $rr = $null
    if ($csz.Count -eq 1) { $rr = $regMap[$name + '|' + $csz[0]] }
    elseif ($regMap.ContainsKey($name + '|' + ([string]$ch.size).Trim())) { $rr = $regMap[$name + '|' + ([string]$ch.size).Trim()] }
    if ($rr) { $price = [double]$rr.current_price; $size = [string]$rr.size }
  }
  $url = 'https://www.walmart.com/ip/' + $itemId
  $id = [string]$ch.id
  if (-not ($pd.items.PSObject.Properties.Name -contains $id)) {
    $label = if ($labelMap.ContainsKey($id)) { $labelMap[$id] } else { $id }
    $pd.items | Add-Member -NotePropertyName $id -NotePropertyValue ([pscustomobject]@{ commodity = $label }) -Force
  }
  $entry = [pscustomobject]@{ url = $url; price = $price; size = $size; name = $name }
  $pd.items.$id | Add-Member -NotePropertyName 'Walmart' -NotePropertyValue $entry -Force
  $added++
}
($pd | ConvertTo-Json -Depth 10) | Set-Content $pf -Encoding UTF8
Write-Output ("Walmart missing chips: " + @($chips).Count + " ; links added: $added ; no-itemid-match: " + $nomatch.Count)
$nomatch | Select-Object -First 25 | ForEach-Object { Write-Output ('  MISS ' + $_) }
