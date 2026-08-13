param(
  [ValidateRange(5,60)][int]$PollSeconds = 10
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'pc-runtime-lib.ps1')
$config = Read-PcRuntimeConfig
Initialize-PcRuntimeEnvironment $config
$platformRoot = [string]$config.platformRoot
$pnpmPath = [string]$config.pnpmPath
$logFile = Join-Path ([string]$config.logRoot) 'ingredient-campaign-supervisor.log'
$cycleScript = Join-Path $platformRoot 'scripts\run-pc-agent-cycle.ps1'
$lock = Enter-PcRuntimeLock 'ingredient-campaign-supervisor' 300
if (-not $lock) { Write-PcRuntimeLog $logFile 'another supervisor owns the active ingredient campaign; standing down'; exit 0 }
$lastPublisherStart = [DateTime]::MinValue
$lastRecipeStart = [DateTime]::MinValue

function Read-IngredientStatus {
  Set-PcRuntimeCredential $config 'local-operator'
  $prior = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $output = & $pnpmPath --silent --filter '@thriftycrew/operator' tc ingredient status 2>$null
    $exitCode = $LASTEXITCODE
  } finally { $ErrorActionPreference = $prior }
  if ($exitCode -ne 0) { throw "ingredient status failed with exit code $exitCode" }
  $text = @($output) -join "`n"
  $start = $text.IndexOf('{')
  $end = $text.LastIndexOf('}')
  if ($start -lt 0 -or $end -le $start) { throw 'ingredient status returned no JSON document' }
  return ($text.Substring($start, $end - $start + 1) | ConvertFrom-Json)
}

function Read-PipelineStatus {
  Set-PcRuntimeCredential $config 'local-operator'
  $prior = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $output = & $pnpmPath --silent --filter '@thriftycrew/operator' tc ingredient pipeline status 2>$null
    $exitCode = $LASTEXITCODE
  } finally { $ErrorActionPreference = $prior }
  if ($exitCode -ne 0) { throw "ingredient pipeline status failed with exit code $exitCode" }
  $text = @($output) -join "`n"
  $start = $text.IndexOf('{')
  $end = $text.LastIndexOf('}')
  if ($start -lt 0 -or $end -le $start) { throw 'ingredient pipeline status returned no JSON document' }
  return ($text.Substring($start, $end - $start + 1) | ConvertFrom-Json)
}

function Get-CycleProcesses([string]$CycleName) {
  return @(Get-CimInstance Win32_Process | Where-Object {
    $_.Name -eq 'powershell.exe' -and $_.CommandLine -match 'run-pc-agent-cycle\.ps1' -and
    $_.CommandLine -match ("-Cycle\s+{0}(?:\s|$)" -f [regex]::Escape($CycleName))
  })
}

function Start-Cycle([string]$CycleName, [int]$MaxItems, [int]$Slot = 0) {
  $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"{0}"' -f $cycleScript),
    '-Cycle', $CycleName, '-MaxItems', [string]$MaxItems)
  if ($Slot -gt 0) { $arguments += @('-PricingWorkerSlot', [string]$Slot) }
  Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WorkingDirectory $platformRoot -WindowStyle Hidden | Out-Null
}

try {
  Write-PcRuntimeLog $logFile 'persistent event-driven supervisor started; research, sourcing, and publication are isolated stages'
  while ($true) {
    $status = Read-IngredientStatus
    $pipeline = Read-PipelineStatus
    $campaigns = @($status.batches | Where-Object { -not $_.paused_at -and $_.state -ne 'completed' })

    $pending = @($status.gaps | Where-Object status -eq 'pending').Count
    $researching = @($status.gaps | Where-Object status -eq 'researching').Count
    $ready = @($status.gaps | Where-Object status -eq 'ready_to_publish').Count
    $v2RunningJobs = [int](($pipeline.status.jobs | Where-Object { $_.state -in @('queued', 'store_checks_running', 'qa_running') } | Measure-Object count -Sum).Sum)
    $desiredWorkers = 1
    $workerProcesses = Get-CycleProcesses 'IngredientPricing'
    $activeSlots = [Collections.Generic.HashSet[int]]::new()
    foreach ($process in $workerProcesses) {
      if ([string]$process.CommandLine -match '-PricingWorkerSlot\s+(\d+)') { [void]$activeSlots.Add([int]$matches[1]) }
    }
    $neededWorkers = if (($pending + $researching + $v2RunningJobs) -gt 0) { 1 } else { 0 }
    if ($neededWorkers -gt 0) {
      foreach ($slot in 1..$neededWorkers) {
        if ($activeSlots.Contains($slot)) { continue }
        $slotLock = Join-Path (Split-Path -Parent ([string]$config.logRoot)) ("locks\agent-cycle-ingredientpricing-{0}.lock" -f $slot)
        if (Test-Path -LiteralPath $slotLock) { Remove-Item -LiteralPath $slotLock -Force }
        Start-Cycle 'IngredientPricing' 50 $slot
        Write-PcRuntimeLog $logFile ("started or recovered pricing worker slot {0}" -f $slot)
        Start-Sleep -Milliseconds 600
      }
    }

    $collecting = @($campaigns | Where-Object { $_.state -eq 'collecting' -and -not $_.discovery_frozen_at }).Count -gt 0
    if ($collecting -and (Get-CycleProcesses 'Recipe').Count -eq 0 -and ((Get-Date) - $lastRecipeStart).TotalSeconds -ge 60) {
      Start-Cycle 'Recipe' 50
      $lastRecipeStart = Get-Date
      Write-PcRuntimeLog $logFile 'started or recovered the recipe discovery stage'
    }

    $configuredBatchSize = if ($campaigns.Count -gt 0) { [int](($campaigns | Measure-Object publish_batch_size -Maximum).Maximum) } else { 50 }
    $batchSize = [Math]::Min(50, [Math]::Max(1, $configuredBatchSize))
    $remaining = if ($campaigns.Count -gt 0) { [int](($campaigns | ForEach-Object { [int]$_.target_published_ingredients - [int]$_.published_ingredients } | Measure-Object -Minimum).Minimum) } else { $ready }
    $publishLimit = [Math]::Min($batchSize, [Math]::Max(1, [int]$remaining))
    $flushTail = $ready -gt 0 -and $pending -eq 0 -and $researching -eq 0
    if (($ready -ge $publishLimit -or $flushTail) -and (Get-CycleProcesses 'IngredientPublication').Count -eq 0 -and ((Get-Date) - $lastPublisherStart).TotalSeconds -ge 60) {
      Start-Cycle 'IngredientPublication' $publishLimit
      $lastPublisherStart = Get-Date
      Write-PcRuntimeLog $logFile ("started batch publication for up to {0} ingredients; ready={1}" -f $publishLimit, $ready)
    }

    Write-PcRuntimeLog $logFile ("heartbeat campaigns={0} v2RunningJobs={1} pending={2} researching={3} ready={4} workers={5}/{6}" -f $campaigns.Count, $v2RunningJobs, $pending, $researching, $ready, $workerProcesses.Count, $desiredWorkers)
    Start-Sleep -Seconds $PollSeconds
  }
} catch {
  Write-PcRuntimeLog $logFile ("SUPERVISOR FAILED: {0}" -f $_.Exception.Message)
  Send-PcRuntimeAlert 'ThriftyCrew ingredient campaign supervisor failed' ("The durable campaign is preserved but paused operationally.`n`n$($_.Exception.Message)`n`nLog: $logFile")
  exit 1
} finally {
  Exit-PcRuntimeLock $lock
}
