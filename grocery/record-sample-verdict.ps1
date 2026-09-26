<#
  record-sample-verdict.ps1 - takes back the verdicts from a blind verification worklist, banks them in
  out\verification-history.json, and reports the board's defect rate AS AN INTERVAL.

  WHY AN INTERVAL AND NEVER A POINT (2026-07-30). "3 defects in 30 cells = 10%" is the sentence that would
  make this whole exercise worse than useless, because 3-in-30 is also consistent with 2% and with 27%, and
  a number with no width invites exactly the confident internal claim ("ACCURACY 0 of 1,844") that was true
  as printed while a bag of cat food held the salmon crown. So this script prints a 95% Wilson score interval,
  refuses to quote a rate at all below -MinSamples, and states how many more cells would have to be verified
  to narrow the interval to +/-1 point. If the honest answer is "we do not know yet", that is the answer.

  WHY WILSON AND NOT x/n +/- 1.96*sqrt(p(1-p)/n): the normal (Wald) interval collapses to zero width at
  p=0 - 0 defects in 40 cells would print "0.0% +/- 0.0%", a false certainty, and 0-defect samples are the
  expected case here. Wilson keeps a real upper bound at p=0 (0 of 40 -> 0.0% to 8.8%) and does not run off
  the end of [0,1].

  STRATIFIED, SO READ THE RIGHT NUMBER. build-verification-sample.ps1 over-samples CROWN cells, because a
  wrong product is ~4x more likely to hold a crown. That makes the crown rate and the non-crown rate two
  different estimates of two different things, and the whole-board rate is the population-weighted
  combination of them - NOT the raw defect count over the raw sample size. This script reports all three and
  labels which is which. Quoting the crown rate as "the board's error rate" would overstate it several fold;
  quoting the raw sample fraction would be a number that estimates nothing at all.

  UNVERIFIABLE IS NOT A PASS. A bot wall, a sign-in wall or an out-of-stock page yields 'unverifiable', and
  those rows leave the DENOMINATOR rather than counting as ok. They are reported separately and by store,
  because the two hardest stores to verify (Sam's Club, Aldi) hold 50% of the board's crowns - if they go
  dark, the surviving estimate is about the easy half of the board and must say so.

  Verdict vocabulary (as written in the worklist):
      ok | wrong-product | wrong-price | wrong-size | missing | unverifiable
  Everything except ok and unverifiable counts as a DEFECT.

  Usage:
      record-sample-verdict.ps1 -VerdictFile out\verification-worklist-2026-07-30.csv
      record-sample-verdict.ps1 -Report                 (re-report from history, record nothing)
      record-sample-verdict.ps1 -Report -PoolWeeks 8

  Exit codes: 0 = recorded and a rate was quotable. 3 = recorded, but NOT enough verified rows to quote a
  rate (could-not-evaluate - the house code for "this examined too little to mean anything"). 1 = bad input.
  It NEVER exits 2: this is bookkeeping about the board, not a gate on it, and must not be able to stop a
  publish on its own bug. 4 = -Alert owed Brad a mail about a higher rate and the send FAILED; the whole report
  still prints, and 4 outranks the 0 or 3 it would otherwise have exited (2026-09-19).

  THE 14-DAY SCHEDULED AGENT (Brad's ruling, 2026-09-19, backlog I232). A scheduled agent with a browser verifies
  a 100-cell sample every 14 days (design\ready-for-brad\verify-board-sample.SKILL.md). Three additions serve it:
    * The ruling's own words are accepted: `match` records as ok, `could-not-look` records as unverifiable.
    * A CLAIMED PASS WITH NO PRICE THE VERIFIER SAW IS A COULD-NOT-LOOK, NEVER A MATCH. An ok/match row whose
      found_price is blank is recorded as unverifiable and counted aloud. A verdict nobody backed with a number
      read off the store's page is a guess, and a guessed pass is the worst outcome this file can record.
      Measured before the rule, at base cbf146ee8: 0 of 146 ok verdicts in the two adjudicated whole-board runs
      (2026-08-08, 2026-08-15) lacked a price, so the adjudicated flow never trips it. The 2026-07-30 run (57 of
      57 ok without a price, a sighted run before adjudicate-blind-findings existed) is history and is not
      re-derived; the rule applies only to what is recorded from now on.
    * -CompareLast states this run's whole-board rate against the LAST measured one (the previous run of the same
      scope, each run alone, never pooled), with both denominators and both intervals, and -Alert mails Brad when
      the new point estimate is higher. -Due answers whether a verification is owed (13+ days since the newest
      run that verified at least -MinSamples cells), so a weekly trigger keeps a 14-day cadence and catches up
      after a missed week.
  -HistoryFile moves the history (default out\verification-history.json) so -SelfTest never touches the live one.
  -AlertLib replaces alert-lib.ps1 with a fixture that defines Send-Alert, so -SelfTest can drive the -Alert path
  end to end against a sender that fails and one that succeeds, and mail nobody.
  AN ALERT IS SAID TO BE SENT ONLY WHEN THE SEND SAYS SO (2026-09-19). Send-Alert's exit code is read: a failure
  prints "ALERT NOT SENT" with the sender's own words and exits 4. Until then the result was discarded and "ALERT
  sent to Brad" printed regardless, which is what the 2026-09-19 05:49 run said over a failed send.

  A RATE IS COMPARED ONLY WITH A RATE MEASURED BY THE SAME RULES (2026-09-19, queue 2026-09-19-641ec6). The
  2026-09-17 run alerted "37.1% is above the last measured 18.2%", and the two numbers were not measuring the same
  thing: its adjudicator applied five rules the 2026-08-15 notes do not state, and they account for 24 of its 36
  defects (under the shared rules it read 12 in 100 against 20 in 100). Nothing in the history could say so,
  because a run recorded its verdicts and never the rules that produced them. So now:
    * a run records rubric = { notes, rules_sha, version, counts }: the sha256 of the BODY of its notes' section
      headed exactly "## Adjudication standard" (the heading line is not hashed, lines are trimmed and
      LF-joined), plus the "Rubric version: <n>" and "Counted subclasses: <list>" lines read out of it.
      -RubricNotes names the notes (default: verification-decisions-<D>-notes.md beside the verdict file). Notes
      with no such section record rubric = null, said aloud, and such a run is never compared like for like.
    * every DEFECT row records a subclass from a closed vocabulary (drift, channel, not-listed, not-cheapest,
      identity, size, multi-buy, other), read from the verdict file's own subclass column or from the decisions
      CSV (-DecisionsFile, default verification-decisions-<D>.csv beside the verdict file). A defect row with no
      subclass, or a word outside the vocabulary, REFUSES the whole recording (exit 1, nothing written): dropping
      the row would understate the rate, and an unknown word would fall out of every like-for-like rate.
    * -CompareLast compares the whole-board rates only when both runs carry the SAME rules_sha. Otherwise the
      verdict is rubric-changed: both rates, plus this run's rate counting only the subclasses the last rubric
      counted (like for like), and the alert subject says "rubric changed" (or "rubric not recorded") instead of
      "is above the last measured". Every alert body carries the defects by subclass with their denominator.
#>
# The self-test drives this script over temp keys, verdict files and histories; the live history is only hashed before and after.
# gate-inputs: grocery\record-sample-verdict.ps1
param(
  [string]$VerdictFile = '',
  [string]$SampleFile = '',
  [string]$HistoryFile = '',
  [int]$PoolWeeks = 4,
  [int]$MinSamples = 30,
  [double]$TargetHalfWidth = 0.01,
  [int]$DueDays = 13,
  [string]$AlertLib = '',
  [string]$DecisionsFile = '',
  [string]$RubricNotes = '',
  [switch]$Report,
  [switch]$CompareLast,
  [switch]$Alert,
  [switch]$Due,
  [switch]$SelfTest,
  [switch]$Quiet
)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$outDir = Join-Path $root 'out'
$histPath = if ($HistoryFile) { $HistoryFile } else { Join-Path $outDir 'verification-history.json' }
function Say([string]$s) { if (-not $Quiet) { Write-Output $s } }
$DEFECT = @('wrong-product', 'wrong-price', 'wrong-size', 'missing')
$VALID  = @('ok', 'wrong-product', 'wrong-price', 'wrong-size', 'missing', 'unverifiable', 'match', 'could-not-look')
# The upstream cause of a defect, a CLOSED vocabulary (the known-wrong retire_when shape): drift = the board's
# product at another shelf price with no sale either way; channel = not buyable in store there (ship-only, out of
# stock); not-listed = the store does not list the board's product while it sells the commodity; not-cheapest =
# a cheaper qualifying product is on the shelf; identity = the board's product is not the commodity; size = the
# size or pack basis is wrong; multi-buy = a multi-buy offer read as (or not as) the unit price; other = say why.
$SUBCLASS = @('drift', 'channel', 'not-listed', 'not-cheapest', 'identity', 'size', 'multi-buy', 'other')

# ---------------------------------------------------------------------------------------------------------
# BEGIN-SAMPLE-STATS  (extracted and executed verbatim by test-auditors.ps1 - do not rename these sentinels)
# ---------------------------------------------------------------------------------------------------------
function Get-WilsonInterval([int]$x, [int]$n, [double]$z = 1.959963985) {
  # 95% Wilson score interval for x defects in n trials.
  #   centre = (p + z^2/2n) / (1 + z^2/n)
  #   half   = z/(1 + z^2/n) * sqrt( p(1-p)/n + z^2/(4n^2) )
  # Worked, and this is the arithmetic that justifies n=100 over n=30 (values computed by this function):
  #   x=6,  n=30  (p=0.200): centre 0.2341, half 0.1390 -> [ 9.5%, 37.3%]  = +/-13.9 points
  #   x=20, n=100 (p=0.200): centre 0.2111, half 0.0777 -> [13.3%, 28.9%]  = +/- 7.8 points
  #   x=2,  n=100 (p=0.020): centre 0.0378, half 0.0323 -> [ 0.6%,  7.0%]  = +/- 3.2 points
  #   x=0,  n=30  (p=0.000): centre 0.0568, half 0.0568 -> [ 0.0%, 11.4%]
  #   x=0,  n=100 (p=0.000): centre 0.0185, half 0.0185 -> [ 0.0%,  3.7%]
  # The half-width depends on p as well as n, so "+/-13 at 30 and +/-3 at 100" is only true read down the
  # right rows: +/-13.9 is the 30-sample width at a 20% rate, +/-3.2 is the 100-sample width at a 2% rate.
  # Like for like, going 30 -> 100 at a 20% rate buys 13.9 -> 7.8. Either way the 30-cell sample cannot tell
  # a 10% board from a 30% board, and those two boards are not the same product.
  if ($n -le 0) { return [pscustomobject]@{ n = 0; x = 0; p = 0.0; lo = 0.0; hi = 1.0; half = 0.5; usable = $false } }
  $p = [double]$x / [double]$n
  $z2 = $z * $z
  $den = 1.0 + ($z2 / $n)
  $centre = ($p + ($z2 / (2.0 * $n))) / $den
  $half = ($z / $den) * [Math]::Sqrt((($p * (1.0 - $p)) / $n) + ($z2 / (4.0 * $n * $n)))
  $lo = $centre - $half; if ($lo -lt 0) { $lo = 0.0 }
  $hi = $centre + $half; if ($hi -gt 1) { $hi = 1.0 }
  return [pscustomobject]@{ n = $n; x = $x; p = $p; lo = $lo; hi = $hi; half = $half; usable = $true }
}

function Get-StratifiedEstimate($strata) {
  # $strata: objects with .name .population(N_h) .n(sampled, verifiable) .x(defects).
  # Point estimate  p = SUM W_h * p_h,  W_h = N_h / SUM N_h.
  # CONSERVATIVE interval: SUM W_h * lo_h  ..  SUM W_h * hi_h, built from the per-stratum Wilson bounds.
  #   It is conservative (wider than nominal) on purpose. The textbook alternative is the design-based
  #   normal interval z*sqrt( SUM W_h^2 * p_h(1-p_h)/n_h * (N_h-n_h)/(N_h-1) ), which is also returned - but
  #   that one collapses toward zero width when the defect counts are small, which is precisely the case this
  #   estate expects and precisely the false certainty that has to be designed out. When they disagree,
  #   quote the conservative one.
  $Ntot = 0.0
  foreach ($s in $strata) { $Ntot += [double]$s.population }
  if ($Ntot -le 0) { return [pscustomobject]@{ usable = $false; p = 0.0; lo = 0.0; hi = 1.0; nWald = 0.0; n = 0; x = 0 } }
  $p = 0.0; $lo = 0.0; $hi = 0.0; $var = 0.0; $nAll = 0; $xAll = 0; $anyN = $false
  foreach ($s in $strata) {
    # $wt/$wi/$popH, never $W/$w/$Nh/$nh: PowerShell variable names are CASE-INSENSITIVE, so a weight in $W
    # and a Wilson result in $w are ONE variable, and a population in $Nh silently overwrites the sample
    # size in $nh. Written that way first, this function returned 0.0 for every estimate (four op_Multiply
    # errors naming the wrong line), and the finite-population correction computed (N-N)/(N-1) = EXACTLY
    # ZERO - a variance term that quietly vanished and printed a +/-0.0 confidence half-width. Both bugs
    # produce plausible output, which is the only kind this estate has ever had trouble with.
    $wt = [double]$s.population / $Ntot
    $nh = [int]$s.n; $xh = [int]$s.x
    $nAll += $nh; $xAll += $xh
    if ($nh -le 0) {
      # A stratum with ZERO verified cells contributes NOTHING to the point estimate and its whole weight to
      # the uncertainty: anywhere from 0 to 1 of it could be wrong and this sample cannot say. Silently
      # dropping it would be the zero-rows lie in statistical dress.
      $hi += $wt * 1.0
      continue
    }
    $anyN = $true
    $wi = Get-WilsonInterval $xh $nh
    $p  += $wt * $wi.p
    $lo += $wt * $wi.lo
    $hi += $wt * $wi.hi
    $popH = [double]$s.population
    if ($popH -gt 1) {
      $fpc = ($popH - $nh) / ($popH - 1.0)
      if ($fpc -lt 0) { $fpc = 0.0 }
      $var += ($wt * $wt) * (($wi.p * (1.0 - $wi.p)) / $nh) * $fpc
    }
  }
  if ($hi -gt 1) { $hi = 1.0 }
  return [pscustomobject]@{ usable = $anyN; p = $p; lo = $lo; hi = $hi; nWald = (1.959963985 * [Math]::Sqrt($var)); n = $nAll; x = $xAll }
}

function Get-RequiredN([double]$p, [double]$half, [int]$population, [double]$z = 1.959963985) {
  # How many cells must be verified for a +/-half interval at rate p, WITH the finite-population correction:
  #   n0 = z^2 p(1-p) / half^2         then    n = N*n0 / (N + n0 - 1)
  # Returns -1 ONLY for an impossible target (half <= 0). It does NOT return -1 for "you'd have to check the
  # whole board": the FPC formula makes n strictly less than N for every finite target, so an "impossible,
  # it's a census" branch here could never fire - a gate that can never arm, in the arithmetic itself. The
  # caller compares n against the population and says so in words instead. Measured on the live board:
  # +/-1 point at a 20% rate = 1,921 of 2,792 cells (69% of the board - a census in all but name);
  # +/-1 point at a 2% rate = 594; +/-3 points at a 2% rate = 82.
  if ($half -le 0) { return -1 }
  if ($p -le 0) { $p = 0.0 }
  if ($p -ge 1) { $p = 1.0 }
  $n0 = ($z * $z * $p * (1.0 - $p)) / ($half * $half)
  if ($n0 -le 0) { return 1 }
  if ($population -le 0) { return [int][Math]::Ceiling($n0) }
  $n = ($population * $n0) / ($population + $n0 - 1.0)
  $ni = [int][Math]::Ceiling($n)
  if ($ni -gt $population) { $ni = $population }
  return $ni
}

function Test-CanQuoteRate([int]$verified, [int]$minSamples) {
  # THE REFUSAL. Under -MinSamples verified rows, no rate is printed - only counts and the bound. A rate
  # from 8 cells is not a small rate, it is not a rate.
  return ($verified -ge $minSamples)
}
# ---------------------------------------------------------------------------------------------------------
# END-SAMPLE-STATS
# ---------------------------------------------------------------------------------------------------------

# ---- the 14-day scheduled agent's additions (backlog I232, 2026-09-19) ----------------------------------
function ConvertTo-RecordedVerdict([string]$verdict, [string]$foundPrice) {
  # The ruling's words map onto the recorded vocabulary, and a pass nobody backed with a price is not a pass.
  $v = ([string]$verdict).Trim().ToLower()
  if ($v -eq 'match') { $v = 'ok' }
  elseif ($v -eq 'could-not-look') { $v = 'unverifiable' }
  $demoted = $false
  if ($v -eq 'ok' -and ([string]$foundPrice).Trim() -eq '') { $v = 'unverifiable'; $demoted = $true }
  return [pscustomobject]@{ verdict = $v; demoted = $demoted }
}

function Get-VerifyRunScope($r) {
  if ($r.PSObject.Properties['store_scope'] -and [string]$r.store_scope) { return [string]$r.store_scope }
  return 'whole-board'
}

function Get-RunEstimate($run, [int]$minSamples, [string[]]$countOnly = $null) {
  # ONE run alone: its own verdicts (a cell verified twice inside it counts once, at its last verdict) and its
  # own stratum populations. Never pooled, because "the last measured rate" is one run's statement.
  # -countOnly (2026-09-19): count a defect only when its subclass is in the list, the like-for-like rate under an
  # older rubric. A defect outside the list stays in the denominator as a cell that rubric would have passed.
  $latest = @{}
  foreach ($v in @($run.verdicts)) { $latest[([string]$v.id) + '|' + ([string]$v.store)] = $v }
  $nC = 0; $xC = 0; $nN = 0; $xN = 0; $unv = 0
  foreach ($v in $latest.Values) {
    $vd = [string]$v.verdict
    if ($vd -eq 'unverifiable') { $unv++; continue }
    $isDef = ($DEFECT -contains $vd)
    if ($isDef -and $null -ne $countOnly) {
      $sc = ''; if ($v.PSObject.Properties['subclass']) { $sc = [string]$v.subclass }
      $isDef = ($countOnly -contains $sc)
    }
    if (([string]$v.stratum) -eq 'crown') { $nC++; if ($isDef) { $xC++ } } else { $nN++; if ($isDef) { $xN++ } }
  }
  $popC = 0; $popN = 0
  if ($run.strata) {
    if ($run.strata.crown)    { $popC = [int]$run.strata.crown.population }
    if ($run.strata.noncrown) { $popN = [int]$run.strata.noncrown.population }
  }
  $sC = [pscustomobject]@{ name = 'crown'; population = $popC; n = $nC; x = $xC }
  $sN = [pscustomobject]@{ name = 'noncrown'; population = $popN; n = $nN; x = $xN }
  $st = Get-StratifiedEstimate @($sC, $sN)
  $n = $nC + $nN
  return [pscustomobject]@{
    board_date = [string]$run.board_date; scope = (Get-VerifyRunScope $run); n = $n; x = ($xC + $xN); unverifiable = $unv
    p = $st.p; lo = $st.lo; hi = $st.hi
    quotable = (($n -ge $minSamples) -and (($popC + $popN) -gt 0) -and $st.usable)
  }
}

function Format-RunRate($e) {
  return ($e.board_date + ' ' + ('{0:N1}%' -f (100.0 * $e.p)) + ' (95% CI ' + ('{0:N1}%' -f (100.0 * $e.lo)) + ' to ' +
    ('{0:N1}%' -f (100.0 * $e.hi)) + '; ' + $e.x + ' defect(s) in ' + $e.n + ' verified, ' + $e.unverifiable + ' could-not-look)')
}

function Get-RateVsLast($runs, [int]$minSamples) {
  # The newest run against the LAST MEASURED rate: the newest earlier run of the SAME scope that verified enough
  # cells to quote one. An earlier run that could not quote a rate measured nothing and is stepped over.
  $sorted = @(@($runs) | Where-Object { ([string]$_.board_date) -match '^\d{4}-\d{2}-\d{2}$' } | Sort-Object { [string]$_.board_date })
  if ($sorted.Count -eq 0) { return [pscustomobject]@{ verdict = 'no-run'; new = $null; last = $null; overlap = $false; line = 'RATE-VS-LAST verdict=no-run' } }
  $newRun = $sorted[$sorted.Count - 1]
  $eN = Get-RunEstimate $newRun $minSamples
  if (-not $eN.quotable) {
    return [pscustomobject]@{ verdict = 'not-quotable'; new = $eN; last = $null; overlap = $false
      line = ('RATE-VS-LAST verdict=not-quotable scope=' + $eN.scope + ' new=' + $eN.board_date + ' verified=' + $eN.n + ' (under the floor of ' + $minSamples + '; no rate, so nothing to compare)') }
  }
  $eP = $null; $pRun = $null
  for ($i = $sorted.Count - 2; $i -ge 0; $i--) {
    if ((Get-VerifyRunScope $sorted[$i]) -ne $eN.scope) { continue }
    $cand = Get-RunEstimate $sorted[$i] $minSamples
    if ($cand.quotable) { $eP = $cand; $pRun = $sorted[$i]; break }
  }
  if ($null -eq $eP) {
    return [pscustomobject]@{ verdict = 'no-previous'; new = $eN; last = $null; overlap = $false; newRun = $newRun; lastRun = $null
      line = ('RATE-VS-LAST verdict=no-previous scope=' + $eN.scope + ' new=' + (Format-RunRate $eN)) }
  }
  $overlap = -not (($eN.lo -gt $eP.hi) -or ($eN.hi -lt $eP.lo))
  # ONE RUBRIC OR NO COMPARISON (2026-09-19, queue 2026-09-19-641ec6). Two whole-board rates are compared only
  # when both runs recorded the SAME rules_sha; anything else is rubric-changed, with the like-for-like rate.
  $rN = Get-RunRubric $newRun; $rP = Get-RunRubric $pRun
  $shaN = ''; if ($rN) { $shaN = [string]$rN.rules_sha }
  $shaP = ''; if ($rP) { $shaP = [string]$rP.rules_sha }
  $rubTxt = ' new_rubric=' + $(if ($shaN) { $shaN.Substring(0, [Math]::Min(12, $shaN.Length)) } else { 'none' }) +
            ' last_rubric=' + $(if ($shaP) { $shaP.Substring(0, [Math]::Min(12, $shaP.Length)) } else { 'none' })
  $ovTxt = ' intervals=' + $(if ($overlap) { 'overlap' } else { 'disjoint' })
  if ($shaN -ne '' -and $shaN -eq $shaP) {
    $verdict = if ($eN.p -gt $eP.p) { 'worse' } else { 'not-worse' }
    return [pscustomobject]@{ verdict = $verdict; new = $eN; last = $eP; overlap = $overlap; newRun = $newRun; lastRun = $pRun
      rubric_why = 'same'; restricted = $null; restricted_why = ''; counted_last = $null
      line = ('RATE-VS-LAST verdict=' + $verdict + ' scope=' + $eN.scope + ' new=' + (Format-RunRate $eN) + ' last=' + (Format-RunRate $eP) + $ovTxt + $rubTxt) }
  }
  $why = if ($shaN -eq '' -or $shaP -eq '') { 'not-recorded' } else { 'differs' }
  $lc = $null
  if ($rP -and $rP.PSObject.Properties['counts'] -and $null -ne $rP.counts) { $lc = [string[]]@(@($rP.counts) | ForEach-Object { [string]$_ }) }
  $eR = $null; $rWhy = ''
  if ($null -eq $lc -or $lc.Count -eq 0) {
    $rWhy = $(if ($shaP -eq '') { 'the last run recorded no rubric, so which subclasses it counted is unknown' } else { 'the last rubric names no counted subclasses' })
  } else {
    $noSub = @(@($newRun.verdicts) | Where-Object { ($DEFECT -contains [string]$_.verdict) -and -not ($_.PSObject.Properties['subclass'] -and [string]$_.subclass) }).Count
    if ($noSub -gt 0) { $rWhy = ([string]$noSub + ' defect row(s) of this run carry no subclass') }
    else { $eR = Get-RunEstimate $newRun $minSamples $lc }
  }
  $lfl = if ($eR) { (Format-RunRate $eR) + ' counting only ' + ($lc -join '/') } else { 'not-computable (' + $rWhy + ')' }
  return [pscustomobject]@{ verdict = 'rubric-changed'; new = $eN; last = $eP; overlap = $overlap; newRun = $newRun; lastRun = $pRun
    rubric_why = $why; restricted = $eR; restricted_why = $rWhy; counted_last = $lc
    line = ('RATE-VS-LAST verdict=rubric-changed why=' + $why + ' scope=' + $eN.scope + ' new=' + (Format-RunRate $eN) + ' last=' + (Format-RunRate $eP) +
            ' like_for_like=' + $lfl + $ovTxt + $rubTxt + ' (measured under different rules: the two whole-board rates are NOT compared)') }
}

function Get-RunRubric($run) {
  # The rubric a run recorded, or $null: every run recorded before 2026-09-19, and a run whose notes had no section.
  if ($null -eq $run -or -not $run.PSObject.Properties['rubric']) { return $null }
  $r = $run.rubric
  if ($null -eq $r -or -not $r.PSObject.Properties['rules_sha'] -or -not ([string]$r.rules_sha)) { return $null }
  return $r
}

function Get-RubricFromText([string]$text, [string]$notesName) {
  # The rubric is the BODY of the section headed exactly "Adjudication standard" (any level): from that heading to
  # the next heading of the same or a higher level, each line trimmed (a copy indented inside a list hashes the
  # same), LF-joined, outer blank lines dropped. The heading line is not hashed, and a heading that says more
  # ("Adjudication standard applied, <date> sample") is not the section, so run-specific text (dates, coverage,
  # examples) cannot move the sha of unchanged rules.
  $lines = @(([string]$text) -split "`r?`n")
  $start = -1; $level = 0
  for ($i = 0; $i -lt $lines.Count; $i++) {
    $m = [regex]::Match($lines[$i], '^\s{0,3}(#{1,6})\s*Adjudication standard\s*:?\s*$', 'IgnoreCase')
    if ($m.Success) { $start = $i; $level = $m.Groups[1].Value.Length; break }
  }
  if ($start -lt 0) { return $null }
  $body = New-Object System.Collections.ArrayList
  for ($j = $start + 1; $j -lt $lines.Count; $j++) {
    $h = [regex]::Match($lines[$j], '^\s{0,3}(#{1,6})\s')
    if ($h.Success -and $h.Groups[1].Value.Length -le $level) { break }
    [void]$body.Add($lines[$j].Trim())
  }
  $norm = (($body.ToArray()) -join "`n").Trim()
  if ($norm.Length -eq 0) { return $null }
  $hasher = [Security.Cryptography.SHA256]::Create()
  $sha = ([BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($norm)))).Replace('-', '').ToLower()
  $ver = 0
  $mv = [regex]::Match($norm, '(?im)^[\s*_]*Rubric version[\s*_]*:[\s*_]*(\d+)')
  if ($mv.Success) { $ver = [int]$mv.Groups[1].Value }
  $counts = $null
  $mc = [regex]::Match($norm, '(?im)^[\s*_]*Counted subclasses[\s*_]*:(.+)$')
  if ($mc.Success) {
    $counts = [string[]]@((($mc.Groups[1].Value) -replace '[`*_.]', '') -split ',' | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
  }
  return [pscustomobject]@{ notes = $notesName; rules_sha = $sha; version = $ver; counts = $counts }
}

function Get-SubclassBreakdown($run) {
  # "channel 15, identity 15 (30 defect(s) in 100 verified)": the defects by subclass WITH their denominator, one
  # cell once at its last verdict as Get-RunEstimate counts it. A run recorded before subclasses says so.
  $latest = @{}
  foreach ($v in @($run.verdicts)) { $latest[([string]$v.id) + '|' + ([string]$v.store)] = $v }
  $n = 0; $x = 0; $none = 0; $by = @{}
  foreach ($v in $latest.Values) {
    $vd = [string]$v.verdict
    if ($vd -eq 'unverifiable') { continue }
    $n++
    if ($DEFECT -notcontains $vd) { continue }
    $x++
    $sc = ''; if ($v.PSObject.Properties['subclass']) { $sc = [string]$v.subclass }
    if ($sc -eq '') { $none++; continue }
    if ($by.ContainsKey($sc)) { $by[$sc]++ } else { $by[$sc] = 1 }
  }
  $parts = @($by.Keys | Sort-Object @{ Expression = { $by[$_] }; Descending = $true }, @{ Expression = { $_ } } | ForEach-Object { $_ + ' ' + $by[$_] })
  if ($none -gt 0) { $parts += ('no subclass recorded ' + $none) }
  $lead = if ($parts.Count -gt 0) { $parts -join ', ' } else { 'none' }
  return ($lead + ' (' + $x + ' defect(s) in ' + $n + ' verified)')
}

function Test-RateAlertOwed($cmp) {
  # Brad's trigger is unchanged (this run's point estimate above the last one); a changed rubric changes what the
  # mail SAYS, never whether it is sent.
  if ($null -eq $cmp) { return $false }
  if ($cmp.verdict -eq 'worse') { return $true }
  if ($cmp.verdict -eq 'rubric-changed' -and $null -ne $cmp.new -and $null -ne $cmp.last -and $cmp.new.p -gt $cmp.last.p) { return $true }
  return $false
}

function Invoke-RateAlert($cmp, [scriptblock]$Sender) {
  # Brad's rule: alert when the rate exceeds the last measured one. The mail says whether the two intervals
  # overlap, because a higher point inside overlapping intervals is not evidence the board got worse. Under a
  # changed or unrecorded rubric the subject says so instead of "is above the last measured" (2026-09-19).
  if (-not (Test-RateAlertOwed $cmp)) { return [pscustomobject]@{ attempted = $false; sent = $false; rc = $null; detail = ''; subject = '' } }
  $pN = '{0:N1}%' -f (100.0 * $cmp.new.p); $pL = '{0:N1}%' -f (100.0 * $cmp.last.p)
  $isRub = ($cmp.verdict -eq 'rubric-changed')
  if ($isRub) {
    $lead = if ($cmp.rubric_why -eq 'differs') { 'rubric changed' } else { 'rubric not recorded' }
    $subj = 'Board verification: ' + $lead + '; ' + $pN + ' this run against ' + $pL + ' last run, ' +
      $(if ($cmp.restricted) { ('{0:N1}%' -f (100.0 * $cmp.restricted.p)) + ' like for like' } else { 'no like-for-like rate' })
  } else {
    $subj = 'Board verification: defect rate ' + $pN + ' is above the last measured ' + $pL
  }
  $bNew = 'not available'; if ($cmp.PSObject.Properties['newRun'] -and $cmp.newRun) { $bNew = Get-SubclassBreakdown $cmp.newRun }
  $bLast = 'not available'; if ($cmp.PSObject.Properties['lastRun'] -and $cmp.lastRun) { $bLast = Get-SubclassBreakdown $cmp.lastRun }
  $body = @(
    $(if ($isRub) { 'The 14-day out-of-band verification adjudicated this run under a different rubric from the last run (' + $cmp.rubric_why + '), so the two whole-board rates are NOT like for like and are not compared.' }
      else { 'The 14-day out-of-band verification measured a higher whole-board defect rate than the last run.' }),
    '',
    ('  this run : ' + (Format-RunRate $cmp.new)),
    ('  last run : ' + (Format-RunRate $cmp.last)),
    $(if ($isRub) { '  like for like (this run, counting only the subclasses the last rubric counted): ' + $(if ($cmp.restricted) { Format-RunRate $cmp.restricted } else { 'not computable: ' + $cmp.restricted_why }) } else { '' }),
    '',
    ('Defects by subclass, this run: ' + $bNew),
    ('Defects by subclass, last run: ' + $bLast),
    '',
    $(if ($cmp.overlap) { 'The two 95% intervals OVERLAP, so this is not evidence on its own that the board got worse; it is a higher point estimate.' }
      else { 'The two 95% intervals do NOT overlap: the board measured worse than last time beyond sampling noise.' }),
    '',
    'Scope: ' + $cmp.new.scope + '. Source: grocery\record-sample-verdict.ps1 -CompareLast over grocery\out\verification-history.json.'
  ) -join "`n"
  # THE SEND'S OWN ANSWER DECIDES WHAT IS SAID (2026-09-19). The sender's LAST output is its exit code; everything
  # before it is what the sender said (alert-lib's ALERT FAILED TO SEND line). Until this date the result was piped
  # to Out-Null and the caller printed "ALERT sent" regardless: on 2026-09-19 at 05:49 the mail failed for want of
  # the OAuth client file in a worktree, and this script said sent and exited 0. A sender that answers nothing, or
  # throws, has not sent, because nothing says it did.
  $rc = 9; $detail = ''
  try {
    $got = @(& $Sender $subj $body)
    $last = $null; if ($got.Count -gt 0) { $last = $got[$got.Count - 1] }
    $parsed = 0
    if ($null -ne $last -and [int]::TryParse(([string]$last).Trim(), [ref]$parsed)) {
      $rc = $parsed
      if ($got.Count -gt 1) { $detail = ((@($got[0..($got.Count - 2)]) | ForEach-Object { [string]$_ }) -join ' | ') }
    } else {
      $detail = 'the sender answered no exit code' + $(if ($got.Count -gt 0) { ': ' + ((@($got) | ForEach-Object { [string]$_ }) -join ' | ') } else { '' })
    }
  } catch {
    $detail = 'the sender threw: ' + ((([string]$_.Exception.Message) -split "`r?`n")[0]).Trim()
  }
  return [pscustomobject]@{ attempted = $true; sent = ($rc -eq 0); rc = $rc; detail = $detail; subject = $subj }
}

function Get-VerifyDue($runs, [int]$minSamples, [int]$dueDays, [datetime]$now) {
  # A verification is owed when the newest WHOLE-BOARD run that could quote a rate was recorded $dueDays or more
  # days ago. A run that could not look (under the floor) does NOT reset the clock: a browser that was not there
  # must never buy two weeks of silence.
  $best = $null; $bestAt = [datetime]::MinValue
  foreach ($r in @($runs)) {
    if ((Get-VerifyRunScope $r) -ne 'whole-board') { continue }
    $e = Get-RunEstimate $r $minSamples
    if (-not $e.quotable) { continue }
    $at = [datetime]::MinValue
    if (-not [datetime]::TryParse([string]$r.recorded_at, [ref]$at)) { continue }
    if ($at -gt $bestAt) { $bestAt = $at; $best = $r }
  }
  if ($null -eq $best) { return [pscustomobject]@{ due = $true; age_days = -1; line = 'VERIFY-DUE due=yes reason=no-quotable-whole-board-run-on-record' } }
  $age = ($now - $bestAt).TotalDays
  $isDue = ($age -ge $dueDays)
  return [pscustomobject]@{ due = $isDue; age_days = $age
    line = ('VERIFY-DUE due=' + $(if ($isDue) { 'yes' } else { 'no' }) + ' newest_quotable_board=' + [string]$best.board_date + ' recorded_at=' + [string]$best.recorded_at +
            ' age_days=' + ('{0:N1}' -f $age) + ' due_after_days=' + $dueDays) }
}

# ---- SELF-TEST ------------------------------------------------------------------------------------------
if ($SelfTest) {
  $stPass = 0; $stFail = 0
  function RsvCase([string]$label, [bool]$cond, [string]$detail) {
    if ($cond) { $script:stPass++; Write-Output ('  PASS ' + $label) }
    else { $script:stFail++; Write-Output ('  FAIL ' + $label + ' :: ' + $detail) }
  }
  $liveHist = Join-Path $outDir 'verification-history.json'
  $liveHash = if (Test-Path -LiteralPath $liveHist) { (Get-FileHash -LiteralPath $liveHist -Algorithm SHA256).Hash } else { 'absent' }
  $stDir = Join-Path $env:TEMP ('rsv-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
  New-Item -ItemType Directory -Path $stDir -ErrorAction Stop | Out-Null
  try {
    # --- pure: the verdict mapping -----------------------------------------------------------------------
    $m1 = ConvertTo-RecordedVerdict 'could-not-look' ''
    RsvCase 'MUST FIRE could-not-look records as unverifiable, never ok' ($m1.verdict -eq 'unverifiable' -and -not $m1.demoted) ('got ' + $m1.verdict + ' demoted=' + $m1.demoted)
    # A could-not-look that still carries a price (a delivery-mode price the verifier could not use) must not
    # lean on the no-price rule: two guards over one rule leave each unfixtured, so this case has no blank.
    $m1b = ConvertTo-RecordedVerdict 'could-not-look' '3.99'
    RsvCase 'MUST FIRE could-not-look with a price on the row still records as unverifiable' ($m1b.verdict -eq 'unverifiable') ('got ' + $m1b.verdict)
    $m2 = ConvertTo-RecordedVerdict 'match' ''
    RsvCase 'MUST FIRE a match with no price the verifier saw records as unverifiable' ($m2.verdict -eq 'unverifiable' -and $m2.demoted) ('got ' + $m2.verdict + ' demoted=' + $m2.demoted)
    $m3 = ConvertTo-RecordedVerdict 'ok' '  '
    RsvCase 'MUST FIRE a legacy ok with a blank price records as unverifiable' ($m3.verdict -eq 'unverifiable') ('got ' + $m3.verdict)
    $m4 = ConvertTo-RecordedVerdict 'match' '2.49'
    RsvCase 'CLEAN TWIN a match with a seen price records as ok' ($m4.verdict -eq 'ok' -and -not $m4.demoted) ('got ' + $m4.verdict)
    $m5 = ConvertTo-RecordedVerdict 'wrong-price' ''
    RsvCase 'CLEAN TWIN a defect verdict is kept as written' ($m5.verdict -eq 'wrong-price') ('got ' + $m5.verdict)

    # --- end to end: the real recorder over a sealed key, into a temp history --------------------------
    $cells = @()
    for ($i = 0; $i -lt 40; $i++) {
      $cells += [pscustomobject]@{ ticket = ('T{0:D2}' -f $i); seq = ($i + 1); id = ('c{0:D2}' -f $i); label = 'Fixture'; unit = 'lb'; store = 'Fixture-Mart'
        stratum = $(if ($i -lt 20) { 'crown' } else { 'noncrown' }); board_item = 'Fixture item'; board_size = '1 lb'; board_ad = ''; board_per_unit = 2.49; board_type = 'regular' }
    }
    $keyObj = [pscustomobject]@{ schema = 1; board_date = '2099-01-01'; board_file = 'comparison-2099-01-01.json'; drawn_at = '2099-01-01T00:00:00'; seed = '2099-01-01'
      crown_share = 0.5; n_requested = 40; n_drawn = 40; store_scope = 'whole-board'; population = 2000
      strata = [pscustomobject]@{ crown = [pscustomobject]@{ population = 400; sampled = 20 }; noncrown = [pscustomobject]@{ population = 1600; sampled = 20 } }
      cells = $cells }
    $keyPath = Join-Path $stDir 'verification-sample-2099-01-01.json'
    [IO.File]::WriteAllText($keyPath, ($keyObj | ConvertTo-Json -Depth 6 -Compress), (New-Object System.Text.UTF8Encoding($false)))
    function FxVerdictFile([string]$path, [scriptblock]$rowFor) {
      $ls = New-Object System.Collections.ArrayList
      [void]$ls.Add('# fixture verdict file')
      [void]$ls.Add('ticket,seq,commodity,unit,store,verdict,found_product,found_price,note')
      for ($i = 0; $i -lt 40; $i++) {
        $vp = & $rowFor $i
        [void]$ls.Add('"' + ('T{0:D2}' -f $i) + '",' + ($i + 1) + ',"Fixture","lb","Fixture-Mart",' + $vp[0] + ',"Fixture item","' + $vp[1] + '",')
      }
      [IO.File]::WriteAllText($path, (($ls.ToArray()) -join "`r`n") + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    }
    # 30 matches with a seen price, 5 matches with NO price, 5 could-not-look.
    $vf1 = Join-Path $stDir 'verification-worklist-2099-01-01.csv'
    FxVerdictFile $vf1 { param($i) if ($i -lt 30) { ,@('match', '2.49') } elseif ($i -lt 35) { ,@('match', '') } else { ,@('could-not-look', '') } }
    $h1 = Join-Path $stDir 'hist-1.json'
    $o1 = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -VerdictFile $vf1 -SampleFile $keyPath -HistoryFile $h1 | ForEach-Object { [string]$_ })
    $rc1 = $LASTEXITCODE
    $hj1 = $null
    if (Test-Path -LiteralPath $h1) { $hj1 = (Get-Content -LiteralPath $h1 -Raw -Encoding UTF8) | ConvertFrom-Json }
    $rec1 = @(); if ($hj1) { $rec1 = @(@($hj1.runs)[0].verdicts) }
    $okT = @($rec1 | Where-Object { $_.verdict -eq 'ok' } | ForEach-Object { [string]$_.ticket } | Sort-Object)
    $badOk = @($rec1 | Where-Object { $_.verdict -eq 'ok' -and ([int]($_.ticket.Substring(1))) -ge 30 })
    RsvCase 'MUST FIRE end to end: no could-not-look and no unpriced match is recorded as ok' ($rec1.Count -eq 40 -and $badOk.Count -eq 0) ('recorded=' + $rec1.Count + ' wrongly-ok=' + $badOk.Count + ' rc=' + $rc1)
    RsvCase 'MUST FIRE end to end: the 10 that could not look leave the denominator' ((($o1 -join "`n") -match 'verified rows   : 30 ') -and @($rec1 | Where-Object { $_.verdict -eq 'unverifiable' }).Count -eq 10) ('out: ' + (($o1 | Where-Object { $_ -match 'verified rows' }) -join ' | '))
    RsvCase 'MUST FIRE end to end: the demotion is spoken, not silent' ((($o1 -join "`n") -match '5 match/ok verdict\(s\) carried no price')) ('out: ' + ($o1 -join ' | '))
    RsvCase 'CLEAN TWIN end to end: the 30 priced matches are recorded as ok and a rate is quoted (exit 0)' ($rc1 -eq 0 -and $okT.Count -eq 30 -and ($okT[0] -eq 'T00') -and ($okT[29] -eq 'T29')) ('rc=' + $rc1 + ' ok=' + $okT.Count)
    # every row a match with no price: nothing verified, nothing quoted, exit 3
    $vf2 = Join-Path $stDir 'verification-worklist-2099-01-01-b.csv'
    FxVerdictFile $vf2 { param($i) ,@('match', '') }
    $h2 = Join-Path $stDir 'hist-2.json'
    $o2 = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -VerdictFile $vf2 -SampleFile $keyPath -HistoryFile $h2 | ForEach-Object { [string]$_ })
    $rc2 = $LASTEXITCODE
    $hj2 = $null; if (Test-Path -LiteralPath $h2) { $hj2 = (Get-Content -LiteralPath $h2 -Raw -Encoding UTF8) | ConvertFrom-Json }
    $ok2 = 0; if ($hj2) { $ok2 = @(@(@($hj2.runs)[0].verdicts) | Where-Object { $_.verdict -eq 'ok' }).Count }
    RsvCase 'MUST FIRE forty unpriced matches quote no rate (exit 3) and record zero ok' ($rc2 -eq 3 -and $ok2 -eq 0 -and $null -ne $hj2) ('rc=' + $rc2 + ' ok=' + $ok2)

    # --- rate against the last measured one ------------------------------------------------------------
    # Every fixture run carries rubric 'fx-rubric-a' unless told otherwise, so the cases written before rubrics
    # existed keep asking what they always asked: one rubric, compare the rates.
    function New-FxRun([string]$date, [string]$scope, [int]$nC, [int]$xC, [int]$nN, [int]$xN, [int]$unv, [string]$recordedAt, [string]$Sha = 'fx-rubric-a', [string]$CrownSub = 'drift') {
      $vs = @(); $k = 0
      for ($i = 0; $i -lt $nC; $i++) { $k++; $vs += [pscustomobject]@{ id = ('r' + $k); store = 'S'; stratum = 'crown'; verdict = $(if ($i -lt $xC) { 'wrong-price' } else { 'ok' }); subclass = $(if ($i -lt $xC) { $CrownSub } else { '' }) } }
      for ($i = 0; $i -lt $nN; $i++) { $k++; $vs += [pscustomobject]@{ id = ('r' + $k); store = 'S'; stratum = 'noncrown'; verdict = $(if ($i -lt $xN) { 'wrong-product' } else { 'ok' }); subclass = $(if ($i -lt $xN) { 'identity' } else { '' }) } }
      for ($i = 0; $i -lt $unv; $i++) { $k++; $vs += [pscustomobject]@{ id = ('r' + $k); store = 'S'; stratum = 'noncrown'; verdict = 'unverifiable'; subclass = '' } }
      $rub = $null
      if ($Sha) {
        $cnt = if ($Sha -eq 'fx-rubric-a') { [string[]]@('drift', 'identity', 'not-cheapest', 'size') } else { [string[]]@('drift', 'channel', 'not-listed', 'not-cheapest', 'identity', 'size', 'multi-buy', 'other') }
        $rub = [pscustomobject]@{ notes = 'fixture'; rules_sha = $Sha; version = 1; counts = $cnt }
      }
      return [pscustomobject]@{ board_date = $date; store_scope = $scope; recorded_at = $recordedAt; rubric = $rub
        strata = [pscustomobject]@{ crown = [pscustomobject]@{ population = 500 }; noncrown = [pscustomobject]@{ population = 1500 } }; verdicts = $vs }
    }
    $rA = New-FxRun '2099-01-01' 'whole-board' 50 5 50 5 0 '2099-01-02T08:00:00'
    $rWorse = New-FxRun '2099-01-15' 'whole-board' 50 15 50 15 0 '2099-01-16T08:00:00'
    $rBetter = New-FxRun '2099-01-15' 'whole-board' 50 1 50 1 0 '2099-01-16T08:00:00'
    $rScoped = New-FxRun '2099-01-08' 'Aldi' 50 1 50 1 0 '2099-01-09T08:00:00'
    $rThin = New-FxRun '2099-01-10' 'whole-board' 5 0 5 0 90 '2099-01-11T08:00:00'
    $cW = Get-RateVsLast @($rA, $rScoped, $rThin, $rWorse) 30
    RsvCase 'MUST FIRE a higher rate than the last measured run reads worse' ($cW.verdict -eq 'worse' -and $cW.last.board_date -eq '2099-01-01') ($cW.line)
    RsvCase 'MUST FIRE the last measured run skips another scope and a run that could not quote' ($cW.last.board_date -eq '2099-01-01') ($cW.line)
    $cB = Get-RateVsLast @($rA, $rBetter) 30
    RsvCase 'MUST NOT FIRE a lower rate than the last measured run reads not-worse' ($cB.verdict -eq 'not-worse') ($cB.line)
    $c1 = Get-RateVsLast @($rA) 30
    RsvCase 'MUST NOT FIRE one run alone has nothing to compare against' ($c1.verdict -eq 'no-previous') ($c1.line)
    $cT = Get-RateVsLast @($rA, $rThin) 30
    RsvCase 'MUST NOT FIRE a newest run under the floor quotes no comparison' ($cT.verdict -eq 'not-quotable') ($cT.line)
    $sent = New-Object System.Collections.ArrayList
    $sender = { param($s, $b) [void]$sent.Add($s + '|' + $b); 0 }
    $a1 = Invoke-RateAlert $cW $sender
    RsvCase 'MUST FIRE a worse rate sends exactly one alert naming both rates' ($a1.attempted -and $a1.sent -and $sent.Count -eq 1 -and $sent[0] -match '2099-01-15' -and $sent[0] -match '2099-01-01') ('sent=' + $sent.Count + ' res.sent=' + $a1.sent)
    $a2 = Invoke-RateAlert $cB $sender
    RsvCase 'MUST NOT FIRE a not-worse rate sends nothing' ((-not $a2.attempted) -and $sent.Count -eq 1) ('sent=' + $sent.Count)

    # --- the send's own answer decides what is said (2026-09-19) ----------------------------------------
    # The failing sender speaks exactly as alert-lib's Send-Alert does on a failed send: its line, then its code.
    $failSender = { param($s, $b) 'ALERT FAILED TO SEND [VERIFY-RATE] - send-alert.ps1 exited 1.'; 1 }
    $f1 = Invoke-RateAlert $cW $failSender
    RsvCase 'MUST FIRE a sender that exits 1 reads NOT sent, with its own words carried' ($f1.attempted -and -not $f1.sent -and $f1.rc -eq 1 -and $f1.detail -match 'ALERT FAILED TO SEND') ('sent=' + $f1.sent + ' rc=' + $f1.rc + ' detail=' + $f1.detail)
    $f2 = Invoke-RateAlert $cW { param($s, $b) throw 'Cannot find path google-oauth-client.json' }
    RsvCase 'MUST FIRE a sender that throws reads NOT sent, naming the throw' ((-not $f2.sent) -and $f2.detail -match 'google-oauth-client') ('sent=' + $f2.sent + ' detail=' + $f2.detail)
    $f3 = Invoke-RateAlert $cW { param($s, $b) }
    RsvCase 'MUST FIRE a sender that answers nothing reads NOT sent, never sent' ((-not $f3.sent) -and $f3.detail -match 'no exit code') ('sent=' + $f3.sent + ' detail=' + $f3.detail)
    $f4 = Invoke-RateAlert $cW { param($s, $b) 'alert emailed'; 0 }
    RsvCase 'CLEAN TWIN a sender that exits 0 reads sent' ($f4.sent -and $f4.rc -eq 0) ('sent=' + $f4.sent + ' rc=' + $f4.rc)

    # --- a rate is compared only with a rate adjudicated under the same rubric (2026-09-19, queue 641ec6) ----
    # Founding case: 2026-09-17 read 37.1% against 2026-08-15's 18.2% and mailed "is above the last measured",
    # while 24 of its 36 defects came from five rules the older notes never stated.
    RsvCase 'CLEAN TWIN one rubric on both runs keeps the comparison and its "is above the last measured" subject' ($cW.verdict -eq 'worse' -and $sent[0] -match 'is above the last measured' -and $cW.line -match 'new_rubric=fx-rubric-a') ($cW.line)
    $rB = New-FxRun '2099-01-15' 'whole-board' 50 15 50 15 0 '2099-01-16T08:00:00' -Sha 'fx-rubric-b' -CrownSub 'channel'
    $cR = Get-RateVsLast @($rA, $rB) 30
    RsvCase 'MUST FIRE a higher rate under a DIFFERENT rubric reads rubric-changed, never worse' ($cR.verdict -eq 'rubric-changed' -and $cR.rubric_why -eq 'differs') ($cR.line)
    $rx = -1; if ($cR.restricted) { $rx = [int]$cR.restricted.x }
    RsvCase 'MUST FIRE the like-for-like rate counts only the subclasses the last rubric counted (15 identity of 30 defects; channel is not one)' ($rx -eq 15 -and $cR.new.x -eq 30 -and $cR.restricted.n -eq 100) ('restricted.x=' + $rx + ' new.x=' + $cR.new.x)
    $sentR = New-Object System.Collections.ArrayList
    $aR = Invoke-RateAlert $cR { param($s, $b) [void]$sentR.Add($s + '|' + $b); 0 }
    $jR = ''; if ($sentR.Count -gt 0) { $jR = [string]$sentR[0] }
    RsvCase 'MUST FIRE a rubric change mails "rubric changed" with both rates and the like-for-like rate, never "is above the last measured"' ($aR.sent -and $sentR.Count -eq 1 -and $aR.subject -match 'rubric changed' -and $aR.subject -match 'like for like' -and $jR -notmatch 'is above the last measured' -and $jR -match '2099-01-15' -and $jR -match '2099-01-01') ('sent=' + $sentR.Count + ' subject=' + $aR.subject)
    RsvCase 'MUST FIRE the mail body carries the defects by subclass with their denominator' ($jR -match 'channel 15' -and $jR -match 'identity 15' -and $jR -match '30 defect\(s\) in 100 verified') ('body=' + $jR)
    $rNone = New-FxRun '2099-01-15' 'whole-board' 50 15 50 15 0 '2099-01-16T08:00:00' -Sha ''
    $cN = Get-RateVsLast @($rA, $rNone) 30
    RsvCase 'MUST FIRE a run with no recorded rubric is never compared like for like (rubric-changed, not-recorded)' ($cN.verdict -eq 'rubric-changed' -and $cN.rubric_why -eq 'not-recorded') ($cN.line)
    # the rubric is the BODY of "## Adjudication standard" and nothing else: not the H1 that carries the date, not
    # the coverage section, not trailing blanks, not the line endings
    $nt1 = "# Adjudication standard applied, 2099-01-01 sample`n`n## Adjudication standard`nRubric version: 2`nCounted subclasses: identity, size, not-cheapest`n- not-cheapest is wrong-price   `n`n## Coverage`n40 of 40 answered.`n"
    $nt2 = "# Adjudication standard applied, 2099-01-15 sample`r`n`r`n   ## Adjudication standard`r`n   Rubric version: 2`r`n   Counted subclasses: identity, size, not-cheapest`r`n   - not-cheapest is wrong-price`r`n`r`n## Coverage`r`n12 of 40 answered on another day.`r`n"
    $nt3 = $nt1.Replace('- not-cheapest is wrong-price', ('- not-cheapest is wrong-price' + "`n" + '- a drifted price is wrong-price'))
    $g1 = Get-RubricFromText $nt1 'n1'; $g2 = Get-RubricFromText $nt2 'n2'; $g3 = Get-RubricFromText $nt3 'n3'
    $g1s = 'null'; if ($g1) { $g1s = [string]$g1.rules_sha + ' v' + $g1.version + ' counts=' + (@($g1.counts) -join ',') }
    RsvCase 'CLEAN TWIN the same standard under another date, other coverage and CRLF reads the same sha, version and counts' ($null -ne $g1 -and $null -ne $g2 -and $g1.rules_sha -eq $g2.rules_sha -and $g1.version -eq 2 -and (@($g1.counts) -join ',') -eq 'identity,size,not-cheapest') ('g1=' + $g1s)
    RsvCase 'MUST FIRE one added rule changes the rubric sha' ($null -ne $g3 -and $null -ne $g1 -and $g3.rules_sha -ne $g1.rules_sha) ('g1=' + $g1s)
    $g4 = Get-RubricFromText "# Adjudication standard applied, 2099-01-01 sample`n`n## Coverage`nall answered`n" 'n4'
    RsvCase 'MUST FIRE notes whose only match is the dated H1 record no rubric' ($null -eq $g4) ('got a rubric from notes with no section')
    # end to end through the real recorder: a defect needs a subclass, and the run records its rubric
    $notesFx = Join-Path $stDir 'fx-notes.md'
    [IO.File]::WriteAllText($notesFx, $nt1, (New-Object System.Text.UTF8Encoding($false)))
    $vf3 = Join-Path $stDir 'verification-worklist-2099-01-01-c.csv'
    FxVerdictFile $vf3 { param($i) if ($i -lt 30) { ,@('match', '2.49') } elseif ($i -lt 35) { ,@('wrong-price', '2.99') } else { ,@('wrong-product', '1.99') } }
    $h3 = Join-Path $stDir 'hist-3.json'
    $o3 = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -VerdictFile $vf3 -SampleFile $keyPath -HistoryFile $h3 -RubricNotes $notesFx | ForEach-Object { [string]$_ })
    $rc3 = $LASTEXITCODE
    RsvCase 'MUST FIRE end to end: ten defect rows with no subclass are REFUSED (exit 1) and nothing is written' ($rc3 -eq 1 -and -not (Test-Path -LiteralPath $h3) -and (($o3 -join "`n") -match '10 defect row\(s\) carry no subclass')) ('rc=' + $rc3 + ' out: ' + ($o3 -join ' | '))
    $dl = @('ticket,verdict,subclass')
    for ($i = 30; $i -lt 40; $i++) { $dl += ('T{0:D2},{1},{2}' -f $i, $(if ($i -lt 35) { 'wrong-price' } else { 'wrong-product' }), $(if ($i -lt 35) { 'drift' } else { 'identity' })) }
    $dec4 = Join-Path $stDir 'fx-decisions.csv'
    [IO.File]::WriteAllText($dec4, (($dl -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    $h4 = Join-Path $stDir 'hist-4.json'
    $o4 = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -VerdictFile $vf3 -SampleFile $keyPath -HistoryFile $h4 -RubricNotes $notesFx -DecisionsFile $dec4 | ForEach-Object { [string]$_ })
    $rc4 = $LASTEXITCODE
    $run4 = $null; if (Test-Path -LiteralPath $h4) { $run4 = @(((Get-Content -LiteralPath $h4 -Raw -Encoding UTF8) | ConvertFrom-Json).runs)[0] }
    $sub4 = @(); $sha4 = ''
    if ($run4) { $sub4 = @(@($run4.verdicts) | Where-Object { [string]$_.subclass -ne '' } | ForEach-Object { [string]$_.subclass }); if ($run4.rubric) { $sha4 = [string]$run4.rubric.rules_sha } }
    RsvCase 'CLEAN TWIN end to end: with a decisions subclass column each defect records its subclass and the run records its rubric sha' ($rc4 -eq 0 -and $sub4.Count -eq 10 -and @($sub4 | Where-Object { $_ -eq 'identity' }).Count -eq 5 -and $null -ne $g1 -and $sha4 -eq $g1.rules_sha) ('rc=' + $rc4 + ' subclasses=' + $sub4.Count + ' sha=' + $sha4 + ' out: ' + (($o4 | Select-Object -Last 3) -join ' | '))
    $dec5 = Join-Path $stDir 'fx-decisions-bad.csv'
    [IO.File]::WriteAllText($dec5, (((@($dl[0..9]) + @('T39,wrong-product,mystery')) -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    $h5 = Join-Path $stDir 'hist-5.json'
    $o5 = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -VerdictFile $vf3 -SampleFile $keyPath -HistoryFile $h5 -RubricNotes $notesFx -DecisionsFile $dec5 | ForEach-Object { [string]$_ })
    $rc5 = $LASTEXITCODE
    RsvCase 'MUST FIRE end to end: a subclass outside the vocabulary is REFUSED (exit 1), never recorded' ($rc5 -eq 1 -and -not (Test-Path -LiteralPath $h5) -and (($o5 -join "`n") -match 'mystery')) ('rc=' + $rc5 + ' out: ' + ($o5 -join ' | '))

    # --- the -Alert path end to end, through the real script and a fixture alert-lib -------------------
    $hAl = Join-Path $stDir 'hist-alert.json'
    [IO.File]::WriteAllText($hAl, ([pscustomobject]@{ schema = 1; runs = @($rA, $rWorse) } | ConvertTo-Json -Depth 7 -Compress), (New-Object System.Text.UTF8Encoding($false)))
    function New-FxAlertLib([string]$path, [int]$code) {
      $src = 'function Send-Alert { param([string]$Subject, [string]$Body, [string]$What)' + "`r`n" +
             $(if ($code -ne 0) { '  Write-Output ''ALERT FAILED TO SEND [fixture] - send-alert.ps1 exited ' + $code + '.''' + "`r`n" } else { '' }) +
             '  $global:LASTEXITCODE = ' + $code + '; return ' + $code + ' }' + "`r`n"
      [IO.File]::WriteAllText($path, $src, (New-Object System.Text.UTF8Encoding($false)))
    }
    $libFail = Join-Path $stDir 'alert-lib-fail.ps1'; New-FxAlertLib $libFail 1
    $libOk = Join-Path $stDir 'alert-lib-ok.ps1'; New-FxAlertLib $libOk 0
    $oF = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Report -CompareLast -Alert -HistoryFile $hAl -AlertLib $libFail | ForEach-Object { [string]$_ })
    $rcF = $LASTEXITCODE; $jF = $oF -join "`n"
    RsvCase 'MUST FIRE end to end: a failed send prints ALERT NOT SENT, never "sent", and exits 4' ($rcF -eq 4 -and $jF -match 'ALERT NOT SENT' -and $jF -notmatch 'ALERT sent' -and $jF -notmatch 'ALERT accepted') ('rc=' + $rcF + ' out: ' + (($oF | Where-Object { $_ -match 'ALERT' }) -join ' | '))
    RsvCase 'MUST FIRE end to end: the report still prints in full after a failed send' ($jF -match 'WHOLE BOARD') ('no WHOLE BOARD line, rc=' + $rcF)
    $oS = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Report -CompareLast -Alert -HistoryFile $hAl -AlertLib $libOk | ForEach-Object { [string]$_ })
    $rcS = $LASTEXITCODE; $jS = $oS -join "`n"
    RsvCase 'CLEAN TWIN end to end: a send that exits 0 is reported accepted and the run exits 0' ($rcS -eq 0 -and $jS -match 'ALERT accepted by send-alert' -and $jS -notmatch 'NOT SENT') ('rc=' + $rcS + ' out: ' + (($oS | Where-Object { $_ -match 'ALERT' }) -join ' | '))

    # --- is a verification owed? -------------------------------------------------------------------------
    $now = [datetime]'2099-01-20T08:00:00'
    $d1 = Get-VerifyDue @($rA) 30 13 $now
    RsvCase 'CLEAN TWIN a quotable run 18 days old makes a verification due' ($d1.due) ($d1.line)
    $d2 = Get-VerifyDue @($rA, $rBetter) 30 13 $now
    RsvCase 'MUST NOT FIRE a quotable run 4 days old is not due' (-not $d2.due) ($d2.line)
    $rThinNew = New-FxRun '2099-01-19' 'whole-board' 5 0 5 0 90 '2099-01-19T12:00:00'
    $d3 = Get-VerifyDue @($rA, $rThinNew) 30 13 $now
    RsvCase 'MUST FIRE a run that could not look does not reset the clock' ($d3.due) ($d3.line)
    $d4 = Get-VerifyDue @() 30 13 $now
    RsvCase 'MUST FIRE an empty history is due' ($d4.due) ($d4.line)

    $liveAfter = if (Test-Path -LiteralPath $liveHist) { (Get-FileHash -LiteralPath $liveHist -Algorithm SHA256).Hash } else { 'absent' }
    RsvCase 'the live verification history is byte-identical after the self-test' ($liveAfter -eq $liveHash) ('before=' + $liveHash + ' after=' + $liveAfter)
  } catch {
    $stFail++
    Write-Output ('  FAIL self-test threw: ' + $_.Exception.Message)
  } finally {
    Remove-Item -LiteralPath $stDir -Recurse -Force -ErrorAction SilentlyContinue
  }
  $stTotal = $stPass + $stFail
  if ($stFail -eq 0 -and $stTotal -eq 42) { Write-Output ('record-sample-verdict self-test: PASS (' + $stPass + ' of ' + $stTotal + ' cases)'); exit 0 }
  Write-Output ('record-sample-verdict self-test: FAIL (' + $stFail + ' failed, ' + $stPass + ' passed, ' + $stTotal + ' ran; 42 expected)')
  exit 1
}

# ---- is a verification owed? (read-only) -----------------------------------------------------------------
if ($Due) {
  $dh = $null
  if (Test-Path -LiteralPath $histPath) {
    $dt = ((Get-Content -LiteralPath $histPath -Raw -Encoding UTF8) + '')
    if ($dt.Trim().Length -gt 0) { $dh = $dt | ConvertFrom-Json }
  }
  $druns = @(); if ($null -ne $dh -and $null -ne $dh.runs) { $druns = @($dh.runs) }
  $dv = Get-VerifyDue $druns $MinSamples $DueDays (Get-Date)
  Write-Output $dv.line
  exit 0
}

function ReadJsonFile([string]$path) {
  # ((Get-Content -Raw) + '') because [string]$null is $null in 5.1 and .Trim() would throw on a zero-byte
  # file; and '' | ConvertFrom-Json returns $null WITHOUT throwing, so emptiness is tested by hand.
  if (-not (Test-Path $path)) { return $null }
  $t = ((Get-Content $path -Raw -Encoding UTF8) + '')
  if ($t.Trim().Length -eq 0) { return $null }
  return ($t | ConvertFrom-Json)
}
$enc = New-Object System.Text.UTF8Encoding($false)

# ---- 1. record a new set of verdicts --------------------------------------------------------------------
$hist = ReadJsonFile $histPath
if ($null -eq $hist -or $null -eq $hist.runs) { $hist = [pscustomobject]@{ schema = 1; runs = @() } }
$runs = @($hist.runs)

if (-not $Report) {
  if (-not $VerdictFile) { Say 'record-sample-verdict: -VerdictFile is required (or pass -Report to re-report from history).'; exit 1 }
  if (-not (Test-Path $VerdictFile)) { Say ('record-sample-verdict: verdict file not found: ' + $VerdictFile); exit 1 }
  $vtxt = ((Get-Content $VerdictFile -Raw -Encoding UTF8) + '')
  if ($vtxt.Trim().Length -eq 0) { Say ('record-sample-verdict: verdict file is EMPTY: ' + $VerdictFile); exit 1 }
  # strip the leading '#' preamble the worklist carries, then parse what is left as CSV
  $vlines = @($vtxt -split "`r?`n" | Where-Object { -not ($_ -match '^\s*#') -and $_.Trim().Length -gt 0 })
  if ($vlines.Count -lt 2) { Say 'record-sample-verdict: verdict file has a header but no rows.'; exit 1 }
  $vrows = @($vlines | ConvertFrom-Csv)
  if ($vrows.Count -eq 0) { Say 'record-sample-verdict: verdict file parsed to zero rows.'; exit 1 }
  if (-not ($vrows[0].PSObject.Properties.Name -contains 'ticket') -or -not ($vrows[0].PSObject.Properties.Name -contains 'verdict')) {
    Say 'record-sample-verdict: verdict file needs at least a ticket column and a verdict column.'; exit 1
  }

  if (-not $SampleFile) {
    $mD = [regex]::Match([IO.Path]::GetFileNameWithoutExtension($VerdictFile), '(\d{4}-\d{2}-\d{2})$')
    if ($mD.Success) { $SampleFile = Join-Path $outDir ('verification-sample-' + $mD.Groups[1].Value + '.json') }
  }
  $key = ReadJsonFile $SampleFile
  if ($null -eq $key -or $null -eq $key.cells) {
    Say ('record-sample-verdict: cannot open the sealed key for this worklist (' + $SampleFile + ').')
    Say '  Without it there is no stratum, no population and no board answer to adjudicate against, so'
    Say '  nothing can be scored. Re-run build-verification-sample.ps1 with the same seed to regenerate it.'
    exit 1
  }
  $byTicket = @{}
  foreach ($c in @($key.cells)) { $byTicket[[string]$c.ticket] = $c }

  # ---- where each defect's subclass and the run's rubric come from (2026-09-19, queue 2026-09-19-641ec6) ----
  # Both default to the adjudicator's own files beside the verdict file, named for the board date in its name.
  $vDate = ''
  $mV = [regex]::Match([IO.Path]::GetFileNameWithoutExtension($VerdictFile), '(\d{4}-\d{2}-\d{2})$')
  if ($mV.Success) { $vDate = $mV.Groups[1].Value }
  $vDir = Split-Path -Parent $VerdictFile
  if (-not $vDir) { $vDir = '.' }
  if (-not $DecisionsFile -and $vDate) { $DecisionsFile = Join-Path $vDir ('verification-decisions-' + $vDate + '.csv') }
  if (-not $RubricNotes -and $vDate) { $RubricNotes = Join-Path $vDir ('verification-decisions-' + $vDate + '-notes.md') }
  $vHasSub = ($vrows[0].PSObject.Properties.Name -contains 'subclass')
  $subByTicket = @{}
  if (-not $vHasSub -and $DecisionsFile -and (Test-Path -LiteralPath $DecisionsFile)) {
    $dtx = ((Get-Content -LiteralPath $DecisionsFile -Raw -Encoding UTF8) + '')
    $dls = @($dtx -split "`r?`n" | Where-Object { -not ($_ -match '^\s*#') -and $_.Trim().Length -gt 0 })
    if ($dls.Count -ge 2) {
      $drs = @($dls | ConvertFrom-Csv)
      if ($drs.Count -gt 0 -and ($drs[0].PSObject.Properties.Name -contains 'subclass')) {
        foreach ($d in $drs) { $dt = ([string]$d.ticket).Trim(); if ($dt) { $subByTicket[$dt] = ([string]$d.subclass).Trim().ToLower() } }
      }
    }
  }

  $recorded = New-Object System.Collections.ArrayList
  $bad = New-Object System.Collections.ArrayList
  $demotedT = New-Object System.Collections.ArrayList
  $blank = 0
  foreach ($v in $vrows) {
    $t = ([string]$v.ticket).Trim()
    $verd = ([string]$v.verdict).Trim().ToLower()
    if ($t -eq '') { continue }
    if ($verd -eq '') { $blank++; continue }
    if ($VALID -notcontains $verd) { [void]$bad.Add($t + ' -> "' + $verd + '"'); continue }
    $c = $byTicket[$t]
    if ($null -eq $c) { [void]$bad.Add($t + ' -> not in the sealed key for this board'); continue }
    $canon = ConvertTo-RecordedVerdict $verd ([string]$v.found_price)
    if ($canon.demoted) { [void]$demotedT.Add($t) }
    $verd = $canon.verdict
    [void]$recorded.Add([pscustomobject]@{
      ticket = $t; id = [string]$c.id; label = [string]$c.label; store = [string]$c.store
      stratum = [string]$c.stratum; verdict = $verd
      found_product = ([string]$v.found_product).Trim()
      found_price = ([string]$v.found_price).Trim()
      note = ([string]$v.note).Trim()
      board_item = [string]$c.board_item; board_per_unit = $c.board_per_unit
      subclass = $(if ($vHasSub) { ([string]$v.subclass).Trim().ToLower() } elseif ($subByTicket.ContainsKey($t)) { [string]$subByTicket[$t] } else { '' })
    })
  }
  if ($bad.Count -gt 0) {
    Say ('record-sample-verdict: ' + $bad.Count + ' row(s) could not be read and were NOT recorded:')
    foreach ($b in $bad.ToArray()) { Say ('    ' + $b) }
    Say ('  valid verdicts: ' + ($VALID -join ' | '))
  }
  if ($recorded.Count -eq 0) { Say 'record-sample-verdict: ZERO usable verdicts in that file - nothing recorded, nothing proved.'; exit 1 }
  # THE SUBCLASS IS A CLOSED VOCABULARY AND EVERY DEFECT CARRIES ONE. The whole recording is refused rather than
  # the row dropped: a dropped defect understates the rate, and an unknown word falls out of every like-for-like rate.
  $noSub = New-Object System.Collections.ArrayList
  $badSub = New-Object System.Collections.ArrayList
  foreach ($rr in $recorded.ToArray()) {
    $sc = [string]$rr.subclass
    if ($sc -ne '' -and $SUBCLASS -notcontains $sc) { [void]$badSub.Add(([string]$rr.ticket) + ' -> "' + $sc + '"'); continue }
    if ($sc -eq '' -and $DEFECT -contains ([string]$rr.verdict)) { [void]$noSub.Add([string]$rr.ticket) }
  }
  if ($noSub.Count -gt 0 -or $badSub.Count -gt 0) {
    if ($noSub.Count -gt 0) { Say ('record-sample-verdict: REFUSED - ' + $noSub.Count + ' defect row(s) carry no subclass: ' + ((@($noSub.ToArray()) | Sort-Object) -join ', ')) }
    if ($badSub.Count -gt 0) { Say ('record-sample-verdict: REFUSED - ' + $badSub.Count + ' row(s) carry a subclass outside the vocabulary: ' + ((@($badSub.ToArray())) -join '; ')) }
    Say ('  vocabulary: ' + ($SUBCLASS -join ' | ') + '. Give every defect row one, in a subclass column on the verdict file or on the decisions file (' + $(if ($DecisionsFile) { $DecisionsFile } else { 'none named or derivable' }) + ').')
    Say '  Nothing was recorded: a defect with no subclass cannot be compared across rubrics, and dropping it would understate the rate.'
    exit 1
  }
  $rubric = $null
  if ($RubricNotes -and (Test-Path -LiteralPath $RubricNotes)) {
    $rubric = Get-RubricFromText ((Get-Content -LiteralPath $RubricNotes -Raw -Encoding UTF8) + '') ([IO.Path]::GetFileName($RubricNotes))
  }
  if ($null -ne $rubric -and $null -ne $rubric.counts) {
    $badC = @(@($rubric.counts) | Where-Object { $SUBCLASS -notcontains [string]$_ })
    if ($badC.Count -gt 0) { Say ('record-sample-verdict: REFUSED - the rubric''s Counted subclasses line names word(s) outside the vocabulary: ' + ($badC -join ', ') + ' (vocabulary: ' + ($SUBCLASS -join ' | ') + '). Nothing was recorded.'); exit 1 }
  }
  if ($null -eq $rubric) {
    $why = if (-not $RubricNotes) { 'no notes file was named or derivable from the verdict file name' } elseif (-not (Test-Path -LiteralPath $RubricNotes)) { $RubricNotes + ' does not exist' } else { $RubricNotes + ' has no section headed exactly "## Adjudication standard"' }
    Say ('record-sample-verdict: NO RUBRIC RECORDED - ' + $why + '. This run will never be compared like for like with any other.')
  } else {
    Say ('record-sample-verdict: rubric ' + $rubric.rules_sha.Substring(0, 12) + ' (version ' + $rubric.version + ', from ' + $rubric.notes + ')' +
      $(if ($null -eq $rubric.counts) { ' - it names no Counted subclasses, so no later run can compute a like-for-like rate against it' } else { ', counting ' + (@($rubric.counts) -join '/') }))
  }
  if ($blank -gt 0) { Say ('record-sample-verdict: ' + $blank + ' row(s) left blank - recorded as NOT YET VERIFIED, not as ok.') }
  if ($demotedT.Count -gt 0) {
    Say ('record-sample-verdict: ' + $demotedT.Count + ' match/ok verdict(s) carried no price the verifier saw - recorded as COULD-NOT-LOOK (unverifiable), never as a match: ' +
      ((@($demotedT.ToArray()) | Sort-Object) -join ', '))
  }

  $newRun = [pscustomobject]@{
    board_date  = [string]$key.board_date
    seed        = [string]$key.seed
    recorded_at = (Get-Date -Format 's')
    n_drawn     = [int]$key.n_drawn
    n_recorded  = $recorded.Count
    population  = [int]$key.population
    # A run older than the -Store flag has no scope recorded; it was necessarily a whole-board draw.
    store_scope = $(if ($key.PSObject.Properties['store_scope'] -and [string]$key.store_scope) { [string]$key.store_scope } else { 'whole-board' })
    strata      = $key.strata
    rubric      = $rubric
    verdicts    = $recorded.ToArray()
  }
  $keep = New-Object System.Collections.ArrayList
  $replaced = $false
  foreach ($r in $runs) {
    if ([string]$r.board_date -eq [string]$key.board_date) { $replaced = $true; continue }
    [void]$keep.Add($r)
  }
  [void]$keep.Add($newRun)
  $runs = $keep.ToArray()
  $hist = [pscustomobject]@{ schema = 1; runs = @($runs | Sort-Object board_date) }
  # -Compress: this file is APPEND-FOREVER and tracked. Indented it costs 82 KB per weekly run (4.2 MB a
  # year of git); compressed, 25 KB (1.3 MB). It is machine-read; any JSON reader pretty-prints it.
  [IO.File]::WriteAllText($histPath, ($hist | ConvertTo-Json -Depth 7 -Compress), $enc)
  Say ('record-sample-verdict: recorded ' + $recorded.Count + ' verdict(s) for the ' + $key.board_date + ' board' + $(if ($replaced) { ' (REPLACED the previous recording for that date)' } else { '' }))
  Say ('  history: ' + @($hist.runs).Count + ' run(s), ' + ('{0:N0}' -f ((Get-Item $histPath).Length / 1kb)) + ' KB')
  $runs = @($hist.runs)
}

if ($runs.Count -eq 0) { Say 'record-sample-verdict: verification history is EMPTY - no sample has ever been verified, so there is NO out-of-band statement about this board. That is not a clean bill of health.'; exit 3 }

# THE ALERT OUTRANKS THE REPORT'S OWN EXIT (2026-09-19). A rise Brad is owed a mail about and did not get is exit 4,
# whatever the pooled report below would have exited: 0 and 3 both read as 'nothing to do' to the scheduled agent.
$script:alertNotSent = $false
function Exit-Rsv([int]$code) { if ($script:alertNotSent) { exit 4 }; exit $code }

# ---- 1b. this run against the LAST measured rate (I232) -------------------------------------------------
# Printed before the pooled report so an exit 3 there cannot swallow it; -Alert mails Brad only on 'worse'.
if ($CompareLast) {
  $cmpLast = Get-RateVsLast $runs $MinSamples
  Say ''
  Say $cmpLast.line
  if ($cmpLast.PSObject.Properties['newRun'] -and $cmpLast.newRun) { Say ('  defects by subclass, this run: ' + (Get-SubclassBreakdown $cmpLast.newRun)) }
  if ($cmpLast.PSObject.Properties['lastRun'] -and $cmpLast.lastRun) { Say ('  defects by subclass, last run: ' + (Get-SubclassBreakdown $cmpLast.lastRun)) }
  if ($Alert -and (Test-RateAlertOwed $cmpLast)) {
    . $(if ($AlertLib) { $AlertLib } else { Join-Path $root 'alert-lib.ps1' })
    # Send-Alert's output ends with its exit code; Invoke-RateAlert reads it rather than trusting the call.
    $liveSender = { param($s, $b) Send-Alert -Subject $s -Body $b -What 'VERIFY-RATE' }
    $alertRes = Invoke-RateAlert $cmpLast $liveSender
    if ($alertRes.sent) {
      # exit 0 from send-alert means the alert is durable in the triage queue and was mailed unless today's
      # once-per-type gate, a mute or its registry class held the mail back; its log says which.
      Say ('  ALERT accepted by send-alert (exit 0): "' + $alertRes.subject + '". The mail line is in grocery\alert-log.txt.')
    } else {
      $script:alertNotSent = $true
      Say ('  ALERT NOT SENT (send exit ' + $alertRes.rc + '): "' + $alertRes.subject + '". Brad has NOT been told the rate rose.')
      if ($alertRes.detail) { Say ('    ' + $alertRes.detail) }
      Say '    Send it by hand from the MAIN checkout, then read grocery\alert-log.txt there. This run exits 4.'
    }
  }
}

# ---- 2. pool the last K weeks ---------------------------------------------------------------------------
$dates = @($runs | ForEach-Object { [string]$_.board_date } | Where-Object { $_ -match '^\d{4}-\d{2}-\d{2}$' })
if ($dates.Count -eq 0) { Say 'record-sample-verdict: history holds no run with a usable board_date - cannot pool.'; Exit-Rsv 3 }
$newest = [datetime]($dates | Sort-Object -Descending | Select-Object -First 1)
$cutoff = $newest.AddDays(-7 * $PoolWeeks)
$pool = @($runs | Where-Object { $_.board_date -match '^\d{4}-\d{2}-\d{2}$' -and ([datetime]$_.board_date) -gt $cutoff })
if ($pool.Count -eq 0) { $pool = @($runs | Select-Object -Last 1) }

# POOL ONLY WHAT ESTIMATES THE SAME POPULATION (2026-08-02). A store-scoped draw and a whole-board draw
# are samples of DIFFERENT populations; averaging them yields a number that describes neither. Measured the
# first time a scoped sample was recorded: an Aldi+Fareway run pooled into the previous whole-board run and
# reported 14 defects - Sam's Club, Hy-Vee, Family Fare and Walmart cells among them - against a 760-cell
# Aldi+Fareway denominator, i.e. a numerator drawn from outside its own denominator.
# The NEWEST run in the window decides the scope; older runs of a different scope are dropped and NAMED,
# never silently averaged in.
function RunScope($r) { if ($r.PSObject.Properties['store_scope'] -and [string]$r.store_scope) { return [string]$r.store_scope } return 'whole-board' }
$poolSorted = @($pool | Sort-Object { [datetime]$_.board_date })
$scopeWanted = RunScope $poolSorted[$poolSorted.Count - 1]
$dropScope = @($pool | Where-Object { (RunScope $_) -ne $scopeWanted })
if ($dropScope.Count -gt 0) {
  $pool = @($pool | Where-Object { (RunScope $_) -eq $scopeWanted })
  Say ('record-sample-verdict: pooling only the ' + $scopeWanted + ' run(s). DROPPED ' + $dropScope.Count +
    ' run(s) drawn from a different population (' + ((@($dropScope | ForEach-Object { $_.board_date + '=' + (RunScope $_) }) | Sort-Object -Unique) -join ', ') +
    ') - a scoped sample and a whole-board sample estimate different things and must not be averaged.')
}

# THE BOARD BARELY MOVES: 99.3% of cells are byte-identical day to day, so pooling weeks re-verifies many of
# the SAME cells. A cell verified more than once inside the pool is counted ONCE, at its most recent verdict -
# otherwise a cell someone checked four weeks running would carry four times the weight of its neighbours and
# the "n" would be an inflated count of work, not of information.
$latest = @{}
foreach ($r in ($pool | Sort-Object board_date)) {
  foreach ($v in @($r.verdicts)) {
    $k = ([string]$v.id) + '|' + ([string]$v.store)
    $latest[$k] = [pscustomobject]@{ stratum = [string]$v.stratum; verdict = [string]$v.verdict; store = [string]$v.store; id = [string]$v.id; label = [string]$v.label; board_item = [string]$v.board_item; date = [string]$r.board_date }
  }
}
$rowsAll = @($latest.Values)
$dupes = 0
foreach ($r in $pool) { $dupes += @($r.verdicts).Count }
$dupes = $dupes - $rowsAll.Count

# populations come from the NEWEST run - the estimate is about TODAY's board, not an average of old ones
$newestRun = @($pool | Sort-Object board_date | Select-Object -Last 1)[0]
$popCrown = 0; $popNon = 0
if ($newestRun.strata) {
  if ($newestRun.strata.crown)    { $popCrown = [int]$newestRun.strata.crown.population }
  if ($newestRun.strata.noncrown) { $popNon   = [int]$newestRun.strata.noncrown.population }
}
$popAll = $popCrown + $popNon
if ($popAll -le 0) { Say 'record-sample-verdict: the newest run records no stratum populations - cannot reweight to a whole-board rate.'; Exit-Rsv 3 }

function Tally($rows, [string]$stratum) {
  $n = 0; $x = 0; $unv = 0
  foreach ($r in $rows) {
    if ($stratum -ne '' -and ([string]$r.stratum) -ne $stratum) { continue }
    if (([string]$r.verdict) -eq 'unverifiable') { $unv++; continue }
    $n++
    if ($DEFECT -contains ([string]$r.verdict)) { $x++ }
  }
  return [pscustomobject]@{ n = $n; x = $x; unverifiable = $unv }
}
$tC = Tally $rowsAll 'crown'
$tN = Tally $rowsAll 'noncrown'
$tAll = Tally $rowsAll ''

# ---- 3. report ------------------------------------------------------------------------------------------
function Pct([double]$v) { return ('{0:N1}%' -f (100.0 * $v)) }
Say ''
Say ('record-sample-verdict: OUT-OF-BAND VERIFICATION, pooled over the last ' + $PoolWeeks + ' week(s) (' + $pool.Count + ' sample run(s), boards ' + (@($pool | ForEach-Object { $_.board_date }) -join ', ') + ')')
Say ('  board population: ' + $popAll + ' priced cells (' + $popCrown + ' crown, ' + $popNon + ' non-crown)')
Say ('  verified rows   : ' + $tAll.n + '   unverifiable (dropped from the denominator): ' + $tAll.unverifiable + $(if ($dupes -gt 0) { '   deduped repeat verifications: ' + $dupes } else { '' }))

$unvTotal = $tAll.unverifiable + $tAll.n
if ($unvTotal -gt 0 -and ($tAll.unverifiable / [double]$unvTotal) -gt 0.20) {
  $byStoreU = @{}
  foreach ($r in $rowsAll) { if (([string]$r.verdict) -eq 'unverifiable') { $s = [string]$r.store; if ($byStoreU.ContainsKey($s)) { $byStoreU[$s]++ } else { $byStoreU[$s] = 1 } } }
  Say ('  WARNING: ' + (Pct ($tAll.unverifiable / [double]$unvTotal)) + ' of the draw could not be verified at all, so every number below is about the VERIFIABLE part of the board only.')
  foreach ($kv in ($byStoreU.GetEnumerator() | Sort-Object Value -Descending)) { Say ('           unverifiable at ' + $kv.Key + ': ' + $kv.Value) }
}

if (-not (Test-CanQuoteRate $tAll.n $MinSamples)) {
  $w = Get-WilsonInterval $tAll.x $tAll.n
  Say ''
  Say ('  NO RATE QUOTED. ' + $tAll.n + ' verified row(s) is under the -MinSamples floor of ' + $MinSamples + '.')
  if ($tAll.n -gt 0) {
    Say ('  All that can honestly be said: ' + $tAll.x + ' defect(s) in ' + $tAll.n + ' verified cells, which is consistent with a true rate anywhere from ' + (Pct $w.lo) + ' to ' + (Pct $w.hi) + '.')
    Say ('  That interval is ' + ('{0:N1}' -f (100.0 * ($w.hi - $w.lo))) + ' points wide. It cannot distinguish a good board from a bad one.')
  } else {
    Say '  Not one row was verifiable. This run proved NOTHING about the board.'
  }
  Say ('  Verify at least ' + ($MinSamples - $tAll.n) + ' more cell(s) from the current worklist, then re-run.')
  Exit-Rsv 3
}

$strata = @(
  [pscustomobject]@{ name = 'crown';    population = $popCrown; n = $tC.n; x = $tC.x },
  [pscustomobject]@{ name = 'noncrown'; population = $popNon;   n = $tN.n; x = $tN.x }
)
$st = Get-StratifiedEstimate $strata
$wC = Get-WilsonInterval $tC.x $tC.n
$wN = Get-WilsonInterval $tN.x $tN.n
$wRaw = Get-WilsonInterval $tAll.x $tAll.n

Say ''
Say '  CROWN cells (the cheapest-store cell - what a shopper actually drives to):'
if ($tC.n -gt 0) { Say ('    ' + $tC.x + ' defect(s) in ' + $tC.n + ' verified   ->  95% CI ' + (Pct $wC.lo) + ' to ' + (Pct $wC.hi) + '   (point ' + (Pct $wC.p) + ', +/-' + ('{0:N1}' -f (100.0 * $wC.half)) + ' pts)') }
else { Say '    ZERO crown cells verified - this pool says NOTHING about the crowns, which is the half that matters most.' }
Say '  NON-CROWN cells:'
if ($tN.n -gt 0) { Say ('    ' + $tN.x + ' defect(s) in ' + $tN.n + ' verified   ->  95% CI ' + (Pct $wN.lo) + ' to ' + (Pct $wN.hi) + '   (point ' + (Pct $wN.p) + ', +/-' + ('{0:N1}' -f (100.0 * $wN.half)) + ' pts)') }
else { Say '    ZERO non-crown cells verified - the whole-board figure below carries their entire weight as pure uncertainty.' }

Say ''
Say '  WHOLE BOARD (population-reweighted - this is the only number that describes the board):'
Say ('    ' + (Pct $st.p) + '   95% CI ' + (Pct $st.lo) + ' to ' + (Pct $st.hi) + '   [conservative combination of the two stratum intervals]')
Say ('    design-based normal interval, for comparison: +/-' + ('{0:N1}' -f (100.0 * $st.nWald)) + ' pts (narrower; it under-states at small defect counts - quote the conservative one)')
Say ('    NOT the same as the raw sample fraction ' + $tAll.x + '/' + $tAll.n + ' = ' + (Pct $wRaw.p) + ', which estimates nothing: the draw over-samples crowns on purpose.')

# ---- 4. what would it take to resolve this -------------------------------------------------------------
$pPlan = $st.p
if ($pPlan -le 0) { $pPlan = $st.hi }        # at zero observed defects, plan against the upper bound, not against 0
$needed = Get-RequiredN $pPlan $TargetHalfWidth $popAll
$curHalf = ($st.hi - $st.lo) / 2.0
Say ''
Say ('  RESOLUTION: the whole-board interval is currently +/-' + ('{0:N1}' -f (100.0 * $curHalf)) + ' points on ' + $tAll.n + ' verified cells.')
if ($needed -lt 0) {
  Say ('    -TargetHalfWidth ' + $TargetHalfWidth + ' is not a reachable target; pass a positive width.')
} else {
  Say ('    To reach +/-' + ('{0:N1}' -f (100.0 * $TargetHalfWidth)) + ' points at a ' + (Pct $pPlan) + ' rate needs about ' + $needed + ' verified cells of ' + $popAll + ' (you have ' + $tAll.n + '); ' + [Math]::Max(0, $needed - $tAll.n) + ' to go.')
  if ($needed -ge (0.5 * $popAll)) {
    Say ('    That is ' + ('{0:N0}' -f (100.0 * $needed / $popAll)) + '% of the whole board - at this board size and this rate, +/-' + ('{0:N1}' -f (100.0 * $TargetHalfWidth)) + ' points is a census in all but name, not a sampling target.')
    Say '    Sampling answers "roughly how bad, and is it getting better". It never answers "exactly how bad".'
  }
}
$n30 = Get-WilsonInterval ([int][Math]::Round(30 * $pPlan)) 30
$n100 = Get-WilsonInterval ([int][Math]::Round(100 * $pPlan)) 100
Say ('    For scale at this rate: n=30 gives +/-' + ('{0:N1}' -f (100.0 * $n30.half)) + ' pts, n=100 gives +/-' + ('{0:N1}' -f (100.0 * $n100.half)) + ' pts. That gap is the whole argument for drawing 100.')

# ---- 5. the defects themselves --------------------------------------------------------------------------
$defRows = @($rowsAll | Where-Object { $DEFECT -contains ([string]$_.verdict) })
if ($defRows.Count -gt 0) {
  Say ''
  Say ('  DEFECTS FOUND (' + $defRows.Count + ') - each one is a live wrong number on the published board, fix them individually:')
  foreach ($d in ($defRows | Sort-Object stratum, store)) {
    Say ('    [' + $d.verdict + '] ' + $d.id + ' @ ' + $d.store + ' (' + $d.stratum + ') - board says: ' + $d.board_item)
  }
}
Exit-Rsv 0

