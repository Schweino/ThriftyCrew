<#
  probe-push-throughput.ps1 - does serialising pushes make a verified commit land, and what does it cost?

  Run:        powershell -File ops\probe-push-throughput.ps1
  Self-test:  powershell -File ops\probe-push-throughput.ps1 -SelfTest

  A REPORT, NEVER A GATE. It starts real processes and takes real wall-clock time, so it is not in run-gates and no
  threshold here can refuse a push. Its self-test is hermetic and is.

  WHAT IT ANSWERS (design\PLAN-push-livelock-2026-09-11.md). On 2026-09-11 one session made 11 consecutive push
  attempts, passed run-gates on every one, and had every one rejected with "cannot lock ref 'refs/heads/main'".
  The claim under test is that this is the starvation of the longest transaction under optimistic concurrency
  control, and that a machine-wide push lock fixes it without costing throughput. Both arms run here, same writers,
  same work, same wall budget.

  THE GATE IS MODELLED AS SHARED CAPACITY, NOT AS A SLEEP, and that choice is the whole difference between a useful
  answer and a confounded one. A fixed sleep would say the lock COSTS throughput, because FIFO makes fast pushes
  wait behind the slow one. That answer would be arithmetically true and causally wrong, which is the exact defect
  design\EVAL-hunter-wall-clock-2026-09-04.md records and that .claude\rules\measurement.md exists over: a gate is
  not a sleep, it is W seconds of work sharing a machine-wide budget. One run alone gets the whole budget; four
  concurrent runs get a quarter each and take four times as long. That is measured, not assumed - run-gates ran 106 s
  quiet and 792 s under load that day, and per-run cost fell from 870 s to 698 s as the queue drained. So a writer
  here counts how many gates are running and sleeps W/(C/k).

  THE FIRST HARNESS WAS CONFOUNDED, and it is written down rather than quietly replaced (2026-09-11). Run 1 modelled
  the gate by QUEUEING for slots from a private lib\gate-slots.ps1 budget, each writer asking for the whole budget.
  Arrival-order ticketing then served them one at a time, so the gates never overlapped - the harness had serialised
  the very thing under test. The livelock still appeared (w1, w2 and w3 landed 0 of 11, 0 of 11 and 0 of 10), but
  the writer it starved was decided by ticket order rather than by transaction length, and the SLOW writer landed 11
  of 11. So acceptance bar A1 was NOT MET on a harness that could not have met it. Run 2 computes the width from a
  counter instead: every writer's gate overlaps every other's, and nothing queues. Both runs are reported in
  design\MEASURE-push-lock-2026-09-11.md.

  ITS LIMIT, stated: the width is sampled when a gate STARTS and is not re-integrated as other gates come and go, so
  a gate that begins alone keeps its full width even if three more start a second later. That makes the unlocked arm
  look slightly BETTER than it is, which is the direction that cannot flatter the change being tested.

  THE ARMS
    nolock - each writer fetches, rebases, gates, pushes. Whoever finishes first lands; the rest are rejected.
    lock   - each writer takes lib\push-lock.ps1 FIRST, then fetches, rebases, gates and pushes inside it.

  ONE ROW PER ATTEMPT PER ARM (backlog E24), written to <OutDir>\rows-<arm>-<writer>.jsonl. Every total this prints
  is derived from those rows, so a pair of aggregates can still be un-aggregated afterwards - and the acceptance bars
  in the plan are checked against the rows, not against a remembered number.

  SCOPE OF A CLEAN REPORT: this measures ORDERING and the capacity that ordering frees, against a LOCAL bare
  repository with a modelled gate. It says nothing about what the real gate costs, nothing about the network, and
  nothing about a pusher that does not call the lock. A pass here does not make the real hook fast; it says a
  verified push lands.
#>
[CmdletBinding()]
param(
  [switch]$SelfTest,
  [int]$Writers = 4,
  [double]$GateWorkSec = 12.0,
  [double]$SlowMultiplier = 3.0,
  [int]$BudgetSec = 180,
  [int]$Capacity = 4,
  [string]$OutDir = '',
  [string]$Arms = 'nolock,lock'
)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path -Parent $here
. (Join-Path $repo 'lib\git-repo-env.ps1')   # Clear-TcGitRepoEnv - this probe builds repositories with git init
. (Join-Path $repo 'lib\guard-contract.ps1') # Invoke-Guard / Exit-Guard - the <NAME>-COMPLETE marker contract

function New-TcProbeRow {
  <# One attempt. `Landed` is what the REMOTE did, never what the writer hoped: a push whose exit code was non-zero
     did not land, whatever its gate said. #>
  param([string]$Arm, [string]$Writer, [int]$Attempt, [bool]$Landed, [double]$GateSec, [double]$LockWaitSec,
        [int]$Width, [double]$WorkSec, [bool]$GateRan)
  return [pscustomobject]@{
    arm = $Arm; writer = $Writer; attempt = $Attempt; landed = [int]$Landed; gate_sec = [Math]::Round($GateSec, 3)
    lock_wait_sec = [Math]::Round($LockWaitSec, 3); width = $Width; gate_work_sec = [Math]::Round($WorkSec, 3)
    gate_ran = [int]$GateRan
  }
}

function Read-TcProbeRows {
  <# Every row an arm's writers wrote. Returns an ARRAY: assign, then wrap - never @(Get-Thing ...), which reads a
     comma-returned array as one element (.claude\rules\ops-and-gates.md). #>
  param([string]$Dir, [string]$Arm)
  $rows = [Collections.Generic.List[object]]::new()
  if (-not [IO.Directory]::Exists($Dir)) { return ,$rows.ToArray() }
  foreach ($f in [IO.Directory]::GetFiles($Dir, ('rows-' + $Arm + '-*.jsonl'))) {
    foreach ($line in [IO.File]::ReadAllLines($f)) {
      if (-not $line.Trim()) { continue }
      $rows.Add(($line | ConvertFrom-Json))
    }
  }
  return ,$rows.ToArray()
}

function Get-TcProbeSummary {
  <# Every figure the acceptance bars are read against, derived from the rows and from nothing else. Rates carry
     their DENOMINATOR (backlog E20): `landed 12 of 37` and never `32%`. WallSec is the arm's wall clock, passed in,
     because the rows record work and not the window they happened in. #>
  param([object[]]$Rows, [double]$WallSec)
  $rows = @($Rows)
  $byWriter = [Collections.Generic.List[object]]::new()
  foreach ($w in (@($rows | ForEach-Object { $_.writer }) | Sort-Object -Unique)) {
    $mine = @($rows | Where-Object { $_.writer -eq $w })
    $land = @($mine | Where-Object { $_.landed -eq 1 }).Count
    $byWriter.Add([pscustomobject]@{
      Writer = $w; Attempts = $mine.Count; Landings = $land
      AttemptsPerLanding = $(if ($land) { [Math]::Round($mine.Count / $land, 3) } else { [double]::PositiveInfinity })
      WastedGateSec = [Math]::Round((@($mine | Where-Object { $_.landed -eq 0 } | ForEach-Object { $_.gate_sec }) | Measure-Object -Sum).Sum, 1)
    })
  }
  $landed = @($rows | Where-Object { $_.landed -eq 1 })
  $wasted = (@($rows | Where-Object { $_.landed -eq 0 } | ForEach-Object { $_.gate_sec }) | Measure-Object -Sum).Sum
  return [pscustomobject]@{
    Attempts = $rows.Count
    Landings = $landed.Count
    WallSec = [Math]::Round($WallSec, 1)
    LandingsPerMin = $(if ($WallSec -gt 0) { [Math]::Round($landed.Count / ($WallSec / 60.0), 2) } else { 0.0 })
    WastedGateSec = [Math]::Round([double]$wasted, 1)
    GateSecPerLanding = $(if ($landed.Count) { [Math]::Round(((@($rows | ForEach-Object { $_.gate_sec }) | Measure-Object -Sum).Sum) / $landed.Count, 1) } else { [double]::PositiveInfinity })
    LandedWithoutGate = @($landed | Where-Object { $_.gate_ran -ne 1 }).Count
    ByWriter = $byWriter.ToArray()
  }
}

# THE WRITER. A separate process per writer, because what is under test is what concurrent PUSHES do to each other.
# Each attempt is the estate's real shape: rebase onto what the remote holds now, gate, push. The only difference
# between the arms is whether the push lock is held around all three.
$script:WriterBody = @'
$ErrorActionPreference = 'Continue'
. '__REPOLIB__\push-lock.ps1'
# HOW MANY GATES ARE RUNNING RIGHT NOW, kept by every writer in one counter under one mutex. An abandoned mutex is a
# killed writer, not a wedge, so it is taken rather than waited on.
$script:CountMutex = New-Object System.Threading.Mutex($false, '__CNTMX__')
function Step-GateCount([int]$Delta) {
  $got = $false
  try { $got = $script:CountMutex.WaitOne(30000) } catch [System.Threading.AbandonedMutexException] { $got = $true }
  try {
    $n = 0
    if ([IO.File]::Exists('__CNT__')) { $n = [int](([IO.File]::ReadAllText('__CNT__')).Trim()) }
    $n = [Math]::Max(0, $n + $Delta)
    [IO.File]::WriteAllText('__CNT__', [string]$n)
    return [Math]::Max(1, $n)
  } finally { if ($got) { try { $script:CountMutex.ReleaseMutex() } catch { } } }
}
$deadline = [DateTime]::UtcNow.AddSeconds(__BUDGET__)
$attempt = 0
$rows = [Collections.Generic.List[string]]::new()
while ([DateTime]::UtcNow -lt $deadline) {
  $attempt++
  $lk = $null; $waitSw = [Diagnostics.Stopwatch]::StartNew(); $lockWait = 0.0
  if (__USELOCK__) {
    $lk = Enter-TcPushLock -Prefix '__PUSHPFX__' -QueueRoot '__PUSHQ__' -WaitSec 120 -PollMs 50 -NoInherit
    $lockWait = $waitSw.Elapsed.TotalSeconds
    if (-not $lk.Held) { break }
  }
  try {
    # REBASE ONTO WHAT THE REMOTE HOLDS NOW, then build this attempt's commit on it. In the lock arm nobody else can
    # land while this runs, so the base cannot go stale; in the nolock arm it can and does.
    $null = & git fetch -q origin 2>$null
    $null = & git reset -q --hard origin/main 2>$null
    $mine = 'w-__NAME__-' + $attempt + '.txt'
    [IO.File]::WriteAllText((Join-Path '__CLONE__' $mine), [guid]::NewGuid().ToString())
    # NAMED, never a sweep: a writer stages the one file it owns (ops\audit-git-sweepers.ps1).
    $null = & git add -- $mine 2>$null
    $null = & git commit -q -m ("__NAME__ attempt " + $attempt) 2>$null
    # THE GATE: W seconds of work SHARED across however many gates are running. One run alone gets the whole budget
    # and finishes in W/C; k concurrent runs get C/k each. The width is computed from a counter every writer keeps,
    # rather than by queueing for slots - see the header's note on why the first harness was confounded.
    $gateSw = [Diagnostics.Stopwatch]::StartNew()
    $k = Step-GateCount 1
    $width = [Math]::Max(1.0, [Math]::Floor(__CAP__ / [double]$k))
    Start-Sleep -Milliseconds ([int](__WORK__ * 1000.0 / $width))
    $null = Step-GateCount -1
    $gateSec = $gateSw.Elapsed.TotalSeconds
    $null = & git push -q origin HEAD:main 2>$null
    $landed = ($LASTEXITCODE -eq 0)
    $rows.Add((@{ arm = '__ARM__'; writer = '__NAME__'; attempt = $attempt; landed = [int]$landed
                  gate_sec = [Math]::Round($gateSec, 3); lock_wait_sec = [Math]::Round($lockWait, 3)
                  width = $width; gate_work_sec = __WORK__; gate_ran = 1 } | ConvertTo-Json -Compress))
  } finally {
    if ($lk) { Exit-TcPushLock $lk }
  }
}
[IO.File]::WriteAllLines('__ROWS__', $rows)
'@

function Invoke-TcPushArm {
  <# Run one arm end to end and return its summary. Builds a fresh bare origin and a clone per writer, so neither arm
     can inherit the other's history. #>
  param([string]$Arm, [string]$Root, [string]$OutDir, [int]$Writers, [double]$Work, [double]$SlowMult,
        [int]$Budget, [int]$Capacity, [string]$Tag)
  $PS = (Get-Command powershell).Source
  # EVERY NAME IS PER RUN AND PER ARM: Local\ so a real push's Global\ lock is never touched, and a guid so two
  # copies of this probe cannot serve each other's queues.
  $pushPfx = 'Local\tc-probe-push-' + $Tag + '-' + $Arm + '-'
  $gatePfx = 'Local\tc-probe-gate-' + $Tag + '-' + $Arm + '-'
  $qroot = Join-Path $Root ('q-' + $Arm)
  $origin = Join-Path $Root ('origin-' + $Arm)
  # 'Continue' AS ITS OWN STATEMENT BEFORE THE NATIVE CALLS, restored in finally (.claude\rules\ops-and-gates.md).
  # Under this file's 'Stop' every `2>$null` on git would make its first stderr line a terminating throw, and a catch
  # around it would keep this alive while throwing git's answer away.
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
  Clear-TcGitRepoEnv
  $null = & git init -q --bare $origin 2>$null
  $seed = Join-Path $Root ('seed-' + $Arm)
  $null = & git init -q $seed 2>$null
  [IO.File]::WriteAllText((Join-Path $seed 'seed.txt'), 'seed')
  Push-Location $seed
  try {
    $null = & git add -- seed.txt 2>$null
    $null = & git -c user.name=Probe -c user.email=p@p commit -q -m seed 2>$null
    $null = & git branch -M main 2>$null
    $null = & git remote add origin $origin 2>$null
    $null = & git push -q origin main 2>$null
  } finally { Pop-Location }

  $procs = [Collections.Generic.List[object]]::new()
  $sw = [Diagnostics.Stopwatch]::StartNew()
  for ($i = 0; $i -lt $Writers; $i++) {
    $name = 'w' + $i
    $clone = Join-Path $Root ($Arm + '-' + $name)
    $null = & git clone -q $origin $clone 2>$null
    Push-Location $clone
    try {
      $null = & git config user.name Probe 2>$null
      $null = & git config user.email p@p 2>$null
    } finally { Pop-Location }
    # THE SLOW WRITER IS WRITER 0, the shape the report describes: a session whose gate is several times the others'.
    $w = $(if ($i -eq 0) { $Work * $SlowMult } else { $Work })
    $rowsFile = Join-Path $OutDir ('rows-' + $Arm + '-' + $name + '.jsonl')
    $body = $script:WriterBody
    $body = $body.Replace('__REPOLIB__', (Join-Path $repo 'lib')).Replace('__BUDGET__', [string]$Budget)
    $body = $body.Replace('__USELOCK__', $(if ($Arm -eq 'lock') { '$true' } else { '$false' }))
    $body = $body.Replace('__PUSHPFX__', $pushPfx).Replace('__PUSHQ__', $qroot)
    $body = $body.Replace('__GATEPFX__', $gatePfx).Replace('__GATEQ__', $qroot).Replace('__CAP__', [string]$Capacity)
    $body = $body.Replace('__CNTMX__', ($gatePfx + 'count')).Replace('__CNT__', (Join-Path $Root ('gates-' + $Arm + '.count')))
    $body = $body.Replace('__CLONE__', $clone).Replace('__NAME__', $name).Replace('__ARM__', $Arm)
    $body = $body.Replace('__WORK__', ([string]$w)).Replace('__ROWS__', $rowsFile)
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($body))
    $p = Start-Process -FilePath $PS -WorkingDirectory $clone -WindowStyle Hidden -PassThru `
      -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $enc)
    $procs.Add($p)
  }
  foreach ($p in $procs) { $null = $p.WaitForExit(($Budget + 300) * 1000); try { if (-not $p.HasExited) { $p.Kill() } } catch { } }
  $wall = $sw.Elapsed.TotalSeconds
  $rows = Read-TcProbeRows -Dir $OutDir -Arm $Arm
  return (Get-TcProbeSummary -Rows $rows -WallSec $wall)
  } finally { $ErrorActionPreference = $prevEap }
}

function Write-TcArmReport {
  param([string]$Arm, [object]$S)
  Write-Output ("  {0}: {1} attempt(s), {2} landed, over {3:N0}s wall - {4} landing(s)/min" -f $Arm, $S.Attempts, $S.Landings, $S.WallSec, $S.LandingsPerMin)
  Write-Output ("     gate-seconds burnt on attempts that did NOT land: {0:N0}; gate-seconds per landing: {1}" -f $S.WastedGateSec, $S.GateSecPerLanding)
  foreach ($w in $S.ByWriter) {
    $apl = $(if ([double]::IsInfinity($w.AttemptsPerLanding)) { 'never landed' } else { ('{0:N2} attempts/landing' -f $w.AttemptsPerLanding) })
    Write-Output ("     {0}{1}: landed {2} of {3} attempt(s) - {4}; {5:N0}s of gate thrown away" -f $w.Writer, $(if ($w.Writer -eq 'w0') { ' (the SLOW writer)' } else { '' }), $w.Landings, $w.Attempts, $apl, $w.WastedGateSec)
  }
}

if ($SelfTest) {
  $f = 0; $cases = 0
  $kMF = 'MUST' + ' FIRE'; $kMNF = 'MUST' + ' NOT FIRE'; $kCT = 'CLEAN' + ' TWIN'
  function T($m, $cond, $got) {
    $script:cases++
    if ($cond) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $got); $script:f++ }
  }
  # THE DERIVATION IS DRIVEN ON FIXED ROWS, hermetically. What the arms do is measured by running them, which is not
  # something a gate can afford; what the NUMBERS mean is arithmetic and is pinned here.
  $starved = @(
    (New-TcProbeRow -Arm 'nolock' -Writer 'w0' -Attempt 1 -Landed $false -GateSec 36 -LockWaitSec 0 -Width 1 -WorkSec 36 -GateRan $true),
    (New-TcProbeRow -Arm 'nolock' -Writer 'w0' -Attempt 2 -Landed $false -GateSec 36 -LockWaitSec 0 -Width 1 -WorkSec 36 -GateRan $true),
    (New-TcProbeRow -Arm 'nolock' -Writer 'w1' -Attempt 1 -Landed $true  -GateSec 12 -LockWaitSec 0 -Width 1 -WorkSec 12 -GateRan $true)
  )
  $s = Get-TcProbeSummary -Rows $starved -WallSec 60
  $w0 = @($s.ByWriter | Where-Object { $_.Writer -eq 'w0' })[0]
  T ($kMF + '  a writer that never lands reports never landed, not a division that quietly reads as a rate') `
    ([double]::IsInfinity($w0.AttemptsPerLanding) -and $w0.Landings -eq 0 -and $w0.Attempts -eq 2) ("apl={0} landings={1}" -f $w0.AttemptsPerLanding, $w0.Landings)
  T ($kMF + '  gate-seconds burnt on attempts that did not land are counted, and are the losing attempts only') `
    ($s.WastedGateSec -eq 72 -and $w0.WastedGateSec -eq 72) ("wasted={0} w0={1}" -f $s.WastedGateSec, $w0.WastedGateSec)
  T ($kCT + '  the writer that did land reads 1.00 attempts per landing and threw nothing away') `
    ((@($s.ByWriter | Where-Object { $_.Writer -eq 'w1' })[0].AttemptsPerLanding -eq 1.0) -and (@($s.ByWriter | Where-Object { $_.Writer -eq 'w1' })[0].WastedGateSec -eq 0)) 'w1 did not read 1.00/0'
  T ($kCT + '  the rate carries its denominator: landings and attempts are both reported') `
    ($s.Attempts -eq 3 -and $s.Landings -eq 1 -and $s.LandingsPerMin -eq 1.0) ("attempts={0} landings={1} perMin={2}" -f $s.Attempts, $s.Landings, $s.LandingsPerMin)
  # A5's own detector. Without this, a bug that skipped the gate would make every other number look BETTER.
  $nogate = @((New-TcProbeRow -Arm 'lock' -Writer 'w1' -Attempt 1 -Landed $true -GateSec 0 -LockWaitSec 0 -Width 4 -WorkSec 12 -GateRan $false))
  T ($kMF + '  a push that landed without its gate having run is counted and named') `
    ((Get-TcProbeSummary -Rows $nogate -WallSec 10).LandedWithoutGate -eq 1) 'a landing with no gate was not counted'
  T ($kMNF + '  a set where every landing gated reports none') ($s.LandedWithoutGate -eq 0) ("landedWithoutGate={0}" -f $s.LandedWithoutGate)
  # AN EMPTY SET IS NOT A CLEAN RESULT. A probe whose writers never ran must never read as "nobody wasted anything".
  $empty = Get-TcProbeSummary -Rows @() -WallSec 60
  T ($kMF + '  no rows at all reads as no landings and an infinite cost per landing, never as a clean arm') `
    ($empty.Attempts -eq 0 -and $empty.Landings -eq 0 -and [double]::IsInfinity($empty.GateSecPerLanding)) ("attempts={0} perLanding={1}" -f $empty.Attempts, $empty.GateSecPerLanding)
  if ($f) { Write-Output ("probe-push-throughput self-test FAIL: {0} of {1} check(s)" -f $f, $cases); exit 1 }
  Write-Output ("probe-push-throughput self-test PASS: {0} cases - led by a starved writer reading 'never landed' rather than a rate, and by an empty row set refusing to read as a clean arm" -f $cases)
  exit 0
}

$tag = [guid]::NewGuid().ToString('N').Substring(0, 8)
# PER RUN, and short: every character lands on every clone path below it and PS 5.1 stops at 260. -ErrorAction Stop,
# so a clash refuses rather than sharing a directory with another copy of this probe.
$root = Join-Path $env:TEMP ('tc-ppt-' + $tag)
$work = Join-Path $root 'w'
$null = New-Item -ItemType Directory -Force -ErrorAction Stop $work
# THE ROWS ARE THE PRODUCT, so they outlive the repositories: the working tree is removed in finally and this is not.
# Pass -OutDir to put them somewhere you will still know the name of tomorrow.
if (-not $OutDir) { $OutDir = Join-Path $root 'rows' }
$null = New-Item -ItemType Directory -Force $OutDir
$armList = @($Arms -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$summaries = @{}
try {
  Write-Output ("probe-push-throughput: {0} writer(s), writer w0's gate {1}x the others', {2}s of gate work each, a private budget of {3} worker slot(s), {4}s per arm." -f $Writers, $SlowMultiplier, $GateWorkSec, $Capacity, $BudgetSec)
  Write-Output ''
  foreach ($arm in $armList) {
    $summaries[$arm] = Invoke-TcPushArm -Arm $arm -Root $work -OutDir $OutDir -Writers $Writers -Work $GateWorkSec `
      -SlowMult $SlowMultiplier -Budget $BudgetSec -Capacity $Capacity -Tag $tag
    Write-TcArmReport -Arm $arm -S $summaries[$arm]
    Write-Output ''
  }
  Write-Output ("probe-push-throughput: one row per attempt per arm is kept at {0}" -f $OutDir)
  if ($summaries.ContainsKey('nolock') -and $summaries.ContainsKey('lock')) {
    $n = $summaries['nolock']; $l = $summaries['lock']
    $nSlow = @($n.ByWriter | Where-Object { $_.Writer -eq 'w0' })
    $lSlow = @($l.ByWriter | Where-Object { $_.Writer -eq 'w0' })
    $a1 = ($nSlow.Count -eq 1) -and ($nSlow[0].Landings -eq 0) -and ($nSlow[0].Attempts -ge 12)
    $a2 = ($l.ByWriter.Count -eq $Writers) -and (@($l.ByWriter | Where-Object { $_.AttemptsPerLanding -ne 1.0 }).Count -eq 0) -and ($l.Landings -ge 12)
    $a3 = ($l.LandingsPerMin -ge $n.LandingsPerMin)
    $a4 = ($l.WastedGateSec -eq 0) -and ($n.WastedGateSec -gt 0)
    $a5 = ($n.LandedWithoutGate -eq 0) -and ($l.LandedWithoutGate -eq 0)
    Write-Output ''
    Write-Output 'probe-push-throughput: the acceptance bars from design\PLAN-push-livelock-2026-09-11.md section 3 -'
    Write-Output ("  A1 the defect reproduces - the slow writer lands 0 in >=12 attempts, unlocked: {0} ({1} landing(s) in {2} attempt(s))" -f $(if ($a1) { 'MET' } else { 'NOT MET' }), $(if ($nSlow.Count) { $nSlow[0].Landings } else { 'no rows' }), $(if ($nSlow.Count) { $nSlow[0].Attempts } else { 0 }))
    Write-Output ("  A2 every locked writer lands on its first attempt, over >=12 landings: {0} ({1} landing(s); worst writer {2})" -f $(if ($a2) { 'MET' } else { 'NOT MET' }), $l.Landings, $(if ($l.ByWriter.Count) { ($l.ByWriter | Sort-Object AttemptsPerLanding -Descending | Select-Object -Last 1).AttemptsPerLanding } else { 'no rows' }))
    Write-Output ("  A3 locked landings/min >= unlocked: {0} ({1} vs {2})" -f $(if ($a3) { 'MET' } else { 'NOT MET' }), $l.LandingsPerMin, $n.LandingsPerMin)
    Write-Output ("  A4 gate-seconds thrown away falls to 0: {0} ({1:N0}s locked vs {2:N0}s unlocked)" -f $(if ($a4) { 'MET' } else { 'NOT MET' }), $l.WastedGateSec, $n.WastedGateSec)
    Write-Output ("  A5 nothing landed without its gate, in either arm: {0} ({1} unlocked, {2} locked)" -f $(if ($a5) { 'MET' } else { 'NOT MET' }), $n.LandedWithoutGate, $l.LandedWithoutGate)
    $met = @($a1, $a2, $a3, $a4, $a5) | Where-Object { $_ }
    Write-Output ("probe-push-throughput: {0} of 5 acceptance bar(s) met." -f @($met).Count)
  }
} finally {
  # The repositories and queues go; the rows stay, because they are what this run produced. When the rows were asked
  # for somewhere else, NOTHING of this run's root is kept - the first version removed only the work directory and
  # left an empty root behind every single run, which is the leak the estate's test-suites-leak-temp-dirs memory is
  # about: the ALLOCATOR has to remember, not the fixture.
  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
  if (-not $OutDir.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
  }
}
Exit-Guard -Name 'PROBE-PUSH-THROUGHPUT' -Summary ('arms=' + ($armList -join '+')) -Code 0
