<#
  withdraw-stale-link.ps1 - remove a stored product URL that no longer describes the cell it is attached to.

  WHEN THIS IS THE RIGHT TOOL
  ---------------------------
  A board cell changes product (a rule widens and a cheaper real product wins, or a store reprices) while
  product-urls.json still points at the old one. audit-tile-integrity correctly hard-fails: a "See item"
  link that opens a different product at a different price is the misleading-link class Brad set a zero
  tolerance for. Two ways out:

    * the store has a HEADLESS RESOLVER (Family Fare, Hy-Vee) -> re-point it, no data is lost
    * the store does NOT (Walmart, Baker's, Aldi, Fareway, Sam's) -> WITHDRAW the link here

  Withdrawing is not a loss. SeeLink's fallback chain still gives the chip a store-search link, so Brad's
  every-price-has-a-link rule holds, and resolve-worklist.ps1 derives its worklist FROM cells that lack an
  exact URL - so a withdrawn link re-enters the resolve queue automatically on the next pass. That is why
  this needs no separate to-do file: an earlier attempt to hand-log one wrote it where nothing reads
  (2026-08-01), which is the memory-the-pipeline-cannot-read mistake.

  Usage:  .\withdraw-stale-link.ps1 -Pairs @(@('caesar-dressing',"Baker's"), @('chicken-noodle-soup','Walmart'))
#>
param([Parameter(Mandatory=$true)][array]$Pairs, [string]$Reason = 'board cell moved to a different product; stored link no longer describes it')
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$puFile = Join-Path $root 'product-urls.json'
$bak = Join-Path $root 'out' | Join-Path -ChildPath ('_product-urls-bak-' + (Get-Date -Format 'HHmmss') + '.json')
Copy-Item $puFile $bak -Force
$pu = Get-Content $puFile -Raw | ConvertFrom-Json
$n = 0
foreach ($pair in $Pairs) {
  $id = [string]$pair[0]; $store = [string]$pair[1]
  $item = $pu.items.$id
  if (-not $item) { Write-Output ("  no product-urls entry for '$id' - nothing to withdraw"); continue }
  if (-not ($item.PSObject.Properties.Name -contains $store)) { Write-Output ("  '$id' has no '$store' link - nothing to withdraw"); continue }
  $old = $item.$store
  $item.PSObject.Properties.Remove($store)
  $n++
  Write-Output ("  withdrew {0,-24} [{1}]  was: {2}" -f $id, $store, ([string]$old.name))
}
if ($n -gt 0) {
  ($pu | ConvertTo-Json -Depth 12) | Set-Content $puFile -Encoding UTF8
  Write-Output ("withdrew $n link(s). Reason: $Reason")
  Write-Output 'These cells now fall back to a store-search link and will re-enter resolve-worklist automatically.'
} else {
  Write-Output 'nothing withdrawn'
}
exit 0
