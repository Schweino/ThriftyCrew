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
  Write-PcRuntimeLog $logFile 'supervisor started; research, sourcing, and publication are isolated stages'
  while ($true) {
    $status = Read-IngredientStatus
    $campaigns = @($status.batches | Where-Object { -not $_.paused_at -and $_.state -ne 'completed' -and [int]$_.published_ingredients -lt [int]$_.target_published_ingredients })
    if ($campaigns.Count -eq 0) {
      Write-PcRuntimeLog $logFile 'no active ingredient campaign remains; supervisor completed'
      break
    }

    $pending = @($status.gaps | Where-Object status -eq 'pending').Count
    $researching = @($status.gaps | Where-Object status -eq 'researching').Count
    $ready = @($status.gaps | Where-Object status -eq 'ready_to_publish').Count
    $desiredWorkers = [Math]::Min(10, [Math]::Max(1, ($campaigns | Measure-Object desired_pricing_workers -Maximum).Maximum))
    $workerProcesses = Get-CycleProcesses 'IngredientPricing'
    $activeSlots = [Collections.Generic.HashSet[int]]::new()
    foreach ($process in $workerProcesses) {
      if ([string]$process.CommandLine -match '-PricingWorkerSlot\s+(\d+)') { [void]$activeSlots.Add([int]$matches[1]) }
    }
    $neededWorkers = [Math]::Min($desiredWorkers, $pending + $researching)
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

    $collecting = @($campaigns | Where-Object state -eq 'collecting').Count -gt 0
    if ($collecting -and (Get-CycleProcesses 'Recipe').Count -eq 0 -and ((Get-Date) - $lastRecipeStart).TotalSeconds -ge 60) {
      Start-Cycle 'Recipe' 50
      $lastRecipeStart = Get-Date
      Write-PcRuntimeLog $logFile 'started or recovered the recipe discovery stage'
    }

    $batchSize = [Math]::Min(50, [Math]::Max(1, ($campaigns | Measure-Object publish_batch_size -Maximum).Maximum))
    $remaining = ($campaigns | ForEach-Object { [int]$_.target_published_ingredients - [int]$_.published_ingredients } | Measure-Object -Minimum).Minimum
    $publishLimit = [Math]::Min($batchSize, [Math]::Max(1, [int]$remaining))
    $flushTail = $ready -gt 0 -and $pending -eq 0 -and $researching -eq 0
    if (($ready -ge $publishLimit -or $flushTail) -and (Get-CycleProcesses 'IngredientPublication').Count -eq 0 -and ((Get-Date) - $lastPublisherStart).TotalSeconds -ge 60) {
      Start-Cycle 'IngredientPublication' $publishLimit
      $lastPublisherStart = Get-Date
      Write-PcRuntimeLog $logFile ("started batch publication for up to {0} ingredients; ready={1}" -f $publishLimit, $ready)
    }

    Write-PcRuntimeLog $logFile ("heartbeat campaigns={0} pending={1} researching={2} ready={3} workers={4}/{5}" -f $campaigns.Count, $pending, $researching, $ready, $workerProcesses.Count, $desiredWorkers)
    Start-Sleep -Seconds $PollSeconds
  }
} catch {
  Write-PcRuntimeLog $logFile ("SUPERVISOR FAILED: {0}" -f $_.Exception.Message)
  Send-PcRuntimeAlert 'ThriftyCrew ingredient campaign supervisor failed' ("The durable campaign is preserved but paused operationally.`n`n$($_.Exception.Message)`n`nLog: $logFile")
  exit 1
} finally {
  Exit-PcRuntimeLock $lock
}
