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
  # AN ESCALATION IS BORN PARKED (2026-09-07, queue 2026-09-07-285b1f). Every alert written here is minted
  # with status 'open', because that is the only status this script could ever give an item - and
  # triage-close.ps1's disposition vocabulary (confirmed|false-alarm|superseded|by-design|wont-fix) has no
  # park either, so needs-brad is a hand edit. The consequence measured on 2026-09-07: round 1's triage
  # emailed Brad a genuine judgment call, parked the original item at needs-brad by hand, and the
  # ESCALATION EMAIL ITSELF landed back in the queue as a fresh open item at 12:31 - so triage-due listed
  # new work whose entire content was "we already asked Brad about this". One parked question, two items,
  # and one of them re-triaged the next morning. Every escalation would cost that, forever.
  # Pass -Escalates <queue-id> and the new item is written status needs-brad, noting which item owns the
  # question. The mail still goes out unchanged, the once-a-day gate and -Force are untouched, and
  # triage-due (which lists only status open, and counts needs-brad as parked) stops reporting it as work.
  [string]$Escalates = "",
  # A TRIAGE-CREATED ITEM IS BORN IN THE WEEKLY LANE (2026-09-10, Brad, after a 1.35M-token triage day).
  # Pass -Lane weekly when a triage run files a residual or a finding about a class. The item is stamped
  # lane 'weekly', triage-due.ps1 still lists it every day, and it makes the run DUE only when the weekly
  # lane is. The default writes no field at all, so no other alert in the estate changes.
  [ValidateSet('daily', 'weekly')][string]$Lane = 'daily',
  # ONE INCIDENT, ONE ALERT (2026-09-10, design\PLAN-zero-alert-days-2026-09-10.md Phase 1). An alert that is a
  # CONSEQUENCE of an open incident passes that incident's key and is absorbed as a recurrence of the incident's
  # open queue item: no new id, no mail. The only key so far is 'guards-hold': today's chain verdict says guards
  # blocked AND an open GUARDS FAILED item exists. When either is false, the key is unknown or the verdict cannot
  # be read, the alert goes out exactly as if -CausedBy had not been passed. An alert is never dropped because its
  # incident could not be found.
  [string]$CausedBy = '',
  # THE QUEUE LOCK, AS FIXTURE SEAMS (2026-09-11). Every live caller takes both defaults, and the name must stay the
  # one grocery\triage-close.ps1 takes around its own rewrite of the queue. -SelfTest passes a fresh fixture name, so
  # a lock it holds on purpose never makes a real alert on this box wait, and a short timeout, so the timed-out
  # branch is reached without a 10 s pause per case.
  [string]$QueueMutexName = 'Global\smp-grocery-triage-queue',
  [int]$QueueLockTimeoutMs = 10000,
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
# One function (2026-09-10) so -SelfTest can assert that grocery\alert-registry-lib.ps1's Get-AlertTypeKey derives
# the SAME key: the registry is keyed on it, and a lib that drifted would let the registry check read green over
# keys this mailer never makes. It stays here as well as in the lib so an alert still gets a key, a queue item and
# a mail on a day the lib cannot load.
function ConvertTo-AlertTypeKey([string]$s) {
  return (([string]$s).ToLower() `
      -replace '\d{4}-\d{2}-\d{2}', '' `
      -replace 'rc\s*=\s*\d+', '' `
      -replace '\d+(\.\d+)?', '' `
      -replace '[^a-z]+', ' ').Trim()
}
$typeKey = ConvertTo-AlertTypeKey $Subject

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

# ---- WHAT STATUS IS A NEW ITEM BORN WITH? (2026-09-07, queue 2026-09-07-285b1f) -------------------------
# One function, so the rule is testable rather than an inline conditional nothing can reach. Until today
# there was exactly one answer - 'open' - and that is the whole defect: an escalation email is not work
# waiting to be done, it is a record that a question was handed to Brad, and the item that OWNS the
# question is already parked at needs-brad. Minting a second open item for it guarantees that every
# parked question generates fresh triage work the following morning, which is this estate's own "an alert
# with no repair lane" shape pointed at its own escalation lane.
# Get-QueueAction is deliberately NOT changed: a needs-brad item never absorbs (line above), so two
# escalations for the same id mint two parked items. That is bounded, manual and visible in triage-due's
# parked count, and making needs-brad absorb would let a parked item swallow unrelated recurrences.
function Get-BirthDisposition([string]$Escalates) {
  if ($Escalates) {
    return [pscustomobject]@{
      status = 'needs-brad'
      notes  = ('escalation email for ' + $Escalates + ' (parked there; do not re-triage this item - the question, its evidence and its ruling live on ' + $Escalates + ')')
    }
  }
  return [pscustomobject]@{ status = 'open'; notes = $null }
}

# ---- A TRIAGE-CREATED ITEM IS BORN IN THE WEEKLY LANE (2026-09-10) ----------------------------------------
# The lane an item is born with. 'weekly' is stamped; 'daily' (the default) and anything else stamp NOTHING,
# so every other alert in the estate writes a byte-identical queue item to the one it wrote before this.
# triage-due.ps1 reads the field; the account of why the lane exists is there.
function Get-BirthLane([string]$Lane) {
  if ($Lane -eq 'weekly') { return 'weekly' }
  return $null
}

# ---- IS THIS ALERT A CONSEQUENCE OF AN OPEN INCIDENT? (2026-09-10, plan Phase 1) ---------------------------------
# Pure, so -SelfTest drives it with frozen verdicts. On 2026-09-10 one guard hold produced four queue items: GUARDS
# FAILED, then the capture watchdog, board prices aging and the feed edge, each describing the same held board from
# its own end. Returns the item to absorb into, or $null with the reason - and $null means "send normally".
function Get-IncidentAbsorbTarget {
  param($Items, [string]$CausedBy, $Verdict, [string]$Today)
  $r = [pscustomobject]@{ target = $null; why = '' }
  if (-not $CausedBy) { $r.why = 'no -CausedBy'; return $r }
  if ($CausedBy -ne 'guards-hold') { $r.why = ("unknown incident key '" + $CausedBy + "'"); return $r }
  if ($null -eq $Verdict) { $r.why = 'no chain verdict could be read'; return $r }
  if ([string]$Verdict.date -ne $Today) { $r.why = ('the chain verdict is for ' + [string]$Verdict.date + ', not today'); return $r }
  if (-not [bool]$Verdict.guards_blocked) { $r.why = 'guards are not blocked today'; return $r }
  $best = $null
  foreach ($i in @($Items)) {
    if (-not $i) { continue }
    if ([string]$i.status -ne 'open') { continue }
    if (-not ([string]$i.type).StartsWith('grocery guards failed', [StringComparison]::Ordinal)) { continue }
    if ($null -eq $best -or [string]$i.ts -gt [string]$best.ts) { $best = $i }
  }
  if ($null -eq $best) { $r.why = 'no open GUARDS FAILED item'; return $r }
  $r.target = $best
  $r.why = 'absorbed'
  return $r
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
  # ---- AN ESCALATION IS BORN PARKED (2026-09-07, queue 2026-09-07-285b1f) ----
  # MUST FIRE, frozen from the day it cost: at 12:31:33 round 1 sent "Your call: the memory store's
  # private backup remote..." for item 2026-09-07-4f672e, which was already parked at needs-brad by hand.
  # send-alert could only mint 'open', so the escalation re-entered the queue as fresh triage work and
  # 4f672e's own question now had two items. With -Escalates the new item is parked and names its owner.
  $esc = Get-BirthDisposition '2026-09-07-4f672e'
  _T 'an escalation email is born needs-brad, not open' $esc.status 'needs-brad'
  _T 'and its notes name the item that owns the question' ([bool]([string]$esc.notes -like '*2026-09-07-4f672e*')) 'True'
  _T 'and the notes tell the next reader not to re-triage it' ([bool]([string]$esc.notes -like '*do not re-triage*')) 'True'
  # MUST NOT FIRE: an ordinary alert is unchanged. This is the whole estate's alerting path, and a park
  # that leaked onto normal alerts would silently stop triage from ever seeing a real failure again.
  $plain = Get-BirthDisposition ''
  _T 'an ordinary alert is still born open' $plain.status 'open'
  _T 'and carries no notes' ([bool]($null -eq $plain.notes)) 'True'
  # CLEAN TWIN: routing is untouched by any of this - a needs-brad item still does NOT absorb, so a second
  # escalation for the same id mints a second parked item rather than reopening the parked one.
  _T 'CLEAN TWIN routing is unchanged: needs-brad still does not absorb' (Get-QueueAction $items4 't' '2026-07-31').action 'new'
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
  # ---- A TRIAGE-CREATED ITEM IS BORN IN THE WEEKLY LANE (2026-09-10) ----
  # MUST FIRE: a residual filed with -Lane weekly carries the lane triage-due.ps1 reads.
  _T 'a -Lane weekly alert is born in the weekly lane' (Get-BirthLane 'weekly') 'weekly'
  # MUST NOT FIRE: an ordinary alert, and one that names the default, carry no lane field at all.
  _T 'an ordinary alert with no -Lane carries no lane' ([bool]($null -eq (Get-BirthLane ''))) 'True'
  _T 'an alert passing -Lane daily carries no lane' ([bool]($null -eq (Get-BirthLane 'daily'))) 'True'
  # CLEAN TWIN: the escalation park beside it still parks.
  _T 'CLEAN TWIN an escalation is still born needs-brad beside the lane stamp' (Get-BirthDisposition '2026-09-07-4f672e').status 'needs-brad'
  # ---- THE ALERT REGISTRY (2026-09-10, Brad ruling 1) ----
  # The lib's key derivation must be this script's, or audit-alert-registry reads green over keys the mailer never makes.
  . (Join-Path $PSScriptRoot 'alert-registry-lib.ps1')
  foreach ($ks in @('Grocery: GUARDS FAILED - board not published - 2026-09-10', 'Grocery publish FAILED (rc=2) - 2026-09-10', "smp-feed edge did not pick up today's push - 2026-09-10", 'Grocery: 7 NEW price flag(s) - 2026-09-10')) {
    _T ('the registry lib derives the same type key as this script for: ' + $ks) (Get-AlertTypeKey $ks) (ConvertTo-AlertTypeKey $ks)
  }
  # END TO END, out of process, in a temp tree: the REAL send-alert.ps1 against a frozen registry and a frozen queue.
  # The mute file is ON, so no case can reach Gmail. Reaching the MUTED branch is the proof the mail leg was taken,
  # and it prints the subject the mail would have carried.
  $saDir = Join-Path $env:TEMP ('smp-sa-registry-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  $saG = Join-Path $saDir 'grocery'
  $saL = Join-Path $saDir 'lib'
  New-Item -ItemType Directory -Force -Path $saG, $saL, (Join-Path $saG 'out') | Out-Null
  $utf8 = New-Object Text.UTF8Encoding($false)
  try {
    Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $saG 'send-alert.ps1')
    foreach ($n in @('alert-registry-lib.ps1', 'mute-lib.ps1')) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $n) -Destination (Join-Path $saG $n) }
    foreach ($n in @('json-io.ps1', 'chain-verdict-lib.ps1', 'atomic-write.ps1', 'append-line.ps1')) { Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) ('lib\' + $n)) -Destination (Join-Path $saL $n) }
    $saReg = Join-Path $saG 'alert-registry.json'
    $saRegJson = '{ "readme": "frozen fixture", "entries": [' +
      '{ "id": "held", "match": "exact", "key": "grocery page held coverage", "class": "page", "condition": "1 board-or-feed-wrong-or-held", "emitter": "x" },' +
      '{ "id": "soundness", "match": "exact", "key": "grocery matching soundness review needed", "class": "review", "condition": "review intake", "emitter": "x" },' +
      '{ "id": "digest", "match": "exact", "key": "brain digest the night", "class": "digest", "condition": "information", "emitter": "x" } ] }'
    [IO.File]::WriteAllText($saReg, $saRegJson, $utf8)
    [IO.File]::WriteAllText((Join-Path $saG 'alerts-muted.json'), '{ "muted": true, "since": "2026-09-10", "until": null }', $utf8)
    $saQ = Join-Path $saG 'triage-queue.json'
    $saBody = Join-Path $saDir 'body.txt'
    [IO.File]::WriteAllText($saBody, 'Frozen fixture body: Hy-Vee canned-mushrooms, 3 rows, enough store and number evidence that the body is not thin.', $utf8)
    # A FIXTURE QUEUE LOCK, never the live one: every case below runs the real script, and the lock case holds this
    # name on purpose, which must not make a real alert on this box wait.
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\mutex-hold.ps1')
    $saMutex = New-TcFixtureMutexName 'smp-sa-selftest-queue'
    function _SA([string]$subj, [string[]]$extra = @()) {
      $o = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $saG 'send-alert.ps1') -Subject $subj -BodyFile $saBody -QueueMutexName $saMutex @extra
      $rc = $LASTEXITCODE
      $its = @()
      if (Test-Path -LiteralPath $saQ) { $qd = Get-Content -LiteralPath $saQ -Raw -Encoding UTF8 | ConvertFrom-Json; $its = @($qd.items) }
      return [pscustomobject]@{ out = ((@($o) | ForEach-Object { [string]$_ }) -join ' | '); rc = $rc; items = $its }
    }
    # CLEAN TWIN: a registered page-class alert behaves exactly as before - one queue item, the mail leg, its own subject.
    $c1 = _SA 'Grocery page HELD (coverage) - 2026-09-10'
    _T 'CLEAN TWIN a registered page alert still queues one item AND takes the mail leg under its own subject' ([bool]($c1.items.Count -eq 1 -and $c1.out -match 'alert MUTED' -and $c1.out -match [regex]::Escape("mail subject 'Grocery page HELD (coverage) - 2026-09-10'"))) 'True'
    _T 'MUST NOT FIRE and a registered page alert carries no unregistered stamp' ([bool]($c1.items.Count -eq 1 -and -not $c1.items[0].PSObject.Properties['unregistered'])) 'True'
    # MUST FIRE: an unregistered subject is never dropped - it queues, stamped, AND mails with the marker.
    Remove-Item -LiteralPath $saQ -Force -ErrorAction SilentlyContinue
    $c2 = _SA 'Grocery: a type nobody registered - 2026-09-10'
    _T 'MUST FIRE an unregistered subject is queued with unregistered=true' ([bool]($c2.items.Count -eq 1 -and $c2.items[0].unregistered -eq $true)) 'True'
    _T 'MUST FIRE and it takes the mail leg with UNREGISTERED ALERT TYPE on its subject' ([bool]($c2.out -match 'alert MUTED' -and $c2.out -match [regex]::Escape("mail subject 'UNREGISTERED ALERT TYPE: Grocery: a type nobody registered - 2026-09-10'"))) 'True'
    # MUST NOT FIRE: a review-class subject sends no mail, but still queues.
    Remove-Item -LiteralPath $saQ -Force -ErrorAction SilentlyContinue
    $c3 = _SA 'Grocery matching soundness - review needed'
    _T 'MUST NOT FIRE a review-class alert never reaches the mail leg' ([bool]($c3.out -notmatch 'alert MUTED' -and $c3.out -match 'queued as REVIEW')) 'True'
    _T 'and it still queues its one item' $c3.items.Count 1
    # MUST NOT FIRE: a digest-class subject writes no queue item, but still mails.
    Remove-Item -LiteralPath $saQ -Force -ErrorAction SilentlyContinue
    $c4 = _SA 'Brain digest: the night'
    _T 'MUST NOT FIRE a digest-class alert writes no queue item' ([bool](-not (Test-Path -LiteralPath $saQ))) 'True'
    _T 'and it still takes the mail leg' ([bool]($c4.out -match 'alert MUTED')) 'True'
    # MUST FIRE: no registry at all fails toward PAGE - the review-class subject from above is now queued AND mailed.
    Remove-Item -LiteralPath $saQ -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $saReg -Force
    $c5 = _SA 'Grocery matching soundness - review needed'
    $saLog = Join-Path $saG 'alert-log.txt'
    _T 'MUST FIRE with the registry missing, a review-class subject fails toward page: queued AND mailed' ([bool]($c5.items.Count -eq 1 -and $c5.out -match 'alert MUTED')) 'True'
    _T 'and the log says the registry could not be read' ([bool]((Test-Path -LiteralPath $saLog) -and ((Get-Content -LiteralPath $saLog -Raw) -match 'ALERT REGISTRY UNREADABLE'))) 'True'
    [IO.File]::WriteAllText($saReg, $saRegJson, $utf8)
    # CLEAN TWIN: -Lane and -Escalates keep working - the lane is still stamped, and the park is still written.
    Remove-Item -LiteralPath $saQ -Force -ErrorAction SilentlyContinue
    $c6 = _SA 'Triage residual: a frozen residual' @('-Lane', 'weekly')
    _T 'CLEAN TWIN -Lane weekly still stamps its lane and lands as review (queued, not mailed)' ([bool]($c6.items.Count -eq 1 -and $c6.items[0].lane -eq 'weekly' -and $c6.out -match 'queued as REVIEW')) 'True'
    Remove-Item -LiteralPath $saQ -Force -ErrorAction SilentlyContinue
    $c7 = _SA 'Grocery matching soundness - review needed' @('-Escalates', '2026-09-10-abcdef')
    _T 'CLEAN TWIN -Escalates still parks the item at needs-brad and always takes the mail leg' ([bool]($c7.items.Count -eq 1 -and $c7.items[0].status -eq 'needs-brad' -and $c7.out -match 'alert MUTED')) 'True'
    # ---- ONE INCIDENT, ONE ALERT (2026-09-10, plan Phase 1) ----
    $tdy = Get-Date -Format 'yyyy-MM-dd'
    $saRegInc = '{ "readme": "frozen fixture", "entries": [' +
      '{ "id": "guards-failed", "match": "exact", "key": "grocery guards failed board not published", "class": "page", "condition": "1 board-or-feed-wrong-or-held", "emitter": "x" },' +
      '{ "id": "watchdog", "match": "exact", "key": "grocery capture watchdog issue s", "class": "page", "condition": "3 scheduled-work-did-not-run-or-land", "emitter": "x" },' +
      '{ "id": "watchdog-held", "match": "exact", "key": "grocery capture watchdog held by guards", "class": "page", "condition": "1 board-or-feed-wrong-or-held", "emitter": "x" },' +
      '{ "id": "aging", "match": "exact", "key": "board prices aging inside a fresh file", "class": "page", "condition": "1 board-or-feed-wrong-or-held", "emitter": "x" },' +
      '{ "id": "feed-edge", "match": "exact", "key": "smp feed edge did not pick up today s push", "class": "page", "condition": "1 board-or-feed-wrong-or-held", "emitter": "x" } ] }'
    [IO.File]::WriteAllText($saReg, $saRegInc, $utf8)
    $saVerdict = Join-Path $saG 'out\chain-verdict.json'
    $gfId = $tdy + '-gf0001'
    $gfQueue = '{ "readme": "frozen fixture", "items": [ { "id": "' + $gfId + '", "date": "' + $tdy + '", "ts": "' + $tdy + 'T08:15:00", "type": "grocery guards failed board not published", "subject": "Grocery: GUARDS FAILED - board not published - ' + $tdy + '", "body": "guards.ps1 hard fail: Ranch dressing at Sam''s priced from a list-price quotient size.", "status": "open", "count": 1, "resolved_ts": null, "notes": null } ] }'
    function _Verdict([bool]$blocked) {
      $rcTxt = '0'; $blTxt = 'false'
      if ($blocked) { $rcTxt = '2'; $blTxt = 'true' }
      [IO.File]::WriteAllText($saVerdict, ('{ "date": "' + $tdy + '", "written": "' + $tdy + 'T08:14:24", "written_by": "fixture", "guards_rc": ' + $rcTxt + ', "guards_blocked": ' + $blTxt + ' }'), $utf8)
    }
    # MUST FIRE, the 2026-09-10 morning replayed: guards blocked, GUARDS FAILED open, then the watchdog's four hold
    # lines and the two other consequence emitters. Four queue items that morning; one now.
    _Verdict $true
    [IO.File]::WriteAllText($saQ, $gfQueue, $utf8)
    [IO.File]::WriteAllText($saBody, ("HELD BY GUARDS: check-ad-cycles refused the 08:14 board (guards_rc 2).`n" +
      " . RUN RECORD: capture-run [daily] completed with exit 1`n" +
      " . NOT PUBLISHED: public\board.json is 1213 min older than today's comparison.`n" +
      " . FAILED: 'TC Grocery Daily Capture 0800' last run exited 1, and no board has been rebuilt and published since.`n" +
      " . COMPUTED BUT NOT SHIPPED: public/smp-feed.json is modified in the working tree after today's run."), $utf8)
    $i1 = _SA ('Grocery capture watchdog: held by guards ' + $tdy) @('-CausedBy', 'guards-hold')
    $i2 = _SA 'Board prices aging inside a fresh file' @('-CausedBy', 'guards-hold')
    $i3 = _SA ("smp-feed edge did not pick up today's push - " + $tdy) @('-CausedBy', 'guards-hold')
    $gf = @($i3.items | Where-Object { $_.id -eq $gfId })
    _T 'MUST FIRE the 2026-09-10 morning replayed: three hold-caused alerts leave ONE queue item' $i3.items.Count 1
    _T 'MUST FIRE and each was absorbed into the open GUARDS FAILED item (count 1 -> 4, three recurrences name the cause)' ([bool]($gf.Count -eq 1 -and [int]$gf[0].count -eq 4 -and @($gf[0].recurrences | Where-Object { $_.caused_by -eq 'guards-hold' }).Count -eq 3)) 'True'
    _T 'MUST NOT FIRE no absorbed alert takes the mail leg' ([bool]((($i1.out + $i2.out + $i3.out) -notmatch 'alert MUTED') -and $i1.out -match 'absorbed by incident guards-hold')) 'True'
    # MUST FIRE: a watchdog finding the hold did NOT cause still mints its own item on the same red morning.
    [IO.File]::WriteAllText($saBody, 'VISIBILITY SWEEP DID NOT COMPLETE: set-recipe-visibility -Audit produced no verdict line, so whether a paid recipe is served free is UNKNOWN this run.', $utf8)
    $i4 = _SA ('Grocery capture watchdog: 1 issue(s) ' + $tdy)
    _T 'MUST FIRE an independent watchdog finding on the hold morning mints its own item and takes the mail leg' ([bool]($i4.items.Count -eq 2 -and $i4.out -match 'alert MUTED')) 'True'
    # CLEAN TWIN: guards green, the same hold-caused lines mint normally.
    _Verdict $false
    [IO.File]::WriteAllText($saQ, $gfQueue, $utf8)
    $i5 = _SA ('Grocery capture watchdog: held by guards ' + $tdy) @('-CausedBy', 'guards-hold')
    _T 'CLEAN TWIN with guards green the same watchdog alert mints its own item and takes the mail leg' ([bool]($i5.items.Count -eq 2 -and $i5.out -match 'alert MUTED')) 'True'
    # MUST FIRE: an unknown incident key never drops an alert.
    _Verdict $true
    [IO.File]::WriteAllText($saQ, $gfQueue, $utf8)
    $i6 = _SA 'Board prices aging inside a fresh file' @('-CausedBy', 'no-such-incident')
    _T 'MUST FIRE an unknown incident key falls back to normal: it mints and takes the mail leg' ([bool]($i6.items.Count -eq 2 -and $i6.out -match 'alert MUTED')) 'True'
    # MUST NOT FIRE (pure): a blocked verdict with no OPEN GUARDS FAILED item, or a verdict from another day, absorbs nothing.
    $blk = [pscustomobject]@{ date = '2026-09-10'; guards_blocked = $true }
    $gfRes = [pscustomobject]@{ id = 'r'; type = 'grocery guards failed board not published'; status = 'resolved'; ts = '2026-09-10T08:15:00' }
    $gfOpen = [pscustomobject]@{ id = 'o'; type = 'grocery guards failed board not published'; status = 'open'; ts = '2026-09-10T08:15:00' }
    _T 'MUST NOT FIRE a blocked verdict with no open GUARDS FAILED item absorbs nothing' ([bool]($null -eq (Get-IncidentAbsorbTarget -Items @($gfRes) -CausedBy 'guards-hold' -Verdict $blk -Today '2026-09-10').target)) 'True'
    _T 'MUST NOT FIRE a blocked verdict from another day absorbs nothing' ([bool]($null -eq (Get-IncidentAbsorbTarget -Items @($gfOpen) -CausedBy 'guards-hold' -Verdict $blk -Today '2026-09-11').target)) 'True'
    # ---- A QUEUE LOCK THAT WAS NOT TAKEN IS NEVER A QUEUE WRITE (2026-09-11) ----
    # MUST FIRE, the founding shape: ANOTHER PROCESS holds the queue lock through this send's whole wait. Before the fix
    # the send rewrote the queue anyway, unlocked, which is how an alert the holder had just queued could be lost. Now
    # the queue must be byte-identical and the entry must be in the spool. The holder keeps the lock until it is
    # released, so no clock decides this case.
    [IO.File]::WriteAllText($saQ, $gfQueue, $utf8)
    foreach ($sf in @(Get-ChildItem -LiteralPath $saG -Filter 'triage-spool-*.jsonl')) { Remove-Item -LiteralPath $sf.FullName -Force }
    function _Spooled {
      $rows = @()
      foreach ($sf in @(Get-ChildItem -LiteralPath $saG -Filter 'triage-spool-*.jsonl')) {
        foreach ($ln in @([IO.File]::ReadAllLines($sf.FullName))) { if ($ln.Trim()) { $rows += ($ln | ConvertFrom-Json) } }
      }
      return ,@($rows)
    }
    $lkSubj = 'Board prices aging inside a fresh file'
    $qBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($saQ))
    $lk1 = $null
    $lkHold = Start-TcMutexHold -Name $saMutex
    try { if ($lkHold.Held) { $lk1 = _SA $lkSubj @('-QueueLockTimeoutMs', '1500') } } finally { Stop-TcMutexHold -Hold $lkHold }
    _T ('the lock fixture really held the queue lock from another process (' + $lkHold.Detail + ')') ([bool]$lkHold.Held) 'True'
    $sp1 = _Spooled
    _T 'MUST FIRE a send whose queue lock is held by another process leaves triage-queue.json byte-identical' ([bool]($null -ne $lk1 -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($saQ)) -eq $qBefore)) 'True'
    _T 'MUST FIRE and the entry is in the spool, carrying its subject and naming the lock as the reason' ([bool]($sp1.Count -eq 1 -and [string]$sp1[0].subject -eq $lkSubj -and [string]$sp1[0].reason -match 'lock')) 'True'
    _T 'MUST FIRE and the alert still takes the mail leg, saying it was NOT queued' ([bool]($null -ne $lk1 -and $lk1.out -match 'alert MUTED' -and $lk1.out -match 'NOT queued')) 'True'
    # CLEAN TWIN: the lock released, the very same send is written to the queue and spools nothing more.
    $lk2 = _SA $lkSubj @('-QueueLockTimeoutMs', '1500')
    $sp2 = _Spooled
    _T 'CLEAN TWIN with the lock free the same send is written to the queue (1 item -> 2) and says so' ([bool]($lk2.items.Count -eq 2 -and $lk2.out -match 'queued to triage-queue.json')) 'True'
    _T 'MUST NOT FIRE and it adds nothing to the spool' $sp2.Count 1
  } finally {
    Stop-TcMutexHold
    Remove-Item -LiteralPath $saDir -Recurse -Force -ErrorAction SilentlyContinue
  }
  Write-Output ""
  if ($fail -gt 0) { Write-Output "SELF-TEST FAIL: $fail case(s)"; exit 1 }
  Write-Output 'SELF-TEST PASS (queue routing + body-thin + emitter path + mute switch + birth lane + alert registry + queue lock refusal)'
  exit 0
}

# ---- WHICH CLASS IS THIS ALERT? (2026-09-10, Brad ruling 1) ------------------------------------------------
# page = emailed and queued; review = queued, never emailed; digest = emailed, never queued. The class comes from
# grocery\alert-registry.json through alert-registry-lib.ps1. EVERY failure here fails toward PAGE: a lib that will
# not load, a registry that is missing or unparseable, or a type no entry matches all leave $delivery as page, and
# the last of those also marks the mail subject so the registry gap is visible in the inbox. The default below IS
# the behaviour this script had before the registry existed.
$delivery = [pscustomobject]@{ class = 'page'; queue = $true; mail = $true; mail_subject = $Subject; unregistered = $false; entry_id = ''; note = '' }
$regLibOk = $false
try { . (Join-Path $root 'alert-registry-lib.ps1'); $regLibOk = $true } catch { Log ("ALERT REGISTRY LIB DID NOT LOAD (" + $_.Exception.Message + ") - failing toward PAGE for '" + $Subject + "'") }
if ($regLibOk) {
  try {
    $regState = Read-AlertRegistry (Join-Path $root 'alert-registry.json')
    if (-not $regState.ok) { Log ("ALERT REGISTRY UNREADABLE: " + $regState.why + " - failing toward PAGE for '" + $Subject + "' [type: " + $typeKey + "]") }
    $delivery = Get-AlertDelivery -Resolution (Resolve-AlertClass $regState.registry $typeKey) -Subject $Subject -Escalates $Escalates -Lane $Lane
  } catch { Log ("ALERT REGISTRY could not be applied (" + $_.Exception.Message + ") - failing toward PAGE for '" + $Subject + "'") }
}
if ($delivery.unregistered) { Log ("UNREGISTERED ALERT TYPE '" + $Subject + "' [type: " + $typeKey + "] - no entry in grocery\alert-registry.json matches, so it queues AND pages as a registry defect. Register it and run grocery\audit-alert-registry.ps1.") }

# -CausedBy: read the incident's evidence now, outside the queue lock. An unreadable verdict is $null, and a $null
# verdict absorbs nothing, so every failure here sends the alert normally.
$incVerdict = $null
if ($CausedBy) {
  try {
    . (Join-Path (Split-Path -Parent $root) 'lib\chain-verdict-lib.ps1')
    $incVerdict = Read-ChainVerdictRecord -Repo (Split-Path -Parent $root)
  } catch { $incVerdict = $null; Log ("-CausedBy " + $CausedBy + ": the chain verdict could not be read (" + $_.Exception.Message + "), so '" + $Subject + "' is NOT absorbed") }
}
$absorbedBy = ''

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
# A DIGEST-CLASS ALERT IS NEVER QUEUED (ruling 1). The queue block below runs only when the class queues; it keeps
# its old indentation so the change reads as the one condition it is.
# THE QUEUE REPLACE AND THE SPOOL APPEND GO THROUGH lib\ (2026-09-11). Neither may take the alerter down on a day lib\
# will not load, so each falls back to the write this script made before - a replace that can lose to a lock-free
# reader, an append that can lose to another appender - and the log says so.
$awLibOk = $false
try { . (Join-Path (Split-Path -Parent $root) 'lib\atomic-write.ps1'); $awLibOk = $true } catch { Log ("lib\atomic-write.ps1 DID NOT LOAD (" + $_.Exception.Message + ") - the queue replace falls back to a bare Move-Item") }
$alLibOk = $false
try { . (Join-Path (Split-Path -Parent $root) 'lib\append-line.ps1'); $alLibOk = $true } catch { Log ("lib\append-line.ps1 DID NOT LOAD (" + $_.Exception.Message + ") - the spool append falls back to a bare Add-Content") }

$queued = $false
if (-not $delivery.queue) { Log ("DIGEST '" + $Subject + "' [type: " + $typeKey + "] - registry entry " + $delivery.entry_id + " is digest class, so it is mailed and NOT queued") }
if ($delivery.queue) {
$qMutex = $null
$qHeld = $false
try {
  # A LOCK THAT WAS NOT TAKEN IS NEVER A QUEUE WRITE (2026-09-11). Until today the wait's answer went into $qHeld and
  # nothing read it: after a 10 s timeout this block went on to read the queue, rebuild it and replace the whole file
  # UNLOCKED, racing the writer that did hold the lock, so an alert that writer had just queued could be overwritten
  # out of existence. The wait expires exactly when writers pile up - capture-run's store lanes, check-ad-cycles'
  # 8-wide fanout of alerting audits, the 15-minute sidecar watchdog - which is when a lost write is likeliest.
  # Now a lock not taken throws, and the catch below SPOOLS the entry: recorded, reported DUE by triage-due.ps1, never
  # dropped and never written unlocked. $queued stays false, so the alert then takes the road of any failed queue
  # write: a review-class alert is mailed, and an incident-caused one is not absorbed.
  # The mutex is opened inside the try too, so a mutex that cannot be opened spools rather than killing the alert.
  $qMutex = New-Object System.Threading.Mutex($false, $QueueMutexName)
  try { $qHeld = $qMutex.WaitOne($QueueLockTimeoutMs) } catch [System.Threading.AbandonedMutexException] { $qHeld = $true }
  if (-not $qHeld) { throw ('triage-queue lock ' + $QueueMutexName + ' not acquired in ' + $QueueLockTimeoutMs + ' ms - the queue was NOT rewritten unlocked, so this entry is spooled') }
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
    $q = [pscustomobject]@{ readme = 'Durable ops-alert queue. Written by send-alert.ps1 on EVERY alert (even inbox-suppressed dupes). Drained by the grocery-alert-triage scheduled agent: investigate -> fix -> fix the ROOT cause -> CLOSE THROUGH grocery\triage-close.ps1 -Id <id> -Disposition <confirmed|false-alarm|superseded|by-design|wont-fix> -Notes "<what was established>". The disposition is what makes a per-alert LIVE precision computable (backlog E22); a hand-edited status=resolved records that somebody dealt with it and loses whether the alert was right. Do not hand-edit except to force a re-triage (set status back to open).'; items = @() }
  }
  $items = @($q.items)
  $bodyStored = $(if ($Body.Length -gt 1500) { $Body.Substring(0,1500) + ' ...[truncated - full context in ad-cycle-log.txt / the source audit json]' } else { $Body })
  $thin = Test-BodyThin $Body
  $incident = Get-IncidentAbsorbTarget -Items $items -CausedBy $CausedBy -Verdict $incVerdict -Today $today
  if ($incident.target) {
    # A CONSEQUENCE OF AN OPEN INCIDENT: one incident, one id. Written on the incident's item as a dated recurrence
    # that names its cause, so triage still reads every symptom without a second item to open and close.
    $t = $incident.target
    $t.count = [int]$t.count + 1
    if ($t.PSObject.Properties['last_seen']) { $t.last_seen = (Get-Date).ToString('s') } else { $t | Add-Member -NotePropertyName last_seen -NotePropertyValue (Get-Date).ToString('s') }
    $rec = @()
    if ($t.PSObject.Properties['recurrences']) { $rec = @($t.recurrences) }
    $rec += [pscustomobject]@{ date = $today; subject = $Subject; caused_by = $CausedBy; body = $(if ($bodyStored.Length -gt 400) { $bodyStored.Substring(0,400) + ' ...' } else { $bodyStored }) }
    if ($rec.Count -gt 5) { $rec = @($rec[($rec.Count-5)..($rec.Count-1)]) }
    if ($t.PSObject.Properties['recurrences']) { $t.recurrences = $rec } else { $t | Add-Member -NotePropertyName recurrences -NotePropertyValue $rec }
    $absorbedBy = [string]$t.id
    Log ("QUEUE ABSORBED BY INCIDENT " + $CausedBy + " into " + $t.id + " (count now " + $t.count + "): '" + $Subject + "' - no new id, no mail")
  } else {
  if ($CausedBy) { Log ("-CausedBy " + $CausedBy + " did not absorb '" + $Subject + "': " + $incident.why + " - it goes out as a normal alert") }
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
      # -Escalates parks the item at birth; without it this is exactly the 'open' it has always been.
      $birth = Get-BirthDisposition $Escalates
      $newItem = [pscustomobject]@{
        id = ($today + '-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        date = $today; ts = (Get-Date).ToString('s')
        type = $typeKey; subject = $Subject
        body = $bodyStored
        status = $birth.status; count = 1; resolved_ts = $null; notes = $birth.notes
      }
      if ($Escalates) { Log ("QUEUE PARKED AT BIRTH: '" + $Subject + "' is the escalation email for " + $Escalates + ", so it is written needs-brad rather than open - triage-due will not list it as work.") }
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
      # -Lane weekly (a triage-created residual or finding): stamped on NEW items only, like the emitter.
      $birthLane = Get-BirthLane $Lane
      if ($birthLane) { $newItem | Add-Member -NotePropertyName lane -NotePropertyValue $birthLane }
      # ruling 1: an unregistered type says so on its record, and a review item records that it was not mailed.
      # A registered page item stamps neither, so its record is the one it always was.
      if ($delivery.unregistered) { $newItem | Add-Member -NotePropertyName unregistered -NotePropertyValue $true }
      if ($delivery.class -eq 'review') { $newItem | Add-Member -NotePropertyName alert_class -NotePropertyValue 'review' }
      # an alert nobody can classify from its own body is a bug in the ALERT - say so on the record
      if ($thin) {
        $newItem | Add-Member -NotePropertyName body_thin -NotePropertyValue $true
        Log ("BODY THIN on '" + $Subject + "' - the queue entry carries no store, commodity or number, so it cannot be classified without hunting the data. Fix the caller to include the identifying rows.")
      }
      $items += $newItem
    }
  }
  }   # else: not absorbed by an incident
  # keep resolved history 30 days so triage can see recurrences; open items never age out
  $cut = (Get-Date).AddDays(-30)
  $items = @($items | Where-Object { $_.status -eq 'open' -or ([datetime]$_.ts) -ge $cut })
  $q.items = $items
  # atomic swap: write the whole document to a sibling temp, then replace. A reader either sees the old file
  # or the new one, never a half-written one. THROUGH lib\atomic-write.ps1 SINCE 2026-09-11: a bare Move-Item -Force
  # fails outright while a lock-free reader (triage-due.ps1, queue-depth.ps1, the brain digest) has the file open, and
  # the entry then went to the spool instead of the queue. The retry outlasts the reader. Same bytes either way: a
  # UTF-8 BOM, the JSON, CRLF.
  $qJson = $q | ConvertTo-Json -Depth 4
  if ($awLibOk) { [void](Write-TcAtomicFile -Path $qFile -Text $qJson) }
  else {
    $qTmp = $qFile + '.tmp'
    $qJson | Set-Content $qTmp -Encoding UTF8
    Move-Item -Path $qTmp -Destination $qFile -Force   # atomic-replace:allow the fallback used only when lib\atomic-write.ps1 did not load; the log line above says so
  }
  $queued = $true
} catch {
  Log ("triage-queue write failed (email still goes out): " + $_.Exception.Message)
  # NEVER lose the entry: Brad's rule is that an alert must not wait for a human, and an alert that never
  # reached the queue waits forever. Spool it beside the queue; triage-due.ps1 reports a spool as DUE.
  try {
    $spool = Join-Path $root ('triage-spool-' + $today + '.jsonl')
    $line = ([pscustomobject]@{ ts=(Get-Date).ToString('s'); type=$typeKey; subject=$Subject; body=$Body; reason=$_.Exception.Message } | ConvertTo-Json -Depth 4 -Compress)
    # THROUGH lib\append-line.ps1 (2026-09-11). A bare Add-Content lands a line only while no other process is
    # appending: in a scratch harness two concurrent appenders landed 13 of 200 lines. A spool is written exactly when
    # senders are contending for the queue lock, so without this the refusal above would have moved the loss here.
    if ($alLibOk) { [void](Add-TcLine -Path $spool -Text $line) } else { Add-Content -Path $spool -Value $line -Encoding UTF8 }
  } catch { Log ('triage-spool write ALSO failed: ' + $_.Exception.Message) }
} finally {
  if ($qHeld) { try { $qMutex.ReleaseMutex() } catch {} }
  if ($qMutex) { try { $qMutex.Dispose() } catch {} }
}
}   # if ($delivery.queue)

# ABSORBED BY AN INCIDENT: durable on the incident's item, so no mail. When the queue write failed $queued is false
# and this falls through to the normal path below - a consequence nobody recorded must still page.
if ($absorbedBy -and $queued) {
  Write-Output ("alert absorbed by incident " + $CausedBy + " into open item " + $absorbedBy + " - no new id, no email")
  exit 0
}

# A REVIEW-CLASS ALERT IS NEVER MAILED (ruling 1), once it is durable in the queue. When the queue write FAILED it is
# mailed instead: the spool may hold it, but an alert this script could not record must page, never vanish.
if (-not $delivery.mail) {
  $revWhy = $delivery.note
  if ($delivery.entry_id) { $revWhy = ('registry entry ' + $delivery.entry_id) }
  if ($queued) {
    Log ("REVIEW '" + $Subject + "' [type: " + $typeKey + "] - queued, NOT emailed (" + $revWhy + ")")
    Write-Output ("alert queued as REVIEW - not emailed, by ruling 1 (" + $revWhy + ")")
    exit 0
  }
  Log ("REVIEW '" + $Subject + "' could not reach the queue, so it is EMAILED instead - a review alert this script could not record must page, never vanish")
}

# MUTED? The queue entry is already durable at this point, so triage still sees and works this alert; we
# just do not mail it. -Force does NOT punch through: -Force exists to beat the once-a-day gate for a new
# incident, and "stop all email alerts" outranks "this one is urgent enough to repeat today".
$mute = Get-MuteState (Join-Path $root 'alerts-muted.json') $today
if ($mute.muted) {
  $mQ = 'NOT queued'
  if ($queued) { $mQ = 'queued to triage-queue.json' }
  Log ("MUTED (" + $mute.why + ") - " + $mQ + " but NOT emailed: '$Subject' [type: $typeKey] [mail subject '" + $delivery.mail_subject + "']")
  Write-Output ("alert MUTED (" + $mute.why + ") - " + $mQ + ", no email sent [mail subject '" + $delivery.mail_subject + "']. Delete grocery\alerts-muted.json to resume email.")
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
  $raw = "To: $To`r`nSubject: $($delivery.mail_subject)`r`nContent-Type: text/plain; charset=UTF-8`r`n`r`n$Body`r`n`r`n(Automated alert from the Omaha grocery pipeline.)"
  $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($raw)).Replace('+','-').Replace('/','_').TrimEnd('=')
  $resp = Invoke-RestMethod -Uri "https://gmail.googleapis.com/gmail/v1/users/me/messages/send" -Method Post `
            -Headers @{ Authorization = "Bearer $token" } -ContentType "application/json" -Body (@{ raw = $b64 } | ConvertTo-Json) -TimeoutSec 30
  Add-Content -Path $sentFile -Value $typeKey   # record the type so the rest of today's runs stay quiet
  Log ("SENT '" + $delivery.mail_subject + "' -> $To (id " + $resp.id + ")")
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
