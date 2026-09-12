<#
  test-precommit-hook.ps1 - the pre-commit hook actually REFUSES the commits it was written to refuse.

  WHY (2026-09-06, PLAN-top5-2026-09-06 area 3). The hook is the only thing standing in the path of BOTH a
  careless human and an automated one, and until now nothing proved it fires. Two arms, two failure modes:

    verify-bulk-edit        the SHAPE of the staged set (BOM, line endings, a clean parse, resolvable
                            calls). Written 2026-09-05 after a 608-site sweep introduced six defects.
    verify-bot-commit-scope the SCOPE of a commit that identifies itself as the pipeline. Written
                            2026-09-06 after push-data.ps1's `git add -A` put 325 files on main, 192 of
                            them .ps1 mid-edit, and held them there for 59 minutes.

  A HOOK THAT DOES NOT REFUSE IS A COMMENT. It runs in `sh`, it depends on exit codes crossing two process
  boundaries and on `git var` resolving an identity that a `-c user.name` handed down through the
  environment - none of which can be read off the source. So this drives the INSTALLED-SHAPE hook against
  throwaway repos in %TEMP% and reads git's own verdict: did the commit exist afterwards, or not.

  FROM A LINKED WORKTREE (2026-09-11). The pre-push incident of 2026-09-10 has a pre-commit twin: git hands this hook
  GIT_DIR from a linked worktree, and a checker that built a temp repo would write the shared config. The hook now
  unsets the repository location and KEEPS GIT_INDEX_FILE. The cases drive a stub checker from a linked worktree and
  from the main checkout, and a PARTIAL commit from a linked worktree, which is judged correctly only while
  GIT_INDEX_FILE survives the unset.

  Run:  powershell -NoProfile -File ops\test-precommit-hook.ps1
  Exit: 0 pass, 1 a case failed, 3 BLIND (the hook or a checker is missing - nothing was proven).
#>
# gate-inputs: ops\hooks\pre-commit, ops\hooks\commit-msg, ops\verify-bulk-edit.ps1, ops\verify-bot-commit-scope.ps1, ops\verify-commodities-gate.ps1, ops\new-commit-message.ps1, grocery\identity-lib.ps1, lib\bot-paths.ps1, lib\guard-contract.ps1, lib\ps-source.ps1
# WHY THIS FILE DECLARES (Brad, 2026-09-12). 39s on every push to re-prove a hook whose entire input set this
# script ALREADY NAMES: the list above is $needed, copied from it, and the suite refuses BLIND when one of them is
# missing. So the inputs were written down long before the key could read them - the declaration only moves them
# somewhere a key can look. Nine named files, none of which a commit elsewhere in the tree can touch.
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop (2026-09-07)
param([switch]$SelfTest)   # accepted so ops\run-gates.ps1 discovers this file; the cases run either way
$ErrorActionPreference = 'Continue'
$repo = Split-Path $PSScriptRoot -Parent
# Every repo below is a temp repo, addressed by path: clear the repository environment first (2026-09-10;
# lib\git-repo-env.ps1), so a copy of this file run from inside a hook cannot write the shared .git.
. (Join-Path $repo 'lib\git-repo-env.ps1'); Clear-TcGitRepoEnv
$hookSrc = Join-Path $PSScriptRoot 'hooks\pre-commit'
# THE CHECKERS THE HOOK SHELLS OUT TO, copied in so the fixture repo is self-contained. A fixture that
# reached back into the real tree for them would pass on a tree where the hook could never find them.
$needed = @('ops\hooks\pre-commit', 'ops\verify-bulk-edit.ps1', 'ops\verify-bot-commit-scope.ps1',
            'ops\verify-commodities-gate.ps1', 'grocery\identity-lib.ps1',
            'ops\hooks\commit-msg', 'ops\new-commit-message.ps1',
            'lib\bot-paths.ps1', 'lib\guard-contract.ps1', 'lib\ps-source.ps1')
foreach ($f in $needed) {
  if (-not (Test-Path -LiteralPath (Join-Path $repo $f))) {
    Write-Output ("BLIND: " + $f + " is missing - the hook cannot be proven"); exit 3
  }
}

$n = 0; $bad = 0
function T([string]$m, [bool]$c, [string]$g) {
  $script:n++
  if ($c) { Write-Output "  ok    $m" } else { $script:bad++; Write-Output "  FAIL  $m -> $g" }
}

$made = New-Object System.Collections.ArrayList
function New-HookRepo {
  $w = Join-Path $env:TEMP ('hook-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  [void]$made.Add($w)
  New-Item -ItemType Directory -Force $w | Out-Null
  & git -C $w init -q -b main .
  & git -C $w config user.email t@t
  & git -C $w config user.name  Session
  & git -C $w config commit.gpgsign false
  foreach ($d in @('ops\hooks', 'lib', 'grocery\out\audit', 'grocery\out\regular', 'design')) {
    New-Item -ItemType Directory -Force (Join-Path $w $d) | Out-Null
  }
  foreach ($f in $needed) { Copy-Item (Join-Path $repo $f) (Join-Path $w $f) -Force }
  'seed' | Set-Content (Join-Path $w 'grocery\out\regular\day1.json')
  & git -C $w add -A | Out-Null
  & git -C $w -c core.hooksPath=nonexistent commit -q -m seed | Out-Null
  # Install the hook the way ops\install-hooks.ps1 does: LF endings, no BOM. git runs it through sh, and
  # a CRLF shebang fails with a bare "not found" that names nothing useful.
  $hook = Join-Path $w '.git\hooks\pre-commit'
  New-Item -ItemType Directory -Force (Split-Path $hook -Parent) | Out-Null
  [IO.File]::WriteAllText($hook, ([IO.File]::ReadAllText($hookSrc) -replace "`r`n", "`n"), (New-Object Text.UTF8Encoding($false)))
  # commit-msg is installed the same way, and for the same reason: it is a shell script git runs
  # through sh, so a CRLF shebang fails with a bare "not found" that names nothing useful.
  $cmSrc = Join-Path $repo 'ops\hooks\commit-msg'
  if (Test-Path $cmSrc) {
    [IO.File]::WriteAllText((Join-Path $w '.git\hooks\commit-msg'),
      ([IO.File]::ReadAllText($cmSrc) -replace "`r`n", "`n"), (New-Object Text.UTF8Encoding($false)))
  }
  return $w
}

function Try-Commit {
  <# Returns whether the commit LANDED, read from git rather than from an exit code we could misread. #>
  param([string]$Work, [switch]$AsBot, [string]$Message = 'fixture commit', [string[]]$Paths = @())
  $before = (@(& git -C $Work rev-parse HEAD) -join '').Trim()
  # -Paths is `git commit -- <paths>`: git commits those paths through a PRIVATE index, whose location reaches the
  # hook only as GIT_INDEX_FILE.
  $pathArgs = @(); if ($Paths.Count) { $pathArgs = @('--') + $Paths }
  $out = if ($AsBot) {
    & git -C $Work -c user.name=smp-pipeline-bot -c user.email=bot@x commit -m $Message @pathArgs 2>&1
  } else {
    & git -C $Work commit -m $Message @pathArgs 2>&1
  }
  $after = (@(& git -C $Work rev-parse HEAD) -join '').Trim()
  return [pscustomobject]@{ Landed = ($after -ne $before); Text = ((@($out) | ForEach-Object { [string]$_ }) -join "`n") }
}

function Try-CommitFile {
  <# Same as Try-Commit but ships the message as a FILE with -F, which is the estate's own rule
     (an inline -m executes backticks) and the only path on which a BOM can reach a subject. #>
  param([string]$Work, [string]$MsgPath)
  $before = (@(& git -C $Work rev-parse HEAD) -join '').Trim()
  $out = & git -C $Work commit -F $MsgPath 2>&1
  $after = (@(& git -C $Work rev-parse HEAD) -join '').Trim()
  return [pscustomobject]@{ Landed = ($after -ne $before); Text = ((@($out) | ForEach-Object { [string]$_ }) -join "`n") }
}

try {
  # ---- MUST FIRE: the pipeline identity staging a source file ----------------------------------------
  $w = New-HookRepo
  'x' | Set-Content (Join-Path $w 'grocery\out\regular\day2.json')
  'notes' | Set-Content (Join-Path $w 'design\PLAN-x.md')
  & git -C $w add -A -- 'grocery/out/regular/day2.json' 'design/PLAN-x.md' | Out-Null
  $c = Try-Commit -Work $w -AsBot
  T 'MUST FIRE  a bot-authored commit staging an unowned path is REFUSED' (-not $c.Landed) 'the commit landed'
  T 'MUST FIRE  and the refusal NAMES the offending path' ($c.Text -match 'design/PLAN-x\.md') $c.Text

  # ---- CLEAN TWIN 1: the same staged set, committed by a person --------------------------------------
  # A person committing a design doc is ordinary work. If the scope arm fired here it would be uninstalled
  # within a day, which is the real failure mode of a gate that is right too often.
  $w2 = New-HookRepo
  'x' | Set-Content (Join-Path $w2 'grocery\out\regular\day2.json')
  'notes' | Set-Content (Join-Path $w2 'design\PLAN-x.md')
  & git -C $w2 add -A -- 'grocery/out/regular/day2.json' 'design/PLAN-x.md' | Out-Null
  $c2 = Try-Commit -Work $w2
  T 'CLEAN TWIN the identical staged set from a SESSION author is allowed through' $c2.Landed $c2.Text

  # ---- CLEAN TWIN 2: the bot staging only what it owns ------------------------------------------------
  $w3 = New-HookRepo
  'x' | Set-Content (Join-Path $w3 'grocery\out\regular\day2.json')
  & git -C $w3 add -A -- 'grocery/out/regular/day2.json' | Out-Null
  $c3 = Try-Commit -Work $w3 -AsBot
  T 'CLEAN TWIN the bot staging only pipeline-owned paths commits normally' $c3.Landed $c3.Text

  # ---- THE OTHER ARM IS STILL LIVE: a broken .ps1 is refused whoever commits it ----------------------
  # If this stopped firing, the hook would look installed and be half a hook.
  $w4 = New-HookRepo
  "function f {`r`n  'unclosed" | Set-Content (Join-Path $w4 'ops\broken.ps1')
  & git -C $w4 add -A -- 'ops/broken.ps1' | Out-Null
  $c4 = Try-Commit -Work $w4
  T 'MUST FIRE  a .ps1 that does not parse is still refused by the shape arm (a session author)' `
    (-not $c4.Landed) 'the commit landed'

  # ---- A MISSING CHECKER MUST NOT READ AS A PASS -----------------------------------------------------
  $w5 = New-HookRepo
  Remove-Item (Join-Path $w5 'ops\verify-bot-commit-scope.ps1') -Force
  'x' | Set-Content (Join-Path $w5 'grocery\out\regular\day2.json')
  & git -C $w5 add -A -- 'grocery/out/regular/day2.json' | Out-Null
  $c5 = Try-Commit -Work $w5
  T 'MUST FIRE  a MISSING scope checker refuses the commit rather than reading as clean' `
    ((-not $c5.Landed) -and ($c5.Text -match 'verify-bot-commit-scope')) $c5.Text

  # ---- THE THIRD ARM: A MATCHING-RULE CHANGE MUST BE REVIEWED (2026-09-07, Brad ruling 8) -------------
  # The founding case is 2026-09-06 commit b28788fa: six commodities' rules changed at 05:45, committed
  # with no soundness accept and no guards, and the board stopped by 08:14.
  $w7 = New-HookRepo
  '[{"id":"x","include":["x"],"exclude":[]}]' | Set-Content (Join-Path $w7 'grocery\commodities.json')
  & git -C $w7 add -A -- 'grocery/commodities.json' | Out-Null
  $c7 = Try-Commit -Work $w7
  T 'MUST FIRE  a staged commodities.json with no reviewed baseline is REFUSED (the b28788fa shape)' `
    ((-not $c7.Landed) -and ($c7.Text -match 'commodities-gate')) $c7.Text

  # MUST NOT FIRE: the checker being GONE must refuse too, never read as clean - the same rule the two
  # arms above already carry, and the reason this file exists at all.
  $w8 = New-HookRepo
  Remove-Item (Join-Path $w8 'ops\verify-commodities-gate.ps1') -Force
  'x' | Set-Content (Join-Path $w8 'grocery\out\regular\day2.json')
  & git -C $w8 add -A -- 'grocery/out/regular/day2.json' | Out-Null
  $c8 = Try-Commit -Work $w8
  T 'MUST FIRE  a MISSING commodities gate refuses the commit rather than reading as clean' `
    ((-not $c8.Landed) -and ($c8.Text -match 'verify-commodities-gate')) $c8.Text

  # CLEAN TWIN: a commit that stages NO rule input is untouched by the new arm. Without this the gate
  # would be indistinguishable from one that simply refuses everything.
  $w9 = New-HookRepo
  'x' | Set-Content (Join-Path $w9 'design\PLAN-y.md')
  & git -C $w9 add -A -- 'design/PLAN-y.md' | Out-Null
  $c9 = Try-Commit -Work $w9
  T 'CLEAN TWIN a commit staging no matching-rule input still commits normally' $c9.Landed $c9.Text

  # ---- THE COMMIT-MSG ARM: A BOM MUST NOT REACH A SUBJECT (2026-09-07, item 16) --------------------
  # Commit 79c62b0f0's subject starts EF BB BF, from PS 5.1's `Set-Content -Encoding utf8`. It is
  # pushed and stays as it is; this is the forward-looking half. A pre-commit hook CANNOT see the
  # message being written (COMMIT_EDITMSG still holds the previous commit's text), so this arm is a
  # commit-msg hook, which receives the real message path as $1.
  $wm1 = New-HookRepo
  'x' | Set-Content (Join-Path $wm1 'grocery\out\regular\day2.json')
  & git -C $wm1 add -A -- 'grocery/out/regular/day2.json' | Out-Null
  $mb = Join-Path $wm1 'msg-bom.txt'
  'A subject that would carry a BOM' | Set-Content -LiteralPath $mb -Encoding UTF8
  $cm1 = Try-CommitFile -Work $wm1 -MsgPath $mb
  T 'MUST FIRE  a commit message file with a UTF-8 BOM is REFUSED (the 79c62b0f0 shape)' `
    ((-not $cm1.Landed) -and ($cm1.Text -match 'BOM')) $cm1.Text

  # CLEAN TWIN - the identical message written BOM-less lands. Without this the arm could be refusing
  # every -F commit and would still pass the case above.
  $wm2 = New-HookRepo
  'x' | Set-Content (Join-Path $wm2 'grocery\out\regular\day2.json')
  & git -C $wm2 add -A -- 'grocery/out/regular/day2.json' | Out-Null
  $mc = Join-Path $wm2 'msg-clean.txt'
  [IO.File]::WriteAllText($mc, "A subject that would carry a BOM`n", (New-Object Text.UTF8Encoding($false)))
  $cm2 = Try-CommitFile -Work $wm2 -MsgPath $mc
  T 'CLEAN TWIN a BOM-less message file commits normally' $cm2.Landed $cm2.Text

  # CLEAN TWIN - the TOOL and the CHECK agree. A helper whose own output the hook refuses is worse
  # than no helper, because it teaches people that the hook is broken.
  $wm3 = New-HookRepo
  'x' | Set-Content (Join-Path $wm3 'grocery\out\regular\day2.json')
  & git -C $wm3 add -A -- 'grocery/out/regular/day2.json' | Out-Null
  $mh = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $wm3 'ops\new-commit-message.ps1') -Body "Written by the helper`n`nBody." -Path (Join-Path $wm3 'msg-helper.txt')
  $cm3 = Try-CommitFile -Work $wm3 -MsgPath ([string]$mh)
  T 'CLEAN TWIN ops\new-commit-message.ps1 output is accepted by the hook (tool and check agree)' $cm3.Landed $cm3.Text

  # ---- A CHECKER RUN FROM A LINKED WORKTREE CANNOT REACH THE SHARED REPOSITORY (2026-09-11) ---------------
  # Measured on git 2.54: a commit from a LINKED worktree hands this hook GIT_DIR=<main>\.git\worktrees\<name>, the
  # main checkout hands it none, and inside the hook `git -C <temp> config user.name X` wrote X into the MAIN
  # config - the pre-push incident of 2026-09-10, in the other hook. The hook now unsets the repository location and
  # KEEPS GIT_INDEX_FILE. The stub stands in for a checker that builds a temp repo on its live path; it replaces
  # verify-commodities-gate in the checkout only, unstaged, so the other two arms still run for real.
  $probeStub = @'
$t = Join-Path $env:TEMP ('hookprobe-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = & git init -q $t 2>$null
$null = & git -C $t config user.name CheckerProbeWrote 2>$null
[IO.File]::WriteAllText($env:TC_PRECOMMIT_PROBE_OUT, $t)
exit 0
'@
  $utf8NoBom = New-Object Text.UTF8Encoding($false)
  function New-LinkedWorktree([string]$Main) {
    $wl = Join-Path $env:TEMP ('hookwt-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    [void]$made.Add($wl)
    # Production carries it, and 5f16140f7 found the bare-repo half of the incident depends on it.
    & git -C $Main config extensions.worktreeConfig true
    & git -C $Main worktree add -q --detach $wl 2>$null | Out-Null
    return $wl
  }
  function Read-ProbeTarget([string]$OutFile) {
    <# The temp repo the stub built and the user.name in its own config. The temp repo is queued for removal. #>
    $t = if (Test-Path -LiteralPath $OutFile) { ([IO.File]::ReadAllText($OutFile)).Trim() } else { '' }
    if ($t) { [void]$made.Add($t) }
    $cfg = if ($t) { Join-Path $t '.git\config' } else { '' }
    $nm = if ($cfg -and (Test-Path -LiteralPath $cfg)) { (@(& git config --file $cfg user.name) -join '').Trim() } else { '' }
    return [pscustomobject]@{ Path = $t; Name = $nm }
  }

  $wl0 = New-HookRepo
  $wl = New-LinkedWorktree $wl0
  [IO.File]::WriteAllText((Join-Path $wl 'ops\verify-commodities-gate.ps1'), $probeStub, $utf8NoBom)
  $probeOut = Join-Path $env:TEMP ('hookprobe-out-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.txt')
  [void]$made.Add($probeOut)
  $env:TC_PRECOMMIT_PROBE_OUT = $probeOut
  New-Item -ItemType Directory -Force (Join-Path $wl 'design') | Out-Null   # an empty directory is not checked out
  'x' | Set-Content (Join-Path $wl 'design\PLAN-z.md')
  & git -C $wl add -- 'design/PLAN-z.md' | Out-Null
  $cl = Try-Commit -Work $wl
  $mainName = (@(& git config --file (Join-Path $wl0 '.git\config') user.name) -join '').Trim()
  $mainBare = (@(& git config --file (Join-Path $wl0 '.git\config') core.bare) -join '').Trim()
  $pt = Read-ProbeTarget $probeOut
  T 'MUST FIRE  a checker the hook runs from a LINKED worktree cannot write the main repo config (user.name, core.bare)' `
    (($mainName -eq 'Session') -and ($mainBare -eq 'false')) "user.name=$mainName core.bare=$mainBare"
  T 'CLEAN TWIN that checker''s temp-repo write lands in the temp repo it named, so the case above is not vacuous' `
    ($pt.Name -eq 'CheckerProbeWrote') "target=$($pt.Path) user.name=$($pt.Name)"
  T 'CLEAN TWIN and the commit from the linked worktree still lands' $cl.Landed $cl.Text

  # CLEAN TWIN: the same stubbed checker from the MAIN checkout, where git exports no GIT_DIR, still runs.
  $wm0 = New-HookRepo
  [IO.File]::WriteAllText((Join-Path $wm0 'ops\verify-commodities-gate.ps1'), $probeStub, $utf8NoBom)
  $probeOut2 = Join-Path $env:TEMP ('hookprobe-out-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.txt')
  [void]$made.Add($probeOut2)
  $env:TC_PRECOMMIT_PROBE_OUT = $probeOut2
  'x' | Set-Content (Join-Path $wm0 'design\PLAN-z.md')
  & git -C $wm0 add -- 'design/PLAN-z.md' | Out-Null
  $cm = Try-Commit -Work $wm0
  $pt2 = Read-ProbeTarget $probeOut2
  T 'CLEAN TWIN the same stubbed checker still runs from the MAIN checkout, and that commit lands' `
    (($pt2.Name -eq 'CheckerProbeWrote') -and $cm.Landed) "user.name=$($pt2.Name) $($cm.Text)"

  # MUST FIRE: A PARTIAL COMMIT FROM A LINKED WORKTREE IS STILL JUDGED. `git commit -- <path>` commits through a
  # private index named to the hook only by GIT_INDEX_FILE; the on-disk index does not hold the change.
  # WHY THE ASSERTION READS THE NAME, measured by mutation on 2026-09-11: a hook that unset GIT_INDEX_FILE too did
  # NOT let this commit land. verify-bulk-edit saw an empty staged set, answered "BLIND: no modified tracked files
  # to verify", and the hook refused - this commit for the wrong reason, and EVERY partial commit with it. A
  # refusal alone therefore proves nothing about the index; a refusal that NAMES the file does, because only a
  # checker reading the private index can know it.
  $wp0 = New-HookRepo
  $wp = New-LinkedWorktree $wp0
  "function f {`r`n  'unclosed" | Set-Content (Join-Path $wp 'ops\new-commit-message.ps1')
  $cp = Try-Commit -Work $wp -Paths @('ops/new-commit-message.ps1')
  T 'MUST FIRE  a PARTIAL commit (git commit -- <path>) of an unparseable .ps1 from a linked worktree is refused BY NAME' `
    ((-not $cp.Landed) -and ($cp.Text -match 'new-commit-message\.ps1') -and ($cp.Text -notmatch 'BLIND')) $cp.Text
  # CLEAN TWIN: a partial commit of a data file from the same kind of checkout lands. This is the case that catches
  # the fail-closed half of the mutation above, where every partial commit is refused.
  $wq0 = New-HookRepo
  $wq = New-LinkedWorktree $wq0
  'changed' | Set-Content (Join-Path $wq 'grocery\out\regular\day1.json')   # reach-fixture-ok: the seed file of a %TEMP% hook repo, never this repo's grocery\out
  $cq = Try-Commit -Work $wq -Paths @('grocery/out/regular/day1.json')   # reach-fixture-ok: the same %TEMP% seed file, committed by path
  T 'CLEAN TWIN a PARTIAL commit of a data file from a linked worktree still lands' $cq.Landed $cq.Text

  # ---- --no-verify IS STILL THE LOUD BYPASS ----------------------------------------------------------
  # It is deliberate, and audit-hook-installed asserts the hook is present so skipping it is a choice.
  $w6 = New-HookRepo
  'x' | Set-Content (Join-Path $w6 'grocery\out\regular\day2.json')
  'notes' | Set-Content (Join-Path $w6 'design\PLAN-x.md')
  & git -C $w6 add -A | Out-Null
  $b6 = (@(& git -C $w6 rev-parse HEAD) -join '').Trim()
  & git -C $w6 -c user.name=smp-pipeline-bot -c user.email=bot@x commit --no-verify -q -m bypass 2>&1 | Out-Null
  $a6 = (@(& git -C $w6 rev-parse HEAD) -join '').Trim()
  T 'CLEAN TWIN --no-verify is still the stated bypass (a gate with no escape hatch gets uninstalled)' `
    ($a6 -ne $b6) 'the bypass did not work'

  Write-Output ''
  Write-Output ("SELFTEST: {0}/{1} pass" -f ($n - $bad), $n)
  Write-Output ("PRECOMMIT-HOOK-COMPLETE cases={0} failed={1}" -f $n, $bad)
  if ($bad) { exit 1 }
  exit 0
} finally {
  Remove-Item -LiteralPath 'Env:\TC_PRECOMMIT_PROBE_OUT' -ErrorAction SilentlyContinue
  foreach ($d in $made) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
}
