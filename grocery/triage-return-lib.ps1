<#
  triage-return-lib.ps1 - RETURNS ARE FAILURES (2026-09-10, Brad's ruling 5,
  design/PLAN-zero-alert-days-2026-09-10.md section 4 Phase 4 and section 7).
  Functions only; dot-source it. ONE copy of "is this queue item a RETURN?", read by triage-due.ps1 (advisory
  RETURN lines) and validate-triage-plan.ps1 (the plan gate), so the line the orchestrator hands the reviewer
  and the rule the gate enforces cannot drift apart. Both self-tests reach it.

  A RETURN is a queue item whose `type` already has an EARLIER item (ordered by ts) closed as resolved inside the
  queue's 30-day window. That is audit-alert-census.ps1's definition of a return, and the window is
  send-alert.ps1's own retention cut, which keys on the item's ts. send-alert never absorbs a new alert into a
  resolved item, so a new id for a closed type is exactly "a fix that did not hold".
  FOUNDING MEASUREMENT: over 2026-08-22 to 2026-09-10, 25 alert types fired on 3 or more days and all 25 came
  back after a close, because each close repaired the instance and nothing asked about the source.
#>

# Not a tuned number: send-alert.ps1 drops resolved items whose ts is older than 30 days, so the queue cannot
# show a close older than this. If the retention moves, this moves with it. When the producer stops (no new
# alerts) nothing is a return, which is the right answer, not a blind one.
$script:TriageReturnWindowDays = 30

function Get-TriageReturnPriors {
  <# .SYNOPSIS Pure. Ids of EARLIER same-type queue items closed as resolved within the window, oldest first. Never throws on bad data. #>
  param($QueueItems, $Item, [datetime]$Now, [int]$WindowDays = $script:TriageReturnWindowDays)
  $out = New-Object System.Collections.Generic.List[string]
  if (-not $Item) { return ,$out.ToArray() }
  $type = ([string]$Item.type).Trim()
  $id = [string]$Item.id
  $ts = [string]$Item.ts
  if (-not $type -or -not $ts) { return ,$out.ToArray() }
  $cut = $Now.AddDays(-$WindowDays)
  $hits = New-Object System.Collections.Generic.List[object]
  foreach ($p in @($QueueItems)) {
    if (-not $p) { continue }
    if ([string]$p.status -ne 'resolved') { continue }        # open and needs-brad were never closed
    if ([string]$p.id -eq $id) { continue }
    # Ordinal: types are send-alert's normalised keys, and a culture compare is blind to damage (ops-and-gates.md).
    if (-not [string]::Equals(([string]$p.type).Trim(), $type, [StringComparison]::Ordinal)) { continue }
    $pts = [string]$p.ts
    if (-not $pts -or [string]::CompareOrdinal($pts, $ts) -ge 0) { continue }   # earlier by ts, as the census orders them
    $pdt = $null
    try { $pdt = [datetime]::Parse($pts, [Globalization.CultureInfo]::InvariantCulture) } catch { $pdt = $null }
    if ($null -eq $pdt -or $pdt -lt $cut) { continue }        # outside the queue's window, or undatable
    [void]$hits.Add($p)
  }
  foreach ($h in ($hits | Sort-Object { [string]$_.ts })) { [void]$out.Add([string]$h.id) }
  return ,$out.ToArray()
}

function Get-TriageReturnLines {
  <# .SYNOPSIS Pure. One '  RETURN:' line per open item whose type triage already closed inside the window. #>
  param($OpenItems, $QueueItems, [datetime]$Now)
  $lines = New-Object System.Collections.Generic.List[string]
  foreach ($i in @($OpenItems)) {
    if (-not $i) { continue }
    $pr = Get-TriageReturnPriors $QueueItems $i $Now
    $pr = @($pr)
    if ($pr.Count -eq 0) { continue }
    [void]$lines.Add(('  RETURN: ' + [string]$i.id + ' - ' + ([string]$i.type).Trim() + ' was closed ' + $pr.Count +
                      ' time(s) in ' + $script:TriageReturnWindowDays + ' days (' + ($pr -join ', ') + ')'))
  }
  return ,$lines.ToArray()
}
