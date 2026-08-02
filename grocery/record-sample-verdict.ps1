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
  publish on its own bug.
#>
param(
  [string]$VerdictFile = '',
  [string]$SampleFile = '',
  [int]$PoolWeeks = 4,
  [int]$MinSamples = 30,
  [double]$TargetHalfWidth = 0.01,
  [switch]$Report,
  [switch]$Quiet
)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$outDir = Join-Path $root 'out'
$histPath = Join-Path $outDir 'verification-history.json'
function Say([string]$s) { if (-not $Quiet) { Write-Output $s } }
$DEFECT = @('wrong-product', 'wrong-price', 'wrong-size', 'missing')
$VALID  = @('ok', 'wrong-product', 'wrong-price', 'wrong-size', 'missing', 'unverifiable')

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

  $recorded = New-Object System.Collections.ArrayList
  $bad = New-Object System.Collections.ArrayList
  $blank = 0
  foreach ($v in $vrows) {
    $t = ([string]$v.ticket).Trim()
    $verd = ([string]$v.verdict).Trim().ToLower()
    if ($t -eq '') { continue }
    if ($verd -eq '') { $blank++; continue }
    if ($VALID -notcontains $verd) { [void]$bad.Add($t + ' -> "' + $verd + '"'); continue }
    $c = $byTicket[$t]
    if ($null -eq $c) { [void]$bad.Add($t + ' -> not in the sealed key for this board'); continue }
    [void]$recorded.Add([pscustomobject]@{
      ticket = $t; id = [string]$c.id; label = [string]$c.label; store = [string]$c.store
      stratum = [string]$c.stratum; verdict = $verd
      found_product = ([string]$v.found_product).Trim()
      found_price = ([string]$v.found_price).Trim()
      note = ([string]$v.note).Trim()
      board_item = [string]$c.board_item; board_per_unit = $c.board_per_unit
    })
  }
  if ($bad.Count -gt 0) {
    Say ('record-sample-verdict: ' + $bad.Count + ' row(s) could not be read and were NOT recorded:')
    foreach ($b in $bad.ToArray()) { Say ('    ' + $b) }
    Say ('  valid verdicts: ' + ($VALID -join ' | '))
  }
  if ($recorded.Count -eq 0) { Say 'record-sample-verdict: ZERO usable verdicts in that file - nothing recorded, nothing proved.'; exit 1 }
  if ($blank -gt 0) { Say ('record-sample-verdict: ' + $blank + ' row(s) left blank - recorded as NOT YET VERIFIED, not as ok.') }

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

# ---- 2. pool the last K weeks ---------------------------------------------------------------------------
$dates = @($runs | ForEach-Object { [string]$_.board_date } | Where-Object { $_ -match '^\d{4}-\d{2}-\d{2}$' })
if ($dates.Count -eq 0) { Say 'record-sample-verdict: history holds no run with a usable board_date - cannot pool.'; exit 3 }
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
if ($popAll -le 0) { Say 'record-sample-verdict: the newest run records no stratum populations - cannot reweight to a whole-board rate.'; exit 3 }

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
  exit 3
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
exit 0

