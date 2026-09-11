# source-domains.ps1
# ---------------------------------------------------------------------------------------------------
# What the pipeline has learned about recipe publishers, so it stops re-learning it every run.
#
# WHAT THIS REPLACES. A blocked-domain list existed as PROSE, duplicated verbatim in two agent files
# (.claude\agents\recipe-sourcer.md and recipe-source-qa.md), with nothing keeping them in sync and
# nothing able to update them. On 2026-08-16 `thespruceeats` was on that list in BOTH files and a
# sourcer sourced from it anyway - the recipe 404'd and died `rejected-unreadable`, after paying for
# the search and the fetch. `themediterraneandish` 404'd the same run and was on neither list, so the
# next run would have tried it again. Prose in a prompt is guidance; this file is data the pipeline
# writes to itself.
#
#   .\source-domains.ps1 -Record -Domain x.com -Outcome ok|fail|404|blocked [-HasJsonLd] [-Note '...']
#   .\source-domains.ps1 -Query -Domain x.com          exit 3 if the domain is blocked, 2 when the ledger cannot be read
#   .\source-domains.ps1 -Brief                        the block for a sourcer prompt (exit 2 when the ledger cannot be read)
#   .\source-domains.ps1 -SelfTest
#
# STATUS RULE, inherited from the store-carriage discipline: one failure is a fact about one URL, not
# about a publisher. A single 404 makes a domain `unreliable`, never `blocked`. Only a repeated
# pattern earns `blocked`, and the counts stay in the row so the judgment is auditable, not folkloric.
# ---------------------------------------------------------------------------------------------------
param(
  [switch]$Record, [switch]$Query, [switch]$Brief, [switch]$List, [switch]$SelfTest,
  [string]$Domain = '', [string]$Outcome = '', [string]$Note = '', [switch]$HasJsonLd,
  [string]$Store = '', [switch]$Json,
  [int]$ReadWaitMs = 3000     # the settled-read bound; lib\json-io.ps1 records where 3000 came from. Fixtures shorten it.
)
$ErrorActionPreference = 'Stop'
$runRecord=[bool]$Record; $runQuery=[bool]$Query; $runBrief=[bool]$Brief; $runList=[bool]$List
$runSelfTest=[bool]$SelfTest; $runJson=[bool]$Json; $runHasJsonLd=[bool]$HasJsonLd

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp   = Split-Path -Parent $here
$repo = Split-Path -Parent $mp
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\atomic-write.ps1')   # Write-TcAtomicFile: a lock-free reader must not cost a writer its write
. (Join-Path $repo 'lib\event-bus.ps1')      # Write-TcEvent: a refused write reaches the digest even when the caller discards our stdout
. (Join-Path $repo 'lib\ledger-fixture.ps1') # Wait-TcLedgerFixtureGate: inert unless this file's own self-test launched the writer
. (Join-Path $repo 'lib\json-io.ps1')        # Read-JsonFileSettled: the writer's replace window is waited out, never read as an empty ledger
# THE LIVE LEDGER IS TRACKED IN GIT, so it is in every checkout and its absence is never a fresh estate. A scratch
# store named by -Store can be. The write path needs to know which one it holds.
$liveStore = Join-Path $mp 'db\source-domains.json'
if (-not $Store) { $Store = $liveStore }
$storeIsLive = [string]::Equals([IO.Path]::GetFullPath($Store), [IO.Path]::GetFullPath($liveStore), [StringComparison]::OrdinalIgnoreCase)

$script:BLOCK_AFTER = 3   # consecutive-ish failures with no success before a domain is called blocked

function Get-Host2 {
  param([string]$D)
  if (-not $D) { return '' }
  $d = $D.Trim().ToLower()
  $d = $d -replace '^https?://', ''
  $d = ($d -split '/')[0]
  $d = $d -replace '^www\.', ''
  return $d
}

function Get-Status {
  param([int]$Ok, [int]$Fail, [bool]$ForcedBlock)
  if ($ForcedBlock) { return 'blocked' }
  if ($Ok -gt 0 -and $Fail -eq 0) { return 'reliable' }
  if ($Fail -ge $script:BLOCK_AFTER -and $Ok -eq 0) { return 'blocked' }
  if ($Fail -gt 0) { return 'unreliable' }
  return 'unknown'
}

# ---------------------------------------------------------------------------------------------------
# THE WRITE MUTEX (added 2026-08-23, measured).
#
# This ledger is a read-modify-write of one JSON file, and until today its only writers were one
# sourcer at a time. The v3 harvester fetches EIGHT PAGES AT ONCE and fetch-recipe.ps1 records an
# outcome per fetch, so eight processes now read the same file, each increment their own copy, and
# each write it back - and the last one wins. Measured on the phase-1 gate crawl: 2,293 real fetches
# produced 65 recorded outcomes. Roughly 97% of the ledger's evidence was being dropped.
#
# That is not a cosmetic undercount. `blocked` is earned at three failures with no successes, so a
# publisher that fails eight times concurrently can be recorded once and never reach the threshold -
# the rule that stops this estate hammering a wall would silently stop firing at exactly the moment
# it is needed most, which is when many requests are failing at once.
#
# A NAMED SYSTEM MUTEX, not a lock file: it is released by the OS if a writer dies, so a crashed
# harvest worker cannot wedge the ledger for every future run. The whole read-modify-write happens
# inside it - locking only the write would still lose the increment that was read before the lock.
$script:LOCK_TIMEOUT_MS = 15000
# 15000 in production. Only a writer this file's SELF-TEST launched waits longer, as a hang guard: whether the
# lock loses an increment is the test's question, and a starved box must not answer it (lib\ledger-fixture.ps1).
$script:LOCK_TIMEOUT_MS = Get-TcLedgerFixtureLockMs $script:LOCK_TIMEOUT_MS

# A REFUSED WRITE IS AN EVENT AS WELL AS A LINE (2026-09-11). Both production callers of -Record discard what
# this prints: fetch-recipe.ps1 pipes it to Out-Null, and harvest.py dropped the exit code until the same day.
# So a refusal said loudly here reached nobody, on the harvest lane that writes 8-wide. ops\brain-digest.ps1
# counts every event kind on its own line, so this reaches the morning digest whoever the caller was. A
# fixture points its children at a scratch bus through TC_EVENT_BUS. Write-TcEvent never throws.
function Write-LedgerRefusal {
  param([string]$Reason, [string]$Detail)
  $null = Write-TcEvent -Kind 'ledger-write-refused' -Producer 'meal-prep\pipeline\source-domains.ps1' `
    -Data @{ ledger = [string]$Store; reason = $Reason; detail = $Detail }
}

function Invoke-Locked {
  param([scriptblock]$Body, [string]$Path)
  # Name the mutex after the store, so a scratch store in a fixture cannot block the live one.
  $key = 'Global\tc-source-domains-' + ([Math]::Abs($Path.ToLower().GetHashCode())).ToString()
  $mx = New-Object System.Threading.Mutex($false, $key)
  $held = $false
  try {
    Wait-TcLedgerFixtureGate   # returns at once unless the self-test launched this writer; its barrier sits here, after start-up
    try { $held = $mx.WaitOne($script:LOCK_TIMEOUT_MS) }
    catch [System.Threading.AbandonedMutexException] { $held = $true }   # a dead writer, not a wedge
    if (-not $held) {
      # Could-not-write is never a silent pass: say so and exit non-zero so the caller sees it.
      Write-Output ("source-domains: could not take the write lock within {0} ms - outcome NOT recorded" -f $script:LOCK_TIMEOUT_MS)
      Write-LedgerRefusal -Reason 'lock-timeout' -Detail ("no lock within {0} ms" -f $script:LOCK_TIMEOUT_MS)
      exit 2
    }
    & $Body
  } finally {
    if ($held) { $mx.ReleaseMutex() | Out-Null }
    $mx.Dispose()
  }
}

# ---------------------------------------------------------------------------------------------------
# THE READ IS SETTLED, AND IT NO LONGER ANSWERS "EMPTY" FOR "COULD NOT LOOK" (2026-09-11).
#
# Read-Store used to return @() for a missing file AND for any read or parse failure. -Record replaces this
# file through Write-TcAtomicFile, which is still a delete then a rename, and a separate reader polling a file
# replaced that way saw it ABSENT on 4,024 of 109,718 polls across 1,500 replaces (the account is in
# lib\json-io.ps1, Read-JsonFileSettled). So in that window -Brief told a sourcer every list was "(none yet)"
# and -Query called a blocked publisher unknown. And the in-lock re-read in -Record used this same function, so
# an unreadable ledger became an empty one and the write then saved one domain over every domain it held.
#
# It returns WHAT IT SAW - State ok, absent or unreadable, after that bounded wait - and each caller decides what
# that means, the policy the ingredient-resolutions ledger set on the same day:
#   -Query, -Brief, -List, -Json   CONSUMERS: anything but ok is exit 2 with a stdout line, never "unknown".
#   -Record                        the WRITER, inside the lock: unreadable REFUSES. Absent is a new ledger for a
#                                  scratch -Store, and a refusal for the live one, which git tracks.
# ---------------------------------------------------------------------------------------------------
function Read-Store { param([string]$Path, [int]$WaitMs = $ReadWaitMs, [scriptblock]$OnWait = $null)
  $st = Read-JsonFileSettled -Path $Path -WaitMs $WaitMs -OnWait $OnWait `
          -Accept { param($d) $null -ne $d -and ($d.PSObject.Properties.Name -contains 'domains') -and $null -ne $d.domains }
  $rowsRead = @()
  if ($st.State -eq 'ok') { $assigned = $st.Doc.domains; $rowsRead = @($assigned) }
  return [pscustomobject]@{ State = $st.State; Rows = $rowsRead; Why = $st.Why; Waits = $st.Waits }
}

if ($runSelfTest) {
  $bad = 0
  function T([string]$n,[bool]$ok,[string]$got){ if($ok){Write-Output ("  ok    "+$n)}else{Write-Output ("  X     "+$n+"   got: "+$got); $script:bad++} }

  T 'host normalises scheme, www and path away' ((Get-Host2 'https://www.thespruceeats.com/recipe/x') -eq 'thespruceeats.com') (Get-Host2 'https://www.thespruceeats.com/recipe/x')
  T 'MUST FIRE  ONE failure is `unreliable`, never `blocked`' ((Get-Status 0 1 $false) -eq 'unreliable') (Get-Status 0 1 $false)
  T 'MUST FIRE  a repeated pattern with no success earns `blocked`' ((Get-Status 0 3 $false) -eq 'blocked') (Get-Status 0 3 $false)
  T 'MUST FIRE  a domain that has EVER worked is not blocked by later failures' ((Get-Status 5 4 $false) -eq 'unreliable') (Get-Status 5 4 $false)
  T 'CLEAN TWIN all-success is reliable' ((Get-Status 9 0 $false) -eq 'reliable') (Get-Status 9 0 $false)
  T 'an explicit block (a real bot wall) overrides the counts' ((Get-Status 9 0 $true) -eq 'blocked') (Get-Status 9 0 $true)
  T 'an unseen domain is `unknown`, not `reliable`' ((Get-Status 0 0 $false) -eq 'unknown') (Get-Status 0 0 $false)

  $tmp = Join-Path $env:TEMP ('sd-' + [guid]::NewGuid().ToString('N') + '.json')
  try {
    ([pscustomobject]@{ domains=@([pscustomobject]@{domain='x.com';ok=1;fail=0;status='reliable'}) } | ConvertTo-Json -Depth 5) | Set-Content $tmp -Encoding utf8
    T 'the store round-trips' ((@((Read-Store $tmp).Rows)).Count -eq 1) ([string](@((Read-Store $tmp).Rows)).Count)
    # CLEAN TWIN: -Query still answers from the ledger (2026-09-11). The read feeding -Query, -Brief and the
    # listing moved below -Record, which no longer reads before its lock; a read placed wrongly or dropped
    # would leave -Query saying `unknown` about a domain the store holds. Driven as a real child, as callers do.
    $qLines = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Query -Domain 'https://www.x.com/a' -Json -Store $tmp
    $qCode = $LASTEXITCODE
    $qRow = $null; try { $qRow = ((@($qLines) -join "`n") | ConvertFrom-Json) } catch { $qRow = $null }
    T 'CLEAN TWIN -Query still answers from the ledger now that the read feeding it sits below -Record' `
      ($qCode -eq 0 -and $null -ne $qRow -and [string]$qRow.domain -eq 'x.com' -and [int]$qRow.ok -eq 1) ("exit $qCode out: " + (@($qLines) -join ' / '))

    # MUST FIRE: CONCURRENT WRITERS DO NOT LOSE INCREMENTS. Measured 2026-08-23 - before the mutex,
    # the v3 harvester's 8 parallel fetches turned 2,293 real outcomes into 65 recorded ones, which
    # would have kept a genuinely walled publisher below the three-failure block threshold forever.
    #
    # REBUILT 2026-08-24 (D9), because THIS FIXTURE DID NOT FIRE. Measured: with the mutex neutered,
    # the eight-job version below still reported ok=8 and the suite still passed - it proved nothing,
    # and PLAN-recipe-hunter-v3 D9 names it as the pattern every other ledger's fixture should copy,
    # so an inert reference would have propagated. The reason it could not race: each child spawns its
    # own powershell.exe at ~1 s apiece while the read-modify-write costs ~2 ms, so no two writers were
    # ever inside the critical section together. Two changes fix it, and both are needed:
    #   1. A START BARRIER - every writer waits inside Invoke-Locked, after its own start-up, until all eight
    #      are there, so they ask for the lock together (THE BARRIER IS INSIDE THE WRITER, below).
    #   2. A STORE BIG ENOUGH TO BE SLOW - seeded with 400 domains, which puts the read-modify-write
    #      in the tens of milliseconds, wide enough for eight barriered writers to overlap.
    # With both, the neutered run loses increments. The lock was always right; only its fixture was asleep.
    # HOW OFTEN, measured 2026-09-11 with WaitOne and ReleaseMutex both skipped in a temp mirror. With the
    # barrier AHEAD of each writer's start-up: red in 1 of 1 run beside 32 CPU burners, 2 of 2 without them and
    # 10 of 10 beside a run-gates loop - while ingredient-resolutions' four-writer twin was caught in 6 of 11,
    # then 9 of 10, because each writer's own start-up spread them further than the barrier closed. With the
    # barrier INSIDE the writer (below): red in 20 of 20, and the locked suite passed 20 of 20 in the same
    # iterations. Load uncontrolled throughout (other sessions' gate runs; 32 CPU burners after 11:47).
    # Harness: a scratch harness running each arm's -SelfTest back to back, at 00c3527d7 plus this change.
    $ctmp = Join-Path $env:TEMP ('sd-conc-' + [guid]::NewGuid().ToString('N') + '.json')
    $seed = @(1..400 | ForEach-Object {
      [pscustomobject]@{ domain="seed$_.test"; ok=1; fail=0; status='reliable'
                         last='2026-08-24T00:00:00'; note='a row that must survive eight writers' } })
    ([pscustomobject]@{ count=$seed.Count; domains=$seed } | ConvertTo-Json -Depth 6) | Set-Content $ctmp -Encoding utf8
    # Every child below that REFUSES writes an event; they write it to a scratch bus, never the live one.
    $sdBus = Join-Path $env:TEMP ('sd-bus-' + [guid]::NewGuid().ToString('N') + '.jsonl')
    $prevBus = $env:TC_EVENT_BUS; $env:TC_EVENT_BUS = $sdBus
    # THE BARRIER IS INSIDE THE WRITER, AFTER ITS START-UP (2026-09-11). It used to sit in a Start-Job child
    # BEFORE `& powershell -File` - first a UTC instant, then a ready/go handshake - and either way each writer
    # still paid its own powershell.exe start-up, about a second and variable, AFTER it was released. That
    # spread the eight further than any barrier closed, so a disabled lock was caught most runs and not all.
    # Now the writers are plain processes that wait on lib\ledger-fixture.ps1's kernel event inside
    # Invoke-Locked, immediately before WaitOne, so start-up is spent first and all eight ask for the lock
    # together. The same library keeps every writer's exit code, stdout and stderr and whether it was launched,
    # reached the barrier and exited - a writer that could not run is named as that, never read as the lock
    # losing an increment - and gives the writers a hang-guard lock wait in place of the production 15 s.
    # WHAT THIS GAVE UP: each writer's own lock-free read at start-up now happens before the barrier, so this
    # case no longer lands one on a sibling's replace by chance (9f3ca3cbd measured that loss in 2 of 40 trials
    # under 32 CPU burners). The held-reader case below drives that collision on purpose, every run.
    $argSets = New-Object System.Collections.Generic.List[object]
    foreach ($i in 1..8) { $argSets.Add([string[]]@('-Record', '-Domain', 'conc.test', '-Outcome', 'ok', '-Store', $ctmp)) }
    $run = Invoke-TcLedgerWriters -Script $PSCommandPath -ArgSets $argSets.ToArray()
    $writers = @($run.writers)
    Write-Output ("  info  barrier: {0} of 8 writers were at the barrier when released ({1} ms)" -f $run.ready_at_go, $run.go_ms)
    $got = @((Read-Store $ctmp).Rows)
    $row = @($got | Where-Object { $_.domain -eq 'conc.test' })
    $okCount = if (@($row).Count) { [int]$row[0].ok } else { -1 }
    $seedKept = @($got | Where-Object { [string]$_.domain -like 'seed*' }).Count
    Remove-Item $ctmp -Force -ErrorAction SilentlyContinue
    $ran = @($writers | Where-Object { $_.ran })
    $rc0 = @($writers | Where-Object { $_.ran -and $_.exit -eq 0 }).Count
    $why = Format-TcWriterTrouble $writers
    T 'every writer RAN - launched, at the barrier when the eight were released together, and exited (one that could not run is named here, never read as a lost increment)' ($ran.Count -eq 8) ("ran " + $ran.Count + " of 8" + $why)
    T 'MUST FIRE  8 barriered concurrent -Record calls all land (the harvest lane writes 8-wide)' ($okCount -eq 8) ("ok=$okCount of 8" + $why)
    # THE MUTEX'S OWN GUARANTEE, stated apart from the one above. "All eight land" also fails when a writer
    # REFUSES, which is loud and costs nothing silently; this one fails only when a writer said it recorded
    # and the increment is not there (or the reverse). A refusal is counted as a refusal, never a lost row.
    T 'MUST FIRE  and no increment was lost SILENTLY - the count that landed is exactly the writers that exited 0' `
      ($ran.Count -eq 8 -and [Math]::Max($okCount, 0) -eq $rc0) ("ok=$okCount, ran and exited 0: $rc0 of 8" + $why)
    T 'MUST FIRE  and not one of the 400 domains already in the ledger was dropped on the way' ($seedKept -eq 400) ("kept $seedKept of 400")
    # CHANGED 2026-09-11: this used to assert "a missing store reads as EMPTY", which is the defect. A missing
    # store now reads as what it is, and each caller decides what absent means (see Read-Store's header).
    $nope = Read-Store (Join-Path $env:TEMP ('nope-sd-' + [guid]::NewGuid().ToString('N') + '.json')) -WaitMs 100
    T 'a missing store reads as ABSENT with no rows, and says so, rather than as an empty ledger' `
      ($nope.State -eq 'absent' -and @($nope.Rows).Count -eq 0 -and $nope.Why) ('state=' + $nope.State)

    # MUST FIRE: A -Record MADE WHILE A LOCK-FREE READER HOLDS THE LEDGER LANDS (2026-09-11).
    # The run-gates red at 839c5e666, made deterministic. The mutex serialises WRITERS and nothing serialises
    # READERS; Get-Content and Read-TextFile open a file shared ReadWrite but not Delete, and a bare
    # `Move-Item -Force` over a file held that way fails inside the lock with "Cannot create a file when that
    # file already exists". Measured under 32 CPU burners with every writer's output kept, that was the whole
    # of the failure: the writer held the lock, waited 43 ms, held it 108 ms, and lost the write at the
    # replace. Here the parent holds exactly that handle until the child has written its .tmp, 400 ms longer,
    # then lets go.
    $htmp = Join-Path $env:TEMP ('sd-hold-' + [guid]::NewGuid().ToString('N') + '.json')
    $hseed = @(1..3 | ForEach-Object { [pscustomobject]@{ domain="seed$_.test"; ok=1; fail=0; status='reliable' } })
    ([pscustomobject]@{ count=3; domains=$hseed } | ConvertTo-Json -Depth 6) | Set-Content $htmp -Encoding utf8
    $hOutF = [IO.Path]::GetTempFileName(); $hErrF = [IO.Path]::GetTempFileName()
    $hold = New-Object IO.FileStream($htmp, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    $sawTmp = $false
    try {
      $hp = Start-Process -FilePath 'powershell' -PassThru -NoNewWindow `
            -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-Record','-Domain','held.test','-Outcome','ok','-Store',$htmp) `
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
    $hRow = @($hRows | Where-Object { [string]$_.domain -eq 'held.test' })
    $heldLanded = ($hRow.Count -eq 1 -and [int]$hRow[0].ok -eq 1)
    Remove-Item $htmp, ($htmp + '.tmp') -Force -ErrorAction SilentlyContinue
    T 'MUST FIRE  a -Record made while a lock-free reader holds the ledger open LANDS once the reader lets go (a bare Move-Item lost it inside the lock)' `
      ($sawTmp -and $hp.ExitCode -eq 0 -and $heldLanded -and $hRows.Count -eq 4) `
      ("saw_tmp=$sawTmp exit=" + $hp.ExitCode + " landed=$heldLanded rows=" + $hRows.Count + " out=" + $hOut.Trim())

    # MUST FIRE: A REFUSED -Record IS LOUD WHERE ITS CALLERS CAN HEAR IT (2026-09-11). fetch-recipe.ps1 pipes
    # -Record to Out-Null, so the stdout line alone reached nobody on the harvest lane. A store in a directory
    # that does not exist is the cheapest real refusal: the replace itself throws.
    $noStore = Join-Path (Join-Path $env:TEMP ('sd-nodir-' + [guid]::NewGuid().ToString('N'))) 'ledger.json'
    $rOutF = [IO.Path]::GetTempFileName(); $rErrF = [IO.Path]::GetTempFileName()
    $rp = Start-Process -FilePath 'powershell' -Wait -PassThru -NoNewWindow `
          -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-Record','-Domain','refused.test','-Outcome','fail','-Store',$noStore) `
          -RedirectStandardOutput $rOutF -RedirectStandardError $rErrF
    $rOut = [string](Get-Content $rOutF -Raw); if ($null -eq $rOut) { $rOut = '' }
    $rErr = [string](Get-Content $rErrF -Raw); if ($null -eq $rErr) { $rErr = '' }
    Remove-Item $rOutF, $rErrF -Force -ErrorAction SilentlyContinue
    $busRows = @()
    if (Test-Path -LiteralPath $sdBus) { foreach ($line in [IO.File]::ReadAllLines($sdBus)) { if ($line.Trim()) { $busRows += ($line | ConvertFrom-Json) } } }
    $refusals = @($busRows | Where-Object { [string]$_.kind -eq 'ledger-write-refused' -and [string]$_.reason -eq 'write-failed' -and [string]$_.ledger -eq $noStore })
    T 'MUST FIRE  a -Record that cannot write exits non-zero and says COULD NOT WRITE on STDOUT, with nothing on stderr' `
      ($rp.ExitCode -ne 0 -and $rOut -match 'COULD NOT WRITE' -and [string]::IsNullOrWhiteSpace($rErr)) ("exit " + $rp.ExitCode + " out=" + $rOut.Trim() + " err=" + $rErr.Trim())
    T 'MUST FIRE  and the refusal is written to the event bus, which the digest reads whoever discarded the stdout' `
      ($refusals.Count -eq 1) ("refusal events=" + $refusals.Count + " of " + $busRows.Count + " bus row(s)")
  } finally {
    if (Test-Path $tmp) { Remove-Item $tmp -Force }
    $env:TC_EVENT_BUS = $prevBus
    if ($sdBus) { Remove-Item $sdBus -Force -ErrorAction SilentlyContinue }
  }

  # ---- A COULD-NOT-READ MUST NOT SETTLE THE LEDGER (2026-09-11) ----
  # The ingredient-resolutions ledger's fix, carried to this one. -Record replaces the file by a delete then a
  # rename, and Read-Store answered @() for that window and for any parse failure: -Brief and -Query then reported
  # a ledger with no history, and the in-lock re-read handed -Record an empty ledger to save its one domain over.
  # Children run as real processes because the exit code and the stdout/stderr split ARE the contract. ONE-TOKEN
  # VALUES ONLY: Start-Process joins -ArgumentList with spaces and quotes nothing.
  function Invoke-SdChild([string]$Script, [string[]]$ChildArgs) {
    $eF = [IO.Path]::GetTempFileName(); $oF = [IO.Path]::GetTempFileName()
    $cp = Start-Process -FilePath 'powershell' -Wait -PassThru -NoNewWindow `
            -ArgumentList (@('-NoProfile','-ExecutionPolicy','Bypass','-File',$Script) + $ChildArgs) `
            -RedirectStandardError $eF -RedirectStandardOutput $oF
    $o = [string](Get-Content $oF -Raw); if ($null -eq $o) { $o = '' }
    $e = [string](Get-Content $eF -Raw); if ($null -eq $e) { $e = '' }
    Remove-Item $eF, $oF -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{ Code = $cp.ExitCode; Out = $o; Err = $e }
  }
  $sdDir = Join-Path $env:TEMP ('sd-read-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $sdDir -Force | Out-Null
  $sdEnc = New-Object Text.UTF8Encoding($false)
  $sdThree = '{"count":3,"domains":[{"domain":"walled.test","ok":0,"fail":3,"status":"blocked","forced_block":false},{"domain":"good.test","ok":4,"fail":0,"status":"reliable","forced_block":false},{"domain":"flaky.test","ok":2,"fail":1,"status":"unreliable","forced_block":false}]}'
  # A refusal writes an event; every child here writes it to a scratch bus, never the live one.
  $sdReadBus = Join-Path $sdDir 'bus.jsonl'
  $prevReadBus = $env:TC_EVENT_BUS; $env:TC_EVENT_BUS = $sdReadBus
  try {
    # (1) THE WINDOW, HELD IN PROCESS: the ledger is absent at the first look and -OnWait puts it back on the
    #     first wait, so the read provably saw the window and provably outlived it. Never raced.
    $sdWin = Join-Path $sdDir 'window.json'
    $sa = $null
    try { $sa = Read-Store $sdWin -WaitMs 5000 -OnWait ({ param($n, $s) if ($n -eq 1) { [IO.File]::WriteAllText($sdWin, $sdThree, $sdEnc) } }.GetNewClosure()) } catch { $sa = $null }
    T 'MUST FIRE  a ledger ABSENT at the first look (the replace window) reads all 3 domains, not an empty ledger' `
      ($null -ne $sa -and $sa.State -eq 'ok' -and $sa.Waits -ge 1 -and @($sa.Rows).Count -eq 3) `
      ($(if ($sa) { 'state=' + $sa.State + ' waits=' + $sa.Waits + ' rows=' + @($sa.Rows).Count } else { 'threw' }))

    # (2) -Record INSIDE THE LOCK against a ledger it cannot read. The bytes on disk are the finding.
    $sdTrunc = Join-Path $sdDir 'truncated.json'
    [IO.File]::WriteAllText($sdTrunc, $sdThree.Substring(0, 120), $sdEnc)
    $md5Trunc = (Get-FileHash -LiteralPath $sdTrunc -Algorithm MD5).Hash
    $cr = Invoke-SdChild $PSCommandPath @('-Record','-Domain','newpub.test','-Outcome','ok','-Store',$sdTrunc,'-ReadWaitMs','200')
    T 'MUST FIRE  -Record against a ledger it cannot READ writes NOTHING - the bytes are unchanged, so no domain is wiped' `
      ((Get-FileHash -LiteralPath $sdTrunc -Algorithm MD5).Hash -eq $md5Trunc) ('the ledger changed; the child said: ' + $cr.Out)
    T '...and exits non-zero, says COULD NOT WRITE and could not READ on STDOUT, and claims no outcome' `
      ($cr.Code -ne 0 -and ($cr.Out -match 'COULD NOT WRITE') -and ($cr.Out -match 'could not READ') -and -not ($cr.Out -match 'newpub\.test\s+ok=')) ('exit ' + $cr.Code + ': ' + $cr.Out)
    T 'MUST FIRE  ...and leaks NOTHING to stderr (one noisy child kills ops\run-gates.ps1)' ([string]::IsNullOrWhiteSpace($cr.Err)) $cr.Err
    $readBusRows = @()
    if (Test-Path -LiteralPath $sdReadBus) { foreach ($line in [IO.File]::ReadAllLines($sdReadBus)) { if ($line.Trim()) { $readBusRows += ($line | ConvertFrom-Json) } } }
    $readRefusals = @($readBusRows | Where-Object { [string]$_.kind -eq 'ledger-write-refused' -and [string]$_.reason -eq 'read-failed' -and [string]$_.ledger -eq $sdTrunc })
    T 'MUST FIRE  ...and the refusal reaches the event bus as read-failed, because fetch-recipe.ps1 discards the stdout' `
      ($readRefusals.Count -eq 1) ('read-failed events=' + $readRefusals.Count + ' of ' + $readBusRows.Count + ' bus row(s)')

    # (3) CONSUMERS: -Query and -Brief on an unreadable ledger, and -Query on one that STAYS absent, are exit 2.
    #     The defect's exact answers were "unknown - no history" and "(none yet)"; the refusal must say neither.
    $cq = Invoke-SdChild $PSCommandPath @('-Query','-Domain','walled.test','-Store',$sdTrunc,'-ReadWaitMs','200')
    T 'MUST FIRE  -Query on an unreadable ledger is exit 2 COULD NOT READ, never "unknown - no history"' `
      ($cq.Code -eq 2 -and ($cq.Out -match 'COULD NOT READ') -and -not ($cq.Out -match 'unknown - no history') -and [string]::IsNullOrWhiteSpace($cq.Err)) `
      ('exit ' + $cq.Code + ': ' + $cq.Out + $cq.Err)
    $cb = Invoke-SdChild $PSCommandPath @('-Brief','-Store',$sdTrunc,'-ReadWaitMs','200')
    T 'MUST FIRE  -Brief on an unreadable ledger is exit 2 COULD NOT READ, never a brief of "(none yet)" for a sourcer to trust' `
      ($cb.Code -eq 2 -and ($cb.Out -match 'COULD NOT READ') -and -not ($cb.Out -match 'none yet') -and [string]::IsNullOrWhiteSpace($cb.Err)) `
      ('exit ' + $cb.Code + ': ' + $cb.Out + $cb.Err)
    $cqa = Invoke-SdChild $PSCommandPath @('-Query','-Domain','walled.test','-Store',(Join-Path $sdDir 'never.json'),'-ReadWaitMs','200')
    T 'MUST FIRE  -Query on a ledger that STAYS absent is exit 2 as well - a consumer never reads absence as no history' `
      ($cqa.Code -eq 2 -and ($cqa.Out -match 'COULD NOT READ') -and -not ($cqa.Out -match 'unknown - no history') -and [string]::IsNullOrWhiteSpace($cqa.Err)) `
      ('exit ' + $cqa.Code + ': ' + $cqa.Out + $cqa.Err)

    # (4) THE LIVE LEDGER ABSENT. Driven from a MIRROR of this script and every library it dot-sources, read off
    #     its own source, so the default store path is a scratch copy of the live layout and the real ledger is
    #     never touched. A pattern that matched nothing leaves the mirror with no libraries, and the child then
    #     fails loudly rather than passing.
    $sdMirror = Join-Path $sdDir 'mirror'
    New-Item -ItemType Directory -Force -Path (Join-Path $sdMirror 'lib'), (Join-Path $sdMirror 'meal-prep\pipeline'), (Join-Path $sdMirror 'meal-prep\db') | Out-Null
    $sdLibs = @([regex]::Matches([IO.File]::ReadAllText($PSCommandPath), '(?m)^\. \(Join-Path \$repo ''lib\\([\w.-]+\.ps1)''\)') | ForEach-Object { $_.Groups[1].Value })
    foreach ($sdLib in $sdLibs) { Copy-Item (Join-Path $repo ('lib\' + $sdLib)) -Destination (Join-Path $sdMirror 'lib') }
    Copy-Item $PSCommandPath -Destination (Join-Path $sdMirror 'meal-prep\pipeline')
    $sdMirrorLive = Join-Path $sdMirror 'meal-prep\db\source-domains.json'
    $cl = Invoke-SdChild (Join-Path $sdMirror 'meal-prep\pipeline\source-domains.ps1') @('-Record','-Domain','newpub.test','-Outcome','ok','-ReadWaitMs','200')
    T 'MUST FIRE  -Record with the LIVE ledger absent REFUSES, rather than starting a one-domain ledger the 07:00 bot would commit' `
      ($cl.Code -ne 0 -and ($cl.Out -match 'COULD NOT WRITE') -and ($cl.Out -match 'LIVE ledger') -and -not (Test-Path -LiteralPath $sdMirrorLive) -and [string]::IsNullOrWhiteSpace($cl.Err)) `
      ('exit ' + $cl.Code + ' created=' + (Test-Path -LiteralPath $sdMirrorLive) + ' libs=' + ($sdLibs -join ',') + ': ' + $cl.Out + $cl.Err)

    # (5) CLEAN TWIN - the fresh-ledger road the fix was most likely to break on its way past
    $sdNew = Join-Path $sdDir 'new-ledger.json'
    $cn = Invoke-SdChild $PSCommandPath @('-Record','-Domain','newpub.test','-Outcome','ok','-Store',$sdNew,'-ReadWaitMs','200')
    $newRows = @((Read-Store $sdNew -WaitMs 0).Rows)
    T 'CLEAN TWIN a SCRATCH -Store that does not exist yet is still created by -Record, holding exactly the new domain' `
      ($cn.Code -eq 0 -and @($newRows).Count -eq 1 -and [string]$newRows[0].domain -eq 'newpub.test') ('exit ' + $cn.Code + ' rows=' + @($newRows).Count + ': ' + $cn.Out)

    # (6) CLEAN TWIN - a readable ledger still answers -Query and -Brief with what it holds
    $sdGood = Join-Path $sdDir 'good.json'
    [IO.File]::WriteAllText($sdGood, $sdThree, $sdEnc)
    $cg = Invoke-SdChild $PSCommandPath @('-Query','-Domain','walled.test','-Store',$sdGood,'-ReadWaitMs','200')
    $cgb = Invoke-SdChild $PSCommandPath @('-Brief','-Store',$sdGood,'-ReadWaitMs','200')
    T 'CLEAN TWIN a readable ledger still answers: -Query finds the blocked publisher (exit 3) and -Brief lists it BLOCKED' `
      ($cg.Code -eq 3 -and ($cg.Out -match 'walled\.test') -and $cgb.Code -eq 0 -and ($cgb.Out -match 'BLOCKED \(do not fetch, do not retry\): walled\.test')) `
      ('query exit ' + $cg.Code + ': ' + $cg.Out + ' | brief exit ' + $cgb.Code + ': ' + $cgb.Out)
  } finally {
    $env:TC_EVENT_BUS = $prevReadBus
    Remove-Item -LiteralPath $sdDir -Recurse -Force -ErrorAction SilentlyContinue
  }

  if ($bad -gt 0) { Write-Output ("source-domains SELF-TEST FAIL ({0})" -f $bad); exit 2 }
  Write-Output 'source-domains SELF-TEST PASS'
  Exit-Guard -Name 'source-domains' -Summary 'selftest pass' -Code 0
}

if ($runRecord) {
  $h = Get-Host2 $Domain
  if (-not $h) { Write-Output 'source-domains: -Record needs -Domain'; exit 1 }
  $o = $Outcome.ToLower()
  if (@('ok','fail','404','blocked') -notcontains $o) { Write-Output ("source-domains: -Outcome must be ok|fail|404|blocked (got '{0}')" -f $Outcome); exit 1 }
  Invoke-Locked -Path $Store -Body {
  # READ INSIDE THE LOCK, and only there. A copy read before the lock was taken may already be stale by an
  # increment another writer has since committed, so -Record no longer reads at script start at all.
  $st = Read-Store $Store
  # A COULD-NOT-READ REFUSES THE WRITE (2026-09-11). The write below saves the WHOLE ledger, so merging into a
  # read that failed would replace every domain on disk with this one. Said on STDOUT and on the event bus,
  # exit 1, nothing on stderr and the file untouched - the same shape as the write-failed refusal below.
  if ($st.State -eq 'unreadable') {
    Write-Output ("source-domains: COULD NOT WRITE {0} - outcome NOT recorded. It could not READ the existing ledger, so writing now would replace every domain it holds with this one. {1}" -f $Store, $st.Why)
    Write-LedgerRefusal -Reason 'read-failed' -Detail $st.Why
    exit 1
  }
  # A settled ABSENT is a NEW ledger only for a scratch -Store. The lock rules out this script's own replace
  # window and the wait rules out a foreign one, but the LIVE ledger is tracked in git: restarting it with one
  # domain is a wipe the 07:00 bot would commit with everything else, so that refuses too.
  if ($st.State -eq 'absent' -and $storeIsLive) {
    Write-Output ("source-domains: COULD NOT WRITE {0} - outcome NOT recorded. The LIVE ledger is absent, and git tracks it, so this is not a fresh estate. {1}" -f $Store, $st.Why)
    Write-LedgerRefusal -Reason 'live-ledger-absent' -Detail $st.Why
    exit 1
  }
  $rows = @($st.Rows)
  $r = @($rows | Where-Object { [string]$_.domain -eq $h })[0]
  if (-not $r) {
    $r = [pscustomobject]@{ domain=$h; ok=0; fail=0; last_404=$null; has_jsonld=$false; forced_block=$false; status='unknown'; note=''; updated='' }
    $rows = @($rows + $r)
  }
  switch ($o) {
    'ok'      { $r.ok = [int]$r.ok + 1 }
    'fail'    { $r.fail = [int]$r.fail + 1 }
    '404'     { $r.fail = [int]$r.fail + 1; $r.last_404 = (Get-Date -Format 'yyyy-MM-dd') }
    'blocked' { $r.fail = [int]$r.fail + 1; $r.forced_block = $true }
  }
  if ($runHasJsonLd) { $r.has_jsonld = $true }
  if ($Note) { $r.note = $Note }
  $r.status = Get-Status ([int]$r.ok) ([int]$r.fail) ([bool]$r.forced_block)
  $r.updated = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
  $doc = [pscustomobject]@{
    _doc='What the pipeline has learned about recipe publishers. Written automatically on every fetch outcome; read by sourcers before searching and before fetching. Replaces the prose blocked-domain lists that used to live, duplicated, in two agent prompts.'
    _rule='One failure is `unreliable`, not `blocked` - a 404 is a fact about one URL. Only a repeated pattern with no successes earns `blocked`. Counts stay visible so the judgment is auditable.'
    updated=(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'); count=@($rows).Count; domains=@($rows)
  }
  # THROUGH lib\atomic-write.ps1, NOT Set-Content + Move-Item (2026-09-11). The mutex serialises WRITERS
  # and nothing serialises READERS: a lock-free read holding this file open made a bare Move-Item fail
  # INSIDE the lock and drop the increment, which is how run-gates read "ok=7 of 8" at 839c5e666.
  # A reader that outlasts the retry budget still costs the write, and that is said on STDOUT, where a
  # caller reads it, not as a raw error on stderr: one noisy child kills ops\run-gates.ps1.
  try { [void](Write-TcAtomicFile -Path $Store -Text ($doc | ConvertTo-Json -Depth 6)) }
  catch {
    Write-Output ("source-domains: COULD NOT WRITE {0} - outcome NOT recorded. {1}" -f $Store, $_.Exception.Message)
    Write-LedgerRefusal -Reason 'write-failed' -Detail $_.Exception.Message
    exit 1
  }
  Write-Output ("source-domains: {0}  ok={1} fail={2}  -> {3}" -f $h, $r.ok, $r.fail, $r.status)
  }
  exit 0
}

# THE READ-ONLY MODES ARE CONSUMERS (2026-09-11). A settled absence or an unreadable ledger is exit 2 with one line
# on stdout (a JSON object under -Json), never "unknown - no history" or a -Brief of "(none yet)": a sourcer acts on
# those by fetching from a publisher the ledger has blocked. Read here and not at the top, so -Record never pays for
# a read it does not use: its own read happens inside the lock.
# Exit 2 is new to -Query. harvest.py's crawl treats only exit 3 as blocked, so a 2 crawls exactly as the "unknown"
# a missing ledger used to produce did - no worse, and no better until that caller reads the 2.
$st = Read-Store $Store
if ($st.State -ne 'ok') {
  $msg = ("source-domains: COULD NOT READ the ledger at {0} ({1}) - that is not the same as a publisher with no history. {2}" -f $Store, $st.State, $st.Why)
  if ($runJson) { ([pscustomobject]@{ error = $msg } | ConvertTo-Json -Compress) } else { Write-Output $msg }
  exit 2
}
$rows = @($st.Rows)

if ($runQuery) {
  $h = Get-Host2 $Domain
  $r = @($rows | Where-Object { [string]$_.domain -eq $h })[0]
  if (-not $r) { Write-Output ("source-domains: {0} unknown - no history, treat as untested (not as safe, not as bad)" -f $h); exit 0 }
  if ($runJson) { ($r | ConvertTo-Json -Depth 5); if ([string]$r.status -eq 'blocked') { exit 3 }; exit 0 }
  Write-Output ("source-domains: {0}  {1}  (ok={2} fail={3}{4}{5})" -f $r.domain, ([string]$r.status).ToUpper(), $r.ok, $r.fail,
    $(if($r.last_404){', last 404 ' + $r.last_404}else{''}), $(if($r.has_jsonld){', JSON-LD'}else{''}))
  if ($r.note) { Write-Output ("  note: " + $r.note) }
  if ([string]$r.status -eq 'blocked') { exit 3 }
  exit 0
}

if ($runBrief) {
  $blocked = @($rows | Where-Object { [string]$_.status -eq 'blocked' } | ForEach-Object { $_.domain } | Sort-Object)
  $unrel   = @($rows | Where-Object { [string]$_.status -eq 'unreliable' } | ForEach-Object { $_.domain } | Sort-Object)
  $rel     = @($rows | Where-Object { [string]$_.status -eq 'reliable' } | ForEach-Object { $_.domain } | Sort-Object)
  $jsonld  = @($rows | Where-Object { $_.has_jsonld } | ForEach-Object { $_.domain } | Sort-Object)
  if ($runJson) { ([pscustomobject]@{ blocked=$blocked; unreliable=$unrel; reliable=$rel; jsonld=$jsonld } | ConvertTo-Json -Depth 4); exit 0 }
  Write-Output ("BLOCKED (do not fetch, do not retry): {0}" -f $(if($blocked.Count){$blocked -join ', '}else{'(none yet)'}))
  Write-Output ("UNRELIABLE (has failed before - prefer alternatives): {0}" -f $(if($unrel.Count){$unrel -join ', '}else{'(none yet)'}))
  Write-Output ("RELIABLE (known good): {0}" -f $(if($rel.Count){$rel -join ', '}else{'(none yet)'}))
  if ($jsonld.Count) { Write-Output ("JSON-LD available (cheap structured fetch): {0}" -f ($jsonld -join ', ')) }
  exit 0
}

if ($runJson) { ([pscustomobject]@{ count=@($rows).Count; domains=@($rows) } | ConvertTo-Json -Depth 6); exit 0 }
Write-Output ("source-domains: {0} domain(s)" -f @($rows).Count)
foreach ($r in @($rows | Sort-Object status, domain)) {
  Write-Output ("  {0,-12} {1,-30} ok={2,-4} fail={3,-4}{4}" -f ([string]$r.status).ToUpper(), $r.domain, $r.ok, $r.fail, $(if($r.has_jsonld){' json-ld'}else{''}))
}
exit 0
