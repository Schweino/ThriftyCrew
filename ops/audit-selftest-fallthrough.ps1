<#
  audit-selftest-fallthrough.ps1 - a self-test block that can end without leaving runs the live work below it.

  SCOPE OF A CLEAN REPORT: UNSOUND. It reads the PowerShell AST of every tracked .ps1 and checks only a TOP-LEVEL
    `if` (a statement of the script's own body) gated on a self-test switch spelled the ways THE RULE lists. A clean
    report means no such block can reach the statements after it. A self-test gated inside a function, a try, a
    begin or process block, or on any other spelling is not read, and a block that does leave on every path can
    still do live work INSIDE itself. An exit inside a helper other than Exit-Guard is not credited, so that
    direction is loud rather than silent. A reported site is real control flow; silence is not proof.

  WHY THIS EXISTS (2026-09-11). Commit 8253ded82 joined grocery\pull-grocery-ads.ps1's last self-test case and its
  verdict onto one line:
      _T '...' (...)  if ($fail -eq 0) { ...; exit 0 } else { ...; exit 1 }
  The parser made the if, its condition, both scriptblocks and the else into arguments of _T, so the -SelfTest
  branch held no exit at all. Control fell out of it into the LIVE pull of Hy-Vee, Aldi and Family Fare, the script
  wrote out\ads-<today>.json into whatever checkout ran it, and exited 0. run-gates runs every -SelfTest on every
  push, so from the 13:50 push that day every push from every session did a live three-store pull and scored the
  suite ok. The main checkout's copy, written by that push's own gate at 13:47:16, became the ads source of the
  board published at 15:03. By 16:16 28 worktrees held another copy, the newest pulled 32 minutes after the repair
  reached origin/main by a branch not yet rebased onto it, and 15 of the 29 files were short reads with Family Fare
  at 100 to 900 of its 1,045 rows, each still marked PASS.
  Three repairs landed that day and this is the fourth, because each of the others is narrower than the class.
  dbd92279f put the verdict back on its own line and ops\audit-keyword-arguments.ps1 fails that SPELLING.
  4ac43c532 gave that ONE file a refusal after its block. run-gates now reads every self-test's own verdict
  (lib\selftest-verdict.ps1) and scores an exit 0 without one as 3. The verdict check is the strongest of them and
  it is still a RUNTIME read: the self-test has already run the live work by the time it speaks, which here means
  the three-store pull happened and only the push was stopped. Its own header names the case it cannot see, a
  passing fall-through into a path that prints nothing. This file is static and reads source only, so it stops the
  push before anything runs, and it covers every self-test block rather than the one file that got a guard: a
  verdict if with no else, a catch that swallows, a deleted exit line, or a glued statement the keyword audit does
  not list all leave the block the same way, and the parser sees every one of them.

  THE RULE. A self-test gate is a top-level `if` any of whose clauses is conditioned on `$SelfTest`, a renamed
  `$<Name>SelfTest`, or the dot-sourced libraries' `$__<name>SelfTest`, alone or as one operand of an -or chain
  (the spellings lib\selftest-discovery.ps1 enrols). When any statement other than a function definition follows
  that `if` in the script body, the gated clause must END on every path. A block ends when one of its statements
  ends, and a statement ends when it is:
      exit, throw or return;
      an if whose every clause and an else end;
      a try whose finally ends, or whose body and every catch end;
      a call to Exit-Guard (lib\guard-contract.ps1), which writes the COMPLETE marker and exits. The self-test
        parses that function and requires its body still to end on an exit, so the credit cannot go stale silently.
  One site per gated clause, naming its line and the statement it ends on.

  WHAT IT DELIBERATELY DOES NOT FLAG.
    * A gate followed by nothing but function definitions. Falling out of it ends the script.
    * A gate whose live work sits in its own else with nothing after the if.
    * A negated condition (`if (-not $SelfTest)`) or `$SelfTest -and $x`. Neither gates a self-test.
    * The founding shape quoted in a comment or a string, which the parser never turns into statements.

  A GATE AT ZERO, NOT A RATCHET. MEASURED 2026-09-11 through this file, from a linked worktree at 46085e69f plus
  this change: git listed 761 tracked .ps1, the walk resolved 760 (never itself), 274 top-level self-test gates,
  0 sites, about 6 s. A scratch probe carrying the same rule over the 750 tracked .ps1 of 88f7d5479 counted 52 of
  that day's 263 gates ending on Exit-Guard. With grocery\import-aldi-batch.ps1 at its 46085e69f blob the same live
  run exited 1 with one site, :18, a shim whose gate only appended -SelfTest to its child's arguments and fell out
  to the call below. It now calls the child and exits inside its gate, and its -SelfTest output is byte-identical
  (SHA-256) before and after. With grocery\pull-grocery-ads.ps1 put back to its 8253ded82 blob, over this same
  tree, the run exited 1 with one site, :200 (ops\audit-keyword-arguments.ps1 named :273 in that file). Every
  swapped file was restored and checked by hash. So the day-one count is zero, and any site is new.
  MUTATION PROBE, same day, from temp mirrors with the original's md5 unchanged: the unmutated control passed 26 of
  26, and 9 of 9 single mutants went red, each in the case aimed at it (an if with no else credited, catch ignored,
  finally ignored, Exit-Guard uncredited, the after-check dropped, no -or split, first clause only, gate regex
  unanchored, function definitions counted as live work).

  DISCOVERY. Every .ps1 under the root, excluded on the path BELOW the root (lib\tree-walk.ps1), never this file,
  and only the paths `git ls-files` lists, so untracked scratch in one checkout cannot make a push red in that
  checkout alone. The same walk as ops\audit-keyword-arguments.ps1.

  EXIT CODES (lib\guard-contract.ps1 vocabulary): 0 no site, 1 at least one site, 3 could not evaluate (git listed
  nothing, or the walk resolved nothing). Read the verdict LINE, not the number.

    ops\audit-selftest-fallthrough.ps1             scan the tracked tree
    ops\audit-selftest-fallthrough.ps1 -SelfTest   the rule over fixture files, each shape run as a child, the walk
#>
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop (2026-09-07)
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\tree-walk.ps1')   # Get-TcRootFull, Get-TcPathBelowRoot, New-TcWorktreeFixture

$script:SFT_ENDING_COMMANDS = @('Exit-Guard')
$script:SFT_WALK_EXCLUDE = '\\work' + 'trees\\|\\\.git\\|node_modules'

function Test-SftGateCondition {
  <# True when an if-clause condition is a self-test switch alone, or one operand of an -or chain. #>
  param($Condition)
  foreach ($op in [regex]::Split([string]$Condition.Extent.Text, '(?i)\s-or\s')) {
    if ($op.Trim() -match '^\$(script:)?\w*SelfTest$') { return $true }
  }
  return $false
}

function Get-SftBlockEnd {
  <# How a statement block leaves on every path, or '' when some path carries on past it. $Block is a
     StatementBlockAst or a NamedBlockAst; both carry .Statements. #>
  param($Block)
  if ($null -eq $Block) { return '' }
  foreach ($s in $Block.Statements) {
    $e = Get-SftStatementEnd $s
    if ($e) { return $e }
  }
  return ''
}

function Get-SftStatementEnd {
  <# 'exit', 'throw', 'return', 'if/else', 'finally', 'try', an ending command's name, or ''. #>
  param($Statement)
  if ($Statement -is [System.Management.Automation.Language.ExitStatementAst])   { return 'exit' }
  if ($Statement -is [System.Management.Automation.Language.ThrowStatementAst])  { return 'throw' }
  if ($Statement -is [System.Management.Automation.Language.ReturnStatementAst]) { return 'return' }
  if ($Statement -is [System.Management.Automation.Language.IfStatementAst]) {
    if ($null -eq $Statement.ElseClause) { return '' }
    foreach ($c in $Statement.Clauses) { if (-not (Get-SftBlockEnd $c.Item2)) { return '' } }
    if (-not (Get-SftBlockEnd $Statement.ElseClause)) { return '' }
    return 'if/else'
  }
  if ($Statement -is [System.Management.Automation.Language.TryStatementAst]) {
    if ($Statement.Finally -and (Get-SftBlockEnd $Statement.Finally)) { return 'finally' }
    if (-not (Get-SftBlockEnd $Statement.Body)) { return '' }
    foreach ($c in $Statement.CatchClauses) { if (-not (Get-SftBlockEnd $c.Body)) { return '' } }
    return 'try'
  }
  if ($Statement -is [System.Management.Automation.Language.PipelineAst] -and $Statement.PipelineElements.Count -eq 1 -and
      $Statement.PipelineElements[0] -is [System.Management.Automation.Language.CommandAst]) {
    $n = [string]$Statement.PipelineElements[0].GetCommandName()
    if ($n -and ($script:SFT_ENDING_COMMANDS -contains $n)) { return $n }
  }
  return ''
}

function Get-SftFindings {
  <# One file, parsed from disk exactly as the live scan parses it.
     Returns @{ Findings = @({Line; Gate; EndsOn; After}); Gates; ParseErrors }. #>
  param([string]$Path)
  $tok = $null; $err = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tok, [ref]$err)
  $parseErrors = if ($null -eq $err) { 0 } else { $err.Count }
  $out = New-Object System.Collections.ArrayList
  $gates = 0
  if ($ast.EndBlock) {
    $top = $ast.EndBlock.Statements
    for ($i = 0; $i -lt $top.Count; $i++) {
      if ($top[$i] -isnot [System.Management.Automation.Language.IfStatementAst]) { continue }
      $after = 0
      for ($j = $i + 1; $j -lt $top.Count; $j++) {
        if ($top[$j] -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $after++ }
      }
      foreach ($c in $top[$i].Clauses) {
        if (-not (Test-SftGateCondition $c.Item1)) { continue }
        $gates++
        if ($after -eq 0) { continue }
        if (Get-SftBlockEnd $c.Item2) { continue }
        $stmts = $c.Item2.Statements
        $last = if ($stmts.Count) { ($stmts[$stmts.Count - 1].Extent.Text -replace '\s+', ' ').Trim() } else { '(an empty block)' }
        if ($last.Length -gt 120) { $last = $last.Substring(0, 120) + '...' }
        [void]$out.Add([pscustomobject]@{ Line = $c.Item1.Extent.StartLineNumber; Gate = [string]$c.Item1.Extent.Text; EndsOn = $last; After = $after })
      }
    }
  }
  return [pscustomobject]@{ Findings = $out.ToArray(); Gates = $gates; ParseErrors = $parseErrors }
}

function Get-SftScanFiles {
  <# Every .ps1 under $RootDir, excluded on the path BELOW the root (lib\tree-walk.ps1), never $Self, and when
     $Tracked is given only the root-relative paths it holds. Same walk as ops\audit-keyword-arguments.ps1. #>
  param([string]$RootDir, [string]$Self = '', $Tracked = $null)
  $rootFull = Get-TcRootFull $RootDir
  Get-TcTreeFiles -RootFull $rootFull -Filter *.ps1 -PruneBelow $script:SFT_WALK_EXCLUDE |
    Where-Object {
      $below = Get-TcPathBelowRoot $_.FullName $rootFull
      ($_.Extension -ieq '.ps1') -and ($below -notmatch $script:SFT_WALK_EXCLUDE) -and
      (-not [string]::Equals($_.FullName, $Self, [StringComparison]::OrdinalIgnoreCase)) -and
      ($null -eq $Tracked -or $Tracked.Contains($below.TrimStart('\')))
    } |
    Sort-Object FullName
}

# ------------------------------------------------------------------------------------------- self-test
if ($SelfTest) {
  $script:fail = 0; $script:cases = 0
  function SftT([string]$m, [bool]$c, [string]$got = '') {
    $script:cases++
    if ($c) { Write-Output ('  ok    ' + $m) } else { Write-Output ('  FAIL  ' + $m + '   got: ' + $got); $script:fail++ }
  }
  function SftGot($r) { return ('gates=' + $r.Gates + ' sites=' + $r.Findings.Count + ' ' + (($r.Findings | ForEach-Object { 'line ' + $_.Line + ' ends on [' + $_.EndsOn + ']' }) -join '; ')) }

  # EVERY TEMP PATH IS PER RUN (.claude/rules/ops-and-gates.md): run-gates runs this from every pushing session at
  # once, so each path comes from SftScratch under a directory no other run can name, made with -ErrorAction Stop so a
  # clash refuses rather than shares, and removed whole in the finally below.
  $sftRoot = Join-Path ([IO.Path]::GetTempPath()) ('sft-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $sftRoot -ErrorAction Stop | Out-Null
  function SftScratch([string]$Leaf) { return (Join-Path $sftRoot $Leaf) }

  # FIXTURE FILES, written as `~` for `$` so this source never spells a gate the live scan could read.
  function New-SftText([string[]]$Lines) { return (($Lines -join "`n").Replace('~', '$')) }
  function New-SftFixture([string]$Name, [string[]]$Lines) {
    $p = SftScratch ($Name + '.ps1')
    [IO.File]::WriteAllText($p, (New-SftText $Lines), (New-Object Text.UTF8Encoding($false)))
    return $p
  }
  $head = @('param([string]~OutDir = ''.'', [switch]~SelfTest)', '~ErrorActionPreference = ''Stop''')
  $live = @('[IO.File]::WriteAllText((Join-Path ~OutDir ''live-marker.txt''), ''live'')', 'Write-Output ''LIVE WORK RAN''')
  $tHelper = '  function _T([string]~label, [bool]~cond) { ~script:n++; if (~cond) { Write-Output "ok    ~label" } else { Write-Output "FAIL  ~label"; ~script:fail++ } }'
  $tGlued = '  _T ''the last case'' (1 -eq 1)  if (~fail -eq 0) { Write-Output "SELF-TEST PASS: ~n case(s)"; exit 0 } else { Write-Output "SELF-TEST FAIL: ~fail of ~n case(s)"; exit 1 }'
  $tCase = '  _T ''the last case'' (1 -eq 1)'
  $tVerdict = '  if (~fail -eq 0) { Write-Output "SELF-TEST PASS: ~n case(s)"; exit 0 } else { Write-Output "SELF-TEST FAIL: ~fail of ~n case(s)"; exit 1 }'

  function Invoke-SftChild([string]$Path, [string[]]$ArgList) {
    # Out of process, because the defect IS what happens after the block should have left. Output to files and the
    # exit code read straight after the call, with no pipe in between.
    # Numbered per call: one fixture runs both with and without the switch, and a shared name would clash.
    $script:sftChildN++
    $name = [IO.Path]::GetFileNameWithoutExtension($Path) + '-' + $script:sftChildN
    $od = SftScratch ('out-' + $name)
    New-Item -ItemType Directory -Path $od -ErrorAction Stop | Out-Null
    $so = SftScratch ($name + '.out.txt'); $se = SftScratch ($name + '.err.txt')
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & (Join-Path $PSHOME 'powershell.exe') -NoProfile -ExecutionPolicy Bypass -File $Path -OutDir $od @ArgList > $so 2> $se; $rc = $LASTEXITCODE }
    finally { $ErrorActionPreference = $prev }
    $text = if (Test-Path -LiteralPath $so) { [IO.File]::ReadAllText($so) } else { '' }
    $marker = Test-Path -LiteralPath (Join-Path $od 'live-marker.txt')
    return [pscustomobject]@{ Rc = $rc; Text = $text; Marker = $marker; Got = ('rc={0} marker={1} out=[{2}]' -f $rc, $marker, (($text -replace '\s+', ' ').Trim())) }
  }

  try {
    $fFounding = New-SftFixture 'founding' ($head + @('if (~SelfTest) {', '  ~fail = 0; ~n = 0', $tHelper, $tGlued, '}') + $live)
    $fRepaired = New-SftFixture 'repaired' ($head + @('if (~SelfTest) {', '  ~fail = 0; ~n = 0', $tHelper, $tCase, $tVerdict, '}') + $live)
    $fGuarded  = New-SftFixture 'guarded'  ($head + @('if (~SelfTest) {', '  ~fail = 0; ~n = 0', $tHelper, $tGlued,
                   '  Write-Output ''SELF-TEST FAIL: the verdict did not exit, so the block stopped here''', '  exit 1', '}') + $live)
    # The library path arrives as an argument, never inside the fixture text, where a `~` in it would become `$`.
    $gcLib = Join-Path $repo 'lib\guard-contract.ps1'
    $fExitGuard = New-SftFixture 'exitguard' (@('param([string]~OutDir = ''.'', [switch]~SelfTest, [string]~GuardLib)', '~ErrorActionPreference = ''Stop''', '. ~GuardLib',
                   'if (~SelfTest) {', '  Write-Output ''cases ran''', '  Exit-Guard -Name ''sft-fixture'' -Summary ''selftest pass'' -Code 0', '}') + $live)

    # ---- MUST FIRE ------------------------------------------------------------------------------------
    $r = Get-SftFindings -Path $fFounding
    SftT 'MUST FIRE  the founding shape from 8253ded82: one gate, one site, ending on the _T call that swallowed the verdict' ($r.Gates -eq 1 -and $r.Findings.Count -eq 1 -and $r.Findings[0].Line -eq 3 -and $r.Findings[0].EndsOn -like '_T *') (SftGot $r)
    $r = Get-SftFindings -Path (New-SftFixture 'ifnoelse' ($head + @('if (~SelfTest) {', '  ~fail = 1', '  if (~fail) { exit 1 }', '}') + $live))
    SftT 'MUST FIRE  a verdict if with no else leaves only when a case failed, so a green run falls into the live work' ($r.Findings.Count -eq 1 -and $r.Findings[0].EndsOn -eq 'if ($fail) { exit 1 }') (SftGot $r)
    $r = Get-SftFindings -Path (New-SftFixture 'catch' ($head + @('if (~SelfTest) {', '  try { Invoke-Cases; exit 0 }', '  catch { Write-Output ~_.Exception.Message }', '}') + $live))
    SftT 'MUST FIRE  a try that exits but whose catch only reports: a throwing case falls out of the block' ($r.Findings.Count -eq 1) (SftGot $r)
    $r = Get-SftFindings -Path (New-SftFixture 'renamed' (@('param([switch]~FfPriceSelfTest)', 'if (~Verbose -or ~FfPriceSelfTest) {', '  Write-Output ''cases ran''', '}') + $live))
    SftT 'MUST FIRE  a renamed switch read as one operand of an -or chain is a gate like any other' ($r.Gates -eq 1 -and $r.Findings.Count -eq 1) (SftGot $r)
    $r = Get-SftFindings -Path (New-SftFixture 'gluedexit' ($head + @('if (~SelfTest) {', '  Write-Output ''done''  exit 0', '}') + $live))
    SftT 'MUST FIRE  a glued exit is an argument to Write-Output, so the block ends on the Write-Output and falls through' ($r.Findings.Count -eq 1 -and $r.Findings[0].EndsOn -like 'Write-Output*') (SftGot $r)
    $r = Get-SftFindings -Path (New-SftFixture 'elsegate' ($head + @('if (~Apply) {', '  Write-Output ''apply''', '} elseif (~SelfTest) {', '  Write-Output ''cases ran''', '}') + $live))
    SftT 'MUST FIRE  a gate in an elseif clause is checked on its own clause, and the site names that clause''s line' ($r.Gates -eq 1 -and $r.Findings.Count -eq 1 -and $r.Findings[0].Line -eq 5) (SftGot $r)

    # ---- MUST NOT FIRE -------------------------------------------------------------------------------
    $r = Get-SftFindings -Path $fRepaired
    SftT 'MUST NOT FIRE  the repair: the verdict on its own line is an if/else whose both arms exit' ($r.Gates -eq 1 -and $r.Findings.Count -eq 0) (SftGot $r)
    $r = Get-SftFindings -Path $fGuarded
    SftT 'MUST NOT FIRE  a glued verdict followed by an unconditional exit 1 cannot fall through (the keyword audit still names the glue)' ($r.Gates -eq 1 -and $r.Findings.Count -eq 0) (SftGot $r)
    $r = Get-SftFindings -Path $fExitGuard
    SftT 'MUST NOT FIRE  a block that ends on Exit-Guard, the way 52 self-tests here end' ($r.Gates -eq 1 -and $r.Findings.Count -eq 0) (SftGot $r)
    $r = Get-SftFindings -Path (New-SftFixture 'finally' ($head + @('if (~SelfTest) {', '  try { ~x = 1 }', '  finally { Write-Output ''cleaned'' }', '  return', '}') + $live))
    SftT 'MUST NOT FIRE  a try/finally followed by return: return leaves a script from its top level' ($r.Findings.Count -eq 0) (SftGot $r)
    $r = Get-SftFindings -Path (New-SftFixture 'finallyexit' ($head + @('if (~SelfTest) {', '  try { Invoke-Cases }', '  finally { exit 0 }', '}') + $live))
    SftT 'MUST NOT FIRE  an exit in a finally leaves on every path, whatever the body does' ($r.Findings.Count -eq 0) (SftGot $r)
    $r = Get-SftFindings -Path (New-SftFixture 'nothingafter' (@('~__xySelfTest = (~MyInvocation.InvocationName -ne ''.'') -and (~args -contains ''-SelfTest'')',
           'function Get-Thing { 1 }', 'if (~__xySelfTest) {', '  Write-Output ''cases ran''', '}', 'function Get-Other { 2 }')))
    SftT 'MUST NOT FIRE  the dot-sourced library shape with only function definitions after its gate: falling out ends the script' ($r.Gates -eq 1 -and $r.Findings.Count -eq 0) (SftGot $r)
    $r = Get-SftFindings -Path (New-SftFixture 'elselive' ($head + @('if (~SelfTest) {', '  Write-Output ''cases ran''', '} else {') + $live + @('}')))
    SftT 'MUST NOT FIRE  live work in the gate''s own else with nothing after the if' ($r.Gates -eq 1 -and $r.Findings.Count -eq 0) (SftGot $r)
    $r = Get-SftFindings -Path (New-SftFixture 'notgates' ($head + @('if (-not ~SelfTest) { Write-Output ''live'' }', 'if (~SelfTest -and ~Apply) { Write-Output ''both'' }', 'if (~Apply) { Write-Output ''apply'' }') + $live))
    SftT 'MUST NOT FIRE  a negated switch, a switch -and another condition, and an unrelated switch are not self-test gates' ($r.Gates -eq 0 -and $r.Findings.Count -eq 0) (SftGot $r)
    $r = Get-SftFindings -Path (New-SftFixture 'prose' ($head + @('# was: if (~SelfTest) { _T ''x'' (1)  if (~fail -eq 0) { exit 0 } }', '~s = ''if (~SelfTest) { Write-Output 1 }''') + $live))
    SftT 'MUST NOT FIRE  the founding shape quoted in a comment and inside a string is not a gate' ($r.Gates -eq 0 -and $r.Findings.Count -eq 0) (SftGot $r)

    # ---- THE RULE MATCHES WHAT POWERSHELL DOES: each shape run as a child, with -OutDir in this run's scratch ----
    $c = Invoke-SftChild $fFounding @('-SelfTest')
    SftT 'MUST FIRE  run with -SelfTest, the founding shape exits 0 with no verdict line and its live work writes the marker' ($c.Rc -eq 0 -and $c.Marker -and $c.Text -match 'LIVE WORK RAN' -and $c.Text -notmatch 'SELF-TEST PASS') $c.Got
    $c = Invoke-SftChild $fGuarded @('-SelfTest')
    SftT 'MUST FIRE  run with -SelfTest, the same glued verdict closed by an unconditional exit 1 stops on its refusal line with exit 1' ($c.Rc -eq 1 -and $c.Text -match 'the verdict did not exit' -and $c.Text -notmatch 'LIVE WORK RAN') $c.Got
    $c = Invoke-SftChild $fRepaired @('-SelfTest')
    SftT 'CLEAN TWIN  run with -SelfTest, the repaired shape prints its verdict and exits 0' ($c.Rc -eq 0 -and $c.Text -match 'SELF-TEST PASS: 1 case') $c.Got
    $c = Invoke-SftChild $fExitGuard @('-SelfTest', '-GuardLib', $gcLib)
    SftT 'CLEAN TWIN  run with -SelfTest, a block ending on Exit-Guard exits 0 on its COMPLETE marker line' ($c.Rc -eq 0 -and $c.Text -match 'SFT-FIXTURE-COMPLETE selftest pass' -and $c.Text -notmatch 'LIVE WORK RAN') $c.Got
    $c = Invoke-SftChild $fRepaired @()
    SftT 'CLEAN TWIN  run WITHOUT -SelfTest, the repaired shape still does its live work and writes the marker, so the fixtures'' live path is real' ($c.Rc -eq 0 -and $c.Marker -and $c.Text -match 'LIVE WORK RAN') $c.Got

    # ---- THE ONE CREDITED COMMAND STILL EARNS ITS CREDIT ------------------------------------------------
    $gcTok = $null; $gcErr = $null
    $gcAst = [System.Management.Automation.Language.Parser]::ParseFile($gcLib, [ref]$gcTok, [ref]$gcErr)
    $gcFn = @($gcAst.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'Exit-Guard' }, $false))
    $gcEnd = if ($gcFn.Count -eq 1) { Get-SftBlockEnd $gcFn[0].Body.EndBlock } else { '' }
    SftT 'CLEAN TWIN  lib\guard-contract.ps1 defines Exit-Guard once and its body still ends on exit, so crediting it is still true' ($gcFn.Count -eq 1 -and $gcEnd -eq 'exit') ('defined={0} ends={1}' -f $gcFn.Count, $gcEnd)

    # ---- THE WALK, FROM A WORKTREE ROOT (lib\tree-walk.ps1) -------------------------------------------
    $wtFx = New-TcWorktreeFixture -Files @{ 'store\fallthrough.ps1' = [IO.File]::ReadAllText($fFounding); 'ops\ends.ps1' = [IO.File]::ReadAllText($fRepaired)
                                            'ops\untracked.ps1' = [IO.File]::ReadAllText($fFounding); 'ops\me.ps1' = 'Write-Output 2' }
    try {
      $self = Join-Path $wtFx.Root 'ops\me.ps1'
      $found = Get-SftScanFiles -RootDir $wtFx.Root -Self $self
      $found = @($found)
      $hits = Measure-TcWorktreeFixture -Fixture $wtFx -Found $found
      SftT 'MUST FIRE  a root that IS a worktree is scanned, not excluded whole (three .ps1, not itself)' ($hits.Root -eq 3) ('root=' + $hits.Root)
      SftT 'MUST NOT FIRE  a sibling worktree BELOW that root is still excluded' ($hits.Sibling -eq 0) ('sibling=' + $hits.Sibling)
      SftT 'MUST NOT FIRE  the detector never scans itself' (@($found | Where-Object { $_.FullName -eq $self }).Count -eq 0) ''
      $trk = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
      foreach ($p in @('store\fallthrough.ps1', 'ops\ends.ps1', 'ops\me.ps1')) { [void]$trk.Add($p) }
      $tFound = Get-SftScanFiles -RootDir $wtFx.Root -Self $self -Tracked $trk
      $tFound = @($tFound)
      $tNames = ($tFound | ForEach-Object { $_.Name }) -join ','
      SftT 'MUST NOT FIRE  an untracked file is not scanned when git''s list is given' (@($tFound | Where-Object { $_.Name -eq 'untracked.ps1' }).Count -eq 0) $tNames
      $sites = 0
      foreach ($f in $tFound) { $sites += (Get-SftFindings -Path $f.FullName).Findings.Count }
      SftT 'CLEAN TWIN  the tracked walk still reads both tracked files and reports the one that falls through: 2 files, 1 site' ($tFound.Count -eq 2 -and $sites -eq 1) ("files={0} sites={1} names={2}" -f $tFound.Count, $sites, $tNames)
    } finally { Remove-Item -LiteralPath $wtFx.Temp -Recurse -Force -ErrorAction SilentlyContinue }
  } catch {
    $script:cases++; $script:fail++
    Write-Output ('  FAIL  a case threw: ' + $_.Exception.Message)
  } finally {
    Remove-Item -LiteralPath $sftRoot -Recurse -Force -ErrorAction SilentlyContinue
  }

  if ($script:cases -eq 0) { Write-Output 'SELFTEST-FALLTHROUGH SELF-TEST FAILED (ran zero cases)'; exit 1 }
  if ($script:fail) { Write-Output ("SELFTEST-FALLTHROUGH SELF-TEST FAILED ({0} of {1} case(s))" -f $script:fail, $script:cases); exit 1 }
  Write-Output ("SELFTEST-FALLTHROUGH SELF-TEST PASSED ({0} case(s): every way out of a block is credited or named, each shape does as a child what the rule says, and the walk reads a worktree root and only tracked files)" -f $script:cases)
  exit 0
}

# ------------------------------------------------------------------------------------------- live run
$rootFull = Get-TcRootFull $repo
$listed = $null
try { $listed = & git -C $rootFull -c core.quotepath=off ls-files -- '*.ps1' } catch { $listed = $null }
$gitRc = $LASTEXITCODE
$listed = @($listed | Where-Object { $_ })
if ($gitRc -ne 0 -or $listed.Count -eq 0) {
  Write-Output ("SELFTEST-FALLTHROUGH AUDIT BLIND: git ls-files exited {0} and listed {1} .ps1 path(s), so there is no tracked set to read." -f $gitRc, $listed.Count)
  Exit-Guard -Name 'selftest-fallthrough' -Summary 'blind=no-git-list' -Code 3
}
$tracked = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($p in $listed) { [void]$tracked.Add(([string]$p -replace '/', '\')) }
$files = Get-SftScanFiles -RootDir $rootFull -Self $PSCommandPath -Tracked $tracked
$files = @($files)
if ($files.Count -eq 0) {
  Write-Output ("SELFTEST-FALLTHROUGH AUDIT BLIND: git lists {0} .ps1 path(s) and the walk resolved none of them, which means the discovery is broken rather than the tree being clean." -f $tracked.Count)
  Exit-Guard -Name 'selftest-fallthrough' -Summary ("blind=walk-resolved-none listed={0}" -f $tracked.Count) -Code 3
}
$sites = New-Object System.Collections.ArrayList
$parseErrorFiles = 0; $gates = 0
foreach ($f in $files) {
  $r = Get-SftFindings -Path $f.FullName
  if ($r.ParseErrors) { $parseErrorFiles++ }
  $gates += $r.Gates
  $rel = (Get-TcPathBelowRoot $f.FullName $rootFull).TrimStart('\')
  foreach ($h in $r.Findings) { [void]$sites.Add(("{0}:{1}  if ({2}) can end on [{3}] with {4} live statement(s) after it" -f $rel, $h.Line, $h.Gate, $h.EndsOn, $h.After)) }
}
$summary = "listed={0} files={1} parse_error_files={2} gates={3} sites={4}" -f $tracked.Count, $files.Count, $parseErrorFiles, $gates, $sites.Count
Write-Output ("selftest-fallthrough: git lists {0} tracked .ps1; the walk resolved {1}, {2} with a parse error; {3} top-level self-test gate(s); {4} site(s)" -f $tracked.Count, $files.Count, $parseErrorFiles, $gates, $sites.Count)
if ($sites.Count) {
  foreach ($s in $sites) { Write-Output ('  falls through  ' + $s) }
  Write-Output ("SELFTEST-FALLTHROUGH AUDIT FAILED: {0} self-test block(s) can end without leaving, and live statements follow them." -f $sites.Count)
  Write-Output '  Run with -SelfTest (as run-gates does), such a block goes on into the script''s live work. End it on every path:'
  Write-Output '  close it with exit after its verdict, or Exit-Guard. An if needs an else that also leaves; a catch must leave too.'
  Exit-Guard -Name 'selftest-fallthrough' -Summary $summary -Code 1
}
Write-Output 'selftest-fallthrough: PASSED - every top-level self-test block with live statements after it ends on exit, throw, return or Exit-Guard on every path.'
Exit-Guard -Name 'selftest-fallthrough' -Summary $summary -Code 0
