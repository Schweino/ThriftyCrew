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
    2. Cleanup becomes destructive. `Remove-Item -Recurse` on a checkout holding a junction walks into
       the target and deletes the real venv (torch and sentence-transformers, a long rebuild), and the
       natural way to clean a temp checkout is exactly that command.
    3. It proves nothing about the change under test. The venv is environment, not code; seeding it
       turns a check that CANNOT LOOK into one that looks at a different checkout and reports on it.
  So start-sidecar now reports that case BLIND in a checkout that has no venv of any name, and still
  FAILS when a venv exists somewhere the launcher does not look, which is the rot the case was written
  for. run-gates prints every BLIND case it sees, so a green run cannot hide one.

  WHAT BLIND LOOKS LIKE HERE, since it is not loud. A worktree at 2fdb99cf ran ops\run-gates.ps1 and
  failed six self-tests that pass in the main checkout. Four were missing data. The other two
  (golden-test, ghost-drift) were the CRLF condition in [[fresh-checkout-is-crlf-main-is-lf]] and no copy
  changes that. The engines are worse than the gate: cost-recipes with no board prices nothing and exits 0.

  Usage:  powershell -File ops\seed-worktree.ps1 -Target <path-to-worktree>
          powershell -File ops\seed-worktree.ps1 -Target <path> -Source C:\Codex\ThriftyCrew
                    (run THIS copy of the script, read the data from another checkout - how a branch
                     that changes this file seeds from main before it is merged)
          powershell -File ops\seed-worktree.ps1 -Target <path> -WhatIf     (rehearse, copy nothing)

  The lists ($SEED_DIRS and .worktreeinclude) are always read from the checkout this script lives in, so
  the code and the list it reads travel together. -Source changes only where the bytes come from.

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
# and same reason as ops\run-gates.ps1 (2026-09-10).
foreach ($v in @('GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_COMMON_DIR', 'GIT_OBJECT_DIRECTORY',
                 'GIT_ALTERNATE_OBJECT_DIRECTORIES', 'GIT_PREFIX', 'GIT_NAMESPACE')) {
  Remove-Item -LiteralPath ("Env:\" + $v) -ErrorAction SilentlyContinue
}
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\ops' }
$repo = Split-Path $here -Parent
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
    [scriptblock]$Exists
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
    $action = if (-not $srcOk) { 'MISSING-SOURCE' } elseif ($dstOk) { 'ALREADY-PRESENT' } else { 'COPY' }
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

  # ---- the LIVE resolver against a real, throwaway git repository ---------------------------------
  # The pure cases above prove the plan; this proves git is asked the right question. Built in TEMP,
  # never under the repo, and removed in finally ([[test-suites-leak-temp-dirs]]).
  $tmp = Join-Path $env:TEMP ('seed-worktree-selftest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
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
  } finally {
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
  Write-Output ("SELF-TEST PASS: {0} of {0} checks - directory and .worktreeinclude file seeding, the git resolver in a temp repo, the source guard, and both shipped lists" -f $cases)
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
$sourceGiven = if ($Source) { $Source } else { $repo }
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
$plan = Get-SeedPlan -Seeds $allSeeds -SourceRoot $sourceFull -TargetRoot $targetFull -Exists { param($x) Test-Path -LiteralPath $x }

Write-Output ("seed-worktree: {0} -> {1}" -f $sourceFull, $targetFull)
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
