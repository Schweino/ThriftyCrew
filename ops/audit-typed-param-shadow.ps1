<#
  audit-typed-param-shadow.ps1 - a value assigned to a TYPED parameter's name is converted to the parameter's type.

  SCOPE OF A CLEAN REPORT: UNSOUND. It reads the PowerShell AST of one file at a time and judges only a value
    whose KIND it can see without running anything. A clean report means no assignment it could judge changes
    kind on the way in. It cannot see a scope it does not own: a function or script DOT-SOURCED into a caller
    that declares the parameter, Set-Variable and New-Variable, a foreach loop variable, a multiple assignment
    ($a, $b = ...), a compound one (+=), or a value whose kind is decided at run time - a command's output, a
    pipeline with no @() around it, a method call, another variable. Those are counted UNJUDGED and printed,
    never passed. A reported site is real; silence is not proof. It is a RATCHET rather than a gate because the
    count it measured on its first day was not zero.

  THE TRAP. PowerShell variable names are case-insensitive, and a parameter declared with a type keeps that type
  for the life of its scope. So inside
      function Get-X([string]$Rule) { $rule = @($cmds | Where-Object { ... }) }
  the assignment does not make a new array. It converts the array to ONE string: $rule.Count reads 1 whatever it
  held, and $rule[0] is a character. Measured on PS 5.1, 2026-09-11: [string] joins an array with spaces, turns
  $null into '' and a hashtable into the text System.Collections.Hashtable; [bool] reads 'false' as True; [switch],
  [int] and [datetime] THROW on an array, and [switch] throws on any string.

  WHY THIS EXISTS (2026-09-11). .claude\rules\ops-and-gates.md recorded the trap after audit-fact-claims' tighten
  broke on it (a string assigned to $json beside [switch]$Json; the fix and its account are at
  meal-prep\pipeline\audit-fact-claims.ps1:281). The same day it recurred in a new self-test helper,
  Get-LcaWiring([string]$Path, [string]$Rule) in grocery\lane-commit-alert-lib.ps1 (c7a45b1b2 records the first
  cut in a comment), where an "exactly one exit rule" case passed over nothing and only a neighbouring case going
  red exposed it. A rule in a file did not prevent the second occurrence. This reaches the third at push time.
  Both founding shapes are frozen in the self-test, and so is the live site this found on its first run.

  WHAT IS A FINDING. A plain `$name = <value>`, unqualified or $local:/$private:, in the scope that owns a
  parameter of that name (case-insensitive) with a type constraint, where the value's kind provably does not
  survive the conversion:
      value kind                                   parameter kinds it is reported against
      array   @(), a,b  ,x  -split  .Split()  [T[]]   string, bool, switch, number, value
      dict    @{}  [ordered]@{}  [pscustomobject]@{}  string, bool, switch, number, value
      string  '...' "..." -f -join [string], a pipeline
              ending in ConvertTo-Json or Out-String  bool, switch, number (unless it is a numeric literal)
      numeric literal string such as '7'           bool, switch
      $null                                        string, number, value
  Parameter kinds: string; bool; switch; number (the integer and floating types); value (datetime, timespan,
  guid, char). [object], [psobject] and an untyped parameter hold anything and are never reported. Every other
  type - [string[]], [hashtable], [scriptblock], a class - is not judged.

  SAME-TYPE REASSIGNMENT IS LEGAL, AND THE COUNT DECIDED IT. The census behind this file (2026-09-11 at e5ccc768e,
  577 .ps1 files, 37,345 assignments) found 507 assignments to a typed parameter's name. 415 sat inside an `if`
  testing that same variable - `if (-not $Path) { $Path = Join-Path ... }`, a default fill - 70 more read the
  parameter on their right - `$Path = Resolve-Path $Path`, `$t = $T.ToLower()` - and 22 did neither. Reporting all 507 would bury the
  trap under code that means what it says, and a ratchet people learn to ignore guards nothing. So the finding is
  the KIND CHANGE, not the name collision, and a default fill that changes kind is still reported. Of the 507,
  exactly one changed kind provably: meal-prep\engine\golden-test.ps1:286, `$structural = @(...)` beside
  [switch]$Structural in its script param block, which threw on every -Provenance -Force run (reproduced
  2026-09-11: exit 1 at that line, under the script's own $ErrorActionPreference = 'Stop'). The commit after the
  one that added this file renamed it, and the mark recorded that fall to 0 through -Tighten -AcceptDrop - the
  fall to zero lib\ratchet.ps1 refuses without it.

  THIS FILE'S OWN DAY-ONE READING, through ops\audit-typed-param-shadow.ps1 at e5ccc768e plus this change, from a
  linked worktree: 577 .ps1 resolved, 483 parsed, 35,497 assignments, 505 to a typed parameter's name - 1 reported,
  42 provably the same kind, 462 unjudged. It owns more scopes than the census script did (.Where, dot-sourcing) and
  parses only files that declare a judged type, so its 505 and the census's 507 are two tests of one tree, not a drift.

  WHICH SCOPE OWNS A NAME, as measured on PS 5.1 on 2026-09-11 (the self-test pins each):
    * a function's parameters, a param() block's, or a class method's own the assignments in their body
    * the bodies of ForEach-Object, %, foreach, Where-Object, ?, where, .ForEach({}), .Where({}) and . { } run in
      the enclosing scope, so an assignment there converts too; if, switch, try and loops are not scopes at all
    * any other script block (& { }, $sb = { }, Invoke-Command, Start-Job) and a nested function is a CHILD scope,
      where the same assignment makes a new, unconstrained local - not a finding
    * `[string[]]$rule = @()` declares a new constraint and replaces the old one - not a finding

  EXIT CODES (lib\guard-contract.ps1 vocabulary): 0 at or under the baseline, 2 a site the baseline does not name
  (even at an unchanged count) or -Tighten refused an implausible fall, 3 could not evaluate - no files resolved,
  or no readable baseline. Read the verdict LINE, not the number.

  A PLAIN RUN NEVER WRITES THE BASELINE. It is tracked, and a pre-push gate that rewrites it dirties the checkout
  being pushed without riding the push (the account is in ops\audit-write-only-reports.ps1). A fall is spoken and
  the committed mark kept; -Tighten records it through lib\ratchet.ps1's plausibility bar.

    ops\audit-typed-param-shadow.ps1                       scan the tree, hold the ratchet, write nothing
    ops\audit-typed-param-shadow.ps1 -Tighten              also record a believable fall (or the first baseline)
    ops\audit-typed-param-shadow.ps1 -Tighten -AcceptDrop  record a fall lib\ratchet.ps1 would refuse
    ops\audit-typed-param-shadow.ps1 -SelfTest             founding shapes, legal forms, scopes, walk, live path
#>
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop (2026-09-07)
param([switch]$SelfTest, [switch]$Tighten, [switch]$AcceptDrop, [string]$Root = '', [string]$BaselineFile = '')
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\ratchet.ps1')
. (Join-Path $repo 'lib\tree-walk.ps1')   # Get-TcPathBelowRoot: a walk from a worktree reads the worktree
. (Join-Path $repo 'lib\lf-write.ps1')    # Write-TcLfFile: the baseline is tracked and stored eol=lf

# THIS SCRIPT DECLARES [string]$Root, [string]$BaselineFile and three switches, so it never assigns a variable
# spelled like any of them. The live run's names are $scanRoot and $blPath for exactly that reason.

$script:TPS_GUARD = 'audit-typed-param-shadow'
$script:TPS_WALK_EXCLUDE = '\\work' + 'trees\\|\\archive\\|\\out\\|node_modules|\\\.git\\'
# Commands whose script block runs in the CALLER's scope (measured, see the header). -contains is case-insensitive.
$script:TPS_SAME_SCOPE_COMMANDS = @('ForEach-Object', '%', 'foreach', 'Where-Object', '?', 'where')
$script:TPS_SAME_SCOPE_METHODS = @('ForEach', 'Where')
# A pipeline whose LAST command is one of these yields one string.
$script:TPS_STRING_COMMANDS = @('ConvertTo-Json', 'Out-String')
# Which parameter kinds each value kind is reported against, and what the conversion does.
$script:TPS_MISMATCH = @{
  'array'          = @('string', 'bool', 'switch', 'number', 'value')
  'dict'           = @('string', 'bool', 'switch', 'number', 'value')
  'string'         = @('bool', 'switch', 'number')
  'numeric-string' = @('bool', 'switch')
  'null'           = @('string', 'number', 'value')
}
$script:TPS_EFFECT = @{
  'array>string' = 'joined into ONE string: .Count reads 1 and [0] is a character'
  'dict>string'  = 'becomes the text of its type name'
  'null>string'  = 'becomes '''' and never tests equal to $null'
  'null>number'  = 'becomes 0'
  'string>bool'  = 'any non-empty string is True, ''false'' included'
  'numeric-string>bool' = 'any non-empty string is True, ''0'' included'
}

# ------------------------------------------------------------------------------------------------ the judgement
function Get-TpsTypeKind {
  <# The kind of a type constraint, from its NAME, so an unloaded class resolves to 'other' rather than failing. #>
  param([string]$TypeName)
  $t = ($TypeName -replace '^System\.', '').ToLowerInvariant()
  if ($t -match '^(string)$') { return 'string' }
  if ($t -match '^(bool|boolean)$') { return 'bool' }
  if ($t -match '^(switch|switchparameter|management\.automation\.switchparameter)$') { return 'switch' }
  if ($t -match '^(u?int(16|32|64)?|u?long|u?short|s?byte|double|single|float|decimal)$') { return 'number' }
  if ($t -match '^(datetime|timespan|guid|char)$') { return 'value' }
  if ($t -match '^(object|psobject|pscustomobject|management\.automation\.psobject)$') { return 'untyped' }
  return 'other'
}

function Get-TpsCore {
  <# Unwrap a one-element pipeline, a command expression and parens. Stops at anything else. #>
  param($Node)
  $n = $Node
  for ($i = 0; $i -lt 32 -and $null -ne $n; $i++) {
    $k = $n.GetType().Name
    if ($k -eq 'PipelineAst' -and $n.PipelineElements.Count -eq 1) { $n = $n.PipelineElements[0] }
    elseif ($k -eq 'CommandExpressionAst') { $n = $n.Expression }
    elseif ($k -eq 'ParenExpressionAst') { $n = $n.Pipeline }
    else { return $n }
  }
  return $n
}

function Get-TpsValueKind {
  <# array, dict, string, numeric-string, null, scalar or unknown. Only what the AST shows without running anything. #>
  param($Node)
  if ($null -ne $Node -and $Node.GetType().Name -eq 'PipelineAst' -and $Node.PipelineElements.Count -gt 1) {
    $last = $Node.PipelineElements[$Node.PipelineElements.Count - 1]
    if ($last.GetType().Name -eq 'CommandAst' -and $script:TPS_STRING_COMMANDS -contains [string]$last.GetCommandName()) { return 'string' }
    return 'unknown'
  }
  $n = Get-TpsCore $Node
  if ($null -eq $n) { return 'unknown' }
  $k = $n.GetType().Name
  if ($k -eq 'ArrayExpressionAst' -or $k -eq 'ArrayLiteralAst' -or $k -eq 'HashtableAst') {
    if ($k -eq 'HashtableAst') { return 'dict' }
    return 'array'
  }
  if ($k -eq 'StringConstantExpressionAst') {
    $d = 0.0
    if ([double]::TryParse([string]$n.Value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return 'numeric-string' }
    return 'string'
  }
  if ($k -eq 'ExpandableStringExpressionAst') { return 'string' }
  if ($k -eq 'ConstantExpressionAst') { return 'scalar' }
  if ($k -eq 'VariableExpressionAst') {
    $u = [string]$n.VariablePath.UserPath
    if ($u -ieq 'null') { return 'null' }
    if ($u -ieq 'true' -or $u -ieq 'false') { return 'scalar' }
    return 'unknown'
  }
  if ($k -eq 'UnaryExpressionAst') {
    $tk = $n.TokenKind.ToString()
    if ($tk -eq 'Comma' -or $tk -match '^[IC]?split$') { return 'array' }
    if ($tk -match '^[IC]?join$') { return 'string' }
    return 'unknown'
  }
  if ($k -eq 'BinaryExpressionAst') {
    $op = $n.Operator.ToString()
    if ($op -match '^[IC]split$') { return 'array' }
    if ($op -eq 'Format' -or $op -eq 'Join') { return 'string' }
    return 'unknown'
  }
  if ($k -eq 'InvokeMemberExpressionAst' -and -not $n.Static -and [string]$n.Member.Value -ieq 'Split') { return 'array' }
  if ($k -eq 'ConvertExpressionAst') {
    $tn = [string]$n.Type.TypeName.FullName
    if ($tn -match '\[\]$' -or $tn -match '^(System\.)?array$') { return 'array' }
    if ($n.Child.GetType().Name -eq 'HashtableAst') { return 'dict' }
    if ($tn -match '^(System\.)?string$') { return 'string' }
    return 'unknown'
  }
  return 'unknown'
}

function Test-TpsSharesScope {
  <# Does this script block expression run in the scope around it (true) or in a child scope (false)? #>
  param($SbExpr)
  $par = $SbExpr.Parent
  if ($null -ne $par -and $par.GetType().Name -eq 'CommandParameterAst') { $par = $par.Parent }
  if ($null -eq $par) { return $false }
  $k = $par.GetType().Name
  if ($k -eq 'CommandAst') {
    if ($par.InvocationOperator.ToString() -eq 'Dot' -and [object]::ReferenceEquals($par.CommandElements[0], $SbExpr)) { return $true }
    return ($script:TPS_SAME_SCOPE_COMMANDS -contains [string]$par.GetCommandName())
  }
  if ($k -eq 'InvokeMemberExpressionAst') { return ($script:TPS_SAME_SCOPE_METHODS -contains [string]$par.Member.Value) }
  return $false
}

function Get-TpsOwnedParameters {
  <# The ParameterAst list of the scope that owns this assignment. Empty when that scope declares none, or when the
     assignment sits in a child scope, where it makes a new local. Wrapped in an object so PS 5.1 cannot unroll it. #>
  param($Assignment)
  $p = $Assignment.Parent
  while ($null -ne $p) {
    if ($p.GetType().Name -eq 'ScriptBlockAst') {
      $owner = $p.Parent
      $ok = if ($null -eq $owner) { '' } else { $owner.GetType().Name }
      if ($ok -eq 'FunctionDefinitionAst') {
        $list = New-Object System.Collections.ArrayList
        if ($owner.Parameters) { foreach ($x in $owner.Parameters) { [void]$list.Add($x) } }
        if ($p.ParamBlock) { foreach ($x in $p.ParamBlock.Parameters) { [void]$list.Add($x) } }
        return [pscustomobject]@{ Params = $list.ToArray() }
      }
      if ($ok -eq 'FunctionMemberAst') { return [pscustomobject]@{ Params = @($owner.Parameters) } }
      if ($null -ne $p.ParamBlock) { return [pscustomobject]@{ Params = @($p.ParamBlock.Parameters) } }
      if ($ok -eq '' -or $ok -ne 'ScriptBlockExpressionAst' -or -not (Test-TpsSharesScope $owner)) {
        return [pscustomobject]@{ Params = @() }
      }
    }
    $p = $p.Parent
  }
  return [pscustomobject]@{ Params = @() }
}

function Get-TpsFindings {
  <# Pure over one file's text, so the self-test drives exactly what the live scan runs.
     Returns @{ Findings = @({Line; Param; Kind; Effect; Text}); Read; ParseErrors; Assignments; Typed; Legal; Unjudged }.
     Read is false when no parameter of a judged type is declared under a name the file also assigns - such a file
     cannot hold a finding and is never parsed. #>
  param([string]$Source)
  $none = [pscustomobject]@{ Findings = @(); Read = $false; ParseErrors = 0; Assignments = 0; Typed = 0; Legal = 0; Unjudged = 0 }
  if ([string]::IsNullOrEmpty($Source)) { return $none }
  $typeRx = '(?i)\[(?:system\.)?(?:string|bool|boolean|switch|switchparameter|management\.automation\.switchparameter|u?int(?:16|32|64)?|u?long|u?short|s?byte|double|single|float|decimal|datetime|timespan|guid|char)\]\s*\$(\w+)'
  $candidates = @([regex]::Matches($Source, $typeRx) | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
  $assigned = $false
  foreach ($nm in $candidates) {
    if ($Source -match ('(?i)(?<![\w:])\$(?:local:|private:)?' + [regex]::Escape($nm) + '\s*=(?!=)')) { $assigned = $true; break }
  }
  if (-not $assigned) { return $none }

  $tok = $null; $err = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseInput($Source, [ref]$tok, [ref]$err)
  $lines = ($Source -replace "`r", '') -split "`n"
  $out = New-Object System.Collections.ArrayList
  $nAssign = 0; $nTyped = 0; $nLegal = 0; $nUnjudged = 0
  foreach ($a in $ast.FindAll({ param($x) $x.GetType().Name -eq 'AssignmentStatementAst' }, $true)) {
    $nAssign++
    if ($a.Operator.ToString() -ne 'Equals' -or $a.Left.GetType().Name -ne 'VariableExpressionAst') { continue }
    $vp = $a.Left.VariablePath
    if ($vp.IsScript -or $vp.IsGlobal -or $vp.IsDriveQualified) { continue }
    # UserPath with the qualifier stripped, NOT VariablePath.UnqualifiedPath: PS 5.1 has no public one, so it read
    # $null, no name matched, and the first cut of this file judged 0 of 35,497 assignments while every MUST NOT
    # FIRE case passed. The MUST FIRE cases caught it; the live floor below is the half that catches it in production.
    $name = [string]$vp.UserPath -replace '^(local|private):', ''
    $owned = Get-TpsOwnedParameters $a
    $pm = $null
    foreach ($x in @($owned.Params)) {
      if ([string]::Equals([string]$x.Name.VariablePath.UserPath, $name, [StringComparison]::OrdinalIgnoreCase)) { $pm = $x; break }
    }
    if ($null -eq $pm) { continue }
    $tcs = @($pm.Attributes | Where-Object { $_.GetType().Name -eq 'TypeConstraintAst' })
    if (-not $tcs.Count) { continue }
    $typeName = [string]$tcs[$tcs.Count - 1].TypeName.FullName
    $pKind = Get-TpsTypeKind $typeName
    if ($pKind -eq 'untyped') { continue }
    $nTyped++
    $vKind = Get-TpsValueKind $a.Right
    if ($vKind -eq 'unknown') { $nUnjudged++; continue }
    $bad = $script:TPS_MISMATCH.ContainsKey($vKind) -and ($script:TPS_MISMATCH[$vKind] -contains $pKind)
    if (-not $bad) { $nLegal++; continue }
    $effect = $script:TPS_EFFECT[$vKind + '>' + $pKind]
    if (-not $effect) { $effect = 'THROWS: the value cannot convert' }
    $ln = $a.Extent.StartLineNumber
    $txt = ($a.Extent.Text -replace '\s+', ' ').Trim()
    if ($txt.Length -gt 200) { $txt = $txt.Substring(0, 200) }
    [void]$out.Add([pscustomobject]@{ Line = $ln; Param = ('[' + $typeName + ']$' + [string]$pm.Name.VariablePath.UserPath)
        Kind = $vKind; Effect = $effect; Text = $txt })
  }
  return [pscustomobject]@{ Findings = $out.ToArray(); Read = $true; ParseErrors = @($err).Count
    Assignments = $nAssign; Typed = $nTyped; Legal = $nLegal; Unjudged = $nUnjudged }
}

function Get-TpsSiteKey {
  <# A site's identity in the baseline: file, parameter, kind and text, and never the line, so an edit above a known
     site does not read as a new one. #>
  param([string]$Rel, $Finding)
  return ('{0} :: {1} <- {2} :: {3}' -f $Rel, $Finding.Param, $Finding.Kind, $Finding.Text)
}

function Compare-TpsSites {
  <# Multiset difference both ways. A site swapped for a new one at the SAME count is still a new site, which a
     bare count cannot see. #>
  param([string[]]$Now, [string[]]$Known)
  $left = @{}
  foreach ($k in @($Known)) { if ($null -ne $k) { if ($left.ContainsKey($k)) { $left[$k]++ } else { $left[$k] = 1 } } }
  $new = New-Object System.Collections.ArrayList
  foreach ($k in @($Now)) {
    if ($null -eq $k) { continue }
    if ($left.ContainsKey($k) -and $left[$k] -gt 0) { $left[$k]-- } else { [void]$new.Add($k) }
  }
  $gone = New-Object System.Collections.ArrayList
  foreach ($k in $left.Keys) { for ($i = 0; $i -lt $left[$k]; $i++) { [void]$gone.Add($k) } }
  return [pscustomobject]@{ New = $new.ToArray(); Gone = $gone.ToArray() }
}

# ------------------------------------------------------------------------------------------------------ the walk
function Get-TpsScanFiles {
  <# Every .ps1 under $RootDir, excluded on the path BELOW the root (lib\tree-walk.ps1), and never $Self. #>
  param([string]$RootDir, [string]$Self = '')
  $rootFull = Get-TcRootFull $RootDir
  Get-ChildItem -LiteralPath $rootFull -Recurse -File -Filter *.ps1 -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -ieq '.ps1' -and
                   (Get-TcPathBelowRoot $_.FullName $rootFull) -notmatch $script:TPS_WALK_EXCLUDE -and
                   -not [string]::Equals($_.FullName, $Self, [StringComparison]::OrdinalIgnoreCase) } |
    Sort-Object FullName
}

function Write-TpsBaseline {
  param([string]$Path, [int]$Count, [string[]]$Names, $PriorDoc)
  $doc = if ($null -ne $PriorDoc) { $PriorDoc } else { [pscustomobject]@{} }
  $hist = Add-RatchetHistory -Doc $doc -Count $Count
  $body = [ordered]@{
    note      = 'HIGH-WATER MARK for assignments that change a TYPED parameter''s kind (ops\audit-typed-param-shadow.ps1). It may only go DOWN; a fall is recorded only by -Tighten, and a fall to zero or over 60% in one run needs -AcceptDrop (lib\ratchet.ps1).'
    generated = (Get-Date).ToString('s')
    sites     = $Count
    names     = @($Names | Sort-Object)
    history   = $hist
  }
  return (Write-TcLfFile -Path $Path -Text ($body | ConvertTo-Json -Depth 5) -NoBom)
}

# ----------------------------------------------------------------------------------------------------- self-test
if ($SelfTest) {
  $script:fail = 0; $script:cases = 0
  function TpsT([string]$m, [bool]$c, [string]$got = '') {
    $script:cases++
    if ($c) { Write-Output ('  ok    ' + $m) } else { Write-Output ('  FAIL  ' + $m + '   got: ' + $got); $script:fail++ }
  }
  function TpsGot($r) { return ('count=' + @($r.Findings).Count + ' lines=' + ((@($r.Findings) | ForEach-Object { $_.Line }) -join ',') + ' read=' + $r.Read + ' typed=' + $r.Typed + ' legal=' + $r.Legal + ' unjudged=' + $r.Unjudged) }
  function TpsLines([string[]]$Rows) { return ($Rows -join "`n") }
  function TpsOne($r, [int]$Line) { return (@($r.Findings).Count -eq 1 -and @($r.Findings)[0].Line -eq $Line) }

  # THE SHADOW IS SPELLED BY CONCATENATION, so no line of this file is itself the founding assignment.
  $S = '$ru' + 'le'
  $E = ' ' + '= '

  try {
    # ---- MUST FIRE: the founding shape, Get-LcaWiring's first cut as c7a45b1b2's comment records it --------
    $fxFounding = TpsLines @(
      'function Get-LcaWiring([string]$Path, [string]$Rule) {',
      '  $tok = $null; $err = $null',
      '  $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tok, [ref]$err)',
      '  $cmds = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))',
      ('  ' + $S + $E + '@($cmds | Where-Object { [string]$_.GetCommandName() -ieq $Rule })'),
      '  $w = [pscustomobject]@{ rules = $rule.Count }',
      '}')
    $r = Get-TpsFindings -Source $fxFounding
    TpsT 'MUST FIRE  the founding shape: [string]$Rule and an @() assigned to $rule in the same function, on line 5' (TpsOne $r 5) (TpsGot $r)
    TpsT 'MUST FIRE  ...reported as an array into [string]$Rule, with the conversion named' ($r.Findings[0].Kind -eq 'array' -and $r.Findings[0].Param -eq '[string]$Rule' -and $r.Findings[0].Effect -like '*ONE string*') ("{0} {1}" -f $r.Findings[0].Kind, $r.Findings[0].Param)

    # ---- MUST FIRE: the second founding shape, audit-fact-claims' tighten before its fix at line 281 -------
    $fxFact = TpsLines @(
      '[CmdletBinding()]',
      'param([switch]$SelfTest, [switch]$Json)',
      'if (-not (Test-Path -LiteralPath $BASELINE_FILE)) {',
      ('  $js' + 'on' + $E + '@{ generated = (Get-Date).ToString(''s''); undeclared = $count } | ConvertTo-Json -Depth 3'),
      '}')
    $r = Get-TpsFindings -Source $fxFact
    TpsT 'MUST FIRE  [switch]$Json in a script param block and a pipeline ending in ConvertTo-Json assigned to $json, on line 4' (TpsOne $r 4) (TpsGot $r)

    # ---- MUST FIRE: the live site this found on its first run, meal-prep\engine\golden-test.ps1:286 ----------
    $fxGolden = TpsLines @(
      'param(',
      '  [switch]$Structural,',
      '  [switch]$Provenance',
      ')',
      'if($Provenance){',
      '    $all = @($totalDiffs) + @($lineDiffs)',
      ('    $struct' + 'ural' + $E + '@($all | Where-Object { $_ -match ''line only in (NEW|OLD)'' })'),
      '}')
    $r = Get-TpsFindings -Source $fxGolden
    TpsT 'MUST FIRE  golden-test.ps1:286 as found: @() assigned to $structural beside [switch]$Structural, inside an if, on line 7' (TpsOne $r 7) (TpsGot $r)
    TpsT 'MUST FIRE  ...and an array into [switch] is named as a throw' ($r.Findings[0].Effect -like 'THROWS*') $r.Findings[0].Effect

    # ---- MUST FIRE: the scopes the header claims share the parameter's scope ---------------------------------
    $r = Get-TpsFindings -Source ('function F([string]$Rule) { $items | ForEach-Object { ' + $S + $E + '@($_) } }')
    TpsT 'MUST FIRE  inside a ForEach-Object body, which runs in the function''s scope' (TpsOne $r 1) (TpsGot $r)
    $r = Get-TpsFindings -Source ('function F([string]$Rule) { $null = $items.Where({ ' + $S + $E + '@($_); $true }) }')
    TpsT 'MUST FIRE  inside a .Where({}) method body' (TpsOne $r 1) (TpsGot $r)
    $r = Get-TpsFindings -Source ('function F([string]$Rule) { . { ' + $S + $E + '@(1, 2) } }')
    TpsT 'MUST FIRE  inside a dot-sourced script block' (TpsOne $r 1) (TpsGot $r)
    $r = Get-TpsFindings -Source (TpsLines @('function F {', '  param([Parameter(Mandatory=$true)][int]$Count)', ('  $co' + 'unt' + $E + '@(1, 2)'), '}'))
    TpsT 'MUST FIRE  a param() block inside the body, behind a [Parameter()] attribute, [int] from an array, on line 3' (TpsOne $r 3) (TpsGot $r)
    $r = Get-TpsFindings -Source ('function F([string]$Rule) { if (-not $Rule) { ' + $S + $E + '@(''a'', ''b'') } }')
    TpsT 'MUST FIRE  a default fill that CHANGES KIND is still reported - the kind decides, not the if' (TpsOne $r 1) (TpsGot $r)
    $r = Get-TpsFindings -Source ('function F([string]$Rule) { $local:rule' + $E + '@(1, 2) }')
    TpsT 'MUST FIRE  $local:rule is the same variable' (TpsOne $r 1) (TpsGot $r)
    $r = Get-TpsFindings -Source ('class K { [object] M([string]$Rule) { ' + $S + $E + '@(1, 2); return $rule } }')
    TpsT 'MUST FIRE  a class method''s typed parameter' (TpsOne $r 1) (TpsGot $r)

    # ---- MUST FIRE: every value kind in the table -------------------------------------------------------------
    $r = Get-TpsFindings -Source ('function F([string]$Rule) { ' + $S + $E + '$Rule -split '','' }')
    TpsT 'MUST FIRE  -split into [string]' ((TpsOne $r 1) -and $r.Findings[0].Kind -eq 'array') (TpsGot $r)
    $r = Get-TpsFindings -Source ('function F([string]$Rule) { ' + $S + $E + '$line.Split('','') }')
    TpsT 'MUST FIRE  .Split() into [string]' (TpsOne $r 1) (TpsGot $r)
    $r = Get-TpsFindings -Source ('function F([string]$Rule) { ' + $S + $E + '''a'', ''b'' }')
    TpsT 'MUST FIRE  a bare a,b array literal into [string]' (TpsOne $r 1) (TpsGot $r)
    $r = Get-TpsFindings -Source ('function F([string]$Rule) { ' + $S + $E + '[ordered]@{ a = 1 } }')
    TpsT 'MUST FIRE  an [ordered] hashtable into [string]' ((TpsOne $r 1) -and $r.Findings[0].Kind -eq 'dict') (TpsGot $r)
    $r = Get-TpsFindings -Source ('function F([bool]$Strict) { $str' + 'ict' + $E + '''false'' }')
    TpsT 'MUST FIRE  the string ''false'' into [bool], which reads True' ((TpsOne $r 1) -and $r.Findings[0].Effect -like '*True*') (TpsGot $r)
    $r = Get-TpsFindings -Source ('function F([bool]$Strict) { $str' + 'ict' + $E + '''0'' }')
    TpsT 'MUST FIRE  a numeric string into [bool]' ((TpsOne $r 1) -and $r.Findings[0].Kind -eq 'numeric-string') (TpsGot $r)
    $r = Get-TpsFindings -Source ('function F([int]$Days) { $da' + 'ys' + $E + '"$n days" }')
    TpsT 'MUST FIRE  an expandable string into [int]' (TpsOne $r 1) (TpsGot $r)
    $r = Get-TpsFindings -Source ('function F([string]$Rule) { ' + $S + $E + '$null }')
    TpsT 'MUST FIRE  $null into [string], which becomes an empty string' ((TpsOne $r 1) -and $r.Findings[0].Kind -eq 'null') (TpsGot $r)
    $r = Get-TpsFindings -Source ('function F([System.DateTime]$When) { $wh' + 'en' + $E + '$null }')
    TpsT 'MUST FIRE  $null into a namespaced [System.DateTime]' (TpsOne $r 1) (TpsGot $r)

    # ---- MUST NOT FIRE: legal inputs ------------------------------------------------------------------------
    # EVERY LEGAL CASE ASSERTS IT WAS SEEN - Read, and a Typed/Legal/Unjudged count - so its silence is a verdict
    # rather than a skipped file. Without that, all eleven passed over a resolver that matched no name at all.
    $r = Get-TpsFindings -Source ('function F($Rule, [string]$Name) { ' + $S + $E + '@($cmds | Where-Object { $_ }); $Na' + 'me' + $E + '''x'' }')
    TpsT 'MUST NOT FIRE  an UNTYPED parameter reassigned with an array - it holds anything; the file WAS judged, through [string]$Name' (@($r.Findings).Count -eq 0 -and $r.Read -and $r.Typed -eq 1 -and $r.Legal -eq 1) (TpsGot $r)
    $r = Get-TpsFindings -Source ('function F([object]$Rule, [psobject]$Other, [string]$Name) { ' + $S + $E + '@(1, 2); $oth' + 'er' + $E + '@(1, 2); $Na' + 'me' + $E + '''x'' }')
    TpsT 'MUST NOT FIRE  [object] and [psobject] hold an array unchanged (measured), and are not counted as typed' (@($r.Findings).Count -eq 0 -and $r.Read -and $r.Typed -eq 1) (TpsGot $r)
    $r = Get-TpsFindings -Source ('function F([string]$Path) { $Pa' + 'th' + $E + 'Resolve-Path $Path }')
    TpsT 'MUST NOT FIRE  $Path = Resolve-Path $Path, a same-type update: SEEN as an assignment to [string]$Path, left unjudged, never reported' (@($r.Findings).Count -eq 0 -and $r.Typed -eq 1 -and $r.Unjudged -eq 1) (TpsGot $r)
    $r = Get-TpsFindings -Source ('function F([string]$Name, [int]$Count) { if (-not $Name) { $Na' + 'me' + $E + '''x'' }; $Co' + 'unt' + $E + '''7'' }')
    TpsT 'MUST NOT FIRE  a string into [string], and a numeric string into [int] - both seen and judged legal' (@($r.Findings).Count -eq 0 -and $r.Typed -eq 2 -and $r.Legal -eq 2) (TpsGot $r)
    $r = Get-TpsFindings -Source ('function F([string[]]$Ids, [string]$Name) { $Id' + 's' + $E + '@($Ids | Where-Object { $_ }); $Na' + 'me' + $E + '''x'' }')
    TpsT 'MUST NOT FIRE  an array into [string[]] - seen and judged legal' (@($r.Findings).Count -eq 0 -and $r.Typed -eq 2 -and $r.Legal -eq 2) (TpsGot $r)
    $r = Get-TpsFindings -Source ('function F([switch]$Force) { $For' + 'ce' + $E + '$true }')
    TpsT 'MUST NOT FIRE  $true into [switch] - seen and judged legal' (@($r.Findings).Count -eq 0 -and $r.Typed -eq 1 -and $r.Legal -eq 1) (TpsGot $r)
    $r = Get-TpsFindings -Source ('function F([string]$Rule) { & { ' + $S + $E + '@(1, 2) }; $sb' + $E + '{ ' + $S + $E + '@(1, 2) } }')
    TpsT 'MUST NOT FIRE  & { } and a stored script block are CHILD scopes, where the name is a new local (measured)' (@($r.Findings).Count -eq 0 -and $r.Read -and $r.Typed -eq 0) (TpsGot $r)
    $r = Get-TpsFindings -Source ('function F([string]$Rule) { function Inner { ' + $S + $E + '@(1, 2) }; Inner }')
    TpsT 'MUST NOT FIRE  a nested function that declares no such parameter' (@($r.Findings).Count -eq 0 -and $r.Read -and $r.Typed -eq 0) (TpsGot $r)
    $r = Get-TpsFindings -Source ('function F([string]$Rule) { $script:rule' + $E + '@(1, 2) }')
    TpsT 'MUST NOT FIRE  $script:rule is another variable' (@($r.Findings).Count -eq 0) (TpsGot $r)
    $r = Get-TpsFindings -Source ('function F([string]$Rule) { [string[]]' + $S + $E + '@(1, 2) }')
    TpsT 'MUST NOT FIRE  [string[]]$rule = @() declares a new constraint (measured)' (@($r.Findings).Count -eq 0) (TpsGot $r)
    $fxProse = TpsLines @(
      'function F([string]$Rule) {',
      ('  # was: ' + $S + $E + '@($cmds)'),
      ('  Write-Output ''' + $S + $E + '@($cmds)'''),
      '}')
    $r = Get-TpsFindings -Source $fxProse
    TpsT 'MUST NOT FIRE  the shape quoted in a comment and in a string' (@($r.Findings).Count -eq 0) (TpsGot $r)

    # ---- CLEAN TWIN: the adjacent behaviour a name-collision detector is most likely to break ------------------
    $fxTwin = TpsLines @(
      'function Get-TpsProbe([string]$Rule) {',
      '  $cmds = @(''a'', ''b'', ''c'')',
      ('  ' + $S + $E + '@($cmds | Where-Object { $_ })'),
      ('  ' + $S + 'Calls' + $E + '@($cmds | Where-Object { $_ })'),
      ('  [pscustomobject]@{ Shadow = ' + $S + '.Count; Local = ' + $S + 'Calls.Count }'),
      '}')
    $r = Get-TpsFindings -Source $fxTwin
    TpsT 'CLEAN TWIN  a differently named local beside the shadow is read as its own name: one finding, the shadow on line 3' (TpsOne $r 3) (TpsGot $r)
    TpsT 'CLEAN TWIN  ...and the denominators read it the same way: 3 assignments, 1 of them to a typed name' ($r.Assignments -eq 3 -and $r.Typed -eq 1) ("assignments={0} typed={1}" -f $r.Assignments, $r.Typed)
    . ([scriptblock]::Create($fxTwin))
    $probe = Get-TpsProbe -Rule 'x'
    TpsT 'MUST FIRE  the trap is real in this PowerShell: the shadow of [string]$Rule reads Count 1 over three rows' ($probe.Shadow -eq 1) ("shadow=" + $probe.Shadow)
    TpsT 'CLEAN TWIN  the differently named local in that same function holds all three rows' ($probe.Local -eq 3) ("local=" + $probe.Local)
    $r = Get-TpsFindings -Source ('function F([string]$Rule, [string]$Name) { ' + $S + $E + '$cmds | Where-Object { $_ }; $Na' + 'me' + $E + '''x'' }')
    TpsT 'CLEAN TWIN  a pipeline with no @() is counted UNJUDGED and a string into [string] LEGAL, so the gap is printed rather than passed' ($r.Unjudged -eq 1 -and $r.Legal -eq 1 -and $r.Typed -eq 2) ("typed={0} legal={1} unjudged={2}" -f $r.Typed, $r.Legal, $r.Unjudged)

    # ---- the baseline comparison ------------------------------------------------------------------------------
    $cmp = Compare-TpsSites -Now @('a', 'c') -Known @('a', 'b')
    TpsT 'MUST FIRE  a site swapped for a new one at the SAME count is still a new site' (@($cmp.New).Count -eq 1 -and @($cmp.New)[0] -eq 'c' -and @($cmp.Gone)[0] -eq 'b') ("new={0} gone={1}" -f (@($cmp.New) -join ','), (@($cmp.Gone) -join ','))
    $cmp = Compare-TpsSites -Now @('a', 'a') -Known @('a')
    TpsT 'MUST FIRE  a second copy of a known site is new' (@($cmp.New).Count -eq 1) ("new=" + @($cmp.New).Count)
    $cmp = Compare-TpsSites -Now @('a') -Known @('a', 'b')
    TpsT 'CLEAN TWIN  a fall names the site that went' (@($cmp.New).Count -eq 0 -and @($cmp.Gone).Count -eq 1 -and @($cmp.Gone)[0] -eq 'b') ("gone=" + (@($cmp.Gone) -join ','))

    # ---- THE WALK, FROM A WORKTREE ROOT (lib\tree-walk.ps1) ------------------------------------------------------
    $wtFx = New-TcWorktreeFixture -Files @{ 'ops\a.ps1' = 'Write-Output 1'; 'grocery\b.ps1' = 'Write-Output 2'
                                            'grocery\out\scratch.ps1' = 'Write-Output 3'; 'ops\me.ps1' = 'Write-Output 4' }
    try {
      $self = Join-Path $wtFx.Root 'ops\me.ps1'
      $wtFound = @(Get-TpsScanFiles -RootDir $wtFx.Root -Self $self)
      $wtHits = Measure-TcWorktreeFixture -Fixture $wtFx -Found $wtFound
      TpsT 'MUST FIRE  a root that IS a worktree is scanned, not excluded whole (two .ps1, no \out\, not itself)' ($wtHits.Root -eq 2) ('root=' + $wtHits.Root)
      TpsT 'MUST NOT FIRE  a sibling worktree BELOW that root is still excluded' ($wtHits.Sibling -eq 0) ('sibling=' + $wtHits.Sibling)
      TpsT 'MUST NOT FIRE  the detector never scans itself' (@($wtFound | Where-Object { $_.FullName -eq $self }).Count -eq 0) ''
    } finally { Remove-Item -LiteralPath $wtFx.Temp -Recurse -Force -ErrorAction SilentlyContinue }

    # ---- THE LIVE PATH, DRIVEN: this script as a child against a one-site temp tree and a temp baseline ------------
    # One directory per run, removed in finally, because concurrent pushes run this suite in the same %TEMP%.
    $tmp = Join-Path $env:TEMP ('tps-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $tmp -ErrorAction Stop | Out-Null
    try {
      $tree = Join-Path $tmp 'tree'
      New-Item -ItemType Directory -Path (Join-Path $tree 'ops') -Force -ErrorAction Stop | Out-Null
      [IO.File]::WriteAllText((Join-Path $tree 'ops\site.ps1'), $fxFounding, (New-Object Text.UTF8Encoding($false)))
      $liveRel = 'ops\site.ps1'
      $liveKey = Get-TpsSiteKey -Rel $liveRel -Finding (Get-TpsFindings -Source $fxFounding).Findings[0]
      $psexe = Join-Path $PSHOME 'powershell.exe'
      function TpsSeed([string]$Path, [int]$Sites, [string[]]$Names) {
        $null = Write-TcLfFile -Path $Path -Text ([ordered]@{ note = 'fixture'; generated = '2026-01-01T00:00:00'; sites = $Sites; names = @($Names); history = @() } | ConvertTo-Json -Depth 4) -NoBom
      }
      function TpsChild([string]$TreeRoot, [string[]]$Extra) {
        # No 2>&1: under Stop, PS 5.1 wraps a native child's stderr in an ErrorRecord and throws at exit 0.
        $o = @(& $psexe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $TreeRoot @Extra)
        $rc = $LASTEXITCODE
        $o = @($o | ForEach-Object { [string]$_ })
        return [pscustomobject]@{ Rc = $rc; Out = $o; Last = $(if ($o.Count) { $o[$o.Count - 1] } else { '' }) }
      }

      $blFall = Join-Path $tmp 'fall.json'
      TpsSeed $blFall 2 @($liveKey, 'ops\gone.ps1 :: [string]$X <- array :: $x = @()')
      $before = [Convert]::ToBase64String([IO.File]::ReadAllBytes($blFall))
      $c1 = TpsChild $tree @('-BaselineFile', $blFall)
      $same = [string]::Equals($before, [Convert]::ToBase64String([IO.File]::ReadAllBytes($blFall)), [StringComparison]::Ordinal)
      TpsT 'CLEAN TWIN  a FALL without -Tighten passes, names the site that went, and leaves the baseline bytes as they were' ($c1.Rc -eq 0 -and $same -and (($c1.Out -join "`n") -match 'CAN tighten') -and (($c1.Out -join "`n") -like '*gone.ps1*')) ("rc={0} same={1}" -f $c1.Rc, $same)
      TpsT 'CLEAN TWIN  ...and its last line is the completion marker' ($c1.Last -like 'AUDIT-TYPED-PARAM-SHADOW-COMPLETE*') $c1.Last

      $c2 = TpsChild $tree @('-BaselineFile', $blFall, '-Tighten')
      $b2 = [IO.File]::ReadAllBytes($blFall)
      $cr = 0; foreach ($x in $b2) { if ($x -eq 13) { $cr++ } }
      $doc2 = [Text.Encoding]::UTF8.GetString($b2) | ConvertFrom-Json
      TpsT 'CLEAN TWIN  -Tighten records the fall in the bytes git stores: no CR, one trailing LF, sites 1, the live site named' ($c2.Rc -eq 0 -and $cr -eq 0 -and $b2[-1] -eq 10 -and [int]$doc2.sites -eq 1 -and @($doc2.names)[0] -eq $liveKey) ("rc={0} cr={1} sites={2}" -f $c2.Rc, $cr, $doc2.sites)

      $blSwap = Join-Path $tmp 'swap.json'
      TpsSeed $blSwap 1 @('ops\other.ps1 :: [string]$X <- array :: $x = @()')
      $c3 = TpsChild $tree @('-BaselineFile', $blSwap)
      TpsT 'MUST FIRE  a new site at an UNCHANGED count exits 2 and names it' ($c3.Rc -eq 2 -and (($c3.Out -join "`n") -like '*ops\site.ps1*')) ("rc=" + $c3.Rc)

      $c4 = TpsChild $tree @('-BaselineFile', (Join-Path $tmp 'absent.json'))
      TpsT 'MUST FIRE  no baseline and no -Tighten is could-not-evaluate, exit 3, never a pass' ($c4.Rc -eq 3 -and -not (Test-Path -LiteralPath (Join-Path $tmp 'absent.json'))) ("rc=" + $c4.Rc)

      # THE FLOOR. A tree that declares typed parameters and assigns their names, yet yields no assignment the scope
      # resolver owns, is what this file's first cut read over the real tree - and every ratchet verdict after it
      # would have been a pass. Here the only assignment is in a child scope, so the resolver rightly owns none.
      $tree2 = Join-Path $tmp 'tree2'
      New-Item -ItemType Directory -Path (Join-Path $tree2 'ops') -Force -ErrorAction Stop | Out-Null
      [IO.File]::WriteAllText((Join-Path $tree2 'ops\child.ps1'), ('function F([string]$Rule) { & { ' + $S + $E + '@(1, 2) } }'), (New-Object Text.UTF8Encoding($false)))
      $c5 = TpsChild $tree2 @('-BaselineFile', $blSwap)
      TpsT 'MUST FIRE  parsed files that yield NO assignment to a typed parameter''s name are BLIND, exit 3, whatever the baseline says' ($c5.Rc -eq 3 -and (($c5.Out -join "`n") -like '*BLIND*')) ("rc=" + $c5.Rc)
    } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
  } catch {
    $script:cases++; $script:fail++
    Write-Output ('  FAIL  the self-test threw: ' + $_.Exception.Message + ' at line ' + $_.InvocationInfo.ScriptLineNumber)
  }

  if ($script:fail) { Write-Output ("TYPED-PARAM-SHADOW SELF-TEST FAILED ({0} of {1} case(s))" -f $script:fail, $script:cases); exit 2 }
  Write-Output ("TYPED-PARAM-SHADOW SELF-TEST PASSED ({0} case(s): both founding shapes and the live site fire, every value kind and shared scope fires, same-kind and child-scope assignments stay silent, the walk reads a worktree root, and the live path writes only under -Tighten)" -f $script:cases)
  exit 0
}

# ------------------------------------------------------------------------------------------------------ live run
$scanRoot = if ($Root) { $Root } else { $repo }
$blPath = if ($BaselineFile) { $BaselineFile } else { Join-Path $repo 'ops\typed-param-shadow-baseline.json' }
# NEVER SCAN YOURSELF. The self-test's fixtures are strings and concatenated, but a detector that relies on that is
# one refactor from reporting itself.
$files = @(Get-TpsScanFiles -RootDir $scanRoot -Self $PSCommandPath)
if (-not $files.Count) {
  Write-Output 'TYPED-PARAM-SHADOW AUDIT BLIND: resolved zero .ps1 files, which means the discovery is broken rather than the tree being clean.'
  Exit-Guard -Name $script:TPS_GUARD -Summary 'blind=no-files' -Code 3
}
$rootFull = Get-TcRootFull $scanRoot
$keys = New-Object System.Collections.ArrayList
$shown = New-Object System.Collections.ArrayList
$read = 0; $parseErrorFiles = 0; $assignments = 0; $typed = 0; $legal = 0; $unjudged = 0
foreach ($f in $files) {
  $r = Get-TpsFindings -Source ([IO.File]::ReadAllText($f.FullName))
  if (-not $r.Read) { continue }
  $read++
  if ($r.ParseErrors) { $parseErrorFiles++ }
  $assignments += $r.Assignments; $typed += $r.Typed; $legal += $r.Legal; $unjudged += $r.Unjudged
  $rel = (Get-TcPathBelowRoot $f.FullName $rootFull).TrimStart('\')
  foreach ($h in @($r.Findings)) {
    [void]$keys.Add((Get-TpsSiteKey -Rel $rel -Finding $h))
    [void]$shown.Add(("{0}:{1}  {2} <- {3}: {4}  |  {5}" -f $rel, $h.Line, $h.Param, $h.Kind, $h.Effect, $h.Text))
  }
}
$count = $keys.Count
Write-Output ("typed-param-shadow: resolved {0} .ps1 file(s); {1} declare a judged type under a name they also assign and were parsed ({2} with a parse error), holding {3} assignment(s). {4} assign a typed parameter's name: {5} change its kind (reported), {6} provably keep it, {7} of a kind this cannot see (UNJUDGED, not passed)." -f $files.Count, $read, $parseErrorFiles, $assignments, $typed, $count, $legal, $unjudged)
foreach ($s in $shown) { Write-Output ('  shadow  ' + $s) }
$summary = "files={0} read={1} assignments={2} typed={3} sites={4} unjudged={5}" -f $files.Count, $read, $assignments, $typed, $count, $unjudged
# A FLOOR, because every other verdict here is an upper bound and cannot fire on a resolver that stopped seeing.
if ($read -gt 0 -and $typed -eq 0) {
  Write-Output ("TYPED-PARAM-SHADOW AUDIT BLIND: parsed {0} file(s) that declare typed parameters and assign their names, and resolved NOT ONE assignment to a typed parameter's name. The census this shipped from found 507. That is the scope resolver broken, not the tree clean." -f $read)
  Exit-Guard -Name $script:TPS_GUARD -Summary ("{0} blind=no-typed-assignments" -f $summary) -Code 3
}

if (-not (Test-Path -LiteralPath $blPath)) {
  if ($Tighten) {
    $null = Write-TpsBaseline -Path $blPath -Count $count -Names $keys.ToArray() -PriorDoc $null
    Write-Output ("typed-param-shadow: baseline written at {0} site(s) - commit it. From here the number may only go DOWN." -f $count)
    Exit-Guard -Name $script:TPS_GUARD -Summary ("{0} baseline-written={1}" -f $summary, $count) -Code 0
  }
  Write-Output ("TYPED-PARAM-SHADOW AUDIT CANNOT EVALUATE: no baseline at {0}. Run with -Tighten once and commit it; a missing baseline is never a pass." -f $blPath)
  Exit-Guard -Name $script:TPS_GUARD -Summary ("{0} no-baseline" -f $summary) -Code 3
}
$baseDoc = $null
try { $baseDoc = [IO.File]::ReadAllText($blPath) | ConvertFrom-Json } catch { $baseDoc = $null }
if ($null -eq $baseDoc -or $null -eq $baseDoc.PSObject.Properties['sites']) {
  Write-Output ("TYPED-PARAM-SHADOW AUDIT CANNOT EVALUATE: the baseline at {0} is unreadable or has no sites field." -f $blPath)
  Exit-Guard -Name $script:TPS_GUARD -Summary ("{0} baseline-unreadable" -f $summary) -Code 3
}
$base = [int]$baseDoc.sites
$knownNames = @()
if ($baseDoc.PSObject.Properties['names'] -and $null -ne $baseDoc.names) { $knownNames = @($baseDoc.names) }
$cmp = Compare-TpsSites -Now $keys.ToArray() -Known $knownNames

if ($count -gt $base -or @($cmp.New).Count) {
  Write-Output ("TYPED-PARAM-SHADOW AUDIT FAILED: {0} site(s) against a baseline of {1}, and {2} the baseline does not name:" -f $count, $base, @($cmp.New).Count)
  foreach ($k in @($cmp.New)) { Write-Output ('  NEW  ' + $k) }
  Write-Output '  A parameter declared with a type keeps that type for its whole scope, and variable names are case-insensitive,'
  Write-Output '  so this assignment converts the value rather than making a new variable. Give the local its own name'
  Write-Output '  ($ruleCalls, not $rule, beside [string]$Rule). If the parameter really should take the value, declare it untyped.'
  Exit-Guard -Name $script:TPS_GUARD -Summary ("{0} baseline={1} new={2}" -f $summary, $base, @($cmp.New).Count) -Code 2
}
if ($count -lt $base) {
  foreach ($k in @($cmp.Gone)) { Write-Output ('  gone  ' + $k) }
  $move = Test-RatchetMove -Name 'typed-param-shadow' -Count $count -Baseline $base -AcceptDrop:$AcceptDrop
  if ($move.Verdict -eq 'implausible') {
    Write-Output ('  ' + $move.Message)
    if ($Tighten) { Exit-Guard -Name $script:TPS_GUARD -Summary ("{0} baseline={1} refused-to-lower" -f $summary, $base) -Code 2 }
  } elseif ($Tighten) {
    $null = Write-TpsBaseline -Path $blPath -Count $count -Names $keys.ToArray() -PriorDoc $baseDoc
    Write-Output ('PASSED and TIGHTENED - ' + $move.Message + ' Commit the baseline, or it protects only this checkout.')
    Exit-Guard -Name $script:TPS_GUARD -Summary ("{0} tightened-from={1}" -f $summary, $base) -Code 0
  } else {
    Write-Output ("  ratchet CAN tighten: {0} site(s), baseline {1}. NOT written: this may be a pre-push gate, and a rewrite here dirties the checkout being pushed without riding the push. Record it with -Tighten and commit the baseline." -f $count, $base)
  }
}
Write-Output ("typed-param-shadow: PASSED - {0} known site(s) against a baseline of {1}. Each one given its own name lowers the mark for good." -f $count, $base)
Exit-Guard -Name $script:TPS_GUARD -Summary ("{0} baseline={1}" -f $summary, $base) -Code 0
