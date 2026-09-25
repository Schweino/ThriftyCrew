<#
  TC Boot Watch: lock the desktop after an AUTOMATIC sign-in, page the jobs a reboot cost, and beat the off-box
  heartbeat. Brad's ruling 2026-09-25 on Q4-tasks-dead-after-reboot (grocery/triage-plans/plan-2026-09-18.json,
  queue 2026-09-18-8491bf): "You set up Autologon; I build the lock and the boot page (Recommended)".

  WHY IT EXISTS. Every TC task runs as Owner, "run only when user is logged on". A Windows Update restart at
  2026-09-14 22:29 left nobody signed in until 09-17 05:06, the scheduler refused every launch (event 332), 09-15
  and 09-16 were lost, and nothing paged because health-heartbeat is one of the watched. The remedy Brad chose is
  Sysinternals Autologon, which he sets up himself (no agent ever handles his password). Auto-logon leaves an
  unlocked desktop after every reboot, so this locks it; and a reboot still costs whatever ran while the box was
  down or sitting at the sign-in screen, so this says what.

  ONE TASK, THREE JOBS, run at logon AND every 15 minutes (ops\scheduled-tasks\tc-boot-watch.xml):
    1. LOCK (-Lock). Locks the workstation when, and only when, ALL hold (Get-BootWatchLockVerdict):
         - HKLM Winlogon AutoAdminLogon reads "1" (Autologon is set up). Only that one value is read, never the
           user name or anything else there. While it is off this can never lock, which is what makes the task
           harmless before Brad sets it up.
         - this boot has not been handled yet (a sign-out and sign-in later is not a boot);
         - the interactive sign-in came at most $LockWindowMinutes (20) after LastBootUpTime;
         - this run is at most $LogonRecentMinutes (20) after that sign-in, so a task registered mid-uptime, or a
           15-minute run long after, can never lock a desktop Brad is using.
       THE WINDOW, 20 MINUTES, IS FIRST PLAUSIBLE, NOT SWEPT. Measured once: the 2026-09-22 boot (12:25:22) had its
       sign-in at 12:25:59, 37 seconds later. LastBootUpTime is kernel start, and the "working on updates" phase
       after an update restart runs between kernel start and the sign-in and is not bounded by Microsoft, so the
       window is about 32 times the one measured gap. A manual sign-in cannot fall inside it with AutoAdminLogon on,
       because the box signs itself in first. The cost of a lock that should not have happened is one unlock; the
       cost of one that did not happen is a desktop sitting open, so the window leans long.
       KNOWN GAP: with Fast Startup on, a SHUT DOWN and power-on resumes the kernel, LastBootUpTime does not move,
       and this does not lock. A RESTART (every Windows Update restart, the founding case) is a full boot and does.
    2. BOOT PAGE (-Alert). On the first run after a boot that is at a sign-in (the same recent-sign-in test,
       Get-BootWatchReportVerdict), it counts, for every TC task, the scheduled occurrences between that task's
       last run and the sign-in (Get-BwMissedJobs), and pages 'Ops: the box rebooted and daily jobs were missed'
       when a DAILY job lost at least one whole day. A 15-minute job missing an hour, or a daily job whose one
       missed run StartWhenAvailable makes up at the sign-in, is written to the run log and never pages: it
       requires nothing (grocery/alert-registry.json readme). A late sign-in, days after the boot, still reports,
       because the test is "this run is at a sign-in", not "the sign-in was near the boot".
    3. HEARTBEAT (-Beat). POSTs to the smp-feed Worker's /box-heartbeat, whose cron pages Brad OFF the box when the
       beats stop (worker/box-heartbeat.js, 60-minute bar). The reply carries the watcher's last check, so when
       the WATCHER stops the box pages 'Ops: the off-box heartbeat watcher is not checking' (over
       $WatcherStaleMinutes, 120). Auth is the X-Notify-Auth hash every pipeline route uses (SHA-256 of the Ghost
       Admin key, read from GHOST_ADMIN_KEY or meal-prep\.ghostkey exactly as grocery\notify-item-added.ps1 does;
       the key itself never travels). Until Brad adds the Worker's KV binding the reply is 503 "not configured",
       which is logged and is not a finding.

  WHAT THE THRESHOLDS DO WHEN THE PRODUCER STOPS. The lock window and the recent-sign-in bar are gates on an
  action, never alarms: with no sign-in nothing runs and nothing locks, which is correct. The boot page cannot fire
  while the box is down, which is why the off-box half exists. The watcher bar FIRES when the watcher stops (its
  last check only ages), and goes quiet when the BOX stops, which is the off-box half's case.

  SCOPE OF A CLEAN REPORT: a run that locks nothing and pages nothing proves only that these conditions did not
  hold in this run. The missed-job count reads Daily, Weekly and repeating triggers; any other trigger kind is
  listed as unreadable, never counted as nothing missed.

  EXIT CODES (lib\guard-contract.ps1): 0 nothing to report, 1 a finding (a watcher not checking, a refused beat, or
  a boot page sent), 3 could not look (the boot time could not be read).
#>
# Declared inputs of its -SelfTest (lib\gate-input-key.ps1): the self-test works in a temp directory and reads nothing else of this repo.
# gate-inputs: ops\boot-watch.ps1
[CmdletBinding()]
param(
  [switch]$SelfTest,
  [switch]$Lock,
  [switch]$Alert,
  [switch]$Beat,
  [int]$LockWindowMinutes = 20,
  [int]$LogonRecentMinutes = 20,
  [int]$WatcherStaleMinutes = 120,
  [string]$HeartbeatUrl = 'https://feed.thriftycrew.com/box-heartbeat',
  [string]$StatePath = ''
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $RepoRoot 'lib\guard-contract.ps1')
. (Join-Path $RepoRoot 'lib\atomic-write.ps1')
. (Join-Path $RepoRoot 'grocery\run-log-lib.ps1')

if (-not $StatePath) { $StatePath = Join-Path $RepoRoot 'ops\out\boot-watch-state.json' }

function Get-BwBootKey([datetime]$BootTime) { return $BootTime.ToString('yyyy-MM-ddTHH:mm:ss') }

function Get-BootWatchLockVerdict {
  <# Pure. Should this run lock the workstation? Returns lock (bool) and why. #>
  param([datetime]$BootTime, $LogonTime, [datetime]$Now, [string]$AutoAdminLogon, [string]$HandledBoot,
        [int]$WindowMinutes, [int]$RecentMinutes)
  $no = { param($w) [pscustomobject]@{ lock = $false; why = $w } }
  if ([string]::Equals([string]$HandledBoot, (Get-BwBootKey $BootTime), [StringComparison]::Ordinal)) { return (& $no 'this boot was already handled') }
  if (-not [string]::Equals(([string]$AutoAdminLogon).Trim(), '1', [StringComparison]::Ordinal)) { return (& $no 'auto-logon is off (AutoAdminLogon is not 1)') }
  if ($null -eq $LogonTime) { return (& $no 'the sign-in time could not be read, so nothing proves this sign-in was automatic') }
  $gap = ([datetime]$LogonTime - $BootTime).TotalSeconds
  if ($gap -lt 0) { return (& $no 'the sign-in reads as older than the boot') }
  if ($gap -gt ($WindowMinutes * 60)) { return (& $no ("the sign-in came {0}s after boot, past the {1}-minute window" -f [int]$gap, $WindowMinutes)) }
  $since = ($Now - [datetime]$LogonTime).TotalSeconds
  if ($since -gt ($RecentMinutes * 60)) { return (& $no ("this run is {0}s after the sign-in, past {1} minutes, so it is not the run at that sign-in" -f [int]$since, $RecentMinutes)) }
  return [pscustomobject]@{ lock = $true; why = ("auto-logon is on and the sign-in came {0}s after boot" -f [int]$gap) }
}

function Get-BootWatchReportVerdict {
  <# Pure. Is this the run that reports what the reboot cost? #>
  param([datetime]$BootTime, $LogonTime, [datetime]$Now, [string]$HandledBoot, [int]$RecentMinutes)
  $no = { param($w) [pscustomobject]@{ report = $false; why = $w } }
  if ([string]::Equals([string]$HandledBoot, (Get-BwBootKey $BootTime), [StringComparison]::Ordinal)) { return (& $no 'this boot was already handled') }
  if ($null -eq $LogonTime) { return (& $no 'the sign-in time could not be read') }
  if (([datetime]$LogonTime - $BootTime).TotalSeconds -lt 0) { return (& $no 'the sign-in reads as older than the boot') }
  $since = ($Now - [datetime]$LogonTime).TotalSeconds
  if ($since -gt ($RecentMinutes * 60)) { return (& $no ("this run is {0}s after the sign-in, so it is not the run at a sign-in (a registration mid-uptime); the boot is marked handled with nothing reported" -f [int]$since)) }
  return [pscustomobject]@{ report = $true; why = 'first run at a sign-in after this boot' }
}

function ConvertTo-BwTriggerSpec {
  <# One scheduler trigger (a CIM MSFT_Task*Trigger, or a pscustomobject with the same fields) as a plain spec. #>
  param($Trigger)
  $cls = ''
  if ($Trigger.PSObject.Properties['CimClass'] -and $Trigger.CimClass) { $cls = [string]$Trigger.CimClass.CimClassName }
  elseif ($Trigger.PSObject.Properties['ClassName']) { $cls = [string]$Trigger.ClassName }
  $kind = switch ($cls) {
    'MSFT_TaskDailyTrigger'  { 'daily' }
    'MSFT_TaskWeeklyTrigger' { 'weekly' }
    'MSFT_TaskLogonTrigger'  { 'event' }
    'MSFT_TaskBootTrigger'   { 'event' }
    'MSFT_TaskSessionStateChangeTrigger' { 'event' }
    'MSFT_TaskEventTrigger'  { 'event' }
    # Deliberate fallback, not a silent one: an unknown kind is listed as UNREADABLE by Get-BwMissedJobs.
    default { 'unknown' }
  }
  $start = $null
  if ([string]$Trigger.StartBoundary) { try { $start = ([DateTimeOffset]::Parse([string]$Trigger.StartBoundary, [Globalization.CultureInfo]::InvariantCulture)).LocalDateTime } catch { $start = $null } }
  $rep = $null; $dur = $null
  if ($Trigger.PSObject.Properties['Repetition'] -and $Trigger.Repetition) {
    if ([string]$Trigger.Repetition.Interval) { try { $rep = [Xml.XmlConvert]::ToTimeSpan([string]$Trigger.Repetition.Interval) } catch { $rep = $null } }
    if ([string]$Trigger.Repetition.Duration) { try { $dur = [Xml.XmlConvert]::ToTimeSpan([string]$Trigger.Repetition.Duration) } catch { $dur = $null } }
  }
  $di = 1; if ($Trigger.PSObject.Properties['DaysInterval'] -and [int]$Trigger.DaysInterval -gt 0) { $di = [int]$Trigger.DaysInterval }
  $wi = 1; if ($Trigger.PSObject.Properties['WeeksInterval'] -and [int]$Trigger.WeeksInterval -gt 0) { $wi = [int]$Trigger.WeeksInterval }
  $dow = 0; if ($Trigger.PSObject.Properties['DaysOfWeek'] -and $Trigger.DaysOfWeek) { $dow = [int]$Trigger.DaysOfWeek }
  $en = $true; if ($Trigger.PSObject.Properties['Enabled'] -and $Trigger.Enabled -eq $false) { $en = $false }
  return [pscustomobject]@{ kind = $kind; start = $start; daysInterval = $di; weeksInterval = $wi; daysOfWeek = $dow; rep = $rep; dur = $dur; enabled = $en }
}

function Test-BwFrequent($Spec) {
  <# A job that runs all day (a repetition under an hour, lasting a day or indefinitely) as against a daily job
     whose repetition is only its retry window. #>
  if (-not $Spec.rep -or $Spec.rep.TotalMinutes -le 0 -or $Spec.rep.TotalMinutes -ge 60) { return $false }
  return ((-not $Spec.dur) -or $Spec.dur.TotalHours -ge 23)
}

function Get-BwOccurrences {
  <# Pure. Every scheduled occurrence of a daily or weekly spec in (From, To]. Local wall-clock times; a DST jump
     can move one occurrence by an hour, which changes no day count. #>
  param($Spec, [datetime]$From, [datetime]$To)
  $out = New-Object 'System.Collections.Generic.List[datetime]'
  if (-not $Spec -or -not $Spec.enabled -or -not $Spec.start -or $To -le $From) { return ,$out.ToArray() }
  if ($Spec.kind -ne 'daily' -and $Spec.kind -ne 'weekly') { return ,$out.ToArray() }
  if (($To - $From).TotalDays -gt 400) { $From = $To.AddDays(-400) }
  $start = [datetime]$Spec.start
  $step = if ($Spec.kind -eq 'daily') { [int]$Spec.daysInterval } else { 1 }
  $d = $start.Date
  if ($From.Date.AddDays(-2) -gt $d) {
    $k = [math]::Floor((($From.Date.AddDays(-2)) - $d).TotalDays / $step)
    if ($k -gt 0) { $d = $d.AddDays($k * $step) }
  }
  $weekAnchor = $start.Date.AddDays(-[int]$start.DayOfWeek)
  while ($d -le $To.Date) {
    $take = $true
    if ($Spec.kind -eq 'weekly') {
      $bit = 1 -shl [int]$d.DayOfWeek
      $wk = [math]::Floor(($d - $weekAnchor).TotalDays / 7)
      $take = ((([int]$Spec.daysOfWeek) -band $bit) -ne 0) -and (($wk % [int]$Spec.weeksInterval) -eq 0)
    }
    if ($take) {
      $base = $d + $start.TimeOfDay
      $times = New-Object 'System.Collections.Generic.List[datetime]'
      [void]$times.Add($base)
      if ($Spec.rep -and $Spec.rep.TotalMinutes -gt 0) {
        $limit = if ($Spec.dur) { $Spec.dur } else { New-TimeSpan -Days $step }
        $o = $base.Add($Spec.rep)
        while (($o - $base) -lt $limit) { [void]$times.Add($o); $o = $o.Add($Spec.rep) }
      }
      foreach ($t in $times) { if ($t -gt $From -and $t -le $To -and $t -ge $start) { [void]$out.Add($t) } }
    }
    $d = $d.AddDays($step)
  }
  return ,$out.ToArray()
}

function Get-BwMissedJobs {
  <# Pure. Tasks = records { name; lastRun; startWhenAvailable; specs = @(ConvertTo-BwTriggerSpec ...) }.
     Returns one row per task that missed anything (or whose trigger could not be read) up to the sign-in. #>
  param([object[]]$Tasks, [datetime]$BootTime, [datetime]$LogonTime)
  $rows = New-Object 'System.Collections.Generic.List[object]'
  foreach ($t in $Tasks) {
    $from = $BootTime
    if ($t.lastRun -and ([datetime]$t.lastRun).Year -ge 2000) { $from = [datetime]$t.lastRun }
    $occ = New-Object 'System.Collections.Generic.List[datetime]'
    $frequent = $false; $unknown = $false; $allEvent = $true
    foreach ($s in @($t.specs)) {
      if (-not $s -or -not $s.enabled) { continue }
      if ($s.kind -eq 'unknown') { $unknown = $true; continue }
      if ($s.kind -eq 'event') { continue }
      $allEvent = $false
      if (Test-BwFrequent $s) { $frequent = $true }
      $got = Get-BwOccurrences -Spec $s -From $from -To $LogonTime
      foreach ($x in $got) { [void]$occ.Add($x) }
    }
    if ($unknown -and $occ.Count -eq 0) {
      [void]$rows.Add([pscustomobject]@{ name = $t.name; kind = 'unreadable'; missed = $null; first = $null; days = @(); lostDays = 0; catchUp = [bool]$t.startWhenAvailable; lastRun = $t.lastRun })
      continue
    }
    if ($allEvent -or $occ.Count -eq 0) { continue }
    $sorted = @($occ.ToArray() | Sort-Object)
    $days = @($sorted | ForEach-Object { $_.Date } | Sort-Object -Unique)
    $lost = @($days | Where-Object { $_ -lt $LogonTime.Date }).Count
    if ((@($days | Where-Object { $_ -eq $LogonTime.Date }).Count -gt 0) -and -not $t.startWhenAvailable) { $lost++ }
    $kind = if ($frequent) { 'frequent' } else { 'daily' }
    [void]$rows.Add([pscustomobject]@{ name = $t.name; kind = $kind; missed = $sorted.Count; first = $sorted[0]; days = $days; lostDays = $lost; catchUp = [bool]$t.startWhenAvailable; lastRun = $t.lastRun })
  }
  return ,$rows.ToArray()
}

function Test-BwBootPage([object[]]$Rows) {
  <# Pure. Page only when a DAILY job lost at least one whole day. #>
  foreach ($r in @($Rows)) { if ($r -and $r.kind -eq 'daily' -and [int]$r.lostDays -ge 1) { return $true } }
  return $false
}

function Format-BwBootBody {
  param([datetime]$BootTime, [datetime]$LogonTime, [object[]]$Rows, [bool]$Locked)
  $L = New-Object 'System.Collections.Generic.List[string]'
  $gapMin = [math]::Round(($LogonTime - $BootTime).TotalMinutes, 1)
  [void]$L.Add(("The box rebooted at {0}; the first sign-in came at {1} ({2} minutes later)." -f $BootTime.ToString('yyyy-MM-dd HH:mm'), $LogonTime.ToString('yyyy-MM-dd HH:mm'), $gapMin))
  [void]$L.Add('Every TC task runs only while someone is signed in, so these scheduled runs did not happen:')
  [void]$L.Add('')
  foreach ($r in @($Rows | Sort-Object @{ Expression = { if ($_.kind -eq 'daily') { 0 } else { 1 } } }, name)) {
    if ($r.kind -eq 'unreadable') { [void]$L.Add(("  {0}: its trigger could not be read, so what it missed is UNKNOWN" -f $r.name)); continue }
    $dayList = (@($r.days) | ForEach-Object { $_.ToString('MM-dd') }) -join ', '
    $cu = if ($r.catchUp) { 'catches up once now' } else { 'does NOT catch up; it waits for its next time' }
    [void]$L.Add(("  {0} ({1}): {2} run(s) missed from {3}, on {4}; lost days {5}; {6}" -f $r.name, $r.kind, $r.missed, $r.first.ToString('MM-dd HH:mm'), $dayList, $r.lostDays, $cu))
  }
  [void]$L.Add('')
  [void]$L.Add('A lost day is a daily job whose run for that day will not happen now: the one make-up run at sign-in')
  [void]$L.Add('covers today at most. Check the board and the day''s captures for those dates.')
  if ($Locked) { [void]$L.Add('The desktop was locked, because this sign-in was automatic.') }
  return (($L.ToArray()) -join "`n")
}

function Get-BwNotifyAuth([string]$Key) {
  <# The X-Notify-Auth value: lower-case hex SHA-256 of the key's UTF-8 bytes (worker/index.js notifyAuthOk). #>
  $sha = [Security.Cryptography.SHA256]::Create()
  return (-join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Key)) | ForEach-Object { $_.ToString('x2') }))
}

function Get-BwBeatVerdict {
  <# Pure. What a /box-heartbeat reply means. Status 0 = no HTTP reply at all. #>
  param([int]$Status, $Body, [datetime]$NowUtc, [int]$WatcherStaleMinutes, $FirstConfiguredUtc)
  if ($Status -eq 0) { return [pscustomobject]@{ state = 'unreachable'; finding = $false; why = 'no reply from the Worker (network or DNS); the off-box watcher pages if this lasts' } }
  if ($Status -eq 401) { return [pscustomobject]@{ state = 'refused'; finding = $true; why = 'the Worker refused the auth hash, so no beat is landing and the off-box watcher will page the box as silent' } }
  if ($Status -eq 503) { return [pscustomobject]@{ state = 'not-configured'; finding = $false; why = 'the Worker has no BOX_KV binding yet (design/ready-for-brad/Q4-autologon-and-box-heartbeat.md)' } }
  if ($Status -eq 404 -or $Status -eq 405) { return [pscustomobject]@{ state = 'not-deployed'; finding = $false; why = 'the deployed Worker has no /box-heartbeat route yet' } }
  if ($Status -ne 200 -or -not $Body -or $Body.ok -ne $true) { return [pscustomobject]@{ state = 'error'; finding = $false; why = ("the Worker answered {0} without ok" -f $Status) } }
  $lc = $null
  if ($Body.PSObject.Properties['last_check_at'] -and [string]$Body.last_check_at) {
    try { $lc = ([DateTimeOffset]::Parse([string]$Body.last_check_at, [Globalization.CultureInfo]::InvariantCulture)).UtcDateTime } catch { $lc = $null }
  }
  if ($null -eq $lc) {
    if ($FirstConfiguredUtc -and (($NowUtc - [datetime]$FirstConfiguredUtc).TotalMinutes -gt $WatcherStaleMinutes)) {
      return [pscustomobject]@{ state = 'watcher-never'; finding = $true; why = ("beats have landed for over {0} minutes and the watcher has never checked: the cron trigger is missing" -f $WatcherStaleMinutes) }
    }
    return [pscustomobject]@{ state = 'ok'; finding = $false; why = 'beat landed; the watcher has not checked yet' }
  }
  $age = ($NowUtc - $lc).TotalMinutes
  if ($age -gt $WatcherStaleMinutes) { return [pscustomobject]@{ state = 'watcher-stale'; finding = $true; why = ("the off-box watcher last checked {0} minutes ago (bar {1}): if the box goes down now, nothing pages" -f [int]$age, $WatcherStaleMinutes) } }
  return [pscustomobject]@{ state = 'ok'; finding = $false; why = ("beat landed; watcher checked {0} minutes ago" -f [int]$age) }
}

function Read-BwState([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]@{ handled_boot = ''; first_configured_utc = $null } }
  try {
    $s = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
    $hb = ''; if ($s.PSObject.Properties['handled_boot']) { $hb = [string]$s.handled_boot }
    $fc = $null; if ($s.PSObject.Properties['first_configured_utc'] -and [string]$s.first_configured_utc) { $fc = ([DateTimeOffset]::Parse([string]$s.first_configured_utc, [Globalization.CultureInfo]::InvariantCulture)).UtcDateTime }
    return [pscustomobject]@{ handled_boot = $hb; first_configured_utc = $fc }
  } catch { return [pscustomobject]@{ handled_boot = ''; first_configured_utc = $null } }
}

function Write-BwState([string]$Path, [string]$HandledBoot, $FirstConfiguredUtc, [string]$Note) {
  $fc = $null; if ($FirstConfiguredUtc) { $fc = [datetime]::SpecifyKind([datetime]$FirstConfiguredUtc, [DateTimeKind]::Utc).ToString('o') }
  $o = [ordered]@{ handled_boot = $HandledBoot; first_configured_utc = $fc; written = (Get-Date).ToString('o'); note = $Note }
  $dir = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  [void](Write-TcAtomicFile -Path $Path -Text ($o | ConvertTo-Json -Compress) -NoBom)
}

# ---------------------------------------------------------------------------
if ($SelfTest) {
  $bad = 0; $ran = 0
  function T([string]$n, [bool]$ok, $got = '') {
    $script:ran++
    if ($ok) { Write-Output ("  ok    " + $n) } else { Write-Output ("  X     {0}   got: {1}" -f $n, $got); $script:bad++ }
  }
  $scratch = Join-Path ([IO.Path]::GetTempPath()) ('bw-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
  New-Item -ItemType Directory -Path $scratch -ErrorAction Stop | Out-Null
  try {
    # The measured boot: kernel start 2026-09-22 12:25:22, sign-in 12:25:59 (37 s).
    $boot = [datetime]'2026-09-22T12:25:22'
    $logon = [datetime]'2026-09-22T12:25:59'
    $W = 20; $R = 20
    $v = Get-BootWatchLockVerdict -BootTime $boot -LogonTime $logon -Now $logon.AddSeconds(10) -AutoAdminLogon '1' -HandledBoot '' -WindowMinutes $W -RecentMinutes $R
    T 'MUST FIRE  an automatic sign-in 37 s after boot, first run, locks' ($v.lock -eq $true) $v.why
    $v = Get-BootWatchLockVerdict -BootTime $boot -LogonTime $boot.AddMinutes(20) -Now $boot.AddMinutes(20).AddSeconds(5) -AutoAdminLogon '1' -HandledBoot '' -WindowMinutes $W -RecentMinutes $R
    T 'MUST FIRE  AT THE BAR: a sign-in exactly 20 minutes (1200 s) after boot still locks' ($v.lock -eq $true) $v.why
    $v = Get-BootWatchLockVerdict -BootTime $boot -LogonTime $boot.AddSeconds(1201) -Now $boot.AddSeconds(1206) -AutoAdminLogon '1' -HandledBoot '' -WindowMinutes $W -RecentMinutes $R
    T 'MUST NOT FIRE ONE STEP PAST THE BAR: a sign-in 1201 s after boot does not lock' ($v.lock -eq $false) $v.why
    $late = [datetime]'2026-09-22T17:40:00'
    $v = Get-BootWatchLockVerdict -BootTime $boot -LogonTime $late -Now $late.AddSeconds(8) -AutoAdminLogon '1' -HandledBoot '' -WindowMinutes $W -RecentMinutes $R
    T 'MUST NOT FIRE a manual sign-in later in the day does not lock' ($v.lock -eq $false) $v.why
    $v = Get-BootWatchLockVerdict -BootTime $boot -LogonTime $late -Now $late.AddSeconds(8) -AutoAdminLogon '1' -HandledBoot (Get-BwBootKey $boot) -WindowMinutes $W -RecentMinutes $R
    T 'MUST NOT FIRE a sign-out and sign-in on a boot already handled does not lock' (($v.lock -eq $false) -and ($v.why -like '*already handled*')) $v.why
    foreach ($off in @('', '0', ' 0 ', '10')) {
      $v = Get-BootWatchLockVerdict -BootTime $boot -LogonTime $logon -Now $logon.AddSeconds(10) -AutoAdminLogon $off -HandledBoot '' -WindowMinutes $W -RecentMinutes $R
      T ("MUST NOT FIRE while auto-logon is off (AutoAdminLogon='{0}') even a sign-in 37 s after boot does not lock" -f $off) (($v.lock -eq $false) -and ($v.why -like '*auto-logon is off*')) $v.why
    }
    $v = Get-BootWatchLockVerdict -BootTime $boot -LogonTime $logon -Now $logon.AddDays(2) -AutoAdminLogon '1' -HandledBoot '' -WindowMinutes $W -RecentMinutes $R
    T 'MUST NOT FIRE a first run two days after an automatic sign-in (a task registered mid-uptime) does not lock' ($v.lock -eq $false) $v.why
    $v = Get-BootWatchLockVerdict -BootTime $boot -LogonTime $logon -Now $logon.AddSeconds(1200) -AutoAdminLogon '1' -HandledBoot '' -WindowMinutes $W -RecentMinutes $R
    T 'MUST FIRE  AT THE BAR: a run exactly 20 minutes after that sign-in still locks' ($v.lock -eq $true) $v.why
    $v = Get-BootWatchLockVerdict -BootTime $boot -LogonTime $logon -Now $logon.AddSeconds(1201) -AutoAdminLogon '1' -HandledBoot '' -WindowMinutes $W -RecentMinutes $R
    T 'MUST NOT FIRE ONE STEP PAST THE BAR: a run 1201 s after that sign-in does not lock' ($v.lock -eq $false) $v.why
    $v = Get-BootWatchLockVerdict -BootTime $boot -LogonTime $null -Now $logon -AutoAdminLogon '1' -HandledBoot '' -WindowMinutes $W -RecentMinutes $R
    T 'MUST NOT FIRE an unreadable sign-in time never locks' ($v.lock -eq $false) $v.why
    $v = Get-BootWatchLockVerdict -BootTime $boot -LogonTime $boot.AddSeconds(-30) -Now $logon -AutoAdminLogon '1' -HandledBoot '' -WindowMinutes $W -RecentMinutes $R
    T 'MUST NOT FIRE a sign-in that reads as older than the boot never locks' ($v.lock -eq $false) $v.why

    # ---- the boot page ----
    $b14 = [datetime]'2026-09-14T22:32:00'; $l17 = [datetime]'2026-09-17T05:06:18'
    $rv = Get-BootWatchReportVerdict -BootTime $b14 -LogonTime $l17 -Now $l17.AddSeconds(20) -HandledBoot '' -RecentMinutes $R
    T 'MUST FIRE  a late sign-in 2.3 days after the boot still reports what was lost' ($rv.report -eq $true) $rv.why
    $rv = Get-BootWatchReportVerdict -BootTime $boot -LogonTime $logon -Now $logon.AddDays(3) -HandledBoot '' -RecentMinutes $R
    T 'MUST NOT FIRE a first run long after its sign-in (a registration mid-uptime) reports nothing' ($rv.report -eq $false) $rv.why
    $rv = Get-BootWatchReportVerdict -BootTime $b14 -LogonTime $l17 -Now $l17.AddSeconds(20) -HandledBoot (Get-BwBootKey $b14) -RecentMinutes $R
    T 'MUST NOT FIRE a boot already reported is not reported again' ($rv.report -eq $false) $rv.why

    $mk = { param($cls, $start, $rep, $dur) [pscustomobject]@{ ClassName = $cls; StartBoundary = $start; DaysInterval = 1; WeeksInterval = 1; DaysOfWeek = 0; Enabled = $true; Repetition = [pscustomobject]@{ Interval = $rep; Duration = $dur } } }
    # The founding case, 09-14 22:29 restart to 09-17 05:06 sign-in, with the live triggers as Get-ScheduledTask read them 2026-09-25.
    $capture = & $mk 'MSFT_TaskDailyTrigger' '2026-08-20T08:00:00-05:00' 'PT1H' 'PT6H'
    $reaper = & $mk 'MSFT_TaskDailyTrigger' '2026-09-20T08:15:00-05:00' 'PT15M' 'P1D'
    $ratchet = & $mk 'MSFT_TaskDailyTrigger' '2026-09-13T03:15:00-05:00' '' ''
    $logonTr = [pscustomobject]@{ ClassName = 'MSFT_TaskLogonTrigger'; StartBoundary = ''; Enabled = $true }
    $weird = [pscustomobject]@{ ClassName = 'MSFT_TaskSomethingNew'; StartBoundary = '2026-09-01T01:00:00-05:00'; Enabled = $true }
    $sCap = ConvertTo-BwTriggerSpec $capture
    T 'CLEAN TWIN a daily trigger with an hourly retry window reads as daily, not frequent' (($sCap.kind -eq 'daily') -and -not (Test-BwFrequent $sCap)) ($sCap.kind)
    T 'CLEAN TWIN a 15-minute all-day repetition reads as frequent' (Test-BwFrequent (ConvertTo-BwTriggerSpec $reaper)) 'not frequent'
    $occ = Get-BwOccurrences -Spec $sCap -From ([datetime]'2026-09-14T13:00:02') -To $l17
    T 'MUST FIRE  the 08:00 capture missed its six hourly slots on each of 09-15 and 09-16 (12), none on 09-17 before 05:06' ($occ.Count -eq 12) $occ.Count
    $tasks = @(
      [pscustomobject]@{ name = 'TC Grocery Daily Capture 0800'; lastRun = [datetime]'2026-09-14T13:00:02'; startWhenAvailable = $true; specs = @($sCap) },
      [pscustomobject]@{ name = 'TC Process Reaper'; lastRun = [datetime]'2026-09-14T22:15:00'; startWhenAvailable = $true; specs = @((ConvertTo-BwTriggerSpec $reaper)) },
      [pscustomobject]@{ name = 'TC Approvals Page'; lastRun = [datetime]'2026-09-14T08:00:00'; startWhenAvailable = $false; specs = @((ConvertTo-BwTriggerSpec $logonTr)) },
      [pscustomobject]@{ name = 'TC Odd'; lastRun = [datetime]'2026-09-14T08:00:00'; startWhenAvailable = $false; specs = @((ConvertTo-BwTriggerSpec $weird)) }
    )
    $rows = Get-BwMissedJobs -Tasks $tasks -BootTime $b14 -LogonTime $l17
    $cap = @($rows | Where-Object { $_.name -eq 'TC Grocery Daily Capture 0800' })
    T 'MUST FIRE  the founding case: the daily capture lost two whole days (09-15, 09-16)' (($cap.Count -eq 1) -and ($cap[0].lostDays -eq 2) -and ($cap[0].kind -eq 'daily')) (($cap | ForEach-Object { "$($_.kind) lost=$($_.lostDays)" }) -join ';')
    T 'MUST FIRE  and that pages' (Test-BwBootPage $rows) 'no page'
    T 'MUST NOT FIRE a logon-triggered task is never counted as missing a run' (@($rows | Where-Object { $_.name -eq 'TC Approvals Page' }).Count -eq 0) 'listed'
    $odd = @($rows | Where-Object { $_.name -eq 'TC Odd' })
    T 'MUST FIRE  a trigger kind this cannot read is listed as UNREADABLE, never as nothing missed' (($odd.Count -eq 1) -and ($odd[0].kind -eq 'unreadable')) (($odd | ForEach-Object { $_.kind }) -join ';')
    $body = Format-BwBootBody -BootTime $b14 -LogonTime $l17 -Rows $rows -Locked $false
    T 'CLEAN TWIN the page says when it rebooted and names the job that lost days' (($body -like '*rebooted at 2026-09-14 22:32*') -and ($body -like '*TC Grocery Daily Capture 0800 (daily)*lost days 2*')) $body

    # A short update restart: 03:14 to a sign-in at 03:16 misses only the 03:15 ratchets, which StartWhenAvailable makes up.
    $short = @(
      [pscustomobject]@{ name = 'TC Daily Ratchets 0315'; lastRun = [datetime]'2026-09-24T03:15:01'; startWhenAvailable = $true; specs = @((ConvertTo-BwTriggerSpec $ratchet)) },
      [pscustomobject]@{ name = 'TC Process Reaper'; lastRun = [datetime]'2026-09-25T03:00:02'; startWhenAvailable = $true; specs = @((ConvertTo-BwTriggerSpec $reaper)) }
    )
    $sRows = Get-BwMissedJobs -Tasks $short -BootTime ([datetime]'2026-09-25T03:14:30') -LogonTime ([datetime]'2026-09-25T03:16:10')
    $rat = @($sRows | Where-Object { $_.name -eq 'TC Daily Ratchets 0315' })
    T 'MUST NOT FIRE a short restart whose one missed daily run is made up at sign-in does not page' ((-not (Test-BwBootPage $sRows)) -and ($rat.Count -eq 1) -and ($rat[0].lostDays -eq 0)) (($sRows | ForEach-Object { "$($_.name) lost=$($_.lostDays)" }) -join ';')
    $noSwa = @([pscustomobject]@{ name = 'TC Daily Ratchets 0315'; lastRun = [datetime]'2026-09-24T03:15:01'; startWhenAvailable = $false; specs = @((ConvertTo-BwTriggerSpec $ratchet)) })
    $nRows = Get-BwMissedJobs -Tasks $noSwa -BootTime ([datetime]'2026-09-25T03:14:30') -LogonTime ([datetime]'2026-09-25T03:16:10')
    T 'MUST FIRE  the same miss on a job that does NOT catch up is a lost day, and pages' (Test-BwBootPage $nRows) (($nRows | ForEach-Object { "lost=$($_.lostDays)" }) -join ';')
    $fq = @([pscustomobject]@{ name = 'TC Process Reaper'; lastRun = [datetime]'2026-09-14T22:15:00'; startWhenAvailable = $true; specs = @((ConvertTo-BwTriggerSpec $reaper)) })
    T 'MUST NOT FIRE a 15-minute job alone never pages, however much it missed' (-not (Test-BwBootPage (Get-BwMissedJobs -Tasks $fq -BootTime $b14 -LogonTime $l17))) 'paged'
    $wk = [pscustomobject]@{ ClassName = 'MSFT_TaskWeeklyTrigger'; StartBoundary = '2026-09-02T06:00:00-05:00'; WeeksInterval = 1; DaysOfWeek = 8; Enabled = $true; Repetition = $null }
    $wOcc = Get-BwOccurrences -Spec (ConvertTo-BwTriggerSpec $wk) -From ([datetime]'2026-09-21T00:00:00') -To ([datetime]'2026-09-24T12:00:00')
    T 'CLEAN TWIN a weekly Wednesday 06:00 trigger has one occurrence between Monday and Thursday' (($wOcc.Count -eq 1) -and ($wOcc[0] -eq [datetime]'2026-09-23T06:00:00')) (($wOcc | ForEach-Object { $_.ToString('s') }) -join ',')

    # ---- the heartbeat reply ----
    $now = [datetime]'2026-09-25T18:00:00'
    $ok = [pscustomobject]@{ ok = $true; last_check_at = '2026-09-25T17:52:00.000Z' }
    T 'CLEAN TWIN a beat with a fresh watcher check is ok' ((Get-BwBeatVerdict -Status 200 -Body $ok -NowUtc $now -WatcherStaleMinutes 120 -FirstConfiguredUtc $null).state -eq 'ok') 'not ok'
    $atBar = [pscustomobject]@{ ok = $true; last_check_at = '2026-09-25T16:00:00Z' }
    T 'MUST NOT FIRE AT THE BAR: a watcher that checked exactly 120 minutes ago is ok' ((Get-BwBeatVerdict -Status 200 -Body $atBar -NowUtc $now -WatcherStaleMinutes 120 -FirstConfiguredUtc $null).state -eq 'ok') 'stale'
    $past = [pscustomobject]@{ ok = $true; last_check_at = '2026-09-25T15:59:00Z' }
    $pv = Get-BwBeatVerdict -Status 200 -Body $past -NowUtc $now -WatcherStaleMinutes 120 -FirstConfiguredUtc $null
    T 'MUST FIRE  ONE STEP PAST THE BAR: a watcher last seen 121 minutes ago is a finding' (($pv.state -eq 'watcher-stale') -and $pv.finding) $pv.state
    $nv = [pscustomobject]@{ ok = $true; last_check_at = $null }
    T 'MUST NOT FIRE a watcher that has not checked yet, just after setup, is not a finding' (-not (Get-BwBeatVerdict -Status 200 -Body $nv -NowUtc $now -WatcherStaleMinutes 120 -FirstConfiguredUtc $now.AddMinutes(-30)).finding) 'finding'
    $nn = Get-BwBeatVerdict -Status 200 -Body $nv -NowUtc $now -WatcherStaleMinutes 120 -FirstConfiguredUtc $now.AddMinutes(-121)
    T 'MUST FIRE  beats landing for 121 minutes with no watcher check means the cron is missing' (($nn.state -eq 'watcher-never') -and $nn.finding) $nn.state
    $rf = Get-BwBeatVerdict -Status 401 -Body $null -NowUtc $now -WatcherStaleMinutes 120 -FirstConfiguredUtc $null
    T 'MUST FIRE  a refused auth hash is a finding' (($rf.state -eq 'refused') -and $rf.finding) $rf.state
    foreach ($c in @(@(503, 'not-configured'), @(404, 'not-deployed'), @(0, 'unreachable'), @(502, 'error'))) {
      $cv = Get-BwBeatVerdict -Status $c[0] -Body $null -NowUtc $now -WatcherStaleMinutes 120 -FirstConfiguredUtc $null
      T ("MUST NOT FIRE a {0} reply reads '{1}' and is not a finding" -f $c[0], $c[1]) (($cv.state -eq $c[1]) -and -not $cv.finding) $cv.state
    }
    T 'CLEAN TWIN the auth hash is lower-case hex SHA-256, as the Worker computes it (vector: abc)' ((Get-BwNotifyAuth 'abc') -eq 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad') (Get-BwNotifyAuth 'abc')

    # ---- state ----
    $sp = Join-Path $scratch 'state.json'
    $s0 = Read-BwState $sp
    T 'CLEAN TWIN no state file reads as no boot handled' ($s0.handled_boot -eq '') $s0.handled_boot
    Write-BwState -Path $sp -HandledBoot (Get-BwBootKey $boot) -FirstConfiguredUtc $now -Note 'selftest'
    $s1 = Read-BwState $sp
    T 'CLEAN TWIN the handled boot and first-configured time round-trip' (($s1.handled_boot -eq '2026-09-22T12:25:22') -and ($s1.first_configured_utc -eq $now)) ("{0} {1}" -f $s1.handled_boot, $s1.first_configured_utc)
    [IO.File]::WriteAllText($sp, '{not json')
    T 'CLEAN TWIN a corrupt state file reads as no boot handled rather than throwing' ((Read-BwState $sp).handled_boot -eq '') 'threw or kept'

    # ---- the live path's own wiring, read from this file (needles by concatenation) ----
    $src = [IO.File]::ReadAllText($PSCommandPath)
    T 'CLEAN TWIN the live path consults the lock verdict before it locks' ($src.Contains('$lv = Get-BootWatch' + 'LockVerdict')) 'not wired'
    T 'CLEAN TWIN the boot-page subject is a literal with no digits' (($src.Contains("-Subject 'Ops: the box rebooted" + " and daily jobs were missed'")) -and -not ('Ops: the box rebooted and daily jobs were missed' -match '\d')) 'subject'
  } catch {
    T ('the self-test itself threw: ' + $_.Exception.Message) $false $_.ScriptStackTrace
  } finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
  }
  $EXPECTED = 45
  if ($ran -ne $EXPECTED) { Write-Output ("  X     ran {0} cases, expected {1}" -f $ran, $EXPECTED); $bad++ }
  Write-Output ''
  if ($bad -gt 0) { Write-Output ("boot-watch self-test: FAIL ({0} of {1} case(s))" -f $bad, $ran); exit 1 }
  Write-Output ("boot-watch self-test: PASS ({0} case(s), 0 failed)" -f $ran)
  exit 0
}

# ---------------------------------------------------------------------------
# EVERY HIDDEN SCHEDULED TASK WRITES A RUN RECORD (backlog E29, ops\audit-run-log-claims.ps1).
$script:RunLog = Start-RunLog -Name 'boot-watch' -OutDir (Join-Path $RepoRoot 'ops\out')
try {
  $now = Get-Date
  $bootTime = $null
  try { $bootTime = [datetime](Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime } catch { $bootTime = $null }
  if (-not $bootTime) {
    Write-Output 'boot-watch: COULD NOT LOOK - LastBootUpTime could not be read'
    Exit-Guard -Name 'BOOT-WATCH' -Code 3 -Summary 'boot time unreadable'
  }
  $bootKey = Get-BwBootKey $bootTime

  # The interactive sign-in of THIS user: the newest interactive logon session, else explorer's start.
  $logonTime = $null
  try {
    $me = ([Security.Principal.WindowsIdentity]::GetCurrent().Name -split '\\')[-1]
    $sessions = Get-CimInstance Win32_LogonSession -Filter 'LogonType=2 OR LogonType=10 OR LogonType=11' -ErrorAction Stop
    foreach ($s in @($sessions)) {
      $u = Get-CimAssociatedInstance -InputObject $s -Association Win32_LoggedOnUser -ErrorAction SilentlyContinue
      $mine = $false
      foreach ($x in @($u)) { if ($x -and [string]::Equals([string]$x.Name, $me, [StringComparison]::OrdinalIgnoreCase)) { $mine = $true } }
      if ($mine -and $s.StartTime -and $s.StartTime -le $now -and ((-not $logonTime) -or $s.StartTime -gt $logonTime)) { $logonTime = [datetime]$s.StartTime }
    }
  } catch { $logonTime = $null }
  if (-not $logonTime) {
    try {
      $sid = [Diagnostics.Process]::GetCurrentProcess().SessionId
      $ex = @(Get-Process explorer -ErrorAction Stop | Where-Object { $_.SessionId -eq $sid } | Sort-Object StartTime)
      if ($ex.Count) { $logonTime = [datetime]$ex[0].StartTime }
    } catch { $logonTime = $null }
  }

  $state = Read-BwState $StatePath
  $findings = 0
  Write-Output ("boot-watch: boot {0}, sign-in {1}, handled boot '{2}'" -f $bootKey, $(if ($logonTime) { $logonTime.ToString('s') } else { 'UNREADABLE' }), $state.handled_boot)

  $handledNow = $state.handled_boot
  if (-not [string]::Equals($state.handled_boot, $bootKey, [StringComparison]::Ordinal)) {
    # 1. LOCK FIRST, before anything slow, so an automatic sign-in is not left open while the rest runs.
    $aal = ''
    try { $aal = [string](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name 'AutoAdminLogon' -ErrorAction Stop).AutoAdminLogon } catch { $aal = '' }
    $lv = Get-BootWatchLockVerdict -BootTime $bootTime -LogonTime $logonTime -Now $now -AutoAdminLogon $aal -HandledBoot $state.handled_boot `
                                   -WindowMinutes $LockWindowMinutes -RecentMinutes $LogonRecentMinutes
    $locked = $false
    if ($lv.lock -and $Lock) {
      & (Join-Path $env:SystemRoot 'System32\rundll32.exe') 'user32.dll,LockWorkStation'
      $locked = $true
      Write-Output ("boot-watch: LOCKED the workstation - " + $lv.why)
    } elseif ($lv.lock) {
      Write-Output ("boot-watch: WOULD LOCK (-Lock not passed) - " + $lv.why)
    } else {
      Write-Output ("boot-watch: no lock - " + $lv.why)
    }

    # 2. THE BOOT PAGE.
    $rv = Get-BootWatchReportVerdict -BootTime $bootTime -LogonTime $logonTime -Now $now -HandledBoot $state.handled_boot -RecentMinutes $LogonRecentMinutes
    if ($rv.report) {
      $records = New-Object 'System.Collections.Generic.List[object]'
      $live = @(Get-ScheduledTask -TaskName 'TC *' -ErrorAction SilentlyContinue)
      foreach ($t in $live) {
        $info = $null; try { $info = $t | Get-ScheduledTaskInfo -ErrorAction Stop } catch { $info = $null }
        $specs = New-Object 'System.Collections.Generic.List[object]'
        foreach ($tr in @($t.Triggers)) { if ($tr) { [void]$specs.Add((ConvertTo-BwTriggerSpec $tr)) } }
        # A task's own LastRunTime may already be THIS run (our own task) or a make-up run started at this sign-in;
        # either is after the sign-in and simply reads as nothing missed for it.
        [void]$records.Add([pscustomobject]@{ name = $t.TaskName; lastRun = $(if ($info) { $info.LastRunTime } else { $null });
                                              startWhenAvailable = [bool]$t.Settings.StartWhenAvailable; specs = $specs.ToArray() })
      }
      $rows = Get-BwMissedJobs -Tasks $records.ToArray() -BootTime $bootTime -LogonTime $logonTime
      $body = Format-BwBootBody -BootTime $bootTime -LogonTime $logonTime -Rows $rows -Locked $locked
      Write-Output ("boot-watch: boot report over {0} TC task(s), {1} with missed runs" -f $live.Count, @($rows).Count)
      Write-Output $body
      if (Test-BwBootPage $rows) {
        $findings++
        $alert = Join-Path $RepoRoot 'grocery\send-alert.ps1'
        if ($Alert -and (Test-Path -LiteralPath $alert)) {
          try { & $alert -Subject 'Ops: the box rebooted and daily jobs were missed' -Body $body -Emitter 'ops\boot-watch.ps1' }
          catch { Write-Output ("boot-watch: ALERT SEND FAILED - " + $_.Exception.Message) }
        } else { Write-Output 'boot-watch: WOULD PAGE (-Alert not passed)' }
      } else {
        Write-Output 'boot-watch: no daily job lost a day, so this is logged and not paged'
      }
    } else {
      Write-Output ("boot-watch: no boot report - " + $rv.why)
    }
    $handledNow = $bootKey
    Write-BwState -Path $StatePath -HandledBoot $handledNow -FirstConfiguredUtc $state.first_configured_utc -Note ("lock: {0}; report: {1}" -f $lv.why, $rv.why)
  }

  # 3. THE OFF-BOX HEARTBEAT.
  if ($Beat) {
    $key = $env:GHOST_ADMIN_KEY
    if (-not $key) { $kf = Join-Path $RepoRoot 'meal-prep\.ghostkey'; if (Test-Path -LiteralPath $kf) { $key = ([IO.File]::ReadAllText($kf)).Trim() } }
    if (-not $key) {
      Write-Output 'boot-watch: heartbeat NOT SENT - no GHOST_ADMIN_KEY and no meal-prep\.ghostkey on this box'
    } else {
      $auth = Get-BwNotifyAuth $key
      $key = $null
      [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
      $payload = ([ordered]@{ boot_at = $bootTime.ToUniversalTime().ToString('o'); host = $env:COMPUTERNAME; sent_at = (Get-Date).ToUniversalTime().ToString('o') } | ConvertTo-Json -Compress)
      $status = 0; $bodyObj = $null
      try {
        $resp = Invoke-WebRequest -Uri $HeartbeatUrl -Method Post -UseBasicParsing -ContentType 'application/json' -Headers @{ 'X-Notify-Auth' = $auth } -Body $payload -TimeoutSec 15 -ErrorAction Stop
        $status = [int]$resp.StatusCode
        try { $bodyObj = $resp.Content | ConvertFrom-Json } catch { $bodyObj = $null }
      } catch [System.Net.WebException] {
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode } else { $status = 0 }
      } catch { $status = 0 }
      $fc = $state.first_configured_utc
      if ($status -eq 200 -and -not $fc) { $fc = (Get-Date).ToUniversalTime() }
      $bv = Get-BwBeatVerdict -Status $status -Body $bodyObj -NowUtc (Get-Date).ToUniversalTime() -WatcherStaleMinutes $WatcherStaleMinutes -FirstConfiguredUtc $fc
      Write-Output ("boot-watch: heartbeat {0} (HTTP {1}) - {2}" -f $bv.state, $status, $bv.why)
      if ($fc -ne $state.first_configured_utc) { Write-BwState -Path $StatePath -HandledBoot $handledNow -FirstConfiguredUtc $fc -Note 'first configured beat' }
      if ($bv.finding) {
        $findings++
        $alert = Join-Path $RepoRoot 'grocery\send-alert.ps1'
        $msg = ("{0}`n`nThe box sends a heartbeat to {1} every 15 minutes and a Cloudflare cron pages Brad when it stops. See design/ready-for-brad/Q4-autologon-and-box-heartbeat.md." -f $bv.why, $HeartbeatUrl)
        if ($Alert -and (Test-Path -LiteralPath $alert)) {
          try {
            if ($bv.state -eq 'refused') {
              & $alert -Subject 'Ops: the off-box heartbeat refused this box' -Body $msg -Emitter 'ops\boot-watch.ps1'
            } else {
              & $alert -Subject 'Ops: the off-box heartbeat watcher is not checking' -Body $msg -Emitter 'ops\boot-watch.ps1'
            }
          } catch { Write-Output ("boot-watch: ALERT SEND FAILED - " + $_.Exception.Message) }
        }
      }
    }
  }

  $summary = ("boot={0} findings={1}" -f $bootKey, $findings)
  if ($findings -gt 0) { Exit-Guard -Name 'BOOT-WATCH' -Code 1 -Summary $summary }
  Exit-Guard -Name 'BOOT-WATCH' -Code 0 -Summary $summary
} finally {
  $rcLog = if ($script:TcGuardMarkerWritten) { 0 } else { 1 }
  Stop-RunLog -ExitCode $rcLog -Path $script:RunLog
}
