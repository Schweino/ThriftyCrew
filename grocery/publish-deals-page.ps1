<#
  publish-deals-page.ps1 - The single, gated PUBLISH action for the public Omaha grocery page. HEADLESS
  (no browser). Rebuilds out\deals-page-embed.html from the newest board, runs a COVERAGE GATE so a
  degraded/half-empty matrix is NEVER pushed live, then upserts the Ghost Resources post
  (slug omaha-grocery-prices) PRESERVING its current visibility (so a weekly refresh never un-gates a
  page Brad later set to paid).

  Exit codes:  0 = published, or CURRENT (page identical to the live one, upsert skipped)
               2 = HELD (a publish gate failed; caller should alert)   1 = error
  Params: -CompareFile <path> (default newest)  -MinCommodities 25  -MinPerStore 15  -Draft
          -Force (skips the coverage gate AND the change gate)
          -SelfTest (hermetic fixture for the change gate; touches no data, publishes nothing)
#>
param([string]$CompareFile = "", [int]$MinCommodities = 25, [int]$MinPerStore = 15, [switch]$Force, [switch]$Draft, [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$OutDir = Join-Path $root 'out'

# ---- WHERE DOES THE PUBLISH BLOCK ACTUALLY GO? (2026-08-23) -------------------------------------
# This file launches eleven children and reported none of their times, so the only number anyone had
# was the gap between two check-ad-cycles log lines - 167 s on 2026-08-23 - which says "the publish
# block" and nothing about which part. PLAN-use-the-cores-2 §2.1 proposed fanning out the two
# read-only gate trios on that gap. Measured standalone first, and the proposal was wrong:
#
#     pre-build   price-mode 1.2 s + links 0.9 s + name-drift 7.5 s   =  9.6 s
#     post-build  store-coverage 0.6 + match-soundness 1.9 + cat-cov 0.4 =  2.9 s
#     builders    build-deals-page 14.7 s, trend-pages 8.4 s, trend-index 0.8 s
#
# Nine of the eleven children are ~36 s of a 167 s block. Fanning out both trios would save about
# THREE SECONDS. The other ~130 s is Ghost: the board upsert, publish-store-guide and
# publish-trend-pages - network, rate-limited, and serial on purpose (§3.5).
#
# So this is a stopwatch, not a fan-out. Each child reports its own wall time on the line it already
# logs, and tomorrow's run answers the question for the two publishers that cannot be timed by hand
# without doing a real Ghost upsert. Measure, then decide - the same order that turned §2.1 from a
# 50-70 s projection into a 3 s one.
$script:StageTimes = [ordered]@{}
function Invoke-Timed {
  param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Body)
  $sw = [Diagnostics.Stopwatch]::StartNew()
  try { & $Body } finally {
    $sw.Stop()
    $script:StageTimes[$Name] = [math]::Round($sw.Elapsed.TotalSeconds, 1)
  }
}
$slug   = 'omaha-grocery-prices'

# ---- CHANGE-GATE DECISION (2026-07-30). Kept pure and file-only so -SelfTest can prove it BOTH fires and
# stays out of the way. Returns $true when the Ghost upsert MUST run. Every uncertain case returns $true:
# this gate may only ever skip work it can PROVE is already live.
function Test-UpsertNeeded {
  param([string]$Sig, [string]$SigFile, [bool]$LiveSeen, [bool]$ForceFlag, [bool]$DraftFlag)
  if ($ForceFlag -or $DraftFlag) { return $true }        # -Force / -Draft always publish
  if (-not $LiveSeen) { return $true }                   # never read the live post -> cannot claim it is current
  if ([string]::IsNullOrWhiteSpace($Sig)) { return $true }
  $prev = ''
  # PS 5.1: [string]$null is $null, so ([string](Get-Content -Raw)).Trim() THROWS on a zero-byte stamp.
  # (x + '') keeps it a string. A locked/unreadable stamp is a publish, never a skip.
  try { if (Test-Path $SigFile) { $prev = ((Get-Content $SigFile -Raw) + '').Trim() } } catch { return $true }
  if (-not $prev) { return $true }                       # missing or empty stamp -> publish
  return ($prev -ne $Sig)
}

if ($SelfTest) {
  # MUST-FIRE + CLEAN-TWIN fixture for the change gate. Founding bug (2026-07-29): 13 invocations of this
  # script pushed the SAME week's board to Ghost 12 times, ~7 MB of lexical payload for one week's data.
  # The signatures below are FROZEN SYNTHETIC strings - never regenerate them from the live board.
  $t = Join-Path $env:TEMP ('pdp-selftest-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $t | Out-Null
  $sf = Join-Path $t 'deals-page.sig'
  $A = '0123456789ABCDEF0123456789ABCDEF|public'   # the page we last published
  $B = '0123456789ABCDEF0123456789ABCDEE|public'   # same page, ONE byte of rendered html different
  $P = '0123456789ABCDEF0123456789ABCDEF|paid'     # same page, the post was flipped to paid
  $fails = @()
  Set-Content -Path $sf -Value $A -Encoding ASCII
  if (Test-UpsertNeeded -Sig $A -SigFile $sf -LiveSeen $true -ForceFlag $false -DraftFlag $false) { $fails += 'MUST-FIRE: an unchanged board still upserts (the short-circuit is dead)' }
  if (-not (Test-UpsertNeeded -Sig $B -SigFile $sf -LiveSeen $true -ForceFlag $false -DraftFlag $false)) { $fails += 'CLEAN TWIN: a one-byte content change was skipped (a price change would never ship)' }
  if (-not (Test-UpsertNeeded -Sig $P -SigFile $sf -LiveSeen $true -ForceFlag $false -DraftFlag $false)) { $fails += 'CLEAN TWIN: a visibility flip was skipped (the paywall schema would never follow it)' }
  if (-not (Test-UpsertNeeded -Sig $A -SigFile $sf -LiveSeen $false -ForceFlag $false -DraftFlag $false)) { $fails += 'skipped although the live post was never read' }
  if (-not (Test-UpsertNeeded -Sig $A -SigFile $sf -LiveSeen $true -ForceFlag $true -DraftFlag $false)) { $fails += '-Force did not bypass the change gate' }
  if (-not (Test-UpsertNeeded -Sig $A -SigFile $sf -LiveSeen $true -ForceFlag $false -DraftFlag $true)) { $fails += '-Draft did not bypass the change gate' }
  [IO.File]::WriteAllText($sf, '')
  if (-not (Test-UpsertNeeded -Sig $A -SigFile $sf -LiveSeen $true -ForceFlag $false -DraftFlag $false)) { $fails += 'a ZERO-BYTE stamp skipped the publish' }
  Remove-Item $sf -Force -ErrorAction SilentlyContinue
  if (-not (Test-UpsertNeeded -Sig $A -SigFile $sf -LiveSeen $true -ForceFlag $false -DraftFlag $false)) { $fails += 'a MISSING stamp skipped the publish' }
  # A fixture that passes with the gate REMOVED is worthless. Assert the decision is actually wired into the
  # publish path: the live-post handle is passed at exactly one place, the real call site.
  if ([IO.File]::ReadAllText($PSCommandPath) -notmatch '-LiveSeen \(\[bool\]\$ex\)') { $fails += 'Test-UpsertNeeded is defined but never called by the publish path' }
  Remove-Item $t -Recurse -Force -ErrorAction SilentlyContinue
  if ($fails.Count) { Write-Output ('SELFTEST FAIL - ' + ($fails -join ' | ')); exit 1 }
  Write-Output 'SELFTEST PASS - change gate: unchanged board skips; one-byte and visibility changes publish; missing, empty or unreadable stamp publishes; unread live post publishes; -Force/-Draft bypass.'
  exit 0
}
# Ghost admin key: env var (CI secret) or gitignored .ghostkey; apiUrl stays the ghost.io admin host.
$adminKey = if ($env:GHOST_ADMIN_KEY) { $env:GHOST_ADMIN_KEY }
  elseif (Test-Path (Join-Path $root '.ghostkey')) { (Get-Content (Join-Path $root '.ghostkey') -Raw).Trim() }
  elseif (Test-Path (Join-Path (Split-Path $root -Parent) 'meal-prep\.ghostkey')) { (Get-Content (Join-Path (Split-Path $root -Parent) 'meal-prep\.ghostkey') -Raw).Trim() }
  else { throw 'Ghost admin key missing: set $env:GHOST_ADMIN_KEY or create meal-prep\.ghostkey' }
$apiUrl = 'https://map-to-success.ghost.io'
if (-not $CompareFile) {
  $cmpF = (Get-ChildItem (Join-Path $OutDir 'comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1)
  $CompareFile = $cmpF.FullName
  # prefer the semantically-verified board when it is at least as fresh as the raw comparison (see build-deals-page)
  try { $wk = (Get-Content $cmpF.FullName -Raw | ConvertFrom-Json).week_of; $verF = Join-Path $OutDir ("verified-" + $wk + ".json"); if ((Test-Path $verF) -and ((Get-Item $verF).LastWriteTime -ge $cmpF.LastWriteTime)) { $CompareFile = $verF } } catch {}
}
$doc = Get-Content $CompareFile -Raw | ConvertFrom-Json

# ---- COVERAGE GATE: never publish a degraded matrix (a store that dropped out, or a thin board) ----
# registry-driven (2026-07-26): this gate silently omitted Fareway for two weeks - the store list now
# comes from stores.json so a store added there is gated here automatically (audit-store-registry.ps1 verifies)
$stores = @((Get-Content (Join-Path $root 'stores.json') -Raw | ConvertFrom-Json).stores | Sort-Object { [int]$_.order } | ForEach-Object { [string]$_.name })
$perStore = @{}; foreach ($s in $stores) { $perStore[$s] = 0 }
foreach ($r in $doc.comparison) { foreach ($st in $r.stores) { $k = [string]$st.store; if ($perStore.ContainsKey($k)) { $perStore[$k]++ } } }
$commCount = @($doc.comparison).Count
$thin = @(); foreach ($s in $stores) { if ($perStore[$s] -lt $MinPerStore) { $thin += ("{0}={1}" -f $s, $perStore[$s]) } }
$reasons = @()
if ($commCount -lt $MinCommodities) { $reasons += "only $commCount commodities (need >= $MinCommodities)" }
if ($thin.Count -gt 0)             { $reasons += ("thin/missing stores: " + ($thin -join ', ')) }
if ($reasons.Count -gt 0 -and -not $Force) {
  Write-Output ("HELD: coverage gate failed - " + ($reasons -join '; ') + ". NOT publishing (a store's pull likely failed; run -Force to override).")
  exit 2
}

# ---- price-mode visibility: compare-deals already DROPS any unverified Instacart store (Aldi/Fareway) so its
#      marked-up delivery prices never reach the board; surface it here too so a drop is never silent ----
try {
  Invoke-Timed 'audit-price-mode' { & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'audit-price-mode.ps1') | Out-Null }
  if ($LASTEXITCODE -eq 2) { Write-Output "price-mode: an Instacart store is UNVERIFIED - compare-deals EXCLUDED it from the board. Re-capture In-Store + stamp mode_verified to restore it." }
  elseif ($LASTEXITCODE -eq 3) { Write-Output "price-mode: BLIND - no canonical file for a mode-sensitive store reached the audit; nothing this run proves Aldi/Fareway are in-store priced (their board cells are also thin/absent, which the coverage gate above holds on)." }
} catch {}

# ---- refresh the link audits so the builder can suppress any wrong (form-flip) "See item" link ----
try { & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'audit-links.ps1') | Out-Null } catch {}
# (audit-name-drift ran here too until 2026-07-28 - a verbatim duplicate of the call ~12 lines below, with
# no state change in between. The LOWER one is the load-bearing one: its comment records that it must run
# against current product-urls BEFORE the builder or link suppression goes stale. Keeping one, not two.)

# ---- rebuild the embed page (no <h1>; Ghost's post title is the H1) ----
# Delete the previous embed FIRST and check the builder's exit code: without both, a build crash left
# yesterday's embed in place (> size floor), which then published as if fresh AND stamped the signature -
# the price change was silently lost forever.
$embed = Join-Path $OutDir 'deals-page-embed.html'
Remove-Item $embed -ErrorAction SilentlyContinue
# Regenerate the name-drift audit against the CURRENT product-urls FIRST. It flags cells whose stored link is a
# wrong product (fresh->frozen etc.), which the builder uses to suppress that "See item" link. If it goes stale,
# a link stays wrongly hidden after its URL is fixed (this bit us: chicken breast at Aldi/Sam's stayed unlinked
# after the frozen->fresh fix until this audit was re-run). Running it here keeps suppression in sync every build.
try { & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'audit-name-drift.ps1') | Out-Null
      if ($LASTEXITCODE -eq 3) { Write-Output 'name-drift: BLIND (examined zero cells) - the builder is about to suppress links from an EMPTY drift table; wrong-product links will not be suppressed this build' } } catch {}
# Board-price override pins are GENERATED UPSTREAM (check-ad-cycles runs generate-board-overrides.ps1 BEFORE
# guards.ps1) and only APPLIED here. Publish must never mint a number the guards have not seen: on 2026-07-23
# this script regenerated pins post-gate and shipped 37 wrong-basis prices (pack price pinned onto per-item
# cells) that guards would have refused. If the pins file looks stale, re-run the pipeline, not this script.
Invoke-Timed 'build-deals-page' { & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'build-deals-page.ps1') -CompareFile $CompareFile -Out $embed -Embed | Out-Null }
if ($LASTEXITCODE -ne 0) { Write-Output ("ERROR: page build FAILED (rc=$LASTEXITCODE) - not publishing"); exit 1 }
if (-not (Test-Path $embed) -or ((Get-Item $embed).Length -lt 2000)) { Write-Output 'ERROR: page build produced no/short file'; exit 1 }
# Link-coverage self-check: how many priced chips render NO "See item" link (or Does-not-carry cell)? A spike
# means links are being wrongly suppressed (a stale audit, an over-tight price guard, or wrong-product data).
# Surfaced, never fatal - the board still publishes; this is an early-warning so it can't silently regress again.
try {
  # Chips live in public/board.json now (they are display:none until a row opens, and inlining them pushed the
  # Ghost upsert past its timeout). Counting them in the embed would find ZERO and report perfect coverage -
  # a blind check. Read the same rendered chip html from the feed the browser injects.
  $nl = 0; $tot = 0
  $nlCells = New-Object System.Collections.Generic.List[string]
  $bfeed = Join-Path (Split-Path $root -Parent) 'public\board.json'
  # [^>]* BEFORE the closing bracket, not a bare '>'. The chip gained a style='--bar:NN%' attribute for the
  # ranked-bar panel on 2026-08-31 and this regex, which demanded data-pu be the LAST attribute, stopped
  # matching every chip on the board. The gate said so out loud rather than printing a clean zero, which is
  # the whole reason the BLIND branch below exists - but a pattern that pins the attribute ORDER will keep
  # doing this, so it now only pins the two attributes it actually reads.
  $chipRx = "<div class='pg-chip[^']*' data-store=`"([^`"]+)`" data-pu='[^']*'[^>]*>(.*?)</div>"
  if (Test-Path $bfeed) {
    $bj = Get-Content $bfeed -Raw | ConvertFrom-Json
    foreach ($bp in $bj.PSObject.Properties) {
      # __meta and __rows are the structured twin, not chip markup (see build-deals-page's RowStruct)
      if (([string]$bp.Name).StartsWith('__')) { continue }
      $cid = ([string]$bp.Name) -replace '::r$',''
      foreach ($cp in [regex]::Matches([string]$bp.Value, $chipRx, 'Singleline')) { $tot++; if ($cp.Groups[2].Value -notmatch 'pg-see') { $nl++; [void]$nlCells.Add($cid + '|' + ($cp.Groups[1].Value -replace '&#39;', "'")) } }
    }
  } else {
    $eh = Get-Content $embed -Raw
    foreach ($rw in [regex]::Matches($eh, "data-id='([^']+)'(.*?)</article>", 'Singleline')) {
      $cid = [string]$rw.Groups[1].Value
      foreach ($cp in [regex]::Matches($rw.Groups[2].Value, $chipRx, 'Singleline')) { $tot++; if ($cp.Groups[2].Value -notmatch 'pg-see') { $nl++; [void]$nlCells.Add($cid + '|' + ($cp.Groups[1].Value -replace '&#39;', "'")) } }
    }
  }
  # WHICH CLASS, because the two need opposite work: a cell that HAS a stored product URL the sale/identity
  # gate hid is a link-quality problem in this repo; a cell with nothing recorded needs a browser resolve.
  $nlStored = 0
  try {
    $puDoc = (Get-Content (Join-Path $root 'product-urls.json') -Raw | ConvertFrom-Json).items
    foreach ($k in $nlCells) {
      $kp = $k -split '\|', 2
      $ce = $puDoc.PSObject.Properties[$kp[0]]; if (-not $ce) { continue }
      $se = $ce.Value.PSObject.Properties[$kp[1]]
      if ($se -and $se.Value -and $se.Value.url) { $nlStored++ }
    }
  } catch { $nlStored = -1 }
  # ZERO CHIPS IS NOT ZERO GAPS. Every count here comes from a regex over rendered chip markup, so the same
  # render change that would break the markup also empties this check - and an empty examination printed "0
  # chips with no link", which reads as perfect coverage. Say so instead.
  if ($tot -eq 0) { Write-Output 'link-coverage: BLIND - examined ZERO priced chips (no board.json, and no chip markup in the embed), so the 0 below is an empty examination, not clean coverage.' }
  $split = if ($nlStored -ge 0) { " ($nlStored of them HAVE a stored product URL the link gate suppressed; " + ($nl - $nlStored) + " have no URL recorded at all)" } else { '' }
  Write-Output ("link-coverage: $nl of $tot priced chip(s) fall back to the weekly-ad pill instead of an exact See-item product link" + $split)
  if ($nl -gt 0) { Write-Output ("NOTE: these are NOT linkless prices. Brad's every-price-has-a-link rule is enforced by the ALL-3 assertion inside build-deals-page.ps1, which hard-fails the build (exit 2) on any priced chip with no <a> and passed on this build - a flyer-only sale cell with no exact product page legitimately links to the store's weekly ad. Closing these means re-resolving the suppressed URLs (out\name-drift.json + the sale gate in SeeLink) and browser-resolving the rest.") }
} catch {}

# ---- ALL-STORES-SHOWN invariant (HARD gate): every staple commodity must render a tile for ALL 7 stores - a
# price, or a "Doesn't carry / No price yet - See it? Let us know!" card. A store missing from a commodity row
# is the exact blueberries drop-off Brad caught; do NOT ship a board that hides a store. -Force overrides.
$__sw = [Diagnostics.Stopwatch]::StartNew()
& powershell -ExecutionPolicy Bypass -File (Join-Path $root 'audit-store-coverage.ps1') -Embed $embed -OutDir $OutDir
$__sw.Stop(); $script:StageTimes['audit-store-coverage'] = [math]::Round($__sw.Elapsed.TotalSeconds, 1)
if ($LASTEXITCODE -eq 2 -and -not $Force) { Write-Output 'HELD: a staple commodity is missing a store tile (see out\store-coverage-report.json). NOT publishing (run -Force to override once the render is fixed).'; exit 2 }

# ---- MATCHING-SOUNDNESS gate (HARD): a rule change that MOVED or DROPPED an existing product's commodity
# vs the reviewed baseline is a matching regression (the 2026-07-13 audit class). Hold until a human reviews
# and runs `audit-match-soundness.ps1 -Accept`. Steady state (no rule change) => 0 changes => passes. -Force overrides.
$__sw = [Diagnostics.Stopwatch]::StartNew()
& powershell -ExecutionPolicy Bypass -File (Join-Path $root 'audit-match-soundness.ps1') -OutDir $OutDir
$__sw.Stop(); $script:StageTimes['audit-match-soundness'] = [math]::Round($__sw.Elapsed.TotalSeconds, 1)
if ($LASTEXITCODE -eq 2 -and -not $Force) { Write-Output 'HELD: commodity matching changed vs the reviewed baseline (see out\audit\soundness-report.json). A product MOVED/DROPPED commodity. Review, then `audit-match-soundness.ps1 -Accept` (or -Force to override).'; exit 2 }
elseif ($LASTEXITCODE -eq 3) { Write-Output 'match-soundness: BLIND - it ingested ZERO products, so nothing this build proves any commodity matching is sound; the matching gate above passed on an empty examination, not on a clean result.' }

# ---- CATEGORY-COVERAGE gate (HARD): every commodity must be filed into exactly one category, else it renders in
# NO department/filter (invisible). This is what makes "add a new item" safe: forget to categorize it and the
# publish HOLDS. Daily pipeline never adds commodities, so it only trips right after a human adds one. -Force overrides.
$__sw = [Diagnostics.Stopwatch]::StartNew()
& powershell -ExecutionPolicy Bypass -File (Join-Path $root 'audit-category-coverage.ps1') -OutDir $OutDir
$__sw.Stop(); $script:StageTimes['audit-category-coverage'] = [math]::Round($__sw.Elapsed.TotalSeconds, 1)
if ($LASTEXITCODE -eq 2 -and -not $Force) { Write-Output 'HELD: a commodity is not in exactly one category (see out\category-coverage-report.json) - it would render in no filter. Add it to a category in categories.json (or -Force to override).'; exit 2 }

# ---- preserve the live post's current visibility (so a weekly refresh never reverts a manual paid-gate) ----
. (Join-Path $PSScriptRoot '..\lib\ghost-lib.ps1')   # 2026-07-26: single Ghost helper (was one of 50+ inline copies)
function New-GhostJWT { Get-GhostJWT -Key $adminKey }
# Preserve the live visibility robustly: cache the last-known value; on a READ FAILURE reuse the cache
# rather than defaulting to 'public' (which would silently un-gate + strip the paywall schema of a page
# Brad set to paid). Only fall back to 'public' when there is genuinely no prior value (first publish).
$visFile = Join-Path $OutDir 'last-visibility.txt'
$vis = $null
$ex  = $null   # stays $null unless the live post was actually READ this run - the change gate below refuses
               # to skip on a post it never saw (deleted, renamed or unreachable = republish, never assume)
try {
  $jwt = New-GhostJWT $adminKey
  # STATUS is fetched, not just visibility (post-batch review 2026-07-30). The change gate proves "already
  # live" from the signature plus [bool]$ex, and a DRAFT post returns a perfectly good $ex - so a -Draft run
  # followed by a normal run reported CURRENT and skipped the upsert forever, leaving the board permanently
  # unpublished. A post that is not status=published is NOT the page we would ship, whatever its bytes say.
  $ex = (Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/posts/slug/$slug/?fields=id,visibility,status" -Headers @{Authorization="Ghost $jwt";'Accept-Version'='v5.0'} -TimeoutSec 30).posts[0]
  if ($ex -and $ex.visibility) { $vis = [string]$ex.visibility }
  if ($ex -and ([string]$ex.status) -ne 'published') {
    Write-Output ("live post status is '" + [string]$ex.status + "', not 'published' - the change gate will NOT skip (a draft is not a live board)")
    $ex = $null
  }
} catch { $ex = $null }
if ($vis) { Set-Content -Path $visFile -Value $vis -Encoding ASCII }
elseif (Test-Path $visFile) { $vis = (Get-Content $visFile -Raw).Trim(); Write-Output ("WARN: visibility read failed - reusing last-known '$vis' (not defaulting to public)") }
else { $vis = 'public' }

# ---- CHANGE GATE (2026-07-30): never push a page to Ghost that is byte-identical to the one already there.
# Same shape as publish-store-guide.ps1's guide gate, one layer up. On 2026-07-29 this script ran 13 times
# and upserted the same week's board 12 times (out\logs\weekly-post-capture-2026-07.log).
# THE RENDERED EMBED IS THE HASH TARGET, not a list of inputs: it is what actually ships, so it covers every
# input including the ones an input list would forget - and it carries the SHA1 cache-bust of public\board.json
# and public\price-history.json, so a change anywhere inside either 2 MB feed changes this hash too.
# VISIBILITY is folded in because publish-resource.ps1 writes the paywall JSON-LD from it: a paid<->public
# flip with identical prices IS a content change.
# FAIL TOWARD DOING THE WORK - see Test-UpsertNeeded: a missing, empty or unreadable stamp, or a live post we
# could not read, all publish. This gate may only ever skip work it can prove is already live.
$sigFile = Join-Path $OutDir 'deals-page.sig'
$sig = (Get-FileHash $embed -Algorithm MD5).Hash + '|' + $vis
if (-not (Test-UpsertNeeded -Sig $sig -SigFile $sigFile -LiveSeen ([bool]$ex) -ForceFlag ([bool]$Force) -DraftFlag ([bool]$Draft))) {
  Write-Output ("CURRENT omaha-grocery-prices  (visibility=$vis, $commCount commodities, week " + [string]$doc.week_of + ") - built page is identical to the live one; Ghost upsert skipped (-Force to republish)")
} else {

  # ---- republish (publish-resource.ps1 upserts by slug) ----
  $pubArgs = @('-ExecutionPolicy','Bypass','-File',(Join-Path $root 'publish-resource.ps1'),
    '-Title',"Omaha's Cheapest Groceries This Week",
    '-Slug',$slug,
    '-HtmlFile',$embed,
    '-Excerpt',"Every grocery staple, compared across seven Omaha stores and ranked cheapest to priciest. Updated weekly.",
    '-MetaTitle',"Omaha's Cheapest Groceries This Week | Thrifty Crew",
    '-MetaDesc',"See the cheapest Omaha store for milk, eggs, chicken, produce and more this week. Hundreds of staples compared across Aldi, Walmart, Hy-Vee, Baker's, Fareway, Sam's Club and Family Fare.",
    '-Visibility',$vis)
  if ($Draft) { $pubArgs += '-Draft' }
  $__sw = [Diagnostics.Stopwatch]::StartNew()
  & powershell @pubArgs
  $__sw.Stop(); $script:StageTimes['ghost-board-upsert'] = [math]::Round($__sw.Elapsed.TotalSeconds, 1)
  $prc = $LASTEXITCODE
  if ($prc -ne 0) {
    Write-Output ("ERROR: Ghost upsert FAILED (rc=$prc) - live page NOT updated (change not published)")
    exit 1
  }
  # Stamp ONLY after a confirmed upsert, and never for a draft: a failed upsert or a draft must leave the
  # stamp as it was so the next run republishes. A stamp we cannot write is also a republish next time.
  if (-not $Draft) { try { Set-Content -Path $sigFile -Value $sig -Encoding ASCII } catch { Write-Output ("WARN: could not write $sigFile - the next run will republish (" + $_.Exception.Message + ")") } }
  Write-Output ("PUBLISHED omaha-grocery-prices  (visibility=$vis, $commCount commodities, week " + [string]$doc.week_of + ")")
}

# ---- dynamic og:image: shared links preview THIS WEEK'S real drops, not a static logo. The week param
# makes scrapers (Reddit/FB cache per-URL) re-fetch when the week changes. Non-fatal on failure. ----
try {
  $ogPng = Join-Path (Split-Path $root -Parent) 'public\share\omaha-drops.png'
  if (Test-Path $ogPng) {
    $ogUrl = 'https://feed.thriftycrew.com/share/omaha-drops.png?w=' + [string]$doc.week_of
    $jwt2 = New-GhostJWT $adminKey
    $cur = (Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/posts/slug/$slug/?fields=id,updated_at,og_image" -Headers @{Authorization="Ghost $jwt2";'Accept-Version'='v5.0'} -TimeoutSec 30).posts[0]
    if ($cur -and ([string]$cur.og_image) -ne $ogUrl) {
      $body = @{ posts = @(@{ og_image = $ogUrl; updated_at = [string]$cur.updated_at }) } | ConvertTo-Json -Depth 4
      Invoke-RestMethod -Method PUT -Uri "$apiUrl/ghost/api/admin/posts/$($cur.id)/" -Headers @{Authorization="Ghost $jwt2";'Accept-Version'='v5.0';'Content-Type'='application/json'} -Body $body -TimeoutSec 30 | Out-Null
      Write-Output ("og:image set to this week's drops graphic (?w=" + [string]$doc.week_of + ")")
    }
  }
} catch { Write-Output ("og:image update skipped: " + $_.Exception.Message) }

# ---- companion page: the per-store guide rides every board publish (non-fatal; its own coverage gate applies) ----
try {
  # Capture stdout so this line can tell PUBLISHED from SKIPPED. It printed "republished" on rc=0, but
  # publish-store-guide also exits 0 when its own change gate skips the upsert - which is how the 2026-07-29
  # audit counted 12 store-guide upserts from 12 log lines. Do NOT add 2>&1 here: this block runs under
  # EAP=Stop, where redirecting a native child's stderr turns its first stderr line into a terminating throw.
  $__sw = [Diagnostics.Stopwatch]::StartNew()
  $sgOut = & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'publish-store-guide.ps1')
  $__sw.Stop(); $script:StageTimes['publish-store-guide'] = [math]::Round($__sw.Elapsed.TotalSeconds, 1)
  $sgRc = $LASTEXITCODE
  if ($sgRc -eq 0) {
    if ((@($sgOut) -join ' ') -match 'guide unchanged') { Write-Output "store guide already current - upsert skipped" }
    else { Write-Output "store guide republished alongside the board" }
  }
  else { Write-Output ("store guide HELD/skipped (rc=$sgRc) - board publish unaffected") }
} catch { Write-Output ("store guide publish threw: " + $_.Exception.Message + " - board publish unaffected") }

# ---- trend pages: WEEKLY. 2026-07-26 efficiency fix: only the PUBLISHER was stamp-gated, so the two
# builders regenerated 425 tracked HTML files on EVERY price-change day for a publish that then no-oped.
# Check the stamp HERE and skip the builds too until a new board week lands.
try {
  $tpStamp = Join-Path $root 'out\trend-pages.stamp'
  $curWk = ''
  try {
    # EXACT same week derivation as publish-trend-pages' stamp logic (newest week_of across histories).
    # 2026-07-28: this read 'out\price-history.json' - A PATH THAT DOES NOT EXIST. The real file is
    # grocery\price-history.json (which is what publish-trend-pages itself uses). The bare catch below
    # swallowed the error, $curWk stayed empty, `if($curWk -and ...)` was always false, and this gate has
    # therefore never fired once since it was added. A silent catch around a path is how a whole feature
    # stays dead for weeks. It now logs instead of swallowing.
    $phd = Get-Content (Join-Path $root 'price-history.json') -Raw | ConvertFrom-Json
    $wks=@(); foreach($c in $phd.commodities){ foreach($e in $c.history){ $wks += [string]$e.week_of } }
    if($wks.Count){ $curWk = (@($wks | Sort-Object))[-1] }
  } catch { Write-Output ("trend gate: could not derive the current week (" + $_.Exception.Message + ") - falling through to a full rebuild") }
  $stampWk = if(Test-Path $tpStamp){ ((Get-Content $tpStamp -Raw) + '').Trim() } else { '' }
  if($curWk -and $stampWk -eq $curWk){
    Write-Output "trend pages up to date for week $curWk - builds skipped"
  } else {
    Invoke-Timed 'build-trend-pages' { & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'build-trend-pages.ps1') | Out-Null }
    Invoke-Timed 'build-trend-index' { & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'build-trend-index.ps1') | Out-Null }
    # Do NOT swallow the child's exit code. publish-trend-pages exits 1 when it cannot stamp, and because
    # this call piped to Out-Null and ignored $LASTEXITCODE, 80 failures a day were invisible for 11 days.
    # Report it; do NOT make it fatal - a trend-page problem must never hold the board publish.
    Invoke-Timed 'publish-trend-pages' { & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'publish-trend-pages.ps1') | Out-Null }
    $tprc = $LASTEXITCODE
    if ($tprc -ne 0) { Write-Output ("trend pages: publisher exited $tprc - it could NOT write its weekly stamp, so the next publish will redo all of them (see publish-trend-pages output)") }
    else { Write-Output "trend pages built + published (weekly stamp armed)" }
  }
} catch { Write-Output ("trend pages step threw: " + $_.Exception.Message + " - board publish unaffected") }

# One line, always, listing every child that ran and what it cost. Printed even when a stage was
# skipped, because "which stages ran at all" is half the question this answers.
if ($script:StageTimes.Count) {
  $__tot = 0; foreach ($__v in $script:StageTimes.Values) { $__tot += [double]$__v }
  Write-Output ("publish-deals-page timings ({0:n1} s total): " -f $__tot)
  foreach ($__k in $script:StageTimes.Keys) { Write-Output ("    {0,-24} {1,6} s" -f $__k, $script:StageTimes[$__k]) }
}
exit 0
