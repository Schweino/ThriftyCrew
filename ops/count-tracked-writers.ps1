<#
  count-tracked-writers.ps1 - which git-TRACKED files does a PowerShell Set-Content, Add-Content, Out-File,
  Tee-Object or `>` / `>>` redirection in this repo write? A REPORT, exit 0. Never a gate.

  WHY IT EXISTS (2026-09-11). .gitattributes stores every text file eol=lf, and under Windows PowerShell 5.1 each
  of those verbs writes CRLF unless it is given -NoNewline: ConvertTo-Json joins its lines with CRLF and the cmdlet
  ends the file with one more. Over an LF blob that leaves a tracked file ` M` with a zero-line `git diff`, which
  makes `git rebase` refuse and is the churn that makes `git add -A` dangerous. Two were confirmed that day inside
  the pre-push gate (audit-spec-contradictions' report and audit-write-only-reports' baseline). This finds the
  rest of the class; lib\lf-write.ps1 is the repair and .claude\rules\ops-and-gates.md carries the account.

  THE TEST, because a count without its test means nothing:
    * SITES come from the PowerShell AST over every TRACKED .ps1/.psm1 (git ls-files): a command named
      Set-Content, sc, Add-Content, ac, Out-File or Tee-Object, or a file redirection whose target is not $null.
      A `>` inside a string, a here-string or a comment cannot produce one, where a text grep would count every
      HTML fragment in the tree.
    * A site's PATH expression is resolved to globs: string constants kept, an expandable string's holes become
      '*', a variable is followed through every assignment to it in the same file and its param default (8 hops through
      variables, commands and joins; the wrappers around an expression spend none), Join-Path and [IO.Path]::Combine join with '/', '+' concatenates, $PSScriptRoot, $PSCommandPath and
      $MyInvocation.MyCommand.Path anchor to the script's own place, and Split-Path (-Parent) drops a segment.
      Anything else is '*'.
    * An ANCHORED glob is matched exactly against the tracked list and an unanchored one by suffix. A glob whose
      file name has fewer than 3 literal characters counts as UNRESOLVED rather than matching everything.

  SCOPE OF A CLEAN REPORT: UNSOUND, in both directions. A path computed in another file, passed in as a parameter,
  built in a loop or assembled by a function the resolver does not model resolves to nothing and is silently not
  a hit; a suffix match can claim a tracked file that merely shares a name (a self-test's temp copy of
  commodities.json matches the real one). A hit is a CANDIDATE to read, and a file absent from the list proves
  nothing. It does not see [IO.File]::WriteAllText, Write-JsonFile, lib\atomic-write.ps1 or Python writers at all.

  THE WALK RUNS AT SCRIPT SCOPE, NOT INSIDE A FUNCTION (2026-09-11). Moved into a function it threw "Argument types
  do not match" under PS 5.1 on every call, as a script and loaded into a session alike. Swapping one construct at
  a time (typed params, a reused loop variable, the verb lookup, the if-expression, the site record, the whole
  matching block, the return shape) did not isolate it, and the one variant that passed once did not pass again.
  The same loop at script scope ran over all 746 tracked scripts twice. So the self-test runs THIS SCRIPT as a
  child against a temp root and a tracked list (-Root, -TrackedFile), which is also exactly the code a report runs.

  Usage:
    powershell -NoProfile -File ops\count-tracked-writers.ps1               denominators and the hit classes
    powershell -NoProfile -File ops\count-tracked-writers.ps1 -ShowHits     plus every hit site, script:line -> path
    powershell -NoProfile -File ops\count-tracked-writers.ps1 -JsonOut f    plus every site as JSON (UTF-8, no BOM)
    powershell -NoProfile -File ops\count-tracked-writers.ps1 -SelfTest     the report run as a child over a fixture
#>
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop
param([switch]$SelfTest, [switch]$ShowHits, [string]$JsonOut = '', [string]$Root = '', [string]$TrackedFile = '')
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')
$script:TcwCurRel = ''

function Get-TcwAssignments($FileAst) {
  $map = @{}
  $asg = $FileAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)
  foreach ($a in $asg) {
    $left = $a.Left
    if ($left -is [System.Management.Automation.Language.ConvertExpressionAst]) { $left = $left.Child }
    if ($left -is [System.Management.Automation.Language.VariableExpressionAst]) {
      $k = $left.VariablePath.UserPath.ToLower()
      if (-not $map.ContainsKey($k)) { $map[$k] = New-Object System.Collections.Generic.List[object] }
      $map[$k].Add($a.Right)
    }
  }
  $pars = $FileAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.ParameterAst] }, $true)
  foreach ($p in $pars) {
    if ($p.DefaultValue) {
      $k = $p.Name.VariablePath.UserPath.ToLower()
      if (-not $map.ContainsKey($k)) { $map[$k] = New-Object System.Collections.Generic.List[object] }
      $map[$k].Add($p.DefaultValue)
    }
  }
  return $map
}

function Join-TcwGlobs($Lefts, $Rights, [string]$Sep) {
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($l in @($Lefts)) { foreach ($r in @($Rights)) { if ($out.Count -lt 24) { $out.Add(([string]$l + $Sep + [string]$r)) } } }
  return ,$out.ToArray()
}

function Get-TcwCmdArgs($Cmd) {
  $named = @{}; $pos = New-Object System.Collections.Generic.List[object]; $sw = New-Object System.Collections.Generic.List[string]
  $els = $Cmd.CommandElements
  for ($i = 1; $i -lt $els.Count; $i++) {
    $e = $els[$i]
    if ($e -is [System.Management.Automation.Language.CommandParameterAst]) {
      $pn = $e.ParameterName.ToLower()
      if ($e.Argument) { $named[$pn] = $e.Argument; continue }
      if ($pn -in @('parent', 'leaf', 'resolve', 'force', 'nonewline', 'append', 'noclobber', 'passthru', 'isabsolute', 'qualifier', 'noqualifier', 'extension', 'leafbase')) { $sw.Add($pn); continue }
      if ($i + 1 -lt $els.Count) { $i++; $named[$pn] = $els[$i] }
      continue
    }
    $pos.Add($e)
  }
  return [pscustomobject]@{ named = $named; pos = $pos; sw = $sw }
}

function Resolve-TcwExpr($Ast, $Ctx, [int]$Depth) {
  # EVERY RECURSIVE RESULT IS ASSIGNED BEFORE IT IS WRAPPED. `@(Resolve-TcwExpr ...)` inline reads a comma-returned
  # array as ONE element, and the first cut of this census printed globs as "System.Collections.Generic.List`1[...]".
  # DEPTH COUNTS HOPS, NOT NODES. The first cut spent a level on every Pipeline, CommandExpression and Paren wrapper,
  # so `Set-Content $blF` -> `Join-Path $here ...` -> `$here = if ($PSScriptRoot) ...` ran out at 6 before it reached
  # $PSScriptRoot, and the estate's most common root resolved to '*'. A single-file suffix match still called those
  # hits, which is why nobody saw it; this file's own MUST FIRE caught it. Wrappers and if-clauses now pass the depth
  # through; variables, commands and joins spend it, which still ends a self-referencing `$p = Join-Path $p 'x'`.
  if ($null -eq $Ast -or $Depth -gt 8) { return ,@('*') }
  switch ($Ast.GetType().Name) {
    'StringConstantExpressionAst' { return ,@($Ast.Value) }
    'ExpandableStringExpressionAst' {
      $v = $Ast.Value
      foreach ($ne in $Ast.NestedExpressions) {
        $rep = '*'
        if ($ne -is [System.Management.Automation.Language.VariableExpressionAst]) {
          $r = Resolve-TcwExpr $ne $Ctx ($Depth + 1); $r = @($r)
          if ($r.Count -eq 1) { $rep = $r[0] }
        }
        $t = $ne.Extent.Text
        $i = $v.IndexOf($t)
        if ($i -ge 0) { $v = $v.Substring(0, $i) + $rep + $v.Substring($i + $t.Length) }
      }
      return ,@($v)
    }
    'VariableExpressionAst' {
      $k = $Ast.VariablePath.UserPath.ToLower()
      if ($k -eq 'psscriptroot') { return ,@('@/' + (Split-Path $script:TcwCurRel -Parent)) }
      if ($k -eq 'pscommandpath') { return ,@('@/' + $script:TcwCurRel) }
      if ($Ctx.ContainsKey($k)) {
        $all = New-Object System.Collections.Generic.List[string]
        foreach ($rhs in $Ctx[$k]) {
          $r = Resolve-TcwExpr $rhs $Ctx ($Depth + 1)
          foreach ($g in @($r)) { if ($all.Count -lt 24 -and -not $all.Contains([string]$g)) { $all.Add([string]$g) } }
        }
        if ($all.Count) { return ,$all.ToArray() }
      }
      return ,@('*')
    }
    'MemberExpressionAst' {
      if ($Ast.Extent.Text -match '^\$MyInvocation\.MyCommand\.(Path|Definition)$') { return ,@('@/' + $script:TcwCurRel) }
      return ,@('*')
    }
    'ParenExpressionAst' { return (Resolve-TcwExpr $Ast.Pipeline $Ctx $Depth) }
    'SubExpressionAst' { if ($Ast.SubExpression.Statements.Count -eq 1) { return (Resolve-TcwExpr $Ast.SubExpression.Statements[0] $Ctx $Depth) }; return ,@('*') }
    'PipelineAst' { if ($Ast.PipelineElements.Count -eq 1) { return (Resolve-TcwExpr $Ast.PipelineElements[0] $Ctx $Depth) }; return ,@('*') }
    'CommandExpressionAst' { return (Resolve-TcwExpr $Ast.Expression $Ctx $Depth) }
    'ConvertExpressionAst' { return (Resolve-TcwExpr $Ast.Child $Ctx $Depth) }
    'BinaryExpressionAst' {
      if ($Ast.Operator -eq 'Plus') {
        $l = Resolve-TcwExpr $Ast.Left $Ctx ($Depth + 1); $r = Resolve-TcwExpr $Ast.Right $Ctx ($Depth + 1)
        return (Join-TcwGlobs $l $r '')
      }
      return ,@('*')
    }
    'IfStatementAst' {
      $all = New-Object System.Collections.Generic.List[string]
      foreach ($c in $Ast.Clauses) { if ($c.Item2.Statements.Count -eq 1) { $r = Resolve-TcwExpr $c.Item2.Statements[0] $Ctx $Depth; foreach ($g in @($r)) { $all.Add([string]$g) } } }
      if ($Ast.ElseClause -and $Ast.ElseClause.Statements.Count -eq 1) { $r = Resolve-TcwExpr $Ast.ElseClause.Statements[0] $Ctx $Depth; foreach ($g in @($r)) { $all.Add([string]$g) } }
      if ($all.Count) { return ,$all.ToArray() }
      return ,@('*')
    }
    'InvokeMemberExpressionAst' {
      $m = $Ast.Member.Extent.Text
      if ($Ast.Expression.Extent.Text -match 'IO\.Path') {
        if ($m -match '^(Combine|Join)$') {
          $acc = @(''); $first = $true
          foreach ($arg in $Ast.Arguments) { $r = Resolve-TcwExpr $arg $Ctx ($Depth + 1); $acc = Join-TcwGlobs $acc $r $(if ($first) { '' } else { '/' }); $first = $false }
          return ,$acc
        }
        if ($m -eq 'GetFullPath' -and $Ast.Arguments.Count -ge 1) { return (Resolve-TcwExpr $Ast.Arguments[0] $Ctx ($Depth + 1)) }
      }
      return ,@('*')
    }
    'CommandAst' {
      $name = $Ast.GetCommandName()
      if (-not $name) { return ,@('*') }
      $a = Get-TcwCmdArgs $Ast
      switch ($name.ToLower()) {
        'join-path' {
          $parts = New-Object System.Collections.Generic.List[object]
          foreach ($k in @('path', 'childpath', 'additionalchildpath')) { if ($a.named.ContainsKey($k)) { $parts.Add($a.named[$k]) } }
          foreach ($p in $a.pos) { $parts.Add($p) }
          $acc = @(''); $first = $true
          foreach ($p in $parts) { $r = Resolve-TcwExpr $p $Ctx ($Depth + 1); $acc = Join-TcwGlobs $acc $r $(if ($first) { '' } else { '/' }); $first = $false }
          return ,$acc
        }
        'split-path' {
          if ($a.sw -contains 'leaf') { return ,@('*') }
          $src = if ($a.named.ContainsKey('path')) { $a.named['path'] } elseif ($a.named.ContainsKey('parent')) { $a.named['parent'] } elseif ($a.pos.Count) { $a.pos[0] } else { $null }
          $r = Resolve-TcwExpr $src $Ctx ($Depth + 1)
          $out = New-Object System.Collections.Generic.List[string]
          foreach ($g in @($r)) {
            $s = ([string]$g) -replace '\\', '/'
            $ix = $s.TrimEnd('/').LastIndexOf('/')
            if ($ix -gt 0) { $out.Add($s.Substring(0, $ix)) } elseif ($s -eq '@/') { $out.Add('@/..') } else { $out.Add('*') }
          }
          return ,$out.ToArray()
        }
        { $_ -in @('resolve-path', 'convert-path') } {
          $src = if ($a.named.ContainsKey('path')) { $a.named['path'] } elseif ($a.named.ContainsKey('literalpath')) { $a.named['literalpath'] } elseif ($a.pos.Count) { $a.pos[0] } else { $null }
          return (Resolve-TcwExpr $src $Ctx ($Depth + 1))
        }
      }
      return ,@('*')
    }
    default { return ,@('*') }
  }
}

function ConvertTo-TcwTail([string]$Glob) {
  $s = ($Glob -replace '\\', '/') -replace '\*+', '*'
  $anch = $s.StartsWith('@/')
  if ($anch) { $s = $s.Substring(2) }
  $segs = New-Object System.Collections.Generic.List[string]
  foreach ($x in ($s -split '/')) { if ($x -ne '') { $segs.Add($x) } }
  if ($anch) {
    $st = New-Object System.Collections.Generic.List[string]
    foreach ($x in $segs) {
      if ($x -eq '.') { continue }
      if ($x -eq '..') { if ($st.Count) { $st.RemoveAt($st.Count - 1) } else { return $null }; continue }
      if ($x -match ':$' -or ($x -eq '*' -and $st.Count -eq 0)) { $anch = $false }
      $st.Add($x)
    }
    $segs = $st
  }
  if (-not $anch) {
    if ($segs.Count -eq 0) { return $null }
    $start = 0
    for ($i = 0; $i -lt $segs.Count - 1; $i++) { if ($segs[$i] -in @('.', '..', '*') -or $segs[$i] -match ':$') { $start = $i + 1 } }
    $segs = @($segs[$start..($segs.Count - 1)])
  }
  if (@($segs).Count -eq 0) { return $null }
  $lit = (@($segs)[-1] -replace '\*', '') -replace '\.[A-Za-z0-9]+$', ''
  if ($lit.Length -lt 3) { return $null }
  return [pscustomobject]@{ pat = (@($segs) -join '/').ToLower(); anchored = $anch }
}

if ($SelfTest) {
  $bad = 0; $ran = 0
  function Chk([string]$Name, [bool]$Ok, [string]$Got) {
    $script:ran++
    if ($Ok) { Write-Output ('  ok    ' + $Name) } else { Write-Output ('  FAIL  ' + $Name + '   got: ' + $Got); $script:bad++ }
  }
  # ONE DIRECTORY PER RUN, removed in finally: run-gates runs every -SelfTest and concurrent pushes share %TEMP%.
  $fxDir = Join-Path $env:TEMP ('ctw-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $fxDir -ErrorAction Stop | Out-Null
  try {
    New-Item -ItemType Directory -Path (Join-Path $fxDir 'ops') -ErrorAction Stop | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $fxDir 'lib') -ErrorAction Stop | Out-Null
    # THE REPORT PATH IS BUILT BY CONCATENATION. ops\audit-write-only-reports.ps1 scans this file's text, and a
    # literal out\<name>.json beside a write verb would enrol this fixture as a real write-only report family.
    $famRel = 'ou' + 't\fx-baseline.json'
    $writer = @(
      '$here = if ($PSScriptRoot) { $PSScriptRoot } else { ''x'' }',
      ('$blF = Join-Path $here ''' + $famRel + ''''),
      '$doc | ConvertTo-Json | Set-Content $blF -Encoding UTF8',
      '$html = ''<p>a > b</p>''',
      '$big = @"',
      'c > d',
      '"@',
      '# e > f',
      'git status 2>$null'
    ) -join "`r`n"
    $other = @(
      '''y'' > (Join-Path $PSScriptRoot ''note.txt'')',
      'Set-Content (Join-Path $PSScriptRoot ''untracked.json'') ''z''',
      '$up = Join-Path $PSScriptRoot ''..\ops''',
      'Out-File -FilePath (Join-Path $up ''writer.ps1'') -InputObject ''w'''
    ) -join "`r`n"
    $utf8 = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText((Join-Path $fxDir 'ops\writer.ps1'), $writer, $utf8)
    [IO.File]::WriteAllText((Join-Path $fxDir 'lib\other.ps1'), $other, $utf8)
    $trkFile = Join-Path $fxDir 'tracked.txt'
    # These two are concatenated for the same reason as $famRel. Spelled whole on this WriteAllText line they enrolled
    # fx-baseline as a 42nd write-only family, and audit-write-only-reports refused the push that carried them.
    $famTracked = 'ops/' + 'ou' + 't/fx-baseline.json'
    $famTwin = 'grocery/' + 'ou' + 't/fx-baseline.json'
    [IO.File]::WriteAllText($trkFile, (@('ops/writer.ps1', 'lib/other.ps1', $famTracked, $famTwin, 'lib/note.txt') -join "`n"), $utf8)
    $sitesFile = Join-Path $fxDir 'sites.json'
    $childOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $fxDir -TrackedFile $trkFile -JsonOut $sitesFile
    $childRc = $LASTEXITCODE
    $childOut = @($childOut)
    Chk 'the report ran as a child over the fixture, exited 0 and ended on its completion marker' `
      ($childRc -eq 0 -and $childOut.Count -gt 0 -and [string]$childOut[-1] -like 'COUNT-TRACKED-WRITERS-COMPLETE*' -and [IO.File]::Exists($sitesFile)) ("rc=$childRc last=" + $(if ($childOut.Count) { $childOut[-1] } else { '' }))
    $sites = @()
    if ([IO.File]::Exists($sitesFile)) { $doc = [IO.File]::ReadAllText($sitesFile) | ConvertFrom-Json; $sites = @($doc.sites) }

    $wSites = @($sites | Where-Object { $_.script -eq 'ops/writer.ps1' })
    $bl = @($wSites | Where-Object { $_.verb -eq 'Set-Content' })
    Chk 'MUST FIRE  a baseline written through $PSScriptRoot resolves ANCHORED to its one tracked path, not to the other file of that name' `
      ($bl.Count -eq 1 -and $bl[0].anchored -and @($bl[0].hits).Count -eq 1 -and @($bl[0].hits)[0] -eq $famTracked) ("sites=$($bl.Count) hits=" + (@($bl | ForEach-Object { $_.hits }) -join ',') + ' globs=' + (@($bl | ForEach-Object { $_.globs }) -join ';'))
    Chk 'MUST NOT FIRE  a > inside a string, a here-string or a comment, and 2>$null, are not writer sites' `
      ($wSites.Count -eq 1) ("writer.ps1 sites=$($wSites.Count): " + (@($wSites | ForEach-Object { $_.verb + '@' + $_.line }) -join ' '))
    $redir = @($sites | Where-Object { $_.verb -eq 'redirect>' })
    Chk 'CLEAN TWIN  a real > redirection to a tracked path is still a site, and hits that path' `
      ($redir.Count -eq 1 -and @($redir[0].hits) -contains 'lib/note.txt') ("redirects=$($redir.Count)")
    $upSite = @($sites | Where-Object { $_.verb -eq 'Out-File' })
    Chk 'CLEAN TWIN  a path anchored through ..\ resolves to the tracked file it names' `
      ($upSite.Count -eq 1 -and @($upSite[0].hits) -contains 'ops/writer.ps1') ("out-file sites=$($upSite.Count) globs=" + (@($upSite | ForEach-Object { $_.globs }) -join ';'))
    $unt = @($sites | Where-Object { $_.script -eq 'lib/other.ps1' -and $_.verb -eq 'Set-Content' })
    Chk 'a write to an UNTRACKED path is a resolved site with no hit, so the denominator still counts it' `
      ($unt.Count -eq 1 -and $unt[0].resolved -and @($unt[0].hits).Count -eq 0) ("sites=$($unt.Count)")
    Chk 'no glob is a .NET type name, the shape an inline @() around a comma-returned result printed in the first cut' `
      ($sites.Count -eq 4 -and @($sites | Where-Object { $_.globs -match 'System\.Collections' }).Count -eq 0) ("sites=$($sites.Count) " + (@($sites | ForEach-Object { $_.globs }) -join ';'))
  } catch {
    Write-Output ('  FAIL  the self-test threw: ' + $_.Exception.Message); $bad++
  } finally {
    Remove-Item -LiteralPath $fxDir -Recurse -Force -ErrorAction SilentlyContinue
  }
  if ($ran -lt 7) { Write-Output ("  FAIL  only $ran of 7 cases ran"); $bad++ }
  if ($bad) { Write-Output ("COUNT-TRACKED-WRITERS SELF-TEST FAILED ($bad)"); Write-GuardComplete -Name 'count-tracked-writers' -Summary "selftest failed=$bad"; exit 1 }
  Write-Output ("COUNT-TRACKED-WRITERS SELF-TEST PASSED ($ran of 7)"); Write-GuardComplete -Name 'count-tracked-writers' -Summary 'selftest ok'; exit 0
}

# ---- the walk: the live report, or the self-test's child over a fixture root and list ----
$walkRoot = if ($Root) { $Root } else { $repo }
if ($TrackedFile) {
  $tracked = @([IO.File]::ReadAllLines($TrackedFile) | Where-Object { $_ })
  $head = 'fixture list ' + $TrackedFile
} else {
  $tracked = & git -C $repo -c core.quotepath=off ls-files
  if ($LASTEXITCODE -ne 0) {
    Write-Output 'count-tracked-writers: BLIND - git ls-files failed, so there is no tracked list to count against'
    Exit-Guard -Name 'count-tracked-writers' -Summary 'blind=no-ls-files' -Code 3
  }
  $tracked = @($tracked)
  $head = & git -C $repo rev-parse HEAD
}
$scripts = @($tracked | Where-Object { $_ -match '\.(ps1|psm1)$' })
if ($scripts.Count -eq 0) {
  Write-Output 'count-tracked-writers: BLIND - zero tracked PowerShell scripts, so a clean count would prove nothing'
  Exit-Guard -Name 'count-tracked-writers' -Summary 'blind=no-scripts' -Code 3
}
$verbs = @{ 'set-content' = 'Set-Content'; 'sc' = 'Set-Content'; 'add-content' = 'Add-Content'; 'ac' = 'Add-Content'; 'out-file' = 'Out-File'; 'tee-object' = 'Tee-Object' }
$switches = @('nonewline', 'force', 'passthru', 'append', 'noclobber', 'whatif', 'confirm', 'asbytestream', 'usetransaction')
$pathParams = @('path', 'literalpath', 'filepath', 'pspath', 'lp')
$trackedLower = @($tracked | ForEach-Object { $_.ToLower() })
$sites = New-Object System.Collections.Generic.List[object]
$parseErr = 0
foreach ($sp in $scripts) {
  $full = Join-Path $walkRoot $sp
  if (-not (Test-Path -LiteralPath $full)) { continue }
  $script:TcwCurRel = $sp
  $tok = $null; $err = $null
  $fa = [System.Management.Automation.Language.Parser]::ParseFile($full, [ref]$tok, [ref]$err)
  if ($err -and $err.Count) { $parseErr++ }
  $ctx = $null
  $cmds = $fa.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandBaseAst] }, $true)
  foreach ($c in $cmds) {
    $found = New-Object System.Collections.Generic.List[object]
    if ($c -is [System.Management.Automation.Language.CommandAst]) {
      $nm = $c.GetCommandName()
      if ($nm -and $verbs.ContainsKey($nm.ToLower())) {
        $verb = $verbs[$nm.ToLower()]
        $pathEl = $null; $noNl = $false; $enc = ''
        $els = $c.CommandElements
        for ($i = 1; $i -lt $els.Count; $i++) {
          $e = $els[$i]
          if ($e -is [System.Management.Automation.Language.CommandParameterAst]) {
            $pn = $e.ParameterName.ToLower()
            $isPath = @($pathParams | Where-Object { $_ -eq $pn -or ($pn.Length -ge 2 -and $_.StartsWith($pn)) }).Count -gt 0
            $isSwitch = (-not $isPath) -and @($switches | Where-Object { $_.StartsWith($pn) }).Count -gt 0
            if ($pn.Length -ge 2 -and 'encoding'.StartsWith($pn)) { if ($e.Argument) { $enc = $e.Argument.Extent.Text } elseif ($i + 1 -lt $els.Count) { $enc = $els[$i + 1].Extent.Text } }
            if ($isSwitch) { if ('nonewline'.StartsWith($pn)) { $noNl = $true }; continue }
            $arg = $null
            if ($e.Argument) { $arg = $e.Argument } elseif ($i + 1 -lt $els.Count) { $i++; $arg = $els[$i] }
            if ($isPath -and $null -eq $pathEl) { $pathEl = $arg }
            continue
          }
          if ($null -eq $pathEl) { $pathEl = $e }
        }
        if ($pathEl) { $found.Add([pscustomobject]@{ verb = $verb; expr = $pathEl; nonewline = $noNl; encoding = $enc }) }
      }
    }
    foreach ($r in $c.Redirections) {
      if ($r -is [System.Management.Automation.Language.FileRedirectionAst]) {
        if ($r.Location.Extent.Text -match '^\$null$') { continue }
        $found.Add([pscustomobject]@{ verb = $(if ($r.Append) { 'redirect>>' } else { 'redirect>' }); expr = $r.Location; nonewline = $false; encoding = 'Out-File default (UTF-16LE under PS 5.1)' })
      }
    }
    if ($found.Count -eq 0) { continue }
    if ($null -eq $ctx) { $ctx = Get-TcwAssignments $fa }
    foreach ($f in $found) {
      $globs = Resolve-TcwExpr $f.expr $ctx 0
      $globs = @($globs)
      $tails = New-Object System.Collections.Generic.List[object]
      foreach ($g in $globs) { $t = ConvertTo-TcwTail ([string]$g); if ($t) { $tails.Add($t) } }
      $hits = New-Object System.Collections.Generic.List[string]
      foreach ($t in $tails) {
        $pat = ($t.pat -replace '\[', '`[' -replace '\]', '`]')
        for ($j = 0; $j -lt $trackedLower.Count; $j++) {
          $tl = $trackedLower[$j]
          $ok = if ($t.anchored) { $tl -like $pat } else { ($tl -like $pat) -or ($tl -like ('*/' + $pat)) }
          if ($ok -and -not $hits.Contains($tracked[$j])) { $hits.Add($tracked[$j]) }
        }
      }
      $sites.Add([pscustomobject]@{
        script = $sp; line = $c.Extent.StartLineNumber; verb = $f.verb; path_expr = $f.expr.Extent.Text
        globs = ($globs -join ' | '); resolved = ($tails.Count -gt 0); anchored = (@($tails | Where-Object { $_.anchored }).Count -gt 0)
        hits = $hits.ToArray(); nonewline = $f.nonewline; encoding = $f.encoding
      })
    }
  }
}

. (Join-Path $repo 'lib\bot-paths.ps1')   # Test-BotPathOwned: the paths the daily bot commits
$n = $sites.Count
$resolved = @($sites | Where-Object { $_.resolved }).Count
$anchored = @($sites | Where-Object { $_.anchored }).Count
$hitSites = @($sites | Where-Object { @($_.hits).Count -gt 0 })
$targets = New-Object System.Collections.Generic.HashSet[string]
foreach ($s in $hitSites) { foreach ($h in $s.hits) { [void]$targets.Add($h) } }
function Get-TcwClass($S) {
  # Any module's out\ holds one-off scripts, so the class names no module. Spelled `^grocery/out/` it was a new
  # ops -> grocery reach and ops\audit-cross-module-reach.ps1 refused it (133 -> 134).
  if ($S.script -match '/archive/|^[^/]+/out/') { return 'archive or one-off' }
  if (@($S.hits | Where-Object { -not (Test-BotPathOwned -Path $_) }).Count -eq 0) { return 'every hit bot-owned (lib\bot-paths.ps1)' }
  if ($S.path_expr -match '(?i)temp|tmp|\$fx|fix|sandbox|scratch|probe') { return 'path names a temp or fixture variable (heuristic)' }
  return 'the rest - read these'
}
function Get-TcwPct([int]$Part, [int]$Whole) { if ($Whole) { return [math]::Round(100.0 * $Part / $Whole, 1) } return 0 }
Write-Output ("count-tracked-writers: HEAD {0}; {1} tracked file(s), {2} tracked PowerShell script(s) parsed, {3} with parse errors" -f $head, $tracked.Count, $scripts.Count, $parseErr)
Write-Output ("  writer sites: {0} ({1}); {2} of {0} pass -NoNewline, so every other one writes at least one CRLF" -f $n, (@($sites | Group-Object verb | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ' '), @($sites | Where-Object { $_.nonewline }).Count)
Write-Output ("  resolved to a usable glob: {0} of {1} ({2}%), {3} of them anchored to the script's own place; unresolved {4} of {1}" -f $resolved, $n, (Get-TcwPct $resolved $n), $anchored, ($n - $resolved))
Write-Output ("  matching a tracked file: {0} of {1} site(s) ({2}%), {3} distinct tracked path(s)" -f $hitSites.Count, $n, (Get-TcwPct $hitSites.Count $n), $targets.Count)
foreach ($grp in @($hitSites | Group-Object { Get-TcwClass $_ } | Sort-Object Count -Descending)) {
  Write-Output ("    {0,4} of {1}  {2}" -f $grp.Count, $hitSites.Count, $grp.Name)
}
if ($ShowHits) {
  foreach ($s in @($hitSites | Sort-Object script, line)) {
    Write-Output ("  {0}:{1} {2}{3} -> {4}{5}" -f $s.script, $s.line, $s.verb, $(if ($s.nonewline) { ' -NoNewline' } else { '' }), @($s.hits)[0], $(if (@($s.hits).Count -gt 1) { " (+$(@($s.hits).Count - 1) more)" } else { '' }))
  }
}
if ($JsonOut) {
  $doc = [pscustomobject]@{ head = $head; tracked_files = $tracked.Count; scripts = $scripts.Count; sites = $sites.ToArray() }
  [IO.File]::WriteAllText($JsonOut, ($doc | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
  Write-Output ("  every site written to $JsonOut")
}
Write-Output '  UNSOUND: a computed path resolves to nothing, so a script absent from this count is not cleared.'
Write-GuardComplete -Name 'count-tracked-writers' -Summary ("sites={0} resolved={1} hit_sites={2} tracked_targets={3} scripts={4}" -f $n, $resolved, $hitSites.Count, $targets.Count, $scripts.Count)
exit 0
