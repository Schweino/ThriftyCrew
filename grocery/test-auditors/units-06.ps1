
# ---------------------------------------------------------------- (u3) ff-carry: REACHABLE from the
# path the schedule actually takes (2026-09-02, queue 2026-09-02-c9c140).
# (u2) above proves ff-carry's own fixtures can run and that its caller reads its exit code. Neither
# question is worth anything if the caller never executes, and from 2026-08-23 to 2026-09-02 it did not:
# the invocation sat inside check-ad-cycles' `if (-not $NoPull)` block, and since 9f938a5b EVERY scheduled
# caller passes -NoPull (capture-run.ps1 -Kind daily is the one that reaches the downstream; the file now
# REFUSES to pull without -ForcePull). Measured: '] ff-carry:' appears 0 times in 1,771 lines of
# ad-cycle-log.txt and the last coverage-ledger row was 2026-08-29 17:21:15. Only the ledger's STALE arm
# noticed, three days late. That is the tested-is-not-run class: a guard whose only path to execution is a
# code path nobody takes. Structural, because the behaviour needs a scheduled morning to observe.
function Test-FfCarryReachable([string]$cacText) {
  $ls = $cacText -split "`r?`n"
  $pullIx = -1; for ($i = 0; $i -lt $ls.Count; $i++) { if ($ls[$i] -match '^\s*\$pullOk = \$NoPull') { $pullIx = $i; break } }
  if ($pullIx -lt 0) { return [pscustomobject]@{ ok = $false; why = 'could not find $pullOk = $NoPull - the -NoPull block has moved and this case is blind' } }
  $closeIx = -1; for ($i = $pullIx + 1; $i -lt $ls.Count; $i++) { if ($ls[$i] -eq '  }') { $closeIx = $i; break } }
  if ($closeIx -lt 0) { return [pscustomobject]@{ ok = $false; why = 'could not find the -NoPull block closing brace' } }
  $fcIx = -1; for ($i = 0; $i -lt $ls.Count; $i++) { if ($ls[$i] -match '^\s*\$fcArgs = @\(') { $fcIx = $i; break } }
  if ($fcIx -lt 0) { return [pscustomobject]@{ ok = $false; why = 'audit-ff-carry is not invoked from check-ad-cycles at all any more' } }
  return [pscustomobject]@{ ok = ($fcIx -gt $closeIx); why = ('$fcArgs at line ' + ($fcIx + 1) + '; the -NoPull block closes at line ' + ($closeIx + 1)); fc = $fcIx; close = $closeIx }
}
if (Use-Unit 'u093-u2-above-proves-ff-carry-s-own') {
$ffcReach = Test-FfCarryReachable $cacSrc
if ($ffcReach.ok) { Ok ('audit-ff-carry is invoked OUTSIDE the -NoPull block, so the scheduled chain runs it (' + $ffcReach.why + ')') }
else { Bad ('audit-ff-carry is only reachable on the pull path every scheduled caller skips - ' + $ffcReach.why) }
# MUST-FIRE: the same file with the block put back where it was must fail this case. A structural check
# that has never been shown to go red is an assertion about a string, not a guard.
$ffcLs = $cacSrc -split "`r?`n"
# The block moved BELOW the publish on 2026-09-19 (it re-probes Freshop live and was costing the ship
# path 118 s of 726 s), so the mutation splices it from its new header. Matching the old
# '# ---- REACHABILITY (2026-09-02' marker still finds a line - the historical note stayed behind at the
# old site - but that line is now ~2,500 lines above the code, so the splice swallowed half the file and
# the case went INERT while reporting itself green. A mutation built from a marker that no longer bounds
# the thing it names proves nothing, which is what this very case exists to say.
$ffcBs = -1; for ($i = 0; $i -lt $ffcLs.Count; $i++) { if ($ffcLs[$i] -match '^\s*# ---- FF PULL-COMPLETENESS GUARD, AFTER THE PUBLISH') { $ffcBs = $i; break } }
$ffcBe = -1; for ($i = [Math]::Max($ffcBs, 0); $i -lt $ffcLs.Count; $i++) { if ($ffcLs[$i] -match "^\s*\} catch \{ Log \('ff-carry guard threw:") { $ffcBe = $i; break } }
if ($ffcBs -lt 0 -or $ffcBe -lt $ffcBs -or $ffcReach.close -lt 0 -or $ffcReach.close -ge $ffcBs) {
  Bad 'could not build the must-fire mutation for ff-carry reachability - this case proved NOTHING'
} else {
  $ffcMut = @($ffcLs[0..($ffcReach.close - 1)] + $ffcLs[$ffcBs..$ffcBe] + $ffcLs[$ffcReach.close..($ffcBs - 1)] + $ffcLs[($ffcBe + 1)..($ffcLs.Count - 1)]) -join "`n"
  $ffcMutR = Test-FfCarryReachable $ffcMut
  if (-not $ffcMutR.ok) { Ok 'MUST-FIRE: the pre-fix layout (ff-carry back inside the pull block) fails the reachability case' }
  else { Bad ('MUST-FIRE inert: the reachability case passes even with ff-carry back inside the -NoPull block - ' + $ffcMutR.why) }
}
} # u093-u2-above-proves-ff-carry-s-own

# ---------------------------------------------------------------- (sp1) the chain stages what it rewrites
# 2026-09-02, queue 2026-09-02-reanch1. capture-run's $servedPaths was enumerated from "the exact set real
# bot commits have ever touched" and cannot see a writer that joined the chain later. reanchor-all
# (check-ad-cycles:774) rewrote 584 authored specs and the surface builders (:1162) rebuilt three data files
# and spliced three tool pages, all after guards - and 536 of those files sat dirty until a human swept them
# by hand as 26c2b0e0 while the bot commit 91f895ef shipped graph/, grocery/ and out/ only. The runtime
# served-dirty check lives in test-commit-size-gate; this is the cheap structural half: the paths are named.
if (Use-Unit 'u094-sp1-the-chain-stages-what-it') {
$crSrc = Get-Content (Join-Path (Split-Path $root -Parent) 'lib\bot-paths.ps1') -Raw
$spI = $crSrc.IndexOf('function Get-BotServedPaths')
$spJ = $crSrc.IndexOf('function Get-BotGlobPaths', [Math]::Max($spI, 0))
if ($spI -lt 0 -or $spJ -le $spI) { Bad 'could not locate Get-BotServedPaths in lib\bot-paths.ps1 - this case is blind' }
else {
  $spBlock = $crSrc.Substring($spI, $spJ - $spI)
  $spMissing = @()
  foreach ($spNeed in @('meal-prep/db/recipes', 'meal-prep/cheapnow-data.js', 'meal-prep/dinner-data.js', 'meal-prep/stretcher-data.js')) {
    if ($spBlock -notmatch [regex]::Escape("'" + $spNeed + "'")) { $spMissing += $spNeed }
  }
  if ($spMissing.Count -eq 0) { Ok 'Get-BotServedPaths stages the specs and the three data files the chain rewrites after guards' }
  else { Bad ('Get-BotServedPaths no longer names: ' + ($spMissing -join ', ') + ' - the chain rewrites them after guards and the bot commit will leave them dirty on the tree again (2026-09-02, 536 files)') }
}
} # u094-sp1-the-chain-stages-what-it

# ------------------------------------------- (u3) ff-pull: the alert that could never be false, and the write that could
# 2026-08-02 (triage plan item 2026-08-02-91d877). pull-regular-familyfare.ps1 HAS had a -SelfTest since
# 2026-07-31 and NOTHING in this harness ran it, so its fixtures were frozen evidence nobody looked at daily.
# They now guard two things, and both were real:
#   - the expiry alert arm. `expired > 0` was re-keyed to MEASURED term starvation because the merged catalog
#     is a name-keyed UNION of top-25 search responses: renames, ranking drift, delistings and the multi-buy
#     skip retire NAMES while Family Fare still sells the PRODUCT, so a trickle of 14-day expiries is the
#     healthy steady state and the old arm could never stay false. It paged on 2026-08-02 over 55 rows that
#     cost the board zero crowns and zero commodities. That exact false page is now the CLEAN TWIN.
#   - the merged write. At 2026-08-02T07:06:41 a bare Set-Content under EAP=Stop hit a file lock AFTER the
#     cursor had advanced #458 -> #35, so 686 rows across ~104 terms were discarded while the cursor skipped
#     the terms that bought them. The write is atomic and retried now, and the cursor only commits behind it.
# Checked STRUCTURALLY before invoking, because an invocation alone cannot tell "fixtures passed" from
# "fixtures were skipped" - and because under -File an undeclared -SelfTest lands in $args and would run a
# REAL Freshop pull, spending a scheduled sweep's request budget from inside the test harness.
if (Use-Unit 'u095-u3-ff-pull-the-alert-that-could') {
$ffpS = Get-Content (Join-Path $root 'pull-regular-familyfare.ps1') -Raw
if ($ffpS -match '\[switch\]\$SelfTest') { Ok 'pull-regular-familyfare declares [switch]$SelfTest (its fixture block is reachable, and -SelfTest cannot fall through to a live pull)' }
else { Bad 'pull-regular-familyfare has no [switch]$SelfTest on param() - -SelfTest would land in $args and run a REAL Freshop pull, burning a scheduled sweep budget and looking like a passing test' }
$ffpSelfIdx = $ffpS.IndexOf('if ($SelfTest) {')
$ffpNetIdx  = $ffpS.IndexOf('$tok = Get-FreshToken')
if ($ffpSelfIdx -ge 0 -and $ffpNetIdx -gt $ffpSelfIdx) { Ok 'pull-regular-familyfare runs its fixtures ABOVE every network call (a -SelfTest run cannot touch Freshop)' }
else { Bad 'pull-regular-familyfare -SelfTest block is no longer above its first Freshop call - running the fixtures now spends live request budget' }
$r = RunPS 'pull-regular-familyfare.ps1' @('-SelfTest')
if ($r.rc -eq 0 -and $r.text -match 'SELF-TEST PASS' -and $r.text -match 'MUST-FIRE' -and $r.text -match 'CLEAN-TWIN') { Ok 'ff-pull -SelfTest passes with its must-fire and clean-twin fixtures armed' }
else { Bad ('ff-pull -SelfTest failed or lost its fixtures: rc=' + $r.rc + ' ' + ((($r.text -split "`n") | Select-Object -Last 3) -join ' | ')) }
# The individual fixtures, named, so a silent deletion of any ONE of them is a failure rather than a shorter
# pass. These are the frozen founding cases; never regenerate them from a live pull.
if ($r.text -match "today's real false page stays SILENT") { Ok "the 2026-08-02 false page (4655/4706, 55 churn expiries, 0 crowns moved) is frozen as the clean twin" }
else { Bad 'ff-pull lost the 2026-08-02 false-page clean twin - the alert is free to page on ordinary name-churn again' }
if ($r.text -match 'FIRES on starvation') { Ok 'the starvation must-fire is armed (a term that has bought nothing inside the carry window still pages)' }
else { Bad 'ff-pull lost its starvation must-fire - the re-keyed arm can no longer be shown to fire at all, which is how a re-key becomes a mute' }
if ($r.text -match 'FIRES on mass expiry') { Ok 'the mass-expiry safety net is armed (>2% of the catalog in one run pages whatever the class)' }
else { Bad 'ff-pull lost the mass-expiry safety net fixture - a classifier bug could now swallow an unbounded expiry event' }
if ($r.text -match 'must NOT advance the cursor') { Ok 'the cursor-commit must-fire is armed (the 686-row / terms #458..#34 loss cannot silently return)' }
else { Bad 'ff-pull lost the cursor-commit must-fire - a failed merged write is free to advance the cursor past terms it never saved' }
if ($r.text -match 'leaves the prior catalog byte-identical') { Ok 'the atomic-write must-fire is armed (a locked target returns false and cannot corrupt or clobber the last good catalog)' }
else { Bad 'ff-pull lost the atomic-write must-fire - the file-lock class that discarded a whole window is unguarded' }
# The two REAL freeze detectors must survive the re-key VERBATIM. This is the anti-softening pin: the point of
# the 2026-08-02 change was to stop paging on churn, and the cheapest way to "stop paging" would have been to
# blunt these. They are the only arms that catch a genuinely frozen store.
# THE CONSTANT WAS RE-DERIVED ON 2026-09-02 (queue 2026-09-02-a4236e), AND THAT IS NOT THE SAME ACT AS
# SOFTENING IT. 500 was set against the PRE-SHARDING sweep, where a single run re-verified 1,259 rows.
# Under the 3-windows-a-day sharded cadence the designed 48-hour yield is 3 x ~85 x 2 = 510, so 500 sat at
# 70-100% of the steady state and ANY thin window read as a frozen store: it paged at 07:00 on 2026-09-02
# over a catalog of 5,305 items with 0 expired and 450 rows re-verified across four windows in 19 hours.
# 300 is 60% of that designed floor. The arm is not blunted - it is pointed at the cadence that exists.
# WHAT KEEPS THIS HONEST is the pair of fixtures pinned just below: m4 (163 re-verified, this morning's
# real page) must still FIRE, and c6 (450, the same day's healthy state) must stay silent. A future nudge
# downward breaks m4; a nudge upward breaks c6. Change the number only by re-deriving it from the window
# count in capture-policy, and move both fixtures with it.
# RE-KEYED FROM ROWS TO TERMS ON 2026-09-05 (queue 2026-09-05-12bd4a), AND THE DETECTOR DID NOT GO AWAY.
# The paragraph above is kept because it is the record of why a rows floor could not be made to work: it was
# re-derived twice, from 500 to 300, and it still paged at 07:01 on 239 rows and read healthy at 08:01 on 310,
# same store, same cursor, one hour apart. Rows per window depend on which seven terms the cursor is sitting
# on (measured 5, 63, 126, 68, 94, 73 across six windows), so no rows constant can be right for both a
# produce slice and a niche one. The arm now counts the number the policy actually SETS - terms bought per
# landed window, from capture-cursor-log.jsonl - against 2 x RotationTerms, which is "fewer than two landed
# windows in two days" and has no constant to nudge.
# WHAT THIS CHECK NOW PROTECTS: (a) a freeze detector still EXISTS, (b) its threshold is DERIVED from the
# capture plan rather than typed, and (c) a rows constant has not crept back in beside it.
if ($ffpS -match '\$termsBought48h -lt \(2 \* \$rotationTerms\)') { Ok 'the freeze detector is present and its floor is derived from the capture plan (2 x RotationTerms), not typed' }
elseif ($ffpS -match '\$termsBought48h -lt \d+') { Bad ('the terms-bought arm has been pinned to a typed constant: ' + ([regex]::Match($ffpS, '\$termsBought48h -lt \d+').Value) + ' - it must be derived from (Get-CapturePlan).RotationTerms so a cadence change cannot leave it stale, which is exactly how the rows floor rotted twice') }
else { Bad 'the terms-bought arm has been REMOVED - that is the detector for a sweep that has stopped buying terms entirely, and it must not be dropped to quieten an alert' }
if ($ffpS -match '\$recentVerified -lt \d+') { Bad 'a ROWS floor is back in Test-FfCatalogDegraded - rows per window vary 0..25 with the slice, so a rows threshold pages on every niche stretch of the 602-term list; the arm is keyed on terms bought per landed window and recentVerified is information only' }
else { Ok 'no rows floor has crept back in beside the terms arm (recentVerified stays information, not a threshold)' }
if ($r.text -match "a healthy SHARDED day does NOT page") { Ok 'the sharded-era clean twin c6 (5305 items, 450 re-verified) is armed - the floor cannot drift back above a normal day unnoticed' }
else { Bad 'ff-pull lost the c6 sharded clean twin - the 1,259-row pre-sharding twin cannot catch a threshold set above what a sharded day can reach, which is the bug that paged on 2026-09-02' }
# m4 (163 rows must page) was RETIRED on 2026-09-05, not lost: that assertion was the defect. Given six
# landed windows, 163 rows is a niche slice of a healthy store, and it is now the c9 clean twin. The freeze
# detection m4 provided moved to m8 (zero terms bought in 48h) and m9 (one landed window, 7 against a floor
# of 14), and c7 pins the founding false positive silent. All four are asserted so no one of them can be
# dropped to quieten the arm.
if ($r.text -match 'FIRES when ZERO terms were bought in 48h') { Ok 'the m8 must-fire (a frozen store buys 0 terms) is armed' }
else { Bad 'ff-pull lost the m8 must-fire - nothing now proves a completely frozen Family Fare still pages' }
if ($r.text -match 'FIRES on one landed window in 48h') { Ok 'the m9 must-fire (one landed window, 7 terms against a floor of 14) is armed' }
else { Bad 'ff-pull lost the m9 must-fire - nothing now proves a store landing once in two days still pages' }
if ($r.text -match 'the 07:01 false page stays SILENT') { Ok "the c7 clean twin (today's 239-row false page, six landed windows) is armed - a rows floor cannot come back unnoticed" }
else { Bad 'ff-pull lost the c7 clean twin - the 2026-09-05 07:01 false page is what retired the rows floor, and without it the floor can be reintroduced silently' }
if ($r.text -match 'an UNMEASURABLE cursor log') { Ok 'the c8 clean twin is armed - an unreadable cursor log stays silent instead of paging about an absent log' }
else { Bad 'ff-pull lost the c8 clean twin - a missing cursor log would page every night about the store it could not see' }
if ($ffpS -match '\$mergedCount -lt \(\$prevMax \* 0\.80\)') { Ok 'the 20%-shrink freeze detector survives verbatim' }
else { Bad 'the 20%-shrink arm has been changed or removed - that is the detector for the original Family Fare freeze (1909 vs 3974) and it must not be softened' }
if ($ffpS -match 'Get-PolicyMaxCarryDays') { Ok 'the carry window is taken FROM capture-policy.ps1, so it cannot be widened locally to quieten expiry alerts' }
else { Bad 'pull-regular-familyfare no longer reads Get-PolicyMaxCarryDays - the carry window must come from capture-policy.ps1. Hand-setting it here is how expiry alerts get quietened by simply serving older prices.' }
# SOURCE CHECKS for the parts a fixture cannot reach without a live Freshop response. Same reasoning as the
# ff-carry zero-probe checks above: the behaviour needs a real search response, which must never be faked by
# hitting the live API from a test. What CAN be pinned is that the provenance actually gets written.
$ffpIngestAll  = ([regex]::Matches($ffpS, 'Ingest-Items \$items')).Count
$ffpIngestTerm = ([regex]::Matches($ffpS, 'Ingest-Items \$items \$term')).Count
if ($ffpS -match 'function Ingest-Items\(\$items, \$term\)' -and $ffpIngestAll -gt 0 -and $ffpIngestAll -eq $ffpIngestTerm) { Ok ("Ingest-Items takes the search term that produced the response, and all $ffpIngestAll call site(s) pass it (row provenance is captured at ingest)") }
else { Bad ("Ingest-Items no longer receives its search term at every call site ($ffpIngestTerm of $ffpIngestAll) - those rows lose found_by_term, and their future expiries fall back to the unclassifiable 'unknown' class that never pages") }
if ($ffpS -match "\`$row\['found_by_term'\] = \[string\]\`$term") { Ok 'fresh rows are stamped with found_by_term' }
else { Bad 'fresh rows are no longer stamped with found_by_term - the expiry classifier has nothing to classify' }
if ($ffpS -match "'product_id', 'found_by_term'") { Ok 'Norm-Row preserves found_by_term on carried rows (the normalizer-drops-the-contract-field class)' }
else { Bad 'Norm-Row no longer preserves found_by_term - carried rows forget which term found them one line after ingest wrote it, exactly like the guard-10 current_price drop' }
if ($ffpS -match 'Attempts = 5' -and $ffpS -match 'BackoffSec = 2') { Ok 'the atomic write keeps its production retry budget (5 attempts / 2s backoff)' }
else { Bad 'Write-FfJsonAtomic no longer defaults to 5 attempts / 2s - the fixture passes 0 backoff for speed, so the live retry budget is only pinned here' }
if ($ffpS -match '\$commitIdx = Get-FfCursorCommit \$nextIdx \$mergedOk') { Ok 'the cursor write is gated on the merged catalog having landed' }
else { Bad 'the cursor write is no longer behind Get-FfCursorCommit - a failed merged write can advance the cursor again, which is exactly how 686 rows were discarded on 2026-08-02' }
} # u095-u3-ff-pull-the-alert-that-could

# ---------------------------------------------------------------- (v) everyday-mismatch: the orphan, now wired
# 2026-07-31. audit-everyday-mismatch.ps1 is the only check that asks whether the number we PUBLISHED agrees
# with the product page we LINKED to. It worked, it found real defects, and NOTHING invoked it - not
# guards.ps1, not check-ad-cycles.ps1. It also printed a confident "EVERYDAY MISMATCHES: 0" after checking
# ZERO cells, and it had no param() block at all, which is why it had never had a fixture: there was no way
# to feed it anything but the live board.
# The three fixtures below are FROZEN and SYNTHETIC (invented product names and prices, never regenerated
# from a board) and they run from a COPY in TEMP, because the audit writes everyday-mismatches.json and a
# coverage row into its -OutDir and a fixture that mutates itself is not frozen.
if (Use-Unit 'u096-v-everyday-mismatch-the-orphan-now') {
$emFxSrc = Join-Path $root 'regression-inputs\guard-fixtures'
$emTmp = Register-Fx (Join-Path $env:TEMP ('emfx-' + [guid]::NewGuid().ToString('N').Substring(0, 8)))
$null = New-Item -ItemType Directory -Path $emTmp -Force
} # u096-v-everyday-mismatch-the-orphan-now
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
if (Use-Unit 'u096-v-everyday-mismatch-the-orphan-now') {
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
} # u096-v-everyday-mismatch-the-orphan-now

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
if (Use-Unit 'u097-v2-the-hy-vee-pull-s-own-numbers') {
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
$cacTx = (Expand-SelfTestPointers -Text ((Expand-SelfTestPointers -Text ([IO.File]::ReadAllText((Join-Path $root 'check-ad-cycles.ps1'))) -Path (Join-Path $root 'check-ad-cycles.ps1'))) -Path (Join-Path $root 'check-ad-cycles.ps1'))
if ($cacTx -match 'audit-store-taxonomy\.ps1') { Ok 'the daily job still runs the store-taxonomy second opinion' }
else { Bad 'check-ad-cycles no longer calls audit-store-taxonomy - the only check that does not inherit the include regex is dark, and the script census will call it an orphan' }
} # u097-v2-the-hy-vee-pull-s-own-numbers

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
# ---- audit-instore-channel: CHANNEL DOUBT on a published cell (2026-09-01, queue 2026-09-01-b7da16) ---
# The in-store gate PASSES a row whose fulfillment field is absent, which is correct for pre-field captures
# and blind to two shapes. Both are frozen below, both from real rows, and the clean twin is the case that
# stops this audit from re-condemning the entire Walmart column.
#
# The must-fire fixture also pins the ATTRIBUTION rule, which is where the first draft of this audit was
# wrong. All five Walmart captures carry "Thai Kitchen Red Curry Paste, 35.0 oz Cup" under item 754814279;
# the NEWEST is the 08-31 row at $19.32 FC, which the gate already refuses and which is NOT on the board.
# The board publishes the carried $23.40. An audit that attributes a cell to the newest row of that name
# reads the row the engine REJECTED and reports nothing, so the fixture prices fx-curry at $23.40 on
# purpose: if anyone re-simplifies the attribution back to newest-wins, this case goes red.
if (Use-Unit 'u098-audit-instore-channel-channel-doubt') {
$icFxSrc = Join-Path $root 'regression-inputs\guard-fixtures'
$icTmp = Register-Fx (Join-Path $env:TEMP ('icfx-' + [guid]::NewGuid().ToString('N').Substring(0, 8)))
$null = New-Item -ItemType Directory -Path $icTmp -Force
} # u098-audit-instore-channel-channel-doubt
function IcFixture([string]$name) {
  $d = Join-Path $icTmp $name
  Copy-Item (Join-Path $icFxSrc $name) $d -Recurse -Force
  $r = RunPS 'audit-instore-channel.ps1' @('-OutDir', $d)
  $wl = Join-Path $d 'research-worklist.json'
  $wlText = ''
  if (Test-Path $wl) { $wlText = [IO.File]::ReadAllText($wl, [Text.Encoding]::UTF8) }
  return @{ rc = $r.rc; text = $r.text; worklist = $wlText }
}
if (Use-Unit 'u098-audit-instore-channel-channel-doubt') {
$icA = IcFixture 'instore-channel-mustfire'
if ($icA.text -match 'PRE-FIELD-ROW-OUTLIVING-A-REFUSAL' -or $icA.text -match 'prices from the PRE-FIELD row') {
  Ok 'instore-channel FIRES on a pre-field row still pricing the board while the same item id is refused as FC in a fresher capture (the red-curry founding pair)'
} else { Bad ('instore-channel lost its PRE-FIELD founding case - a ship-only product can price the board through a carried row again. rc=' + $icA.rc) }
if ($icA.text -match 'EMPTY fulfillment while that capture populates the field') {
  Ok 'instore-channel FIRES on a blank fulfillment inside a field-bearing capture (the Nalley "(4 pack)" bundle that held the beef-stew crown)'
} else { Bad 'instore-channel no longer separates a BLANK field inside a field-bearing capture from a pre-field absence - the online-bundle class is invisible again' }
if ($icA.text -notmatch 'fx-clean') {
  Ok 'instore-channel CLEAN TWIN: a STORE-fulfilled row in the same capture is not doubted, so the audit is not just flagging every Walmart cell'
} else { Bad 'instore-channel doubted a row that records STORE fulfillment - the finding set is not selective and will be ignored' }
if ($icA.rc -eq 0) { Ok 'instore-channel stays ADVISORY (exit 0) with findings: the answer lives at the store, so it queues a shelf-badge check rather than holding the publish' }
else { Bad ('instore-channel exited ' + $icA.rc + ' with findings - it must not block the chain on a question it cannot answer itself') }
# research-worklist.json had no reader (2026-09-25, queue 2026-09-19-c9f0f3): the doubt must reach the OUTPUT that
# check-ad-cycles logs, and the unread file must not come back.
if ($icA.text -match 'UNREACHED' -and -not $icA.worklist) {
  Ok 'instore-channel prints each unreached doubt in its output and writes no research-worklist.json (a queue with no reader)'
} else { Bad ('instore-channel either lost its UNREACHED line or writes research-worklist.json again, which nothing reads. worklist bytes=' + $icA.worklist.Length) }
$icB = IcFixture 'instore-channel-clean'
if ($icB.text -match 'every published cell traces to a row that either records an in-store channel or predates the field with no fresher refusal' -and $icB.rc -eq 0) {
  Ok 'instore-channel CLEAN TWIN: a wholly pre-field capture with no fresher channel evidence stays SILENT (absence is not a verdict)'
} else { Bad ('instore-channel doubts a carried row with NO fresher evidence against it - that condemns every pre-field capture and empties the Walmart column. rc=' + $icB.rc) }

$rwFxSrc = Join-Path $root 'regression-inputs\guard-fixtures'
$rwTmp = Register-Fx (Join-Path $env:TEMP ('rwfx-' + [guid]::NewGuid().ToString('N').Substring(0, 8)))
$null = New-Item -ItemType Directory -Path $rwTmp -Force
} # u098-audit-instore-channel-channel-doubt
function RwFixture([string]$name) {
  $d = Join-Path $rwTmp $name
  Copy-Item (Join-Path $rwFxSrc $name) $d -Recurse -Force
  # -WindowDays IS PINNED, and pinning it is the point. These fixtures are frozen at January 2000 dates
  # chosen so fx-milk sits 9 days back with 5 of 14 window days left. On 2026-08-20 the everyday-price
  # window moved to the capture policy's 90-day quarter, and a 9-day-old capture stopped being anywhere
  # near expiry - the assertion below went red while the arithmetic it tests was perfectly correct. The
  # fixture tests the COUNTDOWN, not the constant; the constant is asserted separately just below.
  $r = RunPS 'build-rescue-worklist.ps1' @('-AsOf', '2000-01-10', '-OutDir', $d, '-WindowDays', '14')
  $listF = Join-Path $d 'rescue-terms-fixturemart.txt'
  $list = if (Test-Path $listF) { [IO.File]::ReadAllText($listF, [Text.Encoding]::UTF8) } else { '' }
  return @{ rc = $r.rc; text = $r.text; list = $list; hasList = (Test-Path $listF) }
}
# MUST FIRE, one cell per section so a single assertion cannot pass by accident: fx-eggs is priced on the
# older board and gone today (the Aldi class), fx-toast is on the board with no capture on disk carrying it
# (unknown provenance = capture it), fx-milk traces to a 9-day-old capture with 5 of 14 window days left
# (the Walmart silent countdown).
if (Use-Unit 'u098-audit-instore-channel-channel-doubt') {
$rwA = RwFixture 'rescue-mustfire'
if ($rwA.rc -eq 1 -and $rwA.list -match '(?m)^fixture eggs\t+fx-eggs\tDROPPED') { Ok 'rescue-worklist FIRES on a cell that was priced a week ago and is gone today (the Aldi 7-staple drop class)' }
else { Bad ('rescue-worklist missed its DROPPED founding case: rc=' + $rwA.rc + ' - a board cell lost to a narrower re-capture produces no re-search term again') }
if ($rwA.list -match '(?m)^fixture toast\t+fx-toast\tUNTRACEABLE') { Ok 'rescue-worklist flags a cell no capture on disk still carries (unknown provenance = capture it)' }
else { Bad 'rescue-worklist no longer flags an UNTRACEABLE cell - a price we cannot attribute to any file is being reported as healthy' }
if ($rwA.list -match '(?m)^fixture jam\t+fx-jam\tEXPIRING\t5d left') { Ok 'rescue-worklist CLEAN TWIN: a marked-down row traces by its REGULAR price, the price the board shows for an everyday cell' }
else { Bad 'rescue-worklist no longer traces a marked-down row by its regular price - every Fareway markdown reads UNTRACEABLE again (114 of 223 cells on 2026-09-27)' }
if ($rwA.list -match '(?m)^fixture milk\t+fx-milk\tEXPIRING\t5d left') { Ok 'rescue-worklist counts an expiring cell down to the exact day its only source leaves the union window' }
else { Bad 'rescue-worklist lost the EXPIRING section or its days-left arithmetic - the 21-cell Walmart silent countdown is invisible again' }
if ($rwA.hasList -and $rwA.list -match 'DEEP CAPTURE REQUIRED') { Ok 'the emitted worklist carries the DEEP CAPTURE warning (a narrow re-capture WINS the commodity with thinner data)' }
else { Bad 'the emitted worklist lost the DEEP CAPTURE header - a shallow rescue pass makes the board WORSE, and nothing on the list now says so' }
# ...and because the fixture now pins the window, NOTHING else would notice the real default drifting away
# from the engine's. build-rescue-worklist.ps1 says its -WindowDays 'MUST match compare-deals' union
# window'; that was a comment, which is not a test. A rescue list computed over a different window than the
# engine prices from counts down to the wrong day, which is the silent-countdown bug wearing a new hat.
$rwSrc = [IO.File]::ReadAllText((Join-Path $root 'build-rescue-worklist.ps1'))
$rwDefault = ([regex]::Match($rwSrc, '\[int\]\$WindowDays\s*=\s*(\d+)')).Groups[1].Value
} # u098-audit-instore-channel-channel-doubt
. (Join-Path $root 'regular-fileset-lib.ps1')
if (Use-Unit 'u098-audit-instore-channel-channel-doubt') {
if ($rwDefault -and [int]$rwDefault -eq (Get-RegularUnionDays)) { Ok "build-rescue-worklist's window default still equals the engine's union window ($rwDefault d)" }
else { Bad "build-rescue-worklist -WindowDays default is '$rwDefault' but the engine unions over $(Get-RegularUnionDays) - the rescue list would count down to the wrong day" }
} # u098-audit-instore-channel-channel-doubt

# ---- EVERY CONSUMER OF THE EVERYDAY-PRICE WINDOW AGREES WITH THE POLICY -------------------------------
# 2026-08-20: capture-policy.ps1 moved everyday prices to a 90-day quarter, and SEVEN files still held a
# private 14. They did not fail loudly - they failed plausibly. audit-walmart-fullpull warned that 468 of
# 468 Walmart cells (100%) were about to expire, for cells with eighty days left; audit-coverage-gaps
# manufactured exactly the false gaps its own comment says it exists to prevent; derive-links-from-prices
# quietly stopped deriving links for Sam's cells the board was actively pricing.
#
# A comment saying "MUST match compare-deals' union window" is not a test. This is the test. It asserts
# each consumer either ASKS (Get-RegularUnionDays / 0 = ask) or states the same number the policy does, so
# the next person to move the quarter cannot leave a consumer behind - and a NEW consumer that hardcodes a
# window will not be covered here, which is why the -ListOnly sweep below names what it checked.
. (Join-Path $root 'regular-fileset-lib.ps1')
if (Use-Unit 'u099-every-consumer-of-the-everyday-price') {
$winPolicy = Get-PolicyCarryDaysFromText
$winUnion  = Get-RegularUnionDays
if ($null -ne $winPolicy -and $winUnion -eq $winPolicy) { Ok "the union window equals capture-policy MaxCarryDays ($winUnion d)" }
else { Bad "union window is $winUnion but capture-policy says $winPolicy - everyday rows expire before the rotation re-captures them" }

# name -> the regex that must find EITHER a shared-source call OR the policy number
$WIN_CONSUMERS = @(
  @{ f = 'compare-deals.ps1';           pat = '\[int\]\$SamsMaxAgeDays\s*=\s*(\d+)';     what = "Sam's union window" },
  @{ f = 'compare-deals.ps1';           pat = '\[int\]\$WalmartMaxAgeDays\s*=\s*(\d+)';  what = 'Walmart union window' },
  @{ f = 'carry-forward-regular.ps1';   pat = '\[int\]\$MaxCarryDays\s*=\s*(\d+)';       what = 'the carry cap every out\regular store inherits' },
  @{ f = 'build-fareway-regular.ps1';   pat = '\[int\]\$MaxExtractDays\s*=\s*(\d+)';     what = "Fareway's extract merge window" },
  @{ f = 'build-rescue-worklist.ps1';   pat = '\[int\]\$WindowDays\s*=\s*(\d+)';         what = 'the rescue countdown window' },
  @{ f = 'audit-walmart-fullpull.ps1';  pat = '\[int\]\$WindowDays\s*=\s*(\d+)';         what = 'the fullpull expiry watch' },
  @{ f = 'repair-asof-evidence.ps1';    pat = '\[int\]\$MaxAgeDays\s*=\s*(\d+)';         what = 'the as_of repair window' }
)
foreach ($c in $WIN_CONSUMERS) {
  $src = [IO.File]::ReadAllText((Join-Path $root $c.f))
  $m = [regex]::Match($src, $c.pat)
  if (-not $m.Success) { Bad ("window consumer " + $c.f + " no longer declares " + $c.what + " - this check went blind on it, which is not the same as it being correct"); continue }
  $v = [int]$m.Groups[1].Value
  # 0 is the ASK sentinel: the file resolves the window from regular-fileset-lib at run time.
  if ($v -eq 0) {
    if ($src -match 'Get-RegularUnionDays') { Ok ($c.f + ' asks regular-fileset-lib for ' + $c.what) }
    else { Bad ($c.f + ' defaults ' + $c.what + ' to 0 but never calls Get-RegularUnionDays - it will run on a zero-day window') }
  }
  elseif ($v -eq $winUnion) { Ok ($c.f + ' states ' + $c.what + " as $v d, matching the policy") }
  else { Bad ($c.f + ' holds a PRIVATE window of ' + $v + ' d for ' + $c.what + " - the engine prices over $winUnion d, so this one counts down to the wrong day") }
}
# The two that must not restate the number at all - they compute a floor/filter inline.
foreach ($c in @(
  @{ f = 'audit-coverage-gaps.ps1';        what = 'its fresh-file floor' },
  @{ f = 'derive-links-from-prices.ps1';   what = "Sam's link-source window" })) {
  $src = [IO.File]::ReadAllText((Join-Path $root $c.f))
  if ($src -match 'Get-RegularUnionDays') { Ok ($c.f + ' derives ' + $c.what + ' from the shared union window') }
  else { Bad ($c.f + ' no longer asks Get-RegularUnionDays for ' + $c.what + ' - it is back to a private copy of the window') }
}
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
$rwReg = Read-JsonFile (Join-Path $root 'stores.json')
$rwWalled = @(@($rwReg.stores) | Where-Object { $_.PSObject.Properties['walled'] -and $_.walled })
if ($rwWalled.Count -eq 4) { Ok 'stores.json still marks exactly 4 walled stores - the set build-rescue-worklist builds lists for' }
else { Bad ('stores.json marks ' + $rwWalled.Count + ' walled store(s), not 4 - a dropped flag silently removes that store from every rescue list, and the tool exits 3 only when ALL of them are gone') }
# guards.ps1 delegates cell-drops as a NATIVE child under EAP=Stop, where a redirected stderr line throws.
# It had 2>$null until 2026-07-31: inside its own try/catch, so not a dead guard, but any run where the
# child wrote to stderr was reported as "could not run" instead of its real finding.
if ($gSrc -match "audit-cell-drops\.ps1'\)\s*2>") { Bad 'guards.ps1 redirects the cell-drops child stderr again - under EAP=Stop the first stderr line throws, and a real cell leak is reported as plumbing failure' }
else { Ok 'guards.ps1 delegates cell-drops without a stderr redirect (a real finding reaches the warn line, not the catch)' }
} # u099-every-consumer-of-the-everyday-price

# ---------------------------------------------------------------- 23b. store SEARCH templates resolve
# FOUNDING BUG (2026-08-02): the Family Fare "Find at store" template was
# https://www.shopfamilyfare.com/search?search_term={q}, which returns "Page not found - Family Fare". It
# was live on 20 chips in public/board.json and no guard in the estate could see it: the all-3 rule counts
# that a chip HAS an href, and audit-links/audit-everyday-mismatch only ever look at PRODUCT urls. A link
# that exists but does not resolve was an unguarded class.
# The fixtures are frozen CANNED RESPONSES (url -> {status,title}) captured from the real stores that day,
# so this replays over the network without touching it. -ReportDir keeps a fixture run from overwriting the
# live report (the audit-basis-reconcile lesson).
if (Use-Unit 'u100-23b-store-search-templates-resolve') {
$slFx  = Join-Path $fix 'searchlinks-mustfire'
$slCl  = Join-Path $fix 'searchlinks-clean'
$slBl  = Join-Path $fix 'searchlinks-blind'
$slRep = NewFxDir 'searchlinks-rep'
} # u100-23b-store-search-templates-resolve
function SlRun($tplDir, $respFile, $baseFile) {
  $a = @('-ResponsesFile', $respFile, '-ReportDir', $slRep)
  if ($tplDir)   { $a = @('-TemplatesFile', (Join-Path $tplDir 'templates.json')) + $a }
  if ($baseFile) { $a += @('-BaselineFile', $baseFile) }
  return (RunPS 'audit-search-links.ps1' $a)
}
if (Use-Unit 'u100-23b-store-search-templates-resolve') {
$sl = SlRun $slFx (Join-Path $slFx 'responses.json')
if ($sl.rc -eq 2 -and $sl.text -match 'Family Fare search template does not resolve' -and $sl.text -match '404') { Ok 'search-links FIRES on the dead Family Fare search template (its founding bug)' }
else { Bad ('search-links MISSED its founding bug - a 404ing store search link ships unnoticed again: rc=' + $sl.rc + ' ' + $sl.text) }
# CLEAN TWIN: the same map with Family Fare corrected. Silence here proves the guard is discriminating and
# not just always-red. It also proves the FRAGMENT is stripped: the corrected url is a hash-bang route, and
# a probe that fetched it whole would judge a url the server never sees.
$sl = SlRun $slCl (Join-Path $slCl 'responses.json')
if ($sl.rc -eq 0 -and $sl.text -match 'search-links: OK' -and $sl.text -notmatch 'does not resolve') { Ok 'search-links SILENT once the template is corrected (and strips the hash-bang before judging it)' }
else { Bad ('search-links false-positived on the corrected templates: rc=' + $sl.rc + ' ' + $sl.text) }
# BLIND: every store behind a bot wall must NOT read as a clean sweep. This is the gates-that-can-never-arm
# shape - the danger with a network probe is that a blocked run looks exactly like a healthy one.
$sl = SlRun $slCl (Join-Path $slBl 'responses.json')
if ($sl.rc -eq 3 -and $sl.text -match 'COULD NOT EVALUATE') { Ok 'search-links exits 3 when every store is bot-walled, instead of reporting all templates healthy' }
else { Bad ('search-links reported a result with every store blocked: rc=' + $sl.rc + ' - a blocked probe is being read as proof') }
# THE EXTRACTION PATH ITSELF. Every case above passes templates in by file, so none of them exercises the
# live $SEARCHURLS extraction from build-deals-page.ps1 - and that path shipped broken on the first cut
# (Invoke-Expression on an assignment returns nothing, so a healthy file read as "could not extract" and the
# whole guard fell into its own fail-closed branch). A fix needs a self-test that can REACH the new code.
$sl = SlRun $null (Join-Path $slCl 'responses.json')
if ($sl.text -notmatch 'could not be extracted') { Ok 'search-links can still extract $SEARCHURLS from the live build-deals-page.ps1 (the guard is not stuck in its own fail-closed branch)' }
else { Bad 'search-links can no longer parse $SEARCHURLS out of build-deals-page.ps1 - it exits 3 every run and probes nothing, which reads as "could not evaluate" forever' }
# THE ECHO DOWNGRADE, the rot a 404 check cannot see: a store renames its query parameter and serves a
# healthy 200 that ignores what the shopper searched for. Walmart echoed the query in its title at baseline
# and does not in this fixture. It must be reported as a DOWNGRADE and must NOT be called BROKEN.
$sl = SlRun $slCl (Join-Path $fix 'searchlinks-paramrot\responses.json') (Join-Path $slCl 'baseline.json')
if ($sl.text -match 'DOWNGRADE' -and $sl.text -match 'Walmart stopped echoing') { Ok 'search-links reports a store that quietly stopped reading our query (200-but-ignored, invisible to any status check)' }
else { Bad ('search-links no longer notices a store ignoring the query parameter - a silently-rotted template reads as healthy: ' + $sl.text) }
if ($sl.rc -eq 0) { Ok 'the echo downgrade stays ADVISORY (exit 0) - a title change is not proof of a dead link' }
else { Bad ('search-links now hard-fails on a title change (rc=' + $sl.rc + ') - that pages Brad over marketing copy, which is how a guard gets ignored') }
# THE REPORT MUST ACTUALLY EXIST. It shipped broken: 'k = @($list)' inside an [ordered] literal throws
# "Argument types do not match" in PS 5.1, the write was wrapped in a bare catch, and every run printed a
# healthy summary while writing no file - with the alert email pointing at that missing file. Asserting the
# summary text alone would never have caught it; only reading the artifact does.
$slRepF = Join-Path $slRep 'search-links-report.json'
if (Test-Path $slRepF) {
  $slJson = $null
  try { $slJson = Read-JsonFile $slRepF } catch {}
  if ($slJson -and @($slJson.rows).Count -ge 7 -and $slJson.query) { Ok 'search-links writes a report that parses and carries a row per store (the file its alert tells Brad to open)' }
  else { Bad 'search-links wrote a report that does not parse or has no per-store rows - the alert points at an unreadable file' }
} else { Bad 'search-links wrote NO report file - its alert body names a path that does not exist, and every run still prints a healthy-looking summary' }
try { Remove-Item -LiteralPath $slRep -Recurse -Force -ErrorAction SilentlyContinue } catch {}
# THE DEAD URL ITSELF, pinned at the source. Cheapest possible regression test for the exact string.
$bdpSrc = Get-Content (Join-Path $root 'build-deals-page.ps1') -Raw
if ($bdpSrc -notmatch 'shopfamilyfare\.com/search\?search_term=') { Ok 'build-deals-page no longer carries the dead Family Fare /search?search_term= template' }
else { Bad 'the dead Family Fare search template is back in build-deals-page.ps1 $SEARCHURLS - every unlinked FF chip 404s again' }
# ORPHAN CHECK: a probe nothing calls is a probe nobody reads (the audit-everyday-mismatch lesson).
if ($cacSrc -match 'audit-search-links\.ps1') { Ok 'check-ad-cycles still invokes audit-search-links (an uncalled probe never checks a template)' }
else { Bad 'audit-search-links is an ORPHAN - nothing invokes it, so a store can re-route its storefront and the fallback links die silently again' }
} # u100-23b-store-search-templates-resolve

# ---------------------------------------------------------------- 24. known-wrong blocklist (Component 2)
# MUST FIRE: an adjudicated-wrong product is priced on the board again. FOUNDING BUG - audit findings lived
# as PROSE in .md files, so honeydew was written up on 2026-07-29 with the store's own arithmetic and was
# still the published crown the next morning, and Blue Buffalo cat food held the salmon crown at 20.8% under
# the runner-up with every guard green. Fixtures are SYNTHETIC and frozen here: the product names are the
# bug, so they must never be re-read from the live board.
if (Use-Unit 'u101-24-known-wrong-blocklist-component-2') {
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
# THE LINK CHECK SKIPS A REVERSED RULING TOO (2026-09-22, plan-2026-09-22-5). The board-cell check above already did; the
# curated-link index did not, so the first reversal of a ruling that had a curated link held the whole board
# (BLOCKED-LINK Baker's laundry-detergent on the ceab00 reversals). Same clean-twin tree and ledger.
$kwPurl = Join-Path $fxKw 'product-urls.json'
Set-Content $kwPurl '{"items":{"parmesan":{"commodity":"parmesan","Aldi":{"url":"https://www.aldi.us/product/x","name":"Clancy''s Parmesan Garlic Pita Chips 7.33 OZ"}},"coffee":{"commodity":"coffee","Walmart":{"url":"https://www.walmart.com/ip/1","name":"Onyx Coffee Lab Salted Mocha Oat Milk Latte, 11 fl oz Can"}}}}' -Encoding UTF8
$r = RunPS 'audit-known-wrong.ps1' @('-Root', $fxKw, '-ListFile', $kwList)
if ($r.rc -eq 2 -and $r.text -match 'BLOCKED-LINK\s+\[Aldi\] parmesan') { Ok 'MUST FIRE  a curated link to a product under an ACTIVE ruling (parmesan / Aldi pita chips) is still a BLOCKED-LINK' }
else { Bad ('known-wrong link check no longer fires on an active ruling (rc=' + $r.rc + '): ' + $r.text) }
if ($r.text -notmatch 'BLOCKED-LINK\s+\[Walmart\] coffee') { Ok 'MUST NOT FIRE  a curated link to a product whose ruling was REVERSED (the coffee latte) is not a BLOCKED-LINK' }
else { Bad 'known-wrong link check still enforces a REVERSED ruling - one reversal holds the whole board' }
[IO.File]::Delete($kwPurl)# BLIND: no board at all. Must be exit 3, never a clean 0.
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
if (-not $HasBoard) { Skip 'known-wrong live clean twin: NO live board in grocery\out - the regression blocklist was not evaluated here' }
else {
  # The Bad line is marked for ops\prepush-test-auditors.ps1's expected-live-red pairing, as the food-category twin is.
  $r = RunPS 'audit-known-wrong.ps1' @()
  if ($r.rc -eq 0 -and $r.text -match 'KNOWN-WRONG AUDIT OK') { Ok 'known-wrong live clean twin: the real blocklist is green on the real board' }
  else { Bad ('known-wrong is RED on the live board (rc=' + $r.rc + ') - an adjudicated-wrong product is published again: ' + $r.text) }  # live-board-ruling-case audit=audit-known-wrong.ps1
}
} # u101-24-known-wrong-blocklist-component-2
# ---- UNFIRABLE vs KEY-COLLISION: two shapes of the SAME 48-char key, needing OPPOSITE actions ---------
# The key is the product name slugged and truncated to 48 chars, so two names that agree for 48 characters
# produce ONE key and TWO different match targets. That fact has two completely different causes and until
# 2026-09-01 this audit reported both as the first one.
#
#   UNFIRABLE (founding case, Soeos bay leaves, 2026-08-29): the SAME product under two spellings. Walmart
#   rewrote a 70-char title into a 168-char SEO title; the two slugs still agree for 55 characters, past the
#   47-char key. The ruling really is inert and Soeos really did hold the Walmart crown at 17x cheap through
#   a rebuild that was supposed to have dropped it. Re-issue it. This case had NO fixture until now.
#
#   KEY-COLLISION (found 2026-09-01 on the live board): TWO DIFFERENT PRODUCTS the truncation merged. The
#   ruling names "...Long Grain WHITE Rice Pouch, 8.8 oz" - plain white rice, correctly ruled wrong for a
#   long-grain-AND-WILD commodity - and the board carries "...Long Grain & WILD Rice Pouch, 8.8 oz", which is
#   the RIGHT product and matches the commodity's own include. The slugs agree for exactly 48 characters and
#   diverge at 49, so the cut is the only thing that merged them. Acting on the UNFIRABLE advice here - "let
#   add-known-wrong read the name off the board" - would rule the correct product wrong and delete a good
#   cell. Understating is as wrong as overstating.
#
# Both rows are FROZEN from the real ones and are never re-read from the live board: the collision IS the bug.
if (Use-Unit 'u102-unfirable-vs-key-collision-two') {
$fxKwU = NewFxDir 'kw-unfirable'
New-Item -ItemType Directory -Force (Join-Path $fxKwU 'out') | Out-Null
Set-Content (Join-Path $fxKwU 'commodities.json') '[{"id":"bay-leaves","label":"Bay Leaves","unit":"oz"},{"id":"ready-to-serve-long-grain-wild-rice-pouch","label":"RTS Long Grain & Wild Rice Pouch","unit":"oz"}]' -Encoding UTF8
Set-Content (Join-Path $fxKwU 'stores.json') '{"stores":[{"name":"Walmart","order":1,"regular_prefix":"walmart"}]}' -Encoding UTF8
Set-Content (Join-Path $fxKwU 'known-wrong.json') @'
{
  "schema": 1,
  "entries": [
    { "key": "bay-leaves|Walmart|soeos-bay-leaves-16-oz-454g-bay-leaves-bulk-bay", "commodity": "bay-leaves", "store": "Walmart",
      "names": ["Soeos Bay Leaves 16 oz (454g), Bay Leaves Bulk, Bay Leaves Whole Dried"],
      "product_id": "", "verdict": "wrong-product",
      "evidence": "frozen from the 2026-08-29 founding case: one product, two spellings, key collides and name does not",
      "ruled_on": "2026-08-29", "ruled_by": "fixture", "retire_when": "ruling-reversed" },
    { "key": "ready-to-serve-long-grain-wild-rice-pouch|Walmart|great-value-ready-to-heat-90-second-long-grain-w", "commodity": "ready-to-serve-long-grain-wild-rice-pouch", "store": "Walmart",
      "names": ["Great Value Ready-to-Heat 90-Second Long Grain White Rice Pouch, 8.8 oz"],
      "product_id": "", "verdict": "wrong-product",
      "evidence": "frozen from the 2026-09-01 case: WHITE rice ruled wrong, and the board carries the WILD rice blend under a colliding key",
      "ruled_on": "2026-08-30", "ruled_by": "fixture", "retire_when": "ruling-reversed" }
  ]
}
'@ -Encoding UTF8
Set-Content (Join-Path $fxKwU 'out\comparison-2026-01-02.json') @'
{"comparison":[
 {"id":"bay-leaves","unit":"oz","cheapest_store":"Walmart","stores":[
   {"store":"Walmart","per_unit":1.4369,"item":"Soeos Bay Leaves 16 oz (454g), Bay Leaves Bulk, Bay Leaves Dry, Bay Leaf, Laurel Leaves, Natural Laurel Leaf, Natural Dried Bay Leaf, Dried Bay Leaves, Whole Bay Leaves","ad":"$22.99","size":"16 oz"}]},
 {"id":"ready-to-serve-long-grain-wild-rice-pouch","unit":"oz","cheapest_store":"Walmart","stores":[
   {"store":"Walmart","per_unit":0.15,"item":"Great Value Ready-to-Heat 90-Second Long Grain & Wild Rice Pouch, 8.8 oz","ad":"$1.32","size":"8.8 oz"}]}
]}
'@ -Encoding UTF8
$r = RunPS 'audit-known-wrong.ps1' @('-Root', $fxKwU, '-ListFile', (Join-Path $fxKwU 'known-wrong.json'))
if ($r.text -match 'UNFIRABLE\s+bay-leaves\|Walmart\|soeos' -and $r.text -match 'agree for 55 characters') {
  Ok 'known-wrong UNFIRABLE still fires on one product under two spellings (the Soeos founding case, which had no fixture until 2026-09-01)'
} else { Bad ('known-wrong lost the UNFIRABLE founding case - a renamed product can sit on the board with an inert ruling again: ' + $r.text) }
if ($r.text -match 'KEY-COLLISION\s+ready-to-serve-long-grain-wild-rice-pouch' -and $r.text -match 'may well be CORRECT') {
  Ok 'known-wrong separates a KEY-COLLISION between two DIFFERENT products from a genuine UNFIRABLE ruling'
} else { Bad ('known-wrong reported the white-rice/wild-rice key collision as UNFIRABLE - acting on that advice blocks a CORRECT board cell: ' + $r.text) }
if ($r.text -notmatch 'UNFIRABLE\s+ready-to-serve-long-grain-wild-rice-pouch') {
  Ok 'known-wrong does NOT tell a reviewer to re-issue a ruling against a board product that is probably correct'
} else { Bad 'known-wrong still prescribes "read the name off the board" for a collision between two different products - that deletes a good cell' }
if ($r.rc -eq 0) { Ok 'neither UNFIRABLE nor KEY-COLLISION sets the exit code (both are read-and-decide findings, not gate failures)' }
else { Bad ('known-wrong gated the publish on a key-shape finding (rc=' + $r.rc + ')') }
Remove-Item $fxKwU -Recurse -Force -ErrorAction SilentlyContinue

Remove-Item $fxKw, $fxKwB, $fxKwS -Recurse -Force -ErrorAction SilentlyContinue
} # u102-unfirable-vs-key-collision-two

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
if (Use-Unit 'u103-m-the-coverage-ledger') {
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
# THE BUDGETED LANE'S DENOMINATOR (2026-08-22). pull-regular-hyvee asks about ~18 products a day, so
# eligible = every product holding an id read as a ~98% collapse EVERY morning - a permanent finding nobody
# can act on. Its denominator is now the slice the run was ALLOWED to ask about, and examined is what the
# store ANSWERED (a refused answer was still examined). Reverting either silently restores the daily cry-wolf.
$covSrcH = Get-Content (Join-Path $root 'pull-regular-hyvee.ps1') -Raw
if ($covSrcH -match 'Write-CoverageRecord -Check ''pull-regular-hyvee'' -OutDir \$OutDir -Eligible \$askableToday -Examined \$covExamined') {
  Ok 'pull-regular-hyvee records coverage against TODAY''S SLICE (askable today / answered), not the whole catalogue'
} else {
  Bad 'pull-regular-hyvee no longer records eligible=$askableToday examined=$covExamined - a budgeted lane measured against the whole catalogue reports a ~98% collapse every day, and a permanent finding trains people to ignore the ledger'
}
if ($covSrcH -match '\$covExamined = \[int\]\$pass\.Answered') { Ok 'pull-regular-hyvee counts an ANSWERED product as examined, so a refused answer is not miscounted as blindness' }
else { Bad 'pull-regular-hyvee stopped taking its examined count from $pass.Answered - if it went back to $fresh, a day of size/shelf-tag refusals reads as a coverage collapse' }

$fxCov = NewFxDir 'cov-ledger'
New-Item -ItemType Directory -Force (Join-Path $fxCov 'out') | Out-Null
Copy-Item (Join-Path $root 'audit-coverage-ledger.ps1') $fxCov
Copy-Item (Join-Path $root 'coverage-lib.ps1') $fxCov
$covEnc = New-Object Text.UTF8Encoding($false)
# as_of is stamped with TODAY on purpose: STALE is measured against the clock, so a frozen calendar date
# would make every non-stale case fail as soon as the fixture aged. The BUG is in the counts, not the date.
$covNow = (Get-Date -Format 'yyyy-MM-dd') + ' 09:00:00'
} # u103-m-the-coverage-ledger
function CovLedger([hashtable]$rows) {
  $c = [ordered]@{}
  foreach ($k in ($rows.Keys | Sort-Object)) {
    $v = $rows[$k]
    $c[$k] = [ordered]@{ eligible = $v[0]; examined = $v[1]; skipped = ([math]::Max(0, $v[0] - $v[1])); blind = ($v[1] -le 0); as_of = $(if ($v.Count -gt 2) { $v[2] } else { $covNow }); detail = 'frozen fixture' }
  }
  [IO.File]::WriteAllText((Join-Path $fxCov 'out\coverage-ledger.json'), (([ordered]@{ schema = 1; updated = $covNow; checks = $c }) | ConvertTo-Json -Depth 6), $covEnc)
}
# FROZEN baseline: guard 11 at its pre-API row count, guard 3 at the 16 pins it had the day it went blind.
if (Use-Unit 'u103-m-the-coverage-ledger') {
[IO.File]::WriteAllText((Join-Path $fxCov 'coverage-baseline.json'), (@'
{"schema":1,"set":"frozen fixture - do not regenerate","checks":{
 "guards/11-bakers-provenance":{"examined":6960,"tolerance":0.25,"max_age_days":2,"phase":"publish"},
 "guards/3-pin-identity":{"examined":16,"tolerance":0.5,"max_age_days":2,"phase":"publish"},
 "guards/4-factor":{"examined":2435,"tolerance":0.1,"max_age_days":2,"phase":"publish"},
 "pull-regular-hyvee":{"examined":3,"tolerance":1.0,"min_ratio":0.9,"max_age_days":3,"phase":"cycle","why":"BUDGETED LANE - the absolute ratchet is off and min_ratio replaces it. It asks about a rotating slice of ~18 products a day (0-18 of them linkable, median 3), so a fixed baseline count reported a 98% collapse every morning. Judged on the fraction of TODAY'S eligible slice it examined."},
 "audit-ff-carry":{"examined":464,"tolerance":1.0,"max_age_days":3,"phase":"cycle","why":"RATCHET DELIBERATELY OFF - inverse denominator. It counts EMPTY FF search terms re-probed, so it FALLS when the pull improves; a ratchet would fire at whoever fixed the thing it watches. The clean twin below pins exactly that. Recorded here because DEAD-RATCHET now separates a declared exemption from an accidental one, and an undeclared 1.0 is an accident."}}}
'@), $covEnc)
$covHealthy = @{ 'guards/11-bakers-provenance' = @(6960, 6936); 'guards/3-pin-identity' = @(19, 9); 'guards/4-factor' = @(2435, 2435); 'audit-ff-carry' = @(464, 464); 'pull-regular-hyvee' = @(3, 3) }

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
} # u103-m-the-coverage-ledger
