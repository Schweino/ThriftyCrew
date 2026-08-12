param(
  [int]$MaximumPasses = 25,
  [string]$PythonPath = $env:TC_ARCHIVE_PYTHON
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'pc-runtime-lib.ps1')
$config = Read-PcRuntimeConfig
Initialize-PcRuntimeEnvironment $config
Set-PcRuntimeCredential $config 'local-operator'
$platformRoot = Split-Path -Parent $PSScriptRoot
$builder = Join-Path $PSScriptRoot 'build-archive-parquet.py'
if (-not $PythonPath) {
  $bundled = Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
  if (Test-Path -LiteralPath $bundled) { $PythonPath = $bundled }
}
if (-not $PythonPath -or -not (Test-Path -LiteralPath $PythonPath)) {
  throw 'A Python runtime with scripts/requirements-archive.txt installed is required; set TC_ARCHIVE_PYTHON.'
}
$workRoot = Join-Path ([string]$config.logRoot) 'canonical-cleanup'
New-Item -ItemType Directory -Force -Path $workRoot | Out-Null

function Invoke-TcJson([string[]]$Arguments) {
  $output = & ([string]$config.pnpmPath) --silent --filter '@thriftycrew/operator' tc @Arguments 2>&1
  if ($LASTEXITCODE -ne 0) { throw "tc $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)" }
  $text = $output -join [Environment]::NewLine
  $start = $text.IndexOf('{')
  $end = $text.LastIndexOf('}')
  if ($start -lt 0 -or $end -lt $start) { throw "tc returned no JSON: $text" }
  return ($text.Substring($start, $end - $start + 1) | ConvertFrom-Json)
}

$removed = 0
$passes = 0
Push-Location $platformRoot
try {
  while ($passes -lt $MaximumPasses) {
    $preview = Invoke-TcJson @('cleanup', 'plan')
    if ([int]$preview.candidates -eq 0) { break }
    $plan = Invoke-TcJson @('cleanup', 'plan', '--execute')
    $runId = [string]$plan.runId
    if (-not $runId) { throw 'cleanup plan returned no run id' }
    $jsonFile = Join-Path $workRoot ($runId + '.json')
    $parquetFile = Join-Path $workRoot ($runId + '.parquet')
    Invoke-TcJson @('cleanup', 'export', $runId, $jsonFile) | Out-Null
    & $PythonPath $builder $jsonFile $parquetFile
    if ($LASTEXITCODE -ne 0) { throw "Parquet build failed for $runId" }
    $sha256 = (Get-FileHash -LiteralPath $parquetFile -Algorithm SHA256).Hash.ToLowerInvariant()
    $uploaded = Invoke-TcJson @('cleanup', 'upload', $runId, $parquetFile)
    if ([string]$uploaded.sha256 -ne $sha256) { throw "R2 hash confirmation disagreed for $runId" }
    $completed = Invoke-TcJson @('cleanup', 'execute', $runId, $sha256)
    $removed += [int]$completed.removedFacts
    $passes += 1
    Remove-Item -LiteralPath $jsonFile, $parquetFile -Force
    Write-Output ("cleanup pass {0}: archived and removed {1} facts" -f $passes, [int]$completed.removedFacts)
  }
  $remaining = Invoke-TcJson @('cleanup', 'plan')
  if ([int]$remaining.candidates -gt 0 -and $passes -ge $MaximumPasses) {
    throw "cleanup still has $($remaining.candidates) candidates after the maximum pass count"
  }
  [pscustomobject]@{ ok = $true; passes = $passes; removedFacts = $removed; remainingCandidates = [int]$remaining.candidates } | ConvertTo-Json
} finally {
  Pop-Location
}
