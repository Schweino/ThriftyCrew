<#
  test-auditors.ps1 - proves the WATCHERS still work. Complements test-guards.ps1, which breaks a live
  invariant and asserts guards.ps1 exits 2; this one tests the auditors and alert plumbing that guards.ps1
  does not own, using FROZEN FIXTURES instead of mutating live data.

  WHY (2026-07-28): three watchers were silently wrong at the same time, and every one of them had been
  "passing" for days by reporting nothing:
    - triage-due.ps1 read a queue file mid-rewrite, got '', and printed IDLE over 5 open alerts;
    - check-ad-cycles collapsed 54 sanity outliers into ONE flag line (the email said "16" for 69 flags);
    - audit-coverage-gaps never read the engine's GLOBAL_EXCLUDE, so engine-refused products were filed
      as coverage gaps forever.
  The layer that decides whether anything is wrong was the least tested layer in the estate. A guard that
  reports nothing is indistinguishable from a guard that is broken - unless something proves it can still
  fire. THE RULE: every guard ships with two fixtures, one where it MUST fire and one where it MUST stay
  silent, and the "must fire" fixture is the bug that caused it to be written.

  Fixtures live in regression-inputs\guard-fixtures\ and are frozen board slices - never regenerate them
  from the live board, or the bug they encode disappears and the test passes by finding nothing (exactly
  how the Lysol negative test in test-guards.ps1 quietly stopped testing anything).

  Usage: test-auditors.ps1        (exit 0 = all pass, 2 = at least one watcher cannot see its own bug)
#>
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$fix  = Join-Path $root 'regression-inputs\guard-fixtures'
$pass = 0; $failed = 0
function Ok($m)   { Write-Output ("  PASS  " + $m); $script:pass++ }
function Bad($m)  { Write-Output ("  FAIL  " + $m); $script:failed++ }
function RunPS($script, $argList) {
  $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root $script) @argList 2>&1 | ForEach-Object { [string]$_ }
  return [pscustomobject]@{ rc = $LASTEXITCODE; text = ($out -join "`n") }
}

Write-Output 'test-auditors: can each watcher still see the bug it was written for?'

# A FIXTURE RUN MUST NOT WRITE WHERE THE LIVE RUN WRITES (2026-07-31).
# audit-basis-reconcile and audit-pack-basis take the board to examine as -CompareFile, but the path they
# write their REPORT to was hardcoded to out\. So every run of this harness overwrote out\basis-reconcile.json
# and out\pack-basis-audit.json with a FIXTURE's result: measured after the 06:47 run, out\pack-basis-audit.json
# said compare_file='packbasis-legit-bulk-board.json', finding_count 0 - a synthetic clean board's report
# parked exactly where a human, and the next reader, looks for the real board's. A harness that proves the
# guards work must not damage the evidence the guards produced.
# Both audits now take -ReportDir (default out\, so live behaviour is untouched) and every fixture call below
# points it here. Temp, not the fixture folder itself: fixtures are FROZEN, and a run that writes into them
# is how a frozen fixture stops being frozen.
$fixRep = Join-Path $env:TEMP ('taudit-rep-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $fixRep -Force

# ---------------------------------------------------------------- 1. basis reconciler
# MUST FIRE: Hy-Vee published $3.15/lb for corned beef brisket while the store's own size text printed
# "($8.99/lb)" right there on the same row.
$r = RunPS 'audit-basis-reconcile.ps1' @('-CompareFile', (Join-Path $fix 'basis-conflict-board.json'), '-ReportDir', $fixRep)
if ($r.text -match 'corned-beef-brisket' -and $r.text -match 'disagree') { Ok 'basis-reconcile FIRES on the per-lb-rate conflict' }
else { Bad ('basis-reconcile MISSED its founding bug: ' + $r.text) }
# MUST BE SILENT: same board with the cell corrected to the store's own rate.
$r = RunPS 'audit-basis-reconcile.ps1' @('-CompareFile', (Join-Path $fix 'basis-clean-board.json'), '-ReportDir', $fixRep)
if ($r.text -match 'ok - every checkable cell agrees') { Ok 'basis-reconcile SILENT on the corrected board' }
else { Bad ('basis-reconcile false-positived on a clean board: ' + $r.text) }
# MUST NOT trip on sub-cent rounding (a store publishing "$0.01/ea" against our $0.0053 is rounding, not conflict)
$r = RunPS 'audit-basis-reconcile.ps1' @('-CompareFile', (Join-Path $fix 'basis-rounding-board.json'), '-ReportDir', $fixRep)
if ($r.text -match 'ok - every checkable cell agrees') { Ok 'basis-reconcile ignores whole-cent rounding noise' }
else { Bad ('basis-reconcile tripped on cent rounding: ' + $r.text) }

# ---------------------------------------------------------------- 1b. Baker's netWeight source
# Kroger returns NO unit price, so netWeight (the store's own package weight) is the only independent
# statement available for the estate's largest store. MUST FIRE on the 2026-07-24 Kerrygold class: reading
# "4 ct / 16 oz" as 16 oz PER STICK priced the pack 4x under and no band blinked.
$rawFx = Join-Path $fix 'bakers-raw'
$r = RunPS 'audit-basis-reconcile.ps1' @('-CompareFile', (Join-Path $fix 'bakers-netweight-conflict-board.json'), '-RawDir', $rawFx, '-ReportDir', $fixRep)
if ($r.text -match 'butter' -and $r.text -match 'netWeight') { Ok "basis-reconcile FIRES when Baker's size disagrees with Kroger's own netWeight" }
else { Bad ('basis-reconcile missed the netWeight conflict: ' + $r.text) }
# MUST BE SILENT once the size is read correctly...
$r2 = RunPS 'audit-basis-reconcile.ps1' @('-CompareFile', (Join-Path $fix 'bakers-netweight-clean-board.json'), '-RawDir', $rawFx, '-ReportDir', $fixRep)
if ($r2.text -match 'ok - every checkable cell agrees') { Ok 'basis-reconcile SILENT when the pack size matches netWeight' }
else { Bad ('basis-reconcile false-positived on a correct netWeight board: ' + $r2.text) }
# ...and must IGNORE a soldBy=WEIGHT row, whose netWeight is the random tray weight (Tyson reads 22.56 lb).
# Both fixtures carry that row; "checked 1 cell" proves it was skipped rather than silently agreeing.
if ($r.text -match 'checked 1 cell' -and $r2.text -match 'checked 1 cell') { Ok 'basis-reconcile ignores a per-pound (soldBy=WEIGHT) row, whose netWeight is a tray weight' }
else { Bad 'basis-reconcile is reading netWeight on a soldBy=WEIGHT row - that is the random tray weight, not a package size' }

# ---------------------------------------------------------------- 1c. one NAME, two products
# 2026-07-28: the join keyed on store+item name and kept the first match, so a multipack cell was compared
# against the single-unit row of the same name and two perfectly correct rows produced a clean 2x "conflict"
# ("Kroger Original Cream Cheese" is both an 8 oz brick and a 2 ct / 8 oz pack; Sam's listed one Pledge
# 3-pack twice). The cell here is CORRECT at $3.29/16 oz, so silence proves the join picked the right row -
# a name-only join would compare it to the 8 oz single at $0.411/oz and flag.
$r = RunPS 'audit-basis-reconcile.ps1' @('-CompareFile', (Join-Path $fix 'bakers-namecollision-board.json'), '-RawDir', (Join-Path $fix 'bakers-raw-collision'), '-ReportDir', $fixRep)
if ($r.text -match 'ok - every checkable cell agrees' -and $r.text -match 'checked 1 cell') { Ok 'basis-reconcile picks the right row when two products share one name' }
else { Bad ('basis-reconcile cross-matched two products sharing a name: ' + $r.text) }

# ---------------------------------------------------------------- 2. pack-basis heuristic
# MUST FIRE: Sam's Pledge 3-pack whose 29 oz TOTAL was multiplied into an 87 oz each-size, making it the
# cheapest furniture polish in Omaha at a third of its real price.
$r = RunPS 'audit-pack-basis.ps1' @('-CompareFile', (Join-Path $fix 'packbasis-board.json'), '-ReportDir', $fixRep)
if ($r.text -match 'furniture-polish' -and $r.text -match 'multiplied') { Ok 'pack-basis FIRES on the Pledge pack-total bug' }
else { Bad ('pack-basis MISSED its founding bug: ' + $r.text) }
# MUST BE SILENT on genuine bulk: 24 ct x 16.9 fl oz water and a 3 pk x 5 lb grits really are that cheap.
$r = RunPS 'audit-pack-basis.ps1' @('-CompareFile', (Join-Path $fix 'packbasis-legit-bulk-board.json'), '-ReportDir', $fixRep)
if ($r.text -match 'ok - no multipack cell') { Ok 'pack-basis SILENT on legitimate bulk multipacks' }
else { Bad ('pack-basis false-positived on real bulk: ' + $r.text) }

# ---------------------------------------------------------------- 3. triage-due must FAIL CLOSED
# Run a COPY of the guard in a temp dir so the live queue is never touched ($PSScriptRoot decides its paths).
$tmp = Join-Path $env:TEMP ('triage-fixture-' + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Force $tmp | Out-Null
Copy-Item (Join-Path $root 'triage-due.ps1') (Join-Path $tmp 'triage-due.ps1')
function RunTriage($content) {
  $qf = Join-Path $tmp 'triage-queue.json'
  if ($null -eq $content) { Remove-Item $qf -ErrorAction SilentlyContinue }
  else { [IO.File]::WriteAllText($qf, $content, (New-Object Text.UTF8Encoding($false))) }
  $o = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $tmp 'triage-due.ps1') 2>&1 | ForEach-Object { [string]$_ }
  return ($o -join ' ')
}
# the exact 2026-07-28 failure: a queue file caught mid-rewrite reads as an empty string, and in PS 5.1
# '' | ConvertFrom-Json returns $null WITHOUT throwing - the catch never fires and IDLE gets printed.
$t = RunTriage ''
if ($t -match '^DUE') { Ok 'triage-due says DUE on an empty (mid-write) queue file' }
else { Bad ('triage-due FAILED OPEN on an empty queue - it said: ' + $t) }
$t = RunTriage '{ "items": [ {"id":"x","status":"op'
if ($t -match '^DUE') { Ok 'triage-due says DUE on truncated JSON' }
else { Bad ('triage-due FAILED OPEN on truncated JSON - it said: ' + $t) }
$t = RunTriage '{"items":[{"id":"a","status":"open","count":1,"subject":"fixture alert"}]}'
if ($t -match '^DUE' -and $t -match 'fixture alert') { Ok 'triage-due says DUE and names a genuinely open item' }
else { Bad ('triage-due missed an open item - it said: ' + $t) }
$t = RunTriage '{"items":[{"id":"a","status":"resolved","count":1,"subject":"done"}]}'
if ($t -match '^IDLE') { Ok 'triage-due says IDLE only when the queue is really clear' }
else { Bad ('triage-due cried wolf on a clear queue - it said: ' + $t) }
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------- 4. the PS 5.1 array-wrap trap, repo-wide
# @(Get-Content x | ConvertFrom-Json) does NOT unroll a JSON array in 5.1: it yields ONE element holding the
# whole array. That is how 54 sanity outliers became a single flag line. This is a CLASS check, not a
# site check - it fails if the pattern reappears anywhere in the live grocery scripts.
$offenders = @()
foreach ($f in (Get-ChildItem (Join-Path $root '*.ps1'))) {
  if ($f.Name -eq 'test-auditors.ps1') { continue }   # this file quotes the pattern to describe and probe it
  $txt = Get-Content $f.FullName -Raw
  foreach ($ln in ([regex]::Matches($txt, '(?m)^.*@\(\s*Get-Content[^)\r\n]*\|\s*ConvertFrom-Json\s*\).*$'))) {
    if ($ln.Value -match '^\s*#') { continue }   # the explanatory comments are not code
    $offenders += ($f.Name + ': ' + $ln.Value.Trim())
  }
}
if ($offenders.Count -eq 0) { Ok 'no live script wraps a ConvertFrom-Json pipeline in @() (the PS 5.1 no-unroll trap)' }
else { Bad ("the @(Get-Content|ConvertFrom-Json) trap is back in " + $offenders.Count + " place(s):`n      " + ($offenders -join "`n      ")) }

# and prove the trap is real, so nobody "fixes" the check by deleting it
$probe = Join-Path $env:TEMP ('arr-' + [guid]::NewGuid().ToString('N').Substring(0,6) + '.json')
'[{"a":1},{"a":2},{"a":3}]' | Set-Content $probe -Encoding UTF8
$wrapped = @(Get-Content $probe -Raw | ConvertFrom-Json)
$assigned = Get-Content $probe -Raw | ConvertFrom-Json
Remove-Item $probe -Force -ErrorAction SilentlyContinue
if ($wrapped.Count -eq 1 -and @($assigned).Count -eq 3) { Ok 'the no-unroll trap still behaves as documented (wrapped=1, assigned-then-wrapped=3)' }
elseif ($wrapped.Count -eq 3) { Ok 'this PowerShell unrolls ConvertFrom-Json (newer host) - the class check above is belt-and-braces' }
else { Bad 'the array-wrap probe behaved unexpectedly - re-read the ps51-json-array-traps note' }

# ---------------------------------------------------------------- 5. send-alert must write the queue atomically
# The queue is read-modify-written by several processes; Set-Content truncates before it fills, which is the
# window that produced the empty read above. Assert the atomic swap + mutex are still in place.
$sa = Get-Content (Join-Path $root 'send-alert.ps1') -Raw
if ($sa -match 'Move-Item[^\r\n]*\$qFile' -and $sa -match 'System\.Threading\.Mutex') { Ok 'send-alert still writes the queue via mutex + atomic swap' }
else { Bad 'send-alert lost its mutex or atomic swap - a concurrent read can see a truncated queue again' }
if ($sa -match 'refusing to overwrite') { Ok 'send-alert still refuses to overwrite a queue that reads back empty' }
else { Bad 'send-alert lost the refuse-to-overwrite-empty guard - a bad read can wipe the backlog' }

# ---------------------------------------------------------------- 6. coverage-gaps must share the engine's exclusions
# It kept its own opinion of what is not-food and reported engine-refused products as gaps forever.
$cg = Get-Content (Join-Path $root 'audit-coverage-gaps.ps1') -Raw
if ($cg -match 'GLOBAL_EXCLUDE') { Ok 'coverage-gaps reads the engine GLOBAL_EXCLUDE' }
else { Bad 'coverage-gaps no longer reads the engine GLOBAL_EXCLUDE - engine-refused products will be reported as gaps' }
# and prove the parse still yields the real list rather than silently returning empty
$cdtxt = Get-Content (Join-Path $root 'compare-deals.ps1') -Raw
$mg = [regex]::Match($cdtxt, '\$GLOBAL_EXCLUDE = @\((?<b>[\s\S]*?)\r?\n\)')
if ($mg.Success) {
  $ge = @(Invoke-Expression ('@(' + $mg.Groups['b'].Value + ')'))
  if ($ge.Count -ge 20 -and ($ge -contains 'happy\s*tot')) { Ok ("the GLOBAL_EXCLUDE parse yields the real list (" + $ge.Count + " tokens)") }
  else { Bad ("the GLOBAL_EXCLUDE parse returned " + $ge.Count + " tokens - a reformat has broken every auditor that reads it") }
} else { Bad 'the GLOBAL_EXCLUDE block can no longer be parsed out of compare-deals.ps1' }

# ---------------------------------------------------------------- 7. a locked log must not kill the pipeline
# 2026-07-28: a `tail -f` on ad-cycle-log.txt held the file open, Add-Content threw under EAP=Stop, and
# check-ad-cycles died mid-run TWICE - with no log line explaining it, because logging WAS the failure. An
# editor with the log open, a backup or an antivirus scan does the same. Reproduce the exact condition:
# hold an exclusive handle on a log file and assert the Log pattern survives it.
$logProbe = Join-Path $env:TEMP ('logprobe-' + [guid]::NewGuid().ToString('N').Substring(0,6) + '.txt')
'seed' | Set-Content $logProbe -Encoding UTF8
$fs = [IO.File]::Open($logProbe, 'Open', 'ReadWrite', 'None')   # 'None' = no sharing, exactly like a lock
try {
  $probeScript = @'
$ErrorActionPreference = 'Stop'
$log = $args[0]
function Log($m) {
  $line = ("[" + (Get-Date).ToString('s') + "] ") + $m
  for ($i = 0; $i -lt 5; $i++) { try { Add-Content -Path $log -Value $line -ErrorAction Stop; return } catch { Start-Sleep -Milliseconds 120 } }
  try { Write-Host ('[log locked, not written] ' + $line) } catch {}
}
Log 'first'
Log 'second'
Write-Output 'SURVIVED'
'@
  $pf = Join-Path $env:TEMP ('logprobe-' + [guid]::NewGuid().ToString('N').Substring(0,6) + '.ps1')
  Set-Content $pf $probeScript -Encoding UTF8
  $out = (& powershell -NoProfile -ExecutionPolicy Bypass -File $pf $logProbe 2>&1 | ForEach-Object { [string]$_ }) -join ' '
  Remove-Item $pf -Force -ErrorAction SilentlyContinue
  if ($out -match 'SURVIVED') { Ok 'a locked log file does not kill the run (retry-then-continue Log pattern)' }
  else { Bad ('a locked log file still terminates the run: ' + $out) }
} finally { $fs.Close(); Remove-Item $logProbe -Force -ErrorAction SilentlyContinue }
# and assert every pipeline logger actually uses that pattern rather than a bare Add-Content
$bare = @()
foreach ($n in 'check-ad-cycles.ps1','run-daily-local.ps1','send-alert.ps1','bakers-daily-scan.ps1','weekly-post-capture.ps1') {
  $p = Join-Path $root $n
  if (-not (Test-Path $p)) { continue }
  $t = Get-Content $p -Raw
  $m = [regex]::Match($t, '(?ms)^function Log\(.*?^\}|^function Log\([^\r\n]*$')
  $body = if ($m.Success) { $m.Value } else { '' }
  if ($body -notmatch 'catch') { $bare += $n }
}
if ($bare.Count -eq 0) { Ok 'every pipeline logger retries instead of dying on a locked file' }
else { Bad ('these loggers still die on a locked log file: ' + ($bare -join ', ')) }

# ---- the golden regression guard itself (added 2026-07-29) --------------------------------------------
# It sat RED for weeks and nobody noticed, because it was not hermetic: the harness froze the DATA but let
# the engine read the LIVE commodities.json/price-bands.json, so every ordinary rule edit registered as
# "drift". On 2026-07-29 it reported 66 differences and not one was a code bug. Now that the rules are
# pinned it can only fail on a CODE change - which makes it safe to run daily, and makes red mean something.
# Three checks: the guard is green, its founding-bug fixture still exists, and the hermetic seal is intact.
$rt = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'regression-test.ps1') 2>&1 | ForEach-Object { [string]$_ }
if ($LASTEXITCODE -eq 0) { Ok 'golden regression guard is GREEN on the hermetic frozen inputs' }
else { Bad ('golden regression guard is RED - the engine changed a known-good number: ' + (($rt | Select-Object -Last 3) -join ' | ')) }

$cdSrc = Get-Content (Join-Path $root 'compare-deals.ps1') -Raw
if ($cdSrc -match 'must NOT divide') { Ok "the weight-package divisor's founding-bug fixture is still in -SelfTest" }
else { Bad 'the "(3 lb bag) in NAME must NOT divide" fixture has been removed from compare-deals -SelfTest - that is the bug the regression guard was written for ($0.33/lb onions), and without it a green run cannot be distinguished from a blind one' }

$rtSrc = Get-Content (Join-Path $root 'regression-test.ps1') -Raw
if ($rtSrc -match 'CommoditiesFile' -and $rtSrc -match 'BandsFile') { Ok 'regression harness still pins the RULES as well as the data (hermetic)' }
else { Bad 'regression-test.ps1 no longer passes -CommoditiesFile/-BandsFile from regression-inputs - the hermetic seal is broken and the guard will drift red on ordinary rule edits again, which is how it stopped being read the first time' }

Write-Output ''
# ---------------------------------------------------------------- N. the ZERO-ROWS rule must stay armed
# guards.ps1 guard 11 printed "ok ... (0 rows checked)" for five days after Baker's moved to the Kroger API and
# its row filter stopped matching anything. "No violations found" and "no rows examined" are the same zero, so
# the estate's cheapest anti-blindness rule is: a check that examined nothing must WARN. OkUnlessBlind enforces
# it. If that helper is deleted, loses its warn branch, or stops being CALLED, every converted guard silently
# reverts to passing on an empty examination - so this fixture is the watcher over the anti-blindness rule.
$gs = Get-Content (Join-Path $root 'guards.ps1') -Raw
if ($gs -match 'function OkUnlessBlind') { Ok 'guards.ps1 still defines OkUnlessBlind (the zero-rows rule)' }
else { Bad 'guards.ps1 LOST OkUnlessBlind - a guard that examines zero rows can print ok again (the guard-11 class)' }
# the helper must still WARN on empty, not just print a different ok
$mOub = [regex]::Match($gs, 'function OkUnlessBlind[\s\S]{0,2000}?\r?\n\}')
if ($mOub.Success -and $mOub.Value -match '\$checked -gt 0' -and $mOub.Value -match '\$warn\.Add') {
  Ok 'OkUnlessBlind still gates on the examined count and warns when it is zero'
} else { Bad 'OkUnlessBlind no longer warns on a zero examined count - the rule is present but toothless' }
# and it must still be WIRED to the guards that were converted. A helper nothing calls protects nothing.
# Count CALL sites only: a call passes its count as a variable ("OkUnlessBlind $mpSeen"), while the definition
# is "function OkUnlessBlind([int]$checked..." with no space before the paren. Matching on the space-then-$
# form excludes the definition without a fudge subtraction (the first version subtracted 1 for a definition
# that was never in the count, and reported 1 when there were 2).
$oubCalls = ([regex]::Matches($gs, 'OkUnlessBlind\s+\$')).Count
if ($oubCalls -ge 2) { Ok ("zero-rows rule is wired into $oubCalls guard(s)") }
else { Bad ("OkUnlessBlind is called by only $oubCalls guard(s) - the conversions were reverted") }
# guard 10 specifically. It is the ONLY check that compares what we PUBLISH to what the store CHARGES, and it
# was the last converted-era guard still printing its ok line with a bare Say - so it could announce
# "(0 rows verified)" as a pass. MUST-FIRE: this reads Bad against any guards.ps1 where that call is gone.
if ($gs -match 'OkUnlessBlind \$checked') { Ok 'guard 10 (the only what-we-publish-vs-what-the-store-charges check) cannot print ok on zero rows' }
else { Bad 'guard 10 prints its ok line with a bare Say again - it can announce "0 rows verified" as a pass, which is the guard-11 class' }
# BEHAVIOURAL fixture, not just a source grep: run the real helper both ways in an isolated scope.
$oubProof = & {
  $warn = New-Object System.Collections.ArrayList
  $Quiet = $true
  function Say($s) { }
  Invoke-Expression $mOub.Value
  OkUnlessBlind 5 'examined something' 'BLIND-5'
  $afterNonZero = $warn.Count
  OkUnlessBlind 0 'examined nothing' 'BLIND-0'
  [pscustomobject]@{ nonZero = $afterNonZero; zero = $warn.Count; msg = [string]$warn[0] }
}
if ($oubProof.nonZero -eq 0 -and $oubProof.zero -eq 1 -and $oubProof.msg -eq 'BLIND-0') {
  Ok 'zero-rows fixture: a non-zero count stays silent, a zero count raises exactly the blind warning'
} else { Bad ("zero-rows fixture FAILED: nonZero-warns=$($oubProof.nonZero) zero-warns=$($oubProof.zero) msg='$($oubProof.msg)'") }

# ---------------------------------------------------------------- Nb. guards must iterate the ENGINE's file set
# Item 9 (2026-07-30): compare-deals unions Walmart across 14 days; guards.ps1 answered "which files does the
# board price from?" with "newest per store", leaving 332 live Walmart cells outside guards 5 and 10 - the two
# gates written to stop a 2x pack price and a price the store is not charging. The fix put the answer in ONE
# shared function, and then reopened itself one day wide by re-deriving the AS-OF from the wall clock while the
# engine resolves it against $ads.today (measured 2026-07-30 08:19: walmart-regular-2026-07-15.json, 711 rows,
# was priced into comparison-2026-07-29 and skipped by both guards). compare-deals -SelfTest proves the
# BEHAVIOUR; what can still rot is the WIRING, so check that here, the same way the zero-rows rule is checked.
$gsFs = Get-Content (Join-Path $root 'guards.ps1') -Raw
if ($gsFs -match 'Select-EngineRegularFiles') { Ok 'guards.ps1 still resolves its file set through the shared engine definition' }
else { Bad 'guards.ps1 no longer calls Select-EngineRegularFiles - guards 5 and 10 are back to guarding a different file set than the board was priced from (item 9, and its one-day-wide reopening)' }
$mEfs = [regex]::Match($gsFs, 'function EngineFileSet[\s\S]{0,1500}?\r?\n\}')
if ($mEfs.Success -and $mEfs.Value -notmatch 'Select-RegularFileSet') { Ok 'EngineFileSet does not re-derive the file set or its as-of locally' }
else { Bad 'EngineFileSet builds its own file set again instead of calling the shared definition - that is exactly how the engine''s 14-day union and the guards'' window drifted apart in the first place' }

# ---------------------------------------------------------------- N+1. batch importers must read UTF-8
# The four batch importers used a bare Get-Content, which in PS 5.1 decodes a UTF-8 capture as Windows-1252
# and then SAVES the damage - the same bug that shipped 16 mangled board rows on 2026-07-29, 6 of them crowns.
# Source-grep that they are wired, then PROVE the decode end to end on a real UTF-8-no-BOM file, because a
# grep alone passes on an importer that dot-sources capture-lib and then ignores it.
# import-browser-batch.ps1 was ARCHIVED 2026-07-30 (0 surviving rows, 0 live board cells, 0 executable
# references - Baker's is 100% kroger-api now), so it is off this list; a file in archive\ is not a live
# importer and demanding it here would fail from the day it was archived. import-aldi-batch is now a SHIM
# that forwards to import-instacart-batch, so it holds no capture read of its own - the read it must be
# checked for lives in the file it forwards to, which is on this list in its own right.
foreach ($imp in @('import-walmart-batch.ps1','import-instacart-batch.ps1')) {
  $ip = Join-Path $root $imp
  if (-not (Test-Path $ip)) { Bad ("$imp is missing - it was a live staples-expansion importer"); continue }
  $it = Get-Content $ip -Raw
  if ($it -match "Get-Content \(Join-Path \`$root \`$Raw\) -Encoding UTF8" -and $it -match 'capture-lib') {
    Ok "$imp reads its capture as UTF-8 and repairs mojibake"
  } else { Bad "$imp reads its capture with the default (ANSI) encoding again - the next staples batch will ship mangled names" }
}
# Behavioural: a UTF-8-no-BOM line with an umlaut must survive the read the importers now perform.
$tmpU = Join-Path $env:TEMP ('utf8probe-' + [guid]::NewGuid().ToString('N') + '.txt')
try {
  $UML = [char]0x00FC   # u-umlaut, built from a code point so THIS file stays pure ASCII
  $want = 'eggs' + "`t" + 'Deutsche K' + $UML + 'che German Style Sauerkraut~~$3.49'
  [IO.File]::WriteAllText($tmpU, $want, (New-Object Text.UTF8Encoding($false)))   # no BOM, as a Blob download is
  $viaDefault = Get-Content $tmpU | Select-Object -First 1
  $viaUtf8    = Get-Content $tmpU -Encoding UTF8 | Select-Object -First 1
  if ($viaDefault -eq $want) {
    Ok 'utf8 fixture inconclusive on this box (ANSI read did not corrupt) - encoding assertion still enforced by the greps above'
  } elseif ($viaUtf8 -eq $want) {
    Ok 'utf8 fixture: the default read DOES corrupt an umlaut and the -Encoding UTF8 read the importers now use does not'
  } else { Bad 'utf8 fixture: -Encoding UTF8 did not round-trip an umlaut - the importer fix does not actually work here' }
} catch { Bad ('utf8 fixture threw: ' + $_.Exception.Message) }
finally { if (Test-Path $tmpU) { Remove-Item -LiteralPath $tmpU -Force -ErrorAction SilentlyContinue } }

# ---------------------------------------------------------------- N+2. allowlist-rot must cover ALL allowlists
# basis-reconcile-allowlist.json was omitted from guards' hygiene loop, and it is the one that suppresses
# FACTOR-level basis conflicts - the class that decides which store the board calls cheapest. It was therefore
# the only allowlist entries could age in forever with no expiry pressure at all.
$gtxt = Get-Content (Join-Path $root 'guards.ps1') -Raw
foreach ($al in @('multipack-allowlist.json','coverage-gap-allowlist.json','basis-reconcile-allowlist.json')) {
  if ($gtxt -match [regex]::Escape($al)) { Ok "allowlist-rot check still covers $al" }
  else { Bad "$al dropped out of guards' allowlist-rot loop - stale suppressions in it become invisible" }
}
# And every allowlist on disk must still expose a key the extractor recognises. A file that renamed its list
# would yield zero entries and the rot check would report a clean bill of health for a list it never opened.
foreach ($al in @('multipack-allowlist.json','coverage-gap-allowlist.json','basis-reconcile-allowlist.json')) {
  $ap = Join-Path $root $al
  if (-not (Test-Path $ap)) { continue }
  try {
    $ad = Get-Content $ap -Raw | ConvertFrom-Json
    if ($ad.PSObject.Properties['allow'] -or $ad.PSObject.Properties['gaps']) { Ok "$al still exposes a recognised entry list" }
    else { Bad "$al exposes neither .allow nor .gaps - guards' rot check is scanning ZERO entries from it" }
  } catch { Bad "$al does not parse: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------- N+2b. guard 6 must NAME the stores it skipped
# FOUNDING BUG (found 2026-07-30): guard 6 ("a store's data collapsed") opened with `if ($files.Count -lt 2)
# { continue }` - a SILENT skip - and then printed "ok  no store's newest data file collapsed vs its recent
# history". On the live tree that skipped exactly one store, sams, whose single out\regular capture
# (sams-regular-2026-07-14.json, 60 rows) is IN the engine's file set and is the only possible source of 29
# published Sam's cells, 9 of them crowned CHEAPEST. So the one store guard 6 could not evaluate was the one
# carrying unrefreshable prices, and its own ok line said so to nobody. Same zero-rows collapse as guard 11:
# "no collapse found" and "no store examined" read identically.
# The decision now lives in Get-CollapseVerdict so it can be exercised directly. Frozen synthetic inputs only.
if ($gtxt -match 'function Get-CollapseVerdict') { Ok 'guards.ps1 defines Get-CollapseVerdict (guard 6''s decision is testable)' }
else { Bad 'guards.ps1 LOST Get-CollapseVerdict - guard 6''s <2-capture skip is unfixtured again' }
if (([regex]::Matches($gtxt, 'Get-CollapseVerdict\s+\$')).Count -ge 2) { Ok 'Get-CollapseVerdict is wired into guard 6 for BOTH the skip and the collapse decision' }
else { Bad 'Get-CollapseVerdict is not called twice by guard 6 - the silent `continue` or the collapse test was inlined again' }
if ($gtxt -match 'g6NoHistory' -and $gtxt -match 'OkUnlessBlind \$g6Checked') { Ok 'guard 6 reports its examined count and names the stores it could not evaluate' }
else { Bad 'guard 6 no longer reports g6Checked / g6NoHistory - it can print ok again while skipping a store in silence' }
$mCv = [regex]::Match($gtxt, 'function Get-CollapseVerdict[\s\S]{0,4000}?\r?\n\}')
if (-not $mCv.Success) { Bad 'could not extract Get-CollapseVerdict from guards.ps1 - the behavioural fixture below cannot run' }
else {
  $cv = & {
    Invoke-Expression $mCv.Value
    [pscustomobject]@{
      # MUST-FIRE 1: the founding silent skip - one capture, no history (the live sams shape).
      noHistory = (Get-CollapseVerdict 1 0 0)
      # MUST-FIRE 2: the founding collapse - family-fare-regular-<date>.PARTIAL.json, 177 rows -> 55.
      collapsed = (Get-CollapseVerdict 5 55 177)
      # CLEAN TWIN 1: an ordinary healthy refresh must stay silent.
      healthy   = (Get-CollapseVerdict 5 170 177)
      # CLEAN TWIN 2: under the 100-row floor the ratio is noise - must NOT be called a collapse.
      belowFloor = (Get-CollapseVerdict 5 20 60)
    }
  }
  if ($cv.noHistory -eq 'no-history' -and $cv.collapsed -eq 'collapsed' -and $cv.healthy -eq 'ok' -and $cv.belowFloor -eq 'ok') {
    Ok 'guard-6 fixture: a single capture reports no-history (was a silent skip), a halved file collapses, a healthy file and a below-floor file stay silent'
  } else {
    Bad ("guard-6 fixture FAILED: noHistory='$($cv.noHistory)' collapsed='$($cv.collapsed)' healthy='$($cv.healthy)' belowFloor='$($cv.belowFloor)'")
  }
}

# ---------------------------------------------------------------- N+2c. guard 9 must not let an ALT FEED mask a live capture's age
# FOUNDING BUG (found 2026-07-30): guard 9 redirects a store's freshness to its alt feed when that feed is
# newer (the 2026-07-29 fix, so Sam's would stop being aged on out\regular). It overwrote $fileDate wholesale,
# on the stated belief that the out\regular file left behind is an unused orphan. It is not: Select-RegularFileSet
# hands the engine the NEWEST dated capture for every store in out\regular and sams has exactly ONE, so
# sams-regular-2026-07-14.json is in the engine's file set. Guard 9 therefore printed "Sam's Club ... file 1d
# old" for a 16-day-old price set, and its >14-day HARD FAIL could never reach those rows - no pull writes that
# file, so no successful run could ever age or refresh it.
# Measured on the 2026-07-29 AND 2026-07-30 boards alike: 29 published Sam's cells name a product that exists
# in that capture and nowhere in the 2,475-row live out\sams feed, and 9 of those commodities crown Sam's
# CHEAPEST - so the rows are load-bearing and the masked age was a real, published staleness.
if ($gtxt -match 'function Test-MaskedStaleCapture') { Ok 'guards.ps1 defines Test-MaskedStaleCapture (the masked-age rule)' }
else { Bad 'guards.ps1 LOST Test-MaskedStaleCapture - a live out\regular capture can be aged by its alt feed again' }
if ($gtxt -match 'Test-MaskedStaleCapture \$') { Ok 'the masked-age rule is CALLED from guard 9''s redirect branch' }
else { Bad 'Test-MaskedStaleCapture is defined but never called - the rule is present and toothless' }
$mMs = [regex]::Match($gtxt, 'function Test-MaskedStaleCapture[\s\S]{0,4000}?\r?\n\}')
if (-not $mMs.Success) { Bad 'could not extract Test-MaskedStaleCapture from guards.ps1 - the behavioural fixture below cannot run' }
else {
  $t0 = [datetime]'2026-07-30'
  $ms2 = & {
    Invoke-Expression $mMs.Value
    [pscustomobject]@{
      # MUST-FIRE: the founding case. A 2026-07-14 capture, still priced from, masked by a 2026-07-29 feed.
      founding = (Test-MaskedStaleCapture ([datetime]'2026-07-14') ([datetime]'2026-07-29') $t0 $true 14)
      # CLEAN TWIN 1: same dates, but the file is NOT in the engine's file set - a true orphan. Ageing it
      # would be crying wolf, and this is the twin that proves we do not.
      trueOrphan = (Test-MaskedStaleCapture ([datetime]'2026-07-14') ([datetime]'2026-07-29') $t0 $false 14)
      # CLEAN TWIN 2: the live Baker's/Fareway shape - regular and alt captured the same day, no redirect at
      # all, so the ordinary age test already covered it. Measured 2026-07-30: both stores look exactly so.
      noRedirect = (Test-MaskedStaleCapture ([datetime]'2026-07-29') ([datetime]'2026-07-29') $t0 $true 14)
      # CLEAN TWIN 3: redirected AND live, but inside the 14-day cliff - not stale, must stay silent.
      withinCliff = (Test-MaskedStaleCapture ([datetime]'2026-07-25') ([datetime]'2026-07-29') $t0 $true 14)
    }
  }
  if ($ms2.founding -and (-not $ms2.trueOrphan) -and (-not $ms2.noRedirect) -and (-not $ms2.withinCliff)) {
    Ok 'guard-9 masked-age fixture: a still-priced-from capture masked by a newer alt feed is aged, while a true orphan, an unredirected store and a within-cliff capture all stay silent'
  } else {
    Bad ("guard-9 masked-age fixture FAILED: founding=$($ms2.founding) trueOrphan=$($ms2.trueOrphan) noRedirect=$($ms2.noRedirect) withinCliff=$($ms2.withinCliff)")
  }
}

# ---------------------------------------------------------------- N+3. -Accept must respect DROP verdicts
# audit-match-soundness -Accept used to bless the current name->commodity map wholesale, converting "judged
# wrong last week" into "reviewed and correct" - which is how bacon/Sam's and broccoli/Sam's, each dropped by
# the verify pass in THREE separate weeks, got baselined and published as crowns on 2026-07-29.
$ms = Get-Content (Join-Path $root 'audit-match-soundness.ps1') -Raw
if ($ms -match 'ACCEPT REFUSED' -and $ms -match 'verify-verdicts-\*\.json') { Ok '-Accept still carries the DROP-verdict gate' }
else { Bad 'audit-match-soundness -Accept lost its DROP-verdict gate - it is a rubber stamp again' }
if ($ms -match '\$ForceAccept') { Ok 'the override is the explicit -ForceAccept switch, not silence' }
else { Bad '-ForceAccept is gone - either the gate cannot be overridden at all (people will edit it out) or it no longer exists' }
# Behavioural: the SHARED quote recovery must capture a full apostrophe-bearing product name. The pattern
# lives in verdict-lib.ps1 (shared by the -Accept gate AND verify-apply's suppressions - both must agree on
# what "the same item" means), so the fixture dot-sources the lib and calls the REAL function rather than a
# copy. A naive [^']+ capture truncates "Member's ..." at the possessive and fails SILENT - the gate
# under-blocks on exactly the Member's Mark rows the founding bug was about.
if (-not (Test-Path (Join-Path $root 'verdict-lib.ps1'))) { Bad 'verdict-lib.ps1 is missing - the -Accept gate and verify-apply have lost their shared item-identity definition' }
else {
  $probe = & {
    . (Join-Path $root 'verdict-lib.ps1')
    return (Get-VerdictQuotedItem "TEST: 'Member's Mark Pinto Beans 12 lbs.' is a 12-lb bag of DRY pinto beans.")
  }
  if ($probe -eq "Member's Mark Pinto Beans 12 lbs.") { Ok 'verdict-lib quote capture survives an apostrophe in the product name' }
  else { Bad ("verdict-lib quote capture truncates at the apostrophe again - captured '" + $probe + "'") }
  if ($ms -match 'verdict-lib\.ps1') { Ok 'the -Accept gate sources verdict-lib (one definition of item identity)' }
  else { Bad 'audit-match-soundness no longer sources verdict-lib - the gate and verify-apply can disagree on what "the same item" means' }
}

# ---------------------------------------------------------------- N+4. the Walmart batch importer's invariants
# 2026-07-25: import-walmart-batch.ps1 was a SECOND Walmart writer with its own weaker size math (backed the
# size out of the unit price and rounded to ONE decimal; no engine check, no multipack filter). 6 of the 23
# rows it put inside the 14-day union window failed the builder's engine-reproduces-the-unit-price invariant
# by 3.3-7.1%, and one was CROWNED cheapest on the 2026-07-29 board (brown-gravy-mix $0.5333/oz vs Walmart's
# real $0.552/oz). Its -SelfTest now carries the frozen founding-bug row (the shipped 0.9-oz shape MUST fail
# the engine tolerance), the 2026-07-27 fish-sauce override, and the guard-5 multipack lockstep. Prove the
# fixture still fires, and that the importer still LIFTS the builder's Build-Row instead of re-forking it.
$r = RunPS 'import-walmart-batch.ps1' @('-SelfTest')
if ($r.rc -eq 0 -and $r.text -match 'MUST-FIRE' -and $r.text -match 'SELF-TEST PASS') { Ok 'import-walmart-batch verifies every batch row through the builder invariants (founding-bug fixture fires)' }
else { Bad ('import-walmart-batch -SelfTest failed or lost its founding-bug fixture: ' + ((($r.text -split "`n") | Select-Object -Last 3) -join ' | ')) }
$iwSrc = Get-Content (Join-Path $root 'import-walmart-batch.ps1') -Raw
if ($iwSrc -match "'Resolve-Unit','Get-NameQtyCandidates','Get-NamePack','Format-Qty','Build-Row'") { Ok 'import-walmart-batch still lifts Build-Row from build-walmart-deals (one home, no fork)' }
else { Bad 'import-walmart-batch no longer lifts Build-Row - the second Walmart writer has re-forked the size math (the 2026-07-25 class)' }

# ---------------------------------------------------------------- N+5. delegated audits must say BLIND (exit 3), never a false OK
# Item 6 remainder (2026-07-30): every delegated/advisory audit used to print its OK line having examined
# NOTHING when its input was empty or schema-drifted - the zero-rows collapse, one script at a time
# (audit-price-mode printed "PRICE-MODE AUDIT OK" against an EMPTY out\regular; cell-drops printed the
# positive ok line against an empty baseline board; tile-integrity certified ACCURACY OK having graded zero
# links). Each now exits 3 = could-not-evaluate, which guards' delegate loop and advisory wrappers render as
# a WARN - never a block, never an ok. These fixtures freeze each script's founding blind shape (must-fire)
# next to a minimal clean twin, per the guard-fixture rule. Frozen/synthetic inputs only - never regenerated
# from the live board (the two live clean-twins below are deliberate: a machine where they fail is itself
# page-worthy).
function NewFxDir([string]$tag) {
  $d = Join-Path $env:TEMP ($tag + '-' + [guid]::NewGuid().ToString('N').Substring(0,8))
  New-Item -ItemType Directory -Force $d | Out-Null
  return $d
}
function RunPSAt([string]$dir, [string]$script, $argList) {
  $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dir $script) @argList 2>&1 | ForEach-Object { [string]$_ }
  return [pscustomobject]@{ rc = $LASTEXITCODE; text = ($out -join "`n") }
}

# (a) audit-price-mode: BLIND when no mode-sensitive store file reaches the strict check (the state that
# shipped 249 delivery-priced Aldi rows on 2026-07-14), and the anchored glob ignores a non-canonical twin.
$fxApm = NewFxDir 'apm-blind'
$r = RunPS 'audit-price-mode.ps1' @('-RegularDir', $fxApm)
if ($r.rc -eq 3 -and $r.text -match 'BLIND' -and $r.text -match 'Aldi, Fareway') { Ok 'price-mode goes BLIND (exit 3) when zero mode-sensitive files reach it' }
else { Bad ('price-mode did NOT go blind on an empty regular dir (rc=' + $r.rc + ') - "OK" from zero examination is back') }
$r = RunPS 'audit-price-mode.ps1' @()
if ($r.rc -eq 0 -and $r.text -match 'PRICE-MODE AUDIT OK') { Ok 'price-mode clean twin: live out\regular still passes with the counted OK line' }
else { Bad ('price-mode clean twin failed (rc=' + $r.rc + ') - either live data is broken (page-worthy) or the edit broke the healthy path') }
$fxApmT = NewFxDir 'apm-twin'
Set-Content (Join-Path $fxApmT 'aldi-regular-2026-01-01.json') '{"store":"Aldi","price_mode":"in-store","mode_verified":"2026-01-01","items":[]}' -Encoding UTF8
Set-Content (Join-Path $fxApmT 'fareway-regular-2026-01-01.json') '{"store":"Fareway","price_mode":"in-store","mode_verified":"2026-01-01","items":[]}' -Encoding UTF8
Set-Content (Join-Path $fxApmT 'aldi-regular-2026-01-02.PARTIAL.json') '{"items":[]}' -Encoding UTF8
$r = RunPS 'audit-price-mode.ps1' @('-RegularDir', $fxApmT)
if ($r.rc -eq 0 -and $r.text -match 'OK\s+Aldi: in-store') { Ok 'price-mode anchored glob: a .PARTIAL twin cannot shadow the real capture (rc 0 AND the Aldi OK line present)' }
else { Bad ('price-mode read the non-canonical twin or went blind past it (rc=' + $r.rc + ') - the family-fare PARTIAL incident class') }
Remove-Item $fxApm, $fxApmT -Recurse -Force -ErrorAction SilentlyContinue

# (b) audit-walmart-fullpull: BLIND when a union store has ZERO captures in its window (used to exit 0 and
# guards printed "  ok    fullpull [Walmart]: no captures...").
$fxWfp = NewFxDir 'wfp-blind'
New-Item -ItemType Directory -Force (Join-Path $fxWfp 'out\regular') | Out-Null
New-Item -ItemType Directory -Force (Join-Path $fxWfp 'out\sams') | Out-Null
$r = RunPS 'audit-walmart-fullpull.ps1' @('-GroceryRoot', $fxWfp)
if ($r.rc -eq 3 -and $r.text -match '\[Walmart\]: BLIND' -and $r.text -match "\[Sam's Club\]: BLIND") { Ok 'walmart-fullpull goes BLIND (exit 3) per store on an empty capture window' }
else { Bad ('walmart-fullpull did NOT go blind on empty windows (rc=' + $r.rc + ')') }
$fxD   = [datetime]::Today.ToString('yyyy-MM-dd')
$fxD11 = [datetime]::Today.AddDays(-11).ToString('yyyy-MM-dd')
# The clean twin needs a BOARD as well as captures: since 2026-07-30 this auditor also runs a per-CELL
# expiry watch, and a tree with no comparison-*.json is a tree where that watch can prove nothing - which
# it must say out loud (exit 1), never swallow. So the healthy fixture is captures AND a board whose every
# cell comes from today's capture.
function _WfpSeed([string]$dir, [string]$wmToday, [string]$wmOld, [string]$cmpRows) {
  Set-Content (Join-Path $dir ('out\regular\walmart-regular-' + $fxD + '.json')) ('{"pull_terms":400,"deals":[' + $wmToday + ']}') -Encoding UTF8
  if ($wmOld) { Set-Content (Join-Path $dir ('out\regular\walmart-regular-' + $fxD11 + '.json')) ('{"pull_terms":400,"deals":[' + $wmOld + ']}') -Encoding UTF8 }
  Set-Content (Join-Path $dir ('out\sams\sams-deals-' + $fxD + '.json')) '{"pull_terms":300,"deals":[{"item":"Sams Row","ad_price":"$5.00"}]}' -Encoding UTF8
  Set-Content (Join-Path $dir ('out\comparison-' + $fxD + '.json')) ('{"comparison":[' + $cmpRows + ']}') -Encoding UTF8
}
$fxSams  = '{"id":"sams-thing","cheapest_store":"Sam''s Club","stores":[{"store":"Sam''s Club","item":"Sams Row","ad":"$5.00"}]}'
$fxFresh = '{"id":"fresh-thing","cheapest_store":"Walmart","stores":[{"store":"Walmart","item":"Fresh Row","ad":"$9.99"}]}'
$fxOld   = '{"id":"old-thing","cheapest_store":"Walmart","stores":[{"store":"Walmart","item":"Old Row","ad":"$1.00"}]}'
_WfpSeed $fxWfp '{"item":"Fresh Row","ad_price":"$9.99"},{"item":"Old Row","ad_price":"$1.00"}' '{"item":"Old Row","ad_price":"$1.00"}' ($fxFresh + ',' + $fxOld + ',' + $fxSams)
$r = RunPS 'audit-walmart-fullpull.ps1' @('-GroceryRoot', $fxWfp)
if ($r.rc -eq 0 -and ([regex]::Matches($r.text, 'ok - newest comprehensive capture')).Count -eq 2 -and ([regex]::Matches($r.text, 'cells: ok')).Count -eq 2) { Ok 'walmart-fullpull clean twin: fresh comprehensive captures AND a board whose cells all come from them read ok for both stores' }
else { Bad ('walmart-fullpull clean twin failed (rc=' + $r.rc + '): ' + $r.text) }
Remove-Item $fxWfp -Recurse -Force -ErrorAction SilentlyContinue

# (b2) MUST FIRE - the 2026-07-30 bug this watch was written for. Watch 1 said "ok - newest comprehensive
# capture ... is 0 day(s) old" while 207 of 432 live Walmart cells (47.9%, 58 CROWNS) hung off
# walmart-regular-2026-07-18.json, 2 days from leaving the union. Frozen small, same shape: a fresh
# comprehensive capture that does NOT carry Old Row, and an 11-day-old capture that is its only source.
# The assertion names the CELLS line and requires watch 1 to still read ok, so it cannot pass on watch 1.
$fxCell = NewFxDir 'wfp-cellexpiry'
New-Item -ItemType Directory -Force (Join-Path $fxCell 'out\regular') | Out-Null
New-Item -ItemType Directory -Force (Join-Path $fxCell 'out\sams') | Out-Null
_WfpSeed $fxCell '{"item":"Fresh Row","ad_price":"$9.99"}' '{"item":"Old Row","ad_price":"$1.00"}' ($fxFresh + ',' + $fxOld + ',' + $fxSams)
$r = RunPS 'audit-walmart-fullpull.ps1' @('-GroceryRoot', $fxCell)
if ($r.rc -eq 1 -and $r.text -match '\[Walmart\] cells: WARNING - 1 of 2' -and $r.text -match 'CROWNS' -and $r.text -match 'ok - newest comprehensive capture walmart') { Ok 'walmart-fullpull FIRES on a board cell whose only source is about to leave the union window, while watch 1 still reads ok' }
else { Bad ('walmart-fullpull cell-expiry watch MISSED its founding bug (rc=' + $r.rc + '): ' + $r.text) }
Remove-Item $fxCell -Recurse -Force -ErrorAction SilentlyContinue

# (b3) CLEAN TWIN for the percent floor. A few trailing cells are normal (a product out of stock, a term
# that returned nothing that morning) - Sam's carried 11 of them on 2026-07-29 with nothing wrong. One
# aging cell in 40 (2.5%) must stay SILENT, or the watch becomes a permanent alarm and gets ignored.
$fxPct = NewFxDir 'wfp-cellpct'
New-Item -ItemType Directory -Force (Join-Path $fxPct 'out\regular') | Out-Null
New-Item -ItemType Directory -Force (Join-Path $fxPct 'out\sams') | Out-Null
$pFresh = @(); $pCmp = @()
foreach ($i in 1..39) { $pFresh += ('{"item":"Row ' + $i + '","ad_price":"$' + $i + '.00"}'); $pCmp += ('{"id":"c' + $i + '","cheapest_store":"Walmart","stores":[{"store":"Walmart","item":"Row ' + $i + '","ad":"$' + $i + '.00"}]}') }
_WfpSeed $fxPct ($pFresh -join ',') '{"item":"Old Row","ad_price":"$1.00"}' (($pCmp -join ',') + ',' + $fxOld + ',' + $fxSams)
$r = RunPS 'audit-walmart-fullpull.ps1' @('-GroceryRoot', $fxPct)
if ($r.rc -eq 0 -and $r.text -match '\[Walmart\] cells: ok - 1 of 40') { Ok 'walmart-fullpull cell watch stays SILENT at 1 aging cell in 40 (2.5%, under the 5% floor) - the trailing-cell noise floor' }
else { Bad ('walmart-fullpull cell watch cried wolf on the 2.5% noise floor (rc=' + $r.rc + '): ' + $r.text) }
Remove-Item $fxPct -Recurse -Force -ErrorAction SilentlyContinue

# (c) audit-household-in-food: BLIND at zero rows scanned (an existing-but-empty out\regular used to print
# "scanned 0 rows" + AUDIT OK + exit 0). Copy-to-temp because the script has no dir param.
$fxHif = NewFxDir 'hif-blind'
foreach ($cf in @('audit-household-in-food.ps1','compare-deals.ps1','commodities.json','categories.json')) { Copy-Item (Join-Path $root $cf) (Join-Path $fxHif $cf) }
New-Item -ItemType Directory -Force (Join-Path $fxHif 'out\regular') | Out-Null
$r = RunPSAt $fxHif 'audit-household-in-food.ps1' @()
if ($r.rc -eq 3 -and $r.text -match 'BLIND') { Ok 'household-in-food goes BLIND (exit 3) at zero rows scanned' }
else { Bad ('household-in-food did NOT go blind on an empty out\regular (rc=' + $r.rc + ')') }
Set-Content (Join-Path $fxHif 'out\regular\hyvee-regular-2026-01-01.json') '{"store":"Hy-Vee","deals":[{"item":"Bananas"}]}' -Encoding UTF8
$r = RunPSAt $fxHif 'audit-household-in-food.ps1' @()
if ($r.rc -eq 0 -and $r.text -match 'scanned 1 rows' -and $r.text -match 'AUDIT OK') { Ok 'household-in-food clean twin: one seeded row scans and passes' }
else { Bad ('household-in-food clean twin failed (rc=' + $r.rc + ')') }
Remove-Item $fxHif -Recurse -Force -ErrorAction SilentlyContinue

# (d) audit-food-category: BLIND at zero priced cells (an empty -OutDir used to print "ok - ... (0 priced
# cells scanned)" with exit 0 - reproduced by execution before the fix).
$fxAfc = NewFxDir 'afc-blind'
$r = RunPS 'audit-food-category.ps1' @('-OutDir', $fxAfc)
if ($r.rc -eq 3 -and $r.text -match 'FOOD-CLASS AUDIT BLIND') { Ok 'food-category goes BLIND (exit 3) at zero priced cells' }
else { Bad ('food-category did NOT go blind on an empty OutDir (rc=' + $r.rc + ')') }
$r = RunPS 'audit-food-category.ps1' @()
if ($r.rc -eq 0 -and $r.text -match 'priced cells scanned') { Ok 'food-category clean twin: the live board still scans and passes' }
else { Bad ('food-category clean twin failed (rc=' + $r.rc + ') - either live data is broken (page-worthy) or the edit broke the healthy path') }
Remove-Item $fxAfc -Recurse -Force -ErrorAction SilentlyContinue

# (d2) MUST-FIRE for the 2026-07-30 additions to category-excludes.json: the snack_carrier class and the
# beverage class's mini-cans / lemon-lime tokens. Both are founding bugs, measured live on that day's board:
# lemons was priced from "Lulu Platanitios Lemon Plantain Chips" (a snack) and limes from "Starry Mini Cans
# Lemon Lime" (a soda). Neither name carries a token the old library knew, so the blocking guard passed them.
# The rows are frozen literals here, NOT read from the board - regenerate them from live data and the bug
# they encode disappears, which is the whole [[guard-fixture-rule]] failure mode.
$fxSnk = NewFxDir 'afc-snack'
$snackRow = '{"week_of":"2026-07-29","comparison":[{"commodity":"Lemons","id":"lemons","unit":"each","stores":[{"store":"Sam''s Club","per_unit":0.5413,"item":"Lulu Platanitios Lemon Plantain Chips, 2.5 oz., 30 pk."}]},{"commodity":"Limes","id":"limes","unit":"each","stores":[{"store":"Sam''s Club","per_unit":0.5327,"item":"Starry Mini Cans Lemon Lime, 7.5 fl. oz., 30 pk."}]}]}'
Set-Content (Join-Path $fxSnk 'comparison-2026-07-29.json') $snackRow -Encoding UTF8
$r = RunPS 'audit-food-category.ps1' @('-OutDir', $fxSnk)
if ($r.rc -eq 2 -and $r.text -match 'snack_carrier' -and $r.text -match 'beverage') {
  Ok 'food-category MUST-FIRE: a snack on lemons and a soda on limes both hard-fail (exit 2)'
} else {
  Bad ('food-category did NOT catch the plantain-chips/mini-cans rows (rc=' + $r.rc + ') - the snack_carrier class or the beverage mini-cans/lemon-lime tokens are gone from category-excludes.json')
}
# CLEAN TWIN: the same two commodities priced from real produce must stay silent, or the new tokens are
# eating legitimate cells (a guard that fails on correct data gets switched off, which is worse than no guard).
$cleanRow = '{"week_of":"2026-07-29","comparison":[{"commodity":"Lemons","id":"lemons","unit":"each","stores":[{"store":"Walmart","per_unit":0.5,"item":"Fresh Lemon"}]},{"commodity":"Limes","id":"limes","unit":"each","stores":[{"store":"Walmart","per_unit":0.25,"item":"Fresh Lime"}]}]}'
Set-Content (Join-Path $fxSnk 'comparison-2026-07-29.json') $cleanRow -Encoding UTF8
$r = RunPS 'audit-food-category.ps1' @('-OutDir', $fxSnk)
if ($r.rc -eq 0) { Ok 'food-category clean twin: fresh lemon/lime rows stay silent under the new classes' }
else { Bad ('food-category flagged REAL produce (rc=' + $r.rc + ') - a new token is too broad: ' + ($r.text -replace "`n", ' ')) }
Remove-Item $fxSnk -Recurse -Force -ErrorAction SilentlyContinue

# (e) audit-tile-integrity: ACCURACY BLIND + exit 3 when zero links were graded (an empty product-urls used
# to certify "ACCURACY OK - every link that ships..." having examined nothing; prune-bad-links can empty the
# set on a live daily path, which is exactly when the certificate would lie).
$fxTi = NewFxDir 'ti-blind'
foreach ($cf in @('audit-tile-integrity.ps1','pu-lib.ps1')) { Copy-Item (Join-Path $root $cf) (Join-Path $fxTi $cf) }
New-Item -ItemType Directory -Force (Join-Path $fxTi 'out') | Out-Null
Set-Content (Join-Path $fxTi 'product-urls.json') '{"items":{}}' -Encoding UTF8
Set-Content (Join-Path $fxTi 'out\comparison-2026-01-01.json') '{"comparison":[{"id":"test-oats","unit":"oz","stores":[{"store":"Hy-Vee","per_unit":0.10,"type":"everyday","item":"Test Oats 16 oz"}]}]}' -Encoding UTF8
$r = RunPSAt $fxTi 'audit-tile-integrity.ps1' @('-OutDir', (Join-Path $fxTi 'out'))
if ($r.rc -eq 3 -and $r.text -match 'ACCURACY BLIND') { Ok 'tile-integrity goes ACCURACY BLIND (exit 3) when zero links were graded' }
else { Bad ('tile-integrity did NOT go blind with an empty product-urls (rc=' + $r.rc + ') - the empty accuracy certificate is back') }
Set-Content (Join-Path $fxTi 'product-urls.json') '{"items":{"test-oats":{"Hy-Vee":{"url":"https://example.test/oats","price":"$1.60","size":"16 oz","name":"Test Oats 16 oz"}}}}' -Encoding UTF8
$r = RunPSAt $fxTi 'audit-tile-integrity.ps1' @('-OutDir', (Join-Path $fxTi 'out'))
if ($r.rc -eq 0 -and $r.text -match 'ACCURACY OK - all 1 price-graded links') { Ok 'tile-integrity clean twin: one matching link grades and the OK line carries the count' }
else { Bad ('tile-integrity clean twin failed (rc=' + $r.rc + ')') }
# the -Baseline and -Strict paths must honor the same BLIND contract (post-batch review 2026-07-30: both
# exited 0 on the blind state, and a blind -Baseline wrote every priced tile as the coverage high-water
# mark - permanently disarming the ratchet with exit 0, during exactly the incident where someone would
# reach for -Baseline). Must-fire: blind + -Baseline refuses (rc 3, NO baseline file); blind + -Strict rc 3.
Set-Content (Join-Path $fxTi 'product-urls.json') '{"items":{}}' -Encoding UTF8
Remove-Item (Join-Path $fxTi 'out\tile-integrity-baseline.json') -Force -ErrorAction SilentlyContinue
$r = RunPSAt $fxTi 'audit-tile-integrity.ps1' @('-OutDir', (Join-Path $fxTi 'out'), '-Baseline')
if ($r.rc -eq 3 -and $r.text -match 'Baseline REFUSED' -and -not (Test-Path (Join-Path $fxTi 'out\tile-integrity-baseline.json'))) { Ok 'tile-integrity -Baseline REFUSES a blind run (rc 3, poisoned baseline never written)' }
else { Bad ('tile-integrity -Baseline accepted a BLIND run (rc=' + $r.rc + ', baseline written: ' + (Test-Path (Join-Path $fxTi 'out\tile-integrity-baseline.json')) + ') - the coverage ratchet can be silently disarmed') }
# -Strict's blind shape is the EMPTY board (zero tiles): a NO-LINK tile is a real strict violation and
# must stay exit 2, but zero-of-anything satisfies "every priced tile has a link" vacuously - that is the
# shape that must read BLIND, not achieved.
Set-Content (Join-Path $fxTi 'out\comparison-2026-01-01.json') '{"comparison":[]}' -Encoding UTF8
$r = RunPSAt $fxTi 'audit-tile-integrity.ps1' @('-OutDir', (Join-Path $fxTi 'out'), '-Strict')
if ($r.rc -eq 3) { Ok 'tile-integrity -Strict reports BLIND (rc 3) on an empty board instead of a vacuous every-tile-linked pass' }
else { Bad ('tile-integrity -Strict returned rc=' + $r.rc + ' on a blind run - the end-state claim is vacuously satisfiable again') }
Remove-Item $fxTi -Recurse -Force -ErrorAction SilentlyContinue

# (f) audit-cell-drops: BLIND on both silent paths - fewer than 2 dated boards, and a baseline board that
# parses to zero everyday cells (which used to print the POSITIVE "no everyday cell lost" ok line).
$fxCd = NewFxDir 'cd-blind'
Copy-Item (Join-Path $root 'audit-cell-drops.ps1') (Join-Path $fxCd 'audit-cell-drops.ps1')
New-Item -ItemType Directory -Force (Join-Path $fxCd 'out') | Out-Null
Set-Content (Join-Path $fxCd 'out\comparison-2026-01-08.json') '{"comparison":[{"id":"eggs","stores":[{"store":"Hy-Vee","type":"everyday","per_unit":2.50}]}]}' -Encoding UTF8
$r = RunPSAt $fxCd 'audit-cell-drops.ps1' @()
if ($r.rc -eq 3 -and $r.text -match 'BLIND - only 1 dated board') { Ok 'cell-drops goes BLIND (exit 3) with a single dated board' }
else { Bad ('cell-drops did NOT go blind with one board (rc=' + $r.rc + ')') }
Set-Content (Join-Path $fxCd 'out\comparison-2026-01-01.json') '{"comparison":[]}' -Encoding UTF8
$r = RunPSAt $fxCd 'audit-cell-drops.ps1' @()
if ($r.rc -eq 3 -and $r.text -match 'compared ZERO everyday cells') { Ok 'cell-drops goes BLIND (exit 3) on an empty-comparison baseline (the false positive-ok shape)' }
else { Bad ('cell-drops printed a verdict against an EMPTY baseline board (rc=' + $r.rc + ')') }
Set-Content (Join-Path $fxCd 'out\comparison-2026-01-01.json') '{"comparison":[{"id":"eggs","stores":[{"store":"Hy-Vee","type":"everyday","per_unit":2.50}]}]}' -Encoding UTF8
$r = RunPSAt $fxCd 'audit-cell-drops.ps1' @()
if ($r.rc -eq 0 -and $r.text -match '\(1 cells compared\)') { Ok 'cell-drops clean twin: kept cell reads ok with the examined count' }
else { Bad ('cell-drops clean twin failed (rc=' + $r.rc + ')') }
Set-Content (Join-Path $fxCd 'out\comparison-2026-01-08.json') '{"comparison":[]}' -Encoding UTF8
$r = RunPSAt $fxCd 'audit-cell-drops.ps1' @()
if ($r.rc -eq 1) { Ok 'cell-drops still detects a real drop (exit 1) - the founding Fareway-chicken shape' }
else { Bad ('cell-drops lost its drop detection (rc=' + $r.rc + ')') }
Remove-Item $fxCd -Recurse -Force -ErrorAction SilentlyContinue

# (g) audit-name-drift: BLIND at zero cells tested; three consumers read its count=0 JSON as a positive
# clean result, so a blind write must at least page.
$fxNd = NewFxDir 'nd-blind'
Copy-Item (Join-Path $root 'audit-name-drift.ps1') (Join-Path $fxNd 'audit-name-drift.ps1')
New-Item -ItemType Directory -Force (Join-Path $fxNd 'out') | Out-Null
Set-Content (Join-Path $fxNd 'product-urls.json') '{"items":{}}' -Encoding UTF8
Set-Content (Join-Path $fxNd 'out\comparison-2026-01-01.json') '{"comparison":[{"id":"eggs","stores":[{"store":"Hy-Vee","item":"Grade A Eggs 12 ct"}]}]}' -Encoding UTF8
$r = RunPSAt $fxNd 'audit-name-drift.ps1' @()
$ndJson = try { Get-Content (Join-Path $fxNd 'out\name-drift.json') -Raw | ConvertFrom-Json } catch { $null }
if ($r.rc -eq 3 -and $r.text -match 'BLIND' -and $ndJson -and [int]$ndJson.examined -eq 0) { Ok 'name-drift goes BLIND (exit 3) at zero cells and its JSON carries examined=0' }
else { Bad ('name-drift did NOT go blind with an empty product-urls (rc=' + $r.rc + ')') }
Set-Content (Join-Path $fxNd 'product-urls.json') '{"items":{"eggs":{"Hy-Vee":{"url":"https://example.test/eggs","price":"$2.50","size":"12 ct","name":"Grade A Eggs 12 ct"}}}}' -Encoding UTF8
$r = RunPSAt $fxNd 'audit-name-drift.ps1' @()
$ndJson = try { Get-Content (Join-Path $fxNd 'out\name-drift.json') -Raw | ConvertFrom-Json } catch { $null }
if ($r.rc -eq 0 -and $r.text -match '0 of 1 cells tested' -and $ndJson -and [int]$ndJson.examined -eq 1) { Ok 'name-drift clean twin: one matching link is examined and reported' }
else { Bad ('name-drift clean twin failed (rc=' + $r.rc + ')') }
Remove-Item $fxNd -Recurse -Force -ErrorAction SilentlyContinue

# (g2) audit-name-drift MUST be able to see a RECIPE-BOARD cell. Founding bug (2026-07-30): it read
# out\comparison-*.json only, so guards.ps1 guard 3's WRONG-PRODUCT clause - which looks a pin up in
# name-drift.json by id|store - could not fire for ANY pin, because all 16 pins in board-price-overrides.json
# are recipe-board-only ids. MUST-FIRE: a wrong-product link on a recipe-only id is flagged AND its id|store
# lands in examined_cells (the key guard 3 reads). CLEAN TWIN: the same fixture with a matching link name stays
# silent while the cell is still IN scope - the union must add coverage, not noise. Third assertion: an id on
# BOTH boards is scanned ONCE (the staple row wins), because the two boards carry different unit bases and one
# link cannot be judged against both. Frozen synthetic data - never regenerated from the live board.
$fxNdU = NewFxDir 'nd-union'
Copy-Item (Join-Path $root 'audit-name-drift.ps1') (Join-Path $fxNdU 'audit-name-drift.ps1')
New-Item -ItemType Directory -Force (Join-Path $fxNdU 'out') | Out-Null
Set-Content (Join-Path $fxNdU 'out\comparison-2026-01-01.json') '{"comparison":[{"id":"eggs","unit":"dozen","stores":[{"store":"Hy-Vee","per_unit":2.50,"type":"everyday","item":"Grade A Eggs 12 ct"}]},{"id":"shared-oats","unit":"oz","stores":[{"store":"Hy-Vee","per_unit":0.10,"type":"everyday","item":"Quaker Oats 42 oz"}]}]}' -Encoding UTF8
Set-Content (Join-Path $fxNdU 'out\recipe-board.json') '{"comparison":[{"id":"pinned-paprika","unit":"oz","stores":[{"store":"Hy-Vee","per_unit":0.99,"type":"everyday","item":"Simply Organic Smoked Paprika 2.72 oz"}]},{"id":"shared-oats","unit":"oz","stores":[{"store":"Hy-Vee","per_unit":0.10,"type":"everyday","item":"Bobs Redmill Steelcut Groats 24 oz"}]}]}' -Encoding UTF8
$ndUPu = '{"items":{"eggs":{"Hy-Vee":{"url":"https://example.test/eggs","price":"$2.50","size":"12 ct","name":"Grade A Eggs 12 ct"}},"shared-oats":{"Hy-Vee":{"url":"https://example.test/oats","price":"$4.20","size":"42 oz","name":"Quaker Oats 42 oz"}},"pinned-paprika":{"Hy-Vee":{"url":"https://example.test/p","price":"$2.69","size":"2.72 oz","name":"{LINK}"}}}}'
Set-Content (Join-Path $fxNdU 'product-urls.json') ($ndUPu -replace '\{LINK\}','Badia Garlic Powder') -Encoding UTF8
$r = RunPSAt $fxNdU 'audit-name-drift.ps1' @()
$ndU = try { Get-Content (Join-Path $fxNdU 'out\name-drift.json') -Raw | ConvertFrom-Json } catch { $null }
$ndUCells = @($ndU.examined_cells)
if ($r.rc -eq 0 -and $ndU -and [int]$ndU.count -eq 1 -and @($ndU.flags)[0].id -eq 'pinned-paprika' -and ($ndUCells -contains 'pinned-paprika|Hy-Vee')) {
  Ok 'name-drift MUST-FIRE: a wrong-product link on a RECIPE-board-only id is flagged and recorded in examined_cells (guard 3 can arm)'
} else {
  Bad ('name-drift did NOT flag the recipe-board-only wrong product (rc=' + $r.rc + ', count=' + [int]$ndU.count + ', examined_cells lists pinned-paprika: ' + ($ndUCells -contains 'pinned-paprika|Hy-Vee') + ') - guard 3''s WRONG-PRODUCT clause is unfirable again')
}
if (@($ndUCells | Where-Object { $_ -eq 'shared-oats|Hy-Vee' }).Count -eq 1) { Ok 'name-drift scans a two-board id ONCE (staple row wins; the recipe row''s different unit basis is not re-judged against the same link)' }
else { Bad ('name-drift recorded ' + @($ndUCells | Where-Object { $_ -eq 'shared-oats|Hy-Vee' }).Count + ' scans of the colliding id (expected 1) - either examined_cells is missing entirely, or one link is being judged against two different unit bases') }
Set-Content (Join-Path $fxNdU 'product-urls.json') ($ndUPu -replace '\{LINK\}','Simply Organic Smoked Paprika 2.72 oz') -Encoding UTF8
$r = RunPSAt $fxNdU 'audit-name-drift.ps1' @()
$ndU = try { Get-Content (Join-Path $fxNdU 'out\name-drift.json') -Raw | ConvertFrom-Json } catch { $null }
if ($r.rc -eq 0 -and $ndU -and [int]$ndU.count -eq 0 -and (@($ndU.examined_cells) -contains 'pinned-paprika|Hy-Vee')) {
  Ok 'name-drift CLEAN TWIN: the recipe cell is in scope and a matching link stays unflagged (the union adds coverage, not noise)'
} else {
  Bad ('name-drift clean twin failed (rc=' + $r.rc + ', count=' + [int]$ndU.count + ') - the union is manufacturing flags')
}
Remove-Item $fxNdU -Recurse -Force -ErrorAction SilentlyContinue

# (h) audit-links: BLIND when zero of the stored links matched a board id/store (a schema break in either
# input used to print "audited N links: 0 price-match, 0 MISMATCH, 0 uncomputable" - flag-free JSON included).
$fxAl = NewFxDir 'al-blind'
Copy-Item (Join-Path $root 'audit-links.ps1') (Join-Path $fxAl 'audit-links.ps1')
New-Item -ItemType Directory -Force (Join-Path $fxAl 'out') | Out-Null
Set-Content (Join-Path $fxAl 'out\comparison-2026-01-01.json') '{"comparison":[{"id":"eggs","unit":"dozen","stores":[{"store":"Hy-Vee","per_unit":2.50}]}]}' -Encoding UTF8
Set-Content (Join-Path $fxAl 'product-urls.json') '{"items":{"zzz-not-on-board":{"Hy-Vee":{"url":"https://example.test/z","price":"$5.00","size":"dozen","name":"Z"}}}}' -Encoding UTF8
$r = RunPSAt $fxAl 'audit-links.ps1' @()
if ($r.rc -eq 3 -and $r.text -match 'examined ZERO of 1 links') { Ok 'audit-links goes BLIND (exit 3) when no link matches the board' }
else { Bad ('audit-links did NOT go blind with zero matchable links (rc=' + $r.rc + ')') }
Set-Content (Join-Path $fxAl 'product-urls.json') '{"items":{"eggs":{"Hy-Vee":{"url":"https://example.test/eggs","price":"$2.50","size":"dozen","name":"Eggs"}}}}' -Encoding UTF8
$r = RunPSAt $fxAl 'audit-links.ps1' @()
if ($r.rc -eq 0 -and $r.text -match 'audited 1 of 1 links') { Ok 'audit-links clean twin: one computable link audits with the honest of-total summary' }
else { Bad ('audit-links clean twin failed (rc=' + $r.rc + ')') }
Remove-Item $fxAl -Recurse -Force -ErrorAction SilentlyContinue

# (i) audit-coverage-gaps: BLIND only at TOTAL blindness (zero raw products for EVERY store); a partial
# blind day is reported per-store in the JSON + qualified line but keeps exit 0/2 (a real finding must win).
$fxCg = NewFxDir 'cg-blind'
$fxCgBoard = Join-Path $fxCg 'fix-board.json'
Set-Content $fxCgBoard '{"comparison":[{"id":"bananas","stores":[]}]}' -Encoding UTF8
$r = RunPS 'audit-coverage-gaps.ps1' @('-OutDir', $fxCg, '-CompareFile', $fxCgBoard)
$cgJson = try { Get-Content (Join-Path $fxCg 'coverage-gaps.json') -Raw | ConvertFrom-Json } catch { $null }
if ($r.rc -eq 3 -and $r.text -match 'BLIND - ZERO raw products' -and $cgJson -and @($cgJson.stores_not_scanned).Count -eq 7) { Ok 'coverage-gaps goes BLIND (exit 3) at total blindness and names all 7 unscanned stores in its JSON' }
else { Bad ('coverage-gaps did NOT go blind with zero raw products (rc=' + $r.rc + ')') }
Set-Content (Join-Path $fxCg 'ads-2026-01-01.json') '{"deals":[{"store":"Hy-Vee","item":"zzzz"},{"store":"Aldi","item":"zzzz"},{"store":"Family Fare","item":"zzzz"},{"store":"Fareway","item":"zzzz"},{"store":"Baker''s","item":"zzzz"},{"store":"Sam''s Club","item":"zzzz"},{"store":"Walmart","item":"zzzz"}]}' -Encoding UTF8
$r = RunPS 'audit-coverage-gaps.ps1' @('-OutDir', $fxCg, '-CompareFile', $fxCgBoard)
if ($r.rc -eq 0 -and $r.text -match 'coverage-gaps: none - every store') { Ok 'coverage-gaps clean twin: all 7 stores seeded reads the plain none line' }
else { Bad ('coverage-gaps clean twin failed (rc=' + $r.rc + ')') }
Remove-Item $fxCg -Recurse -Force -ErrorAction SilentlyContinue

# (j) guards' advisory wrappers: a child exiting non-0/non-1 must land in WARN, never in the ok Say line
# (the bare else used to relabel any unrecognised exit - including the new exit 3 - as "  ok"). The chain
# below is a copy of the post-edit wrapper shape; the source asserts pin guards.ps1 to it.
$fxGw = NewFxDir 'gw-child'
Set-Content (Join-Path $fxGw 'exit5.ps1') 'exit 5' -Encoding UTF8
Set-Content (Join-Path $fxGw 'exit0.ps1') 'Write-Output "fine"; exit 0' -Encoding UTF8
$fxGwWarn = New-Object System.Collections.ArrayList
$fxGwOk = New-Object System.Collections.ArrayList
foreach ($fxChild in @('exit5.ps1','exit0.ps1')) {
  try {
    $null = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $fxGw $fxChild) 2>$null
    if ($LASTEXITCODE -eq 0) { [void]$fxGwOk.Add($fxChild) }
    elseif ($LASTEXITCODE -eq 3) { [void]$fxGwWarn.Add($fxChild + ':blind') }
    else { [void]$fxGwWarn.Add($fxChild) }
  } catch { [void]$fxGwWarn.Add($fxChild + ':catch') }
}
if ($fxGwWarn -contains 'exit5.ps1' -and $fxGwOk -notcontains 'exit5.ps1' -and $fxGwOk -contains 'exit0.ps1' -and $fxGwWarn.Count -eq 1) { Ok 'wrapper chain: exit 5 lands in warn (not ok), exit 0 lands in ok' }
else { Bad ('wrapper chain misroutes exit codes: warn=[' + ($fxGwWarn -join ',') + '] ok=[' + ($fxGwOk -join ',') + ']') }
Remove-Item $fxGw -Recurse -Force -ErrorAction SilentlyContinue
$gSrc = Get-Content (Join-Path $root 'guards.ps1') -Raw
if (([regex]::Matches($gSrc, 'elseif \(\$LASTEXITCODE -eq 3\)')).Count -ge 2 -and $gSrc -match 'is MISSING - the allowlist-rot check scanned ZERO entries') { Ok 'guards.ps1 keeps both advisory-wrapper exit-3 branches and the missing-allowlist warn' }
else { Bad 'guards.ps1 lost an advisory-wrapper exit-3 branch or the missing-allowlist warn - a blind child prints ok again' }

# (k) the direct callers keep their blind branches (source asserts - house precedent for caller plumbing;
# the behavioral exit-3s are covered by the producer fixtures above).
$cacSrc = Get-Content (Join-Path $root 'check-ad-cycles.ps1') -Raw
if ($cacSrc -match 'walmart-fullpull BLIND' -and $cacSrc -match 'name-drift BLIND' -and $cacSrc -match 'coverage-gaps BLIND for' -and $cacSrc -match 'tile-integrity BLIND' -and $cacSrc -match 'match-soundness BLIND') { Ok 'check-ad-cycles keeps all five audit blind branches' }
else { Bad 'check-ad-cycles lost an audit blind branch - a blind audit logs as routine again' }
if ($cacSrc -match 'Not an early warning') { Ok 'check-ad-cycles blind email does not reuse the nothing-is-broken-yet body' }
else { Bad 'check-ad-cycles blind email body regressed - a blackout would email "nothing is broken yet"' }
# the weekly test-guards capture must NOT redirect the child's stderr: under this script's EAP=Stop, a
# 2>&1 on a native child turns its first stderr line into a terminating throw that skips the exit-code
# read, the stamp, and the alert - the suite-crash case is exactly what the alert exists for, and the
# missed stamp re-opened the gate into a silent daily 658 MB crash loop (post-batch review 2026-07-30).
if ($cacSrc -match "run-test-guards-weekly\.ps1'\)\s*2>&1") { Bad 'check-ad-cycles captures run-test-guards-weekly with 2>&1 under EAP=Stop again - a crashing suite throws past the stamp and alert into a silent daily retry loop' }
else { Ok 'check-ad-cycles weekly test-guards capture leaves stderr unredirected (crash still reaches the alert path)' }
# (k1e) THE DRIFT SCANNER COULD NOT READ THE LANGUAGE IT SCANS (2026-07-30). audit-store-registry hunts
# hardcoded store lists in live .ps1 source. It recognised a store name written plainly, as &#39; and as
# &rsquo; - but NOT as '', which is how an apostrophe is actually written inside a single-quoted PowerShell
# string. test-auditors seeds all 7 stores onto one fixture line with Baker''s and Sam''s Club escaped, so
# the guard reported "names 5 store(s) but is missing Baker's, Sam's Club" against a line naming every one.
# Permanently red on correct code, which is how a drift guard gets ignored. The variant list is read out of
# the real file and EXERCISED below, so this tracks behaviour rather than a spelling.
$asrSrc = Get-Content (Join-Path $root 'audit-store-registry.ps1') -Raw
$asrM = [regex]::Match($asrSrc, '\$variants\s*=\s*@\((.+?)\)\r?\n')
if (-not $asrM.Success) { Bad 'audit-store-registry: cannot find its $variants list to check' }
else {
  $asrNames = @("Hy-Vee","Aldi","Family Fare","Fareway","Baker's","Sam's Club","Walmart")
  function Test-RegistryScan([string]$variantExpr, [string]$code) {
    $hit = 0; $missing = @()
    foreach ($n in $asrNames) {
      $variants = & ([scriptblock]::Create('$n = $args[0]; ' + $variantExpr)) $n
      $found = $false; foreach ($v in @($variants)) { if ($code.IndexOf([string]$v, [StringComparison]::Ordinal) -ge 0) { $found = $true; break } }
      if ($found) { $hit++ } else { $missing += $n }
    }
    return @{ hit = $hit; missing = $missing; flags = ($hit -ge 3 -and $missing.Count -gt 0) }
  }
  $asrExpr = '@(' + $asrM.Groups[1].Value + ')'
  $asrQ = [char]39
  $asrSeven = "'" + (($asrNames | ForEach-Object { $_ -replace "'", ($asrQ + $asrQ) }) -join ',') + "'"
  $asrFive  = "'" + ((@("Hy-Vee","Aldi","Family Fare","Fareway","Walmart")) -join ',') + "'"
  $asrClean = Test-RegistryScan $asrExpr $asrSeven
  $asrFire  = Test-RegistryScan $asrExpr $asrFive
  if (-not $asrClean.flags) { Ok "store-registry scan reads PowerShell '' escaping - a line naming all 7 stores is not reported as drift" }
  else { Bad ('store-registry scan is red on a line that names every store (missing: ' + ($asrClean.missing -join ', ') + ") - it cannot read '' escaping") }
  if ($asrFire.flags) { Ok 'store-registry scan still FIRES on a genuine 5-store hardcoded list (not blinded by the escaping fix)' }
  else { Bad 'store-registry scan no longer flags a real 5-store list - the escaping fix blinded it' }
}
# (k1f) A CONSISTENCY GUARD THAT COULD SCORE PERFECT FROM AN EMPTY REGEX (2026-07-30). Every audit-board-
# consistency finding comes from one regex over rendered chip markup, and nothing checked the regex matched
# anything: a missing feed or a one-attribute markup drift would print "no-link=0", exit 0, and be logged by
# check-ad-cycles as "consistency OK" - the blindest state wearing the healthiest label. 3,164 chips are
# examined on a healthy run, so the new exit-3 branch is 3,164 away from arming.
$abcSrc = Get-Content (Join-Path $root 'audit-board-consistency.ps1') -Raw
if ($abcSrc -match 'chips_examined\s*=\s*\$chipsSeen') { Ok 'board-consistency records chips_examined in its report' }
else { Bad 'board-consistency no longer records chips_examined - a blind run is indistinguishable from a clean one' }
if ($abcSrc -match '(?s)if\s*\(\s*\$chipsSeen\s*-eq\s*0\s*\)\s*\{[^}]*exit 3') { Ok 'board-consistency exits 3 (could-not-evaluate) when it examined zero chips' }
else { Bad 'board-consistency no longer exits 3 from zero chips - "no-link=0 out of 0" would read as a pass' }
if ($cacSrc -match 'consistency BLIND') { Ok 'check-ad-cycles has the matching exit-3 branch (a blind run is not logged as OK)' }
else { Bad 'check-ad-cycles lost its consistency exit-3 branch - an exit 3 falls into the else and is logged "consistency OK"' }
# (k1d) AN AUDIT THAT DIED ON ITS OWN FIRST FINDING (2026-07-30). audit-everyday-mismatch built each bug
# record with price=[double]$e.price. 579 of the 2,987 stored link prices are strings like "$1.88", [double]
# on one of those throws, and it threw INSIDE the record for the first mismatch found - under EAP=Stop, so the
# audit reported nothing whenever it had anything to report. Clean board: silent. Board with bugs: silent. The
# price was already parsed safely two lines earlier into $sp. With the fix it checks 2,427 everyday cells and
# finds 43 real mismatches (brand-swapped links inside the 0.32 factor tolerance, which name-drift's token test
# passes because board and link share the commodity word). Deliberately NOT wired into any gate: 43 findings on
# a green board is a backlog to work, not a daily warn.
$aemSrc = Get-Content (Join-Path $root 'audit-everyday-mismatch.ps1') -Raw
$aemThrows = $false
try { $null = [double]'$1.88' } catch { $aemThrows = $true }
if ($aemThrows) { Ok 'PS still throws casting a "$1.88" price string to [double] - the founding hazard is real' }
else { Bad 'a "$1.88" string now casts cleanly to [double]; re-derive this fixture' }
if ($aemSrc -match 'price\s*=\s*\[double\]\$e\.price') { Bad 'audit-everyday-mismatch casts the raw link price again - it will die on the first mismatch it finds and report nothing' }
else { Ok 'audit-everyday-mismatch records the already-parsed price (it can survive its own findings)' }
if ($aemSrc -notmatch 'price\s*=\s*\$sp;') { Bad 'audit-everyday-mismatch no longer records $sp - check it is not re-parsing the raw string somewhere else' }
else { Ok 'audit-everyday-mismatch reuses $sp, the price it already parsed safely' }
# BOTH BOARDS (2026-08-01). It read only comparison-*.json, so every RECIPE-board cell was outside the one
# check that asks "does the price we publish match the product the link opens" - measured that day, all 80
# recipe-board rows are absent from the main board and all 80 carry a link, and turning it on surfaced 95
# mismatches that had never been visible. This fixture RUNS the audit against a synthetic OutDir where the
# ONLY mismatch lives on the recipe board, so a regression that quietly drops the second board fails here
# instead of going quiet on 315 real cells.
$aemFx = Join-Path ([System.IO.Path]::GetTempPath()) ('aem-fx-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $aemFx | Out-Null
'{"comparison":[{"id":"clean-thing","commodity":"Clean","unit":"oz","stores":[{"store":"Walmart","per_unit":0.10,"type":"everyday","item":"Clean Thing"}]}]}' | Set-Content (Join-Path $aemFx 'comparison-2026-01-01.json') -Encoding UTF8
'{"comparison":[{"id":"recipe-only-thing","commodity":"RecipeOnly","unit":"oz","stores":[{"store":"Walmart","per_unit":0.10,"type":"everyday"}]}]}' | Set-Content (Join-Path $aemFx 'recipe-board.json') -Encoding UTF8
'{"items":{"clean-thing":{"Walmart":{"url":"u","price":"$1.00","size":"10 oz","name":"Clean Thing"}},"recipe-only-thing":{"Walmart":{"url":"u","price":"$9.00","size":"10 oz","name":"Recipe Only Thing"}}}}' | Set-Content (Join-Path $aemFx 'product-urls.json') -Encoding UTF8
$aemR = RunPS 'audit-everyday-mismatch.ps1' @('-OutDir', $aemFx)
if ($aemR.text -match 'recipe-only-thing') { Ok 'audit-everyday-mismatch still reads the RECIPE board (a recipe-only mismatch is found)' }
else { Bad 'audit-everyday-mismatch did NOT find the recipe-board-only mismatch - the second board has been dropped and 315 live cells are unaudited again' }
if ($aemR.text -match 'recipe=') { Ok 'audit-everyday-mismatch still reports its per-board checked counts' }
else { Bad 'audit-everyday-mismatch stopped reporting per-board counts - a silently empty second board would look identical to a healthy one' }
Remove-Item $aemFx -Recurse -Force -ErrorAction SilentlyContinue
# (k1a) A GUARD THAT CANNOT FINISH, AND A CALLER THAT CANNOT NOTICE (2026-07-30). audit-ff-carry.ps1 wrapped a
# System.Collections.Generic.List[object] in @( ) to build its report - which throws "ArgumentException:
# Argument types do not match" in Windows PowerShell 5.1 (it is fine around a List[string], and fine around the
# bare list, which is why it reads as harmless). It threw on EVERY run since the script was wired into
# check-ad-cycles on 2026-07-13, AFTER all 464 Freshop probes and BEFORE the report, the OK line and the -Alert
# branch. Nobody saw it because the caller piped the child straight into Log, so a child that dies before its
# first Write-Output logs nothing: 'ff-carry' appears 0 times in 2,716 lines of ad-cycle-log.txt. Two failures,
# two checks - the crash itself, and the caller's inability to see a crash. The @( ) case is executed for real
# against a live List[object], not pattern-matched, so it tracks the language rather than the spelling.
$ffcSrc = Get-Content (Join-Path $root 'audit-ff-carry.ps1') -Raw
$ffcList = New-Object System.Collections.Generic.List[object]
$ffcList.Add([pscustomobject]@{ term = 't' })
$ffcThrows = $false
try { $null = @($ffcList) } catch { $ffcThrows = $true }
if ($ffcThrows) { Ok 'PS 5.1 still throws on @(List[object]) - the founding hazard is real, not a historical quirk' }
else { Bad 'PS 5.1 no longer throws on @(List[object]) - this fixture no longer proves anything; re-derive it' }
if ($ffcSrc -match 'confirmed_victims\s*=\s*@\(\$victims\)') { Bad 'audit-ff-carry wraps its List[object] in @( ) again - it will throw after all 464 probes and log nothing' }
else { Ok 'audit-ff-carry builds its report without @(List[object]) (it can reach its own report line)' }
if ($ffcSrc -notmatch 'confirmed_victims\s*=\s*\$victims\.ToArray\(\)') { Bad 'audit-ff-carry no longer uses .ToArray() - check the JSON shape stays [] at zero and [ {..} ] at one' }
else { Ok 'audit-ff-carry serialises its victims with .ToArray() (array shape holds at 0, 1 and many)' }
# The CALLER must capture and check, not pipe-and-hope. Decision extracted from the real region.
function Test-FfCarryCallerSees([string]$src) {
  $i = $src.IndexOf('$fcArgs')
  if ($i -lt 0) { return @('no ff-carry invocation found') }
  $seg = $src.Substring($i, [Math]::Min(1400, $src.Length - $i))
  $bad = New-Object System.Collections.Generic.List[string]
  if ($seg -match '&\s*powershell\s*@fcArgs\s*\|') { $bad.Add('ff-carry is piped straight into Log - a crash before first output logs nothing') }
  if ($seg -notmatch 'LASTEXITCODE') { $bad.Add('ff-carry exit code is never read') }
  if ($seg -match '@fcArgs\s*2>&1') { $bad.Add('ff-carry child is captured with 2>&1 under EAP=Stop - first stderr line throws past the check') }
  return $bad
}
$ffcReal = Test-FfCarryCallerSees $cacSrc
if ($ffcReal.Count -eq 0) { Ok 'check-ad-cycles captures ff-carry, logs its output, and reads its exit code' }
else { Bad ('ff-carry caller is blind again: ' + ($ffcReal -join '; ')) }
$ffcFire = Test-FfCarryCallerSees '$fcArgs = @(1); & powershell @fcArgs | ForEach-Object { Log $_ }'
if ($ffcFire.Count -ge 2) { Ok 'ff-carry-caller fixture fires on the pipe-and-hope form that hid the crash for 17 days' }
else { Bad 'ff-carry-caller fixture went blind - piping with no exit-code check now reads as correct' }
$ffcClean = Test-FfCarryCallerSees '$fcArgs = @(1); $o = & powershell @fcArgs; $rc = $LASTEXITCODE; foreach($l in @($o)){ Log $l }'
if ($ffcClean.Count -eq 0) { Ok 'ff-carry-caller fixture stays silent on capture-then-check (clean twin)' }
else { Bad ('ff-carry-caller fixture false-positives on correct form: ' + ($ffcClean -join '; ')) }
# (k1c) A HEAL MUST REFRESH THE GATE'S IDENTITY INPUT (2026-07-30). In check-ad-cycles' consistency
# auto-repair, prune-bad-links + sync-browser-links rewrite the links, then generate-board-overrides and
# guards' tile-integrity WRONG-PRODUCT gate both read name-drift.json - which still described the PRE-heal
# links. Every link the heal had just corrected therefore still read as wrong: five Walmart cells whose healed
# link matched the board byte-for-byte held the hard gate red, and re-running audit-name-drift cleared it to
# ACCURACY 0 with no other change. Ordering is read out of the real source (positional), not asserted as a
# phrase, and the fixture below deletes the refresh to prove the check can still see its own bug.
function Test-RepairRefreshesDrift([string]$src) {
  $bad = New-Object System.Collections.Generic.List[string]
  $iSync = $src.IndexOf('sync-browser-links.ps1')
  if ($iSync -lt 0) { $bad.Add('no sync-browser-links call found'); return $bad }
  $iDrift = $src.IndexOf('audit-name-drift.ps1', $iSync)
  $iPins  = $src.IndexOf('generate-board-overrides.ps1', $iSync)
  $iGuard = $src.IndexOf('guards.ps1', $iSync)
  if ($iDrift -lt 0) { $bad.Add('no audit-name-drift after sync-browser-links - the gate grades healed links on stale identity data') ; return $bad }
  if ($iPins -ge 0 -and $iDrift -gt $iPins) { $bad.Add('name-drift refresh runs AFTER generate-board-overrides - pins are minted against stale drift flags') }
  if ($iGuard -ge 0 -and $iDrift -gt $iGuard) { $bad.Add('name-drift refresh runs AFTER guards - the hard gate reads pre-heal identity') }
  return $bad
}
$cacRepair = $cacSrc.Substring([Math]::Max(0, $cacSrc.IndexOf('consistency BREACH')))
$rrReal = Test-RepairRefreshesDrift $cacRepair
if ($rrReal.Count -eq 0) { Ok 'consistency auto-repair refreshes name-drift after the heal, before pins and guards' }
else { Bad ('consistency auto-repair identity ordering broken: ' + ($rrReal -join '; ')) }
# MUST-FIRE: strip the refresh exactly as it was before the fix, and the check has to go red.
$rrFire = Test-RepairRefreshesDrift ($cacRepair -replace [regex]::Escape("'audit-name-drift.ps1'"), "'audit-links.ps1'")
if ($rrFire.Count -ge 1) { Ok 'repair-refresh fixture fires when the name-drift refresh is removed (the 2026-07-30 bug)' }
else { Bad 'repair-refresh fixture went blind - a repair path with no identity refresh now reads as correct' }
# CLEAN TWIN: correct ordering must stay silent.
$rrClean = Test-RepairRefreshesDrift "sync-browser-links.ps1 ... audit-name-drift.ps1 ... generate-board-overrides.ps1 ... guards.ps1"
if ($rrClean.Count -eq 0) { Ok 'repair-refresh fixture stays silent on correct ordering (clean twin)' }
else { Bad ('repair-refresh fixture false-positives on correct ordering: ' + ($rrClean -join '; ')) }
# (k1b) THE PRUNE DEFAULT MUST MATCH THE CALL SITES (2026-07-30). prune-bad-links defaulted to -Tol 0.02 while
# every automated caller passed 0.32, and audit-tile-integrity's failure text told a HUMAN to "run
# prune-bad-links.ps1" with no arguments. Following the printed instruction therefore ran the 2% rule and
# deleted every RIGHT-product link whose stored price snapshot had drifted a few cents: measured on the live
# board that day, 53 links dropped at 0.02 versus 10 at 0.32 - 43 correct links destroyed by doing exactly what
# the tool said. A default that no caller uses is only ever reached by a human following advice, so it is the
# one that has to be safe. Decision extracted from the real files, and exercised below against a synthetic
# 0.02 source so the check cannot pass while blind.
function Test-PruneTolContract([string]$pruneSrc, [string]$tileSrc) {
  $bad = New-Object System.Collections.Generic.List[string]
  $m = [regex]::Match($pruneSrc, '(?m)^param\(\s*\[double\]\$Tol\s*=\s*([0-9.]+)')
  if (-not $m.Success) { $bad.Add('prune-bad-links has no readable [double]$Tol default') }
  elseif ([double]$m.Groups[1].Value -ne 0.32) { $bad.Add('prune-bad-links default Tol is ' + $m.Groups[1].Value + ', not 0.32 - a human running it bare deletes right-product links') }
  if ($tileSrc -match 'Run prune-bad-links\.ps1 to drop them') { $bad.Add('audit-tile-integrity still tells a human to run prune-bad-links with no tolerance') }
  if ($tileSrc -notmatch 'prune-bad-links\.ps1 -Tol 0\.32') { $bad.Add('audit-tile-integrity failure advice does not name -Tol 0.32') }
  return $bad
}
$pruneSrc = Get-Content (Join-Path $root 'prune-bad-links.ps1') -Raw
$tileSrc  = Get-Content (Join-Path $root 'audit-tile-integrity.ps1') -Raw
$ptReal = Test-PruneTolContract $pruneSrc $tileSrc
if ($ptReal.Count -eq 0) { Ok 'prune-bad-links defaults to the 0.32 factor rule and tile-integrity advises it explicitly' }
else { Bad ('prune tolerance contract broken: ' + ($ptReal -join '; ')) }
# MUST-FIRE: the founding bug (0.02 default + bare advice) has to come back red, or this check is decoration.
$ptFire = Test-PruneTolContract "param([double]`$Tol = 0.02, [switch]`$WhatIf)" "  Run prune-bad-links.ps1 to drop them - that is always available"
if ($ptFire.Count -ge 2) { Ok 'prune-tolerance fixture fires on the 2026-07-30 founding bug (0.02 default + untolerance advice)' }
else { Bad 'prune-tolerance fixture went blind - the 0.02 default and bare advice no longer register as faults' }
# CLEAN TWIN: correct source must stay silent, so the check cannot be a constant red.
$ptClean = Test-PruneTolContract "param([double]`$Tol = 0.32, [switch]`$WhatIf)" "  Run  prune-bad-links.ps1 -Tol 0.32  to drop them"
if ($ptClean.Count -eq 0) { Ok 'prune-tolerance fixture stays silent on a correct source (clean twin)' }
else { Bad ('prune-tolerance fixture false-positives on correct source: ' + ($ptClean -join '; ')) }
$wpcSrc = Get-Content (Join-Path $root 'weekly-post-capture.ps1') -Raw
if ($wpcSrc -match 'tiPost -eq 3' -and $wpcSrc -match 'was BLIND on the live board' -and $wpcSrc -match 'prune-bad-links -Tol 0\.32 and re-run -Phase links NOW') { Ok 'weekly-post-capture separates BLIND from FAILED (prune advice stays on the real failure only)' }
else { Bad 'weekly-post-capture lost the blind/FAILED split - a blind post-publish check would advise pruning harder' }
# (k2) THE PHASE WIRING (2026-07-30). audit-coverage-gaps + audit-sale-fallback ran in -Phase compare ONLY, so
# the weekly run graded coverage on a comparison the daily job then rewrote before -Phase publish shipped it:
# on 2026-07-29 gap_count=0 was written at 09:10, out\regular\aldi-regular-2026-07-29.json was rebuilt at 12:24,
# the comparison was rewritten at 12:29, and the 12:58 publish went out having lost the Aldi bread cell. They
# must run in BOTH phases (compare feeds the agent's regex widenings, publish grades the board that ships) and
# the publish call must name the file explicitly, or it silently follows whatever newest-comparison the audit's
# own default picks - which is the race that started this. Not a source grep for a hard-coded phrase: the
# checker below reads the phase branches out of the real file, and is exercised against a source with the
# publish-phase calls deleted, so it cannot pass while blind.
function Test-WpcPhaseAudits([string]$src) {
  $bad = New-Object System.Collections.Generic.List[string]
  foreach ($pair in @(@('compare','publish'), @('publish','links'))) {
    $m = [regex]::Match($src, "(?s)\n    '" + $pair[0] + "' \{\r?\n(?<b>.*?)\r?\n    '" + $pair[1] + "' \{")
    if (-not $m.Success) { $bad.Add('cannot locate the -Phase ' + $pair[0] + ' branch'); continue }
    $body = $m.Groups['b'].Value
    foreach ($a in @('audit-coverage-gaps.ps1','audit-sale-fallback.ps1')) {
      if ($body -notmatch [regex]::Escape($a)) { $bad.Add($a + ' is not invoked in -Phase ' + $pair[0]) }
      elseif ($pair[0] -eq 'publish' -and $body -notmatch ([regex]::Escape($a) + "'\)\s*@\('-CompareFile'")) { $bad.Add($a + ' runs in -Phase publish without an explicit -CompareFile') }
    }
  }
  return $bad
}
# CLEAN TWIN: the live file must have nothing to report.
$wpcLive = @(Test-WpcPhaseAudits $wpcSrc)
if ($wpcLive.Count -eq 0) { Ok 'weekly-post-capture runs coverage-gaps + sale-fallback in BOTH -Phase compare and -Phase publish, pinned to an explicit -CompareFile' }
else { Bad ('weekly-post-capture phase wiring broken - the publish phase would ship an unaudited board: ' + ($wpcLive -join '; ')) }
# MUST FIRE: the 2026-07-29 shape, built by deleting the publish branch body from the live source. Injected by
# construction rather than sampled, so it encodes the bug permanently; if the checker ever stops looking, this
# case goes quiet and FAILS instead of passing.
$wpcBrokeM = [regex]::Match($wpcSrc, "(?s)\n    'publish' \{\r?\n(?<b>.*?)\r?\n    'links' \{")
$wpcBroke = if ($wpcBrokeM.Success) { $wpcSrc.Remove($wpcBrokeM.Groups['b'].Index, $wpcBrokeM.Groups['b'].Length).Insert($wpcBrokeM.Groups['b'].Index, '      # publish-phase audits deleted (fixture)') } else { '' }
$wpcFired = @(Test-WpcPhaseAudits $wpcBroke)
if ($wpcFired.Count -eq 2 -and @($wpcFired | Where-Object { $_ -eq 'audit-coverage-gaps.ps1 is not invoked in -Phase publish' }).Count -eq 1 -and @($wpcFired | Where-Object { $_ -eq 'audit-sale-fallback.ps1 is not invoked in -Phase publish' }).Count -eq 1) { Ok 'phase-wiring check FIRES on a source with the publish-phase audits stripped, and blames only the publish phase' }
else { Bad ('phase-wiring check did NOT fire correctly on the stripped-publish fixture: [' + ($wpcFired -join '; ') + ']') }
$pdpSrc = Get-Content (Join-Path $root 'publish-deals-page.ps1') -Raw
if ($pdpSrc -match 'price-mode: BLIND' -and $pdpSrc -match 'name-drift: BLIND' -and $pdpSrc -match 'match-soundness: BLIND') { Ok 'publish-deals-page surfaces exit 3 from all three of its direct audit calls' }
else { Bad 'publish-deals-page lost a blind surface line - a blind audit falls through silently during publish' }

# ---------------------------------------------------------------- N+6. the verdict-driven record-low purge
# 2026-07-30: purge-bad-lows.ps1 is a RATIO test (>=2x under the next-lowest week) and structurally cannot
# reach a wrong-product low. Two reasons, both measured: the pork-loin filet crowning bacon was 1.02x under,
# and because prices carry forward daily the "next-lowest week" is usually the SAME bad number, making the
# ratio exactly 1.00 (grits held $0.0023/oz for 7 rows against a real $0.0449). That left 219 history entries
# set by 27 products a verdict had already rejected - 12 owning a record low, and 8 tiles printing "Usually
# cheaper - lowest we have tracked $X" on the live page from a hot dog bun, a breakfast cereal, an applesauce.
# purge-verdict-lows.ps1 removes by EVIDENCE. Three of its fixtures decide whether it is safe at all and must
# stay in the file: the quote-fragment match (lose it and bacon/broccoli survive again, which is exactly how
# they survived the last purge), the price-exact name lookup (lose it and a real Member's Mark bacon price
# is deleted as a filet, because history and that day's comparison file disagree on the number), and the
# human-overturn rule (lose it and it deletes history for a product a later keep verdict re-reviewed and KEPT,
# which is chocolate-milk/Walmart today). The two wiring checks below exist because a green self-test cannot
# tell you the tool is still being CALLED.
$r = RunPS 'purge-verdict-lows.ps1' @('-SelfTest')
if ($r.rc -eq 0 -and $r.text -match 'MUST-FIRE' -and $r.text -match 'SELF-TEST PASS') { Ok 'purge-verdict-lows -SelfTest passes with its founding-bug fixtures armed' }
else { Bad ('purge-verdict-lows -SelfTest failed or lost its founding-bug fixtures: ' + ((($r.text -split "`n") | Select-Object -Last 3) -join ' | ')) }
$pvlSrc = Get-Content (Join-Path $root 'purge-verdict-lows.ps1') -Raw
if ($pvlSrc -match '1\.02x under the next row') { Ok 'the 1.02x bacon shape (invisible to any ratio purge) is still the must-fire fixture' }
else { Bad 'purge-verdict-lows lost the 1.02x founding-bug fixture - a ratio-invisible wrong-product low would pass again' }
if ($pvlSrc -match 'board-rebuilt-same-day drift') { Ok 'the price-exact name lookup still has its clean twin (a week-only match deletes real prices)' }
else { Bad 'purge-verdict-lows lost the price-drift clean twin - it can label a history row with a product that was never at that price' }
if ($pvlSrc -match 'verdict-lib\.ps1') { Ok 'purge-verdict-lows sources verdict-lib (one definition of item identity)' }
else { Bad 'purge-verdict-lows no longer sources verdict-lib - the purge and verify-apply can disagree on what "the same item" means' }

# --- merge-product-urls consume-once (added 2026-08-01) ---------------------------------------------
# Founding bug: the merge re-consumed EVERY store-*-urls.json on every run and never removed them, so an
# already-merged capture REPLAYED over links that had since been corrected (~226 links on 07-14; 36 Fareway
# links on 08-01). An age filter alone would not have caught the second one - that file was a day old. The
# defense is consume-once ARCHIVING, so the must-fire fixture is "a consumed input is gone afterwards".
$r = RunPS 'merge-product-urls.ps1' @('-SelfTest')
if ($r.rc -eq 0 -and $r.text -match 'SELFTEST: 6/6 pass') { Ok 'merge-product-urls -SelfTest passes (fresh merged, stale refused, consumed archived, size verbatim)' }
else { Bad ('merge-product-urls -SelfTest failed or lost its founding-bug fixtures: ' + ((($r.text -split "`n") | Select-Object -Last 3) -join ' | ')) }
$mpuSrc = Get-Content (Join-Path $root 'merge-product-urls.ps1') -Raw
if ($mpuSrc -match 'replay bug is live again') { Ok 'the consume-once must-fire fixture (a merged input must be archived) is still armed' }
else { Bad 'merge-product-urls lost the consume-once fixture - a stale capture could silently replay over corrected links again' }
if ($mpuSrc -match 'url-inputs-archive') { Ok 'merge-product-urls still archives consumed inputs' }
else { Bad 'merge-product-urls no longer archives consumed inputs - every past capture will replay on the next run' }
if ($mpuSrc -match "size field corrupted") { Ok 'the size-field clean twin is armed (a URL-only diff cannot see a basis overwrite)' }
else { Bad 'merge-product-urls lost the size-verbatim fixture - a replay could flip "100 ct" to "each" with the URL unchanged and every URL diff would call it clean' }

# --- discover-hyvee (added 2026-08-01, F1) -----------------------------------------------------------
# Hy-Vee's puller is a REFRESH with no discovery path: 89.3% of the catalogue is absent and a product not
# already in the file can never enter. This gives it one. Its founding risk is what it CHOOSES to surface,
# because the whole point is products that BEAT what we hold - exactly the ones that can take a crown.
# Hy-Vee's own "baking soda" search returns cat litter, and cat litter WAS holding a live baking-soda
# crown on 2026-08-01, so the must-fire fixture is that class.
$dhR = RunPS 'discover-hyvee.ps1' @('-SelfTest')
if ($dhR.rc -eq 0 -and $dhR.text -match 'SELFTEST: 7/7 pass') { Ok 'discover-hyvee -SelfTest passes (cat litter and toothpaste refused, real cheaper kept, marginal suppressed)' }
else { Bad ('discover-hyvee -SelfTest failed or lost its founding-bug fixtures: ' + ((($dhR.text -split "`n") | Select-Object -Last 3) -join ' | ')) }
$dhSrc = Get-Content (Join-Path $root 'discover-hyvee.ps1') -Raw
if ($dhSrc -match 'Cat Litter with Baking Soda') { Ok 'the cat-litter-as-baking-soda must-fire fixture is still armed' }
else { Bad 'discover-hyvee lost the cat-litter fixture - that is the exact product class this gate exists to keep off a docket' }
if ($dhSrc -match 'SILENTLY IGNORED') { Ok 'discover-hyvee still records that the Hy-Vee CATEGORY facet cannot filter (measured, not assumed)' }
else { Bad 'discover-hyvee lost the note that the CATEGORY searchFilter is silently ignored - someone will build a safety gate on a filter that does nothing' }
if ($dhSrc -match 'writes a DOCKET' -or $dhSrc -match 'ADVISORY ONLY') { Ok 'discover-hyvee still writes a docket rather than the feed' }
else { Bad 'discover-hyvee may now write into the store feed - unreviewed discovery installs wrong crowns, which is the browse-test failure mode' }
# --- aisle-test (added 2026-08-01) -------------------------------------------------------------------
# The gate that has to exist before a catalogue browse is allowed to flip crowns: the FF browse test
# flipped 26 verdicts, ~2/3 to the wrong product (watermelon -> Hefty Fabuloso Watermelon TRASH BAGS).
$r = RunPS 'aisle-test.ps1' @('-SelfTest')
if ($r.rc -eq 0 -and $r.text -match 'SELFTEST: 12/12 pass') { Ok 'aisle-test -SelfTest passes (4 founding flips blocked, hard positive allowed, blind refuses, multi-row unrolls)' }
else { Bad ('aisle-test -SelfTest failed or lost its founding-bug fixtures: ' + ((($r.text -split "`n") | Select-Object -Last 3) -join ' | ')) }
$atSrc = Get-Content (Join-Path $root 'aisle-test.ps1') -Raw
if ($atSrc -match 'Wimmer') { Ok 'the hard-positive fixture (a real hot dog scoring BELOW three of the four failures) is still armed' }
else { Bad 'aisle-test lost the Wimmer''s Wieners fixture - that case is the whole reason this is not a semantic threshold, and without it someone will rebuild the version that fails' }
if ($atSrc -match 'the PS 5\.1 unroll bug is back') { Ok 'the multi-row unroll fixture is armed (a collapsed candidates file returns a tidy BLIND and reads as clean)' }
else { Bad 'aisle-test lost the array-unroll fixture - a multi-candidate file could silently collapse to one row again' }
if ($atSrc -match 'BLIND REFUSES THE FLIP') { Ok 'aisle-test still documents that BLIND refuses the flip (the one place the estate inverts blind-not-block)' }
else { Bad 'aisle-test lost the inverted-BLIND rule - if blind starts ALLOWING flips, unjudgeable depth reaches the board' }
if ($pvlSrc -match 'Remove-OverturnedRejects \$rej \$overturns') { Ok 'the purge still honours a later KEEP verdict (verify-apply''s human-overturn rule)' }
else { Bad 'purge-verdict-lows no longer subtracts overturned verdicts - it will delete history for a product a human re-reviewed and KEPT' }
$wpc2 = Get-Content (Join-Path $root 'weekly-post-capture.ps1') -Raw
if ($wpc2 -match "purge-verdict-lows\.ps1'\) @\('-Apply'\)") { Ok 'weekly publish still purges verdict-rejected history entries after banking' }
else { Bad 'weekly-post-capture no longer runs purge-verdict-lows - a late DROP verdict stops reaching the weeks it already poisoned' }
$cacSrc2 = Get-Content (Join-Path $root 'check-ad-cycles.ps1') -Raw
if ($cacSrc2 -match "purge-verdict-lows\.ps1'\) -Apply") { Ok 'the daily history bank is swept for verdict-rejected entries' }
else { Bad 'check-ad-cycles no longer purges after banking - the raw branch skips verify-apply, so every standing DROP is inert there and can bank a fresh record low' }

# ---------------------------------------------------------------- (l) review-flag re-arm + ack expiry
# The block in check-ad-cycles.ps1 that decides whether a price flag pages has no entry point of its own,
# so this extracts its two sentinel-delimited regions and runs THE REAL SOURCE against frozen synthetic
# state. Nothing about the expected outcome is hard-coded except the outcome, so reverting the logic breaks
# these checks. Founding bugs, all three measured on the live files on 2026-07-30:
#   1. (2026-07-29) last_seen was refreshed every run, so the novelty gap was always 0: an open flag paged
#      exactly ONCE, ever, and a genuine parse bug that was flagged and never fixed simply went quiet.
#   2. an EXPIRED ack did not re-arm the flag - it fell back onto the parallel 14-day clock, so any ack
#      shorter than 14 days was silently rounded up (the 7 MULTIBUY acks expired 08-06 and paged 08-13).
#   3. -NoAlert stamped last_alerted on flags it never mailed; the GitHub Actions backup runs -NoAlert and
#      commits the tracked state file back, so it consumed re-arms nobody was ever told about.
$rfSrc = [IO.File]::ReadAllText((Join-Path $root 'check-ad-cycles.ps1'))
# [regex]::Match into a LOCAL - $Matches is global and gets clobbered.
$rfD = [regex]::Match($rfSrc, '(?s)<<REVIEW-DECISION-BEGIN>>[^\r\n]*\r?\n(.*?)\r?\n[ \t]*# <<REVIEW-DECISION-END>>')
$rfS = [regex]::Match($rfSrc, '(?s)<<REVIEW-STAMP-BEGIN>>[^\r\n]*\r?\n(.*?)\r?\n[ \t]*# <<REVIEW-STAMP-END>>')
$rfA = [regex]::Match($rfSrc, '(?s)<<REVIEW-ACKLOAD-BEGIN>>[^\r\n]*\r?\n(.*?)\r?\n[ \t]*# <<REVIEW-ACKLOAD-END>>')
if (-not $rfD.Success -or -not $rfS.Success -or -not $rfA.Success) {
  Bad 'review-flag re-arm regions are GONE from check-ad-cycles.ps1 - this check EXAMINED NOTHING, the re-arm logic is untested'
} else {
  $RF_DECISION = $rfD.Groups[1].Value
  $RF_STAMP    = $rfS.Groups[1].Value
  $RF_ACKLOAD  = $rfA.Groups[1].Value
  # FROZEN synthetic state - never regenerated from out\alerted-flags.json, the bug lives in these dates.
  $rfOpen  = 'SANITY|FIXTURE Widget|outlier'      # open every day since T0-30, never re-paged
  $rfAck   = 'MULTIBUY|FIXTURE Store|fx-2'        # acked until T0+3
  $rfFresh = 'SANITY|FIXTURE Fresh|outlier'       # paged yesterday - must stay quiet
  $rfT0 = [datetime]'2026-03-02'
  $rfAckDoc = [pscustomobject]@{ acks = @([pscustomobject]@{ key = $rfAck; reason = 'frozen fixture'; expires = $rfT0.AddDays(3).ToString('yyyy-MM-dd') }) }
  # the REAL loader reads $OutDir\review-ack.json, so the frozen ack doc goes on disk in a temp dir
  $rfTmp = NewFxDir 'rf-ack'
  Set-Content (Join-Path $rfTmp 'review-ack.json') ($rfAckDoc | ConvertTo-Json -Depth 5) -Encoding UTF8
  function RfNewState {
    $h = @{}
    $h[$rfOpen]  = [pscustomobject]@{ first_seen = $rfT0.AddDays(-30).ToString('s'); last_seen = $rfT0.AddDays(-1).ToString('s'); last_detail = 'x' }
    # last_alerted = YESTERDAY on purpose: this is the discriminating case. The parallel 14-day clock is
    # nowhere near elapsing when the ack runs out on day 4, so if the ack expiry is not itself the re-arm
    # point the flag stays silent until day 13. Exactly the shape of the 7 live MULTIBUY acks on 2026-07-30
    # (first_seen 07-29, ack expires 08-06: an 8-day gap against a 14-day clock). A 30-day-old key here
    # would pass whether or not the fix is present, which is a fixture that tests nothing.
    $h[$rfAck]   = [pscustomobject]@{ first_seen = $rfT0.AddDays(-1).ToString('s'); last_seen = $rfT0.AddDays(-1).ToString('s'); last_detail = 'x'; last_alerted = $rfT0.AddDays(-1).ToString('s') }
    $h[$rfFresh] = [pscustomobject]@{ first_seen = $rfT0.AddDays(-1).ToString('s'); last_seen = $rfT0.AddDays(-1).ToString('s'); last_detail = 'x'; last_alerted = $rfT0.AddDays(-1).ToString('s') }
    return $h
  }
  # one simulated day of the REAL decision + stamp regions. $script:RF_NOW shadows Get-Date inside the scope.
  function RfRunDay([datetime]$now, [hashtable]$fstate, [bool]$noAlert, [bool]$sendFails) {
    $script:RF_NOW = $now
    function Get-Date { return $script:RF_NOW }
    function Log([string]$m) { }
    $NoAlert = $noAlert
    $flagKeys  = @($rfOpen, $rfAck, $rfFresh)          # all three flagged EVERY day - the backlog scenario
    $flagParts = @($flagKeys | ForEach-Object { $_ + '|detail' })
    # RUN THE REAL ACK LOADER, not a transcription of it (post-batch review 2026-07-30). This block used to
    # carry its own copy of the loop and its own $REARM_DAYS = 14, so production's $ackUntil line - half of
    # DEFECT 2 - could be deleted and all ten checks stayed green; changing production's re-arm window was
    # equally invisible. The loader is now a sentinelled region and is executed here, so both are covered.
    # $OutDir points at the temp dir holding the frozen review-ack.json, and Get-Date is shadowed above.
    $OutDir = $rfTmp
    Invoke-Expression $RF_ACKLOAD
    $newIdx = @()
    Invoke-Expression $RF_DECISION
    $due = @($newIdx | ForEach-Object { [string]$flagKeys[$_] })
    if ($sendFails) { $newIdx = @() }                  # mirrors the existing send-failure guard
    Invoke-Expression $RF_STAMP
    return [pscustomobject]@{ due = $due; stamped = @($fstate.Keys | Where-Object { $fstate[$_].last_alerted -eq $now.ToString('s') }) }
  }
  # MUST FIRE 1: a flag flagged on CONSECUTIVE days must eventually page again (the 2026-07-29 bug).
  $rfSt = RfNewState; $rfSaw = $false
  for ($rfD2 = 0; $rfD2 -lt 20; $rfD2++) { if ((RfRunDay $rfT0.AddDays($rfD2) $rfSt $false $false).due -contains $rfOpen) { $rfSaw = $true; break } }
  if ($rfSaw) { Ok 'review flags: an open flag present every day RE-ARMS (the never-re-arms bug)' }
  else { Bad 'review flags: a flag open on 20 consecutive days NEVER re-armed - it pages once and goes quiet forever' }
  # CLEAN TWIN 1: no cry-wolf. Window is 12 days, INSIDE the 14-day re-arm - a flag paged yesterday is
  # legitimately due again on day 13, so a 20-day window would call correct behaviour a failure.
  $rfSt = RfNewState; $rfFreshHits = 0; $rfOpenHits = 0
  for ($rfD2 = 0; $rfD2 -lt 12; $rfD2++) { $rfR = RfRunDay $rfT0.AddDays($rfD2) $rfSt $false $false; if ($rfR.due -contains $rfFresh) { $rfFreshHits++ }; if ($rfR.due -contains $rfOpen) { $rfOpenHits++ } }
  if ($rfFreshHits -eq 0) { Ok 'review flags: a flag paged yesterday stays SILENT for its whole re-arm window' }
  else { Bad ('review flags: a freshly-paged flag re-paged ' + $rfFreshHits + ' time(s) inside its 14-day window') }
  if ($rfOpenHits -eq 1) { Ok 'review flags: a re-armed flag pages ONCE, not daily' }
  else { Bad ('review flags: re-armed flag paged ' + $rfOpenHits + ' time(s) in 12 days - expected exactly 1') }
  # MUST FIRE 2: the ack's expiry is the re-arm moment.
  $rfSt = RfNewState; $rfAckDue = @()
  for ($rfD2 = 0; $rfD2 -lt 12; $rfD2++) { if ((RfRunDay $rfT0.AddDays($rfD2) $rfSt $false $false).due -contains $rfAck) { $rfAckDue += $rfD2 } }
  if (@($rfAckDue | Where-Object { $_ -le 3 }).Count -eq 0) { Ok 'review flags: an acked flag stays SILENT through its expiry date' }
  else { Bad ('review flags: an acked flag paged while its ack was still open, on day(s) ' + (($rfAckDue | Where-Object { $_ -le 3 }) -join ',')) }
  if ($rfAckDue -contains 4) { Ok 'review flags: an acked flag RE-ARMS the day after its ack expires' }
  else { Bad ('review flags: ack expiry did not re-arm the flag - paged on day(s) [' + ($rfAckDue -join ',') + '] instead of day 4, so the expiry date is decorative and short acks are silently rounded up to the 14-day clock') }
  if (@($rfAckDue).Count -le 2) { Ok 'review flags: an expired ack re-arms ONCE, not every day after expiry' }
  else { Bad ('review flags: an expired ack re-paged on ' + @($rfAckDue).Count + ' days - that is a daily spam loop') }
  # MUST FIRE 3: an alert nobody received must not consume the re-arm (.github\workflows\daily.yml -NoAlert).
  $rfSt = RfNewState
  $null = RfRunDay $rfT0.AddDays(0) $rfSt $true $false
  $rfStamped = @($rfSt.Keys | Where-Object { $rfSt[$_].last_alerted -eq $rfT0.ToString('s') })
  if ($rfStamped.Count -eq 0) { Ok 'review flags: a -NoAlert run stamps NO last_alerted (the cloud backup cannot consume a re-arm)' }
  else { Bad ('review flags: a -NoAlert run stamped last_alerted on ' + $rfStamped.Count + ' key(s) it never mailed: ' + ($rfStamped -join ' ; ')) }
  $rfR = RfRunDay $rfT0.AddDays(1) $rfSt $false $false
  if ($rfR.due -contains $rfOpen) { Ok 'review flags: a flag suppressed by -NoAlert is still DUE on the next alerting run' }
  else { Bad 'review flags: a flag went through a -NoAlert run and is no longer due - the page was silently swallowed' }
  # CLEAN TWIN 3: a real send still marks the flag delivered, and a FAILED send still does not.
  $rfSt = RfNewState
  $rfR = RfRunDay $rfT0.AddDays(0) $rfSt $false $false
  if ($rfR.stamped -contains $rfOpen) { Ok 'review flags: a real alerting run DOES stamp last_alerted' }
  else { Bad 'review flags: an alerting run failed to stamp last_alerted - flags would re-page forever' }
  $rfSt = RfNewState
  $null = RfRunDay $rfT0.AddDays(0) $rfSt $false $true
  if (@($rfSt.Keys | Where-Object { $rfSt[$_].last_alerted -eq $rfT0.ToString('s') }).Count -eq 0) { Ok 'review flags: a FAILED send stamps nothing (existing guard still intact)' }
  else { Bad 'review flags: a failed send stamped last_alerted - the alert is lost' }
}

# ---------------------------------------------------------------- publish-deals-page CHANGE GATE
# The MUST-FIRE / CLEAN-TWIN pair lives in that script's own -SelfTest (frozen synthetic signatures, never
# regenerated from the live board). Founding bug 2026-07-29: 13 invocations pushed the SAME week's board to
# Ghost 12 times. Run it daily so a DEAD short-circuit (every run upserts again) and, far worse, a
# short-circuit that started skipping REAL changes (a price move that never ships) both surface here.
# READ THE SOURCE BEFORE INVOKING IT. publish-deals-page is a SIMPLE script (no [CmdletBinding()]), so an
# unknown -SelfTest does NOT error: PowerShell drops the string into $args and the script runs its normal
# path - measured - and the admin key resolves from meal-prep\.ghostkey, so a publish-deals-page that lost
# its -SelfTest handler would make this daily fixture suite perform a REAL Ghost publish. Prove the hermetic
# handler exists AND sits ahead of the first live step (the admin-key resolution) before running it; if it
# does not, fail loudly and invoke nothing.
$pdpSelfIdx = $pdpSrc.IndexOf('if ($SelfTest) {')
$pdpKeyIdx  = $pdpSrc.IndexOf('Ghost admin key missing')
if (($pdpSrc -notmatch '\[switch\]\$SelfTest') -or $pdpSelfIdx -lt 0 -or $pdpKeyIdx -lt 0 -or $pdpSelfIdx -gt $pdpKeyIdx) {
  Bad 'publish-deals-page has no hermetic -SelfTest handler ahead of its admin-key step - the change-gate fixture could not be run, and must NOT be invoked (an unknown -SelfTest lands in $args and the script performs a REAL publish)'
} else {
  $r = RunPS 'publish-deals-page.ps1' @('-SelfTest')
  if ($r.rc -eq 0 -and $r.text -match 'SELFTEST PASS') { Ok 'publish-deals-page change gate still skips an unchanged board and still publishes a one-byte change' }
  else { Bad ('publish-deals-page -SelfTest failed or lost its change-gate fixture: ' + ((($r.text -split "`n") | Select-Object -Last 3) -join ' | ')) }
}
# ...and the two callers that must understand a skip (source asserts - house precedent for caller plumbing).
$prtSrc = Get-Content (Join-Path $root 'publish-retry-until-live.ps1') -Raw
if ($prtSrc -match 'CURRENT omaha-grocery-prices') { Ok 'publish-retry-until-live counts a short-circuited (CURRENT) board as success, so the retry task can still delete itself' }
else { Bad 'publish-retry-until-live accepts only PUBLISHED - against the change gate it would retry every 20 min forever on a board that is already live' }
if ($pdpSrc -match 'guide unchanged') { Ok 'publish-deals-page tells a store-guide upsert apart from a store-guide skip' }
else { Bad 'publish-deals-page prints "store guide republished" on any rc=0 again - publish-store-guide also exits 0 when it skips, which is how the 07-29 audit counted 12 phantom guide upserts' }

# ---------------------------------------------------------------- N+6. no script may sign another script's name
# 2026-07-30: build-walmart-deals.ps1 is a fork of build-sams-deals.ps1 (capture-lib.ps1:14-19) and inherited
# that name in EVERY operator-facing string. A real pull printed "build-sams-deals: 4626 raw -> 3444 priced ->
# walmart-regular-2026-07-29.json", and a missing -In threw "build-sams-deals: -In not found", which sends the
# operator to the wrong script AND the wrong capture file. Line 2 of that header was hand-corrected once on
# 2026-07-26 and the usage block two lines below it was missed - a hand fix does not close a copy-paste class.
# The check reads BOTH the dictionary of script names and each file's own name off the filesystem, so there is
# no hard-coded text that could pass by going stale. A script legitimately labels output from a child it RUNS
# (check-ad-cycles logs 'prune-bad-links: ...'), so a name is only a lie when the file does not ALSO carry that
# .ps1 as a bare path string. Measured on the live tree 2026-07-30: 3 findings, all real, and all 4 delegating
# sites (check-ad-cycles x3, run-daily-local) stay silent - dropping the bare-path exemption raises the count
# from 3 to 7, which is how we know that clause is load-bearing and not dead. Comments are not scanned, so
# honest provenance notes ("ported from build-sams-deals") never cry wolf. Costs ~1.0s over 138 scripts.
# NOT extended to STORE nouns on purpose: that variant was built and measured at 3 false positives out of 5
# (audit-walmart-fullpull is deliberately dual-store, audit-ff-missing-products holds a store list, and
# import-walmart-batch's Member's Mark name is inside a frozen fixture) - 60% cry-wolf, so it stays out.
function Get-MisnamedEmitters([string]$scanDir) {
  $own = @{}
  foreach ($p in (Get-ChildItem (Join-Path $scanDir '*.ps1') -File -EA SilentlyContinue)) { $own[$p.BaseName.ToLower()] = $true }
  $hits = New-Object System.Collections.ArrayList
  foreach ($p in (Get-ChildItem (Join-Path $scanDir '*.ps1') -File -EA SilentlyContinue)) {
    # ((Get-Content -Raw) + '') - [string]$null is $null, so .Trim() on a zero-byte script would throw
    $src = ((Get-Content $p.FullName -Raw) + '')
    if (-not $src.Trim()) { continue }
    $perr = $null
    $toks = @([System.Management.Automation.PSParser]::Tokenize($src, [ref]$perr) | Where-Object { $_.Type -eq 'String' })
    # every script this file POINTS AT: a string token that is nothing but a .ps1 path
    $points = @{}
    foreach ($t in $toks) {
      $c = ([string]$t.Content).Trim()
      if ($c -match '\.ps1$' -and $c -notmatch '[\s:]') { $points[([IO.Path]::GetFileNameWithoutExtension($c)).ToLower()] = $true }
    }
    $me = $p.BaseName.ToLower()
    foreach ($t in $toks) {
      $m = [regex]::Match(([string]$t.Content), '^\s*\[?([A-Za-z][A-Za-z0-9]*(?:-[A-Za-z0-9]+)+)(?:\.ps1)?\s*(?::|\])')
      if (-not $m.Success) { continue }
      $said = $m.Groups[1].Value.ToLower()
      if ($said -eq $me -or -not $own.ContainsKey($said) -or $points.ContainsKey($said)) { continue }
      $null = $hits.Add(("{0}:{1} signs '{2}'" -f $p.Name, $t.StartLine, $said))
    }
  }
  return @($hits.ToArray())
}
# MUST FIRE + CLEAN TWIN. Synthetic on purpose - three throwaway scripts, never derived from live source, so
# the bug they encode cannot evaporate the way a regenerated fixture does. The honest twin carries BOTH silence
# conditions at once (it signs its own name AND labels a child it really invokes), which is the exact shape of
# the legitimate sites in the estate.
$fxSg = Join-Path $env:TEMP ('ta-signs-' + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $fxSg -Force | Out-Null
Set-Content (Join-Path $fxSg 'fx-sams-twin.ps1') "Write-Output 'fx-sams-twin: 1 raw -> 1 priced'" -Encoding UTF8
Set-Content (Join-Path $fxSg 'fx-forked-builder.ps1') @'
if (-not $In) { throw "fx-sams-twin: -In not found: $In" }
Write-Output ("fx-sams-twin: {0} raw -> {1} priced" -f 4626, 3444)
'@ -Encoding UTF8
Set-Content (Join-Path $fxSg 'fx-honest-builder.ps1') @'
$out = & powershell -File (Join-Path $root 'fx-sams-twin.ps1')
Write-Output ('fx-sams-twin: ' + $out)
Write-Output ("fx-honest-builder: {0} raw -> {1} priced" -f 4626, 3444)
'@ -Encoding UTF8
$sg = @(Get-MisnamedEmitters $fxSg)
if ((@($sg | Where-Object { $_ -like 'fx-forked-builder.ps1:*' }).Count -eq 2) -and (@($sg | Where-Object { $_ -like 'fx-honest-builder.ps1:*' }).Count -eq 0)) {
  Ok 'signs-its-own-name FIRES on the forked builder and stays silent on the honest twin (self-label + labelling a child it runs)'
} else { Bad ('signs-its-own-name fixture wrong - the checker cannot see its founding bug: ' + ($sg -join ' | ')) }
Remove-Item $fxSg -Recurse -Force -ErrorAction SilentlyContinue
$sgLive = @(Get-MisnamedEmitters $root)
if ($sgLive.Count -eq 0) { Ok 'no grocery script signs another script''s name (the build-walmart-deals/build-sams-deals fork class)' }
else { Bad ('a script emits under another script''s name - a failure sends the operator to the wrong script and the wrong capture file: ' + ($sgLive -join '; ')) }

# ---------------------------------------------------------------- N+9. the match-soundness sweep cache
# audit-match-soundness re-derived its whole name->commodity sweep on every invocation: 51.5s of a 53.0s run,
# ~75% of every publish, and it ran 15 times on 2026-07-29 (14 publish-deals-page invocations in
# out\logs\weekly-post-capture-2026-07.log plus the daily check-ad-cycles call) on inputs that mostly had not
# changed. It now stamps a SHA1 of its closed input set next to match-baseline.json and reuses the sweep.
# A cache is a gate that must arm: if the stamp ever matches when an input HAS changed, this audit silently
# reports last run's answer, and it is the gate that decides whether the publish HOLDs.
# The fixture never re-implements the hash - it takes the fingerprint the script itself wrote and corrupts
# only the ANSWER under it, so "the cache was consulted" and "the cache was rejected" are visible in stdout.
$fxMs = NewFxDir 'ms-cache'
New-Item -ItemType Directory -Force (Join-Path $fxMs 'out\audit') | Out-Null
New-Item -ItemType Directory -Force (Join-Path $fxMs 'out\regular') | Out-Null
Copy-Item (Join-Path $root 'audit-match-soundness.ps1') (Join-Path $fxMs 'audit-match-soundness.ps1')
Copy-Item (Join-Path $root 'verdict-lib.ps1') (Join-Path $fxMs 'verdict-lib.ps1')
Set-Content (Join-Path $fxMs 'commodities.json') '[{"id":"lemons","include":["lemon"],"exclude":[]},{"id":"limes","include":["lime"],"exclude":[]}]' -Encoding UTF8
Set-Content (Join-Path $fxMs 'compare-deals.ps1') "`$GLOBAL_EXCLUDE = @(`n  'scented candle'`n)`n" -Encoding UTF8
Set-Content (Join-Path $fxMs 'out\regular\hyvee-regular-2026-01-01.json') '{"deals":[{"item":"Fresh Lemon 1 ct"},{"item":"Fresh Lime 1 ct"}]}' -Encoding UTF8
$msBaseJson = '{"generated":"2026-01-01 00:00","names":{"Fresh Lemon 1 ct":"lemons","Fresh Lime 1 ct":"limes"},"contested":[]}'
Set-Content (Join-Path $fxMs 'out\audit\match-baseline.json') $msBaseJson -Encoding UTF8
$msCache = Join-Path $fxMs 'out\audit\match-sweep-cache.json'
function MsPoison() {
  $cj = ConvertFrom-Json ([IO.File]::ReadAllText($script:msCache))
  $nk = @($cj.names_k); $nv = @($cj.names_v)
  $pv = New-Object System.Collections.Generic.List[string]
  for ($i = 0; $i -lt $nk.Count; $i++) { if ([string]$nk[$i] -eq 'Fresh Lemon 1 ct') { [void]$pv.Add('limes') } else { [void]$pv.Add([string]$nv[$i]) } }
  Set-Content $script:msCache -Value ([ordered]@{ fp = [string]$cj.fp; count = [int]$cj.count; names_k = $nk; names_v = $pv.ToArray(); contest_k = @($cj.contest_k); contest_v = @($cj.contest_v) } | ConvertTo-Json -Depth 4 -Compress) -Encoding UTF8
}
$r = RunPSAt $fxMs 'audit-match-soundness.ps1' @()
if ($r.rc -eq 0 -and $r.text -match 'MOVED=0  DROPPED=0') { Ok 'match-soundness cold run agrees with its frozen baseline' }
else { Bad ('match-soundness cold run did not match the frozen baseline (rc=' + $r.rc + '): ' + $r.text) }
if (-not (Test-Path $msCache)) { Bad 'no sweep cache was stamped - the input fingerprint is gone, so the 51s sweep reruns on every publish again' }
else {
  # CLEAN TWIN: byte-identical inputs must HIT (the poisoned answer is what surfaces).
  MsPoison
  $r = RunPSAt $fxMs 'audit-match-soundness.ps1' @()
  if ($r.rc -eq 2 -and $r.text -match 'MOVED    lemons -> limes') { Ok 'byte-identical inputs HIT the sweep cache' }
  else { Bad ('byte-identical inputs did NOT hit the sweep cache (rc=' + $r.rc + ') - the fingerprint never matches and the cache is dead weight: ' + $r.text) }
  # MUST FIRE: a one-byte, semantically NEUTRAL change to ANY input must MISS, so the true answer returns.
  foreach ($inp in @(
      @{ n = 'the script itself'; f = (Join-Path $fxMs 'audit-match-soundness.ps1'); add = "`n# fixture byte`n" },
      @{ n = 'commodities.json';  f = (Join-Path $fxMs 'commodities.json');          add = ' ' },
      @{ n = 'compare-deals.ps1'; f = (Join-Path $fxMs 'compare-deals.ps1');         add = "`n# fixture byte`n" },
      @{ n = 'verdict-lib.ps1';   f = (Join-Path $fxMs 'verdict-lib.ps1');           add = "`n# fixture byte`n" },
      @{ n = 'a store feed file'; f = (Join-Path $fxMs 'out\regular\hyvee-regular-2026-01-01.json'); add = ' ' })) {
    $keep = [IO.File]::ReadAllBytes($inp.f)
    RunPSAt $fxMs 'audit-match-soundness.ps1' @() | Out-Null
    MsPoison
    [IO.File]::WriteAllText($inp.f, ([IO.File]::ReadAllText($inp.f) + $inp.add))
    $r = RunPSAt $fxMs 'audit-match-soundness.ps1' @()
    if ($r.rc -eq 0 -and $r.text -match 'MOVED=0  DROPPED=0') { Ok ('a one-byte change to ' + $inp.n + ' MISSES the sweep cache') }
    else { Bad ('a one-byte change to ' + $inp.n + ' still served the STALE sweep (rc=' + $r.rc + ') - that input is not in the fingerprint: ' + $r.text) }
    [IO.File]::WriteAllBytes($inp.f, $keep)
  }
  # -Accept snapshots $names into the baseline and everything in it goes invisible to this audit forever
  # after, so it must never read a cached sweep - nor write one.
  RunPSAt $fxMs 'audit-match-soundness.ps1' @() | Out-Null
  MsPoison
  $msCacheTicks = (Get-Item $msCache).LastWriteTime.Ticks
  $r = RunPSAt $fxMs 'audit-match-soundness.ps1' @('-Accept')
  $msNewBase = ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $fxMs 'out\audit\match-baseline.json')))
  if ($r.rc -eq 0 -and ([string]$msNewBase.names.'Fresh Lemon 1 ct') -eq 'lemons') { Ok '-Accept ignores the sweep cache and baselines a freshly swept truth' }
  else { Bad ('-Accept blessed a CACHED mapping into the permanent baseline (got ' + [string]$msNewBase.names.'Fresh Lemon 1 ct' + ') - a stale sweep is now invisible forever') }
  if ((Get-Item $msCache).LastWriteTime.Ticks -eq $msCacheTicks) { Ok '-Accept does not write the sweep cache either (write path skipped entirely)' }
  else { Bad '-Accept wrote the sweep cache - the write path is not skipped' }
  # An unusable stamp must fall through to the real sweep ('' | ConvertFrom-Json returns $null WITHOUT throwing).
  Set-Content (Join-Path $fxMs 'out\audit\match-baseline.json') $msBaseJson -Encoding UTF8
  foreach ($junk in @('', '   ', '{"fp":"deadbeef","count":2', '{"fp":"deadbeef","count":0,"names_k":[],"names_v":[],"contest_k":[],"contest_v":[]}')) {
    Set-Content $msCache -Value $junk -Encoding UTF8
    $r = RunPSAt $fxMs 'audit-match-soundness.ps1' @()
    if ($r.rc -eq 0 -and $r.text -match 'MOVED=0  DROPPED=0') { Ok ('an unusable sweep stamp (len ' + $junk.Length + ') falls through to the real sweep') }
    else { Bad ('an unusable sweep stamp (len ' + $junk.Length + ') changed the verdict (rc=' + $r.rc + '): ' + $r.text) }
  }
  # BLIND: zero ingested products must never be stamped, must not read as all-clear, and must not be
  # baselined (-Accept over an empty sweep erased 18,123 names -> 129 bytes and exited 0 on 2026-07-30).
  Remove-Item $msCache -Force -ErrorAction SilentlyContinue
  Remove-Item (Join-Path $fxMs 'out\regular\hyvee-regular-2026-01-01.json') -Force
  $msBaseSize = (Get-Item (Join-Path $fxMs 'out\audit\match-baseline.json')).Length
  $r = RunPSAt $fxMs 'audit-match-soundness.ps1' @()
  if ($r.rc -eq 3 -and $r.text -match 'BLIND') { Ok 'match-soundness reports BLIND (exit 3) when ZERO products were ingested' }
  else { Bad ('match-soundness returned rc=' + $r.rc + ' having ingested NOTHING - a zero-product run still reads as a clean board: ' + $r.text) }
  if (-not (Test-Path $msCache)) { Ok 'a sweep that read ZERO products is never stamped (cannot be replayed as all-clear)' }
  else { Bad 'an empty sweep was cached - "0 products, all clear" can now be served forever' }
  $r = RunPSAt $fxMs 'audit-match-soundness.ps1' @('-Accept')
  if ($r.rc -eq 3 -and (Get-Item (Join-Path $fxMs 'out\audit\match-baseline.json')).Length -eq $msBaseSize) { Ok '-Accept REFUSES an empty sweep (the reviewed baseline survives intact)' }
  else { Bad ('-Accept baselined an EMPTY sweep (rc=' + $r.rc + ', baseline now ' + (Get-Item (Join-Path $fxMs 'out\audit\match-baseline.json')).Length + ' bytes) - this audit is blinded permanently and the empty map is a TRACKED file') }
}
Remove-Item $fxMs -Recurse -Force -ErrorAction SilentlyContinue

# ---- (l) the weekly-run lock (added 2026-07-30) --------------------------------------------------------
# FOUNDING BUG: on 2026-07-29 the 8:30 daily job ran a full 46m42s cycle (ad-cycle-log 08:31:06 ->
# 09:17:48) INSIDE the weekly run - weekly-post-capture's -Phase publish wrote out\verified-2026-07-29.json
# and published the live board at 08:46:24-08:51:39, and the daily then graded that board, hard-failed, and
# auto-repaired links on top of it at 09:14:23. Both halves are the requirement: a live weekly run must
# stand the daily down, and a lock the weekly never released must NOT - a stale lock that silently disables
# the daily forever is strictly worse than the waste it prevents. Locks here are written by the REAL
# -Acquire path at the REAL phase timestamps; a hand-written fixture lock would pass whether or not the
# writer still stamps an expiry, and - worse - would pass on a weekly that hands the tree back mid-run.
$fxWl = NewFxDir 'weekly-lock'
$wlF  = Join-Path $fxWl 'weekly-run.lock'
# MUST STAND DOWN: the founding run, replayed. These are the actual phase START times of 2026-07-29 from
# out\logs\weekly-post-capture-2026-07.log. The daily fires at 08:30:01, between the 08:00:26 links phase
# and the 08:46:24 publish phase - a 44.8-minute judgment gap with no phase executing.
foreach ($stamp in @('2026-07-29T07:17:22','2026-07-29T07:29:20','2026-07-29T07:32:30','2026-07-29T07:36:03','2026-07-29T07:54:11','2026-07-29T07:56:30','2026-07-29T08:00:26')) {
  $null = RunPS 'weekly-run-lock.ps1' @('-LockFile',$wlF,'-Acquire','-Phase','replay','-Now',$stamp)
}
$wpcLk = Get-Content (Join-Path $root 'weekly-post-capture.ps1') -Raw
if ($wpcLk -match "weekly-run-lock\.ps1'\) @\('-Release'") {
  # the weekly hands the tree back mid-run: the three links phases at 07:55:21, 07:58:07 and 08:01:34 each
  # ended in push-data, so the lock is GONE before the daily tick. Model that, do not paper over it.
  Remove-Item $wlF -Force -ErrorAction SilentlyContinue
}
$r = RunPS 'weekly-run-lock.ps1' @('-LockFile',$wlF,'-Now','2026-07-29T08:30:01')
if ($r.rc -eq 2 -and $r.text -match 'HELD') { Ok 'weekly lock: the REPLAYED 2026-07-29 run still holds the tree at the 08:30 daily tick' }
else { Bad ('weekly lock is NOT held at 08:30 on a replay of the founding run (rc=' + $r.rc + ') - the 46m42s collision of 2026-07-29 still happens: ' + $r.text) }
# ...and must survive the REAL maximum in-run pause: 12:58:25 -> 16:05:53 = 187.5 min, measured over all 383
# timestamped lines of that run. A TTL under this expires while the agent is still working.
$null = RunPS 'weekly-run-lock.ps1' @('-LockFile',$wlF,'-Acquire','-Phase','publish','-Now','2026-07-29T12:58:25')
$r = RunPS 'weekly-run-lock.ps1' @('-LockFile',$wlF,'-Now','2026-07-29T16:05:53')
if ($r.rc -eq 2) { Ok 'weekly lock: the real 187.5-min agent judgment pause still reads HELD' }
else { Bad ('weekly lock expired inside the REAL max in-run pause (rc=' + $r.rc + ') - the TTL is shorter than a normal weekly gap') }
# MUST NOT STAND DOWN, AND MUST SAY SO: nothing in the weekly releases the lock, so the end state is always
# an abandoned one. That run's last phase was 19:07:26; by the next 08:30 tick it must be dead.
$null = RunPS 'weekly-run-lock.ps1' @('-LockFile',$wlF,'-Acquire','-Phase','publish','-Now','2026-07-29T19:07:26')
$r = RunPS 'weekly-run-lock.ps1' @('-LockFile',$wlF,'-Now','2026-07-30T08:30:01')
if ($r.rc -eq 0 -and $r.text -match 'STALE' -and $r.text -match 'EXPIRED' -and $r.text -match 'must never disable the daily job') { Ok 'weekly lock: a finished/abandoned lock EXPIRES before the next daily, says so loudly, and does NOT stand it down' }
else { Bad ('weekly lock did not expire by the next 08:30 (rc=' + $r.rc + ') - a finished or crashed weekly would disable the 8:30 job: ' + $r.text) }
# the expiry the reader trusts must come from the FILE, not from a constant on the read side
$wlJson = try { (((Get-Content $wlF -Raw -Encoding UTF8) + '').Trim() | ConvertFrom-Json) } catch { $null }
if ($wlJson -and $wlJson.expires -and $wlJson.refreshed -and $wlJson.acquired -and $wlJson.pid) { Ok 'weekly lock carries its own acquired/refreshed/expires/pid stamp' }
else { Bad 'weekly lock file lost its self-describing expiry - the reader has nothing to read and the TTL can drift' }
# CLEAN TWIN: no lock is a definite answer, not a blind one, and never blocks the daily (6 days in 7).
Remove-Item $wlF -Force -ErrorAction SilentlyContinue
$r = RunPS 'weekly-run-lock.ps1' @('-LockFile',$wlF,'-Now','2026-07-30T08:30:01')
if ($r.rc -eq 0 -and $r.text -match 'none - no weekly refresh') { Ok 'weekly lock clean twin: no lock = the daily runs, and says nothing alarming' }
else { Bad ('weekly lock false-positived with no lock present (rc=' + $r.rc + '): ' + $r.text) }
# an unreadable lock must FAIL OPEN and NAME the blindness (exit 3), never silently block the day's prices
Set-Content $wlF '' -Encoding UTF8
$r = RunPS 'weekly-run-lock.ps1' @('-LockFile',$wlF,'-Now','2026-07-30T08:30:01')
if ($r.rc -eq 3 -and $r.text -match 'CANNOT EVALUATE') { Ok 'weekly lock: an empty lock is exit 3 (could-not-evaluate) and fails OPEN' }
else { Bad ('weekly lock did not report could-not-evaluate on an empty file (rc=' + $r.rc + '): ' + $r.text) }
Set-Content $wlF 'not json at all' -Encoding UTF8
$r = RunPS 'weekly-run-lock.ps1' @('-LockFile',$wlF,'-Now','2026-07-30T08:30:01')
if ($r.rc -eq 3 -and $r.text -match 'CANNOT EVALUATE') { Ok 'weekly lock: a corrupt lock is exit 3 and fails OPEN' }
else { Bad ('weekly lock did not report could-not-evaluate on a corrupt file (rc=' + $r.rc + '): ' + $r.text) }
$null = RunPS 'weekly-run-lock.ps1' @('-LockFile',$wlF,'-Acquire','-Phase','links','-Now','2026-07-30T08:00:00')
$null = RunPS 'weekly-run-lock.ps1' @('-LockFile',$wlF,'-Release')
if (-not (Test-Path $wlF)) { Ok 'weekly lock: -Release removes it (so the daily can sweep its own stale debris)' }
else { Bad 'weekly lock: -Release left the file behind - a swept stale lock would come straight back every morning' }
Remove-Item $fxWl -Recurse -Force -ErrorAction SilentlyContinue
# and BOTH callers must still be wired to it - a lock nobody takes and nobody checks is a no-op that
# passes every behavioural test above (source asserts: house precedent for caller plumbing).
$rdlLk = Get-Content (Join-Path $root 'run-daily-local.ps1') -Raw
if ($rdlLk -match 'weekly-run-lock\.ps1' -and $rdlLk -match '\$wlRc -eq 2' -and $rdlLk -match 'STAND DOWN: the weekly browser refresh' -and $rdlLk -match "weekly-run-lock\.ps1'\) -Release") { Ok 'run-daily-local still checks the weekly lock, stands down on HELD, and sweeps a stale one' }
else { Bad 'run-daily-local no longer stands down for the weekly run - the 46-minute collision of 2026-07-29 is back' }
if ($wpcLk -match "weekly-run-lock\.ps1'\) @\('-Acquire'") { Ok 'weekly-post-capture still takes the lock on every phase' }
else { Bad 'weekly-post-capture stopped taking the weekly lock - the daily has nothing to stand down for' }
if ($wpcLk -match "weekly-run-lock\.ps1'\) @\('-Release'") { Bad 'weekly-post-capture releases the lock mid-run again - on 2026-07-29 a links phase finished at 08:01:34 and the next phase was 08:46:24, so releasing hands grocery\out back 28 min before the 08:30 daily fires. The lock expires on its own TTL; nothing in the weekly may hand it back.' }
else { Ok 'weekly-post-capture never hands the tree back mid-run (the lock expires on its own TTL)' }

# ---------------------------------------------------------------- N+6. script census: is every file in this
# directory still reachable? 2026-07-30: 33 of the 144 .ps1 in grocery\ (out\ and archive\ aside) were named
# by no other executable file in the repo, and another 37 sat inside out\ - the pipeline's own OUTPUT
# directory. At that ratio a live weekly-by-hand script is indistinguishable from a finished one-shot that
# would clobber a backup if you ran it. audit-script-census.ps1 holds that line with a recorded SET of
# deliberate entry points plus a recorded COUNT for out\; its header names them all.
# DO NOT NAME A GROCERY SCRIPT IN THIS COMMENT. The census greps filenames across executable files, so a
# mention here is indistinguishable from a call and would silently retire that script from the census (it
# already happened once while this block was being written). Fixtures are synthetic zzz-* trees only.
$r = RunPS 'audit-script-census.ps1' @()
# The live twin asserts TWO things, because "clean" alone is exactly what a self-defeated census reports.
# The census must not count ITSELF as a source: its own KNOWN table quotes every recorded name, so the day
# that exclusion is dropped the census reports 0 uncalled, prints "no unrecorded orphan", and exits 0
# forever. The uncalled count is read from the guard's own output, never hard-coded here: it can never
# legitimately reach 0 while the SKILL-launched and Task-Scheduler-launched entry points exist.
$scM = [regex]::Match($r.text, '(\d+) uncalled, (\d+) recorded as deliberate')
if ($r.rc -eq 0 -and $r.text -match 'no unrecorded orphan' -and $scM.Success -and [int]$scM.Groups[1].Value -gt 0) { Ok ('script-census clean twin: no unrecorded orphan, out\ at baseline, and it still SEES its recorded set (' + $scM.Groups[1].Value + ' uncalled)') }
else { Bad ('script-census fires on the live tree, or reported an EMPTY census (rc=' + $r.rc + ') - either a new orphan landed, or the self-exclusion that stops its own KNOWN table from marking everything "called" was removed: ' + $r.text) }
$fxSc = NewFxDir 'sc-orphan'
Set-Content (Join-Path $fxSc 'zzz-new-thing.ps1') 'Write-Output "new"' -Encoding UTF8
Set-Content (Join-Path $fxSc 'zzz-caller.ps1') '& (Join-Path $PSScriptRoot "zzz-helper.ps1")' -Encoding UTF8
Set-Content (Join-Path $fxSc 'zzz-helper.ps1') 'Write-Output "helper"' -Encoding UTF8
Set-Content (Join-Path $fxSc 'zzz-wire.js') '// nightly: zzz-caller.ps1' -Encoding UTF8
$r = RunPS 'audit-script-census.ps1' @('-Root', $fxSc, '-ScanRoot', $fxSc)
if ($r.rc -eq 2 -and $r.text -match 'ORPHAN zzz-new-thing\.ps1') { Ok 'script-census FIRES on a script no executable file names' }
else { Bad ('script-census missed a brand-new orphan (rc=' + $r.rc + '): ' + $r.text) }
Set-Content (Join-Path $fxSc 'zzz-run.cmd') 'powershell -File zzz-new-thing.ps1' -Encoding UTF8
$r = RunPS 'audit-script-census.ps1' @('-Root', $fxSc, '-ScanRoot', $fxSc)
if ($r.rc -eq 0 -and $r.text -match '0 uncalled') { Ok 'script-census SILENT once that script is wired in (a .cmd launcher counts as a caller)' }
else { Bad ('script-census still fires after the orphan was wired in (rc=' + $r.rc + '): ' + $r.text) }
New-Item -ItemType Directory -Force (Join-Path $fxSc 'out') | Out-Null
Set-Content (Join-Path $fxSc 'out\zzz-oneoff.ps1') 'Write-Output "one-off"' -Encoding UTF8
$r = RunPS 'audit-script-census.ps1' @('-Root', $fxSc, '-ScanRoot', $fxSc, '-OutBaseline', '0')
if ($r.rc -eq 2 -and $r.text -match 'OUTPUT directory') { Ok 'script-census ratchet FIRES when a one-off is written into out\' }
else { Bad ('script-census let out\ grow past its recorded baseline (rc=' + $r.rc + '): ' + $r.text) }
$r = RunPS 'audit-script-census.ps1' @('-Root', $fxSc, '-ScanRoot', $fxSc, '-OutBaseline', '1')
if ($r.rc -eq 0) { Ok 'script-census ratchet SILENT at the recorded baseline (a ratchet, not a hard zero)' }
else { Bad ('script-census ratchet fires at its own recorded baseline (rc=' + $r.rc + ') - it would fail from day one') }
$fxScB = NewFxDir 'sc-blind'
$r = RunPS 'audit-script-census.ps1' @('-Root', $fxScB, '-ScanRoot', $fxScB)
if ($r.rc -eq 3 -and $r.text -match 'BLIND') { Ok 'script-census goes BLIND (exit 3) with nothing to examine instead of reporting a clean zero' }
else { Bad ('script-census reported a result from an empty tree (rc=' + $r.rc + ') - "0 orphans" from zero examination is back') }
Remove-Item $fxSc, $fxScB -Recurse -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------- N. arrivals desk (build-arrivals-docket)
# MUST FIRE: 2026-07-28. "Dr Teal's Foaming Bath with Pure Epsom Salt, Nourish & Protect with Coconut Oil"
# arrived in coconut-oil at Baker's and took the crown at 17c/oz. It carried a real Kroger product_id, a real
# price and a working link, so every identity, basis, band and link check passed it. The ONLY thing wrong was
# that the product is not the commodity, and nothing on the board records that decision.
# THE POINT OF THIS FIXTURE is the head cut. Scoring the FULL product name matches "Coconut Oil" in the tail
# and the bath soap scores a PERFECT 0.00 divergence - measured, along with the cat-food-as-salmon case
# falling off the docket entirely. If someone "simplifies" Get-ArrivalHead to score the whole name, this test
# is what stops it, so do not relax it to a rank or a substring of the item text.
$r = RunPS 'build-arrivals-docket.ps1' @('-CompareFile', (Join-Path $fix 'arrivals-mustfire-board.json'), '-BaselineDir', (Join-Path $fix 'arrivals-baseline'), '-CommoditiesFile', (Join-Path $fix 'arrivals-commodities.json'), '-OutFile', (Join-Path $env:TEMP ('arrdock-' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.json')))
if ($r.text -match 'FLAG#1' -and $r.text -match 'coconut-oil' -and $r.text -match 'div=1\.00' -and $r.text -match 'CROWN') { Ok 'arrivals-docket RANKS the bath-soap-as-coconut-oil crown arrival FIRST' }
else { Bad ('arrivals-docket MISSED its founding bug (head cut broken, or crowns no longer ranked first): ' + $r.text) }
# MUST FIRE: a commodity with ONE other priced cell cannot be scored at all. 41 of 492 commodities are in that
# state, and "no flag" from an unscorable row is the exact silence this estate has been burned by.
if ($r.text -match 'BLIND' -and $r.text -match 'harissa-paste' -and $r.text -match 'thin-cohort') { Ok 'arrivals-docket reports a 1-cell cohort BLIND instead of passing it' }
else { Bad ('arrivals-docket silently passed an unscorable thin cohort: ' + $r.text) }
# MUST BE SILENT: the SAME arrival, the SAME crown, the SAME 17c/oz - with a real coconut oil. If this flags,
# the score is tracking novelty or cheapness rather than divergence and the whole docket is noise.
$r2 = RunPS 'build-arrivals-docket.ps1' @('-CompareFile', (Join-Path $fix 'arrivals-clean-board.json'), '-BaselineDir', (Join-Path $fix 'arrivals-baseline'), '-CommoditiesFile', (Join-Path $fix 'arrivals-commodities.json'), '-OutFile', (Join-Path $env:TEMP ('arrdock-' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.json')))
if ($r2.text -match 'FLAGGED at div >= 0\.75: 0') { Ok 'arrivals-docket SILENT on the same crown arrival with the right product' }
else { Bad ('arrivals-docket flagged a correct new product - it is scoring novelty, not divergence: ' + $r2.text) }
if ($r2.text -match 'harissa-paste' -and $r2.text -match 'thin-cohort') { Ok 'arrivals-docket still reports the thin cohort BLIND on the clean board' }
else { Bad 'arrivals-docket dropped its BLIND report on a clean board - BLIND must describe the cohort, not the verdict' }
# MUST FIRE: with no baseline there is no delta, and "every cell is an arrival" is not a review queue. A check
# that examined nothing must say so rather than emit 2,792 rows that read like findings.
$r3 = RunPS 'build-arrivals-docket.ps1' @('-CompareFile', (Join-Path $fix 'arrivals-mustfire-board.json'), '-BaselineDir', (Join-Path $fix 'arrivals-baseline'), '-CommoditiesFile', (Join-Path $fix 'arrivals-commodities.json'), '-OutFile', (Join-Path $env:TEMP ('arrdock-' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.json')), '-N', '0')
if ($r3.rc -eq 3 -and $r3.text -match 'ZERO baseline boards') { Ok 'arrivals-docket exits 3 when it has NO baseline to diff against' }
else { Bad ('arrivals-docket claimed a usable delta with zero baseline (rc=' + $r3.rc + ')') }

# ---------------------------------------------------------------- N2. the PROSPECTS section (F1 adjudication)
# discover-hyvee.ps1 writes a docket of products that are NOT on the board and would beat what we hold. It had
# no reader, so discovery paid nothing. These fixtures pin the reader.
# WHY IT CANNOT BE MACHINE-VETTED: Hy-Vee publishes no per-product department, and the CATEGORY facet its
# search response exposes is SILENTLY IGNORED when passed back as a filter (three request shapes tried, all
# returned the identical unfiltered results with a cat litter still in "baking soda"). Measured on the first
# live run: ~14% of candidates are WRONG PRODUCTS. So the section must rank and explain, never pass.
$proArgs = @('-CompareFile', (Join-Path $fix 'arrivals-clean-board.json'), '-BaselineDir', (Join-Path $fix 'arrivals-baseline'),
  '-CommoditiesFile', (Join-Path $fix 'arrivals-commodities.json'), '-DiscoveryFile', (Join-Path $fix 'arrivals-prospects.json'),
  '-VerdictsFile', (Join-Path $fix 'arrivals-prospect-verdicts.json'),
  '-OutFile', (Join-Path $env:TEMP ('arrdock-' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.json')))
$rp = RunPS 'build-arrivals-docket.ps1' $proArgs
# MUST FIRE: the 2026-07-28 bath soap, re-staged as a PROSPECT. It has to rank first, carry div 1.00 from the
# head cut, and be named a crown-taker - a prospect that cannot win changes no shopper's price, so that
# distinction is the severity signal the reader sorts on.
if ($rp.text -match 'FLAG#1' -and $rp.text -match "Dr Teal" -and $rp.text -match 'div=1\.00' -and $rp.text -match 'TAKES CROWN') {
  Ok 'prospects: the bath-soap-as-coconut-oil candidate ranks FIRST, div 1.00, named as a crown-taker'
} else { Bad ('prospects MISSED the founding wrong product (head cut, ranking or crown arithmetic broken): ' + $rp.text) }
# MUST FIRE, INDEPENDENTLY: 34 FLUID ounces divided into a commodity priced per WEIGHT ounce. This is the
# defect that made a Pasta Roni vermicelli "beat" olive oil by 21.8% on the first live docket - a REAL price
# on a FALSE basis, where every number in the row is individually defensible. Divergence and basis are
# separate detectors on purpose; the vermicelli scored only 0.50 and the floor would have missed it.
if ($rp.text -match 'BASIS' -and $rp.text -match 'names a VOLUME') { Ok 'prospects: a size in fluid ounces against a per-weight commodity is flagged as a BASIS defect' }
else { Bad ('prospects passed a false basis - the saving is arithmetic, not money: ' + $rp.text) }
# MUST BE SILENT: a real coconut oil, right basis, same store, same docket, also beating the held price.
if ($rp.text -match 'ctx #2' -and $rp.text -match 'Nutiva' -and $rp.text -match 'no crown') { Ok 'prospects: the real coconut oil is listed as context, unflagged, and correctly reads no crown' }
else { Bad ('prospects flagged a correct product or got the crown arithmetic wrong - it is scoring novelty, not divergence: ' + $rp.text) }
# MUST FIRE: a candidate a human already ruled on must LEAVE the queue and still be COUNTED. A settled
# candidate that silently vanishes is indistinguishable from a discovery run that stopped working.
if ($rp.text -match 'PROSPECTS awaiting a ruling: 2 \(1 would take a crown, 1 flagged, 1 already ruled\)' -and $rp.text -notmatch 'Blue Buffalo') {
  Ok 'prospects: the already-ruled cat-food candidate leaves the queue and is counted as settled, not dropped'
} else { Bad ('prospects re-asked a settled question, or dropped it without counting it: ' + $rp.text) }
# MUST FIRE: no docket on disk is NOT "no candidates". Discovery not having run and discovery finding nothing
# are different facts and must never print the same.
$rp2 = RunPS 'build-arrivals-docket.ps1' @('-CompareFile', (Join-Path $fix 'arrivals-clean-board.json'), '-BaselineDir', (Join-Path $fix 'arrivals-baseline'),
  '-CommoditiesFile', (Join-Path $fix 'arrivals-commodities.json'), '-DiscoveryFile', (Join-Path $fix 'no-such-discovery-docket.json'),
  '-VerdictsFile', (Join-Path $fix 'arrivals-prospect-verdicts.json'),
  '-OutFile', (Join-Path $env:TEMP ('arrdock-' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.json')))
if ($rp2.text -match 'BLIND' -and $rp2.text -match 'discovery has not run') { Ok 'prospects: a missing docket reports BLIND rather than a clean zero' }
else { Bad ('prospects turned a missing discovery docket into "no candidates": ' + $rp2.text) }
# MUST FIRE: the prospects section must not overwrite the ARRIVALS baseline-adequacy reason. Shipped and
# caught the same day: the loop reused $why, the docket-level variable, so a run with no baseline printed
# "DEGRADED: no-board-row for ketchup" and its exit-3 line named the wrong reason entirely - a check that
# reports the wrong cause of its own blindness sends the reader to the wrong bug. Same clobber family as
# $Matches being global in PS 5.1. A prospect whose commodity is off this board forces the collision.
$rp3 = RunPS 'build-arrivals-docket.ps1' @('-CompareFile', (Join-Path $fix 'arrivals-mustfire-board.json'), '-BaselineDir', (Join-Path $fix 'arrivals-baseline'),
  '-CommoditiesFile', (Join-Path $fix 'arrivals-commodities.json'), '-DiscoveryFile', (Join-Path $fix 'arrivals-prospects-offboard.json'),
  '-VerdictsFile', (Join-Path $fix 'arrivals-prospect-verdicts.json'), '-N', '0',
  '-OutFile', (Join-Path $env:TEMP ('arrdock-' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.json')))
if ($rp3.text -match 'DEGRADED: ZERO baseline boards' -and $rp3.text -match 'no-board-row') {
  Ok 'prospects: an off-board prospect is reported as unscorable WITHOUT overwriting the docket-level DEGRADED reason'
} else { Bad ('the prospects loop clobbered the arrivals baseline-adequacy reason again: ' + $rp3.text) }
# The fixtures must stay frozen. Both were authored from the founding cases, not from a live docket, and a
# fixture regenerated from live data proves only that the code agrees with itself.
$rpF = @((Get-Content (Join-Path $fix 'arrivals-prospects.json') -Raw) + (Get-Content (Join-Path $fix 'arrivals-prospect-verdicts.json') -Raw))
if ($rpF -match 'NEVER regenerate' -and $rpF -match '9990003') { Ok 'prospects fixtures are still the frozen founding cases' }
else { Bad 'the prospects fixtures were regenerated - they no longer pin the founding wrong products' }

# MUST FIRE: the docket is a QUEUE, not a report of the last slice. discover-hyvee walks a BOUNDED ROTATION
# (40 of 526 terms), and it used to overwrite the file - so a candidate nobody adjudicated before the cursor
# moved on vanished until the rotation came back around ~13 days later. Caught the first time discovery ran
# twice: a 12-term slice replaced 11 open candidates (That's Smart! peanut butter at -33.4%, ketchup at -29%)
# with 2. Source-scanned because reproducing it needs two live network runs.
$dhSrc = Get-Content (Join-Path $root 'discover-hyvee.ps1') -Raw
$dhMergeAt = $dhSrc.IndexOf('MERGE, NEVER OVERWRITE')
$dhWriteAt = $dhSrc.IndexOf('($docket.ToArray() | ConvertTo-Json')
if ($dhMergeAt -gt 0 -and $dhWriteAt -gt $dhMergeAt -and $dhSrc -match '\$docket\.Add\(\$p\); \$carried\+\+') {
  Ok 'discovery docket MERGES the open queue forward instead of overwriting it with the current slice'
} else { Bad 'discover-hyvee overwrites its docket again - every unadjudicated candidate outside the current 40-term slice is being discarded' }
# MUST FIRE, the ordering half of the cycle wiring: the desk reads the docket, so discovery has to run first.
$cacSrc = Get-Content (Join-Path $root 'check-ad-cycles.ps1') -Raw
$cacDisc = $cacSrc.IndexOf("'discover-hyvee.ps1'")
$cacArr  = $cacSrc.IndexOf("'build-arrivals-docket.ps1'")
if ($cacDisc -gt 0 -and $cacArr -gt $cacDisc) { Ok 'the cycle runs discover-hyvee BEFORE the arrivals desk that reads its docket' }
else { Bad 'check-ad-cycles builds the arrivals docket before discovery writes it - the PROSPECTS section will always show yesterday' }

# the verdict intake itself: 14 hermetic checks, including that ACCEPT writes a work-list row and not a price
$r = RunPS 'adjudicate-discovery.ps1' @('-SelfTest')
if ($r.rc -eq 0 -and $r.text -match 'SELFTEST: all') { Ok ('adjudicate-discovery self-test: ' + (($r.text -split "`n" | Where-Object { $_ -match 'SELFTEST: all' }) -join '')) }
else { Bad ('adjudicate-discovery self-test FAILED: ' + $r.text) }

# ---------------------------------------------------------------- N3. recipe-board product identity
# MUST FIRE: recipe-board store rows carried {store, per_unit, type, bulk} and nothing else. derive-recipe-
# floors CHOSE a product to price each cell from and threw its identity away, so nothing downstream could
# match those cells: resolve-hyvee-links matches BY SIZE FIRST and logged "no size match (ours: / )" -
# correctly REFUSING rather than guess, which is the founding minced-garlic fix (board published 32 oz while
# the link opened 4.5 oz) - and guard 3 reported 10 pins whose board cell has no product name to check.
# The fixture is COPIED to a temp dir first: this script writes its proposal and report into -OutDir, and a
# fixture run must never write where the live run writes.
$fxRf = Join-Path $env:TEMP ('taudit-rf-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $fxRf -Force | Out-Null
Copy-Item (Join-Path $fix 'recipe-floors\*.json') $fxRf -Force
$r = RunPS 'derive-recipe-floors.ps1' @('-Root', $fxRf, '-OutDir', $fxRf)
$rfProp = $null
try { $rfProp = ((Get-Content (Join-Path $fxRf 'recipe-floors-proposed.json') -Raw) + '').Trim() | ConvertFrom-Json } catch {}
function RfCell($id, $store) {
  foreach ($row in @($rfProp.comparison)) { if ([string]$row.id -eq $id) { foreach ($s in @($row.stores)) { if ([string]$s.store -eq $store) { return $s } } } }
  return $null
}
$mg = RfCell 'minced-garlic' 'Hy-Vee'
# The cheapest everyday candidate is the 32 oz jar at the SAME per-unit the row already held, so this also
# pins that identity is stamped when the PRICE DOES NOT MOVE - 313 live cells sat at an unchanged price with
# no product name, and a fix that only stamped changed cells would have left them exactly as they were.
if ($mg -and [string]$mg.item -eq 'Spice World Minced Garlic' -and [string]$mg.size -eq '32 oz') {
  Ok 'recipe floors: a cell is stamped with the product its price came from, even when the price is unchanged'
} else { Bad ('recipe-board rows are being written without product identity again: ' + ($mg | ConvertTo-Json -Compress)) }
# MUST FIRE: an EMPTY size is written as NOTHING. '' is exactly what produces the resolver's "ours: / " and
# it reads as an answer; absent reads as the question it is.
$rb2 = RfCell 'rye-bread' 'Hy-Vee'
if ($rb2 -and [string]$rb2.item -eq 'Hy-Vee Jewish Rye Bread' -and -not ($rb2.PSObject.Properties.Name -contains 'size')) {
  Ok 'recipe floors: a candidate with no size writes NO size rather than an empty one the resolver would read as an answer'
} else { Bad ('an empty size was written as a real size - the resolver will match against nothing: ' + ($rb2 | ConvertTo-Json -Compress)) }
# MUST FIRE: identity travels WITH the price or not at all. A row nothing re-prices keeps its old number, so
# it must NOT be handed a product name - that name would describe a price that came from somewhere else,
# which is the wrong-basis class (a real product attached to a real price that is not its own).
$nr = RfCell 'no-refresh-path' 'Hy-Vee'
if ($nr -and -not ($nr.PSObject.Properties.Name -contains 'item') -and $r.text -match 'no-board-match') {
  Ok 'recipe floors: a row with no candidate keeps its price AND gets no invented identity'
} else { Bad ('identity was stamped onto a cell whose price came from somewhere else: ' + ($nr | ConvertTo-Json -Compress)) }
if ((Get-Content (Join-Path $fix 'recipe-floors\recipe-board-everyday.json') -Raw) -match 'NEVER regenerate') { Ok 'recipe-floors fixture is still the frozen identity gap' }
else { Bad 'the recipe-floors fixture was regenerated - it no longer pins the shape the bug lived in' }
# MUST FIRE: a recipe-only row the staples board cannot price falls back to the RECIPE pool. Founding case -
# boneless-skinless-chicken-thigh @ Hy-Vee held the recipe-board CROWN at $1.99/lb while the store charged
# $3.996, because no staples commodity matches that cut so nothing re-priced it since 2026-07-12.
$rp = RfCell 'recipe-pool-only' 'Hy-Vee'
if ($rp -and [double]$rp.per_unit -eq 3.996 -and [string]$rp.item -eq 'Tyson Boneless Skinless Chicken Thighs') {
  Ok 'recipe floors: a row with no staples twin is priced (and named) from the recipe pool instead of sitting frozen'
} else { Bad ('the recipe-pool fallback stopped reaching a recipe-only row - it will sit frozen again: ' + ($rp | ConvertTo-Json -Compress)) }
# MUST FIRE: the pool is a SECOND-CLASS source and every cell from it is reported for review, never blended
# into the staples count. Measured before use: 7 of 10 diverging cells were WRONG PRODUCTS (Mt. OLIVE pickles
# as olives, Oreo Zero Sugar COOKIES as zero-sugar-soda, apple JUICE and Gerber baby food as apple).
$rfRep = $null
try { $rfRep = ((Get-Content (Join-Path $fxRf 'recipe-floors-report.json') -Raw) + '').Trim() | ConvertFrom-Json } catch {}
if ($rfRep -and @($rfRep.recipe_pool_cells).Count -ge 1 -and (@($rfRep.recipe_pool_ids) -contains 'recipe-pool-only') -and $r.text -match 'RECIPE POOL') {
  Ok 'recipe floors: every cell priced from the recipe pool is reported separately for review, not blended in'
} else { Bad 'the recipe pool is being used without being declared - a second-class source is passing as a staples-derived one' }
# MUST FIRE: the fallback removes the MAPPING question, not the BASIS one. A pool entry whose unit differs
# from the row's is still refused - the brown-sugar 16x lesson.
$wu = RfCell 'wrong-unit-pool' 'Hy-Vee'
if ($wu -and [double]$wu.per_unit -eq 1.49 -and -not ($wu.PSObject.Properties.Name -contains 'item')) {
  Ok 'recipe floors: a pool entry in a different unit is REFUSED, price and identity both untouched'
} else { Bad ('the fallback took a price across an unreconciled unit - a real number on a false basis: ' + ($wu | ConvertTo-Json -Compress)) }
Remove-Item $fxRf -Recurse -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------- N4. multipack SIZE REPAIR
# The repair half of guard 5. Its 8 hermetic cases include the two that decide whether it is safe at all:
# the founding Heinz row must repair (name states 2 x 50.5 oz, feed returned one bottle, $0.2968/oz against
# a true $0.1484), and guard 5's OWN founding bug must still be REFUSED ("ReaLemon 100% Lemon Juice (2 pk)",
# size "48 fl oz", no per-unit weight in the name) - inventing a total there is guessing at the exact point
# the guard exists to stop guessing. It also round-trips through Test-MpClassify, so a repair that does not
# actually satisfy the gate it was written for cannot pass.
$r = RunPS 'repair-multipack-sizes.ps1' @('-SelfTest')
if ($r.rc -eq 0 -and $r.text -match 'SELFTEST: all') { Ok ('multipack size repair self-test: ' + (($r.text -split "`n" | Where-Object { $_ -match 'SELFTEST: all' }) -join '')) }
else { Bad ('multipack size repair self-test FAILED: ' + $r.text) }
# MUST FIRE: a repair that writes a size guard 5 still rejects is decoration. Pinned as a pair here as well
# as inside the self-test, because THIS suite is what runs daily.
. (Join-Path $root 'multipack-lib.ps1')
$mpBad = 'Heinz Tomato Ketchup, 2 Pack 50.5 Oz'
$mpFix = Get-MpRepairedSize $mpBad '50.5 oz'
if ((Test-MpClassify 'Family Fare' $mpBad '50.5 oz' @()) -eq 'reject' -and $mpFix -eq '2 pk 50.5 oz' -and (Test-MpClassify 'Family Fare' $mpBad $mpFix @()) -ne 'reject') {
  Ok 'multipack repair and guard 5 agree: the rejected row repairs, and the repaired row passes'
} else { Bad ('the repair and the guard have drifted apart - repaired size was [' + $mpFix + ']') }

# ---------------------------------------------------------------- N5. rule-batch gate (apply-coverage-batch)
# MUST FIRE, and it is a source scan because the bug is an ORDERING one that a unit test cannot see.
# The theft baseline used to be whatever comparison-<date>.json happened to be on disk. Store pulls run on
# their own schedules, so any feed refreshed since that file was written appears as a moved cell the moment
# compare-deals runs again - and verify-no-regression blames the batch. MEASURED 2026-08-01: with the rule
# edit fully REVERTED and nothing changed at all, the check still reported 6 moved Family Fare cells
# (coffee-creamer, english-muffins, ground-cinnamon, honey, hot-dogs, pepperoni) and 3 gained ones, purely
# because a Family Fare pull had landed after the board file was written. A one-word exclude on dried-thyme
# cannot move pepperoni. It is invisible at crown level too - none of the six held a crown - so a crown diff
# reports "0 changed" and looks clean. Any batch run in that window was auto-reverted on merit it never
# lacked, which is the same shape as the visibility gate that had to be rebuilt twice.
$acbSrc = Get-Content (Join-Path $root 'apply-coverage-batch.ps1') -Raw
$acbRebuildAt = $acbSrc.IndexOf('rebuilding the board under the CURRENT rules')
$acbFreezeAt  = $acbSrc.IndexOf('$baseCmp = Join-Path $OutDir ''_baseline-batch.json''')
if ($acbRebuildAt -gt 0 -and $acbFreezeAt -gt $acbRebuildAt) { Ok 'rule-batch gate rebuilds the board BEFORE freezing its theft baseline (a stale baseline reverts correct work)' }
else { Bad 'apply-coverage-batch freezes a theft baseline it did not just rebuild - an unrelated feed refresh will be blamed on the batch and revert it' }
# MUST FIRE: an empty batch would run every gate and prove nothing.
$r = RunPS 'apply-coverage-batch.ps1' @()
if ($r.rc -eq 1 -and $r.text -match 'empty batch would run every gate') { Ok 'rule-batch gate refuses an empty batch instead of reporting a clean run over nothing' }
else { Bad ('apply-coverage-batch accepted an empty batch (rc=' + $r.rc + '): ' + $r.text) }
# MUST FIRE, cheaply and BEFORE the expensive baseline rebuild: a pattern that does not compile matches
# nothing, so the batch would read as "bought nothing" rather than "was never a rule". Same family as a
# typo'd commodity id, which is checked beside it.
$acbBadRx = & powershell -NoProfile -ExecutionPolicy Bypass -Command "& { `$ErrorActionPreference='Continue'; & '$(Join-Path $root 'apply-coverage-batch.ps1')' -Excludes @{ 'dried-thyme' = @('local(\s+roots') } 2>&1 | Out-String; exit `$LASTEXITCODE }"
if ($LASTEXITCODE -eq 1 -and $acbBadRx -match 'not a valid regex' -and $acbBadRx -notmatch 'rebuilding the board') {
  Ok 'rule-batch gate rejects an uncompilable pattern BEFORE it spends a compare-deals on it'
} else { Bad ('apply-coverage-batch let an uncompilable pattern through, or only caught it after the baseline rebuild: ' + $acbBadRx) }
$acbBadId = & powershell -NoProfile -ExecutionPolicy Bypass -Command "& { `$ErrorActionPreference='Continue'; & '$(Join-Path $root 'apply-coverage-batch.ps1')' -Excludes @{ 'no-such-commodity-xyz' = @('foo') } 2>&1 | Out-String; exit `$LASTEXITCODE }"
if ($LASTEXITCODE -eq 1 -and $acbBadId -match 'can never fire') { Ok 'rule-batch gate rejects a batch on a commodity id that does not exist' }
else { Bad ('apply-coverage-batch accepted a non-existent commodity id: ' + $acbBadId) }
# MUST FIRE: the batch's link repair must not reach past the commodities it edited. Called in bulk,
# resolve-hyvee-links rewrote every Hy-Vee link on the board as a side effect of a ONE-commodity exclude and
# re-introduced the poultry-seasoning divergence, failing the publish on a row the batch never touched.
$acbSrcHv = [regex]::Match($acbSrc, "resolve-hyvee-links\.ps1'\)\s*@hvArgs")
if ($acbSrcHv.Success -and $acbSrc -match '\$hvArgs = @\{ Ids = @\(\$TouchedIds\) \}') { Ok 'rule-batch link repair calls resolve-hyvee-links SCOPED to the batch, not in bulk' }
else { Bad 'apply-coverage-batch runs a BULK resolve-hyvee-links in its repair chain again - a one-commodity edit will rewrite every Hy-Vee link' }

# ---------------------------------------------------------------- N10. sample scope (C3)
# MUST FIRE: a STORE-SCOPED verification draw and a WHOLE-BOARD draw sample different populations, and
# pooling them yields a number that describes neither. Measured the first time a scoped sample was recorded
# (Aldi+Fareway, 2026-08-01): it pooled straight into the previous whole-board run and reported 14 defects -
# Sam's Club, Hy-Vee, Family Fare and Walmart cells among them - against a 760-cell Aldi+Fareway
# denominator. A numerator drawn from outside its own denominator is not a rate.
$vsSrc = Get-Content (Join-Path $root 'build-verification-sample.ps1') -Raw
if ($vsSrc -match 'store_scope\s*=') { Ok 'verification sample records WHICH population it estimates (store scope)' }
else { Bad 'build-verification-sample no longer records store_scope - a scoped draw will pool into a whole-board one and quote a rate for neither' }
$rsSrc = Get-Content (Join-Path $root 'record-sample-verdict.ps1') -Raw
if ($rsSrc -match 'DROPPED ' -and $rsSrc -match 'RunScope' -and $rsSrc -match '\$scopeWanted') {
  Ok 'verdict recorder pools only same-population runs and NAMES the ones it drops'
} else { Bad 'record-sample-verdict pools runs of different store scope again - it will average a scoped sample into a whole-board one' }
# and the live history must not contain a run with no scope recorded
$vhP = Join-Path $root 'out\verification-history.json'
if (Test-Path $vhP) {
  $vh = $null; try { $vh = ((Get-Content $vhP -Raw) + '').Trim() | ConvertFrom-Json } catch {}
  $noScope = @(@($vh.runs) | Where-Object { -not ($_.PSObject.Properties['store_scope']) })
  if ($noScope.Count -eq 0) { Ok 'every banked verification run declares the population it estimates' }
  else { Bad ('verification history holds ' + $noScope.Count + ' run(s) with no store_scope - they will pool with anything') }
}

# ---------------------------------------------------------------- N9. public feeds are BOM-less (L7)
# Set-Content -Encoding UTF8 emits a UTF-8 BOM in PS 5.1. Browsers strip it per spec, so the live page was
# never broken - but PS 5.1's OWN ConvertFrom-Json chokes on it, which is how a verification pass reported
# the public feed "malformed" when it was fine and spent the morning on a non-bug. Our own tooling must be
# able to read what we publish. Source-scanned because the live files only lose their BOM on the next
# publish, so a file check would fail for a day and then pass for the wrong reason.
foreach ($bw in @(
    @{ f = 'grocery\build-deals-page.ps1'; n = 'price-history.json'; pat = '\[IO\.File\]::WriteAllText\(\$histOut' }
    @{ f = 'grocery\build-deals-page.ps1'; n = 'board.json'; pat = '\[IO\.File\]::WriteAllText\(\$boardOut' }
    @{ f = 'grocery\export-feed.ps1'; n = 'smp-feed.json'; pat = "\[IO\.File\]::WriteAllText\(\(Join-Path \`$pub 'smp-feed\.json'\)" }
    @{ f = 'meal-prep\rotate-free-dinners.ps1'; n = 'free-dinners.json'; pat = "\[IO\.File\]::WriteAllText\(\(Join-Path \`$pubDir 'free-dinners\.json'\)" }
  )) {
  $bwTxt = Get-Content (Join-Path (Split-Path $root -Parent) $bw.f) -Raw
  if ($bwTxt -match $bw.pat) { Ok ('public feed ' + $bw.n + ' is written BOM-less (PS 5.1 cannot parse its own BOM)') }
  else { Bad ('public feed ' + $bw.n + ' is back on Set-Content -Encoding UTF8, which writes a BOM our own ConvertFrom-Json cannot read') }
}

# ---------------------------------------------------------------- N8. multi-term search (F3)
# 210 of 429 commodities have a Family Fare product name that does not contain our single search term, so
# one term per commodity is structurally unable to reach them. commodity-search.json now allows an ARRAY.
# THE WHOLE DANGER IS THAT AN ARRAY DOES NOT FAIL, IT JOINS: `[string]$_.Value` turns
# ["popsicles","ice pops"] into the one search "popsicles ice pops", which matches nothing while looking
# exactly like an ordinary term that found nothing - and 23 scripts read that file.
. (Join-Path $root 'search-terms-lib.ps1')
$stFix = [pscustomobject]@{ 'popsicles' = @('popsicles', 'ice pops'); 'apples' = 'apples'; 'empty-one' = ''; 'dead-array' = @('', '  ') }
$stPairs = @(Get-SearchTermPairs $stFix)
if (@($stPairs | Where-Object { $_.id -eq 'popsicles' }).Count -eq 2 -and @($stPairs | Where-Object { $_.id -eq 'apples' }).Count -eq 1) {
  Ok 'search terms: an array expands to real separate searches and a plain string still yields exactly one'
} else { Bad ('search-term expansion is wrong - a multi-term commodity is not producing separate searches: ' + (($stPairs | ForEach-Object { $_.id + '=' + $_.term }) -join '; ')) }
if (@($stPairs | Where-Object { $_.id -eq 'empty-one' -or $_.id -eq 'dead-array' }).Count -eq 0) { Ok 'search terms: an empty term produces NO search rather than a blank one that would match the whole catalogue' }
else { Bad 'an empty search term is being issued as a real search' }
# MUST FIRE: the primary term is what every single-string consumer gets, and it must be the FIRST one, so
# a chip q= or a worklist label is identical to what it was before arrays existed.
if ((Get-PrimarySearchTerm $stFix 'popsicles') -eq 'popsicles' -and (Get-PrimarySearchTerm $stFix 'apples') -eq 'apples' -and (Get-PrimarySearchTerm $stFix 'nope') -eq '') {
  Ok 'search terms: single-string consumers get the FIRST term, never the joined one, and a missing id yields empty'
} else { Bad 'Get-PrimarySearchTerm is not returning the stable first term - single-term consumers will search a joined string' }
# MUST FIRE, and this is the one that matters: NO consumer may still cast the terms object to a string.
# That cast is silent, so nothing downstream could ever report it.
# CODE LINES ONLY. The comments that explain this trap quote the offending cast verbatim, so a whole-file
# regex flags the very files that fixed it - a scan that cannot tell an explanation from an instance.
$stOffenders = @()
foreach ($sf in (Get-ChildItem (Join-Path $root '*.ps1') -File)) {
  if ($sf.Name -eq 'search-terms-lib.ps1' -or $sf.Name -eq 'test-auditors.ps1') { continue }
  $sTxt = Get-Content $sf.FullName -Raw
  if ($sTxt -notmatch 'commodity-search\.json') { continue }
  $bad = @(Get-Content $sf.FullName | Where-Object {
      $ln = $_.Trim()
      if ($ln.StartsWith('#')) { return $false }
      ($ln -match '\[string\]\$p\.Value' -and $ln -match '\$term') -or ($ln -match '\[string\]\$terms\.\$id') -or ($ln -match '\[string\]\$_\.Value' -and $ln -match '\$term')
    })
  if ($bad.Count) { $stOffenders += ($sf.Name + ' (' + $bad.Count + ')') }
}
if ($stOffenders.Count -eq 0) { Ok 'search terms: no consumer of commodity-search.json casts a term value to a string (an array would JOIN, not fail)' }
else { Bad ('these readers of commodity-search.json still flatten a term value, so a multi-term commodity becomes one dead search: ' + ($stOffenders -join ', ')) }
# the live file must stay usable by the lib
$stLive = (Get-Content (Join-Path $root 'commodity-search.json') -Raw | ConvertFrom-Json).terms
$stLiveFindings = @(Test-SearchTermShape $stLive)
if ($stLiveFindings.Count -eq 0) { Ok 'search terms: the live commodity-search.json has no empty terms and no degenerate arrays' }
else { Bad ('commodity-search.json shape findings: ' + ($stLiveFindings -join ' | ')) }

# ---------------------------------------------------------------- N7. the coverage ratchet's own config
# F4 asked for tolerances narrowed "from the week's accumulated ledger data" and there WAS none - the ledger
# is a single overwritten snapshot, so every tolerance had been hand-seeded from one green run with no
# reason recorded. These pin the three defects that turned up while looking.
$fxCl = Join-Path $env:TEMP ('taudit-cl-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $fxCl -Force | Out-Null
Copy-Item (Join-Path $fix 'coverage-ledger\coverage-ledger.json') $fxCl -Force
$clBase = Join-Path $fxCl 'coverage-baseline.json'
Copy-Item (Join-Path $fix 'coverage-ledger\coverage-baseline.json') $clBase -Force
$r = RunPS 'audit-coverage-ledger.ps1' @('-OutDir', $fxCl, '-BaselineFile', $clBase, '-Phase', 'all')
# MUST FIRE: a tolerance of 1.0 puts the regression floor at 0, and BLIND already owns everything <= 0, so
# REGRESSED can never fire. Two live checks shipped in that state - the gates-that-can-never-arm class.
if ($r.text -match 'DEAD-RATCHET\s+dead-ratchet-check') { Ok 'coverage ratchet reports a tolerance that makes its own REGRESSED verdict structurally unfirable' }
else { Bad ('a dead ratchet (tolerance 1.0, floor 0) passed as ok: ' + $r.text) }
# MUST FIRE: an override with no reason cannot be reviewed or narrowed later, which is exactly why F4 had
# nothing to narrow FROM.
if ($r.text -match 'UNJUSTIFIED TOLERANCE: unjustified-check') { Ok 'coverage ratchet reports a tolerance override that records no reason' }
else { Bad ('an undocumented tolerance override passed silently: ' + $r.text) }
# MUST FIRE: -Accept must RAISE only. Lowering on one bad run makes the rows it stopped looking at
# unguarded forever - it would have baked in audit-ff-carry at 40 against a 464 baseline (91% lost).
$r2 = RunPS 'audit-coverage-ledger.ps1' @('-OutDir', $fxCl, '-BaselineFile', $clBase, '-Phase', 'all', '-Accept')
$clAfter = ((Get-Content $clBase -Raw) + '').Trim() | ConvertFrom-Json
if ([int]$clAfter.checks.'shrunk-check'.examined -eq 1000 -and $r2.text -match 'KEPT HIGH') {
  Ok '-Accept RAISES the coverage ratchet but refuses to lower it, and names the rows it kept high'
} else { Bad ('-Accept silently lowered a high-water mark - the coverage it stopped watching is now unguarded forever: ' + [string]$clAfter.checks.'shrunk-check'.examined) }
# ...and -AcceptLower is the explicit way to do it on purpose.
$r3 = RunPS 'audit-coverage-ledger.ps1' @('-OutDir', $fxCl, '-BaselineFile', $clBase, '-Phase', 'all', '-Accept', '-AcceptLower')
$clAfter2 = ((Get-Content $clBase -Raw) + '').Trim() | ConvertFrom-Json
if ([int]$clAfter2.checks.'shrunk-check'.examined -eq 40 -and $r3.text -match 'LOWERED') { Ok '-AcceptLower lowers the ratchet deliberately and says which rows it moved down' }
else { Bad '-AcceptLower did not lower the baseline, so a real permanent drop can never be accepted' }
Remove-Item $fxCl -Recurse -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------- N6. Hy-Vee link price provenance
# MUST FIRE: the link's stored price must be the one the BOARD priced, never the search endpoint's.
# Hy-Vee publishes several prices per product and only Omaha #01's is the one it charges - the whole reason
# pull-regular-hyvee exists - and resolve-hyvee-links was stamping the SEARCH API's tagPriceValue beside the
# link. Measured on poultry-seasoning, the row that re-introduced the consistency divergence THREE times and
# was written off as an unexplained "quality problem": right product (Morton & Bassett, 2.1 oz, same name and
# size the board holds), stamped $9.99 while the feed the board priced says $5.81. 9.99/2.1 = $4.7571/oz vs
# 5.81/2.1 = $2.7667/oz, and guard 1 hard-failed the publish at 1.72x. Nothing was wrong with the MATCH.
# It survived because the match gate accepts price agreement OR an overwhelming name match, so an identical
# name lets a disagreeing price straight through unchecked.
$rhvSrc = Get-Content (Join-Path $root 'resolve-hyvee-links.ps1') -Raw
if ($rhvSrc -match '\$price = if \(\$ourPrice -gt 0\) \{ \$ourPrice \}' -and $rhvSrc -notmatch '(?m)^\s*\$price = \[double\]\$best\.pricing\.tagPriceValue\s*$') {
  Ok 'resolve-hyvee-links stores the price the BOARD priced, not the search endpoint''s (the poultry-seasoning root cause)'
} else { Bad 'resolve-hyvee-links is stamping the search API price beside a link again - that is the wrong one of Hy-Vee''s several prices and it hard-fails the factor guard' }

# ---------------------------------------------------------------- (u) store-taxonomy: the second opinion
# The ONLY watcher that does not inherit the include regex's premise. Its founding bug is the class that
# produced 47 of the 99 wrong numbers in 22 days: Family Fare's own catalogue files "Blue Buffalo Natural
# Puppy Chicken And Brown Rice Recipe Food For Puppies" under pets_wildlife/dog/dry_dog_food while our
# brown-rice include claims it is brown rice. Its fixtures are frozen strings from 2026-07-30 and must never
# be regenerated from a later board.
$r = RunPS 'audit-store-taxonomy.ps1' @('-SelfTest')
if ($r.rc -eq 0 -and $r.text -match 'MUST-FIRE' -and $r.text -match 'SELF-TEST PASS') { Ok 'store-taxonomy -SelfTest passes with its founding-bug fixtures armed' }
else { Bad ('store-taxonomy -SelfTest failed or lost its founding-bug fixtures: ' + ((($r.text -split "`n") | Select-Object -Last 3) -join ' | ')) }
$stSrc = Get-Content (Join-Path $root 'audit-store-taxonomy.ps1') -Raw
if ($stSrc -match 'blue_buffalo_natural_puppy') { Ok 'the Blue Buffalo dog-food-as-brown-rice row is still the must-fire fixture' }
else { Bad 'store-taxonomy lost its Blue Buffalo fixture - the wrong-product class it was written for is no longer proven catchable' }
if ($stSrc -match 'kraft_grated_cheese_parmesan_cheese_8_oz') { Ok 'the taxonomy-less-URL trap (3 live rows) is still pinned - a slug must never be read as a department' }
else { Bad 'store-taxonomy lost the taxonomy-less-URL fixture - it can invent a department for a row that carries none' }

# ---------------------------------------------------------------- (u2) ff-carry: the fixtures nobody could reach
# 2026-07-31. audit-ff-carry got a full frozen fixture block (own-feed-coverage MUST-FIRE/CLEAN-TWIN, plus the
# multi-buy cheapest-pick pair) guarded by `if ($SelfTest)` - and the matching `[switch]$SelfTest` never landed
# on its param(). $SelfTest was permanently $null, so the block was unreachable dead code. Worse, under -File
# an undeclared -SelfTest does NOT error (it lands in $args), so `audit-ff-carry.ps1 -SelfTest` quietly ran the
# LIVE network audit and looked like it worked. Second half of the same bug: the pull-state early exits sat
# ABOVE the block, so even once reachable, a -SelfTest run on a day with no FF file - or no empty terms, the
# HEALTHY state - printed SKIP/OK and exited 0 having executed zero fixtures.
# Both halves are checked structurally BEFORE invoking, because the invocation alone cannot tell the
# difference between "fixtures passed" and "fixtures were skipped" if the script regresses to exiting early.
$ffcS = Get-Content (Join-Path $root 'audit-ff-carry.ps1') -Raw
if ($ffcS -match '\[switch\]\$SelfTest') { Ok 'audit-ff-carry declares [switch]$SelfTest (its fixture block is reachable at all)' }
else { Bad 'audit-ff-carry has an if ($SelfTest) block with no [switch]$SelfTest on param() - the fixtures are dead code again, and -SelfTest silently runs the LIVE audit instead of erroring' }
$ffcSelfIdx = $ffcS.IndexOf('if ($SelfTest) {')
$ffcGateIdx = $ffcS.IndexOf('ff-carry: SKIP (no FF regular file)')
if ($ffcSelfIdx -ge 0 -and $ffcGateIdx -ge 0 -and $ffcGateIdx -lt $ffcSelfIdx -and $ffcS -notmatch 'if \(-not \$SelfTest\) \{') {
  Bad 'audit-ff-carry pull-state exits are back above its fixture block and no longer skipped under -SelfTest - a self-test run on a healthy day exits 0 without running one fixture'
} else { Ok 'audit-ff-carry skips its pull-state exits under -SelfTest (fixtures run in every data state)' }
# Hermetic: -OutDir points at an empty scratch dir, so a PASS here proves the fixtures ran WITHOUT an FF file
# present. That is precisely the state that used to fake a pass, so it doubles as the regression test.
$ffcOut = Join-Path $env:TEMP ('ffc-selftest-' + [guid]::NewGuid().ToString('N').Substring(0,8))
$null = New-Item -ItemType Directory -Path $ffcOut -Force
$r = RunPS 'audit-ff-carry.ps1' @('-SelfTest', '-OutDir', $ffcOut)
if ($r.rc -eq 0 -and $r.text -match 'SELF-TEST PASS') { Ok 'ff-carry -SelfTest passes with NO FF file present (fixtures are data-state independent)' }
else { Bad ('ff-carry -SelfTest failed or skipped with no FF file: rc=' + $r.rc + ' ' + ((($r.text -split "`n") | Select-Object -Last 3) -join ' | ')) }
if ($ffcS -match 'Our Family Chili Beans') { Ok 'the chili-beans own-feed-coverage fixture is still armed (the 15-of-24 false-positive class)' }
else { Bad 'ff-carry lost its chili-beans fixture - the "already priced in this very pull" false-positive class is no longer proven catchable' }
if ($ffcS -match '4 for \$5\.00') { Ok 'the multi-buy cheapest-pick fixture is still armed ("4 for $5.00" must not read as 45)' }
else { Bad 'ff-carry lost the multi-buy fixture - the digit-stripping bug that made $5.00 look like $45 is unguarded' }

# THE ZERO-PROBE FALSE OK (2026-07-31, caught live). Every Freshop call sits in an empty catch, so a
# throttled window returns nothing for all of them, $victims stays empty, and ff-carry printed the same
# confident "OK no term is missing from the feed" as a run that really checked 123 terms. Observed:
# "ff-carry: OK ... (0 of 466 empty term(s) re-probed)" exit 0, with the coverage ledger beside it saying
# BLIND. It now exits 3 instead. Two things can rot: the gate keying off the WRONG count, and the caller
# re-flattening exit 3 into a crash report. Both are source checks - the behaviour needs a throttled
# Freshop, which cannot be summoned on demand and must never be faked by hitting the live API harder.
$ffcOkIdx = $ffcS.IndexOf('ff-carry: OK  no term is missing')
$ffcBlindIdx = $ffcS.IndexOf('$attempted -gt 0 -and $probed -eq 0')
if ($ffcBlindIdx -ge 0 -and $ffcOkIdx -ge 0 -and $ffcBlindIdx -lt $ffcOkIdx) { Ok 'ff-carry refuses to print OK when Freshop answered none of the terms it needed to probe (exit 3, blind)' }
else { Bad 'ff-carry no longer gates its OK line on having actually probed something - a fully throttled run reads as a clean bill of health again (the 2026-07-31 zero-probe false OK)' }
if ($ffcS -match '\$attempted\s*=\s*\$emptyTerms\.Count\s*-\s*\$suppressed') { Ok 'ff-carry measures blindness against terms it actually had to probe, not the raw empty-term count' }
else { Bad 'ff-carry blindness is no longer keyed on $emptyTerms.Count - $suppressed - a pull that legitimately suppressed every term will now be reported blind (cry-wolf) or a real blind run missed' }
if ($cacSrc -match '\$fcRc -eq 3') { Ok 'check-ad-cycles reports an ff-carry could-not-evaluate separately from a crash' }
else { Bad 'check-ad-cycles has no $fcRc -eq 3 branch - a blind-but-healthy ff-carry is logged as "DID NOT RUN ... see stderr" and points the reader at an empty stderr' }

# ---------------------------------------------------------------- (v) everyday-mismatch: the orphan, now wired
# 2026-07-31. audit-everyday-mismatch.ps1 is the only check that asks whether the number we PUBLISHED agrees
# with the product page we LINKED to. It worked, it found real defects, and NOTHING invoked it - not
# guards.ps1, not check-ad-cycles.ps1. It also printed a confident "EVERYDAY MISMATCHES: 0" after checking
# ZERO cells, and it had no param() block at all, which is why it had never had a fixture: there was no way
# to feed it anything but the live board.
# The three fixtures below are FROZEN and SYNTHETIC (invented product names and prices, never regenerated
# from a board) and they run from a COPY in TEMP, because the audit writes everyday-mismatches.json and a
# coverage row into its -OutDir and a fixture that mutates itself is not frozen.
$emFxSrc = Join-Path $root 'regression-inputs\guard-fixtures'
$emTmp = Join-Path $env:TEMP ('emfx-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $emTmp -Force
function EmFixture([string]$name) {
  $d = Join-Path $emTmp $name
  Copy-Item (Join-Path $emFxSrc $name) $d -Recurse -Force
  $r = RunPS 'audit-everyday-mismatch.ps1' @('-OutDir', $d)
  $m = [regex]::Match($r.text, 'EVERYDAY MISMATCHES[^:]*:\s*(\d+)')
  return @{ rc = $r.rc; n = $(if ($m.Success) { [int]$m.Groups[1].Value } else { -1 }); text = $r.text }
}
# MUST FIRE: the board says 2.49, its own link says 1.99. Exactly one finding - the other two everyday rows
# in the same fixture are a string-priced link and a half-cent rounding case that must BOTH stay silent, so
# this single assertion also proves the audit is not simply reporting everything it looks at.
$emA = EmFixture 'everyday-mustfire'
if ($emA.rc -eq 1 -and $emA.n -eq 1) { Ok 'everyday-mismatch FIRES on a board cell that disagrees with its own linked product (exit 1, advisory)' }
else { Bad ('everyday-mismatch missed its founding disagreement: rc=' + $emA.rc + ' findings=' + $emA.n + ' (expected rc 1, exactly 1)') }
# CLEAN TWIN: same three products, board now agrees with every link. Must be silent AND exit 0.
$emB = EmFixture 'everyday-clean'
if ($emB.rc -eq 0 -and $emB.n -eq 0) { Ok 'everyday-mismatch stays silent when the board agrees with its links (clean twin)' }
else { Bad ('everyday-mismatch false-positives on a board that agrees with its own links: rc=' + $emB.rc + ' findings=' + $emB.n) }
# THE STRING-PRICE FOUNDING BUG, proven by the clean twin above: fixture-string-price stores "$3.99", and
# [double] on that throws under EAP=Stop. If that regressed, the fixture run dies and rc is neither 0 nor 1.
if ($emA.rc -in @(0, 1) -and $emB.rc -in @(0, 1)) { Ok 'everyday-mismatch survives a link price stored as a STRING ("$3.99") - the cast that killed it on its own first finding' }
else { Bad 'everyday-mismatch died on a string-shaped link price again - 579 of 2,987 stored prices are strings like "$1.88", so this kills the whole audit at its first finding' }
# BLIND: three everyday cells, all linked, all publishing per_unit 0 - real work, none of it doable. The
# house rule is that this can never read as a clean board.
$emC = EmFixture 'everyday-blind'
if ($emC.rc -eq 3 -and $emC.text -match 'COULD NOT EVALUATE') { Ok 'everyday-mismatch exits 3 when it had cells to check and could check none (no all-clear over an empty examination)' }
else { Bad ('everyday-mismatch reported a clean board having examined nothing: rc=' + $emC.rc + ' (expected 3 COULD NOT EVALUATE)') }
try { Remove-Item -LiteralPath $emTmp -Recurse -Force -ErrorAction SilentlyContinue } catch {}
# SOURCE-ONLY, and it has to be: "is this script still CALLED" is the one property no run of the script can
# demonstrate about itself. Being uncalled is its founding bug, so this is the check that matters most.
if ($cacSrc -match 'audit-everyday-mismatch\.ps1') { Ok 'check-ad-cycles still invokes audit-everyday-mismatch (it spent its whole life as an orphan)' }
else { Bad 'audit-everyday-mismatch is an ORPHAN again - nothing invokes it, so it can find real board/link disagreements every day and no one will ever read them' }
if ($cacSrc -match '\$emRc\s*-eq\s*1') { Ok 'check-ad-cycles treats an everyday-mismatch finding as a REVIEW line, not a failure' }
else { Bad 'check-ad-cycles no longer has an $emRc -eq 1 branch - findings are being read as a crash, and this audit must stay advisory (on a 43-finding day only 3 were wrong NUMBERS; the other 40 were stale LINKS over a correct board)' }
if ($cacSrc -match 'audit-coverage-ledger\.ps1[\s\S]{0,400}?-Phase cycle') { Ok 'check-ad-cycles runs the coverage ratchet for the CYCLE phase' }
else { Bad 'nothing runs audit-coverage-ledger with -Phase cycle - every cycle-phase coverage row is written and never compared, which is a gate that cannot arm (coverage-baseline.json carried this as a known TODO for exactly that reason)' }

# ---------------------------------------------------------------- (v2) the Hy-Vee pull's own numbers
# 2026-07-31. The wall-clock cap ($MAXMIN) warned once PER REMAINING PRODUCT and counted nothing, and $stale
# lumps together three unrelated reasons for a carry-forward row (cap hit, size-check refused, no productId),
# so a truncated run and a healthy one were identical from outside. Worse, the puller had NO exit statement
# anywhere: the throttle-wipeout guard - the pull collapsing below half its normal size and being quarantined
# instead of written - ended in a bare `return`, which exits ZERO, and check-ad-cycles piped the whole thing
# to Out-Null and logged 'Hy-Vee everyday refreshed' regardless.
# These are SOURCE checks. The behavioural cases need either a 14-minute run against the live GraphQL or a
# collapsed pull, neither of which can be summoned in a fixture suite, and -Quick deliberately bypasses the
# wipeout guard. Each names the exact mutation that makes it fire.
$hvSrc = Get-Content (Join-Path $root 'pull-regular-hyvee.ps1') -Raw
if ($hvSrc -match '\$capSkipped\+\+') { Ok 'pull-regular-hyvee counts cap-skipped products separately from $stale' }
else { Bad 'pull-regular-hyvee no longer counts cap-skipped products - a run truncated by the wall-clock cap is indistinguishable from a healthy one again' }
# BOTH HALVES, because the NAME surviving proves nothing. Mutating the assignment away left '$capWarned'
# still present in the initialiser and the test, so the loose form stayed green while the flag was never set
# and the warning re-fired every iteration - the exact behaviour being guarded. Same substring trap as $hvRc.
if (($hvSrc -match '-not \$capWarned') -and ($hvSrc -match '\$capWarned\s*=\s*\$true')) { Ok 'the Hy-Vee wall-clock warning fires ONCE, not once per remaining product' }
else { Bad 'the Hy-Vee cap warning lost its once-only flag (it must be both TESTED and SET) - it re-fires for every remaining product, hundreds of identical lines that say nothing about scale' }
if ($hvSrc -match 'cap_skipped=\$capSkipped') { Ok 'the Hy-Vee capture file records cap_skipped, not just the console' }
else { Bad 'pull-regular-hyvee stopped recording cap_skipped in its output file - the console is exactly where this information kept going to die' }
# -cmatch AND A LINE ANCHOR, not -match 'exit 2'. PowerShell's -match is case-INSENSITIVE, and the fix's own
# comment three lines above the statement begins "# EXIT 2, NOT a bare return" - so the loose form stayed
# green after the real `exit 2` was mutated away, satisfied entirely by the comment describing it. That is
# the second time in one day a source check was answered by the prose documenting the bug rather than by the
# code fixing it (test-guards.ps1's empty-stamp scan did the same). Match a STATEMENT: start of line,
# lowercase, nothing after it.
$hvWipe = [regex]::Match($hvSrc, 'THROTTLE-WIPEOUT guard tripped[\s\S]{0,900}')
if ($hvWipe.Success -and $hvWipe.Value -cmatch '(?m)^\s*exit 2\s*$') { Ok 'the Hy-Vee throttle-wipeout path exits 2 (a bare return at script scope exits ZERO)' }
else { Bad 'the Hy-Vee throttle-wipeout path no longer exits non-zero - the pull collapsing and being quarantined reports SUCCESS to its caller, which is how it went unnoticed' }
$hvCall = [regex]::Match($cacSrc, 'pull-regular-hyvee\.ps1[\s\S]{0,700}')
if ($hvCall.Success -and $hvCall.Value -notmatch 'pull-regular-hyvee\.ps1.{0,40}\|\s*Out-Null') { Ok 'check-ad-cycles no longer pipes the Hy-Vee pull to Out-Null' }
else { Bad 'the Hy-Vee pull is piped to Out-Null again - every count it prints is discarded and the log says "refreshed" whatever happened' }
# ASSERT THE ASSIGNMENT, not the name. '\$hvRc' alone is a SUBSTRING of '$hvRcX', so renaming the variable
# away from $LASTEXITCODE left this check green while the exit code went unread - proven by mutation.
if ($hvCall.Success -and $hvCall.Value -match '\$hvRc\s*=\s*\$LASTEXITCODE' -and $hvCall.Value -match '\$hvRc\s*-eq\s*2') { Ok 'check-ad-cycles captures the Hy-Vee pull exit code and branches on it (a native child crash is not a PowerShell exception, so the catch never sees it)' }
else { Bad 'check-ad-cycles no longer captures $LASTEXITCODE from the Hy-Vee pull into a variable it branches on - the throttle-wipeout and a dead pull both log as a clean refresh' }
if ($hvCall.Success -and $hvCall.Value -notmatch '2>&1') { Ok 'the Hy-Vee pull child is captured without 2>&1 (which under EAP=Stop makes its first stderr line terminating)' }
else { Bad 'the Hy-Vee pull child is captured with 2>&1 under EAP=Stop - its first stderr line becomes a terminating throw that skips the exit-code check just added' }
if ($stSrc -match 'protein-bars') { Ok 'the protein-bars clean twin is still present (the one measured legitimate non-food crossing)' }
else { Bad 'store-taxonomy lost the protein-bars clean twin - the allowlist valve is untested and the audit drops to 50% precision' }
# BLIND twin: an empty out\ must say could-not-evaluate, never report a clean zero.
$fxTx = NewFxDir 'taxonomy-blind'
New-Item -ItemType Directory -Force (Join-Path $fxTx 'regular') | Out-Null
$r = RunPS 'audit-store-taxonomy.ps1' @('-OutDir', $fxTx, '-ReportDir', $fxTx)
if ($r.rc -eq 3 -and $r.text -match 'BLIND') { Ok 'store-taxonomy goes BLIND (exit 3) with no store feed to read, instead of a clean zero' }
else { Bad ('store-taxonomy reported a result from an empty out\ (rc=' + $r.rc + ') - "0 disagreements" from zero examination is back') }
Remove-Item $fxTx -Recurse -Force -ErrorAction SilentlyContinue
# a green self-test cannot tell you the tool is still being CALLED
$cacTx = Get-Content (Join-Path $root 'check-ad-cycles.ps1') -Raw
if ($cacTx -match 'audit-store-taxonomy\.ps1') { Ok 'the daily job still runs the store-taxonomy second opinion' }
else { Bad 'check-ad-cycles no longer calls audit-store-taxonomy - the only check that does not inherit the include regex is dark, and the script census will call it an orphan' }

# ---------------------------------------------------------------- (v3) the walled-store rescue worklist
# 2026-07-31. The four walled stores are captured by hand through a browser, and compare-deals hands each
# commodity to the FRESHEST capture in its 14-day window OUTRIGHT. Three failure classes were all visible in
# the data and none of them produced a to-do list: 21 Walmart cells traced to a capture leaving the window
# the next day (produce, whose names Walmart rewrites - "Fresh Pineapple" -> "Fresh Pineapple, Each" - so
# newer captures missed them); Aldi's biggest-ever pass still cost 7 staple cells because it never searched
# those terms, reported only AFTER the loss; and ~20 Sam's cells serving from captures already past the
# window. build-rescue-worklist.ps1 turns all three into out\rescue-terms-<urlkey>.txt.
# The three fixtures are FROZEN and SYNTHETIC (an invented "Fixture Mart", invented products, dates in
# January 2000) and run from a COPY in TEMP, because the tool writes its lists and a coverage row into
# -OutDir and a fixture that mutates itself is not frozen. -AsOf is what makes them freezable at all: the
# tool calls Get-Date nowhere except to default that one parameter.
$rwFxSrc = Join-Path $root 'regression-inputs\guard-fixtures'
$rwTmp = Join-Path $env:TEMP ('rwfx-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $rwTmp -Force
function RwFixture([string]$name) {
  $d = Join-Path $rwTmp $name
  Copy-Item (Join-Path $rwFxSrc $name) $d -Recurse -Force
  $r = RunPS 'build-rescue-worklist.ps1' @('-AsOf', '2000-01-10', '-OutDir', $d)
  $listF = Join-Path $d 'rescue-terms-fixturemart.txt'
  $list = if (Test-Path $listF) { [IO.File]::ReadAllText($listF, [Text.Encoding]::UTF8) } else { '' }
  return @{ rc = $r.rc; text = $r.text; list = $list; hasList = (Test-Path $listF) }
}
# MUST FIRE, one cell per section so a single assertion cannot pass by accident: fx-eggs is priced on the
# older board and gone today (the Aldi class), fx-toast is on the board with no capture on disk carrying it
# (unknown provenance = capture it), fx-milk traces to a 9-day-old capture with 5 of 14 window days left
# (the Walmart silent countdown).
$rwA = RwFixture 'rescue-mustfire'
if ($rwA.rc -eq 1 -and $rwA.list -match '(?m)^fixture eggs\t+fx-eggs\tDROPPED') { Ok 'rescue-worklist FIRES on a cell that was priced a week ago and is gone today (the Aldi 7-staple drop class)' }
else { Bad ('rescue-worklist missed its DROPPED founding case: rc=' + $rwA.rc + ' - a board cell lost to a narrower re-capture produces no re-search term again') }
if ($rwA.list -match '(?m)^fixture toast\t+fx-toast\tUNTRACEABLE') { Ok 'rescue-worklist flags a cell no capture on disk still carries (unknown provenance = capture it)' }
else { Bad 'rescue-worklist no longer flags an UNTRACEABLE cell - a price we cannot attribute to any file is being reported as healthy' }
if ($rwA.list -match '(?m)^fixture milk\t+fx-milk\tEXPIRING\t5d left') { Ok 'rescue-worklist counts an expiring cell down to the exact day its only source leaves the union window' }
else { Bad 'rescue-worklist lost the EXPIRING section or its days-left arithmetic - the 21-cell Walmart silent countdown is invisible again' }
if ($rwA.hasList -and $rwA.list -match 'DEEP CAPTURE REQUIRED') { Ok 'the emitted worklist carries the DEEP CAPTURE warning (a narrow re-capture WINS the commodity with thinner data)' }
else { Bad 'the emitted worklist lost the DEEP CAPTURE header - a shallow rescue pass makes the board WORSE, and nothing on the list now says so' }
# CLEAN TWIN: same store, capture one day old and carrying both rows, older board identical. Every section
# empty, exit 0, and the file still written so a stale list can never be mistaken for today's.
$rwB = RwFixture 'rescue-clean'
if ($rwB.rc -eq 0 -and $rwB.list -match 'nothing at risk' -and $rwB.list -notmatch '(?m)^fixture ') { Ok 'rescue-worklist stays silent on a healthy walled store (clean twin: exit 0, every section empty, list still emitted)' }
else { Bad ('rescue-worklist cries wolf on a healthy store: rc=' + $rwB.rc + ' - a browser session would re-pull terms that did not need it') }
# BLIND: registry and terms present, no board at all. That is the fresh-clone / cloud-runner state.
$rwC = RwFixture 'rescue-blind'
if ($rwC.rc -eq 3 -and $rwC.text -match 'COULD NOT EVALUATE') { Ok 'rescue-worklist exits 3 with no board to read, instead of reporting every walled store healthy' }
else { Bad ('rescue-worklist reported a result with no comparison-*.json to read: rc=' + $rwC.rc + ' (expected 3 COULD NOT EVALUATE)') }
try { Remove-Item -LiteralPath $rwTmp -Recurse -Force -ErrorAction SilentlyContinue } catch {}
# SOURCE-ONLY, and it is the check that matters most: being uncalled is this class's founding bug. The
# closest relative of this tool, audit-everyday-mismatch, spent its ENTIRE life as an orphan finding real
# defects nobody read. No run of a script can demonstrate that something still calls it.
if ($cacSrc -match 'build-rescue-worklist\.ps1') { Ok 'check-ad-cycles still invokes build-rescue-worklist (an uncalled worklist builder is a worklist nobody gets)' }
else { Bad 'build-rescue-worklist is an ORPHAN - nothing invokes it, so the walled stores go back to being re-pulled blind and the expiring cells die on schedule' }
# ASSERT THE ASSIGNMENT AND A BRANCH, never the bare name: '\$rwRc' alone is a substring of '$rwRcX', which
# is exactly how the $hvRc check stayed green while the exit code went unread.
if ($cacSrc -match '\$rwRc\s*=\s*\$LASTEXITCODE' -and $cacSrc -match '\$rwRc\s*-eq\s*1') { Ok 'check-ad-cycles captures the rescue-worklist exit code and branches on it (a native child exit is not a PowerShell exception)' }
else { Bad 'check-ad-cycles no longer reads $LASTEXITCODE from build-rescue-worklist into a variable it branches on - work-exists and nothing-to-do are the same log line again' }
$rwCall = [regex]::Match($cacSrc, 'build-rescue-worklist\.ps1[\s\S]{0,600}')
if ($rwCall.Success -and $rwCall.Value -notmatch '2>&1' -and $rwCall.Value -notmatch '2>\$null') { Ok 'the rescue-worklist child is captured without a stderr redirect (under EAP=Stop one stderr line would become a terminating throw)' }
else { Bad 'the rescue-worklist child is captured with 2>&1 or 2>$null under EAP=Stop - its first stderr line becomes a throw that skips the exit-code read entirely' }
# THE REGISTRY FLAG THE WHOLE TOOL SELECTS ON. Counted from the PARSED JSON, not a regex over the text: a
# regex would count the word inside this file's own prose, or inside a readme sentence in stores.json.
$rwReg = Get-Content (Join-Path $root 'stores.json') -Raw | ConvertFrom-Json
$rwWalled = @(@($rwReg.stores) | Where-Object { $_.PSObject.Properties['walled'] -and $_.walled })
if ($rwWalled.Count -eq 4) { Ok 'stores.json still marks exactly 4 walled stores - the set build-rescue-worklist builds lists for' }
else { Bad ('stores.json marks ' + $rwWalled.Count + ' walled store(s), not 4 - a dropped flag silently removes that store from every rescue list, and the tool exits 3 only when ALL of them are gone') }
# guards.ps1 delegates cell-drops as a NATIVE child under EAP=Stop, where a redirected stderr line throws.
# It had 2>$null until 2026-07-31: inside its own try/catch, so not a dead guard, but any run where the
# child wrote to stderr was reported as "could not run" instead of its real finding.
if ($gSrc -match "audit-cell-drops\.ps1'\)\s*2>") { Bad 'guards.ps1 redirects the cell-drops child stderr again - under EAP=Stop the first stderr line throws, and a real cell leak is reported as plumbing failure' }
else { Ok 'guards.ps1 delegates cell-drops without a stderr redirect (a real finding reaches the warn line, not the catch)' }

# ---------------------------------------------------------------- 24. known-wrong blocklist (Component 2)
# MUST FIRE: an adjudicated-wrong product is priced on the board again. FOUNDING BUG - audit findings lived
# as PROSE in .md files, so honeydew was written up on 2026-07-29 with the store's own arithmetic and was
# still the published crown the next morning, and Blue Buffalo cat food held the salmon crown at 20.8% under
# the runner-up with every guard green. Fixtures are SYNTHETIC and frozen here: the product names are the
# bug, so they must never be re-read from the live board.
$fxKw = NewFxDir 'kw'
New-Item -ItemType Directory -Force (Join-Path $fxKw 'out\regular') | Out-Null
Set-Content (Join-Path $fxKw 'commodities.json') '[{"id":"salmon","label":"Salmon","unit":"lb"},{"id":"parmesan","label":"Parmesan","unit":"oz"},{"id":"coffee","label":"Coffee","unit":"oz"},{"id":"strawberries","label":"Strawberries","unit":"oz"}]' -Encoding UTF8
Set-Content (Join-Path $fxKw 'stores.json') '{"stores":[{"name":"Walmart","order":1,"regular_prefix":"walmart"},{"name":"Aldi","order":2,"regular_prefix":"aldi"}]}' -Encoding UTF8
# the Walmart feed the id-key re-derives today's spelling from: SAME item_id, DIFFERENT product name
Set-Content (Join-Path $fxKw 'out\regular\walmart-regular-2026-01-02.json') '{"store":"Walmart","deals":[{"store":"Walmart","item":"Blue Buffalo Wilderness Adult Cat Salmon Recipe, 9.5 lb","item_id":"634625434","current_price":"$38.98","size":"9.5 lb"}]}' -Encoding UTF8
$kwList = Join-Path $fxKw 'known-wrong.json'
Set-Content $kwList @'
{
  "schema": 1,
  "entries": [
    { "key": "salmon|Walmart|blue-buffalo-cat-food", "commodity": "salmon", "store": "Walmart",
      "names": ["Blue Buffalo Wilderness Natural High Protein Dry Food for Adult Cats, Salmon, 9.5-lb Bag"],
      "product_id": "634625434", "verdict": "wrong-product",
      "evidence": "dry cat food held the salmon crown at 20.8% under the runner-up",
      "ruled_on": "2026-07-30", "ruled_by": "fixture", "retire_when": "ruling-reversed" },
    { "key": "parmesan|Aldi|clancys-parmesan-garlic-pita-chips", "commodity": "parmesan", "store": "Aldi",
      "names": ["Clancy's Parmesan Garlic Pita Chips 7.33 OZ"],
      "product_id": "", "verdict": "wrong-product",
      "evidence": "pita chips, not parmesan cheese; Aldi also strips the apostrophe",
      "ruled_on": "2026-07-30", "ruled_by": "fixture", "retire_when": "ruling-reversed" },
    { "key": "coffee|Walmart|onyx-latte", "commodity": "coffee", "store": "Walmart",
      "names": ["Onyx Coffee Lab Salted Mocha Oat Milk Latte, 11 fl oz Can"],
      "product_id": "", "verdict": "wrong-product",
      "evidence": "ready-to-drink latte in the ground-coffee commodity",
      "ruled_on": "2026-07-30", "ruled_by": "fixture", "retire_when": "ruling-reversed",
      "reversed_on": "2026-07-30", "reversed_by": "fixture-reversal-test" },
    { "key": "strawberries|Aldi|kroger-strawberry-applesauce", "commodity": "strawberries", "store": "Aldi",
      "names": ["Kroger Strawberry Applesauce"],
      "product_id": "", "verdict": "wrong-product",
      "evidence": "applesauce cups held the fresh strawberries crown for six days",
      "ruled_on": "2026-07-30", "ruled_by": "fixture", "retire_when": "ruling-reversed" },
    { "key": "gone-commodity|Walmart|whatever", "commodity": "commodity-that-was-retired", "store": "Walmart",
      "names": ["Some Product That No Longer Has A Commodity"],
      "product_id": "", "verdict": "wrong-product",
      "evidence": "exists only to prove the commodity-retired trigger can actually fire",
      "ruled_on": "2026-07-30", "ruled_by": "fixture", "retire_when": "commodity-retired" }
  ]
}
'@ -Encoding UTF8
# DIRTY board: the ruled-wrong products are back, one of them under a DRIFTED name only the id can reach,
# and one of them (coffee) under a ruling that was REVERSED and therefore must NOT block
Set-Content (Join-Path $fxKw 'out\comparison-2026-01-02.json') @'
{"comparison":[
 {"id":"salmon","unit":"lb","cheapest_store":"Walmart","stores":[
   {"store":"Walmart","per_unit":4.1032,"item":"Blue Buffalo Wilderness Adult Cat Salmon Recipe, 9.5 lb","ad":"$38.98","size":"9.5 lb"},
   {"store":"Aldi","per_unit":5.18,"item":"Fremont Fish Market Atlantic Salmon Portions","ad":"$5.18","size":"lb"}]},
 {"id":"parmesan","unit":"oz","cheapest_store":"Aldi","stores":[
   {"store":"Aldi","per_unit":0.3124,"item":"Clancy S Parmesan Garlic Pita Chips 7.33 OZ","ad":"$2.29","size":"7.33 oz"}]},
 {"id":"coffee","unit":"oz","cheapest_store":"Walmart","stores":[
   {"store":"Walmart","per_unit":0.4518,"item":"Onyx Coffee Lab Salted Mocha Oat Milk Latte, 11 fl oz Can","ad":"$4.97","size":"11 fl oz"}]}
]}
'@ -Encoding UTF8
$r = RunPS 'audit-known-wrong.ps1' @('-Root', $fxKw, '-ListFile', $kwList)
if ($r.rc -eq 2 -and $r.text -match 'BLOCKED.*salmon') { Ok 'known-wrong FIRES (exit 2) when an adjudicated-wrong product is priced on the board again' }
else { Bad ('known-wrong did NOT block a re-published adjudicated-wrong product (rc=' + $r.rc + '): ' + $r.text) }
# the salmon cell in the dirty board carries the DRIFTED name, so the only way to reach it is the product id
if ($r.text -match 'Blue Buffalo Wilderness Adult Cat Salmon Recipe') { Ok 'known-wrong id key works: a listed product renamed in the feed is still blocked (name re-derived from item_id)' }
else { Bad 'known-wrong missed a listed product whose name drifted but whose item_id did not - the id key is dead' }
if ($r.text -match 'BLOCKED.*Clancy S Parmesan Garlic Pita Chips') { Ok 'known-wrong normalizer works: the apostrophe-stripped Aldi spelling is BLOCKED by the adjudicated name' }
else { Bad 'known-wrong missed the apostrophe-stripped spelling - the pipeline can rename its way past the blocklist' }
if ($r.text -notmatch 'BLOCKED.*coffee') { Ok 'known-wrong stops enforcing a REVERSED ruling (the retire trigger can actually fire)' }
else { Bad 'known-wrong still blocks a ruling that was reversed on the record - retire_when=ruling-reversed cannot fire' }
if ($r.text -match 'RETIRE-READY.*commodity-retired') { Ok 'known-wrong retire trigger commodity-retired FIRES for an entry whose commodity is gone' }
else { Bad 'known-wrong never reported commodity-retired - a moot entry can sit in the list forever (the allowlist bug)' }
# CLEAN TWIN: same tree, same blocklist, right products - must go silent, not just quieter
Set-Content (Join-Path $fxKw 'out\comparison-2026-01-02.json') @'
{"comparison":[
 {"id":"salmon","unit":"lb","cheapest_store":"Aldi","stores":[
   {"store":"Aldi","per_unit":5.18,"item":"Fremont Fish Market Atlantic Salmon Portions","ad":"$5.18","size":"lb"}]},
 {"id":"parmesan","unit":"oz","cheapest_store":"Aldi","stores":[
   {"store":"Aldi","per_unit":0.4988,"item":"Happy Farms Grated Parmesan Cheese 8 OZ","ad":"$3.99","size":"8 oz"}]},
 {"id":"coffee","unit":"oz","cheapest_store":"Walmart","stores":[
   {"store":"Walmart","per_unit":0.2483,"item":"Great Value Classic Roast Ground Coffee, 30.5 oz","ad":"$7.57","size":"30.5 oz"}]},
 {"id":"strawberries","unit":"oz","cheapest_store":"Aldi","stores":[
   {"store":"Aldi","per_unit":0.0833,"item":"Kroger Strawberry Applesauce, 6 pk 4 oz","ad":"$2.00","size":"6 pk 4 oz"}]}
]}
'@ -Encoding UTF8
$r = RunPS 'audit-known-wrong.ps1' @('-Root', $fxKw, '-ListFile', $kwList)
if ($r.rc -eq 0 -and $r.text -match 'KNOWN-WRONG AUDIT OK' -and $r.text -notmatch '(?m)^\s+BLOCKED') { Ok 'known-wrong clean twin: the same blocklist is SILENT on a board carrying the right products' }
else { Bad ('known-wrong clean twin failed (rc=' + $r.rc + ') - the blocklist fires on correct products, which would block every publish: ' + $r.text) }
# the REVIEW tier must be able to fire, and must NOT set the exit code. The core-name key (same name with
# the trailing size clause stripped) merges genuinely different pack sizes on real data - measured 435 such
# groups over 35,362 cells, including "Daisy Sour Cream 14 oz 2 pk" vs "48 oz" - so it is a queue, not a gate.
if ($r.text -match 'REVIEW.*Kroger Strawberry Applesauce, 6 pk 4 oz') { Ok 'known-wrong REVIEW tier fires on a size-variant of a blocked product' }
else { Bad 'known-wrong REVIEW tier never fired on an obvious size-variant - the near-match queue is dead code' }
if ($r.rc -eq 0) { Ok 'known-wrong REVIEW tier does NOT set the exit code (a 100%-precision gate plus a separate review queue, never one blended detector)' }
else { Bad ('a REVIEW near-match turned the gate red (rc=' + $r.rc + ') - the low-precision key is gating the publish') }
# the same clean twin must still report WHAT IT EXAMINED, or "no listed product is priced" is unfalsifiable
if ($r.text -match 'entries evaluable against \d+ named priced cells') { Ok 'known-wrong reports how many entries it could evaluate and how many cells it examined' }
else { Bad 'known-wrong reported a clean result without saying what it examined - "ok" from an unknown sample size' }
# BLIND: no board at all. Must be exit 3, never a clean 0.
$fxKwB = NewFxDir 'kw-blind'
New-Item -ItemType Directory -Force (Join-Path $fxKwB 'out') | Out-Null
Copy-Item $kwList (Join-Path $fxKwB 'known-wrong.json')
$r = RunPS 'audit-known-wrong.ps1' @('-Root', $fxKwB, '-ListFile', (Join-Path $fxKwB 'known-wrong.json'))
if ($r.rc -eq 3 -and $r.text -match 'BLIND') { Ok 'known-wrong goes BLIND (exit 3) with no board to examine instead of reporting a clean blocklist' }
else { Bad ('known-wrong reported a result with zero cells examined (rc=' + $r.rc + ') - "0 wrong products" from zero examination') }
# BLIND: the blocklist file itself is missing. Deleting the memory must be loud, not silent.
Remove-Item (Join-Path $fxKwB 'known-wrong.json') -Force
$r = RunPS 'audit-known-wrong.ps1' @('-Root', $fxKwB, '-ListFile', (Join-Path $fxKwB 'known-wrong.json'))
if ($r.rc -eq 3 -and $r.text -match 'MISSING') { Ok 'known-wrong goes BLIND (exit 3) when the blocklist file is missing rather than passing an unguarded board' }
else { Bad ('known-wrong passed with no blocklist file at all (rc=' + $r.rc + ') - the gate can be silently deleted') }
# SCHEMA: a retire trigger outside the closed vocabulary is the allowlist bug - it can never be evaluated.
$fxKwS = NewFxDir 'kw-schema'
New-Item -ItemType Directory -Force (Join-Path $fxKwS 'out') | Out-Null
Copy-Item (Join-Path $fxKw 'out\comparison-2026-01-02.json') (Join-Path $fxKwS 'out\comparison-2026-01-02.json')
Copy-Item (Join-Path $fxKw 'commodities.json') (Join-Path $fxKwS 'commodities.json')
Copy-Item (Join-Path $fxKw 'stores.json') (Join-Path $fxKwS 'stores.json')
Set-Content (Join-Path $fxKwS 'known-wrong.json') '{"schema":1,"entries":[{"key":"salmon|Walmart|x","commodity":"salmon","store":"Walmart","names":["Whatever"],"product_id":"","verdict":"wrong-product","evidence":"e","ruled_on":"2026-07-30","ruled_by":"fixture","retire_when":"the store does not carry the item"}]}' -Encoding UTF8
$r = RunPS 'audit-known-wrong.ps1' @('-Root', $fxKwS, '-ListFile', (Join-Path $fxKwS 'known-wrong.json'))
if ($r.rc -eq 2 -and $r.text -match 'closed vocabulary') { Ok 'known-wrong REFUSES an entry whose retire trigger nobody can evaluate (the 2026-07-30 allowlist bug, rejected at the schema)' }
else { Bad ('known-wrong accepted an unevaluable retire trigger (rc=' + $r.rc + ') - entries can be justified by claims no machine can check') }
# UNEVALUABLE: a typo'd commodity id must be named, not silently counted as clean.
Set-Content (Join-Path $fxKwS 'known-wrong.json') '{"schema":1,"entries":[{"key":"salmonn|Walmart|x","commodity":"salmonn","store":"Walmart","names":["Whatever"],"product_id":"","verdict":"wrong-product","evidence":"e","ruled_on":"2026-07-30","ruled_by":"fixture","retire_when":"ruling-reversed"}]}' -Encoding UTF8
$r = RunPS 'audit-known-wrong.ps1' @('-Root', $fxKwS, '-ListFile', (Join-Path $fxKwS 'known-wrong.json'))
if ($r.rc -eq 3 -and $r.text -match 'UNEVALUABLE') { Ok 'known-wrong names an entry it could not evaluate (typo commodity id) and goes blind rather than counting it clean' }
else { Bad ('known-wrong counted an unevaluable entry as a pass (rc=' + $r.rc + ') - an entry can be permanently unfirable and look green') }
# LIVE CLEAN TWIN: the real blocklist against the real board must be GREEN. It is a REGRESSION blocklist -
# every seeded case is already fixed - so a red here means a fixed defect came back, which is page-worthy.
$r = RunPS 'audit-known-wrong.ps1' @()
if ($r.rc -eq 0 -and $r.text -match 'KNOWN-WRONG AUDIT OK') { Ok 'known-wrong live clean twin: the real blocklist is green on the real board' }
else { Bad ('known-wrong is RED on the live board (rc=' + $r.rc + ') - an adjudicated-wrong product is published again: ' + $r.text) }
Remove-Item $fxKw, $fxKwB, $fxKwS -Recurse -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------- (m) the COVERAGE LEDGER
# FOUNDING BUGS, all three measured, all three the same shape: a check that examined nothing, or stopped
# examining, and nothing anywhere remembered what it used to examine.
#   1. guard 11 reconciled Baker's against a raw capture; its row filter (.upc + source_ad 'bakersplus')
#      stopped matching when Baker's moved to the Kroger API, and it printed "ok ... (0 rows checked)" for
#      FIVE DAYS on the board's largest store.
#   2. guard 3's WRONG-PRODUCT clause examined 0 of 16 pins - its producer read only the staple board and
#      every pin is a recipe-board id - while the ok line beside it said 16 checked.
#   3. audit-ff-carry threw on its own report line before printing one word, so the Family Fare pull-drop
#      watch was decorative for 17 days and 'ff-carry' appears ZERO times in 2,716 lines of ad-cycle-log.txt.
# guards.ps1's OkUnlessBlind catches (1) and (2) WITHIN a run. It cannot catch (3) - absence is not a zero -
# and it cannot catch a PARTIAL collapse, where a check falls from 2,435 rows to 400 and every in-run test
# in this tree reads that as a pass. The ledger is the memory that makes both visible.
# Everything below runs THE REAL SCRIPTS (a copy of audit-coverage-ledger.ps1 + coverage-lib.ps1 in a temp
# dir, so $PSScriptRoot points at the fixture) against FROZEN synthetic state. Never regenerated from the
# live board: the bug lives in these numbers.
$covSrcG = Get-Content (Join-Path $root 'guards.ps1') -Raw
foreach ($k in @('guards/11-bakers-provenance', 'guards/3-pin-identity', 'guards/4-factor', 'guards/10-store-charges')) {
  if ($covSrcG -match ([regex]::Escape("Write-CoverageRecord -Check '" + $k + "'"))) { Ok ("guards.ps1 still records coverage for " + $k) }
  else { Bad ("guards.ps1 stopped recording coverage for " + $k + " - the ratchet has nothing to compare and its baseline row goes NEVER-RECORDED") }
}
$covSrcF = Get-Content (Join-Path $root 'audit-food-category.ps1') -Raw
if ($covSrcF -match "Write-CoverageRecord -Check 'audit-food-category'") { Ok 'audit-food-category still records what it scanned' }
else { Bad 'audit-food-category no longer records its scan count - a shrinking wrong-class scan is invisible again' }
if ($covSrcF -match '\$eligible\+\+') { Ok 'audit-food-category still counts the DENOMINATOR before its scoping tests (2,663 scanned of 3,196 priced cells)' }
else { Bad 'audit-food-category lost its eligible counter - its ok line can shrink by hundreds of cells with no way to tell' }
$covSrcC = Get-Content (Join-Path $root 'audit-ff-carry.ps1') -Raw
if ($covSrcC -match 'Emit-Coverage \$emptyTerms\.Count \$probed') { Ok 'audit-ff-carry records its probe count BEFORE the report line that threw for 17 days' }
else { Bad 'audit-ff-carry no longer records coverage before its report line - a repeat of the 17-day silent death leaves no trace again' }

$fxCov = NewFxDir 'cov-ledger'
New-Item -ItemType Directory -Force (Join-Path $fxCov 'out') | Out-Null
Copy-Item (Join-Path $root 'audit-coverage-ledger.ps1') $fxCov
Copy-Item (Join-Path $root 'coverage-lib.ps1') $fxCov
$covEnc = New-Object Text.UTF8Encoding($false)
# as_of is stamped with TODAY on purpose: STALE is measured against the clock, so a frozen calendar date
# would make every non-stale case fail as soon as the fixture aged. The BUG is in the counts, not the date.
$covNow = (Get-Date -Format 'yyyy-MM-dd') + ' 09:00:00'
function CovLedger([hashtable]$rows) {
  $c = [ordered]@{}
  foreach ($k in ($rows.Keys | Sort-Object)) {
    $v = $rows[$k]
    $c[$k] = [ordered]@{ eligible = $v[0]; examined = $v[1]; skipped = ([math]::Max(0, $v[0] - $v[1])); blind = ($v[1] -le 0); as_of = $(if ($v.Count -gt 2) { $v[2] } else { $covNow }); detail = 'frozen fixture' }
  }
  [IO.File]::WriteAllText((Join-Path $fxCov 'out\coverage-ledger.json'), (([ordered]@{ schema = 1; updated = $covNow; checks = $c }) | ConvertTo-Json -Depth 6), $covEnc)
}
# FROZEN baseline: guard 11 at its pre-API row count, guard 3 at the 16 pins it had the day it went blind.
[IO.File]::WriteAllText((Join-Path $fxCov 'coverage-baseline.json'), (@'
{"schema":1,"set":"frozen fixture - do not regenerate","checks":{
 "guards/11-bakers-provenance":{"examined":6960,"tolerance":0.25,"max_age_days":2,"phase":"publish"},
 "guards/3-pin-identity":{"examined":16,"tolerance":0.5,"max_age_days":2,"phase":"publish"},
 "guards/4-factor":{"examined":2435,"tolerance":0.1,"max_age_days":2,"phase":"publish"},
 "audit-ff-carry":{"examined":464,"tolerance":1.0,"max_age_days":3,"phase":"cycle","why":"RATCHET DELIBERATELY OFF - inverse denominator. It counts EMPTY FF search terms re-probed, so it FALLS when the pull improves; a ratchet would fire at whoever fixed the thing it watches. The clean twin below pins exactly that. Recorded here because DEAD-RATCHET now separates a declared exemption from an accidental one, and an undeclared 1.0 is an accident."}}}
'@), $covEnc)
$covHealthy = @{ 'guards/11-bakers-provenance' = @(6960, 6936); 'guards/3-pin-identity' = @(19, 9); 'guards/4-factor' = @(2435, 2435); 'audit-ff-carry' = @(464, 464) }

# MUST FIRE 1 - the guard-11 founding bug: an ok over 0 of 6,960 rows.
$h = $covHealthy.Clone(); $h['guards/11-bakers-provenance'] = @(6960, 0); CovLedger $h
$r = RunPSAt $fxCov 'audit-coverage-ledger.ps1' @('-OutDir', (Join-Path $fxCov 'out'), '-Phase', 'all')
if ($r.rc -eq 1 -and $r.text -match 'BLIND' -and $r.text -match 'guards/11-bakers-provenance') { Ok 'coverage-ledger FIRES on the guard-11 founding bug (0 of 6,960 rows examined)' }
else { Bad ('coverage-ledger missed a check that examined ZERO of 6,960 rows (rc=' + $r.rc + '): ' + $r.text) }
# and it must be able to BLOCK when armed - a gate that can never arm is no gate
$r = RunPSAt $fxCov 'audit-coverage-ledger.ps1' @('-OutDir', (Join-Path $fxCov 'out'), '-Phase', 'all', '-Gate')
if ($r.rc -eq 2) { Ok 'coverage-ledger -Gate goes RED on the pre-change state (exit 2)' }
else { Bad ('coverage-ledger -Gate did NOT block on a blind check (rc=' + $r.rc + ') - the gate cannot arm') }
# -Accept must REFUSE during the incident, or the high-water mark is pinned at zero forever
$r = RunPSAt $fxCov 'audit-coverage-ledger.ps1' @('-OutDir', (Join-Path $fxCov 'out'), '-Phase', 'all', '-Accept')
if ($r.rc -eq 3 -and $r.text -match 'REFUSED') { Ok 'coverage-ledger -Accept REFUSES on a blind ledger (accepting would disarm the ratchet permanently)' }
else { Bad ('coverage-ledger -Accept wrote a baseline from a BLIND ledger (rc=' + $r.rc + ') - the tile-integrity -Baseline lesson was not learned') }

# MUST FIRE 2 - the guard-3 founding bug: 0 of 16 pins identity-checked while the ok line said 16.
$h = $covHealthy.Clone(); $h['guards/3-pin-identity'] = @(16, 0); CovLedger $h
$r = RunPSAt $fxCov 'audit-coverage-ledger.ps1' @('-OutDir', (Join-Path $fxCov 'out'), '-Phase', 'all')
if ($r.rc -eq 1 -and $r.text -match 'BLIND' -and $r.text -match 'guards/3-pin-identity') { Ok 'coverage-ledger FIRES on the guard-3 founding bug (0 of 16 pins identity-checked)' }
else { Bad ('coverage-ledger missed guard 3 checking 0 of 16 pins (rc=' + $r.rc + '): ' + $r.text) }

# MUST FIRE 3 - the audit-ff-carry founding bug: 17 days of no output at all, so no row.
$h = $covHealthy.Clone(); $h.Remove('audit-ff-carry'); CovLedger $h
$r = RunPSAt $fxCov 'audit-coverage-ledger.ps1' @('-OutDir', (Join-Path $fxCov 'out'), '-Phase', 'cycle')
if ($r.rc -eq 1 -and $r.text -match 'NEVER-RECORDED' -and $r.text -match 'audit-ff-carry') { Ok 'coverage-ledger FIRES on a rostered check that produced NO row at all (the 17-day ff-carry silence)' }
else { Bad ('coverage-ledger did not notice a rostered check that never ran (rc=' + $r.rc + '): ' + $r.text) }
# CLEAN TWIN: the same missing row in the PUBLISH phase must stay silent - ff-carry runs on the ad cycle, and
# demanding a check that was never going to run this job is the cry-wolf failure this file keeps re-learning.
$r = RunPSAt $fxCov 'audit-coverage-ledger.ps1' @('-OutDir', (Join-Path $fxCov 'out'), '-Phase', 'publish')
if ($r.rc -eq 0) { Ok 'coverage-ledger stays SILENT about a cycle-phase check during a publish-phase run' }
else { Bad ('coverage-ledger demanded a cycle-phase row during a publish run (rc=' + $r.rc + ') - it would fire on every cloud run, where out\ starts empty') }

# MUST FIRE 4 - the PARTIAL collapse. Not blind, 63% blind. Nothing else in this tree can see it.
$h = $covHealthy.Clone(); $h['guards/4-factor'] = @(2435, 900); CovLedger $h
$r = RunPSAt $fxCov 'audit-coverage-ledger.ps1' @('-OutDir', (Join-Path $fxCov 'out'), '-Phase', 'all')
if ($r.rc -eq 1 -and $r.text -match 'REGRESSED' -and $r.text -match 'guards/4-factor') { Ok 'coverage-ledger FIRES when a check quietly halves its coverage (2,435 -> 900)' }
else { Bad ('coverage-ledger let a check drop 63% of its coverage (rc=' + $r.rc + '): ' + $r.text) }

# MUST FIRE 5 - eligible ZERO is not a pass. 22 of 492 commodities have exactly ONE priced cell and 58 have
# <=3 (measured 2026-07-30), so any per-commodity rail is structurally inert across a fifth of the board.
$h = $covHealthy.Clone(); $h['guards/4-factor'] = @(0, 0); CovLedger $h
$r = RunPSAt $fxCov 'audit-coverage-ledger.ps1' @('-OutDir', (Join-Path $fxCov 'out'), '-Phase', 'all')
if ($r.rc -eq 1 -and $r.text -match 'INERT') { Ok 'coverage-ledger calls a check with ZERO eligible rows INERT, not ok' }
else { Bad ('coverage-ledger reported a clean result for a check with nothing eligible (rc=' + $r.rc + ')') }

# MUST FIRE 6 - the auditor obeys its OWN zero-rows rule. '' | ConvertFrom-Json returns $null WITHOUT
# throwing in PS 5.1, which is exactly how triage-due printed IDLE over 5 open alerts.
[IO.File]::WriteAllText((Join-Path $fxCov 'out\coverage-ledger.json'), '', $covEnc)
$r = RunPSAt $fxCov 'audit-coverage-ledger.ps1' @('-OutDir', (Join-Path $fxCov 'out'), '-Phase', 'all')
if ($r.rc -eq 3 -and $r.text -match 'COULD NOT EVALUATE') { Ok 'coverage-ledger exits 3 on an empty/mid-write ledger instead of reporting a clean board' }
else { Bad ('coverage-ledger FAILED OPEN on an empty ledger file (rc=' + $r.rc + ') - the PS 5.1 empty-string-to-null trap is back') }
[IO.File]::WriteAllText((Join-Path $fxCov 'out\coverage-ledger.json'), '{"schema":1,"checks":{"a":{"exam', $covEnc)
$r = RunPSAt $fxCov 'audit-coverage-ledger.ps1' @('-OutDir', (Join-Path $fxCov 'out'), '-Phase', 'all')
if ($r.rc -eq 3) { Ok 'coverage-ledger exits 3 on truncated JSON' }
else { Bad ('coverage-ledger did not fail closed on truncated JSON (rc=' + $r.rc + ')') }

# CLEAN TWIN 1 - the healthy shape must be silent, or the whole thing gets switched off in a week.
CovLedger $covHealthy
$r = RunPSAt $fxCov 'audit-coverage-ledger.ps1' @('-OutDir', (Join-Path $fxCov 'out'), '-Phase', 'all')
if ($r.rc -eq 0 -and $r.text -match 'coverage-ledger: ok') { Ok 'coverage-ledger SILENT on a healthy ledger' }
else { Bad ('coverage-ledger fired on a healthy ledger (rc=' + $r.rc + '): ' + $r.text) }
# CLEAN TWIN 2 - THE CRY-WOLF TWIN. -0.7% is the largest day-over-day DROP in the board's priced-cell count
# across every retained board since 2026-07-18 (the whole retained history's worst is -5.0%, during the
# 29 -> 492 commodity build-out). The 10% band was chosen from that measurement and must not fire here.
$h = $covHealthy.Clone(); $h['guards/4-factor'] = @(2435, 2418); CovLedger $h
$r = RunPSAt $fxCov 'audit-coverage-ledger.ps1' @('-OutDir', (Join-Path $fxCov 'out'), '-Phase', 'all')
if ($r.rc -eq 0) { Ok 'coverage-ledger SILENT on a -0.7% move (the worst real day-over-day drop since 2026-07-18)' }
else { Bad ('coverage-ledger fired on ordinary board movement (rc=' + $r.rc + ') - it will be switched off within a week: ' + $r.text) }
# CLEAN TWIN 3 - ff-carry's count FALLS when the FF pull gets BETTER (fewer empty terms to re-probe), so its
# ratchet is deliberately off. A watcher that fires when somebody fixes the thing it watches is worse than none.
$h = $covHealthy.Clone(); $h['audit-ff-carry'] = @(12, 12); CovLedger $h
$r = RunPSAt $fxCov 'audit-coverage-ledger.ps1' @('-OutDir', (Join-Path $fxCov 'out'), '-Phase', 'all')
if ($r.rc -eq 0) { Ok 'coverage-ledger does NOT punish ff-carry for having fewer empty terms to re-probe' }
else { Bad ('coverage-ledger fired when the FF pull IMPROVED (rc=' + $r.rc + ') - the tolerance-1.0 exemption was lost') }
# CLEAN TWIN 4 - brand-new instrumentation must never turn the board red on the day it lands.
$h = $covHealthy.Clone(); $h['audit-something-new'] = @(5, 5); CovLedger $h
$r = RunPSAt $fxCov 'audit-coverage-ledger.ps1' @('-OutDir', (Join-Path $fxCov 'out'), '-Phase', 'all')
if ($r.rc -eq 0 -and $r.text -match 'UNBASELINED') { Ok 'coverage-ledger reports an unbaselined new check as a note, never a finding' }
else { Bad ('a brand-new instrumented check turned the ledger red (rc=' + $r.rc + ')') }
# MUST FIRE 7 - a row that stopped being written. Same failure as (3) for a check that used to report.
$h = $covHealthy.Clone(); $h['guards/4-factor'] = @(2435, 2435, ((Get-Date).AddDays(-9).ToString('yyyy-MM-dd') + ' 09:00:00')); CovLedger $h
$r = RunPSAt $fxCov 'audit-coverage-ledger.ps1' @('-OutDir', (Join-Path $fxCov 'out'), '-Phase', 'all')
if ($r.rc -eq 1 -and $r.text -match 'STALE') { Ok 'coverage-ledger FIRES on a check that stopped recording 9 days ago' }
else { Bad ('coverage-ledger accepted a 9-day-old coverage row as current (rc=' + $r.rc + ')') }

# THE EMITTER ITSELF must still round-trip, or every row above is fiction. Runs the REAL coverage-lib.ps1.
$covEmitOk = $false
try {
  $covProbe = & {
    . (Join-Path $fxCov 'coverage-lib.ps1')
    $od = Join-Path $fxCov 'emit'
    New-Item -ItemType Directory -Force $od | Out-Null
    Write-CoverageRecord -Check 'fixture/real' -OutDir $od -Eligible 100 -Examined 40 -Detail 'fixture'
    Write-CoverageRecord -Check 'fixture/blind' -OutDir $od -Eligible 100 -Examined 0 -Detail 'fixture'
    Read-CoverageJson (Join-Path $od 'coverage-ledger.json')
  }
  $covEmitOk = ($covProbe -and $covProbe.checks.'fixture/real'.examined -eq 40 -and $covProbe.checks.'fixture/real'.skipped -eq 60 -and (-not $covProbe.checks.'fixture/real'.blind) -and $covProbe.checks.'fixture/blind'.blind)
} catch { $covEmitOk = $false }
if ($covEmitOk) { Ok 'coverage-lib records eligible/examined/skipped and marks a zero-examined row BLIND' }
else { Bad 'coverage-lib no longer round-trips a record - every ledger row in this estate is fiction' }
# and it must NOT write to the output stream: guards.ps1 and check-ad-cycles parse their own stdout.
$covNoise = & { . (Join-Path $fxCov 'coverage-lib.ps1'); Write-CoverageRecord -Check 'fixture/noise' -OutDir (Join-Path $fxCov 'emit') -Eligible 1 -Examined 1 }
if ($null -eq $covNoise -or @($covNoise).Count -eq 0) { Ok 'coverage-lib emits nothing to the output stream (it cannot pollute a caller''s stdout)' }
else { Bad ('coverage-lib wrote ' + @($covNoise).Count + ' object(s) to the output stream - it will corrupt the stdout of every script that calls it') }
Remove-Item $fxCov -Recurse -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------- N+10. the OUT-OF-BAND verification sample
# FOUNDING BUG (2026-07-30): every accuracy number this estate prints is written by the code that wrote the
# board. On the morning of 2026-07-30 "ACCURACY 0 of 1,844", "guards exit 0" and "2,640 cells scanned" were
# all true as printed, and all three were sitting above a bag of cat food holding the SALMON crown. The
# sampler exists to produce the one statement the board did not write about itself, and it has exactly two
# ways to become worthless: hand the verifier OUR answer (then they confirm our price and never ask whether
# the row is salmon), or quote a defect rate as a bare point estimate (then "3 of 30 = 10%" gets repeated as
# fact when 3-of-30 is equally consistent with 2% and with 27%).
# Both regions are extracted from the REAL scripts and executed against frozen synthetic input - a
# transcribed copy would drift out of the shipping code the way the Lysol negative test did.
$bvsPath = Join-Path $root 'build-verification-sample.ps1'
$rsvPath = Join-Path $root 'record-sample-verdict.ps1'
if (-not (Test-Path $bvsPath) -or -not (Test-Path $rsvPath)) {
  Bad 'the out-of-band sampler scripts are MISSING - the only non-self-referential check on the board is gone, and this section EXAMINED NOTHING'
} else {
  $bvsTxt = ((Get-Content $bvsPath -Raw) + '')
  $rsvTxt = ((Get-Content $rsvPath -Raw) + '')

  # ---- (a) the DRAW: deterministic, seed-sensitive, and it must spill rather than shrink -----------------
  $mDraw = [regex]::Match($bvsTxt, '# BEGIN-SAMPLE-DRAW[\s\S]*?# END-SAMPLE-DRAW')
  if (-not $mDraw.Success) { Bad 'could not extract the BEGIN-SAMPLE-DRAW region from build-verification-sample.ps1 - the draw fixtures below CANNOT RUN' }
  else {
    $dr = & {
      Invoke-Expression $mDraw.Value
      [pscustomobject]@{
        same     = ((Get-SampleScore '2026-07-30' 'salmon|Walmart') -eq (Get-SampleScore '2026-07-30' 'salmon|Walmart'))
        seedDiff = ((Get-SampleScore '2026-07-30' 'salmon|Walmart') -ne (Get-SampleScore '2026-07-31' 'salmon|Walmart'))
        keyDiff  = ((Get-SampleScore '2026-07-30' 'salmon|Walmart') -ne (Get-SampleScore '2026-07-30' 'salmon|Aldi'))
        inRange  = ((Get-SampleScore '2026-07-30' 'salmon|Walmart') -ge 0 -and (Get-SampleScore '2026-07-30' 'salmon|Walmart') -lt 1)
        # the live board shape on 2026-07-30: 492 crown cells, 2300 non-crown
        live     = (Get-StratumAllocation 100 0.6 492 2300)
        srs      = (Get-StratumAllocation 100 0.0 492 2300)
        # MUST SPILL: a stratum too small for its share must not shrink the sample below what was asked for
        thinCrown = (Get-StratumAllocation 100 0.6 10 2300)
        thinOther = (Get-StratumAllocation 100 0.6 492 5)
        overdraw  = (Get-StratumAllocation 5000 0.6 492 2300)
      }
    }
    if ($dr.same -and $dr.seedDiff -and $dr.keyDiff -and $dr.inRange) { Ok 'sample draw is deterministic per (seed, cell), changes with the seed, and stays in [0,1)' }
    else { Bad ("sample draw score is not a stable seeded uniform: same=$($dr.same) seedDiff=$($dr.seedDiff) keyDiff=$($dr.keyDiff) inRange=$($dr.inRange)") }
    if ($dr.live.crown -eq 60 -and $dr.live.noncrown -eq 40 -and $dr.srs.crown -eq 0 -and $dr.srs.noncrown -eq 100 -and
        $dr.thinCrown.drawn -eq 100 -and $dr.thinOther.drawn -eq 100 -and $dr.overdraw.drawn -eq 2792) {
      Ok 'stratum allocation: 60/40 on the live shape, -CrownShare 0 gives a plain whole-board draw, a thin stratum SPILLS instead of shrinking the sample, and an over-large -N clamps to the population'
    } else {
      Bad ("stratum allocation wrong: live=$($dr.live.crown)/$($dr.live.noncrown) srs=$($dr.srs.crown)/$($dr.srs.noncrown) thinCrown=$($dr.thinCrown.drawn) thinOther=$($dr.thinOther.drawn) overdraw=$($dr.overdraw.drawn)")
    }
  }

  # ---- (b) THE BLIND WORKLIST. The must-fire and the clean twin are the same run read two ways ----------
  # MUST FIRE if the worklist ever carries the board's own answer; the TWIN proves the sealed key still has
  # it, so the check cannot pass by the sampler simply writing nothing (an empty worklist leaks nothing).
  $fxVs = NewFxDir 'verif-sample'
  New-Item -ItemType Directory -Force (Join-Path $fxVs 'out') | Out-Null
  Copy-Item $bvsPath (Join-Path $fxVs 'build-verification-sample.ps1')
  Copy-Item $rsvPath (Join-Path $fxVs 'record-sample-verdict.ps1')
  # FROZEN SYNTHETIC BOARD - never derived from the live board, so the bug it encodes cannot evaporate.
  # zzz-salmon carries the founding defect verbatim: a bag of cat food holding the crown, 20.8% under the
  # runner-up, with a real price and a plausible size. ZZQQ tokens exist only to be searched for.
  $fxRows = New-Object System.Collections.ArrayList
  [void]$fxRows.Add('{"id":"zzz-salmon","commodity":"ZZZ Salmon Fillet","unit":"lb","cheapest_store":"ZZZ-Mart","cheapest_price":1.23,"stores":[{"store":"ZZZ-Mart","per_unit":1.23,"unit":"lb","type":"everyday","item":"ZZQQ Dry Food for Adult Cats ZZQQ","size":"16 lb","ad":"$19.68"},{"store":"ZZZ-Grocer","per_unit":9.99,"unit":"lb","type":"everyday","item":"ZZQQ Atlantic Salmon Fillet ZZQQ","size":"lb","ad":"$9.99"}]}')
  for ($fi = 1; $fi -le 49; $fi++) {
    [void]$fxRows.Add('{"id":"zzz-item-' + $fi + '","commodity":"ZZZ Item ' + $fi + '","unit":"lb","cheapest_store":"ZZZ-Mart","cheapest_price":1.0,"stores":[{"store":"ZZZ-Mart","per_unit":1.0,"unit":"lb","type":"everyday","item":"ZZQQ Product ' + $fi + ' ZZQQ","size":"lb","ad":"$1.00"},{"store":"ZZZ-Grocer","per_unit":2.0,"unit":"lb","type":"everyday","item":"ZZQQ Other ' + $fi + ' ZZQQ","size":"lb","ad":"$2.00"}]}')
  }
  $fxBoard = '{"built_at":"2026-01-01T00:00:00","week_of":"2026-01-01","comparison":[' + (($fxRows.ToArray()) -join ',') + ']}'
  $fxEnc = New-Object System.Text.UTF8Encoding($false)
  [IO.File]::WriteAllText((Join-Path $fxVs 'out\comparison-2026-01-01.json'), $fxBoard, $fxEnc)

  $oVs = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $fxVs 'build-verification-sample.ps1') -N 100 -Quiet 2>&1 | ForEach-Object { [string]$_ }
  $rcVs = $LASTEXITCODE
  $wlF = Join-Path $fxVs 'out\verification-worklist-2026-01-01.csv'
  $kyF = Join-Path $fxVs 'out\verification-sample-2026-01-01.json'
  if ($rcVs -eq 0 -and (Test-Path $wlF) -and (Test-Path $kyF)) {
    $wlT = ((Get-Content $wlF -Raw) + '')
    $kyT = ((Get-Content $kyF -Raw) + '')
    $leaks = New-Object System.Collections.ArrayList
    if ($wlT -match 'ZZQQ')  { [void]$leaks.Add('the board product NAME') }
    if ($wlT -match '19\.68') { [void]$leaks.Add('the board PRICE') }
    if ($wlT -match 'crown')  { [void]$leaks.Add('which cells are CROWNED') }
    if ($leaks.Count -eq 0) { Ok 'the verification worklist is BLIND - it carries no product name, no price and no crown flag' }
    else { Bad ('the verification worklist LEAKS ' + ($leaks -join ' + ') + ' - a verifier handed our own answer confirms it instead of checking it, which is the entire failure this sampler exists to escape') }
    # CLEAN TWIN: the sealed key must hold everything the worklist withheld, or the test above passes on an
    # empty file. It must also carry the stratum populations, without which no reweighting is possible.
    if ($kyT -match 'ZZQQ' -and $kyT -match '19\.68' -and $kyT -match 'crown' -and $kyT -match '"population"') {
      Ok 'the sealed key still holds the board answer + stratum populations (so the blind worklist is blind by omission, not by emptiness)'
    } else { Bad 'the sealed key is missing the board answer or the stratum populations - nothing can be adjudicated or reweighted from it' }
    # ORDERING IS A CHANNEL TOO. Drawn stratum by stratum, the worklist arrives as a crown block followed by
    # a non-crown block, and the crown share is documented in the sampler's own header - so ROW POSITION
    # alone would tell the verifier which cells the board calls cheapest. The column checks above cannot see
    # that, because no column is wrong. Assert the two strata are actually shuffled together.
    $kyO = ((Get-Content $kyF -Raw) + '') | ConvertFrom-Json
    $seqStrat = @($kyO.cells | Sort-Object seq | ForEach-Object { [string]$_.stratum })
    $runsN = 0
    if ($seqStrat.Count -gt 0) { $runsN = 1; for ($si = 1; $si -lt $seqStrat.Count; $si++) { if ($seqStrat[$si] -ne $seqStrat[$si - 1]) { $runsN++ } } }
    if ($runsN -ge 10) { Ok ('the worklist INTERLEAVES the strata (' + $runsN + ' runs over ' + $seqStrat.Count + ' rows) - row position does not publish the crown flag the columns withhold') }
    else { Bad ('the worklist is ordered stratum-by-stratum (' + $runsN + ' runs over ' + $seqStrat.Count + ' rows) - row position ALONE tells the verifier which cells the board calls cheapest, which is the crown flag leaked through the ordering') }
    if (@($wlT -split "`r?`n" | Where-Object { $_ -match '^"' }).Count -eq 100) { Ok 'the worklist holds exactly the 100 rows that were asked for' }
    else { Bad ('the worklist row count is not the requested 100: ' + @($wlT -split "`r?`n" | Where-Object { $_ -match '^"' }).Count) }
    # REPRODUCIBLE: same board, same seed, byte-identical worklist. A sample nobody can redraw is a sample
    # nobody can audit, and Get-Random would silently make every past worklist unreproducible.
    $h1 = (Get-FileHash $wlF).Hash
    $null = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $fxVs 'build-verification-sample.ps1') -N 100 -Force -Quiet 2>&1
    if ((Get-FileHash $wlF).Hash -eq $h1) { Ok 'the draw is REPRODUCIBLE - re-running the sampler on the same board rebuilds a byte-identical worklist' }
    else { Bad 'the draw is NOT reproducible - a disputed verdict can never be traced back to the cell it graded' }
    # and it must REFUSE to silently redraw over a worklist somebody may already be verifying
    $o2 = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $fxVs 'build-verification-sample.ps1') -N 100 2>&1 | ForEach-Object { [string]$_ }
    if (($o2 -join ' ') -match 'already exists') { Ok 'the sampler refuses to overwrite an existing worklist without -Force (no redrawing until the answer is convenient)' }
    else { Bad 'the sampler silently redrew over an existing sample - a sample you may redraw at will is not a sample' }
  } else {
    Bad ('build-verification-sample did not produce a worklist from a valid frozen board (rc=' + $rcVs + '): ' + ($oVs -join ' | '))
  }
  # BLIND: no board at all must be exit 3, never a cheerful empty sample.
  $fxVsE = NewFxDir 'verif-sample-blind'
  New-Item -ItemType Directory -Force (Join-Path $fxVsE 'out') | Out-Null
  Copy-Item $bvsPath (Join-Path $fxVsE 'build-verification-sample.ps1')
  $oE = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $fxVsE 'build-verification-sample.ps1') 2>&1 | ForEach-Object { [string]$_ }
  if ($LASTEXITCODE -eq 3 -and ($oE -join ' ') -match 'BLIND') { Ok 'the sampler goes BLIND (exit 3) with no board to draw from, instead of reporting an empty sample' }
  else { Bad ('the sampler returned ' + $LASTEXITCODE + ' with no board present - a sample of nothing must never read as a result') }

  # ---- (c) THE ARITHMETIC. Frozen numbers, checked against hand-computed values -------------------------
  $mSt = [regex]::Match($rsvTxt, '# BEGIN-SAMPLE-STATS[\s\S]*?# END-SAMPLE-STATS')
  if (-not $mSt.Success) { Bad 'could not extract the BEGIN-SAMPLE-STATS region from record-sample-verdict.ps1 - the interval fixtures below CANNOT RUN' }
  else {
    $stx = & {
      Invoke-Expression $mSt.Value
      [pscustomobject]@{
        # MUST FIRE: 0 defects must NOT produce a zero-width interval. This is the founding bug in one line -
        # the Wald interval prints "0.0% +/- 0.0%" here, which is the false certainty of "ACCURACY 0 of 1,844".
        clean30  = (Get-WilsonInterval 0 30)
        clean100 = (Get-WilsonInterval 0 100)
        # the n=30 vs n=100 argument, at a 20% rate: +/-13.9 points against +/-7.8
        p20n30   = (Get-WilsonInterval 6 30)
        p20n100  = (Get-WilsonInterval 20 100)
        p02n100  = (Get-WilsonInterval 2 100)
        # MUST FIRE: the crown-weighted raw fraction is NOT the board rate. 7 defects in 100 drawn 60/40 over
        # a 492/2300 board is 7.0% raw and 3.8% reweighted - quote the raw one and the board is overstated 1.8x.
        strat    = (Get-StratifiedEstimate @(
                      [pscustomobject]@{ name = 'crown';    population = 492;  n = 60; x = 6 },
                      [pscustomobject]@{ name = 'noncrown'; population = 2300; n = 40; x = 1 }))
        # MUST FIRE: a stratum with ZERO verified cells contributes its whole weight as UNCERTAINTY. Dropping
        # it would be the zero-rows lie wearing a percentage sign.
        blindStratum = (Get-StratifiedEstimate @(
                      [pscustomobject]@{ name = 'crown';    population = 492;  n = 60; x = 6 },
                      [pscustomobject]@{ name = 'noncrown'; population = 2300; n = 0;  x = 0 }))
        # CLEAN TWIN: a census leaves nothing unsampled, so the finite-population correction must drive the
        # design-based half-width to EXACTLY zero. This is the twin that catches the FPC being silently
        # disabled - which is what a $Nh/$nh name collision did to this function while it was being written.
        census   = (Get-StratifiedEstimate @(
                      [pscustomobject]@{ name = 'crown';    population = 492;  n = 492;  x = 20 },
                      [pscustomobject]@{ name = 'noncrown'; population = 2300; n = 2300; x = 30 }))
        need1pt  = (Get-RequiredN 0.02 0.01 2792)
        need3pt  = (Get-RequiredN 0.02 0.03 2792)
        needCensus = (Get-RequiredN 0.20 0.01 2792)
        needBadTarget = (Get-RequiredN 0.20 0.0 2792)
        refuse29 = (Test-CanQuoteRate 29 30)
        refuse30 = (Test-CanQuoteRate 30 30)
        refuse0  = (Test-CanQuoteRate 0 30)
      }
    }
    if ($stx.clean30.hi -gt 0.10 -and $stx.clean30.hi -lt 0.13 -and $stx.clean100.hi -gt 0.03 -and $stx.clean100.hi -lt 0.04) {
      Ok ('ZERO defects still yields a real upper bound (0/30 -> up to ' + ('{0:N1}' -f (100 * $stx.clean30.hi)) + '%, 0/100 -> up to ' + ('{0:N1}' -f (100 * $stx.clean100.hi)) + '%) - a clean sample is never certainty')
    } else { Bad ('a zero-defect sample produced a collapsed interval (0/30 hi=' + $stx.clean30.hi + ', 0/100 hi=' + $stx.clean100.hi + ') - that is the Wald bug and it prints false certainty') }
    if ([Math]::Abs($stx.p20n30.half - 0.1390) -lt 0.002 -and [Math]::Abs($stx.p20n100.half - 0.0777) -lt 0.002 -and [Math]::Abs($stx.p02n100.half - 0.0323) -lt 0.002) {
      Ok 'Wilson half-widths match the hand-computed values (6/30 +/-13.9 pts, 20/100 +/-7.8, 2/100 +/-3.2) - the n=30 sample cannot tell a 10% board from a 30% board'
    } else { Bad ("Wilson arithmetic drifted: 6/30 half=$($stx.p20n30.half) (want 0.1390), 20/100 half=$($stx.p20n100.half) (want 0.0777), 2/100 half=$($stx.p02n100.half) (want 0.0323)") }
    if ([Math]::Abs($stx.strat.p - 0.0382) -lt 0.001 -and $stx.strat.p -lt 0.05 -and $stx.strat.x -eq 7 -and $stx.strat.n -eq 100) {
      Ok ('the crown-weighted draw is REWEIGHTED to the board (7/100 raw = 7.0% becomes ' + ('{0:N1}' -f (100 * $stx.strat.p)) + '% whole-board) - quoting the raw sample fraction would overstate the board 1.8x')
    } else { Bad ("the stratified reweighting is wrong or gone: p=$($stx.strat.p) (want 0.0382 from x=$($stx.strat.x)/n=$($stx.strat.n))") }
    if ($stx.blindStratum.hi -gt 0.80) { Ok ('a stratum with zero verified cells blows the whole-board ceiling to ' + ('{0:N0}' -f (100 * $stx.blindStratum.hi)) + '% instead of being silently dropped') }
    else { Bad ('an unsampled stratum was silently dropped from the interval (hi=' + $stx.blindStratum.hi + ') - 2,300 unchecked cells cannot read as agreement') }
    if ([Math]::Abs($stx.strat.nWald - 0.0415) -lt 0.002 -and $stx.census.nWald -lt 1e-9) {
      Ok 'the finite-population correction is live (60+40 of 2792 -> +/-4.2 pts design-based) and collapses to exactly zero on a census'
    } else { Bad ("the finite-population correction is disabled or wrong: sample nWald=$($stx.strat.nWald) (want ~0.0415), census nWald=$($stx.census.nWald) (want 0)") }
    if ($stx.need1pt -eq 594 -and $stx.need3pt -eq 82 -and $stx.needCensus -eq 1921 -and $stx.needBadTarget -eq -1) {
      Ok 'required-n is honest about its own limits: +/-3 pts at a 2% rate needs 82 cells, +/-1 pt needs 594, +/-1 pt at a 20% rate needs 1,921 of 2,792 (69% of the board - a census in all but name), and an impossible target returns -1'
    } else { Bad ("required-n arithmetic is wrong: 1pt@2%=$($stx.need1pt) 3pt@2%=$($stx.need3pt) 1pt@20%=$($stx.needCensus) badTarget=$($stx.needBadTarget) (want 594, 82, 1921, -1)") }
    if ((-not $stx.refuse29) -and $stx.refuse30 -and (-not $stx.refuse0)) { Ok 'the rate refusal is armed: 29 verified rows quote nothing, 30 do, and zero rows never do' }
    else { Bad ("the too-few-samples refusal is broken: 29=$($stx.refuse29) 30=$($stx.refuse30) 0=$($stx.refuse0)") }
  }

  # ---- (d) the recorder end to end, on the frozen sample it just drew ------------------------------------
  if (Test-Path $kyF) {
    function FxFill([string]$src, [string]$dst, [int]$howMany, [string]$verdict) {
      $ls = @(Get-Content $src)
      $acc = New-Object System.Collections.ArrayList
      $seen = 0
      foreach ($ln in $ls) {
        if ($ln -match '^\s*#' -or $ln -like 'ticket,*') { [void]$acc.Add($ln); continue }
        $seen++
        $tk = [regex]::Match($ln, '^"([0-9A-F]+)"').Groups[1].Value
        $v = if ($seen -le $howMany) { $verdict } else { '' }
        [void]$acc.Add('"' + $tk + '",' + $seen + ',"x","lb","ZZZ-Mart",' + $v + ',,,')
      }
      [IO.File]::WriteAllText($dst, (($acc.ToArray()) -join "`r`n") + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    }
    # MUST REFUSE: 12 verified rows is not a rate.
    FxFill $wlF (Join-Path $fxVs 'out\fx-few.csv') 12 'ok'
    $oR = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $fxVs 'record-sample-verdict.ps1') -VerdictFile (Join-Path $fxVs 'out\fx-few.csv') -SampleFile $kyF 2>&1 | ForEach-Object { [string]$_ }
    $rcR = $LASTEXITCODE
    if ($rcR -eq 3 -and ($oR -join ' ') -match 'NO RATE QUOTED') { Ok 'the recorder REFUSES to quote a defect rate from 12 verified cells (exit 3, could-not-evaluate)' }
    else { Bad ('the recorder quoted a rate from 12 cells (rc=' + $rcR + ') - a rate from 12 rows is not a small rate, it is not a rate: ' + ($oR -join ' | ')) }
    # ...and must never print a bare point estimate once it CAN quote: every rate arrives with an interval.
    FxFill $wlF (Join-Path $fxVs 'out\fx-all.csv') 100 'ok'
    $oR2 = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $fxVs 'record-sample-verdict.ps1') -VerdictFile (Join-Path $fxVs 'out\fx-all.csv') -SampleFile $kyF 2>&1 | ForEach-Object { [string]$_ }
    $rcR2 = $LASTEXITCODE
    $txtR2 = ($oR2 -join ' ')
    if ($rcR2 -eq 0 -and $txtR2 -match '95% CI' -and $txtR2 -match 'WHOLE BOARD' -and $txtR2 -match 'RESOLUTION') {
      Ok 'the recorder quotes a whole-board rate only WITH its 95% interval and states what n would resolve it'
    } else { Bad ('the recorder did not report an interval-bearing whole-board rate (rc=' + $rcR2 + '): ' + $txtR2) }
    # a 100-of-100 CLEAN sample must still refuse to claim the board is clean
    if ($txtR2 -match '95% CI 0\.0% to [1-9]') { Ok 'a 100-cell sample with ZERO defects still publishes a non-zero upper bound - "we found nothing" never becomes "there is nothing"' }
    else { Bad ('a zero-defect sample reported a zero-width whole-board interval - that is the clean bill of health that has never once been true here: ' + $txtR2) }
    # unverifiable rows must leave the DENOMINATOR, not pass as ok
    FxFill $wlF (Join-Path $fxVs 'out\fx-unv.csv') 100 'unverifiable'
    $oR3 = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $fxVs 'record-sample-verdict.ps1') -VerdictFile (Join-Path $fxVs 'out\fx-unv.csv') -SampleFile $kyF 2>&1 | ForEach-Object { [string]$_ }
    if ($LASTEXITCODE -eq 3 -and ($oR3 -join ' ') -match 'proved NOTHING') { Ok 'an all-unverifiable sample (bot walls) reports that it proved NOTHING - it never counts as 100 passes' }
    else { Bad ('an all-unverifiable sample was scored as a result (rc=' + $LASTEXITCODE + ') - a bot wall is not a clean cell: ' + ($oR3 -join ' | ')) }
  }
  Remove-Item $fxVs, $fxVsE -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------- BAKE CURRENCY (2026-07-31, triage round 2)
# FOUNDING BUG: category-excludes.json is the LIBRARY; apply-category-excludes.ps1 BAKES it into every
# commodity's own exclude list. Nothing enforced the bake. Measured 2026-07-31: the bake sat 2,165 patterns
# behind the library across 443 commodities, which is exactly why "Krave Garlic Truffle Wagyu Beef Jerky"
# could reach the GARLIC commodity while the library that forbids \bjerky\b on every Fruit/Vegetables
# commodity sat right there, already correct, for a day. A library nobody bakes protects nothing, and the
# blocking guard (audit-food-category) reads the same library, so the drift is invisible from both ends.
# Two things have to stay true, and they are different claims:
#   (1) the LIVE tree is current - a -WhatIf that wants to add nothing;
#   (2) the detector can still SEE drift - the frozen fixture pair, so (1) passing means something.
$r = RunPS 'apply-category-excludes.ps1' @('-WhatIf')
if ($r.rc -eq 0 -and $r.text -match '\+0 patterns across 0 commodities') { Ok 'bake-currency: the live commodities.json is CURRENT with category-excludes.json (nothing left to bake)' }
else { Bad ('bake-currency: the LIVE bake has DRIFTED behind the library - run apply-category-excludes.ps1, then re-run compare-deals and diff the board. It reports: ' + (($r.text -split "`n") | Select-Object -First 1)) }
# MUST-FIRE: a frozen miniature of the founding shape - garlic (a Vegetable) whose exclude list predates
# snack_carrier, against a library that already carries \bjerky\b and \bcrisps?\b. A correct bake wants to
# add BOTH to garlic and NOTHING to apples, which pins the load-bearing ^apples$ exempt in the same
# assertion (drop the exempt and this reads "+4 patterns across 2 commodities" and goes red).
$fxBakeD = Join-Path $fix 'bake-drifted'
$r = RunPS 'apply-category-excludes.ps1' @('-Root', $fxBakeD, '-WhatIf')
if ($r.rc -eq 0 -and $r.text -match '\+2 patterns across 1 commodities') { Ok 'bake-currency MUST-FIRE: a commodity whose exclude list predates a library class is reported as drift, and the apples exempt still exempts' }
else { Bad ('bake-currency did NOT see the drifted fixture (rc=' + $r.rc + '): ' + (($r.text -split "`n") | Select-Object -First 1) + ' - either the drift counter or the ^apples$ snack_carrier exempt has changed') }
# CLEAN TWIN: the same library against a tree that HAS been baked. A checker that cannot tell these two
# apart is measuring nothing, and the live +0 above would be worthless.
$r = RunPS 'apply-category-excludes.ps1' @('-Root', (Join-Path $fix 'bake-current'), '-WhatIf')
if ($r.rc -eq 0 -and $r.text -match '\+0 patterns across 0 commodities') { Ok 'bake-currency clean twin: an already-baked tree reports no drift' }
else { Bad ('bake-currency false-positived on an already-baked fixture (rc=' + $r.rc + '): ' + (($r.text -split "`n") | Select-Object -First 1)) }
# ...and the fixture must still be FROZEN afterwards. -WhatIf returns before the write, but a future edit
# that forgets -WhatIf would silently bake the fixture and the must-fire above would pass forever after by
# finding nothing - the [[guard-fixture-rule]] failure mode, one careless argument away.
if ((Get-Content (Join-Path $fxBakeD 'commodities.json') -Raw) -notmatch 'jerky') { Ok 'bake-currency fixture is still frozen (the drifted tree was not written to)' }
else { Bad 'the bake-drifted FIXTURE has been baked - it no longer encodes the drift, so its must-fire proves nothing. Restore it from git.' }

# ---------------------------------------------------------------- (d3) food-category: the round-2 classes
# MUST-FIRE for the 2026-07-31 library additions (household tampons/lip-balm, candy marshmallows, beverage
# tea/coffee/v8). All three rows below are REAL Baker's rows read during that review, frozen verbatim, and
# all three were live CANDIDATES on commodities they have no business being in: the tampons priced against
# HONEY, the marshmallow bag against fresh STRAWBERRIES (at $0.22/oz it already beat two real strawberry
# rows), and the tea bags against fresh LEMONS. None held a cell - what stopped them was a unit refusal or
# a sanity band, not the class library, which could not express any of these classes at all.
# FROZEN LITERALS. Never regenerate from the board: the products rotate out of Baker's catalog weekly, and
# a fixture rebuilt from live data would encode nothing.
$fxR2 = NewFxDir 'afc-round2'
$r2Bug = '{"week_of":"2026-07-31","comparison":[' +
  '{"commodity":"Honey","id":"honey","unit":"oz","stores":[{"store":"Baker''s","per_unit":0.4994,"item":"Honey Pot 100% Organic Cotton Core Duo Pack Tampons, 18 Count"}]},' +
  '{"commodity":"Strawberries","id":"strawberries","unit":"oz","stores":[{"store":"Baker''s","per_unit":0.22,"item":"De La Rosa Strawberry & Vanilla Marshmallows"}]},' +
  '{"commodity":"Lemons","id":"lemons","unit":"each","stores":[{"store":"Baker''s","per_unit":0.1895,"item":"Bigelow Lemon Lift Black Tea Bags"}]}]}'
Set-Content (Join-Path $fxR2 'comparison-2026-07-31.json') $r2Bug -Encoding UTF8
$r = RunPS 'audit-food-category.ps1' @('-OutDir', $fxR2)
if ($r.rc -eq 2 -and $r.text -match 'household' -and $r.text -match 'candy' -and $r.text -match 'beverage' -and $r.text -match 'honey' -and $r.text -match 'strawberries' -and $r.text -match 'lemons') {
  Ok 'food-category MUST-FIRE: tampons on honey, marshmallows on strawberries and tea bags on lemons all hard-fail (exit 2) and each names its class'
} else {
  Bad ('food-category did NOT catch the round-2 rows (rc=' + $r.rc + ') - the household tampons/lip-balm, candy marshmallows or beverage tea/coffee/v8 tokens are gone from category-excludes.json: ' + ($r.text -replace "`n", ' '))
}
# CLEAN TWIN: the SAME three commodities priced from the real products that hold those cells today. A token
# broad enough to flag these would take the board down daily, which is how a guard gets switched off.
$r2Clean = '{"week_of":"2026-07-31","comparison":[' +
  '{"commodity":"Honey","id":"honey","unit":"oz","stores":[{"store":"Sam''s Club","per_unit":0.1662,"item":"Member''s Mark Wildflower Pure Premium Honey, 48 oz."}]},' +
  '{"commodity":"Strawberries","id":"strawberries","unit":"oz","stores":[{"store":"Aldi","per_unit":0.1181,"item":"Strawberries"}]},' +
  '{"commodity":"Lemons","id":"lemons","unit":"each","stores":[{"store":"Walmart","per_unit":0.5,"item":"Fresh Lemon"}]}]}'
Set-Content (Join-Path $fxR2 'comparison-2026-07-31.json') $r2Clean -Encoding UTF8
$r = RunPS 'audit-food-category.ps1' @('-OutDir', $fxR2)
if ($r.rc -eq 0) { Ok 'food-category clean twin: the real honey / strawberries / lemons cells stay silent under the round-2 classes' }
else { Bad ('food-category flagged REAL cells (rc=' + $r.rc + ') - a round-2 token is too broad: ' + ($r.text -replace "`n", ' ')) }
Remove-Item $fxR2 -Recurse -Force -ErrorAction SilentlyContinue

# ---- (f) THE TRIAGE PIPELINE'S OWN WATCHERS (2026-07-31) -----------------------------------------------
# Two pieces of the alert-to-fix loop carry their own frozen self-tests. They are only worth having if
# something RUNS them, so they run here, daily, with the rest of the watchers.
#   * send-alert's queue routing: a still-open condition that re-fires on a later day must absorb into the
#     SAME id (five of 2026-07-31's fourteen alerts were one condition wearing two ids), while a RESOLVED
#     one must mint a new id, because a fix that did not hold is different news from a fix nobody tried.
#   * validate-triage-plan: the handoff gate between the reviewer and the developer. Its must-fire cases
#     are the two mistakes this estate actually made - a blast radius measured as token matches instead of
#     routing outcomes, and a widened include with no claimed_by_earlier.
$r = RunPS 'send-alert.ps1' @('-SelfTest')
if ($r.rc -eq 0 -and $r.text -match 'SELF-TEST PASS') { Ok 'send-alert: queue routing (cross-day absorb, resolved-mints-new) + body-thin detection' }
else { Bad ('send-alert -SelfTest failed (rc=' + $r.rc + ') - the triage queue may be minting a new id per day for one condition, or absorbing one it should not: ' + ($r.text -replace "`n", ' ')) }

$r = RunPS 'validate-triage-plan.ps1' @('-SelfTest')
if ($r.rc -eq 0 -and $r.text -match 'SELF-TEST PASS') { Ok 'validate-triage-plan: the reviewer-to-developer handoff gate still rejects a token-match blast radius and an unclaimed include' }
else { Bad ('validate-triage-plan -SelfTest failed (rc=' + $r.rc + ') - the plan gate is not enforcing what it claims: ' + ($r.text -replace "`n", ' ')) }

# ---- (g) THE PROMPTS THEMSELVES ARE CODE (2026-07-31) --------------------------------------------------
# The agents and scheduled-task SKILLs that drive all of this were the only unversioned thing left, and on
# the day this check was written SIX of eight agent prompts had already drifted between project scope and
# user scope - same name, two files, quietly disagreeing, and which one runs depends on the session's
# working directory. Same two-copies-of-one-truth trap as pu-lib and the category-exclude bake.
# The audit lives outside grocery\ (it is estate-wide), so call it by path.
$pb = Join-Path (Split-Path $root -Parent) 'ops\audit-prompt-backup.ps1'
if (Test-Path $pb) {
  $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $pb 2>&1 | ForEach-Object { [string]$_ }
  $rc = $LASTEXITCODE; $txt = ($out -join "`n")
  if ($rc -eq 0) { Ok 'prompt-backup: every agent prompt and scheduled-task SKILL is backed up in ops\prompt-backup and identical across scopes' }
  elseif ($rc -eq 3) { Bad ('prompt-backup went BLIND (found zero live prompts) - the .claude paths moved: ' + ($txt -replace "`n", ' ')) }
  else { Bad ('prompt-backup drift (rc=' + $rc + ') - run ops\audit-prompt-backup.ps1 -Sync and commit: ' + ($txt -replace "`n", ' ')) }
} else { Bad 'prompt-backup audit is MISSING from ops\ - the agent prompts have no backup check' }

# ---- (h) THE DISPLAY FORMATTER (2026-07-31) ------------------------------------------------------------
# Two wrong numbers reached shoppers through the formatter, not the pipeline: "356&cent;/oz" on Mint (fresh)
# because the ounce branch never rolled over to dollars, and "Cotton Swabs $0.00 each, ties record" because
# a real $0.0043-per-swab price has no second decimal to land in. Both were invisible to every existing
# guard, which all watch prices and none watched the printing of them. fmt-lib carries the frozen
# founding cases plus clean twins; this is what runs them daily.
$r = RunPS 'fmt-lib.ps1' @('-SelfTest')
if ($r.rc -eq 0 -and $r.text -match 'SELF-TEST PASS') { Ok 'fmt-lib: per-unit display still rolls over at a dollar and still shows a real sub-cent price' }
else { Bad ('fmt-lib -SelfTest failed (rc=' + $r.rc + ') - the board can print a three-digit cent price or a $0.00 record again: ' + ($r.text -replace "`n", ' ')) }

# ---- (i) THE TWO ACCURACY WATCHERS ADDED 2026-08-01 ---------------------------------------------------
# basis-outlier: catches a wrong BASIS by arithmetic when nothing in the row declares one - the Aldi
# multipack shape, where the name, the size and the price are internally consistent and completely wrong.
# consistency chip-kind: the ad-pill branch is a SKIP, and a skip with no must-fire behind it is how a
# guard stops being able to see its own bug. Its fixture proves a priced chip with NO link still breaches.
$r = RunPS 'audit-unit-basis-outlier.ps1' @('-SelfTest')
if ($r.rc -eq 0 -and $r.text -match 'SELF-TEST PASS') { Ok 'basis-outlier: still catches a pack price on a single-unit size, and still stays silent on an ordinary premium spread' }
else { Bad ('audit-unit-basis-outlier -SelfTest failed (rc=' + $r.rc + ') - a wrong-basis cell can reach the board unremarked: ' + ($r.text -replace "`n", ' ')) }

$r = RunPS 'audit-board-consistency.ps1' @('-SelfTest')
if ($r.rc -eq 0 -and $r.text -match 'SELF-TEST PASS') { Ok 'board-consistency: a flyer-only ad pill is not a breach, and a priced chip with no link still is' }
else { Bad ('audit-board-consistency -SelfTest failed (rc=' + $r.rc + ') - the ad-pill skip may now be swallowing genuinely linkless prices: ' + ($r.text -replace "`n", ' ')) }
# ---- (j) THE SEMANTIC SIDECAR'S ESTATE-SIDE PLUMBING (2026-08-01) --------------------------------------
# The GPU sweep itself is not run here (it needs a card, and a watcher that needs hardware is a watcher
# that goes BLIND on the cloud runner). What IS asserted daily is the part that decides whether a finding
# reaches a human: a fresh finding must be actionable, an ALREADY-ADJUDICATED cell must not be re-reported
# as new, and a malformed finding must be rejected. If that filter inverts, the advisory feed either spams
# the arrivals desk with settled rulings or silently swallows real ones.
$r = RunPS 'audit-semantic-identity.ps1' @('-SelfTest')
if ($r.rc -eq 0 -and $r.text -match 'SELF-TEST PASS') { Ok 'semantic-identity: the actionable filter still admits fresh findings and still suppresses settled rulings' }
else { Bad ('audit-semantic-identity -SelfTest failed (rc=' + $r.rc + ') - the semantic advisory feed may be re-reporting adjudicated cells or dropping real ones: ' + ($r.text -replace "`n", ' ')) }
# ---- (k) THE FAREWAY SIZE SURFACE (2026-08-01, triage 2026-08-01-9da3a8) -------------------------------
# Fareway's storefront DOM often omits the pack size, so the builder now reads it from the catalog slug.
# That surface is unreliable in four proven ways (dropped decimal, leading zero, per-unit size on a
# multipack, stale token), and each refusal is a row that would otherwise be published at a wrong per-unit
# or dropped for "disagreeing" with itself. Both directions are silent on a healthy board - a wrong size
# just looks like a price, and a quarantined row just looks like a store that does not carry the item -
# so the fixtures are the only thing that can see them. They are frozen from the real 2026-07-31 rows.
$r = RunPS 'build-fareway-regular.ps1' @('-SelfTest')
if ($r.rc -eq 0 -and $r.text -match 'SELF-TEST PASS') { Ok 'fareway slug sizes: counts still recovered, the four slug defects still refused, and the milk/eggs basis relabel still cannot eat a real size' }
else { Bad ('build-fareway-regular -SelfTest failed (rc=' + $r.rc + ') - Fareway can publish a pack price as a unit price again, or quarantine correct rows: ' + ($r.text -replace "`n", ' ')) }

$r = RunPS 'heal-degraded-sizes.ps1' @('-Store','fareway','-SelfTest')
if ($r.rc -eq 0 -and $r.text -match 'SELF-TEST PASS') { Ok 'size-heal: still heals across a store RENAME on the catalog product id, and still refuses when the price moved' }
else { Bad ('heal-degraded-sizes -SelfTest failed (rc=' + $r.rc + ') - a renamed product loses its pack size again and the band drops the store: ' + ($r.text -replace "`n", ' ')) }

# ---------------------------------------------------------------- as_of laundering (2026-08-02, C3 sample)
# THE ONLY BUG CLASS WHERE THE DETECTOR ITSELF IS THE VICTIM. build-fareway-regular merges every extract on
# disk and used to stamp them all with the BUILD date: 431 of 577 live rows wore a date newer than the
# capture that produced them, and guard 9 - which measures freshness as "as_of == today" - reported a
# fabricated 78% against a true 6%. Nothing downstream could see it, because every freshness check in the
# estate reads as_of and as_of said the rows were fresh. The C3 out-of-band sample found the shopper end:
# ranch dressing published at $0.99 as_of today, last actually captured 07-23, real shelf price $2.48.
# THREE watchers, and all three have to keep working: the builder must date from the extract, the guard must
# fail when something re-launders, and the repair must undo dates inherited from pre-fix files.
$r = RunPS 'audit-asof-evidence.ps1' @('-SelfTest')
if ($r.rc -eq 0 -and $r.text -match 'SELF-TEST PASS') { Ok 'as_of evidence: a row dated fresher than any capture that holds it still fires, and a carried OLDER date still does not' }
else { Bad ('audit-asof-evidence -SelfTest failed (rc=' + $r.rc + ') - the freshness guards can be fed an invented date again: ' + ($r.text -replace "`n", ' ')) }

$r = RunPS 'repair-asof-evidence.ps1' @('-Store','fareway','-SelfTest')
if ($r.rc -eq 0 -and $r.text -match 'SELF-TEST PASS') { Ok 'as_of repair: still re-dates a laundered row DOWN to its evidence, still never forward, still leaves unbacked rows alone' }
else { Bad ('repair-asof-evidence -SelfTest failed (rc=' + $r.rc + ') - dates inherited from pre-fix files stay laundered: ' + ($r.text -replace "`n", ' ')) }

# The builder's own dating cases live in its -SelfTest above, but that test passes if the fixture stops
# REACHING the dating code. Pin the three things the (q)-(t) cases depend on: the param, the per-extract
# stamp, and the tail call. Each one was a live bug the day this was written.
$bfrSrc = Get-Content (Join-Path $root 'build-fareway-regular.ps1') -Raw
if ($bfrSrc -match '\$MaxExtractDays' -and $bfrSrc -match 'as_of=\$srcAsOf') { Ok 'fareway builder still dates each row from the EXTRACT it came from, not the build date' }
else { Bad 'build-fareway-regular no longer stamps as_of from the source extract ($srcAsOf) - the laundering is back and guard 9 will read 100% freshness on a stale file' }
if ($bfrSrc -match 'repair-asof-evidence\.ps1') { Ok 'fareway builder still runs the as_of repair after carry-forward' }
else { Bad 'build-fareway-regular no longer calls repair-asof-evidence - carried rows keep whatever date a pre-fix file gave them' }

# ---------------------------------------------------------------- Sam's verified-row refresh (2026-08-02)
# build-sams-deals refuses any row it cannot check with qty = linePrice / unitPrice, which is correct and
# permanent - but it leaves the "sft" goods (foil/wrap/parchment/toilet paper, 45 of 74 rejects) and the
# no-unitPrice goods (cauliflower, pineapple, rotisserie chicken, 20 more) unbuildable forever. This takes
# the store's current price and keeps the size that was already hand-verified. Every refusal in its fixture
# is a way that move can go wrong, and each one publishes a wrong PRICE if it stops firing.
$r = RunPS 'refresh-sams-verified.ps1' @('-SelfTest')
if ($r.rc -eq 0 -and $r.text -match 'SELF-TEST PASS') { Ok "Sam's verified refresh: still re-prices sft/no-unitPrice rows, and still refuses an ambiguous price, a changed pack, a per-unit size and a size that is a price" }
else { Bad ('refresh-sams-verified -SelfTest failed (rc=' + $r.rc + ") - Sam's hand-verified rows either stay stale or get re-priced against the wrong pack: " + ($r.text -replace "`n", ' ')) }

# ---------------------------------------------------------------- mixed-vegetable medleys (2026-08-02)
# A PRODUCT THAT NAMES A SECOND VEGETABLE IS NOT THE FIRST ONE. Walmart carries seven broccoli/cauliflower/
# carrot blends and every one of them matched a SINGLE-vegetable commodity: the fresh medley matched
# broccoli AND cauliflower, and the two Birds Eye frozen blends matched CARROTS - a victim nobody had
# noticed, because the rules that already said "medley" and "mixed veg" say nothing about "California Blend".
# Nothing showed on the board only because each blend happened to lose on price to the real vegetable beside
# it; the day Walmart's plain broccoli goes missing, the medley IS the broccoli cell.
# THE PREVIOUS TWO ATTEMPTS WERE BOTH REVERTED BY THE GATES, and the fixture below is why: excluding a blend
# from two commodities just moves it to the third. Adding \bcarrots?\b was not in the plan either - it came
# from watching 'Birds Eye Shredded Carrots & Broccoli Florets' hop OFF carrots and ONTO broccoli in the
# match-soundness report. So this pins the whole family at once, in both directions.
$cmMed = Get-Content (Join-Path $root 'commodities.json') -Raw | ConvertFrom-Json
function Get-MatchingCommodities([string]$name, $catalog) {
  $hits = New-Object System.Collections.Generic.List[string]
  foreach ($cm in $catalog) {
    $inc = @($cm.include); if ($inc.Count -eq 0) { continue }
    $ok = $false
    foreach ($p in $inc) { if ($name -match $p) { $ok = $true; break } }
    if (-not $ok) { continue }
    $bad = $false
    foreach ($p in @($cm.exclude)) { if ($p -and ($name -match $p)) { $bad = $true; break } }
    if (-not $bad) { $hits.Add([string]$cm.id) }
  }
  return $hits
}
# FROZEN: every name below is verbatim from out\regular\walmart-regular-2026-08-01.json.
$SINGLE_VEG = @('broccoli', 'cauliflower', 'frozen-broccoli', 'carrots')
$medleyMust = @(
  'Marketside Fresh Broccoli and Cauliflower Medley, 12 oz',
  'Birds Eye California Blend with Carrots, Broccoli, Cauliflower, Frozen Vegetables, 60 oz. Bag',
  'Birds Eye Steamfresh Carrots, Broccoli and Cauliflower, Frozen Vegetables, 10.8 oz. Bag',
  'Great Value Steamable Broccoli & Cauliflower Florets, 12 oz',
  'Birds Eye Shredded Carrots & Broccoli Florets',
  'Birds Eye Oven Roasters Seasoned Broccoli and Cauliflower, Frozen Vegetables, 14 oz. Bag',
  'Pictsweet Farms Frozen Broccoli Florets, Red Potatoes & Carrots Vegetables for Roasting'
)
$medleyLeak = @()
foreach ($n in $medleyMust) {
  $hit = @(Get-MatchingCommodities $n $cmMed)
  foreach ($s in $SINGLE_VEG) { if ($hit -contains $s) { $medleyLeak += ($s + ' <- ' + $n) } }
}
if ($medleyLeak.Count -eq 0) { Ok 'medley rules: no broccoli/cauliflower/carrot BLEND matches a single-vegetable commodity (all 7 live Walmart blends)' }
else { Bad ('a mixed-vegetable blend is matching a single-vegetable commodity again - it will take that cell the day the real vegetable is dearer or missing: ' + ($medleyLeak -join ' | ')) }
# CLEAN TWINS - the plain vegetables must still match, or the excludes have eaten the commodity they protect.
$medleyTwin = @(
  @{ n = 'Great Value Broccoli Florets, 14 oz';            want = 'broccoli' },
  @{ n = 'Great Value Broccoli Florets, 32 oz Bag (Frozen)'; want = 'frozen-broccoli' },
  @{ n = 'Fresh Whole White Cauliflower';                  want = 'cauliflower' },
  @{ n = 'Marketside Whole Carrots, 2 lb Bag';             want = 'carrots' },
  @{ n = 'Our Family Mixed Vegetables, Fresh Frozen 24 Oz'; want = 'frozen-vegetables' }
)
$twinMiss = @()
foreach ($t in $medleyTwin) { if (-not (@(Get-MatchingCommodities $t.n $cmMed) -contains $t.want)) { $twinMiss += ($t.want + ' NO LONGER matches ' + $t.n) } }
if ($twinMiss.Count -eq 0) { Ok 'medley rules CLEAN TWIN: plain broccoli/cauliflower/carrots and "Fresh Frozen" mixed veg still match their own commodity' }
else { Bad ('the medley excludes have eaten a real product - a missing cell is the cost of an exclude written too wide: ' + ($twinMiss -join ' | ')) }
if ($failed -eq 0) { Write-Output ("test-auditors PASS  ($pass check(s)) - every watcher can still see its own bug."); exit 0 }
Write-Output ("test-auditors FAIL  ($failed failed, $pass passed) - a watcher has gone blind. Fix it before trusting a quiet board."); exit 2

