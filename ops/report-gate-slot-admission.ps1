<#
  report-gate-slot-admission.ps1 - reads ops\probe-gate-slot-admission.ps1's event file and prints the
  verdicts against the bars written BEFORE the run in design\MEASURE-gate-slot-admission-2026-09-11.md.

  Usage:  powershell -File ops\report-gate-slot-admission.ps1 -Events <events.jsonl>

  EVERY RATE CARRIES ITS DENOMINATOR, and every verdict is one of CONFIRMED, REFUTED or UNQUALIFIED with
  the reason - a sample under the bar's minimum is UNQUALIFIED, never a quiet pass. The bars are in the
  document, not here: this file must never be the place a threshold is chosen after seeing the number.

  SCOPE OF A CLEAN REPORT: it reports what the probe recorded and nothing else. It cannot see a slot
  handed over and taken back inside one sample, and it inherits the probe's inferred "waiting". A
  verdict here is about the window measured, on the population of runs that happened to be on the box.

  BY HAND, beside the probe. Nothing schedules either.
#>
param([Parameter(Mandatory)][string]$Events)
$ErrorActionPreference = 'Stop'
$rows = [Collections.Generic.List[object]]::new()
foreach ($line in [IO.File]::ReadAllLines($Events)) { if ($line.Trim()) { $rows.Add(($line | ConvertFrom-Json)) } }
function Pct($a, $b) { if ($b -eq 0) { 'n/a (0 of 0)' } else { '{0} of {1} ({2:N0}%)' -f $a, $b, (100.0 * $a / $b) } }
function Q($xs, $q) { $s = @($xs | Sort-Object); if (-not $s.Count) { return $null }; $s[[Math]::Min($s.Count - 1, [Math]::Floor($q * $s.Count))] }
$t0 = [DateTime]::Parse(($rows | Where-Object ev -eq 'probe_start' | Select-Object -Last 1).t).ToUniversalTime()
$t1 = [DateTime]::Parse($rows[$rows.Count - 1].t).ToUniversalTime()
$mins = ($t1 - $t0).TotalMinutes
$start = $rows | Where-Object ev -eq 'probe_start' | Select-Object -Last 1
"WINDOW  {0:u} to {1:u}  = {2:N1} min; probe md5 {3}" -f $t0, $t1, $mins, $start.probe_md5

$ticks = @($rows | Where-Object ev -eq 'tick')
"TICKS   {0}; run-gates alive mean {1:N1} (min {2}, max {3}); registered waiters mean {4:N1} (max {5}); holders mean {6:N1}; slots owned mean {7:N1} of 10" -f $ticks.Count,
  (($ticks | Measure-Object runs_alive -Average).Average), (($ticks | Measure-Object runs_alive -Minimum).Minimum), (($ticks | Measure-Object runs_alive -Maximum).Maximum),
  (($ticks | Measure-Object waiting -Average).Average), (($ticks | Measure-Object waiting -Maximum).Maximum),
  (($ticks | Measure-Object holders -Average).Average), (($ticks | Measure-Object slots_owned -Average).Average)

$acq = @($rows | Where-Object ev -eq 'acquire')
$grows = @($acq | Where-Object class -eq 'GROW')
$admits = @($acq | Where-Object class -eq 'ADMIT')
"ACQUIRE {0} slot acquisitions after the first sample: ADMIT {1}, GROW {2}" -f $acq.Count, $admits.Count, $grows.Count
# H1: acquisitions made while at least one registered waiter existed (the acquirer counts if it was one)
$withW = @($acq | Where-Object { $_.waiters_other -ge 1 -or ($_.class -eq 'ADMIT' -and $null -ne $_.own_wait_s) })
$g1 = @($withW | Where-Object class -eq 'GROW').Count
$h1 = if ($withW.Count -lt 20) { 'UNQUALIFIED (n under 20)' } elseif ((100.0 * $g1 / $withW.Count) -ge 20) { 'CONFIRMED' } elseif ((100.0 * $g1 / $withW.Count) -lt 5) { 'REFUTED' } else { 'UNQUALIFIED (between the bars)' }
"H1      GROW share of acquisitions with a registered waiter present: {0}  ->  {1}" -f (Pct $g1 $withW.Count), $h1
foreach ($g in $grows) { "          grow  slot {0} pid {1} held_before {2} waiters_other {3} oldest_other_wait_s {4}" -f $g.slot, $g.pid, $g.held_before, $g.waiters_other, $g.oldest_other_wait_s }

# H2: first ADMIT per run, where the acquirer was a registered waiter and at least 3 waiters (incl. it) existed
$firstAdmit = @{}
foreach ($a in $admits) { if (-not $firstAdmit.ContainsKey([string]$a.pid)) { $firstAdmit[[string]$a.pid] = $a } }
$h2set = @($firstAdmit.Values | Where-Object { $null -ne $_.own_wait_s -and ($_.waiters_other + 1) -ge 3 })
$oldW = @($h2set | Where-Object { $_.rank_by_wait -eq 1 }).Count
$oldC = @($h2set | Where-Object { $_.rank_by_created -eq 1 }).Count
function H2Verdict($k, $n) { if ($n -lt 10) { 'UNQUALIFIED (n under 10)' } elseif ((100.0 * $k / $n) -le 50) { 'CONFIRMED' } elseif ((100.0 * $k / $n) -ge 90) { 'REFUTED' } else { 'UNQUALIFIED (between the bars)' } }
"H2      admitted run was the oldest waiter, by wait start: {0} -> {1}; by process creation: {2} -> {3}" -f (Pct $oldW $h2set.Count), (H2Verdict $oldW $h2set.Count), (Pct $oldC $h2set.Count), (H2Verdict $oldC $h2set.Count)
$ranks = @($h2set | ForEach-Object { '{0}/{1}' -f $_.rank_by_created, ($_.waiters_other + 1) })
"          rank_by_created/waiters at each admission: {0}" -f ($ranks -join ' ')
$unreg = @($firstAdmit.Values | Where-Object { $null -eq $_.own_wait_s }).Count
"          admissions of runs never registered as waiters (took a slot straight after discovery): {0} of {1}" -f $unreg, $firstAdmit.Count

# A: arrivals vs services
$ws = @($rows | Where-Object { $_.ev -eq 'wait_start' -and -not $_.censored })
$arrDirect = @($firstAdmit.Values | Where-Object { $null -eq $_.own_wait_s })
$arrivals = $ws.Count + $arrDirect.Count
$runKind = @{}; foreach ($r in ($rows | Where-Object ev -eq 'run_seen')) { $runKind[[string]$r.pid] = $r.kind }
$services = @($rows | Where-Object { $_.ev -eq 'release' -and $_.held_after -eq 0 -and $runKind[[string]$_.pid] -eq 'run-gates' })
# A REAL run either held a slot or lived 30 s. The 1-second "run-gates.ps1" processes are a fixture's stand-in
# script (they never reach discovery's 2 CPU-s), and counting them would bury the starved runs under exit-0 noise.
$allExits = @($rows | Where-Object { $_.ev -eq 'run_exit' -and $_.kind -eq 'run-gates' })
$exits = @($allExits | Where-Object { $_.ever_held -or [double]$_.lifetime_s -ge 30 })
"          run-gates processes that exited within 30 s without a slot (excluded as fixture stand-ins): {0} of {1}" -f ($allExits.Count - $exits.Count), $allExits.Count
$starved = @($exits | Where-Object { -not $_.ever_held })
$av = if ($services.Count -lt 10) { 'UNQUALIFIED (under 10 services)' } elseif ($arrivals -ge 1.2 * $services.Count) { 'CONFIRMED' } elseif ($arrivals -lt $services.Count) { 'REFUTED' } else { 'UNQUALIFIED (between the bars)' }
"A       arrivals {0} ({1} registered waiters not censored + {2} admitted without waiting) against services {3} over {4:N1} min = {5:N2}/min in, {6:N2}/min out  ->  {7}" -f $arrivals, $ws.Count, $arrDirect.Count, $services.Count, $mins, ($arrivals / $mins), ($services.Count / $mins), $av
$meanQ = ($ticks | Measure-Object waiting -Average).Average
if ($services.Count) { "          projected FIFO wait = mean registered waiters {0:N1} / service rate {1:N2}/min = {2:N1} min against a 20 min limit" -f $meanQ, ($services.Count / $mins), ($meanQ / ($services.Count / $mins)) }
"          run-gates exits {0}: exit codes {1}" -f $exits.Count, (($exits | Group-Object exit_code | ForEach-Object { '{0}x{1}' -f $_.Name, $_.Count }) -join ' ')
"          exited having NEVER held a slot: {0}; their exit codes {1}; their lifetimes (s) {2}" -f $starved.Count, (($starved | Group-Object exit_code | ForEach-Object { '{0}x{1}' -f $_.Name, $_.Count }) -join ' '), (($starved | ForEach-Object { [int]$_.lifetime_s }) -join ' ')

# per-run waits and held times
$waits = @($exits + @($rows | Where-Object ev -eq 'run_open') | Where-Object { $null -ne $_.wait_s } | ForEach-Object { [double]$_.wait_s })
$waitsA = @($admits | Where-Object { $null -ne $_.own_wait_s } | ForEach-Object { [double]$_.own_wait_s })
"WAIT    registered waiters admitted: {0}; wait s median {1} p90 {2} max {3} (censored waits included as lower bounds: {4})" -f $waitsA.Count, (Q $waitsA 0.5), (Q $waitsA 0.9), (Q $waitsA 1.0), @($admits | Where-Object { $_.own_censored }).Count
$held = @($exits | Where-Object { $null -ne $_.held_s } | ForEach-Object { [double]$_.held_s })
"HELD    runs that got and gave back slots within the window: {0}; slot-held s median {1} p90 {2} max {3}; peak width distribution {4}" -f $held.Count, (Q $held 0.5), (Q $held 0.9), (Q $held 1.0), (($exits | Where-Object ever_held | Group-Object peak | ForEach-Object { 'w{0}x{1}' -f $_.Name, $_.Count }) -join ' ')
"        runs ever seen to GROW: {0}" -f @($rows | Where-Object { $_.ev -in 'run_exit', 'run_open' -and $_.grows -gt 0 }).Count

# B
$stuck = @($rows | Where-Object ev -eq 'stuck_holder')
$foreign = @($rows | Where-Object ev -eq 'foreign_holder')
"B       stuck holders {0}; non-run-gates holders seen in full scans {1} (distinct pids {2}: {3})" -f $stuck.Count, $foreign.Count, @($foreign | Select-Object -ExpandProperty pid -Unique).Count, ((@($foreign | Group-Object pid | ForEach-Object { '{0} {1}' -f $_.Name, (($_.Group[0].cmd -replace '.*-File\s+', '') -replace '\s.*', '') })) -join '; ')
foreach ($s in $stuck) { "          stuck pid {0} kind {1} held {2} gained {3} CPU-s over {4} s" -f $s.pid, $s.kind, $s.held, $s.tree_cpu_gain_s, $s.span_s }
"ROWS    {0} total: {1}" -f $rows.Count, (($rows | Group-Object ev | ForEach-Object { '{0}={1}' -f $_.Name, $_.Count }) -join ' ')
