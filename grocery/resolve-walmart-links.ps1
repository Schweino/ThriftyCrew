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

$reg = Get-Content (Join-Path $root 'out\regular\walmart-regular-2026-07-15.json') -Raw | ConvertFrom-Json
$regMap = @{}; foreach ($r in @($reg.deals)) { $regMap[[string]$r.item] = $r }

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
  if ($regMap.ContainsKey($name)) { $rr = $regMap[$name]; $price = [double]$rr.current_price; $size = [string]$rr.size }
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
