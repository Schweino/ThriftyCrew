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
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop (2026-09-07)
param([switch]$ListOnly, [int]$Jobs = 0)
$ErrorActionPreference = 'Stop'
# NO REPOSITORY ENVIRONMENT IS INHERITED (2026-09-10). Called from a git hook in a LINKED worktree, this
# process arrives with GIT_DIR pointing at that worktree's gitdir, and every hermetic git self-test below
# inherits it: their temp-repo `git init` and `git config` then write the SHARED repository. On the first
# push from a detached gate-check checkout that set core.bare=true and a test identity in the common
# .git\config, and `git status` failed in every checkout on the box until it was repaired by hand.
# ops\hooks\pre-push unsets these too; this covers every other caller, since a shell or a task spawned
# from inside a hook inherits them the same way. This file finds the repo from its own path and needs none
# of them. Fixtured in ops\test-prepush-hook.ps1.
foreach ($v in @('GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_COMMON_DIR', 'GIT_OBJECT_DIRECTORY',
                 'GIT_ALTERNATE_OBJECT_DIRECTORIES', 'GIT_PREFIX', 'GIT_NAMESPACE')) {
  Remove-Item -LiteralPath ("Env:\" + $v) -ErrorAction SilentlyContinue
}
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\ops' }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\ps-source.ps1')   # Get-PsCodeOnly - no param() block, so it cannot reset ours

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
  # 2026-09-07: BLOCK comments too. The 2026-09-01 fix above stripped only LINE comments, so a
  # `<# ... #>` header explaining why a file has NO self-test enrolled it AS one - the same defect
  # this rule exists to prevent, one comment syntax over, and it means run-gates could report green
  # coverage for a self-test that does not exist. Nine other places in the estate reduce source the
  # same way, so the reduction lives in lib\ps-source.ps1 rather than here.
  $code = Get-PsCodeOnly -Text $t
  if ($code -match '\[switch\]\$SelfTest' -or $code -match '\$__\w*SelfTest\s*=') { $withSelfTest += $s }
}

if ($ListOnly) {
  Write-Output ("self-tests discovered: {0}" -f $withSelfTest.Count)
  $withSelfTest | ForEach-Object { Write-Output ('  ' + $_.FullName.Replace($repo, '')) }
  exit 0
}

if (-not $withSelfTest.Count) {
  Write-Output 'run-gates: COULD NOT EVALUATE - discovered zero self-tests, which means this discovery is broken, not that the tree is clean'
  Exit-Guard -Name 'run-gates' -Summary 'blind=no-selftests' -Code 3
}
# A FLOOR, NOT JUST A ZERO CHECK (2026-09-07). The test above only catches discovery collapsing to
# nothing; a walk that lost most of the tree - a moved directory, a broken exclusion, a regex that
# stopped matching - would find twelve, run twelve, and print a confident green. The Python half of
# this file has carried exactly this floor since it shipped; the PowerShell half did not. 201 were
# discovered on 2026-09-07 after the block-comment fix below removed 8 libraries that had been
# enrolled by their own headers, so 150 is a wide margin that still notices a collapse.
if ($withSelfTest.Count -lt 150) {
  Write-Output ("run-gates: COULD NOT EVALUATE - PowerShell self-test DISCOVERY found only {0} suite(s); it found 201 on 2026-09-07. That is the walk broken, not the tree clean." -f $withSelfTest.Count)
  Exit-Guard -Name 'run-gates' -Summary ("blind=selftest-discovery-collapsed n=" + $withSelfTest.Count) -Code 3
}

$pass = 0; # WHERE THE WALL CLOCK GOES (2026-09-07). Every gate below is a fresh process - `powershell -File`
# for the PowerShell lanes, the interpreter for the Python ones - run serially. On this machine a bare
# PS 5.1 spawn is ~209ms and a Python spawn ~68ms, so the spawn floor alone is tens of seconds before
# any gate code runs. The summary prints the slowest gates and that floor, because "too slow" is not
# actionable and "this gate costs 14s of a 190s run, and 52s of the run is process startup" is.
$runSw = [Diagnostics.Stopwatch]::StartNew()
$timings = [Collections.Generic.List[object]]::new()
function Add-TcGateTiming { param([string]$Name, [double]$Ms, [int]$SpawnMs) $script:timings.Add([pscustomobject]@{ Name = $Name; Ms = $Ms; SpawnMs = $SpawnMs }) }
# HOW WIDE (2026-09-07). 269 gates run serially cost 490s on a 32-processor machine that was idle
# throughout. The gates are independent by construction - each is its own process with its own exit
# code - so the serial loop was the entire cost and none of the safety. -Jobs 1 restores the old
# behaviour exactly, and the library's own fixtures assert that concurrency 1 and the pool agree.
if (-not $Jobs -or $Jobs -lt 1) { $Jobs = [Math]::Max(1, [Math]::Min(16, [Environment]::ProcessorCount - 2)) }
. (Join-Path $repo 'lib\parallel-run.ps1')   # Invoke-TcParallel - no param() block, so it cannot reset ours
$PSEXE = (Get-Command powershell).Source
$fail = @()
Write-Output ("run-gates: {0} self-test(s) discovered" -f $withSelfTest.Count)
# ---- the pool runs them; the loop below judges them, unchanged ----
$selfJobs = [Collections.Generic.List[object]]::new(); $selfKeys = [Collections.Generic.List[string]]::new()
foreach ($s in $withSelfTest) {
  [void]$selfKeys.Add([string]$s.FullName)
  [void]$selfJobs.Add([pscustomobject]@{ Exe = $PSEXE; ArgList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $s.FullName, '-SelfTest') })
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
  # A SCHEDULED TASK'S NAME IS A FOREIGN KEY IN TWO HAND-MAINTAINED TABLES (2026-09-07, queue
  # 2026-09-07-dc7460): the $OWNED list in ops\install-grocery-tasks.ps1 and windows_tasks in
  # grocery\expected-automations.json, which health-heartbeat reads. Nothing compared them at the moment
  # either one changed, so a rename applied to the scheduler and the registrar at 06:30 passed every gate,
  # and at 10:30 the heartbeat paged it as a phantom task plus an unwatched one. Hermetic (source only,
  # no Get-ScheduledTask), which is why it is a wrapper rather than install-grocery-tasks itself: that
  # file's default mode reads the live scheduler and this list passes no arguments.
  @{ f = 'ops\audit-task-registry.ps1';        n = 'every task the registrar registers is watched under the same name, and no legacy name survives in the registry' }
  # THE OTHER END OF THAT SAME JOIN (2026-09-09, queue 2026-09-09-d3e937). The entry above asks whether
  # the tables AGREE; this asks whether a REGISTRAR can create a task that is in neither, which is the
  # state TC Graph Nightly Matching was in for three mornings from 2026-08-22 and TC Recipe Harvest
  # Crawl from 08-24. Both were noticed only by health-heartbeat's TASK UNWATCHED line the following
  # morning - an alarm whose only follower is a human typing an entry. Widening the entry above was not
  # enough on its own: it reads the committed tables, so a registrar that never got a definition
  # committed is still invisible to it.
  # LISTED HERE RATHER THAN LEFT TO DISCOVERY, for the reason audit-write-only-reports records: the
  # discovery pass runs the FIXTURE and this entry runs the DETECTOR over the real tree, and only the
  # second one can see a registrar somebody adds tomorrow. Hermetic - it reads .ps1 source, the
  # committed task XML and expected-automations.json, all tracked, so it is green on a bare checkout.
  @{ f = 'ops\audit-task-registration.ps1';    n = 'no registrar can register a scheduled task that has no committed definition and no watch entry - a task must be impossible to leave unwatched at CHANGE time, not reported unwatched the next morning' }
  @{ f = 'ops\audit-arg-binding.ps1';          n = 'every audit/verify/test/check script REFUSES an argument it does not declare, so a scoped check cannot silently run unscoped and report clean' }
  # Hermetic: reads .ps1 source text, never a board, so it belongs here rather than in the daily chain.
  @{ f = 'ops\audit-cross-module-reach.ps1';   n = 'no NEW script reaches into another module''s internals directory - a ratchet on cross-module path literals, high-water mark may only go DOWN' }
  @{ f = 'ops\audit-lift-completeness.ps1';    n = 'every function lifted out of compare-deals.ps1 brings the engine functions it CALLS with it, so a hand-maintained lift list cannot fall behind and fail at run time' }
  @{ f = 'ops\audit-one-way-actuators.ps1';    n = 'a control constant that may only move ONE WAY carries a rate limit and a plausibility bar - a REPORT, exit 0, because "one-directional" is a property of a design and no pattern matcher can be precise about it' }
  @{ f = 'ops\audit-event-bus.ps1';            n = 'every declared producer of an estate event still writes one, and the bus is not silently dead - the wiring half is static, and the FLOOR half is one of the estate''s only checks that fires on nothing happening' }
  @{ f = 'ops\audit-phantom-paths.ps1';        n = 'a script path named in standing guidance (CLAUDE.md, rules, agents, docs, hooks, rulings) exists in the tree - the founding phantom was ops\audit-hook-installed.ps1, cited five times as a running guard and never written' }
  @{ f = 'ops\audit-conclusion-currency.ps1'; n = 'a recorded conclusion that was current does not name a harness changed after it (WS 7d ratchet)' }
  @{ f = 'ops\audit-rule-currency.ps1';        n = 'every .claude\rules globs entry matches a tracked file; stale dated claims are reported (WS 7e)' }
  @{ f = 'ops\audit-measurement-provenance.ps1'; n = 'a recorded measurement names the harness it ran through and the commit or date it ran at - a RATCHET at 8, because retro-filling the existing set was explicitly not asked for and a bar over them would be red on day one' }
  @{ f = 'ops\audit-source-comment-strip.ps1'; n = 'no source scanner reduces PowerShell by LINE comments only - a block header must not be readable as a declaration (it enrolled 8 libraries here as self-tests)' }
  # ops\verify-commodities-gate.ps1 is deliberately NOT listed here. A $static entry passes no
  # arguments, which would run its LIVE check against a staged set that is empty during a gate run -
  # a confident "not applicable" that proves nothing. It declares [switch]$SelfTest, so the discovery
  # pass above already runs its fixtures, which is the half that can rot.
)
# Same guard the loop applies, so nothing is spawned for a file the loop will skip.
$staticJobs = [Collections.Generic.List[object]]::new(); $staticKeys = [Collections.Generic.List[string]]::new()
foreach ($g in $static) {
  $pp = Join-Path $repo $g.f
  if (-not (Test-Path $pp)) { continue }
  [void]$staticKeys.Add([string]$g.f)
  [void]$staticJobs.Add([pscustomobject]@{ Exe = $PSEXE; ArgList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $pp) })
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
$pyStaticJobs = [Collections.Generic.List[object]]::new(); $pyStaticKeys = [Collections.Generic.List[string]]::new()
foreach ($g in $pyStatic) {
  $pp = Join-Path $repo $g.f
  if (-not (Test-Path $pp) -or -not $pyExe) { continue }
  [void]$pyStaticKeys.Add([string]$g.f)
  [void]$pyStaticJobs.Add([pscustomobject]@{ Exe = $pyExe; ArgList = @($pp) })
}
# KEYED ON FILE PLUS ARGUMENT: a battery can appear twice in $pySuites with different arguments, and a
# bare filename key would collapse both onto one result and score one of them against the other's output.
$pySuiteJobs = [Collections.Generic.List[object]]::new(); $pySuiteKeys = [Collections.Generic.List[string]]::new()
foreach ($g in $pySuites) {
  $pp = Join-Path $repo $g.f
  if (-not (Test-Path $pp) -or -not $pyExe) { continue }
  [void]$pySuiteKeys.Add([string]$g.f + '|' + [string]$g.a)
  [void]$pySuiteJobs.Add([pscustomobject]@{ Exe = $pyExe; ArgList = @($pp, [string]$g.a) })
}
# ---- ONE POOL, NOT FOUR (2026-09-09). ----------------------------------------------------------
# This was four Invoke-TcParallel calls - self-tests, PS static, Python static, Python suites - and
# each one returns an array indexed by job, so each had to DRAIN FULLY before the next began. Three
# hard barriers, and at the end of every batch the workers that had finished sat idle waiting on that
# batch's longest straggler. MEASURED at the four-pool shape: 516s of gate work inside 78s of wall is
# 6.6x effective parallelism against 16 dispatched workers, about 41%, where perfect packing of 516s
# at width 16 is 32s. The width curve was flat - 78s, 76s, 75s at width 16, 24, 32 - and that was
# read as the pool saturating. It was not saturated, it was waiting: widening a barrier does not
# remove it, because each batch's tail is set by its longest single gate however many workers idle
# behind it. `design\MEASURE-gate-cost-2026-09-09.md` is the measurement and its correction.
#
# WHAT THIS DOES NOT CHANGE: every gate still runs, still in its own process, still judged by the same
# four loops below in the same order, and their lines are byte identical. This is the DISPATCH, not
# the assertions - which is exactly why it is safe where running only the gates a change can affect
# would not be, that being the "no gate matched" / "the gates found nothing" shape ops-and-gates.md
# warns about.
#
# SAFE BECAUSE THE GATES DO NOT WRITE, and that was measured rather than assumed: two full runs over
# 108,129 files changed ZERO repo files, against a zero background-churn floor in the same window. So
# there is no file-system channel by which a later batch could have depended on an earlier one.
#
# ONE BEHAVIOUR CHANGE, deliberately: the `$pySuites.Count -lt 15` and interpreter-probe guards now
# run BEFORE any gate verdict prints rather than after the self-test block, so a could-not-evaluate
# aborts with no results above it instead of some. That is fail-fast and it is the honest shape, but
# it IS different from what a reader of the old log would expect.
$allJobs = [Collections.Generic.List[object]]::new()
$offSelf = $allJobs.Count;     foreach ($j in $selfJobs)     { [void]$allJobs.Add($j) }
$offStatic = $allJobs.Count;   foreach ($j in $staticJobs)   { [void]$allJobs.Add($j) }
$offPyStatic = $allJobs.Count; foreach ($j in $pyStaticJobs) { [void]$allJobs.Add($j) }
$offPySuite = $allJobs.Count;  foreach ($j in $pySuiteJobs)  { [void]$allJobs.Add($j) }
Write-Output ("run-gates: {0} gate(s) dispatched into ONE pool at width {1}" -f $allJobs.Count, $Jobs)
$allRes = Invoke-TcParallel -Jobs $allJobs.ToArray() -Concurrency $Jobs -WorkingDirectory $repo
# EXPLICIT INDEX COPIES, never `@(Get-Slice ...)` or a range expression. A function returning an array
# UNROLLS, so a one-element slice - $pyStatic is exactly one job - would come back a SCALAR and index
# into the object instead of the array, and an empty slice would need $a[0..-1] which is not empty.
# This estate has a memory for the family: assign, then wrap. These loops cannot do either.
$selfRes = New-Object object[] $selfJobs.Count
for ($i = 0; $i -lt $selfJobs.Count; $i++) { $selfRes[$i] = $allRes[$offSelf + $i] }
$staticRes = New-Object object[] $staticJobs.Count
for ($i = 0; $i -lt $staticJobs.Count; $i++) { $staticRes[$i] = $allRes[$offStatic + $i] }
$pyStaticRes = New-Object object[] $pyStaticJobs.Count
for ($i = 0; $i -lt $pyStaticJobs.Count; $i++) { $pyStaticRes[$i] = $allRes[$offPyStatic + $i] }
$pySuiteRes = New-Object object[] $pySuiteJobs.Count
for ($i = 0; $i -lt $pySuiteJobs.Count; $i++) { $pySuiteRes[$i] = $allRes[$offPySuite + $i] }
if ($allRes.Count -ne $allJobs.Count) {
  Write-Output ("run-gates: COULD NOT EVALUATE - dispatched {0} job(s) and the pool returned {1}. Refusing to judge a set that does not line up with what was run." -f $allJobs.Count, $allRes.Count)
  exit 3
}

$selfBy = @{}; for ($i = 0; $i -lt $selfKeys.Count; $i++) { $selfBy[$selfKeys[$i]] = $selfRes[$i] }
foreach ($s in $withSelfTest) {
  $rel = $s.FullName.Replace($repo, '').TrimStart('\')
  # NO 2>&1: merging a child's stderr under EAP=Stop makes its first stderr line a terminating throw in THIS
  # script. That trap has bitten test-auditors, guards and check-ad-cycles in this estate already.
  $gr = $selfBy[[string]$s.FullName]
  $out = $gr.Out
  Add-TcGateTiming -Name ($s.FullName.Replace($repo, '')) -Ms $gr.Ms -SpawnMs 209
  $rc = $gr.ExitCode
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

$staticBy = @{}; for ($i = 0; $i -lt $staticKeys.Count; $i++) { $staticBy[$staticKeys[$i]] = $staticRes[$i] }
# WS 10e (2026-09-10): each static detector's COMPLETE line, kept per run in ops\out\gate-readings.jsonl
# (gitignored). lib\ratchet.ps1 only wrote history when a mark TIGHTENED, so a detector returning the same
# number for six weeks - the case its own header names - left no trace. ops\report-ratchet-trends.ps1 reads it.
$gateReadings = [Collections.Generic.List[object]]::new()
foreach ($g in $static) {
  $p = Join-Path $repo $g.f
  if (-not (Test-Path $p)) { $fail += $g.f; Write-Output ("  FAIL  {0} is missing" -f $g.f); continue }
  $gr = $staticBy[[string]$g.f]
  $out = $gr.Out
  Add-TcGateTiming -Name ($g.f) -Ms $gr.Ms -SpawnMs 209
  $rc = $gr.ExitCode
  $gMarks = @(@($out) | Where-Object { "$_" -match '^[A-Z0-9][A-Z0-9-]*-COMPLETE\b' })
  if ($gMarks.Count) { [void]$gateReadings.Add([pscustomobject]@{ gate = [string]$g.f; rc = $rc; marker = [string]$gMarks[$gMarks.Count - 1] }) }
  if ($rc -eq 0) { $pass++; Write-Output ("  ok    {0}  ({1})" -f $g.f, $g.n) }
  else {
    $fail += $g.f
    Write-Output ("  FAIL  {0}  (exit {1}) - {2}" -f $g.f, $rc, $g.n)
    @($out) | Where-Object { $_ -match '!|FAIL' } | Select-Object -First 12 | ForEach-Object { Write-Output ('          ' + $_) }
  }
}

try {
  if ($gateReadings.Count) {
    $grF = Join-Path $repo 'ops\out\gate-readings.jsonl'
    $grDir = Split-Path $grF -Parent
    if (-not (Test-Path $grDir)) { $null = New-Item -ItemType Directory -Force $grDir }
    $grNow = [DateTimeOffset]::UtcNow
    $grLines = foreach ($x in $gateReadings) {
      ([ordered]@{ t = $grNow.ToUnixTimeSeconds(); date = $grNow.ToString('yyyy-MM-dd'); gate = $x.gate; rc = $x.rc; marker = $x.marker } | ConvertTo-Json -Compress)
    }
    [IO.File]::AppendAllText($grF, ((@($grLines) -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
  }
} catch { }   # a reading that cannot be kept must never fail the gate

$pyStaticBy = @{}; for ($i = 0; $i -lt $pyStaticKeys.Count; $i++) { $pyStaticBy[$pyStaticKeys[$i]] = $pyStaticRes[$i] }
foreach ($g in $pyStatic) {
  $p = Join-Path $repo $g.f
  if (-not (Test-Path $p)) { $fail += $g.f; Write-Output ("  FAIL  {0} is missing" -f $g.f); continue }
  if (-not $pyExe) { $fail += $g.f; Write-Output ("  FAIL  {0} - no Python 3 interpreter found, so this audit DID NOT RUN" -f $g.f); continue }
  # NO 2>&1 ON A NATIVE EXE under $ErrorActionPreference='Stop' - it turns a clean exit into a throw.
  $gr = $pyStaticBy[[string]$g.f]
  $out = $gr.Out
  Add-TcGateTiming -Name ($g.f) -Ms $gr.Ms -SpawnMs 68
  $rc = $gr.ExitCode
  if ($rc -eq 0) { $pass++; Write-Output ("  ok    {0}  ({1})" -f $g.f, $g.n) }
  else {
    $fail += $g.f
    Write-Output ("  FAIL  {0}  (exit {1}) - {2}" -f $g.f, $rc, $g.n)
    @($out) | Where-Object { $_ -match '!|FAIL|FINDING' } | Select-Object -First 12 | ForEach-Object { Write-Output ('          ' + $_) }
  }
}

$pySuiteBy = @{}; for ($i = 0; $i -lt $pySuiteKeys.Count; $i++) { $pySuiteBy[$pySuiteKeys[$i]] = $pySuiteRes[$i] }
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
  $gr = $pySuiteBy[([string]$g.f + '|' + [string]$g.a)]
  $out = $gr.Out
  Add-TcGateTiming -Name (($g.f + ' ' + [string]$g.a)) -Ms $gr.Ms -SpawnMs 68
  $rc = $gr.ExitCode
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
# The profile, printed BEFORE the COMPLETE marker: the guard contract says that marker is the LAST
# line on stdout, and anything after it breaks every reader that trusts the contract.
if ($timings.Count) {
  $totalMs = ($timings | Measure-Object -Property Ms -Sum).Sum
  $floorMs = ($timings | Measure-Object -Property SpawnMs -Sum).Sum
  Write-Output ''
  # WALL AND WORK ARE DIFFERENT NUMBERS UNDER A POOL, and reporting the sum as the run time overstates
  # it by the width: the first parallel run summed 569.9s of gate work into 131s of wall clock.
  $wallS = $runSw.Elapsed.TotalSeconds
  Write-Output ("timing: {0} gate(s), {1:N0}s wall at width {2}. {3:N0}s of gate work inside it, of which about {4:N0}s is process startup - every gate is still its own process." -f $timings.Count, $wallS, $Jobs, ($totalMs / 1000), ($floorMs / 1000))
  if ($Jobs -gt 1) { Write-Output ("timing: serial would have been about {0:N0}s, so the pool is saving roughly {1:N0}s a run." -f ($totalMs / 1000), [Math]::Max(0, ($totalMs / 1000) - $wallS)) }
  Write-Output 'timing: slowest 15 -'
  foreach ($r in ($timings | Sort-Object Ms -Descending | Select-Object -First 15)) {
    Write-Output ("   {0,7:N0}ms  {1}" -f $r.Ms, $r.Name)
  }
}
# A RED GATE LEAVES A RECORD (WS 1b). Until 2026-09-09 a failure here printed to a terminal
# and to a temp file the pre-push hook wrote, and that was the whole of it: no queue entry, no
# alert, no history. So "which gate fails most", "did this failure ever produce a fixture" and
# "has this gate been red twice in a fortnight" were all unanswerable, while CLAUDE.md states
# as a habit that a recurring defect earns a memory, a gate or a command. A habit with no
# record cannot be audited. `ops\audit-gate-followthrough.ps1` reads these rows.
#
# IT WRITES ONLY ON RED, and it cannot fail the run: Write-TcEvent swallows everything. A bus
# that could take down the gate would cost more than every signal it carries.
if ($fail.Count) {
  . (Join-Path $repo 'lib\event-bus.ps1')
  # NO `Select-Object -First` ON A NATIVE EXE. It stops the upstream pipeline, which sends
  # the child a broken pipe mid-write; harmless for a one-line rev-parse and a bad habit to
  # spread into a gate. The output is captured and indexed instead.
  $head = @(@($fail | ForEach-Object { "$_" })[0..([Math]::Min(11, $fail.Count - 1))])
  $commit = ''
  try { $c = @(& git -C $repo rev-parse --short HEAD 2>$null); if ($c.Count) { $commit = "$($c[0])" } } catch { }
  $branch = ''
  try { $b = @(& git -C $repo rev-parse --abbrev-ref HEAD 2>$null); if ($b.Count) { $branch = "$($b[0])" } } catch { }
  $null = Write-TcEvent -Kind 'gate-red' -Producer 'ops\run-gates.ps1' -Data @{
    failed  = $fail.Count
    passed  = $pass
    gates   = $head
    commit  = "$commit"
    branch  = "$branch"
  }
}
Exit-Guard -Name 'run-gates' -Summary ("pass={0} fail={1}" -f $pass, $fail.Count) -Code $(if ($fail.Count) { 1 } else { 0 })
