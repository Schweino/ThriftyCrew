<#
  capture-front-lib.ps1 - what goes to the FRONT of a capture window, ahead of the rotation drip.

  Dot-sourced by capture-policy-lib.ps1 (which every lane loads), so every function here is in scope wherever
  Get-CapturePlan is. Moved out of capture-policy-lib.ps1 and pull-regular-familyfare.ps1 on 2026-10-03, when R7.1
  was built and both files sat exactly at their audit-file-size-budget marks: the code moved, never the marks.
  It holds the sale fallbacks a store owes (2026-09-22), R7.1 (a Family Fare fallback jumps the rotation queue,
  Brad 2026-10-03) and the Family Fare window front (Join-FfFront). No param() block, no top-level work.
  Fixtures: grocery\test-capture-policy.ps1 (plan and window) and pull-regular-familyfare.ps1 -SelfTest.
#>

# ---- SALE FALLBACKS ARE OWED WORK IN THE STORE'S OWN PLAN (2026-09-22, plan-2026-09-22-9, queue 2026-09-19-c9f0f3) ----
# A cell on sale with no everyday twin at its store vanishes from the board the day the sale ends. The window in which
# the fallback can still be fetched is WHILE the sale runs, and until today nothing owed it: audit-sale-fallback wrote a
# LABEL ('weekly-browser-agent', 'daily-ff-selfheal') chosen from a hard-coded store list, the browser agent's list was a
# JSON file only prose read, and Hy-Vee gaps were sent to a browser for a store pulled headless. So a gap was "owned"
# until its grace ran out and then paged a person (c9f0f3, and 22b4dd before it).
# Now each gap in out\sale-fallback-gaps.json is OWED to its store's plan: Get-CapturePlan hands out SaleFallbacks from
# the SAME front allowance the sale expiries use and ALWAYS after them, so a fallback can never displace an expiry (and,
# since R7.1 on 2026-10-03, at Family Fare only, may take up to RotationTerms - 1 of the rotation's drip, below). The owed order is least-recently-asked first (never asked leads), then oldest first_seen, then
# id, so a fallback the store answers with nothing cannot sit at the head forever. Set-SaleFallbackAsked records an
# ask only for ids a LANDED capture asked, exactly as Set-SaleExpiryProcessed does for expiries.
# ---- R7.1: A SALE FALLBACK JUMPS THE ROTATION QUEUE AT FAMILY FARE (Brad, 2026-10-03, verbatim label "Yes, jump the queue
# (Recommended)"; design\PLAN-weekly-root-families-2026-10-02.md Phase 7) ----
# "A sale cell with no everyday fallback moves its term to the front of the Family Fare rotation, inside the same 7-a-day
# budget." Until this, a fallback the expiries crowded out of the front allowance waited for the next window (measured: the
# 07:00 window of 2026-09-27 owed at least 2, asked 0, behind 37 expiries). Now such a fallback takes a slot from the
# rotation's OWN drip: the call cap, the budget and RotationDays are untouched, only the order inside the drip changes
# (memory ff-term-budget-is-quarterly-by-design, rule gr-12). AT MOST RotationTerms - 1 a window, so the rotation always
# re-reads at least one term and the cursor never stalls on this cause (og-13); at a rotation of 1 nothing moves. The cap
# was chosen, not swept: 1 variant tried. Lifting it to RotationTerms is this one function.
$script:SaleFallbackJumpsRotation = @{ 'Family Fare' = $true }
function Test-SaleFallbackJumpsRotation([string]$Store) { return [bool]$script:SaleFallbackJumpsRotation.ContainsKey($Store) }
# PURE: the first RotationTerms - 1 of an ordered pending list (ids for the plan, terms for the Family Fare window).
function Get-SaleFallbackRotationTake {
  param([AllowEmptyCollection()][AllowNull()][string[]]$Pending = @(), [int]$RotationTerms)
  $take = New-Object 'System.Collections.Generic.List[string]'
  $room = $RotationTerms - 1
  foreach ($p in @($Pending)) {
    if ($take.Count -ge $room) { break }
    if ($p -and -not $take.Contains([string]$p)) { [void]$take.Add([string]$p) }
  }
  return ,$take.ToArray()
}
function Get-SaleFallbackAskedPath([string]$OutDir) { return (Join-Path $OutDir 'sale-fallback-asked.json') }
function Read-SaleFallbackAsked([string]$OutDir) {
  $h = @{}
  $p = Get-SaleFallbackAskedPath $OutDir
  if (-not (Test-Path -LiteralPath $p)) { return $h }
  try { $d = ConvertFrom-Json ([IO.File]::ReadAllText($p)) } catch { return $h }   # unreadable = nobody asked yet: the order only, never ownership
  foreach ($pr in @($d.PSObject.Properties)) { $h[[string]$pr.Name] = [string]$pr.Value }
  return $h
}
# PURE over its inputs, so the audit proves ownership through the very function the plan uses.
function Get-SaleFallbackOwedFromGaps {
  param([Parameter(Mandatory)][string]$Store, [AllowEmptyCollection()]$Gaps = @(), [hashtable]$Asked = @{})
  $rows = New-Object System.Collections.Generic.List[object]
  $seen = @{}
  foreach ($g in @($Gaps)) {
    if ($null -eq $g) { continue }
    if ([string]$g.store -ne $Store) { continue }
    $id = [string]$g.commodity
    if (-not $id -or $seen.ContainsKey($id)) { continue }
    $seen[$id] = $true
    $ak = $Store + '|' + $id
    [void]$rows.Add([pscustomobject]@{ id = $id; asked = $(if ($Asked.ContainsKey($ak)) { [string]$Asked[$ak] } else { '' }); first_seen = [string]$g.first_seen })
  }
  $sorted = @($rows.ToArray() | Sort-Object @{e = { [string]$_.asked }}, @{e = { [string]$_.first_seen }}, @{e = { [string]$_.id }})
  return @($sorted | ForEach-Object { [string]$_.id })
}
function Get-SaleFallbackOwed {
  param([Parameter(Mandatory)][string]$Store, [string]$OutDir = '')
  if (-not $OutDir) { $OutDir = Join-Path $script:PolicyRoot 'out' }
  $gp = Join-Path $OutDir 'sale-fallback-gaps.json'
  if (-not (Test-Path -LiteralPath $gp)) { return [pscustomobject]@{ Ids = @(); Blind = $true; Why = "no ${gp}: what this store owes in sale fallbacks is unknown" } }
  try { $doc = ConvertFrom-Json ([IO.File]::ReadAllText($gp)) } catch { return [pscustomobject]@{ Ids = @(); Blind = $true; Why = "unreadable $gp ($($_.Exception.Message))" } }
  $ids = Get-SaleFallbackOwedFromGaps -Store $Store -Gaps @($doc.gaps) -Asked (Read-SaleFallbackAsked $OutDir)
  return [pscustomobject]@{ Ids = @($ids); Blind = $false; Why = '' }
}
# WHO ASKS A STORE'S FALLBACKS, and how long two of its cycles are. The browser stores come from stores.json
# (pull_profile.surface, Get-BrowserSurfaceStores), never from a copy of the list: the literal this replaced routed
# Hy-Vee, a headless API pull, to a browser agent. The headless consumers are the lanes that read Get-CapturePlan and
# ask what it owes. A store stores.json does not name REFUSES loudly rather than defaulting to anything.
# Grace days are the 2026-09-03 values kept (weekly browser cadence 2 x 8 = 16; a daily lane 3, two cycles absorbing
# one skip, firing on the third); they were not re-measured here.
$script:SaleFallbackHeadlessConsumers = @{
  'Hy-Vee'      = 'grocery/pull-regular-hyvee.ps1 (plan.SaleFallbacks join rank 0 behind the expiries)'
  'Family Fare' = 'grocery/pull-regular-familyfare.ps1 (plan.SaleFallbacks join the window front behind the expiries)'
  "Baker's"     = 'grocery/capture-policy-lib.ps1 Get-BakersAskPlan (plan.SaleFallbacks share the room left after the expiries)'
}
function Get-SaleFallbackConsumer {
  param([Parameter(Mandatory)][string]$Store, [string]$Root = $script:PolicyRoot)
  $known = @(Get-CapacityStores -Root $Root)
  if ($known.Count -eq 0) { throw "stores.json under $Root is missing or unreadable: no store's sale-fallback owner can be proven" }
  if ($known -notcontains $Store) { throw "unknown store '$Store': not in stores.json, so no capture plan owes its sale fallbacks" }
  $browserStores = @(Get-BrowserSurfaceStores -Root $Root)
  if ($browserStores -contains $Store) { return [pscustomobject]@{ Store = $Store; Owner = ('capture-plan:' + $Store); Via = 'Get-CaptureWorklist sale_fallback_terms (browser surface in stores.json)'; GraceDays = 16 } }
  if ($script:SaleFallbackHeadlessConsumers.ContainsKey($Store)) { return [pscustomobject]@{ Store = $Store; Owner = ('capture-plan:' + $Store); Via = [string]$script:SaleFallbackHeadlessConsumers[$Store]; GraceDays = 3 } }
  return [pscustomobject]@{ Store = $Store; Owner = 'NONE'; Via = 'no lane asks this store''s sale fallbacks'; GraceDays = 0 }
}
function Set-SaleFallbackAsked {
  <#
    .SYNOPSIS Record that a landed capture asked a store's sale fallbacks, so the next plan puts them behind the unasked.
    .DESCRIPTION Mirrors Set-SaleExpiryProcessed: nothing is written on a replay or when the capture did not land, and only
      ids the plan handed this store today (SaleFallbacks) may be marked, whatever the caller passes.
    .OUTPUTS @{ Store; Today; Marked; Ids; Reason }
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Store,
    [string]$Today = '',
    [string]$OutDir = '',
    [AllowEmptyCollection()][string[]]$Ids = @(),
    [Parameter(Mandatory)][bool]$Landed,
    [switch]$AllowReplay
  )
  if (-not $OutDir) { $OutDir = Join-Path $script:PolicyRoot 'out' }
  $todayS = if ($Today) { $Today } else { (Get-Date).ToString('yyyy-MM-dd') }
  $res = [pscustomobject]@{ Store = $Store; Today = $todayS; Marked = 0; Ids = @(); Reason = '' }
  if (-not $AllowReplay -and $todayS -ne (Get-Date).ToString('yyyy-MM-dd')) { $res.Reason = "refusing to record fallback asks on a REPLAY dated $todayS"; return $res }
  if (-not $Landed) { $res.Reason = 'the capture did not land: its fallbacks stay at the head of the owed order'; return $res }
  $plan = Get-CapturePlan -Store $Store -Today $todayS -OutDir $OutDir
  $planned = @{}; foreach ($x in @($plan.SaleFallbacks)) { if ($x) { $planned[[string]$x] = $true } }
  $want = @(@($Ids) | Where-Object { $_ -and $planned.ContainsKey([string]$_) })
  if ($want.Count -eq 0) { $res.Reason = 'no asked id was one the plan owed today'; return $res }
  $p = Get-SaleFallbackAskedPath $OutDir
  $lock = Enter-TcLedgerLock -Path $p
  try {
    $h = Read-SaleFallbackAsked $OutDir
    foreach ($id in $want) { $h[$Store + '|' + [string]$id] = $todayS }
    $o = [ordered]@{}; foreach ($k in @($h.Keys | Sort-Object)) { $o[$k] = $h[$k] }
    [void](Write-TcAtomicFile -Path $p -Text ($o | ConvertTo-Json -Depth 3))
  } finally { Exit-TcLedgerLock $lock }
  $res.Marked = $want.Count; $res.Ids = $want
  return $res
}

# PUT A BOUNDED FRONT AHEAD OF THE ROTATION. $Front is the ordered list of terms owed a place at the head of the
# window (expiry terms first, then victims); only the first $Allowance of them move, the rest keep their rotation
# positions and stay owed. Returns the reordered list and exactly which terms went to the front.
function Join-FfFront {
  param([AllowEmptyCollection()][string[]]$TermList = @(), [AllowEmptyCollection()][string[]]$Front = @(), [int]$Allowance)
  $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  $inList = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  foreach ($t in @($TermList)) { if ($null -ne $t) { [void]$inList.Add([string]$t) } }
  $head = New-Object System.Collections.Generic.List[string]
  foreach ($t in @($Front)) {
    if ($head.Count -ge $Allowance) { break }
    if (-not $t) { continue }
    if (-not $inList.Contains([string]$t)) { continue }
    if ($set.Add([string]$t)) { [void]$head.Add([string]$t) }
  }
  $rest = @(@($TermList) | Where-Object { -not $set.Contains([string]$_) })
  return [pscustomobject]@{ Items = (@($head.ToArray()) + $rest); Prepended = $head.Count; Front = $head.ToArray() }
}

# R7.1 (Brad, 2026-10-03): A SALE FALLBACK THE FRONT COULD NOT HOLD TAKES A ROTATION SLOT. $Joined is Join-FfFront's answer;
# the fallback terms it left out (in owed order) move to just behind its head, at most RotationTerms - 1 of them
# (Get-SaleFallbackRotationTake, capture-policy-lib). The window budget is NOT raised: those terms are bought out of the
# rotation's own drip, and because they count in Prepended, Get-FfNextCursor advances the cursor by exactly that many
# fewer, so no rotation term is skipped. Expiries and victims are never moved by this.
function Join-FfFallbackRotation {
  param($Joined, [AllowEmptyCollection()][string[]]$FallbackTerms = @(), [int]$RotationTerms)
  $inFront = @{}; foreach ($t in @($Joined.Front)) { if ($t) { $inFront[[string]$t] = $true } }
  $inList = @{}; foreach ($t in @($Joined.Items)) { if ($t) { $inList[[string]$t] = $true } }
  $left = @(@($FallbackTerms) | Where-Object { $_ -and -not $inFront.ContainsKey([string]$_) -and $inList.ContainsKey([string]$_) })
  $takeA = Get-SaleFallbackRotationTake -Pending $left -RotationTerms $RotationTerms
  $take = @($takeA)
  if ($take.Count -eq 0) { return [pscustomobject]@{ Items = @($Joined.Items); Prepended = [int]$Joined.Prepended; Front = @($Joined.Front); FromRotation = @() } }
  $j2 = Join-FfFront -TermList @($Joined.Items) -Front (@($Joined.Front) + $take) -Allowance ([int]$Joined.Prepended + $take.Count)
  return [pscustomobject]@{ Items = @($j2.Items); Prepended = [int]$j2.Prepended; Front = @($j2.Front); FromRotation = $take }
}
