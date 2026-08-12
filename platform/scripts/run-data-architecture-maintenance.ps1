param([int]$MaximumPasses = 100)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'pc-runtime-lib.ps1')
$config = Read-PcRuntimeConfig
Initialize-PcRuntimeEnvironment $config
Set-PcRuntimeCredential $config 'local-operator'
$platformRoot = Split-Path -Parent $PSScriptRoot

function Invoke-TcJson([string[]]$Arguments) {
  $output = & ([string]$config.pnpmPath) --silent --filter '@thriftycrew/operator' tc @Arguments 2>&1
  if ($LASTEXITCODE -ne 0) { throw "tc $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)" }
  $text = $output -join [Environment]::NewLine
  $start = $text.IndexOf('{'); $end = $text.LastIndexOf('}')
  if ($start -lt 0 -or $end -lt $start) { throw "tc returned no JSON: $text" }
  return ($text.Substring($start, $end - $start + 1) | ConvertFrom-Json)
}

Push-Location $platformRoot
try {
  $passes = 0
  do {
    $reason = Invoke-TcJson @('maintenance', 'architecture', 'reasons')
    $passes++
  } while ([int]$reason.remaining -gt 0 -and $passes -lt $MaximumPasses)
  if ([int]$reason.remaining -gt 0) { throw 'release reason maintenance exceeded its pass limit' }

  $passes = 0
  do {
    $entity = Invoke-TcJson @('maintenance', 'architecture', 'entities')
    $passes++
  } while ([int]$entity.remaining -gt 0 -and $passes -lt $MaximumPasses)
  if ([int]$entity.remaining -gt 0) { throw 'product entity maintenance exceeded its pass limit' }
  $suggestions = Invoke-TcJson @('maintenance', 'architecture', 'suggestions')

  $status = Invoke-TcJson @('maintenance', 'architecture', 'status')
  foreach ($release in @($status.releases)) {
    if ([int]$release.costs -gt [int]$release.detail_objects) {
      Invoke-TcJson @('maintenance', 'architecture', 'build-details', [string]$release.id) | Out-Null
    }
  }
  $status = Invoke-TcJson @('maintenance', 'architecture', 'status')
  foreach ($release in @($status.releases)) {
    if ([string]$release.state -eq 'superseded' -and [int]$release.detail_objects -gt [int]$release.compacted) {
      Invoke-TcJson @('maintenance', 'architecture', 'compact-details', [string]$release.id) | Out-Null
    }
  }
  $final = Invoke-TcJson @('maintenance', 'architecture', 'status')
  [pscustomobject]@{ ok = $true; releaseReasonsRemaining = $final.releaseReasonsRemaining; entityProductsRemaining = $final.entityProductsRemaining; entitySuggestionsCreated = $suggestions.created; releases = @($final.releases).Count } | ConvertTo-Json
} finally { Pop-Location }
