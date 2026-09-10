<#
  report-ratchet-trends.ps1 - which detectors are still finding things, and which one stopped looking.

  WS 10e of design\PLAN-brain-v2-2026-09-09.md.

  THE GAP. lib\ratchet.ps1's Get-RatchetTrend prints "flat at 7 across the last 10 runs" and nothing
  consumed it. Worse, the history it reads was only ever written in the TIGHTENED branch - by all three
  of its callers - so a detector returning the same figure run after run wrote no history at all, and
  "quietly returning the same number for six weeks because it stopped looking", the exact case the
  library's own header names, could not be seen. Measured 2026-09-10: two of the three history-keeping
  baselines carried no history key at all.

  THE READING IS TAKEN WHERE EVERY DETECTOR ALREADY RUNS. ops\run-gates.ps1 now appends each static
  detector's COMPLETE line to ops\out\gate-readings.jsonl (gitignored) on every run - one edit, instead
  of eight audits each learning to keep a history. This reads that file: one reading per gate per DAY
  (the last run that day), the first integer key=value in the marker as its mark, and the library's own
  Get-RatchetTrend for the words.

  STOPPED LOOKING: a mark that is NON-ZERO and identical across the last $StoppedRuns distinct days. A
  detector flat at ZERO is a clean tree, not a blind detector, and is not listed - a floor on zero is the
  guard-contract marker's job. A flat non-zero mark is not proof it stopped either: a backlog nobody is
  working holds still too. So it is a LINE for a person, in the watchdog mail and the digest.

  $StoppedRuns = 30 is the plan's number, a FIRST PLAUSIBLE VALUE, NOT a sweep (docs\CONTROL-CONSTANTS.md).

  SCOPE OF A CLEAN REPORT: UNSOUND. It sees detectors run by run-gates' static list that print a numeric
  COMPLETE line. A detector outside that list, or one whose summary carries no number, has no reading.

  EXIT 0 always - a report. With no readings yet it says NO EVIDENCE rather than "all moving".
#>
[CmdletBinding()]
param([switch]$SelfTest, [switch]$Json, [int]$StoppedRuns = 30, [string]$ReadingsFile = '')

$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\ops' }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\ratchet.ps1')

function Get-MarkerMark {
  <# @{ Key; Value } for the first integer key=value in a COMPLETE line, or $null. #>
  param([string]$Marker)
  $m = [regex]::Match("$Marker", '\b([A-Za-z_][\w-]*)=(-?\d+)\b')
  if (-not $m.Success) { return $null }
  return @{ Key = $m.Groups[1].Value; Value = [int]$m.Groups[2].Value }
}

function Get-DailyReadings {
  <# @{ gate = @(@{ date; mark; key }) } - the LAST reading of each gate on each day, oldest day first. #>
  param($Rows)
  $by = @{}
  foreach ($r in @($Rows)) {
    if (-not $r -or -not $r.gate -or -not $r.date) { continue }
    $mk = Get-MarkerMark -Marker $r.marker
    if ($null -eq $mk) { continue }
    $g = [string]$r.gate
    if (-not $by.ContainsKey($g)) { $by[$g] = @{} }
    $prevT = 0
    if ($by[$g].ContainsKey([string]$r.date)) { $prevT = [long]$by[$g][[string]$r.date].t }
    if ([long]$r.t -ge $prevT) { $by[$g][[string]$r.date] = @{ date = [string]$r.date; t = [long]$r.t; mark = $mk.Value; key = $mk.Key } }
  }
  $out = @{}
  foreach ($g in $by.Keys) {
    $days = @($by[$g].Values | Sort-Object { $_.date })
    $out[$g] = $days
  }
  return $out
}

function Test-StoppedLooking {
  <# $true when the last $Runs daily marks are identical and non-zero. #>
  param($Days, [int]$Runs)
  $d = @($Days)
  if ($d.Count -lt $Runs) { return $false }
  $tail = @($d[($d.Count - $Runs)..($d.Count - 1)])
  $first = [int]$tail[0].mark
  if ($first -eq 0) { return $false }
  foreach ($x in $tail) { if ([int]$x.mark -ne $first) { return $false } }
  return $true
}

if ($SelfTest) {
  $ran = New-Object System.Collections.Generic.List[string]
  $fails = New-Object System.Collections.Generic.List[string]
  function Case([string]$Label, [string]$Name, [bool]$Ok, [string]$Detail = '') {
    [void]$ran.Add($Name)
    if (-not $Ok) { [void]$fails.Add("$Label $Name") }
    Write-Output ("  {0,-14} {1,-66} {2}" -f $Label, $Name, $(if ($Ok) { 'ok' } else { "FAIL $Detail" }))
  }
  function Row([string]$gate, [string]$date, [long]$t, [string]$marker) {
    return [pscustomobject]@{ gate = $gate; date = $date; t = $t; marker = $marker }
  }

  $mk = Get-MarkerMark -Marker 'CROSS-MODULE-REACH-COMPLETE code_sites=133 baseline=133'
  Case 'MUST FIRE' 'the first integer key=value in a COMPLETE line is the mark' ($mk.Key -eq 'code_sites' -and $mk.Value -eq 133) "$($mk.Key)=$($mk.Value)"
  $flat = @(1..30 | ForEach-Object { Row 'ops\a.ps1' ('2026-09-{0:D2}' -f $_) (1000 + $_) 'A-COMPLETE findings=7' })
  $days = Get-DailyReadings -Rows $flat
  Case 'MUST FIRE' 'a non-zero mark flat across 30 days is STOPPED LOOKING' (Test-StoppedLooking -Days $days['ops\a.ps1'] -Runs 30)
  $twice = @((Row 'ops\a.ps1' '2026-09-01' 100 'A-COMPLETE findings=9'), (Row 'ops\a.ps1' '2026-09-01' 200 'A-COMPLETE findings=4'))
  $d2 = Get-DailyReadings -Rows $twice
  Case 'MUST FIRE' 'two runs on one day are ONE reading, the later one' (@($d2['ops\a.ps1']).Count -eq 1 -and $d2['ops\a.ps1'][0].mark -eq 4) "$(@($d2['ops\a.ps1']).Count)"

  $zero = @(1..30 | ForEach-Object { Row 'ops\z.ps1' ('2026-09-{0:D2}' -f $_) (1000 + $_) 'Z-COMPLETE findings=0' })
  $dz = Get-DailyReadings -Rows $zero
  Case 'MUST NOT FIRE' 'a detector flat at ZERO is a clean tree, not stopped looking' (-not (Test-StoppedLooking -Days $dz['ops\z.ps1'] -Runs 30))
  Case 'MUST NOT FIRE' '29 flat days is not yet stopped looking' (-not (Test-StoppedLooking -Days @($days['ops\a.ps1'])[1..29] -Runs 30))
  $vary = @(1..30 | ForEach-Object { Row 'ops\v.ps1' ('2026-09-{0:D2}' -f $_) (1000 + $_) ('V-COMPLETE findings={0}' -f $(if ($_ -eq 15) { 8 } else { 7 })) })
  $dv = Get-DailyReadings -Rows $vary
  Case 'MUST NOT FIRE' 'one different day in the window breaks the flat run' (-not (Test-StoppedLooking -Days $dv['ops\v.ps1'] -Runs 30))
  $nn = Get-DailyReadings -Rows @((Row 'ops\n.ps1' '2026-09-01' 1 'N-COMPLETE'))
  Case 'MUST NOT FIRE' 'a COMPLETE line with no number gives no reading' (-not $nn.ContainsKey('ops\n.ps1'))

  $hist = @(@($days['ops\a.ps1']) | ForEach-Object { [pscustomobject]@{ count = $_.mark } })
  $trend = Get-RatchetTrend -History $hist -Window 30
  Case 'CLEAN TWIN' "the words come from the library's own Get-RatchetTrend" ($trend -eq 'trend: flat at 7 across the last 30 run(s)') $trend
  $sorted = Get-DailyReadings -Rows @((Row 'ops\s.ps1' '2026-09-03' 3 'S-COMPLETE n=3'), (Row 'ops\s.ps1' '2026-09-01' 1 'S-COMPLETE n=1'))
  Case 'CLEAN TWIN' 'readings are ordered oldest day first' ($sorted['ops\s.ps1'][0].date -eq '2026-09-01') "$($sorted['ops\s.ps1'][0].date)"
  $rg = [IO.File]::ReadAllText((Join-Path $here 'run-gates.ps1'))
  Case 'CLEAN TWIN' 'run-gates records the readings this report reads' ($rg.Contains('gate-readings' + '.jsonl'))

  Write-Output ''
  if ($fails.Count) {
    Write-Output ("report-ratchet-trends selftest: {0} FAILED of {1}" -f $fails.Count, $ran.Count)
    $fails | ForEach-Object { Write-Output "  $_" }
    Exit-Guard -Name 'RATCHET-TRENDS-SELFTEST' -Code 1 -Summary "failed=$($fails.Count) cases=$($ran.Count)"
  }
  Write-Output ("report-ratchet-trends selftest: {0} of {0} cases pass" -f $ran.Count)
  Exit-Guard -Name 'RATCHET-TRENDS-SELFTEST' -Code 0 -Summary "cases=$($ran.Count)"
}

# ------------------------------------------------------------------------------------------------ live
if (-not $ReadingsFile) { $ReadingsFile = Join-Path $here 'out\gate-readings.jsonl' }
$rows = New-Object System.Collections.Generic.List[object]
if (Test-Path -LiteralPath $ReadingsFile) {
  foreach ($line in [IO.File]::ReadAllLines($ReadingsFile)) {
    if (-not "$line".Trim()) { continue }
    try { [void]$rows.Add(($line | ConvertFrom-Json)) } catch { }
  }
}
Write-Output 'RATCHET TRENDS - is each detector still finding what it used to?'
if ($rows.Count -eq 0) {
  Write-Output '  ratchet trends: NO EVIDENCE yet - run-gates has recorded no readings on this machine. That is not "every detector is moving".'
  if ($Json) { 'ratchet-trends-json: {"known": false, "gates": 0, "stopped_looking": 0, "days": 0}' }
  Exit-Guard -Name 'RATCHET-TRENDS' -Code 0 -Summary 'readings=0'
}
$daily = Get-DailyReadings -Rows $rows.ToArray()
$stopped = New-Object System.Collections.Generic.List[string]
$allDays = @{}
foreach ($g in ($daily.Keys | Sort-Object)) {
  $ds = @($daily[$g])
  foreach ($x in $ds) { $allDays[$x.date] = $true }
  $hist = @($ds | ForEach-Object { [pscustomobject]@{ count = $_.mark } })
  $trend = Get-RatchetTrend -History $hist -Window $StoppedRuns
  Write-Output ("  trend {0,-46} {1}={2}  {3}" -f $g, $ds[-1].key, $ds[-1].mark, $trend)
  if (Test-StoppedLooking -Days $ds -Runs $StoppedRuns) { [void]$stopped.Add($g) }
}
foreach ($s in $stopped) {
  Write-Output ("  STOPPED LOOKING? {0} has read the same non-zero mark on each of the last {1} days. A backlog nobody works holds still too - look before believing either." -f $s, $StoppedRuns)
}
Write-Output ("  ratchet trends: {0} detector(s) with readings over {1} day(s), {2} flat for {3}+ days at a non-zero mark" -f $daily.Count, $allDays.Count, $stopped.Count, $StoppedRuns)
if ($Json) {
  'ratchet-trends-json: ' + (([ordered]@{ known = $true; gates = $daily.Count; stopped_looking = $stopped.Count; days = $allDays.Count }) | ConvertTo-Json -Compress)
}
Exit-Guard -Name 'RATCHET-TRENDS' -Code 0 -Summary ("gates={0} days={1} stopped={2}" -f $daily.Count, $allDays.Count, $stopped.Count)
