$ErrorActionPreference = 'Stop'
$clientDir = Join-Path $env:LOCALAPPDATA 'ThriftyCrew\grocery-v3'
$configFile = Join-Path $clientDir 'pc-capture-client.json'
if (-not (Test-Path -LiteralPath $configFile)) { throw "PC capture client is not installed: $configFile is missing" }
$config = Get-Content -LiteralPath $configFile -Raw | ConvertFrom-Json
$secure = ConvertTo-SecureString ([string]$config.encryptedSecret)
$pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try { $tcSecret = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }

$env:TC_LOCAL_MUTATION_SECRET = $tcSecret
$env:TC_AGENT_ID = [string]$config.agentId
$env:TC_API_ORIGIN = [string]$config.apiOrigin
$env:TC_CAPTURE_QUEUE = [string]$config.queueRoot
$env:TC_CAPTURE_JOURNAL = Join-Path $clientDir 'capture-journal.sqlite'
$env:TC_PNPM_PATH = [string]$config.pnpmPath
$env:NODE_OPTIONS = (($env:NODE_OPTIONS, '--disable-warning=ExperimentalWarning') -join ' ').Trim()
$runtimePath = @($config.runtimePath | ForEach-Object { [string]$_ })
if ($runtimePath.Count -gt 0) { $env:Path = (($runtimePath -join [IO.Path]::PathSeparator) + [IO.Path]::PathSeparator + $env:Path) }
$nodePath = $runtimePath | ForEach-Object { Join-Path $_ 'node.exe' } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $nodePath) { $nodePath = (Get-Command node -ErrorAction Stop).Source }
$script = Join-Path ([string]$config.platformRoot) 'scripts\browser-capture-controller.mjs'
& $nodePath $script
exit $LASTEXITCODE
