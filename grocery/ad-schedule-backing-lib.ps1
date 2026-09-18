<#
  ad-schedule-backing-lib.ps1 - is the ad window that ad-schedule.json calls CURRENT backed by the capture that
  advanced it? The decision and the wording behind check-ad-cycles.ps1's SCHEDULE-AHEAD-OF-DATA page, kept pure
  so that script's -SelfTest reaches both with frozen values and no data files.

  LIKE FOR LIKE (2026-09-18, queue 2026-09-18-de39ec, triage-plans\plan-2026-09-18.json). Fareway's calendar and
  its deals file are written by one producer, so comparing them is fair. Baker's is not. Its calendar is advanced
  by the daily Kroger API scan (pull-regular-bakers-api.ps1 Update-BakersAdSchedule, which derives the window from
  the detection date after a store-scoped API capture), while the file the check compared it with,
  out\bakers\bakers-deals-*.json, is a browser read of the printed flyer that nothing has been scheduled to make
  since the Wednesday Chrome agent was retired on 2026-08-22. So the check paged on every Baker's ad turnover
  (08-26, 08-29, 09-02, 09-09, 09-18) whether or not the board was harmed. For Baker's the data is now the newest
  API capture, and the calendar is backed when at least one of its promo rows runs to the window's last day. The
  flyer gap is only logged: audit-row-age.ps1 pages AD COVERAGE GONE for it under the 24h owned-gap rule.

  AND THE PAGE SAYS WHAT IS TRUE. compare-deals refuses an ad whose window has closed (Test-AdWindowClosed), so a
  lagging capture DROPS its sale rows from the board: the loss is coverage, not a stale price. The old body said
  the board "keeps pricing cells from the PREVIOUS ad", which stopped being true when that refusal shipped, and
  told the reader to run a browser agent that no longer exists.
#>

function Get-AdScheduleBacking {
  param(
    [Parameter(Mandatory = $true)][string]$Store,
    [Parameter(Mandatory = $true)][datetime]$SchedTo,
    [string]$SupplementName = '',
    $SupplementTo = $null,
    [string]$ApiName = '',
    [string[]]$ApiAdTo = @()
  )
  $supTo = $null
  if (($null -ne $SupplementTo) -and ("$SupplementTo" -ne '')) { try { $supTo = [datetime]$SupplementTo } catch { $supTo = $null } }
  # Unchanged from the original check: a deals file that declares no window end is not called stale.
  $supplementBacks = [bool]($SupplementName -and ((-not $supTo) -or ($supTo -ge $SchedTo)))
  $have = if ($SupplementName) { $SupplementName + ' (window ends ' + $(if ($supTo) { $supTo.ToString('yyyy-MM-dd') } else { 'undeclared' }) + ')' } else { 'no deals file at all' }
  if ($Store -ne "Baker's") {
    return [pscustomobject]@{ store = $Store; page = (-not $supplementBacks); backed_by = $(if ($supplementBacks) { 'supplement' } else { '' }); supplement_gap = (-not $supplementBacks); have = $have; api_name = ''; api_rows = 0 }
  }
  # ORDINAL, on the yyyy-MM-dd prefix: a culture-sensitive string compare is the wrong default for data.
  $toS = $SchedTo.ToString('yyyy-MM-dd')
  $apiRows = @(@($ApiAdTo) | Where-Object { $_ -and ([string]$_).Length -ge 10 -and ([string]::CompareOrdinal(([string]$_).Substring(0, 10), $toS) -ge 0) }).Count
  $apiBacks = [bool]($ApiName -and ($apiRows -gt 0))
  return [pscustomobject]@{ store = $Store; page = (-not $apiBacks); backed_by = $(if ($apiBacks) { 'api' } else { '' }); supplement_gap = (-not $supplementBacks); have = $have; api_name = $ApiName; api_rows = $apiRows }
}

function Get-AdScheduleAlertText {
  param([Parameter(Mandatory = $true)]$Backing, [string]$SchedTo, [string]$Detected = '', [int]$SupplementRows = 0)
  $store = [string]$Backing.store
  $when = if ($Detected) { " (advanced on $Detected per the schedule's own history)" } else { '' }
  if ($store -eq "Baker's") {
    $data = if ($Backing.api_name) { "the newest Kroger API capture, $($Backing.api_name), carries no promo row running to $SchedTo" } else { 'there is no Kroger API capture (out\regular\bakers-regular-*.json) on disk at all' }
    $fix = "check that the daily Kroger API scan captured this window's promos: the calendar it advanced and its own rows disagree. Separately, the Baker's flyer supplement (newest $($Backing.have)) has had no scheduled producer since the Wednesday Chrome agent was retired on 2026-08-22 (open question Q1-bakers-flyer-lane, triage-plans\plan-2026-09-18.json); audit-row-age pages AD COVERAGE GONE for it."
  } else {
    $data = "the newest ad capture on disk is $($Backing.have)"
    $fix = "land this window's ad capture. The walled stores are captured on demand from out\browser-capture-due-<date>.flag, which capture-watchdog watches (the Wednesday browser agent this alert used to name was retired on 2026-08-22)."
  }
  $rowsNote = if ($SupplementRows -gt 0) { "its $SupplementRows sale row(s)" } else { 'its sale rows' }
  $summary = "REVIEW    $store's schedule says its ad runs to $SchedTo, but $data. compare-deals refuses a closed ad, so the lagging capture's sale rows DROP off the board (coverage lost, prices not stale) until a capture lands."
  $body = "ad-schedule.json records $store's current ad window ending $SchedTo$when, but $data.`n`nThe calendar and the capture are written by two different steps and only one ran. compare-deals refuses an ad whose window has closed (Test-AdWindowClosed), so the newest capture ($($Backing.have)) does NOT keep pricing the board after its window ends: $rowsNote DROP off it. The loss is coverage (those cells fall back to an everyday price or to another store), not a stale price.`n`nFix: $fix"
  return [pscustomobject]@{ summary = $summary; body = $body }
}
