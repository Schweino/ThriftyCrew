param(
  [string]$ApiOrigin = 'https://tc-grocery-public.curly-unit-51a6.workers.dev',
  [string]$AgentId = 'pc-browser-capture',
  [string]$TaskName = 'ThriftyCrew V3 Browser Capture Client',
  [string]$NodeRuntimeDirectory = (Join-Path $env:LOCALAPPDATA 'ThriftyCrew\runtime\node-v24.18.1-win-x64'),
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

function New-RandomKey {
  $random = [Security.Cryptography.RandomNumberGenerator]::Create()
  try { $buffer = New-Object byte[] 32; $random.GetBytes($buffer); return [Convert]::ToBase64String($buffer) }
  finally { $random.Dispose() }
}
function Unprotect-Secret([string]$Ciphertext) {
  $secureValue = ConvertTo-SecureString $Ciphertext
  $secretPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureValue)
  try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($secretPointer) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($secretPointer) }
}
$existingConfiguration = if (Test-Path -LiteralPath $configFile) { Get-Content -LiteralPath $configFile -Raw | ConvertFrom-Json } else { $null }
$sameIdentity = $existingConfiguration -and [string]$existingConfiguration.agentId -eq $AgentId
$secret = if ($sameIdentity -and $existingConfiguration.encryptedSecret) { Unprotect-Secret ([string]$existingConfiguration.encryptedSecret) } else { New-RandomKey }
$controllerToken = if ($sameIdentity -and [string]$existingConfiguration.controllerToken) { [string]$existingConfiguration.controllerToken } else { New-RandomKey }
$journalKey = if ($sameIdentity -and $existingConfiguration.encryptedJournalKey) { Unprotect-Secret ([string]$existingConfiguration.encryptedJournalKey) } else { New-RandomKey }
$browserSources = @(
  'direct-aldi-browser',
  'direct-fareway-browser',
  'direct-sams-browser',
  'direct-walmart-browser'
)
$record = [pscustomobject]@{ secret = $secret; role = 'capture'; sourceIds = $browserSources }
$keyRecords | Add-Member -NotePropertyName $AgentId -NotePropertyValue $record -Force
$remoteSecret = $keyRecords | ConvertTo-Json -Depth 8 -Compress

$nodeExecutable = Join-Path $NodeRuntimeDirectory 'node.exe'
if (-not (Test-Path -LiteralPath $nodeExecutable)) { throw "pinned Node runtime is missing: $nodeExecutable; run scripts/install-node-runtime.ps1" }
$nodeVersion = (& $nodeExecutable --version).Trim()
if ($nodeVersion -ne 'v24.18.1') { throw "capture runtime must be Node v24.18.1, found $nodeVersion" }
$pnpmPath = Join-Path $NodeRuntimeDirectory 'pnpm.cmd'
if (-not (Test-Path -LiteralPath $pnpmPath)) { throw "pinned pnpm runtime is missing: $pnpmPath; run scripts/install-node-runtime.ps1" }
$runtimePath = @($NodeRuntimeDirectory)
$env:Path = ($NodeRuntimeDirectory + [IO.Path]::PathSeparator + $env:Path)
Push-Location $platformRoot
try {
  $remoteSecret | & $pnpmPath exec wrangler secret put MUTATION_KEYS
  if ($LASTEXITCODE -ne 0) { throw 'Cloudflare rejected the scoped PC credential update' }
} finally { Pop-Location }

New-Item -ItemType Directory -Path $clientDir -Force | Out-Null
New-Item -ItemType Directory -Path $queueRoot -Force | Out-Null
$encryptedSecret = ConvertFrom-SecureString (ConvertTo-SecureString $secret -AsPlainText -Force)
$encryptedJournalKey = ConvertFrom-SecureString (ConvertTo-SecureString $journalKey -AsPlainText -Force)
$configuration = [ordered]@{
  version = 3
  agentId = $AgentId
  apiOrigin = $ApiOrigin
  queueRoot = $queueRoot
  platformRoot = $platformRoot
  pnpmPath = $pnpmPath
  nodePath = $nodeExecutable
  runtimePath = $runtimePath
  encryptedSecret = $encryptedSecret
  encryptedJournalKey = $encryptedJournalKey
  controllerToken = $controllerToken
  nodeVersion = $nodeVersion
  installedAt = (Get-Date).ToUniversalTime().ToString('o')
  sourceIds = $browserSources
}
$configuration | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configFile -Encoding UTF8
$currentUserName = [Security.Principal.WindowsIdentity]::GetCurrent().Name
& icacls.exe $configFile '/inheritance:r' '/grant:r' "${currentUserName}:(F)" '*S-1-5-18:(F)' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'capture client configuration ACL could not be restricted' }

$launcher = Join-Path $platformRoot 'scripts\run-pc-capture-client-hidden.vbs'
$actionArguments = "//B //NoLogo `"$launcher`" -Mode Cycle"
$action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument $actionArguments
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 20) -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId ("{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME) -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description 'Drains and watches the authenticated V3 real-Chrome capture queue.' -Force | Out-Null
Write-Output "Installed $TaskName. The credential is DPAPI-protected for the current Windows user and scoped to browser capture sources."
