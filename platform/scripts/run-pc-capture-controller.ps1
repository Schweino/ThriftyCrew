$ErrorActionPreference = 'Stop'
$mutex = [Threading.Mutex]::new($false, 'Local\ThriftyCrew-GroceryV3-CaptureController')
$hasMutex = $false
try { $hasMutex = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $hasMutex = $true }
if (-not $hasMutex) { $mutex.Dispose(); exit 0 }

try {
$clientDir = Join-Path $env:LOCALAPPDATA 'ThriftyCrew\grocery-v3'
$configFile = Join-Path $clientDir 'pc-capture-client.json'
if (-not (Test-Path -LiteralPath $configFile)) { throw "PC capture client is not installed: $configFile is missing" }
$config = Get-Content -LiteralPath $configFile -Raw | ConvertFrom-Json
$secure = ConvertTo-SecureString ([string]$config.encryptedSecret)
$pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try { $tcSecret = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
$journalSecure = ConvertTo-SecureString ([string]$config.encryptedJournalKey)
$journalPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($journalSecure)
try { $tcJournalKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($journalPointer) }
finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($journalPointer) }

$env:TC_LOCAL_MUTATION_SECRET = $tcSecret
$env:TC_AGENT_ID = [string]$config.agentId
$env:TC_API_ORIGIN = [string]$config.apiOrigin
$env:TC_CAPTURE_QUEUE = [string]$config.queueRoot
$env:TC_CAPTURE_JOURNAL = Join-Path $clientDir 'capture-journal.sqlite'
$env:TC_CAPTURE_JOURNAL_KEY = $tcJournalKey
$env:TC_PNPM_PATH = [string]$config.pnpmPath
$env:TC_CAPTURE_CONTROLLER_TOKEN = [string]$config.controllerToken
if ($env:TC_CAPTURE_CONTROLLER_TOKEN.Length -lt 32) { throw 'PC capture controller token is missing or invalid' }
$env:NODE_OPTIONS = (($env:NODE_OPTIONS, '--disable-warning=ExperimentalWarning') -join ' ').Trim()
$runtimePath = @($config.runtimePath | ForEach-Object { [string]$_ })
if ($runtimePath.Count -gt 0) { $env:Path = (($runtimePath -join [IO.Path]::PathSeparator) + [IO.Path]::PathSeparator + $env:Path) }
$restartDelaySeconds = 2
while ($true) {
  Push-Location ([string]$config.platformRoot)
  try { & ([string]$config.pnpmPath) 'exec' 'tsx' 'apps/operator/src/capture-controller.ts' }
  finally { Pop-Location }
  $exitCode = $LASTEXITCODE
  $supervisorLog = Join-Path $clientDir 'logs\capture-controller-supervisor.log'
  New-Item -ItemType Directory -Path (Split-Path -Parent $supervisorLog) -Force | Out-Null
  if ((Test-Path -LiteralPath $supervisorLog) -and (Get-Item -LiteralPath $supervisorLog).Length -gt 1MB) {
    Move-Item -LiteralPath $supervisorLog -Destination ($supervisorLog + '.previous') -Force
  }
  Add-Content -LiteralPath $supervisorLog -Value (([ordered]@{
    at = (Get-Date).ToUniversalTime().ToString('o')
    event = 'controller-exit'
    exitCode = $exitCode
    restartDelaySeconds = $restartDelaySeconds
  } | ConvertTo-Json -Compress))
  Start-Sleep -Seconds $restartDelaySeconds
  $restartDelaySeconds = [Math]::Min(60, $restartDelaySeconds * 2)
}
} finally {
  if ($hasMutex) { $mutex.ReleaseMutex() }
  $mutex.Dispose()
}
