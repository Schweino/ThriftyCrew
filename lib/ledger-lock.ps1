<#
  ledger-lock.ps1 - one named lock per single-file ledger, held around the WHOLE read-modify-write.

  Dot-source:  . (Join-Path $repoRoot 'lib\ledger-lock.ps1')
  Self-test:   powershell -File lib\ledger-lock.ps1 -SelfTest

  WHY (2026-09-11). Three single-file ledgers in grocery\ were read-modify-written by processes that run at the
  same time, with no lock at all:
    sale-windows.json          Set-SaleExpiryProcessed from the Hy-Vee, Baker's and Family Fare lanes, which
                               grocery\capture-run.ps1 starts together as Start-Job children; the walled builders
                               through commit-capture-cursor; capture-policy -Reconcile; and build-sale-windows,
                               which rewrites the whole file.
    out\capture-cursor.json    Save-CaptureCursor from the Baker's and Family Fare lanes (the same launch), from
                               build-walmart-deals and build-sams-deals, which Invoke-Fanout runs side by side, and
                               from the 10:30 watchdog's Family Fare window, which takes no capture-run mutex.
    rollback-first-seen.json   Save-RollbackLedger from the same two builders, plus compare-deals and
                               import-walmart-batch.
  Two writers read, each changes its own part, each writes the whole file: the second write carries the first
  writer's part as it was BEFORE the first writer changed it. The first change is gone and nothing says so. A
  retry on the replace (lib\atomic-write.ps1) cannot help: the replace succeeds, with the wrong contents.

  THE RULE is the one meal-prep\pipeline\source-domains.ps1 and grocery\ingredient-queue.ps1 already follow: a
  Global\ named mutex around the whole read-modify-write, with the READ inside it. A lock around the write alone
  still writes what was read before the lock was taken.

  A LEDGER HELD IN MEMORY MERGES UNDER THE LOCK. rollback-ttl-lib loads its ledger once, early in a build, and
  saves it much later. A lock around that save is a lock around a write of stale contents: it still overwrites
  every entry a sibling saved since the load. So its save re-reads the file inside the lock and folds in only the
  entries THIS process changed (Merge-RollbackEntry).

  WHY A LIBRARY AND NOT A FOURTH AND FIFTH COPY OF Invoke-Locked. Those two are CLIs, so on a timeout they `exit`.
  These ledgers are written by library functions dot-sourced into lanes and builders, where `exit` would end the
  whole builder - a Family Fare lane that had just bought its terms would die over a cursor. So this THROWS, and
  every caller wraps the write in a try/catch that says what stays owed. And the copies key their mutex on
  String.GetHashCode(), which .NET documents as not stable across versions and which differs between 32- and
  64-bit processes: two processes could hash one path to two mutexes and lock nothing. This keys on SHA-256.

  WHY Enter/Exit AND NOT A SCRIPTBLOCK. A body passed as a scriptblock runs in its own scope: a `return` inside it
  leaves the block rather than the function, and an assignment inside it never reaches the caller. The critical
  sections here are long functions that return early from inside them, so the lock is a token held in a
  try/finally at the call site.

  THE PATH IS THE IDENTITY. The name comes from the FULL path, lower-cased, so a relative spelling, another case or
  a `.\` detour all take one lock, and a worktree's copy of a ledger never blocks the main tree's. It does NOT
  resolve 8.3 short names, junctions or symlinks; nothing here writes a ledger through one.

  REENTRANT IN ONE THREAD. A mutex counts its owner's acquisitions, so Step-CaptureCursor can hold the cursor lock
  and call Save-CaptureCursor, which takes it again. Every Enter needs exactly one Exit.

  A WRITER THAT DIES HOLDING IT does not wedge the ledger: Windows hands the mutex to the next waiter as abandoned.
  The file is intact, because every writer here replaces through a temp file.

  A REFUSAL IS LOUD TWICE: the throw, and a `ledger-write-refused` event on lib\event-bus.ps1, because a lane's
  warning only reaches a transcript when the lane also fails.

  THE CONCURRENT-WRITERS FIXTURES' BARRIER LIVES HERE. Enter-TcLedgerLock calls lib\ledger-fixture.ps1's
  Wait-TcLedgerFixtureGate immediately before WaitOne. It returns at once unless a ledger self-test launched this
  process through Invoke-TcLedgerWriters, so in production it is nothing; under a fixture it holds each writer
  AFTER its own start-up, straight in front of the contended call, which is where .claude\rules\ops-and-gates.md
  says a barrier goes. Every ledger this lock guards therefore gets that barrier without a line of its own.

  THE TUNING CONSTANT: 120 s to wait. The first plausible number, NOT the survivor of a sweep. The longest hold here
  is rollback-ttl-lib's merge, measured at about 0.7 s over the live 1,776-entry ledger on 2026-09-11 (parse 333 ms,
  load 96 ms, serialise 304 ms, one quiet run); the ingredient ledgers saw a 10,433 ms wait beside 32 CPU burners.
  Every waiter is a daily lane or builder, for which two minutes is cheap and a refusal costs a cursor advance or a
  TTL anchor. Under a fixture it is Get-TcLedgerFixtureLockMs's hang guard instead, which is also 120 s today; the
  call is kept so the two can move apart without anyone remembering this file. What it does when the producer
  stops: nothing - it runs only when a writer calls it.

  SCOPE OF A CLEAN REPORT: the self-test proves on this machine that spellings of one path take one lock and two
  files take two, that a second PROCESS is refused while the lock is held and admitted once it is released or its
  holder is killed, and that a reentrant hold is released exactly. It proves nothing about a caller: whether a
  ledger's read is inside its lock is proved by that ledger's own concurrent-writers fixture
  (grocery\capture-policy-lib.ps1 and grocery\rollback-ttl-lib.ps1, each with -SelfTest).

  NO param() BLOCK: dot-sourced under PS 5.1 a param() block runs in the CALLER's scope (lib\json-io.ps1).
#>
$__llSelfTest = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-SelfTest')
. (Join-Path $PSScriptRoot 'event-bus.ps1')        # Write-TcEvent: never throws, so reporting a refusal cannot break its writer
. (Join-Path $PSScriptRoot 'ledger-fixture.ps1')   # Wait-TcLedgerFixtureGate: inert unless a ledger self-test launched this writer

$script:TcLedgerLockTimeoutMs = Get-TcLedgerFixtureLockMs 120000

function Get-TcLedgerLockName {
  <# The kernel name of the lock for the file at $Path. #>
  param([Parameter(Mandatory=$true)][string]$Path)
  # PowerShell LOCATION semantics for a relative path, the way Set-Content and lib\atomic-write.ps1 resolve it.
  $full = [IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path))
  $key = $full.TrimEnd([char[]]@('\', '/')).ToLowerInvariant()
  $sha = New-Object Security.Cryptography.SHA256CryptoServiceProvider
  try { $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($key)) } finally { $sha.Dispose() }
  $hex = -join @($bytes[0..11] | ForEach-Object { $_.ToString('x2') })
  return ('Global\tc-ledger-' + $hex)
}

function Enter-TcLedgerLock {
  <# Takes the lock for the ledger at $Path and returns the token Exit-TcLedgerLock needs. THROWS when the lock is not
     free within $TimeoutMs, having written nothing; the caller must say its change is not on disk. #>
  param([Parameter(Mandatory=$true)][string]$Path, [int]$TimeoutMs = $script:TcLedgerLockTimeoutMs)
  $full = [IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path))
  $name = Get-TcLedgerLockName -Path $full
  $mx = New-Object System.Threading.Mutex($false, $name)
  $held = $false; $abandoned = $false
  Wait-TcLedgerFixtureGate   # returns at once unless a ledger self-test launched this writer; its barrier sits here, after start-up
  $sw = [Diagnostics.Stopwatch]::StartNew()
  try { $held = $mx.WaitOne($TimeoutMs) }
  catch {
    # PowerShell hands a .NET method's exception over wrapped, so look through the wrapping for the one that matters.
    $ex = $_.Exception
    while ($null -ne $ex -and -not ($ex -is [System.Threading.AbandonedMutexException])) { $ex = $ex.InnerException }
    if ($null -eq $ex) { $mx.Dispose(); throw }
    $held = $true; $abandoned = $true   # a writer died holding it: the mutex is ours now, not wedged
  }
  if (-not $held) {
    $mx.Dispose()
    $null = Write-TcEvent -Kind 'ledger-write-refused' -Producer 'lib\ledger-lock.ps1' `
      -Data @{ ledger = $full; reason = 'lock-timeout'; detail = ('no lock within {0} ms' -f $TimeoutMs) }
    throw ('Enter-TcLedgerLock: could not take the lock on {0} within {1} ms - another writer held it the whole time. NOTHING was written; this change is not on disk.' -f $full, $TimeoutMs)
  }
  return [pscustomobject]@{ Path = $full; Name = $name; Mutex = $mx; WaitMs = [int]$sw.ElapsedMilliseconds; Abandoned = $abandoned }
}

function Exit-TcLedgerLock {
  <# Releases one hold taken by Enter-TcLedgerLock. Safe with $null, and safe twice on one token. #>
  param($Lock)
  if ($null -eq $Lock -or $null -eq $Lock.Mutex) { return }
  $mx = $Lock.Mutex
  $Lock.Mutex = $null
  try { $mx.ReleaseMutex() } finally { $mx.Dispose() }
}

if ($__llSelfTest) {
  $ErrorActionPreference = 'Stop'
  $script:llN = 0; $script:llBad = 0
  function Case([string]$Label, [string]$Name, [bool]$Ok, [string]$Got) {
    $script:llN++
    $line = if ($Label) { $Label + '  ' + $Name } else { $Name }
    if ($Ok) { Write-Output ('  ok    ' + $line) }
    else { $script:llBad++; Write-Output ('  X     ' + $line + '   got: ' + $Got) }
  }
  $PS = (Get-Command powershell).Source
  $dir = Join-Path ([IO.Path]::GetTempPath()) ('tc-ll-' + [guid]::NewGuid().ToString('N'))
  [void][IO.Directory]::CreateDirectory($dir)
  # Every refusal below writes an event. They go to a scratch bus, never the live one, and the children inherit it.
  $prevBus = $env:TC_EVENT_BUS
  $env:TC_EVENT_BUS = Join-Path $dir 'bus.jsonl'
  $kids = [Collections.Generic.List[object]]::new()
  $utf8 = New-Object Text.UTF8Encoding($false)
  try {
    # A child that takes the lock, says so, and holds it until the parent drops a release file.
    $holder = Join-Path $dir 'holder.ps1'
    $holderText = @'
param([string]$Lib, [string]$Ledger, [string]$Ready, [string]$Release)
$ErrorActionPreference = 'Stop'
. $Lib
$lk = Enter-TcLedgerLock -Path $Ledger -TimeoutMs 60000
[IO.File]::WriteAllText($Ready, [string]$PID)
$sw = [Diagnostics.Stopwatch]::StartNew()
while (-not (Test-Path -LiteralPath $Release) -and $sw.Elapsed.TotalSeconds -lt 120) { Start-Sleep -Milliseconds 20 }
Exit-TcLedgerLock $lk
exit 0
'@
    [IO.File]::WriteAllText($holder, $holderText, $utf8)
    # A child that asks for the lock once and reports TOOK (exit 0) or REFUSED (exit 1).
    $probe = Join-Path $dir 'probe.ps1'
    $probeText = @'
param([string]$Lib, [string]$Ledger, [int]$TimeoutMs)
$ErrorActionPreference = 'Stop'
. $Lib
try {
  $lk = Enter-TcLedgerLock -Path $Ledger -TimeoutMs $TimeoutMs
  Exit-TcLedgerLock $lk
  Write-Output 'TOOK'
  exit 0
} catch {
  Write-Output ('REFUSED ' + $_.Exception.Message)
  exit 1
}
'@
    [IO.File]::WriteAllText($probe, $probeText, $utf8)

    function Start-LlChild([string]$Script, [string[]]$ArgList) {
      $outF = Join-Path $dir ('out-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.txt')
      $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $Script + '"'))
      foreach ($a in $ArgList) { $argv += ('"' + $a + '"') }
      $p = Start-Process -FilePath $PS -ArgumentList $argv -PassThru -NoNewWindow -RedirectStandardOutput $outF -RedirectStandardError ($outF + '.err')
      $null = $p.Handle   # cache it now, or ExitCode reads empty once the process is gone
      [void]$kids.Add($p)
      return [pscustomobject]@{ Process = $p; Out = $outF }
    }
    # HANG GUARDS, not speed bars: nothing below is asserted on time.
    function Wait-LlFile([string]$Path, $Kid) {
      $sw = [Diagnostics.Stopwatch]::StartNew()
      while (-not (Test-Path -LiteralPath $Path) -and -not $Kid.Process.HasExited -and $sw.Elapsed.TotalSeconds -lt 120) { Start-Sleep -Milliseconds 20 }
      return (Test-Path -LiteralPath $Path)
    }
    function Wait-LlExit($Kid) { [void]$Kid.Process.WaitForExit(120000); $t = [string](Get-Content -LiteralPath $Kid.Out -Raw -ErrorAction SilentlyContinue); if ($null -eq $t) { $t = '' }; return $t.Trim() }

    $ledger = Join-Path $dir 'ledger.json'

    # ---- the name: one file, one lock; two files, two locks ----
    Push-Location $dir
    try { $rel = Get-TcLedgerLockName -Path 'ledger.json' } finally { Pop-Location }
    $abs = Get-TcLedgerLockName -Path $ledger
    $upper = Get-TcLedgerLockName -Path $ledger.ToUpperInvariant()
    $detour = Get-TcLedgerLockName -Path (Join-Path $dir 'sub\..\.\ledger.json')
    $slashed = Get-TcLedgerLockName -Path ($ledger -replace '\\', '/')
    Case 'MUST FIRE' 'a relative spelling, upper case, a sub\..\.\ detour and forward slashes all name ONE lock for one file (two names would be two mutexes and no lock)' `
      ($rel -eq $abs -and $upper -eq $abs -and $detour -eq $abs -and $slashed -eq $abs) ("rel=$rel abs=$abs upper=$upper detour=$detour slashed=$slashed")
    $other = Get-TcLedgerLockName -Path (Join-Path $dir 'other.json')
    $mainSw = Get-TcLedgerLockName -Path 'C:\Codex\ThriftyCrew\grocery\sale-windows.json'
    $wtSw = Get-TcLedgerLockName -Path 'C:\Codex\ThriftyCrew\.claude\worktrees\w\grocery\sale-windows.json'
    Case 'MUST NOT FIRE' 'two different files do not share a lock, and a worktree copy of a ledger never blocks the main tree''s' ($abs -ne $other -and $mainSw -ne $wtSw) ("abs=$abs other=$other main=$mainSw worktree=$wtSw")
    Case 'CLEAN TWIN' 'the name is a Global\ kernel name of fixed length, so separate processes and sessions meet on it' ($abs.StartsWith('Global\tc-ledger-') -and $abs.Length -eq 41) $abs

    # ---- a second PROCESS holds it: refused, loudly ----
    $ready1 = Join-Path $dir 'ready1'; $release1 = Join-Path $dir 'release1'
    $h1 = Start-LlChild $holder @($PSCommandPath, $ledger, $ready1, $release1)
    $opened1 = Wait-LlFile $ready1 $h1
    $err = ''
    try { $lk = Enter-TcLedgerLock -Path $ledger -TimeoutMs 250; Exit-TcLedgerLock $lk } catch { $err = $_.Exception.Message }
    Case 'MUST FIRE' 'while another PROCESS holds the lock, Enter is refused with a throw that names the file and says nothing was written' `
      ($opened1 -and $err.Contains($ledger) -and $err -match 'NOTHING was written') ("holder_ready=$opened1 error='$err'")
    $busRows = @()
    if (Test-Path -LiteralPath $env:TC_EVENT_BUS) { foreach ($line in [IO.File]::ReadAllLines($env:TC_EVENT_BUS)) { if ($line.Trim()) { $busRows += ($line | ConvertFrom-Json) } } }
    $refusals = @($busRows | Where-Object { [string]$_.kind -eq 'ledger-write-refused' -and [string]$_.reason -eq 'lock-timeout' -and [string]$_.ledger -eq $ledger })
    Case 'MUST FIRE' 'and the refusal is on the event bus, which the digest reads whoever swallowed the throw' ($refusals.Count -eq 1) ("refusal events=" + $refusals.Count + " of " + $busRows.Count + " bus row(s)")

    [IO.File]::WriteAllText($release1, 'x')
    $h1Out = Wait-LlExit $h1
    $took = $null; $err = ''
    try { $took = Enter-TcLedgerLock -Path $ledger -TimeoutMs 30000 } catch { $err = $_.Exception.Message }
    Case 'CLEAN TWIN' 'once that holder lets go, the next Enter takes the lock, and not as an abandoned one' ($null -ne $took -and -not $took.Abandoned) ("took=" + ($null -ne $took) + " error='$err' holder_exit=" + $h1.Process.ExitCode + " holder_out='$h1Out'")
    Exit-TcLedgerLock $took

    # ---- a holder KILLED while holding: not a wedge ----
    # TWO SHAPES, because Windows tells them apart. When another handle is open on the mutex as the holder dies (a
    # sibling writer already waiting), the kernel keeps the object and hands it on ABANDONED, and WaitOne throws - the
    # path Enter-TcLedgerLock has to catch through PowerShell's wrapping. When no handle is open anywhere, the object
    # dies with its holder and the next Enter creates a free one. The first draft of this case built only the second
    # shape, so it read abandoned=False: right behaviour, wrong fixture, and the catch went untested.
    $never = Join-Path $dir 'release-never'
    $ready2 = Join-Path $dir 'ready2'
    $h2 = Start-LlChild $holder @($PSCommandPath, $ledger, $ready2, $never)
    $opened2 = Wait-LlFile $ready2 $h2
    $waiter = New-Object System.Threading.Mutex($false, (Get-TcLedgerLockName -Path $ledger))   # a sibling's open handle
    Stop-Process -Id $h2.Process.Id -Force -ErrorAction SilentlyContinue
    [void]$h2.Process.WaitForExit(60000)
    $took = $null; $err = ''
    try { $took = Enter-TcLedgerLock -Path $ledger -TimeoutMs 30000 } catch { $err = $_.Exception.Message }
    Case 'MUST FIRE' 'a writer KILLED while holding the lock, with a sibling waiting, does not wedge the ledger: the next Enter takes it and reports it abandoned' `
      ($opened2 -and $null -ne $took -and $took.Abandoned) ("holder_ready=$opened2 took=" + ($null -ne $took) + " abandoned=" + $(if ($took) { $took.Abandoned } else { 'n/a' }) + " error='$err'")
    Exit-TcLedgerLock $took
    $waiter.Dispose()

    $ready3 = Join-Path $dir 'ready3'
    $h3 = Start-LlChild $holder @($PSCommandPath, $ledger, $ready3, $never)
    $opened3 = Wait-LlFile $ready3 $h3
    Stop-Process -Id $h3.Process.Id -Force -ErrorAction SilentlyContinue
    [void]$h3.Process.WaitForExit(60000)
    $took = $null; $err = ''
    try { $took = Enter-TcLedgerLock -Path $ledger -TimeoutMs 30000 } catch { $err = $_.Exception.Message }
    Case 'CLEAN TWIN' 'a writer KILLED while holding the lock with nobody waiting does not wedge it either: the next Enter takes a free lock' `
      ($opened3 -and $null -ne $took) ("holder_ready=$opened3 took=" + ($null -ne $took) + " error='$err'")
    Exit-TcLedgerLock $took

    # ---- reentrant: Step-CaptureCursor holds the cursor lock and calls Save-CaptureCursor ----
    $l1 = Enter-TcLedgerLock -Path $ledger -TimeoutMs 30000
    $l2 = $null; $err = ''
    try { $l2 = Enter-TcLedgerLock -Path $ledger -TimeoutMs 1000 } catch { $err = $_.Exception.Message }
    Case 'CLEAN TWIN' 'the thread that holds a lock can take it again (a nested writer does not deadlock on itself)' ($null -ne $l2) ("error='$err'")
    Exit-TcLedgerLock $l2
    $p6 = Start-LlChild $probe @($PSCommandPath, $ledger, '300')
    $p6Out = Wait-LlExit $p6
    Case 'MUST FIRE' 'one Exit of two leaves the lock HELD - another process is still refused' ($p6.Process.ExitCode -eq 1 -and $p6Out -match '^REFUSED') ("exit=" + $p6.Process.ExitCode + " out='$p6Out'")
    Exit-TcLedgerLock $l1
    Exit-TcLedgerLock $l1   # a second Exit on a released token is harmless
    $p7 = Start-LlChild $probe @($PSCommandPath, $ledger, '30000')
    $p7Out = Wait-LlExit $p7
    Case 'CLEAN TWIN' 'the second Exit releases it - another process then takes the lock' ($p7.Process.ExitCode -eq 0 -and $p7Out -eq 'TOOK') ("exit=" + $p7.Process.ExitCode + " out='$p7Out'")
  } finally {
    foreach ($k in $kids) { try { if (-not $k.HasExited) { $k.Kill() } } catch { } }
    $env:TC_EVENT_BUS = $prevBus
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
  }
  if ($script:llBad) {
    Write-Output ("ledger-lock SELF-TEST FAIL ({0} of {1})" -f $script:llBad, $script:llN)
    Write-Output ("LEDGER-LOCK-COMPLETE cases={0} failed={1}" -f $script:llN, $script:llBad)
    exit 1
  }
  Write-Output ("ledger-lock SELF-TEST PASS ({0} cases)" -f $script:llN)
  Write-Output ("LEDGER-LOCK-COMPLETE cases={0} failed=0" -f $script:llN)
  exit 0
}
