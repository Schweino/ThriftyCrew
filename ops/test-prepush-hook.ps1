<#
  Does a push from a LINKED worktree run the gate without handing it the repository? And does the hook
  run test-auditors before a guard-touching push, and only then?

  WHY IT EXISTS, MEASURED 2026-09-10. Git exports GIT_DIR to a hook when the push comes from a linked
  worktree and exports none from the main checkout. Verified in a sandbox with git 2.54: the same hook
  printed GIT_DIR=<main>\.git\worktrees\linked from one and no GIT_DIR from the other. ops\hooks\pre-push
  ran ops\run-gates.ps1 with that inherited, and the gate's hermetic git self-tests - which build temp
  repos with `git init` and `git config user.name` - wrote into the SHARED repository instead:
  core.bare=true, user.name=Session, user.email=t@t, core.autocrlf=false, commit.gpgsign=false. Every
  checkout on the box then refused `git status` with "this operation must be run in a work tree". That
  push was the first from a detached gate-check checkout, which is exactly the method
  skills\claude-code-craft\applies-here.md rule 6 prescribes for pushing from a worktree.

  THE SECOND FOUNDING CASE, SAME INCIDENT. While the shared repository was bare, the hook's
  `git rev-parse --show-toplevel` failed and its `[ -z "$repo" ] && exit 0` let a sibling session's push
  out at 05:28:19 with no gate run and no gate log. A hook that cannot find a tree must refuse.

  THE THIRD, SAME DAY (plan step 5). Queue item 2026-09-10-4ac6ae was a commit that broke
  grocery\test-auditors.ps1 getting past a clean run-gates, which cannot reach that suite. The hook now
  runs ops\prepush-test-auditors.ps1 after the gate. The sandbox drives it through REAL pushes with the
  REAL script and a stub test-auditors whose failing cases this file chooses: a push touching no guard
  input must not run the suite, a push adding a failing case must be refused by name, a failure already
  in the known-failures record must not refuse and must still be printed, a stale record must refuse,
  and a checkout with no boards must refuse as could-not-evaluate.

  THE FOURTH (ruling R19, 2026-09-10): the check now runs only the test-auditors units a push can reach. The
  stub is unit-wrapped like the real harness, and real pushes prove that a changed fixture runs only the unit
  reading it and says how many cases ran, that a regression in that unit is still refused by name, that a
  shared file runs every unit reading it, that code outside every unit still runs, and that the full run the
  daily chain makes (no skip file) still runs every unit. A docs-only push running nothing is the NOT NEEDED
  case above.

  THE FIFTH (2026-09-11), two more halves of the first incident. The stub gate also runs
  `git -C <temp> config user.name`, the write that put user.name=Session into the shared config, and a case proves
  the shared identity survives while the write lands in the temp repo. The hook now reads the refs BEFORE it asks
  git for a tree, so a push that only deletes a ref goes through a checkout whose tree cannot be resolved - driven
  in the damaged state - without starting the gate. The same gate pushed from the MAIN checkout is a clean twin, so
  the reorder cannot have cost the ordinary push.

  THE SIXTH (2026-09-11, later). run-gates printed "lib\git-repo-env.ps1 is not recognized" from this sandbox and
  passed: the sandbox copied a hand list of libraries older than that one, so the check's own Clear-TcGitRepoEnv
  never ran and no case could tell. The sandbox now copies every lib\*.ps1, the check exits 3 on a library it cannot
  load, and cases drive that refusal and hand the check a leaked GIT_DIR from a caller that is not the hook.

  THE SEVENTH (2026-09-11): the hook SEEDS a blind checkout, once, before the gate. meal-prep\db\built is
  gitignored and .worktreeinclude structurally cannot carry it - Claude Code's candidate list is built with
  `git ls-files --directory`, which collapses a fully-ignored directory to ONE line (measured that day: 1 line
  against 1,168 files on disk). So a fresh worktree had no built card, feed-covers-published and wave-preaudit
  could not look, and both FAILED the push - after it had queued for a gate worker slot. 18 of 53 failed gate
  runs that day failed on nothing else, and 31 of 106 worktrees had no card
  (design\PLAN-gate-queue-2026-09-11.md). Those two gates now report the case BLIND; the hook seeds so they can
  look. The cases use a STUB seeder and pin the hook's WIRING - that it runs, before the gate, handed this
  checkout, once - plus the twin that a checkout with no seeder still pushes, because seeding supplies and
  never decides.

  THE EIGHTH (2026-09-11, later still): ONE PUSH AT A TIME. git fixes a push's refs when it connects, so a push is a
  compare-and-swap whose critical section is this whole hook - and measured that day, 11 consecutive attempts from
  one session each passed run-gates and each were rejected with "cannot lock ref 'refs/heads/main'" while other
  sessions landed every 15 to 25 minutes. The hook now holds a machine-wide push lock across the gate
  (ops\hold-push-lock.ps1, lib\push-lock.ps1, design\PLAN-push-livelock-2026-09-11.md). The cases drive REAL pushes
  and pin the two halves that matter: a push takes the lock, says so and lands; and with the lock held by somebody
  else the hook says UNLOCKED and pushes ANYWAY, because a fairness device that could refuse a push would be worse
  than the livelock. Plus the twins that a red gate under a held lock still refuses, and that both a passing and a
  refused push hand the lock back. THE FIXTURE NEVER TOUCHES THE LIVE LOCK: TC_PUSH_LOCK_PREFIX redirects it onto a
  private Local\ name, which hold-push-lock honours only because it is Local\.

  THE NINTH (2026-09-23, W0.2 of design\PLAN-push-derived-conflicts-2026-09-23.md): THE SUITE WRITES NO PRODUCTION
  LEDGER ROW. The push-lock cases start the REAL ops\hold-push-lock.ps1, which appends a `hook-lock` row to the push
  ledger (lib\push-ledger.ps1), and nothing redirected it, so every run of this suite wrote its rows into
  %LOCALAPPDATA%\ThriftyCrew\push-ledger beside the real pushes they were meant to measure. Read at 2026-09-23 over
  that ledger's ten daily files (2026-09-12 to 2026-09-23): 426 of its 806 hook-lock rows, from 142 distinct sandboxes,
  named a checkout inside one of these sandboxes. TC_PUSH_LEDGER_ROOT now points the whole run at a directory inside
  this run's sandbox, set before the first push and restored in the outer finally. The sandbox is named
  tc-prepush-selftest-<blob8>-<pid>-<guid8>, where <blob8> is the first 8 hex of this file's own git blob, so a
  sandbox name WITH a blob segment can only come from a suite at or after this change, and the old prefix still
  matches every exclusion glob. A MUST FIRE reads the suite's own ledger for a row a sandbox wrote (so the redirect
  cannot pass by nothing having been written), and a MUST NOT FIRE reads the real ledger for this run's sandbox name.
  It compares names, never a line count: a real push may append to the real file while the suite runs.

  THE TENTH (2026-09-23, W1.1 of the same plan): THE REHEARSAL RECORD IS ASKED FOR FIRST, AND EVERY REFUSAL NAMES
  ITSELF. The hook ran ops\rehearse-chain.ps1 -CheckPush after test-auditors, inside the branch where test-auditors
  had passed, so a chain push with no verdict paid run-gates and a full test-auditors run before a record read that
  takes seconds refused it. The check now runs before run-gates. The rehearsal clause below drives it with the REAL
  rehearse-chain.ps1: with no verdict the push is refused, neither stub's start marker exists afterwards, the refusal
  prints the fixed line, and the new early exit leaves no refs file in the directory the hook writes it to (the gate
  stub records that path, so the case cannot watch the wrong directory). With a passing verdict recorded for exactly
  that content, keyed the way rehearse-chain keys it, the same push runs both legs and lands; a push touching a
  test-auditors input and no chain file runs both legs as before. Every BLOCKED and REFUSING exit now ends with
  `PRE-PUSH-REFUSED cause=<run-gates|test-auditors|rehearsal|structure> [gate=<first failing gate>]`, which
  ops\push-main.ps1 reads before the prose; four cases read it for structure, run-gates with a FAIL line (gate= is the
  first one's gate), run-gates with none (no gate=), and test-auditors.

  THE ELEVENTH (2026-09-23, W0.6 of the same plan, section 15.5): EVERY REFUSAL WRITES ONE PUSH-LEDGER ROW. The ledger's
  only writers were ops\hold-push-lock.ps1, which the hook starts only after every check has passed, and
  ops\push-main.ps1, so a plain push the hook refused left no row and W0.3b could not count it as an attempt. The hook
  now starts ops\record-hook-refusal.ps1 just before its fixed PRE-PUSH-REFUSED line. The sandbox carries that writer in
  the MAIN checkout only, untracked, the way it carries hold-push-lock: a push from the linked checkout has no copy of
  its own, so its rows prove the fallback to the main checkout's copy, which is the road most checkouts on this box
  take. Four cases read the suite's own ledger: a chain push with no verdict writes exactly one `hook-refused` row with
  cause=rehearsal, the pushing checkout, the ref line's sha, this hook's blob and under_push_main false; a run-gates red
  writes cause=run-gates and the first failing gate; three passing pushes write none; and with a ledger directory that
  cannot be made the hook still exits 1 with its fixed line, printing the could-not-record line BEFORE it. The suite
  clears TC_PUSH_LOCK_HOLDER for its whole run: run under ops\push-main.ps1 it inherits push-main's live token, and a
  sandbox push would otherwise read as under_push_main (ops-and-gates.md: say which instance you mean).

  THE TWELFTH (2026-09-23, W8.3 as amended in section 16.4, Brad's D14): A CHAIN PUSH THAT IS NOT THE CHAIN QUEUE'S
  HEAD IS REFUSED IN SECONDS WHILE THE QUEUE IS OCCUPIED. Directly after the rehearsal record check, and only for a push
  that check calls chain-touching, the hook asks lib\chain-queue.ps1 with zero wait whether a live ticket that has not
  landed or left exists, and refuses (cause=chain-queue) a push whose TC_CHAIN_QUEUE_HOLDER does not name the head.
  Tickets are held by the REAL library from another process on a private Local\ prefix and a per-run root, with
  TC_CHAIN_QUEUE_SELFTEST set. Ten cases: a plain chain push with a recorded verdict is refused before run-gates,
  naming the head's pid, and writes one hook-refused row; a non-chain push lands meanwhile; the head's own push lands;
  a head whose record is 120 s under the library's own stall bound still refuses, and 120 s past it is WEDGED and the push
  proceeds, because the queue's timed-out waiters push unqueued and must not be refused here; a
  member behind the head is refused and told to wait; with the queue free the chain push lands with the WARN; a probe
  that throws proceeds and says so; and the probe sits between the record check and run-gates and takes nothing.

  THE THIRTEENTH (2026-09-23, W9.1 of the same plan, Brad's D19): THE POST-COMMIT HOOK STARTS THE EARLY REHEARSAL. The
  measured 43% early-verdict hit rate assumed a rehearsal started when the session committed, so ops\hooks\post-commit
  starts the committing checkout's own ops\push-main.ps1 -Prepare, detached, and returns. It gets its own small repository
  in this sandbox (three checkouts: one older than the hook, one whose push-main has no -Prepare, one current) and a stub
  push-main that records what it inherited. Ten cases: a session commit from a linked worktree starts its own -Prepare
  with no GIT_DIR or GIT_INDEX_FILE; the hook's log line names the commit; the commit RETURNS while a held child is still
  running (a hang guard, never a bar); a throwing starter leaves the commit made and rc 0; and it starts nothing without
  CLAUDE_CODE_SESSION_ID, under TC_REHEARSAL_RUN, in a checkout older than itself, where push-main has no -Prepare (one
  printed line, fail open), or for the commits a rebase replays. A MUST NOT FIRE here is read twice: the hook's own log
  line is absent when the commit returns (the hook writes it BEFORE starting anything), and a later commit that does start
  the stub has written its marker while this one's never appeared. A static case holds that the hook's only road is
  push-main -Prepare, so the early-rehearsal cap that rehearse-chain -Early takes is never gone around.

  WHAT THIS DRIVES. A sandbox repository, a linked worktree, the REAL ops\hooks\pre-push, the REAL
  ops\prepush-test-auditors.ps1 with every lib\*.ps1, and stubs for the gate and for test-auditors.
  Then real `git push`es to a sandbox bare remote. No network, nothing outside the sandbox. THIS FILE
  SCRUBS ITS OWN REPOSITORY ENVIRONMENT FIRST: run by an unfixed hook, a copy that did not would recreate
  the very damage it exists to detect, on the real repository.

  Exit 0 pass, 1 a case failed, 3 could not evaluate (the sandbox could not be built).

  SCOPE OF A CLEAN REPORT: SOUND for the variables the hook's unset line names on the git version this
  box runs; UNSOUND for a future git that exports a variable that line does not name. For the test-auditors
  check it proves the hook's wiring and the script's decisions against a stub suite; it does not prove the
  real suite's input set, which the script's own -SelfTest pins live.
#>
# gate-inputs: ops\hooks\pre-push, ops\hooks\post-commit, ops\prepush-test-auditors.ps1, ops\hold-push-lock.ps1, ops\rehearse-chain.ps1, ops\record-hook-refusal.ps1, lib\*.ps1
# WHY THIS FILE DECLARES (Brad, 2026-09-12). At 67s this is the most expensive gate on the box and the one that
# sets the floor on a push's wall clock, since no pool can finish sooner than its longest single job. It could
# never be keyed by inference: line 258 copies the library set with `Get-ChildItem (Join-Path $RepoRoot 'lib')
# -Filter *.ps1`, a DIRECTORY ENUMERATION, and no source key can name a listing - which is exactly why the glob
# form exists. A library added to lib\ tomorrow moves this key with nobody editing the line above.
# The set is what the sandbox actually copies in: the hook itself (251), prepush-test-auditors (252),
# hold-push-lock (fallback path), every lib\*.ps1 (258-260), and ops\rehearse-chain.ps1, which the chain rehearsal
# clause copies into the linked checkout and which the hook's first check runs (added 2026-09-23, W1.1: until then
# an edit to it could replay this suite's recorded pass without running it, because a declaration outranks inference), and
# ops\record-hook-refusal.ps1, which the sandbox's main checkout carries and every refusal starts (added 2026-09-23, W0.6). The line numbers here are as first written and
# have moved; the Copy-Item calls are the ground truth. ops\run-gates.ps1 is already in every key as a RUNNER, so it
# is deliberately not repeated here.
[CmdletBinding()]
param([switch]$SelfTest)   # accepted so ops\run-gates.ps1 discovers this file; the cases run either way

$ErrorActionPreference = 'Continue'
$RepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $RepoRoot 'lib\guard-contract.ps1')

$envLib = Join-Path $RepoRoot 'lib\git-repo-env.ps1'
if (-not (Test-Path -LiteralPath $envLib)) {
  # Never build the sandbox without the scrub: run by an unfixed hook, this file would do the damage it tests for.
  "BLIND: $envLib is missing - the sandbox is not built without clearing the repository environment first"
  Exit-Guard -Name 'TEST-PREPUSH-HOOK' -Code 3 -Summary 'blind=missing-env-lib'
}
. $envLib
Clear-TcGitRepoEnv

$fails = @(); $ran = @()
function Case {
  param([string]$Label, [string]$Name, [bool]$Ok, [string]$Detail = '')
  $script:ran += $Name
  if (-not $Ok) { $script:fails += "$Label $Name" }
  '  {0,-14} {1,-66} {2}' -f $Label, $Name, $(if ($Ok) { 'ok' } else { "FAIL $Detail" })
}
function G {
  # One git call, stderr discarded (git writes progress and CRLF notices there), exit code returned.
  $null = & git @args 2>$null
  return $LASTEXITCODE
}
function GOut {
  $o = & git @args 2>$null
  return (@($o) -join "`n").Trim()
}
function PushOut {
  # A push whose hook output is kept: the refusal has to NAME the case, so stderr is the evidence here.
  param([string]$Dir, [string]$Ref)
  $o = @(& git -C $Dir -c ("core.hooksPath=" + $script:HooksPath) push origin ("HEAD:refs/heads/" + $Ref) 2>&1 | ForEach-Object { [string]$_ })
  $rcP = $LASTEXITCODE
  return [pscustomobject]@{ rc = $rcP; text = ($o -join "`n"); remote = (GOut --git-dir $script:Remote rev-parse --verify -q ("refs/heads/" + $Ref)); head = (GOut -C $Dir rev-parse HEAD) }
}
function CommitFile {
  param([string]$Dir, [string]$Rel, [string]$Text)
  $p = Join-Path $Dir $Rel
  $null = New-Item -ItemType Directory -Force (Split-Path -Parent $p)
  [IO.File]::WriteAllText($p, $Text, (New-Object Text.UTF8Encoding($false)))
  $null = G -C $Dir add -- $Rel
  $null = G -C $Dir commit -q -m ("edit " + $Rel)
}

$hookSrc = Join-Path $RepoRoot 'ops\hooks\pre-push'
$gatesSrc = Join-Path $RepoRoot 'ops\run-gates.ps1'
$taCheckSrc = Join-Path $RepoRoot 'ops\prepush-test-auditors.ps1'
$contractSrc = Join-Path $RepoRoot 'lib\guard-contract.ps1'
foreach ($need in @($hookSrc, $taCheckSrc, $contractSrc)) {
  if (-not (Test-Path -LiteralPath $need)) {
    "BLIND: $need is missing - nothing to drive"
    Exit-Guard -Name 'TEST-PREPUSH-HOOK' -Code 3 -Summary 'blind=missing-source'
  }
}

function Get-SuiteBlob8 {
  <# The first 8 hex of this file's own git blob, for the sandbox name (W0.2). git hashes it through the repository's
     attributes, so a CRLF checkout of an LF blob still names the blob main carries. When git cannot (a copy outside
     any repository), the same id is computed here over the bytes as they sit, which is `git hash-object --no-filters`:
     the name always carries 8 hex, and never a word that a reader would have to special-case. #>
  $b = GOut -C $RepoRoot hash-object -- $PSCommandPath
  if ($b -match '^[0-9a-f]{40}$') { return $b.Substring(0, 8) }
  $bytes = [IO.File]::ReadAllBytes($PSCommandPath)
  $hdr = [Text.Encoding]::ASCII.GetBytes('blob ' + $bytes.Length + [char]0)
  $all = New-Object byte[] ($hdr.Length + $bytes.Length)
  [Array]::Copy($hdr, 0, $all, 0, $hdr.Length)
  [Array]::Copy($bytes, 0, $all, $hdr.Length, $bytes.Length)
  $sha = [Security.Cryptography.SHA1]::Create()
  try { return ([BitConverter]::ToString($sha.ComputeHash($all)) -replace '-', '').ToLowerInvariant().Substring(0, 8) }
  finally { $sha.Dispose() }
}
function Read-LedgerLinesNaming {
  <# Every ledger line, in the given files, that names $Needle, read ORDINALLY off the raw line (String.Contains is
     ordinal), plus how many files were read and which could not be. A file that does not exist is simply not read; one
     that exists and cannot be read is REPORTED, because a could-not-look must never pass for "nothing there". #>
  param([string[]]$Files, [string]$Needle)
  $hits = New-Object Collections.Generic.List[string]
  $read = 0; $unreadable = New-Object Collections.Generic.List[string]
  foreach ($f in @($Files | Sort-Object -Unique)) {
    if (-not (Test-Path -LiteralPath $f)) { continue }
    try { $lines = @(Get-Content -LiteralPath $f -ErrorAction Stop) } catch { $unreadable.Add($f); continue }
    $read++
    foreach ($l in $lines) { if (([string]$l).Contains($Needle)) { $hits.Add([string]$l) } }
  }
  return [pscustomobject]@{ Hits = $hits.ToArray(); Read = $read; Unreadable = $unreadable.ToArray() }
}
function Get-SuiteRefusalRows {
  <# Every `hook-refused` row in this run's own ledger (W0.6), parsed through lib\push-ledger.ps1's reader, from every
     daily file the directory holds, so a run that crosses midnight still sees all of them. A malformed line is not a
     refusal row and is left out; a case that needs to know a row is ABSENT reads it through a filter on this list. #>
  param([string]$Dir)
  $out = New-Object Collections.Generic.List[object]
  foreach ($file in @(Get-ChildItem -LiteralPath $Dir -Filter 'pushes-*.jsonl' -File -ErrorAction SilentlyContinue)) {
    $rowsRaw = Read-TcPushRows -Path $file.FullName
    foreach ($r in @($rowsRaw)) {
      if ($null -eq $r -or $r.PSObject.Properties['malformed']) { continue }
      if ([string]::Equals([string]$r.event, 'hook-refused', [StringComparison]::Ordinal)) { $out.Add($r) }
    }
  }
  return , ($out.ToArray())
}
function Get-SandboxRehearsalKey {
  <# The verdict key ops\rehearse-chain.ps1 computes for a commit, READ FROM THAT SCRIPT: the sandbox's own copy's
     read-only `-ListSet -Commit <rev>` prints it as key= on its CHAIN-REHEARSAL-LISTSET-COMPLETE line. Until 2026-09-23
     this rebuilt the key from the manifest's files[] (the script cannot be dot-sourced), and W9.5 broke that replica the
     day the key gained the dot-source closure: the sandbox's rehearse-chain.ps1 is a member and dot-sources lib\*.ps1,
     so the real key covers those too. One definition, asked, cannot drift. A key read wrong here is LOUD, never quiet:
     the recorded-verdict CLEAN TWIN below is then refused, and its detail prints this key beside the 12 characters the
     hook's own refusal named. $Files is kept for the callers and no longer read. #>
  param([string]$Dir, [string]$Rev, [string[]]$Files)
  $rc = Join-Path $Dir 'ops\rehearse-chain.ps1'
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { $ls = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $rc -ListSet -Commit $Rev) } finally { $ErrorActionPreference = $prevEap }
  $m = [regex]::Match([string]@($ls)[-1], '^CHAIN-REHEARSAL-LISTSET-COMPLETE files=\d+ .*\bkey=([0-9a-f]{64})\b')
  if ($m.Success) { return $m.Groups[1].Value }
  return ('no-key: ' + [string]@($ls)[-1])
}

# THE SANDBOX NAME CARRIES THIS FILE'S BLOB (W0.2), so a ledger row naming a sandbox says which suite wrote it.
$sbLeaf = 'tc-prepush-selftest-{0}-{1}-{2}' -f (Get-SuiteBlob8), $PID, [guid]::NewGuid().ToString('N').Substring(0, 8)
$sb = Join-Path $env:TEMP $sbLeaf
$main = Join-Path $sb 'main'
$linked = Join-Path $sb 'linked'
$remote = Join-Path $sb 'remote.git'
$script:Remote = $remote
$probe = Join-Path $sb 'probe'
$built = $false
$utf8 = New-Object Text.UTF8Encoding($false)
# THE WHOLE RUN WRITES ITS LEDGER ROWS INSIDE ITS OWN SANDBOX (W0.2). Set before the first push and restored in the
# outer finally. Every child the suite starts - git, the hook, the holder the hook starts - inherits it, which a
# per-call -LedgerRoot could never reach. The production root is read from the library, never spelled here.
. (Join-Path $RepoRoot 'lib\push-ledger.ps1')
$ledgerRootHad = Test-Path -LiteralPath 'Env:\TC_PUSH_LEDGER_ROOT'
$ledgerRootWas = [string]$env:TC_PUSH_LEDGER_ROOT
$suiteLedger = Join-Path $sb 'ledger'
$prodLedgerRoot = $script:TcPushLedgerRoot
$suiteStart = [datetime]::Now
$env:TC_PUSH_LEDGER_ROOT = $suiteLedger
# NO INHERITED PUSH-MAIN TOKEN FOR THE WHOLE RUN (W0.6). run-gates often runs under ops\push-main.ps1, which exports
# TC_PUSH_LOCK_HOLDER while it holds the real push lock, and every sandbox push here would inherit it: the refusal rows
# would then say under_push_main about pushes that are plain. The holder these cases start takes a private Local\ lock,
# which a Global token never matched, so clearing it changes nothing any other case reads. Restored in the finally.
$holderTokHad = Test-Path -LiteralPath 'Env:\TC_PUSH_LOCK_HOLDER'
$holderTokWas = [string]$env:TC_PUSH_LOCK_HOLDER
Remove-Item -LiteralPath 'Env:\TC_PUSH_LOCK_HOLDER' -ErrorAction SilentlyContinue
# NO PRODUCTION CHAIN QUEUE FOR THE WHOLE RUN (W8.3). The hook's zero-wait probe reads lib\chain-queue.ps1, and since W9.2
# the production queue is live: a sandbox chain push in ANY case here would otherwise be refused cause=chain-queue
# whenever a real session on this box holds a ticket (found 2026-09-24 landing W8.3: 4 of 77 red while another
# session's push-main queued). So every case runs against a private, empty Local\ instance under this run's sandbox,
# and THE TWELFTH's own cases swap in their populated one and hand this one back. Restored in the outer finally.
$cqSuiteHad = @{}; $cqSuiteWas = @{}
foreach ($n in 'TC_CHAIN_QUEUE_PREFIX', 'TC_CHAIN_QUEUE_ROOT', 'TC_CHAIN_QUEUE_HOLDER') {
  $cqSuiteHad[$n] = Test-Path -LiteralPath ('Env:\' + $n)
  $cqSuiteWas[$n] = [string][Environment]::GetEnvironmentVariable($n)
}
$cqSuitePrefix = 'Local\tc-prepush-cq-suite-' + [guid]::NewGuid().ToString('N').Substring(0, 10) + '-'
$cqSuiteRoot = Join-Path $sb 'cq-suite'
$env:TC_CHAIN_QUEUE_PREFIX = $cqSuitePrefix
$env:TC_CHAIN_QUEUE_ROOT = $cqSuiteRoot
Remove-Item -LiteralPath 'Env:\TC_CHAIN_QUEUE_HOLDER' -ErrorAction SilentlyContinue
try {
  $null = New-Item -ItemType Directory -Force $sb, $probe, $cqSuiteRoot
  $steps = @(
    (G init -q $main),
    (G -C $main config user.email t@t),
    (G -C $main config user.name t),
    (G -C $main config commit.gpgsign false),
    (G -C $main config core.autocrlf false),
    # THE REAL REPOSITORY CARRIES THIS, AND THE SECOND CASE IS NOT REPRODUCIBLE WITHOUT IT. The first
    # draft of this fixture left it out, and a push from the "bare" sandbox sailed through the FIXED
    # hook: without worktreeConfig git ignores a common core.bare inside a linked worktree, so
    # --show-toplevel still resolved and there was nothing for the refusal to catch. A sandbox that
    # differs from production in the one setting the bug depends on proves nothing about production.
    (G -C $main config extensions.worktreeConfig true)
  )
  foreach ($d in @('ops', 'lib', 'grocery', 'design')) { $null = New-Item -ItemType Directory -Force (Join-Path $main $d) }
  # THE STUB GATE does the damaging act and records what it inherited. Single-quoted: nothing expands
  # until the stub itself runs inside the hook.
  $stub = @'
$p = $env:TC_PREPUSH_PROBE
[IO.File]::WriteAllText((Join-Path $p 'gate-saw.txt'), ('GIT_DIR=' + [string]$env:GIT_DIR))
$i = [array]::IndexOf($args, '-PushRefsFile')
$rf = if ($i -ge 0 -and $args.Count -gt ($i + 1)) { [string]$args[$i + 1] } else { '' }
$seen = if ($rf -and (Test-Path -LiteralPath $rf)) { [IO.File]::ReadAllText($rf) } else { 'NO-REFS-FILE:' + $rf }
[IO.File]::WriteAllText((Join-Path $p 'gate-refs.txt'), $seen)
# WHERE the hook put its refs file, so the W1.1 refs case can prove it watches the directory the hook writes into.
[IO.File]::WriteAllText((Join-Path $p 'gate-refs-path.txt'), $rf)
$t = Join-Path $p ('initprobe-' + [guid]::NewGuid().ToString('N'))
$null = & git init -q $t 2>$null
$null = & git -C $t config user.name GateProbeWrote 2>$null
[IO.File]::WriteAllText((Join-Path $p 'gate-target.txt'), $t)
# IS THE PUSH LOCK ACTUALLY HELD WHILE THE GATE RUNS? This is the only reading that can see an EARLY RELEASE, and
# without it the push-lock cases below pass whether the lock is held for the whole hook or for 250 ms. It is not
# hypothetical: the first version of the hook handed the holder Git Bash's `$$`, an MSYS pid Get-Process cannot
# resolve, so the holder read its own hook as dead and released at once - and all 41 cases passed anyway. 1 here
# means the lock was FREE while the gate ran, which is the failure.
if ($env:TC_PUSH_LOCK_PREFIX) {
  $mx = New-Object System.Threading.Mutex($false, ($env:TC_PUSH_LOCK_PREFIX + '0'))
  $free = $false
  try { $free = $mx.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $free = $true }
  if ($free) { try { $mx.ReleaseMutex() } catch { } }
  $mx.Dispose()
  [IO.File]::WriteAllText((Join-Path $p 'gate-lock-free.txt'), [string][int]$free)
}
# WHAT THE GATE SAYS, not just what it exits with (2026-09-12). The hook reads this stdout back out of its
# log to name WHY a 3 happened, so a case that only sets an exit code cannot reach that decision at all.
# Lines are separated by @@ because a newline cannot survive the environment block cleanly here.
if ($env:TC_PREPUSH_PROBE_SAY) {
  foreach ($l in ([string]$env:TC_PREPUSH_PROBE_SAY -split '@@')) { Write-Output $l }
}
exit ([int]$env:TC_PREPUSH_PROBE_EXIT)
'@
  [IO.File]::WriteAllText((Join-Path $main 'ops\run-gates.ps1'), $stub, $utf8)
  # THE STUB test-auditors. It names guards.ps1 and a fixture root the way the real one does, so the REAL
  # check derives a real input set from it, and it fails exactly the cases TC_PREPUSH_TA_FAILS lists.
  # SINCE R19 (2026-09-10) THE STUB IS UNIT-WRAPPED the way the real one is: u001 reads guards.ps1, u002 reads
  # a fixture and a shared rule file, u003 reads only the shared rule file, and one statement sits outside
  # every unit. Each unit that runs appends its id to units-ran.txt, so a case can see exactly what ran.
  $taStub = @'
[CmdletBinding()]
param([string]$SkipUnitsFile = '')
$root = $PSScriptRoot
$fix  = Join-Path $root 'regression-inputs\guard-fixtures'
$HasBoard = (@(Get-ChildItem (Join-Path $root 'out\comparison-*.json') -ErrorAction SilentlyContinue).Count -gt 0) -or
            (Test-Path (Join-Path $root 'out\recipe-board.json'))
$script:SkipIds = @(); if ($SkipUnitsFile) { $script:SkipIds = @([IO.File]::ReadAllLines($SkipUnitsFile) | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
$script:URan = 0; $script:USkipped = 0
function Use-Unit {
  param([Parameter(Mandatory = $true, Position = 0)][string]$Id, [string[]]$Reads = @(), [string]$Always = '')
  if ($script:SkipIds -contains $Id) { $script:USkipped++; return $false }
  $script:URan++; Add-Content -LiteralPath (Join-Path $env:TC_PREPUSH_PROBE 'units-ran.txt') -Value $Id
  return $true
}
[IO.File]::WriteAllText((Join-Path $env:TC_PREPUSH_PROBE 'auditors-ran.txt'), 'ran')
[IO.File]::WriteAllText((Join-Path $env:TC_PREPUSH_PROBE 'ta-saw.txt'), ('GIT_DIR=' + [string]$env:GIT_DIR))
$pass = 0; $failed = 0
try {
if (Use-Unit 'u001-guards') {
$guardText = Get-Content (Join-Path $root 'guards.ps1') -Raw
Write-Output '  PASS  stub watcher'; $pass++
foreach ($c in @(([string]$env:TC_PREPUSH_TA_FAILS) -split '\|' | Where-Object { $_ })) { Write-Output ('  FAIL  ' + $c); $failed++ }
} # u001-guards
if (Use-Unit 'u002-beta') {
$betaBoard = Get-Content (Join-Path $fix 'beta-board.json') -Raw
$betaRules = Get-Content (Join-Path $root 'shared-rules.json') -Raw
Write-Output '  PASS  beta watcher'; $pass++
foreach ($c in @(([string]$env:TC_PREPUSH_TA_FAILS_BETA) -split '\|' | Where-Object { $_ })) { Write-Output ('  FAIL  ' + $c); $failed++ }
} # u002-beta
[IO.File]::WriteAllText((Join-Path $env:TC_PREPUSH_PROBE 'undeclared-ran.txt'), 'ran')
if (Use-Unit 'u003-gamma') {
$gammaRules = Get-Content (Join-Path $root 'shared-rules.json') -Raw
Write-Output '  PASS  gamma watcher'; $pass++
} # u003-gamma
} finally { }
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\guard-contract.ps1')
$note = if ($script:USkipped -gt 0) { ' selective=1 units_ran=' + $script:URan + ' units_skipped=' + $script:USkipped } else { '' }
Write-GuardComplete -Name 'test-auditors' -Summary ('pass=' + $pass + ' failed=' + $failed + ' hygiene=0 skipped=0' + $note)
exit $(if ($failed -gt 0) { 2 } else { 0 })
'@
  [IO.File]::WriteAllText((Join-Path $main 'grocery\test-auditors.ps1'), $taStub, $utf8)
  [IO.File]::WriteAllText((Join-Path $main 'grocery\guards.ps1'), "# guard v1`n", $utf8)
  $null = New-Item -ItemType Directory -Force (Join-Path $main 'grocery\regression-inputs\guard-fixtures')
  [IO.File]::WriteAllText((Join-Path $main 'grocery\regression-inputs\guard-fixtures\beta-board.json'), "{`"v`":1}`n", $utf8)
  [IO.File]::WriteAllText((Join-Path $main 'grocery\shared-rules.json'), "{`"v`":1}`n", $utf8)
  [IO.File]::WriteAllText((Join-Path $main 'design\note.md'), "v1`n", $utf8)
  [IO.File]::WriteAllText((Join-Path $main '.gitignore'), "grocery/out/`n", $utf8)   # reach-fixture-ok: the %TEMP% sandbox repo's own .gitignore, not the real module
  Copy-Item -LiteralPath $taCheckSrc -Destination (Join-Path $main 'ops\prepush-test-auditors.ps1')
  # EVERY lib\*.ps1, NOT A HAND LIST (2026-09-11). The list this replaced named guard-contract and bot-paths and
  # predated lib\git-repo-env.ps1, so the check driven below loaded no clear, printed "is not recognized" on every
  # direct call, and every case passed. The whole directory is 29 files under 400 KB that day, and it keeps the
  # sandbox's libraries the production set. A library missing here now turns the cases red: the check refuses one
  # it cannot load (the lib-load cases below).
  $libFiles = Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'lib') -File -Filter *.ps1
  foreach ($libFile in @($libFiles | Where-Object { $_.Extension -ieq '.ps1' })) {
    Copy-Item -LiteralPath $libFile.FullName -Destination (Join-Path $main ('lib\' + $libFile.Name))
  }
  $steps += (G -C $main add -A)
  $steps += (G -C $main commit -q -m seed)
  $steps += (G init -q --bare $remote)
  $steps += (G -C $main remote add origin $remote)
  # The seed goes to the remote BEFORE the hook is installed, so origin/main exists and each case below
  # pushes only the commit it made - the way a real push is measured against what the remote already has.
  $steps += (G -C $main push -q origin HEAD:refs/heads/main)
  # The REAL hook, as LF: sh reads a CR as part of the command name.
  $hookText = [IO.File]::ReadAllText($hookSrc).Replace("`r`n", "`n")
  [IO.File]::WriteAllText((Join-Path $main '.git\hooks\pre-push'), $hookText, $utf8)
  $steps += (G -C $main worktree add -q --detach $linked)
  $bad = @($steps | Where-Object { $_ -ne 0 })
  if ($bad.Count -gt 0 -or -not (Test-Path -LiteralPath (Join-Path $linked 'ops\run-gates.ps1'))) {
    "BLIND: the sandbox could not be built (non-zero git steps: $($bad.Count))"
    Exit-Guard -Name 'TEST-PREPUSH-HOOK' -Code 3 -Summary 'blind=sandbox'
  }
  $built = $true
  $hooksPath = Join-Path $main '.git\hooks'
  $script:HooksPath = $hooksPath
  # THE REFUSAL WRITER (W0.6), in the MAIN checkout only and untracked, as hold-push-lock is carried below: the linked
  # checkout shares main's commits and not its untracked files, so its refusals prove the hook's fallback to the main
  # checkout's copy. Every refusal from here on appends one row to this run's own ledger ($suiteLedger).
  $recorderSrc = Join-Path $RepoRoot 'ops\record-hook-refusal.ps1'
  if (Test-Path -LiteralPath $recorderSrc) { Copy-Item -LiteralPath $recorderSrc -Destination (Join-Path $main 'ops\record-hook-refusal.ps1') }
  $installedHookBlob = GOut hash-object --no-filters -- (Join-Path $hooksPath 'pre-push')
  # The hook writes its gate log to ${TMPDIR:-/tmp}. Pointed into the sandbox, the log is removed with it
  # instead of accumulating in the real temp directory one refused push at a time.
  $env:TMPDIR = $sb.Replace('\', '/')

  # ---- a PASSING gate, pushed from the linked worktree ----
  $env:TC_PREPUSH_PROBE = $probe
  $env:TC_PREPUSH_PROBE_EXIT = '0'
  $rc = G -C $linked -c ("core.hooksPath=" + $hooksPath) push -q origin HEAD:refs/heads/probe
  $sawFile = Join-Path $probe 'gate-saw.txt'
  $saw = if (Test-Path -LiteralPath $sawFile) { [IO.File]::ReadAllText($sawFile) } else { '' }
  $bare = GOut config --file (Join-Path $main '.git\config') core.bare

  # CLEAN TWIN first: the hook still RUNS the gate. Without this, the two cases below could pass
  # because nothing ran at all.
  Case 'CLEAN TWIN' 'the hook still runs the gate on a linked-worktree push' (Test-Path -LiteralPath $sawFile)
  # MUST FIRE, THE FOUNDING DAMAGE: a temp-repo `git init` inside the gate turned the shared repo bare.
  Case 'MUST FIRE' 'a gate run from a linked-worktree push leaves the shared repo non-bare' `
    ($bare -eq 'false') "core.bare=$bare"
  # MUST FIRE, THE CAUSE: the gate inherited GIT_DIR.
  Case 'MUST FIRE' 'the gate the hook runs inherits no GIT_DIR' ($saw -eq 'GIT_DIR=') $saw
  # CLEAN TWIN: a passing gate still lets the push through.
  $remoteRef = GOut --git-dir $remote rev-parse --verify -q refs/heads/probe
  $head = GOut -C $linked rev-parse HEAD
  Case 'CLEAN TWIN' 'a passing gate still lets the push through' `
    ($rc -eq 0 -and $remoteRef -eq $head -and $head.Length -eq 40) "rc=$rc remote=$remoteRef head=$head"
  # CLEAN TWIN (2026-09-11): the gate is handed the refs this push updates and the remote sha git gave the hook, so
  # lib\push-landable.ps1 can refuse a push the remote will reject anyway before it spends a gate worker slot on it.
  $gateRefsFile = Join-Path $probe 'gate-refs.txt'
  $gateRefsSeen = if (Test-Path -LiteralPath $gateRefsFile) { ([IO.File]::ReadAllText($gateRefsFile)).Trim() } else { '' }
  Case 'CLEAN TWIN' 'the hook hands the gate the refs this push updates, with the sha the remote held' `
    ($gateRefsSeen.Contains($head) -and $gateRefsSeen.Contains('refs/heads/probe')) "refs=[$gateRefsSeen]"
  # MUST FIRE, THE MECHANISM NAMED ON 2026-09-11: the stub gate also runs `git -C <temp> config user.name`. With
  # GIT_DIR inherited that write lands in the SHARED config; user.name=Session on 2026-09-10 was exactly this.
  $mainName = GOut config --file (Join-Path $main '.git\config') user.name
  $targetFile = Join-Path $probe 'gate-target.txt'
  $target = if (Test-Path -LiteralPath $targetFile) { ([IO.File]::ReadAllText($targetFile)).Trim() } else { '' }
  $targetName = if ($target -and (Test-Path -LiteralPath (Join-Path $target '.git\config'))) { GOut config --file (Join-Path $target '.git\config') user.name } else { '' }
  Case 'MUST FIRE' 'a temp-repo config write inside that gate leaves the shared repo identity alone' ($mainName -eq 't') "user.name=$mainName"
  # CLEAN TWIN: the write happened, where it was aimed. Without it the case above passes on a stub that wrote nothing.
  Case 'CLEAN TWIN' 'the gate''s temp-repo config write lands in the temp repo it named' ($targetName -eq 'GateProbeWrote') "target=$target user.name=$targetName"

  # ---- the same passing gate, pushed from the MAIN checkout ----
  # CLEAN TWIN: git exports no GIT_DIR here, and the reordered hook still gates the ordinary push.
  Remove-Item -LiteralPath $sawFile -ErrorAction SilentlyContinue
  $rcMain = G -C $main -c ("core.hooksPath=" + $hooksPath) push -q origin HEAD:refs/heads/probe-main
  $mainRef = GOut --git-dir $remote rev-parse --verify -q refs/heads/probe-main
  $mainHead = GOut -C $main rev-parse HEAD
  Case 'CLEAN TWIN' 'the same hook pushed from the MAIN checkout still runs the gate and lets the push through' `
    ((Test-Path -LiteralPath $sawFile) -and $rcMain -eq 0 -and $mainRef -eq $mainHead -and $mainHead.Length -eq 40) "rc=$rcMain remote=$mainRef head=$mainHead"

  # ---- a gate that COULD NOT EVALUATE ----
  Remove-Item -LiteralPath $sawFile -ErrorAction SilentlyContinue
  $env:TC_PREPUSH_PROBE_EXIT = '3'
  $rc3 = G -C $linked -c ("core.hooksPath=" + $hooksPath) push -q origin HEAD:refs/heads/refused
  $refused = GOut --git-dir $remote rev-parse --verify -q refs/heads/refused
  # CLEAN TWIN: the unset did not cost the hook its refusal. A 3 is never a pass.
  Case 'CLEAN TWIN' 'a gate exiting 3 still blocks the push' (($rc3 -ne 0) -and ($refused -eq '')) "rc=$rc3 ref=$refused"

  # ---- a 3 must name the cause run-gates ACTUALLY reported (2026-09-12) ----
  # THE FOUNDING CASE. Until this date the hook answered every 3 with "that means gate discovery is broken",
  # and by 2026-09-11 a 3 also meant the machine-wide gate worker queue had not moved: that afternoon a
  # standalone run-gates and then a push each waited about 20 minutes while roughly 30 other run-gates
  # processes queued and the box sat near 87%, and both pushers were told their discovery was broken. A
  # refusal that points at the wrong cause sends somebody to debug a walk that is fine, and the next thing
  # they reach for is --no-verify. The stub prints exactly what run-gates prints on that path - the COULD NOT
  # EVALUATE line and Exit-Guard's marker - so these cases drive the hook's real read of its own log.
  $slotSay = 'run-gates: COULD NOT EVALUATE - waited 1,200s for a gate worker slot and the queue did not move for the last 1,200s (7 run(s) still ahead of this one, and all 10 slots held). Nothing was run; that is not a pass.' +
    '@@RUN-GATES-COMPLETE blind=no-gate-worker-slot'
  $env:TC_PREPUSH_PROBE_SAY = $slotSay
  $slotPush = PushOut $linked 'slot-blind'
  $slotText = $slotPush.text
  Case 'MUST FIRE' 'a 3 from slot starvation is refused AND named as slots, not as broken discovery' `
    (($slotPush.rc -ne 0) -and ($slotPush.remote -eq '') -and ($slotText -match 'CAUSE: no gate worker slot') -and ($slotText -notmatch '(?i)discovery')) `
    ("rc=" + $slotPush.rc + " ref=[" + $slotPush.remote + "] text=[" + $slotText + "]")

  # THE BUDGET IT NAMES IS READ FROM lib\gate-slots.ps1 (backlog I237). The refusal said "The 10" for six days after
  # the budget went to 24. CLEAN TWIN: it names the budget the library assigns. MUST FIRE: with the sandbox's copy of
  # the library set to another number it names THAT number, so a literal that happens to match cannot pass.
  $slotLibRx = '(?m)^\$script:TcGateSlotTotal = (\d+)'
  $realBudget = [regex]::Match([IO.File]::ReadAllText((Join-Path $RepoRoot 'lib\gate-slots.ps1')), $slotLibRx).Groups[1].Value
  Case 'CLEAN TWIN' 'the slot refusal names the budget lib\gate-slots.ps1 assigns' `
    ([bool]$realBudget -and ($slotText -match ('The ' + $realBudget + ' machine-wide slots'))) ("budget=" + $realBudget + " text=[" + $slotText + "]")
  $sbSlots = Join-Path $linked 'lib\gate-slots.ps1'
  $sbSlotsBytes = [IO.File]::ReadAllBytes($sbSlots)
  $sbSlotsText = [IO.File]::ReadAllText($sbSlots)
  [IO.File]::WriteAllText($sbSlots, [regex]::Replace($sbSlotsText, $slotLibRx, '$script:TcGateSlotTotal = 17'), $utf8)
  $slot17 = PushOut $linked 'slot-blind-17'
  [IO.File]::WriteAllBytes($sbSlots, $sbSlotsBytes)
  Case 'MUST FIRE' 'with the library assigning 17 the slot refusal names 17, so the number is read and not a literal' `
    (($slot17.rc -ne 0) -and ($slot17.text -match 'The 17 machine-wide slots')) ("rc=" + $slot17.rc + " text=[" + $slot17.text + "]")

  # CLEAN TWIN: the cause this hook could already name still gets named. A discovery collapse is the same
  # exit code down the same branch, and the repair must not have traded one wrong cause for another.
  $discSay = 'run-gates: COULD NOT EVALUATE - PowerShell self-test DISCOVERY found only 12 suite(s); it found 201 on 2026-09-07 and 262 on 2026-09-11. That is the walk broken, not the tree clean.' +
    '@@RUN-GATES-COMPLETE blind=selftest-discovery-collapsed n=12'
  $env:TC_PREPUSH_PROBE_SAY = $discSay
  $discPush = PushOut $linked 'discovery-blind'
  $discText = $discPush.text
  Case 'CLEAN TWIN' 'a 3 from a discovery collapse is refused and still says DISCOVERY' `
    (($discPush.rc -ne 0) -and ($discPush.remote -eq '') -and ($discText -match 'CAUSE: gate DISCOVERY is broken')) `
    ("rc=" + $discPush.rc + " ref=[" + $discPush.remote + "] text=[" + $discText + "]")

  # MUST FIRE (W6.9, 2026-09-23): a 3 from a static gate that exited 0 while its own marker said it read nothing is
  # refused AND named as that. The hook gained its static-scanned-zero branch with 8bf0d72f8 and no case drove it, so
  # losing the branch would have fallen through to the generic "reported blind=" line with every case here green.
  # The stub prints what run-gates prints on that path: its COULD NOT EVALUATE line and Exit-Guard's marker.
  $zeroSay = 'run-gates: COULD NOT EVALUATE - static gate(s) scanned zero files: ops\audit-readjson-inline-wrap.ps1' +
    '@@RUN-GATES-COMPLETE blind=static-scanned-zero pass=412 fail=0 noverdict=0 static_zero=1'
  $env:TC_PREPUSH_PROBE_SAY = $zeroSay
  $zeroPush = PushOut $linked 'static-zero-blind'
  $zeroText = $zeroPush.text
  Case 'MUST FIRE' 'a 3 from a static gate that read nothing is refused AND named as that, not as slots or discovery' `
    (($zeroPush.rc -ne 0) -and ($zeroPush.remote -eq '') -and ($zeroText -match 'CAUSE: a static gate exited 0 while its own marker said it READ NOTHING') -and ($zeroText -notmatch 'no gate worker slot') -and ($zeroText -notmatch '(?i)discovery')) `
    ("rc=" + $zeroPush.rc + " ref=[" + $zeroPush.remote + "] text=[" + $zeroText + "]")

  # CLEAN TWIN: a 3 that names no cause at all - the pool-size mismatch exits 3 with no marker - is still
  # refused, and the hook says it cannot name one rather than inventing the nearest.
  $env:TC_PREPUSH_PROBE_SAY = 'run-gates: something went wrong and it did not say what'
  $mutePush = PushOut $linked 'mute-blind'
  $muteText = $mutePush.text
  Case 'CLEAN TWIN' 'a 3 with no blind token is refused and names no cause rather than guessing one' `
    (($mutePush.rc -ne 0) -and ($mutePush.remote -eq '') -and ($muteText -match 'cannot name a cause') -and ($muteText -notmatch '(?i)discovery')) `
    ("rc=" + $mutePush.rc + " ref=[" + $mutePush.remote + "] text=[" + $muteText + "]")

  # ---- W1.1 (2026-09-23): every refusal ends with ONE fixed line, PRE-PUSH-REFUSED cause=<...> [gate=<...>] ----
  # ops\push-main.ps1 classifies an in-lock refusal from this line (W0.1's reject_class) and prefers it to the prose,
  # which changes whenever a message is improved. MUST FIRE: a red gate names run-gates and the gate on run-gates'
  # FIRST "  FAIL" line, exactly as run-gates prints it ("  FAIL  <gate>  (exit N) - <name>").
  $env:TC_PREPUSH_PROBE_EXIT = '1'
  $env:TC_PREPUSH_PROBE_SAY = '  FAIL  ops\audit-conclusion-currency.ps1  (exit 2) - conclusion currency' +
    '@@  FAIL  ops\audit-fixture-vocabulary.ps1  (exit 2) - fixture vocabulary' +
    '@@RUN-GATES-COMPLETE pass=410 fail=2'
  $redPush = PushOut $linked 'red-gate-named'
  $env:TC_PREPUSH_PROBE_EXIT = '3'
  Case 'MUST FIRE' 'a red gate prints PRE-PUSH-REFUSED cause=run-gates gate=<the first FAIL line''s gate>' `
    (($redPush.rc -ne 0) -and ($redPush.remote -eq '') -and ($redPush.text -match '(?m)^PRE-PUSH-REFUSED cause=run-gates gate=ops\\audit-conclusion-currency\.ps1\s*$')) `
    ("rc=" + $redPush.rc + " text=[" + $redPush.text + "]")
  # MUST NOT FIRE: a 3 whose gate printed no FAIL line names the cause and NO gate, rather than an empty or invented one.
  Case 'MUST NOT FIRE' 'a 3 with no FAIL line prints cause=run-gates and no gate=' `
    ($slotText -match '(?m)^PRE-PUSH-REFUSED cause=run-gates\s*$') ("text=[" + $slotText + "]")

  # ---- W0.6 (2026-09-23): that red push wrote ONE hook-refused row, through the MAIN checkout's writer ----
  # The linked checkout carries no writer of its own (the sandbox put it in main only), so this row also proves the
  # hook's fallback to the main checkout's copy, the road most checkouts on the box take.
  $redRowsRaw = Get-SuiteRefusalRows -Dir $suiteLedger
  $redRows = @(@($redRowsRaw) | Where-Object { [string]$_.remote_ref -eq 'refs/heads/red-gate-named' })
  $redRow = $(if ($redRows.Count -eq 1) { $redRows[0] } else { $null })
  $linkedHasWriter = Test-Path -LiteralPath (Join-Path $linked 'ops\record-hook-refusal.ps1')
  Case 'MUST FIRE' 'a run-gates red writes one hook-refused row naming cause=run-gates and the first failing gate' `
    ($null -ne $redRow -and $redRow.cause -eq 'run-gates' -and $redRow.gate -eq 'ops\audit-conclusion-currency.ps1' -and $redRow.rc -eq 1 `
      -and [string]::Equals([string]$redRow.checkout, $linked, [StringComparison]::OrdinalIgnoreCase) -and $redRow.local_sha -eq $redPush.head `
      -and [bool]$redRow.log -and -not $linkedHasWriter) `
    ("rows=" + $redRows.Count + " linkedHasWriter=" + $linkedHasWriter + " row=[" + $(if ($redRow) { ConvertTo-Json $redRow -Compress } else { '' }) + "]")

  # CLEAN TWIN (W0.6): a ledger that cannot be written changes nothing the hook decides. TC_PUSH_LEDGER_ROOT names a FILE,
  # so the writer cannot make its directory; the push is still refused with the fixed line, the could-not-record line
  # comes BEFORE that line (the fixed line stays the hook's last word), and no row reached the suite's ledger either.
  $env:TC_PREPUSH_PROBE_EXIT = '1'
  $blockedLedger = Join-Path $sb 'ledger-is-a-file'
  [IO.File]::WriteAllText($blockedLedger, 'not a directory')
  $env:TC_PUSH_LEDGER_ROOT = $blockedLedger
  try { $unrecPush = PushOut $linked 'red-gate-unrecorded' } finally { $env:TC_PUSH_LEDGER_ROOT = $suiteLedger }
  $env:TC_PREPUSH_PROBE_EXIT = '3'
  $iNotRec = $unrecPush.text.IndexOf('pre-push: this refusal was not recorded in the push ledger')
  $iFixed = [regex]::Match($unrecPush.text, '(?m)^PRE-PUSH-REFUSED cause=run-gates gate=ops\\audit-conclusion-currency\.ps1\s*$').Index
  $unrecRowsRaw = Get-SuiteRefusalRows -Dir $suiteLedger
  $unrecRows = @(@($unrecRowsRaw) | Where-Object { [string]$_.remote_ref -eq 'refs/heads/red-gate-unrecorded' })
  Case 'CLEAN TWIN' 'with a ledger directory that cannot be made the hook still exits 1 with PRE-PUSH-REFUSED, saying first that it recorded nothing' `
    (($unrecPush.rc -ne 0) -and ($unrecPush.remote -eq '') -and ($unrecPush.text -match '(?m)^PRE-PUSH-REFUSED cause=run-gates gate=ops\\audit-conclusion-currency\.ps1\s*$') `
      -and $iNotRec -ge 0 -and $iFixed -gt $iNotRec -and $unrecRows.Count -eq 0) `
    ("rc=" + $unrecPush.rc + " notRecordedAt=" + $iNotRec + " fixedAt=" + $iFixed + " rows=" + $unrecRows.Count + " text=[" + $unrecPush.text + "]")
  $env:TC_PREPUSH_PROBE_SAY = ''

  # ---- a checkout whose working tree git cannot resolve ----
  # MUST FIRE, THE SECOND FOUNDING CASE: the sandbox repo turned bare, exactly the damaged state, and a
  # push from the linked worktree must be refused rather than waved through ungated.
  $mainCfg = Join-Path $main '.git\config'
  $null = G config --file $mainCfg core.bare true
  $env:TC_PREPUSH_PROBE_EXIT = '0'
  # Through PushOut since W1.1, so the refusal's own words are kept: the fixed line is read below.
  $pBare = PushOut $linked 'unresolved'
  $rcBare = $pBare.rc
  # THE SAME DAMAGED STATE, a push that only DELETES a ref (2026-09-11). It carries no code and needs no tree.
  Remove-Item -LiteralPath $sawFile -ErrorAction SilentlyContinue
  $probeBefore = GOut --git-dir $remote rev-parse --verify -q refs/heads/probe
  $rcDel = G -C $linked -c ("core.hooksPath=" + $hooksPath) push -q origin :refs/heads/probe
  $delSawGate = Test-Path -LiteralPath $sawFile
  $null = G config --file $mainCfg core.bare false
  $unres = GOut --git-dir $remote rev-parse --verify -q refs/heads/unresolved
  $probeAfter = GOut --git-dir $remote rev-parse --verify -q refs/heads/probe
  Case 'MUST FIRE' 'a push whose working tree cannot be resolved is refused, not waved through' `
    (($rcBare -ne 0) -and ($unres -eq '')) "rc=$rcBare ref=$unres"
  # MUST FIRE (W1.1): a REFUSING exit ends with the fixed line a machine reads, naming the cause as structure.
  Case 'MUST FIRE' 'a structural refusal prints PRE-PUSH-REFUSED cause=structure' `
    ($pBare.text -match '(?m)^PRE-PUSH-REFUSED cause=structure\s*$') ("text=[" + $pBare.text + "]")
  # CLEAN TWIN: the deletion went through - the ref existed, the push succeeded, and the ref moved.
  Case 'CLEAN TWIN' 'a push that only deletes a ref still goes through when the tree cannot be resolved' `
    (($probeBefore.Length -eq 40) -and ($rcDel -eq 0) -and ($probeAfter -ne $probeBefore)) "rc=$rcDel before=$probeBefore after=$probeAfter"
  # MUST NOT FIRE: and no gate was started for it.
  Case 'MUST NOT FIRE' 'a deletion-only push starts no gate' (-not $delSawGate) 'the gate ran'

  # ---- test-auditors before a guard-touching push (plan step 5) ----
  $ranFile = Join-Path $probe 'auditors-ran.txt'
  $hyLine = 'Hy-Vee tag/identity fixtures FAILED (rc=1) - either a price the till will not honour can publish again'
  $newLine = 'guards lost OkUnlessBlind - a guard that examines zero rows can print ok again'
  $null = New-Item -ItemType Directory -Force (Join-Path $main 'grocery\out')   # reach-fixture-ok: a board directory inside the %TEMP% sandbox repo
  [IO.File]::WriteAllText((Join-Path $main 'grocery\out\comparison-2026-01-01.json'), '{"comparison":[]}', $utf8)   # reach-fixture-ok: a stub board inside the %TEMP% sandbox repo
  # The daily chain's side, through the REAL -Record: yesterday's run already failed the Hy-Vee case.
  $recIn = Join-Path $sb 'chain-run.txt'
  [IO.File]::WriteAllText($recIn, ("  PASS  stub watcher`n  FAIL  " + $hyLine + "`ntest-auditors FAIL  (1 failed, 1 passed)`nTEST-AUDITORS-COMPLETE pass=1 failed=1`n"), $utf8)
  $recFile = Join-Path $main '.git\tc-test-auditors-known-failures.json'
  # MUST FIRE: a run taken over an uncommitted guard edit is somebody's in-flight change, not a baseline,
  # and recording it would let that change out as "already failing".
  [IO.File]::WriteAllText((Join-Path $main 'grocery\guards.ps1'), "# guard mid-edit`n", $utf8)
  $null = @(& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $main 'ops\prepush-test-auditors.ps1') -Record -OutputFile $recIn -ExitCode 2)
  $recRcInflight = $LASTEXITCODE
  $null = G -C $main checkout -- grocery/guards.ps1
  Case 'MUST FIRE' 'the chain does not record a run taken over an in-flight guard edit' `
    ($recRcInflight -eq 3 -and -not (Test-Path -LiteralPath $recFile)) "rc=$recRcInflight"
  $recOut = @(& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $main 'ops\prepush-test-auditors.ps1') -Record -OutputFile $recIn -ExitCode 2)
  $recRc = $LASTEXITCODE
  $recFile = Join-Path $main '.git\tc-test-auditors-known-failures.json'
  Case 'CLEAN TWIN' 'the daily chain records a known failure in the shared git directory' `
    ($recRc -eq 0 -and (Test-Path -LiteralPath $recFile) -and ([IO.File]::ReadAllText($recFile)).Contains('Hy-Vee tag/identity')) "rc=$recRc $(@($recOut) -join ' ')"

  # MUST NOT FIRE: a push touching no guard input does not run the suite, even one that would fail.
  CommitFile $main 'design\note.md' "v2`n"
  Remove-Item -LiteralPath $ranFile -ErrorAction SilentlyContinue
  $env:TC_PREPUSH_TA_FAILS = $newLine
  $p = PushOut $main 'docs'
  Case 'MUST NOT FIRE' 'a push touching no guard input never starts test-auditors' `
    ($p.rc -eq 0 -and -not (Test-Path -LiteralPath $ranFile) -and $p.text -match 'NOT NEEDED') "rc=$($p.rc) $($p.text)"

  # MUST FIRE: a guard edit that adds a failing case is refused, and the refusal names the case.
  CommitFile $main 'grocery\guards.ps1' "# guard v2`n"
  Remove-Item -LiteralPath $ranFile -ErrorAction SilentlyContinue
  $env:TC_PREPUSH_TA_FAILS = $hyLine + '|' + $newLine
  $p = PushOut $main 'guard'
  Case 'MUST FIRE' 'a guard push that adds a failing test-auditors case is refused by name' `
    ($p.rc -ne 0 -and $p.remote -eq '' -and (Test-Path -LiteralPath $ranFile) -and $p.text -match 'NEW FAILING CASE\s+guards lost OkUnlessBlind') "rc=$($p.rc) remote=$($p.remote) $($p.text)"
  # MUST FIRE (W1.1): that refusal ends with the fixed line naming test-auditors, and names no run-gates gate.
  Case 'MUST FIRE' 'a test-auditors refusal prints PRE-PUSH-REFUSED cause=test-auditors' `
    ($p.text -match '(?m)^PRE-PUSH-REFUSED cause=test-auditors\s*$') "text=[$($p.text)]"

  # CLEAN TWIN: the same guard push with only the recorded Hy-Vee failure goes through, and says so.
  $env:TC_PREPUSH_TA_FAILS = $hyLine
  $p = PushOut $main 'guard'
  Case 'CLEAN TWIN' 'a failure recorded before the push allows it and is still printed' `
    ($p.rc -eq 0 -and $p.remote -eq $p.head -and $p.text -match 'ALREADY FAILING\s+Hy-Vee tag/identity') "rc=$($p.rc) $($p.text)"

  # MUST FIRE: the record goes stale, and the same recorded failure no longer lets a guard push through.
  $recText = [IO.File]::ReadAllText($recFile)
  $old = [datetime]::UtcNow.AddDays(-10).ToString('o')
  [IO.File]::WriteAllText($recFile, ([regex]::Replace($recText, '"recorded_at":\s*"[^"]*"', ('"recorded_at": "' + $old + '"'))), $utf8)
  CommitFile $main 'grocery\guards.ps1' "# guard v3`n"
  $p = PushOut $main 'guard'
  Case 'MUST FIRE' 'a stale known-failures record refuses even a recorded failure' `
    ($p.rc -ne 0 -and $p.head -ne $p.remote -and $p.text -match 'record is stale') "rc=$($p.rc) $($p.text)"

  # CLEAN TWIN: a guard push with no failing case at all still passes, stale record or not.
  $env:TC_PREPUSH_TA_FAILS = ''
  $p = PushOut $main 'guard'
  Case 'CLEAN TWIN' 'a guard push with no failing case passes' ($p.rc -eq 0 -and $p.remote -eq $p.head -and $p.text -match '(PASS|SELECTED CASES PASSED) after') "rc=$($p.rc) $($p.text)"

  # MUST FIRE: a checkout with no boards cannot evaluate, is refused, and says nothing that reads as a pass.
  CommitFile $linked 'grocery\guards.ps1' "# guard from a worktree`n"
  Remove-Item -LiteralPath $ranFile -ErrorAction SilentlyContinue
  $p = PushOut $linked 'wt-guard'
  Case 'MUST FIRE' 'a guard push from a checkout without boards is refused as could-not-evaluate' `
    ($p.rc -ne 0 -and $p.remote -eq '' -and $p.text -match 'COULD NOT EVALUATE' -and $p.text -notmatch '(?m)^prepush-test-auditors: (PASS|ALLOWED)|test-auditors PASS' -and -not (Test-Path -LiteralPath $ranFile)) "rc=$($p.rc) $($p.text)"

  # ---- R19: a push runs only the units it can reach (real pushes, the REAL selector, the unit-wrapped stub) ----
  $unitsFile = Join-Path $probe 'units-ran.txt'
  $undeclFile = Join-Path $probe 'undeclared-ran.txt'
  $env:TC_PREPUSH_TA_FAILS = ''; $env:TC_PREPUSH_TA_FAILS_BETA = ''
  # MUST FIRE: changing a declared input (a fixture u002 reads) runs u002 and not the units that never read it.
  CommitFile $main 'grocery\regression-inputs\guard-fixtures\beta-board.json' "{`"v`":2}`n"
  Remove-Item -LiteralPath $unitsFile, $undeclFile -ErrorAction SilentlyContinue
  $p = PushOut $main 'sel-fixture'
  $ranU = @(if (Test-Path -LiteralPath $unitsFile) { [IO.File]::ReadAllLines($unitsFile) })
  Case 'MUST FIRE' 'a changed fixture runs only the unit that reads it, and says how many cases ran' `
    ($p.rc -eq 0 -and $p.remote -eq $p.head -and ($ranU -join ',') -eq 'u002-beta' -and $p.text -match 'ran \d+ of .+ cases \(1 of 3 units\), selected by 1 pushed path' -and $p.text -notmatch '(?m)^prepush-test-auditors: PASS after') "rc=$($p.rc) ran=$($ranU -join ',') $($p.text)"
  # MUST FIRE: code that sits in no unit ran on that selective push.
  Case 'MUST FIRE' 'code outside every unit runs on a selective push' (Test-Path -LiteralPath $undeclFile)
  # MUST FIRE: a regression in the selected unit refuses the push, by name.
  $env:TC_PREPUSH_TA_FAILS_BETA = 'beta watcher lost its founding bug - the fixture reads clean'
  CommitFile $main 'grocery\regression-inputs\guard-fixtures\beta-board.json' "{`"v`":3}`n"
  $p = PushOut $main 'sel-fixture'
  Case 'MUST FIRE' 'a regression in a selected unit refuses the push by name' `
    ($p.rc -ne 0 -and $p.remote -ne $p.head -and $p.text -match 'NEW FAILING CASE\s+beta watcher lost its founding bug') "rc=$($p.rc) $($p.text)"
  $env:TC_PREPUSH_TA_FAILS_BETA = ''
  # MUST FIRE: a file two units read selects both of them, and not the unit that never reads it.
  CommitFile $main 'grocery\shared-rules.json' "{`"v`":2}`n"
  Remove-Item -LiteralPath $unitsFile -ErrorAction SilentlyContinue
  $p = PushOut $main 'sel-shared'
  $ranU = @(if (Test-Path -LiteralPath $unitsFile) { [IO.File]::ReadAllLines($unitsFile) })
  Case 'MUST FIRE' 'a push touching a shared file runs every unit that reads it' `
    ($p.rc -eq 0 -and ($ranU -contains 'u002-beta') -and ($ranU -contains 'u003-gamma') -and ($ranU -notcontains 'u001-guards')) "rc=$($p.rc) ran=$($ranU -join ',') $($p.text)"
  # CLEAN TWIN: the daily chain's call (no skip file) still runs every unit, and does not call itself selective.
  Remove-Item -LiteralPath $unitsFile -ErrorAction SilentlyContinue
  $fullOut = @(& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $main 'grocery\test-auditors.ps1'))
  $ranU = @(if (Test-Path -LiteralPath $unitsFile) { [IO.File]::ReadAllLines($unitsFile) })
  Case 'CLEAN TWIN' 'the full run (no skip file) still runs every unit' `
    ((($ranU | Sort-Object) -join ',') -eq 'u001-guards,u002-beta,u003-gamma' -and (($fullOut -join "`n") -notmatch 'selective=1')) "ran=$($ranU -join ',') out=$($fullOut -join ' | ')"

  # ---- THE SEVENTH (2026-09-11): seeding a BLIND checkout, once, before the gate ----
  # meal-prep\db\built is gitignored and .worktreeinclude CANNOT carry it - Claude Code's candidate list is
  # built with `git ls-files --directory`, which collapses a fully-ignored directory to ONE line (measured:
  # 1 line against 1,168 files). So a fresh worktree had no built card, feed-covers-published and
  # wave-preaudit could not look, and both FAILED the push after it had queued for a gate worker slot: 18 of
  # 53 failed gate runs on 2026-09-11 failed on nothing else (design\PLAN-gate-queue-2026-09-11.md). Those
  # two now report BLIND; the hook seeds so they can look. A STUB SEEDER, deliberately: these cases pin the
  # hook's WIRING - that it runs, before the gate, handed this checkout, once - and that a checkout without a
  # seeder still pushes. What ops\seed-worktree.ps1 copies is that script's own self-test.
  $seedRanFile = Join-Path $probe 'seed-ran.txt'
  $seedStub = @'
param([string]$Target = '')
$p = $env:TC_PREPUSH_PROBE
[IO.File]::WriteAllText((Join-Path $p 'seed-ran.txt'), ('target=' + $Target + ' gateRanBefore=' + (Test-Path -LiteralPath (Join-Path $p 'gate-saw.txt'))))
$card = Join-Path $Target 'meal-prep\db\built\american-goulash-pasta.body.html'   # reach-fixture-ok: the stub seeder writes the sandbox's own card so the hook's guard can see it
$null = New-Item -ItemType Directory -Force (Split-Path -Parent $card)
[IO.File]::WriteAllText($card, 'seeded')
'@
  $seedPs1 = Join-Path $main 'ops\seed-worktree.ps1'
  $seedCard = Join-Path $main 'meal-prep\db\built\american-goulash-pasta.body.html'   # reach-fixture-ok: the card the HOOK tests for, inside the %TEMP% sandbox repo, never this estate's meal-prep
  [IO.File]::WriteAllText($seedPs1, $seedStub, $utf8)
  Remove-Item -LiteralPath $seedRanFile, $sawFile -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $seedCard -ErrorAction SilentlyContinue
  CommitFile $main 'design\seed-note.md' "seed v1`n"
  $pSeed = PushOut $main 'seed-blind'
  $seedSaw = if (Test-Path -LiteralPath $seedRanFile) { [IO.File]::ReadAllText($seedRanFile) } else { '' }
  # MUST FIRE: a checkout with no built card is seeded, and BEFORE the gate starts - a seed that ran
  # afterwards would leave this push's gates exactly as blind as they were.
  Case 'MUST FIRE' 'a push from a checkout with no built card seeds it BEFORE the gate runs' `
    ($pSeed.rc -eq 0 -and $seedSaw -match 'gateRanBefore=False' -and (Test-Path -LiteralPath $sawFile) -and (Test-Path -LiteralPath $seedCard)) `
    "rc=$($pSeed.rc) seed='$seedSaw' gateRan=$(Test-Path -LiteralPath $sawFile) card=$(Test-Path -LiteralPath $seedCard)"
  # MUST FIRE: and it is handed THIS checkout, not the script's own directory - seed-worktree seeding itself
  # found no db\built and exited 2, which is the trap its own header records.
  Case 'MUST FIRE' 'the seeder is handed the pushing checkout as its target' `
    ($seedSaw -match [regex]::Escape((Split-Path -Leaf $main)) -and $seedSaw -notmatch 'target= ') "seed='$seedSaw'"
  # MUST NOT FIRE: the next push does not seed again. One 47 MB copy per checkout, not one per push.
  Remove-Item -LiteralPath $seedRanFile -ErrorAction SilentlyContinue
  CommitFile $main 'design\seed-note.md' "seed v2`n"
  $pSeed2 = PushOut $main 'seed-blind'
  Case 'MUST NOT FIRE' 'a checkout that already has the card is not seeded again' `
    ($pSeed2.rc -eq 0 -and -not (Test-Path -LiteralPath $seedRanFile)) "rc=$($pSeed2.rc) ranAgain=$(Test-Path -LiteralPath $seedRanFile)"
  # CLEAN TWIN: seeding SUPPLIES, it does not decide. A checkout with no seeder and no card still pushes and
  # is still gated - the gates then report BLIND, which is the honest answer, not a refusal.
  Remove-Item -LiteralPath $seedPs1, $seedCard, $sawFile, $seedRanFile -ErrorAction SilentlyContinue
  CommitFile $main 'design\seed-note.md' "seed v3`n"
  $pSeed3 = PushOut $main 'seed-blind'
  Case 'CLEAN TWIN' 'a checkout with no seeder still pushes, and is still gated' `
    ($pSeed3.rc -eq 0 -and $pSeed3.remote -eq $pSeed3.head -and (Test-Path -LiteralPath $sawFile) -and -not (Test-Path -LiteralPath $seedRanFile)) `
    "rc=$($pSeed3.rc) gateRan=$(Test-Path -LiteralPath $sawFile)"

  # ---- THE EIGHTH (2026-09-11): ONE PUSH AT A TIME (design\PLAN-push-livelock-2026-09-11.md) ----
  # The hook now starts ops\hold-push-lock.ps1 before the gate and holds the machine-wide push lock across it, so a
  # push that passes its gate is not beaten to the ref by one that started later. Everything above this block ran
  # with NO hold-push-lock.ps1 in the sandbox, which is the older-checkout path and is therefore already driven by
  # all 26 cases: the hook must behave exactly as it did before when the script is absent.
  #
  # THE FIXTURE NEVER TOUCHES THE LIVE LOCK. TC_PUSH_LOCK_PREFIX redirects the hold onto a Local\ name of this run's
  # own, which hold-push-lock honours only because it is Local\ - a Global\ value is ignored. Without that, these
  # cases would take the real push lock and hold up every other session on this box for as long as they run, and the
  # contended case below would have wedged a real push behind a fixture.
  . (Join-Path $RepoRoot 'lib\mutex-hold.ps1')
  $holderSrc = Join-Path $RepoRoot 'ops\hold-push-lock.ps1'
  if (Test-Path -LiteralPath $holderSrc) {
    Copy-Item -LiteralPath $holderSrc -Destination (Join-Path $main 'ops\hold-push-lock.ps1')
    $lkPrefix = 'Local\tc-prepush-hook-selftest-' + [guid]::NewGuid().ToString('N') + '-'
    $env:TC_PUSH_LOCK_PREFIX = $lkPrefix
    $env:TC_PUSH_LOCK_QUEUE_ROOT = (Join-Path $sb 'lockq')
    # A SHORT WAIT, honoured only because the prefix above is a private Local\ one. The contended case asserts the
    # BRANCH - unlocked, and the push still goes through - never how long the wait was, and a case that sat out the
    # real 1,200 s would be a wall-clock bar in a hermetic suite. It must also be shorter than lib\mutex-hold.ps1's
    # 300 s cap, or the fixture's own holder expires first and the hook gets the lock after all: that is exactly what
    # happened the first time this block ran, and the case read "held after waiting 299s".
    $env:TC_PUSH_LOCK_WAIT_SEC = '3'
    try {
      $lockFreeFile = Join-Path $probe 'gate-lock-free.txt'
      Remove-Item -LiteralPath $sawFile, $lockFreeFile -ErrorAction SilentlyContinue
      CommitFile $main 'design\lock-note.md' "lock v1`n"
      $pLk = PushOut $main 'pushlock'
      Case 'MUST FIRE' 'a push takes the machine-wide push lock, says so, and still lands' `
        ($pLk.rc -eq 0 -and $pLk.remote -eq $pLk.head -and $pLk.text -match 'push lock - held' -and (Test-Path -LiteralPath $sawFile)) `
        "rc=$($pLk.rc) gateRan=$(Test-Path -LiteralPath $sawFile) text=$($pLk.text)"
      # THE CASE THAT CAN SEE AN EARLY RELEASE, and the only one that can. The gate stub asked, from inside the hook
      # while the gate was running, whether the push lock was takeable. If it was, the hook said "held" and was not
      # holding anything - which is exactly what the first version of this change did, passing every other case.
      # THE SENSE OF THIS CASE WAS DELIBERATELY REVERSED (2026-09-12). It asserted the lock was HELD while the gate
      # ran, which was the point when the lock was taken at the top of the hook. It is now taken AFTER every check
      # passes, so the gate runs UNLOCKED and the lock covers the ref update only - because a session waiting out
      # every other session's checks was the estate's worst queue: 9 pushes deep, oldest at 13 minutes, one of them
      # waiting 957s for a lock it could not use. The probe reads, from inside the hook while the gate runs,
      # whether the lock is takeable; a 1 now means the design is working, and a 0 means the lock has crept back
      # across the checks.
      $lockFreeDuring = if (Test-Path -LiteralPath $lockFreeFile) { [IO.File]::ReadAllText($lockFreeFile).Trim() } else { 'the gate never reported' }
      Case 'MUST FIRE' 'the gate runs UNLOCKED - the lock is taken after the checks, so nobody queues behind another push''s gate' `
        ($lockFreeDuring -eq '1') "lockWasFreeDuringGate=$lockFreeDuring"
      # MUST NOT FIRE: the holder is a process, and a leaked one would hold up every push on the box. The hook's trap
      # writes the release file on every exit path, so no holder may outlive the push that started it.
      $stillHeld = Start-TcMutexHold -Name ($lkPrefix + '0')
      Case 'MUST NOT FIRE' 'the holder that push started did not outlive it - the lock is free again straight after' `
        ($null -ne $stillHeld -and $stillHeld.Held) "held=$(if ($stillHeld) { $stillHeld.Held } else { 'no hold' })"
      # MUST FIRE, and it is the whole degrade rule: with the lock held by somebody else the hook must say UNLOCKED
      # in words and PUSH ANYWAY. A fairness device that could refuse a push would be worse than the livelock.
      Remove-Item -LiteralPath $sawFile -ErrorAction SilentlyContinue
      CommitFile $main 'design\lock-note.md' "lock v2`n"
      $pBusy = PushOut $main 'pushlock'
      Case 'MUST FIRE' 'with the push lock held by another push, the hook says unlocked, gates anyway, and still lets the push through' `
        ($pBusy.rc -eq 0 -and $pBusy.remote -eq $pBusy.head -and $pBusy.text -match 'push lock - unlocked' -and (Test-Path -LiteralPath $sawFile)) `
        "rc=$($pBusy.rc) gateRan=$(Test-Path -LiteralPath $sawFile) text=$($pBusy.text)"
      Stop-TcMutexHold $stillHeld
      # CLEAN TWIN: the lock decides nothing about the tree. A red gate under a HELD lock is refused exactly as before.
      Remove-Item -LiteralPath $sawFile -ErrorAction SilentlyContinue
      $env:TC_PREPUSH_PROBE_EXIT = '1'
      CommitFile $main 'design\lock-note.md' "lock v3`n"
      $pRed = PushOut $main 'pushlock'
      $env:TC_PREPUSH_PROBE_EXIT = '0'
      # STRONGER SINCE THE LOCK MOVED (2026-09-12): a red gate is refused AND never takes the lock at all, because
      # the lock is taken only once every check has passed. A failing push no longer occupies the queue for the
      # length of its own gate, which is the other half of what made the queue 13 minutes deep.
      Case 'CLEAN TWIN' 'a red gate refuses the push and never takes the push lock - a failing push costs the queue nothing' `
        ($pRed.rc -ne 0 -and $pRed.text -notmatch 'push lock - held' -and $pRed.text -match 'BLOCKED') `
        "rc=$($pRed.rc) text=$($pRed.text)"
      # MUST NOT FIRE: a refused push releases the lock too, or one red gate would wedge the box.
      $afterRed = Start-TcMutexHold -Name ($lkPrefix + '0')
      Case 'MUST NOT FIRE' 'a REFUSED push hands the push lock back as well, so one red gate cannot wedge the box' `
        ($null -ne $afterRed -and $afterRed.Held) "held=$(if ($afterRed) { $afterRed.Held } else { 'no hold' })"
      Stop-TcMutexHold $afterRed
      # MUST FIRE - THE CHECKOUT THAT HAS NOT REBASED STILL QUEUES (2026-09-12). The holder was resolved from the
      # PUSHING checkout, so the lock reached only worktrees that had rebased since it shipped, and a fairness device
      # that reaches half the queue is worse than none: the sessions that updated waited while the ones that did not
      # went straight past them to the ref. MEASURED that morning: 30 of 132 worktrees carried the script, 9 pushes sat
      # on the lock with the oldest at 13 minutes, and the other 102 were landing past them. The sandbox has the holder
      # in $main only - the linked worktree shares its commits and not its untracked files - which is exactly the
      # older-checkout shape. The push from it is NOT asserted to land: this sandbox's linked checkout has no board, so
      # the test-auditors check refuses it for a reason that has nothing to do with the lock. What is asserted is that
      # it took the lock rather than jumping the queue.
      Remove-Item -LiteralPath $sawFile -ErrorAction SilentlyContinue
      # THE LOCK IS TAKEN ONLY AFTER EVERY CHECK PASSES, so this push must actually pass them: the linked checkout
      # needs a board, or the test-auditors check refuses it as could-not-evaluate and the push never reaches the
      # lock at all - which would make this case pass or fail for a reason that has nothing to do with the holder.
      CommitFile $linked 'grocery\out\comparison-2026-01-01.json' "{`"comparison`":[]}`n"   # reach-fixture-ok: a stub board inside the %TEMP% sandbox repo
      CommitFile $linked 'design\lock-note-wt.md' "lock from a linked worktree`n"
      $pWt = PushOut $linked 'pushlock-wt'
      Case 'MUST FIRE' 'a push from a checkout with no holder of its own uses the MAIN checkout''s and still queues' `
        ($pWt.text -match 'using the main checkout' -and $pWt.text -match 'push lock - held') `
        "text=$($pWt.text)"
    } finally {
      Remove-Item -LiteralPath Env:TC_PUSH_LOCK_PREFIX -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath Env:TC_PUSH_LOCK_QUEUE_ROOT -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath Env:TC_PUSH_LOCK_WAIT_SEC -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath (Join-Path $main 'ops\hold-push-lock.ps1') -ErrorAction SilentlyContinue
    }
  } else {
    Case 'MUST FIRE' 'ops\hold-push-lock.ps1 exists to be driven' $false 'the push-lock cases could not run'
  }

  # ---- THE SIXTH (2026-09-11): the check's OWN clear, and a library it cannot load ----
  # The sandbox's hand list of libraries predated lib\git-repo-env.ps1, so every copy of the check driven above loaded
  # no clear and all 26 cases passed; the hook sends the check's stderr to /dev/null, so on that path it said nothing.
  # Nothing here could have written the REAL .git: the hook unsets the variables before starting the check, and this
  # file clears its own before the -Record calls. What was lost was the third layer's only fixture, which no case ever
  # handed a GIT_DIR. These cases run the check the way a caller that is NOT the hook does.
  $env:TC_PREPUSH_TA_FAILS = ''; $env:TC_PREPUSH_TA_FAILS_BETA = ''
  $checkPs1 = Join-Path $main 'ops\prepush-test-auditors.ps1'
  $taSawFile = Join-Path $probe 'ta-saw.txt'
  $pathsIn = Join-Path $sb 'paths-guard.txt'
  [IO.File]::WriteAllText($pathsIn, "grocery/guards.ps1`n", $utf8)
  # The leaked GIT_DIR names the SANDBOX's linked worktree, so a check that failed to clear it reaches only the sandbox.
  $leak = Join-Path $main '.git\worktrees\linked'
  Remove-Item -LiteralPath $taSawFile -ErrorAction SilentlyContinue
  $env:GIT_DIR = $leak
  try {
    $leakSeen = (@(& powershell -NoProfile -Command '[string]$env:GIT_DIR') -join '').Trim()
    $leakOut = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $checkPs1 -PathsFile $pathsIn 2>$null)
    $leakRc = $LASTEXITCODE
  } finally { Remove-Item -LiteralPath 'Env:\GIT_DIR' -ErrorAction SilentlyContinue }
  $taSaw = if (Test-Path -LiteralPath $taSawFile) { [IO.File]::ReadAllText($taSawFile) } else { '' }
  # CLEAN TWIN: the leak was real (a child started from that environment inherits it) and the check still ran its suite.
  # Without it the case below passes on a check that never started test-auditors.
  Case 'CLEAN TWIN' 'a caller leaking GIT_DIR hands it to its children, and the check still runs test-auditors' `
    ([string]::Equals($leakSeen, $leak, [StringComparison]::OrdinalIgnoreCase) -and $taSaw -ne '' -and $leakRc -eq 0) "child=$leakSeen saw=$taSaw rc=$leakRc $($leakOut -join ' | ')"
  # MUST FIRE: the check's own clear ran, so the test-auditors it started inherited no GIT_DIR.
  Case 'MUST FIRE' 'the check started by a caller that is not the hook hands test-auditors no GIT_DIR' ($taSaw -eq 'GIT_DIR=') $taSaw

  # -ListInputs is the probe for a library the check cannot load, because it exits 0 with every library present. A bare
  # "exit 3" would not do: calling the check with no mode is also a 3.
  $envLibCopy = Join-Path $main 'lib\git-repo-env.ps1'
  $envLibAside = Join-Path $sb 'git-repo-env.ps1.aside'
  $liOk = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $checkPs1 -ListInputs 2>$null); $liOkRc = $LASTEXITCODE
  Case 'CLEAN TWIN' 'with every library present the check lists its inputs and exits 0' `
    ($liOkRc -eq 0 -and ($liOk -join "`n") -match '(?m)^PREPUSH-TEST-AUDITORS-COMPLETE tracked=') "rc=$liOkRc $($liOk -join ' | ')"
  # MUST FIRE, THE FOUNDING DEFECT: the library is missing, exactly the sandbox of 2026-09-11.
  Move-Item -LiteralPath $envLibCopy -Destination $envLibAside
  try { $liGone = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $checkPs1 -ListInputs 2>$null); $liGoneRc = $LASTEXITCODE }
  finally { Move-Item -LiteralPath $envLibAside -Destination $envLibCopy }
  Case 'MUST FIRE' 'a check whose lib\git-repo-env.ps1 is missing refuses as could-not-evaluate, not print and pass' `
    ($liGoneRc -eq 3 -and ($liGone -join "`n") -match 'COULD NOT EVALUATE - lib\\git-repo-env\.ps1 did not load') "rc=$liGoneRc $($liGone -join ' | ')"
  # MUST FIRE: a library that writes an error while it loads and then carries on. try/catch alone cannot see a
  # non-terminating error, so this is the case that pins the check's 'Stop' around its loads.
  $envLibBytes = [IO.File]::ReadAllBytes($envLibCopy)
  [IO.File]::WriteAllText($envLibCopy, ("Write-Error 'half-loaded library'`n" + [IO.File]::ReadAllText($envLibCopy)), $utf8)
  try { $liHalf = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $checkPs1 -ListInputs 2>$null); $liHalfRc = $LASTEXITCODE }
  finally { [IO.File]::WriteAllBytes($envLibCopy, $envLibBytes) }
  Case 'MUST FIRE' 'a library that errors while loading is refused too, not printed past' `
    ($liHalfRc -eq 3 -and ($liHalf -join "`n") -match 'lib\\git-repo-env\.ps1 did not load \(half-loaded library\)') "rc=$liHalfRc $($liHalf -join ' | ')"

  # ---- THE CHAIN REHEARSAL CLAUSE (2026-09-22, RCA F2, plan-2026-09-22-7), through the REAL hook from the linked worktree.
  # The sandbox gets ops\rehearse-chain.ps1 only HERE, after every case above, because once it and the manifest are in the
  # tree a push touching grocery\guards.ps1 needs a verdict. Verdicts and the bypass log go to a sandbox directory.
  $env:TC_REHEARSAL_VERDICT_DIR = Join-Path $sb 'rh-verdicts'
  $env:TC_PREPUSH_PROBE_EXIT = '0'
  $env:TC_PREPUSH_TA_FAILS = ''; $env:TC_PREPUSH_TA_FAILS_BETA = ''
  $null = G -C $linked reset -q --hard
  $null = G -C $linked fetch -q origin
  $null = G -C $linked checkout -q --detach origin/main
  Copy-Item -LiteralPath (Join-Path $RepoRoot 'ops\rehearse-chain.ps1') -Destination (Join-Path $linked 'ops\rehearse-chain.ps1')
  $rhFiles = @('grocery/guards.ps1', 'ops/chain-manifest.json', 'ops/rehearse-chain.ps1')
  [IO.File]::WriteAllText((Join-Path $linked 'ops\chain-manifest.json'), ('{"schema":1,"max_data_age_days":2,"files":["' + ($rhFiles -join '","') + '"],"globs":[],"derive_from":[],"derive_dirs":[]}'), $utf8)
  $null = G -C $linked add -- 'ops/rehearse-chain.ps1' 'ops/chain-manifest.json'
  $null = G -C $linked commit -q -m 'install the rehearsal harness'
  $env:TC_NO_REHEARSAL = 'fixture: installing the harness'
  $rhSetup = PushOut $linked 'main'
  Remove-Item -LiteralPath 'Env:\TC_NO_REHEARSAL' -ErrorAction SilentlyContinue
  Case 'CLEAN TWIN' 'TC_NO_REHEARSAL lets a chain-touching push to main through, and says so loudly' `
    ($rhSetup.rc -eq 0 -and $rhSetup.remote -eq $rhSetup.head -and $rhSetup.text -match 'REHEARSAL BYPASSED') "rc=$($rhSetup.rc) $($rhSetup.text)"
  # ---- W1.1 (2026-09-23): the record is asked for BEFORE run-gates, and a refusal there starts neither leg ----
  # The rehearsal-free setup push above ran the gate, so the stub recorded where the hook put its refs file: the refs
  # case below watches THAT directory, and cannot pass by watching one the hook never writes into.
  $refsPathFile = Join-Path $probe 'gate-refs-path.txt'
  $refsPathSeen = if (Test-Path -LiteralPath $refsPathFile) { ([IO.File]::ReadAllText($refsPathFile)).Trim() } else { '' }
  $refsInSandbox = [bool]$refsPathSeen -and $refsPathSeen.StartsWith($sb, [StringComparison]::OrdinalIgnoreCase)
  $refsBefore = @(Get-ChildItem -LiteralPath $sb -Filter 'tc-prepush-refs-*' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
  CommitFile $linked 'grocery\guards.ps1' "# guard rehearsed`n"
  Remove-Item -LiteralPath $sawFile, $ranFile -ErrorAction SilentlyContinue
  $rhNo = PushOut $linked 'main'
  $rhNoGateRan = Test-Path -LiteralPath $sawFile
  $rhNoTaRan = Test-Path -LiteralPath $ranFile
  $refsLeft = @(Get-ChildItem -LiteralPath $sb -Filter 'tc-prepush-refs-*' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Name } | Where-Object { $refsBefore -notcontains $_ })
  Case 'MUST FIRE' 'a push to main changing a chain script with no rehearsal verdict is refused' `
    ($rhNo.rc -ne 0 -and $rhNo.remote -ne $rhNo.head -and $rhNo.text -match 'no rehearsal verdict is recorded') "rc=$($rhNo.rc) $($rhNo.text)"
  # MUST FIRE, THE FOUNDING WASTE: the check sat after test-auditors, so this refusal came only after run-gates and a
  # full test-auditors run. Both stubs write a marker when they start; neither may exist after this refusal.
  Case 'MUST FIRE' 'that refusal comes before the hook starts run-gates or test-auditors' `
    ($rhNo.rc -ne 0 -and -not $rhNoGateRan -and -not $rhNoTaRan) "rc=$($rhNo.rc) gateRan=$rhNoGateRan taRan=$rhNoTaRan"
  Case 'MUST FIRE' 'that refusal prints PRE-PUSH-REFUSED cause=rehearsal' `
    ($rhNo.text -match '(?m)^PRE-PUSH-REFUSED cause=rehearsal\s*$') "text=[$($rhNo.text)]"
  # MUST FIRE: the new early exit removes the hook's refs file, as every other early exit does.
  Case 'MUST FIRE' 'after that refusal no tc-prepush-refs file from this hook run is left in the temp directory' `
    ($rhNo.rc -ne 0 -and $refsInSandbox -and $refsLeft.Count -eq 0) "refsPath=[$refsPathSeen] inSandbox=$refsInSandbox left=[$($refsLeft -join ',')]"
  # MUST FIRE (W0.6): that refusal wrote exactly ONE hook-refused row, saying what was refused and by which hook. It is a
  # plain push, so under_push_main is false (the suite cleared any inherited push-main token), and hook_blob is the blob
  # of the hook the sandbox installed.
  $rhRowsRaw = Get-SuiteRefusalRows -Dir $suiteLedger
  $rhRows = @(@($rhRowsRaw) | Where-Object { [string]$_.local_sha -eq $rhNo.head -and [string]$_.remote_ref -eq 'refs/heads/main' })
  $rhRow = $(if ($rhRows.Count -eq 1) { $rhRows[0] } else { $null })
  Case 'MUST FIRE' 'a chain push with no verdict writes one hook-refused row with cause=rehearsal' `
    ($null -ne $rhRow -and $rhRow.cause -eq 'rehearsal' -and $rhRow.rc -eq 1 -and $null -eq $rhRow.gate -and [bool]$rhRow.log `
      -and [string]::Equals([string]$rhRow.checkout, $linked, [StringComparison]::OrdinalIgnoreCase) -and $rhRow.remote -eq 'origin' `
      -and $rhRow.under_push_main -eq $false -and $rhRow.hook_blob -eq $installedHookBlob -and $rhRow.ref_lines -eq 1) `
    ("rows=" + $rhRows.Count + " installedHookBlob=" + $installedHookBlob + " row=[" + $(if ($rhRow) { ConvertTo-Json $rhRow -Compress } else { '' }) + "]")
  # THE BASELINE FOR THE MUST NOT FIRE BELOW: every hook-refused row so far. The three passing pushes that follow may add none.
  $refusedBeforePassRaw = Get-SuiteRefusalRows -Dir $suiteLedger
  $refusedBeforePass = @($refusedBeforePassRaw).Count
  # CLEAN TWIN: with a passing verdict recorded for exactly this content, the same push runs BOTH legs and lands. The
  # verdict is written where the hook's check reads it (TC_REHEARSAL_VERDICT_DIR), keyed as rehearse-chain keys it.
  $rhKey = Get-SandboxRehearsalKey -Dir $linked -Rev 'HEAD' -Files $rhFiles
  $rhK12Printed = [regex]::Match($rhNo.text, 'key ([0-9a-f]{12})\)').Groups[1].Value
  $rhVd = [string]$env:TC_REHEARSAL_VERDICT_DIR
  $null = New-Item -ItemType Directory -Force $rhVd
  [IO.File]::WriteAllText((Join-Path $rhVd ($rhKey + '.json')), ('{"result":"pass","blind":"","key":"' + $rhKey + '","stage":"","cause":"fixture pass","words":[],"data_date":"' + (Get-Date).ToString('yyyy-MM-dd') + '","preexisting":[]}'), $utf8)
  Remove-Item -LiteralPath $sawFile, $ranFile -ErrorAction SilentlyContinue
  $rhYes = PushOut $linked 'main'
  Case 'CLEAN TWIN' 'a chain push with a recorded passing verdict still runs run-gates and test-auditors and lands' `
    ($rhYes.rc -eq 0 -and $rhYes.remote -eq $rhYes.head -and (Test-Path -LiteralPath $sawFile) -and (Test-Path -LiteralPath $ranFile) -and $rhYes.text -match 'chain-rehearsal: PASSED') `
    "rc=$($rhYes.rc) gateRan=$(Test-Path -LiteralPath $sawFile) taRan=$(Test-Path -LiteralPath $ranFile) key=$($rhKey.Substring(0, 12)) refusalNamed=$rhK12Printed text=[$($rhYes.text)]"

  CommitFile $linked 'design\note.md' "rehearsal-free doc`n"
  $rhDoc = PushOut $linked 'main'
  Case 'MUST NOT FIRE' 'a push to main touching no chain script is not asked for a rehearsal' `
    ($rhDoc.rc -eq 0 -and $rhDoc.remote -eq $rhDoc.head -and $rhDoc.text -match 'no rehearsal needed') "rc=$($rhDoc.rc) $($rhDoc.text)"
  # MUST NOT FIRE (W1.1): a push to main that touches a test-auditors input and no chain script is not refused for a
  # rehearsal, and runs run-gates and test-auditors exactly as before the reorder.
  CommitFile $linked 'grocery\shared-rules.json' "{`"v`":9}`n"
  Remove-Item -LiteralPath $sawFile, $ranFile -ErrorAction SilentlyContinue
  $rhTa = PushOut $linked 'main'
  Case 'MUST NOT FIRE' 'a push to main touching no chain script runs run-gates and test-auditors as before and lands' `
    ($rhTa.rc -eq 0 -and $rhTa.remote -eq $rhTa.head -and $rhTa.text -match 'no rehearsal needed' -and (Test-Path -LiteralPath $sawFile) -and (Test-Path -LiteralPath $ranFile)) `
    "rc=$($rhTa.rc) gateRan=$(Test-Path -LiteralPath $sawFile) taRan=$(Test-Path -LiteralPath $ranFile) text=[$($rhTa.text)]"
  # MUST NOT FIRE (W0.6): the three pushes that PASSED above (a recorded verdict, a doc, a test-auditors input) wrote no
  # hook-refused row. Counted against the rows present before them, and read only when all three landed, so the case
  # cannot pass because a push was refused somewhere the writer never ran.
  $refusedAfterPassRaw = Get-SuiteRefusalRows -Dir $suiteLedger
  $refusedAfterPass = @($refusedAfterPassRaw).Count
  Case 'MUST NOT FIRE' 'a passing push writes no hook-refused row' `
    ($rhYes.rc -eq 0 -and $rhDoc.rc -eq 0 -and $rhTa.rc -eq 0 -and $refusedBeforePass -ge 1 -and $refusedAfterPass -eq $refusedBeforePass) `
    ("rc=" + $rhYes.rc + "," + $rhDoc.rc + "," + $rhTa.rc + " refusedRowsBefore=" + $refusedBeforePass + " after=" + $refusedAfterPass)
  # ---- THE TWELFTH (2026-09-23, W8.3 as amended in 16.4): a chain push that is not the queue's head is refused ----
  # Tickets are held by the REAL lib\chain-queue.ps1 (copied into the sandbox with every other library) from ANOTHER
  # PROCESS, on a private Local\ prefix and a per-run root, and TC_CHAIN_QUEUE_SELFTEST is set throughout, so a case that
  # forgot the seam reaches the production queue only to have the library refuse it. Each chain push commits new
  # guards.ps1 content and records a passing verdict for exactly that content, so the rehearsal check lets it through
  # and the queue probe is what decides.
  $cqPrefix = 'Local\tc-prepush-cq-' + [guid]::NewGuid().ToString('N').Substring(0, 12) + '-'
  $cqRoot = Join-Path $sb 'cq'
  $cqLib = Join-Path $linked 'lib\chain-queue.ps1'
  $cqHolderPs1 = Join-Path $sb 'cq-holder.ps1'
  $cqHolderText = @'
param([string]$Lib, [string]$Prefix, [string]$Root, [string]$Checkout, [string]$Base, [string]$Out)
$ErrorActionPreference = 'Stop'
try {
  . $Lib
  $m = Join-TcChainQueue -Checkout $Checkout -Base $Base -Range @($Base) -Mode live -Prefix $Prefix -QueueRoot $Root
  [IO.File]::WriteAllText(($Out + '.token'), ([string]$m.Queue + "`n" + [string]$m.Token + "`n" + [string]$PID))
  $until = [datetime]::UtcNow.AddSeconds(300)
  while (-not (Test-Path -LiteralPath ($Out + '.release')) -and [datetime]::UtcNow -lt $until) { Start-Sleep -Milliseconds 200 }
  Exit-TcChainQueue -Member $m -State left
  [IO.File]::WriteAllText(($Out + '.done'), 'left')
} catch { [IO.File]::WriteAllText(($Out + '.token'), ('error' + "`n" + $_.Exception.Message + "`n" + [string]$PID)) }
'@
  [IO.File]::WriteAllText($cqHolderPs1, $cqHolderText, $utf8)
  function Start-CqHolder {
    <# One ticket held by another powershell.exe until Stop-CqHolder. Returns Queue, Token, Pid and the process. #>
    param([string]$Tag)
    $out = Join-Path $sb ('cq-' + $Tag)
    $base = GOut -C $linked rev-parse origin/main
    $pr = Start-Process -FilePath 'powershell' -NoNewWindow -PassThru -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $cqHolderPs1,
      '-Lib', $cqLib, '-Prefix', $cqPrefix, '-Root', $cqRoot, '-Checkout', $linked, '-Base', $base, '-Out', $out)
    $until = [datetime]::UtcNow.AddSeconds(90)
    while (-not (Test-Path -LiteralPath ($out + '.token')) -and [datetime]::UtcNow -lt $until -and -not $pr.HasExited) { Start-Sleep -Milliseconds 200 }
    $lines = if (Test-Path -LiteralPath ($out + '.token')) { @([IO.File]::ReadAllLines($out + '.token')) } else { @('no-token', '', '') }
    return [pscustomobject]@{ Queue = [string]$lines[0]; Token = [string]$lines[1]; HolderPid = [string]$lines[2]; Out = $out; Process = $pr }
  }
  function Stop-CqHolder {
    param($H)
    if ($null -eq $H) { return }
    [IO.File]::WriteAllText(($H.Out + '.release'), 'go')
    $null = $H.Process.WaitForExit(60000)
  }
  function New-CqChainCommit {
    # New guards.ps1 content, and a passing verdict recorded for exactly that content, keyed as rehearse-chain keys it.
    param([string]$Text)
    CommitFile $linked 'grocery\guards.ps1' $Text
    $k = Get-SandboxRehearsalKey -Dir $linked -Rev 'HEAD' -Files $rhFiles
    [IO.File]::WriteAllText((Join-Path $rhVd ($k + '.json')), ('{"result":"pass","blind":"","key":"' + $k + '","stage":"","cause":"fixture pass","words":[],"data_date":"' + (Get-Date).ToString('yyyy-MM-dd') + '","preexisting":[]}'), $utf8)
  }
  $cqSelfTestHad = Test-Path -LiteralPath 'Env:\TC_CHAIN_QUEUE_SELFTEST'
  $cqSelfTestWas = [string]$env:TC_CHAIN_QUEUE_SELFTEST
  $cqTokHad = Test-Path -LiteralPath 'Env:\TC_CHAIN_QUEUE_HOLDER'
  $cqTokWas = [string]$env:TC_CHAIN_QUEUE_HOLDER
  $cqA = $null; $cqB = $null
  try {
    $env:TC_CHAIN_QUEUE_SELFTEST = '1'
    $env:TC_CHAIN_QUEUE_PREFIX = $cqPrefix
    $env:TC_CHAIN_QUEUE_ROOT = $cqRoot
    Remove-Item -LiteralPath 'Env:\TC_CHAIN_QUEUE_HOLDER' -ErrorAction SilentlyContinue
    $cqA = Start-CqHolder 'a'
    $cqAJoined = ($cqA.Queue -eq 'joined' -and [bool]$cqA.Token)

    # MUST FIRE: a plain chain push, rehearsed and recorded, while a ticket is held by another process: refused in the
    # probe, before run-gates, with the fixed line, naming the head's pid.
    New-CqChainCommit "# guard queued 1`n"
    Remove-Item -LiteralPath $sawFile, $ranFile -ErrorAction SilentlyContinue
    $cqNo = PushOut $linked 'main'
    $cqNoGate = Test-Path -LiteralPath $sawFile
    Case 'MUST FIRE' 'a chain push that joined no queue is refused while a ticket is held, before run-gates, naming the head' `
      ($cqAJoined -and $cqNo.rc -ne 0 -and $cqNo.remote -ne $cqNo.head -and -not $cqNoGate -and $cqNo.text -match ('head pid ' + $cqA.HolderPid + ',') `
        -and $cqNo.text -match '(?m)^PRE-PUSH-REFUSED cause=chain-queue\s*$') ("joined=" + $cqAJoined + " holder=[" + $cqA.Queue + "] rc=" + $cqNo.rc + " gateRan=" + $cqNoGate + " text=[" + $cqNo.text + "]")
    # MUST FIRE (W0.6): that refusal wrote one hook-refused row with cause=chain-queue.
    $cqRowsRaw = Get-SuiteRefusalRows -Dir $suiteLedger
    $cqRows = @(@($cqRowsRaw) | Where-Object { [string]$_.local_sha -eq $cqNo.head -and [string]$_.cause -eq 'chain-queue' })
    Case 'MUST FIRE' 'that refusal writes one hook-refused row with cause=chain-queue' ($cqRows.Count -eq 1) ("rows=" + $cqRows.Count)

    # MUST NOT FIRE: a non-chain push lands while the ticket is held (the probe is asked only of a chain push).
    $null = G -C $linked reset -q --hard origin/main
    CommitFile $linked 'design\note.md' "queue-free doc`n"
    $cqDoc = PushOut $linked 'main'
    Case 'MUST NOT FIRE' 'a push touching no chain script lands while a queue ticket is held' `
      ($cqAJoined -and $cqDoc.rc -eq 0 -and $cqDoc.remote -eq $cqDoc.head -and $cqDoc.text -notmatch 'chain queue') ("rc=" + $cqDoc.rc + " text=[" + $cqDoc.text + "]")

    # MUST NOT FIRE: the push-main child of the HEAD member (its TC_CHAIN_QUEUE_HOLDER names ticket A) proceeds and lands.
    New-CqChainCommit "# guard queued 2`n"
    $env:TC_CHAIN_QUEUE_HOLDER = $cqA.Token
    $cqHead = PushOut $linked 'main'
    Remove-Item -LiteralPath 'Env:\TC_CHAIN_QUEUE_HOLDER' -ErrorAction SilentlyContinue
    Case 'MUST NOT FIRE' 'the queue head''s own push (its holder token names the head ticket) proceeds and lands' `
      ($cqAJoined -and $cqHead.rc -eq 0 -and $cqHead.remote -eq $cqHead.head -and $cqHead.text -match 'this push is the queue''s head') ("rc=" + $cqHead.rc + " text=[" + $cqHead.text + "]")

    # THE WEDGE BAR: a head whose record has not moved for longer than the library's own stall bound
    # ($script:TcChainQueueStallSec, read from the sandbox's copy) is wedged, and the queue's timed-out waiters push
    # unqueued, so the hook must not refuse them. The age is a moving clock, so the two cases sit 120 s either side of
    # the bar rather than on it: the record is rewritten to that age just before each push, and a push takes seconds.
    $cqStall = 0
    $cqStallText = [regex]::Match([IO.File]::ReadAllText($cqLib), '(?m)^\$script:TcChainQueueStallSec = (\d+)').Groups[1].Value
    if ($cqStallText) { $cqStall = [int]$cqStallText }
    $cqATicket = [string](@($cqA.Token -split '\|') + @('', ''))[1]
    $cqARecs = @(Get-ChildItem -LiteralPath $cqRoot -Recurse -File -Filter ($cqATicket + '.json') -ErrorAction SilentlyContinue)
    $cqARec = if ($cqARecs.Count -eq 1) { $cqARecs[0].FullName } else { '' }
    function Set-CqRecordAge {
      param([string]$Path, [int]$AgeSec)
      if (-not $Path) { return }
      $j = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
      $j.updated_utc = [datetime]::UtcNow.AddSeconds(-$AgeSec).ToString('o')
      [IO.File]::WriteAllText($Path, ($j | ConvertTo-Json -Depth 5 -Compress), $utf8)
    }
    New-CqChainCommit "# guard queued 2b`n"
    Set-CqRecordAge $cqARec ($cqStall - 120)
    $cqUnder = PushOut $linked 'main'
    Case 'MUST FIRE' ('a head whose record moved ' + ($cqStall - 120) + ' s ago, under the ' + $cqStall + ' s stall bound, still refuses a plain chain push') `
      ($cqStall -gt 240 -and [bool]$cqARec -and $cqUnder.rc -ne 0 -and $cqUnder.remote -ne $cqUnder.head -and $cqUnder.text -match '(?m)^PRE-PUSH-REFUSED cause=chain-queue\s*$') `
      ("stall=" + $cqStall + " record=[" + $cqARec + "] rc=" + $cqUnder.rc + " text=[" + $cqUnder.text + "]")
    Set-CqRecordAge $cqARec ($cqStall + 120)
    $cqPast = PushOut $linked 'main'
    Set-CqRecordAge $cqARec 0
    Case 'MUST NOT FIRE' ('a head whose record moved ' + ($cqStall + 120) + ' s ago, past the ' + $cqStall + ' s stall bound, is wedged: the push proceeds and says so') `
      ($cqStall -gt 240 -and $cqPast.rc -eq 0 -and $cqPast.remote -eq $cqPast.head -and $cqPast.text -match 'the queue is wedged and this push proceeds') ("rc=" + $cqPast.rc + " text=[" + $cqPast.text + "]")

    # MUST FIRE: a member that is NOT the head (ticket B, behind A) is refused, and says it must wait its turn.
    $cqB = Start-CqHolder 'b'
    $cqBJoined = ($cqB.Queue -eq 'joined' -and [bool]$cqB.Token)
    New-CqChainCommit "# guard queued 3`n"
    $env:TC_CHAIN_QUEUE_HOLDER = $cqB.Token
    $cqBehind = PushOut $linked 'main'
    Remove-Item -LiteralPath 'Env:\TC_CHAIN_QUEUE_HOLDER' -ErrorAction SilentlyContinue
    Case 'MUST FIRE' 'a queue member that is not the head is refused, naming the head and saying it must wait' `
      ($cqBJoined -and $cqBehind.rc -ne 0 -and $cqBehind.remote -ne $cqBehind.head -and $cqBehind.text -match ('head pid ' + $cqA.HolderPid + ',') `
        -and $cqBehind.text -match 'holds a queue ticket but is not the head') ("joinedB=" + $cqBJoined + " rc=" + $cqBehind.rc + " text=[" + $cqBehind.text + "]")
    Stop-CqHolder $cqB; $cqB = $null
    Stop-CqHolder $cqA; $cqA = $null

    # MUST NOT FIRE: with every ticket released the same chain push lands, with the WARN line naming push-main.
    $cqFree = PushOut $linked 'main'
    Case 'MUST NOT FIRE' 'with the queue free a plain chain push lands and prints the WARN naming push-main' `
      ($cqFree.rc -eq 0 -and $cqFree.remote -eq $cqFree.head -and $cqFree.text -match 'WARN - this push changes the daily chain') ("rc=" + $cqFree.rc + " text=[" + $cqFree.text + "]")

    # CLEAN TWIN: a probe that throws (a prefix the hook refuses to honour) proceeds as before, saying so, and lands.
    New-CqChainCommit "# guard queued 4`n"
    $env:TC_CHAIN_QUEUE_PREFIX = 'Global\tc-prepush-cq-not-honoured-'
    $cqThrow = PushOut $linked 'main'
    $env:TC_CHAIN_QUEUE_PREFIX = $cqPrefix
    Case 'CLEAN TWIN' 'a queue probe that throws lets the chain push through as before, saying the queue could not be read' `
      ($cqThrow.rc -eq 0 -and $cqThrow.remote -eq $cqThrow.head -and $cqThrow.text -match 'the chain queue could not be read' -and $cqThrow.text -match 'WARN - this push changes the daily chain') ("rc=" + $cqThrow.rc + " text=[" + $cqThrow.text + "]")

    # MUST FIRE, STATIC: the probe sits after the rehearsal record check and before run-gates, and acquires nothing: no
    # join, no wait and no lock take appears in the hook. Needles by concatenation, so this file is not its own match.
    $hookNow = [IO.File]::ReadAllText($hookSrc).Replace("`r`n", "`n")
    $iRhC = $hookNow.IndexOf('powershell -NoProfile' + ' -ExecutionPolicy Bypass -File "$rh"')
    $iCq = $hookNow.IndexOf('Get-TcChain' + 'QueueLive')
    $iRunC = $hookNow.IndexOf('powershell -NoProfile' + ' -ExecutionPolicy Bypass -File "$gate"')
    $takes = @(('Join-TcChain' + 'Queue'), ('Wait-TcChain' + 'QueueHead'), ('Enter-Tc' + 'PushLock'), ('Enter-Tc' + 'GateSlots'), ('.Wait' + 'One(')) | Where-Object { $hookNow.Contains($_) }
    Case 'MUST FIRE' 'the queue probe runs after the rehearsal record check and before run-gates, and takes nothing' `
      ($iRhC -ge 0 -and $iCq -gt $iRhC -and $iRunC -gt $iCq -and @($takes).Count -eq 0) ("rh@" + $iRhC + " cq@" + $iCq + " run@" + $iRunC + " takes=[" + (@($takes) -join ',') + "]")
  } finally {
    Stop-CqHolder $cqB
    Stop-CqHolder $cqA
    # Back to the suite-wide private empty queue, never to none: a case after this block must not read production.
    $env:TC_CHAIN_QUEUE_PREFIX = $cqSuitePrefix
    $env:TC_CHAIN_QUEUE_ROOT = $cqSuiteRoot
    if ($cqSelfTestHad) { $env:TC_CHAIN_QUEUE_SELFTEST = $cqSelfTestWas } else { Remove-Item -LiteralPath 'Env:\TC_CHAIN_QUEUE_SELFTEST' -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath 'Env:\TC_CHAIN_QUEUE_HOLDER' -ErrorAction SilentlyContinue
  }
  Remove-Item -LiteralPath 'Env:\TC_REHEARSAL_VERDICT_DIR' -ErrorAction SilentlyContinue
  # MUST FIRE, STATIC: run-gates clears the same environment for EVERY caller, not only this hook - a session
  # shell or a scheduled task spawned from inside a git hook inherits it just the same. Since 2026-09-11 it does so
  # through lib\git-repo-env.ps1, whose behaviour ops\audit-git-fixture-env.ps1 drives in a child process; this
  # checks the WIRING - a call on a code line, not a comment - and that the library still names GIT_DIR.
  # NEEDLES BUILT BY CONCATENATION, so this line is not its own match.
  $gatesText = if (Test-Path -LiteralPath $gatesSrc) { [IO.File]::ReadAllText($gatesSrc) } else { '' }
  $envLibText = [IO.File]::ReadAllText($envLib)
  $callRx = '(?m)^[^#\r\n]*\bClear-TcGit' + 'RepoEnv\s*$'
  $gatesCalls = [regex]::IsMatch($gatesText, $callRx)
  Case 'MUST FIRE' 'run-gates calls the shared clear, and the library removes GIT_DIR' `
    ($gatesCalls -and $envLibText.Contains("'GIT_" + "DIR'")) "run-gates call=$gatesCalls"
  # MUST FIRE, STATIC: the hook reads the refs, THEN resolves the tree, THEN unsets, THEN runs the gate and the
  # check. Refs first is what lets a deletion-only push through a tree it cannot resolve; resolving before the
  # unset is what keeps `repo` naming this checkout.
  $iRead = $hookText.IndexOf('while read -r ' + 'lref')
  $iRepo = $hookText.IndexOf('repo="$(git rev-parse --show-' + 'toplevel')
  $iUnset = $hookText.IndexOf('unset GIT_' + 'DIR')
  $iRun = $hookText.IndexOf('powershell -NoProfile' + ' -ExecutionPolicy Bypass -File "$gate"')
  $iTa = $hookText.IndexOf('powershell -NoProfile' + ' -ExecutionPolicy Bypass -File "$ta"')
  # And since W1.1 (2026-09-23) the rehearsal record is asked for after the unset and BEFORE the gate.
  $iRh = $hookText.IndexOf('powershell -NoProfile' + ' -ExecutionPolicy Bypass -File "$rh"')
  Case 'MUST FIRE' 'the hook reads refs, resolves the tree, unsets the environment, asks for the rehearsal record, then runs the gate and the check' `
    ($iRead -ge 0 -and $iRepo -gt $iRead -and $iUnset -gt $iRepo -and $iRh -gt $iUnset -and $iRun -gt $iRh -and $iTa -gt $iRun) "read@$iRead repo@$iRepo unset@$iUnset rh@$iRh run@$iRun ta@$iTa"

  # ---- THE THIRTEENTH (2026-09-23, W9.1 and D19): the post-commit hook starts the early rehearsal, detached ----
  # Its own small repository inside this sandbox, so no pre-push case above sees a post-commit hook and no commit here
  # reaches the pre-push sandbox. Three commits make three checkouts: A has a push-main with no -Prepare and no
  # ops\hooks\post-commit (a checkout OLDER than the hook), B adds the hook file (push-main still has no -Prepare), C
  # gives push-main its -Prepare switch. The stub push-main records what it was started with and inherited, and can be
  # held on a release file (a condition this suite controls) or made to throw. Every commit goes through Invoke-PcCommit,
  # whose wait is a hang guard only: a hook that ran -Prepare in the foreground would hold the held case's commit open,
  # and that case reads it as a failure after releasing the stub, never as a hang.
  $pcRoot = Join-Path $sb 'pc'
  $pcMain = Join-Path $pcRoot 'main'
  $pcProbe = Join-Path $pcRoot 'probe'
  $pcLogs = Join-Path $pcRoot 'logs'
  $pcHooks = Join-Path $pcRoot 'hooks'
  $pcSessionHad = Test-Path -LiteralPath 'Env:\CLAUDE_CODE_SESSION_ID'
  $pcSessionWas = [string]$env:CLAUDE_CODE_SESSION_ID
  $pcRhRunHad = Test-Path -LiteralPath 'Env:\TC_REHEARSAL_RUN'
  $pcRhRunWas = [string]$env:TC_REHEARSAL_RUN
  function Invoke-PcCommit {
    <# One `git commit --allow-empty` through the sandbox's post-commit hook, stderr to a file. Returns rc, text (the
       hook's lines), head, a TimedOut flag, and the hook's log line for that checkout if it wrote one. The message has no
       spaces, because Start-Process joins its arguments with them. #>
    param([string]$Dir, [string]$Msg, [int]$GuardSec = 90)
    $errF = Join-Path $pcRoot ('commit-err-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.txt')
    $outF = $errF + '.out'
    $pr = Start-Process -FilePath 'git' -ArgumentList @('-C', $Dir, '-c', ('core.hooksPath=' + $pcHooks), 'commit', '-q', '--allow-empty', '-m', $Msg) `
      -NoNewWindow -PassThru -RedirectStandardError $errF -RedirectStandardOutput $outF
    $null = $pr.Handle
    $timedOut = -not $pr.WaitForExit($GuardSec * 1000)
    $rcC = if ($timedOut) { -1 } else { $pr.ExitCode }
    # SHARED READ, never ReadAllText: on a timed-out commit git is still running and still holds the file it writes
    # its stderr to, and an exclusive open would throw here instead of letting the case report the timeout.
    $txt = ''
    if (Test-Path -LiteralPath $errF) {
      try {
        $fs = New-Object IO.FileStream($errF, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        try { $txt = (New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
      } catch { $txt = 'UNREADABLE: ' + $_.Exception.Message }
    }
    return [pscustomobject]@{ rc = $rcC; text = $txt; TimedOut = $timedOut; Process = $pr; head = (GOut -C $Dir rev-parse HEAD); subject = (GOut -C $Dir log -1 --format=%s) }
  }
  function Get-PcLogPath {
    <# The log path the hook computes for a checkout: the first 16 hex of SHA-256 over its top path as git prints it,
       lower-cased (ASCII only, as the hook's `tr` is). #>
    param([string]$Dir)
    $top = (GOut -C $Dir rev-parse --show-toplevel).ToLowerInvariant()
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hx = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($top))) -replace '-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
    return (Join-Path $pcLogs ('post-commit-' + $hx.Substring(0, 16) + '.log'))
  }
  function Wait-PcFile {
    # A hang guard, not a bar: returns as soon as the file exists, and $false only when it never appears.
    param([string]$Path, [int]$GuardSec = 90)
    $until = [datetime]::UtcNow.AddSeconds($GuardSec)
    while (-not (Test-Path -LiteralPath $Path)) {
      if ([datetime]::UtcNow -gt $until) { return $false }
      Start-Sleep -Milliseconds 200
    }
    return $true
  }
  function Invoke-PcSentinel {
    <# A commit that DOES start the stub, from the C checkout, made AFTER a case that must start nothing. Its marker
       appearing means every child a hook started before it has had strictly longer to write its own. #>
    param([string]$Tag)
    $env:TC_POSTCOMMIT_TAG = $Tag
    $s = Invoke-PcCommit $pcLinked ('sentinel-' + $Tag)
    $ok = Wait-PcFile (Join-Path $pcProbe ('prepare-' + $Tag + '.txt'))
    return ($s.rc -eq 0 -and $ok)
  }
  try {
    $null = New-Item -ItemType Directory -Force $pcMain, $pcProbe, $pcLogs, $pcHooks
    $pcSteps = @(
      (G init -q $pcMain),
      (G -C $pcMain config user.email t@t),
      (G -C $pcMain config user.name t),
      (G -C $pcMain config commit.gpgsign false),
      (G -C $pcMain config core.autocrlf false)
    )
    $null = New-Item -ItemType Directory -Force (Join-Path $pcMain 'ops\hooks')
    $pmNoPrepare = "[CmdletBinding()]`nparam([switch]`$Other)`n[IO.File]::WriteAllText((Join-Path `$env:TC_POSTCOMMIT_PROBE ('prepare-' + `$env:TC_POSTCOMMIT_TAG + '.txt')), 'the no-Prepare push-main ran')`n"
    [IO.File]::WriteAllText((Join-Path $pcMain 'ops\push-main.ps1'), $pmNoPrepare, $utf8)
    $pcSteps += (G -C $pcMain add -A)
    $pcSteps += (G -C $pcMain commit -q -m pc-A)
    $pcA = GOut -C $pcMain rev-parse HEAD
    $pcHookText = [IO.File]::ReadAllText((Join-Path $RepoRoot 'ops\hooks\post-commit')).Replace("`r`n", "`n")
    [IO.File]::WriteAllText((Join-Path $pcMain 'ops\hooks\post-commit'), $pcHookText, $utf8)
    $pcSteps += (G -C $pcMain add -A)
    $pcSteps += (G -C $pcMain commit -q -m pc-B)
    $pcB = GOut -C $pcMain rev-parse HEAD
    $pmStub = @'
[CmdletBinding()]
param([switch]$Prepare)
$p = $env:TC_POSTCOMMIT_PROBE; $t = [string]$env:TC_POSTCOMMIT_TAG
$seen = 'Prepare=' + [bool]$Prepare + "`nGIT_DIR=" + [string]$env:GIT_DIR + "`nGIT_INDEX_FILE=" + [string]$env:GIT_INDEX_FILE + "`nROOT=" + $PSScriptRoot
[IO.File]::WriteAllText((Join-Path $p ('prepare-' + $t + '.txt')), $seen)
if ($env:TC_POSTCOMMIT_THROW) { throw 'fixture: the starter throws' }
if ($env:TC_POSTCOMMIT_HOLD) {
  $rel = Join-Path $p ('release-' + $t + '.txt'); $until = [datetime]::UtcNow.AddSeconds(150)
  while (-not (Test-Path -LiteralPath $rel) -and [datetime]::UtcNow -lt $until) { Start-Sleep -Milliseconds 200 }
}
[IO.File]::WriteAllText((Join-Path $p ('done-' + $t + '.txt')), 'done')
Write-Output 'stub push-main -Prepare: done'
'@
    [IO.File]::WriteAllText((Join-Path $pcMain 'ops\push-main.ps1'), $pmStub, $utf8)
    $pcSteps += (G -C $pcMain add -A)
    $pcSteps += (G -C $pcMain commit -q -m pc-C)
    [IO.File]::WriteAllText((Join-Path $pcHooks 'post-commit'), $pcHookText, $utf8)
    $pcLinked = Join-Path $pcRoot 'linked'
    $pcOld = Join-Path $pcRoot 'old'
    $pcNoPrep = Join-Path $pcRoot 'noprep'
    $pcSteps += (G -C $pcMain worktree add -q --detach $pcLinked)
    $pcSteps += (G -C $pcMain worktree add -q --detach $pcOld $pcA)
    $pcSteps += (G -C $pcMain worktree add -q --detach $pcNoPrep $pcB)
    $pcBad = @($pcSteps | Where-Object { $_ -ne 0 })
    $env:TC_POSTCOMMIT_PROBE = $pcProbe
    $env:TC_POST_COMMIT_LOG_DIR = $pcLogs
    $env:CLAUDE_CODE_SESSION_ID = 'test-prepush-hook-fixture'
    Remove-Item -LiteralPath 'Env:\TC_REHEARSAL_RUN', 'Env:\TC_POSTCOMMIT_THROW', 'Env:\TC_POSTCOMMIT_HOLD' -ErrorAction SilentlyContinue
    $pcLinkedLog = Get-PcLogPath $pcLinked

    # MUST FIRE: a session commit from a LINKED worktree starts that checkout's OWN push-main -Prepare, with no
    # repository environment inherited, and the log's first line names the commit it was started for.
    $env:TC_POSTCOMMIT_TAG = 'fire'
    $pcFire = Invoke-PcCommit $pcLinked 'pc-fire'
    $pcFireOk = Wait-PcFile (Join-Path $pcProbe 'prepare-fire.txt')
    $pcFireSaw = if ($pcFireOk) { [IO.File]::ReadAllText((Join-Path $pcProbe 'prepare-fire.txt')) } else { '' }
    $pcFireLog1 = if (Test-Path -LiteralPath $pcLinkedLog) { @([IO.File]::ReadAllLines($pcLinkedLog))[0] } else { '' }
    $pcWantRoot = 'ROOT=' + (Join-Path $pcLinked 'ops')
    Case 'MUST FIRE' 'a session commit from a linked worktree starts ITS OWN push-main -Prepare, with no GIT_DIR or GIT_INDEX_FILE' `
      ($pcBad.Count -eq 0 -and $pcFire.rc -eq 0 -and $pcFireOk -and $pcFireSaw.Contains('Prepare=True') -and $pcFireSaw.Contains("GIT_DIR=`n") `
        -and $pcFireSaw.Contains("GIT_INDEX_FILE=`n") -and $pcFireSaw.EndsWith($pcWantRoot, [StringComparison]::OrdinalIgnoreCase)) `
      ("steps-bad=" + $pcBad.Count + " rc=" + $pcFire.rc + " saw=[" + $pcFireSaw.Replace("`n", ' | ') + "] want=[" + $pcWantRoot + "] text=[" + $pcFire.text + "]")
    Case 'MUST FIRE' 'the hook writes its start line to that checkout''s log, naming the commit, before the child runs' `
      ($pcFire.head.Length -eq 40 -and $pcFireLog1.StartsWith('post-commit: started ops/push-main.ps1 -Prepare for ' + $pcFire.head, [StringComparison]::Ordinal)) `
      ("log=[" + $pcLinkedLog + "] line1=[" + $pcFireLog1 + "] head=" + $pcFire.head)

    # MUST FIRE, DETACHED: the commit returns while the started child is still running. The stub is held on a release
    # file; a hook that waited for it would keep the commit open until the hang guard, and the case releases it then.
    $env:TC_POSTCOMMIT_TAG = 'held'
    $env:TC_POSTCOMMIT_HOLD = '1'
    $pcHeld = Invoke-PcCommit $pcLinked 'pc-held' -GuardSec 60
    $pcHeldDoneAtReturn = Test-Path -LiteralPath (Join-Path $pcProbe 'done-held.txt')
    $pcHeldStarted = Wait-PcFile (Join-Path $pcProbe 'prepare-held.txt')
    $pcHeldStillRunning = -not (Test-Path -LiteralPath (Join-Path $pcProbe 'done-held.txt'))
    [IO.File]::WriteAllText((Join-Path $pcProbe 'release-held.txt'), 'go')
    if ($pcHeld.TimedOut) { $null = $pcHeld.Process.WaitForExit(30000) }
    $pcHeldDone = Wait-PcFile (Join-Path $pcProbe 'done-held.txt')
    Remove-Item -LiteralPath 'Env:\TC_POSTCOMMIT_HOLD' -ErrorAction SilentlyContinue
    Case 'MUST FIRE' 'the commit returns while the -Prepare child is still running, and the child then finishes on its own' `
      (-not $pcHeld.TimedOut -and $pcHeld.rc -eq 0 -and -not $pcHeldDoneAtReturn -and $pcHeldStarted -and $pcHeldStillRunning -and $pcHeldDone) `
      ("timedOut=" + $pcHeld.TimedOut + " rc=" + $pcHeld.rc + " doneAtReturn=" + $pcHeldDoneAtReturn + " started=" + $pcHeldStarted + " stillRunning=" + $pcHeldStillRunning + " done=" + $pcHeldDone)

    # CLEAN TWIN: a starter that throws costs the commit nothing: git exits 0 and the commit exists.
    $env:TC_POSTCOMMIT_TAG = 'throw'
    $env:TC_POSTCOMMIT_THROW = '1'
    $pcBeforeThrow = GOut -C $pcLinked rev-parse HEAD
    $pcThrow = Invoke-PcCommit $pcLinked 'pc-throw'
    $pcThrowRan = Wait-PcFile (Join-Path $pcProbe 'prepare-throw.txt')
    Remove-Item -LiteralPath 'Env:\TC_POSTCOMMIT_THROW' -ErrorAction SilentlyContinue
    Case 'CLEAN TWIN' 'a post-commit hook whose starter throws still returns 0, and the commit exists' `
      ($pcThrow.rc -eq 0 -and $pcThrowRan -and $pcThrow.head -ne $pcBeforeThrow -and $pcThrow.subject -eq 'pc-throw') `
      ("rc=" + $pcThrow.rc + " starterRan=" + $pcThrowRan + " head=" + $pcThrow.head + " before=" + $pcBeforeThrow + " subject=" + $pcThrow.subject)

    # MUST NOT FIRE: without CLAUDE_CODE_SESSION_ID (a human, the bot) the hook starts nothing and writes no log line.
    Remove-Item -LiteralPath $pcLinkedLog -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath 'Env:\CLAUDE_CODE_SESSION_ID' -ErrorAction SilentlyContinue
    $env:TC_POSTCOMMIT_TAG = 'nosession'
    $pcNoSess = Invoke-PcCommit $pcLinked 'pc-nosession'
    $pcNoSessLog = Test-Path -LiteralPath $pcLinkedLog
    $env:CLAUDE_CODE_SESSION_ID = 'test-prepush-hook-fixture'
    $pcSent1 = Invoke-PcSentinel 'sentinel-1'
    Case 'MUST NOT FIRE' 'without CLAUDE_CODE_SESSION_ID the post-commit hook starts nothing' `
      ($pcNoSess.rc -eq 0 -and -not $pcNoSessLog -and $pcSent1 -and -not (Test-Path -LiteralPath (Join-Path $pcProbe 'prepare-nosession.txt'))) `
      ("rc=" + $pcNoSess.rc + " logWritten=" + $pcNoSessLog + " sentinel=" + $pcSent1 + " text=[" + $pcNoSess.text + "]")

    # MUST NOT FIRE (M20's case): inside a rehearsal (TC_REHEARSAL_RUN set) the hook starts nothing.
    Remove-Item -LiteralPath $pcLinkedLog -ErrorAction SilentlyContinue
    $env:TC_REHEARSAL_RUN = '1'
    $env:TC_POSTCOMMIT_TAG = 'inrehearsal'
    $pcInRh = Invoke-PcCommit $pcLinked 'pc-inrehearsal'
    $pcInRhLog = Test-Path -LiteralPath $pcLinkedLog
    Remove-Item -LiteralPath 'Env:\TC_REHEARSAL_RUN' -ErrorAction SilentlyContinue
    $pcSent2 = Invoke-PcSentinel 'sentinel-2'
    Case 'MUST NOT FIRE' 'with TC_REHEARSAL_RUN=1 the post-commit hook starts nothing' `
      ($pcInRh.rc -eq 0 -and -not $pcInRhLog -and $pcSent2 -and -not (Test-Path -LiteralPath (Join-Path $pcProbe 'prepare-inrehearsal.txt'))) `
      ("rc=" + $pcInRh.rc + " logWritten=" + $pcInRhLog + " sentinel=" + $pcSent2 + " text=[" + $pcInRh.text + "]")

    # MUST NOT FIRE: a checkout OLDER than the hook (no ops\hooks\post-commit in its tree) starts nothing and says so.
    $pcOldLog = Get-PcLogPath $pcOld
    $env:TC_POSTCOMMIT_TAG = 'old'
    $pcOldC = Invoke-PcCommit $pcOld 'pc-old'
    $pcSent3 = Invoke-PcSentinel 'sentinel-3'
    Case 'MUST NOT FIRE' 'a checkout older than the hook starts nothing and prints one line saying so' `
      ($pcOldC.rc -eq 0 -and $pcOldC.text -match 'this checkout predates the early-rehearsal hook' -and -not (Test-Path -LiteralPath $pcOldLog) -and $pcSent3 `
        -and -not (Test-Path -LiteralPath (Join-Path $pcProbe 'prepare-old.txt'))) ("rc=" + $pcOldC.rc + " sentinel=" + $pcSent3 + " text=[" + $pcOldC.text + "]")

    # MUST NOT FIRE, FAIL OPEN: a push-main with no -Prepare switch is never started, and one line says so.
    $pcNoPrepLog = Get-PcLogPath $pcNoPrep
    $env:TC_POSTCOMMIT_TAG = 'noprep'
    $pcNoPrepC = Invoke-PcCommit $pcNoPrep 'pc-noprep'
    $pcSent4 = Invoke-PcSentinel 'sentinel-4'
    Case 'MUST NOT FIRE' 'a checkout whose push-main has no -Prepare starts nothing, prints one line, and the commit exists' `
      ($pcNoPrepC.rc -eq 0 -and $pcNoPrepC.subject -eq 'pc-noprep' -and $pcNoPrepC.text -match 'has no -Prepare mode' -and -not (Test-Path -LiteralPath $pcNoPrepLog) `
        -and $pcSent4 -and -not (Test-Path -LiteralPath (Join-Path $pcProbe 'prepare-noprep.txt'))) ("rc=" + $pcNoPrepC.rc + " sentinel=" + $pcSent4 + " text=[" + $pcNoPrepC.text + "]")

    # MUST NOT FIRE: the commits a rebase REPLAYS start nothing (git runs post-commit for each one).
    Remove-Item -LiteralPath $pcLinkedLog -ErrorAction SilentlyContinue
    $env:TC_POSTCOMMIT_TAG = 'rebase'
    $null = G -C $pcMain commit -q --allow-empty -m pc-main-moves
    $pcRbOut = @(& git -C $pcLinked -c ('core.hooksPath=' + $pcHooks) rebase $(GOut -C $pcMain rev-parse HEAD) 2>&1 | ForEach-Object { [string]$_ })
    $pcRbRc = $LASTEXITCODE
    $pcRbLog = Test-Path -LiteralPath $pcLinkedLog
    $pcSent5 = Invoke-PcSentinel 'sentinel-5'
    Case 'MUST NOT FIRE' 'the commits a rebase replays start nothing, and each says why' `
      ($pcRbRc -eq 0 -and -not $pcRbLog -and ($pcRbOut -join "`n") -match 'a rebase is in progress' -and $pcSent5 -and -not (Test-Path -LiteralPath (Join-Path $pcProbe 'prepare-rebase.txt'))) `
      ("rc=" + $pcRbRc + " logWritten=" + $pcRbLog + " sentinel=" + $pcSent5 + " out=[" + ($pcRbOut -join ' | ') + "]")

    # MUST FIRE, STATIC: the hook's only road to a rehearsal is push-main -Prepare, so the early-rehearsal cap that
    # rehearse-chain -Early takes is never gone around. Code lines only (comments name the script freely); needles by
    # concatenation so this file is not its own match.
    $pcCode = @($pcHookText -split "`n" | Where-Object { $_ -notmatch '^\s*#' })
    $pcNamesRh = @($pcCode | Where-Object { $_.Contains('rehearse-' + 'chain') }).Count
    $pcStarts = @($pcCode | Where-Object { $_.Contains('-File "$pm" -' + 'Prepare') -and $_.Contains('&') }).Count
    Case 'MUST FIRE' 'the hook starts nothing but push-main -Prepare, in the background, and never names the rehearsal script' `
      ($pcNamesRh -eq 0 -and $pcStarts -eq 1) ("rehearse-chain code lines=" + $pcNamesRh + " background -Prepare starts=" + $pcStarts)
  } finally {
    Remove-Item -LiteralPath 'Env:\TC_POSTCOMMIT_PROBE', 'Env:\TC_POSTCOMMIT_TAG', 'Env:\TC_POSTCOMMIT_HOLD', 'Env:\TC_POSTCOMMIT_THROW', 'Env:\TC_POST_COMMIT_LOG_DIR' -ErrorAction SilentlyContinue
    if ($pcSessionHad) { $env:CLAUDE_CODE_SESSION_ID = $pcSessionWas } else { Remove-Item -LiteralPath 'Env:\CLAUDE_CODE_SESSION_ID' -ErrorAction SilentlyContinue }
    if ($pcRhRunHad) { $env:TC_REHEARSAL_RUN = $pcRhRunWas } else { Remove-Item -LiteralPath 'Env:\TC_REHEARSAL_RUN' -ErrorAction SilentlyContinue }
  }

  # ---- THE NINTH (2026-09-23, W0.2): this run's ledger rows stay inside this run's sandbox ----
  $suiteFiles = @(Get-ChildItem -LiteralPath $suiteLedger -Filter 'pushes-*.jsonl' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
  $suiteRead = Read-LedgerLinesNaming -Files $suiteFiles -Needle $sbLeaf
  # MUST FIRE: the redirect reached the REAL holder the push-lock pushes started, and its rows are here. Without this
  # the case below would pass on a suite that wrote no row anywhere.
  Case 'MUST FIRE' 'the suite''s own ledger holds a row a sandbox push wrote, so the redirect reached the holder' `
    (@($suiteRead.Hits).Count -ge 1) ("files=" + $suiteFiles.Count + " rows naming " + $sbLeaf + "=" + @($suiteRead.Hits).Count)
  # MUST NOT FIRE: the production ledger, for every day this run spanned, holds no row naming this run's sandbox. Names,
  # never a line count: a real push may append to that file while this suite runs. A file that could not be read is a
  # failure here, never a pass.
  $prodFiles = @((Get-TcPushLedgerPath -Root $prodLedgerRoot -Now $suiteStart), (Get-TcPushLedgerPath -Root $prodLedgerRoot -Now ([datetime]::Now)))
  $prodRead = Read-LedgerLinesNaming -Files $prodFiles -Needle $sbLeaf
  Case 'MUST NOT FIRE' 'no row in the PRODUCTION push ledger names this run''s sandbox' `
    ((@($prodRead.Hits).Count -eq 0) -and (@($prodRead.Unreadable).Count -eq 0)) ("read=" + $prodRead.Read + " unreadable=[" + (@($prodRead.Unreadable) -join ',') + "] rows=[" + (@($prodRead.Hits) -join ' | ') + "]")
} finally {
  Remove-Item -LiteralPath 'Env:\TC_PREPUSH_PROBE', 'Env:\TC_PREPUSH_PROBE_EXIT', 'Env:\TC_PREPUSH_PROBE_SAY', 'Env:\TMPDIR', 'Env:\TC_PREPUSH_TA_FAILS', 'Env:\TC_PREPUSH_TA_FAILS_BETA' -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath 'Env:\TC_REHEARSAL_VERDICT_DIR', 'Env:\TC_NO_REHEARSAL' -ErrorAction SilentlyContinue
  if ($ledgerRootHad) { $env:TC_PUSH_LEDGER_ROOT = $ledgerRootWas } else { Remove-Item -LiteralPath 'Env:\TC_PUSH_LEDGER_ROOT' -ErrorAction SilentlyContinue }
  if ($holderTokHad) { $env:TC_PUSH_LOCK_HOLDER = $holderTokWas } else { Remove-Item -LiteralPath 'Env:\TC_PUSH_LOCK_HOLDER' -ErrorAction SilentlyContinue }
  foreach ($n in @($cqSuiteHad.Keys)) {
    if ($cqSuiteHad[$n]) { [Environment]::SetEnvironmentVariable($n, $cqSuiteWas[$n]) } else { Remove-Item -LiteralPath ('Env:\' + $n) -ErrorAction SilentlyContinue }
  }
  if (Test-Path -LiteralPath $sb) {
    # The sandbox's own worktree first, through git, then the directory. No junctions are ever made here.
    if ($built) { $null = G -C $main worktree remove --force $linked }
    Remove-Item -LiteralPath $sb -Recurse -Force -ErrorAction SilentlyContinue
  }
}

# A SUITE THAT SILENTLY RAN A SUBSET still prints "N of N". Measured 2026-09-11 by a mutant that kept the check from
# writing its known-failures record: the stale-record step's ReadAllText threw, the try skipped the 15 cases after it,
# and the tally read "7 FAILED of 16". Had those 7 been green it would have read "16 of 16 cases pass". Pinned, as
# prepush-test-auditors -SelfTest pins its own count.
$expectedCases = 87   # 87 since 2026-09-24 with THE THIRTEENTH's ten post-commit cases (W9.1, D19); 77 since 2026-09-24 with THE TWELFTH's ten chain-queue cases (W8.3); 67 since 2026-09-23 with THE ELEVENTH's four refusal-row cases (W0.6); 63 with THE TENTH's nine cases (W1.1): four that read the fixed refusal line for structure, run-gates with and without a gate, and test-auditors, and five over the reordered rehearsal check; 54 with THE NINTH's two ledger cases (W0.2 of design\PLAN-push-derived-conflicts-2026-09-23.md); 52 with the case that reads the static-scanned-zero cause (W6.9); 51 since 2026-09-22 with the three chain-rehearsal cases; 31 until 2026-09-11, when the hook began handing the gate the refs this push updates; 36 with the seeding cases; 42 with THE EIGHTH's six push-lock cases; 45 with the three that read WHICH cause a 3 named (2026-09-12); 46 once an older checkout falls back to the main one's holder; 48 with the two that read the slot budget from lib\gate-slots.ps1 (2026-09-18, backlog I237)
if ($ran.Count -ne $expectedCases) { $fails += "ran $($ran.Count) case(s), expected $expectedCases - a block of cases was skipped" }

''
if ($fails.Count -gt 0) {
  "test-prepush-hook selftest: $($fails.Count) FAILED of $($ran.Count)"
  $fails | ForEach-Object { "  $_" }
  Exit-Guard -Name 'TEST-PREPUSH-HOOK' -Code 1 -Summary "failed=$($fails.Count) of $($ran.Count)"
}
# The verdict names the self-test: run-gates reads it before believing exit 0 (lib\selftest-verdict.ps1).
"test-prepush-hook selftest: $($ran.Count) of $($ran.Count) cases pass"
Exit-Guard -Name 'TEST-PREPUSH-HOOK' -Code 0 -Summary "cases=$($ran.Count)"
