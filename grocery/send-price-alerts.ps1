<#
  send-price-alerts.ps1 - Emails "Get alerted on low prices" subscribers when a tracked item hits a
  record/tied-record low. Runs daily from check-ad-cycles downstream (after export-feed), in the MAIN
  checkout only (no cloud workflow calls it; checked 2026-09-18 by grepping .github).

  HOW IT WORKS
  - Subscribers = Ghost members carrying label alert-<id> (added by the Worker's POST /alert).
  - Trigger mirrors the board's badge logic: current cheapest at/below the lowest of all PRIOR ad
    cycles (>= 2 prior entries required), with the same >30%-below-runner-up outlier guard so an
    unverified parse never emails anyone.
  - Anti-spam: alert-state.json (grocery root) remembers the last alerted price/date per item. Re-alert
    only on a strictly LOWER price, or after a 30-day cooldown if the item is still at its low. No
    subscribers for an item = no email AND no state update (so the first subscriber still gets told
    while the low is running).
  - Send = one email-only Ghost post per item to newsletter 'price-alerts', segment label:alert-<id>.
    Ghost mails on the draft->published TRANSITION (a PUT), so the POST makes a draft that mails nobody
    and the PUT is the send.

  THE STATE FILE IS READ OR THE RUN STOPS (2026-09-18, backlog I161 option A, I224). An alert-state.json that
  exists and cannot be read (bad JSON, empty, not an object) used to read as EMPTY: every item at a low
  re-alerted every subscriber, and the end-of-run write then replaced the file with only today's sends. Now
  the run REFUSES: it sends nothing, writes nothing, says why on its last line, pages Brad, and exits 1. A
  MISSING file is still a fresh start. And a missing, non-numeric or zero price in a row reads as UNKNOWN,
  never 0: that item alerts once and the real price is recorded. Read as 0 it could never be "lower" nor
  "the same", so the item was muted for ever and nothing said so.

  A FAILED PUBLISH NEVER LEAVES A DRAFT BEHIND, AND AN UNKNOWN ONE IS NEVER REPLAYED (2026-09-18, backlog I224).
  Until then a failed PUT printed SEND FAILED and left the draft the POST had just made, so every retry left
  another draft in Ghost. What happens now turns on WHAT the failure proves, the rule lib\ghost-lib.ps1 set for
  POST under backlog I198:
    - Ghost REFUSED the PUT (a 4xx other than 408/429) or it provably never reached Ghost: nothing was
      published, so the draft is DELETED (idempotent; a 404 means already gone). If that delete fails too,
      the failure message and a page to Brad name the orphan draft's id.
    - The PUT's outcome is UNKNOWN (a timeout, a 5xx, a reset), or it succeeded and the email check could not
      be read: Ghost may be mailing the list right now. The post is NOT deleted (it is the evidence, and a
      delete does not recall an email). The item stays marked as INVOKING (below), Brad is paged with the
      post id, and no later run alerts that item until he says what happened.
  The PUT is attempted exactly ONCE (-MaxRetries 0): a replayed PUT after a lost success carries a stale
  updated_at, Ghost answers 409, and a 409 would then read as "refused" and delete a post that is mailing.

  THE INVOKING MARKER (the send-friday-email pattern, backlog I198). grocery\out\price-alerts.invoking.json
  names each item whose publish PUT is about to go out, with its draft id, written atomically and flushed
  BEFORE the PUT; alert-state.json is the "sent" record, written the moment a send is verified. An item that
  is invoking and not sent is HELD: skipped, and Brad is paged. Before this, a PUT that landed while its reply
  was lost, or a verify GET that failed after a good PUT, recorded nothing, so the next day's run mailed the
  same subscribers again. To release a held item after checking Ghost's email log (Posts, filter by the
  #price-alerts tag, open the post named in the page):
      powershell -File send-price-alerts.ps1 -ResolveInvoking <id> -Mailed   # it went out: record it as sent
      powershell -File send-price-alerts.ps1 -ResolveInvoking <id>           # it did not: the next run may alert
  The marker is gitignored (grocery/out is on the bot's staging list; a tracked copy can be rewound, which
  would re-arm a double send), so it lives in the main checkout only, and a live run or a resolve from a
  LINKED worktree is refused: that worktree cannot see the main checkout's marker or state.

  Params: -DryRun (compute + print, send nothing, write nothing)  -ForceItem <id> (ignore state/cooldown for one
  id, for testing)  -ResolveInvoking <id> [-Mailed]  -SelfTest (stubbed Ghost transport; mails nobody)
#>
param([switch]$DryRun, [string]$ForceItem = "", [switch]$SelfTest, [string]$ResolveInvoking = '', [switch]$Mailed)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$OutDir = Join-Path $root 'out'
. (Join-Path $PSScriptRoot '..\lib\ghost-lib.ps1')        # 2026-07-26: single Ghost helper (was one of 50+ inline copies)
. (Join-Path $PSScriptRoot '..\lib\atomic-write.ps1')     # Write-TcAtomicFile: the state and the marker are never half-written
. (Join-Path $PSScriptRoot '..\lib\gate-leftovers.ps1')   # Get-TcCheckoutKind: a live run happens in the main checkout only

# ordinal .Replace, NOT -replace: regex replacement treats backslashes literally in .NET, so
# -replace '\\','\\\\' inserts FOUR backslashes and corrupts double-encoded JSON (the 422 bug).
function JStr([string]$s){ return '"' + $s.Replace('\','\\').Replace('"','\"') + '"' }
function Fmt([double]$v){ if ($v -lt 1) { return ('$' + $v.ToString('0.000')) } else { return ('$' + $v.ToString('0.00')) } }

# ------------------------------------------------------------------------------------- state
function ConvertTo-AlertPrice {
  <# A stored price, or $null for UNKNOWN: missing, not a number, NaN, infinite, or at or below zero (I161). #>
  param($Value)
  if ($null -eq $Value) { return $null }
  $d = 0.0
  if ($Value -is [string]) {
    if (-not [double]::TryParse($Value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return $null }
  } elseif ($Value -is [ValueType]) {
    try { $d = [double]$Value } catch { return $null }
  } else { return $null }
  if ([double]::IsNaN($d) -or [double]::IsInfinity($d) -or $d -le 0) { return $null }
  return $d
}

function Read-AlertStateFile {
  <# { ok; state; why }. A MISSING file is a fresh start (ok, empty). A file that EXISTS and cannot be read as a
     JSON object is not a fresh start: ok=$false, and the caller must refuse the run (I161 option A). #>
  param([string]$Path, [string]$Name = 'alert-state.json')
  $state = @{}
  if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]@{ ok = $true; state = $state; why = '' } }
  try { $doc = Read-JsonFile $Path }
  catch { return [pscustomobject]@{ ok = $false; state = $null; why = ($Name + ' exists but is not valid JSON: ' + $_.Exception.Message) } }
  if (-not ($doc -is [System.Management.Automation.PSCustomObject])) {
    $shape = if ($null -eq $doc) { 'empty' } else { $doc.GetType().Name }
    return [pscustomobject]@{ ok = $false; state = $null; why = ($Name + ' exists but is not a JSON object (read as ' + $shape + ')') }
  }
  foreach ($p in $doc.PSObject.Properties) { $state[[string]$p.Name] = $p.Value }
  return [pscustomobject]@{ ok = $true; state = $state; why = '' }
}

function ConvertTo-AlertStateJson {
  <# The bytes this file always had: one line, keys sorted, price/date/store. An UNKNOWN price is written null,
     never laundered into 0 (I161). #>
  param([hashtable]$State)
  $parts = @()
  foreach ($k in ($State.Keys | Sort-Object)) {
    $v = $State[$k]
    $pv = ConvertTo-AlertPrice $v.price
    $pTxt = if ($null -eq $pv) { 'null' } else { [string]([double]$pv) }
    $parts += ((JStr $k) + ':{"price":' + $pTxt + ',"date":' + (JStr ([string]$v.date)) + ',"store":' + (JStr ([string]$v.store)) + '}')
  }
  return ('{' + ($parts -join ',') + '}')
}

function Write-AlertStateFile([string]$Path, [hashtable]$State) {
  [void](Write-TcAtomicFile -Path $Path -Text (ConvertTo-AlertStateJson $State) -NoBom -NoNewline -Flush)
}

function Write-AlertInvokingFile([string]$Path, [hashtable]$Map) {
  <# One entry per item whose publish is in flight or unresolved. An empty map removes the file. #>
  if ($Map.Count -eq 0) { if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }; return }
  $o = [ordered]@{}
  foreach ($k in ($Map.Keys | Sort-Object)) { $o[$k] = $Map[$k] }
  [void](Write-TcAtomicFile -Path $Path -Text (ConvertTo-Json $o -Depth 5 -Compress) -NoBom -NoNewline -Flush)
}

function Test-AlertDue {
  <# The anti-spam decision for one item at a low. $St is its alert-state row or $null. #>
  param([double]$Price, $St, [bool]$IsForce, [datetime]$Now)
  if ($IsForce) { return $true }
  if ($null -eq $St) { return $true }
  $sp = $null
  if ($St -is [System.Management.Automation.PSCustomObject] -or $St -is [hashtable]) { $sp = ConvertTo-AlertPrice $St.price }
  if ($null -eq $sp) { return $true }            # UNKNOWN price: alert once, and the real price is recorded (I161)
  if ($Price -lt ($sp - 0.005)) { return $true }
  if ($Price -le ($sp + 0.005)) {
    try { if (($Now - [datetime]$St.date).TotalDays -ge 30) { return $true } } catch { return $true }
  }
  return $false
}

# ------------------------------------------------------------------------------------- Ghost
function Get-GhostFailureKind {
  <# What a failed Ghost call PROVES. rejected = Ghost answered with a refusal (a 4xx other than 408/429), so it
     acted on nothing; never-sent = the request never reached Ghost (lib\ghost-lib.ps1's Test-TcGhostNeverSent);
     ambiguous = anything else (timeout, 5xx, 429, reset, no status): Ghost may have acted. #>
  param($ErrorRecord)
  $ex = $ErrorRecord.Exception
  if (Test-TcGhostNeverSent $ex) { return 'never-sent' }
  $code = 0
  $resp = $ex.Response
  if ($resp -and ($resp.PSObject.Properties['StatusCode'])) { try { $code = [int]$resp.StatusCode } catch { $code = 0 } }
  if ($code -ge 400 -and $code -le 499 -and $code -ne 408 -and $code -ne 429) { return 'rejected' }
  return 'ambiguous'
}

function Get-GhostErrorText($ErrorRecord) {
  $t = [string]$ErrorRecord.Exception.Message
  try {
    $resp = $ErrorRecord.Exception.Response
    if ($resp -and $resp.PSObject.Methods['GetResponseStream']) {
      $sr = New-Object IO.StreamReader($resp.GetResponseStream()); $full = $sr.ReadToEnd()
      $t += ' | ' + $full.Substring(0, [Math]::Min(400, $full.Length))
    }
  } catch {}
  return $t
}

function Remove-AlertPost {
  <# DELETE one post. Idempotent: a 404 means it is already gone and counts as deleted. { ok; why } #>
  param([string]$ApiUrl, [string]$PostId, [scriptblock]$Headers)
  try {
    $null = Invoke-GhostApi -Method DELETE -Uri ($ApiUrl + '/ghost/api/admin/posts/' + $PostId + '/') -Headers (& $Headers) -TimeoutSec 30
    return [pscustomobject]@{ ok = $true; why = '' }
  } catch {
    $code = 0; $resp = $_.Exception.Response
    if ($resp -and ($resp.PSObject.Properties['StatusCode'])) { try { $code = [int]$resp.StatusCode } catch { $code = 0 } }
    if ($code -eq 404) { return [pscustomobject]@{ ok = $true; why = 'already gone (404)' } }
    return [pscustomobject]@{ ok = $false; why = (Get-GhostErrorText $_) }
  }
}

function Invoke-PriceAlertPublish {
  <# Draft, publish, verify, and clean up after a publish that did not happen. -OnDraft runs with the draft id
     AFTER the POST and BEFORE the PUT (the caller writes the invoking marker there). Returns
     { outcome; draft_id; deleted; message; email_count; email_status } where outcome is one of
       sent             the email is queued
       staged           TC_STAGE_WRITES queued the POST; nothing was sent
       draft-failed     the POST failed; nothing was published (message says whether a draft may exist)
       publish-rejected the PUT provably did not publish; the draft was deleted (deleted=$false: it is orphaned)
       ambiguous        the PUT may have published and mailed; nothing was deleted
       not-queued       published but Ghost queued no email; the dead post was deleted (deleted=$false: orphan) #>
  param([string]$ApiUrl, [string]$LabelName, [string]$DraftJson, [scriptblock]$Headers, [scriptblock]$OnDraft)
  $r = [ordered]@{ outcome = ''; draft_id = ''; deleted = $false; message = ''; email_count = 0; email_status = '' }
  try {
    $resp = Invoke-GhostApi -Method POST -Uri ($ApiUrl + '/ghost/api/admin/posts/') -Headers (& $Headers) -Body ([Text.Encoding]::UTF8.GetBytes($DraftJson)) -TimeoutSec 30
  } catch {
    $kind = Get-GhostFailureKind $_
    $r.outcome = 'draft-failed'
    $r.message = 'draft POST failed (' + $kind + '): ' + (Get-GhostErrorText $_)
    if ($kind -eq 'ambiguous') { $r.message += ' - a draft may exist in Ghost with no id reported here; it mails nobody' }
    return [pscustomobject]$r
  }
  if (Test-TcStaged $resp) { $r.outcome = 'staged'; $r.message = 'POST staged, not sent'; return [pscustomobject]$r }
  $draft = $resp.posts[0]
  $id = [string]$draft.id
  $r.draft_id = $id
  & $OnDraft $id
  $pubJson = '{"posts":[{"status":"published","updated_at":' + (JStr ([string]$draft.updated_at)) + '}]}'
  $pubUri = $ApiUrl + '/ghost/api/admin/posts/' + $id + '/?newsletter=price-alerts&email_segment=' + [uri]::EscapeDataString('label:' + $LabelName)
  try {
    # ONE attempt: see the header. A replay after a lost success would 409 and read as a refusal.
    $null = Invoke-GhostApi -Method PUT -Uri $pubUri -Headers (& $Headers) -Body ([Text.Encoding]::UTF8.GetBytes($pubJson)) -TimeoutSec 30 -MaxRetries 0
  } catch {
    $kind = Get-GhostFailureKind $_
    $err = Get-GhostErrorText $_
    if ($kind -eq 'ambiguous') {
      $r.outcome = 'ambiguous'
      $r.message = 'publish PUT outcome unknown (' + $err + '); post ' + $id + ' was NOT deleted because Ghost may be mailing it'
      return [pscustomobject]$r
    }
    $del = Remove-AlertPost -ApiUrl $ApiUrl -PostId $id -Headers $Headers
    $r.outcome = 'publish-rejected'; $r.deleted = $del.ok
    $r.message = 'publish PUT ' + $kind + ' (' + $err + ')'
    if ($del.ok) { $r.message += '; draft ' + $id + ' deleted' } else { $r.message += '; ORPHAN DRAFT ' + $id + ' could not be deleted: ' + $del.why }
    return [pscustomobject]$r
  }
  try {
    $chk = (Invoke-GhostApi -Method GET -Uri ($ApiUrl + '/ghost/api/admin/posts/' + $id + '/?include=email') -Headers (& $Headers) -TimeoutSec 30).posts[0]
  } catch {
    $r.outcome = 'ambiguous'
    $r.message = 'published post ' + $id + ' but the email check failed (' + (Get-GhostErrorText $_) + '); it was NOT deleted'
    return [pscustomobject]$r
  }
  if ($chk.email -and $chk.email.status -ne 'failed') {
    $r.outcome = 'sent'; $r.email_count = $chk.email.email_count; $r.email_status = [string]$chk.email.status
    return [pscustomobject]$r
  }
  $st = if ($chk.email) { [string]$chk.email.status } else { 'none' }
  $del = Remove-AlertPost -ApiUrl $ApiUrl -PostId $id -Headers $Headers
  $r.outcome = 'not-queued'; $r.deleted = $del.ok
  $r.message = 'post published but EMAIL DID NOT QUEUE (status=' + $st + ')'
  if ($del.ok) { $r.message += ' - deleted the dead post, will retry next run' } else { $r.message += ' - ORPHAN POST ' + $id + ' could not be deleted: ' + $del.why }
  return [pscustomobject]$r
}

# ------------------------------------------------------------------------------------- the run
function Invoke-PriceAlertRun {
  <# Everything after the boards are read: the state and marker reads, the candidates, the sends and the state
     writes. -Alert pages Brad (subject, body); the self-test passes a counter. Returns { outcome; sent; lines }
     with outcome refused | nothing | done. #>
  param([object[]]$Rows, [hashtable]$HistById, [string]$Week, [hashtable]$SaleEnd, [string]$StateFile, [string]$MarkerFile,
        [string]$ApiUrl, [scriptblock]$Headers, [scriptblock]$Alert, [bool]$IsDryRun, [string]$ForceItem, [datetime]$Now)
  $lines = New-Object System.Collections.ArrayList
  $st0 = Read-AlertStateFile -Path $StateFile
  if (-not $st0.ok) {
    $why = 'price-alerts REFUSED: ' + $st0.why + ' (' + $StateFile + '). Nothing was sent and nothing was written, because reading it as empty would re-alert every subscriber at a low and then overwrite the file with only today''s sends. Repair or restore the file (git log -- grocery/alert-state.json), or delete it to start fresh, then re-run.'
    & $Alert 'Price alerts refused: alert-state.json cannot be read' $why
    [void]$lines.Add($why)
    return [pscustomobject]@{ outcome = 'refused'; sent = 0; lines = $lines.ToArray() }
  }
  $state = $st0.state
  $mk0 = Read-AlertStateFile -Path $MarkerFile -Name 'price-alerts.invoking.json'
  if (-not $mk0.ok) {
    $why = 'price-alerts REFUSED: ' + $mk0.why + ' (' + $MarkerFile + '). It names alert sends that may be in flight, so without it no run can tell a fresh item from one Ghost may already have mailed. Nothing was sent or written. Check Ghost for #price-alerts posts from the last few days, then delete the file.'
    & $Alert 'Price alerts refused: the invoking marker cannot be read' $why
    [void]$lines.Add($why)
    return [pscustomobject]@{ outcome = 'refused'; sent = 0; lines = $lines.ToArray() }
  }
  $invoking = $mk0.state
  $today = $Now.ToString('yyyy-MM-dd')
  $seen = @{}
  $candidates = @()
  foreach ($r in $Rows) {
    $id = [string]$r.id
    if ($seen.ContainsKey($id)) { continue }
    $seen[$id] = $true
    $h = $HistById[$id]; if (-not $h) { continue }
    $ranked = @($r.stores | Where-Object { [double]$_.per_unit -gt 0 } | Sort-Object per_unit)
    if ($ranked.Count -eq 0) { continue }
    $P = [double]$ranked[0].per_unit
    $store = [string]$ranked[0].store
    # outlier guard (mirror sanity-check threshold)
    if ($ranked.Count -ge 2) { $ru = [double]$ranked[1].per_unit; if ($ru -gt 0 -and (($ru - $P) / $ru) -gt 0.30) { continue } }
    $prior = @($h.history | Where-Object { try { [datetime]$_.week_of -lt [datetime]$Week } catch { $false } })
    if (@($prior).Count -lt 2) { continue }
    $priorMin = $null; foreach ($e in $prior) { $ep = [double]$e.cheapest_price; if ($priorMin -eq $null -or $ep -lt $priorMin) { $priorMin = $ep } }
    $isLow = ($P -le ($priorMin + 0.0001))
    $force = ($ForceItem -ne '' -and $id -eq $ForceItem)
    if (-not $isLow -and -not $force) { continue }
    if (-not (Test-AlertDue -Price $P -St $state[$id] -IsForce $force -Now $Now)) { continue }
    $label = if ($h.label) { [string]$h.label } else { [string]$r.commodity }
    $candidates += ,@{ id=$id; label=$label; unit=[string]$r.unit; price=$P; store=$store; se=$(if ($SaleEnd.ContainsKey($id)) { $SaleEnd[$id] } else { $null }) }
  }

  if ($candidates.Count -eq 0) { [void]$lines.Add('price-alerts: nothing new at a low today'); return [pscustomobject]@{ outcome = 'nothing'; sent = 0; lines = $lines.ToArray() } }
  [void]$lines.Add("price-alerts: " + $candidates.Count + " candidate(s): " + (($candidates | ForEach-Object { $_.id }) -join ', '))

  $sent = 0
  foreach ($c in $candidates) {
    $labelName = 'alert-' + $c.id
    if ($invoking.ContainsKey($c.id)) {
      $m = $invoking[$c.id]
      $why = ('price-alerts: ' + $c.id + ' is HELD. A send began on ' + [string]$m.date + ' (post ' + [string]$m.draft_id + ') and never recorded that it finished, so Ghost may or may not have mailed its subscribers. Nothing was sent for it. Check the post in Ghost admin (Posts, #price-alerts tag): if it went out, run send-price-alerts.ps1 -ResolveInvoking ' + $c.id + ' -Mailed; if not, run -ResolveInvoking ' + $c.id + ' alone.')
      [void]$lines.Add('  ' + $why)
      if (-not $IsDryRun) { & $Alert 'Price alerts: an item is held until someone checks Ghost' $why }
      continue
    }
    # any subscribers?
    try { $mr = Invoke-GhostApi -Method GET -Uri ($ApiUrl + '/ghost/api/admin/members/?filter=' + [uri]::EscapeDataString('label:' + $labelName) + '&limit=1') -Headers (& $Headers) -TimeoutSec 30 }
    catch { [void]$lines.Add("  " + $c.id + ": member lookup failed - skipped"); continue }
    $total = [int]$mr.meta.pagination.total
    if ($total -eq 0) { [void]$lines.Add("  " + $c.id + ": at a low but 0 subscribers - skipped (no state update)"); continue }

    $priceTxt = (Fmt $c.price) + '/' + $c.unit
    $title = 'Price alert: ' + $c.label + ' just hit ' + $priceTxt + ' at ' + $c.store
    $seLine = ''
    if ($c.se) { try { $seLine = '<p style="color:#b23b2e;font-weight:600">It is a sale price, and it runs through ' + ([datetime]$c.se).ToString('dddd, MMM d') + '. After that it goes back up.</p>' } catch {} }
    $bodyHtml = '<p>You asked us to watch <b>' + $c.label + '</b> for you. Good news.</p>' +
      '<p style="font-size:1.3em"><b>' + $priceTxt + ' at ' + $c.store + '</b> - the lowest price we have tracked for it in Omaha.</p>' +
      $seLine +
      '<p><a href="https://www.thriftycrew.com/omaha-grocery-prices/?ref=price-alert">See every store&#39;s price on the live board &rarr;</a></p>' +
      '<p style="color:#8a94a6;font-size:.9em">You get this because you signed up for price alerts on this item at thriftycrew.com. Unsubscribing below stops all price-alert emails.</p>'
    if ($IsDryRun) { [void]$lines.Add("  DRYRUN would email " + $total + "+ subscriber(s): " + $title); continue }

    # Ghost only queues the newsletter email on the draft->published TRANSITION via PUT; creating a
    # post directly as published silently ignores ?newsletter= (post says "sent", no email exists).
    # So: 1) create DRAFT, 2) PUT status published WITH the newsletter + segment params, 3) verify the
    # email object actually exists before claiming success.
    $lex = '{"root":{"children":[{"type":"html","version":1,"html":' + (JStr $bodyHtml) + '}],"direction":null,"format":"","indent":0,"type":"root","version":1}}'
    $draftJson = '{"posts":[{"title":' + (JStr $title) + ',"lexical":' + (JStr $lex) + ',"status":"draft","email_only":true,"tags":[{"name":"#price-alerts"}]}]}'
    $cid = $c.id; $cprice = $c.price; $cstore = $c.store
    $onDraft = {
      param($draftId)
      # invoking: BEFORE the PUT, which is the send
      $invoking[$cid] = [ordered]@{ date = $today; draft_id = $draftId; price = $cprice; store = $cstore }
      Write-AlertInvokingFile -Path $MarkerFile -Map $invoking
    }
    $res = Invoke-PriceAlertPublish -ApiUrl $ApiUrl -LabelName $labelName -DraftJson $draftJson -Headers $Headers -OnDraft $onDraft
    # -OnDraft runs inside Invoke-PriceAlertPublish and reaches $invoking, $cid and $MarkerFile by PowerShell's dynamic scope (a GetNewClosure copy would lose the script's functions).
    switch ($res.outcome) {
      'sent' {
        [void]$lines.Add("  SENT " + $c.id + " -> " + $res.email_count + " recipient(s), email status " + $res.email_status + ": " + $title)
        $state[$c.id] = @{ price = $c.price; date = $today; store = $c.store }
        Write-AlertStateFile -Path $StateFile -State $state      # sent: recorded before the marker goes
        [void]$invoking.Remove($c.id); Write-AlertInvokingFile -Path $MarkerFile -Map $invoking
        $sent++
      }
      'ambiguous' {
        $why = ('price-alerts: ' + $c.id + ': SEND OUTCOME UNKNOWN - ' + $res.message + '. The item is held (grocery\out\price-alerts.invoking.json) so no run mails its subscribers again. Check post ' + $res.draft_id + ' in Ghost admin: if it went out, run send-price-alerts.ps1 -ResolveInvoking ' + $c.id + ' -Mailed; if not, run -ResolveInvoking ' + $c.id + ' alone.')
        [void]$lines.Add('  ' + $why)
        & $Alert 'Price alerts: a send may have gone out and was not recorded' $why
      }
      default {
        # staged, draft-failed, publish-rejected, not-queued: nothing was mailed, so the item is not held.
        if ($invoking.ContainsKey($c.id)) { [void]$invoking.Remove($c.id); Write-AlertInvokingFile -Path $MarkerFile -Map $invoking }
        [void]$lines.Add("  " + $c.id + ": SEND FAILED - " + $res.outcome + ": " + $res.message)
        if ((@('publish-rejected', 'not-queued') -contains $res.outcome) -and -not $res.deleted) {
          & $Alert 'Price alerts: an orphan post could not be deleted from Ghost' ('price-alerts: ' + $c.id + ': ' + $res.message + '. Delete post ' + $res.draft_id + ' in Ghost admin (Posts, #price-alerts tag). Nothing was mailed for it.')
        }
      }
    }
  }

  if (-not $IsDryRun) { Write-AlertStateFile -Path $StateFile -State $state }
  return [pscustomobject]@{ outcome = 'done'; sent = $sent; lines = $lines.ToArray() }
}

function Invoke-ResolveInvoking {
  <# Brad's release of a held item, after checking Ghost. -Mailed records it as sent from the marker's own price,
     store and date; without it the entry is only cleared, so the next run may alert again. { ok; line } #>
  param([string]$Id, [bool]$WasMailed, [string]$StateFile, [string]$MarkerFile)
  $mk = Read-AlertStateFile -Path $MarkerFile -Name 'price-alerts.invoking.json'
  if (-not $mk.ok) { return [pscustomobject]@{ ok = $false; line = ('price-alerts: ' + $mk.why) } }
  if (-not $mk.state.ContainsKey($Id)) { return [pscustomobject]@{ ok = $false; line = ('price-alerts: ' + $Id + ' is not held; nothing to resolve') } }
  $m = $mk.state[$Id]
  if ($WasMailed) {
    $st = Read-AlertStateFile -Path $StateFile
    if (-not $st.ok) { return [pscustomobject]@{ ok = $false; line = ('price-alerts: ' + $st.why + '; nothing changed') } }
    $st.state[$Id] = @{ price = $m.price; date = [string]$m.date; store = [string]$m.store }
    Write-AlertStateFile -Path $StateFile -State $st.state
  }
  [void]$mk.state.Remove($Id)
  Write-AlertInvokingFile -Path $MarkerFile -Map $mk.state
  $what = if ($WasMailed) { 'recorded as sent on ' + [string]$m.date } else { 'released; the next run may alert it' }
  return [pscustomobject]@{ ok = $true; line = ('price-alerts: ' + $Id + ' ' + $what) }
}

# ------------------------------------------------------------------------------------- self-test
if ($SelfTest) {
  $script:fails = 0; $script:cases = 0
  function Check([string]$Label, [bool]$Ok, [string]$Got) {
    $script:cases++
    if ($Ok) { Write-Output ('ok    ' + $Label) } else { Write-Output ('FAIL  ' + $Label + '   got: ' + $Got); $script:fails++ }
  }
  $dir = Join-Path ([IO.Path]::GetTempPath()) ('spa-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
  New-Item -ItemType Directory -Path $dir -ErrorAction Stop | Out-Null
  $sf = Join-Path $dir 'alert-state.json'
  $mf = Join-Path $dir 'price-alerts.invoking.json'
  $saveStage = $env:TC_STAGE_WRITES; $saveJournal = $env:TC_WRITE_JOURNAL
  # The transport seam from lib\ghost-lib.ps1: every Ghost call below goes through the real Invoke-GhostApi into
  # this stub. Nothing here can reach Ghost, and a stubbed transport is never journalled.
  $script:calls = New-Object System.Collections.ArrayList
  $script:plan = @{}
  function Invoke-TcGhostTransport { param([hashtable]$CallArgs, [switch]$Web)
    $m = ([string]$CallArgs.Method).ToUpper()
    [void]$script:calls.Add([pscustomobject]@{ method = $m; uri = [string]$CallArgs.Uri })
    $step = $script:plan[$m]
    if ($step -is [scriptblock]) { $step = & $step $CallArgs }
    if ($step -is [Exception]) { throw $step }
    return $step }
  function Wait-TcGhostRetry { param([int]$Seconds) }
  function New-StubHttp([int]$Code) { $x = New-Object System.Exception ('The remote server returned an error: (' + $Code + ').'); $x | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = $Code }); return $x }
  function New-StubTimeout { return (New-Object System.Net.WebException('The operation has timed out', [System.Net.WebExceptionStatus]::Timeout)) }
  # The comma is load-bearing: without it one matching call unrolls to a bare object and .Count reads nothing.
  function Get-Calls([string]$Method) { return ,@($script:calls | Where-Object { $_.method -eq $Method }) }
  $script:alerts = New-Object System.Collections.ArrayList
  $countAlert = { param($s, $w) [void]$script:alerts.Add([pscustomobject]@{ subject = $s; body = $w }) }
  $hdr = { @{ Authorization = 'Ghost stub'; 'Accept-Version' = 'v5.0' } }
  $api = 'https://invalid.invalid'
  $Now = [datetime]'2026-09-18T08:00:00'
  # one item at a record low: 1.89 against prior lows of 1.99 and 2.49, runner-up 2.10 (inside the outlier guard)
  $rows = @([pscustomobject]@{ id = 'chicken-breast'; commodity = 'Chicken breast'; unit = 'lb'; stores = @(
    [pscustomobject]@{ store = 'Hy-Vee'; per_unit = 1.89 }, [pscustomobject]@{ store = 'Aldi'; per_unit = 2.10 }) })
  $hist = @{ 'chicken-breast' = [pscustomobject]@{ id = 'chicken-breast'; label = 'Chicken breast'; history = @(
    [pscustomobject]@{ week_of = '2026-09-04'; cheapest_price = 1.99 }, [pscustomobject]@{ week_of = '2026-09-11'; cheapest_price = 2.49 }) } }
  $W = '2026-09-18'
  function Reset-Case([hashtable]$Plan) {
    $script:calls.Clear(); $script:alerts.Clear(); $script:plan = $Plan
    foreach ($p in @($sf, $mf)) { if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force } }
  }
  $okMembers = [pscustomobject]@{ meta = [pscustomobject]@{ pagination = [pscustomobject]@{ total = 3 } } }
  $okDraft = [pscustomobject]@{ posts = @([pscustomobject]@{ id = 'draft-abc123'; updated_at = '2026-09-18T08:00:00.000Z' }) }
  $okEmail = [pscustomobject]@{ posts = @([pscustomobject]@{ id = 'draft-abc123'; email = [pscustomobject]@{ status = 'submitted'; email_count = 3 } }) }
  $getPlan = { param($a) if ($a.Uri -like '*members*') { return $okMembers } return $okEmail }
  function Invoke-Run { return (Invoke-PriceAlertRun -Rows $rows -HistById $hist -Week $W -SaleEnd @{} -StateFile $sf -MarkerFile $mf -ApiUrl $api -Headers $hdr -Alert $countAlert -IsDryRun $false -ForceItem '' -Now $Now) }
  try {
    $env:TC_STAGE_WRITES = $null; $env:TC_WRITE_JOURNAL = $null

    # ---- I224: a failed publish deletes the draft it just made ----
    Reset-Case @{ GET = $getPlan; POST = $okDraft; PUT = (New-StubHttp 422); DELETE = [pscustomobject]@{} }
    $r = Invoke-Run
    $dels = Get-Calls 'DELETE'
    Check 'MUST FIRE  a refused publish PUT (422) DELETEs exactly one post, the draft just created' (($dels.Count -eq 1) -and ($dels[0].uri -like '*/posts/draft-abc123/')) ("deletes=" + $dels.Count + " uris=" + (($dels | ForEach-Object { $_.uri }) -join ','))
    Check 'MUST FIRE  and records nothing: no state row, no marker left, no alert (the draft is gone)' ((-not (Test-Path -LiteralPath $mf)) -and ((Read-AlertStateFile $sf).state.Count -eq 0) -and ($script:alerts.Count -eq 0) -and ($r.sent -eq 0)) ("marker=" + (Test-Path -LiteralPath $mf) + " alerts=" + $script:alerts.Count + " sent=" + $r.sent)

    Reset-Case @{ GET = $getPlan; POST = $okDraft; PUT = [pscustomobject]@{ posts = @() }; DELETE = [pscustomobject]@{} }
    $r = Invoke-Run
    $st = (Read-AlertStateFile $sf).state
    Check 'MUST NOT FIRE  a successful publish DELETEs nothing' ((Get-Calls 'DELETE').Count -eq 0) ("deletes=" + (Get-Calls 'DELETE').Count)
    Check 'CLEAN TWIN a successful publish sends once and records the price' (((Get-Calls 'PUT').Count -eq 1) -and ($r.sent -eq 1) -and ([double]$st['chicken-breast'].price -eq 1.89) -and ($st['chicken-breast'].date -eq '2026-09-18')) ("deletes=" + (Get-Calls 'DELETE').Count + " sent=" + $r.sent + " state=" + [IO.File]::ReadAllText($sf))
    Check 'MUST NOT FIRE  no invoking marker is left after a verified send' (-not (Test-Path -LiteralPath $mf)) ("marker present")

    Reset-Case @{ GET = $getPlan; POST = $okDraft; PUT = (New-StubHttp 409); DELETE = (New-StubHttp 500) }
    $r = Invoke-Run
    Check 'MUST FIRE  when the DELETE fails too, one page names the orphan draft id' (($script:alerts.Count -eq 1) -and ($script:alerts[0].body -like '*draft-abc123*') -and ((@($r.lines) -join "`n") -like '*ORPHAN DRAFT draft-abc123*')) ("alerts=" + $script:alerts.Count + " lines=" + (@($r.lines) -join ' / '))
    Check 'CLEAN TWIN the DELETE is idempotent, so the lib retried it (1 + 3 attempts)' ((Get-Calls 'DELETE').Count -eq 4) ("deletes=" + (Get-Calls 'DELETE').Count)

    # ---- I224 + I198: an UNKNOWN publish outcome is never deleted and never replayed ----
    Reset-Case @{ GET = $getPlan; POST = $okDraft; PUT = (New-StubTimeout); DELETE = [pscustomobject]@{} }
    $r = Invoke-Run
    $mk = (Read-AlertStateFile $mf).state
    Check 'MUST FIRE  a PUT that times out is attempted ONCE and its post is NOT deleted' (((Get-Calls 'PUT').Count -eq 1) -and ((Get-Calls 'DELETE').Count -eq 0)) ("puts=" + (Get-Calls 'PUT').Count + " deletes=" + (Get-Calls 'DELETE').Count)
    Check 'MUST FIRE  it leaves the item INVOKING with its post id, no state row, and pages once' (($mk.ContainsKey('chicken-breast')) -and ($mk['chicken-breast'].draft_id -eq 'draft-abc123') -and ((Read-AlertStateFile $sf).state.Count -eq 0) -and ($script:alerts.Count -eq 1)) ("marker=" + $(if (Test-Path -LiteralPath $mf) { [IO.File]::ReadAllText($mf) } else { 'none' }) + " alerts=" + $script:alerts.Count)
    $script:calls.Clear(); $script:alerts.Clear(); $script:plan = @{ GET = $getPlan; POST = $okDraft; PUT = [pscustomobject]@{}; DELETE = [pscustomobject]@{} }
    $r = Invoke-Run
    Check 'MUST FIRE  so the NEXT run holds the item: zero POSTs, zero PUTs, one page' (((Get-Calls 'POST').Count -eq 0) -and ((Get-Calls 'PUT').Count -eq 0) -and ($script:alerts.Count -eq 1) -and ($r.sent -eq 0)) ("posts=" + (Get-Calls 'POST').Count + " puts=" + (Get-Calls 'PUT').Count + " alerts=" + $script:alerts.Count)
    $rv = Invoke-ResolveInvoking -Id 'chicken-breast' -WasMailed $true -StateFile $sf -MarkerFile $mf
    $st = (Read-AlertStateFile $sf).state
    Check 'CLEAN TWIN -ResolveInvoking -Mailed records it as sent and releases the hold' ($rv.ok -and ([double]$st['chicken-breast'].price -eq 1.89) -and -not (Test-Path -LiteralPath $mf)) ("ok=" + $rv.ok + " state=" + $(if (Test-Path -LiteralPath $sf) { [IO.File]::ReadAllText($sf) } else { 'none' }))

    Reset-Case @{ GET = { param($a) if ($a.Uri -like '*members*') { return $okMembers } throw (New-StubTimeout) }; POST = $okDraft; PUT = [pscustomobject]@{}; DELETE = [pscustomobject]@{} }
    $r = Invoke-Run
    Check 'MUST FIRE  a good PUT whose email check fails is held too, not deleted and not recorded' (((Get-Calls 'DELETE').Count -eq 0) -and ((Read-AlertStateFile $mf).state.ContainsKey('chicken-breast')) -and ($script:alerts.Count -eq 1)) ("deletes=" + (Get-Calls 'DELETE').Count + " alerts=" + $script:alerts.Count)
    $rv = Invoke-ResolveInvoking -Id 'chicken-breast' -WasMailed $false -StateFile $sf -MarkerFile $mf
    Check 'MUST NOT FIRE  -ResolveInvoking without -Mailed releases the hold and records nothing' ($rv.ok -and -not (Test-Path -LiteralPath $mf) -and ((Read-AlertStateFile $sf).state.Count -eq 0)) ("ok=" + $rv.ok)

    # ---- I161 option A: an unreadable state file stops the run ----
    foreach ($bad in @(@{ n = 'invalid JSON'; t = '{"chicken-breast":{"price":1.99,' }, @{ n = 'an empty file'; t = '' }, @{ n = 'a JSON array'; t = '[1,2]' })) {
      Reset-Case @{ GET = $getPlan; POST = $okDraft; PUT = [pscustomobject]@{}; DELETE = [pscustomobject]@{} }
      [IO.File]::WriteAllText($sf, $bad.t, (New-Object Text.UTF8Encoding($false)))
      $before = [IO.File]::ReadAllBytes($sf)
      $r = Invoke-Run
      $after = [IO.File]::ReadAllBytes($sf)
      $same = ($before.Length -eq $after.Length) -and (-not (Compare-Object $before $after))
      Check ('MUST FIRE  an unreadable state file (' + $bad.n + ') refuses: zero Ghost calls, file unchanged, one page') (($r.outcome -eq 'refused') -and ($script:calls.Count -eq 0) -and $same -and ($script:alerts.Count -eq 1) -and -not (Test-Path -LiteralPath $mf)) ("outcome=" + $r.outcome + " calls=" + $script:calls.Count + " same=" + $same + " alerts=" + $script:alerts.Count)
    }
    Reset-Case @{ GET = $getPlan; POST = $okDraft; PUT = [pscustomobject]@{}; DELETE = [pscustomobject]@{} }
    $r = Invoke-Run
    Check 'CLEAN TWIN a MISSING state file is still a fresh start: the item sends' (($r.outcome -eq 'done') -and ($r.sent -eq 1)) ("outcome=" + $r.outcome + " sent=" + $r.sent)

    # ---- I161 option A: a missing or zero price is UNKNOWN, alerts once, and the real price is recorded ----
    foreach ($pv in @(@{ n = 'missing'; t = '{"chicken-breast":{"date":"2026-09-17","store":"Hy-Vee"}}' }, @{ n = 'zero'; t = '{"chicken-breast":{"price":0,"date":"2026-09-17","store":"Hy-Vee"}}' })) {
      Reset-Case @{ GET = $getPlan; POST = $okDraft; PUT = [pscustomobject]@{}; DELETE = [pscustomobject]@{} }
      [IO.File]::WriteAllText($sf, $pv.t, (New-Object Text.UTF8Encoding($false)))
      $r = Invoke-Run
      $st = (Read-AlertStateFile $sf).state
      Check ('MUST FIRE  a ' + $pv.n + ' price alerts once and records the real price') (($r.sent -eq 1) -and ([double]$st['chicken-breast'].price -eq 1.89)) ("sent=" + $r.sent + " state=" + [IO.File]::ReadAllText($sf))
      $script:calls.Clear()
      $r = Invoke-Run
      Check ('MUST FIRE  and the day after, the ' + $pv.n + ' price case is quiet: the recorded price holds it') (($r.outcome -eq 'nothing') -and ((Get-Calls 'POST').Count -eq 0)) ("outcome=" + $r.outcome + " posts=" + (Get-Calls 'POST').Count)
    }
    Reset-Case @{ GET = $getPlan; POST = $okDraft; PUT = [pscustomobject]@{}; DELETE = [pscustomobject]@{} }
    [IO.File]::WriteAllText($sf, '{"chicken-breast":{"price":1.89,"date":"2026-09-10","store":"Hy-Vee"}}', (New-Object Text.UTF8Encoding($false)))
    $r = Invoke-Run
    Check 'MUST NOT FIRE  a well-formed row at the same price inside 30 days stays quiet' (($r.outcome -eq 'nothing') -and ($script:calls.Count -eq 0)) ("outcome=" + $r.outcome + " calls=" + $script:calls.Count)
    $d = @{ 'x' = [pscustomobject]@{ price = 1.99; date = '2026-09-11'; store = 'Hy-Vee' }; 'y' = [pscustomobject]@{ date = '2026-09-11'; store = 'Aldi' } }
    $json = ConvertTo-AlertStateJson $d
    Check 'CLEAN TWIN the state bytes keep their shape, and an unknown price is written null, never 0' ($json -ceq '{"x":{"price":1.99,"date":"2026-09-11","store":"Hy-Vee"},"y":{"price":null,"date":"2026-09-11","store":"Aldi"}}') ("json=" + $json)

    # ---- the checkout rule and the marker's road ----
    $repoRoot = Split-Path $root -Parent
    & git -C $repoRoot check-ignore -q --no-index 'grocery/out/price-alerts.invoking.json'
    Check 'MUST FIRE  the invoking marker is gitignored, so the bot''s grocery/out sweep cannot commit it' ($LASTEXITCODE -eq 0) ("check-ignore rc=" + $LASTEXITCODE)
    & git -C $repoRoot ls-files --error-unmatch 'grocery/alert-state.json' | Out-Null
    Check 'CLEAN TWIN alert-state.json itself is still tracked' ($LASTEXITCODE -eq 0) ("ls-files rc=" + $LASTEXITCODE)
  } catch {
    $script:fails++; Write-Output ('FAIL  the suite threw: ' + $_.Exception.Message + ' at line ' + $_.InvocationInfo.ScriptLineNumber)
  } finally {
    $env:TC_STAGE_WRITES = $saveStage; $env:TC_WRITE_JOURNAL = $saveJournal
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
  }
  $expected = 25
  if ($script:cases -ne $expected) { $script:fails++; Write-Output ("FAIL  ran {0} of {1} cases" -f $script:cases, $expected) }
  if ($script:fails) { Write-Output ("send-price-alerts self-test: FAIL ({0} of {1} cases failed)" -f $script:fails, $script:cases); exit 1 }
  Write-Output ("send-price-alerts self-test: PASS ({0} of {0} cases)" -f $script:cases)
  exit 0
}

# ------------------------------------------------------------------------------------- live run
$stateFile = Join-Path $root 'alert-state.json'
$markerFile = Join-Path $OutDir 'price-alerts.invoking.json'
$repoRoot = Split-Path $root -Parent
if (-not $DryRun) {
  $kind = Get-TcCheckoutKind -Root $repoRoot
  if ($kind -ne 'main') {
    $shown = if ($kind) { $kind } else { 'unknown' }
    Write-Output ("price-alerts REFUSED: this checkout ({0}) is '{1}', not the main checkout. The sent record and the invoking marker live in the main checkout, so a send or a resolve from here could mail an item twice. Nothing was sent or written. -DryRun works from any checkout." -f $repoRoot, $shown)
    exit 1
  }
}
if ($ResolveInvoking) {
  if ($DryRun) { Write-Output 'price-alerts: -ResolveInvoking writes, so it does not take -DryRun'; exit 1 }
  $rv = Invoke-ResolveInvoking -Id $ResolveInvoking -WasMailed ([bool]$Mailed) -StateFile $stateFile -MarkerFile $markerFile
  Write-Output $rv.line
  if ($rv.ok) { exit 0 } else { exit 1 }
}

$adminKey = if ($env:GHOST_ADMIN_KEY) { $env:GHOST_ADMIN_KEY }
  elseif (Test-Path (Join-Path $root '.ghostkey')) { (Get-Content (Join-Path $root '.ghostkey') -Raw).Trim() }
  elseif (Test-Path (Join-Path (Split-Path $root -Parent) 'meal-prep\.ghostkey')) { (Get-Content (Join-Path (Split-Path $root -Parent) 'meal-prep\.ghostkey') -Raw).Trim() }
  else { throw 'Ghost admin key missing' }
$apiUrl = 'https://map-to-success.ghost.io'
$liveHeaders = { @{ Authorization = ('Ghost ' + (Get-GhostJWT -Key $adminKey)); 'Accept-Version' = 'v5.0'; 'Content-Type' = 'application/json' } }

# ---- boards + history ----
$cmpF = (Get-ChildItem (Join-Path $OutDir 'comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1)
$CompareFile = $cmpF.FullName
try { $wk0 = (Read-JsonFile $cmpF.FullName).week_of; $verF = Join-Path $OutDir ("verified-" + $wk0 + ".json"); if ((Test-Path $verF) -and ((Get-Item $verF).LastWriteTime -ge $cmpF.LastWriteTime)) { $CompareFile = $verF } } catch {}
$doc = Read-JsonFile $CompareFile
$week = [string]$doc.week_of
$rows = @($doc.comparison)
$riF = Join-Path $OutDir 'recipe-board.json'
if (Test-Path $riF) { $rows = $rows + @((Read-JsonFile $riF).comparison) }

$histFile = Join-Path $root 'price-history.json'
if (-not (Test-Path $histFile)) { Write-Output 'no price-history.json - nothing to alert on'; exit 0 }
$histById = @{}
foreach ($h in ((Read-JsonFile $histFile).commodities)) { $histById[[string]$h.id] = $h }

# feed (for sale_end lines in the email)
$saleEnd = @{}
try { $feed = Read-JsonFile (Join-Path $OutDir 'smp-feed.json')
      foreach ($p in $feed.ingredients.PSObject.Properties) { if ($p.Value.sale_end) { $saleEnd[[string]$p.Name] = [string]$p.Value.sale_end } } } catch {}

. (Join-Path $root 'alert-lib.ps1')   # Send-Alert: the estate's one pager (queue first, mail second)
$liveAlert = { param($subject, $why) Send-Alert -Subject $subject -Body $why -What 'PRICE-ALERTS' | Out-Null }
if (Test-Path -LiteralPath $markerFile) { Write-Output ('price-alerts: ' + $markerFile + ' exists, so an earlier send is unresolved and its item(s) are held until -ResolveInvoking') }
$res = Invoke-PriceAlertRun -Rows $rows -HistById $histById -Week $week -SaleEnd $saleEnd -StateFile $stateFile -MarkerFile $markerFile `
  -ApiUrl $apiUrl -Headers $liveHeaders -Alert $liveAlert -IsDryRun ([bool]$DryRun) -ForceItem $ForceItem -Now (Get-Date)
foreach ($l in $res.lines) { Write-Output $l }
if ($res.outcome -eq 'refused') { exit 1 }
if ($res.outcome -eq 'nothing') { exit 0 }
Write-Output ("price-alerts done: " + $res.sent + " email(s) sent")
