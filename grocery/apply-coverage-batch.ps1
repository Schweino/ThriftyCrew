<#
  apply-coverage-batch.ps1 - add include patterns for a batch of coverage gaps, then GATE them.

  THE PROCEDURE THIS ENFORCES (learned the hard way on 2026-08-01)
  ----------------------------------------------------------------
  Widening a commodity rule looks like a one-line edit and is not. That morning a single added pattern,
  `cheese,\s+shredded`, matched a Hy-Vee FLYER line ("cheese, shredded, bar or cubed, 6 to 8 oz.") and
  collided with that cell's stored product link. The crown-diff said "0 crowns changed" and looked
  perfectly clean; audit-tile-integrity is what caught it. So a crown-diff alone is NOT a sufficient gate.

  Every batch runs, in order:
    1. record the before-state (crowns + per-commodity store coverage)
    2. edit commodities.json, backing it up first
    3. compare-deals
    4. CROWN DIFF          - did any commodity change hands, and was that intended?
    5. COVERAGE DELTA      - did the batch actually ADD cells? A pattern that adds nothing gets reverted:
                             it bought nothing and can only introduce risk.
    6. audit-known-wrong   - no adjudicated-wrong product may re-enter through a widened rule
    7. audit-tile-integrity- the check that caught the cheese collision
    8. guards              - every hard invariant
  Any failure leaves the batch REVERTED and the board untouched.

  Usage:
    .\apply-coverage-batch.ps1 -Patterns @{ 'sun-dried-tomatoes' = @('sun.?dried.{0,30}tomato') }
    .\apply-coverage-batch.ps1 -Patterns $p -WhatIfOnly     measure without keeping
#>
param(
  [Parameter(Mandatory=$true)][hashtable]$Patterns,
  [switch]$WhatIfOnly
)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$OutDir = Join-Path $root 'out'
function Snapshot {
  $f = Get-ChildItem (Join-Path $OutDir 'comparison-*.json') | Where-Object { $_.BaseName -match '^comparison-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending | Select-Object -First 1
  $d = Get-Content $f.FullName -Raw | ConvertFrom-Json
  $h = @{}
  foreach ($r in $d.comparison) { $h[[string]$r.id] = [pscustomobject]@{ store = [string]$r.cheapest_store; price = [double]$r.cheapest_price; cells = @($r.stores).Count } }
  return $h
}

$comFile = Join-Path $root 'commodities.json'
$bak = Join-Path $OutDir ('_commodities-batchbak-' + (Get-Date -Format 'HHmmss') + '.json')
Copy-Item $comFile $bak -Force
$before = Snapshot
Write-Output ("before: {0} commodities on the board" -f $before.Count)

# ---- edit
$coms = Get-Content $comFile -Raw | ConvertFrom-Json
$added = 0
foreach ($id in $Patterns.Keys) {
  $c = @($coms | Where-Object { $_.id -eq $id })[0]
  if (-not $c) { throw "commodity '$id' not found" }
  foreach ($p in @($Patterns[$id])) {
    if (@($c.include) -notcontains $p) { $c.include = @($c.include) + $p; $added++ }
  }
}
($coms | ConvertTo-Json -Depth 12) | Set-Content $comFile -Encoding UTF8
Write-Output ("added {0} include pattern(s) across {1} commodit(y/ies)" -f $added, $Patterns.Keys.Count)

function Revert([string]$why) {
  Copy-Item $bak $comFile -Force
  Write-Output ("REVERTED: $why")
  & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'compare-deals.ps1') *>&1 | Out-Null
  exit 2
}

# ---- recompare
& powershell -ExecutionPolicy Bypass -File (Join-Path $root 'compare-deals.ps1') *>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Revert "compare-deals exited $LASTEXITCODE" }
$after = Snapshot

# ---- gate 1: crown diff
$crownChanges = @()
foreach ($id in $after.Keys) {
  if (-not $before.ContainsKey($id)) { $crownChanges += "NEW ROW $id"; continue }
  $b = $before[$id]; $a = $after[$id]
  if ($b.store -ne $a.store -or [math]::Abs($b.price - $a.price) -gt 0.0001) {
    $crownChanges += ("{0}: {1} @{2:N3} -> {3} @{4:N3}" -f $id, $b.store, $b.price, $a.store, $a.price)
  }
}
Write-Output ("crown changes: {0}" -f $crownChanges.Count)
$crownChanges | ForEach-Object { Write-Output ("    " + $_) }

# ---- gate 2: value delta. A pattern that buys nothing is pure risk - but "nothing" was measured WRONG at
# first. The original rule counted only NEW CELLS, and reverted a batch that had genuinely improved the
# board (2026-08-01: widening chicken-noodle-soup surfaced Great Value at $0.0705 against Campbell's
# $0.075 - a real cheaper product at a store that ALREADY had a cell, so cell count did not move and the
# gate threw it away). Most coverage findings are exactly that shape: a better CANDIDATE at a store that
# is already represented. So a batch earns its keep by adding a cell OR by lowering a real price.
$gained = 0; $lost = 0; $cheaper = 0; $detail = @()
foreach ($id in $Patterns.Keys) {
  $b = if ($before.ContainsKey($id)) { $before[$id].cells } else { 0 }
  $a = if ($after.ContainsKey($id)) { $after[$id].cells } else { 0 }
  $bp = if ($before.ContainsKey($id)) { $before[$id].price } else { 0 }
  $ap = if ($after.ContainsKey($id)) { $after[$id].price } else { 0 }
  $note = ''
  if ($bp -gt 0 -and $ap -gt 0 -and $ap -lt ($bp - 0.0001)) { $cheaper++; $note = ("  CHEAPER {0:N4} -> {1:N4}" -f $bp, $ap) }
  $detail += ("    {0,-24} {1} -> {2} cells{3}" -f $id, $b, $a, $note)
  if ($a -gt $b) { $gained += ($a - $b) } elseif ($a -lt $b) { $lost += ($b - $a) }
}
$detail | ForEach-Object { Write-Output $_ }
Write-Output ("value: +{0} cell(s), -{1} cell(s), {2} commodit(y/ies) got a cheaper real price" -f $gained, $lost, $cheaper)
if ($lost -gt 0) { Revert "the batch REMOVED $lost cell(s); a widening must never cost coverage" }
if ($gained -eq 0 -and $cheaper -eq 0) { Revert 'the batch added ZERO cells AND lowered ZERO prices - it bought nothing and can only add risk' }

if ($WhatIfOnly) { Copy-Item $bak $comFile -Force; & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'compare-deals.ps1') *>&1 | Out-Null; Write-Output 'WhatIfOnly: reverted'; exit 0 }

# ---- gate 3..5: the checks that actually catch collisions
& powershell -ExecutionPolicy Bypass -File (Join-Path $root 'audit-known-wrong.ps1') *>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Revert "audit-known-wrong failed ($LASTEXITCODE) - a widened rule re-admitted an adjudicated-wrong product" }
& powershell -ExecutionPolicy Bypass -File (Join-Path $root 'build-deals-page.ps1') *>&1 | Out-Null
& powershell -ExecutionPolicy Bypass -File (Join-Path $root 'audit-tile-integrity.ps1') *>&1 | Out-Null
$tileRc = $LASTEXITCODE

# A tile fault is not automatically the batch's fault. Two different things produce one:
#   (a) the batch collided a rule onto the wrong product   -> REVERT, this is the cheese lesson
#   (b) the batch found a genuinely CHEAPER product at a store that already had a cell, so the stored
#       link now describes the old product -> that is a link to REPAIR, not a widening to throw away
# and separately (c) today's fresh ads moved unrelated cells, which the batch did not cause at all.
# The first version of this gate could not tell them apart and reverted a good batch on 33 pre-existing
# faults. So: attribute first, repair through the sanctioned headless path, and judge only what remains
# and is actually ours.
if ($tileRc -ne 0) {
  $tf = Join-Path $OutDir 'tile-integrity.json'
  $mine = @(); $theirs = @()
  if (Test-Path $tf) {
    foreach ($rw in @((Get-Content $tf -Raw | ConvertFrom-Json).rows)) {
      if ([string]$rw.fault -eq 'NO-LINK') { continue }
      if ($Patterns.Keys -contains [string]$rw.id) { $mine += $rw } else { $theirs += $rw }
    }
  }
  Write-Output ("tile-integrity failed: {0} hard fault(s) on BATCH commodities, {1} pre-existing elsewhere" -f $mine.Count, $theirs.Count)
  if ($mine.Count -gt 0) {
    # try the sanctioned repair for our own cells before blaming the widening
    Write-Output '  attempting headless link repair on the batch cells...'
    & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'resolve-worklist.ps1') *>&1 | Out-Null
    & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'resolve-ff-boardmatch.ps1') *>&1 | Out-Null
    & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'resolve-hyvee-links.ps1') *>&1 | Out-Null
    & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'merge-product-urls.ps1') *>&1 | Out-Null
    & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'build-deals-page.ps1') *>&1 | Out-Null
    & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'audit-tile-integrity.ps1') *>&1 | Out-Null
    $still = @()
    if (Test-Path $tf) {
      foreach ($rw in @((Get-Content $tf -Raw | ConvertFrom-Json).rows)) {
        if ([string]$rw.fault -ne 'NO-LINK' -and $Patterns.Keys -contains [string]$rw.id) { $still += $rw }
      }
    }
    if ($still.Count -gt 0) {
      $still | ForEach-Object { Write-Output ("    unrepaired: {0} [{1}] {2}" -f $_.id, $_.store, $_.fault) }
      Revert ("audit-tile-integrity: {0} batch commodit(y/ies) still disagree with their tile after repair - this is the cheese collision shape" -f $still.Count)
    }
    Write-Output '  batch cells repaired headlessly; no batch-attributable faults remain'
  }
  if ($theirs.Count -gt 0) {
    # NOT ours: keep the batch, but this board must not ship until the churn is healed separately.
    Write-Output ("  {0} pre-existing fault(s) remain and are NOT from this batch. The batch is KEPT;" -f $theirs.Count)
    Write-Output '  heal them through check-ad-cycles (headless stores) or withdraw-stale-link (the rest) before publishing.'
    Write-Output 'BATCH ACCEPTED, BOARD NOT PUBLISHABLE YET (pre-existing link churn).'
    exit 1
  }
}
& powershell -ExecutionPolicy Bypass -File (Join-Path $root 'guards.ps1') *>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Revert "guards failed ($LASTEXITCODE)" }

Write-Output 'BATCH GREEN: crown-diff reviewed, coverage gained, known-wrong clean, tile-integrity clean, guards clean.'
exit 0
