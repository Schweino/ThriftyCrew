# audit-capture-eviction.ps1 - catches a cell that got DEARER because a thin capture evicted a rich one.
#
# WHY THIS EXISTS (2026-08-06 Sam's baby-formula finding, measured live):
#   Select-FreshestCaptureRows in compare-deals.ps1 gives a commodity outright to the FRESHEST capture that
#   covers it, and only then takes that capture's cheapest row. That rule exists for a real reason and it
#   works: it stops a 16-day-old hand-promoted file handing Sam's onions a stale-LOW $0.737/lb (the founding
#   bug frozen in compare-deals -SelfTest cases 21-24).
#
#   But "covers it" means ONE MATCHING ROW. Sam's captures are partial term-based pulls, so a capture that
#   happened to sweep one premium product wins the commodity from a capture that swept twenty:
#     sams-deals-2026-08-05.json  1,808 deals, exactly 1 baby-formula row: Bubs Goat Milk, $1.4445/oz
#     sams-deals-2026-07-29.json  2,475 deals, 20+ baby-formula rows incl Member's Mark, $0.7704/oz
#   On 2026-08-06 a rule change admitted the Bubs row to baby-formula for the first time. That single
#   admission made the 08-05 capture "cover" the commodity, the whole 07-29 capture was discarded for it,
#   and the live Sam's cell went 0.7704 -> 1.4445, +87%, with no guard able to see it.
#
#   NOTHING WAS WRONG BY ANY EXISTING TEST. Both rows are real, both prices are real, both arithmetic
#   reproduces, the crown did not move (Walmart $0.74/oz still wins the row), so no price guard, no basis
#   guard and no crown guard has a contradiction to find. The defect is only visible as a COMPARISON
#   between the board cell and a row the ranker discarded before price was ever considered.
#
# THE DISCRIMINATOR IS COVERAGE DEPTH, NOT THE PRICE GAP.
#   A ratio alone cannot separate the two cases, because the founding onions bug is ALSO "the newest capture
#   evicted a cheaper older row" - and there the eviction is correct. What separates them is which capture
#   knows more about the commodity:
#     onions  - the newest capture (07-29) held MORE onion rows than the 07-14 file it displaced. Richer
#               capture wins. Working as designed, must never fire.
#     formula - the newest capture (08-05) held FEWER formula rows than the 07-29 capture it displaced.
#               A capture that covers a commodity less thoroughly than the one it displaces should not be
#               deciding that commodity's price.
#   So this fires only when the winning capture is THINNER for that commodity than the capture it evicted,
#   AND the resulting cell moved by at least -Ratio. Same shape as audit-unit-basis-outlier's pack-shape
#   tell: state the structural fact from the data, do not infer it from arithmetic alone.
#
# ADVISORY BY DESIGN for now, exit 0 on findings. A product genuinely discontinued between two captures
# produces this same shape honestly, and the false-positive rate has not been measured over a full week yet.
# Promote it to a hard gate, or wire it to send-alert, once that number is known - not before, because a
# guard that cries wolf gets ignored and this estate has already paid for that once.
#
#   .\audit-capture-eviction.ps1                    audit the newest candidates-*.json
#   .\audit-capture-eviction.ps1 -Ratio 1.5         only cells that moved 1.5x or more (default 1.25)
#   .\audit-capture-eviction.ps1 -SelfTest          frozen founding-bug fixture + clean twins
# Exit 0 = clean or advisory findings. Exit 2 = self-test regression. Exit 3 = BLIND (cannot see src_date).
param([string]$CandidatesFile = '', [double]$Ratio = 1.25, [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

# THE DETECTOR, pure so the fixture reaches the REAL code path with no data files on disk
# (fix-needs-reachable-selftest: two same-day fixes regressed in this estate because their self-test could
# not reach the new code). Takes the candidates-*.json commodity shape verbatim.
function Find-CaptureEvictions {
  param([object[]]$Commodities, [double]$Ratio = 1.25)
  $out = @()
  foreach ($c in $Commodities) {
    $all = @($c.candidates | Where-Object { $null -ne $_.unit_price -and [double]$_.unit_price -gt 0 })
    if (-not $all.Count) { continue }
    foreach ($sg in ($all | Group-Object store)) {
      $rows = @($sg.Group)
      $dated = @($rows | Where-Object { $_.src_date })
      # No dated row means nothing can be filtered - a single-source store is never touched by the ranker.
      if (-not $dated.Count) { continue }
      $newest = @($dated | ForEach-Object { [string]$_.src_date } | Sort-Object -Descending)[0]
      # Mirror of Select-FreshestCaptureRows: undated rows always survive, dated rows only at the newest date.
      $kept = @($rows | Where-Object { -not $_.src_date -or [string]$_.src_date -eq $newest })
      if (-not $kept.Count) { continue }
      $winner = @($kept | Sort-Object { [double]$_.unit_price })[0]
      $best = @($rows | Sort-Object { [double]$_.unit_price })[0]
      # Nothing cheaper was discarded, so no eviction happened at all.
      if ([double]$best.unit_price -ge [double]$winner.unit_price) { continue }
      # The cheaper row must actually have been filtered on DATE, not lost some other way.
      if (-not $best.src_date -or [string]$best.src_date -eq $newest) { continue }
      $ratioGot = [double]$winner.unit_price / [double]$best.unit_price
      if ($ratioGot -lt $Ratio) { continue }
      # COVERAGE DEPTH: how many rows each capture contributed to THIS commodity at THIS store.
      $newestRows = @($rows | Where-Object { [string]$_.src_date -eq $newest }).Count
      $evictedRows = @($rows | Where-Object { [string]$_.src_date -eq [string]$best.src_date }).Count
      # The winning capture knows at least as much as the one it displaced - this is the ranker working.
      if ($newestRows -ge $evictedRows) { continue }
      $out += [pscustomobject]@{
        id = [string]$c.id; commodity = [string]$c.label; unit = [string]$c.unit; store = [string]$sg.Name
        board_price = [double]$winner.unit_price; board_item = [string]$winner.name; board_src = $newest
        best_price = [double]$best.unit_price; best_item = [string]$best.name; best_src = [string]$best.src_date
        ratio = [math]::Round($ratioGot, 3)
        newest_capture_rows = $newestRows; evicted_capture_rows = $evictedRows
      }
    }
  }
  return $out
}

if ($SelfTest) {
  $bad = 0
  # ---- MUST FIRE: the frozen 2026-08-06 Sam's baby-formula case. Synthetic and FROZEN, never re-read from
  # the board, so a later fix to the board cannot quietly disarm the fixture that proves this guard works.
  $mustFire = @(
    [pscustomobject]@{ id='baby-formula'; label='Baby Formula'; unit='oz'; candidates=@(
      [pscustomobject]@{ store="Sam's Club"; name='Bubs Goat Milk Infant Formula Powder With Iron, 20 oz., 2 pk.'; unit_price=1.4445; src_date='2026-08-05' }
      [pscustomobject]@{ store="Sam's Club"; name="Member's Mark, Advantage Premium, Infant Formula, 48 oz."; unit_price=0.7704; src_date='2026-07-29' }
      [pscustomobject]@{ store="Sam's Club"; name="Member's Mark, Infant Premium, Infant Formula, 48 oz."; unit_price=0.8017; src_date='2026-07-29' }
      [pscustomobject]@{ store="Sam's Club"; name="Member's Mark Advantage Premium Baby Formula Powder with Iron, 36 oz."; unit_price=0.805; src_date='2026-07-29' }
      [pscustomobject]@{ store="Sam's Club"; name="Member's Mark Sensitivity Premium Baby Formula, 48 oz."; unit_price=0.8329; src_date='2026-07-29' }
    )}
  )
  $f1 = @(Find-CaptureEvictions -Commodities $mustFire -Ratio $Ratio)
  if ($f1.Count -ne 1) { Write-Output ("  X MUST-FIRE: baby-formula did not flag (found " + $f1.Count + ")"); $bad++ }
  else {
    if ([math]::Abs($f1[0].ratio - 1.875) -gt 0.01) { Write-Output ("  X MUST-FIRE: wrong ratio, got " + $f1[0].ratio + " want ~1.875"); $bad++ }
    # The DEPTH tell is the assertion that matters. Firing on the price gap alone would also condemn the
    # onions case below, which is the ranker working correctly.
    if (-not ($f1[0].newest_capture_rows -eq 1 -and $f1[0].evicted_capture_rows -eq 4)) {
      Write-Output ("  X MUST-FIRE: missed the coverage-depth tell (newest=" + $f1[0].newest_capture_rows + " evicted=" + $f1[0].evicted_capture_rows + ")"); $bad++
    }
  }
  # ---- CLEAN TWINS: every one of these is an eviction that is CORRECT and must stay silent.
  $clean = @(
    # 1. THE FOUNDING ONIONS BUG (compare-deals -SelfTest 21-24). The 07-14 hand-promotion held a stale-LOW
    #    $0.737; the 07-29 real pull evicted it at $0.8267. The newest capture is RICHER, so the ranker is
    #    doing exactly its job. If this ever fires, this guard is arguing against the bug fix that created it.
    [pscustomobject]@{ id='onions'; label='Onions'; unit='lb'; candidates=@(
      [pscustomobject]@{ store="Sam's Club"; name='Yellow Onions, 10 lbs.'; unit_price=0.737; src_date='2026-07-14' }
      [pscustomobject]@{ store="Sam's Club"; name='Sweet Onions, 6 lbs.'; unit_price=0.8267; src_date='2026-07-29' }
      [pscustomobject]@{ store="Sam's Club"; name='Red Onions, 5 lbs.'; unit_price=0.9100; src_date='2026-07-29' }
      [pscustomobject]@{ store="Sam's Club"; name='Vidalia Onions, 10 lbs.'; unit_price=0.9500; src_date='2026-07-29' }
    )}
    # 2. THIN capture, but the cell barely moved. Below -Ratio is not worth a human's attention.
    [pscustomobject]@{ id='rice'; label='Rice'; unit='lb'; candidates=@(
      [pscustomobject]@{ store="Sam's Club"; name='Jasmine Rice, 25 lb.'; unit_price=1.05; src_date='2026-08-05' }
      [pscustomobject]@{ store="Sam's Club"; name='Long Grain Rice, 25 lb.'; unit_price=1.00; src_date='2026-07-29' }
      [pscustomobject]@{ store="Sam's Club"; name='Basmati Rice, 10 lb.'; unit_price=1.40; src_date='2026-07-29' }
    )}
    # 3. A store with NO capture dates at all (weekly ad / single-source everyday file) is never filtered,
    #    so it can never be evicted. Dating these would filter a whole store's catalogue - see case 23.
    [pscustomobject]@{ id='bread'; label='Bread'; unit='each'; candidates=@(
      [pscustomobject]@{ store="Baker's"; name='Kroger White Bread'; unit_price=2.49; src_date='' }
      [pscustomobject]@{ store="Baker's"; name='Private Selection Sourdough'; unit_price=1.10; src_date='' }
    )}
    # 4. The newest capture is thinner AND cheaper. Nothing was evicted upward, so there is nothing to say.
    [pscustomobject]@{ id='butter'; label='Butter'; unit='lb'; candidates=@(
      [pscustomobject]@{ store="Sam's Club"; name="Member's Mark Butter, 4 lb."; unit_price=2.98; src_date='2026-08-05' }
      [pscustomobject]@{ store="Sam's Club"; name='Land O Lakes Butter, 2 lb.'; unit_price=4.15; src_date='2026-07-29' }
      [pscustomobject]@{ store="Sam's Club"; name='Kerrygold Butter, 1 lb.'; unit_price=6.20; src_date='2026-07-29' }
    )}
    # 5. THE TWIN THAT ACTUALLY TESTS THE DISCRIMINATOR. Case 1 above is the real founding onions data, but
    #    its gap is only 1.12x, so -Ratio suppresses it and the coverage-depth check never gets a vote -
    #    the first draft of this fixture proved nothing, and the probe that removes the depth line still
    #    passed. This is the same shape as the founding bug with a WIDE gap: a stale-LOW $0.80 from a
    #    1-row hand-promotion, evicted by a real 4-row pull at $2.00. Ratio 2.5x, well over threshold, so
    #    the ONLY thing that can keep it silent is "the winning capture knows more". Delete that line and
    #    this twin fires. That is the whole thesis of this guard, under test.
    [pscustomobject]@{ id='pork-shoulder'; label='Pork Shoulder'; unit='lb'; candidates=@(
      [pscustomobject]@{ store="Sam's Club"; name='Pork Shoulder Butt, hand-promoted 07-14'; unit_price=0.80; src_date='2026-07-14' }
      [pscustomobject]@{ store="Sam's Club"; name='Pork Shoulder Boston Butt, Cryovac'; unit_price=2.00; src_date='2026-07-29' }
      [pscustomobject]@{ store="Sam's Club"; name='Pork Shoulder Picnic, whole'; unit_price=2.35; src_date='2026-07-29' }
      [pscustomobject]@{ store="Sam's Club"; name='Pork Shoulder Country Ribs'; unit_price=2.80; src_date='2026-07-29' }
      [pscustomobject]@{ store="Sam's Club"; name='Pork Shoulder Steaks'; unit_price=3.10; src_date='2026-07-29' }
    )}
  )
  $f2 = @(Find-CaptureEvictions -Commodities $clean -Ratio $Ratio)
  if ($f2.Count -ne 0) {
    foreach ($c in $f2) { Write-Output ("  X CLEAN TWIN fired: " + $c.commodity + " / " + $c.store + " at " + $c.ratio + "x") }
    $bad += $f2.Count
  }
  if ($bad -eq 0) { Write-Output 'audit-capture-eviction SELF-TEST PASS (1 must-fire, 5 clean twins)'; exit 0 }
  Write-Output ("audit-capture-eviction SELF-TEST FAIL ($bad)"); exit 2
}

# ---- live run ----
$OutDir = Join-Path $root 'out'
if (-not $CandidatesFile) {
  $cf = Get-ChildItem (Join-Path $OutDir 'candidates-*.json') | Where-Object { $_.BaseName -match '^candidates-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending | Select-Object -First 1
  if (-not $cf) { Write-Output 'BLIND: no candidates-*.json to audit'; exit 3 }
  $CandidatesFile = $cf.FullName
}
$doc = Get-Content $CandidatesFile -Raw | ConvertFrom-Json
$cs = @($doc.commodities)
if (-not $cs.Count) { Write-Output 'BLIND: candidates file has no commodities'; exit 3 }

# BLIND, LOUDLY. compare-deals did not emit src_date into candidates until 2026-08-06. Reading an older
# file would report a confident zero over a corpus that cannot express the defect - the exact failure this
# guard was written about. Say so and exit 3 rather than printing a clean line.
$dated = 0
foreach ($c in $cs) { $dated += @($c.candidates | Where-Object { $_.src_date }).Count }
if ($dated -eq 0) {
  Write-Output ("BLIND: no candidate row in " + (Split-Path $CandidatesFile -Leaf) + " carries src_date.")
  Write-Output '       That file predates the 2026-08-06 compare-deals change that emits it. Rebuild with'
  Write-Output '       compare-deals.ps1 before trusting any result here - a zero from this file is not a clean board.'
  exit 3
}

$findings = @(Find-CaptureEvictions -Commodities $cs -Ratio $Ratio)
$ranked = @($findings | Sort-Object @{e={-$_.ratio}})
Write-Output ("audit-capture-eviction: $($cs.Count) commodities, $dated dated candidate row(s), $($findings.Count) cell(s) evicted upward by a thinner capture at or above $($Ratio)x")
foreach ($f in ($ranked | Select-Object -First 25)) {
  Write-Output ("  [{0,-9}] {1,-26} board {2}/{3} from {4} ({5} row) <- discarded {6} from {7} ({8} rows)  {9}x" -f `
    $f.store, $f.commodity, ('{0:N4}' -f $f.board_price), $f.unit, $f.board_src, $f.newest_capture_rows, `
    ('{0:N4}' -f $f.best_price), $f.best_src, $f.evicted_capture_rows, $f.ratio)
  Write-Output ("              board: {0}" -f $f.board_item)
  Write-Output ("              cheaper discarded: {0}" -f $f.best_item)
}
if ($ranked.Count -gt 25) { Write-Output ("  ... and " + ($ranked.Count - 25) + " more (nothing truncated silently: rerun with -Ratio to widen or narrow)") }
$outFile = Join-Path $OutDir 'capture-evictions.json'
@{ generated = (Get-Date).ToString('s'); candidates_file = (Split-Path $CandidatesFile -Leaf); ratio = $Ratio; findings = $ranked } |
  ConvertTo-Json -Depth 6 | Set-Content $outFile -Encoding UTF8
Write-Output ("  -> $outFile")
exit 0
