<#
  audit-guard-contract.ps1 - which DETECTORS in the daily chain cannot prove they ran to the end?

  WHY (2026-08-08). See lib\guard-contract.ps1 for the founding incident: test-auditors died 242 checks
  early, printed 176 lines of PASS, exited 1, and nothing could tell that from an ordinary findings-exit.

  SCOPE IS DELIBERATE. The chain invokes 61 child scripts and most of them are pullers, builders or
  publishers - if one of those dies the damage is LOUD, because the data it was supposed to produce is
  missing downstream. This audit covers DETECTORS only: the scripts whose whole job is to report findings,
  where "found nothing" and "never ran" are indistinguishable from outside. Widening it to all 61 would
  bury the signal under scripts that do not need the contract.

  RATCHETED, not all-or-nothing. Retrofitting ~24 detectors in one pass would be a large blind edit across
  working, golden-tested files. Instead the covered set is recorded in out\guard-contract-baseline.json and
  this fails when a detector that HAD the marker loses it, or when a NEW detector joins the chain without
  one. The remaining backlog is printed every run, so it is visible and shrinking rather than silently
  incomplete - the estate's own contested-flag rule: never bless a pending set, never cry daily either.

  Usage: .\audit-guard-contract.ps1 [-ShowAll] [-Baseline] | -SelfTest
#>
param([switch]$ShowAll, [switch]$Baseline, [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\income\grocery' }
$repo = Split-Path $root -Parent

# A detector is a script whose product is a VERDICT. Named by prefix, plus the handful that do not follow it.
$script:DETECTOR_RX  = '^(audit|test|verify|golden-test|guards|sanity-check|batch-ledger|aisle-test)'
$script:NOT_DETECTOR = @('audit-guard-contract.ps1')   # this file: it reports ON the contract, not via it

function Test-IsDetector { param([string]$Name)
  if ($script:NOT_DETECTOR -contains $Name) { return $false }
  return ([regex]::IsMatch($Name, $script:DETECTOR_RX))
}
function Test-EmitsMarker { param([string]$Text)
  # it must CALL the shared helper, or write a literal <NAME>-COMPLETE line itself
  return ([regex]::IsMatch($Text, 'Write-GuardComplete') -or [regex]::IsMatch($Text, "['`"][A-Z0-9-]+-COMPLETE"))
}

if ($SelfTest) {
  $f = 0
  function T($m, $c, $g) { if ($c) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $g); $script:f++ } }
  T 'CLEAN TWIN a puller is not a detector (its failure is loud downstream)' (-not (Test-IsDetector 'pull-regular-hyvee.ps1')) 'classed as detector'
  T 'CLEAN TWIN a builder is not a detector'                                 (-not (Test-IsDetector 'build-deals-page.ps1')) 'classed as detector'
  T 'an audit-* script IS a detector'                                        (Test-IsDetector 'audit-row-age.ps1') 'missed'
  T 'test-auditors IS a detector (the founding case)'                        (Test-IsDetector 'test-auditors.ps1') 'missed'
  T 'guards.ps1 and golden-test are detectors'                               ((Test-IsDetector 'guards.ps1') -and (Test-IsDetector 'golden-test.ps1')) 'missed'
  T 'this auditor excludes itself'                                           (-not (Test-IsDetector 'audit-guard-contract.ps1')) 'self-included'
  T 'a script calling the helper counts as covered'                          (Test-EmitsMarker 'Write-GuardComplete -Name x') 'missed'
  T 'a literal marker also counts (reanchor-all predates the helper)'        (Test-EmitsMarker '"REANCHOR-COMPLETE stale={0}"') 'missed'
  T 'MUST FIRE  a detector with neither is uncovered'                        (-not (Test-EmitsMarker 'Write-Output "all clear"')) 'false cover'
  if ($f -eq 0) { Write-Output 'SELF-TEST PASS'; exit 0 } else { Write-Output "SELF-TEST FAIL: $f case(s)"; exit 1 }
}

# ---- which detectors does the chain actually invoke? -----------------------------------------------------
$chainText = [IO.File]::ReadAllText((Join-Path $root 'check-ad-cycles.ps1'))
$invoked = @()
foreach ($m in [regex]::Matches($chainText, '([a-z0-9][a-z0-9-]*\.ps1)')) { $invoked += $m.Groups[1].Value }
$invoked = @($invoked | Sort-Object -Unique | Where-Object { Test-IsDetector $_ })

$covered = @(); $uncovered = @(); $missing = @()
foreach ($n in $invoked) {
  $p = @(Get-ChildItem $repo -Recurse -Filter $n -File -ErrorAction SilentlyContinue |
         Where-Object { $_.FullName -notmatch '\\worktrees\\|\\archive\\' } | Select-Object -First 1)
  if (-not $p.Count) { $missing += $n; continue }
  if (Test-EmitsMarker ([IO.File]::ReadAllText($p[0].FullName))) { $covered += $n } else { $uncovered += $n }
}

$basePath = Join-Path $root 'out\guard-contract-baseline.json'
$base = @(); $knownBacklog = @(); $haveBaseline = $false
if (Test-Path $basePath) {
  $b = Get-Content $basePath -Raw -Encoding UTF8 | ConvertFrom-Json
  $base = @($b.covered); $knownBacklog = @($b.backlog); $haveBaseline = $true
}

# THE BASELINE RECORDS BOTH SETS, and the first version recorded only the covered one - so every detector in
# the known backlog looked like a brand-new arrival and all 26 fired as "NEW" on the very first armed run.
# A ratchet that flags the backlog it was created to tolerate is just a louder version of no ratchet.
if ($Baseline) {
  (@{ covered = @($covered | Sort-Object); backlog = @($uncovered | Sort-Object); recorded = (Get-Date).ToString('yyyy-MM-dd') } |
    ConvertTo-Json -Depth 4) | Out-File $basePath -Encoding utf8
  Write-Output ("guard-contract baseline recorded: {0} covered, {1} known backlog" -f $covered.Count, $uncovered.Count)
  exit 0
}

# hard on exactly two things: a detector that HAD the marker and lost it, and a detector in NEITHER recorded
# set (genuinely new to the chain, arriving without one). The known backlog stays visible but quiet.
$regressed = @($base | Where-Object { $uncovered -contains $_ })
$newBare   = @()
if ($haveBaseline) { $newBare = @($uncovered | Where-Object { $base -notcontains $_ -and $knownBacklog -notcontains $_ }) }

Write-Output ("guard-contract: {0} of {1} chain detector(s) can prove they ran to the end" -f $covered.Count, $invoked.Count)
if ($missing.Count) { Write-Output ("  (could not locate on disk: {0})" -f ($missing -join ', ')) }
$cap = if ($ShowAll) { 100 } else { 8 }
if ($uncovered.Count) {
  Write-Output ("  backlog - no completion marker yet ({0}):" -f $uncovered.Count)
  $uncovered | Select-Object -First $cap | ForEach-Object { Write-Output ("      " + $_) }
  if (-not $ShowAll -and $uncovered.Count -gt $cap) { Write-Output ("      ... {0} more (-ShowAll)" -f ($uncovered.Count - $cap)) }
}
foreach ($r in $regressed) { Write-Output ("  ! REGRESSED: {0} had a completion marker and lost it" -f $r) }
foreach ($n in $newBare)   { Write-Output ("  ! NEW: {0} joined the chain with no completion marker" -f $n) }
if (-not (Test-Path $basePath)) { Write-Output '  (no baseline yet - run -Baseline once to arm the ratchet)' }

. (Join-Path $repo 'lib\guard-contract.ps1')
Write-GuardComplete -Name 'guard-contract' -Summary ("covered={0} backlog={1} regressed={2}" -f $covered.Count, $uncovered.Count, ($regressed.Count + $newBare.Count))
exit $(if ($regressed.Count -or $newBare.Count) { 1 } else { 0 })
