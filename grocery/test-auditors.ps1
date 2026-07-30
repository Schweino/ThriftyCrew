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

# ---------------------------------------------------------------- 1. basis reconciler
# MUST FIRE: Hy-Vee published $3.15/lb for corned beef brisket while the store's own size text printed
# "($8.99/lb)" right there on the same row.
$r = RunPS 'audit-basis-reconcile.ps1' @('-CompareFile', (Join-Path $fix 'basis-conflict-board.json'))
if ($r.text -match 'corned-beef-brisket' -and $r.text -match 'disagree') { Ok 'basis-reconcile FIRES on the per-lb-rate conflict' }
else { Bad ('basis-reconcile MISSED its founding bug: ' + $r.text) }
# MUST BE SILENT: same board with the cell corrected to the store's own rate.
$r = RunPS 'audit-basis-reconcile.ps1' @('-CompareFile', (Join-Path $fix 'basis-clean-board.json'))
if ($r.text -match 'ok - every checkable cell agrees') { Ok 'basis-reconcile SILENT on the corrected board' }
else { Bad ('basis-reconcile false-positived on a clean board: ' + $r.text) }
# MUST NOT trip on sub-cent rounding (a store publishing "$0.01/ea" against our $0.0053 is rounding, not conflict)
$r = RunPS 'audit-basis-reconcile.ps1' @('-CompareFile', (Join-Path $fix 'basis-rounding-board.json'))
if ($r.text -match 'ok - every checkable cell agrees') { Ok 'basis-reconcile ignores whole-cent rounding noise' }
else { Bad ('basis-reconcile tripped on cent rounding: ' + $r.text) }

# ---------------------------------------------------------------- 1b. Baker's netWeight source
# Kroger returns NO unit price, so netWeight (the store's own package weight) is the only independent
# statement available for the estate's largest store. MUST FIRE on the 2026-07-24 Kerrygold class: reading
# "4 ct / 16 oz" as 16 oz PER STICK priced the pack 4x under and no band blinked.
$rawFx = Join-Path $fix 'bakers-raw'
$r = RunPS 'audit-basis-reconcile.ps1' @('-CompareFile', (Join-Path $fix 'bakers-netweight-conflict-board.json'), '-RawDir', $rawFx)
if ($r.text -match 'butter' -and $r.text -match 'netWeight') { Ok "basis-reconcile FIRES when Baker's size disagrees with Kroger's own netWeight" }
else { Bad ('basis-reconcile missed the netWeight conflict: ' + $r.text) }
# MUST BE SILENT once the size is read correctly...
$r2 = RunPS 'audit-basis-reconcile.ps1' @('-CompareFile', (Join-Path $fix 'bakers-netweight-clean-board.json'), '-RawDir', $rawFx)
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
$r = RunPS 'audit-basis-reconcile.ps1' @('-CompareFile', (Join-Path $fix 'bakers-namecollision-board.json'), '-RawDir', (Join-Path $fix 'bakers-raw-collision'))
if ($r.text -match 'ok - every checkable cell agrees' -and $r.text -match 'checked 1 cell') { Ok 'basis-reconcile picks the right row when two products share one name' }
else { Bad ('basis-reconcile cross-matched two products sharing a name: ' + $r.text) }

# ---------------------------------------------------------------- 2. pack-basis heuristic
# MUST FIRE: Sam's Pledge 3-pack whose 29 oz TOTAL was multiplied into an 87 oz each-size, making it the
# cheapest furniture polish in Omaha at a third of its real price.
$r = RunPS 'audit-pack-basis.ps1' @('-CompareFile', (Join-Path $fix 'packbasis-board.json'))
if ($r.text -match 'furniture-polish' -and $r.text -match 'multiplied') { Ok 'pack-basis FIRES on the Pledge pack-total bug' }
else { Bad ('pack-basis MISSED its founding bug: ' + $r.text) }
# MUST BE SILENT on genuine bulk: 24 ct x 16.9 fl oz water and a 3 pk x 5 lb grits really are that cheap.
$r = RunPS 'audit-pack-basis.ps1' @('-CompareFile', (Join-Path $fix 'packbasis-legit-bulk-board.json'))
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

# ---------------------------------------------------------------- N+1. batch importers must read UTF-8
# The four batch importers used a bare Get-Content, which in PS 5.1 decodes a UTF-8 capture as Windows-1252
# and then SAVES the damage - the same bug that shipped 16 mangled board rows on 2026-07-29, 6 of them crowns.
# Source-grep that they are wired, then PROVE the decode end to end on a real UTF-8-no-BOM file, because a
# grep alone passes on an importer that dot-sources capture-lib and then ignores it.
foreach ($imp in @('import-browser-batch.ps1','import-walmart-batch.ps1','import-instacart-batch.ps1','import-aldi-batch.ps1')) {
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

if ($failed -eq 0) { Write-Output ("test-auditors PASS  ($pass check(s)) - every watcher can still see its own bug."); exit 0 }
Write-Output ("test-auditors FAIL  ($failed failed, $pass passed) - a watcher has gone blind. Fix it before trusting a quiet board."); exit 2
