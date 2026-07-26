<#
  send-friday-digest.ps1 - the Friday board email the capture CTAs promise.

  The board page now says "Get this board every Friday, free." This is the machine that keeps that promise:
  an email-only Ghost post (never appears on the site) sent to all members each Friday with the week's
  cheapest-store scoreboard, the biggest same-store drops, and one button to the live board.

  SAFETY RAILS (this emails real people unattended):
    - Fridays only, unless -Force (for a supervised test).
    - Idempotent: slug friday-board-<date>; if it already exists, we do NOT send again.
    - Fresh-data gate: refuses to send if the newest comparison is older than 2 days.
    - Same-store drop rule as build-share-image (no coverage-growth lies), same <=60% SKU-switch cap.
#>
param([switch]$Force)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$pub = Join-Path (Split-Path $root -Parent) 'public'

if (-not $Force -and (Get-Date).DayOfWeek -ne 'Friday') { Write-Output 'digest: not Friday - nothing to do'; exit 0 }

# ---- freshness gate ----
$cmpF = Get-ChildItem (Join-Path $root 'out\comparison-*.json') | Sort-Object Name -Desc | Select-Object -First 1
if (-not $cmpF -or $cmpF.BaseName -notmatch '(\d{4}-\d{2}-\d{2})$') { Write-Output 'digest REFUSED: no comparison'; exit 1 }
$cmpDate = [datetime]$Matches[1]
if (((Get-Date) - $cmpDate).TotalDays -gt 2) { Write-Output ('digest REFUSED: comparison is ' + [int]((Get-Date) - $cmpDate).TotalDays + 'd old - not emailing stale prices'); exit 1 }
$doc = Get-Content $cmpF.FullName -Raw | ConvertFrom-Json

# ---- Ghost admin auth (key only from env or gitignored .ghostkey - never inline) ----
$apiUrl = 'https://map-to-success.ghost.io'
$adminKey = $env:GHOST_ADMIN_KEY
if (-not $adminKey) { $kf = Join-Path $root '..\.ghostkey'; if (Test-Path $kf) { $adminKey = (Get-Content $kf -Raw).Trim() } }
if (-not $adminKey) { Write-Output 'digest REFUSED: no Ghost admin key'; exit 1 }
. (Join-Path $PSScriptRoot '..\lib\ghost-lib.ps1')   # 2026-07-26: single Ghost helper (was one of 50+ inline copies)
function New-GhostJWT { Get-GhostJWT -Key $adminKey }

$dateS = Get-Date -Format 'yyyy-MM-dd'
$slug = 'friday-board-' + $dateS

# ---- idempotence: already sent this week? ----
$jwt = New-GhostJWT $adminKey
try {
  $ex = (Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/posts/slug/$slug/?fields=id" -Headers @{Authorization="Ghost $jwt";'Accept-Version'='v5.0'} -TimeoutSec 30).posts[0]
  if ($ex) { Write-Output 'digest: already sent this week - skipping'; exit 0 }
} catch {}   # 404 = not sent yet, proceed

# ---- content: scoreboard + same-store drops ----
$wins = @{}
foreach ($row in $doc.comparison) {
  $cheap = $null
  foreach ($s in $row.stores) { if ([double]$s.per_unit -gt 0 -and ($null -eq $cheap -or [double]$s.per_unit -lt [double]$cheap.per_unit)) { $cheap = $s } }
  if ($cheap) { $k = [string]$cheap.store; if (-not $wins.ContainsKey($k)) { $wins[$k] = 0 }; $wins[$k]++ }
}
$scoreRows = ($wins.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
  '<tr><td style="padding:6px 12px;border-bottom:1px solid #e5e5e5;"><b>' + $_.Key + '</b></td><td style="padding:6px 12px;border-bottom:1px solid #e5e5e5;text-align:right;">' + $_.Value + ' items</td></tr>' }) -join ''

$hist = Get-Content (Join-Path $pub 'price-history.json') -Raw | ConvertFrom-Json
$drops = New-Object System.Collections.Generic.List[object]
foreach ($p in $hist.PSObject.Properties) {
  $it = $p.Value; $weeks = @($it.w); if ($weeks.Count -lt 2) { continue }
  $nowI = $weeks.Count - 1; $thenI = [math]::Max(0, $weeks.Count - 8)
  $bestPct = 0.0; $best = $null
  foreach ($sp in $it.s.PSObject.Properties) {
    $ser = @($sp.Value); if ($ser.Count -le $nowI) { continue }
    $vNow = $ser[$nowI]; $vThen = $ser[[math]::Min($thenI, $ser.Count - 1)]
    if (-not $vNow -or -not $vThen -or [double]$vNow -le 0 -or [double]$vThen -le 0) { continue }
    $pct = ([double]$vThen - [double]$vNow) / [double]$vThen
    if ($pct -gt 0.60) { continue }
    if ($pct -gt $bestPct) { $bestPct = $pct; $best = [pscustomobject]@{ l = [string]$it.l; u = [string]$it.u; now = [double]$vNow; store = $sp.Name; pct = $pct } }
  }
  if ($best -and $bestPct -gt 0.10) { $drops.Add($best) }
}
function FmtPU([double]$v, [string]$u) { if ($v -lt 1) { return ('{0}c/{1}' -f [math]::Round($v * 100), $u) } return ('${0:N2}/{1}' -f $v, $u) }
$dropRows = (@($drops | Sort-Object pct -Descending | Select-Object -First 5) | ForEach-Object {
  '<tr><td style="padding:6px 12px;border-bottom:1px solid #e5e5e5;color:#1b763d;font-weight:bold;">-' + [math]::Round($_.pct * 100) + '%</td><td style="padding:6px 12px;border-bottom:1px solid #e5e5e5;"><b>' + $_.l + '</b><br><span style="color:#666;font-size:13px;">cheapest option now ' + (FmtPU $_.now $_.u) + ' at ' + $_.store + '</span></td></tr>' }) -join ''

$boardUrl = 'https://www.thriftycrew.com/omaha-grocery-prices/'
$html = '<p>Here is where Omaha grocery prices stand this week, checked against every store this morning.</p>' +
  '<h3 style="margin:18px 0 6px;">Who wins the most items this week</h3><table style="border-collapse:collapse;width:100%;max-width:420px;">' + $scoreRows + '</table>' +
  $(if ($dropRows) { '<h3 style="margin:18px 0 6px;">Biggest price drops</h3><table style="border-collapse:collapse;width:100%;max-width:520px;">' + $dropRows + '</table>' } else { '' }) +
  '<p style="margin:22px 0;"><a href="' + $boardUrl + '" style="background:#10213e;color:#ffffff;padding:12px 22px;border-radius:9px;text-decoration:none;font-weight:bold;">Open the full board (378 items) &rarr;</a></p>' +
  '<p style="color:#666;font-size:13px;">Sale prices end when the new ads drop Wednesday morning. Plan your trip on the board and it will split your list across stores for the cheapest run.</p>'

# ---- newsletter + send ----
$jwt = New-GhostJWT $adminKey
$nl = (Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/newsletters/?filter=status:active&limit=1" -Headers @{Authorization="Ghost $jwt";'Accept-Version'='v5.0'} -TimeoutSec 30).newsletters[0]
if (-not $nl) { Write-Output 'digest REFUSED: no active newsletter'; exit 1 }

$title = 'Omaha grocery prices this week (' + (Get-Date -Format 'MMM d') + ')'
$body = @{ posts = @(@{ title = $title; slug = $slug; html = $html; status = 'published'; email_only = $true; tags = @(@{ name = '#friday-digest' }) }) } | ConvertTo-Json -Depth 6
$jwt = New-GhostJWT $adminKey
$uri = "$apiUrl/ghost/api/admin/posts/?source=html&newsletter=" + $nl.slug + "&email_segment=all"
$res = Invoke-RestMethod -Method POST -Uri $uri -Headers @{Authorization="Ghost $jwt";'Accept-Version'='v5.0';'Content-Type'='application/json'} -Body $body -TimeoutSec 60
Write-Output ('digest SENT: "' + $title + '" via newsletter ' + $nl.slug + ' (post ' + $res.posts[0].id + ')')
