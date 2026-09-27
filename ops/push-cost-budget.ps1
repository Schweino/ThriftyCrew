<#
  push-cost-budget.ps1 - read, record and fixture the push-cost budget run-gates judges on every run.

  B1 of design\PLAN-efficiency-budgets-2026-09-27.md. BRAD'S RULING (2026-09-27): the budget is the COUNT of gate jobs
  that run UNKEYED, which run on every push, a data-only one included; a rise is refused. The count does not move with
  load, so its mark is taken from the current tree at once. Seconds stay a trend in the weekly report, never judged.
  The rule lives in lib\push-cost-budget.ps1 (Invoke-TcPushCostCheck); run-gates calls it after every run and writes
  the newest run's unkeyed job names to push-cost-unkeyed-latest.json beside the gate-times rows.

    .\push-cost-budget.ps1              report: the newest run's unkeyed count against the mark, and the seconds trend
    .\push-cost-budget.ps1 -Json        the same, plus one `push-cost-json: {...}` line (the weekly report reads it)
    .\push-cost-budget.ps1 -Accept      record the newest run's unkeyed count and names as the mark (a deliberate rise
                                        goes here, with its reason in the commit)
    .\push-cost-budget.ps1 -Tighten     record a fall
    .\push-cost-budget.ps1 -SelfTest    Brad's three fixtures through run-gates' own entry point, plus this file as a child

  A plain run never writes (og-11). No latest file (run-gates has not run here since B1) is exit 3 for -Accept.

  SCOPE OF A CLEAN REPORT: COMPLETE for a rise (each unkeyed job is a job that runs on every push), UNSOUND for cost (a
  keyed job whose key is too wide also re-runs on data, og-45, and is not counted here; the seconds trend shows it).

  Exit: 0 = reported or recorded. 2 = the newest count is over the mark. 3 = could not evaluate or refused.
#>
# gate-inputs: ops\push-cost-budget.ps1, lib\push-cost-budget.ps1, lib\ratchet.ps1, lib\guard-contract.ps1, lib\append-line.ps1, lib\lf-write.ps1
[CmdletBinding()]
param([switch]$SelfTest, [switch]$Json, [switch]$Accept, [switch]$Tighten, [string]$RowsFile = '', [string]$LatestFile = '', [string]$BaselineFile = '')
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\push-cost-budget.ps1')
. (Join-Path $repo 'lib\append-line.ps1')
. (Join-Path $repo 'lib\lf-write.ps1')

$script:PCB_NOTE = 'Mark for the push-cost budget (B1 of design/PLAN-efficiency-budgets-2026-09-27.md; Brad ruled 2026-09-27 that it counts jobs, not seconds): the number of gate jobs run-gates runs UNKEYED, which run on every push including a data-only one, and their names. May only go DOWN; a deliberate rise is recorded with -Accept and its reason in the commit.'

function Get-PcbGtRoot {
  $root = $(if ($env:TC_GATE_TIMES_ROOT) { [string]$env:TC_GATE_TIMES_ROOT } elseif ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'ThriftyCrew\gate-times' } else { '' })
  if ($root -eq 'off') { return '' }
  return $root
}
function Write-PcbMark([string]$Path, $Doc, [string[]]$Names) {
  $note = if ($Doc -and $Doc.note) { [string]$Doc.note } else { $script:PCB_NOTE }
  $sorted = @($Names | Sort-Object)
  $json = [ordered]@{ note = $note; generated = (Get-Date).ToString('s'); unkeyed_jobs = $sorted.Count; names = $sorted } | ConvertTo-Json -Depth 4
  return (Write-TcLfFile $Path $json)
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
    $mark = Join-Path $wt 'mark.json'
    $null = Write-PcbMark $mark $null @('a.ps1 -SelfTest', 'b.ps1 -SelfTest')
    # A data-only run of 6 jobs: 0 and 1 are code-keyed static detectors that replay; 2 and 3 are keyed and replay;
    # 4 and 5 run UNKEYED (a.ps1, b.ps1). Its count is 2, AT the mark of 2.
    function New-PcbRun([string]$Extra = '', [bool]$ExtraKeyed = $false) {
      $names = [System.Collections.Generic.List[string]]::new(); $res = [System.Collections.Generic.List[object]]::new(); $hit = [System.Collections.Generic.List[bool]]::new(); $why = [System.Collections.Generic.List[string]]::new()
      foreach ($j in @(@('s1.ps1', $true, ''), @('s2.ps1', $true, ''), @('k1.ps1', $true, ''), @('k2.ps1', $true, ''), @('a.ps1 -SelfTest', $false, 'unkeyed'), @('b.ps1 -SelfTest', $false, 'unkeyed'))) {
        $names.Add($j[0]); $hit.Add($j[1]); $why.Add($j[2]); $res.Add([pscustomobject]@{ Ms = 60000 })
      }
      if ($Extra) { $names.Add($Extra); $hit.Add($ExtraKeyed); $why.Add($(if ($ExtraKeyed) { '' } else { 'declares no inputs' })); $res.Add([pscustomobject]@{ Ms = 60000 }) }
      return Invoke-TcPushCostCheck -RowsPath '' -MarkPath $mark -AllRes $res.ToArray() -CacheHit $hit.ToArray() -UnkeyWhy $why.ToArray() -CodeKeyedIdx @(0, 1) -NoReuse $false -OtherFailed $false -Run 'fx' -Names $names.ToArray()
    }
    $base = New-PcbRun
    T ($kCT + '  the tree as marked: 2 unkeyed jobs AT a mark of 2 holds, exit 0, and the run reads as data-only') ($base.Code -eq 0 -and $base.Verdict.Verdict -ceq 'held' -and $base.Class -ceq 'data') ("code=$($base.Code) {0} {1}" -f $base.Verdict.Verdict, $base.Class)
    $unkRun = New-PcbRun 'new-gate.ps1 -SelfTest' $false
    T ($kMF + '  a new gate with NO key raises the count to 3, one past the mark of 2, and fails with exit 2') ($unkRun.Code -eq 2 -and $unkRun.Verdict.Verdict -ceq 'rose') ("code=$($unkRun.Code)")
    T ($kMF + '  ...and the refusal names the new unkeyed gate, so the pusher knows what to key') (($unkRun.Lines -join "`n") -match 'new unkeyed: new-gate\.ps1 -SelfTest') ($unkRun.Lines -join ' | ')
    $good = New-PcbRun 'new-gate.ps1 -SelfTest' $true
    T ($kMNF + '  a new KEYED gate leaves the count at 2 and holds') ($good.Code -eq 0 -and $good.Verdict.Verdict -ceq 'held') ("code=$($good.Code)")
    $null = Write-PcbMark $mark $null @('a.ps1 -SelfTest', 'b.ps1 -SelfTest', 'c.ps1 -SelfTest')
    $markB64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($mark))
    $fall = New-PcbRun
    $same = [string]::Equals($markB64, [Convert]::ToBase64String([IO.File]::ReadAllBytes($mark)), [StringComparison]::Ordinal)
    T ($kCT + '  a FALL (2 against a mark of 3) is reported ("CAN tighten"), exit 0, and the mark file is byte-identical') ($fall.Code -eq 0 -and $same -and ($fall.Lines -join ' ') -match 'CAN tighten') ("code=$($fall.Code) same=$same")
    $nc = Invoke-TcPushCostCheck -RowsPath '' -MarkPath $mark -AllRes @([pscustomobject]@{ Ms = 1 }) -CacheHit @($false) -UnkeyWhy @('x') -CodeKeyedIdx @() -NoReuse $false -OtherFailed $false -Run 'fx'
    T ($kMNF + '  a run with no gate cache (nothing could be keyed) is not judged') ($nc.Code -eq 0 -and -not $nc.Judged) ("code=$($nc.Code)")
    $noMark = Invoke-TcPushCostCheck -RowsPath '' -MarkPath (Join-Path $wt 'absent.json') -AllRes @([pscustomobject]@{ Ms = 1 }) -CacheHit @($true) -UnkeyWhy @('') -CodeKeyedIdx @(0) -NoReuse $false -OtherFailed $false -Run 'fx'
    T ($kMNF + '  no mark file is REPORT-ONLY, never a rise and never a minted mark') ($noMark.Code -eq 0 -and ($noMark.Lines -join ' ') -match 'REPORT-ONLY') ($noMark.Lines -join ' | ')

    # ---- the CLI, as a child ----
    $latest = Join-Path $wt 'latest.json'
    [IO.File]::WriteAllText($latest, '{"utc":"2026-09-27T20:00:00Z","names":["b.ps1 -SelfTest","a.ps1 -SelfTest"]}')
    $m2 = Join-Path $wt 'mark2.json'
    $null = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -LatestFile (Join-Path $wt 'none.json') -BaselineFile $m2 -Accept
    T ($kMF + '  -Accept with no latest run is refused, exit 3, and writes nothing') ($LASTEXITCODE -eq 3 -and -not (Test-Path -LiteralPath $m2)) ("rc=$LASTEXITCODE")
    $null = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -LatestFile $latest -BaselineFile $m2 -Accept
    $rcA = $LASTEXITCODE
    $d = [IO.File]::ReadAllText($m2) | ConvertFrom-Json
    T ($kCT + '  -Accept records the newest run''s count (2) and its names, sorted') ($rcA -eq 0 -and [int]$d.unkeyed_jobs -eq 2 -and ((@($d.names) -join ',') -ceq 'a.ps1 -SelfTest,b.ps1 -SelfTest')) ("rc=$rcA n=$($d.unkeyed_jobs)")
    $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($m2))
    $o = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -LatestFile $latest -BaselineFile $m2 -RowsFile (Join-Path $wt 'rows.jsonl') -Json)
    $rcR = $LASTEXITCODE
    $same2 = [string]::Equals($b64, [Convert]::ToBase64String([IO.File]::ReadAllBytes($m2)), [StringComparison]::Ordinal)
    T ($kCT + '  a plain report exits 0 at the mark, writes nothing, and -Json carries the count and the mark') ($rcR -eq 0 -and $same2 -and (($o -join "`n") -match '"unkeyed_jobs":2') -and (($o -join "`n") -match '"mark":2')) ("rc=$rcR same=$same2")
  } catch {
    $script:cases++; $script:bad++
    Write-Output ('  X     the suite threw: ' + $_.Exception.Message)
  } finally {
    Remove-Item -LiteralPath $wt -Recurse -Force -ErrorAction SilentlyContinue
  }
  $expected = 10
  if ($script:cases -ne $expected) { Write-Output ("  X     ran $($script:cases) case(s), expected $expected"); $script:bad++ }
  if ($script:bad -eq 0) { Write-Output ("PUSH-COST-BUDGET SELF-TEST PASS ($($script:cases) of $expected cases)"); Write-GuardComplete -Name 'push-cost-budget' -Summary "selftest ok cases=$($script:cases)"; exit 0 }
  Write-Output ("PUSH-COST-BUDGET SELF-TEST FAILED ($($script:bad))"); Write-GuardComplete -Name 'push-cost-budget' -Summary "selftest failed=$($script:bad)"; exit 2
}

# ---- live ----
$gt = Get-PcbGtRoot
$latestPath = if ($LatestFile) { $LatestFile } elseif ($gt) { Join-Path $gt 'push-cost-unkeyed-latest.json' } else { '' }
$rowsPath = if ($RowsFile) { $RowsFile } elseif ($gt) { Join-Path $gt 'push-cost.jsonl' } else { '' }
$markPath = if ($BaselineFile) { $BaselineFile } else { Join-Path $here 'out\push-cost-budget.json' }
$latest = $null
if ($latestPath -and [IO.File]::Exists($latestPath)) { try { $latest = [IO.File]::ReadAllText($latestPath) | ConvertFrom-Json } catch { $latest = $null } }
$names = if ($latest) { @($latest.names | ForEach-Object { [string]$_ }) } else { @() }
$rb = Read-TcRatchetBaseline -Path $markPath -Field 'unkeyed_jobs'
if ($Accept) {
  if (-not $latest) { Write-Output ("push-cost-budget: -Accept REFUSED - no newest run at {0}; run ops\run-gates.ps1 once first. Nothing written." -f $latestPath); Exit-Guard -Name 'push-cost-budget' -Summary 'refused=no-latest' -Code 3 }
  $null = Write-PcbMark $markPath $rb.Doc $names
  Write-Output ("  mark written: {0} unkeyed job(s), from the run at {1}. Commit ops\out\push-cost-budget.json with the reason." -f $names.Count, $latest.utc)
  Exit-Guard -Name 'push-cost-budget' -Summary "accepted unkeyed_jobs=$($names.Count)" -Code 0
}
# The seconds trend: median executed time of the newest 9 full green data-only runs, for the report only.
$sample = Select-TcPushCostSample -Rows (Read-TcPushCostRows -Path $rowsPath -Tail 400) -Class 'data' -Last 9
$secs = @(@($sample) | ForEach-Object { [double]$_.executed_ms / 1000 })
$med = Get-TcMedianValue -Values $secs
$cur = if ($latest) { $names.Count } else { $null }
$mk = if ($rb.State -ceq 'read') { $rb.Value } else { $null }
$state = 'report-only'; $code = 0
if ($null -ne $cur -and $null -ne $mk) {
  $v = Test-RatchetMove -Name 'unkeyed jobs' -Count $cur -Baseline $mk
  $state = $v.Verdict; if ($v.Verdict -ceq 'rose') { $code = 2 }
  if ($Tighten -and $v.Verdict -ceq 'tightened') { $null = Write-PcbMark $markPath $rb.Doc $names; Write-Output "  ratchet tightened to $cur. Commit ops\out\push-cost-budget.json." }
}
Write-Output ("push-cost-budget: {0} unkeyed job(s) in the newest run ({1}), mark {2}: {3}. Data-only push time, a trend only: median {4} over {5} run(s)." -f $(if ($null -ne $cur) { $cur } else { '?' }), $(if ($latest) { $latest.utc } else { 'none recorded' }), $(if ($null -ne $mk) { $mk } else { $rb.State }), $state, $(if ($null -ne $med) { '{0:N0} s' -f $med } else { '-' }), $secs.Count)
if ($Json) { Write-Output ('push-cost-json: ' + ([ordered]@{ known = ($null -ne $cur); unkeyed_jobs = $cur; mark = $mk; state = $state; data_median_s = $(if ($null -ne $med) { [math]::Round($med, 1) } else { $null }); data_runs = $secs.Count } | ConvertTo-Json -Compress)) }
Exit-Guard -Name 'push-cost-budget' -Summary ("unkeyed={0} mark={1} state={2}" -f $cur, $mk, $state) -Code $code
