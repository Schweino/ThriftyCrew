<#
  measure-gate-width.ps1 - what does ONE run-gates cost at pool width 1, 2, 5 and 10? A REPORT, never a gate.

  WHY IT EXISTS (2026-09-12, design\PLAN-push-ref-race-2026-09-11.md). The gate's measured width curve
  (design\MEASURE-gate-cost-2026-09-09.md) has points at 16, 24 and 32 ONLY, plus a single serial figure of 372s.
  The machine-wide budget is 10 (lib\gate-slots.ps1), and on 2026-09-11 18 of 19 grants were width 1 - so every
  number that matters for the queue sits in the part of the curve nobody has measured. gate-slots' own header says
  it: "what a lone run costs at 10 is unmeasured here".

  The decision it feeds: whether a MINIMUM GRANT WIDTH is worth building. A pool time-sliced into ten runs at
  width 1 is processor sharing; two runs at width 5 is batch service, identical in slot-seconds and far better in
  latency - but only if the curve between 1 and 10 is actually steep. If it is flat, that change buys nothing and
  the plan should say so.

  THE ACCEPTANCE BAR, WRITTEN BEFORE THE RUN (measurement.md E21; the exemplar is
  meal-prep\pipeline\bm25_dedup_probe.py:309). Stated in the metric's own units, wall seconds:

      A minimum grant width is worth building only if the MEDIAN WALL at width 5 is at most HALF the median
      wall at width 1. Below 2x, the latency the change buys does not pay for a new rule in the slot library,
      and PLAN-push-ref-race's recommendation 1 should be withdrawn rather than argued down.

  A second reading the same rows settle, with no bar because nothing is being decided on it: the width at which
  wall stops falling, which is where a minimum grant width would be set.

  *** THIS ONE ADDS GATE LOAD, WHICH ops\observe-gate-queue.ps1 DELIBERATELY DOES NOT. *** It runs the real
  ops\run-gates.ps1 once per replicate per width, through the NORMAL Enter-TcGateSlots path, so it never exceeds
  the machine-wide budget and queues like any push. But it is still N full gate runs, so -Sweep REFUSES to start
  on a box that is not quiet and ABORTS the moment another gate run appears. That refusal is the point: a width
  curve measured under contention measures the contention. It is not deliberate CPU load and must never be used as
  any - that is ops\cpu-load.ps1, and run-gates in a loop is the thing Brad ruled out on 2026-09-11.

  ARMS ARE INTERLEAVED, NEVER BLOCKED (1,2,5,10, 1,2,5,10, ...). Load on this box drifts over tens of minutes, and
  a blocked sweep would confound width with the time it ran at - which is the defect grocery\check-ad-cycles.ps1
  carries a block headed "THE MEASUREMENT WAS CONFOUNDED" for, where a wrapper measured an hour later reverted a
  working parallel path. Interleaving costs nothing and removes it.

  THE WIDTH RECORDED IS THE WIDTH REACHED, never the width asked. A lease grants up to what is free, so a run that
  asked 10 and was handed 3 ran at 3; recording the ask would record a condition the run never met. run-gates
  prints both ("pool width reached X of the Y asked") and both are kept, and -Report discards any row where they
  differ rather than averaging it in.

  WHAT wallGateS IS, so it is not misread later: run-gates starts its stopwatch at its line 147, before discovery
  and before it queues for a slot, so the number covers discovery plus any slot wait plus the pool plus judging.
  That is deliberate - it is exactly the window a push must win against a moving origin/main, which is the
  question PLAN-push-ref-race asks. On the quiet box this harness insists on, the slot wait is ~0 and the figure
  is the pool's; under contention it would not be, which is why othersStart and othersEnd are on every row and
  why -Report can name a contaminated one. wallHarnessS is the whole child process as this harness timed it, kept
  beside it so the two can be compared rather than trusted.

  ONE ROW PER RUN, AND EVERY TOTAL DERIVES FROM IT (measurement.md E24). A pair of medians cannot be
  un-aggregated; the CSV can. Each row carries its input fingerprint - HEAD sha, the gate count discovered, and
  the concurrent run-gates seen at start and end - so a row taken under contention can be found later rather than
  quietly weighting a median.

  SCOPE OF A CLEAN REPORT: this measures THIS box, on the tree at the recorded HEAD, at the moment it ran. It says
  nothing about a different machine, a different gate set, or the same widths under load - and the quiet it
  requires is the quiet it can SEE (run-gates processes and CPU), not an idle box. A sweep that completes proves
  the curve for the rows it kept; it does not prove the curve is stable across days.

  Usage:
    powershell -File ops\measure-gate-width.ps1 -Probe
    powershell -File ops\measure-gate-width.ps1 -Sweep -OutCsv <path> [-Widths '1,2,5,10'] [-Replicates 3]
    powershell -File ops\measure-gate-width.ps1 -Report -OutCsv <path>
#>
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop
param(
  [switch]$Probe,
  [switch]$Sweep,
  [switch]$Report,
  # A STRING, NOT [int[]], AND THE REASON IS A BUG THIS ALREADY HIT (2026-09-12). Under `powershell -File`,
  # `-Widths 1,2,5,10` arrives as the single STRING '1,2,5,10' - -File does no array parsing - and coercing it
  # to [int[]] does NOT fail: [int]'1,2,5,10' is 12510, because .NET parses thousands separators by default.
  # So the first sweep launched silently as ONE arm at width 12510, which the lease clamps to 10, and every row
  # would have been dropped for a reached width that did not match. It announced "sweeping widths 12510" and
  # that line is the only reason it was caught. Parsed here instead, where a non-numeric entry can refuse.
  [string]$Widths = '1,2,5,10',
  [int]$Replicates = 3,
  [string]$OutCsv = '',
  [int]$MaxOtherRuns = 0,
  # THE CPU ADMISSION LEVEL WAS 60 AND IS NOW 85, CHANGED AFTER SEEING IT REFUSE (2026-09-12). Recorded rather
  # than quietly edited, because a threshold moved after it fires is the shape measurement.md warns about.
  # WHAT CHANGED IS THE ADMISSION CONDITION, NOT THE ACCEPTANCE BAR: $BarRatio is untouched, so what the sweep
  # must show to earn its recommendation is exactly what it had to show before.
  # The evidence: 134 probes from 05:58 to 09:24 found the box quiet in 1, and at 09:31 it read 0 other gate
  # runs at 63% CPU - gate-free, and refused anyway. This box idles at 35-65% with ~140 Claude sessions live,
  # so a 60% bar excludes nearly every genuinely gate-free moment while excluding almost nothing that would
  # corrupt the curve. What corrupts a WIDTH curve is (a) another gate run holding the slots this one needs,
  # which is $MaxOtherRuns and is separately caught per row by widthReached, and (b) so little free CPU that
  # extra workers have no core to run on. At 85% of 32 processors about 5 remain, which still separates width
  # 1 from width 10; at 100% it would not. NOT A SWEEP - one reasoned move, and the first value was itself
  # only the first plausible number. Every row carries its own othersStart/othersEnd and the CPU at the time,
  # so a reader who disagrees with this level can re-judge the rows rather than re-run them.
  [int]$MaxCpuPct = 85,
  [switch]$Force
)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\ops' }
$repo = Split-Path $here -Parent

# THE BAR, ONCE, AS DATA - so -Report cannot quietly judge against a different number than the header states.
$script:BarRatio = 0.5
$script:BarFrom = 1
$script:BarAt = 5

function Get-OtherGateRuns {
  <# How many run-gates processes are live that are NOT this process's own child. Assign, THEN wrap: a
     comma-returned array reads as one element and an empty result would count 1 (ps-json-array-collapse). #>
  param([int]$ExcludePid = 0)
  $found = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -match 'run-gates' -and $_.ProcessId -ne $PID -and $_.ProcessId -ne $ExcludePid }
  $arr = @($found)
  return $arr.Count
}

function Get-CpuPct {
  $c = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Measure-Object -Property LoadPercentage -Average
  if ($null -eq $c -or $null -eq $c.Average) { return -1 }
  return [int]$c.Average
}

function Get-QuietReason {
  <# '' when the box is quiet enough to measure a width curve on; a sentence naming what is in the way otherwise.
     A could-not-look at CPU (-1) is NOT treated as quiet: an unreadable instrument settles nothing.
     THE CALLER SUPPLIES THE READINGS, so the sentence names the same numbers the caller printed. Reading the
     instruments again in here made -Probe say "CPU = 87%" and "CPU at 76%, over the 60% allowed" in consecutive
     lines, off two reads of a moving value - a report contradicting itself about its own evidence. #>
  param([int]$Others, [int]$Cpu, [int]$MaxOther, [int]$MaxCpu)
  $why = @()
  if ($Others -gt $MaxOther) { $why += ('{0} other run-gates process(es) live, over the {1} allowed' -f $Others, $MaxOther) }
  if ($Cpu -lt 0) { $why += 'CPU load could not be read, and a could-not-look is not quiet' }
  elseif ($Cpu -gt $MaxCpu) { $why += ('CPU at {0}%, over the {1}% allowed' -f $Cpu, $MaxCpu) }
  return ($why -join '; ')
}

if ($Probe) {
  $others = Get-OtherGateRuns
  $cpu = Get-CpuPct
  $why = Get-QuietReason -Others $others -Cpu $cpu -MaxOther $MaxOtherRuns -MaxCpu $MaxCpuPct
  Write-Output ('measure-gate-width: other run-gates live = {0}, CPU = {1}%' -f $others, $cpu)
  if ($why) { Write-Output ('measure-gate-width: NOT QUIET - ' + $why) }
  else { Write-Output 'measure-gate-width: QUIET - a sweep would measure width rather than contention.' }
  Write-Output ('MEASURE-GATE-WIDTH-COMPLETE mode=probe quiet={0} others={1} cpu={2}' -f $(if ($why) { 'no' } else { 'yes' }), $others, $cpu)
  exit 0
}

if ($Sweep) {
  if (-not $OutCsv) {
    Write-Output 'measure-gate-width: -Sweep needs -OutCsv <path>. It is the record every total is derived from, so it is never defaulted.'
    Write-Output 'MEASURE-GATE-WIDTH-COMPLETE mode=sweep rows=0 aborted=no-outcsv'
    exit 3
  }
  $why = Get-QuietReason -Others (Get-OtherGateRuns) -Cpu (Get-CpuPct) -MaxOther $MaxOtherRuns -MaxCpu $MaxCpuPct
  if ($why -and -not $Force) {
    Write-Output ('measure-gate-width: REFUSING to sweep - ' + $why + '.')
    Write-Output '          A width curve taken under contention measures the contention. Wait for a quiet box, or pass -Force'
    Write-Output '          and know that every row is then a loaded-box row.'
    Write-Output ('MEASURE-GATE-WIDTH-COMPLETE mode=sweep rows=0 aborted=not-quiet')
    exit 3
  }
  $widthList = [Collections.Generic.List[int]]::new()
  foreach ($wTok in ([string]$Widths -split ',')) {
    $t = ([string]$wTok).Trim()
    if (-not $t) { continue }
    $n = 0
    # NumberStyles::None, so '1,2,5,10' can never arrive here as ONE number again - the default styles accept
    # thousands separators, which is exactly how that string became the single width 12510.
    if (-not [int]::TryParse($t, [Globalization.NumberStyles]::None, [Globalization.CultureInfo]::InvariantCulture, [ref]$n) -or $n -lt 1) {
      Write-Output ("measure-gate-width: -Widths entry '{0}' is not a positive whole number." -f $t)
      Write-Output 'MEASURE-GATE-WIDTH-COMPLETE mode=sweep rows=0 aborted=bad-widths'
      exit 3
    }
    $widthList.Add($n)
  }
  if ($widthList.Count -eq 0) {
    Write-Output 'measure-gate-width: -Widths parsed to nothing, so there is no arm to run.'
    Write-Output 'MEASURE-GATE-WIDTH-COMPLETE mode=sweep rows=0 aborted=bad-widths'
    exit 3
  }
  $sweepWidths = $widthList.ToArray()
  $gate = Join-Path $repo 'ops\run-gates.ps1'
  if (-not (Test-Path -LiteralPath $gate)) {
    Write-Output 'measure-gate-width: ops\run-gates.ps1 is missing, so there is nothing to time.'
    Write-Output 'MEASURE-GATE-WIDTH-COMPLETE mode=sweep rows=0 aborted=no-gate'
    exit 3
  }
  $psexe = (Get-Command powershell).Source
  $headSha = ''
  try {
    $prevEapG = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $headSha = (& git -C $repo rev-parse HEAD) } finally { $ErrorActionPreference = $prevEapG }
    $headSha = ([string]$headSha).Trim()
  } catch { $headSha = 'unknown' }

  $rows = [Collections.Generic.List[object]]::new()
  $order = 0
  $aborted = ''
  Write-Output ('measure-gate-width: sweeping widths {0}, {1} replicate(s) each, INTERLEAVED, at HEAD {2}' -f (($sweepWidths | ForEach-Object { [string]$_ }) -join ' '), $Replicates, $headSha)
  Write-Output ('measure-gate-width: the bar, stated before the run - median wall at width {0} must be at most {1:P0} of median wall at width {2}' -f $script:BarAt, $script:BarRatio, $script:BarFrom)
  for ($rep = 1; ($rep -le $Replicates) -and (-not $aborted); $rep++) {
    foreach ($w in $sweepWidths) {
      $why2 = Get-QuietReason -Others (Get-OtherGateRuns) -Cpu (Get-CpuPct) -MaxOther $MaxOtherRuns -MaxCpu $MaxCpuPct
      if ($why2 -and -not $Force) {
        $aborted = $why2
        Write-Output ('measure-gate-width: ABORTING after {0} row(s) - the box stopped being quiet: {1}' -f $rows.Count, $why2)
        break
      }
      $order++
      $othersStart = Get-OtherGateRuns
      $cpuStart = Get-CpuPct
      $sw = [Diagnostics.Stopwatch]::StartNew()
      # A NATIVE CHILD'S STDERR IS NOT REDIRECTED UNDER 'Stop' (.claude\rules\ops-and-gates.md): every redirect
      # makes its first stderr line a terminating throw, and a catch around it would throw the answer away. The
      # preference is lowered as its own statement before the call, and restored in finally.
      $prevEap = $ErrorActionPreference
      $ErrorActionPreference = 'Continue'
      $out = $null; $rc = -1
      try {
        $out = & $psexe -NoProfile -ExecutionPolicy Bypass -File $gate -Jobs $w -NoReuse
        $rc = $LASTEXITCODE
      } finally {
        $ErrorActionPreference = $prevEap
      }
      $sw.Stop()
      $othersEnd = Get-OtherGateRuns
      $cpuEnd = Get-CpuPct
      $lines = @($out)
      $text = ($lines -join "`n")
      # run-gates:761  "timing: N gate(s), Xs wall at width Y. Zs of gate work inside it, ..."
      $gates = 0; $wallS = 0.0; $workS = 0.0; $widthDispatch = 0; $widthReached = 0
      if ($text -match 'timing:\s*([\d,]+)\s*gate\(s\),\s*([\d,]+)s wall at width\s*(\d+)\.\s*([\d,]+)s of gate work') {
        $gates = [int](($Matches[1]) -replace ',', '')
        $wallS = [double](($Matches[2]) -replace ',', '')
        $widthDispatch = [int]$Matches[3]
        $workS = [double](($Matches[4]) -replace ',', '')
      }
      if ($text -match 'pool width reached\s*(\d+)\s*of the\s*(\d+)\s*asked') { $widthReached = [int]$Matches[1] }
      $passed = 0; $failed = 0
      if ($text -match 'run-gates:\s*([\d,]+) passed,\s*([\d,]+) failed') {
        $passed = [int](($Matches[1]) -replace ',', '')
        $failed = [int](($Matches[2]) -replace ',', '')
      }
      $rows.Add([pscustomobject]@{
          order        = $order
          replicate    = $rep
          widthAsked   = $w
          widthDispatch = $widthDispatch
          widthReached = $widthReached
          wallHarnessS = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
          wallGateS    = $wallS
          workS        = $workS
          gates        = $gates
          passed       = $passed
          failed       = $failed
          rc           = $rc
          othersStart  = $othersStart
          othersEnd    = $othersEnd
          cpuStart     = $cpuStart
          cpuEnd       = $cpuEnd
          headSha      = $headSha
          atUtc        = [DateTimeOffset]::UtcNow.ToString('o')
        })
      Write-Output ('  rep {0} asked {1,2} -> reached {2,2}: {3,6:N0}s wall ({4,6:N0}s harness), {5,6:N0}s work over {6} gate(s), rc {7}, others {8}/{9}, cpu {10}/{11}%' -f `
          $rep, $w, $widthReached, $wallS, $sw.Elapsed.TotalSeconds, $workS, $gates, $rc, $othersStart, $othersEnd, $cpuStart, $cpuEnd)
    }
  }
  $hdr = 'order,replicate,widthAsked,widthDispatch,widthReached,wallHarnessS,wallGateS,workS,gates,passed,failed,rc,othersStart,othersEnd,cpuStart,cpuEnd,headSha,atUtc'
  $body = foreach ($x in $rows) {
    ('{0},{1},{2},{3},{4},{5},{6},{7},{8},{9},{10},{11},{12},{13},{14},{15},{16},{17}' -f $x.order, $x.replicate, $x.widthAsked, $x.widthDispatch, $x.widthReached,
      $x.wallHarnessS, $x.wallGateS, $x.workS, $x.gates, $x.passed, $x.failed, $x.rc, $x.othersStart, $x.othersEnd, $x.cpuStart, $x.cpuEnd, $x.headSha, $x.atUtc)
  }
  $all = @($hdr) + @($body)
  $dir = Split-Path $OutCsv -Parent
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Force $dir }
  [IO.File]::WriteAllText($OutCsv, (($all -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
  Write-Output ('measure-gate-width: wrote {0} row(s) to {1}' -f $rows.Count, $OutCsv)
  Write-Output ('MEASURE-GATE-WIDTH-COMPLETE mode=sweep rows={0} aborted={1}' -f $rows.Count, $(if ($aborted) { 'yes' } else { 'no' }))
  exit $(if ($rows.Count -eq 0) { 3 } else { 0 })
}

if ($Report) {
  if (-not $OutCsv -or -not (Test-Path -LiteralPath $OutCsv)) {
    Write-Output 'measure-gate-width: -Report needs -OutCsv <path> naming a sweep that has already run.'
    Write-Output 'MEASURE-GATE-WIDTH-COMPLETE mode=report rows=0'
    exit 3
  }
  $csv = Import-Csv -LiteralPath $OutCsv
  $all = @($csv)
  Write-Output ('measure-gate-width: {0} row(s) in {1}' -f $all.Count, $OutCsv)
  if ($all.Count -eq 0) {
    Write-Output 'MEASURE-GATE-WIDTH-COMPLETE mode=report rows=0'
    exit 3
  }
  # WHAT DISQUALIFIES A ROW, and the two things that deliberately do NOT.
  #   - A REACHED width that is not the ASKED width ran at a different width. A lease grants what is free, so
  #     recording the ask would record a condition the run never met.
  #   - A row with no timing line ran no gates at all (exit 3: the slot wait, or a push that cannot land).
  #   - A row over a DIFFERENT NUMBER OF GATES is not the same job. Discovery grows as the tree does, and
  #     comparing a 362-gate run against a 200-gate one is comparing two workloads and calling it width. The
  #     modal count wins and every other row is named. This is the one that would have corrupted the result
  #     silently rather than loudly.
  # NOT disqualifying: a NON-ZERO exit. A red run still dispatches and times every gate, so its wall is as
  # valid as a green one's - dropping it would let an unrelated failing gate invalidate a whole sweep. Only
  # exit 3 matters here, and the no-timing-line rule already catches it. rc is kept on every row regardless.
  $timed = @($all | Where-Object { [double]$_.wallGateS -gt 0 -and [int]$_.gates -gt 0 })
  $modalGates = 0
  if ($timed.Count) {
    $counts = @{}
    foreach ($x in $timed) { $k = [int]$x.gates; $counts[$k] = 1 + [int]$counts[$k] }
    $best = -1
    foreach ($k in $counts.Keys) { if ($counts[$k] -gt $best) { $best = $counts[$k]; $modalGates = $k } }
  }
  $ok = { param($r) ([int]$r.widthReached -eq [int]$r.widthAsked) -and ([double]$r.wallGateS -gt 0) -and ([int]$r.gates -eq $modalGates) }
  $usable = @($all | Where-Object { & $ok $_ })
  $dropped = @($all | Where-Object { -not (& $ok $_) })
  Write-Output ('measure-gate-width: usable {0} of {1} row(s), all over {2} gate(s); {3} dropped' -f $usable.Count, $all.Count, $modalGates, $dropped.Count)
  foreach ($d in $dropped) {
    $why = @()
    if ([int]$d.widthReached -ne [int]$d.widthAsked) { $why += ('reached {0} not the {1} asked' -f $d.widthReached, $d.widthAsked) }
    if ([double]$d.wallGateS -le 0) { $why += 'no timing line, so no gate ran' }
    elseif ([int]$d.gates -ne $modalGates) { $why += ('{0} gates, not the modal {1}' -f $d.gates, $modalGates) }
    Write-Output ('   dropped: asked {0} rc {1} wall {2}s others {3}/{4} cpu {5}/{6} - {7}' -f $d.widthAsked, $d.rc, $d.wallGateS, $d.othersStart, $d.othersEnd, $d.cpuStart, $d.cpuEnd, ($why -join '; '))
  }
  function Get-Median {
    param([double[]]$Values)
    $v = @($Values | Sort-Object)
    if ($v.Count -eq 0) { return 0.0 }
    if ($v.Count % 2 -eq 1) { return [double]$v[[int](($v.Count - 1) / 2)] }
    return ([double]$v[$v.Count / 2 - 1] + [double]$v[$v.Count / 2]) / 2.0
  }
  $byWidth = @{}
  foreach ($x in $usable) {
    $k = [int]$x.widthReached
    if (-not $byWidth.ContainsKey($k)) { $byWidth[$k] = [Collections.Generic.List[object]]::new() }
    $byWidth[$k].Add($x)
  }
  Write-Output ''
  Write-Output 'width | n | median wall s | min | max | median gate work s'
  Write-Output '------|---|---------------|-----|-----|-------------------'
  $medians = @{}
  foreach ($k in ($byWidth.Keys | Sort-Object)) {
    $grp = @($byWidth[$k])
    $walls = @($grp | ForEach-Object { [double]$_.wallGateS })
    $works = @($grp | ForEach-Object { [double]$_.workS })
    $med = Get-Median -Values $walls
    $medians[$k] = $med
    $sorted = @($walls | Sort-Object)
    Write-Output ('{0,5} | {1,1} | {2,13:N0} | {3,3:N0} | {4,3:N0} | {5,18:N0}' -f $k, $grp.Count, $med, $sorted[0], $sorted[$sorted.Count - 1], (Get-Median -Values $works))
  }
  Write-Output ''
  # THE BAR, JUDGED AGAINST THE SAME CONSTANTS THE HEADER STATES.
  $haveFrom = $medians.ContainsKey($script:BarFrom)
  $haveAt = $medians.ContainsKey($script:BarAt)
  if (-not ($haveFrom -and $haveAt)) {
    Write-Output ('measure-gate-width: the bar CANNOT BE JUDGED - it needs usable rows at width {0} and width {1}, and this sweep has {2}.' -f $script:BarFrom, $script:BarAt, (($medians.Keys | Sort-Object) -join ','))
    Write-Output ('MEASURE-GATE-WIDTH-COMPLETE mode=report rows={0} usable={1} verdict=unjudged' -f $all.Count, $usable.Count)
    exit 3
  }
  $ratio = $medians[$script:BarAt] / $medians[$script:BarFrom]
  $met = $ratio -le $script:BarRatio
  Write-Output ('THE BAR (written before the run): median wall at width {0} at most {1:P0} of width {2}.' -f $script:BarAt, $script:BarRatio, $script:BarFrom)
  Write-Output ('  measured: {0:N0}s at width {1} against {2:N0}s at width {3} = {4:P0}  ->  {5}' -f `
      $medians[$script:BarAt], $script:BarAt, $medians[$script:BarFrom], $script:BarFrom, $ratio, $(if ($met) { 'BAR MET - a minimum grant width is worth building' } else { 'BAR NOT MET - withdraw that recommendation' }))
  Write-Output ('  n per point: ' + (($medians.Keys | Sort-Object | ForEach-Object { '{0}={1}' -f $_, @($byWidth[$_]).Count }) -join ' '))
  Write-Output ('MEASURE-GATE-WIDTH-COMPLETE mode=report rows={0} usable={1} verdict={2} ratio={3:N2}' -f $all.Count, $usable.Count, $(if ($met) { 'bar-met' } else { 'bar-not-met' }), $ratio)
  exit 0
}

Write-Output 'measure-gate-width: pick a mode - -Probe (is the box quiet), -Sweep (run it), -Report (totals from a sweep).'
Write-Output 'MEASURE-GATE-WIDTH-COMPLETE mode=none'
exit 3
