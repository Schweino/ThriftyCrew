# tree-walk.ps1 - THE one way a walk over this tree decides a path is excluded: on the part BELOW the root.
#
# WHY THIS EXISTS (2026-09-11). Nineteen walks in seventeen files excluded \worktrees\ (two of them \.claude\
# as well) by matching the FULL path of every file they found. A linked worktree lives at
# <main>\.claude\worktrees\<name>, so run from one, EVERY file's full path carries both segments and the walk
# excluded the whole tree it was asked to read. Measured from a worktree on 2026-09-11: twelve of fourteen ops
# detectors exited 3 BLIND, run-gates' Python discovery found no suites, and audit-twin-drift's duplicate-literal
# sweep printed "0 undeclared" and exit 0 over nothing at all. Recorded for run-gates on 2026-08-26 and left
# standing; fixed in two places on 2026-09-10 (run-gates' PowerShell discovery, count-source-lifters) and routed
# through here the next day. count-source-lifters keeps its own fixtured copy of the same rule.
#
# THE RULE. An exclusion pattern is matched against the path below the root, with its leading backslash
# kept, so '\\worktrees\\' still drops a SIBLING checkout under the root (.claude\worktrees\other) while a
# root that IS a worktree is scanned, and '\\out\\' still matches a top-level out\. The sibling exclusion is
# not tidiness: a sibling holds another session's copy of these same scripts at another commit, and
# audit-task-registration's first live run reported nine findings, six of them stale copies.
#
# NOT A CHECKOUT DETECTOR. A worktree checked out under a directory that is not named worktrees matches no
# pattern and is not excluded. grocery\audit-script-census.ps1 prunes on the .git entry git itself uses, which
# is the stronger boundary; this file only makes the existing pattern exclusions mean what they say.
#
# THIS FILE DECLARES NO param() BLOCK, DELIBERATELY: dot-sourced under PS 5.1 a param() block runs in the
# CALLER's scope and would reset the caller's own -SelfTest. Same rule as lib\ps-source.ps1.

function Get-TcRootFull {
  # The root spelled the way the walk will spell it: resolved, with no trailing backslash.
  param([string]$Root)
  return (Resolve-Path -LiteralPath $Root).ProviderPath.TrimEnd('\')
}

function Get-TcPathBelowRoot {
  # '\ops\x.ps1' for <root>\ops\x.ps1: the path below the root, leading backslash kept.
  #
  # A path that is NOT under the root comes back whole, which is the old full-path behaviour. That direction
  # over-excludes, and it is loud rather than quiet: every caller reports a walk that found nothing as BLIND.
  param([string]$FullName, [string]$RootFull)
  if ($FullName.Length -gt $RootFull.Length -and
      $FullName.StartsWith($RootFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
    return $FullName.Substring($RootFull.Length)
  }
  return $FullName
}

function Get-TcTreeFiles {
  # Get-ChildItem $RootFull -Recurse -File [-Filter $Filter], file for file and in the same order, except that a
  # directory whose path below the root (with a trailing backslash) matches $PruneBelow is NEVER ENTERED.
  #
  # WHY (2026-09-12). The main checkout holds every linked worktree under .claude\worktrees: measured that day, a
  # recursive .ps1 listing there enumerated 100,747 files against 780 in a worktree. Every walk here excluded the
  # worktrees AFTER listing them, so a push gated from the main checkout ran its whole-tree audits for 239s of wall
  # clock (audit-guard-contract alone 222s) where a worktree took 23-27s. Filtering is not pruning.
  #
  # WHAT IT COPIES from Get-ChildItem under PS 5.1, each measured that day in a temp tree: Hidden files and Hidden
  # directories are skipped and System ones are not; a junction is not entered; each directory yields its own files
  # first, then each subdirectory's subtree in turn; -Filter is the same Win32 match, so '*.ps1' also returns .ps1xml.
  # An unreadable directory is skipped, as -ErrorAction SilentlyContinue skips it. It does NOT copy -Include, which
  # enters junctions and orders its output differently: a caller converting from -Include checks the extension itself.
  #
  # THE PRUNE CANNOT DROP A FILE THE CALLER'S OWN FILTER KEEPS, provided $PruneBelow is that filter's pattern and it
  # carries no end anchor that a directory path could satisfy: every file below a pruned directory has the matched
  # text in its own path below the root, so the caller's filter would have excluded it anyway. A '\\x\.ps1$' alternative
  # can never match a path ending in a backslash, so it prunes nothing. Callers keep their filter; this only removes
  # the cost of listing what it throws away.
  #
  # $SkipDirs names directories by FULL path that are never entered either, for a caller whose exclusion is a set of
  # places rather than a pattern (grocery\audit-script-census.ps1's nested checkouts). The same argument holds: every
  # file below one starts with that path plus a backslash, which is exactly the caller's own test.
  #
  # $Stats, when given, receives Entered (every directory listed, full path) so a test can prove a prune is a prune.
  param([string]$RootFull, [string]$Filter = '*', [string]$PruneBelow = '', [string[]]$SkipDirs = @(), [hashtable]$Stats = $null)
  # .NET resolves a relative path against the PROCESS directory, which is not PowerShell's location, so a root is
  # resolved the PowerShell way first. A root that does not exist yields nothing, as Get-ChildItem's SilentlyContinue did.
  if (-not (Test-Path -LiteralPath $RootFull -PathType Container)) { return @() }
  $RootFull = Get-TcRootFull $RootFull
  $out = New-Object System.Collections.Generic.List[System.IO.FileInfo]
  $entered = New-Object System.Collections.Generic.List[string]
  $skip = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  foreach ($s in @($SkipDirs)) { if ($s) { [void]$skip.Add($s.TrimEnd('\')) } }
  $hidden = [IO.FileAttributes]::Hidden
  $reparse = [IO.FileAttributes]::ReparsePoint
  $stack = New-Object System.Collections.Generic.Stack[System.IO.DirectoryInfo]
  $stack.Push([IO.DirectoryInfo]$RootFull)
  while ($stack.Count -gt 0) {
    $dir = $stack.Pop()
    $entered.Add($dir.FullName)
    try {
      foreach ($file in $dir.EnumerateFiles($Filter)) {
        if (($file.Attributes -band $hidden) -eq 0) { $out.Add($file) }
      }
      $subs = New-Object System.Collections.Generic.List[System.IO.DirectoryInfo]
      foreach ($sub in $dir.EnumerateDirectories()) {
        if (($sub.Attributes -band ($hidden -bor $reparse)) -ne 0) { continue }
        if ($skip.Count -and $skip.Contains($sub.FullName.TrimEnd('\'))) { continue }
        if ($PruneBelow -and (((Get-TcPathBelowRoot $sub.FullName $RootFull) + '\') -match $PruneBelow)) { continue }
        $subs.Add($sub)
      }
      # A stack pops last-in first, so push in reverse to walk the subdirectories in listing order.
      for ($i = $subs.Count - 1; $i -ge 0; $i--) { $stack.Push($subs[$i]) }
    } catch {
      continue
    }
  }
  if ($null -ne $Stats) { $Stats['Entered'] = @($entered.ToArray()) }
  return $out.ToArray()
}

function New-TcWorktreeFixture {
  # A throwaway tree for a detector's self-test, shaped like the real thing: the ROOT the detector is pointed
  # at is <temp>\host\.claude\worktrees\wt1, and every file is written twice, once under that root and once
  # under a SIBLING worktree below it, <root>\.claude\worktrees\sibling. A walk matching the full path finds
  # neither copy; a walk that dropped the exclusion finds both; only a root-relative walk finds exactly the
  # first set. $Files maps a root-relative path to its content.
  #
  # The CALLER removes .Temp, in a finally. The fixture cannot clean up after a self-test it does not own.
  param([hashtable]$Files)
  $temp = Join-Path ([IO.Path]::GetTempPath()) ('tc-wt-' + [guid]::NewGuid().ToString('N'))
  $root = Join-Path $temp 'host\.claude\worktrees\wt1'
  $sibling = Join-Path $root '.claude\worktrees\sibling'
  foreach ($rel in @($Files.Keys)) {
    foreach ($base in @($root, $sibling)) {
      $p = Join-Path $base $rel
      [void](New-Item -ItemType Directory -Force -Path (Split-Path $p -Parent))
      [IO.File]::WriteAllText($p, [string]$Files[$rel], (New-Object Text.UTF8Encoding($false)))
    }
  }
  return [pscustomobject]@{ Temp = $temp; Root = $root; Sibling = $sibling }
}

function Measure-TcWorktreeFixture {
  # How many of a walk's results landed under the fixture's root proper, and how many under its sibling.
  # Takes FileInfo objects or path strings, because the walks here return both.
  param($Fixture, [object[]]$Found)
  $inRoot = 0; $inSibling = 0
  foreach ($x in @($Found)) {
    if ($null -eq $x) { continue }
    $p = if ($x -is [IO.FileSystemInfo]) { $x.FullName } else { [string]$x }
    if ($p.StartsWith($Fixture.Sibling + '\', [StringComparison]::OrdinalIgnoreCase)) { $inSibling++ }
    elseif ($p.StartsWith($Fixture.Root + '\', [StringComparison]::OrdinalIgnoreCase)) { $inRoot++ }
  }
  return [pscustomobject]@{ Root = $inRoot; Sibling = $inSibling }
}

# ---- self-test: powershell -File lib\tree-walk.ps1 -SelfTest ------------------------------------------------------
# The dot-sourced form (lib\selftest-discovery.ps1): no param() block, so the switch is read from $args, and a
# dot-source never runs this.
$__treeWalkSelfTest = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-SelfTest')
if ($__treeWalkSelfTest) {
  $ErrorActionPreference = 'Stop'
  $script:twFail = 0; $script:twCases = 0
  function TwT([string]$m, [bool]$c, [string]$got = '') {
    $script:twCases++
    if ($c) { Write-Output ('ok    ' + $m) } else { Write-Output ('FAIL  ' + $m + '   got: ' + $got); $script:twFail++ }
  }
  $twRoot = Join-Path ([IO.Path]::GetTempPath()) ('tc-tw-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
  $twJunc = Join-Path $twRoot 'junc'
  $twWt = $null
  try {
    try {
      # THE SHAPES Get-ChildItem treats specially, each one measured before this was written: a Hidden file and a Hidden
      # directory (skipped), a System file (kept), a .ps1xml (matched by -Filter *.ps1), a junction (not entered), and
      # the two places the live walks prune, a sibling worktree and an archive.
      foreach ($d in @('a\sub', 'b', 'hid', 'real', 'lib', 'archive', '.claude\worktrees\sib')) {
        [void](New-Item -ItemType Directory -Force -Path (Join-Path $twRoot $d) -ErrorAction Stop)
      }
      foreach ($p in @('z.ps1', 'a.ps1', 'm.py', 'x.ps1xml', 'hiddenfile.ps1', 'sys.ps1', 'a\k.ps1', 'a\sub\s.ps1', 'b\b.ps1',
                       'hid\h.ps1', 'real\r.ps1', 'lib\x.ps1', 'archive\old.ps1', '.claude\worktrees\sib\w.ps1', '.claude\keep.ps1')) {
        [IO.File]::WriteAllText((Join-Path $twRoot $p), '1')
      }
      (Get-Item -LiteralPath (Join-Path $twRoot 'hid')).Attributes = 'Directory,Hidden'
      (Get-Item -LiteralPath (Join-Path $twRoot 'hiddenfile.ps1')).Attributes = 'Hidden'
      (Get-Item -LiteralPath (Join-Path $twRoot 'sys.ps1')).Attributes = 'System'
      $null = cmd /c mklink /J $twJunc (Join-Path $twRoot 'real')
      TwT 'the fixture really holds a junction, so the not-entered case below is not vacuous' `
        ((Test-Path -LiteralPath $twJunc) -and (((Get-Item -LiteralPath $twJunc).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) 'mklink /J made no junction'

      $gciAll = @(Get-ChildItem -LiteralPath $twRoot -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
      $twAll = @(Get-TcTreeFiles -RootFull $twRoot | ForEach-Object { $_.FullName })
      TwT 'CLEAN TWIN  with nothing pruned the walk returns what Get-ChildItem -Recurse -File returns, file for file and in order' `
        ((@($gciAll) -join '|') -ceq (@($twAll) -join '|')) ('gci=' + (@($gciAll) -join ',') + ' walk=' + (@($twAll) -join ','))
      $gciPs1 = @(Get-ChildItem -LiteralPath $twRoot -Recurse -File -Filter *.ps1 -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
      $twPs1 = @(Get-TcTreeFiles -RootFull $twRoot -Filter *.ps1 | ForEach-Object { $_.FullName })
      TwT 'CLEAN TWIN  -Filter *.ps1 matches what Get-ChildItem -Filter matches, .ps1xml included, in order' `
        ((@($gciPs1) -join '|') -ceq (@($twPs1) -join '|')) ('gci=' + (@($gciPs1) -join ',') + ' walk=' + (@($twPs1) -join ','))

      $pat = '\\worktrees\\|\\archive\\'
      $st = @{}
      $twPruned = @(Get-TcTreeFiles -RootFull $twRoot -PruneBelow $pat -Stats $st | ForEach-Object { $_.FullName })
      $gciFiltered = @($gciAll | Where-Object { (Get-TcPathBelowRoot $_ $twRoot) -notmatch $pat })
      TwT 'CLEAN TWIN  a pruned walk returns exactly what the caller''s own filter keeps from the unpruned list' `
        ((@($gciFiltered) -join '|') -ceq (@($twPruned) -join '|')) ('filtered=' + (@($gciFiltered) -join ',') + ' pruned=' + (@($twPruned) -join ','))
      $entered = @($st['Entered'])
      $enteredPruned = @($entered | Where-Object { $_ -like '*\worktrees' -or $_ -like '*\worktrees\*' -or $_ -like '*\archive' })
      TwT 'MUST FIRE  a pruned directory is never LISTED - its parent is, it is not' `
        (($entered -contains (Join-Path $twRoot '.claude')) -and $enteredPruned.Count -eq 0) ('entered=' + ($entered -join ','))
      TwT 'MUST FIRE  a junction is never entered, as Get-ChildItem -Recurse does not enter one' `
        (-not ($entered -contains $twJunc)) ('entered=' + ($entered -join ','))

      $st2 = @{}
      $twAnchored = @(Get-TcTreeFiles -RootFull $twRoot -PruneBelow '\\lib\\x\.ps1$' -Stats $st2 | ForEach-Object { $_.FullName })
      TwT 'MUST NOT FIRE  a file pattern anchored at its end prunes no directory - lib is still listed and its file returned' `
        ((@($st2['Entered']) -contains (Join-Path $twRoot 'lib')) -and ($twAnchored -contains (Join-Path $twRoot 'lib\x.ps1'))) ('entered=' + (@($st2['Entered']) -join ','))

      $st3 = @{}
      $sib = Join-Path $twRoot '.claude\worktrees\sib'
      $twSkip = @(Get-TcTreeFiles -RootFull $twRoot -SkipDirs @($sib + '\') -Stats $st3 | ForEach-Object { $_.FullName })
      $gciSkip = @($gciAll | Where-Object { -not $_.StartsWith($sib + '\', [StringComparison]::OrdinalIgnoreCase) })
      TwT 'MUST FIRE  a directory named in -SkipDirs is never listed, trailing backslash or not' `
        (-not (@($st3['Entered']) -contains $sib)) ('entered=' + (@($st3['Entered']) -join ','))
      TwT 'CLEAN TWIN  -SkipDirs returns exactly what a starts-with filter keeps' `
        ((@($gciSkip) -join '|') -ceq (@($twSkip) -join '|')) ('filtered=' + (@($gciSkip) -join ',') + ' skipped=' + (@($twSkip) -join ','))

      # FROM A ROOT THAT IS ITSELF A WORKTREE: the pattern is matched below the root, so the root is walked and only the
      # sibling below it is pruned - the 2026-09-11 rule this file exists for, now on the prune as well as the filter.
      $twWt = New-TcWorktreeFixture -Files @{ 'ops\y.ps1' = '1'; 'grocery\z.ps1' = '1' }
      $st4 = @{}
      $wtFound = @(Get-TcTreeFiles -RootFull $twWt.Root -PruneBelow '\\worktrees\\' -Stats $st4)
      $wtHits = Measure-TcWorktreeFixture -Fixture $twWt -Found $wtFound
      TwT 'MUST FIRE  a root under .claude\worktrees is walked, not pruned whole' ($wtHits.Root -eq 2) ('root=' + $wtHits.Root)
      TwT 'MUST NOT FIRE  the sibling worktree below that root is neither returned nor listed' `
        ($wtHits.Sibling -eq 0 -and -not (@($st4['Entered']) | Where-Object { $_.StartsWith($twWt.Sibling, [StringComparison]::OrdinalIgnoreCase) })) ('sibling=' + $wtHits.Sibling)
    } catch {
      TwT ('the self-test ran to the end without throwing') $false $_.Exception.Message
    }
  } finally {
    if (Test-Path -LiteralPath $twJunc) { [IO.Directory]::Delete($twJunc) }
    Remove-Item -LiteralPath $twRoot -Recurse -Force -ErrorAction SilentlyContinue
    if ($twWt) { Remove-Item -LiteralPath $twWt.Temp -Recurse -Force -ErrorAction SilentlyContinue }
  }
  $twExpected = 11
  if ($script:twCases -ne $twExpected) { Write-Output ('FAIL  ran ' + $script:twCases + ' case(s), the list holds ' + $twExpected); $script:twFail++ }
  if ($script:twFail -eq 0) { Write-Output ('tree-walk SELF-TEST PASS (' + $script:twCases + ' cases)'); exit 0 }
  else { Write-Output ('tree-walk SELF-TEST FAIL (' + $script:twFail + ' of ' + $script:twCases + ')'); exit 1 }
}
