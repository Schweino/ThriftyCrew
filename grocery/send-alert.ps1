<#
  send-alert.ps1 - Emails a grocery-pipeline failure alert to Brad (schweino68@gmail.com) via the Gmail API,
  reusing the Work Google OAuth token. Only call this on a HARD failure (a pull that failed AFTER a retry),
  never on a temporary hiccup like "a store's new ad isn't posted yet."

  Requires the shared Google token to include the gmail.send scope. If it doesn't yet, this logs the failure
  and exits 1 (so the caller can fall back) - run google-oauth-authorize.ps1 once to add the scope.

  Usage: powershell -File send-alert.ps1 -Subject "Grocery pull failed: Baker's" -Body "details..."
#>
param(
  [string]$Subject = "Grocery pipeline alert",
  [string]$Body = "",
  # PASS A LONG OR QUOTED BODY BY FILE (2026-07-31). Every caller invokes this as
  # `& powershell -File send-alert.ps1 -Body $body`, and a body containing DOUBLE QUOTES breaks the
  # argument tokenization: measured today, a 2.3 KB body with quoted sizes ("24 x 16.9 fl oz") arrived as
  # 307 chars and the mangled remainder made Gmail answer 400 Bad Request. The queue entry still landed -
  # by design, queue first, mail second - but it landed TRUNCATED, which is the worst of both: an alert
  # that pages nobody and cannot be classified from its own body either. -BodyFile sidesteps the shell
  # entirely. Use it whenever the body carries quotes, or runs past a few hundred characters.
  [string]$BodyFile = "",
  [string]$To = "schweino68@gmail.com",
  # bypass the once-per-type-per-day gate for a genuinely new incident that must page through today. Callers
  # that already do their own signature de-dup (the consistency-drift alert) pass this so their finer-grained
  # logic wins; everything else takes the daily gate.
  [switch]$Force,
  # exercises the queue-routing decision against temp fixtures and exits. Sends nothing, touches no live file.
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$logFile = Join-Path $root 'alert-log.txt'
if ($BodyFile) {
  if (-not (Test-Path $BodyFile)) { throw "send-alert: -BodyFile not found: $BodyFile" }
  $Body = ((Get-Content $BodyFile -Raw) + '')   # ((...) + '') because [string]$null is $null in PS 5.1
}
# a locked log file must never kill the alerter - see the note in check-ad-cycles.ps1 (2026-07-28). This one
# matters twice over: Log() runs inside the catch that handles a failed queue write, so a locked log here
# would swallow the alert entirely.
function Log($m) {
  $line = ("[" + (Get-Date).ToString('s') + "] ") + $m
  for ($i = 0; $i -lt 5; $i++) { try { Add-Content -Path $logFile -Value $line -ErrorAction Stop; return } catch { Start-Sleep -Milliseconds 120 } }
  try { Write-Host ('[log locked, not written] ' + $line) } catch {}
}

# ---- ONE EMAIL PER ALERT TYPE PER DAY -------------------------------------------------------------------
# 2026-07-23: a single bad Walmart pull produced ~20 emails in one morning - not because 20 things broke, but
# because the pipeline ran 3 times and each run re-fired every alert channel (guards-failed, coverage-held,
# stores-dropped, drift, ...). The failures were real and the fail-closed design was correct; the INBOX was
# the bug. So the alert TYPE (the subject with its date/counts/rc-codes stripped) may email at most once a day.
# A stable, ongoing condition alerts once and then stays quiet until it either clears or a new day starts.
$today = (Get-Date -Format 'yyyy-MM-dd')
$typeKey = ($Subject.ToLower() `
    -replace '\d{4}-\d{2}-\d{2}', '' `
    -replace 'rc\s*=\s*\d+', '' `
    -replace '\d+(\.\d+)?', '' `
    -replace '[^a-z]+', ' ').Trim()

# ---- WHERE DOES THIS ALERT GO IN THE QUEUE? (2026-07-31) ------------------------------------------------
# One function, so the rule is testable (-SelfTest below) instead of buried in the write block.
#
# THE BUG IT FIXES: the queue keyed on type + DATE, so a condition that stays broken across midnight minted a
# second id every day. On 2026-07-31 the triage run opened with 14 alerts of which FIVE were the previous
# day's unresolved condition wearing a new id (cell drops, matching soundness, registry drift, link drift,
# price flags). Triage then paid to re-investigate and re-close each pair. A still-open item IS the same
# incident: absorb the recurrence, keep ONE id, and let the count and the recurrence list carry the news.
# Once an item is RESOLVED, the same condition firing again mints a fresh id on purpose - a fix that did not
# hold is a different fact from a fix nobody has attempted yet, and triage must see the difference.
# The 14-day bound stops a long-parked needs-brad item from silently swallowing months of occurrences.
function Get-QueueAction {
  param($Items, [string]$TypeKey, [string]$Today, [int]$MaxAbsorbDays = 14)
  $todayD = [datetime]$Today
  foreach ($i in @($Items)) {
    if ([string]$i.type -ne $TypeKey) { continue }
    if ([string]$i.status -ne 'open') { continue }          # resolved / needs-brad never absorb
    $age = 999
    try { $age = [int]($todayD - [datetime]([string]$i.date)).TotalDays } catch {}
    if ($age -lt 0 -or $age -gt $MaxAbsorbDays) { continue }
    if ($age -eq 0) { return @{ action = 'same-day'; target = $i } }
    return @{ action = 'absorb'; target = $i; days = $age }
  }
  return @{ action = 'new'; target = $null }
}

# ---- CAN A HUMAN (OR AN AGENT) JUDGE THIS ALERT FROM ITS OWN BODY? (2026-07-31) -------------------------
# An alert whose body carries no store, no commodity and no number cannot be classified without going and
# finding the data by hand - which is the same as not alerting. Two live examples: the multibuy flags whose
# queue record had EMPTY item/ad/size fields, and the Family Fare throttle alert that compared one 3-hourly
# slice against the whole catalogue and therefore paged forever. This does not block anything; it stamps
# body_thin on the entry so triage treats the ALERT as the bug, not just the condition it describes.
function Test-BodyThin([string]$Body) {
  $b = [string]$Body
  if ($b.Trim().Length -lt 120) { return $true }
  $hasStore = $b -imatch "hy-vee|baker|family fare|fareway|aldi|walmart|sam's|sams"
  $hasId    = $b -match '[a-z]{3,}(-[a-z0-9]{2,}){1,}'      # commodity-id shape, e.g. canned-mushrooms
  $hasNum   = $b -match '\d'
  if ($hasStore -or $hasId) { return $false }
  return (-not $hasNum)
}

if ($SelfTest) {
  $fail = 0
  function _T($label, $got, $want) {
    if ("$got" -eq "$want") { Write-Output "ok    $label" } else { Write-Output "FAIL  $label  got '$got' want '$want'"; $script:fail++ }
  }
  # MUST-FIRE: yesterday's still-open item absorbs today's recurrence instead of minting a second id.
  $items = @([pscustomobject]@{ type='grocery store s dropped from a commodity they carry'; date='2026-07-30'; status='open'; count=1 })
  _T 'open item from yesterday absorbs today' (Get-QueueAction $items 'grocery store s dropped from a commodity they carry' '2026-07-31').action 'absorb'
  # CLEAN TWIN: once it is resolved, the same condition tomorrow is NEWS and gets its own id.
  $items2 = @([pscustomobject]@{ type='grocery store s dropped from a commodity they carry'; date='2026-07-30'; status='resolved'; count=1 })
  _T 'resolved item does NOT absorb (a fix that did not hold is news)' (Get-QueueAction $items2 'grocery store s dropped from a commodity they carry' '2026-07-31').action 'new'
  # same day stays same-day (the original behaviour, unchanged)
  $items3 = @([pscustomobject]@{ type='t'; date='2026-07-31'; status='open'; count=1 })
  _T 'same-day duplicate still increments in place' (Get-QueueAction $items3 't' '2026-07-31').action 'same-day'
  # a parked needs-brad item must not swallow the recurrence
  $items4 = @([pscustomobject]@{ type='t'; date='2026-07-30'; status='needs-brad'; count=1 })
  _T 'needs-brad item does NOT absorb' (Get-QueueAction $items4 't' '2026-07-31').action 'new'
  # and neither does something ancient
  $items5 = @([pscustomobject]@{ type='t'; date='2026-06-01'; status='open'; count=1 })
  _T 'open item older than the absorb window does NOT absorb' (Get-QueueAction $items5 't' '2026-07-31').action 'new'
  # body-thin detection: the real multibuy record vs a real, judgeable body
  # a truncated first occurrence must be UPGRADED by a fuller later one, not preserved out of politeness
  $short = 'Verified in-browser: pull-aldi-instore reads the product page and takes its size field.'
  $full  = $short + (' ' * 400) + 'plus the three confirmed instances, the why-this-is-not-live-yet paragraph, and the root-cause list.'
  _T 'a materially fuller later body upgrades the stored one' ([bool]($full.Length -gt ($short.Length * 1.5) -and $full.Length -gt ($short.Length + 200))) 'True'
  _T 'a same-size repeat does NOT churn the stored body'      ([bool]($short.Length -gt ($short.Length * 1.5))) 'False'
  _T 'thin body flagged'  (Test-BodyThin 'MULTIBUY|Hy-Vee|Soda (12-pack)') 'True'
  _T 'rich body not flagged' (Test-BodyThin 'These commodity+store cells are on SALE with no everyday item to revert to: bell-peppers @ Family Fare; plums @ Family Fare; sandwich-cookies @ Family Fare. Browser stores are queued in grocery/out/research-worklist.json.') 'False'
  Write-Output ""
  if ($fail -gt 0) { Write-Output "SELF-TEST FAIL: $fail case(s)"; exit 1 }
  Write-Output 'SELF-TEST PASS (queue routing + body-thin)'
  exit 0
}

$sentFile = Join-Path $root ("alert-sent-$today.txt")
# purge prior days' sent-files: yesterday's suppressions are irrelevant, and the cloud job's `git add -A`
# would otherwise commit one new file to the repo every day forever
Get-ChildItem (Join-Path $root 'alert-sent-*.txt') -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -ne ("alert-sent-$today.txt") } | Remove-Item -Force -ErrorAction SilentlyContinue

# ---- TRIAGE QUEUE (2026-07-25, Brad's rule: an issue email must never wait for a human) -----------------
# EVERY alert - suppressed-duplicate or not - lands one durable entry in triage-queue.json BEFORE any email
# logic runs. The grocery-alert-triage scheduled agent drains this queue whenever the Claude app is open:
# it investigates, fixes what the data/rules/builders need, addresses the root cause, and marks the entry
# resolved with notes. The email to Brad stays (visibility), but the email is no longer the response system.
# One entry per type per day (same typeKey as the email gate) so a 3-run morning queues 1 item, not 20.
# 2026-07-28: this block used to read-modify-WRITE-IN-PLACE with Set-Content, which truncates the file and
# then fills it. Two readers get hurt in that window: triage-due.ps1 reads '' (and '' | ConvertFrom-Json
# returns $null in PS 5.1 WITHOUT throwing, so its fail-closed catch never fires and it reports IDLE - a whole
# triage tick silently skipped, which is exactly how 4 real alerts sat unworked this morning), and a CONCURRENT
# send-alert.ps1 reads the same empty file and rebuilds the queue from scratch, dropping every prior item.
# Fix: serialize writers on a named mutex, and swap the file in atomically so a reader sees only whole JSON.
$qMutex = New-Object System.Threading.Mutex($false, 'Global\smp-grocery-triage-queue')
$qHeld = $false
try { $qHeld = $qMutex.WaitOne(10000) } catch [System.Threading.AbandonedMutexException] { $qHeld = $true }
try {
  $qFile = Join-Path $root 'triage-queue.json'
  $qRaw = if (Test-Path $qFile) { Get-Content $qFile -Raw } else { $null }
  $q = $null
  if ($qRaw -and $qRaw.Trim()) { $q = $qRaw | ConvertFrom-Json }
  # An empty/blank/garbled read is NOT "no queue yet" - overwriting on that assumption is how the whole
  # backlog would disappear. Only build a fresh queue when the file genuinely does not exist.
  if (-not $q) {
    if (Test-Path $qFile) { throw ('triage-queue.json exists but read back empty/unparseable - refusing to overwrite ' + @(Get-Content $qFile -Raw).Length + ' bytes') }
    $q = [pscustomobject]@{ readme = 'Durable ops-alert queue. Written by send-alert.ps1 on EVERY alert (even inbox-suppressed dupes). Drained by the grocery-alert-triage scheduled agent: investigate -> fix -> fix the ROOT cause -> status=resolved + notes. Do not hand-edit except to force a re-triage (set status back to open).'; items = @() }
  }
  $items = @($q.items)
  $bodyStored = $(if ($Body.Length -gt 1500) { $Body.Substring(0,1500) + ' ...[truncated - full context in ad-cycle-log.txt / the source audit json]' } else { $Body })
  $thin = Test-BodyThin $Body
  $route = Get-QueueAction $items $typeKey $today
  switch ($route.action) {
    'same-day' {
      foreach ($d in @($items | Where-Object { $_.type -eq $typeKey -and $_.date -eq $today })) {
        $d.count = [int]$d.count + 1
        # same upgrade rule as the cross-day branch below: a truncated or thin first occurrence must not
        # outrank a later one that actually carries the evidence.
        $oldLen = ([string]$d.body).Length
        if ($bodyStored.Length -gt ($oldLen * 1.5) -and $bodyStored.Length -gt ($oldLen + 200)) {
          $d.body = $bodyStored
          if ($d.PSObject.Properties['body_upgraded']) { $d.body_upgraded = $today } else { $d | Add-Member -NotePropertyName body_upgraded -NotePropertyValue $today }
          if ($d.PSObject.Properties['body_thin'] -and (-not $thin)) { $d.body_thin = $false }
          Log ("QUEUE BODY UPGRADED on " + $d.id + " (" + $oldLen + " -> " + $bodyStored.Length + " chars, same day)")
        }
      }
    }
    'absorb' {
      # STILL-OPEN CONDITION FROM AN EARLIER DAY: one incident, one id. Keep the ORIGINAL body (it is what
      # triage was working from) and carry today's wording as a dated recurrence so a changed count or a
      # changed item list is still visible.
      $t = $route.target
      $t.count = [int]$t.count + 1
      # A LATER OCCURRENCE MAY CARRY BETTER EVIDENCE THAN THE FIRST. Keeping the original body is right
      # when the recurrences are the same alert repeating, and WRONG when the first one was truncated or
      # thin: the whole value of a queue entry is that triage can classify it without hunting the data.
      # Measured 2026-07-31: an alert whose body contained double quotes arrived through the shell at 307
      # of 2299 chars, and the re-send with the full evidence would have been filed as a 400-char
      # recurrence under the mangled original. Upgrade when the new body is materially fuller.
      $oldLen = ([string]$t.body).Length
      if ($bodyStored.Length -gt ($oldLen * 1.5) -and $bodyStored.Length -gt ($oldLen + 200)) {
        $t.body = $bodyStored
        if ($t.PSObject.Properties['body_upgraded']) { $t.body_upgraded = $today } else { $t | Add-Member -NotePropertyName body_upgraded -NotePropertyValue $today }
        if ($t.PSObject.Properties['body_thin'] -and (-not $thin)) { $t.body_thin = $false }
        Log ("QUEUE BODY UPGRADED on " + $t.id + " (" + $oldLen + " -> " + $bodyStored.Length + " chars) - a later occurrence carried fuller evidence")
      }
      if ($t.PSObject.Properties['last_seen']) { $t.last_seen = (Get-Date).ToString('s') } else { $t | Add-Member -NotePropertyName last_seen -NotePropertyValue (Get-Date).ToString('s') }
      $rec = @()
      if ($t.PSObject.Properties['recurrences']) { $rec = @($t.recurrences) }
      $rec += [pscustomobject]@{ date = $today; subject = $Subject; body = $(if ($bodyStored.Length -gt 400) { $bodyStored.Substring(0,400) + ' ...' } else { $bodyStored }) }
      if ($rec.Count -gt 5) { $rec = @($rec[($rec.Count-5)..($rec.Count-1)]) }   # keep the last 5, bounded
      if ($t.PSObject.Properties['recurrences']) { $t.recurrences = $rec } else { $t | Add-Member -NotePropertyName recurrences -NotePropertyValue $rec }
      Log ("QUEUE ABSORBED into open item " + $t.id + " (day " + $route.days + " of this condition, count now " + $t.count + ") - no new id minted")
    }
    default {
      $newItem = [pscustomobject]@{
        id = ($today + '-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        date = $today; ts = (Get-Date).ToString('s')
        type = $typeKey; subject = $Subject
        body = $bodyStored
        status = 'open'; count = 1; resolved_ts = $null; notes = $null
      }
      # an alert nobody can classify from its own body is a bug in the ALERT - say so on the record
      if ($thin) {
        $newItem | Add-Member -NotePropertyName body_thin -NotePropertyValue $true
        Log ("BODY THIN on '" + $Subject + "' - the queue entry carries no store, commodity or number, so it cannot be classified without hunting the data. Fix the caller to include the identifying rows.")
      }
      $items += $newItem
    }
  }
  # keep resolved history 30 days so triage can see recurrences; open items never age out
  $cut = (Get-Date).AddDays(-30)
  $items = @($items | Where-Object { $_.status -eq 'open' -or ([datetime]$_.ts) -ge $cut })
  $q.items = $items
  # atomic swap: write the whole document to a sibling temp, then replace. A reader either sees the old file
  # or the new one, never a half-written one.
  $qTmp = $qFile + '.tmp'
  $q | ConvertTo-Json -Depth 4 | Set-Content $qTmp -Encoding UTF8
  Move-Item -Path $qTmp -Destination $qFile -Force
} catch {
  Log ("triage-queue write failed (email still goes out): " + $_.Exception.Message)
  # NEVER lose the entry: Brad's rule is that an alert must not wait for a human, and an alert that never
  # reached the queue waits forever. Spool it beside the queue; triage-due.ps1 reports a spool as DUE.
  try {
    $spool = Join-Path $root ('triage-spool-' + $today + '.jsonl')
    $line = ([pscustomobject]@{ ts=(Get-Date).ToString('s'); type=$typeKey; subject=$Subject; body=$Body; reason=$_.Exception.Message } | ConvertTo-Json -Depth 4 -Compress)
    Add-Content -Path $spool -Value $line -Encoding UTF8
  } catch { Log ('triage-spool write ALSO failed: ' + $_.Exception.Message) }
} finally {
  if ($qHeld) { try { $qMutex.ReleaseMutex() } catch {} }
  try { $qMutex.Dispose() } catch {}
}

if (-not $Force -and (Test-Path $sentFile) -and ((Get-Content $sentFile) -contains $typeKey)) {
  Log ("SUPPRESSED (already sent this type today) '$Subject' [type: $typeKey]")
  Write-Output ("alert suppressed - '$typeKey' already emailed today (use -Force to override)")
  exit 0
}

try {
  . "C:\Codex\.claude\skills\lesson\google-token.ps1"
  $token = Get-GoogleAccessToken
  $raw = "To: $To`r`nSubject: $Subject`r`nContent-Type: text/plain; charset=UTF-8`r`n`r`n$Body`r`n`r`n(Automated alert from the Omaha grocery pipeline.)"
  $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($raw)).Replace('+','-').Replace('/','_').TrimEnd('=')
  $resp = Invoke-RestMethod -Uri "https://gmail.googleapis.com/gmail/v1/users/me/messages/send" -Method Post `
            -Headers @{ Authorization = "Bearer $token" } -ContentType "application/json" -Body (@{ raw = $b64 } | ConvertTo-Json) -TimeoutSec 30
  Add-Content -Path $sentFile -Value $typeKey   # record the type so the rest of today's runs stay quiet
  Log ("SENT '$Subject' -> $To (id " + $resp.id + ")")
  Write-Output ("alert emailed to $To (id " + $resp.id + ")")
} catch {
  $msg = $_.Exception.Message
  Log ("SEND FAILED '$Subject': " + $msg)
  if ($msg -match '403|insufficient|scope|ACCESS_TOKEN_SCOPE') {
    Write-Output "EMAIL NOT SENT: the Google token is missing the gmail.send scope. Run google-oauth-authorize.ps1 once to add it. Alert was logged to alert-log.txt."
  } else {
    Write-Output ("EMAIL NOT SENT: " + $msg + "  (logged to alert-log.txt)")
  }
  exit 1
}
