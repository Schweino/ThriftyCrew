<#
  audit-alert-registry.ps1 - keeps grocery\alert-registry.json complete: every alert type maps to exactly one class.

  WHY (Brad, ruling 1, 2026-09-10; design\PLAN-zero-alert-days-2026-09-10.md section 7). send-alert.ps1 delivers an
  alert by its registered class: page (emailed and queued), review (queued, never emailed) or digest (emailed,
  never queued). A type with no entry still queues and pages, prefixed UNREGISTERED ALERT TYPE, so a gap is never
  silent when it fires. This check finds the gap BEFORE it fires.

  TWO HALVES, TWO HOMES.
    no switch  the SOURCE half. Parses every tracked .ps1 that names send-alert, follows each -Subject through
               literals, concatenation, -f, "$(...)", same-file assignments (if/else included), same-file
               functions that return a literal, and a same-file wrapper function's parameter back to its
               callers. Reads source only, so ops\run-gates.ps1 runs it on every push: a new call site with no
               entry fails the push rather than paging the next morning as a registry defect.
    -Queue     adds the DATA half: every distinct type in grocery\triage-queue.json over the last -Days. The daily
               chain's alert-registry lane (grocery\check-ad-cycles.ps1) runs this one.

  SCOPE OF A CLEAN REPORT: UNSOUND. It is a pattern follower over source text. A subject built from anything it
  cannot follow (a parameter passed in from another file, a member read, a Python or JavaScript caller, an agent's
  own prompt) is listed UNREADABLE and not checked, and a queue type is only seen after it has fired. A clean
  report means every subject it could read, and every queued type, maps to exactly one entry. It does not mean no
  unregistered alert can fire; send-alert.ps1 is the backstop for those and pages them as UNREGISTERED ALERT TYPE.

  EXIT: 0 clean. 2 at least one unmapped or ambiguous subject or type, or an entry that cannot be applied.
  3 could not evaluate (registry missing or unparseable, no call site found at all, or with -Queue an unreadable
  queue). The verdict line starts 'alert-registry:'; the last line is ALERT-REGISTRY-COMPLETE.
  Self-test: powershell -File grocery\audit-alert-registry.ps1 -SelfTest
#>
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop
param([switch]$SelfTest, [switch]$Queue, [string]$RegistryFile = '', [string]$QueueFile = '', [int]$Days = 30)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path $root -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\json-io.ps1')          # Read-JsonFile for the queue read below; named here, not inherited through the lib
. (Join-Path $root 'alert-registry-lib.ps1')

# Files that are the transport, not an emitter: the mailer itself, the one helper every emitter calls, and this.
$script:TransportFiles = @('send-alert.ps1', 'alert-lib.ps1', 'audit-alert-registry.ps1')

function Test-AstKind($Node, [string]$Kind) { return ($null -ne $Node -and $Node.GetType().Name -eq $Kind) }

function Get-BoundArgument {
  <# The AST passed for a parameter: by name anywhere, else by position ($Index, -1 = named only). #>
  param($Cmd, [string]$Name, [int]$Index = -1)
  $els = $Cmd.CommandElements
  for ($i = 1; $i -lt $els.Count; $i++) {
    $e = $els[$i]
    if ((Test-AstKind $e 'CommandParameterAst') -and $e.ParameterName -ieq $Name) {
      if ($e.Argument) { return $e.Argument }
      if ($i + 1 -lt $els.Count) { return $els[$i + 1] }
      return $null
    }
  }
  if ($Index -lt 0) { return $null }
  $pos = 0
  for ($i = 1; $i -lt $els.Count; $i++) {
    $e = $els[$i]
    if (Test-AstKind $e 'CommandParameterAst') { if (-not $e.Argument) { $i++ }; continue }
    if ($pos -eq $Index) { return $e }
    $pos++
  }
  return $null
}

function Get-PipelineValues {
  param($Pipeline, $Root, [int]$Depth)
  if ((Test-AstKind $Pipeline 'PipelineAst') -and $Pipeline.PipelineElements.Count -eq 1) {
    $el = $Pipeline.PipelineElements[0]
    if (Test-AstKind $el 'CommandExpressionAst') { return ,(Get-StaticSubjects $el.Expression $Root $Depth) }
    if (Test-AstKind $el 'CommandAst') { return ,(Get-FunctionReturnValues $el $Root $Depth) }
  }
  $out = New-Object System.Collections.Generic.List[string]
  [void]$out.Add($null)
  return ,$out
}

function Get-StatementValues {
  param($Stmt, $Root, [int]$Depth)
  $out = New-Object System.Collections.Generic.List[string]
  if (Test-AstKind $Stmt 'PipelineAst') { return ,(Get-PipelineValues $Stmt $Root $Depth) }
  if (Test-AstKind $Stmt 'CommandExpressionAst') { return ,(Get-StaticSubjects $Stmt.Expression $Root $Depth) }
  if (Test-AstKind $Stmt 'IfStatementAst') {
    $blocks = @()
    foreach ($c in $Stmt.Clauses) { $blocks += $c.Item2 }
    if ($Stmt.ElseClause) { $blocks += $Stmt.ElseClause }
    foreach ($b in $blocks) { foreach ($s in $b.Statements) { foreach ($v in (Get-StatementValues $s $Root ($Depth + 1))) { [void]$out.Add($v) } } }
    if ($out.Count) { return ,$out }
  }
  [void]$out.Add($null)
  return ,$out
}

function Get-FunctionReturnValues {
  param($Cmd, $Root, [int]$Depth)
  $out = New-Object System.Collections.Generic.List[string]
  $fname = $Cmd.GetCommandName()
  if ($fname) {
    $defs = $Root.FindAll({ param($a) $a.GetType().Name -eq 'FunctionDefinitionAst' -and $a.Name -ieq $fname }.GetNewClosure(), $true)
    foreach ($d in $defs) {
      $rets = $d.Body.FindAll({ param($a) $a.GetType().Name -eq 'ReturnStatementAst' }, $true)
      foreach ($r in $rets) { foreach ($v in (Get-PipelineValues $r.Pipeline $Root ($Depth + 1))) { [void]$out.Add($v) } }
    }
  }
  if (-not $out.Count) { [void]$out.Add($null) }
  return ,$out
}

function Get-VariableValues {
  param($VarNode, $Root, [int]$Depth)
  $out = New-Object System.Collections.Generic.List[string]
  $name = $VarNode.VariablePath.UserPath
  $assigns = $Root.FindAll({ param($a) $a.GetType().Name -eq 'AssignmentStatementAst' -and $a.Left.GetType().Name -eq 'VariableExpressionAst' -and $a.Left.VariablePath.UserPath -ieq $name }.GetNewClosure(), $true)
  foreach ($as in $assigns) { foreach ($v in (Get-StatementValues $as.Right $Root ($Depth + 1))) { [void]$out.Add($v) } }
  if ($out.Count) { return ,$out }
  # a parameter of the function this sits inside: follow that function's callers in the same file
  $fn = $VarNode.Parent
  while ($fn -and -not (Test-AstKind $fn 'FunctionDefinitionAst')) { $fn = $fn.Parent }
  if ($fn) {
    $params = @()
    if ($fn.Parameters) { $params = @($fn.Parameters) } elseif ($fn.Body.ParamBlock) { $params = @($fn.Body.ParamBlock.Parameters) }
    $idx = -1
    for ($i = 0; $i -lt $params.Count; $i++) { if ($params[$i].Name.VariablePath.UserPath -ieq $name) { $idx = $i } }
    if ($idx -ge 0) {
      $fname = $fn.Name
      $calls = $Root.FindAll({ param($a) $a.GetType().Name -eq 'CommandAst' -and $a.GetCommandName() -ieq $fname }.GetNewClosure(), $true)
      foreach ($c in $calls) {
        $arg = Get-BoundArgument $c $name $idx
        foreach ($v in (Get-StaticSubjects $arg $Root ($Depth + 1))) { [void]$out.Add($v) }
      }
    }
  }
  if (-not $out.Count) { [void]$out.Add($null) }
  return ,$out
}

function Get-StaticSubjects {
  <# Pure over an AST. Every string this node can evaluate to, each dynamic part written as 7 (the type key
     strips digits, so a count or a date vanishes exactly as it does at run time). A $null element means a part
     could not be followed. #>
  param($Node, $Root, [int]$Depth = 0)
  $out = New-Object System.Collections.Generic.List[string]
  if ($null -eq $Node -or $Depth -gt 8) { [void]$out.Add($null); return ,$out }
  $kind = $Node.GetType().Name
  if ($kind -eq 'StringConstantExpressionAst') { [void]$out.Add([string]$Node.Value) }
  elseif ($kind -eq 'ExpandableStringExpressionAst') {
    $s = [string]$Node.Value
    foreach ($n in @($Node.NestedExpressions)) { if ($n) { $s = $s.Replace($n.Extent.Text, '7') } }
    [void]$out.Add($s)
  }
  elseif ($kind -eq 'ConstantExpressionAst') { [void]$out.Add('7') }
  elseif ($kind -eq 'ParenExpressionAst') { foreach ($v in (Get-PipelineValues $Node.Pipeline $Root ($Depth + 1))) { [void]$out.Add($v) } }
  elseif ($kind -eq 'BinaryExpressionAst') {
    $op = [string]$Node.Operator
    $L = Get-StaticSubjects $Node.Left $Root ($Depth + 1)
    if ($op -eq 'Format') {
      foreach ($l in $L) { if ($null -eq $l) { [void]$out.Add($null) } else { [void]$out.Add(($l -replace '\{\d+(,[^}]*)?(:[^}]*)?\}', '7')) } }
    } elseif ($op -eq 'Plus') {
      $R = Get-StaticSubjects $Node.Right $Root ($Depth + 1)
      foreach ($l in $L) { foreach ($rr in $R) { if ($null -eq $l -or $null -eq $rr) { [void]$out.Add($null) } else { [void]$out.Add($l + $rr) } } }
    } else { [void]$out.Add($null) }
  }
  elseif ($kind -eq 'VariableExpressionAst') { foreach ($v in (Get-VariableValues $Node $Root ($Depth + 1))) { [void]$out.Add($v) } }
  elseif ($kind -eq 'CommandAst') { foreach ($v in (Get-FunctionReturnValues $Node $Root ($Depth + 1))) { [void]$out.Add($v) } }
  elseif (@('MemberExpressionAst', 'InvokeMemberExpressionAst', 'SubExpressionAst', 'IndexExpressionAst', 'ConvertExpressionAst') -contains $kind) { [void]$out.Add('7') }
  else { [void]$out.Add($null) }
  return ,$out
}

function Test-IsSendAlertCommand {
  param($Cmd, $Root)
  $n = $Cmd.GetCommandName()
  if ($n -and $n -ieq 'Send-Alert') { return $true }
  if ($n -and $n -match '(?i)send-alert\.ps1$') { return $true }
  if ($n -and $n -match '(?i)^powershell(\.exe)?$') {
    foreach ($e in $Cmd.CommandElements) { if ($e.Extent.Text -match '(?i)send-alert\.ps1') { return $true } }
    return $false
  }
  if ([string]$Cmd.InvocationOperator -ne 'Unknown') {
    $first = $Cmd.CommandElements[0]
    if ($first.Extent.Text -match '(?i)send-alert\.ps1') { return $true }
    if (Test-AstKind $first 'VariableExpressionAst') {
      $vn = $first.VariablePath.UserPath
      $as = $Root.FindAll({ param($a) $a.GetType().Name -eq 'AssignmentStatementAst' -and $a.Left.GetType().Name -eq 'VariableExpressionAst' -and $a.Left.VariablePath.UserPath -ieq $vn }.GetNewClosure(), $true)
      foreach ($x in $as) { if ($x.Right.Extent.Text -match '(?i)send-alert\.ps1') { return $true } }
    }
  }
  return $false
}

function Test-InsideSelfTest {
  param($Node)
  $p = $Node.Parent
  while ($p) {
    if (Test-AstKind $p 'IfStatementAst') { foreach ($c in $p.Clauses) { if ($c.Item1.Extent.Text -match '\$SelfTest') { return $true } } }
    $p = $p.Parent
  }
  return $false
}

function Get-AlertCallSites {
  <# Pure over a parsed script. One row per send-alert call: its readable subjects, or unreadable. A file that
     DEFINES Send-Alert is a stub or the transport, and calls inside an if ($SelfTest) block are fixtures. #>
  param($Ast, [string]$File)
  $sites = New-Object System.Collections.Generic.List[object]
  $stubs = @($Ast.FindAll({ param($a) $a.GetType().Name -eq 'FunctionDefinitionAst' -and $a.Name -ieq 'Send-Alert' }, $true))
  if ($stubs.Count) { return ,$sites }
  foreach ($c in $Ast.FindAll({ param($a) $a.GetType().Name -eq 'CommandAst' }, $true)) {
    if (-not (Test-IsSendAlertCommand $c $Ast)) { continue }
    if (Test-InsideSelfTest $c) { continue }
    $arg = Get-BoundArgument $c 'Subject' -1
    $subjects = New-Object System.Collections.Generic.List[string]
    $partial = $false
    if ($null -eq $arg) { $partial = $true }
    else {
      $vals = Get-StaticSubjects $arg $Ast 0
      foreach ($v in $vals) {
        if ($null -eq $v -or -not (Get-AlertTypeKey $v)) { $partial = $true; continue }
        if (-not $subjects.Contains($v)) { [void]$subjects.Add($v) }
      }
    }
    [void]$sites.Add([pscustomobject]@{ file = $File; line = $c.Extent.StartLineNumber; subjects = $subjects.ToArray(); unreadable = ($subjects.Count -eq 0); partial = $partial })
  }
  return ,$sites
}

function Get-RegistryVerdict {
  <# Pure. Registry + call sites + queue types -> findings (unmapped, ambiguous, invalid) and the counts. #>
  param($Registry, $Sites, $QueueTypes)
  $find = New-Object System.Collections.Generic.List[string]
  $unread = New-Object System.Collections.Generic.List[string]
  foreach ($p in (Get-AlertRegistryEntryProblems $Registry)) { [void]$find.Add('INVALID ENTRY ' + $p) }
  $subjN = 0; $typeN = 0; $resolved = @{}
  foreach ($s in $Sites) {   # never @($Sites): PS 5.1 throws 'Argument types do not match' on @(List[object])
    if (-not $s) { continue }
    if ($s.unreadable) { [void]$unread.Add($s.file + ':' + $s.line); continue }
    foreach ($subj in @($s.subjects)) {
      $subjN++
      $k = Get-AlertTypeKey $subj
      $res = Resolve-AlertClass $Registry $k
      if (-not $res.registered) { [void]$find.Add("UNMAPPED call site " + $s.file + ':' + $s.line + " type='" + $k + "' subject='" + $subj + "'") }
      elseif ($res.ambiguous) { [void]$find.Add("AMBIGUOUS call site " + $s.file + ':' + $s.line + " type='" + $k + "' matches " + $res.candidates + " entries") }
      else { $resolved['site|' + $s.file + ':' + $s.line + '|' + $k] = [string]$res.entry.id }
    }
  }
  foreach ($t in @($QueueTypes)) {
    if (-not $t) { continue }
    $typeN++
    $res = Resolve-AlertClass $Registry ([string]$t)
    if (-not $res.registered) { [void]$find.Add("UNMAPPED queue type '" + $t + "'") }
    elseif ($res.ambiguous) { [void]$find.Add("AMBIGUOUS queue type '" + $t + "' matches " + $res.candidates + " entries") }
    else { $resolved['type|' + $t] = [string]$res.entry.id }
  }
  return [pscustomobject]@{ findings = $find; unreadable = $unread; subjects = $subjN; types = $typeN; resolved = $resolved }
}

function ConvertTo-ParsedAst([string]$Source) {
  $tok = $null; $err = $null
  return [System.Management.Automation.Language.Parser]::ParseInput($Source, [ref]$tok, [ref]$err)
}

if ($SelfTest) {
  $fail = 0; $ran = 0
  function _T([string]$label, [bool]$cond, [string]$detail) {
    $script:ran++
    if ($cond) { Write-Output "ok    $label" } else { Write-Output "FAIL  $label  - $detail"; $script:fail++ }
  }
  $fxReg = [pscustomobject]@{ entries = @(
    [pscustomobject]@{ id = 'dropped'; match = 'prefix'; key = 'grocery store s dropped'; class = 'review'; condition = 'review intake'; emitter = 'x.ps1' },
    [pscustomobject]@{ id = 'held'; match = 'exact'; key = 'grocery page held coverage'; class = 'page'; condition = '1 board-or-feed-wrong-or-held'; emitter = 'x.ps1' },
    [pscustomobject]@{ id = 'tg-blind'; match = 'exact'; key = 'grocery test guards could not evaluate'; class = 'page'; condition = '2 watcher-cannot-see'; emitter = 'x.ps1' },
    [pscustomobject]@{ id = 'tg-invariant'; match = 'exact'; key = 'grocery a blocking invariant can no longer fail'; class = 'page'; condition = '2 watcher-cannot-see'; emitter = 'x.ps1' }
  ) }

  # MUST FIRE: the founding gap. A call site whose subject has no entry is reported, with its type key.
  $src1 = @'
if (-not $NoAlert) { try { Send-Alert -Subject "Grocery: a brand new failure nobody registered - $asofS" -Body 'x' | Out-Null } catch {} }
'@
  $v1 = Get-RegistryVerdict $fxReg (Get-AlertCallSites (ConvertTo-ParsedAst $src1) 'fx1.ps1') @()
  _T 'MUST FIRE a call-site subject with no registry entry is reported UNMAPPED' ($v1.findings.Count -eq 1 -and $v1.findings[0] -match "UNMAPPED call site fx1\.ps1:1 type='grocery a brand new failure nobody registered'") ($v1.findings -join ' | ')

  # MUST NOT FIRE: a registered PREFIX covers a dynamic subject (a count, a concatenated date).
  $src2 = @'
Send-Alert -Subject ("Grocery: $($cg.Count) store(s) dropped from a commodity they carry - " + $asofS) -Body 'x' | Out-Null
'@
  $v2 = Get-RegistryVerdict $fxReg (Get-AlertCallSites (ConvertTo-ParsedAst $src2) 'fx2.ps1') @()
  _T 'MUST NOT FIRE a registered prefix covers a dynamic subject' ($v2.findings.Count -eq 0 -and $v2.subjects -eq 1 -and @($v2.resolved.Values) -contains 'dropped') ("findings=" + ($v2.findings -join ' | ') + " subjects=" + $v2.subjects)

  # CLEAN TWIN: a subject held in a variable and produced by a same-file function with two returns still resolves,
  # each branch to its own exact entry - the shape check-ad-cycles' test-guards alert uses.
  $src3 = @'
function Get-TgSubject { param([int]$Rc) if ($Rc -eq 3) { return 'Grocery: test-guards could not evaluate' }; return 'Grocery: a BLOCKING invariant can no longer fail' }
$tgSubject = Get-TgSubject -Rc $tgRc
Send-Alert -Subject $tgSubject -Body 'x' | Out-Null
'@
  $s3 = Get-AlertCallSites (ConvertTo-ParsedAst $src3) 'fx3.ps1'
  $v3 = Get-RegistryVerdict $fxReg $s3 @()
  $ids3 = @($v3.resolved.Values | Sort-Object)
  _T 'CLEAN TWIN a variable subject from a same-file function resolves both branches to their entries' ($s3.Count -eq 1 -and $v3.subjects -eq 2 -and ($ids3 -join ',') -eq 'tg-blind,tg-invariant') ("sites=" + $s3.Count + " ids=" + ($ids3 -join ','))

  # CLEAN TWIN: a wrapper function's parameter is followed back to its caller (bakers-daily-scan's Alert shape),
  # and the in-process '& $alert' form whose variable names send-alert.ps1 is a call site (sidecar-watchdog's shape).
  $src4 = @'
function Alert([string]$subject, [string]$body) { try { Send-Alert -Subject $subject -Body $body | Out-Null } catch {} }
Alert "Grocery page HELD (coverage) - $d" "b"
$alert = Join-Path $RepoRoot 'grocery\send-alert.ps1'
& $alert -Subject 'Semantic sidecar is down' -Body 'b'
'@
  $s4 = Get-AlertCallSites (ConvertTo-ParsedAst $src4) 'fx4.ps1'
  $v4 = Get-RegistryVerdict $fxReg $s4 @()
  _T 'CLEAN TWIN a wrapper parameter resolves through its caller, and an & $alert call is found' ($s4.Count -eq 2 -and @($v4.resolved.Values) -contains 'held' -and $v4.findings.Count -eq 1 -and $v4.findings[0] -match 'semantic sidecar is down') ("sites=" + $s4.Count + " findings=" + ($v4.findings -join ' | '))

  # MUST NOT FIRE: a call inside an if ($SelfTest) block is a fixture, and a file that defines a Send-Alert stub is not an emitter.
  $src5 = @'
if ($SelfTest) { Send-Alert -Subject 'Grocery: fixture only' -Body 'x' }
'@
  $src6 = @'
function Send-Alert { param($Subject, $Body) $script:s = $Subject }
Send-Alert -Subject 'Grocery: a stubbed call' -Body 'x'
'@
  $n5 = (Get-AlertCallSites (ConvertTo-ParsedAst $src5) 'fx5.ps1').Count
  $n6 = (Get-AlertCallSites (ConvertTo-ParsedAst $src6) 'fx6.ps1').Count
  _T 'MUST NOT FIRE a -SelfTest fixture call and a stubbed Send-Alert are not call sites' ($n5 -eq 0 -and $n6 -eq 0) ("selftest=" + $n5 + " stub=" + $n6)

  # MUST NOT FIRE as unmapped: a subject built from a script parameter cannot be read, so it is UNREADABLE, not a finding.
  $src7 = @'
param([string]$Title = '')
& (Join-Path $root 'send-alert.ps1') -Subject $Title -Body $Message | Out-Null
'@
  $v7 = Get-RegistryVerdict $fxReg (Get-AlertCallSites (ConvertTo-ParsedAst $src7) 'fx7.ps1') @()
  _T 'MUST NOT FIRE an unreadable subject is listed UNREADABLE, never counted as mapped or unmapped' ($v7.findings.Count -eq 0 -and $v7.unreadable.Count -eq 1) ("findings=" + $v7.findings.Count + " unreadable=" + $v7.unreadable.Count)

  # MUST FIRE: the queue half. A type that fired and matches nothing is reported.
  $v8 = Get-RegistryVerdict $fxReg @() @('grocery page held coverage', 'grocery something nobody registered')
  _T 'MUST FIRE a queue type with no registry entry is reported UNMAPPED' ($v8.findings.Count -eq 1 -and $v8.findings[0] -match "UNMAPPED queue type 'grocery something nobody registered'") ($v8.findings -join ' | ')

  # MUST FIRE: two prefixes that both cover a type are AMBIGUOUS - "exactly one entry" is the bar.
  $fxAmb = [pscustomobject]@{ entries = @(@($fxReg.entries) + [pscustomobject]@{ id = 'dropped-2'; match = 'prefix'; key = 'grocery store s'; class = 'page'; condition = '1 board-or-feed-wrong-or-held'; emitter = 'x.ps1' }) }
  $v9 = Get-RegistryVerdict $fxAmb @() @('grocery store s dropped from a commodity they carry')
  _T 'MUST FIRE a type covered by two prefix entries is AMBIGUOUS' ($v9.findings.Count -eq 1 -and $v9.findings[0] -match 'AMBIGUOUS') ($v9.findings -join ' | ')
  _T 'and an ambiguous type resolves to the most severe class (page), failing toward paging' ((Resolve-AlertClass $fxAmb 'grocery store s dropped from a commodity they carry').class -eq 'page') 'not page'

  # MUST FIRE: an entry the mailer cannot apply (an unknown class) is reported, and resolves to page, not silence.
  $fxBad = [pscustomobject]@{ entries = @([pscustomobject]@{ id = 'loud'; match = 'exact'; key = 'x y'; class = 'loud'; condition = 'c'; emitter = 'x.ps1' }) }
  $v10 = Get-RegistryVerdict $fxBad @() @()
  _T 'MUST FIRE an entry with a class outside page, review, digest is INVALID' ($v10.findings.Count -ge 1 -and $v10.findings[0] -match 'INVALID ENTRY') ($v10.findings -join ' | ')
  _T 'and that entry resolves to page' ((Resolve-AlertClass $fxBad 'x y').class -eq 'page') 'not page'

  # MUST FIRE: a registry that is not there is not a registry; the check is blind and the mailer pages everything.
  $st = Read-AlertRegistry (Join-Path $env:TEMP ('no-such-alert-registry-' + [guid]::NewGuid().ToString('N') + '.json'))
  _T 'MUST FIRE a missing registry reads as not ok, and resolves every type to page' ((-not $st.ok) -and (Resolve-AlertClass $st.registry 'grocery matching soundness review needed').class -eq 'page' -and -not (Resolve-AlertClass $st.registry 'x').registry_ok) $st.why

  Write-Output ''
  if ($fail -gt 0) { Write-Output "SELF-TEST FAIL: $fail of $ran case(s)"; exit 1 }
  Write-Output "SELF-TEST PASS ($ran alert-registry cases)"
  exit 0
}

if (-not $RegistryFile) { $RegistryFile = Join-Path $root 'alert-registry.json' }
$reg = Read-AlertRegistry $RegistryFile
if (-not $reg.ok) {
  Write-Output ('alert-registry: COULD NOT EVALUATE - ' + $reg.why + '. send-alert.ps1 is paging every alert until this is fixed.')
  Exit-Guard -Name 'ALERT-REGISTRY' -Code 3 -Summary 'blind=registry'
}

# ---- the source half ----
$tracked = @(& git -C $repo ls-files -- '*.ps1')
$gitRc = $LASTEXITCODE
if ($gitRc -ne 0 -or $tracked.Count -eq 0) {
  Write-Output ('alert-registry: COULD NOT EVALUATE - git ls-files returned ' + $tracked.Count + ' file(s), exit ' + $gitRc)
  Exit-Guard -Name 'ALERT-REGISTRY' -Code 3 -Summary 'blind=no-tracked-files'
}
$sites = New-Object System.Collections.Generic.List[object]
$scanned = 0; $parsed = 0
foreach ($rel in $tracked) {
  if ($rel -match '(^|/)archive/') { continue }
  if ($script:TransportFiles -contains (Split-Path -Leaf $rel)) { continue }
  $full = Join-Path $repo $rel
  if (-not (Test-Path -LiteralPath $full)) { continue }
  $scanned++
  $text = [IO.File]::ReadAllText($full)
  if ($text.IndexOf('send-alert', [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
  $parsed++
  foreach ($s in (Get-AlertCallSites (ConvertTo-ParsedAst $text) $rel)) { [void]$sites.Add($s) }
}
if ($sites.Count -eq 0) {
  Write-Output ('alert-registry: COULD NOT EVALUATE - scanned ' + $scanned + ' tracked script(s) and found no send-alert call site at all; that is the walk broken, not the estate quiet.')
  Exit-Guard -Name 'ALERT-REGISTRY' -Code 3 -Summary ('blind=no-call-sites scanned=' + $scanned)
}

# ---- the data half ----
$qTypes = @()
if ($Queue) {
  if (-not $QueueFile) { $QueueFile = Join-Path $root 'triage-queue.json' }
  $q = $null
  try { $q = Read-JsonFile $QueueFile } catch { $q = $null }
  if (-not $q -or -not $q.PSObject.Properties['items']) {
    Write-Output ('alert-registry: COULD NOT EVALUATE - the queue ' + $QueueFile + ' is missing, unparseable or has no items array')
    Exit-Guard -Name 'ALERT-REGISTRY' -Code 3 -Summary 'blind=queue'
  }
  $cut = (Get-Date).AddDays(-$Days).ToString('yyyy-MM-dd')
  $qTypes = @($q.items | Where-Object { $_ -and [string]$_.type -and [string]$_.date -ge $cut } | ForEach-Object { [string]$_.type } | Sort-Object -Unique)
}

$v = Get-RegistryVerdict $reg.registry $sites $qTypes
$entries = @($reg.registry.entries | Where-Object { $_ })
$byClass = @{ page = 0; review = 0; digest = 0 }
foreach ($e in $entries) {
  $cls = [string]$e.class
  if ($byClass.ContainsKey($cls)) { $byClass[$cls] = [int]$byClass[$cls] + 1 }   # not $h[[string]$x]++ : PS 5.1 cannot compile that
}
Write-Output ("alert-registry: {0} entries (page {1}, review {2}, digest {3}) in {4}" -f $entries.Count, $byClass.page, $byClass.review, $byClass.digest, $RegistryFile)
Write-Output ("  scanned {0} tracked script(s), parsed {1} that name send-alert, found {2} call site(s)" -f $scanned, $parsed, $sites.Count)
foreach ($f in $v.findings) { Write-Output ('  ! ' + $f) }
foreach ($u in $v.unreadable) { Write-Output ('  ? UNREADABLE call site ' + $u + ' - its subject is not built from anything this can follow, so it is not checked (send-alert pages it as UNREGISTERED if it fires unmapped)') }
$qTxt = if ($Queue) { (' and ' + $v.types + ' queue type(s) over ' + $Days + ' day(s)') } else { ' (queue half not run: pass -Queue)' }
$sum = ("files={0} sites={1} subjects={2} unreadable={3} queue_types={4} findings={5}" -f $parsed, $sites.Count, $v.subjects, $v.unreadable.Count, $v.types, $v.findings.Count)
if ($v.findings.Count) {
  Write-Output ('alert-registry: FAILED - ' + $v.findings.Count + ' finding(s) across ' + $v.subjects + ' readable call-site subject(s)' + $qTxt + '. Register each type in grocery\alert-registry.json.')
  Exit-Guard -Name 'ALERT-REGISTRY' -Code 2 -Summary $sum
}
Write-Output ('alert-registry: PASSED - ' + $v.subjects + ' readable call-site subject(s)' + $qTxt + ' each map to exactly one entry; ' + $v.unreadable.Count + ' call site(s) unreadable')
Exit-Guard -Name 'ALERT-REGISTRY' -Code 0 -Summary $sum
