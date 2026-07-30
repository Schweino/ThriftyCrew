
<#
  import-aldi-batch.ps1 - SHIM. Aldi is an Instacart storefront, and this file was a fork of
  import-instacart-batch.ps1 with a weaker CleanName and no GoodName check. Measured 2026-07-30 on the real
  capture (out\staples500\aldi-batch1-raw.txt): the two produced the SAME 12 rows and differed on exactly one
  NAME - this file cleaned a bare "each (estimated)each (est.)" prefix that the generic one did not. That one
  arm now lives in import-instacart-batch's CleanName, and with it the two are identical on
  item|size|ad_price|source_ad for all 12 rows. Two copies of one store's ingest is the pu-lib trap; there is
  one copy now, and this file exists only so the documented command keeps working.
  The 9 Aldi rows this fork wrote (aldi-regular-2026-07-{15,18,29}.json) feed 4 live board cells, 2 of them
  crowned - it is NOT dead code, which is why it is converted rather than archived.
  Usage: .\import-aldi-batch.ps1 -ModeVerified 2026-07-30 ; then compare-deals -> diff-board -> vet.
#>
param([string]$Raw = 'out\staples500\aldi-batch1-raw.txt', [string]$ModeVerified = "", [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$fwd = @('-Store', 'Aldi', '-Raw', $Raw, '-SourceLabel', 'Aldi OLA 42 Omaha In-Store shelf price (batch capture)')
if ($ModeVerified) { $fwd += @('-ModeVerified', $ModeVerified) }
if ($SelfTest) { $fwd += '-SelfTest' }
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'import-instacart-batch.ps1') @fwd
exit $LASTEXITCODE
