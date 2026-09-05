<#
  audit-ff-missing-products.ps1

  Today's Family Fare pull came back partial and OVERWROTE the full catalogue, so 104 products we hold a
  verified "See item" link for are absent from the regular file. Where the missing product was the CHEAPEST
  one at Family Fare, the engine silently fell back to a pricier product and the board now OVERSTATES what
  Family Fare charges (FF coffee published at $1.04/oz when the store sells 30.5 oz Folgers at $0.59/oz).

  Only 2 of the 104 tripped the factor guard, because the guard fires at 1.5x and most fallbacks landed
  closer than that - but "within 50%" is not "correct". This reports every one, ranked by how much the board
  overstates the store, so the repair set is chosen on evidence rather than on which ones happened to trip.

  Reports only; writes nothing. -Apply is handled by heal-ff-missing-products.ps1.
#>
param([string]$Store = 'Family Fare')
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$root = $PSScriptRoot

# same quantity math as guards.ps1 / audit-everyday-mismatch.ps1 - a repair judged by different math than the
# gate that will judge it is a repair you cannot trust.
. (Join-Path $root 'pu-lib.ps1')   # the one true per-unit math

$cmpF = (Get-ChildItem (Join-Path $root 'out\comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1).FullName
$board = @((Read-JsonFile $cmpF).comparison)
$pd = (Read-JsonFile (Join-Path $root 'product-urls.json')).items

# Store display name -> data-file prefix. Do NOT derive this by stripping punctuation: "Sam's Club" becomes
# "samsclub", the file is "sams-regular-*.json", Get-ChildItem returns nothing, and the script dies on a null
# path. An explicit map fails loudly on an unknown store instead of silently looking in the wrong place.
$PREFIX = @{ 'Family Fare'='family-fare'; "Baker's"='bakers'; 'Hy-Vee'='hyvee'; 'Walmart'='walmart'; 'Aldi'='aldi'; "Sam's Club"='sams'; 'Fareway'='fareway' }
if (-not $PREFIX.ContainsKey($Store)) { throw ("unknown store '$Store' - add it to the PREFIX map") }
$prefix = $PREFIX[$Store]
$regF = (Get-ChildItem (Join-Path $root ('out\regular\' + $prefix + '-regular-*.json')) |
  Where-Object { $_.BaseName -match '-regular-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending | Select-Object -First 1)
$have = @{}
foreach ($r in (Read-JsonFile $regF.FullName).deals) { $have[([string]$r.item).ToLower().Trim()] = $true }

$rows = New-Object System.Collections.Generic.List[object]
foreach ($it in $board) {
  $id = [string]$it.id; $unit = [string]$it.unit
  $e = $pd.$id.$Store
  if (-not ($e -and $e.name -and $e.price)) { continue }
  if ($have.ContainsKey(([string]$e.name).ToLower().Trim())) { continue }   # product IS in the file - nothing missing

  $lp = 0.0; [void][double]::TryParse((([string]$e.price) -replace '[^0-9.]',''), [ref]$lp)
  $ppu = Get-LinkPerUnit -size ([string]$e.size) -unit $unit -price $lp -name ([string]$e.name)
  $linkPu = if ($null -ne $ppu) { [double]$ppu } else { 0 }

  $cell = $it.stores | Where-Object { $_.store -eq $Store -and $_.type -eq 'everyday' } | Select-Object -First 1
  $boardPu = if ($cell) { [double]$cell.per_unit } else { 0 }
  # A commodity with a SALE cell is NOT missing this store. An earlier version only looked at everyday cells
  # and so reported 20 commodities as having "no Family Fare price" when the board was in fact showing Family
  # Fare's weekly-ad price for the very same product - cheaper than the shelf price, and the number a shopper
  # actually pays. Absence of an everyday cell is not absence of a price.
  $anyCell = $it.stores | Where-Object { $_.store -eq $Store } | Select-Object -First 1

  $ratio = if ($boardPu -gt 0 -and $linkPu -gt 0) { [math]::Round($linkPu / $boardPu, 3) } else { 0 }
  $verdict = 'no board cell'
  if ($linkPu -le 0) { $verdict = 'UNPARSEABLE SIZE - do not restore' }
  elseif ($boardPu -le 0 -and $anyCell) { $verdict = 'on sale this week - shelf price is a useful backstop, not a fix' }
  elseif ($boardPu -le 0) { $verdict = 'restore: store has no cell at all' }
  elseif ($ratio -lt 0.98) { $verdict = 'RESTORE - board OVERSTATES the store' }
  elseif ($ratio -gt 1.02) { $verdict = 'link is dearer than the board pick - leave board alone' }
  else { $verdict = 'agrees - harmless' }

  $rows.Add([pscustomobject]@{
    id=$id; unit=$unit; board_pu=[math]::Round($boardPu,4); link_pu=[math]::Round($linkPu,4); ratio=$ratio
    board_item=$(if($cell){[string]$cell.item}else{''}); link_item=[string]$e.name
    link_price=$lp; link_size=[string]$e.size; verdict=$verdict
  })
}

$restore = @($rows | Where-Object { $_.verdict -like 'RESTORE*' -or $_.verdict -like 'restore*' } | Sort-Object ratio)
$dearer  = @($rows | Where-Object { $_.verdict -like 'link is dearer*' })
$agree   = @($rows | Where-Object { $_.verdict -eq 'agrees - harmless' })
$bad     = @($rows | Where-Object { $_.verdict -like 'UNPARSEABLE*' })

Write-Output ("$Store link products absent from the regular file: " + $rows.Count)
Write-Output ''
Write-Output ("  RESTORE (board overstates the store)      : " + $restore.Count)
Write-Output ("  link dearer than board pick (leave alone) : " + $dearer.Count)
Write-Output ("  board already agrees with the link        : " + $agree.Count)
Write-Output ("  unparseable size (never restore blindly)  : " + $bad.Count)
Write-Output ''
Write-Output 'RESTORE set - board price / true cheapest verified price:'
Write-Output ('{0,-26} {1,-9} {2,-9} {3,-7} {4}' -f 'commodity','board','link','ratio','cheaper product Family Fare actually sells')
foreach ($r in $restore) {
  Write-Output ('{0,-26} {1,-9} {2,-9} {3,-7} {4}' -f $r.id, ('$'+$r.board_pu), ('$'+$r.link_pu), $r.ratio, ($r.link_item + '  $' + $r.link_price + ' / ' + $r.link_size))
}
if ($bad.Count) {
  Write-Output ''
  Write-Output 'UNPARSEABLE SIZE (excluded from the repair - a bad size makes a bad per-unit):'
  foreach ($r in $bad) { Write-Output ('  ' + $r.id.PadRight(26) + ' size="' + $r.link_size + '"  unit=' + $r.unit + '  ' + $r.link_item) }
}

($rows | ConvertTo-Json -Depth 5) | Set-Content (Join-Path $root 'out\ff-missing-products.json') -Encoding UTF8
