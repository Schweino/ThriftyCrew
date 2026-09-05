<#
  familyfare-sweep.ps1 - one EXTRA Family Fare term-budget sweep, outside the 8:30 daily pipeline.

  WHY THIS EXISTS (2026-07-30). Freshop's limit is a per-window REQUEST COUNT (~60-70 search terms), not a
  pacing problem: 20 terms at 200ms all succeed, a second burst in the same window all come back empty.
  pull-regular-familyfare.ps1 already handles that correctly - it keeps a term cursor (out\ff-term-cursor.json)
  and starts each run where the last one's successes ended, so consecutive runs sweep the whole 526-term list
  instead of re-buying the same first ~60 terms. What it could NOT fix by itself is CADENCE: at one run per
  day, a full sweep takes about eight days, and carried prices expire at fourteen. Family Fare had been frozen
  four days running and lost 49 board cells on 2026-07-30 as its 07-16 rows began aging out.

  So the cadence is the fix, and cadence is a scheduling decision (the pull script's own comment says exactly
  that). This wrapper is what the "SMP Family Fare Term Sweep" task runs every 3 hours; with the daily pipeline
  that is ~9 budgets a day, so the catalogue turns over roughly daily and no row has to ride the full carry
  to the edge.

  It ONLY pulls. It does not rebuild or publish the board - the daily pipeline owns that, and a sweep that
  republished would put an unguarded board live. Fresh rows land in out\regular\family-fare-regular-<today>.json
  (today's prices always win; everything else carries forward with its ORIGINAL as_of) and the next board build
  picks them up.
#>
param([int]$MaxMinutes = 9)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $root 'native-lib.ps1')   # Invoke-Native: the only safe native stderr redirect under EAP='Stop'
$log = Join-Path $root 'ff-sweep-log.txt'
function Log([string]$m) {
  $line = '[' + (Get-Date).ToString('s') + '] ' + $m
  # bare Add-Content + EAP=Stop is how a locked log file kills a whole run ([[logger-kills-pipeline]]).
  try { Add-Content -Path $log -Value $line -ErrorAction Stop } catch { }
  Write-Output $line
}

$cursorF = Join-Path $root 'out\ff-term-cursor.json'
$before = ''
if (Test-Path $cursorF) { try { $before = [string]((Read-JsonFile $cursorF).next_index) } catch {} }

Log ("sweep start (cursor before = " + ($(if ($before -ne '') { '#' + $before } else { 'unset' })) + ", MaxMinutes=$MaxMinutes)")
$rc = 0
try {
  # Invoke-Native, not 2>&1: this file sets EAP='Stop', where a redirect makes the child's first
  # stderr line terminate US. See native-lib.ps1.
  $out = (Invoke-NativeScript (Join-Path $root 'pull-regular-familyfare.ps1') '-MaxMinutes' $MaxMinutes).Lines
  $rc = $LASTEXITCODE
  foreach ($l in @($out)) { $s = ([string]$l).Trim(); if ($s) { Log ('  ' + $s) } }
} catch {
  $rc = 1
  Log ('  THREW: ' + $_.Exception.Message)
}

# ---- REPAIR PACK SIZES ON WHAT THIS SWEEP JUST LANDED (2026-08-14) --------------------------------
# check-ad-cycles repairs pack sizes immediately before compare-deals, and that ordering is correct - but it
# only covers the captures that exist at 08:30. This sweep runs every 3 hours and rewrites
# out\regular\family-fare-regular-<today>.json long after the daily has been through, so a row landing here
# reaches the NEXT compare unrepaired. That is exactly what happened on 2026-08-14: the daily repaired at
# 08:59 and found nothing, this sweep wrote "Heinz Tomato Ketchup, 2 Pack 50.5 Oz" with size "50.5 oz" at
# 19:06, and guards then hard-failed the publish on a 2x per-unit price. Repairing where the rows LAND
# closes it for every window, not just the 08:30 one. Idempotent (rows carry size_repaired), so a re-run is
# free. Non-fatal and LOUD, same contract as the daily's copy: a repair that throws must not take the sweep
# down, but must never pass silently either.
try {
  $mpOut = @(& powershell -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'repair-multipack-sizes.ps1') -Apply)
  foreach ($l in @($mpOut | Where-Object { $_ -match 'REPAIR |REFUSED |^repair-multipack-sizes:' })) { Log ('multipack-repair: ' + ([string]$l).Trim()) }
} catch { Log ('multipack-repair THREW: ' + $_.Exception.Message + ' - any pack-size defect in this window is unrepaired and guard 5 will block the next publish') }

$after = ''
if (Test-Path $cursorF) { try { $after = [string]((Read-JsonFile $cursorF).next_index) } catch {} }
# A cursor that did not move means the window bought NOTHING - the sweep is the one place that is visible.
# TWO DIFFERENT REASONS THE CURSOR CAN SIT STILL, AND THEY ARE NOT THE SAME NEWS (2026-08-02).
# Since the pull commits its cursor only behind a landed merged catalog, "cursor did not move" now covers a
# second case: a window that bought plenty and then could not write it. Reporting that as a hard shutout would
# be the same conflation that cost this pipeline thirteen days on "throttled" - an API refusal and a store
# that does not carry the term reading as one line. rc separates them: a real shutout exits 0.
if ($after -ne '' -and $after -eq $before -and $rc -eq 0) { Log ("sweep bought no terms - cursor still at #$after (hard shutout this window; next sweep re-attempts the same slice, which is correct)") }
elseif ($after -ne '' -and $after -eq $before) { Log ("sweep FAILED rc=$rc - cursor deliberately still at #$after. This is NOT a hard shutout: the run exited nonzero without committing the window (see the lines above), so the next sweep re-buys the same slice and nothing is lost.") }
else { Log ("sweep done rc=$rc - cursor #$before -> #$after") }
exit $rc
