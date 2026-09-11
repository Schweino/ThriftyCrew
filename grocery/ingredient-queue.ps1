<#
  ingredient-queue.ps1 - the durable handoff between the Recipe Hunter's mapping stage and its pricing stage.

  WHAT IT IS FOR. When a hunted recipe needs an ingredient the board has never priced, that ingredient lands
  here. The pricing agent drains the queue, checks the seven Omaha stores, and records what each store said.
  A recipe waiting on an ingredient parks; it is never guessed at and never silently dropped.

  IT DOES NOT INJECT INTO pull-order-<store>.txt, AND THAT WAS THE FIRST PLAN.
  Those files are DERIVED - build-pull-order.ps1 regenerates them from price-history depth, how contested a
  commodity is, and whether the store already publishes a cell. Anything written into them is wiped on the
  next regeneration. They order the WEEKLY bulk capture so a bot wall costs the tail instead of the basket.
  That is a different job from "go look at this one thing now", which is what the pricing agent does with its
  own browser tabs. Two mechanisms, two purposes; this one owns only the Hunter's worklist.

  THE VERDICT RULE (Rule B, decided 2026-08-15 against the live catalog):
    an ingredient is CARRIED as soon as ONE store carries it.
    it is NOT-CARRIED only when all seven have been CHECKED and none carry it.
  Measured on the 542 live recipes: requiring all seven to carry every ingredient leaves 1 survivor (0%).
  Requiring at least one leaves 542 (100%). achiote-paste is stocked at exactly 1 of 7 stores and is on the
  live board today. A recipe is rejected only when an ingredient is genuinely unavailable in Omaha.

  UNCHECKED IS NOT NOT-CARRIED. A store that errored, hit a bot wall, or was never visited leaves the
  ingredient PENDING, not rejected. That distinction is the whole point of tracking state per store: the
  cost of confusing them is throwing away a good recipe because a CAPTCHA fired once.

  Usage:
    .\ingredient-queue.ps1 -Add -Term 'saffron' -Recipe 'paella-rice-bowls' -Why 'no board cell, no capture match'
    .\ingredient-queue.ps1 -List
    .\ingredient-queue.ps1 -List -Status pending
    .\ingredient-queue.ps1 -Record -Term 'saffron' -Store "Baker's" -State carried -Price 28.99 -Size '0.03 oz' -Item 'Spice Islands Spanish Threads Saffron' -Evidence 'jar of threads, adjudicated'
    .\ingredient-queue.ps1 -Record -Term 'saffron' -Store 'Aldi' -State not-carried -Evidence 'searched in-store mode, no saffron in spice aisle'
    .\ingredient-queue.ps1 -RecordBatch -File batch.json      one call, N records, ALL-OR-NOTHING
    .\ingredient-queue.ps1 -Verdict -Term 'saffron'
    .\ingredient-queue.ps1 -SelfTest
#>
param(
  [switch]$Add,
  [switch]$List,
  [switch]$Record,
  [switch]$RecordBatch,             # B2: N records in ONE call, validated first, written all-or-nothing
  [string]$File = '',               # the batch: a JSON ARRAY of {term, store, state, price, size, item, evidence}
  [switch]$Verdict,
  [switch]$Promote,
  [string]$Bid = '',
  [string]$Term = '',
  [string]$Recipe = '',
  [string]$Why = '',
  [string]$Store = '',
  [ValidateSet('', 'carried', 'not-carried', 'blocked', 'error')][string]$State = '',
  [double]$Price = 0,
  [string]$Size = '',
  [string]$Item = '',
  [string]$Evidence = '',
  [string]$Status = '',
  [string]$QueueFile = '',
  # A SCRATCH CARRIAGE LEDGER, for exactly the reason -QueueFile exists and added for the same
  # measured reason (H2, 2026-08-25): a NO-PUBLISH drill with every other seam engaged still wrote
  # the live grocery\carriage.json, because -Promote resolved that path itself. Empty means the live
  # ledger, which is what a real run wants.
  [string]$CarriagePath = '',
  [switch]$Json,
  [switch]$IngredientQueueSelfTest,
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\atomic-write.ps1')   # Write-TcAtomicFile: a lock-free reader must not cost a writer its write
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\ledger-fixture.ps1')  # Wait-TcLedgerFixtureGate: inert unless this file's own self-test launched the writer
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $QueueFile) { $QueueFile = Join-Path $root 'ingredient-queue.json' }

# The seven Omaha stores, spelled exactly as every capture and board row spells them. A worker recording
# 'Bakers' or 'Sams Club' would create a silent eighth store and the all-seven-checked test would never fire.
$STORES = @("Baker's", 'Family Fare', 'Hy-Vee', 'Aldi', 'Fareway', "Sam's Club", 'Walmart')
$TERMINAL = @('carried', 'not-carried')

function Get-Stamp { $d = Get-Date; return $d.ToString('yyyy-MM-ddTHH:mm:ss') }

function Read-Queue([string]$path) {
  if (-not (Test-Path $path)) { return [pscustomobject]@{ readme = 'Recipe Hunter ingredient worklist. Written by ingredient-queue.ps1 only. An ingredient is CARRIED when ONE store carries it; NOT-CARRIED only when all seven have been CHECKED and none do. Unchecked is never not-carried.'; items = @() } }
  $raw = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) -replace '^﻿', ''
  return ($raw | ConvertFrom-Json)
}
function Write-Queue($doc, [string]$path) {
  # TMP + MOVE, not a direct Set-Content: -Derive and the pricer both READ this file while lanes are
  # live, and a reader that catches a half-written JSON parses nothing and reads the whole worklist
  # as empty - which Rule B then correctly refuses to call not-carried, but which still stalls a run.
  # THROUGH lib\atomic-write.ps1 SINCE 2026-09-11, because the tmp+move above was not enough on its own:
  # those same live readers hold the file open, and a bare Move-Item -Force over a file another handle
  # has open fails outright - inside the write lock, with the write lost. The retry outlasts the reader.
  [void](Write-TcAtomicFile -Path $path -Text ($doc | ConvertTo-Json -Depth 8))
}

# ---------------------------------------------------------------------------------------------------
# THE WRITE LOCK (added 2026-08-24, phase-4 aftercare - the audit rule from PLAN-recipe-hunter-v3 S4:
# "before any lane's cap is raised above 1, enumerate every single-file ledger its stage writes and
# give each one a mutex or a single pen." This ledger was MISSED in that enumeration.)
#
# This file is a read-modify-write of one JSON document, and under the v3 daemon it has CONCURRENT
# WRITERS: the map lane runs 2 workers and each calls -Add per absent term, while the singleton price
# lane's agent calls -Record against the same file in parallel. Without the lock, two -Adds landing
# together lose one of them - and a lost -Add is a recipe parked FOREVER, because the daemon consumes
# `absent_terms` destructively and never re-queues the term. A lost -Record is a store verdict the
# pricer paid browser minutes for, gone. The measured cost of skipping exactly this pattern on
# source-domains was 2,293 outcomes recorded as 65, a 97% loss.
#
# A NAMED SYSTEM MUTEX, not a lock file: the OS releases it if a writer dies, so a crashed lane cannot
# wedge the queue for every future run. The WHOLE read-modify-write happens inside it - the branches
# below RE-READ the document inside the lock, because merging into a snapshot read before the lock was
# taken keeps the exact race the lock exists to close. Keyed by the target file's path, so a scratch
# queue in a fixture (or a drill's -QueueFile) can never block the live one.
# ---------------------------------------------------------------------------------------------------
$script:LOCK_TIMEOUT_MS = 15000
# 15000 in production. Only a writer this file's SELF-TEST launched waits longer, as a hang guard: whether the
# lock loses an item is the test's question, and a starved box must not answer it (lib\ledger-fixture.ps1).
$script:LOCK_TIMEOUT_MS = Get-TcLedgerFixtureLockMs $script:LOCK_TIMEOUT_MS

function Invoke-Locked {
  param([scriptblock]$Body, [string]$Path)
  $key = 'Global\tc-ingredient-queue-' + ([Math]::Abs($Path.ToLower().GetHashCode())).ToString()
  $mx = New-Object System.Threading.Mutex($false, $key)
  $held = $false
  try {
    Wait-TcLedgerFixtureGate   # returns at once unless the self-test launched this writer; its barrier sits here, after start-up
    try { $held = $mx.WaitOne($script:LOCK_TIMEOUT_MS) }
    catch [System.Threading.AbandonedMutexException] { $held = $true }   # a dead writer, not a wedge
    if (-not $held) {
      Write-Output ("ingredient-queue: could not take the write lock within {0} ms - NOTHING was written" -f $script:LOCK_TIMEOUT_MS)
      exit 1
    }
    & $Body
  } finally {
    if ($held) { $mx.ReleaseMutex() | Out-Null }
    $mx.Dispose()
  }
}
function Get-QueueItem($doc, [string]$term) {
  return @($doc.items | Where-Object { [string]$_.term -eq $term })[0]
}

# THE RULE, in one place so the report and the gate can never disagree.
function Get-QueueVerdict($Entry, $AllStores, $TerminalStates) {
  $checked = @(); $carried = @()
  foreach ($s in $AllStores) {
    $r = $Entry.stores.$s
    if ($r -and ($TerminalStates -contains [string]$r.state)) { $checked += $s }
    if ($r -and [string]$r.state -eq 'carried') { $carried += $s }
  }
  if ($carried.Count -gt 0) { return @{ verdict = 'CARRIED'; carried_by = $carried; checked = $checked } }
  if ($checked.Count -eq $AllStores.Count) { return @{ verdict = 'NOT-CARRIED'; carried_by = @(); checked = $checked } }
  return @{ verdict = 'PENDING'; carried_by = @(); checked = $checked }
}

# ---------------------------------------------------------------------------------------------------
# THE ROW CONTRACT, IN ONE PLACE (B2, added 2026-08-24, phase 6a / cold-read pin P8).
#
# -Record and -RecordBatch both run this. That is the whole reason it is a function: the batch road has
# to enforce the evidence contract "PER ROW exactly as it does per call", and the only way to be sure
# of that is for both roads to run the same code. Two copies of a rule is the forked-taxonomy defect
# this estate already has scars from, and here the two copies would be the difference between a
# carriage claim with evidence and one without.
$script:BATCH_STATES = @('carried', 'not-carried', 'blocked', 'error')

function Test-BatchRow {
  <# Returns the violations for ONE row as an array of strings; empty means legal.
     $Index 0 means "not a batch row" - the single -Record road passes it, so its messages read
     exactly as they always did instead of gaining a row number nobody sent. #>
  param($Row, [int]$Index, $AllStores)
  $bad = @()
  $at = if ($Index -gt 0) { "row {0}: " -f $Index } else { '' }
  $term  = [string]$Row.term
  $store = [string]$Row.store
  $state = [string]$Row.state
  if (-not $term)  { $bad += ($at + "no term") }
  if (-not $store) { $bad += ($at + "no store") }
  elseif ($AllStores -notcontains $store) {
    # A worker recording 'Bakers' or 'Sams Club' would create a silent eighth store and the
    # all-seven-checked test would never fire - the difference between NOT-CARRIED and a recipe
    # parked forever.
    $bad += ($at + ("unknown store '{0}'. Must be exactly one of: {1}" -f $store, ($AllStores -join ', ')))
  }
  if (-not $state) { $bad += ($at + "no state") }
  elseif ($script:BATCH_STATES -notcontains $state) {
    $bad += ($at + ("state '{0}' is not one of: {1}" -f $state, ($script:BATCH_STATES -join ', ')))
  }
  $price = 0.0
  if ($null -ne $Row.price) { try { $price = [double]$Row.price } catch { $price = 0.0 } }
  if ($state -eq 'carried' -and $price -le 0) {
    $bad += ($at + ("'{0}' @ {1} is carried with no price. A carriage claim with no price is not evidence." -f $term, $store))
  }
  return $bad
}

if ($SelfTest -or $IngredientQueueSelfTest) {
  $bad = 0
  function New-E { $st = @{}; foreach ($s in $STORES) { $st[$s] = $null }; return [pscustomobject]@{ term = 't'; stores = [pscustomobject]$st } }
  # one carried store is enough - Rule B
  $e = New-E; $e.stores."Baker's" = [pscustomobject]@{ state = 'carried' }
  $v = Get-QueueVerdict $e $STORES $TERMINAL
  if ($v.verdict -ne 'CARRIED') { Write-Output "  X one carried store should be CARRIED, got $($v.verdict)"; $bad++ }
  # MUST-FIRE: six not-carried and one UNCHECKED is PENDING, never NOT-CARRIED. Confusing those throws away
  # a good recipe because a CAPTCHA fired once.
  $e = New-E; foreach ($s in $STORES[0..5]) { $e.stores.$s = [pscustomobject]@{ state = 'not-carried' } }
  $v = Get-QueueVerdict $e $STORES $TERMINAL
  if ($v.verdict -ne 'PENDING') { Write-Output "  X six not-carried + one unchecked must be PENDING, got $($v.verdict)"; $bad++ }
  # a blocked store is NOT a check
  $e = New-E; foreach ($s in $STORES[0..5]) { $e.stores.$s = [pscustomobject]@{ state = 'not-carried' } }
  $e.stores.Walmart = [pscustomobject]@{ state = 'blocked' }
  $v = Get-QueueVerdict $e $STORES $TERMINAL
  if ($v.verdict -ne 'PENDING') { Write-Output "  X a blocked store must not count as checked, got $($v.verdict)"; $bad++ }
  # an errored store is NOT a check
  $e = New-E; foreach ($s in $STORES[0..5]) { $e.stores.$s = [pscustomobject]@{ state = 'not-carried' } }
  $e.stores.Walmart = [pscustomobject]@{ state = 'error' }
  $v = Get-QueueVerdict $e $STORES $TERMINAL
  if ($v.verdict -ne 'PENDING') { Write-Output "  X an errored store must not count as checked, got $($v.verdict)"; $bad++ }
  # all seven checked, none carry -> the only way to reject
  $e = New-E; foreach ($s in $STORES) { $e.stores.$s = [pscustomobject]@{ state = 'not-carried' } }
  $v = Get-QueueVerdict $e $STORES $TERMINAL
  if ($v.verdict -ne 'NOT-CARRIED') { Write-Output "  X all seven not-carried must be NOT-CARRIED, got $($v.verdict)"; $bad++ }
  # carried wins even if the rest are blocked
  $e = New-E; foreach ($s in $STORES) { $e.stores.$s = [pscustomobject]@{ state = 'blocked' } }
  $e.stores.Aldi = [pscustomobject]@{ state = 'carried' }
  $v = Get-QueueVerdict $e $STORES $TERMINAL
  if ($v.verdict -ne 'CARRIED') { Write-Output "  X carried must win over blocked, got $($v.verdict)"; $bad++ }
  # nothing checked at all
  $v = Get-QueueVerdict (New-E) $STORES $TERMINAL
  if ($v.verdict -ne 'PENDING') { Write-Output "  X an empty entry must be PENDING, got $($v.verdict)"; $bad++ }
  # round-trip through the real file format
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ('iq-selftest-' + [Guid]::NewGuid().ToString('N') + '.json')
  try {
    $d = Read-Queue $tmp
    if (@($d.items).Count -ne 0) { Write-Output '  X a missing queue file should read as empty'; $bad++ }
    $st = @{}; foreach ($s in $STORES) { $st[$s] = $null }
    $d.items = @([pscustomobject]@{ term = 'saffron'; recipes = @('x'); added = (Get-Stamp); status = 'pending'; stores = [pscustomobject]$st; verdict = 'PENDING'; notes = $null })
    Write-Queue $d $tmp
    $d2 = Read-Queue $tmp
    if (@($d2.items).Count -ne 1 -or [string]$d2.items[0].term -ne 'saffron') { Write-Output '  X round-trip lost the item'; $bad++ }
    if (($d2.items[0].stores.PSObject.Properties.Name | Measure-Object).Count -ne 7) { Write-Output '  X round-trip lost store slots'; $bad++ }
  } finally { if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue } }
  # MUST FIRE: CONCURRENT WRITERS DO NOT LOSE AN ITEM (added 2026-08-24, phase-4 aftercare).
  #
  # Under the v3 daemon this file has concurrent writers: the MAP LANE AT CAP 2 calls -Add per absent
  # term from two workers, while the singleton price lane's agent calls -Record in parallel. Without
  # the mutex both read the same document, both write, and the last one wins - a lost -Add is a recipe
  # parked FOREVER (the daemon consumes absent_terms destructively and never re-queues), and a lost
  # -Record is a store verdict the pricer paid browser minutes for.
  #
  # A FIXTURE THAT CANNOT LOSE A ROW PROVES NOTHING (the fourth PS trap, measured on source-domains):
  # process startup costs ~1 s and the read-modify-write costs milliseconds, so unbarrier'd children
  # never overlap and there is no race to lose. Two things make this one honest, both required:
  #   1. A START BARRIER - every writer waits inside Invoke-Locked, after its own start-up, until all four
  #      are there, so they ask for the lock together (THE BARRIER IS INSIDE THE WRITER, below).
  #   2. A STORE BIG ENOUGH TO BE SLOW - 400 seeded items put the read-modify-write in the tens of
  #      milliseconds, wide enough for four barriered writers to sit inside it at once.
  # PROVEN TO FAIL NEUTERED, 2026-08-24: with Invoke-Locked's WaitOne skipped, this measured
  # "landed 2 of 4" and seed rows dropped. Four writers, not two: losing one of four is unmistakable
  # where losing one of two reads as a coin flip.
  # HOW OFTEN, measured 2026-09-11 with WaitOne and ReleaseMutex both skipped in a temp mirror. With the barrier
  # AHEAD of each writer's start-up: red in 1 of 1 run beside 32 CPU burners and 1 of 2 without them; then, paired
  # iteration by iteration, 10 of 10 for that fixture and 10 of 10 with the barrier INSIDE the writer (below). So on
  # this ledger the move is NOT shown to raise the catch rate - it removes the start-up spread by construction, and
  # the count of writers at the barrier is asserted every run. The locked suite passed 10 of 10 either way. Load
  # uncontrolled. Harness: a scratch harness running each arm's -SelfTest back to back, at 00c3527d7 plus this change.
  $ctmp = Join-Path ([IO.Path]::GetTempPath()) ('iq-conc-' + [Guid]::NewGuid().ToString('N') + '.json')
  try {
    $stq = @{}; foreach ($sn in $STORES) { $stq[$sn] = $null }
    $seed = @(1..400 | ForEach-Object {
      [pscustomobject]@{ term = "seed $_"; recipes = @('r'); added = (Get-Stamp); why = 'seed'
                         status = 'pending'; stores = [pscustomobject]$stq; verdict = 'PENDING'; notes = $null } })
    ([pscustomobject]@{ readme = 'concurrency fixture'; items = $seed } | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $ctmp -Encoding UTF8
    # THE BARRIER IS INSIDE THE WRITER, AFTER ITS START-UP (2026-09-11). It used to sit in a Start-Job child
    # BEFORE `& powershell -File` - first a UTC instant, then a ready/go handshake - and either way each writer
    # still paid its own powershell.exe start-up, about a second and variable, AFTER it was released. That
    # spread the four further than any barrier closed, so a disabled lock was caught most runs and not all.
    # Now the writers are plain processes that wait on lib\ledger-fixture.ps1's kernel event inside
    # Invoke-Locked, immediately before WaitOne, so start-up is spent first and all four ask for the lock
    # together. The same library keeps every writer's exit code, stdout and stderr and whether it was launched,
    # reached the barrier and exited - a writer that could not run is named as that, never read as the lock
    # losing an item - and gives the writers a hang-guard lock wait in place of the production 15 s.
    $argSets = New-Object System.Collections.Generic.List[object]
    foreach ($i in 1..4) { $argSets.Add([string[]]@('-Add', '-Term', "conc term $i", '-Recipe', "recipe-$i", '-Why', 'fixture', '-QueueFile', $ctmp)) }
    $run = Invoke-TcLedgerWriters -Script $PSCommandPath -ArgSets $argSets.ToArray()
    $writers = @($run.writers)
    Write-Output ("  info  barrier: {0} of 4 writers were at the barrier when released ({1} ms)" -f $run.ready_at_go, $run.go_ms)
    $got = Read-Queue $ctmp
    $conc = @(@($got.items | Where-Object { [string]$_.term -like 'conc term *' } | ForEach-Object { [string]$_.term }) | Sort-Object)
    $seedKept = @($got.items | Where-Object { [string]$_.term -like 'seed *' }).Count
    $ran = @($writers | Where-Object { $_.ran })
    $claimed = @(@($writers | Where-Object { $_.ran -and $_.exit -eq 0 } | ForEach-Object { 'conc term ' + $_.n }) | Sort-Object)
    $why = Format-TcWriterTrouble $writers
    if ($ran.Count -ne 4) { Write-Output ("  X every writer must RUN - launched, at the barrier when the four were released together, and exited; ran " + $ran.Count + " of 4" + $why); $bad++ }
    else { Write-Output '  ok every writer ran - launched, at the barrier when the four were released together, and exited' }
    if (@($conc).Count -ne 4) { Write-Output ("  X MUST FIRE 4 barriered concurrent -Add calls must all land; landed " + @($conc).Count + " of 4: " + ($conc -join ', ') + $why); $bad++ }
    else { Write-Output '  ok 4 barriered concurrent -Add calls all landed (the map lane writes 2-wide and the pricer records in parallel)' }
    # THE MUTEX'S OWN GUARANTEE, apart from the one above: that fails on a loud refusal too, this fails only
    # when a writer said it queued the term and the term is not there (or the reverse).
    if ($ran.Count -ne 4 -or ($claimed -join ',') -ne ($conc -join ',')) { Write-Output ("  X MUST FIRE no -Add may be lost SILENTLY; landed [" + ($conc -join ',') + "], exited 0 [" + ($claimed -join ',') + "]" + $why); $bad++ }
    else { Write-Output '  ok MUST FIRE and no -Add was lost silently - the terms that landed are exactly the writers that exited 0' }
    if ($seedKept -ne 400) { Write-Output ("  X MUST FIRE the 400 items already queued must survive; kept $seedKept of 400"); $bad++ }
    else { Write-Output '  ok and not one of the 400 items already in the queue was dropped on the way' }
  } finally { if (Test-Path $ctmp) { Remove-Item $ctmp -Force -ErrorAction SilentlyContinue } }

  # MUST FIRE: AN -Add MADE WHILE A LOCK-FREE READER HOLDS THE QUEUE LANDS (2026-09-11). -Derive and the
  # pricer read this file while lanes are live, and a bare Move-Item -Force over a file another handle holds
  # fails inside the lock. The parent holds the queue the way Get-Content and Read-TextFile do (shared
  # ReadWrite, not Delete) until the child has written its .tmp, 400 ms longer, then lets go.
  $hqFile = Join-Path ([IO.Path]::GetTempPath()) ('iq-hold-' + [Guid]::NewGuid().ToString('N') + '.json')
  $hqOutF = [IO.Path]::GetTempFileName(); $hqErrF = [IO.Path]::GetTempFileName()
  try {
    ([pscustomobject]@{ readme = 'hold fixture'; items = @() } | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $hqFile -Encoding UTF8
    $hqHandle = New-Object IO.FileStream($hqFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    $hqSawTmp = $false
    try {
      # ONE-TOKEN VALUES ONLY: Start-Process joins -ArgumentList with spaces and quotes nothing, so a term with
      # a space arrives as two arguments. Its first cut passed 'held term' and queued 'held'. And no comment
      # INSIDE the continued command below: a comment ends a backtick continuation, and the second cut started
      # a bare interactive powershell that way.
      $hqProc = Start-Process -FilePath 'powershell' -PassThru -NoNewWindow `
                -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-Add','-Term','heldterm','-Recipe','recipe-held','-Why','fixture','-QueueFile',$hqFile) `
                -RedirectStandardOutput $hqOutF -RedirectStandardError $hqErrF
      $null = $hqProc.Handle   # cache the handle now, or ExitCode reads empty once the process is gone
      $hqSw = [Diagnostics.Stopwatch]::StartNew()
      while (-not (Test-Path -LiteralPath ($hqFile + '.tmp')) -and -not $hqProc.HasExited -and $hqSw.Elapsed.TotalSeconds -lt 120) { Start-Sleep -Milliseconds 10 }
      $hqSawTmp = Test-Path -LiteralPath ($hqFile + '.tmp')
      Start-Sleep -Milliseconds 400
    } finally { $hqHandle.Dispose() }
    [void]$hqProc.WaitForExit(120000)
    $hqOut = [string](Get-Content $hqOutF -Raw); if ($null -eq $hqOut) { $hqOut = '' }
    $hqDoc = Read-Queue $hqFile
    $hqLanded = (@($hqDoc.items | Where-Object { [string]$_.term -eq 'heldterm' }).Count -eq 1)
    if (-not ($hqSawTmp -and $hqProc.ExitCode -eq 0 -and $hqLanded)) {
      Write-Output ("  X MUST FIRE an -Add made while a lock-free reader holds the queue open must LAND once the reader lets go; saw_tmp=$hqSawTmp exit=" + $hqProc.ExitCode + " landed=$hqLanded out=" + $hqOut.Trim()); $bad++
    } else { Write-Output '  ok MUST FIRE an -Add made while a lock-free reader held the queue open landed once the reader let go (a bare Move-Item lost it inside the lock)' }
  } finally {
    foreach ($f in @($hqFile, ($hqFile + '.tmp'), $hqOutF, $hqErrF)) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
  }

  # =================================================================================================
  # -RecordBatch (B2 / pin P8, added 2026-08-24). ATOMIC: every row validated first, ANY invalid row
  # means NOTHING is written and every violation is named with its row.
  #
  # THREE ROWS MINIMUM ON EVERY FIXTURE, and here the size matters twice over: `@(<pipeline> |
  # ConvertFrom-Json)` on a many-element array binds ONE element of type Object[], which this estate
  # has lost two whole -BatchFile roads to and which is INVISIBLE at batch size one; and "one bad row
  # writes zero rows" cannot be told from "the write failed" at size one either.
  # =================================================================================================
  $btmp = Join-Path ([IO.Path]::GetTempPath()) ('iq-batch-' + [Guid]::NewGuid().ToString('N') + '.json')
  $bfile = Join-Path ([IO.Path]::GetTempPath()) ('iq-rows-' + [Guid]::NewGuid().ToString('N') + '.json')
  try {
    $stb = @{}; foreach ($sn in $STORES) { $stb[$sn] = $null }
    $seedB = @('saffron', 'achiote paste', 'gochujang' | ForEach-Object {
      [pscustomobject]@{ term = $_; recipes = @('r'); added = (Get-Stamp); why = 'fixture'
                         status = 'pending'; stores = [pscustomobject]$stb; verdict = 'PENDING'; notes = $null } })
    function Reset-BatchQueue {
      ([pscustomobject]@{ readme = 'batch fixture'; items = $script:seedBRows } | ConvertTo-Json -Depth 8) |
        Set-Content -LiteralPath $btmp -Encoding UTF8
    }
    $script:seedBRows = $seedB
    Reset-BatchQueue

    # ---- THE HAPPY PATH: three rows, one call, one lock take. ------------------------------------
    $good = @(
      [pscustomobject]@{ term='saffron'; store="Baker's"; state='carried'; price=28.99; size='0.03 oz'; item='Spice Islands Saffron'; evidence='jar of threads' },
      [pscustomobject]@{ term='achiote paste'; store='Aldi'; state='not-carried'; price=0; size=''; item=''; evidence='searched in-store mode' },
      [pscustomobject]@{ term='gochujang'; store='Hy-Vee'; state='blocked'; price=0; size=''; item=''; evidence='no browser in this session' })
    ($good | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $bfile -Encoding UTF8
    # NATIVE STDERR UNDER EAP=Stop (guarded 2026-08-25). This file runs at $ErrorActionPreference='Stop',
    # and "& powershell ... 2>&1" is a NATIVE command: PS 5.1 wraps each stderr line in an ErrorRecord, which
    # under Stop throws NativeCommandError and sets $? to $false even when the child returned 0. These five
    # self-test fixtures deliberately capture a child's combined output to assert on it, so the redirect is
    # correct and only the preference is wrong. Save/force/restore around the call is the shape
    # test-native-stderr-eap.ps1 accepts, and it must sit within 8 lines of the call - a guard further up
    # proves nothing about this line.
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $o = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -RecordBatch -File $bfile -QueueFile $btmp 2>&1
    $ErrorActionPreference = $prev
    $rc = $LASTEXITCODE
    $after = Read-Queue $btmp
    $sf = (Get-QueueItem $after 'saffron').stores."Baker's"
    $ap = (Get-QueueItem $after 'achiote paste').stores.'Aldi'
    $gj = (Get-QueueItem $after 'gochujang').stores.'Hy-Vee'
    if ($rc -ne 0 -or -not $sf -or -not $ap -or -not $gj) {
      Write-Output ("  X MUST FIRE one -RecordBatch call must land ALL THREE records; rc=$rc " + ($o -join ' | ')); $bad++
    } else { Write-Output '  ok one -RecordBatch call landed three records across three terms and three stores' }
    if ($sf -and ([double]$sf.price -ne 28.99 -or [string]$sf.item -ne 'Spice Islands Saffron' -or [string]$sf.evidence -ne 'jar of threads')) {
      Write-Output '  X MUST FIRE the batch road must carry price, item and evidence exactly as -Record does'; $bad++
    } else { Write-Output '  ok and each row carried its price, item and evidence through unchanged' }
    if ((Get-QueueItem $after 'saffron').verdict -ne 'CARRIED' -or (Get-QueueItem $after 'saffron').status -ne 'resolved') {
      Write-Output '  X MUST FIRE Rule B must be applied per row - one carried store resolves the term'; $bad++
    } else { Write-Output '  ok Rule B applied per row: one carried store resolved saffron' }
    if ((Get-QueueItem $after 'gochujang').verdict -ne 'PENDING') {
      Write-Output '  X MUST FIRE a BLOCKED store is not a check - the term must stay PENDING'; $bad++
    } else { Write-Output '  ok CLEAN TWIN a blocked store left its term PENDING (unchecked is never not-carried)' }

    # ---- ATOMICITY: one bad row writes ZERO rows. ------------------------------------------------
    Reset-BatchQueue
    $mixed = @(
      [pscustomobject]@{ term='saffron'; store="Baker's"; state='carried'; price=28.99; size=''; item='x'; evidence='e' },
      [pscustomobject]@{ term='achiote paste'; store='Sams Club'; state='not-carried'; price=0; size=''; item=''; evidence='e' },
      [pscustomobject]@{ term='gochujang'; store='Hy-Vee'; state='blocked'; price=0; size=''; item=''; evidence='e' })
    ($mixed | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $bfile -Encoding UTF8
    # stderr redirect on a native child under EAP=Stop - see the note at the first fixture above.
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $o2 = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -RecordBatch -File $bfile -QueueFile $btmp 2>&1
    $ErrorActionPreference = $prev
    $rc2 = $LASTEXITCODE
    $after2 = Read-Queue $btmp
    $wrote = @(@($after2.items) | Where-Object { @($_.stores.PSObject.Properties | Where-Object { $null -ne $_.Value }).Count -gt 0 }).Count
    if ($rc2 -ne 1 -or $wrote -ne 0) {
      Write-Output ("  X MUST FIRE one contract-violating row must write ZERO rows and exit 1; rc=$rc2 rows_written=$wrote"); $bad++
    } else { Write-Output '  ok MUST FIRE a 3-row batch with ONE bad row wrote zero rows and exited 1 - a partly-applied batch is a hole in the evidence' }
    if (($o2 -join ' ') -notmatch "row 2" -or ($o2 -join ' ') -notmatch "Sams Club") {
      Write-Output ("  X MUST FIRE the violation must be NAMED with its row, so the pricer gets one correction pass; got: " + ($o2 -join ' | ')); $bad++
    } else { Write-Output "  ok and the violation was named with its row number and the offending store ('Sams Club' - the silent eighth store)" }

    # a carried row with no price is the OTHER contract rule, and it refuses the batch too
    Reset-BatchQueue
    $nopr = @(
      [pscustomobject]@{ term='saffron'; store="Baker's"; state='not-carried'; price=0; size=''; item=''; evidence='e' },
      [pscustomobject]@{ term='achiote paste'; store='Aldi'; state='carried'; price=0; size=''; item='paste'; evidence='e' },
      [pscustomobject]@{ term='gochujang'; store='Fareway'; state='error'; price=0; size=''; item=''; evidence='e' })
    ($nopr | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $bfile -Encoding UTF8
    # stderr redirect on a native child under EAP=Stop - see the note at the first fixture above.
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $o3 = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -RecordBatch -File $bfile -QueueFile $btmp 2>&1
    $ErrorActionPreference = $prev
    $rc3 = $LASTEXITCODE
    $after3 = Read-Queue $btmp
    $wrote3 = @(@($after3.items) | Where-Object { @($_.stores.PSObject.Properties | Where-Object { $null -ne $_.Value }).Count -gt 0 }).Count
    if ($rc3 -ne 1 -or $wrote3 -ne 0 -or ($o3 -join ' ') -notmatch 'no price') {
      Write-Output ("  X MUST FIRE carried-with-no-price must refuse the WHOLE batch; rc=$rc3 rows=$wrote3 " + ($o3 -join ' | ')); $bad++
    } else { Write-Output '  ok MUST FIRE a carried row with no price refuses the whole batch - a carriage claim with no price is not evidence' }

    # a term nobody queued cannot be recorded against, and that check is INSIDE the lock
    Reset-BatchQueue
    $unq = @(
      [pscustomobject]@{ term='saffron'; store="Baker's"; state='not-carried'; price=0; size=''; item=''; evidence='e' },
      [pscustomobject]@{ term='never queued'; store='Aldi'; state='not-carried'; price=0; size=''; item=''; evidence='e' },
      [pscustomobject]@{ term='gochujang'; store='Fareway'; state='not-carried'; price=0; size=''; item=''; evidence='e' })
    ($unq | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $bfile -Encoding UTF8
    # stderr redirect on a native child under EAP=Stop - see the note at the first fixture above.
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $o4 = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -RecordBatch -File $bfile -QueueFile $btmp 2>&1
    $ErrorActionPreference = $prev
    $rc4 = $LASTEXITCODE
    $after4 = Read-Queue $btmp
    $wrote4 = @(@($after4.items) | Where-Object { @($_.stores.PSObject.Properties | Where-Object { $null -ne $_.Value }).Count -gt 0 }).Count
    if ($rc4 -ne 1 -or $wrote4 -ne 0) {
      Write-Output ("  X MUST FIRE a row naming an unqueued term must refuse the whole batch; rc=$rc4 rows=$wrote4"); $bad++
    } else { Write-Output '  ok MUST FIRE a row naming an unqueued term refuses the whole batch, and that check runs INSIDE the lock' }

    # ---- THE TWO ROADS ENFORCE THE SAME CONTRACT, ROW FOR ROW. ------------------------------------
    # -Record and -RecordBatch run the SAME validator, which is why it is a function. This asserts it
    # rather than trusting it, because two copies of a rule is the forked-taxonomy defect.
    $sameRules = $true
    foreach ($case in @(
        @{ row = [pscustomobject]@{ term='t'; store='Bakers'; state='carried'; price=1 }; why = 'unknown store' },
        @{ row = [pscustomobject]@{ term='t'; store="Baker's"; state='carried'; price=0 }; why = 'carried with no price' },
        @{ row = [pscustomobject]@{ term=''; store="Baker's"; state='carried'; price=1 }; why = 'no term' })) {
      if (-not @(Test-BatchRow $case.row 0 $STORES).Count) { $sameRules = $false; Write-Output ("  X the shared validator missed: " + $case.why); $bad++ }
    }
    if ($sameRules) { Write-Output '  ok -Record and -RecordBatch run ONE validator, and it catches all three contract rules' }
    if (@(Test-BatchRow ([pscustomobject]@{ term='t'; store="Sam's Club"; state='blocked'; price=0 }) 0 $STORES).Count) {
      Write-Output '  X CLEAN TWIN a legal blocked row with no price must pass - only CARRIED needs one'; $bad++
    } else { Write-Output '  ok CLEAN TWIN a legal blocked row with no price passes: only CARRIED needs a price' }
    # and the ValidateSet on -State is PowerShell's own copy of the same list. It cannot reference a
    # variable, so the two are pinned to each other here rather than left to drift.
    $psSet = @((Get-Command $PSCommandPath).Parameters['State'].Attributes |
               Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } |
               ForEach-Object { $_.ValidValues } | Where-Object { $_ })
    if ((@($psSet | Sort-Object) -join ',') -ne (@($script:BATCH_STATES | Sort-Object) -join ',')) {
      Write-Output ("  X MUST FIRE -State's ValidateSet and BATCH_STATES have drifted: [" + ($psSet -join ',') + "] vs [" + ($script:BATCH_STATES -join ',') + "]"); $bad++
    } else { Write-Output '  ok -State''s ValidateSet and the batch state enum are the same set (PowerShell cannot share the variable, so it is pinned here)' }
  } finally {
    foreach ($f in @($btmp, $bfile)) { if (Test-Path $f) { Remove-Item $f -Force -ErrorAction SilentlyContinue } }
  }

  # MUST FIRE (H2, 2026-08-25): -Promote WRITES WHERE -CarriagePath SAYS, and nowhere else.
  # Measured on the jc1 drill: a run with --ledger, --specs, --costed, --food-db and NO --publish
  # still wrote the live grocery\carriage.json, because this verb resolved that path itself. The
  # seam is proven by driving the real -Promote in a child process over a scratch queue and a
  # scratch ledger, and asserting the LIVE ledger's bytes are untouched.
  # NEUTER PROOF, RUN 2026-08-25: revert $ledgerFile to the hardcoded Join-Path and this case fails
  # on the scratch ledger still holding zero bids (the row went to the live file instead).
  # THE "NOWHERE ELSE" HALF WAS INERT FROM 2026-08-25 TO 2026-09-11. It read `(Get-Item $live).Length`, and this
  # file then defined its queue lookup as Get-Item($doc, $term): a script function outranks the cmdlet, the lookup
  # returned nothing for a path, and .Length on nothing is 0, before and after, whatever -Promote did. The neuter
  # above could not show it, because a -Promote that ignores -CarriagePath leaves the scratch ledger empty and the
  # FIRST half fires. The live ledger is now compared by md5 (Get-FileHash), and the two halves are asserted
  # separately so each names its own failure. The same day the lookup was renamed Get-QueueItem, and
  # ops\audit-cmdlet-shadow.ps1 now fails a push that defines a function named after a built-in command.
  # NEUTER PROOF, RUN 2026-09-11, in a temp mirror holding the whole lib\ and a copy of carriage.json, both restored
  # by md5 before every arm, one run per arm. A -Promote that writes the -CarriagePath ledger AND the mirror's own
  # carriage.json: the old assertion PASSED with that ledger's md5 changed; this one goes red on the live line
  # alone. A -Promote that ignores -CarriagePath: red on both halves here, on the scratch half alone before. Clean
  # arms green before and after. Harness: a scratch harness running each arm's -SelfTest, at c17cc59a7 plus this change.
  $ctmp = Join-Path ([IO.Path]::GetTempPath()) ('iq-carriage-' + [Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $ctmp | Out-Null
  try {
    $cq = Join-Path $ctmp 'queue.json'
    $cl = Join-Path $ctmp 'carriage.json'
    $live = Join-Path $root 'carriage.json'   # LIVE-TWIN on purpose: the live ledger is the thing asserted UNTOUCHED, and it is read only as an md5
    $liveBefore = $(if (Test-Path -LiteralPath $live) { (Get-FileHash -LiteralPath $live -Algorithm MD5).Hash } else { 'absent' })
    $st = @{}; foreach ($s in $STORES) { $st[$s] = [pscustomobject]@{ state = 'not-carried'; evidence = 'fixture' } }
    $st["Baker's"] = [pscustomobject]@{ state = 'carried'; price = 3.49; item = 'Fixture Saffron'; size = '1 g'; evidence = 'fixture' }
    $qd = [pscustomobject]@{ items = @([pscustomobject]@{ term = 'fixture-saffron'; recipes = @('x'); added = (Get-Stamp); status = 'pending'; stores = [pscustomobject]$st; verdict = 'PENDING'; notes = $null }) }
    Write-Queue $qd $cq
    ([pscustomobject]@{ bids = [pscustomobject]@{} } | ConvertTo-Json -Depth 6) | Set-Content $cl -Encoding UTF8
    # stderr redirect on a native child under EAP=Stop - see the note at the first fixture above.
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $o = & powershell -NoProfile -File $PSCommandPath -Promote -Term 'fixture-saffron' -Bid 'fixture-saffron' -QueueFile $cq -CarriagePath $cl 2>&1
    $ErrorActionPreference = $prev
    $prc = $LASTEXITCODE
    $got = Read-JsonFile $cl
    $liveAfter = $(if (Test-Path -LiteralPath $live) { (Get-FileHash -LiteralPath $live -Algorithm MD5).Hash } else { 'absent' })
    if ($prc -ne 0 -or -not ($got.bids.PSObject.Properties.Name -contains 'fixture-saffron')) {
      Write-Output ("  X MUST FIRE -Promote must write the SCRATCH ledger -CarriagePath names; rc=$prc " + ($o -join ' | ')); $bad++
    } else { Write-Output '  ok MUST FIRE -Promote writes the ledger -CarriagePath names' }
    # The fingerprint must be a real one before it can be compared: a lookup that returns nothing reads the
    # same before and after, which is exactly how this half went inert.
    if ($liveBefore -notmatch '^(absent|[0-9A-F]{32})$') {
      Write-Output ("  X the live carriage.json fingerprint is not an md5, so the untouched check below cannot fire; got [" + $liveBefore + "]"); $bad++
    } elseif (-not [string]::Equals($liveBefore, $liveAfter, [StringComparison]::Ordinal)) {
      Write-Output ("  X MUST FIRE -Promote wrote the LIVE carriage.json while -CarriagePath pointed elsewhere; md5 $liveBefore -> $liveAfter"); $bad++
    } else {
      Write-Output '  ok MUST FIRE and it leaves the live carriage.json byte-identical by md5 - a no-publish drill must not write a live grocery ledger'
    }
  } finally { Remove-Item $ctmp -Recurse -Force -ErrorAction SilentlyContinue }

  if ($bad -eq 0) { Write-Output 'ingredient-queue SELF-TEST PASS (Rule B: one carried is enough; unchecked/blocked/errored is never not-carried; file round-trips; concurrent writers lose nothing; -RecordBatch is atomic)'; exit 0 }
  Write-Output ("ingredient-queue SELF-TEST FAIL ({0} problem(s))" -f $bad); exit 1
}

$doc = Read-Queue $QueueFile

if ($Add) {
  if (-not $Term) { Write-Output 'ingredient-queue: -Add needs -Term'; exit 1 }
  # RE-READ INSIDE THE LOCK. $doc above was read before the mutex was taken; merging into it here
  # would drop whatever another writer landed in between - the exact race the lock exists to close.
  $script:addMsg = ''
  Invoke-Locked -Path $QueueFile -Body {
    $fresh = Read-Queue $QueueFile
    $e = Get-QueueItem $fresh $Term
    if ($e) {
      if ($Recipe -and @($e.recipes) -notcontains $Recipe) { $e.recipes = @(@($e.recipes) + $Recipe) }
      Write-Queue $fresh $QueueFile
      $script:addMsg = ("ingredient-queue: '{0}' already queued (status {1}); recipes now: {2}" -f $Term, $e.status, (@($e.recipes) -join ', '))
      return
    }
    $st = @{}; foreach ($s in $STORES) { $st[$s] = $null }
    $new = [pscustomobject]@{ term = $Term; recipes = @($Recipe | Where-Object { $_ }); added = (Get-Stamp)
                              why = $Why; status = 'pending'; stores = [pscustomobject]$st; verdict = 'PENDING'; notes = $null }
    $fresh.items = @(@($fresh.items) + $new)
    Write-Queue $fresh $QueueFile
    $script:addMsg = ("ingredient-queue: queued '{0}'  (0 of 7 stores checked)" -f $Term)
  }
  Write-Output $script:addMsg
  exit 0
}

if ($Record) {
  if (-not $Term -or -not $Store -or -not $State) { Write-Output 'ingredient-queue: -Record needs -Term, -Store and -State'; exit 1 }
  # THE SAME VALIDATOR -RecordBatch USES. It now names EVERY violation rather than the first, which is
  # the same courtesy the batch road extends: one correction pass, not one per round trip.
  $rowBad = Test-BatchRow ([pscustomobject]@{ term=$Term; store=$Store; state=$State; price=$Price }) 0 $STORES
  if (@($rowBad).Count) { foreach ($v in $rowBad) { Write-Output ("ingredient-queue: " + $v) }; exit 1 }
  $script:recMsg = ''; $script:recRc = 0
  Invoke-Locked -Path $QueueFile -Body {
    $fresh = Read-Queue $QueueFile
    $e = Get-QueueItem $fresh $Term
    if (-not $e) { $script:recMsg = ("ingredient-queue: '{0}' is not queued - -Add it first" -f $Term); $script:recRc = 1; return }
    $e.stores.$Store = [pscustomobject]@{ state = $State; price = $(if ($Price -gt 0) { $Price } else { $null })
                                          size = $Size; item = $Item; evidence = $Evidence; checked = (Get-Stamp) }
    $v = Get-QueueVerdict $e $STORES $TERMINAL
    $e.verdict = $v.verdict
    $e.status = $(if ($v.verdict -eq 'PENDING') { 'pending' } else { 'resolved' })
    Write-Queue $fresh $QueueFile
    $script:recMsg = ("ingredient-queue: '{0}' @ {1} = {2}   ->  {3}  ({4} of 7 checked{5})" -f $Term, $Store, $State, $v.verdict, $v.checked.Count, $(if ($v.carried_by.Count) { ', carried by ' + ($v.carried_by -join ', ') } else { '' }))
  }
  Write-Output $script:recMsg
  exit $script:recRc
}

# ---------------------------------------------------------------------------------------------------
# -RecordBatch (B2, added 2026-08-24, phase 6a / cold-read pin P8).
#
# WHY. Seven stores x five terms is ~35 separate -Record invocations, and under the v3 daemon each one
# is a TURN in the pricer's session - the single largest turn sink in the price lane, measured on the
# phase-5 gate run. The pen stays with the pricer and the enforcement stays at the script layer; only
# the number of round trips changes.
#
# IT IS ATOMIC, AND THAT IS THE POINT RATHER THAN A DETAIL. EVERY row is validated FIRST, under exactly
# -Record's rules (the same function, above), and if ANY row is invalid then NOTHING is written, the
# exit is 1, and every violation is named with its row. The pricer gets ONE correction pass instead of
# a silent hole in its evidence - and a hole in the evidence is precisely what the per-store record
# exists to prevent.
#
# ONE MUTEX TAKE for the whole batch, and the document is re-read INSIDE it, exactly as -Add and
# -Record do. -Verdict and -Promote stay per-term and are untouched: a verdict is a reading of one
# term's rows, and promotion writes a different ledger under its own lock.
if ($RecordBatch) {
  if (-not $File) { Write-Output 'ingredient-queue: -RecordBatch needs -File (a JSON array of {term, store, state, price, size, item, evidence})'; exit 1 }
  if (-not (Test-Path $File)) { Write-Output ("ingredient-queue: no batch file at {0}" -f $File); exit 1 }
  $rows = $null
  try {
    $btext = [IO.File]::ReadAllText($File, [Text.Encoding]::UTF8) -replace '^﻿', ''
    # ASSIGN FIRST, THEN WRAP. `@(<pipeline> | ConvertFrom-Json)` on a MANY-element array binds ONE
    # element of type Object[]; the estate has lost two whole -BatchFile roads to that, and it is
    # invisible at batch size one - exactly the size a first fixture reaches for.
    $parsed = ($btext | ConvertFrom-Json)
    $rows = @($parsed)
  } catch {
    Write-Output ("ingredient-queue: the batch file would not parse: {0}" -f $_.Exception.Message); exit 1
  }
  if (-not @($rows).Count) { Write-Output 'ingredient-queue: the batch file holds no rows'; exit 1 }

  # ---- VALIDATE EVERY ROW FIRST. Nothing is opened for writing until all of them are legal. -------
  $violations = @()
  for ($i = 0; $i -lt @($rows).Count; $i++) {
    $violations += (Test-BatchRow @($rows)[$i] ($i + 1) $STORES)
  }
  if (@($violations).Count) {
    Write-Output ("ingredient-queue: -RecordBatch REFUSED - {0} violation(s) across {1} row(s). NOTHING was written." -f @($violations).Count, @($rows).Count)
    foreach ($v in $violations) { Write-Output ("    " + $v) }
    Write-Output '   Fix the named rows and re-send the WHOLE batch. A partly-applied batch is a hole in the evidence, which is the thing the per-store record exists to prevent.'
    exit 1
  }

  $script:batchMsg = @()
  $script:batchRc = 0
  Invoke-Locked -Path $QueueFile -Body {
    $fresh = Read-Queue $QueueFile
    # A SECOND PASS INSIDE THE LOCK, for the one thing the pure validator cannot know: whether the
    # term is actually queued. Still all-or-nothing - the document is not touched until every row has
    # somewhere to land.
    $missing = @()
    for ($i = 0; $i -lt @($rows).Count; $i++) {
      $t = [string](@($rows)[$i].term)
      if (-not (Get-QueueItem $fresh $t)) { $missing += ("row {0}: '{1}' is not queued - -Add it first" -f ($i + 1), $t) }
    }
    if (@($missing).Count) {
      $script:batchMsg = @(("ingredient-queue: -RecordBatch REFUSED - {0} row(s) name a term that is not queued. NOTHING was written." -f @($missing).Count)) + @($missing | ForEach-Object { "    " + $_ })
      $script:batchRc = 1
      return
    }
    $lines = @()
    foreach ($r in @($rows)) {
      $t = [string]$r.term
      $e = Get-QueueItem $fresh $t
      $pr = 0.0; if ($null -ne $r.price) { try { $pr = [double]$r.price } catch { $pr = 0.0 } }
      $e.stores.([string]$r.store) = [pscustomobject]@{ state = [string]$r.state
                                                        price = $(if ($pr -gt 0) { $pr } else { $null })
                                                        size = [string]$r.size; item = [string]$r.item
                                                        evidence = [string]$r.evidence; checked = (Get-Stamp) }
      $v = Get-QueueVerdict $e $STORES $TERMINAL
      $e.verdict = $v.verdict
      $e.status = $(if ($v.verdict -eq 'PENDING') { 'pending' } else { 'resolved' })
      $lines += ("  {0,-22} @ {1,-13} = {2,-12} ->  {3} ({4} of 7 checked)" -f $t, [string]$r.store, [string]$r.state, $v.verdict, $v.checked.Count)
    }
    Write-Queue $fresh $QueueFile
    $script:batchMsg = @(("ingredient-queue: -RecordBatch wrote {0} record(s) in ONE take of the write lock" -f @($rows).Count)) + $lines
  }
  foreach ($m in $script:batchMsg) { Write-Output $m }
  exit $script:batchRc
}

if ($Verdict) {
  if (-not $Term) { Write-Output 'ingredient-queue: -Verdict needs -Term'; exit 1 }
  $e = Get-QueueItem $doc $Term
  if (-not $e) { Write-Output ("ingredient-queue: '{0}' is not queued" -f $Term); exit 1 }
  $v = Get-QueueVerdict $e $STORES $TERMINAL
  if ($Json) { ([pscustomobject]@{ term = $Term; verdict = $v.verdict; carried_by = @($v.carried_by); checked = @($v.checked); unchecked = @($STORES | Where-Object { $v.checked -notcontains $_ }) } | ConvertTo-Json -Depth 5); exit 0 }
  Write-Output ("{0}  '{1}'" -f $v.verdict, $Term)
  Write-Output ("   checked   {0} of 7: {1}" -f $v.checked.Count, $(if ($v.checked.Count) { $v.checked -join ', ' } else { 'none' }))
  Write-Output ("   carried by: {0}" -f $(if ($v.carried_by.Count) { $v.carried_by -join ', ' } else { 'none yet' }))
  $un = @($STORES | Where-Object { $v.checked -notcontains $_ })
  if ($un.Count) { Write-Output ("   STILL UNCHECKED: {0}  (unchecked is not not-carried)" -f ($un -join ', ')) }
  exit 0
}

# ---- -Promote --------------------------------------------------------------------------------------
# Write a settled queue verdict into grocery\carriage.json, keyed by BID, where every gate can read it.
#
# WHY THIS EXISTS. The queue is per-RUN and keyed by TERM; the gates are permanent and keyed by BID. Until
# these were joined, a pricer could check all seven stores, prove an ingredient absent, and that finding
# died with the run - the cost engine and the publish gate never saw it. Promotion is what makes a
# pricer's work durable. PENDING never promotes: an unfinished check is not a fact.
if ($Promote) {
  if (-not $Term) { Write-Output 'ingredient-queue: -Promote needs -Term'; exit 1 }
  if (-not $Bid)  { Write-Output 'ingredient-queue: -Promote needs -Bid (the commodity id, or "item:<Item Name>" for a bid-less ingredient) - the ledger is keyed by bid, not by term'; exit 1 }
  $e = Get-QueueItem $doc $Term
  if (-not $e) { Write-Output ("ingredient-queue: '{0}' is not queued" -f $Term); exit 1 }
  $v = Get-QueueVerdict $e $STORES $TERMINAL
  if ($v.verdict -eq 'PENDING') {
    Write-Output ("ingredient-queue: REFUSED to promote '{0}' - verdict is PENDING ({1} of 7 checked). An unfinished check is not a fact." -f $Term, $v.checked.Count)
    exit 1
  }
  $ledgerFile = $(if ($CarriagePath) { $CarriagePath } else { Join-Path $root 'carriage.json' })
  if (-not (Test-Path $ledgerFile)) { Write-Output ("ingredient-queue: no ledger at " + $ledgerFile); exit 1 }
  # carriage.json is ANOTHER single-file ledger, so its read-modify-write takes the same lock, keyed
  # on ITS path. The pricer is a singleton, but nothing about this script knows that, and a rule that
  # depends on the caller's cap is a rule the next cap change silently breaks.
  $led = Read-JsonFile $ledgerFile
  $stamp = (Get-Date -Format 'yyyy-MM-dd')
  if ($v.verdict -eq 'CARRIED') {
    # the cheapest carrying store's own row is the evidence
    $best = $null
    foreach ($s in $v.carried_by) {
      $r = $e.stores.$s
      if ($null -eq $best -or ([double]$r.price -gt 0 -and [double]$r.price -lt [double]$best.price)) { $best = [pscustomobject]@{ store = $s; price = [double]$r.price; item = [string]$r.item; size = [string]$r.size } }
    }
    $entry = [pscustomobject]@{ verdict = 'CARRIED'; store = $best.store; item = $best.item; size = $best.size
                                price = $best.price; as_of = $stamp
                                source = ("promoted from ingredient-queue term '" + $Term + "'")
                                why = ("carried by " + ($v.carried_by -join ', ')) }
  } else {
    # NOTE: this local MUST NOT be named $stores. PowerShell variable names are case-insensitive, so
    # $stores and the module-level $STORES are the SAME variable: assigning an empty pscustomobject
    # here silently emptied the list the very next foreach iterates, and this whole NOT-CARRIED branch
    # died with "NotePropertyName is null or empty" on every call. Fixed 2026-08-29.
    $storeMap = [pscustomobject]@{}
    foreach ($s in $STORES) {
      $r = $e.stores.$s
      $storeMap | Add-Member -NotePropertyName $s -NotePropertyValue ([pscustomobject]@{
        state = [string]$r.state
        terms_tried = @($(if ($r.PSObject.Properties.Name -contains 'terms_tried' -and @($r.terms_tried).Count) { $r.terms_tried } else { @($Term) }))
        evidence = [string]$r.evidence })
    }
    $entry = [pscustomobject]@{ verdict = 'NOT-CARRIED'; as_of = $stamp; stores = $storeMap
                                source = ("promoted from ingredient-queue term '" + $Term + "'")
                                why = ("all seven Omaha stores answered and none carry it") }
  }
  Invoke-Locked -Path $ledgerFile -Body {
    # re-read inside the lock; $entry was computed from the queue, which is not the file under edit
    $freshLed = Read-JsonFile $ledgerFile
    if ($freshLed.bids.PSObject.Properties.Name -contains $Bid) { $freshLed.bids.$Bid = $entry }
    else { $freshLed.bids | Add-Member -NotePropertyName $Bid -NotePropertyValue $entry }
    # Through lib\atomic-write.ps1 for the same reason as Write-Queue: carriage.json has lock-free readers.
    [void](Write-TcAtomicFile -Path $ledgerFile -Text ($freshLed | ConvertTo-Json -Depth 12))
  }
  Write-Output ("ingredient-queue: promoted '{0}' -> carriage.json[{1}] = {2}" -f $Term, $Bid, $v.verdict)
  Write-Output '   recost (meal-prep\engine\cost-recipes.ps1) for the gates to see it.'
  exit 0
}

# default: list
$items = @($doc.items)
if ($Status) { $items = @($items | Where-Object { [string]$_.status -eq $Status }) }
if ($Json) { ([pscustomobject]@{ queue = (Split-Path $QueueFile -Leaf); count = $items.Count; items = $items } | ConvertTo-Json -Depth 8); exit 0 }
Write-Output ("ingredient-queue: {0} item(s){1}" -f $items.Count, $(if ($Status) { " with status '$Status'" } else { '' }))
foreach ($e in $items) {
  $v = Get-QueueVerdict $e $STORES $TERMINAL
  Write-Output ''
  Write-Output ("  {0,-11} {1}" -f $v.verdict, $e.term)
  Write-Output ("     queued {0}   recipes: {1}" -f $e.added, $(if (@($e.recipes).Count) { @($e.recipes) -join ', ' } else { '-' }))
  Write-Output ("     {0} of 7 checked{1}" -f $v.checked.Count, $(if ($v.carried_by.Count) { '; carried by ' + ($v.carried_by -join ', ') } else { '' }))
  foreach ($s in $STORES) {
    $r = $e.stores.$s
    if ($r) { Write-Output ("       {0,-13} {1,-12} {2}" -f $s, $r.state, $(if ($r.price) { '$' + $r.price + '  ' + $r.item } else { [string]$r.evidence })) }
  }
}
