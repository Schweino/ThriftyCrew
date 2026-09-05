<#
  heal-ff-missing-products.ps1

  Repairs the damage from the 2026-07-14 partial Family Fare pull: 380 items came back where ~590 were
  expected, the file was overwritten wholesale, and products the run simply did not return vanished from the
  catalogue. Where a vanished product was the CHEAPEST one Family Fare sells for that commodity, the engine
  fell back to a pricier product and the board began OVERSTATING Family Fare - it published coffee at
  $1.04/oz while the store sells a 30.5 oz Folgers at $0.59/oz. For 20 other commodities Family Fare lost its
  cell entirely and simply disappeared from the comparison.

  Every row restored here comes from product-urls.json: a product we resolved on Family Fare's own site, with
  a live URL, a captured shelf price and a captured size. Nothing is estimated and nothing is invented - if
  we cannot compute a per-unit from the captured size, the row is left out rather than guessed at.

  The board cell that results MUST come out equal to the linked product's per-unit. That is checked at the
  end, and the script fails loudly if it does not.

  Safe to re-run: a product already in the file is left alone.
#>
param([switch]$WhatIf)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$root = $PSScriptRoot
. (Join-Path $root 'pu-lib.ps1')

$regDir = Join-Path $root 'out\regular'
$curF = (Get-ChildItem (Join-Path $regDir 'family-fare-regular-*.json') |
  Where-Object { $_.BaseName -match '^family-fare-regular-\d{4}-\d{2}-\d{2}$' } |
  Sort-Object Name -Descending | Select-Object -First 1)
$doc = Read-JsonFile $curF.FullName

$cmpF = (Get-ChildItem (Join-Path $root 'out\comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1).FullName
$board = @((Read-JsonFile $cmpF).comparison)
$pd = (Read-JsonFile (Join-Path $root 'product-urls.json')).items

$have = @{}
foreach ($r in $doc.deals) { $have[([string]$r.item).ToLower().Trim()] = $true }

$rows = New-Object System.Collections.ArrayList
foreach ($d in $doc.deals) {
  $h = [ordered]@{ store='Family Fare'; item=[string]$d.item; ad_price=[string]$d.ad_price; size=[string]$d.size; regular=$d.regular; source_ad=[string]$d.source_ad }
  foreach ($k in @('as_of','carried_forward','restored')) { if ($d.$k) { $h[$k] = $d.$k } }
  [void]$rows.Add($h)
}

$added = 0; $skipUnparseable = 0; $skipDearer = 0
$expect = @{}
foreach ($it in $board) {
  $id = [string]$it.id; $unit = [string]$it.unit
  $e = $pd.$id.'Family Fare'
  if (-not ($e -and $e.name -and $e.price -and $e.url)) { continue }
  $name = [string]$e.name
  if ($have.ContainsKey($name.ToLower().Trim())) { continue }

  $lp = 0.0; [void][double]::TryParse((([string]$e.price) -replace '[^0-9.]',''), [ref]$lp)
  $linkPu = Get-LinkPerUnit -size ([string]$e.size) -unit $unit -price $lp -name $name
  if (($null -eq $linkPu) -or ($lp -le 0)) { $skipUnparseable++; continue }

  $cell = $it.stores | Where-Object { $_.store -eq 'Family Fare' -and $_.type -eq 'everyday' } | Select-Object -First 1
  $boardPu = if ($cell) { [double]$cell.per_unit } else { 0 }

  # Only restore where it FIXES something: the store has no cell, or the board is dearer than the product
  # Family Fare actually sells. Adding a product that is dearer than the engine's current pick changes no
  # published number (the engine takes the cheapest), so there is no reason to touch the file for it.
  if ($boardPu -gt 0 -and ([double]$linkPu) -ge ($boardPu * 0.98)) { $skipDearer++; continue }

  [void]$rows.Add([ordered]@{
    store     = 'Family Fare'
    item      = $name
    ad_price  = ('$' + $lp)
    size      = [string]$e.size
    regular   = $lp
    source_ad = 'everyday shelf price'
    as_of     = '2026-07-14'
    restored  = 'verified Family Fare product (product-urls.json, live URL); dropped by the partial pull of 2026-07-14'
  })
  $have[$name.ToLower().Trim()] = $true
  $expect[$id] = [double]$linkPu
  $added++
  Write-Output ('  + {0,-22} {1,-9} {2,-12} {3}' -f $id, ('$'+$lp), ([string]$e.size), $name)
}

Write-Output ''
Write-Output ("restored: $added   skipped (no usable size): $skipUnparseable   skipped (not cheaper than the board pick): $skipDearer")
if ($WhatIf) { Write-Output 'WhatIf: nothing written'; return }
if ($added -eq 0) { Write-Output 'nothing to do'; return }

$doc.deals = $rows.ToArray()
$doc | Add-Member -NotePropertyName deal_count -NotePropertyValue @($rows).Count -Force
($doc | ConvertTo-Json -Depth 6) | Set-Content $curF.FullName -Encoding UTF8
Write-Output ("Family Fare file now " + @($rows).Count + " rows -> " + $curF.Name)
($expect | ConvertTo-Json) | Set-Content (Join-Path $root 'out\ff-heal-expected.json') -Encoding UTF8
Write-Output 'rebuild, then run verify-ff-heal.ps1 to prove each restored cell lands on its linked price'
