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

if ($failed -eq 0) { Write-Output ("test-auditors PASS  ($pass check(s)) - every watcher can still see its own bug."); exit 0 }
Write-Output ("test-auditors FAIL  ($failed failed, $pass passed) - a watcher has gone blind. Fix it before trusting a quiet board."); exit 2
