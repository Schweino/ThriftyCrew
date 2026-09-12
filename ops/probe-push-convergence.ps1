<#
  probe-push-convergence.ps1 - can a push on this box converge? Reports how long pushes wait, how often the remote
  moves while they wait, how fast main moves, and how the refused ones were refused.

  Run:        powershell -File ops\probe-push-convergence.ps1
              powershell -File ops\probe-push-convergence.ps1 -Days 2
  Self-test:  powershell -File ops\probe-push-convergence.ps1 -SelfTest

  WHY IT IS COMMITTED RATHER THAN DESCRIBED (2026-09-12, measurement.md). The push path was rebuilt three times in
  two days and every verdict on it was a scratch probe: named in a design document, described beside its number, and
  gone. When the next morning asked whether the fix had held, re-running the measurement meant WRITING IT AGAIN, and
  a rewritten probe is a second harness however faithful the description was. The test is whether the question can
  recur, and this one recurs every time somebody touches the hook.

  WHAT IT READS, and what each source can and cannot say:

  1. THE PUSH LEDGER (lib\push-ledger.ps1) - one row per push through ops\hold-push-lock.ps1 or ops\push-main.ps1,
     carrying the lock wait and the remote head before and after it. This is the only source that can answer "did
     the remote move WHILE THIS PUSH WAITED", because it is the only one recorded at the moment it happened. It sees
     nothing from a checkout older than the ledger, nothing from --no-verify, and nothing from another machine.

  2. THE SHARED origin/main REFLOG - refs/remotes/origin/main lives in the ONE .git every worktree on this box
     shares, and every landing from this box writes an "update by push" entry with a timestamp. So it is a complete
     machine-wide record of LANDINGS, and the interval between them is how long a freshly fetched base stays fresh.
     It says nothing about pushes that did not land.

  3. THE RETAINED PRE-PUSH GATE LOGS (%TEMP%\tc-prepush-*.log) - and this one comes with a warning that is the whole
     reason this file exists. ops\hooks\pre-push DELETES its log on the path where the gate passed, so what survives
     is the refusals and the runs still in flight. Measured 2026-09-12 at 10:40: 240 retained logs, of which 54 said
     blind=push-cannot-land and 46 blind=no-gate-worker-slot - and not one of them was a push that landed. Every
     rate taken from that pile has REFUSALS as its denominator, never pushes, and this report says so on the line.

  IT IS A REPORT, NOT A GATE. There is no threshold here and there must not be one: ops-and-gates.md forbids a gate
  that is red on day one, and any bar on push waits would be red on the first busy morning and teach --no-verify.
  Nothing in the estate reads its output to decide anything.

  Exit 0 = a report was produced. 3 = it could resolve NOTHING to report on, which is never "the box is healthy".

  SCOPE OF A CLEAN REPORT: every figure here is over what this box recorded. A quiet ledger means nobody pushed
  through an instrumented checkout, never that nobody waited - which is why the resolved counts are printed beside
  every rate and an empty source is named rather than folded into a zero.
#>
[CmdletBinding()]
param(
  [int]$Days = 1,
  [string]$LedgerRoot = '',
  [string]$LogDir = '',
  [string]$ReflogFile = '',
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path -Parent $here
. (Join-Path $repo 'lib\push-ledger.ps1')

function Get-TcReflogLandings {
  <# The timestamps of every landing, from `git reflog show --date=iso` output. PURE, so the parse has fixtures.

     ONLY "update by push" COUNTS. A fetch or a pull entry records this checkout catching up with a landing it may
     have missed by hours, so counting those would put several timestamps on one landing and shrink every interval
     below. The reflog is shared by every worktree on this box, so the push entries are the box's landings. #>
  param($Lines)
  $out = [Collections.Generic.List[datetime]]::new()
  foreach ($ln in @($Lines)) {
    $t = [string]$ln
    if ($t -notmatch 'update by push') { continue }
    if ($t -notmatch '@\{([^}]+)\}') { continue }
    $parsed = [datetime]::MinValue
    if ([datetime]::TryParse($Matches[1], [ref]$parsed)) { $out.Add($parsed) }
  }
  return $out.ToArray()
}

function Measure-TcLandingIntervals {
  <# How long a freshly fetched base stays fresh: the gaps between consecutive landings, in seconds.

     THE DENOMINATOR IS PRINTED BY THE CALLER and is the gap COUNT, which is one less than the landing count - a
     single landing has no interval at all and must not read as an interval of zero. #>
  param($Times)
  $t = @(@($Times) | Sort-Object)
  if ($t.Count -lt 2) {
    return [pscustomobject]@{ Landings = $t.Count; Gaps = 0; MedianSec = -1; P90Sec = -1; MinSec = -1; SpanHours = 0.0; PerHour = -1.0 }
  }
  $gaps = [Collections.Generic.List[double]]::new()
  for ($i = 1; $i -lt $t.Count; $i++) { $gaps.Add(($t[$i] - $t[$i - 1]).TotalSeconds) }
  $sorted = @($gaps | Sort-Object)
  $span = ($t[$t.Count - 1] - $t[0]).TotalHours
  return [pscustomobject]@{
    Landings  = $t.Count
    Gaps      = $sorted.Count
    MedianSec = (Get-TcPushPercentile $sorted 0.5)
    P90Sec    = (Get-TcPushPercentile $sorted 0.9)
    MinSec    = $sorted[0]
    SpanHours = [math]::Round($span, 2)
    PerHour   = $(if ($span -gt 0) { [math]::Round($t.Count / $span, 2) } else { -1.0 })
  }
}

function Get-TcPrepushBlindToken {
  <# Which cause a retained pre-push gate log reports, from its text. PURE.
     '' means the log names none - a red gate, or a run still in flight - and it is reported as its own class rather
     than folded into any of the named ones. #>
  param([string]$Text)
  $m = [regex]::Matches([string]$Text, 'blind=([A-Za-z0-9_-]+)')
  if ($m.Count -eq 0) { return '' }
  return $m[$m.Count - 1].Groups[1].Value
}

function Measure-TcPrepushLogs {
  <# Classify the retained pre-push logs under a directory. Returns the counts by blind token, the total, and
     whether the directory could be read at all - a directory that is not there is BLIND, never an empty count. #>
  param([string]$Dir, [int]$Days = 1)
  if (-not $Dir -or -not (Test-Path -LiteralPath $Dir)) {
    return [pscustomobject]@{ Blind = $true; Why = ('there is no log directory at ' + $Dir); Total = 0; Classes = @{} }
  }
  $cut = [datetime]::Now.AddDays(-$Days)
  $files = @(Get-ChildItem -LiteralPath $Dir -Filter 'tc-prepush-*.log' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -ge $cut })
  $classes = @{}
  # THE LATEST TIME EACH CAUSE WAS SEEN, which is the half that answers "is this still happening": the push path was
  # reordered twice on 2026-09-12, and a count alone cannot tell a class that stopped at 07:41 from one still firing.
  $latest = @{}
  foreach ($fi in $files) {
    $txt = ''
    try { $txt = [IO.File]::ReadAllText($fi.FullName) } catch { $txt = '' }
    $tok = Get-TcPrepushBlindToken -Text $txt
    $key = $(if ($tok) { $tok } else { '(no blind token: a red gate, or still running)' })
    if (-not $classes.ContainsKey($key)) { $classes[$key] = 0; $latest[$key] = $fi.LastWriteTime }
    $classes[$key] = $classes[$key] + 1
    if ($fi.LastWriteTime -gt $latest[$key]) { $latest[$key] = $fi.LastWriteTime }
  }
  return [pscustomobject]@{ Blind = $false; Why = ''; Total = $files.Count; Classes = $classes; Latest = $latest }
}

function Get-TcGitReflogLines {
  <# The reflog for one ref, or @() when it cannot be read. Uses the process API rather than a redirect: under
     EAP=Stop a native child's first stderr line is a terminating throw (ops-and-gates.md). #>
  param([string]$Dir, [string]$Ref)
  try {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = 'git'
    $psi.Arguments = ('-C "' + $Dir + '" reflog show --date=iso ' + $Ref)
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $p = [Diagnostics.Process]::Start($psi)
    try {
      $o = $p.StandardOutput.ReadToEndAsync()
      $e = $p.StandardError.ReadToEndAsync()
      $null = $e.Result
      if (-not $p.WaitForExit(30000)) { return @() }
      if ($p.ExitCode -ne 0) { return @() }
      return @(([string]$o.Result) -split "`r?`n" | Where-Object { $_.Trim() })
    } finally { $p.Dispose() }
  } catch {
    return @()
  }
}

function Write-TcConvergenceReport {
  <# The report itself, from already-gathered parts, so every line has a fixture. Returns the number of SOURCES that
     resolved: 0 means nothing could be looked at, which its caller turns into an exit 3.

     EVERY RATE CARRIES ITS DENOMINATOR (measurement.md). A push that never queued is not in the wait distribution,
     a row that could not read the ref is UNKNOWN rather than "did not move", and the retained-log counts say out
     loud that their population is the refusals. #>
  param($Ledger, $Landings, $Logs, [int]$Days)
  $resolved = 0
  $say = { param([string]$t) [Console]::Out.WriteLine($t) }
  & $say ("push convergence over the last {0} day(s), on this box" -f $Days)
  & $say ''

  & $say '1. THE PUSH LEDGER - the only source that can say whether the remote moved WHILE a push waited.'
  if ($Ledger.Rows -eq 0) {
    & $say '   NO ROWS. Nobody has pushed through an instrumented checkout since the ledger started, so this'
    & $say '   question is unanswered here - it is not a zero. Older checkouts, --no-verify and other machines'
    & $say '   write nothing, by construction.'
  } else {
    $resolved++
    & $say ("   rows={0} (malformed={1}), of which {2} actually queued for the lock" -f $Ledger.Rows, $Ledger.Malformed, $Ledger.Waited)
    if ($Ledger.Waited -gt 0) {
      & $say ("   wait for the push lock: median {0:N1}s, p90 {1:N1}s, max {2:N1}s over {3} queued push(es)" -f `
        ($Ledger.WaitMedianMs / 1000), ($Ledger.WaitP90Ms / 1000), ($Ledger.WaitMaxMs / 1000), $Ledger.Waited)
    } else {
      & $say '   no push in this window waited for the lock at all, so there is no wait distribution to report'
    }
    if ($Ledger.WaitedComparable -gt 0) {
      $pct = 100.0 * $Ledger.MovedWhileWaiting / $Ledger.WaitedComparable
      & $say ("   the remote MOVED while the push waited in {0} of {1} queued push(es) that could be compared ({2:N0}%)" -f `
        $Ledger.MovedWhileWaiting, $Ledger.WaitedComparable, $pct)
    } else {
      & $say '   no queued push could be compared, so the moved-while-waiting rate has no denominator and is not reported'
    }
    if ($Ledger.Unknown -gt 0) {
      & $say ("   {0} row(s) could not read the remote head and are UNKNOWN - they are in neither half of that rate" -f $Ledger.Unknown)
    }
  }
  & $say ''

  & $say '2. LANDINGS on origin/main, from the .git every worktree on this box shares.'
  if ($Landings.Landings -lt 2) {
    & $say ("   {0} landing(s) in this window, which is not enough for an interval. Nothing is claimed about how fast main moves." -f $Landings.Landings)
  } else {
    $resolved++
    & $say ("   {0} landing(s) over {1:N2}h = {2:N2} per hour" -f $Landings.Landings, $Landings.SpanHours, $Landings.PerHour)
    & $say ("   a freshly fetched base stays fresh for: median {0:N0}s, p90 {1:N0}s, shortest {2:N0}s, over {3} gap(s)" -f `
      $Landings.MedianSec, $Landings.P90Sec, $Landings.MinSec, $Landings.Gaps)
    & $say '   READ THIS AGAINST THE WAIT ABOVE. A push whose critical window is longer than the median gap is'
    & $say '   more likely than not to come out of it stale, and retrying restarts the same clock.'
  }
  & $say ''

  & $say '3. RETAINED pre-push gate logs - REFUSALS ONLY. The hook deletes its log when the gate passed, so a push'
  & $say '   that landed is absent by construction and these counts are over refusals, never over pushes.'
  if ($Logs.Blind) {
    & $say ("   COULD NOT LOOK: {0}" -f $Logs.Why)
  } else {
    $resolved++
    & $say ("   {0} retained log(s) in this window" -f $Logs.Total)
    foreach ($k in @($Logs.Classes.Keys | Sort-Object)) {
      $when = ''
      if ($Logs.PSObject.Properties['Latest'] -and $Logs.Latest.ContainsKey($k)) {
        $when = ('   last seen ' + ([datetime]$Logs.Latest[$k]).ToString('yyyy-MM-dd HH:mm'))
      }
      & $say ("     {0,4}  {1}{2}" -f $Logs.Classes[$k], $k, $when)
    }
    if ($Logs.Total -gt 0 -and -not $Logs.Classes.ContainsKey('push-cannot-land')) {
      & $say '   none of them is push-cannot-land, so no push in this window queued and then found the remote had'
      & $say '   moved past what it was built on.'
    }
  }
  & $say ''
  return $resolved
}

if ($SelfTest) {
  $f = 0; $cases = 0
  $kMF = 'MUST' + ' FIRE'; $kMNF = 'MUST' + ' NOT FIRE'; $kCT = 'CLEAN' + ' TWIN'
  function T($m, $cond, $got) {
    $script:cases++
    if ($cond) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $got); $script:f++ }
  }
  # A unique directory per run: run-gates runs every self-test and pre-push runs run-gates, so concurrent pushes run
  # this file over each other in one %TEMP%.
  $tmp = Join-Path $env:TEMP ('tc-ppc-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
  $null = New-Item -ItemType Directory -Force -ErrorAction Stop $tmp
  try {
    # ---- the reflog parse, on a frozen fixture of real lines ----
    # Written as single-quoted literals and collected into a variable: a fixture built by concatenation inside an
    # array literal binds the comma tighter than the + and runs on one line (ops-and-gates.md).
    $l1 = '88c7a835c refs/remotes/origin/main@{2026-09-12 10:26:13 -0500}: update by push'
    $l2 = '4fea00111 refs/remotes/origin/main@{2026-09-12 10:24:09 -0500}: update by push'
    $l3 = 'fe664e694 refs/remotes/origin/main@{2026-09-12 10:06:47 -0500}: update by push'
    $l4 = '7d1b27af2 refs/remotes/origin/main@{2026-09-12 09:42:26 -0500}: fetch origin main: fast-forward'
    $lines = @($l1, $l2, $l3, $l4)
    $landings = Get-TcReflogLandings $lines
    T ($kMNF + '  every "update by push" entry is read as a landing, with its timestamp') `
      (@($landings).Count -eq 3) ("landings={0}" -f @($landings).Count)
    # A FETCH IS NOT A LANDING. Counting one would put two timestamps on a single landing and halve every interval
    # below it, which is how a box would report itself twice as busy as it is.
    T ($kMF + '  a fetch or pull entry is NOT counted as a landing, so an interval is never shortened by a checkout catching up') `
      (@($landings | Where-Object { $_.Hour -eq 9 }).Count -eq 0) ("nineOClockEntries={0}" -f @($landings | Where-Object { $_.Hour -eq 9 }).Count)

    $iv = Measure-TcLandingIntervals $landings
    T ($kCT + '  the intervals between landings are reported with the GAP count, which is one less than the landings') `
      ($iv.Landings -eq 3 -and $iv.Gaps -eq 2 -and $iv.MinSec -eq 124) ("landings={0} gaps={1} min={2}" -f $iv.Landings, $iv.Gaps, $iv.MinSec)
    $one = Measure-TcLandingIntervals @([datetime]'2026-09-12 10:00:00')
    T ($kMF + '  a single landing has NO interval and reports -1, never an interval of zero') `
      ($one.Gaps -eq 0 -and $one.MedianSec -eq -1 -and $one.PerHour -eq -1.0) ("gaps={0} median={1} perHour={2}" -f $one.Gaps, $one.MedianSec, $one.PerHour)
    $none = Measure-TcLandingIntervals @()
    T ($kMNF + '  no landings at all reports zero landings rather than throwing or inventing a rate') `
      ($none.Landings -eq 0 -and $none.MedianSec -eq -1) ("landings={0} median={1}" -f $none.Landings, $none.MedianSec)

    # ---- the blind-token classifier ----
    $tokLine = 'RUN-GATES-COMPLETE blind=push-cannot-land'
    T ($kMNF + '  the blind token a gate log reports is read from its marker') `
      ((Get-TcPrepushBlindToken -Text $tokLine) -eq 'push-cannot-land') ("token={0}" -f (Get-TcPrepushBlindToken -Text $tokLine))
    # THE LAST MARKER WINS. A log holding an earlier run's marker as well would otherwise be classified by the wrong
    # one, and these files are appended to by whatever the hook ran.
    $twoLine = "RUN-GATES-COMPLETE blind=no-gate-worker-slot`nRUN-GATES-COMPLETE blind=push-cannot-land"
    T ($kMF + '  a log carrying two markers is classified by the LAST one, not the first') `
      ((Get-TcPrepushBlindToken -Text $twoLine) -eq 'push-cannot-land') ("token={0}" -f (Get-TcPrepushBlindToken -Text $twoLine))
    T ($kMNF + '  a log with no marker at all classifies as no token rather than as any named cause') `
      ((Get-TcPrepushBlindToken -Text 'nothing here') -eq '') ("token={0}" -f (Get-TcPrepushBlindToken -Text 'nothing here'))

    # ---- the log walk, against a fixture directory ----
    $ld = Join-Path $tmp 'logs'; $null = New-Item -ItemType Directory -Force $ld
    [IO.File]::WriteAllText((Join-Path $ld 'tc-prepush-1.log'), 'RUN-GATES-COMPLETE blind=push-cannot-land')
    [IO.File]::WriteAllText((Join-Path $ld 'tc-prepush-2.log'), 'RUN-GATES-COMPLETE blind=push-cannot-land')
    [IO.File]::WriteAllText((Join-Path $ld 'tc-prepush-3.log'), 'RUN-GATES-COMPLETE pass=387 fail=1')
    [IO.File]::WriteAllText((Join-Path $ld 'unrelated.txt'), 'blind=push-cannot-land')
    $lg = Measure-TcPrepushLogs -Dir $ld -Days 1
    T ($kMNF + '  the log walk counts each retained gate log by its cause, and reads only the gate logs') `
      ((-not $lg.Blind) -and $lg.Total -eq 3 -and $lg.Classes['push-cannot-land'] -eq 2) `
      ("blind={0} total={1} cannotLand={2}" -f $lg.Blind, $lg.Total, $lg.Classes['push-cannot-land'])
    # WHEN A CAUSE WAS LAST SEEN, not just how often. A count cannot tell a refusal class that stopped this morning
    # from one still firing, and that difference is the whole question after a reorder of the push path.
    $old = Get-Item -LiteralPath (Join-Path $ld 'tc-prepush-1.log')
    $old.LastWriteTime = [datetime]'2026-09-12 06:00:00'
    $lg2 = Measure-TcPrepushLogs -Dir $ld -Days 3650
    T ($kMF + '  each cause reports when it was LAST seen, so a class that has stopped can be told from one still firing') `
      ($lg2.Latest['push-cannot-land'] -gt ([datetime]'2026-09-12 06:00:00')) ("latest={0}" -f $lg2.Latest['push-cannot-land'])
    # A DIRECTORY THAT IS NOT THERE IS BLIND, NEVER AN EMPTY COUNT - the empty-result shape this estate has been
    # bitten by five times.
    $lgMissing = Measure-TcPrepushLogs -Dir (Join-Path $tmp 'no-such-dir') -Days 1
    T ($kMF + '  a log directory that cannot be read reports BLIND with a reason, never a clean count of zero') `
      ($lgMissing.Blind -and $lgMissing.Why) ("blind={0} why={1}" -f $lgMissing.Blind, $lgMissing.Why)

    # ---- the report, and the count of sources it actually resolved ----
    $A = '1111111111111111111111111111111111111111'
    $B = '2222222222222222222222222222222222222222'
    $rows = @(
      (New-TcPushRowText -Event 'hook-lock' -WaitMs 1130000 -State 'held' -BaseSha $A -GrantSha $B | ConvertFrom-Json),
      (New-TcPushRowText -Event 'hook-lock' -WaitMs 4000 -State 'held' -BaseSha $A -GrantSha $A | ConvertFrom-Json)
    )
    $ledMeasure = Measure-TcPushRows $rows
    $res = Write-TcConvergenceReport -Ledger $ledMeasure -Landings $iv -Logs $lg -Days 1
    T ($kCT + '  a report with all three sources present resolves all three') ($res -eq 3) ("resolved={0}" -f $res)
    # NOTHING TO LOOK AT IS NOT A HEALTHY BOX. Without this, a run on a machine with no ledger, no landings and no
    # logs would print three reassuring paragraphs and exit 0.
    $emptyLed = Measure-TcPushRows @()
    $resNone = Write-TcConvergenceReport -Ledger $emptyLed -Landings $none -Logs $lgMissing -Days 1
    T ($kMF + '  a report whose every source is empty resolves NOTHING, which its caller turns into an exit 3') `
      ($resNone -eq 0) ("resolved={0}" -f $resNone)
  } finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }
  if ($f) { Write-Output ("probe-push-convergence self-test FAIL: {0} of {1} check(s)" -f $f, $cases); exit 1 }
  Write-Output ("probe-push-convergence self-test PASS: {0} cases - led by a report whose every source is empty resolving NOTHING rather than printing a healthy box, and by a fetch entry never being counted as a landing" -f $cases)
  exit 0
}

$ledgerRows = [Collections.Generic.List[object]]::new()
for ($d = 0; $d -lt [math]::Max(1, $Days); $d++) {
  $path = Get-TcPushLedgerPath -Root $LedgerRoot -Now ([datetime]::Now.AddDays(-$d))
  $these = Read-TcPushRows -Path $path
  foreach ($r in @($these)) { $ledgerRows.Add($r) }
}
$ledger = Measure-TcPushRows $ledgerRows.ToArray()

if ($ReflogFile -and (Test-Path -LiteralPath $ReflogFile)) {
  $reflogLines = @(Get-Content -LiteralPath $ReflogFile)
} else {
  $reflogLines = Get-TcGitReflogLines -Dir $repo -Ref 'refs/remotes/origin/main'
}
$allLandings = Get-TcReflogLandings $reflogLines
$cut = [datetime]::Now.AddDays(-[math]::Max(1, $Days))
$windowLandings = @(@($allLandings) | Where-Object { $_ -ge $cut })
$landings = Measure-TcLandingIntervals $windowLandings

$logDir = $(if ($LogDir) { $LogDir } else { $env:TEMP })
$logs = Measure-TcPrepushLogs -Dir $logDir -Days ([math]::Max(1, $Days))

$resolved = Write-TcConvergenceReport -Ledger $ledger -Landings $landings -Logs $logs -Days ([math]::Max(1, $Days))
if ($resolved -eq 0) {
  [Console]::Out.WriteLine('probe-push-convergence: COULD NOT EVALUATE - no ledger row, no landing and no retained log could be read. That is not a healthy box, it is a probe that could not look.')
  [Console]::Out.WriteLine('PUSH-CONVERGENCE-COMPLETE resolved=0 rows=0 landings=0 logs=0')
  exit 3
}
[Console]::Out.WriteLine(('PUSH-CONVERGENCE-COMPLETE resolved={0} of 3 sources; rows={1} landings={2} logs={3}' -f `
  $resolved, $ledger.Rows, $landings.Landings, $logs.Total))
exit 0
