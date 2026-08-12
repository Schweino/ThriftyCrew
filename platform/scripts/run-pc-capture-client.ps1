param([ValidateSet('Drain','Watchdog','Cycle')][string]$Mode = 'Cycle')
$ErrorActionPreference = 'Stop'

$mutex = [Threading.Mutex]::new($false, 'Local\ThriftyCrew-GroceryV3-CaptureClient')
$hasMutex = $false
try { $hasMutex = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $hasMutex = $true }
if (-not $hasMutex) { exit 0 }

try {

$clientDir = Join-Path $env:LOCALAPPDATA 'ThriftyCrew\grocery-v3'
$configFile = Join-Path $clientDir 'pc-capture-client.json'
if (-not (Test-Path -LiteralPath $configFile)) { throw "PC capture client is not installed: $configFile is missing" }
$config = Get-Content -LiteralPath $configFile -Raw | ConvertFrom-Json

function Invoke-CaptureController([string]$Pathname, [hashtable]$Body) {
  $pipe = [IO.Pipes.NamedPipeClientStream]::new('.', 'ThriftyCrew.GroceryV3.CaptureController', [IO.Pipes.PipeDirection]::InOut, [IO.Pipes.PipeOptions]::Asynchronous)
  try {
    $pipe.Connect(750)
    $writer = [IO.StreamWriter]::new($pipe, [Text.UTF8Encoding]::new($false), 1024, $true)
    $reader = [IO.StreamReader]::new($pipe, [Text.UTF8Encoding]::new($false), $false, 1024, $true)
    $writer.AutoFlush = $true
    $writer.WriteLine((@{ token = [string]$config.controllerToken; pathname = $Pathname; body = $Body } | ConvertTo-Json -Compress -Depth 5))
    return ($reader.ReadLine() | ConvertFrom-Json)
  } finally { $pipe.Dispose() }
}
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
$logRoot = Join-Path $clientDir 'logs'
New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
$runId = '{0}-{1}' -f (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'), ([guid]::NewGuid().ToString('N').Substring(0,8))
$logFile = Join-Path $logRoot ("pc-capture-client-$runId.jsonl")
$activeLog = Join-Path $clientDir 'pc-capture-client.log'
if ((Test-Path -LiteralPath $activeLog) -and (Get-Item -LiteralPath $activeLog).Length -gt 5MB) {
  Move-Item -LiteralPath $activeLog -Destination (Join-Path $logRoot ("pc-capture-client-rollover-$runId.jsonl")) -Force
}
$oldLogs = @(Get-ChildItem -LiteralPath $logRoot -Filter 'pc-capture-client-*.jsonl' -File | Sort-Object LastWriteTimeUtc -Descending | Select-Object -Skip 30)
foreach ($oldLog in $oldLogs) { Remove-Item -LiteralPath $oldLog.FullName -Force -ErrorAction SilentlyContinue }
$platformRoot = [string]$config.platformRoot
$pnpmPath = [string]$config.pnpmPath
$runtimePath = @($config.runtimePath | ForEach-Object { [string]$_ })
if ($runtimePath.Count -gt 0) { $env:Path = (($runtimePath -join [IO.Path]::PathSeparator) + [IO.Path]::PathSeparator + $env:Path) }

function Invoke-CaptureCommand([string[]]$Arguments) {
  Push-Location $platformRoot
  try {
    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
      $output = & $pnpmPath @Arguments 2>&1
      $exitCode = $LASTEXITCODE
    } finally {
      $ErrorActionPreference = $previousErrorAction
    }
    $output | ForEach-Object {
      $message = [string]$_
      if ($message.Length -gt 4000) { $message = $message.Substring(0, 4000) + '…[truncated]' }
      $entry = [ordered]@{ at = (Get-Date).ToUniversalTime().ToString('o'); runId = $runId; mode = $Mode; command = ($Arguments -join ' '); message = $message }
      $line = $entry | ConvertTo-Json -Compress
      Add-Content -LiteralPath $logFile -Value $line
      Add-Content -LiteralPath $activeLog -Value $line
    }
    return $exitCode
  } finally { Pop-Location }
}

$finalExit = 0
if ($Mode -eq 'Drain' -or $Mode -eq 'Cycle') {
  $controllerAccepted = $false
  try {
    $controller = Invoke-CaptureController '/v1/queue/wake' @{ reason = 'pc-client' }
    $controllerAccepted = $controller.accepted -eq $true
  } catch { $controllerAccepted = $false }
  if (-not $controllerAccepted) {
    $drainExit = Invoke-CaptureCommand @('tc','capture','queue','drain')
    if ($drainExit -ne 0) { $finalExit = $drainExit }
  }
}
if ($Mode -eq 'Watchdog' -or $Mode -eq 'Cycle') {
  $watchdogExit = Invoke-CaptureCommand @('tc','capture','queue','watchdog')
  if ($watchdogExit -ne 0) { $finalExit = $watchdogExit }
}
Remove-Variable tcSecret -ErrorAction SilentlyContinue
exit $finalExit
} finally {
  if ($hasMutex) { $mutex.ReleaseMutex() }
  $mutex.Dispose()
}
