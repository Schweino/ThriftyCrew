<#
  push-cost-budget.ps1 - read, record and fixture the push-cost budget run-gates judges on every full run.

  B1 of design\PLAN-efficiency-budgets-2026-09-27.md. The rule and its account are in lib\push-cost-budget.ps1; run-gates
  calls Invoke-TcPushCostCheck from it after every run. This file is the person's side:

    .\push-cost-budget.ps1                       report both classes: runs in the sample, median, mark, newest row's age
    .\push-cost-budget.ps1 -Json                 the same, plus one `push-cost-json: {...}` line (the weekly report reads it)
    .\push-cost-budget.ps1 -Accept -Class data   record the current median of that class as its mark (whole seconds,
                                                 rounded UP), only from a full sample; a deliberate rise goes here too,
                                                 with its reason in the commit
    .\push-cost-budget.ps1 -Tighten              record each class whose median fell below its mark
    .\push-cost-budget.ps1 -SelfTest             the plan's fixtures over the library, plus this file as a child

  A plain run never writes (og-11). -Accept on fewer runs than the sample needs is REFUSED, exit 3: a mark from one run
  is selection on noise (measurement.md ms-03).

  SCOPE OF A CLEAN REPORT: UNSOUND. The rows are this machine's, written only by run-gates at or after B1, and a run
  moved by load moves its row; the median of nine is the whole defence. A finding (a median over the mark) is real in
  what it measures: that many seconds of gates ran.

  Exit: 0 = reported or recorded. 2 = a class's median is over its mark (reported). 3 = could not evaluate or refused.
#>
# gate-inputs: ops\push-cost-budget.ps1, lib\push-cost-budget.ps1, lib\guard-contract.ps1, lib\append-line.ps1, lib\lf-write.ps1
[CmdletBinding()]
param([switch]$SelfTest, [switch]$Json, [switch]$Accept, [switch]$Tighten, [string]$Class = '', [string]$RowsFile = '', [string]$BaselineFile = '')
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\push-cost-budget.ps1')
. (Join-Path $repo 'lib\append-line.ps1')
. (Join-Path $repo 'lib\lf-write.ps1')

$script:PCB_NOTE = 'Marks for the push-cost budget (B1 of design/PLAN-efficiency-budgets-2026-09-27.md, ruled by Brad 2026-09-27): whole seconds of executed gate time, the median of the last min_runs full green run-gates runs of each class, read from the push-cost rows run-gates writes. null is no mark yet (report-only). A mark may only go DOWN; a deliberate rise is recorded with -Accept and its reason in the commit.'

function Get-PcbDefaultRowsPath {
  $root = $(if ($env:TC_GATE_TIMES_ROOT) { [string]$env:TC_GATE_TIMES_ROOT } elseif ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'ThriftyCrew\gate-times' } else { '' })
  if (-not $root -or $root -eq 'off') { return '' }
  return (Join-Path $root 'push-cost.jsonl')
}

function Write-PcbMarks([string]$Path, $Mk, [hashtable]$Marks) {
  $note = if ($Mk.Doc -and $Mk.Doc.note) { [string]$Mk.Doc.note } else { $script:PCB_NOTE }
  $doc = [ordered]@{ note = $note; generated = (Get-Date).ToString('s'); min_runs = [int]$Mk.MinRuns
    classes = [ordered]@{ data = [ordered]@{ mark_s = $Marks['data'] }; code = [ordered]@{ mark_s = $Marks['code'] } } }
  $dir = Split-Path $Path -Parent
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  return (Write-TcLfFile $Path ($doc | ConvertTo-Json -Depth 5))
}

if ($SelfTest) {
  $script:bad = 0; $script:cases = 0
  function T([string]$n, [bool]$ok, [string]$got) {
    $script:cases++
    if ($ok) { Write-Output ('  ok    ' + $n) } else { Write-Output ('  X     ' + $n + '   got: ' + $got); $script:bad++ }
  }
  $kMF = 'MUST' + ' FIRE'; $kMNF = 'MUST' + ' NOT FIRE'; $kCT = 'CLEAN' + ' TWIN'
  $wt = Join-Path $env:TEMP ('pcb-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $wt -ErrorAction Stop | Out-Null
  try {
    # ---- the class, read from the run's own cache hits ----
    T ($kMF + '  every code-keyed static detector replayed: a data push') ((Get-TcPushCostClass -Reused 40 -CodeKeyed 3 -CodeKeyedReused 3 -NoReuse $false) -ceq 'data') ''
    T ($kCT + '  one of them ran: a code push') ((Get-TcPushCostClass -Reused 40 -CodeKeyed 3 -CodeKeyedReused 2 -NoReuse $false) -ceq 'code') ''
    T ($kMNF + '  nothing replayed at all is a cold cache, never judged as a code push') ((Get-TcPushCostClass -Reused 0 -CodeKeyed 3 -CodeKeyedReused 0 -NoReuse $false) -ceq 'cold') ''
    T ($kMNF + '  -NoReuse is its own class, never judged') ((Get-TcPushCostClass -Reused 0 -CodeKeyed 3 -CodeKeyedReused 0 -NoReuse $true) -ceq 'noreuse') ''
    T ($kCT + '  the median of an even list is the mean of its middle two; of none, $null') (((Get-TcMedianValue @(1, 9, 3, 5)) -eq 4) -and ($null -eq (Get-TcMedianValue @()))) ''

    # ---- THE PLAN'S FIXTURES, through run-gates' own entry point over a data-only run ----
    # A data-only run: 10 jobs, jobs 0 and 1 are the code-keyed static detectors and replay, jobs 2..9 run 62.5 s each
    # (8 x 62.5 = 500 s). Nine of them fill the sample; the mark is 500 s.
    $rows = Join-Path $wt 'rows.jsonl'
    $mark = Join-Path $wt 'mark.json'
    $mk0 = [ordered]@{ note = 'fixture'; min_runs = 9; classes = [ordered]@{ data = [ordered]@{ mark_s = 500 }; code = [ordered]@{ mark_s = $null } } }
    $null = Write-TcLfFile $mark ($mk0 | ConvertTo-Json -Depth 5)
    function New-PcbRun([int]$ExtraMs, [bool]$ExtraKeyed, [int]$EachMs = 62500) {
      $res = [System.Collections.Generic.List[object]]::new(); $hit = [System.Collections.Generic.List[bool]]::new(); $why = [System.Collections.Generic.List[string]]::new()
      for ($i = 0; $i -lt 10; $i++) { $res.Add([pscustomobject]@{ Ms = $(if ($i -lt 2) { 0 } else { $EachMs }) }); $hit.Add($i -lt 2); $why.Add($(if ($i -eq 9) { 'unkeyable fixture' } else { '' })) }
      if ($ExtraMs -gt 0) { $res.Add([pscustomobject]@{ Ms = $ExtraMs }); $hit.Add($ExtraKeyed); $why.Add($(if ($ExtraKeyed) { '' } else { 'declares no inputs' })) }
      return @{ Res = $res.ToArray(); Hit = $hit.ToArray(); Why = $why.ToArray() }
    }
    function Invoke-PcbRun($R) {
      $c = Invoke-TcPushCostCheck -RowsPath $rows -MarkPath $mark -AllRes $R.Res -CacheHit $R.Hit -UnkeyWhy $R.Why -CodeKeyedIdx @(0, 1) -NoReuse $false -OtherFailed $false -Run 'fixture'
      $null = Add-TcLine -Path $rows -Text ($c.Row | ConvertTo-Json -Compress)
      return $c
    }
    $first = $null
    for ($k = 0; $k -lt 8; $k++) { $first = Invoke-PcbRun (New-PcbRun 0 $false) }
    T ($kMNF + '  8 data runs of the 9 the median needs is REPORT-ONLY, and says so') ($first.Verdict.State -ceq 'report-only' -and $first.Verdict.N -eq 8 -and ($first.Lines -join ' ') -match 'REPORT-ONLY - 8 of the 9') ("{0} n={1}" -f $first.Verdict.State, $first.Verdict.N)
    $ninth = Invoke-PcbRun (New-PcbRun 0 $false)
    T ($kCT + '  the ninth run is judged: its class is data, median 500 s AT the 500 s mark holds') ($ninth.Class -ceq 'data' -and $ninth.Verdict.State -ceq 'held' -and $ninth.Verdict.MedianS -eq 500) ("{0} {1} med={2}" -f $ninth.Class, $ninth.Verdict.State, $ninth.Verdict.MedianS)
    # AT THE BAR AND ONE STEP PAST IT (og-06), in the mark's own unit: a median of 501 s against 500 s.
    T ($kMF + '  a median ONE SECOND past the mark (501 s against 500 s) is a rise, exit 2') ((Get-TcPushCostVerdict -SampleS @(501, 501, 501, 501, 501, 501, 501, 501, 501) -MarkS 500 -MinRuns 9).Code -eq 2) ''
    T ($kMNF + '  no mark ($null, never read as 0) is report-only, however high the median') ((Get-TcPushCostVerdict -SampleS @(9999, 9999, 9999, 9999, 9999, 9999, 9999, 9999, 9999) -MarkS $null -MinRuns 9).State -ceq 'report-only') ''
    # A KEYED new gate: it replays on a data-only push, so the number does not move.
    $kd = $null; for ($k = 0; $k -lt 9; $k++) { $kd = Invoke-PcbRun (New-PcbRun 60000 $true) }
    T ($kMNF + '  a new KEYED gate on a data-only push replays: the median stays 500 s and holds') ($kd.Verdict.State -ceq 'held' -and $kd.Verdict.MedianS -eq 500) ("{0} med={1}" -f $kd.Verdict.State, $kd.Verdict.MedianS)
    # AN UNKEYED new gate: 60 s on every data-only push. Five runs move the median of nine.
    $uk = $null; $states = @()
    for ($k = 0; $k -lt 5; $k++) { $uk = Invoke-PcbRun (New-PcbRun 60000 $false); $states += $uk.Verdict.State }
    T ($kMF + '  a new UNKEYED gate on a data-only push raises the median past the mark (560 s against 500 s): RATCHET BROKEN') `
      ($uk.Verdict.State -ceq 'rose' -and $uk.Verdict.Code -eq 2 -and $uk.Verdict.MedianS -eq 560 -and ($uk.Lines -join ' ') -match 'RATCHET BROKEN') ("{0} med={1}" -f $uk.Verdict.State, $uk.Verdict.MedianS)
    T ($kCT + '  ...and not before the median moved: its first four runs still held (one slow run cannot break it)') ((@($states[0..3]) -join ',') -ceq 'held,held,held,held') ($states -join ',')
    T ($kCT + '  the unkeyable seconds are named on the line, so the pusher knows what to key') (($uk.Lines[0]) -match '123 s of it unkeyable') $uk.Lines[0]
    # A FALL: nine faster runs. Spoken, and the mark file is not touched.
    $markB64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($mark))
    $fl = $null; for ($k = 0; $k -lt 9; $k++) { $fl = Invoke-PcbRun (New-PcbRun 0 $false 50000) }
    $same = [string]::Equals($markB64, [Convert]::ToBase64String([IO.File]::ReadAllBytes($mark)), [StringComparison]::Ordinal)
    T ($kCT + '  a FALL (400 s against 500 s) is spoken ("CAN tighten") and the mark is KEPT') ($fl.Verdict.State -ceq 'can-tighten' -and $same -and ($fl.Lines -join ' ') -match 'CAN tighten') ("{0} unchanged={1}" -f $fl.Verdict.State, $same)
    # A FIXTURE'S OWN run-gates (5 jobs) never joins the sample of full runs.
    $small = [pscustomobject]@{ class = 'data'; rc = 0; jobs = 5; executed_ms = 1 }
    $smp = Select-TcPushCostSample -Rows (Read-TcPushCostRows -Path $rows) -Class 'data' -Last 9 -Extra $small
    T ($kMNF + '  a sandbox run of 5 jobs beside full runs of 10 is not a full run and does not join the sample') (@($smp | Where-Object { [int]$_.jobs -eq 5 }).Count -eq 0 -and @($smp).Count -eq 9) ("n={0}" -f @($smp).Count)
    $red = [pscustomobject]@{ class = 'data'; rc = 1; jobs = 10; executed_ms = 999999 }
    $smpR = Select-TcPushCostSample -Rows @() -Class 'data' -Last 9 -Extra $red
    T ($kMNF + '  a RED run does not join the sample, and an empty sample is empty, not one row of 0') (@($smpR).Count -eq 0) ("n={0}" -f @($smpR).Count)

    # ---- THE CLI, as a child ----
    $m2 = Join-Path $wt 'mark2.json'
    $null = Write-TcLfFile $m2 ([ordered]@{ note = 'fixture'; min_runs = 9; classes = [ordered]@{ data = [ordered]@{ mark_s = $null }; code = [ordered]@{ mark_s = $null } } } | ConvertTo-Json -Depth 5)
    $few = Join-Path $wt 'few.jsonl'
    foreach ($k in 1..3) { $null = Add-TcLine -Path $few -Text ('{"class":"data","rc":0,"jobs":10,"executed_ms":500000}') }
    $null = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -RowsFile $few -BaselineFile $m2 -Accept -Class data
    $rcA = $LASTEXITCODE
    $d2 = [IO.File]::ReadAllText($m2) | ConvertFrom-Json
    T ($kMF + '  -Accept from 3 runs is REFUSED (exit 3) and writes nothing: a mark from a few runs is selection on noise') ($rcA -eq 3 -and $null -eq $d2.classes.data.mark_s) ("rc=$rcA mark=$($d2.classes.data.mark_s)")
    $o5 = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -RowsFile $rows -BaselineFile $m2 -Accept -Class data)
    $rc5 = $LASTEXITCODE
    $d5 = [IO.File]::ReadAllText($m2) | ConvertFrom-Json
    T ($kCT + '  -Accept from a full sample records its median, rounded up to whole seconds (400), and only for that class') ($rc5 -eq 0 -and [int]$d5.classes.data.mark_s -eq 400 -and $null -eq $d5.classes.code.mark_s) ("rc=$rc5 data=$($d5.classes.data.mark_s) code=$($d5.classes.code.mark_s)")
    $b5 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($m2))
    $o6 = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -RowsFile $rows -BaselineFile $m2 -Json)
    $rc6 = $LASTEXITCODE
    $same6 = [string]::Equals($b5, [Convert]::ToBase64String([IO.File]::ReadAllBytes($m2)), [StringComparison]::Ordinal)
    $j6 = @($o6 | Where-Object { "$_" -like 'push-cost-json: *' })
    T ($kCT + '  a plain report writes nothing, exits 0 at the mark, and -Json carries both classes') ($rc6 -eq 0 -and $same6 -and $j6.Count -eq 1 -and ("$($j6[0])" -match '"data":') -and ("$($j6[0])" -match '"code":')) ("rc=$rc6 unchanged=$same6")
  } catch {
    $script:cases++; $script:bad++
    Write-Output ('  X     the suite threw: ' + $_.Exception.Message)
  } finally {
    Remove-Item -LiteralPath $wt -Recurse -Force -ErrorAction SilentlyContinue
  }
  $expected = 19
  if ($script:cases -ne $expected) { Write-Output ("  X     ran $($script:cases) case(s), expected $expected"); $script:bad++ }
  if ($script:bad -eq 0) { Write-Output ("PUSH-COST-BUDGET SELF-TEST PASS ($($script:cases) of $expected cases)"); Write-GuardComplete -Name 'push-cost-budget' -Summary "selftest ok cases=$($script:cases)"; exit 0 }
  Write-Output ("PUSH-COST-BUDGET SELF-TEST FAILED ($($script:bad))"); Write-GuardComplete -Name 'push-cost-budget' -Summary "selftest failed=$($script:bad)"; exit 2
}

# ---- live ----
$rowsPath = if ($RowsFile) { $RowsFile } else { Get-PcbDefaultRowsPath }
$markPath = if ($BaselineFile) { $BaselineFile } else { Join-Path $here 'out\push-cost-budget.json' }
$mk = Read-TcPushCostMarks -Path $markPath
if ($mk.State -cne 'read') {
  Write-Output ("push-cost-budget: COULD NOT EVALUATE - the mark file {0} is {1} ({2})." -f $markPath, $mk.State, $mk.Why)
  Exit-Guard -Name 'push-cost-budget' -Summary ('blind=mark-' + $mk.State) -Code 3
}
$allRows = Read-TcPushCostRows -Path $rowsPath
$newest = $null
foreach ($r in @($allRows)) { try { $t = [DateTime]::Parse([string]$r.utc).ToUniversalTime(); if ($null -eq $newest -or $t -gt $newest) { $newest = $t } } catch { } }
$ageTxt = if ($null -ne $newest) { '{0:N1} h ago' -f ([DateTime]::UtcNow - $newest).TotalHours } else { 'never' }
Write-Output ("push-cost-budget: {0} row(s) in {1}; newest {2}; a median needs {3} full green runs of a class" -f @($allRows).Count, $(if ($rowsPath) { $rowsPath } else { '(gate times off)' }), $ageTxt, $mk.MinRuns)
$out = [ordered]@{}
$worst = 0
foreach ($c in @('data', 'code')) {
  $sample = Select-TcPushCostSample -Rows $allRows -Class $c -Last $mk.MinRuns
  $secs = @(@($sample) | ForEach-Object { [double]$_.executed_ms / 1000 })
  $v = Get-TcPushCostVerdict -SampleS $secs -MarkS $mk.Marks[$c] -MinRuns $mk.MinRuns
  $out[$c] = [ordered]@{ n = $v.N; median_s = $(if ($null -ne $v.MedianS) { [math]::Round($v.MedianS, 1) } else { $null }); mark_s = $mk.Marks[$c]; state = $v.State; why = $v.Why }
  $medTxt = if ($null -ne $v.MedianS) { '{0:N0} s' -f $v.MedianS } else { '-' }
  $markTxt = if ($null -ne $mk.Marks[$c]) { '{0:N0} s' -f $mk.Marks[$c] } else { 'none' }
  Write-Output ("  {0,-5} {1} run(s), median {2}, mark {3}: {4}{5}" -f $c, $v.N, $medTxt, $markTxt, $v.State, $(if ($v.Why) { ' - ' + $v.Why } else { '' }))
  if ($v.Code -gt $worst) { $worst = $v.Code }
}
if ($Json) { Write-Output ('push-cost-json: ' + ([ordered]@{ known = $true; rows = @($allRows).Count; newest_utc = $(if ($newest) { $newest.ToString('o') } else { $null }); min_runs = $mk.MinRuns; classes = $out } | ConvertTo-Json -Depth 5 -Compress)) }
if ($Accept) {
  if ($Class -cne 'data' -and $Class -cne 'code') { Write-Output 'push-cost-budget: -Accept needs -Class data or -Class code.'; Exit-Guard -Name 'push-cost-budget' -Summary 'refused=no-class' -Code 3 }
  if ([int]$out[$Class].n -lt $mk.MinRuns -or $null -eq $out[$Class].median_s) {
    Write-Output ("push-cost-budget: -Accept REFUSED - the {0} sample holds {1} of the {2} runs a median needs. A mark from fewer is selection on noise; nothing written." -f $Class, $out[$Class].n, $mk.MinRuns)
    Exit-Guard -Name 'push-cost-budget' -Summary "refused=short-sample class=$Class n=$($out[$Class].n)" -Code 3
  }
  $marks = @{ data = $mk.Marks['data']; code = $mk.Marks['code'] }
  $marks[$Class] = [int][math]::Ceiling([double]$out[$Class].median_s)
  $null = Write-PcbMarks $markPath $mk $marks
  Write-Output ("  mark written: {0} = {1} s. Commit ops\out\push-cost-budget.json with the reason." -f $Class, $marks[$Class])
  Exit-Guard -Name 'push-cost-budget' -Summary "accepted class=$Class mark_s=$($marks[$Class])" -Code 0
}
if ($Tighten) {
  $marks = @{ data = $mk.Marks['data']; code = $mk.Marks['code'] }
  $moved = 0
  foreach ($c in @('data', 'code')) { if ($out[$c].state -ceq 'can-tighten') { $marks[$c] = [int][math]::Ceiling([double]$out[$c].median_s); $moved++ } }
  if ($moved) { $null = Write-PcbMarks $markPath $mk $marks; Write-Output "  ratchet tightened: $moved class(es). Commit ops\out\push-cost-budget.json." }
}
Exit-Guard -Name 'push-cost-budget' -Summary ("rows={0} data={1} code={2}" -f @($allRows).Count, $out['data'].state, $out['code'].state) -Code $worst
