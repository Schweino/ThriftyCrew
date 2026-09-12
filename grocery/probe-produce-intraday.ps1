<#
  probe-produce-intraday.ps1 - does a US chain's ONLINE produce price move between morning and
  afternoon on the same day? Backlog I125, on Brad's ruling of 2026-09-12:

      "Yes, produce is compared store to store on the board, so this is worth the one hour. Run the
       cheap test once: one produce commodity at one chain store, priced online morning and afternoon
       on the same day, repeated on two days. If no price moves, record that US chain online produce
       prices here do not move intraday and close it. If any move, every capture starts recording its
       capture time (hour and timezone) alongside asof, and nothing else changes until that data
       shows a pattern."

  WHY THE QUESTION MATTERS. Every capture this estate takes lands in one morning window (08:00-12:00
  on every file in grocery\out\regular\), and the whole vocabulary for row freshness is DAYS - asof,
  audit-row-age.ps1. If a chain marked produce down during the day the way a market stall does, then
  a board that compares seven stores captured hours apart would be comparing different prices for the
  same afternoon, and no field we store could ever say so.

  WHY IT IS A PROBE AND NOT A GATE. It answers one question once. Nothing calls it from code, and
  grocery\audit-script-census.ps1 carries the entry that records that. When the verdict is read, this
  file, its panel and its census entry all go.

  THE SCHEDULING LANDS IN A SECOND COMMIT, and the order is the point. A bounded Windows task runs
  this six times over two days, and its definition names this script by absolute path in the MAIN
  checkout. ops\audit-run-log-claims.ps1 checks that a hidden task's target actually exists, so the
  definition cannot land until this file is there: the POINTED-TO object is written before the object
  that points to it (.claude\rules\ops-and-gates.md). Landing them together would mean a task
  definition naming a script no checkout held.

  THE ACCEPTANCE BAR, WRITTEN BEFORE THE FIRST READING (backlog E21). It is stated here, in
  grocery\produce-intraday-panel.json, and in design\MEASURE-produce-intraday-2026-09-12.md, and the
  three must agree - a threshold chosen after seeing the number is not a threshold:

      A deciding PAIR is one product, one date, its morning price against its afternoon price, both
      read ok. A MOVE is a difference of at least $0.01. 30 pairs are planned (15 products x 2 days).
        moves == 0 and pairs >= 24  ->  CLOSE   (no intraday movement; change no capture schema)
        moves >= 1                  ->  OPEN    (captures start recording hour + timezone)
        anything else               ->  BLIND   (a could-not-look must not settle the question)

      A day-to-day or morning-to-morning difference is NOT a move here. That is the ad cycle, which
      asof already handles, and counting it would answer a different question with a right number.

  WHAT A CLEAN RESULT WOULD MEAN. This is one chain, one store, fifteen products, two days, and two
  windows. A CLOSE says those prices did not move between morning and afternoon on those days. It
  cannot say a different banner does not, and it cannot say nothing moves after the last reading of
  the day - which is why an evening reading is taken as well and reported SEPARATELY, outside the
  verdict arithmetic the ruling specifies.

  THE PRICE READ IS THE ONE THE BOARD PUBLISHES: promo when the store has a live promo, else regular,
  the same rule as pull-regular-bakers-api.ps1. Products are pinned by productId, so a change in
  Kroger's search ranking can never be read as a change in price.

  Modes:
    -Read        take one reading of the whole panel and append one row per product to the ledger
    -Verdict     score the ledger against the bar above and write the verdict file
    -SelfTest    hermetic; no network, no ledger, no scheduler

  Exit codes: 0 fine, 1 a reading or the scoring failed, 3 could not evaluate (no credentials, no
  panel, nothing read yet). 3 is never a pass and never a CLOSE.
#>
param(
  [switch]$Read,
  [switch]$Verdict,
  [switch]$SelfTest,
  [string]$PanelPath = '',
  [string]$LedgerPath = '',
  [string]$VerdictPath = ''
)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path -Parent $here
. (Join-Path $repo 'lib\append-line.ps1')
. (Join-Path $repo 'lib\lf-write.ps1')
. (Join-Path $here 'native-lib.ps1')
. (Join-Path $here 'run-log-lib.ps1')

function Get-PiPanelPath { param([string]$Given) if ($Given) { return $Given } return (Join-Path $here 'produce-intraday-panel.json') }
function Get-PiLedgerPath { param([string]$Given) if ($Given) { return $Given } return (Join-Path $here 'out\produce-intraday.jsonl') }
function Get-PiVerdictPath { param([string]$Given) if ($Given) { return $Given } return (Join-Path $here 'out\produce-intraday-verdict.json') }

function Get-PiWindow {
  <# The window a reading BELONGS TO, read from the hour it actually happened at. The task runs with
     StartWhenAvailable, so a box asleep at 08:30 produces a reading at noon; calling that "morning"
     because a morning trigger owned it would manufacture a deciding pair out of two afternoon
     prices, which is the one error this measurement cannot afford. Pure. #>
  param([Parameter(Mandatory=$true)][int]$Hour)
  if ($Hour -lt 12) { return 'morning' }
  if ($Hour -lt 18) { return 'afternoon' }
  return 'evening'
}

function Get-PiPublishedPrice {
  <# What the store charges today: promo when one is live, else regular. $null when neither is a
     usable number - and $null is a could-not-look, never a zero. Pure. #>
  param($Regular, $Promo)
  $p = 0.0; $r = 0.0
  $hasP = ($null -ne $Promo) -and ([string]$Promo -ne '') -and ([double]::TryParse([string]$Promo, [ref]$p)) -and ($p -gt 0)
  if ($hasP) { return [math]::Round($p, 2) }
  $hasR = ($null -ne $Regular) -and ([string]$Regular -ne '') -and ([double]::TryParse([string]$Regular, [ref]$r)) -and ($r -gt 0)
  if ($hasR) { return [math]::Round($r, 2) }
  return $null
}

function Get-PiPairs {
  <# Every (date, commodity) that has BOTH windows read ok, as one row per pair. One row per case per
     arm (backlog E24): the totals below are derived from this list and never accumulated, so the
     paired comparison stays available to whoever reads it next. Pure over its arguments. #>
  param(
    [Parameter(Mandatory=$true)]$Rows,
    [Parameter(Mandatory=$true)][string]$WindowA,
    [Parameter(Mandatory=$true)][string]$WindowB,
    [double]$Threshold = 0.01
  )
  $byKey = @{}
  foreach ($r in @($Rows)) {
    if (-not $r) { continue }
    if ([string]$r.status -ne 'ok') { continue }
    if ($null -eq $r.published) { continue }
    # THE WINDOW IS THE SLOT, and that is the ONLY thing keeping an evening price out of a
    # morning-vs-afternoon pair. There was a `$w -ne $WindowA -and $w -ne $WindowB -> continue` filter
    # here as well; a mutation probe removed it and killed NOTHING, because a row filed under 'evening'
    # can never satisfy the two-slot test below. Two guards over one rule make the fixture insensitive
    # (.claude\rules\ops-and-gates.md), so the redundant one is gone rather than left looking load-bearing.
    $w = [string]$r.window
    $k = ([string]$r.date) + '|' + ([string]$r.commodity)
    if (-not $byKey.ContainsKey($k)) { $byKey[$k] = @{} }
    # A second reading in the same window on the same day would be a repeat, not a pair. Keep the
    # first: it is the one the plan asked for, and the later one is catch-up after a missed trigger.
    if (-not $byKey[$k].ContainsKey($w)) { $byKey[$k][$w] = $r }
  }
  $pairs = @()
  foreach ($k in ($byKey.Keys | Sort-Object)) {
    $slot = $byKey[$k]
    if (-not ($slot.ContainsKey($WindowA) -and $slot.ContainsKey($WindowB))) { continue }
    $a = $slot[$WindowA]; $b = $slot[$WindowB]
    # COMPARE THE RAW DIFFERENCE, ROUND ONLY FOR DISPLAY. Rounding first inflates a sub-threshold
    # difference INTO one: [math]::Round(0.005, 2) is 0.01 here, because the binary double nearest
    # 0.005 sits just above it, so a half-cent scored as a move and the fixture below caught it. The
    # epsilon is the other direction - 0.56 minus 0.55 is 0.009999999999999953 in binary double, and
    # a bare -ge 0.01 would read a real one-cent move as no move at all. Both cases are pinned below.
    $raw = [double]$b.published - [double]$a.published
    $delta = [math]::Round($raw, 2)
    $pairs += [pscustomobject]@{
      date      = [string]$a.date
      commodity = [string]$a.commodity
      kind      = [string]$a.kind
      a_window  = $WindowA
      b_window  = $WindowB
      a_hour    = [int]$a.hour
      b_hour    = [int]$b.hour
      a_price   = [double]$a.published
      b_price   = [double]$b.published
      delta     = $delta
      moved     = ([math]::Abs($raw) -ge ($Threshold - 1e-9))
    }
  }
  return ,$pairs
}

function Get-PiVerdict {
  <# Scores the ledger against the bar in the panel. Pure over its arguments so the fixtures below
     drive it rather than a live ledger. Returns the object that is written to the verdict file. #>
  param(
    [Parameter(Mandatory=$true)]$Rows,
    [Parameter(Mandatory=$true)]$Panel
  )
  $bar       = $Panel.bar
  $threshold = [double]$bar.move_threshold_usd
  $minPairs  = [int]$bar.min_pairs_for_a_verdict
  $planned   = [int]$bar.deciding_pairs_planned
  $winA      = [string]@($Panel.plan.deciding_windows)[0]
  $winB      = [string]@($Panel.plan.deciding_windows)[1]

  $deciding = Get-PiPairs -Rows $Rows -WindowA $winA -WindowB $winB -Threshold $threshold
  $moved    = @($deciding | Where-Object { $_.moved })
  $supp     = Get-PiPairs -Rows $Rows -WindowA $winB -WindowB 'evening' -Threshold $threshold
  $suppMoved = @($supp | Where-Object { $_.moved })

  $unreadable = @()
  foreach ($r in @($Rows)) {
    if (-not $r) { continue }
    if ([string]$r.status -ne 'ok' -or $null -eq $r.published) {
      $unreadable += ("{0} {1} {2}: {3}" -f [string]$r.date, [string]$r.window, [string]$r.commodity, [string]$r.status)
    }
  }

  $v = 'BLIND'
  if (@($moved).Count -ge 1) { $v = 'OPEN' }
  elseif (@($deciding).Count -ge $minPairs) { $v = 'CLOSE' }

  $dates = @(@($Rows) | Where-Object { $_ } | ForEach-Object { [string]$_.date } | Sort-Object -Unique)
  $comms = @(@($Rows) | Where-Object { $_ } | ForEach-Object { [string]$_.commodity } | Sort-Object -Unique)

  $means = "COULD NOT EVALUATE. Fewer than $minPairs readable morning-vs-afternoon pairs. This is not a CLOSE: a could-not-look must not settle the question. Read unreadable_detail and re-run the readings."
  if ($v -eq 'CLOSE') { $means = 'No intraday movement found. Record that US chain online produce prices here do not move intraday, close I125, change no capture schema.' }
  if ($v -eq 'OPEN')  { $means = 'At least one price moved between morning and afternoon. Every capture starts recording its capture time (hour and timezone) alongside asof, and nothing else changes until that data shows a pattern.' }

  return [pscustomobject]@{
    item              = 'I125'
    verdict           = $v
    moved             = @($moved).Count
    pairs             = @($deciding).Count
    pairs_planned     = $planned
    min_pairs         = $minPairs
    threshold_usd     = $threshold
    products          = @($comms).Count
    dates             = $dates
    rows_read         = @(@($Rows) | Where-Object { $_ }).Count
    unreadable        = @($unreadable).Count
    unreadable_detail = $unreadable
    deciding_pairs    = $deciding
    supplementary     = [pscustomobject]@{
      note   = 'afternoon against evening. Recorded because it is nearly free and a late markdown is the likeliest shape; DELIBERATELY OUTSIDE the verdict, which is the morning-against-afternoon test the ruling specifies.'
      pairs  = @($supp).Count
      moved  = @($suppMoved).Count
      detail = $supp
    }
    means             = $means
  }
}

function Write-PiVerdictLines {
  <# The verdict as text. A rate prints with its DENOMINATOR, always (backlog E20). #>
  param([Parameter(Mandatory=$true)]$V)
  $out = @()
  $out += ("produce-intraday VERDICT: {0} - {1}" -f $V.verdict, $V.means)
  $out += ("  deciding: {0} price move(s) of at least `${1} over {2} morning-vs-afternoon pair(s) (planned {3}, bar {4}), {5} product(s) across {6} day(s)" -f `
            $V.moved, $V.threshold_usd, $V.pairs, $V.pairs_planned, $V.min_pairs, $V.products, @($V.dates).Count)
  $out += ("  supplementary (NOT in the verdict): {0} move(s) over {1} afternoon-vs-evening pair(s)" -f $V.supplementary.moved, $V.supplementary.pairs)
  $out += ("  rows read {0}, unreadable {1}" -f $V.rows_read, $V.unreadable)
  foreach ($u in @($V.unreadable_detail)) { $out += ("    could not look: " + $u) }
  foreach ($p in @($V.deciding_pairs | Where-Object { $_.moved })) {
    $out += ("    MOVED {0} {1}: {2} at {3}h -> {4} at {5}h (delta {6})" -f $p.date, $p.commodity, $p.a_price, $p.a_hour, $p.b_price, $p.b_hour, $p.delta)
  }
  return ,$out
}

function Read-PiLedger {
  param([Parameter(Mandatory=$true)][string]$Path)
  $rows = @()
  if (-not (Test-Path -LiteralPath $Path)) { return ,$rows }
  foreach ($line in [IO.File]::ReadAllLines($Path)) {
    $t = [string]$line
    if (-not $t.Trim()) { continue }
    $rows += ($t | ConvertFrom-Json)
  }
  return ,$rows
}

function Get-PiHarnessCommit {
  <# Which commit the harness ran at (measurement.md: name the harness AND the commit). Through
     Invoke-Native because under EAP=Stop a native child's first stderr line is a terminating throw. #>
  $r = Invoke-Native 'git' '-C' $repo 'rev-parse' 'HEAD'
  if ($r.ExitCode -ne 0) { return 'unknown' }
  return ([string]@($r.Output)[0]).Trim()
}

# ---------------------------------------------------------------------------- self-test
if ($SelfTest) {
  $fails = 0
  $cases = 0
  $scratch = Join-Path $env:TEMP ('pi-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  function Assert-PiCase {
    param([string]$Label, [scriptblock]$Body)
    $script:cases++
    try {
      # A case body's OUTPUT joins its return value (the estate's ps-callback-output-joins-the-return
      # trap), so a body that ever printed would make `if ($ok)` true on an array. Take the last value.
      $emitted = @(& $Body)
      $ok = if (@($emitted).Count -gt 0) { [bool]$emitted[-1] } else { $false }
      if ($ok) { Write-Output ("  ok   " + $Label) } else { Write-Output ("  FAIL " + $Label); $script:fails++ }
    } catch {
      Write-Output ("  FAIL " + $Label + " :: " + $_.Exception.Message); $script:fails++
    }
  }
  function New-PiRow {
    param([string]$Date, [string]$Window, [int]$Hour, [string]$Commodity, $Published, [string]$Status = 'ok', [string]$Kind = 'perishable')
    return [pscustomobject]@{ date = $Date; window = $Window; hour = $Hour; commodity = $Commodity; kind = $Kind; published = $Published; status = $Status }
  }
  # The panel the fixtures score against: the SHIPPED bar, so a change to the bar that the fixtures
  # were not updated for goes red here rather than silently rescoring the live measurement.
  $fixPanel = (Get-Content -LiteralPath (Get-PiPanelPath '') -Raw -Encoding UTF8 | ConvertFrom-Json)

  try {
    New-Item -ItemType Directory -Path $scratch -ErrorAction Stop | Out-Null

    Assert-PiCase 'window: an hour before noon is morning, 12 to 17 is afternoon, 18 and later is evening' {
      (Get-PiWindow 0) -eq 'morning' -and (Get-PiWindow 8) -eq 'morning' -and (Get-PiWindow 11) -eq 'morning' -and `
      (Get-PiWindow 12) -eq 'afternoon' -and (Get-PiWindow 15) -eq 'afternoon' -and (Get-PiWindow 17) -eq 'afternoon' -and `
      (Get-PiWindow 18) -eq 'evening' -and (Get-PiWindow 23) -eq 'evening'
    }
    Assert-PiCase 'price: a live promo is what the store charges today, and it beats the regular price' {
      (Get-PiPublishedPrice 3.29 2.50) -eq 2.50
    }
    Assert-PiCase 'price: no promo means the regular price' {
      (Get-PiPublishedPrice 3.29 $null) -eq 3.29 -and (Get-PiPublishedPrice 3.29 '') -eq 3.29
    }
    Assert-PiCase 'price: MUST NOT FIRE - neither number usable is a could-not-look, never a zero' {
      $null -eq (Get-PiPublishedPrice $null $null) -and $null -eq (Get-PiPublishedPrice 0 0)
    }

    # A full clean plan: 15 products, 2 days, both deciding windows, nothing moving.
    $flat = @()
    $comms = @(@($fixPanel.products) | ForEach-Object { [string]$_.commodity })
    foreach ($d in @('2026-09-13', '2026-09-14')) {
      foreach ($c in $comms) {
        $flat += (New-PiRow -Date $d -Window 'morning'   -Hour 8  -Commodity $c -Published 2.50)
        $flat += (New-PiRow -Date $d -Window 'afternoon' -Hour 15 -Commodity $c -Published 2.50)
      }
    }
    Assert-PiCase 'MUST NOT FIRE: a full plan with every price identical scores 0 moves over 30 pairs and CLOSES' {
      $v = Get-PiVerdict -Rows $flat -Panel $fixPanel
      $v.verdict -eq 'CLOSE' -and $v.moved -eq 0 -and $v.pairs -eq 30
    }
    Assert-PiCase 'MUST FIRE: one afternoon price 30 cents off its morning price is a move, and the verdict OPENS' {
      $rows = @($flat | ForEach-Object { $_ })
      $rows += (New-PiRow -Date '2026-09-15' -Window 'morning'   -Hour 8  -Commodity 'strawberries' -Published 3.99)
      $rows += (New-PiRow -Date '2026-09-15' -Window 'afternoon' -Hour 15 -Commodity 'strawberries' -Published 3.69)
      $v = Get-PiVerdict -Rows $rows -Panel $fixPanel
      $v.verdict -eq 'OPEN' -and $v.moved -eq 1
    }
    Assert-PiCase 'MUST NOT FIRE: half a cent is not a move at a one-cent bar' {
      $rows = @()
      $rows += (New-PiRow -Date '2026-09-13' -Window 'morning'   -Hour 8  -Commodity 'bananas' -Published 0.550)
      $rows += (New-PiRow -Date '2026-09-13' -Window 'afternoon' -Hour 15 -Commodity 'bananas' -Published 0.555)
      $p = Get-PiPairs -Rows $rows -WindowA 'morning' -WindowB 'afternoon'
      @($p).Count -eq 1 -and -not @($p)[0].moved
    }
    Assert-PiCase 'CLEAN TWIN: an exact one-cent move IS a move, which binary doubles nearly hide' {
      $rows = @()
      $rows += (New-PiRow -Date '2026-09-13' -Window 'morning'   -Hour 8  -Commodity 'bananas' -Published 0.55)
      $rows += (New-PiRow -Date '2026-09-13' -Window 'afternoon' -Hour 15 -Commodity 'bananas' -Published 0.56)
      $p = Get-PiPairs -Rows $rows -WindowA 'morning' -WindowB 'afternoon'
      @($p).Count -eq 1 -and @($p)[0].moved -and @($p)[0].delta -eq 0.01
    }
    Assert-PiCase 'MUST FIRE: a day-to-day difference is the ad cycle, not an intraday move, and scores 0' {
      $rows = @()
      $rows += (New-PiRow -Date '2026-09-13' -Window 'morning'   -Hour 8  -Commodity 'asparagus' -Published 3.69)
      $rows += (New-PiRow -Date '2026-09-13' -Window 'afternoon' -Hour 15 -Commodity 'asparagus' -Published 3.69)
      $rows += (New-PiRow -Date '2026-09-14' -Window 'morning'   -Hour 8  -Commodity 'asparagus' -Published 2.99)
      $rows += (New-PiRow -Date '2026-09-14' -Window 'afternoon' -Hour 15 -Commodity 'asparagus' -Published 2.99)
      $p = Get-PiPairs -Rows $rows -WindowA 'morning' -WindowB 'afternoon'
      $movedP = @($p | Where-Object { $_.moved })
      @($p).Count -eq 2 -and @($movedP).Count -eq 0
    }
    Assert-PiCase 'MUST FIRE: an unreadable afternoon leaves NO pair for that product, and is counted as a could-not-look' {
      $rows = @()
      $rows += (New-PiRow -Date '2026-09-13' -Window 'morning'   -Hour 8  -Commodity 'lettuce' -Published 2.79)
      $rows += (New-PiRow -Date '2026-09-13' -Window 'afternoon' -Hour 15 -Commodity 'lettuce' -Published $null -Status 'error:timeout')
      $v = Get-PiVerdict -Rows $rows -Panel $fixPanel
      $v.pairs -eq 0 -and $v.unreadable -eq 1
    }
    # The price check inside Get-PiPairs is a SECOND guard over the status check beside it, and a
    # mutation probe removed it and killed nothing until this case existed. It is kept rather than
    # deleted - unlike the window filter, this one guards a real failure: a row that says ok while
    # carrying no price would cast to 0.00, and a $0.00 afternoon against a real morning is a
    # FABRICATED move, the worst possible answer because it OPENS the item on nothing.
    Assert-PiCase 'MUST FIRE: a row that says ok but carries no price never becomes a 0.00 pair' {
      $rows = @()
      $rows += (New-PiRow -Date '2026-09-13' -Window 'morning'   -Hour 8  -Commodity 'onions' -Published 1.19)
      $rows += (New-PiRow -Date '2026-09-13' -Window 'afternoon' -Hour 15 -Commodity 'onions' -Published $null -Status 'ok')
      $v = Get-PiVerdict -Rows $rows -Panel $fixPanel
      $v.pairs -eq 0 -and $v.moved -eq 0 -and $v.unreadable -eq 1
    }
    Assert-PiCase 'MUST FIRE: 0 moves over too few pairs is BLIND, never a CLOSE' {
      $rows = @()
      foreach ($c in @($comms | Select-Object -Last 10)) {
        $rows += (New-PiRow -Date '2026-09-13' -Window 'morning'   -Hour 8  -Commodity $c -Published 2.50)
        $rows += (New-PiRow -Date '2026-09-13' -Window 'afternoon' -Hour 15 -Commodity $c -Published 2.50)
      }
      $v = Get-PiVerdict -Rows $rows -Panel $fixPanel
      $v.verdict -eq 'BLIND' -and $v.moved -eq 0 -and $v.pairs -eq 10
    }
    Assert-PiCase 'CLEAN TWIN: one hole does not break the other 29 pairs, and the denominator says 29' {
      $rows = @($flat | Where-Object { -not ([string]$_.date -eq '2026-09-13' -and [string]$_.window -eq 'afternoon' -and [string]$_.commodity -eq 'spinach') })
      $v = Get-PiVerdict -Rows $rows -Panel $fixPanel
      $v.pairs -eq 29 -and $v.verdict -eq 'CLOSE'
    }
    Assert-PiCase 'MUST NOT FIRE: an evening reading never pairs with the morning, so it cannot enter the verdict' {
      $rows = @()
      $rows += (New-PiRow -Date '2026-09-13' -Window 'morning' -Hour 8  -Commodity 'broccoli' -Published 2.19)
      $rows += (New-PiRow -Date '2026-09-13' -Window 'evening' -Hour 20 -Commodity 'broccoli' -Published 1.19)
      $v = Get-PiVerdict -Rows $rows -Panel $fixPanel
      $v.pairs -eq 0 -and $v.moved -eq 0 -and $v.verdict -eq 'BLIND'
    }
    Assert-PiCase 'CLEAN TWIN: the same evening drop IS reported, separately, as supplementary evidence' {
      $rows = @()
      $rows += (New-PiRow -Date '2026-09-13' -Window 'afternoon' -Hour 15 -Commodity 'broccoli' -Published 2.19)
      $rows += (New-PiRow -Date '2026-09-13' -Window 'evening'   -Hour 20 -Commodity 'broccoli' -Published 1.19)
      $v = Get-PiVerdict -Rows $rows -Panel $fixPanel
      $v.supplementary.pairs -eq 1 -and $v.supplementary.moved -eq 1 -and $v.moved -eq 0
    }
    Assert-PiCase 'the verdict line prints its denominator, not a bare count' {
      $v = Get-PiVerdict -Rows $flat -Panel $fixPanel
      $lines = Write-PiVerdictLines -V $v
      ($lines -join "`n") -match 'over 30 morning-vs-afternoon pair\(s\)'
    }
    Assert-PiCase 'the ledger round-trips through a real file, one JSON row per line' {
      $p = Join-Path $scratch 'ledger.jsonl'
      foreach ($r in @($flat | Select-Object -Last 3)) { Add-TcLine -Path $p -Text ($r | ConvertTo-Json -Compress -Depth 4) | Out-Null }
      $back = Read-PiLedger -Path $p
      @($back).Count -eq 3 -and [string]@($back)[0].commodity -ne ''
    }
    Assert-PiCase 'MUST NOT FIRE: an absent ledger reads as zero rows and is BLIND, not a clean CLOSE' {
      $back = Read-PiLedger -Path (Join-Path $scratch 'nothing-here.jsonl')
      $v = Get-PiVerdict -Rows $back -Panel $fixPanel
      @($back).Count -eq 0 -and $v.verdict -eq 'BLIND'
    }
    Assert-PiCase 'the shipped panel names 15 products, both deciding windows and a 30-pair plan' {
      @($fixPanel.products).Count -eq 15 -and @($fixPanel.plan.deciding_windows).Count -eq 2 -and `
      [int]$fixPanel.bar.deciding_pairs_planned -eq (@($fixPanel.products).Count * @($fixPanel.plan.dates).Count)
    }
    Assert-PiCase 'every panel commodity is a real Fruit or Vegetables id in this estate' {
      $cats = (Get-Content -LiteralPath (Join-Path $here 'categories.json') -Raw -Encoding UTF8 | ConvertFrom-Json).categories
      $produce = @()
      foreach ($k in @('fruit', 'veg')) { $produce += @(@($cats | Where-Object { $_.key -eq $k })[0].commodities) }
      $missing = @(@($fixPanel.products) | Where-Object { $produce -notcontains [string]$_.commodity })
      @($missing).Count -eq 0
    }
  } finally {
    if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue }
  }

  Write-Output ("probe-produce-intraday self-test: {0} case(s), {1} failure(s)" -f $cases, $fails)
  if ($fails -eq 0) { Write-Output 'probe-produce-intraday self-test: PASS'; exit 0 }
  Write-Output 'probe-produce-intraday self-test: FAIL'
  exit 1
}

# ---------------------------------------------------------------------------- read
if ($Read) {
  # A RUN RECORD BEFORE ANYTHING ELSE. The scheduled task runs -WindowStyle Hidden, so without this the
  # only thing a failed reading could ever say is its exit code, and this estate has already spent a day
  # unable to learn why three hidden jobs returned 1 (ops\audit-run-log-claims.ps1). It starts ahead of
  # the panel and credential checks on purpose: those are the two failures most likely to happen
  # unattended, and a record that begins after them cannot describe either.
  $runLog = Start-RunLog -Name 'produce-intraday' -OutDir (Join-Path $here 'out')
  $panelFile = Get-PiPanelPath $PanelPath
  if (-not (Test-Path -LiteralPath $panelFile)) { Write-Output "produce-intraday COULD NOT EVALUATE: no panel at $panelFile"; Stop-RunLog -ExitCode 3 -Path $runLog; exit 3 }
  $panel = Get-Content -LiteralPath $panelFile -Raw -Encoding UTF8 | ConvertFrom-Json
  $keyFile = Join-Path $here '.krogerkey'
  $cid = $env:KROGER_CLIENT_ID; $csec = $env:KROGER_CLIENT_SECRET
  if (-not $cid -or -not $csec) {
    if (-not (Test-Path -LiteralPath $keyFile)) {
      Write-Output 'produce-intraday COULD NOT EVALUATE: no Kroger credentials (grocery\.krogerkey or KROGER_CLIENT_ID/SECRET). Nothing was read and nothing is proven.'
      Stop-RunLog -ExitCode 3 -Path $runLog
      exit 3
    }
    $k = Get-Content -LiteralPath $keyFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $cid = [string]$k.client_id; $csec = [string]$k.client_secret
  }
  $basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($cid + ':' + $csec))
  $token = (Invoke-RestMethod -Method Post -Uri 'https://api.kroger.com/v1/connect/oauth2/token' `
            -Headers @{ Authorization = "Basic $basic" } -ContentType 'application/x-www-form-urlencoded' `
            -Body @{ grant_type = 'client_credentials'; scope = 'product.compact' }).access_token
  $headers = @{ Authorization = "Bearer $token"; Accept = 'application/json' }

  $now    = [datetimeoffset]::Now
  $stamp  = $now.ToString('yyyy-MM-ddTHH:mm:ssK')
  $window = Get-PiWindow ([int]$now.Hour)
  $panelHash = (Get-FileHash -LiteralPath $panelFile -Algorithm SHA256).Hash
  $commit = Get-PiHarnessCommit
  $ledger = Get-PiLedgerPath $LedgerPath
  $loc = [string]$panel.location_id

  $wrote = 0; $bad = 0
  foreach ($p in @($panel.products)) {
    $status = 'ok'; $reg = $null; $promo = $null; $desc = ''; $size = ''
    try {
      $uri = 'https://api.kroger.com/v1/products/' + [string]$p.product_id + '?filter.locationId=' + $loc
      $resp = Invoke-RestMethod -Uri $uri -Headers $headers
      $item = @($resp.data.items)[0]
      $reg = $item.price.regular; $promo = $item.price.promo
      $desc = ([string]$resp.data.description) -replace '[^\x20-\x7E]', '-'
      $size = [string]$item.size
    } catch {
      $status = 'error:' + (($_.Exception.Message) -replace '[^\x20-\x7E]', ' ')
    }
    $published = if ($status -eq 'ok') { Get-PiPublishedPrice $reg $promo } else { $null }
    if ($status -eq 'ok' -and $null -eq $published) { $status = 'no-price' }
    if ($status -ne 'ok') { $bad++ }
    $row = [ordered]@{
      reading        = $stamp
      date           = $now.ToString('yyyy-MM-dd')
      hour           = [int]$now.Hour
      tz_offset      = $now.ToString('zzz')
      window         = $window
      store          = [string]$panel.store
      location_id    = $loc
      commodity      = [string]$p.commodity
      kind           = [string]$p.kind
      product_id     = [string]$p.product_id
      description    = $desc
      size           = $size
      regular        = $reg
      promo          = $promo
      published      = $published
      status         = $status
      panel_sha256   = $panelHash
      harness        = 'grocery/probe-produce-intraday.ps1'
      harness_commit = $commit
      api            = 'api.kroger.com/v1/products'
    }
    Add-TcLine -Path $ledger -Text (([pscustomobject]$row) | ConvertTo-Json -Compress -Depth 4) | Out-Null
    $wrote++
    Start-Sleep -Milliseconds 180
  }
  Write-Output ("produce-intraday READ: {0} of {1} panel product(s) recorded at {2} ({3}), {4} unreadable -> {5}" -f `
                $wrote, @($panel.products).Count, $stamp, $window, $bad, $ledger)
  # Score after every reading, so the verdict file is always current and the last reading needs no
  # second trigger to produce one.
  $rows = Read-PiLedger -Path $ledger
  $v = Get-PiVerdict -Rows $rows -Panel $panel
  $vJson = ($v | ConvertTo-Json -Depth 6)
  Write-TcLfFile -Path (Get-PiVerdictPath $VerdictPath) -Text $vJson -NoBom | Out-Null
  foreach ($l in (Write-PiVerdictLines -V $v)) { Write-Output $l }
  $rc = if ($bad -gt 0 -and $wrote -eq $bad) { 1 } else { 0 }
  Stop-RunLog -ExitCode $rc -Path $runLog
  exit $rc
}

# ---------------------------------------------------------------------------- verdict
if ($Verdict) {
  $panelFile = Get-PiPanelPath $PanelPath
  if (-not (Test-Path -LiteralPath $panelFile)) { Write-Output "produce-intraday COULD NOT EVALUATE: no panel at $panelFile"; exit 3 }
  $panel = Get-Content -LiteralPath $panelFile -Raw -Encoding UTF8 | ConvertFrom-Json
  $ledger = Get-PiLedgerPath $LedgerPath
  $rows = Read-PiLedger -Path $ledger
  if (@($rows).Count -eq 0) {
    Write-Output "produce-intraday COULD NOT EVALUATE: the ledger $ledger holds no readings. That is not a CLOSE."
    exit 3
  }
  $v = Get-PiVerdict -Rows $rows -Panel $panel
  $vJson = ($v | ConvertTo-Json -Depth 6)
  Write-TcLfFile -Path (Get-PiVerdictPath $VerdictPath) -Text $vJson -NoBom | Out-Null
  foreach ($l in (Write-PiVerdictLines -V $v)) { Write-Output $l }
  if ($v.verdict -eq 'BLIND') { exit 3 }
  exit 0
}

Write-Output 'probe-produce-intraday.ps1 - pass one of -Read, -Verdict, -SelfTest. See the header for the acceptance bar.'
exit 3
