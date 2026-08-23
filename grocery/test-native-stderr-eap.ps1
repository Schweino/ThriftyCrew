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

# --- THE SHARED PATTERN, AND CASE 4: THE WATCHER MUST PROVE IT CAN STILL SEE --------
# ON 2026-08-23 THIS SCANNER WAS FOUND TO BE STRUCTURALLY BLIND. When it was "widened"
# on 08-22 a stray U+0008 (backspace) got into the pattern, right after the alternation
# group: `...|taskkill)<BS>[^|]*2>...`. No source line contains a backspace, so the
# regex could not match ANYTHING. It reported "ok" for a day while watching nothing -
# and in that day `& git fetch origin main 2>$null` was written into capture-run's push
# stage and killed the 07:00 run. A green watcher and a dead watcher looked identical.
#
# So the pattern now lives in ONE variable, used by BOTH the self-proof below and the
# tree scan, and the self-proof runs FIRST. A watcher that cannot demonstrate a catch on
# a frozen known-bad line is reported as BROKEN, never as clean. This is the only defence
# against the failure mode where the checker itself is what broke.
$BadShape = '^\s*[^#]*&\s*[^|]*\b(powershell|git|python|node|npm|npx|wrangler|py|cmd|robocopy|taskkill|nvidia-smi)\b[^|]*2>(&1|\$null)'

$n++
# FROZEN FIXTURES. Every real shape that has ever hurt us, plus the legal shapes that
# must never be accused. If the pattern stops flagging a MUST-CATCH line, or starts
# flagging a MUST-PASS one, the watcher is broken and says so.
$mustCatch = @(
  '      & git -C $repo fetch origin main 2>$null',                                  # the 2026-08-23 07:00 killer
  '  & git -C $repo add -A -- $paths 2>$null',                                       # the 2026-08-22 publish killer
  '    & powershell -NoProfile -File $cac -NoPull 2>&1 | ForEach-Object { $_ }',     # the founding bug
  '  $lastBot = (& git -C $r log -1 --format=%cd 2>$null | Select-Object -First 1)', # capture-watchdog, found blind
  '        $ceOut = & powershell -File (Join-Path $root "a.ps1") 2>$null',           # check-ad-cycles, found blind
  '    $q = & nvidia-smi --query-gpu=memory.free --format=csv 2>$null'
)
$mustPass = @(
  '      & git -C $repo fetch origin main | ForEach-Object { Write-Output $_ }',     # legal shape 1: no redirect
  '  $r = Invoke-Native "git" "-C" $repo "fetch" "origin" "main"',                   # legal shape 2: the helper
  '  # & git -C $repo fetch origin main 2>$null   <- a commented example must not fire',
  '  $out = Get-Content $f 2>$null',                                                 # a CMDLET redirect is harmless
  '  Write-Output "the text 2>$null inside a string is not a call"',
  '$x = & powershell -NoProfile -Command "& { $ErrorActionPreference=''Continue''; & ''a.ps1'' 2>&1 | Out-String }"'
)
# A `2>` INSIDE A QUOTED STRING IS THE CHILD'S REDIRECT, NOT OURS. test-auditors.ps1 runs two
# children as `& powershell ... -Command "& { $ErrorActionPreference='Continue'; ... 2>&1 ... }"`.
# That redirect executes in the CHILD, where EAP was just set to Continue - it is correct code, and
# flagging it would train the next reader to ignore this watcher. Count the quotes before the `2>`:
# an odd number means we are inside a string.
function Test-BadShape([string]$Line, [string]$Pattern) {
  if ($Line -notmatch $Pattern) { return $false }
  $i = $Line.IndexOf('2>')
  if ($i -lt 0) { return $true }
  $before = $Line.Substring(0, $i)
  if ((($before.ToCharArray() | Where-Object { $_ -eq '"' }).Count % 2) -eq 1) { return $false }
  return $true
}

$watcherBad = @()
foreach ($l in $mustCatch) { if (-not (Test-BadShape $l $BadShape)) { $watcherBad += ('MISSED: ' + $l.Trim()) } }
foreach ($l in $mustPass)  { if (Test-BadShape $l $BadShape) { $watcherBad += ('FALSE ALARM: ' + $l.Trim()) } }
if (-not $watcherBad.Count) {
  Write-Output ("  ok    watcher self-proof: the scan pattern still catches all {0} known-bad shapes and accuses none of the {1} legal ones" -f $mustCatch.Count, $mustPass.Count)
} else {
  Write-Output '  FAIL  watcher self-proof: THE SCANNER ITSELF IS BROKEN - every "ok" it prints below is worthless'
  foreach ($b in $watcherBad) { Write-Output ('        ' + $b) }
  $fail++
}

# --- CASE 5: the tree scan, over targets it DERIVES rather than a list that rots ------
# The old scan named three files. The bug class does not live in three files - it lives
# in every script that sets EAP='Stop', which is the only condition under which a native
# child's stderr can terminate anyone. So derive the target set from that fact. A file
# added to the estate tomorrow is covered the day it sets EAP='Stop'; nobody has to
# remember to add it here. check-ad-cycles.ps1 - the whole downstream chain, and the
# single most load-bearing script in the estate - was never in the old list and was
# carrying three of these.
$n++
$exempt = @(
  # native-lib.ps1 IS the sanctioned redirect. It performs it with EAP forced to
  # 'Continue', the one context where a redirect cannot terminate anyone.
  'native-lib.ps1',
  # this fixture holds the bad shapes as FROZEN STRINGS on purpose.
  'test-native-stderr-eap.ps1'
)
$bad = @()
$scanned = 0
$guarded = @()
$files = @(Get-ChildItem -Path $root -Filter *.ps1 -Recurse -ErrorAction SilentlyContinue |
           Where-Object { $_.FullName -notmatch '\\archive\\' -and $exempt -notcontains $_.Name })
foreach ($fi in $files) {
  $lines = @(Get-Content $fi.FullName -ErrorAction SilentlyContinue)
  if (-not $lines.Count) { continue }
  # ONLY EAP='Stop' SCRIPTS CAN HAVE THIS BUG. Everything else redirects harmlessly.
  if (-not ($lines -match "^\s*\`$ErrorActionPreference\s*=\s*'Stop'")) { continue }
  $scanned++
  $inJob = $false
  $eapContinueSince = -99
  for ($i = 0; $i -lt $lines.Count; $i++) {
    $l = $lines[$i]
    # a Start-Job scriptblock runs in its own runspace at the default EAP='Continue'
    if ($l -match 'Start-Job') { $inJob = $true }
    if ($inJob -and $l -match '^\s*\}\s*-ArgumentList') { $inJob = $false; continue }
    if ($inJob) { continue }
    # THE OTHER LEGAL SHAPE, and it is genuinely correct: save EAP, force 'Continue'
    # around the call, restore in a finally. bakers-daily-scan.ps1 and
    # weekly-post-capture.ps1 both invented Invoke-Native inline this way and are safe.
    # Accept it, but only within sight of the call - a guard 40 lines up proves nothing.
    # ANCHORED AT LINE START (tightened 2026-08-23). Unanchored, the `$ErrorActionPreference='Continue'`
    # that test-auditors.ps1 passes INSIDE a child's -Command string counted as a guard for the parent,
    # which it is not - the watcher was excusing a redirect on the strength of the child's setting.
    if ($l -match "^\s*(\`$\w+\s*=\s*\`$ErrorActionPreference\s*;\s*)?\`$ErrorActionPreference\s*=\s*'Continue'") { $eapContinueSince = $i }
    if ($l -match "\`$ErrorActionPreference\s*=\s*\`$prev") { $eapContinueSince = -99 }
    if (Test-BadShape $l $BadShape) {
      if (($i - $eapContinueSince) -le 8) { $guarded += ("{0}:{1}" -f $fi.Name, ($i + 1)) }
      else { $bad += ("{0}:{1}" -f $fi.Name, ($i + 1)) }
    }
  }
}
# A SCAN THAT EXAMINED NOTHING IS NOT A CLEAN SCAN. The old version did `if (-not
# (Test-Path $p)) { continue }`, so a renamed or moved entry point read as green - the
# same silent-skip shape that lets a watcher go quiet without going red.
if ($scanned -lt 4) {
  Write-Output ("  FAIL  tree scan examined only $scanned EAP=Stop script(s) - it should see at least the capture entry points and the downstream chain. A scan that found nothing to look at is BLIND, not clean.")
  $fail++
} elseif ($bad.Count) {
  Write-Output ("  FAIL  tree scan: an unguarded native stderr redirect under EAP=Stop at " + ($bad -join ', '))
  Write-Output '        Use Invoke-Native/Invoke-NativeScript (native-lib.ps1), or drop the redirect entirely.'
  $fail++
} else {
  $g = if ($guarded.Count) { " ($($guarded.Count) accepted behind an inline EAP='Continue' guard: " + ($guarded -join ', ') + ')' } else { '' }
  Write-Output ("  ok    tree scan: $scanned EAP=Stop script(s) examined, no unguarded native stderr redirect$g")
}

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
Write-Output ("NATIVE-STDERR-EAP-TEST-COMPLETE cases={0} failed={1}" -f $n, $fail)
if ($fail) { exit 1 } else { exit 0 }
