<#
  purge-bad-lows.ps1 - delete price-history weeks whose "cheapest" is physically impossible, then recompute
  record_low from what is left.

  WHY. record_low drives the board's buy/wait verdict, and update-history keeps each old week's LOWEST entry
  when it compacts, so a corrupt low can never age out. Today the page tells shoppers "Lowest we have tracked:
  $0.03/lb brown sugar. If it can wait, it usually comes back down." That price never existed: on 2026-07-12
  EVERY store's sugar and brown-sugar figure is exactly ~16x below the next day's, i.e. a per-oz rate printed
  as a per-lb rate across the whole board. Those are basis errors, not prices.

  TEST. A week is impossible when its cheapest_price is >= $MinRatio below the lowest price recorded in ANY
  other week for the same commodity. That is deliberately conservative: a real sale is a fraction cheaper, not
  a third of the cheapest week ever seen.

  Two shapes are handled differently and reported separately:
    BOARD-WIDE  every store in that week sits at the same wrong factor -> the whole week is a basis error
    SINGLE-STORE only the winner is absurd -> drop just that week's row for this commodity
  Either way the row is deleted, not edited: we do not know the true number, only that this one is wrong.
#>
param([switch]$Apply, [double]$MinRatio = 2.0)
$ErrorActionPreference = 'Stop'
$path = 'C:\Codex\ThriftyCrew\grocery\price-history.json'
$doc = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json

$report = @()
$purged = 0
foreach ($c in @($doc.commodities)) {
  $hist = @($c.history | Where-Object { $null -ne $_.cheapest_price })
  if ($hist.Count -lt 3) { continue }
  $sorted = @($hist | Sort-Object { [double]$_.cheapest_price })
  $lowest = $sorted[0]
  $nextLow = [double]$sorted[1].cheapest_price
  $lo = [double]$lowest.cheapest_price
  if ($lo -le 0) { $ratio = [double]::PositiveInfinity } else { $ratio = $nextLow / $lo }
  if ($ratio -lt $MinRatio) { continue }

  # board-wide? compare every store present in the bad week against that store's median elsewhere
  $shape = 'single-store'
  $ps = $lowest.per_store
  if ($ps) {
    $stores = @($ps.PSObject.Properties.Name)
    $factors = @()
    foreach ($s in $stores) {
      $badP = [double]$ps.$s
      if ($badP -le 0) { continue }
      $others = @()
      foreach ($h in $hist) {
        if ($h.week_of -eq $lowest.week_of) { continue }
        if ($h.per_store -and $h.per_store.PSObject.Properties[$s]) { $others += [double]$h.per_store.$s }
      }
      if ($others.Count -ge 2) { $factors += ((@($others | Sort-Object))[[int]($others.Count/2)] / $badP) }
    }
    if ($factors.Count -ge 3) {
      $mn = ($factors | Measure-Object -Minimum).Minimum
      if ($mn -ge ($MinRatio - 0.2)) { $shape = 'board-wide' }
    }
  }

  $report += [pscustomobject]@{
    id = $c.id; week = [string]$lowest.week_of; bad = $lo; next = $nextLow
    ratio = [math]::Round($ratio, 1); store = [string]$lowest.cheapest_store; shape = $shape
  }
  $keep = @($c.history | Where-Object { $_.week_of -ne $lowest.week_of })
  if ($Apply) {
    $c.history = $keep
    $rem = @($keep | Where-Object { $null -ne $_.cheapest_price } | Sort-Object { [double]$_.cheapest_price })
    if ($rem.Count) {
      $c.record_low.price    = [double]$rem[0].cheapest_price
      $c.record_low.store    = [string]$rem[0].cheapest_store
      $c.record_low.week_of  = [string]$rem[0].week_of
    }
  }
  $purged++
}

$report | Sort-Object -Property @{e='ratio';Descending=$true} |
  Format-Table -AutoSize @{n='commodity';e='id'}, @{n='bad week';e='week'}, @{n='impossible';e='bad'},
                          @{n='next lowest';e='next'}, @{n='x';e='ratio'}, @{n='store';e='store'}, @{n='shape';e='shape'} |
  Out-String -Width 160 | Write-Output

Write-Output ("{0} commodit(ies) carry an impossible record low at >= {1}x" -f $purged, $MinRatio)
if (-not $Apply) { Write-Output 'DRY RUN - pass -Apply to write.'; exit 0 }

$doc.updated = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
($doc | ConvertTo-Json -Depth 12) | Set-Content $path -Encoding UTF8
$null = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
Write-Output 'price-history.json written and re-parsed clean.'
