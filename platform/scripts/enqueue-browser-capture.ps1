param(
  [Parameter(Mandatory)][ValidateSet('aldi','fareway','sams','walmart')][string]$Store,
  [Parameter(Mandatory)][string]$RegularFile,
  [Parameter(Mandatory)][string]$SessionManifest,
  [Parameter(Mandatory)][string]$RawCapture,
  [Parameter(Mandatory)][string[]]$Screenshot,
  [Parameter(Mandatory)][ValidatePattern('^https://')][string]$EvidenceUrl,
  [Parameter(Mandatory)][string]$Statement,
  [string]$VerifiedAt = '',
  [string]$QueueRoot = '',
  [switch]$KeepStaging
)

$ErrorActionPreference = 'Stop'
$platformRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$clientConfig = Join-Path $env:LOCALAPPDATA 'ThriftyCrew\grocery-v3\pc-capture-client.json'
if (-not (Test-Path -LiteralPath $clientConfig)) { throw "V3 browser capture client is not installed: $clientConfig" }
$config = Get-Content -LiteralPath $clientConfig -Raw -Encoding UTF8 | ConvertFrom-Json

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

$regularPath = (Resolve-Path -LiteralPath $RegularFile).Path
$sessionPath = (Resolve-Path -LiteralPath $SessionManifest).Path
$rawCapturePath = (Resolve-Path -LiteralPath $RawCapture).Path
$screenshots = @($Screenshot | ForEach-Object { (Resolve-Path -LiteralPath $_).Path })
if ($screenshots.Count -eq 0) { throw 'at least one screenshot is required' }
foreach ($file in $screenshots) {
  if ([IO.Path]::GetExtension($file).ToLowerInvariant() -notin @('.png','.jpg','.jpeg','.webp')) {
    throw "browser evidence must be an image: $file"
  }
}
$session = Get-Content -LiteralPath $sessionPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$session.store -ne $Store) { throw "capture session is for $($session.store), not $Store" }
$accuracyCutover = [datetime]::Parse('2026-08-12T05:00:00.000Z').ToUniversalTime()
$sessionFinished = [datetime]::Parse([string]$session.finishedAt).ToUniversalTime()
if ($sessionFinished -ge $accuracyCutover) {
  if ([int]$session.version -ne 2) { throw 'pre-accuracy browser session contract is retired for this capture window' }
  if ($session.accuracy.pass -ne $true) { throw 'capture-session accuracy report did not pass' }
  if ([int]$session.accuracy.unresolvedVerificationRows -ne 0) { throw 'capture-session has unresolved targeted verification rows' }
  if ([int]$session.accuracy.matchedVerificationRows -ne [int]$session.accuracy.requiredVerificationRows) { throw 'capture-session targeted verification counts do not balance' }
  if ([int]$session.accuracy.retrievalCompleteTerms -ne [int]$session.expectedTerms) { throw 'capture-session pagination/result-depth coverage is incomplete' }
}
$rawHash = (Get-FileHash -LiteralPath $rawCapturePath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($rawHash -ne [string]$session.projectedCaptureSha256) { throw 'raw projected capture does not match the capture-session manifest' }
$screenshotHashes = @($screenshots | ForEach-Object { (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash.ToLowerInvariant() })
$canaryHashes = @($session.canaries | ForEach-Object { [string]$_.screenshotSha256 } | Where-Object { $_ })
if (-not @($screenshotHashes | Where-Object { $canaryHashes -contains $_ }).Count) { throw 'no supplied screenshot is bound by a capture-session canary' }

$storeMetadata = @{
  aldi = @{ label = 'Aldi'; priceMode = 'in-store' }
  fareway = @{ label = 'Fareway'; priceMode = 'in-store' }
  sams = @{ label = "Sam's Club"; priceMode = 'club pickup' }
  walmart = @{ label = 'Walmart'; priceMode = 'pickup' }
}
$meta = $storeMetadata[$Store]
$instant = if ($VerifiedAt) { [datetime]::Parse($VerifiedAt).ToUniversalTime() } else { [datetime]::Parse([string]$session.finishedAt).ToUniversalTime() }
$stagingRoot = Join-Path $env:LOCALAPPDATA 'ThriftyCrew\grocery-v3\capture-staging'
$staging = Join-Path $stagingRoot ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $staging -Force | Out-Null
$attestationFile = Join-Path $staging 'attestation.json'
$artifactFile = Join-Path $staging 'artifact.json'
$augmentedRegularFile = Join-Path $staging 'regular-with-session.json'
$sessionEvidenceFile = Join-Path $staging 'capture-session-manifest.json'
$rawEvidenceFile = Join-Path $staging ('projected-capture' + [IO.Path]::GetExtension($rawCapturePath))

try {
  [ordered]@{
    store = $meta.label
    market = 'Omaha, Nebraska'
    priceMode = $meta.priceMode
    verifiedAt = $instant.ToString('o')
    evidenceUrl = $EvidenceUrl
    statement = $Statement
    marketVerified = $true
    locationVerified = $true
    priceModeVerified = $true
    screenshotSha256 = $screenshotHashes
    captureSessionHash = [string]$session.contentHash
  } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $attestationFile -Encoding UTF8

  $regular = Get-Content -LiteralPath $regularPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $adScheduleFile = Join-Path (Split-Path -Parent $platformRoot) 'grocery\ad-schedule.json'
  if (Test-Path -LiteralPath $adScheduleFile) {
    $adLabel = @{ aldi='Aldi'; fareway='Fareway'; sams="Sam's Club"; walmart='Walmart' }[$Store]
    $adEntry = @((Get-Content -LiteralPath $adScheduleFile -Raw -Encoding UTF8 | ConvertFrom-Json).stores) |
      Where-Object { [string]$_.store -eq $adLabel } | Select-Object -First 1
    $today = (Get-Date).Date
    $window = if ($adEntry -and $adEntry.current -and $adEntry.current.from -and $adEntry.current.to -and ([datetime]$adEntry.current.to).Date -ge $today) {
      @{ from = [string]$adEntry.current.from; to = [string]$adEntry.current.to }
    } elseif ($Store -in @('aldi','fareway')) {
      $startWeekday = if ($Store -eq 'aldi') { [DayOfWeek]::Wednesday } else { [DayOfWeek]::Sunday }
      $daysBack = (([int]$today.DayOfWeek - [int]$startWeekday) + 7) % 7
      $from = $today.AddDays(-$daysBack)
      @{ from = $from.ToString('yyyy-MM-dd'); to = $from.AddDays(6).ToString('yyyy-MM-dd') }
    } else { $null }
    if ($window) {
      $regular | Add-Member -NotePropertyName ad_from -NotePropertyValue ([string]$window.from) -Force
      $regular | Add-Member -NotePropertyName ad_to -NotePropertyValue ([string]$window.to) -Force
    }
  }
  $regular | Add-Member -NotePropertyName capture_session -NotePropertyValue $session -Force
  $regular | Add-Member -NotePropertyName coverage_mode -NotePropertyValue ([string]$session.coverageMode) -Force
  $regular | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $augmentedRegularFile -Encoding UTF8
  Copy-Item -LiteralPath $sessionPath -Destination $sessionEvidenceFile
  Copy-Item -LiteralPath $rawCapturePath -Destination $rawEvidenceFile

  $pnpmPath = [string]$config.pnpmPath
  if (-not (Test-Path -LiteralPath $pnpmPath)) { throw "configured pnpm executable is missing: $pnpmPath" }
  $runtimePath = @($config.runtimePath | ForEach-Object { [string]$_ })
  if ($runtimePath.Count -gt 0) {
    $env:Path = (($runtimePath -join [IO.Path]::PathSeparator) + [IO.Path]::PathSeparator + $env:Path)
  }
  $env:TC_CAPTURE_QUEUE = if ($QueueRoot) { [IO.Path]::GetFullPath($QueueRoot) } else { [string]$config.queueRoot }

  Push-Location $platformRoot
  try {
    & $pnpmPath 'tc' 'capture' 'build-regular' $Store $augmentedRegularFile $artifactFile $attestationFile '--browser'
    if ($LASTEXITCODE -ne 0) { throw "V3 artifact build failed for $Store" }
    & $pnpmPath 'tc' 'capture' 'validate' $artifactFile
    if ($LASTEXITCODE -ne 0) { throw "V3 artifact validation failed for $Store" }
    & $pnpmPath 'tc' 'capture' 'queue' 'enqueue' $artifactFile @screenshots $rawEvidenceFile $sessionEvidenceFile
    if ($LASTEXITCODE -ne 0) { throw "V3 queue enqueue failed for $Store" }
    try { Invoke-CaptureController '/v1/queue/wake' @{ store = $Store } | Out-Null }
    catch { Write-Verbose 'Persistent capture controller is not running; the scheduled queue client will drain the job.' }
  } finally {
    Pop-Location
  }
} finally {
  if (-not $KeepStaging) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
}
