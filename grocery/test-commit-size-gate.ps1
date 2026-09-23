<#
  test-commit-size-gate.ps1 - capture-run's daily commit refuses a commit that is not a day of prices.

  WHY (2026-08-22/23). $inputPaths stages 'grocery/out' as a WHOLE DIRECTORY, so .gitignore is the only
  thing between a new subdirectory and the repo - and .gitignore is an exclusion list, which means
  anything new is tracked BY DEFAULT. When the browser driver started writing persistent Chrome profiles
  under out\, d2a864c0 committed 4,388 files / 797,640 insertions in one go and nobody noticed for two
  days. It became HALF the pack - 191 MB of ~380 MB - and the contents were the seeded store sessions,
  i.e. cookies, on a remote.

  A sweep cannot be made safe by listing what to exclude, because the next tool to write under out\ has
  not been written yet. So the gate COUNTS instead, and this file proves it counts right.

  IT RUNS THE SHIPPED BLOCK, NEVER A COPY. The gate is extracted out of capture-run.ps1 by marker and
  executed against a THROWAWAY git repo in %TEMP% - never this one. A transcribed copy would pass forever
  while production drifted, which is the same reason test-cadence.ps1 pulls its helpers out of
  check-ad-cycles rather than restating them.

  Run:  powershell -NoProfile -File grocery	est-commit-size-gate.ps1
  Exit: 0 pass, 1 a case failed, 3 could not find the gate (BLIND - nothing was proven).
#>
# gate-inputs: grocery\test-commit-size-gate.ps1, grocery\capture-run.ps1, grocery\commit-size-lib.ps1, lib\git-repo-env.ps1, lib\git-blob-lib.ps1, lib\pipeline-commit.ps1, lib\ledger-lock.ps1, lib\atomic-write.ps1, lib\event-bus.ps1
$ErrorActionPreference='Continue'
# Every repo below is a temp repo: clear the repository environment first (2026-09-10; lib\git-repo-env.ps1).
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\git-repo-env.ps1'); Clear-TcGitRepoEnv
# THE LIBRARIES THE LIFTED BLOCKS CALL, loaded before any block runs (2026-09-23, plan W2.2): the size gate reads the
# carry ledger through commit-size-lib and lists additions through Invoke-GitCaptured, and a block run without them
# would take its degraded path and prove the wrong thing.
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\git-blob-lib.ps1')
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\pipeline-commit.ps1')
. (Join-Path $PSScriptRoot 'commit-size-lib.ps1')
# A STUB PAGER from the first case on: the gate pages a refusal, and every page any block composes is kept here.
$script:pages = New-Object System.Collections.Generic.List[string]
function Send-Alert { param($Subject, $Body) [void]$script:pages.Add([string]$Subject); $script:alertSubject = $Subject; $script:alertBody = $Body }
# What the lifted blocks read from capture-run's script scope. Every file a case writes is newer than this, so it is
# the run's OWN, and with no carry record every existing case is judged exactly as the gate judged before W2.2.
$script:RunStart = (Get-Date).AddMinutes(-10)
$today = '2026-09-23'; $Kind = 'daily'
$d = Join-Path $env:TEMP ('gate-' + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory $d -Force | Out-Null
# The carry ledger of every case lives inside that case's own .git, which git never lists and the repo's removal takes.
$env:TC_COMMIT_CARRY_PATH = Join-Path $d '.git\fx-carry.json'
Push-Location $d
try {
  & git init -q .; & git config user.email t@t; & git config user.name t
  New-Item -ItemType Directory (Join-Path $d 'grocery\out') -Force | Out-Null
  'seed' | Set-Content (Join-Path $d 'grocery\out\seed.txt'); & git add -A; & git commit -q -m seed

  # the block under test, lifted verbatim from capture-run.ps1 by marker
  # RESOLVED RELATIVE TO THIS FILE (2026-09-09). This was the absolute 'C:\Codex\ThriftyCrew\grocery\
  # capture-run.ps1', so a run in a WORKTREE lifted MAIN's block, tested it, and reported green about a
  # file it had not opened - a could-not-look laundered into a pass, in a fixture. Push-Location above
  # moves the process into %TEMP%, so a bare relative path would not do; $PSScriptRoot is what this file
  # knows about itself.
  $capRunPath = Join-Path $PSScriptRoot 'capture-run.ps1'
  if (-not (Test-Path $capRunPath)) { Write-Output ('BLIND: capture-run.ps1 not found beside this fixture (' + $capRunPath + ') - nothing was proven'); exit 3 }
  $src = [IO.File]::ReadAllText($capRunPath)
# EVERY FAILED LANE GOES THROUGH Add-FailedLane SINCE 2026-09-22 (plan-2026-09-22-10 item 2026-09-22-7c932a), so the
# block calls it: lift the SHIPPED function out of the same source, never a stub. It appends to the CALLER's $failed.
$crLaneAst = [System.Management.Automation.Language.Parser]::ParseInput($src, [ref]$null, [ref]$null)
foreach ($crLaneFn in @($crLaneAst.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and @('Add-FailedLane', 'Set-FailedLanePaged') -contains $a.Name }, $true))) { . ([scriptblock]::Create($crLaneFn.Extent.Text)) }
  $i = $src.IndexOf('  $newDirs = @()')
  $j = $src.IndexOf('  & git -C $repo diff --cached --quiet', $i)
  if ($i -lt 0 -or $j -lt 0) { Write-Output 'BLIND: could not find the gate markers in capture-run.ps1 - nothing was proven'; exit 3 }
  $gate = $src.Substring($i, $j - $i)
  $repo = $d; $paths = @('grocery/out'); $failed = @(); $ForceBigCommit = $false

  function Try-Gate([int]$n, [int]$kb, [bool]$force) {
    $script:failed = @(); $script:ForceBigCommit = $force
    & git -C $d reset -q --hard | Out-Null
    # reset --hard does NOT remove untracked files; without this each case inherited the last one's 400
    & git -C $d clean -qfd | Out-Null
    $blob = 'x' * ($kb * 1024)
    1..$n | ForEach-Object { $blob | Set-Content (Join-Path $d ("grocery\out\f$_.txt")) }
    & git -C $d add -A -- 'grocery/out' | Out-Null
    $repo = $d; $paths = @('grocery/out'); $failed = @(); $ForceBigCommit = $force
    . ([scriptblock]::Create($gate))
    $stagedAfter = @(& git -C $d diff --cached --name-only | Where-Object { $_ }).Count
    return [pscustomobject]@{ refused = $sizeGateRefused; staged = $stagedAfter; failed = ($failed -join ',') }
  }

  $n=0; $bad=0
  function T($m,$c,$g){ $script:n++; if($c){Write-Output "  ok    $m"} else {$script:bad++; Write-Output "  FAIL  $m -> $g"} }

  $r = Try-Gate 400 1 $false
  T 'MUST FIRE  400 new files is refused, and the index is reset' ($r.refused -and $r.staged -eq 0) ("refused=$($r.refused) staged=$($r.staged)")
  T 'MUST FIRE  the refusal is reported as a failed lane' ($r.failed -match 'commit-size-gate') $r.failed

  $r2 = Try-Gate 12 4 $false
  T 'CLEAN TWIN a normal day (12 files, 48 KB) passes untouched' ((-not $r2.refused) -and $r2.staged -eq 12) ("refused=$($r2.refused) staged=$($r2.staged)")

  $r3 = Try-Gate 40 1024 $false
  T 'MUST FIRE  few files but 40 MB is refused on SIZE, not count' ($r3.refused) ("refused=$($r3.refused)")

  $r4 = Try-Gate 400 1 $true
  T 'CLEAN TWIN -ForceBigCommit lets the same 400 files through' ((-not $r4.refused) -and $r4.staged -eq 400) ("refused=$($r4.refused) staged=$($r4.staged)")

  # THE ACTUAL MECHANISM: a SMALL new directory, well under both caps. This is browser-profiles on the
  # day it arrived, before it grew - the size gate alone would have waved it through.
  #
  # EACH OF THESE TWO GETS ITS OWN REPO. Reusing the one above let a previous case's leftover files
  # reach this one and the clean twin failed for a reason that had nothing to do with what it tests -
  # a fixture whose cases contaminate each other reports the wrong thing twice: once as a false red,
  # and once, later, as a green that was never earned.
  function New-Case([scriptblock]$Setup) {
    $c = Join-Path $env:TEMP ('gatecase-' + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory $c -Force | Out-Null
    & git -C $c init -q .
    & git -C $c config user.email t@t; & git -C $c config user.name t
    New-Item -ItemType Directory (Join-Path $c 'grocery/out') -Force | Out-Null
    'seed' | Set-Content (Join-Path $c 'grocery/out/seed.txt')
    & git -C $c add -A | Out-Null; & git -C $c commit -q -m seed | Out-Null
    & $Setup $c
    & git -C $c add -A -- 'grocery/out' | Out-Null
    $script:repo = $c; $script:paths = @('grocery/out'); $script:failed = @(); $script:ForceBigCommit = $false
    $repo = $c; $paths = @('grocery/out'); $failed = @(); $ForceBigCommit = $false
    . ([scriptblock]::Create($script:gateSrc))
    $staged = @(& git -C $c diff --cached --name-only | Where-Object { $_ }).Count
    Remove-Item $c -Recurse -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{ refused = $sizeGateRefused; staged = $staged }
  }
  $script:gateSrc = $gate

  $rNew = New-Case {
    param($c)
    New-Item -ItemType Directory (Join-Path $c 'grocery/out/browser-profiles/fareway') -Force | Out-Null
    1..8 | ForEach-Object { 'cookie' | Set-Content (Join-Path $c ('grocery/out/browser-profiles/fareway/c' + $_ + '.txt')) }
  }
  T 'MUST FIRE  a SMALL never-before-tracked directory is refused (8 files, 0 MB - under both caps)' `
    ($rNew.refused -and $rNew.staged -eq 0) ("refused=$($rNew.refused) staged=$($rNew.staged)")

  # CLEAN TWIN: new files inside an ALREADY-tracked directory are ordinary daily work.
  $rOld = New-Case {
    param($c)
    New-Item -ItemType Directory (Join-Path $c 'grocery/out/regular') -Force | Out-Null
    'd1' | Set-Content (Join-Path $c 'grocery/out/regular/day1.json')
    & git -C $c add -A | Out-Null; & git -C $c commit -q -m 'regular is now tracked' | Out-Null
    'd2' | Set-Content (Join-Path $c 'grocery/out/regular/day2.json')
  }
  T 'CLEAN TWIN a new file in an already-tracked directory is ordinary daily work' `
    (-not $rOld.refused) ("refused=$($rOld.refused)")

  # ---- THE DURABLE WAY THROUGH (2026-08-25) ------------------------------------------------------
  # out\cadence was a real feature that this gate refused correctly on its first morning and then went
  # on refusing, because the only exits it named were .gitignore (wrong - the stamps belong in git) and
  # -ForceBigCommit (impossible - Task Scheduler passes no switches). Both scheduled runs failed every
  # morning and the board stopped shipping. out-declared-families.json is the exit an unattended run
  # can take; these two cases prove it admits ONLY what is declared, and admits nothing when it breaks.
  $rDecl = New-Case {
    param($c)
    New-Item -ItemType Directory (Join-Path $c 'grocery/out/cadence') -Force | Out-Null
    1..10 | ForEach-Object { '2026-08-24T08:19:48.7480420-05:00' | Set-Content (Join-Path $c ('grocery/out/cadence/cadence-a' + $_ + '.txt')) }
    New-Item -ItemType Directory (Join-Path $c 'grocery') -Force | Out-Null
    '{ "families": [ { "dir": "cadence", "since": "2026-08-24", "writer": "grocery/check-ad-cycles.ps1", "why": "auditor stamps" } ] }' |
      Set-Content (Join-Path $c 'grocery/out-declared-families.json') -Encoding UTF8
  }
  T 'CLEAN TWIN a DECLARED new directory is admitted (this is the 08-24 cadence outage)' `
    ((-not $rDecl.refused) -and $rDecl.staged -gt 0) ("refused=$($rDecl.refused) staged=$($rDecl.staged)")

  # A manifest that cannot be parsed must not become a skeleton key. Truncated JSON is the realistic
  # shape - a half-written file from an interrupted edit - and the safe reading of it is "declares
  # nothing", never "declares everything".
  $rBad = New-Case {
    param($c)
    New-Item -ItemType Directory (Join-Path $c 'grocery/out/cadence') -Force | Out-Null
    1..10 | ForEach-Object { 'stamp' | Set-Content (Join-Path $c ('grocery/out/cadence/cadence-a' + $_ + '.txt')) }
    '{ "families": [ { "dir": "caden' | Set-Content (Join-Path $c 'grocery/out-declared-families.json') -Encoding UTF8
  }
  T 'MUST FIRE  an UNPARSEABLE manifest declares nothing and the new directory still refuses' `
    ($rBad.refused -and $rBad.staged -eq 0) ("refused=$($rBad.refused) staged=$($rBad.staged)")

  # And the undeclared directory in the SAME repo as a valid manifest still refuses - the list admits
  # by name, not by existing.
  $rOther = New-Case {
    param($c)
    New-Item -ItemType Directory (Join-Path $c 'grocery/out/browser-profiles/sams') -Force | Out-Null
    1..8 | ForEach-Object { 'cookie' | Set-Content (Join-Path $c ('grocery/out/browser-profiles/sams/c' + $_ + '.txt')) }
    '{ "families": [ { "dir": "cadence", "since": "2026-08-24", "writer": "x", "why": "y" } ] }' |
      Set-Content (Join-Path $c 'grocery/out-declared-families.json') -Encoding UTF8
  }
  T 'MUST FIRE  a valid manifest does not admit a directory it does not name' `
    ($rOther.refused -and $rOther.staged -eq 0) ("refused=$($rOther.refused) staged=$($rOther.staged)")

  # ---- A REFUSED RUN'S OWN FILES CARRY AT THE CAPS THEY MET (2026-09-23, design\PLAN-bot-checkout-self-heal-2026-09-23.md W2.2) ----
  # The 09-22/09-23 shape by COUNT, so no case writes megabytes: an earlier run wrote files and could not commit them,
  # and the next run's own files plus those went over 300. The gate block and the COMMIT-CARRY block are both lifted
  # from capture-run.ps1 and run against a throwaway repo; the carry ledger is that repo's own .git\fx-carry.json.
  $ci = $src.IndexOf('  # >>> COMMIT-CARRY BLOCK >>>')
  $cj = $src.IndexOf('  # <<< COMMIT-CARRY BLOCK <<<', [Math]::Max($ci, 0))
  if ($ci -lt 0 -or $cj -lt 0) { Write-Output 'BLIND: could not find the commit-carry markers in capture-run.ps1 - nothing was proven'; exit 3 }
  $carryBlock = $src.Substring($ci, $cj - $ci)
  function Run-Carry([int]$OldN, [int]$OwnN, [bool]$Recorded, [bool]$Committed) {
    $c = Join-Path $env:TEMP ('gatecarry-' + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory $c -Force | Out-Null
    & git -C $c init -q .
    & git -C $c config user.email t@t; & git -C $c config user.name t
    New-Item -ItemType Directory (Join-Path $c 'grocery/out') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $c 'grocery/out/seed.txt'), 'seed')
    & git -C $c add -A | Out-Null; & git -C $c commit -q -m seed | Out-Null
    $prevCarry = $env:TC_COMMIT_CARRY_PATH
    $env:TC_COMMIT_CARRY_PATH = Join-Path $c '.git\fx-carry.json'
    $prevStart = $script:RunStart
    $runStart = (Get-Date).AddMinutes(-10)
    # THE EARLIER RUN'S FILES: written 20 h before this run started, one byte each.
    $oldRows = @()
    foreach ($k in 1..([Math]::Max($OldN, 1))) {
      if ($k -gt $OldN) { break }
      $p = 'grocery/out/carried-' + $k + '.txt'
      [IO.File]::WriteAllText((Join-Path $c $p), 'c')
      (Get-Item (Join-Path $c $p)).LastWriteTime = $runStart.AddHours(-20)
      $oldRows += ,([pscustomobject]@{ path = $p; bytes = 1 })
    }
    if ($Recorded) { [void](Add-TcCommitCarry -Repo $c -Run 'fx-yesterday' -Kind 'daily' -Started $runStart.AddHours(-21) -Verdict 'within-caps' -Files $oldRows -Now (Get-Date).AddHours(-20)) }
    # THIS RUN'S OWN FILES, written after it started.
    foreach ($k in 1..([Math]::Max($OwnN, 1))) { if ($k -gt $OwnN) { break }; [IO.File]::WriteAllText((Join-Path $c ('grocery/out/own-' + $k + '.txt')), 'o') }
    & git -C $c add -A -- 'grocery/out' | Out-Null
    $script:RunStart = $runStart
    $repo = $c; $paths = @('grocery/out'); $failed = @(); $ForceBigCommit = $false
    $script:pages.Clear()
    $gOut = . ([scriptblock]::Create($script:gateSrc))
    $refused = [bool]$sizeGateRefused
    $staged = @(& git -C $c diff --cached --name-only | Where-Object { $_ }).Count
    $status = $script:CommitSizeStatus
    # THE COMMIT: refused by the gate, or (-Committed $false) refused by a hook after the gate admitted it.
    $botCommitted = ($Committed -and -not $refused)
    $cOut = . ([scriptblock]::Create($carryBlock))
    $rd = Read-TcCommitCarry -Repo $c
    $mine = @($rd.runs | Where-Object { [string]$_.run_id -like 'capture-run-daily-*' })
    $minePaths = @(); $mineVerdict = ''
    if ($mine.Count -eq 1) { $minePaths = @($mine[0].paths.Keys | Sort-Object); $mineVerdict = [string]$mine[0].verdict }
    $script:RunStart = $prevStart
    $env:TC_COMMIT_CARRY_PATH = $prevCarry
    Remove-Item $c -Recurse -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{
      refused = $refused; staged = $staged; failed = ($failed -join ','); status = $status; pages = @($script:pages)
      text = ((@($gOut) + @($cOut) | ForEach-Object { [string]$_ }) -join "`n"); runs = @($rd.runs).Count; mine = $mine.Count
      minePaths = $minePaths; mineVerdict = $mineVerdict
    }
  }
  $cr1 = Run-Carry 200 200 $true $true
  T 'MUST NOT FIRE a run carrying a recorded within-caps day (200 files) plus its own day (200 files) is admitted' `
    ((-not $cr1.refused) -and $cr1.staged -eq 400 -and ($cr1.text -match 'commit-size: carried +200 file\(s\)')) ("refused=$($cr1.refused) staged=$($cr1.staged) text=$($cr1.text)")
  T 'CLEAN TWIN the status record names the carried run, and a committed run records no carry of its own' `
    ((@($cr1.status.carried_runs) -join ',') -eq 'fx-yesterday' -and $cr1.mine -eq 0 -and $cr1.runs -eq 1) ("carried=$(@($cr1.status.carried_runs) -join ',') mine=$($cr1.mine) runs=$($cr1.runs)")
  $cr2 = Run-Carry 200 200 $false $true
  T 'MUST FIRE  the same carried files with NO record refuse at 400 files, which is the gate of the day before' `
    ($cr2.refused -and $cr2.staged -eq 0 -and ($cr2.failed -match 'commit-size-gate')) ("refused=$($cr2.refused) staged=$($cr2.staged) failed=$($cr2.failed)")
  T 'MUST FIRE  and the refusal pages once, by name' `
    ((@($cr2.pages | Where-Object { $_ -eq 'Grocery commit refused by size - 2026-09-23' }).Count -eq 1)) ("pages=$(@($cr2.pages) -join ' | ')")
  T 'MUST FIRE  a refused commit writes a carry record naming ONLY the 200 files written at or after RunStart, over-caps' `
    ($cr2.mine -eq 1 -and $cr2.minePaths.Count -eq 200 -and @($cr2.minePaths | Where-Object { $_ -like '*carried-*' }).Count -eq 0 -and $cr2.mineVerdict -eq 'over-caps') ("mine=$($cr2.mine) paths=$($cr2.minePaths.Count) verdict=$($cr2.mineVerdict)")
  $cr3 = Run-Carry 20 150 $false $false
  T 'MUST FIRE  a commit a hook refused after the gate admitted it records its own 150 files within-caps and none of the 20 older ones' `
    ((-not $cr3.refused) -and $cr3.mine -eq 1 -and $cr3.minePaths.Count -eq 150 -and @($cr3.minePaths | Where-Object { $_ -like '*carried-*' }).Count -eq 0 -and $cr3.mineVerdict -eq 'within-caps') ("refused=$($cr3.refused) mine=$($cr3.mine) paths=$($cr3.minePaths.Count) verdict=$($cr3.mineVerdict)")

  # ---- A GUARDS-BLOCKED DAY'S SERVED OUTPUTS ARE VOUCHED, NEVER COMMITTED (2026-09-23, plan W3.2 step 3) ----
  # The same lifted gate block, which ends with the pipeline-writes registration. The journal is the temp repo's own
  # .git\tc-pipeline-writes.json, so nothing here opens this checkout's journal.
  function Run-Built([bool]$Ship) {
    $c = Join-Path $env:TEMP ('gatebuilt-' + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory $c -Force | Out-Null
    & git -C $c init -q .
    & git -C $c config user.email t@t; & git -C $c config user.name t
    New-Item -ItemType Directory (Join-Path $c 'grocery/out') -Force | Out-Null
    New-Item -ItemType Directory (Join-Path $c 'public') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $c 'grocery/out/seed.txt'), 'seed')
    [IO.File]::WriteAllText((Join-Path $c 'public/board.json'), '{"v":1}')
    & git -C $c add -A | Out-Null; & git -C $c commit -q -m seed | Out-Null
    # THE CHAIN wrote today's board and one input; a blocked day stages the input only.
    [IO.File]::WriteAllText((Join-Path $c 'public/board.json'), '{"v":2}')
    [IO.File]::WriteAllText((Join-Path $c 'grocery/out/seed.txt'), 'seed2')
    $repo = $c; $failed = @(); $ForceBigCommit = $false
    $runDownstream = $true; $shipServed = $Ship; $servedPaths = @('public')
    $paths = @('grocery/out') + $(if ($Ship) { @('public') } else { @() })
    & git -C $c add -A -- $paths | Out-Null
    $bOut = . ([scriptblock]::Create($script:gateSrc))
    $j = Read-PipelineWriteJournal -JournalPath (Get-PipelineWriteJournalPath -Repo $c)
    $ck = Get-PipelineCheckoutKey -Repo $c
    $board = $j[($ck + '|public/board.json')]; $inp = $j[($ck + '|grocery/out/seed.txt')]
    Remove-Item $c -Recurse -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{
      board = $(if ($board) { [string]$board.lane + '/' + [string]$board.commit } else { 'none' })
      input = $(if ($inp) { [string]$inp.lane + '/' + [string]$inp.commit } else { 'none' })
      text = ((@($bOut) | ForEach-Object { [string]$_ }) -join "`n")
    }
  }
  $bt1 = Run-Built $false
  T 'MUST FIRE  a guards-blocked run vouches its built board as capture-run-daily-built, commit=False, and its input stays committable' `
    ($bt1.board -eq 'capture-run-daily-built/False' -and $bt1.input -eq 'capture-run-daily/True' -and ($bt1.text -match 'vouched 1 served file')) ("board=$($bt1.board) input=$($bt1.input)")
  $bt2 = Run-Built $true
  T 'CLEAN TWIN a run that ships records its served board as committable, and vouches nothing as built' `
    ($bt2.board -eq 'capture-run-daily/True' -and ($bt2.text -notmatch 'pipeline-writes: vouched'))("board=$($bt2.board) text=$($bt2.text)")

  # ---- SERVED-DIRTY: WHAT THE CHAIN WROTE vs WHAT IT STAGED (2026-09-02, queue 2026-09-02-reanch1) ----
  # Same harness, second shipped block. On 2026-09-02 the chain re-anchored 584 authored specs and rebuilt
  # three data files and three tool pages AFTER guards passed, and $servedPaths listed none of them, so 536
  # rewritten files sat dirty on a shared tree and were swept by hand in an unlabelled commit. The paths are
  # in the list now; this block is what notices the NEXT writer to join the chain. Lifted by marker and run
  # against a throwaway repo, never this one - a transcribed copy would pass forever while production drifted.
  $si = $src.IndexOf('# >>> SERVED-DIRTY BLOCK')
  $sj = $src.IndexOf('# <<< SERVED-DIRTY BLOCK', [Math]::Max($si, 0))
  if ($si -lt 0 -or $sj -lt 0) { Write-Output 'BLIND: could not find the served-dirty markers in capture-run.ps1 - nothing was proven'; exit 3 }
  $srv = $src.Substring($si, $sj - $si)
  # A STUB, SO THE ALERT PATH IS ACTUALLY EXERCISED. Without it the block's Send-Alert throws
  # CommandNotFound into its own catch and the alert BODY - which interpolates $servedDirty and $today -
  # would never be composed, so a typo in it would ship unproven.
  function Send-Alert { param($Subject, $Body) $script:alertSubject = $Subject; $script:alertBody = $Body }
  # $committed DEFAULTS TO $true (2026-09-09, queue 2026-09-09-f0b5f2), so the three cases below are
  # byte-for-byte the same assertions they were: they were all written for runs where the commit landed,
  # which is precisely why nothing caught the block reading $shipServed as if it implied that.
  function Run-Served([bool]$ship, [scriptblock]$Setup, [bool]$committed = $true) {
    $c = Join-Path $env:TEMP ('served-' + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory $c -Force | Out-Null
    & git -C $c init -q .
    & git -C $c config user.email t@t; & git -C $c config user.name t
    New-Item -ItemType Directory (Join-Path $c 'meal-prep/db/recipes') -Force | Out-Null
    New-Item -ItemType Directory (Join-Path $c 'public') -Force | Out-Null
    '{"slug":"x","cost_ps":1.23}' | Set-Content (Join-Path $c 'meal-prep/db/recipes/x.json')
    'board' | Set-Content (Join-Path $c 'public/board.json')
    & git -C $c add -A | Out-Null; & git -C $c commit -q -m seed | Out-Null
    & $Setup $c
    # the variables the block reads, exactly as capture-run holds them at that point
    $repo = $c; $today = '2026-09-02'; $shipServed = $ship
    # $botCommitted MUST be spelled exactly as capture-run holds it: the block is DOT-SOURCED into this
    # scope, so a rename here would silently feed the branch $null and the case would pass by taking the
    # wrong arm. That is the risk the plan names, and it is why this is asserted rather than assumed.
    $botCommitted = $committed
    $servedPaths = @('public', 'meal-prep/db/recipes')
    $failed = @()
    $script:alertSubject = ''; $script:alertBody = ''
    # DOT-SOURCE, not &: the block's `$failed += ...` must land in THIS scope or the assertion below
    # would read an unmodified copy and pass on a block that reported nothing.
    $out = . ([scriptblock]::Create($srv))
    Remove-Item $c -Recurse -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{ failed = ($failed -join ','); text = ((@($out) | ForEach-Object { [string]$_ }) -join "`n"); subject = $script:alertSubject; body = $script:alertBody }
  }

  # MUST-FIRE, built from the real 2026-09-02 shape: the chain rewrote a tracked spec and committed without it.
  $sDirty = Run-Served $true { param($c) '{"slug":"x","cost_ps":2.34}' | Set-Content (Join-Path $c 'meal-prep/db/recipes/x.json') }
  T 'MUST FIRE  a tracked served file left dirty after the commit is reported and fails the lane' `
    (($sDirty.failed -match 'served-dirty') -and ($sDirty.text -match 'served-dirty: 1 tracked served file')) ("failed=$($sDirty.failed) text=$($sDirty.text)")
  T 'MUST FIRE  and the alert body composes (it interpolates the count, the paths and the date)' `
    (($sDirty.subject -match '2026-09-02') -and ($sDirty.body -match 'meal-prep/db/recipes/x.json')) ("subject=$($sDirty.subject)")

  # CLEAN TWIN: the same repo with nothing left behind. Silent, and the lane is untouched.
  $sClean = Run-Served $true { param($c) }
  T 'CLEAN TWIN a clean tree after the commit stays silent and does not fail the lane' `
    (($sClean.failed -eq '') -and ($sClean.text -match 'served-dirty: none')) ("failed=$($sClean.failed) text=$($sClean.text)")

  # CLEAN TWIN: guards blocked, so the chain deliberately staged INPUTS only. Dirty served files are the
  # expected state there and must not page - or the block would cry wolf on every genuinely blocked board.
  $sBlocked = Run-Served $false { param($c) '{"slug":"x","cost_ps":2.34}' | Set-Content (Join-Path $c 'meal-prep/db/recipes/x.json') }
  T 'CLEAN TWIN a guards-blocked run (shipServed false) does not report served files as dirty' `
    (($sBlocked.failed -eq '') -and ($sBlocked.text -eq '')) ("failed=$($sBlocked.failed) text=$($sBlocked.text)")

  # ---- THE REFUSED COMMIT (2026-09-09, queue 2026-09-09-f0b5f2) -----------------------------------
  # FROZEN, built from what actually happened at 08:35 on 2026-09-09: guards PASSED, so $shipServed was
  # true and the chain intended to ship - and then the pre-commit hook REFUSED the commit over one file's
  # BOM. The three cases above all drive a run where the commit landed, so nothing in this estate had ever
  # asked what this block does when it did not. The answer was: it fired, named 16 files, and told the
  # operator to "Add the writer's output to $servedPaths" - a repair that would have been inert, because
  # every one of the 16 was already in Get-BotServedPaths. A confidently wrong diagnosis, on the morning
  # its reader was already dealing with a real hard fail.
  # Named once, because three of the lines below need it and one of them ends in a continuation backtick
  # where a trailing comment cannot go.
  $fxServedFile = 'meal-prep/db/recipes/x.json'   # reach-fixture-ok: a seed file inside a %TEMP% throwaway repo, never this repo's meal-prep
  $sRefused = Run-Served $true { param($c) '{"slug":"x","cost_ps":2.34}' | Set-Content (Join-Path $c $fxServedFile) } $false
  T 'MUST FIRE  a REFUSED commit is reported as a refusal, not as a $servedPaths gap' `
    ($sRefused.text -match 'because the commit was REFUSED') ("text=$($sRefused.text)")
  T 'MUST NOT FIRE and a refused commit adds NO served-dirty lane (commit-refused already is one)' `
    ($sRefused.failed -eq '') ("failed=$($sRefused.failed)")
  T 'MUST NOT FIRE and a refused commit composes NO alert (the old body asserted the commit went out)' `
    (($sRefused.subject -eq '') -and ($sRefused.body -eq '')) ("subject=$($sRefused.subject) body=$($sRefused.body)")

  # CLEAN TWIN, the adjacent behaviour this branch was most likely to break: the 2026-09-02 watcher must
  # still catch its founding bug when the commit DID land. Asserted again here, explicitly against the
  # committed flag, so a future edit that inverts the predicate cannot pass by only running the old cases.
  $sStillCatches = Run-Served $true { param($c) '{"slug":"x","cost_ps":9.99}' | Set-Content (Join-Path $c $fxServedFile) } $true
  T 'CLEAN TWIN with the commit LANDED the 2026-09-02 watcher still fails the lane and still alerts' `
    (($sStillCatches.failed -match 'served-dirty') -and ($sStillCatches.body -match [regex]::Escape($fxServedFile))) `
    ("failed=$($sStillCatches.failed) body=$($sStillCatches.body)")

  # ---- FOREIGN-HELD: a session's dirty owned file stays out of the bot commit (2026-09-10, queue 2026-09-10-3a9de4) ----
  # Third shipped block, same harness: lifted by marker out of capture-run.ps1 and run against a throwaway repo, never
  # this one. FROZEN from the founding case: a session stripped the BOM from a pipeline-written baseline under
  # grocery/out BEFORE the run started, the run never rewrote it, and the hook then refused the whole day's commit.
  $fi = $src.IndexOf('  # >>> FOREIGN-HELD BLOCK >>>')
  $fj = $src.IndexOf('  # <<< FOREIGN-HELD BLOCK <<<', [Math]::Max($fi, 0))
  if ($fi -lt 0 -or $fj -lt 0) { Write-Output 'BLIND: could not find the foreign-held markers in capture-run.ps1 - nothing was proven'; exit 3 }
  $fhBlock = $src.Substring($fi, $fj - $fi)
  . (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\git-blob-lib.ps1')
  . (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\pipeline-commit.ps1')
  function Run-ForeignHeld([bool]$rewriteForeign, [bool]$snapshotOk, [bool]$pipelineWrote = $false) {
    $c = Join-Path $env:TEMP ('fh-' + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory $c -Force | Out-Null
    & git -C $c init -q .
    & git -C $c config user.email t@t; & git -C $c config user.name t
    New-Item -ItemType Directory (Join-Path $c 'grocery/out') -Force | Out-Null
    $foreign = Join-Path $c 'grocery/out/json-readers-baseline.json'
    [IO.File]::WriteAllBytes($foreign, ([byte[]](0xEF, 0xBB, 0xBF) + [Text.Encoding]::UTF8.GetBytes('{"n":1}')))
    [IO.File]::WriteAllText((Join-Path $c 'grocery/out/run-output.txt'), 'v1')
    & git -C $c add -A | Out-Null; & git -C $c commit -q -m seed | Out-Null
    # THE SESSION'S EDIT, BEFORE THE RUN: the BOM stripped, and the file's mtime well before the run start.
    [IO.File]::WriteAllBytes($foreign, [Text.Encoding]::UTF8.GetBytes('{"n":1}'))
    (Get-Item $foreign).LastWriteTime = (Get-Date).AddHours(-2)
    # (2026-09-23, queue 2026-09-22-9bc4d2) THE PIPELINE'S OWN WRITE: a non-committing lane wrote these exact bytes and
    # recorded them in the write journal, in the temp repo's own .git, so the lifted block must stage them, not hold them.
    if ($pipelineWrote) { [void](Register-PipelineWrites -Repo $c -Lane 'fixture-watchdog-ff' -Since (Get-Date).AddHours(-3) -Paths @('grocery/out')) }
    $snap = if ($snapshotOk) { Get-DirtyOwnedSnapshot -Repo $c -Paths @('grocery/out') } else { [pscustomobject]@{ ok = $false; files = @(); why = 'fixture: git status failed' } }
    $runStart = (Get-Date).AddMinutes(-30)
    # THE RUN writes its own file; in the clean twin it also rewrites the foreign one.
    [IO.File]::WriteAllText((Join-Path $c 'grocery/out/run-output.txt'), 'v2')
    if ($rewriteForeign) { [IO.File]::WriteAllBytes($foreign, ([byte[]](0xEF, 0xBB, 0xBF) + [Text.Encoding]::UTF8.GetBytes('{"n":2}'))) }
    & git -C $c add -A -- 'grocery/out' | Out-Null
    $repo = $c
    $script:DirtyAtStart = $snap; $script:RunStart = $runStart
    $out = . ([scriptblock]::Create($fhBlock))
    $stagedNames = @(& git -C $c diff --cached --name-only | Where-Object { $_ })
    $dirtyNames = @(& git -C $c status --porcelain | Where-Object { $_ })
    Remove-Item $c -Recurse -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{ staged = ($stagedNames -join ','); dirty = ($dirtyNames -join ','); text = ((@($out) | ForEach-Object { [string]$_ }) -join "`n"); line = [string]$foreignHeldLine }
  }
  $fh1 = Run-ForeignHeld $false $true
  T 'MUST FIRE  a foreign dirty file the run never rewrote is unstaged and named, and the run''s own file stays staged' `
    (($fh1.staged -eq 'grocery/out/run-output.txt') -and ($fh1.text -match 'foreign-held: 1 tracked owned file.*json-readers-baseline\.json') -and ($fh1.dirty -match 'json-readers-baseline\.json')) ("staged=$($fh1.staged) text=$($fh1.text)")
  T 'MUST FIRE  and the line a still-refused commit''s alert carries names the same held file' `
    ($fh1.line -match 'foreign-held: 1 tracked owned file.*json-readers-baseline\.json') ("line=$($fh1.line)")
  $fh2 = Run-ForeignHeld $true $true
  T 'CLEAN TWIN a file dirty at start AND rewritten by the run is committed as the run''s own' `
    (($fh2.staged -match 'json-readers-baseline\.json') -and ($fh2.staged -match 'run-output\.txt')) ("staged=$($fh2.staged)")
  T 'MUST NOT FIRE a run that held nothing adds no held-list line to a refusal alert' ($fh2.line -eq '') ("line=$($fh2.line)")
  $fh4 = Run-ForeignHeld $false $true $true
  T 'MUST FIRE  a dirty-at-start file whose bytes a pipeline lane recorded is committed as the pipeline''s own, and named' `
    (($fh4.staged -match 'json-readers-baseline\.json') -and ($fh4.text -match 'pipeline-own: 1 file.*fixture-watchdog-ff') -and ($fh4.line -eq '')) ("staged=$($fh4.staged) text=$($fh4.text)")
  $fh3 = Run-ForeignHeld $false $false
  T 'MUST FIRE  a snapshot that could not be taken holds NOTHING back, and says so' `
    (($fh3.staged -match 'json-readers-baseline\.json') -and ($fh3.text -match 'holding NOTHING back')) ("staged=$($fh3.staged) text=$($fh3.text)")

  # ---- A DELETION PRESENT AT START IS HELD (2026-09-23, design\PLAN-bot-checkout-self-heal-2026-09-23.md W0.2 step 3) ----
  # FROZEN from 09-23: graph/provenance/2026-09-22.jsonl was deleted from the main checkout BEFORE a forced run, nothing
  # held the deletion, and the bot commit carried it to origin/main. Same harness: the shipped block, a throwaway repo,
  # and then a real `git commit` there, so the case reads the tree the commit made rather than the index alone.
  function Run-HeldDeletion([bool]$DeleteBeforeSnapshot) {
    $c = Join-Path $env:TEMP ('fhd-' + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory $c -Force | Out-Null
    & git -C $c init -q .
    & git -C $c config user.email t@t; & git -C $c config user.name t
    New-Item -ItemType Directory (Join-Path $c 'grocery/out') -Force | Out-Null
    $prov = 'grocery/out/prov-2026-09-22.jsonl'
    [IO.File]::WriteAllText((Join-Path $c $prov), '{"p":1}')
    [IO.File]::WriteAllText((Join-Path $c 'grocery/out/run-output.txt'), 'v1')
    & git -C $c add -A | Out-Null; & git -C $c commit -q -m seed | Out-Null
    if ($DeleteBeforeSnapshot) { Remove-Item -LiteralPath (Join-Path $c $prov) -Force }
    $snap = Get-DirtyOwnedSnapshot -Repo $c -Paths @('grocery/out')
    $script:RunStart = (Get-Date).AddMinutes(-30)
    # THE RUN: it writes its own file, and in the MUST NOT FIRE twin it deletes the provenance file itself.
    [IO.File]::WriteAllText((Join-Path $c 'grocery/out/run-output.txt'), 'v2')
    if (-not $DeleteBeforeSnapshot) { Remove-Item -LiteralPath (Join-Path $c $prov) -Force }
    & git -C $c add -A -- 'grocery/out' | Out-Null
    $repo = $c
    $script:DirtyAtStart = $snap; $script:HeldDeletions = @()
    $out = . ([scriptblock]::Create($fhBlock))
    & git -C $c commit -q -m 'bot' | Out-Null
    $inTree = @(& git -C $c ls-tree --name-only HEAD -- $prov | Where-Object { $_ }).Count
    $ownIn = [string](& git -C $c show HEAD:grocery/out/run-output.txt)
    Remove-Item $c -Recurse -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{ inTree = $inTree; own = $ownIn; text = ((@($out) | ForEach-Object { [string]$_ }) -join "`n"); held = @($script:HeldDeletions); kind = (@($snap.files | ForEach-Object { [string]$_.kind }) -join ',') }
  }
  $fhd1 = Run-HeldDeletion $true
  T 'MUST FIRE  an owned tracked file deleted BEFORE the run and still absent is not deleted by the commit, and the line names it' `
    ($fhd1.inTree -eq 1 -and $fhd1.own -eq 'v2' -and ($fhd1.text -match 'foreign-held: kept a deletion present at start: grocery/out/prov-2026-09-22\.jsonl') -and (@($fhd1.held) -join ',') -eq 'grocery/out/prov-2026-09-22.jsonl') ("inTree=$($fhd1.inTree) own=$($fhd1.own) held=$(@($fhd1.held) -join ',') text=$($fhd1.text)")
  $fhd2 = Run-HeldDeletion $false
  T 'MUST NOT FIRE an owned tracked file the run deleted DURING the run is committed as a deletion, as before, with no held line' `
    ($fhd2.inTree -eq 0 -and $fhd2.own -eq 'v2' -and ($fhd2.text -notmatch 'kept a deletion') -and @($fhd2.held).Count -eq 0) ("inTree=$($fhd2.inTree) own=$($fhd2.own) text=$($fhd2.text)")
  $script:RunStart = (Get-Date).AddMinutes(-10)

  # A LITERAL-CASE SUITE ASSERTS HOW MANY RAN (.claude\rules\ops-and-gates.md): every case above is a literal T line, so
  # a case lost to a thrown helper or a mis-lifted block is a shortfall here, never a smaller green total.
  $EXPECTED_CASES = 34
  $ranBefore = $n
  T ('CLEAN TWIN every literal case ran: ' + $ranBefore + ' of ' + $EXPECTED_CASES) ($ranBefore -eq $EXPECTED_CASES) ("ran=$ranBefore")
  Write-Output ''
  Write-Output ("SELFTEST: {0}/{1} pass" -f ($n-$bad), $n)
  Write-Output ("COMMIT-SIZE-GATE-COMPLETE cases={0} failed={1}" -f $n, $bad)
  if ($bad) { exit 1 }
} finally { Pop-Location; Remove-Item Env:\TC_COMMIT_CARRY_PATH -ErrorAction SilentlyContinue; Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
