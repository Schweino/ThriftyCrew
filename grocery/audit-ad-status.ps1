<#
  audit-ad-status.ps1 - the holistic "where does every store's ad actually stand?" answer.

  WHY THIS EXISTS AS ITS OWN CHECK. Two different things can be stale and they disagree:

    THE SCHEDULE   ad-schedule.json says a store's current window and its next_pull.
                   It advances only after a successful store-scoped capture, so a store
                   whose pull has been failing looks "due" forever.
    THE AD FILE    the newest out\<store>\*-deals-*.json actually on disk. compare-deals
                   REFUSES an ad whose window has closed, so once that date passes the
                   store's sale rows silently drop off the board and every cell falls
                   back to its everyday price - with no error anywhere.

  The second one is the dangerous half: nothing fails, the board just quietly loses a
  store's sale prices. audit-row-age reports it as "AD COVERAGE GONE" but only as one
  line among many, and only for stores that happen to carry dated rows.

  This prints both, per store, plus what falls off if the ad is not refreshed.

  Exit 0 = every weekly-ad store has a live, in-window ad.
  Exit 1 = at least one store's ad has closed or its pull is overdue.
#>
param([string]$OutDir = '', [string]$Today = '', [switch]$Json)

$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
$todayS = if ($Today) { $Today } else { (Get-Date).ToString('yyyy-MM-dd') }
$todayD = [datetime]::ParseExact($todayS, 'yyyy-MM-dd', $null)

function AsDate([string]$s) {
  if (-not $s) { return $null }
  $m = [regex]::Match($s, '\d{4}-\d{2}-\d{2}')
  if (-not $m.Success) { return $null }
  try { return [datetime]::ParseExact($m.Value, 'yyyy-MM-dd', $null) } catch { return $null }
}

# Where each store's ad rows actually live. The combined ads-<date>.json carries the
# three server stores; the rest keep their own folder.
$AD_SOURCES = @{
  'Hy-Vee'      = @('ads-*.json')
  'Aldi'        = @('ads-*.json')
  'Family Fare' = @('ads-*.json')
  "Baker's"     = @('bakers\bakers-deals-*.json')
  'Fareway'     = @('fareway\fareway-deals-*.json')
  "Sam's Club"  = @('sams\sams-deals-*.json')
  'Walmart'     = @()
}

$sched = ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $root 'ad-schedule.json')))
$rows = New-Object System.Collections.Generic.List[object]

foreach ($s in $sched.stores) {
  $store = [string]$s.store
  $cadence = $s.cadence_days
  $curFrom = AsDate ([string]$s.current.from)
  $curTo = AsDate ([string]$s.current.to)
  $nextPull = AsDate ([string]$s.next_pull)

  # --- the SCHEDULE view -----------------------------------------------------
  $schedState = 'no weekly ad cycle'
  $overdueDays = 0
  if ($cadence) {
    if ($curFrom -and $curTo -and $todayD -ge $curFrom -and $todayD -le $curTo) {
      $schedState = "in window to $($curTo.ToString('yyyy-MM-dd'))"
    } elseif ($nextPull -and $todayD -gt $nextPull) {
      $overdueDays = ($todayD - $nextPull).Days
      $schedState = "PULL OVERDUE by $overdueDays d (next_pull $($nextPull.ToString('yyyy-MM-dd')))"
    } elseif ($nextPull -and $todayD -eq $nextPull) {
      $schedState = 'pull DUE today'
    } else {
      $schedState = 'window closed, pull not yet due'
    }
  }

  # --- the AD FILE view ------------------------------------------------------
  $fileName = ''; $fileTo = $null; $fileRows = 0; $fileState = 'n/a'
  foreach ($pat in $AD_SOURCES[$store]) {
    $f = Get-ChildItem (Join-Path $OutDir $pat) -EA SilentlyContinue |
         Sort-Object Name -Descending | Select-Object -First 1
    if (-not $f) { continue }
    $fileName = $f.Name
    try { $doc = ConvertFrom-Json ([IO.File]::ReadAllText($f.FullName)) } catch { continue }
    $fileTo = AsDate ([string]$doc.ad_to)
    if (-not $fileTo) { $fileTo = AsDate ([string]$doc.valid_to) }
    if ($doc.deals) {
      $fileRows = if ($store -in @('Hy-Vee', 'Aldi', 'Family Fare')) {
        @($doc.deals | Where-Object { [string]$_.store -eq $store }).Count
      } else { @($doc.deals).Count }
    }
    # the combined ads file has no ad_to of its own; fall back to the schedule window
    if (-not $fileTo -and $doc.verification) {
      foreach ($v in $doc.verification) { if ([string]$v.store -eq $store) { $fileTo = AsDate ([string]$v.ad_to) } }
    }
    break
  }
  if ($fileName) {
    if ($fileTo -and $todayD -gt $fileTo) {
      $fileState = "CLOSED $(($todayD - $fileTo).Days) d ago ($($fileTo.ToString('yyyy-MM-dd'))) - $fileRows sale row(s) EXCLUDED from the board"
    } elseif ($fileTo) {
      $fileState = "live to $($fileTo.ToString('yyyy-MM-dd')) ($fileRows row(s))"
    } else {
      $fileState = "no ad_to in file ($fileRows row(s))"
    }
  }

  $bad = ($overdueDays -gt 0) -or ($fileTo -and $todayD -gt $fileTo)
  [void]$rows.Add([pscustomobject]@{
      store = $store; method = [string]$s.method; cadence = $cadence
      schedule = $schedState; overdue_days = $overdueDays
      ad_file = $fileName; ad_file_state = $fileState
      excluded_rows = $(if ($fileTo -and $todayD -gt $fileTo) { $fileRows } else { 0 })
      needs_pull = $bad
    })
}

if ($Json) { $rows | ConvertTo-Json -Depth 4; exit 0 }

Write-Output "AD STATUS - $todayS"
Write-Output ''
foreach ($r in $rows) {
  $flag = if ($r.needs_pull) { '!!' } else { 'ok' }
  Write-Output ("{0} {1,-13} [{2,-7}] schedule: {3}" -f $flag, $r.store, $r.method, $r.schedule)
  if ($r.ad_file) { Write-Output ("                    ad file: {0}  {1}" -f $r.ad_file, $r.ad_file_state) }
}
$need = @($rows | Where-Object { $_.needs_pull })
$lost = ($rows | Measure-Object -Property excluded_rows -Sum).Sum
Write-Output ''
Write-Output ("stores needing a pull: {0} of {1}   sale rows currently EXCLUDED from the board: {2}" -f $need.Count, $rows.Count, $lost)
if ($need.Count) { Write-Output ("  -> " + (($need | ForEach-Object { $_.store }) -join ', ')) }
Write-Output 'AD-STATUS-COMPLETE'
if ($need.Count) { exit 1 } else { exit 0 }
