<#
  push-cost-budget.ps1 - what a push costs, held by a mark that may only fall.

  BRAD'S RULING (2026-09-27, supersedes the median-of-seconds verdict described below): the JUDGED number is the COUNT of
  gate jobs that run UNKEYED (Invoke-TcPushCostCheck). It does not move with load, so it needs no sample. The class and
  the seconds below are still recorded per run and read by the weekly report as a trend; nothing fails on them.

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
. (Join-Path $PSScriptRoot 'ratchet.ps1')   # Test-RatchetMove, Read-TcRatchetBaseline, Compare-TcRatchetSites
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

function Get-TcGateJobName {
  <# A job's gate as run-gates' gate-times rows name it: the first .ps1/.py argument below the repo, plus its first
     switch. Pure. #>
  param($Job, [string]$RepoFull)
  $n = ''; $a = ''
  foreach ($x in @($Job.ArgList)) { $s = [string]$x; if (-not $n -and $s -match '\.(ps1|py)$') { $n = $s } elseif ($n -and -not $a -and $s -match '^-') { $a = $s } }
  $rf = $RepoFull.TrimEnd('\') + '\'
  if ($n.StartsWith($rf, [StringComparison]::OrdinalIgnoreCase)) { $n = $n.Substring($rf.Length) }
  return (($n + ' ' + $a).Trim())
}

function Invoke-TcPushCostCheck {
  <# run-gates' whole use of this file. BRAD'S RULING (2026-09-27): the budget is the COUNT of jobs that ran UNKEYED,
     which run on every push including a data-only one, and a rise is refused; it does not move with load. Seconds stay
     in the row as a trend for the weekly report and are never judged. Judged only when the run could key at all
     (CodeKeyedIdx non-empty: a cache directory existed), since without one nothing is keyed and every job would read
     unkeyed. Writes nothing itself; returns the lines, the row and the unkeyed names (for -Accept's latest file). #>
  param([string]$RowsPath, [string]$MarkPath, $AllRes, [bool[]]$CacheHit, [string[]]$UnkeyWhy, [int[]]$CodeKeyedIdx, [bool]$NoReuse, [bool]$OtherFailed, [string]$Run, [string[]]$Names = @())
  $n = @($AllRes).Count
  $execMs = 0; $execJobs = 0; $unkMs = 0; $reused = 0
  $unk = [System.Collections.Generic.List[string]]::new()
  for ($i = 0; $i -lt $n; $i++) {
    if ($UnkeyWhy[$i]) { $unk.Add($(if ($i -lt @($Names).Count -and $Names[$i]) { [string]$Names[$i] } else { "job $i" })) }
    if ($CacheHit[$i]) { $reused++; continue }
    $ms = 0; if ($AllRes[$i]) { $ms = [int]$AllRes[$i].Ms }
    $execMs += $ms; $execJobs++
    if ($UnkeyWhy[$i]) { $unkMs += $ms }
  }
  $ckr = 0; foreach ($ix in @($CodeKeyedIdx)) { if ($CacheHit[$ix]) { $ckr++ } }
  $class = Get-TcPushCostClass -Reused $reused -CodeKeyed @($CodeKeyedIdx).Count -CodeKeyedReused $ckr -NoReuse $NoReuse
  $row = [ordered]@{ utc = [DateTime]::UtcNow.ToString('o'); run = $Run; class = $class; unkeyed_jobs = $unk.Count; executed_ms = $execMs; executed_jobs = $execJobs; unkeyable_ms = $unkMs; reused = $reused; jobs = $n; rc = $(if ($OtherFailed) { 1 } else { 0 }) }
  $lines = [System.Collections.Generic.List[string]]::new()
  $v = $null
  if (@($CodeKeyedIdx).Count -gt 0) {
    $rb = Read-TcRatchetBaseline -Path $MarkPath -Field 'unkeyed_jobs'
    $head = 'push-cost budget: {0} job(s) ran UNKEYED (they run on every push, a data-only one included); this {1} run executed {2:N0} s' -f $unk.Count, $class, ($execMs / 1000)
    if ($rb.State -cne 'read') {
      $lines.Add($head + '; mark ' + $rb.State)
      $lines.Add('  REPORT-ONLY - the mark is ' + $rb.State + ' (' + $rb.Why + '); record it with ops\push-cost-budget.ps1 -Accept')
    } else {
      $v = Test-RatchetMove -Name 'unkeyed jobs' -Count $unk.Count -Baseline $rb.Value
      $lines.Add($head + ('; mark {0}' -f $rb.Value))
      if ($v.Verdict -ceq 'rose') {
        $known = @(); if ($rb.Doc -and $rb.Doc.PSObject.Properties['names']) { $known = @($rb.Doc.names | ForEach-Object { [string]$_ }) }
        $cmp = Compare-TcRatchetSites -Current $unk.ToArray() -Baseline $known
        $lines.Add('  RATCHET BROKEN - more jobs run unkeyed than the mark allows. Key the new one (a `# gate-inputs:` or `# gate-scan:` line, lib\gate-input-key.ps1), or if it must run on every push record it with ops\push-cost-budget.ps1 -Accept and say why in the commit.')
        foreach ($x in @($cmp.New)) { $lines.Add('    new unkeyed: ' + $x) }
      } elseif ($v.Verdict -ceq 'tightened' -or $v.Verdict -ceq 'implausible') {
        $lines.Add('  ratchet CAN tighten (' + $v.Verdict + '): NOT written here. Record it with ops\push-cost-budget.ps1 -Tighten and commit ops\out\push-cost-budget.json.')
      }
    }
  } else {
    $lines.Add(('push-cost budget: no gate cache in this run, so nothing could be keyed; {0:N0} s executed, recorded and not judged' -f ($execMs / 1000)))
  }
  $code = 0; if ($v -and $v.Verdict -ceq 'rose') { $code = 2 }
  return [pscustomobject]@{ Class = $class; Code = $code; Verdict = $v; Unkeyed = $unk.ToArray(); Lines = $lines.ToArray(); Row = $row; Judged = (@($CodeKeyedIdx).Count -gt 0) }
}