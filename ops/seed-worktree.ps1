<#
  seed-worktree.ps1 - copy the gitignored inputs a worktree needs into it.

  WHY THIS EXISTS ALONGSIDE .worktreeinclude (2026-09-06, backlog E7). Claude Code's .worktreeinclude
  is real and it works, and it has one limit that happens to hit the biggest thing we need. It builds
  its candidate list with `git ls-files --others --ignored --exclude-standard --directory`, and that
  COLLAPSES a fully-ignored directory to one entry, then copies each match with copyFile - which cannot
  take a directory. Measured on this repo the same day: grocery/out/ enumerates file by file, because
  something tracked lives under it, while meal-prep/db/built/ collapses to a single line and its 1,168
  files never move. A pattern in .worktreeinclude for that directory reads as solved and copies nothing.

  The second reason is coverage. .worktreeinclude only fires for worktrees Claude Code creates. A plain
  `git worktree add`, a CI clone, or a temp checkout gets nothing from it, and those go blind the same way.

  IT CARRIES BOTH LISTS NOW (2026-09-11). Until then this copied only the DIRECTORIES and left the files
  to .worktreeinclude, which is exactly right for a worktree Claude Code made and exactly wrong for the
  documented gate-check checkout (`git worktree add --detach ... origin/main`), which never sees
  .worktreeinclude at all. Measured at f6c8b46c0: seeded that way, run-gates still failed find-similar
  and make-saturation on a missing meal-prep\pipeline\catalog-digest.json - a file LISTED in
  .worktreeinclude that nothing copied. So this reads .worktreeinclude as the single source for the
  files, and keeps $SEED_DIRS for the directories it cannot carry. The list is never duplicated here.

  THE SOURCE IS THE MAIN CHECKOUT, WHEREVER THIS COPY RUNS (2026-09-11). The default source used to be the
  checkout this script lives in, so the copy inside a worktree seeded that worktree from itself, found no
  db\built and no digest there, and exited 2 unless -Source named main - a rule nobody remembers at the
  moment it is needed. Every linked worktree shares the main checkout's .git, so the default is now the
  parent of `git rev-parse --path-format=absolute --git-common-dir`. The ABSOLUTE form is not optional:
  from the main checkout the plain form answers `.git`, and from a subdirectory `../.git` (measured). A
  repository whose common dir is not a `.git` folder - bare, or a --separate-git-dir clone - names no main
  checkout and is refused (exit 3). -Source still overrides, for a clone with no linked main.

  HOW A PATTERN BECOMES FILES: git does the matching, not this file. Each pattern goes to
  `git ls-files --others --ignored --exclude=<pattern>` in the SOURCE checkout, which applies real
  gitignore semantics (anchoring, `*` not crossing a slash, `**`) and lists only untracked files - so a
  TRACKED file that happens to match is left out, the same eligibility rule Claude Code applies.
  Measured 2026-09-11: the board glob in .worktreeinclude is 37 files on disk and 36 from git, because
  comparison-2026-08-08.json is tracked and already in every checkout. A pattern that matches NOTHING
  in the source is MISSING-SOURCE and reaches the exit code, like a missing directory.
  `!` negation lines are REFUSED (exit 3), because resolving one pattern at a time cannot honour them
  and silently ignoring a negation would copy what it was written to exclude.

  WHAT IT DELIBERATELY DOES NOT SEED: sidecar\.venv. start-sidecar's self-test asserts the venv
  interpreter exists and a checkout without one used to fail it. A directory junction to the source's
  venv makes that pass, and was rejected (2026-09-11) for three reasons:
    1. It breaks this file's own contract, never write the source checkout. A junction is a write path
       back into it: any Python run from that venv in the target compiles __pycache__ into the SOURCE's
       site-packages, and a pip install there changes the source's interpreter.
    2. Cleanup becomes riskier. As first written here: `Remove-Item -Recurse` on a checkout holding a
       junction walks into the target and deletes the real venv (torch and sentence-transformers, a long
       rebuild). MEASURED 2026-09-11 against sandbox victims on Windows PowerShell 5.1.26100.9444, it did
       NOT: eleven recursive deletes aimed at a junction or at its parent - Remove-Item with -Path and with
       -LiteralPath, with and without -Force, fed from Get-ChildItem; `rm -r -fo`; `cmd /c rmdir /s /q`;
       Git's `rm -rf` - all left the target intact. It may still hold on another build or for a symbolic
       link, and nobody has measured either. What WAS measured is the trap beside it: `git worktree
       remove`, plain and --force, exits 0 and LEAVES THE DIRECTORY behind with the junction still inside,
       handing the cleanup to whatever delete somebody reaches for next. So this reason is weaker than it
       was written, and reasons 1 and 3 decide the question on their own.
    3. It proves nothing about the change under test. The venv is environment, not code; seeding it
       turns a check that CANNOT LOOK into one that looks at a different checkout and reports on it.
  So start-sidecar now reports that case BLIND in a checkout that has no venv of any name, and still
  FAILS when a venv exists somewhere the launcher does not look, which is the rot the case was written
  for. run-gates prints every BLIND case it sees, so a green run cannot hide one.

  WHAT BLIND LOOKS LIKE HERE, since it is not loud. A worktree at 2fdb99cf ran ops\run-gates.ps1 and
  failed six self-tests that pass in the main checkout. Four were missing data. The other two
  (golden-test, ghost-drift) were the CRLF condition in [[fresh-checkout-is-crlf-main-is-lf]] and no copy
  changes that. The engines are worse than the gate: cost-recipes with no board prices nothing and exits 0.

  Usage:  powershell -File ops\seed-worktree.ps1 -Target <path-to-checkout>
                    (from ANY checkout - main, a worktree, a branch that changes this file: the data is
                     read from the main checkout git names, so -Source is not needed)
          powershell -File ops\seed-worktree.ps1 -Target <path> -Source <checkout>
                    (read the data from a checkout git cannot name - a clone with no linked main)
          powershell -File ops\seed-worktree.ps1 -Target <path> -WhatIf     (rehearse, copy nothing)

  The lists ($SEED_DIRS and .worktreeinclude) are always read from the checkout this script lives in, so
  the code and the list it reads travel together. The source changes only where the bytes come from.

  EXIT CODES (lib\guard-contract.ps1 vocabulary): 0 done, 2 something could not be copied,
  3 could-not-evaluate. Read the verdict LINE, not the number (backlog E2).
#>
param(
  [string]$Target = '',
  [string]$Source = '',
  [switch]$WhatIf,
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
# NO REPOSITORY ENVIRONMENT IS INHERITED. Every git call here names its checkout with -C, and an inherited
# GIT_DIR overrides -C: spawned from a hook in a linked worktree, `git -C <source> ls-files` would list the
# hook's repository instead, and the self-test's temp repo would be written into the shared .git. Same list
# and same reason as ops\run-gates.ps1 (2026-09-10), and since 2026-09-11 the same library.
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\ops' }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\git-repo-env.ps1')
Clear-TcGitRepoEnv
. (Join-Path $repo 'lib\guard-contract.ps1')

# THE DIRECTORIES .worktreeinclude CANNOT CARRY. Each line names the self-test it fixes, because a line
# whose reason nobody can state is a line nobody can delete. Individual FILES belong in
# .worktreeinclude, not here - this script reads that file, so listing one here too would be a second copy.
$SEED_DIRS = @(
  @{ p = 'meal-prep\db\built'
     why = 'feed-covers-published parses a real built card; wave-preaudit''s end-to-end drill needs a live spec and a reference card. 47 MB, 1,168 files.' }
)
$INCLUDE_FILE = '.worktreeinclude'

function Get-SeedPlan {
  <# Pure, so the self-test drives it with synthetic paths instead of resting on today's disk. Returns
     one row per seed entry saying what would happen and why. A seed carrying nohit=$true is a
     .worktreeinclude pattern that matched nothing in the source, and is MISSING-SOURCE whatever the
     predicate says about its literal spelling. #>
  param(
    [object[]]$Seeds,
    [string]$SourceRoot,
    [string]$TargetRoot,
    [scriptblock]$Exists,
    # HOW MANY FILES ARE UNDER A PATH, or -1 when it is not a directory. Optional: without it the plan
    # behaves exactly as it did before, which is what every caller that seeds single files wants.
    [scriptblock]$Count = $null
  )
  $plan = @()
  foreach ($s in @($Seeds)) {
    # [IO.Path]::Combine, NOT Join-Path. Join-Path resolves against the PROVIDER and throws
    # "Cannot find drive. A drive with the name 'S' does not exist" on a path this process cannot see -
    # which makes a pure function untestable with synthetic roots, and is how the first version of this
    # self-test died. Combine is string arithmetic and touches no drive.
    $src = [IO.Path]::Combine($SourceRoot, $s.p)
    $dst = [IO.Path]::Combine($TargetRoot, $s.p)
    $srcOk = (-not $s.nohit) -and [bool](& $Exists $src)
    $dstOk = [bool](& $Exists $dst)
    # A DIRECTORY THAT EXISTS IS NOT A DIRECTORY THAT IS SEEDED (2026-09-11). This asked only "is the path
    # there", so a worktree holding 2 of meal-prep\db\built's 1,168 files was reported ALREADY-PRESENT and
    # left half blind. MEASURED that day: a checkout in exactly that state ran seed-worktree, was told
    # "39 already present, copied 0", and then reddened ops\seo_url_inspect.py - whose sample read those two
    # files and could not tell a partial checkout from a full one. Half-seeded is the worst of the three
    # states, because it is the one that looks seeded. With $Count supplied, a destination directory holding
    # FEWER files than the source is PARTIAL and the missing files are copied.
    $action = if (-not $srcOk) { 'MISSING-SOURCE' }
              elseif (-not $dstOk) { 'COPY' }
              elseif ($Count) {
                $sc = [int](& $Count $src)
                $dc = [int](& $Count $dst)
                if ($sc -ge 0 -and $dc -ge 0 -and $dc -lt $sc) { 'PARTIAL' } else { 'ALREADY-PRESENT' }
              } else { 'ALREADY-PRESENT' }
    $plan += [pscustomobject]@{ Path = $s.p; Source = $src; Dest = $dst; Action = $action; Why = $s.why }
  }
  # `,` not @(): a single-element array unrolls on the way out of a function and the caller's .Count
  # then reads a property of the lone object instead. Same trap as ops\audit-stray-root-artifacts.ps1.
  return ,@($plan)
}

function Read-WorktreeInclude {
  <# Pure over the file's TEXT. Returns @{ Patterns = the lines git should match, in order;
     Refused = the `!` lines this resolver cannot honour }. Blank lines and `#` comments are dropped,
     which is what makes a commented-out path NOT a seed. #>
  param([string]$Text)
  $patterns = @(); $refused = @()
  foreach ($raw in ($Text -split "`r?`n")) {
    $line = $raw.Trim()
    if (-not $line -or $line.StartsWith('#')) { continue }
    if ($line.StartsWith('!')) { $refused += $line; continue }
    $patterns += $line
  }
  return [pscustomobject]@{ Patterns = @($patterns); Refused = @($refused) }
}

function Get-IncludeSeeds {
  <# Pure given $Lister, which maps one pattern to the source-relative paths it matches (forward slashes,
     as git prints them). One seed per matched FILE, deduplicated across patterns, plus one nohit seed per
     pattern that matched nothing - so an empty match reaches the plan instead of vanishing. #>
  param([string[]]$Patterns, [scriptblock]$Lister)
  $seeds = @(); $seen = @{}
  foreach ($pat in @($Patterns)) {
    $hits = & $Lister $pat
    $hits = @($hits | Where-Object { $_ })
    if (-not $hits.Count) {
      $seeds += @{ p = ($pat -replace '/', '\'); nohit = $true
                   why = ("the .worktreeinclude pattern '{0}' matched no untracked ignored file in the source" -f $pat) }
      continue
    }
    foreach ($h in $hits) {
      $rel = ([string]$h) -replace '/', '\'
      if ($seen.ContainsKey($rel)) { continue }
      $seen[$rel] = $true
      $seeds += @{ p = $rel; why = ("listed in .worktreeinclude as '{0}'" -f $pat) }
    }
  }
  return ,@($seeds)
}

function Get-IgnoredMatches {
  <# The live $Lister: git's own gitignore matcher over the SOURCE checkout. Throws when git fails, so a
     broken resolver is could-not-evaluate and never an empty match. No stderr redirect: under
     EAP=Stop in PS 5.1 that turns a clean exit into a throw. #>
  param([string]$Root, [string]$Pattern)
  $out = & git -C $Root -c core.quotepath=off ls-files --others --ignored ('--exclude=' + $Pattern)
  if ($LASTEXITCODE -ne 0) { throw ("git ls-files exited {0} in {1} for pattern '{2}'" -f $LASTEXITCODE, $Root, $Pattern) }
  return ,@(@($out) | Where-Object { $_ })
}

function Test-SameCheckout {
  <# Pure. Would writing $B write $A? Compared as full paths, case-insensitively, trailing separators
     ignored - `C:\Codex\ThriftyCrew\` and `c:\codex\thriftycrew` are one checkout on this filesystem. #>
  param([string]$A, [string]$B)
  $norm = { param($x) ([IO.Path]::GetFullPath($x)).TrimEnd('\', '/') }
  return [string]::Equals((& $norm $A), (& $norm $B), [StringComparison]::OrdinalIgnoreCase)
}

function Get-SeedSourceRoot {
  <# Pure. The main checkout, from the answer to `git rev-parse --path-format=absolute --git-common-dir`.
     Every linked worktree shares the main checkout's .git, so its parent names the main checkout wherever
     this runs. $null rather than a guess when the answer cannot name a checkout. #>
  param([string]$CommonDir)
  if (-not $CommonDir) { return $null }
  $c = $CommonDir.Trim().Replace('/', '\').TrimEnd('\')
  # RELATIVE IS REFUSED. Resolved against this process's working directory, `.git` or `../.git` would name
  # whatever tree the caller happened to be standing in.
  if (-not $c -or -not [IO.Path]::IsPathRooted($c)) { return $null }
  # A bare repository or a --separate-git-dir clone has a common dir that is not `.git`, and the folder
  # holding it is not a checkout.
  if ([IO.Path]::GetFileName($c) -ine '.git') { return $null }
  return [IO.Path]::GetDirectoryName($c)
}

function Get-MainCheckout {
  <# The live resolver: the main checkout for the checkout at $From, or $null when git cannot name one.
     No stderr redirect, for the reason Get-IgnoredMatches gives. #>
  param([string]$From)
  try {
    $out = & git -C $From rev-parse --path-format=absolute --git-common-dir
    if ($LASTEXITCODE -ne 0) { return $null }
  } catch { return $null }
  return Get-SeedSourceRoot -CommonDir ((@($out) | Where-Object { $_ }) -join '')
}

# ------------------------------------------------------------------------------------- self-test
if ($SelfTest) {
  $f = 0; $cases = 0
  function T($m, $cond, $got) {
    $script:cases++
    if ($cond) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $got); $script:f++ }
  }

  $seeds = @(@{ p = 'a\b'; why = 'x' }, @{ p = 'c'; why = 'y' })
  $S = 'S:\src'; $D = 'D:\dst'

  # MUST FIRE - a source that is there and a destination that is not is the whole point of the script.
  $p1 = Get-SeedPlan -Seeds $seeds -SourceRoot $S -TargetRoot $D -Exists { param($x) $x -like 'S:\*' }
  T 'MUST FIRE  a present source and an absent destination plans a COPY' `
    (@($p1 | Where-Object { $_.Action -eq 'COPY' }).Count -eq 2) (($p1 | ForEach-Object { $_.Action }) -join ',')

  # MUST FIRE - IDEMPOTENCE. Running twice must not re-copy 47 MB, and more importantly must not report
  # work it did not do. A seeder that says COPY over an existing tree is lying about what it changed.
  $p2 = Get-SeedPlan -Seeds $seeds -SourceRoot $S -TargetRoot $D -Exists { param($x) $true }
  T 'MUST FIRE  an already-seeded destination is ALREADY-PRESENT, never a second COPY' `
    (@($p2 | Where-Object { $_.Action -eq 'ALREADY-PRESENT' }).Count -eq 2) (($p2 | ForEach-Object { $_.Action }) -join ',')

  # MUST FIRE - HALF-SEEDED IS THE STATE THAT LOOKS SEEDED (2026-09-11). The plan asked only whether the
  # destination existed, so a worktree holding 2 of the source's 1,168 files was ALREADY-PRESENT and stayed
  # blind. Measured that day: such a checkout ran this script, was told "copied 0, 39 already present", and
  # then reddened a gate whose fixture sampled those two files.
  $shortCount = { param($x) if ($x -like 'S:\*') { 1168 } else { 2 } }
  $pShort = Get-SeedPlan -Seeds $seeds -SourceRoot $S -TargetRoot $D -Exists { param($x) $true } -Count $shortCount
  T 'MUST FIRE  a destination directory holding FEWER files than the source is PARTIAL, never ALREADY-PRESENT' `
    (@($pShort | Where-Object { $_.Action -eq 'PARTIAL' }).Count -eq 2) (($pShort | ForEach-Object { $_.Action }) -join ',')

  # CLEAN TWIN - and a directory that really is complete still copies nothing, so idempotence survives.
  $fullCount = { param($x) 1168 }
  $pFull = Get-SeedPlan -Seeds $seeds -SourceRoot $S -TargetRoot $D -Exists { param($x) $true } -Count $fullCount
  T 'CLEAN TWIN a destination directory with as many files as the source is ALREADY-PRESENT, so a second run still copies nothing' `
    (@($pFull | Where-Object { $_.Action -eq 'ALREADY-PRESENT' }).Count -eq 2) (($pFull | ForEach-Object { $_.Action }) -join ',')

  # MUST NOT FIRE - a FILE seed is not a short directory. The live predicate answers -1 for anything that is
  # not a directory, and a -1 either side must never read as "the target has fewer".
  $fileCount = { param($x) -1 }
  $pFileCnt = Get-SeedPlan -Seeds $seeds -SourceRoot $S -TargetRoot $D -Exists { param($x) $true } -Count $fileCount
  T 'MUST NOT FIRE  a file seed is never PARTIAL - the count predicate answers -1 for anything that is not a directory' `
    (@($pFileCnt | Where-Object { $_.Action -eq 'PARTIAL' }).Count -eq 0) (($pFileCnt | ForEach-Object { $_.Action }) -join ',')

  # MUST FIRE - THE ONE THAT MATTERS. A source that is not there must be MISSING-SOURCE and must reach
  # the exit code, because "seeded nothing because there was nothing to seed" reported as success is
  # exactly the blind-and-green failure this whole file exists to prevent.
  $p3 = Get-SeedPlan -Seeds $seeds -SourceRoot $S -TargetRoot $D -Exists { param($x) $false }
  T 'MUST FIRE  an absent source is MISSING-SOURCE, not a quiet success' `
    (@($p3 | Where-Object { $_.Action -eq 'MISSING-SOURCE' }).Count -eq 2) (($p3 | ForEach-Object { $_.Action }) -join ',')

  # CLEAN TWIN - the mixed case still classifies each row on its own evidence.
  # the source root is joined on, so the predicate must name the FULL path - 'S:\src\a\b', not 'S:\a\b'.
  $p4 = Get-SeedPlan -Seeds $seeds -SourceRoot $S -TargetRoot $D -Exists { param($x) $x -eq 'S:\src\a\b' }
  T 'CLEAN TWIN each row is classified on its own paths, not the batch''s' `
    (($p4[0].Action -eq 'COPY') -and ($p4[1].Action -eq 'MISSING-SOURCE')) (($p4 | ForEach-Object { $_.Action }) -join ',')

  # ARITY - one seed must come back as an array of one.
  $p5 = Get-SeedPlan -Seeds @(@{ p = 'solo'; why = 'z' }) -SourceRoot $S -TargetRoot $D -Exists { param($x) $true }
  T 'a single seed comes back as an ARRAY, not unrolled' ($p5 -is [array]) ($p5.GetType().FullName)

  # ---- the .worktreeinclude FILES (2026-09-11) ----------------------------------------------------
  # Fixture text is a single-quoted literal joined with newlines: never a concatenation passed as an
  # argument, which binds as three arguments ([[ps-concat-in-argument-is-three-args]]).
  # THE GLOB PATHS ARE SYNTHETIC (fx/out/...), NOT the real board path. A literal naming another module's
  # internals is a cross-module reach to ops\audit-cross-module-reach.ps1 even inside a fixture, and the
  # real list is read from .worktreeinclude precisely so this file never has to name it.
  $incText = (@('# a header comment', '', 'meal-prep/pipeline/catalog-digest.json',
                '  # an indented comment', '# old/retired.json', 'fx/out/board-*.json',
                '!fx/out/board-keep.json') -join "`n")
  $inc = Read-WorktreeInclude -Text $incText

  # MUST FIRE - THE FOUNDING BUG. A file listed in .worktreeinclude, present in the source and absent
  # from a `git worktree add` checkout, was never copied: find-similar and make-saturation stayed red.
  $lister1 = { param($pat) if ($pat -eq 'meal-prep/pipeline/catalog-digest.json') { 'meal-prep/pipeline/catalog-digest.json' } }
  $fs1 = Get-IncludeSeeds -Patterns $inc.Patterns -Lister $lister1
  $plan1 = Get-SeedPlan -Seeds $fs1 -SourceRoot $S -TargetRoot $D -Exists { param($x) $x -like 'S:\*' }
  $digestRow = @($plan1 | Where-Object { $_.Path -eq 'meal-prep\pipeline\catalog-digest.json' })
  T 'MUST FIRE  a .worktreeinclude FILE present in the source and absent from the target plans a COPY' `
    (($digestRow.Count -eq 1) -and ($digestRow[0].Action -eq 'COPY')) (($plan1 | ForEach-Object { $_.Path + '=' + $_.Action }) -join ',')

  # MUST FIRE - a pattern that matches NOTHING is MISSING-SOURCE, even though its literal spelling is
  # "present" to the predicate. An include line that quietly resolves to zero files is a blind worktree
  # reported as seeded.
  $globRow = @($plan1 | Where-Object { $_.Path -eq 'fx\out\board-*.json' })
  T 'MUST FIRE  a .worktreeinclude pattern that matches no file in the source is MISSING-SOURCE' `
    (($globRow.Count -eq 1) -and ($globRow[0].Action -eq 'MISSING-SOURCE')) (($plan1 | ForEach-Object { $_.Path + '=' + $_.Action }) -join ',')

  # MUST FIRE - a `!` negation is REFUSED rather than dropped. Dropped, it would copy exactly the file it
  # was written to keep out.
  T 'MUST FIRE  a ! negation line is refused, never silently ignored' `
    (($inc.Refused.Count -eq 1) -and ($inc.Refused[0] -eq '!fx/out/board-keep.json')) ("Refused=" + ($inc.Refused -join '|'))

  # MUST NOT FIRE - comments, indented comments and blank lines are not patterns. A commented-out path
  # that became a seed would copy a file somebody deliberately retired from the list.
  T 'MUST NOT FIRE  blank lines and # comments (a commented-out path included) never become a pattern' `
    (($inc.Patterns.Count -eq 2) -and ($inc.Patterns[0] -eq 'meal-prep/pipeline/catalog-digest.json') -and
     ($inc.Patterns[1] -eq 'fx/out/board-*.json')) ("Patterns=" + ($inc.Patterns -join '|'))

  # MUST NOT FIRE - one file matched by two patterns is ONE seed, so it is copied and counted once.
  $lister2 = { param($pat) 'fx/out/board-2026-09-11.json' }
  $fs2 = Get-IncludeSeeds -Patterns @('fx/out/board-*.json', 'fx/out/*.json') -Lister $lister2
  T 'MUST NOT FIRE  a file matched by two patterns is planned once, not twice' `
    ($fs2.Count -eq 1) ("seeds=" + $fs2.Count)

  # CLEAN TWIN - THE DIRECTORY SEED STILL WORKS BESIDE THE FILES. This change put file rows into the same
  # plan as $SEED_DIRS; the thing it was most likely to break on the way past is the directory copy.
  $allSeeds = @($SEED_DIRS) + @($fs1)
  $plan2 = Get-SeedPlan -Seeds $allSeeds -SourceRoot $S -TargetRoot $D -Exists { param($x) $x -like 'S:\*' }
  $dirSeed = @($SEED_DIRS)[0].p
  $dirRow = @($plan2 | Where-Object { $_.Path -eq $dirSeed })
  T 'CLEAN TWIN the shipped directory seed still plans a COPY alongside the include files' `
    (($dirRow.Count -eq 1) -and ($dirRow[0].Action -eq 'COPY') -and (@($plan2 | Where-Object { $_.Action -eq 'COPY' }).Count -eq 2)) `
    (($plan2 | ForEach-Object { $_.Path + '=' + $_.Action }) -join ',')

  # CLEAN TWIN - idempotence holds for FILE rows too, not only for the directory.
  $plan3 = Get-SeedPlan -Seeds $fs1 -SourceRoot $S -TargetRoot $D -Exists { param($x) $true }
  T 'CLEAN TWIN an include file already in the target is ALREADY-PRESENT' `
    (@($plan3 | Where-Object { $_.Path -eq 'meal-prep\pipeline\catalog-digest.json' -and $_.Action -eq 'ALREADY-PRESENT' }).Count -eq 1) `
    (($plan3 | ForEach-Object { $_.Path + '=' + $_.Action }) -join ',')

  # MUST FIRE - never write the source checkout. The comparison must survive a trailing separator and a
  # case difference, or `-Target C:\Codex\ThriftyCrew\` walks straight past the guard.
  T 'MUST FIRE  a target that is the source spelled with another case and a trailing slash is the SAME checkout' `
    (Test-SameCheckout -A 'C:\Codex\ThriftyCrew' -B 'c:\codex\thriftycrew\') 'Test-SameCheckout said different'
  # CLEAN TWIN - a real gate-check checkout beside the source is still accepted.
  T 'CLEAN TWIN a sibling gate-check checkout is a different checkout' `
    (-not (Test-SameCheckout -A 'C:\Codex\ThriftyCrew' -B 'C:\Codex\tc-gatecheck-x')) 'Test-SameCheckout said same'

  # ---- the SOURCE is the main checkout (2026-09-11) ------------------------------------------------
  # MUST FIRE - THE FOUNDING BUG. The copy of this script inside a worktree took its OWN checkout as the
  # source unless -Source was passed, found no db\built and no digest there, and exited 2. git names the
  # shared common dir from any checkout, and its parent is the main checkout.
  $r1 = Get-SeedSourceRoot -CommonDir 'C:/Codex/ThriftyCrew/.git'
  T 'MUST FIRE  a linked worktree''s common dir names the MAIN checkout as the source' ($r1 -eq 'C:\Codex\ThriftyCrew') $r1
  # MUST NOT FIRE - a RELATIVE answer names nothing. The plain form answers `.git` from the main checkout.
  $r2 = Get-SeedSourceRoot -CommonDir '.git'
  T 'MUST NOT FIRE  a relative common dir names no source' ($null -eq $r2) $r2
  $r3 = Get-SeedSourceRoot -CommonDir 'D:\stores\thriftycrew.git'
  T 'MUST NOT FIRE  a bare or separate git dir names no source, rather than the folder holding it' ($null -eq $r3) $r3
  # CLEAN TWIN - git's raw output still resolves: forward slashes, a trailing separator, the line ending.
  $raw = "C:/Codex/ThriftyCrew/.git/`r`n"
  $r4 = Get-SeedSourceRoot -CommonDir $raw
  T 'CLEAN TWIN git''s raw output, trailing separator and newline included, still names the main checkout' ($r4 -eq 'C:\Codex\ThriftyCrew') $r4

  # ---- the LIVE resolver against a real, throwaway git repository ---------------------------------
  # The pure cases above prove the plan; this proves git is asked the right question. Built in TEMP,
  # never under the repo, and removed in finally ([[test-suites-leak-temp-dirs]]).
  $tmp = Join-Path $env:TEMP ('seed-worktree-selftest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  $tmpWt = $tmp + '-wt'
  try {
    $null = New-Item -ItemType Directory -Force (Join-Path $tmp 'data')
    $null = New-Item -ItemType Directory -Force (Join-Path $tmp 'sub')
    $utf8 = New-Object Text.UTF8Encoding($false)
    # -b main and core.autocrlf=false keep git silent on stderr: an init hint or an "LF will be replaced"
    # warning becomes a terminating error under EAP=Stop when run-gates captures this process's streams.
    & git -C $tmp init -q -b main . | Out-Null
    [IO.File]::WriteAllText((Join-Path $tmp '.gitignore'), "data/*.json`nsub/digest.json`nsub/other.txt`n", $utf8)
    foreach ($n in @('data\a.json', 'data\b.json', 'data\tracked.json', 'sub\digest.json', 'sub\other.txt')) {
      [IO.File]::WriteAllText((Join-Path $tmp $n), '{}', $utf8)
    }
    & git -C $tmp -c core.autocrlf=false -c core.safecrlf=false add -f data/tracked.json .gitignore | Out-Null
    $gitOk = ($LASTEXITCODE -eq 0)
    $g1 = Get-IgnoredMatches -Root $tmp -Pattern 'data/*.json'
    $g1s = @($g1 | Sort-Object)
    T 'MUST FIRE  the git resolver lists every untracked ignored file a glob pattern matches' `
      ($gitOk -and ($g1s -contains 'data/a.json') -and ($g1s -contains 'data/b.json')) ("got=" + ($g1s -join '|'))
    T 'MUST NOT FIRE  a TRACKED file matching the pattern is not listed - it is already in every checkout' `
      ($gitOk -and -not ($g1s -contains 'data/tracked.json') -and ($g1s.Count -eq 2)) ("got=" + ($g1s -join '|'))
    $g2 = Get-IgnoredMatches -Root $tmp -Pattern 'sub/digest.json'
    T 'CLEAN TWIN the git resolver lists a literal file pattern as exactly that one file' `
      ((@($g2).Count -eq 1) -and (@($g2)[0] -eq 'sub/digest.json')) ("got=" + (@($g2) -join '|'))
    $g3 = Get-IgnoredMatches -Root $tmp -Pattern 'nothing/*.json'
    T 'MUST NOT FIRE  a pattern matching nothing resolves to an EMPTY list, not an error' `
      (@($g3).Count -eq 0) ("got=" + (@($g3) -join '|'))

    # The live SOURCE resolver, against a real LINKED worktree of the same throwaway repo. The pure cases
    # prove the arithmetic; these prove git is asked the question whose answer that arithmetic expects.
    # Quiet flags and core.autocrlf=false for the same stderr reason as the init above.
    & git -C $tmp -c user.name=seed-selftest -c user.email=seed@selftest.invalid -c commit.gpgsign=false -c core.autocrlf=false commit -q -m fixture | Out-Null
    $wtOk = ($LASTEXITCODE -eq 0)
    if ($wtOk) {
      & git -C $tmp -c core.autocrlf=false worktree add -q --detach $tmpWt HEAD | Out-Null
      $wtOk = ($LASTEXITCODE -eq 0)
    }
    $m1 = Get-MainCheckout -From $tmpWt
    T 'MUST FIRE  run from a LINKED worktree, the live resolver names the main checkout, not the worktree' `
      ($wtOk -and $m1 -and (Test-SameCheckout -A $m1 -B $tmp)) ("worktree made=" + $wtOk + " got=" + $m1)
    # From a SUBDIRECTORY of the main checkout the plain form answers `../.git`, so this is the case that
    # goes red if the absolute flag is ever dropped.
    $m2 = Get-MainCheckout -From (Join-Path $tmp 'sub')
    T 'CLEAN TWIN run from a SUBDIRECTORY of the main checkout, the live resolver still names that checkout' `
      ($m2 -and (Test-SameCheckout -A $m2 -B $tmp)) ("got=" + $m2)
  } finally {
    # No junction lives in either directory, so a recursive delete is safe here. The worktree's registration
    # is inside $tmp\.git and goes with it.
    Remove-Item -LiteralPath $tmpWt -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }

  # THE REAL LISTS ARE NOT EMPTY. A seeder with nothing to seed passes every test above and does nothing,
  # which is the shape of a check that has quietly lost its payload. .worktreeinclude is TRACKED, so
  # reading it here is hermetic.
  T 'the shipped seed list is not empty' (@($SEED_DIRS).Count -ge 1) ("Count=" + @($SEED_DIRS).Count)
  T 'every shipped seed line states its reason' `
    (@($SEED_DIRS | Where-Object { -not $_.why }).Count -eq 0) 'a line has no why'
  $incPath = Join-Path $repo $INCLUDE_FILE
  $shipped = if (Test-Path -LiteralPath $incPath) { Read-WorktreeInclude -Text ([IO.File]::ReadAllText($incPath)) } else { $null }
  T 'the shipped .worktreeinclude exists, lists at least one pattern, and carries no refused ! line' `
    (($null -ne $shipped) -and ($shipped.Patterns.Count -ge 1) -and ($shipped.Refused.Count -eq 0)) `
    $(if ($null -eq $shipped) { 'missing' } else { "patterns=$($shipped.Patterns.Count) refused=$($shipped.Refused.Count)" })

  if ($f) { Write-Output ("SELF-TEST FAIL: {0} of {1} check(s)" -f $f, $cases); exit 1 }
  Write-Output ("SELF-TEST PASS: {0} of {0} checks - directory and .worktreeinclude file seeding, the git resolver in a temp repo, the main-checkout source resolver (pure and from a real linked worktree), the source guard, and both shipped lists" -f $cases)
  exit 0
}

# ------------------------------------------------------------------------------------- live run
if (-not $Target) {
  Write-Output 'SEED-WORKTREE COULD NOT EVALUATE: -Target is required and names the worktree to seed. Nothing was copied and nothing was proven.'
  Exit-Guard -Name 'seed-worktree' -Summary 'blind=no-target' -Code 3
}
if (-not (Test-Path -LiteralPath $Target)) {
  Write-Output ("SEED-WORKTREE COULD NOT EVALUATE: -Target does not exist ({0})." -f $Target)
  Exit-Guard -Name 'seed-worktree' -Summary 'blind=no-target-dir' -Code 3
}
$sourceHow = '-Source'
if ($Source) {
  $sourceGiven = $Source
} else {
  # THE MAIN CHECKOUT, NOT THIS SCRIPT'S OWN (2026-09-11) - the header says why.
  $sourceHow = 'git common dir'
  $sourceGiven = Get-MainCheckout -From $repo
  if (-not $sourceGiven) {
    Write-Output ("SEED-WORKTREE COULD NOT EVALUATE: git could not name a main checkout for {0} - a bare repository, a --separate-git-dir clone, or not a git checkout at all. Pass -Source <checkout to read the data from>." -f $repo)
    Exit-Guard -Name 'seed-worktree' -Summary 'blind=no-main-checkout' -Code 3
  }
}
if (-not (Test-Path -LiteralPath $sourceGiven)) {
  Write-Output ("SEED-WORKTREE COULD NOT EVALUATE: -Source does not exist ({0})." -f $sourceGiven)
  Exit-Guard -Name 'seed-worktree' -Summary 'blind=no-source-dir' -Code 3
}
$targetFull = (Resolve-Path -LiteralPath $Target).Path.TrimEnd('\')
$sourceFull = (Resolve-Path -LiteralPath $sourceGiven).Path.TrimEnd('\')
if (Test-SameCheckout -A $sourceFull -B $targetFull) {
  Write-Output ("SEED-WORKTREE COULD NOT EVALUATE: -Target is the source checkout itself ({0}). Seeding a tree from itself proves nothing and would be a no-op wearing a success line." -f $sourceFull)
  Exit-Guard -Name 'seed-worktree' -Summary 'blind=target-is-source' -Code 3
}

$incPath = Join-Path $repo $INCLUDE_FILE
if (-not (Test-Path -LiteralPath $incPath)) {
  Write-Output ("SEED-WORKTREE COULD NOT EVALUATE: {0} is missing. It is the single list of the ignored FILES a worktree needs; seeding only the directories would leave the target blind and report success." -f $incPath)
  Exit-Guard -Name 'seed-worktree' -Summary 'blind=no-worktreeinclude' -Code 3
}
$inc = Read-WorktreeInclude -Text ([IO.File]::ReadAllText($incPath))
if ($inc.Refused.Count) {
  Write-Output ("SEED-WORKTREE COULD NOT EVALUATE: {0} carries {1} negation line(s) this resolver cannot honour one pattern at a time: {2}" -f $INCLUDE_FILE, $inc.Refused.Count, ($inc.Refused -join ', '))
  Exit-Guard -Name 'seed-worktree' -Summary ("blind=refused-negation n={0}" -f $inc.Refused.Count) -Code 3
}
if (-not $inc.Patterns.Count) {
  Write-Output ("SEED-WORKTREE COULD NOT EVALUATE: {0} lists no patterns, so there is no file list to seed from." -f $incPath)
  Exit-Guard -Name 'seed-worktree' -Summary 'blind=empty-worktreeinclude' -Code 3
}
try {
  $fileSeeds = Get-IncludeSeeds -Patterns $inc.Patterns -Lister { param($pat) Get-IgnoredMatches -Root $sourceFull -Pattern $pat }
} catch {
  Write-Output ("SEED-WORKTREE COULD NOT EVALUATE: resolving {0} against the source failed - {1}" -f $INCLUDE_FILE, $_.Exception.Message)
  Exit-Guard -Name 'seed-worktree' -Summary 'blind=resolver-failed' -Code 3
}

$allSeeds = @($SEED_DIRS) + @($fileSeeds)
$plan = Get-SeedPlan -Seeds $allSeeds -SourceRoot $sourceFull -TargetRoot $targetFull `
  -Exists { param($x) Test-Path -LiteralPath $x } `
  -Count {
    param($x)
    if (-not (Test-Path -LiteralPath $x -PathType Container)) { return -1 }
    # Assigned, then wrapped: this estate has a memory about @(Get-Thing ...) reading a comma-returned
    # array as one element, and a count that is silently 1 is exactly the bug this predicate exists to stop.
    $items = Get-ChildItem -LiteralPath $x -Recurse -File -Force -ErrorAction SilentlyContinue
    return @($items).Count
  }

Write-Output ("seed-worktree: {0} -> {1}   (source from {2})" -f $sourceFull, $targetFull, $sourceHow)
Write-Output ("  lists read from {0}: {1} directory seed(s), {2} .worktreeinclude pattern(s) resolving to {3} file seed(s)" -f $repo, @($SEED_DIRS).Count, $inc.Patterns.Count, @($fileSeeds | Where-Object { -not $_.nohit }).Count)
$copied = 0; $skipped = 0; $problems = @()
foreach ($row in $plan) {
  switch ($row.Action) {
    'MISSING-SOURCE' {
      $problems += $row.Path
      Write-Output ("  MISSING  {0}  - not in the SOURCE checkout either, so the worktree stays blind on it. {1}" -f $row.Path, $row.Why)
    }
    'ALREADY-PRESENT' {
      $skipped++
      Write-Output ("  present  {0}  - already there, left alone" -f $row.Path)
    }
    'PARTIAL' {
      # THE MISSING FILES ONLY, and copied INTO the directory: `Copy-Item <src> -Destination <dst>` where
      # dst already exists nests src INSIDE it, which would leave db\built\built. The trailing \* copies the
      # contents. The counts either side are printed because "filled" without them is the same unreadable
      # claim as a rate without its denominator.
      $before = @(Get-ChildItem -LiteralPath $row.Dest -Recurse -File -Force -ErrorAction SilentlyContinue)
      $want = @(Get-ChildItem -LiteralPath $row.Source -Recurse -File -Force -ErrorAction SilentlyContinue)
      if ($WhatIf) {
        Write-Output ("  WOULD FILL {0}  - it holds {1} of the source's {2} file(s). {3}" -f $row.Path, $before.Count, $want.Count, $row.Why)
      } else {
        # ONE COPY PER MISSING FILE, and -LiteralPath throughout. The first version of this was
        # `Copy-Item -LiteralPath <src>\* -Recurse`, which copied NOTHING: -LiteralPath means the `*` is a
        # literal character, not a wildcard, so it named a file that does not exist. Measured here, on a
        # worktree holding 2 of 1,168 - and the post-copy count below is what caught it, which is why that
        # check exists rather than a line saying "filled".
        foreach ($sf in $want) {
          $rel = $sf.FullName.Substring($row.Source.Length).TrimStart('\', '/')
          $target = [IO.Path]::Combine($row.Dest, $rel)
          if (Test-Path -LiteralPath $target) { continue }
          $tp = Split-Path $target -Parent
          if ($tp -and -not (Test-Path -LiteralPath $tp)) { New-Item -ItemType Directory -Force -Path $tp | Out-Null }
          Copy-Item -LiteralPath $sf.FullName -Destination $target -Force
        }
        $after = @(Get-ChildItem -LiteralPath $row.Dest -Recurse -File -Force -ErrorAction SilentlyContinue)
        if ($after.Count -lt $want.Count) {
          $problems += $row.Path
          Write-Output ("  SHORT    {0}  - filled to {1} file(s), source has {2}" -f $row.Path, $after.Count, $want.Count)
        } else {
          Write-Output ("  filled   {0}  ({1} -> {2} file(s), source has {3})" -f $row.Path, $before.Count, $after.Count, $want.Count)
        }
      }
      $copied++
    }
    'COPY' {
      if ($WhatIf) {
        Write-Output ("  WOULD    {0}  - {1}" -f $row.Path, $row.Why)
      } else {
        $parent = Split-Path $row.Dest -Parent
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
        Copy-Item -LiteralPath $row.Source -Destination $row.Dest -Recurse -Force
        if (Test-Path -LiteralPath $row.Source -PathType Leaf) {
          # A FILE IS CHECKED, NOT ASSUMED: a copy that landed short is a problem, not a line saying copied.
          $sl = (Get-Item -LiteralPath $row.Source).Length
          $dl = if (Test-Path -LiteralPath $row.Dest -PathType Leaf) { (Get-Item -LiteralPath $row.Dest).Length } else { -1 }
          if ($sl -ne $dl) {
            $problems += $row.Path
            Write-Output ("  SHORT    {0}  - source {1} bytes, target {2}" -f $row.Path, $sl, $dl)
          } else {
            Write-Output ("  copied   {0}  ({1:N0} bytes)" -f $row.Path, $dl)
          }
        } else {
          $n = @(Get-ChildItem -LiteralPath $row.Dest -Recurse -File -Force -ErrorAction SilentlyContinue).Count
          Write-Output ("  copied   {0}  ({1} file(s))" -f $row.Path, $n)
        }
      }
      $copied++
    }
  }
}

if ($problems.Count) {
  Write-Output ("seed-worktree: FAILED - {0} seed path(s) are missing from the source checkout or did not copy whole, so the target is still blind on them. Do not read a green gate in that worktree as coverage." -f $problems.Count)
  Exit-Guard -Name 'seed-worktree' -Summary ("seeds={0} copied={1} problems={2}" -f @($plan).Count, $copied, $problems.Count) -Code 2
}
$verb = if ($WhatIf) { 'WOULD COPY' } else { 'copied' }
Write-Output ("seed-worktree: DONE - {0} {1} of {2} seed path(s), {3} already present. Directories from `$SEED_DIRS, files from {4}." -f $verb, $copied, @($plan).Count, $skipped, $INCLUDE_FILE)
Write-Output '  Deliberately not seeded: sidecar\.venv. start-sidecar reports that case BLIND in a checkout with no venv, and run-gates names it.'
Exit-Guard -Name 'seed-worktree' -Summary ("seeds={0} copied={1} present={2}" -f @($plan).Count, $copied, $skipped) -Code 0
