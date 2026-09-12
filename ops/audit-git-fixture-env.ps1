<#
  audit-git-fixture-env.ps1 - a script that builds a temp git repo clears the repository environment first.

  WHY THIS EXISTS (2026-09-11). On 2026-09-10 a push from a LINKED worktree ran the gate with GIT_DIR exported,
  and seven git-using self-tests failed and wrote the SHARED .git\config instead of their own temp repos':
  core.bare=true, user.name=Session, user.email=t@t, core.autocrlf=false. `git status` then failed in every
  checkout on the box until the config was repaired by hand. GIT_DIR overrides -C, so under a hook
  `git -C <temp> config user.name X` is not about <temp> at all. That morning's fix (5f16140f7) cleared the
  variables in the pre-push hook and in run-gates, and wrote the rule for the NEXT fixture into
  .claude\rules\ops-and-gates.md. The fixtures already in the tree were not swept: on 2026-09-11 eleven scripts
  ran `git init`, two cleared all eight variables, one cleared three, and eight cleared none.

  WHY A GATE AT THE FIXTURE LAYER WHEN TWO LAYERS ABOVE IT ARE FIXED. pre-push unsets the variables and run-gates
  clears them, so a GATED run is safe. A fixture is also run by hand, by grocery\test-auditors.ps1, and by whatever
  the next hook spawns - and pre-commit cannot clear GIT_INDEX_FILE at all, because its checkers judge the staged
  set through it (measured 2026-09-11: `.git/index`, or a lock file for `commit -a` and `commit -- <paths>`).
  Under that hook a temp-repo `git -C <temp> add` writes the index of the commit being made. The fixture is the
  only layer present on every one of those paths.

  THE RULE. A .ps1 whose code runs `git init` calls Clear-TcGitRepoEnv from lib\git-repo-env.ps1. Why that is a
  scrub and not a refusal is recorded in the library's header.

  SCOPE OF A CLEAN REPORT: UNSOUND. `git init` is matched as text, in two spellings: a `git` command with an
  `init` argument on the same line, and a Git-named wrapper handed a quoted 'init' (audit-memory-backup's
  Get-GitOut). A wrapper with another name (test-prepush-hook's `G init`), a command assembled from a string, a
  temp repo made by `git clone`, and .py or .sh files are not seen; on 2026-09-11 no .py, .sh or clone in the tree
  built one. It checks the call is PRESENT in the file, not that it runs before the first init. \out\, \archive\
  and worktrees below the root are not scanned - run-gates' own discovery exclusions. A reported finding is real.

  Exit 0 clean, 1 a script builds a repo without clearing, 2 self-test regression, 3 BLIND (no scripts, or no
  script that builds a repo - the matcher broken, not the tree clean).
#>
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop (2026-09-07)
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\tree-walk.ps1')     # Get-TcPathBelowRoot: exclusions match below the root, so a worktree root is scanned
. (Join-Path $repo 'lib\ps-source.ps1')     # Get-PsCodeOnly: prose about the call is not the call
. (Join-Path $repo 'lib\git-repo-env.ps1')  # Clear-TcGitRepoEnv, driven for real by the self-test

# The two spellings the header names. A `git` token (line start, or after whitespace & ( ; |) with a standalone
# `init` later on the same line; or a Git-named function handed a quoted 'init'.
$script:GitInitRx = @(
  '(?i)(?:^|[\s&(;|])git(?:\.exe)?\s[^\r\n]*?(?<![\w.-])init(?![\w.-])',
  '(?i)\bGit\w*\s+[^\r\n]*?[''"]init[''"\s]'
)
# A CALL, not the definition: the library defines the function and must not count as calling it.
$script:ClearCallRx = '(?<!function\s+)\bClear-TcGitRepoEnv\b'

function Get-GitFixtureEnvState {
  <# Pure over one file's text, so the self-test drives the rule the live scan uses. Builds = the code runs
     `git init`; Clears = the code calls Clear-TcGitRepoEnv; Line = the first init line, TRIMMED TEXT rather than a
     number, because Get-PsCodeOnly drops whole-line comments and a number would not open the right line. #>
  param([string]$Text)
  $code = Get-PsCodeOnly -Text $Text
  $initLine = ''
  foreach ($l in ($code -split "`n")) {
    if (($l -match $script:GitInitRx[0]) -or ($l -match $script:GitInitRx[1])) { $initLine = $l.Trim(); break }
  }
  return [pscustomobject]@{ Builds = [bool]$initLine; Clears = [bool]($code -match $script:ClearCallRx); Line = $initLine }
}

function Get-GitFixtureScripts {
  <# Every .ps1 under $RootDir except $Self, excluded on the path BELOW the root (lib\tree-walk.ps1). The extension
     is checked as well as filtered: a three-letter -Filter also matches longer extensions on Windows. #>
  param([string]$RootDir, [string]$Self = '')
  $rootFull = Get-TcRootFull $RootDir
  $exclude = '\\worktrees\\|\\archive\\|node_modules|\\\.venv\\|\\\.git\\|\\out\\'
  Get-TcTreeFiles -RootFull $rootFull -Filter *.ps1 -PruneBelow $exclude |
    Where-Object { $_.Extension -ieq '.ps1' -and $_.FullName -ne $Self -and
                   (Get-TcPathBelowRoot $_.FullName $rootFull) -notmatch $exclude } |
    Sort-Object FullName
}

if ($SelfTest) {
  # This self-test builds temp repos, so it obeys its own rule before anything else.
  Clear-TcGitRepoEnv
  $ErrorActionPreference = 'Continue'
  $fail = 0; $cases = 0
  function T([string]$m, [bool]$c, [string]$got = '') {
    $script:cases++
    if ($c) { Write-Output ('  ok    ' + $m) } else { Write-Output ('  FAIL  ' + $m + '   got: ' + $got); $script:fail++ }
  }
  # NEEDLES ARE ASSIGNED BEFORE THE CALL, split so this file's own source never spells the thing it looks for.
  $clear = 'Clear-TcGit' + 'RepoEnv'
  $t1 = '  & git -C $w in' + 'it -q -b main .'
  $t2 = '    $null = Get-GitOut $fx ''in' + 'it'''
  $t3 = '    git in' + 'it -q 2>$null | Out-Null'

  # ---- the spellings the tree actually carried on 2026-09-11 ----
  $s = Get-GitFixtureEnvState -Text $t1
  T 'MUST FIRE  git -C <temp> init with no clear is a finding (ops\test-precommit-hook.ps1, one of the seven of 2026-09-10)' ($s.Builds -and -not $s.Clears) ("builds=$($s.Builds) clears=$($s.Clears)")
  $s = Get-GitFixtureEnvState -Text $t2
  T 'MUST FIRE  a Git-named wrapper handed a quoted init is the same call (ops\audit-memory-backup.ps1)' ($s.Builds -and -not $s.Clears) ("builds=$($s.Builds) clears=$($s.Clears)")
  $s = Get-GitFixtureEnvState -Text $t3
  T 'MUST FIRE  a bare git init in the current directory (check-uncommitted-source.ps1)' ($s.Builds -and -not $s.Clears) ("builds=$($s.Builds) clears=$($s.Clears)")
  $tComment = '# ' + $clear + ' is called somewhere else' + "`n" + $t1
  $s = Get-GitFixtureEnvState -Text $tComment
  T 'MUST FIRE  the clear named only in a COMMENT does not count as calling it' ($s.Builds -and -not $s.Clears) ("builds=$($s.Builds) clears=$($s.Clears)")
  $tDefine = 'function ' + $clear + ' { }' + "`n" + $t1
  $s = Get-GitFixtureEnvState -Text $tDefine
  T 'MUST FIRE  DEFINING the function is not calling it' ($s.Builds -and -not $s.Clears) ("builds=$($s.Builds) clears=$($s.Clears)")

  $tFixed = '. (Join-Path $repo ''lib\git-repo-env.ps1''); ' + $clear + "`n" + $t1
  $s = Get-GitFixtureEnvState -Text $tFixed
  T 'MUST NOT FIRE  the same init in a file that calls the clear is not a finding' (-not ($s.Builds -and -not $s.Clears)) ("builds=$($s.Builds) clears=$($s.Clears)")
  T 'CLEAN TWIN  that file is still COUNTED as one that builds a repo, so the live denominator includes it' ($s.Builds) ("builds=$($s.Builds)")
  T 'CLEAN TWIN  the reported line is the init line itself, trimmed' ($s.Line -eq $t1.Trim()) $s.Line
  $tProse = '# ' + 'git in' + 'it here once' + "`n" + "<#`n  " + 'git in' + "it in a header`n#>`n" + '$x = 1'
  $s = Get-GitFixtureEnvState -Text $tProse
  T 'MUST NOT FIRE  git init in a line comment or a block header is prose, not a call' (-not $s.Builds) ("builds=$($s.Builds)")
  $tNoGit = '  Exit-Guard -Name ''hunt-run'' -Summary ("in' + 'it {0}" -f $runId) -Code 0'
  $s = Get-GitFixtureEnvState -Text $tNoGit
  T 'MUST NOT FIRE  init on a line with no git on it (meal-prep\pipeline\hunt-run.ps1)' (-not $s.Builds) ("builds=$($s.Builds)")
  $tFlag = '& git submodule update --in' + 'it'
  $s = Get-GitFixtureEnvState -Text $tFlag
  T 'MUST NOT FIRE  --init is a flag of another command, not git init' (-not $s.Builds) ("builds=$($s.Builds)")
  $s = Get-GitFixtureEnvState -Text '& git -C $c config core.autocrlf false | Out-Null'
  T 'MUST NOT FIRE  a git config call builds no repo' (-not $s.Builds) ("builds=$($s.Builds)")
  $s = Get-GitFixtureEnvState -Text '$__gitBlobSelfTest = ($args -contains ''-SelfTest'')'
  T 'MUST NOT FIRE  a variable whose name contains git is not the git command' (-not $s.Builds) ("builds=$($s.Builds)")

  $sb = Join-Path $env:TEMP ('tc-gitfixenv-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  $utf8 = New-Object Text.UTF8Encoding($false)
  $envLib = Join-Path $repo 'lib\git-repo-env.ps1'
  try {
    $null = New-Item -ItemType Directory -Force $sb
    # ---- THE LIBRARY, in a child process so this process's environment is never the one being edited ----
    $childEnv = Join-Path $sb 'child-env.ps1'
    [IO.File]::WriteAllText($childEnv, @'
param([string]$Lib)
$env:GIT_DIR = 'X:\nowhere\.git'; $env:GIT_INDEX_FILE = 'X:\nowhere\index'; $env:GIT_WORK_TREE = 'X:\nowhere'
$env:GIT_EDITOR = 'kept'
. $Lib
Clear-TcGitRepoEnv
Write-Output ('dir=' + [string]$env:GIT_DIR + '|index=' + [string]$env:GIT_INDEX_FILE + '|tree=' + [string]$env:GIT_WORK_TREE + '|editor=' + [string]$env:GIT_EDITOR)
'@, $utf8)
    $o = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $childEnv -Lib $envLib)
    $o = ($o -join '').Trim()
    T 'MUST FIRE  Clear-TcGitRepoEnv removes GIT_DIR, GIT_INDEX_FILE and GIT_WORK_TREE' ($o -like 'dir=|index=|tree=|*') $o
    T 'CLEAN TWIN  and keeps GIT_EDITOR, which describes the command rather than the repository' ($o -like '*|editor=kept') $o

    # ---- THE PROPERTY, END TO END: a linked worktree's GIT_DIR inherited, a temp repo, a config write ----
    $main = Join-Path $sb 'main'; $linked = Join-Path $sb 'linked'
    $null = & git init -q $main 2>$null
    $null = & git -C $main config user.name orig 2>$null
    $null = & git -C $main config user.email t@t 2>$null
    $null = & git -C $main config commit.gpgsign false 2>$null
    # Production carries it (5f16140f7 found the bare-repo half depends on it), so the sandbox does too.
    $null = & git -C $main config extensions.worktreeConfig true 2>$null
    $null = & git -C $main commit -q --allow-empty -m seed 2>$null
    $null = & git -C $main worktree add -q --detach $linked 2>$null
    $linkedGitDir = [string](@(& git -C $linked rev-parse --absolute-git-dir 2>$null) | Select-Object -Last 1)
    $cfg = Join-Path $main '.git\config'
    $childWrite = Join-Path $sb 'child-write.ps1'
    [IO.File]::WriteAllText($childWrite, @'
param([string]$Lib, [string]$GitDir, [string]$Temp, [string]$Clear)
$env:GIT_DIR = $GitDir
if ($Clear -eq 'yes') { . $Lib; Clear-TcGitRepoEnv }
$null = & git init -q $Temp 2>$null
$null = & git -C $Temp config user.name FixtureWrote 2>$null
'@, $utf8)
    if (-not $linkedGitDir.Trim() -or -not (Test-Path -LiteralPath $linked)) {
      T 'the end-to-end sandbox could be built (a linked worktree and its gitdir)' $false ("gitdir=" + $linkedGitDir)
    } else {
      # THE CLEARED RUN FIRST, so the sandbox is untouched when it is measured; the control damages it afterwards.
      $tFixedDir = Join-Path $sb 'temp-cleared'
      $null = & powershell -NoProfile -ExecutionPolicy Bypass -File $childWrite -Lib $envLib -GitDir $linkedGitDir -Temp $tFixedDir -Clear yes
      $nameFixed = [string](@(& git config --file $cfg user.name 2>$null) | Select-Object -Last 1)
      $tempCfg = Join-Path $tFixedDir '.git\config'
      $tempName = if (Test-Path -LiteralPath $tempCfg) { [string](@(& git config --file $tempCfg user.name 2>$null) | Select-Object -Last 1) } else { '' }
      T 'MUST FIRE  after the clear, a temp repo built under a linked worktree''s GIT_DIR leaves the main repo identity alone' ($nameFixed -eq 'orig') ("main user.name=" + $nameFixed)
      T 'CLEAN TWIN  and the config write lands in the temp repo it named' ($tempName -eq 'FixtureWrote') ("temp user.name=" + $tempName)
      $null = & powershell -NoProfile -ExecutionPolicy Bypass -File $childWrite -Lib $envLib -GitDir $linkedGitDir -Temp (Join-Path $sb 'temp-control') -Clear no
      $nameCtl = [string](@(& git config --file $cfg user.name 2>$null) | Select-Object -Last 1)
      T 'MUST FIRE  without the clear the same write reaches the main repo - the hazard still exists on this git, so the rule still earns its place' ($nameCtl -eq 'FixtureWrote') ("main user.name=" + $nameCtl)
    }
  } finally {
    if (Test-Path -LiteralPath $sb) { Remove-Item -LiteralPath $sb -Recurse -Force -ErrorAction SilentlyContinue }
  }

  # ---- A WORKTREE ROOT IS SCANNED AND A SIBLING BELOW IT IS NOT (lib\tree-walk.ps1) ----
  $wtFx = New-TcWorktreeFixture -Files @{ 'ops\a.ps1' = 'Write-Output 1'; 'grocery\b.ps1' = 'Write-Output 2' }
  try {
    $found = Get-GitFixtureScripts -RootDir $wtFx.Root
    $found = @($found)
    $hits = Measure-TcWorktreeFixture -Fixture $wtFx -Found $found
    T 'MUST FIRE  a root that IS a worktree is scanned, not excluded whole' ($hits.Root -eq 2) ("root=" + $hits.Root)
    T 'MUST NOT FIRE  a sibling worktree BELOW that root is still excluded' ($hits.Sibling -eq 0) ("sibling=" + $hits.Sibling)
  } finally { Remove-Item -LiteralPath $wtFx.Temp -Recurse -Force -ErrorAction SilentlyContinue }

  ''
  if ($fail) {
    Write-Output ("git-fixture-env selftest: $fail FAILED of $cases")
    Exit-Guard -Name 'GIT-FIXTURE-ENV-SELFTEST' -Code 2 -Summary "failed=$fail of $cases"
  }
  Write-Output ("git-fixture-env selftest: $cases of $cases cases pass")
  Exit-Guard -Name 'GIT-FIXTURE-ENV-SELFTEST' -Code 0 -Summary "cases=$cases"
}

# ---- live path: every .ps1 in the tree ---------------------------------------------------------------
$rootFull = Get-TcRootFull $repo
$files = Get-GitFixtureScripts -RootDir $repo -Self $PSCommandPath
$files = @($files)
if (-not $files.Count) {
  Write-Output 'audit-git-fixture-env: BLIND - found no .ps1 to scan, which means this discovery is broken, not that the tree is clean'
  Exit-Guard -Name 'AUDIT-GIT-FIXTURE-ENV' -Code 3 -Summary 'blind=no-scripts'
}
$builds = 0
$findings = New-Object System.Collections.ArrayList
foreach ($f in $files) {
  $st = Get-GitFixtureEnvState -Text ([IO.File]::ReadAllText($f.FullName))
  if (-not $st.Builds) { continue }
  $builds++
  if (-not $st.Clears) { [void]$findings.Add(((Get-TcPathBelowRoot $f.FullName $rootFull).TrimStart('\') + '   ' + $st.Line)) }
}
# A FLOOR THAT FIRES ON NOTHING HAPPENING (ops-and-gates, backlog I80). A matcher that stopped matching would find no
# script that builds a repo, and "none of them fail to clear" would then be true of nothing. Eleven built one on
# 2026-09-11, so zero is the matcher broken. Zero is the only bar here: any other number would be a band nobody tuned.
if ($builds -eq 0) {
  Write-Output ("audit-git-fixture-env: BLIND - scanned {0} .ps1 and found NO script that runs git init; eleven did on 2026-09-11, so the matcher is broken, not the tree clean" -f $files.Count)
  Exit-Guard -Name 'AUDIT-GIT-FIXTURE-ENV' -Code 3 -Summary ("blind=no-builders scanned={0}" -f $files.Count)
}
Write-Output ("audit-git-fixture-env: {0} .ps1 scanned, {1} run git init, {2} of those never clear the repository environment" -f $files.Count, $builds, $findings.Count)
foreach ($x in $findings) { Write-Output ('  ! ' + $x) }
if ($findings.Count) {
  Write-Output '  Under a hook in a linked worktree GIT_DIR overrides -C, so a temp repo built here writes the SHARED .git:'
  Write-Output '  2026-09-10 turned it bare and set user.name=Session for every checkout on the box.'
  Write-Output '  Fix: dot-source lib\git-repo-env.ps1 and call Clear-TcGitRepoEnv before the first git init - inside the'
  Write-Output '  self-test branch if the file is dot-sourced into a live committer.'
  Exit-Guard -Name 'AUDIT-GIT-FIXTURE-ENV' -Code 1 -Summary ("findings={0} builders={1} scanned={2}" -f $findings.Count, $builds, $files.Count)
}
Exit-Guard -Name 'AUDIT-GIT-FIXTURE-ENV' -Code 0 -Summary ("findings=0 builders={0} scanned={1}" -f $builds, $files.Count)
