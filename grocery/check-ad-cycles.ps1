<#
  check-ad-cycles.ps1 - Runs DAILY (Windows Task Scheduler). Pulls a store's ad only the day AFTER its
  current ad expires, tracks each store's cycle in ad-schedule.json, and keeps the comparison + price
  history fresh when a new ad drops.

  Logic per run:
    * Server stores (Hy-Vee/Aldi/Family Fare): if any is DUE (today >= its next_pull), run the server pull,
      read the live ad windows, and per store:
        - live ad window advanced  -> NEW AD: record the flip, set next_pull = new_to + 1 day.
        - past its 'to' but not reposted -> AWAITING: retry tomorrow.
        - still inside its window -> CURRENT: leave it.
      If any store flipped, re-run compare-deals + update-history so downstream stays current.
    * Browser stores (Baker's/Sam's): can't pull headless -> if DUE, FLAG for a Chrome pull (agent/manual).

  Params: -Today <yyyy-MM-dd> (override for testing), -Force (pull regardless), -NoPull (use latest ads file),
          -NoDownstream (skip compare/history), -ScheduleFile <path> (default ad-schedule.json).
#>
param(
  [string]$Today = "",
  [switch]$Force,
  [switch]$NoPull,
  [switch]$NoDownstream,
  [switch]$NoAlert,
  [switch]$NoPublish,
  [string]$ScheduleFile = ""
)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$OutDir = Join-Path $root 'out'
if (-not $ScheduleFile) { $ScheduleFile = Join-Path $root 'ad-schedule.json' }
$LogFile = Join-Path $root 'ad-cycle-log.txt'
$asof = if ($Today) { ([datetime]$Today).Date } else { (Get-Date).Date }
$asofS = $asof.ToString('yyyy-MM-dd')
function DT([string]$s) { try { return ([datetime]$s).Date } catch { return $null } }
function Log([string]$m) { Add-Content -Path $LogFile -Value (("[" + (Get-Date).ToString('s') + "] ") + $m) }
# Price signature of the current board: sorted id|store|per_unit|type over the latest comparison, hashed.
# Used to re-publish only when a price actually changed (a new ad, a flash sale ending, a mid-cycle fix),
# so the daily pull can run every day without needlessly re-pushing an unchanged page.
function BoardSignature() {
  $cf = Get-ChildItem (Join-Path $OutDir 'comparison-*.json') -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
  if (-not $cf) { return '' }
  $cmp = (Get-Content $cf.FullName -Raw | ConvertFrom-Json).comparison
  $parts = @()
  foreach ($it in $cmp) { foreach ($s in $it.stores) { $parts += ('{0}|{1}|{2}|{3}' -f $it.id, $s.store, $s.per_unit, $s.type) } }
  # Fold each store's CURRENT ad window into the signature so a same-price ad repost with a NEW window still
  # triggers a republish - otherwise a "Sale thru <date>" badge could show an expired date after the window
  # rolls (the badge is recomputed from the ad window at build time).
  try { $sc = Get-Content $ScheduleFile -Raw | ConvertFrom-Json; foreach ($s in @($sc.stores)) { if ($s.current -and $s.current.to) { $parts += ('WIN|{0}|{1}|{2}' -f $s.store, $s.current.from, $s.current.to) } } } catch {}
  # also hash the recipe board (everyday floors + any overlaid ad-sales) so a recipe-item sale starting or
  # ending triggers a republish too.
  try { $rbf = Join-Path $OutDir 'recipe-board.json'; if (Test-Path $rbf) { $rb = (Get-Content $rbf -Raw | ConvertFrom-Json).comparison; foreach ($it in $rb) { foreach ($s in $it.stores) { $parts += ('R|{0}|{1}|{2}|{3}' -f $it.id, $s.store, $s.per_unit, $s.type) } } } } catch {}
  # and the VERIFIED board when present - publish PREFERS it, so a verdicts-only change (a wrong-product
  # winner dropped mid-week with no raw price move) must also count as a board change or it never ships.
  try { if ($cf) { $wkS = (Get-Content $cf.FullName -Raw | ConvertFrom-Json).week_of; $vf = Join-Path $OutDir ("verified-" + $wkS + ".json"); if (Test-Path $vf) { $vb = (Get-Content $vf -Raw | ConvertFrom-Json).comparison; foreach ($it in $vb) { foreach ($s in $it.stores) { $parts += ('V|{0}|{1}|{2}' -f $it.id, $s.store, $s.per_unit) } } } } } catch {}
  $joined = ($parts | Sort-Object) -join ';'
  $md5 = [System.Security.Cryptography.MD5]::Create()
  $bytes = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($joined))
  return ([BitConverter]::ToString($bytes) -replace '-','')
}

$sched  = Get-Content $ScheduleFile -Raw | ConvertFrom-Json
$stores = @($sched.stores)
$summary = @()
$flips = @()

# ---- pull server ads EVERY day (not just on the weekly ad-flip day) so pricing always reflects today's
#      ad dates: a flash/weekend sale that ended, or any mid-cycle correction, is caught the next morning.
#      next_pull is still used below purely to detect a NEW AD WINDOW (for the schedule + history). ----
$serverDue = $false
foreach ($s in $stores) { if ($s.method -eq 'server') { $serverDue = $true } }

# ---- pull live server ad windows if due (retry once; a healthy pull ALWAYS yields >=1 PASS store) ----
$verif = $null
$hardFail = $false
$adsToday = Join-Path $OutDir ("ads-" + $asofS + ".json")
if ($serverDue) {
  $pullOk = $NoPull   # in NoPull test mode we don't judge health
  if (-not $NoPull) {
    for ($attempt=1; $attempt -le 2 -and -not $pullOk; $attempt++) {
      try {
        & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'pull-grocery-ads.ps1') | Out-Null
        # Assert a FRESH, today-dated ads file with >=1 PASS store. If the pull crashed before writing
        # today's file, this stays false (we do NOT trust yesterday's ads-*.json) -> retry -> HARD FAILURE.
        if (Test-Path $adsToday) { $vv = @((Get-Content $adsToday -Raw | ConvertFrom-Json).verification); if (@($vv | Where-Object { $_.status -eq 'PASS' }).Count -gt 0) { $pullOk = $true } }
        Log ("pull attempt $attempt ok=$pullOk")
      } catch { Log ("pull attempt $attempt FAILED: " + $_.Exception.Message) }
    }
    # HARD failure = no current ad data from ANY server store after a retry (API/network down, not "ad not posted yet")
    if (-not $pullOk) {
      $hardFail = $true
      Log "HARD FAILURE: server pull returned no current TODAY data after 2 attempts -> alerting, downstream skipped"
      if (-not $NoAlert) {
        $bdy = "The daily server-side grocery pull (Hy-Vee / Aldi / Family Fare) returned NO current ad data after 2 attempts on $asofS. Likely an API or network issue. The board was left at its last good state - nothing was republished. Check pull-grocery-ads.ps1 and ad-cycle-log.txt on the machine."
        try { & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'send-alert.ps1') -Subject "Grocery pull FAILED (server stores) - $asofS" -Body $bdy | Out-Null } catch { Log ("alert send threw: " + $_.Exception.Message) }
      }
    }
    # Family Fare EVERYDAY column (headless Freshop catalog) - refresh alongside the ad pull; nothing else pulls it. Non-fatal.
    try { & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'pull-regular-familyfare.ps1') | Out-Null; Log 'FF everyday refreshed' } catch { Log ('FF everyday pull threw: ' + $_.Exception.Message) }
  }
  # read verification from TODAY's file (real runs); in -NoPull test mode fall back to the newest ads file
  if (Test-Path $adsToday) { $verif = @((Get-Content $adsToday -Raw | ConvertFrom-Json).verification) }
  elseif ($NoPull) { $af = Get-ChildItem (Join-Path $OutDir 'ads-*.json') -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1; if ($af) { $verif = @((Get-Content $af.FullName -Raw | ConvertFrom-Json).verification) } }
}

# ---- rebuild each store record ----
$newStores = @()
foreach ($s in $stores) {
  $store = [string]$s.store
  $rec = [ordered]@{ store=$store; method=$s.method; cadence_days=$s.cadence_days; current=$s.current; next_pull=$s.next_pull; history=@($s.history) }
  if ($s.PSObject.Properties['note']) { $rec.note = $s.note }

  if ($s.method -eq 'server' -and $serverDue -and $verif) {
    $mine = @($verif | Where-Object { $_.store -eq $store -and $_.status -eq 'PASS' -and $_.ad_to })
    if (@($mine).Count -gt 0) {
      $primary   = $mine | Sort-Object { [datetime]$_.ad_to } | Select-Object -First 1   # soonest-expiring = the weekly cycle
      $liveTo    = [string]$primary.ad_to; $liveFrom = [string]$primary.ad_from
      $recordedTo = if ($s.current) { [string]$s.current.to } else { $null }
      if ((-not $recordedTo) -or ((DT $liveTo) -gt (DT $recordedTo))) {
        # NEW AD detected
        $hist = @($s.history) + ,([ordered]@{ from=$liveFrom; to=$liveTo; detected=$asofS })
        $rec.current   = [ordered]@{ from=$liveFrom; to=$liveTo }
        $rec.history   = $hist
        $rec.next_pull = ((DT $liveTo).AddDays(1)).ToString('yyyy-MM-dd')
        $flips += $store
        $summary += ("NEW AD    {0,-13} {1} -> {2}   next pull {3}" -f $store, $liveFrom, $liveTo, $rec.next_pull)
        Log ("NEW AD $store $liveFrom..$liveTo")
      } elseif ($asof -gt (DT $recordedTo)) {
        # expired but not reposted yet -> retry tomorrow
        $rec.next_pull = $asof.AddDays(1).ToString('yyyy-MM-dd')
        $summary += ("AWAITING  {0,-13} expired {1}, new ad not live yet; retry {2}" -f $store, $recordedTo, $rec.next_pull)
        Log ("AWAITING $store (expired $recordedTo)")
      } else {
        $rec.next_pull = ((DT $recordedTo).AddDays(1)).ToString('yyyy-MM-dd')
        $summary += ("CURRENT   {0,-13} still valid thru {1}" -f $store, $recordedTo)
      }
    }
  }
  elseif ($s.method -eq 'server') {
    $summary += ("waiting   {0,-13} next flip {1}" -f $store, $s.next_pull)
  }
  elseif ($s.method -eq 'browser') {
    if ($s.next_pull -and ($asof -ge (DT $s.next_pull))) {
      $expTo = if ($s.current) { $s.current.to } else { '?' }
      $summary += ("DUE-CHROME {0,-12} ad expired {1} -> needs a browser pull (run the agent)" -f $store, $expTo)
      Log ("DUE-CHROME $store")
    } elseif ($s.next_pull) {
      $summary += ("waiting   {0,-13} next flip {1} (browser)" -f $store, $s.next_pull)
    } else {
      $summary += ("n/a       {0,-13} no ad cycle (national); weekly browser refresh" -f $store)
    }
  }
  $newStores += ,$rec
}

# ---- persist schedule ----
([ordered]@{ updated=$asofS; note=$sched.note; stores=$newStores } | ConvertTo-Json -Depth 8) | Set-Content $ScheduleFile -Encoding UTF8

# ---- browser-refresh watchdog: only the weekly Wednesday Chrome agent can pull the browser stores.
#      If it did not run, its data goes stale and NOTHING headless can refresh it. Alert Brad ONCE/week. ----
if (-not $NoAlert) {
  $dow = [int]$asof.DayOfWeek                  # Sun=0 .. Wed=3 .. Sat=6
  $daysSinceWed = (($dow - 3) + 7) % 7         # 0 if today is Wednesday
  if ($daysSinceWed -ge 1) {                   # Thursday or later -> the Wednesday agent should have run this week
    $lastWed = $asof.AddDays(-$daysSinceWed).Date
    $marker  = Join-Path $OutDir ('browser-stale-' + $lastWed.ToString('yyyy-MM-dd') + '.flag')
    if (-not (Test-Path $marker)) {
      function NewestMtime($glob) { $f = Get-ChildItem $glob -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1; if ($f) { return $f.LastWriteTime } else { return $null } }
      $feeds = [ordered]@{
        "Baker's ad"       = (NewestMtime (Join-Path $OutDir 'bakers\bakers-deals-*.json'))
        "Sam's"            = (NewestMtime (Join-Path $OutDir 'sams\sams-deals-*.json'))
        "Baker's everyday" = (NewestMtime (Join-Path $OutDir 'regular\bakers-regular-*.json'))
        "Hy-Vee everyday"  = (NewestMtime (Join-Path $OutDir 'regular\hyvee-regular-*.json'))
        "Walmart everyday" = (NewestMtime (Join-Path $OutDir 'regular\walmart-regular-*.json'))
        "Aldi everyday"    = (NewestMtime (Join-Path $OutDir 'regular\aldi-regular-*.json'))
      }
      $stale = @()
      foreach ($k in $feeds.Keys) { $m = $feeds[$k]; if (($null -eq $m) -or ($m.Date -lt $lastWed)) { $tag = if ($m) { ' (' + $m.ToString('MM-dd') + ')' } else { ' (missing)' }; $stale += ($k + $tag) } }
      if ($stale.Count -gt 0) {
        $bd = "The weekly Wednesday grocery browser refresh did not run for the week of " + $lastWed.ToString('yyyy-MM-dd') + ". Stale/missing browser feeds: " + ($stale -join ', ') + ". The live page is holding last week's prices for those stores. Open the Claude app and run the grocery-browser-stores-refresh agent."
        & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'send-alert.ps1') -Subject ("Grocery: Wednesday browser refresh MISSED - week of " + $lastWed.ToString('yyyy-MM-dd')) -Body $bd | Out-Null
        # only burn the once-per-week de-dupe marker if the email actually SENT (send-alert exits 1 on
        # failure) - otherwise a transient mail error silently ate the whole week's stale warning.
        if ($LASTEXITCODE -eq 0) { New-Item -ItemType File -Path $marker -Force | Out-Null; Log ("browser-stale alert sent: " + ($stale -join ', ')) } else { Log 'browser-stale alert FAILED to send (will retry next run)' }
        $summary += ("ALERT     Wednesday browser refresh missed - stale: " + ($stale -join ', '))
      }
    }
  }
}

# ---- refresh downstream if a server store flipped ----
# Re-compare DAILY (server ads were just re-pulled) so the board reflects today's ad dates, then re-publish
# ONLY when a price actually changed (new ad, flash sale ended, or a mid-cycle correction) - detected by the
# board price signature, so an unchanged day is a no-op. This is what keeps pricing current relative to ad
# dates every day, not just on the weekly ad flip.
if ($serverDue -and (-not $NoDownstream) -and (-not $hardFail)) {
  $bakers = Get-ChildItem (Join-Path $OutDir 'bakers\bakers-deals-*.json') -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
  $sams   = Get-ChildItem (Join-Path $OutDir 'sams\sams-deals-*.json')     -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
  $args = @('-ExecutionPolicy','Bypass','-File',(Join-Path $root 'compare-deals.ps1'),'-MinStores','1')
  if ($bakers) { $args += @('-BakersFile', $bakers.FullName) }
  if ($sams)   { $args += @('-SamsFile',   $sams.FullName) }
  try {
    $sigBefore = BoardSignature
    & powershell @args | Out-Null
    $cmprc = $LASTEXITCODE
    if ($cmprc -ne 0) {
      # A crashed re-compare must NOT be treated as "board current" - leave the last-good board up and alert.
      Log ("COMPARE FAILED rc=$cmprc - board left at last good, NOT republished")
      $summary += "ERROR     compare-deals failed (rc=$cmprc) - live page left at last good, not updated"
      if (-not $NoAlert) { try { & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'send-alert.ps1') -Subject "Grocery compare FAILED - $asofS" -Body "compare-deals.ps1 exited $cmprc on $asofS. The board was NOT recomputed or republished (left at last good). Check ad-cycle-log.txt." | Out-Null } catch {} }
    } else {
      & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'update-history.ps1') | Out-Null
      & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'sanity-check.ps1') | Out-Null   # exit 1 = flags (expected), not a crash -> guards-<week>.json
      # Keep the product-URL worklist current: after prices move, flag any "See item" link whose board price
      # changed (stale) or whose linked product no longer matches (mismatch), so the weekly browser agent
      # re-resolves it. Headless-safe (detection only); the actual re-resolution needs Chrome. Non-fatal.
      # Re-apply the weekly semantic verdicts (wrong-product drops / de-crowns) to TODAY's fresh board so
      # build/publish's verified-<week> board reflects both the fresh prices AND the wrong-product removals.
      # Deterministic PS (no LLM); only runs when this week's verdicts exist. Non-fatal.
      $cmpNow = Get-ChildItem (Join-Path $OutDir 'comparison-*.json') -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
      if ($cmpNow) { try { $wkNow = (Get-Content $cmpNow.FullName -Raw | ConvertFrom-Json).week_of; if (Test-Path (Join-Path $OutDir ("verify-verdicts-" + $wkNow + ".json"))) { & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'verify-apply.ps1') | Out-Null; Log 'verify-apply re-applied verdicts to fresh board' } } catch { Log ('verify-apply threw: ' + $_.Exception.Message) } }
      # overlay this week's ad-sales onto the everyday recipe-ingredient board (catches recipe items on sale;
      # reverts automatically when a sale ends). MUST run BEFORE resolve-worklist so the link worklist reflects
      # TODAY's recipe board, not yesterday's. Non-fatal - only runs once the recipe rule-set exists.
      try { & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'recipe-overlay.ps1') | Out-Null; Log 'recipe-overlay applied' } catch { Log ('recipe-overlay threw: ' + $_.Exception.Message) }
      # re-cost the 113 recipes from today's board + refresh the hub's Top 5 (only publishes on change). Non-fatal.
      try { & powershell -ExecutionPolicy Bypass -File 'C:\Codex\income\meal-prep\top5-weekly.ps1' | Out-Null; Log 'top5-weekly refreshed' } catch { Log ('top5-weekly threw: ' + $_.Exception.Message) }
      try { & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'resolve-worklist.ps1') | Out-Null } catch { Log ('resolve-worklist threw: ' + $_.Exception.Message) }
      $sigAfter = BoardSignature
      $sigFile  = Join-Path $OutDir 'published-board.sig'
      $prevPub  = if (Test-Path $sigFile) { (Get-Content $sigFile -Raw).Trim() } else { '' }
      # republish when the price/type/ad-window signature moved OR a new ad window flipped (belt-and-suspenders)
      $boardChanged = ($sigAfter -ne $sigBefore) -or ($sigAfter -ne $prevPub) -or (@($flips).Count -gt 0)
      if (@($flips).Count -gt 0) { Log ("downstream refreshed after flips: " + ($flips -join ',')) }

      # ---- REVIEW FLAGS: a likely-wrong in-band price (sanity outlier / WoW) or an unpriced tracked BOGO is
      #      advisory (we still publish so the board stays current) but must NOT be silent. Alert Brad ONCE per
      #      distinct flag-set (de-duped via alerted-flags.sig) so a daily re-run doesn't spam. ----
      $flagParts = @()
      $gf = Get-ChildItem (Join-Path $OutDir 'guards-*.json') -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
      if ($gf) { $gc = @(Get-Content $gf.FullName -Raw | ConvertFrom-Json); foreach ($x in $gc) { $flagParts += ('SANITY|' + $x.commodity + '|' + $x.type + '|' + $x.detail) } }
      $ff = Get-ChildItem (Join-Path $OutDir 'flagged-*.json') -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
      if ($ff) { $mb = @((Get-Content $ff.FullName -Raw | ConvertFrom-Json).multibuy_unpriced); foreach ($m in $mb) { $flagParts += ('MULTIBUY|' + $m.store + '|' + $m.label) } }
      $fsigFile = Join-Path $OutDir 'alerted-flags.sig'
      if ($flagParts.Count -gt 0) {
        $flagSig = (($flagParts | Sort-Object) -join ';')
        Log ("REVIEW FLAGS: " + $flagParts.Count + " -> " + (($flagParts | Select-Object -First 4) -join ' ; '))
        $summary += ("REVIEW    $($flagParts.Count) price flag(s) need eyes (sanity/multibuy) - see guards-/flagged- json")
        $prevFsig = if (Test-Path $fsigFile) { (Get-Content $fsigFile -Raw).Trim() } else { '' }
        if ($flagSig -ne $prevFsig -and -not $NoAlert) {
          $body = "The daily grocery check flagged $($flagParts.Count) price(s) to review on $asofS (these still published; verify they are real):`n`n" + (($flagParts) -join "`n") + "`n`nSee guards-*.json / flagged-*.json in $OutDir ."
          # only record the sig when the email actually SENT (send-alert exits 1 on failure); UTF8 so a
          # non-ASCII char in a flag doesn't corrupt the sig and cause daily re-alerts.
          & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'send-alert.ps1') -Subject "Grocery: $($flagParts.Count) price(s) to review - $asofS" -Body $body | Out-Null
          if ($LASTEXITCODE -eq 0) { Set-Content -Path $fsigFile -Value $flagSig -Encoding UTF8; Log 'review-flag alert sent' } else { Log 'review-flag alert FAILED to send (will retry next run)' }
        }
      } else {
        # clean day: clear the dedupe sig so the SAME flag genuinely recurring in a future week re-alerts.
        if (Test-Path $fsigFile) { Remove-Item $fsigFile -ErrorAction SilentlyContinue }
      }

      # AUTO-PUBLISH only when the board changed. publish-deals-page.ps1 self-gates on coverage, rebuilds
      # (recomputing the sale-window badges), and republishes preserving visibility.
      if (-not $boardChanged) {
        Log 'no price change today - board already current, nothing republished'
        $summary += 'CURRENT   no price change today - live page already current'
      } elseif (-not $NoPublish) {
        & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'publish-deals-page.ps1') | Out-Null
        $pubrc = $LASTEXITCODE
        if ($pubrc -eq 0)     { Set-Content -Path $sigFile -Value $sigAfter -Encoding ASCII; Log ('AUTO-PUBLISH: live page updated (price change' + $(if (@($flips).Count -gt 0) { '/new ad' } else { ' mid-cycle' }) + ')'); $summary += 'PUBLISHED live page updated (price change detected)' }
        elseif ($pubrc -eq 2) {
          Log 'AUTO-PUBLISH HELD: coverage gate failed - live page NOT updated'
          $summary += 'HELD      coverage gate failed - live page NOT updated (a store pull is thin/missing)'
          if (-not $NoAlert) { try { & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'send-alert.ps1') -Subject "Grocery page HELD (coverage) - $asofS" -Body "A refreshed board failed the coverage gate on $asofS (a store's pull produced too few commodities), so the live page was NOT updated - nothing bad was published. Check the store pulls." | Out-Null } catch { Log ('held-alert threw: ' + $_.Exception.Message) } }
        }
        else { Log "AUTO-PUBLISH ERROR (rc=$pubrc) - Ghost upsert or build failed; live page NOT updated"; $summary += 'ERROR     auto-publish failed (page NOT updated) - see ad-cycle-log.txt'; if (-not $NoAlert) { try { & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'send-alert.ps1') -Subject "Grocery publish FAILED (rc=$pubrc) - $asofS" -Body "publish-deals-page.ps1 returned $pubrc on $asofS (Ghost upsert or page build failed). The live page was NOT updated with today's price change. Check ad-cycle-log.txt." | Out-Null } catch {} } }
      }
    }
  } catch { Log ("downstream FAILED: " + $_.Exception.Message) }
} elseif ($hardFail -and (-not $NoDownstream)) {
  Log 'HARD FAILURE - skipped re-compare/publish; board left at last good (alert already sent)'
  $summary += 'HELD      server pull hard-failed - board left at last good, not republished'
}

# ---- report ----
$pullNote = if ($serverDue) { '   (server pull ran)' } else { '   (nothing due)' }
Write-Output ("Ad-cycle check  -  " + $asofS + $pullNote)
Write-Output ('-'*74)
foreach ($line in $summary) { Write-Output $line }
if (@($flips).Count -gt 0) { Write-Output ""; Write-Output ("Flipped this run: " + ($flips -join ', ') + "  -> comparison + price history refreshed") }
Log ("run complete; flips=" + (@($flips).Count))
