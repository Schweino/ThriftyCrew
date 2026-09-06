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

  SO THE SPLIT IS: .worktreeinclude carries the individual ignored FILES automatically, this carries the
  DIRECTORIES and is the manual route for any checkout the CLI did not make. Both are documented in
  .worktreeinclude and both were measured against the same failing worktree.

  WHAT BLIND LOOKS LIKE HERE, since it is not loud. A worktree at 2fdb99cf ran ops\run-gates.ps1 and
  failed six self-tests that pass in the main checkout. Four were missing data. The other two
  (golden-test, ghost-drift) are the CRLF condition in [[fresh-checkout-is-crlf-main-is-lf]] and NOTHING
  in this file will fix them - they go red over bytes, and no copy changes that. The engines are worse
  than the gate: cost-recipes with no board prices nothing and exits 0.

  Usage:  powershell -File ops\seed-worktree.ps1 -Target <path-to-worktree>
          powershell -File ops\seed-worktree.ps1 -Target <path> -WhatIf     (rehearse, copy nothing)

  EXIT CODES (lib\guard-contract.ps1 vocabulary): 0 done, 2 something could not be copied,
  3 could-not-evaluate. Read the verdict LINE, not the number (backlog E2).
#>
param(
  [string]$Target = '',
  [switch]$WhatIf,
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\ops' }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')

# THE DIRECTORIES .worktreeinclude CANNOT CARRY. Each line names the self-test it fixes, because a line
# whose reason nobody can state is a line nobody can delete. Individual FILES belong in
# .worktreeinclude, not here - keep the two lists from growing into each other.
$SEED_DIRS = @(
  @{ p = 'meal-prep\db\built'
     why = 'feed-covers-published parses a real built card; wave-preaudit''s end-to-end drill needs a live spec and a reference card. 47 MB, 1,168 files.' }
)

function Get-SeedPlan {
  <# Pure, so the self-test drives it with synthetic paths instead of resting on today's disk. Returns
     one row per seed entry saying what would happen and why. #>
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
    $srcOk = [bool](& $Exists $src)
    $dstOk = [bool](& $Exists $dst)
    $action = if (-not $srcOk) { 'MISSING-SOURCE' } elseif ($dstOk) { 'ALREADY-PRESENT' } else { 'COPY' }
    $plan += [pscustomobject]@{ Path = $s.p; Source = $src; Dest = $dst; Action = $action; Why = $s.why }
  }
  # `,` not @(): a single-element array unrolls on the way out of a function and the caller's .Count
  # then reads a property of the lone object instead. Same trap as ops\audit-stray-root-artifacts.ps1.
  return ,@($plan)
}

# ------------------------------------------------------------------------------------- self-test
if ($SelfTest) {
  $f = 0
  function T($m, $cond, $got) {
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

  # THE REAL LIST IS NOT EMPTY. A seeder with nothing to seed passes every test above and does nothing,
  # which is the shape of a check that has quietly lost its payload.
  T 'the shipped seed list is not empty' (@($SEED_DIRS).Count -ge 1) ("Count=" + @($SEED_DIRS).Count)
  T 'every shipped seed line states its reason' `
    (@($SEED_DIRS | Where-Object { -not $_.why }).Count -eq 0) 'a line has no why'

  if ($f) { Write-Output ("SELF-TEST FAIL: {0} check(s)" -f $f); exit 1 }
  Write-Output 'SELF-TEST PASS: 4 must-fire plan cases, a clean twin, arity, and the shipped list is populated and documented'
  exit 0
}

# ------------------------------------------------------------------------------------- live run
if (-not $Target) {
  Write-Output 'SEED-WORKTREE COULD NOT EVALUATE: -Target is required and names the worktree to seed. Nothing was copied and nothing was proven.'
  Write-GuardComplete -Name 'seed-worktree' -Summary 'blind=no-target'
  exit 3
}
if (-not (Test-Path -LiteralPath $Target)) {
  Write-Output ("SEED-WORKTREE COULD NOT EVALUATE: -Target does not exist ({0})." -f $Target)
  Write-GuardComplete -Name 'seed-worktree' -Summary 'blind=no-target-dir'
  exit 3
}
$targetFull = (Resolve-Path -LiteralPath $Target).Path
if ($targetFull -eq $repo) {
  Write-Output ("SEED-WORKTREE COULD NOT EVALUATE: -Target is the source checkout itself ({0}). Seeding a tree from itself proves nothing and would be a no-op wearing a success line." -f $repo)
  Write-GuardComplete -Name 'seed-worktree' -Summary 'blind=target-is-source'
  exit 3
}

$plan = Get-SeedPlan -Seeds $SEED_DIRS -SourceRoot $repo -TargetRoot $targetFull -Exists { param($x) Test-Path -LiteralPath $x }

Write-Output ("seed-worktree: {0} -> {1}" -f $repo, $targetFull)
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
        $n = @(Get-ChildItem -LiteralPath $row.Dest -Recurse -File -Force -ErrorAction SilentlyContinue).Count
        Write-Output ("  copied   {0}  ({1} file(s))" -f $row.Path, $n)
      }
      $copied++
    }
  }
}

if ($problems.Count) {
  Write-Output ("seed-worktree: FAILED - {0} seed path(s) are missing from the source checkout, so the target is still blind on them. Do not read a green gate in that worktree as coverage." -f $problems.Count)
  Write-GuardComplete -Name 'seed-worktree' -Summary ("copied={0} missing={1}" -f $copied, $problems.Count)
  exit 2
}
$verb = if ($WhatIf) { 'WOULD COPY' } else { 'copied' }
Write-Output ("seed-worktree: DONE - {0} {1} path(s), {2} already present. .worktreeinclude carries the individual files; this carries the directories it cannot." -f $verb, $copied, $skipped)
Write-Output '  Still not fixed by any copy: golden-test and ghost-drift go red in a fresh checkout over CRLF, not over data.'
Write-GuardComplete -Name 'seed-worktree' -Summary ("copied={0} present={1}" -f $copied, $skipped)
exit 0
