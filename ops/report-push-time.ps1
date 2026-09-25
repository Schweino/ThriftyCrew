<#
report-push-time.ps1 - where a landed push's wall time goes, per push kind, off the push ledger.

M1 of design\PLAN-faster-pushes-no-accuracy-loss-2026-09-25.md. Every bar in that plan is read from this report, so it
is committed rather than rerun as scratch (.claude\rules\measurement.md, "NAMING A SCRATCH HARNESS IS NOT NAMING A HARNESS").

READS: the push-main rows of lib\push-ledger.ps1's daily files (%LOCALAPPDATA%\ThriftyCrew\push-ledger, or -Root) whose
outcome starts "landed". A row is one landing. Kind is `chain` when chain_touching is true, `plain` otherwise.

PRINTS, per kind, with every denominator:
  - landings, and how many carry leg_sec (the field is newer than the ledger);
  - median and p90 (nearest rank, Get-TcPushPercentile) of run-gates, test-auditors and, for chain, the rehearsal;
  - early_hit yes / no / unknown / not recorded, over the chain landings;
  - rehearsals per chain landing (sum of `rehearsed` over landings), and how many rehearsed twice or more.
-Rows writes one TSV row per landing (the case file the totals derive from, measurement.md E24).

A RECORDED rh BEFORE M1 IS THE COLLECTION TIME, not the child's run time: a "not needed" rehearsal was charged the whole
gate leg. So the rehearsal column is printed for chain landings only, where the rehearsal really is the long leg. The
-Rows file carries each row's pm_blob, so a reader can split rows written before and after the fix.

SCOPE OF A CLEAN REPORT: a report, not a gate. It is exactly as complete as the ledger: a push that went round push-main
(a plain git push) writes no row and is not here.

Exit 0 printed, 3 could not read any ledger file. Last line: REPORT-PUSH-TIME-COMPLETE.
#>
param(
  [string]$Root = '',
  [string]$From = '',
  [string]$To = '',
  [string]$Rows = '',
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent $here
. (Join-Path $repo 'lib\push-ledger.ps1')

function Get-PtLegSec($row, [string]$leg) {
  $ls = $row.PSObject.Properties['leg_sec']
  if ($null -eq $ls -or $null -eq $ls.Value) { return $null }
  $p = $ls.Value.PSObject.Properties[$leg]
  if ($null -eq $p -or $null -eq $p.Value) { return $null }
  return [int]$p.Value
}

function Get-PtProp($row, [string]$name) {
  $p = $row.PSObject.Properties[$name]
  if ($null -eq $p) { return $null }
  return $p.Value
}

function Measure-PtLandings {
  <# Pure: landed push-main rows in, one summary object per kind out. #>
  param($Rows)
  $land = @($Rows | Where-Object { $null -ne $_ -and -not (Get-PtProp $_ 'malformed') -and [string](Get-PtProp $_ 'event') -ceq 'push-main' -and ([string](Get-PtProp $_ 'outcome')).StartsWith('landed') })
  $out = @()
  foreach ($kind in @('chain', 'plain')) {
    $k = @($land | Where-Object { $isChain = ((Get-PtProp $_ 'chain_touching') -eq $true); ($kind -ceq 'chain') -eq $isChain })
    $timed = @($k | Where-Object { $null -ne (Get-PtLegSec $_ 'rg') })
    $s = [ordered]@{ kind = $kind; landings = $k.Count; timed = $timed.Count }
    foreach ($leg in @('rg', 'ta', 'rh')) {
      if ($leg -ceq 'rh' -and $kind -ceq 'plain') { continue }
      $v = @($timed | ForEach-Object { Get-PtLegSec $_ $leg } | Where-Object { $null -ne $_ } | Sort-Object)
      $s[$leg + '_n'] = $v.Count
      $s[$leg + '_med'] = $(if ($v.Count) { Get-TcPushPercentile -Sorted $v -Fraction 0.5 } else { -1 })
      $s[$leg + '_p90'] = $(if ($v.Count) { Get-TcPushPercentile -Sorted $v -Fraction 0.9 } else { -1 })
    }
    if ($kind -ceq 'chain') {
      $eh = @($k | ForEach-Object { [string](Get-PtProp $_ 'early_hit') })
      $s['early_yes'] = @($eh | Where-Object { $_ -ceq 'yes' }).Count
      $s['early_no'] = @($eh | Where-Object { $_ -ceq 'no' }).Count
      $s['early_unknown'] = @($eh | Where-Object { $_ -ceq 'unknown' }).Count
      $s['early_unrecorded'] = @($eh | Where-Object { -not $_ }).Count
      $rs = @($k | ForEach-Object { $r = Get-PtProp $_ 'rehearsed'; if ($null -eq $r) { 0 } else { [int]$r } })
      $s['rehearsals'] = [int](($rs | Measure-Object -Sum).Sum)
      $s['rehearsed_2plus'] = @($rs | Where-Object { $_ -ge 2 }).Count
    }
    $out += [pscustomobject]$s
  }
  return $out
}

function Format-PtSummary($s) {
  $lines = @()
  $lines += ('{0}: {1} landing(s), {2} of {1} carry leg timings' -f $s.kind, $s.landings, $s.timed)
  foreach ($leg in @('rg', 'ta', 'rh')) {
    if ($null -eq $s.PSObject.Properties[$leg + '_n']) { continue }
    $name = @{ rg = 'run-gates'; ta = 'test-auditors'; rh = 'rehearsal' }[$leg]
    $lines += ('  {0,-14} n={1} median={2}s p90={3}s' -f $name, $s.($leg + '_n'), $s.($leg + '_med'), $s.($leg + '_p90'))
  }
  if ($s.kind -ceq 'chain') {
    $lines += ('  early rehearsal hit: yes {0}, no {1}, unknown {2}, not recorded {3} (of {4} chain landings)' -f $s.early_yes, $s.early_no, $s.early_unknown, $s.early_unrecorded, $s.landings)
    $lines += ('  rehearsals: {0} over {1} landing(s); {2} landing(s) rehearsed twice or more' -f $s.rehearsals, $s.landings, $s.rehearsed_2plus)
  }
  return $lines
}

if ($SelfTest) {
  $kMF = 'MUST' + ' FIRE'; $kCT = 'CLEAN' + ' TWIN'; $kMNF = 'MUST' + ' NOT FIRE'
  $script:pass = 0; $script:fail = 0
  function T([string]$m, [bool]$c, [string]$got) { if ($c) { $script:pass++; Write-Output ('ok    ' + $m) } else { $script:fail++; Write-Output ('FAIL  ' + $m + '   got: ' + $got) } }
  function Rw([string]$json) { return ($json | ConvertFrom-Json) }
  $fx = @(
    (Rw '{"event":"push-main","outcome":"landed","chain_touching":true,"leg_sec":{"rg":300,"ta":90,"rh":900},"early_hit":"no","rehearsed":1}'),
    (Rw '{"event":"push-main","outcome":"landed","chain_touching":true,"leg_sec":{"rg":320,"ta":100,"rh":1000},"early_hit":"yes","rehearsed":0}'),
    (Rw '{"event":"push-main","outcome":"landed","chain_touching":true,"early_hit":null,"rehearsed":3}'),
    (Rw '{"event":"push-main","outcome":"landed","chain_touching":false,"leg_sec":{"rg":200,"ta":1,"rh":201}}'),
    (Rw '{"event":"push-main","outcome":"refused-gate-red","chain_touching":false,"leg_sec":{"rg":999,"ta":1,"rh":1}}'),
    (Rw '{"event":"pre-push","outcome":"landed","chain_touching":false,"leg_sec":{"rg":5,"ta":1,"rh":1}}'),
    [pscustomobject]@{ malformed = $true; text = '{' }
  )
  $sum = Measure-PtLandings -Rows $fx
  $c = @($sum | Where-Object { $_.kind -ceq 'chain' })[0]; $p = @($sum | Where-Object { $_.kind -ceq 'plain' })[0]
  T ($kMF + '  a chain landing without leg_sec is counted as a landing and never as a timing (3 landings, 2 timed)') ($c.landings -eq 3 -and $c.timed -eq 2) ('landings={0} timed={1}' -f $c.landings, $c.timed)
  T ($kMNF + '  a refused push, a pre-push row and a malformed line are not landings (plain landings 1)') ($p.landings -eq 1) ('plain={0}' -f $p.landings)
  T ($kCT + '  nearest-rank median of 900 and 1000 is 900 and the p90 is 1000') ($c.rh_med -eq 900 -and $c.rh_p90 -eq 1000) ('med={0} p90={1}' -f $c.rh_med, $c.rh_p90)
  T ($kMF + '  a plain push prints no rehearsal column, since its rh was the collection time before M1') ($null -eq $p.PSObject.Properties['rh_n']) ('rh_n present')
  T ($kCT + '  early_hit is split yes 1, no 1, not recorded 1 over 3') ($c.early_yes -eq 1 -and $c.early_no -eq 1 -and $c.early_unrecorded -eq 1) ('y={0} n={1} u={2}' -f $c.early_yes, $c.early_no, $c.early_unrecorded)
  T ($kCT + '  rehearsals sum 4 over 3 landings, and exactly the one at 3 counts as twice or more (the bar is 2)') ($c.rehearsals -eq 4 -and $c.rehearsed_2plus -eq 1) ('sum={0} 2plus={1}' -f $c.rehearsals, $c.rehearsed_2plus)
  $e = Measure-PtLandings -Rows @()
  T ($kMNF + '  no rows gives zero landings and -1 medians, never a 0 that reads as fast') (@($e | Where-Object { $_.landings -ne 0 }).Count -eq 0 -and @($e)[0].rg_med -eq -1) ('rg_med={0}' -f @($e)[0].rg_med)
  $expected = 7
  if (($script:pass + $script:fail) -ne $expected) { $script:fail++; Write-Output ('FAIL  ran {0} case(s) where this file holds {1}' -f ($script:pass + $script:fail), $expected) }
  if ($script:fail) { Write-Output ("report-push-time self-test FAIL: {0} of {1}" -f $script:fail, ($script:pass + $script:fail)); exit 1 }
  Write-Output ("report-push-time self-test PASS: {0} cases" -f $script:pass)
  exit 0
}

$dir = $(if ($Root) { $Root } else { Join-Path $env:LOCALAPPDATA 'ThriftyCrew\push-ledger' })
$files = @(Get-ChildItem -LiteralPath $dir -Filter 'pushes-*.jsonl' -File -ErrorAction SilentlyContinue | Sort-Object Name)
if ($From) { $files = @($files | Where-Object { $_.Name -ge ('pushes-' + $From) }) }
if ($To) { $files = @($files | Where-Object { $_.Name -le ('pushes-' + $To + '.jsonl') }) }
if (-not $files.Count) { Write-Output ('report-push-time: no ledger file under ' + $dir); Write-Output 'REPORT-PUSH-TIME-COMPLETE code=3 files=0'; exit 3 }
$all = @()
foreach ($f in $files) { $r = Read-TcPushRows -Path $f.FullName; $all += @($r) }
$bad = @($all | Where-Object { Get-PtProp $_ 'malformed' }).Count
Write-Output ('report-push-time: {0} file(s) {1}..{2}, {3} row(s), {4} malformed' -f $files.Count, $files[0].Name, $files[-1].Name, $all.Count, $bad)
$sum = Measure-PtLandings -Rows $all
foreach ($s in $sum) { Format-PtSummary $s }
if ($Rows) {
  $tsv = @("ts`tkind`toutcome`trg`tta`trh`tearly_hit`trehearsed`tpm_blob")
  foreach ($r in @($all | Where-Object { -not (Get-PtProp $_ 'malformed') -and [string](Get-PtProp $_ 'event') -ceq 'push-main' -and ([string](Get-PtProp $_ 'outcome')).StartsWith('landed') })) {
    $tsv += (@((Get-PtProp $r 'ts'), $(if ((Get-PtProp $r 'chain_touching') -eq $true) { 'chain' } else { 'plain' }), (Get-PtProp $r 'outcome'), (Get-PtLegSec $r 'rg'), (Get-PtLegSec $r 'ta'), (Get-PtLegSec $r 'rh'), (Get-PtProp $r 'early_hit'), (Get-PtProp $r 'rehearsed'), (Get-PtProp $r 'pm_blob')) -join "`t")
  }
  [IO.File]::WriteAllText($Rows, (($tsv -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
  Write-Output ('report-push-time: {0} row(s) written to {1}' -f ($tsv.Count - 1), $Rows)
}
Write-Output ('REPORT-PUSH-TIME-COMPLETE code=0 files={0} rows={1}' -f $files.Count, $all.Count)
exit 0
