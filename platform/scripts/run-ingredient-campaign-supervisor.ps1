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
$lastPricingStarts = @{}
$lastBrowserAlertKey = ''
$lastStallAlertKey = ''
$pricingProcesses = @{}
$recipeProcess = $null
$completionProcesses = @{}
$publisherProcess = $null

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
  $document = $text.Substring($start, $end - $start + 1) | ConvertFrom-Json
  if (-not $document.status) { throw 'ingredient pipeline status omitted its status payload' }
  return $document.status
}

function Start-Cycle([string]$CycleName, [int]$MaxItems, [int]$Slot = 0) {
  $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"{0}"' -f $cycleScript),
    '-Cycle', $CycleName, '-MaxItems', [string]$MaxItems)
  if ($Slot -gt 0) { $arguments += @('-PricingWorkerSlot', [string]$Slot) }
  return Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WorkingDirectory $platformRoot -WindowStyle Hidden -PassThru
}

function Start-PricingWorker([int]$Slot, [string]$Label, [int]$WorkCount) {
  $process = $pricingProcesses[$Slot]
  $lastStart = $lastPricingStarts[$Slot]
  if ($WorkCount -le 0 -or ($process -and -not $process.HasExited) -or
      ($lastStart -and ((Get-Date) - $lastStart).TotalSeconds -lt 2)) { return }
  $pricingProcesses[$Slot] = Start-Cycle 'IngredientPricing' 50 $Slot
  $lastPricingStarts[$Slot] = Get-Date
  Write-PcRuntimeLog $logFile ("started pricing worker {0}; queued={1}" -f $Label,$WorkCount)
}

function Start-CompletionWorker([int]$Slot, [string]$Label, [int]$WorkCount) {
  $process = $completionProcesses[$Slot]
  if ($WorkCount -le 0 -or ($process -and -not $process.HasExited)) { return }
  $scriptPath = Join-Path $platformRoot 'scripts\run-pc-agent-cycle.ps1'
  $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',('"{0}"' -f $scriptPath),
    '-Cycle','RecipeCompletion','-CompletionWorkerSlot',[string]$Slot,'-MaxItems','50')
  $completionProcesses[$Slot] = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WorkingDirectory $platformRoot -WindowStyle Hidden -PassThru
  Write-PcRuntimeLog $logFile ("started recipe completion worker {0}; queued={1}" -f $Label,$WorkCount)
}

try {
  Write-PcRuntimeLog $logFile 'stage-aware supervisor started; idle stages are not launched'
  while ($true) {
    $status = Read-IngredientStatus
    $pipeline = Read-PipelineStatus
    $campaigns = @($status.batches | Where-Object { -not $_.paused_at -and $_.state -ne 'completed' })

    $pending = @($status.gaps | Where-Object status -eq 'pending').Count
    $researching = @($status.gaps | Where-Object status -eq 'researching').Count
    $ready = @($status.gaps | Where-Object status -eq 'ready_to_publish').Count
    $headlessStoreIds = @('bakers-saddle-creek','family-fare-omaha-6401','hy-vee-omaha-1465')
    $browserStoreIds = @('aldi-omaha-446-048','fareway-omaha-043','sams-omaha','walmart-omaha')
    $terminalStoreStates = @('cancelled','qa_verified_priced','qa_verified_not_found')
    $headlessWork = [int](($pipeline.stores | Where-Object { $_.store_location_id -in $headlessStoreIds -and $_.state -notin $terminalStoreStates } | Measure-Object count -Sum).Sum)
    $browserWork = [int](($pipeline.stores | Where-Object { $_.store_location_id -in $browserStoreIds -and $_.state -notin $terminalStoreStates } | Measure-Object count -Sum).Sum)
    $inboxWork = [int](($pipeline.inbox | Where-Object { $_.state -in @('pending','claimed') } | Measure-Object count -Sum).Sum)
    $outboxWork = [int](($pipeline.outbox | Where-Object state -eq 'pending' | Measure-Object count -Sum).Sum)
    $catalogWork = [int](($pipeline.workerQueues | Where-Object role -eq 'catalog' | Measure-Object count -Sum).Sum)
    Start-PricingWorker 0 'coordinator/catalog' ($inboxWork + $outboxWork + $catalogWork)
    $headlessAssignments = @(
      @{ Slot=1; Store='bakers-saddle-creek'; Role='capture' }, @{ Slot=2; Store='bakers-saddle-creek'; Role='qa' },
      @{ Slot=3; Store='family-fare-omaha-6401'; Role='capture' }, @{ Slot=4; Store='family-fare-omaha-6401'; Role='qa' },
      @{ Slot=5; Store='hy-vee-omaha-1465'; Role='capture' }, @{ Slot=6; Store='hy-vee-omaha-1465'; Role='qa' }
    )
    foreach ($assignment in $headlessAssignments) {
      $roleWork = [int](($pipeline.workerQueues | Where-Object { $_.store_location_id -eq $assignment.Store -and $_.role -eq $assignment.Role } | Measure-Object count -Sum).Sum)
      Start-PricingWorker $assignment.Slot ("{0}/{1}" -f $assignment.Store,$assignment.Role) $roleWork
    }
    if ($browserWork -gt 0) {
      $browserBreakdown = @($pipeline.stores | Where-Object { $_.store_location_id -in $browserStoreIds -and $_.state -notin $terminalStoreStates } |
        Group-Object store_location_id | Sort-Object Name | ForEach-Object { "{0}={1}" -f $_.Name,[int](($_.Group | Measure-Object count -Sum).Sum) })
      $browserAlertKey = $browserBreakdown -join ';'
      if ($browserAlertKey -ne $lastBrowserAlertKey) {
        Send-PcRuntimeAlert 'Four Omaha browser pricing lanes are ready' ("Run Aldi, Fareway, Sam's, and Walmart as four simultaneous isolated Codex browser agents. Queue: $browserAlertKey. Chrome challenges raise a separate Done callback alert; one blocked store must not stop the other three.")
        $lastBrowserAlertKey = $browserAlertKey
      }
    } else { $lastBrowserAlertKey = '' }

    $completionReady = [int]$pipeline.recipeCompletionReady
    $writerWork = [int](($pipeline.recipeCompletionWork | Where-Object agent_id -eq 'recipe-writer' | Measure-Object count -Sum).Sum)
    $auditorWork = [int](($pipeline.recipeCompletionWork | Where-Object agent_id -eq 'recipe-auditor' | Measure-Object count -Sum).Sum)
    Start-CompletionWorker 1 'writer' ($completionReady + $writerWork)
    Start-CompletionWorker 2 'auditor/publisher' $auditorWork

    if ($pipeline.noProgressAlert -and ($headlessWork -gt 0 -or $browserWork -gt 0 -or $inboxWork -gt 0)) {
      if ($lastStallAlertKey -ne [string]$pipeline.lastProgressAt) {
        Send-PcRuntimeAlert 'Omaha ingredient pipeline has stalled' ("No durable progress for $($pipeline.noProgressSeconds) seconds with active work. Inspect per-store workers and browser challenges now.")
        $lastStallAlertKey = [string]$pipeline.lastProgressAt
      }
    } else { $lastStallAlertKey = '' }

    $collecting = @($campaigns | Where-Object { $_.state -eq 'collecting' -and -not $_.discovery_frozen_at }).Count -gt 0
    if ($collecting -and (-not $recipeProcess -or $recipeProcess.HasExited) -and ((Get-Date) - $lastRecipeStart).TotalSeconds -ge 5) {
      $recipeProcess = Start-Cycle 'Recipe' 50
      $lastRecipeStart = Get-Date
      Write-PcRuntimeLog $logFile 'started or recovered the recipe discovery stage'
    }

    $configuredBatchSize = if ($campaigns.Count -gt 0) { [int](($campaigns | Measure-Object publish_batch_size -Maximum).Maximum) } else { 50 }
    $batchSize = [Math]::Min(50, [Math]::Max(1, $configuredBatchSize))
    $remaining = if ($campaigns.Count -gt 0) { [int](($campaigns | ForEach-Object { [int]$_.target_published_ingredients - [int]$_.published_ingredients } | Measure-Object -Minimum).Minimum) } else { $ready }
    $publishLimit = [Math]::Min($batchSize, [Math]::Max(1, [int]$remaining))
    $flushTail = $ready -gt 0 -and $pending -eq 0 -and $researching -eq 0
    $definitionWork = [int](($pipeline.definitionWork | Measure-Object count -Sum).Sum)
    $definitionOrPublicationWork = $definitionWork -gt 0 -or $ready -ge $publishLimit -or $flushTail
    if ($definitionOrPublicationWork -and (-not $publisherProcess -or $publisherProcess.HasExited) -and ((Get-Date) - $lastPublisherStart).TotalSeconds -ge 5) {
      $publisherProcess = Start-Cycle 'IngredientPublication' $publishLimit
      $lastPublisherStart = Get-Date
      Write-PcRuntimeLog $logFile ("started batch publication for up to {0} ingredients; ready={1}" -f $publishLimit, $ready)
    }

    Write-PcRuntimeLog $logFile ("heartbeat campaigns={0} headless={1} browser={2} definition={3} pending={4} researching={5} ready={6}" -f $campaigns.Count, $headlessWork, $browserWork, $definitionWork, $pending, $researching, $ready)
    Start-Sleep -Seconds $PollSeconds
  }
} catch {
  Write-PcRuntimeLog $logFile ("SUPERVISOR FAILED: {0}" -f $_.Exception.Message)
  Send-PcRuntimeAlert 'ThriftyCrew ingredient campaign supervisor failed' ("The durable campaign is preserved but paused operationally.`n`n$($_.Exception.Message)`n`nLog: $logFile")
  exit 1
} finally {
  foreach ($process in $pricingProcesses.Values) {
    if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
  }
  foreach ($process in $completionProcesses.Values) {
    if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
  }
  Exit-PcRuntimeLock $lock
}
