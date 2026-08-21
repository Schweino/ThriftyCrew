<#
  test-price-split.ps1 - runner for the everyday/sale split fixtures.

  WHY THIS FILE EXISTS AND IS SO THIN. price-split-lib.ps1 has carried a full self-test since it was
  written - Test-PriceSplitSelf - and on 2026-08-21 a grep showed NOTHING CALLED IT. The fixtures for
  the rule Brad called non-negotiable ("Ad pricing must never enter the every day pricing value") had
  never been executed by the suite. That is `tested is not run`, on the function whose first live
  outing re-typed 357 board cells and moved 27 Cheapest crowns.

  The library cannot run its own fixtures on import - dot-sourcing it would then run a test suite every
  time the engine loads - so the runner has to be a separate, rostered script. That is the whole job of
  this file: give the existing fixtures a production caller and emit the completion marker the guard
  contract looks for.

  Run: test-price-split.ps1     (exit 0 clean, 1 on any failure)
#>
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path (Split-Path $root -Parent) 'lib\guard-contract.ps1')
. (Join-Path $root 'price-split-lib.ps1')

if (-not (Get-Command Test-PriceSplitSelf -ErrorAction SilentlyContinue)) {
  Write-Output 'FAIL  Test-PriceSplitSelf is GONE from price-split-lib - the everyday/ad separation has no fixtures at all'
  Write-Output 'PRICE-SPLIT FAILED (1)'
  Write-GuardComplete -Name 'price-split' -Summary 'failed=1 (fixtures missing)'
  exit 1
}

# CAPTURE THE WHOLE STREAM, THEN TAKE THE COUNT OFF THE END. Test-PriceSplitSelf both Write-Outputs
# its per-case lines AND returns the failure count, so in PowerShell the caller receives ALL of it as
# one collection - `$fail = Test-PriceSplitSelf` binds the entire transcript, not the number, and
# "failed=<the whole transcript>" then reads as non-zero forever. The first version of this runner did
# exactly that and reported FAILED while every one of its 24 cases said ok.
$out = @(Test-PriceSplitSelf)
foreach ($line in $out[0..([Math]::Max(0, $out.Count - 2))]) { Write-Output $line }
$fail = 0
if ($out.Count) { [void][int]::TryParse([string]$out[-1], [ref]$fail) }
Write-Output ("PRICE-SPLIT " + $(if ($fail) { "FAILED ($fail)" } else { 'PASSED' }))
Write-GuardComplete -Name 'price-split' -Summary "failed=$fail"
exit $(if ($fail) { 1 } else { 0 })
