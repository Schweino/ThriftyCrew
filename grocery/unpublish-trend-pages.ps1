<#
  unpublish-trend-pages.ps1 - Takes the 472 retired /<id>-price-omaha/ posts out of circulation by
  setting them to DRAFT (never deleting: draft is reversible, delete is not).

  Context (2026-08-04): the trend set was cut from 492 pages to 20 (lib\trend-keep.ps1). Those 472 posts
  drew 0 Google impressions in 28 days, flooded the homepage post feed with cards like "Rutabagas Price
  in Omaha This Week", and account for most of the 475 URLs Google refused to crawl at all.

  ORDER GATE - this script REFUSES to run until the redirects are live. Ghost matches redirects at the
  routing layer BEFORE it serves a post, so a retired slug starts 301ing the moment the redirect file is
  uploaded, even while the post still exists. That makes the redirect upload independently verifiable,
  and it means unpublishing can never be what creates a 404. The gate probes real URLs over HTTP; it
  does not trust a local file.

  Idempotent and resumable: a post already in draft is skipped, so a half-finished run just continues.

  Usage:
    powershell -ExecutionPolicy Bypass -File unpublish-trend-pages.ps1 -WhatIf   # report only, no writes
    powershell -ExecutionPolicy Bypass -File unpublish-trend-pages.ps1
#>
param(
  [switch]$WhatIf,
  [int]$ProbeCount = 5,
  [string]$Target = '/omaha-grocery-prices/'
)

$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $here '..\lib\ghost-lib.ps1')
. (Join-Path $here '..\lib\trend-keep.ps1')

$apiUrl  = 'https://map-to-success.ghost.io'
$siteUrl = 'https://www.thriftycrew.com'

# ---------- work out which posts are retired ----------
$data = Get-Content (Join-Path $here 'price-history.json') -Raw | ConvertFrom-Json
$live = @($data.commodities | ForEach-Object { [string]$_.id })
$stale = Get-TrendKeepStale -LiveIds $live
if ($stale.Count -gt 0) { throw ("trend-keep.json names {0} id(s) missing from price-history.json: {1}" -f $stale.Count, ($stale -join ', ')) }

$retired = @($data.commodities |
  Where-Object { $_.src -ne 'recipe' -and @($_.history).Count -ge 3 -and -not (Test-TrendKeep $_.id) } |
  ForEach-Object { [string]$_.id } | Sort-Object)
if ($retired.Count -eq 0) { throw 'Nothing retired - refusing to run.' }

Write-Host ("retired trend pages: {0}   kept: {1}" -f $retired.Count, (Get-TrendKeep).Count) -ForegroundColor Cyan

# ---------- ORDER GATE: redirects must already be live ----------
# Probe evenly-spaced retired slugs rather than the first N, so an alphabetically-clustered partial
# upload cannot pass the gate.
$probeIdx = @()
for ($i = 0; $i -lt $ProbeCount; $i++) { $probeIdx += [int][math]::Floor($i * ($retired.Count - 1) / [math]::Max(1, ($ProbeCount - 1))) }
$probeIdx = @($probeIdx | Select-Object -Unique)

$bad = @()
foreach ($ix in $probeIdx) {
  $slug = $retired[$ix] + '-price-omaha'
  $url  = "$siteUrl/$slug/"
  try {
    $r = Invoke-WebRequest -Uri $url -MaximumRedirection 0 -ErrorAction SilentlyContinue -UseBasicParsing -TimeoutSec 30
    $code = [int]$r.StatusCode
    $loc  = [string]$r.Headers['Location']
  } catch {
    $resp = $_.Exception.Response
    $code = if ($resp) { [int]$resp.StatusCode } else { 0 }
    $loc  = if ($resp) { [string]$resp.Headers['Location'] } else { '' }
  }
  if ($code -ne 301 -or ($loc -notlike "*$Target")) { $bad += ("{0} -> {1} {2}" -f $slug, $code, $loc) }
}

if ($bad.Count -gt 0) {
  Write-Host ''
  Write-Host 'BLOCKED: the redirects are not live yet.' -ForegroundColor Red
  Write-Host 'Upload grocery\out\trend-redirects.yaml (merged form: the file staged for Ghost) under' -ForegroundColor Red
  Write-Host 'Ghost Admin -> Settings -> Labs -> Redirects -> Upload redirects file, then re-run.' -ForegroundColor Red
  Write-Host 'Probes that did not 301:' -ForegroundColor Red
  $bad | ForEach-Object { Write-Host ("  " + $_) -ForegroundColor Red }
  exit 1
}
Write-Host ("order gate OK: {0}/{0} probed slugs already 301 to {1}" -f $probeIdx.Count, $Target) -ForegroundColor Green

# ---------- unpublish ----------
$key = Get-GhostKey -Root (Split-Path $here -Parent)
$done = 0; $skipped = 0; $missing = 0; $failed = 0
$i = 0
foreach ($id in $retired) {
  $i++
  $slug = $id + '-price-omaha'
  # Mint a fresh JWT periodically: the token is only valid for 5 minutes and this loop runs far longer.
  if ($i % 40 -eq 1) { $jwt = Get-GhostJWT -Key $key; $h = @{ Authorization = "Ghost $jwt"; 'Accept-Version' = 'v5.0' } }

  $post = $null
  try { $post = (Invoke-GhostApi -Uri "$apiUrl/ghost/api/admin/posts/slug/$slug/?fields=id,status,updated_at" -Headers $h).posts[0] }
  catch { $missing++; continue }
  if (-not $post) { $missing++; continue }

  # SAFETY: only ever touch a slug that ends in -price-omaha and is not keep-listed.
  if ($slug -notmatch '-price-omaha$') { throw ("refusing to touch unexpected slug: {0}" -f $slug) }
  if (Test-TrendKeep $id)              { throw ("refusing to unpublish a keep-listed id: {0}" -f $id) }

  if ($post.status -eq 'draft') { $skipped++; continue }
  if ($WhatIf) { Write-Host ("WHATIF would draft /{0}/ (currently {1})" -f $slug, $post.status); $done++; continue }

  $body = (ConvertTo-Json @{ posts = @(@{ id = $post.id; status = 'draft'; updated_at = $post.updated_at }) } -Depth 6 -Compress)
  try {
    Invoke-GhostApi -Method PUT -Uri "$apiUrl/ghost/api/admin/posts/$($post.id)/" -Headers ($h + @{ 'Content-Type' = 'application/json' }) -Body $body | Out-Null
    $done++
    if ($done % 25 -eq 0) { Write-Host ("  ... {0}/{1}" -f $done, $retired.Count) -ForegroundColor DarkGray }
  } catch { $failed++; Write-Warning ("FAILED {0}: {1}" -f $slug, $_.Exception.Message) }
}

Write-Host ''
Write-Host ("drafted={0}  already-draft={1}  not-found={2}  failed={3}  (of {4} retired)" -f $done, $skipped, $missing, $failed, $retired.Count) -ForegroundColor Cyan
if ($failed -gt 0) { exit 1 }
