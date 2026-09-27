
# ---- THE CADENCE MUST NOT BECOME A SILENT NO-OP, IN EITHER DIRECTION -----------------------------------
# Gating the heavy audits (test-auditors itself, the embedding sweep, commodity-dupes, the static source
# scans) is what took the chain's tail from ~23 min to a few. It buys minutes by NOT RUNNING CHECKS, so it
# is exactly the kind of change that can quietly turn a guard estate into decoration. Two properties, both
# fixtured in test-cadence.ps1 and asserted here so the wiring cannot rot:
#   a skip is never a pass (missing/unreadable stamp -> run), and an input edit is due TODAY (not in 7 days).
if (Use-Unit 'u048-the-cadence-must-not-become-a-silent') {
$tcOut = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'test-cadence.ps1') | ForEach-Object { [string]$_ }) -join "`n"
if ($tcOut -match 'CADENCE SELF-TEST PASS') { Ok 'cadence gate: skips only when the clock AND its inputs both say so (test-cadence.ps1)' }
else { Bad ('cadence gate self-test FAILED - a gated audit may be skipping while its inputs move, or running every day for nothing: ' + ($tcOut -replace "`n", ' | ')) }
if ($cacSrc -match 'function Test-CadenceDue' -and $cacSrc -match "ToString\('o'\)") {
  Ok 'cadence stamps keep sub-second precision (ToString(''o'')) - ''s'' truncation made every check due forever'
} else { Bad 'the cadence stamp lost round-trip precision - an input written in the same second reads as newer and nothing ever skips' }
# A CADENCE GATE MUST NOT BE ABLE TO END THE CHAIN (2026-08-23, the undiagnosed downstream exit-1).
# Ten call sites; nine sat inside their block's try/catch and one was the block's own top-level `if`.
# When the helpers turned out never to have been implemented, the nine logged "threw" and skipped their
# audit - and the tenth terminated check-ad-cycles outright under EAP=Stop, two thirds of the way in.
# Everything after it (test-auditors itself, test-guards weekly, ghost-drift, the cloudflare estate,
# search-links, the cycle-phase coverage ratchet) silently did not run, and the only symptom anywhere
# was capture-run reporting "FAILED LANES: ... downstream". The bug is not "the helpers were missing" -
# that is fixed and could not recur the same way. The bug is that ONE unprotected gate can take the
# whole chain with it, and the next unprotected gate someone adds will do it again.
# THE SHAPE, pinned: a Test-CadenceDue call is either indented (inside a block that catches) or it is
# the `try {` itself. A bare top-level `if (-not (Test-CadenceDue ...))` is the exact line that died.
$cadCalls = @(($cacSrc -replace "`r", '') -split "`n" | Where-Object { $_ -match 'Test-CadenceDue\s+-Name' })
$cadBare = @($cadCalls | Where-Object { $_ -notmatch '^\s' -and $_ -notmatch '^try\s*\{' })
if ($cadCalls.Count -ge 2 -and $cadBare.Count -eq 0) { Ok ('every cadence gate in check-ad-cycles (' + $cadCalls.Count + ') is inside something that catches - one that throws cannot end the chain') }
else { Bad ('check-ad-cycles has ' + $cadBare.Count + ' cadence gate(s) whose throw would escape to the top level and kill the run mid-chain (found ' + $cadCalls.Count + ' gate(s) total): ' + (($cadBare | ForEach-Object { $_.Trim() }) -join ' | ')) }
# AND ITS EXIT CODE MUST BE SOMETHING SOMEBODY WROTE. check-ad-cycles carried no `exit` statement at all,
# so its rc was whatever powershell.exe inferred - 0 on a normal finish, 1 on any terminating error - and
# capture-run and daily.yml both read that inferred number as the chain's verdict. "downstream rc=1" then
# means only "something threw somewhere". An explicit terminal exit does not hide a crash (a crash never
# reaches it) - it makes the SUCCESS deliberate.
# A COMPUTED EXIT COUNTS, AND ONLY IF THE FILE ASSIGNS IT (2026-09-12). This read `^exit\s+\d+$`, a literal
# number, which was the whole of the shape until the chain's verdict started deciding its own exit code: the
# last statement is now `exit $chainExit`, 0 or 1 by whether its own commit landed. That is MORE deliberate
# than a typed constant, not less, so refusing it would push the next author back to a literal and lose the
# verdict. The must-fire is untouched - a file that ends in anything but a terminal exit still fails - and a
# variable the file never assigns fails too, because `exit $neverSet` exits 0 and would hide a crash exactly
# as the inferred code did.
$cacTail = @(($cacSrc -replace "`r", '') -split "`n" | Where-Object { $_.Trim() -ne '' -and $_.Trim() -notmatch '^#' })
$cacLast = $(if ($cacTail.Count) { $cacTail[-1].Trim() } else { '' })
$cacExitVar = $(if ($cacLast -match '^exit\s+\$([A-Za-z_]\w*)$') { $Matches[1] } else { '' })
$cacExitOk = ($cacLast -match '^exit\s+\d+$') -or ($cacExitVar -and ($cacSrc -match ('\$' + [regex]::Escape($cacExitVar) + '\s*=')))
if ($cacExitOk) { Ok ('check-ad-cycles ends with an explicit exit (' + $cacLast + ') - the chain verdict its callers read is stated, not inferred') }
else { Bad ('check-ad-cycles has no explicit terminal exit, so its exit code is whatever PowerShell infers - a crash and a clean run are told apart only by luck; last statement: ' + $(if ($cacLast) { $cacLast } else { '<none>' })) }
} # u048-the-cadence-must-not-become-a-silent

# ---- THE INSPECT FAN-OUT (2026-08-23, PLAN-use-the-cores phase 1) --------------------------------------
# The advisory audits below the ship boundary now run side by side through grocery\fanout-lib.ps1.
# Concurrency is where a watcher goes quiet without anyone noticing: a lane that dies returns nothing, and
# "nothing" and "no findings" are the same shape unless something counts. So the count is asserted, and
# these cases assert that the counting works.
if (Use-Unit 'u049-the-inspect-fan-out' -Always 'enumerates the whole tracked tree with git ls-files, so any added or removed path can move it') {
$foLib = Join-Path $root 'fanout-lib.ps1'
if (-not (Test-Path $foLib)) {
  Bad 'grocery\fanout-lib.ps1 is missing - the inspect fan-out has no helper, so either the chain is broken or every advisory audit quietly went back to running one at a time with nobody counting them'
} else {
  # ITS OWN FIXTURES, RUN HERE SO THEY ACTUALLY RUN. A self-test with no caller is not a guard - that is
  # the audit-unit-basis-outlier / test-matcher-parity lesson, and this file is where such a caller lives.
  # The 14 cases include the three MUST-FIREs that matter most: a lane whose script is MISSING, a lane
  # that exits 0 without its declared completion marker, and a lane killed at its budget must each come
  # back BLIND rather than clean. Plus a CONCURRENCY case, because every other assertion in that file
  # would still pass if the pool had quietly become a serial loop.
  $r = (Get-Early 'early:fanout-selftest' $foLib @('-SelfTest')).text
  if ($LASTEXITCODE -eq 0 -and $r -match 'SELFTEST: 17/17 pass') {
    Ok 'fanout-lib -SelfTest passes (a missing lane, a timeout, and a marker present-but-not-LAST each report BLIND; a child that warns on stderr does not; -Sequential agrees lane-for-lane; the pool is provably concurrent)'
  } else { Bad ('fanout-lib -SelfTest failed or lost its fixtures: ' + (($r -split "`r?`n" | Where-Object { $_ -match 'FAIL|SELFTEST' }) -join ' | ')) }

  # EVERY LANE NAMES A SCRIPT THAT EXISTS. Get-FanoutRecord returns BLIND for a lane it cannot find, and
  # the lane body returns BLIND for a script that is not on disk - both correct, and both would make the
  # daily summary carry a BLIND line every single morning until somebody read it. A rename or a moved
  # script should fail HERE, at change time, not by degrading the whole chain to advisory noise.
  $foLanes = [regex]::Matches($cacSrc, "New-FanoutLane -Name '([a-z0-9-]+)'\s+-File \(Join-Path \`$(root|mealPrep)\s+'([^']+)'\)")
  if ($foLanes.Count -lt 20) {
    Bad ('check-ad-cycles declares only ' + $foLanes.Count + ' fan-out lane(s) - the inspect audits have been unwired from the fan-out, or the lane shape changed and this check can no longer see them (a scan that finds nothing to look at is BLIND, not clean)')
  } else {
    $foMissing = @()
    foreach ($m in $foLanes) {
      $base = if ($m.Groups[2].Value -eq 'root') { $root } else { Join-Path (Split-Path $root -Parent) 'meal-prep' }
      if (-not (Test-Path (Join-Path $base $m.Groups[3].Value))) { $foMissing += ($m.Groups[1].Value + ' -> ' + $m.Groups[3].Value) }
    }
    if ($foMissing.Count -eq 0) { Ok ('all ' + $foLanes.Count + ' inspect fan-out lanes name a script that exists') }
    else { Bad ('inspect fan-out lane(s) point at a script that is not there, so each reports BLIND every morning: ' + ($foMissing -join '; ')) }

    # LAUNCHED AND NEVER READ IS THE WORSE HALF. A lane with no Get-FanoutRecord consumer costs its full
    # runtime every day and its verdict reaches nobody - a guard that runs, finds something, and is thrown
    # away. The reverse (a consumer with no lane) is loud by construction: Get-FanoutRecord hands back a
    # BLIND record. This side is silent, so it gets the check.
    $foNames = @($foLanes | ForEach-Object { $_.Groups[1].Value })
    $foRead  = @([regex]::Matches($cacSrc, "Get-FanoutRecord '([a-z0-9-]+)'") | ForEach-Object { $_.Groups[1].Value })
    $foOrphan = @($foNames | Where-Object { $foRead -notcontains $_ })
    if ($foOrphan.Count -eq 0) { Ok 'every inspect fan-out lane is read back by a consumer (none runs daily for nobody)' }
    else { Bad ('inspect fan-out lane(s) are launched every day and their verdict is never read: ' + ($foOrphan -join ', ')) }

    # THE MUTATORS AND DELETERS MUST STAY OUT. repair-multipack-sizes / derive-links-from-prices /
    # fix-links-ff rewrite out\regular\ and product-urls.json, which the read-only lanes READ; prune-out
    # and prune-intermediates DELETE dated out\ files they read. Putting any of them in the pool means a
    # lane reporting on a board that never existed, which is worse than a slow chain and much harder to
    # see. Named here so the next person adding a lane finds out at change time.
    $foBanned = @('repair-multipack-sizes','derive-links-from-prices','fix-links-ff','prune-out','prune-intermediates','db-build')
    $foBad = @($foBanned | Where-Object { $cacSrc -match ("New-FanoutLane[^\r\n]*" + [regex]::Escape($_)) })
    if ($foBad.Count -eq 0) { Ok 'no mutator or deleter has been added to the inspect fan-out (they still run serially, around it)' }
    else { Bad ('a stage that MUTATES or DELETES shared inputs has been put in the read-only fan-out - other lanes will read a file mid-rewrite: ' + ($foBad -join ', ')) }
  }

  # THE MARKERS ARE WIRED, AND A LANE THAT LOSES ONE MUST SURFACE HERE. 32 of the 34 lanes declare the
  # completion marker their script prints; the two that do not (discover-hyvee, scaler-pricing) emit none.
  # A marker is the only thing that separates "found nothing" from "died half way", which in a POOL is
  # harder to notice than in a serial chain - nothing downstream waits on a lane, so a lane that dies just
  # contributes silence. If this count collapses, the fan-out has gone back to trusting exit codes alone.
  $foMarked = @([regex]::Matches($cacSrc, "New-FanoutLane[^
]*-Marker '[A-Z0-9-]+-COMPLETE'")).Count
  if ($foMarked -ge 30) { Ok ("$foMarked of the inspect fan-out lanes require their completion marker (a lane that dies mid-way cannot read as 'no findings')") }
  else { Bad ("only $foMarked fan-out lane(s) still require a completion marker - the pool has gone back to judging lanes on exit code alone, and an exit code cannot tell 'clean' from 'stopped early'") }

  # -Sequential MUST SURVIVE. It is how the next person answers "is this a concurrency problem?" without
  # reverting anything, and it is the only reason the two transcripts are comparable at all. A fan-out
  # with no way back to serial is a fan-out nobody can debug.
  if ($cacSrc -match '\[switch\]\$Sequential' -and $cacSrc -match '-Sequential:\$Sequential') {
    Ok 'check-ad-cycles keeps -Sequential wired through to the fan-out (a flaky lane is one flag from diagnosis, not one revert)'
  } else { Bad 'check-ad-cycles lost its -Sequential escape hatch - a concurrency-suspect lane can now only be investigated by reverting the fan-out' }

  # THE PULLS BELONG TO capture-run, AND THE CHAIN NOW SAYS SO (2026-08-23). check-ad-cycles' pull block
  # is inside `if (-not $NoPull)`, every scheduled caller passes -NoPull, and capture-run does those pulls
  # as parallel lanes BEFORE calling this file. So the block only ever runs for a human - where it re-pulls
  # stores already pulled that morning, is throttled by Freshop to ~5x normal (567 s vs 88-108 s, measured
  # 2026-08-23), and spends the shared rotation cursor on a test. It now refuses without -ForcePull.
  # Pinned because the refusal is one `if` guarding an expensive, slow-to-notice mistake, and because
  # capture-run MUST keep passing -NoPull or every scheduled run starts hitting the refusal instead.
  if ($cacSrc -match '\[switch\]\$ForcePull' -and $cacSrc -match 'REFUSING to pull') {
    Ok 'check-ad-cycles refuses to pull unless -ForcePull (the pulls belong to capture-run, which runs them as parallel lanes)'
  } else { Bad 'check-ad-cycles lost its pull refusal - a manual run will silently re-pull stores captured hours earlier, get throttled, and spend the rotation cursor' }
  if ($crSrc -match '-NoPull') {
    Ok 'capture-run still calls the chain with -NoPull (so the refusal never fires on a scheduled run)'
  } else { Bad 'capture-run no longer passes -NoPull to check-ad-cycles - every scheduled run will now hit the pull refusal and exit 3' }

# ---- STORAGE HYGIENE (2026-08-23, PLAN-storage-hygiene) -------------------------------------------------
# Half the pack (191 MB of ~380 MB) turned out to be two days of Chrome profiles that a directory sweep
# committed unnoticed. These checks watch the three shapes that let it happen, because the cost of finding
# out late is a rewrite of published history plus a credential rotation.
$giSrc = Get-Content (Join-Path (Split-Path $root -Parent) '.gitignore') -Raw
$crSrc2 = Get-Content (Join-Path $root 'capture-run.ps1') -Raw
# THE OWNERSHIP LIST MOVED OUT OF capture-run ON 2026-09-06 (PLAN-top5 area 3). It lived inline here, where
# push-data.ps1 could not reach it - and push-data therefore ran `git add -A` and put 325 files on main.
# The list is now lib\bot-paths.ps1, read by capture-run, by push-data and by the pre-commit hook's scope
# check. The staging cases below follow it there; the size-gate cases stay on capture-run, which is where
# that block still lives.
$bpSrc = Get-Content (Join-Path (Split-Path $root -Parent) 'lib\bot-paths.ps1') -Raw
# A LIST NOBODY READS IS NOT A LIST. Moving it is only safe if capture-run actually consumes it - the
# same file could hold a perfect declaration and stage from a stale inline copy.
if ($crSrc2 -match "lib\\bot-paths\.ps1" -and $crSrc2 -match '\$inputPaths\s+=\s+Get-BotInputPaths' -and $crSrc2 -match '\$servedPaths\s+=\s+Get-BotServedPaths') {
  Ok 'capture-run stages from lib\bot-paths.ps1 (one declaration, read by the chain, by push-data and by the hook)'
} else { Bad 'capture-run no longer takes its staging list from lib\bot-paths.ps1 - a second hand-copied list is exactly how push-data ended up sweeping the whole tree on 2026-09-05' }

# 1. THE IGNORE LIST COVERS THE KNOWN-VOLATILE SHAPES. Each of these has either already cost us something
#    or is one `git add -A` from doing so. Named individually so a failure says WHICH rule went.
foreach ($rule in @(
  @{ pat = '(?m)^__pycache__/';                     what = '__pycache__/ (bytecode, was sidecar-only while ten other dirs sat unignored)' }
  @{ pat = '(?m)^\*\.pyc';                          what = '*.pyc (two were committed from meal-prep\pipeline)' }
  @{ pat = '(?m)^/grocery/out/browser-profiles/';   what = 'grocery/out/browser-profiles/ (the seeded store sessions - 191 MB of the pack)' }
  @{ pat = '(?m)^/grocery/out/archive/';            what = 'grocery/out/archive/ (what prune-out moves aside)' }
)) {
  if ($giSrc -match $rule.pat) { Ok ('.gitignore still covers ' + $rule.what) }
  else { Bad ('.gitignore LOST its rule for ' + $rule.what + ' - the next daily commit sweeps it into the repo, and a directory sweep makes .gitignore the only defence there is') }
}

# 2. AND NOTHING OF THAT SHAPE IS ACTUALLY TRACKED. The ignore list only governs UNTRACKED files: a file
#    already in the index keeps being committed no matter what .gitignore says, which is exactly why the
#    profiles needed `git rm -r --cached` and not just a rule.
# Invoke-Native, not `2>$null`: this file runs under 'Stop', where one git warning on stderr is a terminating throw.
$lsRes = Invoke-Native 'git' '-C' (Split-Path $root -Parent) 'ls-files'
$tracked = @($lsRes.Output)
$badTracked = @($tracked | Where-Object { $_ -match '__pycache__|\.pyc$|browser-profiles/' })
if ($badTracked.Count -eq 0) { Ok ('no bytecode or browser-profile file is tracked (' + $tracked.Count + ' tracked file(s) checked)') }
else { Bad ('these are TRACKED and should not be - a .gitignore rule does not untrack an existing file, it needs git rm --cached: ' + (($badTracked | Select-Object -First 6) -join ', ')) }

# 3. THE COMMIT-SIZE GATE IS STILL WIRED, and its fixture still proves it fires. The gate is the general
#    defence - the ignore list is per-shape and always one step behind whatever writes under out\ next.
if ($crSrc2 -match '\$NEW_FILE_CAP' -and $crSrc2 -match 'commit REFUSED') {
  Ok 'capture-run still refuses a daily commit that does not look like a day of prices (the 4,388-file class)'
} else { Bad 'capture-run LOST its commit-size gate - a directory sweep can again put thousands of unintended files into the repo, and .gitignore only catches the shapes somebody already thought of' }
$r = PSChild (Join-Path $root 'test-commit-size-gate.ps1')
$csgRc = $LASTEXITCODE
$rTxt = ($r | Out-String)
if ($csgRc -eq 3) { Bad ('test-commit-size-gate is BLIND - it could not find the gate in capture-run.ps1, so nothing about it was proven: ' + (($rTxt -split "`r?`n" | Where-Object { $_ -match 'BLIND' }) -join ' ')) }
# NOT A FROZEN COUNT (2026-08-25). This asserted 'SELFTEST: 7/7 pass'. Three cases were added to
# test-commit-size-gate.ps1 and this line was never updated, so the child printed 'SELFTEST: 10/10 pass'
# and COMMIT-SIZE-GATE-COMPLETE cases=10 failed=0 - completely green - while this harness reported it as
# a FAILING watcher. A test that breaks when its subject gets BETTER trains the reader to ignore it, and
# it is the same false-alarm shape as the rollback ledger count fixed the same day. Assert what the
# contract actually is - it finished, and nothing failed - so growing the fixture set can never fail it.
elseif ($csgRc -eq 0 -and $rTxt -match 'COMMIT-SIZE-GATE-COMPLETE cases=\d+ failed=0') {
  Ok 'commit-size gate fixture passes (400 files refused, 40 MB refused, a SMALL never-tracked directory refused, a normal day and an already-tracked directory untouched, -ForceBigCommit honoured)'
} else { Bad ('test-commit-size-gate failed (rc=' + $csgRc + '): ' + (($rTxt -split "`r?`n" | Where-Object { $_ -match 'FAIL|SELFTEST' }) -join ' | ')) }

# 4. THE AUDIT RECORD IS STAGED. .gitignore says provenance JSONL ARE tracked ("the evaluation record and
#    the audit") and $inputPaths did not list them, so 08-22 and 08-23 were never committed while 191 MB of
#    cookies were. Clean means the RIGHT things are tracked, not only that the wrong things are not.
if ($bpSrc -match "'graph/provenance'") { Ok 'the bot ownership list stages graph/provenance (the audit record leaves this PC)' }
else { Bad 'lib\bot-paths.ps1 no longer stages graph/provenance - the evaluation record .gitignore promises is tracked never leaves this machine, and the cloud clone has none of it' }

# 4b. THE CARRIAGE LEDGERS ARE STAGED (Brad's ruling, 2026-08-27): "if we find a price for an ingredient,
#     it should always be merged after discovery on the seven stores." Same lesson as graph/provenance one
#     check above, on the family where losing a record is worst. These five were on NO list - not
#     $inputPaths, not $servedPaths, not push-data's sweep - so carriage.json held 20 bids at HEAD and 59
#     in the working tree: 39 CARRIED verdicts from three sessions across three days, one
#     `git checkout -- .` from gone and invisible in `git log` because the tracked file had not moved
#     since 08-25. A carriage verdict is an OBSERVATION, not a computation - Rule B turns on what a store
#     carried at a moment, so re-creating one means re-driving seven stores and the moment cannot be
#     re-visited. Six scripts read carriage.json, including engine\cost-recipes.ps1 and engine\publish.ps1.
foreach ($ledger in @('grocery/carriage.json', 'grocery/ingredient-queue.json',
                      'grocery/board-price-overrides.json', 'grocery/sale-without-ad.json',
                      'grocery/notify-log.txt', 'meal-prep/db/source-domains.json')) {
  if ($bpSrc -match [regex]::Escape("'" + $ledger + "'")) {
    Ok ("the bot ownership list stages {0} (a discovered price is merged, never left in the working tree)" -f $ledger)
  } else {
    Bad ("lib\bot-paths.ps1 no longer stages {0} - a carriage verdict found across the seven stores would live on ONE machine, unrecoverable by re-running anything, and a clean clone would price from a different world" -f $ledger)
  }
}
# ...AND IN INPUTS, NOT SERVED. $servedPaths is gated on $shipServed, which a capture-only ad run never
# sets - so a ledger placed there would be staged on chain days only, which is the same bug with a longer
# fuse. Evidence of what a store told us belongs in INPUTS by this list's own stated split.
# MATCH THE DECLARATIONS, NOT ANY MENTION. The first draft of this check used IndexOf('$servedPaths')
# and matched the explanatory COMMENT that sits above both arrays, which put "served" before "inputs"
# and failed on a correct file. A guard that fires on where a comment happens to sit is worse than no
# guard: it teaches the next person to ignore it.
$idxInputs = $bpSrc.IndexOf('function Get-BotInputPaths')
$idxServed = $bpSrc.IndexOf('function Get-BotServedPaths')
$idxCarriage = $bpSrc.IndexOf("'grocery/carriage.json'")
if ($idxInputs -ge 0 -and $idxServed -gt $idxInputs -and $idxCarriage -gt $idxInputs -and $idxCarriage -lt $idxServed) {
  Ok 'the carriage ledgers sit in INPUTS, so they ship on a capture-only ad run that builds no board'
} else {
  Bad 'the carriage ledgers are no longer inside $inputPaths - if they moved to $servedPaths they now ship only when the chain runs and guards pass, so an ad-only day loses every verdict it found'
}
}
# THE ALERT GATE IS NOT A CHECK-THEN-ACT RACE ANY MORE (2026-08-23). send-alert reads alert-sent-<day>.txt,
# decides, sends over the network, then appends the type. Serial callers made that window harmless; the
# fan-out ends that assumption - three lanes (match-soundness, store-registry, category-coverage) page on
# their own behalf as grandchildren, so the parent cannot serialise them by holding anything. Two processes
# in that window both email, or one loses its append and re-pages a type already delivered.
$saSrc = Get-Content (Join-Path $root 'send-alert.ps1') -Raw
if ($saSrc -match "New-Object System\.Threading\.Mutex\(\`$false, 'Global\\smp-grocery-alert-sent'\)") {
  Ok 'send-alert holds a machine-wide lock across its once-per-type-per-day gate (concurrent lanes cannot double-send or silently suppress)'
} else { Bad 'send-alert LOST the lock around its sent-file gate - with audits running side by side, two alerts of one type can both email, or one can be suppressed by an append that never landed' }
} # u049-the-inspect-fan-out

# ---- THE BROWSER-STORE BUILDERS (2026-08-23, PLAN-use-the-cores phase 4) --------------------------------
# capture-run's builder block stopped being one loop and became three passes: a serial pass that decides
# what exists, a FAN-OUT over the first-stage builders, and a serial pass that reads the verdicts and runs
# the second stage. The claim is that behaviour is identical and only timing changed - which is exactly the
# kind of claim that needs a fixture rather than a reading, because this block is the last mile of every
# capture the estate takes and a wrong answer here loses a whole morning's prices.
# test-capture-builders.ps1 extracts the SHIPPED block out of capture-run.ps1 by marker and runs it against
# fake captures and fake builders. Exit 3 means it could not find the block - BLIND, not clean.
# THE FIXTURE INVENTORY FLOOR, in one place because three assertions below read it (the live run, and the
# LF and CRLF regime copies). A floor may only be RAISED: it exists so a silently dropped case fails here
# rather than passing by finding nothing.
if (Use-Unit 'u050-the-browser-store-builders') {
$TCB_MIN_CASES = 33
$tcb = Join-Path $root 'test-capture-builders.ps1'
if (-not (Test-Path $tcb)) {
  Bad 'grocery\test-capture-builders.ps1 is missing - the browser-store builder block is unfixtured, and it is the last mile of every capture'
} else {
  $r = PSChild $tcb | Out-String
  $tcbRc = $LASTEXITCODE
  if ($tcbRc -eq 3) {
    Bad ('test-capture-builders is BLIND - it could not find the builder block in capture-run.ps1, so nothing about the builders was proven: ' + (($r -split "`r?`n" | Where-Object { $_ -match 'BLIND' }) -join ' | '))
  } elseif ($tcbRc -eq 0 -and $r -match 'CAPTURE-BUILDERS-COMPLETE cases=(\d+) failed=0' -and [int]$Matches[1] -ge $TCB_MIN_CASES) {
    # The COUNT is part of the assertion, not decoration: it pins the fixture inventory so a case that is
    # silently dropped fails here instead of passing by finding nothing. 10 -> 19 on 2026-09-03 when queue
    # 2026-09-03-58057b added the edge read-after-write cases (Test-EdgeServesPushed: the skipped/stale/ok/
    # blind arms, plus the assertions that the edge check and the served-dirty block stay gated on the same
    # $shipServed predicate and that both comparisons read the COMMITTED blob).
    # 19 -> 28 on 2026-09-04 (queue 2026-09-04-4ec26c): the committed blob is now read as BYTES, so the
    # byte-comparison arms (stale on one changed price digit, ok on identical bytes carrying non-ASCII, the
    # three BLIND arms, the empty-hash reachability check, the frozen reconstruction of the founding
    # two-decodings bug, and the assertion that no committed blob is read through the TEXT pipeline).
    # 28 -> 33 on 2026-09-09 (queue 2026-09-09-f0b5f2): the served-dirty gate and the edge-skipped line both
    # now read $botCommitted, because on 09-09 the commit was REFUSED and both watchers reported as though
    # it had landed - one naming 16 files and prescribing an inert repair, the other printing "skipped: ok".
    #
    # A FLOOR, NOT AN EQUALITY (2026-09-09). It was `-match 'SELFTEST: 28/28 pass'`, so ADDING a case turned
    # this red and the failure text was the passing run's own output, which is a confusing way to learn that
    # a suite grew. A floor still catches the thing the count is for - a silently dropped case - and it
    # reads the tool's COMPLETION MARKER, so a suite that died halfway cannot satisfy it either. The bar is
    # higher than the equality it replaces, not lower.
    Ok ('capture-run builder block: a missing capture stays outstanding, a failed builder is named, a failed stage 1 skips stage 2, stage 2 is still judged on evidence, the edge read-after-write compares COMMITTED BYTES against git, and both post-commit watchers read $botCommitted (test-capture-builders ' + $Matches[1] + ' cases, floor ' + $TCB_MIN_CASES + ')')
  } else { Bad ('test-capture-builders failed (rc=' + $tcbRc + ', floor ' + $TCB_MIN_CASES + ' cases): ' + (($r -split "`r?`n" | Where-Object { $_ -match 'FAIL|SELFTEST|CAPTURE-BUILDERS-COMPLETE' }) -join ' | ')) }
}
} # u050-the-browser-store-builders

# ---- THE FIXTURE MUST NOT CARE WHAT A LINE ENDING IS (2026-09-07, queue 2026-09-07-76ec7f) -------------
# On 2026-09-07 the block above reported BLIND and proved nothing about the last mile of every capture.
# Nothing was wrong with the builders. test-capture-builders located its subject by a literal CRLF brace
# ladder ("`r`n      }`r`n    }`r`n  }`r`n}") and added a hard-coded 9 for 'CRLF + six spaces + }'; the
# eol=lf attribute landed estate-wide in 39ad18d3d (2026-09-06 17:59) and capture-run.ps1 was rewritten LF
# the next morning, so the marker stopped matching. A fixture that inherits the repository's line-ending
# regime as an unstated assumption goes blind the day the regime moves, and the only reason anyone could
# tell is that its author hand-wrote a BLIND branch. So the fixture is now run under BOTH regimes here, and
# the founding bug is frozen below so the LF regime cannot blind a marker again without saying so.
if (Use-Unit 'u051-the-fixture-must-not-care-what-a') {
$fxLe = NewFxDir 'tcb-lineending'
# the fixture dot-sources lib\git-blob-lib.ps1 from its PARENT dir, and for the copies below that parent
# is $fxLe. Without this the copy throws at startup and exits 1 before printing anything, which reads as
# a case failure rather than a missing dependency.
Copy-Item (Join-Path (Split-Path $root -Parent) 'lib') (Join-Path $fxLe 'lib') -Recurse -Force
$crRaw = [IO.File]::ReadAllText((Join-Path $root 'capture-run.ps1'))
$crLf   = $crRaw -replace "`r`n", "`n"
$crCrLf = $crLf  -replace "`n", "`r`n"
$fxLeLf   = Join-Path $fxLe 'lf';   New-Item -ItemType Directory -Force $fxLeLf   | Out-Null
$fxLeCrLf = Join-Path $fxLe 'crlf'; New-Item -ItemType Directory -Force $fxLeCrLf | Out-Null
foreach ($d in @($fxLeLf, $fxLeCrLf)) {
  Copy-Item (Join-Path $root 'test-capture-builders.ps1') (Join-Path $d 'test-capture-builders.ps1') -Force
  # AND ITS GROCERY-LEVEL DEPENDENCY (2026-09-09). The fixture dot-sources fanout-lib.ps1 from its OWN
  # directory. That line used to be the absolute 'C:\Codex\ThriftyCrew\grocery\fanout-lib.ps1', which made
  # a copy work by reaching back into the main checkout - and made a WORKTREE run load main's library and
  # report green about code it had not opened. Making the fixture repo-relative is right, and it means the
  # copy must now carry the dependency, exactly as the lib\ copy above already does for ps-source and
  # git-blob-lib. This is defect 4 of the 2026-09-05 sweep: a copied script does NOT keep its dependencies.
  Copy-Item (Join-Path $root 'fanout-lib.ps1') (Join-Path $d 'fanout-lib.ps1') -Force
  # AND check-ad-cycles.ps1 (2026-09-26, queue 518fff): the held-post cases read its source from the fixture's
  # own directory to prove it records board_sha256. Without the copy the fixture threw at that read with rc=1.
  Copy-Item (Join-Path $root 'check-ad-cycles.ps1') (Join-Path $d 'check-ad-cycles.ps1') -Force
}
[IO.File]::WriteAllText((Join-Path $fxLeLf   'capture-run.ps1'), $crLf,   (New-Object Text.UTF8Encoding $true))
[IO.File]::WriteAllText((Join-Path $fxLeCrLf 'capture-run.ps1'), $crCrLf, (New-Object Text.UTF8Encoding $true))
# fixture integrity: the two copies really do differ in line endings and in nothing else. Without this a
# 'both pass' result is equally consistent with having written the same bytes into both directories.
$nLf   = ([IO.File]::ReadAllBytes((Join-Path $fxLeLf   'capture-run.ps1')) | Where-Object { $_ -eq 13 }).Count
$nCrLf = ([IO.File]::ReadAllBytes((Join-Path $fxLeCrLf 'capture-run.ps1')) | Where-Object { $_ -eq 13 }).Count
if ($nLf -eq 0 -and $nCrLf -gt 1000 -and (($crCrLf -replace "`r`n", "`n") -eq $crLf)) {
  Ok ('line-ending fixture integrity: the LF copy carries 0 CR and the CRLF copy carries ' + $nCrLf + ', and the two fold to identical text - the two runs below really are the same subject under two regimes')
} else { Bad ('line-ending fixture integrity FAILED (CR counts ' + $nLf + ' / ' + $nCrLf + ') - the two copies are not the same bytes under two regimes, so neither run below means anything') }
$rLf = RunPSAt $fxLeLf 'test-capture-builders.ps1' @()
if ($rLf.rc -eq 0 -and $rLf.text -match 'CAPTURE-BUILDERS-COMPLETE cases=(\d+) failed=0' -and [int]$Matches[1] -ge $TCB_MIN_CASES) { Ok ('capture-run builder block under LF (today''s regime): test-capture-builders finds its subject and passes ' + $Matches[1] + ' cases') }
elseif ($rLf.text -match '(?m)^BLIND:') { Bad ('test-capture-builders is BLIND against an LF capture-run.ps1 (rc=' + $rLf.rc + ') - this is the 2026-09-07 defect returning: ' + (($rLf.text -split "`r?`n" | Where-Object { $_ -match '^BLIND:' }) -join ' | ')) }
else { Bad ('test-capture-builders failed against an LF capture-run.ps1 (rc=' + $rLf.rc + '): ' + (($rLf.text -split "`r?`n" | Where-Object { $_ -match 'FAIL|SELFTEST' }) -join ' | ')) }
# CLEAN TWIN: the regime the fixture was written under. The fix folds CRLF to LF, and the thing that fold
# was most likely to break is the case it used to handle. The builders' behaviour is not a line ending.
$rCrLf = RunPSAt $fxLeCrLf 'test-capture-builders.ps1' @()
if ($rCrLf.rc -eq 0 -and $rCrLf.text -match 'CAPTURE-BUILDERS-COMPLETE cases=(\d+) failed=0' -and [int]$Matches[1] -ge $TCB_MIN_CASES) { Ok ('CLEAN TWIN: capture-run builder block under CRLF (a fresh checkout''s regime) still passes ' + $Matches[1] + ' cases - the fold did not trade one regime for the other') }
elseif ($rCrLf.text -match '(?m)^BLIND:') { Bad ('test-capture-builders is BLIND against a CRLF capture-run.ps1 (rc=' + $rCrLf.rc + ') - the fix traded the old blindness for a new one, and every fresh worktree is CRLF: ' + (($rCrLf.text -split "`r?`n" | Where-Object { $_ -match '^BLIND:' }) -join ' | ')) }
else { Bad ('test-capture-builders failed against a CRLF capture-run.ps1 (rc=' + $rCrLf.rc + '): ' + (($rCrLf.text -split "`r?`n" | Where-Object { $_ -match 'FAIL|SELFTEST' }) -join ' | ')) }
# MUST FIRE (the founding bug, frozen). The OLD locate logic, reconstructed here so it cannot be edited
# away with the fixture it used to live in. FROZEN, not read off the live file: capture-run.ps1 now carries
# the named markers between the braces, so the live source no longer reproduces the shape at all and a
# reconstruction that read it would pass by finding nothing - the exact defect this whole item is about.
# The tail below is the brace ladder capture-run.ps1 carried on 2026-09-04, the day the fixture last passed.
$oldEndMark = "`r`n" + '      }' + "`r`n" + '    }' + "`r`n" + '  }' + "`r`n" + '}'
$frozenTailLf = '      $bLanes = @(); $bMeta = @{}' + "`n" + '              $failed += ("build2-" + $key)' + "`n" + '            }' + "`n" + '          }' + "`n" + '        }' + "`n" + '      }' + "`n" + '    }' + "`n" + '  }' + "`n" + '}' + "`n"
$frozenTailCrLf = $frozenTailLf -replace "`n", "`r`n"
$oldOnFrozenLf   = $frozenTailLf.IndexOf($oldEndMark)
$oldOnFrozenCrLf = $frozenTailCrLf.IndexOf($oldEndMark)
if ($oldOnFrozenCrLf -ge 0 -and $oldOnFrozenLf -lt 0) {
  Ok 'MUST FIRE (founding bug, frozen): the OLD hard-coded-CRLF end marker finds the 2026-09-04 brace ladder under CRLF and finds NOTHING in the identical text under LF - the whole of the 2026-09-07 blindness, and the reason the fixture locates by named marker now'
} else { Bad ('the frozen reconstruction of the 2026-09-07 blindness no longer reproduces (CRLF=' + $oldOnFrozenCrLf + ' LF=' + $oldOnFrozenLf + ') - it has drifted from the bug and proves nothing') }
# and the same old logic against the LIVE LF source must still find nothing, which is what actually
# happened at 08:00 on 2026-09-07. Two separate assertions on purpose: the frozen one proves the
# mechanism is a line ending, this one proves today's file is still on the losing side of it.
$oldJLive = $crLf.IndexOf($oldEndMark, [Math]::Max(0, $crLf.IndexOf('      $bLanes = @(); $bMeta = @{}')))
if ($oldJLive -lt 0) { Ok 'MUST FIRE (live): the OLD CRLF end marker still finds nothing in the shipped LF capture-run.ps1 - a fixture locating by literal line ending would be BLIND right now' }
else { Bad 'the OLD CRLF end marker matches the shipped capture-run.ps1 again, so the file has gone back to CRLF - check .gitattributes eol=lf before trusting any byte-exact comparison in this estate' }
# and the named markers themselves must be present in the SHIPPED file, not only in the copies above.
# THIS UNIT READS ITS OWN SOURCES (2026-09-26). $crSrc and $cacSrc used to arrive from u046/u047, so a push
# that selected u051 alone judged 12 cases against $null and read every one red. Same files, same reader.
$crSrc  = Get-Content (Join-Path $root 'capture-run.ps1') -Raw
$cacSrc = (Expand-SelfTestPointers -Text ((Expand-SelfTestPointers -Text ([IO.File]::ReadAllText((Join-Path $root 'check-ad-cycles.ps1'))) -Path (Join-Path $root 'check-ad-cycles.ps1'))) -Path (Join-Path $root 'check-ad-cycles.ps1'))
if ($crSrc -match '# >>> BUILDER-BLOCK >>>' -and $crSrc -match '# <<< BUILDER-BLOCK <<<') {
  Ok 'capture-run.ps1 still carries the named BUILDER-BLOCK markers the fixture locates by'
} else { Bad 'capture-run.ps1 has lost one of its BUILDER-BLOCK markers - test-capture-builders will go BLIND on the next run' }
# THE SECOND STAGE MUST STAY SERIAL. build-fareway-regular runs only if stage 1 exited 0, and its failure
# is judged on EVIDENCE - does today's file already hold rows captured today? - not on its exit code. That
# is per-store conditional logic. Putting it in the pool would mean launching it before knowing whether it
# should run at all, which for a builder that REFUSES to shrink today's file is a real risk to real prices.
if ($crSrc -match "New-FanoutLane -Name \`$lname" -and $crSrc -notmatch "New-FanoutLane[^\r\n]*\.Then") {
  Ok 'only the FIRST-stage builders are in capture-run''s fan-out (the conditional second stage stays serial)'
} else { Bad 'capture-run''s builder fan-out no longer has the shape it was fixtured with - either the first-stage lane is gone, or the conditional second stage has been put in the pool where it would run before anything knows it should' }
if ($crSrc -match 'smp-pipeline-bot' -and $crSrc -match 'push origin HEAD:main') {
  Ok 'capture-run still commits and pushes the pipeline output (the last mile exists)'
} else { Bad 'capture-run LOST its commit/push - the chain would compute prices that never reach a reader, exactly as 2026-08-18..22' }
if ($crSrc -match '\$servedPaths' -and $crSrc -match '\$inputPaths') {
  Ok 'capture-run separates INPUT paths from SERVED paths'
} else { Bad 'capture-run no longer separates served from input paths - a blocked board or a capture-only run can ship public\** again' }
# 2026-09-07: the gate now reads through lib\chain-verdict-lib.ps1, whose ship_ok is true ONLY for a
# verdict that is today's AND whose recorded input fingerprint still matches the tree. Pinning
# `-and $verdict.ship_ok` pins the whole rule, because ship_ok is the only property that carries it.
if ($crSrc -match '\$shipServed\s*=\s*\$runDownstream\s+-and\s+\$verdict\.ship_ok') {
  Ok 'served files ship ONLY when the chain ran AND the guard verdict is a fresh pass (verdict read, never inferred)'
} else { Bad 'the served-path gate changed shape - public\** may ship without a passing guard verdict' }
if ($crSrc -match 'chain-verdict-lib\.ps1' -and $crSrc -notmatch '\[bool\]\$v\.guards_blocked') {
  Ok 'capture-run reads the verdict through the shared library, not by re-deriving the date rule inline'
} else { Bad 'capture-run reads chain-verdict.json by hand again - the date-only rule that trusted a stale PASS is back' }
if ($crSrc -notmatch "git -C \$repo add -A -- '?public") {
  Ok 'capture-run never stages public\ unconditionally'
} else { Bad 'capture-run stages public\ unconditionally again' }
if ($crSrc -match "New-Object System\.Threading\.Mutex\(\`$false, 'Global\\tc-capture-run'\)") {
  Ok 'capture-run holds a machine-wide lock (overlapping scheduled + manual runs cannot share a git index)'
} else { Bad 'capture-run LOST its mutex - two runs can rebase the same tree at once' }
# CROWN-BY-CONTEST IS ADVISORY, AND AN ADVISORY NOBODY PRINTS IS SILENCE (Brad ruling 5, 2026-09-07).
# audit-match-soundness exits 1 for it; check-ad-cycles handled only 2 and 3, so a NEW contested name
# holding a crown produced no summary line at all and 'advisory' meant 'discarded'. Pin the branch.
if ($cacSrc -match 'msJ\.ExitCode\s+-eq\s+1' -and $cacSrc -match 'CROWN-BY-CONTEST') {
  Ok 'a CROWN-BY-CONTEST advisory (rc 1) reaches the daily summary - advisory means reported, not dropped'
} else { Bad 'check-ad-cycles no longer reports audit-match-soundness rc=1 - a new contested name holding a crown would ship with nothing said' }

# the verdict must be WRITTEN by the chain, or the reader above silently degrades to "no verdict, no ship".
# ASSERT THE CALL, NOT A MENTION. Until 2026-09-07 this matched the strings 'chain-verdict.json' and
# 'guards_blocked' anywhere in the file - and after the writer moved into the shared library, the ONLY
# thing still satisfying it was a COMMENT on line 1279 explaining what the publisher reads. A check a
# comment can pass is not a check. It now pins the call and the library that defines the document.
$cacCode = ($cacSrc -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
$cvLibSrc = [IO.File]::ReadAllText((Join-Path (Split-Path $root -Parent) 'lib\chain-verdict-lib.ps1'))
if ($cacCode -match 'Write-ChainVerdict\s+-Repo' -and $cacCode -match "chain-verdict-lib\.ps1") {
  Ok 'check-ad-cycles states its guard verdict as a value, through the one writer (lib\chain-verdict-lib.ps1)'
} else { Bad 'check-ad-cycles no longer CALLS Write-ChainVerdict - capture-run cannot tell a blocked board from a clean one' }
if ($cacCode -match 'Write-ChainVerdict[^\n]*-GuardsRc\s+\$guardsRc') {
  Ok 'the verdict carries the exit code guards actually returned, not a value the caller chose'
} else { Bad 'check-ad-cycles passes something other than the observed $guardsRc to the verdict writer' }
if ($cvLibSrc -match 'inputs_fingerprint' -and $cvLibSrc -match "'STALE-INPUTS'") {
  Ok 'the guard verdict records an input fingerprint, so a same-day PASS over inputs that have since moved reads STALE and never ships'
} else { Bad 'the chain verdict lost its input fingerprint - a PASS from before a commodities.json edit would ship an ungated board again' }
# and the watchdog must ask the question that speaks for the READER, not for the pipeline
$cwSrc = Get-Content (Join-Path $root 'capture-watchdog.ps1') -Raw
# ASSERT THE QUESTION, NOT ITS PUNCTUATION. This used to pin the literal "log --author='smp-pipeline-bot'",
# so converting that call to Invoke-Native (2026-08-23) read as "the watchdog lost its reached-main check"
# when the check was intact. A shape test that fails on a safe refactor teaches people to edit the test.
if ($cwSrc -match 'NEVER REACHED MAIN' -and $cwSrc -match 'smp-pipeline-bot' -and $cwSrc -match "(Invoke-Native\s+'git'|&\s*git)") {
  Ok 'capture-watchdog asks git whether the pipeline output actually reached main'
} else { Bad 'capture-watchdog lost the reached-main check - the four-day silent staleness of 2026-08-18..22 becomes invisible again' }
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
} # u051-the-fixture-must-not-care-what-a
# (k0) THE SAME RULE, AT THE SCHEDULED ENTRY POINTS (2026-08-22). The check above pins ONE call site.
# The rule is general, and on 2026-08-22 it was being broken at two others that this file never looked at:
# capture-run.ps1's downstream call and capture-watchdog.ps1's audit-ad-status call. Both are reached by the
# TC Windows tasks, which as of that date are the ONLY routines that fire, so both failures surfaced purely
# as an unexplained red task result. Classic one-copy-of-the-rule-per-caller drift: the lesson was written
# down here, and the two newest callers never inherited it. test-native-stderr-eap.ps1 proves the shell
# behaviour empirically (a must-fire founding case plus a clean twin) AND scans those entry points, so this
# check is a real invocation rather than another hand-maintained regex.
# 2026-09-11: the fixture's scan reads every .ps1 below the repo root, not grocery\ alone, so its inputs are all of them.
if (Use-Unit 'u052-k0-the-same-rule-at-the-scheduled' -Reads '**.ps1') {
try {
  $eapT = Join-Path $root 'test-native-stderr-eap.ps1'
  if (Test-Path $eapT) {
    $eapOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $eapT
    $eapRc = $LASTEXITCODE
    if ($eapRc -eq 0 -and (@($eapOut) -join "`n") -match 'NATIVE-STDERR-EAP-TEST-COMPLETE') {
      Ok 'native-stderr/EAP fixture passes - no script in the repo adds a native child stderr redirect under EAP=Stop beyond its named baseline'
    } else {
      Bad ('native-stderr/EAP fixture FAILED (rc=' + $eapRc + '): ' + ((@($eapOut) | Where-Object { $_ -match 'FAIL' }) -join ' | '))
    }
  } else {
    Bad 'test-native-stderr-eap.ps1 is MISSING - the 2026-08-22 exit-1 class has no fixture any more'
  }
} catch { Bad ('native-stderr/EAP fixture threw: ' + $_.Exception.Message) }
} # u052-k0-the-same-rule-at-the-scheduled
# (k1e) THE DRIFT SCANNER COULD NOT READ THE LANGUAGE IT SCANS (2026-07-30). audit-store-registry hunts
# hardcoded store lists in live .ps1 source. It recognised a store name written plainly, as &#39; and as
# &rsquo; - but NOT as '', which is how an apostrophe is actually written inside a single-quoted PowerShell
# string. test-auditors seeds all 7 stores onto one fixture line with Baker''s and Sam''s Club escaped, so
# the guard reported "names 5 store(s) but is missing Baker's, Sam's Club" against a line naming every one.
# Permanently red on correct code, which is how a drift guard gets ignored. The variant list is read out of
# the real file and EXERCISED below, so this tracks behaviour rather than a spelling.
if (Use-Unit 'u053-k1e-the-drift-scanner-could-not-read') {
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
} # u053-k1e-the-drift-scanner-could-not-read
# (k1f) A CONSISTENCY GUARD THAT COULD SCORE PERFECT FROM AN EMPTY REGEX (2026-07-30). Every audit-board-
# consistency finding comes from one regex over rendered chip markup, and nothing checked the regex matched
# anything: a missing feed or a one-attribute markup drift would print "no-link=0", exit 0, and be logged by
# check-ad-cycles as "consistency OK" - the blindest state wearing the healthiest label. 3,164 chips are
# examined on a healthy run, so the new exit-3 branch is 3,164 away from arming.
if (Use-Unit 'u054-k1f-a-consistency-guard-that-could') {
$abcSrc = Get-Content (Join-Path $root 'audit-board-consistency.ps1') -Raw
if ($abcSrc -match 'chips_examined\s*=\s*\$chipsSeen') { Ok 'board-consistency records chips_examined in its report' }
else { Bad 'board-consistency no longer records chips_examined - a blind run is indistinguishable from a clean one' }
if ($abcSrc -match '(?s)if\s*\(\s*\$chipsSeen\s*-eq\s*0\s*\)\s*\{[^}]*exit 3') { Ok 'board-consistency exits 3 (could-not-evaluate) when it examined zero chips' }
else { Bad 'board-consistency no longer exits 3 from zero chips - "no-link=0 out of 0" would read as a pass' }
if ($cacSrc -match 'consistency BLIND') { Ok 'check-ad-cycles has the matching exit-3 branch (a blind run is not logged as OK)' }
else { Bad 'check-ad-cycles lost its consistency exit-3 branch - an exit 3 falls into the else and is logged "consistency OK"' }
} # u054-k1f-a-consistency-guard-that-could
# (k1d) AN AUDIT THAT DIED ON ITS OWN FIRST FINDING (2026-07-30). audit-everyday-mismatch built each bug
# record with price=[double]$e.price. 579 of the 2,987 stored link prices are strings like "$1.88", [double]
# on one of those throws, and it threw INSIDE the record for the first mismatch found - under EAP=Stop, so the
# audit reported nothing whenever it had anything to report. Clean board: silent. Board with bugs: silent. The
# price was already parsed safely two lines earlier into $sp. With the fix it checks 2,427 everyday cells and
# finds 43 real mismatches (brand-swapped links inside the 0.32 factor tolerance, which name-drift's token test
# passes because board and link share the commodity word). Deliberately NOT wired into any gate: 43 findings on
# a green board is a backlog to work, not a daily warn.
if (Use-Unit 'u055-k1d-an-audit-that-died-on-its-own') {
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
} # u055-k1d-an-audit-that-died-on-its-own
# (k1a) A GUARD THAT CANNOT FINISH, AND A CALLER THAT CANNOT NOTICE (2026-07-30). audit-ff-carry.ps1 wrapped a
# System.Collections.Generic.List[object] in @( ) to build its report - which throws "ArgumentException:
# Argument types do not match" in Windows PowerShell 5.1 (it is fine around a List[string], and fine around the
# bare list, which is why it reads as harmless). It threw on EVERY run since the script was wired into
# check-ad-cycles on 2026-07-13, AFTER all 464 Freshop probes and BEFORE the report, the OK line and the -Alert
# branch. Nobody saw it because the caller piped the child straight into Log, so a child that dies before its
# first Write-Output logs nothing: 'ff-carry' appears 0 times in 2,716 lines of ad-cycle-log.txt. Two failures,
# two checks - the crash itself, and the caller's inability to see a crash. The @( ) case is executed for real
# against a live List[object], not pattern-matched, so it tracks the language rather than the spelling.
if (Use-Unit 'u056-k1a-a-guard-that-cannot-finish-and-a') {
$ffcSrc = Get-Content (Join-Path $root 'audit-ff-carry.ps1') -Raw
$ffcList = New-Object System.Collections.Generic.List[object]
$ffcList.Add([pscustomobject]@{ term = 't' })
$ffcThrows = $false
try { $null = @($ffcList) } catch { $ffcThrows = $true }   # list-array-wrap:allow this fixture EXECUTES the wrap to prove PS 5.1 still throws
if ($ffcThrows) { Ok 'PS 5.1 still throws on @(List[object]) - the founding hazard is real, not a historical quirk' }
else { Bad 'PS 5.1 no longer throws on @(List[object]) - this fixture no longer proves anything; re-derive it' }
if ($ffcSrc -match 'confirmed_victims\s*=\s*@\(\$victims\)') { Bad 'audit-ff-carry wraps its List[object] in @( ) again - it will throw after all 464 probes and log nothing' }
else { Ok 'audit-ff-carry builds its report without @(List[object]) (it can reach its own report line)' }
# Two shapes hold the array at 0, 1 and many: the plain .ToArray(), or (since 2026-09-18, carry-forward) the report
# list built by Merge-FfCarriedVictims, which must itself return ,$out.ToArray(). Either one, never neither.
$ffcPlain  = $ffcSrc -match 'confirmed_victims\s*=\s*\$victims\.ToArray\(\)'
$ffcMerged = ($ffcSrc -match 'confirmed_victims\s*=\s*\$reportVictims\b') -and ($ffcSrc -match 'return\s*,\s*\$out\.ToArray\(\)')
if (-not ($ffcPlain -or $ffcMerged)) { Bad 'audit-ff-carry no longer uses .ToArray() - check the JSON shape stays [] at zero and [ {..} ] at one' }
else { Ok 'audit-ff-carry serialises its victims with .ToArray() (array shape holds at 0, 1 and many)' }
} # u056-k1a-a-guard-that-cannot-finish-and-a
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
if (Use-Unit 'u056-k1a-a-guard-that-cannot-finish-and-a') {
$ffcReal = Test-FfCarryCallerSees $cacSrc
if ($ffcReal.Count -eq 0) { Ok 'check-ad-cycles captures ff-carry, logs its output, and reads its exit code' }
else { Bad ('ff-carry caller is blind again: ' + ($ffcReal -join '; ')) }
$ffcFire = Test-FfCarryCallerSees '$fcArgs = @(1); & powershell @fcArgs | ForEach-Object { Log $_ }'
if ($ffcFire.Count -ge 2) { Ok 'ff-carry-caller fixture fires on the pipe-and-hope form that hid the crash for 17 days' }
else { Bad 'ff-carry-caller fixture went blind - piping with no exit-code check now reads as correct' }
$ffcClean = Test-FfCarryCallerSees '$fcArgs = @(1); $o = & powershell @fcArgs; $rc = $LASTEXITCODE; foreach($l in @($o)){ Log $l }'
if ($ffcClean.Count -eq 0) { Ok 'ff-carry-caller fixture stays silent on capture-then-check (clean twin)' }
else { Bad ('ff-carry-caller fixture false-positives on correct form: ' + ($ffcClean -join '; ')) }
} # u056-k1a-a-guard-that-cannot-finish-and-a
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
if (Use-Unit 'u057-k1c-a-heal-must-refresh-the-gate-s') {
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
} # u057-k1c-a-heal-must-refresh-the-gate-s
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
if (Use-Unit 'u058-k1b-the-prune-default-must-match-the') {
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
} # u058-k1b-the-prune-default-must-match-the
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
if (Use-Unit 'u059-k2-the-phase-wiring-audit-coverage') {
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
} # u059-k2-the-phase-wiring-audit-coverage

# ---- A HELD BOARD MUST HOLD THE THINGS COSTED OFF IT (2026-09-07, queue 2026-09-07-e9edb9) -------------
# On 2026-09-07 guards correctly refused the board at 08:13:34 and the publish of public/** honoured that.
# Nothing BELOW the ship boundary did. free-rotation republished the hub at 08:15:25 and build-hub-grid
# -Publish shipped 591 recipe cards at 08:17:42, priced off the refused board, while the live feed still
# said week_of 2026-09-06 - so a reader saw card costs from a board that does not exist. Three call sites
# write to Ghost after the boundary and all three now read the same $guardsBlocked the publish reads.
# A SOURCE ASSERTION, deliberately: these three shell out to Ghost-publishing children, and a fixture that
# actually ran them would either publish to the live site or prove nothing about the live wiring. The
# checker below is exercised against a source with the gate REMOVED, so it cannot pass while blind.
if (Use-Unit 'u060-a-held-board-must-hold-the-things') {
$cacSrc = (Expand-SelfTestPointers -Text ((Expand-SelfTestPointers -Text ([IO.File]::ReadAllText((Join-Path $root 'check-ad-cycles.ps1'))) -Path (Join-Path $root 'check-ad-cycles.ps1'))) -Path (Join-Path $root 'check-ad-cycles.ps1'))
} # u060-a-held-board-must-hold-the-things
function Test-CacInspectGating([string]$src) {
  $bad = New-Object System.Collections.Generic.List[string]
  $lines = @($src -split "`r?`n")
  # Each publisher must sit UNDER a guard-verdict test: on its own line, or within the three lines above
  # it (build-hub-grid's call is a two-line try/catch inside an if block). Three lines is deliberately
  # tight - it proves the gate is the one wrapping this call, not one further up the file.
  foreach ($call in @('top5-weekly.ps1', 'rotate-free-dinners.ps1', ('build-hub-grid.ps1' + "'),'-Publish'"))) {
    $hit = $false; $seen = $false
    for ($li = 0; $li -lt $lines.Count; $li++) {
      if ($lines[$li] -notmatch [regex]::Escape($call)) { continue }
      $seen = $true
      $lo = [Math]::Max(0, $li - 3)
      $window = ($lines[$lo..$li] -join "`n")
      # THE NEEDLE IS THE NEGATIVE FORM, not the bare variable name. The line directly above top5-weekly
      # is the `if ($guardsBlocked) { Log 'held: ...' }` announcement, so a check looking merely for the
      # variable would read that as the gate and pass on a source with the real gate removed. Measured:
      # it did, and the must-fire case below found 2 of 3 instead of 3.
      if ($window.Contains('-not $guardsBlocked')) { $hit = $true }
    }
    if (-not $seen) { $bad.Add($call + ' is not invoked at all - the check cannot see its subject') }
    elseif (-not $hit) { $bad.Add($call + ' is invoked without reading the guard verdict') }
  }
  # ...and the ship-path line must stop claiming a held board was published
  if ($src -notmatch 'SHIP PATH COMPLETE[^\n]*HELD \(guards blocked it\)') { $bad.Add('the SHIP PATH COMPLETE log has no held-board wording') }
  # ...AND IT MUST READ THE PUBLISH RETURN CODE (2026-09-20, queue 2026-09-19-bb10f1). The guards-held
  # branch above was the 2026-09-07 half of this class. The other half is the publish OUTCOME: on
  # 2026-09-19 the summary announced 'the board, the feed and the cards are published' three seconds
  # after 'AUTO-PUBLISH ERROR (rc=1)', because it was derived from $guardsBlocked alone while the
  # outcome it describes has three inputs. The region between the markers is what must consult $pubrc.
  $ssM = [regex]::Match($src, '(?s)<<SHIP-SUMMARY-BEGIN>>(.*?)<<SHIP-SUMMARY-END>>')
  if (-not $ssM.Success) { $bad.Add('the SHIP-SUMMARY region markers are gone - the ship-path summary cannot be tested against frozen values') }
  elseif ($ssM.Groups[1].Value -notmatch '\$pubrc') { $bad.Add('the SHIP PATH COMPLETE log does not read the publish return code') }
  return $bad
}
if (Use-Unit 'u060-a-held-board-must-hold-the-things') {
$cacLive = @(Test-CacInspectGating $cacSrc)
if ($cacLive.Count -eq 0) { Ok 'check-ad-cycles gates the three Ghost-publishing INSPECT stages on the guard verdict, and the ship-path log says so when the board is held' }
else { Bad ('a refused board can still reach readers through the INSPECT path: ' + ($cacLive -join '; ')) }
# MUST FIRE: the 2026-09-07 shape, built by deleting the gate from the LIVE source rather than transcribing
# it, so the case encodes the bug permanently and cannot pass by finding nothing. A literal .Replace, not a
# regex: a double-quoted PowerShell pattern would expand the variable name it is looking for to nothing.
$cacBroke = $cacSrc.Replace('if (-not $guardsBlocked)', 'if ($true)')
$cacFired = @(Test-CacInspectGating $cacBroke)
if ($cacFired.Count -eq 3 -and ($cacFired -join ' ') -match 'top5-weekly' -and ($cacFired -join ' ') -match 'rotate-free-dinners' -and ($cacFired -join ' ') -match 'build-hub-grid') {
  Ok 'the INSPECT-gating check FIRES on a source with the guard verdict stripped, and names all three Ghost publishers'
} else { Bad ('the INSPECT-gating check did NOT fire correctly on the stripped fixture (' + $cacFired.Count + ' finding(s)): [' + ($cacFired -join '; ') + '] - it would not have caught the 2026-09-07 defect') }
# MUST FIRE: the 2026-09-19 shape (queue 2026-09-19-bb10f1), built the same way - by blinding the LIVE
# source to $pubrc, never by transcribing a fixture. A literal .Replace, not a regex, for the same reason.
$cacBlind = $cacSrc.Replace('$pubAttempted -and $pubrc -eq 0', '$pubAttempted')
$cacBlind = $cacBlind.Replace('$pubAttempted -and $pubrc -eq 2', '$false')
$cacBlind = $cacBlind.Replace('publish rc ' + "' + " + '$pubrc', "'")
$cacBlindF = @(Test-CacInspectGating $cacBlind)
if (($cacBlindF -join ' ') -match 'does not read the publish return code') {
  Ok 'the ship-summary check FIRES on a source whose SHIP-SUMMARY region no longer reads $pubrc - the 2026-09-19 "published" line over an rc-1 publish'
} else { Bad ('the ship-summary check did NOT fire on a $pubrc-blinded source (' + $cacBlindF.Count + ' finding(s)): [' + ($cacBlindF -join '; ') + '] - a publish failure would announce itself as a publish again') }
# MUST FIRE: the region markers themselves. Without them nothing below can execute the real decision.
$cacNoMark = $cacSrc.Replace('<<SHIP-SUMMARY-BEGIN>>', '<<GONE>>')
$cacNoMarkF = @(Test-CacInspectGating $cacNoMark)
if (($cacNoMarkF -join ' ') -match 'SHIP-SUMMARY region markers are gone') { Ok 'the ship-summary check FIRES when the SHIP-SUMMARY region markers are removed - it cannot pass by finding nothing' }
else { Bad 'the ship-summary check did not notice the SHIP-SUMMARY markers being removed - it would EXAMINE NOTHING and report clean' }
# ---- THE REGION ITSELF, EXTRACTED AND RUN against frozen values (the WATCHERS-DECISION convention).
# A copy of a decision is a decision that can drift, so this executes the live source's own branch.
# ---- PUBLISH-HELD-GATE: ONE EXIT CODE, FOUR GATES (2026-09-20, queue 2026-09-20-417020).
# publish-deals-page.ps1 exits 2 from four different hard gates and the chain named the first of them for all
# four, so the 2026-09-20 12:15 match-soundness hold paged as "Grocery page HELD (coverage) ... a store's pull
# produced too few commodities. Check the store pulls." The store pulls were fine. The founding lines below are
# copied from publish-deals-page.ps1's own Write-Output calls, so a reworded gate makes these go red on purpose.
$phgSrcM = [regex]::Match($cacSrc, '(?s)<<PUBLISH-HELD-GATE-BEGIN>>[^\r\n]*\r?\n(.*?)\r?\n[ \t]*# <<PUBLISH-HELD-GATE-END>>')
if (-not $phgSrcM.Success) {
  Bad 'PUBLISH-HELD-GATE region is GONE from check-ad-cycles.ps1 - this check EXAMINED NOTHING, the held-gate naming is untested'
} else {
  $phgRegionSrc = $phgSrcM.Groups[1].Value
  . ([scriptblock]::Create($phgRegionSrc))
  # MUST FIRE: the founding hold, verbatim from publish-deals-page.ps1:224 and ad-cycle-log 2026-09-20 12:15:39.
  $phgMs = 'HELD: commodity matching changed vs the reviewed baseline (see out\audit\soundness-report.json). A product MOVED/DROPPED commodity. Review, then `audit-match-soundness.ps1 -Accept` (or -Force to override).'
  $phg = Get-PublishHeldGate @($phgMs)
  if ($phg.gate -eq 'match-soundness' -and $phg.why -notmatch "store's pull" -and $phg.why -match '(?i)match-baseline') {
    Ok 'publish-held-gate: MUST FIRE - the 2026-09-20 12:15 hold is named match-soundness and its body sends the reader to the baseline, never to the store pulls'
  } else { Bad ('publish-held-gate: the match-soundness hold is still mis-named - gate=' + $phg.gate + ' why=' + $phg.why) }
  # MUST FIRE: the other two gates that shared the coverage wording.
  $phg = Get-PublishHeldGate @('HELD: a staple commodity is missing a store tile (see out\store-coverage-report.json). NOT publishing (run -Force to override once the render is fixed).')
  if ($phg.gate -eq 'store-coverage') { Ok 'publish-held-gate: MUST FIRE - a store-tile hold is named store-coverage' }
  else { Bad ('publish-held-gate: the store-coverage hold reads as ' + $phg.gate) }
  $phg = Get-PublishHeldGate @('HELD: a commodity is not in exactly one category (see out\category-coverage-report.json) - it would render in no filter. Add it to a category in categories.json (or -Force to override).')
  if ($phg.gate -eq 'category-coverage') { Ok 'publish-held-gate: MUST FIRE - a category hold is named category-coverage' }
  else { Bad ('publish-held-gate: the category-coverage hold reads as ' + $phg.gate) }
  # MUST NOT FIRE: an rc 2 this reader cannot place must NOT assert a gate. Fail closed, in words.
  $phg = Get-PublishHeldGate @('HELD: some gate nobody has written yet refused the page')
  if ($phg.gate -eq 'unnamed' -and $phg.why -match '(?i)does not recognise') {
    Ok 'publish-held-gate: MUST NOT FIRE - an unrecognised HELD line names no gate and says so, instead of guessing coverage'
  } else { Bad ('publish-held-gate: an unrecognised HELD line was assigned gate=' + $phg.gate) }
  $phg = Get-PublishHeldGate @()
  if ($phg.gate -eq 'unnamed' -and -not $phg.held) { Ok 'publish-held-gate: MUST NOT FIRE - rc 2 with no verdict line at all names no gate' }
  else { Bad ('publish-held-gate: an empty verdict list produced gate=' + $phg.gate) }
  # CLEAN TWIN: the behaviour that already worked. The real coverage hold still reads coverage, and still
  # sends the reader to the store pulls - that sentence was RIGHT for this one gate and must survive.
  $phg = Get-PublishHeldGate @('HELD: coverage gate failed - only 300 commodities (need >= 400). NOT publishing (a store''s pull likely failed; run -Force to override).')
  if ($phg.gate -eq 'coverage' -and $phg.why -match "store's pull") {
    Ok 'publish-held-gate: CLEAN TWIN - a real coverage hold is still named coverage and still sends the reader to the store pulls'
  } else { Bad ('publish-held-gate: the coverage branch broke on its way past - gate=' + $phg.gate + ' why=' + $phg.why) }
  # CLEAN TWIN: the HELD line is picked out of a real stdout mixed with the other verdict shapes.
  $phg = Get-PublishHeldGate @('price-mode: in-store', 'name-drift: 0 suppressed', $phgMs)
  if ($phg.gate -eq 'match-soundness') { Ok 'publish-held-gate: CLEAN TWIN - the HELD line is found among the price-mode and name-drift verdict lines around it' }
  else { Bad ('publish-held-gate: a HELD line below other verdict lines was missed - gate=' + $phg.gate) }
  # MUST FIRE (2026-09-23): the served-board hold, verbatim in shape from publish-deals-page.ps1, names its own gate and
  # never reads as coverage - the hand-run post that named board.json?v=780837d352 over a feed serving 34d164ae13.
  $phg = Get-PublishHeldGate @('HELD: the board this post names is not served by feed.thriftycrew.com yet - the post names board.json?v=780837d352 but feed.thriftycrew.com serves v=34d164ae13. NOT publishing: land the push, let the edge serve that board, then publish (nothing was written to Ghost).')
  if ($phg.gate -eq 'board-not-served' -and $phg.why -match '(?i)nothing was written to ghost') { Ok 'publish-held-gate: MUST FIRE - a post over an unserved board is named board-not-served' }
  else { Bad ('publish-held-gate: the served-board hold reads as ' + $phg.gate) }
  $phg = Get-PublishHeldGate @('HELD: could not confirm the board this post names is served by feed.thriftycrew.com - could not read the served board from feed.thriftycrew.com (timed out). NOT publishing: land the push, let the edge serve that board, then publish (nothing was written to Ghost).')
  if ($phg.gate -eq 'board-not-served') { Ok 'publish-held-gate: MUST FIRE - an unreachable feed is named board-not-served, never a pass and never coverage' }
  else { Bad ('publish-held-gate: the unreachable-feed hold reads as ' + $phg.gate) }
}
$ssSrcM = [regex]::Match($cacSrc, '(?s)<<SHIP-SUMMARY-BEGIN>>[^\r\n]*\r?\n(.*?)\r?\n[ \t]*# <<SHIP-SUMMARY-END>>')
if (-not $ssSrcM.Success) {
  Bad 'SHIP-SUMMARY region is GONE from check-ad-cycles.ps1 - this check EXAMINED NOTHING, the five-way summary is untested'
} else {
  # $ssRegionSrc, NOT $SS: PowerShell variable names are CASE-INSENSITIVE, so a region held in $SS and a
  # result held in $ss are ONE variable. The first call then overwrote the region text with its own result
  # hashtable and the second dot-sourced the string "System.Collections.Hashtable" - a command-not-found
  # that killed the suite mid-run with no FAIL line. Same trap as the $pS/$PS one in the gate-slot work.
  $ssRegionSrc = $ssSrcM.Groups[1].Value
  function SsRun([bool]$blocked, [bool]$attempted, $rc) {
    $guardsBlocked = $blocked; $pubAttempted = $attempted; $pubrc = $rc
    $shipSecs = 726; $summary = @()
    $logged = New-Object System.Collections.Generic.List[string]
    function Log($m) { [void]$logged.Add([string]$m) }
    . ([scriptblock]::Create($ssRegionSrc))
    return @{ log = ($logged -join "`n"); summary = (@($summary) -join "`n") }
  }
  # MUST FIRE: the founding run. rc 1, guards green, a publish attempted - the 2026-09-19 17:23 shape.
  $ss = SsRun $false $true 1
  if ($ss.log -match 'NOT updated' -and $ss.log -match 'rc 1' -and $ss.log -notmatch 'the board, the feed and the cards are published') {
    Ok 'ship summary: MUST FIRE - a publish that exited 1 logs "NOT updated" and "rc 1", and never the published wording (the 2026-09-19 17:23:21 line)'
  } else { Bad ('ship summary: an rc-1 publish still announces a publish - [' + $ss.log + ']') }
  # MUST FIRE: rc 2 is the coverage HELD branch and says so rather than claiming a publish.
  $ss = SsRun $false $true 2
  if ($ss.log -match 'HELD by the coverage gate' -and $ss.log -notmatch 'the board, the feed and the cards are published') {
    Ok 'ship summary: MUST FIRE - an rc-2 publish logs "HELD by the coverage gate", not a publish'
  } else { Bad ('ship summary: the rc-2 coverage-held branch is wrong - [' + $ss.log + ']') }
  # MUST NOT FIRE: guards blocked. The 2026-09-07 wording, unchanged, and no published claim.
  $ss = SsRun $true $false $null
  if ($ss.log -match 'HELD \(guards blocked it\)' -and $ss.log -notmatch 'the board, the feed and the cards are published') {
    Ok 'ship summary: MUST NOT FIRE - a guards-held run still logs the 2026-09-07 held wording and claims no publish'
  } else { Bad ('ship summary: the guards-held branch changed - [' + $ss.log + ']') }
  # CLEAN TWIN: the success path is untouched, BYTE FOR BYTE. Other readers grep this sentence.
  $ss = SsRun $false $true 0
  if ($ss.log -match 'the board, the feed and the cards are published' -and $ss.summary -match 'the board published before any advisory audit ran') {
    Ok 'ship summary: CLEAN TWIN - an rc-0 publish still logs "the board, the feed and the cards are published" and its original summary line'
  } else { Bad ('ship summary: the rc-0 success wording moved - every reader that greps it is now blind - [' + $ss.log + ']') }
  # CLEAN TWIN: no publish attempted (no price change) says so instead of inheriting either other branch.
  $ss = SsRun $false $false $null
  if ($ss.log -match 'no price change' -and $ss.log -notmatch 'the board, the feed and the cards are published' -and $ss.log -notmatch 'NOT updated') {
    Ok 'ship summary: CLEAN TWIN - a run with no publish attempt says the page stands as last published'
  } else { Bad ('ship summary: the not-attempted branch is wrong - [' + $ss.log + ']') }
  # EVERY BRANCH STILL WRITES A SUMMARY LINE. A silent branch is the failure a five-way split invites.
  $ssAll = @((SsRun $false $true 1), (SsRun $false $true 2), (SsRun $true $false $null), (SsRun $false $true 0), (SsRun $false $false $null))
  $ssEmpty = @($ssAll | Where-Object { -not $_.summary -or -not $_.log })
  if ($ssEmpty.Count -eq 0) { Ok 'ship summary: every one of the five branches writes both a log line and a summary line - none is silent' }
  else { Bad ('ship summary: ' + $ssEmpty.Count + ' of 5 branches wrote no summary or no log line - the run would report nothing about what shipped') }
}
# THE PUBLISH VERDICT LINES: the one line that named the failing stage was being discarded.
if ($cacSrc -match "publish-verdict: ") { Ok 'check-ad-cycles logs publish-deals-page''s own verdict lines, so a failed publish names its stage in the log' }
else { Bad 'check-ad-cycles keeps only timing-table lines from the publish: the reason a publish failed is discarded at the moment it is known (the 2026-09-19 17:23 defect)' }
} # u060-a-held-board-must-hold-the-things

# ---------------------------------------------------------------- (k3) sale-fallback reads the ENGINE's
# fileset, not its own newest-file-per-store (2026-09-02, queue 2026-09-02-5df03f).
# THE FOUNDING SHAPE, FROZEN VERBATIM. Walmart is the only everyday-only store, so compare-deals prices it
# from a 90-day UNION of captures while a daily Walmart capture is a 7-to-25-term rotation slice by policy.
# audit-sale-fallback opened one file per store, newest by name, so it asked whether today's 12-term slice
# happened to contain an everyday twin - a question about the capture cursor, not about the board. On
# 2026-09-02 that made 23 of 28 flagged cells false and sent 23 research rows to the weekly browser agent
# for products the union already held.
# The frozen twin below is the real one: ground-beef-8020's everyday row '80% Lean / 20% Fat Ground Beef
# Chuck, 10 lb Roll, Fresh, All Natural' at $49.43, which sat in walmart-regular-2026-08-31 while the
# newest file (09-01) was a rotation slice that did not carry it. NEVER regenerate these two files from the
# live out\regular tree: the whole point is that the newer file does NOT hold the twin, and a regenerated
# pair would encode whatever the cursor happens to be that day and pass by finding nothing.
if (Use-Unit 'u061-k3-sale-fallback-reads-the-engine-s') {
$fxSf = NewFxDir 'sale-fallback-union'
New-Item -ItemType Directory -Force (Join-Path $fxSf 'regular') | Out-Null
$sfBoard = '{"week_of":"2026-09-02","comparison":[{"commodity":"Ground Beef 80/20","id":"ground-beef-8020","unit":"lb","stores":[{"store":"Walmart","type":"sale","per_unit":4.943,"item":"80% Lean / 20% Fat Ground Beef Chuck, 10 lb Roll, Fresh, All Natural"}]}]}'
Set-Content (Join-Path $fxSf 'comparison-2026-09-02.json') $sfBoard -Encoding UTF8
# the 09-01 rotation slice: 7 real terms, none of them ground beef. This is the file the OLD code read.
Set-Content (Join-Path $fxSf 'regular\walmart-regular-2026-09-01.json') '{"store":"Walmart","deals":[{"name":"Fresh Bananas, each"},{"name":"Dial Gold Bar Soap, 8 Bars"},{"name":"Energizer MAX AA Batteries, 8 Pack"},{"name":"Great Value Bay Leaves, 0.15 oz"},{"name":"Sweet Baby Ray''s Barbecue Sauce, 40 oz"},{"name":"Fresh Bean Sprouts, 10 oz"},{"name":"Swanson Beef Broth, 32 oz"}]}' -Encoding UTF8
# MUST-FIRE: the twin is in NEITHER file. A cell on sale with no everyday row anywhere in the union is a
# REAL gap and must still page, or this change would have bought silence rather than accuracy.
Set-Content (Join-Path $fxSf 'regular\walmart-regular-2026-08-31.json') '{"store":"Walmart","deals":[{"name":"Great Value Whole Milk, 1 Gallon"},{"name":"Marketside Rotisserie Chicken"}]}' -Encoding UTF8
$r = RunPS 'audit-sale-fallback.ps1' @('-OutDir', $fxSf, '-CompareFile', (Join-Path $fxSf 'comparison-2026-09-02.json'))
if ($r.rc -eq 2 -and $r.text -match 'ground-beef-8020\s+Walmart') { Ok 'sale-fallback MUST-FIRE: a sale cell with no everyday twin in ANY file of the union still pages (exit 2)' }
else { Bad ('sale-fallback did NOT page on a real gap (rc=' + $r.rc + ') - widening the fileset has silenced the guard instead of correcting it: ' + ($r.text -replace "`n", ' ')) }
# CLEAN TWIN: the exact 2026-09-02 shape. The everyday twin exists ONLY in the OLDER 08-31 capture; the
# newest file is still the rotation slice without it. Before the fix this exits 2; after it, 0.
Set-Content (Join-Path $fxSf 'regular\walmart-regular-2026-08-31.json') '{"store":"Walmart","deals":[{"name":"80% Lean / 20% Fat Ground Beef Chuck, 10 lb Roll, Fresh, All Natural"},{"name":"Marketside Rotisserie Chicken"}]}' -Encoding UTF8
$r = RunPS 'audit-sale-fallback.ps1' @('-OutDir', $fxSf, '-CompareFile', (Join-Path $fxSf 'comparison-2026-09-02.json'))
if ($r.rc -eq 0) { Ok 'sale-fallback clean twin: an everyday twin in an OLDER Walmart capture inside the union counts, so the 12-term slice no longer manufactures a gap' }
else { Bad ('sale-fallback still flags a cell whose everyday twin sits in an older file of the engine union (rc=' + $r.rc + ') - it is back on newest-file-per-store, and Walmart''s rotation slices will page every day: ' + ($r.text -replace "`n", ' ')) }
# and the auditor must SAY what it read - a pool built from zero files answers "no twin" for every cell.
if ($r.text -match 'everyday pool from the engine fileset' -and $r.text -match 'Walmart=2f/') { Ok 'sale-fallback reports its per-store pool size, so an empty pool is visible on the run that produces it' }
else { Bad ('sale-fallback no longer reports the per-store everyday pool it built (expected Walmart=2f/ from the union) - an empty pool is indistinguishable from a store with no twins: ' + ($r.text -replace "`n", ' ')) }
} # u061-k3-sale-fallback-reads-the-engine-s

# ---------------------------------------------------------------- (k3b) sale-fallback alerts by OWNERSHIP,
# and that ownership EXPIRES (2026-09-03, queue 2026-09-03-b844ab).
# THE FOUNDING SHAPE: every gap this auditor finds is routed to an owner by this same script - browser
# stores to research-worklist.json for the weekly agent, Family Fare to the daily self-heal - and then the
# daily job emailed the whole list anyway. b844ab spent an entire triage item establishing that all five
# cells were already queued, i.e. confirming a no-op. The fix routes the email by ownership.
# The DANGER of that fix is that it is one line away from being a permanent mute, so these three cases pin
# the escape hatch rather than the silence: a fresh gap is quiet, an ABANDONED one is loud, and a ledger we
# cannot read makes everything loud. Delete any of them and the mute becomes unconditional.
if (Use-Unit 'u062-k3b-sale-fallback-alerts-by') {
$sfLedger = Join-Path $fxSf 'sale-fallback-ownership.json'
Set-Content (Join-Path $fxSf 'regular\walmart-regular-2026-08-31.json') '{"store":"Walmart","deals":[{"name":"Great Value Whole Milk, 1 Gallon"},{"name":"Marketside Rotisserie Chicken"}]}' -Encoding UTF8
# CLEAN TWIN: a gap seen for the FIRST time is owned and inside its grace window, so it must NOT escalate.
# gap_count must still be 1 - the gap is reported and pre-publish still sees it; only the email is gated.
Remove-Item $sfLedger -Force -ErrorAction SilentlyContinue
$r = RunPS 'audit-sale-fallback.ps1' @('-OutDir', $fxSf, '-CompareFile', (Join-Path $fxSf 'comparison-2026-09-02.json'))
$sfg = try { Read-JsonFile (Join-Path $fxSf 'sale-fallback-gaps.json') } catch { $null }
if ($sfg -and [int]$sfg.gap_count -eq 1 -and [int]$sfg.escalated_count -eq 0 -and [string]@($sfg.owned)[0].owner -eq 'capture-plan:Walmart') { Ok 'sale-fallback clean twin: a first-seen browser gap is OWNED by its store''s capture plan and does not escalate, while gap_count still reports it (b844ab noise gone, visibility kept)' }
else { Bad ('sale-fallback did not route a fresh browser gap to its owner (gap_count=' + [int]$sfg.gap_count + ' escalated=' + [int]$sfg.escalated_count + ') - the b844ab alert is either back, or the gap has vanished from the report entirely: ' + ($r.text -replace "`n", ' ')) }
# MUST-FIRE 1: the SAME gap, still unworked past the weekly agent's grace window, must escalate. This is the
# whole reason the routing is safe. first_seen is 2026-07-01 against a 2026-09-02 board = 63d, grace 16d.
'{"ground-beef-8020|Walmart":{"first_seen":"2026-07-01","owner":"capture-plan:Walmart"}}' | Set-Content $sfLedger -Encoding UTF8
$r = RunPS 'audit-sale-fallback.ps1' @('-OutDir', $fxSf, '-CompareFile', (Join-Path $fxSf 'comparison-2026-09-02.json'))
$sfg = try { Read-JsonFile (Join-Path $fxSf 'sale-fallback-gaps.json') } catch { $null }
if ($sfg -and [int]$sfg.escalated_count -eq 1 -and [int]@($sfg.escalated)[0].age_days -gt 16) { Ok 'sale-fallback MUST-FIRE: a gap its owner has not cleared in 63d escalates past the 16d grace - ownership routing cannot become a permanent mute' }
else { Bad ('sale-fallback did NOT escalate a gap abandoned for 63 days (escalated=' + [int]$sfg.escalated_count + ') - browser-store gaps can now sit forever with nobody looking, which is worse than the noise this replaced: ' + ($r.text -replace "`n", ' ')) }
# MUST-FIRE 2: an unreadable ledger FAILS CLOSED. Resetting it to empty would restart every clock silently
# and make the expiry above unreachable - the shape where a gate quietly stops being able to arm.
'{ this is not json' | Set-Content $sfLedger -Encoding UTF8
$r = RunPS 'audit-sale-fallback.ps1' @('-OutDir', $fxSf, '-CompareFile', (Join-Path $fxSf 'comparison-2026-09-02.json'))
$sfg = try { Read-JsonFile (Join-Path $fxSf 'sale-fallback-gaps.json') } catch { $null }
if ($sfg -and [int]$sfg.escalated_count -eq 1 -and [bool]$sfg.ledger_unreadable) { Ok 'sale-fallback MUST-FIRE: a corrupt ownership ledger escalates every gap and says so, instead of silently restarting the clocks' }
else { Bad ('sale-fallback did not fail closed on an unreadable ownership ledger (escalated=' + [int]$sfg.escalated_count + ' flag=' + [bool]$sfg.ledger_unreadable + ') - a deleted or corrupt ledger would now mute every gap forever: ' + ($r.text -replace "`n", ' ')) }
Remove-Item $fxSf -Recurse -Force -ErrorAction SilentlyContinue
} # u062-k3b-sale-fallback-alerts-by
