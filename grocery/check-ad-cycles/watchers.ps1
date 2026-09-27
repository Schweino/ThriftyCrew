# ---- WATCH THE WATCHERS - ALWAYS, outside the downstream branch (hoisted 2026-07-28) ----
# A guard that reports nothing looks exactly like a guard that is broken, and on 2026-07-28 three of them
# were broken at once while "passing" for days. test-auditors.ps1 replays each watcher's founding bug
# against a frozen fixture and asserts it still fires (and stays silent on the clean twin).
# This deliberately sits OUTSIDE `if ($serverDue -and ... -and (-not $hardFail))`. It used to live inside,
# which meant it was skipped on exactly the days a guard hard-failed - the days you most need to know
# whether the guards themselves can still be trusted. It depends on nothing but its own fixtures, so there
# is no reason for it ever to be conditional. A blind watcher has to be LOUDER than the thing it watches:
# if this fails, every quiet guard above it becomes unproven, including a clean board.
# CADENCE (7d): replays frozen fixtures against guard SOURCE; 877 s. Due on any .ps1 edit, so a commit that blinds a guard is still caught the same day.
# *** THE ONE CADENCE GATE THAT WAS NOT INSIDE A try, AND IT COST A WHOLE CHAIN (2026-08-23). ***
# There are ten Test-CadenceDue call sites in this file. Nine of them are inside their block's own
# try/catch; this one IS the block's `if`, at top level, with nothing around it. On 2026-08-23 the
# helpers had never actually been implemented (see e9731395 - `git log -S "function Test-CadenceDue"`
# returned nothing), so every call site raised CommandNotFoundException. Under $ErrorActionPreference =
# 'Stop' that is a TERMINATING error: the nine inside a try logged "threw" and skipped their audit, and
# THIS ONE killed check-ad-cycles outright, mid-run, with no message of its own.
# What that cost, read off ad-cycle-log.LOCKED-2026-08-23.txt, whose last two lines are prune-out and
# prune-intermediates and then nothing at all: no test-auditors, no test-guards weekly, no ghost-drift,
# no cloudflare-estate, no search-links, no cycle-phase coverage ratchet, and no `run complete` line.
# This script has no `exit` statement anywhere, so a terminating error is also the ONLY way it returns
# non-zero - which is the entire content of capture-run's "FAILED LANES: ... downstream" that morning.
# The chain looked like it had failed at its last step; it had actually died two thirds of the way in.
# (The capture-eviction audit that had to be re-run by hand that day is a DIFFERENT cause: its block is
# ~250 lines EARLIER, inside the post-publish inspect branch, which that run never entered. The crash
# here cannot explain it and must not be credited with it.)
#
# BOTH DIRECTIONS ARE NOW CLOSED. A gate that cannot decide must not skip - and must not be able to end
# the chain either. Any throw resolves to DUE and says so out loud.
#
# THE RULE FILES ARE INPUTS TOO (2026-08-30). The globs were code-only, but two of this suite's LIVE arms
# read data: dead-commodity and unit-vocabulary both sweep commodities.json (and unit-vocabulary also
# sweeps recipe-commodities.json). Both exist to catch a bad EDIT to those files - a commodity whose
# includes can never match, a unit Convert-ToUnit cannot convert - and with code-only globs such an edit
# left the suite not due, so the arm that would have caught it could sit skipped for up to seven days
# while the broken commodity quietly held no cell. The roster entry for matcher-parity already lists
# grocery/commodities.json for exactly this reason; this gate had not caught up.
$taSkip = $false
try { $taSkip = -not (Test-CadenceDue -Name 'test-auditors' -EveryDays 7 -InputGlobs @('grocery/**/*.ps1','lib/*.ps1','grocery/commodities.json','grocery/recipe-commodities.json')) }
catch { Log ('test-auditors cadence gate threw (' + $_.Exception.Message + ') - running the suite anyway; a gate that cannot decide must not skip, and must never take the rest of the chain with it') }
if ($taSkip) {
  Log ('test-auditors: SKIPPED by cadence - inputs unchanged since ' + (Get-CadenceLast 'test-auditors') + "; runs every 7d or the moment its inputs move. A SKIP IS NOT A PASS.")
} else {
try {
  # ONE RUN, OUTPUT KEPT (2026-08-22). This used to run the suite once to get the exit code and then, on a
  # failure, run it AGAIN to get the text - and it failed on 10 of the previous 14 days, so the ~3-minute
  # suite cost ~7.5 minutes per chain, the single largest item in the stage profile. Capture once.
  $taJ = Invoke-Bounded 'test-auditors' @('-ExecutionPolicy','Bypass','-File',(Join-Path $root 'test-auditors.ps1')) 1200
  $ta = ($taJ.Output -join "`n")
  $taRc = $taJ.ExitCode
  # THE KNOWN-FAILURES RECORD THE PRE-PUSH CHECK READS (2026-09-10, plan step 5). ops\hooks\pre-push runs
  # test-auditors before a push that touches one of its inputs and refuses only a failing case this record
  # does not already hold. This run is the ONLY writer allowed to add a case (a push-time run may only
  # confirm or shrink it), and it records from the output captured above; nothing re-runs. A run that did
  # not complete is not recorded, the old record ages out after 192h, and the check then refuses on any
  # failing case rather than passing quietly.
  try {
    $taRecIn = Join-Path $env:TEMP ('tc-ta-record-' + $PID + '.txt')
    [IO.File]::WriteAllText($taRecIn, [string]$ta, (New-Object Text.UTF8Encoding($false)))
    $taRecOut = @(& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path (Split-Path $root -Parent) 'ops\prepush-test-auditors.ps1') -Record -OutputFile $taRecIn -ExitCode $taRc)
    Log ('test-auditors known-failures record: ' + (@($taRecOut | Where-Object { [string]$_ -match '^prepush-test-auditors:' }) -join ' '))
    Remove-Item -LiteralPath $taRecIn -ErrorAction SilentlyContinue
  } catch { Log ('test-auditors known-failures record could not be written: ' + $_.Exception.Message) }
  if ($taRc -ne 0) {
    # <<WATCHERS-DECISION-BEGIN>> test-auditors.ps1 extracts this region and runs it against frozen rc values.
    # THREE OUTCOMES, NOT TWO (2026-09-04, queue 2026-09-04-0b63d3). This branch used to be `-ne 0`, so a
    # stale COPY of a prompt in ops\prompt-backup produced the estate's loudest page - "any quiet report from
    # that guard is unproven - including a clean board" - on a run where all 601 fixtures fired. It cost the
    # trust ordering of every other alert that morning and pointed the reader at a remedy (-Sync) that writes
    # LIVE user-scope prompt files and mirrors a personal scheduled task into a public repo.
    # FAIL CLOSED: rc 1 is the ONLY quiet-ish tier. rc 2, a crash, a throw, an Invoke-Bounded timeout (124) -
    # anything this code does not recognise - takes the BLIND path, because an unknown verdict from the
    # harness that proves the guards is a BLIND verdict. The rc-2 subject, body and file name are unchanged
    # so every existing reader and the dated evidence-file convention keep working.
    # A HYGIENE run still PAGES. It is routed, not silenced: a different subject, a different body, a
    # different summary prefix, and an evidence file of its own.
    if ($taRc -eq 1) {
      $taKind    = 'HYGIENE'
      $taSubject = 'Grocery: test-auditors hygiene finding(s) - watchers intact'
      $taLog     = 'test-auditors HYGIENE: every watcher still fires on its own founding bug; ops housekeeping drift was found'
      $taSummary = 'HYGIENE   every watcher still fires on its own founding bug; ops hygiene drift found - see the HYGIENE lines in the saved output'
      $taFileTag = 'test-auditors-hygiene'
      $taLookFor = 'HYGIENE'
      # THE WORDING IS LOAD-BEARING and is asserted by test-auditors: this body must contain neither
      # "unproven" nor "gone blind". Those two phrases are how a reader (and a grep) tells a housekeeping
      # page from a blind-watcher page, and a hygiene body that merely says it is NOT one is still a body
      # with the words in it.
      $taHeader  = "test-auditors.ps1 replays each watcher's founding bug against a frozen fixture. EVERY FIXTURE FIRED on this run: every watcher still sees the bug it was written for, and nothing here puts the board in doubt." +
                   "`n`nWhat it found is ops HYGIENE - the estate's own housekeeping (a stale prompt mirror, an uncommitted artefact, a census gap). Fix it deliberately; do NOT reach for a -Sync style remedy quoted inside a finding without reading what it writes."
    } elseif ($taRc -eq 4) {
      # FOUR OUTCOMES NOW (2026-09-20, queue 2026-09-19-ae9df2). test-auditors keeps eight LIVE-TWIN cases
      # that read live data ON PURPOSE. When one of those goes red the watcher WORKED: it found a bad cell on
      # the live board. Until today that shared the rc-2 channel and paged "any quiet report from that guard
      # is unproven - including a clean board", which is the exact inverse of the truth - on a live red the
      # watchers are the ONE thing the run proved. Three such pages in 30 days (08-28, 08-29, 09-19) and none
      # of them was a blind watcher. rc 4 is the only new mapping; everything else still fails closed below.
      $taKind    = 'LIVE'
      $taSubject = 'Grocery: the LIVE board failed a watcher (watchers intact)'
      $taLog     = 'test-auditors LIVE-RED: every watcher still fires on its own founding bug; a live-board case is red - a cell is page-worthy, not a guard'
      $taSummary = 'LIVE-RED  a live-board case failed; the watchers are intact - see the LIVE-RED lines in the saved output'
      $taFileTag = 'test-auditors-live'
      $taLookFor = 'LIVE-RED'
      # THE WORDING IS LOAD-BEARING, exactly as in the hygiene tier: neither "unproven" nor "gone blind".
      $taHeader  = "test-auditors.ps1 replays each watcher's founding bug against a frozen fixture. EVERY FIXTURE FIRED on this run: every watcher still sees the bug it was written for." +
                   "`n`nWhat is red is a LIVE-TWIN case - one that reads the LIVE board or the LIVE registry on purpose. So the finding is about a CELL, not about a guard: open the board before the code. The watchers held, and guards will have held the publish if the same condition is a hard invariant."
    } else {
      $taKind    = 'WATCHERS'
      $taSubject = 'Grocery: a GUARD has gone blind (test-auditors failed)'
      $taLog     = 'WATCHERS FAILED: test-auditors could not prove a guard still sees its own bug'
      $taSummary = 'WATCHERS  a guard can no longer see its own founding bug - see test-auditors output'
      $taFileTag = 'test-auditors-fail'
      $taLookFor = 'BAD'
      $taHeader  = "test-auditors.ps1 replays each watcher's founding bug against a frozen fixture. At least one watcher no longer fires on it, which means any quiet report from that guard is unproven - including a clean board."
    }
    # <<WATCHERS-DECISION-END>>
    Log $taLog
    $summary += $taSummary
    # PERSIST THE WHOLE THING BEFORE ALERTING (2026-07-31). send-alert used to truncate its body, and on
    # 2026-07-31T06:20 that truncation ate the only copy of WHICH case failed: the email carried the first
    # ~28 PASS lines and stopped, the log line says only "a guard has gone blind", and by the time anyone
    # read it the mid-edit working tree that produced the failure had been committed over. The failing case
    # was unrecoverable - a page about a blind guard that cannot say which guard. The file is written first
    # so it survives even if the send throws, and it is dated so consecutive failures do not overwrite each
    # other's evidence.
    #
    # THE FILE IS ALSO THE EMAIL BODY NOW (2026-08-06). This output is the one alert body in the estate with
    # no bound on it - 43 KB on each of 2026-08-03/04/05 - and passing it as a command-line -Body meant the
    # send never launched on any of those days (see Send-Alert above). It already has to be written here, so
    # hand send-alert THAT PATH: nothing on this path can be too long, and the mail carries the whole run
    # instead of the first 28 PASS lines. The explanatory header goes into the file rather than only into
    # the email, which also makes the artefact self-describing for whoever finds it days later.
    $taF = Join-Path $OutDir ($taFileTag + '-' + (Get-Date -Format 'yyyy-MM-dd') + '.txt')
    $taBody = $taHeader + "`n`n" +
              "Saved copy of this run: " + $taF + "`n" +
              "FULL test-auditors OUTPUT FOLLOWS - look for the " + $taLookFor + " lines.`n" + ('-' * 78) + "`n" + $ta
    $taSaved = $false
    try { Set-Content -Path $taF -Value $taBody -Encoding UTF8; $taSaved = $true; Log ($taKind + ': full test-auditors output saved to ' + $taF) }
    catch { Log ($taKind + ': could not save test-auditors output: ' + $_.Exception.Message) }
    if (-not $NoAlert) {
      # normal path: the evidence file IS the body. If it could not be written, Send-Alert spools the same
      # text to %TEMP% instead - a failed evidence write must not also cost us the page.
      if ($taSaved) { Send-Alert -Subject $taSubject -BodyFile $taF -What $taKind | Out-Null }
      else          { Send-Alert -Subject $taSubject -Body $taBody -What $taKind | Out-Null }
    }
  } else { Log 'watchers ok: every guard still fires on its own founding bug' }
} catch { Log ('test-auditors threw: ' + $_.Exception.Message) }
  Set-CadenceRan 'test-auditors'
}

# ---- THE WEEKLY GUARD PROOF: RUN, DEFER, STAMP (2026-09-10, queue 2026-09-10-267ba6) ----
# The weekly slot used to be spent on whatever the baseline was that morning, and stamped regardless: rc=3
# (guards already red, nothing proven) on 2026-08-27, 2026-09-03 and 2026-09-10 - three of the last four
# slots - each wrote test-guards-weekly-stamp.txt and closed the week. That stamp recorded when we last TRIED
# and never when we last PROVED, so no staleness check keyed on it could ever fire (queue 2026-09-03-eb3bce
# wrote exactly that down; nothing shipped it). Three pure functions, lifted and driven by test-cadence.ps1
# against THIS source:
#   Get-TestGuardsWeeklyPlan  due? if due, RUN only on today's green verdict, otherwise DEFER and stamp nothing.
#   Get-TestGuardsStampPlan   the weekly stamp only on an EVALUATED run (rc 0 or 1); the proved stamp on rc 0.
#   Get-TestGuardsSubject     the alert subject per rc, wording unchanged.
# THE VERDICT IS READ AS RECORDED - today's guards_rc - and not through Read-ChainVerdictStatus's fingerprint
# test. This block runs after the relink tail rewrites product-urls.json, which moves the fingerprint on a
# green day and reads STALE-INPUTS: the proof would defer on exactly the days it can run. The runner scores
# its own hermetic copy of the unmutated board anyway; the verdict only answers "is the baseline green".
# UnprovenDays = 14 is eb3bce's suggestion, not swept; at most one unproven alert per 14 days.
function Get-TestGuardsWeeklyPlan {
  param($Verdict, [string]$Today, [datetime]$WeeklyLast, [datetime]$ProvedLast, [datetime]$UnprovenAlertLast, [datetime]$Now, [int]$EveryDays = 7, [int]$UnprovenDays = 14)
  $neverProved = ($ProvedLast.Year -le 2000)
  $daysUnproven = [int][math]::Floor(($Now - $ProvedLast).TotalDays)
  $plan = [ordered]@{ action = 'not-due'; why = ''; days_unproven = $daysUnproven; never_proved = $neverProved; alert_unproven = $false }
  if ((($Now - $WeeklyLast).TotalDays) -ge $EveryDays) {
    if ($null -eq $Verdict) { $plan.action = 'defer'; $plan.why = 'no chain verdict on disk' }
    elseif ([string]$Verdict.date -ne $Today) { $plan.action = 'defer'; $plan.why = ('the chain verdict is for ' + [string]$Verdict.date + ', not ' + $Today) }
    elseif (-not ($Verdict.PSObject.Properties.Name -contains 'guards_rc')) { $plan.action = 'defer'; $plan.why = 'the chain verdict records no guards_rc' }
    elseif ([int]$Verdict.guards_rc -ne 0) { $plan.action = 'defer'; $plan.why = ('guards_rc=' + [int]$Verdict.guards_rc + ' today') }
    else { $plan.action = 'run'; $plan.why = 'due, and today''s guards verdict is green' }
  }
  if (($daysUnproven -gt $UnprovenDays) -and ((($Now - $UnprovenAlertLast).TotalDays) -ge $UnprovenDays)) { $plan.alert_unproven = $true }
  return [pscustomobject]$plan
}
function Get-TestGuardsStampPlan {
  param([int]$Rc)
  return [pscustomobject]@{ weekly = (($Rc -eq 0) -or ($Rc -eq 1)); proved = ($Rc -eq 0) }
}
function Get-TestGuardsSubject {
  param([int]$Rc, [bool]$MutationFailed = $true)
  if ($Rc -eq 3) { return 'Grocery: test-guards could not evaluate (guards already red on the unmutated board)' }
  if ($Rc -eq 4) { return 'Grocery: test-guards weekly did not run (hermetic copy failed)' }
  # A SOURCE-SCAN finding is not a blind guard (2026-09-19, queue 2026-09-19-a1c25d): that day's rc 1 was the
  # empty-stamp idiom scan alone while every mutation case still exited 2, and the subject paged as decorative.
  if (($Rc -eq 1) -and (-not $MutationFailed)) { return 'Grocery: test-guards weekly: a source-scan case failed, every invariant still fails' }
  return 'Grocery: a BLOCKING invariant can no longer fail (test-guards weekly)'
}
function Test-TestGuardsMutationFailed {
  # FAILS CLOSED: only when EVERY FAIL line is the empty-stamp source scan's "throwing idiom is back" line is it
  # scan-only. No FAIL line at all, or any other FAIL line, reads as a mutation failure (the blind subject).
  param([string]$Output)
  $fails = @(($Output -split "`r?`n") | Where-Object { $_ -match '^\s*FAIL\b' })
  if ($fails.Count -eq 0) { return $true }
  return (@($fails | Where-Object { $_ -notmatch '^\s*FAIL\s+empty-stamp: throwing idiom is back in ' }).Count -gt 0)
}

# ---- WEEKLY: prove each BLOCKING invariant can still FAIL (test-guards, hermetically) ----
# test-auditors above proves the watchers fire on frozen fixtures; test-guards proves guards.ps1 itself
# still exits 2 when an invariant is broken on purpose. It mutates live data to do it (16 windows, 9
# git-tracked files; measured 2026-07-30: a hard kill runs neither finally nor PowerShell.Exiting, and a
# foreign commit landed DURING the measured run), so it must never run against production. The runner
# copies the whole tree to %TEMP% (1.1s for 658 MB; every script roots at $PSScriptRoot) and runs there.
# Stamp-gated on >=7 days, not a weekday, so a missed week self-heals on the next daily run - and since
# 2026-09-10 the stamp means EVALUATED, and a red baseline DEFERS the run instead of spending the week on it.
try {
  $tgStampF = Join-Path $root 'test-guards-weekly-stamp.txt'
  $tgProvedF = Join-Path $root 'test-guards-proved-stamp.txt'
  $tgUnprovenF = Join-Path $root 'test-guards-unproven-alert-stamp.txt'
  $tgLast = [datetime]'2000-01-01'
  if (Test-Path $tgStampF) { try { $tgLast = [datetime](Get-Content $tgStampF -TotalCount 1) } catch {} }
  $tgProved = [datetime]'2000-01-01'
  if (Test-Path $tgProvedF) { try { $tgProved = [datetime](Get-Content $tgProvedF -TotalCount 1) } catch {} }
  $tgUnprovenLast = [datetime]'2000-01-01'
  if (Test-Path $tgUnprovenF) { try { $tgUnprovenLast = [datetime](Get-Content $tgUnprovenF -TotalCount 1) } catch {} }
  $tgVerdict = $null
  try { $tgVerdict = Read-ChainVerdictRecord -Repo (Split-Path $root -Parent) -OutDir $OutDir } catch { $tgVerdict = $null }
  $tgPlan = Get-TestGuardsWeeklyPlan -Verdict $tgVerdict -Today $asofS -WeeklyLast $tgLast -ProvedLast $tgProved -UnprovenAlertLast $tgUnprovenLast -Now (Get-Date)
  if ($tgPlan.action -eq 'defer') { Log ('test-guards weekly DEFERRED: baseline red, retries next run (' + $tgPlan.why + ')') }
  if ($tgPlan.action -eq 'run') {
    # NO 2>&1: this script runs under EAP=Stop, and in PS 5.1 redirecting a native child's stderr wraps the
    # first line in an ErrorRecord that THROWS - jumping past $tgRc, past the stamp, past the alert, into the
    # catch. The crash case (the runner or its grandchildren dying with a stderr record) is EXACTLY the case
    # this alert exists for, and the throw also re-opened the >=7-day gate so the 658 MB copy re-ran daily.
    # The same batch commit measured and removed this exact trap inside test-guards.ps1, then reintroduced it
    # here - caught by the post-batch review. Everything the alert body needs is stdout.
    $tg = (& powershell -ExecutionPolicy Bypass -File (Join-Path $root 'run-test-guards-weekly.ps1') | ForEach-Object { [string]$_ }) -join "`n"
    $tgRc = $LASTEXITCODE
    # THE WEEKLY STAMP MEANS EVALUATED (2026-09-10, queue 2026-09-10-267ba6): rc 0 or 1 closes the week (rc 1
    # still alerts below); rc 3 or 4 proved nothing, so the week stays open and the next daily run retries.
    # rc 0 is also a PROOF, and only a proof moves test-guards-proved-stamp.txt.
    $tgStamps = Get-TestGuardsStampPlan -Rc $tgRc
    if ($tgStamps.weekly) { (Get-Date -Format 'yyyy-MM-dd') | Set-Content $tgStampF -Encoding ascii }
    if ($tgStamps.proved) { (Get-Date -Format 'yyyy-MM-dd') | Set-Content $tgProvedF -Encoding ascii }
    if ($tgRc -eq 0) { Log 'test-guards weekly: every hard invariant can still fail (hermetic run passed)' }
    else {
      Log ('test-guards weekly rc=' + $tgRc)
      $summary += 'INVARIANTS a blocking guard may no longer be able to fire - see test-guards weekly alert'
      if (-not $NoAlert) {
        $tgSubject = Get-TestGuardsSubject -Rc $tgRc -MutationFailed (Test-TestGuardsMutationFailed -Output $tg)
        Send-Alert -Subject $tgSubject -Body ("run-test-guards-weekly.ps1 breaks each hard invariant inside a scratch COPY of the grocery tree and asserts guards.ps1 exits 2 with that guard's own failure text. Exit " + $tgRc + ": 1 = a broken invariant did NOT fail guards (that guard is decorative until fixed - do not trust a quiet board on it); 3 = baseline already red, nothing proven (the daily run is already alerting on the real failure); 4 = the hermetic copy failed. Production files are never touched by this job.`n`n" + $tg) | Out-Null
      }
    }
  }
  # THE PROOF'S OWN AGE PAGES (2026-09-10, queue 2026-09-10-267ba6). A board that stays red defers every weekly
  # slot, and without this the silence would read as "nothing to report". At most one mail per 14 days.
  if ($tgPlan.alert_unproven) {
    $tgAge = if ($tgPlan.never_proved) { 'no proof has ever been recorded in test-guards-proved-stamp.txt' } else { ('the last proof was ' + $tgPlan.days_unproven + ' days ago (' + $tgProved.ToString('yyyy-MM-dd') + ')') }
    Log ('test-guards weekly UNPROVEN: ' + $tgAge)
    $summary += ('INVARIANTS no blocking guard invariant has been proven able to fail in over 14 days - ' + $tgAge)
    if (-not $NoAlert) {
      Send-Alert -Subject 'Grocery: no blocking guard invariant proven in over 14 days (test-guards weekly)' -Body ('run-test-guards-weekly.ps1 is the only proof that each blocking invariant in guards.ps1 can still FAIL, and since 2026-09-10 it defers whenever the day''s guards verdict is red, so a board that stays red keeps the proof from running at all. ' + $tgAge + '. Weekly plan today: ' + $tgPlan.action + ' (' + $tgPlan.why + '). Get guards green and the next daily run proves it: a deferred week runs on the first green verdict, and its rc 0 writes test-guards-proved-stamp.txt. A by-hand rc 0 from grocery\run-test-guards-weekly.ps1 is the same proof but writes no stamp, so put that date in test-guards-proved-stamp.txt.') | Out-Null
      (Get-Date -Format 'yyyy-MM-dd') | Set-Content $tgUnprovenF -Encoding ascii
    }
  }
} catch { Log ('test-guards weekly threw: ' + $_.Exception.Message) }

# ---- WEEKLY: does each live tool page still match the local source it was published from? ----
# The 16 tool posts are a single lexical html card whose body is a local *-tool.html. publish-tool-post.ps1
# now refuses to overwrite a live body that differs from local, which covers the dangerous path - but only
# the path that goes THROUGH the publisher. A hand-edit in Ghost admin never touches it, so that edit would
# sit unnoticed until someone republished and silently deleted it. This is the sweep for that second path.
# WEEKLY, not daily: it is 16 admin-API round trips, and a tool page changes on the scale of someone editing
# it, not a day. Stamp-gated on >=7 days like test-guards above, so a missed week self-heals on the next
# daily run. ADVISORY - drift on a tool page is never a reason to hold the grocery board.
# NO 2>&1, for the reason spelled out at the test-guards call above.
try {
  $gdStampF = Join-Path $root 'ghost-drift-weekly-stamp.txt'
  $gdLast = [datetime]'2000-01-01'
  if (Test-Path $gdStampF) { try { $gdLast = [datetime](Get-Content $gdStampF -TotalCount 1) } catch {} }
  if (((Get-Date) - $gdLast).TotalDays -ge 7) {
    $gd = (& powershell -ExecutionPolicy Bypass -File (Join-Path $root 'audit-ghost-drift.ps1') -ShowDiff | ForEach-Object { [string]$_ }) -join "`n"
    $gdRc = $LASTEXITCODE
    # THE REPAIR LANE (2026-09-23): tool drift goes to reconcile-ghost-drift.ps1 -Apply, which republishes a page that only
    # lags an older committed version, saves a Ghost edit back when our source has not moved since our last publish, and
    # alerts ONCE on a page where both changed. A page it reconciled is no longer drift, so a clean reconcile clears rc 1.
    if ($gdRc -eq 1) {
      $gdFixArgs = @('-ExecutionPolicy', 'Bypass', '-File', (Join-Path $root 'reconcile-ghost-drift.ps1'), '-Apply')
      if ($NoAlert) { $gdFixArgs += '-NoAlert' }
      $gdFix = (& powershell @gdFixArgs | ForEach-Object { [string]$_ }) -join "`n"
      $gdFixRc = $LASTEXITCODE
      Log ('ghost-drift weekly: reconcile rc=' + $gdFixRc)
      if (($gdFix -match '(?m)^GHOST-RECONCILE-COMPLETE') -and $gdFixRc -eq 0) { $gdRc = 0 }
      $gd = $gd + "`n`n" + $gdFix
    }
    # ...and the 542 recipe cards, against the publish ledger rather than a local file (a rebuilt card carries
    # today's prices, so build-vs-live is not the question; ledger-vs-live is). Same weekly cadence, same
    # advisory posture. Appended to the same body so one alert covers both surfaces.
    $gdR = (& powershell -ExecutionPolicy Bypass -File (Join-Path $root 'audit-ghost-drift.ps1') -Recipes | ForEach-Object { [string]$_ }) -join "`n"
    $gdRRc = $LASTEXITCODE
    if ($gdRRc -ne 0) { $gdRc = $gdRRc }
    $gd = $gd + "`n`n" + $gdR
    (Get-Date -Format 'yyyy-MM-dd') | Set-Content $gdStampF -Encoding ascii   # stamp even on failure: one alert per week
    # THE COMPLETION CONTRACT, PER SURFACE. Both halves must prove they finished, checked SEPARATELY: the two
    # outputs are concatenated for the alert body, and a single search over the joined text would accept one
    # marker as covering both - so a dead tools sweep would be alibied by a healthy recipes sweep. That is the
    # exact "found nothing and never ran look identical" hole this contract exists to close, reintroduced by
    # the convenience of one string.
    $gdToolsDone   = ($gd  -match '(?m)^GHOST-DRIFT-COMPLETE')
    $gdRecipesDone = ($gdR -match '(?m)^GHOST-DRIFT-COMPLETE')
    if (-not ($gdToolsDone -and $gdRecipesDone)) {
      $which = if (-not $gdToolsDone -and -not $gdRecipesDone) { 'neither sweep' } elseif (-not $gdToolsDone) { 'the TOOLS sweep' } else { 'the RECIPE-CARD sweep' }
      Log ('ghost-drift weekly DID NOT RUN TO THE END (rc=' + $gdRc + ') - no completion marker from ' + $which + ', so its verdict proves nothing')
      $summary += ('REVIEW    ghost-drift weekly did not finish (' + $which + ') - those live pages went unchecked this week')
    } elseif ($gdRc -eq 0) { Log 'ghost-drift weekly: every live tool page and recipe card still matches what we published' }
    else {
      Log ('ghost-drift weekly rc=' + $gdRc)
      $summary += 'REVIEW    a live tool page no longer matches its local source - republishing it would delete the difference'
      if (-not $NoAlert) {
        $gdSubject = if ($gdRc -eq 3) { 'Tools: ghost-drift could not evaluate (no key, or a page could not be read)' } else { 'Tools: a live page has drifted from its local source' }
        Send-Alert -Subject $gdSubject -Body ("audit-ghost-drift.ps1 compares each live Ghost html card against the local *-tool.html it was published from. Exit " + $gdRc + ": 1 = at least one page differs, so republishing it from local would DELETE the live-only content (fold the change into the local source, or record it with -Accept <slug> and a reason); 3 = could not evaluate, nothing was proven. publish-tool-post.ps1 already refuses to overwrite an unreviewed difference, so this is the sweep for edits made directly in Ghost admin.`n`n" + $gd) | Out-Null
      }
    }
  }
} catch { Log ('ghost-drift weekly threw: ' + $_.Exception.Message) }

# ---- DAILY: is the mirror ON MAIN still a current backup of the agent prompts and scheduled-task SKILLs? ----
# ops\audit-prompt-backup.ps1 existed since 2026-07-31 and NOTHING called it. The prompts the triage agents
# run on are code, they live outside this repo in ~\.claude\, and the only thing proving they are backed up
# was a script nobody invoked.
# DAILY, AND THE FLOOR, SINCE 2026-09-23 (design\PLAN-push-derived-conflicts-2026-09-23.md W8.4, Brad's ruling
# D15). The audit's push-time run now judges only what a push changed, because a live prompt edited in one
# session reddened every other checkout's push and none of them could fix it. This is the run that still sees
# the whole mirror: -Daily compares the shared live copies with the mirror AS COMMITTED on origin/main (the main
# checkout's own copy is refreshed on disk every morning by capture-run's prompt-sync, so reading it would miss
# exactly the mirror nobody committed), and exits 2 only on a finding more than 24 hours old, which is what pages
# here. Every run of this chain runs it, like memory-backup below; the weekly stamp it used,
# grocery\prompt-backup-weekly-stamp.txt, is read and written by nothing now and is left where the bot commits it.
# The marker is logged whole on every run, so a day with no PROMPT-BACKUP-COMPLETE line in ad-cycle-log.txt is
# a day the floor did not run (the plan's bar B15 counts it).
try {
  $pb = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path (Split-Path $root -Parent) 'ops\audit-prompt-backup.ps1') -Daily | ForEach-Object { [string]$_ }) -join "`n"
  $pbRc = $LASTEXITCODE
  $pbMark = [regex]::Match($pb, '(?m)^PROMPT-BACKUP-COMPLETE[^\r\n]*').Value
  if (-not $pbMark) {
    Log ('prompt-backup daily DID NOT RUN TO THE END (rc=' + $pbRc + ') - no completion marker')
    $summary += 'REVIEW    prompt-backup daily did not finish - agent prompt backups went unverified'
  } elseif ($pbRc -eq 0) { Log ('prompt-backup daily: nothing on the mirror on main has disagreed with its live copy for over 24 hours - ' + $pbMark) }
  else {
    Log ('prompt-backup daily rc=' + $pbRc + ' - ' + $pbMark)
    $summary += 'REVIEW    an agent prompt or scheduled-task SKILL has not matched its backup on main for over 24 hours'
    if (-not $NoAlert) { Send-Alert -Subject 'Ops: an agent prompt is not backed up' -Body ("ops\audit-prompt-backup.ps1 -Daily proves the agent prompts and scheduled-task SKILLs - which are CODE and live outside this repo - are backed up by ops\prompt-backup AS COMMITTED ON origin/main, and identical across scopes in the main checkout. It pages only on a finding more than 24 hours old: a push no longer fails on drift it did not cause, so this is the one run that sees the whole mirror. Exit " + $pbRc + ": 2 = drift or missing, 3 = BLIND (found nothing to check, which is a pass that proves nothing).`n`n" + $pb) | Out-Null }
  }
} catch { Log ('prompt-backup daily threw: ' + $_.Exception.Message) }

# ---- DAILY: is the agent memory store versioned, intact, and OUT of this public repo? ----
# ops\audit-memory-backup.ps1, added 2026-09-03. The memory files are data this estate reasons from and
# they live outside any repository. On 2026-09-03 an ordinary three-character repair performed a GLOBAL
# character substitution in two of them - 2,035 characters damaged, both writes reporting success, neither
# changing the file size - and with nothing versioning the directory, recovery meant rebuilding the content
# out of session transcripts. Memory now has its own local git history.
#
# DAILY, because memory changes on almost every session (prompt-backup above was weekly until 2026-09-23, and
# is daily now for a different reason: it became the floor). -Sync so the history can never fall behind on its own.
#
# IT IS NOT MIRRORED INTO ops\ AND MUST NOT BE. This repo is PUBLIC (private=False, checked 2026-09-03),
# and memory carries cost, revenue and account notes. Half of what this guard watches for is memory
# ARRIVING here: a git remote on the store, or a memory file tracked by ThriftyCrew. Both are alerts.
try {
  $mem = (& powershell -ExecutionPolicy Bypass -File (Join-Path (Split-Path $root -Parent) 'ops\audit-memory-backup.ps1') -Sync | ForEach-Object { [string]$_ }) -join "`n"
  $memRc = $LASTEXITCODE
  if ($mem -notmatch '(?m)^MEMORY-BACKUP-COMPLETE') {
    Log ('memory-backup DID NOT RUN TO THE END (rc=' + $memRc + ') - no completion marker, so the memory store went unverified')
    $summary += 'REVIEW    memory-backup did not finish - the agent memory store went unverified today'
  } elseif ($memRc -eq 0) { Log 'memory-backup: memory is versioned locally, has no remote, is absent from this repo, and its index and encoding are intact' }
  elseif ($memRc -eq 3) {
    Log 'memory-backup: BLIND - nothing to check, which is a pass that proves nothing'
    $summary += 'REVIEW    memory-backup found nothing to check - the store is missing or empty'
    if (-not $NoAlert) { Send-Alert -Subject 'Ops: the agent memory store could not be checked' -Body ("ops\audit-memory-backup.ps1 exited 3 (BLIND): the memory directory is missing, has no MEMORY.md, or holds zero memory files. A clean result would prove nothing.`n`n" + $mem) | Out-Null }
  }
  else {
    Log ('memory-backup rc=' + $memRc)
    $summary += 'REVIEW    the agent memory store has a finding (history, index, encoding, or it has reached this PUBLIC repo)'
    # BRAD RULING R16 (2026-09-10): memory that can leave this machine, or already has, EMAILS; the hygiene
    # findings stay on the review list. audit-memory-backup tags those findings 'EXPOSURE: ' where it creates
    # them, so this routes on the tag and never on the wording (its fix footer says PUBLIC on every failure).
    $memExposed = ($mem -cmatch '(?m)^\s*EXPOSURE: ')
    if ($memExposed -and -not $NoAlert) { Send-Alert -Subject 'Ops: private memory notes reached the public repo' -Body ("ops\audit-memory-backup.ps1 found memory that can leave this machine or already has: a git remote nobody reviewed, a reviewed remote that answers anonymously, or a memory file tracked by the PUBLIC ThriftyCrew repo. Memory carries cost, revenue and account notes. -Sync does not fix this; remove it by hand.`n`n" + $mem) | Out-Null }
    if (-not $memExposed -and -not $NoAlert) { Send-Alert -Subject 'Ops: the agent memory store has a finding' -Body ("ops\audit-memory-backup.ps1 checks that memory is versioned locally, has NO git remote, is NOT tracked by this PUBLIC repo, is fully committed, that MEMORY.md agrees with the files on disk, and that nothing is mojibaked.`n`nA REMOTE or a tracked memory file is the serious one: this repo is public and memory carries cost, revenue and account notes. Neither is fixed by -Sync; remove it by hand.`n`n" + $mem) | Out-Null }
  }
} catch { Log ('memory-backup threw: ' + $_.Exception.Message) }

# ---- WEEKLY: does the live Cloudflare estate still match what this repo declares? ----
# ops\audit-cloudflare-estate.ps1 landed 2026-08-20 and NOTHING in production called it - the same shape
# audit-prompt-backup.ps1 sat in above, and the same shape that let nine unseen R2 lifecycle rules bill
# ~$9/mo for months. ops\run-gates.ps1 DISCOVERS it, but only ever runs its -SelfTest: that proves the
# comparison logic works and checks nothing live. Weekly, because lifecycle rules change when a human
# changes them, not on a schedule.
#
# THIS NEVER BLOCKS THE PUBLISH. It is Cloudflare ops, not a board invariant - a drifted lifecycle rule is
# expensive, not wrong, and holding the board hostage to it would be the wrong trade.
try {
  $cfStampF = Join-Path $root 'cloudflare-estate-weekly-stamp.txt'
  $cfLast = [datetime]'2000-01-01'
  if (Test-Path $cfStampF) { try { $cfLast = [datetime](Get-Content $cfStampF -TotalCount 1) } catch {} }
  if (((Get-Date) - $cfLast).TotalDays -ge 7) {
    $cf = (& powershell -ExecutionPolicy Bypass -File (Join-Path (Split-Path $root -Parent) 'ops\audit-cloudflare-estate.ps1') | ForEach-Object { [string]$_ }) -join "`n"
    $cfRc = $LASTEXITCODE
    (Get-Date -Format 'yyyy-MM-dd') | Set-Content $cfStampF -Encoding ascii
    if ($cfRc -eq 3) {
      # BLIND IS NOT A PASS, and as of 2026-08-20 it is the EXPECTED state: no CLOUDFLARE_API_TOKEN exists
      # on this machine, so the drift this gate was written to catch is currently invisible. Saying so every
      # week is the point - a gate that cannot see must never read as a gate that saw nothing wrong.
      Log 'cloudflare-estate weekly: BLIND - no CLOUDFLARE_API_TOKEN, so R2 lifecycle drift would not be seen'
      $summary += 'REVIEW    cloudflare estate check is BLIND (no CLOUDFLARE_API_TOKEN) - lifecycle drift unwatched'
    } elseif ($cf -notmatch '(?m)^CLOUDFLARE-ESTATE-COMPLETE') {
      Log ('cloudflare-estate weekly DID NOT RUN TO THE END (rc=' + $cfRc + ') - no completion marker')
      $summary += 'REVIEW    cloudflare estate check did not finish - the estate went unverified'
    } elseif ($cfRc -eq 0) {
      Log 'cloudflare-estate weekly: live Cloudflare estate matches ops\cloudflare-estate.json'
    } else {
      Log ('cloudflare-estate weekly rc=' + $cfRc)
      $summary += 'REVIEW    the live Cloudflare estate drifted from ops\cloudflare-estate.json'
      if (-not $NoAlert) { Send-Alert -Subject 'Ops: the Cloudflare estate drifted from its declaration' -Body ("ops\audit-cloudflare-estate.ps1 compares the live R2 buckets, their lifecycle rules and the D1 size against ops\cloudflare-estate.json. Exit " + $cfRc + ": 2 = drift, 3 = BLIND (no token, which proves nothing).`n`nIA transitions are the expensive class: R2 bills operations per whole million with no proration and no IA free tier, which is how 499 transitions bought a full 9.00 dollar block on 2026-08-19.`n`n" + $cf) | Out-Null }
    }
  }
} catch { Log ('cloudflare-estate weekly threw: ' + $_.Exception.Message) }

# ---- DAILY: is every live Ghost page produced by a tracked source or declared? (2026-09-19, backlog I167) ----
# ops\audit-ghost-page-census.ps1 reads every published post and page with read-only GETs and fails on a live
# page no tracked file names and ops\ghost-page-estate.json does not declare, on a declared page that left, whose
# visibility moved, or that was edited in Ghost after its copy under content\ghost-adopted\ was exported. The
# 197 pages that census found unowned on 2026-09-18 were adopted on Brad's ruling; this keeps the set closed.
# run-gates runs only its -SelfTest, because a push must not wait on the live site. ADVISORY: it never holds
# the board. About 25 s (a dozen list GETs and a scan of the tracked tree), so it runs every day, not weekly.
try {
  $gpc = (& powershell -ExecutionPolicy Bypass -File (Join-Path (Split-Path $root -Parent) 'ops\audit-ghost-page-census.ps1') | ForEach-Object { [string]$_ }) -join "`n"
  $gpcRc = $LASTEXITCODE
  if ($gpcRc -eq 3) {
    Log ('ghost-page-census: BLIND (rc=3) - the live Ghost pages went uncensused today')
    $summary += 'REVIEW    ghost page census could not evaluate - an unowned live page would not be seen today'
    if (-not $NoAlert) { Send-Alert -Subject 'Ops: the Ghost page census could not evaluate' -Body ("ops\audit-ghost-page-census.ps1 exited 3: no key, Ghost unreadable, the registry did not parse, or the tracked-file scan read nothing. Nothing was proven.`n`n" + $gpc) | Out-Null }
  } elseif ($gpc -notmatch '(?m)^GHOST-PAGE-CENSUS-COMPLETE') {
    Log ('ghost-page-census DID NOT RUN TO THE END (rc=' + $gpcRc + ') - no completion marker')
    $summary += 'REVIEW    ghost page census did not finish - the live Ghost pages went uncensused today'
  } elseif ($gpcRc -eq 0) {
    Log 'ghost-page-census: every live Ghost page is named by a tracked file or declared in ops\ghost-page-estate.json'
  } else {
    Log ('ghost-page-census rc=' + $gpcRc)
    $summary += 'REVIEW    a live Ghost page is unowned, or a declared page moved (see the ghost page census)'
    if (-not $NoAlert) { Send-Alert -Subject 'Ops: a live Ghost page is neither produced by the repo nor declared' -Body ("ops\audit-ghost-page-census.ps1 compares every published Ghost post and page with the tracked tree and ops\ghost-page-estate.json. Exit " + $gpcRc + ". UNDECLARED: find what made the page and commit its source, or declare it with why and run -Export. EDITED-SINCE-EXPORT: read what changed, then run -Export. VISIBILITY-MOVED and DECLARED-NOT-LIVE: someone changed the live site; decide, then record the new state.`n`n" + $gpc) | Out-Null }
  }
} catch { Log ('ghost-page-census threw: ' + $_.Exception.Message) }

# ---- WEEKLY: do the store SEARCH templates still resolve? ----
# The all-3 rule guarantees every priced chip carries a link; nothing guaranteed the link WORKED. Family
# Fare's search template 404'd on 20 live chips in public/board.json (2026-08-02) and no guard could see it,
# because every link check in this estate looks at PRODUCT urls. This fetches each store's search template.
# WEEKLY, not daily: it is seven outbound requests to stores we otherwise only read data from, and a
# template rots on the scale of a site redesign, not a day. Stamp-gated on >=7 days like test-guards, so a
# missed week self-heals on the next daily run rather than waiting for a weekday to come round again.
# ADVISORY: it alerts and adds a REVIEW line, it never holds the board. A dead fallback link is a real
# defect, but every PRICE on that board is still correct, and holding a correct board over a link is the
# wrong trade. Exit 3 (every store bot-walled) gets its own line - a blocked probe proved nothing, and
# silence from it must never be read as seven healthy templates.
try {
  $slStampF = Join-Path $root 'search-links-weekly-stamp.txt'
  $slLast = [datetime]'2000-01-01'
  if (Test-Path $slStampF) { try { $slLast = [datetime](Get-Content $slStampF -TotalCount 1) } catch {} }
  if (((Get-Date) - $slLast).TotalDays -ge 7) {
    # No 2>&1 on the child: under EAP=Stop a native child's first stderr line becomes a terminating throw
    # that would jump past the exit-code read and the stamp (the same trap measured in test-guards above).
    $slArgs = @('-ExecutionPolicy','Bypass','-File',(Join-Path $root 'audit-search-links.ps1'),'-OutDir',$OutDir)
    if (-not $NoAlert) { $slArgs += '-Alert' }
    & powershell @slArgs | ForEach-Object { Log ('search-links: ' + $_) }
    $slRc = $LASTEXITCODE
    (Get-Date -Format 'yyyy-MM-dd') | Set-Content $slStampF -Encoding ascii   # stamp even on failure: one alert per week
    if ($slRc -eq 2) { $summary += 'REVIEW    a store SEARCH link is DEAD - every chip falling back to it sends a shopper to a 404; see out\search-links-report.json' }
    elseif ($slRc -eq 3) { Log 'search-links BLIND: every store was bot-walled or unreachable - NO template was checked, so this week proved nothing about the fallback links'; $summary += 'REVIEW    audit-search-links could not evaluate (every store blocked) - the fallback search links are UNCHECKED this week' }
  }
} catch { Log ('search-links weekly threw: ' + $_.Exception.Message) }


# ---- COVERAGE RATCHET FOR THE CYCLE PHASE ----
# THE HOOK THAT WAS NEVER BUILT. coverage-baseline.json's own audit-ff-carry entry has carried the note
# "nothing yet runs the ratchet with -Phase cycle, so those two verdicts fire only on a manual run until
# check-ad-cycles.ps1 gets its own hook" since the ledger shipped. guards.ps1 runs the ratchet with
# -Phase publish, so every cycle-phase row was being WRITTEN faithfully and never COMPARED to anything -
# a gate that cannot arm, which is the exact class the ledger itself exists to catch. This is that hook.
# It sits at the very end, after every cycle-phase producer has recorded (the Hy-Vee pull near the top,
# ff-carry, everyday-mismatch), and it is ADVISORY: a coverage regression means a check got quieter, which
# is worth an eye, not a reason to hold a board whose own guards passed.
# No 2>&1 (EAP=Stop turns a native child's first stderr line into a terminating throw), capture then read
# $LASTEXITCODE, and treat exit 3 as could-not-evaluate rather than as a pass.
try {
  $clPath = Join-Path $root 'audit-coverage-ledger.ps1'
  if (Test-Path $clPath) {
    $clOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $clPath -Phase cycle
    $clRc  = $LASTEXITCODE
    foreach ($l in @($clOut)) { Log ('coverage-cycle: ' + $l) }
    if ($clRc -eq 1) {
      $summary += 'REVIEW    a cycle-phase check examined materially fewer rows than its baseline - see coverage-cycle lines in the log'
    } elseif ($clRc -eq 3) {
      $summary += 'REVIEW    cycle-phase coverage could not be evaluated - no rostered cycle check recorded a row this run'
    }
  }
} catch { Log ('coverage-cycle ratchet threw: ' + $_.Exception.Message) }
