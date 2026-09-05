<#
  notify-item-added.ps1 - the IF-CONDITION for "email me when my suggested item is added" (Brad, 2026-07-12).

  Requesters from /suggest-an-item/ are usually NOT site members, so NOTHING persistent is created for them:
  each request with a notify email sits as a Ghost DRAFT post tagged #item-request-queue (written by the
  Worker's /submit; invisible to visitors). This script runs daily in check-ad-cycles' downstream:

    1. Diffs the ids on TODAY's board against notify-known-ids.json (state, committed; seeded on first run).
    2. For each NEW commodity id, matches its own include/exclude rules against every queued request's item
       text. A hit = the thing they asked for is now live.
    3. Sends the requester a ONE-OFF email via the Worker's authed POST /notify (the Worker holds the Gmail
       secrets, so this works from the cloud run too; auth = SHA-256 of the shared GHOST_ADMIN_KEY - the key
       itself never travels). No membership, no newsletter, no list.
    4. Deletes the queue draft on success; expires drafts older than 120 days (item never got added).

  State only advances when the run completes, so a failed send retries on the next daily run.
  -DryRun prints what WOULD happen (no emails, no deletes, no state write).
#>
param([switch]$DryRun, [string]$OutDir = "")
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
$stateFile = Join-Path $root 'notify-known-ids.json'
$workerBase = 'https://feed.thriftycrew.com'

# ---- Ghost admin key (env var in the cloud, .ghostkey locally) + JWT ----
$adminKey = $env:GHOST_ADMIN_KEY
if (-not $adminKey) { $kf = Join-Path (Split-Path $root -Parent) 'meal-prep\.ghostkey'; if (Test-Path $kf) { $adminKey = (Get-Content $kf -Raw).Trim() } }
if (-not $adminKey) { Write-Output 'notify-item-added: SKIP (no GHOST_ADMIN_KEY)'; exit 0 }
$apiUrl = 'https://map-to-success.ghost.io'
. (Join-Path $PSScriptRoot '..\lib\ghost-lib.ps1')   # 2026-07-26: single Ghost helper (was one of 50+ inline copies)
function New-GhostJWT { Get-GhostJWT -Key $adminKey }
# /notify auth = SHA-256 hex of the admin key (the Worker computes the same; key never travels)
$sha = [Security.Cryptography.SHA256]::Create()
$notifyAuth = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($adminKey)) | ForEach-Object { $_.ToString('x2') })

# ---- today's board ids (only ids actually rendered: >=1 store) ----
$cmpF = Get-ChildItem (Join-Path $OutDir 'comparison-*.json') -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
if (-not $cmpF) { Write-Output 'notify-item-added: SKIP (no comparison file)'; exit 0 }
$cmp = @((Read-JsonFile $cmpF.FullName).comparison)
$boardIds = @{}; $rowById = @{}
foreach ($r in $cmp) { if (@($r.stores).Count -ge 1) { $boardIds[[string]$r.id] = $true; $rowById[[string]$r.id] = $r } }

# ---- state: seed on first run (nothing fires retroactively) ----
if (-not (Test-Path $stateFile)) {
  if (-not $DryRun) { [ordered]@{ seeded = (Get-Date -Format 'yyyy-MM-dd'); ids = @($boardIds.Keys | Sort-Object) } | ConvertTo-Json -Depth 3 | Set-Content $stateFile -Encoding UTF8 }
  Write-Output ("notify-item-added: SEEDED state with " + $boardIds.Count + " current board ids - notifications start with the NEXT new commodity")
  exit 0
}
$known = @{}; foreach ($k in (Read-JsonFile $stateFile).ids) { $known[[string]$k] = $true }
$newIds = @($boardIds.Keys | Where-Object { -not $known.ContainsKey($_) })

# ---- read the queue (Ghost drafts tagged #item-request-queue) ----
$jwt = New-GhostJWT
$hdr = @{ Authorization = "Ghost $jwt"; 'Accept-Version' = 'v5.0' }
$queue = @()
try {
  $qres = Invoke-RestMethod -Uri ($apiUrl + '/ghost/api/admin/posts/?filter=' + [uri]::EscapeDataString("tag:hash-item-request-queue+status:draft") + '&limit=all&fields=id,title,custom_excerpt,created_at') -Headers $hdr -TimeoutSec 30
  foreach ($q in @($qres.posts)) {
    try { $meta = $q.custom_excerpt | ConvertFrom-Json } catch { continue }
    if ($meta.email -and $meta.item) { $queue += ,([pscustomobject]@{ postId = $q.id; email = [string]$meta.email; store = [string]$meta.store; item = [string]$meta.item; date = [string]$meta.date }) }
  }
} catch { Write-Output ("notify-item-added: queue read failed (" + $_.Exception.Message + ") - will retry tomorrow"); exit 0 }

if (-not $newIds.Count -and -not $queue.Count) { Write-Output 'notify-item-added: no new commodities, empty queue - nothing to do'; exit 0 }

function Remove-QueueDraft([string]$postId) {
  $j2 = New-GhostJWT
  Invoke-RestMethod -Uri ($apiUrl + '/ghost/api/admin/posts/' + $postId + '/') -Method Delete -Headers @{ Authorization = "Ghost $j2"; 'Accept-Version' = 'v5.0' } -TimeoutSec 30 | Out-Null
}

# ---- expire stale requests (item never got added; don't hold addresses forever) ----
$expired = 0
foreach ($q in $queue) {
  $d = $null; try { $d = [datetime]$q.date } catch {}
  if ($d -and $d -lt (Get-Date).AddDays(-120)) {
    if ($DryRun) { Write-Output ("DRYRUN would expire: '" + $q.item + "' for " + $q.email + " (from " + $q.date + ")") }
    else { try { Remove-QueueDraft $q.postId; $expired++ } catch {} }
  }
}

# ---- the if-condition: new commodity x queued request -> match by the commodity's OWN rules ----
$commods = Read-JsonFile (Join-Path $root 'commodities.json')
$sent = 0; $failed = 0
foreach ($id in $newIds) {
  $cdef = $commods | Where-Object { [string]$_.id -eq $id } | Select-Object -First 1
  if (-not $cdef) { continue }   # recipe-only id etc.
  # cheapest line for the email, from the board row
  $cheapest = ''
  $row = $rowById[$id]
  if ($row) {
    $best = @($row.stores | Sort-Object per_unit) | Select-Object -First 1
    if ($best) { $cheapest = ('$' + ('{0:N2}' -f [double]$best.per_unit) + '/' + [string]$row.unit + ' at ' + [string]$best.store) }
  }
  foreach ($q in $queue) {
    $inc = $false; foreach ($p in @($cdef.include)) { if ($p -and $q.item -imatch $p) { $inc = $true; break } }
    if (-not $inc) { continue }
    $bad = $false; foreach ($x in @($cdef.exclude)) { if ($x -and $q.item -imatch $x) { $bad = $true; break } }
    if ($bad) { continue }
    if ($DryRun) { Write-Output ("DRYRUN would notify " + $q.email + ": '" + $q.item + "' -> " + $cdef.label + " (" + $cheapest + ")"); continue }
    try {
      $body = @{ email = $q.email; item = $q.item; commodity = [string]$cdef.label; cheapest = $cheapest } | ConvertTo-Json -Compress
      $resp = Invoke-RestMethod -Uri ($workerBase + '/notify') -Method Post -ContentType 'application/json' -Headers @{ 'X-Notify-Auth' = $notifyAuth } -Body $body -TimeoutSec 30
      if ($resp.ok) { Remove-QueueDraft $q.postId; $sent++; Write-Output ("NOTIFIED " + $q.email + ": '" + $q.item + "' is live as " + $cdef.label) }
      else { $failed++; Write-Output ("notify FAILED for " + $q.email + " (worker said no) - stays queued, retries tomorrow") }
    } catch { $failed++; Write-Output ("notify FAILED for " + $q.email + " (" + $_.Exception.Message + ") - stays queued, retries tomorrow") }
  }
}

# ---- advance state (only for real runs; failed sends stay queued but the id is now known -
# they were attempted; a failed WORKER send retries because the draft was not deleted and the
# id-diff isn't what drives retries for still-queued items... so on failure keep the id UNKNOWN) ----
if (-not $DryRun) {
  $advance = @($boardIds.Keys)
  if ($failed -gt 0) { $advance = @($advance | Where-Object { $known.ContainsKey($_) -or ($newIds -notcontains $_) }) }
  [ordered]@{ seeded = (Read-JsonFile $stateFile).seeded; updated = (Get-Date -Format 'yyyy-MM-dd HH:mm'); ids = @($advance | Sort-Object) } | ConvertTo-Json -Depth 3 | Set-Content $stateFile -Encoding UTF8
}
Write-Output ("notify-item-added: new-ids=" + $newIds.Count + " queue=" + $queue.Count + " sent=" + $sent + " failed=" + $failed + " expired=" + $expired + $(if ($DryRun) { ' (DRYRUN)' } else { '' }))
