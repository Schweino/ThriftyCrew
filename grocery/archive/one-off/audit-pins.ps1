<#
  audit-pins.ps1 - a pinned override BEATS the engine. Any pin that disagrees with the engine is
  publishing a number the engine did not compute, so every disagreement must be explained.
#>
$root = 'C:\Codex\ThriftyCrew\grocery'
$o = Get-Content (Join-Path $root 'board-price-overrides.json') -Raw | ConvertFrom-Json
$cmp = Get-Content (Get-ChildItem (Join-Path $root 'out\comparison-*.json') | Sort-Object Name -Desc | Select-Object -First 1).FullName -Raw | ConvertFrom-Json
$bad = 0
foreach ($c in $o.cells) {
  $row = $cmp.comparison | Where-Object { $_.id -eq $c.id }
  $cell = $row.stores | Where-Object { $_.store -eq $c.store }
  if (-not $cell) { continue }
  $pin = [double]$c.per_unit; $eng = [double]$cell.per_unit
  if ([math]::Abs($eng - $pin) / [math]::Max($eng, 0.0001) -gt 0.02) {
    $bad++
    Write-Output ("  PIN OVERRIDES ENGINE  {0,-22} {1,-12} pin={2,-9} engine={3,-9}" -f $c.id, $c.store, $pin.ToString('0.####'), $eng.ToString('0.####'))
    Write-Output ("        board item: " + $cell.item)
  }
}
Write-Output ''
Write-Output ("total pins: " + @($o.cells).Count + "   pins overriding the engine: $bad")
