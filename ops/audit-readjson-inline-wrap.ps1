<#
  audit-readjson-inline-wrap.ps1 - no script wraps a Read-JsonFile call inline as @(Read-JsonFile ...).

  WHY (2026-09-21). lib\json-io.ps1's Read-JsonFile returns ,$x on purpose, so an assigned result keeps its
  array-ness. Wrapped INLINE, `@(Read-JsonFile x)` is a one-element array whose only element is the whole file,
  so `foreach ($r in @(Read-JsonFile x))` runs ONCE over every row at once. .claude\rules\ops-and-gates.md has
  forbidden the inline wrap in prose since 2026-09-06 ("Never wrap a function call inline as @(Get-Thing ...)"),
  and it recurred anyway, silently, in three places found on 2026-09-21:
    meal-prep\pipeline\sync-recipesdb-cost.ps1   the partial-cost gate's costed map, empty on every run: each
                                                 run printed "costed COULD NOT READ" and refused nothing
    meal-prep\pipeline\wave-preaudit.ps1 (x2)    the costed and ingredient maps collapsed to one key
  A rule that recurs despite a memory needs a gate. This holds the shape at ZERO.

  THE WALK EXCLUDES BELOW THE ROOT AND PRUNES (2026-09-23, design\PLAN-brain-consults-on-code-and-analysis-2026-09-22.md
  W6.9). The first version matched its exclusion against each file's FULL path, which is tree-walk's founding bug: a
  linked worktree lives under .claude\worktrees\, so from every worktree it excluded every file, printed
  "scanned=0 findings=0" and exited 0. Measured over the gate readings of every checkout on 2026-09-22 and 23: 40
  readings in 11 worktrees, every one scanned=0, and run-gates scored each one ok. It now walks through
  lib\tree-walk.ps1's Get-TcTreeFiles, which never enters a directory the exclusion drops, keeps the same exclusion as
  a filter on the path BELOW the root, and a walk that resolves nothing exits 3 BLIND rather than passing.

  THE DELIBERATE EXCEPTION: a line carrying `# readjson-wrap:allow <reason>` (grocery\test-auditors.ps1 probes
  the trap on purpose). A marker with no reason exempts nothing. This file is excluded from its own scan.
  NOT COVERED, stated: the same trap through any OTHER comma-returning function; only Read-JsonFile is named.

  SCOPE OF A CLEAN REPORT: UNSOUND, so a clean report proves nothing. It reads source text line by line and knows one
  spelling, @( directly before Read-JsonFile on one line; a call split across lines, reached through an alias or a
  variable, or made by another comma-returning reader is invisible to it. It is also INCOMPLETE: a flagged wrap is
  harmless when the file holds one object rather than an array, so a finding is a candidate to read, not a verdict.

  Exit 0 clean, 1 findings, 3 could not evaluate (the walk resolved no .ps1 at all). Last line
  READJSON-INLINE-WRAP-COMPLETE. Self-test: -SelfTest.
#>
[CmdletBinding()]
param([switch]$SelfTest, [string]$Root = '')
$ErrorActionPreference = 'Stop'
# The libraries come from THIS script's checkout; -Root only moves what is scanned, so the self-test can point a child
# run at a fixture tree and still load the real tree-walk.
$libRepo = Split-Path -Parent $PSScriptRoot
$repo = if ($Root) { $Root } else { $libRepo }
. (Join-Path $libRepo 'lib\tree-walk.ps1')   # Get-TcTreeFiles / Get-TcPathBelowRoot: prune and exclude BELOW the root

# ONE PATTERN FOR THE PRUNE AND THE FILTER, so the prune can never drop a file the filter keeps (lib\tree-walk.ps1).
$script:RJW_EXCLUDE = '\\(\.claude\\worktrees|archive|node_modules|\.git)\\'

function Get-RjwScanFiles {
  # Every .ps1 below $RootDir, excluded on the path BELOW the root, never entering an excluded directory, and never $Self.
  param([string]$RootDir, [string]$Self = '')
  $rootFull = Get-TcRootFull $RootDir
  $walk = @(Get-TcTreeFiles -RootFull $rootFull -Filter '*.ps1' -PruneBelow $script:RJW_EXCLUDE)
  return ,@($walk | Where-Object { (Get-TcPathBelowRoot $_.FullName $rootFull) -notmatch $script:RJW_EXCLUDE -and $_.FullName -ne $Self })
}

function Find-RjwSites { param([string]$Text)
  $out = @(); $n = 0; $inBlock = $false
  foreach ($line in ($Text -split "`n")) {
    $n++
    # a <# ... #> block comment is prose about the trap, not a call
    if ($inBlock) { if ($line -match '#>') { $inBlock = $false }; continue }
    if ($line -match '^\s*<#' -and $line -notmatch '#>') { $inBlock = $true; continue }
    if ($line -notmatch ('@\(\s*' + 'Read-JsonFile\b')) { continue }
    if ($line -match '#[^\n]*readjson-wrap:allow\s+\S') { continue }
    if ($line.TrimStart().StartsWith('#')) { continue }
    $out += $n
  }
  return ,$out
}

if ($SelfTest) {
  $f = 0; $c = 0
  function T($m, $ok, $g) { $script:c++; if ($ok) { "ok    $m" } else { "FAIL  $m   got: $g"; $script:f++ } }
  $fn = 'Read-' + 'JsonFile'
  $r = Find-RjwSites ('try { foreach ($c in @(' + $fn + ' $cdPath)) { $x = 1 } } catch {}')
  T 'MUST FIRE  the founding line from sync-recipesdb-cost (foreach over an inline-wrapped read)' ($r.Count -eq 1) $r.Count
  $r = Find-RjwSites ('$rows = @( ' + $fn + ' $p )')
  T 'MUST FIRE  an inline wrap with inner spaces' ($r.Count -eq 1) $r.Count
  $r = Find-RjwSites ('$rows = ' + $fn + ' $p' + "`n" + 'foreach ($r in $rows) { }' + "`n" + '$n = @($rows).Count')
  T 'MUST NOT FIRE  assign, then iterate or wrap the variable' ($r.Count -eq 0) $r.Count
  $r = Find-RjwSites ('$w = @(' + $fn + ' $probe)   # readjson-wrap:allow deliberate probe of the trap')
  T 'MUST NOT FIRE  a marked line with a reason' ($r.Count -eq 0) $r.Count
  $r = Find-RjwSites ('$w = @(' + $fn + ' $probe)   # readjson-wrap:allow')
  T 'MUST FIRE  a marker with no reason exempts nothing' ($r.Count -eq 1) $r.Count
  $r = Find-RjwSites ('  # never write @(' + $fn + ' x) - it collapses')
  T 'MUST NOT FIRE  a comment describing the trap' ($r.Count -eq 0) $r.Count
  $r = Find-RjwSites ("<#" + "`n" + '  the old reader wrapped @(' + $fn + ' ingredients.json)' + "`n" + '#>' + "`n" + '$x = @(' + $fn + ' y)')
  T 'MUST NOT FIRE / MUST FIRE  prose inside a <# #> block is skipped, and the call after the block is still caught (line 4)' ($r.Count -eq 1 -and $r[0] -eq 4) ($r -join ',')
  # CLEAN TWIN: the trap this guards is still real in this PowerShell, or the gate guards a ghost
  . (Join-Path $libRepo 'lib\json-io.ps1')
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ('rjw-' + [guid]::NewGuid().ToString('N') + '.json')
  [IO.File]::WriteAllText($tmp, '[{"a":1},{"a":2},{"a":3}]')
  try { $wrapped = @(Read-JsonFile $tmp); $assigned = Read-JsonFile $tmp } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }   # readjson-wrap:allow the self-test proves the trap
  T 'CLEAN TWIN  the trap is live: inline-wrapped reads 1 element, assigned reads 3' ($wrapped.Count -eq 1 -and @($assigned).Count -eq 3) ("wrapped=" + $wrapped.Count + " assigned=" + @($assigned).Count)

  # ---- THE WALK, FROM A WORKTREE ROOT (lib\tree-walk.ps1, 2026-09-23) --------------------------------------------
  # The founding bug of this file's first version: the exclusion matched the FULL path, so a root under
  # .claude\worktrees\ scanned nothing. New-TcWorktreeFixture writes every file under the root AND under a sibling
  # worktree below it, so a full-path walk finds neither copy and a walk that dropped the exclusion finds both.
  $planted = '$rows = @(' + $fn + ' $p)'
  $wtFx = New-TcWorktreeFixture -Files @{
    'meal-prep\pipeline\fx-wrap.ps1' = $planted; 'ops\fx-clean.ps1' = ('$rows = ' + $fn + ' $p')
    'archive\fx-old.ps1' = $planted; 'node_modules\pkg\fx-dep.ps1' = $planted; 'ops\fx-self.ps1' = $planted }
  $psexe = Join-Path $PSHOME 'powershell.exe'
  $emptyRoot = Join-Path ([IO.Path]::GetTempPath()) ('rjw-empty-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
  try {
    $self = Join-Path $wtFx.Root 'ops\fx-self.ps1'
    $found = Get-RjwScanFiles -RootDir $wtFx.Root -Self $self
    $hits = Measure-TcWorktreeFixture -Fixture $wtFx -Found $found
    T 'MUST FIRE  a root that IS a worktree is walked, not excluded whole (two .ps1 below it: not archive\, node_modules\ or itself)' ($hits.Root -eq 2) ('root=' + $hits.Root)
    T 'MUST NOT FIRE  the sibling worktree below that root is not counted' ($hits.Sibling -eq 0) ('sibling=' + $hits.Sibling)
    T 'MUST NOT FIRE  the detector never scans itself' (@($found | Where-Object { $_.FullName -eq $self }).Count -eq 0) ''
    # The prune must return exactly what the old filter kept from the unpruned list, on the path below the root.
    $rf = Get-TcRootFull $wtFx.Root
    $unpruned = @(Get-ChildItem -LiteralPath $rf -Recurse -File -Filter '*.ps1' -ErrorAction SilentlyContinue |
      Where-Object { (Get-TcPathBelowRoot $_.FullName $rf) -notmatch $script:RJW_EXCLUDE -and $_.FullName -ne $self } | ForEach-Object { $_.FullName })
    $pruned = @($found | ForEach-Object { $_.FullName })
    T 'CLEAN TWIN  the pruned walk returns what the below-root filter keeps from an unpruned listing, file for file' ((@($unpruned) -join '|') -ceq (@($pruned) -join '|')) ('unpruned=' + (@($unpruned) -join ',') + ' pruned=' + (@($pruned) -join ','))

    # THE LIVE PATH, as a child: the planted wrap is found from the worktree root and the sibling's copy is not.
    $o = @(& $psexe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $wtFx.Root)
    $rc = $LASTEXITCODE
    $o = @($o | ForEach-Object { [string]$_ })
    $txt = $o -join "`n"
    $mk = if ($o.Count) { $o[$o.Count - 1] } else { '' }
    # fx-self.ps1 is scanned here: in a child run the detector's own path is this file, not the fixture's.
    T 'MUST FIRE  a child run from the worktree root reports the planted wrap, exits 1, and scanned is not zero' ($rc -eq 1 -and $txt -like '*meal-prep\pipeline\fx-wrap.ps1:1*' -and $mk -match 'scanned=3 findings=2$') ("rc=$rc last=$mk")
    T 'MUST NOT FIRE  ...and names nothing under the sibling worktree, archive\ or node_modules\' ($txt -notlike '*worktrees\sibling*' -and $txt -notlike '*archive\fx-old*' -and $txt -notlike '*node_modules*') $txt

    # BLIND ON ZERO: a walk that resolves no .ps1 is could-not-evaluate, never a clean scan.
    [void](New-Item -ItemType Directory -Path $emptyRoot -ErrorAction Stop)
    [IO.File]::WriteAllText((Join-Path $emptyRoot 'notes.txt'), 'no scripts here')
    $o2 = @(& $psexe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $emptyRoot)
    $rc2 = $LASTEXITCODE
    $o2 = @($o2 | ForEach-Object { [string]$_ })
    $mk2 = if ($o2.Count) { $o2[$o2.Count - 1] } else { '' }
    T 'MUST FIRE  a walk that resolves zero .ps1 exits 3 with scanned=0 blind=1 as its last line, never 0' ($rc2 -eq 3 -and $mk2 -ceq 'READJSON-INLINE-WRAP-COMPLETE scanned=0 blind=1') ("rc=$rc2 last=$mk2")
  } catch {
    T 'the walk cases ran to the end without throwing' $false $_.Exception.Message
  } finally {
    Remove-Item -LiteralPath $wtFx.Temp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $emptyRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
  $expected = 15
  if ($c -ne $expected) { "FAIL  ran $c case(s), the list holds $expected"; $f++ }
  if ($f -eq 0) { "audit-readjson-inline-wrap self-test PASS ($c cases)"; exit 0 } else { "audit-readjson-inline-wrap self-test FAIL ($f of $c)"; exit 1 }
}

$rootFull = Get-TcRootFull $repo
$files = Get-RjwScanFiles -RootDir $rootFull -Self $PSCommandPath
if ($files.Count -eq 0) {
  "readjson-inline-wrap: COULD NOT EVALUATE - the walk below $rootFull resolved zero .ps1 files, which is the walk broken, not the tree clean"
  'READJSON-INLINE-WRAP-COMPLETE scanned=0 blind=1'
  exit 3
}
$hits = @()
foreach ($fi in $files) {
  $t = [IO.File]::ReadAllText($fi.FullName)
  if ($t.IndexOf('Read-JsonFile') -lt 0) { continue }
  foreach ($ln in (Find-RjwSites $t)) { $hits += ((Get-TcPathBelowRoot $fi.FullName $rootFull).TrimStart('\') + ':' + $ln) }
}
foreach ($h in $hits) { "  INLINE WRAP  $h  - assign the Read-JsonFile result to a variable first, then iterate or wrap the variable" }
"readjson-inline-wrap: scanned $($files.Count) .ps1 file(s), $($hits.Count) inline-wrapped Read-JsonFile call(s)"
"READJSON-INLINE-WRAP-COMPLETE scanned=$($files.Count) findings=$($hits.Count)"
if ($hits.Count) { exit 1 } else { exit 0 }
