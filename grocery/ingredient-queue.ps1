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
  $t = $path + '.tmp'
  ($doc | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $t -Encoding UTF8
  Move-Item -LiteralPath $t -Destination $path -Force
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

function Invoke-Locked {
  param([scriptblock]$Body, [string]$Path)
  $key = 'Global\tc-ingredient-queue-' + ([Math]::Abs($Path.ToLower().GetHashCode())).ToString()
  $mx = New-Object System.Threading.Mutex($false, $key)
  $held = $false
  try {
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
function Get-Item($doc, [string]$term) {
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
  #   1. A START BARRIER - every child spins until the same UTC instant, entering together.
  #   2. A STORE BIG ENOUGH TO BE SLOW - 400 seeded items put the read-modify-write in the tens of
  #      milliseconds, wide enough for four barriered writers to sit inside it at once.
  # PROVEN TO FAIL NEUTERED, 2026-08-24: with Invoke-Locked's WaitOne skipped, this measured
  # "landed 2 of 4" and seed rows dropped. Four writers, not two: losing one of four is unmistakable
  # where losing one of two reads as a coin flip.
  $ctmp = Join-Path ([IO.Path]::GetTempPath()) ('iq-conc-' + [Guid]::NewGuid().ToString('N') + '.json')
  try {
    $stq = @{}; foreach ($sn in $STORES) { $stq[$sn] = $null }
    $seed = @(1..400 | ForEach-Object {
      [pscustomobject]@{ term = "seed $_"; recipes = @('r'); added = (Get-Stamp); why = 'seed'
                         status = 'pending'; stores = [pscustomobject]$stq; verdict = 'PENDING'; notes = $null } })
    ([pscustomobject]@{ readme = 'concurrency fixture'; items = $seed } | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $ctmp -Encoding UTF8
    $barrier = (Get-Date).ToUniversalTime().AddSeconds(4).ToString('o')
    $jobs = @()
    foreach ($i in 1..4) {
      $jobs += Start-Job -ScriptBlock {
        param($script, $qf, $n, $go)
        $t = [datetime]::Parse($go, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
        while ((Get-Date).ToUniversalTime() -lt $t) { Start-Sleep -Milliseconds 2 }
        & powershell -NoProfile -ExecutionPolicy Bypass -File $script -Add -Term ("conc term $n") -Recipe ("recipe-$n") -Why 'fixture' -QueueFile $qf | Out-Null
      } -ArgumentList $PSCommandPath, $ctmp, $i, $barrier
    }
    $jobs | Wait-Job -Timeout 180 | Out-Null
    $jobs | Remove-Job -Force -ErrorAction SilentlyContinue
    $got = Read-Queue $ctmp
    $conc = @(@($got.items | Where-Object { [string]$_.term -like 'conc term *' } | ForEach-Object { [string]$_.term }) | Sort-Object)
    $seedKept = @($got.items | Where-Object { [string]$_.term -like 'seed *' }).Count
    if (@($conc).Count -ne 4) { Write-Output ("  X MUST FIRE 4 barriered concurrent -Add calls must all land; landed " + @($conc).Count + " of 4: " + ($conc -join ', ')); $bad++ }
    else { Write-Output '  ok 4 barriered concurrent -Add calls all landed (the map lane writes 2-wide and the pricer records in parallel)' }
    if ($seedKept -ne 400) { Write-Output ("  X MUST FIRE the 400 items already queued must survive; kept $seedKept of 400"); $bad++ }
    else { Write-Output '  ok and not one of the 400 items already in the queue was dropped on the way' }
  } finally { if (Test-Path $ctmp) { Remove-Item $ctmp -Force -ErrorAction SilentlyContinue } }

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
    $sf = (Get-Item $after 'saffron').stores."Baker's"
    $ap = (Get-Item $after 'achiote paste').stores.'Aldi'
    $gj = (Get-Item $after 'gochujang').stores.'Hy-Vee'
    if ($rc -ne 0 -or -not $sf -or -not $ap -or -not $gj) {
      Write-Output ("  X MUST FIRE one -RecordBatch call must land ALL THREE records; rc=$rc " + ($o -join ' | ')); $bad++
    } else { Write-Output '  ok one -RecordBatch call landed three records across three terms and three stores' }
    if ($sf -and ([double]$sf.price -ne 28.99 -or [string]$sf.item -ne 'Spice Islands Saffron' -or [string]$sf.evidence -ne 'jar of threads')) {
      Write-Output '  X MUST FIRE the batch road must carry price, item and evidence exactly as -Record does'; $bad++
    } else { Write-Output '  ok and each row carried its price, item and evidence through unchanged' }
    if ((Get-Item $after 'saffron').verdict -ne 'CARRIED' -or (Get-Item $after 'saffron').status -ne 'resolved') {
      Write-Output '  X MUST FIRE Rule B must be applied per row - one carried store resolves the term'; $bad++
    } else { Write-Output '  ok Rule B applied per row: one carried store resolved saffron' }
    if ((Get-Item $after 'gochujang').verdict -ne 'PENDING') {
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
  $ctmp = Join-Path ([IO.Path]::GetTempPath()) ('iq-carriage-' + [Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $ctmp | Out-Null
  try {
    $cq = Join-Path $ctmp 'queue.json'
    $cl = Join-Path $ctmp 'carriage.json'
    $live = Join-Path $root 'carriage.json'
    $liveBefore = $(if (Test-Path $live) { (Get-Item $live).Length } else { -1 })
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
    $liveAfter = $(if (Test-Path $live) { (Get-Item $live).Length } else { -1 })
    if ($prc -ne 0 -or -not ($got.bids.PSObject.Properties.Name -contains 'fixture-saffron')) {
      Write-Output ("  X MUST FIRE -Promote must write the SCRATCH ledger -CarriagePath names; rc=$prc " + ($o -join ' | ')); $bad++
    } elseif ($liveAfter -ne $liveBefore) {
      Write-Output '  X MUST FIRE -Promote wrote the LIVE carriage.json while -CarriagePath pointed elsewhere'; $bad++
    } else {
      Write-Output '  ok MUST FIRE -Promote writes the ledger -CarriagePath names and leaves the live one untouched - a no-publish drill must not write a live grocery ledger'
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
    $e = Get-Item $fresh $Term
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
    $e = Get-Item $fresh $Term
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
      if (-not (Get-Item $fresh $t)) { $missing += ("row {0}: '{1}' is not queued - -Add it first" -f ($i + 1), $t) }
    }
    if (@($missing).Count) {
      $script:batchMsg = @(("ingredient-queue: -RecordBatch REFUSED - {0} row(s) name a term that is not queued. NOTHING was written." -f @($missing).Count)) + @($missing | ForEach-Object { "    " + $_ })
      $script:batchRc = 1
      return
    }
    $lines = @()
    foreach ($r in @($rows)) {
      $t = [string]$r.term
      $e = Get-Item $fresh $t
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
  $e = Get-Item $doc $Term
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
  $e = Get-Item $doc $Term
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
    $t = $ledgerFile + '.tmp'
    ($freshLed | ConvertTo-Json -Depth 12) | Set-Content $t -Encoding UTF8
    Move-Item -LiteralPath $t -Destination $ledgerFile -Force
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
