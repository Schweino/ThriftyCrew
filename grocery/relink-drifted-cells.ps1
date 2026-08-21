<#
  relink-drifted-cells.ps1 - after a match fix moves a price, point its LINK at the new product.

  THE STEP THAT KEEPS GETTING FORGOTTEN. A price and its link are one fact (see
  derive-links-from-prices.ps1). But they are written by different runs: compare-deals decides which
  product wins a cell, product-urls.json still holds the pin for whatever won it LAST time. So every
  match fix that changes which product a cell holds silently orphans that cell's link, and nobody
  finds out until audit-tile-integrity fails on the next guard pass.

  Measured on 2026-08-21, four times in one day - and each time the remedy was identical:

    cloves          $11.92 -> $2.99   link still opened the McCormick jar
    chocolate milk  $0.0702 -> $0.0312  link still opened the Tru Moo half gallon
    beef-jerky      dog treat removed   link still opened the dog treat
    + a batch of 7 tiles after the learned-alias promotion moved prices across three stores

  The fix was always "derive-links-from-prices -Store <the one that moved> -Apply". That is a
  mechanical consequence of the diff, so it should not depend on the person doing the fix knowing
  to run it.

  WHAT THIS DOES. It needs no before/after snapshot. A drifted cell is self-evident: the board says
  the cell holds product X and product-urls.json says its link opens product Y. It finds those,
  groups them by store, and re-derives ONLY those stores.

  Per store, never globally - derive-links-from-prices carries a scar about that (a global -Apply
  once re-pointed ~40 Fareway links onto pack prices while fixing Sam's). This passes -Store for
  each affected store in turn, which is the same discipline, applied automatically.

  Read-only unless -Apply.

  Exit: 0 = nothing drifted, or drift repaired.  1 = drift found and NOT repaired (read-only run).
#>
param([switch]$Apply, [string]$OutDir = '')
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }

$cmpF = (Get-ChildItem (Join-Path $OutDir 'comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1)
if (-not $cmpF) { Write-Output 'relink: no comparison file; nothing to check'; exit 0 }
$cmp = (Get-Content $cmpF.FullName -Raw | ConvertFrom-Json).comparison
$pu  = (Get-Content (Join-Path $root 'product-urls.json') -Raw | ConvertFrom-Json).items

# Compare on a squashed form. A DERIVED link and its board row come from one capture row and are
# character-identical, but a link resolved by an older browser pass carries the store's own rendering
# of the same product - "Nature's Nectar 100% Apple Juice" against "Nature S Nectar 100 Apple Juice
# 64 FL OZ". Those are the same jug. Treating them as drift would re-derive 150 Aldi links to change
# nothing, which is the churn derive-links-from-prices already refuses on its own.
#
# So the squash removes what the two pipelines legitimately disagree about - case, punctuation,
# pack/size tokens, and the "fresh"/"organic" style adjectives stores add and drop at will - and
# compares what is left. What survives is brand and product identity, which is the thing that must
# not differ. Under-flagging here is safe: audit-name-drift still reads every link independently.
$SIZE = '(?i)\b\d+(?:\.\d+)?\s*(?:fl\s*oz|oz|lb|lbs|ct|ea|pk|pack|count|g|kg|ml|l|qt|gal|liter|litre)s?\b'
function Squash([string]$s) {
  $t = $s.ToLower()
  $t = $t -replace $SIZE, ' '
  $t = $t -replace '\b(?:fresh|organic|natural|premium|value|size|large|small|bulk|each|approx)\b', ' '
  return ($t -replace '[^a-z0-9]', '')
}

$drift = New-Object System.Collections.Generic.List[object]
foreach ($r in $cmp) {
  foreach ($s in $r.stores) {
    if (-not $s.per_unit -or [double]$s.per_unit -le 0) { continue }   # not a priced tile
    $lnk = $pu.($r.id).($s.store)
    if (-not $lnk -or -not $lnk.name) { continue }                     # no link is a COVERAGE issue, not drift
    if ((Squash $s.item) -ne (Squash $lnk.name)) {
      $drift.Add([pscustomobject]@{ id = $r.id; store = [string]$s.store; board = [string]$s.item; link = [string]$lnk.name })
    }
  }
}

if (-not $drift.Count) { Write-Output 'relink: OK - every priced tile links the product it names'; exit 0 }

$byStore = $drift | Group-Object store | Sort-Object Count -Descending
Write-Output ("relink: {0} drifted tile(s) across {1} store(s) - the board moved, the link did not" -f $drift.Count, $byStore.Count)
foreach ($g in $byStore) {
  Write-Output ("  {0,-13} {1} tile(s)" -f $g.Name, $g.Count)
  foreach ($d in ($g.Group | Select-Object -First 4)) {
    Write-Output ("      {0,-26} board='{1}'" -f $d.id, $d.board.Substring(0, [math]::Min(46, $d.board.Length)))
    Write-Output ("      {0,-26} link ='{1}'" -f '', $d.link.Substring(0, [math]::Min(46, $d.link.Length)))
  }
  if ($g.Count -gt 4) { Write-Output ("      ... and {0} more" -f ($g.Count - 4)) }
}

if (-not $Apply) {
  Write-Output ''
  Write-Output 'DRY RUN. Pass -Apply to re-derive these stores, or run them yourself:'
  foreach ($g in $byStore) { Write-Output ("    .\grocery\derive-links-from-prices.ps1 -Store '{0}' -Apply" -f $g.Name) }
  Write-Output 'Then re-run audit-name-drift.ps1 before guards - tile-integrity reads its output and will'
  Write-Output 'otherwise grade these new links against the previous run''s verdicts.'
  exit 1
}

foreach ($g in $byStore) {
  Write-Output ("`n--- re-deriving {0}" -f $g.Name)
  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'derive-links-from-prices.ps1') -Store $g.Name -Apply |
    Select-String -Pattern 'APPLIED|refused at write time|no matching row' | ForEach-Object { Write-Output ('    ' + $_) }
}

# The flags file is an INPUT to tile-integrity, and these links just changed underneath it. Leaving it
# stale would hand the next guard run a verdict about products that no longer sit in those cells -
# which is the failure audit-tile-integrity's own staleness assertion now refuses to run on.
Write-Output "`n--- refreshing name-drift flags (tile-integrity reads them)"
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'audit-name-drift.ps1') | Out-Null
Write-Output 'relink: done. Re-run guards.ps1 to confirm.'
exit 0
