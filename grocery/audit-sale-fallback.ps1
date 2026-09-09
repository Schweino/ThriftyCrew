<#
  audit-sale-fallback.ps1 - guards the "when a sale ends, fall back to the next-cheapest item" behavior.
  compare-deals already ranks the cheapest of {sale, everyday} per store, so a sale ending reverts to the
  store's everyday item AUTOMATICALLY - BUT only if an everyday candidate for that commodity+store exists in
  the source files. If a commodity+store is on SALE with NO everyday entry to fall back to, that store will
  VANISH from the board the day the sale ends. This flags exactly those cells BEFORE that happens.

  For each on-sale cell it checks the store's EVERYDAY source file for a product matching the commodity
  (include, not exclude). Missing -> a fallback gap, BUT ONLY IF THE QUESTION WAS ASKED.

  THE PREMISE THAT WAS WRONG HERE UNTIL 2026-09-07. This header said Family Fare gaps self-heal because
  research-familyfare-everyday.ps1 refreshes it daily. That script does not exist and never did. What
  exists is pull-regular-familyfare.ps1, and it works a ROTATION: Freshop throttles on per-window request
  COUNT, so the measured-good burst is about SEVEN terms per run out of 602. Every term it does not reach
  is written into the everyday file marked outcome=not_attempted, and a commodity's term can therefore
  sit unasked for weeks.

  SO AN ABSENT PRODUCT AND AN UNASKED QUESTION LOOKED IDENTICAL. Measured 2026-09-07:
  yukon-gold-potatoes | Family Fare had been escalating daily as an unowned fallback gap, and the term
  'yukon gold potatoes' is ordinal 342 of 602 against a budget of 7 - never attempted, along with 594
  others. The store may well stock it; nothing here had looked. derive-not-carried.ps1 already states
  this rule for its own question ("outcome=not_attempted ... proves NOTHING"); this file did not.
  A gap whose terms were ALL not_attempted is now reported UNPROVEN, and does not escalate.

  Browser-store gaps (Baker's/Hy-Vee/Aldi/Walmart/Sam's/Fareway) are
  written to research-worklist.json for the weekly agent to research the next-cheapest everyday item, and the
  daily job alerts. Output: out\sale-fallback-gaps.json + out\research-worklist.json; exit 2 if any gaps.
#>
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop (2026-09-07)
param([string]$OutDir = "", [string]$CompareFile = "", [string]$AutomationsFile = "", [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\guard-contract.ps1')
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $root 'regular-fileset-lib.ps1')
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
# Pinnable like -OutDir so a fixture can drive BOTH branches (a registered owner and an unregistered one)
# without touching the estate's own registry. Defaults to the live file, so production callers are unchanged.
if (-not $AutomationsFile) { $AutomationsFile = Join-Path $root 'expected-automations.json' }
$commods = Read-JsonFile (Join-Path $root 'commodities.json')
$byId = @{}; foreach ($c in $commods) { $byId[[string]$c.id] = $c }

# THE BOARD FIRST, BECAUSE ITS NAME IS THE AS-OF. Resolved up here (it used to sit below the everyday pool)
# so the fileset window is anchored to the board being audited rather than to the wall clock - the same
# reason Resolve-BoardAsOf exists in regular-fileset-lib. A triage rebuild audits yesterday's board this
# morning, and an as-of one day wide is how guard 5 lost a 711-row Walmart capture on 2026-07-30.
if (-not $CompareFile) { $CompareFile = (Get-ChildItem (Join-Path $OutDir 'comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1).FullName }
$asof = Resolve-BoardAsOf @(Get-Item $CompareFile) (Get-Date)

# THE ENGINE'S OWN FILESET, NOT THIS AUDITOR'S PRIVATE ONE (2026-09-02, queue 2026-09-02-5df03f).
# This used to be one Get-ChildItem per store, newest by name, Select-Object -First 1. For six of the seven
# stores that is also what the engine does. For WALMART it is false EVERY DAY: Walmart is the only
# everyday-only store, so compare-deals unions every capture inside the 90-day carry window, while a
# Walmart capture is a 7-to-25-term rotation slice by policy (602 terms on a quarterly rotation). The
# auditor was therefore asking "is there an everyday twin in today's 12-term slice", which is a question
# about the capture cursor, not about the board.
# MEASURED 2026-09-02: 23 of 28 flagged cells were false. Every one of them had 5 to 331 matching everyday
# rows in the 24-file union and ZERO in the newest slice - ground-beef-8020's twin, '80% Lean / 20% Fat
# Ground Beef Chuck, 10 lb Roll, Fresh, All Natural' at $49.43, sat in walmart-regular-2026-08-31. The
# collateral was worse than the noise: 23 "research the next-cheapest everyday item" rows went to the
# weekly browser agent for products the union already holds.
# It stayed quiet only because the newest Walmart file used to be a 700-row era capture. Class:
# reporter-reads-a-narrower-fileset-than-the-repairer, the same shape as generate-board-overrides' private
# Sam's map on 2026-08-30 - which is why Sam's goes through Select-EngineSamsFiles here rather than through
# an out\regular glob: Sam's has no out\regular file at all, and two orphan sams-regular-*.json from
# July/August still sit there ready to answer the wrong question.
# DO NOT re-introduce a private fileset here. If the window or the depth rule moves, it moves in
# regular-fileset-lib / capture-policy-lib and this auditor follows it for free.
$regPrefixToStore = @{
  'family-fare' = 'Family Fare'
  'hyvee'       = 'Hy-Vee'
  'aldi'        = 'Aldi'
  'walmart'     = 'Walmart'
  'bakers'      = "Baker's"
  'fareway'     = 'Fareway'
}
$browser = @('Hy-Vee','Aldi','Walmart',"Baker's","Sam's Club",'Fareway')  # can't research headless -> weekly agent

# cache each store's everyday product names, over the SAME files the engine priced from
$everydayNames = @{}
foreach ($st in @($regPrefixToStore.Values)) { $everydayNames[$st] = New-Object System.Collections.Generic.HashSet[string] }
$everydayNames["Sam's Club"] = New-Object System.Collections.Generic.HashSet[string]
$everydayFileCount = @{}
# WHAT THE CAPTURE ACTUALLY ASKED (2026-09-07). Names alone cannot distinguish "the store does not sell
# it" from "the rotation never asked", and the whole finding this audit produces rests on that
# distinction. The everyday file records both, so read both. LAST FILE WINS per term, and the fileset is
# oldest-first, so the newest run's outcome is the one that stands.
$everydayTerms = @{}
function Add-EverydayFile([string]$store, $fileObj) {
  if (-not $everydayNames.ContainsKey($store)) { return }
  try { $doc = Read-JsonFile $fileObj.FullName } catch { return }
  foreach ($d in @($doc.deals)) { [void]$everydayNames[$store].Add("" + $d.item + $d.name) }
  if (-not $everydayTerms.ContainsKey($store)) { $everydayTerms[$store] = @{} }
  foreach ($ct in @($doc.capture_terms)) {
    $nm = ([string]$ct.term).Trim().ToLower()
    if ($nm) { $everydayTerms[$store][$nm] = ([string]$ct.outcome).Trim().ToLower() }
  }
  $everydayFileCount[$store] = 1 + [int]$everydayFileCount[$store]
}
$regFiles = @(Select-RegularFileSet (Get-ChildItem (Join-Path $OutDir 'regular\*-regular-*.json') -ErrorAction SilentlyContinue) $asof (Get-RegularUnionDays))
foreach ($f in $regFiles) {
  $prefix = ($f.BaseName -replace '-regular-.*$','')
  $st = $regPrefixToStore[$prefix]
  if ($st) { Add-EverydayFile $st $f }
}
foreach ($f in @(Select-EngineSamsFiles $OutDir (Get-Date))) { Add-EverydayFile "Sam's Club" $f }
# WAS THE QUESTION EVEN ASKED?  A store's everyday file records every search term it planned and what
# became of it. outcome='not_attempted' means the rotation ran out of budget before reaching that term,
# so the file says nothing at all about whether the store carries the product.
# PURE over its two inputs, so the fixtures drive exactly the live rule.
function Test-TermsWereAttempted {
  param($CaptureTerms, [string[]]$Terms)
  # No terms for this commodity, or no capture_terms recorded at all: this check cannot speak, and a
  # check that cannot speak must not silence the caller. Treat as ATTEMPTED so the old behaviour stands -
  # a new blind spot must never arrive as a new silence.
  if (-not $Terms -or @($Terms).Count -eq 0) { return $true }
  $rec = @{}
  foreach ($ct in @($CaptureTerms)) {
    $nm = ([string]$ct.term).Trim().ToLower()
    if ($nm) { $rec[$nm] = ([string]$ct.outcome).Trim().ToLower() }
  }
  if ($rec.Count -eq 0) { return $true }
  $known = 0
  foreach ($tm in @($Terms)) {
    $k = ([string]$tm).Trim().ToLower()
    if (-not $rec.ContainsKey($k)) { continue }
    $known++
    # ONE attempted term is enough to make the absence meaningful: the store was asked about this
    # commodity under a name it uses and answered with nothing that matches.
    if ($rec[$k] -ne 'not_attempted') { return $true }
  }
  if ($known -eq 0) { return $true }
  return $false
}

if ($SelfTest) {
  $sfBad = 0
  function TSF([string]$n, [bool]$ok, [string]$got) {
    if ($ok) { Write-Output ('  ok    ' + $n) } else { Write-Output ('  FAIL  ' + $n + '   got: ' + $got); $script:sfBad++ }
  }
  # FROZEN, and taken from the real file: these are the exact shapes pull-regular-familyfare writes.
  $ctNotAsked  = @([pscustomobject]@{ term = 'yukon gold potatoes'; outcome = 'not_attempted' },
                   [pscustomobject]@{ term = 'russet potatoes';     outcome = 'not_attempted' })
  $ctAsked     = @([pscustomobject]@{ term = 'yukon gold potatoes'; outcome = 'empty' })
  $ctMixed     = @([pscustomobject]@{ term = 'yukon gold potatoes'; outcome = 'not_attempted' },
                   [pscustomobject]@{ term = 'yellow potatoes';     outcome = 'empty' })

  # MUST FIRE - the founding case. The term was never asked, so the absence of a fallback proves nothing
  # and the gap must not escalate. yukon-gold-potatoes | Family Fare paged daily on exactly this.
  TSF 'MUST FIRE  every term not_attempted -> the question was never asked (the founding 2026-09-07 case)' `
    (-not (Test-TermsWereAttempted -CaptureTerms $ctNotAsked -Terms @('yukon gold potatoes', 'russet potatoes'))) 'read as asked'
  # MUST NOT FIRE - a term that WAS asked and came back with nothing is a real gap, and this is the
  # assertion that keeps the fix from silencing the whole audit.
  TSF 'MUST NOT FIRE  a term that WAS asked and answered empty is a REAL gap and still escalates' `
    (Test-TermsWereAttempted -CaptureTerms $ctAsked -Terms @('yukon gold potatoes')) 'read as never asked'
  # MUST NOT FIRE - one asked term is enough. A commodity with five terms of which four were skipped was
  # still genuinely looked for.
  TSF 'MUST NOT FIRE  ONE attempted term among several makes the absence meaningful' `
    (Test-TermsWereAttempted -CaptureTerms $ctMixed -Terms @('yukon gold potatoes', 'yellow potatoes')) 'read as never asked'
  # CLEAN TWIN - a store file with no capture_terms at all (Sam's, Walmart) must behave exactly as it did
  # before this rule existed. A new blind spot must never arrive as a new silence.
  TSF 'CLEAN TWIN  a store that records no capture_terms is unchanged - it reads as asked, as before' `
    (Test-TermsWereAttempted -CaptureTerms @() -Terms @('yukon gold potatoes')) 'a store with no term record went silent'
  TSF 'CLEAN TWIN  a commodity with no search terms at all is unchanged' `
    (Test-TermsWereAttempted -CaptureTerms $ctNotAsked -Terms @()) 'a commodity with no terms went silent'
  # CLEAN TWIN - a term the file does not mention cannot make the gap unproven on its own.
  TSF 'CLEAN TWIN  a term the capture never listed is not evidence of anything either way' `
    (Test-TermsWereAttempted -CaptureTerms $ctNotAsked -Terms @('some term nobody planned')) 'an unlisted term silenced the gap'
  if ($sfBad) { Write-Output "SALE-FALLBACK SELF-TEST FAILED ($sfBad)"; exit 2 }
  Write-Output 'SALE-FALLBACK SELF-TEST PASS - 1 must-fire, 2 must-not-fire, 3 clean twins'
  Exit-Guard -Name 'sale-fallback' -Code 0
}

function HasEveryday([string]$store, $c) {
  if (-not $everydayNames.ContainsKey($store)) { return $true }   # store has no everyday channel we track -> don't flag
  foreach ($nm in $everydayNames[$store]) {
    $inc = $false; foreach ($rx in $c.include) { if ($nm -imatch $rx) { $inc = $true; break } }; if (-not $inc) { continue }
    $ex = $false; foreach ($rx in $c.exclude) { if ($rx -and $nm -imatch $rx) { $ex = $true; break } }
    if (-not $ex) { return $true }
  }
  return $false
}

# commodity -> its search terms, so a gap can be asked "was this even looked for?"
. (Join-Path $root 'search-terms-lib.ps1')
$termsById = @{}
try {
  $searchDoc = ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $root 'commodity-search.json')))
  $searchTerms = if ($searchDoc.PSObject.Properties.Name -contains 'terms') { $searchDoc.terms } else { $searchDoc }
  foreach ($tp in (Get-SearchTermPairs $searchTerms)) {
    if (-not $termsById.ContainsKey($tp.id)) { $termsById[$tp.id] = New-Object System.Collections.Generic.List[string] }
    [void]$termsById[$tp.id].Add([string]$tp.term)
  }
} catch { Write-Output ('sale-fallback: commodity-search.json unreadable, so no gap can be shown UNPROVEN: ' + $_.Exception.Message) }

$all = (Read-JsonFile $CompareFile).comparison
$gaps = New-Object System.Collections.Generic.List[object]
$work = New-Object System.Collections.Generic.List[object]
foreach ($it in $all) {
  $c = $byId[[string]$it.id]; if (-not $c) { continue }
  foreach ($s in $it.stores) {
    if ([string]$s.type -ne 'sale') { continue }
    if (HasEveryday ([string]$s.store) $c) { continue }
    $ctForStore = @()
    if ($everydayTerms.ContainsKey([string]$s.store)) {
      foreach ($k in @($everydayTerms[[string]$s.store].Keys)) {
        $ctForStore += [pscustomobject]@{ term = $k; outcome = $everydayTerms[[string]$s.store][$k] }
      }
    }
    $myTerms = @()
    if ($termsById.ContainsKey([string]$it.id)) { $myTerms = @($termsById[[string]$it.id]) }
    $asked = Test-TermsWereAttempted -CaptureTerms $ctForStore -Terms $myTerms
    $gaps.Add([pscustomobject]@{ commodity=[string]$it.id; store=[string]$s.store; sale_per_unit=[double]$s.per_unit; terms_attempted=$asked })
    if ($browser -contains [string]$s.store) { $work.Add([pscustomobject]@{ commodity=[string]$it.id; store=[string]$s.store; reason='on sale now with no everyday fallback - research the next-cheapest EVERYDAY item so it does not vanish when the sale ends' }) }
  }
}
# SAY WHAT WAS READ. A fallback pool built from zero files answers "no everyday twin" for every cell in
# the store, which looks exactly like a real gap - the failure mode this item was written about. Printing
# the per-store file count makes an empty pool visible on the run that produces it instead of three days
# later in a worklist.
$pool = (@($everydayNames.Keys) | Sort-Object | ForEach-Object { "{0}={1}f/{2}n" -f $_, ([int]$everydayFileCount[$_]), $everydayNames[$_].Count }) -join ' '
Write-Output ("sale-fallback: everyday pool from the engine fileset (as-of {0:yyyy-MM-dd}, union {1}d): {2}" -f $asof, (Get-RegularUnionDays), $pool)
([ordered]@{ generated=(Get-Date -Format 'yyyy-MM-dd HH:mm'); items=$work }) | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $OutDir 'research-worklist.json') -Encoding UTF8

# ---- OWNERSHIP ROUTING (2026-09-03, queue 2026-09-03-b844ab) --------------------------------------
# EVERY gap this auditor can find is already owned by another job the moment it is found: the six
# browser stores are written to research-worklist.json three lines above for the weekly agent, and
# Family Fare is re-researched daily by research-familyfare-everyday.ps1. The alert therefore told
# triage about work this same script had just routed elsewhere, and it cost a full triage item
# (b844ab) whose entire content was confirming a no-op. Alerting is now by OWNERSHIP, not existence.
#
# THIS IS NOT A MUTE, and it must never become one. Two properties keep it honest:
#   * ownership is PROVEN, never assumed. A browser gap counts as owned only if it is genuinely in the
#     worklist we just wrote. An alert that says "queued for the weekly agent" about something that is
#     not queued is a worse bug than the noise it replaced, so absence of the row escalates at once.
#   * ownership EXPIRES at roughly two of the owner's own cycles (weekly agent -> 16d, daily FF
#     self-heal -> 3d). An owner that stops working a gap surfaces on its own. A window WIDER than the
#     cadence would never fire, which is the tolerance-wider-than-period shape; two cycles fires on the
#     third missed one while absorbing a single skip.
# The ledger is TRACKED (grocery\sale-fallback-ownership.json), deliberately. out\ is gitignored, and a
# first_seen that reset on a clean checkout would make the expiry permanently unreachable - a gate that
# can never arm. Fixture runs (any -OutDir other than the real out\) keep their ledger beside the
# fixture so a test can never write the estate's.
$OWNER_GRACE = @{ 'weekly-browser-agent' = 16; 'daily-ff-selfheal' = 3 }

# ---- AN OWNER MUST BE A JOB THAT EXISTS (2026-09-06, queue 2026-09-06-22b4dd) ----------------------
# The 2026-09-03 fix above gave ownership an EXPIRY but not PROOF. Ownership was ASSERTED from a
# hardcoded store -> string map, so a gap could be silenced as "owned" by a job that does not exist:
# 'daily-ff-selfheal' appears NOWHERE in this estate except line 133 above, its grace entry, the
# ownership ledger and the alert body. No script, no scheduled task, no registry row. It bought
# yukon-gold-potatoes|Family Fare three silent days, and only the expiry ever escalated it - a cell
# nobody was ever going to work.
#
# THE ROLE NAMES ARE NOT TASK NAMES, and that is the trap in the obvious version of this fix.
# 'weekly-browser-agent' names no Windows task either: it is a ROLE, performed by a registered task.
# A literal owner-string lookup against expected-automations.json would therefore collapse all three
# rows to NONE and page the two HEALTHY ones (canned-pumpkin|Hy-Vee and cantaloupe|Aldi, both proven
# by worklist membership and both correctly silent at age 4 of grace 16). So the mapping is declared
# here, explicitly, and an owner is registry-backed only when the task it names is in the registry.
# 'daily-ff-selfheal' is deliberately absent from this map: there is nothing to map it to.
$OWNER_TASK = @{ 'weekly-browser-agent' = 'TC Grocery Daily Capture 0800' }

# FAILS CLOSED, like the ledger read below: a registry we cannot read leaves every owner unregistered
# and every gap escalating. Reading an unreadable registry as "everything is registered" would restore
# exactly the silence this item exists to remove.
function Get-RegisteredAutomationNames([string]$Path) {
  $names = @{}
  $doc = Read-JsonFile $Path          # let an IO or parse error throw: unreadable is not empty
  foreach ($t in @($doc.windows_tasks)) { $n = ([string]$t.name).Trim(); if ($n) { $names[$n] = $true } }
  if ($names.Count -eq 0) { throw ('expected-automations.json registered no windows_tasks at all: ' + $Path) }
  return $names
}
$registered = @{}; $registryBroken = $false
try { $registered = Get-RegisteredAutomationNames $AutomationsFile }
catch { $registryBroken = $true; Write-Output ("sale-fallback: AUTOMATION REGISTRY UNREADABLE ($AutomationsFile) - no owner can be proven, every gap escalates: " + $_.Exception.Message) }
$ownerRegistered = @{}
foreach ($o in @($OWNER_GRACE.Keys)) {
  $task = [string]$OWNER_TASK[$o]
  $ownerRegistered[$o] = ((-not $registryBroken) -and $task -and $registered.ContainsKey($task))
  if (-not $ownerRegistered[$o]) {
    Write-Output ("sale-fallback: OWNER NOT REGISTERED - '{0}' names {1}, so it grants NO grace and any gap it claims escalates on day 0" -f $o, $(if ($task) { "the automation '$task', which is not in expected-automations.json" } else { 'no automation at all' }))
  }
}

function Get-NormPath([string]$p) { try { [System.IO.Path]::GetFullPath($p).TrimEnd('\') } catch { return $p } }
$ledgerPath = if ((Get-NormPath $OutDir) -ieq (Get-NormPath (Join-Path $root 'out'))) { Join-Path $root 'sale-fallback-ownership.json' } else { Join-Path $OutDir 'sale-fallback-ownership.json' }
$script:workKeys = New-Object System.Collections.Generic.HashSet[string]
foreach ($w in $work) { [void]$script:workKeys.Add(($w.commodity + '|' + $w.store)) }
function Get-GapOwner([string]$commodity, [string]$store) {
  if ($store -eq 'Family Fare') { return 'daily-ff-selfheal' }
  if ($script:workKeys.Contains($commodity + '|' + $store)) { return 'weekly-browser-agent' }
  return 'NONE'
}
# A ledger we cannot read fails CLOSED: every gap escalates. Resetting to empty on a parse error would
# silently restart every clock and is exactly how an expiry stops existing.
$ledger = @{}; $ledgerBroken = $false
if (Test-Path $ledgerPath) {
  try {
    $rawL = Get-Content $ledgerPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($p in $rawL.PSObject.Properties) { $ledger[$p.Name] = $p.Value }
  } catch { $ledgerBroken = $true; Write-Output "sale-fallback: OWNERSHIP LEDGER UNREADABLE ($ledgerPath) - every gap escalates until it is repaired" }
}
$today = $asof.Date
$nextLedger = [ordered]@{}
foreach ($gp in $gaps) {
  $key   = $gp.commodity + '|' + $gp.store
  $claimed = Get-GapOwner $gp.commodity $gp.store
  # an owner naming no registered automation is NOT an owner: it collapses to NONE, grace 0, day-0 escalation
  $owner = if ($claimed -eq 'NONE' -or $ownerRegistered[$claimed]) { $claimed } else { 'NONE' }
  $grace = if ($OWNER_GRACE.ContainsKey($owner)) { [int]$OWNER_GRACE[$owner] } else { 0 }
  # first_seen survives only while the OWNER is unchanged; a gap that changes hands restarts its clock
  $first = $null
  if (-not $ledgerBroken -and $ledger.ContainsKey($key) -and ([string]$ledger[$key].owner -eq $owner)) { $first = [string]$ledger[$key].first_seen }
  if (-not $first) { $first = $today.ToString('yyyy-MM-dd') }
  $age = 0; try { $age = [int]([datetime]$today - [datetime]$first).TotalDays } catch { $age = 0 }
  # AN UNASKED QUESTION IS NOT A GAP. If every search term for this commodity carries
  # outcome=not_attempted in the store's own everyday file, nothing has been shown about whether the
  # store carries a fallback - so it cannot escalate. It is still REPORTED, and still counted in
  # gap_count, because making it invisible is the other half of the same mistake.
  $unproven = -not [bool]$gp.terms_attempted
  $escalate = (-not $unproven) -and ($ledgerBroken -or ($owner -eq 'NONE') -or ($age -gt $grace))
  $gp | Add-Member -NotePropertyName owner       -NotePropertyValue $owner
  $gp | Add-Member -NotePropertyName claimed_owner -NotePropertyValue $claimed
  $gp | Add-Member -NotePropertyName first_seen  -NotePropertyValue $first
  $gp | Add-Member -NotePropertyName age_days    -NotePropertyValue $age
  $gp | Add-Member -NotePropertyName grace_days  -NotePropertyValue $grace
  $gp | Add-Member -NotePropertyName escalated   -NotePropertyValue $escalate
  $gp | Add-Member -NotePropertyName unproven    -NotePropertyValue $unproven
  $nextLedger[$key] = [ordered]@{ first_seen=$first; owner=$owner }
}
# only CURRENT gaps are carried, so a gap the owner clears drops out and its clock is gone with it
($nextLedger | ConvertTo-Json -Depth 4) | Set-Content $ledgerPath -Encoding UTF8
$escalated = @($gaps | Where-Object { $_.escalated })
$owned     = @($gaps | Where-Object { -not $_.escalated })
$unprovenGaps = @($gaps | Where-Object { $_.unproven })

# gap_count stays the TOTAL and the exit code stays tied to it: test-auditors (k3) pins rc=2 as the
# must-fire for a real gap, weekly-post-capture logs gap_count pre-publish, and neither is an alerting
# decision. Only the alert reads escalated_count. Nothing here is allowed to make a gap invisible.
$rep = [ordered]@{ generated=(Get-Date -Format 'yyyy-MM-dd HH:mm'); as_of=$asof.ToString('yyyy-MM-dd'); everyday_pool=$pool; gap_count=$gaps.Count; escalated_count=$escalated.Count; owned_count=$owned.Count; unproven_count=$unprovenGaps.Count; ledger_unreadable=$ledgerBroken; escalated=$escalated; owned=$owned; unproven=$unprovenGaps; gaps=$gaps }
$rep | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $OutDir 'sale-fallback-gaps.json') -Encoding UTF8
if ($gaps.Count) {
  Write-Output ("sale-fallback: $($gaps.Count) on-sale cell(s) have NO everyday fallback (would vanish when the sale ends):")
  foreach ($gp in $gaps) { Write-Output ("  {0,-18} {1,-14} owner={2} age={3}d/{4}d{5}" -f $gp.commodity, $gp.store, $gp.owner, $gp.age_days, $gp.grace_days, $(if ($gp.unproven) { ' UNPROVEN - the capture rotation never asked this store about it, so its absence means nothing' } elseif ($gp.escalated) { ' ESCALATED' } else { '' })) }
  Write-Output ("sale-fallback: $($owned.Count) owned and being worked, $($escalated.Count) ESCALATED (no owner, or the owner has not cleared it in its grace window), $($unprovenGaps.Count) UNPROVEN (the rotation has not asked)")
  Exit-Guard -Name 'sale-fallback' -Code 2
} else { Write-Output 'sale-fallback: none - every on-sale cell has an everyday item to revert to'; Write-GuardComplete -Name 'sale-fallback'; exit 0 }
