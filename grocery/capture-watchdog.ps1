<#
  capture-watchdog.ps1 - did today's capture actually happen, and did it publish?

  WHY THIS EXISTS. The old SMP Grocery Failure Watchdog watched the old jobs; those
  jobs are gone, replaced by TC Grocery Ad Pulls 0700 and TC Grocery Daily Capture
  0800. Without a replacement NOTHING notices if the new schedule stops firing -
  and a capture pipeline that silently stops is indistinguishable from one where
  prices simply have not changed. The board keeps serving, quietly going stale.

  IT CHECKS OUTCOMES, NOT JUST EXIT CODES. A task can report success and still have
  done nothing (the shape this estate keeps rediscovering: a confident ok over an
  empty examination). So this asks, in order:

    1. SCHEDULE     do both tasks still exist, enabled, with a next run?
    2. RAN          did each fire today, and what did it exit with?
    3. CAPTURED     is there a comparison board dated today?
    4. PUBLISHED    is public\board.json newer than that board?
    5. AD HEALTH    audit-ad-status: any store's ad closed or its pull overdue?
    5a. AD FORECAST audit-ad-forecast: has next_pull been LANDING? A ratchet on
        full-cycle misses - a store skipping a whole weekly ad means the board
        carried a stale price for a week. Different question from 5: that one is
        about today, this one is about the record.
    6. BROWSER      is a browser-capture flag still sitting unworked?
    7. CHECKOUT     does the checkout the bot runs from contain origin/main? BOT CHECKOUT STALE when the oldest commit
                    it is missing is more than 93,600 s (26 h) old. When capture-run STOPS it still fires: it reads git
                    (ls-remote, merge-base, rev-list), never capture-run's record.
    8. BACKLOG      after 10:00 local, is any untracked, not-ignored file under grocery/out dated before today?
                    CAPTURE BACKLOG, grouped by date. When capture-run STOPS it still fires: it reads git ls-files and
                    the file sizes on disk, never capture-run's record.
    9. KILL SWITCH  is <git common dir>\tc-checkout-sync.disabled present? BOT CHECKOUT SYNC DISABLED on every run, so
                    it cannot be forgotten. When capture-run STOPS it still fires: it reads the file, never a record.
    10. INTRUDERS   report only: how many dirty or untracked entries no declared writer owns, one row a day in
                    <git common dir>\tc-production-intruders.jsonl (design\PLAN-bot-dedicated-checkout-2026-09-25.md W0.3).
                    An ok line, never a finding.
    (7 to 9 are design\PLAN-bot-checkout-self-heal-2026-09-23.md W1.1. The per-store freshness scan further down is
    headed "7." in the body for historical reasons and is not one of them. The -SlotClose run grades only check 6a.)

  Anything that fails is ONE email, not six. Exit 0 = healthy, 1 = findings.
#>
# What -SelfTest reads, declared so the gate key moves when any of it does (its fixtures build every git repo and
# every out\ directory they read under %TEMP%; capture-run.ps1 is read for its AST, stores.json by the -SlotClose child).
# gate-inputs: grocery\capture-watchdog.ps1, lib\json-io.ps1, grocery\run-log-lib.ps1, grocery\native-lib.ps1, lib\git-blob-lib.ps1, lib\git-repo-env.ps1, grocery\capture-policy-lib.ps1, grocery\stores.json
# capture-run.ps1 is TEXT to this suite (2026-09-24): it is parsed, and its two self-contained functions Add-FailedLane and
# Set-FailedLanePaged are lifted by AST and run. Nothing it dot-sources or launches runs here, so its bytes are the input
# and walking into it put 757 files and the event bus in this key.
# gate-inputs-text: grocery\capture-run.ps1
param([switch]$Alert, [string]$OutDir = '', [string]$Today = '', [switch]$SelfTest, [switch]$SlotClose)

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
$todayS = if ($Today) { $Today } else { (Get-Date).ToString('yyyy-MM-dd') }
. (Join-Path $root 'run-log-lib.ps1')
. (Join-Path $root 'native-lib.ps1')   # Invoke-Native: the ONLY safe way to redirect a native child under EAP=Stop
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\git-blob-lib.ps1')   # Invoke-GitCaptured: git with both streams kept, never a redirect (checks 7-9)

# Runs hidden from a scheduled task, so its findings only existed in an email.
# The transcript keeps the evidence even when the alert de-dup suppresses the mail.
# -SelfTest is excluded: it is a foreground developer action, not a scheduled run.
$runLog = if ($SelfTest) { $null } elseif ($SlotClose) { Start-RunLog -Name 'capture-watchdog-slotclose' -OutDir $OutDir -Today $todayS } else { Start-RunLog -Name 'capture-watchdog' -OutDir $OutDir -Today $todayS }

# ---- THE BROWSER-CAPTURE CHECK, SHARED BY THE 10:30 RUN AND THE SLOT-CLOSE RUN (2026-09-22, queue 2026-09-22-2000e1) ----
# One table of which file proves each browser store landed on a day, one stamp path, one finding text: the two runs that
# grade the same fact read it the same way.
function Get-BrowserCaptureFiles([string]$Dir, [string]$DateS) {
  return @{
    'Walmart'    = Join-Path $Dir "captures\walmart-capture-$DateS.csv"
    "Sam's Club" = Join-Path $Dir "captures\sams-capture-$DateS.csv"
    'Aldi'       = Join-Path $Dir "captures\aldi-capture-$DateS.csv"
    'Fareway'    = Join-Path $Dir "fareway\fareway-shop-$DateS.jsonl"
  }
}
function Get-BrowserSlotStampPath([string]$Dir, [string]$DateS) { return (Join-Path $Dir "browser-slot-close-$DateS.json") }
function Get-BrowserCaptureFindings {
  param($V, [string]$TodayS, [string]$YesterdayS, [string]$SlotTxt)
  $o = @()
  if (@($V.MissingToday).Count) { $o += ("BROWSER CAPTURE MISSING TODAY: " + (@($V.MissingToday) -join ', ') + " - no capture dated $TodayS with a data row, and the producer's $SlotTxt has closed. The morning Chrome task (grocery-browser-stores-refresh, Brad's Chrome) did not land them, and for Walmart and Aldi nothing else can.") }
  if (@($V.MissingYesterday).Count) { $o += ("BROWSER CAPTURE MISSING YESTERDAY: " + (@($V.MissingYesterday) -join ', ') + " - no capture dated $YesterdayS with a data row, and that day's $SlotTxt closed with nothing landed and no slot-close run graded it (the backstop). The morning Chrome task (grocery-browser-stores-refresh, Brad's Chrome) did not land them.") }
  return ,$o
}

# ---- -SlotClose: GRADE THE BROWSER SLOT THE MOMENT IT CLOSES (2026-09-22, queue 2026-09-22-2000e1) --------------------
# The 10:30 run sits INSIDE the Chrome task's slot (06:15-14:00), so it can only say NOT YET for today. Without this run a
# real miss paged the next morning. TC Grocery Browser Slot Close 1415 runs `capture-watchdog.ps1 -SlotClose -Alert`
# after the slot ends, grades ONLY the browser check, pages a miss the same day, and writes a stamp so the next
# morning's backstop does not page it again. Nothing else in this file runs in this mode.
if ($SlotClose -and -not $SelfTest) {
  if (-not (Get-Command Get-ProducerSlot -ErrorAction SilentlyContinue)) { . (Join-Path $root 'capture-policy-lib.ps1') }
  $scDay = [datetime]::ParseExact($todayS, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
  $scSlot = Get-ProducerSlot 'grocery-browser-stores-refresh' $scDay
  # -Today pins the clock to 15 minutes after the slot end, the task's own offset, so a fixture run is deterministic.
  $scNow = if ($Today -and $scSlot) { $scSlot.end.AddMinutes(15) } else { Get-Date }
  $scTxt = if ($scSlot) { ('slot ' + $scSlot.start.ToString('HH:mm') + '-' + $scSlot.end.ToString('HH:mm')) } else { 'no declared slot' }
  if ($scSlot -and $scNow -lt $scSlot.end) {
    Write-Output ("capture-watchdog -SlotClose: the $scTxt is still open at " + $scNow.ToString('HH:mm') + " - nothing graded, no stamp written (NOT YET)")
    Write-Output 'CAPTURE-WATCHDOG-COMPLETE findings=0 not_yet=1 mode=slot-close'
    exit 0
  }
  $scStores = Get-BrowserSurfaceStores -Root $root
  $scV = Get-BrowserCaptureVerdict -Stores $scStores -TodayFiles (Get-BrowserCaptureFiles $OutDir $todayS) -YesterdayFiles $null -Now $scNow -Slot $scSlot
  $scFind = Get-BrowserCaptureFindings -V $scV -TodayS $todayS -YesterdayS '' -SlotTxt $scTxt
  $scFind = @($scFind)
  $stamp = [ordered]@{ date = $todayS; graded_at = $scNow.ToString('s'); slot = $scTxt; stores = @($scStores); missing = @($scV.MissingToday) }
  [IO.File]::WriteAllText((Get-BrowserSlotStampPath $OutDir $todayS), ($stamp | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
  if ($scFind.Count) {
    foreach ($f in $scFind) { Write-Output ('  FIND  ' + $f) }
    if ($Alert) {
      . (Join-Path $root 'alert-lib.ps1')
      $scPtr = if ($runLog) { "Slot-close report for $todayS : $runLog" } else { 'Slot-close report: run grocery\capture-watchdog.ps1 -SlotClose' }
      try { Send-AlertConditions -SubjectPrefix 'Grocery capture watchdog' -Conditions $scFind -ReportPointer $scPtr -DateStamp $todayS | Out-Null } catch { Write-Output ('  alert threw: ' + $_.Exception.Message) }
    }
  } else {
    Write-Output ('  ok    browser capture: every browser store (' + (@($scStores) -join ', ') + ') has a capture dated ' + $todayS + ' at its slot close')
  }
  Write-Output ("CAPTURE-WATCHDOG-COMPLETE findings={0} not_yet=0 mode=slot-close" -f $scFind.Count)
  exit $(if ($scFind.Count) { 1 } else { 0 })
}

# How long a registered-but-never-fired task is still innocently "waiting for its trigger".
# One full daily cycle plus a margin: a task registered AFTER today's slot (exactly how the
# 07:00 and 08:00 capture tasks were created on 2026-08-20, at 08:24) legitimately cannot run
# until tomorrow, and calling that broken on day one would train the reader to ignore this
# watchdog before it had ever reported anything real.
$script:NeverRanGraceHours = 30

function Test-NeverRanTooLong {
  <#
    .SYNOPSIS Has a task that has NEVER fired been waiting long enough to call it broken?
    .DESCRIPTION Pure, so the -SelfTest fixture below can drive it without a real Task
                 Scheduler. Returns $false when the start boundary is unknown: an unreadable
                 trigger is not evidence of a fault, and inventing one would be worse than
                 the silence this replaces.
  #>
  param([datetime]$TriggerStart, [datetime]$Now, [int]$GraceHours = 0)
  if ($GraceHours -le 0) { $GraceHours = $script:NeverRanGraceHours }
  if (-not $TriggerStart -or $TriggerStart.Year -lt 2000) { return $false }
  return ((($Now - $TriggerStart).TotalHours) -gt $GraceHours)
}

# How stale the NEWEST board may be before this is a finding (2026-08-30, queue 2026-08-22-fe7b43).
# Section 3 used to ask Test-Path comparison-<today>.json, which is structurally wrong on this estate:
# the board is NAMED after the newest ads file, never after today - guards.ps1 says so in its own line,
# "the board is built from the newest ads file (ads-2026-08-26 -> comparison-2026-08-26)". So on every
# day the ad window had not rolled over, NO BOARD FOR TODAY fired while the heartbeat two sections up
# reported that same board 1.3 h fresh, and the watchdog task sat at LastResult=1 for over a week. A
# watchdog that is red on quiet days teaches its reader to ignore it, which is worse than not running.
# FRESHNESS was always the question; the filename never was.
# 26h = one 24h cadence plus 2h slack. Deliberately NARROWER than two cadences, so a genuinely dead day
# cannot be alibied by yesterday's output (the tolerance-wider-than-period trap).
$script:BoardStaleHours = 26

function Test-BoardStale {
  <#
    .SYNOPSIS Is the newest board older than one capture cadence?
    .DESCRIPTION Pure, so the -SelfTest fixtures below can drive it with frozen timestamps
                 instead of whatever out\ happens to hold on the day the test runs.
  #>
  param([datetime]$BoardWritten, [datetime]$Now, [int]$MaxHours = 0)
  if ($MaxHours -le 0) { $MaxHours = $script:BoardStaleHours }
  if (-not $BoardWritten -or $BoardWritten.Year -lt 2000) { return $false }
  return ((($Now - $BoardWritten).TotalHours) -gt $MaxHours)
}

function Test-RunSuperseded {
  <#
    .SYNOPSIS Did the board get rebuilt AND shipped after a task exited non-zero?
    .DESCRIPTION
      Pure, so the -SelfTest fixtures can drive it with frozen timestamps.

      WHY (2026-08-31). The 08:00 task exits 1 whenever guards refuse to publish - which is the guard
      doing its job, not the capture failing. This watchdog ran at 09:30 back then and reported that exit code
      as "FAILED", so on a day the blocker was found and cleared in between, the email announced a
      failure about a board that was live, current and correct. Measured that morning: the run exited 1
      at 08:00, the board was rebuilt at 09:26 and published, and this watchdog's OWN healthy lines
      said so three rows below the FAILED it had just written. An alert that contradicts itself in the
      same message is how a real signal gets trained into noise.

      SUPERSEDED IS NOT THE SAME AS FINE, and this deliberately does not suppress. The caller reports
      it as a resolved run with both facts on the record - what exited, and what fixed it - so a day
      that needed a human still reads differently from a day that just worked.

      BOTH halves are required. A board rebuilt but NOT shipped is the "rebuilt but never published"
      defect section 4 exists to catch, so it must not count as superseding anything; that is why the
      publish time is checked against the board rather than against the run.
  #>
  param($RunAt, $BoardWritten, $PublishedWritten, [int]$PublishSlackMinutes = 30)
  if ($null -eq $RunAt -or $null -eq $BoardWritten -or $null -eq $PublishedWritten) { return $false }
  $r = [datetime]$RunAt; $b = [datetime]$BoardWritten; $p = [datetime]$PublishedWritten
  if ($r.Year -lt 2000 -or $b.Year -lt 2000 -or $p.Year -lt 2000) { return $false }
  if ($b -le $r) { return $false }                                  # board is no newer than the failed run
  if ($p -lt $b.AddMinutes(-$PublishSlackMinutes)) { return $false } # rebuilt but never shipped
  return $true
}

function Test-HeldByGuards {
  <#
    .SYNOPSIS Is every symptom below just ONE thing - the gate refusing today's board?
    .DESCRIPTION
      Pure, so the -SelfTest fixtures can drive it with frozen values.

      WHY (2026-09-07, queue 2026-09-07-e5efa6). At 08:14 check-ad-cycles ran guards, guards hard-failed
      on the band-censorship ratchet, and it wrote that verdict down: out\chain-verdict.json. capture-run
      then staged INPUTS ONLY, exited 1, and left public\board.json on yesterday's bytes with the exported
      feed unstaged. At 10:30 this watchdog probed FOUR of those artifacts independently and emailed four
      issues - a run record, a stale board.json, a failed task and an unshipped feed - two hours after
      check-ad-cycles had already paged GUARDS FAILED for the same hold. Four probes, one cause, and the
      one artifact that states the cause as a VALUE was read by nobody here: its only readers were
      capture-run.ps1 and push-data.ps1.

      Class: a derivative check that cannot see its upstream cause. Test-RunSuperseded (2026-08-31) fixed
      the TIME axis of this exact shape - was the failure superseded later - and left the CAUSE axis.

      DELIBERATELY NARROW, because the defect section 4 exists for looks identical from the outside. A
      board that was rebuilt and never shipped with guards GREEN is a real, separate failure and must keep
      paging on its own. So all of: the verdict exists, it is TODAY's (the same same-day rule push-data
      and capture-run key on, so yesterday's refusal cannot silence today's), it says blocked, and
      nothing has been rebuilt AND shipped since it was written. The moment something ships, this goes
      false and every existing finding fires exactly as it did before.
  #>
  param($Verdict, [string]$Today, $BoardWritten, $PublishedWritten)
  if ($null -eq $Verdict) { return $false }
  if (-not $Verdict.date -or ([string]$Verdict.date -ne [string]$Today)) { return $false }
  if (-not $Verdict.guards_blocked) { return $false }
  # Rebuilt AND shipped after the refusal = the hold was cleared and this is not what is wrong now.
  if (Test-RunSuperseded -RunAt $Verdict.written -BoardWritten $BoardWritten -PublishedWritten $PublishedWritten) { return $false }
  return $true
}

function Merge-HeldFindings {
  <#
    .SYNOPSIS Fold the derivative symptoms of a guards hold under the one finding that names the cause.
    .DESCRIPTION
      Pure over its arguments so the -SelfTest fixtures drive the REAL assembly rather than a copy of it.
      A fold tested only through its predicate would prove the predicate and nothing about the list the
      reader actually receives, which is where the four-emails-for-one-hold cost lives.

      Not held: everything is returned exactly as it came in. Held: the derivative lines leave the
      findings list and come back as sub-lines under a single HELD BY GUARDS finding, so the exit code
      stays 1 (a held board IS a finding), it is still one email, and the count says one.
  #>
  param($Findings, $Derivative, [bool]$Held, [string]$HeldText)
  $outF = New-Object System.Collections.Generic.List[string]
  $outS = New-Object System.Collections.Generic.List[string]
  if (-not $Held) {
    foreach ($f in $Findings) { [void]$outF.Add([string]$f) }
    return [pscustomobject]@{ findings = $outF; sub = $outS }
  }
  $derivSet = @{}
  foreach ($d in $Derivative) { $derivSet[[string]$d] = $true }
  [void]$outF.Add($HeldText)
  foreach ($f in $Findings) {
    if ($derivSet.ContainsKey([string]$f)) { [void]$outS.Add([string]$f) } else { [void]$outF.Add([string]$f) }
  }
  return [pscustomobject]@{ findings = $outF; sub = $outS }
}

function Get-FailedLanePaging {
  <#
    .SYNOPSIS Which of the daily run's failed lanes paged as themselves (2026-09-22, plan-2026-09-22-10 item 2026-09-22-7c932a).
    .DESCRIPTION
      Pure. capture-run writes failed_lanes [{lane, paged}] beside exit_code, and a lane's paged subject is recorded only
      when its own Send-Alert returned 0. A record with NO failed_lanes field (an older capture-run), or one naming no
      lane at all, answers known=$false, and RUN RECORD then pages exactly as it did before: a missing field fails
      toward the page.
  #>
  param($Record)
  $r = [pscustomobject]@{ known = $false; paged = @(); unpaged = @() }
  if ($null -eq $Record) { return $r }
  $p = $Record.PSObject.Properties['failed_lanes']
  if ($null -eq $p -or $null -eq $p.Value) { return $r }
  $pg = @(); $un = @()
  foreach ($x in @($p.Value)) {
    if ($null -eq $x -or -not [string]$x.lane) { continue }
    if ([string]$x.paged) { $pg += ([string]$x.lane + ' (' + [string]$x.paged + ')') } else { $un += [string]$x.lane }
  }
  if ($pg.Count -eq 0 -and $un.Count -eq 0) { return $r }
  $r.known = $true; $r.paged = $pg; $r.unpaged = $un
  return $r
}

function Get-RunRecordVerdict {
  <#
    .SYNOPSIS What one capture-run record for today says, as ok, finding or failed (2026-09-23, the checkout-sync lane's review).
    .DESCRIPTION
      Pure. The stages capture-run writes, and what each means here:
        complete                       exit 0 is ok; any other exit is 'failed' (RUN RECORD, which the paged-lane fold
                                       may absorb for the daily run).
        blocked-checkout, handoff-failed
                                       FINAL and failed, written with exit 1 by the checkout-sync lane (plan W4.1): the
                                       start sync found conflict markers or a mixed tree, or the synced child never ran.
                                       Each already paged as its own lane (sync, sync-handoff), so it is 'failed' and goes
                                       through the same fold as a completed exit 1, never "not a stage a real run passes
                                       through", which repeated those pages with a wrong explanation.
        started, syncing, synced-handoff, capturing, downstream, publishing
                                       IN PROGRESS: ok under 90 minutes, a finding past it.
        anything else                  a finding: an unrecognised stage is not a healthy one.
      The fold is the caller's; this returns @{ verdict = ok|finding|failed; text }.
  #>
  param($Record, [string]$Kind, [int]$AgeMin)
  $stage = [string]$Record.stage
  if ($stage -eq 'complete') {
    if ([int]$Record.exit_code -ne 0) { return [pscustomobject]@{ verdict = 'failed'; text = "RUN RECORD: capture-run [$Kind] completed with exit $($Record.exit_code) - see $($Record.log)" } }
    return [pscustomobject]@{ verdict = 'ok'; text = "capture-run [$Kind] completed rc=0 at $($Record.updated)" }
  }
  if (@('blocked-checkout', 'handoff-failed') -contains $stage) {
    return [pscustomobject]@{ verdict = 'failed'; text = "RUN RECORD: capture-run [$Kind] stopped at stage '$stage' with exit $($Record.exit_code) before any capture - see $($Record.log)" }
  }
  if (@('started', 'syncing', 'synced-handoff', 'capturing', 'downstream', 'publishing') -notcontains $stage) {
    # An UNRECOGNISED stage is not a healthy one. 'whatif' used to land here and read as ok simply
    # because it was under the age bar - the failure mode this whole check exists to end.
    return [pscustomobject]@{ verdict = 'finding'; text = "RUN RECORD: capture-run [$Kind] left stage '$stage', which is not a stage a real run passes through. Its record cannot be trusted to say whether today's prices were built." }
  }
  if ($AgeMin -gt 90) { return [pscustomobject]@{ verdict = 'finding'; text = "RUN RECORD: capture-run [$Kind] has sat in stage '$stage' for $AgeMin min (pid $($Record.pid)) - it never reached 'complete'. Log: $($Record.log)" } }
  return [pscustomobject]@{ verdict = 'ok'; text = "capture-run [$Kind] in stage '$stage' ($AgeMin min)" }
}

function Merge-PagedLaneFindings {
  <#
    .SYNOPSIS Fold RUN RECORD and its derivative findings under lanes that already paged as themselves.
    .DESCRIPTION
      Pure. Every failed lane paged: RUN RECORD, NOT PUBLISHED and COMPUTED BUT NOT SHIPPED leave the findings and come
      back as sub-lines under one transcript line, and nothing is sent. Some lanes did not page: RUN RECORD is replaced
      by a finding naming exactly those lanes, and it stays derivative. Unknown: everything returns as it came in.
  #>
  param($Findings, $Derivative, $Paging, [string]$RunRecordText, [string]$Kind = 'daily')
  $outF = New-Object System.Collections.Generic.List[string]
  $outS = New-Object System.Collections.Generic.List[string]
  $outD = New-Object System.Collections.Generic.List[string]
  $line = ''
  if ($null -eq $Paging -or -not $Paging.known -or -not $RunRecordText) {
    foreach ($x in $Findings) { [void]$outF.Add([string]$x) }
    foreach ($d in $Derivative) { [void]$outD.Add([string]$d) }
    return [pscustomobject]@{ findings = $outF; sub = $outS; derivative = $outD; line = $line }
  }
  if (@($Paging.unpaged).Count -eq 0) {
    $derivSet = @{}
    foreach ($d in $Derivative) { $derivSet[[string]$d] = $true }
    foreach ($x in $Findings) { if ($derivSet.ContainsKey([string]$x)) { [void]$outS.Add([string]$x) } else { [void]$outF.Add([string]$x) } }
    $line = ('RUN RECORD: capture-run [' + $Kind + '] exit 1 - every failed lane paged as itself: ' + (@($Paging.paged) -join '; ') + '. Nothing sent from here.')
    return [pscustomobject]@{ findings = $outF; sub = $outS; derivative = $outD; line = $line }
  }
  $newRR = ('RUN RECORD: capture-run [' + $Kind + '] exit 1 - failed lane(s) with no page of their own: ' + (@($Paging.unpaged) -join ', '))
  if (@($Paging.paged).Count) { $newRR += (' (paged as themselves: ' + (@($Paging.paged) -join '; ') + ')') }
  foreach ($x in $Findings) { if ([string]$x -eq $RunRecordText) { [void]$outF.Add($newRR) } else { [void]$outF.Add([string]$x) } }
  foreach ($d in $Derivative) { if ([string]$d -eq $RunRecordText) { [void]$outD.Add($newRR) } else { [void]$outD.Add([string]$d) } }
  return [pscustomobject]@{ findings = $outF; sub = $outS; derivative = $outD; line = $line }
}

function Merge-AdRunRecord {
  <#
    .SYNOPSIS The 07:00 [ad] run's RUN RECORD gets the same paged-lane fold as the daily one (2026-09-25, item 2026-09-23-822c30).
    .DESCRIPTION
      Pure. Until this, only the daily record went through Merge-PagedLaneFindings; the ad record went straight into the
      findings, so on 09-24 (push, paged 'Grocery pipeline could not push') and 09-25 (sync, paged 'Grocery bot checkout
      sync degraded at the push') the watchdog paged RUN RECORD [ad] for a lane that had already paged as itself. The ad
      text is its own derivative here, so no other finding is moved. Returns findings and the transcript line.
  #>
  param($Findings, $Record, [string]$RunRecordText)
  $m = Merge-PagedLaneFindings $Findings @($RunRecordText) (Get-FailedLanePaging $Record) $RunRecordText 'ad'
  return [pscustomobject]@{ findings = $m.findings; line = $m.line }
}

function Get-WatchdogAlertPlan {
  <#
    .SYNOPSIS Which alerts one watchdog run sends (2026-09-10, design\PLAN-zero-alert-days-2026-09-10.md Phase 1).
    .DESCRIPTION
      Pure. Merge-HeldFindings already makes a guards hold ONE finding; this separates that finding from everything
      the hold did not cause. The hold goes out on its own subject with -CausedBy guards-hold, so send-alert absorbs
      it into the open GUARDS FAILED item, or mints it normally when there is none. Every other finding goes out as
      the watchdog alert it always was, so an independent failure on a red morning still mints its own item. Not
      held: one alert carrying every finding, exactly as before.
  #>
  param($Findings, [bool]$Held, [string]$HeldText)
  $ind = New-Object System.Collections.Generic.List[string]
  $hold = $false
  foreach ($f in $Findings) {
    if ($Held -and $HeldText -and [string]$f -eq $HeldText) { $hold = $true } else { [void]$ind.Add([string]$f) }
  }
  return [pscustomobject]@{ hold = $hold; independent = $ind }
}

function Test-FlagStoreCold {
  <#
    .SYNOPSIS Is a store named on a capture flag actually still uncaptured?
    .DESCRIPTION
      Pure, so the -SelfTest fixtures below can drive it with frozen dates.

      TWO STANDARDS WERE FIGHTING (2026-08-30, queue 2026-08-30-40c75d). Check 6b called a store COLD when
      it had no rows dated TODAY, while the per-store scan twenty lines up grades the SAME store against
      the 90-day rotation - and prints lines like "Aldi: 0 fresh rows today, newest 2026-08-29 (1d of 90d
      carry)" as OK on the same run. A flag is a TODO, capture-run writes a new one every day, nothing
      deletes one before the 45-day prune, so ONE store not yet reached by 09:32 relit all ten flags on
      disk: 8 unworked, oldest 9 days, "still cold: Aldi" - on a day Aldi was one day old and inside every
      band. That is the alarm-that-accuses-healthy-things class this very check was rewritten for on
      2026-08-25, one standard short.

      A store is COLD only when BOTH are true: nothing has been captured since the flag was written (so
      the todo really is outstanding), AND its newest capture is past the same ROTATION_DEBT band the
      per-store scan uses. A store with no readable capture date at all is COLD - unprovable is not done,
      and this check must never excuse itself on data it failed to read.
  #>
  param([string]$NewestCapture, [datetime]$FlagWritten, [datetime]$Now, [int]$RotationDebtDays)
  if (-not $NewestCapture) { return $true }
  $n = [datetime]'1900-01-01'
  if (-not [datetime]::TryParse($NewestCapture, [ref]$n)) { return $true }
  if ($n.Date -ge $FlagWritten.Date) { return $false }
  return ((($Now.Date - $n.Date).TotalDays) -gt $RotationDebtDays)
}

function Test-FlagWorked {
  <#
    .SYNOPSIS Has every store this flag names been captured since the flag was written?
    .DESCRIPTION
      Pure. A flag is a todo with no completion mechanism - that is the whole defect. This is the
      completion test, and it is STRICTER than the cold test on purpose: a store merely inside its
      rotation band has not had this todo worked, it is just not late yet, so the flag stays on disk.
      Only a flag whose every store carries a capture at or after the flag date is finished and deleted.
  #>
  param([string[]]$Stores, $NewestByStore, [datetime]$FlagWritten)
  if (-not @($Stores).Count) { return $false }
  foreach ($s in @($Stores)) {
    $v = [string]$NewestByStore[[string]$s]
    if (-not $v) { return $false }
    $n = [datetime]'1900-01-01'
    if (-not [datetime]::TryParse($v, [ref]$n)) { return $false }
    if ($n.Date -lt $FlagWritten.Date) { return $false }
  }
  return $true
}

function Measure-CursorAdvances {
  <#
    How many times a store advanced its term cursor since $Since, read off capture-cursor-log.jsonl.
    PURE, and lifted out of the watcher below so -SelfTest can drive it with frozen lines instead of a
    live log - the same reason compute-v2's package decision is a function. A cadence check whose only
    test is "run it and see" is a check nobody can prove fires.
    A line that does not parse, or carries no readable timestamp, is SKIPPED rather than counted: this
    number is used to decide that a window is MISSING, so an unreadable line must not manufacture one.
  #>
  param([string[]]$Lines, [Parameter(Mandatory)][string]$Store, [Parameter(Mandatory)][datetime]$Since)
  $n = 0
  foreach ($ln in @($Lines)) {
    if (-not ("$ln").Trim()) { continue }
    $rec = $null; try { $rec = "$ln" | ConvertFrom-Json } catch { continue }
    if ([string]$rec.store -ne $Store) { continue }
    $at = [datetime]'1900-01-01'
    if (-not [datetime]::TryParse([string]$rec.at, [ref]$at)) { continue }
    if ($at -ge $Since) { $n++ }
  }
  return $n
}

# ---- 7, 8 AND 9: THE BOT CHECKOUT FLOORS (2026-09-23, design\PLAN-bot-checkout-self-heal-2026-09-23.md W1.1) ----------
# WHY. On 2026-09-23 the daily run executed on a checkout about 14 hours behind origin, so a fix that had landed the night
# before was not running, and two days of captures sat uncommitted because each refused commit made the next one bigger.
# Both quantities grew for a day and a half and nothing paged: every other check here reads what capture-run DID, and a
# run that never syncs or never commits leaves nothing new to read. These three read git and the filesystem of the
# watchdog's own checkout instead, so they still fire when capture-run has stopped running at all. They WRITE nothing:
# every git call carries --no-optional-locks, because the 10:30 task runs in the shared main checkout while sessions
# commit there, and a read that refreshed the index would be a write.
# 93,600 s is 26 h: one daily cadence plus 2 h of slack, the same shape and size as $script:BoardStaleHours above. The
# first plausible number, not the survivor of a sweep. When the producer (capture-run) stops, this still fires: origin
# keeps moving and the age of the oldest missing commit keeps growing.
$script:CheckoutStaleBarSec = 93600
# The backlog is graded only from 10:00 local, when the 07:00 ad run and the 08:00 daily run have each had their chance to
# commit yesterday's files. The first plausible time, not a sweep. Before it the answer is NOT CHECKED, never ok.
$script:BacklogDueAt = [timespan]::FromHours(10)

function Invoke-WdGit {
  <# git -C <Repo> --no-optional-locks <GitArgs> through Invoke-GitCaptured (lib\git-blob-lib.ps1): both streams kept,
     no redirect under EAP=Stop, never throws. Returns @{ rc; stdout; stderr }. #>
  param([Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][string[]]$GitArgs)
  return (Invoke-GitCaptured -Repo $Repo -GitArgs (@('--no-optional-locks') + @($GitArgs)))
}

function Get-WdGitCommonDir([string]$Repo) {
  # The shared git directory (the main checkout's .git, from any linked worktree), absolute, or '' when git cannot say.
  $r = Invoke-WdGit -Repo $Repo -GitArgs @('rev-parse', '--path-format=absolute', '--git-common-dir')
  if ($r.rc -ne 0) { return '' }
  $p = ([string]$r.stdout).Trim()
  if (-not $p) { return '' }
  return ($p -replace '/', '\')
}

function Get-WdCaptureDateOf([string]$Path) {
  <# The capture date a path is named for: the LAST yyyy-MM-dd in it, else a yyyyMMdd directly before -HHmmss, else ''.
     The same two expressions as the plan's prototype (sync-proto.ps1 blob 3ddd9f98c415), which W2.1 ports into
     grocery\commit-size-lib.ps1 as Get-CaptureDateOf. This is a copy until that lib lands, and the self-test pins its
     answers so a drift between the two is a red, not a surprise. #>
  $m = [regex]::Matches([string]$Path, '(?<!\d)(20\d\d)-(\d\d)-(\d\d)(?!\d)')
  if ($m.Count) { $g = $m[$m.Count - 1].Groups; return ($g[1].Value + '-' + $g[2].Value + '-' + $g[3].Value) }
  $m = [regex]::Matches([string]$Path, '(?<!\d)(20\d\d)(\d\d)(\d\d)(?=-\d{6})')
  if ($m.Count) { $g = $m[$m.Count - 1].Groups; return ($g[1].Value + '-' + $g[2].Value + '-' + $g[3].Value) }
  return ''
}

function Get-WdShortSha([string]$Sha) { if ($Sha.Length -ge 8) { return $Sha.Substring(0, 8) } else { return $Sha } }
function Format-WdAge([long]$Sec) { return ('{0:N0} s ({1:N1} h)' -f $Sec, ($Sec / 3600.0)) }

function Get-WdLastSyncText([string]$CommonDir) {
  <# One clause naming the last checkout sync's outcome and why, read from <git common dir>\tc-checkout-sync.json, the
     record lib\checkout-sync.ps1 (W3.1) keeps. Absent, unreadable, and an intent with no outcome (a sync that may have
     died mid-move) each say so. Field presence is asked of PSObject.Properties, never inferred from $null. Never throws. #>
  if (-not $CommonDir) { return 'last sync: unknown (git named no common dir)' }
  $p = Join-Path $CommonDir 'tc-checkout-sync.json'
  if (-not (Test-Path -LiteralPath $p)) { return 'last sync: no record (lib\checkout-sync.ps1 has not run in this checkout)' }
  $d = $null
  try { $d = ConvertFrom-Json ([IO.File]::ReadAllText($p, [Text.Encoding]::UTF8)) } catch { return ('last sync: its record ' + $p + ' is unreadable (' + $_.Exception.Message + ')') }
  if ($null -eq $d) { return ('last sync: its record ' + $p + ' is empty') }
  $fields = @{}
  foreach ($n in @('outcome', 'class', 'why', 'phase', 'pid', 'finished', 'ts', 'updated', 'started')) {
    $pp = $d.PSObject.Properties[$n]
    $fields[$n] = if ($pp -and $null -ne $pp.Value) { [string]$pp.Value } else { '' }
  }
  $when = ''
  foreach ($n in @('finished', 'ts', 'updated', 'started')) { if ($fields[$n]) { $when = $fields[$n]; break } }
  if (-not $fields['outcome']) {
    return ('last sync: an intent with no outcome (pid ' + $fields['pid'] + ', phase ' + $fields['phase'] + ', started ' + $fields['started'] + '), so a sync may have died mid-move')
  }
  $t = 'last sync: ' + $fields['outcome']
  if ($fields['class']) { $t += (' class ' + $fields['class']) }
  $t += (' (phase ' + $fields['phase'] + ', ' + $when + ')')
  if ($fields['why']) { $t += (': ' + $fields['why']) }
  return $t
}

function Get-CheckoutFloor {
  <#
    CHECK 7, CHECKOUT. Does the checkout at -Repo contain origin/main, and if not, how old is the oldest commit it lacks?
      1. `git ls-remote origin refs/heads/main`, the remote's own word, which writes nothing here. A non-zero rc is the
         finding `CHECKOUT: BLIND - ls-remote exited <rc>`, never a pass, and the local checks below still run.
      2. `git merge-base --is-ancestor refs/remotes/origin/main HEAD`: rc 0 is ok, rc 1 is behind, anything else BLIND.
      3. Behind: the first line of `git rev-list --reverse refs/remotes/origin/main --not HEAD` is the oldest missing
         commit and its %ct is its age against -Now. MORE than -BarSec (93,600 s) is BOT CHECKOUT STALE, with the last
         sync outcome and why from <git common dir>\tc-checkout-sync.json. Exactly at the bar is not stale.
    NOTHING HERE FETCHES, so the count is against the LOCAL refs/remotes/origin/main, which every session's push-main
    fetch on this box updates. When ls-remote's tip is not that ref, the line says so: a stale local ref can only
    understate the age. Returns findings, ok lines and one CHECKOUT-FLOOR marker line that
    grocery\report-checkout-sync.ps1 reads for bar B9. -Now is the clock seam; the fixtures pass an exact epoch.
  #>
  param([Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][datetime]$Now, [int]$BarSec = 0)
  if ($BarSec -le 0) { $BarSec = $script:CheckoutStaleBarSec }
  $fl = New-Object System.Collections.Generic.List[string]
  $okL = New-Object System.Collections.Generic.List[string]
  $res = [pscustomobject]@{ findings = $fl; ok = $okL; behind = -1; age_s = [long]-1; stale = $false; remote = 'unread'; blind = 0; marker = '' }
  $mark = {
    $res.blind = @($fl | Where-Object { ([string]$_).StartsWith('CHECKOUT: BLIND') }).Count
    $res.marker = ('CHECKOUT-FLOOR behind={0} oldest_age_s={1} bar_s={2} stale={3} remote={4} blind={5}' -f $res.behind, $res.age_s, $BarSec, $(if ($res.stale) { 1 } else { 0 }), $res.remote, $res.blind)
  }
  # A credential prompt would hang an unattended run, and a stalled transfer would too: both are refused for this one
  # call and the environment is put back exactly as it was ($null removes the variable again).
  $prevTp = $env:GIT_TERMINAL_PROMPT; $prevGcm = $env:GCM_INTERACTIVE
  try {
    $env:GIT_TERMINAL_PROMPT = '0'; $env:GCM_INTERACTIVE = 'never'
    $ls = Invoke-WdGit -Repo $Repo -GitArgs @('-c', 'http.lowSpeedLimit=1', '-c', 'http.lowSpeedTime=60', 'ls-remote', 'origin', 'refs/heads/main')
  } finally { $env:GIT_TERMINAL_PROMPT = $prevTp; $env:GCM_INTERACTIVE = $prevGcm }
  $remoteTip = ''
  if ($ls.rc -ne 0) {
    $errL = @(([string]$ls.stderr) -split "`r?`n" | Where-Object { $_.Trim() })
    $why = if ($errL.Count) { ' (' + $errL[0].Trim() + ')' } else { '' }
    [void]$fl.Add('CHECKOUT: BLIND - ls-remote exited ' + $ls.rc + $why + '. The remote could not be read, so whether it has moved past this checkout is unknown this run, not clean.')
    $res.remote = 'blind'
  } else {
    $mt = [regex]::Match([string]$ls.stdout, '(?m)^([0-9a-f]{40})\trefs/heads/main\s*$')
    if ($mt.Success) { $remoteTip = $mt.Groups[1].Value }
    else { [void]$fl.Add('CHECKOUT: BLIND - ls-remote exited 0 but origin named no refs/heads/main, so whether the remote has moved past this checkout is unknown this run.'); $res.remote = 'blind' }
  }
  $lr = Invoke-WdGit -Repo $Repo -GitArgs @('rev-parse', '--verify', '-q', 'refs/remotes/origin/main^{commit}')
  $localTip = if ($lr.rc -eq 0) { ([string]$lr.stdout).Trim() } else { '' }
  if (-not $localTip) {
    [void]$fl.Add('CHECKOUT: BLIND - this checkout has no refs/remotes/origin/main (rev-parse exited ' + $lr.rc + '), so nothing here can say how far behind origin it is.')
    & $mark; return $res
  }
  $note = ''
  if ($remoteTip) {
    if ([string]::Equals($remoteTip, $localTip, [StringComparison]::Ordinal)) { $res.remote = 'same' }
    else {
      $res.remote = 'moved'
      $note = (" The remote's main is at " + (Get-WdShortSha $remoteTip) + ", not this checkout's refs/remotes/origin/main " + (Get-WdShortSha $localTip) + ': nothing here fetches, so this is counted against the local ref and can only understate how far behind the checkout is.')
    }
  } elseif ($res.remote -eq 'blind') {
    $note = ' Counted against the local refs/remotes/origin/main, which can only understate how far behind the checkout is.'
  }
  $anc = Invoke-WdGit -Repo $Repo -GitArgs @('merge-base', '--is-ancestor', 'refs/remotes/origin/main', 'HEAD')
  if ($anc.rc -eq 0) {
    $res.behind = 0
    [void]$okL.Add('checkout: HEAD contains origin/main ' + (Get-WdShortSha $localTip) + '.' + $note)
    & $mark; return $res
  }
  if ($anc.rc -ne 1) {
    [void]$fl.Add('CHECKOUT: BLIND - merge-base --is-ancestor exited ' + $anc.rc + ', so whether HEAD contains origin/main is unknown this run.')
    & $mark; return $res
  }
  $rl = Invoke-WdGit -Repo $Repo -GitArgs @('rev-list', '--reverse', 'refs/remotes/origin/main', '--not', 'HEAD')
  $missing = @(([string]$rl.stdout) -split "`r?`n" | Where-Object { $_ -match '^[0-9a-f]{40}$' })
  if ($rl.rc -ne 0 -or $missing.Count -eq 0) {
    [void]$fl.Add('CHECKOUT: BLIND - HEAD does not contain origin/main but rev-list exited ' + $rl.rc + ' naming ' + $missing.Count + ' missing commit(s), so the age of the oldest is unknown this run.')
    & $mark; return $res
  }
  $oldest = $missing[0]
  $ct = Invoke-WdGit -Repo $Repo -GitArgs @('log', '-1', '--format=%ct', $oldest)
  [long]$ctN = 0
  if ($ct.rc -ne 0 -or -not [long]::TryParse(([string]$ct.stdout).Trim(), [ref]$ctN)) {
    [void]$fl.Add('CHECKOUT: BLIND - ' + $missing.Count + ' commit(s) behind origin/main, but the commit time of the oldest, ' + (Get-WdShortSha $oldest) + ', could not be read (git log exited ' + $ct.rc + ').')
    & $mark; return $res
  }
  $age = ([DateTimeOffset]$Now).ToUnixTimeSeconds() - $ctN
  $res.behind = $missing.Count; $res.age_s = $age
  if ($age -gt $BarSec) {
    $res.stale = $true
    $last = Get-WdLastSyncText (Get-WdGitCommonDir $Repo)
    [void]$fl.Add(('BOT CHECKOUT STALE: {0} commits behind, oldest missing {1} committed {2} ago, past the {3} bar; {4}.{5} capture-run runs whatever code this checkout holds, so a fix that landed on origin since then is not running. Kill switch and rollback: design\PLAN-bot-checkout-self-heal-2026-09-23.md section 11.' -f $missing.Count, (Get-WdShortSha $oldest), (Format-WdAge $age), (Format-WdAge $BarSec), $last, $note))
  } else {
    [void]$okL.Add(('checkout: {0} commit(s) behind origin/main, oldest missing {1} committed {2} ago, inside the {3} bar.{4}' -f $missing.Count, (Get-WdShortSha $oldest), (Format-WdAge $age), (Format-WdAge $BarSec), $note))
  }
  & $mark; return $res
}

function Get-CaptureBacklog {
  <#
    CHECK 8, BACKLOG. From -DueAt (10:00 local) on, every file `git ls-files -z --others --exclude-standard -- grocery/out`
    lists whose path date (Get-WdCaptureDateOf) is before -TodayS is a capture no commit has taken. Any is
    CAPTURE BACKLOG: <n> file(s), <MiB> MiB, oldest dated <date>, grouped by date. Ignored files are never listed, an
    undated path is never counted, and a path is split on NUL, so a name with a space or a quote arrives whole. Before
    -DueAt the answer is NOT CHECKED, an ok line that says so, never a clean one. -Now is the clock seam.
  #>
  param([Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][string]$TodayS, [Parameter(Mandatory)][datetime]$Now, $DueAt = $null)
  if ($null -eq $DueAt) { $DueAt = $script:BacklogDueAt }
  $fl = New-Object System.Collections.Generic.List[string]
  $okL = New-Object System.Collections.Generic.List[string]
  $res = [pscustomobject]@{ findings = $fl; ok = $okL; due = $false; files = 0; bytes = [long]0; oldest = ''; examined = 0 }
  if ($Now.TimeOfDay -lt $DueAt) {
    [void]$okL.Add(('capture backlog: NOT CHECKED at {0} - graded only from {1}, once the 07:00 and 08:00 runs have each had their chance to commit the files dated before {2}. Not clean and not a finding.' -f $Now.ToString('HH:mm:ss'), $DueAt.ToString('hh\:mm'), $TodayS))
    return $res
  }
  $res.due = $true
  $ls = Invoke-WdGit -Repo $Repo -GitArgs @('-c', 'core.quotePath=false', 'ls-files', '-z', '--others', '--exclude-standard', '--', 'grocery/out')
  if ($ls.rc -ne 0) {
    [void]$fl.Add('CAPTURE BACKLOG: BLIND - git ls-files exited ' + $ls.rc + ', so whether captures from before today are still uncommitted is unknown this run, not clean.')
    return $res
  }
  $paths = @(([string]$ls.stdout) -split [char]0 | Where-Object { $_ })
  $res.examined = $paths.Count
  $byDate = @{}
  foreach ($p in $paths) {
    $d = Get-WdCaptureDateOf $p
    if (-not $d) { continue }
    if ([string]::CompareOrdinal($d, $TodayS) -ge 0) { continue }
    [long]$len = 0
    try { $len = [long](New-Object IO.FileInfo (Join-Path $Repo $p)).Length } catch { $len = 0 }
    if (-not $byDate.ContainsKey($d)) { $byDate[$d] = [pscustomobject]@{ files = 0; bytes = [long]0 } }
    $byDate[$d].files++; $byDate[$d].bytes += $len
    $res.files++; $res.bytes += $len
  }
  if ($res.files -gt 0) {
    [string[]]$dates = @($byDate.Keys)
    [Array]::Sort($dates, [StringComparer]::Ordinal)
    $res.oldest = $dates[0]
    $parts = @(foreach ($d in $dates) { ('{0} {1} file(s) {2:N1} MiB' -f $d, $byDate[$d].files, ($byDate[$d].bytes / 1MB)) })
    [void]$fl.Add(('CAPTURE BACKLOG: {0} file(s), {1:N1} MiB, oldest dated {2} - by date: {3}. These are untracked, not-ignored files under grocery/out named for a day before {4} that no commit has taken. Each refused day adds its files to the next run''s commit, which is how 2026-09-22 and 2026-09-23 refused each other.' -f $res.files, ($res.bytes / 1MB), $res.oldest, ($parts -join '; '), $TodayS))
  } else {
    [void]$okL.Add(('capture backlog: 0 untracked file(s) under grocery/out dated before {0} ({1} untracked, not-ignored file(s) examined)' -f $TodayS, $paths.Count))
  }
  return $res
}

function Get-SyncKillSwitch {
  <#
    CHECK 9, KILL SWITCH. <git common dir>\tc-checkout-sync.disabled present is BOT CHECKOUT SYNC DISABLED since <mtime>,
    raised on EVERY run while the file exists, so a switch set for hours cannot quietly become weeks. While it exists
    lib\checkout-sync.ps1 records every sync as disabled and moves nothing (plan section 11, rollback step 1). A common
    dir git cannot name is a BLIND finding.
  #>
  param([Parameter(Mandatory)][string]$Repo)
  $fl = New-Object System.Collections.Generic.List[string]
  $okL = New-Object System.Collections.Generic.List[string]
  $res = [pscustomobject]@{ findings = $fl; ok = $okL; on = $false; path = '' }
  $cd = Get-WdGitCommonDir $Repo
  if (-not $cd) {
    [void]$fl.Add('KILL SWITCH: BLIND - git could not name this checkout''s common dir, so whether the checkout sync is disabled is unknown this run.')
    return $res
  }
  $ks = Join-Path $cd 'tc-checkout-sync.disabled'
  $res.path = $ks
  if (Test-Path -LiteralPath $ks) {
    $res.on = $true
    $mt = (Get-Item -LiteralPath $ks -Force).LastWriteTime
    [void]$fl.Add(('BOT CHECKOUT SYNC DISABLED since {0} ({1}). While it exists every capture-run checkout sync records disabled and moves nothing, so the bot keeps running on whatever HEAD it has. Delete the file to re-enable, as soon as whatever it was set for is over.' -f $mt.ToString('yyyy-MM-dd HH:mm'), $ks))
  } else {
    [void]$okL.Add('checkout sync kill switch: off (' + $ks + ' absent)')
  }
  return $res
}

if ($SelfTest) {
  # Frozen fixtures: the founding bug (a task that never runs, reported green forever) and
  # its clean twin (a task legitimately still waiting for its first slot).
  $fail = 0
  # A LITERAL-CASE SUITE ASSERTS HOW MANY RAN (2026-09-23, W1.1). Every case prints exactly one line starting 'ok',
  # 'PASS' or 'FAIL'. The cases run inside a dot-sourced block, so they share this scope (their $fail counts), and
  # every line they print is captured, re-printed unchanged and counted against this literal: 54 cases for checks 1
  # to 6a (6 of them the checkout-sync lane's run-record stages), 13 for the bot checkout floors (7 to 9). A case lost to a thrown setup or a glued line reads as a shortfall.
  # Captured with a plain dot-source, never inside @( ): audit-store-registry widens a store name to the smallest
  # multi-line array around it, and a whole suite inside one would hide every fixture's own store-subset-ok marker.
  $WD_SELFTEST_CASES = 70
  $wdStOut = . {
  $now = [datetime]'2026-08-21 06:47'

  # ---- FF SHARD CADENCE (2026-09-01, queue 2026-09-01-056e6b) ---------------------------------
  # Frozen from the real log shape. The MUST-FIRE case is the condition that actually existed on
  # 2026-09-01: one window a day where three are configured. The clean twin is the fixed state.
  # A third case pins the reason the check was unbuildable before: a log carrying every OTHER
  # store and no Family Fare line must read as ZERO windows, not as "nothing to see".
  $cadSince = [datetime]'2026-09-01 06:00'
  $ffOneWindow = @(
    '{"at":"2026-09-01T08:01:55","store":"Family Fare","from":593,"to":600,"day":"2026-09-01","caller":"capture-run.ps1","pid":1}'
  )
  $ffThreeWindows = @(
    '{"at":"2026-09-01T07:00:41","store":"Family Fare","from":579,"to":586,"day":"2026-09-01","caller":"capture-run.ps1","pid":1}',
    '{"at":"2026-09-01T08:01:55","store":"Family Fare","from":586,"to":593,"day":"2026-09-01","caller":"capture-run.ps1","pid":2}',
    '{"at":"2026-09-01T09:31:02","store":"Family Fare","from":593,"to":600,"day":"2026-09-01","caller":"capture-watchdog.ps1","pid":3}'
  )
  # the real 2026-09-01 log: six stores advancing, Family Fare absent entirely
  $ffNoneAtAll = @(
    '{"at":"2026-09-01T08:03:05","store":"Sam''s Club","from":70,"to":77,"day":"2026-09-01","caller":"build-sams-deals.ps1","pid":48676}',
    '{"at":"2026-09-01T08:03:10","store":"Fareway","from":84,"to":91,"day":"2026-09-01","caller":"build-fareway-regular.ps1","pid":44468}',
    '{"at":"2026-09-01T09:08:23","store":"Walmart","from":35,"to":42,"day":"2026-09-01","caller":"build-walmart-deals.ps1","pid":14848}'
  )
  $cadA = Measure-CursorAdvances -Lines $ffOneWindow -Store 'Family Fare' -Since $cadSince
  if ($cadA -lt 3) { Write-Output "ok    FF cadence MUST-FIRE: one window a day against three configured reads as $cadA and pages MISSING-WINDOW" }
  else { Write-Output "FAIL  FF cadence counted $cadA windows from a single advance - the 2026-09-01 condition would not page"; $fail++ }
  $cadB = Measure-CursorAdvances -Lines $ffThreeWindows -Store 'Family Fare' -Since $cadSince
  if ($cadB -eq 3) { Write-Output 'ok    FF cadence CLEAN TWIN: all three shard windows advancing reads as 3 and stays silent' }
  else { Write-Output "FAIL  FF cadence counted $cadB of 3 healthy windows - a working cadence would page every day and be muted"; $fail++ }
  $cadC = Measure-CursorAdvances -Lines $ffNoneAtAll -Store 'Family Fare' -Since $cadSince
  if ($cadC -eq 0) { Write-Output 'ok    FF cadence reads a log full of OTHER stores as zero Family Fare windows (the state that made this check unbuildable until pull-regular-familyfare started logging)' }
  else { Write-Output "FAIL  FF cadence counted $cadC Family Fare windows in a log with none - it is matching the wrong store"; $fail++ }
  $cadD = Measure-CursorAdvances -Lines @('not json at all', '{"at":"","store":"Family Fare"}') -Store 'Family Fare' -Since $cadSince
  if ($cadD -eq 0) { Write-Output 'ok    FF cadence skips an unparseable line rather than counting it (an unreadable line must not invent a window)' }
  else { Write-Output "FAIL  FF cadence counted $cadD window(s) from unreadable lines"; $fail++ }

  # MUST FIRE: registered four days ago, still never run.
  if (-not (Test-NeverRanTooLong -TriggerStart ([datetime]'2026-08-17 07:00') -Now $now)) {
    Write-Output 'FAIL  a task registered 4 days ago that never fired read as ok - the gate cannot arm'; $fail++
  } else { Write-Output 'ok    4-day-old never-run task is a finding' }

  # CLEAN TWIN: registered yesterday after its own slot; its first real chance is today.
  if (Test-NeverRanTooLong -TriggerStart ([datetime]'2026-08-20 07:00') -Now $now) {
    Write-Output 'FAIL  a task still inside its first cycle was called broken - day-one false alarm'; $fail++
  } else { Write-Output 'ok    task still inside its first cycle stays ok' }

  # An unreadable trigger must not manufacture a finding.
  if (Test-NeverRanTooLong -TriggerStart ([datetime]'1999-11-30') -Now $now) {
    Write-Output 'FAIL  an unknown trigger start produced a finding out of nothing'; $fail++
  } else { Write-Output 'ok    unknown trigger start -> no invented finding' }

  # ---- board freshness (2026-08-30, queue 2026-08-22-fe7b43) ----------------------------------------
  # FROZEN, not read from out\. The whole defect was a check that consulted a rotating filename, so a
  # fixture rebuilt from the live board on the day of the run would encode whatever the ad cycle happened
  # to be doing and could pass by finding nothing.
  $bNow = [datetime]'2026-08-30 09:30'

  # MUST FIRE: the real failing shape. A board that has not been rebuilt since the morning before.
  if (-not (Test-BoardStale -BoardWritten ([datetime]'2026-08-29 06:10') -Now $bNow)) {
    Write-Output 'FAIL  a board last written 27.3 h ago read as fresh - the staleness gate cannot arm'; $fail++
  } else { Write-Output 'ok    a board 27.3 h old is a finding' }

  # CLEAN TWIN: the exact 08-27..08-30 shape that made the OLD check fire every day. comparison-2026-08-26
  # is named four days back because the board takes the newest ADS file's name, and it was rebuilt at
  # 14:45 the previous afternoon. Filename old, board fresh, watchdog must stay silent.
  if (Test-BoardStale -BoardWritten ([datetime]'2026-08-29 14:45') -Now $bNow) {
    Write-Output 'FAIL  comparison-2026-08-26 rebuilt 18.8 h ago was called stale - the ad-cycle false positive is back'; $fail++
  } else { Write-Output 'ok    a 4-day-old FILENAME with an 18.8 h-old rebuild stays silent' }

  # AT THE BAR (2026-09-19, backlog I196). The two cases above sit 7.2 h inside and 1.3 h past the bar, so
  # neither could see whether the comparison is inclusive: -gt and -ge passed them both. The bar is how
  # old a board MAY be, so a board exactly $BoardStaleHours old is still fresh and one minute more is not.
  # MUST NOT FIRE: exactly at the bar.
  if (Test-BoardStale -BoardWritten $bNow.AddHours(-$script:BoardStaleHours) -Now $bNow) {
    Write-Output "FAIL  a board exactly $($script:BoardStaleHours).0 h old read as stale - the bar is inclusive of the age it allows"; $fail++
  } else { Write-Output "ok    a board exactly $($script:BoardStaleHours).0 h old is still fresh (at the bar)" }
  # MUST FIRE: one minute past the bar.
  if (-not (Test-BoardStale -BoardWritten $bNow.AddHours(-$script:BoardStaleHours).AddMinutes(-1) -Now $bNow)) {
    Write-Output "FAIL  a board one minute past the $($script:BoardStaleHours) h bar read as fresh"; $fail++
  } else { Write-Output "ok    a board one minute past the $($script:BoardStaleHours) h bar is a finding" }

  # The bar sits under two cadences, so a dead day cannot hide behind yesterday's output.
  if ($script:BoardStaleHours -ge 48) {
    Write-Output 'FAIL  the staleness window is at least two capture cadences wide - a skipped day would be alibied by the previous one'; $fail++
  } else { Write-Output 'ok    staleness window is narrower than two cadences' }

  # ---- browser-work flags (2026-08-30, queue 2026-08-30-40c75d) --------------------------------------
  # FROZEN, not read from out\browser-capture-due-*.flag. The flags on disk are rewritten daily and the
  # captures behind them move every few hours, so a fixture built from the live tree would encode whatever
  # the browser agent happened to have finished that morning and could pass by finding nothing.
  $fNow = [datetime]'2026-08-30 09:32'
  $fFlag = [datetime]'2026-08-21 09:00'   # the oldest flag actually on disk that morning
  $rot = 30                               # ROTATION_DEBT_DAYS = QUARTER_DAYS / 3

  # MUST FIRE: the real freeze. 2026-08-22..25, when the browser stores went uncaptured for days and the
  # old routine had been retired - nothing since the flag AND past the rotation band.
  if (-not (Test-FlagStoreCold -NewestCapture '2026-07-14' -FlagWritten $fFlag -Now $fNow -RotationDebtDays $rot)) {
    Write-Output 'FAIL  a store with no capture since the flag and 47 days old read as worked - a real freeze is now invisible'; $fail++
  } else { Write-Output 'ok    a store 47 days stale with nothing since the flag is still COLD' }

  # MUST FIRE: a store the flag names that has no capture date at all. Unprovable is not done.
  if (-not (Test-FlagStoreCold -NewestCapture '' -FlagWritten $fFlag -Now $fNow -RotationDebtDays $rot)) {
    Write-Output 'FAIL  a store with NO readable capture date read as worked - the check excused itself on data it could not read'; $fail++
  } else { Write-Output 'ok    a store with no readable capture date is COLD, not excused' }

  # CLEAN TWIN: today's real shape. Aldi, newest 2026-08-29, one day old, not captured since a 08-21 flag
  # but nowhere near the rotation band. This is the exact row that lit BROWSER WORK STALE on a healthy day.
  if (Test-FlagStoreCold -NewestCapture '2026-08-29' -FlagWritten $fFlag -Now $fNow -RotationDebtDays $rot) {
    Write-Output 'FAIL  Aldi at 1 day old was called cold - the daily-freshness bar is back and it contradicts the rotation bands'; $fail++
  } else { Write-Output 'ok    a store 1 day old is not cold, the same verdict the per-store scan prints' }

  # CLEAN TWIN: captured AFTER the flag - the todo was worked, whatever its age band says.
  if (Test-FlagStoreCold -NewestCapture '2026-08-30' -FlagWritten $fFlag -Now $fNow -RotationDebtDays $rot) {
    Write-Output 'FAIL  a store captured after the flag was still called cold - the watchdog cannot see the work it asked for'; $fail++
  } else { Write-Output 'ok    a store captured after the flag is worked' }

  # COMPLETION: every store newer than the flag = a finished todo, and only then is the flag deleted.
  # store-subset-ok: a frozen newest-capture table for Test-FlagWorked inside this guard's own -SelfTest; the flag arithmetic compares dates per named store and never branches on which store, so three sample stores (one deliberately stale) prove it for all seven
  $nbs = @{ 'Walmart' = '2026-08-30'; 'Aldi' = '2026-08-29'; 'Fareway' = '2026-08-30' }
  if (-not (Test-FlagWorked -Stores @('Walmart', 'Fareway') -NewestByStore $nbs -FlagWritten ([datetime]'2026-08-29 09:00'))) {
    Write-Output 'FAIL  a flag whose every store was captured after it was written did not read as finished - flags never die'; $fail++
  } else { Write-Output 'ok    a flag whose every store has a newer capture is a finished todo' }
  if (Test-FlagWorked -Stores @('Walmart', 'Aldi') -NewestByStore $nbs -FlagWritten ([datetime]'2026-08-30 09:00')) {
    Write-Output 'FAIL  a flag with one store still uncaptured was deleted as finished - the todo would vanish unworked'; $fail++
  } else { Write-Output 'ok    a flag with one store still uncaptured is NOT deleted' }
  if (Test-FlagWorked -Stores @() -NewestByStore $nbs -FlagWritten $fFlag) {
    Write-Output 'FAIL  an unparseable flag naming no store read as finished - a file it could not read would be deleted'; $fail++
  } else { Write-Output 'ok    a flag naming no store is never treated as finished' }

  # ---- Test-RunSuperseded: a non-zero exit judged on OUTCOME, not on the exit code ---------------------
  # THE FOUNDING DAY, to the minute. 2026-08-31: the 08:00 task exited 1 because guards refused to publish
  # (the same log says "lanes run=3 failed=0"), the blocker was cleared, and the board was rebuilt 09:26 and
  # published. At 09:32 this watchdog emailed "FAILED" about a board that was live and correct.
  $r0800 = [datetime]'2026-08-31 08:00'
  if (Test-RunSuperseded -RunAt $r0800 -BoardWritten ([datetime]'2026-08-31 09:26') -PublishedWritten ([datetime]'2026-08-31 09:28')) {
    Write-Output 'ok    a run whose board was rebuilt and shipped after it reads as SUPERSEDED'
  } else { Write-Output 'FAIL  the founding case still reads as a live failure - the 09:30 email contradicts its own healthy lines'; $fail++ }
  # MUST-FIRE TWINS: the states that are genuinely still broken and must keep paging.
  if (Test-RunSuperseded -RunAt $r0800 -BoardWritten ([datetime]'2026-08-31 07:10') -PublishedWritten ([datetime]'2026-08-31 07:12')) {
    Write-Output 'FAIL  a board OLDER than the failed run was accepted as superseding it'; $fail++
  } else { Write-Output 'ok    a board older than the failed run supersedes nothing' }
  if (Test-RunSuperseded -RunAt $r0800 -BoardWritten ([datetime]'2026-08-31 09:26') -PublishedWritten ([datetime]'2026-08-30 09:28')) {
    Write-Output 'FAIL  rebuilt-but-never-published counted as superseded - that is the exact defect section 4 exists for'; $fail++
  } else { Write-Output 'ok    a board rebuilt but NOT shipped does not supersede a failure' }
  if (Test-RunSuperseded -RunAt $r0800 -BoardWritten $null -PublishedWritten ([datetime]'2026-08-31 09:28')) {
    Write-Output 'FAIL  a missing board read as superseding'; $fail++
  } else { Write-Output 'ok    a missing board supersedes nothing (unprovable is not resolved)' }
  # CLEAN TWIN: publish a few minutes BEFORE the board write still counts - the ship path writes
  # public\board.json and the comparison seconds apart and their order is not guaranteed, which is the same
  # 30-minute slack section 4 already allows. Without it every healthy day would read as a live failure.
  if (Test-RunSuperseded -RunAt $r0800 -BoardWritten ([datetime]'2026-08-31 09:26') -PublishedWritten ([datetime]'2026-08-31 09:25')) {
    Write-Output 'ok    a publish minutes either side of the board write still counts as shipped'
  } else { Write-Output 'FAIL  the publish/board write-order slack is gone - healthy days will page'; $fail++ }

  # ---- Test-HeldByGuards + the fold: four probes of one held board -----------------------------------
  # THE FROZEN 2026-09-07 MORNING, to the minute and to the artifact. guards hard-failed at 08:14:24 on
  # the band-censorship ratchet, check-ad-cycles wrote {date 2026-09-07, written 08:14:24, guards_rc 2,
  # guards_blocked true}, capture-run staged inputs only and exited 1 at 08:34, public\board.json stayed
  # on the 09-06 bytes and the exported feed sat unstaged. At 10:30 this file emailed FOUR issues.
  $hv = [pscustomobject]@{ date = '2026-09-07'; written = '2026-09-07T08:14:24'; guards_rc = 2; guards_blocked = $true }
  $hBoard = [datetime]'2026-09-07 08:10:20'      # the board guards refused
  $hPubOld = [datetime]'2026-09-06 12:07:00'     # public\board.json, still yesterday's
  # MUST FIRE - the founding morning.
  if (Test-HeldByGuards -Verdict $hv -Today '2026-09-07' -BoardWritten $hBoard -PublishedWritten $hPubOld) {
    Write-Output 'ok    a same-day guards refusal with nothing shipped since reads as HELD BY GUARDS'
  } else { Write-Output 'FAIL  the founding morning is not recognised as a guards hold - one held board pages as four issues again'; $fail++ }
  # MUST NOT FIRE - guards were GREEN and the board never shipped. That is the real, separate defect
  # section 4 exists for, and folding it away would delete the alert this watchdog is most for.
  $hvGreen = [pscustomobject]@{ date = '2026-09-07'; written = '2026-09-07T08:14:24'; guards_rc = 0; guards_blocked = $false }
  if (Test-HeldByGuards -Verdict $hvGreen -Today '2026-09-07' -BoardWritten $hBoard -PublishedWritten $hPubOld) {
    Write-Output 'FAIL  a GREEN board that never shipped was folded away as a guards hold - the rebuilt-but-never-published defect would go silent'; $fail++
  } else { Write-Output 'ok    a green board that never shipped still pages on its own' }
  # MUST NOT FIRE - yesterday's refusal. Same same-day rule push-data.ps1 and capture-run.ps1 key on.
  $hvOld = [pscustomobject]@{ date = '2026-09-06'; written = '2026-09-06T08:14:24'; guards_rc = 2; guards_blocked = $true }
  if (Test-HeldByGuards -Verdict $hvOld -Today '2026-09-07' -BoardWritten $hBoard -PublishedWritten $hPubOld) {
    Write-Output 'FAIL  a verdict from ANOTHER DAY silenced today - a stale chain-verdict would mute the watchdog indefinitely'; $fail++
  } else { Write-Output 'ok    a verdict dated another day is ignored' }
  # MUST NOT FIRE - no verdict file at all (absent or unparseable reads as null).
  if (Test-HeldByGuards -Verdict $null -Today '2026-09-07' -BoardWritten $hBoard -PublishedWritten $hPubOld) {
    Write-Output 'FAIL  a missing chain-verdict was treated as a hold'; $fail++
  } else { Write-Output 'ok    no verdict on disk changes nothing' }
  # CLEAN TWIN - this afternoon: round 1 rebuilt at 11:28 and published at 11:47, so the hold was
  # cleared. The fold must switch itself off, and the 08:00 exit 1 goes back to reading SUPERSEDED
  # through the founding 2026-08-31 case above.
  if (Test-HeldByGuards -Verdict $hv -Today '2026-09-07' -BoardWritten ([datetime]'2026-09-07 11:28:28') -PublishedWritten ([datetime]'2026-09-07 11:47:33')) {
    Write-Output 'FAIL  a board rebuilt and shipped after the refusal still read as held - the fold would outlive the hold'; $fail++
  } else { Write-Output 'ok    a board rebuilt and shipped after the refusal is no longer held' }

  # THE FOLD ITSELF, over the four lines that were actually emailed at 10:34.
  $fFind = New-Object System.Collections.Generic.List[string]
  [void]$fFind.Add('RUN RECORD: capture-run [daily] completed with exit 1 - see the log')
  [void]$fFind.Add("NOT PUBLISHED: public\board.json is 1203 min older than today's comparison. The board was rebuilt but never shipped.")
  [void]$fFind.Add("FAILED: 'TC Grocery Daily Capture 0800' last run 2026-09-07 08:00:01 exited 1, and no board has been rebuilt and published since. The live page is NOT carrying that run's work.")
  [void]$fFind.Add('COMPUTED BUT NOT SHIPPED:  M public/smp-feed.json are modified in the working tree after today.')
  $fDeriv = New-Object System.Collections.Generic.List[string]
  foreach ($x in $fFind) { [void]$fDeriv.Add($x) }
  $fHeld = Merge-HeldFindings $fFind $fDeriv $true 'HELD BY GUARDS: check-ad-cycles refused the 08:14 board (guards_rc 2) and nothing has shipped since.'
  # MUST FIRE: four issues become one, and the one names the cause.
  if ($fHeld.findings.Count -eq 1 -and $fHeld.sub.Count -eq 4 -and $fHeld.findings[0] -match 'HELD BY GUARDS' -and $fHeld.findings[0] -match '08:14' -and $fHeld.findings[0] -match 'guards_rc 2') {
    Write-Output 'ok    the four derivative lines fold into ONE finding that names the cause (4 -> 1, all 4 kept as sub-lines)'
  } else { Write-Output ("FAIL  the fold did not collapse the founding four: findings=" + $fHeld.findings.Count + " sub=" + $fHeld.sub.Count); $fail++ }
  # CLEAN TWIN: a finding that is NOT derivative of the hold survives the fold at top level, or a real
  # unrelated failure would be buried on exactly the day something else also went wrong.
  $fFind2 = New-Object System.Collections.Generic.List[string]
  foreach ($x in $fDeriv) { [void]$fFind2.Add($x) }
  [void]$fFind2.Add('PAID CONTENT SERVED FREE: 3 live recipe(s) disagree with recipes-db about who may read them.')
  $fHeld2 = Merge-HeldFindings $fFind2 $fDeriv $true 'HELD BY GUARDS: check-ad-cycles refused the 08:14 board (guards_rc 2) and nothing has shipped since.'
  if ($fHeld2.findings.Count -eq 2 -and ($fHeld2.findings -join '|') -match 'PAID CONTENT SERVED FREE') {
    Write-Output 'ok    an unrelated finding survives the fold at top level'
  } else { Write-Output ("FAIL  the fold swallowed an unrelated finding: findings=" + $fHeld2.findings.Count); $fail++ }
  # MUST NOT FIRE: not held, so nothing moves and the list is returned exactly as it came in.
  $fPlain = Merge-HeldFindings $fFind2 $fDeriv $false 'unused'
  if ($fPlain.findings.Count -eq 5 -and $fPlain.sub.Count -eq 0) {
    Write-Output 'ok    on a day with no hold the findings list is untouched (5 in, 5 out, 0 folded)'
  } else { Write-Output ("FAIL  the fold ran on a day with no guards hold: findings=" + $fPlain.findings.Count + " sub=" + $fPlain.sub.Count); $fail++ }

  # ---- RUN RECORD PAGES ONLY A LANE THAT DID NOT PAGE AS ITSELF (2026-09-22, item 2026-09-22-7c932a) ----
  $rrTxt = 'RUN RECORD: capture-run [daily] completed with exit 1 - see the log'
  $rrCnsd = 'COMPUTED BUT NOT SHIPPED:  M public/board.json are modified in the working tree after today.'
  # MUST FIRE: the 09-12 day. build-samsclub failed and paged nothing, so RUN RECORD pages and names it.
  $rrF1 = New-Object System.Collections.Generic.List[string]; [void]$rrF1.Add($rrTxt)
  $rrRec1 = [pscustomobject]@{ exit_code = 1; failed_lanes = @([pscustomobject]@{ lane = 'build-samsclub'; paged = '' }) }
  $rrM1 = Merge-PagedLaneFindings $rrF1 $rrF1 (Get-FailedLanePaging $rrRec1) $rrTxt 'daily'
  if ($rrM1.findings.Count -eq 1 -and $rrM1.findings[0] -match 'failed lane\(s\) with no page of their own: build-samsclub' -and -not $rrM1.line) {
    Write-Output 'ok    MUST FIRE a failed lane with no page of its own (build-samsclub, 09-12) pages RUN RECORD naming it'
  } else { Write-Output ('FAIL  MUST FIRE build-samsclub unpaged: findings=' + ($rrM1.findings -join ' | ')); $fail++ }
  # MUST NOT FIRE: the 09-22 day. commit-refused paged as itself, so neither RUN RECORD nor COMPUTED BUT NOT SHIPPED is sent.
  $rrF2 = New-Object System.Collections.Generic.List[string]; [void]$rrF2.Add($rrTxt); [void]$rrF2.Add($rrCnsd)
  $rrRec2 = [pscustomobject]@{ exit_code = 1; failed_lanes = @([pscustomobject]@{ lane = 'commit-refused'; paged = 'Daily pipeline commit REFUSED - 2026-09-22' }) }
  $rrM2 = Merge-PagedLaneFindings $rrF2 $rrF2 (Get-FailedLanePaging $rrRec2) $rrTxt 'daily'
  if ($rrM2.findings.Count -eq 0 -and $rrM2.sub.Count -eq 2 -and $rrM2.line -match 'every failed lane paged as itself: commit-refused \(Daily pipeline commit REFUSED - 2026-09-22\)') {
    Write-Output 'ok    MUST NOT FIRE every failed lane paged as itself (commit-refused, 09-22): RUN RECORD and COMPUTED BUT NOT SHIPPED fold into one transcript line, nothing sent'
  } else { Write-Output ('FAIL  MUST NOT FIRE commit-refused paged: findings=' + ($rrM2.findings -join ' | ') + ' line=' + $rrM2.line); $fail++ }
  # CLEAN TWIN: an older record with no failed_lanes pages RUN RECORD exactly as before.
  $rrF3 = New-Object System.Collections.Generic.List[string]; [void]$rrF3.Add($rrTxt)
  $rrM3 = Merge-PagedLaneFindings $rrF3 $rrF3 (Get-FailedLanePaging ([pscustomobject]@{ exit_code = 1 })) $rrTxt 'daily'
  if ($rrM3.findings.Count -eq 1 -and $rrM3.findings[0] -eq $rrTxt) {
    Write-Output 'ok    CLEAN TWIN a record with no failed_lanes field still pages RUN RECORD with its old text'
  } else { Write-Output ('FAIL  CLEAN TWIN old record: findings=' + ($rrM3.findings -join ' | ')); $fail++ }

  # ---- THE [ad] RECORD FOLDS TOO (2026-09-25, item 2026-09-23-822c30). FROZEN from capture-run-status.json on 09-25:
  # the 07:00 ad run failed only 'sync' and paged it as itself; the watchdog still paged RUN RECORD [ad] at 10:34.
  $adTxt = 'RUN RECORD: capture-run [ad] completed with exit 1 - see capture-run-ad-2026-09-25.log'
  $adF1 = New-Object System.Collections.Generic.List[string]; [void]$adF1.Add($adTxt); [void]$adF1.Add('NO FRESH ROWS: Hy-Vee x')
  $adRec1 = [pscustomobject]@{ exit_code = 1; failed_lanes = @([pscustomobject]@{ lane = 'sync'; paged = 'Grocery bot checkout sync degraded at the push - 2026-09-25' }) }
  $adM1 = Merge-AdRunRecord $adF1 $adRec1 $adTxt
  if ($adM1.findings.Count -eq 1 -and $adM1.findings[0] -eq 'NO FRESH ROWS: Hy-Vee x' -and $adM1.line -match '^RUN RECORD: capture-run \[ad\] exit 1 - every failed lane paged as itself: sync \(') {
    Write-Output 'ok    MUST NOT FIRE [ad] record whose only failed lane (sync, 09-25) paged as itself folds to a transcript line; the other finding stays'
  } else { Write-Output ('FAIL  [ad] all-paged fold: findings=' + ($adM1.findings -join ' | ') + ' line=' + $adM1.line); $fail++ }
  # MUST FIRE: the 09-23 shape with the lane unpaged still pages, naming the lane.
  $adF2 = New-Object System.Collections.Generic.List[string]; [void]$adF2.Add($adTxt)
  $adRec2 = [pscustomobject]@{ exit_code = 1; failed_lanes = @([pscustomobject]@{ lane = 'commit-size-gate'; paged = '' }) }
  $adM2 = Merge-AdRunRecord $adF2 $adRec2 $adTxt
  if ($adM2.findings.Count -eq 1 -and $adM2.findings[0] -match '^RUN RECORD: capture-run \[ad\] exit 1 - failed lane\(s\) with no page of their own: commit-size-gate$' -and -not $adM2.line) {
    Write-Output 'ok    MUST FIRE [ad] record with an unpaged lane (commit-size-gate) still pages RUN RECORD naming that lane'
  } else { Write-Output ('FAIL  [ad] unpaged lane: findings=' + ($adM2.findings -join ' | ')); $fail++ }
  # CLEAN TWIN: an [ad] record with no failed_lanes field pages its old text unchanged.
  $adF3 = New-Object System.Collections.Generic.List[string]; [void]$adF3.Add($adTxt)
  $adM3 = Merge-AdRunRecord $adF3 ([pscustomobject]@{ exit_code = 1 }) $adTxt
  if ($adM3.findings.Count -eq 1 -and $adM3.findings[0] -eq $adTxt) {
    Write-Output 'ok    CLEAN TWIN an [ad] record with no failed_lanes field still pages RUN RECORD with its old text'
  } else { Write-Output ('FAIL  CLEAN TWIN [ad] old record: findings=' + ($adM3.findings -join ' | ')); $fail++ }

  # ---- THE CHECKOUT-SYNC LANE'S STAGES (2026-09-23, the lane's review) ------------------------------------------------
  # FROZEN from the review's probe: blocked-checkout and handoff-failed are FINAL stages written with exit 1 on a day that
  # already paged as lane sync / sync-handoff, and the old allowlist called each "not a stage a real run passes through",
  # repeating that page with a wrong explanation. syncing and synced-handoff are in-progress stages.
  foreach ($rrFx in @(@('blocked-checkout', 'sync', 'Grocery bot BLOCKED: the main checkout holds conflict markers - 2026-09-23'), @('handoff-failed', 'sync-handoff', 'capture-run could not start the synced code - 2026-09-23'))) {
    $rrRecS = [pscustomobject]@{ stage = $rrFx[0]; exit_code = 1; log = 'x.log'; failed_lanes = @([pscustomobject]@{ lane = $rrFx[1]; paged = $rrFx[2] }) }
    $rrVS = Get-RunRecordVerdict -Record $rrRecS -Kind 'daily' -AgeMin 5
    $rrFS = New-Object System.Collections.Generic.List[string]; [void]$rrFS.Add($rrVS.text)
    $rrMS = Merge-PagedLaneFindings $rrFS $rrFS (Get-FailedLanePaging $rrRecS) $rrVS.text 'daily'
    if ($rrVS.verdict -eq 'failed' -and $rrVS.text -notmatch 'not a stage a real run' -and $rrMS.findings.Count -eq 0 -and $rrMS.line -match ('every failed lane paged as itself: ' + [regex]::Escape($rrFx[1]) + ' ')) {
      Write-Output ('ok    MUST NOT FIRE a final ' + $rrFx[0] + ' record whose lane ' + $rrFx[1] + ' already paged is a failed run folded under that page, never "not a stage", and nothing is sent')
    } else { Write-Output ('FAIL  ' + $rrFx[0] + ': verdict=' + $rrVS.verdict + ' text=' + $rrVS.text + ' findings=' + ($rrMS.findings -join ' | ') + ' line=' + $rrMS.line); $fail++ }
  }
  $rrIn = @(@('syncing', 5), @('synced-handoff', 5)) | ForEach-Object { (Get-RunRecordVerdict -Record ([pscustomobject]@{ stage = $_[0]; pid = 1; log = 'x' }) -Kind 'daily' -AgeMin $_[1]).verdict }
  if ((@($rrIn) -join ',') -eq 'ok,ok') { Write-Output 'ok    MUST NOT FIRE syncing and synced-handoff are in-progress stages, ok at 5 min' }
  else { Write-Output ('FAIL  in-progress stages: ' + (@($rrIn) -join ',')); $fail++ }
  $rrAt = Get-RunRecordVerdict -Record ([pscustomobject]@{ stage = 'syncing'; pid = 1; log = 'x' }) -Kind 'daily' -AgeMin 90
  if ($rrAt.verdict -eq 'ok') { Write-Output 'ok    MUST NOT FIRE AT THE BAR a syncing record exactly 90 min old is still ok (the bar is -gt 90)' }
  else { Write-Output ('FAIL  at the bar: ' + $rrAt.verdict + ' ' + $rrAt.text); $fail++ }
  $rrPast = Get-RunRecordVerdict -Record ([pscustomobject]@{ stage = 'syncing'; pid = 1; log = 'x' }) -Kind 'daily' -AgeMin 91
  if ($rrPast.verdict -eq 'finding' -and $rrPast.text -match "sat in stage 'syncing' for 91 min") { Write-Output 'ok    MUST FIRE ONE MINUTE PAST THE BAR a syncing record 91 min old is a finding' }
  else { Write-Output ('FAIL  past the bar: ' + $rrPast.verdict + ' ' + $rrPast.text); $fail++ }
  # CLEAN TWIN, on the PRODUCER: every stage capture-run.ps1 writes (its literal Write-RunStatus arguments, read by AST)
  # is one this verdict names, so the next stage the run grows cannot be forgotten here. skipped-locked is the one it
  # deliberately still flags: an occurrence that found the lock held overwrote the holder's record, which is worth a look.
  $rrCrAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'capture-run.ps1'), [ref]$null, [ref]$null)
  $rrStages = @($rrCrAst.FindAll({ param($a) $a -is [System.Management.Automation.Language.CommandAst] -and $a.GetCommandName() -eq 'Write-RunStatus' -and $a.CommandElements.Count -ge 2 -and $a.CommandElements[1] -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) | ForEach-Object { [string]$_.CommandElements[1].Value } | Sort-Object -Unique)
  $rrUnknown = @($rrStages | Where-Object { $_ -ne 'skipped-locked' -and (Get-RunRecordVerdict -Record ([pscustomobject]@{ stage = $_; exit_code = 0; pid = 1; log = 'x' }) -Kind 'daily' -AgeMin 1).text -match 'not a stage a real run' })
  $rrNeed = @('blocked-checkout', 'handoff-failed', 'synced-handoff', 'syncing', 'started', 'capturing', 'downstream', 'publishing')
  $rrMissing = @($rrNeed | Where-Object { $rrStages -notcontains $_ })
  if ($rrUnknown.Count -eq 0 -and $rrMissing.Count -eq 0) { Write-Output ('ok    CLEAN TWIN every stage capture-run.ps1 writes (' + $rrStages.Count + ': ' + ($rrStages -join ', ') + ') is one the run-record verdict names, skipped-locked excepted on purpose') }
  else { Write-Output ('FAIL  stages the verdict does not name: ' + ($rrUnknown -join ', ') + ' | expected but not found in capture-run.ps1: ' + ($rrMissing -join ', ')); $fail++ }
  # MUST FIRE, the producer half: capture-run's own Add-FailedLane and Set-FailedLanePaged, lifted by AST and run. A page
  # that did not send (rc 9) records no subject; one that did (rc 0) records it; and no lane bypasses Add-FailedLane.
  $crPath = Join-Path $root 'capture-run.ps1'
  $crAst = [System.Management.Automation.Language.Parser]::ParseFile($crPath, [ref]$null, [ref]$null)
  $crFns = @($crAst.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and @('Add-FailedLane', 'Set-FailedLanePaged') -contains $a.Name }, $true))
  $failed = @(); $script:FailedLaneRecs = @()
  foreach ($fn in $crFns) { . ([scriptblock]::Create($fn.Extent.Text)) }
  Add-FailedLane 'commit-refused'; Set-FailedLanePaged 'commit-refused' 'Daily pipeline commit REFUSED - 2026-09-22' 9
  Add-FailedLane 'push'; Set-FailedLanePaged 'push' 'Grocery pipeline could not push - 2026-09-22' 0
  Add-FailedLane 'build-samsclub'
  $crBypassPat = '\$' + 'failed \+= '
  $crBypass = [regex]::Matches([IO.File]::ReadAllText($crPath), $crBypassPat).Count
  $crRecs = @($script:FailedLaneRecs)
  if ($crFns.Count -eq 2 -and $crRecs.Count -eq 3 -and -not $crRecs[0].paged -and $crRecs[1].paged -eq 'Grocery pipeline could not push - 2026-09-22' -and -not $crRecs[2].paged -and $crBypass -eq 0 -and (@($failed) -join ',') -eq 'commit-refused,push,build-samsclub') {
    Write-Output 'ok    MUST FIRE capture-run records a page only when Send-Alert returned 0, and every failed lane goes through Add-FailedLane (0 bypasses)'
  } else { Write-Output ('FAIL  capture-run lane record: fns=' + $crFns.Count + ' recs=' + $crRecs.Count + ' bypass=' + $crBypass + ' failed=' + (@($failed) -join ',')); $fail++ }

  # ---- ONE INCIDENT, ONE ALERT (2026-09-10, plan Phase 1): which alerts a run sends ----
  $hFx = 'HELD BY GUARDS: check-ad-cycles refused the 08:14 board (guards_rc 2) and nothing has shipped since.'
  # MUST FIRE: the founding four fold to the hold alone, sent caused by the hold, with no watchdog alert beside it.
  $plan1 = Get-WatchdogAlertPlan -Findings $fHeld.findings -Held $true -HeldText $hFx
  if ($plan1.hold -and $plan1.independent.Count -eq 0) { Write-Output 'ok    a morning of only hold symptoms plans ONE hold-caused alert and no independent watchdog alert' }
  else { Write-Output ("FAIL  the hold-only morning did not plan one hold alert: hold=" + $plan1.hold + " independent=" + $plan1.independent.Count); $fail++ }
  # MUST FIRE: a finding the hold did NOT cause still goes out as its own watchdog alert on the same morning.
  $plan2 = Get-WatchdogAlertPlan -Findings $fHeld2.findings -Held $true -HeldText $hFx
  if ($plan2.hold -and $plan2.independent.Count -eq 1 -and $plan2.independent[0] -match 'PAID CONTENT SERVED FREE') { Write-Output 'ok    an independent finding on a hold morning still goes out as its own watchdog alert' }
  else { Write-Output ("FAIL  an independent finding was folded into the hold alert: hold=" + $plan2.hold + " independent=" + $plan2.independent.Count); $fail++ }
  # CLEAN TWIN: no hold, so the run still sends the one watchdog alert carrying every finding.
  $plan3 = Get-WatchdogAlertPlan -Findings $fPlain.findings -Held $false -HeldText ''
  if ((-not $plan3.hold) -and $plan3.independent.Count -eq 5) { Write-Output 'ok    on a day with no hold every finding still goes out in the one watchdog alert (5 of 5)' }
  else { Write-Output ("FAIL  a no-hold day did not send every finding in one alert: hold=" + $plan3.hold + " independent=" + $plan3.independent.Count); $fail++ }


  # ---- NOT YET IS NOT MISSING (2026-09-22, queue 2026-09-22-2000e1) ----
  # Store names are neutral on purpose: Get-BrowserCaptureVerdict never branches on which store (audit-store-registry check 5).
  # Frozen: the 2026-09-22 morning. Aldi, Fareway and Walmart had no capture at 10:30 and landed at 13:09-13:15.
  $bvDir = Join-Path $env:TEMP ('wd-bcv-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
  New-Item -ItemType Directory -Path $bvDir -ErrorAction Stop | Out-Null
  try {
    if (-not (Get-Command Get-BrowserCaptureVerdict -ErrorAction SilentlyContinue)) { . (Join-Path $root 'capture-policy-lib.ps1') }
    $bvSam = Join-Path $bvDir 'sams-today.csv'; [IO.File]::WriteAllText($bvSam, "#tc-store 15429`nsku|Great Value Milk|3.12`n")
    $bvYes = Join-Path $bvDir 'aldi-yday.csv'; [IO.File]::WriteAllText($bvYes, "#tc-store OLA-42`nsku|Milk|2.99`n")
    $bvStores = @('Store W', 'Store S', 'Store A')
    $bvToday = @{ 'Store W' = (Join-Path $bvDir 'none-w.csv'); 'Store S' = $bvSam; 'Store A' = (Join-Path $bvDir 'none-a.csv') }
    $bvYday = @{ 'Store W' = $bvSam; 'Store S' = $bvSam; 'Store A' = $bvYes }
    $bvSlot = Get-ProducerSlot 'grocery-browser-stores-refresh' ([datetime]'2026-09-22')
    $v1 = Get-BrowserCaptureVerdict -Stores $bvStores -TodayFiles $bvToday -YesterdayFiles $bvYday -Now ([datetime]'2026-09-22 10:30') -Slot $bvSlot
    if (@($v1.NotYet).Count -eq 2 -and @($v1.MissingToday).Count -eq 0 -and $v1.SlotOpen) { Write-Output 'PASS  MUST NOT FIRE the founding 10:30 morning: two stores with no capture inside the producer''s slot are NOT YET, never MISSING' } else { Write-Output ("FAIL  a store inside the producer's slot was graded MISSING: missing=" + @($v1.MissingToday).Count + " not_yet=" + @($v1.NotYet).Count); $fail++ }
    $v2 = Get-BrowserCaptureVerdict -Stores $bvStores -TodayFiles $bvToday -YesterdayFiles $bvYday -Now ([datetime]'2026-09-22 14:00') -Slot $bvSlot
    if ((@($v2.MissingToday) -join ',') -eq 'Store W,Store A' -and @($v2.NotYet).Count -eq 0) { Write-Output 'PASS  MUST FIRE AT THE BAR: at exactly the slot end (14:00) the same two stores are MISSING' } else { Write-Output ("FAIL  the slot end did not close the slot: missing=" + (@($v2.MissingToday) -join ',')); $fail++ }
    $v2b = Get-BrowserCaptureVerdict -Stores $bvStores -TodayFiles $bvToday -YesterdayFiles $bvYday -Now ([datetime]'2026-09-22 13:59') -Slot $bvSlot
    if (@($v2b.NotYet).Count -eq 2 -and @($v2b.MissingToday).Count -eq 0) { Write-Output 'PASS  MUST NOT FIRE ONE MINUTE BEFORE THE BAR (13:59): still NOT YET' } else { Write-Output 'FAIL  13:59 was graded as a closed slot'; $fail++ }
    $bvYday2 = @{ 'Store W' = (Join-Path $bvDir 'none-yw.csv'); 'Store S' = $bvSam; 'Store A' = $bvYes }
    $v3 = Get-BrowserCaptureVerdict -Stores $bvStores -TodayFiles $bvToday -YesterdayFiles $bvYday2 -Now ([datetime]'2026-09-22 10:30') -Slot $bvSlot
    if ((@($v3.MissingYesterday) -join ',') -eq 'Store W') { Write-Output 'PASS  MUST FIRE inside today''s slot, a store with no capture YESTERDAY (a closed slot) is MISSING YESTERDAY, so a real miss still pages' } else { Write-Output ("FAIL  yesterday's closed slot was not graded: " + (@($v3.MissingYesterday) -join ',')); $fail++ }
    $v4 = Get-BrowserCaptureVerdict -Stores $bvStores -TodayFiles $bvToday -YesterdayFiles $bvYday -Now ([datetime]'2026-09-22 10:30') -Slot $null
    if ((@($v4.MissingToday) -join ',') -eq 'Store W,Store A' -and @($v4.NotYet).Count -eq 0) { Write-Output 'PASS  MUST FIRE an undeclared producer (no slot) fails toward paging: MISSING, never NOT YET' } else { Write-Output 'FAIL  a producer with no declared slot was read as NOT YET'; $fail++ }
    $bvAll = @{ 'Store W' = $bvSam; 'Store S' = $bvSam; 'Store A' = $bvYes }
    $v5 = Get-BrowserCaptureVerdict -Stores $bvStores -TodayFiles $bvAll -YesterdayFiles $bvYday -Now ([datetime]'2026-09-22 14:30') -Slot $bvSlot
    if (@($v5.MissingToday).Count -eq 0 -and @($v5.NotYet).Count -eq 0 -and $bvSlot.end -eq [datetime]'2026-09-22 14:00') { Write-Output 'PASS  CLEAN TWIN a day with every capture landed after the slot reads clean, and the declared slot ends 14:00 on the given day' } else { Write-Output 'FAIL  a fully landed day was not clean, or the slot end moved'; $fail++ }
    $v6 = Get-BrowserCaptureVerdict -Stores $bvStores -TodayFiles $bvToday -YesterdayFiles $bvYday2 -Now ([datetime]'2026-09-22 10:30') -Slot $bvSlot -YesterdayGraded $true
    if (@($v6.MissingYesterday).Count -eq 0 -and @($v6.NotYet).Count -eq 2) { Write-Output 'PASS  MUST NOT FIRE yesterday graded at its slot close (stamp present) is not paged again by the morning backstop' } else { Write-Output ('FAIL  a slot-close-graded yesterday was paged again: ' + (@($v6.MissingYesterday) -join ',')); $fail++ }
    # END TO END through the real script: -SlotClose over a fixture out\ with one of the browser stores landed.
    $scOut = Join-Path $bvDir 'out'
    New-Item -ItemType Directory -Path (Join-Path $scOut 'captures') -Force -ErrorAction Stop | Out-Null
    [IO.File]::WriteAllText((Join-Path $scOut 'captures\walmart-capture-2026-09-22.csv'), "#tc-store 5361`nsku|Milk|3.12`n")
    $scRun = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -SlotClose -Today '2026-09-22' -OutDir $scOut)
    $scRc = $LASTEXITCODE
    $scTxt = ($scRun -join "`n")
    $scStamp = Join-Path $scOut 'browser-slot-close-2026-09-22.json'
    if ($scRc -eq 1 -and $scTxt -match 'BROWSER CAPTURE MISSING TODAY: ' -and $scTxt -notmatch 'MISSING TODAY: Walmart' -and $scTxt -match 'findings=1 not_yet=0 mode=slot-close' -and (Test-Path -LiteralPath $scStamp)) { Write-Output 'PASS  MUST FIRE -SlotClose at 14:15 pages the stores with no capture today, SAME DAY, and writes the stamp the backstop reads' } else { Write-Output ("FAIL  -SlotClose did not grade the closed slot: rc=$scRc stamp=" + (Test-Path -LiteralPath $scStamp)); $fail++ }
    $scYes = Get-BrowserCaptureVerdict -Stores $bvStores -TodayFiles $bvToday -YesterdayFiles $bvYday2 -Now ([datetime]'2026-09-23 10:30') -Slot (Get-ProducerSlot 'grocery-browser-stores-refresh' ([datetime]'2026-09-23')) -YesterdayGraded (Test-Path -LiteralPath $scStamp)
    if (@($scYes.MissingYesterday).Count -eq 0) { Write-Output 'PASS  CLEAN TWIN the stamp that -SlotClose wrote is the one that stops the next morning paging the same miss' } else { Write-Output 'FAIL  the -SlotClose stamp did not reach the backstop'; $fail++ }
  } finally { Remove-Item -LiteralPath $bvDir -Recurse -Force -ErrorAction SilentlyContinue }

  # ---- 7, 8, 9: THE BOT CHECKOUT FLOORS (2026-09-23, design\PLAN-bot-checkout-self-heal-2026-09-23.md W1.1) ----
  # A temp bare remote plus clones in one per-run root under %TEMP%, removed in finally; the repository environment is
  # cleared before the first git init. Commit times are exact epochs through GIT_COMMITTER_DATE and the clock is the
  # -Now seam, so the case AT the 93,600 s bar is exactly at it. Fixture setup that fails is one counted FAIL, and the
  # case count below then falls short as well: it can never pass over nothing.
  $flSb = Join-Path $env:TEMP ('wd-fl-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
  $flPrevCd = $env:GIT_COMMITTER_DATE; $flPrevAd = $env:GIT_AUTHOR_DATE
  try {
    New-Item -ItemType Directory -Path $flSb -ErrorAction Stop | Out-Null
    . (Join-Path (Split-Path $root -Parent) 'lib\git-repo-env.ps1')
    Clear-TcGitRepoEnv
    $flUtf8 = New-Object Text.UTF8Encoding($false)
    function WdFxGit([string]$Dir, [string[]]$A) {
      $r = Invoke-GitCaptured -Repo $Dir -GitArgs $A
      if ($r.rc -ne 0) { throw ('fixture git ' + ($A -join ' ') + ' exited ' + $r.rc + ': ' + ([string]$r.stderr).Trim()) }
      return ([string]$r.stdout).Trim()
    }
    function WdFxCommit([string]$Dir, [string]$File, [string]$Text, [long]$At) {
      [IO.File]::WriteAllText((Join-Path $Dir $File), $Text, $flUtf8)
      $env:GIT_COMMITTER_DATE = ('@' + $At + ' +0000'); $env:GIT_AUTHOR_DATE = $env:GIT_COMMITTER_DATE
      try {
        $null = WdFxGit $Dir @('add', '--', $File)
        $null = WdFxGit $Dir @('-c', 'user.name=wd', '-c', 'user.email=wd@t', '-c', 'commit.gpgsign=false', 'commit', '-q', '-m', ('add ' + $File))
      } finally { $env:GIT_COMMITTER_DATE = $flPrevCd; $env:GIT_AUTHOR_DATE = $flPrevAd }
      return (WdFxGit $Dir @('rev-parse', 'HEAD'))
    }
    function WdFxStale($o) { return @($o.findings | Where-Object { ([string]$_).StartsWith('BOT CHECKOUT STALE:') }).Count }
    function WdFxAt([long]$Epoch) { return [DateTimeOffset]::FromUnixTimeSeconds($Epoch).UtcDateTime }
    $T0 = [long]1757000000; $T1 = [long]1758000000
    $flRemote = Join-Path $flSb 'remote.git'; $flUp = Join-Path $flSb 'up'; $flBot = Join-Path $flSb 'bot'
    $null = WdFxGit $flSb @('init', '-q', '--bare', '-b', 'main', 'remote.git')
    $null = WdFxGit $flSb @('init', '-q', '-b', 'main', 'up')
    $null = WdFxGit $flUp @('config', 'core.autocrlf', 'false')
    $null = WdFxCommit $flUp 'a.txt' "one`n" $T0
    $null = WdFxGit $flUp @('remote', 'add', 'origin', $flRemote)
    $null = WdFxGit $flUp @('push', '-q', 'origin', 'main')
    $null = WdFxGit $flSb @('clone', '-q', 'remote.git', 'bot')
    $null = WdFxGit $flBot @('config', 'core.autocrlf', 'false')
    $c2 = WdFxCommit $flUp 'b.txt' "two`n" $T1
    $null = WdFxGit $flUp @('push', '-q', 'origin', 'main')
    $null = WdFxGit $flBot @('fetch', '-q', 'origin')

    # MUST NOT FIRE AT THE BAR: the oldest missing commit is exactly 93,600 s old, which is as old as the bar allows.
    $co1 = Get-CheckoutFloor -Repo $flBot -Now (WdFxAt ($T1 + 93600))
    if ((WdFxStale $co1) -eq 0 -and $co1.findings.Count -eq 0 -and $co1.behind -eq 1 -and $co1.age_s -eq 93600 -and $co1.marker -match 'oldest_age_s=93600 bar_s=93600 stale=0 remote=same') { Write-Output 'PASS  MUST NOT FIRE AT THE BAR the oldest missing commit exactly 93,600 s (26 h) old is not stale: 1 behind, inside the bar' }
    else { Write-Output ('FAIL  AT THE BAR 93,600 s: findings=' + ($co1.findings -join ' | ') + ' behind=' + $co1.behind + ' age=' + $co1.age_s + ' marker=' + $co1.marker); $fail++ }

    # MUST FIRE ONE PAST THE BAR: 93,601 s, with the last sync record's outcome and why on the line.
    $flCd = Get-WdGitCommonDir $flBot
    [IO.File]::WriteAllText((Join-Path $flCd 'tc-checkout-sync.json'), '{"phase":"start","started":"2026-09-23T08:00:02","outcome":"blocked","class":"foreign","why":"fixture-session-file.json is dirty on a moved path"}', $flUtf8)
    $co2 = Get-CheckoutFloor -Repo $flBot -Now (WdFxAt ($T1 + 93601))
    $co2Line = @($co2.findings | Where-Object { ([string]$_).StartsWith('BOT CHECKOUT STALE:') })
    if ($co2Line.Count -eq 1 -and $co2Line[0].StartsWith('BOT CHECKOUT STALE: 1 commits behind, oldest missing ' + $c2.Substring(0, 8) + ' committed 93,601 s') -and $co2Line[0].Contains('last sync: blocked class foreign') -and $co2Line[0].Contains('fixture-session-file.json is dirty') -and $co2.marker -match 'stale=1') { Write-Output 'PASS  MUST FIRE ONE PAST THE BAR a missing commit 93,601 s old is BOT CHECKOUT STALE, naming the commit, its age and the last sync outcome and why' }
    else { Write-Output ('FAIL  ONE PAST 93,601 s: findings=' + ($co2.findings -join ' | ') + ' marker=' + $co2.marker); $fail++ }

    # CLEAN TWIN: the remote moved past the local ref and nothing here fetched. The line names both tips.
    $c3 = WdFxCommit $flUp 'c.txt' "three`n" ($T1 + 100)
    $null = WdFxGit $flUp @('push', '-q', 'origin', 'main')
    $co3 = Get-CheckoutFloor -Repo $flBot -Now (WdFxAt ($T1 + 93601))
    $co3Line = @($co3.findings | Where-Object { ([string]$_).StartsWith('BOT CHECKOUT STALE:') })
    if ($co3Line.Count -eq 1 -and $co3Line[0].Contains("The remote's main is at " + $c3.Substring(0, 8)) -and $co3Line[0].Contains('refs/remotes/origin/main ' + $c2.Substring(0, 8)) -and $co3Line[0].Contains('can only understate') -and $co3.marker -match 'remote=moved') { Write-Output 'PASS  CLEAN TWIN a remote tip past the local refs/remotes/origin/main is named on the line, which says the count can only understate' }
    else { Write-Output ('FAIL  CLEAN TWIN remote moved: findings=' + ($co3.findings -join ' | ') + ' marker=' + $co3.marker); $fail++ }

    # MUST NOT FIRE: origin contained, at any age.
    $null = WdFxGit $flBot @('fetch', '-q', 'origin')
    $null = WdFxGit $flBot @('merge', '-q', '--ff-only', 'origin/main')
    $co4 = Get-CheckoutFloor -Repo $flBot -Now (WdFxAt ($T1 + 10000000))
    if ($co4.findings.Count -eq 0 -and $co4.behind -eq 0 -and @($co4.ok | Where-Object { ([string]$_).StartsWith('checkout: HEAD contains origin/main ' + $c3.Substring(0, 8)) }).Count -eq 1) { Write-Output 'PASS  MUST NOT FIRE a checkout that contains origin/main is ok at any age (checked 10,000,000 s after the last commit)' }
    else { Write-Output ('FAIL  MUST NOT FIRE contained: findings=' + ($co4.findings -join ' | ') + ' behind=' + $co4.behind); $fail++ }

    # MUST FIRE: ls-remote against a removed remote is a BLIND finding, never a pass.
    $flGone = Join-Path $flSb 'gone.git'
    $null = WdFxGit $flSb @('init', '-q', '--bare', '-b', 'main', 'gone.git')
    $null = WdFxGit $flUp @('push', '-q', $flGone, 'main')
    $null = WdFxGit $flSb @('clone', '-q', 'gone.git', 'bot2')
    Remove-Item -LiteralPath $flGone -Recurse -Force -ErrorAction Stop
    $co5 = Get-CheckoutFloor -Repo (Join-Path $flSb 'bot2') -Now (WdFxAt ($T1 + 93601))
    $co5Blind = @($co5.findings | Where-Object { ([string]$_) -match '^CHECKOUT: BLIND - ls-remote exited ([1-9]\d*|-\d+)' })
    if ($co5Blind.Count -eq 1 -and $co5.findings.Count -eq 1 -and $co5.marker -match 'remote=blind blind=1') { Write-Output 'PASS  MUST FIRE ls-remote against a removed remote prints CHECKOUT: BLIND with its exit code and counts as a finding' }
    else { Write-Output ('FAIL  MUST FIRE removed remote: findings=' + ($co5.findings -join ' | ') + ' marker=' + $co5.marker); $fail++ }

    # CHECK 8. A frozen day: 2026-09-23. The fixture's .git\info\exclude ignores its grocery/out/ignored-* files. The
    # pattern is concatenated so ops\audit-write-only-reports.ps1 does not read this temp write as a report family.
    $flOut = Join-Path $flBot 'grocery\out'
    New-Item -ItemType Directory -Path (Join-Path $flOut 'regular') -Force -ErrorAction Stop | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $flCd 'info') -Force -ErrorAction Stop | Out-Null
    $flExcl = 'grocery/out/ignored-*' + '.json'
    [IO.File]::WriteAllText((Join-Path $flCd 'info\exclude'), ($flExcl + "`n"), $flUtf8)
    $null = WdFxCommit $flBot 'grocery/out/tracked-2026-09-22.json' "{}`n" ($T1 + 200)
    [IO.File]::WriteAllText((Join-Path $flOut 'regular\x-2026-09-23.json'), "{}`n", $flUtf8)
    [IO.File]::WriteAllText((Join-Path $flOut 'ignored-2026-09-22.json'), "{}`n", $flUtf8)
    $flDay = [datetime]'2026-09-23'
    # MUST NOT FIRE: an untracked file dated today, an ignored file dated yesterday and a tracked one dated yesterday.
    $bl1 = Get-CaptureBacklog -Repo $flBot -TodayS '2026-09-23' -Now $flDay.AddHours(10.5)
    if ($bl1.due -and $bl1.findings.Count -eq 0 -and $bl1.examined -eq 1 -and @($bl1.ok | Where-Object { ([string]$_).StartsWith('capture backlog: 0 untracked file(s) under grocery/out dated before 2026-09-23 (1 untracked') }).Count -eq 1) { Write-Output 'PASS  MUST NOT FIRE an untracked file dated today, an ignored one dated yesterday and a tracked one dated yesterday are no backlog' }
    else { Write-Output ('FAIL  MUST NOT FIRE today/ignored/tracked: findings=' + ($bl1.findings -join ' | ') + ' examined=' + $bl1.examined); $fail++ }
    # One untracked capture dated yesterday, exactly 1 MiB.
    [IO.File]::WriteAllBytes((Join-Path $flOut 'regular\x-2026-09-22.json'), (New-Object byte[] 1048576))
    # MUST NOT FIRE one second before the 10:00 bar: not graded, and the ok line says NOT CHECKED rather than clean.
    $bl2 = Get-CaptureBacklog -Repo $flBot -TodayS '2026-09-23' -Now $flDay.AddHours(10).AddSeconds(-1)
    if (-not $bl2.due -and $bl2.findings.Count -eq 0 -and @($bl2.ok | Where-Object { ([string]$_).StartsWith('capture backlog: NOT CHECKED at 09:59:59') }).Count -eq 1) { Write-Output 'PASS  MUST NOT FIRE the same file at 09:59:59, one second before the 10:00 bar, is NOT CHECKED, never clean' }
    else { Write-Output ('FAIL  MUST NOT FIRE before the slot: due=' + $bl2.due + ' findings=' + ($bl2.findings -join ' | ')); $fail++ }
    # MUST FIRE AT THE BAR: at exactly 10:00:00 the backlog is graded.
    $bl3 = Get-CaptureBacklog -Repo $flBot -TodayS '2026-09-23' -Now $flDay.AddHours(10)
    if ($bl3.due -and $bl3.findings.Count -eq 1 -and $bl3.files -eq 1) { Write-Output 'PASS  MUST FIRE AT THE BAR at exactly 10:00:00 the untracked file dated yesterday is graded and raised' }
    else { Write-Output ('FAIL  MUST FIRE at 10:00:00: due=' + $bl3.due + ' findings=' + ($bl3.findings -join ' | ')); $fail++ }
    # MUST FIRE after the slot: one untracked grocery/out/regular/x-<yesterday>.json, with its count, size and date.
    $bl4 = Get-CaptureBacklog -Repo $flBot -TodayS '2026-09-23' -Now $flDay.AddHours(10.5)
    if ($bl4.findings.Count -eq 1 -and ([string]$bl4.findings[0]).StartsWith('CAPTURE BACKLOG: 1 file(s), 1.0 MiB, oldest dated 2026-09-22 - by date: 2026-09-22 1 file(s) 1.0 MiB.')) { Write-Output 'PASS  MUST FIRE one untracked grocery/out/regular/x-2026-09-22.json after the slot is CAPTURE BACKLOG: 1 file(s), 1.0 MiB, oldest dated 2026-09-22' }
    else { Write-Output ('FAIL  MUST FIRE one file after the slot: ' + ($bl4.findings -join ' | ')); $fail++ }
    # CLEAN TWIN: a second day, a path with a space (split on NUL, never C-quoted), grouped by date, oldest first.
    [IO.File]::WriteAllBytes((Join-Path $flOut 'y two-2026-09-21.json'), (New-Object byte[] 524288))
    $bl5 = Get-CaptureBacklog -Repo $flBot -TodayS '2026-09-23' -Now $flDay.AddHours(10.5)
    if ($bl5.findings.Count -eq 1 -and ([string]$bl5.findings[0]).StartsWith('CAPTURE BACKLOG: 2 file(s), 1.5 MiB, oldest dated 2026-09-21 - by date: 2026-09-21 1 file(s) 0.5 MiB; 2026-09-22 1 file(s) 1.0 MiB.')) { Write-Output 'PASS  CLEAN TWIN two days group by date, oldest first, and a path with a space arrives whole: 2 file(s), 1.5 MiB, oldest 2026-09-21' }
    else { Write-Output ('FAIL  CLEAN TWIN grouping: ' + ($bl5.findings -join ' | ')); $fail++ }
    # CLEAN TWIN: the path-date rule, pinned so a drift from W2.1's Get-CaptureDateOf is a red.
    $dq = @((Get-WdCaptureDateOf 'grocery/out/regular/x-2026-09-22.json'), (Get-WdCaptureDateOf 'grocery/out/2026-09-01/b-2026-09-02.json'), (Get-WdCaptureDateOf 'grocery/out/captures/walmart-20260921-081500.csv'), (Get-WdCaptureDateOf 'grocery/out/match-worklist.json'), (Get-WdCaptureDateOf 'grocery/out/x-12026-09-22.json'))
    if (($dq -join ',') -eq '2026-09-22,2026-09-02,2026-09-21,,') { Write-Output 'PASS  CLEAN TWIN the path date is the LAST yyyy-MM-dd, else yyyyMMdd before -HHmmss, else none (5 of 5 answers)' }
    else { Write-Output ('FAIL  CLEAN TWIN path dates: ' + ($dq -join ',')); $fail++ }

    # CHECK 9. MUST NOT FIRE: no kill-switch file.
    $ks1 = Get-SyncKillSwitch -Repo $flBot
    if ($ks1.findings.Count -eq 0 -and -not $ks1.on -and @($ks1.ok | Where-Object { ([string]$_).StartsWith('checkout sync kill switch: off') }).Count -eq 1) { Write-Output 'PASS  MUST NOT FIRE no tc-checkout-sync.disabled in the git common dir: the kill switch is off' }
    else { Write-Output ('FAIL  MUST NOT FIRE kill switch absent: ' + ($ks1.findings -join ' | ')); $fail++ }
    # MUST FIRE: the file present.
    [IO.File]::WriteAllText((Join-Path $flCd 'tc-checkout-sync.disabled'), "fixture`n", $flUtf8)
    $ks2 = Get-SyncKillSwitch -Repo $flBot
    if ($ks2.on -and $ks2.findings.Count -eq 1 -and ([string]$ks2.findings[0]).StartsWith('BOT CHECKOUT SYNC DISABLED since ')) { Write-Output 'PASS  MUST FIRE tc-checkout-sync.disabled present in the git common dir raises BOT CHECKOUT SYNC DISABLED since <mtime>' }
    else { Write-Output ('FAIL  MUST FIRE kill switch present: ' + ($ks2.findings -join ' | ')); $fail++ }
  } catch {
    Write-Output ('FAIL  the bot checkout floor fixtures threw: ' + $_.Exception.Message); $fail++
  } finally {
    $env:GIT_COMMITTER_DATE = $flPrevCd; $env:GIT_AUTHOR_DATE = $flPrevAd
    Remove-Item -LiteralPath $flSb -Recurse -Force -ErrorAction SilentlyContinue
  }
  }
  $wdStOut = @($wdStOut)
  foreach ($wdL in $wdStOut) { Write-Output $wdL }
  $wdCaseN = @($wdStOut | Where-Object { ([string]$_) -match '^(ok|PASS|FAIL) ' }).Count
  if ($wdCaseN -eq $WD_SELFTEST_CASES) { Write-Output ("CASES ok: exactly $WD_SELFTEST_CASES case lines ran, the literal count of this suite") }
  else { Write-Output ("FAIL  the suite ran $wdCaseN case line(s) against its literal $WD_SELFTEST_CASES - a case was lost or added without the count"); $fail++ }
  Write-Output ("SELFTEST " + $(if ($fail) { "FAILED ($fail)" } else { 'PASSED' }))
  exit $(if ($fail) { 1 } else { 0 })
}
. (Join-Path $root 'alert-lib.ps1')

# ---- 0. SILENT-DEATH HEARTBEAT (moved here 2026-08-22 from the retired local-watchdog.ps1) ----------
# health-heartbeat.ps1 watches expected-automations.json for a task that quietly stopped being scheduled
# or an output that quietly went stale. Its only runner was local-watchdog, retired with the old 8:30
# pipeline, so for two days nothing ran it. It self-alerts and de-dupes; this just surfaces a line.
# No 2>&1 on the child (EAP=Stop turns its first stderr line into a terminating throw - test-native-stderr-eap.ps1).
try { $hbOut = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'health-heartbeat.ps1') -Alert; @($hbOut) | ForEach-Object { Write-Output ('heartbeat: ' + $_) } } catch { Write-Output ('heartbeat threw: ' + $_.Exception.Message) }

$TASKS = @('TC Grocery Ad Pulls 0700', 'TC Grocery Daily Capture 0800')
$findings = New-Object System.Collections.Generic.List[string]
$ok = New-Object System.Collections.Generic.List[string]
# Tasks that exited non-zero, held until sections 3 and 4 can say whether the board was rebuilt and
# shipped after them. See the note at the deferral below.
$failedTasks = New-Object System.Collections.Generic.List[object]

# ---- 1 + 2. the schedule, and whether it fired ------------------------------
foreach ($name in $TASKS) {
  $t = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
  if (-not $t) { [void]$findings.Add("MISSING TASK: '$name' does not exist. Nothing is capturing on that schedule."); continue }
  if ($t.State -eq 'Disabled') { [void]$findings.Add("DISABLED: '$name' is disabled, so it will never fire."); continue }

  $i = $t | Get-ScheduledTaskInfo
  $last = $i.LastRunTime
  $rc = $i.LastTaskResult

  # The 08:00 job is the one that must run EVERY day. The 07:00 ad job legitimately
  # does nothing on days no ad rolled over, so "did not run today" is only a finding
  # for the daily one; for the ad job we report its last result instead.
  $isDaily = $name -like '*Daily Capture*'
  $ranToday = $last -and ($last.ToString('yyyy-MM-dd') -eq $todayS)
  # Check 7 below may only indict a headless lane on a day the daily capture actually ran.
  if ($isDaily) { $dailyRanToday = [bool]$ranToday }

  # Windows sentinels, which are NOT failures and must not be reported as such:
  #   267011 SCHED_S_TASK_HAS_NOT_RUN  - registered but its trigger has not come round yet
  #   267009 SCHED_S_TASK_RUNNING      - in flight right now
  # A task created today reads as 267011 with a 1999 timestamp; calling that
  # "FAILED" on day one would train the reader to ignore this watchdog before it
  # has ever reported anything real.
  $neverRan = ($rc -eq 267011) -or (-not $last) -or ($last.Year -lt 2000)

  if ($neverRan) {
    $next = if ($i.NextRunTime) { $i.NextRunTime.ToString('yyyy-MM-dd HH:mm') } else { 'unscheduled' }
    # "Not yet" is only innocent while it is still EARLY. A task registered days ago that has
    # still never fired is not waiting for its trigger, it is broken - a bad principal, a
    # condition that never holds, a StartBoundary in the past. Left as a permanent `ok` this
    # is a gate that can never arm: the one state it exists to catch would read green forever.
    # The grace is one full cycle plus a margin, so a task created after today's slot (which is
    # exactly how these two were registered on 2026-08-20) still gets its first real chance.
    $start = $null
    try { if ($t.Triggers[0].StartBoundary) { $start = [datetime]$t.Triggers[0].StartBoundary } } catch { }
    if (Test-NeverRanTooLong -TriggerStart $start -Now (Get-Date)) {
      $days = [int]((Get-Date) - $start).TotalDays
      [void]$findings.Add("NEVER RAN: '$name' was registered $days day(s) ago (trigger $($start.ToString('yyyy-MM-dd HH:mm'))) and has still never fired. Next says $next. A trigger that has never produced a run is not waiting, it is misconfigured.")
    } else {
      [void]$ok.Add("$name has not run yet (registered; next $next)")
    }
  } elseif ($rc -eq 267009) {
    [void]$ok.Add("$name is running now")
  } elseif ($isDaily -and -not $ranToday) {
    [void]$findings.Add("DID NOT RUN: '$name' last ran $last - nothing captured today.")
  } elseif ($rc -ne 0) {
    # DEFERRED ON PURPOSE (2026-08-31). A non-zero exit here is usually the guards refusing to publish,
    # which is the guard WORKING - and by the time this runs at 10:30 the blocker may already have been
    # cleared and the board shipped. Reporting the stale exit code as FAILED then emails a failure about a
    # board that is live and correct, which is how a real alert gets trained into noise. The facts that
    # settle it (was the board rebuilt after this run, and did it ship) are computed in sections 3 and 4
    # below, so the verdict waits for them rather than looking them up a second time here.
    [void]$failedTasks.Add([pscustomobject]@{ name = $name; last = $last; rc = $rc; at = $last })
  } else {
    [void]$ok.Add("$name ran $last rc=$rc")
  }
}

# ---- 2b. the run's OWN record (2026-08-22) ---------------------------------------------------
# capture-run.ps1 stamps out\logs\capture-run-status.json at start / capturing / downstream / complete
# with its exit code. Task Scheduler only knows the process ended; this knows how far it got. A run
# stuck in 'downstream' hours later, or one that never reached 'complete', is a finding even when the
# task reports rc=0 - and it does not depend on ad-cycle-log.txt, which another process can hold mute.
# THE CHAIN'S OWN VERDICT, read once (2026-09-07, queue 2026-09-07-e5efa6). check-ad-cycles writes what
# guards decided about today's board; capture-run and push-data both key off it and this watchdog never
# looked, so a single held board arrived as four independent findings. Absent or unparseable is null and
# changes nothing - the whole fold below is opt-in on a same-day blocked verdict.
$chainVerdict = $null
try {
  $cvF = Join-Path $OutDir 'chain-verdict.json'
  if (Test-Path $cvF) { $chainVerdict = Read-JsonFile $cvF }
} catch { $chainVerdict = $null }
# Findings that are SYMPTOMS of that hold rather than independent facts. They are added exactly as
# before, and are only demoted to sub-lines if Test-HeldByGuards says the hold is live - which needs
# sections 3 and 4 to have run, so the decision is deferred to the report, the same way the non-zero
# task verdict already defers to Test-RunSuperseded.
$derivative = New-Object System.Collections.Generic.List[string]
function Add-DerivativeFinding([string]$t) { [void]$findings.Add($t); [void]$derivative.Add($t) }
$dailyRunRecord = $null; $dailyRunRecordText = ''   # the daily record and its RUN RECORD line, for the paged-lane fold
$adRunRecord = $null; $adRunRecordText = ''         # the same for the 07:00 ad run (Merge-AdRunRecord)

$statusF = Join-Path $OutDir 'logs\capture-run-status.json'
if (Test-Path $statusF) {
  try {
    $st = Read-JsonFile $statusF
    foreach ($kind in @('ad', 'daily')) {
      $r = $st.$kind
      if (-not $r) { continue }
      if ([string]$r.date -ne $todayS) { if ($kind -eq 'daily') { [void]$findings.Add("RUN RECORD: the daily capture-run left no record for today (last $($r.date), stage $($r.stage)).") }; continue }
      $ageMin = [int]((Get-Date) - [datetime]$r.updated).TotalMinutes
      # Get-RunRecordVerdict (above) names every stage capture-run writes; -SelfTest checks that list against the AST.
      $rrV = Get-RunRecordVerdict -Record $r -Kind $kind -AgeMin $ageMin
      if ($rrV.verdict -eq 'failed') {
        # Only the DAILY run can be a symptom of a guards hold: the 07:00 ad run finishes before
        # check-ad-cycles ever runs guards, so its exit code is always its own news.
        $rrText = $rrV.text
        if ($kind -eq 'daily') { Add-DerivativeFinding $rrText; $dailyRunRecord = $r; $dailyRunRecordText = $rrText } else { [void]$findings.Add($rrText); $adRunRecord = $r; $adRunRecordText = $rrText }
      } elseif ($rrV.verdict -eq 'finding') { [void]$findings.Add($rrV.text) }
      else { [void]$ok.Add($rrV.text) }
    }
  } catch { [void]$findings.Add("RUN RECORD: $statusF is unreadable ($($_.Exception.Message))") }
} else {
  [void]$findings.Add("RUN RECORD: $statusF does not exist - capture-run has not written its own record; only Task Scheduler's word says it ran.")
}

# ---- 3. was the board REBUILT recently? -------------------------------------
# Freshness, not a filename. See Test-BoardStale above for why comparison-<today>.json was the wrong
# question: the board is named after the newest ads file, so on every non-rollover day this section
# reported NO BOARD FOR TODAY about a board that had been rebuilt hours earlier.
$cmp = $null
$newest = Get-ChildItem (Join-Path $OutDir 'comparison-*.json') -EA SilentlyContinue |
          Sort-Object Name -Descending | Select-Object -First 1
if (-not $newest) {
  [void]$findings.Add("NO BOARD AT ALL: no comparison-*.json under $OutDir. Nothing has been built here, so there is nothing to publish.")
} else {
  $cmp = $newest.FullName
  $ageH = [math]::Round(((Get-Date) - $newest.LastWriteTime).TotalHours, 1)
  if (Test-BoardStale -BoardWritten $newest.LastWriteTime -Now (Get-Date)) {
    [void]$findings.Add("BOARD IS STALE: the newest board $($newest.Name) was last written $($newest.LastWriteTime.ToString('yyyy-MM-dd HH:mm')), $ageH h ago - past the $($script:BoardStaleHours)h bar. Capture may have run, but the board was not recomputed.")
  } else {
    [void]$ok.Add("newest board $($newest.Name) rebuilt $ageH h ago")
  }
}

# ---- 4. did it reach the live site? -----------------------------------------
# public\board.json is what the Worker serves. If it is OLDER than the comparison,
# the recompute happened but the publish did not, and the site is serving a board
# that no longer matches the data behind it.
$pub = Join-Path (Split-Path $root -Parent) 'public\board.json'
# $cmp is now the NEWEST board rather than comparison-<today>.json. That matters here too, and it is the
# same defect wearing a different hat: while $cmp was a today-named path that mostly did not exist, this
# whole check was skipped on every non-rollover day - a gate that could only arm when the ad window
# happened to roll. It arms daily now.
if ($cmp -and (Test-Path $cmp) -and (Test-Path $pub)) {
  $cT = (Get-Item $cmp).LastWriteTime; $pT = (Get-Item $pub).LastWriteTime
  if ($pT -lt $cT.AddMinutes(-30)) {
    Add-DerivativeFinding "NOT PUBLISHED: public\board.json is $([int]($cT - $pT).TotalMinutes) min older than today's comparison. The board was rebuilt but never shipped."
  } else {
    [void]$ok.Add('public\board.json is current with the comparison')
  }
}

# ---- 4b. the deferred verdict on tasks that exited non-zero (2026-08-31) -----
# Sections 3 and 4 have now established when the newest board was written and whether it shipped, so a
# non-zero exit can finally be judged on OUTCOME rather than on its exit code alone - which is what the
# header of this file says it is for ("IT CHECKS OUTCOMES, NOT JUST EXIT CODES"). A run whose board was
# subsequently rebuilt AND published was superseded: still worth saying, because it needed something to
# happen, but it is not a live failure and must not read as one.
$boardW = if ($newest) { $newest.LastWriteTime } else { $null }
$pubW   = if ($pub -and (Test-Path $pub)) { (Get-Item $pub).LastWriteTime } else { $null }
foreach ($ft in $failedTasks) {
  if (Test-RunSuperseded -RunAt $ft.at -BoardWritten $boardW -PublishedWritten $pubW) {
    [void]$ok.Add("$($ft.name) exited $($ft.rc) at $($ft.last) - SUPERSEDED: the board was rebuilt $($boardW.ToString('HH:mm')) and published after it, so the live page is current. Usually the guards refusing to ship, then the blocker cleared.")
  } else {
    $ftText = "FAILED: '$($ft.name)' last run $($ft.last) exited $($ft.rc), and no board has been rebuilt and published since. The live page is NOT carrying that run's work."
    # A task that STARTED before the refusal was written is downstream of it; one that started after is
    # a separate failure and keeps its own line even on a held day.
    $ftPreHold = $false
    if ($chainVerdict -and $chainVerdict.written) { try { $ftPreHold = ([datetime]$ft.at -le [datetime]$chainVerdict.written) } catch { $ftPreHold = $false } }
    if ($ftPreHold) { Add-DerivativeFinding $ftText } else { [void]$findings.Add($ftText) }
  }
}

# ---- 4b. DID IT REACH MAIN? (added 2026-08-22, after four days of the answer being "no") ------------
# CHECK 4 ABOVE COMPARES TWO LOCAL FILES AND IS SATISFIED BY BOTH BEING FRESH ON DISK. That is not the
# product. Cloudflare deploys public\** FROM THE GIT REPO, so a price reaches a reader only once it is
# committed AND pushed. When the 2026-08-20 cutover moved the pipeline onto the three TC tasks it left
# the commit+push step behind in run-daily-local.ps1: the board was rebuilt every morning, check 4 said
# "current with the comparison" every morning, and the last smp-pipeline-bot commit was 2026-08-18. The
# live site served four-day-old prices while every check in this file was green.
# So ask the question the product cares about: is what the pipeline computed actually ON MAIN? Two
# independent signals, because either alone can lie - a bot commit can exist without the served files in
# it, and a clean tree can mean "nothing ran" as easily as "everything shipped".
$repoRoot = Split-Path $root -Parent
try {
  # Invoke-Native, not `git ... 2>$null`. This file sets EAP='Stop', and under Stop a redirect on a
  # native child turns its FIRST stderr line into a TERMINATING error - `2>$null` causes that, it does
  # not prevent it. git writes ordinary progress to stderr, so the watchdog's own "did it reach main?"
  # check was one noisy git invocation away from killing the watchdog. See native-lib.ps1.
  $lbR = Invoke-Native 'git' '-C' $repoRoot 'log' '--author=smp-pipeline-bot' '-1' '--format=%cd' '--date=format:%Y-%m-%d'
  $lastBot = @($lbR.Output) | Select-Object -First 1
  $botAge = if ($lastBot) { [int]((Get-Date).Date - ([datetime]$lastBot)).TotalDays } else { 9999 }
  # the served files, as git sees them: dirty = computed but never shipped
  $dirtyR = Invoke-Native 'git' '-C' $repoRoot 'status' '--porcelain' '--' 'public/board.json' 'public/smp-feed.json'
  $dirty = @($dirtyR.Output | Where-Object { $_ })
  if ($botAge -gt 2) {
    $seen = if ($lastBot) { "the last pipeline commit is $lastBot ($botAge days ago)" } else { 'there is NO pipeline commit in this history' }
    [void]$findings.Add("NEVER REACHED MAIN: $seen. Cloudflare deploys public\** from the repo, so the live board and feed are stale by that much no matter how fresh the local files look. Check the publish stage at the end of capture-run.ps1 (commit -> push -> edge verify).")
  } elseif ($dirty.Count) {
    Add-DerivativeFinding ("COMPUTED BUT NOT SHIPPED: " + ($dirty -join ', ') + " are modified in the working tree after today's run. The pipeline rebuilt them and the commit/push did not take them, so readers still get the previous board.")
  } else {
    [void]$ok.Add("reached main: last pipeline commit $lastBot, served files clean in git")
  }
} catch { [void]$findings.Add("REACHED-MAIN CHECK FAILED: could not ask git whether today's prices reached main ($($_.Exception.Message)) - the one check that speaks for the READER is unavailable") }

# ---- 5. ad health ------------------------------------------------------------
$adsc = Join-Path $root 'audit-ad-status.ps1'
if (Test-Path $adsc) {
  # NO 2>&1 (fixed 2026-08-22, same class as the capture-run downstream call).
  # This script sets EAP=Stop, and in PS 5.1 redirecting a native child's stderr
  # turns each line into a NativeCommandError that TERMINATES the caller. The day
  # audit-ad-status.ps1 writes a single warning, this watchdog would die right here
  # - silently skipping checks 6-8, which are the browser-flag and store-freshness
  # checks. A watchdog that stops examining halfway and still exits through its own
  # summary is worse than no watchdog: it reports on what it managed to reach.
  # Latent when found (audit-ad-status is currently quiet); fixed while it is cheap.
  $adOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $adsc -OutDir $OutDir -Today $todayS
  $adRc = $LASTEXITCODE
  $line = ($adOut | Where-Object { $_ -match 'stores needing a pull' } | Select-Object -First 1)
  if ($adRc -ne 0) { [void]$findings.Add("AD STALE: $line") } else { [void]$ok.Add(($line -replace '\s+', ' ').Trim()) }
}

# ---- 5a. ad FORECAST: is next_pull actually landing on the day? --------------
# A DIFFERENT QUESTION FROM 5, and that is why it is its own check rather than
# more output from audit-ad-status. Check 5 asks "is an ad closed RIGHT NOW",
# which is about today. This asks "has the PREDICTION been right", which is about
# the record - and until 2026-09-08 nothing asked it at all, though the answer had
# been sitting one line from the question in ad-schedule.json since June.
#
# It is a RATCHET and it is silent on the two misses already on the record. A
# rise means a store newly skipped an entire ad cycle, which means the board
# carried a stale price for a week. Same no-2>&1 rule as check 5, for the same
# reason: this script sets EAP=Stop and a redirected native stderr would kill the
# watchdog here and silently skip checks 6 to 8.
$adfc = Join-Path $root 'audit-ad-forecast.ps1'
if (Test-Path $adfc) {
  $afOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $adfc
  $afRc = $LASTEXITCODE
  $afLine = ($afOut | Where-Object { $_ -match 'AD FORECAST FAILED|CADENCE DRIFT|^PASSED|BASELINE WRITTEN|COULD NOT EVALUATE' } | Select-Object -First 1)
  if ($afRc -eq 2) { [void]$findings.Add("AD FORECAST: $afLine") }
  elseif ($afRc -eq 3) { [void]$findings.Add("AD FORECAST could not be evaluated: $afLine") }
  else { [void]$ok.Add((($afLine -replace '\s+', ' ').Trim())) }
}

# ---- 5a2. the sidecar's declared package pins against what is actually installed --------------
# WHY IT RUNS HERE AND NOT IN run-gates (2026-09-08, backlog I58). The check is hermetic - it reads
# two things on disk - but only where sidecar\.venv EXISTS. A CI runner, a worktree and a fresh
# checkout have none, and the check correctly reports BLIND at exit 3 there; run-gates treats every
# nonzero exit from a $static entry as a FAIL, so registering it there would paint the gate red for a
# condition nobody can clear, which is the red-on-day-one shape the estate already forbids. run-gates
# discovers its -SelfTest, which IS hermetic everywhere. The LIVE half belongs on the box with the
# venv, and this watchdog is that box. Same no-2>&1 rule as check 5.
#
# WHAT IT CATCHES: sentence-transformers is the only import path for the matcher's whole score space,
# and on 2026-09-08 requirements.txt declared 5.1.2 against an installed 5.6.1. A minor-version move
# there shifts a score space without shifting a number anybody watches, and nothing had ever compared
# the file to the venv.
$ppc = Join-Path (Split-Path $root -Parent) 'ops\audit-python-pins.ps1'
if (Test-Path $ppc) {
  $ppOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $ppc
  $ppRc = $LASTEXITCODE
  $ppLine = ($ppOut | Where-Object { $_ -match 'PYTHON PINS AUDIT FAILED|PYTHON PINS AUDIT BLIND|^python-pins: PASSED' } | Select-Object -First 1)
  if ($ppRc -eq 2) { [void]$findings.Add("PYTHON PINS: $ppLine") }
  elseif ($ppRc -eq 3) { [void]$findings.Add("PYTHON PINS could not be evaluated: $ppLine") }
  else { [void]$ok.Add((($ppLine -replace '\s+', ' ').Trim())) }
}

# ---- 5a3. the identity graph's SHAPE, which no row-level check can see -----------------------
# WHY HERE AND NOT IN run-gates (2026-09-09, backlog I73/I75/I76). It needs graph\sqlite\graph.db,
# which a CI runner and a worktree do not have - it reports BLIND at exit 3 there, and run-gates
# fails any nonzero from a $static entry, so registering it would paint the gate red for a
# condition nobody can clear. run-gates discovers its --selftest, which is pure. The LIVE half
# belongs on the box with the database, which is this one.
#
# WHAT IT CATCHES: a node the graph stopped being able to reach. Nothing is wrong with any
# individual row, so every row-level data-quality check passes on exactly the rows it finds.
# An INVERTED ratchet is not needed - orphans and components may legitimately fall - so it is the
# ordinary shape: a RISE fails, and --accept records a deliberate one.
$gsc = Join-Path (Split-Path $root -Parent) 'graph\audit_graph_shape.py'
$pyExe = 'C:\Codex\Python312\python.exe'
if ((Test-Path $gsc) -and (Test-Path $pyExe)) {
  $gsOut = & $pyExe $gsc
  $gsRc = $LASTEXITCODE
  $gsLine = ($gsOut | Where-Object { $_ -match 'GRAPH SHAPE AUDIT FAILED|GRAPH SHAPE AUDIT BLIND|^graph-shape: PASSED|^BASELINE WRITTEN' } | Select-Object -First 1)
  if ($gsRc -eq 2) { [void]$findings.Add("GRAPH SHAPE: $gsLine") }
  elseif ($gsRc -eq 3) { [void]$findings.Add("GRAPH SHAPE could not be evaluated: $gsLine") }
  else { [void]$ok.Add((($gsLine -replace '\s+', ' ').Trim())) }
}

# ---- 5a2b. the watchdog asserts its OWN inputs before reading any of them ---------------------
# 2026-09-09, backlog I45 rung 2. Rung 1 measured the surface and narrowed it hard: 172 first-party
# scripts consume another stage's output and 97 defend nothing, but an assertion across 97 consumers
# would be a large change for a risk that has fired twice. **The scheduled entry points are the whole
# surface that matters**, because a scheduled task is the only consumer nobody is watching.
#
# THE WATCHDOG IS THE RIGHT FIRST STAGE TO ASSERT, and not because it is easiest: it is the one
# scheduled stage whose entire job is REPORTING, so a could-not-evaluate here costs a line in a report
# rather than a board that does not get built. Asserting inside capture-run.ps1 stops the day's capture
# if the window is wrong, and that wants somebody watching the next run - which the item itself said.
#
# MISSING IS NOT STALE AND NEITHER IS FRESH. lib\input-assert.ps1 keeps those three apart; collapsing
# any two is the bug it exists to prevent, and a worktree legitimately has no board.
. (Join-Path (Split-Path $root -Parent) 'lib\input-assert.ps1')
$iaRc = Assert-TcInputs -Stage 'capture-watchdog' -Inputs @(
  @{ Path = (Join-Path $OutDir 'logs\capture-run-status.json'); Producer = 'grocery\capture-run.ps1 (08:00 Daily Capture)'; MaxAgeHours = 26.0 }
)
if ($iaRc -ne 0) {
  [void]$findings.Add('INPUT ASSERT: the watchdog''s own inputs are missing or stale - see the input-assert lines above. It has NOT evaluated them, which is not the same as finding nothing.')
}

# ---- 5a3a. promotion holds: the READ, on a cadence. The CLEAR never is. -----------------------
# RULED BY BRAD 2026-09-09 (backlog I92): schedule the read, never the clear.
#
# `--recheck-holds` is READ-ONLY - it promotes nothing, clears nothing, and does not run the guard
# suite - so a daily run costs one board read and can change no state. What it buys is that the
# information arrives without anyone remembering to ask: sixteen holds sat unexamined for nineteen
# days, and thirteen of them turned out to be inert, which nobody could have known without looking.
#
# WHY THE CLEAR STAYS HUMAN, and it is not caution for its own sake. The kosher-salt hold exists
# because its pattern CROSS-CLAIMS the sea-salt cell, and the one row it still matches today is that
# exact cell. A hold that aged out on a timer would have re-armed a known-wrong claim on a live board.
# The report now separates `identity` reasons (about what a pattern MEANS - these can never expire)
# from `board` reasons (about one week's products - these are the re-testable ones).
#
# Reported as a heads-up, never a finding: nothing here is broken, and a chain entry that cries wolf
# on a healthy state is one people learn to skip.
$rhs = Join-Path (Split-Path $root -Parent) 'graph\learning\promote_aliases.py'
$pyExe3 = 'C:\Codex\Python312\python.exe'
if ((Test-Path $rhs) -and (Test-Path $pyExe3)) {
  # --record (WS 7c, 2026-09-10): today's readings go to graph\learning\hold-rechecks.jsonl, one row per
  # hold per day, so 30 inert days can become a clear PROPOSAL in the review packet. It still clears nothing.
  $rhOut = & $pyExe3 $rhs --recheck-holds --record
  $rhRc = $LASTEXITCODE
  $rhLine = ($rhOut | Where-Object { $_ -match '^REASON CLASS|^PROMOTION HOLDS|BOARD IS ABSENT' } | Select-Object -First 1)
  if ($rhRc -ne 0) { [void]$findings.Add("PROMOTION HOLDS could not be re-checked: $rhLine") }
  else {
    [void]$ok.Add((($rhLine -replace '\s+', ' ').Trim()))
    $rhProp = ($rhOut | Where-Object { $_ -match '^CLEAR PROPOSALS' } | Select-Object -Last 1)
    if ($rhProp) { [void]$ok.Add((($rhProp -replace '\s+', ' ').Trim())) }
  }
}

# ---- 5a3a2. the git hooks that run the change-time gate are still live (WS 10d, 2026-09-10) -----
# Five files in this tree cited ops\audit-hook-installed.ps1 as asserting this, and it did not exist.
# It lives HERE rather than in run-gates because run-gates is invoked BY the pre-push hook - a hook
# check inside it can only prove the hook it is running in - and because a worktree has no hooks
# directory, so every spawned agent's gate would go red. Once a day on the main checkout, a missing or
# edited hook is a real finding: it means pushes are silently ungated again, which CLAUDE.md records
# happening for a month.
$hookAudit = Join-Path (Split-Path $root -Parent) 'ops\audit-hook-installed.ps1'
if (Test-Path $hookAudit) {
  $haOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $hookAudit
  $haRc = $LASTEXITCODE
  $haLine = ($haOut | Where-Object { $_ -match '^hook-installed:' } | Select-Object -Last 1)
  if ($haRc -eq 2) { [void]$findings.Add("GIT HOOKS NOT LIVE - pushes are ungated: $haLine") }
  elseif ($haRc -ne 0) { [void]$findings.Add("GIT HOOKS could not be checked (exit $haRc): $haLine") }
  else { [void]$ok.Add((("git hooks " + $haLine) -replace '\s+', ' ').Trim()) }
}

# ---- 5a3a3. ratchet trends: a detector flat for 30 days at a non-zero mark may have stopped looking -----
# WS 10e (2026-09-10). A REPORT: its lines ride the healthy-checks block of this mail and the brain digest.
$rtr = Join-Path (Split-Path $root -Parent) 'ops\report-ratchet-trends.ps1'
if (Test-Path $rtr) {
  $rtOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $rtr
  foreach ($l in @($rtOut | Where-Object { "$_" -match '^\s*(STOPPED LOOKING|ratchet trends:)' })) {
    [void]$ok.Add((("$l") -replace '\s+', ' ').Trim())
  }
}

# ---- 5a3b. a graph.db SCHEMA change that left no record --------------------------------------
# RULED BY BRAD 2026-09-09 (backlog I41): a written record plus a detector, and NOT a staged-migration
# capability - nothing here knows how to do expand-contract, backfill or rollback.
#
# WHY THE DETECTOR IS THE HALF THAT MAKES THE RECORD REAL. A written procedure nobody is forced to
# follow is an intention, and an intention has no exit code. The ONLY way to clear this is --accept,
# and --accept is what appends to docs/SCHEMA-CHANGES.md - so the record cannot be skipped.
#
# WHY HERE AND NOT run-gates: it needs graph\sqlite\graph.db, which a worktree and a CI runner do not
# have, so it reports BLIND at exit 3 there and would paint the gate red for a condition nobody can
# clear. run-gates discovers its --selftest, which is pure.
$scc = Join-Path (Split-Path $root -Parent) 'graph\audit_schema_change.py'
$pyExe2 = 'C:\Codex\Python312\python.exe'
if ((Test-Path $scc) -and (Test-Path $pyExe2)) {
  $scOut = & $pyExe2 $scc
  $scRc = $LASTEXITCODE
  $scLine = ($scOut | Where-Object { $_ -match 'THE SCHEMA MOVED|schema unchanged|BLIND' } | Select-Object -First 1)
  if ($scRc -eq 2) { [void]$findings.Add("GRAPH SCHEMA: $scLine") }
  elseif ($scRc -eq 3) { [void]$findings.Add("GRAPH SCHEMA could not be evaluated: $scLine") }
  else { [void]$ok.Add((($scLine -replace '\s+', ' ').Trim())) }
}

# ---- 5a4. the monthly member cohort snapshot -------------------------------------------------
# RULED BY BRAD 2026-09-09 (backlog I98): start it now, automated, AGGREGATE COUNTS ONLY.
#
# WHY IT LIVES ON A DAILY CHAIN WHEN IT IS MONTHLY. There is no monthly chain, and the snapshot is
# idempotent per calendar month - it checks the series before appending - so a daily attempt costs one
# Ghost read and writes nothing on the other twenty-nine days.
#
# WHY IT IS WORTH AUTOMATING AT ALL. Ghost holds CURRENT status and no status history, so a member who
# cancelled in month 2 and one who cancelled in month 8 are indistinguishable in any single pull. The
# series is the only way the retention curve can ever exist, it builds strictly forward, and a month
# that is not snapshotted cannot be reconstructed later from anything Ghost holds.
#
# THE PRIVACY BOUNDARY: aggregate only. No member row, no id, no address, here or anywhere - the same
# boundary Brad ruled on for I97, enforced in the script by a structure that can hold only month
# strings, status strings and integers.
#
# THE FRESHNESS CHECK IS THE POINT OF THE SECOND CALL. Every other threshold in this estate is an upper
# bound and cannot fire on nothing happening; the failure mode here is the producer going QUIET, which
# would silently cost a month of curve. -CheckFresh is the floor that watches for that absence.
$mcs = Join-Path (Split-Path $root -Parent) 'ops\member-cohorts.ps1'
if (Test-Path $mcs) {
  $mcOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $mcs -AppendHistory
  $mcRc = $LASTEXITCODE
  $mcLine = ($mcOut | Where-Object { $_ -match 'history:|REFUSED|BLIND' } | Select-Object -First 1)
  if ($mcRc -eq 2) { [void]$findings.Add("MEMBER COHORTS refused to write: $mcLine") }
  elseif ($mcRc -eq 3) { [void]$ok.Add('member cohorts: BLIND (no Ghost key on this box) - no snapshot taken') }
  else {
    $mcFresh = & powershell -NoProfile -ExecutionPolicy Bypass -File $mcs -CheckFresh
    $mcFreshRc = $LASTEXITCODE
    $mcFreshLine = ($mcFresh | Where-Object { $_ -match 'series fresh|HAS STOPPED|BLIND' } | Select-Object -First 1)
    if ($mcFreshRc -eq 2) { [void]$findings.Add("MEMBER COHORT SERIES: $mcFreshLine") }
    else { [void]$ok.Add((($mcLine -replace '\s+', ' ').Trim())) }
  }
}

# ---- 5b. rollback / instant-savings windows about to expire ------------------
# THE OTHER HALF OF "STALE IS NOT A BAD THING". Everyday prices are allowed to be a quarter old;
# a PROMO price is not. Walmart, Sam's Club and Fareway publish no end date for a rollback, so
# rollback-ttl-lib anchors a 30-day window to first detection and the builders revert the price when
# it lapses. That revert is invisible until it happens: a wave of cells quietly gets more expensive.
# Reported as a COUNT with the nearest date, not per item - it is a heads-up, never a failure.
#
# WHAT THIS CHECK MEASURES, AND WHY IT CHANGED (2026-08-25). It used to report the number of LEDGER
# entries past their TTL and say "if this count does not fall after the next capture, the revert is
# not running". THAT TEST CAN NEVER PASS. rollback-first-seen.json is append-only by design - see
# rollback-ttl-lib.ps1: first_seen is "written ONCE per (store, item) and is NEVER advanced", and
# nothing prunes an entry - so once a window passes day 30 it stays past day 30 forever and the count
# only ever climbs. It sat at exactly 47 for four days while the board was in fact reverting every
# one of them, which is a false alarm that teaches the reader to skip this section - the failure mode
# a watchdog can least afford. The FAILURE the finding was reaching for is a board that still SELLS
# an expired promo, so that is what is counted now: live cells whose ad window closed before this
# board's date. That number can fall, and zero is provable. The ledger count is kept, demoted to an
# ok line, and labelled cumulative so its flatness is never read as a stall again.
try {
  $rbLedger = Join-Path $root 'rollback-first-seen.json'
  if (Test-Path $rbLedger) {
    $rb = Get-Content $rbLedger -Raw -Encoding UTF8 | ConvertFrom-Json
    $ttl = if ($rb.ttl_days) { [int]$rb.ttl_days } else { $ROLLBACK_TTL }
    $expired = 0; $soon = 0; $nextDate = ''; $ledgerTotal = 0
    foreach ($e in @($rb.entries)) {
      $fs = [string]$e.first_seen
      if ($fs.Length -lt 10) { continue }
      try { $exp = ([datetime]::ParseExact($fs, 'yyyy-MM-dd', $null)).AddDays($ttl) } catch { continue }
      $ledgerTotal++
      $daysLeft = [int]($exp - (Get-Date $todayS)).TotalDays
      if ($daysLeft -lt 0) { $expired++ }
      elseif ($daysLeft -le 7) {
        $soon++
        if (-not $nextDate -or $exp.ToString('yyyy-MM-dd') -lt $nextDate) { $nextDate = $exp.ToString('yyyy-MM-dd') }
      }
    }

    # THE HALF THAT CAN ACTUALLY FAIL: an expired window still priced on the board readers see.
    # price-table-<today>.json is the per-cell artifact that carries ad_to, so it is what gets asked.
    $ptf = Join-Path $OutDir "price-table-$todayS.json"
    if (Test-Path $ptf) {
      $boardDate = Get-Date $todayS
      $staleCells = 0; $adCells = 0; $oldestClosed = ''
      $pt = Get-Content $ptf -Raw -Encoding UTF8 | ConvertFrom-Json
      foreach ($it in @($pt.items)) {
        foreach ($sp in $it.stores.PSObject.Properties) {
          $cell = $sp.Value
          if ($null -eq $cell.ad) { continue }
          $adCells++
          $at = [string]$cell.ad_to
          if ($at -notmatch '^\d{4}-\d{2}-\d{2}$') { continue }
          try { $atd = [datetime]::ParseExact($at, 'yyyy-MM-dd', $null) } catch { continue }
          if ($atd -lt $boardDate) {
            $staleCells++
            if (-not $oldestClosed -or $at -lt $oldestClosed) { $oldestClosed = $at }
          }
        }
      }
      if ($staleCells -gt 0) {
        [void]$findings.Add(("ROLLBACK NOT REVERTING: {0} of {1} live board cell(s) still serve a promo price whose window has closed (oldest closed {2}). The builders should have reverted these to everyday pricing - THIS is the count that must fall after the next capture." -f $staleCells, $adCells, $oldestClosed))
      } else {
        [void]$ok.Add(("rollback revert: 0 of {0} live ad cell(s) carry a closed window - every lapsed promo reverted to everyday pricing" -f $adCells))
      }
    } else {
      # Say so rather than pass silently: an unrun check must never read as a clean one.
      [void]$ok.Add(("rollback revert: NOT CHECKED - price-table-$todayS.json is not present"))
    }

    if ($expired -gt 0) {
      # DELIBERATELY an ok line and not a finding, for the reason set out in the header: this number
      # is cumulative and does not fall, so on its own it can never be a regression signal.
      [void]$ok.Add(("rollback ledger: {0} of {1} window(s) past their {2}-day TTL - cumulative, and NOT expected to fall (first_seen never advances, entries are never pruned); what matters is whether any reach the board, checked above" -f $expired, $ledgerTotal, $ttl))
    }
    if ($soon -gt 0) {
      [void]$ok.Add(("rollback windows: {0} expire within 7 days (first {1}) - those cells revert to everyday pricing" -f $soon, $nextDate))
    } elseif ($expired -eq 0) {
      [void]$ok.Add(("rollback windows: none expired, none expiring within 7 days ({0}-day TTL)" -f $ttl))
    }
  }
} catch { [void]$ok.Add('rollback window check skipped: ' + $_.Exception.Message) }

# ---- 6. browser work left undone --------------------------------------------
# The browser stores cannot be captured headlessly, so the runner leaves a flag.
# A flag older than a day means nobody worked the list and those stores are
# silently aging - which is exactly what happened to Fareway for five days.
# ONE FINDING, NOT ONE PER DAY (2026-08-22). capture-run writes a NEW dated flag every
# run and NOTHING ever deletes one, so this loop emitted a separate finding per unworked
# day - an email that grows by a line a day and, within a fortnight, buries the finding
# that actually matters (ROTATION STALLED, check 7) under a wall of near-identical lines.
# This file's own header warns against exactly that: "flagging it daily would train the
# reader to ignore this email." It became urgent on 2026-08-22, when the browser capture
# routine was retired and the flags stopped being worked by anything at all.
# Report the BACKLOG as one line - how many, and how old the oldest is - and prune the
# ancient ones so out\ does not accumulate without bound. Pruning is capped well beyond
# the point the message is made; it is housekeeping, not the signal.
$flags = @(Get-ChildItem (Join-Path $OutDir 'browser-capture-due-*.flag') -EA SilentlyContinue)
$staleFlags = @($flags | Where-Object { ((Get-Date) - $_.LastWriteTime).TotalDays -gt 1.5 })
# THE FINDING ITSELF NOW LIVES BELOW CHECK 7 (moved 2026-08-25). A flag is a TODO, and whether the todo
# is DONE can only be answered by the per-store freshness scan, which has not run yet at this point in
# the file. $staleFlags is carried down to it. Only the pruning stays here, because that is housekeeping
# and needs nothing but the file dates.
foreach ($f in ($flags | Where-Object { ((Get-Date) - $_.LastWriteTime).TotalDays -gt 45 })) {
  try { Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue } catch { }
}

# ---- 6a. DID EACH BROWSER STORE'S CAPTURE LAND TODAY? (2026-09-19, Brad's ruling) ------------------------------
# Brad's own Chrome captures Walmart, Sam's Club, Aldi and Fareway every morning (the grocery-browser-stores-refresh
# Claude task, one tab per store, concurrently), and the 08:00 driver falls back for Fareway and Sam's only. That task
# stopped on 2026-09-13 on a usage limit and nothing noticed for six days; the board's defect rate doubled over the
# same stretch. A same-morning check turns that into hours: at 10:30 every one of the four must have a capture DATED
# TODAY holding at least one data row, or it is scheduled work that did not land. One finding naming the stores.
if (-not (Get-Command Get-BrowserStoresToDrive -ErrorAction SilentlyContinue)) { . (Join-Path $root 'capture-policy-lib.ps1') }
$bcFiles = Get-BrowserCaptureFiles $OutDir $todayS
# The four stores come from stores.json (pull_profile.surface 'browser...'), never a copy here (queue 2026-09-19-405c73).
# NOT YET IS NOT MISSING (2026-09-22, queue 2026-09-22-2000e1): graded against the PRODUCER's slot, never this run's
# own 10:30 clock. Inside the slot today's stores are NOT YET (counted on the marker) and YESTERDAY's closed slot is
# graded instead, so a miss still pages, a day later, rather than never. Get-BrowserCaptureVerdict holds the rule.
$bcStores = Get-BrowserSurfaceStores -Root $root
$bcDay = [datetime]::ParseExact($todayS, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
$bcYS = $bcDay.AddDays(-1).ToString('yyyy-MM-dd')
$bcYFiles = Get-BrowserCaptureFiles $OutDir $bcYS
$bcYGraded = Test-Path -LiteralPath (Get-BrowserSlotStampPath $OutDir $bcYS)
$bcSlot = Get-ProducerSlot 'grocery-browser-stores-refresh' $bcDay
$bcNow = if ($Today) { $bcDay.AddHours(10.5) } else { Get-Date }
$bcV = Get-BrowserCaptureVerdict -Stores $bcStores -TodayFiles $bcFiles -YesterdayFiles $bcYFiles -Now $bcNow -Slot $bcSlot -YesterdayGraded $bcYGraded
$bcSlotTxt = if ($bcSlot) { ('slot ' + $bcSlot.start.ToString('HH:mm') + '-' + $bcSlot.end.ToString('HH:mm')) } else { 'no declared slot' }
$bcNotYet = @($bcV.NotYet)
foreach ($bcF in @(Get-BrowserCaptureFindings -V $bcV -TodayS $todayS -YesterdayS $bcYS -SlotTxt $bcSlotTxt)) { if ($bcF) { [void]$findings.Add($bcF) } }
if ($bcYGraded) { [void]$ok.Add(("browser capture $bcYS was graded at its slot close (" + (Get-BrowserSlotStampPath $OutDir $bcYS) + "), so it is not graded again here")) }
if ($bcNotYet.Count) {
  [void]$ok.Add(("browser capture NOT YET: " + ($bcNotYet -join ', ') + " - nothing dated $todayS yet, and the producer's $bcSlotTxt is still open (grocery-browser-stores-refresh). Not missing and not ok: graded after the slot, at tomorrow's run if not before."))
}

# ---- 7, 8, 9 (header). THE BOT CHECKOUT FLOORS: a stale checkout, a capture backlog, the sync kill switch (W1.1) -----
# Get-CheckoutFloor, Get-CaptureBacklog and Get-SyncKillSwitch above hold the rules. Each reads git and the filesystem
# of THIS checkout (the watchdog's own repo root: the main checkout when the 10:30 task runs), writes nothing, and still
# fires when capture-run has stopped. A check that throws is a BLIND finding, never a silent pass. CHECKOUT reads the
# real clock, since git's state is live; BACKLOG takes the same 10:30 pin as check 6a when -Today is given.
$flRepo = Split-Path $root -Parent
$flNow = if ($Today) { $bcDay.AddHours(10.5) } else { Get-Date }
$flMarker = ('CHECKOUT-FLOOR behind=-1 oldest_age_s=-1 bar_s={0} stale=0 remote=unread blind=1' -f $script:CheckoutStaleBarSec)
try {
  $coF = Get-CheckoutFloor -Repo $flRepo -Now (Get-Date)
  foreach ($x in $coF.findings) { [void]$findings.Add($x) }
  foreach ($x in $coF.ok) { [void]$ok.Add($x) }
  $flMarker = $coF.marker
} catch { [void]$findings.Add('CHECKOUT: BLIND - the check threw (' + $_.Exception.Message + '), so whether the bot checkout is behind origin is unknown this run.') }
try {
  $blF = Get-CaptureBacklog -Repo $flRepo -TodayS $todayS -Now $flNow
  foreach ($x in $blF.findings) { [void]$findings.Add($x) }
  foreach ($x in $blF.ok) { [void]$ok.Add($x) }
} catch { [void]$findings.Add('CAPTURE BACKLOG: BLIND - the check threw (' + $_.Exception.Message + '), so whether captures from before today are uncommitted is unknown this run.') }
try {
  $ksF = Get-SyncKillSwitch -Repo $flRepo
  foreach ($x in $ksF.findings) { [void]$findings.Add($x) }
  foreach ($x in $ksF.ok) { [void]$ok.Add($x) }
} catch { [void]$findings.Add('KILL SWITCH: BLIND - the check threw (' + $_.Exception.Message + '), so whether the checkout sync is disabled is unknown this run.') }

# ---- 10. PRODUCTION INTRUDERS, REPORT ONLY (design\PLAN-bot-dedicated-checkout-2026-09-25.md W0.3) -----------------
# Who owns each dirty or untracked path in this checkout: the bot (lib\bot-paths.ps1), a registered scheduled writer
# (ops\production-writers.json), or nobody. Records one row a day in <git common dir>\tc-production-intruders.jsonl,
# outside every working tree. It is an ok line, never a finding: D4's set-aside waits for 7 clean days of these rows,
# and a count nobody has ruled on must not page. A BLIND census says BLIND in the line. It moves nothing.
try {
  . (Join-Path $flRepo 'lib\production-writers.ps1')
  $piChk = Invoke-TcProductionCensusCheck -Repo $flRepo -RegistryPath (Join-Path $flRepo 'ops\production-writers.json') -Record -Date $todayS
  [void]$ok.Add($piChk.line)
} catch { [void]$ok.Add('production intruders: BLIND - the check threw (' + $_.Exception.Message + ')') }


# ---- 6b. IS ANYTHING STILL HOLDING THE RUN LOG MUTE? (2026-08-25) ------------------------------------
# check-ad-cycles.ps1 already survives a locked ad-cycle-log.txt: it diverts the run's trail to a dated
# LOCKED-<day> sidecar, and the next run that CAN write the primary folds the sidecar back in and deletes
# it. Both halves worked. What nothing checked was the case where the lock never lifts.
#
# On 2026-08-22 at 08:53 an abandoned Claude session left `tail -n 0 -F grocery/ad-cycle-log.txt` running.
# It held the file for 67 HOURS. Every run from 08-22 on diverted to a sidecar, and the recovery fold
# correctly refused to delete anything it could not first append - so the sidecars simply accumulated:
# three of them, 3,560 lines, the entire trail of three days of runs, sitting outside the log that is
# supposed to hold them and outside git. The recovery design was right. It was just waiting for a run
# that could write, and no such run was ever going to come while that process lived.
#
# A PRIOR-DAY SIDECAR IS ITSELF THE ALARM. Its existence means today's fold could not append, which means
# the primary is still held. That is a one-line check and it would have fired on the morning of 08-23.
# Name the holder if we can - "something has it" sends the reader hunting; a PID and a command line ends
# the question. Get-CimInstance is best-effort and must never take the watchdog down with it.
$sidecars = @(Get-ChildItem (Join-Path $PSScriptRoot 'ad-cycle-log.LOCKED-*.txt') -EA SilentlyContinue |
              Where-Object { $_.BaseName -match 'LOCKED-(\d{4}-\d{2}-\d{2})$' -and $Matches[1] -lt $todayS })
if ($sidecars.Count) {
  $scLines = 0
  foreach ($sc in $sidecars) { try { $scLines += @(Get-Content $sc.FullName -EA SilentlyContinue).Count } catch { } }
  $oldestSc = ($sidecars | Sort-Object Name | Select-Object -First 1)
  $holder = ''
  try {
    $primary = Join-Path $PSScriptRoot 'ad-cycle-log.txt'
    try { $fsT = [System.IO.File]::Open($primary, 'Append', 'Write', 'None'); $fsT.Close() }
    catch {
      # NEVER ACCUSE OURSELVES. Command-line matching is a heuristic, and the watchdog's own launch chain
      # mentions this log whenever a human runs it by hand from a shell one-liner - the first draft of
      # this check named the parent PowerShell that started it, which is a false lead wearing a PID.
      # Walk our own ancestry out of the candidate set first, then prefer the documented culprits
      # (tail/bash) over any shell, so the reader gets the process actually sitting on the handle.
      $mine = @{}; $walk = $PID
      for ($h = 0; $h -lt 12 -and $walk; $h++) {
        $mine[[int]$walk] = $true
        $pp = Get-CimInstance Win32_Process -Filter ("ProcessId=" + [int]$walk) -EA SilentlyContinue
        if (-not $pp) { break }
        $walk = $pp.ParentProcessId
      }
      $cands = @(Get-CimInstance Win32_Process -EA SilentlyContinue |
                 Where-Object { -not $mine.ContainsKey([int]$_.ProcessId) -and [string]$_.CommandLine -like '*ad-cycle-log*' })
      $pick = @($cands | Where-Object { $_.Name -in @('tail.exe','bash.exe') } | Select-Object -First 1)
      if (-not $pick.Count) { $pick = @($cands | Select-Object -First 1) }
      if ($pick.Count) { $holder = "  HOLDER: pid $($pick[0].ProcessId) ($($pick[0].Name)) since $($pick[0].CreationDate) :: " + ([string]$pick[0].CommandLine).Trim() }
      else { $holder = '  HOLDER: the primary log is locked but no other process command line names it - check open handles (Sysinternals handle.exe / Resource Monitor).' }
    }
  } catch { }
  # SINGLE-QUOTED, DELIBERATELY. In a double-quoted PowerShell string the backtick before "tail" is an
  # escape and 'tail -F' silently became a TAB character in the alert - the check fired correctly and the
  # sentence telling the reader what to look for had eaten its own subject. Caught by running it.
  $mute = 'RUN LOG HELD MUTE: {0} prior-day LOCKED sidecar(s) survive, oldest {1}, holding {2} line(s) of run history that never reached ad-cycle-log.txt. The recovery fold only deletes a sidecar it could append first, so a surviving one means the primary is STILL locked by another process - kill it and the next run folds them back automatically. An abandoned "tail -F" from a dead session did this for 67 hours from 2026-08-22.{3}'
  [void]$findings.Add(($mute -f $sidecars.Count, $oldestSc.Name, $scLines, $holder))
}


# ---- 7. did each STORE actually contribute a fresh row, or just the pipeline? -------------------------
# THE HOLE THIS CLOSES. Checks 1-6 are all pipeline-level: the tasks fired, a board exists, it published.
# Every one of them passes while an individual store captures NOTHING, because carry-forward keeps that
# store's row count up and the board builds and ships regardless. Measured 2026-08-20: Fareway's sanctioned
# agent had gone structurally blind (the storefront went client-rendered, so its fetch-and-regex probe
# matched zero products and returned EMPTY for every term). A full sweep would have exited 0, raised no
# wall, and recorded that Fareway carries none of the ~700 things it sells - and this watchdog would have
# reported healthy, because a board WAS built and it WAS published.
#
# So this asks the one question the others do not: whose prices are actually NEW today?
#
# TWO POPULATIONS, TWO BARS, because one bar would be either noise or nothing:
#   HEADLESS lanes (Hy-Vee, Baker's, Family Fare) pull themselves. On a day the 08:00 job ran, a lane that
#     contributed zero fresh rows is broken - that is the Fareway shape, and it is a finding.
#   BROWSER lanes (Walmart, Sam's Club, Fareway, Aldi) are bot-walled and need a human in Chrome, so zero
#     rows on any given day is normal and flagging it daily would train the reader to ignore this email.
#     They are judged on AGE instead: under a 90-day rotation a store must keep contributing SOMETHING or
#     it can never finish a quarter. Seven days without a single fresh row means its rotation has stalled.
#     On the day this shipped that was true of Sam's Club (19d) and Walmart (9d) - both real, both already
#     carrying rescue worklists. It is not a quiet start; it is an accurate one.
# The headless lanes come from stores.json (pull_profile.surface 'server...'), never a copy here: convert on touch (Brad,
# 2026-09-19, backlog I192; plan-2026-09-21-5.json). The complement of Get-BrowserSurfaceStores above. An unreadable
# registry names no lane, and that is said as a finding rather than read as "every lane is fine".
$HEADLESS_LANES = @()
try { $HEADLESS_LANES = @(@((ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $root 'stores.json')))).stores) | Where-Object { $_.pull_profile -and ([string]$_.pull_profile.surface) -match '^server' } | ForEach-Object { [string]$_.name }) } catch { $HEADLESS_LANES = @() }
if ($HEADLESS_LANES.Count -eq 0) { [void]$findings.Add('HEADLESS LANES UNKNOWN: stores.json named no server-surface store (or could not be read), so no headless lane was checked for fresh rows. That is not a pass.') }

# THE RULER WAS WRONG (Brad, 2026-08-22: "state is not a bad thing"). This check used a flat
# $BROWSER_STALE_DAYS = 7 and called a store STALLED the moment it went a week without a fresh row.
# That contradicts the policy the estate actually runs on, so it cried wolf on stores behaving exactly
# as designed - and a daily false alarm is how a reader learns to skip this email, which then hides
# the real one. The two governing numbers, read from the libraries that own them rather than
# re-typed here (a copied constant is a constant that will disagree - [[two-copies-of-a-rule]]):
#
#   EVERYDAY prices  -> a 90-day quarter. Every store buys ~total_terms/90 terms per day and rows are
#                       carried MaxCarryDays. An everyday price is SUPPOSED to be up to a quarter old;
#                       it only becomes a problem at the carry cliff, when rows actually leave the board.
#   ROLLBACK / INSTANT SAVINGS at Walmart and Sam's -> a 30-day TTL from FIRST detection, because
#                       neither store publishes an end date (rollback-ttl-lib.ps1 owns that rule and
#                       the builders already enforce it). This is the number that is genuinely tight.
#
# So the question is no longer "is this store older than a week" but "is anything about to leave the
# board, or already past its promised window". Warn band before the cliff, not at it: a store that
# only learns it is expiring on the day it expires cannot be rescued in time.
. (Join-Path $root 'capture-policy-lib.ps1')
. (Join-Path $root 'rollback-ttl-lib.ps1')
$CARRY_DAYS = Get-PolicyMaxCarryDays          # 90 - rows older than this expire off the board
$QUARTER_DAYS = Get-PolicyQuarterDays         # 90 - one full rotation of the catalogue
$ROLLBACK_TTL = Get-RollbackTtlDays           # 30 - Walmart/Sam's promo window
$CLIFF_WARN_DAYS = 14                         # notice before the carry cliff, not on it
# A store that has landed nothing for a third of a quarter cannot finish the rotation on time. This
# is DEBT, reported so it is visible, not an emergency - it is the number Brad reads to decide whether
# to spend a browser session, and it must not be dressed up as a failure.
$ROTATION_DEBT_DAYS = [int][math]::Round($QUARTER_DAYS / 3)
$freshByStore = @{}; $newestByStore = @{}
# A PROBE IS NOT A CAPTURE (2026-08-22). This glob used to swallow
# out\regular\hunter-<store>-regular-<date>.json - files the Recipe Hunter's pricing
# lane promotes via promote-ingredient-queue.ps1 so compare-deals can read them. They
# are a handful of adjudicated ingredient prices, not a rotation slice, and on
# 2026-08-22 all seven stores had one dated 2026-08-16. The effect: Walmart's real
# newest capture was 2026-08-11 (11d, over the 7d line) and Sam's Club was 2026-08-01
# (21d), yet BOTH read "ok ... 6d" here and this check stayed silent about two stores
# whose rotation had genuinely stalled. Exactly the [[promoted-file-is-not-a-capture]]
# shape: a thin dated file becomes the "newest capture" and alibis the stale ones.
# That matters more now than when it shipped - as of 2026-08-22 the browser stores have
# no scheduled capture at all, so this finding is the ONLY thing that reports them going
# cold. Judge rotation freshness on rotation output only.
$captureFiles = @(Get-ChildItem (Join-Path $OutDir 'regular\*-regular-*.json') -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -notlike 'hunter-*' })
# SAM'S ROTATION OUTPUT IS NOT IN out\regular, AND THIS CHECK COULD NOT SEE IT (fixed 2026-08-25).
# Every other store's daily rotation lands in out\regular\<store>-regular-<date>.json, but
# build-sams-deals.ps1 writes out\sams\sams-deals-<date>.json - the name compare-deals globs to find
# Sam's captures. It is rotation output either way: the same 7-terms-a-day worklist feeds it. Reading
# only out\regular left this check looking at sams-regular-2026-08-01.json, an abandoned file nothing
# has written since, so it reported Sam's as 24 days cold while the store was in fact being captured
# every morning - 377 cells on the 2026-08-25 board, 17 of them dated that day. A freshness check that
# reads the wrong directory does not report a stale store, it invents one, and it is the third alarm of
# that shape found today. sams-rejects-*.json is deliberately outside this glob, as it is outside
# compare-deals' - rejected rows must never be read back as captures.
$captureFiles += @(Get-ChildItem (Join-Path $OutDir 'sams\sams-deals-*.json') -ErrorAction SilentlyContinue)
foreach ($rf in $captureFiles) {
  try { $doc = Get-Content $rf.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
  $st = [string]$doc.store
  if (-not $st) { continue }
  if (-not $freshByStore.ContainsKey($st)) { $freshByStore[$st] = 0 }
  foreach ($row in @($doc.deals)) {
    $a = [string]$row.as_of
    if ($a.Length -lt 10) { continue }
    $a = $a.Substring(0, 10)
    if ($a -eq $todayS) { $freshByStore[$st] = $freshByStore[$st] + 1 }
    if (-not $newestByStore.ContainsKey($st) -or $a -gt $newestByStore[$st]) { $newestByStore[$st] = $a }
  }
}
if (-not $newestByStore.Count) {
  # No dated rows anywhere is not "every store is fine" - it is this check failing to look.
  [void]$findings.Add('STORE FRESHNESS BLIND: no out\regular file carried a single dated row, so this check examined nothing. That is not a pass.')
} else {
  foreach ($st in ($newestByStore.Keys | Sort-Object)) {
    $fresh = [int]$freshByStore[$st]
    $newest = [string]$newestByStore[$st]
    $age = [int]((Get-Date $todayS) - (Get-Date $newest)).TotalDays
    if ($HEADLESS_LANES -contains $st) {
      # Only a day the daily job actually ran can indict a headless lane; otherwise nobody asked it for
      # anything and zero is the correct answer.
      if ($dailyRanToday -and $fresh -eq 0) {
        [void]$findings.Add(("NO FRESH ROWS: {0} has a headless lane and the 08:00 capture ran, but it contributed ZERO rows dated {1} (newest {2}, {3}d old). Its puller ran and saw nothing - check that lane before trusting its cells." -f $st, $todayS, $newest, $age))
      } else {
        [void]$ok.Add(("{0}: {1} fresh row(s) today (newest {2})" -f $st, $fresh, $newest))
      }
    } else {
      # BROWSER STORE. Judged against the real cadence (see the constants above), in three bands.
      if ($age -gt $CARRY_DAYS) {
        [void]$findings.Add(("CELLS EXPIRING NOW: {0}'s newest row is {1} day(s) old, past the {2}-day carry limit - its cells are leaving the board. This is the one that costs coverage; work out\rescue-terms-*.txt for this store first." -f $st, $age, $CARRY_DAYS))
      } elseif ($age -gt ($CARRY_DAYS - $CLIFF_WARN_DAYS)) {
        [void]$findings.Add(("APPROACHING CARRY CLIFF: {0}'s newest row is {1} day(s) old and rows expire at {2}. About {3} day(s) of notice before its cells start leaving the board." -f $st, $age, $CARRY_DAYS, ($CARRY_DAYS - $age)))
      } elseif ($age -gt $ROTATION_DEBT_DAYS) {
        # Deliberately NOT worded as a failure. Everyday prices are on a 90-day refresh by design.
        [void]$ok.Add(("{0}: {1} fresh row(s) today, newest {2} ({3}d) - ROTATION DEBT: no capture for over {4}d, so this quarter will not complete on schedule. Not stale yet ({5}d carry); costs coverage only if it keeps slipping." -f $st, $fresh, $newest, $age, $ROTATION_DEBT_DAYS, $CARRY_DAYS))
      } else {
        [void]$ok.Add(("{0}: {1} fresh row(s) today, newest {2} ({3}d of {4}d carry)" -f $st, $fresh, $newest, $age, $CARRY_DAYS))
      }
    }
  }
}

# ---- 6b (deferred from check 6). BROWSER WORK: is the todo actually still outstanding? ---------------
# A flag records what the 08:00 driver could NOT capture, and NOTHING ever deletes one - so the finding
# was purely "a file exists and is older than a day". It stayed lit after the work was done, and on
# 2026-08-25 it was the only finding left standing at the end of a day on which every store it named had
# been captured: Walmart 193 rows and Aldi 264, both dated today, both through Brad's Chrome. A watchdog
# that cannot see the work it asked for being finished is asking for it forever, which is the fourth
# alarm-that-accuses-healthy-things found that day.
#
# So ask the question the flag is really posing: do the stores this flag names have fresh rows TODAY? A
# flag whose stores are all fresh is a completed todo and is reported as ok. One with a store still cold
# is a real finding, and so is one whose store list cannot be read - unprovable is not the same as done,
# and this check must never excuse itself on a file it failed to parse.
if ($staleFlags.Count) {
  # JUDGED BY THE SAME BANDS THE PER-STORE SCAN USES, and a finished todo is deleted rather than kept
  # forever (2026-08-30, queue 2026-08-30-40c75d - see Test-FlagStoreCold for the measurement). The old
  # bar was "no rows dated TODAY", which contradicted the OK line this same run prints for the same store.
  $unworked = @(); $finished = @(); $coldNames = @{}
  $nowFlags = Get-Date
  foreach ($ff in $staleFlags) {
    $fstores = @()
    try { $fstores = @((Get-Content $ff.FullName -Raw -Encoding UTF8 | ConvertFrom-Json).stores) } catch { $fstores = @() }
    if (-not $fstores.Count) { $unworked += $ff; continue }   # unreadable is not done
    $coldOnes = @($fstores | Where-Object {
        Test-FlagStoreCold -NewestCapture ([string]$newestByStore[[string]$_]) -FlagWritten $ff.LastWriteTime -Now $nowFlags -RotationDebtDays $ROTATION_DEBT_DAYS })
    if ($coldOnes.Count) { $unworked += $ff; $coldNames[$ff.Name] = $coldOnes }
    elseif (Test-FlagWorked -Stores @($fstores | ForEach-Object { [string]$_ }) -NewestByStore $newestByStore -FlagWritten $ff.LastWriteTime) { $finished += $ff }
  }
  if ($unworked.Count) {
    $oldest = ($unworked | Sort-Object LastWriteTime | Select-Object -First 1)
    $oldestAge = [int]((Get-Date) - $oldest.LastWriteTime).TotalDays
    $still = @($coldNames[$oldest.Name])
    $who = if ($still.Count) { ' still cold: ' + ($still -join ', ') } else { '' }
    [void]$findings.Add(("BROWSER WORK STALE: {0} unworked capture flag(s), oldest {1} at {2} day(s).{3} The walled stores are not being captured by anything - open a Chrome tab per store and work out\worklists\." -f $unworked.Count, $oldest.Name, $oldestAge, $who))
  } elseif (@($bcV.MissingToday).Count -eq 0) {
    # Never beside a MISSING line about today: two checks, one flag, opposite verdicts in one report (2000e1).
    [void]$ok.Add(("browser work: {0} capture flag(s) on disk and every store each one names is inside its rotation band - nothing behind them is outstanding" -f $staleFlags.Count))
  }
  # A FINISHED TODO IS DELETED. Same housekeeping-not-signal doctrine as the 45-day prune above: a flag
  # that nothing can ever close is what made ONE unreached store relight ten days of them at once.
  if ($finished.Count) {
    [void]$ok.Add(("browser work: pruned {0} completed capture flag(s) - every store each one named has a capture dated at or after the flag" -f $finished.Count))
    foreach ($ff in $finished) { try { Remove-Item $ff.FullName -Force -ErrorAction SilentlyContinue } catch { } }
  }
}
# ---- PAID CONTENT SERVED FREE (2026-08-29) -----------------------------------
# THE DIRECTION NOBODY WATCHED. build-hub-grid already verifies visibility per slug, but only for slugs
# LISTED in free-rotation.json - it warns when a listed-free post is NOT public, which protects the badge.
# Nothing anywhere asked the dangerous question: is any post NOT listed free being served free? On
# 2026-08-29 the answer was 22 - full paid recipes, ingredients, every step, cost and scaler, readable by
# anonymous visitors - and it took an unrelated wave's post-publish review to notice one of them.
# It lives HERE rather than on the ship path because it is a health question, not a publish gate, and the
# watchdog already raises exactly one email a day. It costs one Ghost read per recipe, so it is deliberately
# NOT in the 0800 chain's fan-out where it would sit on the critical path to the board.
# The sweep alerts on its own (-Alert) AND contributes a line here, because the two have different readers:
# the alert names every slug for whoever fixes it, this line tells the daily health reader it happened.
try {
  $visPs1 = Join-Path (Split-Path $PSScriptRoot -Parent) 'meal-prep\set-recipe-visibility.ps1'
  if (-not (Test-Path $visPs1)) {
    # A MISSING CHECKER IS A FINDING, NOT A SKIP. The first version of this block wrapped everything
    # in `if (Test-Path)`, so deleting the sweep would have made the watchdog quietly stop asking the
    # question and report a clean day - the same shape as every other blind guard in this estate.
    [void]$findings.Add('VISIBILITY SWEEP MISSING: meal-prep\set-recipe-visibility.ps1 is gone, so nothing checks whether a paid recipe is being served free. That check found 22 on 2026-08-29.')
  } else {
    $visOut = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $visPs1 -Audit -Alert)
    $visLine = [string](@($visOut) -match '^VISIBILITY-AUDIT-COMPLETE' | Select-Object -First 1)
    if ($visLine -match 'disagreements=(\d+)') {
      $nBad = [int]$Matches[1]
      if ($nBad -gt 0) {
        [void]$findings.Add("PAID CONTENT SERVED FREE: $nBad live recipe(s) disagree with recipes-db about who may read them - see the VISIBILITY alert for the slugs. Nothing self-heals this: the rotation refuses to re-paywall a post it does not own, and publish.ps1 preserves live visibility on update. Fix with meal-prep\set-recipe-visibility.ps1 -Slug <slug> -Apply.")
      } else {
        [void]$ok.Add(("visibility: every live recipe agrees with recipes-db on who may read it ({0})" -f ($visLine -replace '^VISIBILITY-AUDIT-COMPLETE\s*','')))
      }
    } else {
      # A sweep that could not finish must not read as a clean one - that is the whole lesson of the class.
      [void]$findings.Add('VISIBILITY SWEEP DID NOT COMPLETE: set-recipe-visibility -Audit produced no verdict line, so whether a paid recipe is being served free is UNKNOWN this run, not clean.')
    }
  }
} catch { [void]$findings.Add('VISIBILITY SWEEP THREW: ' + $_.Exception.Message + ' - whether a paid recipe is being served free is unknown this run.') }

# ---- FAMILY FARE SHARD WINDOW 3 OF 3, and the cadence check that watches it ---------------------
# (2026-09-01, queue 2026-09-01-056e6b.) Window 1 rides the 07:00 ad task, window 2 is the 08:00 daily
# run's own FF lane, and this is window 3. No new scheduled task: the automation inventory stays at
# three grocery jobs. The cursor design makes a repeated or a missed window safe by construction, so
# running FF here cannot corrupt anything - a window that buys nothing commits no cursor.
$FF_EXPECTED_WINDOWS = 3
if (-not $SelfTest) {
  try {
    Write-Output 'capture-watchdog: Family Fare shard window (3 of 3)'
    $ffWindowStart = Get-Date
    # NO 2>&1 - see capture-run.ps1: EAP=Stop plus a native child's redirected stderr is a terminating
    # throw in PS 5.1, and it would kill the watchdog before it reported anything.
    $ffOut = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'pull-regular-familyfare.ps1') -MaxMinutes 5
    foreach ($l in @($ffOut)) { Write-Output ('  ff> ' + $l) }
  } catch { Write-Output ('  ff> shard window threw (not fatal, the cursor did not commit): ' + $_.Exception.Message) }
  # THIS WINDOW COMMITS NOTHING, SO IT RECORDS WHAT IT WROTE (2026-09-23, queue 2026-09-22-9bc4d2). On 2026-09-22 the
  # daily run held its three 09-21 files as "another session's edits" (capture-run-daily-2026-09-22.log line 209), and a
  # dated file is never rewritten, so it would have been held on every run after. The next capture-run commits bytes
  # recorded here as the pipeline's own. Scoped to lib\bot-paths.ps1's inputs and to this window's minutes. Never fatal.
  if ($ffWindowStart) {
    try {
      $wdRepo = Split-Path $PSScriptRoot -Parent
      . (Join-Path $wdRepo 'lib\pipeline-commit.ps1')
      . (Join-Path $wdRepo 'lib\bot-paths.ps1')
      $wdN = Register-PipelineWrites -Repo $wdRepo -Lane 'capture-watchdog-ff' -Since $ffWindowStart -Paths @(Get-BotInputPaths)
      Write-Output ('  ff> pipeline-writes: recorded ' + $wdN + ' file(s) the shard window wrote')
    } catch { Write-Output ('  ff> pipeline-writes: could not record the window''s writes (' + $_.Exception.Message + '); the next run holds them as before') }
  }
}

# THE CADENCE WATCHER. The point of 2026-09-01-056e6b is not that Family Fare was throttled; it is that
# the designed cadence never existed and NOTHING was watching for its absence, so a missing schedule
# paged three weeks later as "catalog is degrading" instead of as itself. This asks the direct question.
#
# It reads capture-cursor-log.jsonl, and that file could not answer it until today: every other rotation
# store writes an advance line there and Family Fare never did (17 Fareway, 11 Sam's Club, 11 Hy-Vee, 10
# Baker's, 8 Walmart, 7 Aldi, 0 Family Fare on 2026-09-01), because pull-regular-familyfare called
# Save-CaptureCursor without the separate Write-CursorLog every other builder calls. That call was added
# in the same commit as this check; without it this watcher would have been a gate that can never arm.
try {
  $curLog = Join-Path $OutDir 'capture-cursor-log.jsonl'
  if (Test-Path $curLog) {
    $since = (Get-Date).AddHours(-24)
    $ffAdv = Measure-CursorAdvances -Lines (Get-Content $curLog -ErrorAction SilentlyContinue) -Store 'Family Fare' -Since $since
    if ($ffAdv -lt $FF_EXPECTED_WINDOWS) {
      [void]$findings.Add(("MISSING-WINDOW: Family Fare advanced its term cursor $ffAdv time(s) in the last 24h, against $FF_EXPECTED_WINDOWS configured shard windows (07:00 ad task, 08:00 daily run, 10:30 watchdog). The sweep is sized for several windows a day - about 7 of 526 terms each - so a lost window is not a slow day, it is coverage the 90-day carry has to cover for. This is the check that makes a dead window page as itself instead of surfacing weeks later as 'the catalog is degrading'."))
    } else {
      [void]$ok.Add("Family Fare shard cadence: $ffAdv cursor advance(s) in the last 24h, at or above the $FF_EXPECTED_WINDOWS configured windows")
    }
  }
} catch { }

# ---- THE FOLD: one hold, one finding (2026-09-07, queue 2026-09-07-e5efa6) ----------------------
# Sections 3 and 4 have established when the board was written and whether it shipped, so the question
# "is every symptom above just the gate refusing today's board" can finally be answered - the same
# deferral Test-RunSuperseded already uses. On any other day this is a no-op and the list is untouched.
$heldSub = New-Object System.Collections.Generic.List[string]
$heldNow = Test-HeldByGuards -Verdict $chainVerdict -Today $todayS -BoardWritten $boardW -PublishedWritten $pubW
# ---- RUN RECORD PAGES ONLY WHAT DID NOT PAGE ITSELF (2026-09-22, item 2026-09-22-7c932a). A guards hold keeps its own
# fold below, unchanged; on any other day the daily record's failed_lanes decide whether RUN RECORD is news.
$rrFoldLine = ''
if (-not $heldNow -and $dailyRunRecordText) {
  $rrPaging = Get-FailedLanePaging $dailyRunRecord
  $rrFold = Merge-PagedLaneFindings $findings $derivative $rrPaging $dailyRunRecordText 'daily'
  $findings = $rrFold.findings
  $derivative = $rrFold.derivative
  $heldSub = $rrFold.sub
  $rrFoldLine = $rrFold.line
}
$adFoldLine = ''
if ($adRunRecordText) {
  $adFold = Merge-AdRunRecord $findings $adRunRecord $adRunRecordText
  $findings = $adFold.findings
  $adFoldLine = $adFold.line
}
if ($heldNow) {
  $hMin = if ($cmp -and (Test-Path $cmp) -and $pubW) { [int]((Get-Item $cmp).LastWriteTime - $pubW).TotalMinutes } else { 0 }
  # NOT `$x = try {...} catch {...}` - that is PS 7 syntax and a parse error in 5.1.
  $hWhen = [string]$chainVerdict.written
  try { $hWhen = ([datetime]$chainVerdict.written).ToString('HH:mm') } catch { }
  $hText = "HELD BY GUARDS: check-ad-cycles refused the $hWhen board (guards_rc $($chainVerdict.guards_rc)) and nothing has been rebuilt and shipped since. The 0800 exit code, public\board.json sitting $hMin min behind the comparison and the unstaged served files are all that ONE hold - the GUARDS FAILED alert owns it. Clear the guard failure, rebuild, publish."
  $folded = Merge-HeldFindings $findings $derivative $true $hText
  $findings = $folded.findings
  $heldSub = $folded.sub
}

# ---- report ------------------------------------------------------------------
Write-Output "CAPTURE WATCHDOG - $todayS"
foreach ($o in $ok) { Write-Output "  ok    $o" }
foreach ($f in $findings) { Write-Output "  FIND  $f" }
if ($rrFoldLine) { Write-Output ("  FOLD  " + $rrFoldLine) }
if ($adFoldLine) { Write-Output ("  FOLD  " + $adFoldLine) }
foreach ($s in $heldSub) { Write-Output "          - $s" }
# Check 7's own numbers, one machine-readable line per run, for grocery\report-checkout-sync.ps1's bar B9.
Write-Output ('  ' + $flMarker)

if ($findings.Count -and $Alert) {
  # healthy checks are the transcript's, never the alert's (2026-09-21): the body names what is wrong and points here
  $okLines = if ($runLog) { "`n`nFull watchdog report, healthy checks included: $runLog" } else { '' }
  $hTextNow = ''
  if ($heldNow) { $hTextNow = $hText }
  $plan = Get-WatchdogAlertPlan -Findings $findings -Held ([bool]$heldNow) -HeldText $hTextNow
  if ($plan.hold) {
    # ONE INCIDENT, ONE ALERT (2026-09-10): the hold and its symptoms belong to the open GUARDS FAILED item.
    $subLines = if ($heldSub.Count) { "`n" + (($heldSub | ForEach-Object { "     . $_" }) -join "`n") } else { '' }
    $holdBody = "Capture watchdog on ${todayS}: the board is held by guards.`n`n - $hTextNow" + $subLines + $okLines
    try { Send-Alert -Subject "Grocery capture watchdog: held by guards $todayS" -Body $holdBody -CausedBy 'guards-hold' | Out-Null } catch { }
  }
  if ($plan.independent.Count) {
    # ONE CONDITION, ONE ALERT TYPE (2026-09-21, plan-2026-09-21-5.json). This was one "N issue(s)" alert per run, so
    # a dozen unrelated causes over 30 days (RUN RECORD, AD STALE, NO FRESH ROWS, GRAPH SCHEMA, ...) all filed as
    # returns of one type no single fix could close. Each finding's leading label is now its own type, queue item and
    # dedupe key; Send-AlertConditions still sends ONE message per run listing whichever of them are due. The healthy
    # checks stay in this run's transcript, which every body points at, and no longer ride in the alert.
    $rlNote = if ($runLog) { "Full watchdog report for $todayS, healthy checks included: $runLog" } else { 'Full watchdog report: run grocery\capture-watchdog.ps1 (no transcript was written this run).' }
    try { Send-AlertConditions -SubjectPrefix 'Grocery capture watchdog' -Conditions @($plan.independent) -ReportPointer $rlNote -DateStamp $todayS | Out-Null } catch { }
  }
}

Write-Output ("CAPTURE-WATCHDOG-COMPLETE findings={0} not_yet={1}" -f $findings.Count, $bcNotYet.Count)
# NOTE: rc=1 here means "the watchdog WORKED and found something", not "the
# watchdog broke". Do not read a red result on this task as a crash - read the log.
$rcFinal = if ($findings.Count) { 1 } else { 0 }
Stop-RunLog -ExitCode $rcFinal -Path $runLog
exit $rcFinal

