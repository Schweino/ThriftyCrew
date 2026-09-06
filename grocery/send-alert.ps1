<#
  send-alert.ps1 - Emails a grocery-pipeline failure alert to Brad (schweino68@gmail.com) via the Gmail API,
  reusing the Work Google OAuth token. Only call this on a HARD failure (a pull that failed AFTER a retry),
  never on a temporary hiccup like "a store's new ad isn't posted yet."

  Requires the shared Google token to include the gmail.send scope. If it doesn't yet, this logs the failure
  and exits 1 (so the caller can fall back) - run google-oauth-authorize.ps1 once to add the scope.

  Usage: DON'T CALL THIS DIRECTLY. Dot-source alert-lib.ps1 and use Send-Alert:
      . (Join-Path $root 'alert-lib.ps1')
      Send-Alert -Subject "Grocery pull failed: Baker's" -Body $details | Out-Null
  It routes the body through -BodyFile (a `powershell -File ... -Body $long` command line over 32767 chars
  does not start AT ALL, so the alert simply never happens) and makes a failed send a loud log line rather
  than a swallowed exception. The whole account of the four-day silent outage is in alert-lib.ps1.
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
  # WHICH SCRIPT DECIDED TO PAGE (2026-09-05, queue 2026-09-04-bf1642). Passed by alert-lib.ps1's Send-Alert
  # from its own call stack; stamped on a NEW queue item as `emitter` so triage-due.ps1 can ask git whether
  # the emitting code changed after the alert fired. Absent is fine and always has been: an alert that
  # cannot name its emitter is still an alert, and nothing downstream may require this field.
  [string]$Emitter = "",
  # exercises the queue-routing decision against temp fixtures and exits. Sends nothing, touches no live file.
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$logFile = Join-Path $root 'alert-log.txt'
if ($BodyFile) {
  if (-not (Test-Path $BodyFile)) { throw "send-alert: -BodyFile not found: $BodyFile" }
  # -Encoding utf8 (2026-09-06, worklist C5). PS 5.1's Get-Content decodes a file with NO byte-order
  # mark using the system ANSI codepage, not UTF-8, and every writer that emits BOM-less UTF-8 - Python's
  # json.dump, .NET's UTF8Encoding($false) - produces exactly that. So an alert body naming a real
  # product came in mangled: "Hurst's Hambeens(R) 15 Bean Soup Mix" arrived with the registered sign
  # doubled. lib\json-io.ps1's header documents the mechanism in full; this file never dot-sourced it.
  $Body = ((Get-Content $BodyFile -Raw -Encoding UTF8) + '')   # ((...) + '') because [string]$null is $null in PS 5.1
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
# ---- THE EMITTER, AS A REPO-RELATIVE PATH (2026-09-05, queue 2026-09-04-bf1642) -------------------------
# triage-due.ps1 asks `git log -1 -- <emitter>`, so the stamp has to be something git can resolve: a path
# relative to the repo root, forward slashes, exactly the shape git ls-files prints. An ABSOLUTE path would
# work on this machine and nowhere else, and a path outside the repo has no repo-relative form at all - for
# those the answer is the empty string, because inventing a path git cannot find would turn "I do not know"
# into a silent "nothing changed", which is the same lie by a different route.
function ConvertTo-RepoRelative([string]$Path, [string]$RepoRoot) {
  if (-not $Path -or -not $RepoRoot) { return '' }
  try {
    $full = [IO.Path]::GetFullPath($Path)
    $rr = [IO.Path]::GetFullPath($RepoRoot).TrimEnd('\', '/') + '\'
    if ($full.StartsWith($rr, [StringComparison]::OrdinalIgnoreCase)) { return ($full.Substring($rr.Length) -replace '\\', '/') }
  } catch { }
  return ''
}

function Test-BodyThin([string]$Body) {
  $b = [string]$Body
  if ($b.Trim().Length -lt 120) { return $true }
  $hasStore = $b -imatch "hy-vee|baker|family fare|fareway|aldi|walmart|sam's|sams"
  $hasId    = $b -match '[a-z]{3,}(-[a-z0-9]{2,}){1,}'      # commodity-id shape, e.g. canned-mushrooms
  $hasNum   = $b -match '\d'
  if ($hasStore -or $hasId) { return $false }
  return (-not $hasNum)
}

# ---- MUTE SWITCH (2026-08-14, Brad: "stop all email alerts") --------------------------------------------
# Silences the INBOX, not the response system. The triage-queue write above still happens on every alert, so
# grocery-alert-triage keeps draining and fixing exactly as before - the only thing that stops is the mail.
# That ordering matters: the queue block runs BEFORE this gate on purpose, and moving this check earlier
# would turn "stop emailing me" into "stop responding to failures", which is the opposite of Brad's standing
# rule that an issue email must never wait for a human.
#
# THE RULE ITSELF LIVES IN mute-lib.ps1 and is shared with triage-due.ps1, which prints the banner. Keeping
# a second copy here is what let the banner and the mailer disagree; see the header of that file.
. (Join-Path $PSScriptRoot 'mute-lib.ps1')

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
  # ---- THE EMITTER STAMP (2026-09-05, queue 2026-09-04-bf1642) ----
  # triage-due.ps1 hands this string straight to `git log -- <path>`, so the only useful shape is repo-relative
  # with forward slashes. Synthetic roots, so the case tests the transform and not this machine's layout.
  _T 'an emitter inside the repo becomes a git-resolvable repo-relative path' (ConvertTo-RepoRelative 'C:\repo\grocery\harvest-crawl.ps1' 'C:\repo') 'grocery/harvest-crawl.ps1'
  _T 'a trailing separator on the root does not eat the first path segment'   (ConvertTo-RepoRelative 'C:\repo\grocery\harvest-crawl.ps1' 'C:\repo\') 'grocery/harvest-crawl.ps1'
  # A caller outside the repo (a scheduled-task script) has NO repo-relative path. Stamping a made-up one
  # would make git answer "no commits" forever, which reads as "the emitter never changed" - a silent wrong
  # answer dressed as a clean one. Empty is the honest stamp, and the field is simply omitted.
  _T 'an emitter OUTSIDE the repo stamps nothing rather than a path git cannot find' (ConvertTo-RepoRelative 'C:\Users\Owner\.claude\scheduled-tasks\x\run.ps1' 'C:\repo') ''
  _T 'no emitter at all stamps nothing'                                              (ConvertTo-RepoRelative '' 'C:\repo') ''
  # ---- mute switch, against real temp files (no live path touched) ----
  $mDir = Join-Path $env:TEMP ('smp-mute-selftest-' + [guid]::NewGuid().ToString('N').Substring(0,8))
  New-Item -ItemType Directory -Path $mDir -Force | Out-Null
  try {
    $mF = Join-Path $mDir 'alerts-muted.json'
    # CLEAN TWIN: no file = mail flows, which is the state this estate ran in for its whole life before today
    _T 'no mute file -> not muted' (Get-MuteState $mF '2026-08-14').muted 'False'
    # MUST-FIRE: the founding case - Brad asked for silence on 2026-08-14 and the file says so
    '{ "muted": true, "since": "2026-08-14", "until": null }' | Set-Content $mF -Encoding UTF8
    _T 'mute file with no expiry -> muted' (Get-MuteState $mF '2026-08-14').muted 'True'
    '{ "muted": false, "since": "2026-08-14" }' | Set-Content $mF -Encoding UTF8
    _T 'muted=false -> not muted (in-place off switch)' (Get-MuteState $mF '2026-08-14').muted 'False'
    '{ "muted": true, "until": "2026-08-20" }' | Set-Content $mF -Encoding UTF8
    _T 'until in the future -> still muted' (Get-MuteState $mF '2026-08-14').muted 'True'
    '{ "muted": true, "until": "2026-08-13" }' | Set-Content $mF -Encoding UTF8
    _T 'until in the past -> mute expired, mail resumes' (Get-MuteState $mF '2026-08-14').muted 'False'
    # a garbled instruction to be quiet is still an instruction to be quiet
    'not json at all' | Set-Content $mF -Encoding UTF8
    _T 'unparseable mute file -> muted (fails quiet, not loud)' (Get-MuteState $mF '2026-08-14').muted 'True'
    # ...but an unreadable EXPIRY must not become a permanent mute
    '{ "muted": true, "until": "whenever" }' | Set-Content $mF -Encoding UTF8
    _T 'unparseable until -> mute EXPIRES rather than lasting forever' (Get-MuteState $mF '2026-08-14').muted 'False'
  } finally { Remove-Item $mDir -Recurse -Force -ErrorAction SilentlyContinue }
  Write-Output ""
  if ($fail -gt 0) { Write-Output "SELF-TEST FAIL: $fail case(s)"; exit 1 }
  Write-Output 'SELF-TEST PASS (queue routing + body-thin + emitter path + mute switch)'
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
  # THIS ONE IS THE GENERATIONAL HALF AND IT IS THE WORSE OF THE TWO. This read feeds a
  # read-modify-WRITE of the whole queue, so without -Encoding utf8 every alert appended re-decoded and
  # re-encoded every entry already in the file - one more generation of damage per alert, to rows that
  # had nothing to do with the new one. The estate has measured this shape before: commodities.json once
  # carried 61,542 mojibake characters eight to ten generations deep.
  $qRaw = if (Test-Path $qFile) { Get-Content $qFile -Raw -Encoding UTF8 } else { $null }
  $q = $null
  if ($qRaw -and $qRaw.Trim()) { $q = $qRaw | ConvertFrom-Json }
  # An empty/blank/garbled read is NOT "no queue yet" - overwriting on that assumption is how the whole
  # backlog would disappear. Only build a fresh queue when the file genuinely does not exist.
  if (-not $q) {
    if (Test-Path $qFile) { throw ('triage-queue.json exists but read back empty/unparseable - refusing to overwrite ' + @(Get-Content $qFile -Raw -Encoding UTF8).Length + ' bytes') }
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
      # WHICH CODE SAID SO (2026-09-05, queue 2026-09-04-bf1642). Stamped on NEW items only: an absorbed
      # recurrence belongs to the incident the first occurrence opened, and re-stamping it would overwrite
      # the provenance of the alert triage is actually working. -Emitter comes from alert-lib's call stack;
      # the fallback below covers the in-process callers that invoke this script directly (notify-desktop.ps1
      # does `& send-alert.ps1`), where the stack still holds the caller. Under `powershell -File` with no
      # -Emitter there is no caller frame at all, and then nothing is stamped - which is correct and must
      # stay harmless: every item written before today has no emitter and must keep reading fine forever.
      $emitterRel = ''
      try {
        $emSrc = $Emitter
        if (-not $emSrc) {
          $f = @(Get-PSCallStack | Where-Object { $_.ScriptName -and ($_.ScriptName -ne $PSCommandPath) })
          if ($f.Count) { $emSrc = [string]$f[0].ScriptName }
        }
        $emitterRel = ConvertTo-RepoRelative $emSrc (Split-Path -Parent $root)
      } catch { $emitterRel = '' }
      if ($emitterRel) { $newItem | Add-Member -NotePropertyName emitter -NotePropertyValue $emitterRel }
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

# MUTED? The queue entry is already durable at this point, so triage still sees and works this alert; we
# just do not mail it. -Force does NOT punch through: -Force exists to beat the once-a-day gate for a new
# incident, and "stop all email alerts" outranks "this one is urgent enough to repeat today".
$mute = Get-MuteState (Join-Path $root 'alerts-muted.json') $today
if ($mute.muted) {
  Log ("MUTED (" + $mute.why + ") - queued but NOT emailed: '$Subject' [type: $typeKey]")
  Write-Output ("alert MUTED (" + $mute.why + ") - queued to triage-queue.json, no email sent. Delete grocery\alerts-muted.json to resume email.")
  exit 0
}

# ---- THE ONCE-PER-TYPE-PER-DAY GATE IS A CHECK-THEN-ACT RACE, AND NOW IT IS NOT (2026-08-23) ----
# Read the sent-file, decide, send over the network, THEN append the type. Two send-alert.ps1
# processes hitting that window together both read a file without their type in it and both
# email; and the append itself can lose a line, after which the rest of the day re-pages a type
# that was already delivered. Until today the window was narrow because the daily chain called
# every alert serially from one script. fanout-lib.ps1 ends that assumption: several advisory
# audits now run side by side and three of them (match-soundness, store-registry,
# category-coverage) page on their OWN behalf, as grandchildren, so the parent cannot serialise
# them by holding anything. A cross-process lock is the only place the fix can live.
#
# Named exactly like the triage-queue mutex twenty lines up, which fixed the same shape on the
# same file for the same reason on 2026-07-28 - that precedent is why this is a mutex and not,
# say, a lock file with a retry loop.
#
# A LOCK MUST NEVER SWALLOW AN ALERT. If the wait expires we send ANYWAY and say so: a duplicate
# email is an annoyance, a suppressed one is a watcher gone quiet, and this estate has already
# paid for the second kind. 90 s covers the 30 s Gmail timeout with room for a retry behind it.
$sMutex = New-Object System.Threading.Mutex($false, 'Global\smp-grocery-alert-sent')
$sHeld = $false
try { $sHeld = $sMutex.WaitOne(90000) } catch [System.Threading.AbandonedMutexException] { $sHeld = $true }
if (-not $sHeld) { Log ("alert-sent lock not acquired in 90 s - sending anyway rather than risking a suppressed alert [type: $typeKey]") }
try {

if (-not $Force -and (Test-Path $sentFile) -and ((Get-Content $sentFile -Encoding UTF8) -contains $typeKey)) {
  Log ("SUPPRESSED (already sent this type today) '$Subject' [type: $typeKey]")
  Write-Output ("alert suppressed - '$typeKey' already emailed today (use -Force to override)")
  exit 0
}

try {
  # Repo-relative, not absolute. Until 2026-08-15 this dot-sourced C:\Codex\.claude\... - a path OUTSIDE
  # the repo - so a fresh clone could not send a single alert. That is the same hole lib\ had, sitting on
  # the one script whose job is to report every other hole. $PSScriptRoot is grocery\, so the repo root is
  # its parent.
  . (Join-Path (Split-Path -Parent $PSScriptRoot) '.claude\skills\lesson\google-token.ps1')
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

} finally {
  # Runs on every path out of the block above, `exit` included: PowerShell's exit unwinds
  # through finally. Even if it did not, a process death releases the mutex as ABANDONED and
  # the next waiter catches AbandonedMutexException above and treats it as acquired - so a
  # crashed alert can never wedge every later alert in the estate.
  if ($sHeld) { try { $sMutex.ReleaseMutex() } catch { } }
  try { $sMutex.Dispose() } catch { }
}
