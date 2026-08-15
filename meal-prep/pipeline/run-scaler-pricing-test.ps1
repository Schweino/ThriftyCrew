<#
  run-scaler-pricing-test.ps1 - HEADLESS driver for the recipe-card pricing guard.

  Runs meal-prep\pipeline\test-scaler-pricing.ps1's generated fixture in jsdom and exits 0/2, so the rule
  behind every price on a recipe card is checked by the daily chain rather than by someone remembering to
  open a page. Brad approved installing node for exactly this on 2026-08-15.

  It runs BOTH lanes and demands both verdicts, which is what makes the guard trustworthy:
    POSITIVE  the fixture as generated from the live template  -> must PASS
    NEGATIVE  the same fixture with the cheapest lane reverted to minimum-PER-UNIT selection (the founding
              bug: $10.22 of butter for 20 cents of it) -> must FAIL, and must fail on the butter assertions
  A guard that only ever passes has not been shown to discriminate; if the negative lane ever passes, the
  fixture has stopped testing the thing it exists for and that is a hard failure too.

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

function Invoke-Lane([string]$label, [bool]$negative) {
  $page = Join-Path $env:TEMP ("tc-fixture-" + $(if ($negative) { 'negative' } else { 'positive' }) + ".html")
  if ($negative) { & (Join-Path $here 'test-scaler-pricing.ps1') -OutFile $page -NegativeTest | Out-Null }
  else           { & (Join-Path $here 'test-scaler-pricing.ps1') -OutFile $page | Out-Null }
  $raw = & $NodeExe $runner $page $JsdomEnv 2>&1
  $code = $LASTEXITCODE
  $json = $null
  foreach ($line in @($raw)) { $t = ([string]$line).Trim(); if ($t.StartsWith('{')) { try { $json = $t | ConvertFrom-Json } catch {} } }
  return [pscustomobject]@{ label=$label; exit=$code; result=$json; raw=@($raw) }
}

$pos = Invoke-Lane 'positive' $false
$neg = Invoke-Lane 'negative' $true

$ok = $true
if ($null -eq $pos.result -or -not $pos.result.pass) {
  $ok = $false
  Write-Output ("SCALER-PRICING: FAIL - the live template does not satisfy the pricing fixture ({0} of {1} assertion(s) failed)" -f $(if($pos.result){$pos.result.failed}else{'?'}), $(if($pos.result){$pos.result.total}else{'?'}))
  if ($pos.result) { foreach ($f in @($pos.result.failures)) { Write-Output ('    ' + $f) } } else { foreach ($l in $pos.raw) { Write-Output ('    ' + $l) } }
} elseif (-not $Quiet) {
  Write-Output ("SCALER-PRICING: positive lane PASS ({0} assertions)" -f $pos.result.total)
}
# The negative lane must fail, AND must fail on the founding bug specifically - if it starts failing for
# some unrelated reason the mutation has stopped reproducing the bug and the guard is testing nothing.
if ($null -eq $neg.result -or $neg.result.pass) {
  $ok = $false
  Write-Output 'SCALER-PRICING: FAIL - the NEGATIVE lane passed. Reverting the cheapest lane to minimum-per-unit selection no longer breaks the fixture, so this guard is not testing the rule it was written for.'
} else {
  $mustFire = @($neg.result.failures | Where-Object { $_ -match 'MUST-FIRE' })
  if (-not $mustFire.Count) {
    $ok = $false
    Write-Output 'SCALER-PRICING: FAIL - the negative lane failed, but NOT on the must-fire butter assertions. The mutation is no longer reproducing the founding bug:'
    foreach ($f in @($neg.result.failures)) { Write-Output ('    ' + $f) }
  } elseif (-not $Quiet) {
    Write-Output ("SCALER-PRICING: negative lane correctly FAILED ({0} assertion(s), {1} must-fire)" -f $neg.result.failed, $mustFire.Count)
  }
}
if ($ok) { Write-Output 'SCALER-PRICING: OK - recipe cards price each ingredient at the store that is cheapest to buy at, and the guard proves it can still catch the alternative.'; exit 0 }
exit 2
