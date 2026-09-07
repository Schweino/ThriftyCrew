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
  # BOTH HALVES ONE MORE TIME. Every one of the 19 bytes this found on its first sweep was a backslash
  # eaten by an escape at authoring time, almost always in a Windows path: out\archive became
  # out<BEL>rchive because \a is BEL, pipeline\feed- became pipeline<FF>eed- because \f is form feed,
  # db\built became db<BS>uilt because \b is backspace. CLAUDE.md already names the cause; this is the
  # enforcement it never had, and the reason it needs one is that NOTHING ELSE SEES IT - the affected
  # script's own self-test stays green, grep and sed DISPLAY the damage as a merely missing character,
  # and a NUL makes grep classify the whole file as binary so every text search silently skips it
  # (2026-09-07).
  @{ f = 'ops\audit-source-control-bytes.ps1'; n = 'no tracked source file carries a raw control byte from an eaten backslash' }
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
  # AN AUDITOR THAT REPORTS INTO A FILE NOBODY OPENS IS A MEASUREMENT WITH NO CONSEQUENCE, and one whose
  # ALERT describes a consumer that does not exist is worse: it suppresses the manual repair that would
  # otherwise have happened. audit-ff-carry told its reader that confirmed victims "lead the next window's
  # slice automatically" while NOTHING read out\ff-carry-report.json, so two genuinely dropped carried items
  # were left 33 and 58 windows away in a 90-day rotation (2026-09-07, queue 2026-09-07-72756b). A ratchet:
  # plenty of these reports are legitimately human-read, so what may only go down is the COUNT.
  # REGISTERED HERE RATHER THAN LEFT TO DISCOVERY, and that distinction is the whole lesson: run-gates'
  # discovery pass runs every -SelfTest it finds, which wires the FIXTURE and not the DETECTOR.
  # audit-guard-contract caught this file shipping with no production caller - the same defect it exists
  # to detect, in the detector itself.
  @{ f = 'ops\audit-write-only-reports.ps1';   n = 'no NEW out\ report family is written by a script and read by none' }
  # THE FACT CHECK LIST, and the live half is the point: it reads the 584 real cards, which is where the
  # undeclared claims actually are. Hermetic - specs are tracked, so it works on a bare checkout. A
  # ratchet, because 340 assertions predate the field (2026-09-06, backlog E6).
  @{ f = 'meal-prep\pipeline\audit-fact-claims.ps1'; n = 'no NEW prose claim ships that the writer did not declare' }
  # Every agent declares its tools, and what a definition SAYS about them matches what it HAS. Four of
  # twelve declared none until today and inherited Write and Edit, two of them on agents whose job is a
  # verdict. An absent tools: line does not look wrong in a diff (2026-09-06, backlog E3).
  @{ f = 'ops\audit-agent-tools.ps1';          n = 'no agent silently inherits every tool, and no block claims one it lacks' }
  # A citation that does not resolve reads as AUTHORITY: the reader believes an account exists, cannot
  # reach it, and proceeds on the one-line hook with more confidence than if nothing had been cited.
  # Found two on its first run, both pointing at memories that no longer exist (2026-09-06, backlog E13).
  @{ f = 'ops\audit-memory-citations.ps1';     n = 'every cited memory resolves, and every agent can find the store' }
  # twin-drift covers CODE-to-CODE. This covers DOCUMENT-to-CODE: a ruling changes without a deploy and
  # the script enforcing it does not notice. Founding case was already live and already written down -
  # Brad's 2026-09-04 no-hardcoded-bands ruling, unimplemented and gated by nothing (backlog E12).
  @{ f = 'ops\audit-ruling-drift.ps1';         n = 'no NEW ratified ruling goes unimplemented by the code' }
  # Import-CaptureCsv dropped vendor TEST rows at ingest - the right place - and recorded the count in
  # $script:CapturePlaceholderCount, which ZERO of its callers read. A drop nobody reads is a clean
  # bill (2026-09-06, backlog E5).
  @{ f = 'ops\audit-capture-ingest-reporting.ps1'; n = 'a row dropped at ingest is reported by whoever read it' }
  # "CLEAN TWIN" meant two OPPOSITE things here - zero findings in the PowerShell audits, a HIT in
  # knowledge-search - so the standing instruction to "add a must-fire and a clean twin" could be read
  # either way, and read the wrong way it produces a fixture that passes while proving nothing about
  # over-firing. Brad ruled the knowledge-search vocabulary canonical on 2026-09-07 and the 133
  # provable cases were renamed; this keeps a new one from appearing (backlog I11). It only judges
  # labels whose ASSERTION settles the sign, and its own header says so rather than implying a sweep.
  @{ f = 'ops\audit-fixture-vocabulary.ps1'; n = 'no fixture is labelled CLEAN TWIN while asserting that a detector found nothing' }
  # The same one-label-two-meanings defect as the line above, one floor up: the backlog's `OPEN` meant
  # work nobody started, a decision waiting on Brad, AND a measurement whose conclusion was "do not
  # build this". Seventeen items read as a to-do list and five of them were never tasks (2026-09-07).
  # Five states with a precedence now, and this fails a heading that invents a sixth or declares none.
  # -Summary prints the board, so "what is open for me" is a command rather than a reading exercise.
  @{ f = 'ops\audit-backlog-status.ps1'; n = 'every backlog item declares exactly one state from the closed vocabulary' }
  # THREE non-comparable score spaces run here at once - bi-encoder cosine, cross-encoder
  # sigmoid probability, and BM25 - and the two most confusable numbers sit TEN LINES APART in
  # sweep.py: COVERAGE_COS_FLOOR 0.55 and COVERAGE_RERANK_FLOOR 0.90. They read like a loose bar
  # and a strict one and they do not share a scale. A threshold carried between spaces fails by
  # admitting or refusing rows rather than by erroring, so nothing else would ever report it
  # (2026-09-06, backlog E25). Static analysis cannot check that a recorded space is CORRECT;
  # it can check that a new threshold cannot appear without someone writing the space down.
  @{ f = 'ops\audit-threshold-register.ps1'; n = 'no similarity threshold ships without recording which space it was tuned in' }
  # run-log-lib.ps1 opened with 'ONE copy of the write this run down rule' and it was one of
  # THREE: five hidden scheduled tasks, three conventions, and only the TC Grocery ones use the
  # library (2026-09-06, backlog E29). Nothing is unlogged, so the defect is the CLAIM - a file
  # that says it is the single copy of a rule and is not is worse than no claim, because the
  # next person to add a hidden task reads it, sees a library, and cannot learn that two other
  # tasks route around it. Documentation drift, checkable; CONVERGENCE is not, because three of
  # the five registrations live in the Windows registry where no static detector can reach them.
  @{ f = 'ops\audit-run-log-claims.ps1'; n = 'the run-record library describes the logging conventions that actually exist' }
  # THE CHECK EXISTED AND NOTHING RAN IT (2026-09-06, worklist C3). It detects SCOPE DRIFT - the
  # user-scope copy of an agent differing from the project-scope one, so which prompt runs depends on
  # the session's working directory - and it detects a stale backup of the only versioned copy of the
  # prompts. Both fired this session and both were found by hand. audit-twin-drift's own header records
  # the same lesson from the other side: a lockstep assertion caught a real drift correctly and sat red
  # for weeks because nothing ran that suite. Safe on a bare checkout: .claude\agents and
  # .claude\skills are tracked, so `checked` is non-zero, and the hardcoded user-scope paths simply
  # skip when absent.
  @{ f = 'ops\audit-prompt-backup.ps1';        n = 'the only versioned copy of the agent prompts is current, and the scopes agree' }
  # The agent that drains the staging queue BEFORE a publish. Its verdict reader is deliberately
  # asymmetric - anything that is not an explicit GO holds - so this self-test is what stands between an
  # unreadable reviewer reply and a live page (2026-09-06, backlog E1).
  @{ f = 'ops\drain-staged.ps1';               n = 'anything that is not an explicit GO holds the queue' }
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
# DISCOVERED, NOT HAND-LISTED (2026-09-07, backlog I8). Every PowerShell -SelfTest in the tree has
# always been found by walking it; the Python ones were a list somebody had to remember to add to. On
# the day this changed, 32 .py files carried --selftest and SIX were listed: nineteen working suites
# had simply never been wired in, including the band pre-check, the food-provenance reader, the
# ingredient learner and the whole hunt_lib. A suite nobody runs is a suite that rots, and this estate
# has already been bitten by exactly that (coverage_check sat at two failures for weeks).
#
# THE SKIP LIST IS EXPLICIT AND CARRIES ITS REASON, and anything discovered that is NOT skipped MUST
# run. That is what makes this different from the hand-list it replaces: a new suite is in the gate the
# moment it exists, and the only way out is to name it here and say why.
$pySkip = @{
  # numpy/torch live in the sidecar venv, not in the pinned interpreter. Each of these already detects
  # that itself and prints a CANNOT RUN line, so the gate would be re-testing the interpreter rather
  # than the estate.
  'meal-prep\pipeline\harvest_embed.py'     = 'needs numpy - sidecar venv; it says so itself and stops'
  'meal-prep\pipeline\resolution_embed.py'  = 'needs numpy - sidecar venv; it says so itself and stops'
  'sidecar\sweep.py'                        = 'needs torch - sidecar venv'
  # The daemon and its full battery run for minutes, and the gate has to stay fast enough that people
  # run it. Both are exercised in the nightly chain instead.
  'meal-prep\pipeline\hunt-daemon.py'       = 'the daemon itself - runs for minutes; exercised nightly'
  'meal-prep\pipeline\hunt_daemon_selftest.py' = 'the full daemon battery - runs for minutes; exercised nightly'
}
$pySuites = @()
foreach ($f in @(Get-ChildItem -Path $repo -Recurse -Filter '*.py' -File -ErrorAction SilentlyContinue |
                 Where-Object { $_.FullName -notmatch '\\\.venv\\|\\archive\\|\\worktrees\\|\\node_modules\\|\\site-packages\\|\\\.git\\' })) {
  $rel = $f.FullName.Substring($repo.Length).TrimStart('\')
  $txt = ''
  try { $txt = [IO.File]::ReadAllText($f.FullName) } catch { continue }
  if ($txt -notmatch '--selftest') { continue }
  if ($pySkip.ContainsKey($rel)) { continue }
  $pySuites += @{ f = $rel; a = '--selftest'; n = 'discovered Python self-test' }
}
if ($pySuites.Count -lt 15) {
  # DISCOVERY BROKEN IS NOT A CLEAN TREE. Nineteen suites were found the day this shipped; a run that
  # finds almost none has lost the walk, not the suites.
  Write-Output ("  FAIL  python self-test DISCOVERY found only {0} suite(s) - it found 27 on 2026-09-07. That is the walk broken, not the tree clean." -f $pySuites.Count)
  $fail += 'python-selftest-discovery'
}
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
# PYTHON AUDITS WHOSE LIVE PASS BELONGS IN THE GATE (2026-09-07). The discovery pass below gives
# every Python file its --selftest, which proves the logic works and never looks at production - the
# same hole audit-twin-drift's entry above describes from the PowerShell side. These read TRACKED
# inputs, so they are hermetic and belong here rather than in the daily chain.
#
# SEPARATE FROM $static BECAUSE THAT LOOP RUNS `powershell -File`, which cannot execute a .py: putting
# one there exits -196608 with nothing useful said about why (measured, the same day).
$pyStatic = @(
  # Our test sets are built out of successes and their absence is invisible in the score (E23). The
  # dedup set was 31 pairs from 168 ruled duplicates, filtered toward the pipeline's own successes by
  # a mechanism nobody saw until the denominator was printed. This prints it per corpus and ratchets
  # the checkable half: a corpus whose rows do not say where they came from cannot answer the
  # question even in principle. A gitignored corpus that is absent reads as not-read, never repaired.
  @{ f = 'ops\audit_corpus_provenance.py'; n = 'no NEW test corpus loses track of where its cases came from' }
)
foreach ($g in $pyStatic) {
  $p = Join-Path $repo $g.f
  if (-not (Test-Path $p)) { $fail += $g.f; Write-Output ("  FAIL  {0} is missing" -f $g.f); continue }
  if (-not $pyExe) { $fail += $g.f; Write-Output ("  FAIL  {0} - no Python 3 interpreter found, so this audit DID NOT RUN" -f $g.f); continue }
  # NO 2>&1 ON A NATIVE EXE under $ErrorActionPreference='Stop' - it turns a clean exit into a throw.
  $out = & $pyExe $p
  $rc = $LASTEXITCODE
  if ($rc -eq 0) { $pass++; Write-Output ("  ok    {0}  ({1})" -f $g.f, $g.n) }
  else {
    $fail += $g.f
    Write-Output ("  FAIL  {0}  (exit {1}) - {2}" -f $g.f, $rc, $g.n)
    @($out) | Where-Object { $_ -match '!|FAIL|FINDING' } | Select-Object -First 12 | ForEach-Object { Write-Output ('          ' + $_) }
  }
}

foreach ($g in $pySuites) {
  $p = Join-Path $repo $g.f
  if (-not (Test-Path $p)) { $fail += $g.f; Write-Output ("  FAIL  {0} is missing" -f $g.f); continue }
  if (-not $pyExe) {
    $fail += $g.f
    Write-Output ("  FAIL  {0} - no Python 3 interpreter found, so this battery DID NOT RUN" -f $g.f)
    continue
  }
  # NO 2>&1 ON A NATIVE EXE (2026-09-07). This line used to redirect python's stderr into $out,
  # and this script sets $ErrorActionPreference='Stop'. In PS 5.1 that combination is fatal: each
  # stderr line becomes an ErrorRecord and the FIRST one is a TERMINATING throw, so the gate DIED
  # at the first suite that printed a warning instead of reporting it. It survived six curated
  # suites and broke on the twenty-seventh the moment discovery widened the input - the same shape
  # capture-run.ps1 records from 2026-08-22. stderr now goes to the console where a human sees it;
  # the verdict was never in stderr, it is the exit code.
  $out = & $pyExe $p $g.a
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
