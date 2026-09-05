<#
  stamp-fareway-instore.ps1 - BACKFILL the price-mode contract onto an existing fareway-regular file.

  WHY A BACKFILL AND NOT A REBUILD: build-fareway-regular.ps1 -ModeVerified regenerates the file from the raw
  extracts, which THROWS AWAY healed/carried rows (the 07-15 file is "core re-pulled 07-15 + carried 07-14" -
  382 rows, more than the extracts alone hold). That exact mistake cost Family Fare 26 cells once already.
  On a file that has been healed/corrected, backfill the new fields; never rebuild it from an older source.

  WHY IT EXISTS AT ALL (2026-07-16): I dropped Fareway's ~320 everyday cells off the board on the strength of a
  spot-check that said the file was Instacart DELIVERY pricing, marked up (butter +14%, cream cheese +50%, tuna
  +22%, OJ +37%). Re-checked today against a PROVEN In-Store + Omaha session: 28 of 28 items match the file to
  the cent - butter $3.48, cream cheese $1.99, tuna $0.97, OJ $7.98, all exact. The file was in-store all along.
  The original spot-check was almost certainly taken against the wrong store: a cold shop.fareway.com session
  defaults to "Des Moines - Euclid", not Omaha, which is precisely the trap this script's -Evidence note exists
  to stop the next person walking into.

  THE METHOD IS PROVEN, NOT ASSUMED. Same-origin fetch() DOES carry the storefront's httpOnly fulfilment
  session: the control is Aldi canned tuna, whose in-store price is $0.95 and whose delivery price is $1.05.
  From the In-Store Omaha session, both the rendered page and fetch() returned $0.95. So a fetch that agrees
  with the file is real evidence the file is in-store.

  Only ever stamp what you actually verified, and record HOW in the file itself.
#>
param(
  [string]$File = "",
  [string]$ModeVerified = "",
  [string]$Evidence = "",
  [switch]$WhatIf
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $File) { $f = Get-ChildItem (Join-Path $root 'out\regular\fareway-regular-*.json') | Sort-Object Name -Desc | Select-Object -First 1; $File = $f.FullName }
if (-not $ModeVerified) { throw "-ModeVerified <yyyy-MM-dd> is required. It asserts you PROVED the capture's fulfilment mode; do not pass it otherwise." }
if (-not $Evidence) { throw "-Evidence '<what you checked>' is required. A stamp with no recorded evidence is how the guard got defeated the first time." }

$doc = Read-JsonFile $File
$before = @($doc.deals).Count
if ($before -lt 1) { throw "refusing: $File has no deals" }

$out = [ordered]@{}
foreach ($p in $doc.PSObject.Properties) {
  if ($p.Name -eq 'deals') { continue }
  $out[$p.Name] = $p.Value
}
$out['price_mode'] = 'in-store'
$out['mode_verified'] = $ModeVerified
$out['mode_evidence'] = $Evidence
$out['deals'] = $doc.deals

$after = @($out['deals']).Count
if ($after -ne $before) { throw "refusing: row count changed $before -> $after" }

Write-Output ("stamp-fareway-instore: " + (Split-Path $File -Leaf))
Write-Output ("  price_mode   : " + [string]$doc.price_mode + "  ->  in-store")
Write-Output ("  mode_verified: " + $ModeVerified)
Write-Output ("  rows         : " + $before + " (unchanged)")
if ($WhatIf) { Write-Output '  -WhatIf: nothing written.'; exit 0 }
($out | ConvertTo-Json -Depth 8) | Set-Content $File -Encoding UTF8
Write-Output '  written.'
