# audit-wave-blocker-headings.ps1
# ---------------------------------------------------------------------------------------------------
# Every OPEN blocker heading in a wave audit must declare whose defect it was: `(recipe-local)`,
# `(shared-data)`, `(shared)`, `(process)` or `(orchestration)`, somewhere in its parentheses.
#
# WHY (2026-08-29). hunt-run.ps1 -Revive returns a recipe that a wave rejected for SOMEBODY ELSE'S
# defect, and the only evidence it will accept is the audit's own blocker headings. That makes the
# heading format load-bearing: an auditor who writes `### Blocker 1 - slug: what broke` has, without
# knowing it, made every recipe in that wave permanently unrevivable, because nothing in the file can
# say the defect was not theirs. -Revive refuses, correctly, and the refusal reads like a verdict on
# the recipe.
#
# That is not hypothetical. -Revive shipped reading for `### BLOCKER n (kind)`, a form no auditor has
# ever used, so it matched ZERO headings in ZERO reports and refused all eleven live rejections. The
# matcher is fixed and now reads the four forms actually in use - but nothing stopped a fifth form
# from appearing next week and welding the door shut all over again. This is that stop.
#
# It shares audit-blocker-lib.ps1 with -Revive ON PURPOSE. A gate with its own private idea of what a
# blocker heading looks like can be green while the command it protects still parses nothing, which
# is the same class of bug wearing a gate's uniform.
#
# THE BASELINE IS PER-HEADING, NOT PER-FILE. Two historical reports predate the rule and are recorded
# in db\blocker-heading-baseline.json by their exact heading text. A file-level exemption would let a
# NEW kindless heading slip into an already-baselined report unseen; keying on the text means the two
# known ones stay quiet and anything else in the same file still fires.
#
#   .\audit-wave-blocker-headings.ps1
#   .\audit-wave-blocker-headings.ps1 -Json
#   .\audit-wave-blocker-headings.ps1 -SelfTest
# Exit 0 clean, 1 findings, 2 self-test failure.
# ---------------------------------------------------------------------------------------------------
param(
  [string]$RunsDir, [string]$BaselineFile, [switch]$Json, [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$runJson = [bool]$Json; $runSelfTest = [bool]$SelfTest

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp   = Split-Path -Parent $here
$repo = Split-Path -Parent $mp
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $here 'audit-blocker-lib.ps1')
if (-not $RunsDir)      { $RunsDir      = Join-Path $mp 'runs' }
if (-not $BaselineFile) { $BaselineFile = Join-Path $mp 'db\blocker-heading-baseline.json' }

function Read-Baseline {
  param([string]$Path)
  if (-not (Test-Path $Path)) { return @{} }
  # ASSIGN THEN WRAP. `@(Get-Content -Raw | ConvertFrom-Json)` collapses the whole array to ONE
  # element, so the baseline read back as a single empty row and every historical heading reported
  # as new. Same misread audit-vocab-integrity.ps1 documents against db\ingredients.json; it is
  # silent, and here it would have looked like the gate simply refusing to honour its own baseline.
  $parsed = Get-Content $Path -Raw -Encoding utf8 | ConvertFrom-Json
  $rows = @($parsed)
  $m = @{}
  foreach ($r in $rows) {
    if (-not $r) { continue }
    $key = ([string]$r.report + '|' + ([string]$r.heading).Trim())
    $m[$key] = $true
  }
  return $m
}

# The whole judgement, as a function so the fixtures can drive it without a runs tree.
function Get-HeadingFindings {
  param([string[]]$Reports, $Baseline)
  $out = @()
  foreach ($p in $Reports) {
    $rel = [string]$p
    foreach ($h in @(Get-KindlessBlockerHeadings $p)) {
      $name = Split-Path $rel -Leaf
      $parent = Split-Path (Split-Path $rel -Parent) -Parent
      $short = (Split-Path $parent -Leaf) + '/' + $name
      $key = $short + '|' + ([string]$h).Trim()
      if ($Baseline -and $Baseline.ContainsKey($key)) { continue }
      $out += [pscustomobject]@{ report = $short; heading = ([string]$h).Trim() }
    }
  }
  return @($out)
}

# ---------------------------------------------------------------------------------------------------
if ($runSelfTest) {
  $f = 0
  function T([string]$name, [bool]$ok, [string]$got) {
    if ($ok) { Write-Output ("  ok    " + $name) }
    else { $script:f++; Write-Output ("  FAIL  " + $name + "   got: " + $got) }
  }
  $t = Join-Path ([IO.Path]::GetTempPath()) ('bh-' + [guid]::NewGuid().ToString('N'))
  try {
    [void](New-Item -ItemType Directory (Join-Path $t 'r1\waves') -Force)
    function Seed([string]$n, [string]$body) {
      [IO.File]::WriteAllText((Join-Path $t ('r1\waves\' + $n)), $body, (New-Object Text.UTF8Encoding $false))
      return (Join-Path $t ('r1\waves\' + $n))
    }
    # Every form that appears in a real report, all correctly tagged.
    $good = Seed 'wave-1.audit.md' "NO-GO`n### Blocker 1 (recipe-local): a`n### R2. b (shared-data, pipeline)`n### B3. c (shared, pipeline + shared-data)`n### 4. d (process/orchestration)`n"
    T 'CLEAN TWIN all four heading forms in use, correctly tagged, produce no finding' `
      (@(Get-HeadingFindings @($good) @{}).Count -eq 0) (@(Get-HeadingFindings @($good) @{}).Count.ToString())

    $bad = Seed 'wave-2.audit.md' "NO-GO`n### Blocker 1 - slug: macros computed on the wrong pasta`n"
    $bf = @(Get-HeadingFindings @($bad) @{})
    T 'MUST FIRE  a blocker heading that names no kind is a finding - this is what welds -Revive shut' `
      ($bf.Count -eq 1 -and $bf[0].heading -match 'wrong pasta') ($bf.Count.ToString())

    $prior = Seed 'wave-3.audit.md' "GO`n### Prior BLOCKER 3 (recipe-local) - VERIFIED FIXED`n### Prior BLOCKER 4 - no kind and still closed`n"
    # What excludes a CLOSED blocker is the LEADING anchor - `Prior` is not one of the labels - and
    # nothing else. There used to be a separate `^###\s+Prior\s` guard in the lib; neutering it left
    # this case green, which is how the redundancy surfaced. Neuter the anchor instead (allow anything
    # before the label) and heading 2 below becomes a finding, so this case now has a real subject.
    T 'CLEAN TWIN a CLOSED `Prior BLOCKER` heading is not judged - only OPEN blockers gate a revival' `
      (@(Get-HeadingFindings @($prior) @{}).Count -eq 0) (@(Get-HeadingFindings @($prior) @{}).Count.ToString())

    $batt = Seed 'wave-4.audit.md' "GO`n### Battery failure re-derived CLEAN (not blocking)`n### audit-rejected recipes marked published`n"
    T 'CLEAN TWIN a non-blocker `###` heading is not dragged in by the bare B alternative' `
      (@(Get-HeadingFindings @($batt) @{}).Count -eq 0) (@(Get-HeadingFindings @($batt) @{}).Count.ToString())

    # THE BASELINE IS PER-HEADING. This is the case that makes that design matter: one heading is
    # forgiven and a SECOND, new one in the SAME file must still fire. A file-level exemption passes
    # the first assertion and fails this one, which is exactly why it is written this way.
    $two = Seed 'wave-5.audit.md' "NO-GO`n### Blocker 1 - old and forgiven`n### Blocker 2 - new and not forgiven`n"
    $base = @{ ('r1/wave-5.audit.md|### Blocker 1 - old and forgiven') = $true }
    $tf = @(Get-HeadingFindings @($two) $base)
    T 'MUST FIRE  a baselined report still reports a NEW kindless heading - the exemption is per heading' `
      ($tf.Count -eq 1 -and $tf[0].heading -match 'new and not forgiven') `
      (($tf | ForEach-Object { $_.heading }) -join ' | ')
    T 'CLEAN TWIN   ...and the baselined one really is silenced, so this is not a distinction without a difference' `
      (@(Get-HeadingFindings @($two) @{}).Count -eq 2) (@(Get-HeadingFindings @($two) @{}).Count.ToString())

    # THE LIVE TREE. The fixtures above prove the rule; this proves the rule is TRUE of the estate
    # right now, which is the thing a baseline can silently stop being.
    $live = @(Get-ChildItem (Join-Path $mp 'runs') -Recurse -Filter '*.audit.md' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    $liveFind = @(Get-HeadingFindings $live (Read-Baseline $BaselineFile))
    T 'CLEAN TWIN every wave audit on disk is clean or baselined, so the gate ships green' `
      ($liveFind.Count -eq 0) (($liveFind | ForEach-Object { $_.report + ': ' + $_.heading }) -join ' | ')
  } finally { Remove-Item $t -Recurse -Force -ErrorAction SilentlyContinue }
  if ($f -eq 0) { Write-Output 'wave-blocker-headings SELF-TEST PASS'; exit 0 }
  Write-Output ("wave-blocker-headings SELF-TEST FAIL: {0} case(s)" -f $f); exit 2
}

# ---------------------------------------------------------------------------------------------------
$reports = @(Get-ChildItem $RunsDir -Recurse -Filter '*.audit.md' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
$findings = @(Get-HeadingFindings $reports (Read-Baseline $BaselineFile))

if ($runJson) {
  [pscustomobject]@{ reports = $reports.Count; findings = $findings } | ConvertTo-Json -Depth 5
} else {
  Write-Output ("wave blocker headings: {0} report(s) scanned, {1} finding(s)" -f $reports.Count, $findings.Count)
  foreach ($x in $findings) {
    Write-Output ("  [NO-KIND] {0}" -f $x.report)
    Write-Output ("            {0}" -f $x.heading)
  }
  if ($findings.Count) {
    Write-Output ''
    Write-Output '  A blocker heading with no (kind) makes every recipe in its wave unrevivable: hunt-run -Revive'
    Write-Output '  cannot tell whose defect it was, so it refuses, and the refusal reads like a verdict on the recipe.'
    Write-Output '  FIX: add the kind to the heading - (recipe-local), (shared-data), (shared), (process) or'
    Write-Output '  (orchestration) - or, for a report that is history, record it in db\blocker-heading-baseline.json.'
  }
}
Write-GuardComplete -Name 'wave-blocker-headings' -Summary ("reports={0} findings={1}" -f $reports.Count, $findings.Count)
exit $(if ($findings.Count) { 1 } else { 0 })
