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
param([switch]$Report, [switch]$Emit, [string]$Store = '', [string]$Today = '', [string]$OutDir = '')

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
  $sale = New-Object System.Collections.Generic.List[object]
  foreach ($id in $plan.SaleExpiries) {
    $hit = $all | Where-Object { $_.id -eq $id } | Select-Object -First 1
    if ($hit) { [void]$sale.Add($hit) }
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

function Save-CaptureCursor {
  <# Advance a store's cursor. Call ONLY after the capture landed. #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Store, [Parameter(Mandatory)][int]$Next, [string]$OutDir = '')
  if (-not $OutDir) { $OutDir = Join-Path $script:PolicyRoot 'out' }
  $p = Join-Path $OutDir $script:CursorFile
  $cur = Get-CaptureCursors $OutDir
  $h = @{}
  foreach ($pr in $cur.PSObject.Properties) { $h[$pr.Name] = $pr.Value }
  $h[($Store -replace '[^A-Za-z0-9]', '')] = $Next
  $h['updated'] = (Get-Date).ToString('s')
  Set-Content -Path $p -Value ($h | ConvertTo-Json -Depth 4) -Encoding UTF8
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
$script:AllStores = @('Hy-Vee', 'Aldi', "Baker's", 'Family Fare', 'Fareway', 'Walmart', "Sam's Club")

if ($Emit) {
  # Emit today's worklist for every store. The three walled stores (Walmart, Sam's,
  # Fareway) have no other way to be told what to fetch - their capture happens in a
  # real logged-in Chrome, so a file is the only handoff that works.
  foreach ($s in $script:AllStores) {
    $f = Write-CaptureWorklist -Store $s -Today $Today -OutDir $OutDir
    $wl = Get-CaptureWorklist -Store $s -Today $Today -OutDir $OutDir
    Write-Output ("{0,-13} {1,3} term(s)  ad_rollover={2,-5}  -> {3}" -f $s, @($wl.Terms).Count, $wl.AdRollover, (Split-Path $f -Leaf))
  }
  return
}

if ($Report -or $Store) {
  $stores = if ($Store) { @($Store) } else { $script:AllStores }
  Write-Output ("capture policy: quarter=$script:QuarterDays d, max-carry=$script:MaxCarryDays d")
  Write-Output ''
  foreach ($s in $stores) {
    $p = Get-CapturePlan -Store $s -Today $Today
    Write-Output ("{0,-13} rotation {1,3} term(s)/day  + {2,2} sale expiry  = budget {3,3}   ad: {4}" -f `
        $p.Store, $p.RotationTerms, $p.SaleExpiries.Count, $p.TermBudget, $p.AdNote)
    if ($p.SaleExpiries.Count) {
      Write-Output ("               sales reverting today: " + (($p.SaleExpiries | Select-Object -First 8) -join ', '))
    }
  }
}
