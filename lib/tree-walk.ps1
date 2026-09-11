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
