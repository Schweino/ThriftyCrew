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
[CmdletBinding()]
param(
  # SELECTIVE RUNS (2026-09-10, ruling R19). A file naming the units to SKIP, one id per line, written by
  # ops\prepush-test-auditors.ps1. The daily chain passes nothing, so every unit runs. See Use-Unit below.
  [string]$SkipUnitsFile = ''
)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

# PSChild - every `& powershell ... -File X ... 2>&1` in this suite, routed through the ONE safe
# redirect (native-lib.ps1). This file sets EAP='Stop', so each of those redirects was a latent
# landmine: the moment a child under test writes to stderr, the FIRST line terminates THIS SCRIPT
# and every remaining case goes unrun - the suite would report FEWER CASES, not a failure. That is
# the same shape that killed capture-run at 07:00 on 2026-08-23, and a test harness that can be
# silenced by the very thing it is testing is worth very little. $LASTEXITCODE still reads the
# child's real code through the helper (verified), so the `$rc = $LASTEXITCODE` lines are unchanged.
. (Join-Path $root 'native-lib.ps1')
. (Join-Path (Split-Path $root -Parent) 'lib\production-text.ps1')   # Get-TcProductionLines / Get-TcProductionText: a class sweep over script text reads only what runs in production, so a frozen -SelfTest fixture is not an offender (queue 2026-09-11-220094). No param() block, so it cannot reset ours.
. (Join-Path (Split-Path $root -Parent) 'lib\selftest-lib.ps1')   # Expand-SelfTestPointers: check-ad-cycles.ps1 is split into grocery\check-ad-cycles\ (2026-09-27, PLAN-split-giant-files D4), so every source-shape read takes the host with its pieces in place. No param() block.
. (Join-Path (Split-Path $root -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage. Must load BEFORE any use - the estate-wide sweep converted 25 call sites in this file and the presence check that adds this line matched a MENTION of json-io in a fixture string rather than a real dot-source, so the file was converted and left without it.
function PSChild {
  # TWO EXPLICIT PARAMETERS, NOT ONE CATCH-ALL. A single ValueFromRemainingArguments array
  # cannot carry `PSChild $script -SelfTest`: PowerShell tries to bind -SelfTest as a PARAMETER
  # NAME of PSChild and mangles it. With $Path taking position 0 and $Rest collecting the rest,
  # all four shapes used in this file work - no args, a switch, named values, and both mixed.
  # (Verified against a probe child before shipping: SelfTest/Name/N all arrive intact.)
  param([Parameter(Mandatory, Position = 0)][string]$Path,
        [Parameter(ValueFromRemainingArguments = $true)][object[]]$Rest)
  (Invoke-NativeScript $Path @Rest).Lines
}

$fix  = Join-Path $root 'regression-inputs\guard-fixtures'
# A FOURTH TALLY, AND IT IS THE POINT (2026-09-04, queue 2026-09-04-0b63d3).
# This harness grew from a fixture-replay suite into the estate's general self-check - gitignore coverage,
# script census, orphan wiring, prompt backups - but kept ONE Bad() tally and ONE exit code, and
# check-ad-cycles reads that single bit into the strongest sentence the estate has: "any quiet report from
# that guard is unproven - including a clean board". On 2026-09-04 that sentence was printed because a COPY
# of a prompt in ops\prompt-backup was stale. 601 fixtures fired; not one watcher had gone blind. The page
# also pointed the reader at a remedy (-Sync) that writes live user-scope prompt files and would have pushed
# a personal flight-price watch into a public repo.
# A stale backup is ops hygiene. A fixture that stopped firing is a blind watcher. They are not the same
# verdict and must not share an exit code.
$pass = 0; $failed = 0; $skipped = 0; $hygiene = 0; $live = 0

# EVERY SCRATCH PATH THIS HARNESS MAKES IS REGISTERED AND SWEPT, and the sweep is a `finally`.
#
# MEASURED 2026-08-26. Cleaning up was a thing each fixture had to REMEMBER, and most do - but the ones
# that forgot forgot on EVERY run, forever: cg-alert- (888 dirs), arrdock- (648 files), rf-ack- (421),
# ffc-selftest- (366), taudit-rep- (350). ~2,673 entries in %TEMP% from this one file. The sibling
# defect in meal-prep\pipeline\hunt_daemon_selftest.py had the same shape and the same cause, and was
# fixed the same way the same day: the allocator does the remembering, not the caller.
#
# Register-Fx is now the only way a scratch path is named here. A fixture that ALSO removes its own dir
# inline - most do, and should, so a 467-second run does not hold fifty of them open at once - is simply
# a no-op for the sweep.
#
# WHY A `finally` AND NOT `Register-EngineEvent PowerShell.Exiting`: the engine event was tried first and
# does NOT fire under `powershell.exe -File` on either exit path (probed both, 2026-08-26; the scratch dir
# survived both times). A try/finally around the body DOES run on all three ways out of this script -
# `exit 0`, `exit 2`, and an uncaught throw - and it preserves the exit code, which the completion
# contract below depends on. Probed the same day, all three, zero leftovers.
$script:FxPaths = New-Object System.Collections.ArrayList
function Register-Fx([string]$path) { [void]$script:FxPaths.Add($path); return $path }
function Sweep-FxPaths {
  foreach ($fx in $script:FxPaths) { Remove-Item -LiteralPath $fx -Recurse -Force -ErrorAction SilentlyContinue }
  $script:FxPaths.Clear()
}

try {
. (Join-Path $PSScriptRoot 'test-auditors\harness.ps1')
$script:MpPipeEarly = Join-Path (Split-Path $root -Parent) 'meal-prep\pipeline'
# Where early:spec-live writes its report instead of the tracked meal-prep\out\ (see the 2026-09-11 note above).
$script:SpecLiveReportDir = Register-Fx (Join-Path $env:TEMP ('taudit-speclive-' + [guid]::NewGuid().ToString('N').Substring(0, 8)))
if (-not $script:SkipUnits.Contains('u139-matcher-parity-wired-2026-08-21')) { Start-Early 'early:matcher-parity'  (Join-Path $root 'test-matcher-parity.ps1')                  @('-Sample', '400') }
if (-not $script:SkipUnits.Contains('u122-specs-prose-re-sync')) { Start-Early 'early:spec-live'       (Join-Path $script:MpPipeEarly 'audit-spec-contradictions.ps1') @('-Quiet', '-ReportDir', $script:SpecLiveReportDir) }
if (-not $script:SkipUnits.Contains('u128-the-precompiled-matcher')) { Start-Early 'early:match-lib'       (Join-Path $root 'test-match-lib.ps1')                       @('-Quiet') }
if (-not $script:SkipUnits.Contains('u079-n-6-script-census-is-every-file-in')) { Start-Early 'early:census-live'     (Join-Path $root 'audit-script-census.ps1')                  @() }
if (-not $script:SkipUnits.Contains('u049-the-inspect-fan-out')) { Start-Early 'early:fanout-selftest' (Join-Path $root 'fanout-lib.ps1')                           @('-SelfTest') }

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
$fixRep = Register-Fx (Join-Path $env:TEMP ('taudit-rep-' + [guid]::NewGuid().ToString('N').Substring(0, 8)))
$null = New-Item -ItemType Directory -Path $fixRep -Force
. (Join-Path $PSScriptRoot 'test-auditors\units-01.ps1')
. (Join-Path $PSScriptRoot 'test-auditors\sandbox.ps1')
. (Join-Path $PSScriptRoot 'test-auditors\units-02.ps1')
. (Join-Path $PSScriptRoot 'test-auditors\units-03.ps1')
. (Join-Path $PSScriptRoot 'test-auditors\units-04.ps1')
. (Join-Path $PSScriptRoot 'test-auditors\units-05.ps1')
. (Join-Path $PSScriptRoot 'test-auditors\units-06.ps1')
. (Join-Path $PSScriptRoot 'test-auditors\units-07.ps1')
. (Join-Path $PSScriptRoot 'test-auditors\units-08.ps1')

# ---------------------------------------------------------------- dead commodities (2026-08-30, queue 2026-08-22-51a5b6)
# A commodity whose every include requires a word GLOBAL_EXCLUDE blocks, with no relax_global to release
# it, can never match anything. chili-garlic-sauce and frozen-cauliflower-florets had been in that state
# since they were created, and it is invisible from any output: a rule that is switched off looks exactly
# like a commodity Omaha does not carry. The rule lives in dead-commodity-lib.ps1 so the fixtures below
# and the live arm run the SAME code.
. (Join-Path $PSScriptRoot 'dead-commodity-lib.ps1')

# MUST FIRE - the frozen PRE-FIX rulesets, verbatim as they stood before this triage round. Never
# regenerated from the live commodities.json: both commodities were REPAIRED today, so a fixture read
# from the tree would encode the fix and the case would pass by finding nothing.
if (Use-Unit 'u131-dead-commodities') {
$dcGexFx = @('\bsauce\b', '\bfrozen\b', '\bcanned\b', '\bmeal\b', '\bcake\b', '\bwater\b')
$dcCgs = [pscustomobject]@{ id = 'chili-garlic-sauce'
  include = @('\b(?:chili|chilli|chile)\s+garlic\s+sauce\b', '\bgarlic\s+(?:chili|chilli|chile)\s+sauce\b') }
$dcFcf = [pscustomobject]@{ id = 'frozen-cauliflower-florets'
  include = @('^(?=.*\bfrozen\b)(?=.*\bcauliflower\s+florets?\b).*$') }
$dcR = Test-CommodityIsDead $dcCgs $dcGexFx
if ($dcR -eq '\bsauce\b') { Ok 'dead-commodity: the pre-fix chili-garlic-sauce ruleset is named unmatchable - every include requires "sauce", GLOBAL_EXCLUDE blocks it, no relax_global released it' }
else { Bad ('dead-commodity: the pre-fix chili-garlic-sauce ruleset was NOT caught (verdict [' + $dcR + ']) - the check cannot see its own founding bug, so a quiet run proves nothing') }
$dcR = Test-CommodityIsDead $dcFcf $dcGexFx
if ($dcR -eq '\bfrozen\b') { Ok 'dead-commodity: the pre-fix frozen-cauliflower-florets ruleset is named unmatchable - its only include requires "frozen"' }
else { Bad ('dead-commodity: the pre-fix frozen-cauliflower-florets ruleset was NOT caught (verdict [' + $dcR + '])') }

# CLEAN TWIN - teriyaki-sauce, which has carried relax_global \bsauce\b since long before this round and
# prices six stores. If this ever fires, the check has become an argument for weakening a global exclude.
$dcTwin = [pscustomobject]@{ id = 'teriyaki-sauce'; include = @('teriyaki'); relax_global = @('\bsauce\b') }
if ((Test-CommodityIsDead $dcTwin $dcGexFx) -eq '') { Ok 'dead-commodity: teriyaki-sauce stays silent - a commodity that relaxes the token blocking it is alive' }
else { Bad 'dead-commodity: teriyaki-sauce was called dead, but it relaxes \bsauce\b and prices 6 stores - the check is too eager' }

# CLEAN TWINS FOR THE FALSE POSITIVES THE FIRST CUT ACTUALLY PRODUCED. These are not hypothetical: a
# substring version of this check reported all four as dead while they priced 4 to 7 stores each.
foreach ($dcFp in @(
    @{ id = 'pancake-mix';  inc = @('\bpancake\s+mix\b') },                       # 'cake' inside 'pancake'
    @{ id = 'watermelon';   inc = @('\bseedless\s+watermelon\b','\bwatermelon\b') }, # 'water' inside 'watermelon'
    @{ id = 'kale';         inc = @('\bkale\b') },                                # 'ale' inside 'kale'
    @{ id = 'rice-vinegar'; inc = @('\brice\s+(?:wine\s+)?vinegar\b') },          # OPTIONAL 'wine'
    @{ id = 'cooked-quinoa';inc = @('\b(?:cooked|microwave(?:able)?|frozen)\s+quinoa\b') })) {  # nested alternation
  $dcObj = [pscustomobject]@{ id = $dcFp.id; include = $dcFp.inc }
  $dcV = Test-CommodityIsDead $dcObj $dcGexFx
  if ($dcV -eq '') { Ok ('dead-commodity: ' + $dcFp.id + ' stays silent (the word is inside a longer word, an optional group or an alternation)') }
  else { Bad ('dead-commodity: ' + $dcFp.id + ' was called dead by [' + $dcV + '] - this is the over-eager shape that would argue for weakening a global exclude') }
}

# THE PRODUCTION ARM. Runs against the real ruleset every time this suite runs, and this suite runs daily
# from check-ad-cycles. A check that only ever sees its own fixtures runs never.
$dcGexLive = Get-EngineGlobalExclude $PSScriptRoot
if ($null -eq $dcGexLive) {
  Bad 'dead-commodity: could not read $GLOBAL_EXCLUDE out of compare-deals.ps1 - the live arm did not run, which is not the same as a clean result'
} else {
  # NOT @( ... | ConvertFrom-Json ): a top-level JSON array arrives as ONE pipeline object and @() around
  # it counts 1, so the sweep would examine a single commodity and report all clear. Measured here today.
  # LIVE-TWIN: THE PRODUCTION ARM (above) - the live ruleset is the subject.
  $dcRaw = Read-JsonFile (Join-Path $PSScriptRoot 'commodities.json')
  $dcComs = @($dcRaw)
  $dcDead = @(); $dcUndec = 0
  foreach ($dcC in $dcComs) {
    $dcH = Test-CommodityIsDead $dcC $dcGexLive
    if ($dcH -eq '?') { $dcUndec++ }
    elseif ($dcH) { $dcDead += ("{0} (blocked by {1})" -f $dcC.id, $dcH) }
  }
  if ($dcComs.Count -lt 100) {
    Bad ("dead-commodity: only $($dcComs.Count) commodit(y/ies) were examined - the live arm read almost nothing, so a clean result would mean nothing")
  } elseif ($dcDead.Count -eq 0) {
    Ok ("dead-commodity: all $($dcComs.Count) commodities can still match something past the $($dcGexLive.Count) global excludes ($dcUndec include set(s) too complex to reduce, reported rather than assumed clean)")
  } else {
    Bad ("dead-commodity: " + $dcDead.Count + " commodit(y/ies) can NEVER match - every include requires a word GLOBAL_EXCLUDE blocks and relax_global does not release: " + ($dcDead -join '; ') + ". Add that token to the commodity's relax_global, or narrow its includes. Do NOT remove the global exclude.")
  }
}
} # u131-dead-commodities

# ---------------------------------------------------------------- unit vocabulary (2026-08-30, queue 2026-08-22-51a5b6)
# The SIBLING of the dead-commodity class above, and the reason that round bounced. There the matcher can
# never keep a row; here the matcher keeps the row and Convert-ToUnit - a switch over six unit values with
# no default arm - returns $null for the commodity's declared unit, so no per-unit price is ever computed
# and the commodity holds no cell at any store, forever. Seven commodities were in that state: five spelled
# their unit 'fl_oz' against the engine's 'floz' (74 of 74 'floz' commodities had cells; 0 of 5 'fl_oz'
# did), aluminum-foil said 'sq_ft' and saffron said 'gram'. The rule lives in unit-vocabulary-lib.ps1 so
# the fixtures below and the live arm run the SAME code, and the vocabulary is read out of the engine's
# own switch rather than retyped here.
. (Join-Path $PSScriptRoot 'unit-vocabulary-lib.ps1')

# MUST FIRE - the frozen PRE-FIX unit values, verbatim as they stood before this round. Never regenerated
# from the live commodities.json: all seven were repaired today, so a fixture read from the tree would
# encode the fix and the case would pass by finding nothing.
if (Use-Unit 'u132-unit-vocabulary') {
$uvVocabFx = @('lb', 'oz', 'floz', 'gallon', 'each', 'dozen')
foreach ($uvFx in @(
    @{ id = 'coconut-aminos';    unit = 'fl_oz' },   # 5 commodities spelled it this way, 0 cells between them
    @{ id = 'aluminum-foil';     unit = 'sq_ft' },   # STILL sq_ft today, deliberately - see the exception cases below
    @{ id = 'saffron';           unit = 'gram'  })) {
  $uvV = Test-CommodityUnitIsPriceable ([pscustomobject]@{ id = $uvFx.id; unit = $uvFx.unit }) $uvVocabFx
  if ($uvV -eq $uvFx.unit) { Ok ("unit-vocabulary: the pre-fix " + $uvFx.id + " unit '" + $uvFx.unit + "' is named unpriceable - Convert-ToUnit has no arm for it, so every row it matches yields a null per-unit") }
  else { Bad ("unit-vocabulary: the pre-fix " + $uvFx.id + " unit '" + $uvFx.unit + "' was NOT caught (verdict [" + $uvV + "]) - the check cannot see its own founding bug, so a quiet run proves nothing") }
}
# and the same defect wearing a different spelling: no unit field at all
$uvV = Test-CommodityUnitIsPriceable ([pscustomobject]@{ id = 'no-unit-at-all' }) $uvVocabFx
if ($uvV -eq '(none)') { Ok 'unit-vocabulary: a commodity with no unit field at all is caught - Convert-ToUnit falls through on it identically' }
else { Bad ("unit-vocabulary: a commodity with no unit field was NOT caught (verdict [" + $uvV + "])") }

# CLEAN TWINS - every value the engine really does convert, including the corrected spellings of the
# seven. If any of these ever fires, the check has become an argument for editing the engine to suit it.
foreach ($uvOk in @('lb', 'oz', 'floz', 'gallon', 'each', 'dozen')) {
  if ((Test-CommodityUnitIsPriceable ([pscustomobject]@{ id = 'twin-' + $uvOk; unit = $uvOk }) $uvVocabFx) -eq '') { Ok ("unit-vocabulary: '" + $uvOk + "' stays silent - it is an arm of Convert-ToUnit's switch") }
  else { Bad ("unit-vocabulary: '" + $uvOk + "' was called unpriceable, but Convert-ToUnit converts it - the check is too eager") }
}
} # u132-unit-vocabulary

# ---- THE DOCUMENTED-EXCEPTION VALVE (2026-08-30, plan-2026-08-30-2 item 2026-08-22-51a5b6) ----------
# aluminum-foil declares sq_ft ON PURPOSE. Pricing it per 'each' was tried on the live board this morning
# and published a wrong crown: Family Fare's 25 sq ft roll at $1.79 ($0.0716/sqft) beat Walmart's 223 sq ft
# roll at $12.20 ($0.0547/sqft), which is a per-PURCHASE verdict across a 9x size spread. So the commodity
# is deliberately unpriceable pending Brad's basis call, and this valve says so in writing.
# The cases below exist because the DANGER of an allowlist is that it stops being narrow. Each one asks
# whether the valve can be made to excuse something it was never given: the same unit somewhere else, a
# different unit here, or an entry nobody finished writing. If any of them ever passes, the valve has
# become a blanket and the check is decorative.
if (Use-Unit 'u133-the-documented-exception-valve') {
$uvExcFx = @(
  [pscustomobject]@{ id = 'aluminum-foil'; unit = 'sq_ft'; reason = 'measured: per-roll crowns the worst value per sq ft'; review_by = '2026-10-01' }
)
$uvE = Test-UnitVocabularyException -Id 'aluminum-foil' -Unit 'sq_ft' -Exceptions $uvExcFx
if ($uvE.Excused) { Ok 'unit-vocabulary exception: the reviewed aluminum-foil sq_ft entry excuses exactly its own (id, unit) pair' }
else { Bad ("unit-vocabulary exception: the reviewed aluminum-foil sq_ft entry did NOT excuse itself (" + $uvE.Why + ") - the valve does not work, so the live arm is about to hard-fail on a deliberate state") }

$uvE = Test-UnitVocabularyException -Id 'parchment-paper' -Unit 'sq_ft' -Exceptions $uvExcFx
if (-not $uvE.Excused) { Ok 'unit-vocabulary exception: sq_ft on a DIFFERENT commodity still fires - the entry excuses one pair, not a unit' }
else { Bad 'unit-vocabulary exception: sq_ft was excused on parchment-paper, which was never reviewed - the valve leaks by unit and every future sq_ft typo now ships silently' }

$uvE = Test-UnitVocabularyException -Id 'aluminum-foil' -Unit 'gram' -Exceptions $uvExcFx
if (-not $uvE.Excused) { Ok 'unit-vocabulary exception: a DIFFERENT unit on the excepted commodity still fires - the entry excuses one pair, not a commodity' }
else { Bad 'unit-vocabulary exception: gram was excused on aluminum-foil, which was never reviewed - the valve leaks by commodity' }

foreach ($uvHalf in @(
    @{ what = 'no reason';    e = [pscustomobject]@{ id = 'aluminum-foil'; unit = 'sq_ft'; review_by = '2026-10-01' } },
    @{ what = 'no review_by'; e = [pscustomobject]@{ id = 'aluminum-foil'; unit = 'sq_ft'; reason = 'because' } })) {
  $uvE = Test-UnitVocabularyException -Id 'aluminum-foil' -Unit 'sq_ft' -Exceptions @($uvHalf.e)
  if (-not $uvE.Excused) { Ok ("unit-vocabulary exception: an entry with " + $uvHalf.what + " excuses nothing - a half-written allowlist row cannot silence the check it annotates") }
  else { Bad ("unit-vocabulary exception: an entry with " + $uvHalf.what + " was allowed to excuse a commodity - the valve accepts undocumented entries") }
}

# THE LIVE EXCEPTION FILE, read the way the production arm reads it. Anything in here that is NOT a real
# deliberate state is a hole, so the file is asserted to be small, complete, and about a commodity that
# really does still declare that unit (a stale entry is caught by the live arm below).
$uvExcLive = Get-UnitVocabularyExceptions $PSScriptRoot
if (@($uvExcLive).Count -le 3) { Ok ("unit-vocabulary exception: the live exception file carries " + @($uvExcLive).Count + " entr(y/ies) - " + ((@($uvExcLive) | ForEach-Object { [string]$_.id + " unit='" + [string]$_.unit + "'" }) -join ', ')) }
else { Bad ("unit-vocabulary exception: the live exception file has grown to " + @($uvExcLive).Count + " entries - an exception list this long is a second vocabulary, not a set of reviewed calls; fix the units or add the engine arm") }

# THE VOCABULARY READER ITSELF. Reading it out of compare-deals is the whole point of the check, so a
# silent parse failure would take the live arm down with it - and a wrong-big parse would pass everything.
$uvVocab = Get-EngineUnitVocabulary $PSScriptRoot
if ($null -eq $uvVocab) {
  Bad 'unit-vocabulary: could not read Convert-ToUnit''s switch out of compare-deals.ps1 - the live arm did not run, which is not the same as a clean result'
} else {
  Ok ("unit-vocabulary: read " + @($uvVocab).Count + " unit(s) straight out of Convert-ToUnit's switch (" + (($uvVocab | Sort-Object) -join ', ') + ") - no second copy of the list lives in this estate")
  # THE PRODUCTION ARM. Every rule file the engine is ever pointed at - commodities.json AND the recipe
  # set recipe-overlay.ps1 runs through the same Convert-ToUnit. Runs daily from check-ad-cycles.
  $uvBad = @(); $uvSeen = 0; $uvExcUsed = @(); $uvExcAll = Get-UnitVocabularyExceptions $PSScriptRoot
  foreach ($uvF in (Get-EngineRuleFiles $PSScriptRoot)) {
    $uvName = [IO.Path]::GetFileName($uvF)
    foreach ($uvC in (Read-RuleFileCommodities $uvF)) {
      $uvSeen++
      $uvH = Test-CommodityUnitIsPriceable $uvC $uvVocab
      if ($uvH) {
        # A DELIBERATE unpriceable unit is excused only by a complete, reviewed (id, unit) entry, and the
        # excusing is printed rather than swallowed - a valve nobody sees is a valve nobody prunes.
        $uvV2 = Test-UnitVocabularyException -Id ([string]$uvC.id) -Unit $uvH -Exceptions $uvExcAll
        if ($uvV2.Excused) { $uvExcUsed += ("{0} [{1}] unit='{2}'" -f [string]$uvC.id, $uvName, $uvH) }
        else { $uvBad += ("{0} [{1}] unit='{2}' ({3})" -f [string]$uvC.id, $uvName, $uvH, $uvV2.Why) }
      }
    }
  }
  # STALE EXCEPTIONS. An entry whose commodity no longer declares that unit is excusing nothing, and an
  # allowlist row nobody deletes is how a narrow exception becomes a permanent hole with a good story
  # attached. Fail on it: the day the unit is fixed or the engine grows the arm is exactly the day to
  # notice the row is spent.
  $uvExcStale = @()
  foreach ($uvX in @($uvExcAll)) {
    $uvKey = ("{0}|{1}" -f [string]$uvX.id, [string]$uvX.unit)
    if (-not (@($uvExcUsed) | Where-Object { $_ -like ([string]$uvX.id + ' *') -and $_ -like ("*unit='" + [string]$uvX.unit + "'*") })) { $uvExcStale += $uvKey }
  }
  if (@($uvExcUsed).Count) { Ok ("unit-vocabulary: " + @($uvExcUsed).Count + " commodit(y/ies) hold a DELIBERATE unpriceable unit under a reviewed exception and are off the board on purpose: " + (@($uvExcUsed) -join '; ')) }
  if (@($uvExcStale).Count) { Bad ("unit-vocabulary: " + @($uvExcStale).Count + " exception entr(y/ies) in unit-vocabulary-exceptions.json no longer match any commodity's declared unit and are excusing nothing: " + (@($uvExcStale) -join '; ') + ". Delete them - a spent allowlist row is a hole with a good story attached.") }
  if ($uvSeen -lt 100) {
    Bad ("unit-vocabulary: only $uvSeen commodit(y/ies) were examined - the live arm read almost nothing, so a clean result would mean nothing")
  } elseif ($uvBad.Count -eq 0) {
    Ok ("unit-vocabulary: all $uvSeen commodities across every engine rule file declare a unit Convert-ToUnit can convert, or a reviewed exception says why they deliberately do not")
  } else {
    Bad ("unit-vocabulary: " + $uvBad.Count + " commodit(y/ies) declare a unit Convert-ToUnit cannot convert, so they can NEVER hold a board cell however well their rules match: " + ($uvBad -join '; ') + ". Correct the unit to one the engine converts (" + (($uvVocab | Sort-Object) -join ', ') + "), or add an arm to Convert-ToUnit - never leave the two disagreeing.")
  }
}
} # u133-the-documented-exception-valve

# ---------------------------------------------------------------- derived size density (2026-08-30)
# THE CROSS-MEASURE HALF OF THE SAZON RULE. build-sams-deals' Build-Row back-computes a package size as
# linePrice / the store's displayed unitPrice whenever the name is silent in the priced unit, and stamps
# the row qty_basis "...; qty derived lp/up" - 8,511 of 57,323 capture rows today. The Sazon rule already
# refuses a row whose name states a quantity IN THE PRICED UNIT that does not reproduce the store's own
# arithmetic; it compares unit TOKENS, so a name in pounds against a price per fluid ounce sails through.
# Weight and volume are bound by density, and that binding is the whole check:
#     "Member's Mark Peanut Oil, 35 lbs."  $55.96  "$0.07/foz"  ->  size 799.429 fl oz  ->  0.672 g/mL
# which is below any edible oil, and would have crowned peanut-oil at $0.07 against a true $0.0953.
# Found by hand, not by a guard. The rule lives in derived-size-density-lib.ps1 so the frozen fixtures
# below and the live arm run the SAME code, and the qty_basis marker is read out of build-sams-deals
# rather than retyped here.
. (Join-Path $PSScriptRoot 'derived-size-density-lib.ps1')

# The marker every fixture is judged against, frozen. The live arm reads the real one out of the builder.
if (Use-Unit 'u134-derived-size-density') {
$dsMk = 'derived lp/up'
} # u134-derived-size-density
function New-DsRow($item, $size, $ad, $up, $store) {
  [pscustomobject]@{ store = $store; item = $item; size = $size; ad_price = $ad; sams_unit_price = $up; qty_basis = ('package; qty ' + $dsMk) }
}

# MUST FIRE - the founding row, frozen verbatim as it stands in sams-deals-2026-08-15.json and
# 2026-08-25.json. Never regenerated from the capture tree: the row is RULED today, and a fixture read
# through the ruling valve would encode the ruling and the case would pass by finding nothing.
if (Use-Unit 'u134-derived-size-density') {
$dsFx = New-DsRow "Member's Mark Peanut Oil, 35 lbs." '799.429 fl oz' '$55.96' '$0.07/foz' "Sam's Club"
$dsV = Test-DerivedSizeDensity $dsFx $dsMk
if ($dsV.Status -eq 'flag' -and [math]::Abs([double]$dsV.Density - 0.672) -lt 0.002) {
  Ok ("derived-size-density: the founding peanut oil row is flagged at " + [math]::Round([double]$dsV.Density, 3) + " g/mL - 35 lb cannot fit in 799.429 fl oz")
} else {
  Bad ("derived-size-density: the founding peanut oil row was NOT caught (status [" + $dsV.Status + "], density [" + $dsV.Density + "]) - the check cannot see its own founding bug, so a quiet run proves nothing")
}

# MUST FIRE - the SECOND row of the same class, which the hand did not find and the rule did. Same store,
# same 35 lb name, a different price and a different displayed unit price, and it lands within 0.03% of
# the same ~799.5 fl oz. Frozen for the same reason.
$dsV = Test-DerivedSizeDensity (New-DsRow "Member's Mark Pure Soybean Oil, 35 lbs." '799.6 fl oz' '$39.98' '$0.05/foz' "Sam's Club") $dsMk
if ($dsV.Status -eq 'flag') { Ok ("derived-size-density: the soybean oil twin is flagged at " + [math]::Round([double]$dsV.Density, 3) + " g/mL - the row the rule found and the hand did not") }
else { Bad ("derived-size-density: the soybean oil twin was NOT caught (status [" + $dsV.Status + "]) - the rule only reproduces the one case it was written from") }

# MUST FIRE - THE CENTS NOTATION (2026-09-21, queue 2026-09-21-e291a1). Since 2026-09-20 Sam's prints a sub-dollar
# unit price in cents to a tenth of a cent, so the same two jugs re-derived to new sizes and walked out from under
# their size-pinned rulings, exactly as those rulings' retire_when said they would, and this watcher refused every
# push on the box. Frozen verbatim from sams-deals-2026-09-21.json as df1d6429e committed it, BEFORE
# build-sams-deals learned to refuse such a row at ingest (its self-test case 8k): a fixture regenerated from the
# capture tree would now find nothing, because the rebuilt file no longer holds either row. The cent sign is
# built from its code point, because PS 5.1 reads this file as ANSI.
$dsCent = [string][char]0x00A2
foreach ($dsC in @(
    @{ n = "Member's Mark Pure Soybean Oil, 35 lbs."; s = '832.778 fl oz'; ad = '$29.98'; up = ('3.6 ' + $dsCent + '/fl oz'); d = 0.645 },
    @{ n = "Member's Mark Peanut Oil, 35 lbs.";       s = '847.879 fl oz'; ad = '$55.96'; up = ('6.6 ' + $dsCent + '/fl oz'); d = 0.633 })) {
  $dsV = Test-DerivedSizeDensity (New-DsRow $dsC.n $dsC.s $dsC.ad $dsC.up "Sam's Club") $dsMk
  if ($dsV.Status -eq 'flag' -and [math]::Abs([double]$dsV.Density - [double]$dsC.d) -lt 0.001) { Ok ("derived-size-density: the 2026-09-21 cents-form row " + $dsC.n + " is flagged at " + [math]::Round([double]$dsV.Density, 3) + " g/mL - the tenth-cent notation is read and judged, not abstained on") }
  else { Bad ("derived-size-density: the 2026-09-21 cents-form row " + $dsC.n + " was NOT caught (status [" + $dsV.Status + "], density [" + $dsV.Density + "]) - " + $dsV.Why) }
}

# MUST FIRE - the OTHER direction, a derived size three times too SMALL. It cannot steal a crown (a small
# size makes the per-unit price too high), but a check that only looks down would call it clean.
$dsV = Test-DerivedSizeDensity (New-DsRow "Melinda's Jalapeo Ketchup, Spicy and Tangy, All Natural, 12 Ounce" '4 fl oz' '$1.08' '$0.27/foz' 'Walmart') $dsMk
if ($dsV.Status -eq 'flag' -and [double]$dsV.Density -gt 2) { Ok ("derived-size-density: a derived size 3x too SMALL is flagged too, at " + [math]::Round([double]$dsV.Density, 3) + " g/mL - the band has two edges") }
else { Bad ("derived-size-density: the too-small Melinda's ketchup size was NOT caught (status [" + $dsV.Status + "]) - only the crown-stealing direction is watched") }

# THE BAND'S OWN REASON FOR EXISTING. The obvious band - "0.6 to 1.6 g/mL, water is 1.0" - does not fire
# on either founding row: 0.672 and 0.671 sit inside it. This case pins that the shipped floor is the one
# taken from real liquid densities, so nobody can "simplify" it back to round numbers without the suite
# saying what that costs.
$dsBand = Get-DensityBand
if ([double]$dsBand.Floor -gt 0.672) { Ok ("derived-size-density: the floor is " + $dsBand.Floor + " g/mL, above the 0.672 the founding row reads - a 0.6 floor would have let it through") }
else { Bad ("derived-size-density: the floor has been widened to " + $dsBand.Floor + " g/mL, which is at or below the founding row's 0.672 - the check can no longer see the bug it was written for") }

# CLEAN TWIN - a correctly-sized Sam's volume row, and the strongest one available: the SAME store, the
# SAME 35 lb oil-jug name, on the same capture days. Its quotient derives 571.143 fl oz, which is
# 0.940 g/mL and right. If this ever fires, the check has become an argument that Sam's is wrong about
# every jug it sells.
# CORRECTED 2026-09-21 (queue 2026-09-21-e291a1): "0.940 and right" was the dollar form's coarseness, not a
# measurement - "$0.07/foz" is +/-7.1% of itself. The same jug printed in cents on 2026-09-21 ("6.6 c/fl oz",
# +/-0.76%) derives 605.758 fl oz = 0.886 g/mL, about 4% under an edible oil's 0.91-0.93 and inside this band.
# That day 4 of the 6 weight-labelled 35 lb oil jugs read 0.875-0.886 and the other 2 are the cents-form rows
# above, so Sam's per-fl-oz price was off on all 6. This case still asserts exactly what it can: an in-band row
# stays silent. The in-band residual is measured and owned in grocery/triage-plans/plan-2026-09-21-3.json.
$dsV = Test-DerivedSizeDensity (New-DsRow "Member's Mark Clear Frying Oil 35 lbs." '571.143 fl oz' '$39.98' '$0.07/foz' "Sam's Club") $dsMk
if ($dsV.Status -eq 'ok') { Ok ("derived-size-density: the correctly-sized 35 lb frying oil jug stays silent at " + [math]::Round([double]$dsV.Density, 3) + " g/mL - the control for the two flagged jugs is in the same store on the same day") }
else { Bad ("derived-size-density: the CORRECT 35 lb frying oil row was called " + $dsV.Status + " (" + $dsV.Why + ") - the check is too eager and would condemn real rows") }
} # u134-derived-size-density

# ---- THE ABSTENTIONS, which are what stop this check from being a false-positive machine -------------
# A multipack whose name states ONE unit's size looks exactly like a bad derivation. The discriminator is
# arithmetic, not vocabulary: a multipack's derived size is a whole-number multiple of the named size.
if (Use-Unit 'u135-the-abstentions-which-are-what-stop') {
foreach ($dsP in @(
    @{ n = 'Capri Sun 100% Juice Blend from Concentrate Juice Boxes, 10 Pouches, for School Lunches and On-the-Go Hydration, Berry with Added Ingredients and Other Natural Flavor, All Natural Ingredients, 6 oz'; z = '60.303 fl oz'; a = '$3.98'; u = '$0.066/foz'; k = 10 },
    @{ n = 'Knorr Professional Ultimate Liquid Concentrated Chicken Base, Shelf Stable, 32oz';                                  z = '127.853 fl oz'; a = '$24.42'; u = '$0.191/foz'; k = 4 },
    @{ n = 'Zevo Multi Insect Killer Spray for Ants, Roaches & More - Two 12 oz Sprays';                                        z = '23.99 fl oz';   a = '$14.97'; u = '$0.624/foz'; k = 2 })) {
  $dsV = Test-DerivedSizeDensity (New-DsRow $dsP.n $dsP.z $dsP.a $dsP.u 'Walmart') $dsMk
  if ($dsV.Status -eq 'abstain' -and $dsV.Why -match ("is " + $dsP.k + "x the ")) { Ok ("derived-size-density: the " + $dsP.k + "-pack is abstained on, not flagged - its derived size is exactly " + $dsP.k + "x the size its name states") }
  else { Bad ("derived-size-density: a " + $dsP.k + "-pack came back [" + $dsV.Status + "] (" + $dsV.Why + ") - a pack-shaped row is not evidence of a bad quotient, and flagging it is how a guard earns its reputation for noise") }
}
# THE KNORR CASE IS THE POINT OF DOING IT WITH ARITHMETIC: its name says nothing about being a case of
# four. A keyword list would have flagged it and a human would have had to rule a correct row.
if (-not (Test-NamePackAmbiguous 'Knorr Professional Ultimate Liquid Concentrated Chicken Base, Shelf Stable, 32oz')) { Ok 'derived-size-density: the Knorr 4-pack carries NO pack word in its name - the keyword list could never have excused it, and the ratio did' }
else { Bad 'derived-size-density: the keyword list now matches the Knorr name, so the multipack ratio case above no longer proves the arithmetic is doing the work' }

# AND THE ABSTENTION MUST NOT REACH THE FOUNDING ROW. 799.429 / 560 nominal oz is 1.43 - not a whole
# number, so no reading of the peanut oil jug as an N-pack excuses it. If the tolerance is ever widened
# far enough to round that to 2, the whole check goes quiet on the case it exists for.
if ($null -eq (Get-PackMultiple (799.429) (35 * 16) 0.05)) { Ok 'derived-size-density: the peanut oil jug is NOT pack-shaped (799.429 fl oz is 1.43x its 35 lb, not a whole multiple) - the multipack valve cannot excuse it' }
else { Bad 'derived-size-density: the multipack valve now reads the founding peanut oil row as an N-pack and would abstain on it - the tolerance has been widened past the point of usefulness' }
# ...and a NON-integer ratio in the pack-shaped range must not be excused either.
if ($null -eq (Get-PackMultiple (25.0) (10.0) 0.05)) { Ok 'derived-size-density: a 2.5x ratio is not read as a pack - only whole multiples abstain' }
else { Bad 'derived-size-density: a 2.5x ratio was read as a multipack - the valve rounds to whatever is nearest and excuses everything' }

# A COARSE UNIT PRICE MAKES THE QUOTIENT MEANINGLESS, and the check must say so rather than judge it. At
# $0.01/foz the cent rounding alone moves the derived size by 50% - Build-Row's own Q-tips comment is
# about this same quotient.
$dsV = Test-DerivedSizeDensity (New-DsRow 'Some Concentrate, 12 oz' '108 fl oz' '$1.08' '$0.01/foz' 'Walmart') $dsMk
if ($dsV.Status -eq 'abstain' -and $dsV.Why -match 'rounded') { Ok 'derived-size-density: a $0.01 unit price is abstained on - at that precision the derived size is +/-50% before anything is wrong' }
else { Bad ("derived-size-density: a $0.01 unit price was judged [" + $dsV.Status + "] - the check is reading pure rounding noise as a density") }

# OUT OF SCOPE is not the same as CLEAN, and the verdict object has to keep them apart.
foreach ($dsS in @(
    @{ w = 'a row whose quantity was NOT derived'; r = [pscustomobject]@{ store = "Sam's Club"; item = "Member's Mark Peanut Oil, 35 lbs."; size = '799.429 fl oz'; ad_price = '$55.96'; sams_unit_price = '$0.07/foz'; qty_basis = "package; qty name (reproduces Sam's unit price)" } },
    @{ w = 'a derived size that is a WEIGHT, not a volume'; r = (New-DsRow 'Something, 35 lbs.' '560 oz' '$55.96' '$0.10/oz' "Sam's Club") },
    @{ w = 'a name that states no weight at all';          r = (New-DsRow 'Member''s Mark Vanilla Ice Cream Pail 5 qts.' '162.4 fl oz' '$8.12' '$0.05/foz' "Sam's Club") })) {
  $dsV = Test-DerivedSizeDensity $dsS.r $dsMk
  if ($dsV.Status -eq 'skip') { Ok ("derived-size-density: " + $dsS.w + " is reported OUT OF SCOPE, not clean") }
  else { Bad ("derived-size-density: " + $dsS.w + " came back [" + $dsV.Status + "] - the check is judging rows it has no evidence about") }
}

# WEIGHT-OZ vs FLUID-OZ. A name that says "16.9 fl. oz." states no WEIGHT, and the number in front of a
# fluid measure must never be read as one - that alone would manufacture a density for every beverage.
# NOT @(Get-NameStatedWeights ...) - the function comma-wraps its return, and @() around a call that
# already did that wraps it a SECOND time, so an EMPTY result counts 1 and this case passes on the wrong
# grounds. It did, the first time it was written. Assign, then count.
$dsW = Get-NameStatedWeights 'Gold Peak Unsweetened Tea 16.9 fl. oz., 18 pk.'
if (@($dsW).Count -eq 0) { Ok 'derived-size-density: "16.9 fl. oz." contributes no weight - a fluid measure is not a mass' }
else { Bad ('derived-size-density: a fluid-ounce measure was read as a weight (' + ((@($dsW) | ForEach-Object { $_.Text }) -join ', ') + '), which manufactures a density for every beverage in the estate') }
# ...and the same call on a name that really does state a weight must come back with exactly one, or the
# case above is only passing because the parser is broken in the other direction.
$dsW = Get-NameStatedWeights "Member's Mark Peanut Oil, 35 lbs."
if (@($dsW).Count -eq 1 -and [math]::Abs([double]$dsW[0].NominalOz - 560) -lt 0.001) { Ok 'derived-size-density: "35 lbs." reads as exactly one weight of 560 nominal oz - the fluid-ounce case above is a real discrimination, not a dead parser' }
else { Bad ('derived-size-density: "35 lbs." did not read as one 560-oz weight (' + @($dsW).Count + ' found) - the weight parser is broken, so every clean verdict above is vacuous') }
} # u135-the-abstentions-which-are-what-stop

# ---- THE RULING VALVE -------------------------------------------------------------------------------
# A flagged row is wrong DATA and cannot be repaired where it sits (a capture records what the store
# said). So the valve is a ledger of adjudicated rows, and it pins the SIZE. These cases exist because
# the danger of any allowlist is that it stops being narrow: each asks whether the valve can be made to
# excuse something it was never given.
if (Use-Unit 'u136-the-ruling-valve') {
$dsRuleFx = @([pscustomobject]@{ store = "Sam's Club"; name = "Member's Mark Peanut Oil, 35 lbs."; size = '799.429 fl oz'; reason = 'measured: 35 lb of peanut oil is 587.3 fl oz, not 799.429'; ruled_by = 'claude'; review_by = '2026-10-01' })
$dsR = Test-DerivedSizeRuling "Sam's Club" "Member's Mark Peanut Oil, 35 lbs." '799.429 fl oz' $dsRuleFx
if ($dsR.Ruled) { Ok 'derived-size-density ruling: the complete peanut oil entry covers exactly its own (store, name, size)' }
else { Bad ("derived-size-density ruling: the complete entry did NOT cover its own row (" + $dsR.Why + ") - the valve does not work, so the live arm is about to hard-fail on a ruled state") }

$dsR = Test-DerivedSizeRuling "Sam's Club" "Member's Mark Peanut Oil, 35 lbs." '812.5 fl oz' $dsRuleFx
if (-not $dsR.Ruled) { Ok 'derived-size-density ruling: a DIFFERENT derived size on the same product still fires - the ruling covers one number, not a product forever' }
else { Bad 'derived-size-density ruling: a new wrong size was excused by the old ruling - the day the store publishes a second bad quotient for this jug, nothing will say so' }

$dsR = Test-DerivedSizeRuling 'Walmart' "Member's Mark Peanut Oil, 35 lbs." '799.429 fl oz' $dsRuleFx
if (-not $dsR.Ruled) { Ok 'derived-size-density ruling: the same name and size at a DIFFERENT store still fires - the ruling is scoped to the capture it was written about' }
else { Bad 'derived-size-density ruling: a ruling written about Sam''s excused a Walmart row - the valve leaks by store' }

foreach ($dsH in @(
    @{ what = 'no reason';    e = [pscustomobject]@{ store = "Sam's Club"; name = "Member's Mark Peanut Oil, 35 lbs."; size = '799.429 fl oz'; ruled_by = 'claude'; review_by = '2026-10-01' } },
    @{ what = 'no ruled_by';  e = [pscustomobject]@{ store = "Sam's Club"; name = "Member's Mark Peanut Oil, 35 lbs."; size = '799.429 fl oz'; reason = 'because'; review_by = '2026-10-01' } },
    @{ what = 'no review_by'; e = [pscustomobject]@{ store = "Sam's Club"; name = "Member's Mark Peanut Oil, 35 lbs."; size = '799.429 fl oz'; reason = 'because'; ruled_by = 'claude' } })) {
  $dsR = Test-DerivedSizeRuling "Sam's Club" "Member's Mark Peanut Oil, 35 lbs." '799.429 fl oz' @($dsH.e)
  if (-not $dsR.Ruled) { Ok ("derived-size-density ruling: an entry with " + $dsH.what + " covers nothing - a half-written ledger row cannot silence the check it annotates") }
  else { Bad ("derived-size-density ruling: an entry with " + $dsH.what + " was allowed to cover a row - the valve accepts undocumented rulings") }
}
} # u136-the-ruling-valve

# ---- THE PRODUCTION ARM, run daily from check-ad-cycles' test-auditors call -------------------------
# THE MARKER READER FIRST. Reading it out of build-sams-deals is the point; a silent parse failure would
# take the sweep down with it and every row would read as not-derived, which is indistinguishable from
# clean. (Measured while writing this: the pattern was first written in a double-quoted string, where
# "\$basis" is a backslash plus an EMPTY variable expansion, and it matched nothing.)
if (Use-Unit 'u137-the-production-arm-run-daily-from') {
$dsMkLive = Get-DerivedQtyMarker $PSScriptRoot
if (-not $dsMkLive) {
  Bad 'derived-size-density: could not read the derived-quantity marker out of build-sams-deals.ps1 - the live arm did not run, which is not the same as a clean result'
} else {
  Ok ("derived-size-density: read the marker '" + $dsMkLive + "' straight out of build-sams-deals' own `$basis assignment - no second copy of it lives in this estate")
  $dsFiles = Get-DerivedCaptureFiles $PSScriptRoot
  $dsRulings = Get-DerivedSizeRulings $PSScriptRoot
  $dsSeen = 0; $dsDerived = 0; $dsAbstain = 0; $dsOk = 0
  $dsBad = @(); $dsRuled = @(); $dsKeys = @{}
  foreach ($dsF in $dsFiles) {
    $dsName = [IO.Path]::GetFileName($dsF)
    foreach ($dsRow in (Read-CaptureRows $dsF)) {
      if (-not $dsRow) { continue }
      $dsSeen++
      if (-not (Test-RowIsDerived $dsRow $dsMkLive)) { continue }
      $dsDerived++
      $dsV2 = Test-DerivedSizeDensity $dsRow $dsMkLive
      if ($dsV2.Status -eq 'abstain') { $dsAbstain++; continue }
      if ($dsV2.Status -eq 'ok') { $dsOk++; continue }
      if ($dsV2.Status -ne 'flag') { continue }
      $dsStore = [string]$dsRow.store; $dsItem = [string]$dsRow.item; $dsSize = [string]$dsRow.size
      $dsKey = ("{0}|{1}|{2}" -f $dsStore, $dsItem, $dsSize)
      # one line per DISTINCT row, however many dated files carry it - the same wrong quotient repeated
      # across a fortnight of captures is one defect, and printing it eight times buries the others
      if ($dsKeys.ContainsKey($dsKey)) { continue }
      $dsKeys[$dsKey] = $true
      $dsRV = Test-DerivedSizeRuling $dsStore $dsItem $dsSize $dsRulings
      if ($dsRV.Ruled) { $dsRuled += ("{0} [{1}] {2} g/mL" -f $dsItem, $dsStore, [math]::Round([double]$dsV2.Density, 3)) }
      else { $dsBad += ("{0} [{1}, {2}] {3} ({4})" -f $dsItem, $dsStore, $dsName, $dsV2.Why, $dsRV.Why) }
    }
  }
  # SPENT RULINGS. An entry whose row no longer appears at that size is covering nothing, and a ledger row
  # nobody deletes is how a narrow ruling becomes a permanent hole with a good story attached. The day the
  # store fixes its quotient is exactly the day to notice the row is spent.
  $dsStale = @()
  foreach ($dsX in @($dsRulings)) {
    $dsXKey = ("{0}|{1}|{2}" -f [string]$dsX.store, [string]$dsX.name, [string]$dsX.size)
    if (-not $dsKeys.ContainsKey($dsXKey)) { $dsStale += $dsXKey }
  }
  if (@($dsRuled).Count) { Ok ("derived-size-density: " + @($dsRuled).Count + " flagged row(s) are covered by a written ruling in derived-size-density-rulings.json: " + (@($dsRuled) -join '; ')) }
  if (@($dsStale).Count) { Bad ("derived-size-density: " + @($dsStale).Count + " ruling(s) no longer match any capture row at that size and are covering nothing: " + (@($dsStale) -join '; ') + ". Delete them - the store's number has moved, so the ruling written about it is spent.") }
  if ($dsSeen -lt 1000 -or $dsDerived -lt 100) {
    Bad ("derived-size-density: only $dsSeen capture row(s) across " + @($dsFiles).Count + " file(s) were read and only $dsDerived carried a derived quantity - the live arm read almost nothing, so a clean result would mean nothing")
  } elseif ($dsBad.Count -eq 0) {
    Ok ("derived-size-density: $dsDerived derived-quantity row(s) across " + @($dsFiles).Count + " capture file(s); $dsOk judged against the name's stated weight and all inside " + $dsBand.Floor + "-" + $dsBand.Ceil + " g/mL, $dsAbstain not judgeable and reported rather than assumed clean")
  } else {
    Bad ("derived-size-density: " + $dsBad.Count + " capture row(s) hold a back-computed size the product cannot physically have, so any per-unit price built from them is wrong by that factor: " + ($dsBad -join '; ') + ". Verify the real package size at the store, then either rule the row in derived-size-density-rulings.json with the arithmetic, or block its cell in known-wrong.json if it reaches the board. Do NOT edit the capture - it is the record of what the store said.")
  }
}
} # u137-the-production-arm-run-daily-from

# ---------------------------------------------------------------- heartbeat CONTENT-CURRENCY (2026-09-04, queue 2026-09-04-2feb5c)
# AN OUTPUT THAT IS REWRITTEN ONLY WHEN IT CHANGES HAS NO mtime LIVENESS SIGNAL AT ALL. health-heartbeat
# paged "OUTPUT STALE: free-dinners.json is 52.4h old" every morning while rotate-free-dinners.ps1 was
# running fine at 08:12 and exiting 0, and while the file's CONTENT was correct (week_of=2026-09-02, the
# current board week). The writer no-ops when the free set has not flipped (its early return at
# rotate-free-dinners.ps1:129-130 sits before the write at line 228), so the mtime tracks the WEEKLY
# rotation while the registry asserted a 30h DAILY window over it.
# The decision is EXTRACTED AND RUN, never transcribed - a copy of a decision is a decision that can drift.
# The two cases below are opposites and both are frozen. Do NOT regenerate them from public\free-dinners.json:
# the next time the rotation flips, the shape they encode disappears and both would pass by finding nothing.
if (Use-Unit 'u138-heartbeat-content-currency') {
$hbSrc = Get-Content (Join-Path $root 'health-heartbeat.ps1') -Raw
# AN EMPTY REGISTRY MUST READ AS BLIND, NOT AS HEALTHY (2026-09-06, PLAN-top5 area 5 §5.2.4).
# health-heartbeat sets EAP='Continue', so before the reader sweep an unreadable expected-automations.json
# left $cfg NULL and every loop iterated nothing: $issues stayed at 0 and the run printed
# "HEALTHY: 0 automation(s)/output(s) all fresh" and exited 0. The one check whose whole job is to notice
# things that died silently would have died silently and said everything was fine. Read-JsonFile throwing
# closes the unreadable half; this closes the other half - a file that PARSES and declares nothing.
if ($hbSrc -match '\$declared\s*=' -and $hbSrc -match 'BLIND - expected-automations\.json declares no tasks' -and $hbSrc -match '(?s)\$declared -eq 0\s*\)\s*\{[^}]*exit 3') {
  Ok 'health-heartbeat refuses to grade an EMPTY registry - zero declared automations is BLIND (exit 3), never HEALTHY (exit 0)'
} else {
  Bad 'health-heartbeat LOST its empty-registry guard - an expected-automations.json that parses but declares nothing makes the silent-death detector print HEALTHY over zero automations and exit 0'
}
$hbM = [regex]::Match($hbSrc, '(?s)# >>> CONTENT-CURRENCY[^\r\n]*\r?\n(.*?)\r?\n# <<< CONTENT-CURRENCY')
if (-not $hbM.Success) {
  Bad 'CONTENT-CURRENCY region is GONE from health-heartbeat.ps1 - this check EXAMINED NOTHING, so an output whose writer legitimately no-ops is back to being judged on an mtime that proves nothing about it'
} else {
  . ([scriptblock]::Create($hbM.Groups[1].Value))
  function CcMtimeH($detail) { $m = [regex]::Match([string]$detail, 'mtime ([0-9.]+)h'); if ($m.Success) { [double]$m.Groups[1].Value } else { -1 } }
  $ccDir = NewFxDir 'hb-content-currency'
  New-Item -ItemType Directory -Force (Join-Path $ccDir 'grocery\out') | Out-Null
  New-Item -ItemType Directory -Force (Join-Path $ccDir 'public') | Out-Null
  $ccFd  = Join-Path $ccDir 'public\free-dinners.json'
  $ccNow = [datetime]'2026-09-04T12:34:00'
  # The registry row under test, frozen in the shape it ships in.
  $ccRow = [pscustomobject]@{ path = 'public/free-dinners.json'; max_age_hours = 30; currency_field = 'week_of'; currency_equals = 'board_week'; why = "this week's free-dinner rotation" }
  # THE BOARD WEEK IS TAKEN BY NAME, NOT BY mtime, because that is how rotate-free-dinners.ps1 takes it and
  # a disagreement between the two derivations would page as a dead rotation. The older board here carries
  # the NEWER mtime on purpose - the live tree does exactly this (comparison-2026-08-26.json was rebuilt on
  # 08-29). A derivation that sorted by LastWriteTime would call 2026-08-26 "this week" and then report a
  # perfectly current rotation as dead.
  Set-Content (Join-Path $ccDir 'grocery\out\comparison-2026-08-26.json') '{"week_of":"2026-08-26"}' -Encoding UTF8
  Set-Content (Join-Path $ccDir 'grocery\out\comparison-2026-09-02.json') '{"week_of":"2026-09-02"}' -Encoding UTF8
  (Get-Item (Join-Path $ccDir 'grocery\out\comparison-2026-08-26.json')).LastWriteTime = [datetime]'2026-09-04T11:59:00'
  (Get-Item (Join-Path $ccDir 'grocery\out\comparison-2026-09-02.json')).LastWriteTime = [datetime]'2026-09-04T11:30:16'
  $ccWeek = Get-BoardWeek $ccDir
  if ($ccWeek -eq '2026-09-02') { Ok 'heartbeat content-currency: the board week is taken by NAME - the newest comparison file by mtime is an older board and it did not win' }
  else { Bad ("heartbeat content-currency: board week resolved to '" + $ccWeek + "', not 2026-09-02 - this check no longer agrees with rotate-free-dinners' own week key, so it will page a current rotation as dead") }

  # ---- MUST FIRE: a rotation stuck on a PREVIOUS board week, with an mtime minutes old. This is precisely
  #      the failure the mtime rule cannot see, and the reason the answer was not a wider window.
  [IO.File]::WriteAllText($ccFd, '{"week_of":"2026-08-26","updated":"2026-08-26T08:09:12","free":[]}', (New-Object Text.UTF8Encoding($false)))
  (Get-Item $ccFd).LastWriteTime = [datetime]'2026-09-04T12:20:00'
  $cc1 = Test-ContentCurrency -Row $ccRow -Path $ccFd -BoardWeek $ccWeek -Now $ccNow
  $cc1Age = CcMtimeH $cc1.detail
  if ($cc1.applies -and (-not $cc1.current) -and $cc1.detail -match 'week_of=2026-08-26' -and $cc1.detail -match '2026-09-02') {
    Ok 'heartbeat content-currency: MUST FIRE - a rotation still on the 2026-08-26 board week is reported even though its file was written 14 minutes ago'
  } else { Bad ('heartbeat content-currency: a DEAD rotation with a fresh mtime read as current (applies=' + $cc1.applies + ' current=' + $cc1.current + ' detail=' + $cc1.detail + ')') }
  if ($cc1Age -ge 0 -and $cc1Age -lt 30) {
    Ok ('heartbeat content-currency: the must-fire fixture is genuinely fresh by mtime (' + $cc1Age + 'h, inside the row 30h window), so the old rule would have called this dead rotation healthy - the case cannot pass for the wrong reason')
  } else { Bad ('heartbeat content-currency: the must-fire fixture reported mtime ' + $cc1Age + 'h, so it may be firing on staleness rather than on content - the case would prove nothing') }

  # ---- CLEAN TWIN: today's exact shape. week_of is the current board week and the mtime is 52.4h old,
  #      well past the row's 30h. It must report clean and send nothing, or the check never moved off mtime.
  [IO.File]::WriteAllText($ccFd, '{"week_of":"2026-09-02","updated":"2026-09-02T08:10:35","free":[]}', (New-Object Text.UTF8Encoding($false)))
  (Get-Item $ccFd).LastWriteTime = [datetime]'2026-09-02T08:10:35'
  $cc2 = Test-ContentCurrency -Row $ccRow -Path $ccFd -BoardWeek $ccWeek -Now $ccNow
  $cc2Age = CcMtimeH $cc2.detail
  if ($cc2.applies -and $cc2.current) { Ok 'heartbeat content-currency: CLEAN TWIN - an honest no-op whose week_of is the current board week reports clean and pages nobody' }
  else { Bad ('heartbeat content-currency: the 2026-09-04 false page is back - a current rotation still reports stale (current=' + $cc2.current + ' detail=' + $cc2.detail + ')') }
  if ($cc2Age -gt 30) { Ok ('heartbeat content-currency: the clean twin really is past the row window by mtime (' + $cc2Age + 'h > 30h), so it proves the check moved off mtime rather than passing on freshness') }
  else { Bad ('heartbeat content-currency: the clean twin reported mtime ' + $cc2Age + 'h, inside the 30h window - it would pass under the OLD rule too and proves nothing') }

  # ---- FAIL CLOSED. Everything this check cannot prove is reported, never assumed clean.
  $cc3 = Test-ContentCurrency -Row $ccRow -Path $ccFd -BoardWeek '' -Now $ccNow
  if ($cc3.applies -and (-not $cc3.current) -and $cc3.detail -match 'BLIND') { Ok 'heartbeat content-currency: no board to compare against is reported as BLIND, not as clean' }
  else { Bad ('heartbeat content-currency: with no comparison board the check went quiet instead of reporting (current=' + $cc3.current + ' detail=' + $cc3.detail + ')') }
  $ccRowX = [pscustomobject]@{ path = 'public/free-dinners.json'; max_age_hours = 30; currency_field = 'week_of'; currency_equals = 'whenever'; why = 'x' }
  $cc4 = Test-ContentCurrency -Row $ccRowX -Path $ccFd -BoardWeek $ccWeek -Now $ccNow
  if ($cc4.applies -and (-not $cc4.current)) { Ok 'heartbeat content-currency: a currency_equals form this code has never heard of is UNPROVEN (allowlist, not denylist)' }
  else { Bad 'heartbeat content-currency: an unrecognised currency_equals passed as current - a typo in the registry would silently disarm the row' }
  [IO.File]::WriteAllText($ccFd, '{"updated":"2026-09-02T08:10:35","free":[]}', (New-Object Text.UTF8Encoding($false)))
  $cc5 = Test-ContentCurrency -Row $ccRow -Path $ccFd -BoardWeek $ccWeek -Now $ccNow
  if ($cc5.applies -and (-not $cc5.current) -and $cc5.detail -match 'no week_of field') { Ok 'heartbeat content-currency: a file with no week_of at all is reported, not read as agreement' }
  else { Bad ('heartbeat content-currency: a file missing its currency stamp did not report (current=' + $cc5.current + ' detail=' + $cc5.detail + ')') }
  Remove-Item $ccFd -Force -ErrorAction SilentlyContinue
  $cc6 = Test-ContentCurrency -Row $ccRow -Path $ccFd -BoardWeek $ccWeek -Now $ccNow
  if ($cc6.applies -and (-not $cc6.current) -and $cc6.detail -match 'does not exist') { Ok 'heartbeat content-currency: a missing output is still reported under the content form' }
  else { Bad 'heartbeat content-currency: a deleted output went unreported under the content form' }

  # ---- HELD WITH THE BOARD (2026-09-19, inbox run0919-free-dinners). guards refused every board 09-13..09-18,
  #      check-ad-cycles skipped the rotation by design each morning, and this check paged it as a dead job four
  #      times. A week-behind row is HELD only on TODAY's blocked verdict over THIS board week; all else pages.
  $ccToday = $ccNow.ToString('yyyy-MM-dd')
  function CcVerdict([string]$date, $blocked, [string]$board) {
    [pscustomobject]@{ date = $date; written = ($date + 'T08:11:59'); guards_rc = 2; guards_blocked = $blocked
      inputs = [pscustomobject]@{ ('grocery\out\' + $board) = 'x'; 'grocery\commodities.json' = 'y' } }
  }
  [IO.File]::WriteAllText($ccFd, '{"week_of":"2026-08-26","updated":"2026-08-26T08:09:12","free":[]}', (New-Object Text.UTF8Encoding($false)))
  $cc7 = Test-ContentCurrency -Row $ccRow -Path $ccFd -BoardWeek $ccWeek -Now $ccNow
  $hw1 = Test-HeldWithBoard -Cc $cc7 -Verdict (CcVerdict $ccToday $true 'comparison-2026-09-02.json') -BoardWeek $ccWeek -Today $ccToday
  if ($cc7.week_behind -and $hw1.held -and $hw1.detail -match 'HELD WITH THE BOARD' -and $hw1.detail -match 'guards_rc=2') {
    Ok 'heartbeat held-with-board: MUST FIRE - a rotation one board behind while guards refused THAT board today reads HELD, not "has not run" (the 09-13..09-18 page)'
  } else { Bad ('heartbeat held-with-board: a rotation skipped by the board hold still reads as a dead job (week_behind=' + $cc7.week_behind + ' held=' + $hw1.held + ' detail=' + $hw1.detail + ')') }
  $hw2 = Test-HeldWithBoard -Cc $cc7 -Verdict (CcVerdict $ccToday $false 'comparison-2026-09-02.json') -BoardWeek $ccWeek -Today $ccToday
  if ($hw2.held -eq $false) { Ok 'heartbeat held-with-board: MUST NOT FIRE - guards PASSED today and the rotation did not move, so it still pages as dead' }
  else { Bad 'heartbeat held-with-board: a dead rotation on a green day was excused as held' }
  $hw3 = Test-HeldWithBoard -Cc $cc7 -Verdict (CcVerdict '2026-09-03' $true 'comparison-2026-09-02.json') -BoardWeek $ccWeek -Today $ccToday
  if ($hw3.held -eq $false) { Ok 'heartbeat held-with-board: MUST NOT FIRE - a blocked verdict from YESTERDAY says nothing about today, so a chain that stopped still pages' }
  else { Bad 'heartbeat held-with-board: yesterday''s hold excused today, so a chain that stopped running would never page here' }
  $hw4 = Test-HeldWithBoard -Cc $cc7 -Verdict (CcVerdict $ccToday $true 'comparison-2026-08-26.json') -BoardWeek $ccWeek -Today $ccToday
  if ($hw4.held -eq $false) { Ok 'heartbeat held-with-board: MUST NOT FIRE - a hold on an OLDER board does not excuse a newer board no guard has seen' }
  else { Bad 'heartbeat held-with-board: a verdict about another board excused this one' }
  $hw5 = Test-HeldWithBoard -Cc $cc7 -Verdict $null -BoardWeek $ccWeek -Today $ccToday
  if ($hw5.held -eq $false) { Ok 'heartbeat held-with-board: MUST NOT FIRE - no verdict at all excuses nothing' }
  else { Bad 'heartbeat held-with-board: an absent verdict read as a hold' }
  $hw6 = Test-HeldWithBoard -Cc $cc6 -Verdict (CcVerdict $ccToday $true 'comparison-2026-09-02.json') -BoardWeek $ccWeek -Today $ccToday
  if ($cc6.week_behind -eq $false -and $hw6.held -eq $false) { Ok 'heartbeat held-with-board: MUST NOT FIRE - a MISSING output is never excused by a hold, only a week-behind one' }
  else { Bad 'heartbeat held-with-board: a hold excused a missing output' }
  [IO.File]::WriteAllText($ccFd, '{"week_of":"2026-09-02","updated":"2026-09-02T08:10:35","free":[]}', (New-Object Text.UTF8Encoding($false)))
  $cc8 = Test-ContentCurrency -Row $ccRow -Path $ccFd -BoardWeek $ccWeek -Now $ccNow
  if ($cc8.current -eq $true -and $cc8.detail -match 'matches the board week') { Ok 'heartbeat held-with-board: CLEAN TWIN - a current rotation still reads current, whatever the verdict says' }
  else { Bad ('heartbeat held-with-board: a current rotation stopped reading current (detail=' + $cc8.detail + ')') }
  # WIRED, NOT ONLY AVAILABLE: the live path reads today's verdict and routes a not-current row through the hold
  # test. Needles split so this suite cannot match its own text.
  $nHw = 'Test-HeldWith' + 'Board -Cc $cc -Verdict $hbVerdict'
  $nRv = '$hbVerdict = Read-ChainVerdict' + 'Record -Repo $repo'
  if ($hbSrc.Contains($nHw) -and $hbSrc.Contains($nRv)) { Ok 'heartbeat held-with-board: CLEAN TWIN - the live output loop reads today''s verdict and routes a not-current row through the hold test' }
  else { Bad 'heartbeat held-with-board: the live loop no longer consults the verdict, so a board hold pages as a dead rotation again' }
  Remove-Item $ccFd -Force -ErrorAction SilentlyContinue

  # ---- IT IS OPT-IN, AND THAT IS THE BLAST RADIUS. The other four output_files rows are rewritten on EVERY
  #      run and their mtime IS a real liveness signal; a default-on content check would silently disarm all
  #      four. This arm reads the LIVE registry, so adding currency_field to one of them fires here.
  $ccCfg = Read-JsonFile (Join-Path $root 'expected-automations.json')
  $ccWrong = @()
  foreach ($ccP in @('grocery/out/smp-feed.json', 'public/smp-feed.json', 'meal-prep/pipeline/v2-perserving.json', 'meal-prep/ingredient-map.json')) {
    $ccR = @(@($ccCfg.output_files) | Where-Object { [string]$_.path -eq $ccP })
    if ($ccR.Count -ne 1) { $ccWrong += ($ccP + ' (no such row in the registry any more)'); continue }
    if ((Test-ContentCurrency -Row $ccR[0] -Path $ccFd -BoardWeek $ccWeek -Now $ccNow).applies) { $ccWrong += $ccP }
  }
  if ($ccWrong.Count -eq 0) { Ok 'heartbeat content-currency: all four write-every-run rows are still on the plain mtime rule - the content form did not leak into outputs whose writers cannot no-op' }
  else { Bad ('heartbeat content-currency: ' + $ccWrong.Count + ' row(s) whose writer cannot no-op are now judged on content, which disarms the mtime check that is their only liveness signal: ' + ($ccWrong -join '; ')) }
  $ccFdRow = @(@($ccCfg.output_files) | Where-Object { [string]$_.path -eq 'public/free-dinners.json' })
  if ($ccFdRow.Count -eq 1 -and (Test-ContentCurrency -Row $ccFdRow[0] -Path $ccFd -BoardWeek $ccWeek -Now $ccNow).applies) {
    Ok 'heartbeat content-currency: the live free-dinners row still opts in - the fix is wired in the registry, not just available in the code'
  } else { Bad 'heartbeat content-currency: the live public/free-dinners.json row no longer declares currency_field, so it is back on the 30h mtime rule and will page again from ~30h after every flip' }
  Remove-Item $ccDir -Recurse -Force -ErrorAction SilentlyContinue
}
} # u138-heartbeat-content-currency

# ---------------------------------------------------------------- matcher parity (wired 2026-08-21)
# WHICH COMMODITY OWNS A PRODUCT NAME is decided by Match-Category in compare-deals, and re-implemented in
# at least three auditors - one of them, audit-household-in-food, a HARD guard. test-matcher-parity.ps1 was
# written on 2026-08-21 to prove those copies still agree with the engine, and it shipped with NO caller:
# the script census listed it as an orphan and guard-contract as DEAD. A parity test nothing runs proves
# nothing, which is precisely the class this whole harness exists to catch, so it is called from here.
# SAMPLED, not exhaustive: the estate holds ~28.5k product names and the full sweep is minutes. 400 is
# enough to catch a systematic divergence (the failure mode is a copy drifting for a WHOLE rule, not for
# one unlucky name) while keeping this suite quick enough that people keep running it.
if (Use-Unit 'u139-matcher-parity-wired-2026-08-21') {
$r = Get-Early 'early:matcher-parity' (Join-Path $root 'test-matcher-parity.ps1') @('-Sample','400')
if ($r.rc -eq 0 -and $r.text -match 'MATCHER-PARITY OK') { Ok 'matcher parity: every auditor copy of Match-Category still assigns names exactly as the engine does' }
elseif ($r.rc -eq 3 -or $r.text -match 'FATAL') { Bad ('matcher parity could not evaluate (rc=' + $r.rc + ') - it proved nothing, which is not the same as agreement') }
else { Bad ('matcher parity FAILED (rc=' + $r.rc + ') - an auditor no longer describes the engine that builds the board; audit-household-in-food is a HARD guard, so it may be judging cells under the wrong commodity') }
# THE CHAIN LANE IS A CENSUS, NOT THIS SAMPLE (2026-09-18, backlog I133). The 400 above stays because this
# suite runs on every push. The daily chain's lane ran the same -Sample 400, a sorted stride that is a fixed
# function of the corpus: over 51,766 names it reached 188 of the 583 commodities that own any name, so a
# drift in the other 395 rules was invisible, and "a copy drifts for a whole rule" did not cover them. The
# census took 309.5 s against 43.2 s, weekly or on a matcher edit. A lane that goes back to -Sample is red here.
function Get-ParityLaneShape([string]$src) {
  # 'missing' = no single matcher-parity lane; 'sampled' = its code passes -Sample; 'census' = it does not.
  $lane = @(($src -split "`n") | Where-Object { $_ -match "New-FanoutLane\s+-Name\s+'matcher-parity'" })
  if ($lane.Count -ne 1) { return 'missing' }
  $code = ($lane[0] -split '#', 2)[0]
  if ($code -match '-Sample\b') { return 'sampled' }
  return 'census'
}
$fxLanePre = "        New-FanoutLane -Name 'matcher-parity' -File x.ps1 "
$fxLaneSampled = $fxLanePre + "-Arguments @('-Sample','400') -Marker 'M'"
$fxLaneCensus = $fxLanePre + "-TimeoutSec 900 -Marker 'M'   # a census, no -Sample"
$shapeS = Get-ParityLaneShape $fxLaneSampled
if ($shapeS -eq 'sampled') { Ok 'MUST FIRE  a matcher-parity chain lane that passes -Sample is read as SAMPLED' } else { Bad ('MUST FIRE  a sampled matcher-parity lane was read as ' + $shapeS) }
$shapeC = Get-ParityLaneShape $fxLaneCensus
if ($shapeC -eq 'census') { Ok 'MUST NOT FIRE  a census lane whose trailing comment names -Sample is still a census' } else { Bad ('MUST NOT FIRE  a census lane was read as ' + $shapeC) }
$cadSrcI133 = (Expand-SelfTestPointers -Text ([IO.File]::ReadAllText((Join-Path $root 'check-ad-cycles.ps1'))) -Path (Join-Path $root 'check-ad-cycles.ps1'))
$shapeLive = Get-ParityLaneShape $cadSrcI133
if ($shapeLive -eq 'census') { Ok 'the daily chain runs matcher parity as a CENSUS over every product name (I133)' }
else { Bad ('the daily chain matcher-parity lane is ' + $shapeLive + ', not a census - a stride of 400 reached 188 of 583 commodities (backlog I133)') }
$liveLane = @(($cadSrcI133 -split "`n") | Where-Object { $_ -match "New-FanoutLane\s+-Name\s+'matcher-parity'" })
if ($liveLane.Count -eq 1 -and $liveLane[0] -match "-Marker\s+'MATCHER-PARITY-COMPLETE'" -and $liveLane[0] -match "-Due\s+\`$cadDue\['matcher-parity'\]") { Ok 'CLEAN TWIN  the census lane still declares its completion marker and its 7-day cadence' }
else { Bad 'CLEAN TWIN  the matcher-parity lane lost its MATCHER-PARITY-COMPLETE marker or its cadence' }
} # u139-matcher-parity-wired-2026-08-21

# COMPLETION MARKER (2026-08-08). This file is the founding case for the whole contract: on 2026-08-08 it
# threw 242 checks before this point, printed 176 lines of PASS, and exited 1 - indistinguishable from an
# ordinary findings-exit. The exit code carries the VERDICT; this line carries the fact that the run
# REACHED THE END. check-ad-cycles requires it before believing a quiet result.
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\guard-contract.ps1')
# ONE decision, taken by the pure function above, so the cases that prove it cannot drift from it.
# OUTSIDE EVERY UNIT, ALWAYS: a verdict inside a unit is a verdict a selective run can skip.
$verdict = Get-AuditorsVerdict $failed $hygiene $pass $skipped $live
$unitNote = ''
if ($script:UnitsSkipped.Count -gt 0) {
  # A SELECTIVE RUN (see Use-Unit) states what it covered and never uses the PASS wording, whatever it found.
  $unitsAll = $script:UnitsRan.Count + $script:UnitsSkipped.Count
  Write-Output ('test-auditors SELECTIVE  ran ' + ($pass + $failed + $live + $hygiene + $skipped) + ' case(s) in ' + $script:UnitsRan.Count + ' of ' + $unitsAll + ' unit(s) (' + $failed + ' failed, ' + $pass + ' passed' + $(if ($live) { ', ' + $live + ' LIVE-RED' } else { '' }) + $(if ($hygiene) { ', ' + $hygiene + ' HYGIENE' } else { '' }) + $(if ($skipped) { ', ' + $skipped + ' SKIPPED' } else { '' }) + '); ' + $script:UnitsSkipped.Count + ' unit(s) were not selected and proved nothing. NOT a full run and NOT a pass.')
  $unitNote = ' selective=1 units_ran=' + $script:UnitsRan.Count + ' units_skipped=' + $script:UnitsSkipped.Count
} else {
  Write-Output $verdict.line
}
Write-GuardComplete -Name 'test-auditors' -Summary ("pass=$pass failed=$failed live=$live hygiene=$hygiene skipped=$skipped" + $unitNote)
exit $verdict.rc
} finally { Sweep-FxPaths }

