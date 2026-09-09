# audit-lift-completeness.ps1
# ---------------------------------------------------------------------------------------------------
# A lifted function whose CALLEE was not lifted with it (2026-09-09, backlog I82).
#
# THE RECORDED INCIDENT THIS EXISTS FOR. `grocery/build-walmart-deals.ps1` lifts pricing functions out of
# `compare-deals.ps1` as source text, driven by a HAND-MAINTAINED list of function names. Its own comment
# records what happens when the list falls behind: the day `Test-NameOffersTwoSizes` was added and
# `Get-UnitPrice` began calling it, the lift produced a function whose callee did not exist, and the
# failure landed at RUN time as "not recognized as the name of a cmdlet". A self-test caught it that time.
# Nothing checks it in general, and the same list is duplicated across several builders.
#
# WHAT IT CHECKS. For every script that lifts by `foreach ($fn in @(...))` over `compare-deals.ps1`:
# extract exactly the functions that list names, find every command they call, and report any call to a
# function that compare-deals.ps1 DEFINES but the list did not lift. That closure check is the whole job.
#
# WHY THIS IS A DETECTOR AND NOT THE FIX. The fix is a provided interface - a dot-sourced library, the
# shape `match-lib.ps1` and `identity-lib.ps1` already have - and it is blocked on compare-deals.ps1
# running a pipeline on load, which is why nobody could dot-source it in the first place. That refactor
# touches the live pricing path for a paid site and is planned in
# `design/PLAN-compare-deals-interface-2026-09-09.md`. Until it lands, the hand-maintained lists stay,
# and this makes their one failure mode visible at gate time instead of at run time.
#
# SCOPE OF A CLEAN REPORT: UNSOUND, so a clean report proves nothing. It reads source text and knows one
# lifting spelling - a `foreach` over an inline `@('A','B')` list against a `compare-deals.ps1` read. A
# lifter that builds its list some other way, lifts a variable rather than a function, or calls through
# `&$name` is invisible to it. A finding it reports is real; silence is not proof there is none.
#
#   .\audit-lift-completeness.ps1
#   .\audit-lift-completeness.ps1 -SelfTest
# Exit 0 clean, 2 an incomplete lift, 3 could not evaluate.
# ---------------------------------------------------------------------------------------------------
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop
param(
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$runSelfTest = [bool]$SelfTest

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path -Parent $here
. (Join-Path $repo 'lib\guard-contract.ps1')

function Get-DefinedFunctionNames {
  param([string]$Text)
  $names = @()
  if (-not $Text) { return $names }
  foreach ($m in [regex]::Matches($Text, '(?m)^function\s+([A-Za-z][A-Za-z0-9]*-[A-Za-z0-9]+)')) {
    $names += $m.Groups[1].Value
  }
  return $names
}

function Get-LiftedNames {
  param([string]$Text)
  # The lifting spelling: foreach ($fn in @('A','B',...)). Returns every name across every such list.
  $names = @()
  if (-not $Text) { return $names }
  foreach ($m in [regex]::Matches($Text, '(?s)foreach\s*\(\s*\$\w+\s+in\s+@\((?<b>[^)]*)\)')) {
    foreach ($q in [regex]::Matches($m.Groups['b'].Value, "'([^']+)'")) { $names += $q.Groups[1].Value }
  }
  return $names
}

function Get-FunctionBody {
  param([string]$Text, [string]$Name)
  # Same extraction the lifters themselves use, so this audit fails exactly when they would.
  $m = [regex]::Match($Text, '(?ms)^function\s+' + [regex]::Escape($Name) + '\s*\(.*?^\}')
  if ($m.Success) { return $m.Value }
  return ''
}

function Remove-PsComments {
  param([string]$Text)
  # BLOCK comments FIRST, then line comments. Reducing PowerShell by line comments alone leaves a `<#`
  # block header readable as code, which is how a source scanner ends up enrolling prose as a
  # declaration - the estate has an audit for exactly that mistake.
  if (-not $Text) { return '' }
  $t = [regex]::Replace($Text, '(?s)<#.*?#>', '')
  $out = @()
  foreach ($line in ($t -split "`r?`n")) {
    $h = $line.IndexOf('#')
    if ($h -ge 0) { $out += $line.Substring(0, $h) } else { $out += $line }
  }
  return ($out -join "`n")
}

function Get-MissingCallees {
  param([string]$EngineText, [string[]]$Lifted, [string[]]$Defined)
  # Returns @{ fn=; callee= } for every call, from inside a lifted function, to a function the engine
  # DEFINES but the lift did not bring along.
  $out = @()
  foreach ($fn in $Lifted) {
    $body = Get-FunctionBody -Text $EngineText -Name $fn
    if (-not $body) { continue }
    # A NAME IN A COMMENT IS NOT A CALL. Measured 2026-09-09: without this, Get-UnitPrice reported calls
    # to Add-Norm and Get-MatchTexts that are both prose in its own explanatory comments, and the audit
    # would have been red on day one across three builders that have been running daily for months.
    $body = Remove-PsComments -Text $body
    foreach ($d in $Defined) {
      if ($Lifted -contains $d) { continue }
      if ($d -eq $fn) { continue }
      # a CALL is the bare name at a token boundary, not the definition line
      foreach ($c in [regex]::Matches($body, '(?m)(^|[^-\w])' + [regex]::Escape($d) + '(?=[\s\)\|;,]|$)')) {
        $out += @{ fn = $fn; callee = $d }
        break
      }
    }
  }
  return $out
}

# ---- self-test -------------------------------------------------------------------------------------
if ($runSelfTest) {
  $bad = 0
  function T([string]$n, [bool]$ok, [string]$got) {
    if ($ok) { Write-Output ("  ok    " + $n) } else { Write-Output ("  X     " + $n + "   got: " + $got); $script:bad++ }
  }

  # The founding incident, reconstructed: Get-UnitPrice starts calling Test-NameOffersTwoSizes and the
  # hand-maintained list was not updated.
  $engine = @"
function Get-UnitPrice (`$a) {
  if (Test-NameOffersTwoSizes `$a) { return 0 }
  return 1
}
function Test-NameOffersTwoSizes (`$a) {
  return `$false
}
function Get-PackCount (`$a) {
  return 1
}
"@
  $defined = @(Get-DefinedFunctionNames -Text $engine)
  T 'every function the engine defines is found' ($defined.Count -eq 3 -and $defined -contains 'Test-NameOffersTwoSizes') ([string]$defined.Count)

  $miss1 = @(Get-MissingCallees -EngineText $engine -Lifted @('Get-UnitPrice') -Defined $defined)
  T 'MUST FIRE  a lifted function calling an unlifted engine function is a finding' ($miss1.Count -eq 1 -and $miss1[0].callee -eq 'Test-NameOffersTwoSizes') ([string]$miss1.Count)

  $miss2 = @(Get-MissingCallees -EngineText $engine -Lifted @('Get-UnitPrice','Test-NameOffersTwoSizes') -Defined $defined)
  T 'MUST NOT FIRE  a complete lift reports nothing' ($miss2.Count -eq 0) ([string]$miss2.Count)

  # MUST NOT FIRE - an engine function nobody lifted and nobody calls is not a finding.
  $miss3 = @(Get-MissingCallees -EngineText $engine -Lifted @('Get-PackCount') -Defined $defined)
  T 'MUST NOT FIRE  an unlifted function that is never called is fine' ($miss3.Count -eq 0) ([string]$miss3.Count)

  $lift = Get-LiftedNames -Text "foreach (`$fn in @('Get-UnitPrice','Get-PackCount')) { }"
  T 'the lift list is read out of the foreach' (@($lift).Count -eq 2 -and $lift -contains 'Get-PackCount') ([string]@($lift).Count)
  $lift0 = Get-LiftedNames -Text 'nothing here at all'
  T 'MUST NOT FIRE  a script with no lift list yields no names' (@($lift0).Count -eq 0) ([string]@($lift0).Count)

  # MUST NOT FIRE - a name that appears only in a COMMENT is not a call. This is the false positive that
  # would have made this audit red on day one across three builders that run daily.
  $engineC = @"
function Get-UnitPrice (`$a) {
  # see Test-NameOffersTwoSizes for why this is not done here
  return 1
}
function Test-NameOffersTwoSizes (`$a) { return `$false }
"@
  $defC = @(Get-DefinedFunctionNames -Text $engineC)
  $missC = @(Get-MissingCallees -EngineText $engineC -Lifted @('Get-UnitPrice') -Defined $defC)
  T 'MUST NOT FIRE  a callee named only in a line comment is not a call' ($missC.Count -eq 0) ([string]$missC.Count)

  $engineB = @"
function Get-UnitPrice (`$a) {
<#
  Test-NameOffersTwoSizes is discussed at length here and never called.
#>
  return 1
}
function Test-NameOffersTwoSizes (`$a) { return `$false }
"@
  $missB = @(Get-MissingCallees -EngineText $engineB -Lifted @('Get-UnitPrice') -Defined @(Get-DefinedFunctionNames -Text $engineB))
  T 'MUST NOT FIRE  a callee named only in a BLOCK comment is not a call either' ($missB.Count -eq 0) ([string]$missB.Count)

  # MUST NOT FIRE - a function's own DEFINITION line must not be read as a call to itself.
  $miss4 = @(Get-MissingCallees -EngineText $engine -Lifted @('Test-NameOffersTwoSizes') -Defined $defined)
  T 'MUST NOT FIRE  a function is not reported as calling itself' (@($miss4 | Where-Object { $_.callee -eq 'Test-NameOffersTwoSizes' }).Count -eq 0) ([string]$miss4.Count)

  # CLEAN TWIN - the behaviour comment-stripping was most likely to have broken: a REAL call that shares
  # its line with a trailing comment must STILL be found. A positive assertion, and the one that would
  # have caught an over-eager strip.
  $engineT = @"
function Get-UnitPrice (`$a) {
  `$r = Test-NameOffersTwoSizes `$a   # the two-size refusal
  return `$r
}
function Test-NameOffersTwoSizes (`$a) { return `$false }
"@
  $missT = @(Get-MissingCallees -EngineText $engineT -Lifted @('Get-UnitPrice') -Defined @(Get-DefinedFunctionNames -Text $engineT))
  T 'CLEAN TWIN  a real call sharing a line with a trailing comment is still found' ($missT.Count -eq 1 -and $missT[0].callee -eq 'Test-NameOffersTwoSizes') ([string]$missT.Count)

  if ($bad -gt 0) { Write-Output ("lift-completeness SELF-TEST FAIL ({0})" -f $bad); exit 2 }
  Write-Output 'lift-completeness SELF-TEST PASS'
  Write-GuardComplete -Name 'lift-completeness' -Summary 'selftest pass'
  exit 0
}

# ---- sweep -----------------------------------------------------------------------------------------
$enginePath = Join-Path $repo 'grocery\compare-deals.ps1'
if (-not (Test-Path $enginePath)) { Write-Output 'lift-completeness: compare-deals.ps1 not found - could not evaluate.'; exit 3 }
$engineText = [IO.File]::ReadAllText($enginePath)
$defined = @(Get-DefinedFunctionNames -Text $engineText)
if (-not $defined.Count) { Write-Output 'lift-completeness: parsed ZERO function definitions out of the engine - discovery is broken, not clean.'; exit 3 }

$cands = @(Get-ChildItem (Join-Path $repo 'grocery') -Filter '*.ps1' -File -ErrorAction SilentlyContinue)
$scanned = 0; $findings = @()
foreach ($f in $cands) {
  if ($f.Name -eq 'compare-deals.ps1') { continue }
  $t = [IO.File]::ReadAllText($f.FullName)
  if ($t -notmatch 'compare-deals\.ps1') { continue }
  $lifted = @(Get-LiftedNames -Text $t | Where-Object { $defined -contains $_ })
  if (-not $lifted.Count) { continue }
  $scanned++
  foreach ($m in @(Get-MissingCallees -EngineText $engineText -Lifted $lifted -Defined $defined)) {
    $findings += [pscustomobject]@{ file = $f.Name; fn = $m.fn; callee = $m.callee }
  }
}

Write-Output ("lift-completeness: {0} lifting script(s) checked against {1} engine function(s)" -f $scanned, $defined.Count)
if ($findings.Count -gt 0) {
  Write-Output ("  {0} incomplete lift(s):" -f $findings.Count)
  foreach ($x in $findings) {
    Write-Output ("    {0,-32} lifts {1} which calls {2}, NOT in its list" -f $x.file, $x.fn, $x.callee)
  }
  Write-Output '  Add the callee to that list, or the lifted function fails at RUN time with "not recognized".'
  Write-GuardComplete -Name 'lift-completeness' -Summary ("scanned={0} findings={1}" -f $scanned, $findings.Count)
  exit 2
}
Write-Output '  every lifted function has every engine callee it needs'
Write-GuardComplete -Name 'lift-completeness' -Summary ("scanned={0} findings=0" -f $scanned)
exit 0
