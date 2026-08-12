param(
  [string]$Version = '24.18.1',
  [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'ThriftyCrew\runtime')
)
$ErrorActionPreference = 'Stop'
$archiveName = "node-v$Version-win-x64.zip"
$releaseBase = "https://nodejs.org/dist/v$Version"
$installDirectory = Join-Path $InstallRoot "node-v$Version-win-x64"
$nodeExecutable = Join-Path $installDirectory 'node.exe'
function Install-PinnedPnpm {
  $priorPath = $env:Path
  try {
    $env:Path = $installDirectory + [IO.Path]::PathSeparator + $env:Path
    & (Join-Path $installDirectory 'corepack.cmd') enable pnpm
    if ($LASTEXITCODE -ne 0) { throw 'Corepack could not enable the pnpm shim' }
    & (Join-Path $installDirectory 'corepack.cmd') install --global pnpm@11.16.0
    if ($LASTEXITCODE -ne 0) { throw 'Corepack could not install pnpm 11.16.0' }
  } finally { $env:Path = $priorPath }
}
if (Test-Path -LiteralPath $nodeExecutable) {
  $installed = (& $nodeExecutable --version).Trim()
  if ($installed -eq "v$Version") {
    Install-PinnedPnpm
    [pscustomobject]@{ ok = $true; version = $installed; directory = $installDirectory; reused = $true } | ConvertTo-Json -Compress
    exit 0
  }
  throw "unexpected Node binary at $nodeExecutable ($installed)"
}
New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
$temporary = Join-Path ([IO.Path]::GetTempPath()) ("thriftycrew-node-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporary -Force | Out-Null
try {
  $archive = Join-Path $temporary $archiveName
  $checksums = Join-Path $temporary 'SHASUMS256.txt'
  Invoke-WebRequest -Uri "$releaseBase/$archiveName" -OutFile $archive -UseBasicParsing
  Invoke-WebRequest -Uri "$releaseBase/SHASUMS256.txt" -OutFile $checksums -UseBasicParsing
  $expectedLine = Get-Content -LiteralPath $checksums | Where-Object { $_ -match ("\s" + [regex]::Escape($archiveName) + '$') } | Select-Object -First 1
  if (-not $expectedLine) { throw "official checksum does not list $archiveName" }
  $expected = ($expectedLine -split '\s+')[0].ToLowerInvariant()
  $actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actual -ne $expected) { throw "Node archive checksum mismatch (expected $expected, got $actual)" }
  Expand-Archive -LiteralPath $archive -DestinationPath $InstallRoot
  $installed = (& $nodeExecutable --version).Trim()
  if ($installed -ne "v$Version") { throw "installed Node runtime reports $installed instead of v$Version" }
  Install-PinnedPnpm
  [pscustomobject]@{ ok = $true; version = $installed; directory = $installDirectory; sha256 = $actual; reused = $false } | ConvertTo-Json -Compress
} finally {
  Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
}
