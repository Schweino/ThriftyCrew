<#
  audit-list-array-wrap.ps1 - @() around a New-Object List[object] THROWS under PS 5.1.

  SCOPE OF A CLEAN REPORT: UNSOUND. It reads the PowerShell AST of every tracked .ps1 and .psm1 and reports
    `@($v)` where the binding of $v it can see is a LITERAL `New-Object ...List[object]`. It sees literal
    assignments only: a list that arrives as a parameter, out of a hashtable or a property, through a second
    variable (`$b = $a`), from a function's return value, or built from a type name held in a variable is
    invisible to it, and so is `@($h.rows)`. A reported site is real; silence is not proof.

  WHAT ACTUALLY THROWS, measured on PS 5.1.26100.9444 on 2026-09-17, one case per line. The brief for this
  gate described the trap as a CONCAT trap, `@($list) + @(...)`, and three of these say it is not:

      $l = New-Object System.Collections.Generic.List[object]
      @($l)                      THROWS "Argument types do not match"   <- the wrap alone, no + anywhere
      @($l).Count                THROWS                                  even when the list is EMPTY
      foreach ($x in @($l)) { }  THROWS
      [ordered]@{ p = @($l) }    THROWS      the error points at the hashtable, never at the wrap
      @($arr) + @($l)            THROWS      either side of a +, because the wrap is what throws
      $l + @($arr)               fine        the BARE variable concatenates, count 3
      $l + $l                    fine
      @($l.ToArray()) + @($arr)  fine        the repair, and what build-sams-deals.ps1 carries now
      @($l | Where-Object {...}) fine        a pipeline inside the wrap
      [System.Collections.Generic.List[object]]::new() ... @($that)      fine
      $l.psobject.BaseObject ... @($that)    fine
      New-Object ArrayList ... @($that)      fine
      List[string], List[int], List[hashtable], List[psobject], List[pscustomobject]   all fine

  So the trigger is the WRAP, the creation form and the element type - never the operator. New-Object returns
  its instance wrapped in a PSObject and `@()` cannot convert that wrapper when the element type is object;
  ::new() returns the bare instance, which is why the identical type built that way is safe. That is also why
  this file is named for the wrap rather than for the concat: a gate called `list-array-concat` would have to
  stay silent on `foreach ($x in @($l))`, which is the same bug with no + in it.

  WHY THIS EXISTS. Commit 9c44c3a37 (2026-09-12) gave grocery\build-sams-deals.ps1 a rejects LIST and wrote
      $rjRows = @($rejects) + @($hintNotes)
  Every Sam's build that produced a reject then died there, AFTER the deals file was written and BEFORE the
  rejects file, the summary and the cursor advance - so a build with a bad row looked like a build that had
  not finished, for five days, until b7060307b. grocery\build-arrivals-docket.ps1:446 carries a HAND fix of
  the same trap with a comment explaining it, and memory ps-list-object-array-wrap-throws.md recorded it on
  2026-08-31 from a third site in build-deals-page.ps1. Three sites, one memory, and it recurred anyway: a
  rule that recurs despite a memory needs a gate. The self-test runs the hazard in a child on every run, so
  the day this PowerShell stops throwing, the gate says so instead of guarding a rule that has expired.

  THE RULE. Report an ArrayExpressionAst whose sub-expression is exactly one variable, `@($v)`, when the
  binding of $v that this file can see is `New-Object` with a type name matching
  [System.]Collections.Generic.List[[System.]object], compared case-insensitively, given as a bare or
  single-quoted word positionally or after -TypeName. The binding is the last assignment to that name,
  by source offset, in the innermost scope that binds it at all - a function body, or the file. A
  `$script:`/`$global:` use resolves against the script-scoped and top-level assignments in the file. A
  parameter, a foreach loop variable, a `[type]$v =` conversion and any other right-hand side all BIND the
  name and are not lists, so a variable reassigned before the wrap is not reported.

  THE DELIBERATE EXCEPTION. A wrap whose own line carries `# list-array-wrap:allow <reason>` is not reported,
  the way ops\audit-bare-replace.ps1 marks a deliberate bare replace. There is exactly one legitimate reason
  and both of today's sites give it: a fixture that EXECUTES the wrap against a live List[object] to prove PS
  5.1 still throws, rather than pattern-matching the spelling (grocery\test-auditors.ps1 u056-k1a,
  meal-prep\pipeline\wave-preaudit.ps1's frozen trap pair). A marker with no reason after it is not a marker.

  A GATE AT ZERO, NOT A RATCHET. MEASURED 2026-09-17 through this file from a linked worktree: git listed 785
  tracked .ps1/.psm1, the walk resolved 785, no parse errors, 30s, and SIX sites - two of them the fixtures
  above and four of them live latent crashes, each on an error path that had never been taken:
  build-sams-deals.ps1:608 (a self-test's FAIL report, which would have died naming no case),
  rebid-ingredient.ps1:401 (the CANNOT IDENTIFY refusal), wave-preaudit.ps1:1216 (the unparseable-spec
  branch, twelve lines under a comment block explaining this very trap) and grocery\out\audit\
  inject-ff-victims.ps1:26. All four were repaired in the commit that added this gate, so the day-one count
  is zero and any site is new. There is nothing to ratchet down to.

  DISCOVERY. Every .ps1 and .psm1 under the root, excluded on the path BELOW the root (lib\tree-walk.ps1),
  never this file, and only the paths `git ls-files` lists, so untracked scratch in one checkout cannot make
  a push red there alone.

  EXIT CODES (lib\guard-contract.ps1 vocabulary): 0 no site, 1 at least one site, 3 could not evaluate (git
  listed nothing, or the walk resolved nothing). Read the verdict LINE, not the number.

    ops\audit-list-array-wrap.ps1             scan the tracked tree
    ops\audit-list-array-wrap.ps1 -SelfTest   the founding line, the legal forms, the hazard, the walk
#>
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop (2026-09-07)
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\tree-walk.ps1')   # Get-TcRootFull, Get-TcPathBelowRoot, New-TcWorktreeFixture

$script:LAW_WALK_EXCLUDE = '\\work' + 'trees\\|\\\.git\\|node_modules'
# The element type is half the rule: List[string] and List[psobject] wrap without complaint, List[object] does not.
$script:LAW_TYPE_RE = '(?i)^\s*(system\.)?collections\.generic\.list\[\s*(system\.)?object\s*\]\s*$'
# The deliberate exception, on the wrap's own line, with a reason after it (ops\audit-bare-replace.ps1's shape).
$script:LAW_ALLOW_RE = '(?i)#[^\n]*list-array-wrap:allow\s+\S'

function Test-LawNewObjectList {
  <# Pure. Is this CommandAst a New-Object of List[object]? The type name is New-Object's first positional
     argument or the value of -TypeName (any unambiguous prefix of it). An expandable string is NOT read:
     "List[$t]" names a type only at run time, which is the unsoundness the header declares. #>
  param($Cmd)
  if (-not ($Cmd -is [System.Management.Automation.Language.CommandAst])) { return $false }
  if ([string]$Cmd.GetCommandName() -notmatch '(?i)^new-object$') { return $false }
  $els = $Cmd.CommandElements
  $type = $null
  for ($i = 1; $i -lt $els.Count; $i++) {
    $e = $els[$i]
    if ($e -is [System.Management.Automation.Language.CommandParameterAst]) {
      $pn = ([string]$e.ParameterName).ToLowerInvariant()
      if ($pn.Length -gt 0 -and 'typename'.StartsWith($pn)) {
        if ($null -ne $e.Argument) { $type = $e.Argument }
        elseif ($i + 1 -lt $els.Count) { $type = $els[$i + 1] }
        break
      }
      if ($null -eq $e.Argument) { $i++ }   # -ArgumentList 4: the next element is this parameter's value
      continue
    }
    $type = $e
    break
  }
  if ($null -eq $type) { return $false }
  if (-not ($type -is [System.Management.Automation.Language.StringConstantExpressionAst])) { return $false }
  return ([string]$type.Value -match $script:LAW_TYPE_RE)
}

function Test-LawListRhs {
  <# Pure. Does this right-hand side evaluate to a New-Object List[object]? Parens and a one-element pipeline
     are transparent; anything else - ::new(), a cast, a second variable, a call - is not this shape. #>
  param($Node)
  $n = $Node
  for ($hop = 0; $hop -lt 8 -and $null -ne $n; $hop++) {
    if ($n -is [System.Management.Automation.Language.PipelineAst]) {
      if ($n.PipelineElements.Count -ne 1) { return $false }
      $n = $n.PipelineElements[0]; continue
    }
    if ($n -is [System.Management.Automation.Language.CommandExpressionAst]) { $n = $n.Expression; continue }
    if ($n -is [System.Management.Automation.Language.ParenExpressionAst]) { $n = $n.Pipeline; continue }
    if ($n -is [System.Management.Automation.Language.CommandAst]) { return (Test-LawNewObjectList $n) }
    return $false
  }
  return $false
}

function Get-LawScope {
  <# Pure. The FunctionDefinitionAst a node sits in, or $null for the file scope. A scriptblock that is not a
     function body is transparent: ForEach-Object and Where-Object blocks read the caller's variables. #>
  param($Node)
  $p = $Node.Parent
  while ($null -ne $p) {
    if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) { return $p }
    $p = $p.Parent
  }
  return $null
}

function Get-LawVarName {
  <# Pure. A variable's name without its scope qualifier, lower-cased. VariablePath.UnqualifiedPath says this
     and is INTERNAL under PS 5.1, where it reads as $null (ops\audit-internal-ast-members.ps1). #>
  param($Node)
  return (([string]$Node.VariablePath.UserPath) -replace '(?i)^(global|local|script|private):', '').ToLowerInvariant()
}

function Test-LawScriptQualified {
  param($Node)
  return (([string]$Node.VariablePath.UserPath) -match '(?i)^(global|script):')
}

function Get-LawBinders {
  <# Pure. Every place a name is BOUND in this file: assignments, parameters and foreach loop variables.
     Everything that is not a New-Object List[object] assignment still binds, which is what stops a
     reassigned or re-parameterised name being reported. #>
  param($Ast)
  $out = New-Object System.Collections.ArrayList
  $assigns = $Ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)
  foreach ($a in $assigns) {
    $left = $a.Left
    $converted = $false
    if ($left -is [System.Management.Automation.Language.ConvertExpressionAst]) { $left = $left.Child; $converted = $true }
    if (-not ($left -is [System.Management.Automation.Language.VariableExpressionAst])) { continue }
    $isList = (-not $converted) -and
              ($a.Operator -eq [System.Management.Automation.Language.TokenKind]::Equals) -and
              (Test-LawListRhs $a.Right)
    [void]$out.Add([pscustomobject]@{
      Name = (Get-LawVarName $left); Qualified = (Test-LawScriptQualified $left); Scope = (Get-LawScope $a)
      Start = $a.Extent.StartOffset; End = $a.Extent.EndOffset; IsList = [bool]$isList
      Line = $a.Extent.StartLineNumber })
  }
  $params = $Ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.ParameterAst] }, $true)
  foreach ($p in $params) {
    if (-not ($p.Name -is [System.Management.Automation.Language.VariableExpressionAst])) { continue }
    [void]$out.Add([pscustomobject]@{
      Name = (Get-LawVarName $p.Name); Qualified = $false; Scope = (Get-LawScope $p)
      Start = $p.Extent.StartOffset; End = $p.Extent.EndOffset; IsList = $false; Line = $p.Extent.StartLineNumber })
  }
  $loops = $Ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.ForEachStatementAst] }, $true)
  foreach ($f in $loops) {
    if (-not ($f.Variable -is [System.Management.Automation.Language.VariableExpressionAst])) { continue }
    [void]$out.Add([pscustomobject]@{
      Name = (Get-LawVarName $f.Variable); Qualified = $false; Scope = (Get-LawScope $f)
      Start = $f.Extent.StartOffset; End = $f.Extent.EndOffset; IsList = $false; Line = $f.Extent.StartLineNumber })
  }
  return $out.ToArray()
}

function Resolve-LawBinding {
  <# Pure. Is the binding this wrap will see a New-Object List[object]? $null when nothing binds the name,
     which is reported as nothing: an unresolved name is a could-not-look, never a finding. #>
  param($Binders, $Use)
  $name = $Use.Name
  # Candidate binders, innermost scope first. A $script:/$global: use reads the file's script scope, which is
  # written by a top-level assignment or by a $script:-qualified one anywhere.
  $groups = New-Object System.Collections.ArrayList
  if ($Use.Qualified) {
    $g = @($Binders | Where-Object { $_.Name -eq $name -and ($_.Qualified -or $null -eq $_.Scope) })
    [void]$groups.Add($g)
  } else {
    $scope = $Use.Scope
    while ($true) {
      $g = @($Binders | Where-Object { $_.Name -eq $name -and -not $_.Qualified -and $_.Scope -eq $scope })
      if ($g.Count) { [void]$groups.Add($g) ; break }
      if ($null -eq $scope) { break }
      $scope = Get-LawScope $scope
    }
  }
  foreach ($g in $groups) {
    # A binder whose extent CONTAINS the wrap cannot be the binding the wrap reads: `$x = @($x)` reads the
    # previous one. Everything else in the group is ordered by source offset.
    $cands = @($g | Where-Object { -not ($_.Start -le $Use.Start -and $_.End -ge $Use.End) })
    if (-not $cands.Count) { continue }
    $prior = @($cands | Where-Object { $_.Start -lt $Use.Start } | Sort-Object Start)
    if ($prior.Count) { return [pscustomobject]@{ IsList = $prior[$prior.Count - 1].IsList; Line = $prior[$prior.Count - 1].Line } }
    # Nothing precedes it textually - a function defined above the assignment that fills its variable. Then the
    # honest answer is only yes when EVERY binding of the name is the list, and no otherwise.
    $notList = @($cands | Where-Object { -not $_.IsList })
    return [pscustomobject]@{ IsList = ($notList.Count -eq 0); Line = $cands[0].Line }
  }
  return $null
}

function Get-LawFindings {
  <# Pure over one file's text, so the self-test drives exactly what the live scan runs.
     Returns @{ Findings = @({Line; Var; BoundAt; Text}); ParseErrors }. #>
  param([string]$Text)
  $tok = $null; $err = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseInput([string]$Text, [ref]$tok, [ref]$err)
  $parseErrors = if ($null -eq $err) { 0 } else { $err.Count }
  $src = ([string]$Text -replace "`r", '') -split "`n"
  $out = New-Object System.Collections.ArrayList
  $binders = Get-LawBinders $ast
  $wraps = $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.ArrayExpressionAst] }, $true)
  foreach ($w in $wraps) {
    $stmts = $w.SubExpression.Statements
    if ($stmts.Count -ne 1) { continue }
    $st = $stmts[0]
    if (-not ($st -is [System.Management.Automation.Language.PipelineAst])) { continue }
    if ($st.PipelineElements.Count -ne 1) { continue }
    $el = $st.PipelineElements[0]
    if (-not ($el -is [System.Management.Automation.Language.CommandExpressionAst])) { continue }
    $v = $el.Expression
    if (-not ($v -is [System.Management.Automation.Language.VariableExpressionAst])) { continue }
    $use = [pscustomobject]@{
      Name = (Get-LawVarName $v); Qualified = (Test-LawScriptQualified $v); Scope = (Get-LawScope $w)
      Start = $w.Extent.StartOffset; End = $w.Extent.EndOffset }
    $bound = Resolve-LawBinding -Binders $binders -Use $use
    if ($null -eq $bound -or -not $bound.IsList) { continue }
    $line = $w.Extent.StartLineNumber
    $t = $src[$line - 1].Trim()
    # A deliberate wrap says so on its own line, with a reason. A bare marker is not a marker.
    if ($t -match $script:LAW_ALLOW_RE) { continue }
    if ($t.Length -gt 160) { $t = $t.Substring(0, 160) + '...' }
    [void]$out.Add([pscustomobject]@{ Line = $line; Var = ('$' + [string]$v.VariablePath.UserPath); BoundAt = $bound.Line; Text = $t })
  }
  return [pscustomobject]@{ Findings = $out.ToArray(); ParseErrors = $parseErrors }
}

function Get-LawScanFiles {
  <# Every .ps1 and .psm1 under $RootDir, excluded on the path BELOW the root (lib\tree-walk.ps1), never $Self,
     and when $Tracked is given only the root-relative paths it holds. The extension is checked as well as
     filtered: a -Filter also matches longer extensions on Windows (*.ps1 finds .ps1xml). #>
  param([string]$RootDir, [string]$Self = '', $Tracked = $null)
  $rootFull = Get-TcRootFull $RootDir
  $ps1 = @(Get-TcTreeFiles -RootFull $rootFull -Filter *.ps1 -PruneBelow $script:LAW_WALK_EXCLUDE)
  $psm1 = @(Get-TcTreeFiles -RootFull $rootFull -Filter *.psm1 -PruneBelow $script:LAW_WALK_EXCLUDE)
  ($ps1 + $psm1) |
    Where-Object {
      $below = Get-TcPathBelowRoot $_.FullName $rootFull
      ($_.Extension -ieq '.ps1' -or $_.Extension -ieq '.psm1') -and ($below -notmatch $script:LAW_WALK_EXCLUDE) -and
      (-not [string]::Equals($_.FullName, $Self, [StringComparison]::OrdinalIgnoreCase)) -and
      ($null -eq $Tracked -or $Tracked.Contains($below.TrimStart('\')))
    } |
    Sort-Object FullName
}

# ------------------------------------------------------------------------------------------- self-test
if ($SelfTest) {
  $script:fail = 0; $script:cases = 0
  function LawT([string]$m, [bool]$c, [string]$got = '') {
    $script:cases++
    if ($c) { Write-Output ('  ok    ' + $m) } else { Write-Output ('  FAIL  ' + $m + '   got: ' + $got); $script:fail++ }
  }
  function LawGot($r) { return ('count=' + $r.Findings.Count + ' ' + (($r.Findings | ForEach-Object { 'line ' + $_.Line + ' ' + $_.Var }) -join '; ')) }

  # EVERY NEEDLE IS BUILT BY CONCATENATION, so this file's own source can never be a fixture for itself, and
  # each piece is assigned to a variable first: a `+` inside an argument is THREE arguments (ops-and-gates.md).
  $nw = 'New-' + 'Object'
  $ty = 'System.Collections.Generic.' + 'List[object]'
  $mk = '$rejects = ' + $nw + ' ' + $ty
  $mkQuoted = '$rows = ' + $nw + " '" + $ty + "'"
  $mkNamed = '$rows = ' + $nw + ' -ArgumentList 4 -TypeName ' + $ty
  $mkNew = '$rows = [' + $ty + ']::new()'
  $mkAl = '$rows = ' + $nw + ' System.Collections.ArrayList'
  $mkStr = '$rows = ' + $nw + ' System.Collections.Generic.' + 'List[string]'

  $sbDir = Join-Path ([IO.Path]::GetTempPath()) ('tc-law-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
  try {
    # ---- MUST FIRE ------------------------------------------------------------------------------------
    # The founding line, as 9c44c3a37 wrote it in grocery\build-sams-deals.ps1.
    $fxFounding = @($mk, '$hintNotes = @()', '$rjRows = @($rejects) + @($hintNotes)') -join "`n"
    $r = Get-LawFindings -Text $fxFounding
    LawT 'MUST FIRE  the founding Sam''s line: @($rejects) on line 3, bound by the New-Object on line 1' ($r.Findings.Count -eq 1 -and $r.Findings[0].Line -eq 3 -and $r.Findings[0].Var -eq '$rejects' -and $r.Findings[0].BoundAt -eq 1) (LawGot $r)

    $fxBare = @($mk, '$n = @($rejects).Count') -join "`n"
    $r = Get-LawFindings -Text $fxBare
    LawT 'MUST FIRE  the wrap ALONE, with no + anywhere - the half a concat-shaped rule would miss' ($r.Findings.Count -eq 1 -and $r.Findings[0].Line -eq 2) (LawGot $r)

    $fxForeach = @($mk, 'foreach ($row in @($rejects)) { $row }') -join "`n"
    $r = Get-LawFindings -Text $fxForeach
    LawT 'MUST FIRE  a foreach over the wrap, which throws before the loop body runs once' ($r.Findings.Count -eq 1 -and $r.Findings[0].Line -eq 2) (LawGot $r)

    $fxRight = @($mk, '$all = @($other) + @($rejects)') -join "`n"
    $r = Get-LawFindings -Text $fxRight
    LawT 'MUST FIRE  the wrap on the RIGHT of the +, because the operator is not what throws' ($r.Findings.Count -eq 1 -and $r.Findings[0].Var -eq '$rejects') (LawGot $r)

    $fxQuoted = @('function Build-Rows {', ('  ' + $mkQuoted), '  $out = @($rows) + @(1)', '  return $out', '}') -join "`n"
    $r = Get-LawFindings -Text $fxQuoted
    LawT 'MUST FIRE  a QUOTED type name, bound and wrapped inside one function body' ($r.Findings.Count -eq 1 -and $r.Findings[0].Line -eq 3) (LawGot $r)

    $fxNamed = @($mkNamed, '$out = @($rows)') -join "`n"
    $r = Get-LawFindings -Text $fxNamed
    LawT 'MUST FIRE  the type given as -TypeName with -ArgumentList ahead of it' ($r.Findings.Count -eq 1 -and $r.Findings[0].Line -eq 2) (LawGot $r)

    $fxScript = @(('$script:Notes = ' + $nw + ' ' + $ty), 'function Write-Notes { $n = @($script:Notes); $n }') -join "`n"
    $r = Get-LawFindings -Text $fxScript
    LawT 'MUST FIRE  a $script:-qualified list wrapped inside a function - the Sam''s hint-notes shape' ($r.Findings.Count -eq 1 -and $r.Findings[0].Line -eq 2) (LawGot $r)

    # ---- MUST NOT FIRE -------------------------------------------------------------------------------
    $r = Get-LawFindings -Text (@($mk, '$rjRows = @($rejects.ToArray()) + @($hintNotes)') -join "`n")
    LawT 'MUST NOT FIRE  the repair b7060307b shipped: .ToArray() inside the wrap' ($r.Findings.Count -eq 0) (LawGot $r)
    $r = Get-LawFindings -Text (@($mkAl, '$out = @($rows) + @(1)') -join "`n")
    LawT 'MUST NOT FIRE  an ArrayList, which wraps and concatenates without complaint' ($r.Findings.Count -eq 0) (LawGot $r)
    $r = Get-LawFindings -Text (@($mkNew, '$out = @($rows) + @(1)') -join "`n")
    LawT 'MUST NOT FIRE  the identical type built with ::new(), which is not PSObject-wrapped' ($r.Findings.Count -eq 0) (LawGot $r)
    $r = Get-LawFindings -Text (@($mkStr, '$out = @($rows) + @(1)') -join "`n")
    LawT 'MUST NOT FIRE  List[string] - the element type is half the rule' ($r.Findings.Count -eq 0) (LawGot $r)
    $r = Get-LawFindings -Text '$a = @(1,2); $b = @(3); $c = @($a) + @($b)'
    LawT 'MUST NOT FIRE  a plain array + array, the shape most of this tree is made of' ($r.Findings.Count -eq 0) (LawGot $r)
    $r = Get-LawFindings -Text (@($mk, '$out = $rejects + @(1)') -join "`n")
    LawT 'MUST NOT FIRE  the BARE variable in a +, which is legal and returns 3 (proved in a child below)' ($r.Findings.Count -eq 0) (LawGot $r)
    $r = Get-LawFindings -Text (@($mk, '$rejects = $rejects.ToArray()', '$out = @($rejects) + @(1)') -join "`n")
    LawT 'MUST NOT FIRE  a name REASSIGNED to an array before the wrap: the binding is the nearest one above' ($r.Findings.Count -eq 0) (LawGot $r)
    $r = Get-LawFindings -Text (@($mk, 'function Show-Rows { param($rejects) $out = @($rejects) }') -join "`n")
    LawT 'MUST NOT FIRE  a PARAMETER of the same name in a function, which binds its own local' ($r.Findings.Count -eq 0) (LawGot $r)
    $r = Get-LawFindings -Text (@($mk, '$out = @($rejects | Where-Object { $_ }) + @(1)') -join "`n")
    LawT 'MUST NOT FIRE  a pipeline inside the wrap, which enumerates the list and is legal' ($r.Findings.Count -eq 0) (LawGot $r)
    $r = Get-LawFindings -Text '$out = @($rejects) + @(1)'
    LawT 'MUST NOT FIRE  a name nothing in the file binds: an unresolved name is a could-not-look' ($r.Findings.Count -eq 0) (LawGot $r)
    $needle = '# was: $rjRows = @($rejects) + @($hintNotes)' + "`n" + '$doc = ''$x = @($rejects) + @(1)'''
    $r = Get-LawFindings -Text (@($mk, $needle) -join "`n")
    LawT 'MUST NOT FIRE  the founding shape quoted in a comment and inside a string' ($r.Findings.Count -eq 0) (LawGot $r)

    # ---- THE DELIBERATE EXCEPTION --------------------------------------------------------------------
    $probe = 'try { $null = @($rejects) } catch { $threw = $true }'
    $allow = '  # list-array-wrap:' + 'allow this line PROVES the throw against a live list'
    $r = Get-LawFindings -Text (@($mk, ($probe + $allow)) -join "`n")
    LawT 'MUST NOT FIRE  a fixture that EXECUTES the wrap to prove PS 5.1 still throws, marked with its reason' ($r.Findings.Count -eq 0) (LawGot $r)
    $r = Get-LawFindings -Text (@($mk, $probe) -join "`n")
    LawT 'MUST FIRE  the SAME line unmarked, so it is the marker that silences it and not the shape' ($r.Findings.Count -eq 1 -and $r.Findings[0].Line -eq 2) (LawGot $r)
    $bare = '  # list-array-wrap:' + 'allow'
    $r = Get-LawFindings -Text (@($mk, ($probe + $bare)) -join "`n")
    LawT 'MUST FIRE  a marker with NO reason after it is not a marker' ($r.Findings.Count -eq 1) (LawGot $r)

    # ---- CLEAN TWIN: the detector still reports a live site beside a repaired one --------------------
    $r = Get-LawFindings -Text (@($mk, '$safe = @($rejects.ToArray())', '$bad = @($rejects)') -join "`n")
    LawT 'CLEAN TWIN  a repaired wrap and a live one in the same file: the live one is still reported, on line 3' ($r.Findings.Count -eq 1 -and $r.Findings[0].Line -eq 3) (LawGot $r)

    # ---- THE HAZARD, END TO END: does this PowerShell still throw? ------------------------------------
    [void](New-Item -ItemType Directory -Path $sbDir -ErrorAction Stop)
    $utf8 = New-Object Text.UTF8Encoding($false)
    $childBody = @(
      '$ErrorActionPreference = ''Stop''',
      ('$l = ' + $nw + ' ' + $ty),
      '$l.Add(''a''); $l.Add(''b'')',
      '$arr = @(''p'')',
      'try { $w = @($l) + $arr; Write-Output ("WRAP-OK " + $w.Count) } catch { Write-Output ("WRAP-THREW " + $_.Exception.Message) }',
      'try { $b = $l + $arr; Write-Output ("BARE-OK " + $b.Count) } catch { Write-Output ("BARE-THREW " + $_.Exception.Message) }',
      ('$n = [' + $ty + ']::new()'),
      '$n.Add(''a''); $n.Add(''b'')',
      'try { $m = @($n) + $arr; Write-Output ("NEW-OK " + $m.Count) } catch { Write-Output ("NEW-THREW " + $_.Exception.Message) }',
      'try { $t = @($l.ToArray()) + $arr; Write-Output ("TOARRAY-OK " + $t.Count) } catch { Write-Output ("TOARRAY-THREW " + $_.Exception.Message) }',
      'exit 0'
    ) -join "`n"
    $childPath = Join-Path $sbDir 'hazard.ps1'
    [IO.File]::WriteAllText($childPath, $childBody, $utf8)
    $o = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $childPath)
    $rc = $LASTEXITCODE
    $joined = ($o -join '|')
    LawT 'MUST FIRE  the hazard still exists on this PowerShell: @(New-Object List[object]) throws "Argument types do not match"' ($rc -eq 0 -and $joined -match 'WRAP-THREW.*Argument types do not match') ('exit=' + $rc + ' out=' + $joined)
    LawT 'CLEAN TWIN  the BARE variable still concatenates in the same child, count 3 - which is why it is not reported' ($joined -match 'BARE-OK 3') ('out=' + $joined)
    LawT 'CLEAN TWIN  the ::new() list still wraps and concatenates, count 3 - the creation form is half the rule' ($joined -match 'NEW-OK 3') ('out=' + $joined)
    LawT 'CLEAN TWIN  the .ToArray() repair still concatenates, count 3' ($joined -match 'TOARRAY-OK 3') ('out=' + $joined)

    # ---- THE WALK, FROM A WORKTREE ROOT (lib\tree-walk.ps1) -------------------------------------------
    $wtFx = New-TcWorktreeFixture -Files @{ 'grocery\bad.ps1' = $fxFounding; 'ops\good.ps1' = (@($mkNew, '$out = @($rows)') -join "`n")
                                            'ops\untracked.ps1' = $fxBare; 'ops\me.ps1' = 'Write-Output 2'
                                            'lib\mod.psm1' = $fxBare }
    try {
      $self = Join-Path $wtFx.Root 'ops\me.ps1'
      $found = Get-LawScanFiles -RootDir $wtFx.Root -Self $self
      $found = @($found)
      $hits = Measure-TcWorktreeFixture -Fixture $wtFx -Found $found
      LawT 'CLEAN TWIN  a root that IS a worktree is scanned, not excluded whole: three .ps1 and a .psm1, not itself' ($hits.Root -eq 4) ('root=' + $hits.Root)
      LawT 'MUST NOT FIRE  a sibling worktree BELOW that root is still excluded' ($hits.Sibling -eq 0) ('sibling=' + $hits.Sibling)
      $mine = @($found | Where-Object { $_.FullName -eq $self })
      LawT 'MUST NOT FIRE  the detector never scans itself' ($mine.Count -eq 0) ''
      $trk = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
      foreach ($p in @('grocery\bad.ps1', 'ops\good.ps1', 'ops\me.ps1', 'lib\mod.psm1')) { [void]$trk.Add($p) }
      $tFound = Get-LawScanFiles -RootDir $wtFx.Root -Self $self -Tracked $trk
      $tFound = @($tFound)
      $tNames = ($tFound | ForEach-Object { $_.Name }) -join ','
      $untracked = @($tFound | Where-Object { $_.Name -eq 'untracked.ps1' })
      LawT 'MUST NOT FIRE  an untracked file is not scanned when git''s list is given' ($untracked.Count -eq 0) $tNames
      $sites = 0
      foreach ($f in $tFound) { $sites += (Get-LawFindings -Text ([IO.File]::ReadAllText($f.FullName))).Findings.Count }
      LawT 'CLEAN TWIN  the tracked walk reads all three tracked files, the .psm1 among them, and reports both live sites: 3 files, 2 sites' ($tFound.Count -eq 3 -and $sites -eq 2 -and $tNames -match 'mod\.psm1') (("files={0} sites={1} names={2}" -f $tFound.Count, $sites, $tNames))
    } finally { Remove-Item -LiteralPath $wtFx.Temp -Recurse -Force -ErrorAction SilentlyContinue }
  } catch {
    $script:cases++; $script:fail++
    Write-Output ('  FAIL  a case threw: ' + $_.Exception.Message)
  } finally {
    if (Test-Path -LiteralPath $sbDir) { Remove-Item -LiteralPath $sbDir -Recurse -Force -ErrorAction SilentlyContinue }
  }

  if ($script:fail) { Write-Output ("LIST-ARRAY-WRAP SELF-TEST FAILED ({0} of {1} case(s))" -f $script:fail, $script:cases); exit 1 }
  Write-Output ("LIST-ARRAY-WRAP SELF-TEST PASSED ({0} case(s): the founding Sam's line fires, the legal creation forms and the repair stay silent, the hazard still exists on this PowerShell, and the walk reads a worktree root and only tracked files)" -f $script:cases)
  exit 0
}

# ------------------------------------------------------------------------------------------- live run
$rootFull = Get-TcRootFull $repo
$listed = $null
try { $listed = & git -C $rootFull -c core.quotepath=off ls-files -- '*.ps1' '*.psm1' } catch { $listed = $null }
$gitRc = $LASTEXITCODE
$listed = @($listed | Where-Object { $_ })
if ($gitRc -ne 0 -or $listed.Count -eq 0) {
  Write-Output ("LIST-ARRAY-WRAP AUDIT BLIND: git ls-files exited {0} and listed {1} .ps1/.psm1 path(s), so there is no tracked set to read." -f $gitRc, $listed.Count)
  Exit-Guard -Name 'audit-list-array-wrap' -Summary 'blind=no-git-list' -Code 3
}
$tracked = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($p in $listed) { [void]$tracked.Add(([string]$p -replace '/', '\')) }
$files = Get-LawScanFiles -RootDir $rootFull -Self $PSCommandPath -Tracked $tracked
$files = @($files)
if ($files.Count -eq 0) {
  Write-Output ("LIST-ARRAY-WRAP AUDIT BLIND: git lists {0} .ps1/.psm1 path(s) and the walk resolved none of them, which means the discovery is broken rather than the tree being clean." -f $tracked.Count)
  Exit-Guard -Name 'audit-list-array-wrap' -Summary ("blind=walk-resolved-none listed={0}" -f $tracked.Count) -Code 3
}
$sites = New-Object System.Collections.ArrayList
$parseErrorFiles = 0
foreach ($f in $files) {
  $r = Get-LawFindings -Text ([IO.File]::ReadAllText($f.FullName))
  if ($r.ParseErrors) { $parseErrorFiles++ }
  $rel = (Get-TcPathBelowRoot $f.FullName $rootFull).TrimStart('\')
  foreach ($h in $r.Findings) { [void]$sites.Add(("{0}:{1}  {2} is the New-Object List[object] made on line {3}  {4}" -f $rel, $h.Line, $h.Var, $h.BoundAt, $h.Text)) }
}
$summary = "listed={0} files={1} parse_error_files={2} sites={3}" -f $tracked.Count, $files.Count, $parseErrorFiles, $sites.Count
Write-Output ("list-array-wrap: git lists {0} tracked .ps1/.psm1; the walk resolved {1}, {2} with a parse error; {3} site(s)" -f $tracked.Count, $files.Count, $parseErrorFiles, $sites.Count)
if ($sites.Count) {
  foreach ($s in $sites) { Write-Output ('  wrap   ' + $s) }
  Write-Output ("LIST-ARRAY-WRAP AUDIT FAILED: {0} array wrap(s) around a New-Object List[object]." -f $sites.Count)
  Write-Output '  Under PS 5.1 @($list) throws "Argument types do not match" there, even when the list is empty, and the'
  Write-Output '  error points at whatever encloses the wrap rather than at the wrap. Use @($list.ToArray()), or build the'
  Write-Output '  list with [System.Collections.Generic.List[object]]::new(), which is not PSObject-wrapped and wraps fine.'
  Exit-Guard -Name 'audit-list-array-wrap' -Summary $summary -Code 1
}
Write-Output 'list-array-wrap: PASSED - no tracked script wraps a New-Object List[object] in @().'
Exit-Guard -Name 'audit-list-array-wrap' -Summary $summary -Code 0
