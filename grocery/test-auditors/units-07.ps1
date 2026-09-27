# ---- THE BUDGETED LANE (min_ratio), 2026-08-22 ------------------------------------------------------
# CLEAN TWIN 5 - THE ONE THIS RAIL EXISTS FOR. pull-regular-hyvee asks about a rotating slice of ~18
# products a day; on a median day only 3 of them carry a link. Full coverage of that slice is a HEALTHY
# day and must be silent. Against the old fixed baseline (1,010, measured when the lane re-verified
# everything daily) the identical run was REGRESSED every single morning - a permanent finding nobody
# could act on, which is the surest way to teach people to ignore the whole ledger.
if (Use-Unit 'u104-the-budgeted-lane-min-ratio-2026-08') {
$h = $covHealthy.Clone(); $h['pull-regular-hyvee'] = @(2, 2); CovLedger $h
$r = RunPSAt $fxCov 'audit-coverage-ledger.ps1' @('-OutDir', (Join-Path $fxCov 'out'), '-Phase', 'all')
if ($r.rc -eq 0) { Ok 'coverage-ledger is SILENT on a budgeted lane that fully covered its (small) daily slice' }
else { Bad ('a budgeted lane at 100% of today''s slice was reported as a finding (rc=' + $r.rc + '): ' + $r.text + ' - this is the every-morning cry-wolf the ratio rail replaced') }
# MUST FIRE 8 - the throttle, which is the whole reason this puller is on the ledger. Allowed to ask about
# 18, answered for 4: the wall clock bit, or GraphQL stopped answering. A fixed floor cannot see this at all
# (4 clears any floor a 0-18 population could carry); the ratio sees it immediately.
$h = $covHealthy.Clone(); $h['pull-regular-hyvee'] = @(18, 4); CovLedger $h
$r = RunPSAt $fxCov 'audit-coverage-ledger.ps1' @('-OutDir', (Join-Path $fxCov 'out'), '-Phase', 'all')
if ($r.rc -eq 1 -and $r.text -match 'SHORTFALL' -and $r.text -match 'pull-regular-hyvee') { Ok 'coverage-ledger FIRES when a budgeted lane examines 4 of the 18 rows it was allowed to examine' }
else { Bad ('a budgeted lane got answers for 4 of 18 and nothing said so (rc=' + $r.rc + '): ' + $r.text) }
# CLEAN TWIN 7 - SMALL-N: one unanswered product on a 3-product slice is 33%, and firing on it would put
# this rail back in cry-wolf territory about one morning in seventeen (measured no-offer rate ~2% of asked
# products). A dead product id is not a throttle. It is a NOTE, so a slow bleed is still visible.
$h = $covHealthy.Clone(); $h['pull-regular-hyvee'] = @(3, 2); CovLedger $h
$r = RunPSAt $fxCov 'audit-coverage-ledger.ps1' @('-OutDir', (Join-Path $fxCov 'out'), '-Phase', 'all')
if ($r.rc -eq 0 -and $r.text -match 'SMALL SLICE') { Ok 'one unanswered product on a tiny slice is a note, not a SHORTFALL (a percentage is the wrong instrument at n=3)' }
else { Bad ('a single dead product id turned the ledger red on a 3-product slice (rc=' + $r.rc + '): ' + $r.text) }
# ...but TWO of three missing is a third of the day's work and must still be reported.
$h = $covHealthy.Clone(); $h['pull-regular-hyvee'] = @(3, 1); CovLedger $h
$r = RunPSAt $fxCov 'audit-coverage-ledger.ps1' @('-OutDir', (Join-Path $fxCov 'out'), '-Phase', 'all')
if ($r.rc -eq 1 -and $r.text -match 'SHORTFALL') { Ok 'the one-row grace is exactly one row - 1 of 3 is still a SHORTFALL' }
else { Bad ('the small-n grace swallowed a 2-of-3 loss (rc=' + $r.rc + ') - it must not become a blanket exemption') }
# MUST FIRE 9 - and reverting the denominator to the whole catalogue does not go QUIET, it goes SHORTFALL:
# 18 answered of 535 linked products is 3%, which is what the old wiring recorded every day.
$h = $covHealthy.Clone(); $h['pull-regular-hyvee'] = @(535, 18); CovLedger $h
$r = RunPSAt $fxCov 'audit-coverage-ledger.ps1' @('-OutDir', (Join-Path $fxCov 'out'), '-Phase', 'all')
if ($r.rc -eq 1 -and $r.text -match 'SHORTFALL') { Ok 'coverage-ledger still fires if the whole-catalogue denominator comes back (18 of 535 is not a day''s work)' }
else { Bad ('the pre-2026-08-22 denominator passed silently (rc=' + $r.rc + ') - the ratio rail must not become a way to hide a real collapse') }
# MUST FIRE 10 - asked and got nothing back. BLIND is untouched by the ratio rail and is the verdict that
# matters most for a budgeted lane: a dead endpoint looks exactly like a quiet day if nobody checks.
$h = $covHealthy.Clone(); $h['pull-regular-hyvee'] = @(5, 0); CovLedger $h
$r = RunPSAt $fxCov 'audit-coverage-ledger.ps1' @('-OutDir', (Join-Path $fxCov 'out'), '-Phase', 'all')
if ($r.rc -eq 1 -and $r.text -match 'BLIND' -and $r.text -match 'pull-regular-hyvee') { Ok 'coverage-ledger still calls a budgeted lane that asked and got NOTHING back BLIND' }
else { Bad ('a budgeted lane answered for 0 of 5 and was not called blind (rc=' + $r.rc + '): ' + $r.text) }
# MUST FIRE 11 - a slice holding no linkable product at all. Measured: 6% of 18-wide windows in the live
# rotation (5 of 87 simulated days). Eligible 0 is TRUE - the lane verified no price that day - and INERT
# is the verdict, deliberately: it is the no-discovery-path problem (1,064 of 1,554 rows carry no link) in
# the only form anyone can act on. Do not silence it by zero-filling the denominator.
$h = $covHealthy.Clone(); $h['pull-regular-hyvee'] = @(0, 0); CovLedger $h
$r = RunPSAt $fxCov 'audit-coverage-ledger.ps1' @('-OutDir', (Join-Path $fxCov 'out'), '-Phase', 'all')
if ($r.rc -eq 1 -and $r.text -match 'INERT' -and $r.text -match 'pull-regular-hyvee') { Ok 'a day whose slice held no linkable product is INERT, not a silent pass' }
else { Bad ('a lane that examined nothing at all reported clean (rc=' + $r.rc + '): ' + $r.text) }
# CLEAN TWIN 6 - a tolerance of 1.0 on a ratio-judged row is NOT a dead ratchet: min_ratio is its ratchet
# and it fires (MUST FIRE 8 above). Reporting it would be the cry-wolf DEAD-RATCHET was written to prevent.
$h = $covHealthy.Clone(); CovLedger $h
$r = RunPSAt $fxCov 'audit-coverage-ledger.ps1' @('-OutDir', (Join-Path $fxCov 'out'), '-Phase', 'all')
if ($r.rc -eq 0 -and $r.text -notmatch 'DEAD-RATCHET') { Ok 'a ratio-judged row is not reported as a dead ratchet (min_ratio IS its ratchet)' }
else { Bad ('a row judged by min_ratio was flagged DEAD-RATCHET (rc=' + $r.rc + '): ' + $r.text) }

# CLEAN TWIN 4 - brand-new instrumentation must never turn the board red on the day it lands.
$h = $covHealthy.Clone(); $h['audit-something-new'] = @(5, 5); CovLedger $h
$r = RunPSAt $fxCov 'audit-coverage-ledger.ps1' @('-OutDir', (Join-Path $fxCov 'out'), '-Phase', 'all')
if ($r.rc -eq 0 -and $r.text -match 'UNBASELINED') { Ok 'coverage-ledger reports an unbaselined new check as a note, never a finding' }
else { Bad ('a brand-new instrumented check turned the ledger red (rc=' + $r.rc + ')') }
# MUST FIRE 7 - a row that stopped being written. Same failure as (3) for a check that used to report.
$h = $covHealthy.Clone(); $h['guards/4-factor'] = @(2435, 2435, ((Get-Date).AddDays(-9).ToString('yyyy-MM-dd') + ' 09:00:00')); CovLedger $h
$r = RunPSAt $fxCov 'audit-coverage-ledger.ps1' @('-OutDir', (Join-Path $fxCov 'out'), '-Phase', 'all')
if ($r.rc -eq 1 -and $r.text -match 'STALE') { Ok 'coverage-ledger FIRES on a check that stopped recording 9 days ago' }
else { Bad ('coverage-ledger accepted a 9-day-old coverage row as current (rc=' + $r.rc + ')') }

# -Accept AND THE RATIO ROW, LAST because -Accept rewrites the fixture baseline. A budgeted lane's absolute
# count must NOT ratchet: a dense day (18 of 18 linkable) would pin a floor that a median day (3) can never
# clear, re-arming the every-morning finding the ratio rail replaced. min_ratio must survive the round trip
# too, or the first -Accept quietly demotes the row back to the fixed floor.
$h = $covHealthy.Clone(); $h['pull-regular-hyvee'] = @(18, 18); CovLedger $h
$r = RunPSAt $fxCov 'audit-coverage-ledger.ps1' @('-OutDir', (Join-Path $fxCov 'out'), '-Phase', 'all', '-Accept')
$covAfter = $null
try { $covAfter = ((Read-TextFile (Join-Path $fxCov 'coverage-baseline.json')) + '').Trim() | ConvertFrom-Json } catch { }
if ($covAfter -and [int]$covAfter.checks.'pull-regular-hyvee'.examined -eq 3 -and ([double]$covAfter.checks.'pull-regular-hyvee'.min_ratio -eq 0.9) -and $r.text -match 'PINNED') {
  Ok '-Accept keeps a budgeted lane pinned (examined 3, min_ratio 0.9) instead of ratcheting it to a dense day'
} else {
  Bad ('-Accept re-armed the fixed floor on a ratio-judged row - the median day can never clear it and the daily cry-wolf is back: ' + $r.text)
}

# THE EMITTER ITSELF must still round-trip, or every row above is fiction. Runs the REAL coverage-lib.ps1.
$covEmitOk = $false
try {
  $covProbe = & {
    . (Join-Path $fxCov 'coverage-lib.ps1')
    $od = Join-Path $fxCov 'emit'
    New-Item -ItemType Directory -Force $od | Out-Null
    Write-CoverageRecord -Check 'fixture/real' -OutDir $od -Eligible 100 -Examined 40 -Detail 'fixture'
    Write-CoverageRecord -Check 'fixture/blind' -OutDir $od -Eligible 100 -Examined 0 -Detail 'fixture'
    Read-CoverageJson (Join-Path $od 'coverage-ledger.json')
  }
  $covEmitOk = ($covProbe -and $covProbe.checks.'fixture/real'.examined -eq 40 -and $covProbe.checks.'fixture/real'.skipped -eq 60 -and (-not $covProbe.checks.'fixture/real'.blind) -and $covProbe.checks.'fixture/blind'.blind)
} catch { $covEmitOk = $false }
if ($covEmitOk) { Ok 'coverage-lib records eligible/examined/skipped and marks a zero-examined row BLIND' }
else { Bad 'coverage-lib no longer round-trips a record - every ledger row in this estate is fiction' }
# and it must NOT write to the output stream: guards.ps1 and check-ad-cycles parse their own stdout.
$covNoise = & { . (Join-Path $fxCov 'coverage-lib.ps1'); Write-CoverageRecord -Check 'fixture/noise' -OutDir (Join-Path $fxCov 'emit') -Eligible 1 -Examined 1 }
if ($null -eq $covNoise -or @($covNoise).Count -eq 0) { Ok 'coverage-lib emits nothing to the output stream (it cannot pollute a caller''s stdout)' }
else { Bad ('coverage-lib wrote ' + @($covNoise).Count + ' object(s) to the output stream - it will corrupt the stdout of every script that calls it') }
Remove-Item $fxCov -Recurse -Force -ErrorAction SilentlyContinue
} # u104-the-budgeted-lane-min-ratio-2026-08

# ---------------------------------------------------------------- N+10. the OUT-OF-BAND verification sample
# FOUNDING BUG (2026-07-30): every accuracy number this estate prints is written by the code that wrote the
# board. On the morning of 2026-07-30 "ACCURACY 0 of 1,844", "guards exit 0" and "2,640 cells scanned" were
# all true as printed, and all three were sitting above a bag of cat food holding the SALMON crown. The
# sampler exists to produce the one statement the board did not write about itself, and it has exactly two
# ways to become worthless: hand the verifier OUR answer (then they confirm our price and never ask whether
# the row is salmon), or quote a defect rate as a bare point estimate (then "3 of 30 = 10%" gets repeated as
# fact when 3-of-30 is equally consistent with 2% and with 27%).
# Both regions are extracted from the REAL scripts and executed against frozen synthetic input - a
# transcribed copy would drift out of the shipping code the way the Lysol negative test did.
if (Use-Unit 'u105-n-10-the-out-of-band-verification') {
$bvsPath = Join-Path $root 'build-verification-sample.ps1'
$rsvPath = Join-Path $root 'record-sample-verdict.ps1'
if (-not (Test-Path $bvsPath) -or -not (Test-Path $rsvPath)) {
  Bad 'the out-of-band sampler scripts are MISSING - the only non-self-referential check on the board is gone, and this section EXAMINED NOTHING'
} else {
  $bvsTxt = ((Get-Content $bvsPath -Raw) + '')
  $rsvTxt = ((Get-Content $rsvPath -Raw) + '')

  # ---- (a) the DRAW: deterministic, seed-sensitive, and it must spill rather than shrink -----------------
  $mDraw = [regex]::Match($bvsTxt, '# BEGIN-SAMPLE-DRAW[\s\S]*?# END-SAMPLE-DRAW')
  if (-not $mDraw.Success) { Bad 'could not extract the BEGIN-SAMPLE-DRAW region from build-verification-sample.ps1 - the draw fixtures below CANNOT RUN' }
  else {
    $dr = & {
      Invoke-Expression $mDraw.Value
      [pscustomobject]@{
        same     = ((Get-SampleScore '2026-07-30' 'salmon|Walmart') -eq (Get-SampleScore '2026-07-30' 'salmon|Walmart'))
        seedDiff = ((Get-SampleScore '2026-07-30' 'salmon|Walmart') -ne (Get-SampleScore '2026-07-31' 'salmon|Walmart'))
        keyDiff  = ((Get-SampleScore '2026-07-30' 'salmon|Walmart') -ne (Get-SampleScore '2026-07-30' 'salmon|Aldi'))
        inRange  = ((Get-SampleScore '2026-07-30' 'salmon|Walmart') -ge 0 -and (Get-SampleScore '2026-07-30' 'salmon|Walmart') -lt 1)
        # the live board shape on 2026-07-30: 492 crown cells, 2300 non-crown
        live     = (Get-StratumAllocation 100 0.6 492 2300)
        srs      = (Get-StratumAllocation 100 0.0 492 2300)
        # MUST SPILL: a stratum too small for its share must not shrink the sample below what was asked for
        thinCrown = (Get-StratumAllocation 100 0.6 10 2300)
        thinOther = (Get-StratumAllocation 100 0.6 492 5)
        overdraw  = (Get-StratumAllocation 5000 0.6 492 2300)
      }
    }
    if ($dr.same -and $dr.seedDiff -and $dr.keyDiff -and $dr.inRange) { Ok 'sample draw is deterministic per (seed, cell), changes with the seed, and stays in [0,1)' }
    else { Bad ("sample draw score is not a stable seeded uniform: same=$($dr.same) seedDiff=$($dr.seedDiff) keyDiff=$($dr.keyDiff) inRange=$($dr.inRange)") }
    if ($dr.live.crown -eq 60 -and $dr.live.noncrown -eq 40 -and $dr.srs.crown -eq 0 -and $dr.srs.noncrown -eq 100 -and
        $dr.thinCrown.drawn -eq 100 -and $dr.thinOther.drawn -eq 100 -and $dr.overdraw.drawn -eq 2792) {
      Ok 'stratum allocation: 60/40 on the live shape, -CrownShare 0 gives a plain whole-board draw, a thin stratum SPILLS instead of shrinking the sample, and an over-large -N clamps to the population'
    } else {
      Bad ("stratum allocation wrong: live=$($dr.live.crown)/$($dr.live.noncrown) srs=$($dr.srs.crown)/$($dr.srs.noncrown) thinCrown=$($dr.thinCrown.drawn) thinOther=$($dr.thinOther.drawn) overdraw=$($dr.overdraw.drawn)")
    }
  }

  # ---- (b) THE BLIND WORKLIST. The must-fire and the clean twin are the same run read two ways ----------
  # MUST FIRE if the worklist ever carries the board's own answer; the TWIN proves the sealed key still has
  # it, so the check cannot pass by the sampler simply writing nothing (an empty worklist leaks nothing).
  $fxVs = NewFxDir 'verif-sample'
  New-Item -ItemType Directory -Force (Join-Path $fxVs 'out') | Out-Null
  Copy-Item $bvsPath (Join-Path $fxVs 'build-verification-sample.ps1')
  Copy-Item $rsvPath (Join-Path $fxVs 'record-sample-verdict.ps1')
  # FROZEN SYNTHETIC BOARD - never derived from the live board, so the bug it encodes cannot evaporate.
  # zzz-salmon carries the founding defect verbatim: a bag of cat food holding the crown, 20.8% under the
  # runner-up, with a real price and a plausible size. ZZQQ tokens exist only to be searched for.
  $fxRows = New-Object System.Collections.ArrayList
  [void]$fxRows.Add('{"id":"zzz-salmon","commodity":"ZZZ Salmon Fillet","unit":"lb","cheapest_store":"ZZZ-Mart","cheapest_price":1.23,"stores":[{"store":"ZZZ-Mart","per_unit":1.23,"unit":"lb","type":"everyday","item":"ZZQQ Dry Food for Adult Cats ZZQQ","size":"16 lb","ad":"$19.68"},{"store":"ZZZ-Grocer","per_unit":9.99,"unit":"lb","type":"everyday","item":"ZZQQ Atlantic Salmon Fillet ZZQQ","size":"lb","ad":"$9.99"}]}')
  for ($fi = 1; $fi -le 49; $fi++) {
    [void]$fxRows.Add('{"id":"zzz-item-' + $fi + '","commodity":"ZZZ Item ' + $fi + '","unit":"lb","cheapest_store":"ZZZ-Mart","cheapest_price":1.0,"stores":[{"store":"ZZZ-Mart","per_unit":1.0,"unit":"lb","type":"everyday","item":"ZZQQ Product ' + $fi + ' ZZQQ","size":"lb","ad":"$1.00"},{"store":"ZZZ-Grocer","per_unit":2.0,"unit":"lb","type":"everyday","item":"ZZQQ Other ' + $fi + ' ZZQQ","size":"lb","ad":"$2.00"}]}')
  }
  $fxBoard = '{"built_at":"2026-01-01T00:00:00","week_of":"2026-01-01","comparison":[' + (($fxRows.ToArray()) -join ',') + ']}'
  $fxEnc = New-Object System.Text.UTF8Encoding($false)
  [IO.File]::WriteAllText((Join-Path $fxVs 'out\comparison-2026-01-01.json'), $fxBoard, $fxEnc)

  $oVs = PSChild (Join-Path $fxVs 'build-verification-sample.ps1') -N 100 -Quiet | ForEach-Object { [string]$_ }
  $rcVs = $LASTEXITCODE
  $wlF = Join-Path $fxVs 'out\verification-worklist-2026-01-01.csv'
  $kyF = Join-Path $fxVs 'out\verification-sample-2026-01-01.json'
  if ($rcVs -eq 0 -and (Test-Path $wlF) -and (Test-Path $kyF)) {
    $wlT = ((Get-Content $wlF -Raw) + '')
    $kyT = ((Get-Content $kyF -Raw) + '')
    $leaks = New-Object System.Collections.ArrayList
    if ($wlT -match 'ZZQQ')  { [void]$leaks.Add('the board product NAME') }
    if ($wlT -match '19\.68') { [void]$leaks.Add('the board PRICE') }
    if ($wlT -match 'crown')  { [void]$leaks.Add('which cells are CROWNED') }
    if ($leaks.Count -eq 0) { Ok 'the verification worklist is BLIND - it carries no product name, no price and no crown flag' }
    else { Bad ('the verification worklist LEAKS ' + ($leaks -join ' + ') + ' - a verifier handed our own answer confirms it instead of checking it, which is the entire failure this sampler exists to escape') }
    # CLEAN TWIN: the sealed key must hold everything the worklist withheld, or the test above passes on an
    # empty file. It must also carry the stratum populations, without which no reweighting is possible.
    if ($kyT -match 'ZZQQ' -and $kyT -match '19\.68' -and $kyT -match 'crown' -and $kyT -match '"population"') {
      Ok 'the sealed key still holds the board answer + stratum populations (so the blind worklist is blind by omission, not by emptiness)'
    } else { Bad 'the sealed key is missing the board answer or the stratum populations - nothing can be adjudicated or reweighted from it' }
    # ORDERING IS A CHANNEL TOO. Drawn stratum by stratum, the worklist arrives as a crown block followed by
    # a non-crown block, and the crown share is documented in the sampler's own header - so ROW POSITION
    # alone would tell the verifier which cells the board calls cheapest. The column checks above cannot see
    # that, because no column is wrong. Assert the two strata are actually shuffled together.
    $kyO = ((Read-TextFile $kyF) + '') | ConvertFrom-Json
    $seqStrat = @($kyO.cells | Sort-Object seq | ForEach-Object { [string]$_.stratum })
    $runsN = 0
    if ($seqStrat.Count -gt 0) { $runsN = 1; for ($si = 1; $si -lt $seqStrat.Count; $si++) { if ($seqStrat[$si] -ne $seqStrat[$si - 1]) { $runsN++ } } }
    if ($runsN -ge 10) { Ok ('the worklist INTERLEAVES the strata (' + $runsN + ' runs over ' + $seqStrat.Count + ' rows) - row position does not publish the crown flag the columns withhold') }
    else { Bad ('the worklist is ordered stratum-by-stratum (' + $runsN + ' runs over ' + $seqStrat.Count + ' rows) - row position ALONE tells the verifier which cells the board calls cheapest, which is the crown flag leaked through the ordering') }
    if (@($wlT -split "`r?`n" | Where-Object { $_ -match '^"' }).Count -eq 100) { Ok 'the worklist holds exactly the 100 rows that were asked for' }
    else { Bad ('the worklist row count is not the requested 100: ' + @($wlT -split "`r?`n" | Where-Object { $_ -match '^"' }).Count) }
    # REPRODUCIBLE: same board, same seed, byte-identical worklist. A sample nobody can redraw is a sample
    # nobody can audit, and Get-Random would silently make every past worklist unreproducible.
    $h1 = (Get-FileHash $wlF).Hash
    $null = PSChild (Join-Path $fxVs 'build-verification-sample.ps1') -N 100 -Force -Quiet
    if ((Get-FileHash $wlF).Hash -eq $h1) { Ok 'the draw is REPRODUCIBLE - re-running the sampler on the same board rebuilds a byte-identical worklist' }
    else { Bad 'the draw is NOT reproducible - a disputed verdict can never be traced back to the cell it graded' }
    # and it must REFUSE to silently redraw over a worklist somebody may already be verifying
    $o2 = PSChild (Join-Path $fxVs 'build-verification-sample.ps1') -N 100 | ForEach-Object { [string]$_ }
    if (($o2 -join ' ') -match 'already exists') { Ok 'the sampler refuses to overwrite an existing worklist without -Force (no redrawing until the answer is convenient)' }
    else { Bad 'the sampler silently redrew over an existing sample - a sample you may redraw at will is not a sample' }
  } else {
    Bad ('build-verification-sample did not produce a worklist from a valid frozen board (rc=' + $rcVs + '): ' + ($oVs -join ' | '))
  }
  # BLIND: no board at all must be exit 3, never a cheerful empty sample.
  $fxVsE = NewFxDir 'verif-sample-blind'
  New-Item -ItemType Directory -Force (Join-Path $fxVsE 'out') | Out-Null
  Copy-Item $bvsPath (Join-Path $fxVsE 'build-verification-sample.ps1')
  $oE = PSChild (Join-Path $fxVsE 'build-verification-sample.ps1') | ForEach-Object { [string]$_ }
  if ($LASTEXITCODE -eq 3 -and ($oE -join ' ') -match 'BLIND') { Ok 'the sampler goes BLIND (exit 3) with no board to draw from, instead of reporting an empty sample' }
  else { Bad ('the sampler returned ' + $LASTEXITCODE + ' with no board present - a sample of nothing must never read as a result') }

  # ---- (c) THE ARITHMETIC. Frozen numbers, checked against hand-computed values -------------------------
  $mSt = [regex]::Match($rsvTxt, '# BEGIN-SAMPLE-STATS[\s\S]*?# END-SAMPLE-STATS')
  if (-not $mSt.Success) { Bad 'could not extract the BEGIN-SAMPLE-STATS region from record-sample-verdict.ps1 - the interval fixtures below CANNOT RUN' }
  else {
    $stx = & {
      Invoke-Expression $mSt.Value
      [pscustomobject]@{
        # MUST FIRE: 0 defects must NOT produce a zero-width interval. This is the founding bug in one line -
        # the Wald interval prints "0.0% +/- 0.0%" here, which is the false certainty of "ACCURACY 0 of 1,844".
        clean30  = (Get-WilsonInterval 0 30)
        clean100 = (Get-WilsonInterval 0 100)
        # the n=30 vs n=100 argument, at a 20% rate: +/-13.9 points against +/-7.8
        p20n30   = (Get-WilsonInterval 6 30)
        p20n100  = (Get-WilsonInterval 20 100)
        p02n100  = (Get-WilsonInterval 2 100)
        # MUST FIRE: the crown-weighted raw fraction is NOT the board rate. 7 defects in 100 drawn 60/40 over
        # a 492/2300 board is 7.0% raw and 3.8% reweighted - quote the raw one and the board is overstated 1.8x.
        strat    = (Get-StratifiedEstimate @(
                      [pscustomobject]@{ name = 'crown';    population = 492;  n = 60; x = 6 },
                      [pscustomobject]@{ name = 'noncrown'; population = 2300; n = 40; x = 1 }))
        # MUST FIRE: a stratum with ZERO verified cells contributes its whole weight as UNCERTAINTY. Dropping
        # it would be the zero-rows lie wearing a percentage sign.
        blindStratum = (Get-StratifiedEstimate @(
                      [pscustomobject]@{ name = 'crown';    population = 492;  n = 60; x = 6 },
                      [pscustomobject]@{ name = 'noncrown'; population = 2300; n = 0;  x = 0 }))
        # CLEAN TWIN: a census leaves nothing unsampled, so the finite-population correction must drive the
        # design-based half-width to EXACTLY zero. This is the twin that catches the FPC being silently
        # disabled - which is what a $Nh/$nh name collision did to this function while it was being written.
        census   = (Get-StratifiedEstimate @(
                      [pscustomobject]@{ name = 'crown';    population = 492;  n = 492;  x = 20 },
                      [pscustomobject]@{ name = 'noncrown'; population = 2300; n = 2300; x = 30 }))
        need1pt  = (Get-RequiredN 0.02 0.01 2792)
        need3pt  = (Get-RequiredN 0.02 0.03 2792)
        needCensus = (Get-RequiredN 0.20 0.01 2792)
        needBadTarget = (Get-RequiredN 0.20 0.0 2792)
        refuse29 = (Test-CanQuoteRate 29 30)
        refuse30 = (Test-CanQuoteRate 30 30)
        refuse0  = (Test-CanQuoteRate 0 30)
      }
    }
    if ($stx.clean30.hi -gt 0.10 -and $stx.clean30.hi -lt 0.13 -and $stx.clean100.hi -gt 0.03 -and $stx.clean100.hi -lt 0.04) {
      Ok ('ZERO defects still yields a real upper bound (0/30 -> up to ' + ('{0:N1}' -f (100 * $stx.clean30.hi)) + '%, 0/100 -> up to ' + ('{0:N1}' -f (100 * $stx.clean100.hi)) + '%) - a clean sample is never certainty')
    } else { Bad ('a zero-defect sample produced a collapsed interval (0/30 hi=' + $stx.clean30.hi + ', 0/100 hi=' + $stx.clean100.hi + ') - that is the Wald bug and it prints false certainty') }
    if ([Math]::Abs($stx.p20n30.half - 0.1390) -lt 0.002 -and [Math]::Abs($stx.p20n100.half - 0.0777) -lt 0.002 -and [Math]::Abs($stx.p02n100.half - 0.0323) -lt 0.002) {
      Ok 'Wilson half-widths match the hand-computed values (6/30 +/-13.9 pts, 20/100 +/-7.8, 2/100 +/-3.2) - the n=30 sample cannot tell a 10% board from a 30% board'
    } else { Bad ("Wilson arithmetic drifted: 6/30 half=$($stx.p20n30.half) (want 0.1390), 20/100 half=$($stx.p20n100.half) (want 0.0777), 2/100 half=$($stx.p02n100.half) (want 0.0323)") }
    if ([Math]::Abs($stx.strat.p - 0.0382) -lt 0.001 -and $stx.strat.p -lt 0.05 -and $stx.strat.x -eq 7 -and $stx.strat.n -eq 100) {
      Ok ('the crown-weighted draw is REWEIGHTED to the board (7/100 raw = 7.0% becomes ' + ('{0:N1}' -f (100 * $stx.strat.p)) + '% whole-board) - quoting the raw sample fraction would overstate the board 1.8x')
    } else { Bad ("the stratified reweighting is wrong or gone: p=$($stx.strat.p) (want 0.0382 from x=$($stx.strat.x)/n=$($stx.strat.n))") }
    if ($stx.blindStratum.hi -gt 0.80) { Ok ('a stratum with zero verified cells blows the whole-board ceiling to ' + ('{0:N0}' -f (100 * $stx.blindStratum.hi)) + '% instead of being silently dropped') }
    else { Bad ('an unsampled stratum was silently dropped from the interval (hi=' + $stx.blindStratum.hi + ') - 2,300 unchecked cells cannot read as agreement') }
    if ([Math]::Abs($stx.strat.nWald - 0.0415) -lt 0.002 -and $stx.census.nWald -lt 1e-9) {
      Ok 'the finite-population correction is live (60+40 of 2792 -> +/-4.2 pts design-based) and collapses to exactly zero on a census'
    } else { Bad ("the finite-population correction is disabled or wrong: sample nWald=$($stx.strat.nWald) (want ~0.0415), census nWald=$($stx.census.nWald) (want 0)") }
    if ($stx.need1pt -eq 594 -and $stx.need3pt -eq 82 -and $stx.needCensus -eq 1921 -and $stx.needBadTarget -eq -1) {
      Ok 'required-n is honest about its own limits: +/-3 pts at a 2% rate needs 82 cells, +/-1 pt needs 594, +/-1 pt at a 20% rate needs 1,921 of 2,792 (69% of the board - a census in all but name), and an impossible target returns -1'
    } else { Bad ("required-n arithmetic is wrong: 1pt@2%=$($stx.need1pt) 3pt@2%=$($stx.need3pt) 1pt@20%=$($stx.needCensus) badTarget=$($stx.needBadTarget) (want 594, 82, 1921, -1)") }
    if ((-not $stx.refuse29) -and $stx.refuse30 -and (-not $stx.refuse0)) { Ok 'the rate refusal is armed: 29 verified rows quote nothing, 30 do, and zero rows never do' }
    else { Bad ("the too-few-samples refusal is broken: 29=$($stx.refuse29) 30=$($stx.refuse30) 0=$($stx.refuse0)") }
  }

  # ---- (d) the recorder end to end, on the frozen sample it just drew ------------------------------------
  if (Test-Path $kyF) {
    function FxFill([string]$src, [string]$dst, [int]$howMany, [string]$verdict) {
      $ls = @(Get-Content $src)
      $acc = New-Object System.Collections.ArrayList
      $seen = 0
      foreach ($ln in $ls) {
        if ($ln -match '^\s*#' -or $ln -like 'ticket,*') { [void]$acc.Add($ln); continue }
        $seen++
        $tk = [regex]::Match($ln, '^"([0-9A-F]+)"').Groups[1].Value
        $v = if ($seen -le $howMany) { $verdict } else { '' }
        # found_price is filled (2026-09-19, I232): the recorder now records an ok with NO price the verifier
        # saw as could-not-look, so an unpriced 'ok' fixture would test that rule instead of the interval.
        [void]$acc.Add('"' + $tk + '",' + $seen + ',"x","lb","ZZZ-Mart",' + $v + ',,"1.00",')
      }
      [IO.File]::WriteAllText($dst, (($acc.ToArray()) -join "`r`n") + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    }
    # MUST REFUSE: 12 verified rows is not a rate.
    FxFill $wlF (Join-Path $fxVs 'out\fx-few.csv') 12 'ok'
    $oR = PSChild (Join-Path $fxVs 'record-sample-verdict.ps1') -VerdictFile (Join-Path $fxVs 'out\fx-few.csv') -SampleFile $kyF | ForEach-Object { [string]$_ }
    $rcR = $LASTEXITCODE
    if ($rcR -eq 3 -and ($oR -join ' ') -match 'NO RATE QUOTED') { Ok 'the recorder REFUSES to quote a defect rate from 12 verified cells (exit 3, could-not-evaluate)' }
    else { Bad ('the recorder quoted a rate from 12 cells (rc=' + $rcR + ') - a rate from 12 rows is not a small rate, it is not a rate: ' + ($oR -join ' | ')) }
    # ...and must never print a bare point estimate once it CAN quote: every rate arrives with an interval.
    FxFill $wlF (Join-Path $fxVs 'out\fx-all.csv') 100 'ok'
    $oR2 = PSChild (Join-Path $fxVs 'record-sample-verdict.ps1') -VerdictFile (Join-Path $fxVs 'out\fx-all.csv') -SampleFile $kyF | ForEach-Object { [string]$_ }
    $rcR2 = $LASTEXITCODE
    $txtR2 = ($oR2 -join ' ')
    if ($rcR2 -eq 0 -and $txtR2 -match '95% CI' -and $txtR2 -match 'WHOLE BOARD' -and $txtR2 -match 'RESOLUTION') {
      Ok 'the recorder quotes a whole-board rate only WITH its 95% interval and states what n would resolve it'
    } else { Bad ('the recorder did not report an interval-bearing whole-board rate (rc=' + $rcR2 + '): ' + $txtR2) }
    # a 100-of-100 CLEAN sample must still refuse to claim the board is clean
    if ($txtR2 -match '95% CI 0\.0% to [1-9]') { Ok 'a 100-cell sample with ZERO defects still publishes a non-zero upper bound - "we found nothing" never becomes "there is nothing"' }
    else { Bad ('a zero-defect sample reported a zero-width whole-board interval - that is the clean bill of health that has never once been true here: ' + $txtR2) }
    # unverifiable rows must leave the DENOMINATOR, not pass as ok
    FxFill $wlF (Join-Path $fxVs 'out\fx-unv.csv') 100 'unverifiable'
    $oR3 = PSChild (Join-Path $fxVs 'record-sample-verdict.ps1') -VerdictFile (Join-Path $fxVs 'out\fx-unv.csv') -SampleFile $kyF | ForEach-Object { [string]$_ }
    if ($LASTEXITCODE -eq 3 -and ($oR3 -join ' ') -match 'proved NOTHING') { Ok 'an all-unverifiable sample (bot walls) reports that it proved NOTHING - it never counts as 100 passes' }
    else { Bad ('an all-unverifiable sample was scored as a result (rc=' + $LASTEXITCODE + ') - a bot wall is not a clean cell: ' + ($oR3 -join ' | ')) }
  }
  Remove-Item $fxVs, $fxVsE -Recurse -Force -ErrorAction SilentlyContinue
}
} # u105-n-10-the-out-of-band-verification

# ---------------------------------------------------------------- BAKE CURRENCY (2026-07-31, triage round 2)
# FOUNDING BUG: category-excludes.json is the LIBRARY; apply-category-excludes.ps1 BAKES it into every
# commodity's own exclude list. Nothing enforced the bake. Measured 2026-07-31: the bake sat 2,165 patterns
# behind the library across 443 commodities, which is exactly why "Krave Garlic Truffle Wagyu Beef Jerky"
# could reach the GARLIC commodity while the library that forbids \bjerky\b on every Fruit/Vegetables
# commodity sat right there, already correct, for a day. A library nobody bakes protects nothing, and the
# blocking guard (audit-food-category) reads the same library, so the drift is invisible from both ends.
# Two things have to stay true, and they are different claims:
#   (1) the LIVE tree is current - a -WhatIf that wants to add nothing;
#   (2) the detector can still SEE drift - the frozen fixture pair, so (1) passing means something.
if (Use-Unit 'u106-bake-currency') {
$r = RunPS 'apply-category-excludes.ps1' @('-WhatIf')
if ($r.rc -eq 0 -and $r.text -match '\+0 patterns across 0 commodities') { Ok 'bake-currency: the live commodities.json is CURRENT with category-excludes.json (nothing left to bake)' }
else { Bad ('bake-currency: the LIVE bake has DRIFTED behind the library - run apply-category-excludes.ps1, then re-run compare-deals and diff the board. It reports: ' + (($r.text -split "`n") | Select-Object -First 1)) }
# MUST-FIRE: a frozen miniature of the founding shape - garlic (a Vegetable) whose exclude list predates
# snack_carrier, against a library that already carries \bjerky\b and \bcrisps?\b. A correct bake wants to
# add BOTH to garlic and NOTHING to apples, which pins the load-bearing ^apples$ exempt in the same
# assertion (drop the exempt and this reads "+4 patterns across 2 commodities" and goes red).
$fxBakeD = Join-Path $fix 'bake-drifted'
$r = RunPS 'apply-category-excludes.ps1' @('-Root', $fxBakeD, '-WhatIf')
if ($r.rc -eq 0 -and $r.text -match '\+2 patterns across 1 commodities') { Ok 'bake-currency MUST-FIRE: a commodity whose exclude list predates a library class is reported as drift, and the apples exempt still exempts' }
else { Bad ('bake-currency did NOT see the drifted fixture (rc=' + $r.rc + '): ' + (($r.text -split "`n") | Select-Object -First 1) + ' - either the drift counter or the ^apples$ snack_carrier exempt has changed') }
# CLEAN TWIN: the same library against a tree that HAS been baked. A checker that cannot tell these two
# apart is measuring nothing, and the live +0 above would be worthless.
$r = RunPS 'apply-category-excludes.ps1' @('-Root', (Join-Path $fix 'bake-current'), '-WhatIf')
if ($r.rc -eq 0 -and $r.text -match '\+0 patterns across 0 commodities') { Ok 'bake-currency clean twin: an already-baked tree reports no drift' }
else { Bad ('bake-currency false-positived on an already-baked fixture (rc=' + $r.rc + '): ' + (($r.text -split "`n") | Select-Object -First 1)) }
# ...and the fixture must still be FROZEN afterwards. -WhatIf returns before the write, but a future edit
# that forgets -WhatIf would silently bake the fixture and the must-fire above would pass forever after by
# finding nothing - the [[guard-fixture-rule]] failure mode, one careless argument away.
if ((Get-Content (Join-Path $fxBakeD 'commodities.json') -Raw) -notmatch 'jerky') { Ok 'bake-currency fixture is still frozen (the drifted tree was not written to)' }
else { Bad 'the bake-drifted FIXTURE has been baked - it no longer encodes the drift, so its must-fire proves nothing. Restore it from git.' }
} # u106-bake-currency

# ---------------------------------------------------------------- (d3) food-category: the round-2 classes
# MUST-FIRE for the 2026-07-31 library additions (household tampons/lip-balm, candy marshmallows, beverage
# tea/coffee/v8). All three rows below are REAL Baker's rows read during that review, frozen verbatim, and
# all three were live CANDIDATES on commodities they have no business being in: the tampons priced against
# HONEY, the marshmallow bag against fresh STRAWBERRIES (at $0.22/oz it already beat two real strawberry
# rows), and the tea bags against fresh LEMONS. None held a cell - what stopped them was a unit refusal or
# a sanity band, not the class library, which could not express any of these classes at all.
# FROZEN LITERALS. Never regenerate from the board: the products rotate out of Baker's catalog weekly, and
# a fixture rebuilt from live data would encode nothing.
if (Use-Unit 'u107-d3-food-category-the-round-2-classes') {
$fxR2 = NewFxDir 'afc-round2'
$r2Bug = '{"week_of":"2026-07-31","comparison":[' +
  '{"commodity":"Honey","id":"honey","unit":"oz","stores":[{"store":"Baker''s","per_unit":0.4994,"item":"Honey Pot 100% Organic Cotton Core Duo Pack Tampons, 18 Count"}]},' +
  '{"commodity":"Strawberries","id":"strawberries","unit":"oz","stores":[{"store":"Baker''s","per_unit":0.22,"item":"De La Rosa Strawberry & Vanilla Marshmallows"}]},' +
  '{"commodity":"Lemons","id":"lemons","unit":"each","stores":[{"store":"Baker''s","per_unit":0.1895,"item":"Bigelow Lemon Lift Black Tea Bags"}]}]}'
Set-Content (Join-Path $fxR2 'comparison-2026-07-31.json') $r2Bug -Encoding UTF8
$r = RunPS 'audit-food-category.ps1' @('-OutDir', $fxR2)
if ($r.rc -eq 2 -and $r.text -match 'household' -and $r.text -match 'candy' -and $r.text -match 'beverage' -and $r.text -match 'honey' -and $r.text -match 'strawberries' -and $r.text -match 'lemons') {
  Ok 'food-category MUST-FIRE: tampons on honey, marshmallows on strawberries and tea bags on lemons all hard-fail (exit 2) and each names its class'
} else {
  Bad ('food-category did NOT catch the round-2 rows (rc=' + $r.rc + ') - the household tampons/lip-balm, candy marshmallows or beverage tea/coffee/v8 tokens are gone from category-excludes.json: ' + ($r.text -replace "`n", ' '))
}
# CLEAN TWIN: the SAME three commodities priced from the real products that hold those cells today. A token
# broad enough to flag these would take the board down daily, which is how a guard gets switched off.
$r2Clean = '{"week_of":"2026-07-31","comparison":[' +
  '{"commodity":"Honey","id":"honey","unit":"oz","stores":[{"store":"Sam''s Club","per_unit":0.1662,"item":"Member''s Mark Wildflower Pure Premium Honey, 48 oz."}]},' +
  '{"commodity":"Strawberries","id":"strawberries","unit":"oz","stores":[{"store":"Aldi","per_unit":0.1181,"item":"Strawberries"}]},' +
  '{"commodity":"Lemons","id":"lemons","unit":"each","stores":[{"store":"Walmart","per_unit":0.5,"item":"Fresh Lemon"}]}]}'
Set-Content (Join-Path $fxR2 'comparison-2026-07-31.json') $r2Clean -Encoding UTF8
$r = RunPS 'audit-food-category.ps1' @('-OutDir', $fxR2)
if ($r.rc -eq 0) { Ok 'food-category clean twin: the real honey / strawberries / lemons cells stay silent under the round-2 classes' }
else { Bad ('food-category flagged REAL cells (rc=' + $r.rc + ') - a round-2 token is too broad: ' + ($r.text -replace "`n", ' ')) }
Remove-Item $fxR2 -Recurse -Force -ErrorAction SilentlyContinue
} # u107-d3-food-category-the-round-2-classes

# ---- (f) THE TRIAGE PIPELINE'S OWN WATCHERS (2026-07-31) -----------------------------------------------
# Two pieces of the alert-to-fix loop carry their own frozen self-tests. They are only worth having if
# something RUNS them, so they run here, daily, with the rest of the watchers.
#   * send-alert's queue routing: a still-open condition that re-fires on a later day must absorb into the
#     SAME id (five of 2026-07-31's fourteen alerts were one condition wearing two ids), while a RESOLVED
#     one must mint a new id, because a fix that did not hold is different news from a fix nobody tried.
#   * validate-triage-plan: the handoff gate between the reviewer and the developer. Its must-fire cases
#     are the two mistakes this estate actually made - a blast radius measured as token matches instead of
#     routing outcomes, and a widened include with no claimed_by_earlier.
if (Use-Unit 'u108-f-the-triage-pipeline-s-own-watchers') {
$r = RunPS 'send-alert.ps1' @('-SelfTest')
if ($r.rc -eq 0 -and $r.text -match 'SELF-TEST PASS') { Ok 'send-alert: queue routing (cross-day absorb, resolved-mints-new) + body-thin detection' }
else { Bad ('send-alert -SelfTest failed (rc=' + $r.rc + ') - the triage queue may be minting a new id per day for one condition, or absorbing one it should not: ' + ($r.text -replace "`n", ' ')) }

$r = RunPS 'validate-triage-plan.ps1' @('-SelfTest')
if ($r.rc -eq 0 -and $r.text -match 'SELF-TEST PASS') { Ok 'validate-triage-plan: the reviewer-to-developer handoff gate still rejects a token-match blast radius and an unclaimed include' }
else { Bad ('validate-triage-plan -SelfTest failed (rc=' + $r.rc + ') - the plan gate is not enforcing what it claims: ' + ($r.text -replace "`n", ' ')) }

# audit-capture-eviction (2026-08-06): the guard for the class NO other guard can see - a cell that got
# DEARER because a thin capture evicted a rich one under Select-FreshestCaptureRows. Its must-fire is the
# frozen Sam's baby-formula case ($0.7704 -> $1.4445/oz, every existing guard green), and its clean twins
# include the founding ONIONS bug that the freshness ranker exists to fix, so a lazy "flag every eviction"
# rewrite argues against the fix that created it and goes red here.
$r = RunPS 'audit-capture-eviction.ps1' @('-SelfTest')
if ($r.rc -eq 0 -and $r.text -match 'SELF-TEST PASS') { Ok 'audit-capture-eviction: thin-capture eviction still fires on the frozen Sams formula case and stays silent on the onions ranker fix' }
else { Bad ('audit-capture-eviction -SelfTest failed (rc=' + $r.rc + ') - the capture-eviction class is unguarded: ' + ($r.text -replace "`n", ' ')) }
$aceSrc = Get-Content (Join-Path $root 'audit-capture-eviction.ps1') -Raw
$cdSrc2 = (Expand-SelfTestPointers -Text ([IO.File]::ReadAllText((Join-Path $root 'compare-deals.ps1'))) -Path (Join-Path $root 'compare-deals.ps1'))
# LOCKSTEP, NOW BY SHARED CODE RATHER THAN BY MATCHING TEXT (2026-08-21).
# The audit asks whether the BOARD agrees with the engine's eligibility rule, so it has to know that rule.
# It used to carry a hand-restated copy, and this check kept the two honest by grepping both files for the
# same literal. That worked until the rule's MEANING changed instead of its text: the everyday/sale split
# made one captured product emit two candidate rows, so "count the rows" stopped meaning "how much does
# this capture know about this commodity" while both copies still read `$g.Count -gt $newestCount` and this
# check still passed. A grep sees a literal; it cannot see a definition moving underneath one.
# Both sides now dot-source capture-depth-lib, so the drift is no longer expressible and what is asserted
# here is that neither has quietly re-grown a private copy.
$cdLib  = ($cdSrc2 -match "capture-depth-lib\.ps1")
$aceLib = ($aceSrc -match "capture-depth-lib\.ps1")
$cdOwnCopy  = ($cdSrc2 -match 'function\s+Select-FreshestCaptureRows')
$aceOwnCopy = ($aceSrc -match 'function\s+Select-FreshestCaptureRows')
if ($cdLib -and $aceLib -and -not $cdOwnCopy -and -not $aceOwnCopy) { Ok 'compare-deals and audit-capture-eviction share ONE coverage-depth rule (capture-depth-lib), neither holds a private copy' }
elseif (-not $cdLib) { Bad 'compare-deals no longer dot-sources capture-depth-lib - the engine and the audit that checks it can now disagree silently, which is how Sams baby-formula shipped at +87% and how Walmart cherries published a 38-day-dead $2.50 against a live $6.97' }
elseif (-not $aceLib) { Bad 'audit-capture-eviction no longer dot-sources capture-depth-lib - it is at risk of auditing a rule the engine does not run' }
else { Bad 'a private copy of Select-FreshestCaptureRows has re-appeared beside the shared lib - two copies of this rule have drifted before and the failure is silent in both directions' }
# The lib must still COUNT DISTINCT PRODUCTS. This is the one property that cannot be inferred from "both
# dot-source the lib", and reverting it re-opens the cherries cell.
$cdlSrc = Get-Content (Join-Path $root 'capture-depth-lib.ps1') -Raw
if ($cdlSrc -match 'Select-Object -Unique' -and $cdlSrc -match 'function\s+Get-CaptureDepth') { Ok 'capture-depth-lib still measures depth in DISTINCT products, so a split one-product capture cannot out-rank a live one' }
else { Bad 'capture-depth-lib no longer counts distinct products - the everyday/sale split makes one product emit two rows, so a 1-product capture presents as depth 2 and a stale-low price can evict today''s' }
# The candidates artifact must keep carrying src_date, or this guard is permanently BLIND. It shipped
# without that field for months, which is exactly why the eviction class went unseen.
# prod_key joined src_date in the projection on 2026-09-05 for the same reason: the supersession rule turns
# on it, so an artifact without it cannot be audited against the rule the engine ran. Both are asserted.
# Fields may follow prod_key (as_of joined on 2026-09-19 for the provenance contract); what is asserted is that
# the two the ranking turns on are both still projected, adjacent as they always were.
if ($cdSrc2 -match 'price_type,src_date' -and $cdSrc2 -match 'src_date,prod_key(,\w+)*\)') { Ok 'compare-deals still emits src_date AND prod_key into candidates (the two fields the per-store ranking turns on)' }
else { Bad 'compare-deals no longer emits src_date into candidates-*.json - audit-capture-eviction goes BLIND and an eviction becomes invisible again' }

# ROSTER CURRENCY (2026-08-06, triage plan-2026-08-06-2). A guard nothing RUNS is not a guard. This one
# shipped with a self-test and no roster: for its first day the only thing exercising it was the -SelfTest
# above, which proves the code works and says nothing about whether it ever looks at the live board. It was
# hand-run at 10:22:08 against the 10:21:49 board and would never have re-checked the 11:23:15 rebuild.
# Checked in two halves, because either half alone can be fooled:
#   (1) SOURCE - check-ad-cycles must still make a LIVE call (a -SelfTest-only reference does not count).
#   (2) CURRENCY - the artifact it writes must name the newest comparison and be stamped LATER than that
#       comparison's built_at. A stamp older than the job that writes it is the tell of a roster entry that
#       never armed (gates-that-can-never-arm), and it is also what a call that throws every run looks like
#       from the outside, where the source check alone would stay green forever.
$cacLive = @(((Expand-SelfTestPointers -Text ([IO.File]::ReadAllText((Join-Path $root 'check-ad-cycles.ps1'))) -Path (Join-Path $root 'check-ad-cycles.ps1')) -split "`n") | Where-Object { $_ -match 'audit-capture-eviction\.ps1' -and $_ -notmatch '-SelfTest' -and $_ -notmatch '^\s*#' })
if ($cacLive.Count -gt 0) { Ok 'audit-capture-eviction is ROSTERED in check-ad-cycles - the eviction check runs on every board generation, not only when a human remembers it' }
else { Bad 'audit-capture-eviction is not called by check-ad-cycles.ps1 - the ONLY check that can see a thin capture evicting a rich one is hand-cranked, and a passing -SelfTest proves the code works, not that anything runs it' }

# WHICH RECORD ANSWERS "DID THE ROSTERED PASS RUN ON THIS BOARD", AND WHY THE TRACKED REPORT IS NOT THAT RECORD
# OUTSIDE THE CHECKOUT THAT WROTE IT (2026-09-11, second pass over the same incident).
#
# The pass writes two files. out\capture-evictions.json is the REPORT and is TRACKED, so its findings stay
# reviewable in history. out\capture-evictions-stamp.json is the STAMP and is gitignored, like the board it
# describes, so the two reach a checkout by the same road: this disk, or .worktreeinclude into a new worktree.
#
# THE REPORT CROSSES CHECKOUTS BY COMMIT; THE BOARD CROSSES BY COPY. Comparing them therefore answers a DIFFERENT
# QUESTION from the one this case asks. This case asks: has the rostered pass run on the newest board in THIS
# checkout? Report-versus-board answers: how long ago did somebody commit a report, in some OTHER checkout, naming
# the board that was later copied here - which the daily bot's commit clock decides, not the pass. In the checkout
# that RAN the pass, the report on disk is that run's own output and the comparison is sound. Anywhere else it is a
# commit-lag measurement wearing a currency verdict's words, and whether it reads pass or fail is an accident of
# when the last commit happened relative to the last board copy.
#
# It cost a day. 2026-09-11: a triage chain rebuilt the board at 14:27, ran the pass at 14:32 in the main checkout
# and committed its source only (correctly - explicit paths). Every worktree carrying the new board then REFUSED
# unrelated pushes against a committed report naming the old one, while main's own dirty working copy passed. The
# stamp (422699bb3) put the record on the board's road for every checkout seeded after the first live pass under
# that code, and left the checkouts that have no stamp "judged on the report exactly as before" - which is exactly
# the false FAIL, still standing. So the decision is three-way, and Get-CaptureEvictionCurrency below holds it:
#   * a STAMP decides wherever the checkout has one. It travels the board's road, and it must match the board's
#     GENERATION (built_at) as well as its name, because a board is rebuilt in place under the same name
#     (comparison-2026-09-09.json at 12:19 that day).
#   * with NO stamp, ask whether this checkout could ever have run the pass. The pass resolves its input as
#     out\candidates-YYYY-MM-DD.json (audit-capture-eviction.ps1's live run; the case below asserts that spelling
#     has not moved), and .worktreeinclude does not carry those, so a worktree exits 3 BLIND there and can never
#     write a stamp or a report of its own. With none present the verdict is a counted SKIP naming that reason -
#     never a FAIL, and never a pass either (a-could-not-look-must-not-settle-the-question).
#   * with candidates present - the chain's own checkout - the report IS this checkout's own output, and it is
#     judged exactly as it was before this change, message for message.
# THIS DOES NOT WEAKEN THE CASE. The FAIL that goes away is one that could never tell "the pass did not run" from
# "nobody has committed a report yet", in a checkout where the first is unanswerable. The true positive this case
# exists for - a chain that rebuilds a board and skips the pass - is still a FAIL in the checkout that holds that
# board and can run that pass, and a seeded checkout gets the STRICTER stamp test instead of a SKIP as soon as one
# live pass has run upstream. design\PLAN-capture-eviction-stamp-2026-09-11.md has the timeline and the two repairs
# that were measured and refused (untracking the report; a stamp-only reader).
#
# PURE, so the frozen cases below drive the real decision with no file on disk - the same reason
# audit-capture-eviction's own detector is a function. Returns @{ verdict = PASS|FAIL|SKIP; message = <line> }.
function Get-CaptureEvictionCurrency {
  param(
    [object]$Stamp,             # out\capture-evictions-stamp.json parsed, or $null when this checkout has none
    [object]$Report,            # out\capture-evictions.json parsed, or $null
    [int]$CandidateFileCount,   # dated out\candidates-*.json here: 0 means the pass has never been runnable
    [int]$BoardCount,           # dated boards here, so the SKIP line prints its denominator
    [string]$BoardName, [string]$BoardBuiltAt
  )
  $fromStamp = $false
  if ($Stamp) { $rec = $Stamp; $name = 'capture-evictions-stamp.json'; $fromStamp = $true }
  elseif ($CandidateFileCount -le 0) {
    return @{ verdict = 'SKIP'; message = ('roster currency: this checkout holds ' + $BoardCount + ' dated board(s) and 0 dated out\candidates-*.json, so the rostered capture-eviction pass has never been runnable here and has written no out\capture-evictions-stamp.json. The TRACKED out\capture-evictions.json was NOT read as a currency record: it crosses checkouts by COMMIT while the board crosses by COPY, so against a copied board it measures another checkout''s commit clock, not whether the pass ran on this board') }
  }
  elseif (-not $Report) {
    return @{ verdict = 'FAIL'; message = 'a board exists but neither out\capture-evictions-stamp.json nor out\capture-evictions.json does - the rostered capture-eviction pass has never written its artifact, so the eviction class is going unwatched on the live board' }
  }
  else { $rec = $Report; $name = 'capture-evictions.json' }
  $gen = $null; $built = $null
  try { $gen = [datetime]::Parse([string]$rec.generated, [Globalization.CultureInfo]::InvariantCulture) } catch {}
  try { $built = [datetime]::Parse([string]$BoardBuiltAt, [Globalization.CultureInfo]::InvariantCulture) } catch {}
  if ((-not $gen) -or (-not $built)) {
    return @{ verdict = 'FAIL'; message = ($name + ' or the newest comparison carries an unparseable timestamp (generated=' + [string]$rec.generated + ', built_at=' + [string]$BoardBuiltAt + ') - roster currency cannot be established') }
  }
  # ORDINAL on both name comparisons. PS 5.1's `-ne` on strings is culture-sensitive, and a culture-sensitive
  # comparison IGNORES a NUL: ('a' + [char]0 + 'b') -ne 'ab' reads $false. These two names arrive from a JSON
  # document and from the filesystem, so they are exactly the text that can come back damaged, and the damaged
  # case would read as a clean match - the agreeing answer. This one was `-ne` until 2026-09-11.
  if (-not [string]::Equals([string]$rec.compare_file, $BoardName, [StringComparison]::Ordinal)) {
    return @{ verdict = 'FAIL'; message = ($name + ' audited ' + [string]$rec.compare_file + ' but the newest board is ' + $BoardName + ' - the eviction check is reporting on a board that is no longer live') }
  }
  if ($fromStamp -and (-not [string]::Equals([string]$rec.compare_built_at, [string]$BoardBuiltAt, [StringComparison]::Ordinal))) {
    return @{ verdict = 'FAIL'; message = ($name + ' read ' + $BoardName + ' as built at ' + [string]$rec.compare_built_at + ' but the board on disk was built at ' + [string]$BoardBuiltAt + ' - it was rebuilt under the same name and the rostered pass has not run on this generation') }
  }
  if ($gen -lt $built) {
    return @{ verdict = 'FAIL'; message = ($name + ' is stamped ' + $gen.ToString('s') + ', OLDER than the ' + $BoardName + ' generation it names (built_at ' + $built.ToString('s') + ') - the rostered pass did not run on this board, so its zero findings describe a board that no longer exists') }
  }
  return @{ verdict = 'PASS'; message = ('capture-eviction roster is ARMED: ' + $name + ' (' + $gen.ToString('s') + ') post-dates the newest board ' + $BoardName + ' (built_at ' + $built.ToString('s') + ')') }
}

# THE FROZEN CASES for that decision, all from the 2026-09-11 incident: board comparison-2026-09-11.json built at
# 14:27:41, the committed report naming comparison-2026-09-09.json (generated 08:20:59), the repaired report at
# 19:22:26, the live stamp at 15:10:52. Ordinal Contains, never -match, so a needle cannot be read as a pattern.
$ceFxOk = 0; $ceFxN = 0
function Test-CeCurrency {
  param([string]$Label, [hashtable]$Verdict, [string]$Expect, [string]$Needle)
  $script:ceFxN++
  if (([string]$Verdict.verdict -eq $Expect) -and ([string]$Verdict.message).Contains($Needle)) { $script:ceFxOk++; return }
  Bad ('capture-eviction currency ' + $Label + ': expected ' + $Expect + ' saying "' + $Needle + '", got ' + [string]$Verdict.verdict + ': ' + [string]$Verdict.message)
}
$ceFxBoard = 'comparison-2026-09-11.json'
$ceFxBuilt = '2026-09-11T14:27:41'
$ceFxOldReport = [pscustomobject]@{ generated = '2026-09-11T08:20:59'; compare_file = 'comparison-2026-09-09.json' }
$ceFxLateReport = [pscustomobject]@{ generated = '2026-09-11T08:20:59'; compare_file = $ceFxBoard }
$ceFxGoodReport = [pscustomobject]@{ generated = '2026-09-11T19:22:26'; compare_file = $ceFxBoard }
$ceFxGoodStamp = [pscustomobject]@{ generated = '2026-09-11T15:10:52'; compare_file = $ceFxBoard; compare_built_at = $ceFxBuilt }
$ceFxOldStamp = [pscustomobject]@{ generated = '2026-09-11T15:10:52'; compare_file = 'comparison-2026-09-09.json'; compare_built_at = $ceFxBuilt }
$ceFxRebuiltStamp = [pscustomobject]@{ generated = '2026-09-11T15:10:52'; compare_file = $ceFxBoard; compare_built_at = '2026-09-11T08:11:25' }
# MUST FIRE: the founding positive, in the checkout that CAN run the pass. A report naming an older board there is
# this checkout's own output, so it really does mean no pass has run on this generation.
Test-CeCurrency 'MUST FIRE (report names an older board where the pass runs)' `
  (Get-CaptureEvictionCurrency -Stamp $null -Report $ceFxOldReport -CandidateFileCount 4 -BoardCount 39 -BoardName $ceFxBoard -BoardBuiltAt $ceFxBuilt) `
  'FAIL' 'audited comparison-2026-09-09.json but the newest board is comparison-2026-09-11.json'
# MUST FIRE: the same shape read off a STAMP, which is the road every seeded checkout is on.
Test-CeCurrency 'MUST FIRE (stamp names an older board)' `
  (Get-CaptureEvictionCurrency -Stamp $ceFxOldStamp -Report $ceFxGoodReport -CandidateFileCount 0 -BoardCount 39 -BoardName $ceFxBoard -BoardBuiltAt $ceFxBuilt) `
  'FAIL' 'capture-evictions-stamp.json audited comparison-2026-09-09.json'
# MUST FIRE: same board NAME, different generation - the in-place rebuild a name match cannot see.
Test-CeCurrency 'MUST FIRE (board rebuilt in place under the same name)' `
  (Get-CaptureEvictionCurrency -Stamp $ceFxRebuiltStamp -Report $ceFxGoodReport -CandidateFileCount 0 -BoardCount 39 -BoardName $ceFxBoard -BoardBuiltAt $ceFxBuilt) `
  'FAIL' 'it was rebuilt under the same name and the rostered pass has not run on this generation'
# MUST FIRE: the right board name, but the pass ran BEFORE that board was built (the 2026-08-31 shape).
Test-CeCurrency 'MUST FIRE (the pass pre-dates the board it names)' `
  (Get-CaptureEvictionCurrency -Stamp $null -Report $ceFxLateReport -CandidateFileCount 4 -BoardCount 39 -BoardName $ceFxBoard -BoardBuiltAt $ceFxBuilt) `
  'FAIL' 'OLDER than the comparison-2026-09-11.json generation it names'
# MUST NOT FIRE: the incident input, in a checkout that cannot run the pass. A seeded worktree carrying the new
# board beside the lagging COMMITTED report must not be failed on another checkout's commit clock.
Test-CeCurrency 'MUST NOT FIRE (a seeded worktree judged on a lagging committed report)' `
  (Get-CaptureEvictionCurrency -Stamp $null -Report $ceFxOldReport -CandidateFileCount 0 -BoardCount 39 -BoardName $ceFxBoard -BoardBuiltAt $ceFxBuilt) `
  'SKIP' 'has never been runnable here'
# CLEAN TWIN: a seeded worktree that DOES have a stamp still gets a real verdict, not the SKIP - the SKIP must not
# swallow the checkouts the stamp was built to serve.
Test-CeCurrency 'CLEAN TWIN (a seeded worktree with a current stamp is ARMED)' `
  (Get-CaptureEvictionCurrency -Stamp $ceFxGoodStamp -Report $ceFxOldReport -CandidateFileCount 0 -BoardCount 39 -BoardName $ceFxBoard -BoardBuiltAt $ceFxBuilt) `
  'PASS' 'roster is ARMED: capture-evictions-stamp.json'
# CLEAN TWIN: the chain's own checkout, no stamp yet, its own current report - the behaviour this change had to
# leave alone, because it is what the main checkout does until its first live pass under the stamp code.
Test-CeCurrency 'CLEAN TWIN (no stamp, current report where the pass runs)' `
  (Get-CaptureEvictionCurrency -Stamp $null -Report $ceFxGoodReport -CandidateFileCount 4 -BoardCount 39 -BoardName $ceFxBoard -BoardBuiltAt $ceFxBuilt) `
  'PASS' 'roster is ARMED: capture-evictions.json'
if ($ceFxOk -eq $ceFxN) { Ok ('capture-eviction currency decision: ' + $ceFxOk + ' of ' + $ceFxN + ' frozen case(s) - 4 must-fire, 1 must-not-fire, 2 clean twins; the SKIP fires only where the pass cannot run, and never over a stamp') }
else { Bad ('capture-eviction currency decision: only ' + $ceFxOk + ' of ' + $ceFxN + ' frozen case(s) returned the verdict they assert - the line(s) above name each one, and until they are green the roster-currency verdict below is not trustworthy') }

# ONE SPELLING OF "CAN THIS CHECKOUT RUN THE PASS", TWO READERS. The SKIP above is only honest while the live run
# really does resolve its input from dated out\candidates-*.json; if that moves, this case would SKIP a checkout
# that can run the pass. Needle built by concatenation so this assertion cannot be satisfied by its own text.
if ($aceSrc -match ([regex]::Escape("candidates-" + "*.json")) -and $aceSrc -match ([regex]::Escape('^candidates-\d{4}-\d{2}-\d{2}$'))) {
  Ok 'audit-capture-eviction still resolves its input as a dated out\candidates-*.json - the currency SKIP above reads the same spelling to decide whether this checkout could have run the pass'
} else {
  Bad 'audit-capture-eviction no longer resolves its input as a dated out\candidates-*.json - the roster-currency case decides "this checkout cannot run the pass" from that spelling, so it would now SKIP a checkout that CAN run it'
}

# LIVE-TWIN (2026-09-11): half (2) above is CURRENCY on the live board, so all four of these reads are live by design.
$ceStamp = Join-Path $root 'out\capture-evictions-stamp.json'   # LIVE-TWIN: half (2)
$ceReport = Join-Path $root 'out\capture-evictions.json'        # LIVE-TWIN: half (2)
$ceCands = @(Get-ChildItem (Join-Path $root 'out\candidates-*.json') -ErrorAction SilentlyContinue | Where-Object { $_.BaseName -match '^candidates-\d{4}-\d{2}-\d{2}$' })   # LIVE-TWIN: half (2)
$ceCmps = @(Get-ChildItem (Join-Path $root 'out\comparison-*.json') -ErrorAction SilentlyContinue | Where-Object { $_.BaseName -match '^comparison-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending)   # LIVE-TWIN: half (2)
if ($ceCmps.Count -eq 0) {
  # No dated board here at all (a bare checkout). Still not a pass - but not a defect either, so it is a
  # counted SKIP rather than a FAIL. On a machine with boards, $HasBoard is true and this stays a hard FAIL.
  if (-not $HasBoard) { Skip 'roster currency: no out\comparison-*.json here - the capture-eviction stamp was not compared against anything' }
  else { Bad 'roster currency UNCHECKABLE: no DATED out\comparison-YYYY-MM-DD.json to compare the capture-eviction stamp against - this check examined nothing, which is not the same as a clean board' }
} else {
  $ceDoc = if (Test-Path $ceStamp) { Read-JsonFile $ceStamp } else { $null }
  $ceRptDoc = if (Test-Path $ceReport) { Read-JsonFile $ceReport } else { $null }
  $ceCmpDoc = Read-JsonFile $ceCmps[0].FullName
  $ceVerdict = Get-CaptureEvictionCurrency -Stamp $ceDoc -Report $ceRptDoc -CandidateFileCount $ceCands.Count -BoardCount $ceCmps.Count -BoardName $ceCmps[0].Name -BoardBuiltAt ([string]$ceCmpDoc.built_at)
  switch ([string]$ceVerdict.verdict) {
    'PASS' { Ok ([string]$ceVerdict.message) }
    'SKIP' { Skip ([string]$ceVerdict.message) }
    default { Bad ([string]$ceVerdict.message) }
  }
}
} # u108-f-the-triage-pipeline-s-own-watchers

# ---- (g) THE PROMPTS THEMSELVES ARE CODE (2026-07-31) --------------------------------------------------
# The agents and scheduled-task SKILLs that drive all of this were the only unversioned thing left, and on
# the day this check was written SIX of eight agent prompts had already drifted between project scope and
# user scope - same name, two files, quietly disagreeing, and which one runs depends on the session's
# working directory. Same two-copies-of-one-truth trap as pu-lib and the category-exclude bake.
# The audit lives outside grocery\ (it is estate-wide), so call it by path.
if (Use-Unit 'u109-g-the-prompts-themselves-are-code' -Always 'audit-prompt-backup reads the live .claude prompt tree, which no path pattern here names') {
$pb = Join-Path (Split-Path $root -Parent) 'ops\audit-prompt-backup.ps1'
if (Test-Path $pb) {
  $out = PSChild $pb | ForEach-Object { [string]$_ }
  $rc = $LASTEXITCODE; $txt = ($out -join "`n")
  # NOT EVERY MACHINE HOSTS THE PROMPTS (2026-08-08). audit-prompt-backup compares ops\prompt-backup against
  # hardcoded live roots (C:\Codex\ThriftyCrew\.claude\agents and friends). A CI runner has none of them, so it exits 3
  # BLIND and this printed FAIL for a check that never ran. The roots are READ OUT OF THE AUDIT'S OWN SOURCE
  # rather than restated here - two copies of a path is how a rule silently stops matching. BLIND with the
  # roots present still FAILS: that is the real "the .claude paths moved" case.
  $pbRoots = @([regex]::Matches((Get-Content $pb -Raw), '(?m)^\$(?:PROJ|USER|TASKS)\s*=\s*''([^'']+)''') |
                ForEach-Object { $_.Groups[1].Value })
  if ($rc -eq 0) { Ok 'prompt-backup: every agent prompt and scheduled-task SKILL is backed up in ops\prompt-backup and identical across scopes' }
  elseif ($rc -eq 3 -and $pbRoots.Count -eq 0) { Bad 'prompt-backup: could not read its own live-prompt roots out of the source - the BLIND-vs-not-this-machine split is now guesswork' }
  elseif ($rc -eq 3 -and -not (@($pbRoots | Where-Object { Test-Path $_ }).Count)) {
    Skip ('prompt-backup: none of its live-prompt roots exist here (' + ($pbRoots -join '; ') + ') - this machine does not host the prompts, so nothing was compared')
  }
  elseif ($rc -eq 3) { Bad ('prompt-backup went BLIND (found zero live prompts) - the .claude paths moved: ' + ($txt -replace "`n", ' ')) }
  # HYGIENE, NOT BLIND (2026-09-04, queue 2026-09-04-0b63d3). rc 2 here means the audit RAN and found a
  # stale/missing MIRROR - a copy of a prompt in ops\prompt-backup that no longer matches the live file.
  # That is housekeeping. The three Bad() arms above stay Bad because each of them means the backup CHECK
  # cannot see: it lost its own roots, or it went BLIND with the roots present.
  # The remedy line is deliberately NOT "-Sync": that command writes LIVE user-scope prompt files
  # (audit-prompt-backup.ps1:159 copies project scope over C:\Users\Owner\.claude\agents\<name>.md) and
  # mirrors every scheduled-task SKILL into ops\prompt-backup, which is tracked in a PUBLIC repo. The drift
  # is normally a live session's in-flight edit, and syncing changes an agent prompt underneath it.
  # This finding has its OWN channel already: check-ad-cycles runs the same audit weekly and pages
  # 'Ops: an agent prompt is not backed up'.
  else { Hygiene ('prompt-backup drift (rc=' + $rc + ') - a MIRROR is stale, no watcher is blind. Do NOT reflexively -Sync: it writes live user-scope prompts and mirrors scheduled-task SKILLs into a public repo. Reconcile the named files deliberately (or add an exemption to ops\prompt-backup-exempt.json), then commit ops\prompt-backup: ' + ($txt -replace "`n", ' ')) }
} else { Bad 'prompt-backup audit is MISSING from ops\ - the agent prompts have no backup check' }
} # u109-g-the-prompts-themselves-are-code

# ---- (h) THE DISPLAY FORMATTER (2026-07-31) ------------------------------------------------------------
# Two wrong numbers reached shoppers through the formatter, not the pipeline: "356&cent;/oz" on Mint (fresh)
# because the ounce branch never rolled over to dollars, and "Cotton Swabs $0.00 each, ties record" because
# a real $0.0043-per-swab price has no second decimal to land in. Both were invisible to every existing
# guard, which all watch prices and none watched the printing of them. fmt-lib carries the frozen
# founding cases plus clean twins; this is what runs them daily.
if (Use-Unit 'u110-h-the-display-formatter') {
$r = RunPS 'fmt-lib.ps1' @('-SelfTest')
if ($r.rc -eq 0 -and $r.text -match 'SELF-TEST PASS') { Ok 'fmt-lib: per-unit display still rolls over at a dollar and still shows a real sub-cent price' }
else { Bad ('fmt-lib -SelfTest failed (rc=' + $r.rc + ') - the board can print a three-digit cent price or a $0.00 record again: ' + ($r.text -replace "`n", ' ')) }
} # u110-h-the-display-formatter

# ---- (i) THE TWO ACCURACY WATCHERS ADDED 2026-08-01 ---------------------------------------------------
# basis-outlier: catches a wrong BASIS by arithmetic when nothing in the row declares one - the Aldi
# multipack shape, where the name, the size and the price are internally consistent and completely wrong.
# consistency chip-kind: the ad-pill branch is a SKIP, and a skip with no must-fire behind it is how a
# guard stops being able to see its own bug. Its fixture proves a priced chip with NO link still breaches.
if (Use-Unit 'u111-i-the-two-accuracy-watchers-added') {
$r = RunPS 'audit-unit-basis-outlier.ps1' @('-SelfTest')
if ($r.rc -eq 0 -and $r.text -match 'SELF-TEST PASS') { Ok 'basis-outlier: still catches a pack price on a single-unit size, and still stays silent on an ordinary premium spread' }
else { Bad ('audit-unit-basis-outlier -SelfTest failed (rc=' + $r.rc + ') - a wrong-basis cell can reach the board unremarked: ' + ($r.text -replace "`n", ' ')) }

$r = RunPS 'audit-board-consistency.ps1' @('-SelfTest')
if ($r.rc -eq 0 -and $r.text -match 'SELF-TEST PASS') { Ok 'board-consistency: a flyer-only ad pill is not a breach, and a priced chip with no link still is' }
else { Bad ('audit-board-consistency -SelfTest failed (rc=' + $r.rc + ') - the ad-pill skip may now be swallowing genuinely linkless prices: ' + ($r.text -replace "`n", ' ')) }
} # u111-i-the-two-accuracy-watchers-added
# ---- (j) THE SEMANTIC SIDECAR'S ESTATE-SIDE PLUMBING (2026-08-01) --------------------------------------
# The GPU sweep itself is not run here (it needs a card, and a watcher that needs hardware is a watcher
# that goes BLIND on the cloud runner). What IS asserted daily is the part that decides whether a finding
# reaches a human: a fresh finding must be actionable, an ALREADY-ADJUDICATED cell must not be re-reported
# as new, and a malformed finding must be rejected. If that filter inverts, the advisory feed either spams
# the arrivals desk with settled rulings or silently swallows real ones.
if (Use-Unit 'u112-j-the-semantic-sidecar-s-estate-side') {
$r = RunPS 'audit-semantic-identity.ps1' @('-SelfTest')
if ($r.rc -eq 0 -and $r.text -match 'SELF-TEST PASS') { Ok 'semantic-identity: the actionable filter still admits fresh findings and still suppresses settled rulings' }
else { Bad ('audit-semantic-identity -SelfTest failed (rc=' + $r.rc + ') - the semantic advisory feed may be re-reporting adjudicated cells or dropping real ones: ' + ($r.text -replace "`n", ' ')) }
} # u112-j-the-semantic-sidecar-s-estate-side
# ---- (j2) THE ONE PROCESS THAT OWNS THE GPU WINDOW (2026-08-22, PLAN-local-matching phase 2) ----------
# graph\pipeline\nightly.ps1 is the only scheduled thing allowed to start llama-server, and the only
# reason that is safe is the ordering rule: the sidecar sweep takes the card first and must have given
# it back before the 13 GB server may take it. Both halves of that rule are pure functions, and both are
# asserted here daily, because the failure has no symptom on the day it happens - it shows up as a BLIND
# semantic sweep at 07:00 the NEXT morning, attributed to "the GPU was busy" and never traced back.
# Also fixtured: Log must not leak into any function's return value, which this script shipped wrong
# once and which silently turned the run-status file's card_free flag into an array of log lines.
if (Use-Unit 'u113-j2-the-one-process-that-owns-the-gpu') {
$r = RunPSAt (Join-Path (Split-Path $root -Parent) 'graph\pipeline') 'nightly.ps1' @('-SelfTest')
if ($r.rc -eq 0 -and $r.text -match 'self-test OK') { Ok 'nightly: the sweep/llama-server ordering rule, the deadline maths and the log-leak guard all hold' }
else { Bad ('nightly.ps1 -SelfTest failed (rc=' + $r.rc + ') - the GPU handover rule is unproven, and its failure mode is a BLIND semantic sweep tomorrow morning: ' + ($r.text -replace "`n", ' ')) }
} # u113-j2-the-one-process-that-owns-the-gpu
# ---- (j3) WHICH COMMODITY DID THE HELPER JUST SCORE? (2026-08-22) -------------------------------
# 33 bare commodity ids exist in BOTH namespaces - milk, butter, brown-sugar, carrots. The sweep's
# contested lane used to key on the bare id, so a RECIPE question could be scored against the
# STAPLE's definition. That failure produces a plausible number rather than a missing one, which is
# why it needs a fixture: a missing score is a cache miss anyone can see, and a plausible wrong one
# is never questioned. Asserted here daily so the refusal cannot quietly become a lookup again.
# SKIPPED, never failed, without the sidecar venv - it carries torch, and a watcher that needs a GPU
# stack is a watcher that goes BLIND on the cloud runner.
if (Use-Unit 'u114-j3-which-commodity-did-the-helper') {
$sidecarPy = Join-Path (Split-Path $root -Parent) 'sidecar\.venv\Scripts\python.exe'
if (-not (Test-Path $sidecarPy)) {
  Skip 'sweep -Selftest: no sidecar venv on this machine, so the namespace-collision fixture did not run'
} else {
  $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $swOut = & $sidecarPy (Join-Path (Split-Path $root -Parent) 'sidecar\sweep.py') '--selftest' 2>&1 | ForEach-Object { [string]$_ } }
  finally { $ErrorActionPreference = $prevEap }
  $swRc = $LASTEXITCODE
  if ($swRc -eq 0 -and (($swOut -join "`n") -match 'sweep SELF-TEST PASS')) { Ok 'sweep: a recipe question cannot be scored against a staple commodity that shares its bare id' }
  else { Bad ('sweep.py --selftest failed (rc=' + $swRc + ') - the contested lane may be scoring questions against the WRONG namespace''s commodity, which reads as a plausible number: ' + (($swOut -join ' '))) }
}
} # u114-j3-which-commodity-did-the-helper
# ---- (k) THE FAREWAY SIZE SURFACE (2026-08-01, triage 2026-08-01-9da3a8) -------------------------------
# Fareway's storefront DOM often omits the pack size, so the builder now reads it from the catalog slug.
# That surface is unreliable in four proven ways (dropped decimal, leading zero, per-unit size on a
# multipack, stale token), and each refusal is a row that would otherwise be published at a wrong per-unit
# or dropped for "disagreeing" with itself. Both directions are silent on a healthy board - a wrong size
# just looks like a price, and a quarantined row just looks like a store that does not carry the item -
# so the fixtures are the only thing that can see them. They are frozen from the real 2026-07-31 rows.
if (Use-Unit 'u115-k-the-fareway-size-surface') {
$r = RunPS 'build-fareway-regular.ps1' @('-SelfTest')
if ($r.rc -eq 0 -and $r.text -match 'SELF-TEST PASS') { Ok 'fareway slug sizes: counts still recovered, the four slug defects still refused, and the milk/eggs basis relabel still cannot eat a real size' }
else { Bad ('build-fareway-regular -SelfTest failed (rc=' + $r.rc + ') - Fareway can publish a pack price as a unit price again, or quarantine correct rows: ' + ($r.text -replace "`n", ' ')) }

$r = RunPS 'heal-degraded-sizes.ps1' @('-Store','fareway','-SelfTest')
if ($r.rc -eq 0 -and $r.text -match 'SELF-TEST PASS') { Ok 'size-heal: still heals across a store RENAME on the catalog product id, and still refuses when the price moved' }
else { Bad ('heal-degraded-sizes -SelfTest failed (rc=' + $r.rc + ') - a renamed product loses its pack size again and the band drops the store: ' + ($r.text -replace "`n", ' ')) }
} # u115-k-the-fareway-size-surface

# ---------------------------------------------------------------- as_of laundering (2026-08-02, C3 sample)
# THE ONLY BUG CLASS WHERE THE DETECTOR ITSELF IS THE VICTIM. build-fareway-regular merges every extract on
# disk and used to stamp them all with the BUILD date: 431 of 577 live rows wore a date newer than the
# capture that produced them, and guard 9 - which measures freshness as "as_of == today" - reported a
# fabricated 78% against a true 6%. Nothing downstream could see it, because every freshness check in the
# estate reads as_of and as_of said the rows were fresh. The C3 out-of-band sample found the shopper end:
# ranch dressing published at $0.99 as_of today, last actually captured 07-23, real shelf price $2.48.
# THREE watchers, and all three have to keep working: the builder must date from the extract, the guard must
# fail when something re-launders, and the repair must undo dates inherited from pre-fix files.
if (Use-Unit 'u116-as-of-laundering') {
$r = RunPS 'audit-asof-evidence.ps1' @('-SelfTest')
if ($r.rc -eq 0 -and $r.text -match 'SELF-TEST PASS') { Ok 'as_of evidence: a row dated fresher than any capture that holds it still fires, and a carried OLDER date still does not' }
else { Bad ('audit-asof-evidence -SelfTest failed (rc=' + $r.rc + ') - the freshness guards can be fed an invented date again: ' + ($r.text -replace "`n", ' ')) }

$r = RunPS 'repair-asof-evidence.ps1' @('-Store','fareway','-SelfTest')
if ($r.rc -eq 0 -and $r.text -match 'SELF-TEST PASS') { Ok 'as_of repair: still re-dates a laundered row DOWN to its evidence, still never forward, still leaves unbacked rows alone' }
else { Bad ('repair-asof-evidence -SelfTest failed (rc=' + $r.rc + ') - dates inherited from pre-fix files stay laundered: ' + ($r.text -replace "`n", ' ')) }

# The builder's own dating cases live in its -SelfTest above, but that test passes if the fixture stops
# REACHING the dating code. Pin the three things the (q)-(t) cases depend on: the param, the per-extract
# stamp, and the tail call. Each one was a live bug the day this was written.
$bfrSrc = Get-Content (Join-Path $root 'build-fareway-regular.ps1') -Raw
if ($bfrSrc -match '\$MaxExtractDays' -and $bfrSrc -match 'as_of=\$srcAsOf') { Ok 'fareway builder still dates each row from the EXTRACT it came from, not the build date' }
else { Bad 'build-fareway-regular no longer stamps as_of from the source extract ($srcAsOf) - the laundering is back and guard 9 will read 100% freshness on a stale file' }
if ($bfrSrc -match 'repair-asof-evidence\.ps1') { Ok 'fareway builder still runs the as_of repair after carry-forward' }
else { Bad 'build-fareway-regular no longer calls repair-asof-evidence - carried rows keep whatever date a pre-fix file gave them' }
} # u116-as-of-laundering

# ---------------------------------------------------------------- Sam's verified-row refresh (2026-08-02)
# build-sams-deals refuses any row it cannot check with qty = linePrice / unitPrice, which is correct and
# permanent - but it leaves the "sft" goods (foil/wrap/parchment/toilet paper, 45 of 74 rejects) and the
# no-unitPrice goods (cauliflower, pineapple, rotisserie chicken, 20 more) unbuildable forever. This takes
# the store's current price and keeps the size that was already hand-verified. Every refusal in its fixture
# is a way that move can go wrong, and each one publishes a wrong PRICE if it stops firing.
if (Use-Unit 'u117-sam-s-verified-row-refresh') {
$r = RunPS 'refresh-sams-verified.ps1' @('-SelfTest')
if ($r.rc -eq 0 -and $r.text -match 'SELF-TEST PASS') { Ok "Sam's verified refresh: still re-prices sft/no-unitPrice rows, and still refuses an ambiguous price, a changed pack, a per-unit size and a size that is a price" }
else { Bad ('refresh-sams-verified -SelfTest failed (rc=' + $r.rc + ") - Sam's hand-verified rows either stay stale or get re-priced against the wrong pack: " + ($r.text -replace "`n", ' ')) }
} # u117-sam-s-verified-row-refresh

# ---------------------------------------------------------------- mixed-vegetable medleys (2026-08-02)
# A PRODUCT THAT NAMES A SECOND VEGETABLE IS NOT THE FIRST ONE. Walmart carries seven broccoli/cauliflower/
# carrot blends and every one of them matched a SINGLE-vegetable commodity: the fresh medley matched
# broccoli AND cauliflower, and the two Birds Eye frozen blends matched CARROTS - a victim nobody had
# noticed, because the rules that already said "medley" and "mixed veg" say nothing about "California Blend".
# Nothing showed on the board only because each blend happened to lose on price to the real vegetable beside
# it; the day Walmart's plain broccoli goes missing, the medley IS the broccoli cell.
# THE PREVIOUS TWO ATTEMPTS WERE BOTH REVERTED BY THE GATES, and the fixture below is why: excluding a blend
# from two commodities just moves it to the third. Adding \bcarrots?\b was not in the plan either - it came
# from watching 'Birds Eye Shredded Carrots & Broccoli Florets' hop OFF carrots and ONTO broccoli in the
# match-soundness report. So this pins the whole family at once, in both directions.
if (Use-Unit 'u118-mixed-vegetable-medleys') {
# LIVE-TWIN (2026-09-11): the product names below are frozen and the RULES are live, which is the question.
$cmMed = Read-JsonFile (Join-Path $root 'commodities.json')
} # u118-mixed-vegetable-medleys
function Get-MatchingCommodities([string]$name, $catalog) {
  $hits = New-Object System.Collections.Generic.List[string]
  foreach ($cm in $catalog) {
    $inc = @($cm.include); if ($inc.Count -eq 0) { continue }
    $ok = $false
    foreach ($p in $inc) { if ($name -match $p) { $ok = $true; break } }
    if (-not $ok) { continue }
    $bad = $false
    foreach ($p in @($cm.exclude)) { if ($p -and ($name -match $p)) { $bad = $true; break } }
    if (-not $bad) { $hits.Add([string]$cm.id) }
  }
  return $hits
}
# FROZEN: every name below is verbatim from out\regular\walmart-regular-2026-08-01.json.
if (Use-Unit 'u118-mixed-vegetable-medleys') {
$SINGLE_VEG = @('broccoli', 'cauliflower', 'frozen-broccoli', 'carrots')
$medleyMust = @(
  'Marketside Fresh Broccoli and Cauliflower Medley, 12 oz',
  'Birds Eye California Blend with Carrots, Broccoli, Cauliflower, Frozen Vegetables, 60 oz. Bag',
  'Birds Eye Steamfresh Carrots, Broccoli and Cauliflower, Frozen Vegetables, 10.8 oz. Bag',
  'Great Value Steamable Broccoli & Cauliflower Florets, 12 oz',
  'Birds Eye Shredded Carrots & Broccoli Florets',
  'Birds Eye Oven Roasters Seasoned Broccoli and Cauliflower, Frozen Vegetables, 14 oz. Bag',
  'Pictsweet Farms Frozen Broccoli Florets, Red Potatoes & Carrots Vegetables for Roasting'
)
$medleyLeak = @()
foreach ($n in $medleyMust) {
  $hit = @(Get-MatchingCommodities $n $cmMed)
  foreach ($s in $SINGLE_VEG) { if ($hit -contains $s) { $medleyLeak += ($s + ' <- ' + $n) } }
}
if ($medleyLeak.Count -eq 0) { Ok 'medley rules: no broccoli/cauliflower/carrot BLEND matches a single-vegetable commodity (all 7 live Walmart blends)' }
else { Bad ('a mixed-vegetable blend is matching a single-vegetable commodity again - it will take that cell the day the real vegetable is dearer or missing: ' + ($medleyLeak -join ' | ')) }
# CLEAN TWINS - the plain vegetables must still match, or the excludes have eaten the commodity they protect.
#
# 2026-09-01: the broccoli twin was RE-POINTED, not relaxed. It used to be
# 'Great Value Broccoli Florets, 14 oz' -> broccoli, chosen because the name carries no frozen token.
# That was the assumption, not the fact: Walmart's own breadcrumb for item 13925175 reads
# Food > Frozen Foods > Frozen Fruits & Vegetables > Frozen Vegetables, its found_by_term in the
# capture is "frozen broccoli florets", and $0.0829/oz is the frozen-steamable price point. It held the
# FRESH broccoli cell and the commodity crown at $1.3257/lb until 2026-09-01 (queue 2026-09-01-b7da16).
# So that row now asserts frozen-broccoli, which makes this fixture a regression test for that bug, and
# the fresh side is asserted by two products that really are fresh: the crown Walmart actually sells,
# and a Marketside FLORETS row, which keeps the original point that a florets name must not be eaten.
$medleyTwin = @(
  @{ n = 'Fresh Whole Green Broccoli Crowns, 1 Each';      want = 'broccoli' },        # walmart-regular-2026-07-23
  @{ n = 'Marketside Broccoli Florets, 12 oz';             want = 'broccoli' },        # walmart-regular-2026-08-31, Walmart's FRESH line
  @{ n = 'Great Value Broccoli Florets, 14 oz';            want = 'frozen-broccoli' }, # walmart-regular-2026-08-31, store-verified frozen
  @{ n = 'Great Value Broccoli Florets, 32 oz Bag (Frozen)'; want = 'frozen-broccoli' },
  @{ n = 'Fresh Whole White Cauliflower';                  want = 'cauliflower' },
  @{ n = 'Marketside Whole Carrots, 2 lb Bag';             want = 'carrots' },
  @{ n = 'Our Family Mixed Vegetables, Fresh Frozen 24 Oz'; want = 'frozen-vegetables' }
)
$twinMiss = @()
foreach ($t in $medleyTwin) { if (-not (@(Get-MatchingCommodities $t.n $cmMed) -contains $t.want)) { $twinMiss += ($t.want + ' NO LONGER matches ' + $t.n) } }
if ($twinMiss.Count -eq 0) { Ok 'medley rules CLEAN TWIN: plain broccoli/cauliflower/carrots and "Fresh Frozen" mixed veg still match their own commodity' }
else { Bad ('the medley excludes have eaten a real product - a missing cell is the cost of an exclude written too wide: ' + ($twinMiss -join ' | ')) }
} # u118-mixed-vegetable-medleys

# ------------------------------------------------- product-FORM and one-word-include ownership (2026-08-06, plan-3)
# FOUR mechanisms, one fixture, all four measured on the 2026-08-06 board and frozen here verbatim from the
# captures named beside each row. NEVER regenerate these strings from the live board: the bug they encode would
# vanish and the case would pass by finding nothing.
#   (1) FORM: a commodity named for a FRESH herb had only herb-NAME includes, so a shelf-stable stir-in
#       concentrate paste won Basil (fresh) at Aldi. Dish-name includes did the same for a 0.741 oz seasoning
#       packet on a fresh vegetable commodity.
#   (2) ENCODING: the store's own mojibake defeated a correct [n-ntilde] character class. The rule never changed;
#       the world under it did. Built from char codes on purpose so an editor re-saving this file in another
#       encoding cannot silently repair the fixture out of existence.
#   (3) OWNERSHIP: one-word includes ('\bpizza\b' at 85, '\bbleach\b' at 99) sit EARLY in first-match-wins, so
#       anything that merely MENTIONS the word is captured before its true owner (cheese-crackers 218,
#       shower-cleaner 305) can ever see it.
#   (4) A brand-scoped exclude that was silently doing first-match-wins protection for a LATER commodity, so it
#       could only be narrowed, never deleted. The canned twin below is what proves the narrowing held.
if (Use-Unit 'u119-product-form-and-one-word-include') {
$mojiN = [string][char]0xC3 + [string][char]0xB1        # the store's UTF-8-read-as-latin1 n-tilde
$formMust = @(
  # name                                                                                     # first-match-wins owner (null = must not be claimed by 'reject')
  @{ n = 'Simply Nature Organic Basil Stir IN Paste 2.8 OZ';                                  reject = 'fresh-basil';          src = 'aldi-regular-2026-08-05' },
  @{ n = 'Sun-Bird Stir Fry Mix';                                                             reject = 'fresh-stir-fry-blend'; src = 'walmart-regular-2026-08-06' },
  @{ n = 'Goldfish Flavor Blasted Xtra Cheesy Pizza Cheese Crackers';                         want   = 'cheese-crackers';      src = 'bakers-regular-2026-08-06' },
  @{ n = 'OxiClean Plus Bleach No Drip Foam Mold & Mildew Bathroom Cleaner';                  want   = 'shower-cleaner';       src = 'bakers-regular-2026-08-06' },
  @{ n = 'Great Value Bathroom Cleaner with Bleach, 32 fl oz';                                want   = 'shower-cleaner';       src = 'walmart-regular-2026-08-06' },
  @{ n = ('Clemente Jacques Sliced Jalape' + $mojiN + 'o Peppers, Pickled Jalape' + $mojiN + 'os, 28 oz Can'); want = 'pickled-jalapenos'; src = 'walmart-regular-2026-08-01' }
)
$formLeak = @()
foreach ($t in $formMust) {
  $hits = @(Get-MatchingCommodities $t.n $cmMed)
  $own  = if ($hits.Count) { $hits[0] } else { '<unmatched>' }
  if ($t.reject) { if ($hits -contains $t.reject) { $formLeak += ($t.reject + ' STILL CLAIMS ' + $t.n) } }
  else           { if ($own -ne $t.want)          { $formLeak += ($t.n + ' -> ' + $own + ', wanted ' + $t.want) } }
}
if ($formLeak.Count -eq 0) { Ok 'product-form + ownership rules: a stir-in paste and a seasoning packet stay OUT of the fresh commodities, and the mojibake jalapeno / pizza-flavoured crackers / bathroom cleaners reach their TRUE owners past the early one-word includes' }
else { Bad ('a wrong-form or wrong-owner product is back in a commodity it does not belong to: ' + ($formLeak -join ' | ')) }
# CLEAN TWINS - the real products these excludes sit next to must keep their commodities, or a token is too wide.
# The canned 15 oz row is the load-bearing one: its name carries NO can token, so the ONLY thing keeping it out of
# frozen-vegetables (index 87, ahead of canned-mixed-vegetables at 336) is the narrowed brand exclude. Deleting
# that exclude outright re-hijacked this SKU in the first simulation; the (?!(frozen)) lookahead is why it holds.
$formTwin = @(
  @{ n = 'Great Value Mixed Vegetables, 15 oz';                                            want = 'canned-mixed-vegetables' },
  @{ n = 'Great Value Mixed Vegetables, 32 oz Bag (Frozen)';                               want = 'frozen-vegetables' },
  @{ n = 'Fresh Basil, 1.5 oz Clamshell';                                                  want = 'fresh-basil' },
  @{ n = 'Bud by Dole 12oz Vegetable Stir Fry';                                            want = 'fresh-stir-fry-blend' },
  @{ n = 'Kroger Pepperoni French Bread Frozen Pizza';                                     want = 'frozen-pizza' },
  @{ n = 'CLORALEN Household Cleaning Liquid Scented Bleach - Lemon Scent (121 fl oz)';     want = 'bleach' },
  @{ n = 'San Marcos Nacho Sliced Jalapenos, 26 oz';                                        want = 'pickled-jalapenos' },
  @{ n = 'Kroger Premium Chicken Breast Chunk in Water';                                    want = 'canned-chicken' },
  @{ n = 'Kroger Sausage, Egg & Cheese Croissant 8 Sandwiches';                             want = 'breakfast-sandwiches' }
)
$formTwinMiss = @()
foreach ($t in $formTwin) {
  $hits = @(Get-MatchingCommodities $t.n $cmMed)
  $own  = if ($hits.Count) { $hits[0] } else { '<unmatched>' }
  if ($own -ne $t.want) { $formTwinMiss += ($t.n + ' -> ' + $own + ', wanted ' + $t.want) }
}
if ($formTwinMiss.Count -eq 0) { Ok 'product-form CLEAN TWIN: the canned 15 oz mixed-veg SKU stays home behind the NARROWED brand exclude, and real basil / stir-fry / pizza / bleach / jalapenos / canned chicken / croissant sandwiches all keep their commodities' }
else { Bad ('a form or ownership exclude has eaten a real product, or a widened include did not land: ' + ($formTwinMiss -join ' | ')) }
} # u119-product-form-and-one-word-include
