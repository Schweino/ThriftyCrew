<#
  audit-full-path-excludes.ps1 - a tree walk excludes on the path BELOW its root, never on the full path.

  SCOPE OF A CLEAN REPORT: UNSOUND. It reads the PowerShell AST and Python text and finds the spellings
    listed under WHAT IT SEES. A clean report means none of those spellings is present. A full path reached
    another way - read from a file, set in another script, tested in a switch -regex, a pathlib .parts
    check - is invisible to it. A reported site is real; silence is not proof. It is a RATCHET rather than
    a gate for the reason every ratchet here gives: the count it measured on its first day is not zero.

  WHY THIS EXISTS (2026-09-11). Nineteen walks in seventeen files excluded \worktrees\, two of them
  \.claude\ as well, by matching the FULL path of every file they found. A linked worktree lives at
  <main>\.claude\worktrees\<name>, so from one every path matched and the walk excluded the tree it was
  asked to read: twelve of fourteen ops detectors exited 3, run-gates' Python discovery found no suites,
  and audit-twin-drift printed a clean count over nothing. It was recorded on 2026-08-26 and left standing
  for two weeks. Commit e1afb523b routed the walks through lib\tree-walk.ps1, and
  .claude\rules\ops-and-gates.md states the convention. A rule in a file reaches whoever opens the file.
  This reaches the next walk at push time.

  THE TWO FOUNDING LINES, both frozen verbatim in the self-test:
    ops\audit-git-sweepers.ps1  a Where-Object testing $_.FullName with -notmatch against a \worktrees\ pattern
    ops\audit-arg-binding.ps1   $p held $f.FullName, and a loop tested $p with -like against each entry of a
                                skip list that carried \.claude\ and \worktrees\
  The second is why the PowerShell half reads the AST and not the line: neither the path nor the pattern
  is spelled on the line that compares them.

  WHAT IT SEES, POWERSHELL (from the AST, so comments and quoted prose are never code):
    * -match / -notmatch / -like / -notlike, any case variant, with a FULL PATH on the left and a pattern
      CARRYING worktrees or .claude on the right
    * .Contains() / .IndexOf() / .LastIndexOf() on a full path with such an argument
    * [regex]::IsMatch / Match / Matches with a full path and such a pattern
    * -contains / -in against a -split or .Split() of a full path
    * Where-Object FullName -NotMatch '...', the simplified syntax
  A FULL PATH is .FullName, .DirectoryName or .PSPath read off anything, or a variable assigned one (or a
  foreach variable over one), through parens, casts, + and the case and trim calls. It STOPS being one at
  any command call, .Substring() or .Replace() - which is exactly how the two fixed forms spell the path
  below the root: Get-TcPathBelowRoot, and count-source-lifters' own Substring($rootFull.Length).
  A pattern CARRIES the needle when it holds a string literal matching it, or a variable assigned one (or a
  foreach variable over such a list), followed to a fixpoint within the file. Nested scriptblocks are not
  searched for it, so a pipeline that merely FILTERS with such a pattern does not make its result one.

  WHAT IT SEES, PYTHON (text, with docstrings and # comments blanked, line numbers kept). Only in a file
  that walks: `any(s in <expr> for s in <X>)` and `'...worktrees...' in <expr>`, where <expr> names an
  os.walk root, a glob/rglob loop variable, or a name built from one, never through relpath, relative_to or
  basename; and <X> is a literal carrying the needle or a name assigned one.

  WHAT IT DELIBERATELY DOES NOT FLAG. `$PSScriptRoot -like '*\.claude\worktrees\*'` asks WHERE THE SCRIPT
  IS RUNNING, which is a question and not an exclusion, so only a file's own path counts as a full path.
  A pruning of directory NAMES (`dirs[:] = [d for d in dirs if d not in ('worktrees',)]`) is already
  below the root. And \out\ is not walked: gitignored scratch lands there in the main checkout, and a
  ratchet that counts untracked files reads differently in every checkout.

  THE RATCHET, MEASURED 2026-09-11 at 930195deb through this file, from a linked worktree: 685 files
  resolved (559 .ps1, 126 .py), 43 read closely, 6 sites. Two were fixture lines e1afb523b itself added to
  the self-tests of audit-arg-binding and audit-source-comment-strip, selecting a nested worktree by FULL
  path. They were rewritten below the root in the same change, and they are the argument for a block over
  a rule: the commit that wrote the rule reintroduced the shape the same day. The mark starts at the 4 left:
    ops\probe-detector-health.py       any(s in low for s in SKIP)
    ops\probe-detector-gate-claims.py  any(s in low for s in SKIP)
    ops\probe-queue2-triage.py         any(x in root for x in (... 'worktrees' ...)), twice
  LEFT AS RUN, ON PURPOSE. They hardcode REPO to the main checkout, so they read main from anywhere and are
  not blind; and backlog I29 and the I8-I27 triage name them as the harness behind recorded conclusions, so
  editing them would leave those verdicts unqualified (.claude\rules\measurement.md). Retire them, or move
  them to relpath when they are next run for real, and the mark falls.

  EXIT CODES (lib\guard-contract.ps1 vocabulary): 0 at or below the high-water mark, 2 the mark rose or a
  fall was refused as implausible, 3 could not evaluate. Read the verdict LINE, not the number.

    ops\audit-full-path-excludes.ps1               scan the tree, hold the ratchet
    ops\audit-full-path-excludes.ps1 -AcceptDrop   record a fall lib\ratchet.ps1 would refuse
    ops\audit-full-path-excludes.ps1 -SelfTest     frozen founding lines, the fixed forms, the walk
#>
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop (2026-09-07)
param([switch]$SelfTest, [switch]$AcceptDrop)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\ratchet.ps1')
. (Join-Path $repo 'lib\tree-walk.ps1')   # Get-TcPathBelowRoot: this file's own walk obeys the rule it enforces

$BASELINE_FILE = Join-Path $repo 'ops\full-path-excludes-baseline.json'

# THE NEEDLES ARE BUILT BY CONCATENATION, so no literal in this file carries the word it hunts for.
$script:FPE_NEEDLE_CORE = 'work' + 'trees|\.cla' + 'ude'
$script:FPE_NEEDLE = '(?i)' + $script:FPE_NEEDLE_CORE
$script:FPE_PY_LIT = '(?i)([''"])[^''"\n]*(?:' + $script:FPE_NEEDLE_CORE + ')[^''"\n]*\1'
$script:FPE_PY_RELATIVE = 'relpath\(|relative_to\(|basename\('
$script:FPE_WALK_EXCLUDE = '\\work' + 'trees\\|\\archive\\|\\out\\|node_modules|\\\.venv\\|\\venv\\|site-packages|\\\.git\\'
# Members whose value IS a file's full path, and calls that leave WHICH path a value is unchanged.
$script:FPE_FULL_MEMBERS = @('FullName', 'DirectoryName', 'PSPath')
$script:FPE_SAME_PATH_CALLS = @('ToLower', 'ToLowerInvariant', 'ToUpper', 'ToUpperInvariant', 'Trim', 'TrimEnd', 'TrimStart', 'ToString')

# ------------------------------------------------------------------------------------- PowerShell half
function Get-FpeVarName {
  <# 'EXCLUDE' for $EXCLUDE, $script:EXCLUDE or [string]$EXCLUDE; '' for anything that is not a variable. #>
  param($Node)
  $n = $Node
  while ($null -ne $n -and $n.GetType().Name -eq 'ConvertExpressionAst') { $n = $n.Child }
  if ($null -eq $n -or $n.GetType().Name -ne 'VariableExpressionAst') { return '' }
  return ([string]$n.VariablePath.UserPath -replace '^(script|global|local|private):', '')
}

function Get-FpeCore {
  <# Unwrap what does not change WHICH path a value is: a one-element pipeline, parens, casts, and the case
     and trim calls. Stops at anything else, including every command call. #>
  param($Node)
  $n = $Node
  for ($i = 0; $i -lt 64 -and $null -ne $n; $i++) {
    $t = $n.GetType().Name
    if ($t -eq 'PipelineAst' -and $n.PipelineElements.Count -eq 1) { $n = $n.PipelineElements[0] }
    elseif ($t -eq 'CommandExpressionAst') { $n = $n.Expression }
    elseif ($t -eq 'ParenExpressionAst') { $n = $n.Pipeline }
    elseif ($t -eq 'ConvertExpressionAst') { $n = $n.Child }
    elseif ($t -eq 'InvokeMemberExpressionAst' -and -not $n.Static -and
            $script:FPE_SAME_PATH_CALLS -contains [string]$n.Member.Value) { $n = $n.Expression }
    else { return $n }
  }
  return $n
}

function Test-FpeFullPath {
  <# Is this expression a file's FULL path? #>
  param($Node, $PathVars)
  $n = Get-FpeCore $Node
  if ($null -eq $n) { return $false }
  $t = $n.GetType().Name
  # EXACT type name: InvokeMemberExpressionAst derives from MemberExpressionAst, and .Substring() is one.
  if ($t -eq 'MemberExpressionAst') { return ($script:FPE_FULL_MEMBERS -contains [string]$n.Member.Value) }
  if ($t -eq 'VariableExpressionAst') { $v = Get-FpeVarName $n; return ($v -ne '' -and $PathVars.Contains($v)) }
  if ($t -eq 'BinaryExpressionAst' -and $n.Operator.ToString() -eq 'Plus') {
    return ((Test-FpeFullPath $n.Left $PathVars) -or (Test-FpeFullPath $n.Right $PathVars))
  }
  return $false
}

function Test-FpeSplitOfFullPath {
  <# ($full -split '\\') or $full.Split('\'): the segments of a full path, which carry worktrees just the same. #>
  param($Node, $PathVars)
  $n = Get-FpeCore $Node
  if ($null -eq $n) { return $false }
  $t = $n.GetType().Name
  if ($t -eq 'BinaryExpressionAst' -and $n.Operator.ToString() -match '^[IC]split$') { return (Test-FpeFullPath $n.Left $PathVars) }
  if ($t -eq 'InvokeMemberExpressionAst' -and [string]$n.Member.Value -eq 'Split') { return (Test-FpeFullPath $n.Expression $PathVars) }
  return $false
}

function Test-FpeCarriesNeedle {
  <# Does this expression carry worktrees or .claude - a string literal holding it, or a variable assigned
     one? Nested scriptblocks are NOT searched: a pipeline that filters with such a pattern does not make
     its RESULT a pattern. #>
  param($Node, $PatVars)
  if ($null -eq $Node) { return $false }
  $hits = $Node.FindAll({
      param($a)
      $tn = $a.GetType().Name
      if ($tn -eq 'StringConstantExpressionAst' -or $tn -eq 'ExpandableStringExpressionAst') { return ([string]$a.Value -match $script:FPE_NEEDLE) }
      if ($tn -eq 'VariableExpressionAst') { $v = Get-FpeVarName $a; return ($v -ne '' -and $PatVars.Contains($v)) }
      return $false
    }, $false)
  return (@($hits).Count -gt 0)
}

function Get-FpeTaint {
  <# The file's PATH variables (assigned a full path) and PATTERN variables (assigned a needle), to a fixpoint.
     File-wide and keyed by name, so a name reused for two things is treated as both. That over-approximates
     on purpose, and the self-test pins the forms that must stay silent. #>
  param($Ast)
  $pathVars = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  $patVars = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  $binds = New-Object System.Collections.ArrayList
  foreach ($a in $Ast.FindAll({ param($x) $x.GetType().Name -eq 'AssignmentStatementAst' }, $true)) {
    $nm = Get-FpeVarName $a.Left
    if ($nm) { [void]$binds.Add([pscustomobject]@{ Name = $nm; Value = $a.Right }) }
  }
  foreach ($l in $Ast.FindAll({ param($x) $x.GetType().Name -eq 'ForEachStatementAst' }, $true)) {
    $nm = Get-FpeVarName $l.Variable
    if ($nm) { [void]$binds.Add([pscustomobject]@{ Name = $nm; Value = $l.Condition }) }
  }
  foreach ($p in $Ast.FindAll({ param($x) $x.GetType().Name -eq 'ParameterAst' }, $true)) {
    if ($null -eq $p.DefaultValue) { continue }
    $nm = Get-FpeVarName $p.Name
    if ($nm) { [void]$binds.Add([pscustomobject]@{ Name = $nm; Value = $p.DefaultValue }) }
  }
  $changed = $true; $rounds = 0
  while ($changed -and $rounds -lt 16) {
    $changed = $false; $rounds++
    foreach ($b in $binds) {
      if (-not $patVars.Contains($b.Name) -and (Test-FpeCarriesNeedle $b.Value $patVars)) { [void]$patVars.Add($b.Name); $changed = $true }
      if (-not $pathVars.Contains($b.Name) -and (Test-FpeFullPath $b.Value $pathVars)) { [void]$pathVars.Add($b.Name); $changed = $true }
    }
  }
  return [pscustomobject]@{ PathVars = $pathVars; PatVars = $patVars }
}

function Get-FpePsFindings {
  <# Pure over one file's text, so the self-test drives exactly what the live scan runs.
     Returns @{ Findings = @({Line; Text}); ParseErrors; Read }. Read is false when the file cannot hold a
     finding at all - no needle and no path member anywhere in it - and was never parsed. #>
  param([string]$Text)
  $none = [pscustomobject]@{ Findings = @(); ParseErrors = 0; Read = $false }
  if ($null -eq $Text -or $Text -notmatch $script:FPE_NEEDLE -or $Text -notmatch 'FullName|DirectoryName|PSPath') { return $none }
  $tok = $null; $err = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tok, [ref]$err)
  if ($null -eq $ast) { return $none }
  $taint = Get-FpeTaint $ast
  $pv = $taint.PathVars; $tv = $taint.PatVars
  $src = ($Text -replace "`r", '') -split "`n"
  $out = New-Object System.Collections.ArrayList
  $seen = New-Object 'System.Collections.Generic.HashSet[int]'
  $nodes = $ast.FindAll({ param($x) $k = $x.GetType().Name; $k -eq 'BinaryExpressionAst' -or $k -eq 'InvokeMemberExpressionAst' -or $k -eq 'CommandAst' }, $true)
  foreach ($n in $nodes) {
    $hit = $false
    $kind = $n.GetType().Name
    if ($kind -eq 'BinaryExpressionAst') {
      $op = $n.Operator.ToString()
      if ($op -match '^[IC](not)?(match|like)$') { $hit = (Test-FpeFullPath $n.Left $pv) -and (Test-FpeCarriesNeedle $n.Right $tv) }
      elseif ($op -match '^[IC](not)?contains$') { $hit = (Test-FpeSplitOfFullPath $n.Left $pv) -and (Test-FpeCarriesNeedle $n.Right $tv) }
      elseif ($op -match '^[IC](not)?in$') { $hit = (Test-FpeSplitOfFullPath $n.Right $pv) -and (Test-FpeCarriesNeedle $n.Left $tv) }
    } elseif ($kind -eq 'InvokeMemberExpressionAst') {
      $m = [string]$n.Member.Value
      $args0 = @($n.Arguments)
      if ($n.Static) {
        if ($n.Expression.GetType().Name -eq 'TypeExpressionAst' -and [string]$n.Expression.TypeName.Name -match '(^|\.)regex$' -and
            @('IsMatch', 'Match', 'Matches') -contains $m -and $args0.Count -ge 2) {
          $hit = (Test-FpeFullPath $args0[0] $pv) -and (Test-FpeCarriesNeedle $args0[1] $tv)
        }
      } elseif (@('Contains', 'IndexOf', 'LastIndexOf') -contains $m -and $args0.Count -ge 1) {
        # StartsWith is left out on purpose: anchored at the root it is the CORRECT sibling exclusion.
        $hit = (Test-FpeFullPath $n.Expression $pv) -and (Test-FpeCarriesNeedle $args0[0] $tv)
      }
    } else {
      $cmd = $n.GetCommandName()
      $els = @($n.CommandElements)
      if ($cmd -and @('Where-Object', 'where', '?') -contains $cmd) {
        for ($k = 1; $k -lt $els.Count; $k++) {
          $e = $els[$k]
          if ($e.GetType().Name -ne 'CommandParameterAst' -or $e.ParameterName -notmatch '^[ic]?(not)?(match|like)$') { continue }
          $prev = $els[$k - 1]
          $arg = if ($null -ne $e.Argument) { $e.Argument } elseif ($k + 1 -lt $els.Count) { $els[$k + 1] } else { $null }
          if ($prev.GetType().Name -eq 'StringConstantExpressionAst' -and $script:FPE_FULL_MEMBERS -contains [string]$prev.Value -and
              (Test-FpeCarriesNeedle $arg $tv)) { $hit = $true }
        }
      }
    }
    if ($hit -and $seen.Add($n.Extent.StartOffset)) {
      $ln = $n.Extent.StartLineNumber
      [void]$out.Add([pscustomobject]@{ Line = $ln; Text = $src[$ln - 1].Trim() })
    }
  }
  return [pscustomobject]@{ Findings = $out.ToArray(); ParseErrors = @($err).Count; Read = $true }
}

# ----------------------------------------------------------------------------------------- Python half
function Remove-FpePyNoise {
  <# Blank triple-quoted strings and # comments, keeping every newline so line numbers survive. #>
  param([string]$Text)
  $t = $Text -replace "`r", ''
  $t = [regex]::Replace($t, '(?s)""".*?"""|''''''.*?''''''', { param($m) ($m.Value -replace '[^\n]', ' ') })
  $lines = $t -split "`n"
  for ($i = 0; $i -lt $lines.Count; $i++) {
    $s = $lines[$i]
    if ($s.IndexOf('#') -lt 0) { continue }
    $q = ''
    for ($j = 0; $j -lt $s.Length; $j++) {
      $c = [string]$s[$j]
      if ($q) { if ($c -eq '\') { $j++ } elseif ($c -eq $q) { $q = '' } }
      elseif ($c -eq "'" -or $c -eq '"') { $q = $c }
      elseif ($c -eq '#') { $lines[$i] = $s.Substring(0, $j); break }
    }
  }
  return ($lines -join "`n")
}

function Test-FpePyNamesAny {
  <# Does $Expr name any of $Names as a whole identifier (not as an attribute)? #>
  param([string]$Expr, $Names)
  foreach ($nm in $Names) { if ($Expr -match ('(?<![\w.])' + [regex]::Escape($nm) + '\b')) { return $true } }
  return $false
}

function Get-FpePyFindings {
  <# Same return shape as Get-FpePsFindings. Pure over one file's text. #>
  param([string]$Text)
  $none = [pscustomobject]@{ Findings = @(); ParseErrors = 0; Read = $false }
  if ($null -eq $Text -or $Text -notmatch $script:FPE_NEEDLE -or $Text -notmatch 'os\.walk\(|glob\(') { return $none }
  $code = Remove-FpePyNoise -Text $Text
  $lines = $code -split "`n"
  $src = ($Text -replace "`r", '') -split "`n"
  $roots = New-Object 'System.Collections.Generic.HashSet[string]'
  foreach ($m in [regex]::Matches($code, 'for\s+\(?\s*(\w+)\s*,\s*\w+\s*,\s*\w+\s*\)?\s+in\s+os\.walk\(')) { [void]$roots.Add($m.Groups[1].Value) }
  foreach ($m in [regex]::Matches($code, 'for\s+(\w+)\s+in\s+[^\n:]*\b(?:iglob|glob|rglob)\(')) { [void]$roots.Add($m.Groups[1].Value) }
  $read = [pscustomobject]@{ Findings = @(); ParseErrors = 0; Read = $true }
  if (-not $roots.Count) { return $read }
  $assigns = @([regex]::Matches($code, '(?m)^[ \t]*(\w+)[ \t]*=(?!=)[ \t]*(.*)$'))

  # Names built from a root, never through a relativising call.
  $changed = $true; $rounds = 0
  while ($changed -and $rounds -lt 16) {
    $changed = $false; $rounds++
    foreach ($a in $assigns) {
      $nm = $a.Groups[1].Value; $rhs = $a.Groups[2].Value
      if ($roots.Contains($nm) -or $rhs -match $script:FPE_PY_RELATIVE) { continue }
      if (Test-FpePyNamesAny -Expr $rhs -Names @($roots)) { [void]$roots.Add($nm); $changed = $true }
    }
  }
  # Names assigned a literal carrying the needle, following a bracketed value across its continuation lines.
  $pats = New-Object 'System.Collections.Generic.HashSet[string]'
  foreach ($a in $assigns) {
    $rhs = $a.Groups[2].Value
    $next = ($code.Substring(0, $a.Index) -split "`n").Count   # 0-based index of the line after this one
    $stop = $next + 40
    $depth = [regex]::Matches($rhs, '[\(\[\{]').Count - [regex]::Matches($rhs, '[\)\]\}]').Count
    while ($depth -gt 0 -and $next -lt $lines.Count -and $next -lt $stop) {
      $rhs += "`n" + $lines[$next]
      $depth += [regex]::Matches($lines[$next], '[\(\[\{]').Count - [regex]::Matches($lines[$next], '[\)\]\}]').Count
      $next++
    }
    if ($rhs -match $script:FPE_PY_LIT) { [void]$pats.Add($a.Groups[1].Value) }
  }

  $out = New-Object System.Collections.ArrayList
  $seen = New-Object 'System.Collections.Generic.HashSet[int]'
  foreach ($m in [regex]::Matches($code, 'any\(\s*(\w+)\s+in\s+([^\n]+?)\s+for\s+(\w+)\s+in\s+([^\n]+)')) {
    if ($m.Groups[1].Value -ne $m.Groups[3].Value) { continue }
    $expr = $m.Groups[2].Value; $over = $m.Groups[4].Value
    if ($expr -match $script:FPE_PY_RELATIVE -or -not (Test-FpePyNamesAny -Expr $expr -Names @($roots))) { continue }
    if (-not ($over -match $script:FPE_PY_LIT -or (Test-FpePyNamesAny -Expr $over -Names @($pats)))) { continue }
    $ln = ($code.Substring(0, $m.Index) -split "`n").Count
    if ($seen.Add($ln)) { [void]$out.Add([pscustomobject]@{ Line = $ln; Text = $src[$ln - 1].Trim() }) }
  }
  foreach ($m in [regex]::Matches($code, $script:FPE_PY_LIT + '[ \t]+(?:not[ \t]+)?in[ \t]+([^\n:]+)')) {
    $expr = ($m.Groups[2].Value -split '\s+(?:and|or|for|if)\s+|,')[0]
    if ($expr -match $script:FPE_PY_RELATIVE -or -not (Test-FpePyNamesAny -Expr $expr -Names @($roots))) { continue }
    $ln = ($code.Substring(0, $m.Index) -split "`n").Count
    if ($seen.Add($ln)) { [void]$out.Add([pscustomobject]@{ Line = $ln; Text = $src[$ln - 1].Trim() }) }
  }
  return [pscustomobject]@{ Findings = $out.ToArray(); ParseErrors = 0; Read = $true }
}

# --------------------------------------------------------------------------------------------- the walk
function Get-FpeScanFiles {
  <# Every .ps1 and .py under $RootDir, excluded on the path BELOW the root (lib\tree-walk.ps1) and never
     $Self. The rule this detector enforces, applied to its own walk. #>
  param([string]$RootDir, [string]$Self = '')
  $rootFull = Get-TcRootFull $RootDir
  Get-ChildItem -LiteralPath $rootFull -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { ($_.Extension -ieq '.ps1' -or $_.Extension -ieq '.py') -and
                   (Get-TcPathBelowRoot $_.FullName $rootFull) -notmatch $script:FPE_WALK_EXCLUDE -and
                   -not [string]::Equals($_.FullName, $Self, [StringComparison]::OrdinalIgnoreCase) } |
    Sort-Object FullName
}

# ------------------------------------------------------------------------------------------- self-test
if ($SelfTest) {
  $script:fail = 0; $script:cases = 0
  function FpeT([string]$m, [bool]$c, [string]$got = '') {
    $script:cases++
    if ($c) { Write-Output ('  ok    ' + $m) } else { Write-Output ('  FAIL  ' + $m + '   got: ' + $got); $script:fail++ }
  }
  function FpeGot($r) { return ('count=' + $r.Findings.Count + ' lines=' + (($r.Findings | ForEach-Object { $_.Line }) -join ',')) }

  # ---- MUST FIRE: the two founding lines, verbatim from e1afb523b^ -------------------------------------
  $fxSweepers = @(
    '$files = @(Get-ChildItem $repo -Recurse -File -ErrorAction SilentlyContinue |',
    '  Where-Object { $_.FullName -notmatch ''\\worktrees\\|\\archive\\|node_modules|\.venv|\\\.git\\'' } |',
    '  Sort-Object FullName)'
  ) -join "`n"
  $r = Get-FpePsFindings -Text $fxSweepers
  FpeT 'MUST FIRE  audit-git-sweepers before e1afb523b: $_.FullName -notmatch a \worktrees\ pattern, on line 2' ($r.Findings.Count -eq 1 -and $r.Findings[0].Line -eq 2) (FpeGot $r)

  $fxArgBinding = @(
    '$skipDirs = @(''\archive\'', ''\out\'', ''\.claude\'', ''\node_modules\'', ''\.git\'', ''\worktrees\'',',
    '              ''\.venv\'', ''\venv\'', ''\site-packages\'', ''\dist-info\'')',
    'foreach ($sub in @(''ops'', ''grocery'')) {',
    '  $d = Join-Path $Root $sub',
    '  if (-not (Test-Path $d)) { continue }',
    '  $files = @(Get-ChildItem $d -Recurse -Filter *.ps1 -File -ErrorAction SilentlyContinue)',
    '  foreach ($f in $files) {',
    '    $p = $f.FullName',
    '    $skip = $false',
    '    foreach ($sd in $skipDirs) { if ($p -like (''*'' + $sd + ''*'')) { $skip = $true; break } }',
    '    if ($skip) { continue }',
    '  }',
    '}'
  ) -join "`n"
  $r = Get-FpePsFindings -Text $fxArgBinding
  FpeT 'MUST FIRE  audit-arg-binding before e1afb523b: $p held FullName, $sd walked a list carrying \worktrees\, compared on line 10' ($r.Findings.Count -eq 1 -and $r.Findings[0].Line -eq 10) (FpeGot $r)

  # ---- MUST FIRE: the other spellings the header claims ------------------------------------------------
  $fxSeam = @(
    '$EXCLUDE = ''\\archive\\|\\worktrees\\|\\out\\|node_modules|\\lib\\ghost-lib\.ps1$''',
    '$files = @(Get-ChildItem $repo -Recurse -File -Filter *.ps1 |',
    '  Where-Object { $_.FullName -notmatch $EXCLUDE -and $_.FullName -ne $PSCommandPath } | ForEach-Object { $_.FullName })'
  ) -join "`n"
  $r = Get-FpePsFindings -Text $fxSeam
  FpeT 'MUST FIRE  the pattern held in a variable, as audit-write-seam spelled it before e1afb523b' ($r.Findings.Count -eq 1 -and $r.Findings[0].Line -eq 3) (FpeGot $r)

  $r = Get-FpePsFindings -Text 'foreach ($f in $files) { if ($f.FullName -like ''*\.claude\*'') { continue } }'
  FpeT 'MUST FIRE  \.claude\ alone is enough - every worktree path carries it' ($r.Findings.Count -eq 1) (FpeGot $r)
  $r = Get-FpePsFindings -Text '$keep = @($all | Where-Object { -not $_.FullName.ToLower().Contains(''\worktrees\'') })'
  FpeT 'MUST FIRE  .Contains() on a lower-cased full path' ($r.Findings.Count -eq 1) (FpeGot $r)
  $r = Get-FpePsFindings -Text '$keep = Get-ChildItem $root -Recurse -File | Where-Object FullName -NotMatch ''\\worktrees\\'''
  FpeT 'MUST FIRE  Where-Object FullName -NotMatch, the simplified syntax' ($r.Findings.Count -eq 1) (FpeGot $r)
  $r = Get-FpePsFindings -Text 'if ([regex]::IsMatch($f.FullName, ''\\worktrees\\'')) { continue }'
  FpeT 'MUST FIRE  [regex]::IsMatch over a full path' ($r.Findings.Count -eq 1) (FpeGot $r)
  $r = Get-FpePsFindings -Text 'if ($f.FullName -split ''\\'' -contains ''worktrees'') { continue }'
  FpeT 'MUST FIRE  -contains over the segments of a full path' ($r.Findings.Count -eq 1) (FpeGot $r)
  # Added after a mutation probe: with the + rule removed every other case stayed green. This is the PowerShell
  # twin of probe-detector-health's (root + '\\').lower().
  $r = Get-FpePsFindings -Text 'foreach ($f in $files) { if (($f.FullName + ''\'') -like ''*\worktrees\*'') { continue } }'
  FpeT 'MUST FIRE  a full path carried through + (a trailing backslash appended before the match)' ($r.Findings.Count -eq 1) (FpeGot $r)
  $r = Get-FpePsFindings -Text 'param([string]$Skip = ''\\worktrees\\'')
Get-ChildItem . -Recurse | Where-Object { $_.DirectoryName -notmatch $Skip }'
  FpeT 'MUST FIRE  a parameter default carrying the needle, against .DirectoryName' ($r.Findings.Count -eq 1 -and $r.Findings[0].Line -eq 2) (FpeGot $r)

  # ---- MUST FIRE: the Python leftovers, verbatim from ops\probe-detector-health.py and probe-queue2-triage.py
  $fxPyHealth = @(
    'SKIP = (''\\archive\\'', ''\\.venv\\'', ''\\worktrees\\'', ''\\node_modules\\'', ''\\out\\'', ''\\one-off\\'')',
    '',
    'DETECTORS = []',
    'for root, dirs, files in os.walk(REPO):',
    '    low = (root + ''\\'').lower()',
    '    if any(s in low for s in SKIP):',
    '        continue'
  ) -join "`n"
  $r = Get-FpePyFindings -Text $fxPyHealth
  FpeT 'MUST FIRE  Python: any(s in low for s in SKIP), low built from the os.walk root, on line 6' ($r.Findings.Count -eq 1 -and $r.Findings[0].Line -eq 6) (FpeGot $r)
  $fxPyTriage = @(
    'for root, dirs, files in os.walk(REPO):',
    '    if any(x in root for x in (''.venv'', ''node_modules'', ''.git'', ''worktrees'', ''archive'')):',
    '        continue'
  ) -join "`n"
  $r = Get-FpePyFindings -Text $fxPyTriage
  FpeT 'MUST FIRE  Python: any(x in root for x in a literal tuple carrying worktrees)' ($r.Findings.Count -eq 1 -and $r.Findings[0].Line -eq 2) (FpeGot $r)
  $r = Get-FpePyFindings -Text ((@('for dirpath, _, names in os.walk(ROOT):', '    if ''worktrees'' in dirpath:', '        continue')) -join "`n")
  FpeT 'MUST FIRE  Python: a literal tested with in against the os.walk root' ($r.Findings.Count -eq 1 -and $r.Findings[0].Line -eq 2) (FpeGot $r)

  # ---- MUST NOT FIRE: the fixed forms, verbatim from the tree today --------------------------------------
  $fxFixed = @(
    '  $rootFull = Get-TcRootFull $RootDir',
    '  $exts = @(''.ps1'', ''.yml'', ''.yaml'', ''.sh'', ''.py'')',
    '  Get-ChildItem $rootFull -Recurse -File -ErrorAction SilentlyContinue |',
    '    Where-Object { $exts -contains $_.Extension.ToLower() } |',
    '    Where-Object { (Get-TcPathBelowRoot $_.FullName $rootFull) -notmatch ''\\worktrees\\|\\archive\\|node_modules|\.venv|\\\.git\\'' } |',
    '    Sort-Object FullName'
  ) -join "`n"
  $r = Get-FpePsFindings -Text $fxFixed
  FpeT 'MUST NOT FIRE  the Get-TcPathBelowRoot form (audit-git-sweepers today)' ($r.Findings.Count -eq 0) (FpeGot $r)
  FpeT 'MUST FIRE  ...and that fixture WAS parsed, so its silence is a verdict and not a skipped file' ($r.Read) ('read=' + $r.Read)

  $fxSubstring = @(
    '  $rootFull = (Resolve-Path -LiteralPath $RootDir).ProviderPath.TrimEnd(''\'')',
    '  $files = @(Get-ChildItem -LiteralPath $rootFull -Filter *.ps1 -Recurse -File -ErrorAction SilentlyContinue |',
    '             Where-Object {',
    '               $_.Extension -eq ''.ps1'' -and',
    '               $_.FullName.Substring($rootFull.Length).TrimStart(''\'') -notmatch ''(^|\\)(\.git|archive|node_modules|worktrees)\\'' })'
  ) -join "`n"
  $r = Get-FpePsFindings -Text $fxSubstring
  FpeT 'MUST NOT FIRE  the Substring($rootFull.Length) form (count-source-lifters today)' ($r.Findings.Count -eq 0 -and $r.Read) (FpeGot $r)

  $fxLoopFixed = @(
    '  $skipDirs = @(''\archive\'', ''\out\'', ''\.claude\'', ''\node_modules\'', ''\.git\'', ''\worktrees\'',',
    '                ''\.venv\'', ''\venv\'', ''\site-packages\'', ''\dist-info\'')',
    '  foreach ($sub in @(''ops'', ''grocery'', ''lib'', ''meal-prep'')) {',
    '    $d = Join-Path $rootFull $sub',
    '    foreach ($f in @(Get-ChildItem $d -Recurse -Filter *.ps1 -File -ErrorAction SilentlyContinue)) {',
    '      $below = Get-TcPathBelowRoot $f.FullName $rootFull',
    '      $skip = $false',
    '      foreach ($sd in $skipDirs) { if ($below -like (''*'' + $sd + ''*'')) { $skip = $true; break } }',
    '    }',
    '  }'
  ) -join "`n"
  $r = Get-FpePsFindings -Text $fxLoopFixed
  FpeT 'MUST NOT FIRE  the same skip loop over Get-TcPathBelowRoot (audit-source-comment-strip today)' ($r.Findings.Count -eq 0 -and $r.Read) (FpeGot $r)

  $r = Get-FpePsFindings -Text 'Get-ChildItem . -Recurse | Where-Object { $_.FullName -notmatch ''\\archive\\|node_modules|\\out\\'' }'
  FpeT 'MUST NOT FIRE  a full path against a pattern with neither worktrees nor .claude' ($r.Findings.Count -eq 0) (FpeGot $r)
  $fxProse = @(
    '# was: Where-Object { $_.FullName -notmatch ''\\worktrees\\'' }',
    'Write-Output ''Where-Object { $_.FullName -notmatch ''''\\worktrees\\'''' }'''
  ) -join "`n"
  $r = Get-FpePsFindings -Text $fxProse
  FpeT 'MUST NOT FIRE  the founding line quoted in a comment and in a string' ($r.Findings.Count -eq 0) (FpeGot $r)
  $r = Get-FpePsFindings -Text 'if ($PSScriptRoot -like ''*\.claude\worktrees\*'') { $inWorktree = $true }; $x = $f.FullName'
  FpeT 'MUST NOT FIRE  asking where the script runs is a question, not an exclusion' ($r.Findings.Count -eq 0) (FpeGot $r)
  $r = Get-FpePsFindings -Text '$files = @(Get-ChildItem . -Recurse | Where-Object { (Get-TcPathBelowRoot $_.FullName $rf) -notmatch ''\\worktrees\\'' }); $files | Where-Object { $_.FullName -match $files }'
  FpeT 'MUST NOT FIRE  a pipeline that FILTERS with the needle does not make its result a pattern' ($r.Findings.Count -eq 0) (FpeGot $r)

  $fxPyRel = @(
    'SKIP = (''\\worktrees\\'', ''\\archive\\'')',
    'for root, dirs, files in os.walk(REPO):',
    '    rel = ''\\'' + os.path.relpath(root, REPO) + ''\\''',
    '    if any(s in rel.lower() for s in SKIP):',
    '        continue'
  ) -join "`n"
  $r = Get-FpePyFindings -Text $fxPyRel
  FpeT 'MUST NOT FIRE  Python: the same any() over os.path.relpath(root, REPO)' ($r.Findings.Count -eq 0 -and $r.Read) (FpeGot $r)
  $r = Get-FpePyFindings -Text ((@('for root, dirs, files in os.walk(REPO):', '    dirs[:] = [d for d in dirs if d not in (''worktrees'', ''.git'')]  # prune by NAME')) -join "`n")
  FpeT 'MUST NOT FIRE  Python: pruning directory NAMES is already below the root' ($r.Findings.Count -eq 0) (FpeGot $r)
  $r = Get-FpePyFindings -Text ((@('"""Old code: if any(s in root for s in (''worktrees'',)): continue"""', 'for root, dirs, files in os.walk(REPO):', '    pass  # any(s in root for s in (''worktrees'',))')) -join "`n")
  FpeT 'MUST NOT FIRE  Python: the shape quoted in a docstring and a comment' ($r.Findings.Count -eq 0) (FpeGot $r)

  # ---- CLEAN TWIN: the adjacent behaviour the exemptions were most likely to break ------------------------
  $fxMixed = @(
    '$a = @(Get-ChildItem $root -Recurse -File | Where-Object { (Get-TcPathBelowRoot $_.FullName $rf) -notmatch ''\\worktrees\\'' })',
    '$b = @(Get-ChildItem $root -Recurse -File | Where-Object { $_.FullName -notmatch ''\\worktrees\\'' })'
  ) -join "`n"
  $r = Get-FpePsFindings -Text $fxMixed
  FpeT 'CLEAN TWIN  a fixed walk beside a founding one in the same file still reports the founding one, on line 2' ($r.Findings.Count -eq 1 -and $r.Findings[0].Line -eq 2) (FpeGot $r)
  $r = Get-FpePyFindings -Text ($fxPyRel + "`n" + $fxPyTriage)
  FpeT 'CLEAN TWIN  Python: a relpath walk beside a full-path walk still reports the full-path one, on line 7' ($r.Findings.Count -eq 1 -and $r.Findings[0].Line -eq 7) (FpeGot $r)

  # ---- THE WALK, FROM A WORKTREE ROOT (lib\tree-walk.ps1) -------------------------------------------------
  $wtFx = New-TcWorktreeFixture -Files @{ 'ops\a.ps1' = 'Write-Output 1'; 'sidecar\b.py' = 'print(1)'
                                          'grocery\out\scratch.ps1' = 'Write-Output 2'; 'ops\me.ps1' = 'Write-Output 3' }
  try {
    $self = Join-Path $wtFx.Root 'ops\me.ps1'
    $wtFound = @(Get-FpeScanFiles -RootDir $wtFx.Root -Self $self)
    $wtHits = Measure-TcWorktreeFixture -Fixture $wtFx -Found $wtFound
    FpeT 'MUST FIRE  a root that IS a worktree is scanned, not excluded whole (.ps1 and .py, no \out\, not itself)' ($wtHits.Root -eq 2) ('root=' + $wtHits.Root)
    FpeT 'MUST NOT FIRE  a sibling worktree BELOW that root is still excluded' ($wtHits.Sibling -eq 0) ('sibling=' + $wtHits.Sibling)
    FpeT 'MUST NOT FIRE  the detector never scans itself' (@($wtFound | Where-Object { $_.FullName -eq $self }).Count -eq 0) ''
  } finally { Remove-Item -LiteralPath $wtFx.Temp -Recurse -Force -ErrorAction SilentlyContinue }

  if ($script:fail) { Write-Output ("FULL-PATH-EXCLUDES SELF-TEST FAILED ({0} of {1} case(s))" -f $script:fail, $script:cases); exit 2 }
  Write-Output ("FULL-PATH-EXCLUDES SELF-TEST PASSED ({0} case(s): both founding lines and the Python leftovers fire, both fixed forms stay silent, and the walk reads a worktree root)" -f $script:cases)
  exit 0
}

# ------------------------------------------------------------------------------------------- live run
# NEVER SCAN YOURSELF. The self-test above carries the founding lines as fixtures; they are strings, so the
# AST would not count them, but a detector that relies on that is one refactor from reporting itself.
$files = @(Get-FpeScanFiles -RootDir $repo -Self $PSCommandPath)
$psCount = @($files | Where-Object { $_.Extension -ieq '.ps1' }).Count
$pyCount = $files.Count - $psCount
if (-not $psCount) {
  Write-Output 'FULL-PATH-EXCLUDES AUDIT BLIND: resolved zero .ps1 files, which means the discovery is broken rather than the tree being clean.'
  Exit-Guard -Name 'full-path-excludes' -Summary 'blind=no-files' -Code 3
}
$rootFull = Get-TcRootFull $repo
$sites = New-Object System.Collections.ArrayList
$read = 0; $parseErrorFiles = 0
foreach ($f in $files) {
  $text = [IO.File]::ReadAllText($f.FullName)
  $r = if ($f.Extension -ieq '.ps1') { Get-FpePsFindings -Text $text } else { Get-FpePyFindings -Text $text }
  if ($r.Read) { $read++ }
  if ($r.ParseErrors) { $parseErrorFiles++ }
  $rel = (Get-TcPathBelowRoot $f.FullName $rootFull).TrimStart('\')
  foreach ($h in $r.Findings) { [void]$sites.Add(("{0}:{1}  {2}" -f $rel, $h.Line, $h.Text)) }
}
$count = $sites.Count
Write-Output ("full-path-excludes: resolved {0} file(s) ({1} .ps1, {2} .py); {3} could hold a finding and were read closely, {4} of those with a parse error; {5} site(s)" -f $files.Count, $psCount, $pyCount, $read, $parseErrorFiles, $count)
foreach ($s in $sites) { Write-Output ('  full-path  ' + $s) }
$summary = "files={0} read={1} sites={2}" -f $files.Count, $read, $count

$note = 'HIGH-WATER MARK for sites that match a file''s FULL path against an exclusion carrying worktrees or .claude. It may only go DOWN, and a fall to zero or over 60% in one run is REFUSED as a probably-broken detector (lib\ratchet.ps1).'
if (-not (Test-Path -LiteralPath $BASELINE_FILE)) {
  # The day-one count goes into the history as well, so every later fall is read against what was first measured.
  $hist = Add-RatchetHistory -Doc ([pscustomobject]@{}) -Count $count
  $doc = [pscustomobject]@{ generated = (Get-Date).ToString('s'); sites = $count; history = $hist; note = $note }
  [IO.File]::WriteAllText($BASELINE_FILE, ($doc | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
  Write-Output ("full-path-excludes: baseline written at {0} site(s). From here the number may only go DOWN." -f $count)
  Exit-Guard -Name 'full-path-excludes' -Summary ("{0} baseline={1}" -f $summary, $count) -Code 0
}
$base = [int]((Get-Content -LiteralPath $BASELINE_FILE -Raw -Encoding UTF8 | ConvertFrom-Json).sites)

if ($count -gt $base) {
  Write-Output ("FULL-PATH-EXCLUDES AUDIT FAILED: {0} site(s) match a file's FULL path against a pattern carrying worktrees or .claude, against a baseline of {1}." -f $count, $base)
  Write-Output '  A linked worktree lives at <main>\.claude\worktrees\<name>, so from one EVERY full path carries both, and the'
  Write-Output '  walk excludes the tree it was asked to read, then reports clean over nothing or exits 3. Match the path below'
  Write-Output '  the root instead: (Get-TcPathBelowRoot $_.FullName $rootFull) -notmatch ''...'', from lib\tree-walk.ps1, and'
  Write-Output '  give the walk a New-TcWorktreeFixture case. In Python, test os.path.relpath(root, REPO).'
  Exit-Guard -Name 'full-path-excludes' -Summary ("{0} baseline={1} ROSE" -f $summary, $base) -Code 2
}
$move = Test-RatchetMove -Name 'full-path-excludes' -Count $count -Baseline $base -AcceptDrop:$AcceptDrop
if ($move.Verdict -eq 'implausible') {
  Write-Output $move.Message
  Exit-Guard -Name 'full-path-excludes' -Summary ("{0} baseline={1} refused-to-lower" -f $summary, $base) -Code 2
}
if ($move.Verdict -eq 'tightened') {
  $doc = $null
  try { $doc = Get-Content -LiteralPath $BASELINE_FILE -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
  if (-not $doc) { $doc = [pscustomobject]@{} }
  $hist = Add-RatchetHistory -Doc $doc -Count $count
  $newDoc = [pscustomobject]@{ generated = (Get-Date).ToString('s'); sites = $move.NewBaseline; history = $hist; note = $note }
  [IO.File]::WriteAllText($BASELINE_FILE, ($newDoc | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
  Write-Output ('PASSED and TIGHTENED - ' + $move.Message)
  Write-Output ('  ' + (Get-RatchetTrend -History $hist))
  Exit-Guard -Name 'full-path-excludes' -Summary ("{0} tightened-from={1}" -f $summary, $base) -Code 0
}
Write-Output ("full-path-excludes: PASSED - {0} known site(s), unchanged from the baseline. Each one routed through Get-TcPathBelowRoot lowers the mark for good." -f $count)
Exit-Guard -Name 'full-path-excludes' -Summary ("{0} baseline={1}" -f $summary, $base) -Code 0
