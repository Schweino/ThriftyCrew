
# ---------------------------------------------------------------- stale price feed (2026-08-15)
# THE WATCHER FOR THE FEED A PRICING STAGE COMPUTES ON. compute-v2-perserving.ps1 downloaded the feed only
# when meal-prep\scratch-smpfeed.json was MISSING, so it downloaded once and then priced the entire catalog
# against that snapshot forever. Nineteen days on: 264 of 564 shared prices had moved (mean 27%), 41 items
# existed live that the snapshot had never heard of, and 534 of 544 rows of the manifest on disk matched the
# JULY computation and none matched the live feed. It reached the site - cheapest_ps is what the cards, hub
# grid, planner, Top 5, free-dinner rotation and the daily reel all read.
# A present-but-old file is indistinguishable from a fresh one by inspection and the output is a plausible
# dollar figure either way, so this is the class that only a fixture can hold down.
if (Use-Unit 'u120-stale-price-feed') {
$mpPipe = Join-Path (Split-Path $root -Parent) 'meal-prep\pipeline'
$ffs = Join-Path $mpPipe 'feed-freshness.ps1'
if (-not (Test-Path $ffs)) { Bad 'meal-prep\pipeline\feed-freshness.ps1 is missing - nothing decides which feed a pricing stage may compute on, and the download-once-forever bug has nothing stopping it coming back' }
else {
  # A FLOOR, NOT AN EQUALITY, the same ruling as $TCB_MIN_CASES above (2026-09-09): it was
  # `-match 'SELFTEST: 25/25 pass'`, so ADDING a case turned this red with the PASSING run's own output as
  # the failure text. 25 -> 26 on 2026-09-11, when the clobber probe moved off the fixed %TEMP% name onto a
  # per-run scratch directory and gained the case that asserts the directory is removed again. A floor still
  # catches what the count is for - a case that silently stops running - and the n/n shape means no case
  # failed, so the bar is not lower than the equality it replaces.
  $FF_MIN_CASES = 26
  $r = PSChild $ffs -SelfTest | Out-String
  $ffRc = $LASTEXITCODE
  $ffOk = $false; $ffCount = 0
  if ($r -match 'SELFTEST: (\d+)/(\d+) pass') {
    $ffCount = [int]$Matches[2]
    $ffOk = ([int]$Matches[1] -eq $ffCount) -and ($ffCount -ge $FF_MIN_CASES)
  }
  if ($ffRc -eq 0 -and $ffOk) {
    Ok ('feed-freshness -SelfTest passes with its founding-bug fixtures armed (July 27 snapshot refused, fresh feed passes, mtime-laundering caught, an 8h cache refused against a 1h canonical feed, legitimate 23.5h aging not refused; ' + $ffCount + ' cases, floor ' + $FF_MIN_CASES + ')')
  } else { Bad ('feed-freshness -SelfTest failed or lost its founding-bug fixtures (rc=' + $ffRc + ', floor ' + $FF_MIN_CASES + ' cases): ' + (($r -split "`r?`n" | Where-Object { $_ -match 'FAIL|SELFTEST' }) -join ' | ')) }

  # THE FROZEN FIXTURE FILES THEMSELVES. Same rule as every other fixture here: never regenerate them from
  # the live feed, or the staleness they encode disappears and the test passes by finding nothing.
  $ffMf = Join-Path $fix 'feedfresh-mustfire.json'
  if ((Test-Path $ffMf) -and ((Read-JsonFile $ffMf).generated -eq '2026-07-27T07:13:44')) {
    Ok 'the frozen stale-feed fixture still carries the real 2026-07-27 snapshot stamp it was built from'
  } else { Bad 'guard-fixtures\feedfresh-mustfire.json is missing or has been regenerated - it must keep the July 27 stamp, which IS the bug' }

  # THE SEAL. A guard cannot detect its own unsealing: if the production caller stops routing through
  # feed-freshness, its self-test stays green forever while every run prices on whatever it likes again.
  # feed-freshness -SelfTest asserts this too; asserting it HERE is what makes the check independent of the
  # file being checked.
  $cvSrc = Get-Content (Join-Path $mpPipe 'compute-v2-perserving.ps1') -Raw
  if ($cvSrc -match 'feed-freshness\.ps1' -and $cvSrc -match 'Resolve-AndCheckFeed' -and $cvSrc -match 'Test-FeedVerdictFatal') {
    Ok 'compute-v2-perserving still resolves its feed through feed-freshness and still refuses a fatal verdict'
  } else { Bad 'compute-v2-perserving.ps1 no longer routes its feed through feed-freshness.ps1 - the freshness gate has been unsealed and the catalog can be priced on any snapshot that happens to be lying around' }

  # THE PRODUCTION REFUSAL, END TO END. Everything above tests the judgement or the source; this runs the
  # REAL compute-v2-perserving.ps1 against the frozen July fixture and requires exit 2 with the manifest
  # untouched. It is the difference between "the library would refuse" and "the script does refuse" - and
  # the manifest hash check is the part that matters, because the harm was never the exit code, it was a
  # stale manifest reaching the cards, the planner, Top 5, the rotation and the daily reel.
  # -NoAlert so a daily fixture run does not mail Brad and file a triage entry for a synthetic feed.
  $cvMan = Join-Path $mpPipe 'v2-perserving.json'
  if (Test-Path $cvMan) {
    $cvHashBefore = (Get-FileHash $cvMan).Hash
    $null = PSChild (Join-Path $mpPipe 'compute-v2-perserving.ps1') -FeedPath $ffMf -NoAlert
    $cvRc = $LASTEXITCODE
    $cvHashAfter = (Get-FileHash $cvMan).Hash
    if ($cvRc -eq 2 -and $cvHashAfter -eq $cvHashBefore) {
      Ok 'compute-v2-perserving REFUSES the frozen July feed end to end (exit 2) and leaves the manifest untouched'
    } else {
      Bad ("compute-v2-perserving did NOT refuse the frozen stale feed as designed (exit $cvRc, manifest changed: $($cvHashAfter -ne $cvHashBefore)) - a stale feed can reach pipeline\v2-perserving.json again, and every cost surface reads that file")
    }
  } else { Skip 'compute-v2 end-to-end refusal (no v2-perserving.json on this machine)' }

  if ($cvSrc -match '(?s)if\s*\(\s*-not\s*\(Test-Path\s+\$FeedPath\s*\)\s*\)\s*\{\s*[^}]*Invoke-WebRequest') {
    Bad 'the founding "download the feed only if the file is missing" branch is back in compute-v2-perserving.ps1 - that is the exact code that froze the catalog on a July snapshot for nineteen days'
  } else { Ok 'the founding download-only-if-missing branch has not returned to compute-v2-perserving' }
}
} # u120-stale-price-feed

# ------------------------------------------------- feed COVERAGE of what is published (2026-08-15)
# Sibling to the freshness gate above and a different question: freshness asks whether the feed a pricing
# stage computes on is current, this asks whether the feed the READER'S CARD fetches can price the recipes
# that are actually live.
#
# FOUNDING BUG. Every recipe card fetches prices at view time. Until 2026-08-15 that fetch went to the V3
# platform's /api/v2/recipe-feed/<slug>, deleted 2026-08-14. It did not fail cleanly: it kept answering from
# a STORED release, returning 200 with frozen prices for anything minted before that release and 404 for
# everything newer. Two recipes published that day rendered an EMPTY cost section and were set back to
# draft. Worse, V3's pricing_inputs never carried the recipe-spelling aliases, so a card whose spec says
# 93-7-ground-beef found nothing under a feed that only knew ground-beef-93-7: measured live, american-
# goulash-pasta showed "Price unavailable in this release" on its two biggest lines and a grand total of
# "Unavailable". 231 of 544 cards use an alias-spelling bid. Nothing failed at publish time; the pages were
# simply wrong once a reader opened them, and it was found at post-publish review instead of at publish.
if (Use-Unit 'u121-feed-coverage-of-what-is-published') {
# The child's verdict read three ways (backlog I237): 'pass' only on exit 0 AND the pinned N/N; 'blind' only on
# exit 0 AND "X of Y cases ran, Z BLIND" with X + Z = Y = the pin; everything else 'fail'.
function Get-FeedCovSelfTestVerdict([int]$Rc, [string]$Text, [int]$Pinned) {
  if ($Rc -eq 0 -and $Text -match ('SELFTEST: ' + $Pinned + '/' + $Pinned + ' pass')) { return [pscustomobject]@{ state = 'pass'; detail = '' } }
  $bm = [regex]::Match([string]$Text, 'SELFTEST: (\d+) of (\d+) cases ran, (\d+) BLIND')
  if ($Rc -eq 0 -and $bm.Success) {
    $ran = [int]$bm.Groups[1].Value; $tot = [int]$bm.Groups[2].Value; $bl = [int]$bm.Groups[3].Value
    if ($tot -eq $Pinned -and ($ran + $bl) -eq $tot -and $bl -gt 0) { return [pscustomobject]@{ state = 'blind'; detail = ('ran ' + $ran + ' of ' + $tot + ', ' + $bl + ' BLIND') } }
  }
  return [pscustomobject]@{ state = 'fail'; detail = '' }
}
$fcvBlind = 'SELFTEST: 27 of 28 cases ran, 1 BLIND - could not look, NOT passed'
$fcvCases = @(
  @('MUST NOT FIRE: an unseeded checkout''s blind verdict at exit 0 is a SKIP, not a failing case', 0, $fcvBlind, 'blind'),
  @('CLEAN TWIN: the seeded verdict 28/28 at exit 0 still passes', 0, 'SELFTEST: 28/28 pass', 'pass'),
  @('MUST FIRE: a failing child (exit 1) is a failure', 1, 'SELFTEST: 27/28 pass - 1 FAILED', 'fail'),
  @('MUST FIRE: a blind verdict over a suite that lost cases (27 of 27) is still lost fixtures, not a skip', 0, 'SELFTEST: 26 of 27 cases ran, 1 BLIND - could not look, NOT passed', 'fail'),
  @('MUST FIRE: a blind verdict at a non-zero exit is a failure', 1, $fcvBlind, 'fail')
)
foreach ($fc in $fcvCases) {
  $got = (Get-FeedCovSelfTestVerdict -Rc $fc[1] -Text $fc[2] -Pinned 28).state
  if ($got -eq $fc[3]) { Ok ('feed-covers-published verdict reader - ' + $fc[0]) } else { Bad ('feed-covers-published verdict reader - ' + $fc[0] + ' (got ' + $got + ', want ' + $fc[3] + ')') }
}
$fcp = Join-Path $mpPipe 'feed-covers-published.ps1'
if (-not (Test-Path $fcp)) { Bad 'meal-prep\pipeline\feed-covers-published.ps1 is missing - nothing checks that the feed a published card FETCHES can actually price it, and a recipe can go live with an empty cost section again' }
else {
  $r = PSChild $fcp -SelfTest | Out-String
  # The count is pinned for the reason every count here is pinned: a case that silently stops running never
  # errors, so the tally is the only thing that notices it went missing.
  # 16 -> 19 (2026-08-23): a2a34ae3 "carriage gate phase 1b" added three cases to
  # feed-covers-published.ps1 and did not move this pin, so the child passed 19/19 while the wrapper
  # failed it. The pin is still pinned ON PURPOSE - a case that silently stops running never errors,
  # so the tally is the only thing that notices - it just has to be MOVED when cases are added.
  # 19 -> 28 (2026-08-29): AND IT HAPPENED AGAIN, same file, same pin, same cause. 120a26c1 ("the guard
  # said the price was $0.00 and the price was fine; the scaler was the thing that was dark") added nine
  # UNBID_LINE cases and left the pin at 19, so test-auditors reported "a watcher has gone blind" about a
  # child that was passing 28/28 with rc=0. Twice in six days is the pin telling us something: the failure
  # message says "failed or lost its founding-bug fixtures", which reads as the guard being broken rather
  # than as the wrapper being out of date, and it sends the next reader to debug the wrong file. Verified
  # before moving it: feed-covers-published.ps1 -SelfTest exits 0 and reports 28/28, and all nine new cases
  # are real UNBID_LINE assertions, not the old ones renamed.
  # A CHECKOUT WITHOUT A BUILT CARD IS COULD-NOT-LOOK, NEVER A FAILURE (2026-09-18, backlog I237). The child's own
  # verdict there is "SELFTEST: 27 of 28 cases ran, 1 BLIND" at exit 0 (meal-prep\db\built is gitignored and a
  # worktree has none until ops\seed-worktree.ps1 runs). This line used to read only '28/28 pass', so that verdict
  # printed FAIL here, and ops\prepush-test-auditors.ps1 counted it as a NEW failing case and refused most first
  # pushes from a fresh worktree for a reason unrelated to the change. A blind child is now a SKIP, counted as one,
  # and only when its ran + blind still add to the pinned 28: a blind line over a smaller suite is still lost fixtures.
  # 28 -> 31 (2026-10-02): three Get-FeedCovReadableVerdict cases (a run that read no card is BLIND, not clean). Verified before moving it: the child reports 30 of 31 ran + 1 BLIND unseeded, exit 0.
  $fcV = Get-FeedCovSelfTestVerdict -Rc $LASTEXITCODE -Text $r -Pinned 31
  if ($fcV.state -eq 'pass') {
    Ok 'feed-covers-published -SelfTest passes with its founding-bug fixtures armed (a published slug the feed does not carry, a bid in ingredients but not pricing_inputs, a present-but-zero-priced entry, and the allowlist pardoning only its own bid)'
  } elseif ($fcV.state -eq 'blind') {
    Skip ('feed-covers-published -SelfTest could not look: ' + $fcV.detail + ' - this checkout has no built card; run ops\seed-worktree.ps1 -Target <this checkout>. Not a pass')
  } else { Bad ('feed-covers-published -SelfTest failed or lost its founding-bug fixtures: ' + (($r -split "`r?`n" | Where-Object { $_ -match 'FAIL|SELFTEST' }) -join ' | ')) }

  # THE SEAL, asserted HERE so it is independent of the file being checked. The guard is worth nothing as a
  # publish-day gate unless the publish chain actually runs it, and unless it runs BEFORE the publish stage:
  # after it, the recipe is already live and the reader has already seen the broken cost section.
  $prSrc = Get-Content (Join-Path $mpPipe 'propagate-recipes.ps1') -Raw
  if ($prSrc -match 'feed-covers-published\.ps1' -and $prSrc -match '(?s)feed-covers-published\.ps1.*publish\.ps1') {
    Ok 'the publish chain still runs feed-covers-published, and still runs it BEFORE publish'
  } else { Bad 'propagate-recipes.ps1 no longer gates on feed-covers-published.ps1 before publishing - a recipe can go live again while the feed its own card fetches cannot price it' }

  # COMPLETION AND VERDICT ARE DIFFERENT QUESTIONS (lib\guard-contract.ps1). The chain must reject a guard
  # that died mid-run rather than read its silence as "found nothing".
  if ($prSrc -match 'Test-GuardComplete' -and $prSrc -match "FEEDCOV") {
    Ok 'the publish chain requires the FEEDCOV completion marker, so a guard that dies is not read as clean'
  } else { Bad 'propagate-recipes.ps1 no longer checks the FEEDCOV completion marker - a feed-coverage guard that crashes mid-run would be indistinguishable from one that found nothing' }

  # THE PRODUCTION REFUSAL, END TO END. Everything above tests judgement or source; this runs the REAL guard
  # against a feed with pricing_inputs stripped and requires a findings exit that still carries the marker.
  $fcTmp = Register-Fx (Join-Path $env:TEMP ('feedcov-stripped-' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.json'))
  # LIVE-TWIN (2026-09-11): the real guard on the real feed, stripped of pricing_inputs; run only when the feed is here.
  $fcCanon = Join-Path $root 'out\smp-feed.json'
  if (Test-Path $fcCanon) {
    try {
      $fcDoc = Get-Content $fcCanon -Raw -Encoding utf8 | ConvertFrom-Json
      $fcDoc.PSObject.Properties.Remove('pricing_inputs')
      [IO.File]::WriteAllText($fcTmp, ($fcDoc | ConvertTo-Json -Depth 8 -Compress))
      $fcOut = PSChild $fcp -FeedPath $fcTmp | Out-String
      $fcRc = $LASTEXITCODE
      if ($fcRc -eq 1 -and $fcOut -match 'FEEDCOV-COMPLETE') {
        Ok 'feed-covers-published REFUSES a feed with pricing_inputs stripped end to end (exit 1) and still reports completion'
      } elseif ($fcRc -eq 3 -and $fcOut -match 'FEEDCOV-COMPLETE could not evaluate') {
        # A could-not-look is never a pass and never a failure (2026-09-19): a checkout with the feed and no published
        # set cannot ask the question, and the guard says so in its own marker. Counted, named, and not a pass.
        Skip ('feed-covers-published end-to-end refusal (the guard could not evaluate here: ' + (($fcOut -split "`n" | Where-Object { $_ -match 'FEEDCOV' } | Select-Object -Last 1) -replace '\s+$', '') + ')')
      } else { Bad ("feed-covers-published did NOT refuse a feed stripped of pricing_inputs (exit $fcRc) - the check that a live card can be priced is not actually firing") }
    } catch { Bad ('feed-covers-published end-to-end refusal could not be evaluated: ' + $_.Exception.Message) }
    finally { Remove-Item $fcTmp -Force -ErrorAction SilentlyContinue }
  } else { Skip 'feed-covers-published end-to-end refusal (no grocery\out\smp-feed.json on this machine)' }
}
} # u121-feed-coverage-of-what-is-published

# ---------------------------------------------------------------- specs\prose re-sync (2026-08-02, L4)
# THE ONE WATCHER WHOSE FAILURE IS A REVERT RATHER THAN A WRONG NUMBER. spec-guards.ps1 full mode does not
# read prose to CHECK it - it MERGES specs\prose\prose-<slug>.json INTO the spec and validates the result.
# That is right while the prose file is the writer's copy; the 2026-07-26 cost redesign inverted it, three
# writer waves re-anchored prose directly in the SPECS, and nothing wrote it back. Measured before the fix:
# ALL 400 slugs holding both files would have been overwritten by ONE full run - 400 upsell_html, 400
# cost_closing_html, 362 head.description, 325 intro_html - and three of them would have had their deleted
# shop_smart dollar figures put back. There is no partial version of that failure.
if (Use-Unit 'u122-specs-prose-re-sync' -Reads 'meal-prep/db/recipes/*.json') { # reach-fixture-ok: a selection pattern matched against pushed paths; nothing here opens a meal-prep file
$mpPipe = Join-Path (Split-Path $root -Parent) 'meal-prep\pipeline'
$sps = Join-Path $mpPipe 'sync-prose-from-spec.ps1'
if (-not (Test-Path $sps)) { Bad 'sync-prose-from-spec.ps1 is missing - nothing keeps specs\prose in step with the specs, and a full spec-guards run silently reverts the cost redesign' }
else {
  # THE VERDICT AND THE EXIT CODE, BOTH (2026-09-11). This site and the six meal-prep repair sites below it read only
  # the child's verdict line, so a suite that printed SELF-TEST PASS and then died, or fell through into a path that
  # exits non-zero, still passed. Each child was run once that day: all seven exit 0 on a pass and print the matched
  # text exactly once, as their verdict. $LASTEXITCODE survives the Out-String, as feed-freshness' check above relies on.
  $r = PSChild $sps -SelfTest | Out-String
  if ($LASTEXITCODE -eq 0 -and $r -match 'SELF-TEST PASS') { Ok 'prose-sync: still writes spec -> prose only, still refuses to blank a field the spec lost, and its -Check still fires on a re-drifted file' }
  else { Bad ('sync-prose-from-spec -SelfTest failed (rc=' + $LASTEXITCODE + '): ' + ($r -replace "`n", ' ')) }

  $chk = PSChild $sps -AllRuns -Check | Out-String
  # SCOPE, stated in the label because the first version of it over-claimed: these prose files belong to
  # the ARCHIVE run snapshots. db\recipes (the layer engine\build-cards renders from) has no prose dir, so
  # full-mode spec-guards cannot run against it and cannot revert a live card.
  if ($LASTEXITCODE -eq 0 -and $chk -match 'CHECK OK') { Ok 'specs\prose matches its spec in every archived run - a full spec-guards run on a run dir cannot revert that run''s record' }
  else { Bad ('specs\prose has DRIFTED from the specs. spec-guards FULL mode merges prose INTO the spec, so the next full run overwrites the specs with older text, on every drifted slug at once. Run meal-prep\pipeline\sync-prose-from-spec.ps1 -AllRuns. ' + (($chk -split "`r?`n" | Where-Object { $_ -match 'CHECK FAIL' }) -join ' ')) }

  # THE TWO FIELD LISTS MUST STAY EQUAL. sync-prose-from-spec copies exactly the fields spec-guards merges;
  # if that merge grows a field and the sync does not, the new field reverts on every run and nothing above
  # would notice, because both sides would agree about the fields they DO know.
  $sgSrc = Get-Content (Join-Path $mpPipe 'spec-guards.ps1') -Raw
  $spSrc = Get-Content $sps -Raw
  $sgFields = @([regex]::Matches($sgSrc, "foreach\(\`$k in @\('intro_html'[^)]*\)") | ForEach-Object { $_.Value })
  $missing = @()
  foreach ($f in @('intro_html','cost_closing_html','portion_html','upsell_html','shop_smart','make_it','description','keywords','prepTime','cookTime','totalTime','recipeIngredient','steps')) {
    if ($sgSrc -match [regex]::Escape("'$f'") -and $spSrc -notmatch [regex]::Escape("'$f'")) { $missing += $f }
  }
  if ($missing.Count -eq 0) { Ok 'prose-sync covers every field spec-guards merges (no field can revert unwatched)' }
  else { Bad ('spec-guards merges field(s) that sync-prose-from-spec does not copy, so those fields revert on every full run and the drift check cannot see it: ' + ($missing -join ', ')) }

  # ------------------------------------------------------- spec self-contradictions (2026-08-02, L4)
  # A recipe spec that states the same fact twice and disagrees with itself is wrong no matter what the
  # source recipe says - and one of the two numbers is on a live card. Five writer agents found a handful
  # of these by hand while doing an unrelated job on 97 of 513 recipes; the same reading applied to every
  # spec found 138. A hand-compiled worklist is a coincidence, not a detector.
  $asc = Join-Path $mpPipe 'audit-spec-contradictions.ps1'
  $rsc = Join-Path $mpPipe 'repair-spec-contradictions.ps1'
  $r = PSChild $asc -SelfTest | Out-String
  if ($LASTEXITCODE -eq 0 -and $r -match 'SELF-TEST PASS') { Ok 'spec-contradictions: all five classes still fire on the frozen live cases, and a self-consistent spec still produces nothing' }
  else { Bad ('audit-spec-contradictions -SelfTest failed (rc=' + $LASTEXITCODE + '): ' + ($r -replace "`n", ' ')) }
  $r = PSChild $rsc -SelfTest | Out-String
  if ($LASTEXITCODE -eq 0 -and $r -match 'SELF-TEST PASS') { Ok 'contradiction repair: still refuses a two-quantity head line, "rice vinegar", and "wild rice" - and still matches "93/7 ground turkey" to its own line' }
  else { Bad ('repair-spec-contradictions -SelfTest failed (rc=' + $LASTEXITCODE + ') - a head ingredient line can be rewritten to the WRONG ingredient''s amount: ' + ($r -replace "`n", ' ')) }
  # BUY-COVERAGE's repair side (2026-08-15). The class fires on a cost line whose buy sentence disagrees
  # with the package the batch needs; this is the script that rewrites those sentences, and its fixtures
  # pin the two shapes plus the scope guard - a spec whose hand-written shop_smart uses the same words
  # must keep them, because the repair edits one array span and never the whole file.
  $rbb = Join-Path $mpPipe 'repair-bulk-buy-line.ps1'
  if (-not (Test-Path $rbb)) { Bad 'repair-bulk-buy-line.ps1 is missing - bulk cost lines can go back to telling every shopper one package "lasts several batches"' }
  else {
    $r = PSChild $rbb -SelfTest | Out-String
    if ($LASTEXITCODE -eq 0 -and $r -match 'all green') { Ok 'bulk buy line: a 1.88-batch box no longer reads "lasts several batches", a 14.8-batch bottle still does, and writer prose is never rewritten' }
    else { Bad ('repair-bulk-buy-line -SelfTest failed (rc=' + $LASTEXITCODE + ') - the buy sentence can drift from the package the recipe actually needs: ' + ($r -replace "`n", ' ')) }
  }

  $r = (Get-Early 'early:spec-live' $asc @('-Quiet', '-ReportDir', $script:SpecLiveReportDir)).text
  if ($LASTEXITCODE -eq 0) { Ok 'no recipe spec contradicts itself worse than the recorded baseline (stat-vs-prose, stale money, head quantities, buy coverage all at ZERO)' }
  else { Bad ('a spec-contradiction class got WORSE: ' + (($r -split "`r?`n" | Where-Object { $_ -match 'FAIL' }) -join ' ')) }

  # ------------------------------------------------- cook measures, not purchase labels (2026-08-02)
  # Brad, from one card: "the ingredients section should only list what we need to COOK the recipe, not
  # what to purchase". The list was printing the purchase label, so 120 g of soy sauce read "1 bottle" and
  # 90 g of brown sugar read "1 bag". Measured across 513 specs: 6,999 ingredient lines, 459 of them a
  # package noun that does not weigh what the recipe uses. The fixtures below pin BOTH halves of the fix -
  # the rewrite itself, and the serving scaler that re-renders these labels in the browser.
  $rcm = Join-Path $mpPipe 'repair-cook-measures.ps1'
  if (-not (Test-Path $rcm)) { Bad 'repair-cook-measures.ps1 is missing - the ingredients list can go back to naming packages a cook cannot measure' }
  else {
    $r = PSChild $rcm -SelfTest | Out-String
    if ($LASTEXITCODE -eq 0 -and $r -match 'SELF-TEST PASS') { Ok 'cook measures: a package noun that cannot prove it equals the grams is still replaced, a whole can is still left alone, and a WEIGHT label is still out of scope' }
    else { Bad ('repair-cook-measures -SelfTest failed (rc=' + $LASTEXITCODE + '): ' + ($r -replace "`n", ' ')) }

    $r = PSChild $rcm | Out-String
    $n = 0
    $m = [regex]::Match($r, 'cook-measure repair: (\d+) false label')
    if ($m.Success) { $n = [int]$m.Groups[1].Value }
    if ($n -eq 0) { Ok 'no ingredient line names a package the recipe does not actually use (0 false labels across 513 specs)' }
    else { Bad ("$n ingredient line(s) again state a package quantity the recipe does not use - the Ingredients list is telling a cook to measure out a bottle or a bag. Run meal-prep\pipeline\repair-cook-measures.ps1 -Apply, then rebuild and republish those cards.") }

    # THE BROWSER HALF. The PowerShell twin is what the fixture can run; this pins the JS it mirrors, so a
    # future edit to the template cannot quietly restore the multiply-every-number behaviour that turned
    # "1/2 tsp" into "2/4 tsp" the moment a reader changed the serving count.
    $tpl = Get-Content (Join-Path $mpPipe 'tpl2-scaler-prefix.html') -Raw
    if (($tpl -match 'function parseQty') -and ($tpl -match 'function fmtCook') -and ($tpl -notmatch 'buy\.replace\(/\\d\+')) {
      Ok 'serving scaler still scales only the leading quantity and understands fractions (the JS matches its PowerShell twin)'
    } else { Bad 'tpl2-scaler-prefix.html no longer carries the fraction-aware scaleBuy - changing the servings will render "2/4 tsp" again' }

    # ------------------------------------------------ RANGE labels (2026-08-04)
    # The one label shape the scaler above cannot render honestly no matter how carefully it is written.
    # "<quantity> <unit> <note>" is the premise scaleBuy depends on; a range puts a second number where
    # the unit belongs, so "2-3 cloves" doubled renders "4-3 cloves". Ten shipped that way, and nine of
    # the ten were ALREADY wrong standing still - the range was the source recipe's amount at the
    # SOURCE's serving count sitting beside Brad's scaled gram figure, so the garlic line said 2-3 cloves
    # over 42 g of garlic, which is 8. Nothing detected them: repair-cook-measures scopes itself to
    # package nouns on purpose, and Get-CmUnit's pattern is anchored and reads no unit past a dash, so a
    # range reports no unit at all and passes Test-CmLabelTrue as "not provably false".
    $rrb = Join-Path $mpPipe 'repair-range-buy.ps1'
    if (-not (Test-Path $rrb)) { Bad 'repair-range-buy.ps1 is missing - a range label can ship again and the servings control will render "4-3 cloves"' }
    else {
      $r = PSChild $rrb -SelfTest | Out-String
      if ($LASTEXITCODE -eq 0 -and $r -match 'SELF-TEST PASS') { Ok 'range labels: the founding garlic case still resolves to the grams, a range with an unweighable unit is still REFUSED rather than guessed, and "12-oz bag" is still not a range' }
      else { Bad ('repair-range-buy -SelfTest failed (rc=' + $LASTEXITCODE + '): ' + ($r -replace "`n", ' ')) }

      $r = PSChild $rrb | Out-String
      $n = -1
      $m = [regex]::Match($r, 'range-buy repair: (\d+) label')
      if ($m.Success) { $n = [int]$m.Groups[1].Value }
      if ($n -eq 0) { Ok 'no ingredient line states a range where the quantity belongs (the serving scaler can render every label in the catalog)' }
      elseif ($n -lt 0) { Bad ('repair-range-buy did not report a count - the guard cannot tell a clean catalog from a broken run: ' + ($r -replace "`n", ' ')) }
      else { Bad ("$n ingredient line(s) state a RANGE where the quantity belongs. Changing the servings will render nonsense like ""4-3 cloves"", and the label is probably the source recipe's amount at the source's serving count rather than this batch's. Run meal-prep\pipeline\repair-range-buy.ps1 -Apply, then sync-recipesdb-buy.ps1 -Apply, gen-planner-data.ps1, and rebuild + republish those cards.") }
    }

    # ---------------------------------- the SECOND copy of every one of those labels (2026-08-04)
    # THE CHECK ABOVE READ GREEN FOR TWO DAYS WHILE THE SITE WAS WRONG, and it was not lying: the specs
    # really were clean. recipes-db.json keeps its own copy of every ingredient's buy string,
    # gen-planner-data.ps1 is built from THAT copy, and the 2026-08-02 repair never reached it - so the
    # Meal Plan Builder's merged grocery list went on telling members to buy "2 cans" of beans the specs
    # had already restated as 5 1/4 cups. Nothing compared the two: engine\audit-db-agreement.ps1 checks
    # slug and protein, not labels. "The source of truth is clean" is not the same claim as "every copy
    # agrees with it", and only the second one is what a member reads.
    $srb = Join-Path $mpPipe 'sync-recipesdb-buy.ps1'
    if (-not (Test-Path $srb)) { Bad 'sync-recipesdb-buy.ps1 is missing - a spec label repair now has no path into recipes-db, and the Meal Plan Builder reads recipes-db' }
    else {
      $r = PSChild $srb -SelfTest | Out-String
      if ($LASTEXITCODE -eq 0 -and $r -match 'SELF-TEST PASS') { Ok 'recipes-db buy sync: both carry classes still fire on their frozen cases, and a true package noun, a hand-edited spec, a measure-vs-grams defect and disagreeing grams are all still refused' }
      else { Bad ('sync-recipesdb-buy -SelfTest failed (rc=' + $LASTEXITCODE + ') - the only path a label repair has into recipes-db: ' + ($r -replace "`n", ' ')) }

      $r = PSChild $srb | Out-String
      $m = [regex]::Match($r, 'recipes-db buy sync: (\d+) label')
      if (-not $m.Success) { Bad ('could not read a label count out of sync-recipesdb-buy - the check cannot tell clean from broken: ' + ($r -replace "`n", ' ')) }
      elseif ([int]$m.Groups[1].Value -eq 0) { Ok "recipes-db states the same ingredient label as its spec everywhere the difference is a known repair class (the Meal Plan Builder's grocery list matches the recipe cards)" }
      else { Bad ("$([int]$m.Groups[1].Value) ingredient label(s) in recipes-db.json still disagree with their spec in a class we know how to carry - the Meal Plan Builder's merged grocery list is printing pre-repair text. Run meal-prep\pipeline\sync-recipesdb-buy.ps1 -Apply, then meal-prep\gen-planner-data.ps1.") }
    }
  }

  # ------------------------------------------- the gates that stop this recurring (2026-08-02)
  # The retrospective on the whole day: the pipeline derives TWO artifacts from one source - the ingredient
  # mapper's costed list and the writer's steps - and NOTHING EVER COMPARED THEM. That is a defect
  # generator, not an agent being careless, and better instructions would not have caught it. So the
  # invariants moved into spec-guards, the gate every new recipe must pass before it can publish.
  $rcl = Join-Path $mpPipe 'recipe-coherence-lib.ps1'
  $sg = Join-Path $mpPipe 'spec-guards.ps1'
  if (-not (Test-Path $rcl)) { Bad 'recipe-coherence-lib.ps1 is missing - nothing stops a new recipe shipping with ingredients no step uses' }
  else {
    . $rcl
    # MUST FIRE: the founding case. Rice vinegar bought, never mentioned in a step.
    $bad = [pscustomobject]@{
      make_it = @('Weigh your empty mixing pot.', 'Add the chicken, hoisin, soy sauce and garlic to the slow cooker.', 'Cook on low for 6 hours.')
      head = [pscustomobject]@{ steps = @('Combine and cook.') }
      scaler = [pscustomobject]@{ ing = @(
        [pscustomobject]@{ item = 'Boneless Skinless Chicken Breast' },
        [pscustomobject]@{ item = 'Hoisin Sauce' },
        [pscustomobject]@{ item = 'Rice Vinegar' },
        [pscustomobject]@{ item = '93/7 Ground Beef' }
      ) }
    }
    $un = @(Get-RcUnusedIngredients $bad)
    if (($un -contains 'Rice Vinegar') -and ($un -contains '93/7 Ground Beef') -and $un.Count -eq 2) {
      Ok 'unused-ingredient gate: still catches a bought-but-never-cooked ingredient, and still credits "shred the chicken" for the chicken breast'
    } else { Bad ('the unused-ingredient gate has drifted - flagged [' + ($un -join ', ') + '] (want exactly Rice Vinegar + 93/7 Ground Beef)') }

    # CLEAN TWIN: a step that names the food loosely must NOT be accused. "brown the beef" uses "93/7
    # Ground Beef"; a gate that demands the step echo "93/7" or "ground" flags every correct recipe.
    $good = [pscustomobject]@{
      make_it = @('Brown the beef and drain it.', 'Stir in the hoisin and the vinegar.', 'Shred the chicken into the sauce.')
      head = [pscustomobject]@{ steps = @('Cook.') }
      scaler = [pscustomobject]@{ ing = @(
        [pscustomobject]@{ item = '93/7 Ground Beef' },
        [pscustomobject]@{ item = 'Hoisin Sauce' },
        [pscustomobject]@{ item = 'Rice Vinegar' },
        [pscustomobject]@{ item = 'Boneless Skinless Chicken Breast' }
      ) }
    }
    if (@(Get-RcUnusedIngredients $good).Count -eq 0) { Ok 'unused-ingredient gate CLEAN TWIN: loose but genuine step wording is never accused' }
    else { Bad ('the gate cries wolf on correct recipes: ' + ((Get-RcUnusedIngredients $good) -join ', ')) }

    # MUST FIRE: presence is not a value. This is the exact shape that let 113 recipes publish uncredited.
    $empty = [pscustomobject]@{ name = 'X'; slug = 'x'; source_url = ''; source_site = ''; credit_html = ''
      intro_html = 'i'; portion_html = 'p'; cost_closing_html = 'c'; upsell_html = 'u'
      head = [pscustomobject]@{ description = 'd'; keywords = 'k'; prepTime = 'PT1M'; cookTime = 'PT2M'; totalTime = 'PT3M' } }
    $ef = @(Get-RcEmptyRequired $empty)
    if (($ef -contains 'source_url') -and ($ef -contains 'credit_html')) { Ok 'empty-required gate: an EMPTY source_url no longer passes for a present one (the 113-uncredited-recipes hole)' }
    else { Bad ('the empty-required gate missed an empty source_url/credit_html: ' + ($ef -join ', ')) }

    $sgSrc = Get-Content $sg -Raw
    if (($sgSrc -match 'Get-RcUnusedIngredients') -and ($sgSrc -match 'Get-RcEmptyRequired')) {
      Ok 'spec-guards ENFORCES both gates, so a new recipe cannot publish with ingredients no step uses or an empty credit'
    } else { Bad 'spec-guards no longer calls the coherence gates - the checks exist but nothing runs them before publish' }
  }
}
} # u122-specs-prose-re-sync

# ---------------------------------------------------------------- identity eval set (2026-08-02, L1)
# The sidecar's identity lane stays OFF until it beats a HARD eval, and Phase 1's eval was not hard: all
# 25 of its negatives are dramatically wrong (bath soap as coconut oil), so it never asked the model to
# tell a wiener from a hot dog. export-identity-eval.ps1 builds the harder set, and the rule that keeps it
# honest is the one pinned here - a pair may only be MINED as a negative when the candidate commodity's
# own regex REJECTS the product. A rule-accepted product is contested, not clean, and labelling it either
# way teaches the eval a lie. The regex verdict stays in PowerShell for the same reason the sweep does:
# Python must never re-implement the corpus rules.
if (Use-Unit 'u123-identity-eval-set') {
$eie = Join-Path $root 'export-identity-eval.ps1'
if (-not (Test-Path $eie)) { Bad 'export-identity-eval.ps1 is missing - the identity lane has no hard eval to be measured against, and the only remaining evidence is the AUC 0.985 that was measured on dramatic errors' }
else {
  $r = RunPS 'export-identity-eval.ps1' @('-SelfTest')
  if ($r.rc -eq 0 -and $r.text -match 'SELF-TEST PASS') { Ok 'identity eval: an EXCLUDE still overrides an include, and a rule-ACCEPTED product still cannot be mined as a clean negative' }
  else { Bad ('export-identity-eval -SelfTest failed (rc=' + $r.rc + ') - the hard-negative labelling rule is broken, so any AUC measured with it is meaningless: ' + ($r.text -replace "`n", ' ')) }
}
} # u123-identity-eval-set
# ---------------------------------------------------------------- ad-page install contract (2026-08-09)
# FOUNDING BUG: pull-fareway-ads.ps1 downloaded flyer pages straight into out\fareway\weekly\ and never
# cleared it. The 2026-08-02..08 ad had 24 pages, the 2026-08-09..15 ad has 22, so weekly-23.jpg and
# weekly-24.jpg from the EXPIRED ad stayed on disk - and the documented vision-read step globs
# out\fareway\weekly\*.jpg, so a closed ad's prices could be read as current. weekly-23.jpg was
# vision-confirmed as page 23 of the old ad. It is the expired-ad-supplement class ruled on 2026-08-07,
# except it bypasses that guard entirely: the stale data arrives as an IMAGE, before any ad_to exists.
# The self-test drives regression-inputs\guard-fixtures\adpages-shrink.json (frozen at 24 -> 22).
# MUTATION-PROVEN 2026-08-09: deleting the clear step took 3 cases red, blinding the orphan check took the
# must-fire case red, and restoring the library went green again.
if (Use-Unit 'u124-ad-page-install-contract') {
$r = RunPS 'pull-fareway-ads.ps1' @('-SelfTest')
if ($r.rc -eq 0 -and $r.text -match 'SELFTEST PASS') {
  Ok 'ad-page install: a 22-page ad over a 24-page one leaves NO orphan pages, and a partial download refuses to half-swap'
} else { Bad ('pull-fareway-ads -SelfTest failed (rc=' + $r.rc + ') - a shrinking flyer can strand an expired ad''s pages where the vision read will treat them as current: ' + ($r.text -replace "`n", ' ')) }

# SOURCE ASSERTION - a guard cannot detect its own unsealing (the [[guard-fixture-rule]] lesson). The
# self-test above exercises adpages-lib directly, so it stays green even if a puller stops CALLING the lib
# and goes back to downloading in place. Assert the callers instead: both image pullers must dot-source the
# library, and neither may point -OutFile at anything but a staging path.
foreach ($p in @('pull-fareway-ads.ps1', 'pull-bakers.ps1')) {
  $ps = Join-Path $root $p
  if (-not (Test-Path $ps)) { Bad ($p + ' is missing - the ad-page install contract has no caller to enforce'); continue }
  $src = Get-Content $ps -Raw
  # \b on each call, not a bare substring: a renamed-out stub (Install-AdPagesDISABLED) satisfies a
  # substring match while calling nothing, which is exactly how an unsealing would look in a diff.
  $callsLib = ($src -match 'adpages-lib\.ps1') -and ($src -match 'Install-AdPages\b') -and ($src -match 'New-AdStagingDir\b')
  # Every download in these scripts must land in staging, never in the live page dir. The target is often
  # an indirection (-OutFile $o), so a bare variable is resolved back to its own assignment before it is
  # judged - otherwise this check fails the very scripts it is meant to protect.
  $badOut = @()
  foreach ($m in @([regex]::Matches($src, '-OutFile\s+(\([^)]*\)|\$\w+|\S+)'))) {
    $arg = $m.Groups[1].Value
    if ($arg -match '(?i)staging') { continue }
    if ($arg -match '^\$(\w+)$') {
      $vn = $Matches[1]
      if ($src -match ('\$' + [regex]::Escape($vn) + '\s*=[^\r\n]*(?i)staging')) { continue }
    }
    $badOut += $arg
  }
  if ($callsLib -and $badOut.Count -eq 0) {
    Ok ($p + ' still stages its downloads and installs through adpages-lib (clear-then-swap intact)')
  } else {
    $why = @()
    if (-not $callsLib) { $why += 'no longer installs via adpages-lib' }
    if ($badOut.Count)  { $why += ('downloads outside staging: -OutFile ' + ($badOut -join ', -OutFile ')) }
    Bad ($p + ' has been unsealed - ' + ($why -join '; ') + ' - the shrinking-ad orphan bug is reachable again')
  }
}
} # u124-ad-page-install-contract

# (k1f) PULL PACING IS VERSIONED DATA, NOT A NUMBER IN A CONSOLE SNIPPET (2026-08-15). The Sam's sweep ran
# unpaced and tripped the bot wall after 207 of 595 (id,term) pairs; the rate that would have prevented it
# lived nowhere on disk. Pacing now lives in stores.json -> pull_profile and each walled store's browser
# agent mirrors its own constants (the console cannot read a file). That duplication is only safe while
# something compares the two, which is what audit-pull-profiles does - it caught Aldi's agent carrying an
# unmirrored 900ms the first time it ran. It also blocks the dangerous shape: a profile must record HOW to
# pull and never WHAT a store carries, because a term learned "empty" during a wall would stop being
# checked forever, and unchecked is never not-carried.
if (Use-Unit 'u125-k1f-pull-pacing-is-versioned-data') {
$r = RunPS 'audit-pull-profiles.ps1' @('-SelfTest')
if ($r.rc -eq 0 -and $r.text -match 'MUST-FIRE' -and $r.text -match 'all self-tests pass') {
  Ok 'audit-pull-profiles -SelfTest passes with its drift + carriage fixtures armed'
} else {
  Bad ('audit-pull-profiles -SelfTest failed or lost its founding-bug fixtures: ' + ((($r.text -split "`n") | Select-Object -Last 3) -join ' | '))
}
# LIVE-TWIN, DELIBERATELY (labelled 2026-09-06, PLAN-top5 area 4 §4.4): this compares the SHIPPED
# pull-profile registry against the SHIPPED agent modules. Freezing either half would prove the comparison
# works and prove nothing about production, which is the one thing this case is for.
$r = RunPS 'audit-pull-profiles.ps1' @()
if ($r.rc -eq 0) { Ok 'LIVE-TWIN pull-profiles: every store pull_profile agrees with its agent module' }
else { Live ('LIVE-TWIN pull-profiles: drift, or a profile encoding carriage - this reads the LIVE registry and the LIVE modules: ' + ((($r.text -split "`n") | Select-Object -First 6) -join ' | ')) }
} # u125-k1f-pull-pacing-is-versioned-data

# ---------------------------------------------------------------- rollback TTL ledger (2026-08-21)
# Brad: "for walmart and sams, a rollback price we just stick with a 30 day TTL from when we first
# detect". The whole difficulty is in FIRST. A rollback is re-observed on every capture covering its
# term, so an anchor that re-stamps on each sighting makes the TTL infinite while reading as governed.
# test-rollback-ttl.ps1 carries the must-fire fixture for exactly that.
if (Use-Unit 'u126-rollback-ttl-ledger') {
$r = RunPS 'test-rollback-ttl.ps1' @()
if ($r.rc -eq 0 -and $r.text -match 'ROLLBACK-TTL PASSED') { Ok 'rollback TTL: first_seen anchors once and never re-anchors on re-sighting' }
else { Bad ('rollback TTL fixtures FAILED (rc=' + $r.rc + ') - a 30-day window that re-anchors never expires') }
} # u126-rollback-ttl-ledger

# ---------------------------------------------------------------- the 2026-08-22 engine-review fixes
# Each of these carries a MUST-FIRE that fails on the pre-fix code (verified against HEAD~ copies on the day
# they shipped) and clean twins for what had to keep working. Wired here so a quiet suite proves they still run.
if (Use-Unit 'u127-the-2026-08-22-engine-review-fixes') {
$r = RunPS 'test-ad-match.ps1' @()
if ($r.rc -eq 0 -and $r.text -match 'AD-MATCH PASSED') { Ok 'ad-match: same-price candidates are scored, a cell cannot inherit another product''s window, the terse butter line still traces' }
else { Bad ('test-ad-match FAILED (rc=' + $r.rc + ') - a sale cell can again take the window of whichever same-price ad line comes first: ' + (($r.text -split "`n" | Where-Object { $_ -match 'FAIL' } | Select-Object -First 3) -join ' | ')) }
$r = RunPS 'test-capture-policy.ps1' @()
if ($r.rc -eq 0 -and $r.text -match 'CAPTURE-POLICY PASSED') { Ok 'sale-expiry slice - an expiring sale''s terms/products are IN the headless lanes'' slice, not merely budgeted for' }
else { Bad ('test-capture-policy FAILED (rc=' + $r.rc + ') - sale-expiry re-pricing no longer reaches the slice: ' + (($r.text -split "`n" | Where-Object { $_ -match 'FAIL' } | Select-Object -First 3) -join ' | ')) }
$r = RunPS 'test-pu-lib.ps1' @()
if ($r.rc -eq 0 -and $r.text -match 'PU-LIB PASSED') { Ok 'pu-lib: frozen per-unit values hold (fractions, x-packs, litre/ml/qt multipacks, pack count over per-each marker)' }
else { Bad ('test-pu-lib FAILED (rc=' + $r.rc + ') - the shared per-unit math regressed against its frozen values: ' + (($r.text -split "`n" | Where-Object { $_ -match 'FAIL' } | Select-Object -First 3) -join ' | ')) }
$r = RunPS 'pull-regular-hyvee.ps1' @('-SelfTest')
if ($r.rc -eq 0 -and $r.text -match 'SELF-TEST PASS') { Ok 'pull-regular-hyvee -SelfTest: a carried markdown keeps its discount fields; an ended sale reverts to everyday at base_price' }
else { Bad ('pull-regular-hyvee -SelfTest failed (rc=' + $r.rc + ') - the Hy-Vee carry can launder a markdown into an everyday price again: ' + (($r.text -split "`n" | Where-Object { $_ -match 'FAIL' } | Select-Object -First 3) -join ' | ')) }
} # u127-the-2026-08-22-engine-review-fixes

# ---------------------------------------------------------------- Hy-Vee shelf tag + store identity (2026-08-21)
# Brad checked four Hy-Vee cells against his own screen and all four disagreed. Two causes, and the
# second one no guard here could see: storeProducts.price - the field every guard in this estate reads -
# can sit BELOW retailItems.ecommerceTagPrice, the shelf tag. Morton & Bassett sesame seed published at
# $5.31 against a $9.99 tag, as a 47% markdown, with every check green. The fixture freezes that row.
# It also sweeps every production script for the RETIRED Omaha #01 identity: that identity lived in six
# files while stores.json carried none of it, so switching stores meant editing six and hoping. The sweep
# caught four files missed on its first run, which is why it is a fixture and not a comment.
# ---------------------------------------------------------------- the wide price table (2026-08-21)
# Brad's model: one row per item, every store's everyday price and ad price as columns, page shows the
# cheaper, and the ad column NULLS OUT when its window closes so a finished sale expires by arithmetic
# instead of waiting for the 90-day rotation to come back round. His three non-negotiables are three
# separate fixtures - ad must never become everyday, everyday must never become an ad, and an ad must
# be null when there is no ad. The file also proves the parity check can FAIL, because a parity check
# that cannot fail makes "derived from the same rows" read as "verified".
# ---------------------------------------------------------------- captured-but-unpublished (2026-08-21)
# Brad: "we need to make sure that when we pull pricing, from ANY part of our codebase, its populating
# the table correctly." It was not. The Recipe Hunter's pricing agent records real adjudicated prices
# into ingredient-queue.json and NOTHING promotes them - 97 of 99 had reached nothing since 2026-08-16.
# No existing guard could see it: every other one starts from the board and asks whether what is on it
# is right, so a price that never arrives is invisible by construction.
# ---------------------------------------------------------------- graph gates (graduated 2026-08-21)
# graph\ now CHECKS the live board. The fixture's must-fire is a parser one, and it is the right thing
# to freeze: if the parser silently drops a FAIL line, this whole check reports clean forever - the
# worst possible failure mode for a guard, and invisible from the outside. Its clean twins keep the
# block from over-reading (a later report section must not be mistaken for a gate) and keep an
# unrecognised verdict from being read as a pass, because unknown is not a pass.
# ---------------------------------------------------------------- the everyday/sale split (wired 2026-08-21)
# price-split-lib has carried a full self-test since it was written, and NOTHING CALLED IT - the
# fixtures for the rule Brad called non-negotiable had never been executed by this suite, on the
# function whose first live outing re-typed 357 board cells and moved 27 Cheapest crowns.
# It now also covers Fareway's stated countdown ("Sale ends in N days"), whose must-not-drift case is
# the important one: the window is anchored to the CAPTURE date, so the same row read a week later
# still ends on the same day. Anchored on today instead, a sale would never end.
# ---------------------------------------------------------------- the precompiled matcher (2026-08-22)
# compare-deals' hot loop now runs match-lib instead of Match-Category: same decision, 17x faster (139s
# of a 159s build was 45.7 million interpreted `-match` calls). A second copy of THE rule that decides
# which product owns a cell is only tolerable because this harness extracts the original verbatim from
# compare-deals.ps1 on every run and demands identical answers over every distinct name in the live
# pool - both the compiled path and the PowerShell fallback. Zero divergences or the suite goes red.
if (Use-Unit 'u128-the-precompiled-matcher') {
$r = Get-Early 'early:match-lib' (Join-Path $root 'test-match-lib.ps1') @('-Quiet')
if ($r.rc -eq 0 -and $r.text -match 'MATCH-LIB PASSED') { Ok 'match-lib decides identically to the original Match-Category on every distinct product name (compiled path and fallback)' }
# LOAD-BLIND IS A SKIP, NEVER A PASS AND NEVER A BLIND WATCHER (2026-10-02, queue 2026-09-27-ae8b7a part b). This suite
# runs inside the daily chain, so a chain-peak storm read as a drifted matcher. test-match-lib now says BLIND (rc 3) only
# when every red is a still-blind name AND more blind looks recovered on the re-look than stayed blind; that is counted
# on the SKIP line of both summaries. DRIFT, UNRECORDED and a still-blind name with no recovery beside it still FAIL.
elseif ($r.rc -eq 3 -and $r.text -match 'MATCH-LIB BLIND \(load') { Skip ('test-match-lib could not evaluate under load (rc 3), proved nothing this run: ' + (($r.text -split "`n" | Where-Object { $_ -match '^MATCH-LIB BLIND' } | Select-Object -First 1) -join '')) }
else { Bad ('test-match-lib FAILED (rc=' + $r.rc + ') - the fast matcher has drifted from the reference, so the board may be assigning products to the wrong commodity: ' + (($r.text -split "`n" | Where-Object { $_ -match 'FAIL|diverg' } | Select-Object -First 4) -join ' | ')) }

# THE SECOND COPY OF THE EXCLUDE RULE, PROVEN AGAINST THE FIRST (2026-09-19, plan L2 phase 0).
# commodity-rules-lib composes "own + global minus relaxed" so the 33 scripts that read .exclude can stop
# each composing it by hand - 17 of them by not composing it at all. A rule that exists twice drifts
# silently, so the accessor is checked against match-lib's own matcher over live capture names: the same
# discipline this file applies to the matcher's second copy just above. Read the exit code AND the
# verdict, because a suite that dies before printing exits non-zero with no verdict line and either test
# alone would pass it.
$r = RunPS 'test-commodity-rules-lib.ps1' @()
if ($r.rc -eq 0 -and $r.text -match 'test-commodity-rules-lib self-test: PASS') { Ok 'commodity-rules-lib composes the same effective excludes match-lib enforces, over the live commodity set' }
else { Bad ('test-commodity-rules-lib FAILED (rc=' + $r.rc + ') - the exclude accessor disagrees with the engine, so any caller converted to it would apply different rules from the board: ' + (($r.text -split "`n" | Where-Object { $_ -match 'FAIL' } | Select-Object -Last 1) -join ' ')) }

$r = RunPS 'test-price-split.ps1' @()
if ($r.rc -eq 0 -and $r.text -match 'PRICE-SPLIT PASSED') { Ok 'price split: ad never becomes everyday, everyday never becomes an ad, and a stated countdown does not drift with the clock' }
else { Bad ('price-split fixtures FAILED (rc=' + $r.rc + ') - the everyday/ad separation or the stated sale window is wrong: ' + (($r.text -split "`n" | Where-Object { $_ -match 'FAIL' } | Select-Object -First 3) -join ' | ')) }

$r = RunPS 'audit-graph-gates.ps1' @('-SelfTest')
if ($r.rc -eq 0 -and $r.text -match 'SELF-TEST PASS') { Ok 'graph-gates: a failing gate survives parsing, a later section is not read as a gate, and an unknown verdict is not a pass' }
else { Bad ('audit-graph-gates -SelfTest failed (rc=' + $r.rc + ') - graph could report every board clean regardless of what its gates said: ' + ($r.text -replace "`n", ' ')) }
} # u128-the-precompiled-matcher

# ---------------------------------------------------------------- promoting queued prices (2026-08-21)
# The Recipe Hunter's agent had 99 adjudicated store prices in ingredient-queue.json reaching nothing.
# promote-ingredient-queue moves them into out\regular, which IS an engine input. Its -Apply stays a
# manual step (the commodity mapping is a human ruling), but its fixtures run here, and the must-fire is
# the one that matters: an UNRULED term must be skipped, never slugified into an id. "gruyere"
# slugifies to a perfectly plausible commodity id, which is exactly why inferring would be dangerous -
# a careless id splits a commodity already priced under another name.
if (Use-Unit 'u129-promoting-queued-prices' -Reads 'grocery/*.ps1') {
$r = RunPS 'promote-ingredient-queue.ps1' @('-SelfTest')
if ($r.rc -eq 0 -and $r.text -match 'SELF-TEST PASS') { Ok 'promote-queue: only RULED terms promote; an unruled term is skipped rather than guessed, and a price with no size is refused' }
else { Bad ('promote-ingredient-queue -SelfTest failed (rc=' + $r.rc + ') - queued prices could enter the board under a guessed commodity id: ' + ($r.text -replace "`n", ' ')) }

$r = RunPS 'audit-price-capture-reach.ps1' @('-SelfTest')
if ($r.rc -eq 0 -and $r.text -match 'SELF-TEST PASS') { Ok 'price-capture-reach: a captured price that reaches nothing is still reported, and reach is measured per CELL not per commodity' }
else { Bad ('audit-price-capture-reach -SelfTest failed (rc=' + $r.rc + ') - captured prices can go missing without anything counting them: ' + ($r.text -replace "`n", ' ')) }

$r = RunPS 'test-price-table.ps1' @()
if ($r.rc -eq 0 -and $r.text -match 'PRICE-TABLE PASSED') { Ok 'price table: the everyday/ad split holds in both directions, a closed ad nulls out, and parity can still see a disagreement' }
else { Bad ('price-table fixtures FAILED (rc=' + $r.rc + ') - the everyday/ad separation Brad called non-negotiable is not holding: ' + (($r.text -split "`n" | Where-Object { $_ -match 'FAIL' } | Select-Object -First 3) -join ' | ')) }

$r = RunPS 'test-hyvee-tag-check.ps1' @()
if ($r.rc -eq 0 -and $r.text -match 'HYVEE-TAG-CHECK PASSED') { Ok 'Hy-Vee: a price below the store shelf tag is still refused, a real promotion still is not, and no script is pinned to the retired store' }
else { Bad ('Hy-Vee tag/identity fixtures FAILED (rc=' + $r.rc + ') - either a price the till will not honour can publish again, or a caller is still pulling the retired Omaha #01: ' + (($r.text -split "`n" | Where-Object { $_ -match 'FAIL' } | Select-Object -First 3) -join ' | ')) }
} # u129-promoting-queued-prices
# ---------------------------------------------------------------- commodity rules (wired 2026-08-25)
# THE SAME ORPHAN STORY AS test-matcher-parity BELOW, and caught the same way. test-commodity-rules.ps1
# was written on 2026-08-24 - the day the Recipe Hunter's 6b run found that chicken-thighs carried
# exclude \b(drumsticks?)\b while its own label read 'Chicken Thighs / Drumsticks', so the board answered
# 'chicken drumsticks' with seven stores of THIGHS - and it shipped with NO caller at all: the script
# census listed it as an ORPHAN and guard-contract as DEAD. It asks the one question test-match-lib
# cannot: not 'do the two matcher implementations agree' but 'does this rule do what its own label says'.
# A frozen regression fixture nobody runs protects nothing, so it is called from here - the same home,
# and for the same reason, as every other fixture suite in this file.
if (Use-Unit 'u130-commodity-rules-wired-2026-08-25') {
$r = RunPS 'test-commodity-rules.ps1' @()
if ($r.rc -eq 0 -and $r.text -match 'test-commodity-rules: PASS') { Ok 'commodity rules: every frozen case still resolves the way its label says - the drumsticks-under-thighs class stays closed' }
else { Bad ('commodity-rule fixtures FAILED (rc=' + $r.rc + ') - a commodity include/exclude rule no longer does what its label claims, which is how the board served THIGHS for drumsticks: ' + (($r.text -split "`n" | Where-Object { $_ -match 'FAIL' } | Select-Object -First 3) -join ' | ')) }
} # u130-commodity-rules-wired-2026-08-25
