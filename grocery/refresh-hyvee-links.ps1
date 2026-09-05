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
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$root = $PSScriptRoot

$regF = (Get-ChildItem (Join-Path $root 'out\regular\hyvee-regular-*.json') |
  Where-Object { $_.BaseName -match '^hyvee-regular-\d{4}-\d{2}-\d{2}$' } |
  Sort-Object Name -Descending | Select-Object -First 1)
$rows = @((Read-JsonFile $regF.FullName).deals)

# only rows we actually re-verified today carry as_of = today AND a product_id
$fresh = @{}
# KEY BY NAME **AND SIZE**, NOT NAME ALONE.
# Hy-Vee sells one name in several sizes - "Spice World Minced Garlic" is BOTH 32 oz/$8.99 and 4.5 oz/$3.49;
# "Dinty Moore Beef Stew" is BOTH 15 oz/$3.49 and 38 oz/$6.99. 13 names in the current file are ambiguous and
# 9 of them serve a LINKED commodity. A name-keyed hashtable keeps only the LAST such row, so which product a
# link got refreshed from was decided by nothing but row order in the file - and this writes BOTH the price and
# the size into the link, so a wrong row leaves the record internally consistent and completely false. That is
# the same bug resolve-hyvee-links had (fixed 2026-07-16) and the same family as the board-match collisions:
# ALWAYS SUSPECT A DICTIONARY KEYED BY A PRODUCT NAME.
#   Keyed name|SIZE for the exact lookup, plus a name->sizes index so an ambiguous name can be reported rather
#   than guessed. Deliberately NOT a hashtable of List[object]: in PowerShell 5.1 `@($hash[$key])` THROWS
#   ("Argument types do not match") when the value is a generic List, which would have crashed this script on
#   every run and silently stopped Hy-Vee's links refreshing altogether. (Related 5.1 trap: `@($hash[$missing])`
#   returns COUNT 1, not 0, because @($null) is a one-element array - so always gate on ContainsKey.)
$sizesOf = @{}
foreach ($r in $rows) {
  if (-not $r.product_id) { continue }
  if ($r.not_reverified) { continue }
  $n = ([string]$r.item).ToLower().Trim()
  $fresh[$n + '|' + ([string]$r.size).Trim()] = $r
  if (-not $sizesOf.ContainsKey($n)) { $sizesOf[$n] = @() }
  $sizesOf[$n] = $sizesOf[$n] + @(([string]$r.size).Trim())
}
$ambiguous = 0
foreach ($n in $sizesOf.Keys) { if ($sizesOf[$n].Count -gt 1) { $ambiguous++ } }
Write-Output ("freshly verified Hy-Vee products available: " + $sizesOf.Count + " name(s)" + $(if ($ambiguous) { " ($ambiguous sold in more than one size - matched by name+SIZE, never by name alone)" } else { '' }))

$puF = Join-Path $root 'product-urls.json'
$doc = Read-JsonFile $puF

$upd = 0; $same = 0; $noFresh = 0; $ambigSkip = 0
$changes = New-Object System.Collections.Generic.List[string]
$skips = New-Object System.Collections.Generic.List[string]
foreach ($p in $doc.items.PSObject.Properties) {
  $e = $p.Value.'Hy-Vee'
  if (-not ($e -and $e.name)) { continue }
  $k = ([string]$e.name).ToLower().Trim()
  if (-not $sizesOf.ContainsKey($k)) { $noFresh++; continue }
  # Take the row that is the SAME SIZE as the product this link already points at. If the name is sold in only
  # one size, that row is unambiguous and its size is authoritative. Otherwise the size must match ours, or we
  # REFUSE: we cannot tell which of the store's products this link means, and guessing writes a real price onto
  # the wrong quantity - internally consistent, completely false.
  $r = $null
  $sz = @($sizesOf[$k])
  if ($sz.Count -eq 1) { $r = $fresh[$k + '|' + $sz[0]] }
  else {
    $ours = ([string]$e.size).Trim()
    if ($fresh.ContainsKey($k + '|' + $ours)) { $r = $fresh[$k + '|' + $ours] }
  }
  if (-not $r) {
    $ambigSkip++
    $skips.Add(('  {0,-24} AMBIGUOUS: ours=[{1}] but "{2}" is sold as {3} - refusing to guess' -f $p.Name, [string]$e.size, [string]$e.name, ($sz -join ' / ')))
    continue
  }

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
Write-Output ("ambiguous, left alone  : $ambigSkip")
foreach ($s in $skips) { Write-Output $s }
Write-Output ''
Write-Output 'price changes written into the links:'
foreach ($c in ($changes | Select-Object -First 30)) { Write-Output $c }
if ($changes.Count -gt 30) { Write-Output ("  ... and " + ($changes.Count - 30) + " more") }

if ($WhatIf) { Write-Output ''; Write-Output 'WhatIf: product-urls.json not written'; return }
($doc | ConvertTo-Json -Depth 8) | Set-Content $puF -Encoding UTF8
Write-Output ''
Write-Output 'product-urls.json updated - the board and its Hy-Vee links now quote the same verified number.'
