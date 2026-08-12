param(
  [string]$NodeRoot = (Join-Path $env:LOCALAPPDATA 'CodexRuntime\node-v24.16.0-win-x64'),
  [string]$CodexRuntimeRoot = (Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime'),
  [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'
$requiredVersion = [version]'24.16.0'
$expectedNodeSha256 = 'b3094d0b49f9ad602262a9921551737bb97637c05dd357a06ae98188d7290aa3'
$nodeExecutable = Join-Path $NodeRoot 'node.exe'
$overrideRoot = Join-Path $CodexRuntimeRoot 'dependencies\bin\override'
$pnpmModule = Join-Path $CodexRuntimeRoot 'dependencies\node\node_modules\pnpm\bin\pnpm.mjs'
$nodeWrapper = Join-Path $overrideRoot 'node.cmd'
$pnpmWrapper = Join-Path $overrideRoot 'pnpm.cmd'

if (-not (Test-Path -LiteralPath $nodeExecutable -PathType Leaf)) { throw "Verified Node executable is missing: $nodeExecutable" }
if (-not (Test-Path -LiteralPath $pnpmModule -PathType Leaf)) { throw "Codex pnpm module is missing: $pnpmModule" }
$nodeHash = (Get-FileHash -LiteralPath $nodeExecutable -Algorithm SHA256).Hash.ToLowerInvariant()
if ($nodeHash -ne $expectedNodeSha256) { throw "Node executable checksum mismatch: expected $expectedNodeSha256, got $nodeHash" }
$reportedVersion = (& $nodeExecutable --version).TrimStart('v')
if ([version]$reportedVersion -lt $requiredVersion) { throw "Node $requiredVersion or newer is required; found $reportedVersion" }

$nodeBody = "@echo off`r`n`"$nodeExecutable`" %*`r`nexit /b %ERRORLEVEL%`r`n"
$pnpmBody = "@echo off`r`nsetlocal`r`nset `"pnpm_config_pm_on_fail=ignore`"`r`n`"$nodeExecutable`" `"$pnpmModule`" %*`r`nexit /b %ERRORLEVEL%`r`n"

if (-not $CheckOnly) {
  New-Item -ItemType Directory -Force -Path $overrideRoot | Out-Null
  [IO.File]::WriteAllText($nodeWrapper, $nodeBody, [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText($pnpmWrapper, $pnpmBody, [Text.UTF8Encoding]::new($false))
}

foreach ($wrapper in @($nodeWrapper, $pnpmWrapper)) {
  if (-not (Test-Path -LiteralPath $wrapper -PathType Leaf)) { throw "Codex runtime override is missing: $wrapper" }
}
if ((Get-Content -LiteralPath $nodeWrapper -Raw) -ne $nodeBody) { throw 'Codex Node override differs from the verified configuration' }
if ((Get-Content -LiteralPath $pnpmWrapper -Raw) -ne $pnpmBody) { throw 'Codex pnpm override differs from the verified configuration' }
$nodeViaOverride = (& $nodeWrapper --version).TrimStart('v')
$nodeViaPnpm = (& $pnpmWrapper --silent exec node --version).TrimStart('v')
if ([version]$nodeViaOverride -lt $requiredVersion -or [version]$nodeViaPnpm -lt $requiredVersion) {
  throw "Codex override verification failed: node=$nodeViaOverride pnpm-node=$nodeViaPnpm"
}

[pscustomobject]@{
  ok = $true
  checkOnly = [bool]$CheckOnly
  nodeVersion = $nodeViaOverride
  pnpmNodeVersion = $nodeViaPnpm
  nodeSha256 = $nodeHash
  overrideRoot = $overrideRoot
} | ConvertTo-Json
