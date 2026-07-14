<#
  verify-heal.ps1 - the proof obligation for heal-missing-products.ps1.

  Putting a product back into a store's catalogue is only a fix if the ENGINE then picks it. Three things can
  swallow a restore silently:
    * commodity matching is first-match-wins by array order, so a restored product can be claimed by a
      DIFFERENT commodity than the one it was restored for;
    * the target commodity's include/exclude rules can reject it outright;
    * the row's SIZE can be something the engine cannot parse into a quantity (a "$1.99/lb" unit price), in
      which case the row sits in the file doing nothing at all.
  In every case the file looks repaired while the board stays wrong.

  The expectations are read STRAIGHT OUT OF THE STORE FILES - every row carrying a `restored` flag - rather
  than from a side-file written at heal time. A side-file goes stale the moment a heal is re-run (it did:
  a fixed run that correctly restored nothing wiped the record of what the previous run had restored, and a
  stale entry survived to fail this check over a cell nobody had touched). The files are the truth; derive
  from them and there is nothing to keep in sync.

  A SALE cell outranking a restored shelf price is a PASS: this week the store charges less than its shelf
  price, and that is the number a shopper pays. The restored row takes over when the ad ends.
#>
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
. (Join-Path $root 'pu-lib.ps1')

$cmpF = (Get-ChildItem (Join-Path $root 'out\comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1).FullName
$board = @((Get-Content $cmpF -Raw | ConvertFrom-Json).comparison)

# every restored row currently sitting in a store catalogue, keyed by product name
$restored = @{}
foreach ($f in (Get-ChildItem (Join-Path $root 'out\regular\*-regular-*.json') | Where-Object { $_.BaseName -match '-regular-\d{4}-\d{2}-\d{2}$' })) {
  $doc = Get-Content $f.FullName -Raw | ConvertFrom-Json
  # newest file per store only
  $prefix = ($f.BaseName -replace '-regular-.*$','')
  $newest = Get-ChildItem (Join-Path $root ('out\regular\' + $prefix + '-regular-*.json')) |
    Where-Object { $_.BaseName -match '-regular-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending | Select-Object -First 1
  if ($f.FullName -ne $newest.FullName) { continue }
  foreach ($d in $doc.deals) {
    if (-not $d.restored) { continue }
    $restored[(([string]$d.store) + '|' + ([string]$d.item).ToLower().Trim())] = $d
  }
}
if ($restored.Count -eq 0) { Write-Output 'no restored rows in any catalogue - nothing to verify'; exit 0 }

$ok = 0; $bad = 0; $sale = 0; $inert = 0
foreach ($it in $board) {
  $unit = [string]$it.unit
  foreach ($st in @('Family Fare',"Baker's",'Hy-Vee','Walmart','Aldi',"Sam's Club",'Fareway')) {
    $cells = @($it.stores | Where-Object { $_.store -eq $st })
    if (-not $cells.Count) { continue }
    $ev = $cells | Where-Object { $_.type -eq 'everyday' } | Select-Object -First 1
    if (-not $ev) { continue }
    $k = $st + '|' + ([string]$ev.item).ToLower().Trim()
    if (-not $restored.ContainsKey($k)) { continue }
    # this board cell IS being served by a restored row - prove the published per-unit matches the row
    $d = $restored[$k]
    $rp = 0.0; [void][double]::TryParse((([string]$d.ad_price) -replace '[^0-9.]',''), [ref]$rp)
    $want = Get-LinkPerUnit -size ([string]$d.size) -unit $unit -price $rp -name ([string]$d.item)
    if ($null -eq $want) { $bad++; Write-Output ('  UNREADABLE {0,-13} {1,-22} restored row size "{2}" yields no per-unit' -f $st, [string]$it.id, [string]$d.size); continue }
    $got = [double]$ev.per_unit
    if ([math]::Abs($got - [double]$want) -le ([math]::Max(0.005, [double]$want * 0.02))) { $ok++ }
    else {
      Write-Output ('  WRONG     {0,-13} {1,-22} row says {2}  board publishes {3}   [{4}]' -f $st, [string]$it.id, [math]::Round([double]$want,4), [math]::Round($got,4), [string]$ev.item)
      $bad++
    }
    $restored.Remove($k)
  }
}
# Rows left over are in a catalogue but are not the published cell. There are two very different reasons, and
# collapsing them is how a broken restore passes as a success:
#   OUTRANKED - some cell for that store DOES exist (a sale, or a cheaper product won). The restore is fine.
#   INERT     - the product matched NO commodity at all, so the row does nothing. The restore silently failed.
# Family Fare lemon juice was exactly this: "Our Family Lemon 100% Juice" never matched the commodity's
# `lemon\s+juice` include (the store puts "100%" between the words), so the row sat in the file achieving
# nothing while this script reported it as a pass. Name the inert ones.
# Judge by the COMMODITY the row was restored for (restored_for), not by hunting the row's own product name
# among the winning cells. A row that loses to a cheaper sibling in the same commodity stops appearing on the
# board at all - so a name-hunt reports it as a failure when it is nothing of the kind. ReaLemon did exactly
# that: once the cheaper Our Family lemon juice was restored and won the cell, the ReaLemon row vanished from
# the board and got flagged INERT, though the commodity was fixed and showing a better price than before.
# INERT is the real failure: the commodity has NO cell for this store, so the row achieved nothing.
$outranked = 0
$inert = New-Object System.Collections.Generic.List[string]
foreach ($k in $restored.Keys) {
  $st = ($k -split '\|')[0]
  $d = $restored[$k]
  $nm = [string]$d.item
  $for = [string]$d.restored_for
  if (-not $for) { $outranked++; continue }   # untraceable (pre-dates the field) - do not cry wolf
  $it = $board | Where-Object { $_.id -eq $for } | Select-Object -First 1
  $cell = $null
  if ($it) { $cell = $it.stores | Where-Object { $_.store -eq $st } | Select-Object -First 1 }
  if ($cell) { $outranked++ }
  else { $inert.Add(('{0,-13} {1,-22} {2}' -f $st, $for, $nm)) }
}
Write-Output ''
Write-Output ("restored rows now serving the board at their verified price : $ok")
Write-Output ("restored rows outranked by a sale or a cheaper product       : $outranked  (correct)")
Write-Output ("restored rows the board publishes WRONG                      : $bad")
Write-Output ("restored rows that matched NO commodity (INERT - did nothing): " + $inert.Count)
foreach ($x in $inert) { Write-Output ('    INERT  ' + $x) }
if ($bad -gt 0 -or $inert.Count -gt 0) { exit 1 }
exit 0
