param(
  [Parameter(Mandatory=$true)]
  [ValidateSet('daily-engine','promotion-boundary','efficiency-daily','family-fare-paced','accuracy-weekly','accuracy-revalidation-daily','triage-daily','ghost-rotation-reconcile','restore-drill-quarterly')]
  [string]$Job,
  [switch]$Force,
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'pc-runtime-lib.ps1')
$config = Read-PcRuntimeConfig
Initialize-PcRuntimeEnvironment $config
$logFile = Join-Path ([string]$config.logRoot) ("platform-{0}.log" -f $Job)
$platformRoot = [string]$config.platformRoot
$incomeRoot = Split-Path -Parent $platformRoot
$pnpmPath = [string]$config.pnpmPath

if ($SelfTest) {
  if (-not (Test-Path -LiteralPath $pnpmPath)) { throw "pnpm runtime is missing: $pnpmPath" }
  if (-not (Test-Path -LiteralPath (Join-Path $incomeRoot 'grocery\pull-regular-familyfare.ps1'))) { throw 'Family Fare source adapter is missing' }
  Set-PcRuntimeCredential $config 'local-operator'
  Write-Output "PC platform job self-test passed for $Job"
  exit 0
}

if ($Job -eq 'restore-drill-quarterly' -and -not $Force) {
  $now = Get-Date
  if ($now.Day -ne 1 -or @(1,4,7,10) -notcontains $now.Month) {
    Write-PcRuntimeLog $logFile 'quarterly guard: not a scheduled restore-drill date; standing down'
    exit 0
  }
}

$lock = Enter-PcRuntimeLock ("platform-job-{0}" -f $Job) 180
if (-not $lock) { Write-PcRuntimeLog $logFile 'another instance holds the job lock; standing down'; exit 0 }

function Invoke-Logged([string]$Label, [scriptblock]$Command, [int[]]$AllowedExitCodes = @(0)) {
  Write-PcRuntimeLog $logFile ("START {0}" -f $Label)
  $prior = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { $output = & $Command 2>&1; $exitCode = $LASTEXITCODE }
  finally { $ErrorActionPreference = $prior }
  foreach ($line in @($output)) { Write-PcRuntimeLog $logFile ("{0}: {1}" -f $Label, $line) }
  if ($null -eq $exitCode) { $exitCode = 0 }
  if ($AllowedExitCodes -notcontains $exitCode) { throw "$Label failed with exit code $exitCode" }
  Write-PcRuntimeLog $logFile ("DONE {0}" -f $Label)
  return $exitCode
}

function Invoke-TcJson([string]$Label, [string[]]$Arguments) {
  Write-PcRuntimeLog $logFile ("START {0}" -f $Label)
  $prior = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { $lines = @(& $pnpmPath --silent tc @Arguments 2>&1); $exitCode = $LASTEXITCODE }
  finally { $ErrorActionPreference = $prior }
  foreach ($line in $lines) { Write-PcRuntimeLog $logFile ("{0}: {1}" -f $Label, $line) }
  if ($exitCode -ne 0) { throw "$Label failed with exit code $exitCode" }
  $text = $lines -join [Environment]::NewLine
  $start = $text.IndexOf('{')
  if ($start -lt 0) { throw "$Label did not return JSON" }
  Write-PcRuntimeLog $logFile ("DONE {0}" -f $Label)
  return ($text.Substring($start) | ConvertFrom-Json)
}

Set-PcRuntimeCredential $config 'local-operator'
$env:TC_JOB_RUN_ID = "run_{0}_pc-{1}" -f $Job, ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
$env:TC_SCHEDULED_FOR = (Get-Date).ToUniversalTime().ToString('o')
$env:TC_RECOVERY_REASON = 'authoritative Windows Task Scheduler execution'
$env:TC_JOB_LEASE_FILE = Join-Path ([string]$config.logRoot) ("lease-{0}.json" -f ($env:TC_JOB_RUN_ID -replace '[^a-zA-Z0-9_-]', '-'))
$jobStarted = $false
$failed = $false
try {
  Push-Location $platformRoot
  try {
    $startExit = Invoke-Logged 'job-ledger-start' { & $pnpmPath tc job start $Job } @(0,75)
    if ($startExit -eq 75) { Write-PcRuntimeLog $logFile 'control-plane lease is held; standing down'; exit 0 }
    $jobStarted = $true
    switch ($Job) {
      'daily-engine' {
        Invoke-Logged 'config-deploy' { & $pnpmPath tc config deploy }
        Invoke-Logged 'bakers-capture' { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $incomeRoot 'grocery\pull-regular-bakers-api.ps1') }
        Invoke-Logged 'family-fare-capture' { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $incomeRoot 'grocery\pull-regular-familyfare.ps1') }
        Invoke-Logged 'hy-vee-capture' { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $incomeRoot 'grocery\pull-regular-hyvee.ps1') }
        Invoke-Logged 'capture-ingest' { & $pnpmPath tc capture ingest-current bakers family-fare hy-vee }
        Invoke-Logged 'browser-promotion' { & $pnpmPath tc capture promote-ready-browser }
        Invoke-Logged 'native-publish' { & $pnpmPath tc engine publish-native }
        Invoke-Logged 'ghost-reconcile' { & $pnpmPath tc ghost reconcile }
        Invoke-Logged 'direct-parity' { & $pnpmPath tc engine parity direct }
        Invoke-Logged 'evidence-accrue' { & $pnpmPath tc evidence accrue }
      }
      'promotion-boundary' {
        Invoke-Logged 'promotion-calendar-sync' { & $pnpmPath tc promotion sync }
        Invoke-Logged 'promotion-lifecycle-reconcile' { & $pnpmPath tc promotion reconcile }
        $claim = Invoke-TcJson 'promotion-headless-claim' @('promotion','claim','headless',("pc-{0}" -f $env:COMPUTERNAME))
        $requests = @($claim.requests)
        $browserDue = Invoke-TcJson 'promotion-browser-due' @('promotion','due','browser')
        $publishForBoundary = @($browserDue.requests | Where-Object { $_.request_kind -in @('activate','expire') }).Count -gt 0
        if ($requests.Count -gt 0) {
          $stores = @($requests.store_location_id | Sort-Object -Unique)
          if ($stores -contains 'bakers-saddle-creek') {
            Invoke-Logged 'promotion-bakers-capture' { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $incomeRoot 'grocery\pull-regular-bakers-api.ps1') }
          }
          if ($stores -contains 'family-fare-omaha-6401') {
            Invoke-Logged 'promotion-family-fare-capture' { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $incomeRoot 'grocery\pull-regular-familyfare.ps1') }
          }
          if ($stores -contains 'hy-vee-omaha-1465') {
            Invoke-Logged 'promotion-hy-vee-capture' { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $incomeRoot 'grocery\pull-regular-hyvee.ps1') }
          }
          $storeKeys = @()
          if ($stores -contains 'bakers-saddle-creek') { $storeKeys += 'bakers' }
          if ($stores -contains 'family-fare-omaha-6401') { $storeKeys += 'family-fare' }
          if ($stores -contains 'hy-vee-omaha-1465') { $storeKeys += 'hy-vee' }
          if ($storeKeys.Count -gt 0) { Invoke-Logged 'promotion-capture-ingest' { & $pnpmPath tc capture ingest-current @storeKeys } }
          $publishForBoundary = $true
        }
        if ($publishForBoundary) { Invoke-Logged 'promotion-native-publish' { & $pnpmPath tc engine publish-native } }
        if ($requests.Count -gt 0) {
          $requestIds = @($requests.id)
          Invoke-Logged 'promotion-headless-complete' { & $pnpmPath tc promotion complete completed @requestIds }
        }
        if ($requests.Count -eq 0 -and -not $publishForBoundary) { Write-PcRuntimeLog $logFile 'no promotion boundary work is due; standing down' }
      }
      'family-fare-paced' {
        $globalLock = Join-Path $env:LOCALAPPDATA 'ThriftyCrew\grocery-v3\locks\platform-job-daily-engine.lock'
        if (Test-Path -LiteralPath $globalLock) { Write-PcRuntimeLog $logFile 'daily engine owns the capture files; paced run standing down'; break }
        Invoke-Logged 'family-fare-capture' { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $incomeRoot 'grocery\pull-regular-familyfare.ps1') }
        Invoke-Logged 'family-fare-ingest' { & $pnpmPath tc capture ingest-current family-fare }
      }
      'efficiency-daily' {
        $reportFile = Join-Path ([string]$config.logRoot) 'd1-efficiency-latest.json'
        Write-PcRuntimeLog $logFile 'START efficiency-check'
        $prior = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { $reportOutput = & node (Join-Path $platformRoot 'scripts\d1-efficiency-report.mjs') 1d 2>&1; $reportExit = $LASTEXITCODE }
        finally { $ErrorActionPreference = $prior }
        foreach ($line in @($reportOutput)) { Write-PcRuntimeLog $logFile ("efficiency-check: {0}" -f $line) }
        if ($reportExit -ne 0) { throw "efficiency-check failed with exit code $reportExit" }
        @($reportOutput) -join [Environment]::NewLine | Set-Content -LiteralPath $reportFile -Encoding UTF8
        Write-PcRuntimeLog $logFile 'DONE efficiency-check'
        Invoke-Logged 'efficiency-incident-reconcile' { & $pnpmPath tc efficiency record $reportFile }
        Invoke-Logged 'data-architecture-maintenance' { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $platformRoot 'scripts\run-data-architecture-maintenance.ps1') }
      }
      'accuracy-weekly' { Invoke-Logged 'accuracy-draw' { & $pnpmPath tc accuracy draw } }
      'accuracy-revalidation-daily' { Invoke-Logged 'accuracy-revalidation' { & $pnpmPath tc accuracy revalidate } }
      'triage-daily' { Invoke-Logged 'triage-run' { & $pnpmPath tc triage run } }
      'ghost-rotation-reconcile' { Invoke-Logged 'ghost-reconcile' { & $pnpmPath tc ghost reconcile } }
      'restore-drill-quarterly' { Invoke-Logged 'restore-trigger' { & $pnpmPath tc restore trigger } }
    }
  } finally { Pop-Location }
} catch {
  $failed = $true
  Write-PcRuntimeLog $logFile ("FAILED: {0}" -f $_.Exception.Message)
  Send-PcRuntimeAlert ("ThriftyCrew V3 local job failed: $Job") ("The authoritative local job $Job failed. The last error was:`n`n$($_.Exception.Message)`n`nLog: $logFile`n`nThe Worker will also retain the missed/failed ledger incident; GitHub Actions is intentionally not used for automatic recovery.")
} finally {
  if ($jobStarted) {
    try {
      Set-PcRuntimeCredential $config 'local-operator'
      $env:TC_GITHUB_JOB_STATUS = if ($failed) { 'failure' } else { 'success' }
      Push-Location $platformRoot
      try { Invoke-Logged 'job-ledger-finish' { & $pnpmPath tc job finish $Job $env:TC_GITHUB_JOB_STATUS } }
      finally { Pop-Location }
    } catch {
      $failed = $true
      Write-PcRuntimeLog $logFile ("job-ledger-finish failed: {0}" -f $_.Exception.Message)
      Send-PcRuntimeAlert ("ThriftyCrew V3 job ledger finish failed: $Job") ("The authoritative local job completed its work but could not record a terminal ledger state.`n`n$($_.Exception.Message)`n`nLog: $logFile")
    }
  }
  Exit-PcRuntimeLock $lock
  if (Test-Path -LiteralPath $env:TC_JOB_LEASE_FILE) { Remove-Item -LiteralPath $env:TC_JOB_LEASE_FILE -Force }
}
if ($failed) { exit 1 }
