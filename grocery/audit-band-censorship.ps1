# audit-band-censorship.ps1 - is the board publishing a DEARER price because the sanity band threw away a
# HOLD SCOPE: cell - names each censored cell (QUARANTINE-CELL ... selection)
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
#   3. its per-unit is CHEAPER than what the board actually publishes for that cell, and
#   4. its per-unit is at least -MedianFloor of the commodity's MEDIAN published per-unit (default 0.4).
#      A floor is a band edge and carries no notion of what a commodity actually costs, so on a commodity
#      whose real prices sit far above its floor a 12x or 16x parse error can land inside the 25% window by
#      arithmetic accident. Two did on 2026-09-07 and between them they held the board. See the long note
#      on Find-BandCensorship for the measurement that chose 0.4.
#   Findings rank by NEARNESS TO THE FLOOR, not by savings. The nearest ones are the likeliest to be real
#   prices. Sorting by savings would put the parse bugs on top, which is backwards: a huge "saving" is the
#   tell for a bad number, and the 1% miss is the one really costing a reader money.
#
#   .\audit-band-censorship.ps1                  audit the newest flagged file against the newest board
#   .\audit-band-censorship.ps1 -NearFloor 0.5   widen to rows down to half the floor (noisier)
#   .\audit-band-censorship.ps1 -MedianFloor 0.3 widen the SCALE test (Find-BandCensorship's own note)
#   .\audit-band-censorship.ps1 -SelfTest        frozen founding-bug fixture + three clean twins
#   .\audit-band-censorship.ps1 -Replay 14       READ-ONLY: replay the last 14 dated boards in -OutDir and
#                                                count, per ratchet version, how often another store moved
#                                                a cell (backlog I216). Writes nothing, not even a baseline.
# Exit 0 = clean or advisory findings. Exit 2 = self-test regression. Exit 3 = BLIND (nothing to judge).
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop (2026-09-07)
param([string]$OutDir = '', [string]$FlaggedFile = '', [string]$CompareFile = '', [double]$NearFloor = 0.75, [double]$MedianFloor = 0.4, [switch]$SelfTest, [int]$Replay = 0, [string]$ReplayRows = '')
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\guard-contract.ps1')
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }

# ONE implementation, driven by the self-test with frozen rows and by the live path with real ones. A guard
# whose self-test exercises a different code path than production is [[fix-needs-reachable-selftest]].
function Find-BandCensorship {
  param([array]$Flagged, [hashtable]$Board, [double]$NearFloor, [double]$MedianFloor = 0.4, [string]$ScaleRef = 'median')
  # A FLOOR IS A BAND EDGE, NOT A SCALE (2026-09-07, queue 2026-09-07-e9edb9). Distance-to-floor was this
  # guard's ONLY discriminator, and a floor carries no information about where a commodity's real prices
  # actually sit. So on a commodity whose prices are far above its floor, a 12x or 16x parse error can land
  # INSIDE the 25% window by arithmetic accident and be reported as a censored bargain. Two did on
  # 2026-09-07 and between them they held the whole board:
  #   coffee | Fareway  | "Scooter's Coffee French Vanilla Ground Coffee" $10.99 size "12 x 12 oz"
  #                       -> 0.0763/oz. A 12 oz bag read as 144 oz (shop.fareway.com case notation).
  #                       76% of the 0.10 floor, so it passed NearFloor - but 15.6% of the 0.4906 median.
  #   sliced-cheese | Hy-Vee | "Di Lusso premium sliced cheese, $9.99 lb." -> 0.0625/oz. A per-POUND price
  #                       read as a 9.99-pound pack: 9.99 / (9.99 x 16) = 1/16 exactly, for any price.
  #                       78% of the 0.08 floor; 31.8% of the 0.1967 median.
  # So the second discriminator is SCALE-AWARE: what the commodity's own published cells actually cost. A
  # real bargain is a few tens of percent under the going rate; a parse error is a different order of
  # magnitude from it. Both tests must pass, so this can only ever REMOVE a finding the floor test admitted
  # and never add one - the founding lettuce row is 75.1% of its (single-cell) median and still fires.
  #
  # MEASURED BEFORE THE THRESHOLD WAS CHOSEN, on today's 73 findings over 3,167 priced cells:
  #   MedianFloor 0.3 -> 69 findings / 39 cells, and the 1/16 deli row (0.318) SURVIVES - it does not clear
  #   MedianFloor 0.4 -> 58 findings / 33 cells, and both parse errors drop out
  # 0.4 also retires 4 arguable-real backlog rows (a 2-pack couscous 0.36, mini muffins 0.383, four 7.2 oz
  # personal pizzas 0.391, a 25 lb pepperoni case 0.395); that trade is an open question for Brad. The
  # UNBLOCK does not depend on it: the deli row is fixed at the parser in compare-deals, and this test is
  # what stops the Fareway case-notation shape (which is left to the band on purpose) from paging.
  $medianOf = @{}
  if ($Board -and $Board.Count) {
    $byCom = @{}
    foreach ($k in @($Board.Keys)) {
      $cid = ([string]$k).Split('|')[0]
      $pv = [double]$Board[$k].per_unit
      if ($pv -le 0) { continue }
      if (-not $byCom.ContainsKey($cid)) { $byCom[$cid] = New-Object System.Collections.ArrayList }
      [void]$byCom[$cid].Add($pv)
    }
    foreach ($cid in @($byCom.Keys)) {
      # ASSIGN THEN WRAP: @(Sort-Object ...) inline on a comma-returned array reads as ONE element.
      $vals = @($byCom[$cid] | Sort-Object)
      $n = $vals.Count
      # a commodity with ONE cell uses that cell, which is the honest answer for a one-store commodity and
      # is what the founding fixture's board is.
      if ($n -eq 0) { continue }
      if ($n % 2 -eq 1) { $medianOf[$cid] = [double]$vals[[int](($n - 1) / 2)] }
      else { $medianOf[$cid] = ([double]$vals[($n / 2) - 1] + [double]$vals[$n / 2]) / 2.0 }
    }
  }
  $out = New-Object System.Collections.ArrayList
  # Script-scoped so the live path can report it after the call. A $script: variable does NOT travel with
  # a lifted function ([[compare-deals-lifters-need-functions-not-variables]]), and nothing lifts this
  # one - it is called in-process by this file and by its own fixtures.
  $script:bcRetired = New-Object System.Collections.ArrayList
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
    # THE SECOND, SCALE-AWARE DISCRIMINATOR - see the long note on this function. BLIND-SAFE: a commodity
    # with no median (it has no priced cell at all) cannot reach here, because the $Board lookup above
    # already required one. A zero median is refused rather than divided by.
    $med = 0.0
    if ($ScaleRef -eq 'cell') { $med = $pu }
    elseif ($medianOf.ContainsKey([string]$r.id)) { $med = [double]$medianOf[[string]$r.id] }
    if ($med -le 0) { continue }
    $medRatio = $up / $med
    if ($medRatio -lt $MedianFloor) {
      # RULED 0.4 BY BRAD, 2026-09-07, AND THE COST OF THAT RULING IS RECORDED RATHER THAN DISCARDED.
      # 0.3 keeps four arguable-real rows (a 2-pack couscous at 0.36 of median, mini muffins 0.383, four
      # 7.2 oz personal pizzas 0.391, a 25 lb pepperoni case 0.395) but does NOT clear the 1/16 deli row
      # at 0.318, so it leaves a known false positive standing in a RATCHET - and a ratchet with a known
      # false positive is one people learn to scroll past, which costs more than four maybes.
      # But "retired by the discriminator" and "never existed" must not look the same. Anything the floor
      # drops is counted and named on every run, so the trade stays visible and reversible: if this list
      # grows, the threshold is wrong and the number itself says so.
      [void]$script:bcRetired.Add([pscustomobject]@{
        commodity = [string]$r.id; store = [string]$r.store; name = [string]$r.name
        rejected = [math]::Round($up, 4); median_price = [math]::Round($med, 4)
        median_ratio = [math]::Round($medRatio, 4); floor = $MedianFloor
      })
      continue
    }
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
      median_price = [math]::Round($med, 4)
      median_ratio = [math]::Round($medRatio, 4)
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

# WHAT THE RATCHET COUNTS, and why it is not simply the finding cells (2026-09-18, backlog I216).
# Tests 1 to 3 of a finding read only the cell's OWN inputs: its refused rows, its band, and its own
# published price. Test 4 divides by the commodity MEDIAN, which every OTHER store's price moves. So a cell
# could leave the findings on nobody's change, the ratchet tightened over it, and the same row re-entered
# when the median moved back and broke the ratchet on nobody's change either. It held the 2026-09-18 08:13
# board: Fareway's Jack's pizza went 4.49 -> 3.33, the frozen-pizza median fell 3.99 -> 3.33, and Totino's
# at 1.4925 crossed 0.4 of it (0.374 -> 0.448) at Aldi, Sam's Club and Walmart, refusing the same rows as on
# 09-11, which had left on 09-13 when Fareway's sale ended. Replayed over the 14 boards to 2026-09-17, the
# median moved 8 cells in or out with their own inputs byte-identical, across 13 transitions.
# The findings are UNCHANGED - Brad ruled the 0.4-of-median test on 2026-09-07 and it still decides what is
# reported. What changes is what the ratchet COUNTS: every finding cell, plus every cell it counted before
# that is still a candidate on its own inputs (tests 1 to 3) but is retired today by the median alone. Such
# a cell is PARKED: it stays counted until its own row stops being a near-floor refusal cheaper than its own
# board price, so another store's price can no longer lower the mark or raise the count. Dividing by the
# cell's own price instead was measured and rejected: on the 2026-09-17 board it dropped three real
# censored cells (Sam's Alani Nu at 0.0768/fl oz, Hy-Vee's fold-close sandwich bags at 0.0086, Sam's Ricos
# queso at 0.0839) and admitted a Walmart tissue row whose own published cell is itself a 16-pack misread.
# RESIDUAL, stated: a candidate the ratchet has NEVER counted can still enter the findings on a median move
# alone and break it once. `-Replay 14` over the boards 2026-08-25..09-17 read 8 outside moves across 13
# transitions counting finding cells, and 3 counting with parking: all 3 first-time entries (canned-pineapple
# at Aldi, pepperoni at Sam's, muffins at Walmart), none a re-entry. Those are dated files, one build per day,
# so the intraday rebuilds that flapped on 09-10 and 09-18 are not in them and both counts are floors.
function Get-RatchetCells([string[]]$FindingCells, [string[]]$CandidateCells, [string[]]$Known) {
  $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  foreach ($c in @($FindingCells)) { if ($c) { [void]$set.Add($c) } }
  $knownSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  foreach ($c in @($Known)) { if ($c) { [void]$knownSet.Add($c) } }
  foreach ($c in @($CandidateCells)) { if ($c -and $knownSet.Contains($c)) { [void]$set.Add($c) } }
  $out = @($set | Sort-Object)
  return ,$out
}

# One call from findings to the counted set, shared by the live path, the self-test and -Replay, so none of
# them can drift into a private copy of the parking rule.
function Get-BandRatchetState([array]$Flagged, [hashtable]$Board, [double]$NearFloor, [double]$MedianFloor, [string[]]$Known, [string]$ScaleRef = 'median') {
  $f = @(Find-BandCensorship -Flagged $Flagged -Board $Board -NearFloor $NearFloor -MedianFloor $MedianFloor -ScaleRef $ScaleRef)
  $fc = @($f | ForEach-Object { $_.commodity + '|' + $_.store } | Sort-Object -Unique)
  $rc = @($script:bcRetired | ForEach-Object { $_.commodity + '|' + $_.store })
  $cc = @(@($fc) + @($rc) | Sort-Object -Unique)
  $countedArr = Get-RatchetCells -FindingCells $fc -CandidateCells $cc -Known $Known
  $counted = @($countedArr)
  return [pscustomobject]@{ findings = $f; finding_cells = $fc; candidate_cells = $cc; counted = $counted
    parked = @($counted | Where-Object { $fc -notcontains $_ }); retired = @($script:bcRetired) }
}

if ($SelfTest) {
  $fail = 0
  $sams = "Sam's Club"
  $board = @{}
  $board['lettuce|' + $sams]      = @{ per_unit = 1.0367; item = 'Romaine Hearts, 6 ct.' }
  $board['toilet-paper|Walmart']  = @{ per_unit = 0.9725; item = 'Great Value Toilet Paper' }
  $board['dryer-sheets|' + $sams] = @{ per_unit = 0.0207; item = 'all Fabric Softener Dryer Sheets' }
  $board['coffee|Fareway']        = @{ per_unit = 0.4184; item = 'Folgers Classic Roast' }
  # THE COFFEE ROW'S REAL PEERS, FROZEN off comparison-2026-09-07 (2026-09-07, queue 2026-09-07-e9edb9).
  # The median discriminator is meaningless against a one-cell commodity, so the fixture has to carry the
  # shape the live board has. These are the seven priced coffee cells that morning; their median is 0.4906,
  # which is the number the case below asserts against. Frozen deliberately: recomputing them from the live
  # board would make the case pass by finding whatever is there.
  $board['coffee|Aldi']           = @{ per_unit = 0.3825; item = 'Beaumont Ground Coffee' }
  $board['coffee|' + $sams]       = @{ per_unit = 0.3940; item = 'Maxwell House Original Roast Medium Ground Coffee, 43.1 oz.' }
  $board['coffee|Walmart']        = @{ per_unit = 0.4906; item = 'Great Value Classic Roast' }
  $board['coffee|Family Fare']    = @{ per_unit = 0.4997; item = 'Folgers Ground Coffee' }
  $board["coffee|Baker's"]        = @{ per_unit = 0.5087; item = 'Kroger Classic Roast' }
  $board['coffee|Hy-Vee']         = @{ per_unit = 0.5262; item = 'Maxwell House Coffee, Ground, Medium, Original Roast' }

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

  # (5b) THE SCALE TEST, and the row that bought it (2026-09-07, queue 2026-09-07-e9edb9). Frozen exactly
  #      as flagged-2026-09-07 recorded it: Fareway's shop feed writes a CASE size, "12 x 12 oz", so a 12 oz
  #      bag was read as 144 oz and $10.99 came out at 0.0763/oz. That is 76.3% of coffee's 0.10 floor, so
  #      it SAILS THROUGH NearFloor - the floor is a band edge and knows nothing about what coffee costs -
  #      but it is 15.6% of the commodity's 0.4906 median. It held the whole board on the ratchet.
  $fxCoffee = @([pscustomobject]@{ id='coffee'; label='Coffee (ground)'; store='Fareway'; unit='oz'; unit_price=0.0763; band='0.10-2.00'; name="Scooter's Coffee French Vanilla Ground Coffee"; price_text='$10.99'; size_text='12 x 12 oz' })
  #      FIXTURE INTEGRITY FIRST, or the silence below proves nothing. With the scale test switched off the
  #      row MUST be reported, with the frozen median and the floor ratio that let it in. Without this, a
  #      case that stopped reaching the guard at all would look exactly like a case the guard correctly
  #      refused - the [[selftest-greps-its-own-source]] shape, one layer up.
  $r = @(Find-BandCensorship -Flagged $fxCoffee -Board $board -NearFloor 0.75 -MedianFloor 0)
  if ($r.Count -eq 1 -and $r[0].median_price -eq 0.4906 -and $r[0].floor_ratio -eq 0.763) {
    Write-Output '  PASS  FIXTURE INTEGRITY: the frozen case-pack row does pass the FLOOR test (76.3% of 0.10) and the commodity median computes to the frozen 0.4906'
  } else { Write-Output ('  FAIL  FIXTURE INTEGRITY: the case-pack row is not reaching the guard as recorded (count ' + $r.Count + ') - the MUST-NOT-FIRE below would be silent for the wrong reason'); $fail++ }
  $r = @(Find-BandCensorship -Flagged $fxCoffee -Board $board -NearFloor 0.75 -MedianFloor 0.4)
  if ($r.Count -eq 0) { Write-Output '  PASS  MUST NOT FIRE: a 12x case-notation parse error at 15.6% of the commodity median is refused, even though it sits inside the 25% floor window' }
  else { Write-Output '  FAIL  MUST NOT FIRE: the Fareway case-pack parse error is being reported as a censored bargain again - this is what blocked the board on 2026-09-07'; $fail++ }

  # (5c) MUST FIRE, RE-ASSERTED UNDER THE NEW TEST. The founding lettuce row is 75.1% of its median (its
  #      board carries one lettuce cell, so the median IS that cell). Case (1) already runs it on the
  #      default MedianFloor; this one names the number, so a threshold moved to 0.8 fails HERE with a
  #      reason rather than silently deleting the founding bug.
  $fx = @([pscustomobject]@{ id='lettuce'; label='Lettuce (head)'; store=$sams; unit='each'; unit_price=0.7783; band='0.8-4.5'; name='Romaine Hearts, 6 ct.'; price_text='$4.67'; size_text='6 ct' })
  $r = @(Find-BandCensorship -Flagged $fx -Board $board -NearFloor 0.75 -MedianFloor 0.4)
  if ($r.Count -eq 1 -and $r[0].median_ratio -eq 0.7507) { Write-Output '  PASS  MUST FIRE under the scale test: the founding lettuce row is 75.1% of its commodity median and still reported' }
  else { Write-Output ('  FAIL  MUST FIRE: the founding lettuce row did not survive the median discriminator (count ' + $r.Count + ') - the guard has stopped seeing its own founding bug'); $fail++ }

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
  # AND AT THE NEW HIGH-WATER MARK. The scale test tightens the baseline from 41 to the low 30s, and the
  # thing that must not happen is a tighter ratchet that has stopped ratcheting. One cell over the NEW
  # baseline is still a hard fail; the numbers are the ones this run is about to record.
  if ((Get-RatchetVerdict -Cells 34 -Baseline 33) -eq 'break') { Write-Output '  PASS  RATCHET at the tightened mark: 34 cells against a baseline of 33 still breaks' }
  else { Write-Output '  FAIL  RATCHET: the tightened baseline no longer breaks on a new censored cell'; $fail++ }

  # (7) ANOTHER STORE'S SALE MUST NOT MOVE THE RATCHET (2026-09-18, backlog I216). Frozen off the boards of
  #     2026-09-11 and 2026-09-13: seven frozen-pizza cells whose median is Fareway's Jack's, 3.33 on sale
  #     and 4.49 off it, and three refused rows that never changed (Totino's 4-count at Walmart 1.4925,
  #     Mama Cozzi's 2-count at Aldi 1.495, Red Baron 9-pack at Sam's 1.4422, all under a 1.5 floor).
  function New-PizzaBoard([double]$fareway) {
    $b = @{}
    $b['frozen-pizza|Walmart'] = @{ per_unit = 2.96; item = "Tony's Pepperoni Pizzeria Style Crust Frozen Pizza, 18.56 oz" }
    $b['frozen-pizza|Hy-Vee'] = @{ per_unit = 2.99; item = "Tony's pizza, 18.56 to 20.6 oz., `$2.99" }
    $b['frozen-pizza|Aldi'] = @{ per_unit = 2.99; item = 'Mama Cozzi Original Thin Crust Cheese Pizza 13.8 OZ' }
    $b['frozen-pizza|Fareway'] = @{ per_unit = $fareway; item = "Jack's Original Thin Supreme Pizza" }
    $b["frozen-pizza|Baker's"] = @{ per_unit = 3.99; item = "Jack's Thin Crust Pepperoni Frozen Pizza" }
    $b['frozen-pizza|Family Fare'] = @{ per_unit = 4.99; item = 'Red Baron Pizza, Pepperoni, Brick Oven Crust 17.89 Oz' }
    $b['frozen-pizza|' + $sams] = @{ per_unit = 5.485; item = "Member's Mark Cauliflower Crust White Pizza" }
    return $b
  }
  $pzRows = @(
    [pscustomobject]@{ id='frozen-pizza'; label='Frozen Pizza'; store='Walmart'; unit='each'; unit_price=1.4925; band='1.5-14'; name="Totino's Party Pizza, Pepperoni, Thin Crust, 40.8 oz, 4 Count (Frozen)"; price_text='$5.97'; size_text='40.8 oz' },
    [pscustomobject]@{ id='frozen-pizza'; label='Frozen Pizza'; store='Aldi'; unit='each'; unit_price=1.495; band='1.5-14'; name="Mama Cozzi's Pizza Kitchen French Bread Pepperoni Pizza, 2 Count"; price_text='$2.99'; size_text='11.25 oz' },
    [pscustomobject]@{ id='frozen-pizza'; label='Frozen Pizza'; store=$sams; unit='each'; unit_price=1.4422; band='1.5-14'; name='Red Baron Pepperoni French Bread Frozen Personal Pizza, 5.40 oz., 9 pk.'; price_text='$12.98'; size_text='9 ct 5.40 oz' }
  )
  $pzSale = New-PizzaBoard 3.33
  $pzFull = New-PizzaBoard 4.49
  $s1 = Get-BandRatchetState -Flagged $pzRows -Board $pzSale -NearFloor 0.75 -MedianFloor 0.4 -Known @()
  $s2old = Get-BandRatchetState -Flagged $pzRows -Board $pzFull -NearFloor 0.75 -MedianFloor 0.4 -Known @()
  #     FIXTURE INTEGRITY: the frozen boards reproduce the incident under the OLD count, which was the finding
  #     cells alone. On sale all three rows are findings; off sale none are; so the old ratchet tightened 3 -> 0
  #     and then broke 3 against 0 when the sale came back, on nobody's change. Without this, the clean twin
  #     below could hold for the boring reason that the rows never reached the median test at all.
  $oldTighten = Get-RatchetVerdict -Cells $s2old.finding_cells.Count -Baseline $s1.finding_cells.Count
  $oldBreak = Get-RatchetVerdict -Cells $s1.finding_cells.Count -Baseline $s2old.finding_cells.Count
  if ($s1.finding_cells.Count -eq 3 -and $s2old.finding_cells.Count -eq 0 -and $s2old.candidate_cells.Count -eq 3 -and $oldTighten -eq 'tighten' -and $oldBreak -eq 'break') {
    Write-Output '  PASS  FIXTURE INTEGRITY: the frozen pizza boards reproduce the flap under a count of finding cells (3 on sale, 0 off it, tighten then break)'
  } else { Write-Output ('  FAIL  FIXTURE INTEGRITY: the frozen pizza boards no longer reproduce the 09-18 flap (sale ' + $s1.finding_cells.Count + ', off ' + $s2old.finding_cells.Count + ', candidates ' + $s2old.candidate_cells.Count + ', ' + $oldTighten + '/' + $oldBreak + ')'); $fail++ }
  #     CLEAN TWIN: counted on sale, the three cells are PARKED when the sale ends (the count holds at 3, no
  #     tighten), and when the sale returns the same rows count 3 again and the ratchet HOLDS.
  $s2 = Get-BandRatchetState -Flagged $pzRows -Board $pzFull -NearFloor 0.75 -MedianFloor 0.4 -Known $s1.counted
  $s3 = Get-BandRatchetState -Flagged $pzRows -Board $pzSale -NearFloor 0.75 -MedianFloor 0.4 -Known $s2.counted
  $v2 = Get-RatchetVerdict -Cells $s2.counted.Count -Baseline $s1.counted.Count
  $v3 = Get-RatchetVerdict -Cells $s3.counted.Count -Baseline $s1.counted.Count
  if ($s2.counted.Count -eq 3 -and $s2.parked.Count -eq 3 -and $v2 -eq 'hold' -and $s3.counted.Count -eq 3 -and $v3 -eq 'hold') {
    Write-Output '  PASS  CLEAN TWIN: Fareway''s pizza going 3.33 -> 4.49 -> 3.33 moves the median across 0.4 twice and the ratchet holds at 3 both times (3 parked, then 3 findings)'
  } else { Write-Output ('  FAIL  CLEAN TWIN: another store''s sale moved the ratchet (off-sale counted ' + $s2.counted.Count + ' parked ' + $s2.parked.Count + ' ' + $v2 + '; back on sale counted ' + $s3.counted.Count + ' ' + $v3 + ')'); $fail++ }
  #     MUST FIRE: a genuinely NEW censored cell on the same off-sale board still raises the count and breaks,
  #     and it is the one named new. Parking must not become a place a regression can hide.
  $boardNew = New-PizzaBoard 4.49
  $boardNew['lettuce|' + $sams] = @{ per_unit = 1.0367; item = 'Romaine Hearts, 6 ct.' }
  $rowsNew = @($pzRows) + @([pscustomobject]@{ id='lettuce'; label='Lettuce (head)'; store=$sams; unit='each'; unit_price=0.7783; band='0.8-4.5'; name='Romaine Hearts, 6 ct.'; price_text='$4.67'; size_text='6 ct' })
  $s4 = Get-BandRatchetState -Flagged $rowsNew -Board $boardNew -NearFloor 0.75 -MedianFloor 0.4 -Known $s2.counted
  $v4 = Get-RatchetVerdict -Cells $s4.counted.Count -Baseline $s1.counted.Count
  $new4 = @($s4.counted | Where-Object { $s2.counted -notcontains $_ })
  if ($v4 -eq 'break' -and $s4.counted.Count -eq 4 -and $new4.Count -eq 1 -and $new4[0] -eq ('lettuce|' + $sams)) {
    Write-Output '  PASS  MUST FIRE: a new censored cell beside three parked ones counts 4 against 3 and breaks, naming lettuce'
  } else { Write-Output ('  FAIL  MUST FIRE: a new censored cell did not break the parked ratchet (counted ' + $s4.counted.Count + ', ' + $v4 + ', new ' + ($new4 -join ',') + ')'); $fail++ }
  #     CLEAN TWIN: parking is not forever. When a parked cell's OWN row goes (Walmart's Totino's leaves the
  #     capture), it stops being a candidate, leaves the count, and the ratchet tightens as it always has.
  $rowsGone = @($pzRows | Where-Object { $_.store -ne 'Walmart' })
  $s5 = Get-BandRatchetState -Flagged $rowsGone -Board $pzFull -NearFloor 0.75 -MedianFloor 0.4 -Known $s2.counted
  $v5 = Get-RatchetVerdict -Cells $s5.counted.Count -Baseline $s1.counted.Count
  if ($v5 -eq 'tighten' -and $s5.counted.Count -eq 2 -and $s5.counted -notcontains 'frozen-pizza|Walmart') {
    Write-Output '  PASS  CLEAN TWIN: a parked cell whose own row is gone leaves the count and the ratchet tightens 3 -> 2'
  } else { Write-Output ('  FAIL  CLEAN TWIN: a resolved parked cell stayed counted (counted ' + $s5.counted.Count + ', ' + $v5 + ')'); $fail++ }

  if ($fail) { Write-Output ("SELF-TEST FAILED ($fail)"); exit 2 }
  Write-Output 'SELF-TEST PASS - founding bug armed (floor AND scale), the case-pack parse error refused, three clean twins, the discrimination case, the ratchet hold, and another store''s sale parked rather than counted'
  exit 0
}

# ---- -Replay: how often does ANOTHER store move a cell? (backlog I216) ------------------------------------
# READ-ONLY by construction: it never reaches the baseline code below and writes only -ReplayRows if given.
# An OUTSIDE MOVE is a cell whose membership of the COUNTED set differs between two consecutive boards while
# its OWN inputs are identical (the same multiset of flagged rows by name, unit_price and band, and the same
# published per-unit), so nothing about the cell itself changed. The ratchet is simulated as the live path
# runs it, with one modelling choice stated: a break is taken as triaged and accepted (mark and set reset to
# that run), because otherwise a single break repeats on every later board and counts the same event again.
function Get-BoardCells($cmp) {
  $b = @{}
  foreach ($r in @($cmp.comparison)) { foreach ($s in @($r.stores)) {
    if ([double]$s.per_unit -le 0) { continue }
    $b[([string]$r.id) + '|' + ([string]$s.store)] = @{ per_unit = [double]$s.per_unit; item = [string]$s.item } } }
  return $b
}
if ($Replay -gt 0) {
  $dates = @(Get-ChildItem (Join-Path $OutDir 'flagged-*.json') -ErrorAction SilentlyContinue |
    Where-Object { $_.BaseName -match '^flagged-\d{4}-\d{2}-\d{2}$' } | ForEach-Object { $_.BaseName.Substring(8) } |
    Where-Object { Test-Path (Join-Path $OutDir ('comparison-' + $_ + '.json')) } | Sort-Object)
  $dates = @($dates | Select-Object -Last $Replay)
  if ($dates.Count -lt 2) { Write-Output ('BLIND: -Replay needs at least 2 dated flagged+comparison pairs in ' + $OutDir + ', found ' + $dates.Count); exit 3 }
  $arms = @('finding-count', 'parked', 'own-cell')
  $sim = @{}
  foreach ($a in $arms) { $sim[$a] = @{ mark = $null; known = @(); prev = $null; outside = 0; ownMoves = 0; breaks = 0; falseBreaks = 0; tightens = 0 } }
  $prevFp = $null; $prevBoard = $null; $rowsOut = New-Object System.Collections.ArrayList
  foreach ($d in $dates) {
    $fl = @((Read-JsonFile (Join-Path $OutDir ('flagged-' + $d + '.json'))).flagged)
    $bd = Get-BoardCells (Read-JsonFile (Join-Path $OutDir ('comparison-' + $d + '.json')))
    $acc = @{}
    foreach ($r in $fl) {
      $k = ([string]$r.id) + '|' + ([string]$r.store)
      if (-not $acc.ContainsKey($k)) { $acc[$k] = New-Object System.Collections.ArrayList }
      [void]$acc[$k].Add(([string]$r.name) + '~' + ([string]$r.unit_price) + '~' + ([string]$r.band))
    }
    $fp = @{}
    foreach ($k in @($acc.Keys)) { $fp[$k] = (@($acc[$k] | Sort-Object) -join '||') }
    $line = $d + ':'
    foreach ($a in $arms) {
      $S = $sim[$a]
      if ($a -eq 'own-cell') { $st = Get-BandRatchetState -Flagged $fl -Board $bd -NearFloor $NearFloor -MedianFloor $MedianFloor -Known @() -ScaleRef 'cell'; $cnt = @($st.finding_cells) }
      elseif ($a -eq 'finding-count') { $st = Get-BandRatchetState -Flagged $fl -Board $bd -NearFloor $NearFloor -MedianFloor $MedianFloor -Known @(); $cnt = @($st.finding_cells) }
      else { $st = Get-BandRatchetState -Flagged $fl -Board $bd -NearFloor $NearFloor -MedianFloor $MedianFloor -Known $S.known; $cnt = @($st.counted) }
      foreach ($c in $cnt) { [void]$rowsOut.Add([pscustomobject]@{ board = $d; arm = $a; cell = $c; finding = (@($st.finding_cells) -contains $c) }) }
      $line += (' {0}={1}' -f $a, $cnt.Count)
      if ($null -ne $S.prev) {
        $newOutside = 0; $newReal = 0
        foreach ($k in (@($S.prev) + @($cnt) | Sort-Object -Unique)) {
          $was = @($S.prev) -contains $k; $is = @($cnt) -contains $k
          if ($was -eq $is) { continue }
          $same = [string]::Equals([string]$prevFp[$k], [string]$fp[$k], [StringComparison]::Ordinal) -and $prevBoard.ContainsKey($k) -and $bd.ContainsKey($k) -and ($prevBoard[$k].per_unit -eq $bd[$k].per_unit)
          if ($same) { $S.outside++; if ($is) { $newOutside++ }; Write-Output ('  [{0}] OUTSIDE MOVE {1}: {2} {3}' -f $a, $d, $k, $(if ($is) { 'entered' } else { 'left' })) }
          else { $S.ownMoves++; if ($is) { $newReal++ } }
        }
        $v = Get-RatchetVerdict -Cells $cnt.Count -Baseline $S.mark
        if ($v -eq 'break') { $S.breaks++; if ($newReal -eq 0) { $S.falseBreaks++ }; Write-Output ('  [{0}] BREAK {1}: {2} over {3} (newly counted: {4} outside, {5} own-input)' -f $a, $d, $cnt.Count, $S.mark, $newOutside, $newReal) }
        if ($v -eq 'tighten') { $S.tightens++ }
      }
      $S.mark = $cnt.Count; $S.known = @($cnt); $S.prev = @($cnt)
    }
    Write-Output $line
    $prevFp = $fp; $prevBoard = $bd
  }
  if ($ReplayRows) { @($rowsOut | ForEach-Object { $_ | ConvertTo-Json -Compress }) | Set-Content $ReplayRows -Encoding UTF8 }
  foreach ($a in $arms) {
    $S = $sim[$a]
    Write-Output ('REPLAY {0}: {1} boards, {2} transitions; {3} outside move(s), {4} own-input move(s); {5} break(s), {6} of them with no own-input cell newly counted; {7} tighten(s)' -f $a, $dates.Count, ($dates.Count - 1), $S.outside, $S.ownMoves, $S.breaks, $S.falseBreaks, $S.tightens)
  }
  Write-Output ('BAND-CENSORSHIP-REPLAY-COMPLETE boards=' + $dates.Count + ' first=' + $dates[0] + ' last=' + $dates[-1])
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
$fdoc = Read-JsonFile $FlaggedFile
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
$cmp = Read-JsonFile $CompareFile
$board = @{}
foreach ($r in @($cmp.comparison)) {
  foreach ($s in @($r.stores)) {
    if ([double]$s.per_unit -le 0) { continue }
    $board[([string]$r.id) + '|' + ([string]$s.store)] = @{ per_unit = [double]$s.per_unit; item = [string]$s.item }
  }
}
if (-not $board.Count) { Write-Output 'BLIND: comparison carries no priced store cells'; exit 3 }

# The ratchet's baseline is read BEFORE the findings, because what it counts depends on the cells it counted
# last time (Get-RatchetCells). Its write side is at the end, after the report.
$blF = Join-Path $OutDir 'band-censorship-baseline.json'
$base = $null
$known = @()
if (Test-Path $blF) {
  try { $bdoc = Read-JsonFile $blF; $base = [int]$bdoc.cells; if ($bdoc.PSObject.Properties['counted_cells']) { $known = @($bdoc.counted_cells | ForEach-Object { [string]$_ }) } } catch { $base = $null; $known = @() }
}
$state = Get-BandRatchetState -Flagged $flagged -Board $board -NearFloor $NearFloor -MedianFloor $MedianFloor -Known $known
$findings = @($state.findings)
$cells =@($findings | ForEach-Object { $_.commodity + '|' + $_.store } | Sort-Object -Unique).Count
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
# WHAT THE MEDIAN FLOOR RETIRED, NAMED. Brad ruled the discriminator at 0.4 on 2026-09-07 knowing it
# drops four arguable-real rows. A trade nobody can see is a trade nobody can revisit, so the rows it
# drops are counted and listed on every run - and the count is the evidence for or against 0.4.
$retired = @($state.retired)
Write-Output ("  median floor {0}: {1} further rejected row(s) were retired as a different ORDER of magnitude from the going rate (a parse error, not censorship)" -f $MedianFloor, $retired.Count)
foreach ($rr in ($retired | Sort-Object -Property median_ratio -Descending | Select-Object -Last 200 | Sort-Object -Property median_ratio -Descending | Select-Object -First 12)) {
  Write-Output ("    retired  {0,-22} {1,-12} {2} at {3} of a {4} median" -f $rr.commodity, $rr.store, $rr.rejected, $rr.median_ratio, $rr.median_price)
}
if ($retired.Count -gt 12) { Write-Output ("    ... and " + ($retired.Count - 12) + " more retired (nothing is dropped silently)") }
$outFile = Join-Path $OutDir 'band-censorship.json'
@{ generated = (Get-Date).ToString('s'); flagged_file = (Split-Path $FlaggedFile -Leaf); compare_file = (Split-Path $CompareFile -Leaf); near_floor = $NearFloor; median_floor = $MedianFloor; cells = $cells; findings = $findings } |
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
# THE COUNTED SET, not the finding cells (backlog I216, Get-RatchetCells). A cell the median alone retired
# today stays counted while its own row is still a candidate, so another store's sale cannot move the mark.
$counted = @($state.counted)
$parked = @($state.parked)
$nCounted = $counted.Count
Write-Output ("  ratchet counts $nCounted cell(s): $cells finding cell(s) + $($parked.Count) parked (counted before, still a candidate on its own row, retired today by the median alone)")
foreach ($pc in $parked) { Write-Output ("    parked   $pc") }
function Write-BandBaseline([int]$N, [string[]]$Set) {
  @{ generated = (Get-Date).ToString('s'); cells = $N; counted_cells = @($Set); note = 'High-water mark for the band-censorship ratchet. This number may only go DOWN. A run above it is a NEW censored cell and hard-fails. counted_cells is the set behind the number: a cell in it stays counted while its own row is still a near-floor refusal, even when another store moves the commodity median (backlog I216).' } |
    ConvertTo-Json -Depth 3 | Set-Content $blF -Encoding UTF8
}
$verdict = Get-RatchetVerdict -Cells $nCounted -Baseline $base
if ($verdict -eq 'first') {
  # A BLIND run must never write the baseline: pinning a high-water mark from a run that saw nothing would
  # permanently disarm the ratchet, which is exactly how tile-integrity's -Baseline refusal came to exist.
  # Every BLIND path above exits 3 before reaching here, so arriving with a real board is the precondition.
  Write-BandBaseline -N $nCounted -Set $counted
  Write-Output ("  baseline written: $nCounted cell(s). From here the number may only go DOWN.")
  $base = $nCounted
}
if ($verdict -eq 'break') {
  $newCells = @($counted | Where-Object { $known -notcontains $_ })
  Write-Output ("band-censorship: RATCHET BROKEN - $nCounted cell(s) now, baseline $base. A cell that was not being censored yesterday is being censored today, which is a live regression rather than the known backlog.")
  if ($known.Count) { foreach ($nc in $newCells) { Write-Output ("    new      $nc") } }
  # THE QUARANTINE PROTOCOL (2026-09-21, grocery\cell-quarantine-lib.ps1 Get-TcChildQuarantineScope). The regression
  # is exactly the cells the baseline did not know, so this names each one for guards.ps1 to quarantine, and
  # affirms the list is complete. With no recorded set there is nothing to name: no scope line, and guards holds
  # the whole board as it always did. 'selection' because censorship condemns the ROW CHOSEN, not the number shown.
  if ($known.Count -and $newCells.Count) {
    foreach ($nc in $newCells) { Write-Output ('QUARANTINE-CELL ' + $nc + '|selection') }
    Write-Output ('QUARANTINE-SCOPE complete cells=' + $newCells.Count + ' stores=0')
  }
  Exit-Guard -Name 'band-censorship' -Summary ("$nCounted cell(s) over a baseline of $base") -Code 2
}
if ($verdict -eq 'tighten') {
  Write-BandBaseline -N $nCounted -Set $counted
  Write-Output ("  ratchet tightened: $nCounted cell(s), was $base. New baseline written.")
}
if ($verdict -eq 'hold' -and -not [string]::Equals((@($known) -join ','), ($counted -join ','), [StringComparison]::Ordinal)) {
  # Same count, different cells (or a baseline written before the set existed): record WHICH cells, so a
  # cell counted today can be parked tomorrow. The number itself does not move.
  Write-BandBaseline -N $base -Set $counted
  Write-Output ("  counted set recorded at the same mark of $base.")
}
Write-Output ("band-censorship: $nCounted cell(s) against a baseline of $base - the known backlog, not a regression. Work it from $outFile (ranked: nearest the floor is likeliest to be a real price).")
Exit-Guard -Name 'band-censorship' -Summary ("$($findings.Count) finding(s) across $cells cell(s), $nCounted counted, baseline $base") -Code 0
