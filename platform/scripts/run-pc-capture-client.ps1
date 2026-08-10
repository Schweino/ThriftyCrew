param([ValidateSet('Drain','Watchdog','Cycle')][string]$Mode = 'Cycle')
$ErrorActionPreference = 'Stop'

$clientDir = Join-Path $env:LOCALAPPDATA 'ThriftyCrew\grocery-v3'
$configFile = Join-Path $clientDir 'pc-capture-client.json'
if (-not (Test-Path -LiteralPath $configFile)) { throw "PC capture client is not installed: $configFile is missing" }
$config = Get-Content -LiteralPath $configFile -Raw | ConvertFrom-Json
$secure = ConvertTo-SecureString ([string]$config.encryptedSecret)
$pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try { $tcSecret = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }

$env:TC_LOCAL_MUTATION_SECRET = $tcSecret
$env:TC_AGENT_ID = [string]$config.agentId
$env:TC_API_ORIGIN = [string]$config.apiOrigin
$env:TC_CAPTURE_QUEUE = [string]$config.queueRoot
$logFile = Join-Path $clientDir 'pc-capture-client.log'
$platformRoot = [string]$config.platformRoot
$pnpmPath = [string]$config.pnpmPath

function Invoke-CaptureCommand([string[]]$Arguments) {
  Push-Location $platformRoot
  try {
    $output = & $pnpmPath @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $output | ForEach-Object { Add-Content -LiteralPath $logFile -Value ("[{0}] {1}" -f (Get-Date).ToString('s'), $_) }
    return $exitCode
  } finally { Pop-Location }
}

$finalExit = 0
if ($Mode -eq 'Drain' -or $Mode -eq 'Cycle') {
  $drainExit = Invoke-CaptureCommand @('tc','capture','queue','drain')
  if ($drainExit -ne 0) { $finalExit = $drainExit }
}
if ($Mode -eq 'Watchdog' -or $Mode -eq 'Cycle') {
  $watchdogExit = Invoke-CaptureCommand @('tc','capture','queue','watchdog')
  if ($watchdogExit -ne 0) { $finalExit = $watchdogExit }
}
Remove-Variable tcSecret -ErrorAction SilentlyContinue
exit $finalExit
