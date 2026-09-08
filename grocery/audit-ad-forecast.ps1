<#
  audit-ad-forecast.ps1 - is the ad-cycle PREDICTION any good, and is it getting worse?

  WHAT THIS IS NOT. It is not a staleness check. `audit-ad-status.ps1` already
  answers "is a store's ad closed or its pull overdue RIGHT NOW", it exits 1 when
  one is, and the daily watchdog runs it. That layer exists and works. Building a
  second one would have been the obvious mistake and this file deliberately does
  not.

  WHAT IS ACTUALLY MISSING, and it is a different question. `ad-schedule.json`
  writes `next_pull` = the current window's `to` plus one day. That is a DATED
  PREDICTION, recorded before the event. The next `history` entry's `from` is the
  OBSERVED ANSWER, read out of the store's own feed. The two have sat one line
  apart in the same file since 2026-06-29 and nothing has ever compared them.

  THE METRIC, AND WHY IT IS NOT A MEAN. Scored by hand on 2026-09-08 the whole
  set is 37 of 47 exact with a mean absolute error of 0.47 days, and that number
  actively hides the thing that matters: two of the errors are a FULL +7 DAYS,
  where Aldi and Baker's each skipped an entire weekly cycle. A seven-day miss
  and seven one-day misses have the same mean. So this reports, per store:

    exact       the fraction landing on the day, which is the honest headline
    full miss   errors of a whole cadence or more, COUNTED SEPARATELY and never
                averaged into anything
    bias        early or late, because a store that predicts EARLY wastes a pull
                and one that predicts LATE serves a stale board

  Three different failure modes live in this data and one statistic showed none
  of them: Aldi and Baker's skip cycles, Fareway is wrong half the time but never
  by much, and Hy-Vee is the only store that predicts early.

  THE DECLARED CADENCE IS ALSO CHECKED AGAINST THE OBSERVED ONE. `cadence_days`
  is a hand-set constant, 7 for every store that has one. If a store's history
  says otherwise, the prediction will be wrong forever in the same direction and
  no amount of retrying fixes it. That is the preventive half.

  IT IS READ-ONLY. It reads `ad-schedule.json` and writes nothing. Every number
  comes from data already on disk.

  IT IS A RATCHET, AND THE RATCHET RUNS THE OTHER WAY. This estate's standing
  rule is not to add a gate that is red on day one: a red nobody can clear
  teaches people to ignore red. The usual answer is a high-water mark that may
  only go DOWN. That is the wrong shape here, and the difference is worth stating
  rather than copying the pattern blind.

  A full-cycle miss is HISTORY. It happened, it is in the file, and no amount of
  future work removes it - so a lifetime count can never legitimately fall, and a
  down-ratchet would never fire. Inverted, it is exactly the check wanted: the
  count may only STAY THE SAME, and any rise means a NEW cycle was skipped. The
  two misses on record today are the baseline and are silent. The third one fails
  the day it is detected, which is the whole point.

  A FALL IS NOT A PASS. If the count drops, history was rewritten or the reader
  broke. That exits 3, never 0.

  Exit 0 = no new full-cycle miss, and every declared cadence matches observation.
  Exit 2 = a NEW full-cycle miss, or an observed cadence that disagrees with the
           declared one. Hard finding.
  Exit 3 = could not evaluate: no schedule, no store with enough history, or the
           lifetime count fell. NEVER read 3 as a pass.

  Params: -ScheduleFile <path>, -Json, -Baseline <path>, -AcceptDrop (record a
          genuine history rewrite rather than refusing it).
#>
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop
param(
  [string]$ScheduleFile = '',
  [switch]$Json,
  [string]$Baseline = '',
  [switch]$AcceptDrop,
  [switch]$AcceptMiss,
  [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path -Parent $root
if (-not $ScheduleFile) { $ScheduleFile = Join-Path $root 'ad-schedule.json' }
if (-not $Baseline) { $Baseline = Join-Path $root 'ad-forecast-baseline.json' }
$gc = Join-Path $repo 'lib\guard-contract.ps1'
if (Test-Path $gc) { . $gc }

# THE BAR, WRITTEN HERE AND NOT DERIVED FROM THE RUN. A threshold chosen after
# seeing the number is a description of a decision already taken.
#   - A NEW full-cycle miss is a hard finding. A skipped weekly ad means the
#     board served a stale price for a week; there is no acceptable rate above
#     zero, and the ratchet is what lets that be true without being red today.
#   - An observed cadence differing from the declared one by more than a day is
#     a finding, because it will keep being wrong in the same direction and
#     retrying never fixes a constant that is set wrong.
$MAX_CADENCE_DRIFT_DAYS = 1

function Get-ForecastScore {
  <# SCORING, FACTORED OUT SO BOTH ARMS RUN THROUGH IT (2026-09-08, backlog I70).

     An error number with no baseline beside it means nothing. "37 of 47 exact" is not a
     verdict until something says what the DUMBEST predictor scores on the SAME pairs - and
     on a random-walk-ish series the naive forecast is provably optimal, so "we beat the
     naive forecast" is the only claim a forecaster can make that is worth anything.

     The naive predictor here is exact, free, and already in the file: the next ad drops
     `cadence_days` after the last one DID, read from history[i].from. The live rule is this
     window's `to` plus one day.

     This function exists so the two arms cannot differ by accident: same exact / full-miss /
     bias logic, one input, the error list. Pure, so the fixtures drive it.

     DEFINED ABOVE THE SELF-TEST ON PURPOSE. Placed below it, the fixtures throw
     CommandNotFoundException, the terminating error leaves $LASTEXITCODE at whatever it was,
     and the harness reads exit 0 off a suite that never ran a case. That happened once while
     this was being written, which is exit-code-first-tally-second arriving in its own file. #>
  param([int[]]$Errors, [int]$Cadence)
  if (@($Errors).Count -eq 0) { return @{ pairs = 0; exact = 0; full = 0; bias = $null } }
  return @{
    pairs = @($Errors).Count
    exact = @($Errors | Where-Object { $_ -eq 0 }).Count
    # A FULL MISS is an error of a whole cadence or more, in either direction. Never averaged.
    full  = @($Errors | Where-Object { [math]::Abs($_) -ge $Cadence }).Count
    bias  = [math]::Round(((@($Errors) | Measure-Object -Sum).Sum / @($Errors).Count), 2)
  }
}


if ($SelfTest) {
  # FROZEN FIXTURES. A gate nobody has seen go red is a gate nobody knows works,
  # and every one of these is a shape that actually occurred: the +7 skip is the
  # Aldi and Baker's case, the one-day slip is Fareway, the cadence drift is the
  # constant nobody re-derives. `ops\run-gates.ps1` runs this on every push.
  $tmp = Join-Path $env:TEMP ('adf-st-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $tmp | Out-Null
  $sf = Join-Path $tmp 'sched.json'; $bf = Join-Path $tmp 'base.json'
  $me = $PSCommandPath
  $pass = 0; $fails = New-Object System.Collections.ArrayList

  function _Sched($rowsIn) {
    $h = @(); foreach ($r in $rowsIn) { $h += @{ from = $r[0]; to = $r[1]; detected = $r[0] } }
    @{ updated = '2026-09-08'; stores = @(@{ store = 'TestMart'; method = 'server'
        cadence_days = 7; current = @{ from = $rowsIn[-1][0]; to = $rowsIn[-1][1] }
        next_pull = '2026-09-09'; history = $h }) } |
      ConvertTo-Json -Depth 6 | Set-Content $sf -Encoding UTF8
  }
  # A HASHTABLE splat, never an array: an array splat passes a switch
  # POSITIONALLY and CmdletBinding rejects it as an unbound argument.
  function _Run([hashtable]$extra = @{}) {
    $o = & $me -ScheduleFile $sf -Baseline $bf @extra 2>&1 | Out-String
    return @{ code = $LASTEXITCODE; out = $o }
  }
  function _Case($label, $name, $ok, $detail) {
    if ($ok) { $script:pass++ } else { [void]$script:fails.Add("$label $name") }
    Write-Output ("  {0,-14} {1,-56} {2}" -f $label, $name, $(if ($ok) { 'ok' } else { "FAIL $detail" }))
  }

  $clean = @(@('2026-08-01','2026-08-07'), @('2026-08-08','2026-08-14'),
             @('2026-08-15','2026-08-21'), @('2026-08-22','2026-08-28'))
  $missed = $clean + ,@('2026-09-05','2026-09-11')   # predicted 08-29, actual 09-05 = +7
  $slip   = $clean + ,@('2026-08-30','2026-09-05')   # predicted 08-29, actual 08-30 = +1

  _Sched $clean
  $r = _Run
  _Case 'MUST NOT FIRE' 'a clean history writes a baseline of 0 and exits 0' ($r.code -eq 0 -and $r.out -match 'BASELINE WRITTEN at 0') $r.code
  $r = _Run
  _Case 'MUST NOT FIRE' 'an unchanged history passes on the second run' ($r.code -eq 0 -and $r.out -match 'PASSED') $r.code

  _Sched $missed
  $r = _Run
  _Case 'MUST FIRE' 'a NEW full-cycle miss hard-fails with exit 2' ($r.code -eq 2 -and $r.out -match 'AD FORECAST FAILED') $r.code
  _Case 'MUST FIRE' 'and it names the store that skipped' ($r.out -match 'NEW\s+TestMart 0 -> 1') 'no NEW line'

  Remove-Item $bf -Force; _Sched $slip
  $r = _Run
  _Case 'MUST NOT FIRE' 'a one-day slip is NOT a full-cycle miss' ($r.code -eq 0 -and $r.out -match 'BASELINE WRITTEN at 0') $r.code

  # ------- THE NAIVE BASELINE ARM (2026-09-08, backlog I70). The fixtures pin BOTH arms, or the
  # second one rots quietly while the first keeps the suite green.
  $sc0 = Get-ForecastScore -Errors ([int[]]@(0, 0, 0)) -Cadence 7
  _Case 'MUST NOT FIRE' 'the shared scorer calls three zero errors 3 of 3, no full miss, bias 0' `
    ($sc0.exact -eq 3 -and $sc0.pairs -eq 3 -and $sc0.full -eq 0 -and $sc0.bias -eq 0) "exact=$($sc0.exact) full=$($sc0.full)"
  $sc1 = Get-ForecastScore -Errors ([int[]]@(0, 7, -7, 1)) -Cadence 7
  _Case 'MUST FIRE' 'a whole-cadence error in EITHER direction is a full miss, and is not averaged in' `
    ($sc1.full -eq 2 -and $sc1.exact -eq 1 -and $sc1.pairs -eq 4) "full=$($sc1.full) exact=$($sc1.exact)"
  $sc2 = Get-ForecastScore -Errors ([int[]]@()) -Cadence 7
  _Case 'MUST NOT FIRE' 'an EMPTY error list scores 0 of 0, never 1 of 1 - @($null).Count is 1 in PS 5.1' `
    ($sc2.pairs -eq 0 -and $sc2.exact -eq 0 -and $null -eq $sc2.bias) "pairs=$($sc2.pairs)"

  # On $clean the ad drops exactly cadence_days after the previous window OPENED and exactly one day
  # after it CLOSED, so both arms are perfect. That is the case the item was filed about: when the
  # arms tie, the live rule is buying nothing over a plain calendar, and the report must say so
  # rather than letting the live figure read as a win.
  Remove-Item $bf -Force; _Sched $clean
  $r = _Run
  _Case 'CLEAN TWIN' 'the report prints the naive arm with its OWN denominator beside the live one' `
    ($r.out -match "NAIVE BASELINE: \d+/\d+ exact, against the live rule's \d+/\d+") 'no NAIVE BASELINE line'
  _Case 'MUST FIRE' 'and it says out loud when the live rule is NOT beating the plain calendar' `
    ($r.out -match 'NOT beating a plain calendar') 'no not-beating note on a fixture where the arms tie'

  Remove-Item $bf -Force; _Sched $clean; _Run | Out-Null; _Sched $missed
  $r = _Run @{ AcceptMiss = $true }
  _Case 'MUST FIRE' '-AcceptMiss raises the baseline and clears the red' ($r.code -eq 0 -and $r.out -match 'ACCEPTED: baseline raised 0 -> 1') $r.code
  $r = _Run
  _Case 'MUST NOT FIRE' 'an acknowledged miss stays quiet on the next run' ($r.code -eq 0 -and $r.out -match 'PASSED') $r.code
  _Sched ($missed + ,@('2026-09-26','2026-10-02'))
  $r = _Run
  _Case 'MUST FIRE' 'the NEXT miss after an acknowledgement fails again' ($r.code -eq 2 -and $r.out -match 'AD FORECAST FAILED') $r.code

  Remove-Item $bf -Force; _Sched $clean
  @{ generated = '2026-09-08'; full_misses = 5; per_store = @{ TestMart = 5 }; note = 'test' } |
    ConvertTo-Json -Depth 4 | Set-Content $bf -Encoding UTF8
  $r = _Run
  _Case 'MUST FIRE' 'a FALL is refused with exit 3, never passed' ($r.code -eq 3 -and $r.out -match 'COULD NOT EVALUATE') $r.code
  $r = _Run @{ AcceptDrop = $true }
  _Case 'CLEAN TWIN' '-AcceptDrop records a genuine fall deliberately' ($r.code -eq 0 -and $r.out -match 'baseline lowered') $r.code

  Remove-Item $bf -Force
  _Sched @(@('2026-08-01','2026-08-14'), @('2026-08-15','2026-08-28'), @('2026-08-29','2026-09-11'))
  $r = _Run
  _Case 'MUST FIRE' 'an observed cadence contradicting the declared one fails' ($r.code -eq 2 -and $r.out -match 'CADENCE DRIFT') $r.code

  Remove-Item $bf -Force
  @{ updated = '2026-09-08'; stores = @(@{ store = 'NoCycle'; method = 'browser'
      cadence_days = $null; current = $null; next_pull = $null; history = @() }) } |
    ConvertTo-Json -Depth 6 | Set-Content $sf -Encoding UTF8
  $r = _Run
  _Case 'MUST FIRE' 'a store with no cycle exits 3, never 0 on an empty score' ($r.code -eq 3 -and $r.out -match 'COULD NOT EVALUATE') $r.code

  Remove-Item $tmp -Recurse -Force
  Write-Output ''
  $total = $pass + $fails.Count
  if ($fails.Count) {
    Write-Output ("SELF-TEST FAIL: {0} case(s) of {1}" -f $fails.Count, $total)
    foreach ($f in $fails) { Write-Output ("  " + $f) }
    exit 1
  }
  Write-Output ("ad-forecast self-test: {0} of {0} cases pass" -f $total)
  exit 0
}

if (-not (Test-Path $ScheduleFile)) {
  Write-Output "COULD NOT EVALUATE - no schedule at $ScheduleFile."
  Write-Output "That is not 'the forecast is fine': nothing was measured."
  Write-Output 'AD-FORECAST-COMPLETE'
  exit 3
}

# -Encoding utf8 is not enough on the read side: this file carries a BOM and a
# plain read leaves it on the first character, which breaks the JSON parse.
$sched = (Get-Content -LiteralPath $ScheduleFile -Raw -Encoding UTF8).TrimStart([char]0xFEFF) | ConvertFrom-Json

function DT([string]$s) { [datetime]::ParseExact($s, 'yyyy-MM-dd', $null) }

$rows = New-Object System.Collections.ArrayList
$scored = 0

foreach ($s in $sched.stores) {
  $store = [string]$s.store
  $cadence = $s.cadence_days
  $hist = @($s.history)

  # A store with no cycle is EXCLUDED, never scored zero. Sam's and Walmart
  # carry a null cadence because they have no weekly ad; counting them as
  # perfect or as failures would both be lies.
  if ($null -eq $cadence -or $hist.Count -lt 2) {
    [void]$rows.Add([pscustomobject]@{
      store = $store; scored = $false; reason = $(if ($null -eq $cadence) { 'no weekly ad cycle' } else { "only $($hist.Count) history entries" })
      pairs = 0; exact = 0; full_misses = 0; bias = $null
      naive_pairs = 0; naive_exact = 0; naive_full_misses = 0; naive_bias = $null
      observed_cadence = $null; declared_cadence = $cadence; drift = $null
      recent_full_misses = 0; verdict = 'not scored' })
    continue
  }

  $errs = New-Object System.Collections.ArrayList
  $naiveErrs = New-Object System.Collections.ArrayList
  $gaps = New-Object System.Collections.ArrayList
  for ($i = 0; $i -lt $hist.Count - 1; $i++) {
    $a = $hist[$i]; $b = $hist[$i + 1]
    if (-not $a.to -or -not $b.from) { continue }
    # THE PREDICTION, reconstructed exactly as check-ad-cycles writes it:
    # next_pull = this window's `to` plus one day.
    $predicted = (DT ([string]$a.to)).AddDays(1)
    $actual    = DT ([string]$b.from)
    [void]$errs.Add([int]($actual - $predicted).TotalDays)
    # THE NAIVE BASELINE over the SAME pair (I70): the next ad drops cadence_days after the
    # last one DID. Skipped only when this window has no `from` to count from, so the two arms
    # can legitimately differ in `pairs` - which is why the report prints BOTH denominators.
    if ($a.from) { [void]$naiveErrs.Add([int]($actual - (DT ([string]$a.from)).AddDays($cadence)).TotalDays) }
    # The OBSERVED cadence, window start to window start.
    if ($a.from) { [void]$gaps.Add([int]((DT ([string]$b.from)) - (DT ([string]$a.from))).TotalDays) }
  }

  if ($errs.Count -eq 0) {
    [void]$rows.Add([pscustomobject]@{
      store = $store; scored = $false; reason = 'no usable pairs'
      pairs = 0; exact = 0; full_misses = 0; bias = $null
      naive_pairs = 0; naive_exact = 0; naive_full_misses = 0; naive_bias = $null
      observed_cadence = $null; declared_cadence = $cadence; drift = $null
      recent_full_misses = 0; verdict = 'not scored' })
    continue
  }

  $scored++
  # BOTH ARMS THROUGH THE SAME FUNCTION, so they cannot differ by accident (I70).
  $live  = Get-ForecastScore -Errors ([int[]]@($errs))      -Cadence $cadence
  $naive = Get-ForecastScore -Errors ([int[]]@($naiveErrs)) -Cadence $cadence
  $exact = $live.exact
  $full  = $live.full
  $bias  = $live.bias

  # The observed cadence is the MEDIAN gap, not the mean: one skipped cycle
  # would drag a mean and invent a drift that is not there.
  $obs = $null; $drift = $null
  if ($gaps.Count -gt 0) {
    $sorted = @($gaps | Sort-Object)
    $obs = $sorted[[int][math]::Floor($sorted.Count / 2)]
    $drift = [math]::Abs($obs - $cadence)
  }

  $bad = @()
  if ($null -ne $drift -and $drift -gt $MAX_CADENCE_DRIFT_DAYS) { $bad += "observed cadence $obs d vs declared $cadence d" }

  [void]$rows.Add([pscustomobject]@{
    store = $store; scored = $true; reason = ''
    pairs = $errs.Count; exact = $exact; full_misses = $full; bias = $bias
    naive_pairs = $naive.pairs; naive_exact = $naive.exact; naive_full_misses = $naive.full; naive_bias = $naive.bias
    observed_cadence = $obs; declared_cadence = $cadence; drift = $drift
    verdict = $(if ($bad.Count) { ($bad -join '; ') } else { 'ok' }) })
}

if ($Json) { $rows | ConvertTo-Json -Depth 4; exit 0 }

if ($scored -eq 0) {
  Write-Output 'COULD NOT EVALUATE - no store has two history entries to compare.'
  Write-Output "That is not 'the forecast is fine': nothing was measured."
  Write-Output 'AD-FORECAST-COMPLETE'
  exit 3
}

Write-Output "AD FORECAST - is next_pull actually landing on the day the ad drops?"
Write-Output ''
Write-Output ("{0,-13} {1,9} {2,11} {3,6} {4,12} {5,9}" -f 'store', 'exact', 'FULL MISS', 'bias', 'NAIVE exact', 'cadence')
Write-Output ('-' * 70)
foreach ($r in $rows) {
  if (-not $r.scored) {
    Write-Output ("{0,-13} {1}" -f $r.store, "not scored - $($r.reason)")
    continue
  }
  $cad = if ($null -eq $r.observed_cadence) { '-' } else { "$($r.observed_cadence)/$($r.declared_cadence)" }
  Write-Output ("{0,-13} {1,9} {2,11} {3,6} {4,12} {5,9}" -f `
    $r.store, ("$($r.exact)/$($r.pairs)"), $r.full_misses, $r.bias, ("$($r.naive_exact)/$($r.naive_pairs)"), $cad)
}

$sc = @($rows | Where-Object { $_.scored })
$pairs = ($sc | Measure-Object -Property pairs -Sum).Sum
$ex    = ($sc | Measure-Object -Property exact -Sum).Sum
$fm    = ($sc | Measure-Object -Property full_misses -Sum).Sum
$nEx = ($sc | Measure-Object -Property naive_exact -Sum).Sum
$nPr = ($sc | Measure-Object -Property naive_pairs -Sum).Sum
Write-Output ('-' * 70)
Write-Output ("{0,-13} {1,9} {2,11} {3,6} {4,12}" -f 'ALL', "$ex/$pairs", $fm, '', "$nEx/$nPr")
Write-Output ''
Write-Output "Every rate carries its denominator. `exact` is the honest headline;"
Write-Output "FULL MISS counts errors of a whole cycle or more and is NEVER averaged"
Write-Output "into it, because a 7-day miss and seven 1-day misses have the same mean"
Write-Output "and only one of them served a stale board for a week."
Write-Output ''
Write-Output "The horizon is ONE STEP AHEAD - each prediction is scored against the"
Write-Output "very next window. It says nothing about two cycles out."
Write-Output ''
# THE BASELINE (2026-09-08, backlog I70). Both arms go through Get-ForecastScore, so the only
# thing that differs between them is the prediction fed in.
Write-Output ("NAIVE BASELINE: {0}/{1} exact, against the live rule's {2}/{3}." -f $nEx, $nPr, $ex, $pairs)
Write-Output "The naive predictor is 'the next ad drops cadence_days after the last one"
Write-Output "DID'. The live rule is 'this window's close, plus one day'. Same scorer, same"
Write-Output "pairs, one column changed - which is the only way two arms cannot drift apart."
if ($nPr -gt 0 -and $ex -le $nEx) {
  Write-Output ''
  Write-Output "READ THIS BEFORE QUOTING THE LIVE FIGURE: it is NOT beating a plain calendar"
  Write-Output "on this data. That is a real finding about these feeds rather than a defect,"
  Write-Output "but it means the live number is not evidence that the close-plus-one rule is"
  Write-Output "buying anything over counting days."
}
Write-Output ''
Write-Output "Any estate number of the form 'N of M correct' should ship with the same N of M"
Write-Output "for the dumbest predictor that could have produced it, through the same code."
Write-Output ''

# ---- the cadence half: a constant set wrong stays wrong ------------------
$drifted = @($rows | Where-Object { $_.scored -and $_.verdict -ne 'ok' })
if ($drifted.Count) {
  Write-Output ("CADENCE DRIFT, against a bar of {0} day set before this run:" -f $MAX_CADENCE_DRIFT_DAYS)
  foreach ($f in $drifted) { Write-Output ("  {0,-13} {1}" -f $f.store, $f.verdict) }
  Write-Output ''
}

# ---- the ratchet: a lifetime miss count may only STAY THE SAME -----------
# `@(...).Count` is 1 for a null in PowerShell, so the per-store list is built
# explicitly rather than measured off a possibly-absent field.
$perStore = @{}
foreach ($r in $rows) { if ($r.scored) { $perStore[$r.store] = [int]$r.full_misses } }

$note = 'BASELINE for full-cycle ad-forecast misses. A full miss is HISTORY and cannot be undone, so this number may only STAY THE SAME. A RISE is a newly skipped ad cycle and hard-fails. A FALL means history was rewritten or the reader broke, and is refused rather than recorded.'

if (-not (Test-Path -LiteralPath $Baseline)) {
  @{ generated = (Get-Date).ToString('s'); full_misses = $fm; per_store = $perStore; note = $note } |
    ConvertTo-Json -Depth 4 | Set-Content $Baseline -Encoding UTF8
  Write-Output ("BASELINE WRITTEN at {0} full-cycle miss(es) over {1} scored pair(s). These are on the record and are silent from here; the NEXT one fails." -f $fm, $pairs)
  Write-Output "This is a PREDICTION score, not a staleness check. audit-ad-status.ps1"
  Write-Output "owns 'is an ad closed right now' and runs in the daily watchdog."
  if (Get-Command Write-GuardComplete -ErrorAction SilentlyContinue) {
    Write-GuardComplete -Name 'ad-forecast' -Summary ("pairs={0} exact={1} baseline={2}" -f $pairs, $ex, $fm)
  } else { Write-Output 'AD-FORECAST-COMPLETE' }
  exit $(if ($drifted.Count) { 2 } else { 0 })
}

$baseDoc = Get-Content -LiteralPath $Baseline -Raw -Encoding UTF8 | ConvertFrom-Json
$base = [int]$baseDoc.full_misses

if ($fm -gt $base) {
  $new = @()
  foreach ($k in $perStore.Keys) {
    $was = 0
    if ($baseDoc.per_store -and $baseDoc.per_store.PSObject.Properties[$k]) { $was = [int]$baseDoc.per_store.$k }
    if ($perStore[$k] -gt $was) { $new += ("{0} {1} -> {2}" -f $k, $was, $perStore[$k]) }
  }
  # -AcceptMiss IS NOT A BYPASS, AND WITHOUT IT THIS GATE WOULD ROT.
  # `[ADDED 2026-09-08, caught by the fixtures.]` A rise does not move the
  # baseline, and a full-cycle miss is permanent - so once one happened the gate
  # would be red every single day forever, for a thing nobody can undo. That is
  # precisely the red-on-day-one failure this estate has a rule about: a red
  # that cannot be cleared teaches people to ignore red. The miss is
  # acknowledged EXPLICITLY, once, by a person who has dealt with the cause, and
  # the acknowledgement is dated in the file so the history stays legible.
  if ($AcceptMiss) {
    $hist = @()
    if ($baseDoc.PSObject.Properties['accepted']) { $hist = @($baseDoc.accepted) }
    $hist += [ordered]@{ at = (Get-Date).ToString('s'); from = $base; to = $fm; stores = $new }
    @{ generated = (Get-Date).ToString('s'); full_misses = $fm; per_store = $perStore
       accepted = $hist; note = $note } |
      ConvertTo-Json -Depth 5 | Set-Content $Baseline -Encoding UTF8
    Write-Output ("ACCEPTED: baseline raised {0} -> {1} by -AcceptMiss. The miss stays on the record; the NEXT one fails again." -f $base, $fm)
    foreach ($n in $new) { Write-Output ("  accepted  " + $n) }
    if (Get-Command Write-GuardComplete -ErrorAction SilentlyContinue) {
      Write-GuardComplete -Name 'ad-forecast' -Summary ("pairs={0} exact={1} full={2} accepted-from={3}" -f $pairs, $ex, $fm, $base)
    } else { Write-Output 'AD-FORECAST-COMPLETE' }
    exit 0
  }
  Write-Output ("AD FORECAST FAILED: {0} full-cycle miss(es) against a baseline of {1}. A store skipped an entire ad cycle, which means the board carried a stale price for a full week." -f $fm, $base)
  foreach ($n in $new) { Write-Output ("  NEW  " + $n) }
  Write-Output "Deal with the cause, then acknowledge it once with -AcceptMiss. That"
  Write-Output "raises the baseline and dates the acknowledgement; it does not erase it."
  if (Get-Command Write-GuardComplete -ErrorAction SilentlyContinue) {
    Write-GuardComplete -Name 'ad-forecast' -Summary ("pairs={0} exact={1} full={2} baseline={3}" -f $pairs, $ex, $fm, $base)
  } else { Write-Output 'AD-FORECAST-COMPLETE' }
  exit 2
}

if ($fm -lt $base -and -not $AcceptDrop) {
  Write-Output ("COULD NOT EVALUATE: {0} full-cycle miss(es) against a baseline of {1}. This number cannot legitimately FALL - a past miss is history. Either the schedule history was rewritten or this reader is broken. Neither is a pass. Re-run with -AcceptDrop only after establishing which." -f $fm, $base)
  if (Get-Command Write-GuardComplete -ErrorAction SilentlyContinue) {
    Write-GuardComplete -Name 'ad-forecast' -Summary ("pairs={0} full={1} baseline={2} refused-fall" -f $pairs, $fm, $base)
  } else { Write-Output 'AD-FORECAST-COMPLETE' }
  exit 3
}

if ($fm -lt $base -and $AcceptDrop) {
  @{ generated = (Get-Date).ToString('s'); full_misses = $fm; per_store = $perStore; note = $note } |
    ConvertTo-Json -Depth 4 | Set-Content $Baseline -Encoding UTF8
  Write-Output ("baseline lowered to {0} by -AcceptDrop, from {1}." -f $fm, $base)
}

Write-Output ("PASSED - {0} full-cycle miss(es) over {1} scored pair(s), unchanged from the baseline. {2} of {1} predictions landed on the day." -f $fm, $pairs, $ex)
Write-Output "This is a PREDICTION score, not a staleness check. audit-ad-status.ps1"
Write-Output "owns 'is an ad closed right now' and runs in the daily watchdog."
if (Get-Command Write-GuardComplete -ErrorAction SilentlyContinue) {
  Write-GuardComplete -Name 'ad-forecast' -Summary ("pairs={0} exact={1} full={2} baseline={3}" -f $pairs, $ex, $fm, $base)
} else { Write-Output 'AD-FORECAST-COMPLETE' }
exit $(if ($drifted.Count) { 2 } else { 0 })
