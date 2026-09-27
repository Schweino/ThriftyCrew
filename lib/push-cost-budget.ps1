<#
  push-cost-budget.ps1 - what a push costs in gate time, per class, held by a mark that may only fall.

  B1 of design\PLAN-efficiency-budgets-2026-09-27.md, ruled by Brad 2026-09-27 ("Yes, all of it"). The gate-diet plan cut
  a data-only push from 748 s of gate work to 292 s and the 2026-09-27 safety fix (cc40a2820) put it back near 500 s,
  each step measured by hand from the gate-times rows. Nothing held the number between measurements, so a new check that
  declared no inputs could add its seconds to every data-only push and nobody would see it until the next hand count.

  THE NUMBER. Executed gate time of one full run-gates run: the sum of each job's own milliseconds over the jobs that
  RAN (not replayed from the cache). It is a sum of per-job wall times, which is the gate-diet plan's "gate CPU".

  THE CLASS, READ FROM THE RUN ITSELF, never from a guess about the push:
    data    - every static detector keyed on the code scan set (*.ps1 ...) replayed its pass: no code changed since this
              checkout's last run. The gate-diet plan's "data-only push" (its run C).
    code    - at least one of them ran: code changed.
    cold    - nothing replayed at all (a fresh cache: a first run, the diet plan's run A). Recorded, never judged.
    noreuse - -NoReuse forced every job. Recorded, never judged.
    unknown - no code-keyed static detector exists to read the class from. Recorded, never judged.

  THE VERDICT IS A MEDIAN, NEVER ONE RUN (.claude\rules\measurement.md ms-03): the median of the last MinRuns full,
  green runs of the class, this one included. A run is FULL when its job count is at least 90% of the largest in the
  window, so a fixture that runs run-gates over a sandbox of five gates never joins the sample. Fewer than MinRuns such
  runs, or no mark yet, is REPORT-ONLY: the number is printed and nothing fails. A plain run never writes the mark
  (og-11); ops\push-cost-budget.ps1 -Accept records one, only from MinRuns runs, and -Tighten records a fall.

  THE ROWS live beside the gate-times rows, outside the repo (%LOCALAPPDATA%\ThriftyCrew\gate-times\push-cost.jsonl, or
  TC_GATE_TIMES_ROOT; 'off' reads and writes nothing), appended through Add-TcLine. They are machine-local, like the
  gate cache whose hit rate they measure.

  WHAT IT DOES WHEN THE PRODUCER STOPS (og-13). If run-gates stops writing rows the sample stops growing and the budget
  stays report-only or holds on old rows; it cannot fire. ops\push-cost-budget.ps1 -Report prints the newest row's age
  and the weekly report carries it, which is where a stopped producer shows.

  Dot-source:  . (Join-Path $repoRoot 'lib\push-cost-budget.ps1')    Fixtures: ops\push-cost-budget.ps1 -SelfTest
  THIS FILE DECLARES NO param() BLOCK: dot-sourcing would run it in the caller's scope (lib\ratchet.ps1 has the account).
#>

# TUNING CONSTANTS (og-14). Nine runs: the first plausible odd window, not swept; at the 2026-09-27 rate of about 60 full
# runs a day it fills within hours, and one run moved by load cannot move a median of nine. 90% full-run share: a real
# run's job count moves by a handful as suites are added, a fixture's is a small fraction of it; not swept.
$script:TcPushCostMinRunsDefault = 9
$script:TcPushCostFullShare = 0.9

function Get-TcPushCostClass {
  <# The class of one run, from its own cache hits. Pure. #>
  param([int]$Reused, [int]$CodeKeyed, [int]$CodeKeyedReused, [bool]$NoReuse)
  if ($NoReuse) { return 'noreuse' }
  if ($Reused -le 0) { return 'cold' }
  if ($CodeKeyed -le 0) { return 'unknown' }
  if ($CodeKeyedReused -ge $CodeKeyed) { return 'data' }
  return 'code'
}

function Get-TcMedianValue {
  <# The median of a list of numbers, or $null for an empty list. Pure. #>
  param([double[]]$Values)
  $v = @($Values)
  if (-not $v.Count) { return $null }
  $s = @($v | Sort-Object)
  $mid = [int][math]::Floor($s.Count / 2)
  if ($s.Count % 2) { return [double]$s[$mid] }
  return ([double]$s[$mid - 1] + [double]$s[$mid]) / 2
}

function Read-TcPushCostRows {
  <# Every parseable row of the rows file, oldest first. A torn line is skipped, never fatal; an absent file is none. #>
  param([string]$Path, [int]$Tail = 0)
  $rows = [System.Collections.Generic.List[object]]::new()
  if (-not $Path -or -not [IO.File]::Exists($Path)) { return $rows.ToArray() }
  # -Tail parses only the newest lines, so run-gates' cost stays flat as the file grows (about 60 rows a day).
  $all = [IO.File]::ReadAllLines($Path)
  if ($Tail -gt 0 -and $all.Count -gt $Tail) { $all = $all[($all.Count - $Tail)..($all.Count - 1)] }
  foreach ($l in $all) {
    if (-not $l.Trim()) { continue }
    try { $rows.Add(($l | ConvertFrom-Json)) } catch { }
  }
  return $rows.ToArray()
}

function Select-TcPushCostSample {
  <# The newest -Last full, green runs of one class, oldest first: rc 0, and jobs at least the full share of the largest
     job count among that class's green rows. -Extra is this run, not yet written, judged as one more row. Pure. #>
  param($Rows, [string]$Class, [int]$Last, $Extra = $null)
  $all = [System.Collections.Generic.List[object]]::new()
  foreach ($r in @($Rows)) { if ($r -and [string]$r.class -ceq $Class -and [int]$r.rc -eq 0) { $all.Add($r) } }
  if ($null -ne $Extra -and [string]$Extra.class -ceq $Class -and [int]$Extra.rc -eq 0) { $all.Add($Extra) }
  if (-not $all.Count) { return ,@() }
  $maxJobs = 0; foreach ($r in $all) { if ([int]$r.jobs -gt $maxJobs) { $maxJobs = [int]$r.jobs } }
  $full = [System.Collections.Generic.List[object]]::new()
  foreach ($r in $all) { if ([double][int]$r.jobs -ge $script:TcPushCostFullShare * $maxJobs) { $full.Add($r) } }
  $arr = $full.ToArray()
  if ($arr.Count -gt $Last) { $arr = $arr[($arr.Count - $Last)..($arr.Count - 1)] }
  return ,$arr
}

function Get-TcPushCostVerdict {
  <# The budget's answer for one class: { State; Code; N; MedianS; MarkS; Why }.
       report-only - fewer than MinRuns runs, or no mark yet; never fails
       rose        - the median is over the mark: exit 2 for the run that sees it
       held        - at the mark
       can-tighten - under it; spoken, and the mark is kept (a plain run never writes)
     MarkS is untyped on purpose: $null is "no mark", which [int] would turn into a mark of 0. Pure. #>
  param([double[]]$SampleS, $MarkS, [int]$MinRuns)
  $s = @($SampleS)
  $med = Get-TcMedianValue -Values $s
  $o = [ordered]@{ State = 'report-only'; Code = 0; N = $s.Count; MedianS = $med; MarkS = $MarkS; Why = '' }
  if ($s.Count -lt $MinRuns) { $o.Why = ('{0} of the {1} runs a median needs' -f $s.Count, $MinRuns); return [pscustomobject]$o }
  if ($null -eq $MarkS) { $o.Why = 'no mark recorded yet: ops\push-cost-budget.ps1 -Accept -Class <class> records one'; return [pscustomobject]$o }
  if ($med -gt [double]$MarkS) { $o.State = 'rose'; $o.Code = 2 }
  elseif ($med -lt [double]$MarkS) { $o.State = 'can-tighten' }
  else { $o.State = 'held' }
  return [pscustomobject]$o
}

function Read-TcPushCostMarks {
  <# The committed marks: { State = read | absent | unreadable; MinRuns; Marks = @{ data; code } (seconds or $null); Doc; Why }.
     A class with no mark is $null, never 0. Never throws. #>
  param([string]$Path)
  $o = [ordered]@{ State = 'absent'; MinRuns = $script:TcPushCostMinRunsDefault; Marks = @{ data = $null; code = $null }; Doc = $null; Why = 'no such file' }
  if (-not $Path -or -not [IO.File]::Exists($Path)) { return [pscustomobject]$o }
  try { $d = [IO.File]::ReadAllText($Path) | ConvertFrom-Json } catch { $o.State = 'unreadable'; $o.Why = 'it does not parse as JSON'; return [pscustomobject]$o }
  if ($null -eq $d -or -not $d.PSObject.Properties['classes']) { $o.State = 'unreadable'; $o.Why = 'it has no classes field'; return [pscustomobject]$o }
  $o.Doc = $d
  if ($d.PSObject.Properties['min_runs'] -and ($d.min_runs -is [int] -or $d.min_runs -is [long]) -and [int]$d.min_runs -ge 1) { $o.MinRuns = [int]$d.min_runs }
  foreach ($c in @('data', 'code')) {
    $cp = $d.classes.PSObject.Properties[$c]
    if ($cp -and $null -ne $cp.Value -and $cp.Value.PSObject.Properties['mark_s'] -and $null -ne $cp.Value.mark_s) {
      $m = $cp.Value.mark_s
      if (($m -is [int] -or $m -is [long]) -and $m -ge 0) { $o.Marks[$c] = [int]$m }
      else { $o.State = 'unreadable'; $o.Why = ('classes.' + $c + '.mark_s is not a non-negative integer: ' + [string]$m); return [pscustomobject]$o }
    }
  }
  $o.State = 'read'; $o.Why = ''
  return [pscustomobject]$o
}

function Invoke-TcPushCostCheck {
  <# run-gates' whole use of this file, so run-gates grows by a few lines. From the run's own arrays: its class, its
     executed time, the verdict for its class, the lines to print, and the row to append once its exit code is known.
     OtherFailed: another gate already failed this run, so it is not a green run and does not join its own sample. #>
  param([string]$RowsPath, [string]$MarkPath, $AllRes, [bool[]]$CacheHit, [string[]]$UnkeyWhy, [int[]]$CodeKeyedIdx, [bool]$NoReuse, [bool]$OtherFailed, [string]$Run)
  $n = @($AllRes).Count
  $execMs = 0; $execJobs = 0; $unkMs = 0; $reused = 0
  for ($i = 0; $i -lt $n; $i++) {
    if ($CacheHit[$i]) { $reused++; continue }
    $ms = 0; if ($AllRes[$i]) { $ms = [int]$AllRes[$i].Ms }
    $execMs += $ms; $execJobs++
    if ($UnkeyWhy[$i]) { $unkMs += $ms }
  }
  $ckr = 0; foreach ($ix in @($CodeKeyedIdx)) { if ($CacheHit[$ix]) { $ckr++ } }
  $class = Get-TcPushCostClass -Reused $reused -CodeKeyed @($CodeKeyedIdx).Count -CodeKeyedReused $ckr -NoReuse $NoReuse
  $row = [ordered]@{ utc = [DateTime]::UtcNow.ToString('o'); run = $Run; class = $class; executed_ms = $execMs; executed_jobs = $execJobs; unkeyable_ms = $unkMs; reused = $reused; jobs = $n; rc = $(if ($OtherFailed) { 1 } else { 0 }) }
  $lines = [System.Collections.Generic.List[string]]::new()
  $v = $null
  if ($class -ceq 'data' -or $class -ceq 'code') {
    $mk = Read-TcPushCostMarks -Path $MarkPath
    $sample = Select-TcPushCostSample -Rows (Read-TcPushCostRows -Path $RowsPath -Tail 400) -Class $class -Last $mk.MinRuns -Extra ([pscustomobject]$row)
    $secs = @(@($sample) | ForEach-Object { [double]$_.executed_ms / 1000 })
    $markS = if ($mk.State -ceq 'read') { $mk.Marks[$class] } else { $null }
    $v = Get-TcPushCostVerdict -SampleS $secs -MarkS $markS -MinRuns $mk.MinRuns
    $medTxt = if ($null -ne $v.MedianS) { '{0:N0} s' -f $v.MedianS } else { '-' }
    $markTxt = if ($null -ne $markS) { '{0:N0} s' -f $markS } else { 'none' }
    $head = 'push-cost budget ({0} push): this run executed {1:N0} s of gate time, {2:N0} s of it unkeyable; median of the last {3} {0} run(s) {4}, mark {5}' -f $class, ($execMs / 1000), ($unkMs / 1000), $v.N, $medTxt, $markTxt
    $lines.Add($head)
    if ($mk.State -ceq 'unreadable') { $lines.Add('  the mark file is unreadable (' + $mk.Why + '), so this is report-only: a mark nobody can read is not a mark') }
    switch -CaseSensitive ($v.State) {
      'report-only' { $lines.Add('  REPORT-ONLY - ' + $v.Why + '; nothing fails on this number yet') }
      'rose'        { $lines.Add('  RATCHET BROKEN - the median is over the mark. A check that declares no inputs runs on every push; key it (lib\gate-input-key.ps1), or if the cost is the decision record it with ops\push-cost-budget.ps1 -Accept -Class ' + $class + ' and say why in the commit.') }
      'can-tighten' { $lines.Add('  ratchet CAN tighten: NOT written here. Record it with ops\push-cost-budget.ps1 -Tighten and commit ops\out\push-cost-budget.json.') }
      'held'        { }
      default       { throw ('Invoke-TcPushCostCheck: unknown verdict ' + $v.State) }
    }
  } else {
    $lines.Add(('push-cost budget: a {0} run ({1:N0} s executed) is recorded and not judged' -f $class, ($execMs / 1000)))
  }
  return [pscustomobject]@{ Class = $class; Verdict = $v; Lines = $lines.ToArray(); Row = $row }
}
