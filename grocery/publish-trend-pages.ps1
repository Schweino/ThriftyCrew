<#
  publish-trend-pages.ps1 - Upserts every generated trend page (out\trend\<id>.html) to Ghost
  as a PUBLIC post tagged "Price Tracker" (NOT "Resources", so the Resources hub is untouched).

  Slug:  <id>-price-omaha             (e.g. chicken-breast-price-omaha)
  Title: "<Label> Price in Omaha This Week"
  Meta:  "<Label> Price in Omaha This Week (Tracked Weekly) | Thrifty Crew"

  WEEKLY GATE: after a successful full run this script writes out\trend-pages.stamp containing
  the newest week_of in price-history.json. On the next run, if the stamp already equals the
  newest week_of, it exits 0 immediately and does nothing, so a daily caller only republishes
  when a new week of history lands. Use -Force to republish anyway.

  Key resolution copied from publish-resource.ps1: $env:GHOST_ADMIN_KEY, then a gitignored
  .ghostkey file here or in meal-prep\.
#>
param(
  [switch]$Force,
  [switch]$Draft
)

$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$utf8 = New-Object System.Text.UTF8Encoding($false)

$HistoryFile = Join-Path $here 'price-history.json'
$TrendDir    = Join-Path $here 'out\trend'
$StampFile   = Join-Path $here 'out\trend-pages.stamp'
$MinWeeks    = 3

$adminKey = if ($env:GHOST_ADMIN_KEY) { $env:GHOST_ADMIN_KEY }
  elseif (Test-Path (Join-Path $here '.ghostkey')) { (Get-Content (Join-Path $here '.ghostkey') -Raw).Trim() }
  elseif (Test-Path (Join-Path (Split-Path $here -Parent) 'meal-prep\.ghostkey')) { (Get-Content (Join-Path (Split-Path $here -Parent) 'meal-prep\.ghostkey') -Raw).Trim() }
  else { throw 'Ghost admin key missing: set $env:GHOST_ADMIN_KEY or create meal-prep\.ghostkey' }
$apiUrl = 'https://map-to-success.ghost.io'

# Board store coverage - keep the count in lockstep with $storeOrder (build-deals-page.ps1) / the audit store lists.
# Derived to a word so the copy can never silently go stale when a store is added.
$StoreNames = @('Hy-Vee','Aldi','Family Fare','Fareway',"Baker's","Sam's Club",'Walmart')
$numWords   = @('zero','one','two','three','four','five','six','seven','eight','nine','ten','eleven','twelve')
$StoreWord  = if ($StoreNames.Count -lt $numWords.Count) { $numWords[$StoreNames.Count] } else { [string]$StoreNames.Count }
. (Join-Path $PSScriptRoot '..\lib\ghost-lib.ps1')   # 2026-07-26: single Ghost helper (was one of 50+ inline copies)
function New-GhostJWT { Get-GhostJWT -Key $adminKey }

function Format-Price { param([double]$p)
  $r = [math]::Round($p, 4)
  if ($r -ge 1) { return ('${0:N2}' -f $r) }
  $s = $r.ToString('0.0000', [System.Globalization.CultureInfo]::InvariantCulture)
  $s = $s.TrimEnd('0')
  $parts = $s.Split('.')
  $dec = ''
  if ($parts.Length -gt 1) { $dec = $parts[1] }
  while ($dec.Length -lt 2) { $dec = $dec + '0' }
  return ('$' + $parts[0] + '.' + $dec)
}

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
$data = Get-Content $HistoryFile -Raw | ConvertFrom-Json

$allWeeks = @()
foreach ($c in $data.commodities) { foreach ($e in $c.history) { $allWeeks += [string]$e.week_of } }
if ($allWeeks.Count -eq 0) { throw 'No history entries found in price-history.json' }
$newestWeek = (@($allWeeks | Sort-Object))[-1]

if (-not $Force) {
  if (Test-Path $StampFile) {
    $stamp = ([string](Get-Content $StampFile -Raw)).Trim()
    if ($stamp -eq $newestWeek) {
      Write-Host ('Trend pages already published for week {0} (stamp match). Nothing to do. Use -Force to republish.' -f $newestWeek)
      exit 0
    }
  }
}

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

  try {
    $jwt = New-GhostJWT $adminKey
    $existing = $null
    try { $existing = (Invoke-GhostApi -Uri "$apiUrl/ghost/api/admin/posts/slug/$slug/?fields=id,updated_at" -Headers @{Authorization = "Ghost $jwt"; 'Accept-Version' = 'v5.0'}).posts[0] } catch {}

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
    $r = Invoke-RestMethod -Uri $uri -Method $method -Headers @{Authorization = "Ghost $jwt"; 'Accept-Version' = 'v5.0'} -ContentType 'application/json' -Body $bytes -TimeoutSec 30
    $saved = $r.posts[0]
    $verb = if ($existing) { 'UPDATED' } else { 'CREATED' }
    Write-Host ('{0}: /{1}/  status={2} visibility={3}' -f $verb, $slug, $saved.status, $saved.visibility) -ForegroundColor Green
    $okCount++
  } catch {
    Write-Warning ('FAILED {0}: {1}' -f $slug, $_.Exception.Message)
    $failCount++
  }
  Start-Sleep -Milliseconds 300
}

Write-Host ''
Write-Host ('Done: {0} upserted, {1} failed.' -f $okCount, $failCount)

if ($failCount -eq 0 -and $okCount -gt 0) {
  [IO.File]::WriteAllText($StampFile, $newestWeek, $utf8)
  Write-Host ('Stamp written: {0} = {1}' -f $StampFile, $newestWeek)
} else {
  Write-Warning 'Not writing stamp (failures or nothing published), so the next run will retry.'
  if ($failCount -gt 0) { exit 1 }
}
