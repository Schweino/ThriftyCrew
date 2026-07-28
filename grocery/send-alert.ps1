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
  [string]$To = "schweino68@gmail.com",
  # bypass the once-per-type-per-day gate for a genuinely new incident that must page through today. Callers
  # that already do their own signature de-dup (the consistency-drift alert) pass this so their finer-grained
  # logic wins; everything else takes the daily gate.
  [switch]$Force
)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$logFile = Join-Path $root 'alert-log.txt'
function Log($m) { Add-Content -Path $logFile -Value (("[" + (Get-Date).ToString('s') + "] ") + $m) }

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
  $dupe = $items | Where-Object { $_.type -eq $typeKey -and $_.date -eq $today }
  if ($dupe) {
    foreach ($d in $dupe) { $d.count = [int]$d.count + 1 }
  } else {
    $items += [pscustomobject]@{
      id = ($today + '-' + [guid]::NewGuid().ToString('N').Substring(0,6))
      date = $today; ts = (Get-Date).ToString('s')
      type = $typeKey; subject = $Subject
      body = $(if ($Body.Length -gt 1500) { $Body.Substring(0,1500) + ' ...[truncated - full context in ad-cycle-log.txt / the source audit json]' } else { $Body })
      status = 'open'; count = 1; resolved_ts = $null; notes = $null
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
