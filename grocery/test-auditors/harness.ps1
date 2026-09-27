
# FIXTURES RUN COPIES OF DETECTORS, and every detector carrying the completion contract dot-sources
# lib\guard-contract.ps1 (and most lib\json-io.ps1) from its PARENT directory. For a fixture copy that parent
# is the directory holding the fixture directory, and with no lib\ there the copy died on its second line and
# every tile-integrity, name-drift, coverage-ledger and match-soundness assertion failed with "the term
# ...\lib\guard-contract.ps1 is not recognized". The harness already ships SIBLING libs into fixture dirs
# (verdict-lib, alert-lib, coverage-lib); this is the same convention one level up, done once for all of them.
#
# ONE ROOT PER RUN, AND EVERY LIBRARY IN IT (2026-09-11). Until then that lib\ was ONE FIXED %TEMP%\lib, shared
# by every run of this harness from every checkout on the box and filled from a HAND LIST: guard-contract here
# with -Force, and json-io in NewFxDir only when the source was NEWER by mtime. Two consequences. A library
# dropped from the list could not go red on a box that had run this harness before, because the copy an earlier
# run left behind answered the dot-source. And a run could load a library another checkout had copied there,
# because a -Force copy from a concurrent run, or an older-mtime source, left the other bytes in place. The same
# hand-list shape blinded ops\test-prepush-hook.ps1 until c17cc59a7. Now each run allocates its own root under
# %TEMP%, copies every lib\*.ps1 into <root>\lib, and NewFxDir makes every fixture directory inside that root,
# so a fixture copy's parent lib\ is this run's and this checkout's. The root is created with -ErrorAction Stop,
# so a clash refuses rather than shares, and it is Register-Fx'd, so the finally at the end sweeps it.
# Unit u142 proves the copy is complete and that a missing or stale library is named.
$script:FxRoot = Register-Fx (Join-Path $env:TEMP ('tarun-' + [guid]::NewGuid().ToString('N').Substring(0, 8)))
New-Item -ItemType Directory -Path $script:FxRoot -ErrorAction Stop | Out-Null
$script:FxLibSource = Join-Path (Split-Path $root -Parent) 'lib'
$fxLibDir = Join-Path $script:FxRoot 'lib'
New-Item -ItemType Directory -Path $fxLibDir -ErrorAction Stop | Out-Null
foreach ($fxLibFile in @(Get-ChildItem -LiteralPath $script:FxLibSource -Filter '*.ps1' -File)) {
  Copy-Item -LiteralPath $fxLibFile.FullName -Destination (Join-Path $fxLibDir $fxLibFile.Name) -ErrorAction Stop
}
# THE LIVE-DATA CASES (2026-08-08). Most of this harness drives frozen fixtures, but a handful of cases
# assert against the REAL board (out\comparison-*.json / out\recipe-board.json) or the REAL .claude prompt
# tree. Both are gitignored, so on the change-time gate's bare checkout those cases were not failing - they
# were never able to RUN, and "could not run" printed as FAIL. That is what took gates run #2 red on
# 2026-08-08 while nothing was broken. They now SKIP when the data is absent, and the SKIP is counted and
# printed in both summaries, so a machine that HAS the data still fails exactly as loudly as before.
# LIVE-TWIN on purpose (ops\audit-fixture-inputs.ps1, 2026-09-11): these two lines only ask whether a real board is
# here, so the live-data cases SKIP rather than FAIL where it is not. ops\prepush-test-auditors.ps1 reads this
# assignment and its -or continuation, so the first line must keep ending in -or.
$HasBoard = (@(Get-ChildItem (Join-Path $root 'out\comparison-*.json') -ErrorAction SilentlyContinue).Count -gt 0) -or
            (Test-Path (Join-Path $root 'out\recipe-board.json'))   # LIVE-TWIN: the same presence probe
function Ok($m)   { Write-Output ("  PASS  " + $m); $script:pass++ }
function Bad($m)  { Write-Output ("  FAIL  " + $m); $script:failed++ }
# A case that could not run is NOT a pass. It gets its own counter and its own line in BOTH summaries, so
# "every watcher can still see its own bug" can never be printed over a case that never executed.
function Skip($m) { Write-Output ("  SKIP  " + $m); $script:skipped++ }
# HYGIENE: a finding about the ESTATE'S HOUSEKEEPING, not about a watcher's eyesight. It is still reported,
# still counted, still paged - through its own subject - but it may never claim the board is unproven.
# Use it ONLY where the check itself is working and what it found is a stale copy, a missing mirror, an
# uncommitted artefact. A check that cannot SEE stays Bad: "the backup is out of date" and "the backup
# checker went blind" are opposite findings.
function Hygiene($m) { Write-Output ("  HYGIENE  " + $m); $script:hygiene++ }
# LIVE-RED: a finding about the LIVE BOARD, not about a watcher's eyesight (2026-09-20, queue 2026-09-19-ae9df2).
# This file asks TWO questions of one run - can each watcher still see its founding bug, and does the LIVE
# board still pass the watchers - and it kept ONE tally for both, so a LIVE-TWIN red (the watcher WORKING, on
# a real bad cell) exited 2 and paged "a GUARD has gone blind ... any quiet report from that guard is
# unproven - including a clean board". That sentence INVERTS the day's trust ordering: on a live-board red
# the watchers are the one thing the run proved. Three such pages in 30 days (2026-08-28, 2026-08-29,
# 2026-09-19) and not one of them was a blind watcher.
# Use it ONLY where the case's SUBJECT is live data (a LIVE-TWIN) and the watcher itself ran and reported.
# A case that could not SEE stays Bad: "the live board has a bad cell" and "the watcher went blind" are
# opposite findings, and rc 2 still outranks rc 4 whenever both happen.
function Live($m) { Write-Output ("  LIVE-RED  " + $m); $script:live++ }
# UNITS AND SELECTIVE RUNS (2026-09-10, design\PLAN-zero-alert-days-2026-09-10.md, ruling R19).
# Every case below sits inside `if (Use-Unit '<id>' ...) { ... }`. A push that touches one guard input used to
# run all of them for five minutes; ops\prepush-test-auditors.ps1 now derives, from each unit's own code, what
# it reads and runs, and hands this file the units a push CANNOT reach. Three rules keep that honest:
#   * THE LIST IS OF UNITS TO SKIP, NOT UNITS TO RUN. An id nobody named runs, so a unit the selector could
#     not read, or a unit added after it looked, fails toward running rather than toward silence.
#   * FUNCTION DEFINITIONS, DOT-SOURCES AND Add-Type STAY OUTSIDE THE WRAPPERS, so a helper defined in one
#     unit still exists when that unit is skipped. A unit that reads a VARIABLE another unit assigns is kept
#     together with it by the selector's def-use pass, never by this file.
#   * A SELECTIVE RUN NEVER READS AS A PASS. It prints how many units it ran and names itself SELECTIVE, and
#     its exit code keeps the full run's meaning (2 = a case it ran failed).
# -Reads and -Always are declarations for the selector, for what a unit's code cannot show: a child that scans
# the live tree. The harness ignores them. The daily chain passes no -SkipUnitsFile, so it runs every unit.
# A skip file that was named and cannot be read runs EVERY unit and says so.
$script:SkipUnits    = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
$script:UnitsRan     = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
$script:UnitsSkipped = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
if ($SkipUnitsFile) {
  try {
    foreach ($suLine in [IO.File]::ReadAllLines($SkipUnitsFile)) { $suId = $suLine.Trim(); if ($suId -and -not $suId.StartsWith('#')) { [void]$script:SkipUnits.Add($suId) } }
  } catch {
    $script:SkipUnits.Clear()
    Write-Output ("test-auditors: the skip file '" + $SkipUnitsFile + "' could not be read (" + $_.Exception.Message + "), so EVERY unit runs")
  }
}
function Use-Unit {
  param([Parameter(Mandatory = $true, Position = 0)][string]$Id, [string[]]$Reads = @(), [string]$Always = '')
  if ($script:SkipUnits.Contains($Id)) { [void]$script:UnitsSkipped.Add($Id); return $false }
  [void]$script:UnitsRan.Add($Id)
  return $true
}
# THE VERDICT, AS A PURE FUNCTION so the two cases below can drive it without running a 600-check suite.
# rc 2 = a watcher has gone blind (BLIND-class, publish-holding, the loudest page in the estate)
# rc 4 = every watcher fires; a LIVE-TWIN case found a bad cell on the LIVE board (2026-09-20, ae9df2)
# rc 1 = every watcher still fires; ops hygiene drift was found (guard-contract's "findings")
# rc 0 = clean
# ORDER MATTERS: failed wins over live, and live wins over hygiene. A run that is BOTH blind and carrying a
# live red pages as BLIND, because a blind watcher makes the live verdict itself unprovable.
function Get-AuditorsVerdict([int]$failed, [int]$hygiene, [int]$pass, [int]$skipped, [int]$live = 0) {
  $skipNote = if ($skipped) { ", $skipped SKIPPED (proved nothing - see the SKIP lines)" } else { '' }
  $hygNote  = if ($hygiene) { ", $hygiene HYGIENE" } else { '' }
  if ($failed -gt 0) {
    return @{ rc = 2; line = ("test-auditors FAIL  ($failed failed, $pass passed$hygNote$skipNote) - a watcher has gone blind. Fix it before trusting a quiet board.") }
  }
  if ($live -gt 0) {
    # THE WORDING IS LOAD-BEARING: a reader and a grep sort on "gone blind" and "unproven", so this line
    # carries neither. u071 asserts that.
    return @{ rc = 4; line = ("test-auditors LIVE-RED ($live live case(s) failed, $pass passed$hygNote$skipNote) - every watcher still sees its own founding bug; the LIVE board failed a watcher, open the board before the code.") }
  }
  if ($hygiene -gt 0) {
    return @{ rc = 1; line = ("test-auditors HYGIENE ($hygiene) - every watcher still sees its bug ($pass check(s) passed$skipNote); ops hygiene drift listed above. The board is NOT unproven.") }
  }
  return @{ rc = 0; line = ("test-auditors PASS  ($pass check(s)$skipNote) - every watcher that could run can still see its own bug.") }
}
function RunPS($script, $argList) {
  # A DELEGATED CHILD'S STDERR MUST NOT KILL THIS HARNESS (2026-08-08). In PS 5.1, merging with 2>&1 while
  # $ErrorActionPreference is 'Stop' turns the child's FIRST stderr line into a terminating NativeCommandError
  # in THIS script. test-guards deliberately writes one (guard 19's "a delegated audit is allowed to write to
  # stderr" fixture), so this harness died at that call on every run: 9 checks in, exit 1, last line a
  # cheerful PASS and no FAIL anywhere. That is the exact founding shape test-auditors exists to catch,
  # happening inside test-auditors - and it was invisible until the completion marker went missing.
  # The merge is deliberate (assertions read the child's stderr); only the throw is unwanted.
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { $out = PSChild (Join-Path $root $script) @argList | ForEach-Object { [string]$_ } }
  finally { $ErrorActionPreference = $prev }
  return [pscustomobject]@{ rc = $LASTEXITCODE; text = ($out -join "`n") }
}

function RunPSMany {
  # THE SAME CHILD, N AT A TIME (2026-08-23). Three of this suite's checks were 154 of its 467 seconds -
  # three full runs of one auditor over three frozen boards, run one after another for no reason but that
  # RunPS is synchronous. Independent inputs, independent outputs, verdicts read only from each child's own
  # stdout: nothing about running them together can change an answer, and the suite gets ~100 seconds back.
  #
  # RUNSPACES, NOT Start-Job. PS 5.1 has no ForEach-Object -Parallel, and Start-Job pays a whole extra
  # powershell.exe per unit of work on top of the one we already spawn. A runspace pool costs a thread.
  #
  # THE STDERR RULE IS UNCHANGED AND STILL THE ONLY SHAPE HERE. Each runspace dot-sources native-lib and
  # calls Invoke-NativeScript exactly as PSChild does, so the child's stderr is merged inside a call that
  # has forced EAP='Continue' for the duration - never by a redirect written here. A runspace also carries
  # its OWN preference variables, so this thread starts at 'Continue' rather than inheriting this file's
  # 'Stop'; that is belt and braces, not the guarantee. The guarantee is Invoke-Native.
  #
  # A WORKER THAT DIES BECOMES A FAILED CASE, NOT A MISSING ONE. EndInvoke rethrows in the parent, and an
  # escaping throw under EAP='Stop' would end the suite mid-run with a cheerful PASS as its last line -
  # the exact shape this harness exists to catch. Caught here, it comes back as rc=-1 with the message as
  # its text, so the caller's own assertion fails loudly and the counts still add up.
  param([object[]]$Calls)
  $lib = Join-Path $root 'native-lib.ps1'
  $sb = {
    param([string]$Lib, [string]$Path, [object[]]$Argv)
    $ErrorActionPreference = 'Continue'
    . $Lib
    $res = Invoke-NativeScript $Path @Argv
    [pscustomobject]@{ rc = $res.ExitCode; text = ((@($res.Lines) | ForEach-Object { [string]$_ }) -join "`n") }
  }
  $calls = @($Calls)
  $pool = [runspacefactory]::CreateRunspacePool(1, [Math]::Max(1, $calls.Count))
  $pool.Open()
  $jobs = @()
  foreach ($c in $calls) {
    $ps = [powershell]::Create()
    $ps.RunspacePool = $pool
    [void]$ps.AddScript([string]$sb).AddArgument($lib).AddArgument((Join-Path $root $c.script)).AddArgument([object[]]@($c.args))
    $jobs += [pscustomobject]@{ ps = $ps; handle = $ps.BeginInvoke() }
  }
  $out = @()
  foreach ($j in $jobs) {
    try { $out += @($j.ps.EndInvoke($j.handle)) }
    catch { $out += [pscustomobject]@{ rc = -1; text = ('RunPSMany worker failed: ' + $_.Exception.Message) } }
    finally { $j.ps.Dispose() }
  }
  $pool.Close(); $pool.Dispose()
  return $out
}

# ---- TIER 1: THE FIVE LONGEST CHILDREN, LAUNCHED EARLY (2026-09-09) ---------------------------------
# MEASURED, not guessed. PSChild was instrumented for one run (then restored and verified byte-identical
# by md5): 271 child spawns, 268.8s of child time, 69% of the run. These five are 116.3s of that 268.8s -
# test-matcher-parity 34.9s, audit-spec-contradictions 32.3s, test-match-lib 24.9s, audit-script-census
# 13.6s, fanout-lib 10.6s - and every other child is under 6s. Run one after another they are two
# minutes of this suite doing nothing but waiting.
#
# WHY THESE FIVE AND NOT THE OTHER 148 SITES. None of them passes -ReportDir, -OutDir or -OutFile. That
# matters more than their size: 82 of the 101 children that DO pass an output path share it with another
# child, so batching those needs each one given its own directory first. These five write nowhere, so
# they are the tranche that needs no collision work at all. The rest is Tier 2/3 in the plan.
#
# THAT WAS FALSE FOR ONE OF THEM (2026-09-11). audit-spec-contradictions wrote its report to the TRACKED
# meal-prep\out\spec-contradictions.json on every run, with CRLF under PS 5.1, so every full pre-push run
# left the pushing checkout modified and the post-push `git rebase origin/main` refused. It now takes
# -ReportDir. The launch and the harvest pass the SAME temp directory, because Get-Early's synchronous
# fallback must run the identical child.
#
# THE PATTERN IS guards.ps1's Register-Kid/Wait-Kid, and the property that makes it safe is stated there:
# harvest at the ORIGINAL call site, so every assertion keeps its text AND its position in the report.
# Same process boundary, same arguments, same exit code, same artifacts. Only the waiting overlaps.
#
# GET-EARLY SETS $LASTEXITCODE, for the same reason Wait-Kid does: two of the five call sites read
# $LASTEXITCODE rather than an rc property, and their conditionals stay the exact text they were.
#
# NOT LAUNCHED DEGRADES TO THE OLD BEHAVIOUR. Get-Early takes the path and args too, so a key that was
# never started - a typo, a file that did not exist at launch time - runs synchronously right there,
# exactly as before. A missing early launch can cost time; it can never change an answer or return
# nothing. That is the fail-open direction that is safe here, and it is safe ONLY because the fallback
# runs the identical child.
$script:EarlyPool = $null
$script:EarlyJobs = @{}
$script:EarlyDone = @{}

function Start-Early([string]$Key, [string]$Path, [object[]]$Argv) {
  # A file that is not there is left entirely to the call site's own missing-file path.
  if (-not (Test-Path $Path)) { return }
  if (-not $script:EarlyPool) {
    $script:EarlyPool = [runspacefactory]::CreateRunspacePool(1, 5)
    $script:EarlyPool.Open()
  }
  # THE STDERR RULE, UNCHANGED. Each runspace dot-sources native-lib and calls Invoke-NativeScript
  # exactly as PSChild does, so a child's stderr is merged inside a call that has forced
  # EAP='Continue' - never by a redirect written here. Same shape RunPSMany already uses.
  $sb = {
    param([string]$Lib, [string]$P, [object[]]$A)
    $ErrorActionPreference = 'Continue'
    . $Lib
    $res = Invoke-NativeScript $P @A
    [pscustomobject]@{ rc = $res.ExitCode; text = ((@($res.Lines) | ForEach-Object { [string]$_ }) -join "`n") }
  }
  $ps = [powershell]::Create()
  $ps.RunspacePool = $script:EarlyPool
  [void]$ps.AddScript([string]$sb).AddArgument((Join-Path $root 'native-lib.ps1')).AddArgument($Path).AddArgument([object[]]@($Argv))
  $script:EarlyJobs[$Key] = [pscustomobject]@{ ps = $ps; handle = $ps.BeginInvoke() }
}

function Get-Early([string]$Key, [string]$Path, [object[]]$Argv) {
  $r = $null
  if ($script:EarlyDone.ContainsKey($Key)) {
    $r = $script:EarlyDone[$Key]
  } elseif ($script:EarlyJobs.ContainsKey($Key)) {
    $j = $script:EarlyJobs[$Key]
    # A WORKER THAT DIES BECOMES A FAILED CASE, NOT A MISSING ONE - the same rule RunPSMany states.
    # EndInvoke rethrows here, and an escaping throw under EAP='Stop' would end the suite mid-run with
    # a cheerful PASS as its last line, which is the exact shape this harness exists to catch.
    try { $r = @($j.ps.EndInvoke($j.handle))[0] }
    catch { $r = [pscustomobject]@{ rc = -1; text = ('early worker failed: ' + $_.Exception.Message) } }
    finally { $j.ps.Dispose() }
    [void]$script:EarlyJobs.Remove($Key)
    $script:EarlyDone[$Key] = $r
  } else {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = PSChild $Path @Argv | ForEach-Object { [string]$_ } }
    finally { $ErrorActionPreference = $prev }
    $r = [pscustomobject]@{ rc = $LASTEXITCODE; text = ((@($out) -join "`n")) }
    $script:EarlyDone[$Key] = $r
  }
  $global:LASTEXITCODE = $r.rc
  return $r
}

