<#
  build-sale-windows.ps1 - Per-ITEM sale-date + sale-price log (the event-driven refresh brain).

  WHY: the board used to know sale windows only at the STORE level (ad-schedule.json's weekly cycle),
  so the daily Baker's agent had to SCAN blindly every day just in case a price moved. Instead, when we
  read an ad we now record, per item on sale: its sale PRICE and its sale START/END dates. From that we
  know EXACTLY when each item's price reverts (refresh_on = sale_end + 1). The daily guard reads this to
  scan Baker's only when an item's sale actually starts or rolls off - not every day.

  Windows come from the ad itself, no fabrication:
    - base weekly window  = each store's live ad window (ad-schedule.json 'current', self-corrected from
      the feed every pull; for Baker's this equals the flyer cover "SALE DATES" range).
    - tighter flash window = ParseFlashWindow() on the item's ad/sale text (weekend / single-day / M-D),
      identical to the logic that draws the page's "Sale thru" badge, so the log and the badge agree.
    - sale_start = flash.from ?? window.from ; sale_end = flash.to ?? window.to ; refresh_on = sale_end + 1.

  Everyday (EDLP) chips carry no window and never expire, so they are NOT logged here.

  Input : newest out\comparison-*.json (the ranked board) + ad-schedule.json (+ prior sale-windows.json
          for first_seen continuity). Output: sale-windows.json in the grocery ROOT (durable, gitignored;
          regenerated daily by check-ad-cycles so it self-heals).

  Usage : powershell -ExecutionPolicy Bypass -File build-sale-windows.ps1
          powershell -ExecutionPolicy Bypass -File build-sale-windows.ps1 -AsOf 2026-07-15   (test a date)
          powershell -ExecutionPolicy Bypass -File build-sale-windows.ps1 -SelfTest
#>
param(
  [string]$OutDir = "",
  [string]$ComparisonFile = "",
  [string]$ScheduleFile = "",
  [string]$LogFile = "",
  [string]$AsOf = "",
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir)       { $OutDir       = Join-Path $root 'out' }
if (-not $ScheduleFile) { $ScheduleFile = Join-Path $root 'ad-schedule.json' }
if (-not $LogFile)      { $LogFile      = Join-Path $root 'sale-windows.json' }
$today = if ($AsOf) { ([datetime]$AsOf).Date } else { (Get-Date).Date }

# ---------------------------------------------------------------- flash-window parser
# Identical logic to build-deals-page.ps1's ParseFlashWindow so the log and the on-page "Sale thru" badge
# never disagree. Returns @{from;to} within [$from,$to], @{suppress=$true} for an undated "today only",
# or $null (fall back to the full weekly window).
function ParseFlashWindow([string]$text, $from, $to) {
  if ($null -eq $from -or $null -eq $to) { return $null }
  $t = ([string]$text).ToLower()
  $m = [regex]::Match($t, '\b(1[0-2]|0?[1-9])[/-]([0-3]?[0-9])\b(?!\s*(?:fl\s*oz|oz|lb|lbs|ct|count|pk|pack|gal|each|ea|cans?|bottles?|rolls?)\b)')
  if ($m.Success) { try { $d = [datetime]::new($from.Year, [int]$m.Groups[1].Value, [int]$m.Groups[2].Value); if ($d -ge $from -and $d -le $to) { return @{ from=$d; to=$d } } } catch {} }
  if ($t -match 'weekend') {
    $f=$from; while ($f -le $to -and [int]$f.DayOfWeek -ne 5) { $f=$f.AddDays(1) }
    if ($f -le $to) { $e=$f; while ($e -lt $to -and [int]$e.DayOfWeek -ne 0) { $e=$e.AddDays(1) }; return @{ from=$f; to=$e } }
  }
  foreach ($pair in @(@('sunday',0),@('monday',1),@('tuesday',2),@('wednesday',3),@('thursday',4),@('friday',5),@('saturday',6))) {
    if ($t -match ('\b' + $pair[0] + '\b')) { for ($d=$from; $d -le $to; $d=$d.AddDays(1)) { if ([int]$d.DayOfWeek -eq $pair[1]) { return @{ from=$d; to=$d } } } }
  }
  if ($t -match '\btoday only\b|\bone day\b|\b1[- ]day\b') { return @{ suppress=$true } }
  return $null
}

# ---------------------------------------------------------------- SELF-TEST (-SelfTest exits here)
if ($SelfTest) {
  $fail = 0
  function _Eq($label,$got,$want) { if ("$got" -eq "$want") { Write-Output "ok    $label = $got" } else { Write-Output "FAIL  $label got '$got' want '$want'"; $script:fail++ } }
  $wf = [datetime]'2026-07-08'; $wt = [datetime]'2026-07-14'
  # plain weekly sale text -> no flash -> null (caller uses the full weekly window)
  _Eq 'weekly->null'      (ParseFlashWindow '$2.99' $wf $wt) $null
  # weekend flash -> Fri..Sun inside the window
  $we = ParseFlashWindow '3-day weekend sale' $wf $wt
  _Eq 'weekend.from' ($we.from.ToString('yyyy-MM-dd')) '2026-07-10'
  _Eq 'weekend.to'   ($we.to.ToString('yyyy-MM-dd'))   '2026-07-12'
  # explicit single date inside window
  $sd = ParseFlashWindow 'Sale 7/11 only' $wf $wt
  _Eq 'single.from' ($sd.from.ToString('yyyy-MM-dd')) '2026-07-11'
  _Eq 'single.to'   ($sd.to.ToString('yyyy-MM-dd'))   '2026-07-11'
  # a size that LOOKS like a date must NOT be read as one
  _Eq 'size-not-date' (ParseFlashWindow 'yogurt 9-12 oz $3.99' $wf $wt) $null
  # refresh_on = sale_end + 1
  _Eq 'refresh_on' ($wt.AddDays(1).ToString('yyyy-MM-dd')) '2026-07-15'
  Write-Output ('-'*54)
  if ($script:fail -eq 0) { Write-Output 'SELF-TEST PASS'; exit 0 } else { Write-Output "SELF-TEST FAIL: $script:fail"; exit 1 }
}

# ---------------------------------------------------------------- base per-store weekly windows
# ad-schedule.json 'current' is the live, feed-self-corrected window per store (Baker's == flyer cover dates).
$adWin = @{}
if (Test-Path $ScheduleFile) {
  $sc = Read-JsonFile $ScheduleFile
  foreach ($s in $sc.stores) { if ($s.current -and $s.current.from) { $adWin[[string]$s.store] = @{ from=[datetime]$s.current.from; to=[datetime]$s.current.to } } }
}

# ---------------------------------------------------------------- newest board
if (-not $ComparisonFile) {
  $cf = Get-ChildItem (Join-Path $OutDir 'comparison-*.json') -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
  if (-not $cf) { Write-Output 'No comparison-*.json found - nothing to log.'; exit 0 }
  $ComparisonFile = $cf.FullName
}
$board = Read-JsonFile $ComparisonFile

# ---------------------------------------------------------------- prior log (first_seen continuity + roll-off carry)
$prior = @{}
if (Test-Path $LogFile) { try { foreach ($w in (Read-JsonFile $LogFile).windows) { $prior[($w.id + '|' + $w.store)] = $w } } catch {} }

# ---------------------------------------------------------------- build TODAY's active sale windows from the board
$active = @{}
foreach ($c in $board.comparison) {
  foreach ($s in $c.stores) {
    if ([string]$s.type -ne 'sale') { continue }              # everyday chips have no window / never expire
    $store = [string]$s.store
    $win = $adWin[$store]
    if (-not $win) { continue }                               # a sale with no known store window (EDLP store) - skip
    $wf = $win.from; $wt = $win.to

    # A MONTHLY-AD PRICE DOES NOT EXPIRE ON THE WEEKLY BOUNDARY.
    # ad-schedule.json only knows each store's WEEKLY cycle, so every sale used to
    # inherit it. Fareway also runs a MONTHLY ad, and its rows carry
    # source_ad = "monthly ad p4 ..." - those prices run the whole month. Stamping
    # the weekly window on them declared three live Fareway sales expired on
    # 2026-08-15 when the monthly ad ran to 08-29 (found 2026-08-20:
    # alfredo-sauce, fruit-cups, fruit-snacks). The board was right; this file was
    # wrong, and capture-policy then queued six re-prices that were not needed -
    # spending the very request budget the policy exists to protect.
    # The monthly window comes from the store's own ad manifest.
    $note = ''
    if ([string]$s.source_ad -match '(?i)monthly') {
      $mw = $null
      $mf = Get-ChildItem (Join-Path $OutDir ((($store -replace "[^A-Za-z]", '').ToLower()) + '\*-ad-manifest-*.json')) -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
      if ($mf) {
        try {
          $mdoc = Read-JsonFile $mf.FullName
          if ($mdoc.monthly -and $mdoc.monthly.from -and $mdoc.monthly.to) {
            $mw = @{ from = [datetime]$mdoc.monthly.from; to = [datetime]$mdoc.monthly.to }
          }
        } catch { }
      }
      if ($mw) { $wf = $mw.from; $wt = $mw.to }
      else { $note = 'monthly-ad price but no monthly window found; weekly window used (expiry may be early)' }
    }
    # THE CELL'S OWN WINDOW BEATS THE STORE'S (2026-08-21). Until today the only window available was
    # ad-schedule.json's per-STORE ad cycle, so every sale cell inherited it. That is wrong wherever a
    # store runs more than one ad at a time, which is most of them:
    #   Hy-Vee  'Weekly Ad' 08-17..08-23  |  monthly 08-03..08-30  |  '3 Day Sale' 08-21..08-23
    #   Fareway  weekly Sun-Sat           |  monthly ~4 weeks   (already special-cased below)
    # Measured before the fix: all 28 Hy-Vee sale cells carried 08-17..08-23, so its 216 monthly-ad
    # deals were retired on 08-23 instead of 08-30 - seven days early, while the ad was still running,
    # reverting those cells to everyday and re-queueing them for a capture they did not need.
    # compare-deals now carries ad_from/ad_to from the deal that actually WON the cell, so prefer it.
    # The monthly-ad manifest lookup below stays as the fallback for rows that still arrive undated.
    $cellFrom = $null; $cellTo = $null
    if ($s.PSObject.Properties['ad_from'] -and [string]$s.ad_from -match '^\d{4}-\d{2}-\d{2}$') { try { $cellFrom = [datetime]$s.ad_from } catch {} }
    if ($s.PSObject.Properties['ad_to']   -and [string]$s.ad_to   -match '^\d{4}-\d{2}-\d{2}$') { try { $cellTo   = [datetime]$s.ad_to } catch {} }
    if ($cellFrom -and $cellTo) { $wf = $cellFrom; $wt = $cellTo; $note = 'window from the deal itself' }

    $flash = ParseFlashWindow ((([string]$s.ad) + ' ' + ([string]$s.note))) $wf $wt
    if ($flash -and $flash.suppress) { $note = 'undated short sale (window unknown, using weekly)'; $flash = $null }
    $sFrom = if ($flash) { $flash.from } else { $wf }
    $sTo   = if ($flash) { $flash.to }   else { $wt }
    $key = ($c.id + '|' + $store)
    $fseen = if ($prior.ContainsKey($key) -and $prior[$key].first_seen) { [string]$prior[$key].first_seen } else { $today.ToString('yyyy-MM-dd') }
    $active[$key] = [ordered]@{
      id          = [string]$c.id
      commodity   = [string]$c.commodity
      store       = $store
      item        = [string]$s.item
      sale_price  = $s.per_unit
      unit        = [string]$c.unit
      size        = [string]$s.size
      ad_text     = [string]$s.ad
      is_flash    = [bool]$flash
      sale_start  = $sFrom.ToString('yyyy-MM-dd')
      sale_end    = $sTo.ToString('yyyy-MM-dd')
      refresh_on  = $sTo.AddDays(1).ToString('yyyy-MM-dd')
      status      = 'active'
      first_seen  = $fseen
      last_seen   = $today.ToString('yyyy-MM-dd')
      note        = $note
      # THE PROCESSED SIGNAL (2026-08-22). repriced_for holds the refresh_on value a landed
      # capture actually satisfied; capture-policy's Set-SaleExpiryProcessed is the only
      # thing that writes it. Carried forward across the daily rebuild exactly like
      # first_seen, or every rebuild would forget the work and re-queue it. It is
      # deliberately compared against THIS entry's refresh_on, so when a sale renews with a
      # later end date the entry becomes owed again rather than staying "done" forever.
      repriced_on  = $(if ($prior.ContainsKey($key)) { [string]$prior[$key].repriced_on } else { '' })
      repriced_for = $(if ($prior.ContainsKey($key)) { [string]$prior[$key].repriced_for } else { '' })
    }
  }
}

# carry forward a prior entry that has dropped OFF today's board but whose refresh_on hasn't passed yet:
# we still need to know the sale is rolling off so the guard fires on that day (the item may already be gone
# from the board the morning its price reverts).
#
# PRUNE BY WORK DONE, NOT BY DATE (2026-08-22). This used to keep an entry only while
# refresh_on >= today, so an expiry lived for exactly one day and was then deleted whether or
# not anybody re-priced it. That is safe only while every expiry is processed on its due day,
# and it stopped being true the moment capture-policy started CAPPING the daily slice: 130
# entries reverted on 2026-08-23 and Family Fare's Freshop wall is ~40 calls, so most of them
# could not possibly be processed that morning. Deleting the rest would leave their SALE
# prices publishing on the board until each item's next quarterly rotation slot - up to 90
# days - with nothing on disk to say a re-price was ever owed. A throttle is visible; that is
# not, which makes it the worse failure.
#
# So an entry survives while EITHER
#   - its sale is still running / reverts today (refresh_on >= today), or
#   - it is still OWED: refresh_on has passed and repriced_for does not match it.
# capture-policy's Set-SaleExpiryProcessed writes repriced_for, and only after a landed
# capture - so a run that fetched nothing prunes nothing. The two halves must move together;
# see the coupling note beside SaleExpiries in capture-policy-lib.ps1.
$owedCount = 0
foreach ($k in $prior.Keys) {
  if ($active.ContainsKey($k)) { continue }
  $p = $prior[$k]
  $ro = $null; try { $ro = [datetime]$p.refresh_on } catch {}
  if ($ro -eq $null) { continue }
  $roS = $ro.ToString('yyyy-MM-dd')
  $done = ((([string]$p.repriced_for) -ne '') -and (([string]$p.repriced_for) -eq $roS))
  $due = ($ro.Date -ge $today)
  if (-not $due -and $done) { continue }         # processed and past - this is the only prune
  $e = [ordered]@{}
  foreach ($prop in $p.PSObject.Properties) { $e[$prop.Name] = $prop.Value }
  if (-not $e.Contains('repriced_on')) { $e['repriced_on'] = '' }
  if (-not $e.Contains('repriced_for')) { $e['repriced_for'] = '' }
  if ($due) {
    $e['status'] = 'awaiting-rolloff'   # no longer on the live board, but its price is due to revert soon
  } else {
    # Past due and never processed - the board may still be publishing this sale price.
    $e['status'] = 'reprice-owed'
    $owedCount++
  }
  $active[$k] = $e
}

$rows = @($active.Values | Sort-Object @{e={$_.store}}, @{e={$_.commodity}})

# ---------------------------------------------------------------- write durable log
$out = [ordered]@{
  updated      = (Get-Date).ToString('s')
  today        = $today.ToString('yyyy-MM-dd')
  source       = (Split-Path $ComparisonFile -Leaf)
  active_count = @($rows | Where-Object { $_.status -eq 'active' }).Count
  owed_count   = @($rows | Where-Object { $_.status -eq 'reprice-owed' }).Count
  note         = 'Per-item sale windows: sale_price + sale_start/sale_end from the ad; refresh_on = sale_end + 1 (the day the price reverts, when a re-price is due). Everyday/EDLP chips are not logged (no expiry). Derived daily from the newest comparison board; safe to delete (regenerates) EXCEPT for repriced_on/repriced_for, which record work that actually happened and cannot be rederived - an entry is pruned only once refresh_on is past AND repriced_for matches it, so a capped or throttled run leaves the re-price owed (status reprice-owed) instead of losing it.'
  windows      = $rows
}
($out | ConvertTo-Json -Depth 6) | Set-Content $LogFile -Encoding UTF8

# ---------------------------------------------------------------- report
Write-Output ("SALE-WINDOW LOG  -  " + $today.ToString('yyyy-MM-dd') + "   (" + $out.active_count + " active sale(s), " + $rows.Count + " tracked, " + $out.owed_count + " re-price OWED)")
Write-Output ("=" * 82)
foreach ($r in $rows) {
  $flag = if ($r.is_flash) { ' [flash]' } else { '' }
  $st   = if ($r.status -ne 'active') { ' (' + $r.status + ')' } else { '' }
  Write-Output ('{0,-13} {1,-26} ${2,-8}/{3,-5} {4} -> {5}  refresh {6}{7}{8}' -f `
    $r.store, $r.commodity, ('{0:N2}' -f [double]$r.sale_price), $r.unit, $r.sale_start, $r.sale_end, $r.refresh_on, $flag, $st)
}
# upcoming: sales whose price reverts today or tomorrow (a re-price / re-check is due)
$due = @($rows | Where-Object { try { $ro=[datetime]$_.refresh_on; ($ro.Date -ge $today -and $ro.Date -le $today.AddDays(1)) } catch { $false } })
if ($due.Count -gt 0) {
  Write-Output ""
  Write-Output ("NEXT 2 DAYS - " + $due.Count + " sale(s) roll off (price reverts, re-check due):")
  foreach ($d in $due) { Write-Output ("   " + $d.store + "  " + $d.commodity + "  ends " + $d.sale_end + " -> refresh " + $d.refresh_on) }
}
Write-Output ""
Write-Output ("Saved: " + $LogFile)
