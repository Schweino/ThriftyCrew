param(
  [Parameter(Mandatory)][ValidateSet('aldi','fareway','sams','walmart')][string]$Store,
  [Parameter(Mandatory)][string]$RegularFile,
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

$regularPath = (Resolve-Path -LiteralPath $RegularFile).Path
$screenshots = @($Screenshot | ForEach-Object { (Resolve-Path -LiteralPath $_).Path })
if ($screenshots.Count -eq 0) { throw 'at least one screenshot is required' }
foreach ($file in $screenshots) {
  if ([IO.Path]::GetExtension($file).ToLowerInvariant() -notin @('.png','.jpg','.jpeg','.webp')) {
    throw "browser evidence must be an image: $file"
  }
}

$storeMetadata = @{
  aldi = @{ label = 'Aldi'; priceMode = 'in-store' }
  fareway = @{ label = 'Fareway'; priceMode = 'in-store' }
  sams = @{ label = "Sam's Club"; priceMode = 'club pickup' }
  walmart = @{ label = 'Walmart'; priceMode = 'pickup' }
}
$meta = $storeMetadata[$Store]
$instant = if ($VerifiedAt) { [datetime]::Parse($VerifiedAt).ToUniversalTime() } else { [datetime]::UtcNow }
$stagingRoot = Join-Path $env:LOCALAPPDATA 'ThriftyCrew\grocery-v3\capture-staging'
$staging = Join-Path $stagingRoot ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $staging -Force | Out-Null
$attestationFile = Join-Path $staging 'attestation.json'
$artifactFile = Join-Path $staging 'artifact.json'

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
  } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $attestationFile -Encoding UTF8

  $pnpmPath = [string]$config.pnpmPath
  if (-not (Test-Path -LiteralPath $pnpmPath)) { throw "configured pnpm executable is missing: $pnpmPath" }
  $runtimePath = @($config.runtimePath | ForEach-Object { [string]$_ })
  if ($runtimePath.Count -gt 0) {
    $env:Path = (($runtimePath -join [IO.Path]::PathSeparator) + [IO.Path]::PathSeparator + $env:Path)
  }
  $env:TC_CAPTURE_QUEUE = if ($QueueRoot) { [IO.Path]::GetFullPath($QueueRoot) } else { [string]$config.queueRoot }

  Push-Location $platformRoot
  try {
    & $pnpmPath 'tc' 'capture' 'build-regular' $Store $regularPath $artifactFile $attestationFile '--browser'
    if ($LASTEXITCODE -ne 0) { throw "V3 artifact build failed for $Store" }
    & $pnpmPath 'tc' 'capture' 'validate' $artifactFile
    if ($LASTEXITCODE -ne 0) { throw "V3 artifact validation failed for $Store" }
    & $pnpmPath 'tc' 'capture' 'queue' 'enqueue' $artifactFile @screenshots
    if ($LASTEXITCODE -ne 0) { throw "V3 queue enqueue failed for $Store" }
  } finally {
    Pop-Location
  }
} finally {
  if (-not $KeepStaging) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
}
