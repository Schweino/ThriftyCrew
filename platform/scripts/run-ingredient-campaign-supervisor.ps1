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
$lastPricingStart = [DateTime]::MinValue
$lastBrowserAlertKey = ''
$pricingProcess = $null
$recipeProcess = $null
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
    if (($headlessWork -gt 0 -or $inboxWork -gt 0 -or $outboxWork -gt 0) -and
        (-not $pricingProcess -or $pricingProcess.HasExited) -and ((Get-Date) - $lastPricingStart).TotalSeconds -ge 5) {
      $pricingProcess = Start-Cycle 'IngredientPricing' 50
      $lastPricingStart = Get-Date
      Write-PcRuntimeLog $logFile ("started one bounded headless pricing tick; headless={0} inbox={1} outbox={2}" -f $headlessWork, $inboxWork, $outboxWork)
    }
    if ($browserWork -gt 0) {
      $browserAlertKey = [string]$browserWork
      if ($browserAlertKey -ne $lastBrowserAlertKey) {
        Send-PcRuntimeAlert 'Omaha pricing browser lanes are ready' ("$browserWork browser-store checks are queued. Open Codex and ask it to use `$omaha-ingredient-pricing. Chrome challenges will raise a separate Done callback alert.")
        $lastBrowserAlertKey = $browserAlertKey
      }
    } else { $lastBrowserAlertKey = '' }

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
  if ($pricingProcess -and -not $pricingProcess.HasExited) { Stop-Process -Id $pricingProcess.Id -Force -ErrorAction SilentlyContinue }
  Exit-PcRuntimeLock $lock
}
