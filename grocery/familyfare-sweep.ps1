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
  that is ~9 budgets a day, so the catalogue turns over roughly daily and no row has to ride the 14-day carry
  to the edge.

  It ONLY pulls. It does not rebuild or publish the board - the daily pipeline owns that, and a sweep that
  republished would put an unguarded board live. Fresh rows land in out\regular\family-fare-regular-<today>.json
  (today's prices always win; everything else carries forward with its ORIGINAL as_of) and the next board build
  picks them up.
#>
param([int]$MaxMinutes = 9)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$log = Join-Path $root 'ff-sweep-log.txt'
function Log([string]$m) {
  $line = '[' + (Get-Date).ToString('s') + '] ' + $m
  # bare Add-Content + EAP=Stop is how a locked log file kills a whole run ([[logger-kills-pipeline]]).
  try { Add-Content -Path $log -Value $line -ErrorAction Stop } catch { }
  Write-Output $line
}

$cursorF = Join-Path $root 'out\ff-term-cursor.json'
$before = ''
if (Test-Path $cursorF) { try { $before = [string]((Get-Content $cursorF -Raw | ConvertFrom-Json).next_index) } catch {} }

Log ("sweep start (cursor before = " + ($(if ($before -ne '') { '#' + $before } else { 'unset' })) + ", MaxMinutes=$MaxMinutes)")
$rc = 0
try {
  $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'pull-regular-familyfare.ps1') -MaxMinutes $MaxMinutes 2>&1
  $rc = $LASTEXITCODE
  foreach ($l in @($out)) { $s = ([string]$l).Trim(); if ($s) { Log ('  ' + $s) } }
} catch {
  $rc = 1
  Log ('  THREW: ' + $_.Exception.Message)
}

$after = ''
if (Test-Path $cursorF) { try { $after = [string]((Get-Content $cursorF -Raw | ConvertFrom-Json).next_index) } catch {} }
# A cursor that did not move means the window bought NOTHING - the sweep is the one place that is visible.
if ($after -ne '' -and $after -eq $before) { Log ("sweep bought no terms - cursor still at #$after (hard shutout this window; next sweep re-attempts the same slice, which is correct)") }
else { Log ("sweep done rc=$rc - cursor #$before -> #$after") }
exit $rc
