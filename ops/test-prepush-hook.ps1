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

$sb = Join-Path $env:TEMP ('tc-prepush-selftest-{0}-{1}' -f $PID, [guid]::NewGuid().ToString('N').Substring(0, 8))
$main = Join-Path $sb 'main'
$linked = Join-Path $sb 'linked'
$remote = Join-Path $sb 'remote.git'
$script:Remote = $remote
$probe = Join-Path $sb 'probe'
$built = $false
$utf8 = New-Object Text.UTF8Encoding($false)
try {
  $null = New-Item -ItemType Directory -Force $sb, $probe
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

  # ---- a checkout whose working tree git cannot resolve ----
  # MUST FIRE, THE SECOND FOUNDING CASE: the sandbox repo turned bare, exactly the damaged state, and a
  # push from the linked worktree must be refused rather than waved through ungated.
  $mainCfg = Join-Path $main '.git\config'
  $null = G config --file $mainCfg core.bare true
  $env:TC_PREPUSH_PROBE_EXIT = '0'
  $rcBare = G -C $linked -c ("core.hooksPath=" + $hooksPath) push -q origin HEAD:refs/heads/unresolved
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
      $lockFreeDuring = if (Test-Path -LiteralPath $lockFreeFile) { [IO.File]::ReadAllText($lockFreeFile).Trim() } else { 'the gate never reported' }
      Case 'MUST FIRE' 'the lock is STILL HELD while the gate runs, not handed back the moment the hook says held' `
        ($lockFreeDuring -eq '0') "lockWasFreeDuringGate=$lockFreeDuring"
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
      Case 'CLEAN TWIN' 'a red gate under a held push lock still refuses the push - the lock decides nothing about the tree' `
        ($pRed.rc -ne 0 -and $pRed.text -match 'push lock - held' -and $pRed.text -match 'BLOCKED') `
        "rc=$($pRed.rc) text=$($pRed.text)"
      # MUST NOT FIRE: a refused push releases the lock too, or one red gate would wedge the box.
      $afterRed = Start-TcMutexHold -Name ($lkPrefix + '0')
      Case 'MUST NOT FIRE' 'a REFUSED push hands the push lock back as well, so one red gate cannot wedge the box' `
        ($null -ne $afterRed -and $afterRed.Held) "held=$(if ($afterRed) { $afterRed.Held } else { 'no hold' })"
      Stop-TcMutexHold $afterRed
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
  Case 'MUST FIRE' 'the hook reads refs, resolves the tree, unsets the environment, then runs the gate and the check' `
    ($iRead -ge 0 -and $iRepo -gt $iRead -and $iUnset -gt $iRepo -and $iRun -gt $iUnset -and $iTa -gt $iUnset) "read@$iRead repo@$iRepo unset@$iUnset run@$iRun ta@$iTa"
} finally {
  Remove-Item -LiteralPath 'Env:\TC_PREPUSH_PROBE', 'Env:\TC_PREPUSH_PROBE_EXIT', 'Env:\TMPDIR', 'Env:\TC_PREPUSH_TA_FAILS', 'Env:\TC_PREPUSH_TA_FAILS_BETA' -ErrorAction SilentlyContinue
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
$expectedCases = 42   # 31 until 2026-09-11, when the hook began handing the gate the refs this push updates; 36 with the seeding cases; 42 with THE EIGHTH's six push-lock cases
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
