param([switch]$StartNow, [switch]$Uninstall)
$ErrorActionPreference = 'Stop'
$runner = (Resolve-Path (Join-Path $PSScriptRoot 'run-ingredient-campaign-supervisor.ps1')).Path
$entryName = 'ThriftyCrew V3 Ingredient Pipeline'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
if ($Uninstall) {
  Remove-ItemProperty -Path $runKey -Name $entryName -ErrorAction SilentlyContinue
  [pscustomobject]@{ ok = $true; startupEntry = $entryName; removed = $true } | ConvertTo-Json -Compress
  exit 0
}
$command = "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$runner`""
New-Item -Path $runKey -Force | Out-Null
New-ItemProperty -Path $runKey -Name $entryName -Value $command -PropertyType String -Force | Out-Null
if ($StartNow) {
  Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', $runner) -WindowStyle Hidden
}
[pscustomobject]@{ ok = $true; startupEntry = $entryName; runner = $runner; started = [bool]$StartNow } | ConvertTo-Json -Compress
