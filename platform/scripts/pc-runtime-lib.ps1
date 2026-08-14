$ErrorActionPreference = 'Stop'

function Read-PcUtf8Json([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { throw "JSON file is missing: $Path" }
  return ([IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json)
}

function Get-PcRuntimePath {
  return (Join-Path $env:LOCALAPPDATA 'ThriftyCrew\grocery-v3\pc-platform-runtime.json')
}

function Read-PcRuntimeConfig {
  $path = Get-PcRuntimePath
  if (-not (Test-Path -LiteralPath $path)) { throw "PC platform runtime is not installed: $path" }
  $config = Read-PcUtf8Json $path
  if ([int]$config.version -ne 1) { throw "unsupported PC platform runtime version: $($config.version)" }
  return $config
}

function Unprotect-PcSecret([string]$EncryptedSecret) {
  $secure = ConvertTo-SecureString $EncryptedSecret
  $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
  try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
}

function Set-PcRuntimeCredential($Config, [string]$AgentId) {
  $record = $Config.credentials.PSObject.Properties[$AgentId]
  if (-not $record) { throw "PC runtime credential is missing for $AgentId" }
  $env:TC_LOCAL_MUTATION_SECRET = Unprotect-PcSecret ([string]$record.Value.encryptedSecret)
  $env:TC_AGENT_ID = $AgentId
  $env:TC_API_ORIGIN = [string]$Config.apiOrigin
}

function Initialize-PcRuntimeEnvironment($Config) {
  $paths = @($Config.runtimePath | ForEach-Object { [string]$_ })
  if ($paths.Count -gt 0) { $env:Path = (($paths -join [IO.Path]::PathSeparator) + [IO.Path]::PathSeparator + $env:Path) }
  $env:TC_API_ORIGIN = [string]$Config.apiOrigin
}

function Write-PcRuntimeLog([string]$LogFile, [string]$Message) {
  $directory = Split-Path -Parent $LogFile
  if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
  $line = "[{0}] {1}" -f (Get-Date).ToString('s'), $Message
  for ($attempt = 1; $attempt -le 20; $attempt++) {
    try {
      Add-Content -LiteralPath $LogFile -Value $line -ErrorAction Stop
      return
    } catch [IO.IOException] {
      if ($attempt -eq 20) { return }
      Start-Sleep -Milliseconds 50
    }
  }
}

function Send-PcRuntimeAlert([string]$Subject, [string]$Body) {
  $alertLibrary = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'grocery\alert-lib.ps1'
  if (-not (Test-Path -LiteralPath $alertLibrary)) { return }
  try {
    . $alertLibrary
    Send-Alert -Subject $Subject -Body $Body | Out-Null
  } catch { }
}

function Enter-PcRuntimeLock([string]$Name, [int]$StaleMinutes = 180) {
  $lockRoot = Join-Path $env:LOCALAPPDATA 'ThriftyCrew\grocery-v3\locks'
  New-Item -ItemType Directory -Path $lockRoot -Force | Out-Null
  $lockPath = Join-Path $lockRoot ($Name + '.lock')
  if (Test-Path -LiteralPath $lockPath) {
    $age = ((Get-Date) - (Get-Item -LiteralPath $lockPath).LastWriteTime).TotalMinutes
    if ($age -lt $StaleMinutes) { return $null }
    Remove-Item -LiteralPath $lockPath -Force
  }
  try {
    New-Item -ItemType File -Path $lockPath -Value ((Get-Date).ToUniversalTime().ToString('o')) -ErrorAction Stop | Out-Null
    return $lockPath
  } catch { return $null }
}

function Exit-PcRuntimeLock([string]$LockPath) {
  if ($LockPath -and (Test-Path -LiteralPath $LockPath)) { Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue }
}
