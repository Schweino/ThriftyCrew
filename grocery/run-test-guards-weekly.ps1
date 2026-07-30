<#
  run-test-guards-weekly.ps1 - hermetic invocation of test-guards.ps1.
  test-guards proves each hard invariant in guards.ps1 can still FAIL by breaking production files and
  restoring them. Measured 2026-07-30: a hard kill mid-run runs neither finally nor PowerShell.Exiting
  (proven with Stop-Process on an armed child), 4 of its 16 mutation windows were outside the crash
  registry, and another session committed to the repo DURING the measured run. So the recurring job never
  touches production: robocopy the tree to %TEMP% (measured 1.1s / 658 MB; guards.ps1 and every audit
  root at $PSScriptRoot - verified zero absolute-path escapes) and run the suite inside the copy. A crash
  costs a temp directory. Exit: 0 = pass, 1 = a case failed, 3 = could not evaluate (baseline already
  red - decided HERE in the copy, because on a red board every expect-2 case passes vacuously), 4 = copy
  failed.
  Day-gate + stamp live in the caller (check-ad-cycles), like every other weekly job.
#>
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$dst = Join-Path $env:TEMP 'smp-test-guards-hermetic'
robocopy $root $dst /MIR /NFL /NDL /NJH /R:1 /W:1 | Out-Null
if ($LASTEXITCODE -ge 8) { Write-Output ("hermetic copy FAILED (robocopy rc=" + $LASTEXITCODE + ") - suite not run"); exit 4 }
# Baseline pre-check IN THE COPY: guards red before any mutation means every expect-exit-2 case passes
# vacuously (guards exits 2 no matter what is broken - measured 2026-07-30: 12 vacuous passes on the live
# coverage-regression failure), so the suite can prove nothing. Exit 3 = "could not evaluate", the same
# convention as the delegated-audit wrappers in guards.ps1. guards -Quiet still prints its HARD FAIL
# report (bare Write-Output), so the alert body names the real failure. test-guards itself also aborts
# exit-3 on a red baseline; this pre-check keeps the runner's contract self-contained either way.
$base = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dst 'guards.ps1') -Quiet
if ($LASTEXITCODE -ne 0) {
  Write-Output ('baseline already red (guards exit ' + $LASTEXITCODE + ') before any mutation - nothing provable; the daily guards run owns this failure:')
  @($base) | Where-Object { $_ } | ForEach-Object { Write-Output $_ }
  Remove-Item $dst -Recurse -Force -ErrorAction SilentlyContinue
  exit 3
}
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dst 'test-guards.ps1')
$rc = $LASTEXITCODE
Remove-Item $dst -Recurse -Force -ErrorAction SilentlyContinue   # never leave 658 MB in TEMP
exit $rc
