<#
  send-price-alerts.ps1 - Emails "Get alerted on low prices" subscribers when a tracked item hits a
  record/tied-record low. Runs daily from check-ad-cycles downstream (after export-feed), locally AND
  in the cloud (GHOST_ADMIN_KEY env there).

  HOW IT WORKS
  - Subscribers = Ghost members carrying label alert-<id> (added by the Worker's POST /alert).
  - Trigger mirrors the board's badge logic: current cheapest at/below the lowest of all PRIOR ad
    cycles (>= 2 prior entries required), with the same >30%-below-runner-up outlier guard so an
    unverified parse never emails anyone.
  - Anti-spam: alert-state.json (grocery root; cloud-committed like price-history) remembers the last
    alerted price/date per item. Re-alert only on a strictly LOWER price, or after a 30-day cooldown
    if the item is still at its low. No subscribers for an item = no email AND no state update (so
    the first subscriber still gets told while the low is running).
  - Send = one email-only Ghost post per item to newsletter 'price-alerts', segment label:alert-<id>.

  Params: -DryRun (compute + print, send nothing)  -ForceItem <id> (ignore state/cooldown for one id, for testing)
#>
param([switch]$DryRun, [string]$ForceItem = "")
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$OutDir = Join-Path $root 'out'
$adminKey = if ($env:GHOST_ADMIN_KEY) { $env:GHOST_ADMIN_KEY }
  elseif (Test-Path (Join-Path $root '.ghostkey')) { (Get-Content (Join-Path $root '.ghostkey') -Raw).Trim() }
  elseif (Test-Path (Join-Path (Split-Path $root -Parent) 'meal-prep\.ghostkey')) { (Get-Content (Join-Path (Split-Path $root -Parent) 'meal-prep\.ghostkey') -Raw).Trim() }
  else { throw 'Ghost admin key missing' }
$apiUrl = 'https://map-to-success.ghost.io'
function New-GhostJWT {
  $id,$secret = $adminKey -split ':'
  $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  $b64 = { param($b) [Convert]::ToBase64String($b).TrimEnd('=').Replace('+','-').Replace('/','_') }
  $h='{"alg":"HS256","typ":"JWT","kid":"'+$id+'"}'; $pl='{"iat":'+$now+',"exp":'+($now+300)+',"aud":"/admin/"}'
  $si=(& $b64 ([Text.Encoding]::UTF8.GetBytes($h)))+'.'+(& $b64 ([Text.Encoding]::UTF8.GetBytes($pl)))
  $sb=New-Object byte[] ($secret.Length/2); for($i=0;$i -lt $sb.Length;$i++){$sb[$i]=[Convert]::ToByte($secret.Substring($i*2,2),16)}
  $hm=New-Object System.Security.Cryptography.HMACSHA256 (,$sb); return $si+'.'+(& $b64 ($hm.ComputeHash([Text.Encoding]::UTF8.GetBytes($si))))
}
# ordinal .Replace, NOT -replace: regex replacement treats backslashes literally in .NET, so
# -replace '\\','\\\\' inserts FOUR backslashes and corrupts double-encoded JSON (the 422 bug).
function JStr([string]$s){ return '"' + $s.Replace('\','\\').Replace('"','\"') + '"' }
function Fmt([double]$v){ if ($v -lt 1) { return ('$' + $v.ToString('0.000')) } else { return ('$' + $v.ToString('0.00')) } }

# ---- boards + history + state ----
$cmpF = (Get-ChildItem (Join-Path $OutDir 'comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1)
$CompareFile = $cmpF.FullName
try { $wk0 = (Get-Content $cmpF.FullName -Raw | ConvertFrom-Json).week_of; $verF = Join-Path $OutDir ("verified-" + $wk0 + ".json"); if ((Test-Path $verF) -and ((Get-Item $verF).LastWriteTime -ge $cmpF.LastWriteTime)) { $CompareFile = $verF } } catch {}
$doc = Get-Content $CompareFile -Raw | ConvertFrom-Json
$week = [string]$doc.week_of
$rows = @($doc.comparison)
$riF = Join-Path $OutDir 'recipe-board.json'
if (Test-Path $riF) { $rows = $rows + @((Get-Content $riF -Raw | ConvertFrom-Json).comparison) }

$histFile = Join-Path $root 'price-history.json'
if (-not (Test-Path $histFile)) { Write-Output 'no price-history.json - nothing to alert on'; exit 0 }
$histById = @{}
foreach ($h in ((Get-Content $histFile -Raw | ConvertFrom-Json).commodities)) { $histById[[string]$h.id] = $h }

$stateFile = Join-Path $root 'alert-state.json'
$state = @{}
if (Test-Path $stateFile) { try { foreach ($p in ((Get-Content $stateFile -Raw | ConvertFrom-Json).PSObject.Properties)) { $state[[string]$p.Name] = $p.Value } } catch {} }

# feed (for sale_end lines in the email)
$saleEnd = @{}
try { $feed = (Get-Content (Join-Path $OutDir 'smp-feed.json') -Raw).TrimStart([char]0xFEFF) | ConvertFrom-Json
      foreach ($p in $feed.ingredients.PSObject.Properties) { if ($p.Value.sale_end) { $saleEnd[[string]$p.Name] = [string]$p.Value.sale_end } } } catch {}

$today = (Get-Date).ToString('yyyy-MM-dd')
$seen = @{}
$candidates = @()
foreach ($r in $rows) {
  $id = [string]$r.id
  if ($seen.ContainsKey($id)) { continue }
  $seen[$id] = $true
  $h = $histById[$id]; if (-not $h) { continue }
  $ranked = @($r.stores | Where-Object { [double]$_.per_unit -gt 0 } | Sort-Object per_unit)
  if ($ranked.Count -eq 0) { continue }
  $P = [double]$ranked[0].per_unit
  $store = [string]$ranked[0].store
  # outlier guard (mirror sanity-check threshold)
  if ($ranked.Count -ge 2) { $ru = [double]$ranked[1].per_unit; if ($ru -gt 0 -and (($ru - $P) / $ru) -gt 0.30) { continue } }
  $prior = @($h.history | Where-Object { try { [datetime]$_.week_of -lt [datetime]$week } catch { $false } })
  if (@($prior).Count -lt 2) { continue }
  $priorMin = $null; foreach ($e in $prior) { $ep = [double]$e.cheapest_price; if ($priorMin -eq $null -or $ep -lt $priorMin) { $priorMin = $ep } }
  $isLow = ($P -le ($priorMin + 0.0001))
  $force = ($ForceItem -ne '' -and $id -eq $ForceItem)
  if (-not $isLow -and -not $force) { continue }
  # anti-spam state
  $st = $state[$id]
  $should = $false
  if ($force) { $should = $true }
  elseif ($null -eq $st) { $should = $true }
  elseif ($P -lt ([double]$st.price - 0.005)) { $should = $true }
  elseif ($P -le ([double]$st.price + 0.005)) {
    try { if (((Get-Date) - [datetime]$st.date).TotalDays -ge 30) { $should = $true } } catch { $should = $true }
  }
  if (-not $should) { continue }
  $label = if ($h.label) { [string]$h.label } else { [string]$r.commodity }
  $candidates += ,@{ id=$id; label=$label; unit=[string]$r.unit; price=$P; store=$store; se=$(if ($saleEnd.ContainsKey($id)) { $saleEnd[$id] } else { $null }) }
}

if ($candidates.Count -eq 0) { Write-Output 'price-alerts: nothing new at a low today'; exit 0 }
Write-Output ("price-alerts: " + $candidates.Count + " candidate(s): " + (($candidates | ForEach-Object { $_.id }) -join ', '))

$sent = 0
foreach ($c in $candidates) {
  $labelName = 'alert-' + $c.id
  # any subscribers?
  $jwt = New-GhostJWT
  $filter = [uri]::EscapeDataString("label:" + $labelName)
  try { $mr = Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/members/?filter=$filter&limit=1" -Headers @{Authorization="Ghost $jwt";'Accept-Version'='v5.0'} -TimeoutSec 30 }
  catch { Write-Output ("  " + $c.id + ": member lookup failed - skipped"); continue }
  $total = [int]$mr.meta.pagination.total
  if ($total -eq 0) { Write-Output ("  " + $c.id + ": at a low but 0 subscribers - skipped (no state update)"); continue }

  $priceTxt = (Fmt $c.price) + '/' + $c.unit
  $title = 'Price alert: ' + $c.label + ' just hit ' + $priceTxt + ' at ' + $c.store
  $seLine = ''
  if ($c.se) { try { $seLine = '<p style="color:#b23b2e;font-weight:600">It is a sale price, and it runs through ' + ([datetime]$c.se).ToString('dddd, MMM d') + '. After that it goes back up.</p>' } catch {} }
  $bodyHtml = '<p>You asked us to watch <b>' + $c.label + '</b> for you. Good news.</p>' +
    '<p style="font-size:1.3em"><b>' + $priceTxt + ' at ' + $c.store + '</b> - the lowest price we have tracked for it in Omaha.</p>' +
    $seLine +
    '<p><a href="https://www.thriftycrew.com/omaha-grocery-prices/?ref=price-alert">See every store&#39;s price on the live board &rarr;</a></p>' +
    '<p style="color:#8a94a6;font-size:.9em">You get this because you signed up for price alerts on this item at thriftycrew.com. Unsubscribing below stops all price-alert emails.</p>'
  if ($DryRun) { Write-Output ("  DRYRUN would email " + $total + "+ subscriber(s): " + $title); continue }

  # Ghost only queues the newsletter email on the draft->published TRANSITION via PUT; creating a
  # post directly as published silently ignores ?newsletter= (post says "sent", no email exists).
  # So: 1) create DRAFT, 2) PUT status published WITH the newsletter + segment params, 3) verify the
  # email object actually exists before claiming success.
  $lex = '{"root":{"children":[{"type":"html","version":1,"html":' + (JStr $bodyHtml) + '}],"direction":null,"format":"","indent":0,"type":"root","version":1}}'
  $draftJson = '{"posts":[{"title":' + (JStr $title) + ',"lexical":' + (JStr $lex) + ',"status":"draft","email_only":true,"tags":[{"name":"#price-alerts"}]}]}'
  try {
    $jwt2 = New-GhostJWT
    $draft = (Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/posts/" -Method Post -Headers @{Authorization="Ghost $jwt2";'Accept-Version'='v5.0'} -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($draftJson)) -TimeoutSec 30).posts[0]
    $pubJson = '{"posts":[{"status":"published","updated_at":' + (JStr ([string]$draft.updated_at)) + '}]}'
    $pubUri = "$apiUrl/ghost/api/admin/posts/" + $draft.id + "/?newsletter=price-alerts&email_segment=" + [uri]::EscapeDataString("label:" + $labelName)
    $jwt3 = New-GhostJWT
    $pub = (Invoke-RestMethod -Uri $pubUri -Method Put -Headers @{Authorization="Ghost $jwt3";'Accept-Version'='v5.0'} -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($pubJson)) -TimeoutSec 30).posts[0]
    # verify the email actually queued
    $jwt4 = New-GhostJWT
    $chk = (Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/posts/$($draft.id)/?include=email" -Headers @{Authorization="Ghost $jwt4";'Accept-Version'='v5.0'} -TimeoutSec 30).posts[0]
    if ($chk.email -and $chk.email.status -ne 'failed') {
      Write-Output ("  SENT " + $c.id + " -> " + $chk.email.email_count + " recipient(s), email status " + $chk.email.status + ": " + $title)
      $state[$c.id] = @{ price = $c.price; date = $today; store = $c.store }
      $sent++
    } else {
      Write-Output ("  " + $c.id + ": post published but EMAIL DID NOT QUEUE (status=" + $(if ($chk.email) { $chk.email.status } else { 'none' }) + ") - deleting the dead post, will retry next run")
      try { $jwt5 = New-GhostJWT; Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/posts/$($draft.id)/" -Method Delete -Headers @{Authorization="Ghost $jwt5";'Accept-Version'='v5.0'} -TimeoutSec 30 | Out-Null } catch {}
    }
  } catch {
    $errBody = ''
    try { $resp = $_.Exception.Response; if ($resp) { $sr = New-Object IO.StreamReader($resp.GetResponseStream()); $full = $sr.ReadToEnd(); $errBody = $full.Substring(0, [Math]::Min(400, $full.Length)) } } catch {}
    Write-Output ("  " + $c.id + ": SEND FAILED - " + $_.Exception.Message + " | " + $errBody)
  }
}

if (-not $DryRun) {
  $parts = @()
  foreach ($k in ($state.Keys | Sort-Object)) { $v = $state[$k]; $parts += ((JStr $k) + ':{"price":' + [double]$v.price + ',"date":' + (JStr ([string]$v.date)) + ',"store":' + (JStr ([string]$v.store)) + '}') }
  [IO.File]::WriteAllText($stateFile, ('{' + ($parts -join ',') + '}'), (New-Object System.Text.UTF8Encoding($false)))
}
Write-Output ("price-alerts done: " + $sent + " email(s) sent")
