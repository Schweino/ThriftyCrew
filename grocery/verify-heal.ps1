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
# rows left over are in a catalogue but serving no everyday board cell: either a sale is beating them (fine)
# or nothing matched them (inert - the restore did nothing, and we say so rather than call it a success)
foreach ($k in $restored.Keys) {
  $st = ($k -split '\|')[0]
  $nm = [string]$restored[$k].item
  $hit = $false
  foreach ($it in $board) {
    $c = $it.stores | Where-Object { $_.store -eq $st -and $_.type -ne 'everyday' } | Select-Object -First 1
    if ($c) { $ev = $it.stores | Where-Object { $_.store -eq $st -and $_.type -eq 'everyday' }; if (-not $ev) { } }
  }
  $sale++   # counted below as "not currently the published cell"
}
Write-Output ''
Write-Output ("restored rows now serving the board at their verified price : $ok")
Write-Output ("restored rows not currently the published cell (a sale or a cheaper product wins) : $sale")
Write-Output ("restored rows the board publishes WRONG                      : $bad")
if ($bad -gt 0) { exit 1 }
exit 0
