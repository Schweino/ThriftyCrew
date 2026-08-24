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
    .\ingredient-queue.ps1 -Verdict -Term 'saffron'
    .\ingredient-queue.ps1 -SelfTest
#>
param(
  [switch]$Add,
  [switch]$List,
  [switch]$Record,
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
  [switch]$Json,
  [switch]$IngredientQueueSelfTest,
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
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

  if ($bad -eq 0) { Write-Output 'ingredient-queue SELF-TEST PASS (Rule B: one carried is enough; unchecked/blocked/errored is never not-carried; file round-trips; concurrent writers lose nothing)'; exit 0 }
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
  if ($STORES -notcontains $Store) { Write-Output ("ingredient-queue: unknown store '{0}'. Must be exactly one of: {1}" -f $Store, ($STORES -join ', ')); exit 1 }
  if ($State -eq 'carried' -and $Price -le 0) { Write-Output 'ingredient-queue: a carried store needs -Price. A carriage claim with no price is not evidence.'; exit 1 }
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
  $ledgerFile = Join-Path $root 'carriage.json'
  if (-not (Test-Path $ledgerFile)) { Write-Output ("ingredient-queue: no ledger at " + $ledgerFile); exit 1 }
  # carriage.json is ANOTHER single-file ledger, so its read-modify-write takes the same lock, keyed
  # on ITS path. The pricer is a singleton, but nothing about this script knows that, and a rule that
  # depends on the caller's cap is a rule the next cap change silently breaks.
  $led = Get-Content $ledgerFile -Raw | ConvertFrom-Json
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
    $stores = [pscustomobject]@{}
    foreach ($s in $STORES) {
      $r = $e.stores.$s
      $stores | Add-Member -NotePropertyName $s -NotePropertyValue ([pscustomobject]@{
        state = [string]$r.state
        terms_tried = @($(if ($r.PSObject.Properties.Name -contains 'terms_tried' -and @($r.terms_tried).Count) { $r.terms_tried } else { @($Term) }))
        evidence = [string]$r.evidence })
    }
    $entry = [pscustomobject]@{ verdict = 'NOT-CARRIED'; as_of = $stamp; stores = $stores
                                source = ("promoted from ingredient-queue term '" + $Term + "'")
                                why = ("all seven Omaha stores answered and none carry it") }
  }
  Invoke-Locked -Path $ledgerFile -Body {
    # re-read inside the lock; $entry was computed from the queue, which is not the file under edit
    $freshLed = Get-Content $ledgerFile -Raw | ConvertFrom-Json
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
