<#
  test-native-stderr-eap.ps1 - the frozen fixture for the 2026-08-22 exit-1 bug.

  FOUNDING BUG. capture-run.ps1 sets $ErrorActionPreference='Stop' and invoked its
  downstream child as:
        & powershell ... -File check-ad-cycles.ps1 -NoPull 2>&1 | ForEach-Object {...}
  In PS 5.1, redirecting a NATIVE child's stderr wraps every line in an ErrorRecord
  (NativeCommandError). Under EAP=Stop the FIRST such line is a TERMINATING error, so
  the caller died mid-script: no rc line, no browser handoff, no CAPTURE-RUN-COMPLETE,
  exit 1. 'TC Grocery Ad Pulls 0700' and 'TC Grocery Daily Capture 0800' both showed
  LastTaskResult=1 for days and the cause was invisible because the tasks ran hidden
  with no transcript. check-ad-cycles.ps1 already documented this exact rule in its own
  comments; the caller just did not follow it.

  WHY A FIXTURE AND NOT A CODE READ. The failure is a PROPERTY OF THE SHELL, not of our
  logic, so the only honest check is to make the shell do it. This file therefore has a
  MUST-FIRE case (the founding bug, which must still fail) and a CLEAN TWIN (the fixed
  shape, which must pass). If the must-fire case ever stops failing, this test is no
  longer testing anything and must be re-examined rather than trusted.

  It also scans the three SCHEDULED entry points for the bad shape, so a re-introduction
  is caught here rather than by a red task result nobody can explain.

  Exit 0 = all cases behaved. Exit 1 = a case regressed.
#>
[CmdletBinding()]
param()

$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$tmp = Join-Path $env:TEMP ("eap-fixture-" + $PID)
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$fail = 0
$n = 0

function Invoke-Case([string]$Name, [string]$Body) {
  $p = Join-Path $tmp ($Name + '.ps1')
  Set-Content -Path $p -Value $Body -Encoding UTF8
  $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $p 2>$null
  return [pscustomobject]@{ Rc = $LASTEXITCODE; Out = (@($out) -join "`n") }
}

# --- CASE 1: MUST-FIRE. The founding bug, verbatim in shape. -----------------
# A child that writes ONE stderr line and exits 0, redirected with 2>&1 under EAP=Stop.
# Correct behaviour for this case is FAILURE: rc=1 and the completion marker missing.
$n++
$c1 = Invoke-Case 'mustfire' @'
$ErrorActionPreference = 'Stop'
& powershell -NoProfile -Command "[Console]::Error.WriteLine('a warning line'); exit 0" 2>&1 | ForEach-Object { $_ }
Write-Output "COMPLETE-MARKER"
exit 0
'@
if ($c1.Rc -eq 1 -and $c1.Out -notmatch 'COMPLETE-MARKER') {
  Write-Output "  ok    must-fire: 2>&1 under EAP=Stop still kills the caller (rc=$($c1.Rc), no marker)"
} else {
  Write-Output "  FAIL  must-fire: expected rc=1 and NO marker, got rc=$($c1.Rc) marker=$($c1.Out -match 'COMPLETE-MARKER')"
  Write-Output "        This case existing-and-failing is what proves the fix below is load-bearing."
  $fail++
}

# --- CASE 2: CLEAN TWIN. The shipped fix. ------------------------------------
# Same child, same stderr, same EAP=Stop - but no redirection. Must survive, must
# reach its marker, and must still read the child's real exit code.
$n++
$c2 = Invoke-Case 'cleantwin' @'
$ErrorActionPreference = 'Stop'
$out = & powershell -NoProfile -Command "[Console]::Error.WriteLine('a warning line'); Write-Output 'child said hello'; exit 0"
$rc = $LASTEXITCODE
foreach ($l in @($out)) { Write-Output ("  " + $l) }
Write-Output ("downstream rc=" + $rc)
Write-Output "COMPLETE-MARKER"
exit 0
'@
if ($c2.Rc -eq 0 -and $c2.Out -match 'COMPLETE-MARKER' -and $c2.Out -match 'downstream rc=0') {
  Write-Output "  ok    clean-twin: unredirected child survives stderr and reports rc"
} else {
  Write-Output "  FAIL  clean-twin: expected rc=0 + marker + 'downstream rc=0', got rc=$($c2.Rc)"
  Write-Output ("        output: " + ($c2.Out -replace "`n", ' | '))
  $fail++
}

# --- CASE 3: the fix must still PROPAGATE a real child failure ---------------
# The danger in "just stop redirecting" is over-correcting into swallowing failures.
# A child that genuinely exits non-zero must still be seen as failed.
$n++
$c3 = Invoke-Case 'realfail' @'
$ErrorActionPreference = 'Stop'
$out = & powershell -NoProfile -Command "Write-Output 'work'; exit 4"
$rc = $LASTEXITCODE
Write-Output ("downstream rc=" + $rc)
if ($rc -ne 0) { exit 1 } else { exit 0 }
'@
if ($c3.Rc -eq 1 -and $c3.Out -match 'downstream rc=4') {
  Write-Output "  ok    real-failure: a genuinely failing child is still detected (rc=4 -> caller rc=1)"
} else {
  Write-Output "  FAIL  real-failure: expected caller rc=1 and 'downstream rc=4', got rc=$($c3.Rc)"
  $fail++
}

# --- CASE 3b: the browser driver's agent contract ----------------------------
# The browser driver (pull-browser-stores.py) injects pull-agent-lib.js + a store agent and calls
# functions BY NAME. If an agent renames its entry point or its storage key, the driver breaks at
# 08:00 with a ReferenceError that reads like a store outage. The driver's own --selftest proves this
# against a live browser, but that costs a Chrome launch per store; this is the cheap source-level
# half, so a rename is caught by the daily suite rather than by a red task.
$n++
$drvPath = Join-Path $root 'pull-browser-stores.py'
if (-not (Test-Path $drvPath)) {
  Write-Output '  skip  browser-driver contract: pull-browser-stores.py not present'
} else {
  $drv = Get-Content $drvPath -Raw
  $contractBad = @()
  # TWO LANES, TWO CONTRACTS (updated 2026-08-22 when Fareway moved lanes - and this check FAILED on
  # that change, which is the point of it).
  #   paced   Walmart, Sam's Club: runPacedSweep over a term list, results in localStorage under a
  #           storage key, exported by a *SweepToCsv function.
  #   navigate Fareway: the storefront went client-rendered, so there is nothing for a same-origin
  #           fetch to read. The driver navigates per term and calls farewayShopExtract, which reads
  #           the Apollo cache. No sweep function, no storage key - asserting them here would be
  #           asserting the dead contract. farewayIdentity still comes from the instore file and is
  #           load-bearing: it proves BOTH the Omaha location and In-Store mode, which is what
  #           licenses -ModeVerified downstream.
  foreach ($pair in @(
      @{ Agent = 'pull-walmart-instore.js'; Fns = @('pullWalmartInStore', 'walmartSweepToCsv'); Key = 'TC_WALMART_SWEEP' },
      @{ Agent = 'pull-sams-instore.js';    Fns = @('pullSamsInStore', 'samsSweepToCsv');       Key = 'TC_SAMS_SWEEP' },
      @{ Agent = 'pull-fareway-instore.js'; Fns = @('farewayIdentity');                         Key = '' },
      @{ Agent = 'pull-fareway-shop.js';    Fns = @('farewayShopExtract');                      Key = '' })) {
    $ap = Join-Path $root $pair.Agent
    if (-not (Test-Path $ap)) { $contractBad += ($pair.Agent + ' is missing'); continue }
    $asrc = Get-Content $ap -Raw
    foreach ($fn in $pair.Fns) {
      if ($asrc -notmatch [regex]::Escape($fn)) { $contractBad += ("$($pair.Agent) no longer defines $fn") }
      if ($drv  -notmatch [regex]::Escape($fn)) { $contractBad += ("the driver no longer calls $fn") }
    }
    if ($pair.Key) {
      if ($asrc -notmatch [regex]::Escape($pair.Key)) { $contractBad += ("$($pair.Agent) no longer uses $($pair.Key)") }
      if ($drv  -notmatch [regex]::Escape($pair.Key)) { $contractBad += ("the driver no longer expects $($pair.Key)") }
    }
  }
  # Fareway's In-Store assertion is the whole basis for stamping -ModeVerified from a script. If it
  # ever stops asserting the mode, that flag becomes a claim nobody checked.
  $fwId = Get-Content (Join-Path $root 'pull-fareway-instore.js') -Raw -ErrorAction SilentlyContinue
  if ($fwId -and $fwId -notmatch 'In-Store') {
    $contractBad += 'farewayIdentity no longer asserts In-Store - capture-run stamps -ModeVerified on the strength of it'
  }
  if (-not $contractBad.Count) {
    Write-Output '  ok    browser-driver contract: every agent entry point and storage key the driver names still exists'
  } else {
    Write-Output ('  FAIL  browser-driver contract drift: ' + ($contractBad -join '; '))
    Write-Output '        The 08:00 capture calls these BY NAME - a rename fails the pull, not the test.'
    $fail++
  }
}

# --- CASE 4: the scheduled entry points must not carry the bad shape ---------
# The three TC Windows tasks are, as of 2026-08-22, the ONLY routines that fire.
# A reintroduction here is invisible until a task goes red, so scan for it.
$n++
$scan = @('capture-run.ps1', 'capture-watchdog.ps1', 'capture-policy.ps1')
$bad = @()
foreach ($f in $scan) {
  $p = Join-Path $root $f
  if (-not (Test-Path $p)) { continue }
  $lines = Get-Content $p
  # Only the MAIN body matters: a Start-Job scriptblock runs in its own runspace
  # with the default EAP='Continue', where the redirect is harmless and useful.
  $inJob = $false
  for ($i = 0; $i -lt $lines.Count; $i++) {
    $l = $lines[$i]
    if ($l -match 'Start-Job')      { $inJob = $true }
    if ($inJob -and $l -match '^\s*\}\s*-ArgumentList') { $inJob = $false; continue }
    if ($inJob) { continue }
    # ANY native command, not just powershell (widened 2026-08-22). The narrow pattern let
    # `& git ... 2>$null` through in capture-run.ps1's publish stage, and on that stage's FIRST real run
    # git exited nonzero on a pathspec matching nothing, the redirect made it terminating, and the whole
    # commit/push threw - so the day's prices did not ship. Same bug class, different executable, and the
    # test that exists to catch the class could not see it. Both redirect forms, any native command.
    if ($l -match '^\s*[^#]*&\s*(powershell|git|python|node|npm|wrangler|nvidia-smi|robocopy|taskkill)[^|]*2>(&1|\$null)') { $bad += ("{0}:{1}" -f $f, ($i + 1)) }
  }
}
if (-not $bad.Count) {
  Write-Output "  ok    entry-point scan: no native child has its stderr redirected in a main body under EAP=Stop"
} else {
  Write-Output ("  FAIL  entry-point scan: the founding bug shape is back at " + ($bad -join ', '))
  Write-Output '        Capture the child into a variable and read $LASTEXITCODE instead of redirecting.'
  $fail++
}

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
Write-Output ("NATIVE-STDERR-EAP-TEST-COMPLETE cases={0} failed={1}" -f $n, $fail)
if ($fail) { exit 1 } else { exit 0 }
