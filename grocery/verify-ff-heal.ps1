<#
  verify-ff-heal.ps1 - the proof obligation for heal-ff-missing-products.ps1.

  Restoring a product to the catalogue is only a fix if the engine then PICKS it. Two things can silently
  swallow the restore:
    * commodity matching is first-match-wins by array order, so a restored product can be claimed by a
      different commodity than the one it was restored for ("Fresh Tomatoes, Hot House" landing on
      crushed-tomatoes instead of tomatoes);
    * the target commodity's own include/exclude rules can reject it outright, in which case the row sits in
      the file doing nothing and the board still shows the wrong price.
  Either way the file would look repaired while the board stayed broken. So: every restored commodity must
  now have a Family Fare everyday cell whose per-unit equals the linked product's. Exit 1 if any does not.
#>
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$root = $PSScriptRoot
$expF = Join-Path $root 'out\ff-heal-expected.json'
if (-not (Test-Path $expF)) { Write-Output 'no ff-heal-expected.json - nothing to verify'; exit 0 }
$exp = Read-JsonFile $expF

$cmpF = (Get-ChildItem (Join-Path $root 'out\comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1).FullName
$board = @((Read-JsonFile $cmpF).comparison)

$ok = 0; $bad = 0; $sale = 0
foreach ($p in $exp.PSObject.Properties) {
  $id = $p.Name; $want = [double]$p.Value
  $it = $board | Where-Object { $_.id -eq $id } | Select-Object -First 1
  $cells = @()
  if ($it) { $cells = @($it.stores | Where-Object { $_.store -eq 'Family Fare' }) }
  if (-not $cells.Count) {
    Write-Output ('  MISSING  {0,-22} restored the product but the board still has no Family Fare cell (claimed by another commodity, or rejected by this one''s rules)' -f $id)
    $bad++; continue
  }
  $ev = $cells | Where-Object { $_.type -eq 'everyday' } | Select-Object -First 1
  if ($ev) {
    $got = [double]$ev.per_unit
    if ([math]::Abs($got - $want) -le ([math]::Max(0.005, $want * 0.02))) { $ok++ }
    else {
      Write-Output ('  WRONG    {0,-22} expected {1}  got {2}   [{3}]' -f $id, [math]::Round($want,4), [math]::Round($got,4), [string]$ev.item)
      $bad++
    }
    continue
  }
  # A SALE cell outranking the restored everyday row is the CORRECT outcome, not a failure: this week the
  # store is charging less than its shelf price, and that is the number a shopper pays. The restored row is
  # still the right everyday price and takes over when the ad expires.
  $sl = $cells | Select-Object -First 1
  if ([double]$sl.per_unit -le ($want * 1.02)) { $sale++ }
  else {
    Write-Output ('  WRONG    {0,-22} only a SALE cell, and it is DEARER than the shelf price we restored: sale {1} vs shelf {2}' -f $id, [math]::Round([double]$sl.per_unit,4), [math]::Round($want,4))
    $bad++
  }
}
Write-Output ''
Write-Output ("restored cells now published at the verified shelf price : $ok")
Write-Output ("restored, but this week's SALE is cheaper and wins        : $sale  (correct - the shelf price takes over when the ad ends)")
Write-Output ("did NOT land                                             : $bad")
if ($bad -gt 0) { exit 1 }
exit 0
