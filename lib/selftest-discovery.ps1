# selftest-discovery.ps1 - THE one rule for which switch runs a script's self-test, as ops\run-gates.ps1 discovers it.
#
# WHY THIS EXISTS (2026-09-11). run-gates enrolled a script when its CODE matched the ordinary switch declaration or
# the dot-sourced gate-variable form, and ran it with -SelfTest. Three grocery libs gate their self-test on a RENAMED
# switch instead: grocery\search-verdict-lib.ps1 (-SearchVerdictSelfTest), grocery\capture-lib.ps1
# (-CaptureLibSelfTest) and grocery\ff-price-lib.ps1 (-FfPriceSelfTest). The rename is load-bearing: dot-sourced under
# PS 5.1 a param() block runs in the CALLER's scope, so a lib declaring the ordinary switch resets its caller's own
# switch to false, and on 2026-08-15 that disarmed pull-regular-familyfare.ps1's self-test and ran a live Freshop pull
# in its place. Neither form matched the three, a tree-wide search found no other caller, and so nothing automated ran
# their self-tests. Run by hand that day all three passed, and each went red (exit 1, naming the case) on one mutation
# of the logic it guards, so they were wired rather than recorded.
#
# THE RULE, in order:
#   1. the ordinary declaration, or the dot-sourced gate variable, anywhere in CODE -> 'SelfTest'. These are the two
#      regexes run-gates carried, moved here unchanged, so the set they enrol does not move.
#   2. otherwise a switch whose name ends in SelfTest, declared in the SCRIPT's own param block (never a function's),
#      AND read by an `if` whose condition is that variable alone or one operand of an -or chain -> that name.
#      Both halves are required because run-gates RUNS the file with the switch: a declared switch that gates nothing
#      would run the script's production body under the gate's name. A negated condition does not count, for the
#      same reason.
#   A script carrying both forms (grocery\ingredient-queue.ps1 gates on either) resolves by rule 1 and runs once.
#
# COMMENTS NEVER ENROL - run-gates' 2026-09-01 and 2026-09-07 notes, fixtured here for the first time. Rule 1 matches
# over Get-PsCodeOnly, which blanks block comments and drops comment lines; rule 2 reads the parsed param block, which
# prose cannot reach at all.
#
# DECLINED IS SPOKEN, NOT SWALLOWED. A script-level renamed switch that no `if` reads, or a file that spells one in
# code but does not parse, comes back with Declined set, and run-gates prints it: a self-test switch nothing runs is
# the defect this file was written for.
#
# SCOPE OF A CLEAN RESOLVE: unsound. It knows the spellings above. A self-test gated any other way - a [bool]
# parameter, a switch whose name does not end in SelfTest, $args read outside the dot-sourced form - resolves to
# nothing and is not reported. An empty answer proves the file carries none of THESE spellings, not that it has no
# self-test.
#
# A NEIGHBOUR, NOT A TWIN. lib\selftest-lib.ps1's Get-SelfTestBlock answers where the gated block IS, for
# ops\audit-mustfire-census.ps1 and ops\audit-fixture-inputs.ps1. Since 2026-09-11 it also reads a renamed switch, a
# variable captured from a switch and a compound condition, so the gates this file enrols are visible to those two
# audits. They differ over -or on purpose: this enrols a renamed switch that is one operand of an -or chain, because
# the switch does reach the body, and that refuses the chain unless EVERY operand is a self-test switch, because
# otherwise the body also runs in production.
#
# THE FIXTURES WRITE `~` FOR `$`, so this file's source never spells a declaration either rule would read
# ([[selftest-greps-its-own-source]]).
#
# NO param() BLOCK, DELIBERATELY: dot-sourced under PS 5.1 a param() block runs in the CALLER's scope and would reset
# the caller's own -SelfTest. Same rule as lib\ps-source.ps1 and lib\tree-walk.ps1.
#
# Dot-source:  . (Join-Path $repoRoot 'lib\selftest-discovery.ps1')
# Self-test:   powershell -File lib\selftest-discovery.ps1 -SelfTest

. (Join-Path $PSScriptRoot 'ps-source.ps1')   # Get-PsCodeOnly - no param() block, so it cannot reset ours
$__stdSelfTest = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-SelfTest')

function Get-TcSelfTestSwitch {
  # Which switch runs this script's self-test.
  # Returns { Switch = 'SelfTest' | a renamed switch's name | ''; Form = 'ordinary' | 'dot-sourced' | 'renamed' | '';
  #           Declined = '' | why a renamed declaration was not enrolled }.
  param([string]$Text)
  $out = [pscustomobject]@{ Switch = ''; Form = ''; Declined = '' }
  if ([string]::IsNullOrEmpty($Text)) { return $out }
  $code = Get-PsCodeOnly -Text $Text
  if ($code -match '\[switch\]\$SelfTest') { $out.Switch = 'SelfTest'; $out.Form = 'ordinary'; return $out }
  if ($code -match '\$__\w*SelfTest\s*=') { $out.Switch = 'SelfTest'; $out.Form = 'dot-sourced'; return $out }
  # A text filter before the parser: run-gates walks every script in the tree, and four of them spell this at all.
  if ($code -notmatch '\[switch\]\s*\$\w+SelfTest\b') { return $out }
  $errs = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$errs)
  if ($errs -and $errs.Count) {
    $out.Declined = 'spells a renamed self-test switch in code, but the file does not parse, so its param block cannot be read'
    return $out
  }
  $declared = New-Object System.Collections.Generic.List[string]
  if ($ast.ParamBlock) {
    foreach ($p in $ast.ParamBlock.Parameters) {
      $n = [string]$p.Name.VariablePath.UserPath
      if ($n -match '^\w+SelfTest$' -and $p.StaticType -eq [System.Management.Automation.SwitchParameter]) { $declared.Add($n) }
    }
  }
  if ($declared.Count -eq 0) { return $out }
  $ifs = $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.IfStatementAst] }, $true)
  foreach ($n in $declared) {
    foreach ($f in $ifs) {
      foreach ($c in $f.Clauses) {
        foreach ($operand in [regex]::Split($c.Item1.Extent.Text, '(?i)\s-or\s')) {
          if ([string]::Equals($operand.Trim(), ('$' + $n), [StringComparison]::OrdinalIgnoreCase)) {
            $out.Switch = $n; $out.Form = 'renamed'; return $out
          }
        }
      }
    }
  }
  $out.Declined = ('declares -' + ($declared -join ', -') + ' in its param block, but no if reads it as its condition, so running it with that switch would run the script body')
  return $out
}

if ($__stdSelfTest) {
  $ErrorActionPreference = 'Stop'
  $script:stdFail = 0
  $script:stdCases = 0
  function Test-StdCase([string]$Label, [scriptblock]$Check) {
    # A case that THROWS is a counted failure, never a skipped line: a suite whose cases all error must not pass.
    $script:stdCases++
    $ok = $false
    try { $ok = [bool](& $Check) } catch { $Label = $Label + ' (threw: ' + $_.Exception.Message + ')' }
    if ($ok) { Write-Output ('  PASS  ' + $Label) } else { Write-Output ('  FAIL  ' + $Label); $script:stdFail++ }
  }
  function New-StdText([string[]]$Lines) { return (($Lines -join "`n").Replace('~', '$')) }

  # ---- rule 2, the renamed switch ------------------------------------------------------------------------------
  $tRenamed = New-StdText -Lines @('<#', '  header: the switch is renamed, and that is load-bearing', '#>',
    'param([switch]~SearchVerdictSelfTest)', 'function Get-Ladder { 1 }', 'if (~SearchVerdictSelfTest) {', '  exit 0', '}')
  Test-StdCase 'MUST FIRE  a renamed switch in the script param block, gated by an if, resolves to its own name (the search-verdict-lib shape)' {
    $r = Get-TcSelfTestSwitch -Text $tRenamed
    ($r.Switch -ceq 'SearchVerdictSelfTest') -and ($r.Form -ceq 'renamed')
  }
  $tOrChain = New-StdText -Lines @('[CmdletBinding()]', 'param([int]~N = 3, [switch]~FfPriceSelfTest)', 'if (~Verbose -or ~FfPriceSelfTest) { exit 0 }')
  Test-StdCase 'MUST FIRE  a renamed switch among other parameters, gated as one operand of an -or chain, resolves' {
    (Get-TcSelfTestSwitch -Text $tOrChain).Switch -ceq 'FfPriceSelfTest'
  }

  # ---- prose never enrols: run-gates' 2026-09-01 (line comment) and 2026-09-07 (block comment) notes ---------------
  $tLineProse = New-StdText -Lines @('# run it as param([switch]~CaptureLibSelfTest), gated by if (~CaptureLibSelfTest)', 'param([string]~Path)', 'if (~CaptureLibSelfTest) { exit 0 }')
  Test-StdCase 'MUST NOT FIRE  a LINE comment quoting a renamed declaration does not enrol, even beside a real if reading that name' {
    $r = Get-TcSelfTestSwitch -Text $tLineProse
    ($r.Switch -ceq '') -and ($r.Declined -ceq '')
  }
  $tBlockProse = New-StdText -Lines @('<#', '  usage: param([switch]~CaptureLibSelfTest)', '  if (~CaptureLibSelfTest) { exit 0 }', '#>', 'param([string]~Path)', 'if (~CaptureLibSelfTest) { exit 0 }')
  Test-StdCase 'MUST NOT FIRE  a BLOCK comment quoting a renamed declaration does not enrol, even beside a real if reading that name' {
    $r = Get-TcSelfTestSwitch -Text $tBlockProse
    ($r.Switch -ceq '') -and ($r.Declined -ceq '')
  }
  $tOrdinaryLineProse = New-StdText -Lines @('# this file deliberately has no param([switch]~SelfTest)', 'Write-Output 1')
  Test-StdCase 'MUST NOT FIRE  a LINE comment quoting the ordinary declaration does not enrol (the 2026-09-01 run-gates recursion)' {
    (Get-TcSelfTestSwitch -Text $tOrdinaryLineProse).Switch -ceq ''
  }
  $tOrdinaryBlockProse = New-StdText -Lines @('<#', '  why there is no param([switch]~SelfTest) here', '#>', 'Write-Output 1')
  Test-StdCase 'MUST NOT FIRE  a BLOCK comment quoting the ordinary declaration does not enrol (the 8 libraries of 2026-09-07)' {
    (Get-TcSelfTestSwitch -Text $tOrdinaryBlockProse).Switch -ceq ''
  }
  $tString = New-StdText -Lines @('~needle = ''param([switch]~FooSelfTest)''', 'if (~FooSelfTest) { exit 0 }')
  Test-StdCase 'MUST NOT FIRE  a renamed declaration inside a STRING literal does not enrol' {
    (Get-TcSelfTestSwitch -Text $tString).Switch -ceq ''
  }

  # ---- a declaration run-gates must not run --------------------------------------------------------------------
  $tFunctionOnly = New-StdText -Lines @('function Invoke-Thing {', '  param([switch]~FooSelfTest)', '  if (~FooSelfTest) { return 1 }', '}', 'Invoke-Thing')
  Test-StdCase 'MUST NOT FIRE  a renamed switch declared only in a FUNCTION param block does not enrol the script' {
    (Get-TcSelfTestSwitch -Text $tFunctionOnly).Switch -ceq ''
  }
  $tUngated = New-StdText -Lines @('param([switch]~FooSelfTest)', 'Invoke-LivePull')
  Test-StdCase 'MUST NOT FIRE  a script-level renamed switch that no if reads does not enrol, and the reason is spoken' {
    $r = Get-TcSelfTestSwitch -Text $tUngated
    ($r.Switch -ceq '') -and ($r.Declined -match 'no if reads it')
  }
  $tNegated = New-StdText -Lines @('param([switch]~FooSelfTest)', 'if (-not ~FooSelfTest) { Invoke-LivePull }')
  Test-StdCase 'MUST NOT FIRE  a NEGATED condition is not a gate, so the script is not enrolled' {
    $r = Get-TcSelfTestSwitch -Text $tNegated
    ($r.Switch -ceq '') -and ($r.Declined -match 'no if reads it')
  }
  $tBroken = New-StdText -Lines @('param([switch]~FooSelfTest)', 'if (~FooSelfTest) {', '  ~a = ''unclosed')
  Test-StdCase 'MUST NOT FIRE  a file that does not parse is not enrolled on a half-read, and says why' {
    $r = Get-TcSelfTestSwitch -Text $tBroken
    ($r.Switch -ceq '') -and ($r.Declined -match 'does not parse')
  }

  # ---- rule 1 still resolves exactly as run-gates did ----------------------------------------------------------
  $tOrdinary = New-StdText -Lines @('param([switch]~SelfTest)', 'if (~SelfTest) { exit 0 }')
  Test-StdCase 'CLEAN TWIN  the ordinary declaration still resolves to SelfTest' {
    $r = Get-TcSelfTestSwitch -Text $tOrdinary
    ($r.Switch -ceq 'SelfTest') -and ($r.Form -ceq 'ordinary')
  }
  $tDotSourced = New-StdText -Lines @('~__xySelfTest = (~MyInvocation.InvocationName -ne ''.'') -and (~args -contains ''-SelfTest'')', 'if (~__xySelfTest) { exit 0 }')
  Test-StdCase 'CLEAN TWIN  the dot-sourced gate-variable form still resolves to SelfTest' {
    $r = Get-TcSelfTestSwitch -Text $tDotSourced
    ($r.Switch -ceq 'SelfTest') -and ($r.Form -ceq 'dot-sourced')
  }
  $tBoth = New-StdText -Lines @('param([switch]~IngredientQueueSelfTest, [switch]~SelfTest)', 'if (~SelfTest -or ~IngredientQueueSelfTest) { exit 0 }')
  Test-StdCase 'CLEAN TWIN  a script declaring both (the ingredient-queue shape) still resolves to SelfTest, so it runs once and unchanged' {
    $r = Get-TcSelfTestSwitch -Text $tBoth
    ($r.Switch -ceq 'SelfTest') -and ($r.Form -ceq 'ordinary')
  }
  $tCase = New-StdText -Lines @('param([switch]~ffPriceSelftest)', 'if (~FFPRICESELFTEST) { exit 0 }')
  Test-StdCase 'CLEAN TWIN  a renamed gate spelled in another case still resolves, as PowerShell binds it' {
    (Get-TcSelfTestSwitch -Text $tCase).Switch -ceq 'ffPriceSelftest'
  }

  if ($script:stdCases -eq 0) { Write-Output 'SELFTEST-DISCOVERY SELF-TEST FAILED (ran zero cases)'; exit 1 }
  if ($script:stdFail) { Write-Output ("SELFTEST-DISCOVERY SELF-TEST FAILED ({0} of {1} case(s))" -f $script:stdFail, $script:stdCases); exit 1 }
  Write-Output ("SELFTEST-DISCOVERY SELF-TEST PASSED ({0} of {0} case(s): renamed switches enrol with their own name, prose and ungated declarations never do, and the ordinary forms resolve as before)" -f $script:stdCases)
  exit 0
}
