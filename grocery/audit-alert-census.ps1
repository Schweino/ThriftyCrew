<#
  audit-alert-census.ps1 - the scoreboard for design\PLAN-zero-alert-days-2026-09-10.md.

  WHAT IT ANSWERS: how many days had no alerts, how many alerts a day, which alert types keep coming back,
  and how often a type came back after triage had already closed it. Brad's targets (2026-09-10, ruling 4):
  3 alert-free days a week by 2026-10-08, 5 by 2026-11-05, and zero returns within 30 days for a class that
  shipped a prevention fix.

  WHY IT KEEPS A FILE: send-alert.ps1 keeps only 30 days of resolved queue history, so any trend older than
  that disappears. Every run merges one row per day per alert type into out\alert-census.jsonl. Inside the
  queue's 30-day window the queue's measurement replaces the stored row; older rows are kept as written, so
  the history outlives the queue.

  THE MEASUREMENT (the same one the plan's baseline used): an "alert" on a day is a new queue id minted that
  day or a recurrence absorbed into an open id that day. Same-day increments of one id are not dated in the
  queue, so they are not counted per day. A "return" is a new id for a type that already has an earlier id
  closed as resolved.

  SCOPE OF A CLEAN REPORT: a MEASUREMENT, not a detector. It counts what reached triage-queue.json. An alert
  that never queued (a spool file, a crashed emitter, a check that stopped running) is invisible here, so a
  quiet day means "nothing queued", never "nothing was wrong". The heartbeat and spool checks own those.

  EXIT: 0 = measured (a bad week is the content, not a failure). 3 = could not evaluate (no queue, or a queue
  that reads back empty or without an items array).
  Self-test: powershell -File grocery\audit-alert-census.ps1 -SelfTest
#>
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop
param([switch]$SelfTest, [string]$QueueFile = '', [string]$OutFile = '', [string]$Today = '')
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path $root -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\json-io.ps1')
. (Join-Path $root 'triage-return-lib.ps1')   # Get-AlertCensusTypeDays: the one copy of days fired per type (ruling 6)

# Ruling 4, 2026-09-10. Dates and counts are Brad's; kept here once so the report and the plan cannot disagree.
$script:Targets = @(
  [pscustomobject]@{ by = '2026-10-08'; quiet_per_week = 3 },
  [pscustomobject]@{ by = '2026-11-05'; quiet_per_week = 5 }
)
$script:QueueWindowDays = 30   # send-alert.ps1 drops resolved items older than 30 days

function Get-CensusRows {
  <# .SYNOPSIS Pure. Queue items -> one row per (date, type). #>
  param($Items)
  $rows = @{}
  $get = {
    param($d, $t, $s)
    $k = $d + '|' + $t
    if (-not $rows.ContainsKey($k)) {
      $rows[$k] = [pscustomobject]@{ date = $d; type = $t; subject = $s; alerts = 0; new_ids = 0; recurrences = 0; closes = 0; dispositions = @{}; returns = 0 }
    }
    $rows[$k]
  }
  $list = @($Items | Where-Object { $_ -and [string]$_.type -and [string]$_.date })
  foreach ($grp in ($list | Group-Object { [string]$_.type })) {
    $closedBefore = $false
    foreach ($i in @($grp.Group | Sort-Object { [string]$_.ts })) {
      $t = [string]$i.type; $s = [string]$i.subject
      $r = & $get ([string]$i.date) $t $s
      $r.alerts++; $r.new_ids++
      if ($closedBefore) { $r.returns++ }
      foreach ($rec in @($i.recurrences)) {
        if (-not $rec -or -not [string]$rec.date) { continue }
        $rr = & $get ([string]$rec.date) $t $s
        $rr.alerts++; $rr.recurrences++
      }
      if ([string]$i.status -eq 'resolved') {
        $closedBefore = $true
        $cd = ''
        try { if ([string]$i.resolved_ts) { $cd = ([datetime][string]$i.resolved_ts).ToString('yyyy-MM-dd') } } catch { $cd = '' }
        if ($cd) {
          $cr = & $get $cd $t $s
          $cr.closes++
          $disp = if ($i.PSObject.Properties['disposition'] -and [string]$i.disposition) { [string]$i.disposition } else { 'undispositioned' }
          if ($cr.dispositions.ContainsKey($disp)) { $cr.dispositions[$disp]++ } else { $cr.dispositions[$disp] = 1 }
        }
      }
    }
  }
  return @($rows.Values)
}

function Merge-CensusRows {
  <# .SYNOPSIS Pure. Rows on or after $Cutoff come from the queue; older rows keep the stored version when one exists. #>
  param($Existing, $Fresh, [string]$Cutoff)
  $out = @{}
  foreach ($e in @($Existing)) { if ($e -and [string]$e.date -lt $Cutoff) { $out[[string]$e.date + '|' + [string]$e.type] = $e } }
  foreach ($f in @($Fresh)) {
    if (-not $f) { continue }
    $k = [string]$f.date + '|' + [string]$f.type
    if ([string]$f.date -ge $Cutoff -or -not $out.ContainsKey($k)) { $out[$k] = $f }
  }
  return @($out.Values | Sort-Object { [string]$_.date }, { [string]$_.type })
}

function Get-CensusSummary {
  <# .SYNOPSIS Pure. Merged rows + today -> the numbers the report prints, each with its denominator. #>
  param($Rows, [datetime]$Today)
  $rowsA = @($Rows | Where-Object { $_ })
  $byDay = @{}
  foreach ($r in $rowsA) { $d = [string]$r.date; if (-not $byDay.ContainsKey($d)) { $byDay[$d] = 0 }; $byDay[$d] += [int]$r.alerts }
  $first = if ($rowsA.Count) { [datetime](@($rowsA | ForEach-Object { [string]$_.date } | Sort-Object)[0]) } else { $Today }
  $win = {
    param([int]$n)
    $start = $Today.AddDays(-($n - 1)); if ($start -lt $first) { $start = $first }
    $days = 0; $quiet = 0; $alerts = 0
    for ($d = $start; $d -le $Today; $d = $d.AddDays(1)) {
      $k = $d.ToString('yyyy-MM-dd'); $days++
      $a = 0; if ($byDay.ContainsKey($k)) { $a = $byDay[$k] }
      $alerts += $a; if ($a -eq 0) { $quiet++ }
    }
    [pscustomobject]@{ days = $days; quiet = $quiet; alerts = $alerts; start = $start.ToString('yyyy-MM-dd') }
  }
  $w7 = & $win 7
  $w30 = & $win 30
  $in30 = @($rowsA | Where-Object { [string]$_.date -ge $w30.start })
  # ONE copy of days fired per type (triage-return-lib.ps1), shared with validate-triage-plan.ps1's weekly
  # prevention_target (ruling 6, 2026-09-10), so the scoreboard and the gate cannot count a day differently. The window
  # is the 30 days ending today; no row predates $first, so $w30's clamp to it changes nothing here.
  $typesR = Get-AlertCensusTypeDays $rowsA $Today 30
  $typesA = @($typesR)
  $disp = @{}
  foreach ($r in $in30) {
    if (-not $r.dispositions) { continue }
    foreach ($p in $r.dispositions.PSObject.Properties) { if ($p.MemberType -ne 'NoteProperty') { continue }; if ($disp.ContainsKey($p.Name)) { $disp[$p.Name] += [int]$p.Value } else { $disp[$p.Name] = [int]$p.Value } }
    if ($r.dispositions -is [hashtable]) { foreach ($k in $r.dispositions.Keys) { if ($disp.ContainsKey($k)) { $disp[$k] += [int]$r.dispositions[$k] } else { $disp[$k] = [int]$r.dispositions[$k] } } }
  }
  return [pscustomobject]@{
    First = $first.ToString('yyyy-MM-dd'); W7 = $w7; W30 = $w30
    Types = $typesA
    Recurring = @($typesA | Where-Object { $_.days -ge 3 } | Sort-Object days -Descending)
    Returns = [int](($typesA | Measure-Object -Property returns -Sum).Sum)
    ReturnTypes = @($typesA | Where-Object { $_.returns -gt 0 }).Count
    Dispositions = $disp
  }
}

if ($SelfTest) {
  $fail = 0; $ran = 0
  function _T([string]$label, [bool]$cond, [string]$detail) {
    $script:ran++
    if ($cond) { Write-Output "ok    $label" } else { Write-Output "FAIL  $label  - $detail"; $script:fail++ }
  }
  $fx = @(
    [pscustomobject]@{ id = 'x-a1'; type = 'a'; subject = 'Alert A'; date = '2026-09-01'; ts = '2026-09-01T08:00:00'; status = 'resolved'; resolved_ts = '2026-09-01T10:00:00'; disposition = 'confirmed'; count = 1 },
    [pscustomobject]@{ id = 'x-b1'; type = 'b'; subject = 'Alert B'; date = '2026-09-01'; ts = '2026-09-01T09:00:00'; status = 'open'; count = 2; recurrences = @([pscustomobject]@{ date = '2026-09-03'; subject = 'Alert B' }) },
    [pscustomobject]@{ id = 'x-a2'; type = 'a'; subject = 'Alert A'; date = '2026-09-03'; ts = '2026-09-03T08:00:00'; status = 'open'; count = 1 }
  )
  $rows = @(Get-CensusRows $fx)
  $a3 = @($rows | Where-Object { $_.date -eq '2026-09-03' -and $_.type -eq 'a' })
  $b3 = @($rows | Where-Object { $_.date -eq '2026-09-03' -and $_.type -eq 'b' })
  # MUST FIRE: the founding measurement. A type triage closed, raised again, is a return.
  _T 'MUST-FIRE a new id for a type with an earlier closed id counts as a return' ($a3.Count -eq 1 -and [int]$a3[0].returns -eq 1) ("rows=" + $a3.Count)
  # MUST NOT FIRE: a recurrence absorbed into an id nobody closed is not a return, but it is an alert that day.
  _T 'MUST-NOT-FIRE a recurrence of a never-closed id is an alert but not a return' ($b3.Count -eq 1 -and [int]$b3[0].returns -eq 0 -and [int]$b3[0].alerts -eq 1) ("rows=" + $b3.Count)
  $sum = Get-CensusSummary $rows ([datetime]'2026-09-03')
  # MUST FIRE: a day with nothing queued is a quiet day, counted against the days that have data.
  _T 'MUST-FIRE 2026-09-02 counts as the one quiet day of 3' ($sum.W7.quiet -eq 1 -and $sum.W7.days -eq 3 -and $sum.W7.alerts -eq 4) ("quiet=" + $sum.W7.quiet + " days=" + $sum.W7.days + " alerts=" + $sum.W7.alerts)
  _T 'the close is dated on its resolved day with its disposition' ([int]$sum.Dispositions['confirmed'] -eq 1) ("disp=" + ($sum.Dispositions.Keys -join ','))
  # MERGE: a stored row inside the queue window is replaced; a row older than the window survives the queue's purge.
  $stored = @(
    [pscustomobject]@{ date = '2026-07-01'; type = 'z'; subject = 'Old'; alerts = 3; new_ids = 3; recurrences = 0; closes = 0; dispositions = @{}; returns = 0 },
    [pscustomobject]@{ date = '2026-09-01'; type = 'a'; subject = 'Alert A'; alerts = 9; new_ids = 9; recurrences = 0; closes = 0; dispositions = @{}; returns = 0 }
  )
  $merged = @(Merge-CensusRows $stored $rows '2026-08-05')
  $keptOld = @($merged | Where-Object { $_.date -eq '2026-07-01' -and $_.type -eq 'z' })
  $a1 = @($merged | Where-Object { $_.date -eq '2026-09-01' -and $_.type -eq 'a' })
  # CLEAN TWIN: history older than the queue's 30 days is still there after a merge.
  _T 'CLEAN TWIN a stored row older than the queue window survives the merge' ($keptOld.Count -eq 1 -and [int]$keptOld[0].alerts -eq 3) ("kept=" + $keptOld.Count)
  # MUST FIRE: inside the window the queue is the truth, so a stale stored count is replaced.
  _T 'MUST-FIRE a stored row inside the window is replaced by the queue measurement' ($a1.Count -eq 1 -and [int]$a1[0].alerts -eq 1) ("alerts=" + $(if ($a1.Count) { $a1[0].alerts } else { 'none' }))
  Write-Output ''
  if ($fail -gt 0) { Write-Output "SELF-TEST FAIL: $fail of $ran case(s)"; exit 1 }
  Write-Output "SELF-TEST PASS ($ran alert-census cases)"
  exit 0
}

if (-not $QueueFile) { $QueueFile = Join-Path $root 'triage-queue.json' }
if (-not $OutFile) { $OutFile = Join-Path $root 'out\alert-census.jsonl' }
$now = if ($Today) { [datetime]$Today } else { (Get-Date).Date }
if (-not (Test-Path -LiteralPath $QueueFile)) { Write-Output ("alert-census: BLIND - no queue at " + $QueueFile); Exit-Guard -Name 'ALERT-CENSUS' -Code 3 -Summary 'blind=no-queue' }
$q = $null
try { $q = Read-JsonFile $QueueFile } catch { $q = $null }
if (-not $q -or -not $q.PSObject.Properties['items']) { Write-Output 'alert-census: BLIND - the queue reads back empty, unparseable or with no items array'; Exit-Guard -Name 'ALERT-CENSUS' -Code 3 -Summary 'blind=unreadable-queue' }
$items = @($q.items)

$fresh = @(Get-CensusRows $items)
$existing = @()
if (Test-Path -LiteralPath $OutFile) {
  foreach ($line in [IO.File]::ReadAllLines($OutFile)) { if ($line.Trim()) { try { $existing += ($line | ConvertFrom-Json) } catch { } } }
}
$cutoff = $now.AddDays(-($script:QueueWindowDays - 1)).ToString('yyyy-MM-dd')
$merged = @(Merge-CensusRows $existing $fresh $cutoff)
$outDir = Split-Path -Parent $OutFile
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
$json = @($merged | ForEach-Object { $_ | ConvertTo-Json -Depth 4 -Compress })
[IO.File]::WriteAllText($OutFile, (($json -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))

$s = Get-CensusSummary $merged $now
Write-Output ("alert-census: read " + $items.Count + " queue item(s); history " + $s.First + " to " + $now.ToString('yyyy-MM-dd') + "; " + $merged.Count + " day/type row(s) in " + $OutFile)
Write-Output ("  QUIET DAYS   last 7: {0} of {1}   last 30: {2} of {3} (days with data)" -f $s.W7.quiet, $s.W7.days, $s.W30.quiet, $s.W30.days)
Write-Output ("  ALERTS       last 7: {0} ({1:N1} a day)   last 30: {2} ({3:N1} a day)" -f $s.W7.alerts, ($s.W7.alerts / [Math]::Max(1, $s.W7.days)), $s.W30.alerts, ($s.W30.alerts / [Math]::Max(1, $s.W30.days)))
foreach ($t in $script:Targets) {
  $state = if ($s.W7.days -lt 7) { 'NOT YET MEASURABLE (fewer than 7 days of data)' } elseif ($s.W7.quiet -ge $t.quiet_per_week) { 'MET' } else { 'NOT MET' }
  Write-Output ("  TARGET       {0} quiet day(s) a week by {1}: last 7 days had {2} of {3} - {4}" -f $t.quiet_per_week, $t.by, $s.W7.quiet, $s.W7.days, $state)
}
Write-Output ("  RETURNS      last 30: {0} alert(s) were a type triage had already closed, across {1} of {2} type(s). Per-prevention tracking arrives with ruling 5." -f $s.Returns, $s.ReturnTypes, $s.Types.Count)
Write-Output ("  RECURRING    {0} of {1} type(s) raised on 3 or more of the last {2} day(s). Top 10 by days:" -f $s.Recurring.Count, $s.Types.Count, $s.W30.days)
foreach ($t in @($s.Recurring | Select-Object -First 10)) {
  $sub = $t.subject; if ($sub.Length -gt 80) { $sub = $sub.Substring(0, 80) }
  Write-Output ("    days={0,-3} alerts={1,-3} returns={2,-3} {3}" -f $t.days, $t.alerts, $t.returns, $sub)
}
$dTxt = (@($s.Dispositions.Keys | Sort-Object | ForEach-Object { $_ + '=' + $s.Dispositions[$_] })) -join ' '
Write-Output ("  CLOSES       last 30 by disposition: " + $(if ($dTxt) { $dTxt } else { 'none dated' }))
Exit-Guard -Name 'ALERT-CENSUS' -Code 0 -Summary ("quiet7={0}/{1} quiet30={2}/{3} alerts30={4} returns30={5} recurring={6}" -f $s.W7.quiet, $s.W7.days, $s.W30.quiet, $s.W30.days, $s.W30.alerts, $s.Returns, $s.Recurring.Count)
