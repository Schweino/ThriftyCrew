# selftest-verdict.ps1 - did a self-test's OWN verdict run? Read off the child's stdout, never inferred from exit 0.
#
# WHY THIS EXISTS (2026-09-11). ops\run-gates.ps1 judged every discovered self-test by its exit code alone. Commit
# 8253ded82 glued grocery\pull-grocery-ads.ps1's closing `if ($fail -eq 0) { ...; exit 0 } else { ...; exit 1 }` onto
# its last `_T` case line, so the if became ARGUMENTS to _T, the -SelfTest branch held no exit, and control fell
# through to the LIVE Hy-Vee, Aldi and Family Fare pull. That wrote out\ads-<today>.json and exited 0, and run-gates
# scored it ok on every push from every session for hours. ops\audit-keyword-arguments.ps1 blocks that one spelling.
# Any other fall-through out of a self-test branch - a missing exit, an exit inside a function that only returns, a
# refactor that moves the verdict - still read as a pass whenever the code after it exits 0. An exit code says the
# PROCESS ended cleanly; it cannot say the SUITE reached its verdict.
#
# THE RULE (Get-TcSelfTestVerdict), over the child's non-blank stdout lines, trimmed:
#   1. Walk back over trailing guard-contract markers, <NAME>-COMPLETE <summary>. A marker whose NAME carries SELFTEST
#      or SELF-TEST, or whose summary carries selftest=, IS the verdict (START-SIDECAR-SELFTEST-COMPLETE,
#      SEO-REACH-DIAGNOSIS-COMPLETE selftest=pass). Any other marker is skipped and vouches for nothing, because a
#      production path prints a marker of its own.
#   2. The last line left must NAME a self-test (self-test, selftest, self test, -SelfTest, self-tests) AND carry a
#      result word (pass, passed, passes, ok, green, fail, failed, fails), and must not be a CASE line: the estate's
#      `ok    label` / `PASS  label` / `FAIL  label` shape, or a label ending in two spaces and ok or FAIL.
#   A line that merely comes last is not a verdict. That is the founding case: the pull's last line was `Saved: ...`.
#
# MEASURED 2026-09-11 at 2c0d9c45c, before this rule was wired: one run of run-gates' own discovery (its -ListOnly
# for PowerShell, its Python walk replicated) through a scratch harness on the machine-wide gate-slot budget, every
# child's stdout kept per suite. grocery\pull-grocery-ads.ps1 was left out because at that commit its self-test runs
# the live pull. Of 316 suites that ran (263 PowerShell, 53 Python) this rule scored 308 ok (270 by their last line,
# 38 by a marker naming the self-test), 2 fail (both for gitignored data a fresh worktree lacked), and 6 no-verdict:
# audit-count-gpu (SELF-TEST: all predicates hold), repair-head-ingredients (failures: 0), test-prepush-hook
# (test-prepush-hook: 31 of 31 cases pass), food_provenance and food_source_backfill (all assertions passed), and
# injection_eval (a bare VERDICT: PASS). All six were given a verdict in the change that wired this in, so the gate
# was not red on day one and needs no allowlist. About 30 spellings were in use; the two commonest were
# SELF-TEST PASS (118) and <NAME> SELF-TEST PASS (106).
#
# MUTATION-PROBED 2026-09-11, nine single compiling mutants from a temp mirror, the original verified byte-identical
# by md5 afterwards: the case-line exclusion never matching, every trailing marker vouching, no-verdict scoring ok,
# the result word not required, the marker NAME ignored, markers never skipped, the fail-sense branch disabled, and
# each of its two halves (the anchored FAIL line, the SELF-TEST FAIL spelling) neutered alone. Killed 9 of 9, each by
# the case named for it. The result-word case was written before the run because that mutant was predicted to
# survive without it; the version lacking it was not run.
#
# SCORING (Get-TcSelfTestScore): a non-zero exit is 'fail', exactly as before. An exit 0 whose stdout carries a
# case-sensitive SELF-TEST FAIL (or SELFTEST FAIL), or a line starting with FAIL, is 'fail' too - the suite evaluated
# and said so, so run-gates scores it 1, not 3. An exit 0 with a verdict and no such line is 'ok'. An exit 0 with
# neither is 'no-verdict', which run-gates scores as could-not-evaluate (3), never ok.
#
# SCOPE OF A CLEAN REPORT: UNSOUND, in the direction that matters. A reported no-verdict or failing line is real. A
#   verdict found proves less than it looks:
#     * a self-test that falls through into a production path that PRINTS NOTHING and exits 0, having PASSED, leaves
#       its own verdict last and passes this check (having failed, its FAIL line now scores it fail);
#     * the sense is read from two spellings only. A failure written any other way - `27/28 pass`, `1 regressed`,
#       lower-case `fail` - under an exit 0 still scores ok. The other direction is a false red: a suite that prints a
#       captured child's FAIL line as a line of its own at exit 0 goes red. Measured 0 of 314 on 2026-09-11;
#     * only stdout is read, because lib\parallel-run.ps1 does not capture stderr, so a verdict written only to
#       stderr scores no-verdict (a loud miss, not a silent pass);
#     * the vocabulary is the one measured below. A suite that invents a new spelling scores no-verdict until it uses
#       one of these words, which is the intended pressure.
#
# NO param() BLOCK, DELIBERATELY: dot-sourced under PS 5.1 a param() block runs in the CALLER's scope and would reset
# the caller's own -SelfTest. Same rule as lib\guard-contract.ps1 and lib\selftest-discovery.ps1.
#
# Dot-source:  . (Join-Path $repoRoot 'lib\selftest-verdict.ps1')
# Self-test:   powershell -File lib\selftest-verdict.ps1 -SelfTest

$__svSelfTest = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-SelfTest')

$script:TcVerdictMarker = '^([A-Z0-9][A-Z0-9-]*)-COMPLETE(?:\s+(.*))?$'
$script:TcVerdictNames  = '(?i)self[- ]?tests?'
$script:TcVerdictWords  = '(?i)\b(pass|passed|passes|ok|green|fail|failed|fails)\b'
$script:TcVerdictCase   = '^(ok|PASS|FAIL|X)\s{2,}|\s{2,}(ok|FAIL)$'

function Get-TcSelfTestVerdict {
  # Returns { Found = bool; By = 'marker' | 'line' | ''; Line = the verdict line or the line that was not one; Reason }.
  param([object[]]$Lines)
  $nb = [Collections.Generic.List[string]]::new()
  foreach ($l in @($Lines)) {
    if ($null -eq $l) { continue }   # @($null) has one element, and it is not a line
    $s = ([string]$l).Trim()
    if ($s.Length) { $nb.Add($s) }
  }
  $i = $nb.Count - 1
  while ($i -ge 0 -and $nb[$i] -cmatch $script:TcVerdictMarker) {
    $name = [string]$Matches[1]; $summary = [string]$Matches[2]
    if ($name -cmatch 'SELF-?TEST' -or $summary -match '(?i)\bself-?test=') {
      return [pscustomobject]@{ Found = $true; By = 'marker'; Line = $nb[$i]; Reason = '' }
    }
    $i--
  }
  if ($i -lt 0) {
    $why = if ($nb.Count) { 'it printed only completion markers, and none of them names a self-test' } else { 'it printed nothing on stdout' }
    return [pscustomobject]@{ Found = $false; By = ''; Line = ''; Reason = $why }
  }
  $last = $nb[$i]
  if ($last -cmatch $script:TcVerdictCase) {
    return [pscustomobject]@{ Found = $false; By = ''; Line = $last; Reason = 'its last line is a CASE line, not the suite''s verdict' }
  }
  if ($last -match $script:TcVerdictNames -and $last -match $script:TcVerdictWords) {
    return [pscustomobject]@{ Found = $true; By = 'line'; Line = $last; Reason = '' }
  }
  return [pscustomobject]@{ Found = $false; By = ''; Line = $last; Reason = 'its last line does not name a self-test with a result word' }
}

# WHAT A SUITE SAYS OUTWEIGHS ITS EXIT 0 (2026-09-11, the complement, ruled into this lib by Brad so one owner holds
# the scoring). A lost exit line after `SELF-TEST FAIL: 2 of 25`, or a fall-through into a path that prints nothing,
# leaves a FAIL verdict as the last word and an exit 0 behind it, and a verdict FOUND is not a verdict PASSED. Case
# sensitive and anchored, so `  ok    MUST FIRE  a FAIL line is reported` and `SELF-TEST PASS: covers FAIL lines`
# stay ok. Measured by the session that raised it over this lib's own 2c0d9c45c corpus and recomputed here: 0 of 314
# exit-0 suites print either line, and both non-zero suites print the anchored one (only 1 of 2 the SELF-TEST FAIL
# spelling, which is why both halves are kept).
$script:TcFailSelfTest = 'SELF-?TEST FAIL'
$script:TcFailCase     = '^\s*FAIL\b'

function Get-TcSelfTestScore {
  # 'fail' for any non-zero exit, and for an exit 0 whose stdout says it failed (FailLines names the lines); 'ok' for
  # exit 0 with a verdict; 'no-verdict' otherwise.
  param([int]$ExitCode, [object[]]$Lines)
  if ($ExitCode -ne 0) { return [pscustomobject]@{ Score = 'fail'; Verdict = $null; FailLines = @() } }
  $said = @(@($Lines) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ } |
    Where-Object { $_ -cmatch $script:TcFailSelfTest -or $_ -cmatch $script:TcFailCase })
  if ($said.Count) { return [pscustomobject]@{ Score = 'fail'; Verdict = $null; FailLines = $said } }
  $v = Get-TcSelfTestVerdict -Lines $Lines
  $score = if ($v.Found) { 'ok' } else { 'no-verdict' }
  return [pscustomobject]@{ Score = $score; Verdict = $v; FailLines = @() }
}

if ($__svSelfTest) {
  $ErrorActionPreference = 'Stop'
  $script:svFail = 0
  $script:svCases = 0
  function Test-SvCase([string]$Label, [scriptblock]$Check) {
    # A case that THROWS is a counted failure, never a skipped line: a suite whose cases all error must not pass.
    $script:svCases++
    $ok = $false
    try { $ok = [bool](& $Check) } catch { $Label = $Label + ' (threw: ' + $_.Exception.Message + ')' }
    if ($ok) { Write-Output ('  PASS  ' + $Label) } else { Write-Output ('  FAIL  ' + $Label); $script:svFail++ }
  }
  function Get-SvFound([string[]]$Out) { return (Get-TcSelfTestVerdict -Lines $Out).Found }

  # ---- the founding output, as lines ------------------------------------------------------------------------------
  $founding = @(
    '  ok    MUST NOT FIRE  a complete circular read adds no REVIEW line',
    '  ok    MUST FIRE  a Family Fare pull that ERRORED adds a REVIEW line rather than passing silently beside two PASS stores',
    'Today: 2026-09-11  -  pulling current Omaha weekly ads...',
    '',
    'STORE        IDENTITY               ZIP     AD FROM     AD TO       OMAHA  CURRENT  DEALS  STATUS',
    'VERIFIED stores: Hy-Vee, Aldi   total verified deals: 412',
    'Saved: C:\Codex\ThriftyCrew\grocery\out\ads-2026-09-11.json')
  Test-SvCase 'MUST FIRE  the 8253ded82 output - every case ok, then the live pull, exit 0 - carries no verdict' { -not (Get-SvFound $founding) }
  Test-SvCase 'MUST FIRE  a verdict printed and then fallen past - production lines after it - is not the last word' {
    -not (Get-SvFound @('  ok    one case', 'SELF-TEST PASS: 1 case(s)', 'pulling...', 'Saved: out\x.json'))
  }
  Test-SvCase 'MUST FIRE  a production COMPLETE marker does not vouch for the self-test before it, when a production line sits between' {
    -not (Get-SvFound @('SELF-TEST PASS: 3 case(s)', 'scanned 40 file(s)', 'AUDIT-X-COMPLETE scanned=40 findings=0'))
  }
  Test-SvCase 'MUST FIRE  only a production marker, with no self-test named anywhere, is no verdict' { -not (Get-SvFound @('AUDIT-X-COMPLETE scanned=40 findings=0')) }
  Test-SvCase 'MUST FIRE  empty stdout is no verdict, and says so' {
    $v = Get-TcSelfTestVerdict -Lines @()
    (-not $v.Found) -and ($v.Reason -match 'nothing')
  }
  Test-SvCase 'MUST FIRE  $null output is no verdict - @($null) has one element and it is not a line' { -not (Get-SvFound $null) }
  Test-SvCase 'MUST FIRE  a last CASE line that happens to mention the self-test is still a case line' {
    -not (Get-SvFound @('  ok    the self-test branch exits before the pull'))
  }
  Test-SvCase 'MUST FIRE  a trailing label-then-ok case line is a case line too' {
    -not (Get-SvFound @('  MUST FIRE      the self-test clears GIT_DIR  ok'))
  }
  Test-SvCase 'MUST FIRE  a line that names the self-test with NO result word is not a verdict (audit-count-gpu printed SELF-TEST: all predicates hold)' {
    -not (Get-SvFound @('SELF-TEST: all predicates hold'))
  }

  # ---- the spellings measured on 2026-09-11, one of each family ----------------------------------------------------
  $spellings = @(
    'SELF-TEST PASS',
    'SELF-TEST PASS: 21 case(s)',
    'SELFTEST-DISCOVERY SELF-TEST PASSED (14 of 14 case(s): renamed switches enrol with their own name)',
    'verdict_expiry selftest: 12 of 12 cases pass',
    'SELFTEST: 28/28 pass',
    'ENGINE SELFTEST: all 9 passed',
    'SELFTEST PASS',
    'capture-lib: all self-tests pass',
    'self-test OK',
    'pool selftest: all green',
    'report self-test: 5/5 ok',
    'prepush-test-auditors -SelfTest: 26 of 26 cases pass',
    'ff-carry: own-feed-coverage and cheapest-pick fixtures both hold - SELF-TEST PASS')
  foreach ($sp in $spellings) {
    $one = $sp
    Test-SvCase ('MUST NOT FIRE  a measured verdict spelling is found: ' + $one) { Get-SvFound @('  ok    a case', $one) }
  }
  Test-SvCase 'MUST NOT FIRE  a verdict followed by a guard marker is found through the marker' {
    $v = Get-TcSelfTestVerdict -Lines @('  ok    a case', 'test-prepush-hook selftest: 31 of 31 cases pass', 'TEST-PREPUSH-HOOK-COMPLETE cases=31', '')
    $v.Found -and ($v.By -ceq 'line')
  }
  Test-SvCase 'MUST NOT FIRE  a marker that names the self-test is the verdict, BLIND lines before it notwithstanding (start-sidecar)' {
    $v = Get-TcSelfTestVerdict -Lines @('start-sidecar selftest: 15 of 16 cases pass, 1 BLIND - could not look, NOT passed:', '  MUST FIRE the sidecar venv interpreter exists', 'START-SIDECAR-SELFTEST-COMPLETE cases=16 blind=1')
    $v.Found -and ($v.By -ceq 'marker')
  }
  Test-SvCase 'MUST NOT FIRE  a marker whose summary says selftest= is the verdict (seo_reach_diagnosis)' {
    (Get-TcSelfTestVerdict -Lines @('  totals derive from the rows     ok', 'SEO-REACH-DIAGNOSIS-COMPLETE selftest=pass')).By -ceq 'marker'
  }

  # ---- scoring -------------------------------------------------------------------------------------------------------
  Test-SvCase 'MUST FIRE  exit 0 with no verdict scores no-verdict, never ok' { (Get-TcSelfTestScore -ExitCode 0 -Lines $founding).Score -ceq 'no-verdict' }
  Test-SvCase 'MUST NOT FIRE  exit 0 with a verdict scores ok' { (Get-TcSelfTestScore -ExitCode 0 -Lines @('SELF-TEST PASS: 3 case(s)')).Score -ceq 'ok' }
  Test-SvCase 'CLEAN TWIN  a non-zero exit still scores fail with its FAIL verdict - the exit code keeps the sense' {
    (Get-TcSelfTestScore -ExitCode 1 -Lines @('  FAIL  a case', 'SELF-TEST FAIL: 1 of 3 case(s)')).Score -ceq 'fail'
  }
  Test-SvCase 'CLEAN TWIN  a timed-out child (exit 3, no output) still scores fail, not no-verdict' { (Get-TcSelfTestScore -ExitCode 3 -Lines @()).Score -ceq 'fail' }

  # ---- the sense: what a suite SAYS outweighs its exit 0 -------------------------------------------------------------
  # Needles by concatenation, and no label below spells the failing sequence, so this suite's own output - which run-gates
  # scores with this very rule - cannot trip it ([[selftest-greps-its-own-source]]).
  $svSf = 'SELF-TEST ' + 'FAIL'
  $svCaseFail = '  ' + 'FAIL' + '  a case'
  Test-SvCase 'MUST FIRE  exit 0 whose last line is its own failing verdict scores fail - found is not passed' {
    $s = Get-TcSelfTestScore -ExitCode 0 -Lines @('  ok    one case', ($svSf + ': 1 of 2 case(s)'))
    ($s.Score -ceq 'fail') -and (@($s.FailLines).Count -eq 1)
  }
  Test-SvCase 'MUST FIRE  exit 0 with an anchored failing case line scores fail, even under a passing verdict' {
    (Get-TcSelfTestScore -ExitCode 0 -Lines @($svCaseFail, 'SELF-TEST PASS: 3 case(s)')).Score -ceq 'fail'
  }
  Test-SvCase 'MUST NOT FIRE  the word mid-line - a case label about failing lines, or a passing verdict naming them - stays ok' {
    (Get-TcSelfTestScore -ExitCode 0 -Lines @('  ok    MUST FIRE  a FAIL line is reported', 'SELF-TEST PASS: fixtures cover FAIL lines')).Score -ceq 'ok'
  }
  Test-SvCase 'MUST NOT FIRE  a lower-case failed=0 in a self-test marker is not a failure line (pull-browser-stores)' {
    (Get-TcSelfTestScore -ExitCode 0 -Lines @('  ok    a case', 'DRIVER-SELFTEST-COMPLETE stores=3 lookup=hermetic failed=0')).Score -ceq 'ok'
  }

  # ---- end to end: a real child through the pool run-gates uses, scored by the function run-gates calls ---------------
  # One scratch directory per run, every path recorded, removed in finally ([[test-suites-leak-temp-dirs]] and the
  # GcScratch rule in lib\guard-contract.ps1). No network: the "production path" below only prints.
  . (Join-Path $PSScriptRoot 'parallel-run.ps1')   # Invoke-TcParallel - no param() block, so it cannot reset ours
  $svRoot = Join-Path $env:TEMP ('sv-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $svRoot -ErrorAction Stop | Out-Null
  $svMade = New-Object System.Collections.Generic.List[string]
  function Get-SvScratch([string]$Leaf) { $p = Join-Path $svRoot $Leaf; [void]$svMade.Add($p); return $p }
  try {
    $head = @(
      'param([switch]$SelfTest)',
      '$fail = 0; $n = 0',
      'function _T([string]$m, [bool]$c) { $script:n++; if ($c) { Write-Output (''  ok    '' + $m) } else { Write-Output (''  FAIL  '' + $m); $script:fail++ } }',
      'if ($SelfTest) {')
    $verdict = 'if ($fail -eq 0) { Write-Output "SELF-TEST PASS: $n case(s)"; exit 0 } else { Write-Output "SELF-TEST FAIL: $fail of $n case(s)"; exit 1 }'
    $tail = @('}', 'Write-Output ''Today: 2026-09-11  -  pulling current Omaha weekly ads...''', 'Write-Output ''Saved: out\ads-2026-09-11.json''')
    $glued = Get-SvScratch 'glued.ps1'
    [IO.File]::WriteAllText($glued, ((@($head) + @("  _T 'MUST FIRE  a case' (`$true)  " + $verdict) + $tail) -join "`r`n"), (New-Object Text.UTF8Encoding($false)))
    $apart = Get-SvScratch 'apart.ps1'
    [IO.File]::WriteAllText($apart, ((@($head) + @("  _T 'MUST FIRE  a case' (`$true)", ('  ' + $verdict)) + $tail) -join "`r`n"), (New-Object Text.UTF8Encoding($false)))
    $red = Get-SvScratch 'red.ps1'
    [IO.File]::WriteAllText($red, ((@($head) + @("  _T 'MUST FIRE  a case' (`$false)", ('  ' + $verdict)) + $tail) -join "`r`n"), (New-Object Text.UTF8Encoding($false)))
    # THE COMPLEMENT'S FOUNDING SHAPE: a failing case, its FAIL verdict printed, the exit line lost, and nothing after
    # the branch - so the verdict IS the last word and the process exits 0.
    $lost = Get-SvScratch 'lost.ps1'
    $lostVerdict = 'if ($fail -eq 0) { Write-Output "SELF-TEST PASS: $n case(s)" } else { Write-Output "SELF-TEST FAIL: $fail of $n case(s)" }'
    [IO.File]::WriteAllText($lost, ((@($head) + @("  _T 'a case' (`$false)", ('  ' + $lostVerdict), '}')) -join "`r`n"), (New-Object Text.UTF8Encoding($false)))

    $PSX = (Get-Command powershell).Source
    $jobs = @($glued, $apart, $red, $lost | ForEach-Object { [pscustomobject]@{ Exe = $PSX; ArgList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $_, '-SelfTest') } })
    $res = Invoke-TcParallel -Jobs $jobs -Concurrency 1
    $gOut = @($res[0].Out); $aOut = @($res[1].Out); $rOut = @($res[2].Out); $lOut = @($res[3].Out)
    $lScore = Get-TcSelfTestScore -ExitCode $res[3].ExitCode -Lines $lOut
    Test-SvCase ('MUST FIRE  A LOST EXIT, RUN: a child whose failing verdict is its last word and which exits 0 scores fail, not ok (exit ' + $res[3].ExitCode + ', ' + @($lScore.FailLines).Count + ' failing line(s) read)') {
      ($res[3].ExitCode -eq 0) -and ($lScore.Score -ceq 'fail') -and (@($lScore.FailLines).Count -ge 1)
    }
    $gScore = Get-TcSelfTestScore -ExitCode $res[0].ExitCode -Lines $gOut
    Test-SvCase ('MUST FIRE  THE FOUNDING SHAPE, RUN: a verdict glued onto the last case line falls through to the production path, exits 0, and scores no-verdict (exit ' + $res[0].ExitCode + ', last: ' + (@($gOut) | Select-Object -Last 1) + ')') {
      ($res[0].ExitCode -eq 0) -and (($gOut -join "`n") -match 'Saved: out') -and ($gScore.Score -ceq 'no-verdict')
    }
    Test-SvCase ('MUST NOT FIRE  the same suite with its verdict on its own line exits 0 before the production path and scores ok (exit ' + $res[1].ExitCode + ')') {
      ($res[1].ExitCode -eq 0) -and -not (($aOut -join "`n") -match 'Saved: out') -and ((Get-TcSelfTestScore -ExitCode $res[1].ExitCode -Lines $aOut).Score -ceq 'ok')
    }
    Test-SvCase ('CLEAN TWIN  the same suite with a failing case still exits 1 and scores fail (exit ' + $res[2].ExitCode + ')') {
      ($res[2].ExitCode -eq 1) -and ((Get-TcSelfTestScore -ExitCode $res[2].ExitCode -Lines $rOut).Score -ceq 'fail')
    }
  } finally {
    foreach ($made in $svMade) { Remove-Item -LiteralPath $made -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $svRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
  Test-SvCase ('the per-run scratch directory is removed on the way out, with the ' + $svMade.Count + ' path(s) it handed out') {
    ($svMade.Count -eq 4) -and -not (Test-Path -LiteralPath $svRoot)
  }

  if ($script:svCases -eq 0) { Write-Output 'SELFTEST-VERDICT SELF-TEST FAILED (ran zero cases)'; exit 1 }
  if ($script:svFail) { Write-Output ("SELFTEST-VERDICT SELF-TEST FAILED ({0} of {1} case(s))" -f $script:svFail, $script:svCases); exit 1 }
  Write-Output ("SELFTEST-VERDICT SELF-TEST PASSED ({0} of {0} case(s): a suite that exits 0 past its verdict scores no-verdict, run end to end through the gate pool, and every measured verdict spelling is still found)" -f $script:svCases)
  exit 0
}
