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
  ($doc | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $path -Encoding UTF8
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
  if ($bad -eq 0) { Write-Output 'ingredient-queue SELF-TEST PASS (Rule B: one carried is enough; unchecked/blocked/errored is never not-carried; file round-trips)'; exit 0 }
  Write-Output ("ingredient-queue SELF-TEST FAIL ({0} problem(s))" -f $bad); exit 1
}

$doc = Read-Queue $QueueFile

if ($Add) {
  if (-not $Term) { Write-Output 'ingredient-queue: -Add needs -Term'; exit 1 }
  $e = Get-Item $doc $Term
  if ($e) {
    if ($Recipe -and @($e.recipes) -notcontains $Recipe) { $e.recipes = @(@($e.recipes) + $Recipe) }
    Write-Queue $doc $QueueFile
    Write-Output ("ingredient-queue: '{0}' already queued (status {1}); recipes now: {2}" -f $Term, $e.status, (@($e.recipes) -join ', '))
    exit 0
  }
  $st = @{}; foreach ($s in $STORES) { $st[$s] = $null }
  $new = [pscustomobject]@{ term = $Term; recipes = @($Recipe | Where-Object { $_ }); added = (Get-Stamp)
                            why = $Why; status = 'pending'; stores = [pscustomobject]$st; verdict = 'PENDING'; notes = $null }
  $doc.items = @(@($doc.items) + $new)
  Write-Queue $doc $QueueFile
  Write-Output ("ingredient-queue: queued '{0}'  (0 of 7 stores checked)" -f $Term)
  exit 0
}

if ($Record) {
  if (-not $Term -or -not $Store -or -not $State) { Write-Output 'ingredient-queue: -Record needs -Term, -Store and -State'; exit 1 }
  if ($STORES -notcontains $Store) { Write-Output ("ingredient-queue: unknown store '{0}'. Must be exactly one of: {1}" -f $Store, ($STORES -join ', ')); exit 1 }
  $e = Get-Item $doc $Term
  if (-not $e) { Write-Output ("ingredient-queue: '{0}' is not queued - -Add it first" -f $Term); exit 1 }
  if ($State -eq 'carried' -and $Price -le 0) { Write-Output 'ingredient-queue: a carried store needs -Price. A carriage claim with no price is not evidence.'; exit 1 }
  $e.stores.$Store = [pscustomobject]@{ state = $State; price = $(if ($Price -gt 0) { $Price } else { $null })
                                        size = $Size; item = $Item; evidence = $Evidence; checked = (Get-Stamp) }
  $v = Get-QueueVerdict $e $STORES $TERMINAL
  $e.verdict = $v.verdict
  $e.status = $(if ($v.verdict -eq 'PENDING') { 'pending' } else { 'resolved' })
  Write-Queue $doc $QueueFile
  Write-Output ("ingredient-queue: '{0}' @ {1} = {2}   ->  {3}  ({4} of 7 checked{5})" -f $Term, $Store, $State, $v.verdict, $v.checked.Count, $(if ($v.carried_by.Count) { ', carried by ' + ($v.carried_by -join ', ') } else { '' }))
  exit 0
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
