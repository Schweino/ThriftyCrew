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
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$root = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\grocery' }
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

# CONTAINING the helper is not the same as EMITTING it. The 2026-08-08 retrofit patched 6 files that all
# passed Test-EmitsMarker and 3 of them printed nothing on the path they actually take - they finish on a
# conditional exit above the one that got the marker. Presence is the right RATCHET question; this is the
# COMPLETENESS one. AST, not regex, so the word "exit" in a comment or a string cannot fool it.
function Get-BareVerdictExits { param([string]$Text)
  $e2 = $null; $t2 = $null
  $a = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$t2, [ref]$e2)
  if ($e2 -and $e2.Count) { return @() }
  $lines = $Text -split "`r?`n"
  $skip = @()   # a -SelfTest branch has its own PASS/FAIL line and must not carry a completion marker
  foreach ($n in $a.FindAll({ $args[0] -is [System.Management.Automation.Language.IfStatementAst] }, $true)) {
    foreach ($cl in $n.Clauses) { if ($cl.Item1.Extent.Text -match '\$SelfTest') { $skip += ,@($n.Extent.StartOffset, $n.Extent.EndOffset) } }
  }
  $bare = @()
  foreach ($x in $a.FindAll({ $args[0] -is [System.Management.Automation.Language.ExitStatementAst] }, $true)) {
    $code = if ($x.Pipeline) { $x.Pipeline.Extent.Text.Trim() } else { '0' }
    if ($code -ne '0' -and $code -ne '1' -and $code -ne '2') { continue }   # 3 = could-not-evaluate, never marked
    $off = $x.Extent.StartOffset
    $inST = $false; foreach ($r in $skip) { if ($off -ge $r[0] -and $off -lt $r[1]) { $inST = $true } }
    if ($inST) { continue }
    $ln = $x.Extent.StartLineNumber
    # THE TWO HALVES OF THIS FILE DISAGREED, AND THE COMPLETENESS HALF WAS THE STRICTER ONE (fixed
    # 2026-08-23). Test-EmitsMarker above accepts EITHER shape - a Write-GuardComplete call or a literal
    # '<NAME>-COMPLETE' line - because both satisfy the contract, which is about what reaches STDOUT. This
    # look-back only recognised the helper. So every detector that writes its marker as a literal was
    # reported HALF-COVERED on paths where it is completely correct: audit-commodity-dupes.ps1 prints
    # 'COMMODITY-DUPES-COMPLETE' immediately before BOTH of its exits and was accused at both (lines 219
    # and 235), and test-native-stderr-eap.ps1 the same at 280. Three of the eight HALF findings on
    # 2026-08-23 were this bug, not the audited scripts.
    #
    # A watcher that cries wolf on correct code is not a stricter watcher, it is a quieter one: the reader
    # learns the HALF list contains noise and stops reading the entries that are real. Same predicate as
    # Test-EmitsMarker, so the two questions can never drift apart again.
    $before = $lines[[Math]::Max(0, $ln - 4)..($ln - 1)] -join "`n"
    if ($before -match 'Write-GuardComplete' -or $before -match "['`"][A-Z0-9-]+-COMPLETE") { continue }
    $bare += $ln
  }
  return @($bare)
}

# Branches that legitimately leave WITHOUT a marker, and how many each file is allowed. All of them are modes
# that run no detection: -Baseline records a baseline, -PrepareOnly builds inputs, a no-mode invocation prints
# usage, and store-coverage SKIPs when there is no built board to examine. A marker on any of these would
# vouch for a run that examined nothing - the same lie from the other direction. Counted, not blanket-allowed,
# so a NEW bare exit in one of these files still surfaces.
# ---- A GUARD WHOSE ONLY CALLER IS ITS OWN TEST IS DEAD (2026-08-08) --------------------------------------
# audit-script-census already enforces "every script is called by code, or is recorded as a deliberate manual
# entry point". audit-unit-basis-outlier.ps1 was in NEITHER list and the census was still green, because the
# one executable naming it was test-auditors.ps1 - its own test. Naming a guard in a test satisfies
# reachability and runs it exactly never, so the guard sat dead from 07-31 while the board published butter
# priced from a bottle of pancake syrup.
#
# So reachability has to distinguish a PRODUCTION caller from a TEST caller. These files only test or
# describe other scripts; a reference from one of them proves the guard is TESTED, not that it RUNS.
$script:TESTER_FILES = @(
  'test-auditors.ps1', 'test-guards.ps1', 'test-scale-hardening.ps1', 'regression-test.ps1',
  'audit-script-census.ps1',      # asks who calls what; naming a script is its whole job
  'audit-guard-contract.ps1'      # this file
)
function Test-IsTesterFile { param([string]$Name) return ($script:TESTER_FILES -contains $Name) }

# Detectors that legitimately have no production caller, each with the reason. Keyed by NAME alone, unlike
# the drift allowlists: what is being blessed here is a permanent property of the script ("this is a manual
# diagnostic"), not a transient state that a content hash should re-arm on.
$script:MANUAL_OK = Join-Path $root 'detector-manual-allowlist.json'

$script:BARE_ALLOWED = @{
  'aisle-test.ps1'               = 1   # no -Candidates/-Id/-LiveBoard: "nothing to judge"
  'audit-guard-contract.ps1'     = 1   # -Baseline
  'audit-row-age.ps1'            = 1   # -Baseline
  'audit-schema-constraints.ps1' = 1   # -Baseline
  'audit-semantic-identity.ps1'  = 1   # -PrepareOnly
  'audit-store-coverage.ps1'     = 1   # SKIP: no built board to examine
  # -Json: the whole stdout IS the report, and a caller pipes it to ConvertFrom-Json. A completion
  # marker appended there would not prove anything - it would make the document unparseable, which is
  # a worse failure than the one it guards against. The detection still runs; only the rendering
  # differs, and the human-readable path one line below carries the marker as normal.
  'audit-carriage.ps1'           = 1   # -Json: stdout is a JSON document, a marker would corrupt it
  'audit-search-terms.ps1'       = 1   # -Json: same, and its human path got the marker on 2026-08-23
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

  # FROZEN FIXTURE, the half-covered shape: audit-everyday-mismatch exactly as the first retrofit left it.
  # The marker sat BELOW the findings exit, so it proved completion only when it found nothing.
  $half = "if (`$bugs.Count -gt 0) { exit 1 }`nWrite-GuardComplete -Name 'x'`nexit 0"
  # ---- tested is not the same as run ----
  # FROZEN from the audit-unit-basis-outlier incident: before 2026-08-08 the ONLY executable naming it was
  # test-auditors.ps1, it was absent from the census's KNOWN list, and the census was green. It ran never.
  T 'MUST FIRE  test-auditors is a TESTER, so naming a guard there is not a production call' (Test-IsTesterFile 'test-auditors.ps1') 'counted as production'
  T 'MUST FIRE  test-guards is a TESTER too' (Test-IsTesterFile 'test-guards.ps1') 'counted as production'
  T 'the census is a TESTER - naming scripts is its whole job' (Test-IsTesterFile 'audit-script-census.ps1') 'counted as production'
  T 'CLEAN TWIN the daily chain is NOT a tester - a call from it is a real one' (-not (Test-IsTesterFile 'check-ad-cycles.ps1')) 'chain treated as a test'
  T 'CLEAN TWIN guards.ps1 is NOT a tester - it delegates for real' (-not (Test-IsTesterFile 'guards.ps1')) 'guards treated as a test'

  T 'MUST FIRE  a marker below a conditional verdict exit leaves that exit bare' `
    ((Get-BareVerdictExits $half).Count -eq 1) ("bare=" + (Get-BareVerdictExits $half).Count)
  # CLEAN TWIN: the same file with the marker moved above the verdict block - both paths covered
  $whole = "Write-GuardComplete -Name 'x'`nif (`$bugs.Count -gt 0) { exit 1 }`nexit 0"
  T 'CLEAN TWIN a marker above the verdict block covers every exit' `
    ((Get-BareVerdictExits $whole).Count -eq 0) ("bare=" + (Get-BareVerdictExits $whole).Count)
  # exit 3 is could-not-evaluate: it must NEVER be asked to carry a completion marker
  T 'an exit 3 is not a bare verdict exit (could-not-evaluate is not completion)' `
    ((Get-BareVerdictExits "Write-Output 'blind'`nexit 3").Count -eq 0) 'demanded a marker on exit 3'
  # the word "exit" inside a comment or a string must not be mistaken for a real one
  T 'comments and strings are not exits (AST, not regex)' `
    ((Get-BareVerdictExits "# exit 0 here`nWrite-Output 'exit 0'").Count -eq 0) 'regex-fooled'
  # a -SelfTest branch has its own PASS/FAIL line and is not part of the contract
  T 'exits inside an if ($SelfTest) block are not counted' `
    ((Get-BareVerdictExits "if (`$SelfTest) {`n  exit 0`n}").Count -eq 0) 'counted a self-test exit'
  if ($f -eq 0) { Write-Output 'SELF-TEST PASS'; exit 0 } else { Write-Output "SELF-TEST FAIL: $f case(s)"; exit 1 }
}

# ---- which detectors does the chain actually invoke? -----------------------------------------------------
$chainText = [IO.File]::ReadAllText((Join-Path $root 'check-ad-cycles.ps1'))
# A MENTION IS NOT A CALL (2026-08-23). This scanned the WHOLE file text for anything shaped like a
# .ps1 name, so three files were reported as having "joined the chain with no completion marker"
# when the chain does not run them at all:
#   test-cadence.ps1               named in three PROSE COMMENTS explaining where the cadence
#                                  helpers live and which self-test extracts them
#   test-log-sidecar-recovery.ps1  named in one comment, next to the sentinel it extracts between
#   audit-household-in-food.ps1    named inside a cadence -InputGlobs array - it is a file whose
#                                  MTIME the matcher-parity gate watches, the exact opposite of a
#                                  thing this file runs
# Three of the four NEW findings on 2026-08-23 were this, and the cost is the same as the
# HALF-COVERED false positives fixed below: a list with noise in it stops being read, and the one
# real entry (audit-search-terms.ps1) sat in the middle of three imaginary ones.
#
# ONLY provably-not-a-call shapes are removed, because the failure this check exists to catch is a
# detector that joined the chain UNNOTICED - so it must keep erring toward over-reporting:
#   * comment lines AND <# block comments #> - nothing in either executes. Both are needed: this
#     file's helpers carry long docstrings, and test-cadence.ps1 is named inside one of them
#     (Set-CadenceRan's, "test-cadence.ps1 case 2 is what caught it") on a line that does not
#     start with #, so a line-only filter still accused it
#   * repo-relative 'grocery/x.ps1' strings - every real invocation in this file resolves the path
#     with Join-Path $root 'x.ps1', so a forward slash and a directory prefix means it is data
#     (a cadence input glob, a path in an alert body), not an invocation
$chainCode = [regex]::Replace($chainText, '(?s)<#.*?#>', ' ')
$chainCode = (($chainCode -replace "`r", '') -split "`n" | Where-Object { $_.TrimStart() -notmatch '^#' }) -join "`n"
$chainCode = [regex]::Replace($chainCode, '[A-Za-z0-9_.-]+/[a-z0-9][a-z0-9-]*\.ps1', ' ')
$invoked = @()
foreach ($m in [regex]::Matches($chainCode, '([a-z0-9][a-z0-9-]*\.ps1)')) { $invoked += $m.Groups[1].Value }
$invoked = @($invoked | Sort-Object -Unique | Where-Object { Test-IsDetector $_ })

$covered = @(); $uncovered = @(); $missing = @(); $halfCovered = @()
foreach ($n in $invoked) {
  $p = @(Get-ChildItem $repo -Recurse -Filter $n -File -ErrorAction SilentlyContinue |
         Where-Object { $_.FullName -notmatch '\\worktrees\\|\\archive\\' } | Select-Object -First 1)
  if (-not $p.Count) { $missing += $n; continue }
  $txt = [IO.File]::ReadAllText($p[0].FullName)
  if (-not (Test-EmitsMarker $txt)) { $uncovered += $n; continue }
  $covered += $n
  $bare  = @(Get-BareVerdictExits $txt)
  $allow = if ($script:BARE_ALLOWED.ContainsKey($n)) { $script:BARE_ALLOWED[$n] } else { 0 }
  if ($bare.Count -gt $allow) { $halfCovered += [pscustomobject]@{ name = $n; lines = $bare; allow = $allow } }
}

# ---- which detectors on disk have no PRODUCTION caller at all? -------------------------------------------
# GIT HOOKS ARE PRODUCTION CALLERS AND HAVE NO FILE EXTENSION (2026-09-05). ops\hooks\pre-commit runs
# verify-bulk-edit.ps1 on every commit in this repo, which is a stricter production path than most entries
# in this list because it cannot be forgotten. It was reported DEAD purely because the include list below is
# extension-based and a git hook is an extensionless shell script. Recording it in the manual allowlist would
# have been the WRONG fix: that says 'nothing calls this, deliberately' about a detector that in fact runs
# more often than the daily chain does.
$hookFiles = @(Get-ChildItem (Join-Path $repo 'ops\hooks') -File -ErrorAction SilentlyContinue)
$execFiles = @(Get-ChildItem $repo -Recurse -File -Include *.ps1,*.psm1,*.js,*.yml,*.yaml,*.vbs,*.bat,*.cmd -ErrorAction SilentlyContinue |
               Where-Object { $_.FullName -notmatch '\\worktrees\\|\\archive\\|node_modules|\.venv' })
$execFiles = @($execFiles) + @($hookFiles)
$execText = @{}
foreach ($f in $execFiles) { try { $execText[$f.FullName] = [IO.File]::ReadAllText($f.FullName) } catch { } }

$manualOk = @{}
if (Test-Path $script:MANUAL_OK) {
  try { foreach ($m in (Read-JsonFile $script:MANUAL_OK).manual) { $manualOk[[string]$m.name] = [string]$m.reason } } catch { }
}

$onDisk = @($execFiles | Where-Object { $_.Extension -eq '.ps1' -and (Test-IsDetector $_.Name) -and -not (Test-IsTesterFile $_.Name) })
$dead = @()
foreach ($d in $onDisk) {
  $prod = @()
  foreach ($f in $execFiles) {
    if ($f.FullName -eq $d.FullName) { continue }
    if (Test-IsTesterFile $f.Name) { continue }              # tested is not the same as run
    if ($execText[$f.FullName] -and $execText[$f.FullName].Contains($d.Name)) { $prod += $f.Name }
  }
  if (-not $prod.Count -and -not $manualOk.ContainsKey($d.Name)) { $dead += $d.Name }
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
# HALF-COVERED is a hard finding, not a backlog item: the file passes the presence check, so nothing else in
# the estate can see that it stays silent on the exact path it takes when it finds something.
foreach ($h in $halfCovered) {
  Write-Output ("  ! HALF-COVERED: {0} has the marker but leaves by {1} unmarked verdict exit(s) at line(s) {2}{3}" -f `
    $h.name, $h.lines.Count, ($h.lines -join ', '), $(if ($h.allow) { " (allowed $($h.allow))" } else { '' }))
}
foreach ($d in $dead) {
  Write-Output ("  ! DEAD: {0} is a detector that NOTHING in production calls - only its own tests, or nothing at all" -f $d)
}
if ($dead.Count) {
  Write-Output '  A guard nobody runs is not a guard. Wire it into the chain, or record it in'
  Write-Output ("  {0} with the reason it is a manual tool." -f (Split-Path $script:MANUAL_OK -Leaf))
}
if (-not (Test-Path $basePath)) { Write-Output '  (no baseline yet - run -Baseline once to arm the ratchet)' }

. (Join-Path $repo 'lib\guard-contract.ps1')
Write-GuardComplete -Name 'guard-contract' -Summary ("covered={0} backlog={1} regressed={2} half={3} dead={4}" -f `
  $covered.Count, $uncovered.Count, ($regressed.Count + $newBare.Count), $halfCovered.Count, $dead.Count)
exit $(if ($regressed.Count -or $newBare.Count -or $halfCovered.Count -or $dead.Count) { 1 } else { 0 })
