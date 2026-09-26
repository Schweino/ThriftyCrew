<#
  publish-trend-pages.ps1 - Upserts every generated trend page (out\trend\<id>.html) to Ghost
  as a PUBLIC post tagged "Price Tracker" (NOT "Resources", so the Resources hub is untouched).

  Slug:  <id>-price-omaha             (e.g. chicken-breast-price-omaha)
  Title: "<Label> Price in Omaha This Week"
  Meta:  "<Label> Price in Omaha This Week (Tracked Weekly) | Thrifty Crew"

  CONTENT GATE, NOT A WEEKLY ONE (2026-09-26, Brad's D3, design\PLAN-board-clock-2026-09-26.md). A page is upserted
  only when what it SHOWS changed: lib\trend-publish-key.ps1's Get-TcTrendPageHash over its fragment, title, excerpt
  and meta, compared with the hash recorded for its slug in out\trend-pages-published.json. Each hash is recorded the
  moment its page lands, so a run that dies half way has still recorded the pages it published
  (publish-wave-crash-loses-the-journal). After a run with no failure, out\trend-pages.stamp holds
  Get-TcTrendInputKey (price-history.json's content key), which publish-deals-page compares to skip the builds on a
  day no tracked price moved. Until 2026-09-26 both gates compared the newest week_of, which is the AD SET's date and
  does not move while no weekly ad is due, so a price that moved mid-week never reached these pages or the tracker.
  -Force republishes every page regardless.

  Key resolution copied from publish-resource.ps1: $env:GHOST_ADMIN_KEY, then a gitignored
  .ghostkey file here or in meal-prep\.
#>
param(
  [switch]$Force,
  [switch]$Draft
)

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$utf8 = New-Object System.Text.UTF8Encoding($false)

$HistoryFile = Join-Path $here 'price-history.json'
$TrendDir    = Join-Path $here 'out\trend'
$StampFile   = Join-Path $here 'out\trend-pages.stamp'
$LedgerFile  = Join-Path $here 'out\trend-pages-published.json'   # slug -> the page hash it was last published with
$MinWeeks    = 3

$adminKey = if ($env:GHOST_ADMIN_KEY) { $env:GHOST_ADMIN_KEY }
  elseif (Test-Path (Join-Path $here '.ghostkey')) { (Get-Content (Join-Path $here '.ghostkey') -Raw).Trim() }
  elseif (Test-Path (Join-Path (Split-Path $here -Parent) 'meal-prep\.ghostkey')) { (Get-Content (Join-Path (Split-Path $here -Parent) 'meal-prep\.ghostkey') -Raw).Trim() }
  else { throw 'Ghost admin key missing: set $env:GHOST_ADMIN_KEY or create meal-prep\.ghostkey' }
$apiUrl = 'https://map-to-success.ghost.io'

# Board store coverage, derived to a word so the copy can never silently go stale when a store is added. Read from the
# registry, never a copy of the store list here (Brad, 2026-09-19, backlog I192: convert on touch - converted
# 2026-09-26 with PLAN-board-clock's D3 change). An unreadable registry THROWS: publishing "tracked across <wrong
# number> stores" to every page is worse than publishing nothing today.
$StoreNames = @(@((Read-JsonFile (Join-Path $here 'stores.json')).stores) | Where-Object { $_ -and $_.name } | Sort-Object { [int]$_.order } | ForEach-Object { [string]$_.name })
if ($StoreNames.Count -eq 0) { throw 'publish-trend-pages: stores.json names no store - refusing to publish a store count' }
$numWords   = @('zero','one','two','three','four','five','six','seven','eight','nine','ten','eleven','twelve')
$StoreWord  = if ($StoreNames.Count -lt $numWords.Count) { $numWords[$StoreNames.Count] } else { [string]$StoreNames.Count }
. (Join-Path $PSScriptRoot '..\lib\ghost-lib.ps1')   # 2026-07-26: single Ghost helper (was one of 50+ inline copies)
. (Join-Path $PSScriptRoot '..\lib\trend-keep.ps1')  # 2026-08-04: single source for which commodities get a page
. (Join-Path $PSScriptRoot '..\lib\trend-publish-key.ps1')  # 2026-09-26: publish on CONTENT change (Brad's D3)
. (Join-Path $PSScriptRoot '..\lib\atomic-write.ps1')       # Write-TcAtomicFile: the per-page ledger is replaced whole
function New-GhostJWT { Get-GhostJWT -Key $adminKey }

# THE FOURTH COPY (2026-08-31). Same four-decimal renderer as build-trend-pages had, and this one writes
# the META DESCRIPTION - "This week: $0.9967 per lb at Aldi" was the line Google was showing for apples.
# Delegates to fmt-lib's Fmt-PriceBare, where the frozen fixtures are; the unit stays this file's job.
. (Join-Path $here 'fmt-lib.ps1')
function Format-Price { param([double]$p) return (Fmt-PriceBare $p) }

function Get-UnitPhrase { param([string]$u)
  switch ($u) {
    'lb'     { return 'per lb' }
    'oz'     { return 'per oz' }
    'floz'   { return 'per fl oz' }
    'each'   { return 'each' }
    'dozen'  { return 'per dozen' }
    'gallon' { return 'per gallon' }
    default  { return ('per ' + $u) }
  }
}

# ---------- load data + weekly gate ----------

if (-not (Test-Path $HistoryFile)) { throw "History file not found: $HistoryFile" }
$data = Read-JsonFile $HistoryFile

if (@($data.commodities).Count -eq 0) { throw 'No commodities found in price-history.json' }
$inputKey = Get-TcTrendInputKey $HistoryFile
# The per-page ledger. An unreadable one is treated as EMPTY, which republishes every page once - never as "all current".
$published = @{}
if (Test-Path -LiteralPath $LedgerFile) {
  try { $lj = Read-JsonFile $LedgerFile; foreach ($pp in $lj.pages.PSObject.Properties) { $published[$pp.Name] = [string]$pp.Value } } catch { $published = @{}; Write-Warning 'trend-pages-published.json unreadable - every page will be republished once' }
}
function Save-TrendLedger {
  $o = [ordered]@{ updated = (Get-Date).ToString('s'); note = 'slug -> Get-TcTrendPageHash of the page as last published (publish-trend-pages.ps1)'; pages = [ordered]@{} }
  foreach ($k in @($published.Keys | Sort-Object)) { $o.pages[$k] = $published[$k] }
  [void](Write-TcAtomicFile -Path $LedgerFile -Text ($o | ConvertTo-Json -Depth 4) -NoBom)
}
$unchanged = 0

if (-not (Test-Path $TrendDir)) { throw "Trend dir not found: $TrendDir  (run build-trend-pages.ps1 first)" }

# ---------- publish loop ----------

$status = if ($Draft) { 'draft' } else { 'published' }
$okCount = 0
$failCount = 0

foreach ($c in $data.commodities) {
  # MIRROR OF build-trend-pages.ps1:176. The builder skips recipe-sourced commodities, so no fragment is
  # ever written for them - but this publisher had no such filter, so it tried to publish 80 pages that
  # cannot exist, incremented $failCount 80 times, and the stamp below (written only when failCount is 0)
  # became STRUCTURALLY IMPOSSIBLE. Result: every publish since 2026-07-17 re-upserted all 491 trend posts,
  # 982 Ghost round trips plus 147s of Start-Sleep - about 86% of the 467-second publish. The stamp file
  # sat at 2026-07-17 for eleven days as the evidence, and nobody saw it because the caller pipes this
  # script to Out-Null and ignores its exit code. Two filters over one list must never drift apart.
  if ($c.src -eq 'recipe') { continue }
  # 2026-08-04: the >=$MinWeeks rule qualified 492 commodities and produced 492 near-duplicate pages
  # that Google refused to crawl. The keep-list in lib\trend-keep.ps1 is now the ONLY gate; MinWeeks
  # stays below it as a floor so a keep-listed item with no history still cannot publish an empty page.
  if (-not (Test-TrendKeep $c.id)) { continue }
  $hist = @($c.history | Sort-Object week_of)
  if ($hist.Count -lt $MinWeeks) { continue }

  $htmlFile = Join-Path $TrendDir ($c.id + '.html')
  if (-not (Test-Path $htmlFile)) {
    Write-Warning ('Missing fragment for {0}: {1} (run build-trend-pages.ps1)' -f $c.id, $htmlFile)
    $failCount++
    continue
  }
  $html = [IO.File]::ReadAllText($htmlFile, [Text.Encoding]::UTF8)
  if ([string]::IsNullOrWhiteSpace($html)) {
    Write-Warning ('Fragment is empty for {0}: {1}' -f $c.id, $htmlFile)
    $failCount++
    continue
  }

  $cur = $hist[$hist.Count - 1]
  $curPrice = Format-Price ([double]$cur.cheapest_price)
  $unitPhr = Get-UnitPhrase $c.unit

  $slug = $c.id + '-price-omaha'
  $title = $c.label + ' Price in Omaha This Week'
  $metaTitle = $c.label + ' Price in Omaha This Week (Tracked Weekly) | Thrifty Crew'
  $metaDesc = 'Cheapest ' + $c.label.ToLower() + ' in Omaha this week: ' + $curPrice + ' ' + $unitPhr + ' at ' + $cur.cheapest_store + '. Tracked weekly across ' + $StoreWord + ' stores, with the record low and full price history. Updates every week.'
  $excerpt = 'This week: ' + $curPrice + ' ' + $unitPhr + ' at ' + $cur.cheapest_store + '. Tracked weekly across ' + $StoreWord + ' Omaha stores.'

  $pageHash = Get-TcTrendPageHash $html $title $excerpt $metaTitle $metaDesc
  if (-not $Force -and $published.ContainsKey($slug) -and [string]::Equals($published[$slug], $pageHash, [StringComparison]::Ordinal)) { $unchanged++; continue }

  try {
    $jwt = New-GhostJWT $adminKey
    $existing = $null
    try { $existing = (Invoke-GhostApi -Uri "$apiUrl/ghost/api/admin/posts/slug/$slug/?fields=id,updated_at" -Headers @{Authorization = "Ghost $jwt"; 'Accept-Version' = (Get-GhostAcceptVersion)}).posts[0] } catch {}

    $lexObj = @{ root = [ordered]@{ children = @([ordered]@{ type = 'html'; version = 1; html = [string]$html }); direction = $null; format = ''; indent = 0; type = 'root'; version = 1 } }
    $lex = ConvertTo-Json $lexObj -Depth 12 -Compress

    $postObj = [ordered]@{
      title = $title; slug = $slug; lexical = $lex; status = $status; visibility = 'public';
      custom_excerpt = $excerpt; tags = @(@{ name = 'Price Tracker' });
      meta_title = $metaTitle; meta_description = $metaDesc;
      og_title = $metaTitle; og_description = $metaDesc; twitter_title = $metaTitle; twitter_description = $metaDesc
    }

    if ($existing) { $postObj.updated_at = $existing.updated_at; $method = 'Put'; $uri = "$apiUrl/ghost/api/admin/posts/$($existing.id)/" }
    else { $method = 'Post'; $uri = "$apiUrl/ghost/api/admin/posts/" }

    $payload = @{ posts = @($postObj) }
    $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $payload -Depth 14))
    $jwt = New-GhostJWT $adminKey
    $r = Invoke-RestMethod -Uri $uri -Method $method -Headers @{Authorization = "Ghost $jwt"; 'Accept-Version' = (Get-GhostAcceptVersion)} -ContentType 'application/json' -Body $bytes -TimeoutSec 30
    $saved = $r.posts[0]
    $verb = if ($existing) { 'UPDATED' } else { 'CREATED' }
    Write-Host ('{0}: /{1}/  status={2} visibility={3}' -f $verb, $slug, $saved.status, $saved.visibility) -ForegroundColor Green
    $okCount++
    # Recorded the moment it lands (a Draft run records nothing: a draft is not what readers see).
    if (-not $Draft) { $published[$slug] = $pageHash; Save-TrendLedger }
  } catch {
    Write-Warning ('FAILED {0}: {1}' -f $slug, $_.Exception.Message)
    $failCount++
  }
  Start-Sleep -Milliseconds 300
}

Write-Host ''
Write-Host ('Done: {0} upserted, {1} unchanged (content identical to what is live), {2} failed.' -f $okCount, $unchanged, $failCount)

# The stamp is the INPUT key, written after a run with no failure whether or not any page needed an upsert: "nothing
# changed" is a clean, complete result now, where the weekly gate needed at least one upsert to arm.
if ($failCount -eq 0 -and $inputKey -and -not $Draft) {
  [IO.File]::WriteAllText($StampFile, $inputKey, $utf8)
  Write-Host ('Stamp written: {0} = {1}' -f $StampFile, $inputKey)
} else {
  Write-Warning 'Not writing stamp (failures, a draft run, or no readable history), so the next run will rebuild and retry.'
  if ($failCount -gt 0) { exit 1 }
}
