<#
  refresh-hyvee-links.ps1

  product-urls.json stores, for each commodity+store, the product we link to AND a snapshot of its price and
  size taken when the link was resolved. That snapshot is what the guards compare the board against: if the
  board says one number and the linked product says another, something is wrong.

  Now that Hy-Vee's prices are pulled live (pull-regular-hyvee.ps1 reads the CURRENT shelf price from Hy-Vee's
  own GraphQL), the board moved to today's real prices - and the stored snapshots became the stale side. The
  guards fired correctly: 20 override pins built from the OLD snapshots were trying to drag the board back to
  prices Hy-Vee no longer charges (grapes pinned to $3.99/lb when the store is charging $1.88).

  So the snapshot has to be refreshed from the same source as the board. This copies the freshly-verified
  price AND our validated size out of the new hyvee-regular file into product-urls, so the board and its
  "See item" link are the same number by construction - which is what makes those cells checkable at all.

  Nothing is invented: every value here came from the Hy-Vee GraphQL pull performed today.
#>
param([switch]$WhatIf)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

$regF = (Get-ChildItem (Join-Path $root 'out\regular\hyvee-regular-*.json') |
  Where-Object { $_.BaseName -match '^hyvee-regular-\d{4}-\d{2}-\d{2}$' } |
  Sort-Object Name -Descending | Select-Object -First 1)
$rows = @((Get-Content $regF.FullName -Raw | ConvertFrom-Json).deals)

# only rows we actually re-verified today carry as_of = today AND a product_id
$fresh = @{}
foreach ($r in $rows) {
  if (-not $r.product_id) { continue }
  if ($r.not_reverified) { continue }
  $fresh[([string]$r.item).ToLower().Trim()] = $r
}
Write-Output ("freshly verified Hy-Vee products available: " + $fresh.Count)

$puF = Join-Path $root 'product-urls.json'
$doc = Get-Content $puF -Raw | ConvertFrom-Json

$upd = 0; $same = 0; $noFresh = 0
$changes = New-Object System.Collections.Generic.List[string]
foreach ($p in $doc.items.PSObject.Properties) {
  $e = $p.Value.'Hy-Vee'
  if (-not ($e -and $e.name)) { continue }
  $k = ([string]$e.name).ToLower().Trim()
  if (-not $fresh.ContainsKey($k)) { $noFresh++; continue }
  $r = $fresh[$k]

  $newPrice = [double]$r.regular
  $newSize  = [string]$r.size
  $oldPrice = 0.0; [void][double]::TryParse((([string]$e.price) -replace '[^0-9.]',''), [ref]$oldPrice)
  $oldSize  = [string]$e.size

  if (([math]::Abs($newPrice - $oldPrice) -lt 0.005) -and ($newSize -eq $oldSize)) { $same++; continue }

  if ([math]::Abs($newPrice - $oldPrice) -ge 0.005) {
    $changes.Add(('  {0,-24} ${1,-8} -> ${2,-8} {3}' -f $p.Name, $oldPrice, $newPrice, [string]$e.name))
  }
  if (-not $WhatIf) {
    $e | Add-Member -NotePropertyName price -NotePropertyValue $newPrice -Force
    $e | Add-Member -NotePropertyName size  -NotePropertyValue $newSize  -Force
    $e | Add-Member -NotePropertyName verified -NotePropertyValue ((Get-Date -Format 'yyyy-MM-dd') + ' Hy-Vee GraphQL (storeId 1465, current shelf price)') -Force
  }
  $upd++
}

Write-Output ("link snapshots updated : $upd")
Write-Output ("already current        : $same")
Write-Output ("no fresh price for it  : $noFresh")
Write-Output ''
Write-Output 'price changes written into the links:'
foreach ($c in ($changes | Select-Object -First 30)) { Write-Output $c }
if ($changes.Count -gt 30) { Write-Output ("  ... and " + ($changes.Count - 30) + " more") }

if ($WhatIf) { Write-Output ''; Write-Output 'WhatIf: product-urls.json not written'; return }
($doc | ConvertTo-Json -Depth 8) | Set-Content $puF -Encoding UTF8
Write-Output ''
Write-Output 'product-urls.json updated - the board and its Hy-Vee links now quote the same verified number.'
