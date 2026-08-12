$ErrorActionPreference = 'Stop'
$platformRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Push-Location $platformRoot
try {
  & pnpm exec wrangler r2 bucket lifecycle set tc-grocery-v3-evidence --file config/r2-lifecycle/evidence.json --force
  if ($LASTEXITCODE -ne 0) { throw 'failed to apply evidence lifecycle' }
  & pnpm exec wrangler r2 bucket lifecycle set tc-grocery-v3-backups --file config/r2-lifecycle/backups.json --force
  if ($LASTEXITCODE -ne 0) { throw 'failed to apply primary backup lifecycle' }
  & pnpm exec wrangler r2 bucket lifecycle set tc-grocery-v3-backups-secondary --file config/r2-lifecycle/backups-secondary.json --force
  if ($LASTEXITCODE -ne 0) { throw 'failed to apply secondary backup lifecycle' }
  & pnpm exec wrangler r2 bucket lifecycle set tc-grocery-v3-archive --file config/r2-lifecycle/archive.json --force
  if ($LASTEXITCODE -ne 0) { throw 'failed to apply immutable lake lifecycle' }
} finally { Pop-Location }
