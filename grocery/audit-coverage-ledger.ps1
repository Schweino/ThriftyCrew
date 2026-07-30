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
  [switch]$Gate,
  [switch]$Quiet
)
$ErrorActionPreference = 'Stop'
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
  if ($blind -or $exam -le 0) {
    $findings.Add(("BLIND           {0} - examined {1} of {2} eligible row(s). This is the shape guard 11 held for five days: a confident ok over an empty examination. {3}" -f $name, $exam, $elig, $detail))
    continue
  }

  # REGRESSED - the ratchet.
  if ($bExam -gt 0) {
    $floor = [math]::Floor($bExam * (1.0 - $bTol))
    if ($exam -lt $floor) {
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
  $merged = [ordered]@{}
  foreach ($bp in ($blRows | Sort-Object Name)) {
    $name = [string]$bp.Name; $b = $bp.Value
    $row = [ordered]@{ examined = [int](Get-Num $b 'examined' 0) }
    if ($ledRows.ContainsKey($name)) { $row['examined'] = [int](Get-Num $ledRows[$name] 'examined' 0) }
    $row['tolerance']    = (Get-Num $b 'tolerance' $Tolerance)
    $row['max_age_days'] = [int](Get-Num $b 'max_age_days' 2)
    $row['phase']        = $(if ($b.PSObject.Properties['phase'] -and $b.phase) { [string]$b.phase } else { 'publish' })
    if ($b.PSObject.Properties['why'] -and $b.why) { $row['why'] = [string]$b.why }
    $merged[$name] = $row
  }
  foreach ($k in ($ledRows.Keys | Sort-Object)) {
    if ($merged.Contains($k)) { continue }
    $merged[$k] = [ordered]@{ examined = [int](Get-Num $ledRows[$k] 'examined' 0); tolerance = $Tolerance; max_age_days = 2; phase = 'publish'; why = 'added by -Accept' }
  }
  $doc = [ordered]@{ schema = 1; set = (Get-Date -Format 'yyyy-MM-dd HH:mm'); checks = $merged }
  [IO.File]::WriteAllText($BaselineFile, ($doc | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
  Write-Output ''
  Write-Output ("coverage-ledger: baseline written to " + $BaselineFile + " (" + $merged.Count + " check(s)). From here each check's examined count may only go DOWN by its tolerance.")
  exit 0
}

# ---- report -------------------------------------------------------------------------------------------
if ($findings.Count -gt 0) {
  Write-Output ''
  foreach ($f in $findings) { Write-Output ("  " + $f) }
  Write-Output ''
  Write-Output ("coverage-ledger: " + $findings.Count + " coverage finding(s) across " + $blRows.Count + " rostered check(s); " + $evaluated + " row(s) evaluated.")
  if ($Gate) { exit 2 }
  exit 1
}
if ($evaluated -eq 0) {
  Write-Output ("coverage-ledger: COULD NOT EVALUATE - " + $blRows.Count + " check(s) are rostered but NONE of them was evaluated in phase '" + $Phase + "'. Reporting ok here would be the exact failure this file watches for.")
  exit 3
}
Write-Output ("coverage-ledger: ok - " + $evaluated + " check(s) still examine at least their baseline coverage (phase '" + $Phase + "', tolerance " + [math]::Round($Tolerance * 100) + "% unless overridden).")
exit 0

