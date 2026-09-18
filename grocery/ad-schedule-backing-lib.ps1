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

  BAKER'S AD IS NOW ITS OWN LIST PLUS ITS ASKS (2026-09-18, design\PLAN-bakers-weekly-ad-feed-2026-09-18.md). A
  promo row in the newest API capture proved only that the ROTATION happened to ask a term that is on sale; it
  could not prove the new ad's sale items were asked at all, and that is exactly how pasta-sauce, coffee-pods and
  clementines lost their sale cells when the 09-09 flyer closed. pull-bakers-ad-list.ps1 now reads the ad's own
  offer list and routes it onto our search terms, and the API lane asks those first. So Baker's is BACKED when an
  ad list covers the schedule's window AND every routed term has a receipt inside it (capture-policy-lib's
  Get-BakersAdCaptureState, the one rule check-ad-cycles, audit-ad-status and audit-row-age share). It PAGES when
  the list did not land and when the asks did not. The flyer file is no longer expected.
#>

function Get-AdScheduleBacking {
  param(
    [Parameter(Mandatory = $true)][string]$Store,
    [Parameter(Mandatory = $true)][datetime]$SchedTo,
    [string]$SupplementName = '',
    $SupplementTo = $null,
    [string]$ApiName = '',
    [string[]]$ApiAdTo = @(),
    # Baker's only (2026-09-18): the ad list covering the window, its routed term count and how many are still owed.
    [string]$AdListName = '',
    $AdListTo = $null,
    [int]$AdOwed = -1,
    [int]$AdTotal = 0,
    [switch]$AdBlind
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
  # The API's promo rows are still counted, for the log only: they are what the rotation happened to ask.
  $apiRows = @(@($ApiAdTo) | Where-Object { $_ -and ([string]$_).Length -ge 10 -and ([string]::CompareOrdinal(([string]$_).Substring(0, 10), $toS) -ge 0) }).Count
  $listTo = ''
  if (($null -ne $AdListTo) -and ("$AdListTo" -ne '')) { $listTo = ([string]$AdListTo); if ($listTo.Length -ge 10) { $listTo = $listTo.Substring(0, 10) } else { $listTo = '' } }
  $listBacks = [bool]($AdListName -and $listTo -and ([string]::CompareOrdinal($listTo, $toS) -ge 0))
  $asked = [bool]($listBacks -and (-not $AdBlind) -and ($AdOwed -eq 0))
  $haveList = if ($AdListName) { $AdListName + ' (window ends ' + $(if ($listTo) { $listTo } else { 'undeclared' }) + ')' } else { 'no ad list at all' }
  return [pscustomobject]@{ store = $Store; page = (-not $asked); backed_by = $(if ($asked) { 'ad-list' } else { '' }); supplement_gap = (-not $listBacks); have = $haveList
                            api_name = $ApiName; api_rows = $apiRows; ad_list = $AdListName; ad_list_gap = (-not $listBacks); ad_owed = $AdOwed; ad_total = $AdTotal; ad_blind = [bool]$AdBlind }
}

function Get-AdScheduleAlertText {
  param([Parameter(Mandatory = $true)]$Backing, [string]$SchedTo, [string]$Detected = '', [int]$SupplementRows = 0)
  $store = [string]$Backing.store
  $when = if ($Detected) { " (advanced on $Detected per the schedule's own history)" } else { '' }
  if ($store -eq "Baker's") {
    $recover = "The 08:00 capture reads the ad id in Chrome (pull-browser-stores.py --bakers-ad-id-out) and pulls the list; to recover by hand, open https://www.bakersplus.com/weeklyad on the Saddlecreek store, take the /api/dacs/<guid> it requests, run grocery\pull-bakers-ad-list.ps1 -AdId <guid>, then grocery\pull-regular-bakers-api.ps1, which asks the owed ad terms first."
    if ($Backing.ad_list_gap) {
      $data = "no Baker's weekly ad list covers it (newest: $($Backing.have))"
      $fix = "land this week's ad list. $recover"
    } elseif ($Backing.ad_blind) {
      $data = "its ad list $($Backing.ad_list) could not be checked for asks in this checkout"
      $fix = "re-run this check in the main checkout, where out\regular is present."
    } else {
      $data = "$($Backing.ad_owed) of the $($Backing.ad_total) search term(s) its ad list $($Backing.ad_list) routes were never asked through the Kroger API inside the window"
      $fix = "run grocery\pull-regular-bakers-api.ps1: it asks owed ad terms ahead of the rotation, and a term whose request failed twice stays owed until one lands."
    }
  } else {
    $data = "the newest ad capture on disk is $($Backing.have)"
    $fix = "land this window's ad capture. The walled stores are captured on demand from out\browser-capture-due-<date>.flag, which capture-watchdog watches (the Wednesday browser agent this alert used to name was retired on 2026-08-22)."
  }
  $rowsNote = if ($SupplementRows -gt 0) { "its $SupplementRows sale row(s)" } else { 'its sale rows' }
  if ($store -eq "Baker's") {
    $summary = "REVIEW    $store's schedule says its ad runs to $SchedTo, but $data. The Kroger API prices a sale only when it asks the term, so this week's new Baker's sale items stay OFF the board (coverage lost, prices not stale) until they are asked."
    $body = "ad-schedule.json records $store's current ad window ending $SchedTo$when, but $data.`n`nBaker's sale prices come from the Kroger API, which prices a sale only for a term it asks, and the weekly ad list is how the new ad's sale items get asked ahead of the 7-term rotation. Until they are, those cells fall back to an everyday price or to another store: the loss is coverage, not a stale price, because every stored promo row carries its own ad_to and compare-deals refuses an expired one.`n`nFix: $fix"
    return [pscustomobject]@{ summary = $summary; body = $body }
  }
  $summary = "REVIEW    $store's schedule says its ad runs to $SchedTo, but $data. compare-deals refuses a closed ad, so the lagging capture's sale rows DROP off the board (coverage lost, prices not stale) until a capture lands."
  $body = "ad-schedule.json records $store's current ad window ending $SchedTo$when, but $data.`n`nThe calendar and the capture are written by two different steps and only one ran. compare-deals refuses an ad whose window has closed (Test-AdWindowClosed), so the newest capture ($($Backing.have)) does NOT keep pricing the board after its window ends: $rowsNote DROP off it. The loss is coverage (those cells fall back to an everyday price or to another store), not a stale price.`n`nFix: $fix"
  return [pscustomobject]@{ summary = $summary; body = $body }
}
