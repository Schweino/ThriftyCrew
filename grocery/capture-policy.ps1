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
param([switch]$Report, [string]$Store = '', [string]$Today = '')

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
if ($Report -or $Store) {
  $stores = if ($Store) { @($Store) } else {
    @('Hy-Vee', 'Aldi', "Baker's", 'Family Fare', 'Fareway', 'Walmart', "Sam's Club")
  }
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
