<#
  audit-fixed-temp-names.ps1 - a path under %TEMP% is named PER RUN, never by a fixed leaf.

  SCOPE OF A CLEAN REPORT: UNSOUND. It reads the PowerShell AST and finds the spellings listed under WHAT IT
    SEES. A clean report means none of those spellings builds a fixed name under a temp root. A name built any
    other way - a helper that takes the leaf as a parameter, a temp root reached through an if-expression, a
    script body held in a string and run later, a Python suite - is invisible to it. A reported site is real;
    silence is not proof. It is a RATCHET rather than a gate because the count it measured on its first day is
    not zero, and several of those sites are fixed on purpose.

  WHY THIS EXISTS (2026-09-11). ops\run-gates.ps1 runs every -SelfTest in the tree and the pre-push hook runs
  run-gates, so pushes from concurrent sessions run the SAME suites over each other in one %TEMP%. A suite that
  writes a fixed name there collides with itself. lib\guard-contract.ps1 wrote gc-clobber-probe.ps1,
  gc-invoke-probe.ps1 and gc-probe-out-<mode>.txt there and went red in 6 of 6 run-gates passes under three
  concurrent loops; grocery\test-guards.ps1 -SelfTest journalled into the one fixed tg-restore-journal. Commit
  c3a686290 gave both a per-run directory (GcScratch in lib\guard-contract.ps1 is the exemplar), and
  .claude\rules\ops-and-gates.md states the convention. A rule in a file reaches whoever opens the file. This
  reaches the next suite at push time.

  THE FOUNDING LINES, frozen verbatim from c3a686290^ in the self-test:
    lib\guard-contract.ps1   $probe = Join-Path $env:TEMP 'gc-clobber-probe.ps1', the invoke probe beside it,
                             and the per-mode output file whose only variable was the mode
    grocery\test-guards.ps1  $script:JournalDir = Join-Path $env:TEMP 'tg-restore-journal'

  WHAT IT SEES (from the AST, so comments and quoted prose are never code). A TEMP ROOT is $env:TEMP, $env:TMP,
  [IO.Path]::GetTempPath() or [System.IO.Path]::GetTempPath(), through parens, casts, "$(...)" and the trim
  calls, or a variable assigned one (a parameter default included), followed to a fixpoint within the file.
  A path BUILT UNDER one is any of:
    * Join-Path <root> <leaf>, positional or -Path / -ChildPath in either order
    * [IO.Path]::Combine(<root>, <leaf>, ...)
    * "<root>\<leaf>", an expandable string that opens with the root
    * <root> + <leaf> + ..., counted once however long the chain
  Each such site is then UNIQUE, FIXED, an ABSENCE PROBE or UNRESOLVED:
    UNIQUE      the leaf holds [guid]::NewGuid(), $PID, New-TemporaryFile, [IO.Path]::GetRandomFileName() or
                [IO.Path]::GetTempFileName(), or a variable assigned any of those. $PID counts because no two
                LIVE processes share one, and concurrent runs are the collision this is for. A clock does not
                count: two pushes started in the same tick read the same time. Get-Random does not count either,
                because its seeding under PS 5.1 was not checked here, so it is left to prove itself.
    FIXED       not unique, and the leaf spells literal text: a string constant, a bareword, or an expandable
                string, including one whose variables are ordinary (tc-oracle-$label.log). COUNTED.
    ABSENCE     FIXED, but passed straight in as an argument to a Get-, Read- or Test- command. LISTED, NOT
    PROBE       COUNTED. See below.
    UNRESOLVED  the leaf is only a variable or a call, with no literal text. Not counted, and printed as a count
                so what the detector could not judge is visible.
  The name-keyed taint is file-wide, so a variable assigned a guid ANYWHERE in the file makes every use of that
  name unique. That leans toward silence on purpose, and it is one of the reasons a clean report proves nothing.

  THE ABSENCE-PROBE RULING (decided 2026-09-11). ops\audit-memory-backup.ps1:475 and ops\sidecar-watchdog.ps1:240
  pass Join-Path $env:TEMP 'no-such-...' to a reader and assert the missing-file branch. Two concurrent runs of
  such a suite cannot collide: both only read an absence, and on the day this shipped no file in the tree
  spelled any of the six probe names anywhere else, let alone wrote one. Counting them would fill the ratchet
  with sites that do not carry the defect it exists for, and a list with junk in it is a list nobody lowers.
  They carry a DIFFERENT, weaker defect - the verdict assumes nothing else on the box ever created that name in
  a %TEMP% every process shares - which a guid leaf removes, so they are printed on their own lines. The line is
  drawn on the verb rather than the word no-such because a verb is the caller's declared intent and a word is an
  exemption anyone can spell. The SAME leaf assigned to a variable, or piped to Set-Content, is counted: the
  detector cannot follow a variable to a read, and does not pretend to.

  WHAT IT DELIBERATELY DOES NOT FLAG. Join-Path $gcRoot $leaf, where $gcRoot is itself a guid-named directory
  under TEMP, is below a per-run root and is exactly the fixed form. A temp root passed ALONE (Test-Plan ... $env:TEMP)
  builds no name. \out\ is not walked: gitignored scratch lands there in the main checkout, and a ratchet that
  counts untracked files reads differently in every checkout. Python is not read at all; on the day this shipped
  meal-prep\pipeline\harvest.py held the tree's only three os.environ TEMP joins, and all three carry os.getpid().

  THE RATCHET, MEASURED 2026-09-11 at 3176eb82b through this file, from a linked worktree: 576 .ps1 resolved,
  147 spell a temp root, 264 paths built under one. 247 are unique per run, 0 unresolved, 6 are absence probes
  (listed), and the mark starts at the 11 FIXED:
    grocery\test-guards.ps1:61                     tg-restore-journal. SHARED ON PURPOSE: a killed run's successor
                                                   must find it, and c3a686290 redirected it inside the self-test.
    grocery\test-auditors.ps1:99 and :1034         %TEMP%\lib, where fixture copies of detectors find ..\lib. Shared
                                                   on purpose, but ops\prepush-test-auditors.ps1 runs test-auditors
                                                   cases before a push, so two pushes from different checkouts copy
                                                   different library versions into that one directory.
    grocery\test-precedence-ladders.ps1:60         tc-precedence-fixture, the target of a robocopy /MIR
    grocery\run-test-guards-weekly.ps1:26          smp-test-guards-hermetic
    ops\consistency-oracle.ps1:207                 tc-oracle-$label.log, each arm's log in Invoke-TcArm
    meal-prep\pipeline\feed-freshness.ps1:350      ff-clobber-probe.ps1, the guard-contract founding shape in this
                                                   file's own self-test block. FIXED and the mark lowered to 10 the
                                                   same day: it was measured red in 29 of 60 concurrent writer runs,
                                                   19 of them dying with no verdict line at all, and moved under a
                                                   per-run scratch directory. The fixture line above stays frozen.
    meal-prep\pipeline\run-scaler-pricing-test.ps1:56 and :83   the runner and page fixtures
    meal-prep\build-hub-grid.ps1:36                tc-hub-work
    grocery\backfill-aldi-link-urls.ps1:472        the dry-run report, named by board date
  Six of these were known before it ran; the last five were found by its first run. The first version took 89.7 s
  because it ran the AST taint test on every binding in every pass. Gating each test on a text mention it cannot
  pass without took the same tree to 16.2 s with identical output, 18 of 18 report lines. A mutation probe of 9
  single edits from a temp mirror killed 8; the survivor was a root reached through two variables, which now has
  its own case.

  A RUN THAT IS NOT ASKED TO RECORD WRITES NOTHING (2026-09-12, the rule 740c82af6 gave the other seven
  ratchets and this one did not get). run-gates runs every static audit with NO arguments on every pre-push, so a
  fall used to rewrite the TRACKED baseline inside the checkout being pushed. Measured that day: a plain run
  printed "PASSED and TIGHTENED - 9 finding(s), down from 10" and left ops\fixed-temp-names-baseline.json ` M`,
  which also made run-gates report "this pass is NOT recorded for reuse - the checkout changed while the gates
  ran", so the run's own green verdict could not be reused and the next push paid for all 362 gates again.
  Reproduced at 740c82af6 in this checkout with the mark set to 11: exit 0, "PASSED and TIGHTENED", baseline ` M`.
  The rewrite never rode that push either, so the lower mark protected only the checkout that happened to run it,
  and a count taken over uncommitted edits is not a baseline. So a fall is SPOKEN and the committed mark KEPT;
  -Tighten records it, through lib\ratchet.ps1's plausibility bar and in the bytes git stores (lib\lf-write.ps1).

  ONE DELIBERATE DIFFERENCE FROM ops\audit-write-only-reports.ps1, which exits 2 on an implausible fall only when
  a record was asked for: this one exits 2 either way, as it always has. A fall to zero or past -MaxDropPct here
  means the AST test stopped seeing sites the tree still holds, and that is a broken detector rather than a clean
  tree - the one thing this file's own SCOPE line says silence never proves. Nothing is written on that path
  regardless, so the red costs a run, never a baseline.

  EXIT CODES (lib\guard-contract.ps1 vocabulary): 0 at or below the high-water mark, 2 the mark rose or a fall
  was refused as implausible, 3 could not evaluate. Read the verdict LINE, not the number.

    ops\audit-fixed-temp-names.ps1               scan the tree, hold the ratchet; writes NOTHING
    ops\audit-fixed-temp-names.ps1 -Tighten      the same, and record a believable FALL as the new high-water mark
    ops\audit-fixed-temp-names.ps1 -AcceptDrop   record a fall lib\ratchet.ps1 would otherwise refuse
    ops\audit-fixed-temp-names.ps1 -SelfTest     frozen founding lines, the per-run forms, the probes, the walk,
                                                 and this script's live path against a temp tree and baseline
#>
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop (2026-09-07)
param([switch]$SelfTest, [switch]$AcceptDrop, [switch]$Tighten, [string]$Root = '', [string]$BaselineFile = '')
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\ratchet.ps1')
. (Join-Path $repo 'lib\lf-write.ps1')    # Write-TcLfFile: the baseline is TRACKED and stored eol=lf
. (Join-Path $repo 'lib\tree-walk.ps1')   # Get-TcPathBelowRoot: a walk that runs from a worktree reads it

# -Root and -BaselineFile exist for the self-test, so the three live-path cases drive THIS script against a
# temp tree and a temp baseline rather than a copy of its logic. Production passes neither.
$BASELINE_FILE = if ($BaselineFile) { $BaselineFile } else { Join-Path $repo 'ops\fixed-temp-names-baseline.json' }

# THE NEEDLES ARE BUILT BY CONCATENATION, so no literal in this file spells what it hunts for.
$script:FTN_PREFILTER = '(?i)env:T' + 'E?MP\b|GetTem' + 'pPath'
$script:FTN_TEMP_VARS = @(('env:TE' + 'MP'), ('env:TM' + 'P'))
$script:FTN_UNIQUE_MEMBERS = @(('New' + 'Guid'), ('GetRandom' + 'FileName'), ('GetTemp' + 'FileName'))
$script:FTN_UNIQUE_COMMANDS = @('New-Temporary' + 'File')
# The TEXT any per-run source must contain, so a binding without it is never handed to the AST test.
$script:FTN_UNIQUE_TEXT = '(?i)New' + 'Guid|GetRandom' + 'FileName|GetTemp' + 'FileName|New-Temporary' + 'File|\$\{?(?:global:)?PID\b'
$script:FTN_READ_VERB = '^(?i)(Get|Read|Test)-'
$script:FTN_WALK_EXCLUDE = '\\work' + 'trees\\|\\archive\\|\\out\\|node_modules|\\\.git\\'
$script:FTN_SAME_PATH_CALLS = @('Trim', 'TrimEnd', 'TrimStart', 'ToString')
# Node types one walk collects, so a 6,000-line suite is visited once and not once per question.
$script:FTN_KINDS = @('AssignmentStatementAst', 'ForEachStatementAst', 'ParameterAst', 'CommandAst',
                      'InvokeMemberExpressionAst', 'ExpandableStringExpressionAst', 'BinaryExpressionAst')

function Get-FtnVarName {
  <# 'x' for $x, $script:x or [string]$x; 'env:TEMP' stays drive-qualified; '' for anything not a variable. #>
  param($Node)
  $n = $Node
  while ($null -ne $n -and $n.GetType().Name -eq 'ConvertExpressionAst') { $n = $n.Child }
  if ($null -eq $n -or $n.GetType().Name -ne 'VariableExpressionAst') { return '' }
  return ([string]$n.VariablePath.UserPath -replace '^(?i)(script|global|local|private|using):', '')
}

function Get-FtnCore {
  <# Unwrap what does not change WHICH directory a value names: a one-element pipeline, parens, casts, a
     "$(...)" or "$x" holding nothing else, and the trim calls. Stops at anything else. #>
  param($Node)
  $n = $Node
  for ($i = 0; $i -lt 64 -and $null -ne $n; $i++) {
    $t = $n.GetType().Name
    if ($t -eq 'PipelineAst' -and $n.PipelineElements.Count -eq 1) { $n = $n.PipelineElements[0] }
    elseif ($t -eq 'CommandExpressionAst') { $n = $n.Expression }
    elseif ($t -eq 'ParenExpressionAst') { $n = $n.Pipeline }
    elseif ($t -eq 'ConvertExpressionAst') { $n = $n.Child }
    elseif ($t -eq 'SubExpressionAst' -and @($n.SubExpression.Statements).Count -eq 1) { $n = $n.SubExpression.Statements[0] }
    elseif ($t -eq 'ExpandableStringExpressionAst' -and @($n.NestedExpressions).Count -eq 1 -and
            [string]::Equals([string]$n.Value, [string]$n.NestedExpressions[0].Extent.Text, [StringComparison]::Ordinal)) { $n = $n.NestedExpressions[0] }
    elseif ($t -eq 'InvokeMemberExpressionAst' -and -not $n.Static -and
            $script:FTN_SAME_PATH_CALLS -contains [string]$n.Member.Value) { $n = $n.Expression }
    else { return $n }
  }
  return $n
}

function Test-FtnTempRoot {
  <# Is this expression the shared temp directory itself? #>
  param($Node, $RootVars)
  $n = Get-FtnCore $Node
  if ($null -eq $n) { return $false }
  $t = $n.GetType().Name
  if ($t -eq 'VariableExpressionAst') {
    $v = Get-FtnVarName $n
    return ($v -ne '' -and ($script:FTN_TEMP_VARS -contains $v -or $RootVars.Contains($v)))
  }
  if ($t -eq 'InvokeMemberExpressionAst' -and $n.Static -and [string]$n.Member.Value -eq 'GetTempPath' -and
      $n.Expression.GetType().Name -eq 'TypeExpressionAst') {
    return ([string]$n.Expression.TypeName.FullName -match '^(?i)(System\.)?IO\.Path$')
  }
  return $false
}

function Test-FtnUnique {
  <# Does this subtree hold a per-run source, directly or through a variable assigned one? #>
  param($Node, $UniqueVars)
  if ($null -eq $Node) { return $false }
  $hits = $Node.FindAll({
      param($a)
      $tn = $a.GetType().Name
      if ($tn -eq 'InvokeMemberExpressionAst') { return ($a.Static -and $script:FTN_UNIQUE_MEMBERS -contains [string]$a.Member.Value) }
      if ($tn -eq 'VariableExpressionAst') { $v = Get-FtnVarName $a; return ($v -eq 'PID' -or ($v -ne '' -and $UniqueVars.Contains($v))) }
      if ($tn -eq 'CommandAst') { return ($script:FTN_UNIQUE_COMMANDS -contains [string]$a.GetCommandName()) }
      return $false
    }, $true)
  return (@($hits).Count -gt 0)
}

function Test-FtnHasText {
  <# Does this leaf SPELL a name - literal text that is not a command name, a member name or a method argument
     (.ToString('N') is a format, not a name), and is more than separators? #>
  param($Node)
  if ($null -eq $Node) { return $false }
  $hits = $Node.FindAll({
      param($a)
      $tn = $a.GetType().Name
      if ($tn -ne 'StringConstantExpressionAst' -and $tn -ne 'ExpandableStringExpressionAst') { return $false }
      $p = $a.Parent
      # The leaf ITSELF is never excluded for its parent: [IO.Path]::Combine's leaves are method arguments too.
      if ($null -ne $p -and -not [object]::ReferenceEquals($a, $Node)) {
        $pt = $p.GetType().Name
        if ($pt -eq 'CommandAst' -and [object]::ReferenceEquals($p.CommandElements[0], $a)) { return $false }
        if (($pt -eq 'MemberExpressionAst' -or $pt -eq 'InvokeMemberExpressionAst') -and [object]::ReferenceEquals($p.Member, $a)) { return $false }
        if ($pt -eq 'InvokeMemberExpressionAst') { foreach ($x in @($p.Arguments)) { if ([object]::ReferenceEquals($x, $a)) { return $false } } }
      }
      $text = [string]$a.Value
      if ($tn -eq 'ExpandableStringExpressionAst') { foreach ($ne in @($a.NestedExpressions)) { $text = $text.Replace([string]$ne.Extent.Text, '') } }
      return ($text.Trim().Trim('\', '/').Length -gt 0)
    }, $true)
  return (@($hits).Count -gt 0)
}

function Get-FtnJoinParts {
  <# The -Path and the leaf arguments of one Join-Path call, positional or named, in either order. #>
  param($Cmd)
  $els = @($Cmd.CommandElements)
  $path = $null; $leaves = New-Object System.Collections.ArrayList; $pos = New-Object System.Collections.ArrayList
  $ic = [StringComparison]::OrdinalIgnoreCase
  $k = 1
  while ($k -lt $els.Count) {
    $e = $els[$k]
    if ($e.GetType().Name -ne 'CommandParameterAst') { [void]$pos.Add($e); $k++; continue }
    $pn = [string]$e.ParameterName
    $role = ''
    if ($pn -ieq 'PSPath' -or ($pn.Length -ge 1 -and 'Path'.StartsWith($pn, $ic))) { $role = 'path' }
    elseif ($pn.Length -ge 2 -and 'ChildPath'.StartsWith($pn, $ic)) { $role = 'leaf' }
    elseif ($pn.Length -ge 1 -and 'AdditionalChildPath'.StartsWith($pn, $ic)) { $role = 'leaf' }
    elseif ($pn.Length -ge 2 -and 'Credential'.StartsWith($pn, $ic)) { $role = 'skip' }
    $k++
    if (-not $role) { continue }   # a switch: -Resolve, -UseTransaction
    $val = $e.Argument
    if ($null -eq $val -and $k -lt $els.Count) { $val = $els[$k]; $k++ }
    if ($role -eq 'path') { $path = $val } elseif ($role -eq 'leaf' -and $null -ne $val) { [void]$leaves.Add($val) }
  }
  foreach ($p in $pos) { if ($null -eq $path) { $path = $p } else { [void]$leaves.Add($p) } }
  return [pscustomobject]@{ Path = $path; Leaves = $leaves.ToArray() }
}

function Test-FtnReadProbe {
  <# Is this site passed straight in as an argument to a Get-, Read- or Test- command? #>
  param($Node)
  $p = $Node.Parent
  while ($null -ne $p -and @('PipelineAst', 'ParenExpressionAst', 'CommandExpressionAst', 'ConvertExpressionAst', 'CommandParameterAst') -contains $p.GetType().Name) { $p = $p.Parent }
  if ($null -eq $p -or $p.GetType().Name -ne 'CommandAst') { return $false }
  return ([string]$p.GetCommandName() -match $script:FTN_READ_VERB)
}

function Get-FtnMentionRx {
  <# $Base, widened to a mention of any tainted variable name: the text test that gates every AST test. #>
  param($Names, [string]$Base)
  if ($null -eq $Names -or $Names.Count -eq 0) { return $Base }
  $alt = @($Names | ForEach-Object { [regex]::Escape([string]$_) }) -join '|'
  return ($Base + '|\$\{?(?:script:|global:|local:|private:|using:)?(?:' + $alt + ')\b')
}

function Get-FtnSites {
  <# Pure over one file's text, so the self-test drives exactly what the live scan runs.
     Returns @{ Findings; Probes (each @{Line; Text}); Unique; Unresolved; ParseErrors; Read }. Read is false
     when no temp root is spelled anywhere in the file, which was then never parsed. #>
  param([string]$Text)
  $none = [pscustomobject]@{ Findings = @(); Probes = @(); Unique = 0; Unresolved = 0; ParseErrors = 0; Read = $false }
  if ($null -eq $Text -or $Text -notmatch $script:FTN_PREFILTER) { return $none }
  $tok = $null; $err = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tok, [ref]$err)
  if ($null -eq $ast) { return $none }
  $kinds = $script:FTN_KINDS
  $all = @($ast.FindAll({ param($x) $kinds -contains $x.GetType().Name }, $true))

  # Split once: bindings feed the taint, and a site candidate must be a shape that can build a path at all.
  $binds = New-Object System.Collections.ArrayList; $cands = New-Object System.Collections.ArrayList
  foreach ($a in $all) {
    $tn = $a.GetType().Name
    if ($tn -eq 'AssignmentStatementAst') { [void]$binds.Add([pscustomobject]@{ Left = $a.Left; Value = $a.Right; Text = $a.Right.Extent.Text; Name = $null }) }
    elseif ($tn -eq 'ForEachStatementAst') { [void]$binds.Add([pscustomobject]@{ Left = $a.Variable; Value = $a.Condition; Text = $a.Condition.Extent.Text; Name = $null }) }
    elseif ($tn -eq 'ParameterAst') { if ($null -ne $a.DefaultValue) { [void]$binds.Add([pscustomobject]@{ Left = $a.Name; Value = $a.DefaultValue; Text = $a.DefaultValue.Extent.Text; Name = $null }) } }
    elseif ($tn -eq 'CommandAst') { if ([string]$a.GetCommandName() -ieq 'Join-Path') { [void]$cands.Add($a) } }
    elseif ($tn -eq 'InvokeMemberExpressionAst') { if ($a.Static -and [string]$a.Member.Value -eq 'Combine') { [void]$cands.Add($a) } }
    elseif ($tn -eq 'BinaryExpressionAst') { if ($a.Operator.ToString() -eq 'Plus') { [void]$cands.Add($a) } }
    else { [void]$cands.Add($a) }
  }

  # Taint, keyed by name and file-wide: variables that ARE a temp root, then variables that hold a per-run source.
  # A binding is only examined when its TEXT mentions a source or an already-tainted name, which is a necessary
  # condition for the AST test to pass, so the text check changes the cost and never the answer.
  $rootVars = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  $uniqueVars = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  foreach ($pass in @('root', 'unique')) {
    if ($pass -eq 'unique') {
      # Only a surviving candidate needs per-run taint, and most files that spell a temp root build no path from it.
      $rootRx = Get-FtnMentionRx $rootVars $script:FTN_PREFILTER
      $cands = @(foreach ($c in $cands) { if ([string]$c.Extent.Text -match $rootRx) { $c } })
      if (-not $cands.Count) { break }
    }
    $changed = $true; $rounds = 0
    while ($changed -and $rounds -lt 16) {
      $changed = $false; $rounds++
      $rx = if ($pass -eq 'root') { Get-FtnMentionRx $rootVars $script:FTN_PREFILTER } else { Get-FtnMentionRx $uniqueVars $script:FTN_UNIQUE_TEXT }
      foreach ($b in $binds) {
        if ([string]$b.Text -notmatch $rx) { continue }
        if ($null -eq $b.Name) { $b.Name = Get-FtnVarName $b.Left }
        if (-not $b.Name) { continue }
        if ($pass -eq 'root') {
          if (-not $rootVars.Contains($b.Name) -and (Test-FtnTempRoot $b.Value $rootVars)) { [void]$rootVars.Add($b.Name); $changed = $true }
        } elseif (-not $uniqueVars.Contains($b.Name) -and (Test-FtnUnique $b.Value $uniqueVars)) { [void]$uniqueVars.Add($b.Name); $changed = $true }
      }
    }
  }
  $uniqueRx = Get-FtnMentionRx $uniqueVars $script:FTN_UNIQUE_TEXT

  $src = ($Text -replace "`r", '') -split "`n"
  $findings = New-Object System.Collections.ArrayList; $probes = New-Object System.Collections.ArrayList
  $unique = 0; $unresolved = 0
  foreach ($n in $cands) {
    $tn = $n.GetType().Name
    $leaves = $null; $textHere = $false
    if ($tn -eq 'CommandAst') {
      if ([string]$n.GetCommandName() -ine 'Join-Path') { continue }
      $jp = Get-FtnJoinParts $n
      if ($null -eq $jp.Path -or @($jp.Leaves).Count -eq 0 -or -not (Test-FtnTempRoot $jp.Path $rootVars)) { continue }
      $leaves = @($jp.Leaves)
    } elseif ($tn -eq 'InvokeMemberExpressionAst') {
      $args0 = @($n.Arguments)
      if (-not $n.Static -or [string]$n.Member.Value -ne 'Combine' -or $args0.Count -lt 2 -or
          $n.Expression.GetType().Name -ne 'TypeExpressionAst' -or [string]$n.Expression.TypeName.FullName -notmatch '^(?i)(System\.)?IO\.Path$') { continue }
      if (-not (Test-FtnTempRoot $args0[0] $rootVars)) { continue }
      $leaves = @($args0[1..($args0.Count - 1)])
    } elseif ($tn -eq 'ExpandableStringExpressionAst') {
      $nested = @($n.NestedExpressions)
      if ($nested.Count -eq 0 -or $nested[0].Extent.StartOffset -ne $n.Extent.StartOffset + 1 -or
          -not (Test-FtnTempRoot $nested[0] $rootVars)) { continue }
      $rest = ([string]$n.Value).Substring(([string]$nested[0].Extent.Text).Length)
      foreach ($ne in @($nested | Select-Object -Skip 1)) { $rest = $rest.Replace([string]$ne.Extent.Text, '') }
      $textHere = ($rest.Trim().Trim('\', '/').Length -gt 0)
      $leaves = @($nested | Select-Object -Skip 1)
      if (-not $textHere -and $leaves.Count -eq 0) { continue }   # "$env:TEMP\" names nothing
    } elseif ($tn -eq 'BinaryExpressionAst') {
      if ($n.Operator.ToString() -ne 'Plus') { continue }
      $par = $n.Parent
      if ($null -ne $par -and $par.GetType().Name -eq 'BinaryExpressionAst' -and $par.Operator.ToString() -eq 'Plus' -and
          [object]::ReferenceEquals($par.Left, $n)) { continue }   # only the outermost link of a chain is a site
      $ops = New-Object System.Collections.ArrayList
      $cur = $n
      while ($cur.GetType().Name -eq 'BinaryExpressionAst' -and $cur.Operator.ToString() -eq 'Plus') { $ops.Insert(0, $cur.Right); $cur = $cur.Left }
      $ops.Insert(0, $cur)
      if (-not (Test-FtnTempRoot $ops[0] $rootVars)) { continue }
      $leaves = @($ops[1..($ops.Count - 1)])
    } else { continue }

    $isUnique = $false
    foreach ($l in $leaves) { if ([string]$l.Extent.Text -match $uniqueRx -and (Test-FtnUnique $l $uniqueVars)) { $isUnique = $true; break } }
    if ($isUnique) { $unique++; continue }
    if (-not $textHere) { foreach ($l in $leaves) { if (Test-FtnHasText $l) { $textHere = $true; break } } }
    if (-not $textHere) { $unresolved++; continue }
    $ln = $n.Extent.StartLineNumber
    $row = [pscustomobject]@{ Line = $ln; Text = $src[$ln - 1].Trim() }
    if (Test-FtnReadProbe $n) { [void]$probes.Add($row) } else { [void]$findings.Add($row) }
  }
  return [pscustomobject]@{ Findings = $findings.ToArray(); Probes = $probes.ToArray(); Unique = $unique
                            Unresolved = $unresolved; ParseErrors = @($err).Count; Read = $true }
}

# --------------------------------------------------------------------------------------------- the walk
function Get-FtnScanFiles {
  <# Every .ps1 and .psm1 under $RootDir, excluded on the path BELOW the root (lib\tree-walk.ps1) and never $Self. #>
  param([string]$RootDir, [string]$Self = '')
  $rootFull = Get-TcRootFull $RootDir
  Get-TcTreeFiles -RootFull $rootFull -PruneBelow $script:FTN_WALK_EXCLUDE |
    Where-Object { ($_.Extension -ieq '.ps1' -or $_.Extension -ieq '.psm1') -and
                   (Get-TcPathBelowRoot $_.FullName $rootFull) -notmatch $script:FTN_WALK_EXCLUDE -and
                   -not [string]::Equals($_.FullName, $Self, [StringComparison]::OrdinalIgnoreCase) } |
    Sort-Object FullName
}

# ------------------------------------------------------------------------------------------- self-test
if ($SelfTest) {
  $script:fail = 0; $script:cases = 0
  function FtnT([string]$m, [bool]$c, [string]$got = '') {
    $script:cases++
    if ($c) { Write-Output ('  ok    ' + $m) } else { Write-Output ('  FAIL  ' + $m + '   got: ' + $got); $script:fail++ }
  }
  function FtnGot($r) {
    return ('findings=' + @($r.Findings).Count + ' lines=' + ((@($r.Findings) | ForEach-Object { $_.Line }) -join ',') +
            ' probes=' + @($r.Probes).Count + ' unique=' + $r.Unique + ' unresolved=' + $r.Unresolved)
  }
  function FtnLines($r) { return ((@($r.Findings) | ForEach-Object { $_.Line }) -join ',') }

  try {
    # ---- MUST FIRE: the founding lines, verbatim from c3a686290^ ---------------------------------------
    $fxGc = @(
      '    $probe = Join-Path $env:TEMP ''gc-clobber-probe.ps1''',
      '    $gp = Join-Path $env:TEMP ''gc-invoke-probe.ps1''',
      '    function RunProbe([string]$mode) {',
      '      $o = Join-Path $env:TEMP ("gc-probe-out-" + $mode + ".txt")',
      '    }'
    ) -join "`n"
    $r = Get-FtnSites -Text $fxGc
    FtnT 'MUST FIRE  guard-contract before c3a686290: both probes and the per-mode output file, on lines 1, 2 and 4' ((FtnLines $r) -eq '1,2,4') (FtnGot $r)
    $r = Get-FtnSites -Text '$script:JournalDir = Join-Path $env:TEMP ''tg-restore-journal'''
    FtnT 'MUST FIRE  test-guards'' shared journal directory' (@($r.Findings).Count -eq 1) (FtnGot $r)

    # ---- MUST FIRE: shapes still standing in the tree on 2026-09-11, verbatim --------------------------
    $r = Get-FtnSites -Text '  $probe = Join-Path $env:TEMP ''ff-clobber-probe.ps1'''
    FtnT 'MUST FIRE  feed-freshness'' clobber probe, the guard-contract shape copied into another suite' (@($r.Findings).Count -eq 1) (FtnGot $r)
    $r = Get-FtnSites -Text '  $log = Join-Path $env:TEMP ("tc-oracle-$label.log")'
    FtnT 'MUST FIRE  an expandable leaf whose only variable is not per run (consistency-oracle)' (@($r.Findings).Count -eq 1) (FtnGot $r)
    $fxAldi = @(
      '$regDate = [regex]::Match((Split-Path $regPath -Leaf), ''(\d{4}-\d{2}-\d{2})'').Groups[1].Value',
      '$reportPath = if ($opt.Report) { $opt.Report } elseif ($doApply) { Join-Path $here (''out\audit\aldi-link-backfill-'' + $regDate + ''.jsonl'') } else { Join-Path ([IO.Path]::GetTempPath()) (''aldi-link-backfill-'' + $regDate + ''-dryrun.jsonl'') }'
    ) -join "`n"
    $r = Get-FtnSites -Text $fxAldi
    FtnT 'MUST FIRE  a GetTempPath root with a date leaf, and not the repo-rooted twin on the same line (backfill-aldi-link-urls)' (@($r.Findings).Count -eq 1 -and $r.Findings[0].Line -eq 2) (FtnGot $r)

    # ---- MUST FIRE: the other spellings the header claims ----------------------------------------------
    $r = Get-FtnSites -Text 'Join-Path -Path $env:TMP -ChildPath ''tc-x.json'''
    FtnT 'MUST FIRE  named -Path and -ChildPath, under $env:TMP' (@($r.Findings).Count -eq 1) (FtnGot $r)
    $r = Get-FtnSites -Text '$p = Join-Path -ChildPath ''tc-x'' -Path ([System.IO.Path]::GetTempPath())'
    FtnT 'MUST FIRE  -ChildPath before -Path, under [System.IO.Path]::GetTempPath()' (@($r.Findings).Count -eq 1) (FtnGot $r)
    $r = Get-FtnSites -Text ('$t = [IO.Path]::GetTempPath().TrimEnd(''\'')' + "`n" + '$d = Join-Path $t ''tc-x''')
    FtnT 'MUST FIRE  a variable that holds the temp root, on line 2' (@($r.Findings).Count -eq 1 -and $r.Findings[0].Line -eq 2) (FtnGot $r)
    # Added after a mutation probe: with the taint's text gate never widened past the needle, every other case stayed green.
    $r = Get-FtnSites -Text ('$base = $env:TEMP' + "`n" + '$t = $base' + "`n" + '$d = Join-Path $t ''tc-x''')
    FtnT 'MUST FIRE  a temp root reached through TWO variables, on line 3' (@($r.Findings).Count -eq 1 -and $r.Findings[0].Line -eq 3) (FtnGot $r)
    $r = Get-FtnSites -Text ('function New-Thing { param([string]$Tmp = $env:TEMP)' + "`n" + '  Join-Path $Tmp ''tc-x'' }')
    FtnT 'MUST FIRE  a parameter defaulting to the temp root' (@($r.Findings).Count -eq 1) (FtnGot $r)
    $r = Get-FtnSites -Text '$p = [IO.Path]::Combine($env:TEMP, ''tc-x'', ''y.txt'')'
    FtnT 'MUST FIRE  [IO.Path]::Combine' (@($r.Findings).Count -eq 1) (FtnGot $r)
    $r = Get-FtnSites -Text '$p = "$env:TEMP\tc-x.log"'
    FtnT 'MUST FIRE  an expandable string that opens with the root' (@($r.Findings).Count -eq 1) (FtnGot $r)
    $r = Get-FtnSites -Text '$p = $env:TEMP + ''\'' + ''tc-x'' + ''.log'''
    FtnT 'MUST FIRE  a + chain from the root, counted ONCE however long' (@($r.Findings).Count -eq 1) (FtnGot $r)
    $r = Get-FtnSites -Text '$p = Join-Path $env:TEMP (''tc-x-'' + (Get-Date -Format ''yyyyMMddHHmmss''))'
    FtnT 'MUST FIRE  a clock is not a per-run name' (@($r.Findings).Count -eq 1) (FtnGot $r)
    $r = Get-FtnSites -Text 'Join-Path $env:TEMP tc-bare'
    FtnT 'MUST FIRE  a bareword leaf is literal text' (@($r.Findings).Count -eq 1) (FtnGot $r)
    $r = Get-FtnSites -Text '''x'' | Set-Content (Join-Path $env:TEMP ''no-such-file.json'')'
    FtnT 'MUST FIRE  the probe word does not exempt a WRITE: the same leaf piped to Set-Content' (@($r.Findings).Count -eq 1 -and @($r.Probes).Count -eq 0) (FtnGot $r)
    $r = Get-FtnSites -Text '$miss = Join-Path $env:TEMP ''no-such-file.json''; $x = Read-Store $miss'
    FtnT 'MUST FIRE  ...nor the same leaf ASSIGNED, which the detector cannot follow to a read' (@($r.Findings).Count -eq 1 -and @($r.Probes).Count -eq 0) (FtnGot $r)

    # ---- MUST NOT FIRE: the per-run forms, verbatim from the tree today --------------------------------
    $fxScratch = @(
      '  $gcRoot = Join-Path $env:TEMP (''gc-selftest-'' + [guid]::NewGuid().ToString(''N'').Substring(0, 8))',
      '  New-Item -ItemType Directory -Path $gcRoot -ErrorAction Stop | Out-Null',
      '  $gcMade = New-Object System.Collections.Generic.List[string]',
      '  function GcScratch([string]$leaf) { $p = Join-Path $gcRoot $leaf; [void]$gcMade.Add($p); return $p }',
      '    $probe = GcScratch ''gc-clobber-probe.ps1'''
    ) -join "`n"
    $r = Get-FtnSites -Text $fxScratch
    FtnT 'MUST NOT FIRE  GcScratch, the exemplar: a guid root and leaves below it (guard-contract today)' (@($r.Findings).Count -eq 0 -and $r.Read) (FtnGot $r)
    FtnT 'CLEAN TWIN  ...and its guid root is still classed UNIQUE, so the fixture was judged and not skipped' ($r.Unique -eq 1) (FtnGot $r)
    $fxPushData = @(
      '  $id   = [guid]::NewGuid().ToString(''N'').Substring(0, 8)',
      '  $bare = Join-Path $env:TEMP ("pd-remote-$id")',
      '  $work = Join-Path $env:TEMP ("pd-work-$id")'
    ) -join "`n"
    $r = Get-FtnSites -Text $fxPushData
    FtnT 'MUST NOT FIRE  an expandable leaf whose variable holds a guid (test-push-data today)' (@($r.Findings).Count -eq 0 -and $r.Unique -eq 2) (FtnGot $r)
    $r = Get-FtnSites -Text '  $tmp = Join-Path $env:TEMP ("event-bus-selftest-{0}.jsonl" -f $PID)'
    FtnT 'MUST NOT FIRE  a -f leaf carrying $PID (audit-event-bus today)' (@($r.Findings).Count -eq 0 -and $r.Unique -eq 1) (FtnGot $r)
    $r = Get-FtnSites -Text '$p = Join-Path $env:TEMP (''tc-'' + (New-TemporaryFile).BaseName)'
    FtnT 'MUST NOT FIRE  a leaf built from New-TemporaryFile' (@($r.Findings).Count -eq 0 -and $r.Unique -eq 1) (FtnGot $r)
    $r = Get-FtnSites -Text '$p = "$env:TEMP\tc-$([guid]::NewGuid().ToString(''N''))"'
    FtnT 'MUST NOT FIRE  an expandable string from the root with a guid in it' (@($r.Findings).Count -eq 0 -and $r.Unique -eq 1) (FtnGot $r)

    # ---- MUST NOT FIRE: the absence probes, verbatim, which are LISTED instead -------------------------
    $fxProbes = @(
      '    $e4 = Get-AllowedRemote -Url ''https://github.com/Schweino/codex-memory.git'' -AllowFile (Join-Path $env:TEMP ''no-such-allowlist-file.json'')',
      '  $hs2 = Get-NightlyHardStop -Path (Join-Path $env:TEMP ''no-such-status-file.json'') -Fallback ''05:15''',
      '    T ''a missing lane log reads as empty, not as an error'' ((@(Read-LaneLog (Join-Path $env:TEMP ''no-such-lane-log.jsonl''))).Count -eq 0) ''threw'''
    ) -join "`n"
    $r = Get-FtnSites -Text $fxProbes
    FtnT 'MUST NOT FIRE  absence probes passed straight to Get-/Read- commands are not counted (audit-memory-backup, sidecar-watchdog, hunt-run)' (@($r.Findings).Count -eq 0) (FtnGot $r)
    FtnT 'CLEAN TWIN  ...and all three are still LISTED as probes, on lines 1, 2 and 3' (((@($r.Probes) | ForEach-Object { $_.Line }) -join ',') -eq '1,2,3') (FtnGot $r)

    # ---- MUST NOT FIRE: things that name no fixed leaf --------------------------------------------------
    $fxProse = @(
      '# was: $probe = Join-Path $env:TEMP ''gc-clobber-probe.ps1''',
      'Write-Output ''$probe = Join-Path $env:TEMP ''''gc-clobber-probe.ps1'''''''
    ) -join "`n"
    $r = Get-FtnSites -Text $fxProse
    FtnT 'MUST NOT FIRE  the founding line quoted in a comment and in a string' (@($r.Findings).Count -eq 0 -and $r.Read) (FtnGot $r)
    $r = Get-FtnSites -Text '  function Tmp([string]$leaf) { return (Join-Path $env:TEMP $leaf) }'
    FtnT 'MUST NOT FIRE  a leaf that is only a variable is UNRESOLVED, and counted as such' (@($r.Findings).Count -eq 0 -and $r.Unresolved -eq 1) (FtnGot $r)
    $fxRootAlone = @(
      '    $r = Test-Plan $doc @(''q1'') $env:TEMP',
      '$underTemp = $PSScriptRoot.TrimEnd(''\'').ToLower().StartsWith(([IO.Path]::GetTempPath()).TrimEnd(''\'').ToLower())',
      '  $env:TMPDIR = $sb.Replace(''\'', ''/'')',
      '$x = "$env:TEMP"; $y = "$env:TEMP\"'
    ) -join "`n"
    $r = Get-FtnSites -Text $fxRootAlone
    FtnT 'MUST NOT FIRE  a temp root passed or compared ALONE builds no name (validate-triage-plan, test-guards, test-prepush-hook)' (@($r.Findings).Count -eq 0 -and @($r.Probes).Count -eq 0 -and $r.Read) (FtnGot $r)

    # ---- CLEAN TWIN: the adjacent behaviour the exemptions were most likely to break ---------------------
    $fxMixed = @(
      '$a = Join-Path $env:TEMP (''tc-a-'' + [guid]::NewGuid().ToString(''N''))',
      '$b = Join-Path $env:TEMP ''tc-b''',
      '$c = Read-Store (Join-Path $env:TEMP ''nope.json'')'
    ) -join "`n"
    $r = Get-FtnSites -Text $fxMixed
    FtnT 'CLEAN TWIN  a unique site and a probe beside a fixed one: the fixed one is still reported, on line 2' (@($r.Findings).Count -eq 1 -and $r.Findings[0].Line -eq 2 -and @($r.Probes).Count -eq 1 -and $r.Unique -eq 1) (FtnGot $r)

    # ---- THE WALK, FROM A WORKTREE ROOT (lib\tree-walk.ps1) -----------------------------------------------
    $wtFx = New-TcWorktreeFixture -Files @{ 'ops\a.ps1' = 'Write-Output 1'; 'lib\b.psm1' = 'Write-Output 2'
                                            'grocery\out\scratch.ps1' = 'Write-Output 3'; 'ops\me.ps1' = 'Write-Output 4'
                                            'sidecar\c.py' = 'print(1)' }
    try {
      $self = Join-Path $wtFx.Root 'ops\me.ps1'
      $wtFound = @(Get-FtnScanFiles -RootDir $wtFx.Root -Self $self)
      $wtHits = Measure-TcWorktreeFixture -Fixture $wtFx -Found $wtFound
      FtnT 'MUST FIRE  a root that IS a worktree is scanned, not excluded whole (.ps1 and .psm1, no \out\, no .py, not itself)' ($wtHits.Root -eq 2) ('root=' + $wtHits.Root)
      FtnT 'MUST NOT FIRE  a sibling worktree BELOW that root is still excluded' ($wtHits.Sibling -eq 0) ('sibling=' + $wtHits.Sibling)
      FtnT 'MUST NOT FIRE  the detector never scans itself' (@($wtFound | Where-Object { $_.FullName -eq $self }).Count -eq 0) ''
    } finally { Remove-Item -LiteralPath $wtFx.Temp -Recurse -Force -ErrorAction SilentlyContinue }

    # ---- THE LIVE PATH, DRIVEN (2026-09-12) ---------------------------------------------------------------
    # The founding shape is a pre-push run-gates pass whose count FELL: it rewrote the TRACKED baseline, left the
    # pushing checkout ` M`, and cost that pass its reuse record. These three run THIS script as a child against a
    # one-file temp tree and a temp baseline, so they exercise the code a gate runs rather than a copy of it.
    # ONE DIRECTORY PER RUN, removed in finally - this suite's own rule, and concurrent pushes share %TEMP%.
    $ftnWt = Join-Path $env:TEMP ('ftn-live-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $ftnWt -ErrorAction Stop | Out-Null
    try {
      $fxTree = Join-Path $ftnWt 'tree'
      New-Item -ItemType Directory -Path $fxTree -ErrorAction Stop | Out-Null
      # EXACTLY ONE fixed site, so the counts below are the fixture's and not the tree's.
      $fxSrc = '$b = Join-Path $env:TEMP ''tc-live-fixture'''
      [IO.File]::WriteAllText((Join-Path $fxTree 'suite.ps1'), $fxSrc, (New-Object Text.UTF8Encoding($false)))
      $fxNote = 'fixture note (keep me)'
      $blFx = Join-Path $ftnWt 'baseline.json'
      $seed = [pscustomobject]@{ generated = '2026-01-01T00:00:00'; sites = 2
                                 history = @([pscustomobject]@{ date = '2026-01-01T00:00:00'; count = 2 }); note = $fxNote }
      $null = Write-TcLfFile -Path $blFx -Text ($seed | ConvertTo-Json -Depth 5) -NoBom
      $seedB64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($blFx))

      $o1 = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $fxTree -BaselineFile $blFx)
      $rc1 = $LASTEXITCODE
      $same1 = [string]::Equals($seedB64, [Convert]::ToBase64String([IO.File]::ReadAllBytes($blFx)), [StringComparison]::Ordinal)
      FtnT 'MUST FIRE  a FALL (1 site, baseline 2) with no -Tighten is SPOKEN and the baseline left byte-identical, so a gate run leaves its checkout clean' `
        ($rc1 -eq 0 -and $same1 -and (($o1 -join "`n") -match 'CAN tighten')) ("rc=$rc1 baselineUnchanged=$same1 said=" + (($o1 | Where-Object { $_ -match 'CAN tighten|TIGHTENED' }) -join ' | '))

      $null = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $fxTree -BaselineFile $blFx -Tighten)
      $rc2 = $LASTEXITCODE
      $b2 = [IO.File]::ReadAllBytes($blFx)
      $cr2 = 0; foreach ($x in $b2) { if ($x -eq 13) { $cr2++ } }
      $bom2 = ($b2.Length -ge 3 -and $b2[0] -eq 0xEF -and $b2[1] -eq 0xBB -and $b2[2] -eq 0xBF)
      $doc2 = $null
      try { $doc2 = [Text.Encoding]::UTF8.GetString($b2) | ConvertFrom-Json } catch { }
      FtnT '-Tighten records the fall in the bytes git stores: no CR, no BOM (the committed blob has none), one trailing LF, sites lowered, and the note kept' `
        ($rc2 -eq 0 -and $cr2 -eq 0 -and (-not $bom2) -and $b2[-1] -eq 10 -and $null -ne $doc2 -and
         [int]$doc2.sites -eq 1 -and [string]$doc2.note -eq $fxNote -and @($doc2.history).Count -eq 2) `
        ("rc=$rc2 cr=$cr2 bom=$bom2 sites=$(if ($doc2) { $doc2.sites }) note=$(if ($doc2) { $doc2.note })")

      # CLEAN TWIN: not writing on a fall must not have disarmed the ratchet in the direction that matters.
      $blRise = Join-Path $ftnWt 'baseline-rise.json'
      $riseSeed = [pscustomobject]@{ generated = '2026-01-01T00:00:00'; sites = 0; history = @(); note = $fxNote }
      $null = Write-TcLfFile -Path $blRise -Text ($riseSeed | ConvertTo-Json -Depth 5) -NoBom
      $riseB64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($blRise))
      $null = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $fxTree -BaselineFile $blRise)
      $rc3 = $LASTEXITCODE
      $same3 = [string]::Equals($riseB64, [Convert]::ToBase64String([IO.File]::ReadAllBytes($blRise)), [StringComparison]::Ordinal)
      FtnT 'CLEAN TWIN  a count that ROSE still exits 2 and writes nothing, so not recording a fall did not disarm the ratchet' `
        ($rc3 -eq 2 -and $same3) ("rc=$rc3 baselineUnchanged=$same3")
    } finally { Remove-Item -LiteralPath $ftnWt -Recurse -Force -ErrorAction SilentlyContinue }
  } catch {
    # A case that THROWS is a counted failure, never a suite that stopped early and printed a pass.
    $script:cases++; $script:fail++
    Write-Output ('  FAIL  the suite threw: ' + $_.Exception.Message + ' at line ' + $_.InvocationInfo.ScriptLineNumber)
  }

  if ($script:fail) { Write-Output ("FIXED-TEMP-NAMES SELF-TEST FAILED ({0} of {1} case(s))" -f $script:fail, $script:cases); exit 2 }
  Write-Output ("FIXED-TEMP-NAMES SELF-TEST PASSED ({0} case(s): the founding lines and every claimed spelling fire, the per-run forms stay silent, absence probes are listed and not counted, and the walk reads a worktree root)" -f $script:cases)
  exit 0
}

# ------------------------------------------------------------------------------------------- live run
# NEVER SCAN YOURSELF. The self-test above carries the founding lines as fixtures; they are strings, so the
# AST would not count them, but a detector that relies on that is one refactor from reporting itself.
if (-not $Root) { $Root = $repo }
$files = @(Get-FtnScanFiles -RootDir $Root -Self $PSCommandPath)
if (-not $files.Count) {
  Write-Output 'FIXED-TEMP-NAMES AUDIT BLIND: resolved zero .ps1 files, which means the discovery is broken rather than the tree being clean.'
  Exit-Guard -Name 'fixed-temp-names' -Summary 'blind=no-files' -Code 3
}
$rootFull = Get-TcRootFull $Root
$sites = New-Object System.Collections.ArrayList; $probeSites = New-Object System.Collections.ArrayList
$read = 0; $parseErrorFiles = 0; $uniqueAll = 0; $unresolvedAll = 0
foreach ($f in $files) {
  $r = Get-FtnSites -Text ([IO.File]::ReadAllText($f.FullName))
  if (-not $r.Read) { continue }
  $read++
  if ($r.ParseErrors) { $parseErrorFiles++ }
  $uniqueAll += $r.Unique; $unresolvedAll += $r.Unresolved
  $rel = (Get-TcPathBelowRoot $f.FullName $rootFull).TrimStart('\')
  foreach ($h in $r.Findings) { [void]$sites.Add(("{0}:{1}  {2}" -f $rel, $h.Line, $h.Text)) }
  foreach ($h in $r.Probes) { [void]$probeSites.Add(("{0}:{1}  {2}" -f $rel, $h.Line, $h.Text)) }
}
if (-not $read) {
  Write-Output ("FIXED-TEMP-NAMES AUDIT BLIND: resolved {0} file(s) and not one spells a temp root, which means the prefilter is broken rather than the tree being clean." -f $files.Count)
  Exit-Guard -Name 'fixed-temp-names' -Summary ("blind=no-temp-root files={0}" -f $files.Count) -Code 3
}
$count = $sites.Count
$built = $count + $probeSites.Count + $uniqueAll + $unresolvedAll
Write-Output ("fixed-temp-names: resolved {0} file(s); {1} spell a temp root and were parsed, {2} of those with a parse error; {3} path(s) built under a temp root: {4} unique per run, {5} FIXED (counted), {6} absence probe(s) (listed, not counted), {7} unresolved" -f $files.Count, $read, $parseErrorFiles, $built, $uniqueAll, $count, $probeSites.Count, $unresolvedAll)
foreach ($s in $sites) { Write-Output ('  fixed-temp     ' + $s) }
foreach ($s in $probeSites) { Write-Output ('  absence-probe  ' + $s) }
$summary = "files={0} read={1} built={2} fixed={3} probes={4} unresolved={5}" -f $files.Count, $read, $built, $count, $probeSites.Count, $unresolvedAll

$note = 'HIGH-WATER MARK for paths built under %TEMP% from a FIXED leaf, which concurrent runs of one suite share. Absence probes passed straight to a Get-/Read-/Test- command are listed, not counted. It may only go DOWN, and a fall to zero or over 60% in one run is REFUSED as a probably-broken detector (lib\ratchet.ps1).'
$blDoc = $null
if (Test-Path -LiteralPath $BASELINE_FILE) {
  try { $blDoc = Get-Content -LiteralPath $BASELINE_FILE -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $blDoc = $null }
}
function Write-FtnBaseline([int]$Sites) {
  <# The recorded mark, in the bytes git stores. The committed blob carries NO BOM, so -NoBom: matching it is
     what keeps a record to an unchanged count from showing up as a whole-file rewrite. The NOTE the file
     already carries is KEPT rather than replaced, and the key order is the committed one, so the diff of a
     record is only what moved. #>
  $keepNote = if ($blDoc -and $blDoc.note) { [string]$blDoc.note } else { $note }
  $srcDoc = if ($blDoc) { $blDoc } else { [pscustomobject]@{} }
  $hist = Add-RatchetHistory -Doc $srcDoc -Count $Sites
  $doc = [pscustomobject]@{ generated = (Get-Date).ToString('s'); sites = $Sites; history = $hist; note = $keepNote }
  $null = Write-TcLfFile -Path $BASELINE_FILE -Text ($doc | ConvertTo-Json -Depth 5) -NoBom
  return $hist
}
if (-not $blDoc) {
  # SEEDING IS NOT RECORDING A FALL. With no baseline there is nothing to protect and nothing to compare
  # against, so the first run writes one - which in production cannot happen, the file being tracked.
  # The day-one count goes into the history as well, so every later fall is read against what was first measured.
  $null = Write-FtnBaseline $count
  Write-Output ("fixed-temp-names: baseline written at {0} site(s). From here the number may only go DOWN." -f $count)
  Exit-Guard -Name 'fixed-temp-names' -Summary ("{0} baseline={1}" -f $summary, $count) -Code 0
}
$base = [int]$blDoc.sites

if ($count -gt $base) {
  Write-Output ("FIXED-TEMP-NAMES AUDIT FAILED: {0} path(s) are built under %TEMP% from a FIXED leaf, against a baseline of {1}." -f $count, $base)
  Write-Output '  run-gates runs every -SelfTest and pre-push runs run-gates, so concurrent pushes run the same suite over each'
  Write-Output '  other in ONE %TEMP%, and a fixed name there is shared: one run reads, replays or deletes another''s file.'
  Write-Output '  Allocate one directory per run - Join-Path $env:TEMP (''tag-'' + [guid]::NewGuid().ToString(''N'').Substring(0, 8))'
  Write-Output '  - hand out every path under it through one recording function, and remove it in finally. GcScratch in'
  Write-Output '  lib\guard-contract.ps1 is the exemplar. A name deliberately shared ACROSS runs stays on the production path'
  Write-Output '  and is redirected inside the self-test.'
  Exit-Guard -Name 'fixed-temp-names' -Summary ("{0} baseline={1} ROSE" -f $summary, $base) -Code 2
}
$move = Test-RatchetMove -Name 'fixed-temp-names' -Count $count -Baseline $base -AcceptDrop:$AcceptDrop
if ($move.Verdict -eq 'implausible') {
  Write-Output $move.Message
  Exit-Guard -Name 'fixed-temp-names' -Summary ("{0} baseline={1} refused-to-lower" -f $summary, $base) -Code 2
}
if ($move.Verdict -eq 'tightened') {
  if ($Tighten -or $AcceptDrop) {
    $hist = Write-FtnBaseline ([int]$move.NewBaseline)
    Write-Output ('PASSED and TIGHTENED - ' + $move.Message)
    Write-Output ('  ' + (Get-RatchetTrend -History $hist))
    Write-Output '  New baseline written - commit ops\fixed-temp-names-baseline.json, or it protects only this checkout.'
    Exit-Guard -Name 'fixed-temp-names' -Summary ("{0} tightened-from={1}" -f $summary, $base) -Code 0
  }
  # SPOKEN, NOT WRITTEN. This may be a pre-push run-gates pass, and a rewrite here dirties the checkout being
  # pushed without riding the push - and it costs that pass its reuse record as well.
  # ASSIGNED FIRST, not concatenated inside the -replace: `'a' + $m -replace x, y` binds as `('a' + $m) -replace
  # x, y` here, which happens to be what was meant and is one precedence change from not being.
  $spoken = [string]$move.Message -replace 'Baseline lowered; it can never rise again\.', 'NOT written.'
  Write-Output ("fixed-temp-names: PASSED, and the ratchet CAN tighten - " + $spoken)
  Write-Output '  Record it deliberately: ops\audit-fixed-temp-names.ps1 -Tighten, then commit ops\fixed-temp-names-baseline.json.'
  Exit-Guard -Name 'fixed-temp-names' -Summary ("{0} baseline={1} can-tighten={2}" -f $summary, $base, $count) -Code 0
}
Write-Output ("fixed-temp-names: PASSED - {0} known site(s), unchanged from the baseline. Each one moved under a per-run directory lowers the mark for good." -f $count)
Exit-Guard -Name 'fixed-temp-names' -Summary ("{0} baseline={1}" -f $summary, $base) -Code 0
