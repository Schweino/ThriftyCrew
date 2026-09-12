<#
  audit-keyword-arguments.ps1 - a statement keyword glued onto a command line is an ARGUMENT, not a statement.

  SCOPE OF A CLEAN REPORT: UNSOUND. It reads the PowerShell AST of every tracked .ps1 and .psm1 and finds the
    seventeen statement keywords listed under THE RULE when they appear unquoted as arguments of a command, in the
    shapes listed there. A clean report means none of those is present. A glued statement in any other shape - a
    `for` followed by a bare word, a `throw` right after a switch parameter - is invisible to it, and so is a
    statement that is wrong for any other reason. A reported site is real; silence is not proof.

  WHY THIS EXISTS (2026-09-11). Commit 8253ded82 joined grocery\pull-grocery-ads.ps1's last self-test case and
  the suite's closing verdict onto ONE line, separated only by spaces:
      _T '...' (...)  if ($fail -eq 0) { ...; exit 0 } else { ...; exit 1 }
  PowerShell does not end a command at whitespace. The parser gave that _T command eight elements, and five of
  them were the bare word if, the condition in parens, the first scriptblock, the bare word else and the second
  scriptblock. _T declares two parameters, so the rest went to $args unread. The -SelfTest branch then held no
  exit at all, control fell through to the LIVE pull of Hy-Vee, Aldi and Family Fare, the script wrote
  out\ads-<today>.json and exited 0. run-gates runs every -SelfTest on every push and judges the exit code, so
  from 13:38 that day every push from every session did a live three-store pull and scored the suite ok. Nothing
  errored, nothing warned, and all 21 of the file's cases printed ok. Only the parser can see it. The self-test
  below runs that shape in a child on every run, so the rule is dropped the day this PowerShell stops doing it.

  THE RULE. In the PowerShell AST, an element AFTER the command name of a CommandAst that is an unquoted
  (BareWord) string constant spelling a statement keyword, compared case-insensitively, as the language compares
  keywords:
    * if  else  elseif  foreach  while  exit  return
        wherever they stand.
    * for  do  switch  try  catch  finally  trap  throw  break  continue
        when the next element is a paren or a scriptblock, the shape of a real statement; and throw, break and
        continue whatever follows them, unless the word comes right after a parameter name and so is that
        parameter's value (`-ErrorAction Continue`).
  A command named cmd is never reported: every word after `cmd /c` belongs to cmd.exe, where exit and if are its
  own commands. One site per command, naming every keyword that command swallowed, so the founding line is one
  site carrying if and else.

  WHAT IT DELIBERATELY DOES NOT FLAG.
    * A QUOTED word. Write-Output 'if' is a string its author meant. Quoting is also the fix when a bare word
      really is a value, and the failure message says so.
    * The command NAME. `$rows | foreach { $_ }` is the ForEach-Object alias, element 0, not an argument.
    * Comments and string contents, which the parser never turns into commands.
    * for, do, switch, try, catch, finally and trap followed by anything but a paren or a scriptblock. `for` and
      `try` are ordinary prose in an unquoted Write-Host, and none of the seven is a working statement without
      its block.
    * throw, break and continue right after a parameter name. `-ErrorAction Continue` is the legal case, and the
      price is `Invoke-Thing -Force  throw 'x'`, which reads the same to a parser that cannot resolve -Force.
    * No such exemption for the first seven (`-Mode return`). It would let a glued statement after a switch
      parameter through (`Invoke-Thing -Force  return $x`), which the self-test pins. A legal command line has no
      ordinary reason to carry those seven bare, and that is the whole basis for choosing them.

  A GATE AT ZERO, NOT A RATCHET. MEASURED 2026-09-11 through this file, from a linked worktree at c17cc59a7 with
  the repair to pull-grocery-ads.ps1 applied: git listed 747 tracked .ps1, the walk resolved 747, none had a
  parse error, 0 sites, 14 s. With that one file put back to its c17cc59a7 blob (md5 AB704285...) the same live
  run exited 1 with exactly one site, grocery\pull-grocery-ads.ps1:273 carrying [if,else], and the repaired file
  was restored byte-identical by md5. So the day-one count is zero, and any site is new.
  THE TEN SHAPED KEYWORDS, .psm1 AND THE cmd EXEMPTION were added the same day and measured through this file at
  0a681beb0, from a linked worktree: git listed 750 tracked scripts, the walk resolved 749 (this file is the
  difference), no parse errors, 0 sites, 14 s. With pull-grocery-ads.ps1 put back to its 127e261b2 blob (md5
  AB704285...) the live run exited 1 with exactly one site, :273 carrying [if,else], and the file was restored
  byte-identical by md5. Before the ten were added, a scratch scan of the widest form - all seventeen keywords, any
  case, anything after them - read the 749 scripts tracked at 127e261b2 (56,090 commands) and matched only that
  line. So the shapes cost no finding today; they exist so that `-ErrorAction Continue` and prose never go red.
  Six mutants from a temp mirror - each keyword group, the flow rule, both exemptions, the .psm1 walk - each
  turned the cases that name it red.

  DISCOVERY. Every .ps1 and .psm1 under the root, excluded on the path BELOW the root (lib\tree-walk.ps1), never
  this file, and only the paths `git ls-files` lists, so untracked scratch in one checkout cannot make a push red
  in that checkout alone. Git names containing non-ASCII characters are read through the console encoding and may
  not match; none exist today.

  EXIT CODES (lib\guard-contract.ps1 vocabulary): 0 no site, 1 at least one site, 3 could not evaluate (git
  listed nothing, or the walk resolved nothing). Read the verdict LINE, not the number.

    ops\audit-keyword-arguments.ps1             scan the tracked tree
    ops\audit-keyword-arguments.ps1 -SelfTest   the founding line, the legal forms, the hazard, the walk
#>
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop (2026-09-07)
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\tree-walk.ps1')   # Get-TcRootFull, Get-TcPathBelowRoot, New-TcWorktreeFixture

$script:KWA_KEYWORDS = @('if', 'else', 'elseif', 'foreach', 'while', 'exit', 'return')
# The other ten fire only in the shape of a real statement (THE RULE), and these three of them with any operand.
$script:KWA_SHAPED_KEYWORDS = @('for', 'do', 'switch', 'try', 'catch', 'finally', 'trap', 'throw', 'break', 'continue')
$script:KWA_FLOW_KEYWORDS = @('throw', 'break', 'continue')
$script:KWA_WALK_EXCLUDE = '\\work' + 'trees\\|\\\.git\\|node_modules'

function Test-KwaSwallowed {
  <# Is element $Index of a command's $Elements a statement keyword that command swallowed? THE RULE, per element. #>
  param($Elements, [int]$Index)
  $e = $Elements[$Index]
  if (-not ($e -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
            $e.StringConstantType -eq [System.Management.Automation.Language.StringConstantType]::BareWord)) { return $false }
  $v = [string]$e.Value
  if ($script:KWA_KEYWORDS -contains $v) { return $true }
  if ($script:KWA_SHAPED_KEYWORDS -notcontains $v) { return $false }
  $next = $null
  if ($Index + 1 -lt $Elements.Count) { $next = $Elements[$Index + 1] }
  if ($next -is [System.Management.Automation.Language.ParenExpressionAst] -or
      $next -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { return $true }
  if ($script:KWA_FLOW_KEYWORDS -notcontains $v) { return $false }
  $prev = $Elements[$Index - 1]
  return (-not ($prev -is [System.Management.Automation.Language.CommandParameterAst] -and $null -eq $prev.Argument))
}

function Get-KwaFindings {
  <# Pure over one file's text, so the self-test drives exactly what the live scan runs.
     Returns @{ Findings = @({Line; Command; Keywords; Text}); ParseErrors }. #>
  param([string]$Text)
  $tok = $null; $err = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseInput([string]$Text, [ref]$tok, [ref]$err)
  $parseErrors = if ($null -eq $err) { 0 } else { $err.Count }
  $src = ([string]$Text -replace "`r", '') -split "`n"
  $out = New-Object System.Collections.ArrayList
  $cmds = $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.CommandAst] }, $true)
  foreach ($c in $cmds) {
    # Every word after `cmd /c` belongs to cmd.exe, where exit and if are its own commands.
    if ([string]$c.GetCommandName() -match '(?i)^cmd(\.exe)?$') { continue }
    $els = $c.CommandElements
    $kws = New-Object System.Collections.ArrayList
    $line = 0
    for ($i = 1; $i -lt $els.Count; $i++) {
      if (Test-KwaSwallowed -Elements $els -Index $i) {
        [void]$kws.Add(([string]$els[$i].Value).ToLowerInvariant())
        if (-not $line) { $line = $els[$i].Extent.StartLineNumber }
      }
    }
    if ($kws.Count) {
      $t = $src[$line - 1].Trim()
      if ($t.Length -gt 160) { $t = $t.Substring(0, 160) + '...' }
      [void]$out.Add([pscustomobject]@{ Line = $line; Command = [string]$c.GetCommandName(); Keywords = ($kws -join ','); Text = $t })
    }
  }
  return [pscustomobject]@{ Findings = $out.ToArray(); ParseErrors = $parseErrors }
}

function Get-KwaScanFiles {
  <# Every .ps1 and .psm1 under $RootDir, excluded on the path BELOW the root (lib\tree-walk.ps1), never $Self, and
     when $Tracked is given only the root-relative paths it holds. The live run passes git ls-files; the self-test
     passes its own set, so both halves of the filter are driven by a fixture. The extension is checked as well as
     filtered: a -Filter also matches longer extensions on Windows (*.ps1 finds .ps1xml). #>
  param([string]$RootDir, [string]$Self = '', $Tracked = $null)
  $rootFull = Get-TcRootFull $RootDir
  $ps1 = @(Get-TcTreeFiles -RootFull $rootFull -Filter *.ps1 -PruneBelow $script:KWA_WALK_EXCLUDE)
  $psm1 = @(Get-TcTreeFiles -RootFull $rootFull -Filter *.psm1 -PruneBelow $script:KWA_WALK_EXCLUDE)
  ($ps1 + $psm1) |
    Where-Object {
      $below = Get-TcPathBelowRoot $_.FullName $rootFull
      ($_.Extension -ieq '.ps1' -or $_.Extension -ieq '.psm1') -and ($below -notmatch $script:KWA_WALK_EXCLUDE) -and
      (-not [string]::Equals($_.FullName, $Self, [StringComparison]::OrdinalIgnoreCase)) -and
      ($null -eq $Tracked -or $Tracked.Contains($below.TrimStart('\')))
    } |
    Sort-Object FullName
}

# ------------------------------------------------------------------------------------------- self-test
if ($SelfTest) {
  $script:fail = 0; $script:cases = 0
  function KwaT([string]$m, [bool]$c, [string]$got = '') {
    $script:cases++
    if ($c) { Write-Output ('  ok    ' + $m) } else { Write-Output ('  FAIL  ' + $m + '   got: ' + $got); $script:fail++ }
  }
  function KwaGot($r) { return ('count=' + $r.Findings.Count + ' ' + (($r.Findings | ForEach-Object { 'line ' + $_.Line + ' [' + $_.Keywords + ']' }) -join '; ')) }

  # THE FOUNDING LINE, verbatim from 8253ded82 grocery\pull-grocery-ads.ps1:273, under a stand-in for its _T.
  $fxFounding = @(
    'function _T([string]$label, [bool]$cond) { }',
    '  _T ''MUST FIRE  a Family Fare pull that ERRORED adds a REVIEW line rather than passing silently beside two PASS stores'' ((@($revErr) -join '' '') -match ''Family Fare circular pull ERRORED'')  if ($fail -eq 0) { Write-Output "SELF-TEST PASS: $n case(s)"; exit 0 } else { Write-Output "SELF-TEST FAIL: $fail of $n case(s)"; exit 1 }'
  ) -join "`n"
  $fxRepaired = @(
    'function _T([string]$label, [bool]$cond) { }',
    '  _T ''MUST FIRE  a Family Fare pull that ERRORED adds a REVIEW line rather than passing silently beside two PASS stores'' ((@($revErr) -join '' '') -match ''Family Fare circular pull ERRORED'')',
    '  if ($fail -eq 0) { Write-Output "SELF-TEST PASS: $n case(s)"; exit 0 } else { Write-Output "SELF-TEST FAIL: $fail of $n case(s)"; exit 1 }'
  ) -join "`n"

  $sbDir = Join-Path ([IO.Path]::GetTempPath()) ('tc-kwa-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
  try {
    # ---- MUST FIRE ------------------------------------------------------------------------------------
    $r = Get-KwaFindings -Text $fxFounding
    KwaT 'MUST FIRE  the founding line from 8253ded82: one site on line 2, the _T command carrying if and else' ($r.Findings.Count -eq 1 -and $r.Findings[0].Line -eq 2 -and $r.Findings[0].Keywords -eq 'if,else' -and $r.Findings[0].Command -eq '_T') (KwaGot $r)
    $r = Get-KwaFindings -Text 'Write-Output ''done''  exit 1'
    KwaT 'MUST FIRE  a glued exit is an argument to Write-Output, so the script never exits there' ($r.Findings.Count -eq 1 -and $r.Findings[0].Keywords -eq 'exit') (KwaGot $r)
    $r = Get-KwaFindings -Text 'Invoke-Thing -Force  return $x'
    KwaT 'MUST FIRE  a glued return right after a switch parameter, the case a parameter-value exemption would miss' ($r.Findings.Count -eq 1 -and $r.Findings[0].Keywords -eq 'return') (KwaGot $r)
    $r = Get-KwaFindings -Text 'Get-Item $p  foreach ($x in $y) { $x }'
    KwaT 'MUST FIRE  a glued foreach loop' ($r.Findings.Count -eq 1 -and $r.Findings[0].Keywords -eq 'foreach') (KwaGot $r)
    $r = Get-KwaFindings -Text 'Write-Verbose ''a''  While ($busy) { Start-Sleep 1 }  ElseIf'
    KwaT 'MUST FIRE  keywords compare case-insensitively, as the language compares them' ($r.Findings.Count -eq 1 -and $r.Findings[0].Keywords -eq 'while,elseif') (KwaGot $r)
    $r = Get-KwaFindings -Text 'Remove-Item $tmp -Force  try { Get-Item $p } catch { $bad = $true }'
    KwaT 'MUST FIRE  a glued try and catch, each followed by its block, after a switch parameter' ($r.Findings.Count -eq 1 -and $r.Findings[0].Keywords -eq 'try,catch') (KwaGot $r)
    $r = Get-KwaFindings -Text 'Get-Item $p  Switch ($x) { default { $x } }'
    KwaT 'MUST FIRE  a glued switch with its paren' ($r.Findings.Count -eq 1 -and $r.Findings[0].Keywords -eq 'switch') (KwaGot $r)
    $r = Get-KwaFindings -Text 'Write-Warning ''bad input''  throw ''stop here'''
    KwaT 'MUST FIRE  a glued throw with a quoted message after it, no block needed' ($r.Findings.Count -eq 1 -and $r.Findings[0].Keywords -eq 'throw') (KwaGot $r)
    $r = Get-KwaFindings -Text 'foreach ($x in $xs) { Write-Output $x  continue }'
    KwaT 'MUST FIRE  a glued continue with NOTHING after it, the last element of the command' ($r.Findings.Count -eq 1 -and $r.Findings[0].Keywords -eq 'continue') (KwaGot $r)

    # ---- MUST NOT FIRE -------------------------------------------------------------------------------
    $r = Get-KwaFindings -Text 'Write-Output ''if''; Write-Host "return"; Set-Thing -Mode ''exit''; Write-Output ''throw'''
    KwaT 'MUST NOT FIRE  a quoted keyword is a string argument its author meant' ($r.Findings.Count -eq 0) (KwaGot $r)
    $r = Get-KwaFindings -Text '$rows | foreach { $_ }; $rows | ForEach-Object { if ($_) { return } }'
    KwaT 'MUST NOT FIRE  foreach as the command NAME (the ForEach-Object alias), and real statements inside a scriptblock' ($r.Findings.Count -eq 0) (KwaGot $r)
    $r = Get-KwaFindings -Text 'Get-Item $p -ErrorAction Continue; Invoke-Thing -OnError break; Write-Host waiting for the server'
    KwaT 'MUST NOT FIRE  continue and break right after a parameter name are its value, and for in unquoted prose is a word' ($r.Findings.Count -eq 0) (KwaGot $r)
    $r = Get-KwaFindings -Text 'Write-Host try again later, do not switch off; Write-Host done finally'
    KwaT 'MUST NOT FIRE  try, do, switch and finally followed by a bare word are prose, not statements' ($r.Findings.Count -eq 0) (KwaGot $r)
    $r = Get-KwaFindings -Text 'cmd /c exit 1; cmd.exe /c if exist x echo y'
    KwaT 'MUST NOT FIRE  cmd /c exit 1 and cmd /c if: every word after cmd /c belongs to cmd.exe' ($r.Findings.Count -eq 0) (KwaGot $r)
    $r = Get-KwaFindings -Text 'Get-Command Set-Thing -CommandType Function'
    KwaT 'MUST NOT FIRE  Function after -CommandType is not a statement keyword (three legal sites in the tree)' ($r.Findings.Count -eq 0) (KwaGot $r)
    $r = Get-KwaFindings -Text ("# was: _T 'x' (y)  if (`$fail -eq 0) { exit 0 } else { exit 1 }`n`$s = '_T x (y)  if (`$f) { exit 0 } else { exit 1 }'")
    KwaT 'MUST NOT FIRE  the founding shape quoted in a comment and inside a string' ($r.Findings.Count -eq 0) (KwaGot $r)
    $r = Get-KwaFindings -Text $fxRepaired
    KwaT 'MUST NOT FIRE  the repair: the same verdict on its own line' ($r.Findings.Count -eq 0) (KwaGot $r)

    # ---- CLEAN TWIN ----------------------------------------------------------------------------------
    $tok = $null; $perr = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($fxRepaired, [ref]$tok, [ref]$perr)
    $top = $ast.EndBlock.Statements
    $ifs = @($top | Where-Object { $_ -is [System.Management.Automation.Language.IfStatementAst] })
    $exitsThen = 0; $exitsElse = 0
    if ($ifs.Count -eq 1) {
      $exitsThen = @($ifs[0].Clauses[0].Item2.Statements | Where-Object { $_ -is [System.Management.Automation.Language.ExitStatementAst] }).Count
      if ($ifs[0].ElseClause) { $exitsElse = @($ifs[0].ElseClause.Statements | Where-Object { $_ -is [System.Management.Automation.Language.ExitStatementAst] }).Count }
    }
    KwaT 'CLEAN TWIN  the repaired form parses as a real top-level if whose then and else each hold an exit' ($ifs.Count -eq 1 -and $exitsThen -eq 1 -and $exitsElse -eq 1) ("ifs={0} then={1} else={2}" -f $ifs.Count, $exitsThen, $exitsElse)
    $tok = $null; $perr = $null
    $semi = [System.Management.Automation.Language.Parser]::ParseInput('Write-Warning ''bad input''; throw ''stop here''', [ref]$tok, [ref]$perr)
    $throws = @($semi.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.ThrowStatementAst] }).Count
    $r = Get-KwaFindings -Text 'Write-Warning ''bad input''; throw ''stop here'''
    KwaT 'CLEAN TWIN  the same throw after a semicolon parses as a real ThrowStatementAst' ($throws -eq 1) ("throws={0}" -f $throws)
    KwaT 'MUST NOT FIRE  and that separated throw is not reported' ($r.Findings.Count -eq 0) (KwaGot $r)
    $r = Get-KwaFindings -Text ($fxRepaired + "`n" + 'Write-Output ''tail''  exit 3')
    KwaT 'CLEAN TWIN  a glued exit beside the repaired form in the same file is still reported, on line 4' ($r.Findings.Count -eq 1 -and $r.Findings[0].Line -eq 4) (KwaGot $r)

    # ---- THE HAZARD, END TO END: the founding shape run in a child, with one case that fails on purpose ------
    [void](New-Item -ItemType Directory -Path $sbDir -ErrorAction Stop)
    $utf8 = New-Object Text.UTF8Encoding($false)
    $childHead = @(
      'param([switch]$RunCases)',
      'if ($RunCases) {',
      '  $fail = 0; $n = 0',
      '  function _T([string]$label, [bool]$cond) { $script:n++; if ($cond) { Write-Output "ok    $label" } else { Write-Output "FAIL  $label"; $script:fail++ } }',
      '  _T ''first case passes'' ($true)',
      '  _T ''second case fails on purpose'' ($false)'
    ) -join "`n"
    $childVerdict = 'if ($fail -eq 0) { Write-Output "VERDICT PASS"; exit 0 } else { Write-Output "VERDICT FAIL: $fail of $n"; exit 1 }'
    $childTail = "`n}`nWrite-Output 'LIVE PATH REACHED'`nexit 0"
    $childGlued = Join-Path $sbDir 'glued.ps1'; $childFixed = Join-Path $sbDir 'fixed.ps1'
    [IO.File]::WriteAllText($childGlued, ($childHead + '  ' + $childVerdict + $childTail), $utf8)
    [IO.File]::WriteAllText($childFixed, ($childHead + "`n  " + $childVerdict + $childTail), $utf8)
    $oG = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $childGlued -RunCases); $rcG = $LASTEXITCODE
    KwaT 'MUST FIRE  the hazard still exists on this PowerShell: the glued verdict exits 0 past a FAIL and runs the live path' ($rcG -eq 0 -and (($oG -join '|') -match 'LIVE PATH REACHED')) ('exit=' + $rcG + ' out=' + ($oG -join '|'))
    $oF = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $childFixed -RunCases); $rcF = $LASTEXITCODE
    KwaT 'CLEAN TWIN  the fixed copy exits 1 on the same FAIL, prints its verdict, and never reaches the live path' ($rcF -eq 1 -and (($oF -join '|') -match 'VERDICT FAIL: 1 of 2') -and -not (($oF -join '|') -match 'LIVE PATH REACHED')) ('exit=' + $rcF + ' out=' + ($oF -join '|'))

    # ---- THE WALK, FROM A WORKTREE ROOT (lib\tree-walk.ps1) -------------------------------------------
    $wtFx = New-TcWorktreeFixture -Files @{ 'grocery\glued.ps1' = $fxFounding; 'ops\clean.ps1' = $fxRepaired
                                            'ops\untracked.ps1' = 'Write-Output 1  exit 1'; 'ops\me.ps1' = 'Write-Output 2'
                                            'lib\mod.psm1' = 'Write-Output 3' }
    try {
      $self = Join-Path $wtFx.Root 'ops\me.ps1'
      $found = Get-KwaScanFiles -RootDir $wtFx.Root -Self $self
      $found = @($found)
      $hits = Measure-TcWorktreeFixture -Fixture $wtFx -Found $found
      KwaT 'MUST FIRE  a root that IS a worktree is scanned, not excluded whole (three .ps1 and a .psm1, not itself)' ($hits.Root -eq 4) ('root=' + $hits.Root)
      KwaT 'MUST NOT FIRE  a sibling worktree BELOW that root is still excluded' ($hits.Sibling -eq 0) ('sibling=' + $hits.Sibling)
      KwaT 'MUST NOT FIRE  the detector never scans itself' (@($found | Where-Object { $_.FullName -eq $self }).Count -eq 0) ''
      $trk = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
      foreach ($p in @('grocery\glued.ps1', 'ops\clean.ps1', 'ops\me.ps1', 'lib\mod.psm1')) { [void]$trk.Add($p) }
      $tFound = Get-KwaScanFiles -RootDir $wtFx.Root -Self $self -Tracked $trk
      $tFound = @($tFound)
      $tNames = ($tFound | ForEach-Object { $_.Name }) -join ','
      KwaT 'MUST NOT FIRE  an untracked file is not scanned when git''s list is given' (@($tFound | Where-Object { $_.Name -eq 'untracked.ps1' }).Count -eq 0) $tNames
      $sites = 0
      foreach ($f in $tFound) { $sites += (Get-KwaFindings -Text ([IO.File]::ReadAllText($f.FullName))).Findings.Count }
      KwaT 'CLEAN TWIN  the tracked walk still reads all three tracked files, the .psm1 among them, and reports the glued one: 3 files, 1 site' ($tFound.Count -eq 3 -and $sites -eq 1 -and $tNames -match 'mod\.psm1') ("files={0} sites={1} names={2}" -f $tFound.Count, $sites, $tNames)
    } finally { Remove-Item -LiteralPath $wtFx.Temp -Recurse -Force -ErrorAction SilentlyContinue }
  } catch {
    $script:cases++; $script:fail++
    Write-Output ('  FAIL  a case threw: ' + $_.Exception.Message)
  } finally {
    if (Test-Path -LiteralPath $sbDir) { Remove-Item -LiteralPath $sbDir -Recurse -Force -ErrorAction SilentlyContinue }
  }

  if ($script:fail) { Write-Output ("KEYWORD-ARGUMENTS SELF-TEST FAILED ({0} of {1} case(s))" -f $script:fail, $script:cases); exit 1 }
  Write-Output ("KEYWORD-ARGUMENTS SELF-TEST PASSED ({0} case(s): the founding line fires, quoted and legal forms stay silent, the hazard still exists, and the walk reads a worktree root and only tracked files)" -f $script:cases)
  exit 0
}

# ------------------------------------------------------------------------------------------- live run
$rootFull = Get-TcRootFull $repo
$listed = $null
try { $listed = & git -C $rootFull -c core.quotepath=off ls-files -- '*.ps1' '*.psm1' } catch { $listed = $null }
$gitRc = $LASTEXITCODE
$listed = @($listed | Where-Object { $_ })
if ($gitRc -ne 0 -or $listed.Count -eq 0) {
  Write-Output ("KEYWORD-ARGUMENTS AUDIT BLIND: git ls-files exited {0} and listed {1} .ps1/.psm1 path(s), so there is no tracked set to read." -f $gitRc, $listed.Count)
  Exit-Guard -Name 'keyword-arguments' -Summary 'blind=no-git-list' -Code 3
}
$tracked = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($p in $listed) { [void]$tracked.Add(([string]$p -replace '/', '\')) }
$files = Get-KwaScanFiles -RootDir $rootFull -Self $PSCommandPath -Tracked $tracked
$files = @($files)
if ($files.Count -eq 0) {
  Write-Output ("KEYWORD-ARGUMENTS AUDIT BLIND: git lists {0} .ps1/.psm1 path(s) and the walk resolved none of them, which means the discovery is broken rather than the tree being clean." -f $tracked.Count)
  Exit-Guard -Name 'keyword-arguments' -Summary ("blind=walk-resolved-none listed={0}" -f $tracked.Count) -Code 3
}
$sites = New-Object System.Collections.ArrayList
$parseErrorFiles = 0
foreach ($f in $files) {
  $r = Get-KwaFindings -Text ([IO.File]::ReadAllText($f.FullName))
  if ($r.ParseErrors) { $parseErrorFiles++ }
  $rel = (Get-TcPathBelowRoot $f.FullName $rootFull).TrimStart('\')
  foreach ($h in $r.Findings) { [void]$sites.Add(("{0}:{1}  {2} carries [{3}]  {4}" -f $rel, $h.Line, $h.Command, $h.Keywords, $h.Text)) }
}
$summary = "listed={0} files={1} parse_error_files={2} sites={3}" -f $tracked.Count, $files.Count, $parseErrorFiles, $sites.Count
Write-Output ("keyword-arguments: git lists {0} tracked .ps1/.psm1; the walk resolved {1}, {2} with a parse error; {3} site(s)" -f $tracked.Count, $files.Count, $parseErrorFiles, $sites.Count)
if ($sites.Count) {
  foreach ($s in $sites) { Write-Output ('  glued  ' + $s) }
  Write-Output ("KEYWORD-ARGUMENTS AUDIT FAILED: {0} command(s) carry a statement keyword as a bare argument." -f $sites.Count)
  Write-Output '  PowerShell does not end a command at whitespace, so the statement after it never runs as one: an if/else'
  Write-Output '  becomes arguments, an exit, return or throw never leaves. Put the statement on its own line or after a ;.'
  Write-Output '  If the word really is a value, quote it.'
  Exit-Guard -Name 'keyword-arguments' -Summary $summary -Code 1
}
Write-Output 'keyword-arguments: PASSED - no command carries a statement keyword as a bare argument in any shape the header''s RULE names.'
Exit-Guard -Name 'keyword-arguments' -Summary $summary -Code 0
