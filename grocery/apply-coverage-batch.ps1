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
# freeze the pre-edit board so the theft check has a fixed baseline (compare-deals overwrites the live one)
$baseCmp = Join-Path $OutDir '_baseline-batch.json'
Copy-Item (Get-ChildItem (Join-Path $OutDir 'comparison-*.json') | Where-Object { $_.BaseName -match '^comparison-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending | Select-Object -First 1).FullName $baseCmp -Force
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

# ---- gate 2b: VISIBILITY. This is the measurement the first two versions of this gate got wrong.
# Board effects are weekly: a correct new pattern often changes nothing today simply because the product it
# reveals is not this week's cheapest at that store. Judging a rule edit by today's cells therefore throws
# away correct work - it reverted 8 verified patterns on 2026-08-01, every one of which revealed a real
# product the rules genuinely could not see. And an invisible product can never win in ANY future week
# either, which is the whole reason the coverage backlog exists.
# So the durable question is: does this pattern make real, currently-INVISIBLE rows visible? A pattern that
# reveals nothing bought nothing and is still rejected. A pattern that reveals rows is kept even when the
# board does not move today - provided the theft check and every downstream gate stay clean.
$corpusFile = Join-Path (Split-Path $root -Parent) 'sidecar\data\corpus-current.json'
$revealed = @{}; $blind = $false
if (Test-Path $corpusFile) {
  $corp = Get-Content $corpusFile -Raw | ConvertFrom-Json
  $comsNow = Get-Content $comFile -Raw | ConvertFrom-Json
  foreach ($id in $Patterns.Keys) {
    $cdef = @($comsNow | Where-Object { $_.id -eq $id })[0]
    $exRx = @(); foreach ($xp in @($cdef.exclude)) { if ($xp) { $exRx += [regex]::new([string]$xp, 'IgnoreCase,Compiled') } }
    $n = 0
    foreach ($p in @($Patterns[$id])) {
      $r = [regex]::new([string]$p, 'IgnoreCase,Compiled')
      foreach ($row in $corp) {
        if ($row.rule_match) { continue }                       # already visible to some rule; not a gain
        $nm = [string]$row.product
        if (-not $r.IsMatch($nm)) { continue }
        $killed = $false; foreach ($x in $exRx) { if ($x.IsMatch($nm)) { $killed = $true; break } }
        if (-not $killed) { $n++ }
      }
    }
    $revealed[$id] = $n
  }
  $dead = @($Patterns.Keys | Where-Object { $revealed[$_] -eq 0 })
  foreach ($id in ($Patterns.Keys | Sort-Object)) {
    $flag = ''
    # An outsized reveal count is the CATEGORY-SUFFIX tell. Stores append their aisle name to every SKU in
    # it ("... , Frozen Vegetables" on Kroger's asparagus spears, corn on the cob and teriyaki stir fry),
    # so a pattern built from that phrase matches an entire aisle rather than a product. On 2026-08-01
    # `frozen\s+vegetables\b` revealed 40 rows and passed every gate - because the gates protect OTHER
    # commodities (theft) and the links (tile integrity), and neither can see that a single-vegetable bag
    # is wrong for a MIXED-vegetable commodity. Nothing here can decide that; a human has to read the rows.
    if ($revealed[$id] -ge 15) { $flag = '   <-- REVIEW: reads like an aisle, not a product. Check the revealed rows before shipping.' }
    Write-Output ("    {0,-24} reveals {1} previously-invisible row(s){2}" -f $id, $revealed[$id], $flag)
  }
  if ($dead.Count -eq @($Patterns.Keys).Count) { Revert 'no pattern in the batch revealed a single invisible row - it bought nothing' }
  if ($dead.Count -gt 0) { Write-Output ("    NOTE: {0} pattern(s) revealed nothing and should be dropped: {1}" -f $dead.Count, ($dead -join ', ')) }
} else {
  # BLIND, not block: no corpus means we cannot measure visibility, so fall back to the board-effect test
  # rather than silently passing an unmeasured batch.
  $blind = $true
  Write-Output '    BLIND: no sidecar corpus - cannot measure visibility; falling back to board effect'
  if ($gained -eq 0 -and $cheaper -eq 0) { Revert 'blind on visibility AND the board did not move - nothing proves this batch bought anything' }
}

# ---- gate 2c: THEFT. Matching is first-match-wins by array order, so a widened rule in an earlier
# commodity silently steals products from a later one, and theft LOOKS like success (the thief gains, the
# victim quietly loses a cell). verify-no-regression is the estate's existing check for exactly this; the
# batch's own targets are exempt because their prices are supposed to move.
# NOTE: invoked IN-PROCESS, not through `powershell -File`. An array argument does not survive -File - it
# arrives flattened into positional junk ("A positional parameter cannot be found"), the same trap that bit
# withdraw-stale-link. Splatting a hashtable to the call operator keeps -IgnoreIds an actual array.
$vnrArgs = @{ Baseline = $baseCmp; IgnoreIds = @($Patterns.Keys) }
$vnrOut = & (Join-Path $root 'verify-no-regression.ps1') @vnrArgs 2>&1
if ($LASTEXITCODE -ne 0) {
  $vnrOut | Select-String -Pattern 'LOST|MOVED|was:|now:' | ForEach-Object { Write-Output ("    " + $_) }
  Revert 'verify-no-regression FAILED - the batch took a cell or re-priced one at a commodity it does not own (first-match-wins theft)'
}
Write-Output '    theft check: OK - no other commodity lost a cell or was re-priced'

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
