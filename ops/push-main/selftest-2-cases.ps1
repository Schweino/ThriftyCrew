    Clear-TcGitRepoEnv
    $origin = Join-Path $tmp 'origin'
    $null = & git init -q --bare $origin 2>$null
    $script:cloneFails = 0
    function New-Clone([string]$Name) {
      $d = Join-Path $tmp $Name
      $null = & git clone -q $origin $d 2>$null
      $null = & git -C $d config user.name Probe 2>$null
      $null = & git -C $d config user.email p@p 2>$null
      # A CLONE THAT CAME UP EMPTY IS NAMED, NEVER USED. `git init --bare` points HEAD at the branch named by
      # init.defaultBranch, and this seed pushes `main`; when those differ, clone finds the remote HEAD pointing at a
      # ref that does not exist, checks nothing out, and leaves an unborn branch. Every commit made in it is then a
      # ROOT commit sharing no ancestor with main - which is exactly how five cases here passed or failed for reasons
      # that had nothing to do with the code. The fix is the symbolic-ref below; this is the assertion that the fix
      # held, so a fixture running against empty clones can never read as a result.
      $n = @(& git -C $d rev-list --count HEAD 2>$null)
      if (-not $n.Count -or [int]([string]$n[0]).Trim() -lt 1) { $script:cloneFails++ }
      return $d
    }
    $seed = Join-Path $tmp 'seed'
    $null = & git init -q $seed 2>$null
    $null = & git -C $seed config user.name Probe 2>$null
    $null = & git -C $seed config user.email p@p 2>$null
    [IO.File]::WriteAllText((Join-Path $seed 'seed.txt'), 'seed')
    $null = & git -C $seed add -- seed.txt 2>$null
    $null = & git -C $seed commit -q -m seed 2>$null
    $null = & git -C $seed branch -M main 2>$null
    $null = & git -C $seed remote add origin $origin 2>$null
    $null = & git -C $seed push -q origin main 2>$null
    # The bare repository's HEAD must name the branch it actually has, or every clone below comes up empty - see the
    # account in New-Clone.
    $null = & git -C $origin symbolic-ref HEAD refs/heads/main 2>$null

    # ---- SEEDED BEFORE THE GATE (backlog I237) ----
    # Founding case: 2026-09-18, a fresh worktree's first push-main was refused by the warm test-auditors leg over
    # feed-covers-published's BLIND verdict, because nothing seeded the checkout before the gate outside the lock.
    # The gate seam records whether the seed directory held a file when the gate ran: the ORDER, read from the
    # mechanism. The stub seeder declares its own one-directory list, which is what push-main reads to decide.
    $sdList = '$SEED' + '_DIRS = @( @{ p = ''seedfx\cards''; why = ''fixture'' } )'
    $sdStub = Join-Path $tmp 'seed-stub.ps1'
    $sdFail = Join-Path $tmp 'seed-fail.ps1'
    $sdBody = @(
      'Add-Content -LiteralPath (Join-Path $Target ''seeded-for.txt'') -Value $Target',
      '$d = Join-Path $Target ''seedfx\cards''',
      '$null = New-Item -ItemType Directory -Force $d',
      '[IO.File]::WriteAllText((Join-Path $d ''one.card''), ''card'')',
      'exit 0') -join "`n"
    [IO.File]::WriteAllText($sdStub, ("param([string]`$Target)`n" + $sdList + "`n" + $sdBody + "`n"))
    [IO.File]::WriteAllText($sdFail, ("param([string]`$Target)`n" + $sdList + "`nexit 1`n"))
    $script:cardAtGate = $null
    $cardGate = { param($d) $script:cardAtGate = Test-Path -LiteralPath (Join-Path $d 'seedfx\cards\one.card'); return [pscustomobject]@{ Ran = $true; Code = 0; Why = '' } }
    $s1 = New-Clone 's1'
    Add-Content -LiteralPath (Join-Path $s1 '.git\info\exclude') -Value @('seeded-for.txt', 'seedfx/') -Encoding ascii   # gitignored in the real repo
    [IO.File]::WriteAllText((Join-Path $s1 's1.txt'), 's1')
    $null = & git -C $s1 add -- s1.txt 2>$null; $null = & git -C $s1 commit -q -m s1 2>$null
    $rS1 = Invoke-TcPushMain -Dir $s1 -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $true -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $cardGate -SeedScript $sdStub
    $sFor = if (Test-Path -LiteralPath (Join-Path $s1 'seeded-for.txt')) { ([IO.File]::ReadAllText((Join-Path $s1 'seeded-for.txt'))).Trim() } else { '<not seeded>' }
    T ($kMF + '  a checkout with nothing in a directory the seeder seeds is seeded, with -Target naming it, BEFORE the gate runs') `
      ($rS1 -eq 0 -and $script:cardAtGate -eq $true -and [string]::Equals($sFor, $s1, [StringComparison]::OrdinalIgnoreCase)) ("rc={0} cardAtGate={1} seededFor={2}" -f $rS1, $script:cardAtGate, $sFor)
    Remove-Item -LiteralPath (Join-Path $s1 'seeded-for.txt') -Force -ErrorAction SilentlyContinue
    # A SEEDED CHECKOUT IS RE-SEEDED (2026-09-23): the founding case was a reused worktree whose built card was copied
    # 2026-09-03 and never refreshed, because this returned 'already seeded' and never called the seeder again.
    $rS2 = Invoke-TcSeedBeforeGate -Dir $s1 -Seeder $sdStub
    $sFor2 = if (Test-Path -LiteralPath (Join-Path $s1 'seeded-for.txt')) { ([IO.File]::ReadAllText((Join-Path $s1 'seeded-for.txt'))).Trim() } else { '<not seeded>' }
    T ($kMF + '  a checkout whose seed directories already hold files is RE-SEEDED, so a stale seeded file can be refreshed') `
      ($rS2.Ran -and $rS2.Code -eq 0 -and [string]::Equals($sFor2, $s1, [StringComparison]::OrdinalIgnoreCase)) ("ran={0} code={1} why={2} seededFor={3}" -f $rS2.Ran, $rS2.Code, $rS2.Why, $sFor2)
    Remove-Item -LiteralPath (Join-Path $s1 'seeded-for.txt') -Force -ErrorAction SilentlyContinue
    $s3 = New-Clone 's3'
    Add-Content -LiteralPath (Join-Path $s3 '.git\info\exclude') -Value @('seeded-for.txt', 'seedfx/') -Encoding ascii   # gitignored in the real repo
    [IO.File]::WriteAllText((Join-Path $s3 's3.txt'), 's3')
    $null = & git -C $s3 add -- s3.txt 2>$null; $null = & git -C $s3 commit -q -m s3 2>$null
    $script:gateRuns = 0
    $rS3 = Invoke-TcPushMain -Dir $s3 -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $true -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $okGate -SeedScript $sdFail
    T ($kCT + '  a seed that fails is best effort: the gate still runs and the push still proceeds') `
      ($rS3 -eq 0 -and $script:gateRuns -eq 1) ("rc={0} gateRuns={1}" -f $rS3, $script:gateRuns)
    # THE CHAIN REHEARSAL LEG (2026-09-22, plan-2026-09-22-7): it runs after a green gate and before the lock, and a
    # failed or could-not-run rehearsal refuses there with its own code; the runner is the seam, as the gate's is.
    $rhRed = { param($d) [pscustomobject]@{ Code = 1; Why = 'fixture: the rehearsal failed at stage commit' } }
    $rhBlind = { param($d) [pscustomobject]@{ Code = 3; Why = 'fixture: blind=no-seed-board' } }
    $rhGreen = { param($d) [pscustomobject]@{ Code = 0; Why = 'fixture: rehearsed-pass' } }
    $script:gateRuns = 0
    $rR1 = Invoke-TcPushMain -Dir $s3 -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $true -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $okGate -SeedScript $sdFail -RehearsalRunner $rhRed
    T ($kMF + '  a push whose chain rehearsal FAILED is refused (1) before the lock, after its gate ran once') `
      ($rR1 -eq 1 -and $script:gateRuns -eq 1) ("rc={0} gateRuns={1}" -f $rR1, $script:gateRuns)
    $rR2 = Invoke-TcPushMain -Dir $s3 -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $true -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $okGate -SeedScript $sdFail -RehearsalRunner $rhBlind
    T ($kMNF + '  a rehearsal that could not run is exit 3, never a pass and never read as a red') ($rR2 -eq 3) ("rc={0}" -f $rR2)
    $rR3 = Invoke-TcPushMain -Dir $s3 -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $true -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $okGate -SeedScript $sdFail -RehearsalRunner $rhGreen
    T ($kCT + '  a passing rehearsal lets the push go on to the lock exactly as before') ($rR3 -eq 0) ("rc={0}" -f $rR3)
    $rR4 = (Start-TcRehearsalChild -Dir $s3 -Remote 'origin' -Branch 'main').Wait()
    T ($kMNF + '  a checkout with no ops\rehearse-chain.ps1 is not asked for a rehearsal (the older-checkout rule)') ($rR4.Code -eq 0) ("code={0} why={1}" -f $rR4.Code, $rR4.Why)

    # ---- THE REHEARSAL JUDGES THE REBASED CONTENT (2026-09-23) ----
    # Founding case: on 2026-09-23 several landings rehearsed the content from BEFORE push-main's in-lock rebase, the hook
    # found no verdict for the rebased content, and each push paid a second 13-to-15-minute rehearsal. The fixture models
    # ops\rehearse-chain.ps1's verdict key at small scale: a verdict covers one blob of chain.ps1 (the "manifest"), the
    # rehearsal runner records one for whatever HEAD it sees, and the in-lock check asks whether HEAD's blob has one. The
    # runner can also make origin MOVE while it runs, from a second clone, which is the window the trade-off is about.
    $script:rhVerdicts = @{}
    $script:rhSeen = New-Object Collections.ArrayList
    $script:rhMoves = @()
    $script:rhLockFree = $null
    $mover = New-Clone 'mover'
    $blobOf = { param($d) $bo = @(& git -C $d rev-parse 'HEAD:chain.ps1' 2>$null); if ($LASTEXITCODE -eq 0 -and $bo.Count) { ([string]$bo[0]).Trim() } else { 'no-chain' } }
    $moveOrigin = { param([string]$File)
      $null = & git -C $mover pull -q --rebase origin main 2>$null
      [IO.File]::WriteAllText((Join-Path $mover $File), ('moved ' + [guid]::NewGuid().ToString('N')))
      $null = & git -C $mover add -- $File 2>$null; $null = & git -C $mover commit -q -m ('move ' + $File) 2>$null
      $null = & git -C $mover push -q origin HEAD:main 2>$null
    }
    # THE MODEL SAYS WHEN IT REUSED A VERDICT (W2.2R). It records every call in rhSeen, and it REHEARSES (records a new
    # verdict, and says Rehearsed) only for a chain.ps1 blob with no verdict yet; a blob it already covers is a reuse, as a
    # real -ForPush reads a recorded verdict in seconds. Each case clears rhVerdicts first, so its own first round rehearses.
    $rhModel = { param($d)
      [void]$script:rhSeen.Add(([string](@(& git -C $d rev-parse HEAD 2>$null))[0]).Trim())
      $pr = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $probeScript -Name ($prefix + '0'))
      $script:rhLockFree = [bool](@($pr | Where-Object { "$_".Trim() -eq 'FREE' }).Count)
      $rk = & $blobOf $d
      $isNew = -not $script:rhVerdicts.ContainsKey($rk)
      $script:rhVerdicts[$rk] = $true
      if ($script:rhMoves.Count) { $mf = $script:rhMoves[0]; $script:rhMoves = @($script:rhMoves | Select-Object -Skip 1); & $moveOrigin $mf }
      return [pscustomobject]@{ Code = 0; Why = $(if ($isNew) { 'fixture: rehearsed-pass' } else { 'fixture: reused a recorded verdict' }); Rehearsed = $isNew }
    }
    $rhCheck = { param($d, $h, $r) if ($script:rhVerdicts.ContainsKey((& $blobOf $d))) { [pscustomobject]@{ Code = 0; Why = 'covered' } } else { [pscustomobject]@{ Code = 1; Why = 'fixture: no-verdict for the rebased chain.ps1' } } }
    $greenGate = { param($d) [pscustomobject]@{ Ran = $true; Code = 0; Why = '' } }
    $newPusher = { param([string]$Name)
      $pd = New-Clone $Name
      [IO.File]::WriteAllText((Join-Path $pd ($Name + '.txt')), $Name)
      $null = & git -C $pd add -- ($Name + '.txt') 2>$null; $null = & git -C $pd commit -q -m $Name 2>$null
      return $pd
    }
    $tipOf = { ([string](@(& git -C $origin rev-parse main 2>$null))[0]).Trim() }
    $isAnc = { param($d, $anc, $desc) $null = & git -C $d merge-base --is-ancestor $anc $desc 2>$null; return ($LASTEXITCODE -eq 0) }

    # THE LOCK-ENTRY MOVER (W2.2R). Since the catch-up fetch after every round's legs, a move made DURING the legs is caught
    # outside the lock, so the in-lock hand-back is reached only by a move in the window between that fetch and the fetch
    # inside the lock. Invoke-WithLockMover reaches it: for one run, Enter-TcPushLock is wrapped so that, immediately
    # before each real take, it applies the next entry of $script:lockMoves (a file name moved on origin, or a scriptblock),
    # and records the take's WaitedMs as the lock reported it. The real function is put back in finally.
    # W9.4: -LmCap is the lock hand-back cap for the run. The cases written before W9.4 pass 0 (the default): they are about
    # what happens AT the cap, where the lock rebases inside and the verdict check decides, which 0 reaches at the first
    # take. The W9.4 cases pass -1, which keeps the production cap. -LmDir names the checkout whose HEAD is recorded at
    # every take (after the grant) and every release, so a case can prove no rebase ran while the lock was held.
    $script:lockMoves = @()
    $script:lockWaitsSeen = [Collections.Generic.List[double]]::new()
    $script:lockHeads = [Collections.Generic.List[string]]::new()
    $script:lmDir = ''
    $script:enterTcPushLockReal = ${function:Enter-TcPushLock}
    $script:exitTcPushLockReal = ${function:Exit-TcPushLock}
    $script:handBackCapReal = $script:PmMaxHandBacks
    function Invoke-WithLockMover([scriptblock]$LmBody, [int]$LmCap = 0, [string]$LmDir = '') {
      $script:lockWaitsSeen.Clear(); $script:lockHeads.Clear(); $script:lmDir = $LmDir
      try {
        if ($LmCap -ge 0) { $script:PmMaxHandBacks = $LmCap }
        function script:Enter-TcPushLock {
          param([int]$WaitSec, [int]$PollMs, [string]$Prefix, [string]$QueueRoot, [scriptblock]$OnWait, [switch]$NoInherit)
          if ($script:lockMoves.Count) {
            $lmv = $script:lockMoves[0]; $script:lockMoves = @($script:lockMoves | Select-Object -Skip 1)
            if ($lmv -is [scriptblock]) { & $lmv } else { & $moveOrigin ([string]$lmv) }
          }
          $lk = & $script:enterTcPushLockReal @PSBoundParameters
          [void]$script:lockWaitsSeen.Add([double]$lk.WaitedMs)
          if ($script:lmDir) { [void]$script:lockHeads.Add('take ' + ([string](@(& git -C $script:lmDir rev-parse HEAD 2>$null))[0]).Trim()) }
          return $lk
        }
        function script:Exit-TcPushLock {
          param($Lock)
          if ($script:lmDir) { [void]$script:lockHeads.Add('release ' + ([string](@(& git -C $script:lmDir rev-parse HEAD 2>$null))[0]).Trim()) }
          & $script:exitTcPushLockReal $Lock
        }
        return (& $LmBody)
      } finally {
        $script:PmMaxHandBacks = $script:handBackCapReal
        Set-Item -LiteralPath 'function:script:Enter-TcPushLock' -Value $script:enterTcPushLockReal
        Set-Item -LiteralPath 'function:script:Exit-TcPushLock' -Value $script:exitTcPushLockReal
      }
    }

    # MUST FIRE, the founding order: origin moved over chain.ps1 BEFORE this push started. The one rehearsal must see a
    # HEAD already rebased on top of that move, with the push lock free while it runs, and the push lands on it.
    $q1 = & $newPusher 'q1'
    & $moveOrigin 'chain.ps1'
    $moved1 = & $tipOf
    $script:rhSeen.Clear(); $script:rhMoves = @(); $script:rhVerdicts = @{}
    $tokenWas2 = $env:TC_PUSH_LOCK_HOLDER; $env:TC_PUSH_LOCK_HOLDER = $null
    $rQ1 = Invoke-TcPushMain -Dir $q1 -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $greenGate -RehearsalRunner $rhModel -RehearsalCheck $rhCheck
    $env:TC_PUSH_LOCK_HOLDER = $tokenWas2
    $seen1 = $(if ($script:rhSeen.Count) { [string]$script:rhSeen[0] } else { '' })
    T ($kMF + '  the rehearsal judges the REBASED content: origin moved over a manifest script before the push, and the one rehearsal saw a HEAD already on top of it, outside the lock') `
      ($rQ1 -eq 0 -and $script:rhSeen.Count -eq 1 -and $seen1 -and (& $isAnc $q1 $moved1 $seen1) -and $script:rhLockFree -eq $true -and (& $tipOf) -eq $seen1) `
      ("rc={0} rehearsals={1} sawRebased={2} lockFree={3} landedWhatWasRehearsed={4}" -f $rQ1, $script:rhSeen.Count, $(if ($seen1) { & $isAnc $q1 $moved1 $seen1 } else { $false }), $script:rhLockFree, ((& $tipOf) -eq $seen1))

    # MUST FIRE, the trade-off: origin changes a manifest script in the window AFTER the catch-up fetch and before the fetch
    # inside the lock (the lock-entry mover). The rebase inside the lock moves the key, so the push hands the lock back and
    # rehearses the rebased content again before it pushes.
    $q2 = & $newPusher 'q2'
    $script:rhSeen.Clear(); $script:rhMoves = @(); $script:rhVerdicts = @{}; $script:lockMoves = @('chain.ps1')
    $rQ2 = Invoke-WithLockMover { Invoke-TcPushMain -Dir $q2 -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $greenGate -RehearsalRunner $rhModel -RehearsalCheck $rhCheck }
    $moved2 = ([string](@(& git -C $mover rev-parse HEAD 2>$null))[0]).Trim()
    $seen2 = $(if ($script:rhSeen.Count -ge 2) { [string]$script:rhSeen[1] } else { '' })
    T ($kMF + '  a rebase inside the lock that changes a manifest script re-rehearses before the push: two rehearsals, the second over the moved content, and it lands') `
      ($rQ2 -eq 0 -and $script:rhSeen.Count -eq 2 -and $seen2 -and (& $isAnc $q2 $moved2 $seen2) -and (& $tipOf) -eq $seen2) `
      ("rc={0} rehearsals={1} secondSawMove={2}" -f $rQ2, $script:rhSeen.Count, $(if ($seen2) { & $isAnc $q2 $moved2 $seen2 } else { $false }))

    # CLEAN TWIN: origin moves in that same window over a file no rehearsal covers. The rebase inside the lock keeps the
    # key, the recorded verdict is reused, and the push lands after ONE rehearsal carrying the moved commit.
    $q3 = & $newPusher 'q3'
    $script:rhSeen.Clear(); $script:rhMoves = @(); $script:rhVerdicts = @{}; $script:lockMoves = @('notes.txt')
    $rQ3 = Invoke-WithLockMover { Invoke-TcPushMain -Dir $q3 -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $greenGate -RehearsalRunner $rhModel -RehearsalCheck $rhCheck }
    $moved3 = ([string](@(& git -C $mover rev-parse HEAD 2>$null))[0]).Trim()
    $head3 = ([string](@(& git -C $q3 rev-parse HEAD 2>$null))[0]).Trim()
    T ($kCT + '  a rebase inside the lock over non-manifest commits reuses the verdict: one rehearsal, and the landed HEAD carries the moved commit') `
      ($rQ3 -eq 0 -and $script:rhSeen.Count -eq 1 -and (& $isAnc $q3 $moved3 $head3) -and (& $tipOf) -eq $head3) `
      ("rc={0} rehearsals={1} carriesMove={2} landed={3}" -f $rQ3, $script:rhSeen.Count, (& $isAnc $q3 $moved3 $head3), ((& $tipOf) -eq $head3))

    # THE REHEARSAL CAP (3), AT it and one PAST it, over in-lock hand-backs. At the bar: origin changes chain.ps1 at the
    # lock entry of rounds 1 and 2, and round 3 lands. Past it: at all three, and the push is refused rather than looping.
    $q4 = & $newPusher 'q4'
    $script:rhSeen.Clear(); $script:rhMoves = @(); $script:rhVerdicts = @{}; $script:lockMoves = @('chain.ps1', 'chain.ps1')
    $ledRoot4 = Join-Path $tmp 'led4'
    $rQ4 = Invoke-WithLockMover { Invoke-TcPushMain -Dir $q4 -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $greenGate -RehearsalRunner $rhModel -RehearsalCheck $rhCheck -LedgerRoot $ledRoot4 }
    T ($kMNF + '  at the 3-round cap (origin changes a manifest script in rounds 1 and 2) the push still lands, after exactly 3 rehearsals') `
      ($rQ4 -eq 0 -and $script:rhSeen.Count -eq 3) ("rc={0} rehearsals={1}" -f $rQ4, $script:rhSeen.Count)
    $q5 = & $newPusher 'q5'
    $script:rhSeen.Clear(); $script:rhMoves = @(); $script:rhVerdicts = @{}; $script:lockMoves = @('chain.ps1', 'chain.ps1', 'chain.ps1')
    $ledRoot5 = Join-Path $tmp 'led5'
    $rQ5 = Invoke-WithLockMover { Invoke-TcPushMain -Dir $q5 -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $greenGate -RehearsalRunner $rhModel -RehearsalCheck $rhCheck -LedgerRoot $ledRoot5 }
    $head5 = ([string](@(& git -C $q5 rev-parse HEAD 2>$null))[0]).Trim()
    $row5Raw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledRoot5)
    $row5 = @($row5Raw)
    T ($kMF + '  one round past the cap (origin changes a manifest script in all 3 rounds) is refused, nothing is pushed, and ONE ledger row says refused-rehearsal-churn') `
      ($rQ5 -eq 1 -and $script:rhSeen.Count -eq 3 -and -not (& $isAnc $q5 $head5 (& $tipOf)) -and $row5.Count -eq 1 -and $row5[0].outcome -eq 'refused-rehearsal-churn') `
      ("rc={0} rehearsals={1} rows={2} outcome={3}" -f $rQ5, $script:rhSeen.Count, $row5.Count, $(if ($row5.Count) { $row5[0].outcome } else { '' }))

    # ---- W0.1R: THE ONE ROW DESCRIBES THE WHOLE LOOP (2026-09-23) ----
    # Founding case: W0.1 was written before this loop landed, so its row could not say that a push took two rounds,
    # entered the lock twice, or what the in-lock check found; and a round-2 refusal wrote state=not-taken with nothing
    # to say the lock had been taken in round 1. Each case below reads the ONE row its push wrote.
    $churnRow = $(if ($row5.Count) { $row5[0] } else { $null })
    T ($kMF + '  the churn refusal is in-lock: its row says phase inlock, rounds 3, lock_takes 3, rehearsals 3 and inlock_check not-covered (the last take''s check)') `
      ($null -ne $churnRow -and [string]$churnRow.phase -ceq 'inlock' -and [int]$churnRow.rounds -eq 3 -and [int]$churnRow.lock_takes -eq 3 -and [int]$churnRow.rehearsals -eq 3 -and [string]$churnRow.inlock_check -ceq 'not-covered') `
      ("phase={0} rounds={1} takes={2} rehearsals={3} check={4}" -f $(if ($churnRow) { $churnRow.phase }), $(if ($churnRow) { $churnRow.rounds }), $(if ($churnRow) { $churnRow.lock_takes }), $(if ($churnRow) { $churnRow.rehearsals }), $(if ($churnRow) { $churnRow.inlock_check }))
    # AT the cap it lands, and the check word is the LAST take's: takes 1 and 2 found the rebased content uncovered, and
    # take 3 ran no in-lock rebase at all, so it says not-run. A word carried over from an earlier take would say not-covered.
    $capRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledRoot4)
    $capRows = @($capRaw)
    $capRow = $(if ($capRows.Count) { $capRows[$capRows.Count - 1] } else { $null })
    T ($kCT + '  the landing AT the cap writes one row: rounds 3, lock_takes 3, and inlock_check not-run, because its last take ran no check') `
      ($rQ4 -eq 0 -and $capRows.Count -eq 1 -and [string]$capRow.outcome -ceq 'landed-after-rebase' -and [int]$capRow.rounds -eq 3 -and [int]$capRow.lock_takes -eq 3 -and [string]$capRow.inlock_check -ceq 'not-run' -and $null -eq $capRow.phase) `
      ("rc={0} rows={1} outcome={2} rounds={3} takes={4} check={5} phase={6}" -f $rQ4, $capRows.Count, $(if ($capRow) { $capRow.outcome }), $(if ($capRow) { $capRow.rounds }), $(if ($capRow) { $capRow.lock_takes }), $(if ($capRow) { $capRow.inlock_check }), $(if ($capRow) { $capRow.phase }))

    # MUST FIRE: a push that hands the lock back ONCE and then lands. Round 1: origin changes chain.ps1 at the lock entry,
    # so the in-lock check does not cover the rebased content and the lock goes back. Round 2: origin moves again at the
    # lock entry, over a file no rehearsal covers, so the in-lock rebase keeps the key, the check says covered, and it lands.
    # THE WAITS ARE READ AT THEIR SOURCE: the lock-entry mover keeps each take's WaitedMs exactly as the lock reported it,
    # and the row's sum is checked against the takes rather than against itself.
    $hb = & $newPusher 'hb'
    $script:rhSeen.Clear(); $script:rhMoves = @(); $script:rhVerdicts = @{}; $script:lockMoves = @('chain.ps1', 'notes.txt')
    $ledHb = Join-Path $tmp 'ledhb'
    $rHb = Invoke-WithLockMover { Invoke-TcPushMain -Dir $hb -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $greenGate -RehearsalRunner $rhModel -RehearsalCheck $rhCheck -LedgerRoot $ledHb }
    $hbRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledHb)
    $hbRows = @($hbRaw)
    $hbRow = $(if ($hbRows.Count) { $hbRows[$hbRows.Count - 1] } else { $null })
    $hbWaits = $script:lockWaitsSeen.ToArray()
    $hbSum = 0.0
    foreach ($w in $hbWaits) { $hbSum += $w }
    $hbLast = $(if ($hbWaits.Count) { [long][math]::Round($hbWaits[$hbWaits.Count - 1]) } else { -1 })
    T ($kMF + '  a push that hands the lock back once and then lands writes ONE row: rounds 2, lock_takes 2, inlock_check covered, lock_wait_ms_total the sum of both takes'' waits, and waitMs the last take''s') `
      ($rHb -eq 0 -and $hbRows.Count -eq 1 -and [int]$hbRow.rounds -eq 2 -and [int]$hbRow.lock_takes -eq 2 -and [string]$hbRow.inlock_check -ceq 'covered' -and $hbWaits.Count -eq 2 -and `
        [long]$hbRow.lock_wait_ms_total -eq [long][math]::Round($hbSum) -and [long]$hbRow.waitMs -eq $hbLast -and [int]$hbRow.rehearsals -eq 2 -and [int]$hbRow.rehearsed -eq 2 -and `
        [string]$hbRow.outcome -ceq 'landed-after-rebase' -and (@($hbRow.rebase_phases) -join ',') -ceq 'inlock,inlock' -and $null -eq $hbRow.phase) `
      ("rc={0} rows={1} rounds={2} takes={3} check={4} waits={5} total={6} waitMs={7} rehearsals={8} rehearsed={9} outcome={10} phases={11}" -f $rHb, $hbRows.Count, $(if ($hbRow) { $hbRow.rounds }), $(if ($hbRow) { $hbRow.lock_takes }), $(if ($hbRow) { $hbRow.inlock_check }), (@($hbWaits) -join '/'), $(if ($hbRow) { $hbRow.lock_wait_ms_total }), $(if ($hbRow) { $hbRow.waitMs }), $(if ($hbRow) { $hbRow.rehearsals }), $(if ($hbRow) { $hbRow.rehearsed }), $(if ($hbRow) { $hbRow.outcome }), $(if ($hbRow) { @($hbRow.rebase_phases) -join ',' }))
    $hbReal = ${function:Enter-TcPushLock}
    T ($kCT + '  after that case the real Enter-TcPushLock is back, so no later case runs through the wrapper') `
      ([object]::ReferenceEquals($hbReal, $script:enterTcPushLockReal) -or [string]::Equals([string]$hbReal, [string]$script:enterTcPushLockReal, [StringComparison]::Ordinal)) 'the wrapper was left in place'

    # MUST FIRE: a refusal BEFORE the lock in round 2 counts the one take round 1 handed back. `state` keeps its old
    # meaning, what the last round got, so the row says not-taken; lock_takes is what says the lock was entered at all.
    # The round-2 gate takes at least 2 s, so catchup_sec has a LOWER bar that load can only help (never an upper one).
    $r2c = & $newPusher 'r2c'
    $script:rhSeen.Clear(); $script:rhMoves = @(); $script:rhVerdicts = @{}; $script:lockMoves = @('chain.ps1')
    $script:twoGateRuns = 0
    $twoGate = { param($d)
      $script:twoGateRuns++
      if ($script:twoGateRuns -ge 2) { Start-Sleep -Seconds 2; return [pscustomobject]@{ Ran = $true; Code = 1; Why = 'fixture: run-gates red in round 2' } }
      return [pscustomobject]@{ Ran = $true; Code = 0; Why = '' }
    }
    $ledR2c = Join-Path $tmp 'ledr2c'
    $rR2c = Invoke-WithLockMover { Invoke-TcPushMain -Dir $r2c -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $twoGate -RehearsalRunner $rhModel -RehearsalCheck $rhCheck -LedgerRoot $ledR2c }
    $r2cRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledR2c)
    $r2cRows = @($r2cRaw)
    $r2cRow = $(if ($r2cRows.Count) { $r2cRows[$r2cRows.Count - 1] } else { $null })
    T ($kMF + '  a round-2 refusal before the lock records lock_takes 1, phase catchup, rounds 2, outcome refused-gate-red and at least the 2 s of its round-2 gate in catchup_sec, beside state not-taken') `
      ($rR2c -eq 1 -and $script:twoGateRuns -eq 2 -and $r2cRows.Count -eq 1 -and [string]$r2cRow.outcome -ceq 'refused-gate-red' -and [int]$r2cRow.lock_takes -eq 1 -and `
        [string]$r2cRow.phase -ceq 'catchup' -and [int]$r2cRow.rounds -eq 2 -and [string]$r2cRow.state -ceq 'not-taken' -and [string]$r2cRow.inlock_check -ceq 'not-covered' -and [int]$r2cRow.catchup_sec -ge 2) `
      ("rc={0} gateRuns={1} rows={2} outcome={3} takes={4} phase={5} rounds={6} state={7} check={8} catchup={9}" -f $rR2c, $script:twoGateRuns, $r2cRows.Count, $(if ($r2cRow) { $r2cRow.outcome }), $(if ($r2cRow) { $r2cRow.lock_takes }), $(if ($r2cRow) { $r2cRow.phase }), $(if ($r2cRow) { $r2cRow.rounds }), $(if ($r2cRow) { $r2cRow.state }), $(if ($r2cRow) { $r2cRow.inlock_check }), $(if ($r2cRow) { $r2cRow.catchup_sec }))

    # ---- THE REVIEW OF W0.1R (2026-09-23): the catch-up sync, the check word and the row a throw leaves ----
    # $ckMoves is what the check pushes from the mover the moment it refuses to cover the rebased content, so the NEXT
    # round's own sync meets a move nothing else could have made.
    $script:ckMoves = @()
    $moveOriginText = { param([string]$File, [string]$Text)
      $null = & git -C $mover pull -q --rebase origin main 2>$null
      [IO.File]::WriteAllText((Join-Path $mover $File), $Text)
      $null = & git -C $mover add -- $File 2>$null; $null = & git -C $mover commit -q -m ('edit ' + $File) 2>$null
      $null = & git -C $mover push -q origin HEAD:main 2>$null
    }
    $ckMover = { param($d, $h, $r)
      $res = & $rhCheck $d $h $r
      if ($res.Code -ne 0 -and $script:ckMoves.Count) {
        $mv = $script:ckMoves[0]; $script:ckMoves = @($script:ckMoves | Select-Object -Skip 1)
        & $moveOriginText $mv.File $mv.Text
      }
      return $res
    }
    $tenLines = { param([string]$First, [string]$Tenth) ((@($First) + @(2..9 | ForEach-Object { 'l' + $_ }) + @($Tenth)) -join "`n") + "`n" }

    # MUST FIRE: a round-2 sync (after a hand-back) that REBASES. Round 1's lock entry moves chain.ps1, so the in-lock check
    # does not cover the rebased content, and while it says so origin moves again over a file nothing covers. Round 2's
    # fetch and rebase meet that move before the lock: rebase_phases must say inlock then CATCHUP, and preflight_sha must
    # still be the tip origin held when the push started, never the round-2 fetch.
    $cu = & $newPusher 'cu'
    $cuStartTip = & $tipOf
    $script:rhSeen.Clear(); $script:rhMoves = @(); $script:rhVerdicts = @{}; $script:lockMoves = @('chain.ps1')
    $script:ckMoves = @([pscustomobject]@{ File = 'notes.txt'; Text = ('catch-up ' + [guid]::NewGuid().ToString('N')) })
    $ledCu = Join-Path $tmp 'ledcu'
    $rCu = Invoke-WithLockMover { Invoke-TcPushMain -Dir $cu -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $greenGate -RehearsalRunner $rhModel -RehearsalCheck $ckMover -LedgerRoot $ledCu }
    $cuMoveTip = ([string](@(& git -C $mover rev-parse HEAD 2>$null))[0]).Trim()
    $cuRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledCu)
    $cuRows = @($cuRaw)
    $cuRow = $(if ($cuRows.Count) { $cuRows[$cuRows.Count - 1] } else { $null })
    T ($kMF + '  a round-2 sync that rebases is recorded as catchup (rebase_phases inlock,catchup), and preflight_sha stays the tip origin held at the start, not the round-2 fetch') `
      ($rCu -eq 0 -and $cuRows.Count -eq 1 -and [string]$cuRow.outcome -ceq 'landed-after-rebase' -and [int]$cuRow.rounds -eq 2 -and (@($cuRow.rebase_phases) -join ',') -ceq 'inlock,catchup' -and `
        [string]$cuRow.preflight_sha -ceq $cuStartTip -and [string]$cuRow.preflight_sha -cne $cuMoveTip -and $script:ckMoves.Count -eq 0) `
      ("rc={0} rows={1} outcome={2} rounds={3} phases={4} preflight={5} start={6} round2fetch={7} movesLeft={8}" -f $rCu, $cuRows.Count, $(if ($cuRow) { $cuRow.outcome }), $(if ($cuRow) { $cuRow.rounds }), $(if ($cuRow) { @($cuRow.rebase_phases) -join ',' }), $(if ($cuRow) { $cuRow.preflight_sha }), $cuStartTip, $cuMoveTip, $script:ckMoves.Count)

    # MUST FIRE: a round-2 sync that CONFLICTS. F.txt has ten lines; the branch edits line 10. Before the push starts
    # origin edits line 1 (X), so the pre-flight rebase is clean and preflight_sha is X. Round 1's lock entry moves
    # chain.ps1 (M1), the in-lock rebase takes it and the grant is M1; the check refuses to cover it and, while it does,
    # origin edits line 10 (Y). Round 2's rebase conflicts on F.txt against Y. The row must say phase catchup, name F.txt,
    # and name Y as what it conflicted against - the grant says M1, which that rebase never saw.
    $null = & git -C $mover pull -q --rebase origin main 2>$null
    [IO.File]::WriteAllText((Join-Path $mover 'F.txt'), (& $tenLines 'l1' 'l10'))
    $null = & git -C $mover add -- F.txt 2>$null; $null = & git -C $mover commit -q -m 'F ten lines' 2>$null
    $null = & git -C $mover push -q origin HEAD:main 2>$null
    $cc = New-Clone 'cc'
    [IO.File]::WriteAllText((Join-Path $cc 'F.txt'), (& $tenLines 'l1' 'mine10'))
    $null = & git -C $cc add -- F.txt 2>$null; $null = & git -C $cc commit -q -m 'cc edits line 10' 2>$null
    & $moveOriginText 'F.txt' (& $tenLines 'x1' 'l10')
    $ccX = & $tipOf
    $script:rhSeen.Clear(); $script:rhMoves = @(); $script:rhVerdicts = @{}; $script:lockMoves = @('chain.ps1')
    $script:ckMoves = @([pscustomobject]@{ File = 'F.txt'; Text = (& $tenLines 'x1' 'theirs10') })
    $ledCc = Join-Path $tmp 'ledcc'
    $rCc = Invoke-WithLockMover { Invoke-TcPushMain -Dir $cc -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $greenGate -RehearsalRunner $rhModel -RehearsalCheck $ckMover -LedgerRoot $ledCc }
    $ccY = & $tipOf
    $ccRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledCc)
    $ccRows = @($ccRaw)
    $ccRow = $(if ($ccRows.Count) { $ccRows[$ccRows.Count - 1] } else { $null })
    $ccFiles = @($(if ($ccRow) { $ccRow.conflict_files } else { @() }))
    $ccMid = (Test-Path -LiteralPath (Join-Path $cc '.git\rebase-merge')) -or (Test-Path -LiteralPath (Join-Path $cc '.git\rebase-apply'))
    T ($kMF + '  a round-2 conflict before the lock records phase catchup, rebase_phases preflight,inlock,catchup, the one conflicted file, and conflict_target the round-2 fetch (Y), not the grant (M1)') `
      ($rCc -eq 1 -and $ccRows.Count -eq 1 -and [string]$ccRow.outcome -ceq 'refused-rebase-conflict' -and [string]$ccRow.phase -ceq 'catchup' -and (@($ccRow.rebase_phases) -join ',') -ceq 'preflight,inlock,catchup' -and `
        $ccFiles.Count -eq 1 -and [string]$ccFiles[0] -ceq 'F.txt' -and [string]$ccRow.conflict_scope -ceq 'first-stop' -and [string]$ccRow.conflict_target -ceq $ccY -and [string]$ccRow.grant -cne $ccY -and `
        [string]$ccRow.preflight_sha -ceq $ccX -and [int]$ccRow.rounds -eq 1 -and [int]$ccRow.lock_takes -eq 1 -and [string]$ccRow.state -ceq 'not-taken' -and -not $ccMid) `
      ("rc={0} rows={1} outcome={2} phase={3} phases={4} files={5} scope={6} target={7} Y={8} grant={9} preflight={10} X={11} rounds={12} takes={13} state={14} midRebase={15}" -f $rCc, $ccRows.Count, $(if ($ccRow) { $ccRow.outcome }), $(if ($ccRow) { $ccRow.phase }), $(if ($ccRow) { @($ccRow.rebase_phases) -join ',' }), ($ccFiles -join ','), $(if ($ccRow) { $ccRow.conflict_scope }), $(if ($ccRow) { $ccRow.conflict_target }), $ccY, $(if ($ccRow) { $ccRow.grant }), $(if ($ccRow) { $ccRow.preflight_sha }), $ccX, $(if ($ccRow) { $ccRow.rounds }), $(if ($ccRow) { $ccRow.lock_takes }), $(if ($ccRow) { $ccRow.state }), $ccMid)

    # W2.2R step 4, MUST NOT FIRE: an in-lock check that DECIDED NOTHING (Code 3) twice no longer hands the lock back. It is
    # called exactly twice (once, then its one retry), and the push is attempted with inlock_check could-not-decide; the
    # hook's record check decides, as the day before. (Until W2.2R a Code 3 handed the lock back for a whole round.)
    $cn = & $newPusher 'cn'
    $script:rhSeen.Clear(); $script:rhMoves = @(); $script:rhVerdicts = @{}; $script:lockMoves = @('chain.ps1')
    $script:cnChecks = 0
    $cnCheck = { param($d, $h, $r) $script:cnChecks++; [pscustomobject]@{ Code = 3; Why = 'fixture: the verdict check printed no completion marker' } }
    $ledCn = Join-Path $tmp 'ledcn'
    $rCn = Invoke-WithLockMover { Invoke-TcPushMain -Dir $cn -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $greenGate -RehearsalRunner $rhModel -RehearsalCheck $cnCheck -LedgerRoot $ledCn }
    $cnRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledCn)
    $cnRows = @($cnRaw)
    $cnRow = $(if ($cnRows.Count) { $cnRows[$cnRows.Count - 1] } else { $null })
    T ($kMNF + '  an in-lock check that exits 3 twice does not hand the lock back: called exactly twice, one lock take, and the push is attempted with inlock_check could-not-decide') `
      ($rCn -eq 0 -and $script:cnChecks -eq 2 -and $cnRows.Count -eq 1 -and [string]$cnRow.inlock_check -ceq 'could-not-decide' -and [int]$cnRow.lock_takes -eq 1 -and [int]$cnRow.rounds -eq 1 -and ([string]$cnRow.outcome).StartsWith('landed')) `
      ("rc={0} checks={1} rows={2} check={3} takes={4} rounds={5} outcome={6}" -f $rCn, $script:cnChecks, $cnRows.Count, $(if ($cnRow) { $cnRow.inlock_check }), $(if ($cnRow) { $cnRow.lock_takes }), $(if ($cnRow) { $cnRow.rounds }), $(if ($cnRow) { $cnRow.outcome }))
    # CLEAN TWIN: a check that exits 3 once and then 0 lands with inlock_check covered, on one take.
    $c30 = & $newPusher 'c30'
    $script:rhSeen.Clear(); $script:rhMoves = @(); $script:rhVerdicts = @{}; $script:lockMoves = @('notes.txt')
    $script:c30Checks = 0
    $c30Check = { param($d, $h, $r) $script:c30Checks++; if ($script:c30Checks -eq 1) { return [pscustomobject]@{ Code = 3; Why = 'fixture: crashed once' } }; return [pscustomobject]@{ Code = 0; Why = 'covered' } }
    $ledC30 = Join-Path $tmp 'ledc30'
    $rC30 = Invoke-WithLockMover { Invoke-TcPushMain -Dir $c30 -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $greenGate -RehearsalRunner $rhModel -RehearsalCheck $c30Check -LedgerRoot $ledC30 }
    $c30Raw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledC30)
    $c30Rows = @($c30Raw)
    $c30Row = $(if ($c30Rows.Count) { $c30Rows[0] } else { $null })
    T ($kCT + '  a check that exits 3 once and then 0 lands with inlock_check covered, on one lock take, after exactly two checks') `
      ($rC30 -eq 0 -and $script:c30Checks -eq 2 -and $c30Rows.Count -eq 1 -and [string]$c30Row.inlock_check -ceq 'covered' -and [int]$c30Row.lock_takes -eq 1 -and ([string]$c30Row.outcome).StartsWith('landed')) `
      ("rc={0} checks={1} rows={2} check={3} takes={4} outcome={5}" -f $rC30, $script:c30Checks, $c30Rows.Count, $(if ($c30Row) { $c30Row.inlock_check }), $(if ($c30Row) { $c30Row.lock_takes }), $(if ($c30Row) { $c30Row.outcome }))

    # MUST FIRE: a throw OUTSIDE the lock writes the run's one row, and the throw still reaches the caller. Run under the
    # production preference (Stop), because this block runs under Continue and a throw there is not the same path.
    # THE PREFERENCE IS SET INSIDE A FUNCTION, never by an assignment in this block: grocery\test-native-stderr-eap.ps1
    # reads the preference lexically, and a Stop assigned here would make every later `2>$null` in the block a site.
    function Invoke-StUnderStop([scriptblock]$StBody) { $ErrorActionPreference = 'Stop'; & $StBody }
    $tw = & $newPusher 'tw'
    $throwGate = { param($d) throw 'fixture: the gate runner threw' }
    $ledTw = Join-Path $tmp 'ledtw'
    $twCaught = ''
    try { $null = Invoke-StUnderStop { Invoke-TcPushMain -Dir $tw -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $throwGate -RehearsalRunner $rhGreen -LedgerRoot $ledTw } }
    catch { $twCaught = [string]$_.Exception.Message }
    $twRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledTw)
    $twRows = @($twRaw)
    $twRow = $(if ($twRows.Count) { $twRows[0] } else { $null })
    T ($kMF + '  a leg runner that throws in round 1 writes ONE row (outcome unknown, state not-taken, no phase, lock_takes 0), and the throw still reaches the caller') `
      ($twCaught -match 'the gate runner threw' -and $twRows.Count -eq 1 -and [string]$twRow.outcome -ceq 'unknown' -and [string]$twRow.state -ceq 'not-taken' -and $null -eq $twRow.phase -and [int]$twRow.lock_takes -eq 0 -and [int]$twRow.rounds -eq 1) `
      ("caught={0} rows={1} outcome={2} state={3} phase={4} takes={5} rounds={6}" -f $twCaught, $twRows.Count, $(if ($twRow) { $twRow.outcome }), $(if ($twRow) { $twRow.state }), $(if ($twRow) { $twRow.phase }), $(if ($twRow) { $twRow.lock_takes }), $(if ($twRow) { $twRow.rounds }))
    # CLEAN TWIN: a throw INSIDE the lock still writes exactly one row (the in-lock finally writes it, and the guard must
    # not write a second), and the lock is handed back.
    $ti = & $newPusher 'ti'
    $script:rhSeen.Clear(); $script:rhMoves = @(); $script:rhVerdicts = @{}; $script:lockMoves = @('chain.ps1')
    $throwCheck = { param($d, $h, $r) throw 'fixture: the in-lock check threw' }
    $ledTi = Join-Path $tmp 'ledti'
    $tiCaught = ''
    try { $null = Invoke-WithLockMover { Invoke-StUnderStop { Invoke-TcPushMain -Dir $ti -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $greenGate -RehearsalRunner $rhModel -RehearsalCheck $throwCheck -LedgerRoot $ledTi } } }
    catch { $tiCaught = [string]$_.Exception.Message }
    $tiRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledTi)
    $tiRows = @($tiRaw)
    $tiRow = $(if ($tiRows.Count) { $tiRows[0] } else { $null })
    $tiFree = Enter-TcPushLock -Prefix $prefix -QueueRoot $qroot -WaitSec 5 -PollMs 50 -NoInherit
    T ($kCT + '  a throw inside the lock still writes exactly one row (outcome unknown, phase inlock), reaches the caller, and hands the lock back') `
      ($tiCaught -match 'the in-lock check threw' -and $tiRows.Count -eq 1 -and [string]$tiRow.outcome -ceq 'unknown' -and [string]$tiRow.phase -ceq 'inlock' -and $tiFree.Held) `
      ("caught={0} rows={1} outcome={2} phase={3} lockFree={4}" -f $tiCaught, $tiRows.Count, $(if ($tiRow) { $tiRow.outcome }), $(if ($tiRow) { $tiRow.phase }), $tiFree.Held)
    Exit-TcPushLock $tiFree

    # ---- W2.2R: THE CATCH-UP ROUND, OUTSIDE THE LOCK (2026-09-23) ----
    # Founding case: origin moves WHILE the legs run, and until W2.2R that move was found only by the fetch inside the
    # lock, where a rebase over a manifest script handed the lock back for a whole round. Every move below is made during
    # the legs, by a gate or rehearsal stub, so the catch-up fetch after them is what meets it.
    # CLEAN TWIN: origin moves once during round 1's legs over a non-chain file. It settles in round 2 outside the lock:
    # each stub is called twice, the rehearsal stub reports a reused verdict, and the in-lock sync rebases nothing.
    $ct1 = & $newPusher 'ct1'
    $script:rhSeen.Clear(); $script:rhMoves = @('notes.txt'); $script:rhVerdicts = @{}
    $script:ct1Gates = 0
    $ct1Gate = { param($d) $script:ct1Gates++; [pscustomobject]@{ Ran = $true; Code = 0; Why = '' } }
    $ledCt1 = Join-Path $tmp 'ledct1'
    $rCt1 = Invoke-TcPushMain -Dir $ct1 -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $ct1Gate -RehearsalRunner $rhModel -RehearsalCheck $rhCheck -LedgerRoot $ledCt1
    $ct1Raw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledCt1)
    $ct1Rows = @($ct1Raw)
    $ct1Row = $(if ($ct1Rows.Count) { $ct1Rows[0] } else { $null })
    T ($kCT + '  a move during round 1''s legs over a non-chain file settles in round 2 outside the lock: both stubs called twice, the second rehearsal a reuse, the in-lock sync rebases nothing, and it lands on one take') `
      ($rCt1 -eq 0 -and $script:ct1Gates -eq 2 -and $script:rhSeen.Count -eq 2 -and $ct1Rows.Count -eq 1 -and [int]$ct1Row.rounds -eq 2 -and [int]$ct1Row.rehearsed -eq 1 -and [int]$ct1Row.catchups -eq 1 -and `
        [int]$ct1Row.lock_takes -eq 1 -and (@($ct1Row.rebase_phases) -join ',') -ceq 'catchup' -and [string]$ct1Row.inlock_check -ceq 'not-run' -and [string]$ct1Row.outcome -ceq 'landed-after-rebase') `
      ("rc={0} gates={1} rehearsalCalls={2} rows={3} rounds={4} rehearsed={5} catchups={6} takes={7} phases={8} check={9} outcome={10}" -f $rCt1, $script:ct1Gates, $script:rhSeen.Count, $ct1Rows.Count, $(if ($ct1Row) { $ct1Row.rounds }), $(if ($ct1Row) { $ct1Row.rehearsed }), $(if ($ct1Row) { $ct1Row.catchups }), $(if ($ct1Row) { $ct1Row.lock_takes }), $(if ($ct1Row) { @($ct1Row.rebase_phases) -join ',' }), $(if ($ct1Row) { $ct1Row.inlock_check }), $(if ($ct1Row) { $ct1Row.outcome }))

    # MUST FIRE, AT THE BAR (3 catch-up rounds): a gate stub that moves origin (non-chain) on EVERY call. Round 1 and exactly
    # 3 catch-up rounds run their legs (4 gate calls); the 4th catch-up never starts; the push reaches the lock, whose sync
    # takes the last move, and lands. One past the bar would be a 5th gate call.
    $cb = & $newPusher 'cb'
    $script:rhSeen.Clear(); $script:rhMoves = @(); $script:rhVerdicts = @{}
    $script:cbGates = 0
    $cbGate = { param($d) $script:cbGates++; & $moveOrigin 'notes.txt'; [pscustomobject]@{ Ran = $true; Code = 0; Why = '' } }
    $ledCb = Join-Path $tmp 'ledcb'
    # At hand-back cap 0 (Invoke-WithLockMover's default), so the lock rebases the last move inside, as this bar is about the catch-up.
    $cbCap = Invoke-StCapture { Invoke-WithLockMover { Invoke-TcPushMain -Dir $cb -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $cbGate -RehearsalRunner $rhModel -RehearsalCheck $rhCheck -LedgerRoot $ledCb } }
    $cbRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledCb)
    $cbRows = @($cbRaw)
    $cbRow = $(if ($cbRows.Count) { $cbRows[0] } else { $null })
    T ($kMF + '  a remote that moves after every round''s legs stops after exactly 3 catch-up rounds (the bar): 4 leg sets, catchups 3, the 4th catch-up never starts, and the push reaches the lock and lands') `
      ($cbCap.Result -eq 0 -and $script:cbGates -eq 4 -and $cbRows.Count -eq 1 -and [int]$cbRow.rounds -eq 4 -and [int]$cbRow.catchups -eq 3 -and [int]$cbRow.catchup_fetches -eq 3 -and `
        (@($cbRow.rebase_phases) -join ',') -ceq 'catchup,catchup,catchup,inlock' -and [int]$cbRow.lock_takes -eq 1 -and $cbCap.Text -match 'did not settle in 3 rounds') `
      ("rc={0} gates={1} rows={2} rounds={3} catchups={4} fetches={5} phases={6} takes={7}" -f $cbCap.Result, $script:cbGates, $cbRows.Count, $(if ($cbRow) { $cbRow.rounds }), $(if ($cbRow) { $cbRow.catchups }), $(if ($cbRow) { $cbRow.catchup_fetches }), $(if ($cbRow) { @($cbRow.rebase_phases) -join ',' }), $(if ($cbRow) { $cbRow.lock_takes }))

    # MUST FIRE: a conflict the catch-up fetch finds is refused with phase catchup, before the lock: lock_takes 0, and a probe
    # from ANOTHER process finds the lock free the moment the push returns.
    $cq = New-Clone 'cq'
    [IO.File]::WriteAllText((Join-Path $cq 'clashQ.txt'), 'mine')
    $null = & git -C $cq add -- clashQ.txt 2>$null; $null = & git -C $cq commit -q -m 'cq mine' 2>$null
    $cqGate = { param($d) & $moveOriginText 'clashQ.txt' 'theirs'; [pscustomobject]@{ Ran = $true; Code = 0; Why = '' } }
    $ledCq = Join-Path $tmp 'ledcq'
    $rCq = Invoke-TcPushMain -Dir $cq -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $cqGate -RehearsalRunner $rhGreen -LedgerRoot $ledCq
    $cqProbe = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $probeScript -Name ($prefix + '0'))
    $cqRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledCq)
    $cqRows = @($cqRaw)
    $cqRow = $(if ($cqRows.Count) { $cqRows[0] } else { $null })
    T ($kMF + '  a conflict found by the catch-up fetch is refused with phase catchup before the lock: lock_takes 0, the conflicted file named, and another process finds the lock free') `
      ($rCq -eq 1 -and $cqRows.Count -eq 1 -and [string]$cqRow.outcome -ceq 'refused-rebase-conflict' -and [string]$cqRow.phase -ceq 'catchup' -and [int]$cqRow.lock_takes -eq 0 -and `
        (@($cqRow.conflict_files) -join ',') -ceq 'clashQ.txt' -and @($cqProbe | Where-Object { "$_".Trim() -eq 'FREE' }).Count -eq 1) `
      ("rc={0} rows={1} outcome={2} phase={3} takes={4} files={5} probe={6}" -f $rCq, $cqRows.Count, $(if ($cqRow) { $cqRow.outcome }), $(if ($cqRow) { $cqRow.phase }), $(if ($cqRow) { $cqRow.lock_takes }), $(if ($cqRow) { @($cqRow.conflict_files) -join ',' }), ($cqProbe -join ','))

    # MUST FIRE: a runner stub exiting 1 in round 2 (a catch-up round) refuses refused-gate-red, phase catchup.
    $g2 = & $newPusher 'g2'
    $script:g2Gates = 0
    $g2Gate = { param($d) $script:g2Gates++; if ($script:g2Gates -eq 1) { & $moveOrigin 'notes.txt'; return [pscustomobject]@{ Ran = $true; Code = 0; Why = '' } }; return [pscustomobject]@{ Ran = $true; Code = 1; Why = 'fixture: red in the catch-up round' } }
    $ledG2 = Join-Path $tmp 'ledg2'
    $rG2 = Invoke-TcPushMain -Dir $g2 -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $g2Gate -RehearsalRunner $rhGreen -LedgerRoot $ledG2
    $g2Raw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledG2)
    $g2Rows = @($g2Raw)
    $g2Row = $(if ($g2Rows.Count) { $g2Rows[0] } else { $null })
    T ($kMF + '  a runner stub exiting 1 in the catch-up round refuses refused-gate-red with phase catchup, and the lock is never taken') `
      ($rG2 -eq 1 -and $script:g2Gates -eq 2 -and $g2Rows.Count -eq 1 -and [string]$g2Row.outcome -ceq 'refused-gate-red' -and [string]$g2Row.phase -ceq 'catchup' -and [int]$g2Row.lock_takes -eq 0) `
      ("rc={0} gates={1} rows={2} outcome={3} phase={4} takes={5}" -f $rG2, $script:g2Gates, $g2Rows.Count, $(if ($g2Row) { $g2Row.outcome }), $(if ($g2Row) { $g2Row.phase }), $(if ($g2Row) { $g2Row.lock_takes }))

    # MUST FIRE (M17's case): three non-chain catch-up rounds do NOT spend the rehearsal budget. The rehearsal moves notes.txt
    # during rounds 1 to 3 (round 1 rehearses; rounds 2 to 4 reuse), so the catch-up cap is reached, and then the lock
    # entry moves chain.ps1: the in-lock check does not cover it, and because only ONE round rehearsed, the push still gets
    # its hand-back round and lands. Counting every round against the budget would refuse it as churn.
    $bud = & $newPusher 'bud'
    $script:rhSeen.Clear(); $script:rhMoves = @('notes.txt', 'notes.txt', 'notes.txt'); $script:rhVerdicts = @{}; $script:lockMoves = @('chain.ps1')
    $ledBud = Join-Path $tmp 'ledbud'
    $rBud = Invoke-WithLockMover { Invoke-TcPushMain -Dir $bud -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $greenGate -RehearsalRunner $rhModel -RehearsalCheck $rhCheck -LedgerRoot $ledBud }
    $budRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledBud)
    $budRows = @($budRaw)
    $budRow = $(if ($budRows.Count) { $budRows[0] } else { $null })
    T ($kMF + '  three non-chain catch-up rounds do not spend the rehearsal budget: a chain move found in the lock after them still gets its hand-back round, and the push lands with rehearsed 2') `
      ($rBud -eq 0 -and $budRows.Count -eq 1 -and [int]$budRow.catchups -eq 3 -and [int]$budRow.rehearsed -eq 2 -and [int]$budRow.lock_takes -eq 2 -and [int]$budRow.rounds -eq 5 -and ([string]$budRow.outcome).StartsWith('landed')) `
      ("rc={0} rows={1} catchups={2} rehearsed={3} takes={4} rounds={5} outcome={6}" -f $rBud, $budRows.Count, $(if ($budRow) { $budRow.catchups }), $(if ($budRow) { $budRow.rehearsed }), $(if ($budRow) { $budRow.lock_takes }), $(if ($budRow) { $budRow.rounds }), $(if ($budRow) { $budRow.outcome }))

    # MUST NOT FIRE: a stub exiting 3 in round 2 does not refuse. The push reaches the lock with degraded naming the leg,
    # and no third leg set runs.
    $g3 = & $newPusher 'g3'
    $script:g3Gates = 0
    $g3Gate = { param($d) $script:g3Gates++; if ($script:g3Gates -eq 1) { & $moveOrigin 'notes.txt'; return [pscustomobject]@{ Ran = $true; Code = 0; Why = '' } }; return [pscustomobject]@{ Ran = $true; Code = 3; Why = 'fixture: no gate worker slot' } }
    $ledG3 = Join-Path $tmp 'ledg3'
    $rG3 = Invoke-TcPushMain -Dir $g3 -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $g3Gate -RehearsalRunner $rhGreen -LedgerRoot $ledG3
    $g3Raw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledG3)
    $g3Rows = @($g3Raw)
    $g3Row = $(if ($g3Rows.Count) { $g3Rows[0] } else { $null })
    T ($kMNF + '  a stub exiting 3 in the catch-up round does not refuse: two leg sets, degraded names run-gates, and the push reaches the lock and lands') `
      ($rG3 -eq 0 -and $script:g3Gates -eq 2 -and $g3Rows.Count -eq 1 -and [string]$g3Row.degraded -ceq 'run-gates' -and [int]$g3Row.lock_takes -eq 1 -and [int]$g3Row.rounds -eq 2 -and ([string]$g3Row.outcome).StartsWith('landed')) `
      ("rc={0} gates={1} rows={2} degraded={3} takes={4} rounds={5} outcome={6}" -f $rG3, $script:g3Gates, $g3Rows.Count, $(if ($g3Row) { $g3Row.degraded }), $(if ($g3Row) { $g3Row.lock_takes }), $(if ($g3Row) { $g3Row.rounds }), $(if ($g3Row) { $g3Row.outcome }))

    # MUST NOT FIRE: a failed catch-up fetch does not refuse. The rehearsal stub points the clone's remote nowhere, so the
    # catch-up fetch fails; the lock-entry mover puts it back, and the fetch inside the lock lands the push.
    $cf = & $newPusher 'cf'
    $cfBreak = { param($d) $null = & git -C $d remote set-url origin (Join-Path $tmp 'no-such-remote') 2>$null; [pscustomobject]@{ Code = 0; Why = 'fixture: rehearsed-pass' } }
    $script:lockMoves = @({ $null = & git -C $cf remote set-url origin $origin 2>$null })
    $ledCf = Join-Path $tmp 'ledcf'
    $rCf = Invoke-WithLockMover { Invoke-TcPushMain -Dir $cf -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $greenGate -RehearsalRunner $cfBreak -LedgerRoot $ledCf }
    $cfRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledCf)
    $cfRows = @($cfRaw)
    $cfRow = $(if ($cfRows.Count) { $cfRows[0] } else { $null })
    T ($kMNF + '  a failed catch-up fetch does not refuse: the row says degraded fetch, one catch-up fetch was made, and the push lands through the fetch inside the lock') `
      ($rCf -eq 0 -and $cfRows.Count -eq 1 -and [string]$cfRow.degraded -ceq 'fetch' -and [int]$cfRow.catchup_fetches -eq 1 -and ([string]$cfRow.outcome).StartsWith('landed')) `
      ("rc={0} rows={1} degraded={2} fetches={3} outcome={4}" -f $rCf, $cfRows.Count, $(if ($cfRow) { $cfRow.degraded }), $(if ($cfRow) { $cfRow.catchup_fetches }), $(if ($cfRow) { $cfRow.outcome }))

    # MUST NOT FIRE: a remote that never moves gives exactly ONE catch-up fetch and no second leg run.
    $nm = & $newPusher 'nm'
    $script:nmGates = 0
    $nmGate = { param($d) $script:nmGates++; [pscustomobject]@{ Ran = $true; Code = 0; Why = '' } }
    $ledNm = Join-Path $tmp 'lednm'
    $rNm = Invoke-TcPushMain -Dir $nm -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $nmGate -RehearsalRunner $rhGreen -LedgerRoot $ledNm
    $nmRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledNm)
    $nmRows = @($nmRaw)
    $nmRow = $(if ($nmRows.Count) { $nmRows[0] } else { $null })
    T ($kMNF + '  a remote that never moves gives exactly one catch-up fetch, no catch-up round and no second leg run') `
      ($rNm -eq 0 -and $script:nmGates -eq 1 -and $nmRows.Count -eq 1 -and [int]$nmRow.catchup_fetches -eq 1 -and [int]$nmRow.catchups -eq 0 -and [int]$nmRow.rounds -eq 1) `
      ("rc={0} gates={1} rows={2} fetches={3} catchups={4} rounds={5}" -f $rNm, $script:nmGates, $nmRows.Count, $(if ($nmRow) { $nmRow.catchup_fetches }), $(if ($nmRow) { $nmRow.catchups }), $(if ($nmRow) { $nmRow.rounds }))

    # MUST FIRE (D11a, the catch-up road to the cap): the rehearsal moves chain.ps1 in rounds 1, 2 and 3, each a new verdict,
    # and the third move is met by a catch-up. With 3 rehearsals spent, the check says the rebased content is not covered,
    # so no fourth rehearsal starts: refused-rehearsal-churn with phase catchup, the lock never taken.
    $cc3 = & $newPusher 'cc3'
    $script:rhSeen.Clear(); $script:rhMoves = @('chain.ps1', 'chain.ps1', 'chain.ps1'); $script:rhVerdicts = @{}
    $ledCc3 = Join-Path $tmp 'ledcc3'
    $cc3Cap = Invoke-StCapture { Invoke-TcPushMain -Dir $cc3 -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $greenGate -RehearsalRunner $rhModel -RehearsalCheck $rhCheck -LedgerRoot $ledCc3 }
    $cc3Raw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledCc3)
    $cc3Rows = @($cc3Raw)
    $cc3Row = $(if ($cc3Rows.Count) { $cc3Rows[0] } else { $null })
    T ($kMF + '  after 3 rehearsals a catch-up that moves the key again is refused-rehearsal-churn before the lock (phase catchup, no fourth rehearsal, lock_takes 0), naming a manifest move') `
      ($cc3Cap.Result -eq 1 -and $script:rhSeen.Count -eq 3 -and $cc3Rows.Count -eq 1 -and [string]$cc3Row.outcome -ceq 'refused-rehearsal-churn' -and [string]$cc3Row.phase -ceq 'catchup' -and [int]$cc3Row.lock_takes -eq 0 -and [int]$cc3Row.rehearsed -eq 3 -and $cc3Cap.Text -match 'a manifest move') `
      ("rc={0} rehearsals={1} rows={2} outcome={3} phase={4} takes={5} rehearsed={6}" -f $cc3Cap.Result, $script:rhSeen.Count, $cc3Rows.Count, $(if ($cc3Row) { $cc3Row.outcome }), $(if ($cc3Row) { $cc3Row.phase }), $(if ($cc3Row) { $cc3Row.lock_takes }), $(if ($cc3Row) { $cc3Row.rehearsed }))

    # ---- W9.4: LOCK ONLY THE SWAP (2026-09-23) ----
    # Founding figure (the review's model, from the plan's holds): a rebased in-lock hold of about 128 s against a 25 s
    # replay, lock utilisation 0.64 at 18 landings an hour. Every move below is made by the lock-entry mover immediately
    # before a real take, at the PRODUCTION hand-back cap (-LmCap -1), with HEAD recorded at every take and release.
    # MUST FIRE: a remote that moves just before the in-lock fetch hands the lock back ONCE. No rebase ran while the lock
    # was held (HEAD at each release equals HEAD at that take), the rebase ran outside (rebase_phases handback), and it lands.
    $hk1 = & $newPusher 'hk1'
    $script:rhSeen.Clear(); $script:rhMoves = @(); $script:rhVerdicts = @{}; $script:lockMoves = @('notes.txt')
    $ledHk1 = Join-Path $tmp 'ledhbk1'
    $rHk1 = Invoke-WithLockMover { Invoke-TcPushMain -Dir $hk1 -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $greenGate -RehearsalRunner $rhModel -RehearsalCheck $rhCheck -LedgerRoot $ledHk1 } -LmCap -1 -LmDir $hk1
    $hk1Heads = $script:lockHeads.ToArray()
    $hk1Raw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledHk1)
    $hk1Rows = @($hk1Raw)
    $hk1Row = $(if ($hk1Rows.Count) { $hk1Rows[0] } else { $null })
    $hk1Held = ($hk1Heads.Count -eq 4 -and ($hk1Heads[0] -replace '^take ', '') -ceq ($hk1Heads[1] -replace '^release ', ''))
    T ($kMF + '  a remote that moves just before the in-lock fetch hands the lock back once: HEAD at the release equals HEAD at the take, the rebase ran outside (handback), hand_backs 1, lock_takes 2, and it lands') `
      ($rHk1 -eq 0 -and $hk1Held -and $hk1Rows.Count -eq 1 -and [int]$hk1Row.hand_backs -eq 1 -and [int]$hk1Row.lock_takes -eq 2 -and (@($hk1Row.rebase_phases) -join ',') -ceq 'handback' -and ([string]$hk1Row.outcome).StartsWith('landed') -and $hk1Row.handback_sec -is [int]) `
      ("rc={0} heads={1} rows={2} handBacks={3} takes={4} phases={5} outcome={6} hbSec={7}" -f $rHk1, ($hk1Heads -join '|'), $hk1Rows.Count, $(if ($hk1Row) { $hk1Row.hand_backs }), $(if ($hk1Row) { $hk1Row.lock_takes }), $(if ($hk1Row) { @($hk1Row.rebase_phases) -join ',' }), $(if ($hk1Row) { $hk1Row.outcome }), $(if ($hk1Row) { $hk1Row.handback_sec }))

    # MUST FIRE, AT THE BAR (3 hand-backs): a remote that moves before EVERY in-lock fetch hands back exactly 3 times; the
    # 4th take rebases INSIDE the lock (rebase_phases ends inlock) and the push lands. Never refused.
    # CLEAN TWIN: after the cap's in-lock rebase, the sibling's in-lock verdict check still runs.
    $hk3 = & $newPusher 'hk3'
    $script:rhSeen.Clear(); $script:rhMoves = @(); $script:rhVerdicts = @{}; $script:lockMoves = @('notes.txt', 'notes.txt', 'notes.txt', 'notes.txt')
    $ledHk3 = Join-Path $tmp 'ledhbk3'
    $rHk3 = Invoke-WithLockMover { Invoke-TcPushMain -Dir $hk3 -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $greenGate -RehearsalRunner $rhModel -RehearsalCheck $rhCheck -LedgerRoot $ledHk3 } -LmCap -1 -LmDir $hk3
    $hk3Heads = $script:lockHeads.ToArray()
    $hk3Raw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledHk3)
    $hk3Rows = @($hk3Raw)
    $hk3Row = $(if ($hk3Rows.Count) { $hk3Rows[0] } else { $null })
    $hk3HeldSame = $true
    for ($hi = 0; $hi -lt 6 -and ($hi + 1) -lt $hk3Heads.Count; $hi += 2) { if (($hk3Heads[$hi] -replace '^take ', '') -cne ($hk3Heads[$hi + 1] -replace '^release ', '')) { $hk3HeldSame = $false } }
    T ($kMF + '  a remote that moves before every in-lock fetch hands back exactly 3 times (the bar), with no rebase under any of those takes; the 4th take rebases inside the lock, rebase_phases ends inlock, and it lands') `
      ($rHk3 -eq 0 -and $hk3Rows.Count -eq 1 -and [int]$hk3Row.hand_backs -eq 3 -and [int]$hk3Row.lock_takes -eq 4 -and $hk3HeldSame -and $hk3Heads.Count -eq 8 -and `
        (@($hk3Row.rebase_phases) -join ',') -ceq 'handback,handback,handback,inlock' -and ([string]$hk3Row.outcome).StartsWith('landed')) `
      ("rc={0} rows={1} handBacks={2} takes={3} heldSame={4} heads={5} phases={6} outcome={7}" -f $rHk3, $hk3Rows.Count, $(if ($hk3Row) { $hk3Row.hand_backs }), $(if ($hk3Row) { $hk3Row.lock_takes }), $hk3HeldSame, $hk3Heads.Count, $(if ($hk3Row) { @($hk3Row.rebase_phases) -join ',' }), $(if ($hk3Row) { $hk3Row.outcome }))
    T ($kCT + '  after the cap''s in-lock rebase the in-lock verdict check still runs (inlock_check covered, not not-run)') `
      ($null -ne $hk3Row -and [string]$hk3Row.inlock_check -ceq 'covered') ("check={0}" -f $(if ($hk3Row) { $hk3Row.inlock_check }))

    # MUST FIRE: a hand-back rebase that CONFLICTS refuses with phase catchup, and at the moment it conflicts (the abort
    # seam runs the probe) another process finds the push lock FREE: the rebase ran outside it.
    $hkc = New-Clone 'hkc'
    [IO.File]::WriteAllText((Join-Path $hkc 'clashH.txt'), 'mine')
    $null = & git -C $hkc add -- clashH.txt 2>$null; $null = & git -C $hkc commit -q -m 'hkc mine' 2>$null
    $script:rhSeen.Clear(); $script:rhMoves = @(); $script:rhVerdicts = @{}; $script:lockMoves = @({ & $moveOriginText 'clashH.txt' 'theirs' })
    $script:hkcProbe = ''
    $script:TcPmRebaseAbort = { param($d) $script:hkcProbe = (@(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $probeScript -Name ($prefix + '0')) -join ','); Invoke-TcGit -Dir $d -Arguments @('rebase', '--abort') }
    $ledHkc = Join-Path $tmp 'ledhbkc'
    try {
      $rHkc = Invoke-WithLockMover { Invoke-TcPushMain -Dir $hkc -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $greenGate -RehearsalRunner $rhGreen -LedgerRoot $ledHkc } -LmCap -1
    } finally { $script:TcPmRebaseAbort = { param($d) Invoke-TcGit -Dir $d -Arguments @('rebase', '--abort') } }
    $hkcRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledHkc)
    $hkcRows = @($hkcRaw)
    $hkcRow = $(if ($hkcRows.Count) { $hkcRows[0] } else { $null })
    T ($kMF + '  a hand-back rebase that conflicts refuses with phase catchup (rebase_phases handback), and another process found the lock free at the moment it conflicted') `
      ($rHkc -eq 1 -and $hkcRows.Count -eq 1 -and [string]$hkcRow.outcome -ceq 'refused-rebase-conflict' -and [string]$hkcRow.phase -ceq 'catchup' -and (@($hkcRow.rebase_phases) -join ',') -ceq 'handback' -and `
        [int]$hkcRow.hand_backs -eq 1 -and [int]$hkcRow.lock_takes -eq 1 -and $script:hkcProbe -ceq 'FREE') `
      ("rc={0} rows={1} outcome={2} phase={3} phases={4} handBacks={5} takes={6} probe={7}" -f $rHkc, $hkcRows.Count, $(if ($hkcRow) { $hkcRow.outcome }), $(if ($hkcRow) { $hkcRow.phase }), $(if ($hkcRow) { @($hkcRow.rebase_phases) -join ',' }), $(if ($hkcRow) { $hkcRow.hand_backs }), $(if ($hkcRow) { $hkcRow.lock_takes }), $script:hkcProbe)

    # MUST NOT FIRE: an origin that has not moved at the in-lock fetch gives hand_backs 0 and one take (the unmoving
    # remote of the catch-up case above, read for W9.4's fields).
    T ($kMNF + '  an unmoved origin at the in-lock fetch gives hand_backs 0, handback_sec 0 and one lock take') `
      ($null -ne $nmRow -and [int]$nmRow.hand_backs -eq 0 -and [int]$nmRow.handback_sec -eq 0 -and [int]$nmRow.lock_takes -eq 1) `
      ("handBacks={0} hbSec={1} takes={2}" -f $(if ($nmRow) { $nmRow.hand_backs }), $(if ($nmRow) { $nmRow.handback_sec }), $(if ($nmRow) { $nmRow.lock_takes }))

    # ---- W3.2 WITH W3.4a STEP 3: THE PRE-FLIGHT'S BACKLOG AND INBOX COUNTS (2026-09-23), warn only ----
    # Founding figure: design/BACKLOG-course-findings.md overlapped in 12 of 19 recent rebase conflicts. The fixture origin
    # carries a backlog with one item, a findings file in the inbox and one UPDATE file; each clone makes one kind of
    # commit and runs a -DryRun, so origin never moves under the next. The validator is this repo's real one, pointed at
    # the clone's own backlog.
    $bkRel = 'design/BACKLOG-course-' + 'findings.md'
    $ibRel = 'design/backlog-inbox/lane-x-2026-09-23.md'
    $upRel = 'design/backlog-inbox/updates/lane-u-2026-09-23-100000.md'
    $null = & git -C $mover pull -q --rebase origin main 2>$null
    $null = New-Item -ItemType Directory -Force -ErrorAction Stop (Join-Path $mover 'design\backlog-inbox\updates')
    [IO.File]::WriteAllText((Join-Path $mover $bkRel), "# Backlog`n`n### I1 - a fixture item ``OPEN`` ``queue-1```n`nbody one`n")
    [IO.File]::WriteAllText((Join-Path $mover $ibRel), "# a lane's findings`n`nnothing yet`n")
    [IO.File]::WriteAllText((Join-Path $mover $upRel), "## UPDATE I1`n``DONE`` ``queue-1```nfinished`n")
    $null = & git -C $mover add -- $bkRel $ibRel $upRel 2>$null; $null = & git -C $mover commit -q -m 'backlog fixture' 2>$null
    $null = & git -C $mover push -q origin HEAD:main 2>$null
    $script:TcPmInboxValidatorScript = Join-Path $repo ('ops\merge-backlog-' + 'inbox.ps1')
    $script:bkRun = 0
    function Invoke-StBacklogCase([string]$Name, [scriptblock]$Change) {
      $script:bkRun++
      $bd = New-Clone $Name
      & $Change $bd
      $null = & git -C $bd commit -q -m ($Name + ' change') 2>$null
      $root = Join-Path $tmp ('ledbk' + $script:bkRun)
      $cap = Invoke-StCapture { Invoke-TcPushMain -Dir $bd -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $true -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $greenGate -RehearsalRunner $rhGreen -LedgerRoot $root }
      $raw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $root)
      $rows = @($raw)
      return [pscustomobject]@{ Rc = $cap.Result; Text = $cap.Text; Row = $(if ($rows.Count) { $rows[0] } else { $null }); Rows = $rows.Count }
    }
    $editBacklog = { param($d) Add-Content -LiteralPath (Join-Path $d $bkRel) -Value 'a direct edit' -Encoding ascii; $null = & git -C $d add -- $bkRel 2>$null }
    $warnBk = 'WARN - 1 commit\(s\) here edit design/BACKLOG-course-findings\.md directly'
    try {
      $b1 = Invoke-StBacklogCase 'bk1' $editBacklog
      T ($kMF + '  a commit that edits the backlog and touches no inbox file warns, with backlog_direct 1, and the push is not refused') `
        ($b1.Rc -eq 0 -and $b1.Rows -eq 1 -and [int]$b1.Row.backlog_direct -eq 1 -and $b1.Text -match $warnBk) ("rc={0} rows={1} direct={2} warned={3}" -f $b1.Rc, $b1.Rows, $(if ($b1.Row) { $b1.Row.backlog_direct }), ($b1.Text -match $warnBk))
      $b2 = Invoke-StBacklogCase 'bk2' { param($d) & $editBacklog $d; $null = & git -C $d rm -q -- $ibRel 2>$null }
      T ($kMNF + '  a commit that edits the backlog and deletes an inbox file (a merge) does not warn: backlog_direct 0') `
        ($b2.Rc -eq 0 -and $null -ne $b2.Row -and [int]$b2.Row.backlog_direct -eq 0 -and $b2.Text -notmatch 'edit design/BACKLOG') ("rc={0} direct={1}" -f $b2.Rc, $(if ($b2.Row) { $b2.Row.backlog_direct }))
      $b3 = Invoke-StBacklogCase 'bk3' { param($d) & $editBacklog $d; $null = New-Item -ItemType Directory -Force (Join-Path $d 'design\backlog-inbox\quarantine'); $null = & git -C $d mv -- $ibRel 'design/backlog-inbox/quarantine/lane-x-2026-09-23.md' 2>$null }
      T ($kMNF + '  a commit that edits the backlog and moves an inbox file into quarantine/ (a merge) does not warn: backlog_direct 0') `
        ($b3.Rc -eq 0 -and $null -ne $b3.Row -and [int]$b3.Row.backlog_direct -eq 0 -and $b3.Text -notmatch 'edit design/BACKLOG') ("rc={0} direct={1}" -f $b3.Rc, $(if ($b3.Row) { $b3.Row.backlog_direct }))
      $b4 = Invoke-StBacklogCase 'bk4' { param($d) [IO.File]::WriteAllText((Join-Path $d 'bk4.txt'), 'x'); $null = & git -C $d add -- bk4.txt 2>$null }
      T ($kMNF + '  a branch that does not touch the backlog does not warn: backlog_direct 0, inbox_invalid 0, inbox_updates_modified 0') `
        ($b4.Rc -eq 0 -and $null -ne $b4.Row -and [int]$b4.Row.backlog_direct -eq 0 -and [int]$b4.Row.inbox_invalid -eq 0 -and [int]$b4.Row.inbox_updates_modified -eq 0 -and $b4.Text -notmatch 'WARN') `
        ("rc={0} direct={1} invalid={2} modified={3}" -f $b4.Rc, $(if ($b4.Row) { $b4.Row.backlog_direct }), $(if ($b4.Row) { $b4.Row.inbox_invalid }), $(if ($b4.Row) { $b4.Row.inbox_updates_modified }))
      $b5 = Invoke-StBacklogCase 'bk5' { param($d) $f = Join-Path $d 'design\backlog-inbox\updates\lane-n-2026-09-23-110000.md'; [IO.File]::WriteAllText($f, "## UPDATE I999`n``DONE`` ``queue-1```nprogress on an item the backlog does not hold`n"); $null = & git -C $d add -- 'design/backlog-inbox/updates/lane-n-2026-09-23-110000.md' 2>$null }
      T ($kMF + '  an added UPDATE file naming a missing id warns that the merge would quarantine it, with inbox_invalid 1, and the push is not refused') `
        ($b5.Rc -eq 0 -and $null -ne $b5.Row -and [int]$b5.Row.inbox_invalid -eq 1 -and $b5.Text -match 'lane-n-2026-09-23-110000\.md would be QUARANTINED') ("rc={0} invalid={1}" -f $b5.Rc, $(if ($b5.Row) { $b5.Row.inbox_invalid }))
      T ($kMNF + '  (W3.4a step 3) a commit that ADDS a new updates/ file does not warn as a modification: inbox_updates_modified 0') `
        ($b5.Rc -eq 0 -and $null -ne $b5.Row -and [int]$b5.Row.inbox_updates_modified -eq 0 -and $b5.Text -notmatch 'MODIFY an existing file') ("modified={0}" -f $(if ($b5.Row) { $b5.Row.inbox_updates_modified }))
      $b6 = Invoke-StBacklogCase 'bk6' { param($d) Add-Content -LiteralPath (Join-Path $d $upRel) -Value 'more on the same day file' -Encoding ascii; $null = & git -C $d add -- $upRel 2>$null }
      T ($kMF + '  (W3.4a step 3) a commit that MODIFIES an existing updates/ file warns with a count of 1') `
        ($b6.Rc -eq 0 -and $null -ne $b6.Row -and [int]$b6.Row.inbox_updates_modified -eq 1 -and $b6.Text -match 'WARN - 1 commit\(s\) here MODIFY an existing file under design/backlog-inbox/updates/') ("rc={0} modified={1}" -f $b6.Rc, $(if ($b6.Row) { $b6.Row.inbox_updates_modified }))
    } finally { $script:TcPmInboxValidatorScript = '' }

    # ---- W4.1 STEP 7: A RE-READ ADDED AS A DOC LINE WARNS (2026-09-23), warn only ----
    # Founding case: row 40 of the case list conflicted on re-read lines in one MEASURE doc; the ledger row is the road
    # that union-merges. MUST FIRE: a commit adding a "Re-read at" line to a design doc warns, reread_doc_lines 1.
    $rrDoc = 'design/MEASURE-fixture-2026-09-23.md'
    $rrLine = 'Re-read at harness blob ' + ('a' * 40) + ' (ops/x.ps1): the conclusion holds'
    $rr1 = Invoke-StBacklogCase 'rr1' { param($d) $null = New-Item -ItemType Directory -Force (Join-Path $d 'design'); [IO.File]::WriteAllText((Join-Path $d $rrDoc), ("# A measurement`n`n" + $rrLine + "`n")); $null = & git -C $d add -- $rrDoc 2>$null }
    T ($kMF + '  a commit that adds a Re-read at line to a design doc warns to use ops\add-reread.ps1, with reread_doc_lines 1, and the push is not refused') `
      ($rr1.Rc -eq 0 -and $null -ne $rr1.Row -and [int]$rr1.Row.reread_doc_lines -eq 1 -and $rr1.Text -match 'WARN - 1 commit\(s\) here add a re-read as a doc line') ("rc={0} count={1}" -f $rr1.Rc, $(if ($rr1.Row) { $rr1.Row.reread_doc_lines }))
    # MUST NOT FIRE: the same line in a file outside design/*.md, and a design doc edit with no re-read line, count 0.
    $rr2 = Invoke-StBacklogCase 'rr2' { param($d) [IO.File]::WriteAllText((Join-Path $d 'notes-rr.md'), ($rrLine + "`n")); $null = New-Item -ItemType Directory -Force (Join-Path $d 'design'); [IO.File]::WriteAllText((Join-Path $d 'design\PLAN-fixture.md'), "# a plan`n`nno re-read here`n"); $null = & git -C $d add -- notes-rr.md design/PLAN-fixture.md 2>$null }
    T ($kMNF + '  a Re-read at line outside design/*.md, and a design doc edit with none, count 0 and do not warn') `
      ($rr2.Rc -eq 0 -and $null -ne $rr2.Row -and [int]$rr2.Row.reread_doc_lines -eq 0 -and $rr2.Text -notmatch 'add a re-read as a doc line') ("rc={0} count={1}" -f $rr2.Rc, $(if ($rr2.Row) { $rr2.Row.reread_doc_lines }))
    # MUST NOT FIRE (pure): a patch that REMOVES a re-read line, or carries one only in its +++ header, counts 0.
    $rrPure = Get-TcRereadDocLineCount -Lines @('TC-COMMIT 1111', ('--- a/design/MEASURE-x.md'), ('+++ b/design/MEASURE-x.md Re-read at'), ('-' + $rrLine), 'TC-COMMIT 2222', ('+' + 'an unrelated line'))
    $rrPure2 = Get-TcRereadDocLineCount -Lines @('TC-COMMIT 1111', ('+' + $rrLine), ('+' + $rrLine), 'TC-COMMIT 2222', ('+' + $rrLine))
    T ($kMNF + '  a removed re-read line or one only in the +++ header counts 0, and two added lines in one commit count that commit once (2 commits, 2)') `
      ($rrPure -eq 0 -and $rrPure2 -eq 2) ("removed={0} twoCommits={1}" -f $rrPure, $rrPure2)

    # ---- W9.1, PUSH-MAIN'S HALF: -Prepare AND early_hit (2026-09-23) ----
    # Founding figure (plan 16.1, SCRATCH): a rehearsal started at commit time, of HEAD rebased onto origin as it stood
    # then, would have been ready and valid before the push for 10 of 23 chain landings (43%, bar 30%). -Prepare is the
    # start; rehearse-chain -Early decides. The stub below stands in for rehearse-chain: it declares -Early, records how it
    # was called in a file beside itself, and prints the decision line and the completion line the real one prints. It is
    # started through the REAL detached starter (Win32_Process.Create), so the fixture proves the child outlives the call.
    $pr = & $newPusher 'pr'
    & $moveOrigin 'notes.txt'
    $prTip = & $tipOf
    $prHead0 = ([string](@(& git -C $pr rev-parse HEAD 2>$null))[0]).Trim()
    $prDir = Join-Path $tmp 'prstub'
    $null = New-Item -ItemType Directory -Force -ErrorAction Stop $prDir
    $prStub = Join-Path $prDir 'rehearse-stub.ps1'
    $prSaw = Join-Path $prDir 'saw.txt'
    [IO.File]::WriteAllText($prStub, ("param([switch]`$Early, [string]`$Onto, [string]`$Remote, [string]`$Branch)`n" +
      "[IO.File]::WriteAllText('" + $prSaw + "', ('early=' + [bool]`$Early + ' onto=' + `$Onto + ' remote=' + `$Remote + ' branch=' + `$Branch + ' cwd=' + (Get-Location).Path + ' gitdir=' + `$env:GIT_DIR))`n" +
      "Write-Output ('chain-rehearsal: EARLY - rehearsing 111111111 rebased onto ' + `$Onto.Substring(0, 9) + ' (key abcdef012345), in-flight file C:\fixture\early\x.json')`n" +
      "Write-Output 'CHAIN-REHEARSAL-EARLY-COMPLETE started=yes reason=rehearsed verdict=pass key=abcdef012345'`n" +
      "exit 0`n"))
    $prLogs = Join-Path $tmp 'prlogs'
    $gitDirWas = $env:GIT_DIR
    $env:GIT_DIR = Join-Path $tmp 'a-hook-git-dir-that-must-not-reach-the-child'
    try {
      $prCap = Invoke-StCapture { Invoke-TcPushMainPrepare -Dir $pr -Remote 'origin' -Branch 'main' -RehearseScript $prStub -LogRoot $prLogs }
    } finally { if ($null -eq $gitDirWas) { Remove-Item -LiteralPath Env:GIT_DIR -ErrorAction SilentlyContinue } else { $env:GIT_DIR = $gitDirWas } }
    $prSaid = $(if (Test-Path -LiteralPath $prSaw) { ([IO.File]::ReadAllText($prSaw)).Trim() } else { '<the stub never ran>' })
    $prHead1 = ([string](@(& git -C $pr rev-parse HEAD 2>$null))[0]).Trim()
    T ($kMF + '  -Prepare fetches and starts rehearse-chain -Early -Onto the fetched origin tip, detached and outside this process''s environment, prints the key and the in-flight file, and returns 0') `
      ($prCap.Result -eq 0 -and $prSaid -match ('^early=True onto=' + $prTip + ' remote=origin branch=main cwd=') -and $prSaid -match 'gitdir=$' -and $prCap.Text -match 'key abcdef012345, in-flight file C:\\fixture\\early\\x\.json') `
      ("rc={0} saw={1}" -f $prCap.Result, $prSaid)
    T ($kMNF + '  -Prepare moves no HEAD (origin had moved, and HEAD is where it was), runs no leg and writes no push row') `
      ($prHead0 -eq $prHead1 -and $prHead1 -ne $prTip) ("before={0} after={1} origin={2}" -f $prHead0, $prHead1, $prTip)
    # MUST NOT FIRE: a rehearse-chain with no -Early mode (a checkout older than W9.1) is not started at all.
    $prOld = Join-Path $prDir 'rehearse-old.ps1'
    $prOldSaw = Join-Path $prDir 'saw-old.txt'
    [IO.File]::WriteAllText($prOld, ("param([switch]`$ForPush)`n[IO.File]::WriteAllText('" + $prOldSaw + "', 'ran')`nexit 0`n"))
    $prOldCap = Invoke-StCapture { Invoke-TcPushMainPrepare -Dir $pr -Remote 'origin' -Branch 'main' -RehearseScript $prOld -LogRoot $prLogs }
    T ($kMNF + '  -Prepare in a checkout whose rehearse-chain has no -Early mode starts nothing, says so, and returns 0') `
      ($prOldCap.Result -eq 0 -and -not (Test-Path -LiteralPath $prOldSaw) -and $prOldCap.Text -match 'no -Early mode') ("rc={0} ran={1}" -f $prOldCap.Result, (Test-Path -LiteralPath $prOldSaw))
    # early_hit, pure over what the round-1 -ForPush child printed.
    $ehYes = Get-TcEarlyHit -ChainTouching $true -Lines @('chain-rehearsal: PASSED - 1 chain script(s) changed', 'CHAIN-REHEARSAL-CHECK-COMPLETE code=0 outcome=rehearsed-pass early=yes')
    $ehNow = Get-TcEarlyHit -ChainTouching $true -Lines @('chain-rehearsal: this push changes the chain and has no usable rehearsal verdict - rehearsing HEAD now, OUTSIDE the push lock.', 'CHAIN-REHEARSAL-CHECK-COMPLETE code=0 outcome=rehearsed-pass')
    $ehNc = Get-TcEarlyHit -ChainTouching $false -Lines @('CHAIN-REHEARSAL-CHECK-COMPLETE code=0 outcome=not-needed')
    $ehOld = Get-TcEarlyHit -ChainTouching $true -Lines @('chain-rehearsal: PASSED - 1 chain script(s) changed', 'CHAIN-REHEARSAL-CHECK-COMPLETE code=0 outcome=rehearsed-pass')
    T ($kMF + '  early_hit reads yes from an early=yes token, no for a push that rehearsed now, not-chain for a push touching no member, and unknown when a chain push''s child says neither') `
      ($ehYes -ceq 'yes' -and $ehNow -ceq 'no' -and $ehNc -ceq 'not-chain' -and $ehOld -ceq 'unknown') ("yes={0} now={1} notChain={2} old={3}" -f $ehYes, $ehNow, $ehNc, $ehOld)
    # CLEAN TWIN: the row of a push whose -ForPush found the early verdict carries early_hit yes, through the real row path.
    $eh = & $newPusher 'eh'
    $ehRunner = { param($d) [pscustomobject]@{ Code = 0; Why = 'fixture'; Ran = $true; Lines = [string[]]@('chain-rehearsal: PASSED - 1 chain script(s) changed and this content was rehearsed over data from 2026-09-23 (0 day(s) old)', 'CHAIN-REHEARSAL-CHECK-COMPLETE code=0 outcome=rehearsed-pass early=yes') } }
    $ledEh = Join-Path $tmp 'ledeh'
    $rEh = Invoke-TcPushMain -Dir $eh -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $greenGate -RehearsalRunner $ehRunner -LedgerRoot $ledEh
    $ehRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledEh)
    $ehRows = @($ehRaw)
    $ehRow = $(if ($ehRows.Count) { $ehRows[0] } else { $null })
    T ($kCT + '  a push whose -ForPush read the early verdict lands with early_hit yes and chain_touching true on its row, and its rehearsal leg is 0 s (a reuse)') `
      ($rEh -eq 0 -and $ehRows.Count -eq 1 -and [string]$ehRow.early_hit -ceq 'yes' -and $ehRow.chain_touching -eq $true -and [int]$ehRow.leg_sec.rh -eq 0) `
      ("rc={0} rows={1} early_hit={2} chain={3} rh={4}" -f $rEh, $ehRows.Count, $(if ($ehRow) { $ehRow.early_hit }), $(if ($ehRow) { $ehRow.chain_touching }), $(if ($ehRow) { $ehRow.leg_sec.rh }))

    # ---- W9.3: THE LEGS RUN BESIDE THE REHEARSAL (2026-09-23; W2.3's fixtures, widened) ----
    # Founding cost: a chain push runs run-gates, test-auditors and a 13 to 15 minute rehearsal one after another, and
    # a red leg used to wait for nothing but still paid its whole order. The rehearsal stub below is a REAL child process
    # started through Start-TcRehearsalChild (its -Script seam): it can rendezvous with a leg through
    # lib\concurrency-probe.ps1, wait on its stop file, and print the markers rehearse-chain prints.
    . (Join-Path $repo 'lib\concurrency-probe.ps1')
    $w3Dir = Join-Path $tmp 'w93'
    $null = New-Item -ItemType Directory -Force -ErrorAction Stop $w3Dir
    $w3Stub = Join-Path $w3Dir 'rehearse-stub.ps1'
    [IO.File]::WriteAllText($w3Stub, @'
param([switch]$ForPush, [string]$Remote, [string]$Branch, [string]$StackFile, [string]$StopFile, [string]$Mode = 'pass', [string]$Rendezvous = '', [string]$Started = '', [string]$Ended = '')
if ($Started) { [IO.File]::WriteAllText($Started, [string]$PID) }
try {
  if ($Rendezvous) { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Rendezvous | Out-Null }
  if ($Mode -eq 'stopwait') {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt 120) {
      if ($StopFile -and (Test-Path -LiteralPath $StopFile)) {
        Write-Output 'chain-rehearsal: STOPPED - fixture'
        Write-Output 'CHAIN-REHEARSAL-CHECK-COMPLETE code=3 outcome=could-not-rehearse blind=stopped'
        exit 3
      }
      Start-Sleep -Milliseconds 100
    }
    Write-Output 'CHAIN-REHEARSAL-CHECK-COMPLETE code=0 outcome=rehearsed-pass'
    exit 0
  }
  if ($Mode -eq 'fail') { Write-Output 'chain-rehearsal: REFUSED - fixture'; Write-Output 'CHAIN-REHEARSAL-CHECK-COMPLETE code=1 outcome=rehearsed-fail'; exit 1 }
  if ($Mode -eq 'badmarker') { Write-Output 'CHAIN-REHEARSAL-CHECK-COMPLETE code=1 outcome=rehearsed-fail'; exit 0 }
  Write-Output 'chain-rehearsal: no chain-manifest script changed in this push; no rehearsal needed'
  Write-Output 'CHAIN-REHEARSAL-CHECK-COMPLETE code=0 outcome=not-needed'
  exit 0
} finally { if ($Ended) { [IO.File]::WriteAllText($Ended, [string]$PID) } }
'@)
    # THE STARTER'S CONFIGURATION IS SCRIPT STATE, never a closure: a GetNewClosure scriptblock is bound to a dynamic
    # module that cannot see this script's functions. One configuration per case, set by New-StW3Starter.
    $script:w3Cfg = @{ Mode = 'pass'; Probes = @(); Started = ''; Ended = ''; Starts = 0 }
    function New-StW3Starter([string]$Mode, $Probes = @(), [string]$Started = '', [string]$Ended = '') {
      $script:w3Cfg = @{ Mode = $Mode; Probes = @($Probes); Started = $Started; Ended = $Ended; Starts = 0 }
      return {
        param($d, $stack, $stop)
        $script:w3Cfg.Starts++
        $xa = @('-Mode', $script:w3Cfg.Mode)
        if (@($script:w3Cfg.Probes).Count -ge $script:w3Cfg.Starts) { $xa += @('-Rendezvous', ('"' + @($script:w3Cfg.Probes)[$script:w3Cfg.Starts - 1].Script + '"')) }
        if ($script:w3Cfg.Started) { $xa += @('-Started', ('"' + $script:w3Cfg.Started + '"')) }
        if ($script:w3Cfg.Ended) { $xa += @('-Ended', ('"' + $script:w3Cfg.Ended + '"')) }
        Start-TcRehearsalChild -Dir $d -Remote 'origin' -Branch 'main' -StackFile $stack -StopFile $stop -Script $w3Stub -ExtraArgs $xa
      }
    }
    # MUST FIRE (M1, PLAN-faster-pushes-no-accuracy-loss-2026-09-25): a rehearsal leg's Sec is the CHILD'S own run time,
    # never the time push-main took to collect it. The child finishes, collection is held 5 s past its end (a LOWER bar,
    # which load can only lengthen), and Sec must fall short of the collection time by at least 4 s. The collector's
    # stopwatch, the founding bug, charges the whole hold and fails the second half.
    $m1Ended = Join-Path $w3Dir 'm1-ended.txt'
    $m1Sw = [Diagnostics.Stopwatch]::StartNew()
    $m1Job = Start-TcRehearsalChild -Dir $w3Dir -Remote 'origin' -Branch 'main' -Script $w3Stub -ExtraArgs @('-Mode', 'pass', '-Ended', ('"' + $m1Ended + '"'))
    while (-not (Test-Path -LiteralPath $m1Ended) -and $m1Sw.Elapsed.TotalSeconds -lt 120) { Start-Sleep -Milliseconds 100 }
    $m1Proc = $m1Job.Proc
    if ($m1Proc) { $null = $m1Proc.WaitForExit(120000) }
    $m1EndAt = $m1Sw.Elapsed.TotalSeconds
    Start-Sleep -Seconds 5
    $m1R = $m1Job.Wait()
    $m1Collect = $m1Sw.Elapsed.TotalSeconds
    T ($kMF + '  a rehearsal leg collected 5 s after its child exited records the child''s own run time, not the collection time (Sec at most the time to exit plus 1, and at least 4 s under the collection time)') `
      ((Test-Path -LiteralPath $m1Ended) -and [int]$m1R.Sec -le ([math]::Ceiling($m1EndAt) + 1) -and ($m1Collect - [int]$m1R.Sec) -ge 4) `
      ("sec={0} exited_by={1:N1} collected_at={2:N1}" -f $m1R.Sec, $m1EndAt, $m1Collect)
    # MUST FIRE, overlap: the run-gates stub and the rehearsal stub each wait, through lib\concurrency-probe.ps1, until
    # BOTH have started. A pipeline that starts the rehearsal after run-gates cannot satisfy it (the 120 s deadline is a
    # hang guard). CLEAN TWIN from the same run: all three legs pass and the lock is taken, with rh_stopped false.
    $ov = & $newPusher 'ov'
    $ovProbe = New-TcRendezvousProbe -Count 2 -DeadlineSec 120
    $ovGate = { param($d) $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ovProbe.Script; [pscustomobject]@{ Ran = $true; Code = 0; Why = '' } }
    $ledOv = Join-Path $tmp 'ledov'
    $rOv = Invoke-TcPushMain -Dir $ov -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $ovGate -RehearsalStarter (New-StW3Starter 'pass' @($ovProbe)) -LedgerRoot $ledOv
    $ovV = Get-TcRendezvousVerdict -Probe $ovProbe
    $ovRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledOv)
    $ovRows = @($ovRaw)
    $ovRow = $(if ($ovRows.Count) { $ovRows[0] } else { $null })
    T ($kMF + '  the rehearsal runs BESIDE run-gates: the run-gates stub and the rehearsal child were alive at the same instant (a rendezvous of 2, never a clock)') `
      ($ovV.Ok -and $rOv -eq 0) ("rc={0} {1}" -f $rOv, $ovV.Detail)
    T ($kCT + '  all three legs pass and the lock is taken: one take, landed, rh_stopped false, and one entry in rh_secs_list (0: the stub needed no rehearsal)') `
      ($rOv -eq 0 -and $ovRows.Count -eq 1 -and [int]$ovRow.lock_takes -eq 1 -and ([string]$ovRow.outcome).StartsWith('landed') -and $ovRow.rh_stopped -eq $false -and (@($ovRow.rh_secs_list) -join ',') -ceq '0') `
      ("rc={0} rows={1} takes={2} outcome={3} stopped={4} secs={5}" -f $rOv, $ovRows.Count, $(if ($ovRow) { $ovRow.lock_takes }), $(if ($ovRow) { $ovRow.outcome }), $(if ($ovRow) { $ovRow.rh_stopped }), $(if ($ovRow) { @($ovRow.rh_secs_list) -join ',' }))
    # MUST FIRE, the stop: a red run-gates stub (it waits until the rehearsal child has started, on its started file, so
    # the stop meets a running child) makes push-main write the stop file; the child, polling it, ends blind=stopped
    # and has EXITED before push-main returns. MUST NOT FIRE: that refusal is refused-gate-red, never refused-rehearsal.
    $sp1 = & $newPusher 'sp1'
    $spStarted = Join-Path $w3Dir 'sp-started.txt'; $spEnded = Join-Path $w3Dir 'sp-ended.txt'
    $spGate = { param($d) $w = [Diagnostics.Stopwatch]::StartNew(); while (-not (Test-Path -LiteralPath $spStarted) -and $w.Elapsed.TotalSeconds -lt 120) { Start-Sleep -Milliseconds 50 }; [pscustomobject]@{ Ran = $true; Code = 1; Why = 'fixture: run-gates red' } }
    $ledSp = Join-Path $tmp 'ledsp'
    $rSp = Invoke-TcPushMain -Dir $sp1 -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $spGate -RehearsalStarter (New-StW3Starter 'stopwait' @() $spStarted $spEnded) -LedgerRoot $ledSp
    $spExitedBefore = Test-Path -LiteralPath $spEnded
    $spRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledSp)
    $spRows = @($spRaw)
    $spRow = $(if ($spRows.Count) { $spRows[0] } else { $null })
    T ($kMF + '  a red run-gates writes the stop file, the rehearsal child ends blind=stopped (rh_stopped true) and has exited before push-main returns, and the push is refused') `
      ($rSp -eq 1 -and $spExitedBefore -and $spRows.Count -eq 1 -and $spRow.rh_stopped -eq $true) ("rc={0} childExitedFirst={1} rows={2} stopped={3}" -f $rSp, $spExitedBefore, $spRows.Count, $(if ($spRow) { $spRow.rh_stopped }))
    T ($kMNF + '  a stopped rehearsal''s refusal is refused-gate-red, never refused-rehearsal or refused-rehearsal-blind') `
      ($null -ne $spRow -and [string]$spRow.outcome -ceq 'refused-gate-red') ("outcome={0}" -f $(if ($spRow) { $spRow.outcome }))
    # CLEAN TWIN: a catch-up round uses the same start, run and wait sequence, so its legs overlap too. Round 1's gate
    # moves origin (a non-chain file) and rendezvouses on probe A; round 2's gate rendezvouses on probe B; the starter hands
    # each rehearsal child the probe of its own round.
    $cr2 = & $newPusher 'cr2'
    $crA = New-TcRendezvousProbe -Count 2 -DeadlineSec 120; $crB = New-TcRendezvousProbe -Count 2 -DeadlineSec 120
    $script:crGates = 0
    $crGate = { param($d) $script:crGates++; $pp = $(if ($script:crGates -eq 1) { $crA } else { $crB }); $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $pp.Script; if ($script:crGates -eq 1) { & $moveOrigin 'notes.txt' }; [pscustomobject]@{ Ran = $true; Code = 0; Why = '' } }
    $ledCr2 = Join-Path $tmp 'ledcr2'
    $rCr2 = Invoke-TcPushMain -Dir $cr2 -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $crGate -RehearsalStarter (New-StW3Starter 'pass' @($crA, $crB)) -LedgerRoot $ledCr2
    $crVA = Get-TcRendezvousVerdict -Probe $crA; $crVB = Get-TcRendezvousVerdict -Probe $crB
    $cr2Raw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledCr2)
    $cr2Rows = @($cr2Raw)
    $cr2Row = $(if ($cr2Rows.Count) { $cr2Rows[0] } else { $null })
    T ($kCT + '  a catch-up round overlaps its legs too: both rounds'' run-gates stubs met their rehearsal children, the row says rounds 2 and catchups 1, and it lands') `
      ($rCr2 -eq 0 -and $crVA.Ok -and $crVB.Ok -and $null -ne $cr2Row -and [int]$cr2Row.rounds -eq 2 -and [int]$cr2Row.catchups -eq 1) ("rc={0} A={1} B={2} rounds={3} catchups={4}" -f $rCr2, $crVA.Detail, $crVB.Detail, $(if ($cr2Row) { $cr2Row.rounds }), $(if ($cr2Row) { $cr2Row.catchups }))

    # W2.3's cases, through the DEFAULT legs (stub run-gates and stub test-auditors in the clone's own ops\, excluded
    # from git as the seeded paths are in the real repo) and the rehearsal stub child.
    $mkLegs = { param([string]$Name, [string]$TaBody)
      $cd = New-Clone $Name
      Add-Content -LiteralPath (Join-Path $cd '.git\info\exclude') -Value @('ops/') -Encoding ascii
      $null = New-Item -ItemType Directory -Force -ErrorAction Stop (Join-Path $cd 'ops')
      [IO.File]::WriteAllText((Join-Path $cd 'ops\run-gates.ps1'), "Write-Output 'RUN-GATES-COMPLETE pass=1 fail=0'`nexit 0`n")
      [IO.File]::WriteAllText((Join-Path $cd 'ops\prepush-test-auditors.ps1'), ("param([switch]`$RefsFromStdin)`n`$null = [Console]::In.ReadToEnd()`n" + $TaBody))
      [IO.File]::WriteAllText((Join-Path $cd ($Name + '.txt')), $Name)
      $null = & git -C $cd add -- ($Name + '.txt') 2>$null; $null = & git -C $cd commit -q -m $Name 2>$null
      return $cd
    }
    # MUST FIRE, overlap (W2.3's, kept): the test-auditors stub and the rehearsal child each wait on one rendezvous.
    $taProbe = New-TcRendezvousProbe -Count 2 -DeadlineSec 120
    $tov = & $mkLegs 'tov' ("`$null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File '" + $taProbe.Script + "'`nWrite-Output 'PREPUSH-TEST-AUDITORS-COMPLETE rc=0'`nexit 0`n")
    $rTov = Invoke-TcPushMain -Dir $tov -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $true -LockPrefix $prefix -LockQueueRoot $qroot -RehearsalStarter (New-StW3Starter 'pass' @($taProbe))
    $taV = Get-TcRendezvousVerdict -Probe $taProbe
    T ($kMF + '  test-auditors runs beside the rehearsal: the default legs'' test-auditors stub and the rehearsal child were alive at the same instant') ($taV.Ok -and $rTov -eq 0) ("rc={0} {1}" -f $rTov, $taV.Detail)
    # MUST FIRE: a red rehearsal refuses refused-rehearsal when both gate legs passed.
    $trr = & $mkLegs 'trr' "Write-Output 'PREPUSH-TEST-AUDITORS-COMPLETE rc=0'`nexit 0`n"
    $ledTrr = Join-Path $tmp 'ledtrr'
    $rTrr = Invoke-TcPushMain -Dir $trr -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -RehearsalStarter (New-StW3Starter 'fail') -LedgerRoot $ledTrr
    $trrRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledTrr)
    $trrRows = @($trrRaw)
    T ($kMF + '  a red rehearsal with both gate legs green refuses refused-rehearsal') ($rTrr -eq 1 -and $trrRows.Count -eq 1 -and [string]$trrRows[0].outcome -ceq 'refused-rehearsal' -and $trrRows[0].ta_rc -eq 0) ("rc={0} outcome={1}" -f $rTrr, $(if ($trrRows.Count) { $trrRows[0].outcome }))
    # MUST FIRE: a red test-auditors refuses refused-gate-red, and the rehearsal child (told to stop) has exited first.
    $tred = & $mkLegs 'tred' "Write-Output 'prepush-test-auditors: REFUSED - fixture'`nWrite-Output 'PREPUSH-TEST-AUDITORS-COMPLETE rc=1'`nexit 1`n"
    $tredEnded = Join-Path $w3Dir 'tred-ended.txt'
    $ledTred = Join-Path $tmp 'ledtred'
    $rTred = Invoke-TcPushMain -Dir $tred -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -RehearsalStarter (New-StW3Starter 'stopwait' @() '' $tredEnded) -LedgerRoot $ledTred
    $tredFirst = Test-Path -LiteralPath $tredEnded
    $tredRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledTred)
    $tredRows = @($tredRaw)
    T ($kMF + '  a red test-auditors refuses refused-gate-red, and the rehearsal child has exited, stopped, before push-main returns') `
      ($rTred -eq 1 -and $tredFirst -and $tredRows.Count -eq 1 -and [string]$tredRows[0].outcome -ceq 'refused-gate-red' -and $tredRows[0].rh_stopped -eq $true -and $tredRows[0].ta_rc -eq 1) `
      ("rc={0} childExitedFirst={1} outcome={2} stopped={3} ta_rc={4}" -f $rTred, $tredFirst, $(if ($tredRows.Count) { $tredRows[0].outcome }), $(if ($tredRows.Count) { $tredRows[0].rh_stopped }), $(if ($tredRows.Count) { $tredRows[0].ta_rc }))
    # MUST FIRE (pure, the Wait rule): an empty exit code with a code=0 marker is 3; a 0 with a code=1 marker is 3; a 0 with
    # no marker is 3; and a CLEAN TWIN 0 with code=0 is 0.
    $wx1 = Resolve-TcRehearsalExit -ExitCode $null -Lines @('CHAIN-REHEARSAL-CHECK-COMPLETE code=0 outcome=not-needed')
    $wx2 = Resolve-TcRehearsalExit -ExitCode 0 -Lines @('CHAIN-REHEARSAL-CHECK-COMPLETE code=1 outcome=rehearsed-fail')
    $wx3 = Resolve-TcRehearsalExit -ExitCode 0 -Lines @('chain-rehearsal: something')
    $wx4 = Resolve-TcRehearsalExit -ExitCode 0 -Lines @('CHAIN-REHEARSAL-CHECK-COMPLETE code=0 outcome=not-needed')
    T ($kMF + '  the wait scores 3 for an empty exit code under a code=0 marker, a 0 under a code=1 marker and a 0 with no marker, and 0 only when both agree on 0') `
      ($wx1.Code -eq 3 -and $wx2.Code -eq 3 -and $wx3.Code -eq 3 -and $wx4.Code -eq 0) ("empty={0} disagree={1} none={2} agree={3}" -f $wx1.Code, $wx2.Code, $wx3.Code, $wx4.Code)
    # MUST FIRE, through a real child: a stub that exits 0 with a code=1 marker is scored 3, so the push is refused blind.
    $tbm = & $mkLegs 'tbm' "Write-Output 'PREPUSH-TEST-AUDITORS-COMPLETE rc=0'`nexit 0`n"
    $ledTbm = Join-Path $tmp 'ledtbm'
    $rTbm = Invoke-TcPushMain -Dir $tbm -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -RehearsalStarter (New-StW3Starter 'badmarker') -LedgerRoot $ledTbm
    $tbmRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledTbm)
    $tbmRows = @($tbmRaw)
    T ($kMF + '  a rehearsal child that exits 0 under a code=1 marker is scored 3: refused-rehearsal-blind, never a pass') ($rTbm -eq 3 -and $tbmRows.Count -eq 1 -and [string]$tbmRows[0].outcome -ceq 'refused-rehearsal-blind') ("rc={0} outcome={1}" -f $rTbm, $(if ($tbmRows.Count) { $tbmRows[0].outcome }))
    # MUST NOT FIRE: a push that needs no rehearsal gets the child's not-needed answer, and test-auditors' result alone
    # decides: it lands, chain_touching false.
    $tnn = & $mkLegs 'tnn' "Write-Output 'PREPUSH-TEST-AUDITORS-COMPLETE rc=0'`nexit 0`n"
    $ledTnn = Join-Path $tmp 'ledtnn'
    $rTnn = Invoke-TcPushMain -Dir $tnn -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -RehearsalStarter (New-StW3Starter 'pass') -LedgerRoot $ledTnn
    $tnnRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledTnn)
    $tnnRows = @($tnnRaw)
    T ($kMNF + '  a push needing no rehearsal lands on the child''s not-needed answer and test-auditors'' pass: chain_touching false, rh_outcome not-needed') `
      ($rTnn -eq 0 -and $tnnRows.Count -eq 1 -and $tnnRows[0].chain_touching -eq $false -and [string]$tnnRows[0].rh_outcome -ceq 'not-needed' -and $tnnRows[0].ta_rc -eq 0) ("rc={0} chain={1} rh={2}" -f $rTnn, $(if ($tnnRows.Count) { $tnnRows[0].chain_touching }), $(if ($tnnRows.Count) { $tnnRows[0].rh_outcome }))
    Remove-TcRendezvousProbe

