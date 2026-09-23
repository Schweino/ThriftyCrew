<#
  audit-literal-newline-escape.ps1 - a typed \n in PowerShell source is two characters, never a line break, and a
  self-test case written into a comment never runs.

  SCOPE OF A CLEAN REPORT: UNSOUND. It tokenises every tracked .ps1 and .psm1 and counts the three shapes under THE
  RULE. A clean report means none of those three spellings is present. A case lost any other way (a case inside a
  block comment, an `if ($false)`, a helper named so the case pattern cannot see it, a \n typed into a Python file) is
  out of its reach, and silence is not proof. A COUNTED finding is a candidate to read, not a verdict: the rule is
  INCOMPLETE because a line comment may quote the broken shape on purpose, and the fixtures below do exactly that (the
  detector never scans itself, and a test file that must quote it marks the line `# literal-newline:allow <reason>`).

  WHY THIS EXISTS (2026-09-23). The 2dae07 edit to grocery\audit-match-soundness.ps1 wrote its CONTESTED CROWN case
  and the pre-existing alert-registry assertion onto ONE source line joined by a literal backslash-n (the blob before
  the repair is 8b8320d2710ccd9bb49603438a62a3fb5b85d093, line 708). The line began with `#`, so the parser read the
  whole 1,431 characters as one comment. Neither case ran, the suite printed `match-soundness SELF-TEST PASS`, and
  run-gates scored it ok on every push until 8847c9fa5 split it by hand. Nothing errored: a comment is legal. The
  suite now asserts how many cases ran (62), and this file closes the class at push time for every other suite.
  Cousin of ops\audit-source-control-bytes.ps1, which catches the opposite accident (an escape eaten into a raw
  control byte), and of ops\audit-keyword-arguments.ps1 (a statement glued onto a command line).

  THE RULE. Over the PowerShell TOKENS (never the text, so a \n inside any string literal, expandable string,
  here-string or regex argument is never read):
    CODE      a token that is neither a string nor a comment whose text BEGINS or ENDS with \n or \r\n. That is
              the shape a joined line leaves between two statements (`$true\n    T 'x'` tokenises `\n` as a bare
              word). A bareword path such as out\new carries \n in its middle and is not read.
    COMMENT   a LINE comment (one that opens with #, never a block comment) in which \n or \r\n is followed by what reads as a new source
              line: optional blanks, then `#`, a `$variable`, or a command name followed by a quote, a paren, a `$`
              or a `-`. Prose such as "split on \r\n" or "a `[^\r\n]*` class" is not that.
    CASE      a LINE comment carrying a self-test case CALL: a command name, then a quoted label that opens with
              MUST FIRE, MUST NOT FIRE or CLEAN TWIN, then a `(` or `$` condition. A case in a comment never runs.
  LISTED, NOT COUNTED: every other comment holding \n or \r\n (prose about line endings) where the escape does not follow a
  letter or digit, so out\name-drift.json is not listed. Ten on the day this was written, all prose, and 22 after the same day's
  REPLACES header seeds added regex classes such as [^\r\n#] to twelve library headers; printed so a reader can see
  what the COMMENT rule chose not to count. Those headers are why the COMMENT rule wants a blank, or a # followed by a
  blank, between the escape and the new line it reads: the first cut counted all twelve.

  A GATE AT ZERO, NOT A RATCHET. Measured 2026-09-23 through this file from a linked worktree over the tree at
  origin/main 0c06fcf1d: git listed 839 tracked .ps1/.psm1, the walk resolved 839, CODE 0, COMMENT 0, CASE 0 counted,
  10 prose comments listed. With audit-match-soundness.ps1
  put back to blob 8b8320d27 the run exits 1 with the one line 708 carrying COMMENT and CASE (the self-test below
  reads that blob from git's object store on every run, which no rebase can move).

  PREFILTER. A file whose text holds no backslash-n and no # followed on its line by a quoted label cannot match any
  rule and is not tokenised (131 of 839 files held a backslash-n on 2026-09-23, 3 a commented label); a self-test case
  pins that a commented case with no escape still reaches the tokeniser.

  DISCOVERY. Every .ps1 and .psm1 under the root, excluded on the path BELOW the root (lib\tree-walk.ps1), never this
  file, and only the paths `git ls-files` lists.

  EXIT CODES (lib\guard-contract.ps1 vocabulary): 0 no counted site, 1 at least one, 3 could not evaluate (git listed
  nothing, or the walk resolved nothing). Read the verdict LINE, not the number.

    ops\audit-literal-newline-escape.ps1             scan the tracked tree
    ops\audit-literal-newline-escape.ps1 -SelfTest   the founding blob, the legal forms, the walk
#>
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop (2026-09-07)
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\tree-walk.ps1')   # Get-TcRootFull, Get-TcPathBelowRoot, Get-TcTreeFiles, New-TcWorktreeFixture

$script:LNE_WALK_EXCLUDE = '\\work' + 'trees\\|\\\.git\\|node_modules'
# Built by concatenation so a detector reading its own source could never match its own patterns.
$script:LNE_ESC = '(?:\\' + 'r)?\\' + 'n'   # an optional backslash-r, then backslash-n
$script:LNE_CODE_RX = '^' + $script:LNE_ESC + '|' + $script:LNE_ESC + '$'
# After the escape: blanks and then a comment, a variable or a command (the founding shape, an indented next line), or
# with no blank a comment that opens with a space, a variable, or a command. A regex class such as [^\r\n#] puts # right
# after the escape with no space, and is not a new line (the REPLACES headers of 2026-09-23 carry a dozen of them).
$script:LNE_COMMENT_RX = $script:LNE_ESC + '(?:[ \t]+(?:#|\$[\w{]|[A-Za-z_][\w-]*[ \t]+[''"($-])|#[ \t]|\$[A-Za-z_{]|[A-Za-z_][\w-]*[ \t]+[''"($-])'
$script:LNE_CASE_RX = '(?:^#|[\s;{(])[A-Za-z_][\w-]*[ \t]+''(?:MUST ' + 'FIRE|MUST NOT ' + 'FIRE|CLEAN ' + 'TWIN)[^'']*''[ \t]+[($]'
$script:LNE_ALLOW = 'literal-newline' + ':allow'
$script:LNE_BSN = [string][char]92 + 'n'
$script:LNE_CASE_PRE_RX = '#[^\r\n]*''(?:MUST FIRE|MUST NOT FIRE|CLEAN TWIN)'
$script:LNE_QUOTED_KINDS = @('StringLiteral', 'StringExpandable', 'HereStringLiteral', 'HereStringExpandable')
# LISTED prose only: an escape that does not follow a letter or digit, so a path such as out\name-drift.json is not prose
# about line endings. The COUNTED rules take no such lookbehind: the founding line joined "own" to its next line.
$script:LNE_PROSE_RX = '(?<!\w)' + $script:LNE_ESC

function Get-LneFindings {
  <# Pure over one file's text, so the self-test drives exactly what the live scan runs.
     Returns @{ Findings = @({Line; Rules; Text}); Listed = @({Line; Text}); ParseErrors }. #>
  param([string]$Text)
  # PREFILTER, a superset of all three rules (2026-09-23: 61 s tokenising all 839 scripts, most of it a PowerShell loop
  # over tokens no rule can match). CODE and COMMENT need the two characters backslash-n somewhere in the text; CASE
  # needs a # followed on the same line by a quoted label. A file with neither is not parsed, and says so.
  if (-not $Text.Contains($script:LNE_BSN) -and -not [regex]::IsMatch($Text, $script:LNE_CASE_PRE_RX)) {
    return [pscustomobject]@{ Findings = @(); Listed = @(); ParseErrors = 0; Parsed = $false }
  }
  $tok = $null; $err = $null
  [void][System.Management.Automation.Language.Parser]::ParseInput([string]$Text, [ref]$tok, [ref]$err)
  $parseErrors = if ($null -eq $err) { 0 } else { $err.Count }
  $byLine = [ordered]@{}
  $listed = New-Object System.Collections.ArrayList
  foreach ($k in $tok) {
    $t = [string]$k.Text
    $line = $k.Extent.StartLineNumber
    $rules = New-Object System.Collections.ArrayList
    if ($k.Kind -eq [System.Management.Automation.Language.TokenKind]::Comment) {
      if ($t.StartsWith('<#')) { continue }                     # block comments are documentation, out of scope
      if ($t.Contains($script:LNE_ALLOW)) { continue }
      if ($t -match $script:LNE_COMMENT_RX) { [void]$rules.Add('COMMENT') }
      if ($t -match $script:LNE_CASE_RX) { [void]$rules.Add('CASE') }
      if ($rules.Count -eq 0 -and $t -match $script:LNE_PROSE_RX) {
        [void]$listed.Add([pscustomobject]@{ Line = $line; Text = $(if ($t.Length -gt 140) { $t.Substring(0, 140) + '...' } else { $t }) })
      }
    } elseif ($script:LNE_QUOTED_KINDS -contains [string]$k.Kind) {
      continue                                                    # every QUOTED string form, here-strings included
      # A bareword argument such as `$true\n` is a StringExpandableToken too, but its Kind is Generic: it is not quoted,
      # and it is exactly the shape a joined line leaves, so the CODE rule below reads it.
    } elseif ($t -match $script:LNE_CODE_RX) {
      [void]$rules.Add('CODE')
    }
    if ($rules.Count) {
      $key = [string]$line
      if (-not $byLine.Contains($key)) { $byLine[$key] = New-Object System.Collections.ArrayList }
      foreach ($r in $rules) { if (-not $byLine[$key].Contains($r)) { [void]$byLine[$key].Add($r) } }
    }
  }
  $src = ([string]$Text -replace "`r", '') -split "`n"
  $out = New-Object System.Collections.ArrayList
  foreach ($key in $byLine.Keys) {
    $n = [int]$key
    $s = $src[$n - 1].Trim()
    if ($s.Length -gt 160) { $s = $s.Substring(0, 160) + '...' }
    [void]$out.Add([pscustomobject]@{ Line = $n; Rules = (@($byLine[$key]) -join ','); Text = $s })
  }
  return [pscustomobject]@{ Findings = $out.ToArray(); Listed = $listed.ToArray(); ParseErrors = $parseErrors; Parsed = $true }
}

function Get-LneScanFiles {
  <# Every .ps1 and .psm1 under $RootDir, excluded on the path BELOW the root, never $Self, and when $Tracked is given
     only the root-relative paths it holds. The extension is checked as well as filtered (*.ps1 also finds .ps1xml). #>
  param([string]$RootDir, [string]$Self = '', $Tracked = $null)
  $rootFull = Get-TcRootFull $RootDir
  $ps1 = @(Get-TcTreeFiles -RootFull $rootFull -Filter *.ps1 -PruneBelow $script:LNE_WALK_EXCLUDE)
  $psm1 = @(Get-TcTreeFiles -RootFull $rootFull -Filter *.psm1 -PruneBelow $script:LNE_WALK_EXCLUDE)
  ($ps1 + $psm1) |
    Where-Object {
      $below = Get-TcPathBelowRoot $_.FullName $rootFull
      ($_.Extension -ieq '.ps1' -or $_.Extension -ieq '.psm1') -and ($below -notmatch $script:LNE_WALK_EXCLUDE) -and
      (-not [string]::Equals($_.FullName, $Self, [StringComparison]::OrdinalIgnoreCase)) -and
      ($null -eq $Tracked -or $Tracked.Contains($below.TrimStart('\')))
    } |
    Sort-Object FullName
}

# ------------------------------------------------------------------------------------------- self-test
if ($SelfTest) {
  $script:fail = 0; $script:cases = 0
  $script:expectedCases = 19
  function LneT([string]$m, [bool]$c, [string]$got = '') {
    $script:cases++
    if ($c) { Write-Output ('  ok    ' + $m) } else { Write-Output ('  FAIL  ' + $m + '   got: ' + $got); $script:fail++ }
  }
  function LneGot($r) { return ('count=' + $r.Findings.Count + ' ' + (($r.Findings | ForEach-Object { 'line ' + $_.Line + ' [' + $_.Rules + ']' }) -join '; ') + ' listed=' + $r.Listed.Count) }
  $bs = [string][char]92   # one backslash, so no fixture below spells the escape the live scan looks for
  $nl = $bs + 'n'; $crnl = $bs + 'r' + $bs + 'n'
  try {
    # ---- MUST FIRE: the founding blob, read from git's object store by id ------------------------------------
    $blob = '8b8320d2710ccd9bb49603438a62a3fb5b85d093'
    $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $blobText = (& git -C $repo cat-file -p $blob) -join "`n"; $blobRc = $LASTEXITCODE } finally { $ErrorActionPreference = $prevEap }
    LneT 'the founding blob 8b8320d27 (audit-match-soundness.ps1 before 8847c9fa5) is readable from git' ($blobRc -eq 0 -and $blobText.Length -gt 1000) ('rc=' + $blobRc)
    $r = Get-LneFindings -Text $blobText
    $f708 = @($r.Findings | Where-Object { $_.Line -eq 708 })
    LneT 'MUST FIRE  the founding blob: exactly one counted site, line 708, carrying COMMENT and CASE' ($r.Findings.Count -eq 1 -and $f708.Count -eq 1 -and $f708[0].Rules -eq 'COMMENT,CASE') (LneGot $r)

    # ---- MUST FIRE: each rule alone ---------------------------------------------------------------------------
    $fxCase = "function T([string]`$n, [bool]`$ok) { }`n# T 'MUST FIRE  a disabled case' (`$x -eq 1)"
    $r = Get-LneFindings -Text $fxCase
    LneT 'MUST FIRE  a self-test case call written into a line comment, with no escape at all, is CASE on line 2' ($r.Findings.Count -eq 1 -and $r.Findings[0].Line -eq 2 -and $r.Findings[0].Rules -eq 'CASE') (LneGot $r)
    $fxCmt = '# first half of a note' + $nl + '    $x = 1'
    $r = Get-LneFindings -Text $fxCmt
    LneT 'MUST FIRE  a line comment whose escape is followed by an indented $variable is COMMENT' ($r.Findings.Count -eq 1 -and $r.Findings[0].Rules -eq 'COMMENT') (LneGot $r)
    $fxCmt2 = '# condition text' + $crnl + '  # second comment line'
    $r = Get-LneFindings -Text $fxCmt2
    LneT 'MUST FIRE  the \r\n spelling followed by a second comment is COMMENT' ($r.Findings.Count -eq 1 -and $r.Findings[0].Rules -eq 'COMMENT') (LneGot $r)
    $fxCode = "function T([string]`$n, [bool]`$ok) { }`nT 'first' `$true" + $nl + "    T 'second' `$true"
    $r = Get-LneFindings -Text $fxCode
    LneT 'MUST FIRE  a joined line in CODE (a bare escape between two statements) is CODE on line 2' ($r.Findings.Count -eq 1 -and $r.Findings[0].Line -eq 2 -and $r.Findings[0].Rules -eq 'CODE') (LneGot $r)

    # ---- MUST NOT FIRE: every legal home of the escape --------------------------------------------------------
    $fxStrings = @(
      ('$parts = $s -split "' + $nl + '"'),
      ('$m = [regex]::Match($s, ''(?s)# a[^' + $bs + 'r' + $bs + 'n]*' + $bs + 'r?' + $nl + '(.*?)'')'),
      ('$t = $body -replace ''' + $crnl + ''', '' '''),
      ('$h = @"' + "`n" + 'line with ' + $nl + ' inside' + "`n" + '"@'),
      ('Select-String -Path $p -Pattern ''' + $nl + '''')
    ) -join "`n"
    $r = Get-LneFindings -Text $fxStrings
    LneT 'MUST NOT FIRE  the escape inside a double-quoted string, a regex, a -replace, a here-string and a -Pattern' ($r.Findings.Count -eq 0 -and $r.Listed.Count -eq 0 -and $r.ParseErrors -eq 0) (LneGot $r)
    $fxProse = @(
      ('# split on ' + $crnl + ' so a CRLF file reads the same'),
      ('# a `[^' + $bs + 'r' + $bs + 'n]*` class cannot span lines'),
      ('# joined by a literal ' + $nl + ' (8847c9fa5)')
    ) -join "`n"
    $r = Get-LneFindings -Text $fxProse
    LneT 'MUST NOT FIRE  prose about line endings in a comment is LISTED, never counted (3 listed, 0 counted)' ($r.Findings.Count -eq 0 -and $r.Listed.Count -eq 3) (LneGot $r)
    $r = Get-LneFindings -Text ('Join-Path $root out' + $bs + 'new' + $bs + 'file.json')
    LneT 'MUST NOT FIRE  a bareword path with the escape in its middle (out\new\...)' ($r.Findings.Count -eq 0) (LneGot $r)
    $r = Get-LneFindings -Text ("<#`n  example: T 'MUST FIRE  x' (`$y)" + $nl + "  `$z = 1`n#>")
    LneT 'MUST NOT FIRE  a BLOCK comment is documentation and may show a case call and an escape' ($r.Findings.Count -eq 0 -and $r.Listed.Count -eq 0) (LneGot $r)
    $r = Get-LneFindings -Text ("# MUST FIRE: the case below proves X`n# the 'MUST FIRE' label names the founding bug")
    LneT 'MUST NOT FIRE  a comment that NAMES the vocabulary without a quoted-label-then-condition call' ($r.Findings.Count -eq 0) (LneGot $r)
    $r = Get-LneFindings -Text ("# T 'MUST FIRE  quoted on purpose' (`$x)   # " + $script:LNE_ALLOW + ' fixture of the shape')
    $r = Get-LneFindings -Text ("function T([string]`$n, [bool]`$ok) { }`nT 'MUST FIRE  x' (`$y)`n# a note")
    LneT 'MUST NOT FIRE  a file with neither a backslash-n nor a commented label is skipped by the prefilter, unparsed' ((-not $r.Parsed) -and $r.Findings.Count -eq 0) ('parsed=' + $r.Parsed)
    $fxClass = '# REPLACES: (?im)^(?![ \t]*#)[^' + $bs + 'r' + $bs + 'n#]*' + $bs + 'bAdd-Content' + $bs + 'b[^' + $bs + 'r' + $bs + 'n#]*' + $bs + '.(?:jsonl|log)'
    $r = Get-LneFindings -Text $fxClass
    LneT 'MUST NOT FIRE  a regex class [^\r\n#] in a line comment (the REPLACES header shape) is not a joined line' ($r.Findings.Count -eq 0) (LneGot $r)
    LneT 'MUST NOT FIRE  a line comment that carries the allow marker' ($r.Findings.Count -eq 0) (LneGot $r)

    # ---- CLEAN TWIN -------------------------------------------------------------------------------------------
    $fixed = '027e16e63'   # the blob 8847c9fa5 wrote, by its abbreviated id
    $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $fixedFull = (& git -C $repo rev-parse ('8847c9fa5:grocery/audit-match-soundness.ps1')); $fixedText = (& git -C $repo cat-file -p $fixedFull) -join "`n"; $fixedRc = $LASTEXITCODE } finally { $ErrorActionPreference = $prevEap }
    $r = Get-LneFindings -Text $fixedText
    LneT 'MUST NOT FIRE  the repaired blob from 8847c9fa5 parses clean and holds 0 counted sites' ($fixedRc -eq 0 -and $fixedFull -like ($fixed + '*') -and $r.Findings.Count -eq 0 -and $r.ParseErrors -eq 0) ((LneGot $r) + ' blob=' + $fixedFull)
    $tok = $null; $perr = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($fixedText, [ref]$tok, [ref]$perr)
    $belvita = @($ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.CommandAst] -and [string]$x.GetCommandName() -eq 'T' -and $x.Extent.Text -like '*CONTESTED CROWN*' }, $true))
    LneT 'CLEAN TWIN  in the repaired blob the CONTESTED CROWN case is a real T command the suite executes' ($belvita.Count -eq 1) ('commands=' + $belvita.Count)

    # ---- THE WALK, FROM A WORKTREE ROOT (lib\tree-walk.ps1) ---------------------------------------------------
    $wtFx = New-TcWorktreeFixture -Files @{ 'grocery\hidden.ps1' = $fxCase; 'ops\clean.ps1' = $fxStrings
                                            'ops\untracked.ps1' = $fxCase; 'ops\me.ps1' = 'Write-Output 2'
                                            'lib\mod.psm1' = $fxCmt }
    try {
      $self = Join-Path $wtFx.Root 'ops\me.ps1'
      $found = Get-LneScanFiles -RootDir $wtFx.Root -Self $self
      $found = @($found)
      $hits = Measure-TcWorktreeFixture -Fixture $wtFx -Found $found
      LneT 'MUST FIRE  a root that IS a worktree is scanned, not excluded whole (three .ps1 and a .psm1, not itself)' ($hits.Root -eq 4) ('root=' + $hits.Root)
      LneT 'MUST NOT FIRE  a sibling worktree BELOW that root is still excluded' ($hits.Sibling -eq 0) ('sibling=' + $hits.Sibling)
      $trk = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
      foreach ($p in @('grocery\hidden.ps1', 'ops\clean.ps1', 'ops\me.ps1', 'lib\mod.psm1')) { [void]$trk.Add($p) }
      $tFound = Get-LneScanFiles -RootDir $wtFx.Root -Self $self -Tracked $trk
      $tFound = @($tFound)
      $sites = 0
      foreach ($f in $tFound) { $sites += (Get-LneFindings -Text ([IO.File]::ReadAllText($f.FullName))).Findings.Count }
      $tNames = ($tFound | ForEach-Object { $_.Name }) -join ','
      LneT 'CLEAN TWIN  the tracked walk reads the three tracked files, the .psm1 among them, never the untracked one: 3 files, 2 sites' ($tFound.Count -eq 3 -and $sites -eq 2 -and $tNames -match 'mod\.psm1' -and $tNames -notmatch 'untracked') ("files={0} sites={1} names={2}" -f $tFound.Count, $sites, $tNames)
    } finally { Remove-Item -LiteralPath $wtFx.Temp -Recurse -Force -ErrorAction SilentlyContinue }
  } catch {
    $script:cases++; $script:fail++
    Write-Output ('  FAIL  a case threw: ' + $_.Exception.Message)
  }
  if ($script:cases -ne $script:expectedCases) {
    Write-Output ("  FAIL  CASE COUNT  ran {0} case(s), the suite lists {1}" -f $script:cases, $script:expectedCases); $script:fail++
  }
  if ($script:fail) { Write-Output ("LITERAL-NEWLINE-ESCAPE SELF-TEST FAILED ({0} of {1} case(s))" -f $script:fail, $script:cases); exit 1 }
  Write-Output ("LITERAL-NEWLINE-ESCAPE SELF-TEST PASSED ({0} case(s): the founding blob fires, each rule fires alone, strings, regexes, prose and block comments stay silent, and the walk reads a worktree root and only tracked files)" -f $script:cases)
  exit 0
}

# ------------------------------------------------------------------------------------------- live run
$rootFull = Get-TcRootFull $repo
$listed = $null
$prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
try { $listed = & git -C $rootFull -c core.quotepath=off ls-files -- '*.ps1' '*.psm1'; $gitRc = $LASTEXITCODE } finally { $ErrorActionPreference = $prevEap }
$listed = @($listed | Where-Object { $_ })
if ($gitRc -ne 0 -or $listed.Count -eq 0) {
  Write-Output ("LITERAL-NEWLINE-ESCAPE AUDIT BLIND: git ls-files exited {0} and listed {1} .ps1/.psm1 path(s), so there is no tracked set to read." -f $gitRc, $listed.Count)
  Exit-Guard -Name 'literal-newline-escape' -Summary 'blind=no-git-list' -Code 3
}
$tracked = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($p in $listed) { [void]$tracked.Add(([string]$p -replace '/', '\')) }
$files = Get-LneScanFiles -RootDir $rootFull -Self $PSCommandPath -Tracked $tracked
$files = @($files)
if ($files.Count -eq 0) {
  Write-Output ("LITERAL-NEWLINE-ESCAPE AUDIT BLIND: git lists {0} .ps1/.psm1 path(s) and the walk resolved none of them, which means the discovery is broken rather than the tree being clean." -f $tracked.Count)
  Exit-Guard -Name 'literal-newline-escape' -Summary ("blind=walk-resolved-none listed={0}" -f $tracked.Count) -Code 3
}
$sites = New-Object System.Collections.ArrayList
$prose = New-Object System.Collections.ArrayList
$parseErrorFiles = 0
$parsedFiles = 0
foreach ($f in $files) {
  $r = Get-LneFindings -Text ([IO.File]::ReadAllText($f.FullName))
  if ($r.ParseErrors) { $parseErrorFiles++ }
  if ($r.Parsed) { $parsedFiles++ }
  $rel = (Get-TcPathBelowRoot $f.FullName $rootFull).TrimStart('\')
  foreach ($h in $r.Findings) { [void]$sites.Add(("{0}:{1}  [{2}]  {3}" -f $rel, $h.Line, $h.Rules, $h.Text)) }
  foreach ($h in $r.Listed) { [void]$prose.Add(("{0}:{1}  {2}" -f $rel, $h.Line, $h.Text)) }
}
$summary = "listed={0} files={1} parsed={5} parse_error_files={2} sites={3} prose_listed={4}" -f $tracked.Count, $files.Count, $parseErrorFiles, $sites.Count, $prose.Count, $parsedFiles
Write-Output ("literal-newline-escape: git lists {0} tracked .ps1/.psm1; the walk resolved {1}; {5} held a backslash-n or a commented label and were tokenised, {2} with a parse error; {3} counted site(s), {4} prose comment(s) listed" -f $tracked.Count, $files.Count, $parseErrorFiles, $sites.Count, $prose.Count, $parsedFiles)
foreach ($s in $prose) { Write-Output ('  listed (prose, not counted)  ' + $s) }
if ($sites.Count) {
  foreach ($s in $sites) { Write-Output ('  site  ' + $s) }
  Write-Output ("LITERAL-NEWLINE-ESCAPE AUDIT FAILED: {0} line(s) carry a typed newline escape outside a string, or a self-test case inside a comment." -f $sites.Count)
  Write-Output '  In PowerShell source a typed backslash-n is two characters, never a line break: a line that starts with # stays a'
  Write-Output '  comment to its end, so every statement joined onto it never runs. Split it into real lines. A case call in a'
  Write-Output '  comment never runs either: restore it, or delete it. A comment that quotes the shape on purpose carries'
  Write-Output ('  # ' + $script:LNE_ALLOW + ' <reason>.')
  Exit-Guard -Name 'literal-newline-escape' -Summary $summary -Code 1
}
Write-Output 'literal-newline-escape: PASSED - no line outside a string carries a typed newline escape that joins source lines, and no line comment carries a self-test case call.'
Exit-Guard -Name 'literal-newline-escape' -Summary $summary -Code 0
