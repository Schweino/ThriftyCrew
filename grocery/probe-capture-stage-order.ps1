<#
  probe-capture-stage-order.ps1 - did the day's ONE build-and-publish chain ever start before that day's AD
  capture had landed? A REPORT, never a gate, run by hand. Backlog I45.

  THE EDGE IT MEASURES. Two Windows tasks share one working tree: 'TC Grocery Ad Pulls 0700'
  (grocery\capture-run.ps1 -Kind ad, captures only) and 'TC Grocery Daily Capture 0800' (-Kind daily, which
  runs the downstream chain - compare, guards, publish, commit - ONCE a day). The daily chain reads what the
  ad run wrote (grocery\out\ads-<date>.json, the Fareway ad files). The dependency is encoded as a clock gap
  of one hour, and both tasks re-fire hourly for six hours as catch-up, so a failed 07:00 run can re-run AFTER
  the day's chain has already built the board. Its capture then waits a whole day for the next chain, and the
  chain that ran reported success over the older ad. That is I45's founding shape, and this answers how often
  it has actually happened rather than how often it could.

  HOW ORDER IS READ, AND WHY THE TRANSCRIPT START IS ENOUGH. Both kinds take the named mutex
  Global\tc-capture-run before they write anything and refuse ('SKIP: another capture-run holds the lock')
  when they cannot. So two occurrences never overlap, and an ad occurrence that STARTED before the day's
  chain occurrence finished its writes before that chain could begin. The verdict therefore needs only each
  occurrence's transcript start time, never an end time - which matters, because a run killed mid-rebase
  leaves no 'End time' line at all (2026-09-14 07:00 is one).

  WHAT COUNTS AS AD DATA: an ad occurrence whose 'lanes run=N failed=M' line has N-M > 0. A catch-up whose
  only lane failed (Fareway's vision-read handoff exits 3 and writes no deals file) wrote nothing a chain
  could have missed.

  VERDICT PER DAY: no-chain | no-ad-data | ordered | CHAIN-BEFORE-AD.
  EXIT: 0 no CHAIN-BEFORE-AD day; 1 at least one; 3 could not evaluate (no transcript resolved).

  SCOPE OF A CLEAN REPORT: UNSOUND. It reads grocery\out\logs\capture-run-{ad,daily}-<date>.log only. A day
  with no transcript (the box asleep, 2026-09-15 and 09-16) is absent rather than scored, an occurrence that
  printed 'SKIP: ... already ran today' leaves no transcript header and is not seen, and a manual run by hand
  is counted like a scheduled one. It says whether the order held on the days it can read, and prints how
  many those were.
#>
[CmdletBinding()]
param(
  [string]$LogDir = '',
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
# The self-test is hermetic: in-file fixtures and temp files it writes itself, no repo file but this one.
# gate-inputs: grocery\probe-capture-stage-order.ps1
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $LogDir) { $LogDir = Join-Path $here 'out\logs' }   # grocery\out\logs: this probe lives beside the chain it reads

function Get-CaptureOccurrences {
  <# One row per transcript occurrence in capture-run-{ad,daily}-<date>.log under $Dir. Reads files only. #>
  param([string]$Dir)
  $rows = New-Object System.Collections.ArrayList
  if (-not (Test-Path -LiteralPath $Dir)) { return ,$rows }
  $files = @(Get-ChildItem -LiteralPath $Dir -Filter 'capture-run-*.log' | Sort-Object Name)
  foreach ($f in $files) {
    if ($f.Name -notmatch '^capture-run-(ad|daily)-(\d{4}-\d{2}-\d{2})\.log$') { continue }
    $kind = $Matches[1]; $day = $Matches[2]
    $cur = $null
    foreach ($l in (Get-Content -LiteralPath $f.FullName -Encoding UTF8)) {
      if ($l -match '^Start time: (\d{14})') {
        $cur = [pscustomobject]@{ day = $day; kind = $kind; start = [datetime]::ParseExact($Matches[1], 'yyyyMMddHHmmss', $null)
                                  lanes = 0; lanesFailed = 0; skipped = $false; chain = $false }
        [void]$rows.Add($cur); continue
      }
      if ($null -eq $cur) { continue }
      if ($l -match '^SKIP: another capture-run holds the lock') { $cur.skipped = $true }
      if ($l -match 'captures done\. lanes run=(\d+) failed=(\d+)') { $cur.lanes = [int]$Matches[1]; $cur.lanesFailed = [int]$Matches[2] }
      if ($l -match '^downstream: check-ad-cycles') { $cur.chain = $true }
    }
  }
  return ,$rows
}

function Get-StageOrderVerdicts {
  <# PURE. One verdict per day over the rows Get-CaptureOccurrences returned. #>
  param($Rows)
  $out = New-Object System.Collections.ArrayList
  $days = @($Rows | ForEach-Object { $_.day } | Sort-Object -Unique)
  foreach ($d in $days) {
    $chains = @($Rows | Where-Object { $_.day -eq $d -and $_.kind -eq 'daily' -and $_.chain -and -not $_.skipped })
    $adData = @($Rows | Where-Object { $_.day -eq $d -and $_.kind -eq 'ad' -and -not $_.skipped -and ($_.lanes - $_.lanesFailed) -gt 0 })
    $chainStart = $null
    foreach ($c in $chains) { if (($null -eq $chainStart) -or $c.start -lt $chainStart) { $chainStart = $c.start } }
    $late = @($adData | Where-Object { $null -ne $chainStart -and $_.start -gt $chainStart })
    $v = if (-not $chains.Count) { 'no-chain' } elseif (-not $adData.Count) { 'no-ad-data' } elseif ($late.Count) { 'CHAIN-BEFORE-AD' } else { 'ordered' }
    $lastAd = $null
    foreach ($a in $adData) { if (($null -eq $lastAd) -or $a.start -gt $lastAd) { $lastAd = $a.start } }
    [void]$out.Add([pscustomobject]@{
      day = $d; verdict = $v
      ad_data_runs = $adData.Count
      last_ad_data_start = $(if ($lastAd) { $lastAd.ToString('HH:mm:ss') } else { '' })
      chain_start = $(if ($chainStart) { $chainStart.ToString('HH:mm:ss') } else { '' })
    })
  }
  return ,$out
}

if ($SelfTest) {
  $script:n = 0; $script:f = 0
  function Assert-Case([string]$Name, [bool]$Ok, [string]$Got) {
    $script:n++
    if ($Ok) { Write-Output ("ok    " + $Name) } else { $script:f++; Write-Output ("FAIL  " + $Name + "  got=" + $Got) }
  }
  function New-Transcript([string]$Start, [string[]]$Body) {
    $lines = @('**********************', 'Windows PowerShell transcript start', ('Start time: ' + $Start), '**********************') + $Body + @('**********************', ('End time: ' + $Start), '**********************')
    return ($lines -join "`r`n")
  }
  $tmp = Join-Path $env:TEMP ('pcso-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
  try {
    New-Item -ItemType Directory -Path $tmp -ErrorAction Stop | Out-Null
    $pulled  = 'capture-run [ad] captures done. lanes run=2 failed=0 browser-pending=0'
    $allFail = 'capture-run [ad] captures done. lanes run=1 failed=1 browser-pending=0'
    $chain   = 'downstream: check-ad-cycles -NoPull -NoCommit (compare -> guards -> publish -> recipes -> commit HERE)'
    $locked  = 'SKIP: another capture-run holds the lock (a scheduled run overlapping, or a manual one). Nothing started - two runs on one working tree corrupt each other.'
    # day 1: the founding shape - the 07:00 ad run left nothing, the chain ran at 08:00, the catch-up pulled at 09:00.
    $ad1 = (New-Transcript '20260101070000' @('capture-run [ad] captures done. lanes run=0 failed=0 browser-pending=0')) + "`r`n" + (New-Transcript '20260101090000' @($pulled))
    [IO.File]::WriteAllText((Join-Path $tmp 'capture-run-ad-2026-01-01.log'), $ad1)
    [IO.File]::WriteAllText((Join-Path $tmp 'capture-run-daily-2026-01-01.log'), (New-Transcript '20260101080000' @($chain)))
    # day 2: the normal morning.
    [IO.File]::WriteAllText((Join-Path $tmp 'capture-run-ad-2026-01-02.log'), (New-Transcript '20260102070000' @($pulled)))
    [IO.File]::WriteAllText((Join-Path $tmp 'capture-run-daily-2026-01-02.log'), (New-Transcript '20260102080000' @($chain)))
    # day 3: 2026-09-14's shape - the ad data landed at 07:00, and a 09:00 catch-up's only lane failed.
    $ad3 = (New-Transcript '20260103070000' @($pulled)) + "`r`n" + (New-Transcript '20260103090000' @($allFail))
    [IO.File]::WriteAllText((Join-Path $tmp 'capture-run-ad-2026-01-03.log'), $ad3)
    [IO.File]::WriteAllText((Join-Path $tmp 'capture-run-daily-2026-01-03.log'), (New-Transcript '20260103080000' @($chain)))
    # day 4: a 09:00 ad occurrence that was refused the lock - it wrote nothing.
    $ad4 = (New-Transcript '20260104070000' @($pulled)) + "`r`n" + (New-Transcript '20260104090000' @($locked, $pulled))
    [IO.File]::WriteAllText((Join-Path $tmp 'capture-run-ad-2026-01-04.log'), $ad4)
    [IO.File]::WriteAllText((Join-Path $tmp 'capture-run-daily-2026-01-04.log'), (New-Transcript '20260104080000' @($chain)))
    # day 5: no ad was due.
    [IO.File]::WriteAllText((Join-Path $tmp 'capture-run-ad-2026-01-05.log'), (New-Transcript '20260105070000' @('capture-run [ad] captures done. lanes run=0 failed=0 browser-pending=0')))
    [IO.File]::WriteAllText((Join-Path $tmp 'capture-run-daily-2026-01-05.log'), (New-Transcript '20260105080000' @($chain)))

    $rows = Get-CaptureOccurrences -Dir $tmp
    $vs = Get-StageOrderVerdicts -Rows $rows
    $by = @{}; foreach ($v in $vs) { $by[$v.day] = $v.verdict }
    Assert-Case 'MUST FIRE  an ad catch-up that pulled AFTER the day''s chain started is CHAIN-BEFORE-AD' ($by['2026-01-01'] -eq 'CHAIN-BEFORE-AD') ([string]$by['2026-01-01'])
    Assert-Case 'MUST NOT FIRE  an ad run that pulled before the chain is ordered' ($by['2026-01-02'] -eq 'ordered') ([string]$by['2026-01-02'])
    Assert-Case 'MUST NOT FIRE  a late catch-up whose only lane FAILED wrote nothing, so the day is ordered (2026-09-14)' ($by['2026-01-03'] -eq 'ordered') ([string]$by['2026-01-03'])
    Assert-Case 'MUST NOT FIRE  a late occurrence refused the mutex wrote nothing, so the day is ordered' ($by['2026-01-04'] -eq 'ordered') ([string]$by['2026-01-04'])
    Assert-Case 'CLEAN TWIN  a day with no ad pulled reads no-ad-data, not ordered' ($by['2026-01-05'] -eq 'no-ad-data') ([string]$by['2026-01-05'])
    Assert-Case 'CLEAN TWIN  every transcript occurrence is resolved (13 of 13)' ($rows.Count -eq 13) ([string]$rows.Count)
    $empty = Join-Path $tmp 'none'
    $r0 = Get-CaptureOccurrences -Dir $empty
    Assert-Case 'MUST FIRE  a log directory that is absent resolves ZERO occurrences, which the report turns into exit 3' ($r0.Count -eq 0) ([string]$r0.Count)
  } catch {
    $script:n++; $script:f++; Write-Output ('FAIL  the self-test threw: ' + $_.Exception.Message)
  } finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
  }
  if ($script:f -eq 0) { Write-Output ("probe-capture-stage-order SELF-TEST PASS: {0} case(s)" -f $script:n); exit 0 }
  Write-Output ("probe-capture-stage-order SELF-TEST FAIL: {0} of {1} case(s)" -f $script:f, $script:n)
  exit 1
}

$rows = Get-CaptureOccurrences -Dir $LogDir
if ($rows.Count -eq 0) {
  Write-Output ("probe-capture-stage-order: no capture-run transcript resolved under " + $LogDir + " - could not evaluate, which is not a clean order.")
  Write-Output 'PROBE-CAPTURE-STAGE-ORDER-COMPLETE days=0 blind=1'
  exit 3
}
$vs = Get-StageOrderVerdicts -Rows $rows
$vs | Format-Table -AutoSize | Out-String -Width 200 | Write-Output
$nDays = $vs.Count
foreach ($g in ($vs | Group-Object verdict | Sort-Object Name)) { Write-Output ("{0,-16} {1} of {2} day(s)" -f $g.Name, $g.Count, $nDays) }
$adDays = @($vs | Where-Object { $_.verdict -eq 'ordered' -or $_.verdict -eq 'CHAIN-BEFORE-AD' }).Count
$bad = @($vs | Where-Object { $_.verdict -eq 'CHAIN-BEFORE-AD' }).Count
Write-Output ("occurrences read: {0} (ad {1}, daily {2}); refused the mutex: {3}" -f $rows.Count, @($rows | Where-Object { $_.kind -eq 'ad' }).Count, @($rows | Where-Object { $_.kind -eq 'daily' }).Count, @($rows | Where-Object { $_.skipped }).Count)
Write-Output ("chain started before that day's ad data: {0} of {1} day(s) that pulled ad data ({2} day(s) read, {3} to {4})" -f $bad, $adDays, $nDays, $vs[0].day, $vs[$nDays - 1].day)
Write-Output ("PROBE-CAPTURE-STAGE-ORDER-COMPLETE days={0} ad_days={1} chain_before_ad={2}" -f $nDays, $adDays, $bad)
if ($bad -gt 0) { exit 1 }
exit 0
