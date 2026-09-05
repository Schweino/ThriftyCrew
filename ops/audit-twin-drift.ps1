<#
  audit-twin-drift.ps1 - THE CHECK FOR RULES THIS ESTATE WROTE DOWN TWICE.

  A rule implemented in two files is the single most productive source of quiet bugs in this tree's
  history, and every instance was found by accident or by a bespoke check somebody happened to think
  of. The scoreboard, all of it real:

    Get-LinkPerUnit          two copies; they disagreed on 13 of 3,342 links, private copy wrong on 13
    the price formatter      FIVE copies; three published surfaces drifted before anyone noticed
    notes-vs-bid             two implementations firing on DISJOINT refusal words
    stated_mass_grams        both twins dropped the whole number off "4 3/4 lb": 340 g against 2154 g
    RX_PROTEIN               drifted from its PowerShell twin; read "47.3g protein" as 3g

  The last one is the reason this file exists rather than another hand-written case. A LOCKSTEP
  assertion inside coverage_check.py DID catch that drift, correctly, and it sat red for weeks because
  nothing in the estate ran that suite. A check that works and is not run is not protection - so this
  one is a first-class auditor on the run-gates roster, not an assertion buried in one language's
  battery.

  TWO PASSES:
    DECLARED   ops\twin-rules.json names each known twin and the exact text to lift from each side.
               The sides must match after normalisation. This is the half that gates.
    UNDECLARED A sweep for regex literals of real length that appear VERBATIM in more than one file
               and are not covered by a declared twin. Same text in two files is duplication by
               definition, so precision here is high - but it is reported, not failed, because the
               right response is usually "declare it", and a new auditor that fails a clean tree on
               day one is one people learn to skip.

  EXIT: 0 = every declared twin agrees. 1 = at least one has drifted. 3 = COULD NOT EVALUATE (no
        registry, no readable sides) - the house rule: a check that examined nothing must never say ok.
#>
param([string]$Registry = '', [switch]$SelfTest, [switch]$Quiet)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path -Parent $here
. (Join-Path $repo 'lib\guard-contract.ps1')

function Get-TwinText {
  <#
    Lift one side's rule text out of its file, or $null when the anchor does not match.

    A MISSING ANCHOR IS NOT AGREEMENT. If a capture stops matching - someone renamed the constant,
    or reformatted the line - this returns $null and the caller reports it as a finding, because a
    twin the auditor can no longer read is a twin nobody is watching. The failure mode this whole
    file exists to prevent is silence, so silence is never the answer.
  #>
  param([string]$Path, [string]$Capture)
  if (-not (Test-Path $Path)) { return $null }
  $src = [IO.File]::ReadAllText($Path)
  $m = [regex]::Match($src, $Capture, 'Singleline')
  if (-not $m.Success -or $m.Groups.Count -lt 2) { return $null }
  return [string]$m.Groups[1].Value
}

function Get-NormalisedRule {
  <#
    The comparable form of a rule text.

    Only two normalisations, both of which are language spelling and not meaning:
      - a leading inline (?i) flag, which Python writes into the pattern and PowerShell often does too
      - surrounding whitespace
    NOTHING ELSE IS STRIPPED, on purpose. Normalising away escapes or character classes would let a
    real divergence compare equal, which is the one failure this must not have.
  #>
  param([string]$Text)
  $t = [string]$Text
  $t = [regex]::Replace($t, '^\(\?i\)', '')
  return $t.Trim()
}

if ($SelfTest) {
  $fail = 0
  function T($label, $cond, $detail) {
    if ($cond) { Write-Output "ok    $label" } else { Write-Output "FAIL  $label   got: $detail"; $script:fail++ }
  }
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ('twin-' + [guid]::NewGuid().ToString('N'))
  [void](New-Item -ItemType Directory $tmp)
  try {
    $a = Join-Path $tmp 'a.py'; $b = Join-Path $tmp 'b.ps1'
    [IO.File]::WriteAllText($a, "RX_X = re.compile(r'(?i)\bfoo\b')" + [Environment]::NewLine)
    [IO.File]::WriteAllText($b, "`$script:RX_X = '(?i)\bfoo\b'" + [Environment]::NewLine)
    $ca = "RX_X = re\.compile\(r'(.*?)'\)"
    $cb = "\`$script:RX_X\s*=\s*'(.*?)'"
    T 'a rule is lifted out of each side' `
      ((Get-TwinText $a $ca) -eq '(?i)\bfoo\b' -and (Get-TwinText $b $cb) -eq '(?i)\bfoo\b') `
      ((Get-TwinText $a $ca) + ' | ' + (Get-TwinText $b $cb))
    T 'CLEAN TWIN two sides that agree normalise equal' `
      ((Get-NormalisedRule (Get-TwinText $a $ca)) -eq (Get-NormalisedRule (Get-TwinText $b $cb))) 'not equal'
    # THE FOUNDING SHAPE: one side fixed, the other not. This is RX_PROTEIN exactly.
    [IO.File]::WriteAllText($b, "`$script:RX_X = '(?i)(?<![\d.])\bfoo\b'" + [Environment]::NewLine)
    T 'MUST FIRE  one side tightened and the other left behind is a drift' `
      ((Get-NormalisedRule (Get-TwinText $a $ca)) -ne (Get-NormalisedRule (Get-TwinText $b $cb))) 'read as agreeing'
    # AND THE INLINE FLAG IS NOT A DRIFT, or every cross-language pair would report forever.
    [IO.File]::WriteAllText($b, "`$script:RX_X = '\bfoo\b'" + [Environment]::NewLine)
    T 'CLEAN TWIN a leading (?i) on one side only is spelling, not divergence' `
      ((Get-NormalisedRule (Get-TwinText $a $ca)) -eq (Get-NormalisedRule (Get-TwinText $b $cb))) 'reported a false drift'
    # A CAPTURE THAT STOPPED MATCHING MUST NOT READ AS AGREEMENT - the silence failure.
    [IO.File]::WriteAllText($b, "`$script:RENAMED = '\bfoo\b'" + [Environment]::NewLine)
    T 'MUST FIRE  a side whose anchor no longer matches returns null, never a quiet match' `
      ($null -eq (Get-TwinText $b $cb)) 'returned a value for a missing anchor'
    T 'MUST FIRE  ...and null is not equal to the other side, so it lands as a finding' `
      ((Get-NormalisedRule (Get-TwinText $a $ca)) -ne (Get-NormalisedRule (Get-TwinText $b $cb))) 'null compared equal'
    # THE LIVE REGISTRY MUST BE READABLE AND NON-EMPTY. A registry that lists nothing reports a clean
    # bill of health for a set nobody is watching - the same rule the coverage ledger enforces on itself.
    $liveReg = Join-Path $here 'twin-rules.json'
    $liveOk = $false
    if (Test-Path $liveReg) {
      $rj = (Read-JsonFile $liveReg)
      $liveOk = (@($rj.twins).Count -ge 1)
    }
    T 'the live registry exists and names at least one twin' $liveOk 'registry missing or empty'
  } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
  if ($fail) { Write-Output ("twin-drift SELF-TEST FAIL: {0} case(s)" -f $fail); exit 1 }
  Write-Output 'twin-drift SELF-TEST PASS'
  exit 0
}

if (-not $Registry) { $Registry = Join-Path $here 'twin-rules.json' }
if (-not (Test-Path $Registry)) {
  Write-Output ("twin-drift: COULD NOT EVALUATE - no registry at '" + $Registry + "'. With no roster there is nothing to compare and nothing to notice missing.")
  exit 3
}
$reg = Read-JsonFile $Registry
$twins = @($reg.twins)
if ($twins.Count -eq 0) {
  Write-Output 'twin-drift: COULD NOT EVALUATE - the registry lists ZERO twins. An empty roster is a clean bill of health for a set nobody is watching.'
  exit 3
}

$findings = @()
$drifted  = 0        # TWINS that diverged - NOT $findings.Count, which counts the
                     # detail lines under each one. The first cut reported "4 drifted" for a single
                     # drifted pair, which is the LOWERED-label bug again: a summary that misstates its
                     # own number, in the line a reader is most likely to quote.
$checked = 0
$declaredTexts = @{}
foreach ($t in $twins) {
  $name = [string]$t.name
  $vals = @()
  $bad = @()
  foreach ($side in @($t.sides)) {
    $p = Join-Path $repo ([string]$side.file)
    $txt = Get-TwinText $p ([string]$side.capture)
    if ($null -eq $txt) { $bad += ([string]$side.file) ; continue }
    $vals += [pscustomobject]@{ file = [string]$side.file; raw = $txt; norm = (Get-NormalisedRule $txt) }
    $declaredTexts[(Get-NormalisedRule $txt)] = $name
  }
  if ($bad.Count) {
    $findings += ("{0}: could not read the rule from {1} - the anchor no longer matches, so this twin is UNWATCHED" -f $name, ($bad -join ', '))
    $drifted++
    continue
  }
  $checked++
  $distinct = @($vals | ForEach-Object { $_.norm } | Sort-Object -Unique)
  if ($distinct.Count -gt 1) {
    $drifted++
    $findings += ("{0}: the copies have DRIFTED" -f $name)
    foreach ($v in $vals) { $findings += ("    {0}`n      {1}" -f $v.file, $v.raw) }
    if ($t.why) { $findings += ('    why this pair must agree: ' + [string]$t.why) }
  }
  elseif (-not $Quiet) { Write-Output ("  ok    {0}  ({1} sides agree)" -f $name, $vals.Count) }
}

# ---- UNDECLARED: the same regex literal in more than one file ---------------------------------------
# Reported, never failed. The right response is to declare it, and a brand-new auditor that fails a
# clean tree on its first run is one that gets skipped rather than read.
$lits = @{}
$files = @(Get-ChildItem $repo -Recurse -File -Include *.ps1, *.py -ErrorAction SilentlyContinue |
  Where-Object { $_.FullName -notmatch '\\worktrees\\|\\archive\\|node_modules|\.venv|\\out\\|\\regression-inputs\\' })
foreach ($f in $files) {
  $src = [IO.File]::ReadAllText($f.FullName)
  foreach ($m in [regex]::Matches($src, "'([^'\r\n]{30,200})'")) {
    $lit = [string]$m.Groups[1].Value
    # only things that look like a RULE: a regex or a delimited pattern, not prose or a path
    if ($lit -notmatch '\\[dswbA-Z]|\[\^|\(\?:|\(\?<|\{\d') { continue }
    if ($lit -match '^[A-Za-z]:\\|/$') { continue }
    if (-not $lits.ContainsKey($lit)) { $lits[$lit] = New-Object System.Collections.ArrayList }
    [void]$lits[$lit].Add($f.FullName.Replace($repo, '').TrimStart('\'))
  }
}
$undeclared = @()
foreach ($k in $lits.Keys) {
  $inFiles = @($lits[$k] | Sort-Object -Unique)
  if ($inFiles.Count -lt 2) { continue }
  if ($declaredTexts.ContainsKey((Get-NormalisedRule $k))) { continue }
  $undeclared += [pscustomobject]@{ lit = $k; files = $inFiles }
}

if ($findings.Count) {
  Write-Output ''
  Write-Output 'TWIN DRIFT - a rule this estate keeps in more than one place no longer says the same thing:'
  foreach ($f in $findings) { Write-Output ('  ' + $f) }
}
if ($undeclared.Count -and -not $Quiet) {
  Write-Output ''
  Write-Output ("UNDECLARED (report only): {0} regex literal(s) appear verbatim in more than one file and are not in the registry." -f $undeclared.Count)
  foreach ($u in ($undeclared | Select-Object -First 10)) {
    Write-Output ('  ' + $u.lit.Substring(0, [Math]::Min(72, $u.lit.Length)))
    foreach ($ff in $u.files) { Write-Output ('      ' + $ff) }
  }
  if ($undeclared.Count -gt 10) { Write-Output ("  ... and {0} more" -f ($undeclared.Count - 10)) }
  Write-Output '  Declare each in ops\twin-rules.json, or make it one implementation.'
}

Write-Output ''
Write-Output ("twin-drift: {0} declared twin(s) compared, {1} drifted, {2} undeclared duplicate literal(s)" -f $checked, $drifted, $undeclared.Count)
Write-GuardComplete -Name 'audit-twin-drift' -Summary ("twins={0} drift={1} undeclared={2}" -f $checked, $drifted, $undeclared.Count)
exit $(if ($drifted) { 1 } else { 0 })
