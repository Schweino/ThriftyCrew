<#
  audit-fixture-vocabulary.ps1 - a fixture label must not claim the opposite of what it asserts.

  WHY THIS EXISTS (2026-09-07, backlog I11). "CLEAN TWIN" labelled fixture cases in two conventions
  here and THE SIGN OF THE ASSERTION WAS OPPOSITE IN EACH:

    the PowerShell audits      a clean twin asserted ZERO findings - a legal input the detector must
                               not flag
    knowledge-search\search.py a clean twin asserted a HIT - adjacent behaviour that must not have
                               regressed - and kept MUST NOT FIRE as a separate third label

  Both readings are defensible in isolation, which is why nothing was ever red. The cost is transfer:
  the standing instruction is "add a must-fire fixture plus a clean twin", and an author who learned
  the phrase in one place and applies it in the other writes a POSITIVE assertion where a negative was
  wanted. That fixture passes while proving nothing about over-firing - the exact failure the twin
  exists to prevent, and invisible because the suite is green.

  BRAD RULED 2026-09-07: the knowledge-search vocabulary is canonical. Three labels, three jobs:

    MUST FIRE      the founding bug. The detector must flag it, or the guard has stopped guarding.
    MUST NOT FIRE  a legal input. The detector must be SILENT, or it is crying wolf.
    CLEAN TWIN     an adjacent behaviour that STILL WORKS - a POSITIVE assertion, and the thing a fix
                   was most likely to have broken on its way past.

  WHAT THIS GATE POLICES, AND WHAT IT CANNOT. It flags a CLEAN TWIN label whose assertion PROVES
  ABSENCE. That is decidable and it is checked; the prose is not, and is never read. Of the 1,166
  non-comment CLEAN TWIN labels in the tree on the day this shipped, 133 were provable and every one
  of them was renamed. The remaining ~1,000 carry the sense in their wording only, and a heuristic
  over wording would relabel a few hundred of them WRONG - which is worse than the ambiguity, because
  a confident wrong label is believed. So this gate is deliberately narrow and honest about it: it
  stops the shape a new author actually writes, and it does not pretend to have swept the estate.

  AN EXIT CODE OF 0 IS NOT ABSENCE. `ExitCode -eq 0` and `rc == 0` say a run SUCCEEDED, which is a
  real clean twin. grocery\fanout-lib.ps1 carries two of them and they must stay CLEAN TWIN; they are
  the founding false positive for this detector and they are frozen below.

  EXIT CODES (lib\guard-contract.ps1 vocabulary): 0 clean, 2 hard finding, 3 could-not-evaluate.
  Read the verdict LINE, not the number (backlog E2).

  Self-test: powershell -File ops\audit-fixture-vocabulary.ps1 -SelfTest
#>
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop (2026-09-07)
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\ops' }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')

# VENDORED TREES ARE NOT OUR FIXTURES. site-packages alone is 11,167 .py files, and counting them
# made the pass line read "across 11,772 files" - a number that sounds like coverage and is almost
# entirely somebody else's library. Excluding them makes the reported figure mean what it says.
$EXCLUDE = '\\archive\\|\\worktrees\\|\\out\\|node_modules|\\\.git\\|site-packages|\\\.venv\\|\\venv\\'

function Test-TcMislabelledTwin {
  <# True when a line labels a case CLEAN TWIN and then asserts that something was NOT found.

     Pure, so the fixtures below drive it with synthetic lines rather than resting on today's tree. #>
  param([string]$Line)
  # COMMENTS FIRST, for the reason audit-write-seam records: prose that DESCRIBES the wrong shape is
  # not the wrong shape, and this file's own header is full of it.
  if ($Line -match '^\s*#') { return $false }
  $i = $Line.IndexOf('CLEAN TWIN')
  if ($i -lt 0) { return $false }
  $tail = $Line.Substring($i)
  # A SUCCEEDED RUN IS NOT AN ABSENCE. Checked before the absence idioms, because `$x.ExitCode -eq 0`
  # would otherwise match `-eq 0` and relabel a twin that is correctly named.
  if ($tail -match '(?i)(ExitCode\s*-eq\s*0|\.Rc\s*-eq\s*0|\brc\s*==\s*0|returncode)') { return $false }
  return [bool]($tail -match '(?i)(Count\)?\s+-eq\s+0|\(\s*-not\s+\(|\$null\s+-eq\s+\(|len\([^)]*\)\s*==\s*0)')
}

function Get-TcMislabelledTwins {
  <# One record per mislabelled case. `,@()` so a single finding does not unroll to a bare string,
     and CALLERS MUST ASSIGN BEFORE WRAPPING - @(callsite) reads an EMPTY result as one element.
     [[ps-json-array-collapse]] #>
  param([object[]]$Files, [scriptblock]$ReadLines)
  $hits = @()
  foreach ($f in @($Files)) {
    $n = 0
    foreach ($line in @(& $ReadLines $f)) {
      $n++
      if (Test-TcMislabelledTwin $line) { $hits += [pscustomobject]@{ File = $f; Line = $n } }
    }
  }
  return ,@($hits)
}

# ------------------------------------------------------------------------------------- self-test
if ($SelfTest) {
  $f = 0
  function T($m, $cond, $got) { if ($cond) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $got); $script:f++ } }

  # MUST FIRE - the absence idioms this estate actually writes, taken from the 133 renamed.
  # EVERY FIXTURE IS A SINGLE-QUOTED LITERAL. Built by concatenation they were not one argument but
  # three: PowerShell binds the first positional and drops the rest in $args, so three cases were fed
  # a truncated line and two others PASSED on a fragment that could never have matched. A fixture
  # that passes for the wrong reason is exactly what this file exists to catch.
  T 'MUST FIRE  a twin asserting a finding count of zero' `
    (Test-TcMislabelledTwin 'T ''CLEAN TWIN text with none yields none'' (@($c4).Count -eq 0) (($c4) -join '','')') 'missed the commonest shape'
  T 'MUST FIRE  a twin asserting a negated detector call' `
    (Test-TcMislabelledTwin 'T ''CLEAN TWIN a builder is not a detector'' (-not (Test-IsDetector ''build-deals-page.ps1'')) ''classed as detector''') 'missed'
  T 'MUST FIRE  a twin asserting a null result' `
    (Test-TcMislabelledTwin 'T ''CLEAN TWIN a non-Recipe page yields no node'' ($null -eq (Find-RecipeNode $j)) ''false positive''') 'missed'
  T 'MUST FIRE  the Python spelling counts too' `
    (Test-TcMislabelledTwin 'T("CLEAN TWIN an allow-listed row is silent", len(rows) == 0, rows)') 'a PowerShell-only gate leaves the sidecar unpoliced'
  T 'MUST FIRE  a double-quoted label, not just a single-quoted one' `
    (Test-TcMislabelledTwin 'Check "CLEAN TWIN a fraction ''1/2 cup''" (-not (BuyHasUnitFlags ''1/2 cup''))') 'missed'

  # MUST NOT FIRE - the legal inputs. The first is the founding false positive.
  T 'MUST NOT FIRE  THE ONE THAT KEEPS THIS GATE HONEST - an EXIT CODE of 0 is a run that SUCCEEDED, which is a real clean twin' `
    (-not (Test-TcMislabelledTwin 'T ''CLEAN TWIN a child that writes to stderr still reports rc 0'' (-not ($er.Blind) -and $er.ExitCode -eq 0)')) 'relabelled a correctly-named twin'
  T 'MUST NOT FIRE  a twin asserting a real value is exactly what CLEAN TWIN now means' `
    (-not (Test-TcMislabelledTwin 'T ''CLEAN TWIN the real product matches'' ($r.hits -eq 1) "hits=$($r.hits)"')) 'a correct twin was flagged'
  T 'MUST NOT FIRE  prose describing the wrong shape is not the wrong shape' `
    (-not (Test-TcMislabelledTwin '  # CLEAN TWIN cases that assert (@($r).Count -eq 0) are the ones this gate renames')) 'a comment was counted'
  T 'MUST NOT FIRE  a MUST NOT FIRE case asserting zero is correctly labelled and must stay silent' `
    (-not (Test-TcMislabelledTwin 'T ''MUST NOT FIRE text with none yields none'' (@($c4).Count -eq 0) ''''')) 'flagged the correct label'
  T 'MUST NOT FIRE  an ordinary line naming neither label' `
    (-not (Test-TcMislabelledTwin '$rows = Get-Findings $spec')) 'flagged an ordinary line'

  # CLEAN TWIN - the scanner around the predicate still walks files and reports file+line.
  $fake = { param($p) if ($p -eq 'a.ps1') { @('$x = 1', "T 'CLEAN TWIN nothing here' (@(`$r).Count -eq 0) ''") } else { @("T 'CLEAN TWIN the real product matches' (`$r.hits -eq 1) ''") } }
  $r = Get-TcMislabelledTwins -Files @('a.ps1', 'b.ps1') -ReadLines $fake
  T 'CLEAN TWIN the scanner finds the one mislabel and reports its line' (($r.Count -eq 1) -and ($r[0].File -eq 'a.ps1') -and ($r[0].Line -eq 2)) ("Count=" + $r.Count)
  T 'CLEAN TWIN a single finding comes back as an ARRAY, not unrolled to a string' ($r -is [array]) ($r.GetType().FullName)
  $r0 = Get-TcMislabelledTwins -Files @('b.ps1') -ReadLines $fake
  T 'MUST NOT FIRE a file whose twins are all correctly labelled yields nothing' ((@($r0)).Count -eq 0) ("Count=" + @($r0).Count)

  if ($f) { Write-Output ("SELF-TEST FAIL: {0} check(s)" -f $f); exit 1 }
  Write-Output 'SELF-TEST PASS: 5 must-fire absence idioms across both languages, 5 must-not-fire cases including the exit-code twin that founded them, plus the scanner and its return arity'
  exit 0
}

# ------------------------------------------------------------------------------------- live run
# NEVER SCAN YOURSELF. The fixtures above are verbatim mislabels passed as ARGUMENTS, not comments, so
# the comment filter does not reach them and this detector would report five findings inside its own
# must-fire cases. run-gates and audit-write-seam both carry the same exclusion for the same reason.
$files = @(Get-ChildItem $repo -Recurse -File -ErrorAction SilentlyContinue -Include *.ps1, *.py |
  Where-Object { $_.FullName -notmatch $EXCLUDE -and $_.FullName -ne $PSCommandPath } | ForEach-Object { $_.FullName })
if (-not $files.Count) {
  Write-Output 'FIXTURE-VOCABULARY AUDIT BLIND: found zero .ps1/.py files to scan, which means the discovery is broken rather than the tree being clean.'
  Exit-Guard -Name 'fixture-vocabulary' -Summary 'blind=no-files' -Code 3
}
$hits = Get-TcMislabelledTwins -Files $files -ReadLines { param($p) [IO.File]::ReadAllLines($p) }
$hits = @($hits)

foreach ($h in ($hits | Sort-Object File, Line)) {
  Write-Output ("  mislabelled  {0}:{1}" -f $h.File.Replace($repo, '').TrimStart('\'), $h.Line)
}
if ($hits.Count) {
  Write-Output ("FIXTURE-VOCABULARY AUDIT FAILED: {0} case(s) labelled CLEAN TWIN assert that a detector found NOTHING. That is a MUST NOT FIRE case. CLEAN TWIN is reserved for an adjacent behaviour that STILL WORKS - a positive assertion - so that 'add a must-fire and a clean twin' cannot be read two opposite ways. Rename the label; the assertion is already right." -f $hits.Count)
  Exit-Guard -Name 'fixture-vocabulary' -Summary ("mislabelled={0}" -f $hits.Count) -Code 2
}
Write-Output ("fixture-vocabulary: PASSED - every CLEAN TWIN label whose assertion is legible asserts a VALUE, not an absence, across {0} file(s). The labels whose sense lives only in their wording are out of this gate's reach and are not claimed." -f $files.Count)
Exit-Guard -Name 'fixture-vocabulary' -Summary ("files={0} mislabelled=0" -f $files.Count) -Code 0
