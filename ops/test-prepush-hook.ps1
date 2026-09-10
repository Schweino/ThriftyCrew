<#
  Does a push from a LINKED worktree run the gate without handing it the repository?

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

  WHAT THIS DRIVES. A sandbox repository, a linked worktree, the REAL ops\hooks\pre-push, and a stub
  gate that does the one thing that did the damage (`git init` of a temp directory) and records the
  GIT_DIR it saw. Then a real `git push` to a sandbox bare remote. No network, nothing outside the
  sandbox. THIS FILE SCRUBS ITS OWN REPOSITORY ENVIRONMENT FIRST: run by an unfixed hook, a copy that
  did not would recreate the very damage it exists to detect, on the real repository.

  Exit 0 pass, 1 a case failed, 3 could not evaluate (the sandbox could not be built).

  SCOPE OF A CLEAN REPORT: SOUND for the variables the hook's unset line names on the git version this
  box runs; UNSOUND for a future git that exports a variable that line does not name.
#>
[CmdletBinding()]
param([switch]$SelfTest)   # accepted so ops\run-gates.ps1 discovers this file; the cases run either way

$ErrorActionPreference = 'Continue'
$RepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $RepoRoot 'lib\guard-contract.ps1')

$script:RepoEnv = @('GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_COMMON_DIR', 'GIT_OBJECT_DIRECTORY',
                    'GIT_ALTERNATE_OBJECT_DIRECTORIES', 'GIT_PREFIX', 'GIT_NAMESPACE')
foreach ($v in $script:RepoEnv) { Remove-Item -LiteralPath ("Env:\" + $v) -ErrorAction SilentlyContinue }

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

$hookSrc = Join-Path $RepoRoot 'ops\hooks\pre-push'
$gatesSrc = Join-Path $RepoRoot 'ops\run-gates.ps1'
if (-not (Test-Path -LiteralPath $hookSrc)) {
  'BLIND: ops\hooks\pre-push is missing - nothing to drive'
  Exit-Guard -Name 'TEST-PREPUSH-HOOK' -Code 3 -Summary 'blind=no-hook'
}

$sb = Join-Path $env:TEMP ('tc-prepush-selftest-{0}-{1}' -f $PID, [guid]::NewGuid().ToString('N').Substring(0, 8))
$main = Join-Path $sb 'main'
$linked = Join-Path $sb 'linked'
$remote = Join-Path $sb 'remote.git'
$probe = Join-Path $sb 'probe'
$built = $false
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
  $null = New-Item -ItemType Directory -Force (Join-Path $main 'ops')
  # THE STUB GATE does the damaging act and records what it inherited. Single-quoted: nothing expands
  # until the stub itself runs inside the hook.
  $stub = @'
$p = $env:TC_PREPUSH_PROBE
[IO.File]::WriteAllText((Join-Path $p 'gate-saw.txt'), ('GIT_DIR=' + [string]$env:GIT_DIR))
$null = & git init -q (Join-Path $p ('initprobe-' + [guid]::NewGuid().ToString('N'))) 2>$null
exit ([int]$env:TC_PREPUSH_PROBE_EXIT)
'@
  [IO.File]::WriteAllText((Join-Path $main 'ops\run-gates.ps1'), $stub, (New-Object Text.UTF8Encoding($false)))
  $steps += (G -C $main add -A)
  $steps += (G -C $main commit -q -m seed)
  $steps += (G init -q --bare $remote)
  $steps += (G -C $main remote add origin $remote)
  # The REAL hook, as LF: sh reads a CR as part of the command name.
  $hookText = [IO.File]::ReadAllText($hookSrc).Replace("`r`n", "`n")
  [IO.File]::WriteAllText((Join-Path $main '.git\hooks\pre-push'), $hookText, (New-Object Text.UTF8Encoding($false)))
  $steps += (G -C $main worktree add -q --detach $linked)
  $bad = @($steps | Where-Object { $_ -ne 0 })
  if ($bad.Count -gt 0 -or -not (Test-Path -LiteralPath (Join-Path $linked 'ops\run-gates.ps1'))) {
    "BLIND: the sandbox could not be built (non-zero git steps: $($bad.Count))"
    Exit-Guard -Name 'TEST-PREPUSH-HOOK' -Code 3 -Summary 'blind=sandbox'
  }
  $built = $true
  $hooksPath = Join-Path $main '.git\hooks'
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
  $null = G config --file $mainCfg core.bare false
  $unres = GOut --git-dir $remote rev-parse --verify -q refs/heads/unresolved
  Case 'MUST FIRE' 'a push whose working tree cannot be resolved is refused, not waved through' `
    (($rcBare -ne 0) -and ($unres -eq '')) "rc=$rcBare ref=$unres"

  # MUST FIRE, STATIC: run-gates scrubs the same environment for EVERY caller, not only this hook - a
  # session shell or a scheduled task spawned from inside a git hook inherits it just the same.
  # NEEDLES BUILT BY CONCATENATION, so this line is not its own match.
  $gatesText = if (Test-Path -LiteralPath $gatesSrc) { [IO.File]::ReadAllText($gatesSrc) } else { '' }
  Case 'MUST FIRE' 'run-gates removes GIT_DIR from its own environment' `
    ($gatesText.Contains("'GIT_" + "DIR'") -and $gatesText.Contains('Remove-Item -LiteralPath ("Env:' + '\"'))
  # MUST FIRE, STATIC: the hook unsets BEFORE it runs the gate, not after.
  $iUnset = $hookText.IndexOf('unset GIT_' + 'DIR')
  $iRun = $hookText.IndexOf('powershell -NoProfile' + ' -ExecutionPolicy Bypass -File "$gate"')
  Case 'MUST FIRE' 'the hook unsets the repository environment before invoking the gate' `
    ($iUnset -ge 0 -and $iRun -gt $iUnset) "unset@$iUnset run@$iRun"
} finally {
  Remove-Item -LiteralPath 'Env:\TC_PREPUSH_PROBE', 'Env:\TC_PREPUSH_PROBE_EXIT', 'Env:\TMPDIR' -ErrorAction SilentlyContinue
  if (Test-Path -LiteralPath $sb) {
    # The sandbox's own worktree first, through git, then the directory. No junctions are ever made here.
    if ($built) { $null = G -C $main worktree remove --force $linked }
    Remove-Item -LiteralPath $sb -Recurse -Force -ErrorAction SilentlyContinue
  }
}

''
if ($fails.Count -gt 0) {
  "test-prepush-hook: $($fails.Count) FAILED of $($ran.Count)"
  $fails | ForEach-Object { "  $_" }
  Exit-Guard -Name 'TEST-PREPUSH-HOOK' -Code 1 -Summary "failed=$($fails.Count) of $($ran.Count)"
}
"test-prepush-hook: $($ran.Count) of $($ran.Count) cases pass"
Exit-Guard -Name 'TEST-PREPUSH-HOOK' -Code 0 -Summary "cases=$($ran.Count)"
