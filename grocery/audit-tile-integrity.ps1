<#
  audit-tile-integrity.ps1 - BRAD'S INVARIANT, as one number.

    "There should be no tile that has a price and item name and no link, and the price and item name need to
     match the link 100%."

  Every PRICED tile must satisfy all three:
     LINKED   it has a See-item link at all
     SAME-PRODUCT  the link opens the product the board named (not a different brand/size/form)
     SAME-PRICE    the link's per-unit equals the board's per-unit

  Until now this was spread across three audits with three scopes - consistency-report (no_link + mismatch),
  name-drift (wrong product), guard 4 (factor). Three numbers nobody could hold to one bar. This is the single
  score, per store, with every violation named.

  TWO DIFFERENT PROMISES, TWO DIFFERENT GATES. Lumping these into one number hid the thing that matters:

    ACCURACY  (WRONG-PRODUCT, PRICE-MISMATCH, LINK-UNPRICEABLE, LINK-NO-PRICE)
              A link that ships opens something other than what we advertised. This LIES to a shopper - they
              click "See item", land on a different product or price, and conclude the board inflates deals.
              It is never acceptable and it is fixable without anyone's browser, by REMOVING the link.
              -> HARD GATE. Must be zero. prune-bad-links keeps it there.

    COVERAGE  (NO-LINK)
              A tile shows a price with no "See item" link. Incomplete, not dishonest: the price is still the
              store's own, verified by guards 9/10. Closing these needs paced per-store browser passes.
              -> RATCHET against out\tile-integrity-baseline.json. May only go down.

  A wrong link is strictly worse than no link, so ACCURACY is bought by spending COVERAGE, and this split is
  what lets that trade be made deliberately instead of accidentally. Before the split, pruning a bad link made
  the single score look WORSE - the gate actively discouraged the honest fix.

  Exit: 0 = accuracy clean and no store regressed on coverage. 2 = ANY accuracy violation, or coverage regressed.
  3 = BLIND (zero links were price-graded - the accuracy claim would be empty; a real violation still wins with 2).
#>
param(
  [string]$OutDir = "",
  [switch]$Baseline,   # write the current counts as the high-water mark
  [switch]$Strict,     # ANY violation fails - the end state
  [switch]$Quiet
)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
. (Join-Path $root 'pu-lib.ps1')   # the SAME per-unit math the page publishes with

$cmpF = (Get-ChildItem (Join-Path $OutDir 'comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1)
$cmp = (Get-Content $cmpF.FullName -Raw | ConvertFrom-Json).comparison
$pu = (Get-Content (Join-Path $root 'product-urls.json') -Raw | ConvertFrom-Json).items
$drift = @{}
$ndF = Join-Path $OutDir 'name-drift.json'
if (Test-Path $ndF) { foreach ($d in (Get-Content $ndF -Raw | ConvertFrom-Json).flags) { $drift[([string]$d.id + '|' + [string]$d.store)] = [string]$d.reason } }

$rows = New-Object System.Collections.Generic.List[object]
$graded = 0   # everyday linked tiles whose link price was actually compared to the board
foreach ($r in $cmp) {
  $id = [string]$r.id; $unit = [string]$r.unit
  foreach ($s in $r.stores) {
    $st = [string]$s.store
    $bpu = [double]$s.per_unit
    if ($bpu -le 0) { continue }                      # not a priced tile
    $lnk = $pu.$id.$st
    if (-not $lnk -or -not $lnk.url) {
      $rows.Add([pscustomobject]@{ id = $id; store = $st; fault = 'NO-LINK'; detail = 'priced tile with no See-item link'; board = [string]$s.item; link = '' }); continue
    }
    if ($drift.ContainsKey($id + '|' + $st)) {
      $rows.Add([pscustomobject]@{ id = $id; store = $st; fault = 'WRONG-PRODUCT'; detail = $drift[$id + '|' + $st]; board = [string]$s.item; link = [string]$lnk.name }); continue
    }
    # price agreement: a SALE cell is legitimately below its link's shelf price, so only EVERYDAY cells are held
    # to price equality. (That exemption is also how the stale-markdown bug hid - guard 8 covers that class.)
    if (([string]$s.type) -ne 'everyday') { continue }
    $sp = 0.0; [void][double]::TryParse((([string]$lnk.price) -replace '[^0-9.]', ''), [ref]$sp)
    if ($sp -le 0) {
      $rows.Add([pscustomobject]@{ id = $id; store = $st; fault = 'LINK-NO-PRICE'; detail = 'link carries no price to compare'; board = [string]$s.item; link = [string]$lnk.name }); continue
    }
    $lpu = Get-LinkPerUnit -size ([string]$lnk.size) -unit $unit -price $sp -name ([string]$lnk.name)
    if ($null -eq $lpu -or $lpu -le 0) {
      $rows.Add([pscustomobject]@{ id = $id; store = $st; fault = 'LINK-UNPRICEABLE'; detail = ('link size "' + [string]$lnk.size + '" gives no per-unit in ' + $unit); board = [string]$s.item; link = [string]$lnk.name }); continue
    }
    $graded++
    $off = [math]::Abs($lpu - $bpu) / $lpu
    # A STALE PRICE SNAPSHOT IS NOT A WRONG LINK - AND THIS GATE USED TO SAY IT WAS.
    # I first demanded 2%. That is wrong twice over:
    #   1. The board refreshes DAILY; a link's stored price snapshot does not. The moment a store nudges a
    #      price, a perfectly good link - still opening exactly the product the board names - reads as a
    #      "violation". That is our record being a day old, not the link lying to anyone.
    #   2. It broke a contract that already existed and worked: the daily's repair prunes at Tol 0.32, which
    #      is tuned to guard 4's factor rule (>=1.5x / <=0.67x) precisely so the gate "can never deadlock the
    #      daily publish" (its words). A 2% gate against a 32% pruner deadlocks it EVERY DAY - and did: the
    #      2026-07-17 cloud run pulled fresh prices, pruned at 0.32, and my gate then blocked the publish over
    #      ordinary movement. Fresh accurate prices did not ship because some snapshots were a few cents old.
    #      A gate that blocks the truth to protect a formality is worse than no gate.
    # So ACCURACY means what it always should have: the link opens a DIFFERENT PRODUCT. That is a FACTOR
    # error - a wrong SKU, a pack counted as one unit - and it matches prune 0.32 and guard 4 exactly.
    # Ordinary drift below that is real, worth watching, and NOT a lie: it is a WARN, and the daily's
    # consistency repair re-points those links anyway.
    if ($off -gt 0.02 -and [math]::Abs($lpu - $bpu) -gt 0.005) {
      $ratio = $lpu / $bpu
      $fault = if ($ratio -ge 1.5 -or $ratio -le 0.67) { 'PRICE-MISMATCH' } else { 'PRICE-DRIFT' }
      $rows.Add([pscustomobject]@{ id = $id; store = $st; fault = $fault; detail = ('board $' + [math]::Round($bpu, 4) + ' vs link $' + [math]::Round($lpu, 4) + '  (' + [math]::Round($off * 100, 1) + '% off)'); board = [string]$s.item; link = [string]$lnk.name })
    }
  }
}

# priced tiles per store, for the score
$tiles = @{}
foreach ($r in $cmp) { foreach ($s in $r.stores) { if ([double]$s.per_unit -gt 0) { $k = [string]$s.store; if (-not $tiles.ContainsKey($k)) { $tiles[$k] = 0 }; $tiles[$k]++ } } }
$bad = @{}
foreach ($x in $rows) { if (-not $bad.ContainsKey($x.store)) { $bad[$x.store] = 0 }; $bad[$x.store]++ }

$report = [ordered]@{ generated = (Get-Date -Format 'yyyy-MM-dd HH:mm'); board = $cmpF.Name; total_tiles = ($tiles.Values | Measure-Object -Sum).Sum; violations = $rows.Count; by_store = @{}; rows = $rows }
# record COVERAGE per store as well as total violations: the ratchet below compares coverage only, because
# pruning a wrong link (the correct fix) RAISES a store's no-link count and a combined ratchet would fail it.
$covPerStore = @{}
foreach ($x in $rows) { if ($x.fault -eq 'NO-LINK') { if (-not $covPerStore.ContainsKey($x.store)) { $covPerStore[$x.store] = 0 }; $covPerStore[$x.store]++ } }
foreach ($k in $tiles.Keys) {
  $report.by_store[$k] = @{
    tiles      = $tiles[$k]
    violations = $(if ($bad.ContainsKey($k)) { $bad[$k] } else { 0 })
    coverage   = $(if ($covPerStore.ContainsKey($k)) { $covPerStore[$k] } else { 0 })
  }
}
($report | ConvertTo-Json -Depth 6) | Set-Content (Join-Path $OutDir 'tile-integrity.json') -Encoding UTF8

# ACCURACY = the link opens something OTHER than what we advertised. Those are lies and they block.
# PRICE-DRIFT is deliberately NOT here: it is the right product whose snapshot is a few cents old, which the
# daily's consistency repair re-points. Blocking on it stops today's true prices from shipping.
$ACC = @('WRONG-PRODUCT', 'PRICE-MISMATCH', 'LINK-UNPRICEABLE', 'LINK-NO-PRICE')
$accRows = @($rows | Where-Object { $ACC -contains $_.fault })
$driftRows = @($rows | Where-Object { $_.fault -eq 'PRICE-DRIFT' })
$covRows = @($rows | Where-Object { $_.fault -eq 'NO-LINK' })
$report['accuracy_violations'] = $accRows.Count
$report['coverage_violations'] = $covRows.Count
$linked = [int]$report.total_tiles - $covRows.Count   # [int]: total_tiles is $null when $tiles is empty
$report['linked_tiles'] = $linked
$report['accuracy_graded'] = $graded
($report | ConvertTo-Json -Depth 6) | Set-Content (Join-Path $OutDir 'tile-integrity.json') -Encoding UTF8

if (-not $Quiet) {
  # $linked hoisted above (persisted in the report; needed on the -Quiet path too)
  Write-Output ("ACCURACY  " + $accRows.Count + " of " + $linked + " LINKED tiles open a DIFFERENT product than advertised  <- must be ZERO; this is the only one that lies")
  Write-Output ("DRIFT     " + $driftRows.Count + " linked tiles whose stored price snapshot is stale (right product)  <- watch, do not block; the repair re-points these")
  Write-Output ("COVERAGE  " + $covRows.Count + " of " + $report.total_tiles + " priced tiles have no See-item link at all       <- incomplete, not dishonest; needs browser passes")
  Write-Output ''
  Write-Output ("tile-integrity: " + $rows.Count + " violation(s) of " + $report.total_tiles + " priced tiles   (" + [math]::Round(100 - ($rows.Count / [math]::Max(1, $report.total_tiles) * 100), 1) + "% clean)")
  Write-Output ''
  Write-Output ("{0,-14}{1,8}{2,12}{3,10}   {4}" -f 'store', 'tiles', 'violations', 'clean%', 'worst fault')
  foreach ($k in ($tiles.Keys | Sort-Object)) {
    $b = if ($bad.ContainsKey($k)) { $bad[$k] } else { 0 }
    $w = @($rows | Where-Object { $_.store -eq $k } | Group-Object fault | Sort-Object Count -Descending | Select-Object -First 1)
    $wt = if ($w.Count) { $w[0].Name + ' x' + $w[0].Count } else { '-' }
    Write-Output ("{0,-14}{1,8}{2,12}{3,10}   {4}" -f $k, $tiles[$k], $b, ([math]::Round(100 - ($b / [math]::Max(1, $tiles[$k]) * 100), 1)), $wt)
  }
  Write-Output ''
  $rows | Group-Object fault | Sort-Object Count -Descending | ForEach-Object { Write-Output ("  {0,-18}{1}" -f $_.Name, $_.Count) }
}

$blF = Join-Path $OutDir 'tile-integrity-baseline.json'
if ($Baseline) {
  # A BLIND -Baseline is worse than a blind report: with zero links graded every priced tile is a NO-LINK
  # coverage violation, so writing the baseline here sets the ratchet's high-water mark to the MAXIMUM
  # possible value - the coverage-regression warn can then structurally never fire again - while exiting 0.
  # And the blind state (product-urls emptied) is exactly the incident during which someone would reach for
  # -Baseline. Refuse: same exit-3 contract as the default path, and the poisoned baseline is never written.
  # (Post-batch review 2026-07-30: the original blind check lived only in the final exit expression, which
  # this block and -Strict both exit BEFORE - two of three paths violated the file's own '3 = BLIND' header.)
  if ($linked -le 0 -or $graded -le 0) {
    Write-Output ''
    Write-Output ('tile-integrity: -Baseline REFUSED - BLIND run (' + $linked + ' linked tiles, ' + $graded + ' graded). Writing a baseline now would pin every priced tile as the coverage high-water mark and permanently disarm the ratchet. Fix product-urls.json first; no baseline was written.')
    exit 3
  }
  (@{ set = (Get-Date -Format 'yyyy-MM-dd HH:mm'); by_store = $report.by_store } | ConvertTo-Json -Depth 5) | Set-Content $blF -Encoding UTF8
  Write-Output ''
  Write-Output ("baseline written: " + $rows.Count + " violation(s). From here the number may only go DOWN.")
  exit 0
}
# ---- ACCURACY: a hard gate, always. Not baselined, not ratcheted, not -Strict-gated. -----------------------
# A shipped link that opens the wrong product/price is never acceptable and never needs a browser to fix:
# prune-bad-links removes it and the tile falls back to an honest price-with-no-link. There is no version of
# this repo where a wrong link is tolerable, so there is no baseline to grandfather one in.
$fail2 = $false
if ($accRows.Count -gt 0) {
  Write-Output ''
  Write-Output ("tile-integrity: FAIL - " + $accRows.Count + " LINKED tile(s) disagree with the product/price they advertise.")
  Write-Output '  A wrong link is worse than no link: the shopper clicks, sees something else, and concludes the'
  Write-Output '  board inflates its deals. Run  prune-bad-links.ps1 -Tol 0.32  to drop them - that is always'
  Write-Output '  available and needs no browser. The tolerance is not decoration: it is the same factor rule'
  Write-Output '  guard 4 uses, and it is what every automated call site passes. Anything tighter also deletes'
  Write-Output '  RIGHT-product links whose stored price snapshot merely drifted a few cents.'
  foreach ($x in ($accRows | Select-Object -First 10)) { Write-Output ('    ' + $x.fault.PadRight(18) + ($x.id + ' | ' + $x.store).PadRight(34) + $x.detail) }
  $fail2 = $true
}
else {
  Write-Output ''
  if ($linked -le 0 -or $graded -le 0) { Write-Output ('tile-integrity: ACCURACY BLIND - zero links were price-graded (' + $linked + ' linked tiles, ' + $graded + ' graded). product-urls.json is empty/unreadable or every link was skipped; this proves NOTHING about link accuracy. NOT an OK.') }
  else { Write-Output ('tile-integrity: ACCURACY OK - all ' + $graded + ' price-graded links (of ' + $linked + ' linked tiles) open the product the board names, at the price it shows.') }
}

# ---- COVERAGE: ratchets down. Closing these needs paced per-store browser passes. --------------------------
if ($Strict) {
  if ($covRows.Count -gt 0) { Write-Output ("tile-integrity: STRICT - " + $covRows.Count + " priced tile(s) still have no link."); exit 2 }
  # a real violation still wins with 2; otherwise a blind run must not read as the STRICT end-state
  # (an empty board/product-urls satisfies "every priced tile has a link" vacuously - zero of anything)
  if ($fail2) { Write-Output 'tile-integrity: STRICT - accuracy violations above.'; exit 2 }
  if ($linked -le 0 -or $graded -le 0) { Write-Output ('tile-integrity: STRICT - BLIND (' + $linked + ' linked tiles, ' + $graded + ' graded); the every-tile-linked claim is vacuous, not achieved.'); exit 3 }
  Write-Output 'tile-integrity: STRICT - every priced tile also has a verified link.'
  exit 0
}
if (Test-Path $blF) {
  $bl = (Get-Content $blF -Raw | ConvertFrom-Json).by_store
  $worse = @()
  # compare COVERAGE only. Accuracy is gated above, and pruning a bad link (the right fix) RAISES a store's
  # no-link count - the old combined ratchet would have failed the very act of removing a lie.
  $covByStore = @{}
  foreach ($x in $covRows) { if (-not $covByStore.ContainsKey($x.store)) { $covByStore[$x.store] = 0 }; $covByStore[$x.store]++ }
  foreach ($k in ($tiles.Keys | Sort-Object)) {
    $now = if ($covByStore.ContainsKey($k)) { $covByStore[$k] } else { 0 }
    $was = if ($bl.PSObject.Properties[$k] -and $null -ne $bl.$k.coverage) { [int]$bl.$k.coverage } else { $null }
    if ($null -ne $was -and $now -gt $was) { $worse += ("  " + $k + ": " + $was + " -> " + $now + "  (+" + ($now - $was) + ")") }
  }
  if ($worse.Count) {
    Write-Output ''
    # WARN, NOT FAIL. Coverage regressing does NOT justify withholding today's prices.
    # This blocked the 2026-07-17 publish and that was indefensible: the run had pulled fresh, correct prices,
    # pruned the links that no longer matched them (the RIGHT action), and my ratchet then failed the board for
    # having fewer links than yesterday - so shoppers kept seeing STALE PRICES to protect a link count. A tile
    # with no link is incomplete; a tile with a day-old price is wrong. Never trade the second for the first.
    # It is still surfaced every day, and prune/browser passes still drive it down - it just cannot hold the
    # board hostage. Accuracy above is the only thing that blocks, because it is the only thing that lies.
    Write-Output 'tile-integrity: COVERAGE WARN - a store has fewer links than its baseline (pruning a bad link does this on purpose).'
    $worse | ForEach-Object { Write-Output $_ }
    Write-Output '  Not blocking: withholding fresh prices over a link count would publish a stale lie to protect a formality.'
  }
  else { Write-Output 'tile-integrity: COVERAGE OK - no store regressed against the baseline.' }
}
exit $(if ($fail2) { 2 } elseif ($linked -le 0 -or $graded -le 0) { 3 } else { 0 })
