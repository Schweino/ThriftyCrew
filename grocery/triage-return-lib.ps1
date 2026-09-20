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

# Read-JsonFile, not Get-Content -Raw | ConvertFrom-Json (2026-09-20, queue 2026-09-19-b66b54). PS 5.1
# decodes a BOM-less file with the ANSI codepage, and the plan files this lib reads are written by tools
# that emit BOM-less UTF-8 - so a bare read mangles every non-ASCII character in a resolution_note or an
# item title and the RETURN rule then compares mojibake. grocery\audit-json-readers.ps1 is the ratchet.
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')

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

# --- A RETURN SKIPS THE REVIEWER (Brad's ruling, 2026-09-20) ------------------------------------------------
# Measured that morning over the four days grocery\triage-plans\cost-ledger.jsonl covers (2026-09-10, 09-11,
# 09-18, 09-19): 5.8M agent tokens, and 116 of the 323 alerts in 30 days (36%) were a type triage had already
# closed. A returning type paid full diagnosis price a second and a third time, at about 317k tokens a reviewer
# run, to re-derive a root cause a committed plan already holds.
# THE ROUTE IS A POINTER, NOT A VERDICT. It names where the last answer is written. The lane still re-measures
# the alert against today's board (the RE-MEASURE FIRST rule above), which is what keeps a wrong prior diagnosis
# costing one lane's re-measurement instead of becoming the new answer.
function Get-TriageRouteLane {
  <# .SYNOPSIS Pure. The lane a plan item belongs to: its own field, else the SKILL's money test, else ops. #>
  param($Item)
  if (-not $Item) { return 'ops' }
  $lane = ''
  try { if ($Item.PSObject.Properties['lane']) { $lane = ([string]$Item.lane).Trim().ToLowerInvariant() } } catch { $lane = '' }
  if ($lane -eq 'money' -or $lane -eq 'ops') { return $lane }
  # The SKILL's money test in the order it states it: a publish, then the three money classifications.
  $batch = 0
  try { if ($Item.PSObject.Properties['publish_batch']) { $batch = [int]$Item.publish_batch } } catch { $batch = 0 }
  if ($batch -ge 1) { return 'money' }
  $cls = ''
  try { $cls = ([string]$Item.classification).Trim().ToLowerInvariant() } catch { $cls = '' }
  if ($cls -eq 'wrong-product' -or $cls -eq 'parse-basis-bug' -or $cls -eq 'real-economics') { return 'money' }
  return 'ops'
}
function Get-TriageReturnRoute {
  <# .SYNOPSIS Pure. Where a returning item's last answer is written: the newest prior id any plan record holds. #>
  param($PriorIds, $PlanRecords)
  $r = [pscustomobject]@{ found = $false; prior_id = ''; plan = ''; lane = ''; status = ''; why = '' }
  $ids = @($PriorIds)
  if ($ids.Count -eq 0) { $r.why = 'no prior closes'; return $r }
  $plans = @($PlanRecords)
  if ($plans.Count -eq 0) { $r.why = 'no plan file could be read'; return $r }
  # Priors arrive oldest first, so walk backwards: the NEWEST close is the one whose fix is on disk today.
  for ($k = $ids.Count - 1; $k -ge 0; $k--) {
    $id = [string]$ids[$k]
    foreach ($p in $plans) {
      if (-not $p) { continue }
      foreach ($it in @($p.items)) {
        if (-not $it) { continue }
        $qid = ''
        try { $qid = ([string]$it.queue_id).Trim() } catch { $qid = '' }
        if (-not [string]::Equals($qid, $id, [StringComparison]::Ordinal)) { continue }
        $r.found = $true
        $r.prior_id = $id
        $r.plan = [string]$p.path
        $r.lane = Get-TriageRouteLane $it
        try { $r.status = ([string]$it.status).Trim() } catch { $r.status = '' }
        return $r
      }
    }
  }
  $r.why = ('no committed plan holds ' + ($ids -join ', '))
  return $r
}
function Format-TriageRouteLine {
  <# .SYNOPSIS Pure. The ROUTE line under a RETURN, or $null when there is nothing to point at. #>
  param([string]$Id, $Route)
  if (-not $Route -or -not $Route.found) { return $null }
  $st = ''
  try { $st = [string]$Route.status } catch { $st = '' }
  if (-not $st) { $st = 'unrecorded' }
  return ('    ROUTE: ' + $Id + ' - give it to the ' + [string]$Route.lane + ' lane seeded with ' + [string]$Route.plan +
          ' item ' + [string]$Route.prior_id + ' (prior status ' + $st + '), no fresh reviewer diagnosis. Re-measure it against today''s board first.')
}
# --- UNFINISHED WORK IS DUE WORK (Brad's ruling, 2026-09-20, design\PLAN-alert-quiet-2026-09-20.md) ---------
# FOUNDING MEASUREMENT, from this estate's own plan files over 2026-09-10 to 2026-09-20: of 52 real work
# outcomes only 20 are a clean `done`. 17 are `deviated` and 9 are `needs-more-time`, and both mean the root
# fix as specified did not fully land. Four of the five traced return chains start at one of those two
# statuses. The founding case is queue 2026-09-18-f90ba6, closed `needs-more-time` in plan-2026-09-18.json,
# which returned the next day as 2026-09-19-b66b54 and paid a fresh reviewer diagnosis (408,197 tokens that
# day) to re-derive an answer the committed plan already held.
# THE CLOSE IS DELIBERATELY NOT BLOCKED. The queue's `disposition` answers "was the ALERT RIGHT"
# (triage-lib.ps1's header: confirmed / false-alarm / superseded / by-design / wont-fix) and exists so a
# detector's live precision becomes knowable. Whether the FIX FINISHED is a different axis and lives in the
# plan item's `status`. Blocking a close on plan status would jam the two axes together and corrupt the
# precision measure. So unfinished work becomes VISIBLE and DUE instead: triage-due.ps1 prints a RESUME
# section above its DUE list, and RESUME work alone makes the run due.
function Get-TriageUnfinished {
  <# .SYNOPSIS Pure. One record per queue item whose NEWEST plan item closed `deviated` or `needs-more-time`:
     id, subject, plan, status (the plan item's) and lane. Never throws; a plan it cannot read is skipped. #>
  param($Items, $PlanRecords)
  $out = New-Object System.Collections.Generic.List[object]
  $plans = @($PlanRecords)
  if ($plans.Count -eq 0) { return ,$out.ToArray() }
  foreach ($i in @($Items)) {
    if (-not $i) { continue }
    $id = ''
    try { $id = ([string]$i.id).Trim() } catch { $id = '' }
    if (-not $id) { continue }
    $qs = ''
    try { $qs = ([string]$i.status).Trim().ToLowerInvariant() } catch { $qs = '' }
    # An OPEN item is today's work and triage-due lists it as DUE already; counting it here double-counts it.
    # A needs-brad item is PARKED on a ruling of Brad's and is never re-triaged (send-alert.ps1's escalation).
    if ($qs -eq 'open' -or $qs -eq 'needs-brad') { continue }
    # NEWEST PLAN WINS, and the rule is Get-TriageReturnRoute's rather than a second copy of it: two copies of
    # "which plan is newest" is how they diverge. One id in, so the route it finds is this item's own newest.
    $route = $null
    try { $route = Get-TriageReturnRoute @($id) $plans } catch { $route = $null }
    if (-not $route -or -not $route.found) { continue }
    $ps = ''
    try { $ps = ([string]$route.status).Trim().ToLowerInvariant() } catch { $ps = '' }
    # done and superseded finished; needs-brad is a ruling and blocked is waiting on something outside triage.
    if ($ps -ne 'deviated' -and $ps -ne 'needs-more-time') { continue }
    $subj = ''
    try { if ($i.PSObject.Properties['subject']) { $subj = ([string]$i.subject).Trim() } } catch { $subj = '' }
    [void]$out.Add([pscustomobject]@{
      id = $id; subject = $subj; plan = [string]$route.plan
      status = ([string]$route.status).Trim(); lane = [string]$route.lane })
  }
  return ,$out.ToArray()
}
function Format-TriageResumeLines {
  <# .SYNOPSIS Pure. The RESUME block triage-due.ps1 prints ABOVE its DUE list, or no lines at all. #>
  param($Unfinished)
  $lines = New-Object System.Collections.Generic.List[string]
  $u = @($Unfinished)
  if ($u.Count -eq 0) { return ,$lines.ToArray() }
  [void]$lines.Add('DUE  RESUME ' + $u.Count + ' unfinished root fix(es). Each of these closed its queue item with the class' +
                   ' still open, so it is the next run''s FIRST work: resume from the named plan item, do not re-diagnose it.')
  foreach ($r in $u) {
    $s = [string]$r.subject
    if ($s) { $s = ' - ' + $s }
    [void]$lines.Add('  RESUME: ' + [string]$r.id + ' - ' + [string]$r.plan + ' closed it ' + [string]$r.status +
                     ', lane ' + [string]$r.lane + $s)
  }
  return ,$lines.ToArray()
}
function Read-TriagePlanRecords {
  <# .SYNOPSIS Plan files as {path, items}, newest name first. Never throws: an unreadable plan is skipped. #>
  param([string]$PlansDir, [int]$Newest = 40)
  $out = New-Object System.Collections.Generic.List[object]
  if (-not $PlansDir -or -not (Test-Path -LiteralPath $PlansDir)) { return ,$out.ToArray() }
  $files = @()
  try { $files = @(Get-ChildItem -LiteralPath $PlansDir -Filter 'plan-*.json' -File -ErrorAction Stop | Sort-Object Name -Descending) } catch { return ,$out.ToArray() }
  $kept = 0
  foreach ($f in $files) {
    if ($kept -ge $Newest) { break }
    if ($f.Name -like '*.routing.json') { continue }
    try {
      $j = Read-JsonFile $f.FullName
      if ($null -eq $j -or -not $j.items) { continue }
      [void]$out.Add([pscustomobject]@{ path = ('grocery/triage-plans/' + $f.Name); items = @($j.items) })
      $kept++
    } catch { continue }
  }
  return ,$out.ToArray()
}
