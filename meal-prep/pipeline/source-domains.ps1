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
#   .\source-domains.ps1 -Query -Domain x.com          exit 3 if the domain is blocked
#   .\source-domains.ps1 -Brief                        the block for a sourcer prompt
#   .\source-domains.ps1 -SelfTest
#
# STATUS RULE, inherited from the store-carriage discipline: one failure is a fact about one URL, not
# about a publisher. A single 404 makes a domain `unreliable`, never `blocked`. Only a repeated
# pattern earns `blocked`, and the counts stay in the row so the judgment is auditable, not folkloric.
# ---------------------------------------------------------------------------------------------------
param(
  [switch]$Record, [switch]$Query, [switch]$Brief, [switch]$List, [switch]$SelfTest,
  [string]$Domain = '', [string]$Outcome = '', [string]$Note = '', [switch]$HasJsonLd,
  [string]$Store = '', [switch]$Json
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
if (-not $Store) { $Store = Join-Path $mp 'db\source-domains.json' }

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

function Read-Store { param([string]$Path)
  if (-not (Test-Path $Path)) { return @() }
  try { $d = Get-Content $Path -Raw -Encoding utf8 | ConvertFrom-Json } catch { return @() }
  if ($d -and ($d.PSObject.Properties.Name -contains 'domains')) { return @($d.domains) }
  return @()
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
    T 'the store round-trips' ((@(Read-Store $tmp)).Count -eq 1) ([string](@(Read-Store $tmp)).Count)

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
    $got = @(Read-Store $ctmp)
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
    T 'a missing store reads as empty' ((@(Read-Store (Join-Path $env:TEMP 'nope.json'))).Count -eq 0) 'not empty'

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
    $hRows = @(Read-Store $htmp)
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

  if ($bad -gt 0) { Write-Output ("source-domains SELF-TEST FAIL ({0})" -f $bad); exit 2 }
  Write-Output 'source-domains SELF-TEST PASS'
  Exit-Guard -Name 'source-domains' -Summary 'selftest pass' -Code 0
}

$rows = @(Read-Store $Store)

if ($runRecord) {
  $h = Get-Host2 $Domain
  if (-not $h) { Write-Output 'source-domains: -Record needs -Domain'; exit 1 }
  $o = $Outcome.ToLower()
  if (@('ok','fail','404','blocked') -notcontains $o) { Write-Output ("source-domains: -Outcome must be ok|fail|404|blocked (got '{0}')" -f $Outcome); exit 1 }
  Invoke-Locked -Path $Store -Body {
  # RE-READ INSIDE THE LOCK. The copy loaded at script start was read before the lock was taken and
  # may already be stale by an increment another writer has since committed.
  $rows = @(Read-Store $Store)
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
