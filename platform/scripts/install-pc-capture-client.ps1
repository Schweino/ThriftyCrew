param(
  [string]$ApiOrigin = 'https://tc-grocery-v3.curly-unit-51a6.workers.dev',
  [string]$AgentId = 'pc-browser-capture',
  [string]$TaskName = 'ThriftyCrew V3 Browser Capture Client',
  [switch]$Uninstall
)
$ErrorActionPreference = 'Stop'
$platformRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$clientDir = Join-Path $env:LOCALAPPDATA 'ThriftyCrew\grocery-v3'
$configFile = Join-Path $clientDir 'pc-capture-client.json'
$queueRoot = Join-Path $clientDir 'capture-queue'

if ($Uninstall) {
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
  Write-Output "Scheduled task removed. Queue and encrypted credential remain at $clientDir for rollback."
  exit 0
}

$devVars = Join-Path $platformRoot '.dev.vars'
if (-not (Test-Path -LiteralPath $devVars)) { throw "missing $devVars; an operator credential is required to preserve the existing remote key set" }
$mutationLine = Get-Content -LiteralPath $devVars | Where-Object { $_ -match '^MUTATION_KEYS=' } | Select-Object -First 1
if (-not $mutationLine) { throw 'MUTATION_KEYS is missing from platform/.dev.vars' }
$keyRecords = ($mutationLine.Substring($mutationLine.IndexOf('=') + 1) | ConvertFrom-Json)

$rng = [Security.Cryptography.RandomNumberGenerator]::Create()
$bytes = New-Object byte[] 32
$rng.GetBytes($bytes)
$rng.Dispose()
$secret = [Convert]::ToBase64String($bytes)
$browserSources = @(
  'direct-aldi-browser',
  'direct-fareway-browser',
  'direct-sams-browser',
  'direct-walmart-browser'
)
$record = [pscustomobject]@{ secret = $secret; role = 'capture'; sourceIds = $browserSources }
$keyRecords | Add-Member -NotePropertyName $AgentId -NotePropertyValue $record -Force
$remoteSecret = $keyRecords | ConvertTo-Json -Depth 8 -Compress

$pnpmCommand = Get-Command pnpm -ErrorAction Stop
$pnpmPath = $pnpmCommand.Source
Push-Location $platformRoot
try {
  $remoteSecret | & $pnpmPath exec wrangler secret put MUTATION_KEYS
  if ($LASTEXITCODE -ne 0) { throw 'Cloudflare rejected the scoped PC credential update' }
} finally { Pop-Location }

New-Item -ItemType Directory -Path $clientDir -Force | Out-Null
New-Item -ItemType Directory -Path $queueRoot -Force | Out-Null
$encryptedSecret = ConvertFrom-SecureString (ConvertTo-SecureString $secret -AsPlainText -Force)
$configuration = [ordered]@{
  version = 1
  agentId = $AgentId
  apiOrigin = $ApiOrigin
  queueRoot = $queueRoot
  platformRoot = $platformRoot
  pnpmPath = $pnpmPath
  encryptedSecret = $encryptedSecret
  installedAt = (Get-Date).ToUniversalTime().ToString('o')
  sourceIds = $browserSources
}
$configuration | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configFile -Encoding UTF8

$runner = Join-Path $platformRoot 'scripts\run-pc-capture-client.ps1'
$actionArguments = "-NoProfile -ExecutionPolicy Bypass -File `"$runner`" -Mode Cycle"
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $actionArguments
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 20) -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId ("{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME) -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description 'Drains and watches the authenticated V3 real-Chrome capture queue.' -Force | Out-Null
Write-Output "Installed $TaskName. The credential is DPAPI-protected for the current Windows user and scoped to browser capture sources."
