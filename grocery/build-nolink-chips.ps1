<#
  build-nolink-chips.ps1 - DEPRECATED SHIM (2026-07-17). Use build-chips-from-tileintegrity.ps1.

  This script read out\consistency-report.json and only knew Baker's/Aldi/Fareway; the unified auditor
  (audit-tile-integrity.ps1 -> out\tile-integrity.json) sees every store and every fault class, and
  build-chips-from-tileintegrity.ps1 builds the same BLR chip lists from it. Two chip builders reading two
  different reports is how one of them silently goes stale - so this one now just forwards.
#>
$ErrorActionPreference = 'Stop'
Write-Warning 'build-nolink-chips.ps1 is deprecated; forwarding to build-chips-from-tileintegrity.ps1 (reads out\tile-integrity.json, all stores).'
& (Join-Path $PSScriptRoot 'build-chips-from-tileintegrity.ps1') @args
exit $LASTEXITCODE
