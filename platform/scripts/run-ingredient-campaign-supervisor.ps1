param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'pc-runtime-lib.ps1')
$config = Read-PcRuntimeConfig
Initialize-PcRuntimeEnvironment $config
$platformRoot = [string]$config.platformRoot
$nodePath = [string]$config.nodePath
$runner = Join-Path $platformRoot 'scripts\run-pipeline-agent-supervisor.mjs'
$logFile = Join-Path ([string]$config.logRoot) 'ingredient-campaign-supervisor.log'

if (-not (Test-Path -LiteralPath $runner)) { throw "V4 Node supervisor is missing: $runner" }
Write-PcRuntimeLog $logFile 'launching event-driven V4 Node supervisor; PowerShell is a compatibility/startup wrapper only'
Push-Location $platformRoot
try {
  & $nodePath $runner 2>&1 | ForEach-Object { Write-PcRuntimeLog $logFile ([string]$_) }
  if ($LASTEXITCODE -ne 0) { throw "V4 Node supervisor exited with code $LASTEXITCODE" }
} finally { Pop-Location }
