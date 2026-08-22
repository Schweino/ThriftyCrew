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

# The quarter. Change it HERE and nowhere else; MaxCarryDays must move with it.
$script:QuarterDays = 90

# Rows carried longer than this expire. It MUST be >= QuarterDays or a term's rows die
# before the rotation comes back to them - at 90-day rotation with a 14-day carry, ~85%
# of the catalog would starve. The pulls read this so the two can never disagree.
$script:MaxCarryDays = 90

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
  # THE COUPLING THAT BOUNDS THIS LIST (documented 2026-08-22). build-sale-windows.ps1
  # keeps an entry only while refresh_on >= today ("Prune only once refresh_on is in the
  # past") and prunes it the day AFTER refresh_on. So an id appears here on exactly ONE
  # day - refresh_on itself, the day after the window ends - and is gone the next. That
  # is what keeps SaleExpiries from growing without bound, and it is also why a lane that
  # skips its expiry slice on that day never gets a second chance from this list: the
  # re-price is owed on the day the sale drops off, not "sometime after". Brad's rule:
  # "reprice whenever an ad price / sale price / rollback price / instant-savings price
  # drops off." The two halves - the builder's prune and this consumer's >= test - must
  # stay aligned; widen one without the other and expiries are either missed or repeated.
  $expiries = New-Object System.Collections.Generic.List[string]
  $sw = Get-PolicyJson 'sale-windows.json'
  if ($sw -and $sw.windows) {
    foreach ($w in $sw.windows) {
      if ([string]$w.store -ne $Store) { continue }
      $ro = [string]$w.refresh_on
      if (-not $ro) { continue }
      try {
        $roD = [datetime]::ParseExact($ro, 'yyyy-MM-dd', $null)
        if ($todayD -ge $roD) { [void]$expiries.Add([string]$w.id) }
      } catch { }
    }
  }

  # --- 3. quarterly rotation ------------------------------------------------
  $terms = Get-StoreTermCount $Store
  $rotation = [int][math]::Ceiling($terms / [double]$script:QuarterDays)
  if ($rotation -lt 1 -and $terms -gt 0) { $rotation = 1 }

  return [pscustomobject]@{
    Store         = $Store
    Today         = $todayS
    AdRollover    = $adRollover
    AdNote        = $adNote
    SaleExpiries  = $expiries.ToArray()
    TermCount     = $terms
    RotationTerms = $rotation
    QuarterDays   = $script:QuarterDays
    MaxCarryDays  = $script:MaxCarryDays
    # What the pull should actually ask for today: the daily drip plus any expiring
    # sales. An ad rollover is a separate pull (the ad feed), not extra search terms.
    TermBudget    = $rotation + $expiries.Count
  }
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
    # Dedupe on the TERM STRING. Select-Object -Unique on PSCustomObjects compares
    # their ToString(), which is identical for every one of them, so it silently
    # collapsed a 13-term worklist to a single entry - a store would then be told to
    # fetch one term a day and the rotation would never complete.
    Terms         = @(@($rot.ToArray()) + @($sale.ToArray()) |
                      Group-Object -Property term | ForEach-Object { $_.Group[0] })
    QuarterDays   = $plan.QuarterDays
    MaxCarryDays  = $plan.MaxCarryDays
  }
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

    .PARAMETER Items     the lane's full worklist in rotation order (terms, or products)
    .PARAMETER Expiring  keys of the items whose sale ended (commodity ids, or terms)
    .PARAMETER KeyOf     scriptblock: item -> the key(s) it answers to (string or string[])
    .PARAMETER Budget    total items to take today; <= 0 means unbudgeted (all, expiries first)
    .PARAMETER CursorStart  where the rotation starts in Items
    .OUTPUTS  @{ Items; Prepended; FromRotation; CursorNext }
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
  $exp = @{}; foreach ($k in @($Expiring)) { if ($k) { $exp[[string]$k] = $true } }
  $taken = New-Object System.Collections.Generic.List[object]
  $seen = New-Object 'System.Collections.Generic.HashSet[int]'
  $prepended = 0
  if ($exp.Count -gt 0) {
    for ($i = 0; $i -lt $n; $i++) {
      $keys = @(& $KeyOf $all[$i])
      $hit = $false
      foreach ($k in $keys) { if ($k -and $exp.ContainsKey([string]$k)) { $hit = $true; break } }
      if ($hit) { [void]$taken.Add($all[$i]); [void]$seen.Add($i); $prepended++ }
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
    Items        = $taken.ToArray()
    Prepended    = $prepended
    FromRotation = ($taken.Count - $prepended)
    CursorNext   = if ($n -gt 0) { (($CursorStart + $walked) % $n) } else { 0 }
  }
}

# ---------------------------------------------------------------------------
# WHICH STORES THE TERM CURSOR ACTUALLY GOVERNS (2026-08-21)
#
# Not all seven rotate through commodity-search terms, and pretending they do
# would be worse than not rotating at all - an audit would read a cursor that
# means nothing. Three different shapes, named rather than blurred:
#
#   TERM ROTATION  Family Fare, Walmart, Sam's Club, Aldi, Fareway
#                  A slice of commodity-search.json per day. This cursor.
#   PRODUCT ROTATION  Hy-Vee. Its lane re-verifies by product id, not by search
#                  term, so its cursor indexes a different list entirely and
#                  lives in hyvee-rotation-cursor.json. Folding it in here would
#                  narrow a namespace: the same integer would mean two things.
#   COMPREHENSIVE  Baker's. The Kroger API pull returns the whole catalog in one
#                  pass (7,281 rows on 2026-08-21), so there is nothing to
#                  rotate and no cursor to keep.
#
# Ask this before advancing anything. A store that is not TERM ROTATION must not
# get a term cursor written for it.
$script:TermRotationStores = @('Family Fare', 'Walmart', "Sam's Club", 'Aldi', 'Fareway')

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
           "commodity-search terms (see TermRotationStores). Hy-Vee rotates by product id " +
           "and Baker's pulls comprehensively; giving either a term cursor would make the " +
           'same integer mean two different things.')
  }
  $p = Join-Path $OutDir $script:CursorFile
  $cur = Get-CaptureCursors $OutDir
  $h = @{}
  foreach ($pr in $cur.PSObject.Properties) { $h[$pr.Name] = $pr.Value }
  $h[(Get-CursorKey $Store)] = $Next
  # The date this store last moved. Step-CaptureCursor reads it to enforce one slice per day,
  # so a builder that runs twice does not rotate twice.
  if ($AdvancedOn) { $h[((Get-CursorKey $Store) + '_last')] = $AdvancedOn }
  $h['updated'] = (Get-Date).ToString('s')
  $h['note'] = 'index into the commodity-search term order where each TERM-ROTATION store starts next. Advanced only after that store''s capture landed. Hy-Vee (product ids) and Baker''s (comprehensive) are deliberately absent.'
  $tmp = "$p.tmp"
  Set-Content -Path $tmp -Value ($h | ConvertTo-Json -Depth 4) -Encoding UTF8
  Move-Item -LiteralPath $tmp -Destination $p -Force
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
  try {
    $sj = Get-PolicyJson 'stores.json'
    foreach ($s in $sj.stores) { if ([string]$s.name -eq $Store) { $prefix = [string]$s.regular_prefix; break } }
  } catch { }
  if (-not $prefix) { return $false }

  $f = Join-Path $OutDir ("regular\{0}-regular-{1}.json" -f $prefix, $todayS)
  if (-not (Test-Path $f)) { return $false }
  try {
    $doc = ConvertFrom-Json ([IO.File]::ReadAllText($f))
    $rows = if ($doc.deals) { @($doc.deals) } else { @($doc) }
    return (@($rows).Count -gt 0)
  } catch { return $false }
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
      Reason = "not a term-rotation store (Hy-Vee rotates by product id; Baker's pulls comprehensively)" }
  }

  $did = if ($null -ne $Landed) { [bool]$Landed } else { Test-CaptureLanded -Store $Store -Today $todayS -OutDir $OutDir }
  $from = Get-CaptureCursor -Store $Store -OutDir $OutDir

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
    terms          = @($wl.Terms | ForEach-Object { $_.term })
    commodities    = @($wl.Terms | ForEach-Object { $_.id })
    note           = 'Fetch ONLY these terms today. Advance the cursor with Save-CaptureCursor AFTER the capture lands - a run that fetched nothing must re-attempt this slice tomorrow, never skip it.'
  }
  Set-Content -Path $file -Value ($doc | ConvertTo-Json -Depth 5) -Encoding UTF8
  return $file
}

# ---------------------------------------------------------------------------


