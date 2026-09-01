<#
  run-scaler-pricing-test.ps1 - HEADLESS driver for the recipe-card WIDGET guards.

  Runs the generated fixtures in jsdom and exits 0/2, so the rules behind a recipe card are checked by the
  daily chain rather than by someone remembering to open a page. Brad approved installing node for exactly
  this on 2026-08-15. check-ad-cycles.ps1 runs this file as the `scaler-pricing` fan-out lane; the name is
  kept because that is what the daily chain calls, not because pricing is all it covers.

  TWO FIXTURES, EACH IN TWO LANES, and all four verdicts are demanded:
    test-scaler-pricing.ps1  the CHEAPEST-STORE SELECTION rule. NEGATIVE reverts the cheapest lane to
                             minimum-PER-UNIT selection (the founding bug: $10.22 of butter for 20 cents
                             of it) -> must FAIL on the butter assertions.
    test-scaler-labels.ps1   the INGREDIENT-LABEL SCALING rule (added 2026-09-01). NEGATIVE restores the
                             2026-07 scaleBuy, which moved only a label's leading number -> must FAIL on
                             the compound "2 lb 5 oz" and qualified "about 14 cups" assertions.
  A guard that only ever passes has not been shown to discriminate; if a negative lane ever passes, that
  fixture has stopped testing the thing it exists for and that is a hard failure too.

  The label fixture's PowerShell twin (Invoke-CmScaleBuy) is pinned separately, by
  test-scaler-labels.ps1 -SelfTest, which ops\run-gates.ps1 discovers and runs on every push.

  Node is a PORTABLE install (no elevation): C:\Codex\tools\node-*-win-x64\node.exe, with jsdom in
  C:\Codex\tools\jsdom-env. Both live OUTSIDE the repo on purpose - node_modules has no business in a
  tree with a deny-by-default .gitignore. Override with -NodeExe / -JsdomEnv.

  Usage: powershell -File meal-prep\pipeline\run-scaler-pricing-test.ps1
#>
param(
  [string]$NodeExe = '',
  [string]$JsdomEnv = 'C:\Codex\tools\jsdom-env',
  [switch]$Quiet
)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

if (-not $NodeExe) {
  $cand = Get-Command node -ErrorAction SilentlyContinue
  if ($cand) { $NodeExe = $cand.Source }
  else {
    $p = Get-ChildItem 'C:\Codex\tools' -Filter 'node-*-win-x64' -Directory -ErrorAction SilentlyContinue |
         Sort-Object Name -Descending | Select-Object -First 1
    if ($p) { $NodeExe = Join-Path $p.FullName 'node.exe' }
  }
}
# REFUSE, do not skip. A guard that quietly no-ops when its runtime is missing is the same failure as no
# guard at all, and it reads green (see the standing "could not run is not a failure" rule).
if (-not $NodeExe -or -not (Test-Path $NodeExe)) {
  Write-Output 'SCALER-PRICING: FAIL - node not found. Portable install expected under C:\Codex\tools\node-*-win-x64, or pass -NodeExe.'
  exit 2
}
if (-not (Test-Path (Join-Path $JsdomEnv 'node_modules\jsdom'))) {
  Write-Output ("SCALER-PRICING: FAIL - jsdom not found in {0}. Run: npm install jsdom@24 in that folder." -f $JsdomEnv)
  exit 2
}

$runner = Join-Path $env:TEMP 'tc-run-scaler-fixture.js'
@'
// Loads the generated fixture page in jsdom, lets its own assertions run, reports window.__FIXTURE_RESULT.
const fs = require('fs');
const path = require('path');
const { JSDOM } = require(path.join(process.argv[3], 'node_modules', 'jsdom'));
const html = fs.readFileSync(process.argv[2], 'utf8');
const dom = new JSDOM(html, { runScripts: 'dangerously', pretendToBeVisual: true, url: 'https://www.thriftycrew.com/zz-fixture/' });
const w = dom.window;
// The fixture stubs fetch itself, so no network is possible. Fail loudly if that ever stops being true.
w.addEventListener('error', e => { console.error('PAGE ERROR: ' + (e.message || e)); });
const deadline = Date.now() + 20000;
(function poll() {
  if (w.__FIXTURE_RESULT) {
    const r = w.__FIXTURE_RESULT;
    console.log(JSON.stringify(r));
    process.exit(r.pass ? 0 : 1);
  }
  if (Date.now() > deadline) {
    console.log(JSON.stringify({ pass: false, failed: -1, total: 0, failures: ['fixture never reported a verdict (title=' + w.document.title + ')'] }));
    process.exit(3);
  }
  setTimeout(poll, 50);
})();
'@ | Set-Content $runner -Encoding UTF8

function Invoke-Lane([string]$generator, [string]$tag, [bool]$negative) {
  $page = Join-Path $env:TEMP ("tc-fixture-" + $tag + "-" + $(if ($negative) { 'negative' } else { 'positive' }) + ".html")
  if ($negative) { & (Join-Path $here $generator) -OutFile $page -NegativeTest | Out-Null }
  else           { & (Join-Path $here $generator) -OutFile $page | Out-Null }
  $raw = & $NodeExe $runner $page $JsdomEnv 2>&1
  $code = $LASTEXITCODE
  $json = $null
  foreach ($line in @($raw)) { $t = ([string]$line).Trim(); if ($t.StartsWith('{')) { try { $json = $t | ConvertFrom-Json } catch {} } }
  return [pscustomobject]@{ tag=$tag; exit=$code; result=$json; raw=@($raw) }
}

$ok = $true

# ONE FIXTURE, BOTH LANES, THE SAME STANDARD FOR EACH. $negWhat names the mutation so a failure says
# which rule stopped being tested rather than just that something is red.
#
# IT SETS $script:ok AND RETURNS NOTHING, deliberately. Written first as `if (-not (Test-Fixture ...))`
# it was silently broken in the PS 5.1 way: every Write-Output inside a function joins its RETURN VALUE,
# so the caller got an array of report lines with the boolean on the end, `-not <non-empty array>` is
# always false, and the guard printed nothing and could never fail. The verdict and the report cannot
# share one channel here, so the verdict leaves by a variable and the report leaves by stdout.
function Test-Fixture([string]$name, [string]$generator, [string]$tag, [string]$negWhat, [string]$okLine) {
  $pos = Invoke-Lane $generator $tag $false
  $neg = Invoke-Lane $generator $tag $true
  $good = $true
  if ($null -eq $pos.result -or -not $pos.result.pass) {
    $good = $false
    Write-Output ("SCALER-PRICING: FAIL - the live template does not satisfy the {0} fixture ({1} of {2} assertion(s) failed)" -f $name, $(if($pos.result){$pos.result.failed}else{'?'}), $(if($pos.result){$pos.result.total}else{'?'}))
    if ($pos.result) { foreach ($f in @($pos.result.failures)) { Write-Output ('    ' + $f) } } else { foreach ($l in $pos.raw) { Write-Output ('    ' + $l) } }
  } elseif (-not $Quiet) {
    Write-Output ("SCALER-PRICING: {0} positive lane PASS ({1} assertions)" -f $name, $pos.result.total)
  }
  # The negative lane must fail, AND must fail on the founding bug specifically - if it starts failing for
  # some unrelated reason the mutation has stopped reproducing the bug and the guard is testing nothing.
  if ($null -eq $neg.result -or $neg.result.pass) {
    $good = $false
    Write-Output ("SCALER-PRICING: FAIL - the {0} NEGATIVE lane passed. {1} no longer breaks the fixture, so this guard is not testing the rule it was written for." -f $name, $negWhat)
  } else {
    $mustFire = @($neg.result.failures | Where-Object { $_ -match 'MUST-FIRE' })
    if (-not $mustFire.Count) {
      $good = $false
      Write-Output ("SCALER-PRICING: FAIL - the {0} negative lane failed, but NOT on its must-fire assertions. The mutation is no longer reproducing the founding bug:" -f $name)
      foreach ($f in @($neg.result.failures)) { Write-Output ('    ' + $f) }
    } elseif (-not $Quiet) {
      Write-Output ("SCALER-PRICING: {0} negative lane correctly FAILED ({1} assertion(s), {2} must-fire)" -f $name, $neg.result.failed, $mustFire.Count)
    }
  }
  if ($good -and -not $Quiet) { Write-Output ("SCALER-PRICING: OK - " + $okLine) }
  if (-not $good) { $script:ok = $false }
}

Test-Fixture 'store-selection' 'test-scaler-pricing.ps1' 'pricing' `
  'Reverting the cheapest lane to minimum-per-unit selection' `
  'recipe cards price each ingredient at the store that is cheapest to buy at.'

# THE LABEL RULE (2026-09-01). A card that prices correctly can still tell a cook to weigh out five
# ounces less chicken than the recipe uses, which is what "2 lb 5 oz" doubling to "4 lb 5 oz" did.
Test-Fixture 'label-scaling' 'test-scaler-labels.ps1' 'labels' `
  'Restoring the 2026-07 leading-number-only scaleBuy' `
  'a compound lb+oz label scales as one quantity and a hedged label scales at all.'

if ($ok) { Write-Output 'SCALER-PRICING: OK - both recipe-card widget fixtures pass, and each proves it can still catch its founding bug.'; exit 0 }
exit 2
