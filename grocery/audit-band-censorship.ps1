# audit-band-censorship.ps1 - is the board publishing a DEARER price because the sanity band threw away a
# cheaper one that was almost certainly real?
#
# WHY THIS EXISTS (2026-09-05, found while working queue 521f1c's supersession residue).
#   The board published lettuce at Sam's Club for $1.0367/each, sourced from a capture dated 2026-07-17.
#   The SAME product, "Romaine Hearts, 6 ct.", was captured on 2026-09-01 at $4.67 - four days before the
#   board was built, and cheaper. It never reached the ranking:
#       2026-09-01  $4.67 / 6 = 0.7783   OUT-OF-BAND   (lettuce band_min = 0.80)
#       2026-08-05  $4.72 / 6 = 0.7867   OUT-OF-BAND
#       2026-07-29  $4.86 / 6 = 0.8100   priced
#       2026-07-17  $6.22 / 6 = 1.0367   priced   <- PUBLISHED
#   Two current, correctly parsed prices were discarded for missing the floor by 2.7% and 1.7%, and the
#   engine fell back 46 days to a dearer row that happens to sit inside the band. On a board whose entire
#   promise is the cheapest price in Omaha, that is the worst direction to fail in: we threw away the
#   bargain and published the stale higher number.
#
# THE ROOT CAUSE IT WATCHES. A price below a commodity's band floor is one of two completely different
#   things, and the band cannot tell them apart because a floor is a single scalar with no notion of
#   magnitude:
#       a PARSE ERROR     - almost always off by an order of magnitude. Measured on the 2026-09-02 board:
#                           214 of 385 below-floor-and-cheaper rows sat under 10% of their floor, e.g.
#                           toilet paper at $0.0009/roll (a per-SHEET division) and ramen at $0.0001.
#                           The band is RIGHT to refuse these and this guard must stay silent on them.
#       a REAL PRICE DROP - a few percent below. dryer-sheets rejected at 0.0199 against a floor of 0.0200
#                           is 0.5% out. No parse error produces a 0.5% miss.
#   The band treats both identically: drop the row, fall back to an older in-band row, publish that.
#
# WHY NO EXISTING GUARD COULD SEE IT, WHICH IS THE PART THAT MATTERS.
#   Every outcome guard in this estate is phrased as "does the published board match the ENGINE'S OWN
#   eligibility rule". audit-capture-eviction says so in its own header: eligible = undated rows + newest
#   capture + a deeper older capture. That shape catches an implementation bug (board disagrees with rule)
#   and is STRUCTURALLY INCAPABLE of catching a rule bug (rule disagrees with reality), because a row the
#   rule discarded is outside the comparison set by construction. A band rejection is exactly that: the
#   engine nulls the price and stamps basis OUT-OF-BAND before ranking ever happens, so the row is invisible
#   to every downstream check. flagged-*.json has recorded every one of these rejections, with the engine's
#   own computed unit price, on every run for months, and nothing has ever read it against the board.
#   See [[guard-audits-own-output]] - that class applied to the guard LAYER rather than to one guard.
#
# SO THIS GUARD IS DELIBERATELY NOT A CONFORMANCE CHECK. It reads what the engine THREW AWAY and asks
#   whether the board is TRUE, not whether the board is consistent with the rule that produced it. That
#   independence is the whole value; do not "simplify" it by sourcing its candidate set from the ranking.
#
# WHAT IT REPORTS. A row is a finding when ALL of these hold:
#   1. it was rejected for falling BELOW the band floor (not above the cap),
#   2. its per-unit is at least -NearFloor of the floor (default 0.75, i.e. within 25% of it), so an
#      order-of-magnitude parse error is excluded by construction, and
#   3. its per-unit is CHEAPER than what the board actually publishes for that cell.
#   Findings rank by NEARNESS TO THE FLOOR, not by savings. The nearest ones are the likeliest to be real
#   prices. Sorting by savings would put the parse bugs on top, which is backwards: a huge "saving" is the
#   tell for a bad number, and the 1% miss is the one really costing a reader money.
#
#   .\audit-band-censorship.ps1                  audit the newest flagged file against the newest board
#   .\audit-band-censorship.ps1 -NearFloor 0.5   widen to rows down to half the floor (noisier)
#   .\audit-band-censorship.ps1 -SelfTest        frozen founding-bug fixture + three clean twins
# Exit 0 = clean or advisory findings. Exit 2 = self-test regression. Exit 3 = BLIND (nothing to judge).
param([string]$OutDir = '', [string]$FlaggedFile = '', [string]$CompareFile = '', [double]$NearFloor = 0.75, [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\guard-contract.ps1')
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }

# ONE implementation, driven by the self-test with frozen rows and by the live path with real ones. A guard
# whose self-test exercises a different code path than production is [[fix-needs-reachable-selftest]].
function Find-BandCensorship {
  param([array]$Flagged, [hashtable]$Board, [double]$NearFloor)
  $out = New-Object System.Collections.ArrayList
  foreach ($r in @($Flagged)) {
    $band = [string]$r.band
    # Only a MIN-MAX band can express "below the floor". The other shape flagged writes is "floor>=0.005",
    # which is Test-Floor's universal dropped-decimal check - a different mechanism with its own finding,
    # and one that is right to be absolute. Skip it rather than guessing a floor out of it.
    $m = [regex]::Match($band, '^([0-9.]+)-([0-9.]+)$')
    if (-not $m.Success) { continue }
    $bmin = [double]$m.Groups[1].Value
    if ($bmin -le 0) { continue }
    if ($null -eq $r.unit_price) { continue }
    $up = [double]$r.unit_price
    if ($up -le 0) { continue }
    if ($up -ge $bmin) { continue }                       # rejected by the CAP, not the floor - not ours
    $ratio = $up / $bmin
    if ($ratio -lt $NearFloor) { continue }               # order-of-magnitude miss: a parse bug, band is right
    $key = ([string]$r.id) + '|' + ([string]$r.store)
    if (-not $Board.ContainsKey($key)) { continue }       # no published cell to be wrong about
    $pu = [double]$Board[$key].per_unit
    if ($pu -le 0) { continue }
    if ($up -ge $pu) { continue }                         # rejected row is DEARER than we publish: costs nobody
    [void]$out.Add([pscustomobject]@{
      commodity   = [string]$r.id
      label       = [string]$r.label
      store       = [string]$r.store
      unit        = [string]$r.unit
      board_price = [math]::Round($pu, 4)
      board_item  = [string]$Board[$key].item
      rejected    = [math]::Round($up, 4)
      band_min    = $bmin
      floor_ratio = [math]::Round($ratio, 4)
      save_pct    = [math]::Round((($pu - $up) / $pu) * 100, 1)
      name        = [string]$r.name
      price_text  = [string]$r.price_text
      size_text   = [string]$r.size_text
    })
  }
  return @($out | Sort-Object @{e={ -$_.floor_ratio }})
}

# The ratchet decision, as a function, so the self-test drives the SAME code the live path does. Written
# this way after the first version buried it in the live path where nothing could reach it - the
# [[fix-needs-reachable-selftest]] trap, in a guard whose whole subject is checks that cannot see.
#   'break'   more censored cells than the baseline: a NEW one, a live regression, hard fail
#   'tighten' fewer: the backlog is being worked, lower the high-water mark
#   'hold'    equal: the known backlog, not a regression
function Get-RatchetVerdict([int]$Cells, $Baseline) {
  if ($null -eq $Baseline) { return 'first' }
  if ($Cells -gt [int]$Baseline) { return 'break' }
  if ($Cells -lt [int]$Baseline) { return 'tighten' }
  return 'hold'
}

if ($SelfTest) {
  $fail = 0
  $sams = "Sam's Club"
  $board = @{}
  $board['lettuce|' + $sams]      = @{ per_unit = 1.0367; item = 'Romaine Hearts, 6 ct.' }
  $board['toilet-paper|Walmart']  = @{ per_unit = 0.9725; item = 'Great Value Toilet Paper' }
  $board['dryer-sheets|' + $sams] = @{ per_unit = 0.0207; item = 'all Fabric Softener Dryer Sheets' }
  $board['coffee|Fareway']        = @{ per_unit = 0.4184; item = 'Folgers Classic Roast' }

  # (1) MUST FIRE - the founding bug, frozen. Romaine hearts captured 2026-09-01 at 0.7783 against a floor
  #     of 0.80 while the board publishes a 46-day-old 1.0367. 2.7% below the floor is not a parse error.
  $fx = @([pscustomobject]@{ id='lettuce'; label='Lettuce (head)'; store=$sams; unit='each'; unit_price=0.7783; band='0.8-4.5'; name='Romaine Hearts, 6 ct.'; price_text='$4.67'; size_text='6 ct' })
  $r = @(Find-BandCensorship -Flagged $fx -Board $board -NearFloor 0.75)
  if ($r.Count -eq 1 -and $r[0].commodity -eq 'lettuce' -and $r[0].rejected -eq 0.7783 -and $r[0].save_pct -gt 24) {
    Write-Output '  PASS  MUST FIRE: the frozen lettuce row (0.7783 against a 0.80 floor, board 1.0367) is reported'
  } else { Write-Output ('  FAIL  MUST FIRE: the founding lettuce row was not reported (got ' + $r.Count + ')'); $fail++ }

  # (2) CLEAN TWIN - a real parse bug. Toilet paper divided per SHEET instead of per roll lands at 0.0009,
  #     0.3% of its floor. The band is RIGHT to refuse it and this guard must stay silent, or it becomes a
  #     second copy of the band with none of its judgement.
  $fx = @([pscustomobject]@{ id='toilet-paper'; label='Toilet Paper'; store='Walmart'; unit='roll'; unit_price=0.0009; band='0.3-2'; name='Scott 1000 1-Ply Toilet Paper, 12 Rolls'; price_text='$10.88'; size_text='1000 sheets' })
  $r = @(Find-BandCensorship -Flagged $fx -Board $board -NearFloor 0.75)
  if ($r.Count -eq 0) { Write-Output '  PASS  CLEAN TWIN: an order-of-magnitude parse error (0.3% of floor) stays silent - the band is right about that one' }
  else { Write-Output '  FAIL  CLEAN TWIN: a per-sheet parse bug was reported as a censored bargain - NearFloor is not being applied'; $fail++ }

  # (3) CLEAN TWIN - a below-floor rejection DEARER than the published cell. Real, but it costs no reader
  #     anything, and reporting it would bury the ones that do.
  $fx = @([pscustomobject]@{ id='coffee'; label='Coffee'; store='Fareway'; unit='oz'; unit_price=0.44; band='0.5-3'; name='Some Coffee'; price_text='$8.80'; size_text='20 oz' })
  $r = @(Find-BandCensorship -Flagged $fx -Board $board -NearFloor 0.75)
  if ($r.Count -eq 0) { Write-Output '  PASS  CLEAN TWIN: a near-floor rejection DEARER than the published cell stays silent' }
  else { Write-Output '  FAIL  CLEAN TWIN: a rejection dearer than the board was reported'; $fail++ }

  # (4) CLEAN TWIN - rejected by the CAP, not the floor. A different defect with a different fix; if this
  #     fires, the guard has stopped reading which end of the band was missed.
  $fx = @([pscustomobject]@{ id='dryer-sheets'; label='Dryer Sheets'; store=$sams; unit='each'; unit_price=9.99; band='0.02-1'; name='Overpriced Sheets'; price_text='$99.90'; size_text='10 ct' })
  $r = @(Find-BandCensorship -Flagged $fx -Board $board -NearFloor 0.75)
  if ($r.Count -eq 0) { Write-Output '  PASS  CLEAN TWIN: a row rejected by the band CAP is not read as a censored bargain' }
  else { Write-Output '  FAIL  CLEAN TWIN: an above-cap rejection was reported as below-floor'; $fail++ }

  # (5) THE DISCRIMINATION ITSELF, in one case: same cell, one row just under the floor and one far under
  #     it. Exactly one must be reported. This is precisely what the sanity band cannot express, so if this
  #     case ever goes to 0 or 2 the guard has collapsed back into being a copy of the band.
  $fx = @(
    [pscustomobject]@{ id='dryer-sheets'; label='Dryer Sheets'; store=$sams; unit='each'; unit_price=0.0199; band='0.02-1'; name='all Fabric Softener Dryer Sheets'; price_text='$5.97'; size_text='300 ct' },
    [pscustomobject]@{ id='dryer-sheets'; label='Dryer Sheets'; store=$sams; unit='each'; unit_price=0.0002; band='0.02-1'; name='Bad Parse Sheets'; price_text='$5.97'; size_text='30000 ct' }
  )
  $r = @(Find-BandCensorship -Flagged $fx -Board $board -NearFloor 0.75)
  if ($r.Count -eq 1 -and $r[0].rejected -eq 0.0199) { Write-Output '  PASS  DISCRIMINATION: of two below-floor rows on one cell, only the 0.5%-under one is reported' }
  else { Write-Output ('  FAIL  DISCRIMINATION: expected exactly the near-floor row, got ' + $r.Count); $fail++ }

  # (6) THE RATCHET. This guard shipped for about an hour exiting 0 with 50 real findings, which made
  #     guards.ps1 print "ok  no cell publishes a dearer price..." while fifty cells did exactly that. A
  #     finding indistinguishable from a pass is the advisory-report failure this estate has already paid
  #     for (audit-pack-basis named the Pledge row correctly and the board published the wrong number
  #     anyway). These four cases are what stops it going back.
  if ((Get-RatchetVerdict -Cells 51 -Baseline 50) -eq 'break') { Write-Output '  PASS  RATCHET MUST FIRE: one MORE censored cell than the baseline is a regression, not backlog' }
  else { Write-Output '  FAIL  RATCHET: a new censored cell did not break the ratchet - the guard is advisory again'; $fail++ }
  if ((Get-RatchetVerdict -Cells 50 -Baseline 50) -eq 'hold') { Write-Output '  PASS  RATCHET CLEAN TWIN: the known backlog at exactly the baseline holds, it does not block a publish' }
  else { Write-Output '  FAIL  RATCHET: the known backlog blocks, which is the gate that gets switched off'; $fail++ }
  if ((Get-RatchetVerdict -Cells 49 -Baseline 50) -eq 'tighten') { Write-Output '  PASS  RATCHET: working the backlog down tightens the high-water mark automatically' }
  else { Write-Output '  FAIL  RATCHET: the baseline does not tighten, so a fixed cell could silently regress later'; $fail++ }
  if ((Get-RatchetVerdict -Cells 50 -Baseline $null) -eq 'first') { Write-Output '  PASS  RATCHET: a first run with no baseline writes one rather than reading a missing file as zero' }
  else { Write-Output '  FAIL  RATCHET: a missing baseline is not handled as a first run'; $fail++ }

  if ($fail) { Write-Output ("SELF-TEST FAILED ($fail)"); exit 2 }
  Write-Output 'SELF-TEST PASS - founding bug armed, three clean twins, the discrimination case and the ratchet hold'
  exit 0
}

# ---- live path ----
if (-not $FlaggedFile) {
  $ff = Get-ChildItem (Join-Path $OutDir 'flagged-*.json') -ErrorAction SilentlyContinue |
        Where-Object { $_.BaseName -match '^flagged-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending | Select-Object -First 1
  if (-not $ff) { Write-Output 'BLIND: no flagged-*.json to audit - the engine has not recorded its band rejections'; exit 3 }
  $FlaggedFile = $ff.FullName
}
if (-not $CompareFile) {
  $mf = Get-ChildItem (Join-Path $OutDir 'comparison-*.json') -ErrorAction SilentlyContinue |
        Where-Object { $_.BaseName -match '^comparison-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending | Select-Object -First 1
  if (-not $mf) { Write-Output 'BLIND: no comparison-*.json to audit'; exit 3 }
  $CompareFile = $mf.FullName
}
$fdoc = Get-Content $FlaggedFile -Raw | ConvertFrom-Json
$flagged = @($fdoc.flagged)
if (-not $flagged.Count) { Write-Output ('BLIND: ' + (Split-Path $FlaggedFile -Leaf) + ' carries no flagged rows'); exit 3 }
# BLIND, LOUDLY. Without a min-max band on at least one row there is no floor to be below, and a confident
# zero here would be indistinguishable from a run that could not express the defect at all.
$banded = @($flagged | Where-Object { [string]$_.band -match '^[0-9.]+-[0-9.]+$' }).Count
if ($banded -eq 0) {
  Write-Output ('BLIND: no row in ' + (Split-Path $FlaggedFile -Leaf) + ' carries a min-max band.')
  Write-Output '       Every rejection recorded is a universal-floor drop, so nothing here can express a'
  Write-Output '       band-floor censorship. A zero from this file is not a clean board.'
  exit 3
}
$cmp = Get-Content $CompareFile -Raw | ConvertFrom-Json
$board = @{}
foreach ($r in @($cmp.comparison)) {
  foreach ($s in @($r.stores)) {
    if ([double]$s.per_unit -le 0) { continue }
    $board[([string]$r.id) + '|' + ([string]$s.store)] = @{ per_unit = [double]$s.per_unit; item = [string]$s.item }
  }
}
if (-not $board.Count) { Write-Output 'BLIND: comparison carries no priced store cells'; exit 3 }

$findings = @(Find-BandCensorship -Flagged $flagged -Board $board -NearFloor $NearFloor)
$cells = @($findings | ForEach-Object { $_.commodity + '|' + $_.store } | Sort-Object -Unique).Count
$pct = [int]((1 - $NearFloor) * 100)
Write-Output ("audit-band-censorship: $($board.Count) published cell(s), $banded banded rejection(s) in " + (Split-Path $FlaggedFile -Leaf) + "; $($findings.Count) rejected row(s) across $cells cell(s) sat within $pct% of the floor AND cheaper than what the board publishes")
foreach ($f in ($findings | Select-Object -First 25)) {
  Write-Output ("  [{0,-11}] {1,-24} board {2}/{3}  refused {4} ({5}% of the {6} floor, {7}% cheaper)" -f `
    $f.store, $f.commodity, ('{0:N4}' -f $f.board_price), $f.unit, ('{0:N4}' -f $f.rejected), `
    [int]($f.floor_ratio * 100), $f.band_min, $f.save_pct)
  Write-Output ("                board:   {0}" -f $f.board_item)
  Write-Output ("                refused: {0}  [{1} {2}]" -f $f.name, $f.price_text, $f.size_text)
}
if ($findings.Count -gt 25) { Write-Output ("  ... and " + ($findings.Count - 25) + " more (nothing truncated silently: rerun with -NearFloor to widen or narrow)") }
$outFile = Join-Path $OutDir 'band-censorship.json'
@{ generated = (Get-Date).ToString('s'); flagged_file = (Split-Path $FlaggedFile -Leaf); compare_file = (Split-Path $CompareFile -Leaf); near_floor = $NearFloor; cells = $cells; findings = $findings } |
  ConvertTo-Json -Depth 6 | Set-Content $outFile -Encoding UTF8
Write-Output ("  -> $outFile")

# ---- THE RATCHET (2026-09-05, same shape as audit-tile-integrity) ---------------------------------------
# THIS GUARD SHIPPED WIRED WRONG FOR ABOUT AN HOUR AND THE FIX IS THE INTERESTING PART. It exited 0 with 50
# real findings, so guards.ps1 printed "ok  no cell publishes a dearer price because the band refused a
# near-floor row that was cheaper" - asserting the invariant HOLDS while fifty cells violated it. That is
# the advisory-report failure this estate has already paid for twice: audit-pack-basis named the Sam's
# Pledge row correctly at 09:03 and the board published the wrong number anyway, because nothing in the
# publish path reads a paragraph. A guard whose findings are indistinguishable from a pass is not a guard.
# Blocking outright is the other bad answer: 50 cells is a backlog, and a gate that fails from day one is a
# gate that gets switched off (audit-tile-integrity says the same thing in its own header).
# So it is a RATCHET. The baseline is the cell count at the moment the class was found; the number may only
# go DOWN. Today's 50 do not block. The 51st does, because a NEW censored cell is a live regression, and as
# the backlog is ruled the baseline tightens itself with no one remembering to tighten it.
$blF = Join-Path $OutDir 'band-censorship-baseline.json'
$base = $null
if (Test-Path $blF) { try { $base = [int]((Get-Content $blF -Raw | ConvertFrom-Json).cells) } catch { $base = $null } }
$verdict = Get-RatchetVerdict -Cells $cells -Baseline $base
if ($verdict -eq 'first') {
  # A BLIND run must never write the baseline: pinning a high-water mark from a run that saw nothing would
  # permanently disarm the ratchet, which is exactly how tile-integrity's -Baseline refusal came to exist.
  # Every BLIND path above exits 3 before reaching here, so arriving with a real board is the precondition.
  @{ generated = (Get-Date).ToString('s'); cells = $cells; note = 'High-water mark for the band-censorship ratchet, set when the class was found on 2026-09-05. This number may only go DOWN. A run above it is a NEW censored cell and hard-fails.' } |
    ConvertTo-Json -Depth 3 | Set-Content $blF -Encoding UTF8
  Write-Output ("  baseline written: $cells cell(s). From here the number may only go DOWN.")
  $base = $cells
}
if ($verdict -eq 'break') {
  Write-Output ("band-censorship: RATCHET BROKEN - $cells cell(s) now, baseline $base. A cell that was not being censored yesterday is being censored today, which is a live regression rather than the known backlog.")
  Write-GuardComplete -Name 'band-censorship' -Summary ("$cells cell(s) over a baseline of $base")
  exit 2
}
if ($verdict -eq 'tighten') {
  @{ generated = (Get-Date).ToString('s'); cells = $cells; note = 'High-water mark for the band-censorship ratchet. This number may only go DOWN. A run above it is a NEW censored cell and hard-fails.' } |
    ConvertTo-Json -Depth 3 | Set-Content $blF -Encoding UTF8
  Write-Output ("  ratchet tightened: $cells cell(s), was $base. New baseline written.")
}
Write-Output ("band-censorship: $cells cell(s) against a baseline of $base - the known backlog, not a regression. Work it from $outFile (ranked: nearest the floor is likeliest to be a real price).")
Write-GuardComplete -Name 'band-censorship' -Summary ("$($findings.Count) finding(s) across $cells cell(s), baseline $base")
exit 0
