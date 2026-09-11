# gate-leftovers.ps1 - what a gate run left where the daily bot commits, and whether that fails the run.
#
# WHY THIS EXISTS (2026-09-11). run-gates runs its gates in one pool on the ground that the gates do not write,
# measured once over 108,129 files and never again. From 8253ded82 grocery\pull-grocery-ads.ps1's -SelfTest did: its
# verdict `if` shared a line with the last case, PowerShell read it as more arguments to that case, neither exit ran,
# and every self-test run fell through into the LIVE weekly-ad pull and wrote grocery\out\ads-<today>.json. Seen after
# a push from worktree reverent-almeida-373a21 (791,970 bytes at 14:06:25, untracked and not ignored), and reproduced
# in friendly-gould-3e85d4 the same day: exit 0, 135 s, 1,004 live deals, that one file and nothing else written.
# grocery\capture-run.ps1 stages grocery\out whole and the board reads the newest ads file, so from the main checkout
# that run hands the next bot commit an ad capture no chain verified.
#
# THE RULE. Snapshot every path the bot stages (lib\bot-paths.ps1, both sets) just before the pool and just after it,
# each file keyed on length and last-write time. A file ADDED, CHANGED or REMOVED there that git does not ignore is a
# leftover, because the bot's `git add -A -- <path>` would commit it. An ignored one is not counted: the bot cannot
# stage it.
#
# ONLY A LINKED WORKTREE FAILS. No scheduled task runs in one (checked 2026-09-11: no TC task action names a worktree
# path), so a change that appears there while the pool runs came from the pool. The MAIN checkout is where the capture
# lanes and the morning chain write through the day, and a push from it can overlap them, so there the same finding
# prints as REVIEW, every path named, and does not fail: a red caused by a lane would teach --no-verify. A gate that
# writes does so in every checkout, and spawned sessions push from worktrees, so the next push from one fails on it.
#
# SCOPE OF A CLEAN REPORT: UNSOUND. It compares length and write time, not bytes, so a rewrite that keeps both is
# missed. It watches the bot-staged paths only; a gate writing a tracked script or ops\out is not seen. A file a gate
# writes and removes inside the pool leaves nothing to see. A directory it cannot list is BLIND and named, never read
# as unchanged. The main checkout's REVIEW is not a verdict either way. A leftover reported in a linked worktree is
# the pool's unless a person ran something in that worktree during the push.
#
# THE SELF-TEST'S FIXTURE MODULE IS NAMED `store`, not after a real module. Nothing here depends on which module owns
# the staged directory, and a fixture spelling a real module's internals is counted by ops\audit-cross-module-reach.ps1
# as a reach it is not (the first cut added 13 such sites).
#
# NO param() BLOCK, DELIBERATELY: dot-sourced under PS 5.1 a param() block runs in the CALLER's scope and would reset
# the caller's own -SelfTest. Same rule as lib\tree-walk.ps1 and lib\bot-paths.ps1.
#
# Dot-source:  . (Join-Path $repoRoot 'lib\gate-leftovers.ps1')
# Self-test:   powershell -File lib\gate-leftovers.ps1 -SelfTest

$__gateLeftoversSelfTest = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-SelfTest')
. (Join-Path $PSScriptRoot 'bot-paths.ps1')   # Get-BotInputPaths, Get-BotServedPaths - no param() block either

function Get-TcBotStagedPaths {
  # Both of the bot's staging sets, repo-relative with backslashes, the spelling Get-TcTreeSnapshot keys on.
  $in = Get-BotInputPaths
  $served = Get-BotServedPaths
  $all = New-Object System.Collections.Generic.List[string]
  foreach ($p in @($in) + @($served)) { $all.Add(([string]$p).Replace('/', '\')) }
  return ,$all.ToArray()
}

function Get-TcTreeSnapshot {
  # Every file under each path: repo-relative path -> 'length|last-write ticks (UTC)'. A path that is a file is one
  # entry and an absent path is none. A reparse-point directory is not entered, since a junction can loop. A directory
  # that cannot be listed goes into .Blind, never skipped in silence.
  param([string]$Root, [string[]]$Paths)
  $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
  $files = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
  $blind = New-Object System.Collections.Generic.List[string]
  foreach ($rel in @($Paths | Where-Object { $_ })) {
    $full = Join-Path $rootFull $rel
    if ([IO.File]::Exists($full)) {
      $fi = New-Object IO.FileInfo $full
      $files[$rel] = ([string]$fi.Length + '|' + [string]$fi.LastWriteTimeUtc.Ticks)
      continue
    }
    if (-not [IO.Directory]::Exists($full)) { continue }
    $stack = New-Object 'System.Collections.Generic.Stack[IO.DirectoryInfo]'
    $stack.Push((New-Object IO.DirectoryInfo $full))
    while ($stack.Count -gt 0) {
      $d = $stack.Pop()
      try {
        foreach ($f in $d.EnumerateFiles()) { $files[$f.FullName.Substring($rootFull.Length + 1)] = ([string]$f.Length + '|' + [string]$f.LastWriteTimeUtc.Ticks) }
        foreach ($sd in $d.EnumerateDirectories()) { if (($sd.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) { $stack.Push($sd) } }
      } catch {
        $blind.Add($d.FullName.Substring($rootFull.Length + 1) + ' (' + $_.Exception.Message + ')')
      }
    }
  }
  return [pscustomobject]@{ Files = $files; Blind = $blind.ToArray() }
}

function Compare-TcTreeSnapshot {
  # Each file added, changed (length or write time) or removed between two snapshots, sorted by path.
  param($Before, $After)
  $out = New-Object System.Collections.Generic.List[object]
  foreach ($k in $After.Files.Keys) {
    $was = $null
    if (-not $Before.Files.TryGetValue($k, [ref]$was)) { $out.Add([pscustomobject]@{ Path = $k; Change = 'added' }) }
    elseif (-not [string]::Equals($was, $After.Files[$k], [StringComparison]::Ordinal)) { $out.Add([pscustomobject]@{ Path = $k; Change = 'changed' }) }
  }
  foreach ($k in $Before.Files.Keys) { if (-not $After.Files.ContainsKey($k)) { $out.Add([pscustomobject]@{ Path = $k; Change = 'removed' }) } }
  $sorted = @($out | Sort-Object Path)
  return ,$sorted
}

function Select-TcStageableChange {
  # Drops the changes git ignores, which the bot's `git add` cannot stage. Asked per FILE path, never a directory
  # ([[check-ignore-directory-form-lies]]), 100 at a time on the command line. A git that cannot answer keeps EVERY
  # change and names its exit code: an over-report, never a quiet drop.
  param([string]$Root, [object[]]$Changes)
  $r = [pscustomobject]@{ Changes = @(); Ignored = 0; Error = '' }
  $list = @($Changes | Where-Object { $_ })
  if ($list.Count -eq 0) { return $r }
  $ignored = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  $ErrorActionPreference = 'Continue'   # a native stderr line must not become a throw; this scope only
  for ($i = 0; $i -lt $list.Count; $i += 100) {
    $chunk = @($list[$i..([Math]::Min($i + 99, $list.Count - 1))] | ForEach-Object { ([string]$_.Path).Replace('\', '/') })
    $said = @(& git -C $Root -c core.quotepath=off check-ignore -- $chunk 2>$null)
    $rc = $LASTEXITCODE
    if ($rc -ne 0 -and $rc -ne 1) { $r.Error = ('git check-ignore exited ' + $rc); break }
    foreach ($line in $said) { [void]$ignored.Add(([string]$line).Trim().Replace('/', '\')) }
  }
  if ($r.Error) { $r.Changes = $list; return $r }
  $keep = @($list | Where-Object { -not $ignored.Contains([string]$_.Path) })
  $r.Changes = $keep
  $r.Ignored = $list.Count - $keep.Count
  return $r
}

function Get-TcCheckoutKind {
  # 'linked' when .git is a FILE (a linked worktree's gitdir pointer), 'main' when it is a directory, '' when absent.
  param([string]$Root)
  $g = Join-Path $Root '.git'
  if ([IO.File]::Exists($g)) { return 'linked' }
  if ([IO.Directory]::Exists($g)) { return 'main' }
  return ''
}

function Get-TcLeftoverVerdict {
  # { Fail; Lines }. Only a linked worktree fails on a leftover; the header says why the main checkout reviews.
  param([object[]]$Changes = @(), [string]$Kind = '', [int]$Watched = 0, [int]$Ignored = 0, [string[]]$Blind = @(), [string]$FilterError = '')
  $list = @($Changes | Where-Object { $_ } | Sort-Object Path)
  $lines = New-Object System.Collections.Generic.List[string]
  foreach ($b in @($Blind | Where-Object { $_ })) { $lines.Add('gate-leftovers: BLIND - could not list ' + $b + ', so nothing below it was compared') }
  if ($FilterError) { $lines.Add('gate-leftovers: git could not say which changes it ignores (' + $FilterError + '), so every change is counted, ignored or not') }
  if ($list.Count -eq 0) {
    $lines.Add(('gate-leftovers: none - {0} file(s) watched where the daily bot stages, and the pool added, changed and removed none of them ({1} change(s) to ignored files not counted)' -f $Watched, $Ignored))
    return [pscustomobject]@{ Fail = $false; Lines = $lines.ToArray() }
  }
  $fail = ($Kind -eq 'linked')
  if ($fail) {
    $lines.Add(('gate-leftovers: FAILED - the pool left {0} change(s) where the daily bot stages ({1} file(s) watched), in a linked worktree where no scheduled task writes:' -f $list.Count, $Watched))
  } else {
    $where = if ($Kind -eq 'main') { 'the main checkout' } else { 'a checkout that is not a linked worktree' }
    $lines.Add(('gate-leftovers: REVIEW - {0} change(s) appeared where the daily bot stages while the pool ran ({1} file(s) watched). This is {2}, where capture lanes also write, so they are not attributed and do not fail the run. If no lane was running, a gate wrote them and the next bot commit carries them:' -f $list.Count, $Watched, $where))
  }
  $show = [Math]::Min(25, $list.Count)
  for ($i = 0; $i -lt $show; $i++) { $lines.Add(('  {0,-8} {1}' -f $list[$i].Change, $list[$i].Path)) }
  if ($list.Count -gt $show) { $lines.Add(('  ... and {0} more' -f ($list.Count - $show))) }
  if ($fail) { $lines.Add('  A gate writes under a temp directory it owns. Run each suspect self-test alone and diff these paths; lib\gate-leftovers.ps1 has the account.') }
  return [pscustomobject]@{ Fail = $fail; Lines = $lines.ToArray() }
}

if ($__gateLeftoversSelfTest) {
  . (Join-Path $PSScriptRoot 'git-repo-env.ps1')
  Clear-TcGitRepoEnv   # this self-test builds a temp repo, so it clears the repository environment first
  $ErrorActionPreference = 'Stop'
  $script:glFail = 0
  $script:glCases = 0
  function Test-GlCase([string]$Label, [scriptblock]$Check) {
    # A case that THROWS is a counted failure, never a skipped line: a suite whose cases all error must not pass.
    $script:glCases++
    $ok = $false
    try { $ok = [bool](& $Check) } catch { $Label = $Label + ' (threw: ' + $_.Exception.Message + ')' }
    if ($ok) { Write-Output ('  PASS  ' + $Label) } else { Write-Output ('  FAIL  ' + $Label); $script:glFail++ }
  }
  # `~` stands for `$`, so this file's source never spells a switch declaration run-gates' discovery would read.
  function New-GlText([string[]]$Lines) { return (($Lines -join "`r`n").Replace('~', '$')) }
  function Invoke-GlChild([string]$Path) {
    # Launched the way run-gates launches a self-test.
    $ErrorActionPreference = 'Continue'
    $o = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Path -SelfTest)
    return [pscustomobject]@{ Rc = $LASTEXITCODE; Text = ($o -join "`n") }
  }
  function Get-GlRound([string]$Root, [string[]]$Watch, $Before) {
    $after = Get-TcTreeSnapshot -Root $Root -Paths $Watch
    $changes = Compare-TcTreeSnapshot -Before $Before -After $after
    $stage = Select-TcStageableChange -Root $Root -Changes $changes
    return [pscustomobject]@{ After = $after; Changes = @($changes); Stage = $stage }
  }

  $utf8 = New-Object Text.UTF8Encoding($false)
  $sb = Join-Path ([IO.Path]::GetTempPath()) ('tc-gl-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  $null = New-Item -ItemType Directory -Path $sb -ErrorAction Stop
  try {
    # A checkout shaped like this one where it matters: a committed ad file in a staged out directory, a ledger beside
    # it, and the board pattern ignored, as .gitignore ignores the real board files. The module is `store` (header).
    $fx = Join-Path $sb 'r'
    $fxOut = Join-Path $fx 'store\out'
    $null = New-Item -ItemType Directory -Path $fxOut -Force
    [IO.File]::WriteAllText((Join-Path $fx '.gitignore'), "/store/out/comparison-*.json`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $fxOut 'ads-2026-09-10.json'), '{"deals":[1]}', $utf8)
    [IO.File]::WriteAllText((Join-Path $fx 'store\ledger.json'), '{"k":1}', $utf8)
    $ErrorActionPreference = 'Continue'
    $null = & git init -q $fx 2>$null
    $ErrorActionPreference = 'Stop'
    $watch = @('store\out', 'store\ledger.json', 'store\absent.json')

    # THE FOUNDING SHAPE AND ITS REPAIR, as self-tests sitting beside the staged out directory the way pull-grocery-ads does.
    $head = @(
      'param([switch]~SelfTest)',
      '~fail = 0',
      'function _T([string]~label, [bool]~cond) { if (~cond) { Write-Output (''ok    '' + ~label) } else { Write-Output (''FAIL  '' + ~label); ~script:fail++ } }',
      'if (~SelfTest) {'
    )
    $verdict = 'if (~fail -eq 0) { Write-Output ''SELF-TEST PASS''; exit 0 } else { Write-Output ''SELF-TEST FAIL''; exit 1 }'
    $tail = @(
      '}',
      '[IO.File]::WriteAllText((Join-Path (Join-Path ~PSScriptRoot ''out'') ''ads-2026-09-11.json''), ''{"deals":[2]}'')',
      'Write-Output ''Saved the live pull'''
    )
    $founding = Join-Path $fx 'store\pull-founding.ps1'
    $repaired = Join-Path $fx 'store\pull-repaired.ps1'
    [IO.File]::WriteAllText($founding, (New-GlText ($head + @(('  _T ''a frozen case'' (1 -eq 1)  ' + $verdict)) + $tail)), $utf8)
    [IO.File]::WriteAllText($repaired, (New-GlText ($head + @('  _T ''a frozen case'' (1 -eq 1)', ('  ' + $verdict)) + $tail)), $utf8)
    $newAds = Join-Path 'store\out' 'ads-2026-09-11.json'

    $s0 = Get-TcTreeSnapshot -Root $fx -Paths $watch
    $run = Invoke-GlChild $founding
    $g = Get-GlRound $fx $watch $s0
    $v = Get-TcLeftoverVerdict -Changes $g.Stage.Changes -Kind 'linked' -Watched $g.After.Files.Count -Ignored $g.Stage.Ignored
    Test-GlCase 'MUST FIRE  the founding shape (the verdict if read as arguments to the case before it) exits 0 and writes out\ads-2026-09-11.json where the bot stages, and in a linked worktree the verdict FAILS naming that file' {
      ($run.Rc -eq 0) -and ($run.Text -match 'Saved the live pull') -and (@($g.Stage.Changes).Count -eq 1) -and
      ([string]$g.Stage.Changes[0].Path -eq $newAds) -and ([string]$g.Stage.Changes[0].Change -eq 'added') -and
      ($v.Fail -eq $true) -and (($v.Lines -join "`n") -match [regex]::Escape('added    ' + $newAds))
    }
    $vMain = Get-TcLeftoverVerdict -Changes $g.Stage.Changes -Kind 'main' -Watched $g.After.Files.Count -Ignored $g.Stage.Ignored
    Test-GlCase 'MUST NOT FIRE  the same leftover in the MAIN checkout does not fail the run, since a capture lane may have written it' { $vMain.Fail -eq $false }
    Test-GlCase 'CLEAN TWIN  and the main checkout still speaks it as REVIEW, naming the file' {
      (($vMain.Lines -join "`n") -match 'gate-leftovers: REVIEW') -and (($vMain.Lines -join "`n") -match [regex]::Escape($newAds))
    }
    Remove-Item -LiteralPath (Join-Path $fx $newAds) -Force

    $s0 = Get-TcTreeSnapshot -Root $fx -Paths $watch
    $run = Invoke-GlChild $repaired
    $g = Get-GlRound $fx $watch $s0
    $v = Get-TcLeftoverVerdict -Changes $g.Stage.Changes -Kind 'linked' -Watched $g.After.Files.Count -Ignored $g.Stage.Ignored
    Test-GlCase 'MUST NOT FIRE  the repair (the verdict on its own line) changes nothing where the bot stages, and a linked worktree passes' { ($g.Changes.Count -eq 0) -and ($v.Fail -eq $false) }
    Test-GlCase 'CLEAN TWIN  the repaired self-test still runs its case and exits 0 with its PASS line' { ($run.Rc -eq 0) -and ($run.Text -match 'ok    a frozen case') -and ($run.Text -match 'SELF-TEST PASS') }
    Test-GlCase 'CLEAN TWIN  the clean verdict states its denominator: the 2 watched files, not an empty sentence' { ($v.Lines -join ' ') -match '\b2 file\(s\) watched' }

    $s0 = Get-TcTreeSnapshot -Root $fx -Paths $watch
    $board = Join-Path 'store\out' 'comparison-2026-09-11.json'
    [IO.File]::WriteAllText((Join-Path $fx $board), '{}', $utf8)
    $g = Get-GlRound $fx $watch $s0
    Test-GlCase 'CLEAN TWIN  the snapshot sees a new board file the repo ignores, so a drop below is the filter and not a blind walk' { ($g.Changes.Count -eq 1) -and ([string]$g.Changes[0].Path -eq $board) }
    Test-GlCase 'MUST NOT FIRE  git check-ignore drops that board file, which the bot cannot stage' { (@($g.Stage.Changes).Count -eq 0) -and ($g.Stage.Ignored -eq 1) -and ($g.Stage.Error -eq '') }
    Remove-Item -LiteralPath (Join-Path $fx $board) -Force

    $s0 = Get-TcTreeSnapshot -Root $fx -Paths $watch
    $oldAds = Join-Path 'store\out' 'ads-2026-09-10.json'
    [IO.File]::WriteAllText((Join-Path $fx $oldAds), '{"deals":[1,2,3]}', $utf8)
    Remove-Item -LiteralPath (Join-Path $fx 'store\ledger.json') -Force
    $g = Get-GlRound $fx $watch $s0
    Test-GlCase 'MUST FIRE  a committed ad file rewritten to a new length is a changed leftover' { @($g.Stage.Changes | Where-Object { $_.Path -eq $oldAds -and $_.Change -eq 'changed' }).Count -eq 1 }
    Test-GlCase 'MUST FIRE  a watched ledger the pool deleted is a removed leftover, since the bot stages a deletion too' { @($g.Stage.Changes | Where-Object { $_.Path -eq 'store\ledger.json' -and $_.Change -eq 'removed' }).Count -eq 1 }

    $err = Select-TcStageableChange -Root (Join-Path $sb 'no-such-checkout') -Changes @([pscustomobject]@{ Path = 'store\out\x.json'; Change = 'added' })
    Test-GlCase 'MUST FIRE  when git cannot answer, every change is KEPT and the exit code is named - an over-report, never a quiet drop' { (@($err.Changes).Count -eq 1) -and ($err.Error -match 'exited') }

    $lk = Join-Path $sb 'linked'
    $null = New-Item -ItemType Directory -Path $lk
    [IO.File]::WriteAllText((Join-Path $lk '.git'), 'gitdir: X:/nowhere/.git/worktrees/linked', $utf8)
    Test-GlCase 'MUST FIRE  a checkout whose .git is a FILE is a linked worktree, the kind where a leftover fails' { (Get-TcCheckoutKind -Root $lk) -eq 'linked' }
    Test-GlCase 'CLEAN TWIN  a checkout whose .git is a directory is the main checkout' { (Get-TcCheckoutKind -Root $fx) -eq 'main' }
    Test-GlCase 'CLEAN TWIN  the watched set is every entry of the bot''s two staging lists, in backslash form' {
      # ASSIGN, THEN COUNT: both lists return with a leading comma, so @(Get-BotInputPaths) would count ONE element.
      $p = Get-TcBotStagedPaths
      $inputs = Get-BotInputPaths
      $served = Get-BotServedPaths
      ($inputs.Count -gt 1) -and ($p.Count -eq ($inputs.Count + $served.Count)) -and ($p -contains ([string]$inputs[0]).Replace('/', '\')) -and ($p -contains 'public')
    }
  } finally {
    Remove-Item -LiteralPath $sb -Recurse -Force -ErrorAction SilentlyContinue
  }

  if ($script:glCases -eq 0) { Write-Output 'GATE-LEFTOVERS SELF-TEST FAILED (ran zero cases)'; exit 1 }
  if ($script:glFail) { Write-Output ('GATE-LEFTOVERS SELF-TEST FAILED ({0} of {1} case(s))' -f $script:glFail, $script:glCases); exit 1 }
  Write-Output ('GATE-LEFTOVERS SELF-TEST PASSED ({0} of {0} case(s): a self-test that falls through and writes where the bot stages fails a linked worktree and is reviewed in main, its repair and an ignored file pass, and a change or a deletion is caught)' -f $script:glCases)
  exit 0
}
