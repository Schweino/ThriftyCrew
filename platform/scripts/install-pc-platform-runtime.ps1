param(
  [string]$ApiOrigin = 'https://tc-grocery-public.curly-unit-51a6.workers.dev',
  [string]$NodeRuntimeDirectory = (Join-Path $env:LOCALAPPDATA 'ThriftyCrew\runtime\node-v24.18.1-win-x64'),
  [switch]$SkipRemoteSecret,
  [switch]$Uninstall
)
$ErrorActionPreference = 'Stop'
$platformRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$incomeRoot = Split-Path -Parent $platformRoot
$runtimeRoot = Join-Path $env:LOCALAPPDATA 'ThriftyCrew\grocery-v3'
$configFile = Join-Path $runtimeRoot 'pc-platform-runtime.json'
$logRoot = Join-Path $runtimeRoot 'logs'
$taskNames = @(
  'ThriftyCrew V3 Daily Engine',
  'ThriftyCrew V3 Promotion Boundary',
  'ThriftyCrew V3 Efficiency Budget',
  'ThriftyCrew V3 Family Fare Paced',
  'ThriftyCrew V3 Accuracy Weekly',
  'ThriftyCrew V3 Accuracy Agent',
  'ThriftyCrew V3 Accuracy Revalidation Daily',
  'ThriftyCrew V3 Accuracy Revalidation Agent',
  'ThriftyCrew V3 Triage Daily',
  'ThriftyCrew V3 Ghost Reconcile',
  'ThriftyCrew V3 Source Sentinel',
  'ThriftyCrew V3 Post Publish Review',
  'ThriftyCrew V3 Triage Agents',
  'ThriftyCrew V3 Recipe Pack',
  'ThriftyCrew V3 Restore Drill'
)

if ($Uninstall) {
  foreach ($name in $taskNames) { Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue }
  & (Join-Path $PSScriptRoot 'install-pc-capture-controller.ps1') -Uninstall | Out-Null
  Write-Output "Removed $($taskNames.Count) PC platform tasks. DPAPI credentials and logs remain at $runtimeRoot for rollback."
  exit 0
}

$devVars = Join-Path $platformRoot '.dev.vars'
if (-not (Test-Path -LiteralPath $devVars)) { throw "missing $devVars; local-operator credential cannot be preserved" }
$mutationLine = Get-Content -LiteralPath $devVars | Where-Object { $_ -match '^MUTATION_KEYS=' } | Select-Object -First 1
if (-not $mutationLine) { throw 'MUTATION_KEYS is missing from platform/.dev.vars' }
$knownKeys = $mutationLine.Substring($mutationLine.IndexOf('=') + 1) | ConvertFrom-Json
$operatorRecord = $knownKeys.PSObject.Properties['local-operator']
if (-not $operatorRecord -or $operatorRecord.Value.role -ne 'operator') { throw 'local-operator is missing or is not an operator credential' }

$nodeExecutable = Join-Path $NodeRuntimeDirectory 'node.exe'
$pnpmPath = Join-Path $NodeRuntimeDirectory 'pnpm.cmd'
if (-not (Test-Path -LiteralPath $nodeExecutable) -or (& $nodeExecutable --version).Trim() -ne 'v24.18.1') { throw 'pinned Node v24.18.1 is missing; run scripts/install-node-runtime.ps1' }
if (-not (Test-Path -LiteralPath $pnpmPath)) { throw 'pinned pnpm 11.16.0 is missing; run scripts/install-node-runtime.ps1' }
$runtimePath = @($NodeRuntimeDirectory)
$env:Path = ($NodeRuntimeDirectory + [IO.Path]::PathSeparator + $env:Path)
$agents = (Get-Content -LiteralPath (Join-Path $platformRoot 'config\agents.json') -Raw | ConvertFrom-Json).agents | Where-Object { $_.enabled -and $_.plane -eq 'pc' }
if (@($agents).Count -eq 0) { throw 'no enabled PC agents exist in config/agents.json' }

$existing = if (Test-Path -LiteralPath $configFile) { Get-Content -LiteralPath $configFile -Raw | ConvertFrom-Json } else { $null }
function New-RandomSecret {
  $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
  try { $bytes = New-Object byte[] 32; $rng.GetBytes($bytes); return [Convert]::ToBase64String($bytes) }
  finally { $rng.Dispose() }
}
function Protect-Secret([string]$Plaintext) {
  return ConvertFrom-SecureString (ConvertTo-SecureString $Plaintext -AsPlainText -Force)
}
function Unprotect-Secret([string]$Ciphertext) {
  $secure = ConvertTo-SecureString $Ciphertext
  $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
  try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
}

$credentials = [ordered]@{}
$credentials['local-operator'] = [ordered]@{ role = 'operator'; encryptedSecret = Protect-Secret ([string]$operatorRecord.Value.secret) }
$remoteKeys = [ordered]@{
  'local-operator' = [ordered]@{ secret = [string]$operatorRecord.Value.secret; role = 'operator' }
}

$captureConfigFile = Join-Path $runtimeRoot 'pc-capture-client.json'
if (Test-Path -LiteralPath $captureConfigFile) {
  $capture = Get-Content -LiteralPath $captureConfigFile -Raw | ConvertFrom-Json
  $captureSecret = Unprotect-Secret ([string]$capture.encryptedSecret)
  $remoteKeys[[string]$capture.agentId] = [ordered]@{ secret = $captureSecret; role = 'capture'; sourceIds = @($capture.sourceIds) }
}

foreach ($agent in $agents) {
  $existingProperty = if ($existing -and $existing.credentials) { $existing.credentials.PSObject.Properties[[string]$agent.id] } else { $null }
  $secret = if ($existingProperty) { Unprotect-Secret ([string]$existingProperty.Value.encryptedSecret) } else { New-RandomSecret }
  $credentials[[string]$agent.id] = [ordered]@{ role = 'engine'; registeredAgent = $true; encryptedSecret = Protect-Secret $secret }
  $remoteKeys[[string]$agent.id] = [ordered]@{ secret = $secret; role = 'engine'; registeredAgent = $true }
}

New-Item -ItemType Directory -Path $runtimeRoot -Force | Out-Null
New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
$configuration = [ordered]@{
  version = 1
  apiOrigin = $ApiOrigin
  platformRoot = $platformRoot
  incomeRoot = $incomeRoot
  pnpmPath = $pnpmPath
  runtimePath = $runtimePath
  logRoot = $logRoot
  credentials = $credentials
  installedAt = (Get-Date).ToUniversalTime().ToString('o')
}
$configuration | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configFile -Encoding UTF8

if (-not $SkipRemoteSecret) {
  $secretJson = $remoteKeys | ConvertTo-Json -Depth 8 -Compress
  Push-Location $platformRoot
  try {
    $secretJson | & $pnpmPath exec wrangler secret put MUTATION_KEYS
    if ($LASTEXITCODE -ne 0) { throw 'Cloudflare rejected the merged local runtime credential set' }
  } finally { Pop-Location }
}

$platformLauncher = Join-Path $PSScriptRoot 'run-pc-platform-job.ps1'
$agentLauncher = Join-Path $PSScriptRoot 'run-pc-agent-cycle.ps1'
$principal = New-ScheduledTaskPrincipal -UserId ("{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME) -LogonType Interactive -RunLevel Limited
function Register-PcTask([string]$Name, [string]$Script, [string]$Arguments, $Trigger, [int]$LimitMinutes, [string]$Description) {
  $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ("-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"{0}`" {1}" -f $Script, $Arguments)
  $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -WakeToRun -ExecutionTimeLimit (New-TimeSpan -Minutes $LimitMinutes) -MultipleInstances IgnoreNew
  Register-ScheduledTask -TaskName $Name -Action $action -Trigger $Trigger -Settings $settings -Principal $principal -Description $Description -Force | Out-Null
}

$today = (Get-Date).Date
$familyFareStart = $today.AddMinutes(17)
while ($familyFareStart -le (Get-Date)) { $familyFareStart = $familyFareStart.AddHours(3) }
$promotionStart = (Get-Date).AddMinutes(30)
Register-PcTask 'ThriftyCrew V3 Daily Engine' $platformLauncher '-Job daily-engine' (New-ScheduledTaskTrigger -Daily -At '12:07 PM') 180 'Authoritative local V3 direct capture and immutable release pipeline.'
Register-PcTask 'ThriftyCrew V3 Promotion Boundary' $platformLauncher '-Job promotion-boundary' (New-ScheduledTaskTrigger -Once -At $promotionStart -RepetitionInterval (New-TimeSpan -Minutes 15)) 90 'Promotion-aware prefetch, start, end, and post-start verification with an immediate immutable release rebuild.'
Register-PcTask 'ThriftyCrew V3 Efficiency Budget' $platformLauncher '-Job efficiency-daily' (New-ScheduledTaskTrigger -Daily -At '5:47 PM') 30 'Measures D1 query and write amplification and reconciles one durable incident.'
Register-PcTask 'ThriftyCrew V3 Family Fare Paced' $platformLauncher '-Job family-fare-paced' (New-ScheduledTaskTrigger -Once -At $familyFareStart -RepetitionInterval (New-TimeSpan -Hours 3)) 60 'Authoritative local three-hour Family Fare capture pacing.'
Register-PcTask 'ThriftyCrew V3 Accuracy Weekly' $platformLauncher '-Job accuracy-weekly' (New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday -At '3:17 PM') 30 'Weekly deterministic blind accuracy draw.'
Register-PcTask 'ThriftyCrew V3 Accuracy Agent' $agentLauncher '-Cycle Accuracy -MaxItems 1' (New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday -At '3:30 PM') 90 'Weekly local registered accuracy verdict agent.'
Register-PcTask 'ThriftyCrew V3 Accuracy Revalidation Daily' $platformLauncher '-Job accuracy-revalidation-daily' (New-ScheduledTaskTrigger -Daily -At '10:17 AM') 30 'Daily deterministic winner/challenger revalidation draw.'
Register-PcTask 'ThriftyCrew V3 Accuracy Revalidation Agent' $agentLauncher '-Cycle Accuracy -MaxItems 1' (New-ScheduledTaskTrigger -Daily -At '10:30 AM') 90 'Daily local registered winner/challenger revalidation agent.'
Register-PcTask 'ThriftyCrew V3 Triage Daily' $platformLauncher '-Job triage-daily' (New-ScheduledTaskTrigger -Daily -At '1:37 PM') 45 'Daily deterministic triage queue seeding.'
Register-PcTask 'ThriftyCrew V3 Triage Agents' $agentLauncher '-Cycle Triage -MaxItems 6' (New-ScheduledTaskTrigger -Daily -At '1:57 PM') 240 'Bounded local reviewer-to-developer triage drain.'
Register-PcTask 'ThriftyCrew V3 Post Publish Review' $agentLauncher '-Cycle PostPublish -MaxItems 1' (New-ScheduledTaskTrigger -Daily -At '12:47 PM') 90 'Daily local post-publish review.'
Register-PcTask 'ThriftyCrew V3 Source Sentinel' $agentLauncher '-Cycle SourceSentinel -MaxItems 1' (New-ScheduledTaskTrigger -Daily -At '2:47 PM') 120 'Daily local source-contract sentinel.'
Register-PcTask 'ThriftyCrew V3 Ghost Reconcile' $platformLauncher '-Job ghost-rotation-reconcile' (New-ScheduledTaskTrigger -Daily -At '4:07 PM') 30 'Daily Ghost intent-versus-truth reconciliation.'
Register-PcTask 'ThriftyCrew V3 Recipe Pack' $agentLauncher '-Cycle Recipe -MaxItems 50' (New-ScheduledTaskTrigger -Weekly -DaysOfWeek Tuesday -At '10:27 AM') 720 'Weekly resumable recipe and 50-gap Omaha ingredient coverage chain using ChatGPT-included Codex limits only.'
Register-PcTask 'ThriftyCrew V3 Restore Drill' $platformLauncher '-Job restore-drill-quarterly' (New-ScheduledTaskTrigger -Daily -At '5:23 AM') 30 'Daily guarded trigger; executes only on the first day of each quarter.'

& (Join-Path $PSScriptRoot 'install-pc-capture-controller.ps1') | Out-Null

Write-Output "Installed $($taskNames.Count) authoritative local V3 tasks. Credentials are DPAPI-protected for $env:USERNAME."
