# ingredient-resolutions.ps1
# ---------------------------------------------------------------------------------------------------
# Remembers what an ingredient string resolved to, so the mapper stops re-deriving stable answers and
# the commodity-registrar is never asked the same question twice.
#
# IDENTITY ONLY - NEVER PRICE. This caches "shaved beef steak -> shaved-beef-steak, bid exists" and
# nothing else. Prices come from the board and change weekly; caching one would be how a stale number
# reaches a card. The `bid_exists` flag is a fact about the WIRING (is there a row in
# db\ingredients.json), not about the amount, and it is what lets the mapper hold a recipe BEFORE the
# writer is paid rather than after the auditor catches it - the R3 shift-left in the efficiency plan.
#
#   .\ingredient-resolutions.ps1 -Record -Term 'shaved beef steak' -ItemId shaved-beef-steak [-BidExists] [-Evidence '...'] [-By mapper]
#   .\ingredient-resolutions.ps1 -Query -Term 'shaved beef steak'         exit 3 when a prior ruling exists, 2 when the ledger cannot be read
#   .\ingredient-resolutions.ps1 -Invalidate -ItemId x    (a registrar ruling changed a commodity id)
#   .\ingredient-resolutions.ps1 -SelfTest
# ---------------------------------------------------------------------------------------------------
param(
  [switch]$Record, [switch]$Query, [switch]$Invalidate, [switch]$List, [switch]$SelfTest,
  [string]$Term = '', [string]$ItemId = '', [string]$Evidence = '', [string]$By = '',
  [switch]$BidExists, [string]$Store = '', [switch]$Json,
  [int]$ReadWaitMs = 3000     # the settled-read bound; lib\json-io.ps1 records where 3000 came from. Fixtures shorten it.
)
$ErrorActionPreference = 'Stop'
$runRecord=[bool]$Record; $runQuery=[bool]$Query; $runInv=[bool]$Invalidate; $runSelfTest=[bool]$SelfTest; $runJson=[bool]$Json; $runBid=[bool]$BidExists

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp   = Split-Path -Parent $here
$repo = Split-Path -Parent $mp
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\atomic-write.ps1')   # Write-TcAtomicFile: a lock-free reader must not cost a writer its write
. (Join-Path $repo 'lib\ledger-fixture.ps1') # Wait-TcLedgerFixtureGate: inert unless this file's own self-test launched the writer
. (Join-Path $repo 'lib\json-io.ps1')   # Read-JsonFileSettled: the writer's replace window is waited out, never read as an empty ledger
# THE LIVE LEDGER IS TRACKED IN GIT (since 2026-08-16), so it is in every checkout and its absence is never a
# fresh estate. A scratch store named by -Store can be. The write path needs to know which one it holds.
$liveStore = Join-Path $mp 'db\ingredient-resolutions.json'
if (-not $Store) { $Store = $liveStore }
$storeIsLive = [string]::Equals([IO.Path]::GetFullPath($Store), [IO.Path]::GetFullPath($liveStore), [StringComparison]::OrdinalIgnoreCase)

function Get-TermKey {
  param([string]$T)
  if (-not $T) { return '' }
  # Normalise the incidental, keep the meaningful. "2 lbs Shaved Beef Steak," and "shaved beef steak"
  # are the same question; "beef steak" is NOT, so no word is ever dropped.
  $t = $T.ToLower().Trim()
  $t = $t -replace '[^a-z0-9 ]', ' '
  $t = $t -replace '\s+', ' '
  return $t.Trim()
}
# ---------------------------------------------------------------------------------------------------
# THE READ IS SETTLED, AND IT NO LONGER ANSWERS "EMPTY" FOR "COULD NOT LOOK" (2026-09-11).
#
# Read-Store used to return @() for a missing file AND for any read or parse failure. Two things made that
# wrong. Save-Rows replaces this file by Move-Item -Force, which deletes the name and then renames onto it,
# and a separate reader saw the file ABSENT on 4,024 of 109,718 polls across 1,500 replaces - so a -Query in
# that window answered "no prior resolution" with the ruling sitting on disk. And the in-lock re-read in
# -Record and -Invalidate used this same function, so an unreadable ledger became an empty one and Save-Rows
# then wrote only the new row over every row the ledger held.
#
# So it returns WHAT IT SAW - State ok, absent or unreadable, after lib\json-io.ps1's bounded wait - and each
# caller decides what that means:
#   -Query, -List, -Json   CONSUMERS: anything but ok is exit 2 with a stdout line, never "no prior resolution".
#   -Record, -Invalidate   WRITERS, inside the lock: unreadable REFUSES the write. Absent is a new ledger for a
#                          scratch -Store, and a refusal for the live one, which git tracks.
# ---------------------------------------------------------------------------------------------------
function Read-Store { param([string]$P, [int]$WaitMs = $ReadWaitMs, [scriptblock]$OnWait = $null)
  $st = Read-JsonFileSettled -Path $P -WaitMs $WaitMs -OnWait $OnWait `
          -Accept { param($d) $null -ne $d -and ($d.PSObject.Properties.Name -contains 'resolutions') -and $null -ne $d.resolutions }
  $rowsRead = @()
  if ($st.State -eq 'ok') { $assigned = $st.Doc.resolutions; $rowsRead = @($assigned) }
  return [pscustomobject]@{ State = $st.State; Rows = $rowsRead; Why = $st.Why; Waits = $st.Waits } }

# ---------------------------------------------------------------------------------------------------
# THE WRITE LOCK (added 2026-08-24, PLAN-recipe-hunter-v3 D9's phase-1 obligation: "any single-file
# ledger written by a lane whose cap exceeds 1 takes the source-domains named-mutex pattern, with a
# concurrent-writers fixture PER LEDGER").
#
# This ledger is a read-modify-write of one JSON file, and until today its only writer was one mapper
# agent at a time. The v3 daemon runs the MAP LANE AT CAP 2 and holds the pen itself, so two mapper
# completions can land a -Record at the same moment: both read the same rows, both add their own, and
# the last one wins - the other resolution is simply gone, and the next mapper re-derives an answer
# this ledger exists to have already given. The measured cost of skipping exactly this on
# source-domains was 2,293 outcomes recorded as 65, a 97% loss.
#
# A NAMED SYSTEM MUTEX, not a lock file: the OS releases it if a writer dies, so a crashed lane cannot
# wedge the ledger for every future run. The WHOLE read-modify-write happens inside it - locking only
# the write would still lose the row that was read before the lock was taken.
# ---------------------------------------------------------------------------------------------------
$script:LOCK_TIMEOUT_MS = 15000
# 15000 in production. Only a writer this file's SELF-TEST launched waits longer, as a hang guard: whether the
# lock loses a row is the test's question, and a starved box must not answer it (lib\ledger-fixture.ps1).
$script:LOCK_TIMEOUT_MS = Get-TcLedgerFixtureLockMs $script:LOCK_TIMEOUT_MS

function Invoke-Locked {
  param([scriptblock]$Body, [string]$Path)
  # Named after the store, so a scratch store in a fixture cannot block the live one.
  $key = 'Global\tc-ingredient-resolutions-' + ([Math]::Abs($Path.ToLower().GetHashCode())).ToString()
  $mx = New-Object System.Threading.Mutex($false, $key)
  $held = $false
  try {
    Wait-TcLedgerFixtureGate   # returns at once unless the self-test launched this writer; its barrier sits here, after start-up
    try { $held = $mx.WaitOne($script:LOCK_TIMEOUT_MS) }
    catch [System.Threading.AbandonedMutexException] { $held = $true }   # a dead writer, not a wedge
    if (-not $held) {
      # Could-not-write is never a silent pass: say so and exit non-zero so the caller sees it.
      Write-Output ("ingredient-resolutions: could not take the write lock within {0} ms - resolution NOT recorded" -f $script:LOCK_TIMEOUT_MS)
      exit 2
    }
    & $Body
  } finally {
    if ($held) { $mx.ReleaseMutex() | Out-Null }
    $mx.Dispose()
  }
}

if ($runSelfTest) {
  $bad=0
  function T([string]$n,[bool]$ok,[string]$got){ if($ok){Write-Output ("  ok    "+$n)}else{Write-Output ("  X     "+$n+"   got: "+$got); $script:bad++} }
  T 'case and punctuation are normalised away' ((Get-TermKey '  Shaved Beef Steak, ') -eq 'shaved beef steak') (Get-TermKey '  Shaved Beef Steak, ')
  T 'MUST FIRE  a DIFFERENT ingredient does not collide with a shorter one' ((Get-TermKey 'beef steak') -ne (Get-TermKey 'shaved beef steak')) 'collided'
  T 'internal whitespace collapses' ((Get-TermKey 'sour    cream') -eq 'sour cream') (Get-TermKey 'sour    cream')
  T 'an empty term keys to empty rather than throwing' ((Get-TermKey '') -eq '') 'threw'
  $tmp = Join-Path $env:TEMP ('ir-' + [guid]::NewGuid().ToString('N') + '.json')
  try {
    ([pscustomobject]@{ resolutions=@([pscustomobject]@{key='sumac';item_id='sumac';bid_exists=$false}) } | ConvertTo-Json -Depth 5) | Set-Content $tmp -Encoding utf8
    $b = @((Read-Store $tmp).Rows)
    T 'the store round-trips' ($b.Count -eq 1 -and $b[0].key -eq 'sumac') ([string]$b.Count)
    T 'MUST FIRE  bid_exists=false survives the round-trip as FALSE, not as absent' ($b[0].bid_exists -eq $false) ([string]$b[0].bid_exists)
    # CLEAN TWIN: -Query still answers from the ledger (2026-09-11). The read feeding -Query and the listing
    # moved below -Record and -Invalidate, which no longer read before their lock; a read placed wrongly or
    # dropped would leave -Query saying `no prior resolution` for a term the store holds. A real child, as callers do.
    $qLines = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Query -Term 'Sumac' -Json -Store $tmp
    $qCode = $LASTEXITCODE
    $qRow = $null; try { $qRow = ((@($qLines) -join "`n") | ConvertFrom-Json) } catch { $qRow = $null }
    T 'CLEAN TWIN -Query still answers from the ledger now that the read feeding it sits below -Record and -Invalidate' `
      ($qCode -eq 3 -and $null -ne $qRow -and [string]$qRow.item_id -eq 'sumac') ("exit $qCode out: " + (@($qLines) -join ' / '))
    # CHANGED 2026-09-11: this used to assert "a missing store reads as EMPTY", which is the defect. A missing
    # store now reads as what it is, and each caller decides what absent means (see Read-Store's header).
    $nope = Read-Store (Join-Path $env:TEMP ('nope-ir-' + [guid]::NewGuid().ToString('N') + '.json')) -WaitMs 100
    T 'a missing store reads as ABSENT with no rows, and says so, rather than as an empty ledger' `
      ($nope.State -eq 'absent' -and @($nope.Rows).Count -eq 0 -and $nope.Why) ('state=' + $nope.State)

    # MUST FIRE: CONCURRENT WRITERS DO NOT LOSE ROWS (added 2026-08-24, D9's phase-1 obligation).
    #
    # The v3 daemon runs the MAP LANE AT CAP 2 and holds the pen itself, so two mapper completions can
    # land a -Record at the same instant. Without the mutex both read the same rows, both add their
    # own, and the last write wins - the measured cost of exactly this on source-domains was 2,293
    # outcomes recorded as 65, a 97% loss.
    #
    # A FIXTURE THAT CANNOT LOSE A ROW PROVES NOTHING, and the first build of this one could not.
    # MEASURED 2026-08-24: four Start-Job children each spawning their own powershell.exe passed
    # WITH THE LOCK NEUTERED, because process startup costs ~1 s and the read-modify-write costs
    # ~2 ms - the four writers never overlapped, so there was no race to lose. Two things fix that,
    # and both are needed:
    #   1. A START BARRIER. Every writer waits inside Invoke-Locked, after its own start-up, until all four
    #      are there, so they ask for the lock together (THE BARRIER IS INSIDE THE WRITER, below).
    #   2. A STORE BIG ENOUGH TO BE SLOW. The scratch store is seeded with 400 rows, which puts the
    #      read-modify-write in the tens of milliseconds - wide enough for four barriered writers to
    #      sit inside it at once.
    # With both, the neutered run loses rows and the locked run loses none.
    # HOW OFTEN, measured 2026-09-11 with WaitOne and ReleaseMutex both skipped in a temp mirror. With the
    # barrier in a Start-Job child AHEAD of each writer's start-up, the concurrency cases below went red in
    # 3 of 6 runs beside 32 CPU burners (timestamp barrier), 3 of 5 without them (ready/go), and 9 of 10
    # beside a run-gates loop. With the barrier INSIDE the writer (below) they went red in 20 of 20, and the
    # locked suite passed 20 of 20 in the same iterations. Load uncontrolled throughout: other sessions' gate
    # runs, and 32 CPU burners from another session after 11:47. Harness: a scratch harness running each
    # arm's -SelfTest back to back, at 00c3527d7 plus this change. Four writers
    # and not two on purpose: the PS 5.1 collection traps say a fixture over a collection uses at
    # least three elements, and losing one of four is unmistakable where losing one of two reads as a
    # coin flip.
    $ctmp = Join-Path $env:TEMP ('ir-conc-' + [guid]::NewGuid().ToString('N') + '.json')
    $seed = @(1..400 | ForEach-Object {
      [pscustomobject]@{ key="seed $_"; term="seed $_"; item_id="seed-$_"; bid_exists=$true
                         evidence='a row that must survive four concurrent writers'; by='fixture'
                         at='2026-08-24T00:00:00' } })
    ([pscustomobject]@{ count=$seed.Count; resolutions=$seed } | ConvertTo-Json -Depth 6) | Set-Content $ctmp -Encoding utf8
    # THE BARRIER IS INSIDE THE WRITER, AFTER ITS START-UP (2026-09-11). It used to sit in a Start-Job child
    # BEFORE `& powershell -File` - first a UTC instant, then a ready/go handshake - and either way each writer
    # still paid its own powershell.exe start-up, about a second and variable, AFTER it was released. That
    # spread the four further than any barrier closed, so a disabled lock was caught most runs and not all.
    # Now the writers are plain processes that wait on lib\ledger-fixture.ps1's kernel event inside
    # Invoke-Locked, immediately before WaitOne, so start-up is spent first and all four ask for the lock
    # together. The same library keeps every writer's exit code, stdout and stderr and whether it was launched,
    # reached the barrier and exited - a writer that could not run is named as that, never read as the lock
    # losing a row - and gives the writers a hang-guard lock wait in place of the production 15 s.
    # WHAT THIS GAVE UP: each writer's own lock-free read at start-up now happens before the barrier, so this
    # case no longer lands one on a sibling's replace by chance. The held-reader case below drives that
    # collision on purpose, every run.
    $argSets = New-Object System.Collections.Generic.List[object]
    foreach ($i in 1..4) { $argSets.Add([string[]]@('-Record', '-Term', "conc term $i", '-ItemId', "conc-$i", '-BidExists', '-By', 'fixture', '-Store', $ctmp)) }
    $run = Invoke-TcLedgerWriters -Script $PSCommandPath -ArgSets $argSets.ToArray()
    $writers = @($run.writers)
    Write-Output ("  info  barrier: {0} of 4 writers were at the barrier when released ({1} ms)" -f $run.ready_at_go, $run.go_ms)
    $got = @((Read-Store $ctmp).Rows)
    $conc = @(@($got | Where-Object { [string]$_.key -like 'conc term *' } | ForEach-Object { [string]$_.key }) | Sort-Object)
    $seedKept = @($got | Where-Object { [string]$_.key -like 'seed *' }).Count
    Remove-Item $ctmp -Force -ErrorAction SilentlyContinue
    $ran = @($writers | Where-Object { $_.ran })
    $claimed = @(@($writers | Where-Object { $_.ran -and $_.exit -eq 0 } | ForEach-Object { 'conc term ' + $_.n }) | Sort-Object)
    $why = Format-TcWriterTrouble $writers
    T 'every writer RAN - launched, at the barrier when the four were released together, and exited (one that could not run is named here, never read as a lost row)' ($ran.Count -eq 4) ("ran " + $ran.Count + " of 4" + $why)
    T 'MUST FIRE  4 barriered concurrent -Record calls all land (the map lane writes 2-wide and the daemon holds the pen)' `
      (@($conc).Count -eq 4 -and ($conc -join ',') -eq 'conc term 1,conc term 2,conc term 3,conc term 4') `
      ("kept " + @($conc).Count + " of 4: " + ($conc -join ',') + $why)
    # THE MUTEX'S OWN GUARANTEE, stated apart from the one above. "All four land" also fails when a writer
    # REFUSES, which is loud and costs nothing silently; this one fails only when a writer said it recorded
    # and the row is not there (or the reverse). A refusal is counted as a refusal, never as a lost row.
    T 'MUST FIRE  and no write was lost SILENTLY - the rows that landed are exactly the writers that exited 0' `
      ($ran.Count -eq 4 -and ($claimed -join ',') -eq ($conc -join ',')) `
      ("landed [" + ($conc -join ',') + "], exited 0 [" + ($claimed -join ',') + "]" + $why)
    T 'MUST FIRE  and not one of the 400 rows already in the ledger was dropped on the way' `
      ($seedKept -eq 400) ("kept $seedKept of 400")

    # MUST FIRE: A -Record MADE WHILE A LOCK-FREE READER HOLDS THE LEDGER LANDS (2026-09-11).
    # The run-gates red at 839c5e666, made deterministic. The mutex serialises WRITERS and nothing serialises
    # READERS; Get-Content and Read-TextFile open a file shared ReadWrite but not Delete, and a bare
    # `Move-Item -Force` over a file held that way fails inside the lock with "Cannot create a file when that
    # file already exists". Measured under 32 CPU burners with every writer's output kept, that was the whole
    # of the failure: the writer held the lock, waited milliseconds, and lost the write at the replace. Here
    # the parent holds exactly that handle until the child has written its .tmp, 400 ms longer, then lets go.
    $htmp = Join-Path $env:TEMP ('ir-hold-' + [guid]::NewGuid().ToString('N') + '.json')
    $hseed = @(1..3 | ForEach-Object { [pscustomobject]@{ key="seed $_"; term="seed $_"; item_id="seed-$_"; bid_exists=$true; evidence='fixture'; by='fixture'; at='2026-09-11T00:00:00' } })
    ([pscustomobject]@{ count=3; resolutions=$hseed } | ConvertTo-Json -Depth 6) | Set-Content $htmp -Encoding utf8
    $hOutF = [IO.Path]::GetTempFileName(); $hErrF = [IO.Path]::GetTempFileName()
    $hold = New-Object IO.FileStream($htmp, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    $sawTmp = $false
    try {
      $hp = Start-Process -FilePath 'powershell' -PassThru -NoNewWindow `
            -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-Record','-Term','heldterm','-ItemId','held-1','-By','fixture','-Store',$htmp) `
            -RedirectStandardOutput $hOutF -RedirectStandardError $hErrF
      $null = $hp.Handle   # cache the handle now, or ExitCode reads empty once the process is gone
      $hsw = [Diagnostics.Stopwatch]::StartNew()
      while (-not (Test-Path -LiteralPath ($htmp + '.tmp')) -and -not $hp.HasExited -and $hsw.Elapsed.TotalSeconds -lt 120) { Start-Sleep -Milliseconds 10 }
      $sawTmp = Test-Path -LiteralPath ($htmp + '.tmp')
      Start-Sleep -Milliseconds 400
    } finally { $hold.Dispose() }
    [void]$hp.WaitForExit(120000)
    $hOut = [string](Get-Content $hOutF -Raw); if ($null -eq $hOut) { $hOut = '' }
    Remove-Item $hOutF, $hErrF -Force -ErrorAction SilentlyContinue
    $hRows = @((Read-Store $htmp).Rows)
    # ONE-TOKEN VALUES ONLY: Start-Process joins -ArgumentList with spaces and quotes nothing, so a term with a
    # space arrives as two arguments. Its first cut passed 'held term' and recorded 'held'.
    $heldLanded = (@($hRows | Where-Object { [string]$_.key -eq 'heldterm' }).Count -eq 1)
    Remove-Item $htmp, ($htmp + '.tmp') -Force -ErrorAction SilentlyContinue
    T 'MUST FIRE  a -Record made while a lock-free reader holds the ledger open LANDS once the reader lets go (a bare Move-Item lost it inside the lock)' `
      ($sawTmp -and $hp.ExitCode -eq 0 -and $heldLanded -and @($hRows).Count -eq 4) `
      ("saw_tmp=$sawTmp exit=" + $hp.ExitCode + " landed=$heldLanded rows=" + @($hRows).Count + " out=" + $hOut.Trim())
  } finally { if (Test-Path $tmp) { Remove-Item $tmp -Force } }
  # ---- AN UNWRITABLE STORE MUST NOT REPORT SUCCESS (2026-08-31) ----
  # Save-Rows used to let a failed Set-Content fall through, so -Invalidate printed "invalidated N
  # row(s)" and exited 0 while the ledger on disk was untouched, and the only trace was a raw error on
  # stderr. Driven as a real child process because the exit code IS the finding, and because the
  # leaked stderr is what killed run-gates.
  $missing = Join-Path $tmp 'no-such-dir\ledger.json'
  $errF = [IO.Path]::GetTempFileName(); $outF = [IO.Path]::GetTempFileName()
  $pi = Start-Process -FilePath 'powershell' -Wait -PassThru -NoNewWindow `
        -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath,
                        '-Invalidate','-ItemId','apples','-Store',$missing) `
        -RedirectStandardError $errF -RedirectStandardOutput $outF
  # COALESCED TO '' BEFORE ANY .Trim(), and the neuter is why. Get-Content -Raw on an EMPTY file
  # returns $null, and an empty stdout is exactly what the DEFECT produces - so the diagnostic
  # argument threw "You cannot call a method on a null-valued expression" on the one run where these
  # cases were supposed to go red. The suite died at this line and printed no failures at all: a test
  # whose FAILURE path crashes reports nothing, which is indistinguishable from a test that passed.
  $sOut = [string](Get-Content $outF -Raw); if ($null -eq $sOut) { $sOut = '' }
  $sErr = [string](Get-Content $errF -Raw); if ($null -eq $sErr) { $sErr = '' }
  Remove-Item $errF, $outF -Force -ErrorAction SilentlyContinue
  # NAMED HONESTLY: the first two held BEFORE this fix too (the throw was already terminating), so they
  # are the standing contract, not the proof. The two below them are the ones that discriminate.
  T '-Invalidate on an unwritable store exits non-zero' ($pi.ExitCode -ne 0) ("exit " + $pi.ExitCode)
  T '...and does NOT claim it invalidated anything' (-not ($sOut -match 'invalidated \d+ row')) $sOut
  T '...and says it could not write, on STDOUT where a caller reads it' ($sOut -match 'COULD NOT WRITE') $sOut
  T 'MUST FIRE  ...and leaks NOTHING to stderr (one noisy child kills ops\run-gates.ps1)' `
    ([string]::IsNullOrWhiteSpace($sErr)) $sErr

  # ---- A COULD-NOT-READ MUST NOT SETTLE THE LEDGER (2026-09-11) ----
  # Save-Rows replaces the ledger by Move-Item -Force, and a separate reader saw it ABSENT on 4,024 of 109,718
  # polls across 1,500 replaces. Read-Store answered @() for that and for any parse failure, so -Query said "no
  # prior resolution" with the ruling on disk, and the in-lock re-read handed Save-Rows an empty ledger to write
  # the new row over. Children run as real processes because the exit code and the stdout/stderr split ARE the
  # contract, the same reason the unwritable-store cases above are driven that way.
  function Invoke-IrChild([string]$Script, [string[]]$ChildArgs) {
    $eF = [IO.Path]::GetTempFileName(); $oF = [IO.Path]::GetTempFileName()
    $cp = Start-Process -FilePath 'powershell' -Wait -PassThru -NoNewWindow `
            -ArgumentList (@('-NoProfile','-ExecutionPolicy','Bypass','-File',$Script) + $ChildArgs) `
            -RedirectStandardError $eF -RedirectStandardOutput $oF
    $o = [string](Get-Content $oF -Raw); if ($null -eq $o) { $o = '' }
    $e = [string](Get-Content $eF -Raw); if ($null -eq $e) { $e = '' }
    Remove-Item $eF, $oF -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{ Code = $cp.ExitCode; Out = $o; Err = $e }
  }
  $irDir = Join-Path $env:TEMP ('ir-read-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $irDir -Force | Out-Null
  $irEnc = New-Object Text.UTF8Encoding($false)
  $irThree = '{"count":3,"resolutions":[{"key":"sumac","item_id":"sumac","bid_exists":true},{"key":"za atar","item_id":"za-atar","bid_exists":true},{"key":"labneh","item_id":"labneh","bid_exists":false}]}'
  try {
    # (1) THE WINDOW, HELD IN PROCESS: the ledger is absent at the first look and -OnWait puts it back on the
    #     first wait, so the read provably saw the window and provably outlived it. Never raced.
    $irWin = Join-Path $irDir 'window.json'
    $sa = $null
    try { $sa = Read-Store $irWin -WaitMs 5000 -OnWait ({ param($n, $s) if ($n -eq 1) { [IO.File]::WriteAllText($irWin, $irThree, $irEnc) } }.GetNewClosure()) } catch { $sa = $null }
    T 'MUST FIRE  a ledger ABSENT at the first look (the Move-Item replace window) reads all 3 rows, not an empty ledger' `
      ($null -ne $sa -and $sa.State -eq 'ok' -and $sa.Waits -ge 1 -and @($sa.Rows).Count -eq 3) `
      ($(if ($sa) { 'state=' + $sa.State + ' waits=' + $sa.Waits + ' rows=' + @($sa.Rows).Count } else { 'threw' }))

    # (2) -Record INSIDE THE LOCK against a ledger it cannot read. The bytes on disk are the finding.
    $irTrunc = Join-Path $irDir 'truncated.json'
    [IO.File]::WriteAllText($irTrunc, $irThree.Substring(0, 120), $irEnc)
    $md5Trunc = (Get-FileHash $irTrunc -Algorithm MD5).Hash
    $cr = Invoke-IrChild $PSCommandPath @('-Record','-Term','cumin','-ItemId','cumin','-BidExists','-By','fixture','-Store',$irTrunc,'-ReadWaitMs','200')
    T 'MUST FIRE  -Record against a ledger it cannot READ writes NOTHING - the bytes are unchanged, so no row is wiped' `
      ((Get-FileHash $irTrunc -Algorithm MD5).Hash -eq $md5Trunc) ('the ledger changed; the child said: ' + $cr.Out)
    T '...and exits non-zero' ($cr.Code -ne 0) ('exit ' + $cr.Code)
    T '...and says so on STDOUT, naming the failed read, and claims no resolution' `
      (($cr.Out -match 'COULD NOT WRITE') -and ($cr.Out -match 'could not READ') -and -not ($cr.Out -match 'cumin -> cumin')) $cr.Out
    T 'MUST FIRE  ...and leaks NOTHING to stderr (one noisy child kills ops\run-gates.ps1)' ([string]::IsNullOrWhiteSpace($cr.Err)) $cr.Err

    # (3) -Invalidate, the other writer, against the same unreadable ledger
    $ci = Invoke-IrChild $PSCommandPath @('-Invalidate','-ItemId','sumac','-Store',$irTrunc,'-ReadWaitMs','200')
    T 'MUST FIRE  -Invalidate against a ledger it cannot READ writes NOTHING either, exits non-zero and says why on stdout' `
      ((Get-FileHash $irTrunc -Algorithm MD5).Hash -eq $md5Trunc -and $ci.Code -ne 0 -and ($ci.Out -match 'could not READ') -and -not ($ci.Out -match 'invalidated \d+ row')) `
      ('exit ' + $ci.Code + ': ' + $ci.Out)
    T '...and leaks NOTHING to stderr' ([string]::IsNullOrWhiteSpace($ci.Err)) $ci.Err

    # (4) -Query is a CONSUMER: unreadable and settled-absent are both exit 2, never "no prior resolution"
    #     The refusal names the phrase it is NOT ("not the same as no prior resolution"), so these match the
    #     defect's exact answer, `no prior resolution for '<key>'`, and not the bare phrase - the first cut of
    #     this fixture matched the refusal's own wording and failed a correct run.
    $cq = Invoke-IrChild $PSCommandPath @('-Query','-Term','sumac','-Store',$irTrunc,'-ReadWaitMs','200')
    T 'MUST FIRE  -Query on an unreadable ledger is exit 2 COULD NOT READ, never "no prior resolution"' `
      ($cq.Code -eq 2 -and ($cq.Out -match 'COULD NOT READ') -and -not ($cq.Out -match "no prior resolution for '") -and [string]::IsNullOrWhiteSpace($cq.Err)) `
      ('exit ' + $cq.Code + ': ' + $cq.Out + $cq.Err)
    $cqa = Invoke-IrChild $PSCommandPath @('-Query','-Term','sumac','-Store',(Join-Path $irDir 'never.json'),'-ReadWaitMs','200')
    T 'MUST FIRE  -Query on a ledger that STAYS absent is exit 2 as well - a consumer never reads absence as no ruling' `
      ($cqa.Code -eq 2 -and ($cqa.Out -match 'COULD NOT READ') -and -not ($cqa.Out -match "no prior resolution for '") -and [string]::IsNullOrWhiteSpace($cqa.Err)) `
      ('exit ' + $cqa.Code + ': ' + $cqa.Out + $cqa.Err)

    # (5) THE LIVE LEDGER ABSENT. Driven from a MIRROR of this script and its two libraries, so the default
    #     store path is a scratch copy of the live layout and the real ledger is never touched.
    $irMirror = Join-Path $irDir 'mirror'
    New-Item -ItemType Directory -Force -Path (Join-Path $irMirror 'lib'), (Join-Path $irMirror 'meal-prep\pipeline'), (Join-Path $irMirror 'meal-prep\db') | Out-Null
    # EVERY LIBRARY THIS SCRIPT DOT-SOURCES, read off its own source rather than listed by hand. The first cut
    # listed two, and the day lib\atomic-write.ps1 joined them the mirrored child could not load and this case
    # went red for a reason that had nothing to do with what it tests. A pattern that matched nothing would
    # leave the mirror with no libraries, and the child would fail loudly rather than pass.
    $irLibs = @([regex]::Matches([IO.File]::ReadAllText($PSCommandPath), '(?m)^\. \(Join-Path \$repo ''lib\\([\w.-]+\.ps1)''\)') | ForEach-Object { $_.Groups[1].Value })
    foreach ($irLib in $irLibs) { Copy-Item (Join-Path $repo ('lib\' + $irLib)) -Destination (Join-Path $irMirror 'lib') }
    Copy-Item $PSCommandPath -Destination (Join-Path $irMirror 'meal-prep\pipeline')
    $mirrorLive = Join-Path $irMirror 'meal-prep\db\ingredient-resolutions.json'
    $cl = Invoke-IrChild (Join-Path $irMirror 'meal-prep\pipeline\ingredient-resolutions.ps1') @('-Record','-Term','cumin','-ItemId','cumin','-By','fixture','-ReadWaitMs','200')
    T 'MUST FIRE  -Record with the LIVE ledger absent REFUSES, rather than starting a one-row ledger the 07:00 bot would commit' `
      ($cl.Code -ne 0 -and ($cl.Out -match 'COULD NOT WRITE') -and ($cl.Out -match 'LIVE ledger') -and -not (Test-Path $mirrorLive) -and [string]::IsNullOrWhiteSpace($cl.Err)) `
      ('exit ' + $cl.Code + ' created=' + (Test-Path $mirrorLive) + ': ' + $cl.Out + $cl.Err)

    # (6) CLEAN TWIN - the fresh-ledger road the fix was most likely to break on its way past
    $irNew = Join-Path $irDir 'new-ledger.json'
    $cn = Invoke-IrChild $PSCommandPath @('-Record','-Term','cumin','-ItemId','cumin','-BidExists','-By','fixture','-Store',$irNew,'-ReadWaitMs','200')
    $newRows = @((Read-Store $irNew -WaitMs 0).Rows)
    T 'CLEAN TWIN a SCRATCH -Store that does not exist yet is still created by -Record, holding exactly the new row' `
      ($cn.Code -eq 0 -and @($newRows).Count -eq 1 -and [string]$newRows[0].key -eq 'cumin') ('exit ' + $cn.Code + ' rows=' + @($newRows).Count + ': ' + $cn.Out)

    # (7) CLEAN TWIN - a readable ledger still answers -Query with its prior ruling
    $irGood = Join-Path $irDir 'good.json'
    [IO.File]::WriteAllText($irGood, $irThree, $irEnc)
    $cg = Invoke-IrChild $PSCommandPath @('-Query','-Term','labneh','-Store',$irGood,'-ReadWaitMs','200')
    T 'CLEAN TWIN -Query on a readable ledger still finds the prior ruling (exit 3) and names it' `
      ($cg.Code -eq 3 -and ($cg.Out -match 'labneh')) ('exit ' + $cg.Code + ': ' + $cg.Out)
  } finally { Remove-Item $irDir -Recurse -Force -ErrorAction SilentlyContinue }

  if ($bad -gt 0) { Write-Output ("ingredient-resolutions SELF-TEST FAIL ({0})" -f $bad); exit 2 }
  Write-Output 'ingredient-resolutions SELF-TEST PASS'
  Exit-Guard -Name 'ingredient-resolutions' -Summary 'selftest pass' -Code 0
}

function Save-Rows { param($R)
  $doc = [pscustomobject]@{
    _doc='Ingredient string -> commodity id, plus whether a bid is wired. Consulted by the mapper before it reasons and before it asks the commodity-registrar. IDENTITY ONLY - never a price.'
    _rule='Invalidated by any registrar ruling that changes a commodity id. bid_exists is a fact about db\ingredients.json wiring, refreshed by the mapper, and is what lets a recipe hold at `mapped` instead of dying at the audit.'
    updated=(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'); count=@($R).Count; resolutions=@($R) }
  # NO -ErrorAction HERE, DELIBERATELY, and it was measured rather than assumed. $ErrorActionPreference
  # is 'Stop' at the top of this file, so a failed write is ALREADY terminating: an unwritable store has
  # always exited non-zero and has never written a half-file or claimed success. The first cut of the
  # 2026-08-31 fix added -ErrorAction Stop and a comment saying it stopped a silent fall-through; running
  # all four combinations against an unwritable store proved the flags change nothing at all. Dead code
  # that reads like a second safeguard teaches the next reader that two things defend this when only one
  # does, so it is gone. What was actually wrong is at the -Record catch below.
  #
  # THROUGH lib\atomic-write.ps1, NOT Set-Content + Move-Item (2026-09-11). The mutex serialises WRITERS
  # and nothing serialises READERS: a lock-free read holding this file open made a bare Move-Item fail
  # INSIDE the lock, which is how run-gates read "kept 3 of 4" at 839c5e666. It still throws when a
  # reader outlasts its retry budget, so the catch below still says COULD NOT WRITE.
  [void](Write-TcAtomicFile -Path $Store -Text ($doc | ConvertTo-Json -Depth 6)) }

if ($runRecord) {
  $k = Get-TermKey $Term
  if (-not $k) { Write-Output 'ingredient-resolutions: -Record needs -Term'; exit 1 }
  # READ INSIDE THE LOCK, AND ONLY HERE. A snapshot read before the mutex was taken would keep the exact
  # race the mutex exists to close - a writer that merges into a snapshot older than its own turn drops
  # whatever landed in between. -Record and -Invalidate never used one, yet until 2026-09-11 the script read
  # one first, holding the file open for nothing while a sibling replaced it (the reader side of 9f3ca3cbd).
  # The read the query verbs need now sits below -Invalidate.
  try {
    Invoke-Locked -Path $Store -Body {
      $st = Read-Store $Store
      # A COULD-NOT-READ REFUSES THE WRITE (2026-09-11). Save-Rows writes the WHOLE ledger, so merging into a
      # read that failed would replace every row on disk with this one. The throw lands in the catch below:
      # exit 1, one line on stdout, nothing on stderr, and the file untouched.
      if ($st.State -eq 'unreadable') { throw ('could not READ the existing ledger, so writing now would replace every row it holds with this one - nothing was written. ' + $st.Why) }
      # A settled ABSENT is a NEW ledger only for a scratch -Store. The lock rules out this script's own replace
      # window and the wait rules out a foreign one, but the LIVE ledger is tracked in git: restarting it with
      # one row is a wipe the 07:00 bot would commit with everything else, so that refuses too.
      if ($st.State -eq 'absent' -and $storeIsLive) { throw ('the LIVE ledger is absent, and git tracks it, so this is not a fresh estate - nothing was written. ' + $st.Why) }
      $fresh = @($st.Rows)
      $keep = @($fresh | Where-Object { [string]$_.key -ne $k })
      $row = [pscustomobject]@{ key=$k; term=$Term; item_id=$ItemId; bid_exists=$runBid; evidence=$Evidence; by=$By; at=(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') }
      Save-Rows @($keep + $row)
    }
  } catch {
    # THE REAL DEFECT (2026-08-31): the failure was always LOUD, but it was loud in the wrong channel.
    # An unwritable store threw an unhandled .NET error straight onto STDERR, so the exit code was
    # right and the message was unreadable to every caller that reads stdout - and rebid-ingredient's
    # Invoke-MemoryInvalidation deliberately does NOT redirect a child's stderr, because doing so
    # under EAP=Stop is itself a terminating throw. Worse, ops\run-gates.ps1 runs each self-test as a
    # native child under EAP=Stop, so that one leaked line was a TERMINATING error for the gate: the
    # whole suite died on it and reported nothing about the other 152 self-tests, all of which passed.
    # One noisy negative fixture blinded the change-time gate completely.
    Write-Output ("ingredient-resolutions: COULD NOT WRITE the store at {0} - {1}" -f $Store, $_.Exception.Message)
    exit 1
  }
  Write-Output ("ingredient-resolutions: {0} -> {1}{2}" -f $k, $(if($ItemId){$ItemId}else{'(null)'}), $(if($runBid){' [bid wired]'}else{' [NO BID - recipe must hold at mapped]'}))
  exit 0
}
if ($runInv) {
  if (-not $ItemId) { Write-Output 'ingredient-resolutions: -Invalidate needs -ItemId'; exit 1 }
  $script:invalidated = 0
  try {
    Invoke-Locked -Path $Store -Body {
      $st = Read-Store $Store
      # The same two refusals as -Record, for the same reasons: from a failed read, the rows that "survive" this
      # invalidation are none, and Save-Rows would write that; and the live ledger's absence is not a fresh estate.
      if ($st.State -eq 'unreadable') { throw ('could not READ the existing ledger, so writing now would replace every row it holds with none - nothing was written. ' + $st.Why) }
      if ($st.State -eq 'absent' -and $storeIsLive) { throw ('the LIVE ledger is absent, and git tracks it, so this is not a fresh estate - nothing was written. ' + $st.Why) }
      $fresh = @($st.Rows)
      $keep = @($fresh | Where-Object { [string]$_.item_id -ne $ItemId })
      $script:invalidated = @($fresh).Count - @($keep).Count
      Save-Rows $keep
    }
  } catch {
    # Same as the -Record path above: a clean line on stdout instead of a raw error on stderr.
    Write-Output ("ingredient-resolutions: COULD NOT WRITE the store at {0} - {1}" -f $Store, $_.Exception.Message)
    exit 1
  }
  Write-Output ("ingredient-resolutions: invalidated {0} row(s) for item_id '{1}'" -f $script:invalidated, $ItemId)
  exit 0
}
# The read the query verbs answer from. Below -Record and -Invalidate on purpose: a writer reads only inside its lock.
# THE READ-ONLY MODES ARE CONSUMERS (2026-09-11). A settled absence or an unreadable ledger is exit 2 with one line
# on stdout (a JSON object under -Json) and never "no prior resolution" or "0 resolution(s)" - the answers a mapper
# acts on by re-deriving a ruling the ledger already holds. Read here and not at the top, so a writer never pays
# for a read it does not use: its own read happens inside the lock.
$st = Read-Store $Store
if ($st.State -ne 'ok') {
  $msg = ("ingredient-resolutions: COULD NOT READ the store at {0} ({1}) - that is not the same as no prior resolution. {2}" -f $Store, $st.State, $st.Why)
  if ($runJson) { ([pscustomobject]@{ error = $msg } | ConvertTo-Json -Compress) } else { Write-Output $msg }
  exit 2
}
$rows = @($st.Rows)
if ($runQuery) {
  $k = Get-TermKey $Term
  $r = @($rows | Where-Object { [string]$_.key -eq $k })[0]
  if (-not $r) { if($runJson){ '{"found":false}' } else { Write-Output ("ingredient-resolutions: no prior resolution for '{0}'" -f $k) }; exit 0 }
  if ($runJson) { ($r | ConvertTo-Json -Depth 4); exit 3 }
  Write-Output ("ingredient-resolutions: '{0}' -> {1}  bid_exists={2}  (by {3} on {4})" -f $r.key, $(if($r.item_id){$r.item_id}else{'(null)'}), $r.bid_exists, $r.by, $r.at)
  if ($r.evidence) { Write-Output ("  evidence: " + $r.evidence) }
  exit 3
}
if ($runJson) { ([pscustomobject]@{ count=@($rows).Count; resolutions=@($rows) } | ConvertTo-Json -Depth 6); exit 0 }
Write-Output ("ingredient-resolutions: {0} resolution(s)" -f @($rows).Count)
foreach ($r in @($rows | Sort-Object key)) { Write-Output ("  {0,-34} {1,-28} {2}" -f $r.key, $(if($r.item_id){$r.item_id}else{'(null)'}), $(if($r.bid_exists){'bid'}else{'NO BID'})) }
exit 0
