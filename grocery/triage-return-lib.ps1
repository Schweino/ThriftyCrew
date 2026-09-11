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

# --- THE ALERT CENSUS, READ BY THE GATE (2026-09-10, Brad's ruling 6, the weekly lane plans ahead) -----------------
# ONE copy of "on how many days did this type fire in a window", shared by audit-alert-census.ps1 (its RECURRING
# table) and validate-triage-plan.ps1 (a weekly plan's prevention_target), so the number the scoreboard prints and the
# number the gate recomputes cannot drift apart. The census's definition stands: a type fired on a day when its
# out\alert-census.jsonl row for that day has alerts > 0, which is a new queue id that day or an absorbed recurrence
# that day (audit-alert-census.ps1, Get-CensusRows). A row carrying only a close is not a day fired.
# Not a tuned number: ruling 6 states the target's days fired over the PRIOR 14 DAYS, so 14 is Brad's floor, and a
# plan may count over a wider window. When the census producer stops, the rows stop, days fired fall to 0, and the
# gate refuses a target that fired on no day, so a stale census cannot pass a plan (it names the census's top instead).
$script:PreventionWindowDaysMin = 14

function Read-AlertCensusFile {
  <# .SYNOPSIS Reads out\alert-census.jsonl. ok=$false with why when missing, empty, or any line that is not a day/type
     row with alerts, so a caller reports BLIND instead of counting days from half a file. Never throws. #>
  param([string]$Path)
  if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @{ ok = $false; why = "there is no alert census at $Path"; rows = @() } }
  $lines = $null
  try { $lines = [IO.File]::ReadAllLines($Path, (New-Object Text.UTF8Encoding($false))) }
  catch { return @{ ok = $false; why = ("the alert census at $Path could not be read: " + $_.Exception.Message); rows = @() } }
  $rows = New-Object System.Collections.Generic.List[object]
  $n = 0; $bad = 0
  foreach ($line in @($lines)) {
    if (-not ([string]$line).Trim()) { continue }
    $n++
    $o = $null
    try { $o = $line | ConvertFrom-Json } catch { $o = $null }
    if (-not $o -or -not [string]$o.date -or -not [string]$o.type -or -not $o.PSObject.Properties['alerts']) { $bad++; continue }
    [void]$rows.Add($o)
  }
  if ($bad -gt 0) { return @{ ok = $false; why = "the alert census at $Path has $bad of $n line(s) that are not a day/type row with alerts"; rows = @() } }
  if ($rows.Count -eq 0) { return @{ ok = $false; why = "the alert census at $Path reads back empty"; rows = @() } }
  return @{ ok = $true; why = ''; rows = $rows.ToArray() }
}

function Get-AlertCensusTypeDays {
  <# .SYNOPSIS Pure. Census day/type rows -> one record per type that fired in the WindowDays days ending on End,
     inclusive: type, days (distinct dates with alerts > 0), alerts, returns, subject (the newest row's), and rank
     (1 + the number of types that fired on MORE days, so tied types share a rank). Most days first. Never throws. #>
  param($Rows, [datetime]$End, [int]$WindowDays)
  $out = New-Object System.Collections.Generic.List[object]
  if ($WindowDays -lt 1) { return ,$out.ToArray() }
  $endK = $End.ToString('yyyy-MM-dd')
  $startK = $End.AddDays(-($WindowDays - 1)).ToString('yyyy-MM-dd')
  $by = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
  foreach ($r in @($Rows)) {
    if (-not $r) { continue }
    $d = [string]$r.date; $t = [string]$r.type
    if (-not $d -or -not $t) { continue }
    if ([string]::CompareOrdinal($d, $startK) -lt 0 -or [string]::CompareOrdinal($d, $endK) -gt 0) { continue }
    $a = 0; try { $a = [int]$r.alerts } catch { $a = 0 }
    if ($a -le 0) { continue }
    if (-not $by.ContainsKey($t)) { $by[$t] = @{ dates = (New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)); alerts = 0; returns = 0; subject = ''; last = '' } }
    $e = $by[$t]
    [void]$e.dates.Add($d)
    $e.alerts += $a
    $rt = 0; try { $rt = [int]$r.returns } catch { $rt = 0 }
    $e.returns += $rt
    if ([string]::CompareOrdinal($d, [string]$e.last) -ge 0) { $e.last = $d; $e.subject = [string]$r.subject }
  }
  if ($by.Count -eq 0) { return ,$out.ToArray() }
  $recs = New-Object System.Collections.Generic.List[object]
  foreach ($k in $by.Keys) { [void]$recs.Add([pscustomobject]@{ type = $k; days = $by[$k].dates.Count; alerts = [int]$by[$k].alerts; returns = [int]$by[$k].returns; subject = [string]$by[$k].subject; rank = 0 }) }
  $sorted = @($recs | Sort-Object @{ Expression = { $_.days }; Descending = $true }, @{ Expression = { $_.type } })
  foreach ($x in $sorted) {
    $x.rank = 1 + @($sorted | Where-Object { $_.days -gt $x.days }).Count
    [void]$out.Add($x)
  }
  return ,$out.ToArray()
}
