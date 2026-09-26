<#
  count-unchecked-child-parse.ps1 - where is a CHILD PROCESS's or a WEB CALL's output parsed as data with neither
  an exit/status read nor a shape check? A REPORT, exit 0. Never a gate. (backlog I188, 2026-09-19)

  WHY IT EXISTS. An error must not travel on the channel the consumer reads as data. This estate has paid for that
  shape three times: an HTTP 200 carrying an HTML error page, a self-test verdict glued onto a case line, and a
  native child's stderr folded into its output under EAP=Stop. The item asked for the count before any rule.

  THE TEST, which is the acceptance bar committed into design\BACKLOG-course-findings.md I188 before the first run:
    * POPULATION: tracked .ps1 (PowerShell AST, here) and .py (Python ast, ops\count_unchecked_child_parse.py)
      outside any archive/ directory.
    * A SITE is a ConvertFrom-Json, a -split, a .Split( or an Invoke-RestMethod (which parses implicitly) whose
      input is a NATIVE child's output or a WEB call's, directly (piped, or as the operand) or through assignments
      in the same scope (-MaxHops, default 1, the bar's "one assignment"). NATIVE: a command named in $TcuNative, anything ending .exe, Invoke-Native /
      Invoke-NativeScript, `& <x>` where <x> is a string or a variable whose assignments in the file name an .exe,
      python, powershell, pwsh, node or git, and .StandardOutput.ReadToEnd(). WEB: Invoke-WebRequest and its
      iwr / curl / wget aliases, Invoke-RestMethod / irm, and WebClient / HttpClient string calls. `& $x.ps1` runs
      in-process and returns objects, so it is not a child's stdout and not a site.
    * EXIT READ: $LASTEXITCODE, $?, or a .ExitCode / .StatusCode member anywhere in the same scope. IMPLICIT: the
      PowerShell 5.1 web cmdlets throw on a non-2xx, recorded as their own class, because a 200 carrying an error
      page still passes it.
    * SHAPE CHECK: the parse result is assigned to a variable, and that variable appears AFTER the site in an if /
      elseif / while / do / switch condition, an -is / -isnot test, or a .PSObject member read, in the same scope.
    * A scope is a function body, or the file's code outside every function.
    * U = sites with no exit read (none, not implicit) and no shape check.

  SCOPE OF A CLEAN REPORT: UNSOUND, in both directions. A child launched through a helper this file does not
  model (a function returning git's stdout, Start-Process writing a file that is read back) is not followed, so its
  parse is not a site; a try/catch around the parse, or a guard in a caller, is not read as a check, so a site the
  scanner calls unguarded may be protected. Every U site is a CANDIDATE to read by eye, and a file absent from the
  list proves nothing.

  Usage:
    powershell -NoProfile -File ops\count-unchecked-child-parse.ps1                 totals, by language and class
    powershell -NoProfile -File ops\count-unchecked-child-parse.ps1 -ShowSites      plus every U site, file:line
    powershell -NoProfile -File ops\count-unchecked-child-parse.ps1 -JsonOut <f>    plus one row per site (JSONL)
    powershell -NoProfile -File ops\count-unchecked-child-parse.ps1 -SelfTest       frozen fixtures, both halves
#>
# The self-test is inline fixtures plus the Python half's own --selftest.
# gate-inputs: ops\count_unchecked_child_parse.py
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop
param([switch]$SelfTest, [switch]$ShowSites, [string]$JsonOut = '', [string]$Root = '', [int]$MaxHops = 1)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path $here -Parent
Add-Type -AssemblyName System.Management.Automation
$script:TcuMaxHops = $MaxHops   # the I188 bar: "directly or through one assignment in the same scope"
$TcuPython = 'C:\Codex\Python312\python.exe'   # workspace rule: bare python is not the interpreter

$TcuNative = @('git', 'python', 'python3', 'py', 'node', 'npx', 'npm', 'powershell', 'pwsh', 'cmd', 'gh', 'claude',
  'schtasks', 'wsl', 'where', 'tasklist', 'netstat', 'wmic', 'reg', 'sc', 'robocopy', 'icacls', 'nvidia-smi', 'ffmpeg',
  'ffprobe', 'invoke-native', 'invoke-nativescript', 'curl.exe')
$TcuWeb = @('invoke-webrequest', 'iwr', 'curl', 'wget', 'invoke-restmethod', 'irm')
$TcuPassMember = @('content', 'rawcontent', 'stdout', 'output', 'out', 'lines', 'text', 'result', 'standardoutput', 'value')
$TcuPassMethod = @('trim', 'trimend', 'trimstart', 'tostring', 'replace', 'tolower', 'toupper', 'readtoend', 'getresult')
$TcuWebMethod = @('downloadstring', 'uploadstring', 'getstringasync', 'readasstringasync')
$TcuNativeText = '(?i)(\.exe\b|python|powershell|pwsh|\bnode\b|\bgit\b)'

function Get-TcuScope($node) {
  $p = $node.Parent
  while ($null -ne $p) {
    if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) { return $p }
    $p = $p.Parent
  }
  return $null
}

function Get-TcuVarName($v) {
  $n = $v.VariablePath.UserPath
  $i = $n.IndexOf(':')
  if ($i -ge 0) { $n = $n.Substring($i + 1) }
  return $n.ToLower()
}

function Test-TcuNativeTarget($expr, $ctx) {
  if ($expr -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
      $expr -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
    $t = $expr.Value
    if ($t -match '(?i)\.ps1$') { return $false }
    return ($t -match $TcuNativeText)
  }
  if ($expr -is [System.Management.Automation.Language.VariableExpressionAst]) {
    $k = Get-TcuVarName $expr
    if ($k -match '^(py|python\w*|pyexe|node\w*|git\w*|pwsh|psexe|powershell\w*|exe)$') { return $true }
    if ($ctx.FileAssign.ContainsKey($k)) {
      foreach ($rhs in $ctx.FileAssign[$k]) {
        $t = $rhs.Extent.Text
        if ($t -match '(?i)\.ps1[''"]') { continue }
        if ($t -match $TcuNativeText) { return $true }
      }
    }
  }
  return $false
}

# 'native', 'web' or '' for a CommandAst
function Get-TcuCommandKind($cmd, $ctx) {
  $name = $cmd.GetCommandName()
  if ($cmd.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Ampersand) {
    if (Test-TcuNativeTarget $cmd.CommandElements[0] $ctx) { return 'native' }
    return ''
  }
  if (-not $name) { return '' }
  $l = $name.ToLower()
  if ($TcuWeb -contains $l) { return 'web' }
  if ($TcuNative -contains $l) { return 'native' }
  if ($l.EndsWith('.exe')) { return 'native' }
  return ''
}

function Get-TcuSourceKind($expr, $ctx, [int]$depth, [int]$hops = 0) {
  # $depth counts AST steps (a hang guard); $hops counts ASSIGNMENTS followed, which is what -MaxHops bounds
  if ($null -eq $expr -or $depth -gt 16 -or $hops -gt $script:TcuMaxHops) { return '' }
  $t = $expr.GetType().Name
  switch ($t) {
    'PipelineAst' {
      foreach ($el in $expr.PipelineElements) {
        if ($el -is [System.Management.Automation.Language.CommandAst]) {
          $k = Get-TcuCommandKind $el $ctx
          if ($k) { return $k }
        }
      }
      $first = $expr.PipelineElements[0]
      if ($first -is [System.Management.Automation.Language.CommandExpressionAst]) { return (Get-TcuSourceKind $first.Expression $ctx ($depth + 1) $hops) }
      return ''
    }
    'CommandExpressionAst' { return (Get-TcuSourceKind $expr.Expression $ctx ($depth + 1) $hops) }
    'ParenExpressionAst'   { return (Get-TcuSourceKind $expr.Pipeline $ctx ($depth + 1) $hops) }
    'SubExpressionAst'     {
      foreach ($s in $expr.SubExpression.Statements) { $k = Get-TcuSourceKind $s $ctx ($depth + 1) $hops; if ($k) { return $k } }
      return ''
    }
    'ArrayExpressionAst'   {
      foreach ($s in $expr.SubExpression.Statements) { $k = Get-TcuSourceKind $s $ctx ($depth + 1) $hops; if ($k) { return $k } }
      return ''
    }
    'ConvertExpressionAst' { return (Get-TcuSourceKind $expr.Child $ctx ($depth + 1) $hops) }
    'UnaryExpressionAst'   { return (Get-TcuSourceKind $expr.Child $ctx ($depth + 1) $hops) }
    'BinaryExpressionAst'  {
      if ($expr.Operator.ToString() -match '(?i)join|replace') { return (Get-TcuSourceKind $expr.Left $ctx ($depth + 1) $hops) }
      return ''
    }
    'AssignmentStatementAst' { return (Get-TcuSourceKind $expr.Right $ctx ($depth + 1) $hops) }
    'VariableExpressionAst' {
      $k = Get-TcuVarName $expr
      if ($ctx.ScopeAssign.ContainsKey($k)) {
        foreach ($rhs in $ctx.ScopeAssign[$k]) { $r = Get-TcuSourceKind $rhs $ctx ($depth + 1) ($hops + 1); if ($r) { return $r } }
      }
      return ''
    }
    'MemberExpressionAst' {
      $m = "$($expr.Member)".Trim('''"').ToLower()
      if ($TcuPassMember -contains $m) { return (Get-TcuSourceKind $expr.Expression $ctx ($depth + 1) $hops) }
      return ''
    }
    'InvokeMemberExpressionAst' {
      $m = "$($expr.Member)".Trim('''"').ToLower()
      if ($TcuWebMethod -contains $m) { return 'web' }
      if ($m -eq 'readtoend' -and $expr.Expression.Extent.Text -match '(?i)StandardOutput') { return 'native' }
      if ($TcuPassMethod -contains $m) { return (Get-TcuSourceKind $expr.Expression $ctx ($depth + 1) $hops) }
      return ''
    }
  }
  return ''
}

# The variable names a parse result lands in: the nearest enclosing assignment's left side.
function Get-TcuResultNames($site) {
  $names = @()
  $p = $site.Parent
  $hops = 0
  while ($null -ne $p -and $hops -lt 6) {
    if ($p -is [System.Management.Automation.Language.AssignmentStatementAst]) {
      foreach ($v in $p.Left.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
        $names += (Get-TcuVarName $v)
      }
      break
    }
    if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst] -or
        $p -is [System.Management.Automation.Language.NamedBlockAst]) { break }
    $p = $p.Parent
    $hops++
  }
  return , $names
}

function Test-TcuShapeCheck($names, [int]$afterOffset, $scopeNodes) {
  if ($names.Count -eq 0) { return $false }
  foreach ($n in $scopeNodes) {
    $conds = @()
    if ($n -is [System.Management.Automation.Language.IfStatementAst]) { foreach ($c in $n.Clauses) { $conds += $c.Item1 } }
    elseif ($n -is [System.Management.Automation.Language.WhileStatementAst] -or
            $n -is [System.Management.Automation.Language.DoWhileStatementAst] -or
            $n -is [System.Management.Automation.Language.DoUntilStatementAst]) { $conds += $n.Condition }
    elseif ($n -is [System.Management.Automation.Language.SwitchStatementAst]) { $conds += $n.Condition }
    elseif ($n -is [System.Management.Automation.Language.BinaryExpressionAst] -and "$($n.Operator)" -match '^Is(Not)?$') { $conds += $n }
    elseif ($n -is [System.Management.Automation.Language.MemberExpressionAst] -and "$($n.Member)" -eq 'PSObject') { $conds += $n }
    foreach ($c in $conds) {
      if ($null -eq $c -or $c.Extent.StartOffset -lt $afterOffset) { continue }
      foreach ($v in $c.FindAll({ param($x) $x -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
        if ($names -contains (Get-TcuVarName $v)) { return $true }
      }
    }
  }
  return $false
}

function Get-TcuSitesFromText([string]$text, [string]$rel) {
  $tokens = $null; $errs = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errs)
  if ($errs -and $errs.Count -gt 0) { return $null }
  $all = $ast.FindAll({ param($n) $true }, $true)
  # group nodes and assignments by scope (a function, or the file outside every function)
  $scopeNodes = @{}; $scopeAssign = @{}; $fileAssign = @{}
  $fileKey = 'FILE'
  foreach ($n in $all) {
    $s = Get-TcuScope $n
    $key = if ($null -eq $s) { $fileKey } else { [string][System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($s) }
    if (-not $scopeNodes.ContainsKey($key)) { $scopeNodes[$key] = New-Object System.Collections.ArrayList; $scopeAssign[$key] = @{} }
    [void]$scopeNodes[$key].Add($n)
    if ($n -is [System.Management.Automation.Language.AssignmentStatementAst]) {
      $left = $n.Left
      if ($left -is [System.Management.Automation.Language.ConvertExpressionAst]) { $left = $left.Child }
      if ($left -is [System.Management.Automation.Language.VariableExpressionAst]) {
        $k = Get-TcuVarName $left
        if (-not $scopeAssign[$key].ContainsKey($k)) { $scopeAssign[$key][$k] = New-Object System.Collections.ArrayList }
        [void]$scopeAssign[$key][$k].Add($n.Right)
        if (-not $fileAssign.ContainsKey($k)) { $fileAssign[$k] = New-Object System.Collections.ArrayList }
        [void]$fileAssign[$k].Add($n.Right)
      }
    }
  }
  $rows = New-Object System.Collections.ArrayList
  $exitCache = @{}
  foreach ($key in @($scopeNodes.Keys)) {
    $ctx = @{ ScopeAssign = $scopeAssign[$key]; FileAssign = $fileAssign }
    foreach ($n in $scopeNodes[$key]) {
      $op = ''; $kind = ''; $implicitParse = $false
      if ($n -is [System.Management.Automation.Language.CommandAst]) {
        $cn = $n.GetCommandName()
        if ($cn -and $cn -ieq 'ConvertFrom-Json') {
          $op = 'ConvertFrom-Json'
          $pipe = $n.Parent
          $kinds = ''
          if ($pipe -is [System.Management.Automation.Language.PipelineAst]) {
            $idx = $pipe.PipelineElements.IndexOf($n)
            for ($i = 0; $i -lt $idx; $i++) {
              $el = $pipe.PipelineElements[$i]
              if ($el -is [System.Management.Automation.Language.CommandAst]) { $kk = Get-TcuCommandKind $el $ctx }
              else { $kk = Get-TcuSourceKind $el.Expression $ctx 0 }
              if ($kk) { $kinds = $kk; break }
            }
          }
          if (-not $kinds) {
            for ($i = 1; $i -lt $n.CommandElements.Count; $i++) {
              $el = $n.CommandElements[$i]
              if ($el -is [System.Management.Automation.Language.CommandParameterAst]) { continue }
              $kk = Get-TcuSourceKind $el $ctx 0
              if ($kk) { $kinds = $kk; break }
            }
          }
          $kind = $kinds
        } elseif ($cn -and @('invoke-restmethod', 'irm') -contains $cn.ToLower()) {
          $op = 'Invoke-RestMethod'; $kind = 'web'; $implicitParse = $true
        }
      } elseif ($n -is [System.Management.Automation.Language.BinaryExpressionAst] -and "$($n.Operator)" -match '(?i)split') {
        $op = '-split'; $kind = Get-TcuSourceKind $n.Left $ctx 0
      } elseif ($n -is [System.Management.Automation.Language.UnaryExpressionAst] -and "$($n.TokenKind)" -match '(?i)split') {
        $op = '-split'; $kind = Get-TcuSourceKind $n.Child $ctx 0
      } elseif ($n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and "$($n.Member)" -ieq 'Split') {
        $op = '.Split('; $kind = Get-TcuSourceKind $n.Expression $ctx 0
      }
      if (-not $op -or -not $kind) { continue }
      if (-not $exitCache.ContainsKey($key)) {
        $hit = $false
        foreach ($x in $scopeNodes[$key]) {
          if ($x -is [System.Management.Automation.Language.VariableExpressionAst]) {
            $vn = Get-TcuVarName $x
            if ($vn -eq 'lastexitcode' -or $vn -eq '?') { $hit = $true; break }
          } elseif ($x -is [System.Management.Automation.Language.MemberExpressionAst]) {
            $mn = "$($x.Member)".Trim('''"')
            if ($mn -ieq 'ExitCode' -or $mn -ieq 'StatusCode') { $hit = $true; break }
          }
        }
        $exitCache[$key] = $hit
      }
      $names = Get-TcuResultNames $n
      $shape = Test-TcuShapeCheck $names $n.Extent.EndOffset $scopeNodes[$key]
      $exit = if ($exitCache[$key]) { 'read' } elseif ($kind -eq 'web') { 'implicit' } else { 'none' }
      [void]$rows.Add([ordered]@{
        lang = 'ps1'; file = $rel; line = $n.Extent.StartLineNumber; op = $op; class = $kind
        exit = $exit; shape = $shape; unguarded = ($exit -eq 'none' -and -not $shape)
      })
    }
  }
  return , $rows
}

if ($SelfTest) {
  $cases = 0; $fails = 0
  function TcuCase([string]$label, [string]$src, [int]$wantSites, [int]$wantU) {
    $r = Get-TcuSitesFromText $src 'fx.ps1'
    $u = @($r | Where-Object { $_.unguarded }).Count
    $ok = ($r.Count -eq $wantSites -and $u -eq $wantU)
    $script:cases++
    if (-not $ok) { $script:fails++ }
    Write-Output ("{0} {1}  sites={2} unguarded={3}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $label, $r.Count, $u)
  }
  TcuCase 'MUST FIRE      git output piped into ConvertFrom-Json, no exit read, no shape check' 'function F { $j = git log -1 --format=x | ConvertFrom-Json; return $j.a }' 1 1
  TcuCase 'MUST FIRE      a python child''s stdout, through one assignment, -split with no check' '$py = ''C:\x\python.exe''; $out = & $py a.py; $parts = $out -split '',''; $parts[0]' 1 1
  TcuCase 'MUST NOT FIRE  LASTEXITCODE read in the same scope' 'function F { $o = git status --porcelain; if ($LASTEXITCODE -ne 0) { throw ''x'' }; return ($o -split "`n") }' 1 0
  TcuCase 'MUST NOT FIRE  a shape check on the parsed variable' 'function F { $d = & node x.js | ConvertFrom-Json; if ($null -eq $d.rows) { return @() }; $d.rows }' 1 0
  TcuCase 'MUST NOT FIRE  a file read is not a child''s output' 'function F($p) { $d = Get-Content $p -Raw | ConvertFrom-Json; ($d.a -split '','') }' 0 0
  TcuCase 'MUST NOT FIRE  an in-process .ps1 call is not a child' '$s = ''x.ps1''; $d = & $s | ConvertFrom-Json; $d' 0 0
  TcuCase 'CLEAN TWIN     Invoke-WebRequest content is a site, implicit status, not unguarded' 'function F($u) { $r = Invoke-WebRequest $u -UseBasicParsing; ($r.Content | ConvertFrom-Json).x }' 1 0
  TcuCase 'CLEAN TWIN     Invoke-RestMethod is a site of its own (implicit parse)' 'function F($u) { $d = Invoke-RestMethod $u; $d.x }' 1 0
  $twoHop = '$a = git show x; $b = $a.Trim(); $c = $b -split '',''; $c'
  TcuCase 'MUST NOT FIRE  two assignments deep is outside the default one-hop bar' $twoHop 0 0
  $script:TcuMaxHops = 2
  TcuCase 'CLEAN TWIN     the same text is a site at -MaxHops 2' $twoHop 1 1
  $script:TcuMaxHops = $MaxHops
  $pyOut = & $TcuPython (Join-Path $here 'count_unchecked_child_parse.py') --selftest
  $pyRc = $LASTEXITCODE
  $cases++
  if ($pyRc -ne 0 -or -not (@($pyOut)[-1] -match 'self-test: PASS')) { $fails++; Write-Output ('FAIL CLEAN TWIN     the Python half''s own self-test passes  rc=' + $pyRc) }
  else { Write-Output ('PASS CLEAN TWIN     the Python half''s own self-test passes  (' + @($pyOut)[-1] + ')') }
  Write-Output ("count-unchecked-child-parse self-test: {0} ({1} of {2} cases pass)" -f $(if ($fails -eq 0) { 'PASS' } else { 'FAIL' }), ($cases - $fails), $cases)
  if ($fails -eq 0) { exit 0 } else { exit 1 }
}

# ---- the report -----------------------------------------------------------------------------------------------
if (-not $Root) { $Root = $repo }
$Root = (Resolve-Path $Root).Path
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try { $tracked = @(& git -C $Root ls-files -- '*.ps1' '*.py') ; $gitRc = $LASTEXITCODE } finally { $ErrorActionPreference = $prevEap }
if ($gitRc -ne 0 -or $tracked.Count -eq 0) {
  Write-Output ("count-unchecked-child-parse: BLIND - git ls-files exit " + $gitRc + ", " + $tracked.Count + " files. Nothing was examined; this proves nothing.")
  Write-Output 'COUNT-UNCHECKED-CHILD-PARSE-COMPLETE blind=1'
  exit 3
}
$live = @($tracked | Where-Object { $_ -notmatch '(^|/)archive/' })
$ps1 = @($live | Where-Object { $_ -like '*.ps1' })
$py = @($live | Where-Object { $_ -like '*.py' })
$rows = New-Object System.Collections.ArrayList
$unparsed = 0
foreach ($rel in $ps1) {
  $full = Join-Path $Root $rel
  $text = [IO.File]::ReadAllText($full)
  $r = Get-TcuSitesFromText $text $rel
  if ($null -eq $r) { $unparsed++; continue }
  foreach ($x in $r) { [void]$rows.Add($x) }
}
$tmp = Join-Path $env:TEMP ('tcu-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -ErrorAction Stop | Out-Null
try {
  $list = Join-Path $tmp 'py.txt'; $pyRows = Join-Path $tmp 'py.jsonl'
  [IO.File]::WriteAllText($list, (($py -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
  $pyOut = & $TcuPython (Join-Path $here 'count_unchecked_child_parse.py') --root $Root --files $list --out $pyRows --max-hops $MaxHops
  $pyRc = $LASTEXITCODE
  if ($pyRc -ne 0 -or -not (@($pyOut)[-1] -match '^COUNT-UNCHECKED-CHILD-PARSE-PY-COMPLETE')) {
    Write-Output ("count-unchecked-child-parse: BLIND - the Python half exited " + $pyRc + ". Nothing is reported for .py.")
    Write-Output 'COUNT-UNCHECKED-CHILD-PARSE-COMPLETE blind=1'
    exit 3
  }
  foreach ($l in [IO.File]::ReadAllLines($pyRows)) {
    if (-not $l.Trim()) { continue }
    $o = $l | ConvertFrom-Json
    if ($null -eq $o.file -or $null -eq $o.unguarded) { throw ('a Python row has the wrong shape: ' + $l) }
    [void]$rows.Add([ordered]@{ lang = 'py'; file = $o.file; line = $o.line; op = $o.op; class = $o.class; exit = $o.exit; shape = [bool]$o.shape; unguarded = [bool]$o.unguarded })
  }
  $pyNote = @($pyOut)[0]
} finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }

$S = $rows.Count
$U = @($rows | Where-Object { $_.unguarded }).Count
Write-Output ("count-unchecked-child-parse: scanned {0} .ps1 ({1} unparsed) and {2} .py ({3})" -f $ps1.Count, $unparsed, $py.Count, $pyNote)
Write-Output ("  U = {0} of S = {1} sites have neither an exit/status read nor a shape check" -f $U, $S)
foreach ($lang in 'ps1', 'py') {
  foreach ($cls in 'native', 'web') {
    $sub = @($rows | Where-Object { $_.lang -eq $lang -and $_.class -eq $cls })
    if ($sub.Count -eq 0) { continue }
    $ex = @{}; foreach ($e in 'read', 'implicit', 'none') { $ex[$e] = @($sub | Where-Object { $_.exit -eq $e }).Count }
    Write-Output ("  {0,-4} {1,-7} sites={2,4}  exit read={3} implicit={4} none={5}  shape-checked={6}  unguarded={7}" -f $lang, $cls, $sub.Count,
      $ex['read'], $ex['implicit'], $ex['none'], @($sub | Where-Object { $_.shape }).Count, @($sub | Where-Object { $_.unguarded }).Count)
  }
}
$sorted = @($rows | Sort-Object { $_.file }, { [int]$_.line })
if ($ShowSites) {
  foreach ($r in $sorted) { if ($r.unguarded) { Write-Output ("  U  {0}:{1}  {2} {3}" -f $r.file, $r.line, $r.class, $r.op) } }
}
if ($JsonOut) {
  $lines = foreach ($r in $sorted) { ([pscustomobject]$r | ConvertTo-Json -Compress) }
  [IO.File]::WriteAllText($JsonOut, (($lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
}
Write-Output ("COUNT-UNCHECKED-CHILD-PARSE-COMPLETE scanned={0} sites={1} unguarded={2}" -f ($ps1.Count + $py.Count), $S, $U)
exit 0
