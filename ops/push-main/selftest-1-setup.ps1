  $f = 0; $cases = 0
  $kMF = 'MUST' + ' FIRE'; $kMNF = 'MUST' + ' NOT FIRE'; $kCT = 'CLEAN' + ' TWIN'
  # EVERY LINE THIS FILE ECHOES IS MARKED AS AN ECHO (see Say): the fixtures below make children print FAIL lines on
  # purpose, and one of those at the start of a stdout line would score this whole suite failed at exit 0.
  $script:TcSayPrefix = '  | '
  function T($m, $cond, $got) {
    $script:cases++
    if ($cond) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $got); $script:f++ }
  }
  # THE PLAN IS DRIVEN ON FIXED INPUTS, so every branch has a case without needing a remote to be in that state.
  $A = '1111111111111111111111111111111111111111'
  $B = '2222222222222222222222222222222222222222'
  $C = '3333333333333333333333333333333333333333'
  T ($kMF + '  a dirty working tree is refused, and the reason names the index rather than just saying dirty') `
    ((-not (Get-TcPushPlan -Head $A -RemoteSha $B -MergeBase $B -Ahead 1 -Dirty $true).Ready) -and ((Get-TcPushPlan -Head $A -RemoteSha $B -MergeBase $B -Ahead 1 -Dirty $true).Reason -match 'index')) 'a dirty tree was allowed'
  T ($kMF + '  a HEAD equal to the remote is refused as nothing to push') `
    (-not (Get-TcPushPlan -Head $A -RemoteSha $A -MergeBase $A -Ahead 0 -Dirty $false).Ready) 'an empty push was allowed'
  T ($kMF + '  a branch with no commits the remote lacks is refused') `
    (-not (Get-TcPushPlan -Head $A -RemoteSha $B -MergeBase $B -Ahead 0 -Dirty $false).Ready) 'a push with nothing ahead was allowed'
  T ($kMF + '  a remote that could not be read is refused, never treated as an empty remote') `
    (-not (Get-TcPushPlan -Head $A -RemoteSha '' -MergeBase '' -Ahead 1 -Dirty $false).Ready) 'an unreadable remote was treated as readable'
  T ($kMNF + '  a branch sitting on exactly what the remote holds is ready and is NOT rebased') `
    ((Get-TcPushPlan -Head $A -RemoteSha $B -MergeBase $B -Ahead 2 -Dirty $false).Ready -and -not (Get-TcPushPlan -Head $A -RemoteSha $B -MergeBase $B -Ahead 2 -Dirty $false).NeedsRebase) 'a needless rebase was planned'
  T ($kMF + '  a branch whose base the remote has moved past is rebased') `
    ((Get-TcPushPlan -Head $A -RemoteSha $B -MergeBase $C -Ahead 2 -Dirty $false).NeedsRebase) 'a stale base was not rebased'
  # THE EMPTY MERGE-BASE. `git merge-base` prints nothing and exits 1 for unrelated histories, and reading that as
  # "not equal to the remote sha" made it a REBASE - replaying an unrelated history onto main and pushing it.
  $unrel = Get-TcPushPlan -Head $A -RemoteSha $B -MergeBase '' -Ahead 2 -Dirty $false
  T ($kMF + '  a branch sharing no ancestor with the remote is refused, and is never rebased onto it') `
    ((-not $unrel.Ready) -and (-not $unrel.NeedsRebase) -and $unrel.Reason -match 'no common ancestor') ("ready={0} needsRebase={1} reason={2}" -f $unrel.Ready, $unrel.NeedsRebase, $unrel.Reason)

  # ---- WHAT THE ROW RECORDS: the pure readers (2026-09-23, PLAN-push-derived-conflicts W0.1) ----
  # Each rule of the refusal classifier the end-to-end hook cases further down do not reach gets its own text here. A
  # repo path in these fixtures is split across a + so the gate-input walk does not read it as a file this suite loads.
  $gateX = 'ops\audit-' + 'fixture-x.ps1'
  $rjTa = Get-TcPushRejectClass -Text "pre-push: running the gate`npre-push: BLOCKED - the test-auditors check exited 1. This push leaves a watcher that cannot see its own bug.`n          full output kept at: /tmp/x.log"
  T ($kMF + '  a test-auditors refusal in the hook''s own wording is classed test-auditors, and its BLOCKED line is kept') `
    ($rjTa.Class -ceq 'test-auditors' -and @($rjTa.Lines).Count -eq 1 -and ([string]@($rjTa.Lines)[0]).StartsWith('pre-push: BLOCKED - the test-auditors')) ("class={0} lines={1}" -f $rjTa.Class, (@($rjTa.Lines) -join ' | '))
  $rjSt = Get-TcPushRejectClass -Text 'pre-push: REFUSING - git could not name a working tree for this push'
  T ($kMF + '  a structural REFUSING line is classed structure') ($rjSt.Class -ceq 'structure') ("class={0}" -f $rjSt.Class)
  $rjRm = Get-TcPushRejectClass -Text "To C:/fixture/origin`n ! [remote rejected] HEAD -> main (cannot lock ref 'refs/heads/main': is at 1111 but expected 2222)`nerror: failed to push some refs"
  T ($kMF + '  a remote that refused the ref update is classed remote') ($rjRm.Class -ceq 'remote' -and @($rjRm.Lines).Count -eq 1) ("class={0} lines={1}" -f $rjRm.Class, @($rjRm.Lines).Count)
  $rjPg = Get-TcPushRejectClass -Text ('PRE-PUSH-REFUSED cause=run-gates gate=' + $gateX)
  T ($kMF + '  the fixed PRE-PUSH-REFUSED line with a gate= names the class as cause:gate') ($rjPg.Class -ceq ('run-gates:' + $gateX)) ("class={0}" -f $rjPg.Class)
  $rjB3 = Get-TcPushRejectClass -Text "pre-push: BLOCKED - run-gates COULD NOT EVALUATE (exit 3). A 3 is NEVER a pass.`n          CAUSE: no gate worker slot.`nrun-gates: COULD NOT EVALUATE - waited 1200s for a gate worker slot"
  T ($kCT + '  a run-gates refusal with no FAIL line is classed run-gates alone, keeping the BLOCKED line and the gate''s own COULD NOT line') `
    ($rjB3.Class -ceq 'run-gates' -and @($rjB3.Lines).Count -eq 2 -and ([string]@($rjB3.Lines)[1]).StartsWith('run-gates: COULD NOT EVALUATE')) ("class={0} lines={1}" -f $rjB3.Class, (@($rjB3.Lines) -join ' | '))
  $longFail = '  FAIL  ' + $gateX + '  (exit 1) - ' + ('w' * 400)
  $rjCap = Get-TcPushRejectClass -Text ("pre-push: BLOCKED - run-gates exited 1.`n" + (@($longFail, $longFail, $longFail, $longFail, $longFail) -join "`n"))
  $capLens = @(@($rjCap.Lines) | ForEach-Object { ([string]$_).Length })
  T ($kCT + '  a refusal with many long lines keeps exactly 3, each cut to 300 characters, the BLOCKED line first') `
    ($rjCap.Class -ceq ('run-gates:' + $gateX) -and @($rjCap.Lines).Count -eq 3 -and ($capLens | Measure-Object -Maximum).Maximum -eq 300 -and ([string]@($rjCap.Lines)[0]).StartsWith('pre-push: BLOCKED - run-gates')) `
    ("class={0} count={1} lengths={2}" -f $rjCap.Class, @($rjCap.Lines).Count, ($capLens -join ','))

  $rgLine = 'run-gates: 3 of 7 self-test(s) already passed over these exact inputs and were not run again; 2 could not be keyed and always run'
  $rgr = Get-TcRunGatesReading -Lines @('run-gates: dispatching', $rgLine, 'RUN-GATES-COMPLETE pass=7 fail=0')
  T ($kMF + '  run-gates'' reuse line is read into its three numbers, and a run that dispatched is not a whole-run replay') `
    ($rgr.Reused -eq 3 -and $rgr.SelfTests -eq 7 -and $rgr.Unkeyable -eq 2 -and -not $rgr.WholeRun) ("reused={0} selftests={1} unkeyable={2} whole={3}" -f $rgr.Reused, $rgr.SelfTests, $rgr.Unkeyable, $rgr.WholeRun)
  $rgw = Get-TcRunGatesReading -Lines @('run-gates: PASSED - all 380 gate(s) passed at 2026-09-23T10:00:00Z over content byte-identical to this checkout now, so not one was run again (fixture). Pass -NoReuse to run them regardless.', 'RUN-GATES-COMPLETE pass=380 fail=0 reused=1')
  $rgn = Get-TcRunGatesReading -Lines @('nothing run-gates said')
  T ($kMF + '  a replayed whole verdict is read as WholeRun, so the leg records 0 seconds, and its numbers stay null') ($rgw.WholeRun -and $null -eq $rgw.Reused) ("whole={0} reused={1}" -f $rgw.WholeRun, $rgw.Reused)
  T ($kMNF + '  output with no reuse line leaves all three numbers null, never zero') ($null -eq $rgn.Reused -and $null -eq $rgn.SelfTests -and $null -eq $rgn.Unkeyable -and -not $rgn.WholeRun) ("reused={0} whole={1}" -f $rgn.Reused, $rgn.WholeRun)

  $rgfR = Get-TcRunGatesFailed -Lines @('  FAIL  ops\audit-x.ps1  (exit 2) - why', '  failed: ops\audit-x.ps1', '  failed: push-cost-budget', 'RUN-GATES-COMPLETE pass=5 fail=2')
  $rgf = @($rgfR)
  T ($kMF + '  a red run''s "failed:" lines are read into the gate names, in order (the refused-gate-red row names them)') ($rgf.Count -eq 2 -and $rgf[0] -ceq 'ops\audit-x.ps1' -and $rgf[1] -ceq 'push-cost-budget') ($rgf -join ' | ')
  $rgf0R = Get-TcRunGatesFailed -Lines @('  ok    ops\audit-x.ps1', 'RUN-GATES-COMPLETE pass=7 fail=0')
  $rgf0 = @($rgf0R)
  T ($kMNF + '  a run with no "failed:" line names no gate') ($rgf0.Count -eq 0) ("count=" + $rgf0.Count)

  $htRan = Get-TcHookTestAuditors -Text "prepush-test-auditors: FULL RUN - fixture`nprepush-test-auditors: running the suite in full (measured 500s)"
  $htReu = Get-TcHookTestAuditors -Text 'prepush-test-auditors: REUSED key=0123456789abcdef - fixture'
  $htNn = Get-TcHookTestAuditors -Text 'prepush-test-auditors: NOT NEEDED - 2 pushed path(s) across 1 ref(s), none is a test-auditors input'
  $htUn = Get-TcHookTestAuditors -Text 'pre-push: BLOCKED - run-gates exited 1.'
  T ($kMF + '  the in-lock hook''s test-auditors lines read as ran, reused and not-needed, and a hook that never reached them as unknown') `
    ($htRan -ceq 'ran' -and $htReu -ceq 'reused' -and $htNn -ceq 'not-needed' -and $htUn -ceq 'unknown') ("ran={0} reused={1} notNeeded={2} unknown={3}" -f $htRan, $htReu, $htNn, $htUn)

  # ---- THE REVIEW OF W0.1R (2026-09-23): the readers it found blind ----
  # reject_rc: the fixed PRE-PUSH-REFUSED line carries no exit code, so a contention 3 and a red wrote the same class and
  # lines. The code is read off the hook's own BLOCKED line. Founding texts: the hook's exit-3 and exit-1 wordings.
  $rc3 = Get-TcPushRejectClass -Text "pre-push: BLOCKED - run-gates COULD NOT EVALUATE (exit 3). A 3 is NEVER a pass.`n          CAUSE: no gate worker slot.`nPRE-PUSH-REFUSED cause=run-gates"
  $rc3ta = Get-TcPushRejectClass -Text "pre-push: BLOCKED - the test-auditors check COULD NOT EVALUATE (exit 3). That is not a pass.`nPRE-PUSH-REFUSED cause=test-auditors"
  T ($kMF + '  a could-not-evaluate refusal under the fixed line records reject_rc 3, for run-gates and for test-auditors, beside its unchanged class') `
    ($rc3.Class -ceq 'run-gates' -and $rc3.Rc -eq 3 -and $rc3ta.Class -ceq 'test-auditors' -and $rc3ta.Rc -eq 3) ("rg={0}/{1} ta={2}/{3}" -f $rc3.Class, $rc3.Rc, $rc3ta.Class, $rc3ta.Rc)
  $rc1 = Get-TcPushRejectClass -Text "pre-push: BLOCKED - run-gates exited 1. This tree must not be pushed until it passes.`n  FAIL  fixture-gate  (exit 2) - x`nPRE-PUSH-REFUSED cause=run-gates gate=fixture-gate"
  $rc1ta = Get-TcPushRejectClass -Text "pre-push: BLOCKED - the test-auditors check exited 1. This push leaves a watcher that cannot see its own bug.`nPRE-PUSH-REFUSED cause=test-auditors"
  $rc1rh = Get-TcPushRejectClass -Text 'pre-push: BLOCKED - this push changes the daily chain and carries no passing rehearsal over recent data (exit 1).'
  $rcSt = Get-TcPushRejectClass -Text "pre-push: REFUSING - git could not name a working tree for this push`nPRE-PUSH-REFUSED cause=structure"
  $rcRm = Get-TcPushRejectClass -Text ' ! [remote rejected] HEAD -> main (cannot lock ref)'
  T ($kMNF + '  a red is still a red: exit 1 of run-gates, test-auditors and the rehearsal records reject_rc 1 (never the FAIL line''s own exit 2), and a structure or remote refusal records none') `
    ($rc1.Rc -eq 1 -and $rc1ta.Rc -eq 1 -and $rc1rh.Rc -eq 1 -and $null -eq $rcSt.Rc -and $null -eq $rcRm.Rc -and $rc1.Class -ceq 'run-gates:fixture-gate') `
    ("rg={0} ta={1} rh={2} structure={3} remote={4} class={5}" -f $rc1.Rc, $rc1ta.Rc, $rc1rh.Rc, $rcSt.Rc, $rcRm.Rc, $rc1.Class)

  # inlock_check: Code 3 (no completion marker) and a check that returned no Code decided nothing; only 0 is covered.
  $ckW0 = Get-TcInlockCheckWord -Check ([pscustomobject]@{ Code = 0 })
  $ckW1 = Get-TcInlockCheckWord -Check ([pscustomobject]@{ Code = 1 })
  $ckW3 = Get-TcInlockCheckWord -Check ([pscustomobject]@{ Code = 3 })
  $ckWn = Get-TcInlockCheckWord -Check ([pscustomobject]@{ Why = 'no code at all' })
  T ($kMF + '  the in-lock check word is covered for Code 0, not-covered for 1, and could-not-decide for 3 and for a check that returned no Code') `
    ($ckW0 -ceq 'covered' -and $ckW1 -ceq 'not-covered' -and $ckW3 -ceq 'could-not-decide' -and $ckWn -ceq 'could-not-decide') ("0={0} 1={1} 3={2} none={3}" -f $ckW0, $ckW1, $ckW3, $ckWn)

  # hook_ta_scope: B11 counts FULL test-auditors runs inside the lock, and hook_ta 'ran' says only that one ran.
  $hsFull = Get-TcHookTestAuditorsScope -Text 'prepush-test-auditors: running grocery\test-auditors.ps1 in full (measured 500s on 2026-09-10, bound 900s)'
  $hsSel = Get-TcHookTestAuditorsScope -Text 'prepush-test-auditors: running grocery\test-auditors.ps1 on 3 of 84 unit(s) (a full run measured 500s on 2026-09-10, bound 900s)'
  $hsNone = Get-TcHookTestAuditorsScope -Text 'prepush-test-auditors: REUSED key=0123456789abcdef - fixture'
  T ($kMF + '  hook_ta_scope tells a full in-lock test-auditors run from a selective one, with its unit counts, and is null when none ran') `
    ($hsFull -ceq 'full' -and $hsSel -ceq 'selective 3 of 84' -and $null -eq $hsNone) ("full={0} selective={1} none={2}" -f $hsFull, $hsSel, $hsNone)

  # subject_shas: the founding case is the housekeeping lane, three attempts of one change with three subjects_sha values
  # (an amended subject, then a dropped sibling commit). One hash over the set moves; per-subject hashes still OVERLAP.
  $sjA = [string[]]@('fix the widget', 'mustfire-census baseline retrained on a rise: 3,023 to 4,735')
  $sjAmend = [string[]]@('fix the widget', 'mustfire-census baseline retrained on a rise: 3,023 to 4,770')
  $sjAdded = [string[]]@('fix the widget', 'mustfire-census baseline retrained on a rise: 3,023 to 4,735', 'fix the red the gate found')
  $shA = Get-TcSubjectShaList -Subjects $sjA
  $shAm = Get-TcSubjectShaList -Subjects $sjAmend
  $shAd = Get-TcSubjectShaList -Subjects $sjAdded
  $ovAm = @($shA | Where-Object { $shAm -ccontains $_ }).Count
  $ovAd = @($shA | Where-Object { $shAd -ccontains $_ }).Count
  T ($kMF + '  an amended subject and an added fix commit each move subjects_sha, and subject_shas still overlaps the first attempt''s (1 and 2 shared of 2)') `
    ((Get-TcSubjectsShaOf -Subjects $sjA) -cne (Get-TcSubjectsShaOf -Subjects $sjAmend) -and (Get-TcSubjectsShaOf -Subjects $sjA) -cne (Get-TcSubjectsShaOf -Subjects $sjAdded) -and `
      $shA.Count -eq 2 -and $shAd.Count -eq 3 -and $ovAm -eq 1 -and $ovAd -eq 2 -and ([string]$shA[0]) -match '^[0-9a-f]{16}$' -and [string]::CompareOrdinal([string]$shA[0], [string]$shA[1]) -lt 0) `
    ("countA={0} countAdded={1} overlapAmend={2} overlapAdded={3} first={4}" -f $shA.Count, $shAd.Count, $ovAm, $ovAd, $(if ($shA) { $shA[0] }))
  # THE CAP (50), AT it and one PAST it, and a repeated subject counted once.
  $sj50 = [string[]]@(1..50 | ForEach-Object { 'subject ' + $_ })
  $sj51 = [string[]]@(1..51 | ForEach-Object { 'subject ' + $_ })
  $sh50 = Get-TcSubjectShaList -Subjects $sj50
  $sh51 = Get-TcSubjectShaList -Subjects $sj51
  $shDup = Get-TcSubjectShaList -Subjects ([string[]]@('same', 'same', 'other'))
  $shNone = Get-TcSubjectShaList -Subjects ([string[]]@())
  T ($kCT + '  subject_shas keeps all 50 hashes AT the cap of 50 and exactly 50 of 51 one past it, counts a repeated subject once, and is null for no subjects') `
    ($sh50.Count -eq 50 -and $sh51.Count -eq 50 -and $shDup.Count -eq 2 -and $null -eq $shNone) ("at={0} past={1} dup={2} none={3}" -f $sh50.Count, $sh51.Count, $shDup.Count, $(if ($null -eq $shNone) { 'null' } else { $shNone.Count }))

  $tmLine = 'TA-KEY-MOVED kind=board input=fixture/board.json'
  $tmA = Get-TcTaKeyMoved -Lines @('prepush-test-auditors: no pass reused (key=abc) - the inputs changed; running', $tmLine, 'prepush-test-auditors: running the suite in full')
  $tmN = Get-TcTaKeyMoved -Lines @('prepush-test-auditors: REUSED key=abc - fixture')
  $tmR = Get-TcTaKeyMoved -Lines @('  TA-KEY-MOVED kind=no-record')
  T ($kMF + '  the TA-KEY-MOVED line (W0.4) is copied as ta_moved exactly, and the no-record form with no input= is copied too') `
    ([string]::Equals([string]$tmA, $tmLine, [StringComparison]::Ordinal) -and [string]::Equals([string]$tmR, 'TA-KEY-MOVED kind=no-record', [StringComparison]::Ordinal)) ("moved={0} noRecord={1}" -f $tmA, $tmR)
  T ($kMNF + '  a test-auditors leg that printed no TA-KEY-MOVED line records ta_moved null') ($null -eq $tmN) ("got={0}" -f $tmN)

  $ctNn = Get-TcChainTouching -Outcome 'not-needed'
  $ctFail = Get-TcChainTouching -Outcome 'rehearsed-fail'
  $ctBlind = Get-TcChainTouching -Outcome 'could-not-rehearse'
  $ctErr = ''
  try { $null = Get-TcChainTouching -Outcome 'a-word-nobody-mapped' } catch { $ctErr = [string]$_.Exception.Message }
  T ($kCT + '  the rehearsal outcome maps to chain_touching: not-needed false, rehearsed-fail true, could-not-rehearse unknown (null)') `
    ($ctNn -eq $false -and $null -ne $ctNn -and $ctFail -eq $true -and $null -eq $ctBlind) ("notNeeded={0} fail={1} blind={2}" -f $ctNn, $ctFail, $ctBlind)
  T ($kMF + '  an outcome word outside rehearse-chain''s vocabulary THROWS, so a new word is loud rather than a silent null') ($ctErr -match 'a-word-nobody-mapped') ("err={0}" -f $ctErr)
  $rhOc = Get-TcRehearsalOutcome -Lines @('CHAIN-REHEARSAL-CHECK-COMPLETE code=1 outcome=no-verdict', 'chain-rehearsal: rehearsing HEAD now', 'CHAIN-REHEARSAL-CHECK-COMPLETE code=0 outcome=rehearsed-pass')
  T ($kMF + '  the LAST CHAIN-REHEARSAL-CHECK-COMPLETE line decides the outcome, as -ForPush prints a second decision after rehearsing') ($rhOc -ceq 'rehearsed-pass') ("outcome={0}" -f $rhOc)

  $seBoth = Get-TcPushSession -Environment @{ CLAUDE_CODE_HOST_SESSION_ID = 'local_host-fixture'; CLAUDE_CODE_SESSION_ID = 'own-fixture' }
  $seOwn = Get-TcPushSession -Environment @{ CLAUDE_CODE_SESSION_ID = 'own-fixture' }
  $seNone = Get-TcPushSession -Environment @{ UNRELATED = 'x' }
  T ($kCT + '  the session is the host id when one is set, the session''s own id otherwise, and null for a push no Claude session made') `
    ($seBoth.Value -ceq 'local_host-fixture' -and $seBoth.Var -ceq 'CLAUDE_CODE_HOST_SESSION_ID' -and $seOwn.Value -ceq 'own-fixture' -and $seOwn.Var -ceq 'CLAUDE_CODE_SESSION_ID' -and $null -eq $seNone.Value -and $null -eq $seNone.Var) `
    ("both={0}/{1} own={2}/{3} none={4}" -f $seBoth.Value, $seBoth.Var, $seOwn.Value, $seOwn.Var, $seNone.Value)

  # ---- the test-auditors leg outside the lock (queue 2026-09-18-1139a0), driven through fixture scripts ----
  # Founding case: 2026-09-18, a 389 s test-auditors run held the push lock because no pass was recorded before it.
  $taDir = Join-Path $env:TEMP ('tc-pm-ta-st-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
  $null = New-Item -ItemType Directory -Force -ErrorAction Stop $taDir
  try {
    $taSeen = Join-Path $taDir 'stdin-seen.txt'
    $taRed = Join-Path $taDir 'ta-red.ps1'
    $taGreen = Join-Path $taDir 'ta-green.ps1'
    $taBare = Join-Path $taDir 'ta-nomarker.ps1'
    [IO.File]::WriteAllText($taRed, "Write-Output 'prepush-test-auditors: REFUSED - a new failing case'`nWrite-Output 'PREPUSH-TEST-AUDITORS-COMPLETE rc=1'`nexit 1`n")
    [IO.File]::WriteAllText($taGreen, ("`$in = [Console]::In.ReadToEnd()`n[IO.File]::WriteAllText('" + $taSeen + "', `$in)`nWrite-Output 'TA-KEY-MOVED kind=content input=fixture/suite.ps1'`nWrite-Output 'prepush-test-auditors: PASS'`nWrite-Output 'PREPUSH-TEST-AUDITORS-COMPLETE rc=0'`nexit 0`n"))
    [IO.File]::WriteAllText($taBare, "Write-Output 'prepush-test-auditors: started'`nexit 0`n")
    $taLine = 'HEAD ' + $A + ' refs/heads/main ' + $B
    $tr = Invoke-TcWarmTestAuditors -Dir $taDir -RefLine $taLine -Script $taRed
    T ($kMF + '  a test-auditors check that refuses outside the lock refuses the push (Code 1), so it never queues') `
      ($tr.Ran -and $tr.Code -eq 1 -and $tr.Why -match 'test-auditors') ("ran={0} code={1} why={2}" -f $tr.Ran, $tr.Code, $tr.Why)
    $tg = Invoke-TcWarmTestAuditors -Dir $taDir -RefLine $taLine -Script $taGreen
    $seen = if (Test-Path -LiteralPath $taSeen) { ([IO.File]::ReadAllText($taSeen)).Trim() } else { '<no stdin recorded>' }
    T ($kCT + '  a passing check is Code 0 AND it was handed the exact ref line the hook will hand it, so its keyed pass is the one the in-lock run looks up') `
      ($tg.Ran -and $tg.Code -eq 0 -and [string]::Equals($seen, $taLine, [StringComparison]::Ordinal)) ("ran={0} code={1} stdin='{2}'" -f $tg.Ran, $tg.Code, $seen)
    # FOR THE ROW (W0.1, W0.4): the leg hands back its own exit code, an integer time and its lines, and the TA-KEY-MOVED
    # line it printed before running is what ta_moved copies.
    $tgMoved = Get-TcTaKeyMoved -Lines $tg.Lines
    T ($kCT + '  a passing check also returns its exit code, an integer time and its lines, and its TA-KEY-MOVED line reads back exactly') `
      ($tg.Exit -eq 0 -and $tg.Sec -is [int] -and $tg.Sec -ge 0 -and [string]::Equals([string]$tgMoved, 'TA-KEY-MOVED kind=content input=fixture/suite.ps1', [StringComparison]::Ordinal)) `
      ("exit={0} sec={1} moved={2}" -f $tg.Exit, $tg.Sec, $tgMoved)
    # THE RUN-GATES LEG NOW RUNS THROUGH A PIPELINE (W0.1), so the three things Start-Process gave it are asserted here:
    # the exit code survives (a red must stay red), the child runs in the checkout it judges, and its lines come back.
    $rgDir = Join-Path $taDir 'rgfx'
    $null = New-Item -ItemType Directory -Force -ErrorAction Stop (Join-Path $rgDir 'ops')
    $rgStub = Join-Path $rgDir 'ops\run-gates.ps1'
    $rgCwd = Join-Path $taDir 'rg-cwd.txt'
    [IO.File]::WriteAllText($rgStub, ("[IO.File]::WriteAllText('" + $rgCwd + "', (Get-Location).Path)`nWrite-Output '" + $rgLine + "'`nWrite-Output 'RUN-GATES-COMPLETE pass=7 fail=0'`nexit 0`n"))
    $wgOk = Invoke-TcWarmGate -Dir $rgDir
    $cwdSeen = if (Test-Path -LiteralPath $rgCwd) { ([IO.File]::ReadAllText($rgCwd)).Trim() } else { '<not written>' }
    $wgOkR = Get-TcRunGatesReading -Lines $wgOk.Lines
    T ($kCT + '  the run-gates leg run through the pipeline still returns its exit code 0, ran in the checkout it judges, and hands back its reuse line') `
      ($wgOk.Ran -and $wgOk.Code -eq 0 -and $wgOk.Sec -is [int] -and [string]::Equals($cwdSeen.TrimEnd('\'), $rgDir.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase) -and $wgOkR.Reused -eq 3) `
      ("ran={0} code={1} sec={2} cwd={3} reused={4}" -f $wgOk.Ran, $wgOk.Code, $wgOk.Sec, $cwdSeen, $wgOkR.Reused)
    [IO.File]::WriteAllText($rgStub, "Write-Output '  FAIL  fixture-gate  (exit 1)'`nexit 1`n")
    $wgRed = Invoke-TcWarmGate -Dir $rgDir
    T ($kMF + '  a run-gates that exits 1 through the pipeline is Code 1, so a red gate outside the lock still refuses') `
      ($wgRed.Ran -and $wgRed.Code -eq 1) ("ran={0} code={1}" -f $wgRed.Ran, $wgRed.Code)
    $tb = Invoke-TcWarmTestAuditors -Dir $taDir -RefLine $taLine -Script $taBare
    T ($kMF + '  an exit 0 with no completion marker is could-not-evaluate (3), never a pass') `
      ($tb.Code -eq 3 -and $tb.Why -match 'marker') ("code={0} why={1}" -f $tb.Code, $tb.Why)
    $tn = Invoke-TcWarmTestAuditors -Dir $taDir -RefLine '' -Script $taGreen
    T ($kMF + '  a ref line that could not be formed is could-not-evaluate (3), and the check is not run on a guess') `
      ($tn.Code -eq 3 -and -not $tn.Ran) ("ran={0} code={1}" -f $tn.Ran, $tn.Code)
  } finally {
    Remove-Item -LiteralPath $taDir -Recurse -Force -ErrorAction SilentlyContinue
  }

  # ---- THE TWO LEGS AT ONCE (2026-10-01, design\PLAN-push-speed-2026-10-01.md step 2) ----
  # Founding cost: run-gates (396 s) then test-auditors (631 s) one after the other on 2026-10-01's landings. Proved by a
  # RENDEZVOUS, never a stopwatch (og-36): each leg's stub joins a 2-way rendezvous, which only completes if both legs
  # were alive at once; a serial runner leaves the first leg waiting alone until the probe's deadline.
  . (Join-Path $repo 'lib\concurrency-probe.ps1')
  $lgDir = Join-Path $env:TEMP ('tc-pm-lg-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
  $null = New-Item -ItemType Directory -Force -ErrorAction Stop (Join-Path $lgDir 'ops')
  try {
    $lgProbe = New-TcRendezvousProbe -Count 2 -DeadlineSec 120
    $lgJoin = "& powershell.exe -NoProfile -ExecutionPolicy Bypass -File '" + $lgProbe.Script + "' | Out-Null`n"
    [IO.File]::WriteAllText((Join-Path $lgDir 'ops\run-gates.ps1'), ($lgJoin + "Write-Output 'RUN-GATES-COMPLETE pass=1 fail=0'`nexit 0`n"))
    $lgCwd = Join-Path $env:TEMP ('tc-pm-lg-cwd-' + [guid]::NewGuid().ToString('N').Substring(0, 10) + '.txt')
    [IO.File]::WriteAllText((Join-Path $lgDir 'ops\prepush-test-auditors.ps1'), ($lgJoin + "[IO.File]::WriteAllText('" + $lgCwd + "', (Get-Location).Path)`n`$null = [Console]::In.ReadToEnd()`nWrite-Output 'prepush-test-auditors: PASS'`nWrite-Output 'PREPUSH-TEST-AUDITORS-COMPLETE rc=0'`nexit 0`n"))
    [IO.File]::WriteAllText((Join-Path $lgDir 'ops\seed-worktree.ps1'), "param([string]`$Target)`n`$SEED_DIRS = @(@{ p = 'fixture-seed' })`nexit 0`n")
    foreach ($ga in @(@('init', '-q'), @('-c', 'user.email=t@t', '-c', 'user.name=t', 'add', '-A'), @('-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-q', '-m', 'legs fixture'))) { $null = Invoke-TcGit -Dir $lgDir -Arguments $ga }
    $lgHead = ([string]@((Invoke-TcGit -Dir $lgDir -Arguments @('rev-parse', 'HEAD')).Out)[0]).Trim()
    $null = Invoke-TcGit -Dir $lgDir -Arguments @('update-ref', 'refs/remotes/origin/main', $lgHead)
    $lgRes = Invoke-TcDefaultLegs -Dir $lgDir -Remote 'origin' -Branch 'main'
    $lgV = Get-TcRendezvousVerdict -Probe $lgProbe
    $lgCwdSeen = if (Test-Path -LiteralPath $lgCwd) { ([IO.File]::ReadAllText($lgCwd)).Trim() } else { '<not written>' }
    Remove-Item -LiteralPath $lgCwd -Force -ErrorAction SilentlyContinue
    # IN THE PUSHING CHECKOUT, because its pass record is named by the checkout root: a leg run elsewhere made the
    # in-lock hook re-run all 818 cases holding the lock (7b6f1698e's own landing, 327 s).
    T ($kCT + '  run-gates and test-auditors run AT THE SAME TIME (both legs meet at one rendezvous), test-auditors runs IN the pushing checkout where its pass record lives, and the pass is a pass') `
      ($lgRes.Code -eq 0 -and $lgV.Ok -and $lgRes.TaExit -eq 0 -and [string]::Equals($lgCwdSeen.TrimEnd('\'), $lgDir.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) ("code={0} rendezvous={1} taExit={2} taCwd={3}" -f $lgRes.Code, $lgV.Detail, $lgRes.TaExit, $lgCwdSeen)
    # A red run-gates still collects test-auditors, so ONE refusal names both layers (landing 1 of 2026-10-01 hid five
    # test-auditors reds behind eight gate reds, and the run ended unlanded on its one retry).
    [IO.File]::WriteAllText((Join-Path $lgDir 'ops\run-gates.ps1'), "Write-Output '  FAIL  fixture-gate  (exit 1)'`nWrite-Output 'RUN-GATES-COMPLETE pass=0 fail=1'`nexit 1`n")
    [IO.File]::WriteAllText((Join-Path $lgDir 'ops\prepush-test-auditors.ps1'), "`$null = [Console]::In.ReadToEnd()`nWrite-Output 'prepush-test-auditors: REFUSED - a new failing case'`nWrite-Output 'PREPUSH-TEST-AUDITORS-COMPLETE rc=1'`nexit 1`n")
    $null = Invoke-TcGit -Dir $lgDir -Arguments @('-c', 'user.email=t@t', '-c', 'user.name=t', 'add', '-A')
    $lgCommit = Invoke-TcGit -Dir $lgDir -Arguments @('-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-q', '-m', 'both red')
    $lgHead2 = ([string]@((Invoke-TcGit -Dir $lgDir -Arguments @('rev-parse', 'HEAD')).Out)[0]).Trim()
    $lgRed = Invoke-TcDefaultLegs -Dir $lgDir -Remote 'origin' -Branch 'main'
    T ($kMF + '  a red run-gates still waits for test-auditors: the refusal is the gate''s, and it names test-auditors'' red too') `
      ($lgHead2 -ne $lgHead -and $lgRed.Code -eq 1 -and $lgRed.TaExit -eq 1 -and ([string]$lgRed.Why) -match 'test-auditors refused too') ("headMoved={0} commit={1} code={2} taExit={3} why={4}" -f ($lgHead2 -ne $lgHead), (([string]$lgCommit.Text) -replace '\s+', ' '), $lgRed.Code, $lgRed.TaExit, $lgRed.Why)
  } finally {
    Remove-TcRendezvousProbe
    $null = Invoke-TcGit -Dir $lgDir -Arguments @('worktree', 'prune')
    Remove-Item -LiteralPath $lgDir -Recurse -Force -ErrorAction SilentlyContinue
  }

  # ---- the whole thing, against real repositories ----
  $tmp = Join-Path $env:TEMP ('tc-pm-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
  $null = New-Item -ItemType Directory -Force -ErrorAction Stop $tmp
  $prefix = 'Local\tc-push-main-selftest-' + [guid]::NewGuid().ToString('N') + '-'
  $qroot = Join-Path $tmp 'q'
  # EVERY CASE INJECTS ITS GATE. Without this each fixture below would launch the real ops\run-gates.ps1 - hundreds of
  # seconds, the 24 machine-wide slots, from a suite that run-gates itself runs. The seam is what makes the ORDER
  # assertable at all: $gateSawLock records whether the push lock was free at the moment the gate ran, which is the
  # mechanism this change is about and cannot be read from a clock.
  #
  # THE PROBE MUST RUN IN ANOTHER PROCESS, and the first version of this case did not - it SURVIVED the mutant that
  # hoists the lock back above the gate (2026-09-12, measured: mutant exit 0, the case still ok). A Windows mutex is
  # REENTRANT ON ITS OWNING THREAD, so a probe calling Enter-TcPushLock from inside this same process is handed the
  # lock the caller is already holding and reports it free either way. `-NoInherit` does not help: that governs the
  # token a descendant reads, not the kernel object's own thread affinity. This is the estate's insensitive-fixture
  # shape - a live case, a true assertion, and no ability to see which half was working.
  $probeScript = Join-Path $tmp 'lockprobe.ps1'
  [IO.File]::WriteAllText($probeScript, @'
param([string]$Name)
$m = $null
try { $m = [System.Threading.Mutex]::OpenExisting($Name) } catch { Write-Output 'FREE'; exit 0 }
$got = $m.WaitOne(0)
if ($got) { $m.ReleaseMutex(); Write-Output 'FREE' } else { Write-Output 'HELD' }
$m.Dispose()
'@)
  $script:gateSawLock = $null
  $script:gateRuns = 0
  $okGate = {
    param($d)
    $script:gateRuns++
    # NO `2>$null` HERE. Under EAP=Stop a native child's first stderr line becomes a terminating throw, which is what
    # grocery\test-native-stderr-eap.ps1 ratchets - and this probe's whole job is to report what it saw, so a redirect
    # that could swallow the reason it could not look is the last thing it should carry.
    $out = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $probeScript -Name ($prefix + '0'))
    $script:gateSawLock = [bool](@($out | Where-Object { "$_".Trim() -eq 'FREE' }).Count)
    return [pscustomobject]@{ Ran = $true; Code = 0; Why = '' }
  }
  $redGate = { param($d) $script:gateRuns++; return [pscustomobject]@{ Ran = $true; Code = 1; Why = '' } }
  $blindGate = { param($d) $script:gateRuns++; return [pscustomobject]@{ Ran = $true; Code = 3; Why = 'no gate worker slot' } }

  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  # EVERY CASE IN THIS SUITE WRITES ITS LEDGER ROWS TO SCRATCH (2026-09-12). The cases that do not pass -LedgerRoot
  # push temp CLONES, so before this redirect existed their rows - real shas, real waits, from repositories that
  # exist for a second - went into the production ledger and were counted by the first live convergence report.
  # A default that reaches a real path is redirected suite-wide, never per fixture.
  $prodLedger = Get-TcPushLedgerPath
  $ledgerRootWas = $env:TC_PUSH_LEDGER_ROOT
  $env:TC_PUSH_LEDGER_ROOT = Join-Path $tmp 'suite-ledger'
  # AND EVERY ROW IT WRITES CARRIES THIS RUN'S ID, which is what the production check below filters on - never this
  # process's pid, which Windows recycles within the day the production file covers (backlog I171). Exported, so a
  # row written by a child of these cases carries it too.
  $runWas = $env:TC_PUSH_LEDGER_RUN
  $suiteRun = New-TcPushLedgerRunId
  $env:TC_PUSH_LEDGER_RUN = $suiteRun
  # NO CASE OPENS THE PRODUCTION PER-CHECKOUT GUARD (plan section 5): every Invoke-TcPushMain below takes a private
  # Local\ name, and its holder files go under this run's root. Put back in the finally.
  $guardPrefixWas = $script:TcPmGuardPrefix
  $guardInfoWas = $script:TcPmGuardInfoRoot
  $script:TcPmGuardPrefix = 'Local\tc-pm-guard-selftest-' + [guid]::NewGuid().ToString('N').Substring(0, 12) + '-'
  $script:TcPmGuardInfoRoot = Join-Path $tmp 'guard'
  # AND NO CASE OPENS THE PRODUCTION CHAIN QUEUE (W9.2, interface step 11): a private Local\ prefix and a root under this
  # run's directory, with TC_CHAIN_QUEUE_SELFTEST set suite-wide, so a case that forgot the seam THROWS instead of
  # queueing real pushes behind it.
  $cqPrefixWas = $script:TcPmChainQueuePrefix; $cqRootWas = $script:TcPmChainQueueRoot; $cqSelfTestWas = $env:TC_CHAIN_QUEUE_SELFTEST
  $script:TcPmChainQueuePrefix = 'Local\tc-pm-cq-selftest-' + [guid]::NewGuid().ToString('N').Substring(0, 12) + '-'
  $script:TcPmChainQueueRoot = Join-Path $tmp 'cq'
  $env:TC_CHAIN_QUEUE_SELFTEST = '1'
  $reexecWas = $env:TC_PUSH_MAIN_REEXEC
  Remove-Item -LiteralPath Env:TC_PUSH_MAIN_REEXEC -ErrorAction SilentlyContinue
  . (Join-Path $repo 'lib\mutex-hold.ps1')   # Start-TcMutexHold: a guard held from ANOTHER process
  # CONSOLE CAPTURE, for the cases that read what push-main SAID: Say writes to [Console]::Out, which a StringWriter can
  # stand in for while one call runs. Children echoed through Say are captured too.
  function Invoke-StCapture([scriptblock]$CapBody) {
    $capOld = [Console]::Out
    $capSw = New-Object IO.StringWriter
    [Console]::SetOut($capSw)
    $capRes = $null
    try { $capRes = & $CapBody } finally { [Console]::SetOut($capOld) }
    return [pscustomobject]@{ Result = $capRes; Text = $capSw.ToString() }
  }
