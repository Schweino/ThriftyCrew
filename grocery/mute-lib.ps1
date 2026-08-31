<#
  mute-lib.ps1 - THE one definition of "is the alert mail muted?".

  ONE COPY ON PURPOSE (2026-08-31). This rule used to live inside send-alert.ps1 while triage-due.ps1
  carried its own second opinion - a bare `Test-Path alerts-muted.json`. Those two disagree the moment
  anyone uses the documented in-place off switch: setting `muted:false` keeps the file (deliberately, so
  the mute period stays on the record), so send-alert correctly resumed mailing while triage-due went on
  printing "email alerts are OFF" at the top of every run. The banner exists to tell the daily agent
  whether anyone is being emailed, so a banner that says the opposite of the truth is worse than none.
  Found the day Brad asked for the mail back. See the two-copies-of-a-rule class: a shared fix ships
  nothing while callers keep inline copies.

  Dot-source it and call Get-MuteState:
      . (Join-Path $root 'mute-lib.ps1')
      $m = Get-MuteState -Path (Join-Path $root 'alerts-muted.json') -Today (Get-Date -Format 'yyyy-MM-dd')
      if ($m.muted) { ... }   # $m.why explains the verdict in words fit to print
#>

# ---- MUTE SWITCH (2026-08-14, Brad: "stop all email alerts") --------------------------------------------
# Silences the INBOX, not the response system. The triage-queue write above still happens on every alert, so
# grocery-alert-triage keeps draining and fixing exactly as before - the only thing that stops is the mail.
# That ordering matters: the queue block runs BEFORE this gate on purpose, and moving this check earlier
# would turn "stop emailing me" into "stop responding to failures", which is the opposite of Brad's standing
# rule that an issue email must never wait for a human.
#
# The file is grocery\alerts-muted.json, and it is TRACKED (grocery\ is allow-listed) so the mute is visible
# in git rather than being one machine's invisible silence. Turn mail back on by deleting it.
#   { "muted": true, "since": "2026-08-14", "until": null, "reason": "..." }
# 'until' is optional: an ISO date past which the mute expires by itself. A mute with no expiry is the thing
# that can silently outlive its reason (see the rules-that-silently-disarm class), so every run logs the
# suppression and triage-due.ps1 prints the mute banner where the daily agent will see it.
function Get-MuteState {
  param([string]$Path, [string]$Today)
  if (-not (Test-Path $Path)) { return @{ muted = $false; why = 'no mute file' } }
  $raw = ''
  try { $raw = ((Get-Content $Path -Raw -ErrorAction Stop) + '') } catch {
    # FAIL MUTED, deliberately. Someone put this file here to stop the mail; an unreadable copy of that
    # instruction is still that instruction, and re-flooding the inbox is not the safe default here.
    return @{ muted = $true; why = 'mute file present but unreadable - honouring it as a mute' }
  }
  $cfg = $null
  if ($raw.Trim()) { try { $cfg = $raw | ConvertFrom-Json } catch { $cfg = $null } }
  if (-not $cfg) { return @{ muted = $true; why = 'mute file present but unparseable - honouring it as a mute' } }
  # an explicit false is the in-place off switch (keeps the reason/history without deleting the file)
  if ($cfg.PSObject.Properties['muted'] -and -not $cfg.muted) { return @{ muted = $false; why = 'muted=false' } }
  if ($cfg.PSObject.Properties['until'] -and [string]$cfg.until) {
    $u = $null
    try { $u = [datetime]([string]$cfg.until) } catch { $u = $null }
    # an unparseable 'until' must NOT quietly become "muted forever" - that is the whole failure mode this
    # field exists to bound, so a date nobody can read expires the mute now and says why.
    if (-not $u) { return @{ muted = $false; why = ("until='" + [string]$cfg.until + "' is not a date - mute treated as EXPIRED") } }
    if ($u -lt [datetime]$Today) { return @{ muted = $false; why = ('mute expired ' + $u.ToString('yyyy-MM-dd')) } }
    return @{ muted = $true; why = ('muted until ' + $u.ToString('yyyy-MM-dd')) }
  }
  $since = if ($cfg.PSObject.Properties['since']) { [string]$cfg.since } else { 'unknown date' }
  return @{ muted = $true; why = ('muted since ' + $since + ', no expiry') }
}
