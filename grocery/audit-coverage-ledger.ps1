<#
  audit-coverage-ledger.ps1 - THE RATCHET on how much each check actually looked at.

  Reads out\coverage-ledger.json (written by coverage-lib.ps1 from inside the checks themselves) and
  compares it to grocery\coverage-baseline.json, the accepted high-water mark. It answers the one question
  no other audit in this tree can answer: DID THIS CHECK STILL SEE WHAT IT SAW LAST TIME?

  FIVE VERDICTS, in the order they are reported:
    NEVER-RECORDED  the baseline names a check that has NO ledger row at all. This is the audit-ff-carry
                    class: the script threw before its report line for 17 days and printed nothing, so
                    there was no output to be suspicious of. Absence is not a zero.
    STALE           a row older than its baseline's max_age_days. The check ran once and stopped running.
    BLIND           examined <= 0 while eligible > 0. The guard-11 class (ok on 0 of 6,960 rows for five
                    days) and the guard-3 class (0 of 16 pins) both land here.
    INERT           eligible = 0. NOT a pass. Measured on the live board 2026-07-30: 22 of 492 commodities
                    have exactly ONE priced cell, 41 have <=2, 58 have <=3, so any per-commodity rail is
                    structurally incapable of firing on a fifth of the board. A rail with no eligible rows
                    proves nothing and must say so.
    REGRESSED       examined < baseline.examined * (1 - tolerance). The partial-collapse class that every
                    in-run zero-rows test in this tree is blind to: 2,435 rows falling to 400 is not zero,
                    it is 84% blind, and it reads as a pass everywhere else.
    SHORTFALL       examined < min_ratio * eligible AND more than one eligible row went unexamined, for the
                    rows that declare a `min_ratio`. THE BUDGETED-LANE RAIL, added 2026-08-22 for
                    pull-regular-hyvee. See below.

  BUDGETED LANES, AND WHY REGRESSED CANNOT WATCH THEM. Every verdict above compares examined to a FIXED
  baseline count, which assumes the population is roughly the same size every day. pull-regular-hyvee is no
  longer that: capture-policy gives it ceil(population/90) products a day and rotates a cursor, so what it
  is ALLOWED to look at legitimately swings 0-18 (median 3, measured over a full rotation of the 1,554-row
  2026-08-21 file, whose 490 linked products cluster). Ratcheting its absolute count against the 1,010 it
  measured in the re-verify-everything era reported a 98% collapse every single morning - a permanent
  finding nobody could act on, which is this file's own founding failure (a confident answer about nothing)
  running in reverse, because a watcher that cries daily is one people learn to scroll past.
  A row may therefore declare `min_ratio`, and then it is judged on WHAT IT WAS ALLOWED TO LOOK AT TODAY:
  examined / eligible must hold at or above that ratio. Full coverage of a small slice is ok; a slice we
  could not finish asking about, or a source that stopped answering, drops the ratio immediately. For such
  a row the absolute REGRESSED test is skipped (its baseline count is documentation, not a floor) and
  -Accept will not raise it, or one dense day would re-arm the fixed floor the row exists to avoid.
  ONE missing row is never a SHORTFALL, only a note: a median Hy-Vee slice is 3 products, where a single
  dead product id is a 33% "collapse" - a percentage is the wrong instrument on a small n, the same lesson
  guards/3-pin-derivable carries. Every failure this rail is for misses many rows at once.
  BLIND, INERT and STALE still apply unchanged - they are the verdicts that do not need a stable
  population, and BLIND is what fires when a budgeted lane asks and gets nothing back.

  CRY-WOLF, MEASURED BEFORE THIS WAS WRITTEN (not asserted). The default tolerance is 0.10. Across the 18
  consecutive retained boards in out\ (2026-07-05 -> 2026-07-30) the priced-cell count - the denominator
  nearly every one of these checks is drawn from - moved day over day by:
      +4.4 -3.6 +5.6 +858.8 -5.0 +13.6 +16.3 +1.8 +10.0 -0.7 +7.2 -0.1 +3.5 +5.6 0.0 -0.1 +0.2 +4.9 %
  The largest DROP in the whole retained history is -5.0% (2026-07-12 -> 07-13, during the 29 -> 492
  commodity build-out); in the mature era from 2026-07-18 the largest drop is -0.7%. A 10% band therefore
  produces ZERO findings across all 18 real transitions, and against a fixed high-water baseline set at
  2026-07-18 (2,291 cells) it also produces zero. It still catches every founding bug above, all of which
  are 100% drops. Per-check tolerance overrides live in the baseline, with the reason written next to them.

  PHASES. Not every check runs in every job, and demanding one that did not run is the cry-wolf failure
  this file is supposed to prevent. Each baseline entry declares the phase it is REQUIRED in:
    publish - written during a guards.ps1 run (guards' own rows and the audits guards delegates to)
    cycle   - written during check-ad-cycles.ps1 (audit-ff-carry and friends)
  NEVER-RECORDED and STALE fire only for the phase being run (-Phase publish | cycle | all). BLIND, INERT
  and REGRESSED fire for any row that IS present, whatever the phase - a row that exists can always be read.
  This is what keeps a fresh cloud checkout (out\ is gitignored, so the ledger starts empty there) from
  reporting every cycle-phase check as missing on a run that was never going to write them.

  EXIT: 0 = clean. 1 = findings (ADVISORY - the default). 2 = findings and -Gate was passed.
        3 = COULD NOT EVALUATE (no ledger, no baseline, or neither holds a usable row). Never 0 from zero
            rows - that is the rule this whole component exists to enforce, and it applies to this file too.

  -Accept moves the baseline to today's ledger, like audit-tile-integrity's -Baseline. It MERGES: a
  rostered check with no ledger row keeps its baseline entry rather than being quietly retired, because
  dropping it is exactly how the ff-carry watch would disappear a second time. It REFUSES on a blind or
  unreadable ledger, for the reason audit-tile-integrity learned the hard way: accepting during the
  incident pins the high-water mark at its most useless value and disarms the ratchet permanently.
#>
param(
  [string]$OutDir = '',
  [string]$BaselineFile = '',
  [ValidateSet('publish','cycle','all')][string]$Phase = 'all',
  [double]$Tolerance = 0.10,
  [switch]$Accept,
  # -Accept RAISES a check's high-water mark freely and refuses to LOWER one without this, because a
  # ratchet that can be lowered by an ordinary accept is not a ratchet. See the merge block below.
  [switch]$AcceptLower,
  [switch]$Gate,
  [switch]$Quiet
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\guard-contract.ps1')
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
if (-not $BaselineFile) { $BaselineFile = Join-Path $root 'coverage-baseline.json' }
. (Join-Path $root 'coverage-lib.ps1')

$ledPath = Get-CoverageLedgerPath $OutDir
$led = Read-CoverageJson $ledPath
$bl  = Read-CoverageJson $BaselineFile

# ---- the zero-rows rule, applied to this auditor itself -----------------------------------------------
if ($null -eq $bl -or -not $bl.PSObject.Properties['checks'] -or $null -eq $bl.checks) {
  Write-Output ("coverage-ledger: COULD NOT EVALUATE - no readable baseline at '" + $BaselineFile + "'. With no roster there is nothing to ratchet against and nothing to notice missing, so this run proves NOTHING about any check's coverage. Seed it with -Accept once the ledger has a run in it.")
  exit 3
}
$blRows = @($bl.checks.PSObject.Properties)
if ($blRows.Count -eq 0) {
  Write-Output ("coverage-ledger: COULD NOT EVALUATE - the baseline at '" + $BaselineFile + "' lists ZERO checks. An empty roster reports a clean bill of health for a set nobody is watching.")
  exit 3
}
if ($null -eq $led -or -not $led.PSObject.Properties['checks'] -or $null -eq $led.checks -or @($led.checks.PSObject.Properties).Count -eq 0) {
  Write-Output ("coverage-ledger: COULD NOT EVALUATE - no readable coverage ledger at '" + $ledPath + "' (missing, empty, or malformed). NOT a pass: it means no check recorded what it examined, which is indistinguishable from every check examining nothing.")
  exit 3
}

$ledRows = @{}
foreach ($p in $led.checks.PSObject.Properties) { $ledRows[[string]$p.Name] = $p.Value }

function Get-Num($obj, [string]$name, [double]$default) {
  # ConvertFrom-Json rows are HETEROGENEOUS - a property present on row 1 can be absent on row 500 - so
  # every field read here is probed, never assumed.
  if ($null -eq $obj) { return $default }
  if (-not $obj.PSObject.Properties[$name]) { return $default }
  $v = $obj.$name
  if ($null -eq $v) { return $default }
  $d = 0.0
  if ([double]::TryParse(([string]$v), [ref]$d)) { return $d }
  return $default
}

$findings = New-Object System.Collections.Generic.List[string]
$okLines  = New-Object System.Collections.Generic.List[string]
$notes    = New-Object System.Collections.Generic.List[string]
$evaluated = 0
$today = [datetime](Get-Date -Format 'yyyy-MM-dd')

foreach ($bp in ($blRows | Sort-Object Name)) {
  $name = [string]$bp.Name
  $b = $bp.Value
  $bExam = [int](Get-Num $b 'examined' 0)
  $bTol  = Get-Num $b 'tolerance' $Tolerance
  $bAge  = [int](Get-Num $b 'max_age_days' 2)
  # 0 = off, which is every row but the budgeted lanes. See the header.
  $bRatio = Get-Num $b 'min_ratio' 0.0
  $bPhase = 'publish'
  if ($b.PSObject.Properties['phase'] -and $b.phase) { $bPhase = [string]$b.phase }
  $required = ($Phase -eq 'all') -or ($Phase -eq $bPhase)

  if (-not $ledRows.ContainsKey($name)) {
    if ($required) {
      $findings.Add(("NEVER-RECORDED  {0} - the baseline expects this check to record its coverage in the '{1}' phase and the ledger holds NO row for it. Either it did not run, or it died before it could report. A check that produces no output at all is the one failure no in-run zero-rows test can see." -f $name, $bPhase))
    } else {
      $notes.Add(("not required in phase '{0}': {1} (declared phase '{2}', no ledger row)" -f $Phase, $name, $bPhase))
    }
    continue
  }

  $r = $ledRows[$name]
  $exam = [int](Get-Num $r 'examined' 0)
  $elig = [int](Get-Num $r 'eligible' 0)
  $blind = $false
  if ($r.PSObject.Properties['blind']) { $blind = [bool]$r.blind }
  $asOfS = ''
  if ($r.PSObject.Properties['as_of']) { $asOfS = ([string]$r.as_of) }
  $detail = ''
  if ($r.PSObject.Properties['detail']) { $detail = ([string]$r.detail) }
  $evaluated++

  # STALE - the row exists but is from an older run than this phase should have produced.
  $ageDays = -1
  if ($asOfS) {
    $dm = [regex]::Match($asOfS, '^(\d{4}-\d{2}-\d{2})')
    if ($dm.Success) { try { $ageDays = [int](($today - [datetime]$dm.Groups[1].Value).TotalDays) } catch { $ageDays = -1 } }
  }
  if ($required -and $ageDays -gt $bAge) {
    $findings.Add(("STALE           {0} - last recorded coverage is {1} ({2} day(s) old, limit {3}). The check stopped recording; whatever it is asserting today, it is not asserting it on today's data." -f $name, $asOfS, $ageDays, $bAge))
    continue
  }

  # INERT - nothing was eligible. Never a pass.
  if ($elig -le 0 -and $exam -le 0) {
    $findings.Add(("INERT           {0} - ZERO eligible rows, so the check could not fire even if the bug it watches for were present. Unknown is not a pass. {1}" -f $name, $detail))
    continue
  }

  # BLIND - eligible rows existed and none were examined.
  # What justifies this row's tolerance, if anything. Read once; both checks below turn on it.
  $whyTxt = ''
  foreach ($wk in @('why', 'reason', 'note')) { if ($b.PSObject.Properties[$wk] -and ([string]$b.$wk).Trim()) { $whyTxt = [string]$b.$wk; break } }

  # DEAD RATCHET - a tolerance so wide the REGRESSED verdict below can never fire (F4, 2026-08-01).
  # `floor = bExam * (1 - tol)`, so a tolerance of 1.0 puts the floor at ZERO, and `examined < 0` is
  # unreachable because BLIND above already claims everything <= 0. Two checks were shipped in that state
  # - guards/5-multipack and audit-ff-carry - so their ratchet had never been able to fire and nothing said
  # so. That is the gates-that-can-never-arm class exactly: a check that reports `ok` forever because its
  # own threshold is unreachable, which is worse than no check because it occupies the slot.
  # Reported against the check ITSELF rather than the data, because no amount of data can trip it - so it
  # is computed BEFORE the data verdicts and does NOT `continue`. Ordered after BLIND it stayed invisible
  # on exactly the checks that needed it, which is the finding-hidden-behind-a-finding shape.
  #
  # BUT A DISABLED RATCHET IS SOMETIMES CORRECT, and the first version of this check got that wrong. Some
  # denominators are INVERSE: audit-ff-carry counts EMPTY Family Fare search terms re-probed, so its number
  # FALLS when the pull gets better, and a ratchet on it would fire at whoever fixed the thing it watches.
  # That exemption is deliberate and pinned by its own clean twin in test-auditors.
  # So the line is not "is the ratchet off" but "is it off ON PURPOSE": a recorded reason makes it a
  # declared exemption, and silence makes it an accident. guards/5-multipack had no reason and was NOT an
  # inverse metric - its own guard warns that a terser Walmart capture turns the invariant into a no-op -
  # so it was simply unfirable, and now carries a real tolerance.
  # A row judged by min_ratio is exempt here, and not by the usual write-down-a-reason route: its ratchet
  # is the SHORTFALL rail below, which is live and firable. Reporting its unused tolerance as a dead ratchet
  # would be the cry-wolf this check exists to avoid.
  if ($bRatio -le 0 -and $bExam -gt 0 -and [math]::Floor($bExam * (1.0 - $bTol)) -le 0 -and -not $whyTxt) {
    $findings.Add(("DEAD-RATCHET    {0} - tolerance {1}% puts its regression floor at 0 of a {2}-row baseline, and BLIND already owns everything at or below zero. This check's REGRESSED verdict is STRUCTURALLY UNFIRABLE: it can drop to 1 examined row and still report ok, and nothing records that as deliberate. Give it a real tolerance, or write down why its ratchet is off on purpose. {3}" -f $name, [math]::Round($bTol * 100), $bExam, $detail))
  }
  # An override with no reason is how a threshold drifts loose and nobody can say whether it was measured.
  # The file's own contract says overrides carry their reason; this makes that contract enforceable.
  if ([math]::Abs($bTol - $Tolerance) -gt 0.0001 -and -not $whyTxt) {
    $notes.Add(("UNJUSTIFIED TOLERANCE: {0} overrides the default {1}% with {2}% and records no reason. Every override is a decision to look at less; an undocumented one cannot be reviewed or narrowed." -f $name, [math]::Round($Tolerance * 100), [math]::Round($bTol * 100)))
  }

  if ($blind -or $exam -le 0) {
    $findings.Add(("BLIND           {0} - examined {1} of {2} eligible row(s). This is the shape guard 11 held for five days: a confident ok over an empty examination. {3}" -f $name, $exam, $elig, $detail))
    continue
  }

  # SHORTFALL - the ratchet for a row whose DENOMINATOR MOVES (see the header). Everything below this
  # point compares examined to a fixed count; a budgeted lane has no fixed count to compare to, so it is
  # judged on the fraction of today's own eligible set it managed to examine. BLIND above already owns
  # exam <= 0 and INERT owns elig <= 0, so both numbers here are positive.
  if ($bRatio -gt 0) {
    $ratio = [double]$exam / [double]$elig
    # ONE MISSING ROW IS NEVER A SHORTFALL, because these slices are SMALL and a percentage is the wrong
    # instrument on a small n - the same lesson guards/3-pin-derivable carries. A median Hy-Vee slice holds
    # THREE askable products, so a single delisted product id (measured ~2% of asked products: 08-18 landed
    # 356 fresh + 171 capped of 539, and 08-21 landed 490 of 490) would read as a 33% collapse and fire
    # about one morning in seventeen. What this rail is for leaves DOZENS unexamined at once - the
    # wall-clock cap biting, or the endpoint refusing - and clears this floor easily. The single-row case
    # is still said out loud, as a note, so a slow bleed is visible rather than swallowed.
    $missed = $elig - $exam
    if ($ratio -lt $bRatio -and $missed -gt 1) {
      $findings.Add(("SHORTFALL       {0} - examined {1} of the {2} row(s) it was ALLOWED to examine today ({3}%), below the {4}% this row requires. Its population is a rotating daily slice, so a fixed baseline count cannot tell a throttled day from an ordinary one - this can, and what it says is that something stopped the work being asked for or stopped the source answering. {5}" -f $name, $exam, $elig, [math]::Round(100.0 * $ratio), [math]::Round(100.0 * $bRatio), $detail))
      continue
    }
    if ($ratio -lt $bRatio) {
      $notes.Add(("SMALL SLICE: {0} - examined {1} of {2} eligible today, ONE row short. A slice this small cannot carry a percentage: one unanswered product is a dead product id, not a throttle, so this is a note rather than a finding. A real throttle leaves dozens unexamined at once and is reported. {3}" -f $name, $exam, $elig, $detail))
      $okLines.Add(("  ok    {0,-30} examined {1} of {2} eligible TODAY ({3}%) - one row short of its {4}% floor, too small to call; see the note below" -f $name, $exam, $elig, [math]::Round(100.0 * $ratio), [math]::Round(100.0 * $bRatio)))
      continue
    }
    $okLines.Add(("  ok    {0,-30} examined {1} of {2} eligible TODAY ({3}%, floor {4}% of the day's slice; absolute count not ratcheted)" -f $name, $exam, $elig, [math]::Round(100.0 * $ratio), [math]::Round(100.0 * $bRatio)))
    continue
  }

  # REGRESSED - the ratchet.
  if ($bExam -gt 0) {
    $floor = [math]::Floor($bExam * (1.0 - $bTol))
    # FULL COVERAGE IS NOT A REGRESSION (2026-08-21). The ratchet compares examined against the
    # BASELINE examined and never looks at how many rows exist to examine. When the eligible
    # population legitimately shrinks, a check that reads every single row it has is reported as
    # "PARTLY blind - the rows it stopped looking at are unguarded", and there are no such rows.
    #
    # Measured: guards/3-pin-derivable recorded eligible 7, examined 7 - 100% - against a baseline
    # of 19, and was reported REGRESSED for weeks. Override pins had simply gone from 19 to 7. Its
    # own baseline `why` already anticipates this ("pins collapsed 19 -> 1"), which is why its
    # tolerance is 0.5; the tolerance was treating the symptom.
    #
    # The distinction that matters is whether anything is UNGUARDED. At exam >= elig nothing is, so
    # the REGRESSED text would be false. But a shrinking population is still worth seeing - pins can
    # vanish because links were lost - so it becomes a note rather than silence. The baseline stores
    # only `examined`, so the note reports what it can prove: full coverage of a smaller set.
    if ($exam -lt $floor -and $elig -gt 0 -and $exam -ge $elig) {
      $notes.Add(("POPULATION SHRANK: {0} - examined {1} of {2} eligible ({3}%), against a baseline of {4}. Nothing is unguarded - this check read every row it has - so this is NOT a coverage regression. What fell is the POPULATION. Worth knowing WHY it shrank, and -Accept once you do. {5}" -f $name, $exam, $elig, [math]::Round(100.0 * $exam / $elig), $bExam, $detail))
    }
    elseif ($exam -lt $floor) {
      $pct = [math]::Round(100.0 * ($bExam - $exam) / $bExam, 1)
      $findings.Add(("REGRESSED       {0} - examined {1}, baseline {2} ({3}% fewer, tolerance {4}%). Not blind, PARTLY blind: the rows it stopped looking at are unguarded and nothing else in this tree can tell. Re-run it, or accept the new floor with audit-coverage-ledger.ps1 -Accept once you know WHY it shrank. {5}" -f $name, $exam, $bExam, $pct, [math]::Round($bTol * 100), $detail))
      continue
    }
  }
  $okLines.Add(("  ok    {0,-30} examined {1} of {2} eligible (baseline {3}, tol {4}%)" -f $name, $exam, $elig, $bExam, [math]::Round($bTol * 100)))
}

# rows the ledger holds that the baseline has never seen: new instrumentation. Informational ONLY - a new
# check must not be able to turn the board red on the day it is added.
foreach ($k in ($ledRows.Keys | Sort-Object)) {
  if (-not $bl.checks.PSObject.Properties[$k]) {
    $r = $ledRows[$k]
    $notes.Add(("UNBASELINED: {0} recorded examined={1} eligible={2} - not in the baseline yet, so it is NOT being ratcheted. Run -Accept to start watching it." -f $k, [int](Get-Num $r 'examined' 0), [int](Get-Num $r 'eligible' 0)))
  }
}

if (-not $Quiet) {
  foreach ($l in $okLines) { Write-Output $l }
  foreach ($n in $notes) { Write-Output ("  note  " + $n) }
}

# ---- -Accept ------------------------------------------------------------------------------------------
if ($Accept) {
  $blindRows = @($ledRows.Keys | Where-Object { [int](Get-Num $ledRows[$_] 'examined' 0) -le 0 })
  if ($blindRows.Count -gt 0) {
    Write-Output ''
    Write-Output ("coverage-ledger: -Accept REFUSED - " + $blindRows.Count + " ledger row(s) recorded ZERO examined rows (" + (($blindRows | Sort-Object) -join ', ') + "). Accepting now would pin those checks' high-water mark at zero and the ratchet could never fire for them again. Fix the blind check first; no baseline was written.")
    exit 3
  }
  # A RATCHET ONLY RATCHETS ONE WAY (F4, 2026-08-01). This used to take the ledger's number unconditionally,
  # so -Accept run on a bad day LOWERED the high-water mark it exists to defend - silently, while printing
  # "from here each check's examined count may only go DOWN by its tolerance", now measured from the lower
  # floor. One capped run of pull-regular-hyvee (its 14-minute wall clock) would have moved that check's
  # floor from 1,010 to 844 and nothing would have said so; the coverage it stopped looking at becomes
  # permanently unguarded, which is the whole failure this file was written for.
  # So: raise freely, lower only with -AcceptLower, and NAME every row that goes down either way.
  $lowered = @()
  $pinned  = @()
  $merged = [ordered]@{}
  foreach ($bp in ($blRows | Sort-Object Name)) {
    $name = [string]$bp.Name; $b = $bp.Value
    $bWas = [int](Get-Num $b 'examined' 0)
    $bRatioB = Get-Num $b 'min_ratio' 0.0
    $row = [ordered]@{ examined = $bWas }
    # A RATIO-JUDGED ROW DOES NOT RATCHET ITS ABSOLUTE COUNT, in either direction. Its population is a
    # rotating daily slice (pull-regular-hyvee: 0-18 askable products, median 3), so today's count says
    # nothing about tomorrow's floor - and raising it on a dense day would re-arm the fixed floor that
    # reported a 98% collapse every morning and made the whole ledger easy to ignore. The stored number is
    # documentation of the measured typical day; the live rail is min_ratio.
    if ($ledRows.ContainsKey($name) -and $bRatioB -gt 0) {
      $pinned += ("{0}: examined stays {1} (judged by ratio, min_ratio {2}%; today's ledger said {3})" -f $name, $bWas, [math]::Round(100.0 * $bRatioB), [int](Get-Num $ledRows[$name] 'examined' 0))
    }
    elseif ($ledRows.ContainsKey($name)) {
      $now = [int](Get-Num $ledRows[$name] 'examined' 0)
      if ($now -ge $bWas) { $row['examined'] = $now }
      else {
        $lowered += ("{0}: {1} -> {2} ({3}% less coverage)" -f $name, $bWas, $now, [math]::Round(100.0 * ($bWas - $now) / [math]::Max(1, $bWas), 1))
        if ($AcceptLower) { $row['examined'] = $now }
      }
    }
    $row['tolerance']    = (Get-Num $b 'tolerance' $Tolerance)
    if ($bRatioB -gt 0) { $row['min_ratio'] = $bRatioB }
    $row['max_age_days'] = [int](Get-Num $b 'max_age_days' 2)
    $row['phase']        = $(if ($b.PSObject.Properties['phase'] -and $b.phase) { [string]$b.phase } else { 'publish' })
    if ($b.PSObject.Properties['why'] -and $b.why) { $row['why'] = [string]$b.why }
    $merged[$name] = $row
  }
  foreach ($k in ($ledRows.Keys | Sort-Object)) {
    if ($merged.Contains($k)) { continue }
    $merged[$k] = [ordered]@{ examined = [int](Get-Num $ledRows[$k] 'examined' 0); tolerance = $Tolerance; max_age_days = 2; phase = 'publish'; why = 'added by -Accept' }
  }
  if ($pinned.Count -gt 0) {
    Write-Output ''
    foreach ($l in $pinned) { Write-Output ('  PINNED    ' + $l) }
  }
  if ($lowered.Count -gt 0) {
    Write-Output ''
    foreach ($l in $lowered) { Write-Output ('  ' + $(if ($AcceptLower) { 'LOWERED  ' } else { 'KEPT HIGH' }) + '  ' + $l) }
    if (-not $AcceptLower) {
      Write-Output ('  ^ these ' + $lowered.Count + " row(s) examine LESS than their baseline and were left at the higher mark, so the ratchet still defends the coverage they used to have. If the drop is real and permanent, re-run with -AcceptLower once you know WHY - a lowered floor makes the rows it stopped looking at unguarded forever.")
    }
  }
  $doc = [ordered]@{ schema = 1; set = (Get-Date -Format 'yyyy-MM-dd HH:mm'); checks = $merged }
  [IO.File]::WriteAllText($BaselineFile, ($doc | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
  Write-Output ''
  Write-Output ("coverage-ledger: baseline written to " + $BaselineFile + " (" + $merged.Count + " check(s)). From here each check's examined count may only go DOWN by its tolerance.")
  Write-GuardComplete -Name 'coverage-ledger'; exit 0
}

# ---- HISTORY: the evidence a future narrowing needs (F4, 2026-08-01) ----------------------------------
# The plan asked for tolerances narrowed "from the week's accumulated ledger data" - and there WAS no
# accumulated ledger data. out\coverage-ledger.json is a single overwritten snapshot, so every tolerance in
# the baseline was seeded by hand from one green run and none of them carries a reason. There is nothing to
# narrow FROM, and picking tighter numbers today would just be a better-dressed guess.
# So start accumulating. One append-only line per run: the date and each check's examined count. After a
# couple of weeks this answers the actual question - how much does THIS check's denominator move on a
# normal day - per check, instead of using the board-wide priced-cell proxy for all of them.
# Append-only and best-effort: a history write must never take down the audit that produces it.
try {
  $histF = Join-Path $OutDir 'coverage-ledger-history.jsonl'
  $snap = [ordered]@{ at = (Get-Date -Format 'yyyy-MM-dd HH:mm'); phase = $Phase }
  $ex = [ordered]@{}
  foreach ($k in ($ledRows.Keys | Sort-Object)) { $ex[$k] = [int](Get-Num $ledRows[$k] 'examined' 0) }
  $snap['examined'] = $ex
  Add-Content -LiteralPath $histF -Value ($snap | ConvertTo-Json -Depth 5 -Compress) -Encoding UTF8
} catch {
  # Bare Add-Content under EAP=Stop turns a locked file into a terminating error that kills the whole run -
  # the logger-kills-pipeline failure. Say it and carry on.
  Write-Output ('  (coverage history not appended this run: ' + $_.Exception.Message + ')')
}

# ---- report -------------------------------------------------------------------------------------------
if ($findings.Count -gt 0) {
  Write-Output ''
  foreach ($f in $findings) { Write-Output ("  " + $f) }
  Write-Output ''
  Write-Output ("coverage-ledger: " + $findings.Count + " coverage finding(s) across " + $blRows.Count + " rostered check(s); " + $evaluated + " row(s) evaluated.")
  # THE GATE PATH HAD DONE EVERY BIT OF THE WORK AND THEN LEFT WITHOUT SAYING SO (2026-08-23).
  # One line below, the advisory path marks completion and exits 1; this one exited 2 bare. So a
  # caller running -Gate - the mode whose whole purpose is to BLOCK on the finding - could not tell
  # "found coverage findings and finished" from "crashed part-way", which is the one distinction the
  # completion contract exists to make, missing from the one mode that acts on it.
  if ($Gate) { Write-GuardComplete -Name 'coverage-ledger' -Summary ("{0} finding(s), gate" -f $findings.Count); exit 2 }
  Write-GuardComplete -Name 'coverage-ledger'; exit 1
}
if ($evaluated -eq 0) {
  Write-Output ("coverage-ledger: COULD NOT EVALUATE - " + $blRows.Count + " check(s) are rostered but NONE of them was evaluated in phase '" + $Phase + "'. Reporting ok here would be the exact failure this file watches for.")
  exit 3
}
Write-Output ("coverage-ledger: ok - " + $evaluated + " check(s) still examine at least their baseline coverage (phase '" + $Phase + "', tolerance " + [math]::Round($Tolerance * 100) + "% unless overridden).")
Write-GuardComplete -Name 'coverage-ledger'; exit 0

