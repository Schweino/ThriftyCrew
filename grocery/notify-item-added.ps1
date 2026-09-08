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

  THE SEND LOG, AND THE HOLE IT CLOSES (2026-09-08, backlog I89). Step 3 and step 4 are in two
  different systems, so there is a window between them: the Worker returns ok, Remove-QueueDraft
  throws, the draft survives, and TOMORROW'S RUN MATCHES THE SAME REQUEST AGAINST THE SAME BOARD ID
  AND EMAILS THE SAME PERSON AGAIN. Nothing bounded that. There was no attempt counter, no terminal
  state, and the `catch` around the send did not cover the delete, so a delete that can NEVER
  succeed - a draft deleted in the Ghost UI by hand, a permissions change, an id that 404s - meant a
  member of the public who asked once for one thing got that email every morning, forever. Nothing
  would have noticed: audit-alert-precision measures whether an alert was RIGHT, and nothing in the
  estate measures whether one was sent TWICE.

  The draft was the only durable record of "already told", and it is the record that fails. So the
  send is now recorded LOCALLY, before the delete is attempted, in notify-sent-log.json - which is
  git-tracked, so git is its undo log (backlog E1's finding) and no second one is needed.

  THE LOG HOLDS NO EMAIL ADDRESS. It keys on the Ghost post id plus the commodity id, and carries a
  SHA-256 of the address purely so a human can confirm a match without the address being in the
  repo. Requester addresses have never been committed here and this change does not start.

  Three consequences, in the order they fire:
    * a (postId, commodity) pair already marked sent is SUPPRESSED - it is not re-sent, whatever the
      draft's state. That is the unbounded loop, closed.
    * a failed delete after a successful send prints DELETE-FAILED and increments delete_attempts,
      so the condition is visible rather than silent.
    * after DELETE_GIVE_UP attempts the pair goes terminal and stops being retried at all.

  Rows older than 180 days are pruned; the drafts themselves expire at 120, so nothing that can
  still fire is ever forgotten.

  Self-test: powershell -File grocery\notify-item-added.ps1 -SelfTest   (pure, sends nothing)
#>
param([switch]$DryRun, [string]$OutDir = "", [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
$stateFile = Join-Path $root 'notify-known-ids.json'
$sentFile  = Join-Path $root 'notify-sent-log.json'
$workerBase = 'https://feed.thriftycrew.com'

# How many times a delete may fail after a SUCCESSFUL send before the pair is declared terminal and
# stops being touched. The send is already suppressed by the log from attempt 1 - this only bounds
# how long we keep poking Ghost about a draft that will not go.
$DELETE_GIVE_UP = 5
$SENT_LOG_KEEP_DAYS = 180   # > the 120-day draft expiry, so nothing that can still fire is forgotten

function Get-NotifyKey {
  <# The identity of "this person has been told about this commodity". The Ghost post id is the
     request; the commodity id is the thing it matched. Pure. #>
  param([string]$PostId, [string]$CommodityId)
  return ($PostId + '|' + $CommodityId)
}

function Get-EmailFingerprint {
  <# A SHA-256 of the address, so a human can confirm a match without the address being in the repo.
     Requester emails have never been committed here. #>
  param([string]$Email)
  $s = [Security.Cryptography.SHA256]::Create()
  return (-join ($s.ComputeHash([Text.Encoding]::UTF8.GetBytes(($Email.Trim().ToLowerInvariant()))) | ForEach-Object { $_.ToString('x2') })).Substring(0, 16)
}

function Test-NotifyAlreadySent {
  <# THE WHOLE POINT OF I89. Has this exact (request, commodity) pair already been emailed?

     Returns @{ Sent; Terminal; Attempts }. Sent TRUE means do not send again, whatever the draft
     says - the draft is in another system and it is the thing that failed. Pure, so the fixtures
     drive it with synthetic rows rather than with today's log. #>
  param([object[]]$Log, [string]$PostId, [string]$CommodityId)
  $key = Get-NotifyKey -PostId $PostId -CommodityId $CommodityId
  # WRAP THE PIPELINE, do not assign then wrap: with no match `$x = ...|Where-Object` is $null and
  # `@($null).Count` is 1, so a row that was never sent would read as one row already sent - the
  # exact inversion of this function's job. [[ps-null-count-is-one]]
  $hit = @($Log | Where-Object { $_ -and ([string]$_.key -eq $key) })
  if ($hit.Count -eq 0) { return @{ Sent = $false; Terminal = $false; Attempts = 0 } }
  $r = $hit[0]
  $att = 0; if ($r.PSObject.Properties['delete_attempts']) { $att = [int]$r.delete_attempts }
  return @{ Sent = [bool]$r.sent; Terminal = ($att -ge $DELETE_GIVE_UP); Attempts = $att }
}

function Remove-StaleNotifyRows {
  <# Prune rows older than the keep window. `,@()` so one surviving row does not unroll to a bare
     object and get written as a JSON object where the reader expects an array. #>
  param([object[]]$Log, [datetime]$Now, [int]$KeepDays)
  $keep = @()
  foreach ($r in @($Log)) {
    if (-not $r) { continue }
    $d = $null; try { $d = [datetime]$r.sent_at } catch { }
    if ($null -eq $d -or $d -ge $Now.AddDays(-$KeepDays)) { $keep += $r }
  }
  return ,@($keep)
}

# ------------------------------------------------------------------------------------- self-test
if ($SelfTest) {
  $f = 0
  function T($m, $cond, $got) { if ($cond) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $got); $script:f++ } }

  # EVERY FIXTURE IS A SINGLE-QUOTED LITERAL where it is a string. Built by concatenation in the
  # argument position they would be three positional arguments, not one (2026-09-07).
  $log = @(
    [pscustomobject]@{ key = 'post-a|milk'; sent = $true;  sent_at = '2026-09-01'; delete_ok = $true;  delete_attempts = 0 },
    [pscustomobject]@{ key = 'post-b|eggs'; sent = $true;  sent_at = '2026-09-01'; delete_ok = $false; delete_attempts = 2 },
    [pscustomobject]@{ key = 'post-c|rice'; sent = $true;  sent_at = '2026-09-01'; delete_ok = $false; delete_attempts = 5 }
  )

  $r1 = Test-NotifyAlreadySent -Log $log -PostId 'post-b' -CommodityId 'eggs'
  T 'MUST FIRE  THE FOUNDING BUG - a send whose DRAFT DELETE FAILED is still recorded as sent, so tomorrow suppresses it instead of emailing a real person again' `
    ($r1.Sent -and -not $r1.Terminal) ("sent=" + $r1.Sent + " terminal=" + $r1.Terminal)

  $r2 = Test-NotifyAlreadySent -Log $log -PostId 'post-c' -CommodityId 'rice'
  T 'MUST FIRE  a pair whose delete has failed DELETE_GIVE_UP times is terminal, so we stop poking Ghost about a draft that will not go' `
    ($r2.Sent -and $r2.Terminal -and $r2.Attempts -eq 5) ("terminal=" + $r2.Terminal + " attempts=" + $r2.Attempts)

  $r3 = Test-NotifyAlreadySent -Log $log -PostId 'post-z' -CommodityId 'flour'
  T 'MUST NOT FIRE  THE ONE THAT MATTERS MOST - a pair that has never been sent is NOT suppressed, or the fix silences the feature it is protecting' `
    (-not $r3.Sent -and $r3.Attempts -eq 0) ("sent=" + $r3.Sent)

  $r4 = Test-NotifyAlreadySent -Log @() -PostId 'post-a' -CommodityId 'milk'
  T 'MUST NOT FIRE  an EMPTY log suppresses nothing - @($null).Count is 1 in PS 5.1 and would have made every first send read as a repeat' `
    (-not $r4.Sent) ("sent=" + $r4.Sent)

  $r5 = Test-NotifyAlreadySent -Log $log -PostId 'post-a' -CommodityId 'eggs'
  T 'MUST NOT FIRE  the key is the PAIR - the same request matching a DIFFERENT commodity is a different notification and must still go' `
    (-not $r5.Sent) ("sent=" + $r5.Sent)

  $r6 = Test-NotifyAlreadySent -Log $log -PostId 'post-b' -CommodityId 'egg'
  T 'MUST NOT FIRE  the commodity id is matched WHOLE - a prefix of another id is not the same cell' `
    (-not $r6.Sent) ("sent=" + $r6.Sent)

  # CLEAN TWIN - the behaviours the fix was most likely to have broken on its way past.
  $pruned = Remove-StaleNotifyRows -Log $log -Now ([datetime]'2026-09-08') -KeepDays 180
  T 'CLEAN TWIN pruning keeps rows inside the window, and keeps them as an ARRAY rather than unrolling one row to a bare object' `
    (($pruned -is [array]) -and ($pruned.Count -eq 3)) ("count=" + @($pruned).Count)
  $old = @([pscustomobject]@{ key = 'post-x|salt'; sent = $true; sent_at = '2025-01-01' })
  $pruned2 = Remove-StaleNotifyRows -Log $old -Now ([datetime]'2026-09-08') -KeepDays 180
  T 'CLEAN TWIN a row past the keep window is dropped, and the window is WIDER than the 120-day draft expiry so nothing that can still fire is forgotten' `
    (@($pruned2).Count -eq 0 -and $SENT_LOG_KEEP_DAYS -gt 120) ("count=" + @($pruned2).Count + " keep=" + $SENT_LOG_KEEP_DAYS)
  $noDate = @([pscustomobject]@{ key = 'post-y|oats'; sent = $true })
  T 'CLEAN TWIN a row with no readable date is KEPT, not pruned - an unparseable stamp must not silently re-arm an email' `
    (@(Remove-StaleNotifyRows -Log $noDate -Now (Get-Date) -KeepDays 180).Count -eq 1) 'a dateless row was pruned'
  T 'CLEAN TWIN the fingerprint is stable, case-folded, and is not the address' `
    ((Get-EmailFingerprint 'A@B.com') -eq (Get-EmailFingerprint 'a@b.com ') -and (Get-EmailFingerprint 'a@b.com').Length -eq 16) `
    (Get-EmailFingerprint 'a@b.com')

  if ($f) { Write-Output ("SELF-TEST FAIL: {0} check(s)" -f $f); exit 1 }
  Write-Output 'SELF-TEST PASS: 2 must-fire cases led by the founding bug (a successful send whose draft delete failed must still suppress tomorrow), 4 must-not-fire cases including the empty log and the pair-key boundary, and 4 clean twins over pruning and the address fingerprint'
  exit 0
}

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
$sent = 0; $failed = 0; $suppressed = 0; $deleteFailed = 0

# THE SEND LOG (I89). Read before the loop, written after it, one row per (request, commodity).
$rawRows = @()
if (Test-Path $sentFile) { $rawRows = @((Read-JsonFile $sentFile).rows) }
$sentLog = Remove-StaleNotifyRows -Log $rawRows -Now (Get-Date) -KeepDays $SENT_LOG_KEEP_DAYS
$logDirty = ($sentLog.Count -ne $rawRows.Count)   # a prune alone is a reason to rewrite the file
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
    # I89: THE SUPPRESSION CHECK COMES BEFORE THE SEND, and it trusts the local log rather than the
    # draft. The draft is in Ghost, the delete is what fails, and a surviving draft is exactly the
    # state that used to re-send to a real person every morning with no upper bound.
    $prior = Test-NotifyAlreadySent -Log $sentLog -PostId $q.postId -CommodityId $id
    if ($prior.Sent) {
      $suppressed++
      Write-Output ("SUPPRESSED duplicate: request " + $q.postId + " was already notified about " + $cdef.label +
                    " (delete_attempts=" + $prior.Attempts + $(if ($prior.Terminal) { ', TERMINAL - not retried' } else { '' }) + ")")
      # The draft is still here, which is WHY this fired. Keep trying to tidy it, but bounded: after
      # DELETE_GIVE_UP the row goes terminal and we stop asking Ghost about a draft that will not go.
      if (-not $DryRun -and -not $prior.Terminal) {
        $k = Get-NotifyKey -PostId $q.postId -CommodityId $id
        $row = @($sentLog | Where-Object { $_ -and ([string]$_.key -eq $k) })[0]
        if ($row -and -not $row.delete_ok) {
          try { Remove-QueueDraft $q.postId; $row.delete_ok = $true; $logDirty = $true; Write-Output ("  draft " + $q.postId + " finally deleted on retry") }
          catch {
            $row.delete_attempts = [int]$row.delete_attempts + 1; $logDirty = $true; $deleteFailed++
            $note = if ([int]$row.delete_attempts -ge $DELETE_GIVE_UP) { ' - GIVING UP, this pair is now terminal' } else { '' }
            Write-Output ("  DELETE-FAILED again for " + $q.postId + " (attempt " + $row.delete_attempts + " of " + $DELETE_GIVE_UP + ")" + $note)
          }
        }
      }
      continue
    }
    if ($DryRun) { Write-Output ("DRYRUN would notify " + $q.email + ": '" + $q.item + "' -> " + $cdef.label + " (" + $cheapest + ")"); continue }
    try {
      $body = @{ email = $q.email; item = $q.item; commodity = [string]$cdef.label; cheapest = $cheapest } | ConvertTo-Json -Compress
      $resp = Invoke-RestMethod -Uri ($workerBase + '/notify') -Method Post -ContentType 'application/json' -Headers @{ 'X-Notify-Auth' = $notifyAuth } -Body $body -TimeoutSec 30
      if ($resp.ok) {
        # RECORD THE SEND FIRST. The email has left; from here on the only question is tidying the
        # draft, and no outcome of that may ever make this person eligible to be emailed again.
        $row = [pscustomobject]@{ key = (Get-NotifyKey -PostId $q.postId -CommodityId $id)
                                  postId = $q.postId; commodity = $id; email_sha256 = (Get-EmailFingerprint $q.email)
                                  sent = $true; sent_at = (Get-Date -Format 'yyyy-MM-dd HH:mm')
                                  delete_ok = $false; delete_attempts = 0 }
        $sentLog = @($sentLog) + @($row); $logDirty = $true
        $sent++
        Write-Output ("NOTIFIED " + $q.email + ": '" + $q.item + "' is live as " + $cdef.label)
        # THE DELETE IS NOW BEST-EFFORT AND ITS FAILURE IS LOUD. It used to be neither: it sat
        # outside the catch, so a throw here aborted the run and left no record that the send had
        # succeeded.
        try { Remove-QueueDraft $q.postId; $row.delete_ok = $true }
        catch {
          $row.delete_attempts = 1; $deleteFailed++
          Write-Output ("DELETE-FAILED for request " + $q.postId + " after a SUCCESSFUL send (" + $_.Exception.Message +
                        ") - the draft survives, so it will match again tomorrow; the send log is what stops the duplicate.")
        }
      }
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

# THE SEND LOG IS WRITTEN WHETHER OR NOT THE RUN OTHERWISE SUCCEEDED (I89). It is the only record
# that an email left the building, and it is tracked, so git is its undo log.
if (-not $DryRun -and $logDirty) {
  [ordered]@{
    readme = 'One row per (Ghost request draft, commodity) that has been emailed. Written BEFORE the draft delete is attempted, because the delete is the step that fails and a surviving draft used to mean the same person got the same email every morning forever (backlog I89). NO EMAIL ADDRESS IS STORED - email_sha256 is a 16-hex-char fingerprint so a match can be confirmed without the address being in this repo. delete_attempts reaching 5 makes a pair terminal. Rows older than 180 days are pruned; the drafts themselves expire at 120.'
    updated = (Get-Date -Format 'yyyy-MM-dd HH:mm')
    rows = @($sentLog)
  } | ConvertTo-Json -Depth 4 | Set-Content $sentFile -Encoding UTF8
}
Write-Output ("notify-item-added: new-ids=" + $newIds.Count + " queue=" + $queue.Count + " sent=" + $sent +
              " suppressed=" + $suppressed + " delete-failed=" + $deleteFailed + " failed=" + $failed +
              " expired=" + $expired + " sent-log-rows=" + @($sentLog).Count + $(if ($DryRun) { ' (DRYRUN)' } else { '' }))
