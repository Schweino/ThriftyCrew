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

# THE ARCHIVE IS PART OF THE RECORD (2026-09-22, queue 2026-09-21-594c27; F1 in design/RCA-holistic-2026-09-22.md).
# The queue was the one record of every close for 30 days until a hand run moved 357 items, 169 of them resolved
# inside the window, into grocery\out\archive\triage-queue.archived-2026-09-17.json. Nothing read that file, so
# every "has this type been closed before" answer lost those closes and the RETURN scoreboard under-counted. Every
# reader of the RETURN rule now takes the queue UNIONED with every archive file in that directory; the window is
# applied after the union exactly as before, so an archived close older than 30 days still counts for nothing.
# The directory is gitignored: a worktree without it reads the queue alone, which is the pre-2026-09-22 answer.
function Read-TriageArchivedItems {
  <# .SYNOPSIS Every item of every triage-queue*.json under the archive directory. Never throws: an unreadable file is skipped. #>
  param([string]$ArchiveDir)
  $out = New-Object System.Collections.Generic.List[object]
  if (-not $ArchiveDir -or -not (Test-Path -LiteralPath $ArchiveDir)) { return ,$out.ToArray() }
  $files = @()
  try { $files = @(Get-ChildItem -LiteralPath $ArchiveDir -Filter 'triage-queue*.json' -File -ErrorAction Stop | Sort-Object Name) } catch { return ,$out.ToArray() }
  foreach ($f in $files) {
    try {
      $j = Read-JsonFile $f.FullName
      if ($null -eq $j -or -not $j.PSObject.Properties['items']) { continue }
      foreach ($it in @($j.items)) { if ($it) { [void]$out.Add($it) } }
    } catch { continue }
  }
  return ,$out.ToArray()
}
function Join-TriageQueueWithArchive {
  <# .SYNOPSIS Pure. The queue's items plus every archived item whose id the queue does not hold (the queue wins a tie). #>
  param($QueueItems, $ArchivedItems)
  $out = New-Object System.Collections.Generic.List[object]
  $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  foreach ($i in @($QueueItems)) { if (-not $i) { continue }; [void]$out.Add($i); [void]$seen.Add([string]$i.id) }
  foreach ($a in @($ArchivedItems)) {
    if (-not $a) { continue }
    $aid = [string]$a.id
    if (-not $aid -or $seen.Contains($aid)) { continue }
    [void]$seen.Add($aid); [void]$out.Add($a)
  }
  return ,$out.ToArray()
}

# --- THE SCOREBOARD'S RETURN RULE, ONE COPY (2026-09-22, plan-2026-09-22-10 item discovered:class-keyed-return-rate) ---
# audit-alert-census.ps1 scored returns with its own closedBefore loop over the queue alone while this lib, read by
# triage-due and the gate, already unioned the archive (F1 in design/RCA-holistic-2026-09-22.md: two copies of one rule
# that disagreed). The census now calls this for BOTH of its numbers: the legacy returnrate30 (KeyOf = the queue type,
# WindowDays 0, the queue alone, exactly the loop it replaced) and the class rate (KeyOf = Get-AlertClassKey, the 30-day
# window, queue UNIONED with the archive through Join-TriageQueueWithArchive).
function Test-TriageCreatedItem {
  <# Pure. Triage's own work item, which can never return: -Lane weekly, or a type whose class is a triage residual or
     finding entry. Counted on its own line, never in the rate's numerator or denominator. #>
  param($Item, [string]$ClassKey = '')
  if (-not $Item) { return $false }
  if ($Item.PSObject.Properties['lane'] -and [string]$Item.lane -eq 'weekly') { return $true }
  return ($ClassKey -ceq 'class:triage-residual' -or $ClassKey -ceq 'class:triage-finding')
}
function Get-ClassReturnRows {
  <# Pure. Items -> one row per (date, key): alerts (new ids plus recurrences dated that day), new_ids, recurrences,
     closes and dispositions (dated on the close), returns, and the first subject seen. KeyOf maps an item to its key.
     A new id is a RETURN when an EARLIER item of its key (ordered by ts) was closed as resolved; with WindowDays above
     0 that earlier item's ts must also lie within WindowDays before its own (the queue's retention, as
     Get-TriageReturnPriors reads it). WindowDays 0 is the census's original rule, kept for returnrate30. Never throws
     on a bad row: an item with no key, type or date is skipped. #>
  param($Items, [scriptblock]$KeyOf, [int]$WindowDays = 0, [string]$KeyName = 'type')
  $rows = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
  $get = {
    param($d, $k, $s)
    $rk = $d + '|' + $k
    if (-not $rows.ContainsKey($rk)) {
      $h = [ordered]@{ date = $d }; $h[$KeyName] = $k
      $h['subject'] = $s; $h['alerts'] = 0; $h['new_ids'] = 0; $h['recurrences'] = 0; $h['closes'] = 0; $h['dispositions'] = @{}; $h['returns'] = 0
      $rows[$rk] = [pscustomobject]$h
    }
    $rows[$rk]
  }
  $groups = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
  foreach ($i in @($Items)) {
    if (-not $i -or -not [string]$i.type -or -not [string]$i.date) { continue }
    $k = ''
    try { $k = [string](& $KeyOf $i) } catch { $k = '' }
    if (-not $k) { continue }
    if (-not $groups.ContainsKey($k)) { $groups[$k] = New-Object System.Collections.Generic.List[object] }
    [void]$groups[$k].Add($i)
  }
  foreach ($k in $groups.Keys) {
    $closedBefore = $false
    $closedTs = New-Object System.Collections.Generic.List[datetime]
    foreach ($i in @($groups[$k].ToArray() | Sort-Object { [string]$_.ts })) {
      $s = [string]$i.subject
      $r = & $get ([string]$i.date) $k $s
      $r.alerts++; $r.new_ids++
      if ($WindowDays -le 0) { if ($closedBefore) { $r.returns++ } }
      else {
        $its = $null
        try { $its = [datetime]::Parse([string]$i.ts, [Globalization.CultureInfo]::InvariantCulture) } catch { $its = $null }
        if ($null -ne $its) {
          $cut = $its.AddDays(-$WindowDays)
          foreach ($c in $closedTs) { if ($c -ge $cut) { $r.returns++; break } }
        }
      }
      foreach ($rec in @($i.recurrences)) {
        if (-not $rec -or -not [string]$rec.date) { continue }
        $rr = & $get ([string]$rec.date) $k $s
        $rr.alerts++; $rr.recurrences++
      }
      if ([string]$i.status -eq 'resolved') {
        $closedBefore = $true
        try { [void]$closedTs.Add([datetime]::Parse([string]$i.ts, [Globalization.CultureInfo]::InvariantCulture)) } catch { }
        $cd = ''
        try { if ([string]$i.resolved_ts) { $cd = ([datetime][string]$i.resolved_ts).ToString('yyyy-MM-dd') } } catch { $cd = '' }
        if ($cd) {
          $cr = & $get $cd $k $s
          $cr.closes++
          $disp = if ($i.PSObject.Properties['disposition'] -and [string]$i.disposition) { [string]$i.disposition } else { 'undispositioned' }
          if ($cr.dispositions.ContainsKey($disp)) { $cr.dispositions[$disp]++ } else { $cr.dispositions[$disp] = 1 }
        }
      }
    }
  }
  return ,@($rows.Values)
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
  $r = [pscustomobject]@{ found = $false; prior_id = ''; plan = ''; lane = ''; status = ''; why = ''; item = $null }
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
        $r.item = $it
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
  # THE QUEUE OWNS A RESIDUAL ONCE (2026-09-22, discovered:resume-double-count-2026-09-22; F1). A plan item that
  # closed deviated or needs-more-time AND named its leftover's owner in leaves_open_followup, when that owner is
  # a queue item still OPEN (or parked needs-brad), is already listed as that owner's own work. It is returned
  # with owned_by set, printed as RESUMED-BY, and never counted as RESUME work. An owner that is CLOSED, absent or
  # not a queue id leaves the item RESUME: the owner finished and the class did not.
  $liveOwners = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  foreach ($i in @($Items)) {
    if (-not $i) { continue }
    $st0 = ''
    try { $st0 = ([string]$i.status).Trim().ToLowerInvariant() } catch { $st0 = '' }
    if ($st0 -eq 'open' -or $st0 -eq 'needs-brad') { [void]$liveOwners.Add(([string]$i.id).Trim()) }
  }
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
    # DEVIATED CARRIES TWO MEANINGS, AND THE ITEM'S OWN RESIDUAL FIELDS SAY WHICH (2026-09-25, queue 2026-09-25-d76f72).
    # Developers write `deviated` for "shipped, but not as planned" (a false premise, more files than planned) as well as
    # for "the root fix did not fully land". Measured that day: 3 of 8 RESUME lines were deviated items whose fix
    # shipped with leaves_open "nothing" at 0 occurrences, each costing the next run a lane spawn to re-measure
    # finished work. So a deviated item whose leaves_open reads "nothing" and whose leaves_open_occurrences is absent or
    # 0 finished. needs-more-time never finished whatever it says, and a deviated item with any other leaves_open (a
    # watch: owner, a prose residual) stays RESUME exactly as before (the d24000 case).
    if ($ps -eq 'deviated' -and $route.item) {
      $lo = ''; $loN = $null
      try { if ($route.item.PSObject.Properties['leaves_open']) { $lo = ([string]$route.item.leaves_open).Trim() } } catch { $lo = '' }
      try { if ($route.item.PSObject.Properties['leaves_open_occurrences']) { $loN = $route.item.leaves_open_occurrences } } catch { $loN = $null }
      $loZero = ($null -eq $loN) -or ([string]$loN -match '^\s*0\s*$')
      if ($lo -match '^(?i)nothing\b' -and $loZero) { continue }
    }
    $subj = ''
    try { if ($i.PSObject.Properties['subject']) { $subj = ([string]$i.subject).Trim() } } catch { $subj = '' }
    $owners = New-Object System.Collections.Generic.List[string]
    $fu = ''
    try { if ($route.item -and $route.item.PSObject.Properties['leaves_open_followup']) { $fu = [string]$route.item.leaves_open_followup } } catch { $fu = '' }
    foreach ($m in [regex]::Matches($fu, '\d{4}-\d{2}-\d{2}-[0-9a-f]{6}')) {
      if ($m.Value -ne $id -and $liveOwners.Contains($m.Value) -and -not $owners.Contains($m.Value)) { [void]$owners.Add($m.Value) }
    }
    [void]$out.Add([pscustomobject]@{
      id = $id; subject = $subj; plan = [string]$route.plan
      status = ([string]$route.status).Trim(); lane = [string]$route.lane; owned_by = ($owners -join ', ') })
  }
  return ,$out.ToArray()
}
function Get-TriageResumeDue {
  <# .SYNOPSIS Pure. The unfinished records that are RESUME work: those whose leftover no open queue item owns. #>
  param($Unfinished)
  return ,@(@($Unfinished) | Where-Object { $_ -and -not ($_.PSObject.Properties['owned_by'] -and [string]$_.owned_by) })
}
function Format-TriageResumeLines {
  <# .SYNOPSIS Pure. The RESUME block triage-due.ps1 prints ABOVE its DUE list, or no lines at all. #>
  param($Unfinished)
  $lines = New-Object System.Collections.Generic.List[string]
  $all = @($Unfinished)
  $u = @($all | Where-Object { $_ -and -not ($_.PSObject.Properties['owned_by'] -and [string]$_.owned_by) })
  $owned = @($all | Where-Object { $_ -and $_.PSObject.Properties['owned_by'] -and [string]$_.owned_by })
  if ($owned.Count -gt 0) {
    [void]$lines.Add('NOTE  ' + $owned.Count + ' unfinished item(s) whose leftover already has its own open queue item - counted ONCE, under that owner, never as RESUME:')
    foreach ($r in $owned) {
      [void]$lines.Add('  RESUMED-BY ' + [string]$r.owned_by + ': ' + [string]$r.id + ' - ' + [string]$r.plan + ' closed it ' + [string]$r.status)
    }
  }
  if ($u.Count -eq 0) { return ,$lines.ToArray() }
  [void]$lines.Insert(0, 'DUE  RESUME ' + $u.Count + ' unfinished root fix(es). Each of these closed its queue item with the class' +
                   ' still open, so it is the next run''s FIRST work: resume from the named plan item, do not re-diagnose it.')
  $at = 1
  foreach ($r in $u) {
    $s = [string]$r.subject
    if ($s) { $s = ' - ' + $s }
    [void]$lines.Insert($at, '  RESUME: ' + [string]$r.id + ' - ' + [string]$r.plan + ' closed it ' + [string]$r.status +
                     ', lane ' + [string]$r.lane + $s)
    $at++
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
