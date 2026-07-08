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
$stores = @('Hy-Vee','Aldi','Family Fare',"Baker's","Sam's Club",'Walmart')
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

# ---- refresh the link audits so the builder can suppress any wrong (form-flip) "See item" link ----
try { & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'audit-links.ps1') | Out-Null } catch {}
try { & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'audit-name-drift.ps1') | Out-Null } catch {}

# ---- rebuild the embed page (no <h1>; Ghost's post title is the H1) ----
# Delete the previous embed FIRST and check the builder's exit code: without both, a build crash left
# yesterday's embed in place (> size floor), which then published as if fresh AND stamped the signature -
# the price change was silently lost forever.
$embed = Join-Path $OutDir 'deals-page-embed.html'
Remove-Item $embed -ErrorAction SilentlyContinue
& powershell -ExecutionPolicy Bypass -File (Join-Path $root 'build-deals-page.ps1') -CompareFile $CompareFile -Out $embed -Embed | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Output ("ERROR: page build FAILED (rc=$LASTEXITCODE) - not publishing"); exit 1 }
if (-not (Test-Path $embed) -or ((Get-Item $embed).Length -lt 2000)) { Write-Output 'ERROR: page build produced no/short file'; exit 1 }

# ---- preserve the live post's current visibility (so a weekly refresh never reverts a manual paid-gate) ----
function New-GhostJWT { param($key)
  $p=$key -split ':'; $id=$p[0]; $secretHex=$p[1]
  $sb=New-Object byte[] ($secretHex.Length/2); for($i=0;$i -lt $sb.Length;$i++){ $sb[$i]=[Convert]::ToByte($secretHex.Substring($i*2,2),16) }
  $now=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  $h='{"alg":"HS256","typ":"JWT","kid":"'+$id+'"}'; $pl='{"iat":'+$now+',"exp":'+($now+300)+',"aud":"/admin/"}'
  $b64={param($b)[Convert]::ToBase64String($b).TrimEnd('=').Replace('+','-').Replace('/','_')}
  $si=(& $b64 ([Text.Encoding]::UTF8.GetBytes($h)))+'.'+(& $b64 ([Text.Encoding]::UTF8.GetBytes($pl)))
  $hm=New-Object System.Security.Cryptography.HMACSHA256 (,$sb); return $si+'.'+(& $b64 ($hm.ComputeHash([Text.Encoding]::UTF8.GetBytes($si))))
}
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
  '-Excerpt',"Every grocery staple, compared across six Omaha stores and ranked cheapest to priciest. Updated weekly.",
  '-MetaTitle',"Omaha's Cheapest Groceries This Week | Simple Money Playbook",
  '-MetaDesc',"See the cheapest Omaha store for milk, eggs, chicken, produce and more this week. 29 staples compared across Aldi, Walmart, Hy-Vee, Baker's, Sam's Club and Family Fare.",
  '-Visibility',$vis)
if ($Draft) { $pubArgs += '-Draft' }
& powershell @pubArgs
$prc = $LASTEXITCODE
if ($prc -ne 0) {
  Write-Output ("ERROR: Ghost upsert FAILED (rc=$prc) - live page NOT updated (change not published)")
  exit 1
}
Write-Output ("PUBLISHED omaha-grocery-prices  (visibility=$vis, $commCount commodities, week " + [string]$doc.week_of + ")")
exit 0
