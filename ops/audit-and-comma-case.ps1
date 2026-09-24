<#
  audit-and-comma-case.ps1 - a self-test case body written `a -and b, 'got'` never judges b: the comma binds tighter
  than -and, so PowerShell reads it as `a -and (b, 'got')`, a two-element array is always truthy, and the case passes
  whatever b says.

  SCOPE OF A CLEAN REPORT: UNSOUND. It parses every tracked .ps1 and .psm1 and counts one AST shape: a -and, -or or
  -xor whose RIGHT operand is an unparenthesised array literal (ArrayLiteralAst), where that node sits inside a
  self-test body (lib\selftest-lib.ps1's Get-SelfTestSpans) or inside an argument of a case call (a command one of whose
  arguments is a string label opening MUST FIRE, MUST NOT FIRE or CLEAN TWIN). A clean report means that spelling is
  absent there. A condition lost any other way (a comma after -eq or -match, a case in a helper the span rules cannot
  see, a Python suite) is out of its reach, and silence is not proof. A COUNTED finding is COMPLETE for what it names:
  the right operand of the boolean IS an array, so the operator reads only whether the array is non-empty and the first
  element (the condition the author meant) is never evaluated as a boolean at all. It is incomplete only in that a
  fixture may execute the shape on purpose, which carries `# and-comma-case:allow <reason>` on the site's own line.
  The same shape OUTSIDE a self-test or case call is LISTED, never counted (production code is not what this gate is
  for, and none existed on the day it was written).

  WHY THIS EXISTS (2026-09-23). ops\rehearse-chain.ps1's cases returned `(c1) -and (c2), ('got')`. Found while killing
  mutant M11 (design\backlog-inbox\pd-rehearse2-2026-09-23.md): the LAST condition of every multi-condition case was
  never judged and no got-text was ever printed. On origin/main at blob 17170b38726577d9046c139a0e741bd82c8e8517 the
  file carries 28 such sites, which the self-test below reads from git's object store on every run. The lane that owns
  that file rewrote them on feat/pd-rehearse2 and made its case harness refuse a body that does not return exactly
  (verdict, got); this file closes the class at push time for every other suite. Cousin of
  ops\audit-keyword-arguments.ps1 and ops\audit-literal-newline-escape.ps1: three spellings in which a condition is
  present in the source and absent from the run.

  THE RULE. Over the AST (never the text, so a string or comment spelling the shape is never read):
    COUNTED  BinaryExpressionAst, Operator And, Or or Xor, Right is ArrayLiteralAst, inside a self-test span or a case
             call's arguments, and no `and-comma-case:allow` comment on the line the site starts on.
    LISTED   the same shape anywhere else in the file, and every allowed site.
  The fix is to parenthesise the verdict: `((c1) -and (c2)), 'got'`.

  PENDING. A file another lane is landing at the time this was written is held by a PIN, not fixed here: its sites
  must not rise above the pinned count, and the run says when the pin can go. Each entry names its owner.

  A GATE AT ZERO OUTSIDE THE PIN. Measured 2026-09-24 from a linked worktree over origin/main faafb042c: git listed 861
  tracked .ps1/.psm1, the walk resolved 861, 0 parse errors, 28 counted sites, all 28 in ops\rehearse-chain.ps1 (pinned), 0
  elsewhere, 0 listed. The same scan over the in-flight branch tips (feat/pd-pushmain, feat/pd-queue, feat/pd-hooks,
  feat/pd-hooks-w83) read the same 28 and nothing in push-main, chain-queue, the hooks or test-prepush-hook; over
  feat/pd-rehearse2 it read 1, the deliberate fixture at line 1183 that executes the shape to prove its harness refuses
  it (that line wants the allow marker when the lane next touches it).

  DISCOVERY. Every .ps1 and .psm1 under the root, pruned and excluded on the path BELOW the root (lib\tree-walk.ps1),
  never this file, and only the paths `git ls-files` lists.

  EXIT CODES (lib\guard-contract.ps1 vocabulary): 0 no counted site outside a pin and no pin exceeded, 1 at least one,
  3 could not evaluate (git listed nothing, or the walk resolved nothing). Read the verdict LINE, not the number.

    ops\audit-and-comma-case.ps1             scan the tracked tree
    ops\audit-and-comma-case.ps1 -SelfTest   the founding blob, the legal forms, the pin, the walk
#>
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop (2026-09-07)
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\tree-walk.ps1')      # Get-TcRootFull, Get-TcPathBelowRoot, Get-TcTreeFiles, New-TcWorktreeFixture
. (Join-Path $repo 'lib\selftest-lib.ps1')   # Get-SelfTestSpans

$script:ACC_WALK_EXCLUDE = '\\work' + 'trees\\|\\\.git\\|node_modules'
# Built by concatenation so no fixture or rule in this file spells what the live scan counts.
$script:ACC_ALLOW = 'and-comma-case' + ':allow'
$script:ACC_LABEL_RX = '^\s*(?:MUST ' + 'FIRE|MUST NOT ' + 'FIRE|CLEAN ' + 'TWIN)\b'
$script:ACC_OPS = @('And', 'Or', 'Xor')
# PENDING pins, keyed on the root-relative path. Max is the count on origin/main when the pin was written; a rise
# fails, a fall is spoken. Remove an entry when its file reads 0 counted sites (the run says so).
$script:ACC_PENDING = @{
  'ops\rehearse-chain.ps1' = [pscustomobject]@{ Max = 28; Why = 'owned by the pd-rehearse2 lane, which rewrote all 28 on feat/pd-rehearse2 and is landing it (design\backlog-inbox\pd-rehearse2-2026-09-23.md)' }
}

function Get-AccFindings {
  <# Pure over one file's text, so the self-test drives exactly what the live scan runs. -Path is read only for its
     file name (the whole-file test-*.ps1 rule of Get-SelfTestSpans).
     Returns @{ Counted = @({Line; Where; Swallowed; Text}); Listed = @({Line; Why; Text}); ParseErrors }. #>
  param([string]$Text, [string]$Path = '')
  $empty = [pscustomobject]@{ Counted = @(); Listed = @(); ParseErrors = 0 }
  $tok = $null; $err = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseInput([string]$Text, [ref]$tok, [ref]$err)
  $parseErrors = if ($null -eq $err) { 0 } else { $err.Count }
  $ops = $script:ACC_OPS
  $hits = $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.BinaryExpressionAst] -and
      ($ops -contains [string]$x.Operator) -and
      $x.Right -is [System.Management.Automation.Language.ArrayLiteralAst] }, $true)
  if (-not $hits.Count) { $empty.ParseErrors = $parseErrors; return $empty }

  $spans = Get-SelfTestSpans -Text $Text -Path $Path
  $spans = @($spans)
  $labelRx = $script:ACC_LABEL_RX
  $caseCalls = $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.CommandAst] -and
      @($x.CommandElements | Where-Object {
        ($_ -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
         $_ -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) -and
        ([string]$_.Value -match $labelRx) }).Count -gt 0 }, $true)
  $allowLines = New-Object 'System.Collections.Generic.HashSet[int]'
  foreach ($k in $tok) {
    if ($k.Kind -eq [System.Management.Automation.Language.TokenKind]::Comment -and ([string]$k.Text).Contains($script:ACC_ALLOW)) {
      [void]$allowLines.Add($k.Extent.StartLineNumber)
    }
  }
  $src = ([string]$Text -replace "`r", '') -split "`n"
  $counted = New-Object System.Collections.ArrayList
  $listed = New-Object System.Collections.ArrayList
  foreach ($h in $hits) {
    $o = $h.Extent.StartOffset
    $inSpan = $false
    foreach ($sp in $spans) { if ($o -ge $sp.S -and $o -lt $sp.E) { $inSpan = $true; break } }
    $inCase = $false
    foreach ($c in $caseCalls) {
      if ($o -ge $c.Extent.StartOffset -and $h.Extent.EndOffset -le $c.Extent.EndOffset) { $inCase = $true; break }
    }
    $line = $h.Extent.StartLineNumber
    $s = $src[$line - 1].Trim()
    if ($s.Length -gt 160) { $s = $s.Substring(0, 160) + '...' }
    $swallowed = [string]$h.Right.Elements[0].Extent.Text
    if ($swallowed.Length -gt 100) { $swallowed = $swallowed.Substring(0, 100) + '...' }
    $where = @(); if ($inSpan) { $where += 'self-test' }; if ($inCase) { $where += 'case-call' }
    if ($where.Count -and -not $allowLines.Contains($line)) {
      [void]$counted.Add([pscustomobject]@{ Line = $line; Where = ($where -join ','); Swallowed = $swallowed; Text = $s })
    } else {
      $why = if ($where.Count) { 'allowed' } else { 'outside any self-test or case call' }
      [void]$listed.Add([pscustomobject]@{ Line = $line; Why = $why; Text = $s })
    }
  }
  return [pscustomobject]@{ Counted = $counted.ToArray(); Listed = $listed.ToArray(); ParseErrors = $parseErrors }
}

function Test-AccPending {
  <# The pin rule, pure. $Counts maps a root-relative path to its counted sites. Returns one row per pending entry:
     {Path; Count; Max; Verdict} with Verdict 'exceeded' (Count > Max, a failure), 'held' (0 < Count <= Max) or
     'clear' (0: the pin may be removed). #>
  param([hashtable]$Counts, [hashtable]$Pending)
  $rows = New-Object System.Collections.ArrayList
  foreach ($p in @($Pending.Keys | Sort-Object)) {
    $n = if ($Counts.ContainsKey($p)) { [int]$Counts[$p] } else { 0 }
    $max = [int]$Pending[$p].Max
    $v = if ($n -gt $max) { 'exceeded' } elseif ($n -gt 0) { 'held' } else { 'clear' }
    [void]$rows.Add([pscustomobject]@{ Path = $p; Count = $n; Max = $max; Verdict = $v })
  }
  return $rows.ToArray()
}

function Get-AccScanFiles {
  <# Every .ps1 and .psm1 under $RootDir, pruned and excluded on the path BELOW the root, never $Self, and when
     $Tracked is given only the root-relative paths it holds. The extension is checked as well as filtered. #>
  param([string]$RootDir, [string]$Self = '', $Tracked = $null)
  $rootFull = Get-TcRootFull $RootDir
  $ps1 = @(Get-TcTreeFiles -RootFull $rootFull -Filter *.ps1 -PruneBelow $script:ACC_WALK_EXCLUDE)
  $psm1 = @(Get-TcTreeFiles -RootFull $rootFull -Filter *.psm1 -PruneBelow $script:ACC_WALK_EXCLUDE)
  ($ps1 + $psm1) |
    Where-Object {
      $below = Get-TcPathBelowRoot $_.FullName $rootFull
      ($_.Extension -ieq '.ps1' -or $_.Extension -ieq '.psm1') -and ($below -notmatch $script:ACC_WALK_EXCLUDE) -and
      (-not [string]::Equals($_.FullName, $Self, [StringComparison]::OrdinalIgnoreCase)) -and
      ($null -eq $Tracked -or $Tracked.Contains($below.TrimStart('\')))
    } |
    Sort-Object FullName
}

# ------------------------------------------------------------------------------------------- self-test
if ($SelfTest) {
  $script:fail = 0; $script:cases = 0
  $script:expectedCases = 18
  function AccT([string]$m, [bool]$c, [string]$got = '') {
    $script:cases++
    if ($c) { Write-Output ('  ok    ' + $m) } else { Write-Output ('  FAIL  ' + $m + '   got: ' + $got); $script:fail++ }
  }
  function AccGot($r) { return ('counted=' + $r.Counted.Count + ' ' + (($r.Counted | ForEach-Object { 'line ' + $_.Line + ' [' + $_.Where + '] swallowed=' + $_.Swallowed }) -join '; ') + ' listed=' + $r.Listed.Count) }
  $MF = 'MUST ' + 'FIRE'; $MNF = 'MUST NOT ' + 'FIRE'
  $stHead = "param([switch]`$SelfTest)`nif (`$SelfTest) {`n"
  $stTail = "`n}`n"
  try {
    # ---- MUST FIRE: the founding blob, read from git's object store by id ------------------------------------
    $blob = '17170b38726577d9046c139a0e741bd82c8e8517'
    $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $blobText = (& git -C $repo cat-file -p $blob) -join "`n"; $blobRc = $LASTEXITCODE } finally { $ErrorActionPreference = $prevEap }
    AccT 'the founding blob 17170b387 (ops\rehearse-chain.ps1 on origin/main, 2026-09-23) is readable from git' ($blobRc -eq 0 -and $blobText.Length -gt 1000) ('rc=' + $blobRc)
    $r = Get-AccFindings -Text $blobText -Path 'rehearse-chain.ps1'
    $want = '720,727,734,761,765,770,774,782,787,792,799,806,809,840,843,847,851,853,867,877,881,983,994,998,1002,1007,1016,1082'
    $gotLines = ($r.Counted | ForEach-Object { $_.Line }) -join ','
    AccT ($MF + '  the founding blob: exactly the 28 case bodies the pd-rehearse2 lane found, by line') ($r.Counted.Count -eq 28 -and $gotLines -eq $want -and $r.Listed.Count -eq 0) (AccGot $r)

    # ---- MUST FIRE: the exact rehearse-chain shape, built by concatenation ----------------------------------------
    $rhBody = "  Test-RhCase '" + $MNF + "  a stale verdict is refused' {`n    (`$d.Code -eq 1) -and (`$d.Outcome -eq 'stale'), ('' + `$d.Code + ' ' + `$d.Outcome)`n  }"
    $r = Get-AccFindings -Text ($stHead + $rhBody + $stTail)
    AccT ($MF + '  the rehearse-chain shape `(c1) -and (c2), (got)` in a self-test case body is counted, and names c2 as swallowed') ($r.Counted.Count -eq 1 -and $r.Counted[0].Line -eq 4 -and $r.Counted[0].Swallowed -eq "(`$d.Outcome -eq 'stale')" -and $r.Counted[0].Where -eq 'self-test,case-call') (AccGot $r)
    $three = "  Test-RhCase '" + $MF + "  three' { (`$a) -and (`$b) -and (`$c), 'got' }"
    $r = Get-AccFindings -Text ($stHead + $three + $stTail)
    AccT ($MF + '  three conditions: only the LAST is swallowed, and it is the one named') ($r.Counted.Count -eq 1 -and $r.Counted[0].Swallowed -eq '($c)') (AccGot $r)
    $orForm = "  T '" + $MF + "  or' ((`$a) -or (`$b), 'got')"
    $r = Get-AccFindings -Text ($stHead + $orForm + $stTail)
    AccT ($MF + '  the -or form inside a case-call''s parenthesised argument') ($r.Counted.Count -eq 1 -and $r.Counted[0].Swallowed -eq '($b)') (AccGot $r)
    $outside = "function Invoke-Cases {`n  T '" + $MNF + "  helper' ((`$a) -and (`$b), 'got')`n}`n"
    $r = Get-AccFindings -Text $outside
    AccT ($MF + '  a labelled case call OUTSIDE every self-test span is still counted, as case-call') ($r.Counted.Count -eq 1 -and $r.Counted[0].Where -eq 'case-call') (AccGot $r)

    # ---- MUST NOT FIRE: the legal forms ---------------------------------------------------------------------------
    $fixed = "  Test-RhCase '" + $MNF + "  a stale verdict is refused' {`n    ((`$d.Code -eq 1) -and (`$d.Outcome -eq 'stale')), ('' + `$d.Code)`n  }"
    $r = Get-AccFindings -Text ($stHead + $fixed + $stTail)
    AccT ($MNF + '  the correctly parenthesised case `((c1) -and (c2)), got`') ($r.Counted.Count -eq 0 -and $r.Listed.Count -eq 0 -and $r.ParseErrors -eq 0) (AccGot $r)
    $plain = "  T '" + $MF + "  plain' ((`$a) -and (`$b)) ('a=' + `$a)`n  `$ok = `$a -and (`$b, `$c)`n  `$n = `$a -and @(`$b, `$c).Count -gt 1"
    $r = Get-AccFindings -Text ($stHead + $plain + $stTail)
    AccT ($MNF + '  a condition with its got as a separate argument, a parenthesised array, and an @() array') ($r.Counted.Count -eq 0 -and $r.Listed.Count -eq 0) (AccGot $r)
    $quoted = "  # T '" + $MF + "  x' { (`$a) -and (`$b), 'got' }`n  `$s = '(`$a) -and (`$b), got'"
    $r = Get-AccFindings -Text ($stHead + $quoted + $stTail)
    AccT ($MNF + '  the shape spelled in a comment or a string is never read (AST, not text)') ($r.Counted.Count -eq 0 -and $r.Listed.Count -eq 0) (AccGot $r)
    $allowed = "  `$m = & { (`$true) -and (`$false), ('got') }   # " + $script:ACC_ALLOW + ' executes the shape on purpose'
    $r = Get-AccFindings -Text ($stHead + $allowed + $stTail)
    AccT ($MNF + '  a fixture that executes the shape on purpose carries the allow marker and is listed as allowed') ($r.Counted.Count -eq 0 -and $r.Listed.Count -eq 1 -and $r.Listed[0].Why -eq 'allowed') (AccGot $r)

    # ---- CLEAN TWIN -----------------------------------------------------------------------------------------------
    $prod = "function Get-Pair(`$a, `$b, `$c) {`n  `$pair = `$a -and `$b, `$c`n  return `$pair`n}`n"
    $r = Get-AccFindings -Text $prod
    AccT 'CLEAN TWIN  an array literal after -and in production code, outside every self-test and case call, is LISTED with its reason, never counted' ($r.Counted.Count -eq 0 -and $r.Listed.Count -eq 1 -and $r.Listed[0].Line -eq 2 -and $r.Listed[0].Why -like 'outside*') (AccGot $r)
    # The mechanism the rule rests on: run both spellings with a FALSE last condition.
    $bad = @(& { ($true) -and ($false), ('got') })   # and-comma-case:allow the runtime twin executes the founding shape
    $good = @(& { (($true) -and ($false)), ('got') })
    AccT 'CLEAN TWIN  at runtime the swallowed form returns ONE $true for a false last condition, the fixed form returns (False, got)' ($bad.Count -eq 1 -and $bad[0] -eq $true -and $good.Count -eq 2 -and $good[0] -eq $false -and $good[1] -eq 'got') ('bad=' + ($bad -join '|') + ' good=' + ($good -join '|'))

    # ---- THE PIN: at the bar and a step past it -----------------------------------------------------------------
    $pend = @{ 'ops\x.ps1' = [pscustomobject]@{ Max = 28; Why = 'fixture' } }
    $at = Test-AccPending -Counts @{ 'ops\x.ps1' = 28 } -Pending $pend
    $past = Test-AccPending -Counts @{ 'ops\x.ps1' = 29 } -Pending $pend
    $zero = Test-AccPending -Counts @{} -Pending $pend
    $at = @($at); $past = @($past); $zero = @($zero)
    AccT ($MNF + '  a pinned file AT its pin of 28 is held, not failed') ($at.Count -eq 1 -and $at[0].Verdict -eq 'held') ($at | ForEach-Object { $_.Verdict })
    AccT ($MF + '  a pinned file one site PAST its pin (29 over 28) is exceeded') ($past.Count -eq 1 -and $past[0].Verdict -eq 'exceeded') ($past | ForEach-Object { $_.Verdict })
    AccT 'CLEAN TWIN  a pinned file that reads 0 is clear, so the run can say the pin may go' ($zero.Count -eq 1 -and $zero[0].Verdict -eq 'clear' -and $zero[0].Count -eq 0) ($zero | ForEach-Object { $_.Verdict })

    # ---- THE WALK, FROM A WORKTREE ROOT (lib\tree-walk.ps1) ---------------------------------------------------
    $fxHit = $stHead + $rhBody + $stTail
    $wtFx = New-TcWorktreeFixture -Files @{ 'grocery\hidden.ps1' = $fxHit; 'ops\clean.ps1' = ($stHead + $fixed + $stTail)
                                            'ops\untracked.ps1' = $fxHit; 'ops\me.ps1' = 'Write-Output 2'
                                            'lib\mod.psm1' = $outside }
    try {
      $self = Join-Path $wtFx.Root 'ops\me.ps1'
      $found = Get-AccScanFiles -RootDir $wtFx.Root -Self $self
      $found = @($found)
      $hits = Measure-TcWorktreeFixture -Fixture $wtFx -Found $found
      AccT ($MF + '  a root that IS a worktree is scanned, not excluded whole (three .ps1 and a .psm1, not itself)') ($hits.Root -eq 4) ('root=' + $hits.Root)
      AccT ($MNF + '  a sibling worktree BELOW that root is still excluded') ($hits.Sibling -eq 0) ('sibling=' + $hits.Sibling)
      $trk = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
      foreach ($p in @('grocery\hidden.ps1', 'ops\clean.ps1', 'ops\me.ps1', 'lib\mod.psm1')) { [void]$trk.Add($p) }
      $tFound = Get-AccScanFiles -RootDir $wtFx.Root -Self $self -Tracked $trk
      $tFound = @($tFound)
      $sites = 0
      foreach ($f in $tFound) { $sites += (Get-AccFindings -Text ([IO.File]::ReadAllText($f.FullName)) -Path $f.FullName).Counted.Count }
      $tNames = ($tFound | ForEach-Object { $_.Name }) -join ','
      AccT 'CLEAN TWIN  the tracked walk reads the three tracked files, the .psm1 among them, never the untracked one: 3 files, 2 sites' ($tFound.Count -eq 3 -and $sites -eq 2 -and $tNames -match 'mod\.psm1' -and $tNames -notmatch 'untracked') ("files={0} sites={1} names={2}" -f $tFound.Count, $sites, $tNames)
    } finally { Remove-Item -LiteralPath $wtFx.Temp -Recurse -Force -ErrorAction SilentlyContinue }
  } catch {
    $script:cases++; $script:fail++
    Write-Output ('  FAIL  a case threw: ' + $_.Exception.Message)
  }
  if ($script:cases -ne $script:expectedCases) {
    Write-Output ("  FAIL  CASE COUNT  ran {0} case(s), the suite lists {1}" -f $script:cases, $script:expectedCases); $script:fail++
  }
  if ($script:fail) { Write-Output ("AND-COMMA-CASE SELF-TEST FAILED ({0} of {1} case(s))" -f $script:fail, $script:cases); exit 1 }
  Write-Output ("AND-COMMA-CASE SELF-TEST PASSED ({0} case(s): the founding blob fires on its 28 lines, the shape fires in a case body and a case call, the parenthesised and quoted forms stay silent, production code is listed, the pin holds at its bar and fails past it, and the walk reads a worktree root and only tracked files)" -f $script:cases)
  exit 0
}

# ------------------------------------------------------------------------------------------- live run
$rootFull = Get-TcRootFull $repo
$listedPaths = $null
$prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
try { $listedPaths = & git -C $rootFull -c core.quotepath=off ls-files -- '*.ps1' '*.psm1'; $gitRc = $LASTEXITCODE } finally { $ErrorActionPreference = $prevEap }
$listedPaths = @($listedPaths | Where-Object { $_ })
if ($gitRc -ne 0 -or $listedPaths.Count -eq 0) {
  Write-Output ("AND-COMMA-CASE AUDIT BLIND: git ls-files exited {0} and listed {1} .ps1/.psm1 path(s), so there is no tracked set to read." -f $gitRc, $listedPaths.Count)
  Exit-Guard -Name 'and-comma-case' -Summary 'blind=no-git-list' -Code 3
}
$tracked = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($p in $listedPaths) { [void]$tracked.Add(([string]$p -replace '/', '\')) }
$files = Get-AccScanFiles -RootDir $rootFull -Self $PSCommandPath -Tracked $tracked
$files = @($files)
if ($files.Count -eq 0) {
  Write-Output ("AND-COMMA-CASE AUDIT BLIND: git lists {0} .ps1/.psm1 path(s) and the walk resolved none of them, which means the discovery is broken rather than the tree being clean." -f $tracked.Count)
  Exit-Guard -Name 'and-comma-case' -Summary ("blind=walk-resolved-none listed={0}" -f $tracked.Count) -Code 3
}
$sites = New-Object System.Collections.ArrayList
$listedSites = New-Object System.Collections.ArrayList
$pinCounts = @{}
$parseErrorFiles = 0
foreach ($f in $files) {
  $r = Get-AccFindings -Text ([IO.File]::ReadAllText($f.FullName)) -Path $f.FullName
  if ($r.ParseErrors) { $parseErrorFiles++ }
  $rel = (Get-TcPathBelowRoot $f.FullName $rootFull).TrimStart('\')
  $isPinned = $script:ACC_PENDING.ContainsKey($rel)
  foreach ($h in $r.Counted) {
    if ($isPinned) { $pinCounts[$rel] = 1 + [int]$pinCounts[$rel] }
    else { [void]$sites.Add(("{0}:{1}  [{2}]  swallowed {3}  |  {4}" -f $rel, $h.Line, $h.Where, $h.Swallowed, $h.Text)) }
  }
  foreach ($h in $r.Listed) { [void]$listedSites.Add(("{0}:{1}  ({2})  {3}" -f $rel, $h.Line, $h.Why, $h.Text)) }
}
$pins = Test-AccPending -Counts $pinCounts -Pending $script:ACC_PENDING
$pins = @($pins)
$exceeded = @($pins | Where-Object { $_.Verdict -eq 'exceeded' })
$pinned = 0; foreach ($pr in $pins) { $pinned += $pr.Count }
$summary = "listed={0} files={1} parse_error_files={2} sites={3} pinned={4} pins_exceeded={5} listed_not_counted={6}" -f $tracked.Count, $files.Count, $parseErrorFiles, $sites.Count, $pinned, $exceeded.Count, $listedSites.Count
Write-Output ("and-comma-case: git lists {0} tracked .ps1/.psm1; the walk resolved {1}, {2} with a parse error; {3} counted site(s) outside a pin, {4} under a pin, {5} listed and not counted" -f $tracked.Count, $files.Count, $parseErrorFiles, $sites.Count, $pinned, $listedSites.Count)
foreach ($pr in $pins) {
  $why = $script:ACC_PENDING[$pr.Path].Why
  switch ($pr.Verdict) {
    'held'     { Write-Output ("  pinned  {0}: {1} of {2} pinned site(s), {3}" -f $pr.Path, $pr.Count, $pr.Max, $why) }
    'clear'    { Write-Output ("  pinned  {0}: 0 site(s) - the pin CAN be removed from this file's ACC_PENDING" -f $pr.Path) }
    'exceeded' { Write-Output ("  PIN EXCEEDED  {0}: {1} site(s) against a pin of {2} - a NEW swallowed condition in a pinned file" -f $pr.Path, $pr.Count, $pr.Max) }
    default    { throw ("unknown pin verdict: " + $pr.Verdict) }
  }
}
foreach ($s in $listedSites) { Write-Output ('  listed (not counted)  ' + $s) }
if ($sites.Count -or $exceeded.Count) {
  foreach ($s in $sites) { Write-Output ('  site  ' + $s) }
  Write-Output ("AND-COMMA-CASE AUDIT FAILED: {0} self-test condition(s) swallowed by a comma, {1} pin(s) exceeded." -f $sites.Count, $exceeded.Count)
  Write-Output '  `a -and b, ''got''` parses as `a -and (b, ''got'')`: the array is always truthy, so b is never judged.'
  Write-Output '  Parenthesise the verdict: `((a) -and (b)), ''got''`. A fixture that executes the shape on purpose carries'
  Write-Output ('  # ' + $script:ACC_ALLOW + ' <reason> on the same line.')
  Exit-Guard -Name 'and-comma-case' -Summary $summary -Code 1
}
Write-Output 'and-comma-case: PASSED - no self-test case body or case-call argument outside a pin carries a condition swallowed by a comma.'
Exit-Guard -Name 'and-comma-case' -Summary $summary -Code 0
