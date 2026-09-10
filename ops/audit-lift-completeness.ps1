# audit-lift-completeness.ps1
# ---------------------------------------------------------------------------------------------------
# A lifted function whose CALLEE was not lifted with it (2026-09-09, backlog I82; widened 2026-09-10).
#
# THE RECORDED INCIDENT THIS EXISTS FOR. `grocery/build-walmart-deals.ps1` used to lift pricing functions
# out of `compare-deals.ps1` as source text, driven by a HAND-MAINTAINED list of function names. The day
# `Test-NameOffersTwoSizes` was added and `Get-UnitPrice` began calling it, the lift produced a function
# whose callee did not exist, and the failure landed at RUN time as "not recognized as the name of a
# cmdlet". A self-test caught it that time.
#
# WIDENED 2026-09-10 BECAUSE IT HAD GONE VACUOUS. I82 moved the pricing math into pricing-math-lib.ps1 and
# every builder dot-sources it, so nothing lifts from compare-deals.ps1 any more - and this audit, which
# looked only at compare-deals.ps1, printed "0 lifting script(s) checked" and exited 0 in run-gates on
# every push. The lifts still live read OTHER files: import-walmart-batch.ps1 cuts Build-Row and its
# helpers out of build-walmart-deals.ps1, and import-instacart-batch.ps1 cuts Merge-IwbRows out of
# import-walmart-batch.ps1 (`ops\count-source-lifters.ps1 -Script <file>` names them). So the SOURCE is
# now whichever grocery script the lifter reads, and it prints every lift it checked.
#
# WHAT IT CHECKS. For every grocery script with a `foreach ($fn in @(...))` lift list: find the grocery
# scripts it reads with Get-Content, take the functions the list names that a source defines, find every
# command their bodies call, and report any call to a function that SOURCE defines, the list did not
# lift, and the lifter does not define for itself. A lifter supplying its own copy is deliberate at least
# once: import-instacart-batch.ps1 defines Get-RowKey before its lift and must never lift the source's.
#
# WHY THIS IS A DETECTOR AND NOT THE FIX. The fix is the shape I82 gave the pricing math - a dot-sourced
# library - and for Build-Row that means moving it out of build-walmart-deals.ps1, the live Walmart price
# path. Until that is done the hand-maintained lists stay, and this makes their one failure mode visible
# at gate time instead of at run time.
#
# SCOPE OF A CLEAN REPORT: UNSOUND, so a clean report proves nothing. It reads source text and knows one
# lifting spelling - a `foreach` over an inline `@('A','B')` list, in a grocery script that Get-Contents
# another grocery script by a literal filename within 120 characters. A lifter that builds its list some
# other way, reads its source through a path variable, lifts a VARIABLE rather than a function (the
# `$script:UnitFamily` that import-walmart-batch.ps1 also takes is invisible here), or calls through
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

function Get-ReadSources {
  param([string]$Text)
  # The .ps1 filenames a script reads with Get-Content, named literally within 120 characters of the call.
  $names = @()
  if (-not $Text) { return $names }
  foreach ($m in [regex]::Matches($Text, '(?s)Get-Content\b.{0,120}?[''"\\]([\w.-]+\.ps1)[''"]')) {
    $names += $m.Groups[1].Value
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
  param([string]$EngineText, [string[]]$Lifted, [string[]]$Defined, [string[]]$Supplied = @())
  # Returns @{ fn=; callee= } for every call, from inside a lifted function, to a function the source
  # DEFINES but the lift did not bring along and the lifter does not SUPPLY itself.
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
      if ($Supplied -contains $d) { continue }
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

function Get-LiftFindings {
  param([string]$Dir)
  # @{ Files = scripts read; Checked = one line per (lifter, source) pair checked; Findings = rows }
  $files = @(Get-ChildItem -LiteralPath $Dir -Filter '*.ps1' -File -ErrorAction SilentlyContinue)
  $byName = @{}
  foreach ($f in $files) { $byName[$f.Name] = $f.FullName }
  $checked = New-Object System.Collections.ArrayList
  $findings = New-Object System.Collections.ArrayList
  foreach ($f in $files) {
    $t = [IO.File]::ReadAllText($f.FullName)
    $listed = @(Get-LiftedNames -Text $t)
    if (-not $listed.Count) { continue }
    $own = @(Get-DefinedFunctionNames -Text $t)
    $sources = @(Get-ReadSources -Text $t | Sort-Object -Unique)
    foreach ($s in $sources) {
      if ($s -eq $f.Name -or -not $byName.ContainsKey($s)) { continue }
      $srcText = [IO.File]::ReadAllText($byName[$s])
      $defined = @(Get-DefinedFunctionNames -Text $srcText)
      $lifted = @($listed | Where-Object { $defined -contains $_ })
      if (-not $lifted.Count) { continue }
      [void]$checked.Add(("{0} lifts {1} function(s) out of {2}" -f $f.Name, $lifted.Count, $s))
      foreach ($m in @(Get-MissingCallees -EngineText $srcText -Lifted $lifted -Defined $defined -Supplied $own)) {
        [void]$findings.Add([pscustomobject]@{ file = $f.Name; source = $s; fn = $m.fn; callee = $m.callee })
      }
    }
  }
  return @{ Files = $files.Count; Checked = $checked; Findings = $findings }
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

  # THE WIDENING (2026-09-10): lifts out of a file that is not compare-deals.ps1, discovered from a
  # directory the way the sweep discovers them. Frozen files in a temp dir, removed in finally.
  $fx = Join-Path $env:TEMP ('alc-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $fx -Force | Out-Null
  try {
    $W = { param($n, $b) [IO.File]::WriteAllText((Join-Path $fx $n), $b, (New-Object Text.UTF8Encoding($false))) }
    & $W 'builder.ps1' @'
function Resolve-Unit ($u) {
  return $u
}
function Build-Row ($raw) {
  return (Resolve-Unit $raw)
}
'@
    & $W 'short-importer.ps1' @'
$src = Get-Content (Join-Path $root 'builder.ps1') -Raw
foreach ($fn in @('Build-Row')) {
  Invoke-Expression ([regex]::Match($src, "(?ms)^function\s+$fn\s*\(.*?^\}")).Value
}
'@
    & $W 'full-importer.ps1' @'
$src = Get-Content (Join-Path $root 'builder.ps1') -Raw
foreach ($fn in @('Resolve-Unit','Build-Row')) {
  Invoke-Expression ([regex]::Match($src, "(?ms)^function\s+$fn\s*\(.*?^\}")).Value
}
'@
    & $W 'merger.ps1' @'
function Merge-Rows ($rows) {
  return ($rows | ForEach-Object { Get-RowKey $_ })
}
function Get-RowKey ($r) {
  return $r
}
'@
    & $W 'own-key.ps1' @'
function Get-RowKey ($r) {
  return 'mine'
}
$imp = Get-Content (Join-Path $root 'merger.ps1') -Raw
foreach ($fn in @('Merge-Rows')) {
  Invoke-Expression ([regex]::Match($imp, "(?ms)^function\s+$fn\s*\(.*?^\}")).Value
}
'@
    $lf = Get-LiftFindings -Dir $fx
    $short = @($lf.Findings | Where-Object { $_.file -eq 'short-importer.ps1' })
    T 'MUST FIRE  a lift out of a file that is NOT compare-deals, missing a callee, is a finding' ($short.Count -eq 1 -and $short[0].callee -eq 'Resolve-Unit' -and $short[0].source -eq 'builder.ps1') ([string]$short.Count)
    $full = @($lf.Findings | Where-Object { $_.file -eq 'full-importer.ps1' })
    T 'MUST NOT FIRE  a complete lift out of another file reports nothing' ($full.Count -eq 0) ([string]$full.Count)
    $ownKey = @($lf.Findings | Where-Object { $_.file -eq 'own-key.ps1' })
    T 'MUST NOT FIRE  a callee the lifter defines for itself is supplied, not missing' ($ownKey.Count -eq 0) ([string]$ownKey.Count)
    # CLEAN TWIN - a positive assertion that all three lifts were CHECKED, so the two silent files above
    # are silent because they are complete, not because discovery never reached them.
    T 'CLEAN TWIN  every lift in the fixture directory was checked' ($lf.Checked.Count -eq 3) (($lf.Checked -join '; '))
  }
  finally { Remove-Item -LiteralPath $fx -Recurse -Force -ErrorAction SilentlyContinue }

  if ($bad -gt 0) { Write-Output ("lift-completeness SELF-TEST FAIL ({0})" -f $bad); exit 2 }
  Write-Output 'lift-completeness SELF-TEST PASS'
  Exit-Guard -Name 'lift-completeness' -Summary 'selftest pass' -Code 0
}

# ---- sweep -----------------------------------------------------------------------------------------
$groceryDir = Join-Path $repo 'grocery'
if (-not (Test-Path -LiteralPath $groceryDir)) { Write-Output 'lift-completeness: grocery\ not found - could not evaluate.'; exit 3 }
$res = Get-LiftFindings -Dir $groceryDir
if ($res.Files -eq 0) { Write-Output 'lift-completeness: read ZERO .ps1 files under grocery\ - discovery is broken, not clean.'; exit 3 }

Write-Output ("lift-completeness: read {0} grocery script(s); {1} lift(s) checked" -f $res.Files, $res.Checked.Count)
foreach ($c in $res.Checked) { Write-Output ("    checked  " + $c) }
if ($res.Checked.Count -eq 0) {
  Write-Output '  no lift of the known spelling was found - nothing was checked, which is not the same as every lift being complete'
}
if ($res.Findings.Count -gt 0) {
  Write-Output ("  {0} incomplete lift(s):" -f $res.Findings.Count)
  foreach ($x in $res.Findings) {
    Write-Output ("    {0,-28} lifts {1} out of {2}, which calls {3}, NOT in its list" -f $x.file, $x.fn, $x.source, $x.callee)
  }
  Write-Output '  Add the callee to that list, or the lifted function fails at RUN time with "not recognized".'
  Exit-Guard -Name 'lift-completeness' -Summary ("scanned={0} findings={1}" -f $res.Checked.Count, $res.Findings.Count) -Code 2
}
if ($res.Checked.Count -gt 0) { Write-Output '  every lifted function has every callee it needs from the file it was lifted out of' }
Exit-Guard -Name 'lift-completeness' -Summary ("scanned={0} findings=0" -f $res.Checked.Count) -Code 0
