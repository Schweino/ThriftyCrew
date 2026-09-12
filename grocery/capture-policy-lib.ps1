<#
  capture-policy-lib.ps1 - the FUNCTIONS behind capture-policy.ps1, with no param() block.

  *** WHY THE SPLIT (2026-08-21) ***
  Dot-sourcing a script runs its param() block in the CALLER's scope. capture-policy.ps1 is
  both a CLI (-Report, -Emit) and the library eight other scripts dot-source, so every one of
  those callers silently had its own $OutDir, $Today and $Store reset to '' the moment it
  loaded the policy. browser-refresh-due.ps1 hit it head-on: it set $OutDir, dot-sourced the
  policy, and then called a function with an empty string.

  It was survivable elsewhere only by luck - the emptied $OutDir fell through to the same
  default the caller would have used anyway - which is precisely how this class hides.
  capture-lib.ps1 learned the identical lesson on 2026-07-29 when a shared param([switch]$SelfTest)
  reset every builder's own $SelfTest to $false, and browser-feeds-lib.ps1 carries the rule in
  capitals: A SHARED LIBRARY MUST NOT DECLARE PARAMETERS AT ALL.

  So: the functions live here and declare nothing. capture-policy.ps1 keeps the CLI and dot-sources
  this. Callers should dot-source THIS file; dot-sourcing capture-policy.ps1 still works and still
  clobbers, which is why every in-tree caller was moved over in the same change.
#>
<#
  capture-policy.ps1 - the ONE place that answers "what should we capture from this store today?"

  THE POLICY (Brad, 2026-08-20), and it is the same for all seven stores:

    1. AD ROLLOVER    the store's current ad expired and a new one is up -> pull its ad.
    2. SALE EXPIRY    an item's temporary sale ended -> re-price that item, because the
                      shelf price reverts the day after sale_end and the board would
                      otherwise keep publishing the sale price.
    3. QUARTERLY BASE everything else rotates: total terms / 90 days, that many per day.

  1 and 2 are EVENTS - they fire once or twice a week, not daily. 3 is the daily drip.

  WHY THIS IS ONE FILE AND NOT SEVEN. The estate already learned this lesson the hard
  way in the exclude rules: 113 produce commodities each carried a separately
  hand-assembled list, so whether a jam could steal a fruit's price depended on which
  words that particular commodity happened to receive. Seven per-store capture policies
  would rot the same way, and the failure would be invisible - a store quietly asking for
  more than its budget, or for nothing at all.

  WHY A BUDGET AT ALL. Family Fare's Freshop API answers a search with HTTP 400 carrying
  {"error_code":429} once we exceed its window - a rate limit dressed as a bad request.
  On 2026-08-20 that had degraded FF to 15% same-day rows (from 64-77% the days before)
  and left audit-ff-carry blind for five days. Asking for less, on a schedule, is the fix.

  THE TRADE THIS ENCODES. A 90-day rotation means an "everyday" price can be up to a
  quarter old. That is a deliberate, owner-made decision; it is NOT free, and
  MaxCarryDays must be raised to match or the rows expire before their turn comes round
  again. Both numbers live here so they can never drift apart.

  Usage:
      . capture-policy.ps1
      $plan = Get-CapturePlan -Store 'Family Fare'
      $plan.RotationTerms      # how many rotation terms to buy today
      $plan.AdRollover         # $true if the ad flipped and needs pulling
      $plan.SaleExpiries       # commodity ids whose sale ended and must be re-priced
      capture-policy.ps1 -Report   # human-readable, all seven stores
#>

$ErrorActionPreference = 'Stop'
$script:PolicyRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
# Write-TcAtomicFile: the store lanes run side by side and read the cursor and sale-windows.json lock-free.
. (Join-Path (Split-Path -Parent $script:PolicyRoot) 'lib\atomic-write.ps1')
# Enter-TcLedgerLock: the same lanes also WRITE those two files side by side - see lib\ledger-lock.ps1.
. (Join-Path (Split-Path -Parent $script:PolicyRoot) 'lib\ledger-lock.ps1')
# -SelfTest drives both ledgers from concurrent processes (the block at the end of this file). Read from $args,
# because this file declares no parameters - see the header.
$__cplSelfTest = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-SelfTest')

# The quarter. Change it HERE and nowhere else; MaxCarryDays must move with it.
$script:QuarterDays = 90

# Rows carried longer than this expire. It MUST be >= QuarterDays or a term's rows die
# before the rotation comes back to them - at 90-day rotation with a 14-day carry, ~85%
# of the catalog would starve. The pulls read this so the two can never disagree.
$script:MaxCarryDays = 90

# ---------------------------------------------------------------------------
# THE PER-STORE CALL CEILING (2026-08-22)
#
# WHY. Until today the daily slice was rotation + EVERY expiring sale, uncapped, and
# Select-ExpiryFirstSlice added the expiries in a loop with no budget test at all - so the
# returned slice could exceed its own budget outright. sale-windows.json on 2026-08-22 holds
# 130 entries refreshing on 08-23 (Fareway 111, Family Fare 19) and 104 on 08-24 (Hy-Vee),
# so tomorrow those lanes would have asked for ~19x and ~15x their normal day in ONE run.
# Family Fare's Freshop search answers HTTP 400 carrying {"error_code":429} once we exceed
# its window; a throttled run degrades that whole store, and on 2026-08-20 it cost five
# blind days. A slice that cannot be fetched is not a bigger capture, it is a smaller one.
#
# WHERE THE NUMBERS COME FROM. One entry per store, each carrying its own basis, in the same
# measured/proposed vocabulary stores.json already uses for pull_profile.confidence. This is
# a CEILING ON REQUESTS PER RUN, in that lane's own request unit (search terms for the term-
# rotation stores, product ids for Hy-Vee).
#
#   Family Fare 40  MEASURED. Freshop starts answering 400/error_code 429 at roughly 40
#                   search calls in a window (2026-08-20 incident; FF fell to 15% same-day
#                   rows from 64-77%). The only store whose refusal point has actually been
#                   observed. Everything else below is bounded by an OBSERVED-CLEAN run, not
#                   by an observed refusal, and is deliberately set well under it.
#   Hy-Vee     120  PROPOSED. GraphQL, no wall ever observed; the lane re-verified 1010
#                   products in a run at baseline with no refusal, so 120 is ~12% of a
#                   known-clean run. Its unit is PRODUCTS (see PRODUCT ROTATION below).
#   Baker's    250  PROPOSED. Kroger's sanctioned API, 180ms pacing, and until 2026-08-22 this
#                   lane ignored the cap entirely: it walked ALL 598 search terms every single
#                   day (7,281 rows on 2026-08-21) because it was "comprehensive". Brad's ruling
#                   ended that - "Bakers should be following the SAME logic as literally everyone
#                   else when it comes to ad rotation and 'everyday' pricing" - so the cap is now
#                   a real ceiling on a real worklist, in this lane's own unit (search terms).
#                   598/90 = 7 a day, so 250 clamps nothing today; it exists so a backlog of
#                   expiring sales cannot turn one morning into a 130-request day.
#   Fareway     45  PROPOSED. Browser lane, 900ms pacing. A 144-term sweep completed clean on
#                   2026-08-15 with zero empties, but 144 is a fifth of the list and no wall
#                   has ever been measured; 45 is under a third of that known-clean sweep.
#   Aldi        45  PROPOSED. Same 900ms browser pacing; stores.json records 403s "after a
#                   few hundred rapid requests", so the same third-of-clean rule applies.
#   Sam's Club  30  PROPOSED. 2600ms measured-clean pacing over 388 terms, but each term is a
#                   slow storefront page - 30 keeps one Chrome session near the lane's own
#                   14-minute wall-clock cap rather than near a rate limit.
#   Walmart     25  PROPOSED. 3500ms pacing, and it is the ONLY store that has hit a hard
#                   "Robot or human?" wall (2026-08-15) at a rate nobody recorded. The store
#                   we know least about gets the smallest slice.
#
# RAISE A NUMBER ONLY WITH EVIDENCE, and move its basis to 'measured' in the same edit. An
# unmeasured ceiling raised on a hunch is how the 2026-08-20 throttle happened.
$script:StoreCallCap = @{
  'Family Fare' = @{ cap = 40;  basis = 'measured'; unit = 'search terms' }
  'Hy-Vee'      = @{ cap = 120; basis = 'proposed'; unit = 'product ids' }
  "Baker's"     = @{ cap = 250; basis = 'proposed'; unit = 'search terms' }
  'Fareway'     = @{ cap = 45;  basis = 'proposed'; unit = 'search terms' }
  'Aldi'        = @{ cap = 45;  basis = 'proposed'; unit = 'search terms' }
  "Sam's Club"  = @{ cap = 30;  basis = 'proposed'; unit = 'search terms' }
  'Walmart'     = @{ cap = 25;  basis = 'proposed'; unit = 'search terms' }
}
# An unknown store gets the tightest cap in the table, never the loosest: a store nobody has
# characterised is the one most likely to be walled by the request we have not thought about.
$script:DefaultCallCap = 25

function Get-StoreCallCap([string]$Store) {
  if ($script:StoreCallCap.ContainsKey($Store)) { return [int]$script:StoreCallCap[$Store].cap }
  return [int]$script:DefaultCallCap
}
function Get-StoreCallCapBasis([string]$Store) {
  if ($script:StoreCallCap.ContainsKey($Store)) { return [string]$script:StoreCallCap[$Store].basis }
  return 'default'
}

function Get-PolicyJson([string]$name) {
  $p = Join-Path $script:PolicyRoot $name
  if (-not (Test-Path $p)) { return $null }
  try { return ConvertFrom-Json ([IO.File]::ReadAllText($p)) } catch { return $null }
}

function Get-StoreTermCount([string]$store) {
  # The API budget is spent per SEARCH TERM, not per item: one term returns up to ~25
  # items. Counting items here would understate the request cost by roughly 9x.
  $t = Get-PolicyJson 'commodity-search.json'
  if (-not $t) { return 0 }
  $n = 0
  foreach ($p in $t.terms.PSObject.Properties) {
    if ($p.Value -is [array]) { $n += @($p.Value).Count } else { $n++ }
  }
  return $n
}

function Get-CapturePlan {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Store, [string]$Today = '')

  $todayS = if ($Today) { $Today } else { (Get-Date).ToString('yyyy-MM-dd') }
  $todayD = [datetime]::ParseExact($todayS, 'yyyy-MM-dd', $null)

  # --- 1. ad rollover -------------------------------------------------------
  $adRollover = $false; $adNote = 'no weekly ad cycle'
  $sched = Get-PolicyJson 'ad-schedule.json'
  if ($sched) {
    foreach ($s in $sched.stores) {
      if ([string]$s.store -ne $Store) { continue }
      if (-not $s.cadence_days) { break }              # Walmart / Sam's: no ad cycle
      $np = [string]$s.next_pull
      if ($np) {
        try {
          $npD = [datetime]::ParseExact($np, 'yyyy-MM-dd', $null)
          $adRollover = ($todayD -ge $npD)
          $adNote = if ($adRollover) { "ad pull DUE (next_pull $np)" } else { "ad current until $($s.current.to); next_pull $np" }
        } catch { $adNote = "unparseable next_pull '$np'" }
      }
      break
    }
  }

  # --- 2. sale expiries -----------------------------------------------------
  # sale-windows.json already computes refresh_on = sale_end + 1, described in its own
  # note as "the day the price reverts, when a re-price is due". It was being written
  # daily and read by nothing; this is what consumes it.
  #
  # THE COUPLING THAT BOUNDS THIS LIST - AND WHAT REPLACED IT (2026-08-22, second pass).
  # build-sale-windows.ps1 USED to keep an entry only while refresh_on >= today and prune
  # it the day AFTER refresh_on, so an id appeared here on exactly ONE day and was gone the
  # next. That bounded the list, but it bounded it by the CALENDAR rather than by the work:
  # an expiry a capped or throttled run did not actually process was dropped from the
  # ledger and never re-priced, so its SALE price kept publishing on the board until that
  # item's next quarterly rotation slot - up to 90 days away. Capping the slice without
  # fixing that would have converted a throttle problem into silently stale prices, which
  # is strictly worse. So the prune is now driven by an explicit PROCESSED SIGNAL:
  #
  #   repriced_for  = the refresh_on value a landed capture actually satisfied.
  #   An entry is OWED while refresh_on <= today AND repriced_for <> refresh_on.
  #   build-sale-windows.ps1 keeps an owed entry no matter how old it is; it prunes only
  #   once refresh_on is past AND repriced_for matches it.
  #   Set-SaleExpiryProcessed (below) writes that field, and only after a landed capture -
  #   a run that fetched nothing marks nothing and therefore loses nothing.
  #
  # The two halves - the builder's prune and this consumer's test - must stay aligned;
  # widen one without the other and expiries are either missed or repeated forever.
  #
  # OLDEST FIRST. Pending expiries are ordered by refresh_on ascending, then by id, so the
  # cap below always takes the longest-owed work and nothing starves at the back of a
  # backlog. The order is total and deterministic, so two runs on the same day pick the
  # same slice - which is what lets Set-SaleExpiryProcessed mark exactly what was asked.
  # Brad's rule: "reprice whenever an ad price / sale price / rollback price /
  # instant-savings price drops off."
  $pending = New-Object System.Collections.Generic.List[object]
  $seenId = @{}
  $sw = Get-PolicyJson 'sale-windows.json'
  if ($sw -and $sw.windows) {
    foreach ($w in $sw.windows) {
      if ([string]$w.store -ne $Store) { continue }
      $ro = [string]$w.refresh_on
      if (-not $ro) { continue }
      $roD = $null
      try { $roD = [datetime]::ParseExact($ro, 'yyyy-MM-dd', $null) } catch { continue }
      if ($todayD -lt $roD) { continue }                       # sale still running
      if ((Get-SaleWindowRepricedFor $w) -eq $ro) { continue }  # already processed for THIS window
      $id = [string]$w.id
      if (-not $id) { continue }
      # One slot per commodity even when two of its items are on sale at the same store.
      if ($seenId.ContainsKey($id)) {
        if ([string]$seenId[$id].refresh_on -gt $ro) { $seenId[$id].refresh_on = $ro }
        continue
      }
      $row = [pscustomobject]@{ id = $id; refresh_on = $ro }
      $seenId[$id] = $row
      [void]$pending.Add($row)
    }
  }
  $ordered = @($pending | Sort-Object @{e = { [string]$_.refresh_on }}, @{e = { [string]$_.id }})

  # --- 3. quarterly rotation ------------------------------------------------
  $terms = Get-StoreTermCount $Store
  $rotation = [int][math]::Ceiling($terms / [double]$script:QuarterDays)
  if ($rotation -lt 1 -and $terms -gt 0) { $rotation = 1 }

  # --- 4. the cap -----------------------------------------------------------
  # Expiries come FIRST, but they may not eat the whole run: the rotation is reserved its
  # daily drip, or a long backlog would stall the quarterly sweep for weeks and the rows
  # it feeds would age past MaxCarryDays. So the expiry allowance is the store's call cap
  # minus the rotation, and the two together are exactly the cap.
  $callCap = Get-StoreCallCap $Store
  $expiryCap = $callCap - $rotation
  if ($expiryCap -lt 1) { $expiryCap = 1 }
  $expiries = @($ordered | Select-Object -First $expiryCap | ForEach-Object { [string]$_.id })
  $deferred = @($ordered).Count - @($expiries).Count
  if ($deferred -lt 0) { $deferred = 0 }
  $budget = $rotation + @($expiries).Count
  if ($budget -gt $callCap) { $budget = $callCap }

  return [pscustomobject]@{
    Store         = $Store
    Today         = $todayS
    AdRollover    = $adRollover
    AdNote        = $adNote
    # Today's slice of expiries: oldest-owed first, capped. NOT the whole backlog.
    SaleExpiries  = $expiries
    # Every expiry this store still owes, capped slice included. An audit reads this to
    # see the backlog; a lane must never fetch it.
    ExpiryPending = @($ordered | ForEach-Object { [string]$_.id })
    ExpiryDeferred = $deferred
    ExpiryCap     = $expiryCap
    ExpiryOldest  = if (@($ordered).Count) { [string]@($ordered)[0].refresh_on } else { '' }
    CallCap       = $callCap
    CallCapBasis  = (Get-StoreCallCapBasis $Store)
    TermCount     = $terms
    RotationTerms = $rotation
    QuarterDays   = $script:QuarterDays
    MaxCarryDays  = $script:MaxCarryDays
    # What the pull should actually ask for today: the daily drip plus today's capped
    # slice of expiring sales, and never more than the store's call cap. An ad rollover
    # is a separate pull (the ad feed), not extra search terms.
    TermBudget    = $budget
  }
}

function Get-SaleWindowRepricedFor($w) {
  <# The refresh_on value a landed capture already satisfied for this window, or ''. #>
  if ($null -eq $w) { return '' }
  try { if ($w.PSObject.Properties['repriced_for']) { return ([string]$w.repriced_for) } } catch { }
  return ''
}

function Get-PolicyMaxCarryDays { return $script:MaxCarryDays }
function Get-PolicyQuarterDays { return $script:QuarterDays }

# ---------------------------------------------------------------------------
# ROTATION CURSOR + DAILY WORKLIST
#
# Why a worklist rather than budget logic inside each pull. The seven lanes have
# seven different shapes - Freshop search, Kroger API, Hy-Vee GraphQL, and three
# that need a real logged-in Chrome. Teaching each one to compute its own budget
# would give us seven implementations of one rule, which is precisely the disease
# this file exists to cure. So the policy decides WHICH TERMS TODAY and writes it
# down; a lane's only job is to read its list and fetch those.
#
# It also makes the walled stores tractable at all: no PowerShell can drive Brad's
# Chrome, but it can leave a worklist that the browser agent picks up - the same
# handoff shape ingredient-queue.ps1 already uses for the Recipe Hunter.
# ---------------------------------------------------------------------------

$script:CursorFile = 'capture-cursor.json'

function Get-AllTerms {
  # Flattened in a STABLE order so a cursor means the same thing across runs.
  # commodity-search.json maps one commodity to one term OR a list of them.
  $t = Get-PolicyJson 'commodity-search.json'
  $out = New-Object System.Collections.Generic.List[object]
  if (-not $t) { return $out }
  foreach ($p in ($t.terms.PSObject.Properties | Sort-Object Name)) {
    if ($p.Value -is [array]) {
      foreach ($v in $p.Value) { [void]$out.Add([pscustomobject]@{ id = $p.Name; term = [string]$v }) }
    } else {
      [void]$out.Add([pscustomobject]@{ id = $p.Name; term = [string]$p.Value })
    }
  }
  return $out
}

function Get-CaptureCursors([string]$outDir) {
  $p = Join-Path $outDir $script:CursorFile
  if (Test-Path $p) { try { return ConvertFrom-Json ([IO.File]::ReadAllText($p)) } catch { } }
  return [pscustomobject]@{}
}

# ---- THE WALMART STORE-DRIFT RULING, READ RATHER THAN REMEMBERED (2026-09-12) --------------------
#
# Brad ruled on 2026-08-28 that the L St Supercenter stays canonical and named 23 terms to recapture
# first, because they were priced while the session had drifted to another store. The ruling said "put
# them at the head of the first clean Walmart worklist" and NOTHING CARRIED THAT ANYWHERE: the list sat
# in a JSON file and in the 09:00 runbook, so for a fortnight it depended on whoever read those. Eight
# landed on 2026-09-12 and fifteen were still owed, which is the shape of a reminder rather than a
# mechanism ([[an-intention-has-no-exit-code]]).
#
# So the worklist reads it. Two things make this a mechanism rather than a second reminder:
#   1. OWED IS DERIVED, not maintained. A term leaves the list when a walmart-regular file that NAMES
#      the sanctioned store carries a row for it. Nobody has to edit anything, and the list empties
#      itself and goes quiet - the day it is empty this prepends nothing.
#   2. THE ROTATION KEEPS ITS DRIP. These terms come out of the same allowance the sale expiries come
#      from (the call cap minus the rotation), ahead of them, so the quarterly sweep is not starved and
#      the rotation cursor still advances over terms that were really asked for. Advancing the cursor
#      past terms a prepend displaced is the starvation bug Select-ExpiryFirstSlice's header describes.
# An owed term that does not fit today is not lost: it is still owed tomorrow, by the same derivation.
$script:WalmartRulingFile = 'walmart-store-ruling-2026-08-28.json'
# The day the Walmart capture format learned to name its own store. An ATTESTED discharge - a human or
# agent verifying the store and writing it down - is accepted only for a capture taken on or before
# this date, because every capture after it proves its own store and needs nothing taken on trust.
# The attestation list is CLOSED by construction; it can never grow a new entry that this accepts.
$script:WalmartStoreLineFrom = '2026-09-12'

function Get-WalmartRulingOwed {
  <#
    .SYNOPSIS Which of the store-drift ruling's terms are still owed a recapture at the sanctioned store.
    .DESCRIPTION
      Pure read. Owed = the ruling's own list, minus terms ATTESTED as recaptured before the capture
      format could name its store, minus terms PROVEN recaptured by a walmart-regular file whose source
      names the sanctioned storeId. Order is the ruling's own, so the oldest instruction is served first.

      A COULD-NOT-LOOK IS NEVER A DISCHARGE. With no out\regular to read (a worktree, a CI runner, a
      clean checkout) this cannot know what has landed, so it says BLIND and reports everything the
      ruling names as still owed. Over-asking costs requests; under-asking leaves a wrong-basis price
      on the board, and those are not the same mistake.
    .OUTPUTS @{ Owed; All; Attested; Proven; Sanctioned; Blind; Why }
  #>
  [CmdletBinding()]
  param([string]$OutDir = '')
  if (-not $OutDir) { $OutDir = Join-Path $script:PolicyRoot 'out' }
  $none = [pscustomobject]@{ Owed = @(); All = @(); Attested = @(); Proven = @(); Sanctioned = ''; Blind = $false; Why = '' }

  $rulePath = Join-Path $OutDir $script:WalmartRulingFile
  if (-not (Test-Path $rulePath)) { return $none }        # no ruling on file: nothing is owed
  $doc = $null
  try { $doc = ConvertFrom-Json ([IO.File]::ReadAllText($rulePath)) } catch { $doc = $null }
  if (-not $doc) {
    $n = $none.PSObject.Copy(); $n.Blind = $true
    $n.Why = ('the ruling file ' + $script:WalmartRulingFile + ' is present but unparseable, so what it still owes is unknown')
    return $n
  }
  # assign, THEN wrap - a single-element JSON array comes back unwrapped ([[ps-json-array-collapse]])
  $rawAll = $doc.terms_to_recapture_first
  $all = @(@($rawAll) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
  if ($all.Count -eq 0) { return $none }

  # THE SANCTIONED STORE COMES FROM THE REGISTRY, never from a literal here - the same rule
  # build-walmart-deals.ps1 follows, and the same single source of truth.
  $sanct = ''
  $stores = Get-PolicyJson 'stores.json'
  if ($stores) {
    foreach ($s in @($stores.stores)) {
      if ([string]$s.name -eq 'Walmart' -and $s.store_identity -and $s.store_identity.store_id) {
        $sanct = ([string]$s.store_identity.store_id).Trim()
      }
    }
  }

  # 1. ATTESTED, and only from before the capture format could speak for itself.
  $att = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  $cut = [datetime]::ParseExact($script:WalmartStoreLineFrom, 'yyyy-MM-dd', $null)
  if ($doc.recaptured_at_l_st) {
    foreach ($prop in $doc.recaptured_at_l_st.PSObject.Properties) {
      $when = $null
      try { $when = [datetime]::ParseExact($prop.Name, 'yyyy-MM-dd', $null) } catch { continue }  # 'note' and friends
      if ($when -gt $cut) { continue }
      foreach ($t in @($prop.Value)) { $s2 = ([string]$t).Trim(); if ($s2) { [void]$att.Add($s2) } }
    }
  }

  # 2. PROVEN by a built file that names the store it was read at.
  $proven = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  $regDir = Join-Path $OutDir 'regular'
  $blind = ''
  if (-not $sanct) {
    $blind = 'stores.json does not declare Walmart store_identity.store_id, so no built file can be checked against the sanctioned store'
  } elseif (-not (Test-Path $regDir)) {
    $blind = ('there is no ' + $regDir + ' to read, so which of these terms have already been recaptured is unknown in this checkout')
  } else {
    # Filter on the DATE IN THE NAME before opening anything: the ruling cannot be discharged by a file
    # built before it was made, and these files run to a quarter of a megabyte each.
    $since = ''
    try { $since = ([string]$doc.ruled).Trim() } catch { $since = '' }
    foreach ($f in @(Get-ChildItem -LiteralPath $regDir -Filter 'walmart-regular-*.json' -File -ErrorAction SilentlyContinue)) {
      $m = [regex]::Match($f.Name, '(\d{4}-\d{2}-\d{2})')
      if (-not $m.Success) { continue }
      if ($since -and ([string]$m.Groups[1].Value) -lt $since) { continue }
      $d = $null
      try { $d = ConvertFrom-Json ([IO.File]::ReadAllText($f.FullName)) } catch { continue }
      if (-not $d) { continue }
      # THE STAMP IS THE PROOF. A file built under -WaiveMissingStoreLine says the store was NOT
      # recorded and discharges nothing, however carefully somebody verified the store by hand -
      # that is what an attestation above is for, and it is closed.
      if ([string]$d.source -notmatch ('storeId\s+' + [regex]::Escape($sanct) + '\b')) { continue }
      foreach ($row in @($d.deals)) {
        $t = ([string]$row.found_by_term).Trim()
        if ($t) { [void]$proven.Add($t) }
      }
    }
  }

  $owed = @($all | Where-Object { -not $att.Contains($_) -and -not $proven.Contains($_) })
  return [pscustomobject]@{
    Owed = $owed; All = $all
    Attested = @($all | Where-Object { $att.Contains($_) })
    Proven = @($all | Where-Object { $proven.Contains($_) })
    Sanctioned = $sanct
    Blind = [bool]$blind
    Why = $blind
  }
}

function Get-CaptureWorklist {
  <#
    .SYNOPSIS Today's terms for one store: rotation slice + sales reverting today.
    .NOTES    Pure - it does NOT advance the cursor. A lane advances it only after
              its capture has actually landed, exactly as the FF cursor-commit rule
              already works: a run that bought nothing must re-attempt the same
              slice tomorrow rather than skipping it forever.
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Store, [string]$Today = '', [string]$OutDir = '')

  if (-not $OutDir) { $OutDir = Join-Path $script:PolicyRoot 'out' }
  $plan = Get-CapturePlan -Store $Store -Today $Today
  $all = Get-AllTerms
  $cursors = Get-CaptureCursors $OutDir
  $key = ($Store -replace '[^A-Za-z0-9]', '')
  $start = 0
  if ($cursors.PSObject.Properties.Name -contains $key) { $start = [int]$cursors.$key }
  if ($all.Count -eq 0) { $start = 0 }

  $rot = New-Object System.Collections.Generic.List[object]
  for ($k = 0; $k -lt $plan.RotationTerms -and $all.Count -gt 0; $k++) {
    [void]$rot.Add($all[(($start + $k) % $all.Count)])
  }

  # Sales reverting today are EXTRA, not part of the rotation slice: the whole point
  # is that the shelf price changed back and the board is still showing the sale.
  # EVERY term of the expiring commodity, not its first (2026-08-22). commodity-search.json allows an
  # array of terms precisely because 210 of 429 commodities are only reachable through a second term;
  # re-pricing the expiring item through its first term alone could miss the very product on sale.
  $sale = New-Object System.Collections.Generic.List[object]
  foreach ($id in $plan.SaleExpiries) {
    foreach ($hit in @($all | Where-Object { $_.id -eq $id })) { [void]$sale.Add($hit) }
  }

  # A STANDING RULING'S TERMS LEAD, INSIDE THE SAME ALLOWANCE THE EXPIRIES GET (2026-09-12). See
  # Get-WalmartRulingOwed's header: owed is derived from what has actually been recaptured at the
  # sanctioned store, so this empties itself and then prepends nothing. The allowance is the call cap
  # minus the rotation's reserved drip, which is what stops a 23-term ruling from starving the
  # quarterly sweep and from advancing the cursor over terms nobody asked for. Expiries give way to it
  # and stay owed in sale-windows.json, which is exactly what they already do when the cap is short.
  $rule = if ($Store -eq 'Walmart') { Get-WalmartRulingOwed -OutDir $OutDir } else { $null }
  $ruleTerms = New-Object System.Collections.Generic.List[object]
  $ruleDeferred = 0
  $saleDeferredByRuling = 0
  $allowance = $plan.CallCap - $plan.RotationTerms
  if ($allowance -lt 0) { $allowance = 0 }
  if ($rule -and @($rule.Owed).Count -gt 0) {
    foreach ($t in @($rule.Owed)) {
      if ($ruleTerms.Count -ge $allowance) { $ruleDeferred++; continue }
      $hits = @($all | Where-Object { [string]$_.term -eq [string]$t })
      if ($hits.Count -eq 0) { continue }          # a ruling term the catalogue no longer carries
      foreach ($hit in $hits) { [void]$ruleTerms.Add($hit) }
    }
    # The expiries share what is left of the allowance. Trimming them here is not a loss: a window is
    # marked repriced only when a capture LANDS, so an untaken expiry leads tomorrow's slice.
    $saleRoom = $allowance - $ruleTerms.Count
    if ($saleRoom -lt 0) { $saleRoom = 0 }
    if ($sale.Count -gt $saleRoom) {
      $saleDeferredByRuling = $sale.Count - $saleRoom
      $keep = New-Object System.Collections.Generic.List[object]
      for ($i = 0; $i -lt $saleRoom; $i++) { [void]$keep.Add($sale[$i]) }
      $sale = $keep
    }
  }

  return [pscustomobject]@{
    Store         = $Store
    Today         = $plan.Today
    CursorStart   = $start
    CursorNext    = if ($all.Count) { (($start + $plan.RotationTerms) % $all.Count) } else { 0 }
    TotalTerms    = $all.Count
    RotationTerms = $rot.ToArray()
    SaleTerms     = $sale.ToArray()
    AdRollover    = $plan.AdRollover
    AdNote        = $plan.AdNote
    CallCap        = $plan.CallCap
    ExpiryDeferred = $plan.ExpiryDeferred
    ExpiryOldest   = $plan.ExpiryOldest
    # A standing ruling's owed terms, ahead of everything (2026-09-12). Empty for every store but
    # Walmart, and empty for Walmart too once the ruling is discharged.
    RulingTerms   = $ruleTerms.ToArray()
    RulingOwed    = if ($rule) { @($rule.Owed) } else { @() }
    RulingTotal   = if ($rule) { @($rule.All).Count } else { 0 }
    RulingDeferred = $ruleDeferred
    RulingBlind   = if ($rule) { [bool]$rule.Blind } else { $false }
    RulingWhy     = if ($rule) { [string]$rule.Why } else { '' }
    SaleDeferredByRuling = $saleDeferredByRuling
    # Dedupe on the TERM STRING. Select-Object -Unique on PSCustomObjects compares
    # their ToString(), which is identical for every one of them, so it silently
    # collapsed a 13-term worklist to a single entry - a store would then be told to
    # fetch one term a day and the rotation would never complete.
    # THE RULING'S TERMS COME FIRST here, because Group-Object keeps first-seen order and this list is
    # fetched in order: a run that is cut short must have spent its requests on the owed ones.
    Terms         = @(@($ruleTerms.ToArray()) + @($rot.ToArray()) + @($sale.ToArray()) |
                      Group-Object -Property term | ForEach-Object { $_.Group[0] })
    QuarterDays   = $plan.QuarterDays
    MaxCarryDays  = $plan.MaxCarryDays
  }
}

function Get-FfVictimTerms {
  <#
    .SYNOPSIS Which confirmed pull-drop victim terms may lead the next Family Fare window.
    .DESCRIPTION
      THE DEFECT (2026-09-07, queue 2026-09-07-72756b). audit-ff-carry writes
      out\ff-carry-report.json with a confirmed_victims array and its alert told the reader those
      victims 'lead the next window's slice automatically'. NOTHING READ THAT FILE. Repo-wide the
      family name appeared only in the writer and in two JSON-shape assertions, so a genuinely
      dropped carried item waited its full turn in the 90-day rotation - the two found that morning
      were due in 33 and 58 windows. An auditor whose output has a writer and no reader is worse
      than one with no output: the alert describes a repair lane that does not exist.

      PURE on purpose - the report doc and the clock are both parameters - because the promotion
      itself lives inside a network-bound puller nothing can fixture. The rule, stated once so it
      can be tested (see test-capture-policy.ps1):
        1. no report, or no readable `generated` stamp -> promote NOTHING and say which it was;
           an undated report could be any age, and blind is not fresh.
        2. older than -MaxAgeHours (48) -> promote NOTHING. Once a victim is captured the next
           report drops it; if the AUDIT stops running the file freezes, and a frozen report would
           otherwise pin the front of every future slice forever.
        3. otherwise -> the distinct, non-empty terms, in the order the report lists them.
      The caller counts one budget slot per TERM and clamps at the store call cap, exactly as it
      does for a sale expiry, so promoting a victim can never breach the Freshop window.
  #>
  param($Report, [double]$MaxAgeHours = 48, $Now = $null)
  if ($null -eq $Now) { $Now = Get-Date }
  if ($null -eq $Report) { return [pscustomobject]@{ terms = @(); reason = 'no report' } }
  $gen = $null
  try { if ($Report.generated) { $gen = [datetime]$Report.generated } } catch { $gen = $null }
  if ($null -eq $gen) { return [pscustomobject]@{ terms = @(); reason = 'no readable generated stamp' } }
  $ageH = (([datetime]$Now) - $gen).TotalHours
  if ($ageH -gt $MaxAgeHours) { return [pscustomobject]@{ terms = @(); reason = ('stale: ' + [int]$ageH + ' h old') } }
  # ASSIGN THEN WRAP. @(Get-Thing ...) inline on a comma-returned array reads as ONE element in PS 5.1,
  # so an empty victims array would count 1 and promote a null term.
  $vs = @($Report.confirmed_victims)
  $terms = @($vs | Where-Object { $_ -and $_.term } | ForEach-Object { [string]$_.term } | Where-Object { $_.Trim() -ne '' } | Select-Object -Unique)
  return [pscustomobject]@{ terms = $terms; reason = ('fresh: ' + [int]$ageH + ' h old, ' + $terms.Count + ' term(s)') }
}
function Select-ExpiryFirstSlice {
  <#
    .SYNOPSIS Today's work slice with the expiring sales IN it, not merely budgeted for.
    .DESCRIPTION
      THE DEFECT (2026-08-22). Get-CapturePlan returned SaleExpiries and a TermBudget of
      rotation + expiries, and both headless lanes (Family Fare, Hy-Vee) read the BUDGET
      and ignored the LIST: they took a bigger slice of the rotation and never put the
      expiring items into it. The extra budget re-verified whatever happened to sit at
      the cursor, while the item whose sale had just ended - the one the extra slot was
      FOR - waited its turn in the quarter. Brad's rule: "reprice whenever an ad price /
      sale price / rollback price / instant-savings price drops off."

      So: the expiring items come FIRST, then the rotation fills from the cursor until
      the budget is spent. Pure - no disk, no cursor writes - so a fixture can prove an
      expiring commodity's term is in the slice.

      THE SECOND DEFECT, AND THE ORDERING RULE (2026-08-22, second pass). The expiry loop
      had NO budget test - only the rotation loop afterwards checked $Budget - so the
      returned slice was (ALL expiries) + (rotation up to budget) and taken.Count could
      exceed the budget outright. With 130 sale windows reverting on 2026-08-23 that is a
      ~19x day for Family Fare, straight into Freshop's 400/error_code 429. The loop now
      walks $Expiring IN THE ORDER GIVEN and stops at the budget like everything else.

      THE RULE, stated once so it can be tested (see test-capture-policy.ps1):
        1. expiries before rotation;
        2. expiries in the order $Expiring was given - Get-CapturePlan hands them over
           oldest refresh_on first, so the longest-owed re-price is the one that survives
           the cap and nothing starves at the back of a backlog;
        3. the CAP APPLIES TO THE WHOLE SLICE, expiries included.
      A multi-key item (a commodity with two search terms) keeps its terms adjacent
      because the walk is per expiring key, not per position in Items.

    .PARAMETER Items     the lane's full worklist in rotation order (terms, or products)
    .PARAMETER Expiring  keys of the items whose sale ended (commodity ids, or terms),
                         PRIORITY ORDER - first is taken first when the budget is short
    .PARAMETER KeyOf     scriptblock: item -> the key(s) it answers to (string or string[])
    .PARAMETER Budget    total items to take today; <= 0 means unbudgeted (all, expiries first)
    .PARAMETER CursorStart  where the rotation starts in Items
    .OUTPUTS  @{ Items; Prepended; FromRotation; CursorNext; ExpiryDropped }
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][AllowEmptyCollection()]$Items,
    [AllowEmptyCollection()][string[]]$Expiring = @(),
    [Parameter(Mandatory)][scriptblock]$KeyOf,
    [int]$Budget = 0,
    [int]$CursorStart = 0
  )
  $all = @($Items); $n = $all.Count
  $taken = New-Object System.Collections.Generic.List[object]
  $seen = New-Object 'System.Collections.Generic.HashSet[int]'
  $prepended = 0
  $expDropped = 0
  $wanted = @(@($Expiring) | Where-Object { $_ })
  if ($wanted.Count -gt 0 -and $n -gt 0) {
    # key -> the positions in Items that answer to it, in Items order (so a commodity's
    # two search terms stay adjacent and in their catalogue order).
    $byKey = @{}
    for ($i = 0; $i -lt $n; $i++) {
      foreach ($k in @(& $KeyOf $all[$i])) {
        if (-not $k) { continue }
        $ks = [string]$k
        if (-not $byKey.ContainsKey($ks)) { $byKey[$ks] = New-Object System.Collections.Generic.List[int] }
        [void]$byKey[$ks].Add($i)
      }
    }
    $full = $false
    foreach ($k in $wanted) {
      $ks = [string]$k
      if (-not $byKey.ContainsKey($ks)) { continue }
      foreach ($idx in $byKey[$ks]) {
        if ($seen.Contains($idx)) { continue }
        # THE CAP APPLIES TO THE EXPIRIES TOO. Everything past it is not lost - it stays
        # OWED in sale-windows.json (repriced_for is only written for what actually landed)
        # and comes back at the front of tomorrow's slice, oldest first.
        if ($Budget -gt 0 -and $taken.Count -ge $Budget) { $full = $true; break }
        [void]$taken.Add($all[$idx]); [void]$seen.Add($idx); $prepended++
      }
      if ($full) { $expDropped++ }
    }
    if ($full) {
      # count the whole un-taken tail, not just the key we stopped on
      $expDropped = 0
      foreach ($k in $wanted) {
        $ks = [string]$k
        if (-not $byKey.ContainsKey($ks)) { continue }
        $any = $false
        foreach ($idx in $byKey[$ks]) { if ($seen.Contains($idx)) { $any = $true; break } }
        if (-not $any) { $expDropped++ }
      }
    }
  }
  $walked = 0
  if ($n -gt 0) {
    $start = (($CursorStart % $n) + $n) % $n
    while ($walked -lt $n) {
      if ($Budget -gt 0 -and $taken.Count -ge $Budget) { break }
      $idx = ($start + $walked) % $n
      $walked++
      if ($seen.Contains($idx)) { continue }
      [void]$taken.Add($all[$idx]); [void]$seen.Add($idx)
    }
  }
  return [pscustomobject]@{
    Items         = $taken.ToArray()
    Prepended     = $prepended
    FromRotation  = ($taken.Count - $prepended)
    ExpiryDropped = $expDropped
    CursorNext    = if ($n -gt 0) { (($CursorStart + $walked) % $n) } else { 0 }
  }
}

function Get-SaleWindowsPath { return (Join-Path $script:PolicyRoot 'sale-windows.json') }

function Set-SaleExpiryProcessed {
  <#
    .SYNOPSIS Record that a store's expiring sales were actually re-priced, so they can be pruned.
    .DESCRIPTION
      THE HALF THAT MAKES CAPPING SAFE (2026-08-22). build-sale-windows.ps1 used to prune an
      entry the day after its refresh_on, by DATE alone. Cap the slice without changing that
      and every expiry the cap deferred is deleted unprocessed - its sale price then keeps
      publishing until the item's next quarterly slot, up to 90 days later. Silently stale
      prices are worse than a throttle, because nothing reports them.

      So the prune now needs a signal, and this is the only thing that writes it:
          repriced_on  = the day a landed capture covered this window
          repriced_for = the refresh_on value that capture satisfied
      Both are written ONLY for ids this run actually asked for, and only when the store's
      capture LANDED (Test-CaptureLanded - fresh rows on disk, not an exit code). A run that
      fetched nothing marks nothing and therefore loses nothing; those ids are still owed
      tomorrow, at the front of the slice.

      ATTEMPTED-AND-LANDED, NOT PROVEN-REPRICED, and that is deliberate. Judging per item -
      "did a fresh row for this exact commodity appear?" - would let one commodity the store
      simply does not carry sit at the head of the oldest-first queue forever, blocking the
      backlog behind it and re-spending its slot every single day. Marking what a landed run
      was asked for keeps the queue draining. The cost is that a commodity the lane asked for
      and failed to find is marked done; it is re-priced by the quarterly rotation instead,
      which is exactly what happens to every non-sale item anyway.

    .PARAMETER Ids  override the ids to mark. Default: exactly the capped slice
                    Get-CapturePlan handed this store today.
    .PARAMETER Landed  override the landing test (a lane that just wrote the file).
    .OUTPUTS @{ Store; Today; Marked; Ids; Reason }
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Store,
    [string]$Today = '',
    [string]$OutDir = '',
    [AllowEmptyCollection()][string[]]$Ids = @(),
    [nullable[bool]]$Landed = $null,
    [switch]$AllowReplay
  )
  if (-not $OutDir) { $OutDir = Join-Path $script:PolicyRoot 'out' }
  $todayS = if ($Today) { $Today } else { (Get-Date).ToString('yyyy-MM-dd') }
  $res = [pscustomobject]@{ Store = $Store; Today = $todayS; Marked = 0; Ids = @(); Reason = '' }

  # A REPLAY IS NOT NEW WORK, the same rule Step-CaptureCursor learned on 2026-08-21 when a
  # builder's SELF-TEST fixture dates advanced the production cursor #7 -> #63 in two hours.
  # This write is strictly more dangerous: marking a window processed is what ALLOWS the next
  # build to delete it, so a self-test could retire a re-price that never happened. Judged
  # against the WALL CLOCK on purpose - "is this a replay?" is the one question a pinned date
  # cannot answer. -AllowReplay exists only for this file's own fixtures.
  if (-not $AllowReplay) {
    $realToday = (Get-Date).ToString('yyyy-MM-dd')
    if ($todayS -ne $realToday) {
      $res.Reason = "refusing to record re-prices on a REPLAY: this run's date is $todayS but today is $realToday"
      return $res
    }
  }

  $want = @(@($Ids) | Where-Object { $_ })
  if ($want.Count -eq 0) {
    try { $want = @((Get-CapturePlan -Store $Store -Today $todayS).SaleExpiries | Where-Object { $_ }) } catch { $want = @() }
  }
  if ($want.Count -eq 0) { $res.Reason = 'nothing was owed / asked for today'; return $res }

  $did = if ($null -ne $Landed) { [bool]$Landed } else { Test-CaptureLanded -Store $Store -Today $todayS -OutDir $OutDir }
  if (-not $did) {
    $res.Reason = "no fresh rows landed for $todayS - $($want.Count) expiry(ies) stay OWED and lead tomorrow's slice"
    return $res
  }

  # THE WHOLE READ-MODIFY-WRITE IS INSIDE ONE LOCK (2026-09-11). capture-run starts the Hy-Vee, Baker's and Family
  # Fare lanes together and each one ends here; the walled builders reach it through commit-capture-cursor, the 10:30
  # watchdog's Family Fare window reaches it with no capture-run mutex, and build-sale-windows rewrites the same file
  # under the same lock. Without it two writers read the same windows, each marks its own store, and the second write
  # carries the first store's windows back UNMARKED - a re-price that really landed is owed again and fetched again.
  # The existence check and the read are inside the lock on purpose: a lock around the write alone still writes what
  # was read before it was taken. The rule is lib\ledger-lock.ps1; the fixture is this file's -SelfTest.
  $p = Get-SaleWindowsPath
  $lock = Enter-TcLedgerLock -Path $p
  try {
    if (-not (Test-Path $p)) { $res.Reason = 'no sale-windows.json'; return $res }
    $doc = $null
    try { $doc = ConvertFrom-Json ([IO.File]::ReadAllText($p)) } catch { $res.Reason = 'sale-windows.json unreadable'; return $res }
    if (-not $doc -or -not $doc.windows) { $res.Reason = 'sale-windows.json has no windows'; return $res }

    $todayD = [datetime]::ParseExact($todayS, 'yyyy-MM-dd', $null)
    $set = @{}; foreach ($i in $want) { $set[[string]$i] = $true }
    $marked = New-Object System.Collections.Generic.List[string]
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($w in @($doc.windows)) {
      $e = [ordered]@{}
      foreach ($pr in $w.PSObject.Properties) { $e[$pr.Name] = $pr.Value }
      $ro = [string]$w.refresh_on
      if ([string]$w.store -eq $Store -and $set.ContainsKey([string]$w.id) -and $ro) {
        $roD = $null; try { $roD = [datetime]::ParseExact($ro, 'yyyy-MM-dd', $null) } catch { }
        if ($roD -and $todayD -ge $roD -and (Get-SaleWindowRepricedFor $w) -ne $ro) {
          $e['repriced_on'] = $todayS
          $e['repriced_for'] = $ro
          [void]$marked.Add([string]$w.id)
        }
      }
      [void]$rows.Add([pscustomobject]$e)
    }
    if ($marked.Count -eq 0) { $res.Reason = 'already recorded'; return $res }

    # Atomic, for the same reason the cursor is: a torn write here loses the record of work
    # that was actually done, and the next build would prune it as unprocessed - or repeat it.
    $out = [ordered]@{}
    foreach ($pr in $doc.PSObject.Properties) { if ($pr.Name -ne 'windows') { $out[$pr.Name] = $pr.Value } }
    # Through a VARIABLE, not inline. `$dict['k'] = @($listOfPSCustomObject)` throws
    # "Argument types do not match" in Windows PowerShell 5.1 - the inline @() around a
    # generic List of PSCustomObject picks the wrong indexer overload. Reproduced 2026-08-22.
    $winArr = $rows.ToArray()
    $out['windows'] = $winArr
    # Retried against a lock-free reader, in the bytes the Set-Content -Encoding UTF8 it replaced wrote.
    [void](Write-TcAtomicFile -Path $p -Text ($out | ConvertTo-Json -Depth 6))
  } finally { Exit-TcLedgerLock $lock }

  $markedIds = @($marked | Sort-Object -Unique)
  $res.Marked = $marked.Count
  $res.Ids = $markedIds
  $res.Reason = "recorded $($marked.Count) re-price(s) after a landed capture"
  return $res
}

# ---------------------------------------------------------------------------
# WHICH STORES THE TERM CURSOR ACTUALLY GOVERNS (2026-08-21)
#
# Not all seven rotate through commodity-search terms, and pretending they do
# would be worse than not rotating at all - an audit would read a cursor that
# means nothing. Three different shapes, named rather than blurred:
#
#   TERM ROTATION  Family Fare, Walmart, Sam's Club, Aldi, Fareway, Baker's
#                  A slice of commodity-search.json per day. This cursor.
#   PRODUCT ROTATION  Hy-Vee. Its lane re-verifies by product id, not by search
#                  term, so its cursor indexes a different list entirely and
#                  lives in hyvee-rotation-cursor.json. Folding it in here would
#                  narrow a namespace: the same integer would mean two things.
#
# BAKER'S MOVED FROM "COMPREHENSIVE" TO TERM ROTATION (2026-08-22, Brad's ruling:
# "Bakers should be following the SAME logic as literally everyone else when it
# comes to ad rotation and 'everyday' pricing. IDK why its pulling the entire
# thing but it needs to stop."). This note used to read "COMPREHENSIVE Baker's -
# the Kroger API pull returns the whole catalog in one pass, so there is nothing
# to rotate and no cursor to keep", and that was true of the lane as written: it
# walked all 598 terms at 180ms every day, ~5 minutes of the daily run and the
# single largest remaining cost in the pipeline. It rotates now, over the SAME
# term list in the SAME order as the other five, so its integer means exactly what
# theirs means and one cursor file answers for all six.
#
# ONE CAVEAT THE BAKER'S LANE MUST HANDLE ITSELF, and it is the reason that lane
# passes -Landed explicitly instead of letting Step-CaptureCursor ask:
# Test-CaptureLanded reads out\regular\bakers-regular-<date>.json and counts rows,
# and that file now carries all ~7,275 rows on EVERY run because the un-asked terms
# are carried forward. So it says LANDED even on a run where every request failed.
# The honest signal is what the run ASKED and was ANSWERED, which only the lane
# knows - the same judgement Test-HyVeeCursorAdvance makes for the product cursor.
#
# Ask this before advancing anything. A store that is not TERM ROTATION must not
# get a term cursor written for it.
$script:TermRotationStores = @('Family Fare', 'Walmart', "Sam's Club", 'Aldi', 'Fareway', "Baker's")

function Test-TermRotationStore([string]$Store) { return ($script:TermRotationStores -contains $Store) }

function Get-CursorKey([string]$Store) { return ($Store -replace '[^A-Za-z0-9]', '') }

function Get-CaptureCursor {
  <# This store's current index into the shared term order, or 0 if unset. #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Store, [string]$OutDir = '')
  if (-not $OutDir) { $OutDir = Join-Path $script:PolicyRoot 'out' }
  $cur = Get-CaptureCursors $OutDir
  $key = Get-CursorKey $Store
  if ($cur.PSObject.Properties.Name -contains $key) { return [int]$cur.$key }
  return 0
}

function Save-CaptureCursor {
  <#
    Advance a store's cursor. Call ONLY after the capture landed.

    ATOMIC, because the cursor is the one file whose corruption silently loses a
    whole quarter of coverage. pull-regular-familyfare learned this the expensive
    way on 2026-08-20: a bare Set-Content threw mid-write AFTER the index had
    moved, and ~104 terms' worth of fresh prices were discarded while the cursor
    skipped straight past them. Temp-then-move so a reader never sees a partial
    file and a failed write leaves the previous index intact.
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Store, [Parameter(Mandatory)][int]$Next, [string]$OutDir = '', [string]$AdvancedOn = '')
  if (-not $OutDir) { $OutDir = Join-Path $script:PolicyRoot 'out' }
  if (-not (Test-TermRotationStore $Store)) {
    throw ("REFUSING to write a TERM cursor for '$Store': it does not rotate through " +
           "commodity-search terms (see TermRotationStores). Hy-Vee rotates by PRODUCT ID and " +
           'keeps its own cursor file; giving it a term cursor would make the same integer ' +
           'mean two different things.')
  }
  $p = Join-Path $OutDir $script:CursorFile
  # THE WHOLE READ-MODIFY-WRITE IS INSIDE ONE LOCK (2026-09-11). The Baker's and Family Fare lanes start together,
  # build-walmart-deals and build-sams-deals fan out side by side, and the 10:30 watchdog's Family Fare window takes no
  # capture-run mutex. Each writer changes only its own store's key but writes the whole file, so without the lock the
  # second write puts the first store's cursor BACK: that store re-buys a slice it already bought, and its _last date
  # goes back with it. Reentrant: Step-CaptureCursor already holds this lock when it calls here.
  $lock = Enter-TcLedgerLock -Path $p
  try {
    # AN UNREADABLE CURSOR IS NOT AN EMPTY ONE. Get-CaptureCursors answers {} for a file it cannot parse, which is right
    # for a reader and wrong here: writing {} plus this store would send every other store's rotation back to #0.
    $cur = [pscustomobject]@{}
    if (Test-Path -LiteralPath $p) {
      $cur = $null
      try { $cur = ConvertFrom-Json ([IO.File]::ReadAllText($p)) } catch { }
      if ($null -eq $cur) {
        throw ("REFUSING to write the term cursor for '$Store': $p exists but could not be read. Writing it would send every other store's rotation back to #0; the file is left exactly as it was.")
      }
    }
    $h = @{}
    foreach ($pr in $cur.PSObject.Properties) { $h[$pr.Name] = $pr.Value }
    $h[(Get-CursorKey $Store)] = $Next
    # The date this store last moved. Step-CaptureCursor reads it to enforce one slice per day,
    # so a builder that runs twice does not rotate twice.
    if ($AdvancedOn) { $h[((Get-CursorKey $Store) + '_last')] = $AdvancedOn }
    $h['updated'] = (Get-Date).ToString('s')
    $h['note'] = 'index into the commodity-search term order where each TERM-ROTATION store starts next. Advanced only after that store''s capture landed. Baker''s joined this cursor on 2026-08-22 (it used to pull all 598 terms daily). Hy-Vee is deliberately absent: it rotates by PRODUCT ID and keeps hyvee-rotation-cursor.json.'
    # Retried against a lock-free reader, in the bytes the Set-Content -Encoding UTF8 it replaced wrote.
    [void](Write-TcAtomicFile -Path $p -Text ($h | ConvertTo-Json -Depth 4))
  } finally { Exit-TcLedgerLock $lock }
}

function Write-CursorLog {
  <#
    .SYNOPSIS Append one line per cursor advance: who moved it, from where, to where, and when.
    .DESCRIPTION
      WHY THIS EXISTS (2026-08-21). Fareway's cursor moved from #7 to #63 - eight slices - inside a
      two-hour window on the day the one-slice-per-day guard shipped, and afterwards NOTHING on disk
      could say which process did it. The cursor file records only the latest value, so a run that
      moves it eight times and a run that moves it once look identical afterwards. The guard tests
      green when driven directly, so the honest position is "there is a path I have not reproduced",
      and the fix for that is evidence, not another guess.

      One JSONL line per advance, carrying the CALLER (the top-level script that invoked this) and
      the process id, so the next occurrence names itself instead of having to be re-derived. Never
      fatal: a cursor that moves but cannot be logged is still a moved cursor, and losing the write
      must not lose the capture.
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Store, [int]$From, [int]$To, [string]$Today, [string]$OutDir = '')
  try {
    if (-not $OutDir) { $OutDir = Join-Path $script:PolicyRoot 'out' }
    # The outermost script in the call stack is the thing that actually caused this.
    $caller = ''
    try {
      $stack = @(Get-PSCallStack | Where-Object { $_.ScriptName } | Select-Object -ExpandProperty ScriptName)
      if ($stack.Count) { $caller = (Split-Path $stack[-1] -Leaf) }
    } catch { }
    $line = [ordered]@{
      at = (Get-Date).ToString('s'); store = $Store; from = $From; to = $To
      day = $Today; caller = $caller; pid = $PID
    } | ConvertTo-Json -Compress
    Add-Content -LiteralPath (Join-Path $OutDir 'capture-cursor-log.jsonl') -Value $line -Encoding UTF8
  } catch { }
}

function Test-CaptureLanded {
  <#
    .SYNOPSIS Did this store actually contribute fresh everyday rows for $Today?

    This is the gate on advancing the cursor, and it deliberately asks about the
    DATA, not about an exit code. A lane can exit 0 having bought nothing - that
    is exactly what Family Fare's throttled runs do - and advancing on rc=0 would
    skip the slice those terms were owed. A run that fetched nothing must re-attempt
    the same slice tomorrow, never skip it.
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Store, [string]$Today = '', [string]$OutDir = '')
  if (-not $OutDir) { $OutDir = Join-Path $script:PolicyRoot 'out' }
  $todayS = if ($Today) { $Today } else { (Get-Date).ToString('yyyy-MM-dd') }

  # regular_prefix is stores.json's own name for the store's everyday file, so the
  # mapping is not duplicated here.
  $prefix = $null
  $dealsGlob = $null
  try {
    $sj = Get-PolicyJson 'stores.json'
    foreach ($s in $sj.stores) {
      if ([string]$s.name -eq $Store) { $prefix = [string]$s.regular_prefix; $dealsGlob = [string]$s.deals_glob; break }
    }
  } catch { }
  if (-not $prefix -and -not $dealsGlob) { return $false }

  function Test-RowsDated([string]$Path) {
    if (-not (Test-Path $Path)) { return $false }
    try {
      $doc = ConvertFrom-Json ([IO.File]::ReadAllText($Path))
      # AN EMPTY deals ARRAY IS FALSY, AND THAT INVERTED THIS TEST (fixed 2026-08-22).
      # `if ($doc.deals)` is FALSE for an empty array in PS 5.1, so a file that legitimately
      # contained `"deals": []` fell through to the `@($doc)` branch, which wraps the whole document
      # object and counts 1 - reporting LANDED for a capture that priced nothing.
      # Measured: build-walmart-deals wrote 333 raw -> 0 priced, and the cursor still advanced
      # #0 -> #7, skipping that slice for a full quarter. The function's own docstring says the
      # opposite ("a run that fetched nothing must re-attempt the same slice tomorrow, never skip
      # it"), so this was a silent inversion of the stated rule, in the safe-sounding direction.
      # Ask whether the PROPERTY EXISTS, then count it - never lean on array truthiness.
      $rows = if ($doc.PSObject.Properties['deals']) { @($doc.deals) } else { @($doc) }
      return (@($rows).Count -gt 0)
    } catch { return $false }
  }

  if ($prefix) {
    $f = Join-Path $OutDir ("regular\{0}-regular-{1}.json" -f $prefix, $todayS)
    if (Test-RowsDated $f) { return $true }
  }

  # NOT EVERY STORE HAS AN out\regular FILE, AND SAM'S NEVER HAS (fixed 2026-08-22).
  # This asked only about regular\<prefix>-regular-<date>.json. Sam's Club does not produce one -
  # build-sams-deals writes out\sams\sams-deals-<date>.json, which is the contract compare-deals
  # reads it through (-SamsFile). So the answer for Sam's was ALWAYS $false, which meant its
  # rotation cursor could never advance: a landed capture of 100 priced rows still reported
  # "no fresh rows landed - the slice is re-attempted tomorrow", forever, on slice #0.
  # A gate that can never arm ([[gates-that-can-never-arm]]) - and a silent one, because
  # "re-attempt tomorrow" is the SAFE-sounding branch, so it reads as caution rather than a defect.
  # stores.json already declares deals_glob for exactly these stores; consult it rather than
  # inventing a second mapping here.
  if ($dealsGlob) {
    $rel = ($dealsGlob -replace '^out[\\/]', '') -replace '/', '\'
    # The glob names the SHAPE; only today's file counts, so the date is substituted in.
    $dated = $rel -replace '\*', $todayS
    if (Test-RowsDated (Join-Path $OutDir $dated)) { return $true }
  }
  return $false
}

function Step-CaptureCursor {
  <#
    .SYNOPSIS The ONE implementation of "advance only after the capture landed".
    .DESCRIPTION Returns a result object describing what it did and why. Every lane
                 calls this rather than computing its own next index, so the rule
                 cannot drift into five slightly different versions.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Store,
    [string]$Today = '',
    [string]$OutDir = '',
    # Override the landing test when the caller already knows (a browser builder
    # that just wrote the file, say). Still verified unless -Force.
    [nullable[bool]]$Landed = $null,
    [switch]$Force
  )
  if (-not $OutDir) { $OutDir = Join-Path $script:PolicyRoot 'out' }
  $todayS = if ($Today) { $Today } else { (Get-Date).ToString('yyyy-MM-dd') }

  if (-not (Test-TermRotationStore $Store)) {
    return [pscustomobject]@{ Store = $Store; Advanced = $false; From = $null; To = $null
      Reason = "not a term-rotation store (Hy-Vee rotates by product id and keeps its own cursor file)" }
  }

  $did = if ($null -ne $Landed) { [bool]$Landed } else { Test-CaptureLanded -Store $Store -Today $todayS -OutDir $OutDir }

  # ONE SLICE PER STORE PER DAY, however many times this is called.
  # The commit lives in each store's BUILDER, and a builder can legitimately run several times
  # in a day - a retry, a partial re-build, a daily check task that re-prices after a sale
  # flip. Without this, every one of those advanced the cursor another 7 terms and the rotation
  # sprinted past terms nobody captured. Measured on 2026-08-21, the hour this hook shipped:
  # Fareway went to #63, nine slices ahead, on a day it had landed ONE capture. Over-advancing
  # is the dangerous direction - a skipped term is not captured for another quarter, whereas a
  # repeated one merely costs a few requests - so the guard errs toward repeating.
  # A REPLAY IS NOT NEW WORK (2026-08-21). The cursor may only be advanced by a run whose date IS
  # today's real date. Found by the advance log this guard shipped with, which recorded:
  #     {"from":14,"to":21,"day":"2026-07-31","caller":"build-fareway-regular.ps1"}
  #     {"from":21,"to":28,"day":"2026-08-01","caller":"build-fareway-regular.ps1"}
  # Those are the BUILDER'S SELF-TEST fixture dates. The self-tests were advancing the PRODUCTION
  # cursor, and the one-slice-per-day guard below could not see it: it compares <store>_last against
  # the date it was PASSED, and a frozen fixture date never equals today, so every self-test run
  # sailed through. That is what moved Fareway #7 -> #63 in two hours, and it is a test mutating live
  # state - the worst kind of coupling, because the more you verify the further the damage goes.
  # Checked against the WALL CLOCK on purpose. Everything else in this estate is judged against the
  # board's own date so that a pinned regression run stays reproducible; this is the one decision that
  # must not be, because "is this a replay?" is exactly the question a pinned date cannot answer.
  $realToday = (Get-Date).ToString('yyyy-MM-dd')
  if ($todayS -ne $realToday) {
    return [pscustomobject]@{ Store = $Store; Advanced = $false; From = (Get-CaptureCursor -Store $Store -OutDir $OutDir); To = (Get-CaptureCursor -Store $Store -OutDir $OutDir)
      Reason = "refusing to advance on a REPLAY: this run's date is $todayS but today is $realToday - a rebuild of an older capture, or a self-test, must never move the live rotation" }
  }

  # FROM, THE DAY GUARD AND THE ADVANCE ARE ONE READ-MODIFY-WRITE (2026-09-11). They were three lock-free steps - read
  # `from`, check <store>_last, save from + rotation - so two runs of one store's builder at once both read the old
  # _last, both passed the guard, and both advanced and logged: the double advance the guard exists to stop, let
  # through by timing. Holding the cursor lock across all three makes the second run read the first run's _last.
  # Save-CaptureCursor takes the same lock again inside, which a mutex allows in one thread.
  $lock = Enter-TcLedgerLock -Path (Join-Path $OutDir $script:CursorFile)
  try {
    $from = Get-CaptureCursor -Store $Store -OutDir $OutDir
    $lastKey = (Get-CursorKey $Store) + '_last'
    $cursors = Get-CaptureCursors $OutDir
    if ($cursors.PSObject.Properties.Name -contains $lastKey -and [string]$cursors.$lastKey -eq $todayS -and -not $Force) {
      return [pscustomobject]@{ Store = $Store; Advanced = $false; From = $from; To = $from
        Reason = "already advanced for $todayS - one rotation slice per day, no matter how many times the builder runs" }
    }

    if (-not $did -and -not $Force) {
      return [pscustomobject]@{ Store = $Store; Advanced = $false; From = $from; To = $from
        Reason = "no fresh rows landed for $todayS - the slice is re-attempted tomorrow, not skipped" }
    }

    $plan = Get-CapturePlan -Store $Store -Today $todayS
    $all = Get-AllTerms
    if ($all.Count -le 0) {
      return [pscustomobject]@{ Store = $Store; Advanced = $false; From = $from; To = $from; Reason = 'no terms' }
    }
    $to = (($from + $plan.RotationTerms) % $all.Count)
    Save-CaptureCursor -Store $Store -Next $to -OutDir $OutDir -AdvancedOn $todayS
    Write-CursorLog -Store $Store -From $from -To $to -Today $todayS -OutDir $OutDir
    return [pscustomobject]@{ Store = $Store; Advanced = $true; From = $from; To = $to
      Reason = "advanced $($plan.RotationTerms) term(s) after a landed capture" }
  } finally { Exit-TcLedgerLock $lock }
}

function Test-HyVeeCursorAdvance {
  <#
    .SYNOPSIS Has today's Hy-Vee run earned the right to move the PRODUCT rotation on?
    .DESCRIPTION
      THE RULE, AND WHY IT IS NOT "advance after the file landed" (2026-08-22). Every other cursor in
      this estate advances only once the capture has LANDED - see Step-CaptureCursor - because a run that
      bought nothing must re-attempt its slice rather than skip it. The Hy-Vee product lane found the
      other edge of that rule the hard way. Its commit sat after the everyday file was written, the
      capture-policy budget collapsed the file to 7 rows, the THROTTLE-WIPEOUT guard quarantined it and
      exited 2 - so the cursor was never written AT ALL. Every subsequent run re-read cursor 0, took the
      same 7 products, and those 7 carry no product link, so the lane reported "0 refreshed, 7 not
      re-verified" every day while Hy-Vee's prices sat frozen. Not a slow day: a DEADLOCK, and the thing
      that made it one is that a refused write also refused the rotation.

      So this lane advances on what the run ASKED, not on what it managed to write:

        answered > 0                        ADVANCE. The store answered; those products had their turn,
                                            whether or not the file was allowed to land afterwards.
        attempted > 0, answered = 0         HOLD. Every request failed - a dead or throttled endpoint,
                                            not a day's work. Burning the slice here is exactly the
                                            Family Fare failure of 2026-08-20 (a cursor that ran ahead
                                            of a capture that never happened).
        attempted = 0, slice all unaskable  ADVANCE. Nothing in the slice carries a product id, so there
                                            was nothing to ask and there never will be; re-asking
                                            nothing tomorrow is the deadlock above, verbatim.
        attempted = 0, slice was askable    HOLD. We had things to ask and did not ask them (the
                                            wall-clock cap, an early exit). Those products are owed.

      Pure: the fixtures state the four cases directly.
  #>
  [CmdletBinding()]
  param([int]$Attempted = 0, [int]$Answered = 0, [int]$SliceSize = 0, [int]$SliceUnaskable = 0)
  if ($Answered -gt 0) {
    return [pscustomobject]@{ Advance = $true; Reason = "the store answered for $Answered of the $Attempted product(s) asked" }
  }
  if ($Attempted -gt 0) {
    return [pscustomobject]@{ Advance = $false
      Reason = "$Attempted request(s) issued and NOT ONE was answered - a dead or throttled endpoint, not a day's work; this slice is re-attempted tomorrow" }
  }
  if ($SliceSize -gt 0 -and $SliceUnaskable -ge $SliceSize) {
    return [pscustomobject]@{ Advance = $true
      Reason = "none of the $SliceSize product(s) in today's slice carries a retailer product id - there was nothing to ask, and re-asking nothing tomorrow is a deadlock, not patience" }
  }
  return [pscustomobject]@{ Advance = $false
    Reason = 'no request was issued and the slice was askable (wall-clock cap, or an early exit) - those products are owed their turn' }
}

function Step-HyVeeProductCursor {
  <#
    .SYNOPSIS Advance the Hy-Vee PRODUCT rotation cursor, under the same guards as the term cursor.
    .DESCRIPTION
      A SEPARATE FILE, DELIBERATELY. Hy-Vee indexes 1,554 PRODUCT IDS while capture-cursor.json indexes
      commodity-search TERMS; folding them together would make the same integer mean two different things
      (see TermRotationStores above), which is why Save-CaptureCursor REFUSES to write a term cursor for
      this store. But the guards are the same guards, and they live here rather than inside the puller so
      the two cursors cannot drift into two slightly different sets of rules:

        REPLAYS DO NOT COUNT      a run whose date is not the wall-clock date - a rebuild of an older
                                  capture, or a self-test on a frozen fixture date - must never move the
                                  live rotation. That is what took Fareway from #7 to #63 in two hours.
        ONE SLICE PER DAY         however many times the builder runs. Over-advancing is the dangerous
                                  direction: a skipped product waits a quarter, a repeated one costs one
                                  request.
        ONLY IF THE RUN ASKED     Test-HyVeeCursorAdvance above; the whole judgement is in that function.
        ATOMIC                    temp-then-move, because a torn cursor silently loses a quarter of
                                  coverage and reads as a valid file afterwards.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][int]$Next,
    [int]$From = 0,
    [int]$Attempted = 0, [int]$Answered = 0, [int]$SliceSize = 0, [int]$SliceUnaskable = 0,
    [string]$Today = '', [string]$OutDir = '', [switch]$Force
  )
  if (-not $OutDir) { $OutDir = Join-Path $script:PolicyRoot 'out' }
  $todayS = if ($Today) { $Today } else { (Get-Date).ToString('yyyy-MM-dd') }
  $p = Join-Path $OutDir 'hyvee-rotation-cursor.json'

  $realToday = (Get-Date).ToString('yyyy-MM-dd')
  if ($todayS -ne $realToday -and -not $Force) {
    return [pscustomobject]@{ Advanced = $false; From = $From; To = $From
      Reason = "refusing to advance on a REPLAY: this run's date is $todayS but today is $realToday" }
  }

  $doc = $null
  if (Test-Path $p) { try { $doc = ConvertFrom-Json ([IO.File]::ReadAllText($p)) } catch { $doc = $null } }
  if ($doc -and ([string]$doc.last_advanced) -eq $todayS -and -not $Force) {
    return [pscustomobject]@{ Advanced = $false; From = $From; To = $From
      Reason = "already advanced for $todayS - one product slice per day, no matter how many times the puller runs" }
  }

  $d = Test-HyVeeCursorAdvance -Attempted $Attempted -Answered $Answered -SliceSize $SliceSize -SliceUnaskable $SliceUnaskable
  if (-not $d.Advance -and -not $Force) {
    return [pscustomobject]@{ Advanced = $false; From = $From; To = $From; Reason = $d.Reason }
  }

  $tmp = "$p.tmp"
  Set-Content -Path $tmp -Encoding UTF8 -Value (([ordered]@{
    next_index    = $Next
    from_index    = $From
    last_advanced = $todayS
    updated       = (Get-Date).ToString('s')
    note          = 'PRODUCT-index rotation cursor for the Hy-Vee re-verify lane (NOT the commodity-search term cursor in capture-cursor.json). Advanced when the run ASKED the store, even if the write was later refused - a refused write must not also refuse the rotation, or the same slice is re-asked forever.'
  }) | ConvertTo-Json)
  Move-Item -LiteralPath $tmp -Destination $p -Force
  Write-CursorLog -Store 'Hy-Vee (products)' -From $From -To $Next -Today $todayS -OutDir $OutDir
  return [pscustomobject]@{ Advanced = $true; From = $From; To = $Next; Reason = $d.Reason }
}

function Write-CaptureWorklist {
  <#
    .SYNOPSIS Emit today's worklist file for a store (what the browser agent reads).
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Store, [string]$Today = '', [string]$OutDir = '')
  if (-not $OutDir) { $OutDir = Join-Path $script:PolicyRoot 'out' }
  $wl = Get-CaptureWorklist -Store $Store -Today $Today -OutDir $OutDir
  $slug = ($Store -replace "[^A-Za-z0-9]", '').ToLower()
  $dir = Join-Path $OutDir 'worklists'
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $file = Join-Path $dir ("capture-{0}-{1}.json" -f $slug, $wl.Today)
  $doc = [ordered]@{
    store          = $wl.Store
    date           = $wl.Today
    policy         = "ad-rollover + sale-expiry + quarterly rotation ($($wl.QuarterDays)d)"
    ad_rollover    = $wl.AdRollover
    ad_note        = $wl.AdNote
    cursor_start   = $wl.CursorStart
    cursor_next    = $wl.CursorNext
    total_terms    = $wl.TotalTerms
    rotation_terms = @($wl.RotationTerms | ForEach-Object { $_.term })
    sale_terms     = @($wl.SaleTerms | ForEach-Object { $_.term })
    # A STANDING RULING'S OWED TERMS, AT THE HEAD OF `terms` (2026-09-12). Walmart's store-drift
    # ruling of 2026-08-28 named terms priced at the wrong store; these are the ones not yet proven
    # recaptured at the sanctioned store. Derived, so the list empties itself and then disappears.
    ruling_terms   = @($wl.RulingTerms | ForEach-Object { $_.term })
    ruling_owed_total = @($wl.RulingOwed).Count
    ruling_of       = $wl.RulingTotal
    ruling_deferred = $wl.RulingDeferred
    ruling_blind    = $wl.RulingBlind
    ruling_blind_why = $wl.RulingWhy
    call_cap       = $wl.CallCap
    expiry_deferred = $wl.ExpiryDeferred
    expiry_deferred_by_ruling = $wl.SaleDeferredByRuling
    expiry_oldest_owed = $wl.ExpiryOldest
    note           = 'Fetch ONLY these terms today - the list is already capped at this store''s call_cap so it cannot trip a rate limit. Advance the cursor with Save-CaptureCursor AFTER the capture lands - a run that fetched nothing must re-attempt this slice tomorrow, never skip it. expiry_deferred re-prices did NOT fit today; they are still recorded as owed in sale-windows.json and lead tomorrow''s slice, oldest first - do NOT fetch them here. ruling_terms are a STANDING RULING''s owed recaptures and lead this list; they leave it on their own once a built file proves them recaptured at the sanctioned store, so never edit a ruling file to discharge one. ruling_blind means this checkout could not read what has already landed and is reporting everything the ruling named.'
  }
  Set-Content -Path $file -Value ($doc | ConvertTo-Json -Depth 5) -Encoding UTF8
  return $file
}

# ---- WHO OWNS THIS STORE'S CAPTURE RIGHT NOW (2026-09-09, queue 2026-09-09-e60137) ---------------------
#
# THE SHAPE. At 07:02 the ad run found Baker's ad window had rolled over, queued 17 terms for it and
# DEFERRED the store to a browser owner, writing out\browser-capture-due-2026-09-09.flag. At 08:35
# audit-row-age paged "AD COVERAGE GONE: Baker's" for a store the pipeline had explicitly handed to
# someone else 93 minutes earlier, and at 09:10 that owner's 146-row capture landed. The alert was true
# when it fired and false 35 minutes later. A store with a named owner and work in flight is not an
# unowned gap, and paging it as one is how an ops queue teaches people to skim.
#
# THE EXPIRY IS THE WHOLE SAFETY PROPERTY. An ownership record that never ages out would hide a browser
# agent that simply never ran - the Fareway $1.99/lb pork chops shape, a real gap invisible for a week.
# So ownership is worth exactly 24 hours from the moment the store was FIRST deferred, and after that
# the emitters page normally. Refusing to alert is a loan against attention, not a write-off.
#
# WHY FIRST-DEFERRED AND NOT THE FILE'S MTIME, which is the half the plan could not have known: the flag
# is ONE FILE PER DATE and every run REWRITES it with only its own outstanding set. Measured on 09-09:
# the 07:02 ad run wrote it naming Baker's; the 08:06 daily run overwrote the same file naming Aldi and
# Walmart, and Baker's ownership record was gone 29 minutes before the alert that needed it. Keying the
# expiry on the file's mtime would also mean a store deferred a week ago looks freshly owned every
# morning, because some other store's deferral keeps refreshing the timestamp. So the writer now carries
# an `owned` map of store -> when it was first deferred TODAY, and this reads that. A flag with no
# `owned` map (every flag written before this change) falls back to the file's mtime, which is the best
# evidence those files carry and is never treated as newer than it is.
function Test-BrowserCaptureOwned {
  <# .SYNOPSIS  Is <Store> currently deferred to a browser owner, with the deferral still inside its
                expiry window? .DESCRIPTION Reads out\browser-capture-due-*.flag. Returns $false for
                anything it cannot prove - an unreadable flag is not ownership, and could-not-look must
                never settle the question in the quiet direction. #>
  param(
    [Parameter(Mandatory=$true)][string]$Store,
    [Parameter(Mandatory=$true)][string]$OutDir,
    [datetime]$Now = (Get-Date),
    [double]$MaxAgeHours = 24
  )
  if (-not $Store -or -not $OutDir -or -not (Test-Path $OutDir)) { return $false }
  # "Baker's" / "Bakers" / "BAKER'S" are one store. The flag is written by one script and read by two
  # others, and an apostrophe has already cost this estate a guard that was permanently red.
  $key = ($Store -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
  if (-not $key) { return $false }
  $flags = @(Get-ChildItem (Join-Path $OutDir 'browser-capture-due-*.flag') -ErrorAction SilentlyContinue)
  foreach ($f in $flags) {
    $doc = $null
    try { $doc = (Get-Content $f.FullName -Raw -Encoding UTF8) | ConvertFrom-Json } catch { continue }
    if (-not $doc) { continue }
    $deferredAt = $null
    # Preferred: the per-store stamp, which survives another run rewriting the file for a different store.
    if ($doc.PSObject.Properties['owned'] -and $doc.owned) {
      foreach ($p in $doc.owned.PSObject.Properties) {
        if ((([string]$p.Name) -replace '[^A-Za-z0-9]', '').ToLowerInvariant() -ne $key) { continue }
        try { $deferredAt = [datetime]::Parse([string]$p.Value) } catch { $deferredAt = $f.LastWriteTime }
        break
      }
    }
    # Fallback for a flag written before the `owned` map existed: the store list plus the file's mtime.
    if (-not $deferredAt -and $doc.PSObject.Properties['stores']) {
      foreach ($s in @($doc.stores)) {
        if ((([string]$s) -replace '[^A-Za-z0-9]', '').ToLowerInvariant() -eq $key) { $deferredAt = $f.LastWriteTime; break }
      }
    }
    if (-not $deferredAt) { continue }
    if (($Now - $deferredAt).TotalHours -lt $MaxAgeHours) { return $true }
  }
  return $false
}

# The line an emitter prints INSTEAD of paging, so a downgraded alert is still visible in the transcript.
# Silence and "somebody else is on it" must not look the same in a log.
function Get-BrowserOwnedNote {
  param([Parameter(Mandatory=$true)][string]$Store)
  return ("$Store is deferred to a browser capture owner (out\browser-capture-due-<date>.flag) and the deferral is under 24h old, so this is an OWNED gap in flight, not an unowned one. It escalates normally once the deferral passes 24h.")
}

# ---------------------------------------------------------------------------
# SELF-TEST: the two ledgers this file writes, written by concurrent PROCESSES (2026-09-11).
#   powershell -File grocery\capture-policy-lib.ps1 -SelfTest
# test-capture-policy.ps1 carries the policy rules. This carries the one thing a single process cannot show: what a
# write does when a SIBLING writes the same file at the same moment. Every writer is its own powershell.exe launched by
# lib\ledger-fixture.ps1's Invoke-TcLedgerWriters. Each pays its start-up and dot-sources this file, and is then held on
# the fixture gate inside Enter-TcLedgerLock until all of them are there (ops-and-gates.md: the barrier goes inside the
# writer). Each then writes many times, so the WRITES overlap and not merely the processes. Every write goes into a
# temp directory, and nothing is asserted on time.
# AN ERROR PART-WAY IS A FAILURE, NEVER A SHORT PASS - see rollback-ttl-lib's self-test for the day it was not.
if ($__cplSelfTest) {
  $script:cplN = 0; $script:cplBad = 0
  function Test-CplCase([string]$What, [bool]$Cond, [string]$Detail = '') {
    $script:cplN++
    if ($Cond) { Write-Output ('  ok    ' + $What) }
    else { $script:cplBad++; Write-Output ('  FAIL  ' + $What + $(if ($Detail) { ' -> ' + $Detail } else { '' })) }
  }
  # One NAME=number line out of a writer's stdout, or -1 when the writer never printed it.
  function Get-CplField($Writer, [string]$Name) {
    $m = [regex]::Match([string]$Writer.out, ('(?m)^' + $Name + '=(-?\d+)'))
    if ($m.Success) { return [int]$m.Groups[1].Value }
    return -1
  }
  # Every writer's own WHY line, after lib\ledger-fixture.ps1's account of any writer that did not run cleanly.
  function Get-CplWhy([object[]]$Writers) {
    $why = Format-TcWriterTrouble $Writers
    foreach ($w in @($Writers)) { if ([string]$w.out -match '(?m)^WHY (.*)$') { $why += (' | writer ' + $w.n + ': ' + $Matches[1]) } }
    return $why
  }
  function Write-CplWriter([string]$Path, [string]$Text) { [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false))) }
  # A window shaped like the ones build-sale-windows writes, owed since 2026-08-21.
  function New-CplWindow([string]$Store, [string]$Id) {
    [ordered]@{ id = $Id; commodity = $Id; store = $Store; item = ('a product called ' + $Id); sale_price = 1.99; unit = 'lb'; size = '1 lb'
                ad_text = 'weekly ad'; is_flash = $false; sale_start = '2026-08-15'; sale_end = '2026-08-20'; refresh_on = '2026-08-21'
                status = 'reprice-owed'; first_seen = '2026-08-15'; last_seen = '2026-08-20'; note = ''; repriced_on = ''; repriced_for = '' }
  }

  $cplDir = Join-Path ([IO.Path]::GetTempPath()) ('cpl-selftest-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
  [void][IO.Directory]::CreateDirectory($cplDir)
  $cplLib = $PSCommandPath
  $cplBsw = Join-Path $script:PolicyRoot 'build-sale-windows.ps1'
  $ErrorActionPreference = 'Stop'
  try {
    # ---- 1. sale-windows.json: six lanes marking their own stores, while build-sale-windows rewrites the file ----
    # Each lane marks 40 owed windows, five per call. build-sale-windows prunes a window once it is marked, so a marked
    # window is either still there WITH its mark or gone - never there without it - and a lane can check its own marks.
    # TWO THINGS MAKE A LOST MARK VISIBLE, and each was a draft that missed one:
    #   * build-sale-windows REWRITES UNTIL EVERY LANE IS DONE, not a fixed number of times. The first draft ran it three
    #     times and finished early; with its lock deleted in a temp mirror the suite stayed green 5 of 5.
    #   * EACH LANE CHECKS ITS OWN MARKS BEFORE EVERY CALL AND ONCE AFTER THE LAST. The second draft looked only at the
    #     file at the end, and went red in 3 of 5 with the lock deleted. An erasure can HEAL: a stale build-sale-windows
    #     write removes marks, and a lane that read the file inside its lock just before that write then writes its own
    #     copy, marks included, back over it. So the end state often looked whole after a real loss. A regression is now
    #     counted the moment a lane sees one, healed later or not. With the locks in place none can be seen: every
    #     writer re-reads inside the lock, and a lock-free read of a file replaced by rename is always a whole version.
    # The 300 cap on rewrites is a hang guard for a lane that died.
    $swRoot = Join-Path $cplDir 'sw'
    [void][IO.Directory]::CreateDirectory($swRoot)
    $swDone = Join-Path $cplDir 'sw-done'
    [void][IO.Directory]::CreateDirectory($swDone)
    $swStores = @('Hy-Vee', 'Aldi', "Baker's", 'Family Fare', 'Fareway', 'Walmart')
    $swRows = [Collections.Generic.List[object]]::new()
    for ($k = 0; $k -lt $swStores.Count; $k++) { for ($n = 0; $n -lt 40; $n++) { $swRows.Add((New-CplWindow $swStores[$k] ('sw-' + ($k + 1) + '-' + $n))) } }
    for ($n = 0; $n -lt 300; $n++) { $swRows.Add((New-CplWindow "Sam's Club" ('filler-' + $n))) }
    $swArr = $swRows.ToArray()
    $swFile = Join-Path $swRoot 'sale-windows.json'
    [IO.File]::WriteAllText($swFile, ([ordered]@{ updated = '2026-08-21T08:00:00'; today = '2026-08-21'; windows = $swArr } | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($true)))
    $swBoard = Join-Path $swRoot 'comparison-2026-08-22.json'
    [IO.File]::WriteAllText($swBoard, '{"comparison":[]}')
    $swSched = Join-Path $swRoot 'ad-schedule.json'
    [IO.File]::WriteAllText($swSched, '{"stores":[]}')
    $swWriter = Join-Path $cplDir 'sw-writer.ps1'
    Write-CplWriter $swWriter @'
param([string]$Lib, [string]$Root, [string]$Mode, [int]$Index, [string]$Done, [string]$Bsw = '', [string]$Board = '', [string]$Sched = '', [string]$Log = '')
$ErrorActionPreference = 'Stop'
. $Lib
$script:PolicyRoot = $Root
$stores = @('Hy-Vee', 'Aldi', "Baker's", 'Family Fare', 'Fareway', 'Walmart')
$refused = 0; $why = ''
if ($Mode -eq 'lane') {
  $marked = 0; $regressed = 0
  $myStore = $stores[$Index - 1]
  $mine = New-Object 'System.Collections.Generic.HashSet[string]'
  for ($m = 0; $m -le 8; $m++) {
    # Are this lane's marks still on disk? Read lock-free, the way the daily-due guards read it, retried past the
    # instant a replace is mid-move. A mark present but unset is a regression, counted now even if a later write heals it.
    if ($mine.Count -gt 0) {
      $doc = $null
      for ($a = 0; $a -lt 400 -and $null -eq $doc; $a++) { try { $doc = ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $Root 'sale-windows.json'))) } catch { Start-Sleep -Milliseconds 5 } }
      if ($null -ne $doc) {
        foreach ($win in @($doc.windows)) {
          if ([string]$win.store -eq $myStore -and $mine.Contains([string]$win.id) -and [string]$win.repriced_for -ne '2026-08-21') { $regressed++ }
        }
      }
    }
    if ($m -eq 8) { break }
    $ids = @(0..4 | ForEach-Object { 'sw-' + $Index + '-' + ($m * 5 + $_) })
    try {
      $r = Set-SaleExpiryProcessed -Store $myStore -Today '2026-08-22' -OutDir $Root -Ids $ids -Landed $true -AllowReplay
      $marked += [int]$r.Marked
      foreach ($id in @($r.Ids)) { if ($id) { [void]$mine.Add([string]$id) } }
    }
    catch { $refused++; $why = $_.Exception.Message }
  }
  [IO.File]::WriteAllText((Join-Path $Done ('lane-done-' + $Index)), 'x')
  Write-Output ('MARKED=' + $marked)
  Write-Output ('REGRESSED=' + $regressed)
} else {
  $built = 0
  while ($built -lt 300 -and ([IO.Directory]::GetFiles($Done, 'lane-done-*')).Length -lt $stores.Count) {
    try { & $Bsw -OutDir $Root -ComparisonFile $Board -ScheduleFile $Sched -LogFile $Log -AsOf '2026-08-22' | Out-Null; $built++ }
    catch { $refused++; $why = $_.Exception.Message; break }
  }
  Write-Output ('BUILT=' + $built)
}
Write-Output ('REFUSED=' + $refused)
if ($why) { Write-Output ('WHY ' + $why) }
exit 0
'@
    $swArgs = New-Object System.Collections.Generic.List[object]
    for ($i = 1; $i -le 6; $i++) { $swArgs.Add([string[]]@('-Lib', $cplLib, '-Root', $swRoot, '-Mode', 'lane', '-Index', [string]$i, '-Done', $swDone)) }
    $swArgs.Add([string[]]@('-Lib', $cplLib, '-Root', $swRoot, '-Mode', 'build', '-Index', '7', '-Done', $swDone, '-Bsw', $cplBsw, '-Board', $swBoard, '-Sched', $swSched, '-Log', $swFile))
    $sw = Invoke-TcLedgerWriters -Script $swWriter -ArgSets $swArgs.ToArray()
    $swW = @($sw.writers)
    $swRan = @($swW | Where-Object { $_.ran }).Count
    $swWhy = Get-CplWhy $swW
    $swReported = 0; $swRefused = 0; $swBuilt = 0; $swRegressed = 0
    foreach ($w in $swW) {
      if ([int]$w.n -le 6) {
        $swReported += [Math]::Max((Get-CplField $w 'MARKED'), 0)
        $swRegressed += [Math]::Max((Get-CplField $w 'REGRESSED'), 0)
      } else { $swBuilt += [Math]::Max((Get-CplField $w 'BUILT'), 0) }
      $swRefused += [Math]::Max((Get-CplField $w 'REFUSED'), 0)
    }
    $swDoc = ConvertFrom-Json ([IO.File]::ReadAllText($swFile))
    $swById = @{}
    foreach ($win in @($swDoc.windows)) { $swById[([string]$win.store + '|' + [string]$win.id)] = $win }
    $swMarked = 0; $swPruned = 0; $swLost = 0
    for ($k = 1; $k -le 6; $k++) {
      for ($n = 0; $n -lt 40; $n++) {
        $key = ($swStores[$k - 1] + '|sw-' + $k + '-' + $n)
        if (-not $swById.ContainsKey($key)) { $swPruned++ }
        elseif ([string]$swById[$key].repriced_for -eq '2026-08-21') { $swMarked++ }
        else { $swLost++ }
      }
    }
    $swFiller = 0
    for ($n = 0; $n -lt 300; $n++) { if ($swById.ContainsKey(("Sam's Club|filler-" + $n))) { $swFiller++ } }
    Write-Output ('  info  sale-windows barrier: {0} of 7 writers were at the barrier when released ({1} ms); build-sale-windows rewrote the file {2} time(s) while the lanes marked' -f $sw.ready_at_go, $sw.go_ms, $swBuilt)
    Test-CplCase 'PREMISE    every writer RAN - six lanes and a build-sale-windows, launched, at the barrier when released together, and exited' `
      ($swRan -eq 7 -and $swBuilt -ge 1) ("ran $swRan of 7; build-sale-windows rewrites=$swBuilt" + $swWhy)
    Test-CplCase 'MUST FIRE  no recorded re-price ever went back to owed under a sibling''s write - not at the end, and not for a moment in between' `
      ($swLost -eq 0 -and $swRegressed -eq 0 -and $swReported -eq 240) ("lanes reported $swReported of 240 marked; on disk at the end $swMarked still marked, $swPruned pruned as done, $swLost LOST back to owed; regressions seen mid-run=$swRegressed" + $swWhy)
    Test-CplCase 'MUST FIRE  and no mark was lost SILENTLY - no writer refused, so every count above is a real write' ($swRefused -eq 0) ("refusals=$swRefused" + $swWhy)
    Test-CplCase 'CLEAN TWIN all 300 windows nobody marked are still in the file' ($swFiller -eq 300) ("kept $swFiller of 300")

    # ---- 2. capture-cursor.json: six stores' cursors saved side by side ----
    # Each writer saves its own store 25 times and, before each save, reads what the file says about its key. Only that
    # writer ever writes that key, so the file must say what it last wrote; anything less is a sibling's whole-file
    # write putting the cursor BACK, and it is counted the moment it is seen. The store is passed as an INDEX, so no
    # store name with a space or an apostrophe has to survive a command line.
    $curRoot = Join-Path $cplDir 'cur'
    [void][IO.Directory]::CreateDirectory($curRoot)
    $curFile = Join-Path $curRoot 'capture-cursor.json'
    $curSeed = [ordered]@{}
    for ($n = 0; $n -lt 400; $n++) { $curSeed[('filler_' + $n)] = $n }
    [IO.File]::WriteAllText($curFile, ($curSeed | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($true)))
    $curStores = @('Family Fare', 'Walmart', "Sam's Club", 'Aldi', 'Fareway', "Baker's")
    $curWriter = Join-Path $cplDir 'cur-writer.ps1'
    Write-CplWriter $curWriter @'
param([string]$Lib, [string]$Dir, [int]$Index)
$ErrorActionPreference = 'Stop'
. $Lib
$store = @('Family Fare', 'Walmart', "Sam's Club", 'Aldi', 'Fareway', "Baker's")[$Index - 1]
$key = Get-CursorKey $store
$file = Join-Path $Dir 'capture-cursor.json'
$saved = 0; $refused = 0; $regressed = 0; $last = 0; $why = ''
for ($m = 1; $m -le 25; $m++) {
  # Read lock-free, the way the lanes read it, retried past the instant a sibling's replace is mid-move.
  $seen = $null
  for ($a = 0; $a -lt 400 -and $null -eq $seen; $a++) {
    try {
      $d = ConvertFrom-Json ([IO.File]::ReadAllText($file))
      if ($null -ne $d) { $seen = 0; if ($d.PSObject.Properties[$key]) { $seen = [int]$d.$key } }
    } catch { Start-Sleep -Milliseconds 5 }
  }
  if ($null -ne $seen -and $seen -lt $last) { $regressed++ }
  try { Save-CaptureCursor -Store $store -Next $m -OutDir $Dir; $last = $m; $saved++ } catch { $refused++; $why = $_.Exception.Message }
}
Write-Output ('SAVED=' + $saved)
Write-Output ('REFUSED=' + $refused)
Write-Output ('REGRESSED=' + $regressed)
if ($why) { Write-Output ('WHY ' + $why) }
exit 0
'@
    $curArgs = New-Object System.Collections.Generic.List[object]
    for ($i = 1; $i -le 6; $i++) { $curArgs.Add([string[]]@('-Lib', $cplLib, '-Dir', $curRoot, '-Index', [string]$i)) }
    $cur = Invoke-TcLedgerWriters -Script $curWriter -ArgSets $curArgs.ToArray()
    $curW = @($cur.writers)
    $curRan = @($curW | Where-Object { $_.ran }).Count
    $curWhy = Get-CplWhy $curW
    $curSaved = 0; $curRefused = 0; $curRegressed = 0
    foreach ($w in $curW) {
      $curSaved += [Math]::Max((Get-CplField $w 'SAVED'), 0)
      $curRefused += [Math]::Max((Get-CplField $w 'REFUSED'), 0)
      $curRegressed += [Math]::Max((Get-CplField $w 'REGRESSED'), 0)
    }
    $curDoc = ConvertFrom-Json ([IO.File]::ReadAllText($curFile))
    $curAtEnd = 0; $curEnds = @()
    foreach ($s in $curStores) {
      $ck = Get-CursorKey $s
      $cv = -1
      if ($curDoc.PSObject.Properties[$ck]) { $cv = [int]$curDoc.$ck }
      if ($cv -eq 25) { $curAtEnd++ }
      $curEnds += ('{0}={1}' -f $ck, $cv)
    }
    $curFiller = 0
    for ($n = 0; $n -lt 400; $n++) { $fp = $curDoc.PSObject.Properties[('filler_' + $n)]; if ($fp -and [int]$fp.Value -eq $n) { $curFiller++ } }
    Write-Output ('  info  capture-cursor barrier: {0} of 6 writers were at the barrier when released ({1} ms)' -f $cur.ready_at_go, $cur.go_ms)
    Test-CplCase 'PREMISE    every cursor writer RAN - launched, at the barrier when the six were released together, exited - and made all 25 saves' `
      ($curRan -eq 6 -and $curSaved -eq 150) ("ran $curRan of 6; saves=$curSaved of 150" + $curWhy)
    Test-CplCase 'MUST FIRE  no store''s cursor ever went BACKWARDS under a sibling''s whole-file write, and every one ends where its writer left it' `
      ($curRegressed -eq 0 -and $curAtEnd -eq 6) ("regressions seen=$curRegressed; ended at 25: $curAtEnd of 6 (" + ($curEnds -join ' ') + ')' + $curWhy)
    Test-CplCase 'MUST FIRE  and no save was refused, so every count above is a real write' ($curRefused -eq 0) ("refusals=$curRefused" + $curWhy)
    Test-CplCase 'CLEAN TWIN all 400 other keys in the cursor file still hold their values' ($curFiller -eq 400) ("kept $curFiller of 400")

    # ---- 3. Step-CaptureCursor: four runs of ONE store's builder advancing on the same day ----
    # The one-slice-per-day guard reads <store>_last before it saves, so it only holds if the read and the save are one
    # locked step. Uses TODAY'S REAL DATE because the replay guard refuses any other; a run that straddles midnight sees
    # every writer refused and goes red rather than passing.
    $stRoot = Join-Path $cplDir 'step'
    [void][IO.Directory]::CreateDirectory($stRoot)
    $stTerms = [ordered]@{}
    for ($n = 0; $n -lt 180; $n++) { $stTerms[('c' + $n.ToString('000'))] = ('term ' + $n) }
    [IO.File]::WriteAllText((Join-Path $stRoot 'commodity-search.json'), (@{ terms = $stTerms } | ConvertTo-Json -Depth 4))
    $stToday = (Get-Date).ToString('yyyy-MM-dd')
    $stWriter = Join-Path $cplDir 'step-writer.ps1'
    Write-CplWriter $stWriter @'
param([string]$Lib, [string]$Root, [string]$Today)
$ErrorActionPreference = 'Stop'
. $Lib
$script:PolicyRoot = $Root
try {
  $r = Step-CaptureCursor -Store 'Walmart' -Today $Today -OutDir $Root -Landed $true
  Write-Output ('ADVANCED=' + [int][bool]$r.Advanced)
  Write-Output 'REFUSED=0'
  Write-Output ('REASON ' + $r.Reason)
} catch {
  Write-Output 'ADVANCED=0'
  Write-Output 'REFUSED=1'
  Write-Output ('WHY ' + $_.Exception.Message)
}
exit 0
'@
    $stArgs = New-Object System.Collections.Generic.List[object]
    for ($i = 1; $i -le 4; $i++) { $stArgs.Add([string[]]@('-Lib', $cplLib, '-Root', $stRoot, '-Today', $stToday)) }
    $st = Invoke-TcLedgerWriters -Script $stWriter -ArgSets $stArgs.ToArray()
    $stW = @($st.writers)
    $stRan = @($stW | Where-Object { $_.ran }).Count
    $stWhy = Get-CplWhy $stW
    $stAdvanced = 0; $stRefused = 0
    foreach ($w in $stW) {
      if ((Get-CplField $w 'ADVANCED') -eq 1) { $stAdvanced++ }
      $stRefused += [Math]::Max((Get-CplField $w 'REFUSED'), 0)
    }
    $stCursor = -1
    $stCurFile = Join-Path $stRoot 'capture-cursor.json'
    if (Test-Path -LiteralPath $stCurFile) { $stDoc = ConvertFrom-Json ([IO.File]::ReadAllText($stCurFile)); if ($stDoc.PSObject.Properties['Walmart']) { $stCursor = [int]$stDoc.Walmart } }
    $stLog = 0
    $stLogFile = Join-Path $stRoot 'capture-cursor-log.jsonl'
    if (Test-Path -LiteralPath $stLogFile) { foreach ($line in [IO.File]::ReadAllLines($stLogFile)) { if ($line.Trim()) { $stLog++ } } }
    Write-Output ('  info  step barrier: {0} of 4 writers were at the barrier when released ({1} ms)' -f $st.ready_at_go, $st.go_ms)
    Test-CplCase 'PREMISE    every run of the store''s builder RAN - launched, at the barrier when the four were released together, and exited' ($stRan -eq 4) ("ran $stRan of 4" + $stWhy)
    Test-CplCase 'MUST FIRE  exactly ONE of four same-day advances moves the cursor and logs it - the one-slice-per-day guard holds under a race' `
      ($stAdvanced -eq 1 -and $stRefused -eq 0 -and $stCursor -eq 2 -and $stLog -eq 1) ("advanced=$stAdvanced of 4, cursor=$stCursor (want 2), log lines=$stLog (want 1), refusals=$stRefused" + $stWhy)
  } catch {
    Test-CplCase 'the self-test ran to its end with no unexpected error' $false ($_.Exception.Message + ' (line ' + $_.InvocationInfo.ScriptLineNumber + ')')
  } finally {
    $ErrorActionPreference = 'Continue'
    Remove-Item -LiteralPath $cplDir -Recurse -Force -ErrorAction SilentlyContinue
  }
  Write-Output ('capture-policy-lib SELF-TEST {0} ({1} of {2} failed)' -f $(if ($script:cplBad) { 'FAIL' } else { 'PASS' }), $script:cplBad, $script:cplN)
  Write-Output ('CAPTURE-POLICY-LIB-COMPLETE cases={0} failed={1}' -f $script:cplN, $script:cplBad)
  if ($script:cplBad -gt 0) { exit 1 }
  exit 0
}

# ---------------------------------------------------------------------------


