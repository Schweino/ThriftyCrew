
# ---------------------------------------------------------------- (k3c) an OWNER must be a job that EXISTS
# (2026-09-06, queue 2026-09-06-22b4dd). The 09-03 fix above gave ownership an EXPIRY but not PROOF:
# ownership was asserted from a hardcoded store -> string map, so yukon-gold-potatoes|Family Fare was
# silenced for three days as owned by 'daily-ff-selfheal' - a name that appears nowhere in this estate
# except the map, its grace entry, the ledger and the alert body. No script, no scheduled task, no row in
# expected-automations.json. Only the expiry ever escalated it.
# THE OVER-BROAD FIX IS THE REAL HAZARD, so the clean twin below is the load-bearing case: role names are
# NOT task names. 'weekly-browser-agent' is also absent from the registry, and a literal owner-string
# lookup would collapse the two HEALTHY rows to NONE and page them too.
if (Use-Unit 'u063-k3c-an-owner-must-be-a-job-that') {
$fxOwn = Join-Path $env:TEMP ('tafxown-' + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Force (Join-Path $fxOwn 'regular') | Out-Null
# FROZEN registry: the five task names really registered, as of 2026-09-07 (the watchdog row was
# 'TC Grocery Capture Watchdog 0930' until install-grocery-tasks -FixName renamed it that morning; kept in
# step with the live key so this fixture never teaches a reader a name that no longer exists - neither
# spelling changes what these cases assert, because the owner strings are what is on trial). Written here,
# never read from the live file - a fixture that re-reads the registry would go green the day someone
# registers a task called daily-ff-selfheal, which is the one change that must make these cases FAIL.
$ownReg = '{"windows_tasks":[{"name":"TC Grocery Ad Pulls 0700"},{"name":"TC Grocery Daily Capture 0800"},{"name":"TC Grocery Capture Watchdog 1030"},{"name":"TC Graph Nightly Matching"},{"name":"TC Recipe Harvest Crawl"}]}'
$ownRegF = Join-Path $fxOwn 'expected-automations.json'
Set-Content $ownRegF $ownReg -Encoding UTF8
# FROZEN board: today's two real shapes side by side - the Family Fare gap with the phantom owner, and the
# Hy-Vee gap with the real one. Both on sale, neither with an everyday twin in the pool below.
$ownBoard = '{"week_of":"2026-09-06","comparison":[{"commodity":"Yukon Gold Potatoes","id":"yukon-gold-potatoes","unit":"lb","stores":[{"store":"Family Fare","type":"sale","per_unit":0.99,"item":"Yukon Gold Potatoes 5 Lb"}]},{"commodity":"Canned Pumpkin","id":"canned-pumpkin","unit":"oz","stores":[{"store":"Hy-Vee","type":"sale","per_unit":0.12,"item":"Hy-Vee Pumpkin 15 oz"}]}]}'
Set-Content (Join-Path $fxOwn 'comparison-2026-09-06.json') $ownBoard -Encoding UTF8
Set-Content (Join-Path $fxOwn 'regular\family-fare-regular-2026-09-06.json') '{"store":"Family Fare","deals":[{"name":"Our Family Whole Milk, 1 Gallon"}]}' -Encoding UTF8
Set-Content (Join-Path $fxOwn 'regular\hyvee-regular-2026-09-06.json') '{"store":"Hy-Vee","deals":[{"name":"Hy-Vee Whole Milk, 1 Gallon"}]}' -Encoding UTF8
$ownLedger = Join-Path $fxOwn 'sale-fallback-ownership.json'
# MUST-FIRE: the phantom owner escalates on DAY 0. first_seen is the board's own date, so age is 0 - under
# the old rule that is 0 of 3 days' grace and silent. It must be loud anyway, because the owner is fiction.
# SINCE 2026-09-22 (plan-2026-09-22-9, c9f0f3) the owner is the store's own capture plan, proven from the plan and
# from stores.json, and the labels above are gone. The same two frozen rows now carry the plan owners.
'{"yukon-gold-potatoes|Family Fare":{"first_seen":"2026-09-06","owner":"capture-plan:Family Fare"},"canned-pumpkin|Hy-Vee":{"first_seen":"2026-09-02","owner":"capture-plan:Hy-Vee"}}' | Set-Content $ownLedger -Encoding UTF8
$r = RunPS 'audit-sale-fallback.ps1' @('-OutDir', $fxOwn, '-CompareFile', (Join-Path $fxOwn 'comparison-2026-09-06.json'), '-AutomationsFile', $ownRegF)
$ofg = try { Read-JsonFile (Join-Path $fxOwn 'sale-fallback-gaps.json') } catch { $null }
$ffRow = @($ofg.gaps | Where-Object { $_.commodity -eq 'yukon-gold-potatoes' })[0]
$hvRow = @($ofg.gaps | Where-Object { $_.commodity -eq 'canned-pumpkin' })[0]
# CLEAN TWIN: a fresh Family Fare gap is owed by its own plan (never the phantom daily-ff-selfheal) and keeps its grace.
if ($ffRow -and -not [bool]$ffRow.escalated -and [string]$ffRow.owner -eq 'capture-plan:Family Fare' -and [int]$ffRow.grace_days -eq 3 -and [int]$ffRow.age_days -eq 0) { Ok 'sale-fallback CLEAN TWIN: a fresh Family Fare gap is OWNED by capture-plan:Family Fare with a 3-day grace, so validating owners did not page every owned gap' }
else { Bad ('sale-fallback did not give a fresh Family Fare gap to its plan (owner=' + [string]$ffRow.owner + ' grace=' + [int]$ffRow.grace_days + ' age=' + [int]$ffRow.age_days + ' escalated=' + [bool]$ffRow.escalated + '): ' + ($r.text -replace "`n", ' ')) }
# MUST-FIRE: a Hy-Vee gap belongs to capture-plan:Hy-Vee, NEVER the browser agent (Hy-Vee is pulled headless), and one
# its plan has owed for 4 days, past two of that daily lane's cycles (grace 3), escalates.
if ($hvRow -and [bool]$hvRow.escalated -and [string]$hvRow.owner -eq 'capture-plan:Hy-Vee' -and [int]$hvRow.age_days -eq 4 -and [int]$hvRow.grace_days -eq 3) { Ok 'sale-fallback MUST-FIRE: a Hy-Vee gap is owned by capture-plan:Hy-Vee, never weekly-browser-agent, and escalates once its plan has owed it past two cycles' }
else { Bad ('sale-fallback Hy-Vee gap wrong (owner=' + [string]$hvRow.owner + ' age=' + [int]$hvRow.age_days + ' grace=' + [int]$hvRow.grace_days + ' escalated=' + [bool]$hvRow.escalated + ') - either the browser label is back or a stale gap is silent: ' + ($r.text -replace "`n", ' ')) }
# MUST-FIRE: the plan's lane must be a REGISTERED job. Without the daily capture task every plan owner is NONE on DAY 0,
# and the report still names who claimed it (the 22b4dd property, kept).
$ownRegNoCap = Join-Path $fxOwn 'expected-automations-nocap.json'
Set-Content $ownRegNoCap '{"windows_tasks":[{"name":"TC Grocery Ad Pulls 0700"},{"name":"TC Graph Nightly Matching"}]}' -Encoding UTF8
$r = RunPS 'audit-sale-fallback.ps1' @('-OutDir', $fxOwn, '-CompareFile', (Join-Path $fxOwn 'comparison-2026-09-06.json'), '-AutomationsFile', $ownRegNoCap)
$ofg = try { Read-JsonFile (Join-Path $fxOwn 'sale-fallback-gaps.json') } catch { $null }
$ffRow = @($ofg.gaps | Where-Object { $_.commodity -eq 'yukon-gold-potatoes' })[0]
if ($ffRow -and [bool]$ffRow.escalated -and [int]$ffRow.grace_days -eq 0 -and [string]$ffRow.owner -eq 'NONE' -and [string]$ffRow.claimed_owner -eq 'capture-plan:Family Fare') { Ok 'sale-fallback MUST-FIRE: a plan owner whose lane is no registered automation escalates on DAY 0, and the report still names who claimed it' }
else { Bad ('sale-fallback granted grace to an unregistered plan owner (owner=' + [string]$ffRow.owner + ' claimed=' + [string]$ffRow.claimed_owner + ' grace=' + [int]$ffRow.grace_days + ' escalated=' + [bool]$ffRow.escalated + '): ' + ($r.text -replace "`n", ' ')) }
# ...and it says so out loud, naming the missing task rather than silently downgrading it
if ($r.text -match 'OWNER NOT REGISTERED' -and $r.text -match 'TC Grocery Daily Capture 0800') { Ok 'sale-fallback names the unregistered owner''s task on the run that demotes it' }
else { Bad ('sale-fallback demoted an unregistered owner without saying which task - the next reader cannot tell why a gap escalated: ' + ($r.text -replace "`n", ' ')) }
# MUST-FIRE: a registry it cannot read FAILS CLOSED, exactly like the ledger above. Reading it as
# "everything is registered" would restore the silence this whole item exists to remove.
'{ not json at all' | Set-Content $ownRegF -Encoding UTF8
$r = RunPS 'audit-sale-fallback.ps1' @('-OutDir', $fxOwn, '-CompareFile', (Join-Path $fxOwn 'comparison-2026-09-06.json'), '-AutomationsFile', $ownRegF)
$ofg = try { Read-JsonFile (Join-Path $fxOwn 'sale-fallback-gaps.json') } catch { $null }
if ($ofg -and [int]$ofg.escalated_count -eq 2 -and $r.text -match 'AUTOMATION REGISTRY UNREADABLE') { Ok 'sale-fallback MUST-FIRE: an unreadable automation registry proves no owner, so every gap escalates and says why' }
else { Bad ('sale-fallback did not fail closed on an unreadable automation registry (escalated=' + [int]$ofg.escalated_count + ') - a deleted or corrupt registry would silently re-grant grace to every owner: ' + ($r.text -replace "`n", ' ')) }
Remove-Item $fxOwn -Recurse -Force -ErrorAction SilentlyContinue
} # u063-k3c-an-owner-must-be-a-job-that

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
if (Use-Unit 'u064-n-6-the-verdict-driven-record-low') {
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
} # u064-n-6-the-verdict-driven-record-low

# (bm) THE BOARD'S OWN NAMES (2026-09-05, queue 2026-09-05-18d67c). Every encoding defence in this estate
# watched an INPUT - guards check 0d pins commodities.json, capture-lib repairs on ingest, heal-mojibake
# backfills the store files - and none of them looked at what the shopper reads. comparison-2026-09-02
# carried five mangled names across three stores with every guard green, and one of them (Sam's TRESemme)
# came from a file that is CLEAN on disk: sams-deals-2026-07-29.json has no BOM, and Windows PowerShell 5.1
# decodes a BOM-less UTF-8 file as the ANSI codepage, so the ENGINE manufactured the name while reading it.
# An input-only guard is structurally incapable of finding that one. Its fixtures are the real 117-character
# Campbell row and the real 148-character Craisins row stored as CODEPOINTS, so re-encoding that file cannot
# alter them, plus the same five products spelled correctly as clean twins.
if (Use-Unit 'u065-bm-the-board-s-own-names-every') {
$r = RunPS 'audit-board-mojibake.ps1' @('-SelfTest')
if ($r.rc -eq 0 -and $r.text -match 'SELF-TEST PASS' -and $r.text -match 'MUST FIRE') { Ok 'audit-board-mojibake -SelfTest passes with its founding-bug fixtures armed' }
else { Bad ('audit-board-mojibake -SelfTest failed or lost its founding-bug fixtures: ' + ((($r.text -split "`n") | Select-Object -Last 3) -join ' | ')) }
$abmSrc = Get-Content (Join-Path $root 'audit-board-mojibake.ps1') -Raw
if ($abmSrc -match '0x0043,0x0061,0x006D,0x0070,0x0062,0x0065,0x006C,0x006C') { Ok 'the frozen 5-generation Campbell row is still in audit-board-mojibake''s fixtures' }
else { Bad 'audit-board-mojibake lost the frozen Campbell fixture - the bug it encodes is being healed out of the live board, so without the frozen copy a green run cannot be told from a blind one' }
# BOTH SPELLINGS (2026-09-09). Backlog I86 turned `exit 3` into `Exit-Guard -Code 3` estate-wide, and
# this assertion still spelled the old one - so it reported a lost BLIND path on a guard that has three.
if ($abmSrc -match 'exit 3' -or $abmSrc -match '-Code 3') { Ok 'audit-board-mojibake reports BLIND rather than clean on a board it could not read' }
else { Bad 'audit-board-mojibake no longer has a BLIND path - a zero-row board would read as zero findings' }

# audit-band-censorship (2026-09-05). The band floor cannot tell a parse error from a real price drop, and
# nothing in the estate read what it threw away. The guard's whole value is the DISCRIMINATION - reporting
# a row 2.7% under the floor while staying silent on one 99.7% under - because without that it is just a
# second copy of the band with none of its judgement, and it would report 385 rows instead of 90.
$r = RunPS 'audit-band-censorship.ps1' @('-SelfTest')
if ($r.rc -eq 0 -and $r.text -match 'SELF-TEST PASS' -and $r.text -match 'MUST FIRE' -and $r.text -match 'DISCRIMINATION') {
  Ok 'audit-band-censorship -SelfTest passes with its founding bug, three clean twins and the discrimination case armed'
} else { Bad ('audit-band-censorship -SelfTest failed or lost a fixture: ' + ((($r.text -split "`n") | Select-Object -Last 3) -join ' | ')) }
$abcSrc = Get-Content (Join-Path $root 'audit-band-censorship.ps1') -Raw
# The frozen founding numbers. If the lettuce row is ever regenerated from the board it will encode the FIX
# and pass by finding nothing, which is the guard-fixture-rule failure this estate has hit repeatedly.
if ($abcSrc -match '0\.7783' -and $abcSrc -match '1\.0367') { Ok 'the frozen lettuce row (0.7783 refused against a published 1.0367) is still in audit-band-censorship''s fixtures' }
else { Bad 'audit-band-censorship lost its frozen lettuce fixture - regenerated from the board it would encode the fix and pass by finding nothing' }
# The parse-bug twin is the half that keeps it honest. Without it the guard passes by flagging everything.
if ($abcSrc -match '0\.0009') { Ok 'the per-sheet toilet-paper parse bug (0.0009 against a 0.30 floor) is still armed as the clean twin' }
else { Bad 'audit-band-censorship lost its parse-bug clean twin - a guard that reports every below-floor row is a copy of the band, not a check on it' }
if ($abcSrc -match 'exit 3' -or $abcSrc -match '-Code 3') { Ok 'audit-band-censorship reports BLIND rather than clean when nothing can express the defect' }
else { Bad 'audit-band-censorship no longer has a BLIND path - a flagged file with no banded rejection would read as a clean board' }
# THE RATCHET, asserted at the SOURCE as well as through -SelfTest. The guard shipped for an hour exiting 0
# with 50 real findings, so guards.ps1 printed "ok" on an invariant fifty cells were violating. If this
# ever loses its exit 2 it is silently advisory again, and an advisory report is not in the publish path.
if ($abcSrc -match 'Get-RatchetVerdict' -and $abcSrc -match "'break'" -and ($abcSrc -match 'exit 2' -or $abcSrc -match '-Code 2')) {
  Ok 'audit-band-censorship still HARD FAILS (exit 2) when the ratchet breaks - a new censored cell is not filed as backlog'
} else { Bad 'audit-band-censorship lost its ratchet break - it is advisory again, and guards.ps1 will print ok over real findings' }
# And the guards.ps1 invariant text must keep saying NEW, or the line claims more than the check proves.
$gSrcBc = Get-Content (Join-Path $root 'guards.ps1') -Raw
if ($gSrcBc -match 'no NEW cell publishes a dearer price' -and $gSrcBc -match 'band-censorship') {
  Ok 'guards.ps1 states the band-censorship invariant as the ratchet it is (NEW cells), not as an absolute it does not prove'
} else { Bad 'guards.ps1 band-censorship invariant no longer says NEW - it now claims an absolute the ratchet does not check' }

# import-walmart-batch's name->itemId map (2026-09-05). The deals file merges; this map used to be written
# straight over with the current batch only. A 22-row staleness repair cut it from 508 entries to 22 and the
# run reported "22 verified, 22 added, 0 rejected" - nothing reads the map during an import, so the loss was
# invisible until someone needed a link to resolve. The file is untracked, so there is no restoring it.
$iwbSrc = Get-Content (Join-Path $root 'import-walmart-batch.ps1') -Raw
if ($iwbSrc -match 'merged not replaced' -and $iwbSrc -match '\$idsOut\[\$p\.Name\]') {
  Ok 'import-walmart-batch MERGES walmart-itemids.json into the existing map instead of overwriting it with one batch'
} else { Bad 'import-walmart-batch no longer merges walmart-itemids.json - a small batch will silently discard every entry it did not capture, and the file is untracked so it cannot be restored' }
if ($iwbSrc -match 'REFUSING to overwrite it with this batch') {
  Ok 'import-walmart-batch refuses to overwrite an UNREADABLE itemId map rather than reading it as empty'
} else { Bad 'import-walmart-batch treats an unparseable itemId map as empty - the fail-open-reads-as-empty class, applied to the only copy of the map' }
# THE MARKDOWN STAMP HAS ONE HOME (2026-09-05). build-walmart-deals and build-sams-deals each carried a
# hand-copy of the same ten lines, and the copy had already cost a bug (the Sam's paste read a variable that
# file never assigns, so an old capture got a fresh 30-day anchor). import-walmart-batch was the third
# caller and had NO copy, so a batch-imported markdown published as an everyday price with a fresh as_of.
# If any of the three grows its own Add-Member 'marked_down' again, the copies are back.
$bwdSrcRb = Get-Content (Join-Path $root 'build-walmart-deals.ps1') -Raw
$bsdSrcRb = Get-Content (Join-Path $root 'build-sams-deals.ps1') -Raw
$iwbSrcRb = Get-Content (Join-Path $root 'import-walmart-batch.ps1') -Raw
if (($bwdSrcRb -match 'Set-RollbackFields') -and ($bsdSrcRb -match 'Set-RollbackFields') -and ($iwbSrcRb -match 'Set-RollbackFields')) {
  Ok 'all three markdown callers (walmart builder, sams builder, walmart batch importer) go through Set-RollbackFields'
} else { Bad ('a markdown caller no longer routes through Set-RollbackFields - walmart=' + [bool]($bwdSrcRb -match 'Set-RollbackFields') + ' sams=' + [bool]($bsdSrcRb -match 'Set-RollbackFields') + ' importer=' + [bool]($iwbSrcRb -match 'Set-RollbackFields')) }
$copies = @(@($bwdSrcRb,$bsdSrcRb,$iwbSrcRb) | Where-Object { $_ -match "NotePropertyName 'marked_down'" }).Count
if ($copies -eq 0) { Ok 'no caller carries its own inline marked_down stamp - the two hand-copies are gone, not just supplemented' }
else { Bad ("$copies caller(s) still stamp marked_down inline - a second implementation of one fact, which is how the Sam's anchor bug shipped") }
# And the capture format must still be able to CARRY a was-price, or the stamp above can never fire.
if ($iwbSrcRb -match 'wasPrice' -and $iwbSrcRb -match '\$f\[6\]') {
  Ok 'the Walmart batch raw format still carries a 7th was-price field (without it no markdown is knowable)'
} else { Bad 'the Walmart batch raw format lost its was-price field - markdowns become indistinguishable from everyday prices again' }
} # u065-bm-the-board-s-own-names-every

# ---- THE ENCODING PAIR (2026-09-05) ---------------------------------------------------------------------
# PS 5.1's Get-Content decodes a BOM-less file with the ANSI codepage. A BOM-less UTF-8 capture plus a
# reader that omits -Encoding mangles every non-ASCII byte, and the misdecoded string is written back, so
# each round trip bakes in another generation. Five live board cells were corrupted this way while every
# guard was green, and the worst offender's input file is CLEAN ON DISK - the engine did it at read time.
# RunPS resolves against grocery\, so the lib is invoked directly rather than through it.
if (Use-Unit 'u066-the-encoding-pair') {
$jioPath = Join-Path (Split-Path $root -Parent) 'lib\json-io.ps1'
$jioRes  = Invoke-NativeScript $jioPath '-SelfTest'
$jioOut  = @($jioRes.Lines) -join "`n"
if ($jioRes.ExitCode -eq 0 -and $jioOut -match 'MUST FIRE' -and $jioOut -match 'SELF-TEST PASSED') {
  Ok 'lib\json-io -SelfTest passes, and its FIRST case proves the PS 5.1 codepage bug still exists before claiming to fix it'
} else { Bad ('lib\json-io -SelfTest failed: ' + ((($jioOut -split "`n") | Select-Object -Last 3) -join ' | ')) }
$jioSrc = Get-Content $jioPath -Raw
# The must-fire asserts the BUG. If PowerShell ever changed this default the library would be decoration,
# and a fixture that cannot fail is exactly the dead-guard shape this harness exists to find.
if ($jioSrc -match 'still corrupts the name') { Ok 'json-io still asserts the founding PS 5.1 codepage bug is real, rather than assuming it' }
else { Bad 'json-io lost the case that proves the bug it fixes still exists - it can now pass while being pointless' }
if ($jioSrc -match 'ReadAllText') { Ok 'json-io reads through [IO.File]::ReadAllText (BOM-detecting, UTF-8 default), not -Encoding UTF8 which covers only one of the three shapes' }
else { Bad 'json-io no longer uses ReadAllText - a narrower fix that looks like the same fix' }

$r = RunPS 'audit-json-readers.ps1' @('-SelfTest')
if ($r.rc -eq 0 -and $r.text -match 'MUST FIRE' -and $r.text -match 'SELF-TEST PASS') {
  Ok 'audit-json-readers -SelfTest passes with its founding shape and four clean twins armed'
} else { Bad ('audit-json-readers -SelfTest failed: ' + ((($r.text -split "`n") | Select-Object -Last 3) -join ' | ')) }
# It must FAIL CLOSED on a file it could not scan. An undercount in a ratchet is worse than no ratchet: it
# lowers the baseline, and the next real regression then reads as "at or below the known backlog". This
# happened while the guard was being written - a Mandatory [string[]] rejected files with blank lines, the
# loop carried on, and the count was silently short.
$jrSrc = Get-Content (Join-Path $root 'audit-json-readers.ps1') -Raw
if ($jrSrc -match 'AllowEmptyString' -and $jrSrc -match 'BLIND: ') {
  Ok 'audit-json-readers fails CLOSED on a file it cannot scan, so its ratchet can never be built from a partial count'
} else { Bad 'audit-json-readers can undercount silently - a ratchet built from a partial scan lowers its own baseline and hides the next regression' }

$abmR = Get-Content (Join-Path $root 'audit-board-mojibake.ps1') -Raw
if ($abmR -match 'RATCHET BROKEN' -and $abmR -match 'board-mojibake-baseline') {
  Ok 'audit-board-mojibake is a RATCHET - a name that was clean and is now mangled hard-fails rather than being filed as backlog'
} else { Bad 'audit-board-mojibake lost its ratchet - it is advisory again, and a live reader bug will publish' }
$gSrcEnc = Get-Content (Join-Path $root 'guards.ps1') -Raw
# BOTH ENDS STILL RUN, IN TWO PLACES SINCE 2026-09-21: the OUTCOME (mangled board names, board data) in the publish
# gate, the CAUSE (bare readers, source code) at push time in ops\run-gates.ps1, where a source defect belongs.
$rgSrcEnc = Get-Content (Join-Path (Split-Path $root -Parent) 'ops\run-gates.ps1') -Raw
if ($gSrcEnc -match "'audit-board-mojibake\.ps1'" -and $gSrcEnc -notmatch "Register-Kid\s+'json-readers'" -and $rgSrcEnc -match "f = 'grocery\\audit-json-readers\.ps1'") {
  Ok 'the encoding pair still runs at both ends - board-mojibake in guards.ps1, json-readers at push time in run-gates'
} else { Bad 'one end of the encoding pair is missing (board-mojibake must stay in guards.ps1, json-readers must run in ops\run-gates.ps1 and not hold the board) - either half alone leaves the other unguarded' }

# audit-pack-basis could not be quieted by a ruling (2026-09-05). It reported every ambiguous pack on every
# run with no way to mark one reviewed, so the hummus row sat unruled for weeks and a genuine
# CONFIRMED-PACK-TOTAL would eventually have been lost in standing noise. The ruling now lives in
# multipack-allowlist.json - the SAME file guard 5 reads, because a pack this audit has cleared and a pack
# the publish gate has cleared must never be two different lists.
$apbSrc = Get-Content (Join-Path $root 'audit-pack-basis.ps1') -Raw
if ($apbSrc -match 'multipack-allowlist\.json') {
  Ok 'audit-pack-basis reads its rulings from multipack-allowlist.json, the same list guard 5 uses'
} else { Bad 'audit-pack-basis has no ruling path again - an advisory nobody can close is an advisory nobody reads' }
# THE LOAD-BEARING HALF: a ruling must never silence the arithmetic fingerprint. That is a hard fail by
# design, and an allowlist that could quiet it would become a way to publish a known-bad number.
if ($apbSrc -match '-and\s+-not\s+\$fpConfirmed') {
  Ok 'a pack-basis ruling CANNOT silence a CONFIRMED-PACK-TOTAL - only the undecidable ones go quiet'
} else { Bad 'a pack-basis ruling can now silence the arithmetic fingerprint - the allowlist has become a way to publish a known-bad pack multiply' }
# A silenced row must still be VISIBLE as a count. Disappearing entirely is how a suppression list grows
# without anyone noticing what is in it.
if ($apbSrc -match 'ruled in multipack-allowlist') {
  Ok 'a ruled pack is still reported as a COUNT, never simply absent'
} else { Bad 'audit-pack-basis suppresses ruled rows silently - the list can grow unnoticed' }

# THE ENCODING REPAIR MUST RUN AT INGEST, NOT ONLY AT THE GATE (2026-09-05). bakers-deals and
# fareway-deals are written by a VISION-READING AGENT, not by any script - pull-bakers.ps1 only downloads
# the flyer pages and writes meta.json - which is why no code search ever found the writer and why those
# two families kept arriving BOM-less. Naming such a file at the publish gate means a hard fail waiting on
# a human to run -Fix, which is an alarm with no repair lane. capture-run normalises at ingest so the gate
# becomes the proof it worked.
$crSrc = Get-Content (Join-Path $root 'capture-run.ps1') -Raw
if ($crSrc -match 'audit-capture-encoding' -and $crSrc -match "-Fix") {
  Ok 'capture-run normalises capture encoding at INGEST, so an agent-written BOM-less file never reaches the engine'
} else { Bad 'capture-run no longer normalises capture encoding - a vision-agent capture will reach the engine BOM-less and a bare reader will mangle it' }
$aceSrc = Get-Content (Join-Path $root 'audit-capture-encoding.ps1') -Raw
# The invariant must stay 'BOM or pure ASCII'. Demanding a BOM outright would fight audit-json-encoding's
# deliberate ASCII-no-BOM pin on commodities.json, and two guards demanding opposite things is how one
# gets switched off.
if ($aceSrc -match 'pure ASCII') {
  Ok 'capture-encoding still accepts pure ASCII as unambiguous - it does not fight the commodities.json ASCII pin'
} else { Bad 'capture-encoding now demands a BOM outright, which contradicts audit-json-encoding pinning commodities.json to ASCII with no BOM' }
# ...and the healer it depends on must still reach the depth the board actually hit. These are two halves of
# one loop: a healer that stops short leaves the audit permanently red, and the only way to make it green
# again is to weaken the signature.
$clSrc = Get-Content (Join-Path $root 'capture-lib.ps1') -Raw
if ($clSrc -match '\$i -lt 8') { Ok 'Repair-Mojibake still peels deep enough for the 5-generation founding row' }
else { Bad 'Repair-Mojibake''s peel cap has been lowered - the 117-character Campbell row needs five passes and the cap was 4 when it shipped mangled' }
# THE READER THAT MANUFACTURED IT. compare-deals must not go back to reading store JSON without an encoding.
$cdEnc = Get-Content (Join-Path $root 'compare-deals.ps1') -Raw
if ($cdEnc -match 'function Read-JsonFile' -and $cdEnc -notmatch 'Get-Content \$extra -Raw \| ConvertFrom-Json') { Ok 'compare-deals reads its store inputs through Read-JsonFile (BOM-tolerant), not a codepage-dependent Get-Content' }   # json-readers:allow the frozen literal names the shape compare-deals must NOT contain; converting it would blind the check
else { Bad 'compare-deals is reading store JSON with a bare Get-Content again - a BOM-less input will be decoded as the ANSI codepage and the mangled name will be written onto the board' }
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
# The count is pinned on purpose: it is the ratchet that catches a fixture being DELETED rather than fixed.
# Raised 12 -> 14 on 2026-08-06 when the reviewed COMMODITY_DEPT exception table grew from 7 entries to 21
# and took a must-fire / clean-twin pair with it (an excepted commodity in a NON-listed department must still
# BLOCK; the same commodity in its listed department must ALLOW through the exception). Never lower it.
# Raised 14 -> 20 on 2026-09-11 (queue 2026-09-11-62b248) when the rule moved to aisle-lib.ps1 and compare-deals
# began refusing Family Fare rows at ADMISSION through it: the Contadina squeeze bottle refused by id and by name
# naming pantry, Di Giorno allowed from freezer, the Planters exception honoured through the same path, a
# shelf-less row and a non-FF row admitted, and a /shop/<product_slug>/p/ URL that must not read as a department.
$r = RunPS 'aisle-test.ps1' @('-SelfTest')
if ($r.rc -eq 0 -and $r.text -match 'SELFTEST: 20/20 pass') { Ok 'aisle-test -SelfTest passes (5 founding/exception flips blocked, hard positive allowed, exception path allowed, blind refuses, multi-row unrolls)' }
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
$cacSrc2 = (Expand-SelfTestPointers -Text ((Expand-SelfTestPointers -Text ([IO.File]::ReadAllText((Join-Path $root 'check-ad-cycles.ps1'))) -Path (Join-Path $root 'check-ad-cycles.ps1'))) -Path (Join-Path $root 'check-ad-cycles.ps1'))
if ($cacSrc2 -match "purge-verdict-lows\.ps1'\) -Apply") { Ok 'the daily history bank is swept for verdict-rejected entries' }
else { Bad 'check-ad-cycles no longer purges after banking - the raw branch skips verify-apply, so every standing DROP is inert there and can bank a fresh record low' }
} # u066-the-encoding-pair

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
if (Use-Unit 'u067-l-review-flag-re-arm-ack-expiry') {
$rfSrc = (Expand-SelfTestPointers -Text ([IO.File]::ReadAllText((Join-Path $root 'check-ad-cycles.ps1'))) -Path (Join-Path $root 'check-ad-cycles.ps1'))
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
  function RfRunDay([datetime]$now, [hashtable]$fstate, [bool]$noAlert, [bool]$sendFails, [string[]]$keys = @()) {
    $script:RF_NOW = $now
    function Get-Date { return $script:RF_NOW }
    function Log([string]$m) { }
    $NoAlert = $noAlert
    # $keys lets a case drive the SAME region with its own flag set (the re-arm coalescing cases below).
    # Omitted, it is the original three, so every case written before 2026-09-11 runs unchanged.
    $flagKeys  = if (@($keys).Count -gt 0) { @($keys) } else { @($rfOpen, $rfAck, $rfFresh) }   # flagged EVERY day - the backlog scenario
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
  # ---- RE-ARMS RIDE, THEY DO NOT LEAD (2026-09-11, weekly prevention lane) --------------------------
  # Founding measurement, off the live out\alerted-flags.json: 21 standing flags carry a clock and their
  # 14-day re-arms fall on 6 DISTINCT days inside the next 14, so this alert type fired on 12 of the 14
  # days ending 2026-09-11 (census rank 1) on flags the reader had already been told about. Frozen here as
  # two open keys whose re-arms fall 3 days apart: one page day, not two.
  $rfA1 = 'SANITY|FIXTURE Backlog A|outlier'
  $rfA2 = 'SANITY|FIXTURE Backlog B|outlier'
  $rfNew = 'SANITY|FIXTURE Brand New|outlier'
  function RfBacklogState {
    $h = @{}
    $h[$rfA1] = [pscustomobject]@{ first_seen = $rfT0.AddDays(-40).ToString('s'); last_seen = $rfT0.AddDays(-1).ToString('s'); last_detail = 'x'; last_alerted = $rfT0.AddDays(-14).ToString('s') }
    $h[$rfA2] = [pscustomobject]@{ first_seen = $rfT0.AddDays(-40).ToString('s'); last_seen = $rfT0.AddDays(-1).ToString('s'); last_detail = 'x'; last_alerted = $rfT0.AddDays(-11).ToString('s') }
    return $h
  }
  # MUST FIRE 4: the two re-arms land in ONE mail. Before the fix A paged on day 0 and B on day 3.
  $rfSt = RfBacklogState; $rfDays = @()
  for ($rfD2 = 0; $rfD2 -lt 11; $rfD2++) { if ((RfRunDay $rfT0.AddDays($rfD2) $rfSt $false $false @($rfA1, $rfA2)).due.Count -gt 0) { $rfDays += $rfD2 } }
  if (@($rfDays).Count -eq 1) { Ok ('review flags: two staggered re-arms page on ONE day (day ' + ($rfDays -join ',') + '), not one mail each') }
  else { Bad ('review flags: a backlog of 2 re-armed flags paged on ' + @($rfDays).Count + ' separate day(s) [' + ($rfDays -join ',') + '] - each standing flag still starts a mail of its own, which is what makes this type fire almost daily') }
  # MUST FIRE 4b: held is not dropped. Both keys must be in that one mail, and it must happen inside
  # REARM_DAYS + REARM_RIDE_DAYS, or a held re-arm has been silently swallowed.
  $rfSt = RfBacklogState; $rfPaged = @()
  for ($rfD2 = 0; $rfD2 -lt 11; $rfD2++) { $rfPaged += @((RfRunDay $rfT0.AddDays($rfD2) $rfSt $false $false @($rfA1, $rfA2)).due) }
  if (($rfPaged -contains $rfA1) -and ($rfPaged -contains $rfA2)) { Ok 'review flags: every held re-arm still pages - holding is not dropping' }
  else { Bad ('review flags: a held re-arm never paged in 11 days - it was swallowed, not deferred (paged: ' + (($rfPaged | Sort-Object -Unique) -join ' ; ') + ')') }
  # CLEAN TWIN 4: a key NEVER SEEN pages the day it appears, and the waiting re-arms ride along in that
  # same mail rather than waiting for their own day. This is the half the fix was most likely to break.
  $rfSt = RfBacklogState
  $rfR = RfRunDay $rfT0 $rfSt $false $false @($rfA1, $rfA2, $rfNew)
  if ($rfR.due -contains $rfNew) { Ok 'review flags: a brand-new flag still pages the day it appears, never deferred' }
  else { Bad 'review flags: a NEW flag was held by the re-arm coalescing - novel flags must page same-day' }
  # Day 3, not day 0: B's own clock does not re-arm until day 3, so asking for both on day 0 would be
  # asserting something the re-arm window forbids and the case would grade correct behaviour as broken.
  $rfSt = RfBacklogState
  $rfR = RfRunDay $rfT0.AddDays(3) $rfSt $false $false @($rfA1, $rfA2, $rfNew)
  if (($rfR.due -contains $rfA1) -and ($rfR.due -contains $rfA2)) { Ok 'review flags: re-arms RIDE a day that is already paging, so they cost no extra mail' }
  else { Bad 'review flags: re-arms did not ride a page day that was already sending - they will each cost a day of their own later' }
}
} # u067-l-review-flag-re-arm-ack-expiry

# ---------------------------------------------------------------- (k2b) THE STORE'S OWN UNIT PRICE
# 2026-09-04, queue 2026-09-04-def37c. sanity-check has carried a native_unit_price cross-check since it was
# written and NOT ONE comparison row has ever carried that field - no producer populated it - so the check
# was dormant for every store from day one. The consequence was not a missing check but a paging loop: the
# only valve for a true-but-47%-cheaper cell was a hand-written ack with a short expiry, and the designed
# re-arm-on-expiry paged the same reviewed-real row again every time the ack lapsed.
# THE FOUNDING PAIR, frozen verbatim off comparison-2026-09-02 and out\sams\sams-deals-2026-07-29.json:
# Sam's Quaker Old Fashioned Oats 160 oz (a 10 lb sack) at $7.98 = $0.0499/oz against Aldi's 42 oz at
# $3.99 = $0.0950/oz, and Sam's own shelf publishes $0.05/oz. Paged 2026-07-29, acked as real, ack expired
# 2026-08-13, paged again 2026-09-04.
if (Use-Unit 'u068-k2b-the-store-s-own-unit-price') {
$fxSv = NewFxDir 'sanity-native'
$svOats = '{"week_of":"2026-09-02","comparison":[{"commodity":"Oats / Oatmeal","id":"oatmeal","unit":"oz","cheapest_price":0.0499,"stores":[{"store":"Sam''s Club","per_unit":0.0499,"unit":"oz","item":"Quaker Old Fashioned Oats, 160 oz.","native_unit_price":0.05,"native_unit":"oz"},{"store":"Aldi","per_unit":0.095,"unit":"oz","item":"Millville Hearty 100 Whole Grain Old Fashioned Rolled Oats 42 OZ"}]}]}'
Set-Content (Join-Path $fxSv 'comparison-2026-09-02.json') $svOats -Encoding UTF8
} # u068-k2b-the-store-s-own-unit-price
# ASSIGN, THEN WRAP. PS 5.1's ConvertFrom-Json writes a JSON ARRAY to the pipeline as ONE object, so
# `@(Get-Content | ConvertFrom-Json)` is a 1-element array CONTAINING the array. Reading .type off that
# then member-enumerates and stringifies to "outlier native-mismatch", and every -contains test silently
# answers the wrong question. Same trap check-ad-cycles documents at the review-flag loader.
# the comma keeps the array from unrolling on the way out, so a ONE-flag result is still an array
function SvRead([string]$p) { $d = Read-JsonFile $p; return , @($d) }
if (Use-Unit 'u068-k2b-the-store-s-own-unit-price') {
$r = RunPS 'sanity-check.ps1' @('-CompareFile', (Join-Path $fxSv 'comparison-2026-09-02.json'), '-OutDir', $fxSv)
$svJ = SvRead (Join-Path $fxSv 'guards-2026-09-02.json')
$svOat = @($svJ | Where-Object { $_.commodity -eq 'Oats / Oatmeal' -and $_.type -eq 'outlier-verified' })
if ($svOat.Count -eq 1 -and $svOat[0].detail -match '0\.0499' -and $svOat[0].detail -match '0\.0500') {
  Ok 'sanity native: MUST FIRE - the founding oats pair is written as outlier-verified and the detail quotes BOTH our number and the store''s'
} else { Bad ('sanity native: the oats pair did not become outlier-verified quoting both numbers (' + (($svJ | ForEach-Object { $_.type }) -join ',') + ') - the cross-check is dormant again, or the tolerance no longer accepts a cent-rounded store price') }
# MUST FIRE: a DISAGREEING store price must page as BOTH an ordinary outlier and a native-mismatch. A
# verified flag is only meaningful if a contradicted one is still loud.
$svBad = $svOats -replace '"native_unit_price":0\.05,', '"native_unit_price":0.10,'
Set-Content (Join-Path $fxSv 'comparison-2026-09-02.json') $svBad -Encoding UTF8
$r = RunPS 'sanity-check.ps1' @('-CompareFile', (Join-Path $fxSv 'comparison-2026-09-02.json'), '-OutDir', $fxSv)
$svJ = SvRead (Join-Path $fxSv 'guards-2026-09-02.json')
$svT = @($svJ | ForEach-Object { [string]$_.type })
if (($svT -contains 'outlier') -and ($svT -contains 'native-mismatch') -and ($svT -notcontains 'outlier-verified')) {
  Ok 'sanity native: MUST FIRE - a store price that DISAGREES with ours pages as an ordinary outlier AND as native-mismatch'
} else { Bad ('sanity native: a disagreeing store unit price produced ' + ($svT -join ',') + ' - a contradicted cell would be recorded as verified') }
# MUST FIRE: not comparable is not agreement. A Sam''s row priced per EACH on an OUNCE commodity carries no
# native field at all (compare-deals refuses to emit one), so its outlier must page exactly as before.
$svEa = '{"week_of":"2026-09-02","comparison":[{"commodity":"Hummus","id":"hummus","unit":"oz","cheapest_price":0.1395,"stores":[{"store":"Sam''s Club","per_unit":0.1395,"unit":"oz","item":"Member''s Mark Classic Hummus Singles 2.5 oz., 16 ct."},{"store":"Aldi","per_unit":0.259,"unit":"oz","item":"Park Street Deli Classic Hummus 10 OZ"}]}]}'
Set-Content (Join-Path $fxSv 'comparison-2026-09-02.json') $svEa -Encoding UTF8
$r = RunPS 'sanity-check.ps1' @('-CompareFile', (Join-Path $fxSv 'comparison-2026-09-02.json'), '-OutDir', $fxSv)
$svJ = SvRead (Join-Path $fxSv 'guards-2026-09-02.json')
if (@($svJ | Where-Object { $_.type -eq 'outlier' }).Count -eq 1 -and @($svJ | Where-Object { $_.type -eq 'outlier-verified' }).Count -eq 0) {
  Ok 'sanity native: CLEAN TWIN - a row with NO store unit price stays an ordinary outlier; absence of proof is not proof'
} else { Bad 'sanity native: a row carrying no native unit price was treated as verified - an unproven cell would stop paging' }
# CLEAN TWIN: the three rounding edges the live board actually contains. A store publishes to the cent, so
# "$0.15/oz" is anything in [0.145,0.155) and our 0.155 reproduces it; a pure 3% test calls that a
# disagreement. The tolerance is max(half a cent, 3%) and it is INCLUSIVE - 0.005 <= 0.00501, the 0.00001
# being float slack, not data slack. The fourth pair must still FAIL, or the tolerance is just wide.
$svEdges = @(
  @{ ours = 0.155;  nat = 0.15; want = $true;  what = 'Sam''s saltines 0.155 vs $0.15/oz (the one boundary case on the whole board)' },
  @{ ours = 0.0449; nat = 0.04; want = $true;  what = 'grits 0.0449 vs $0.04/oz' },
  @{ ours = 0.215;  nat = 0.21; want = $true;  what = 'yeast 0.215 vs $0.21/oz' },
  @{ ours = 0.0499; nat = 0.06; want = $false; what = 'a genuine 20% disagreement 0.0499 vs $0.06/oz' }
)
$svEdgeBad = 0
foreach ($e in $svEdges) {
  $row = '{"week_of":"2026-09-02","comparison":[{"commodity":"Edge","id":"edge","unit":"oz","cheapest_price":' + $e.ours + ',"stores":[{"store":"Sam''s Club","per_unit":' + $e.ours + ',"unit":"oz","item":"Edge fixture","native_unit_price":' + $e.nat + ',"native_unit":"oz"},{"store":"Aldi","per_unit":' + ([math]::Round($e.ours * 4, 4)) + ',"unit":"oz","item":"Edge runner-up"}]}]}'
  Set-Content (Join-Path $fxSv 'comparison-2026-09-02.json') $row -Encoding UTF8
  $null = RunPS 'sanity-check.ps1' @('-CompareFile', (Join-Path $fxSv 'comparison-2026-09-02.json'), '-OutDir', $fxSv)
  $j = SvRead (Join-Path $fxSv 'guards-2026-09-02.json')
  $verified = (@($j | Where-Object { $_.type -eq 'outlier-verified' }).Count -eq 1)
  if ($verified -ne $e.want) { $svEdgeBad++; Bad ('sanity native tolerance: ' + $e.what + ' read as ' + $(if ($verified) { 'AGREEMENT' } else { 'disagreement' }) + ', expected the opposite') }
}
if ($svEdgeBad -eq 0) { Ok 'sanity native: CLEAN TWIN - all three cent-rounding edges read as agreement and a real 20% gap still does not' }
Remove-Item $fxSv -Recurse -Force -ErrorAction SilentlyContinue
} # u068-k2b-the-store-s-own-unit-price

# ---- the week-over-week detector must not compare across a UNIT CHANGE ---------------------------
# (2026-09-06, queue 2026-09-06-24ac66) THE FOUNDING ROW, frozen: aluminum-foil was priced per EACH
# until the commodity was re-based to sq_ft. price-history carried week_of, cheapest_price,
# cheapest_store and per_store - and never the unit - so on 2026-09-06 sanity-check compared 1.79 PER
# EACH against 0.0624 PER SQUARE FOOT and paged 'cheapest moved down 97%'. Both numbers were right.
# Until this change sanity-check read $root\price-history.json unconditionally, so NO fixture could
# reach this branch at all - that is why -HistoryFile exists and why these cases can exist.
if (Use-Unit 'u069-the-week-over-week-detector-must-not') {
$fxU = NewFxDir 'sanity-unit'
$uHistPath = Join-Path $fxU 'price-history.json'
} # u069-the-week-over-week-detector-must-not
function UWrite($boardJson, $histJson) {
  Set-Content (Join-Path $fxU 'comparison-2026-09-06.json') $boardJson -Encoding UTF8
  Set-Content $uHistPath $histJson -Encoding UTF8
}
function URun {
  $null = RunPS 'sanity-check.ps1' @('-CompareFile', (Join-Path $fxU 'comparison-2026-09-06.json'), '-OutDir', $fxU, '-HistoryFile', $uHistPath)
  $d = Read-JsonFile (Join-Path $fxU 'guards-2026-09-06.json'); return , @($d)
}
# MUST-FIRE: the real 2026-09-06 foil row. each -> sq_ft must produce 'unit-changed' and NEVER 'wow'.
if (Use-Unit 'u069-the-week-over-week-detector-must-not') {
$uFoilBoard = '{"week_of":"2026-09-06","comparison":[{"commodity":"Aluminum Foil","id":"aluminum-foil","unit":"sq_ft","cheapest_price":0.0624,"stores":[{"store":"Hy-Vee","per_unit":0.0624,"unit":"sq_ft","item":"Hy-Vee aluminum foil, 50 or 75 sq. ft."},{"store":"Walmart","per_unit":0.0644,"unit":"sq_ft","item":"Great Value Aluminum Foil 75 sq ft Roll"}]}]}'
UWrite $uFoilBoard '{"commodities":[{"id":"aluminum-foil","history":[{"week_of":"2026-08-10","cheapest_price":1.79,"cheapest_store":"Family Fare","unit":"each"}]}]}'
$uJ = URun
$uT = @($uJ | ForEach-Object { [string]$_.type })
if (($uT -contains 'unit-changed') -and ($uT -notcontains 'wow')) { Ok 'sanity wow: MUST FIRE - aluminum-foil each -> sq_ft is reported as unit-changed and NOT as a 97% crash' }
else { Bad ('sanity wow: a re-based commodity produced ' + ($uT -join ',') + ' - 1.79 per each is still being compared against 0.0624 per sq ft, which pages a human to verify a correct parse') }
if (@($uJ | Where-Object { $_.type -eq 'unit-changed' })[0].detail -match 'each' -and @($uJ | Where-Object { $_.type -eq 'unit-changed' })[0].detail -match 'sq_ft') { Ok 'sanity wow: the unit-changed detail names BOTH units, so the reader can see what was re-based' }
else { Bad 'sanity wow: unit-changed did not name the old and new units - the finding is unactionable without them' }
# CLEAN TWIN 1: the real frozen-pizza row. SAME unit both weeks, so a 70% move must still page as wow.
$uPizzaBoard = '{"week_of":"2026-09-06","comparison":[{"commodity":"Frozen Pizza","id":"frozen-pizza","unit":"each","cheapest_price":2.96,"stores":[{"store":"Walmart","per_unit":2.96,"unit":"each","item":"Tony''s Pepperoni Pizzeria Style Crust Frozen Pizza, 18.56 oz"},{"store":"Sam''s Club","per_unit":2.97,"unit":"each","item":"Jack''s Original Thin Pepperoni Frozen Pizza 4 pk."}]}]}'
UWrite $uPizzaBoard '{"commodities":[{"id":"frozen-pizza","history":[{"week_of":"2026-09-02","cheapest_price":1.745,"cheapest_store":"Baker''s","unit":"each"}]}]}'
$uT = @(URun | ForEach-Object { [string]$_.type })
if (($uT -contains 'wow') -and ($uT -notcontains 'unit-changed')) { Ok 'sanity wow: CLEAN TWIN - a real 70% move within the SAME unit still pages as wow (the fix did not mute the detector)' }
else { Bad ('sanity wow: a genuine same-unit price move produced ' + ($uT -join ',') + ' - the unit test has silenced the week-over-week detector itself') }
# CLEAN TWIN 2: the fl_oz -> floz SPELLING normalisation of 2026-08-30 renamed five commodities' unit.
# Those must NOT read as re-basings, and with an unchanged price they must produce nothing at all.
$uSpellBoard = '{"week_of":"2026-09-06","comparison":[{"commodity":"Avocado Oil","id":"avocado-oil","unit":"floz","cheapest_price":0.32,"stores":[{"store":"Walmart","per_unit":0.32,"unit":"floz","item":"Great Value Avocado Oil"},{"store":"Aldi","per_unit":0.35,"unit":"floz","item":"Simply Nature Avocado Oil"}]}]}'
UWrite $uSpellBoard '{"commodities":[{"id":"avocado-oil","history":[{"week_of":"2026-09-02","cheapest_price":0.32,"cheapest_store":"Walmart","unit":"fl_oz"}]}]}'
$uT = @(URun | ForEach-Object { [string]$_.type })
if (($uT -notcontains 'unit-changed') -and ($uT -notcontains 'wow')) { Ok 'sanity wow: CLEAN TWIN - fl_oz and floz are the SAME unit, so the 2026-08-30 spelling rename produces no finding' }
else { Bad ('sanity wow: the fl_oz -> floz spelling rename produced ' + ($uT -join ',') + ' - this fix would have manufactured five false alarms of its own') }
# CLEAN TWIN 3: a LEGACY entry with no unit at all must NOT be silently blessed. The wow verdict stands
# and says the prior unit was unrecorded, so a reader knows the comparison is unproven rather than proven.
UWrite $uFoilBoard '{"commodities":[{"id":"aluminum-foil","history":[{"week_of":"2026-08-10","cheapest_price":1.79,"cheapest_store":"Family Fare"}]}]}'
$uJ = URun
$uW = @($uJ | Where-Object { $_.type -eq 'wow' })
if ($uW.Count -eq 1 -and $uW[0].detail -match 'prior unit unrecorded') { Ok 'sanity wow: CLEAN TWIN - a legacy history entry with NO unit still pages, and says the prior unit was unrecorded rather than claiming agreement' }
else { Bad ('sanity wow: a unit-less legacy history entry produced ' + (@($uJ | ForEach-Object { [string]$_.type }) -join ',') + ' - either the whole legacy history has gone quiet, or it is being reported as if the units were known') }
Remove-Item $fxU -Recurse -Force -ErrorAction SilentlyContinue
# and the WRITER must actually bank the unit, or every case above tests a field nothing produces
$uhSrc = Get-Content (Join-Path $root 'update-history.ps1') -Raw
# 2026-09-22 (plan-2026-09-22-10): the entry is built by New-HistoryEntry, which the upsert AND -Reconcile share, so the
# unit is required in that builder and the upsert must go through it; the old inline literal is still accepted.
if (($uhSrc -match '\$thisWeek\s*=\s*\[ordered\]@\{[^}]*unit\s*=') -or (($uhSrc -match 'function New-HistoryEntry[^\n]*\n[^\n]*\n\s*return \[ordered\]@\{[^}]*unit\s*=') -and ($uhSrc -match '\$thisWeek\s*=\s*New-HistoryEntry '))) { Ok 'sanity wow: update-history banks the commodity unit into every new history entry (the reader above has something to read)' }
else { Bad 'sanity wow: update-history no longer writes a unit into the history entry - the unit-changed detector will read every future week as legacy and never fire again' }
} # u069-the-week-over-week-detector-must-not

# ---- and the PAGER: a verified outlier is recorded but not paged, while an UNKNOWN type still pages ----
# Extracted and run, never transcribed. FAIL CLOSED is the property under test: the quiet list is an
# ALLOWLIST of one, so a type this code has never heard of pages by construction.
if (Use-Unit 'u070-and-the-pager-a-verified-outlier-is') {
$spSrc = (Expand-SelfTestPointers -Text ((Expand-SelfTestPointers -Text ([IO.File]::ReadAllText((Join-Path $root 'check-ad-cycles.ps1'))) -Path (Join-Path $root 'check-ad-cycles.ps1'))) -Path (Join-Path $root 'check-ad-cycles.ps1'))
$spM = [regex]::Match($spSrc, '(?s)<<SANITY-PAGER-BEGIN>>[^\r\n]*\r?\n(.*?)\r?\n[ \t]*# <<SANITY-PAGER-END>>')
if (-not $spM.Success) {
  Bad 'SANITY-PAGER region is GONE from check-ad-cycles.ps1 - this check EXAMINED NOTHING, the quiet-type allowlist is untested'
} else {
  $SP = $spM.Groups[1].Value
  $fxSp = NewFxDir 'sanity-pager'
  $spRows = '[{"commodity":"Oats / Oatmeal","type":"outlier-verified","detail":"store agrees"},{"commodity":"Anaheim Peppers","type":"outlier","detail":"unverified"},{"commodity":"Mystery","type":"outlier-nonsense","detail":"a type this code has never seen"},{"commodity":"Something","type":"wow","detail":"moved 60%"}]'
  Set-Content (Join-Path $fxSp 'guards-2026-09-02.json') $spRows -Encoding UTF8
  $gf = Get-Item (Join-Path $fxSp 'guards-2026-09-02.json')
  $flagParts = @(); $flagKeys = @()
  . ([scriptblock]::Create($SP))
  if ($sanityQuiet -eq 1 -and ($flagKeys -notcontains 'SANITY|Oats / Oatmeal|outlier-verified')) {
    Ok 'sanity pager: MUST FIRE - a store-verified outlier is counted and NOT paged (the ack-expiry re-page loop is closed)'
  } else { Bad ('sanity pager: outlier-verified still pages (quiet=' + $sanityQuiet + ', keys=' + ($flagKeys -join ' ; ') + ')') }
  if (($flagKeys -contains 'SANITY|Mystery|outlier-nonsense') -and ($flagKeys -contains 'SANITY|Anaheim Peppers|outlier') -and ($flagKeys -contains 'SANITY|Something|wow')) {
    Ok 'sanity pager: CLEAN TWIN - an UNKNOWN flag type still pages, and so do ordinary outliers and wow moves (allowlist, not denylist)'
  } else { Bad ('sanity pager: FAIL-CLOSED broken - an unrecognised flag type went quiet. keys=' + ($flagKeys -join ' ; ')) }
  Remove-Item $fxSp -Recurse -Force -ErrorAction SilentlyContinue
}
} # u070-and-the-pager-a-verified-outlier-is

# ---- the MULTIBUY pager: only the UNRESOLVED half of an out-of-band multibuy pages as a price flag ----------
# (2026-09-25, queue 2026-09-23-9459a1, grocery/triage-plans/plan-2026-09-25-15.json). Extracted and run, never
# transcribed. Rows FROZEN from flagged-2026-09-23 (Family Fare); the half field is what compare-deals now writes.
# A row with no half (every flagged file before this change) must still page: fail closed.
if (Use-Unit 'u146-multibuy-pager-pages-only-the-unresolved-half' -Reads 'grocery/check-ad-cycles.ps1') {
$mpM = [regex]::Match(((Expand-SelfTestPointers -Text ((Expand-SelfTestPointers -Text ([IO.File]::ReadAllText((Join-Path $root 'check-ad-cycles.ps1'))) -Path (Join-Path $root 'check-ad-cycles.ps1'))) -Path (Join-Path $root 'check-ad-cycles.ps1'))), '(?s)<<MULTIBUY-PAGER-BEGIN>>[^\r\n]*\r?\n(.*?)\r?\n[ \t]*# <<MULTIBUY-PAGER-END>>')
if (-not $mpM.Success) {
  Bad 'MULTIBUY-PAGER region is GONE from check-ad-cycles.ps1 - this check EXAMINED NOTHING, the multibuy half filter is untested'
} else {
  $fxMp = NewFxDir 'multibuy-pager'
  $mpJson = '{"week_of":"2026-09-23","flagged_count":0,"flagged":[],"multibuy_unpriced":[' +
    '{"id":"hand-soap","label":"Hand Soap","store":"Family Fare","name":"Dove Hand Wash, Antibacterial 12 Fl Oz","price_text":"Buy 1 get 1 40% off","regular":5.99,"size_text":"12 oz","half":"complete-basis","reason":"priced but OUT-OF-BAND ($0.3993 outside 0.01216-0.304) on a complete basis (size 12 floz) - the band refuses a real price; see band review"},' +
    '{"id":"bar-soap","label":"Bar Soap","store":"Family Fare","name":"Dove Cleansing Bar, Relax, Eucalyptus + Cedar Oil 5 Oz","price_text":"Buy 1 get 1 40% off","regular":7.99,"size_text":"5 oz","half":"unresolved","reason":"priced but OUT-OF-BAND ($6.392 outside 0.19976-4.994) with an unresolved pack count (per-each) - review the capture"},' +
    '{"id":"deodorant","label":"Deodorant","store":"Family Fare","name":"Dove Men+Care Antiperspirant, Extra Fresh, Twin Pack 2 Ea","price_text":"Buy 1 get 1 40% off","regular":16.99,"size_text":"2 ea","reason":"has regular but no unit basis - a row written before the half field"}' +
    ']}'
  Set-Content (Join-Path $fxMp 'flagged-2026-09-23.json') $mpJson -Encoding UTF8
  $ff = Get-Item (Join-Path $fxMp 'flagged-2026-09-23.json')
  $flagParts = @(); $flagKeys = @(); $mbBandHalf = $null
  . ([scriptblock]::Create($mpM.Groups[1].Value))
  if (($flagKeys -contains 'MULTIBUY|Family Fare|bar-soap') -and ($flagKeys -contains 'MULTIBUY|Family Fare|deodorant')) {
    Ok 'multibuy pager: MUST FIRE - the unresolved Dove Cleansing Bar pages, and a legacy row with no half still pages (fail closed)'
  } else { Bad ('multibuy pager: an unresolved or legacy multibuy row went quiet. keys=' + ($flagKeys -join ' ; ')) }
  if (($flagKeys -notcontains 'MULTIBUY|Family Fare|hand-soap') -and $mbBandHalf -eq 1 -and $flagKeys.Count -eq 2) {
    Ok 'multibuy pager: MUST NOT FIRE - the complete-basis Dove Hand Wash (a real 0.3993/fl oz premium sale) is counted for band review and NOT paged as a price flag'
  } else { Bad ('multibuy pager: the complete-basis half still pages or was not counted (bandHalf=' + $mbBandHalf + ', keys=' + ($flagKeys -join ' ; ') + ')') }
  Remove-Item $fxMp -Recurse -Force -ErrorAction SilentlyContinue
}
} # u146-multibuy-pager-pages-only-the-unresolved-half

# ---- a week-over-week move the PREVIOUS BOARD explains is recorded, not paged; a defect still pages --------
# (2026-09-21, queue 2026-09-19-fccb69, grocery/triage-plans/plan-2026-09-21-6.json). Every row below is FROZEN
# from the real boards and price-history of the day it names, never regenerated from a live board. The four
# MUST FIRE cells are the defects this flag found inside the 30-day window; the laundry case is the one that
# decided the design: its only trace was a SALE row leaving the cell, so "a sale ending" cannot be an
# explanation. The cent sign of the Hy-Vee ad line is written 'c' to keep this file ASCII.
if (Use-Unit 'u144-a-move-the-previous-board-explains-is-quiet') {
$fxE = NewFxDir 'sanity-explain'
function ERun([string]$cur, [string]$prev, [string]$curJson, [string]$prevJson, [string]$histJson) {
  Get-ChildItem $fxE -Filter '*.json' | Remove-Item -Force
  Set-Content (Join-Path $fxE ('comparison-' + $cur + '.json')) $curJson -Encoding UTF8
  if ($prevJson) { Set-Content (Join-Path $fxE ('comparison-' + $prev + '.json')) $prevJson -Encoding UTF8 }
  Set-Content (Join-Path $fxE 'price-history.json') $histJson -Encoding UTF8
  $null = RunPS 'sanity-check.ps1' @('-CompareFile', (Join-Path $fxE ('comparison-' + $cur + '.json')), '-OutDir', $fxE, '-HistoryFile', (Join-Path $fxE 'price-history.json'))
  # ASSIGN, THEN WRAP: Read-JsonFile hands a JSON array back as ONE object under PS 5.1, so @(Read-JsonFile ...) is a
  # one-element array holding the whole array, and every type then reads as one space-joined string.
  $d = Read-JsonFile (Join-Path $fxE ('guards-' + $cur + '.json'))
  return , @($d)
}
function ETypes($j) { return , @(@($j) | ForEach-Object { [string]$_.type }) }
$eQuiet = @('outlier-verified', 'unit-changed', 'wow-explained')
# MUST FIRE 1 - laundry pods, 2026-09-07 (queue 2026-09-07-05e4c3, confirmed): Hy-Vee's fuel-saver ad line held the
# crown at $0.10 until its ad ended 2026-09-06. Sam's is the SAME item at the SAME price, so only the sale clause keeps it.
# store-subset-ok: frozen board rows from a real incident; the sanity-explain region compares stores generically and never branches on which store (queue 2026-09-22-175249)
$eJ = ERun '2026-09-07' '2026-09-06' '{"week_of":"2026-09-07","comparison":[{"commodity":"Laundry Detergent Pods","id":"laundry-pods","unit":"each","cheapest_store":"Sam''s Club","cheapest_price":0.1498,"stores":[{"store":"Sam''s Club","per_unit":0.1498,"type":"everyday","item":"Member''s Mark Laundry Detergent Power Pacs, Blooming Breeze, 130 ct.","native_unit_price":0.15,"native_unit":"each"},{"store":"Walmart","per_unit":0.1795,"type":"everyday","item":"Great Value Ultimate Fresh Laundry Pacs, Original Clean, 60 Count"},{"store":"Aldi","per_unit":0.2131,"type":"everyday","item":"Arm Hammer Plus Oxiclean With Odor Blasters Laundry Detergent 5 IN 1 Power Paks 42ct Packaging May Vary 42 1n"},{"store":"Baker''s","per_unit":0.2496,"type":"everyday","item":"ARM & HAMMER Clean Burst Laundry Detergent 5-in-1 Power Paks"}]}]}' '{"week_of":"2026-09-06","comparison":[{"commodity":"Laundry Detergent Pods","id":"laundry-pods","unit":"each","cheapest_store":"Hy-Vee","cheapest_price":0.1,"stores":[{"store":"Hy-Vee","per_unit":0.1,"type":"sale","item":"Gain Flings, EARN 10c OFF PER GALLON, -3.00 off with manufacturer''s digital coupon, $12.94","ad_to":"2026-09-06"},{"store":"Sam''s Club","per_unit":0.1498,"type":"everyday","item":"Member''s Mark Laundry Detergent Power Pacs, Blooming Breeze, 130 ct.","native_unit_price":0.15,"native_unit":"each"},{"store":"Walmart","per_unit":0.1795,"type":"everyday","item":"Great Value Ultimate Fresh Laundry Pacs, Original Clean, 60 Count"},{"store":"Aldi","per_unit":0.2131,"type":"everyday","item":"Arm Hammer Plus Oxiclean With Odor Blasters Laundry Detergent 5 IN 1 Power Paks 42ct Packaging May Vary 42 1n"}]}]}' '{"commodities":[{"id":"laundry-pods","history":[{"week_of":"2026-09-06","cheapest_price":0.1,"cheapest_store":"Hy-Vee","per_store":{"Hy-Vee":0.1,"Sam''s Club":0.1498,"Walmart":0.1795,"Aldi":0.2131,"Baker''s":0.2496}}]}]}'
$eW = @($eJ | Where-Object { [string]$_.type -eq 'wow' })
if ($eW.Count -eq 1 -and ((ETypes $eJ) -notcontains 'wow-explained') -and $eW[0].detail -match 'sale ending') { Ok 'sanity explain: MUST FIRE - laundry pods 2026-09-07: the fuel-saver SALE row leaving the cell still pages as wow, although the new cheapest is a standing price' }
else { Bad ('sanity explain: the 2026-09-07 laundry-pods defect went quiet or lost its reason (types=' + ((ETypes $eJ) -join ',') + ') - a sale ending is being treated as an explanation, and it was the only trace of a live wrong ad price') }
# MUST FIRE 2 - Whole Coconut, 2026-09-10 (queue 2026-09-10-b91a0a, confirmed): a KIND snack bar took the crown at $1.33.
$eJ = ERun '2026-09-09' '2026-09-08' '{"week_of":"2026-09-09","comparison":[{"commodity":"Whole Coconut","id":"coconut","unit":"each","cheapest_store":"Fareway","cheapest_price":1.33,"stores":[{"store":"Fareway","per_unit":1.33,"item":"KIND Almond & Coconut"},{"store":"Baker''s","per_unit":3.49,"type":"everyday","item":"Fresh Brown Coconuts"}]}]}' '{"week_of":"2026-09-08","comparison":[{"commodity":"Whole Coconut","id":"coconut","unit":"each","cheapest_store":"Baker''s","cheapest_price":3.49,"stores":[{"store":"Baker''s","per_unit":3.49,"type":"everyday","item":"Fresh Brown Coconuts"},{"store":"Fareway","per_unit":3.99,"type":"everyday","item":"Coconut"}]}]}' '{"commodities":[{"id":"coconut","history":[{"week_of":"2026-09-08","cheapest_price":3.49,"cheapest_store":"Baker''s","unit":"each","per_store":{"Baker''s":3.49,"Fareway":3.99}}]}]}'
$eT = ETypes $eJ
if (($eT -contains 'wow') -and ($eT -contains 'outlier') -and @($eJ | Where-Object { [string]$_.type -eq 'wow' })[0].detail -match 'NEW price at the cheapest store') { Ok 'sanity explain: MUST FIRE - Whole Coconut 2026-09-10: the KIND bar at $1.33 pages as wow (a NEW price at the cheapest store) AND as outlier' }
else { Bad ('sanity explain: the 2026-09-10 coconut defect did not page on both arms (types=' + ($eT -join ',') + ')') }
# MUST FIRE 3 - Shrimp, 2026-09-11 (queue 2026-09-11-3b246c, confirmed): a chowder at exactly $3.49/lb replaced the EZ Peel.
# store-subset-ok: frozen board rows from a real incident; the sanity-explain region compares stores generically and never branches on which store (queue 2026-09-22-175249)
$eJ = ERun '2026-09-09' '2026-09-08' '{"week_of":"2026-09-09","comparison":[{"commodity":"Shrimp (frozen, raw)","id":"shrimp","unit":"lb","cheapest_store":"Sam''s Club","cheapest_price":3.49,"stores":[{"store":"Sam''s Club","per_unit":3.49,"type":"everyday","item":"Member''s Mark Shrimp and Corn Chowder, 24 oz., 2 pk."},{"store":"Walmart","per_unit":6.76,"type":"everyday","item":"Great Value Frozen Raw Small Peeled & Deveined, Tail-off Shrimp, 12 oz Bag (60-80 Count per lb)"},{"store":"Aldi","per_unit":7.36,"type":"everyday","item":"Fusia Shrimp Avocado Roll Sushi 11.5 OZ"}]}]}' '{"week_of":"2026-09-08","comparison":[{"commodity":"Shrimp (frozen, raw)","id":"shrimp","unit":"lb","cheapest_store":"Sam''s Club","cheapest_price":5.82,"stores":[{"store":"Sam''s Club","per_unit":5.82,"type":"everyday","item":"Member''s Mark Farm Raised Jumbo Raw EZ Peel Shrimp, Frozen, 21-30 ct. per pound, 3 lbs.","native_unit_price":5.82,"native_unit":"lb"},{"store":"Walmart","per_unit":6.76,"type":"everyday","item":"Great Value Frozen Raw Small Peeled & Deveined, Tail-off Shrimp, 12 oz Bag (60-80 Count per lb)"},{"store":"Aldi","per_unit":7.36,"type":"everyday","item":"Fusia Shrimp Avocado Roll Sushi 11.5 OZ"}]}]}' '{"commodities":[{"id":"shrimp","history":[{"week_of":"2026-09-08","cheapest_price":5.82,"cheapest_store":"Sam''s Club","unit":"lb","per_store":{"Sam''s Club":5.82,"Walmart":6.76,"Aldi":7.36}}]}]}'
$eT = ETypes $eJ
if (($eT -contains 'wow') -and ($eT -contains 'outlier') -and ($eT -notcontains 'wow-explained')) { Ok 'sanity explain: MUST FIRE - Shrimp 2026-09-11: the chowder replacing the EZ Peel at the same store pages as wow AND as outlier' }
else { Bad ('sanity explain: the 2026-09-11 shrimp defect did not page on both arms (types=' + ($eT -join ',') + ')') }
# MUST FIRE 4 - Bouillon, 2026-09-05 (queue 2026-09-05-521f1c): a stale Walmart row at $0.0813 took the crown from Sam's.
# Walmart was on the previous board with a different item at $0.1681, so the new cheapest is a NEW price and pages - even
# though the store HAD carried $0.0813 earlier in the window (the 2026-07-15 entry has the shape of the real history,
# measured inside the 90-day window; its week is illustrative). A test on "any earlier price" would have explained it away.
# store-subset-ok: frozen board rows from a real incident; the sanity-explain region compares stores generically and never branches on which store (queue 2026-09-22-175249)
$eJ = ERun '2026-09-02' '2026-08-31' '{"week_of":"2026-09-02","comparison":[{"commodity":"Bouillon (cubes / granules / base)","id":"bouillon","unit":"oz","cheapest_store":"Walmart","cheapest_price":0.0813,"stores":[{"store":"Walmart","per_unit":0.0813,"type":"everyday","item":"Knorr Select bouillon, the 52-day-old batch row whose name says 1.82 pounds"},{"store":"Sam''s Club","per_unit":0.1477,"type":"everyday","item":"Knorr Granulated Chicken Bouillon, 40.5 oz."},{"store":"Baker''s","per_unit":0.3814,"type":"everyday","item":"Knorr Chicken Cube Bouillon"}]}]}' '{"week_of":"2026-08-31","comparison":[{"commodity":"Bouillon (cubes / granules / base)","id":"bouillon","unit":"oz","cheapest_store":"Sam''s Club","cheapest_price":0.1477,"stores":[{"store":"Sam''s Club","per_unit":0.1477,"type":"everyday","item":"Knorr Granulated Chicken Bouillon, 40.5 oz."},{"store":"Walmart","per_unit":0.1681,"type":"everyday","item":"Knorr Granulated Beef Bouillon Ground Seasoning, 2.0 lb Jar"},{"store":"Baker''s","per_unit":0.3814,"type":"everyday","item":"Knorr Chicken Cube Bouillon"}]}]}' '{"commodities":[{"id":"bouillon","history":[{"week_of":"2026-07-15","cheapest_price":0.0813,"cheapest_store":"Walmart","unit":"oz","per_store":{"Walmart":0.0813,"Sam''s Club":0.1477}},{"week_of":"2026-08-31","cheapest_price":0.1477,"cheapest_store":"Sam''s Club","unit":"oz","per_store":{"Sam''s Club":0.1477,"Walmart":0.1681,"Baker''s":0.3814}}]}]}'
$eT = ETypes $eJ
if (($eT -contains 'wow') -and ($eT -contains 'outlier') -and @($eJ | Where-Object { [string]$_.type -eq 'wow' })[0].detail -match 'NEW price at the cheapest store: Walmart .*\$0\.1681') { Ok 'sanity explain: MUST FIRE - Bouillon 2026-09-05: the stale $0.0813 Walmart row pages as wow (Walmart carried $0.1681 on the previous board) AND as outlier' }
else { Bad ('sanity explain: the 2026-09-05 bouillon defect went quiet or lost its reason (types=' + ($eT -join ',') + ')') }
# MUST FIRE 5 - the look-back path, synthetic and binary-exact: Store C is ABSENT from the previous board, carried 0.25 two
# versions ago and 0.5 LAST time, and comes back at 0.25. Only the LAST price counts, so an older price coming back pages.
$eJ = ERun '2026-09-21' '2026-09-20' '{"week_of":"2026-09-21","comparison":[{"commodity":"Lookback Case","id":"lookback-case","unit":"oz","cheapest_store":"Store C","cheapest_price":0.25,"stores":[{"store":"Store C","per_unit":0.25,"type":"everyday","item":"Item C"},{"store":"Store D","per_unit":0.5,"type":"everyday","item":"Item D"}]}]}' '{"week_of":"2026-09-20","comparison":[{"commodity":"Lookback Case","id":"lookback-case","unit":"oz","cheapest_store":"Store D","cheapest_price":0.5,"stores":[{"store":"Store D","per_unit":0.5,"type":"everyday","item":"Item D"}]}]}' '{"commodities":[{"id":"lookback-case","history":[{"week_of":"2026-09-13","cheapest_price":0.25,"cheapest_store":"Store C","unit":"oz","per_store":{"Store C":0.25,"Store D":0.5}},{"week_of":"2026-09-17","cheapest_price":0.5,"cheapest_store":"Store C","unit":"oz","per_store":{"Store C":0.5,"Store D":0.5}},{"week_of":"2026-09-20","cheapest_price":0.5,"cheapest_store":"Store D","unit":"oz","per_store":{"Store D":0.5}}]}]}'
$eW = @($eJ | Where-Object { [string]$_.type -eq 'wow' })
if ($eW.Count -eq 1 -and $eW[0].detail -match 'was last \$0\.5000') { Ok 'sanity explain: MUST FIRE - a store back at an OLDER price (0.25) than its last one (0.5) is a new price and pages' }
else { Bad ('sanity explain: an older price coming back was read as standing (types=' + ((ETypes $eJ) -join ',') + ')') }
# MUST NOT FIRE 1 - Adobo seasoning, 2026-09-17: Sam's (an EVERYDAY row) left the cell and Baker's took the crown at the
# $0.3113 it already carried. +134%, and nothing about any price changed.
# store-subset-ok: frozen board rows from a real incident; the sanity-explain region compares stores generically and never branches on which store (queue 2026-09-22-175249)
$eJ = ERun '2026-09-17' '2026-09-14' '{"week_of":"2026-09-17","comparison":[{"commodity":"Adobo seasoning","id":"adobo-seasoning","unit":"oz","cheapest_store":"Baker''s","cheapest_price":0.3113,"stores":[{"store":"Baker''s","per_unit":0.3113,"type":"everyday","item":"Goya Adobo All Purpose Seasoning"},{"store":"Family Fare","per_unit":0.3129,"type":"everyday","item":"Badia Adobo Seasoning With Pepper 7 Oz"}]}]}' '{"week_of":"2026-09-14","comparison":[{"commodity":"Adobo seasoning","id":"adobo-seasoning","unit":"oz","cheapest_store":"Sam''s Club","cheapest_price":0.1332,"stores":[{"store":"Sam''s Club","per_unit":0.1332,"type":"everyday","item":"Goya Adobo All-Purpose Seasoning with Pepper, 28 oz.","native_unit_price":0.13,"native_unit":"oz"},{"store":"Baker''s","per_unit":0.3113,"type":"everyday","item":"Goya Adobo All Purpose Seasoning"},{"store":"Family Fare","per_unit":0.3129,"type":"everyday","item":"Badia Adobo Seasoning With Pepper 7 Oz"},{"store":"Walmart","per_unit":0.3782,"type":"everyday","item":"Goya Adobo All Purpose Seasoning with Pepper, 28 oz Large","native_unit_price":0.378,"native_unit":"oz"}]}]}' '{"commodities":[{"id":"adobo-seasoning","history":[{"week_of":"2026-09-14","cheapest_price":0.1332,"cheapest_store":"Sam''s Club","unit":"oz","per_store":{"Sam''s Club":0.1332,"Baker''s":0.3113,"Family Fare":0.3129,"Walmart":0.3782}}]}]}'
$eT = ETypes $eJ
if (($eT -contains 'wow-explained') -and @($eT | Where-Object { $eQuiet -notcontains $_ }).Count -eq 0) { Ok 'sanity explain: MUST NOT FIRE - Adobo 2026-09-17: an everyday crown leaving the cell for a standing price is wow-explained and nothing pages' }
else { Bad ('sanity explain: the 2026-09-17 adobo store-churn move still pages (types=' + ($eT -join ',') + ')') }
# MUST NOT FIRE 2 - Caraway Seeds, 2026-09-21: Walmart came back at the $2.4222 it last carried (2026-09-14), undercutting a
# Family Fare price that did not move; the outlier it makes is reproduced by Walmart's own unit price. Nothing pages.
# store-subset-ok: frozen board rows from a real incident; the sanity-explain region compares stores generically and never branches on which store (queue 2026-09-22-175249)
$eJ = ERun '2026-09-21' '2026-09-20' '{"week_of":"2026-09-21","comparison":[{"commodity":"Caraway Seeds","id":"caraway-seeds","unit":"oz","cheapest_store":"Walmart","cheapest_price":2.4222,"stores":[{"store":"Walmart","per_unit":2.4222,"type":"everyday","item":"Great Value Organic Caraway Seed, 1.8 oz","native_unit_price":2.42,"native_unit":"oz"},{"store":"Family Fare","per_unit":5.1,"type":"everyday","item":"Mc Cormick Whole Caraway Seed 0.9 Oz"}]}]}' '{"week_of":"2026-09-20","comparison":[{"commodity":"Caraway Seeds","id":"caraway-seeds","unit":"oz","cheapest_store":"Family Fare","cheapest_price":5.1,"stores":[{"store":"Family Fare","per_unit":5.1,"type":"everyday","item":"Mc Cormick Whole Caraway Seed 0.9 Oz"}]}]}' '{"commodities":[{"id":"caraway-seeds","history":[{"week_of":"2026-09-14","cheapest_price":2.4222,"cheapest_store":"Walmart","unit":"oz","per_store":{"Walmart":2.4222,"Fareway":3.3222,"Hy-Vee":4.3148,"Family Fare":5.1}},{"week_of":"2026-09-17","cheapest_price":5.1,"cheapest_store":"Family Fare","unit":"oz","per_store":{"Family Fare":5.1}},{"week_of":"2026-09-20","cheapest_price":5.1,"cheapest_store":"Family Fare","unit":"oz","per_store":{"Family Fare":5.1}}]}]}'
$eT = ETypes $eJ
if (($eT -contains 'wow-explained') -and ($eT -contains 'outlier-verified') -and @($eT | Where-Object { $eQuiet -notcontains $_ }).Count -eq 0) { Ok 'sanity explain: MUST NOT FIRE - Caraway 2026-09-21: a store back at its last price plus a store-verified outlier pages nothing' }
else { Bad ('sanity explain: the 2026-09-21 caraway return still pages (types=' + ($eT -join ',') + ')') }
# CLEAN TWIN - Apples, 2026-09-18 (queue 2026-09-18-61f76c, confirmed real): Aldi's SAME bag went $0.6633 -> $0.9633 on the
# shelf. Nothing on the board accounts for that, so it still pages, and it says why.
# store-subset-ok: frozen board rows from a real incident; the sanity-explain region compares stores generically and never branches on which store (queue 2026-09-22-175249)
$eJ = ERun '2026-09-17' '2026-09-14' '{"week_of":"2026-09-17","comparison":[{"commodity":"Apples","id":"apples","unit":"lb","cheapest_store":"Aldi","cheapest_price":0.9633,"stores":[{"store":"Aldi","per_unit":0.9633,"type":"everyday","item":"Gala Apple Bag 3 Lbs"},{"store":"Baker''s","per_unit":1,"type":"everyday","item":"Kroger Gala Apples 5 Pound Bag"},{"store":"Walmart","per_unit":1.08,"type":"sale","item":"Fresh Gala Apples, 3 lb Bag","ad_to":"2026-09-30","native_unit_price":1.08,"native_unit":"lb"}]}]}' '{"week_of":"2026-09-14","comparison":[{"commodity":"Apples","id":"apples","unit":"lb","cheapest_store":"Aldi","cheapest_price":0.6633,"stores":[{"store":"Aldi","per_unit":0.6633,"type":"everyday","item":"Gala Apple Bag 3 Lbs"},{"store":"Baker''s","per_unit":1,"type":"everyday","item":"Kroger Pink Lady Apples 5 Pound Bag BIG DEAL!"},{"store":"Walmart","per_unit":1.08,"type":"everyday","item":"Fresh Gala Apples, 3 lb Bag","native_unit_price":1.08,"native_unit":"lb"}]}]}' '{"commodities":[{"id":"apples","history":[{"week_of":"2026-09-14","cheapest_price":0.6633,"cheapest_store":"Aldi","unit":"lb","per_store":{"Aldi":0.6633,"Baker''s":1,"Walmart":1.08}}]}]}'
$eW = @($eJ | Where-Object { [string]$_.type -eq 'wow' })
if ($eW.Count -eq 1 -and $eW[0].detail -match 'unexplained: a NEW price at the cheapest store: Aldi ''Gala Apple Bag 3 Lbs''') { Ok 'sanity explain: CLEAN TWIN - Apples 2026-09-18: a same-item shelf move still pages as wow, and the flag names the store and item that moved' }
else { Bad ('sanity explain: an unexplained same-item move lost its page or its reason (types=' + ((ETypes $eJ) -join ',') + ')') }
# THE BAR: "standing" is the same per-unit to 4 dp. AT the bar (0.3125 = 0.3125, binary-exact) the move is explained; ONE
# STEP PAST (0.3126, one unit of the 4 dp resolution) it is a new price and pages.
$eBarPrev = '{"week_of":"2026-09-20","comparison":[{"commodity":"Bar Case","id":"bar-case","unit":"oz","cheapest_store":"Store A","cheapest_price":0.125,"stores":[{"store":"Store A","per_unit":0.125,"type":"everyday","item":"Item A"},{"store":"Store B","per_unit":0.3125,"type":"everyday","item":"Item B"}]}]}'
$eBarHist = '{"commodities":[{"id":"bar-case","history":[{"week_of":"2026-09-20","cheapest_price":0.125,"cheapest_store":"Store A","unit":"oz","per_store":{"Store A":0.125,"Store B":0.3125}}]}]}'
$eT = ETypes (ERun '2026-09-21' '2026-09-20' '{"week_of":"2026-09-21","comparison":[{"commodity":"Bar Case","id":"bar-case","unit":"oz","cheapest_store":"Store B","cheapest_price":0.3125,"stores":[{"store":"Store B","per_unit":0.3125,"type":"everyday","item":"Item B"}]}]}' $eBarPrev $eBarHist)
if (($eT -join ',') -eq 'wow-explained') { Ok 'sanity explain: AT THE BAR - the new cheapest at exactly the per-unit it carried (0.3125) is standing, so the move is wow-explained' }
else { Bad ('sanity explain: at the bar (identical per-unit) the move was not explained (types=' + ($eT -join ',') + ')') }
$eT = ETypes (ERun '2026-09-21' '2026-09-20' '{"week_of":"2026-09-21","comparison":[{"commodity":"Bar Case","id":"bar-case","unit":"oz","cheapest_store":"Store B","cheapest_price":0.3126,"stores":[{"store":"Store B","per_unit":0.3126,"type":"everyday","item":"Item B"}]}]}' $eBarPrev $eBarHist)
if (($eT -join ',') -eq 'wow') { Ok 'sanity explain: ONE STEP PAST THE BAR - 0.3126 against a carried 0.3125 is a new price and pages as wow' }
else { Bad ('sanity explain: one step past the bar (0.3126 vs 0.3125) did not page (types=' + ($eT -join ',') + ')') }
Remove-Item $fxE -Recurse -Force -ErrorAction SilentlyContinue
# and the PAGER half: the quiet allowlist in check-ad-cycles names wow-explained, and a plain wow still pages beside it.
$epM = [regex]::Match(((Expand-SelfTestPointers -Text ((Expand-SelfTestPointers -Text ([IO.File]::ReadAllText((Join-Path $root 'check-ad-cycles.ps1'))) -Path (Join-Path $root 'check-ad-cycles.ps1'))) -Path (Join-Path $root 'check-ad-cycles.ps1'))), '(?s)<<SANITY-PAGER-BEGIN>>[^\r\n]*\r?\n(.*?)\r?\n[ \t]*# <<SANITY-PAGER-END>>')
if (-not $epM.Success) { Bad 'sanity explain: SANITY-PAGER region is GONE from check-ad-cycles.ps1 - the wow-explained quiet type is untested' }
else {
  $fxEp = NewFxDir 'sanity-explain-pager'
  Set-Content (Join-Path $fxEp 'guards-2026-09-21.json') '[{"commodity":"Adobo seasoning","type":"wow-explained","detail":"explained"},{"commodity":"Apples","type":"wow","detail":"unexplained"}]' -Encoding UTF8
  $gf = Get-Item (Join-Path $fxEp 'guards-2026-09-21.json')
  $flagParts = @(); $flagKeys = @()
  . ([scriptblock]::Create($epM.Groups[1].Value))
  if ($sanityQuiet -eq 1 -and ($flagKeys -notcontains 'SANITY|Adobo seasoning|wow-explained') -and ($flagKeys -contains 'SANITY|Apples|wow')) { Ok 'sanity explain: MUST NOT FIRE - the pager counts a wow-explained flag as quiet and still pages the unexplained wow beside it' }
  else { Bad ('sanity explain: pager quiet list is wrong for wow-explained (quiet=' + $sanityQuiet + ', keys=' + ($flagKeys -join ' ; ') + ')') }
  Remove-Item $fxEp -Recurse -Force -ErrorAction SilentlyContinue
}
} # u144-a-move-the-previous-board-explains-is-quiet

# ---------------------------------------------------------------- (k3) THIS HARNESS'S OWN VERDICT
# 2026-09-04, queue 2026-09-04-0b63d3. On 2026-09-04 this suite ran 601 fixtures, every one fired, and it
# exited 2 - which check-ad-cycles reads as "a GUARD has gone blind ... any quiet report from that guard is
# unproven - including a clean board". The single Bad() was a STALE COPY of a prompt in ops\prompt-backup.
# This file had grown from a fixture-replay harness into the estate's general self-check but kept one tally
# and one exit code, so ops housekeeping and a watcher losing its sight became the same page - and the page
# recommended a remedy (-Sync) that writes live user-scope prompt files and mirrors a personal scheduled
# task into a public repo.
# Both halves of the fix are asserted here: the VERDICT function in this file, and the DECISION region in
# check-ad-cycles that reads it. The region is extracted and run, never transcribed - a copy of a decision
# is a decision that can drift.
if (Use-Unit 'u071-k3-this-harness-s-own-verdict') {
$av = Get-AuditorsVerdict 1 1 601 0
if ($av.rc -eq 2 -and $av.line -match 'gone blind') { Ok 'auditors verdict: MUST FIRE - a failed fixture is rc 2 and says "gone blind", even with hygiene findings alongside it' }
else { Bad ('auditors verdict: a failed fixture did not produce rc 2 + "gone blind" (rc=' + $av.rc + ', line=' + $av.line + ') - a blind watcher would page as ordinary housekeeping') }
$av = Get-AuditorsVerdict 0 1 601 0
if ($av.rc -eq 1 -and $av.line -notmatch 'gone blind') { Ok 'auditors verdict: CLEAN TWIN - hygiene alone is rc 1 and never claims a watcher went blind' }
else { Bad ('auditors verdict: a hygiene-only run produced rc=' + $av.rc + ' / ' + $av.line + ' - the 2026-09-04 false BLIND page is back') }
$av = Get-AuditorsVerdict 0 0 601 0
if ($av.rc -eq 0) { Ok 'auditors verdict: a clean run is still rc 0' }
else { Bad ('auditors verdict: a clean run returned rc ' + $av.rc) }
$av = Get-AuditorsVerdict 3 0 601 2
if ($av.rc -eq 2 -and $av.line -match 'SKIPPED') { Ok 'auditors verdict: skips are still reported in the FAIL line (a case that could not run is not a pass)' }
else { Bad 'auditors verdict: the skip note vanished from the FAIL line' }
# The tier is only worth having if the HYGIENE function actually exists and increments its own tally.
if ((Get-Command Hygiene -ErrorAction SilentlyContinue) -and (Get-Command Get-AuditorsVerdict -ErrorAction SilentlyContinue)) { Ok 'auditors verdict: the HYGIENE tier and the verdict function are both present in this harness' }
else { Bad 'auditors verdict: the HYGIENE tier is missing - every ops-hygiene finding is a BLIND page again' }
# ---- the THIRD tier: a LIVE-TWIN red is the watcher WORKING (2026-09-20, queue 2026-09-19-ae9df2) ----
# MUST FIRE: a live red with no fixture red is rc 4, and its line carries neither of the two words a reader
# and a grep sort the day's trust ordering on.
$av = Get-AuditorsVerdict 0 0 741 0 1
if ($av.rc -eq 4 -and $av.line -match 'LIVE' -and $av.line -notmatch 'gone blind' -and $av.line -notmatch 'unproven') {
  Ok 'auditors verdict: MUST FIRE - failed=0 live=1 is rc 4, says LIVE, and says neither "gone blind" nor "unproven"'
} else { Bad ('auditors verdict: a live-board red did not produce rc 4 + LIVE wording (rc=' + $av.rc + ', line=' + $av.line + ') - the 09-19 inverted page is back') }
# MUST FIRE: a blind watcher OUTRANKS a live red. If a fixture stopped firing, the live verdict itself is
# unprovable, so the loud page wins.
$av = Get-AuditorsVerdict 1 0 741 0 1
if ($av.rc -eq 2 -and $av.line -match 'gone blind') { Ok 'auditors verdict: MUST FIRE - failed=1 live=1 is still rc 2 "gone blind" (a blind watcher outranks a live red)' }
else { Bad ('auditors verdict: a blind fixture alongside a live red returned rc ' + $av.rc + ' - the loud page lost to the quiet one') }
# MUST FIRE, THE FOUNDING RUN REPLAYED: the 2026-09-19 16:59 shape was 742 cases, ONE live-twin red
# (almond-butter | Baker's | 'Nutty Blends Stage 2 Organic Bananas & Almond Butter Baby Food Pouch'), zero
# fixture reds. That run exited 2 and paged "a GUARD has gone blind". Under this verdict it is rc 4.
$av = Get-AuditorsVerdict 0 0 741 0 1
if ($av.rc -eq 4) { Ok 'auditors verdict: MUST FIRE - the 2026-09-19 742-case shape (1 live red, 0 fixture reds) is rc 4, not rc 2' }
else { Bad ('auditors verdict: the 09-19 founding shape still returns rc ' + $av.rc) }
# CLEAN TWIN: live>0 must not swallow hygiene, and a clean run is still rc 0 with no live tally.
$av = Get-AuditorsVerdict 0 1 741 0 1
if ($av.rc -eq 4 -and $av.line -match 'HYGIENE') { Ok 'auditors verdict: CLEAN TWIN - a live red alongside hygiene is rc 4 and still names the hygiene count' }
else { Bad ('auditors verdict: live+hygiene returned rc ' + $av.rc + ' / ' + $av.line) }
$av = Get-AuditorsVerdict 0 0 741 0 0
if ($av.rc -eq 0) { Ok 'auditors verdict: CLEAN TWIN - live=0 leaves the clean run at rc 0' }
else { Bad ('auditors verdict: live=0 no longer returns rc 0 (rc=' + $av.rc + ')') }
# The tier is only worth having if Live() exists and increments its OWN tally, not Bad's.
if (Get-Command Live -ErrorAction SilentlyContinue) {
  $liveBefore = $script:live; $failedBefore = $script:failed
  # THE PROBE'S OUTPUT IS CAPTURED, NOT PRINTED. Live() writes a '  LIVE-RED  ' line, and
  # ops\prepush-test-auditors.ps1 reads those lines as failing lines - so a fixture that let one reach
  # stdout would make every push read "exit 0 with 1 failing line" and refuse as COULD NOT EVALUATE.
  # Assigning the call captures the success stream; the tally still moves, which is what is under test.
  $liveProbeOut = Live 'probe - the Live() tally being exercised by its own fixture, not a real finding'
  if ($script:live -eq ($liveBefore + 1) -and $script:failed -eq $failedBefore -and ([string]$liveProbeOut) -match 'LIVE-RED') { Ok 'auditors verdict: Live() increments the live tally, leaves the failed tally alone, and writes a LIVE-RED line' }
  else { Bad 'auditors verdict: Live() moved the wrong tally - a live red would page as a blind watcher again' }
  $script:live = $liveBefore   # the probe above is a fixture, not a finding: do not let it change this run's verdict
} else { Bad 'auditors verdict: the LIVE-RED tier is missing - every live-board red is a BLIND page again' }
} # u071-k3-this-harness-s-own-verdict
# ---- the OTHER half: check-ad-cycles must route the two tiers differently ----
if (Use-Unit 'u072-the-other-half-check-ad-cycles-must') {
$wdSrc = (Expand-SelfTestPointers -Text ((Expand-SelfTestPointers -Text ([IO.File]::ReadAllText((Join-Path $root 'check-ad-cycles.ps1'))) -Path (Join-Path $root 'check-ad-cycles.ps1'))) -Path (Join-Path $root 'check-ad-cycles.ps1'))
$wdM = [regex]::Match($wdSrc, '(?s)<<WATCHERS-DECISION-BEGIN>>[^\r\n]*\r?\n(.*?)\r?\n[ \t]*# <<WATCHERS-DECISION-END>>')
if (-not $wdM.Success) {
  Bad 'WATCHERS-DECISION region is GONE from check-ad-cycles.ps1 - this check EXAMINED NOTHING, the two-tier routing is untested'
} else {
  $WD = $wdM.Groups[1].Value
  function WdRun([int]$rc) {
    $taRc = $rc
    $taKind = ''; $taSubject = ''; $taLog = ''; $taSummary = ''; $taFileTag = ''; $taLookFor = ''; $taHeader = ''
    . ([scriptblock]::Create($WD))
    return @{ kind = $taKind; subject = $taSubject; summary = $taSummary; fileTag = $taFileTag; header = $taHeader; lookFor = $taLookFor }
  }
  # MUST FIRE: rc 2 keeps the existing page, word for word. Every reader and the dated evidence-file
  # convention depend on this subject and this file name.
  $w = WdRun 2
  if ($w.subject -eq 'Grocery: a GUARD has gone blind (test-auditors failed)' -and $w.header -match 'unproven' -and $w.fileTag -eq 'test-auditors-fail' -and $w.summary -match '^WATCHERS') {
    Ok 'watchers routing: MUST FIRE - rc 2 still selects the blind-watcher subject, the "unproven" body and test-auditors-fail-<date>.txt'
  } else { Bad ('watchers routing: rc 2 no longer selects the blind page (' + $w.subject + ' / ' + $w.fileTag + ')') }
  # MUST FIRE: FAIL CLOSED. A crash, a throw, an Invoke-Bounded timeout - any rc this code does not know -
  # takes the blind path. The new tier must not be able to swallow an unknown verdict.
  # 4 LEAVES THIS LIST because it is now a KNOWN verdict (the LIVE-RED tier, 2026-09-20). 5 replaces it so
  # the loop still holds a value ONE PAST the known set - the at-the-bar / step-past rule, backlog I196.
  foreach ($odd in @(3, 5, 124, 255, -1)) {
    $w = WdRun $odd
    if ($w.subject -eq 'Grocery: a GUARD has gone blind (test-auditors failed)' -and $w.header -match 'unproven') {
      Ok ("watchers routing: MUST FIRE - an unrecognised rc $odd fails CLOSED to the blind page")
    } else { Bad ("watchers routing: rc $odd did NOT take the blind path - an unknown verdict from the harness that proves the guards was treated as benign") }
  }
  # CLEAN TWIN: rc 1 is routed, not silenced. Its own subject, its own evidence file, and a body that
  # claims neither that a watcher is blind nor that the board is unproven.
  $w = WdRun 1
  $twinOk = ($w.subject -eq 'Grocery: test-auditors hygiene finding(s) - watchers intact') -and
            ($w.fileTag -eq 'test-auditors-hygiene') -and
            ($w.header -notmatch 'unproven') -and ($w.header -notmatch 'gone blind') -and
            ($w.summary -match '^HYGIENE') -and ($w.lookFor -eq 'HYGIENE') -and
            ($w.subject -ne '')
  if ($twinOk) { Ok 'watchers routing: CLEAN TWIN - rc 1 pages its OWN subject to out\test-auditors-hygiene-<date>.txt, and the body says neither "unproven" nor "gone blind"' }
  else { Bad ('watchers routing: the hygiene tier is wrong (subject=' + $w.subject + ', file=' + $w.fileTag + ', summary=' + $w.summary + ') - a hygiene finding must be SENT, just not as a blind-guard page') }
  # A HYGIENE RUN MUST STILL SEND. Silencing is the opposite failure to over-paging, and it is the one a
  # new quiet tier invites: an empty subject would make Send-Alert a no-op and the finding would vanish.
  if ($w.subject -and $w.summary) { Ok 'watchers routing: a hygiene run still produces a subject and a summary line - it is routed, never silenced' }
  else { Bad 'watchers routing: the hygiene tier produced no subject or no summary - the finding would be silently dropped' }
  # MUST FIRE: rc 4 gets its OWN subject, its own evidence file and a body that says the watchers are intact
  # (2026-09-20, queue 2026-09-19-ae9df2). Same two forbidden words as the hygiene tier, for the same reason.
  $w = WdRun 4
  $liveOk = ($w.subject -eq 'Grocery: the LIVE board failed a watcher (watchers intact)') -and
            ($w.fileTag -eq 'test-auditors-live') -and
            ($w.header -match 'watchers intact|EVERY FIXTURE FIRED') -and
            ($w.header -notmatch 'unproven') -and ($w.header -notmatch 'gone blind') -and
            ($w.summary -match '^LIVE-RED') -and ($w.lookFor -eq 'LIVE-RED')
  if ($liveOk) { Ok 'watchers routing: MUST FIRE - rc 4 pages its OWN subject to out\test-auditors-live-<date>.txt, and the body says neither "unproven" nor "gone blind"' }
  else { Bad ('watchers routing: the LIVE-RED tier is wrong (subject=' + $w.subject + ', file=' + $w.fileTag + ', summary=' + $w.summary + ', lookFor=' + $w.lookFor + ') - a live-board red would page as a blind watcher, which inverts the day''s trust ordering') }
  # A LIVE RUN MUST STILL SEND. The new tier is the one a quiet failure mode invites; an empty subject makes
  # Send-Alert a no-op and the finding vanishes.
  if ($w.subject -and $w.summary) { Ok 'watchers routing: a live-board run still produces a subject and a summary line - it is routed, never silenced' }
  else { Bad 'watchers routing: the LIVE-RED tier produced no subject or no summary - the finding would be silently dropped' }
}
} # u072-the-other-half-check-ad-cycles-must

# ---------------------------------------------------------------- (l2) coverage-gap alert: ACTIONABLE only
# 2026-08-06 (triage plan-2026-08-06 item 2026-08-03-f4fb91). The coverage-gap alert counted and signatured
# the FULL gap set while the audit itself already separates a gap we can act on from one the ENGINE explains
# and refuses on purpose. Measured on the live files: 51 gaps / 7 actionable on 2026-08-05, 43 / 8 the next
# morning - so 84-86% of the set was permanent, correct refusals (BASIS-NULL: an each-priced commodity whose
# only rows at that store are cut trays; BAND-DROPPED: the sanity band eating "Orchid & Plum" moisturiser).
# Any churn in a quiet row changed the signature and re-paged the whole list, burying the real rows.
# Runs THE REAL REGION out of check-ad-cycles.ps1 against a FROZEN 5-gap file (2 actionable + 3 quiet),
# never a transcription and never regenerated from out\coverage-gaps.json - the bug is in which rows the
# region selects, and a fixture rebuilt from today's live file would encode whatever it does now.
if (Use-Unit 'u073-l2-coverage-gap-alert-actionable') {
$cgSrc = (Expand-SelfTestPointers -Text ([IO.File]::ReadAllText((Join-Path $root 'check-ad-cycles.ps1'))) -Path (Join-Path $root 'check-ad-cycles.ps1'))
$cgR = [regex]::Match($cgSrc, '(?s)<<COVERAGE-GAP-ALERT-BEGIN>>[^\r\n]*\r?\n(.*?)\r?\n[ \t]*# <<COVERAGE-GAP-ALERT-END>>')
if (-not $cgR.Success) {
  Bad 'the coverage-gap alert region is GONE from check-ad-cycles.ps1 - this check EXAMINED NOTHING, the actionable-only selection is untested'
} else {
  $CG_REGION = $cgR.Groups[1].Value
  # FROZEN fixture. The 2 actionable rows are the real 2026-08-05 shapes (a first-match-wins claim and a
  # rule-invisible store naming); the 3 quiet rows are the real permanent-refusal shapes.
  $cgFxGaps = @(
    [pscustomobject]@{ commodity = 'baby-formula'; store = "Sam's Club"; reason = 'CLAIMED-BY';     actionable = $true  }
    [pscustomobject]@{ commodity = 'acorn-squash'; store = 'Family Fare'; reason = 'RULE-INVISIBLE'; actionable = $true  }
    [pscustomobject]@{ commodity = 'lemons';       store = 'Walmart';     reason = 'BASIS-NULL';     actionable = $false }
    [pscustomobject]@{ commodity = 'plums';        store = 'Hy-Vee';      reason = 'BAND-DROPPED';   actionable = $false }
    [pscustomobject]@{ commodity = 'mangoes';      store = 'Aldi';        reason = 'BASIS-NULL';     actionable = $false }
  )
  function CgRunRegion($gaps) {
    # the region's own inputs, isolated: no mail can leave ($NoAlert), no sig file is read or written
    # (a temp $OutDir), and Log/summary are captured so the count in the operator line is assertable.
    $cg = [pscustomobject]@{ gap_count = @($gaps).Count; gaps = @($gaps) }
    $OutDir = NewFxDir 'cg-alert'
    $NoAlert = $true
    $asofS = '2026-08-06'
    $summary = @()
    $script:CG_LOG = @()
    function Log([string]$m) { $script:CG_LOG += $m }
    Invoke-Expression $CG_REGION
    return [pscustomobject]@{ sig = $cgSig; list = $cgList; act = @($cgAct).Count; all = @($cgAll).Count; summary = ($summary -join ' | '); log = ($script:CG_LOG -join ' | ') }
  }
  $cgFx = CgRunRegion $cgFxGaps
  # MUST FIRE: the paging set is EXACTLY the 2 actionable pairs.
  $cgQuiet = @('lemons @ Walmart', 'plums @ Hy-Vee', 'mangoes @ Aldi')
  $cgLeak = @($cgQuiet | Where-Object { $cgFx.list -like ('*' + $_ + '*') })
  if ($cgFx.act -eq 2 -and $cgFx.all -eq 5) { Ok 'coverage-gap alert: 5 frozen gaps select 2 actionable (3 engine-explained rows do not page)' }
  else { Bad ('coverage-gap alert: frozen 5-gap file selected ' + $cgFx.act + ' actionable of ' + $cgFx.all + ' - expected 2 of 5, so the alert is back on the full set') }
  if ($cgLeak.Count -eq 0) { Ok 'coverage-gap alert: no BASIS-NULL / BAND-DROPPED row reaches the alert body' }
  else { Bad ('coverage-gap alert: quiet row(s) leaked into the alert body: ' + ($cgLeak -join ' ; ')) }
  if ($cgFx.list -like '*baby-formula*' -and $cgFx.list -like '*acorn-squash*') { Ok 'coverage-gap alert: both actionable rows ARE named in the body' }
  else { Bad ('coverage-gap alert: an actionable row is missing from the body: [' + $cgFx.list + ']') }
  if ($cgFx.sig -eq "acorn-squash|Family Fare;baby-formula|Sam's Club") { Ok 'coverage-gap alert: the dedup signature is built from the actionable subset only' }
  else { Bad ('coverage-gap alert: signature is [' + $cgFx.sig + '] - it must be the sorted actionable pairs only, or quiet-row churn re-pages the list') }
  if ($cgFx.summary -match '2 actionable of 5') { Ok 'coverage-gap alert: the operator summary reports BOTH counts' }
  else { Bad ('coverage-gap alert: summary lost the both-counts line: [' + $cgFx.summary + ']') }
  # CLEAN TWIN 1: quiet-row CHURN must not change the signature (this is the whole point).
  $cgChurn = @($cgFxGaps | ForEach-Object { $_ })
  $cgChurn[2] = [pscustomobject]@{ commodity = 'watermelon'; store = 'Walmart'; reason = 'BASIS-NULL'; actionable = $false }
  $cgFx2 = CgRunRegion $cgChurn
  if ($cgFx2.sig -eq $cgFx.sig) { Ok 'coverage-gap alert: a quiet row changing does NOT change the signature (no re-page)' }
  else { Bad 'coverage-gap alert: swapping one engine-explained row changed the signature - the daily churn re-page is back' }
  # CLEAN TWIN 2: a real actionable row arriving DOES change it.
  $cgNew = @($cgFxGaps) + @([pscustomobject]@{ commodity = 'frozen-pizza'; store = 'Aldi'; reason = 'CLAIMED-BY'; actionable = $true })
  $cgFx3 = CgRunRegion $cgNew
  if ($cgFx3.sig -ne $cgFx.sig -and $cgFx3.act -eq 3) { Ok 'coverage-gap alert: a NEW actionable gap still changes the signature and pages' }
  else { Bad 'coverage-gap alert: a new actionable gap did not change the signature - the detector is deaf' }
  # CLEAN TWIN 3: FAIL OPEN. An old coverage-gaps.json with no actionable field must alert on everything
  # rather than silently on nothing - a detector that goes quiet because a field was renamed is the worst case.
  $cgOld = @($cgFxGaps | ForEach-Object { [pscustomobject]@{ commodity = $_.commodity; store = $_.store; reason = $_.reason } })
  $cgFx4 = CgRunRegion $cgOld
  if ($cgFx4.act -eq 5) { Ok 'coverage-gap alert: a gaps file with no actionable field FAILS OPEN (alerts on all 5)' }
  else { Bad ('coverage-gap alert: an actionable-less gaps file selected ' + $cgFx4.act + ' of 5 - the alert would go silent on a format change') }
}
} # u073-l2-coverage-gap-alert-actionable
