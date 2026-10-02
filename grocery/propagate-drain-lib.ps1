# propagate-drain-lib.ps1 - the daily chain's PROPAGATE DRAIN, dot-sourced by check-ad-cycles.ps1.
# Moved out of check-ad-cycles on 2026-10-02 (triage 2026-09-30-9b9cf1 fix-up) so that file stays at its size mark;
# the behaviour is unchanged. Self-test: grocery\test-propagate-drain.ps1.
#
# DRAIN THE PROPAGATE QUEUE (triage 2026-09-30-9b9cf1). propagate-recipes.ps1 had NO automated caller, so a spec edit
# reached its live page only when a person ran it: 33 specs waited 75.5h and health-heartbeat paged QUEUE STUCK with no
# repair lane. This runs it daily as `-Drain`, which names the dirty set minus the held list and goes through
# propagate's own -SlugsFile narrowing and every gate in it (db-agreement, buy-label plurals, feed coverage, allergen
# line, publish's price-literal, hold, rollout and create refusals). Never -AllowCatalogue, never a create, and refused
# over 150 specs. sync-recipesdb-cost runs first, as by hand, or audit-db-agreement refuses the drain on a stale index.
# Skipped when compute-v2 failed (the costs are not trustworthy) and under -NoPublish (it writes to Ghost).
# Cost: one propagate child a day; with nothing dirty it is a hash pass over the specs and exits.
#
# Returns the REVIEW summary line when the drain did not complete, else nothing. Calls the caller's Log and Send-Alert.
# -PipelineDir is where sync-recipesdb-cost.ps1 and propagate-recipes.ps1 live (the test hands it a stub folder).
function Invoke-TcPropagateDrain {
  param([string]$PipelineDir, [bool]$Cv2Ok, [switch]$NoPublish, [switch]$NoAlert)
  if ($NoPublish) { Log 'propagate drain skipped under -NoPublish (it republishes live recipe pages)'; return }
  if (-not $Cv2Ok) { return }
  try {
    $scOut = @(& powershell -ExecutionPolicy Bypass -File (Join-Path $PipelineDir 'sync-recipesdb-cost.ps1') -Apply)
    $scRc = $LASTEXITCODE
    Log ('sync-recipesdb-cost: ' + (@($scOut) | Select-Object -Last 1))
    $pdOut = @()
    $pdRc = -1
    if ($scRc -eq 0) {
      $pdOut = @(& powershell -ExecutionPolicy Bypass -File (Join-Path $PipelineDir 'propagate-recipes.ps1') -Drain)
      $pdRc = $LASTEXITCODE
      foreach ($l in @($pdOut | Where-Object { $_ -match '^(propagate|PROPAGATE|nothing to propagate|  held, not drained|published\+verified)' })) { Log ('propagate-drain: ' + $l) }
    }
    $pdDone = @($pdOut | Where-Object { $_ -match '^propagate COMPLETE:|^nothing to propagate' }).Count -gt 0
    if ($scRc -ne 0 -or $pdRc -ne 0 -or -not $pdDone) {
      $why = if ($scRc -ne 0) { "sync-recipesdb-cost exited $scRc, so the drain did not run" } else { "propagate-recipes.ps1 -Drain exited $pdRc" + $(if ($pdDone) { '' } else { ' without its COMPLETE line' }) }
      Log ('propagate drain NOT done: ' + $why)
      if (-not $NoAlert) { try { Send-Alert -Subject "Recipe propagate drain did not complete" -Body ("The daily chain's propagate drain did not finish: $why. Dirty recipe specs were not carried to their live pages; they stay dirty and the next run retries them. A PROPAGATE-DRAIN-REFUSED line means more specs are dirty than the unattended bar allows: review them and run meal-prep\pipeline\propagate-recipes.ps1 -SlugsFile <list>.`n`nLast lines:`n" + ((@($scOut) + @($pdOut) | Select-Object -Last 15) -join "`n")) | Out-Null } catch {} }
      return "REVIEW    the propagate drain did not complete ($why); dirty recipe specs stay unpublished and stay dirty for the next run"
    }
  } catch { Log ('propagate drain threw: ' + $_.Exception.Message) }
}
