<#
  audit-derived-size-callers.ps1 - does every builder that back-computes a package size from a unit price run the
  density refusal before it writes that size?

  SCOPE OF A CLEAN REPORT: UNSOUND and INCOMPLETE. It reads the PowerShell AST of every .ps1 below the root (archive,
  out, worktrees and vendored trees pruned on the path below the root; .claude\skills is read) and knows a derivation only by its two known spellings: a
  division whose left side is $lp, $linePrice or $line_price and whose right side is $up, $unitPrice or $unit_price,
  or a member of one ($up.value). A size derived under any other name (import-sams-prices' `$cur / $wpu`, a
  superseded cross-check that writes no size), in Python or in JavaScript is invisible, so a clean report proves only
  that no builder using THOSE spellings skips the rule. A finding is a candidate to read, not a verdict: the rule is
  structural (the enclosing function calls Test-DerivedSizeDensity and the file dot-sources
  derived-size-density-lib.ps1), so a function that calls it on a path the derived size never takes still reads as
  guarded, and a quotient that is never written as a size reads as a builder until its line says otherwise.

  WHY THIS EXISTS (queue 2026-09-21-85c3b7, grocery\triage-plans\plan-2026-09-22-2.json, Brad-ruled). One rule - a
  volume derived as linePrice / unitPrice must agree with the weight the name states, within
  derived-size-density-lib's band - had one library and two builders, and only build-sams-deals called it. Walmart's
  derived rows were written and then ruled by hand afterwards (Melinda's Jalapeno Ketchup 12 Ounce derived 4 fl oz on
  2026-08-30; SPECTRUM peanut oil 32 OZ derived 15.998 fl oz on 2026-09-19). walmart-row-lib's Build-Row gained the
  refusal on 2026-09-22; the plan's deviation recorded that the census stopping a THIRD builder was never built. This
  is that census: a two-copies-of-a-rule defect (F1) is fixed by memory once and by a gate every time after.

  WHAT A SITE IS, and its three states:
    guarded    the division's enclosing function (the script body when there is none) calls Test-DerivedSizeDensity,
               and the file dot-sources derived-size-density-lib.ps1 itself. These are the registered BUILDERS.
    allowed    the division's own line carries `# derived-size:allow <reason>` with a non-empty reason: a quotient that
               is never written as a size (audit-ingest-shape reads it into a message). A marker with no reason is
               not an allowance.
    unguarded  anything else. THE COUNT THIS RATCHETS.

  A RATCHET, and it starts at ZERO because nothing is owed: both builders route through the guard and the one other
  quotient carries its allowance. It is still a ratchet rather than a bare gate so it is written the way this estate
  writes them (ops\audit-write-only-reports.ps1 is the exemplar): the mark may only fall, a plain run never writes it,
  -Tighten records a believable fall, -Accept records whatever the count is. The mark carries NAMES as well as the
  count (lib\ratchet.ps1's Compare-TcRatchetSites), so a fix and a new builder in one change cannot hold the count.
  The registered builders are named in the mark too, and a run that no longer resolves one of them exits 2: a census
  that has lost sight of a builder it used to see is a spelling that moved, and silence there is the blind-detector
  shape. -Accept re-records the builder set after a deliberate removal. No numeric band is introduced here: the only
  numbers are counts.

  Usage:
    .\audit-derived-size-callers.ps1            census, report, ratchet against grocery\derived-size-callers-baseline.json; writes nothing
    .\audit-derived-size-callers.ps1 -Tighten   the same, and record a believable FALL as the new mark
    .\audit-derived-size-callers.ps1 -Accept    record the CURRENT count, unguarded names and builder set, whatever they are
    .\audit-derived-size-callers.ps1 -SelfTest  frozen fixtures, the two real builders read as text, and this script's
                                                live path run as a child against a temp tree and a temp baseline

  Exit: 0 = at or under the mark and every registered builder still resolved. 2 = a NEW unguarded site, a registered
  builder the census no longer resolves, or -Tighten refused an implausible fall. 3 = could not evaluate (nothing
  scanned, or the baseline absent or unreadable). The last line is AUDIT-DERIVED-SIZE-CALLERS-COMPLETE.
#>
# Its self-test reads the two real builders as TEXT (parsed, never loaded) and otherwise only temp trees it builds.
# gate-inputs: grocery\audit-derived-size-callers.ps1, lib\guard-contract.ps1, lib\ratchet.ps1, lib\lf-write.ps1, lib\tree-walk.ps1
# gate-inputs-text: grocery\walmart-row-lib.ps1, grocery\build-sams-deals.ps1
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop
param([switch]$SelfTest, [switch]$Accept, [switch]$Tighten, [string]$Root = '', [string]$BaselineFile = '')
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\ratchet.ps1')     # Read-TcRatchetBaseline, Test-RatchetMove, Compare-TcRatchetSites
. (Join-Path $repo 'lib\lf-write.ps1')    # Write-TcLfFile: the mark is tracked and stored eol=lf
. (Join-Path $repo 'lib\tree-walk.ps1')   # Get-TcTreeFiles, Get-TcPathBelowRoot: prune on the path BELOW the root

$script:DSC_NAME = 'audit-derived-size-callers'
$script:DSC_LP = @('lp', 'lineprice', 'line_price')
$script:DSC_UP = @('up', 'unitprice', 'unit_price')
# SKIPPING AN IMPOSSIBLE CASE IS NOT CHECKING LESS: an AST division of $lp by $up needs the lp name followed (after any
# closing parens and whitespace) by the slash, and the up name somewhere, so a file without both cannot hold a site and
# is not parsed. Scanned counts it all the same. The one spelling this skips is a comment between $lp and the slash.
$script:DSC_PRE_LP = '(?i)\$(?:lp|lineprice|line_price)\b\)*\s*/'
$script:DSC_PRE_UP = '(?i)\$(?:up|unitprice|unit_price)\b'
$script:DSC_ALLOW_RX = '#\s*derived-size:allow\b(.*)$'
$script:DSC_LIB_RX = '(?i)derived-size-density-lib\.ps1'
$script:DSC_GUARD = 'Test-DerivedSizeDensity'
# The path below the root that is never entered: archived and output trees, the worktrees under .claude, vendored code.
$script:DSC_PRUNE = '(?i)\\(?:archive|out|worktrees|node_modules|\.git|\.venv|venv|site-packages)\\'

function Get-DscVarName($Ast) {
  # The bare variable name under parentheses and a [type] cast, lower-cased; $null when it is not a variable.
  # UserPath with the scope stripped, never VariablePath.UnqualifiedPath, which is INTERNAL under PS 5.1 and reads $null.
  $a = $Ast
  for ($i = 0; $i -lt 6 -and $null -ne $a; $i++) {
    if ($a -is [System.Management.Automation.Language.ConvertExpressionAst]) { $a = $a.Child; continue }
    if ($a -is [System.Management.Automation.Language.ParenExpressionAst]) {
      $pe = $a.Pipeline
      if ($pe -is [System.Management.Automation.Language.PipelineAst] -and $pe.PipelineElements.Count -eq 1 -and
          $pe.PipelineElements[0] -is [System.Management.Automation.Language.CommandExpressionAst]) { $a = $pe.PipelineElements[0].Expression; continue }
      return $null
    }
    break
  }
  if ($a -is [System.Management.Automation.Language.VariableExpressionAst]) {
    return (([string]$a.VariablePath.UserPath) -replace '^\w+:', '').ToLowerInvariant()
  }
  return $null
}

function Get-DscUnitName($Ast) {
  # The right side: a unit-price variable, or a member of one ($up.value, $up.Value).
  $n = Get-DscVarName $Ast
  if ($n) { return $n }
  if ($Ast -is [System.Management.Automation.Language.MemberExpressionAst]) { return (Get-DscVarName $Ast.Expression) }
  return $null
}

function Find-DerivedSizeSites {
  <# The census, as ONE pure function over a (path below the root -> source text) map, so the fixture drives exactly
     the rule the live scan runs. Returns scanned, parsed, and every site with its state. #>
  param([hashtable]$Sources)
  $sites = New-Object System.Collections.Generic.List[object]
  $parsed = 0
  foreach ($f in @($Sources.Keys | Sort-Object)) {
    $text = [string]$Sources[$f]
    if ($text -notmatch $script:DSC_PRE_LP -or $text -notmatch $script:DSC_PRE_UP) { continue }
    $parsed++
    $tok = $null; $err = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tok, [ref]$err)
    $lines = $text -split "`r?`n"
    $dotsLib = @($ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and
        $n.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Dot -and
        $n.Extent.Text -match $script:DSC_LIB_RX }, $true)).Count -gt 0
    $divs = $ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.BinaryExpressionAst] -and
        $n.Operator -eq [System.Management.Automation.Language.TokenKind]::Divide }, $true)
    foreach ($d in $divs) {
      $ln = Get-DscVarName $d.Left
      $un = Get-DscUnitName $d.Right
      if (-not $ln -or -not $un) { continue }
      if ($script:DSC_LP -notcontains $ln -or $script:DSC_UP -notcontains $un) { continue }
      $fn = $null; $p = $d.Parent
      while ($null -ne $p) {
        if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $fn = $p; break }
        $p = $p.Parent
      }
      $scope = if ($fn) { $fn } else { $ast }
      $fnName = if ($fn) { [string]$fn.Name } else { '<script>' }
      $calls = @($scope.FindAll({ param($n)
          $n -is [System.Management.Automation.Language.CommandAst] -and
          [string]::Equals([string]$n.GetCommandName(), $script:DSC_GUARD, [StringComparison]::OrdinalIgnoreCase) }, $true)).Count
      $lineNo = $d.Extent.StartLineNumber
      $lineText = if ($lineNo -ge 1 -and $lineNo -le $lines.Count) { $lines[$lineNo - 1] } else { '' }
      $am = [regex]::Match($lineText, $script:DSC_ALLOW_RX)
      $reason = if ($am.Success) { $am.Groups[1].Value.Trim() } else { '' }
      $expr = ($d.Extent.Text -replace '\s+', ' ').Trim()
      $state = 'unguarded'; $why = ''
      if ($dotsLib -and $calls -gt 0) { $state = 'guarded' }
      elseif ($reason) { $state = 'allowed'; $why = $reason }
      else {
        $miss = @()
        if (-not $dotsLib) { $miss += 'the file does not dot-source derived-size-density-lib.ps1' }
        if ($calls -eq 0) { $miss += ($fnName + ' never calls ' + $script:DSC_GUARD) }
        if ($am.Success) { $miss += 'its derived-size:allow marker gives no reason' }
        $why = $miss -join '; '
      }
      $sites.Add([pscustomobject]@{
        file = [string]$f; function = $fnName; line = $lineNo; expr = $expr; state = $state; why = $why
        builder = ([string]$f + '::' + $fnName)
        key = ([string]$f + '::' + $fnName + '::' + $expr)
      })
    }
  }
  $all = $sites.ToArray()
  return [pscustomobject]@{
    scanned   = $Sources.Count
    parsed    = $parsed
    sites     = $all
    guarded   = @($all | Where-Object { $_.state -eq 'guarded' })
    allowed   = @($all | Where-Object { $_.state -eq 'allowed' })
    unguarded = @($all | Where-Object { $_.state -eq 'unguarded' })
  }
}

function Get-DscBuilderSet($Result) {
  # Each registered builder once, sorted ordinally.
  $set = New-Object 'System.Collections.Generic.SortedSet[string]' ([StringComparer]::Ordinal)
  foreach ($s in @($Result.guarded)) { [void]$set.Add([string]$s.builder) }
  return @($set)
}

function Get-DscLostBuilders([string[]]$Registered, [string[]]$Current) {
  # Builders the mark names that this run did not resolve: the census lost sight of them.
  $cur = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  foreach ($c in @($Current)) { if ($c) { [void]$cur.Add($c) } }
  return @(@($Registered) | Where-Object { $_ -and -not $cur.Contains($_) })
}

if ($SelfTest) {
  $bad = 0; $cases = 0
  function T([string]$n, [bool]$ok, [string]$got) {
    $script:cases++
    if ($ok) { Write-Output ('  ok    ' + $n) } else { Write-Output ('  X     ' + $n + '   got: ' + $got); $script:bad++ }
  }
  # Every fixture line is its own single-quoted literal and the file is joined with a newline, so no line is a
  # concatenation inside an array literal (the comma binds tighter than +).
  $nl = "`n"
  $libDot = '. (Join-Path $PSScriptRoot ''derived-size-density-lib.ps1'')'
  $unguardedSrc = @(
    'function Build-NewRow($raw) {',
    '  $lp = [double]$raw.lp',
    '  $up = [double]$raw.up',
    '  $qty = $lp / $up',
    '  return @{ size = $qty }',
    '}') -join $nl
  $guardedSrc = @(
    $libDot,
    'function Build-GuardedRow($raw) {',
    '  $lp = [double]$raw.lp; $up = [double]$raw.up',
    '  $derived = $lp / $up',
    '  $v = Test-DerivedSizeDensity $raw ''derived lp/up''',
    '  if ($v.Status -eq ''flag'') { return @{ err = ''DENSITY CONFLICT'' } }',
    '  return @{ size = $derived }',
    '}') -join $nl
  $wrongFnSrc = @(
    $libDot,
    'function Test-Other($r) { return (Test-DerivedSizeDensity $r ''x'') }',
    'function Build-SplitRow($raw) {',
    '  $lp = [double]$raw.lp; $up = [double]$raw.up',
    '  return @{ size = ($lp / $up) }',
    '}') -join $nl
  $noDotSrc = @(
    'function Build-NoLibRow($raw) {',
    '  $lp = [double]$raw.lp; $up = [double]$raw.up',
    '  $d = $lp / $up',
    '  $v = Test-DerivedSizeDensity $raw ''derived lp/up''',
    '  return @{ size = $d }',
    '}') -join $nl
  $memberSrc = @(
    'function Test-RowProves($Row) {',
    '  $lp = 3.0; $up = Get-Reading $Row.up',
    '  $derived = $lp / $up.value',
    '  return $derived',
    '}') -join $nl
  $allowSrc = @(
    'function Test-RowProves($Row) {',
    '  $lp = 3.0; $up = Get-Reading $Row.up',
    '  $derived = $lp / $up.value   # derived-size:allow the quotient is printed in a message and never written as a size',
    '  return $derived',
    '}') -join $nl
  $emptyAllowSrc = @(
    'function Test-RowProves($Row) {',
    '  $lp = 3.0; $up = 2.0',
    '  $derived = $lp / $up   # derived-size:allow',
    '  return $derived',
    '}') -join $nl
  $proseSrc = @(
    '# qty = $lp / $up is how Sam''s states a pack',
    '$msg = ''lp/up derives $lp / $up''',
    '$ratio = $lp / $total',
    '$other = $cost / $up') -join $nl

  $r1 = Find-DerivedSizeSites @{ 'grocery\build-new.ps1' = $unguardedSrc }
  T 'MUST FIRE  a new builder that derives $lp / $up with no density guard is an unguarded site' `
    (@($r1.unguarded).Count -eq 1 -and @($r1.unguarded)[0].function -eq 'Build-NewRow') ("unguarded=" + @($r1.unguarded).Count)
  $r2 = Find-DerivedSizeSites @{ 'grocery\build-split.ps1' = $wrongFnSrc }
  T 'MUST FIRE  the file dot-sources the lib but the BUILDER function never calls Test-DerivedSizeDensity (a call elsewhere does not guard it)' `
    (@($r2.unguarded).Count -eq 1 -and [string]@($r2.unguarded)[0].why -match 'Build-SplitRow never calls') ("unguarded=" + @($r2.unguarded).Count + ' why=' + (@($r2.unguarded) | ForEach-Object { $_.why }))
  $r3 = Find-DerivedSizeSites @{ 'grocery\build-nolib.ps1' = $noDotSrc }
  T 'MUST FIRE  the builder calls the guard but its file never dot-sources derived-size-density-lib' `
    (@($r3.unguarded).Count -eq 1 -and [string]@($r3.unguarded)[0].why -match 'does not dot-source') ("unguarded=" + @($r3.unguarded).Count)
  $r4 = Find-DerivedSizeSites @{ 'grocery\audit-x.ps1' = $memberSrc }
  T 'MUST FIRE  the member spelling $lp / $up.value (audit-ingest-shape''s) is a site too' `
    (@($r4.unguarded).Count -eq 1) ("unguarded=" + @($r4.unguarded).Count)
  $castSrc = @(
    'function Build-CastRow($raw) {',
    '  $linePrice = $raw.lp; $unitPrice = $raw.up',
    '  $q = ([double]$linePrice) / [double]$unitPrice',
    '  return @{ size = $q }',
    '}') -join $nl
  $r4b = Find-DerivedSizeSites @{ 'grocery\build-cast.ps1' = $castSrc }
  T 'MUST FIRE  the long spelling under a parenthesised [double] cast, ([double]$linePrice) / [double]$unitPrice, is a site too' `
    (@($r4b.unguarded).Count -eq 1) ("unguarded=" + @($r4b.unguarded).Count + ' parsed=' + $r4b.parsed)
  $r5 = Find-DerivedSizeSites @{ 'grocery\audit-x.ps1' = $emptyAllowSrc }
  T 'MUST FIRE  a derived-size:allow marker with no reason is not an allowance' `
    (@($r5.unguarded).Count -eq 1 -and @($r5.allowed).Count -eq 0 -and [string]@($r5.unguarded)[0].why -match 'gives no reason') ("unguarded=" + @($r5.unguarded).Count)
  $r6 = Find-DerivedSizeSites @{ 'grocery\build-guarded.ps1' = $guardedSrc }
  $r6Set = Get-DscBuilderSet $r6   # assign, then wrap: a one-element return unrolls to its string
  T 'MUST NOT FIRE  a guarded builder (dot-sources the lib, calls the guard in the same function) is registered, not a finding' `
    (@($r6.unguarded).Count -eq 0 -and @($r6.guarded).Count -eq 1 -and (@($r6Set) -join ',') -eq 'grocery\build-guarded.ps1::Build-GuardedRow') ("guarded=" + @($r6.guarded).Count + ' unguarded=' + @($r6.unguarded).Count + ' builders=' + (@($r6Set) -join ','))
  $r7 = Find-DerivedSizeSites @{ 'grocery\audit-x.ps1' = $allowSrc }
  T 'MUST NOT FIRE  a quotient whose line carries derived-size:allow with a reason is allowed, not a finding' `
    (@($r7.unguarded).Count -eq 0 -and @($r7.allowed).Count -eq 1) ("allowed=" + @($r7.allowed).Count + ' unguarded=' + @($r7.unguarded).Count)
  $r8 = Find-DerivedSizeSites @{ 'grocery\prose.ps1' = $proseSrc }
  T 'MUST NOT FIRE  $lp / $up in a comment or a string, and a division that is not lp by up, is no site at all' `
    (@($r8.sites).Count -eq 0 -and $r8.parsed -eq 1) ("sites=" + @($r8.sites).Count + ' parsed=' + $r8.parsed)
  $r9 = Find-DerivedSizeSites @{}
  T 'an empty corpus scans zero, so the live path can tell "nothing scanned" from "nothing found"' `
    ($r9.scanned -eq 0 -and @($r9.sites).Count -eq 0) ("scanned=" + $r9.scanned)
  $rMix = Find-DerivedSizeSites @{ 'a.ps1' = $unguardedSrc; 'b.ps1' = $guardedSrc; 'c.ps1' = 'Write-Output 1' }
  T 'the denominator is reported: 3 scanned, 2 parsed (the third carries neither name), 2 sites' `
    ($rMix.scanned -eq 3 -and $rMix.parsed -eq 2 -and @($rMix.sites).Count -eq 2) ("scanned=$($rMix.scanned) parsed=$($rMix.parsed) sites=" + @($rMix.sites).Count)
  $lost = Get-DscLostBuilders @('grocery\walmart-row-lib.ps1::Build-Row', 'grocery\build-sams-deals.ps1::Build-Row') @('grocery\build-sams-deals.ps1::Build-Row')
  T 'MUST FIRE  a registered builder the census no longer resolves is named as lost' `
    (@($lost).Count -eq 1 -and @($lost)[0] -eq 'grocery\walmart-row-lib.ps1::Build-Row') ("lost=" + (@($lost) -join ','))
  $lost0 = Get-DscLostBuilders @('grocery\build-sams-deals.ps1::Build-Row') @('grocery\build-sams-deals.ps1::Build-Row', 'grocery\build-new.ps1::Build-Row')
  T 'MUST NOT FIRE  a NEW guarded builder beside the registered one loses nothing' (@($lost0).Count -eq 0) ("lost=" + (@($lost0) -join ','))
  # CLEAN TWIN: the two REAL builders, read as text from this checkout, are both still counted as guarded builders.
  # This is the case that goes red the day a refactor renames $lp or moves the guard out of Build-Row.
  $realSrc = @{}
  foreach ($rel in @('grocery\walmart-row-lib.ps1', 'grocery\build-sams-deals.ps1')) {
    $full = Join-Path $repo $rel
    if (Test-Path -LiteralPath $full) { $realSrc[$rel] = [IO.File]::ReadAllText($full) }
  }
  $rReal = Find-DerivedSizeSites $realSrc
  $realSet = Get-DscBuilderSet $rReal
  T 'CLEAN TWIN  the existing registered builders (walmart-row-lib and build-sams-deals Build-Row) are still counted as guarded' `
    ($realSrc.Count -eq 2 -and @($rReal.unguarded).Count -eq 0 -and ($realSet -join ',') -eq 'grocery\build-sams-deals.ps1::Build-Row,grocery\walmart-row-lib.ps1::Build-Row') ("read=$($realSrc.Count) builders=" + ($realSet -join ',') + ' unguarded=' + @($rReal.unguarded).Count)

  # THE LIVE PATH, DRIVEN: this script as a child against a temp tree and a temp baseline, so the cases exercise the
  # code a gate runs. One directory per run, removed in finally, because concurrent pushes share %TEMP%.
  $wt = Join-Path $env:TEMP ('dsc-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $wt -ErrorAction Stop | Out-Null
  try {
    $fxTree = Join-Path $wt 'tree'
    New-Item -ItemType Directory -Path (Join-Path $fxTree 'grocery') -ErrorAction Stop | Out-Null
    $utf8 = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText((Join-Path $fxTree 'grocery\build-guarded.ps1'), $guardedSrc, $utf8)
    [IO.File]::WriteAllText((Join-Path $fxTree 'grocery\build-new.ps1'), $unguardedSrc, $utf8)   # exactly one unguarded site
    $newKey = '\grocery\build-new.ps1::Build-NewRow::$lp / $up'
    $gBuilder = '\grocery\build-guarded.ps1::Build-GuardedRow'
    $blFx = Join-Path $wt 'baseline.json'
    $seed = [ordered]@{ note = 'fixture note (queue fixture-q1)'; generated = '2026-01-01T00:00:00'; unguarded = 2
                        unguarded_sites = @($newKey, '\grocery\retired.ps1::Build-Old::$lp / $up'); builders = @($gBuilder); allowed = @() } | ConvertTo-Json -Depth 4
    $null = Write-TcLfFile $blFx $seed
    $seedB64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($blFx))
    $o1 = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $fxTree -BaselineFile $blFx)
    $rc1 = $LASTEXITCODE
    $same1 = [string]::Equals($seedB64, [Convert]::ToBase64String([IO.File]::ReadAllBytes($blFx)), [StringComparison]::Ordinal)
    T 'a FALL (1 unguarded, mark 2) without -Tighten is spoken and NOT written, so a gate run leaves its checkout clean' `
      ($rc1 -eq 0 -and $same1 -and (($o1 -join "`n") -match 'CAN tighten')) ("rc=$rc1 baselineUnchanged=$same1 last=" + $(if ($o1.Count) { $o1[-1] } else { '' }))
    $null = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $fxTree -BaselineFile $blFx -Tighten
    $rc2 = $LASTEXITCODE
    $b2 = [IO.File]::ReadAllBytes($blFx)
    $cr2 = 0; foreach ($x in $b2) { if ($x -eq 13) { $cr2++ } }
    $bom2 = ($b2.Length -ge 3 -and $b2[0] -eq 0xEF -and $b2[1] -eq 0xBB -and $b2[2] -eq 0xBF)
    $doc2 = $null
    if ($bom2) { $doc2 = [Text.Encoding]::UTF8.GetString($b2, 3, $b2.Length - 3) | ConvertFrom-Json }
    T '-Tighten records the fall in the bytes git stores: no CR, the BOM, one trailing LF, the note kept and the survivor named' `
      ($rc2 -eq 0 -and $cr2 -eq 0 -and $bom2 -and $b2[-1] -eq 10 -and $null -ne $doc2 -and [int]$doc2.unguarded -eq 1 -and
       [string]$doc2.note -eq 'fixture note (queue fixture-q1)' -and (@($doc2.unguarded_sites) -join '|') -eq $newKey) `
      ("rc=$rc2 cr=$cr2 bom=$bom2 unguarded=$(if ($doc2) { $doc2.unguarded }) sites=$(if ($doc2) { @($doc2.unguarded_sites) -join '|' })")
    $blRise = Join-Path $wt 'baseline-rise.json'
    $null = Write-TcLfFile $blRise ([ordered]@{ note = 'fixture'; generated = '2026-01-01T00:00:00'; unguarded = 0; unguarded_sites = @(); builders = @($gBuilder); allowed = @() } | ConvertTo-Json -Depth 4)
    $o3 = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $fxTree -BaselineFile $blRise)
    $rc3 = $LASTEXITCODE
    T 'CLEAN TWIN  a new unguarded builder over a mark of 0 still fails the run with exit 2, so not writing on a fall did not disarm the ratchet' `
      ($rc3 -eq 2 -and (($o3 -join "`n") -match 'NEW UNGUARDED')) ("rc=$rc3")
  } finally {
    Remove-Item -LiteralPath $wt -Recurse -Force -ErrorAction SilentlyContinue
  }
  # A LITERAL CASE LIST KNOWS ITS OWN NUMBER, so a case that never ran is a defect, not a smaller suite.
  $expectedCases = 17
  if ($cases -ne $expectedCases) { Write-Output ("  X     the suite ran $cases case(s), expected $expectedCases"); $bad++ }
  if ($bad -eq 0) {
    Write-Output ("DERIVED-SIZE-CALLERS SELF-TEST PASS ($cases of $cases)")
    Write-GuardComplete -Name $script:DSC_NAME -Summary ("selftest=pass cases=$cases"); exit 0
  }
  Write-Output ("DERIVED-SIZE-CALLERS SELF-TEST FAIL ($bad of $cases)")
  Write-GuardComplete -Name $script:DSC_NAME -Summary ("selftest=fail cases=$cases failed=$bad"); exit 1
}

# ---- live census ----
if (-not $Root) { $Root = $repo }
$rootFull = Get-TcRootFull $Root
$srcs = @{}
foreach ($fi in @(Get-TcTreeFiles -RootFull $rootFull -Filter '*.ps1' -PruneBelow $script:DSC_PRUNE)) {
  if ($fi.Extension -ne '.ps1') { continue }   # -Filter '*.ps1' also returns .ps1xml
  # THIS FILE MUST NOT SCAN ITSELF: a detector that reads its own fixtures cannot fail.
  if ([string]::Equals($fi.FullName, $PSCommandPath, [StringComparison]::OrdinalIgnoreCase)) { continue }
  $rel = Get-TcPathBelowRoot $fi.FullName $rootFull
  if ($rel -match $script:DSC_PRUNE) { continue }
  try { $srcs[$rel] = [IO.File]::ReadAllText($fi.FullName) } catch { }
}
if ($srcs.Count -eq 0) {
  Write-Output ($script:DSC_NAME + ': BLIND - zero .ps1 files reached the census, so a clean result would prove nothing')
  Exit-Guard -Name $script:DSC_NAME -Summary 'scanned=0 findings=0 blind=no-sources' -Code 3
}
$res = Find-DerivedSizeSites $srcs
$builders = Get-DscBuilderSet $res
$ugKeys = @($res.unguarded | ForEach-Object { [string]$_.key })
$alKeys = @($res.allowed | ForEach-Object { [string]$_.key })
$n = @($res.unguarded).Count
Write-Output ("{0}: scanned {1} .ps1 file(s), parsed {2} carrying both an lp and a up name; {3} derivation site(s): {4} guarded in {5} builder(s), {6} allowed, {7} unguarded" -f `
  $script:DSC_NAME, $res.scanned, $res.parsed, @($res.sites).Count, @($res.guarded).Count, @($builders).Count, @($res.allowed).Count, $n)
foreach ($s in @($res.sites | Sort-Object file, line)) {
  $tag = switch -CaseSensitive ($s.state) { 'guarded' { 'BUILDER  ' } 'allowed' { 'ALLOWED  ' } 'unguarded' { 'UNGUARDED' } default { throw ('unknown site state: ' + $s.state) } }
  $tail = if ($s.why) { '  - ' + $s.why } else { '' }
  Write-Output ('  {0} {1}:{2} {3}  {4}{5}' -f $tag, $s.file, $s.line, $s.function, $s.expr, $tail)
}

$blF = if ($BaselineFile) { $BaselineFile } else { Join-Path $here 'derived-size-callers-baseline.json' }
$bl = Read-TcRatchetBaseline -Path $blF -Field 'unguarded'
$script:DSC_NOTE = 'High-water mark for the derived-size caller census (queue 2026-09-21-85c3b7, plan-2026-09-22-2). unguarded may only go DOWN; builders are the registered builders that route through Test-DerivedSizeDensity, and a run that no longer resolves one exits 2.'
function Write-DscBaseline([int]$Count, [string[]]$Sites) {
  $note = if ($bl.Doc -and $bl.Doc.note) { [string]$bl.Doc.note } else { $script:DSC_NOTE }
  $json = [ordered]@{ note = $note; generated = (Get-Date).ToString('s'); unguarded = $Count
                      unguarded_sites = @($Sites); builders = @($builders); allowed = @($alKeys) } | ConvertTo-Json -Depth 4
  return (Write-TcLfFile $blF $json)
}
$summary = ("scanned={0} parsed={1} sites={2} builders={3} allowed={4} findings={5}" -f $res.scanned, $res.parsed, @($res.sites).Count, @($builders).Count, @($res.allowed).Count, $n)
if ($Accept) {
  $null = Write-DscBaseline $n $ugKeys
  Write-Output ("  baseline written: $n unguarded, builders " + ($(if (@($builders).Count) { $builders -join ', ' } else { 'none' })) + '. From here unguarded may only go DOWN.')
  Exit-Guard -Name $script:DSC_NAME -Summary ($summary + " baseline=$n") -Code 0
}
if ($bl.State -ne 'read') {
  Write-Output ("{0}: COULD NOT EVALUATE - the baseline {1} is {2} ({3}). Nothing written; -Accept records one." -f $script:DSC_NAME, $blF, $bl.State, $bl.Why)
  Exit-Guard -Name $script:DSC_NAME -Summary ($summary + ' blind=' + (Get-TcRatchetBlindToken $bl.State)) -Code 3
}
$base = [int]$bl.Value
$cmp = Compare-TcRatchetSites -Current $ugKeys -Baseline @($bl.Doc.unguarded_sites)
$lost = Get-DscLostBuilders @($bl.Doc.builders) $builders
$failed = $false
if ($n -gt $base -or $cmp.Verdict -eq 'rose') {
  foreach ($k in @($cmp.New)) { Write-Output ('  NEW UNGUARDED  ' + $k) }
  Write-Output ("{0}: RATCHET BROKEN - {1} unguarded derivation site(s), mark {2}. A builder derives a size as lp / up and does not run Test-DerivedSizeDensity in the same function with derived-size-density-lib dot-sourced; route it through the guard as walmart-row-lib's Build-Row does, or mark a quotient that is never written as a size with '# derived-size:allow <reason>'." -f $script:DSC_NAME, $n, $base)
  $failed = $true
}
if (@($lost).Count) {
  foreach ($k in @($lost)) { Write-Output ('  LOST BUILDER  ' + $k) }
  Write-Output ("{0}: CENSUS LOST {1} REGISTERED BUILDER(S) - a builder the mark names no longer resolves. Either its spelling moved out of the census's reach (fix the census) or it was removed on purpose (re-record with -Accept)." -f $script:DSC_NAME, @($lost).Count)
  $failed = $true
}
foreach ($b in @($builders)) { if (@($bl.Doc.builders) -notcontains $b) { Write-Output ('  new guarded builder, not yet in the mark: ' + $b + ' (record with -Tighten or -Accept)') } }
if ($failed) { Exit-Guard -Name $script:DSC_NAME -Summary ($summary + " baseline=$base") -Code 2 }
if ($n -lt $base) {
  $move = Test-RatchetMove -Name $script:DSC_NAME -Count $n -Baseline $base
  if ($move.Verdict -eq 'implausible') {
    Write-Output ('  ' + $move.Message + ' (-Accept is this script''s -AcceptDrop.)')
    if ($Tighten) { Exit-Guard -Name $script:DSC_NAME -Summary ($summary + " baseline=$base refused-to-lower") -Code 2 }
  } elseif ($Tighten) {
    $null = Write-DscBaseline $n $ugKeys
    Write-Output ("  ratchet tightened: $n unguarded, was $base. New baseline written - commit it, or it protects only this checkout.")
  } else {
    Write-Output ("  ratchet CAN tighten: $n unguarded, mark $base. NOT written: this may be a pre-push gate, and a rewrite here dirties the checkout being pushed without riding the push. Record it with -Tighten and commit grocery\derived-size-callers-baseline.json.")
  }
} elseif ($Tighten -and ((@($builders) -join '|') -ne (@($bl.Doc.builders) -join '|'))) {
  $null = Write-DscBaseline $n $ugKeys
  Write-Output '  builder set recorded (-Tighten): the count held and the registered builders changed.'
}
Write-Output ("{0}: {1} unguarded against a mark of {2}; every registered builder resolved." -f $script:DSC_NAME, $n, $base)
Exit-Guard -Name $script:DSC_NAME -Summary ($summary + " baseline=$base") -Code 0
