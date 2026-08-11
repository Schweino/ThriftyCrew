param([switch]$Apply)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'pc-runtime-lib.ps1')
$config = Read-PcRuntimeConfig
Initialize-PcRuntimeEnvironment $config
Set-PcRuntimeCredential $config 'local-operator'
$platformRoot = [string]$config.platformRoot
$pnpmPath = [string]$config.pnpmPath
$authority = Get-Content -LiteralPath (Join-Path $platformRoot 'config\schedules.json') -Raw | ConvertFrom-Json

Push-Location $platformRoot
try {
  $raw = & $pnpmPath --silent --filter '@thriftycrew/operator' tc transition readiness 2>&1
  if ($LASTEXITCODE -ne 0) { throw "transition readiness failed with exit code $LASTEXITCODE" }
  $readiness = ($raw -join "`n") | ConvertFrom-Json
  $eligible = @($readiness.schedules | Where-Object { $_.eligible -eq $true })
  if (-not $Apply) {
    [pscustomobject]@{ ok = $true; apply = $false; eligible = $eligible } | ConvertTo-Json -Depth 20
    exit 0
  }
  $retired = @()
  foreach ($candidate in $eligible) {
    $definition = $authority.schedules | Where-Object { $_.id -eq [string]$candidate.job } | Select-Object -First 1
    if (-not $definition) { throw "eligible transition $($candidate.job) is absent from local authority" }
    $disabledTask = $null
    try {
      if ($definition.executor -eq 'pc') {
        if (-not $definition.windowsTask) { throw "PC transition $($candidate.job) has no exact Windows task" }
        $task = Get-ScheduledTask -TaskName ([string]$definition.windowsTask) -ErrorAction Stop
        Disable-ScheduledTask -InputObject $task | Out-Null
        $disabledTask = [string]$definition.windowsTask
      }
      $result = & $pnpmPath --silent --filter '@thriftycrew/operator' tc transition retire ([string]$candidate.job) 2>&1
      if ($LASTEXITCODE -ne 0) { throw "server retirement failed: $($result -join ' ')" }
      $retired += [pscustomobject]@{ job = [string]$candidate.job; windowsTask = $disabledTask; result = (($result -join "`n") | ConvertFrom-Json) }
    } catch {
      if ($disabledTask) { Enable-ScheduledTask -TaskName $disabledTask | Out-Null }
      throw
    }
  }
  [pscustomobject]@{ ok = $true; apply = $true; retired = $retired } | ConvertTo-Json -Depth 20
} finally {
  Pop-Location
}
