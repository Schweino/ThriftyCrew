<#
  weekly-run-lock.ps1 - the ONE owner of grocery\out\weekly-run.lock, the marker that says "the weekly
  browser refresh is in flight; do not start a second full pipeline on these files".

  WHY (2026-07-29, measured). The weekly agent and the 8:30 daily job ran on the same working tree at the
  same time. ad-cycle-log.txt: the daily pulled at 08:31:06 and ran to 09:17:48 (46m42s). Inside that
  window out\logs\weekly-post-capture-2026-07.log shows -Phase publish at 08:46:24-08:51:39 writing
  out\verified-2026-07-29.json, out\verified-history.json and out\guards-2026-07-29.json and PUBLISHING the
  live board. The daily then graded that board with its own guards (09:14:18 GUARDS FAILED), started a link
  auto-repair and republish on top of it (09:14:23), and threw its whole 46 minutes away.
  The daily ALREADY stands down when the bot committed today - but that gate is structurally blind to the
  weekly, because the weekly's push-data.ps1 commits under Brad's own identity. git log for 2026-07-29: the
  only smp-pipeline-bot commit that day is the daily's own 09:17.

  NOTHING IN THE WEEKLY EVER HANDS THE LOCK BACK. The obvious-looking rule - release after a successful
  -Phase links, "the documented last step" - is exactly wrong, and the 2026-07-29 log says why: that run
  executed THREE successful links phases (07:55:21, 07:58:07, 08:01:34), each ending in push-data, and then
  went on to publish at 08:46:24. Releasing at 08:01:34 hands grocery\out back 28.5 minutes before the 08:30
  daily fires, i.e. it re-opens the exact hole this file exists to close. The agent iterates; there is no
  phase that reliably means "done". So the lock is taken by every phase and expires on its own terms.

  THE LOCK CARRIES ITS OWN EXPIRY. A lock that outlives its run and silently disables the daily job forever
  is strictly worse than the waste it prevents, so:
    - every acquire stamps refreshed + expires (= refreshed + TtlHours) INTO the file, and
    - the reader compares now against the file's OWN expires field. There is no TTL constant on the read
      side that can drift out of step with the write side.
  TtlHours default 4, measured over ALL 383 timestamped lines of the 2026-07-29 run (not a truncated slice):
  the gaps between consecutive log lines that exceed 20 min are 44.8, 101.5, 31.2, 29.0, 46.1, 22.9, 187.5,
  62.9 and 108.0 min. The maximum is 187.5 min (12:58:25 -> 16:05:53), so 240 min clears a real judgment
  pause with 52.5 min of margin. It also expires well before the NEXT daily tick: that run's last phase was
  19:07:26, so the lock dies at 23:07:26 - 9h22m before the following 08:30. A 3h TTL was tried and rejected:
  it goes stale 7 minutes BEFORE the run resumes across that 187.5-min gap.
  PID IS DIAGNOSTIC ONLY. Do not "improve" this into a process-liveness check: weekly-post-capture.ps1
  exits between phases, so the writing PID is dead for most of the time the lock is legitimately held.

  Modes:
    -Acquire -Phase <name>  create or refresh the lock (every weekly-post-capture phase calls this)
    -Release                delete it. The WEEKLY never calls this - only the daily, after it has reported
                            an EXPIRED lock, so debris sweeps itself up instead of being re-reported daily.
    (default)               REPORT.  exit 0 = free to run (no lock, or an EXPIRED lock - and it says so
                            loudly), 2 = HELD by a live weekly run, 3 = a lock exists but could not be
                            evaluated (fail OPEN - the caller proceeds, but the blindness is named).
  -Now / -LockFile are the fixture seam used by test-auditors.ps1, the same testability seam
  browser-refresh-due.ps1 has in -Today. Nothing in production passes them.
#>
param(
  [switch]$Acquire,
  [switch]$Release,
  [string]$Phase = '',
  [int]$TtlHours = 4,
  [string]$LockFile = '',
  [string]$Now = ''
)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$lockPath = if ($LockFile) { $LockFile } else { Join-Path $root 'out\weekly-run.lock' }

function AsDate($s) {
  try { return [datetime]::Parse([string]$s, [Globalization.CultureInfo]::InvariantCulture) } catch { return $null }
}
# ([string](Get-Content $f -Raw)) is $null on a zero-byte file and .Trim() throws on it; '' | ConvertFrom-Json
# returns $null WITHOUT throwing. Both shapes must land in "cannot evaluate", never in "held".
function ReadLock([string]$p) {
  if (-not (Test-Path $p)) { return [pscustomobject]@{ present = $false; ok = $false; why = 'no lock file'; lock = $null } }
  $raw = ''
  try { $raw = ((Get-Content $p -Raw -Encoding UTF8 -ErrorAction Stop) + '').Trim() }
  catch { return [pscustomobject]@{ present = $true; ok = $false; why = ('it cannot be read (' + $_.Exception.Message + ')'); lock = $null } }
  if ($raw -eq '') { return [pscustomobject]@{ present = $true; ok = $false; why = 'it is empty'; lock = $null } }
  $o = $null
  try { $o = $raw | ConvertFrom-Json } catch { $o = $null }
  if (($null -eq $o) -or (-not $o.expires) -or (-not $o.refreshed)) {
    return [pscustomobject]@{ present = $true; ok = $false; why = 'it is not the expected JSON (no refreshed/expires stamp)'; lock = $null }
  }
  return [pscustomobject]@{ present = $true; ok = $true; why = ''; lock = $o }
}

try {
  # $asOf, NOT $now: PowerShell variable names are case-INSENSITIVE, so $now IS the [string]$Now parameter,
  # and assigning a DateTime to it silently coerces the date back to a string ("Cannot find an overload for
  # ToString" one line later). Never name a local after a typed param.
  $asOf = if ($Now) { AsDate $Now } else { Get-Date }
  if ($null -eq $asOf) { Write-Output ('weekly-run lock: CANNOT EVALUATE - -Now "' + $Now + '" is not a date.'); exit 3 }

  if ($Acquire) {
    $dir = Split-Path $lockPath -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    # keep the ORIGINAL acquired stamp across refreshes, so the report can say how long the run has been going
    $acquired = $asOf
    $prev = ReadLock $lockPath
    if ($prev.ok) { $d = AsDate $prev.lock.acquired; if ($d) { $acquired = $d } }
    $body = [ordered]@{
      acquired  = $acquired.ToString('s')
      refreshed = $asOf.ToString('s')
      expires   = $asOf.AddHours($TtlHours).ToString('s')
      ttl_hours = $TtlHours
      pid       = $PID
      phase     = $Phase
      writer    = 'weekly-post-capture.ps1'
    }
    ($body | ConvertTo-Json) | Set-Content -Path $lockPath -Encoding ASCII
    Write-Output ('weekly-run lock ACQUIRED/REFRESHED: phase=' + $Phase + ' pid=' + $PID + ' since ' + $body.acquired + ', expires ' + $body.expires + ' (ttl ' + $TtlHours + 'h)')
    exit 0
  }

  if ($Release) {
    if (Test-Path $lockPath) { Remove-Item $lockPath -Force -ErrorAction SilentlyContinue; Write-Output 'weekly-run lock RELEASED.' }
    else { Write-Output 'weekly-run lock: nothing to release.' }
    exit 0
  }

  $r = ReadLock $lockPath
  if (-not $r.present) { Write-Output 'weekly-run lock: none - no weekly refresh is holding the tree.'; exit 0 }
  if (-not $r.ok) {
    Write-Output ('weekly-run lock: CANNOT EVALUATE - ' + $lockPath + ' exists but ' + $r.why + '. Failing OPEN (the caller proceeds); delete the file if it is debris.')
    exit 3
  }
  $exp = AsDate $r.lock.expires
  $ref = AsDate $r.lock.refreshed
  $acq = AsDate $r.lock.acquired
  if ($null -eq $exp) {
    Write-Output ('weekly-run lock: CANNOT EVALUATE - expires="' + ([string]$r.lock.expires) + '" is not a date. Failing OPEN; delete the file if it is debris.')
    exit 3
  }
  $pidTxt = [string]$r.lock.pid
  $phTxt  = [string]$r.lock.phase
  $refTxt = if ($ref) { $ref.ToString('s') } else { '?' }
  $acqTxt = if ($acq) { $acq.ToString('s') } else { '?' }
  if ($asOf -gt $exp) {
    $overdue = [int](($asOf - $exp).TotalMinutes)
    Write-Output ('weekly-run lock: STALE - ' + $lockPath + ' was written by pid ' + $pidTxt + ' (phase ' + $phTxt + '), last refreshed ' + $refTxt + ', and EXPIRED ' + $overdue + ' min ago. It is being IGNORED: a stale lock must never disable the daily job. Look for a weekly run that died in out\logs\weekly-post-capture-*.log.')
    exit 0
  }
  Write-Output ('weekly-run lock: HELD - a weekly refresh is in flight (pid ' + $pidTxt + ', phase ' + $phTxt + ', acquired ' + $acqTxt + ', last refreshed ' + $refTxt + ', expires ' + $exp.ToString('s') + ').')
  exit 2
} catch {
  # never throw at a caller: an unhandled error here must not stop the daily job or the weekly run
  Write-Output ('weekly-run lock: CANNOT EVALUATE - ' + $_.Exception.Message + '. Failing OPEN.')
  exit 3
}
