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

    1. every -SelfTest in the tree, and every self-test a dot-sourced lib gates on a renamed switch instead
       (lib\selftest-discovery.ps1 is the rule). That is the real payload. Each one drives frozen must-fire fixtures of a
       founding bug plus its clean twin, needs no data, no network and no secrets, and fails loudly when a
       fix stops being able to detect the thing it was written for.
    2. the static-analysis detectors that read SOURCE rather than data (guard contract, cloud readiness,
       script census) - the ones that catch a guard going dead, losing its completion marker, or becoming
       unreachable.

  The data-dependent audits stay where they are, in the daily chain against a real board. This gate answers
  "did this change break the machinery?", not "is today's board correct".

  Exit 0 = every gate passed. 1 = at least one failed. 3 = could not evaluate (found no self-tests at all,
  which would mean the discovery is broken rather than the tree being clean, or a self-test exited 0 without
  its own verdict as its last words - lib\selftest-verdict.ps1 is that rule, since 2026-09-11).
#>
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop (2026-09-07)
param([switch]$ListOnly, [int]$Jobs = 0, [switch]$NoReuse, [string]$PushRefsFile = '', [string]$PushRemote = '')
$ErrorActionPreference = 'Stop'
# NO REPOSITORY ENVIRONMENT IS INHERITED (2026-09-10). Called from a git hook in a LINKED worktree, this
# process arrives with GIT_DIR pointing at that worktree's gitdir, and every hermetic git self-test below
# inherits it: their temp-repo `git init` and `git config` then write the SHARED repository. On the first
# push from a detached gate-check checkout that set core.bare=true and a test identity in the common
# .git\config, and `git status` failed in every checkout on the box until it was repaired by hand.
# ops\hooks\pre-push unsets these too; this covers every other caller, since a shell or a task spawned
# from inside a hook inherits them the same way. This file finds the repo from its own path and needs none
# of them. Fixtured in ops\test-prepush-hook.ps1. The list lives in lib\git-repo-env.ps1 since 2026-09-11, the
# one copy that every script building a temp repo also calls. Nothing above this line runs git.
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\ops' }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\git-repo-env.ps1')
Clear-TcGitRepoEnv
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\selftest-discovery.ps1')   # Get-TcSelfTestSwitch - no param() block, so it cannot reset ours
. (Join-Path $repo 'lib\tree-walk.ps1')   # Get-TcPathBelowRoot - discovery excludes below the root, so a worktree root is scanned
. (Join-Path $repo 'lib\selftest-verdict.ps1')   # Get-TcSelfTestScore - no param() block, so it cannot reset ours

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

$repoFull = Get-TcRootFull $repo
$scripts = @(Get-ChildItem $repoFull -Recurse -File -Filter *.ps1 -ErrorAction SilentlyContinue |
  # \out\ is the pipeline's OUTPUT directory. Scripts that land there are one-offs and debris (the script
  # census counts 37 of them); running their self-tests would gate every push on abandoned scratch work.
  # MATCHED BELOW THE REPO ROOT, NOT ON THE FULL PATH (2026-09-10). A linked worktree lives under
  # .claude\worktrees\, so the full-path form excluded every file in it: discovery found zero and exited 3
  # from every spawned session, which pre-push then BLOCKS. Recorded 2026-08-26 and left standing until
  # ops\count-source-lifters.ps1 was found blind the same way. Sibling worktrees below the root stay excluded.
  # The rule lives in lib\tree-walk.ps1 since 2026-09-11, shared with every other walk that had the same bug.
  Where-Object { (Get-TcPathBelowRoot $_.FullName $repoFull) -notmatch '\\worktrees\\|\\archive\\|node_modules|\.venv|\\out\\' } |
  Sort-Object FullName)

$withSelfTest = @()
# THE SWITCH EACH ONE RUNS WITH, keyed by full path (2026-09-11). Three grocery libs gate their self-test on a
# RENAMED switch, because a dot-sourced param() block resets the caller's own switch under PS 5.1, and until this
# date nothing here matched them, so their self-tests ran nowhere. They run with their own switch now; the rename
# stays. $declinedSwitch names a renamed declaration the rule would not run, with the reason.
$selfSwitch = @{}
$declinedSwitch = @()
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
  # 2026-09-11: the whole rule moved to lib\selftest-discovery.ps1 - the two matches above unchanged, plus the renamed
  # switch - because this file has no self-test of its own, so neither comment rule had a fixture until then.
  $found = Get-TcSelfTestSwitch -Text $t
  if ($found.Switch) { $withSelfTest += $s; $selfSwitch[[string]$s.FullName] = $found.Switch }
  elseif ($found.Declined) { $declinedSwitch += ('{0}: {1}' -f $s.FullName.Replace($repo, '').TrimStart('\'), $found.Declined) }
}
# What resolved to a renamed switch, as printable 'path -Switch' lines. A pipeline, not a wrapped function call.
$renamedSelf = @($withSelfTest | Where-Object { -not [string]::Equals([string]$selfSwitch[[string]$_.FullName], 'SelfTest', [StringComparison]::Ordinal) } |
  ForEach-Object { $_.FullName.Replace($repo, '').TrimStart('\') + ' -' + $selfSwitch[[string]$_.FullName] })

if ($ListOnly) {
  Write-Output ("self-tests discovered: {0}" -f $withSelfTest.Count)
  foreach ($w in $withSelfTest) {
    $sw = [string]$selfSwitch[[string]$w.FullName]
    if ([string]::Equals($sw, 'SelfTest', [StringComparison]::Ordinal)) { Write-Output ('  ' + $w.FullName.Replace($repo, '')) }
    else { Write-Output ('  ' + $w.FullName.Replace($repo, '') + '  (runs with -' + $sw + ')') }
  }
  Write-Output ("  of which {0} run with a renamed switch" -f $renamedSelf.Count)
  foreach ($d in $declinedSwitch) { Write-Output ('  NOT ENROLLED  ' + $d) }
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
# 2026-09-11: 262 at 8253ded82 plus this change, 258 before it. Three of the four added are libs gating on a
# renamed switch, and they count toward this floor because they run; the fourth is lib\selftest-discovery.ps1.
if ($withSelfTest.Count -lt 150) {
  Write-Output ("run-gates: COULD NOT EVALUATE - PowerShell self-test DISCOVERY found only {0} suite(s); it found 201 on 2026-09-07 and 262 on 2026-09-11. That is the walk broken, not the tree clean." -f $withSelfTest.Count)
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
# WIDTH IS A SHARE OF A MACHINE-WIDE BUDGET, NOT A CLAIM ON THE MACHINE (2026-09-11, Brad: "fixed at 10
# total"). This line was min(16, processors - 2) and every run took it as if it were alone; seven live at
# once put 112 gate workers on 32 processors and each run took about 390s, against 372s serial. -Jobs is now
# what a run ASKS for: lib\gate-slots.ps1 grants at most the free share of $TcGateSlotTotal slots, held
# across every run-gates on the box, and the pool below runs at what was granted.
. (Join-Path $repo 'lib\gate-slots.ps1')     # Enter-TcGateSlots - no param() block, so it cannot reset ours
if (-not $Jobs -or $Jobs -lt 1) { $Jobs = [Math]::Max(1, [Math]::Min($script:TcGateSlotTotal, [Environment]::ProcessorCount - 2)) }
. (Join-Path $repo 'lib\parallel-run.ps1')   # Invoke-TcParallel - no param() block, so it cannot reset ours
$PSEXE = (Get-Command powershell).Source
$fail = @()
$noVerdict = @()   # self-tests that exited 0 without their own verdict line - scored 3, never ok (lib\selftest-verdict.ps1)
$blindGates = @()
Write-Output ("run-gates: {0} self-test(s) discovered" -f $withSelfTest.Count)
# A DISCOVERED SET PRINTS WHAT IT RESOLVED (2026-09-11). The renamed-switch suites are named with the switch each
# runs with, so a rule that stopped matching them reads as a count of 0 here rather than as nothing at all, and a
# renamed declaration the rule declined is named with its reason. The rule itself is fixtured in its lib.
Write-Output ("run-gates: {0} of them gate on a RENAMED switch and run with it, not -SelfTest: {1}" -f $renamedSelf.Count, $(if ($renamedSelf.Count) { $renamedSelf -join ', ' } else { 'none' }))
foreach ($d in $declinedSwitch) { Write-Output ('run-gates: NOT ENROLLED - ' + $d) }
# ---- the pool runs them; the loop below judges them, unchanged ----
$selfJobs = [Collections.Generic.List[object]]::new(); $selfKeys = [Collections.Generic.List[string]]::new()
foreach ($s in $withSelfTest) {
  [void]$selfKeys.Add([string]$s.FullName)
  [void]$selfJobs.Add([pscustomobject]@{ Exe = $PSEXE; ArgList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $s.FullName, ('-' + $selfSwitch[[string]$s.FullName])) })
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
  # 2026-09-11: on 2026-09-10 seven self-tests that build temp repos ran under a linked worktree's GIT_DIR and wrote
  # the SHARED .git\config. This hook and this file clear it now; the fixtures are the layer present on every other path.
  @{ f = 'ops\audit-git-fixture-env.ps1';      n = 'every script that builds a temp repo clears the repository environment first, so a hook-spawned run cannot write the shared .git' }
  # 2026-09-11: sessions' own load tests held the shared box at 100% for over an hour. Deliberate load now comes
  # from ops\cpu-load.ps1, which draws on the same machine-wide budget as this file's pool.
  @{ f = 'ops\audit-cpu-load.ps1';             n = 'every committed script that starts CPU burners takes its cores from the machine-wide budget run-gates shares' }
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
  @{ f = 'ops\audit-lift-completeness.ps1';    n = 'every function a grocery script lifts out of another script''s source brings the functions it CALLS with it, so a hand-maintained lift list cannot fall behind and fail at run time' }
  @{ f = 'ops\audit-one-way-actuators.ps1';    n = 'a control constant that may only move ONE WAY carries a rate limit and a plausibility bar - a REPORT, exit 0, because "one-directional" is a property of a design and no pattern matcher can be precise about it' }
  @{ f = 'ops\audit-event-bus.ps1';            n = 'every declared producer of an estate event still writes one, and the bus is not silently dead - the wiring half is static, and the FLOOR half is one of the estate''s only checks that fires on nothing happening' }
  @{ f = 'ops\audit-phantom-paths.ps1';        n = 'a script path named in standing guidance (CLAUDE.md, rules, agents, docs, hooks, rulings) exists in the tree - the founding phantom was ops\audit-hook-installed.ps1, cited five times as a running guard and never written' }
  @{ f = 'ops\audit-conclusion-currency.ps1'; n = 'a recorded conclusion that was current does not name a harness changed after it (WS 7d ratchet)' }
  @{ f = 'ops\audit-rule-currency.ps1';        n = 'every .claude\rules globs entry matches a tracked file; stale dated claims are reported (WS 7e)' }
  @{ f = 'ops\audit-measurement-provenance.ps1'; n = 'a recorded measurement names the harness it ran through and the commit or date it ran at - a RATCHET at 8, because retro-filling the existing set was explicitly not asked for and a bar over them would be red on day one' }
  @{ f = 'ops\audit-source-comment-strip.ps1'; n = 'no source scanner reduces PowerShell by LINE comments only - a block header must not be readable as a declaration (it enrolled 8 libraries here as self-tests)' }
  # From a linked worktree every FULL path carries \.claude\worktrees\, so a walk excluding on it reads nothing and reports clean; e1afb523b fixed nineteen and this blocks the next.
  @{ f = 'ops\audit-full-path-excludes.ps1';   n = 'no NEW tree walk excludes worktrees or .claude by matching a file''s FULL path instead of the path below its root - a ratchet, hermetic, reads source only' }
  # A typed parameter keeps its type for its whole scope and names are case-insensitive, so `$rule = @(...)` beside [string]$Rule made ONE string and a self-test passed over nothing; the rule in ops-and-gates.md did not stop the recurrence (2026-09-11).
  @{ f = 'ops\audit-typed-param-shadow.ps1';   n = 'no NEW assignment reuses a typed parameter''s name with a value of another kind, which converts it rather than making a local - a ratchet over the AST, hermetic, reads source only' }
  # 8253ded82 glued a self-test's closing if/else onto its last case line, so the branch never exited and every push's gate ran a live three-store pull and scored it ok.
  @{ f = 'ops\audit-keyword-arguments.ps1';    n = 'no tracked .ps1 or .psm1 carries a statement keyword (if, else, exit, return, try, throw, continue and the rest) as a bare command ARGUMENT - a statement glued onto a command line never runs as one; a gate at zero, hermetic, reads source only' }
  # 2026-09-11: this watcher ran only inside test-auditors, which this file skips, and walked grocery\ only; wave-preaudit's drill died mid-suite on the class it watches.
  @{ f = 'grocery\test-native-stderr-eap.ps1'; n = 'no NEW native child redirects its stderr under EAP=Stop anywhere in the repo - the shell fixtures of the 2026-08-22 bug, plus an AST scan ratcheted by named site; hermetic, reads source only' }
  # Concurrent pushes run the same self-tests over each other in ONE %TEMP%, so a fixed name there is shared; c3a686290 moved guard-contract and test-guards to a per-run directory and this blocks the next fixed name.
  @{ f = 'ops\audit-fixed-temp-names.ps1';     n = 'no NEW path under %TEMP% is built from a FIXED leaf that concurrent runs of one suite would share - a ratchet, hermetic, reads source only' }
  # 2026-09-11: ingredient-queue defined a function named Get-Item, which outranks the cmdlet, so its live-ledger assertion
  # read 0 before and after for 17 days. A rule in ops-and-gates.md reaches whoever opens it; this reaches the next definition.
  @{ f = 'ops\audit-cmdlet-shadow.ps1';        n = 'no tracked script defines a function named after a built-in cmdlet or module function, except a file-and-name allowlist entry with its reason - hermetic, a pinned name list, reads source only' }
  # 2026-09-11: a test-auditors case compared a TRACKED artifact under out\ with a board that reaches a worktree by COPY, so a chain
  # that regenerated it in main and committed its source only refused every push from every worktree for about 17 hours.
  @{ f = 'ops\audit-crossroad-reads.ps1';      n = 'no NEW test-auditors case decides its verdict by comparing a file that reaches a checkout by COMMIT with one that reaches it by COPY - a ratchet BY NAME over the AST, hermetic, reads source and git' }
  # Brad's ruling 1 (2026-09-10): every alert type is exactly one class. With no argument this is the SOURCE half
  # only, so a new Send-Alert call site with no registry entry fails the push instead of paging next morning as
  # UNREGISTERED ALERT TYPE. The queue half reads data and runs in the daily chain's alert-registry lane.
  @{ f = 'grocery\audit-alert-registry.ps1';   n = 'every Send-Alert call site whose subject can be read maps to exactly one class in grocery\alert-registry.json' }
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
  # run it. This said "exercised in the nightly chain" until 2026-09-11, when none of the box's 193 scheduled
  # tasks and no .ps1, .cmd, .xml or .yml in the tree invoked either. The battery (hunt-daemon.py --selftest
  # runs exactly this file) is now defined as TC Daemon Battery 0230 - ops\scheduled-tasks\tc-daemon-battery-0230.xml,
  # which runs ops\run-daemon-battery.ps1: exit code first, --names-diff against a committed reference, and red on
  # any git status line in its throwaway checkout. A definition is not a registration; health-heartbeat pages
  # TASK MISSING while the task is not on the scheduler.
  'meal-prep\pipeline\hunt-daemon.py'       = 'the daemon itself - its --selftest IS the battery below; runs for minutes'
  'meal-prep\pipeline\hunt_daemon_selftest.py' = 'the full daemon battery - 250-680 s; nightly as TC Daemon Battery 0230 (ops\run-daemon-battery.ps1), not at push time'
}
$pySuites = @()
# MATCHED BELOW THE ROOT (2026-09-11, lib\tree-walk.ps1), the same fix as the PowerShell discovery above. On the full
# path every .py in a linked worktree carried \worktrees\, so this walk resolved no suites from a spawned session
# and the discovery floor below failed the gate for a reason that had nothing to do with the change being pushed.
# KEPT AS A LIST rather than consumed inline: lib\gate-verdict.ps1 fingerprints the BYTES of every script this
# discovery walked, and that has to be the same set the gates were chosen from.
$pyWalk = @(Get-ChildItem -Path $repoFull -Recurse -Filter '*.py' -File -ErrorAction SilentlyContinue |
            Where-Object { (Get-TcPathBelowRoot $_.FullName $repoFull) -notmatch '\\\.venv\\|\\archive\\|\\worktrees\\|\\node_modules\\|\\site-packages\\|\\\.git\\' })
foreach ($f in $pyWalk) {
  $rel = (Get-TcPathBelowRoot $f.FullName $repoFull).TrimStart('\')
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
$pyVersion = ''   # part of the fingerprint below: the same tree judged by another interpreter is another run
foreach ($cand in @('C:\Codex\Python312\python.exe', 'python3', 'python')) {
  try {
    $v = & $cand --version 2>&1
    if ($LASTEXITCODE -eq 0 -and ([string]$v) -match 'Python\s+3') { $pyExe = $cand; $pyVersion = ([string]$v).Trim(); break }
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
# ---- A VERDICT ALREADY EARNED IS NOT EARNED AGAIN (2026-09-11) ----
# About half the completed runs on the day the pool saturated were a session's own run-gates rather than a push, and
# the shape in the process table was a session that runs the gate, reads the exit code and then pushes - so the hook
# ran the identical tree again, for twice the slot time and one verdict. lib\gate-verdict.ps1 holds the rule: a
# fingerprint over the HEAD tree, every git status entry, and the BYTES of every script this discovery walked (which
# covers an ignored script, and a line-ending flip git diff hides). A green verdict recorded for that exact
# fingerprint, in THIS checkout, inside its age limit, is printed and nothing is dispatched. -NoReuse runs them
# anyway. Taken BEFORE the slots, so a reuse never joins the queue at all.
. (Join-Path $repo 'lib\gate-verdict.ps1')
$verdictPath = Join-Path $repo 'ops\out\gate-verdict.json'
$fpFiles = [Collections.Generic.List[string]]::new()
foreach ($s in $scripts) { [void]$fpFiles.Add([string]$s.FullName) }
foreach ($s in $pyWalk) { [void]$fpFiles.Add([string]$s.FullName) }
$fpExtra = @(('powershell=' + $PSEXE), ('python=' + [string]$pyExe + ' ' + $pyVersion), ('gates=' + $allJobs.Count))
$fpBefore = Get-TcGateFingerprint -Repo $repo -Files $fpFiles.ToArray() -Extra $fpExtra
if (-not $fail.Count) {
  $priorVerdict = Read-TcGateVerdict -Path $verdictPath
  $reuse = Test-TcGateVerdictReuse -Verdict $priorVerdict -Fingerprint $fpBefore.Fingerprint -Repo $repo -NowUtc ([DateTime]::UtcNow)
  if ($reuse.Reuse -and -not $NoReuse) {
    Write-Output ("run-gates: PASSED - all {0} gate(s) passed at {1} over content byte-identical to this checkout now, so not one was run again ({2}). Pass -NoReuse to run them regardless." -f $reuse.Passed, $reuse.At, $reuse.Reason)
    Exit-Guard -Name 'run-gates' -Summary ("pass={0} fail=0 reused=1" -f $reuse.Passed) -Code 0
  }
  Write-Output ("run-gates: no recorded verdict stands in for this run - {0}" -f $(if ($NoReuse) { '-NoReuse was passed' } else { $reuse.Reason }))
}
# A PUSH THAT CAN NO LONGER LAND IS NOT WAITED FOR (2026-09-11). ops\hooks\pre-push hands this run the refs it is
# pushing and the remote's URL, and lib\push-landable.ps1 asks the remote whether any of them still holds the sha
# git gave the hook. When none does, every ref would be rejected whatever the gates say, so queueing for a slot and
# then running every gate spends the machine on a verdict that session cannot use. Checked while waiting, and once
# more before dispatch. A remote that cannot be read decides nothing and the gates run.
$pushAbandon = $null
if ($PushRefsFile) {
  . (Join-Path $repo 'lib\push-landable.ps1')
  $pushRemoteUse = if ($PushRemote) { $PushRemote } else { 'origin' }
  $pushAbandon = { Get-TcPushCannotLandReason -RefsFile $PushRefsFile -Remote $pushRemoteUse -WorkingDirectory $repo }
}
# THE SLOTS ARE HELD ONLY AROUND THE POOL: discovery above and judging below spawn nothing, so holding
# them any longer would make other runs wait on work that uses no worker. A run REFUSES with 3 rather than running
# over the budget - running anyway is the pile-up - and since 2026-09-11 it waits in ARRIVAL ORDER, so a refusal
# means the QUEUE stopped moving for 20 minutes, not that this run lost a race (lib\gate-slots.ps1).
$askedJobs = $Jobs
$lease = Enter-TcGateSlots -Want $askedJobs -Abandon $pushAbandon -OnWait {
  param($ahead)
  Write-Output ("run-gates: all {0} machine-wide gate worker slots are held by other gate runs - queued behind {1} earlier run(s), and served in arrival order" -f $script:TcGateSlotTotal, $ahead)
}
if ($lease.TimedOut) {
  Write-Output ("run-gates: COULD NOT EVALUATE - waited {0:N0}s for a gate worker slot and the queue did not move for the last 1,200s ({1} run(s) still ahead of this one, and all {2} slots held). Nothing was run; that is not a pass." -f ($lease.WaitedMs / 1000), $lease.Ahead, $script:TcGateSlotTotal)
  Exit-Guard -Name 'run-gates' -Summary 'blind=no-gate-worker-slot' -Code 3
}
if ($pushAbandon -and -not $lease.Abandoned -and $lease.WaitedMs -ge 30000) {
  $saidNow = & $pushAbandon
  $saidNow = @($saidNow)
  if ($saidNow.Count -and [string]$saidNow[$saidNow.Count - 1]) {
    Exit-TcGateSlots $lease
    $lease.Abandoned = [string]$saidNow[$saidNow.Count - 1]
  }
}
if ($lease.Abandoned) {
  Write-Output ("run-gates: COULD NOT EVALUATE - this push can no longer land, so no gate was run for it: {0}. Fetch, rebase onto what the remote holds now, and push again. Nothing was run; that is not a pass." -f $lease.Abandoned)
  Exit-Guard -Name 'run-gates' -Summary 'blind=push-cannot-land' -Code 3
}
$Jobs = $lease.Count
Write-Output ("run-gates: {0} gate(s) dispatched into ONE pool starting at width {1} (asked {2}; {3} slot(s) of a machine-wide {4}, after {5:N1}s waiting for them)" -f $allJobs.Count, $Jobs, $askedJobs, $lease.Count, $script:TcGateSlotTotal, ($lease.WaitedMs / 1000))
# THE GRANT MOVES WITH THE WORK (2026-09-11). Holding the first grant until the whole pool finished queued
# every other push behind this run's slowest straggler - measured: five runs idle while one held all 10
# slots with 2 gates left. So the pool tops up toward what it asked for while gates are still queued, and
# hands back every slot it no longer has a running gate for once the last gate is dispatched.
$script:gateWidthMax = $lease.Count
try {
  $allRes = Invoke-TcParallel -Jobs $allJobs.ToArray() -Concurrency $Jobs -WorkingDirectory $repo `
    -Grow { param($width) Add-TcGateSlots -Lease $lease -Want $askedJobs; if ($lease.Count -gt $script:gateWidthMax) { $script:gateWidthMax = $lease.Count }; $lease.Count } `
    -Shrink { param($stillRunning) Reduce-TcGateSlots -Lease $lease -Keep $stillRunning }
} finally {
  Exit-TcGateSlots $lease
}
Write-Output ("run-gates: pool width reached {0} of the {1} asked, and its slots were handed back as the last gates finished" -f $script:gateWidthMax, $askedJobs)
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
  # EXIT 0 IS NOT A VERDICT (2026-09-11). On that day 8253ded82 glued pull-grocery-ads' closing if/else onto its last
  # case line: the -SelfTest branch never exited, fell through to the LIVE three-store pull, wrote out\ads-<today>.json
  # and exited 0, and this loop scored it ok on every push for hours. A self-test's last words must now be its OWN
  # verdict (lib\selftest-verdict.ps1 is the rule and its fixtures). Exit 0 without one is COULD NOT EVALUATE, never
  # ok. Measured the same day at 2c0d9c45c over run-gates' own discovery: 6 of 316 suites exited 0 with no verdict
  # line, all six named a tally or a bare VERDICT instead, and all six were given one in the same change.
  $score = Get-TcSelfTestScore -ExitCode $rc -Lines $out
  if ($score.Score -ceq 'no-verdict') {
    $noVerdict += $rel
    Write-Output ("  NO VERDICT  {0}  (exit 0, scored 3 - {1}; last line: {2})" -f $rel, $score.Verdict.Reason, $score.Verdict.Line)
  }
  elseif ($score.Score -ceq 'ok') {
    $pass++
    # A PASS THAT COULD NOT LOOK IS NAMED (2026-09-11). A self-test may report a case BLIND - it could not
    # look, so it neither passed nor failed - and exit 0; sidecar\start-sidecar.ps1 does for its venv in a
    # checkout that has none. Its COMPLETE marker then carries blind=<n>, and without this line a green run
    # would hide it. Read off the LAST marker only, so a fixture line quoting the word cannot trip it.
    $marks = @(@($out) | Where-Object { "$_" -match '^[A-Z0-9][A-Z0-9-]*-COMPLETE\b' })
    if ($marks.Count -and ("" + $marks[$marks.Count - 1]) -match '\bblind=([1-9][0-9]*)\b') {
      $blindGates += ("{0} ({1} case(s))" -f $rel, $Matches[1])
      Write-Output ("  ok    {0}  (BLIND on {1} case(s) - see its output)" -f $rel, $Matches[1])
    } else {
      Write-Output ("  ok    {0}" -f $rel)
    }
  }
  else {
    $fail += $rel
    $said = if ($rc -eq 0) { ' - it exited 0, but its own output says it failed' } else { '' }
    Write-Output ("  FAIL  {0}  (exit {1}{2})" -f $rel, $rc, $said)
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
  # EXIT 0 IS NOT A VERDICT here either: the same rule and the same lib as the PowerShell self-test loop above. A
  # `--selftest` branch that forgets its sys.exit falls into main() exactly the way pull-grocery-ads fell into its pull.
  $score = Get-TcSelfTestScore -ExitCode $rc -Lines $out
  if ($score.Score -ceq 'no-verdict') {
    $noVerdict += $g.f
    Write-Output ("  NO VERDICT  {0}  (exit 0, scored 3 - {1}; last line: {2})" -f $g.f, $score.Verdict.Reason, $score.Verdict.Line)
  }
  elseif ($score.Score -ceq 'ok') { $pass++; Write-Output ("  ok    {0}  ({1})" -f $g.f, $g.n) }
  else {
    $fail += $g.f
    $said = if ($rc -eq 0) { ' - it exited 0, but its own output says it failed' } else { '' }
    Write-Output ("  FAIL  {0}  (exit {1}{2}) - {3}" -f $g.f, $rc, $said, $g.n)
    @($out) | Where-Object { $_ -match '^\s*FAIL\b|SELF-TEST FAIL' } | Select-Object -First 12 | ForEach-Object { Write-Output ('          ' + $_) }
  }
}

Write-Output ''
Write-Output ("run-gates: {0} passed, {1} failed, {2} could not evaluate (exit 0 with no self-test verdict)" -f $pass, $fail.Count, $noVerdict.Count)
foreach ($f in $fail) { Write-Output ("  failed: " + $f) }
foreach ($f in $noVerdict) { Write-Output ("  no verdict: " + $f) }
# Counted as passes, and listed so that is never mistaken for having looked. Not a failure: a gate-check
# checkout without the sidecar venv is not a broken tree. See the self-test loop above.
if ($blindGates.Count) {
  Write-Output ("run-gates: {0} passing gate(s) reported BLIND cases - they could not look, so those cases are NOT covered by this run:" -f $blindGates.Count)
  foreach ($b in $blindGates) { Write-Output ("  blind:  " + $b) }
}
# A WORDS-LEVEL VERDICT ON EVERY EXIT PATH, NOT ONLY ON 3 (2026-09-06, backlog E2). The could-not-evaluate
# path above has said "COULD NOT EVALUATE" in words since it was written; these two said only "186 passed,
# 1 failed", which is a TALLY and not a verdict - a reader still has to know that this tool's 1 means
# failed, when the same 1 means "findings, report written" in the PLAN v3 batteries and the guard-contract
# audits reserve 2 for a hard finding and 3 for could-not-evaluate. Three live vocabularies, so the number
# is not a channel an agent can decode without knowing which tool it ran. The words are.
if ($fail.Count) {
  $nvNote = if ($noVerdict.Count) { ', and ' + $noVerdict.Count + ' self-test(s) exited 0 with no verdict of their own' } else { '' }
  Write-Output ("run-gates: FAILED - {0} gate(s) did not pass{1}. This tree must not be pushed until they do; fix the cause, never the gate." -f $fail.Count, $nvNote)
} elseif ($noVerdict.Count) {
  # The names ride on this line because it is the one the pre-push hook prints back.
  Write-Output ("run-gates: COULD NOT EVALUATE - {0} self-test(s) exited 0 without printing their own verdict, so code past the verdict ran or the verdict never did: {1}. Scored 3, never ok. Each suite's last line must name its self-test with a result word (lib\selftest-verdict.ps1)." -f $noVerdict.Count, ($noVerdict -join ', '))
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
# A self-test with no verdict is red too: it blocks the push, so it leaves the same record, named in `gates`.
if ($fail.Count -or $noVerdict.Count) {
  . (Join-Path $repo 'lib\event-bus.ps1')
  # NO `Select-Object -First` ON A NATIVE EXE. It stops the upstream pipeline, which sends
  # the child a broken pipe mid-write; harmless for a one-line rev-parse and a bad habit to
  # spread into a gate. The output is captured and indexed instead.
  $red = @($fail) + @($noVerdict)
  $head = @(@($red | ForEach-Object { "$_" })[0..([Math]::Min(11, $red.Count - 1))])
  # 'Continue' AROUND THE REDIRECT, NOT A CATCH ALONE (2026-09-11). Under this file's 'Stop' a git stderr line is a
  # terminating throw; the catch kept the gate alive and threw git's answer away, so one warning recorded an empty
  # commit. grocery\test-native-stderr-eap.ps1 watches the shape repo-wide. The catch stays for a missing git.
  $commit = ''
  $branch = ''
  $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try {
    $c = @(& git -C $repo rev-parse --short HEAD 2>$null); if ($c.Count) { $commit = "$($c[0])" }
    $b = @(& git -C $repo rev-parse --abbrev-ref HEAD 2>$null); if ($b.Count) { $branch = "$($b[0])" }
  } catch { } finally { $ErrorActionPreference = $prevEap }
  $null = Write-TcEvent -Kind 'gate-red' -Producer 'ops\run-gates.ps1' -Data @{
    failed     = $fail.Count
    no_verdict = $noVerdict.Count
    passed     = $pass
    gates      = $head
    commit     = "$commit"
    branch     = "$branch"
  }
}
# THE VERDICT IS RECORDED FOR THE CONTENT IT JUDGED (2026-09-11), and only when this run exits 0 AND the checkout is
# byte-identical to the fingerprint taken before the gates ran: a pass over content that moved underneath it
# describes neither version. A red or could-not-evaluate run over content a recorded pass names WITHDRAWS that pass,
# because gates that disagree with themselves over one tree have given no verdict to reuse. This can never fail the
# run: a verdict that could not be kept is a lost saving, not a defect in the tree.
# 1 when anything failed; otherwise 3 when a self-test exited 0 with no verdict of its own, because that suite was NOT
# evaluated - and a 3 reaches Save-TcGateVerdict below, which records nothing and withdraws any pass over this same
# content. A suite nobody evaluated must never stand in for one that passed.
$gateCode = $(if ($fail.Count) { 1 } elseif ($noVerdict.Count) { 3 } else { 0 })
try {
  if (-not $fpBefore.Fingerprint) {
    Write-Output ("run-gates: this run's verdict is NOT recorded for reuse - {0}" -f $fpBefore.Reason)
  } else {
    $fpAfter = Get-TcGateFingerprint -Repo $repo -Files $fpFiles.ToArray() -Extra $fpExtra
    $vCommit = ''
    # Same 'Continue' as the event above, for the same reason: under this file's 'Stop' a git stderr line is a
    # terminating throw, and the catch would keep the run alive while recording a verdict with no commit on it.
    $prevEapV = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $vc = @(& git -C $repo rev-parse --short HEAD 2>$null); if ($vc.Count) { $vCommit = "$($vc[0])" } } catch { } finally { $ErrorActionPreference = $prevEapV }
    $kept = Save-TcGateVerdict -Path $verdictPath -ExitCode $gateCode -Before $fpBefore.Fingerprint -After $fpAfter.Fingerprint -Repo $repo -Passed $pass -Commit $vCommit
    if ($kept -eq 'recorded') { Write-Output 'run-gates: this pass is recorded for reuse - the next run in this checkout over the same content prints it instead of running the gates again' }
    elseif ($kept -eq 'content-moved') { Write-Output 'run-gates: this pass is NOT recorded for reuse - the checkout changed while the gates ran, so it describes neither version' }
    elseif ($kept -eq 'withdrawn') { Write-Output 'run-gates: the recorded pass for this content is WITHDRAWN - the same content has now failed here' }
  }
} catch { }
Exit-Guard -Name 'run-gates' -Summary ("pass={0} fail={1} noverdict={2}" -f $pass, $fail.Count, $noVerdict.Count) -Code $gateCode
