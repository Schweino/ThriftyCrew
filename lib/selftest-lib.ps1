# selftest-lib.ps1 - find the self-test body of a PowerShell script, exactly.
#
# WHY THIS IS A LIB (2026-09-06, PLAN-top5-2026-09-06 area 4). Two audits need the same answer -
# ops\audit-fixture-inputs.ps1 asks which LIVE files a self-test reads, ops\audit-mustfire-census.ps1 asks
# how many must-fire assertions it carries - and this estate's most reliable bug is two copies of one rule
# drifting apart (pu-lib, the category-exclude bake, the notes-vs-bid check). ops\audit-twin-drift.ps1
# exists because of it. So there is one copy, here.
#
# WHY THE PARSER AND NOT A BRACE COUNT. Both hand-written versions of this were wrong, in opposite
# directions, and each looked right at a glance:
#
#   counting raw braces      ran to end-of-file on meal-prep\pipeline\rebid-ingredient.ps1, whose self-test
#                            pins a call site with $src.IndexOf("if (-not $Apply) { Write-Output") - an
#                            UNBALANCED brace inside a string. Three of that file's PRODUCTION reads were
#                            then reported against a self-test that never runs them.
#   masking strings first    fixed that and broke on APOSTROPHES IN COMMENTS ("the author's"), which open a
#                            string that swallows every brace to the next apostrophe. The audit then
#                            reported its OWN baseline read, from sixty lines past its own self-test.
#
# A guard whose scanner needs a PowerShell lexer should use the PowerShell lexer.
#
# WHICH CONDITIONS OPEN A SELF-TEST (widened 2026-09-11). Until then only a condition of exactly `$SelfTest`
# or `$__<name>SelfTest` counted. The meal-prep\pipeline idiom `$runSelfTest = [bool]$SelfTest` followed by
# `if ($runSelfTest)` was invisible, and so was grocery\ingredient-queue.ps1's
# `if ($SelfTest -or $IngredientQueueSelfTest)`. Measured at 8253ded82: 43 tracked .ps1 declaring
# [switch]$SelfTest had a block this could not find, 37 of them carrying 658 MUST FIRE lines over the whole
# file, and not one was in the census baseline - so a must-fire deleted from hunt-run.ps1 or
# map-preresolve.ps1 left the census green. A condition now counts when its body can only run as a self-test:
#
#   a self-test VARIABLE   $SelfTest, $__<name>SelfTest, a script-level [switch] parameter named *SelfTest,
#                          or a variable EVERY assignment of which copies one of those ([bool]$SelfTest,
#                          $SelfTest.IsPresent). One assignment from anything else and it is not one.
#   A -and B               at least one side is a self-test condition
#   A -or B                EVERY side is; `$SelfTest -or $Apply` runs in production too
#   anything else          no: -not, -xor, a comparison, a call
#
# EVERY SUCH BODY, NOT THE FIRST (same day). The first match used to win, so grocery\capture-watchdog.ps1's
# one-line `$runLog = if ($SelfTest) { $null } else { ... }` on line 40 was "the self-test", and the
# 225-line block on line 270 with its must-fire was never read. The answer is now every OUTERMOST self-test
# body in source order, joined by newlines; a body nested inside one already taken is not repeated. Joining
# can only ever ADD text to what the first match returned, so no census count can fall because of it.
#
# THREE MORE SHAPES (2026-09-11, later). The conditions above still left must-fire labels outside every body: 8
# files and 111 lines counting only files that spell SelfTest, and 274 label lines in 25 files by a comment-blind
# recount over every census file at 13b8b5df0. Each shape is read only where its body cannot run in production:
#
#   a guard-return          `if (-not <self-test condition>) { ...; exit }` whose LAST statement is exit or return:
#                           the statements after it in its own block (grocery\test-pull-agent-lib.ps1). A guard
#                           ending in anything else is refused - nine in the tree that day end in a try or an if,
#                           and the production path can fall through those.
#   Invoke-<name>SelfTest   a function so named: its body (meal-prep\pipeline\head-ingredients-lib.ps1). The verb is
#                           part of the rule, because grocery\audit-alert-registry.ps1's Test-InsideSelfTest is a
#                           predicate its live path calls on every Send-Alert site.
#   a whole-file suite      a file NAMED test-*.ps1 (pass -Path) in whose code no self-test variable appears outside
#                           the param block: from the param block, or the first statement, to the end, so the
#                           header comment is not read. grocery\test-auditors.ps1 declares no switch at all, and
#                           ops\test-prepush-hook.ps1 declares one only so run-gates finds it. A test-*.ps1 that
#                           reads its switch is read by its gated body alone: grocery\test-guards.ps1 mutates live
#                           files outside it. The name is the declaration; a file not so named is never read whole.
#
# SCOPE OF A CLEAN ANSWER: unsound. Still outside every body: a fixtures function with another name
# (meal-prep\pipeline\selftest-names-lib.ps1 Invoke-NamesFixtures), labels in a production path
# (meal-prep\pipeline\test-scaler-labels.ps1's generated page), and prose or messages that merely use the words
# (ops\run-gates.ps1's gate list, grocery\triage-lib.ps1's header).
#
# A NEIGHBOUR, NOT A TWIN. lib\selftest-discovery.ps1 answers which SWITCH run-gates runs a script with; this
# answers where the gated body IS. They differ over -or on purpose: discovery enrols `$Verbose -or $FfPriceSelfTest`
# because that switch does reach the body, and this refuses it because the body also runs without the switch.
#
# Dot-source:  . (Join-Path $repoRoot 'lib\selftest-lib.ps1')
# Self-test:   powershell -File lib\selftest-lib.ps1 -SelfTest
#
# NO param() BLOCK - same reason as lib\json-io.ps1 and lib\bot-paths.ps1: in PS 5.1 a dot-sourced param()
# runs in the CALLER's scope and would reset the caller's own -SelfTest to $false.
$__stlSelfTest = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-SelfTest')

function Get-SelfTestUnwrapped {
  <# Pure. Strip what does not change a condition's truth: a one-element pipeline, parentheses, a [bool] or
     [switch] cast, and .IsPresent. #>
  param($Node)
  while ($true) {
    if ($Node -is [System.Management.Automation.Language.PipelineAst] -and $Node.PipelineElements.Count -eq 1) { $Node = $Node.PipelineElements[0]; continue }
    if ($Node -is [System.Management.Automation.Language.CommandExpressionAst] -and -not $Node.Redirections.Count) { $Node = $Node.Expression; continue }
    if ($Node -is [System.Management.Automation.Language.ParenExpressionAst]) { $Node = $Node.Pipeline; continue }
    if ($Node -is [System.Management.Automation.Language.ConvertExpressionAst] -and
        $Node.Type.TypeName.FullName -match '^(bool|switch|System\.Boolean|System\.Management\.Automation\.SwitchParameter)$') { $Node = $Node.Child; continue }
    if ($Node -is [System.Management.Automation.Language.MemberExpressionAst] -and
        $Node -isnot [System.Management.Automation.Language.InvokeMemberExpressionAst] -and -not $Node.Static -and
        $Node.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $Node.Member.Value -eq 'IsPresent') { $Node = $Node.Expression; continue }
    return $Node
  }
}

function Get-SelfTestVariableName {
  <# Pure. A variable's name without its scope qualifier: $script:SelfTest is SelfTest. VariablePath has an
     UnqualifiedPath that says exactly this, and under PS 5.1 it is INTERNAL, so it reads as $null. #>
  param($Node)
  return ($Node.VariablePath.UserPath -replace '^(global|local|script|private):', '')
}

function Test-SelfTestCondition {
  <# Pure. Can the body behind this condition only run as a self-test? $Names is the self-test variable set. #>
  param($Node, $Names)
  $n = Get-SelfTestUnwrapped $Node
  if ($n -is [System.Management.Automation.Language.VariableExpressionAst]) { return $Names.Contains((Get-SelfTestVariableName $n)) }
  if ($n -is [System.Management.Automation.Language.BinaryExpressionAst]) {
    $l = Test-SelfTestCondition -Node $n.Left -Names $Names
    $r = Test-SelfTestCondition -Node $n.Right -Names $Names
    if ($n.Operator -eq [System.Management.Automation.Language.TokenKind]::And) { return ($l -or $r) }
    if ($n.Operator -eq [System.Management.Automation.Language.TokenKind]::Or) { return ($l -and $r) }
  }
  return $false
}

function Get-SelfTestBlock {
  <# Every outermost self-test body in the script, joined in source order (see WHICH CONDITIONS and THREE MORE
     SHAPES above). -Path is the script's path, and only its file name is read: the whole-file rule needs it, and
     a caller passing text alone gets every other shape. Returns '' when there is no such body AND when the file
     does not parse - a file that does not parse is a different problem, and run-gates and the pre-commit hook
     both catch it. #>
  param([string]$Text, [string]$Path = '')
  $errs = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$errs)
  if ($errs -and $errs.Count) { return '' }

  # PowerShell variable names are case-insensitive, so the set is too.
  $names = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  foreach ($v in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
    $vn = Get-SelfTestVariableName $v
    if ($vn -match '^(SelfTest|__\w*SelfTest)$') { [void]$names.Add($vn) }
  }
  if ($ast.ParamBlock) {
    foreach ($p in $ast.ParamBlock.Parameters) {
      $isSwitch = @($p.Attributes | Where-Object { $_ -is [System.Management.Automation.Language.TypeConstraintAst] -and
        $_.TypeName.FullName -match '^(switch|System\.Management\.Automation\.SwitchParameter)$' }).Count -gt 0
      $pn = Get-SelfTestVariableName $p.Name
      if ($isSwitch -and $pn -match 'SelfTest$') { [void]$names.Add($pn) }
    }
  }
  # A CAPTURE is a variable whose every assignment copies a self-test variable. Every one, not any one: a
  # $mode that starts as [bool]$SelfTest and is later set from $Apply gates production code.
  $byName = @{}
  foreach ($a in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
    $left = $a.Left
    while ($left -is [System.Management.Automation.Language.AttributedExpressionAst]) { $left = $left.Child }
    if ($left -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
    $k = Get-SelfTestVariableName $left
    if (-not $byName.ContainsKey($k)) { $byName[$k] = New-Object System.Collections.ArrayList }
    [void]$byName[$k].Add($a)
  }
  do {   # to a fixed point, so a copy of a copy counts
    $grew = $false
    foreach ($k in @($byName.Keys)) {
      if ($names.Contains($k)) { continue }
      $every = $true
      foreach ($a in $byName[$k]) {
        $r = Get-SelfTestUnwrapped $a.Right
        if ($a.Operator -ne [System.Management.Automation.Language.TokenKind]::Equals -or
            $r -isnot [System.Management.Automation.Language.VariableExpressionAst] -or
            -not $names.Contains((Get-SelfTestVariableName $r))) { $every = $false; break }
      }
      if ($every) { [void]$names.Add($k); $grew = $true }
    }
  } while ($grew)

  # Every candidate is a span of $Text; the outermost ones are kept below.
  $spans = New-Object System.Collections.ArrayList
  foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] }, $true)) {
    foreach ($c in $f.Clauses) {
      if (Test-SelfTestCondition -Node $c.Item1 -Names $names) {
        [void]$spans.Add([pscustomobject]@{ S = $c.Item2.Extent.StartOffset; E = $c.Item2.Extent.EndOffset })
      }
    }
    # A GUARD-RETURN: `if (-not <self-test condition>) { ...; exit }` as a statement of its own block. Only an exit
    # or a return as the LAST statement counts; anything else there can let the production path fall through.
    if ($f.Clauses.Count -ne 1 -or $f.ElseClause) { continue }
    if ($f.Parent -isnot [System.Management.Automation.Language.NamedBlockAst] -and
        $f.Parent -isnot [System.Management.Automation.Language.StatementBlockAst]) { continue }
    $u = Get-SelfTestUnwrapped $f.Clauses[0].Item1
    if ($u -isnot [System.Management.Automation.Language.UnaryExpressionAst]) { continue }
    if ($u.TokenKind -ne [System.Management.Automation.Language.TokenKind]::Not -and
        $u.TokenKind -ne [System.Management.Automation.Language.TokenKind]::Exclaim) { continue }
    if (-not (Test-SelfTestCondition -Node $u.Child -Names $names)) { continue }
    $gs = $f.Clauses[0].Item2.Statements
    if (-not $gs.Count) { continue }
    $last = $gs[$gs.Count - 1]
    if ($last -isnot [System.Management.Automation.Language.ExitStatementAst] -and
        $last -isnot [System.Management.Automation.Language.ReturnStatementAst]) { continue }
    $after = $false; $first = -1; $end = -1
    foreach ($s in $f.Parent.Statements) {
      if ($after) { if ($first -lt 0) { $first = $s.Extent.StartOffset }; $end = $s.Extent.EndOffset }
      elseif ([object]::ReferenceEquals($s, $f)) { $after = $true }
    }
    if ($first -ge 0) { [void]$spans.Add([pscustomobject]@{ S = $first; E = $end }) }
  }

  # A FUNCTION NAMED Invoke-<name>SelfTest: its body. The verb is part of the rule (see THREE MORE SHAPES).
  foreach ($fd in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if (($fd.Name -replace '^(global|local|script|private):', '') -match '^Invoke-\w*SelfTest$') {
      [void]$spans.Add([pscustomobject]@{ S = $fd.Body.Extent.StartOffset; E = $fd.Body.Extent.EndOffset })
    }
  }

  # A WHOLE-FILE SUITE: a test-*.ps1 in whose code no self-test variable appears outside the param block.
  if ((($Path -split '[\\/]')[-1]) -match '^test-.+\.ps1$') {
    $inCode = $false
    foreach ($v in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
      if (-not $names.Contains((Get-SelfTestVariableName $v))) { continue }
      if ($ast.ParamBlock -and $v.Extent.StartOffset -ge $ast.ParamBlock.Extent.StartOffset -and
          $v.Extent.EndOffset -le $ast.ParamBlock.Extent.EndOffset) { continue }
      $inCode = $true; break
    }
    if (-not $inCode) {
      # From the param block, or the first statement when there is none, so the header comment is not read.
      $start = -1
      if ($ast.ParamBlock) { $start = $ast.ParamBlock.Extent.StartOffset }
      else {
        foreach ($nb in @($ast.DynamicParamBlock, $ast.BeginBlock, $ast.ProcessBlock, $ast.EndBlock)) {
          if ($nb -and $nb.Statements.Count) {
            $s0 = $nb.Statements[0].Extent.StartOffset
            if ($start -lt 0 -or $s0 -lt $start) { $start = $s0 }
          }
        }
      }
      if ($start -ge 0) { [void]$spans.Add([pscustomobject]@{ S = $start; E = $Text.Length }) }
    }
  }

  if (-not $spans.Count) { return '' }
  # Outermost first: by start, and the longer of two spans that start together. A span inside one already kept
  # is not repeated. The AST nests, so two spans never partly overlap.
  $ordered = @($spans | Sort-Object -Property @{ Expression = 'S'; Ascending = $true }, @{ Expression = 'E'; Descending = $true })
  $kept = New-Object System.Collections.ArrayList
  foreach ($sp in $ordered) {
    $inside = $false
    foreach ($k in $kept) { if ($sp.S -ge $k.S -and $sp.E -le $k.E) { $inside = $true; break } }
    if (-not $inside) { [void]$kept.Add($sp) }
  }
  return (@($kept | ForEach-Object { $Text.Substring($_.S, $_.E - $_.S) }) -join "`n")
}

if ($__stlSelfTest) {
  $fail = 0
  function StT([string]$m, [bool]$c) { if ($c) { Write-Output ('  PASS  ' + $m) } else { Write-Output ('  FAIL  ' + $m); $script:fail++ } }

  StT 'MUST FIRE: the ordinary switch form is found' `
      ((Get-SelfTestBlock -Text "param([switch]`$SelfTest)`nif (`$SelfTest) {`n  `$a = 1`n}`n") -match '\$a = 1')
  StT 'MUST FIRE: the dot-sourced-lib form ($__jioSelfTest) is found too' `
      ((Get-SelfTestBlock -Text "`$__jioSelfTest = `$true`nif (`$__jioSelfTest) {`n  `$b = 2`n}`n") -match '\$b = 2')
  # THE rebid-ingredient SHAPE: an unbalanced brace inside a string must not extend the block.
  $t = "if (`$SelfTest) {`n  `$g = `$src.IndexOf(`"if (-not `$Apply) { Write-Output`")`n}`n`$live = 'production'`n"
  StT 'MUST FIRE: an unbalanced brace inside a STRING does not carry the block past its closing brace' `
      ((Get-SelfTestBlock -Text $t) -notmatch 'production')
  # THE apostrophe-in-a-comment shape.
  $t2 = "if (`$SelfTest) {`n  # the author's own note, with one apostrophe`n  `$c = 3`n}`n`$live = 'production'`n"
  $b2 = Get-SelfTestBlock -Text $t2
  StT 'MUST FIRE: an apostrophe in a comment does not open a string that swallows the closing brace' `
      (($b2 -match '\$c = 3') -and ($b2 -notmatch 'production'))
  StT 'CLEAN TWIN: a nested scriptblock inside the self-test stays INSIDE it' `
      ((Get-SelfTestBlock -Text "if (`$SelfTest) {`n  1..3 | ForEach-Object { `$_ }`n  `$last = 9`n}`n") -match '\$last = 9')
  StT 'MUST NOT FIRE: a script with no self-test yields nothing' ((Get-SelfTestBlock -Text "Write-Output 'hi'") -eq '')
  StT 'MUST NOT FIRE: an unrelated if ($Apply) block is not mistaken for a self-test' `
      ((Get-SelfTestBlock -Text "param([switch]`$SelfTest, [switch]`$Apply)`nif (`$Apply) {`n  `$a = 1`n}`n") -eq '')
  # A file that does not parse must yield NOTHING rather than a half-read block that reports the wrong file.
  StT 'MUST NOT FIRE: a file that does not parse yields nothing, never a partial block' `
      ((Get-SelfTestBlock -Text "if (`$SelfTest) {`n  `$a = 'unclosed`n") -eq '')

  # THE WIDENED CONDITIONS (2026-09-11). Each MUST FIRE is a shape a real suite opens its self-test with, and
  # which the exact-name match could not see.
  $cap = "param([switch]`$SelfTest, [switch]`$Json)`n`$runSelfTest = [bool]`$SelfTest; `$runJson = [bool]`$Json`nif (`$runSelfTest) {`n  `$cap = 1`n}`n"
  StT 'MUST FIRE: a variable captured as [bool]$SelfTest opens the self-test (the meal-prep\pipeline idiom)' `
      ((Get-SelfTestBlock -Text $cap) -match '\$cap = 1')
  $isp = "param([switch]`$SelfTest)`n`$st = `$SelfTest.IsPresent`n`$again = `$st`nif (`$again) {`n  `$isp = 1`n}`n"
  StT 'MUST FIRE: a capture through .IsPresent, and a copy of that capture, open it too' `
      ((Get-SelfTestBlock -Text $isp) -match '\$isp = 1')
  $orSt = "param([switch]`$SelfTest, [switch]`$IngredientQueueSelfTest)`nif (`$SelfTest -or `$IngredientQueueSelfTest) {`n  `$iq = 1`n}`n"
  StT 'MUST FIRE: -or over two self-test switches opens it (the grocery\ingredient-queue.ps1 shape)' `
      ((Get-SelfTestBlock -Text $orSt) -match '\$iq = 1')
  $andSt = "param([switch]`$SelfTest, [switch]`$Quiet)`nif (`$SelfTest -and -not `$Quiet) {`n  `$an = 1`n}`n"
  StT 'MUST FIRE: -and with one self-test side opens it, because the body still needs the switch' `
      ((Get-SelfTestBlock -Text $andSt) -match '\$an = 1')
  $named = "param([switch]`$FfPriceSelfTest)`nif (`$FfPriceSelfTest) {`n  `$ff = 1`n}`n"
  StT 'MUST FIRE: a script-level [switch] named *SelfTest opens it (the grocery\ff-price-lib.ps1 shape)' `
      ((Get-SelfTestBlock -Text $named) -match '\$ff = 1')
  # THE capture-watchdog SHAPE: a one-line expression-if near the top used to BE the self-test.
  $late = "param([switch]`$SelfTest)`n`$runLog = if (`$SelfTest) { `$null } else { 'log' }`nWrite-Output 'production'`nif (`$SelfTest) {`n  `$late = 1`n}`n"
  $bl = Get-SelfTestBlock -Text $late
  StT 'MUST FIRE: an earlier one-line if ($SelfTest) no longer hides the real block below it' `
      (($bl -match '\$late = 1') -and ($bl -notmatch 'production'))

  StT 'MUST NOT FIRE: -or with an unrelated switch runs in production, so it is not a self-test' `
      ((Get-SelfTestBlock -Text "param([switch]`$SelfTest, [switch]`$Apply)`nif (`$SelfTest -or `$Apply) {`n  `$a = 1`n}`n") -eq '')
  StT 'MUST NOT FIRE: a variable captured from an unrelated switch is not a self-test' `
      ((Get-SelfTestBlock -Text "param([switch]`$Apply)`n`$runApply = [bool]`$Apply`nif (`$runApply) {`n  `$a = 1`n}`n") -eq '')
  StT 'MUST NOT FIRE: the negation is the production path' `
      ((Get-SelfTestBlock -Text "param([switch]`$SelfTest)`nif (-not `$SelfTest) {`n  `$a = 1`n}`n") -eq '')
  $moved = "param([switch]`$SelfTest, [switch]`$Apply)`n`$mode = [bool]`$SelfTest`n`$mode = `$Apply`nif (`$mode) {`n  `$m = 1`n}`n"
  StT 'MUST NOT FIRE: a capture that is later reassigned from anything else is not a self-test' `
      ((Get-SelfTestBlock -Text $moved) -eq '')
  StT 'MUST NOT FIRE: a counter merely NAMED for self-tests, in a comparison, is not one (the run-gates shape)' `
      ((Get-SelfTestBlock -Text "`$withSelfTest = @()`nif (`$withSelfTest.Count -lt 150) {`n  `$a = 1`n}`nif (`$withSelfTest) {`n  `$b = 1`n}`n") -eq '')
  $nest = "`$runSelfTest = [bool]`$SelfTest`nif (`$runSelfTest) {`n  if (`$runSelfTest -and `$x) {`n    `$nested = 1`n  }`n}`n"
  StT 'CLEAN TWIN: a self-test if nested inside the self-test body is in the text exactly once' `
      (([regex]::Matches((Get-SelfTestBlock -Text $nest), 'nested = 1')).Count -eq 1)

  # THREE MORE SHAPES (2026-09-11, later). Each MUST FIRE is a real suite's opening; each MUST NOT FIRE is a production
  # path one of the three rules would take if it were one word looser.
  $guard = "param([switch]`$SelfTest)`nfunction Find-Node { 'finder' }`nif (-not `$SelfTest) { Write-Output 'pass -SelfTest'; exit 0 }`n`$gr = 1`n"
  $bg = Get-SelfTestBlock -Text $guard
  StT 'MUST FIRE: the code after if (-not $SelfTest) { ...; exit 0 } is the self-test (the grocery\test-pull-agent-lib.ps1 shape)' `
      (($bg -match '\$gr = 1') -and ($bg -notmatch 'pass -SelfTest') -and ($bg -notmatch 'finder'))
  StT 'MUST FIRE: a dot-sourced lib guard, if (!$__abSelfTest) { return }, opens it too' `
      ((Get-SelfTestBlock -Text "`$__abSelfTest = `$false`nif (!`$__abSelfTest) { return }`n`$gd = 1`n") -match '\$gd = 1')
  $fnSrc = "function Get-HeadThing { 'production' }`nfunction Invoke-HiSelfTest {`n  `$hi = 1`n}`n"
  $bf = Get-SelfTestBlock -Text $fnSrc
  StT 'MUST FIRE: the body of a function named Invoke-<name>SelfTest is a self-test (the head-ingredients-lib shape)' `
      (($bf -match '\$hi = 1') -and ($bf -notmatch 'production'))
  $whole = "<#`n  test-auditors.ps1 - header prose`n#>`n[CmdletBinding()]`nparam([string]`$SkipUnitsFile = '')`n`$wf = 1`n"
  $bw = Get-SelfTestBlock -Text $whole -Path 'C:\x\grocery\test-auditors.ps1'
  StT 'MUST FIRE: a test-*.ps1 with no self-test switch is a whole-file suite from its param block on (the test-auditors shape)' `
      (($bw -match '\$wf = 1') -and ($bw -match 'SkipUnitsFile') -and ($bw -notmatch 'header prose'))
  $declared = "param([switch]`$SelfTest)   # accepted so run-gates discovers this file; the cases run either way`n`$wf2 = 1`n"
  StT 'MUST FIRE: a test-*.ps1 whose -SelfTest switch nothing reads is a whole-file suite (the test-prepush-hook shape)' `
      ((Get-SelfTestBlock -Text $declared -Path 'ops\test-prepush-hook.ps1') -match '\$wf2 = 1')

  StT 'MUST NOT FIRE: a negated guard ending in a try, not an exit, lets production fall through (grocery\build-aldi-regular.ps1)' `
      ((Get-SelfTestBlock -Text "param([switch]`$SelfTest)`nif (-not `$SelfTest) { try { Invoke-LivePull } finally { `$z = 0 } }`n`$after = 1`n") -eq '')
  StT 'MUST NOT FIRE: a guard whose exit is itself conditional does not gate what follows' `
      ((Get-SelfTestBlock -Text "param([switch]`$SelfTest)`nif (-not `$SelfTest) { if (`$Force) { exit 0 } }`n`$after = 1`n") -eq '')
  StT 'MUST NOT FIRE: a guard-return on an unrelated switch leaves production code after it' `
      ((Get-SelfTestBlock -Text "param([switch]`$Apply)`nif (-not `$Apply) { exit 0 }`n`$apply = 1`n") -eq '')
  StT 'MUST NOT FIRE: a guard on -not ($SelfTest -or $Apply) lets -Apply alone through' `
      ((Get-SelfTestBlock -Text "param([switch]`$SelfTest, [switch]`$Apply)`nif (-not (`$SelfTest -or `$Apply)) { exit 0 }`n`$either = 1`n") -eq '')
  StT 'MUST NOT FIRE: a counter merely named for self-tests, guarding an exit, is not one (the ops\run-gates.ps1 shape)' `
      ((Get-SelfTestBlock -Text "`$withSelfTest = @()`nif (-not `$withSelfTest.Count) { exit 3 }`n`$live = 1`n") -eq '')
  StT 'MUST NOT FIRE: Test-InsideSelfTest is a predicate the live path calls, not a self-test (grocery\audit-alert-registry.ps1)' `
      ((Get-SelfTestBlock -Text "function Test-InsideSelfTest {`n  param(`$Node)`n  `$p = 1`n}`n") -eq '')
  StT 'MUST NOT FIRE: an unread -SelfTest switch in a file NOT named test-*.ps1 is not a whole-file suite' `
      ((Get-SelfTestBlock -Text $declared -Path 'grocery\pull-regular-thing.ps1') -eq '')
  StT 'MUST NOT FIRE: a name that merely contains test- is not a suite name' `
      ((Get-SelfTestBlock -Text $declared -Path 'grocery\latest-test-run.ps1') -eq '')
  StT 'MUST NOT FIRE: without -Path the whole-file rule cannot apply, so a caller passing text alone gets the old answer' `
      ((Get-SelfTestBlock -Text $whole) -eq '')
  $tg = "param([switch]`$SelfTest)`nif (`$SelfTest) {`n  `$st = 1`n}`n`$live = 'production'`n"
  $btg = Get-SelfTestBlock -Text $tg -Path 'grocery\test-guards.ps1'
  StT 'MUST NOT FIRE: a test-*.ps1 that READS its switch is read by its gated body alone (grocery\test-guards.ps1 mutates live files outside it)' `
      (($btg -match '\$st = 1') -and ($btg -notmatch 'production'))
  $onceSrc = "param([switch]`$SelfTest)`nif (-not `$SelfTest) { exit 0 }`nif (`$SelfTest) {`n  `$once = 1`n}`nfunction Invoke-XSelfTest {`n  `$inner = 1`n}`n"
  $bo = Get-SelfTestBlock -Text $onceSrc
  StT 'CLEAN TWIN: an if body and an Invoke-*SelfTest function inside a guard-return span are each read exactly once' `
      ((([regex]::Matches($bo, 'once = 1')).Count -eq 1) -and (([regex]::Matches($bo, 'inner = 1')).Count -eq 1))

  if ($fail) { Write-Output "SELFTEST-LIB SELF-TEST FAILED ($fail)"; exit 1 }
  Write-Output 'SELFTEST-LIB SELF-TEST PASSED (every opening shape found - gated body, guard-return, Invoke-*SelfTest, whole-file suite - production paths refused, and the two shapes that broke the hand-written scanners are armed)'
  exit 0
}
