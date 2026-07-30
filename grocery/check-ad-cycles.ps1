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
# LOGGING MUST NEVER KILL THE RUN (2026-07-28). $ErrorActionPreference is 'Stop', so a plain Add-Content
# turns any transient lock on the log file into a TERMINATING error: the pipeline dies mid-flight, and the
# one thing that would explain why - the log - is the thing that failed, so it stops with no reason recorded.
# Proved the hard way twice in one afternoon by a `tail -f` on this file; an editor with the log open, a
# backup, or an antivirus scan does exactly the same. Retry briefly, then carry on WITHOUT the line: a lost
# log line is a small loss, an abandoned board pull halfway through publishing is a real one.
function Log([string]$m) {
  $line = ("[" + (Get-Date).ToString('s') + "] ") + $m
  for ($i = 0; $i -lt 5; $i++) {
    try { Add-Content -Path $LogFile -Value $line -ErrorAction Stop; return } catch { Start-Sleep -Milliseconds 120 }
  }
  try { Write-Host ('[log locked, not written] ' + $line) } catch {}
}
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
    # Family Fare EVERYDAY column (headless Freshop catalog) - refresh alongside the ad pull; nothing else pulls it.
    # NOTE: this writes ALL search results and lets compare-deals apply the full include/exclude+per-unit filter and
    # pick the cheapest VALID one. Do NOT swap in a "pick one cheapest here" researcher - pre-filtering with a lesser
    # rule dropped FF from milk/butter/blueberries (it picked Butter Beans / Blueberry Soda). Non-fatal.
    try { & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'pull-regular-familyfare.ps1') | Out-Null; Log 'FF everyday refreshed' } catch { Log ('FF everyday pull threw: ' + $_.Exception.Message) }

    # HY-VEE, DAILY. Hy-Vee used to be the one priced store with no automated pull: a human refreshed it through
    # a browser, it went stale in between, and the capture read basePrice (the REGULAR price) rather than what
    # the store actually charges. That is how sirloin sat on the board at $13.99/lb while Omaha #01 was charging
    # $11.99, and how ~110 live markdowns went unseen. Its GraphQL takes storeId as a request VARIABLE (not a
    # cookie), so it runs headless right here, every day, like Family Fare's. Non-fatal: a bad run keeps the
    # last good file (throttle-wipeout guard) and the price guards still gate the publish.
    try { & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'pull-regular-hyvee.ps1') | Out-Null; Log 'Hy-Vee everyday refreshed (current shelf price, Omaha #01)' } catch { Log ('Hy-Vee pull threw: ' + $_.Exception.Message) }
    # Baker's via Kroger's sanctioned public API (2026-07-24): daily headless current+promo prices for the
    # Saddlecreek store, replacing the browser scan that needed the Claude app awake. Credentials are the
    # gitignored grocery\.krogerkey locally (env vars in CI); WHERE THE KEY IS ABSENT (the cloud backup
    # runner, unless Brad adds the secrets) the pull throws, we log it, and the newest committed capture
    # keeps serving - same graceful degradation as any other store having an off day. The link snapshots
    # refresh from the SAME pull (the Hy-Vee lesson) so guard 4 compares like against like.
    try {
      & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'pull-regular-bakers-api.ps1') | Out-Null
      if ($LASTEXITCODE -eq 0) {
        & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'refresh-bakers-links.ps1') | Out-Null
        Log "Baker's everyday+promo refreshed via Kroger API (Saddlecreek) + link snapshots synced"
      } else { Log ("Baker's API pull rc=$LASTEXITCODE (thin or failed) - keeping newest existing capture") }
    } catch { Log ("Baker's API pull threw: " + $_.Exception.Message + ' - keeping newest existing capture') }
    # and re-point Hy-Vee's stored link snapshots at those same fresh numbers, so the board and its "See item"
    # link quote one number. Skip this and yesterday's snapshots become override pins that drag the board back.
    try { & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'refresh-hyvee-links.ps1') | Out-Null; Log 'Hy-Vee link snapshots refreshed' } catch { Log ('Hy-Vee link refresh threw: ' + $_.Exception.Message) }
    # FF PULL-COMPLETENESS GUARD: catch a term the Freshop pull silently dropped (rate-limit -> 0 items) for a
    # product FF actually carries (the 2026-07-13 ground-pork bug; coverage-gaps can't see a never-pulled item).
    try {
      $fcArgs = @('-ExecutionPolicy','Bypass','-File',(Join-Path $root 'audit-ff-carry.ps1'),'-OutDir',$OutDir)
      if (-not $NoAlert) { $fcArgs += '-Alert' }
      & powershell @fcArgs | ForEach-Object { Log ('ff-carry: ' + $_) }
    } catch { Log ('ff-carry guard threw: ' + $_.Exception.Message) }
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
      # THE FEED LIST LIVES IN ONE PLACE: browser-refresh-due.ps1. This used to carry its own copy of the same
      # six globs and the same mtime comparison, and the two drifted exactly as that class always does - neither
      # listed FAREWAY, so when its weekly sweep was skipped on 2026-07-29 the pre-run gate said FRESH and this
      # alert could not name the store either. Sourcing the definition means a store added to the gate is
      # automatically watched by the alert. (Same fix shape as the pu-lib "1/2 gal" divergence.)
      . (Join-Path $root 'browser-feeds-lib.ps1')
      $feeds = Get-BrowserFeedDates -OutDir $OutDir
      $stale = @()
      foreach ($k in $feeds.Keys) { $m = $feeds[$k]; if (($null -eq $m) -or ($m.Date -lt $lastWed)) { $tag = if ($m) { ' (' + $m.ToString('MM-dd') + ')' } else { ' (missing)' }; $stale += ($k + $tag) } }
      if ($stale.Count -gt 0) {
        $bd = "The weekly Wednesday grocery browser refresh did not run for the week of " + $lastWed.ToString('yyyy-MM-dd') + ". Stale/missing browser feeds: " + ($stale -join ', ') + ". The live page is holding last week's prices for those stores. Open the Claude app and run the grocery-browser-stores-refresh agent. While in the warm store tabs, ALSO close any browser-store no-link gaps: run build-chips-from-tileintegrity.ps1 for the chip list (reads out\tile-integrity.json, all stores), then paste hyvee/browser-link-resolve.js and BLR.run('<store>', chips) per store (board-match, skips sponsored/wrong-size), save to out\url-inputs\store-<store>-urls.json, and merge -> stamp -> prune-bad-links -Tol 0.32 -> guards -> publish -> archive the url-inputs file. Family Fare's MISSING links now self-heal in the daily job (fix-links-ff, 30 Freshop calls/day) and Hy-Vee's link PRICES self-heal (refresh-hyvee-links) - but nothing headless can ADD a Hy-Vee/Aldi/Baker's/Walmart/Sam's link, so those no-link chips need this browser pass. Check out\tile-integrity.json for the current per-store count. IMPORTANT: the Walmart capture must run the FULL commodity worklist (every commodity-search.json term (count the file, 526 as of 2026-07-29)) - a core-staples subset is absorbed by the union but leaves the comprehensive-capture clock running (audit-walmart-fullpull warns from day 10 of 14)."
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
  $fareway = Get-ChildItem (Join-Path $OutDir 'fareway\fareway-deals-*.json') -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
  $args = @('-ExecutionPolicy','Bypass','-File',(Join-Path $root 'compare-deals.ps1'),'-MinStores','1')
  if ($bakers)  { $args += @('-BakersFile',  $bakers.FullName) }
  if ($fareway) { $args += @('-FarewayFile', $fareway.FullName) }
  # Sam's is deliberately NOT pinned here. Its club catalog is CAPTCHA-walled, so each capture only covers the
  # categories that run got through - pinning "the newest file" made every night's board only as broad as the
  # last partial capture (the 07-15 Omaha capture covered 118 commodities where 07-08 covered 251: 167 priced
  # cells vanished, chicken-breast among them). compare-deals loads EVERY capture inside its age window and
  # lets the freshest one that covers a commodity win it, so leaving -SamsFile off is what keeps coverage whole.
  # "Newest file wins" lived in two places; this was the copy that would have silently overridden the fix.
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
      # BANK THE VERIFIED BOARD, NOT THE RAW ONE (2026-07-30). This ran update-history against the raw
      # comparison that compare-deals had just written - the exact bug fixed in the WEEKLY path on 2026-07-29
      # and left in place here, so the daily job kept doing it every single day.
      # Why it matters: the week's "cheapest" is written into price-history BEFORE the semantic verify drops
      # wrong-product winners, so every one of them sets a RECORD LOW on its way out (strawberries $0.0833
      # from an applesauce, honey $0.1244 from hot dog buns). record_low is what the buy/wait badge reads, and
      # update-history's compaction deliberately keeps each old week's MINIMUM forever - so a corrupt low
      # never ages out on its own. It has to be hand-purged, which is what purge-bad-lows.ps1 is for.
      # If the week has a verdict file, apply it and bank THAT. If it does not, no product has been judged, so
      # the raw board IS the verified board and banking it directly is equivalent rather than a shortcut.
      $histTarget = $null
      try {
        $cmpH = Get-ChildItem (Join-Path $OutDir 'comparison-*.json') -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
        if ($cmpH) {
          $wkH = [string](Get-Content $cmpH.FullName -Raw | ConvertFrom-Json).week_of
          if ($wkH -and (Test-Path (Join-Path $OutDir ("verify-verdicts-" + $wkH + ".json")))) {
            # -MinStores 1 so the ~24 single-store long-tail commodities keep their history even though
            # MinStores 2 keeps them off the published page - same reasoning as weekly-post-capture.
            & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'verify-apply.ps1') -MinStores 1 -OutFile 'verified-history.json' | Out-Null
            $vh = Join-Path $OutDir 'verified-history.json'
            if (Test-Path $vh) { $histTarget = $vh }
            else { Log 'verify-apply produced no verified-history.json - banking history from the RAW board this run' }
          }
        }
      } catch { Log ('verify-for-history threw, banking from the raw board: ' + $_.Exception.Message) }
      if ($histTarget) {
        & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'update-history.ps1') -CompareFile $histTarget | Out-Null
        Log 'history banked from the VERIFIED board'
      } else {
        & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'update-history.ps1') | Out-Null
        Log 'history banked from the raw board (no verdict file for this week - nothing judged, so raw == verified)'
      }
      & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'sanity-check.ps1') | Out-Null   # exit 1 = flags (expected), not a crash -> guards-<week>.json
      # NOTE: the coverage-REGRESSION check (a store quietly shrinking between boards) is NOT run here. It is a
      # hard invariant, so it lives in guards.ps1 where a failure actually stops the publish. Setting $hardFail
      # at this point would not: the publish below gates on $guardsBlocked, and $hardFail was already read at the
      # top of this block - so it would log "publish HELD" while the board shipped anyway.
      # ---- COVERAGE GAP GUARD: a store SILENTLY dropped from a commodity it actually carries (a too-strict
      # include regex not matching that store's real product name - the Hy-Vee "Pork Loin TOP Loin Chops" bug).
      # audit-coverage-gaps.ps1 scans each missing store's raw pull for a loosened-include match; a hit = fix the
      # commodity's include (or allowlist it). Alert Brad ONCE per distinct gap-set (signature de-dup) so it is
      # never silent but never spams. Advisory (we still publish the current board).
      try {
        & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'audit-coverage-gaps.ps1') | Out-Null
        $cg = try { Get-Content (Join-Path $OutDir 'coverage-gaps.json') -Raw | ConvertFrom-Json } catch { $null }
        if ($cg -and [int]$cg.gap_count -gt 0) {
          $cgSig = (@($cg.gaps | ForEach-Object { $_.commodity + '|' + $_.store } | Sort-Object) -join ';')
          $cgF = Join-Path $OutDir 'coverage-gap-alert.sig'
          $cgPrev = if (Test-Path $cgF) { ([string](Get-Content $cgF -Raw)).Trim() } else { '' }
          $cgList = (@($cg.gaps | ForEach-Object { $_.commodity + ' @ ' + $_.store }) -join '; ')
          Log ("coverage-gaps: $($cg.gap_count) store(s) carry an item but are off the board - $cgList")
          $summary += "REVIEW    coverage gaps: $($cg.gap_count) store(s) dropped despite carrying the item - see coverage-gaps.json"
          if ($cgSig -ne $cgPrev -and (-not $NoAlert)) {
            try { & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'send-alert.ps1') -Subject "Grocery: $($cg.gap_count) store(s) dropped from a commodity they carry - $asofS" -Body "audit-coverage-gaps found stores that HAVE a matching product but are missing from the board (usually a too-strict include regex): $cgList. Fix that commodity's include in commodities.json (or add a reviewed exception to coverage-gap-allowlist.json). Details: grocery/out/coverage-gaps.json." | Out-Null
                  if ($LASTEXITCODE -eq 0) { Set-Content -Path $cgF -Value $cgSig -Encoding UTF8; Log 'coverage-gap alert sent' } } catch { Log ('coverage-gap alert threw: ' + $_.Exception.Message) }
          } else { Log 'coverage-gaps unchanged since last alert - not re-alerting' }
        } elseif ($cg -and @($cg.stores_not_scanned | Where-Object { $_ }).Count) {
          $ns = (@($cg.stores_not_scanned | Where-Object { $_ }) -join ', ')
          Log ("coverage-gaps BLIND for: " + $ns + " - zero raw products parsed; those stores were never checked")
          $summary += "REVIEW    coverage-gaps scanned 0 products for $ns - the 'no gaps' result does not cover those stores"
        } else { if (Test-Path (Join-Path $OutDir 'coverage-gap-alert.sig')) { Remove-Item (Join-Path $OutDir 'coverage-gap-alert.sig') -ErrorAction SilentlyContinue } }
      } catch { Log ('coverage-gap guard threw: ' + $_.Exception.Message) }
      # ---- MATCHING-SOUNDNESS GUARD: a WRONG product landing in a commodity, or a rule change quietly moving/
      # dropping an existing product vs the reviewed baseline (the 2026-07-13 matching-audit class). No other
      # guard catches theft-IN. audit-match-soundness -Alert self-dedups and emails on a NEW issue-set; a
      # MOVED/DROPPED also makes it exit 2 so the publish gate holds. Advisory here (the daily board still ships).
      try {
        $msArgs = @('-ExecutionPolicy','Bypass','-File',(Join-Path $root 'audit-match-soundness.ps1'),'-OutDir',$OutDir)
        if (-not $NoAlert) { $msArgs += '-Alert' }
        & powershell @msArgs | ForEach-Object { Log ('match-soundness: ' + $_) }
        if ($LASTEXITCODE -eq 2) { $summary += 'REVIEW    commodity matching changed vs baseline (a product MOVED/DROPPED) - see out\audit\soundness-report.json; publish will HOLD until reviewed + audit-match-soundness.ps1 -Accept' }
      } catch { Log ('match-soundness guard threw: ' + $_.Exception.Message) }
      # ---- CATEGORY-COVERAGE GUARD: a commodity filed into NO category renders in no department/filter (invisible).
      # HARD publish gate + daily alert so adding a new item can never silently skip a filter.
      try {
        $ccArgs = @('-ExecutionPolicy','Bypass','-File',(Join-Path $root 'audit-category-coverage.ps1'),'-OutDir',$OutDir)
        if (-not $NoAlert) { $ccArgs += '-Alert' }
        & powershell @ccArgs | ForEach-Object { Log ('category-coverage: ' + $_) }
        if ($LASTEXITCODE -eq 2) { $summary += 'REVIEW    a commodity is in no category (renders in no filter) - see out\category-coverage-report.json; publish will HOLD until it is filed into a category' }
      } catch { Log ('category-coverage guard threw: ' + $_.Exception.Message) }
      # ---- STORE-REGISTRY GUARD (2026-07-26): a hardcoded store list drifting from stores.json (the
      # publish-store-guide/publish-deals-page Fareway class - a store silently missing from ONE surface).
      # Advisory: alerts + summary, board still ships (drift is a surface bug, not a data bug).
      try {
        $srArgs = @('-ExecutionPolicy','Bypass','-File',(Join-Path $root 'audit-store-registry.ps1'))
        if (-not $NoAlert) { $srArgs += '-Alert' }
        & powershell @srArgs | ForEach-Object { Log ('store-registry: ' + $_) }
        if ($LASTEXITCODE -eq 2) { $summary += 'REVIEW    store-registry drift: a hardcoded store list disagrees with stores.json - fix the script or document the subset in stores.json allowed_subsets' }
      } catch { Log ('store-registry guard threw: ' + $_.Exception.Message) }
      # ---- SALE-FALLBACK GUARD: an on-sale cell with NO everyday item to revert to VANISHES when the sale ends.
      # audit-sale-fallback flags them; FF self-heals daily (researched above), browser-store gaps go to
      # research-worklist.json for the weekly agent to research the next-cheapest everyday item. De-duped alert.
      try {
        & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'audit-sale-fallback.ps1') | Out-Null
        $sf = try { Get-Content (Join-Path $OutDir 'sale-fallback-gaps.json') -Raw | ConvertFrom-Json } catch { $null }
        if ($sf -and [int]$sf.gap_count -gt 0) {
          $sfSig = (@($sf.gaps | ForEach-Object { $_.commodity + '|' + $_.store } | Sort-Object) -join ';')
          $sfF = Join-Path $OutDir 'sale-fallback-alert.sig'
          $sfPrev = if (Test-Path $sfF) { ([string](Get-Content $sfF -Raw)).Trim() } else { '' }
          $sfList = (@($sf.gaps | ForEach-Object { $_.commodity + ' @ ' + $_.store }) -join '; ')
          Log ("sale-fallback: $($sf.gap_count) on-sale cell(s) with no everyday fallback - $sfList")
          $summary += "REVIEW    sale-fallback: $($sf.gap_count) on-sale cell(s) would vanish when the sale ends - see sale-fallback-gaps.json"
          if ($sfSig -ne $sfPrev -and (-not $NoAlert)) {
            try { & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'send-alert.ps1') -Subject "Grocery: $($sf.gap_count) on-sale item(s) have no everyday fallback - $asofS" -Body "These commodity+store cells are on SALE with no everyday item to revert to, so the store DROPS OFF that commodity when the sale ends: $sfList. Browser stores are queued in grocery/out/research-worklist.json for the weekly agent to research the next-cheapest everyday item; Family Fare self-heals daily." | Out-Null
                  if ($LASTEXITCODE -eq 0) { Set-Content -Path $sfF -Value $sfSig -Encoding UTF8; Log 'sale-fallback alert sent' } } catch { Log ('sale-fallback alert threw: ' + $_.Exception.Message) }
          } else { Log 'sale-fallback gaps unchanged - not re-alerting' }
        } else { if (Test-Path (Join-Path $OutDir 'sale-fallback-alert.sig')) { Remove-Item (Join-Path $OutDir 'sale-fallback-alert.sig') -ErrorAction SilentlyContinue } }
      } catch { Log ('sale-fallback guard threw: ' + $_.Exception.Message) }
      # Refresh the per-item sale-window log (sale price + start/end dates from the fresh board) so the daily
      # Baker's guard fires only when a sale actually reverts/starts, not blindly. Headless-safe, non-fatal.
      try { & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'build-sale-windows.ps1') | Out-Null; Log 'sale-windows refreshed' } catch { Log ('build-sale-windows threw: ' + $_.Exception.Message) }
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
      # UNIFIED ENGINE (2026-07-26 consolidation): re-cost the whole catalog from today's boards into
      # db\costed.json, then recompute the v2 per-serving manifest (everyday + cheapest whole-package)
      # that top5-weekly reads. MUST run before top5-weekly or per_serving falls back to the legacy
      # basis. Feed path = the local smp-feed (regenerated later in this same sequence; one-day lag on
      # feed-only movements, same as the retired per-run flow). Non-fatal.
      try { & powershell -ExecutionPolicy Bypass -File (Join-Path (Split-Path $root -Parent) 'meal-prep\engine\cost-recipes.ps1') | Out-Null; Log 'engine cost-recipes refreshed db\costed' } catch { Log ('engine cost-recipes threw: ' + $_.Exception.Message) }
      # COST-FLAG ALERT (2026-07-26 scale hardening): an unpriced ingredient line silently makes a recipe
      # look CHEAPER (the line is dropped from the batch cost). cost-recipes records these to db\cost-flags.txt
      # but nothing read it. Alert on a NEW flag-set (signature de-dup so a persistent flag does not spam).
      try {
        $cfFile = Join-Path (Split-Path $root -Parent) 'meal-prep\db\cost-flags.txt'
        $cf = if (Test-Path $cfFile) { ([string](Get-Content $cfFile -Raw)).Trim() } else { '' }
        if ($cf) {
          $cfLines = @($cf -split "`n" | Where-Object { $_.Trim() })
          Log ("cost-flags: $($cfLines.Count) unpriced recipe line(s) - a recipe is priced too cheap; see db\cost-flags.txt")
          $summary += "REVIEW    cost-flags: $($cfLines.Count) unpriced recipe line(s) - a bid lost its price; recipe reads too cheap (db\cost-flags.txt)"
          $cfSig = [BitConverter]::ToString([Security.Cryptography.MD5]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes(($cfLines | Sort-Object) -join ';'))) -replace '-',''
          $cfSigF = Join-Path $OutDir 'cost-flags-alert.sig'
          $cfPrev = if (Test-Path $cfSigF) { ([string](Get-Content $cfSigF -Raw)).Trim() } else { '' }
          if ($cfSig -ne $cfPrev -and (-not $NoAlert)) {
            try { & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'send-alert.ps1') -Subject "Recipe pricing: $($cfLines.Count) unpriced ingredient line(s)" -Body ("engine\cost-recipes.ps1 could not price some recipe ingredient lines this run - each dropped line makes that recipe's cost read LOWER than reality (usually a bid pointing at a renamed/removed board commodity). Fix the bid in db\ingredients.json or register the commodity. Lines: " + (($cfLines | Select-Object -First 15) -join ' | ')) | Out-Null; if ($LASTEXITCODE -eq 0) { Set-Content $cfSigF -Value $cfSig -Encoding ASCII } } catch {}
          }
        } elseif (Test-Path (Join-Path $OutDir 'cost-flags-alert.sig')) { Remove-Item (Join-Path $OutDir 'cost-flags-alert.sig') -ErrorAction SilentlyContinue }
      } catch { Log ('cost-flag alert threw: ' + $_.Exception.Message) }
      # drift guard: recipes-db index vs db\recipes specs vs db\ingredients (2026-07-26). Non-fatal; alerts.
      try {
        & powershell -ExecutionPolicy Bypass -File (Join-Path (Split-Path $root -Parent) 'meal-prep\engine\audit-db-agreement.ps1') | Out-Null
        if ($LASTEXITCODE -ne 0) {
          Log 'db-agreement guard found DRIFT (see its output)'
          try { & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'send-alert.ps1') -Subject "Recipe db drift (index vs specs)" -Body "meal-prep\engine\audit-db-agreement.ps1 found drift between recipes-db.json and db\recipes specs (or missing db\ingredients items). Run it for the list; fix the lagging side." | Out-Null } catch {}
        } else { Log 'db-agreement guard: clean' }
      } catch { Log ('db-agreement guard threw: ' + $_.Exception.Message) }
      # compute-v2 now SKIPS bad recipes and exits 1 with the list (was: throw -> whole manifest stale,
      # and a child exit-1 does NOT raise in this parent, so the old code logged success falsely). Check
      # the exit code explicitly and alert on any skipped recipe.
      try {
        $cv2 = & powershell -ExecutionPolicy Bypass -File (Join-Path (Split-Path $root -Parent) 'meal-prep\pipeline\compute-v2-perserving.ps1') -FeedPath (Join-Path $OutDir 'smp-feed.json') 2>&1
        if ($LASTEXITCODE -ne 0) {
          $cv2Bad = @($cv2 | Where-Object { $_ -match '^\s+\S' -or $_ -match 'SKIPPED' })
          Log ('compute-v2 SKIPPED recipe(s) with bad cost data: ' + (($cv2Bad | Select-Object -First 6) -join ' | '))
          $summary += 'REVIEW    v2 per-serving manifest skipped recipe(s) with bad cost data - top5/rotation may be stale for them (see compute-v2 output)'
          if (-not $NoAlert) { try { & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'send-alert.ps1') -Subject "Recipe per-serving manifest: skipped recipe(s)" -Body ("compute-v2-perserving.ps1 could not compute per-serving cost for some recipes and skipped them (the rest still updated). Their top5/rotation/site numbers are stale until fixed. Detail: " + (($cv2Bad | Select-Object -First 15) -join ' | ')) | Out-Null } catch {} }
        } else { Log 'v2 per-serving manifest recomputed' }
      } catch { Log ('compute-v2-perserving threw: ' + $_.Exception.Message) }
      # DERIVED ingredient-map refresh (2026-07-26): regenerate meal-prep\ingredient-map.json from the spec
      # scaler payloads + live feed (it was a hand-authored file frozen since 07-07, missing 58 items). Runs
      # BEFORE top5 (which reads it for sale badges); dinner/protein tool builders read it on their own runs.
      try { & powershell -ExecutionPolicy Bypass -File (Join-Path (Split-Path $root -Parent) 'meal-prep\pipeline\regenerate-ingredient-map.ps1') | Out-Null; Log 'ingredient-map regenerated (derived from specs + feed)' } catch { Log ('regenerate-ingredient-map threw: ' + $_.Exception.Message) }
      # re-cost the recipes from today's board + refresh the hub's Top 5 (only publishes on change). Non-fatal.
      # Brad's final call 2026-07-25: the ORIGINAL SMP-TOP5 hub section stays (he preferred it over the
      # green free-week grid, which was removed same day). The free ROTATION still runs below - it just
      # renders nothing on the hub; the Top 5 section is the display.
      try { & powershell -ExecutionPolicy Bypass -File (Join-Path (Split-Path $root -Parent) 'meal-prep\top5-weekly.ps1') | Out-Null; Log 'top5-weekly refreshed' } catch { Log ('top5-weekly threw: ' + $_.Exception.Message) }
      # Free-dinner rotation (Brad, 2026-07-25): top 5 cheapest dinners per protein go FREE for the board
      # week; they revert to members-only when the week re-ranks them. Runs daily right after re-costing but
      # no-ops until the board week (or the set) changes, so flips happen on the ad flip. Non-fatal.
      try { & powershell -ExecutionPolicy Bypass -File (Join-Path (Split-Path $root -Parent) 'meal-prep\rotate-free-dinners.ps1') 2>&1 | ForEach-Object { Log ('free-rotation: ' + $_) } } catch { Log ('rotate-free-dinners threw: ' + $_.Exception.Message) }
      try { & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'export-feed.ps1') | Out-Null; Log 'smp-feed exported' } catch { Log ('export-feed threw: ' + $_.Exception.Message) }
      # price alerts: email label:alert-<id> subscribers when an item hits a tracked low (self-gates via alert-state.json)
      try { $paOut = & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'send-price-alerts.ps1'); Log ('price-alerts: ' + (@($paOut)[-1])) } catch { Log ('send-price-alerts threw: ' + $_.Exception.Message) }
      try { & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'resolve-worklist.ps1') | Out-Null } catch { Log ('resolve-worklist threw: ' + $_.Exception.Message) }
      # ---- CLOSE FAMILY FARE'S NO-LINK GAP, A LITTLE EVERY DAY. -------------------------------------------
      # resolve-worklist above only DETECTS; it has never added a link. The note further up claiming "the API
      # stores already self-heal in the daily job" was half true: refresh-hyvee-links re-points Hy-Vee's price
      # SNAPSHOTS, but nothing here ever filled a MISSING link. That is why 58 priced Family Fare tiles were
      # published with no "See item" link at all.
      # Family Fare is the one store resolvable without a browser (Freshop REST). Its documented budget is
      # ~40 calls before it 400s everything, so this takes 30/day and no more - the backlog grinds down over a
      # few days and then stays at zero as new items appear. Two steps because the resolver splits plan from
      # apply: the plan does the searching, -Apply writes it with zero network calls.
      # Safety: it links ONLY when the found product's name matches the board's own item AND its per-unit
      # equals the board's. Anything less confident is refused and left exactly as it was, because a link that
      # disagrees with the price does not fix the tile - it just moves the lie somewhere a shopper will find it.
      # Non-fatal, and guards still gate the publish.
      # ---- DERIVE LINKS FROM THE PRICE ROWS, BEFORE ANY SEARCH. -------------------------------------------
      # A price was fetched FROM a product; that product's id/URL is on the row. Deriving the link from the same
      # record the board priced makes price and link ONE fact that cannot drift. Searching the store to re-find
      # the product is a SECOND pipeline for the same fact, and every wrong link we have ever shipped came from
      # the two disagreeing ("Hy Vee Almondmilk" priced, "Blue Diamond Almond Breeze" linked).
      # This runs FIRST so the searchers only ever work on what identity could not cover.
      try {
        $dlOut = & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'derive-links-from-prices.ps1') -Apply
        Log ('derive-links-from-prices: ' + ((@($dlOut) | Where-Object { $_ -match 'APPLIED' })[-1]))
      } catch { Log ('derive-links-from-prices threw: ' + $_.Exception.Message) }
      try {
        & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'audit-tile-integrity.ps1') -Quiet | Out-Null
        if ($LASTEXITCODE -eq 3) { Log 'tile-integrity BLIND (zero links graded) - the link layer is empty/unreadable; fix-links-ff is about to run against nothing' }
        & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'fix-links-ff.ps1') -Fresh -MaxCalls 30 | Out-Null
        $ffOut = & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'fix-links-ff.ps1') -Apply
        Log ('family-fare link fill: ' + (@($ffOut | Where-Object { $_ -match 'APPLIED' })[-1]))
      } catch { Log ('fix-links-ff threw: ' + $_.Exception.Message) }
      # ---- NEVER SHIP A LINK WE CANNOT PROVE. --------------------------------------------------------------
      # Brad's bar is 100% ACCURATE, and accuracy and coverage are different promises. A tile with a price and
      # no link is incomplete; a tile whose link opens a DIFFERENT product is a lie - the shopper clicks, sees
      # $4.99 where we said $2.98, and concludes the board inflates its deals. Prices move daily, links go
      # stale, and merge-product-urls can resurrect old ones, so this has to run EVERY day, not once.
      # It removes any link that is not positively verified against the board (wrong product, wrong price,
      # unverifiable per-unit, or no price to check). The tile falls back to a price with no link, which is
      # honest. name-drift must run FIRST - it is the product-identity check the pruner reads.
      try {
        & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'audit-name-drift.ps1') | Out-Null
        if ($LASTEXITCODE -eq 3) { Log 'name-drift BLIND: examined ZERO cells - its count=0 output is not clean; prune-bad-links and the builder link suppression are running with no product-identity input'; $summary += 'REVIEW    audit-name-drift examined ZERO cells (product-urls/board mismatch) - wrong-product links are unguarded this run' }
        # -Tol 0.32, SAME as the repair path below and as guard 4's factor rule (>=1.5x / <=0.67x). I first
        # wired this with the default 2%, which deletes a RIGHT-product link the moment the store nudges its
        # price - eroding coverage a little every day to enforce a threshold the accuracy gate itself does not
        # use. One tolerance, everywhere: a link is removed for being a different PRODUCT (any drift counts as
        # a factor error), never for its snapshot being a few cents old.
        $pbOut = & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'prune-bad-links.ps1') -Tol 0.32
        Log ('prune-bad-links: ' + ((@($pbOut) | Where-Object { $_ -match 'DROPPED' }) -join ' | '))
      } catch { Log ('prune-bad-links threw: ' + $_.Exception.Message) }
      $sigAfter = BoardSignature
      $sigFile  = Join-Path $OutDir 'published-board.sig'
      $prevPub  = if (Test-Path $sigFile) { ([string](Get-Content $sigFile -Raw)).Trim() } else { '' }
      # republish when the price/type/ad-window signature moved OR a new ad window flipped (belt-and-suspenders)
      $boardChanged = ($sigAfter -ne $sigBefore) -or ($sigAfter -ne $prevPub) -or (@($flips).Count -gt 0)
      if (@($flips).Count -gt 0) { Log ("downstream refreshed after flips: " + ($flips -join ',')) }

      # ---- REVIEW FLAGS: a likely-wrong in-band price (sanity outlier / WoW) or an unpriced tracked BOGO is
      #      advisory (we still publish so the board stays current) but must NOT be silent. Alert Brad ONCE per
      #      distinct flag-set (de-duped via alerted-flags.sig) so a daily re-run doesn't spam. ----
      $flagParts = @()
      # STABLE KEYS, deliberately excluding prices (2026-07-28). See the differential alert block below:
      # a flag's identity is WHICH commodity/store is flagged, not what today's numbers happen to be.
      $flagKeys  = @()
      $gf = Get-ChildItem (Join-Path $OutDir 'guards-*.json') -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
      # @(Get-Content|ConvertFrom-Json) does NOT unroll in PS 5.1: ConvertFrom-Json writes a JSON array to the
      # pipeline as ONE object, so @() wraps it into a 1-element array. Every sanity outlier therefore collapsed
      # into a single flagPart whose fields were arrays - the 2026-07-28 email said "16 price(s) to review" for
      # 54 outliers + 15 multibuys (69), and printed all 54 commodity names mashed into one unreadable line.
      # Worse, the whole set shared one dedupe signature. Assign first, THEN wrap, so each outlier is its own flag.
      if ($gf) { $gj = Get-Content $gf.FullName -Raw | ConvertFrom-Json; foreach ($x in @($gj)) { $flagParts += ('SANITY|' + $x.commodity + '|' + $x.type + '|' + $x.detail); $flagKeys += ('SANITY|' + $x.commodity + '|' + $x.type) } }
      $ff = Get-ChildItem (Join-Path $OutDir 'flagged-*.json') -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
      if ($ff) { $mb = @((Get-Content $ff.FullName -Raw | ConvertFrom-Json).multibuy_unpriced); foreach ($m in $mb) { $flagParts += ('MULTIBUY|' + $m.store + '|' + $m.label); $flagKeys += ('MULTIBUY|' + $m.store + '|' + $m.id) } }
      # ---- BASIS CHECKS (2026-07-28). Bands and freshness cannot see a basis error: the price is real and
      # only the arithmetic is wrong, which is precisely what wins a "cheapest store" verdict. Both audits
      # write their own report; their findings ride the same review-flag channel so they land in the triage
      # queue instead of a log nobody reads. Advisory here by design - a store's own unit price is evidence,
      # not gospel (Walmart's is provably wrong sometimes), so these ask for a decision, they do not block.
      try {
        # SURFACE THE FINDINGS. This was piped to Out-Null, so a genuine basis conflict - the class that moves
        # a price by a FACTOR and therefore lands preferentially on the cheapest-store verdict - was computed
        # and then discarded. It is also the ONLY independent price proof Baker's has (see guards.ps1 invariant
        # 11, retired 2026-07-30 in its favour), so throwing its output away left the board's largest store
        # effectively unwatched. Advisory by design; what changes is that it is now READ.
        $brOut = & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'audit-basis-reconcile.ps1') 2>$null
        $brSummary = @($brOut) | Where-Object { $_ -match 'basis-reconcile:' } | Select-Object -First 1
        if ($brSummary) { Log ([string]$brSummary) }
        $brFindings = @($brOut) | Where-Object { $_ -match 'CONFLICT|disagree' }
        if ($brFindings.Count) {
          Log ('basis-reconcile: ' + $brFindings.Count + ' factor-level conflict(s) between our per-unit and the store''s own')
          $summary += ('REVIEW    basis-reconcile: ' + $brFindings.Count + ' cell(s) disagree with the store''s own unit price by a FACTOR - see out\basis-reconcile-report.json')
        }
        $brF = Join-Path $OutDir 'basis-reconcile.json'
        if (Test-Path $brF) {
          $brJ = Get-Content $brF -Raw | ConvertFrom-Json
          foreach ($b in @($brJ.findings)) { $flagKeys += ('BASIS|' + $b.id + '|' + $b.store); $flagParts += ('BASIS|' + $b.id + '|' + $b.store + '|ours ' + $b.ours + '/' + $b.unit + ' vs the store''s own ' + $b.store_says + ' (x' + $b.factor + ') - ' + $b.item) }
        }
      } catch { Log ('audit-basis-reconcile threw: ' + $_.Exception.Message) }
      try {
        & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'audit-pack-basis.ps1') | Out-Null
        $pbF = Join-Path $OutDir 'pack-basis-audit.json'
        if (Test-Path $pbF) {
          $pbJ = Get-Content $pbF -Raw | ConvertFrom-Json
          foreach ($p in @($pbJ.findings)) { $flagKeys += ('PACKBASIS|' + $p.id + '|' + $p.store); $flagParts += ('PACKBASIS|' + $p.id + '|' + $p.store + '|cheapest only because a ' + $p.count + '-pack count was multiplied into the size (' + $p.published + ' vs ' + $p.as_pack_total + ' as a pack total) - ' + $p.item) }
        }
      } catch { Log ('audit-pack-basis threw: ' + $_.Exception.Message) }
      # ---- DIFFERENTIAL ALERTING (2026-07-28). The old dedupe hashed the WHOLE flag text into one
      # signature, and that text embeds prices - so ordinary price movement changed the hash and re-emailed
      # all 68 flags every single day. About 48 of them are the same benign warehouse-bulk economics
      # recurring forever, which is precisely how a real flag hides. Measured on this data: keying on
      # commodity+type instead, 07-27 had 54 and 07-28 had 53, of which only 5 were NEW.
      # 68 lines a day becomes 5, and nothing is lost - the full set still goes to the report files, each
      # flag is just shown to a human ONCE.
      # Deliberately NOT auto-classifying "benign bulk" by heuristic: that can hide a real bug.
      # "New or returning" is lossless; classification is not.
      $fstateFile = Join-Path $OutDir 'alerted-flags.json'
      $fstate = @{}
      if (Test-Path $fstateFile) {
        try { foreach ($p in ((Get-Content $fstateFile -Raw | ConvertFrom-Json).PSObject.Properties)) { $fstate[[string]$p.Name] = $p.Value } } catch { $fstate = @{} }
      }
      # AN ACK IS HOW A REVIEWED FLAG GOES QUIET - not by being ignored long enough.
      # out\review-ack.json: { "acks": [ { "key": "...", "reason": "...", "expires": "yyyy-MM-dd" } ] }
      # An ack with no expires, or an unparseable one, is treated as EXPIRED: silencing a price flag forever
      # on the strength of a typo is exactly the failure this whole block exists to prevent. The estate already
      # works this way for coverage (coverage-ack.json), which re-arms on expiry.
      $REARM_DAYS = 14
      $ackOpen = @{}; $ackExpired = 0; $ackHit = 0; $reArmed = 0
      $ackFile = Join-Path $OutDir 'review-ack.json'
      if (Test-Path $ackFile) {
        try {
          foreach ($a in @((Get-Content $ackFile -Raw | ConvertFrom-Json).acks)) {
            if (-not $a.key) { continue }
            $exp = $null; try { $exp = [datetime]$a.expires } catch { $exp = $null }
            if ($null -ne $exp -and $exp.Date -ge (Get-Date).Date) { $ackOpen[[string]$a.key] = $true } else { $ackExpired++ }
          }
        } catch { Log ('review-ack.json unreadable - treating every flag as unacknowledged: ' + $_.Exception.Message) }
      }
      if ($flagParts.Count -gt 0) {
        Log ("REVIEW FLAGS: " + $flagParts.Count + " -> " + (($flagParts | Select-Object -First 4) -join ' ; '))
        $newIdx = @()
        for ($fi = 0; $fi -lt $flagParts.Count; $fi++) {
          $k = if ($fi -lt $flagKeys.Count) { [string]$flagKeys[$fi] } else { [string]$flagParts[$fi] }
          $isNew = $true
          if ($ackOpen.ContainsKey($k)) { $isNew = $false; $ackHit++ }      # explicitly acknowledged, not expired
          elseif ($fstate.ContainsKey($k)) {
            # a flag that CLEARED and came back must page again - it is a new event, not the same one
            $gap = $null
            try { $gap = ((Get-Date) - [datetime]$fstate[$k].last_seen).TotalDays } catch { $gap = $null }
            if ($null -eq $gap) { $isNew = $true }          # FAIL OPEN: see the note below
            elseif ($gap -gt 7) { $isNew = $true }          # genuinely cleared and returned
            else {
              # STILL CONTINUOUSLY OPEN. This used to be an unconditional $isNew = $false, which made the
              # 7-day test above unreachable: line ~542 refreshes last_seen for EVERY currently-flagged key on
              # EVERY run, so the gap is always 0 and can never exceed 7. A flag present day after day paged
              # exactly ONCE, ever, and then went quiet forever - no expiry, no escalation, nothing. A genuine
              # parse bug flagged once and never fixed simply disappeared into the "already seen" count.
              # Re-arm off last_alerted (which is NOT refreshed by mere presence) so an open flag pages again.
              # Clock preference: last_alerted, else first_seen. The fallback matters - every one of the 63
              # keys in alerted-flags.json today predates this field, and failing OPEN on a missing
              # last_alerted would have paged all 63 in a single mail on the next run. An alert that dumps
              # 63 items trains the reader to ignore it, which is the same wolf-crying this fix is meant to
              # stop. first_seen is when the key was first recorded and therefore first paged, so it is an
              # honest clock for keys created before the field existed: they re-arm 14 days after they
              # appeared, not all at once tonight.
              $la = $null
              try { if ($fstate[$k].last_alerted) { $la = ((Get-Date) - [datetime]$fstate[$k].last_alerted).TotalDays } } catch { $la = $null }
              if ($null -eq $la) { try { $la = ((Get-Date) - [datetime]$fstate[$k].first_seen).TotalDays } catch { $la = $null } }
              if ($null -eq $la) { $isNew = $true }                                  # no usable clock -> fail OPEN
              elseif ($la -ge $REARM_DAYS) { $isNew = $true; $reArmed++ }            # open and ignored too long
              else { $isNew = $false }
            }
          }
          if ($isNew) { $newIdx += $fi }
        }
        $stillOpen = $flagParts.Count - $newIdx.Count
        $extra = ''
        if ($ackHit)     { $extra += ", $ackHit acknowledged" }
        if ($reArmed)    { $extra += ", $reArmed RE-ARMED after $REARM_DAYS days open" }
        if ($ackExpired) { $extra += ", $ackExpired ack(s) EXPIRED" }
        $summary += ("REVIEW    $($flagParts.Count) price flag(s) on the board ($($newIdx.Count) new, $stillOpen already seen$extra) - see guards-/flagged- json")
        if ($newIdx.Count -gt 0 -and -not $NoAlert) {
          $newLines = @($newIdx | ForEach-Object { $flagParts[$_] })
          $body = "$($newIdx.Count) NEW price flag(s) on $asofS (these still published; verify they are real):`n`n" + ($newLines -join "`n") +
                  "`n`n$stillOpen other flag(s) were already reported and are still open - the full set is in guards-*.json / flagged-*.json in $OutDir ."
          & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'send-alert.ps1') -Subject "Grocery: $($newIdx.Count) NEW price flag(s) - $asofS" -Body $body | Out-Null
          if ($LASTEXITCODE -eq 0) { Log ("review-flag alert sent (" + $newIdx.Count + " new of " + $flagParts.Count + ")") }
          else { Log 'review-flag alert FAILED to send (will retry next run)'; $newIdx = @() }   # do not mark as seen if it never sent
        }
        # mark everything currently flagged as seen (only the ones we actually alerted on get first_seen)
        $nowS = (Get-Date).ToString('s')
        # last_alerted is the clock the re-arm above reads, so it must be stamped ONLY on keys this run
        # actually paged about - never by mere presence, or it would refresh itself daily and reproduce the
        # exact bug being fixed (last_seen does that, which is why it cannot be the re-arm clock).
        $alertedKeys = @{}
        if ($newIdx.Count -gt 0) {
          foreach ($ai in $newIdx) { $alertedKeys[$(if ($ai -lt $flagKeys.Count) { [string]$flagKeys[$ai] } else { [string]$flagParts[$ai] })] = $true }
        }
        for ($fi = 0; $fi -lt $flagParts.Count; $fi++) {
          $k = if ($fi -lt $flagKeys.Count) { [string]$flagKeys[$fi] } else { [string]$flagParts[$fi] }
          if (-not $fstate.ContainsKey($k)) { $fstate[$k] = [pscustomobject]@{ first_seen = $nowS; last_seen = $nowS; last_detail = [string]$flagParts[$fi] } }
          else { $fstate[$k].last_seen = $nowS; $fstate[$k].last_detail = [string]$flagParts[$fi] }
          if ($alertedKeys.ContainsKey($k)) {
            if ($fstate[$k].PSObject.Properties['last_alerted']) { $fstate[$k].last_alerted = $nowS }
            else { $fstate[$k] | Add-Member -NotePropertyName last_alerted -NotePropertyValue $nowS -Force }
          }
        }
      }
      # prune anything unseen for 30 days so the state file cannot grow forever
      $cutoff = (Get-Date).AddDays(-30)
      foreach ($k in @($fstate.Keys)) { try { if ([datetime]$fstate[$k].last_seen -lt $cutoff) { $fstate.Remove($k) } } catch { $fstate.Remove($k) } }
      try {
        $tmpF = $fstateFile + '.tmp'
        ([pscustomobject]$fstate | ConvertTo-Json -Depth 4) | Set-Content $tmpF -Encoding UTF8
        Move-Item $tmpF $fstateFile -Force
      } catch { Log ('alerted-flags state write failed: ' + $_.Exception.Message) }
      # retire the old blob signature - it only ever caused the daily re-alert this replaced
      $fsigFile = Join-Path $OutDir 'alerted-flags.sig'
      if (Test-Path $fsigFile) { Remove-Item $fsigFile -ErrorAction SilentlyContinue }

      # AUTO-PUBLISH only when the board changed. publish-deals-page.ps1 self-gates on coverage, rebuilds
      # (recomputing the sale-window badges), and republishes preserving visibility.
      # ---- HARD INVARIANT GATE ------------------------------------------------------------------
      # guards.ps1 blocks the publish if any invariant that is ALWAYS a bug is violated: a mode-sensitive
      # store off the in-store catalogue, a cleaning product priced as food, an override pin that beats the
      # engine, a board cell that differs from its own linked product by a FACTOR (the 2x/3x/12x/24x
      # quantity bugs - ordinary price drift is ignored), or a multipack priced as a single unit.
      # These are exactly the classes that shipped wrong prices on 2026-07-14 while every existing gate
      # stayed green, so a failure here must stop the board going live, not just log.
      # WARN-ONLY: are the weekly-ad landing pages (the flyer-only pills' link targets, ad-urls.json) still
      # alive? Never blocks - a store site outage must not stop OUR publish - but a dead ad link is the same
      # lie class as a dead product link, so it gets said out loud the day it breaks. Baker's is skipped
      # headless (Akamai walls non-browser fetches; the Wednesday browser agent exercises that URL for real).
      try {
        $adDoc = Get-Content (Join-Path $root 'ad-urls.json') -Raw | ConvertFrom-Json
        $skip = @($adDoc.headless_check_skip)
        foreach ($p in $adDoc.urls.PSObject.Properties) {
          if ($skip -contains [string]$p.Name) { continue }
          try {
            $ar = Invoke-WebRequest -UseBasicParsing -Uri ([string]$p.Value) -TimeoutSec 20 -Headers @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' }
            if ([int]$ar.StatusCode -ne 200) { Log ('WARN ad-url ' + $p.Name + ' returned HTTP ' + $ar.StatusCode + ' - the flyer-only pill links there: ' + $p.Value) }
          } catch { Log ('WARN ad-url ' + $p.Name + ' unreachable (' + $_.Exception.Message + ') - the flyer-only pill links there: ' + $p.Value) }
        }
      } catch { Log ('WARN ad-url check skipped: ' + $_.Exception.Message) }

      # Pins are minted HERE, before guards, so every number the build can apply passes the gate first.
      # (Until 2026-07-23 publish-deals-page regenerated them post-gate; a carried-row day minted 37
      # wrong-basis pins the guards never saw. Publish now only APPLIES the pins file.)
      try { & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'generate-board-overrides.ps1') | ForEach-Object { Log ('pins: ' + $_) } } catch { Log ('WARN generate-board-overrides threw: ' + $_.Exception.Message) }
      $guardsRc = 0
      try {
        & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'guards.ps1') | ForEach-Object { Log ('guards: ' + $_) }
        $guardsRc = $LASTEXITCODE
      } catch { $guardsRc = 2; Log ('guards threw: ' + $_.Exception.Message) }
      $guardsBlocked = ($guardsRc -ne 0)
      if ($guardsBlocked) {
        # Do NOT reuse $boardChanged here: that would log "no price change today", which is a lie -
        # the board DID change, we refused to ship it. A misleading log is how an outage goes unnoticed.
        Log 'GUARDS FAILED - board NOT republished (left at last good state)'
        $summary += 'BLOCKED   guards failed a hard invariant - live page left at last good, NOT updated'
        if (-not $NoAlert) {
          try { & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'send-alert.ps1') -Subject "Grocery: GUARDS FAILED - board not published - $asofS" -Body "guards.ps1 found a hard invariant violation on $asofS (wrong-mode store, cleaner priced as food, a pin overriding the engine, a cell off its linked product by a FACTOR, or a multipack priced as one unit). The live page was left at its last good state. See grocery/ad-cycle-log.txt." | Out-Null } catch {}
        }
      }

      # weekly shareable drops graphic (also the board post's og:image). Refresh BEFORE publish so the
      # og:image step sees today's png. Non-fatal: a share graphic must never block prices.
      try { & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'build-share-image.ps1') | ForEach-Object { Log ('share: ' + $_) } } catch { Log ('share-image threw: ' + $_.Exception.Message) }

      if ($guardsBlocked) {
        # already logged + alerted above; fall through without publishing
      } elseif (-not $boardChanged) {
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

      # ---- Walmart full-capture aging watch (2026-07-23 incident follow-up). The union in compare-deals
      # absorbs partial Walmart pulls only while a COMPREHENSIVE capture sits in its 14-day window. Daily
      # partials keep every OTHER freshness signal green (guard 9 watches file age; the Wednesday watchdog
      # watches mtimes), so this is the one condition with no early warning - it would surface only as a
      # coverage HOLD on the day the window expires. audit-walmart-fullpull.ps1 owns the logic (one copy);
      # exit 1 = advisory. Emails even under -NoAlert, same precedent as the consistency-drift alert: only a
      # LOCAL browser pull can fix it, and send-alert's per-type daily gate caps it at one email per day.
      # Non-fatal by construction.
      try {
        $wfpOut = & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'audit-walmart-fullpull.ps1') 2>$null
        if ($LASTEXITCODE -eq 1) {
          Log ('walmart-fullpull ADVISORY: ' + [string]$wfpOut)
          try { & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'send-alert.ps1') -Subject "Grocery: Walmart full capture aging - $asofS" -Body ("Early warning, nothing is broken yet: " + [string]$wfpOut + " When the last comprehensive capture leaves the 14-day union window, the coverage guard will HOLD the board (safe, but that day's Walmart refresh is lost). Run the full-worklist Walmart browser pull to reset the clock.") | Out-Null } catch {}
        } elseif ($LASTEXITCODE -eq 3) {
          Log ('walmart-fullpull BLIND: ' + [string]$wfpOut)
          try { & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'send-alert.ps1') -Subject "Grocery: a union store has NO captures in its window - $asofS" -Body ("Not an early warning - the fullpull watch examined ZERO capture files for at least one union store (Walmart/Sam's): " + [string]$wfpOut + " The coverage guard will HOLD that store at the cliff; run the full-worklist browser pull now.") | Out-Null } catch {}
        } else { Log ('walmart-fullpull: ' + [string]$wfpOut) }
      } catch { Log ('walmart-fullpull audit threw: ' + $_.Exception.Message) }

      # ---- Friday digest: the weekly board email the capture CTAs promise. Only when guards passed (never
      # email prices the gates would not publish), Fridays only, idempotent inside the script. Non-fatal.
      if (-not $guardsBlocked) {
        try { & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'send-friday-digest.ps1') | ForEach-Object { Log ('digest: ' + $_) } } catch { Log ('digest threw: ' + $_.Exception.Message) }
      }

      # ---- CONSISTENCY GUARD: enforce "the price shown == the product the 'See item' link opens", every day.
      # audit-board-consistency.ps1 returns 2 when too many chips fall back to a name (a link was suppressed
      # because its price no longer matches - divergence or a stale board price). On breach we AUTO-REPAIR the
      # Family Fare links (re-point each to the exact product the board priced, at today's price - the API path
      # that can run headless in the cloud), re-merge, republish, and re-audit. A breach that survives repair =
      # a browser-store shelf price drifted from the board (needs a re-pull); we alert Brad ONCE per distinct
      # drift set (signature de-dup, so a stable backlog never spams) even under -NoAlert.
      if (-not $NoPublish) {
        try {
          & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'audit-board-consistency.ps1') | Out-Null
          if ($LASTEXITCODE -eq 2) {
            Log 'consistency BREACH - auto-repairing Family Fare + Hy-Vee links + republishing'
            try {
              & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'resolve-ff-boardmatch.ps1') | Out-Null
              # Hy-Vee no-link + wrong-size chips self-heal the SAME way, headless via Hy-Vee's search API.
              # Added 2026-07-14: this repair ran Family Fare ONLY, so Hy-Vee no-link gaps never closed on their
              # own and the board sat at 25 linkless Hy-Vee chips. resolve-hyvee-links board-matches by
              # size+brand+price and writes product-urls.json directly, so it runs BEFORE the merge; the
              # prune-bad-links + guards gate below still catch anything it produces that drifts by a factor.
              & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'resolve-hyvee-links.ps1') | Out-Null
              # CAUTION: merge-product-urls re-merges EVERY store-*-urls.json still sitting in
              # out\url-inputs\, so a stale resolver file left behind can RESURRECT an old link and
              # overwrite a good one (it silently corrupted ~226 links on 2026-07-14). Old resolver
              # outputs therefore live in out\url-inputs-archive\, NOT out\url-inputs\.
              & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'merge-product-urls.ps1')     | Out-Null
              # Prune at a FACTOR tolerance, NOT the strict 2%. Rationale:
              #   - strict 2% would delete a perfectly good link the moment a store nudged its price
              #     (the board refreshes daily; the link's price snapshot does not), eroding coverage;
              #   - but a link left off by a FACTOR (a wrong SKU / a pack counted as one unit) would
              #     trip guards.ps1 below and BLOCK the board every single day.
              # 0.32 drops everything guards would hard-fail on (ratio >=1.5x or <=0.67x) and nothing
              # else, so the repair is self-healing and the gate can never deadlock the daily publish.
              & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'prune-bad-links.ps1') -Tol 0.32 | Out-Null
              # THE PERMANENT FIX for browser-store link regression: prune just dropped any link that drifted by
              # a factor (a wrong SKU/size), which would leave a no-link gap. sync-browser-links immediately
              # re-creates any browser link that is now missing but whose row still carries the product identity
              # (item_id for Walmart/Sam's, a captured URL for Baker's), board-ANCHORED so it matches by
              # construction. Net: a browser link pruned for drift is healed in the SAME pass and never stays a
              # gap. Heal-only (never overwrites a healthy link, so guard 4 keeps checking those independently).
              & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'sync-browser-links.ps1') | Out-Null
              # This repair path used to publish DIRECTLY, which would have bypassed the invariant gate.
              # Links just changed, so pins derived from them must be re-minted BEFORE guards re-check
              # (same publish-never-mints rule as the main gate above).
              try { & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'generate-board-overrides.ps1') | Out-Null } catch {}
              & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'guards.ps1') -Quiet | Out-Null
              if ($LASTEXITCODE -eq 0) {
                & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'publish-deals-page.ps1')   | Out-Null
              } else {
                Log 'GUARDS FAILED after consistency auto-repair - NOT republished (left at last good)'
                $summary += 'BLOCKED   guards failed after consistency auto-repair - live page left at last good'
              }
            } catch { Log ('consistency auto-repair threw: ' + $_.Exception.Message) }
            & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'audit-board-consistency.ps1') | Out-Null
            if ($LASTEXITCODE -eq 2) {
              $cr = try { Get-Content (Join-Path $OutDir 'consistency-report.json') -Raw | ConvertFrom-Json } catch { $null }
              $nl = if ($cr) { [string]$cr.no_link_count } else { '?' }
              # signature covers BOTH failure kinds: price-drift mismatches AND no-link chips (a pure no-link
              # breach used to hash to '' and could never de-dup properly)
              $driftSig = if ($cr) { (@(@($cr.mismatch) + @($cr.no_link) | Where-Object { $_ } | ForEach-Object { $_.id + '|' + $_.store } | Sort-Object -Unique) -join ';') } else { '' }
              $csigF = Join-Path $OutDir 'consistency-alert.sig'
              $prevSig = if (Test-Path $csigF) { ([string](Get-Content $csigF -Raw)).Trim() } else { '' }
              Log ("consistency STILL breached after repair - no-link=$nl (browser-store price drift, needs re-pull)")
              $summary += "REVIEW    board-link drift: $nl chips show a name not a link - see consistency-report.json"
              if ($driftSig -ne $prevSig -and (-not $NoAlert)) {
                try { & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'send-alert.ps1') -Subject "Grocery: board-link price drift ($nl chips) - $asofS" -Body "$nl priced chips fall back to a product name (no 'See item' link) after auto-repair on $asofS, because a store's shelf price drifted from the board. NO misleading link is shown. Re-pull the flagged store(s). Details: grocery/out/consistency-report.json." | Out-Null
                      if ($LASTEXITCODE -eq 0) { Set-Content -Path $csigF -Value $driftSig -Encoding UTF8; Log 'consistency drift alert sent' } } catch { Log ('consistency alert threw: ' + $_.Exception.Message) }
              } else { Log 'consistency drift unchanged since last alert - not re-alerting' }
            } else { Log 'consistency repaired - all shown links match their price'; if (Test-Path (Join-Path $OutDir 'consistency-alert.sig')) { Remove-Item (Join-Path $OutDir 'consistency-alert.sig') -ErrorAction SilentlyContinue } }
          } else { Log 'consistency OK - every shown link matches its price' }
        } catch { Log ('consistency guard threw: ' + $_.Exception.Message) }
      }

      # ---- ALL-STORES-SHOWN MONITOR: re-assert on the freshly BUILT board that every staple commodity shows a
      # tile for all 7 stores (a price, or a "Doesn't carry / No price yet - See it? Let us know!" card). This is
      # the blueberries drop-off invariant. build-deals-page renders it by construction + publish HARD-GATES on
      # it, so a failure here means a render regression slipped through; we name the exact commodity+store and
      # alert ONCE per distinct violation set (sig de-dup) even under -NoAlert, so a silent store-drop can't recur.
      if (-not $NoPublish) {
        try {
          & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'audit-store-coverage.ps1') | Out-Null
          if ($LASTEXITCODE -eq 2) {
            $sc = try { Get-Content (Join-Path $OutDir 'store-coverage-report.json') -Raw | ConvertFrom-Json } catch { $null }
            $scList = if ($sc) { (@($sc.violations | ForEach-Object { $_.commodity + ' [missing: ' + $_.missing + ']' }) -join '; ') } else { '?' }
            $scSig  = if ($sc) { (@($sc.violations | ForEach-Object { $_.commodity + '|' + $_.missing } | Sort-Object) -join ';') } else { '' }
            $scF = Join-Path $OutDir 'store-coverage-alert.sig'
            $scPrev = if (Test-Path $scF) { ([string](Get-Content $scF -Raw)).Trim() } else { '' }
            Log ("store-coverage FAIL: $($sc.violations.Count) commodity(ies) missing a store tile - $scList")
            $summary += "REVIEW    store-coverage: $($sc.violations.Count) commodity(ies) not showing all 7 stores - see store-coverage-report.json"
            if ($scSig -ne $scPrev -and (-not $NoAlert)) {
              try { & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'send-alert.ps1') -Subject "Grocery: a store dropped off a commodity tile - $asofS" -Body "audit-store-coverage found staple commodities NOT showing all 7 stores (a store tile is missing entirely - not even a 'Doesn't carry' card): $scList. The board is built to render all 7 by construction, so this is a render regression - check MissingCells / storeOrder in build-deals-page.ps1. Details: grocery/out/store-coverage-report.json." | Out-Null
                    if ($LASTEXITCODE -eq 0) { Set-Content -Path $scF -Value $scSig -Encoding UTF8; Log 'store-coverage alert sent' } } catch { Log ('store-coverage alert threw: ' + $_.Exception.Message) }
            } else { Log 'store-coverage violation unchanged since last alert - not re-alerting' }
          } else { Log 'store-coverage OK - every staple commodity shows all 7 stores'; if (Test-Path (Join-Path $OutDir 'store-coverage-alert.sig')) { Remove-Item (Join-Path $OutDir 'store-coverage-alert.sig') -ErrorAction SilentlyContinue } }
        } catch { Log ('store-coverage guard threw: ' + $_.Exception.Message) }
      }

      # ---- ITEM-REQUEST NOTIFICATIONS: when a NEW commodity appears on the board, email any /suggest-an-item/
      # requester who asked for it (one-off via the Worker's Gmail; requesters are NOT members). Driven purely
      # by the notify-known-ids.json state diff, so it is a no-op every day nothing new was added - and it runs
      # regardless of -NoAlert (these are requester-facing, not Brad-alerts). Never fatal to the pipeline.
      try {
        $niOut = & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'notify-item-added.ps1') 2>&1
        foreach ($ln in @($niOut)) { Log ("notify-item-added: " + $ln) }
        $niSent = @($niOut | Where-Object { "$_" -match '^NOTIFIED ' }).Count
        if ($niSent -gt 0) { $summary += ("NOTIFIED  $niSent item-request follower(s) emailed - their suggested item is now on the board") }
      } catch { Log ('notify-item-added threw: ' + $_.Exception.Message) }
    }
  } catch { Log ("downstream FAILED: " + $_.Exception.Message) }
} elseif ($hardFail -and (-not $NoDownstream)) {
  Log 'HARD FAILURE - skipped re-compare/publish; board left at last good (alert already sent)'
  $summary += 'HELD      server pull hard-failed - board left at last good, not republished'
}

# ---- WATCH THE WATCHERS - ALWAYS, outside the downstream branch (hoisted 2026-07-28) ----
# A guard that reports nothing looks exactly like a guard that is broken, and on 2026-07-28 three of them
# were broken at once while "passing" for days. test-auditors.ps1 replays each watcher's founding bug
# against a frozen fixture and asserts it still fires (and stays silent on the clean twin).
# This deliberately sits OUTSIDE `if ($serverDue -and ... -and (-not $hardFail))`. It used to live inside,
# which meant it was skipped on exactly the days a guard hard-failed - the days you most need to know
# whether the guards themselves can still be trusted. It depends on nothing but its own fixtures, so there
# is no reason for it ever to be conditional. A blind watcher has to be LOUDER than the thing it watches:
# if this fails, every quiet guard above it becomes unproven, including a clean board.
try {
  & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'test-auditors.ps1') | Out-Null
  if ($LASTEXITCODE -ne 0) {
    $ta = (& powershell -ExecutionPolicy Bypass -File (Join-Path $root 'test-auditors.ps1') 2>&1 | ForEach-Object { [string]$_ }) -join "`n"
    Log 'WATCHERS FAILED: test-auditors could not prove a guard still sees its own bug'
    $summary += 'WATCHERS  a guard can no longer see its own founding bug - see test-auditors output'
    if (-not $NoAlert) {
      & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'send-alert.ps1') -Subject 'Grocery: a GUARD has gone blind (test-auditors failed)' -Body ("test-auditors.ps1 replays each watcher's founding bug against a frozen fixture. At least one watcher no longer fires on it, which means any quiet report from that guard is unproven - including a clean board.`n`n" + $ta) | Out-Null
    }
  } else { Log 'watchers ok: every guard still fires on its own founding bug' }
} catch { Log ('test-auditors threw: ' + $_.Exception.Message) }

# ---- WEEKLY: prove each BLOCKING invariant can still FAIL (test-guards, hermetically) ----
# test-auditors above proves the watchers fire on frozen fixtures; test-guards proves guards.ps1 itself
# still exits 2 when an invariant is broken on purpose. It mutates live data to do it (16 windows, 9
# git-tracked files; measured 2026-07-30: a hard kill runs neither finally nor PowerShell.Exiting, and a
# foreign commit landed DURING the measured run), so it must never run against production. The runner
# copies the whole tree to %TEMP% (1.1s for 658 MB; every script roots at $PSScriptRoot) and runs there.
# Stamp-gated on >=7 days, not a weekday, so a missed week self-heals on the next daily run.
try {
  $tgStampF = Join-Path $root 'test-guards-weekly-stamp.txt'
  $tgLast = [datetime]'2000-01-01'
  if (Test-Path $tgStampF) { try { $tgLast = [datetime](Get-Content $tgStampF -TotalCount 1) } catch {} }
  if (((Get-Date) - $tgLast).TotalDays -ge 7) {
    $tg = (& powershell -ExecutionPolicy Bypass -File (Join-Path $root 'run-test-guards-weekly.ps1') 2>&1 | ForEach-Object { [string]$_ }) -join "`n"
    $tgRc = $LASTEXITCODE
    (Get-Date -Format 'yyyy-MM-dd') | Set-Content $tgStampF -Encoding ascii   # stamp even on failure: one alert per week, not one per day
    if ($tgRc -eq 0) { Log 'test-guards weekly: every hard invariant can still fail (hermetic run passed)' }
    else {
      Log ('test-guards weekly rc=' + $tgRc)
      $summary += 'INVARIANTS a blocking guard may no longer be able to fire - see test-guards weekly alert'
      if (-not $NoAlert) {
        $tgSubject = if ($tgRc -eq 3) { 'Grocery: test-guards could not evaluate (guards already red on the unmutated board)' } elseif ($tgRc -eq 4) { 'Grocery: test-guards weekly did not run (hermetic copy failed)' } else { 'Grocery: a BLOCKING invariant can no longer fail (test-guards weekly)' }
        & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'send-alert.ps1') -Subject $tgSubject -Body ("run-test-guards-weekly.ps1 breaks each hard invariant inside a scratch COPY of the grocery tree and asserts guards.ps1 exits 2 with that guard's own failure text. Exit " + $tgRc + ": 1 = a broken invariant did NOT fail guards (that guard is decorative until fixed - do not trust a quiet board on it); 3 = baseline already red, nothing proven (the daily run is already alerting on the real failure); 4 = the hermetic copy failed. Production files are never touched by this job.`n`n" + $tg) | Out-Null
      }
    }
  }
} catch { Log ('test-guards weekly threw: ' + $_.Exception.Message) }

# ---- report ----
$pullNote = if ($serverDue) { '   (server pull ran)' } else { '   (nothing due)' }
Write-Output ("Ad-cycle check  -  " + $asofS + $pullNote)
Write-Output ('-'*74)
foreach ($line in $summary) { Write-Output $line }
if (@($flips).Count -gt 0) { Write-Output ""; Write-Output ("Flipped this run: " + ($flips -join ', ') + "  -> comparison + price history refreshed") }
Log ("run complete; flips=" + (@($flips).Count))

