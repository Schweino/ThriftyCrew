<#
  clean-worktrees.ps1 - remove the worktrees nobody can lose anything from, exactly as they were removed by hand.

  WHY (B3 of design\PLAN-efficiency-budgets-2026-09-27.md, ruled by Brad 2026-09-27: "Yes, all of it"). On 2026-09-27 a
  day of cleanup included 208 worktrees. Each was left by a session or agent that finished, and nothing removed them.
  This is the hand procedure of that day, run by the daily ratchets task (ops\run-daily-ratchets.ps1), and nothing more.

  A WORKTREE IS REMOVED ONLY WHEN ALL OF THESE HOLD, and each is asked of git, never inferred:
    1. it is not the main worktree, and not the checkout running this;
    2. it is not LOCKED (`git worktree lock`, which the agent harness uses for a live worktree);
    3. its HEAD is an ANCESTOR of origin/main, as this checkout last fetched it: every commit in it is on main.
       A stale origin/main can only make this refuse more, never remove more;
    4. it is UNTOUCHED for 3+ days: the newest write time of its directory and of its git admin files (HEAD, index,
       logs) is at least that old;
    5. `git worktree remove <path>` WITHOUT --force succeeds. Git itself refuses a worktree with modified or untracked
       files, so a dirty tree is left exactly as git leaves it, and counted refused-dirty.
  Then its branch is deleted with `git branch -d`, NEVER -D: git refuses a branch not merged into this checkout's HEAD,
  and that refusal is counted (branch-kept), not overridden. Last, `git worktree prune` drops admin entries whose
  directory is already gone. NEVER --force, anywhere.

  Counts: removed, refused-dirty, unmerged, locked, recent, skipped (main, this checkout, missing directory), branch-kept.
  -DryRun names what it would remove and removes nothing.

  SCOPE OF A CLEAN REPORT: SOUND for "nothing a person could lose was removed" (every removal is a git command that
  refuses dirt, and every other gate above is a refusal); UNSOUND for "no stale worktree remains" (an unmerged,
  locked, dirty or recent one is left on purpose, and a count is the whole report of it).

  Exit: 0 = ran (whatever it removed). 3 = could not evaluate (not a git checkout, or no origin/main ref), and nothing
  was removed.
#>
# The self-test builds a temp repository with worktrees, so it reads nothing else of this repo.
# gate-inputs: ops\clean-worktrees.ps1, lib\git-repo-env.ps1
[CmdletBinding()]
param([switch]$SelfTest, [switch]$DryRun, [string]$Root = '', [double]$MinAgeDays = 3)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = if ($Root) { $Root } else { Split-Path $here -Parent }
. (Join-Path (Split-Path $here -Parent) 'lib\git-repo-env.ps1')

function Invoke-TcWtGit {
  <# git with Continue around it, so a stderr line is not a throw; returns { Rc; Out }. #>
  param([string]$Repo, [string[]]$GitArgs)
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $o = @(& git -C $Repo @GitArgs 2>$null); return [pscustomobject]@{ Rc = $LASTEXITCODE; Out = $o } }
  catch { return [pscustomobject]@{ Rc = -1; Out = @() } }
  finally { $ErrorActionPreference = $prev }
}

function Get-TcWorktreeList {
  <# `git worktree list --porcelain` as rows { Path; Head; Branch; Locked; Prunable; IsMain }. The first is main. #>
  param([string]$Repo)
  $r = Invoke-TcWtGit -Repo $Repo -GitArgs @('worktree', 'list', '--porcelain')
  if ($r.Rc -ne 0) { return $null }
  $rows = [System.Collections.Generic.List[object]]::new()
  $cur = $null
  foreach ($line in @($r.Out) + @('')) {
    $l = [string]$line
    if (-not $l) { if ($cur) { $rows.Add([pscustomobject]$cur); $cur = $null }; continue }
    if ($l.StartsWith('worktree ')) { $cur = [ordered]@{ Path = $l.Substring(9); Head = ''; Branch = ''; Locked = $false; Prunable = $false; IsMain = ($rows.Count -eq 0) } }
    elseif ($null -eq $cur) { continue }
    elseif ($l.StartsWith('HEAD ')) { $cur.Head = $l.Substring(5) }
    elseif ($l.StartsWith('branch ')) { $cur.Branch = $l.Substring(7) }
    elseif ($l -ceq 'locked' -or $l.StartsWith('locked ')) { $cur.Locked = $true }
    elseif ($l -ceq 'prunable' -or $l.StartsWith('prunable ')) { $cur.Prunable = $true }
  }
  return $rows.ToArray()
}

function Get-TcWorktreeTouchedUtc {
  <# The newest write time of the worktree's directory, its .git file, and the files of its git admin directory
     (HEAD, index, ORIG_HEAD, logs\HEAD). Any git command in it, a checkout, a commit, a status that refreshes the index,
     moves one of these. $null when none can be read, which the caller treats as recent: a could-not-look never removes. #>
  param([string]$Path)
  $newest = $null
  $cands = [System.Collections.Generic.List[string]]::new()
  $cands.Add($Path)
  $gf = Join-Path $Path '.git'
  $cands.Add($gf)
  try {
    if ([IO.File]::Exists($gf)) {
      $m = [regex]::Match([IO.File]::ReadAllText($gf), '(?m)^gitdir:\s*(.+?)\s*$')
      if ($m.Success) {
        $adm = $m.Groups[1].Value
        if (-not [IO.Path]::IsPathRooted($adm)) { $adm = Join-Path $Path $adm }
        foreach ($n in @('HEAD', 'index', 'ORIG_HEAD', 'logs\HEAD')) { $cands.Add((Join-Path $adm $n)) }
      }
    }
  } catch { }
  foreach ($c in $cands) {
    $t = $null
    try {
      if ([IO.File]::Exists($c)) { $t = [IO.File]::GetLastWriteTimeUtc($c) }
      elseif ([IO.Directory]::Exists($c)) { $t = [IO.Directory]::GetLastWriteTimeUtc($c) }
    } catch { $t = $null }
    if ($null -ne $t -and ($null -eq $newest -or $t -gt $newest)) { $newest = $t }
  }
  return $newest
}

function Invoke-TcWorktreeCleanup {
  <# The whole procedure over one repository. Returns { Ok; Why; Counts; Lines }. Removes nothing when -DryRun. #>
  param([string]$Repo, [double]$MinAgeDays = 3, [switch]$DryRun, [datetime]$NowUtc = [DateTime]::UtcNow)
  $counts = [ordered]@{ removed = 0; 'refused-dirty' = 0; unmerged = 0; locked = 0; recent = 0; skipped = 0; 'branch-kept' = 0 }
  $lines = [System.Collections.Generic.List[string]]::new()
  $om = Invoke-TcWtGit -Repo $Repo -GitArgs @('rev-parse', '--verify', '-q', 'refs/remotes/origin/main')
  if ($om.Rc -ne 0 -or -not @($om.Out).Count) { return [pscustomobject]@{ Ok = $false; Why = 'no origin/main ref'; Counts = $counts; Lines = $lines.ToArray() } }
  $omSha = ([string]$om.Out[0]).Trim()
  $top = Invoke-TcWtGit -Repo $Repo -GitArgs @('rev-parse', '--show-toplevel')
  $self = if ($top.Rc -eq 0 -and @($top.Out).Count) { [IO.Path]::GetFullPath(([string]$top.Out[0]).Trim()).TrimEnd('\') } else { '' }
  $wts = Get-TcWorktreeList -Repo $Repo
  if ($null -eq $wts) { return [pscustomobject]@{ Ok = $false; Why = 'git worktree list failed'; Counts = $counts; Lines = $lines.ToArray() } }
  foreach ($w in $wts) {
    $full = [IO.Path]::GetFullPath(($w.Path -replace '/', '\')).TrimEnd('\')
    if ($w.IsMain -or [string]::Equals($full, $self, [StringComparison]::OrdinalIgnoreCase)) { $counts.skipped++; continue }
    if ($w.Prunable -or -not [IO.Directory]::Exists($full)) { $counts.skipped++; continue }   # prune below drops its entry
    if ($w.Locked) { $counts.locked++; continue }
    $anc = Invoke-TcWtGit -Repo $Repo -GitArgs @('merge-base', '--is-ancestor', $w.Head, $omSha)
    if ($anc.Rc -ne 0) { $counts.unmerged++; continue }   # 1 = not on main; anything else = could not ask, also left alone
    $touched = Get-TcWorktreeTouchedUtc -Path $full
    if ($null -eq $touched -or ($NowUtc - $touched).TotalDays -lt $MinAgeDays) { $counts.recent++; continue }
    # ASKED FIRST, SO A DRY RUN SEES DIRT TOO. --no-optional-locks keeps status from refreshing the index, which would
    # move the very write time rule 4 reads. `git worktree remove` below still refuses on its own, so this adds a
    # refusal and never removes one.
    $st = Invoke-TcWtGit -Repo $full -GitArgs @('--no-optional-locks', 'status', '--porcelain')
    if ($st.Rc -ne 0 -or @($st.Out | Where-Object { "$_".Trim() }).Count) { $counts.'refused-dirty'++; $lines.Add("  refused     $full (modified or untracked files, or status could not be read)"); continue }
    if ($DryRun) { $counts.removed++; $lines.Add("  would remove $full"); continue }
    $rm = Invoke-TcWtGit -Repo $Repo -GitArgs @('worktree', 'remove', $full)
    if ($rm.Rc -ne 0) { $counts.'refused-dirty'++; $lines.Add("  refused     $full (git worktree remove refused: modified or untracked files)"); continue }
    $counts.removed++
    $lines.Add("  removed     $full")
    if ($w.Branch -and $w.Branch.StartsWith('refs/heads/')) {
      $bn = $w.Branch.Substring(11)
      $bd = Invoke-TcWtGit -Repo $Repo -GitArgs @('branch', '-d', $bn)
      if ($bd.Rc -ne 0) { $counts.'branch-kept'++; $lines.Add("  branch kept $bn (git branch -d refused: not merged into this checkout's HEAD)") }
    }
  }
  if (-not $DryRun) { $null = Invoke-TcWtGit -Repo $Repo -GitArgs @('worktree', 'prune') }
  return [pscustomobject]@{ Ok = $true; Why = ''; Counts = $counts; Lines = $lines.ToArray() }
}

function Format-TcWorktreeCounts($Counts) {
  return (@($Counts.Keys | ForEach-Object { "$_=$($Counts[$_])" }) -join ' ')
}

if ($SelfTest) {
  $script:bad = 0; $script:cases = 0
  function T([string]$n, [bool]$ok, [string]$got) {
    $script:cases++
    if ($ok) { Write-Output ('  ok    ' + $n) } else { Write-Output ('  X     ' + $n + '   got: ' + $got); $script:bad++ }
  }
  $kMF = 'MUST' + ' FIRE'; $kMNF = 'MUST' + ' NOT FIRE'; $kCT = 'CLEAN' + ' TWIN'
  $utf8 = New-Object Text.UTF8Encoding($false)
  $wt = Join-Path ([IO.Path]::GetTempPath()) ('cwt-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  $null = [IO.Directory]::CreateDirectory($wt)
  $prevE = $ErrorActionPreference
  try {
    Clear-TcGitRepoEnv
    $ErrorActionPreference = 'Continue'
    $m = Join-Path $wt 'main'
    $gid = @('-c', 'user.name=fixture', '-c', 'user.email=fixture@example.invalid', '-c', 'commit.gpgsign=false')
    $null = & git init -q $m 2>$null
    [IO.File]::WriteAllText((Join-Path $m 'a.txt'), "a`n", $utf8)
    $null = & git -C $m add a.txt 2>$null
    $null = & git -C $m @gid commit -q -m base 2>$null
    $base = ([string](& git -C $m rev-parse HEAD)).Trim()
    $ErrorActionPreference = $prevE
    $noOm = Invoke-TcWorktreeCleanup -Repo $m
    T ($kMF + '  with NO origin/main ref nothing is judged and nothing removed: could not evaluate') (-not $noOm.Ok -and $noOm.Why -eq 'no origin/main ref') ("ok=$($noOm.Ok) why=$($noOm.Why)")
    $ErrorActionPreference = 'Continue'
    $null = & git -C $m update-ref refs/remotes/origin/main $base 2>$null
    foreach ($n in @('clean', 'dirty', 'untracked', 'unmerged', 'locked', 'recent')) {
      $null = & git -C $m worktree add -q -b ("wt-" + $n) (Join-Path $wt $n) $base 2>$null
    }
    [IO.File]::WriteAllText((Join-Path $wt 'dirty\a.txt'), "changed`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $wt 'untracked\new.txt'), "new`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $wt 'unmerged\b.txt'), "b`n", $utf8)
    $null = & git -C (Join-Path $wt 'unmerged') add b.txt 2>$null
    $null = & git -C (Join-Path $wt 'unmerged') @gid commit -q -m local 2>$null
    $null = & git -C $m worktree lock (Join-Path $wt 'locked') 2>$null
    $ErrorActionPreference = $prevE
    # Age every worktree but 'recent' by five days: its directory and its admin files, exactly what the procedure reads.
    $old = [DateTime]::UtcNow.AddDays(-5)
    foreach ($n in @('clean', 'dirty', 'untracked', 'unmerged', 'locked')) {
      $p = Join-Path $wt $n
      $gf = Join-Path $p '.git'
      $adm = ([regex]::Match([IO.File]::ReadAllText($gf), '(?m)^gitdir:\s*(.+?)\s*$')).Groups[1].Value
      foreach ($f in @('HEAD', 'index', 'ORIG_HEAD', 'logs\HEAD')) { $fp = Join-Path $adm $f; if ([IO.File]::Exists($fp)) { [IO.File]::SetLastWriteTimeUtc($fp, $old) } }
      [IO.File]::SetLastWriteTimeUtc($gf, $old)
      [IO.Directory]::SetLastWriteTimeUtc($p, $old)
    }
    $dry = Invoke-TcWorktreeCleanup -Repo $m -DryRun
    T ($kCT + '  -DryRun names the one removable worktree and removes nothing') ($dry.Ok -and $dry.Counts.removed -eq 1 -and [IO.Directory]::Exists((Join-Path $wt 'clean'))) (Format-TcWorktreeCounts $dry.Counts)
    $res = Invoke-TcWorktreeCleanup -Repo $m
    $c = $res.Counts
    $ErrorActionPreference = 'Continue'
    $branches = @(& git -C $m branch --format='%(refname:short)' 2>$null)
    $ErrorActionPreference = $prevE
    T ($kCT + '  a clean worktree on origin/main, untouched 5 days, is removed and its merged branch deleted with -d') `
      ($res.Ok -and $c.removed -eq 1 -and -not [IO.Directory]::Exists((Join-Path $wt 'clean')) -and ($branches -notcontains 'wt-clean')) ((Format-TcWorktreeCounts $c) + ' branches=' + ($branches -join ','))
    T ($kMNF + '  a DIRTY worktree (a modified tracked file) is left, with its change, and counted refused-dirty') `
      ([IO.File]::ReadAllText((Join-Path $wt 'dirty\a.txt')) -eq "changed`n" -and ($branches -contains 'wt-dirty')) (Format-TcWorktreeCounts $c)
    T ($kMNF + '  a worktree with an UNTRACKED file is left, with the file: git refuses without --force') `
      ([IO.File]::Exists((Join-Path $wt 'untracked\new.txt'))) (Format-TcWorktreeCounts $c)
    T ($kCT + '  ...and both are counted refused-dirty, 2 of them') ($c.'refused-dirty' -eq 2) (Format-TcWorktreeCounts $c)
    T ($kMNF + '  an UNMERGED worktree (a commit not on origin/main) is left, with its branch') `
      ($c.unmerged -eq 1 -and [IO.File]::Exists((Join-Path $wt 'unmerged\b.txt')) -and ($branches -contains 'wt-unmerged')) (Format-TcWorktreeCounts $c)
    T ($kMNF + '  a LOCKED worktree is left, though clean, merged and old') ($c.locked -eq 1 -and [IO.Directory]::Exists((Join-Path $wt 'locked'))) (Format-TcWorktreeCounts $c)
    T ($kMNF + '  a RECENT worktree (touched now, under 3 days) is left, though clean and merged') ($c.recent -eq 1 -and [IO.Directory]::Exists((Join-Path $wt 'recent'))) (Format-TcWorktreeCounts $c)
    T ($kCT + '  the main worktree is skipped, never judged') ($c.skipped -eq 1 -and [IO.Directory]::Exists($m)) (Format-TcWorktreeCounts $c)
    # THE BAR IS 3 DAYS (og-06): the same 'recent' worktree judged 2.5 days later (touched 2.5 days before "now") stays;
    # 3.5 days later it is removable. Halves, so the arithmetic is binary-exact.
    $touchedR = Get-TcWorktreeTouchedUtc -Path (Join-Path $wt 'recent')
    $under = Invoke-TcWorktreeCleanup -Repo $m -DryRun -NowUtc $touchedR.AddDays(2.5)
    T ($kMNF + '  a worktree touched 2.5 days ago, under the 3-day bar, is recent') ($under.Counts.recent -eq 1 -and $under.Counts.removed -eq 0) (Format-TcWorktreeCounts $under.Counts)
    $past = Invoke-TcWorktreeCleanup -Repo $m -DryRun -NowUtc $touchedR.AddDays(3.5)
    T ($kMF + '  the same worktree 3.5 days later, past the bar, would be removed') ($past.Counts.removed -eq 1) (Format-TcWorktreeCounts $past.Counts)
  } catch {
    $script:cases++; $script:bad++
    Write-Output ('  X     the suite threw: ' + $_.Exception.Message)
  } finally {
    $ErrorActionPreference = $prevE
    Remove-Item -LiteralPath $wt -Recurse -Force -ErrorAction SilentlyContinue
  }
  $expected = 12
  if ($script:cases -ne $expected) { Write-Output ("  X     ran $($script:cases) case(s), expected $expected"); $script:bad++ }
  if ($script:bad -eq 0) { Write-Output ("clean-worktrees self-test PASS ($($script:cases) of $expected cases)"); exit 0 }
  Write-Output ("clean-worktrees self-test FAIL ($($script:bad))"); exit 1
}

Clear-TcGitRepoEnv
$res = Invoke-TcWorktreeCleanup -Repo $repo -MinAgeDays $MinAgeDays -DryRun:$DryRun
if (-not $res.Ok) {
  Write-Output ("clean-worktrees: COULD NOT EVALUATE - {0}; nothing was removed." -f $res.Why)
  Write-Output ('WORKTREE-CLEANUP-COMPLETE blind=' + ($res.Why -replace '\s', '-'))
  exit 3
}
foreach ($l in $res.Lines) { Write-Output $l }
$mode = if ($DryRun) { ' (dry run: nothing removed)' } else { '' }
Write-Output ("clean-worktrees: {0}{1}" -f (Format-TcWorktreeCounts $res.Counts), $mode)
Write-Output ('WORKTREE-CLEANUP-COMPLETE ' + (Format-TcWorktreeCounts $res.Counts))
exit 0
