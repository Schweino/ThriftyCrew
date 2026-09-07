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
$pySuites = @(
  @{ f = 'meal-prep\pipeline\coverage_check.py'; a = '--selftest'; n = 'the recipe QA battery: coverage, scaling, prose numbers, the mass reader' }
  # graph\agentic WAS COVERED BY NOTHING - not in this list, no -SelfTest, imported by no other suite -
  # and it holds the Executor that shells out on a plan's tool string. os.path.join discards the repo
  # root when the tool name is absolute, so an absolute or traversing name escaped entirely, and the
  # plan-hash check above it proves the plan was not MUTATED, which is a different question
  # (2026-09-06, backlog E11+E18).
  @{ f = 'graph\agentic\executor_selftest.py'; a = '--selftest'; n = 'the executor refuses a tool path that escapes the repo, and records why' }
  # The BM25 probe's ARITHMETIC, not its verdict. A scorer nobody checked, reporting a recall that a
  # build decision rests on, is the shape this estate keeps writing guards about (backlog E4).
  @{ f = 'meal-prep\pipeline\bm25_dedup_probe.py'; a = '--selftest'; n = 'the E4 lexical probe still scores rare terms above common ones' }
  # finetune_reranker.py scored holdout AUC every epoch and then saved whichever epoch ran
  # LAST, so the scores decided nothing and an overfit final epoch shipped over a better one
  # (2026-09-06, backlog E27). The rule that fixes it is split into its own module for one
  # reason: the trainer imports torch at module scope and runs on the sidecar venv, which the
  # interpreter above does not have, so a decision rule left inside it could never run HERE.
  # Its clean twin is the load-bearing case - a plain 'keep the best epoch' would select the
  # maximum of k noisy draws, and this file's own docstring measures that noise at 0.0033.
  @{ f = 'sidecar\checkpoint_selection.py'; a = '--selftest'; n = 'the trainer ships a mid-run peak but refuses to chase a lead inside measured seed noise' }
  # The E9 probe's COMPARATOR, not its verdict. Its whole job is to notice that one
  # transcription differs from another, so a comparator that has quietly gone lenient reports
  # agreement and retires a question that was never asked. Its must-fire is the unit rewrite
  # ('ounces' to 'oz') the extractor is forbidden to make.
  @{ f = 'meal-prep\pipeline\extractor_model_probe.py'; a = '--selftest'; n = 'the E9 transcription comparator still calls a rewritten unit a difference' }
  # ONLY THE SELF-TEST, never the live run. matcher_eval's real pass needs torch and the model,
  # which is not hermetic, and it currently exits 2 on a real finding - 186 of 2,816 known-
  # correct pairs score under sweep.py's prefilter floor (2026-09-06, backlog E19). Its
  # arithmetic is what belongs in the gate: the must-fire is that an ABSTENTION lowers MRR
  # rather than vanishing from it, which is the trick that makes a matcher which gives up on
  # its hard rows outscore one that attempts everything.
  @{ f = 'sidecar\matcher_eval.py'; a = '--selftest'; n = 'the matcher scorer still counts an abstention against itself, and reads the live floor' }
  # backtest.py called itself an ACCEPTANCE GATE, said in its own header that it was allowed to
  # fail, and contained no sys.exit at all - so every run exited 0 whatever it measured
  # (2026-09-07, backlog I17). The bar it now enforces is the one it always stated: a candidate
  # ships only if it still catches what stock catches. The rule is split out so it can run HERE,
  # on the pinned interpreter, without torch. Its must-fire is a candidate that wins at every
  # other budget and loses ONE known-wrong pair at one of them.
  @{ f = 'sidecar\backtest_veto.py'; a = '--selftest'; n = 'the candidate veto still refuses a comparison it cannot make, and fires on a lost defect' }
  # sweep.py's coverage prefilter was CHOSEN - 0.55, from eight observations in a 0.58-0.69 band -
  # and a product under it is never reranked, so the cross-encoder that actually discriminates
  # never sees it. Measured against 2,816 confirmed-correct pairs, true positives sit as low as
  # 0.3948 (2026-09-07, backlog I13/I14 and the E19 floor finding). The must-fire is that a floor
  # derived from a narrow sample sits ABOVE a real pair outside it - which is what happened.
  @{ f = 'sidecar\derive_coverage_floor.py'; a = '--selftest'; n = 'the coverage floor is read off the lowest confirmed pair, and its volume cap says when it bound' }
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
