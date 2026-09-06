# selftest-lib.ps1 - find the `if ($SelfTest) { ... }` body of a PowerShell script, exactly.
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
# Dot-source:  . (Join-Path $repoRoot 'lib\selftest-lib.ps1')
# Self-test:   powershell -File lib\selftest-lib.ps1 -SelfTest
#
# NO param() BLOCK - same reason as lib\json-io.ps1 and lib\bot-paths.ps1: in PS 5.1 a dot-sourced param()
# runs in the CALLER's scope and would reset the caller's own -SelfTest to $false.
$__stlSelfTest = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-SelfTest')

function Get-SelfTestBlock {
  <# The body of `if ($SelfTest) { ... }`, or of the `$__<name>SelfTest` form the dot-sourced libs use.
     Returns '' when there is no such block AND when the file does not parse - a file that does not parse
     is a different problem, and run-gates and the pre-commit hook both catch it. #>
  param([string]$Text)
  $errs = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$errs)
  if ($errs -and $errs.Count) { return '' }
  $ifs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] }, $true)
  foreach ($f in $ifs) {
    foreach ($c in $f.Clauses) {
      if ($c.Item1.Extent.Text -match '^\s*\$(SelfTest|__\w*SelfTest)\s*$') { return $c.Item2.Extent.Text }
    }
  }
  return ''
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
  StT 'CLEAN TWIN: a script with no self-test yields nothing' ((Get-SelfTestBlock -Text "Write-Output 'hi'") -eq '')
  StT 'CLEAN TWIN: an unrelated if-block is not mistaken for a self-test' `
      ((Get-SelfTestBlock -Text "if (`$Apply) {`n  `$a = 1`n}`n") -eq '')
  # A file that does not parse must yield NOTHING rather than a half-read block that reports the wrong file.
  StT 'CLEAN TWIN: a file that does not parse yields nothing, never a partial block' `
      ((Get-SelfTestBlock -Text "if (`$SelfTest) {`n  `$a = 'unclosed`n") -eq '')

  if ($fail) { Write-Output "SELFTEST-LIB SELF-TEST FAILED ($fail)"; exit 1 }
  Write-Output 'SELFTEST-LIB SELF-TEST PASSED (both declaration forms found, and the two shapes that broke the hand-written scanners are armed)'
  exit 0
}
