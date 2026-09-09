# audit-measurement-provenance.ps1
# ---------------------------------------------------------------------------------------------------
# Does a recorded measurement say what it was measured THROUGH? (2026-09-09, backlog I47 rung 2.)
#
# WHY. A difference can be real, reproducible and significant and still be caused by something that
# differed between the arms and was not the intervention. That is a DESIGN defect, so more data makes
# it worse rather than better, and this estate has paid for it twice: grocery\check-ad-cycles.ps1
# carries a block headed "THE MEASUREMENT WAS CONFOUNDED" where a 30.9-vs-41.7-minute verdict REVERTED
# a working parallel path, and design\EVAL-hunter-wall-clock-2026-09-04.md 46 says it plainly -
# "arithmetically true and causally wrong". **Both were caught by a human re-reading the commit clock
# months later, by luck.**
#
# RUNG 1 MEASURED IT: 8 of the 9 recorded-measurement documents name a harness that has CHANGED since
# the document was written, and the ninth only reads current because it was edited the day before for
# an unrelated item. A moved harness does not make a verdict wrong - **it makes it UNQUALIFIED until
# somebody re-reads it**, and today answering that costs archaeology.
#
# RUNG 2 IS A CONVENTION, AND A CONVENTION WITH NO DETECTOR IS AN INTENTION WITH NO EXIT CODE. The rule
# is in .claude\rules\measurement.md: a recorded measurement states the script it ran through and the
# commit hash it ran at. This is what notices when a new one does not.
#
# A RATCHET, NEVER A GATE, and the item said so explicitly: retro-filling the existing nine was NOT
# asked for, and a bar over them would be red on day one against almost every one. The high-water mark
# may only go DOWN. A NEW measurement document without provenance raises it and fails; filling one in
# lowers it and the ground is held.
#
# SCOPE OF A CLEAN REPORT: UNSOUND. It looks for a harness/commit statement by its spelling, so a
# document that records its provenance in some other wording counts as missing, and one that names a
# harness it did not actually use counts as present. It cannot check that the provenance is TRUE - only
# that the question was answered somewhere in the file.
#
#   .\audit-measurement-provenance.ps1
#   .\audit-measurement-provenance.ps1 -UpdateBaseline
#   .\audit-measurement-provenance.ps1 -SelfTest
# Exit 0 at or under the mark, 2 the ratchet rose, 3 could not evaluate.
# ---------------------------------------------------------------------------------------------------
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop
param(
  [switch]$UpdateBaseline,
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$runSelfTest = [bool]$SelfTest

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path -Parent $here
. (Join-Path $repo 'lib\guard-contract.ps1')

$BASELINE = Join-Path $here 'measurement-provenance-baseline.json'

function Test-TcNamesHarness {
  <# Does this document say what it was measured THROUGH? Pure.

     Two halves, and BOTH are required, because either alone is the failure the rule is about:
       * a HARNESS - the script the measurement ran through
       * a COMMIT - the point in that script's history it ran at
     Naming the script without the commit is the exact state all nine documents were already in: you
     know which file to look at and still cannot tell whether it has moved. #>
  param([string]$Text)
  if (-not $Text) { return $false }
  $hasHarness = ($Text -match '(?im)^\s*\*{0,2}(harness|measured through|harness and commit)\b')
  # A COMMIT HASH **OR** AN ISO DATE, and the alternative is not laxity - it is the only writable form
  # for the introducing commit. A document cannot contain the hash of the commit that adds it; the
  # first one written to this convention said "the commit that introduced this file" and was correctly
  # flagged by this audit's own first run. A date is enough to answer the question the rule exists for,
  # because `git log --before=<date> -- <harness>` tells you whether the harness has moved since. The
  # hash is better and should be backfilled once it exists.
  $hasCommit  = ($Text -match '(?i)\bcommit\b[^\n]{0,80}\b[0-9a-f]{7,40}\b') -or
                ($Text -match '(?i)\bcommit\s+(hash|it ran at)\b') -or
                ($Text -match '\b20[0-9]{2}-[0-1][0-9]-[0-3][0-9]\b')
  return ($hasHarness -and $hasCommit)
}

function Get-TcMeasurementDocs {
  <# The population: recorded-measurement documents under design\. Named by their own convention. #>
  param([string]$DesignDir)
  if (-not (Test-Path $DesignDir)) { return @() }
  $files = @(Get-ChildItem $DesignDir -File -Filter '*.md' -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -like 'EVAL-*' -or $_.Name -like 'MEASURE-*' })
  return $files
}

# ---- self-test -------------------------------------------------------------------------------------
if ($runSelfTest) {
  $bad = 0
  function T([string]$n, [bool]$ok, [string]$got) {
    if ($ok) { Write-Output ("  ok    " + $n) } else { Write-Output ("  X     " + $n + "   got: " + $got); $script:bad++ }
  }

  # MUST FIRE - the state all nine documents were in. A verdict with no provenance at all.
  $none = "# EVAL something`n`nWe measured 30.9 minutes against 41.7 and reverted the parallel path.`n"
  T 'MUST FIRE  a measurement with no provenance at all is a finding' (-not (Test-TcNamesHarness $none)) 'counted as present'

  # MUST FIRE - THE HALF THAT LOOKS DONE AND IS NOT. Naming the script without the commit leaves you
  # knowing which file to look at and still unable to tell whether it moved. That is where all nine
  # already were, so accepting it would make this audit green while changing nothing.
  $harnessOnly = "# EVAL x`n`n**Harness.** measured through hunt-run.ps1.`n"
  T 'MUST FIRE  naming the harness WITHOUT the commit is still a finding' (-not (Test-TcNamesHarness $harnessOnly)) 'counted as present'

  $commitOnly = "# EVAL x`n`nRan at commit 3e1b8eb41.`n"
  T 'MUST FIRE  a commit with no harness named is still a finding' (-not (Test-TcNamesHarness $commitOnly)) 'counted as present'

  # MUST FIRE - a DATE alone is not provenance either. Every one of the nine existing documents carries
  # a date; if a date sufficed, this audit would have gone green on day one having changed nothing.
  $dateOnly = "# EVAL x`n`nMeasured 2026-09-04 over 31 pairs.`n"
  T 'MUST FIRE  a date with no harness named is still a finding' (-not (Test-TcNamesHarness $dateOnly)) 'counted as present'

  # MUST NOT FIRE - harness plus a DATE is the only form writable in the commit that introduces the
  # document, because a file cannot contain the hash of the commit that adds it. Frozen from the real
  # case: the first document written to this convention was flagged by this audit's own first run.
  $harnessDate = "# EVAL x`n`n**Harness and commit.** ops\member-cohorts.ps1, run 2026-09-09.`n"
  T 'MUST NOT FIRE  harness plus an ISO date is compliant - a hash cannot name its own commit' `
    (Test-TcNamesHarness $harnessDate) 'counted as missing'

  # MUST NOT FIRE - the compliant shape, frozen from the one document written to the convention.
  $good = "# EVAL x`n`n**Harness and commit.** The producer is ops\member-cohorts.ps1 -AppendHistory, run from`ngrocery\capture-watchdog.ps1. The commit that introduced both is af55112b3.`n"
  T 'MUST NOT FIRE  a document naming both harness and commit is compliant' (Test-TcNamesHarness $good) 'counted as missing'

  # MUST NOT FIRE - the wording is allowed to vary a little, or the convention becomes a magic string.
  $alt = "# EVAL x`n`n**Measured through** sidecar\matcher_eval.py at commit hash 64e570c4a.`n"
  T 'MUST NOT FIRE  an alternative wording still counts' (Test-TcNamesHarness $alt) 'counted as missing'

  # MUST NOT FIRE - an empty document does not throw and is simply missing.
  T 'MUST NOT FIRE  an empty document is missing, not an error' (-not (Test-TcNamesHarness '')) 'threw or passed'

  # CLEAN TWIN - the population picker still selects the right files, which is the half a text test
  # cannot cover. A positive assertion against the real design directory.
  $docs = @(Get-TcMeasurementDocs (Join-Path $repo 'design'))
  T 'CLEAN TWIN  the population is the EVAL-* and MEASURE-* documents, and it is not empty' `
    ($docs.Count -gt 0 -and (@($docs | Where-Object { $_.Name -notlike 'EVAL-*' -and $_.Name -notlike 'MEASURE-*' }).Count -eq 0)) `
    ("count=" + $docs.Count)

  if ($bad -gt 0) { Write-Output ("measurement-provenance SELF-TEST FAIL ({0})" -f $bad); exit 2 }
  Write-Output 'measurement-provenance SELF-TEST PASS: 9 case(s) resolved - led by the two half-done shapes that look finished (a harness with no commit, a date with no harness) and by the case that a hash cannot name its own commit'
  Exit-Guard -Name 'measurement-provenance' -Summary 'selftest pass' -Code 0
}

# ---- sweep -----------------------------------------------------------------------------------------
$docs = @(Get-TcMeasurementDocs (Join-Path $repo 'design'))
if (-not $docs.Count) {
  Write-Output 'measurement-provenance: no EVAL-* or MEASURE-* documents found - discovery is broken, not clean.'
  exit 3
}

$missing = @()
foreach ($d in $docs) {
  $t = [IO.File]::ReadAllText($d.FullName)
  if (-not (Test-TcNamesHarness $t)) { $missing += $d.Name }
}

Write-Output ("measurement-provenance: {0} recorded-measurement document(s); {1} name a harness AND the commit it ran at, {2} do not" -f `
  $docs.Count, ($docs.Count - $missing.Count), $missing.Count)
foreach ($m in $missing) { Write-Output ("    {0}" -f $m) }
Write-Output '  A moved harness does not make a verdict wrong - it makes it UNQUALIFIED until somebody'
Write-Output '  re-reads it, and without the commit that costs archaeology. Rule: .claude\rules\measurement.md'
Write-Output '  SCOPE: UNSOUND. It checks that the question was ANSWERED, never that the answer is true.'

if ($UpdateBaseline) {
  $prev = if (Test-Path $BASELINE) { [int]((Get-Content $BASELINE -Raw | ConvertFrom-Json).missing) } else { [int]::MaxValue }
  if ($missing.Count -gt $prev) {
    Write-Output ("measurement-provenance: REFUSING to raise the high-water mark from {0} to {1}. A ratchet may only go DOWN." -f $prev, $missing.Count)
    exit 2
  }
  $obj = [pscustomobject]@{ missing = $missing.Count; recorded = (Get-Date -Format 'yyyy-MM-dd')
    note = 'HIGH-WATER MARK: recorded-measurement documents that do NOT name their harness and commit. May only go DOWN. Backlog I47 rung 2. Retro-filling the existing set was explicitly NOT asked for; the ask is that the next one carries it.' }
  [IO.File]::WriteAllText($BASELINE, ($obj | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
  Write-Output ("measurement-provenance: baseline set to {0}" -f $missing.Count)
  Exit-Guard -Name 'measurement-provenance' -Summary ("baseline={0}" -f $missing.Count) -Code 0
}

if (-not (Test-Path $BASELINE)) {
  Write-Output 'measurement-provenance: no baseline recorded. Run -UpdateBaseline once to arm the ratchet.'
  exit 3
}
$base = [int]((Get-Content $BASELINE -Raw | ConvertFrom-Json).missing)
if ($missing.Count -gt $base) {
  Write-Output ("measurement-provenance: RATCHET ROSE. baseline {0}, now {1}. A NEW recorded measurement does not say what it was measured through." -f $base, $missing.Count)
  Exit-Guard -Name 'measurement-provenance' -Summary ("ROSE base={0} now={1}" -f $base, $missing.Count) -Code 2
}
if ($missing.Count -lt $base) {
  Write-Output ("measurement-provenance: below the high-water mark ({0} < {1}). Lower it with -UpdateBaseline." -f $missing.Count, $base)
}
Exit-Guard -Name 'measurement-provenance' -Summary ("docs={0} missing={1} base={2}" -f $docs.Count, $missing.Count, $base) -Code 0
