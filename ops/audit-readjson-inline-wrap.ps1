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

  THE SECOND SHAPE: @(... | ConvertFrom-Json) (2026-10-02, queue 2026-09-28-3849bc, Phase 6 of
  design\PLAN-weekly-root-families-2026-10-02.md). Under PS 5.1 ConvertFrom-Json writes a top-level JSON array down
  the pipe as ONE object, so @() around the pipe is a one-element array holding the whole file. health-heartbeat read
  queue-depth -Json that way and raised no QUEUE STUCK or QUEUE UNMEASURED from 2026-09-07 to 2026-09-28. It is matched
  on the AST, not the text: an ArrayExpression whose only statement is a pipeline of two or more elements ending in
  ConvertFrom-Json. So comments never match, and neither does @((x | ConvertFrom-Json)) or @((x | ConvertFrom-Json).p),
  whose inner parentheses unroll. MEASURED that day over this walk (775 .ps1): the queue's text regex matched 87
  lines, 80 of them comments or the unrolling forms; the AST matched 7 in 6 files. Two were deliberate MUST FIRE
  probes (now marked), five read a top-level array and were fixed in the same change (build-arrivals-docket's
  commodity labels had never loaded: one key holding all 599 ids). So this shape is held at ZERO like the first, not
  ratcheted: with no backlog a ratchet's mark is 0 and it is the same gate with a baseline file to keep (rule og-11
  is for a backlog nobody is about to clear).
  NOT HELD, measured and left out: the og-08 shape @(Get-Thing ...). 711 single-command @(Get-X) wraps in 775 files,
  518 calling something other than a built-in cmdlet, 36 whose callee NAME comma-returns somewhere in the tree (348
  such names). The trap needs a comma-returning callee, and names collide (Get-MatchTexts is defined six times, one a
  comma-returning test stub), so a count of the shape mixes the correct idiom with the trap. Holding it soundly needs
  per-file dot-source resolution, and a whole-tree parse costs about 8 s a push.

  THE DELIBERATE EXCEPTION: a line carrying `# readjson-wrap:allow <reason>` (grocery\test-auditors.ps1 probes
  the trap on purpose). A marker with no reason exempts nothing. This file is excluded from its own scan.
  NOT COVERED, stated: the same trap through any OTHER comma-returning function; only Read-JsonFile is named.

  SCOPE OF A CLEAN REPORT: UNSOUND, so a clean report proves nothing. The Read-JsonFile half reads source text line by
  line and knows one spelling, @( directly before Read-JsonFile on one line; a call split across lines, reached
  through an alias or a variable, or made by another comma-returning reader is invisible to it. The ConvertFrom-Json
  half sees only the pipe written inside the @(); a pipe result held in a variable, or a [IO.File] read handed to
  ConvertFrom-Json -InputObject, is outside it, and so is a file whose reader call continues its arguments onto the
  next line with a backtick (the text prefilter needs the closing paren on the reader's line). Both are INCOMPLETE: a flagged wrap is harmless when the JSON holds
  one object rather than an array, so a finding is a candidate to read, not a verdict.

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

$script:RJW_PIPE_PREFILTER = '(?i)\|\s*' + 'ConvertFrom-' + 'Json\b[^|\n]*\)'

function Find-RjwPipeSites { param([string]$Text)
  # Line numbers of @(<a> | ... | ConvertFrom-Json): an ArrayExpression whose ONLY statement is a pipeline of two or
  # more elements whose last is ConvertFrom-Json. Read off the AST, so a comment or a string never matches, and the
  # unrolling forms @((x | ConvertFrom-Json)) and @((x | ConvertFrom-Json).p) are not this shape.
  $tok = $null; $err = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tok, [ref]$err)
  $lines = $Text -split "`n"
  $out = @()
  $arrs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ArrayExpressionAst] }, $true)
  foreach ($a in $arrs) {
    $st = $a.SubExpression.Statements
    if ($st.Count -ne 1 -or $st[0] -isnot [System.Management.Automation.Language.PipelineAst]) { continue }
    $els = $st[0].PipelineElements
    if ($els.Count -lt 2) { continue }
    $last = $els[$els.Count - 1]
    if ($last -isnot [System.Management.Automation.Language.CommandAst]) { continue }
    if (-not [string]::Equals([string]$last.GetCommandName(), ('ConvertFrom-' + 'Json'), [StringComparison]::OrdinalIgnoreCase)) { continue }
    $n = $a.Extent.StartLineNumber
    if ($lines[$n - 1] -match '#[^\n]*readjson-wrap:allow\s+\S') { continue }
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

  # ---- THE SECOND SHAPE, @(... | ConvertFrom-Json), read off the AST (2026-10-02, queue 2026-09-28-3849bc) ----------
  # Needles by concatenation (og-03); this file is also excluded from its own live scan.
  $cj = 'ConvertFrom-' + 'Json'
  $r = Find-RjwPipeSites ('$qrows = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $qd -Json | ' + $cj + ')')
  T 'MUST FIRE  the health-heartbeat founding line (queue-depth -Json piped into the reader inside @())' ($r.Count -eq 1) $r.Count
  $r = Find-RjwPipeSites ('if ($craw -ne '''') { foreach ($cr in @($craw | ' + $cj + ')) { $x = 1 } }')
  T 'MUST FIRE  the build-arrivals-docket line (foreach over a wrapped pipe of a JSON string)' ($r.Count -eq 1) $r.Count
  $r = Find-RjwPipeSites ('$rows = @(Get-Content $p -Raw |' + "`n" + '  ' + $cj + ')')
  T 'MUST FIRE  a pipe split across lines after its bar is one site, at the line the @( opens (1)' ($r.Count -eq 1 -and $r[0] -eq 1) ($r -join ',')
  $r = Find-RjwPipeSites ('$parsed = Get-Content $p -Raw | ' + $cj + "`n" + '$rows = @($parsed)')
  T 'MUST NOT FIRE  assign, then wrap the variable' ($r.Count -eq 0) $r.Count
  $r = Find-RjwPipeSites ('$rows = @((Get-Content $p -Raw | ' + $cj + '))' + "`n" + '$its = @((Get-Content $q -Raw | ' + $cj + ').items)')
  T 'MUST NOT FIRE  the doubled-paren and property forms, whose inner parentheses unroll' ($r.Count -eq 0) $r.Count
  $r = Find-RjwPipeSites ('# never write @(x | ' + $cj + ') - it collapses' + "`n" + '<#' + "`n" + ' @(y | ' + $cj + ')' + "`n" + '#>' + "`n" + '$s = ''@(z | ' + $cj + ')''')
  T 'MUST NOT FIRE  a line comment, a block comment and a string that spell the shape' ($r.Count -eq 0) $r.Count
  $r = Find-RjwPipeSites ('$bad = @(Get-Content $f -Raw | ' + $cj + ')   # readjson-wrap:allow MUST FIRE probe of the trap')
  T 'MUST NOT FIRE  a marked line with a reason' ($r.Count -eq 0) $r.Count
  $r = Find-RjwPipeSites ('$bad = @(Get-Content $f -Raw | ' + $cj + ')   # readjson-wrap:allow')
  T 'MUST FIRE  a marker with no reason exempts nothing' ($r.Count -eq 1) $r.Count
  $r1 = Find-RjwSites ('$a = @(' + $fn + ' $p)' + "`n" + '$b = @($t | ' + $cj + ')')
  $r2 = Find-RjwPipeSites ('$a = @(' + $fn + ' $p)' + "`n" + '$b = @($t | ' + $cj + ')')
  T 'CLEAN TWIN  one file with both shapes: the Read-JsonFile half still names line 1, the pipe half names line 2' ($r1.Count -eq 1 -and $r1[0] -eq 1 -and $r2.Count -eq 1 -and $r2[0] -eq 2) ("readjson=" + ($r1 -join ',') + " pipe=" + ($r2 -join ','))
  # each fixture assigned first: in @('a' + $x, 'b') the comma binds before the plus (og-07)
  $pf1 = '$qrows = @(& powershell -File $qd -Json | ' + $cj + ')'
  $pf2 = 'foreach ($cr in @($craw | ' + $cj + ')) { }'
  $pf3 = '$rows = @(Get-Content $p -Raw |' + "`n" + '  ' + $cj + ')'
  $pf4 = '$r = @($t | ' + $cj + ' -Depth 5)'
  $pf = @($pf1, $pf2, $pf3, $pf4)
  $pfKept = @($pf | Where-Object { ($_ -match $script:RJW_PIPE_PREFILTER) -and (Find-RjwPipeSites $_).Count -eq 1 })
  T 'CLEAN TWIN  the text prefilter keeps every MUST FIRE shape the AST fires on (4 of 4, an argument list included)' ($pfKept.Count -eq 4) ('kept ' + $pfKept.Count + ' of 4')
  $three = '[{"a":1},{"a":2},{"a":3}]'
  $pw = @($three | ConvertFrom-Json)   # readjson-wrap:allow the self-test proves the pipe trap is live
  $pa = $three | ConvertFrom-Json
  T 'CLEAN TWIN  the pipe trap is live in this PowerShell: wrapped reads 1 element, assigned then wrapped reads 3' ($pw.Count -eq 1 -and @($pa).Count -eq 3) ("wrapped=" + $pw.Count + " assigned=" + @($pa).Count)

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
  $barRoot = Join-Path ([IO.Path]::GetTempPath()) ('rjw-bar-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
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

    # THE BAR IS ZERO for the pipe shape. AT it: a tree whose only reads assign then wrap passes. One PAST it: the
    # same tree plus one wrapped pipe fails and names it (og-06).
    [void](New-Item -ItemType Directory -Path (Join-Path $barRoot 'grocery') -ErrorAction Stop)
    [IO.File]::WriteAllText((Join-Path $barRoot 'grocery\fx-ok.ps1'), ('$p = $t | ' + $cj + "`n" + '$rows = @($p)'))
    $o3 = @(& $psexe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $barRoot)
    $rc3 = $LASTEXITCODE
    $o3 = @($o3 | ForEach-Object { [string]$_ })
    $mk3 = if ($o3.Count) { $o3[$o3.Count - 1] } else { '' }
    T 'MUST NOT FIRE  AT THE BAR (0 pipe wraps, bar 0): a child run exits 0 with scanned=1 findings=0' ($rc3 -eq 0 -and $mk3 -ceq 'READJSON-INLINE-WRAP-COMPLETE scanned=1 findings=0') ("rc=$rc3 last=$mk3")
    [IO.File]::WriteAllText((Join-Path $barRoot 'grocery\fx-bad.ps1'), ('$x = 1' + "`n" + '$rows = @($t | ' + $cj + ')'))
    $o4 = @(& $psexe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $barRoot)
    $rc4 = $LASTEXITCODE
    $o4 = @($o4 | ForEach-Object { [string]$_ })
    $mk4 = if ($o4.Count) { $o4[$o4.Count - 1] } else { '' }
    T 'MUST FIRE  ONE PAST THE BAR (1 pipe wrap, bar 0): exits 1, names grocery\fx-bad.ps1:2, scanned=2 findings=1' ($rc4 -eq 1 -and (($o4 -join "`n") -like '*grocery\fx-bad.ps1:2*') -and $mk4 -ceq 'READJSON-INLINE-WRAP-COMPLETE scanned=2 findings=1') ("rc=$rc4 last=$mk4")
  } catch {
    T 'the walk cases ran to the end without throwing' $false $_.Exception.Message
  } finally {
    Remove-Item -LiteralPath $wtFx.Temp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $emptyRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $barRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
  $expected = 28
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
$hits = @(); $pipeHits = @(); $pipeRead = 0
foreach ($fi in $files) {
  $t = [IO.File]::ReadAllText($fi.FullName)
  $rel = (Get-TcPathBelowRoot $fi.FullName $rootFull).TrimStart('\')
  if ($t.IndexOf('Read-JsonFile') -ge 0) {
    foreach ($ln in (Find-RjwSites $t)) { $hits += ($rel + ':' + $ln) }
  }
  # PARSE ONLY A CANDIDATE: a pipe into the reader that a ')' closes before the next pipe. Every AST site is one, so
  # the prefilter drops none of them (bar a backtick-continued argument list, stated in the header). Parsing every
  # file that names the reader (384 of 774) took the gate from 1.0 s to 7.0 s; this parses 177, about 4 s.
  if ($t -match $script:RJW_PIPE_PREFILTER) {
    $pipeRead++
    foreach ($ln in (Find-RjwPipeSites $t)) { $pipeHits += ($rel + ':' + $ln) }
  }
}
foreach ($h in $hits) { "  INLINE WRAP  $h  - assign the Read-JsonFile result to a variable first, then iterate or wrap the variable" }
foreach ($h in $pipeHits) { "  PIPE WRAP  $h  - @(... | ConvertFrom-Json) is ONE element under PS 5.1 when the JSON is an array: assign the parse, then wrap the variable" }
"readjson-inline-wrap: scanned $($files.Count) .ps1 file(s), $($hits.Count) inline-wrapped Read-JsonFile call(s); parsed $pipeRead candidate file(s) for a wrapped pipe into ConvertFrom-Json, $($pipeHits.Count) found"
$hits = @($hits) + @($pipeHits)
"READJSON-INLINE-WRAP-COMPLETE scanned=$($files.Count) findings=$($hits.Count)"
if ($hits.Count) { exit 1 } else { exit 0 }
