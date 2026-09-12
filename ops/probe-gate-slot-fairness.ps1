# probe-gate-slot-fairness.ps1
# ---------------------------------------------------------------------------------------------------
# DOES THE MACHINE-WIDE GATE BUDGET SERVE ITS WAITERS IN ARRIVAL ORDER? One row per arrival, and every
# total below is derived from those rows (measurement.md, backlog E24: a pair of totals cannot be
# un-aggregated, so the paired comparison that would have been free is gone forever).
#
# WHY IT IS COMMITTED. `lib\gate-slots.ps1` grew its queue on 2026-09-11 and
# `design\MEASURE-gate-slot-starvation-2026-09-11.md` records the BEFORE at 8 waiters - through scratch
# probes that were never committed, so re-running that number costs re-writing the probe. This is that
# probe, kept, so the claim "arrival order holds" can be re-measured against a moved tree rather than
# quoted. It is the harness `measurement.md` asks a recorded measurement to NAME.
#
# IT IS A REPORT, NOT A GATE. Exit 0 unless -Strict, which fails the bars below. It is not wired into
# run-gates: it spends about a minute and 20 processes, and a gate that costs that on every push would
# be bypassed. Its -SelfTest is hermetic and spawns nothing - it drives the SCORER over frozen rows,
# because a scorer that cannot see an out-of-order service would report a clean queue over any data at
# all, which is this file's own version of the agreeing zero.
#
# IT TAKES NO REAL SLOT. -Prefix defaults to a per-run private `Local\` name and the queue root to a
# per-run temp directory, so a probe cannot starve the box it is measuring, and two probes at once
# cannot collide (ops\audit-fixed-temp-names.ps1).
#
# ARRIVAL ORDER IS RECORDED, NEVER ASSUMED. powershell.exe takes about a second to start, which is
# further than a 250 ms stagger closes, so launch order is not arrival order (lib\ledger-fixture.ps1
# carries the same lesson for barriers). Every child signals ready, the parent then publishes one
# absolute release clock, and each child waits until its own slot on it and stamps the tick it actually
# called Enter-TcGateSlots. Order comes from that stamp. A child whose stamp lands out of its intended
# place is NAMED in the report, never quietly sorted away.
#
# WHAT THE NUMBERS MEAN, all with denominators:
#   inversions  - pairs served out of arrival order, out of C(N,2). A uniformly random order averages
#                 half of them, which is what the pre-queue code measured at 8 waiters.
#   passed-by   - per arrival, how many LATER arrivals were served first. STARVATION IS A LARGE MAX
#                 HERE, not a large mean: one run passed nineteen times is the production failure, and
#                 a mean can hide it.
#   peak        - the most slots held at once, from the rows' grant and release stamps. The budget is
#                 the one property that may never be traded for fairness.
#
# SCOPE OF A CLEAN REPORT: UNSOUND. It proves that THIS shape - N arrivals staggered evenly, each
# wanting the same few slots for the same fixed work - is served in order on this box. It says nothing
# about a real queue's drain rate, nothing about mixed appetites, and nothing about a waiter that is
# alive but frozen, which `lib\gate-slots.ps1` documents as not handled.
#
# Usage:
#   powershell -NoProfile -File ops\probe-gate-slot-fairness.ps1                    # 20 arrivals
#   powershell -NoProfile -File ops\probe-gate-slot-fairness.ps1 -Lib <path>        # a mutant mirror
#   powershell -NoProfile -File ops\probe-gate-slot-fairness.ps1 -SelfTest
[CmdletBinding()]
param(
  [int]$Arrivals = 20,
  [int]$Want = 3,
  [int]$Total = 4,
  [int]$WorkMs = 1500,
  [int]$StaggerMs = 250,
  [int]$PollMs = 200,
  [int]$WaitSec = 90,
  [string]$Lib = '',
  [string]$Label = 'after',
  [string]$OutJson = '',
  [switch]$Lone,
  [switch]$Strict,
  [switch]$SelfTest,
  # -Child and the four that follow are the worker side of this same file. Not for a caller.
  [switch]$Child,
  [int]$Index = 0,
  [string]$Rendezvous = '',
  [string]$Prefix = '',
  [string]$QueueRoot = ''
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent $here

# ---------------------------------------------------------------------------------------------------
# THE SCORER. Pure, over rows, so the self-test can drive it with no processes at all.
# ---------------------------------------------------------------------------------------------------

function Get-TcProbeOrdering {
  <# Rows in, verdict out. Arrival order is the ORDER OF THE RECORDED STAMPS, and service order the
     order of the grant stamps; a row that never got a slot is served by nobody and is counted as a
     timeout instead. Inversions and passed-by are counted over the GRANTED rows only, because a row
     that timed out was never served and pairing it with one that was would score a refusal as an
     out-of-order service - two different failures, and the bars name them separately. #>
  param([object[]]$Rows)
  $all = @($Rows)
  $byArrival = @($all | Sort-Object -Property ArrivalTicks)
  $granted = @($byArrival | Where-Object { $_.Count -gt 0 })
  $n = $granted.Count
  $inversions = 0
  $passedBy = @()
  for ($i = 0; $i -lt $n; $i++) {
    $mine = 0
    for ($j = $i + 1; $j -lt $n; $j++) {
      if ([int64]$granted[$j].GrantTicks -lt [int64]$granted[$i].GrantTicks) { $inversions++; $mine++ }
    }
    $passedBy += [pscustomobject]@{ Arrival = $i; PassedBy = $mine; WaitedMs = [double]$granted[$i].WaitedMs }
  }
  $pairs = if ($n -gt 1) { ($n * ($n - 1)) / 2 } else { 0 }
  $waits = @($granted | ForEach-Object { [double]$_.WaitedMs })
  $maxPassed = 0
  foreach ($p in $passedBy) { if ($p.PassedBy -gt $maxPassed) { $maxPassed = $p.PassedBy } }
  $firstIsFastest = $false
  if ($waits.Count -gt 0) {
    $min = ($waits | Measure-Object -Minimum).Minimum
    $firstIsFastest = ([double]$waits[0] -le [double]$min)
  }
  return [pscustomobject]@{
    Arrivals       = $all.Count
    Granted        = $n
    TimedOut       = @($all | Where-Object { $_.Count -le 0 }).Count
    Inversions     = $inversions
    Pairs          = $pairs
    MaxPassedBy    = $maxPassed
    PassedBy       = $passedBy
    Waits          = $waits
    FirstIsFastest = $firstIsFastest
    Peak           = (Get-TcProbePeak -Rows $granted)
  }
}

function Get-TcProbePeak {
  <# The most slots held at once, swept over the rows' own grant and release stamps. A release that
     never happened (a killed child) is treated as held to the end of the run, which can only make the
     peak larger: a budget check must never be flattered by a missing stamp. #>
  param([object[]]$Rows)
  $rows = @($Rows)
  if ($rows.Count -eq 0) { return 0 }
  $endOfRun = 0L
  foreach ($r in $rows) {
    foreach ($t in @([int64]$r.GrantTicks, [int64]$r.ReleaseTicks)) { if ($t -gt $endOfRun) { $endOfRun = $t } }
  }
  $events = @()
  foreach ($r in $rows) {
    $rel = [int64]$r.ReleaseTicks
    if ($rel -le 0) { $rel = $endOfRun + 1 }
    $events += [pscustomobject]@{ At = [int64]$r.GrantTicks; Delta = [int]$r.Count }
    $events += [pscustomobject]@{ At = $rel; Delta = -([int]$r.Count) }
  }
  # A release at the same tick as a grant is counted as the RELEASE first only when it really precedes
  # it; ties sort the negative delta last, so a tie reads as an overlap. Over-counting is the safe way
  # for a budget check to be wrong.
  $ordered = @($events | Sort-Object -Property @{ Expression = 'At' }, @{ Expression = 'Delta'; Descending = $true })
  $cur = 0; $peak = 0
  foreach ($e in $ordered) {
    $cur += [int]$e.Delta
    if ($cur -gt $peak) { $peak = $cur }
  }
  return $peak
}

function Write-TcProbeReport {
  param([object]$Score, [string]$Label, [int]$Total, [int]$Concurrent)
  Write-Host ''
  Write-Host ("ARM {0}   (machine had {1} run-gates live at the start of this arm)" -f $Label, $Concurrent)
  Write-Host ("  served in arrival order : {0} of {1} pairs INVERTED   (a random order averages {2})" -f `
      $Score.Inversions, $Score.Pairs, [math]::Round($Score.Pairs / 2.0, 1))
  Write-Host ("  worst starvation        : one arrival passed by {0} of {1} later arrivals" -f `
      $Score.MaxPassedBy, ([math]::Max(0, $Score.Granted - 1)))
  Write-Host ("  refused (no slot)       : {0} of {1} arrivals" -f $Score.TimedOut, $Score.Arrivals)
  Write-Host ("  peak slots held at once : {0} of a budget of {1}" -f $Score.Peak, $Total)
  if ($Score.Waits.Count -gt 0) {
    $st = $Score.Waits | Measure-Object -Minimum -Maximum -Average
    Write-Host ("  wait to first slot      : min {0} ms, median {1} ms, max {2} ms, over {3} granted arrivals" -f `
        [int]$st.Minimum, [int](Get-TcProbeMedian -Values $Score.Waits), [int]$st.Maximum, $Score.Granted)
    Write-Host ("  first arrival waited least : {0}" -f $(if ($Score.FirstIsFastest) { 'yes' } else { 'NO' }))
  }
  Write-Host '  per arrival (arrival index, wait ms, slots, passed by later arrivals):'
  foreach ($p in $Score.PassedBy) {
    Write-Host ("    {0,3}  {1,8} ms  passed-by {2}" -f $p.Arrival, [int]$p.WaitedMs, $p.PassedBy)
  }
}

function Get-TcProbeMedian {
  param([double[]]$Values)
  $v = @($Values | Sort-Object)
  if ($v.Count -eq 0) { return 0 }
  $mid = [int][math]::Floor($v.Count / 2)
  if ($v.Count % 2 -eq 1) { return $v[$mid] }
  return (($v[$mid - 1] + $v[$mid]) / 2.0)
}

function Get-TcProbeRunGatesCount {
  <# How busy the box is, recorded with every arm so a slow arm can be read against its own conditions
     rather than blamed on the code (measurement.md: name what differed between the arms). #>
  try {
    $procs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop |
        Where-Object { $_.CommandLine -and $_.CommandLine -match 'run-gates' })
    return $procs.Count
  } catch { return -1 }
}

# ---------------------------------------------------------------------------------------------------
# THE CHILD. One arrival. Everything it learns goes in one row.
# ---------------------------------------------------------------------------------------------------

if ($Child) {
  $row = [ordered]@{
    Index = $Index; ArrivalTicks = 0L; GrantTicks = 0L; ReleaseTicks = 0L
    Count = 0; WaitedMs = 0.0; TimedOut = $true; Error = ''
  }
  $rowPath = Join-Path $Rendezvous ('row-{0:D3}.json' -f $Index)
  try {
    . $Lib
    [IO.File]::WriteAllText((Join-Path $Rendezvous ('ready-{0:D3}.txt' -f $Index)), [string]$PID)
    # THE BARRIER IS INSIDE THE CHILD, immediately before the contended call. A release published by the
    # parent after every child is ready is the only thing that makes the stagger mean anything: start-up
    # is about a second, four times the stagger it would otherwise scramble.
    $goPath = Join-Path $Rendezvous 'go.txt'
    $deadline = [DateTime]::UtcNow.AddSeconds(300)
    $t0 = 0L
    while ($t0 -eq 0L) {
      if ([IO.File]::Exists($goPath)) {
        try { $t0 = [int64]([IO.File]::ReadAllText($goPath).Trim()) } catch { $t0 = 0L }
      }
      if ($t0 -eq 0L) {
        if ([DateTime]::UtcNow -gt $deadline) { throw 'probe child: the parent never published a release clock' }
        Start-Sleep -Milliseconds 20
      }
    }
    $mine = $t0 + ([int64]$Index * [int64]$StaggerMs * 10000L)
    while ([DateTime]::UtcNow.Ticks -lt $mine) {
      $left = ($mine - [DateTime]::UtcNow.Ticks) / 10000L
      if ($left -gt 30) { Start-Sleep -Milliseconds 10 }
    }
    $row.ArrivalTicks = [DateTime]::UtcNow.Ticks
    $lease = Enter-TcGateSlots -Want $Want -Total $Total -Prefix $Prefix -WaitSec $WaitSec -PollMs $PollMs -QueueRoot $QueueRoot
    $row.GrantTicks = [DateTime]::UtcNow.Ticks
    $row.Count = [int]$lease.Count
    $row.WaitedMs = [double]$lease.WaitedMs
    $row.TimedOut = [bool]$lease.TimedOut
    if ($lease.Count -gt 0) {
      Start-Sleep -Milliseconds $WorkMs
      Exit-TcGateSlots $lease
      $row.ReleaseTicks = [DateTime]::UtcNow.Ticks
    }
  } catch {
    $row.Error = [string]$_.Exception.Message
  }
  [IO.File]::WriteAllText($rowPath, (ConvertTo-Json ([pscustomobject]$row) -Depth 4))
  exit 0
}

# ---------------------------------------------------------------------------------------------------
# SELF-TEST. Hermetic: it spawns nothing and takes no mutex. It drives the scorer, which is the half a
# live run cannot check - a scorer that always answered zero would report a perfect queue over any data.
# ---------------------------------------------------------------------------------------------------

function New-TcProbeRow {
  param([int]$Index, [int64]$Arrival, [int64]$Grant, [int64]$Release, [int]$Count, [double]$Waited)
  return [pscustomobject]@{
    Index = $Index; ArrivalTicks = $Arrival; GrantTicks = $Grant; ReleaseTicks = $Release
    Count = $Count; WaitedMs = $Waited; TimedOut = ($Count -le 0); Error = ''
  }
}

if ($SelfTest) {
  $fail = 0
  $cases = 0
  function Assert-TcProbe {
    param([string]$Name, [bool]$Ok)
    $script:cases++
    if ($Ok) { Write-Host ("  ok   {0}" -f $Name) }
    else { $script:fail++; Write-Host ("  FAIL {0}" -f $Name) }
  }

  # MUST FIRE - the founding bug this file exists to see. Service in reverse of arrival is total
  # starvation of the first arrival, and the scorer must say so in BOTH of its words. A scorer that
  # could not see this would make every live report above meaningless.
  $rev = @()
  for ($i = 0; $i -lt 5; $i++) {
    # The wait is what the stamps say it is: served last-first, the FIRST arrival waits longest.
    $rev += New-TcProbeRow -Index $i -Arrival (1000L + $i) -Grant (9000L - $i) -Release (9500L - $i) -Count 1 -Waited (8000.0 - (2.0 * $i))
  }
  $s = Get-TcProbeOrdering -Rows $rev
  Assert-TcProbe 'MUST FIRE: a reverse-order service scores every pair inverted' ($s.Inversions -eq 10 -and $s.Pairs -eq 10)
  Assert-TcProbe 'MUST FIRE: the first arrival is passed by every later one' ($s.MaxPassedBy -eq 4)
  Assert-TcProbe 'MUST FIRE: the first arrival did not wait least' (-not $s.FirstIsFastest)

  # MUST NOT FIRE - a legal input. Arrival order served in arrival order is SILENT, or the probe cries
  # wolf and no fix could ever be shown to have worked.
  $fifo = @()
  for ($i = 0; $i -lt 5; $i++) {
    $fifo += New-TcProbeRow -Index $i -Arrival (1000L + $i) -Grant (2000L + ($i * 10)) -Release (2005L + ($i * 10)) -Count 1 -Waited (10.0 + $i)
  }
  $s2 = Get-TcProbeOrdering -Rows $fifo
  Assert-TcProbe 'MUST NOT FIRE: an in-order service scores no inversion' ($s2.Inversions -eq 0 -and $s2.MaxPassedBy -eq 0)
  Assert-TcProbe 'MUST NOT FIRE: the first arrival waited least' ($s2.FirstIsFastest)

  # The rows are sorted by the STAMP, never by the index they were launched with, because start-up
  # jitter reorders launches. A row set whose indices disagree with its stamps must score by the stamps.
  $shuffled = @(
    (New-TcProbeRow -Index 7 -Arrival 1000L -Grant 2000L -Release 2100L -Count 1 -Waited 5.0),
    (New-TcProbeRow -Index 0 -Arrival 1500L -Grant 2500L -Release 2600L -Count 1 -Waited 6.0)
  )
  $s3 = Get-TcProbeOrdering -Rows $shuffled
  # A POSITIVE assertion, per the three fixture labels: the row scored as arrival 0 is the one with the
  # EARLIEST STAMP (its wait is 5 ms), though it was launched as index 7. Asserting merely that nothing
  # was inverted would pass just as well on a scorer that had read the launch index and got lucky.
  Assert-TcProbe 'CLEAN TWIN: the row scored first is the one with the earliest stamp, not the lowest launch index' `
    ($s3.PassedBy[0].WaitedMs -eq 5.0 -and $s3.Granted -eq 2)

  # A refusal is not an out-of-order service. Counting it as one would report the 2026-09-11 production
  # failure - everybody refused - as a perfectly fair queue, or as chaos, depending on the tick it died.
  $withTimeout = @(
    (New-TcProbeRow -Index 0 -Arrival 1000L -Grant 0L -Release 0L -Count 0 -Waited 90000.0),
    (New-TcProbeRow -Index 1 -Arrival 1100L -Grant 2000L -Release 2100L -Count 1 -Waited 7.0)
  )
  $s4 = Get-TcProbeOrdering -Rows $withTimeout
  Assert-TcProbe 'a refused arrival counts as a refusal, not an inversion' ($s4.TimedOut -eq 1 -and $s4.Inversions -eq 0 -and $s4.Granted -eq 1)

  # THE BUDGET, which may never be traded for fairness. Three rows holding 2 slots each, only ever two
  # of them overlapping, peak at 4 and not at the sum of 6.
  $overlap = @(
    (New-TcProbeRow -Index 0 -Arrival 1000L -Grant 1000L -Release 3000L -Count 2 -Waited 0.0),
    (New-TcProbeRow -Index 1 -Arrival 1100L -Grant 2000L -Release 4000L -Count 2 -Waited 0.0),
    (New-TcProbeRow -Index 2 -Arrival 1200L -Grant 3500L -Release 5000L -Count 2 -Waited 0.0)
  )
  Assert-TcProbe 'the peak is the most slots held AT ONCE, not the sum' ((Get-TcProbePeak -Rows $overlap) -eq 4)

  # A release stamped at the same tick as another row's grant reads as an OVERLAP, deliberately. The two
  # stamps are taken in different processes after their calls returned, so an exact tie is not evidence
  # that the slot was free; a budget check that has to be wrong is wrong in the direction that says so.
  $tied = @(
    (New-TcProbeRow -Index 0 -Arrival 1000L -Grant 1000L -Release 3000L -Count 2 -Waited 0.0),
    (New-TcProbeRow -Index 1 -Arrival 1100L -Grant 2000L -Release 4000L -Count 2 -Waited 0.0),
    (New-TcProbeRow -Index 2 -Arrival 1200L -Grant 3000L -Release 5000L -Count 2 -Waited 0.0)
  )
  Assert-TcProbe 'a grant tied with a release counts as an overlap, never as a free slot' ((Get-TcProbePeak -Rows $tied) -eq 6)

  # A child killed mid-work leaves no release stamp. Treating that as "released instantly" would hide a
  # budget breach; it is held to the end of the run instead, which can only over-count.
  $noRelease = @(
    (New-TcProbeRow -Index 0 -Arrival 1000L -Grant 1000L -Release 0L -Count 3 -Waited 0.0),
    (New-TcProbeRow -Index 1 -Arrival 1100L -Grant 9000L -Release 9500L -Count 3 -Waited 0.0)
  )
  Assert-TcProbe 'a missing release stamp is held to the end of the run, never freed' ((Get-TcProbePeak -Rows $noRelease) -eq 6)

  Write-Host ''
  if ($fail -gt 0) {
    Write-Host ("probe-gate-slot-fairness self-test: FAIL - {0} of {1} cases" -f $fail, $cases)
    exit 1
  }
  Write-Host ("probe-gate-slot-fairness self-test: pass - {0} of {1} cases" -f $cases, $cases)
  exit 0
}

# ---------------------------------------------------------------------------------------------------
# THE LIVE RUN.
# ---------------------------------------------------------------------------------------------------

if (-not $Lib) { $Lib = Join-Path $repo 'lib\gate-slots.ps1' }
if (-not (Test-Path -LiteralPath $Lib)) { Write-Host ("probe: no such library: " + $Lib); exit 3 }

$runId = [guid]::NewGuid().ToString('N').Substring(0, 8)
$rv = Join-Path ([IO.Path]::GetTempPath()) ('tc-gsf-' + $runId)
$null = [IO.Directory]::CreateDirectory($rv)
$prefix = 'Local\tc-gsf-' + $runId + '-'
$queueRoot = Join-Path $rv 'q'
$concurrent = Get-TcProbeRunGatesCount

try {
  if ($Lone) {
    # MUST NOT FIRE for the whole change: with nobody else waiting, one run still gets the entire budget.
    . $Lib
    $lease = Enter-TcGateSlots -Want $Total -Total $Total -Prefix $prefix -WaitSec 30 -PollMs $PollMs -QueueRoot $queueRoot
    Write-Host ("LONE RUN: asked for {0}, got {1} of {2}, waited {3} ms" -f $Total, $lease.Count, $Total, [int]$lease.WaitedMs)
    $ok = ($lease.Count -eq $Total)
    Exit-TcGateSlots $lease
    if (-not $ok) { Write-Host 'probe-gate-slot-fairness: LONE RUN FAILED - a lone run did not get the whole budget'; exit 1 }
    Write-Host 'probe-gate-slot-fairness: lone run ok'
    exit 0
  }

  $procs = @()
  for ($i = 0; $i -lt $Arrivals; $i++) {
    $childArgs = @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath,
      '-Child', '-Index', $i, '-Rendezvous', $rv, '-Prefix', $prefix, '-QueueRoot', $queueRoot,
      '-Lib', $Lib, '-Want', $Want, '-Total', $Total, '-WorkMs', $WorkMs,
      '-StaggerMs', $StaggerMs, '-PollMs', $PollMs, '-WaitSec', $WaitSec
    )
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $childArgs -WindowStyle Hidden -PassThru
    $null = $p.Handle   # without this, ExitCode reads as a pass whatever happened
    $procs += $p
  }

  $readyBy = [DateTime]::UtcNow.AddSeconds(180)
  while ($true) {
    $ready = @([IO.Directory]::GetFiles($rv, 'ready-*.txt')).Count
    if ($ready -ge $Arrivals) { break }
    if ([DateTime]::UtcNow -gt $readyBy) {
      Write-Host ("probe: only {0} of {1} children reported ready; the rest could not run" -f $ready, $Arrivals)
      break
    }
    Start-Sleep -Milliseconds 100
  }
  # The release clock, published only once every child is spinning on it.
  [IO.File]::WriteAllText((Join-Path $rv 'go.txt'), [string]([DateTime]::UtcNow.AddSeconds(2).Ticks))

  foreach ($p in $procs) { $null = $p.WaitForExit(600000) }

  $rowFiles = @([IO.Directory]::GetFiles($rv, 'row-*.json'))
  if ($rowFiles.Count -lt $Arrivals) {
    Write-Host ("probe: {0} of {1} arrivals wrote a row; the missing ones could not run and are NOT scored" -f $rowFiles.Count, $Arrivals)
  }
  $rows = @()
  foreach ($f in $rowFiles) {
    $one = [IO.File]::ReadAllText($f) | ConvertFrom-Json
    $rows += $one
  }
  $errored = @($rows | Where-Object { $_.Error })
  foreach ($e in $errored) { Write-Host ("probe: arrival {0} errored: {1}" -f $e.Index, $e.Error) }

  # The intended arrival order is the launch index; the recorded one is the stamp. Name any disagreement
  # rather than sorting it away - a scrambled stagger would make every number below about something else.
  $byArrival = @($rows | Sort-Object -Property ArrivalTicks)
  $outOfStep = 0
  for ($i = 0; $i -lt $byArrival.Count; $i++) { if ([int]$byArrival[$i].Index -ne $i) { $outOfStep++ } }
  if ($outOfStep -gt 0) {
    Write-Host ("probe: {0} of {1} arrivals landed out of their intended place in the stagger; order is scored from the STAMPS" -f $outOfStep, $byArrival.Count)
  }

  $score = Get-TcProbeOrdering -Rows $rows
  Write-TcProbeReport -Score $score -Label $Label -Total $Total -Concurrent $concurrent

  if ($OutJson) {
    $payload = [pscustomobject]@{
      Label = $Label; Lib = $Lib; Arrivals = $Arrivals; Want = $Want; Total = $Total
      WorkMs = $WorkMs; StaggerMs = $StaggerMs; WaitSec = $WaitSec
      ConcurrentRunGates = $concurrent; OutOfStep = $outOfStep
      Inversions = $score.Inversions; Pairs = $score.Pairs; MaxPassedBy = $score.MaxPassedBy
      TimedOut = $score.TimedOut; Granted = $score.Granted; Peak = $score.Peak
      FirstIsFastest = $score.FirstIsFastest; Rows = $byArrival
    }
    [IO.File]::WriteAllText($OutJson, (ConvertTo-Json $payload -Depth 6))
    Write-Host ("  rows written to {0}" -f $OutJson)
  }

  # THE BARS, stated in design\MEASURE-gate-slot-starvation-2026-09-11.md before the run.
  $breaches = @()
  if ($score.Pairs -gt 0 -and $score.Inversions -gt [math]::Floor($score.Pairs * 0.1)) { $breaches += 'B1 fairness' }
  if ($score.MaxPassedBy -gt 2) { $breaches += 'B2 no-passing' }
  if ($score.TimedOut -gt 0) { $breaches += 'B3 no-refusal' }
  if ($score.Peak -gt $Total) { $breaches += 'B4 budget' }
  if (-not $score.FirstIsFastest) { $breaches += 'B5 first-out' }
  if ($breaches.Count -gt 0) {
    Write-Host ("  BARS BREACHED: {0}" -f ($breaches -join ', '))
  } else {
    Write-Host '  every bar held'
  }
  Write-Host ("PROBE-GATE-SLOT-FAIRNESS-COMPLETE arm={0} arrivals={1} inversions={2}/{3} peak={4}/{5}" -f `
      $Label, $score.Arrivals, $score.Inversions, $score.Pairs, $score.Peak, $Total)
  if ($Strict -and $breaches.Count -gt 0) { exit 1 }
  exit 0
} finally {
  try { [IO.Directory]::Delete($rv, $true) } catch { }
}
