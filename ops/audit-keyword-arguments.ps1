<#
  audit-keyword-arguments.ps1 - a statement keyword glued onto a command line is an ARGUMENT, not a statement.

  SCOPE OF A CLEAN REPORT: UNSOUND. It reads the PowerShell AST of every tracked .ps1 and finds the seven
    keywords listed under THE RULE when they appear unquoted as arguments of a command. A clean report means
    none of those is present. A glued statement it does not list (for, switch, try, do, throw, break,
    continue) is invisible to it, and so is a statement that is wrong for any other reason. A reported site
    is real; silence is not proof.

  WHY THIS EXISTS (2026-09-11). Commit 8253ded82 joined grocery\pull-grocery-ads.ps1's last self-test case and
  the suite's closing verdict onto ONE line, separated only by spaces:
      _T '...' (...)  if ($fail -eq 0) { ...; exit 0 } else { ...; exit 1 }
  PowerShell does not end a command at whitespace. The parser gave that _T command eight elements, and five of
  them were the bare word if, the condition in parens, the first scriptblock, the bare word else and the second
  scriptblock. _T declares two parameters, so the rest went to $args unread. The -SelfTest branch then held no
  exit at all, control fell through to the LIVE pull of Hy-Vee, Aldi and Family Fare, the script wrote
  out\ads-<today>.json and exited 0. run-gates runs every -SelfTest on every push and judges the exit code, so
  from 13:38 that day every push from every session did a live three-store pull and scored the suite ok. Nothing
  errored, nothing warned, and all 21 of the file's cases printed ok. Only the parser can see it.

  THE RULE. In the PowerShell AST, any element AFTER the command name of a CommandAst that is an unquoted
  (BareWord) string constant spelling one of
      if  else  elseif  foreach  while  exit  return
  compared case-insensitively, as the language compares keywords. One site per command, naming every keyword
  that command swallowed, so the founding line is one site carrying if and else.

  WHAT IT DELIBERATELY DOES NOT FLAG.
    * A QUOTED word. Write-Output 'if' is a string its author meant. Quoting is also the fix when a bare word
      really is a value, and the failure message says so.
    * The command NAME. `$rows | foreach { $_ }` is the ForEach-Object alias, element 0, not an argument.
    * Comments and string contents, which the parser never turns into commands.
    * continue, break, for, do, switch, try, throw. `-ErrorAction Continue` passes a bare word on a great many
      lines here, and for is ordinary prose in an unquoted Write-Host. A legal command line has no ordinary
      reason to carry the seven above bare, and that is the whole basis for choosing them.
    * No exemption for a bare word right after a parameter name (`-Mode return`). It would let a glued
      statement after a switch parameter through (`Invoke-Thing -Force  return $x`), which the self-test pins.

  A GATE AT ZERO, NOT A RATCHET. MEASURED 2026-09-11 through this file, from a linked worktree at c17cc59a7 with
  the repair to pull-grocery-ads.ps1 applied: git listed 747 tracked .ps1, the walk resolved 747, none had a
  parse error, 0 sites, 14 s. With that one file put back to its c17cc59a7 blob (md5 AB704285...) the same live
  run exited 1 with exactly one site, grocery\pull-grocery-ads.ps1:273 carrying [if,else], and the repaired file
  was restored byte-identical by md5. So the day-one count is zero, and any site is new.

  DISCOVERY. Every .ps1 under the root, excluded on the path BELOW the root (lib\tree-walk.ps1), never this
  file, and only the paths `git ls-files` lists, so untracked scratch in one checkout cannot make a push red in
  that checkout alone. Git names containing non-ASCII characters are read through the console encoding and may
  not match; none exist today.

  EXIT CODES (lib\guard-contract.ps1 vocabulary): 0 no site, 1 at least one site, 3 could not evaluate (git
  listed nothing, or the walk resolved nothing). Read the verdict LINE, not the number.

    ops\audit-keyword-arguments.ps1             scan the tracked tree
    ops\audit-keyword-arguments.ps1 -SelfTest   the founding line, the legal forms, the walk
#>
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop (2026-09-07)
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\tree-walk.ps1')   # Get-TcRootFull, Get-TcPathBelowRoot, New-TcWorktreeFixture

$script:KWA_KEYWORDS = @('if', 'else', 'elseif', 'foreach', 'while', 'exit', 'return')
$script:KWA_WALK_EXCLUDE = '\\work' + 'trees\\|\\\.git\\|node_modules'

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
    $els = $c.CommandElements
    $kws = New-Object System.Collections.ArrayList
    $line = 0
    for ($i = 1; $i -lt $els.Count; $i++) {
      $e = $els[$i]
      if ($e -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
          $e.StringConstantType -eq [System.Management.Automation.Language.StringConstantType]::BareWord -and
          $script:KWA_KEYWORDS -contains [string]$e.Value) {
        [void]$kws.Add(([string]$e.Value).ToLowerInvariant())
        if (-not $line) { $line = $e.Extent.StartLineNumber }
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
  <# Every .ps1 under $RootDir, excluded on the path BELOW the root (lib\tree-walk.ps1), never $Self, and when
     $Tracked is given only the root-relative paths it holds. The live run passes git ls-files; the self-test
     passes its own set, so both halves of the filter are driven by a fixture. #>
  param([string]$RootDir, [string]$Self = '', $Tracked = $null)
  $rootFull = Get-TcRootFull $RootDir
  Get-ChildItem -LiteralPath $rootFull -Recurse -File -Filter *.ps1 -ErrorAction SilentlyContinue |
    Where-Object {
      $below = Get-TcPathBelowRoot $_.FullName $rootFull
      ($_.Extension -ieq '.ps1') -and ($below -notmatch $script:KWA_WALK_EXCLUDE) -and
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

    # ---- MUST NOT FIRE -------------------------------------------------------------------------------
    $r = Get-KwaFindings -Text 'Write-Output ''if''; Write-Host "return"; Set-Thing -Mode ''exit'''
    KwaT 'MUST NOT FIRE  a quoted keyword is a string argument its author meant' ($r.Findings.Count -eq 0) (KwaGot $r)
    $r = Get-KwaFindings -Text '$rows | foreach { $_ }; $rows | ForEach-Object { if ($_) { return } }'
    KwaT 'MUST NOT FIRE  foreach as the command NAME (the ForEach-Object alias), and real statements inside a scriptblock' ($r.Findings.Count -eq 0) (KwaGot $r)
    $r = Get-KwaFindings -Text 'Get-Item $p -ErrorAction Continue; Write-Host waiting for the server'
    KwaT 'MUST NOT FIRE  continue and for are left out on purpose: -ErrorAction Continue and unquoted prose' ($r.Findings.Count -eq 0) (KwaGot $r)
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
    $r = Get-KwaFindings -Text ($fxRepaired + "`n" + 'Write-Output ''tail''  exit 3')
    KwaT 'CLEAN TWIN  a glued exit beside the repaired form in the same file is still reported, on line 4' ($r.Findings.Count -eq 1 -and $r.Findings[0].Line -eq 4) (KwaGot $r)

    # ---- THE WALK, FROM A WORKTREE ROOT (lib\tree-walk.ps1) -------------------------------------------
    $wtFx = New-TcWorktreeFixture -Files @{ 'grocery\glued.ps1' = $fxFounding; 'ops\clean.ps1' = $fxRepaired
                                            'ops\untracked.ps1' = 'Write-Output 1  exit 1'; 'ops\me.ps1' = 'Write-Output 2' }
    try {
      $self = Join-Path $wtFx.Root 'ops\me.ps1'
      $found = Get-KwaScanFiles -RootDir $wtFx.Root -Self $self
      $found = @($found)
      $hits = Measure-TcWorktreeFixture -Fixture $wtFx -Found $found
      KwaT 'MUST FIRE  a root that IS a worktree is scanned, not excluded whole (three .ps1, not itself)' ($hits.Root -eq 3) ('root=' + $hits.Root)
      KwaT 'MUST NOT FIRE  a sibling worktree BELOW that root is still excluded' ($hits.Sibling -eq 0) ('sibling=' + $hits.Sibling)
      KwaT 'MUST NOT FIRE  the detector never scans itself' (@($found | Where-Object { $_.FullName -eq $self }).Count -eq 0) ''
      $trk = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
      foreach ($p in @('grocery\glued.ps1', 'ops\clean.ps1', 'ops\me.ps1')) { [void]$trk.Add($p) }
      $tFound = Get-KwaScanFiles -RootDir $wtFx.Root -Self $self -Tracked $trk
      $tFound = @($tFound)
      $tNames = ($tFound | ForEach-Object { $_.Name }) -join ','
      KwaT 'MUST NOT FIRE  an untracked file is not scanned when git''s list is given' (@($tFound | Where-Object { $_.Name -eq 'untracked.ps1' }).Count -eq 0) $tNames
      $sites = 0
      foreach ($f in $tFound) { $sites += (Get-KwaFindings -Text ([IO.File]::ReadAllText($f.FullName))).Findings.Count }
      KwaT 'CLEAN TWIN  the tracked walk still reads both tracked files and reports the glued one: 2 files, 1 site' ($tFound.Count -eq 2 -and $sites -eq 1) ("files={0} sites={1} names={2}" -f $tFound.Count, $sites, $tNames)
    } finally { Remove-Item -LiteralPath $wtFx.Temp -Recurse -Force -ErrorAction SilentlyContinue }
  } catch {
    $script:cases++; $script:fail++
    Write-Output ('  FAIL  a case threw: ' + $_.Exception.Message)
  }

  if ($script:fail) { Write-Output ("KEYWORD-ARGUMENTS SELF-TEST FAILED ({0} of {1} case(s))" -f $script:fail, $script:cases); exit 1 }
  Write-Output ("KEYWORD-ARGUMENTS SELF-TEST PASSED ({0} case(s): the founding line fires, quoted and legal forms stay silent, and the walk reads a worktree root and only tracked files)" -f $script:cases)
  exit 0
}

# ------------------------------------------------------------------------------------------- live run
$rootFull = Get-TcRootFull $repo
$listed = $null
try { $listed = & git -C $rootFull -c core.quotepath=off ls-files -- '*.ps1' } catch { $listed = $null }
$gitRc = $LASTEXITCODE
$listed = @($listed | Where-Object { $_ })
if ($gitRc -ne 0 -or $listed.Count -eq 0) {
  Write-Output ("KEYWORD-ARGUMENTS AUDIT BLIND: git ls-files exited {0} and listed {1} .ps1 path(s), so there is no tracked set to read." -f $gitRc, $listed.Count)
  Exit-Guard -Name 'keyword-arguments' -Summary 'blind=no-git-list' -Code 3
}
$tracked = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($p in $listed) { [void]$tracked.Add(([string]$p -replace '/', '\')) }
$files = Get-KwaScanFiles -RootDir $rootFull -Self $PSCommandPath -Tracked $tracked
$files = @($files)
if ($files.Count -eq 0) {
  Write-Output ("KEYWORD-ARGUMENTS AUDIT BLIND: git lists {0} .ps1 path(s) and the walk resolved none of them, which means the discovery is broken rather than the tree being clean." -f $tracked.Count)
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
Write-Output ("keyword-arguments: git lists {0} tracked .ps1; the walk resolved {1}, {2} with a parse error; {3} site(s)" -f $tracked.Count, $files.Count, $parseErrorFiles, $sites.Count)
if ($sites.Count) {
  foreach ($s in $sites) { Write-Output ('  glued  ' + $s) }
  Write-Output ("KEYWORD-ARGUMENTS AUDIT FAILED: {0} command(s) carry a statement keyword as a bare argument." -f $sites.Count)
  Write-Output '  PowerShell does not end a command at whitespace, so the statement after it never runs as one: an if/else'
  Write-Output '  becomes arguments, an exit or return never leaves. Put the statement on its own line or after a ;.'
  Write-Output '  If the word really is a value, quote it.'
  Exit-Guard -Name 'keyword-arguments' -Summary $summary -Code 1
}
Write-Output 'keyword-arguments: PASSED - no command carries if, else, elseif, foreach, while, exit or return as a bare argument.'
Exit-Guard -Name 'keyword-arguments' -Summary $summary -Code 0
