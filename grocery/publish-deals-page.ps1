<#
  publish-deals-page.ps1 - The single, gated PUBLISH action for the public Omaha grocery page. HEADLESS
  (no browser). Rebuilds out\deals-page-embed.html from the newest board, runs a COVERAGE GATE so a
  degraded/half-empty matrix is NEVER pushed live, then upserts the Ghost Resources post
  (slug omaha-grocery-prices) PRESERVING its current visibility (so a weekly refresh never un-gates a
  page Brad later set to paid).

  Exit codes:  0 = published   2 = HELD (coverage gate failed; caller should alert)   1 = error
  Params: -CompareFile <path> (default newest)  -MinCommodities 25  -MinPerStore 15  -Force (skip gate)  -Draft
#>
param([string]$CompareFile = "", [int]$MinCommodities = 25, [int]$MinPerStore = 15, [switch]$Force, [switch]$Draft)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$OutDir = Join-Path $root 'out'
$slug   = 'omaha-grocery-prices'
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
  & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'audit-price-mode.ps1') | Out-Null
  if ($LASTEXITCODE -eq 2) { Write-Output "price-mode: an Instacart store is UNVERIFIED - compare-deals EXCLUDED it from the board. Re-capture In-Store + stamp mode_verified to restore it." }
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
try { & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'audit-name-drift.ps1') | Out-Null } catch {}
# Board-price override pins are GENERATED UPSTREAM (check-ad-cycles runs generate-board-overrides.ps1 BEFORE
# guards.ps1) and only APPLIED here. Publish must never mint a number the guards have not seen: on 2026-07-23
# this script regenerated pins post-gate and shipped 37 wrong-basis prices (pack price pinned onto per-item
# cells) that guards would have refused. If the pins file looks stale, re-run the pipeline, not this script.
& powershell -ExecutionPolicy Bypass -File (Join-Path $root 'build-deals-page.ps1') -CompareFile $CompareFile -Out $embed -Embed | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Output ("ERROR: page build FAILED (rc=$LASTEXITCODE) - not publishing"); exit 1 }
if (-not (Test-Path $embed) -or ((Get-Item $embed).Length -lt 2000)) { Write-Output 'ERROR: page build produced no/short file'; exit 1 }
# Link-coverage self-check: how many priced chips render NO "See item" link (or Does-not-carry cell)? A spike
# means links are being wrongly suppressed (a stale audit, an over-tight price guard, or wrong-product data).
# Surfaced, never fatal - the board still publishes; this is an early-warning so it can't silently regress again.
try {
  # Chips live in public/board.json now (they are display:none until a row opens, and inlining them pushed the
  # Ghost upsert past its timeout). Counting them in the embed would find ZERO and report perfect coverage -
  # a blind check. Read the same rendered chip html from the feed the browser injects.
  $nl = 0
  $bfeed = Join-Path (Split-Path $root -Parent) 'public\board.json'
  if (Test-Path $bfeed) {
    $bj = Get-Content $bfeed -Raw | ConvertFrom-Json
    foreach ($bp in $bj.PSObject.Properties) {
      foreach ($cp in [regex]::Matches([string]$bp.Value, "<div class='pg-chip[^']*' data-store=`"[^`"]+`" data-pu='[^']*'>(.*?)</div>", 'Singleline')) { if ($cp.Groups[1].Value -notmatch 'pg-see') { $nl++ } }
    }
  } else {
    $eh = Get-Content $embed -Raw
    foreach ($rw in [regex]::Matches($eh, "data-id='[^']+'(.*?)</article>", 'Singleline')) {
      foreach ($cp in [regex]::Matches($rw.Groups[1].Value, "<div class='pg-chip[^']*' data-store=`"[^`"]+`" data-pu='[^']*'>(.*?)</div>", 'Singleline')) { if ($cp.Groups[1].Value -notmatch 'pg-see') { $nl++ } }
    }
  }
  Write-Output ("link-coverage: $nl priced chip(s) with no See-item link")
  if ($nl -gt 0) { Write-Output ("WARN: $nl chips missing links (target 0 - Brad's invariant: every price has a link) - check consistency-report.json no_link / product-urls / the identity gate in build-deals-page.ps1") }
} catch {}

# ---- ALL-STORES-SHOWN invariant (HARD gate): every staple commodity must render a tile for ALL 7 stores - a
# price, or a "Doesn't carry / No price yet - See it? Let us know!" card. A store missing from a commodity row
# is the exact blueberries drop-off Brad caught; do NOT ship a board that hides a store. -Force overrides.
& powershell -ExecutionPolicy Bypass -File (Join-Path $root 'audit-store-coverage.ps1') -Embed $embed -OutDir $OutDir
if ($LASTEXITCODE -eq 2 -and -not $Force) { Write-Output 'HELD: a staple commodity is missing a store tile (see out\store-coverage-report.json). NOT publishing (run -Force to override once the render is fixed).'; exit 2 }

# ---- MATCHING-SOUNDNESS gate (HARD): a rule change that MOVED or DROPPED an existing product's commodity
# vs the reviewed baseline is a matching regression (the 2026-07-13 audit class). Hold until a human reviews
# and runs `audit-match-soundness.ps1 -Accept`. Steady state (no rule change) => 0 changes => passes. -Force overrides.
& powershell -ExecutionPolicy Bypass -File (Join-Path $root 'audit-match-soundness.ps1') -OutDir $OutDir
if ($LASTEXITCODE -eq 2 -and -not $Force) { Write-Output 'HELD: commodity matching changed vs the reviewed baseline (see out\audit\soundness-report.json). A product MOVED/DROPPED commodity. Review, then `audit-match-soundness.ps1 -Accept` (or -Force to override).'; exit 2 }

# ---- CATEGORY-COVERAGE gate (HARD): every commodity must be filed into exactly one category, else it renders in
# NO department/filter (invisible). This is what makes "add a new item" safe: forget to categorize it and the
# publish HOLDS. Daily pipeline never adds commodities, so it only trips right after a human adds one. -Force overrides.
& powershell -ExecutionPolicy Bypass -File (Join-Path $root 'audit-category-coverage.ps1') -OutDir $OutDir
if ($LASTEXITCODE -eq 2 -and -not $Force) { Write-Output 'HELD: a commodity is not in exactly one category (see out\category-coverage-report.json) - it would render in no filter. Add it to a category in categories.json (or -Force to override).'; exit 2 }

# ---- preserve the live post's current visibility (so a weekly refresh never reverts a manual paid-gate) ----
. (Join-Path $PSScriptRoot '..\lib\ghost-lib.ps1')   # 2026-07-26: single Ghost helper (was one of 50+ inline copies)
function New-GhostJWT { Get-GhostJWT -Key $adminKey }
# Preserve the live visibility robustly: cache the last-known value; on a READ FAILURE reuse the cache
# rather than defaulting to 'public' (which would silently un-gate + strip the paywall schema of a page
# Brad set to paid). Only fall back to 'public' when there is genuinely no prior value (first publish).
$visFile = Join-Path $OutDir 'last-visibility.txt'
$vis = $null
try {
  $jwt = New-GhostJWT $adminKey
  $ex = (Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/posts/slug/$slug/?fields=id,visibility" -Headers @{Authorization="Ghost $jwt";'Accept-Version'='v5.0'} -TimeoutSec 30).posts[0]
  if ($ex -and $ex.visibility) { $vis = [string]$ex.visibility }
} catch {}
if ($vis) { Set-Content -Path $visFile -Value $vis -Encoding ASCII }
elseif (Test-Path $visFile) { $vis = (Get-Content $visFile -Raw).Trim(); Write-Output ("WARN: visibility read failed - reusing last-known '$vis' (not defaulting to public)") }
else { $vis = 'public' }

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
& powershell @pubArgs
$prc = $LASTEXITCODE
if ($prc -ne 0) {
  Write-Output ("ERROR: Ghost upsert FAILED (rc=$prc) - live page NOT updated (change not published)")
  exit 1
}
Write-Output ("PUBLISHED omaha-grocery-prices  (visibility=$vis, $commCount commodities, week " + [string]$doc.week_of + ")")

# ---- dynamic og:image: shared links preview THIS WEEK'S real drops, not a static logo. The week param
# makes scrapers (Reddit/FB cache per-URL) re-fetch when the week changes. Non-fatal on failure. ----
try {
  $ogPng = Join-Path (Split-Path $root -Parent) 'public\share\omaha-drops.png'
  if (Test-Path $ogPng) {
    $ogUrl = 'https://smp-feed.ancient-snow-93df.workers.dev/share/omaha-drops.png?w=' + [string]$doc.week_of
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
  & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'publish-store-guide.ps1') | Out-Null
  if ($LASTEXITCODE -eq 0) { Write-Output "store guide republished alongside the board" }
  else { Write-Output ("store guide HELD/skipped (rc=$LASTEXITCODE) - board publish unaffected") }
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
  $stampWk = if(Test-Path $tpStamp){ ([string](Get-Content $tpStamp -Raw)).Trim() } else { '' }
  if($curWk -and $stampWk -eq $curWk){
    Write-Output "trend pages up to date for week $curWk - builds skipped"
  } else {
    & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'build-trend-pages.ps1') | Out-Null
    & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'build-trend-index.ps1') | Out-Null
    # Do NOT swallow the child's exit code. publish-trend-pages exits 1 when it cannot stamp, and because
    # this call piped to Out-Null and ignored $LASTEXITCODE, 80 failures a day were invisible for 11 days.
    # Report it; do NOT make it fatal - a trend-page problem must never hold the board publish.
    & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'publish-trend-pages.ps1') | Out-Null
    $tprc = $LASTEXITCODE
    if ($tprc -ne 0) { Write-Output ("trend pages: publisher exited $tprc - it could NOT write its weekly stamp, so the next publish will redo all of them (see publish-trend-pages output)") }
    else { Write-Output "trend pages built + published (weekly stamp armed)" }
  }
} catch { Write-Output ("trend pages step threw: " + $_.Exception.Message + " - board publish unaffected") }
exit 0
