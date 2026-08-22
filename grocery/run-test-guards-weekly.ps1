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
#
#  THE COPY IS A REPO ROOT, NOT A LOOSE grocery\ (2026-08-22). It used to robocopy grocery\ straight to
#  %TEMP%\smp-test-guards-hermetic, whose PARENT is %TEMP% itself - and guards.ps1's very first act is to
#  dot-source ..\lib\guard-contract.ps1. That resolved to %TEMP%\lib\guard-contract.ps1, which exists on
#  this machine only because some earlier run happened to leave it there. The suite has been passing on a
#  stray file in the temp directory; on a clean machine the baseline pre-check would have thrown.
#  So the hermetic tree now has the shape the code expects: <root>\grocery, <root>\lib, <root>\graph. The
#  graph\identity copy is what lets guard 13 (board vs the product identity table) be exercised at all -
#  without it that gate reports BLIND inside the suite and its must-fire case could never fire.
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$repo = Split-Path $root -Parent
$hermetic = Join-Path $env:TEMP 'smp-test-guards-hermetic'
$dst = Join-Path $hermetic 'grocery'
robocopy $root $dst /MIR /NFL /NDL /NJH /R:1 /W:1 | Out-Null
if ($LASTEXITCODE -ge 8) { Write-Output ("hermetic copy FAILED (robocopy rc=" + $LASTEXITCODE + ") - suite not run"); exit 4 }
foreach ($sib in @('lib', 'graph\identity')) {
  $src = Join-Path $repo $sib
  if (-not (Test-Path $src)) { continue }
  robocopy $src (Join-Path $hermetic $sib) /MIR /NFL /NDL /NJH /R:1 /W:1 | Out-Null
  if ($LASTEXITCODE -ge 8) { Write-Output ("hermetic copy of " + $sib + " FAILED (robocopy rc=" + $LASTEXITCODE + ") - suite not run"); exit 4 }
}
if (-not (Test-Path (Join-Path $hermetic 'lib\guard-contract.ps1'))) {
  Write-Output 'hermetic copy is missing lib\guard-contract.ps1 - guards.ps1 dot-sources it before anything else, so the suite would prove nothing'
  exit 4
}
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
  Remove-Item $hermetic -Recurse -Force -ErrorAction SilentlyContinue
  exit 3
}
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dst 'test-guards.ps1')
$rc = $LASTEXITCODE
Remove-Item $hermetic -Recurse -Force -ErrorAction SilentlyContinue   # never leave 658 MB in TEMP
exit $rc
