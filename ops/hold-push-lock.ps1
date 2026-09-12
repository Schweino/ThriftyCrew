<#
  hold-push-lock.ps1 - hold the machine-wide push lock for as long as a pre-push hook is running, and say in one file
  whether it is held.

  Run:        powershell -File ops\hold-push-lock.ps1 -SignalDir <dir> -WatchPid <pid>
  Self-test:  powershell -File ops\hold-push-lock.ps1 -SelfTest

  WHY A SEPARATE PROCESS. A Windows mutex is owned by the thread that took it, so something must STAY ALIVE for the
  whole hook to hold one. ops\hooks\pre-push is `sh`, and its two PowerShell children (the gate and the test-auditors
  check) each exit, so neither can carry the lock across the other. This starts alongside them, takes the lock, and
  holds it until the hook says it is done. lib\push-lock.ps1 is the lock itself and has the account of why there is
  one; design\PLAN-push-livelock-2026-09-11.md is the diagnosis.

  IT SPEAKS THROUGH ONE FILE, <SignalDir>\state, whose first line is exactly one of:
      held        - this process holds the push lock. Nothing else on this box will land while the hook runs.
      inherited   - an ancestor already holds it (ops\push-main.ps1), so it was not taken again and nothing is held.
      unlocked    - it was NOT taken, and the rest of the line says why IN WORDS.
  The hook waits for that file, prints the line, and pushes on regardless.

  UNLOCKED IS NEVER A REFUSAL, and that is deliberate. This is a fairness device, not a safety device - the GATE is
  what makes a push safe, and nothing here reads a tree. The hook it serves lives in the SHARED .git in front of
  every checkout on this box, so a lock that could not be taken must degrade to the behaviour of the day before this
  file existed, never to a box nobody can push from.

  IT CANNOT OUTLIVE ITS HOOK, by three independent means, because a holder that leaks holds up every push on the box:
    1. -WatchPid: when the hook's own process is gone, this releases and exits.
    2. <SignalDir>\release: the hook writes it on every exit path, through a trap.
    3. -MaxHoldSec: a hang guard, far above any measured hook.
  And if this process is KILLED outright, Windows marks the mutex abandoned and the next waiter takes it at once -
  which is why liveness is carried by the mutex and never by a file (lib\gate-slots.ps1).

  SCOPE OF A CLEAN REPORT: `held` proves this process holds the one push mutex while it lives. It proves nothing
  about a pusher that does not run this hook - an older checkout, --no-verify, or another machine.
#>
[CmdletBinding()]
param(
  [string]$SignalDir = '',
  [int]$WatchPid = 0,
  [int]$WaitSec = 1200,
  [int]$MaxHoldSec = 5400,
  [int]$PollMs = 250,
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path -Parent $here
. (Join-Path $repo 'lib\push-lock.ps1')
. (Join-Path $repo 'lib\push-ledger.ps1')

function Get-TcHoldLockNames {
  <# Which lock this hold should take. Normally the real one; a FIXTURE may redirect it, and the redirect is
     self-limiting: it is honoured ONLY when it names a `Local\` prefix.

     WHY AN OVERRIDE AT ALL. ops\test-prepush-hook.ps1 drives REAL pushes through the real hook, so without this its
     cases would take the live Global\ push lock and hold up every other session on the box for as long as the
     fixture runs - and one of those cases has to hold the lock against itself, which would have wedged a real push.
     WHY IT IS SAFE. The prefix can only ever be moved to a Local\ name, which is private to the session that set it,
     so nothing can redirect a push onto ANOTHER shared lock and quietly land beside somebody. And the lock is a
     fairness device in the first place: the gate is what makes a push safe, and no setting here reaches it. A
     Global\ value in the variable is IGNORED rather than obeyed, and the real names are used. #>
  param([string]$PrefixEnv, [string]$RootEnv, [string]$WaitEnv = '')
  $prefix = ''; $root = ''; $wait = 0
  if ($PrefixEnv -and $PrefixEnv.StartsWith('Local\')) {
    $prefix = $PrefixEnv
    if ($RootEnv) { $root = $RootEnv }
    # THE WAIT TRAVELS ONLY WITH A PRIVATE LOCK, so nothing can shorten the real one's wait and make the estate's
    # pushes stop queueing for each other. A fixture needs it to pick the BRANCH - it asserts that a contended hold
    # reports `unlocked` and pushes on, never how many seconds that took, and a case that sat out the real 1,200 s
    # would be a wall-clock bar in a hermetic suite, which is the red that teaches --no-verify.
    if ($WaitEnv -match '^\d+$' -and [int]$WaitEnv -gt 0) { $wait = [int]$WaitEnv }
  }
  return [pscustomobject]@{ Prefix = $prefix; QueueRoot = $root; WaitSec = $wait }
}

function Write-TcHoldState {
  <# The state file is written ONCE and completely, before anything waits on it: a hook reading a half-written line
     would decide on a fragment. #>
  param([string]$Dir, [string]$Text)
  $null = New-Item -ItemType Directory -Force $Dir
  [IO.File]::WriteAllText((Join-Path $Dir 'state'), $Text)
}

function Test-TcHoldDone {
  <# Has this hold ended? Any of: the release file exists, the watched process is gone, or the hang guard expired.
     Returns the reason in words, or '' while it should keep holding. A WatchPid of 0 watches nothing. #>
  param([string]$Dir, [int]$WatchPid, [double]$HeldSec, [int]$MaxHoldSec)
  if ([IO.File]::Exists((Join-Path $Dir 'release'))) { return 'the hook released it' }
  if ($WatchPid -gt 0 -and -not (Test-TcProcessAlive -ProcessId $WatchPid)) { return ('the hook process ' + $WatchPid + ' is gone') }
  if ($HeldSec -ge $MaxHoldSec) { return ('the ' + $MaxHoldSec + 's hang guard expired, which no measured hook reaches') }
  return ''
}

function Invoke-TcPushLockHold {
  <# Take the lock, announce it, hold until done, release. Returns the state word it announced.

     IT ALSO RECORDS ONE ROW (2026-09-12, lib\push-ledger.ps1). This is the one place on the box that knows how long
     a push waited, and until now it said so only in a file the hook deletes on its way out - so every account of
     whether the push path converges has been archaeology over whatever %TEMP% happened to still hold, a population
     that drops its successes. The row carries the wait, the state, and refs/remotes/origin/<branch> as it stood
     BEFORE the wait and at the GRANT: a difference between those two is a landing that happened under this push's
     feet, which is the quantity that decides whether retrying can converge. Recording is best effort and is never
     read by anything that decides - a ledger must not be able to refuse a push. #>
  param([string]$Dir, [int]$WatchPid, [int]$WaitSec, [int]$MaxHoldSec, [int]$PollMs, [string]$Prefix = '', [string]$QueueRoot = '',
    [string]$RepoDir = '', [string]$LedgerRoot = '', [string]$WatchRef = 'refs/remotes/origin/main')
  $args2 = @{ WaitSec = $WaitSec; PollMs = 500 }
  if ($Prefix) { $args2['Prefix'] = $Prefix }
  if ($QueueRoot) { $args2['QueueRoot'] = $QueueRoot }
  # READ BEFORE THE WAIT, or the comparison is between the ref and itself. An unreadable ref is '' and its row is
  # counted UNKNOWN rather than as a ref that stood still.
  $baseSha = $(if ($RepoDir) { Get-TcPushLedgerRefSha -Dir $RepoDir -Ref $WatchRef } else { '' })
  $record = {
    param([string]$State, [double]$WaitMs, [string]$Grant)
    $null = Write-TcPushRow -Event 'hook-lock' -WaitMs $WaitMs -State $State -BaseSha $baseSha -GrantSha $Grant `
      -Outcome '' -Checkout $RepoDir -Root $LedgerRoot
  }
  $lock = $null
  try {
    $lock = Enter-TcPushLock @args2
  } catch {
    & $record 'unlocked' -1 ''
    Write-TcHoldState -Dir $Dir -Text ('unlocked the push lock could not be taken (' + $_.Exception.Message + '); this push is gated exactly as it was before, it just races for the ref')
    return 'unlocked'
  }
  $grantSha = $(if ($RepoDir) { Get-TcPushLedgerRefSha -Dir $RepoDir -Ref $WatchRef } else { '' })
  if (-not $lock.Held) {
    & $record 'unlocked' ([double]$lock.WaitedMs) $grantSha
    Write-TcHoldState -Dir $Dir -Text ('unlocked ' + $lock.Reason + '; this push is gated exactly as it was before, it just races for the ref')
    return 'unlocked'
  }
  if ($lock.Inherited) {
    & $record 'inherited' ([double]$lock.WaitedMs) $grantSha
    Write-TcHoldState -Dir $Dir -Text ('inherited ' + $lock.Reason)
    Exit-TcPushLock $lock
    return 'inherited'
  }
  & $record 'held' ([double]$lock.WaitedMs) $grantSha
  try {
    Write-TcHoldState -Dir $Dir -Text ('held after waiting {0:N0}s - no other push on this box can land while this hook runs' -f ($lock.WaitedMs / 1000))
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
      $why = Test-TcHoldDone -Dir $Dir -WatchPid $WatchPid -HeldSec $sw.Elapsed.TotalSeconds -MaxHoldSec $MaxHoldSec
      if ($why) { break }
      Start-Sleep -Milliseconds $PollMs
    }
  } finally {
    Exit-TcPushLock $lock
  }
  return 'held'
}

if ($SelfTest) {
  $f = 0; $cases = 0
  $kMF = 'MUST' + ' FIRE'; $kMNF = 'MUST' + ' NOT FIRE'; $kCT = 'CLEAN' + ' TWIN'
  function T($m, $cond, $got) {
    $script:cases++
    if ($cond) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $got); $script:f++ }
  }
  # A unique directory per run under %TEMP%, short: run-gates runs every self-test and pre-push runs run-gates, so
  # concurrent pushes run this file over each other in one %TEMP%.
  $tmp = Join-Path $env:TEMP ('tc-hpl-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
  $null = New-Item -ItemType Directory -Force -ErrorAction Stop $tmp
  $prefix = 'Local\tc-hold-push-selftest-' + [guid]::NewGuid().ToString('N') + '-'
  $qroot = Join-Path $tmp 'q'
  $kids = [Collections.Generic.List[object]]::new()
  $PS = (Get-Command powershell).Source
  # EVERY CASE IN THIS SUITE WRITES ITS LEDGER ROWS TO SCRATCH (2026-09-12). The cases below call
  # Invoke-TcPushLockHold without -LedgerRoot, and before this redirect existed those wrote FIXTURE rows into the
  # production ledger - the first live convergence report off this box was computed over them. A default that
  # reaches a real path is redirected suite-wide, never per fixture (ops-and-gates.md).
  $prodLedger = Get-TcPushLedgerPath
  $ledgerRootWas = $env:TC_PUSH_LEDGER_ROOT
  $env:TC_PUSH_LEDGER_ROOT = Join-Path $tmp 'suite-ledger'
  try {
    # ---- THE END CONDITIONS, driven directly rather than by waiting on a clock ----
    $d = Join-Path $tmp 'd1'; $null = New-Item -ItemType Directory -Force $d
    T ($kMNF + '  a hold with nothing released, a live watched process and time left keeps holding') `
      ((Test-TcHoldDone -Dir $d -WatchPid $PID -HeldSec 1 -MaxHoldSec 5400) -eq '') 'it ended early'
    [IO.File]::WriteAllText((Join-Path $d 'release'), 'go')
    T ($kMF + '  the release file the hook writes ends the hold') `
      ((Test-TcHoldDone -Dir $d -WatchPid $PID -HeldSec 1 -MaxHoldSec 5400) -match 'released') 'the release file was ignored'
    $d2 = Join-Path $tmp 'd2'; $null = New-Item -ItemType Directory -Force $d2
    $dead = Start-Process -FilePath $PS -ArgumentList @('-NoProfile', '-Command', 'exit') -PassThru -WindowStyle Hidden
    $null = $dead.WaitForExit(15000)
    T ($kMF + '  a hook that died without releasing ends the hold, so a killed push cannot hold the box up') `
      ((Test-TcHoldDone -Dir $d2 -WatchPid $dead.Id -HeldSec 1 -MaxHoldSec 5400) -match 'is gone') 'a dead hook kept the lock'
    T ($kMF + '  the hang guard ends a hold nothing else ended') `
      ((Test-TcHoldDone -Dir $d2 -WatchPid $PID -HeldSec 5400 -MaxHoldSec 5400) -match 'hang guard') 'the hang guard did not fire'
    T ($kCT + '  a WatchPid of 0 watches nothing and does not end the hold by itself') `
      ((Test-TcHoldDone -Dir $d2 -WatchPid 0 -HeldSec 1 -MaxHoldSec 5400) -eq '') 'a zero pid ended the hold'

    # ---- the fixture redirect, which can only ever point at a private lock ----
    $okLocal = Get-TcHoldLockNames -PrefixEnv 'Local\tc-fix-' -RootEnv 'C:\q'
    T ($kMNF + '  a fixture may redirect this hold onto a Local\ lock of its own, and its queue root travels with it') `
      ($okLocal.Prefix -eq 'Local\tc-fix-' -and $okLocal.QueueRoot -eq 'C:\q') ("prefix={0} root={1}" -f $okLocal.Prefix, $okLocal.QueueRoot)
    $badGlobal = Get-TcHoldLockNames -PrefixEnv 'Global\tc-push-lock-' -RootEnv 'C:\q'
    T ($kMF + '  a redirect naming a Global\ prefix is IGNORED, so nothing can move a push onto another shared lock') `
      ($badGlobal.Prefix -eq '' -and $badGlobal.QueueRoot -eq '') ("prefix={0} root={1}" -f $badGlobal.Prefix, $badGlobal.QueueRoot)
    $withWait = Get-TcHoldLockNames -PrefixEnv 'Local\tc-fix-' -RootEnv 'C:\q' -WaitEnv '3'
    T ($kMNF + '  a fixture on a private lock may shorten its own wait, so a case picks the branch instead of sitting out 1,200s') `
      ($withWait.WaitSec -eq 3) ("waitSec={0}" -f $withWait.WaitSec)
    $waitNoPrefix = Get-TcHoldLockNames -PrefixEnv '' -RootEnv '' -WaitEnv '3'
    T ($kMF + '  a shortened wait with no private prefix is IGNORED, so nothing can stop real pushes queueing for each other') `
      ($waitNoPrefix.WaitSec -eq 0) ("waitSec={0}" -f $waitNoPrefix.WaitSec)
    $none = Get-TcHoldLockNames -PrefixEnv '' -RootEnv ''
    T ($kCT + '  with nothing set, the hold takes the real push lock') ($none.Prefix -eq '') ("prefix={0}" -f $none.Prefix)
    $bare = Get-TcHoldLockNames -PrefixEnv 'tc-push-lock-' -RootEnv 'C:\q'
    T ($kMF + '  a redirect with no namespace at all is ignored too, not treated as Local') `
      ($bare.Prefix -eq '') ("prefix={0}" -f $bare.Prefix)

    # ---- the three states, for real, against a private lock ----
    $dh = Join-Path $tmp 'held'; $null = New-Item -ItemType Directory -Force $dh
    [IO.File]::WriteAllText((Join-Path $dh 'release'), 'go')   # release it before it starts, so the hold is instant
    $st = Invoke-TcPushLockHold -Dir $dh -WatchPid 0 -WaitSec 5 -MaxHoldSec 5400 -PollMs 50 -Prefix $prefix -QueueRoot $qroot
    $line = [IO.File]::ReadAllText((Join-Path $dh 'state'))
    T ($kMNF + '  with the lock free, the state file says held and names the wait') `
      ($st -eq 'held' -and $line.StartsWith('held')) ("state={0} line={1}" -f $st, $line)

    # ---- THE ROW THIS HOLD RECORDS (2026-09-12, lib\push-ledger.ps1) ----
    # The wait and the staleness were only ever written to <SignalDir>\state, which ops\hooks\pre-push deletes on its
    # way out, so nobody could answer "how long do pushes wait, and how often does the remote move while they do"
    # without reading whatever %TEMP% happened to still hold - a population with its successes deleted.
    $dl = Join-Path $tmp 'ledger'; $null = New-Item -ItemType Directory -Force $dl
    [IO.File]::WriteAllText((Join-Path $dl 'release'), 'go')
    $ledRoot = Join-Path $tmp 'led'
    $stL = Invoke-TcPushLockHold -Dir $dl -WatchPid 0 -WaitSec 5 -MaxHoldSec 5400 -PollMs 50 -Prefix $prefix -QueueRoot $qroot `
      -RepoDir $repo -LedgerRoot $ledRoot
    # ASSIGN, THEN WRAP. A function's comma-returned array reads as ONE element inside an inline @( ) - an empty
    # result would count 1 and this case would pass over nothing ([[ps-json-array-collapse]]).
    $ledRowsRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledRoot)
    $ledRows = @($ledRowsRaw)
    T ($kMF + '  a hold records exactly one ledger row naming its wait, its state and the ref it watched, so the wait outlives the signal directory') `
      ($stL -eq 'held' -and $ledRows.Count -eq 1 -and $ledRows[0].state -eq 'held' -and $ledRows[0].event -eq 'hook-lock' `
        -and ([string]$ledRows[0].base) -match '^[0-9a-f]{7,40}$' -and [double]$ledRows[0].waitMs -ge 0) `
      ("state={0} rows={1} rowState={2} base={3}" -f $stL, $ledRows.Count, $(if ($ledRows.Count) { $ledRows[0].state } else { '' }), $(if ($ledRows.Count) { $ledRows[0].base } else { '' }))

    # A REF IT COULD NOT READ IS RECORDED AS UNKNOWN, never as a ref that stood still - otherwise a box where git
    # could not be reached would report a perfect zero-staleness rate.
    $dn = Join-Path $tmp 'ledgerblind'; $null = New-Item -ItemType Directory -Force $dn
    [IO.File]::WriteAllText((Join-Path $dn 'release'), 'go')
    $ledRoot2 = Join-Path $tmp 'led2'
    $null = Invoke-TcPushLockHold -Dir $dn -WatchPid 0 -WaitSec 5 -MaxHoldSec 5400 -PollMs 50 -Prefix $prefix -QueueRoot $qroot `
      -RepoDir $repo -LedgerRoot $ledRoot2 -WatchRef 'refs/remotes/origin/no-such-branch-here-42'
    $blindRowsRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledRoot2)
    $mBlind = Measure-TcPushRows @($blindRowsRaw)
    T ($kMF + '  a hold whose watched ref cannot be read records UNKNOWN, so the staleness rate never counts it as a ref that stood still') `
      ($mBlind.Rows -eq 1 -and $mBlind.Unknown -eq 1 -and $mBlind.Comparable -eq 0) `
      ("rows={0} unknown={1} comparable={2}" -f $mBlind.Rows, $mBlind.Unknown, $mBlind.Comparable)

    # AND THE LEDGER MUST NOT BE ABLE TO REFUSE A PUSH. The root is a FILE, so no row can be written at all.
    $db = Join-Path $tmp 'ledgerbroken'; $null = New-Item -ItemType Directory -Force $db
    [IO.File]::WriteAllText((Join-Path $db 'release'), 'go')
    $ledFile = Join-Path $tmp 'led-not-a-dir'
    [IO.File]::WriteAllText($ledFile, 'not a directory')
    $stB = Invoke-TcPushLockHold -Dir $db -WatchPid 0 -WaitSec 5 -MaxHoldSec 5400 -PollMs 50 -Prefix $prefix -QueueRoot $qroot `
      -RepoDir $repo -LedgerRoot $ledFile
    $lineB = [IO.File]::ReadAllText((Join-Path $db 'state'))
    T ($kCT + '  a ledger that cannot be written does not stop the hold: the lock is still taken and the hook is still told') `
      ($stB -eq 'held' -and $lineB.StartsWith('held')) ("state={0} line={1}" -f $stB, $lineB)

    # A CONTENDER IS ANOTHER PROCESS, because a mutex is recursive in one thread and this one would take it again.
    $body = @'
. '__LIB__'
$lk = Enter-TcPushLock -Prefix '__PFX__' -QueueRoot '__QROOT__' -WaitSec 600 -PollMs 50 -NoInherit
[IO.File]::WriteAllText('__READY__', [string][int]$lk.Held)
$sw = [Diagnostics.Stopwatch]::StartNew()
while (-not (Test-Path -LiteralPath '__REL__') -and $sw.Elapsed.TotalSeconds -lt 120) { Start-Sleep -Milliseconds 25 }
Exit-TcPushLock $lk
'@
    $ready = Join-Path $tmp 'c.ready'; $rel = Join-Path $tmp 'c.rel'
    $body = $body.Replace('__LIB__', (Join-Path $repo 'lib\push-lock.ps1')).Replace('__PFX__', $prefix)
    $body = $body.Replace('__QROOT__', $qroot).Replace('__READY__', $ready).Replace('__REL__', $rel)
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($body))
    $c = Start-Process -FilePath $PS -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $enc) -PassThru -WindowStyle Hidden
    $kids.Add($c)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath $ready) -and $sw.Elapsed.TotalSeconds -lt 60 -and -not $c.HasExited) { Start-Sleep -Milliseconds 25 }
    $contenderHeld = $(if (Test-Path -LiteralPath $ready) { [int]([IO.File]::ReadAllText($ready).Trim()) } else { -1 })
    $du = Join-Path $tmp 'unlocked'; $null = New-Item -ItemType Directory -Force $du
    # WaitSec 1: what is asserted is the BRANCH, never how long it took.
    $stU = Invoke-TcPushLockHold -Dir $du -WatchPid 0 -WaitSec 1 -MaxHoldSec 5400 -PollMs 50 -Prefix $prefix -QueueRoot $qroot
    $lineU = [IO.File]::ReadAllText((Join-Path $du 'state'))
    T ($kMF + '  with another push holding the lock, the state file says unlocked and gives the reason in words - it does not say held') `
      ($contenderHeld -eq 1 -and $stU -eq 'unlocked' -and $lineU.StartsWith('unlocked') -and $lineU -match 'did not move') `
      ("contenderHeld={0} state={1} line={2}" -f $contenderHeld, $stU, $lineU)
    T ($kCT + '  an unlocked hold still tells the hook to push on, rather than refusing it') `
      ($lineU -match 'gated exactly as it was before') ("line={0}" -f $lineU)
    [IO.File]::WriteAllText($rel, 'go'); $null = $c.WaitForExit(30000)

    $di = Join-Path $tmp 'inh'; $null = New-Item -ItemType Directory -Force $di
    # The token names the lock it was taken on, and only a matching one is inherited - so this case has to name
    # THIS fixture's private prefix. A token from another lock is not an inheritance (lib\push-lock.ps1).
    $env:TC_PUSH_LOCK_HOLDER = "{0}|abcdef123456|{1}" -f $PID, $prefix
    $stI = Invoke-TcPushLockHold -Dir $di -WatchPid 0 -WaitSec 5 -MaxHoldSec 5400 -PollMs 50 -Prefix $prefix -QueueRoot $qroot
    $lineI = [IO.File]::ReadAllText((Join-Path $di 'state'))
    Remove-Item -LiteralPath Env:TC_PUSH_LOCK_HOLDER -ErrorAction SilentlyContinue
    T ($kMNF + '  a hook under ops\push-main.ps1 inherits the lock instead of deadlocking on its own ancestor') `
      ($stI -eq 'inherited' -and $lineI.StartsWith('inherited')) ("state={0} line={1}" -f $stI, $lineI)
    $free = Enter-TcPushLock -Prefix $prefix -QueueRoot $qroot -WaitSec 5 -PollMs 50 -NoInherit
    T ($kCT + '  an inherited hold released nothing of its ancestor''s, and left the lock takeable afterwards') `
      ($free.Held) ("held={0}" -f $free.Held)
    Exit-TcPushLock $free

    # NOTHING THIS SUITE WROTE REACHED THE PRODUCTION LEDGER. Keyed on this process's pid rather than on the file's
    # size, because a real push from another session may append to it while these cases run.
    $prodRaw = Read-TcPushRows -Path $prodLedger
    $prodMine = @(@($prodRaw) | Where-Object { -not $_.PSObject.Properties['malformed'] -and [int]$_.pid -eq $PID })
    T ($kMF + '  no row this suite wrote reached the production ledger, so the convergence report is never computed over fixtures') `
      ($prodMine.Count -eq 0) ("rowsFromThisProcessInProduction={0}" -f $prodMine.Count)
  } finally {
    foreach ($p in $kids) { try { if (-not $p.HasExited) { $p.Kill() } } catch { } }
    if ($null -eq $ledgerRootWas) {
      Remove-Item -LiteralPath Env:TC_PUSH_LEDGER_ROOT -ErrorAction SilentlyContinue
    } else {
      $env:TC_PUSH_LEDGER_ROOT = $ledgerRootWas
    }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath Env:TC_PUSH_LOCK_HOLDER -ErrorAction SilentlyContinue
  }
  if ($f) { Write-Output ("hold-push-lock self-test FAIL: {0} of {1} check(s)" -f $f, $cases); exit 1 }
  Write-Output ("hold-push-lock self-test PASS: {0} cases - led by a dead hook's hold ending rather than holding the box up, and by a contended lock reporting unlocked in words instead of held" -f $cases)
  exit 0
}

if (-not $SignalDir) {
  Write-Output 'hold-push-lock: -SignalDir is required. This is started by ops\hooks\pre-push, not by hand.'
  exit 2
}
$names = Get-TcHoldLockNames -PrefixEnv ([string]$env:TC_PUSH_LOCK_PREFIX) -RootEnv ([string]$env:TC_PUSH_LOCK_QUEUE_ROOT) `
  -WaitEnv ([string]$env:TC_PUSH_LOCK_WAIT_SEC)
if ($names.WaitSec -gt 0) { $WaitSec = $names.WaitSec }
$state = Invoke-TcPushLockHold -Dir $SignalDir -WatchPid $WatchPid -WaitSec $WaitSec -MaxHoldSec $MaxHoldSec `
  -PollMs $PollMs -Prefix $names.Prefix -QueueRoot $names.QueueRoot -RepoDir $repo -LedgerRoot ([string]$env:TC_PUSH_LEDGER_ROOT)
Write-Output ('hold-push-lock: ' + $state)
exit 0
