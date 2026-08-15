$ErrorActionPreference='Stop'
$root='C:\Codex\ThriftyCrew\grocery'
$f = Join-Path $root 'board-price-overrides.json'
$doc = Get-Content $f -Raw | ConvertFrom-Json
$before = @($doc.overrides).Count
$doc.overrides = @($doc.overrides | Where-Object { -not (
  ($_.id -eq 'ground-coriander' -and $_.store -eq 'Hy-Vee') -or
  ($_.id -eq 'ground-nutmeg' -and $_.store -eq 'Hy-Vee') -or
  ($_.id -eq 'dried-thyme' -and $_.store -eq 'Family Fare')
) })
($doc | ConvertTo-Json -Depth 6) | Set-Content $f -Encoding UTF8
$null = Get-Content $f -Raw | ConvertFrom-Json
Write-Output ("pins: $before -> " + @($doc.overrides).Count + " (3 unsourced r100 pins removed)")
