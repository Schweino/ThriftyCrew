<#
  run-gates.ps1 - the CHANGE-TIME gate. Everything provable without live data, run on every push.

  WHY THIS EXISTS (2026-08-08). This estate had 60 detectors, 324 scripts and 62,000 lines of PowerShell,
  and NOTHING ran when the code changed. Both GitHub workflows were `schedule:` only and there were zero git
  hooks, so every guard was policed by a clock: a bad commit shipped and was caught the next morning at best.
  That gap matters more now that the standing rule is to push every commit immediately - the day this was
  written, 12 commits went to main in one push through no automated gate at all.

  WHAT IT CAN AND CANNOT CHECK, and why the scope is what it is. A clean checkout has no board:
  grocery\out\comparison-*.json is gitignored, so guards.ps1, tile-integrity and every data audit would be
  BLIND on a runner - and a blind check that reports success is the exact failure this estate keeps writing
  guards about. So this gate deliberately runs only what is hermetic:

    1. every -SelfTest in the tree. That is the real payload. Each one drives frozen must-fire fixtures of a
       founding bug plus its clean twin, needs no data, no network and no secrets, and fails loudly when a
       fix stops being able to detect the thing it was written for.
    2. the static-analysis detectors that read SOURCE rather than data (guard contract, cloud readiness,
       script census) - the ones that catch a guard going dead, losing its completion marker, or becoming
       unreachable.

  The data-dependent audits stay where they are, in the daily chain against a real board. This gate answers
  "did this change break the machinery?", not "is today's board correct".

  Exit 0 = every gate passed. 1 = at least one failed. 3 = could not evaluate (found no self-tests at all,
  which would mean the discovery is broken rather than the tree being clean).
#>
param([switch]$ListOnly)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\ops' }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')

# Self-tests that cannot run hermetically, with the reason. Keyed by file name, same standard as every other
# allowlist here: a line is a decision someone defends in a diff, not a way to make the gate quiet.
$SKIP = @{
  'check-ad-cycles.ps1' = 'the daily chain itself - running it would execute the whole pipeline, not test it'
  # test-auditors is NOT hermetic and cannot be made so cheaply: it drives the real audits against the real
  # board, and grocery\out\comparison-*.json is gitignored. On gates run #2 it failed with
  # "food-category clean twin failed (rc=3)" - rc=3 is could-not-evaluate, i.e. it went BLIND for want of a
  # board, not because anything was broken. Gating pushes on that would train everyone to ignore a red gate,
  # which is worse than not having one. It runs every day in check-ad-cycles against a real board, where its
  # 418 checks mean something. Excluded here on purpose, not overlooked.
  'test-auditors.ps1'   = 'data-dependent: needs a real board, which a clean checkout does not have (out\comparison-*.json is gitignored). Runs daily in the chain instead.'
}

$scripts = @(Get-ChildItem $repo -Recurse -File -Filter *.ps1 -ErrorAction SilentlyContinue |
  # \out\ is the pipeline's OUTPUT directory. Scripts that land there are one-offs and debris (the script
  # census counts 37 of them); running their self-tests would gate every push on abandoned scratch work.
  Where-Object { $_.FullName -notmatch '\\worktrees\\|\\archive\\|node_modules|\.venv|\\out\\' } |
  Sort-Object FullName)

$withSelfTest = @()
foreach ($s in $scripts) {
  if ($SKIP.ContainsKey($s.Name)) { continue }
  # NEVER DISCOVER YOURSELF. run-gates runs every file it discovers with -SelfTest; discovering this
  # file means running this file, which discovers it again. On 2026-09-01 a COMMENT added here quoted
  # the switch declaration in prose, the matcher below saw its own text, and run-gates spawned a fresh
  # copy of itself every two minutes for 39 minutes - 18 live processes, each blocked on its child,
  # and not one line of output. The guard is one line and costs nothing; the failure it prevents is
  # unbounded.
  if ($s.FullName -eq $PSCommandPath) { continue }
  $t = [IO.File]::ReadAllText($s.FullName)
  # IT MUST ACCEPT THE SWITCH, NOT MERELY MENTION IT IN PROSE - and until 2026-09-01 that rule was
  # stated here and not enforced, because the match ran over the file INCLUDING its comments. Comment
  # lines are stripped first now, so writing about the switch can never enrol a script that does not
  # take it. This file's own recursion is the proof; the same shape would quietly enrol any script
  # whose header merely discusses self-testing, and then fail it for not accepting the argument.
  $code = ($t -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
  if ($code -match '\[switch\]\$SelfTest' -or $code -match '\$__\w*SelfTest\s*=') { $withSelfTest += $s }
}

if ($ListOnly) {
  Write-Output ("self-tests discovered: {0}" -f $withSelfTest.Count)
  $withSelfTest | ForEach-Object { Write-Output ('  ' + $_.FullName.Replace($repo, '')) }
  exit 0
}

if (-not $withSelfTest.Count) {
  Write-Output 'run-gates: COULD NOT EVALUATE - discovered zero self-tests, which means this discovery is broken, not that the tree is clean'
  Write-GuardComplete -Name 'run-gates' -Summary 'blind=no-selftests'
  exit 3
}

$pass = 0; $fail = @()
Write-Output ("run-gates: {0} self-test(s) discovered" -f $withSelfTest.Count)
foreach ($s in $withSelfTest) {
  $rel = $s.FullName.Replace($repo, '').TrimStart('\')
  # NO 2>&1: merging a child's stderr under EAP=Stop makes its first stderr line a terminating throw in THIS
  # script. That trap has bitten test-auditors, guards and check-ad-cycles in this estate already.
  $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $s.FullName -SelfTest
  $rc = $LASTEXITCODE
  if ($rc -eq 0) { $pass++; Write-Output ("  ok    {0}" -f $rel) }
  else {
    $fail += $rel
    Write-Output ("  FAIL  {0}  (exit {1})" -f $rel, $rc)
    # THE EXCERPT MUST SHOW THE FAILURES (2026-08-08). This was `-match '(?i)fail|X '` capped at 5 lines, and
    # '(?i)...x ' matches the "x " inside words - "mutex + atomic swap" scored as a hit. On gates run #2 that
    # spent 3 of the 5 slots on PASSING lines and hid 3 of test-auditors' 4 failures from the log entirely,
    # so the run read as one broken watcher when it was four. Anchored to the FAIL/X markers, and 12 lines.
    @($out) | Where-Object { $_ -match '^\s*(FAIL|X)\b' -or $_ -match '(?-i)SELF-TEST FAIL' } |
      Select-Object -First 12 | ForEach-Object { Write-Output ('          ' + $_) }
    if (@($out).Count -gt 0) { Write-Output ('          ...' + (@($out).Count) + ' line(s) of output in total') }
  }
}

# ---- static-analysis detectors: they read SOURCE, so they work on a bare checkout ----
$static = @(
  @{ f = 'grocery\audit-guard-contract.ps1';   n = 'every chain detector can prove it ran, none are dead or half-covered' }
  @{ f = 'grocery\audit-cloud-readiness.ps1';  n = 'every credential consumer in the chain can run on a runner' }
  @{ f = 'grocery\audit-script-census.ps1';    n = 'no script is unreachable and unrecorded' }
  @{ f = 'grocery\audit-json-encoding.ps1';    n = 'the matching rules are still in the encoding they were written in' }
  @{ f = 'grocery\audit-instore-shutout.ps1';  n = 'no NEW commodity has quietly lost every shelf row at a store' }
  # BOTH HALVES, for the reason spelled out under audit-twin-drift below: the discovery pass proves the
  # matcher can still tell a sweep from an ownership list, and THIS entry runs it over the real tree,
  # which is what catches the next script to be written with a bare `git add`. Four incidents in seven
  # weeks, every one of them fixed only in the file that caused it (2026-09-06, PLAN-top5 area 3).
  @{ f = 'ops\audit-git-sweepers.ps1';         n = 'no tracked script stages by sweep - every git add names what it owns' }
  # Same both-halves reason again: the discovery pass proves the scanner can still tell a frozen fixture
  # from a live ruling; this entry runs it over the real tree, which is what catches the NEXT self-test
  # written to read its own live allowlist (2026-09-06, PLAN-top5 area 4).
  @{ f = 'ops\audit-fixture-inputs.ps1';       n = 'no self-test rests its verdict on a live rulings file the harness never froze' }
  # A must-fire that BREAKS turns its own line red and everybody sees it. One that is DELETED leaves a
  # green suite with one fewer case, and nobody counts tallies ([[exit-code-first-tally-second]]).
  @{ f = 'ops\audit-mustfire-census.ps1';      n = 'no self-test has quietly lost a must-fire assertion' }
  # BOTH HALVES AGAIN, and here the live half is the whole point. The discovery pass above runs this
  # file's -SelfTest and proves the enumeration works against a frozen root; THIS entry runs it against
  # the REAL root, which is the only place the debris actually lands. .gitignore line 3 is `/*`, so the
  # root is ignored by default and nothing else in this estate can see a stray there - two artifacts sat
  # for days, and writing the detector turned up two more nobody had recorded (2026-09-06, backlog I2).
  @{ f = 'ops\audit-stray-root-artifacts.ps1'; n = 'no debris at the repo root - the one directory nothing else can see' }
  # THE E1 SAFETY LAYER IS ONLY AS GOOD AS ITS CHOKEPOINT BEING THE ONLY DOOR. The staging gate and the
  # journal hook Invoke-GhostApi; 17 mutating calls to Ghost, thriftycrew.com and the Cloudflare API go
  # around it entirely, ten of them in .claude\skills\lesson. A ratchet, so the number can only fall
  # (2026-09-06, backlog E1).
  @{ f = 'ops\audit-write-seam.ps1';           n = 'no NEW irreversible write bypasses the E1 safety layer' }
  # BOTH HALVES OF THIS FILE MATTER AND ONLY ONE IS DISCOVERED. The discovery pass above picks up its
  # self-test and proves the comparison logic works; THIS entry runs it against the real tree, which
  # is what actually catches a rule whose two copies have stopped agreeing. Registering the self-test
  # alone would repeat the exact failure the auditor was written for - a check that works and never
  # looks at production.
  # (This comment deliberately does NOT spell the switch declaration out. Writing it in prose here is
  # what made run-gates discover ITSELF on 2026-09-01 and respawn every two minutes for 39 minutes.)
  @{ f = 'ops\audit-twin-drift.ps1';           n = 'no rule this estate keeps in two files has drifted apart' }
  # THE COST ENGINE'S GOLDEN TEST, ungated until 2026-09-01 and the only thing that caught a schema
  # change to costed.json the same day. It has no -SelfTest switch, so the discovery pass above cannot
  # see it, and it was in no static list either - the identical hole coverage_check.py was sitting in.
  # It is hermetic (frozen inputs, its own -OutFile) so it runs anywhere, and it is the only check that
  # compares the engine's ACTUAL output against an accepted baseline rather than re-deriving from it.
  @{ f = 'meal-prep\engine\golden-test.ps1';   n = 'the cost engine still produces its accepted output from frozen inputs' }
)
foreach ($g in $static) {
  $p = Join-Path $repo $g.f
  if (-not (Test-Path $p)) { $fail += $g.f; Write-Output ("  FAIL  {0} is missing" -f $g.f); continue }
  $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $p
  $rc = $LASTEXITCODE
  if ($rc -eq 0) { $pass++; Write-Output ("  ok    {0}  ({1})" -f $g.f, $g.n) }
  else {
    $fail += $g.f
    Write-Output ("  FAIL  {0}  (exit {1}) - {2}" -f $g.f, $rc, $g.n)
    @($out) | Where-Object { $_ -match '!|FAIL' } | Select-Object -First 12 | ForEach-Object { Write-Output ('          ' + $_) }
  }
}

# ---- PYTHON self-tests -----------------------------------------------------------------------------
# THE DISCOVERY ABOVE READS *.ps1 AND NOTHING ELSE, so every Python suite in this estate was ungated.
# coverage_check.py carries the recipe QA battery - coverage, scaling ratios, prose numbers, and the
# mass reader that decides a recipe's main protein weight - and on 2026-09-01 it was found sitting at
# two failures that had been red for weeks with nobody watching: its protein pattern had drifted out
# of lockstep with spec-contradiction-lib.ps1 (reading "47.3g protein" as 3g, a false fail against a
# correct spec), and a splitting case had flipped when the estate learned a head noun. Both were real,
# both were invisible, and the same file had just produced a 7x mass error. A suite nobody runs is a
# suite that rots.
$pySuites = @(
  @{ f = 'meal-prep\pipeline\coverage_check.py'; a = '--selftest'; n = 'the recipe QA battery: coverage, scaling, prose numbers, the mass reader' }
)
# AN INTERPRETER IT CANNOT FIND IS A FAILURE, NEVER A SKIP. Bare `python` on this machine is the
# Windows Store shim, which exits 49 without running anything - a "pass" that ran no test is exactly
# the blindness this section exists to end, so the candidates are probed and a miss is reported loudly.
$pyExe = $null
foreach ($cand in @('C:\Codex\Python312\python.exe', 'python3', 'python')) {
  try {
    $v = & $cand --version 2>&1
    if ($LASTEXITCODE -eq 0 -and ([string]$v) -match 'Python\s+3') { $pyExe = $cand; break }
  } catch { }
}
foreach ($g in $pySuites) {
  $p = Join-Path $repo $g.f
  if (-not (Test-Path $p)) { $fail += $g.f; Write-Output ("  FAIL  {0} is missing" -f $g.f); continue }
  if (-not $pyExe) {
    $fail += $g.f
    Write-Output ("  FAIL  {0} - no Python 3 interpreter found, so this battery DID NOT RUN" -f $g.f)
    continue
  }
  $out = & $pyExe $p $g.a 2>&1
  $rc = $LASTEXITCODE
  if ($rc -eq 0) { $pass++; Write-Output ("  ok    {0}  ({1})" -f $g.f, $g.n) }
  else {
    $fail += $g.f
    Write-Output ("  FAIL  {0}  (exit {1}) - {2}" -f $g.f, $rc, $g.n)
    @($out) | Where-Object { $_ -match '^FAIL|SELF-TEST FAIL' } | Select-Object -First 12 | ForEach-Object { Write-Output ('          ' + $_) }
  }
}

Write-Output ''
Write-Output ("run-gates: {0} passed, {1} failed" -f $pass, $fail.Count)
foreach ($f in $fail) { Write-Output ("  failed: " + $f) }
# A WORDS-LEVEL VERDICT ON EVERY EXIT PATH, NOT ONLY ON 3 (2026-09-06, backlog E2). The could-not-evaluate
# path above has said "COULD NOT EVALUATE" in words since it was written; these two said only "186 passed,
# 1 failed", which is a TALLY and not a verdict - a reader still has to know that this tool's 1 means
# failed, when the same 1 means "findings, report written" in the PLAN v3 batteries and the guard-contract
# audits reserve 2 for a hard finding and 3 for could-not-evaluate. Three live vocabularies, so the number
# is not a channel an agent can decode without knowing which tool it ran. The words are.
if ($fail.Count) {
  Write-Output ("run-gates: FAILED - {0} gate(s) did not pass. This tree must not be pushed until they do; fix the cause, never the gate." -f $fail.Count)
} else {
  Write-Output ("run-gates: PASSED - all {0} gate(s) passed." -f $pass)
}
Write-GuardComplete -Name 'run-gates' -Summary ("pass={0} fail={1}" -f $pass, $fail.Count)
exit $(if ($fail.Count) { 1 } else { 0 })
