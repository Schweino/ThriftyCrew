<#
  probe-push-convergence.ps1 - can a push on this box converge, and what does a push cost? Reports how long pushes
  wait, how often the remote moves while they wait, how fast main moves and how the refused ones were refused, and,
  since 2026-09-23, every figure the bars of design\PLAN-push-derived-conflicts-2026-09-23.md are judged on.

  Run:        powershell -File ops\probe-push-convergence.ps1                 the convergence report, as before
              powershell -File ops\probe-push-convergence.ps1 -Days 2
              powershell -File ops\probe-push-convergence.ps1 -Cost           push-main cost, last 7 days (or -Days N)
              powershell -File ops\probe-push-convergence.ps1 -Cost -Bar B3   one bar, over its treated rows only
              powershell -File ops\probe-push-convergence.ps1 -History        what the reflog and git can re-derive
              powershell -File ops\probe-push-convergence.ps1 -Due            which bars are past their read-out date
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

  THE THREE MODES W0.3 ADDED (2026-09-23, design\PLAN-push-derived-conflicts-2026-09-23.md, W0.3 steps 1 to 5).

  -Cost prints, over PUSH-MAIN rows of the ledger in a UTC window, each figure with its N and the window: outcomes by
  UTC day; seconds from the push-main start (the start time inside the row's `run` id) to the row, by outcome, phase
  and population (generic, chain-touching, unknown); first attempt to landing per change; leg seconds; the lock hold;
  conflict files by the literal class table below, with the ancestry of each colliding main commit; reject classes;
  the W3.2 and W4.1 counters; the run-gates cache flush (the D7 input); the chain lease; landings per active hour and
  the busy hours; parallel runs; and every bar. A field a row does not carry is counted ABSENT, never zero, so a row
  in the shape before W0.1 parses and is counted pre-W0.1 in every section. hook-lock rows are the hook's own and are
  not costed. Rows whose checkout is a test-prepush sandbox (%TEMP%\tc-prepush-selftest-*) are excluded and counted,
  with how many carry W0.2's blob segment in the name; push-main rows from any other checkout under %TEMP% are
  fixtures too (the plan's census excluded 2 such rows) and are excluded and counted on their own line.

  WHICH ROWS A BAR JUDGES. The plan says a bar's rows are those whose pm_blob maps to a push-main commit at or after
  the item's landing. Read literally, that excludes EVERY row for an item that does not change ops\push-main.ps1
  (W1.1, W3.x, W4.x): an unchanged blob maps to the commit that introduced it, which is older than the landing. So a
  row is TREATED for a bar when both hold: its pm_blob maps to the push-main commit current at the landing or a later
  one (the plan's rule, read against the blob the item landed with), and the main it gated on already held the
  landing commit (preflight_sha when the row has one, else branch_base, both W0.1 fields). The second clause also
  keeps out an item's own attempts before it landed, which ran the new push-main on a branch based before it. Every
  other row is counted by why: pre-W0.1 (no pm_blob), unknown-copy (a blob not on the push-main history of the main
  ref), older-copy, no-base, base-before-landing.

  WHERE A BAR'S LANDING COMES FROM. A commit cannot contain its own landed hash, and push-main rebases before it
  pushes, so the bars table below holds no hash. It holds, per bar, the items it judges and a read-out offset in days.
  At read time an item's landing is the FIRST commit on the main ref whose message carries the line
  `Plan: design/PLAN-push-derived-conflicts-2026-09-23.md <item id>`, the id matched as a whole token, so W2.1 never
  matches W2.10. A bar that judges several items (B4, B8, B9, B10) lands with the last of them. A bar whose item has
  not landed is printed NOT LANDED and is never due. A landing commit that forgot its Plan line is invisible here.

  READ-OUT DATES. The plan names one (B6, 14 days after W6.1 lands). Every bar takes the same 14 days: the first
  plausible offset, not swept, and each bar's minimum N still decides whether its read-out can give a verdict.

  -Due prints every bar and exits 2 when a bar past its read-out date has no result line in the plan's COMMITTED copy
  on the main ref: a line starting `B<n>: result` inside section 13 and outside a fenced block. IT IS AN ALARM FOR
  TRACKED WORK, read by W3.4's scheduled task, and is never wired into run-gates or a hook: a push must not be refused
  because a read-out is late.

  -History (report only) re-derives from the shared reflog and git what the plan measured by scratch: the chain share
  of landings (through ops\rehearse-chain.ps1 -ListSet; BLIND until W0.5 adds it, and never run while its param block
  lacks it, because an unknown switch without CmdletBinding would fall into a real 14-minute rehearsal), the 14-day
  class census, the backlog touch share and the median overlap share. The conflict attribution before W0.1 needed
  transcripts and cannot be re-derived: it stays SCRATCH. Since W0.3b it also reads the push ledger for two counts the
  amendment measured by scratch, now committed: main-checkout plain pushes that passed every hook check and were then
  rejected (a held hook-lock row from the main checkout with no main-ref update 0 to 15 s after it), and every landing
  of the last 7 days by ROUTE (push-main, a plain push from a worktree, a plain push from the main checkout, no ledger
  row), with the chain landings among them. Either is BLIND, never zero, when no ledger file is in the window.

  W0.3b: THE PROBE COUNTS ATTEMPTS, NOT ROWS (2026-09-23, the plan's section 15.5). Section 3 of -Cost now reads:
  - An ATTEMPT is a run a session launched: a push-main row, or a hook-refused row (W0.6) of a PLAIN push. A hook-refused
    row written under a push-main is that push-main's attempt, which its own row already records, so it is counted
    apart and never again. A dry run moves nothing and is no attempt. A LEG SET is one push-main round (`rounds`, W0.1R,
    summed); a change whose rows do not all carry `rounds` gets no leg count rather than a guessed one.
  - A CHANGE is (checkout, subjects_sha). change_id only breaks a tie: the same subjects after a landing, over a
    different patch, is new work. Rows without subjects_sha fall back to W0.3's (checkout, change_id), and rows with
    neither to its 6-hour gap. A plain push's attempt joins the change its checkout was working on at that moment. A
    subject set that lands from another checkout links the groups into one change that CROSSES checkouts, which stays
    out of B6's denominator and is counted on its own line. A change landed on its FIRST attempt only when that
    attempt's own row landed.
  - B6 prints every attempt in a column: landed, own red, ambient red, red undecided, not-ready at start, during the
    legs or unrecorded, mechanical, genuine or unrecorded conflict, and other. Own against ambient is read from the
    PATCH: a red whose change_id equals the one the change landed with is ambient, because the refused patch later
    landed unchanged. (a) excludes only own reds and genuine conflicts, because an exclusion needs evidence; (b) is leg
    sets per change. B6 and B10 are split into QUIET (no attempt inside a parallel run, none in an hour with 8 or more
    landings of the main ref's reflog) and CONTENDED, and the quiet B6 prints P(result | old rate) under a stated
    model. Verdicts print only under -Cost -Bar B6, whose rows are treated. W0.3b changes no bar's value, only what the
    bars count.
  - Every older-copy count beside a bar is also printed as a share of the rows it was taken from.

  IT IS A REPORT, NOT A GATE. There is no threshold on push waits here and there must not be one: ops-and-gates.md
  forbids a gate that is red on day one, and any bar on push waits would be red on the first busy morning and teach
  --no-verify. Nothing in the estate reads its output to decide a push. -Due's exit 2 pages a person; it refuses
  nothing.

  Exit codes. The convergence report: 0 = a report was produced, 3 = it could resolve NOTHING to report on, which is
  never "the box is healthy". -Cost: 0 = a report over at least one push-main row, 3 = no row in the window, or a
  -Bar that names no bar or one that has not landed. -History: 0, or 3 when the reflog cannot be read or holds fewer
  than 2 landings in 14 days. -Due: 0 = no landed bar is past its date without a result line, 2 = at least one is,
  3 = the plan or the landing log could not be read.

  SCOPE OF A CLEAN REPORT: every figure here is over what this box recorded. A quiet ledger means nobody pushed
  through an instrumented checkout, never that nobody waited - which is why the resolved counts are printed beside
  every rate and an empty source is named rather than folded into a zero. A -Due exit 0 says nothing about a bar whose
  item has not landed, and nothing about a landing whose commit forgot its Plan line.
#>
# Declared inputs of its -SelfTest (2026-09-23, lib\gate-input-key.ps1): every case runs on frozen literal rows, logs and
# plan text written into a per-run temp directory, and a fake git; the -Due and -ListSet cases run THIS file or a temp
# script as a child. So it reads nothing else of this repo. Verify with: powershell -File lib\gate-input-key.ps1 -VerifyDeclared <this file>
# gate-inputs: ops\probe-push-convergence.ps1, lib\push-ledger.ps1, lib\append-line.ps1
[CmdletBinding()]
param(
  [int]$Days = 1,
  [string]$LedgerRoot = '',
  [string]$LogDir = '',
  [string]$ReflogFile = '',
  [switch]$Cost,
  [switch]$History,
  [switch]$Due,
  [string]$Bar = '',
  # The main ref every landing is read from: the remote-tracking ref in the one .git this box shares, which every
  # landing from this box updates. Nothing here fetches.
  [string]$MainRef = 'refs/remotes/origin/main',
  # SEAMS for the self-test: a plan text and a landing log read from files instead of git, a clock, and the directory
  # the test-prepush sandboxes live under. A run passes none of them.
  [string]$PlanFile = '',
  [string]$PlanLogFile = '',
  [string]$NowUtc = '',
  [string]$TempRoot = '',
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

# =====================================================================================================================
# W0.3: THE COST, HISTORY AND DUE MODES (2026-09-23). Everything below the next line is new with W0.3; everything
# above it is the convergence report, unchanged, which the self-test pins byte for byte.
# =====================================================================================================================

$script:TcPpcPlanRel = 'design/PLAN-push-derived-conflicts-2026-09-23.md'
# The landing line. The id group is split into tokens and each is compared ORDINALLY with the item id, so W2.1 never
# matches W2.10, and the plan's own commit ("Plan: <plan> (this commit adds it)") resolves no item.
$script:TcPpcPlanLineRx = '^\s*Plan:\s*design[\\/]PLAN-push-derived-conflicts-2026-09-23\.md(?:\s+(.*?))?\s*$'
# Every constant below is the plan's own value (section 6, W0.3, and section 8), used as written: first plausible, not
# swept. The read-out offset is B6's 14 days applied to every bar, because the plan names no other.
$script:TcPpcReadoutDays = 14
$script:TcPpcSandboxLeaf = 'tc-prepush-selftest-'
$script:TcPpcChangeGapSec = 21600          # rows with no change_id: consecutive attempts within 6 hours are one change
$script:TcPpcParallelMinCheckouts = 4      # a parallel run: at least 4 distinct checkouts sharing one session ...
$script:TcPpcParallelWindowSec = 7200      # ... that each wrote a push-main row within one 2-hour window
$script:TcPpcBusyHourRows = 6              # a BUSY hour holds at least 6 push-main rows (B8)
$script:TcPpcExposedSec = 3600             # -History: a touch is exposed when another landing touched the file in the 60 minutes before
$script:TcPpcB1aBarSec = 60                # B1(a): median at most 60 s from push-main start to a preflight refusal
$script:TcPpcB1aMinN = 5                   # B1(a): at least 5 preflight refusals
$script:TcPpcB1bMinN = 10                  # B1(b): at least 10 conflict rows of any phase
$script:TcPpcLandedOutcomes = @('landed', 'landed-after-rebase')
$script:TcPpcOutcomeOrder = @('landed', 'landed-after-rebase', 'refused-gate-red', 'refused-rehearsal', 'refused-rehearsal-blind',
  'refused-rehearsal-churn', 'refused-not-ready', 'refused-rebase-conflict', 'refused-already-on-main', 'push-rejected', 'blind-fetch-failed', 'dry-run')
# W0.3b (15.5): attempts, changes and leg sets. Every value is the plan's own, first plausible, not swept.
$script:TcPpcContendedHourLandings = 8     # B6/B10 strata: an hour with at least 8 landings is contended (15.6: "fewer than 8 landings in the hour" is quiet)
$script:TcPpcB6QuietMinN = 10              # B6 quiet: at least 10 changes
$script:TcPpcB6ContendedMinN = 5           # B6 contended: at least 5 changes
# B6's OLD RATE for P(result | old rate): 15.6's baseline, 30 push-main rows over 12 landed chain changes 09-21 to 09-23
# (2.50 per change), and 1.92 under W0.3's old exclusions. Both SCRATCH (the measurement skeptic). The amended count sits
# between them, so both are printed; a lower old rate gives a larger P.
$script:TcPpcB6OldRates = @(2.5, 1.92)
$script:TcPpcFollowedSec = 15              # -History: a held hook-lock row is FOLLOWED when a reflog update lands 0 to 15 s after it (the method of %TEMP%\pushgood-skeptic\mainland.py)
# -History's route match, the windows of %TEMP%\pushgood-residual\landings.py, used as written: a push-main landed row
# written -10 to +900 s after the landing and naming the sha main moved from as its base or grant; else one written -10
# to +120 s after it; else a hook-lock row written 900 s before to 30 s after the landing, naming that sha.
$script:TcPpcRoutePmBeforeSec = 10
$script:TcPpcRoutePmAfterSec = 900
$script:TcPpcRoutePmNearSec = 120
$script:TcPpcRouteHookBeforeSec = 900
$script:TcPpcRouteHookAfterSec = 30
$script:TcPpcMechanicalClasses = @('backlog-index', 'reread')
$script:TcPpcAttemptColumns = @('landed', 'own-red', 'ambient-red', 'red-undecided', 'not-ready-start', 'not-ready-legs', 'not-ready-unrecorded',
  'conflict-mechanical', 'conflict-genuine', 'conflict-unrecorded', 'other')
$script:TcPpcExcludedColumns = @('own-red', 'conflict-genuine')
$script:TcPpcRouteNames = @('push-main', 'plain-worktree', 'plain-main', 'plain-unknown', 'no-ledger-row')

# THE CLASS TABLE, W0.3 step 3, literal and case-sensitive over a repo path with forward slashes. First match wins.
$script:TcPpcClassTable = @(
  [pscustomobject]@{ Class = 'backlog-index'; Rx = @('^design/BACKLOG-', '^design/ready-for-brad/README\.md$', '^design/backlog-inbox/') }
  [pscustomobject]@{ Class = 'reread'; Rx = @('^design/(MEASURE|EVAL)-', '^design/reread-ledger\.tsv$') }
  [pscustomobject]@{ Class = 'ruling'; Rx = @('^grocery/known-wrong\.json$', '^grocery/commodities\.json$') }
  [pscustomobject]@{ Class = 'baseline'; Rx = @('baseline\.json$') }
  [pscustomobject]@{ Class = 'rules'; Rx = @('^\.claude/rules/', '^CLAUDE\.md$') }
  [pscustomobject]@{ Class = 'hub'; Rx = @('^ops/run-gates\.ps1$', '^grocery/test-auditors\.ps1$', '^grocery/check-ad-cycles\.ps1$', '^ops/run-gates-static\.tsv$') }
  [pscustomobject]@{ Class = 'code'; Rx = @('\.(ps1|py|js|sh)$') }
)
$script:TcPpcClassNames = @('backlog-index', 'reread', 'ruling', 'baseline', 'rules', 'hub', 'code', 'other')

# THE BARS TABLE, section 8 of the plan, W0.3 step 4. No landing hash lives here (see the header): each bar names the
# items it judges, and its landing is read from the main ref's commit messages at read time.
$script:TcPpcBars = @(
  [pscustomobject]@{ Id = 'B1'; Items = @('W2.1'); ReadoutDays = $script:TcPpcReadoutDays
    Metric = '(a) seconds from push-main start to a phase=preflight conflict refusal; (b) catch-up or in-lock conflict rows whose colliding commit was on main before the pre-flight fetch (rows without degraded=fetch)'
    MinN = '(a) 5 preflight refusals; (b) 10 conflict rows of any phase'; Value = '(a) median at most 60 s; (b) 0 such rows' }
  [pscustomobject]@{ Id = 'B2'; Items = @('W2.2'); ReadoutDays = $script:TcPpcReadoutDays
    Metric = 'in-lock refusals with reject_class rehearsal, per push-main row that took the lock'
    MinN = '50 qualifying rows, in hours with fewer than 8 landings'; Value = 'at most 1 per 50; no verdict while any push-rejected row has reject_class unknown' }
  [pscustomobject]@{ Id = 'B2b'; Items = @('W1.1'); ReadoutDays = $script:TcPpcReadoutDays
    Metric = 'lock_held_ms on rehearsal-refused rows'; MinN = '3 rows'; Value = 'median at most 60 s' }
  [pscustomobject]@{ Id = 'B3'; Items = @('W2.2'); ReadoutDays = $script:TcPpcReadoutDays
    Metric = 'lock_held_ms, stratum A (main moved during the legs) and B (it did not)'; MinN = '30 rows in A'
    Value = 'A: median at most 45 s and p90 at most 180 s; B: median no more than 10 s above its soak baseline' }
  [pscustomobject]@{ Id = 'B4'; Items = @('W3.1', 'W3.2'); ReadoutDays = $script:TcPpcReadoutDays
    Metric = '(a) landings with backlog_direct over 0; (b) conflict rows whose conflict_files include design/BACKLOG-course-findings.md'
    MinN = '(a) 50 landings; (b) 60 push-main rows from parallel runs'; Value = '(a) at most 10% of landings; (b) 0' }
  [pscustomobject]@{ Id = 'B5'; Items = @('W4.1'); ReadoutDays = $script:TcPpcReadoutDays
    Metric = '(a) re-reads written as ledger rows, of all re-reads added; (b) conflict rows in class reread'
    MinN = '(a) 10 re-reads'; Value = '(a) at least 90% ledger rows; (b) reported with P(0 under the old rate), no verdict' }
  [pscustomobject]@{ Id = 'B6'; Items = @('W6.1'); ReadoutDays = $script:TcPpcReadoutDays
    Metric = '(amended, 15.6) (a) ATTEMPTS per landed chain-touching change, counting not-ready and ambient reds and excluding only the change''s own reds and genuine conflicts; (b) LEG SETS per landed chain-touching change'
    MinN = 'quiet (not a parallel run, fewer than 8 landings in the hour): 10 changes; contended: 5'
    Value = '(a) at most 1.2 quiet and at most 1.5 contended; (b) at most 1.8 quiet, reported when contended; read no earlier than 14 days after W6.1 and W2.1R, with the plain-push share of chain landings (-History) beside it' }
  [pscustomobject]@{ Id = 'B7'; Items = @('W2.3'); ReadoutDays = $script:TcPpcReadoutDays
    Metric = 'pre-lock wall on chain-touching rows where test-auditors ran and the rehearsal ran over 60 s'
    MinN = '5 rows after and 3 before'; Value = 'median at most the pre-change rg + max(ta, rh) + 60 s; 0 test-auditors timeouts in overlapped runs' }
  [pscustomobject]@{ Id = 'B8'; Items = @('W2.1', 'W2.2', 'W2.3'); ReadoutDays = $script:TcPpcReadoutDays
    Metric = 'wasted gate minutes per landing, over busy hours'; MinN = '50 landings in busy hours'; Value = 'at most one third of W0.3''s recomputed baseline' }
  [pscustomobject]@{ Id = 'B9'; Items = @('W2.1', 'W2.2', 'W2.3'); ReadoutDays = $script:TcPpcReadoutDays
    Metric = 'seconds from push-main start to a landed row, generic and chain-touching'; MinN = '30 generic and 5 chain-touching landings'
    Value = 'generic: median at most baseline + 60 s and p90 at most baseline p90; chain-touching: median at most 45 min' }
  [pscustomobject]@{ Id = 'B10'; Items = @('W2.1', 'W2.2', 'W2.3', 'W6.1'); ReadoutDays = $script:TcPpcReadoutDays
    Metric = 'first attempt to landing per change, generic and chain-touching'; MinN = '30 generic and 5 chain-touching changes'
    Value = 'chain-touching: median at most 45 min; generic: median at most baseline + 60 s' }
  [pscustomobject]@{ Id = 'B11'; Items = @('W2.3'); ReadoutDays = $script:TcPpcReadoutDays
    Metric = 'full test-auditors runs inside the lock (hook_ta ran), per lock-taken row'; MinN = '50 lock-taken rows'; Value = 'not above the pre-W2.3 rate' }
)

function Write-TcPpcLine { param([string]$Text) [Console]::Out.WriteLine($Text) }

function ConvertTo-TcPpcUtc {
  <# A timestamp as a UTC [datetime], or $null when it cannot be read. A string without an offset is read as UTC, which
     is what every row's `ts` and `run` start are. PS 5.1's ConvertFrom-Json leaves ISO dates as strings. #>
  param($Value)
  if ($null -eq $Value) { return $null }
  if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
  $s = ([string]$Value).Trim()
  if (-not $s) { return $null }
  $dto = [DateTimeOffset]::MinValue
  if ([DateTimeOffset]::TryParse($s, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$dto)) { return $dto.UtcDateTime }
  return $null
}

function Format-TcPpcUtc { param($At) if ($null -eq $At) { return '(none)' }; return ([datetime]$At).ToString('yyyy-MM-ddTHH:mm:ssZ') }

function Format-TcPpcShort { param([string]$Sha) if (-not $Sha) { return '(none)' }; if ($Sha.Length -gt 9) { return $Sha.Substring(0, 9) }; return $Sha }

function Get-TcPpcProp {
  <# One field of a row, or $null when the row does not carry it. A PRESENCE question asked of the property table,
     never inferred from a value, so an old-shape row reads every new field as absent. #>
  param($Row, [string]$Name)
  if ($null -eq $Row) { return $null }
  $p = $Row.PSObject.Properties[$Name]
  if ($null -eq $p) { return $null }
  return $p.Value
}

function Get-TcPpcList {
  <# A list field as strings, empty when absent. -SplitComma also splits a comma-joined string, for rebase_phases,
     which a writer may record either way. A path list is never split, because a path may hold a comma. #>
  param($Row, [string]$Name, [switch]$SplitComma)
  $v = Get-TcPpcProp $Row $Name
  $out = [Collections.Generic.List[string]]::new()
  foreach ($x in @($v)) {
    if ($null -eq $x) { continue }
    $parts = if ($SplitComma) { ([string]$x -split ',') } else { @([string]$x) }
    foreach ($s in $parts) { $t = $s.Trim(); if ($t) { $out.Add($t) } }
  }
  return , ($out.ToArray())
}

function Get-TcPpcNum {
  <# A numeric field, or $null when it is absent, null, a boolean or not a number. ABSENT IS NEVER ZERO. #>
  param($Row, [string]$Name)
  $v = Get-TcPpcProp $Row $Name
  if ($null -eq $v -or $v -is [bool]) { return $null }
  $d = 0.0
  if ([double]::TryParse([string]$v, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return $d }
  return $null
}

function Test-TcPpcLanded { param($Row) return ($script:TcPpcLandedOutcomes -contains [string](Get-TcPpcProp $Row 'outcome')) }

function Get-TcPpcRowStartUtc {
  <# When the push-main that wrote this row STARTED: the start time inside its `run` id, `<pid>@<start, UTC>`
     (lib\push-ledger.ps1, backlog I171). $null for a row written before run ids existed and for a fixture's guid id,
     which carries no time. #>
  param($Row)
  $run = [string](Get-TcPpcProp $Row 'run')
  $i = $run.IndexOf('@')
  if ($i -lt 1) { return $null }
  return (ConvertTo-TcPpcUtc $run.Substring($i + 1))
}

function Get-TcPpcRowSeconds {
  <# Seconds from the push-main start to its row, or $null when either end cannot be read. A row's `ts` is written to
     the second and truncated, so the true figure lies in [this, this + 1). #>
  param($Row)
  $s = Get-TcPpcRowStartUtc $Row
  $t = ConvertTo-TcPpcUtc (Get-TcPpcProp $Row 'ts')
  if ($null -eq $s -or $null -eq $t) { return $null }
  return ($t - $s).TotalSeconds
}

function Get-TcPpcRowAnchor {
  <# The time a row's attempt began: its run start, else its ts, else the minimum, so a sort never meets a null. #>
  param($Row)
  $s = Get-TcPpcRowStartUtc $Row
  if ($null -ne $s) { return $s }
  $t = ConvertTo-TcPpcUtc (Get-TcPpcProp $Row 'ts')
  if ($null -ne $t) { return $t }
  return [datetime]::MinValue
}

function Get-TcPpcCheckoutKey { param($Row) return ([string](Get-TcPpcProp $Row 'checkout')).TrimEnd('\').ToLowerInvariant() }

function Get-TcPpcChainClass {
  <# generic, chain-touching or unknown, from W0.1's chain_touching field. An absent field and a value this reader does
     not know are both UNKNOWN - counted, and the raw values printed by the report, so a vocabulary W0.1 chose that
     this file does not read shows up instead of folding into either population. #>
  param($Row)
  $v = Get-TcPpcProp $Row 'chain_touching'
  if ($null -eq $v) { return 'unknown' }
  if ($v -is [bool]) { if ($v) { return 'chain-touching' } else { return 'generic' } }
  $s = ([string]$v).Trim().ToLowerInvariant()
  if (@('true', 'yes', 'needed', 'chain', 'chain-touching', 'rehearse') -contains $s) { return 'chain-touching' }
  if (@('false', 'no', 'not-needed', 'generic', 'none') -contains $s) { return 'generic' }
  return 'unknown'
}

function Get-TcPpcStats {
  <# N, median, p75, p90 and max by the NEAREST RANK rule of lib\push-ledger.ps1, -1 for no samples. A $null value is
     left out, never counted as zero. #>
  param($Values)
  $a = [Collections.Generic.List[double]]::new()
  foreach ($v in @($Values)) { if ($null -ne $v) { $a.Add([double]$v) } }
  $s = $a.ToArray()
  [Array]::Sort($s)
  return [pscustomobject]@{
    N = $s.Count
    Median = (Get-TcPushPercentile $s 0.5)
    P75 = (Get-TcPushPercentile $s 0.75)
    P90 = (Get-TcPushPercentile $s 0.9)
    Max = (Get-TcPushPercentile $s 1.0)
  }
}

function Format-TcPpcStats {
  param($S, [double]$Scale = 1.0, [string]$Unit = ' s')
  if ($S.N -eq 0) { return 'N=0, no distribution' }
  return ('median {0:N0}{4}, p90 {1:N0}{4}, max {2:N0}{4}, N={3}' -f ($S.Median / $Scale), ($S.P90 / $Scale), ($S.Max / $Scale), $S.N, $Unit)
}

function Get-TcPpcFileClass {
  <# The class of one repo path, by the literal table above. First match wins; anything else is 'other'. #>
  param([string]$Path)
  $p = ([string]$Path).Trim() -replace '\\', '/'
  if ($p.StartsWith('./')) { $p = $p.Substring(2) }
  foreach ($c in $script:TcPpcClassTable) {
    foreach ($rx in $c.Rx) { if ([regex]::IsMatch($p, $rx)) { return $c.Class } }
  }
  return 'other'
}

function Test-TcPpcSandboxBlobName {
  <# A W0.2 sandbox name carries the suite's blob: tc-prepush-selftest-<blob8>-<pid>-<guid8>. The older names are
     tc-prepush-selftest-<pid>-<guid8>, so three segments with an 8-hex first one is the W0.2 shape. #>
  param([string]$Checkout)
  $m = [regex]::Match([string]$Checkout, '(?i)tc-prepush-selftest-([^\\/]+)')
  if (-not $m.Success) { return $false }
  $seg = $m.Groups[1].Value -split '-'
  return ($seg.Count -ge 3 -and $seg[0] -match '^[0-9a-f]{8}$')
}

function Select-TcPpcRows {
  <# W0.3 step 2's row selection. Returns what was read, what was excluded and why, and the kept PUSH-MAIN rows.
     Sandbox rows of ANY event are excluded and counted, because W0.2's read-out is how many sandbox rows still reach
     the production ledger. Nothing is dropped without a count. #>
  param($Rows, [string]$SandboxRoot)
  $tr = ''
  if ($SandboxRoot) { try { $tr = [IO.Path]::GetFullPath($SandboxRoot).TrimEnd('\') } catch { $tr = ([string]$SandboxRoot).TrimEnd('\') } }
  $kept = [Collections.Generic.List[object]]::new()
  # W0.3b: the non-push-main rows that are still ATTEMPTS or route evidence are kept on their own lists. OtherEvents
  # still counts every row that is not push-main, so the head line's count is what it was.
  $hookRefused = [Collections.Generic.List[object]]::new()
  $hookLock = [Collections.Generic.List[object]]::new()
  $hrUnder = 0
  $read = 0; $mal = 0; $otherEv = 0; $sand = 0; $sandBlob = 0; $tmpOther = 0
  foreach ($r in @($Rows)) {
    if ($null -eq $r) { continue }
    $read++
    if ($r.PSObject.Properties['malformed']) { $mal++; continue }
    $co = ([string](Get-TcPpcProp $r 'checkout')).TrimEnd('\')
    if ($tr -and $co) {
      if ($co.StartsWith($tr + '\' + $script:TcPpcSandboxLeaf, [StringComparison]::OrdinalIgnoreCase)) {
        $sand++
        if (Test-TcPpcSandboxBlobName $co) { $sandBlob++ }
        continue
      }
      if ($co.StartsWith($tr + '\', [StringComparison]::OrdinalIgnoreCase)) { $tmpOther++; continue }
    }
    $ev = [string](Get-TcPpcProp $r 'event')
    if (-not [string]::Equals($ev, 'push-main', [StringComparison]::Ordinal)) {
      $otherEv++
      if ([string]::Equals($ev, 'hook-refused', [StringComparison]::Ordinal)) { if (Test-TcPpcUnderPushMain $r) { $hrUnder++ } else { $hookRefused.Add($r) } }
      elseif ([string]::Equals($ev, 'hook-lock', [StringComparison]::Ordinal)) { $hookLock.Add($r) }
      continue
    }
    $kept.Add($r)
  }
  return [pscustomobject]@{
    Read = $read; Malformed = $mal; OtherEvents = $otherEv
    ExcludedSandbox = $sand; ExcludedSandboxBlob = $sandBlob; ExcludedTemp = $tmpOther
    Kept = $kept.ToArray()
    HookRefused = $hookRefused.ToArray(); HookRefusedUnderPm = $hrUnder; HookLock = $hookLock.ToArray()
  }
}

function ConvertFrom-TcPpcBlobLog {
  <# The push-main blob history, oldest first, from
       git log --reverse --format='@@TC-COMMIT %H %cI' --raw --no-abbrev <main> -- ops/push-main.ps1
     One entry per commit: Commit, Ts, and the NEW blob from its raw line ('' when it has none). #>
  param($Lines)
  $out = [Collections.Generic.List[object]]::new()
  $cur = $null
  foreach ($ln in @($Lines)) {
    $t = [string]$ln
    if ($t.StartsWith('@@TC-COMMIT ')) {
      if ($null -ne $cur) { $out.Add($cur) }
      $p = $t.Substring(12).Trim() -split '\s+'
      $cur = [pscustomobject]@{ Commit = $p[0]; Ts = $(if ($p.Count -ge 2) { ConvertTo-TcPpcUtc $p[1] } else { $null }); Blob = '' }
      continue
    }
    if ($null -ne $cur -and $t -match '^:\d{6} \d{6} [0-9a-f]{40} ([0-9a-f]{40}) [A-Z]\d*\t') { $cur.Blob = $Matches[1] }
  }
  if ($null -ne $cur) { $out.Add($cur) }
  return , ($out.ToArray())
}

function New-TcPpcBlobIndex {
  <# Blob -> the FIRST commit carrying it (W0.3 step 2), and each commit's position in the push-main history, which is
     the order "at or after" is judged in. A deleted file's all-zero blob is never an entry. #>
  param($Entries)
  $first = New-Object Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase)
  $order = New-Object Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase)
  $i = 0
  foreach ($e in @($Entries)) {
    if ($null -eq $e) { continue }
    $order[[string]$e.Commit] = $i
    $b = [string]$e.Blob
    if ($b -and $b -notmatch '^0+$' -and -not $first.ContainsKey($b)) { $first[$b] = $e }
    $i++
  }
  return [pscustomobject]@{ First = $first; Order = $order; Count = $i }
}

function Resolve-TcPpcRowCopy {
  <# Is this row TREATED for a bar, and if not, why (header: WHICH ROWS A BAR JUDGES). $LandingBlob is the push-main
     blob at the bar's landing commit; $AfterLanding the set of main commits at or after that landing. Returns one of
     treated, pre-w01, unknown-copy, unknown-landing, older-copy, no-base, base-before-landing. #>
  param($Row, $Index, [string]$LandingBlob, $AfterLanding)
  $pb = [string](Get-TcPpcProp $Row 'pm_blob')
  if (-not $pb) { return 'pre-w01' }
  if ($null -eq $Index -or -not $Index.First.ContainsKey($pb)) { return 'unknown-copy' }
  if (-not $LandingBlob -or -not $Index.First.ContainsKey($LandingBlob)) { return 'unknown-landing' }
  $rowPos = [int]$Index.Order[[string]$Index.First[$pb].Commit]
  $landPos = [int]$Index.Order[[string]$Index.First[$LandingBlob].Commit]
  if ($rowPos -lt $landPos) { return 'older-copy' }
  $base = [string](Get-TcPpcProp $Row 'preflight_sha')
  if (-not $base) { $base = [string](Get-TcPpcProp $Row 'branch_base') }
  if (-not $base) { return 'no-base' }
  if ($null -eq $AfterLanding -or -not $AfterLanding.Contains($base)) { return 'base-before-landing' }
  return 'treated'
}

function Measure-TcPpcBarCopies {
  <# How many rows fall in each of Resolve-TcPpcRowCopy's answers for one bar state. #>
  param($Rows, $State, $Index)
  $c = [ordered]@{ 'treated' = 0; 'older-copy' = 0; 'unknown-copy' = 0; 'pre-w01' = 0; 'no-base' = 0; 'base-before-landing' = 0; 'unknown-landing' = 0 }
  foreach ($r in @($Rows)) {
    if ($null -eq $r) { continue }
    $k = Resolve-TcPpcRowCopy -Row $r -Index $Index -LandingBlob ([string]$State.LandingBlob) -AfterLanding $State.AfterLanding
    $c[$k] = [int]$c[$k] + 1
  }
  return $c
}

function ConvertFrom-TcPpcPlanLog {
  <# The landing log: `git log --reverse --format='@@TC-COMMIT %H %cI%n%B' -F --grep=<plan file> <main>`, oldest
     first. Returns Records (Sha, Ts, Body lines) and Malformed, the count of headers that did not parse. #>
  param($Lines)
  $out = [Collections.Generic.List[object]]::new()
  $cur = $null
  $body = [Collections.Generic.List[string]]::new()
  $bad = 0
  foreach ($ln in @($Lines)) {
    $t = [string]$ln
    if ($t.StartsWith('@@TC-COMMIT ')) {
      if ($null -ne $cur) { $cur.Body = $body.ToArray(); $out.Add($cur) }
      $cur = $null
      $body = [Collections.Generic.List[string]]::new()
      $p = $t.Substring(12).Trim() -split '\s+'
      $ts = $null
      if ($p.Count -ge 2) { $ts = ConvertTo-TcPpcUtc $p[1] }
      if ($p.Count -ge 2 -and $p[0] -match '^[0-9a-f]{7,40}$' -and $null -ne $ts) {
        $cur = [pscustomobject]@{ Sha = $p[0]; Ts = $ts; Body = @() }
      } else { $bad++ }
      continue
    }
    $body.Add($t)
  }
  if ($null -ne $cur) { $cur.Body = $body.ToArray(); $out.Add($cur) }
  return [pscustomobject]@{ Records = $out.ToArray(); Malformed = $bad }
}

function Find-TcPpcItemLanding {
  <# The FIRST record whose message carries the plan's landing line naming this item as a WHOLE TOKEN, or $null.
     Tokens split on space, comma and semicolon, with a trailing . ) or : trimmed, and compare ordinally. #>
  param($Records, [string]$ItemId)
  foreach ($rec in @($Records)) {
    if ($null -eq $rec) { continue }
    foreach ($ln in @($rec.Body)) {
      $m = [regex]::Match([string]$ln, $script:TcPpcPlanLineRx)
      if (-not $m.Success) { continue }
      foreach ($tok in ($m.Groups[1].Value -split '[\s,;]+')) {
        $t = $tok.TrimEnd('.', ')', ':')
        if ($t -and [string]::Equals($t, $ItemId, [StringComparison]::Ordinal)) { return $rec }
      }
    }
  }
  return $null
}

function Resolve-TcPpcBarStates {
  <# One state per bar: landed when EVERY item it judges has a landing, at the LAST of them; read-out that plus the
     bar's offset; due when the clock is AT or past the read-out. LandingBlob and AfterLanding start empty and are
     filled by the -Cost gather, which is the only caller that needs git. #>
  param($Bars, $Records, [datetime]$AtUtc)
  $out = [Collections.Generic.List[object]]::new()
  foreach ($b in @($Bars)) {
    $missing = [Collections.Generic.List[string]]::new()
    $last = $null
    foreach ($item in @($b.Items)) {
      $rec = Find-TcPpcItemLanding -Records $Records -ItemId $item
      if ($null -eq $rec) { $missing.Add($item); continue }
      if ($null -eq $last -or $rec.Ts -gt $last.Ts) { $last = $rec }
    }
    $landed = ($missing.Count -eq 0 -and $null -ne $last)
    $readout = $null
    $isDue = $false
    if ($landed) { $readout = $last.Ts.AddDays([double]$b.ReadoutDays); $isDue = ($AtUtc -ge $readout) }
    $out.Add([pscustomobject]@{
      Id = $b.Id; Def = $b; Landed = $landed; Missing = $missing.ToArray()
      Landing = $(if ($landed) { $last } else { $null }); Readout = $readout; Due = $isDue
      LandingBlob = ''; AfterLanding = $null
    })
  }
  return , ($out.ToArray())
}

function Get-TcPpcResultBars {
  <# The bar ids that have a result line in SECTION 13 of the plan text: a line starting `B<n>: result` (an optional
     list marker before it), outside any fenced block. A result line anywhere else in the plan does not count. #>
  param([string]$PlanText)
  $ids = New-Object Collections.Hashtable ([StringComparer]::Ordinal)
  $in = $false; $found = $false; $fence = $false
  foreach ($ln in ([string]$PlanText -split "`r?`n")) {
    if ($ln -match '^\s*(```|~~~)') { $fence = -not $fence; continue }
    if ($fence) { continue }
    if ($ln -match '^##\s') {
      if ($in) { break }
      if ($ln -match '^##\s+13\.') { $in = $true; $found = $true }
      continue
    }
    if (-not $in) { continue }
    $m = [regex]::Match($ln, '^\s*(?:[-*]\s+)?(B\d+[a-z]?): result\b')
    if ($m.Success) { $ids[$m.Groups[1].Value] = $true }
  }
  return [pscustomobject]@{ Found = $found; Ids = $ids }
}

function Get-TcPpcDueVerdict {
  <# Exit 2 when a LANDED bar is due and has no result line; 0 otherwise. A bar not landed is never due. #>
  param($States, $ResultIds)
  $dueN = 0; $notLanded = 0
  $missing = [Collections.Generic.List[string]]::new()
  foreach ($s in @($States)) {
    if ($null -eq $s) { continue }
    if (-not $s.Landed) { $notLanded++; continue }
    if (-not $s.Due) { continue }
    $dueN++
    if (-not $ResultIds.ContainsKey([string]$s.Id)) { $missing.Add([string]$s.Id) }
  }
  return [pscustomobject]@{ Code = $(if ($missing.Count) { 2 } else { 0 }); Due = $dueN; Missing = $missing.ToArray(); NotLanded = $notLanded }
}

function Test-TcPpcWithinB1 {
  <# B1(a)'s comparison: a preflight refusal is within the bar when it came AT MOST 60 s after its push-main start. #>
  param([double]$Seconds)
  return ($Seconds -le $script:TcPpcB1aBarSec)
}

function Resolve-TcPpcConflictAncestry {
  <# For each conflict file of one row: the colliding main commit (the newest in branch_base..<target> touching the
     file; target is preflight_sha for a preflight refusal and the in-lock grant otherwise) and its ancestry against
     preflight_sha: before-preflight, after-preflight or unknown, with why. $Git is a scriptblock over git arguments
     returning Code and Out, so a fixture can answer for git. #>
  param($Row, [scriptblock]$Git)
  $files = Get-TcPpcList $Row 'conflict_files'
  $phase = [string](Get-TcPpcProp $Row 'phase')
  $pre = [string](Get-TcPpcProp $Row 'preflight_sha')
  $bb = [string](Get-TcPpcProp $Row 'branch_base')
  $target = if ($phase -eq 'preflight') { $pre } else { [string](Get-TcPpcProp $Row 'grant') }
  $out = [Collections.Generic.List[object]]::new()
  foreach ($f in $files) {
    $col = ''; $anc = 'unknown'; $why = ''
    if (-not $bb -or -not $target) { $why = 'the row carries no branch_base or no target sha' }
    else {
      $r = & $Git @('log', '-1', '--format=%H', ($bb + '..' + $target), '--', $f)
      $first = ''
      if ($r.Code -eq 0) { foreach ($o in @($r.Out)) { $x = ([string]$o).Trim(); if ($x) { $first = $x; break } } }
      if ($first) { $col = $first } else { $why = 'git named no main commit touching it in branch_base..target' }
    }
    if ($col) {
      if (-not $pre) { $why = 'the row carries no preflight_sha (a copy before W2.1)' }
      else {
        $a = & $Git @('merge-base', '--is-ancestor', $col, $pre)
        if ($a.Code -eq 0) { $anc = 'before-preflight' } elseif ($a.Code -eq 1) { $anc = 'after-preflight' } else { $why = 'merge-base --is-ancestor could not answer' }
      }
    }
    $out.Add([pscustomobject]@{ File = $f; Class = (Get-TcPpcFileClass $f); Collider = $col; Ancestry = $anc; Why = $why })
  }
  return , ($out.ToArray())
}

function Measure-TcPpcB1 {
  <# Both halves of B1 over one row set. $Ancestry is a list of { Row; Files } from Resolve-TcPpcConflictAncestry.
     (a) the median seconds to a preflight conflict refusal, judged at 60 s over at least 5; (b) catch-up or in-lock
     conflict rows with a collider on main before the pre-flight fetch, rows with degraded=fetch left out, judged at
     0 over at least 10 conflict rows of any phase. A bar under its minimum N gives NO VERDICT, never a pass. #>
  param($Rows, $Ancestry)
  $secs = [Collections.Generic.List[object]]::new()
  $noStart = 0
  $conflictRows = 0
  foreach ($r in @($Rows)) {
    if ($null -eq $r) { continue }
    if (-not [string]::Equals([string](Get-TcPpcProp $r 'outcome'), 'refused-rebase-conflict', [StringComparison]::Ordinal)) { continue }
    $conflictRows++
    if ([string](Get-TcPpcProp $r 'phase') -ne 'preflight') { continue }
    $s = Get-TcPpcRowSeconds $r
    if ($null -eq $s) { $noStart++ } else { $secs.Add($s) }
  }
  $sa = Get-TcPpcStats $secs.ToArray()
  $va = if ($sa.N -lt $script:TcPpcB1aMinN) { ('no verdict (N={0}, under {1})' -f $sa.N, $script:TcPpcB1aMinN) } elseif (Test-TcPpcWithinB1 $sa.Median) { 'pass' } else { 'fail' }
  $bad = 0
  foreach ($e in @($Ancestry)) {
    if ($null -eq $e) { continue }
    $ph = [string](Get-TcPpcProp $e.Row 'phase')
    if (@('catchup', 'inlock') -notcontains $ph) { continue }
    if ([string](Get-TcPpcProp $e.Row 'degraded') -match 'fetch') { continue }
    if (@(@($e.Files) | Where-Object { $_.Ancestry -eq 'before-preflight' }).Count) { $bad++ }
  }
  $vb = if ($conflictRows -lt $script:TcPpcB1bMinN) { ('no verdict (N={0} conflict rows, under {1})' -f $conflictRows, $script:TcPpcB1bMinN) } elseif ($bad -eq 0) { 'pass' } else { 'fail' }
  return [pscustomobject]@{ A = $sa; ANoStart = $noStart; AVerdict = $va; BBad = $bad; BConflictRows = $conflictRows; BVerdict = $vb }
}

function Test-TcPpcUnderPushMain {
  <# Did the hook write this hook-refused row (W0.6) under a push-main? Its `under_push_main` says whether a push-main
     token was inherited. A row under a push-main is that push-main's attempt, which its own row already records, so it
     is never counted again. A row that does not carry the field is read as a PLAIN push and counted: W0.6 writes it on
     every row, so its absence is a writer this reader does not know, and dropping the row would hide an attempt. #>
  param($Row)
  $v = Get-TcPpcProp $Row 'under_push_main'
  if ($null -eq $v) { return $false }
  if ($v -is [bool]) { return $v }
  return (@('true', '1', 'yes') -contains ([string]$v).Trim().ToLowerInvariant())
}

function Test-TcPpcIsRed {
  <# Is this attempt a GATE RED: push-main's own legs refused it (refused-gate-red), the in-lock hook refused it on
     run-gates or test-auditors (push-rejected with that reject_class), or a plain push's hook did (hook-refused with
     that cause). A rehearsal, remote, structure or chain-lease refusal is not a red of the change's content. #>
  param($Row)
  $ev = [string](Get-TcPpcProp $Row 'event')
  if ($ev -eq 'hook-refused') { return (@('run-gates', 'test-auditors') -contains [string](Get-TcPpcProp $Row 'cause')) }
  $o = [string](Get-TcPpcProp $Row 'outcome')
  if ($o -eq 'refused-gate-red') { return $true }
  if ($o -eq 'push-rejected') { return ([string](Get-TcPpcProp $Row 'reject_class') -match '^(run-gates|test-auditors)') }
  return $false
}

function Get-TcPpcAttemptClass {
  <# Which column of B6 one attempt falls in (W0.3b step 4). $LandingChangeId is the change_id of the row the change
     LANDED with, '' when it did not land or that row carries none.

     OWN RED against AMBIENT RED is decided by the patch, never by the gate's name: a red attempt whose change_id equals
     the landing's is AMBIENT, because the very patch that was refused later landed unchanged, so what was red was not
     the patch (another session's live edit, a flaky suite, a mirror nobody had committed). A red whose change_id
     differs is the change's OWN: the lane changed its patch before it landed. A red that cannot be compared (no
     change_id on either row, or a plain push's hook-refused row, which carries none) is RED-UNDECIDED. A table of
     "ambient gates" was rejected: audit-prompt-backup is ambient before W8.4 and the push's own after it, so a name
     would be right on one date and wrong on the next.

     A conflict is MECHANICAL when every conflict file is in the backlog-index or reread class (the append-shaped files
     section 8 already sets apart), GENUINE otherwise. That reads a header-line conflict in a .ps1 (15.8, row 36) as
     genuine, which is the rubric's limit and is stated where it is printed.

     An outcome this reader does not know is counted OTHER, never dropped, and the report prints it by name; that is
     why this is a lookup and not a switch that could fall through unseen. #>
  param($Row, [string]$LandingChangeId = '')
  if (Test-TcPpcIsRed $Row) {
    if ([string](Get-TcPpcProp $Row 'event') -eq 'hook-refused') { return 'red-undecided' }
    $cid = [string](Get-TcPpcProp $Row 'change_id')
    if (-not $cid -or -not $LandingChangeId) { return 'red-undecided' }
    if ([string]::Equals($cid, $LandingChangeId, [StringComparison]::Ordinal)) { return 'ambient-red' }
    return 'own-red'
  }
  if ([string](Get-TcPpcProp $Row 'event') -eq 'hook-refused') { return 'other' }
  if (Test-TcPpcLanded $Row) { return 'landed' }
  $o = [string](Get-TcPpcProp $Row 'outcome')
  if ($o -eq 'refused-not-ready') {
    $ds = [string](Get-TcPpcProp $Row 'dirty_since')
    if ($ds -eq 'start') { return 'not-ready-start' }
    if ($ds -eq 'during-legs') { return 'not-ready-legs' }
    return 'not-ready-unrecorded'
  }
  if ($o -eq 'refused-rebase-conflict') {
    $files = Get-TcPpcList $Row 'conflict_files'
    if (-not $files.Count) { return 'conflict-unrecorded' }
    foreach ($f in $files) { if ($script:TcPpcMechanicalClasses -notcontains (Get-TcPpcFileClass $f)) { return 'conflict-genuine' } }
    return 'conflict-mechanical'
  }
  return 'other'
}

function New-TcPpcChange {
  <# One change from its push-main rows and the plain-push hook-refused rows attached to it. Every row is an ATTEMPT.
     Attempts is the count of both; LegSets is the sum of `rounds` over the push-main rows, $null when any of them
     does not carry it (a copy before W0.1R), so a change is never given a leg count it cannot show. #>
  param($Rows, [string]$How, $HookRows = @(), [bool]$Crosses = $false)
  $att = [Collections.Generic.List[object]]::new()
  foreach ($r in @($Rows)) { if ($null -ne $r) { $att.Add($r) } }
  $pmN = $att.Count
  foreach ($r in @($HookRows)) { if ($null -ne $r) { $att.Add($r) } }
  $sorted = @($att.ToArray() | Sort-Object { Get-TcPpcRowAnchor $_ })
  $first = $null; $landedRow = $null; $anyChain = $false; $anyUnknown = $false
  $legs = 0; $roundsRows = 0; $cos = @{}
  foreach ($r in $sorted) {
    $a = Get-TcPpcRowAnchor $r
    if ($null -eq $first -or $a -lt $first) { $first = $a }
    $cos[(Get-TcPpcCheckoutKey $r)] = $true
    if ([string](Get-TcPpcProp $r 'event') -eq 'hook-refused') {
      # A plain push the hook refused on the rehearsal or the chain lease changed the daily chain.
      if (@('rehearsal', 'chain-lease') -contains [string](Get-TcPpcProp $r 'cause')) { $anyChain = $true }
      continue
    }
    if ($null -eq $landedRow -and (Test-TcPpcLanded $r)) { $landedRow = $r }
    $c = Get-TcPpcChainClass $r
    if ($c -eq 'chain-touching') { $anyChain = $true } elseif ($c -eq 'unknown') { $anyUnknown = $true }
    $rd = Get-TcPpcNum $r 'rounds'
    if ($null -ne $rd) { $roundsRows++; $legs += [int]$rd }
  }
  $pop = if ($anyChain) { 'chain-touching' } elseif ($anyUnknown) { 'unknown' } else { 'generic' }
  $sec = $null
  if ($null -ne $landedRow) { $lt = ConvertTo-TcPpcUtc (Get-TcPpcProp $landedRow 'ts'); if ($null -ne $lt) { $sec = ($lt - $first).TotalSeconds } }
  $landCid = if ($null -ne $landedRow) { [string](Get-TcPpcProp $landedRow 'change_id') } else { '' }
  $cls = [ordered]@{}
  foreach ($k in $script:TcPpcAttemptColumns) { $cls[$k] = 0 }
  foreach ($r in $sorted) { $k = Get-TcPpcAttemptClass -Row $r -LandingChangeId $landCid; $cls[$k] = [int]$cls[$k] + 1 }
  $excl = 0
  foreach ($k in $script:TcPpcExcludedColumns) { $excl += [int]$cls[$k] }
  return [pscustomobject]@{
    How = $How; Attempts = $sorted.Count; PmRows = $pmN; HookRows = ($sorted.Count - $pmN)
    Landed = ($null -ne $landedRow); Seconds = $sec; Population = $pop
    FirstAttemptLanded = ($null -ne $landedRow -and $sorted.Count -and [object]::ReferenceEquals($sorted[0], $landedRow))
    Crosses = $Crosses; Checkouts = $cos.Count
    LegSets = $(if ($pmN -and $roundsRows -eq $pmN) { $legs } else { $null }); RoundsRows = $roundsRows
    Classes = $cls; Counted = ($sorted.Count - $excl); Rows = $sorted
  }
}

function Get-TcPpcChangeSet {
  <# W0.3b steps 1 to 3: the changes, with every ATTEMPT attached.

     THE KEY. A push-main row carrying subjects_sha (W0.1R) groups by (checkout, subjects_sha): a lane that amends a
     baseline between attempts moves its change_id and keeps its subjects, so it stays one change (the housekeeping
     lane's three attempts carried three change_ids). change_id only BREAKS A TIE: within one (checkout, subjects_sha),
     a row after a LANDED row starts a new change when its change_id differs from the landing's, because the same
     subjects over a different patch after a landing is new work, and over the same patch is the same change pushed
     again. A row with no subjects_sha groups by (checkout, change_id), W0.3's rule; a row with neither, by W0.3's gap.

     A PLAIN PUSH'S ATTEMPT is a hook-refused row (W0.6) not under a push-main. It attaches to the change its checkout
     was working on at that moment: the change of that checkout whose first attempt began no more than the gap after
     it and whose last row was written at or after it, the one whose last row is soonest. One that attaches to nothing
     is counted as Unattached.

     CROSSING CHECKOUTS. Groups in two or more checkouts sharing one subjects_sha, at least one of which landed, are
     ONE change counted as crossing checkouts: a subject set that lands from another checkout links the two. A crossing
     change stays out of B6's denominator and is counted on its own line (step 3).

     DRY RUNS move nothing (W2.1R step 7), so they are no attempt and are counted as DryRuns. #>
  param($Rows, $HookRefused = @(), [int]$GapSec = $script:TcPpcChangeGapSec)
  $bySub = @{}; $byCid = @{}; $noCid = @{}; $dry = 0
  foreach ($r in @($Rows)) {
    if ($null -eq $r) { continue }
    if ([string](Get-TcPpcProp $r 'outcome') -eq 'dry-run') { $dry++; continue }
    $co = Get-TcPpcCheckoutKey $r
    $sub = [string](Get-TcPpcProp $r 'subjects_sha')
    $cid = [string](Get-TcPpcProp $r 'change_id')
    if ($sub) {
      $k = $co + '|' + $sub
      if (-not $bySub.ContainsKey($k)) { $bySub[$k] = [Collections.Generic.List[object]]::new() }
      $bySub[$k].Add($r)
    } elseif ($cid) {
      $k = $co + '|' + $cid
      if (-not $byCid.ContainsKey($k)) { $byCid[$k] = [Collections.Generic.List[object]]::new() }
      $byCid[$k].Add($r)
    } else {
      if (-not $noCid.ContainsKey($co)) { $noCid[$co] = [Collections.Generic.List[object]]::new() }
      $noCid[$co].Add($r)
    }
  }
  $groups = [Collections.Generic.List[object]]::new()
  foreach ($k in @($bySub.Keys | Sort-Object)) {
    $sorted = @($bySub[$k].ToArray() | Sort-Object { Get-TcPpcRowAnchor $_ })
    $cur = [Collections.Generic.List[object]]::new()
    $landedCid = $null
    foreach ($r in $sorted) {
      if ($cur.Count -and $null -ne $landedCid -and -not [string]::Equals([string](Get-TcPpcProp $r 'change_id'), $landedCid, [StringComparison]::Ordinal)) {
        $groups.Add([pscustomobject]@{ How = 'subjects'; Checkout = (Get-TcPpcCheckoutKey $cur[0]); Subjects = [string](Get-TcPpcProp $cur[0] 'subjects_sha'); Rows = $cur; Hook = [Collections.Generic.List[object]]::new(); Merged = $false })
        $cur = [Collections.Generic.List[object]]::new()
        $landedCid = $null
      }
      $cur.Add($r)
      if ($null -eq $landedCid -and (Test-TcPpcLanded $r)) { $landedCid = [string](Get-TcPpcProp $r 'change_id') }
    }
    if ($cur.Count) { $groups.Add([pscustomobject]@{ How = 'subjects'; Checkout = (Get-TcPpcCheckoutKey $cur[0]); Subjects = [string](Get-TcPpcProp $cur[0] 'subjects_sha'); Rows = $cur; Hook = [Collections.Generic.List[object]]::new(); Merged = $false }) }
  }
  foreach ($k in @($byCid.Keys | Sort-Object)) {
    $groups.Add([pscustomobject]@{ How = 'change_id'; Checkout = (Get-TcPpcCheckoutKey $byCid[$k][0]); Subjects = ''; Rows = $byCid[$k]; Hook = [Collections.Generic.List[object]]::new(); Merged = $false })
  }
  foreach ($co in @($noCid.Keys | Sort-Object)) {
    $sorted = @($noCid[$co].ToArray() | Sort-Object { Get-TcPpcRowAnchor $_ })
    $cur = [Collections.Generic.List[object]]::new()
    $prevTs = $null; $prevLanded = $false
    foreach ($r in $sorted) {
      $st = Get-TcPpcRowAnchor $r
      if ($cur.Count -and ($prevLanded -or ($null -ne $prevTs -and ($st - $prevTs).TotalSeconds -gt $GapSec))) {
        $groups.Add([pscustomobject]@{ How = 'gap'; Checkout = $co; Subjects = ''; Rows = $cur; Hook = [Collections.Generic.List[object]]::new(); Merged = $false })
        $cur = [Collections.Generic.List[object]]::new()
      }
      $cur.Add($r)
      $prevTs = ConvertTo-TcPpcUtc (Get-TcPpcProp $r 'ts')
      $prevLanded = Test-TcPpcLanded $r
    }
    if ($cur.Count) { $groups.Add([pscustomobject]@{ How = 'gap'; Checkout = $co; Subjects = ''; Rows = $cur; Hook = [Collections.Generic.List[object]]::new(); Merged = $false }) }
  }
  # Attach each plain push's attempt to the change its checkout was working on.
  $unattached = 0
  foreach ($h in @($HookRefused)) {
    if ($null -eq $h) { continue }
    $co = Get-TcPpcCheckoutKey $h
    $t = Get-TcPpcRowAnchor $h
    $best = $null; $bestLast = $null
    foreach ($g in $groups) {
      if ($g.Checkout -ne $co) { continue }
      $f = $null; $l = $null
      foreach ($r in $g.Rows) {
        $a = Get-TcPpcRowAnchor $r; if ($null -eq $f -or $a -lt $f) { $f = $a }
        $w = ConvertTo-TcPpcUtc (Get-TcPpcProp $r 'ts'); if ($null -eq $w) { $w = $a }; if ($null -eq $l -or $w -gt $l) { $l = $w }
      }
      if ($t -lt $f.AddSeconds(-$GapSec) -or $t -gt $l) { continue }
      if ($null -eq $best -or $l -lt $bestLast) { $best = $g; $bestLast = $l }
    }
    if ($null -eq $best) { $unattached++ } else { $best.Hook.Add($h) }
  }
  # Link groups across checkouts that share a subject set, once one of them landed.
  $bySubAll = @{}
  foreach ($g in $groups) { if ($g.Subjects) { if (-not $bySubAll.ContainsKey($g.Subjects)) { $bySubAll[$g.Subjects] = [Collections.Generic.List[object]]::new() }; $bySubAll[$g.Subjects].Add($g) } }
  $changes = [Collections.Generic.List[object]]::new()
  foreach ($s in @($bySubAll.Keys | Sort-Object)) {
    $gs = $bySubAll[$s]
    $cos = @{}; $anyLanded = $false
    foreach ($g in $gs) { $cos[$g.Checkout] = $true; foreach ($r in $g.Rows) { if (Test-TcPpcLanded $r) { $anyLanded = $true } } }
    if ($cos.Count -lt 2 -or -not $anyLanded) { continue }
    $rows = [Collections.Generic.List[object]]::new(); $hooks = [Collections.Generic.List[object]]::new()
    foreach ($g in $gs) { foreach ($r in $g.Rows) { $rows.Add($r) }; foreach ($r in $g.Hook) { $hooks.Add($r) }; $g.Merged = $true }
    $changes.Add((New-TcPpcChange -Rows $rows.ToArray() -How 'subjects' -HookRows $hooks.ToArray() -Crosses $true))
  }
  foreach ($g in $groups) {
    if ($g.Merged) { continue }
    $changes.Add((New-TcPpcChange -Rows $g.Rows.ToArray() -How $g.How -HookRows $g.Hook.ToArray()))
  }
  return [pscustomobject]@{ Changes = $changes.ToArray(); Unattached = $unattached; DryRuns = $dry }
}

function Group-TcPpcChanges {
  <# The changes alone, for callers that need no attempt counts (W0.3's section 3 and its fixtures). #>
  param($Rows, [int]$GapSec = $script:TcPpcChangeGapSec, $HookRefused = @())
  $cs = Get-TcPpcChangeSet -Rows $Rows -HookRefused $HookRefused -GapSec $GapSec
  return , ($cs.Changes)
}

function Get-TcPpcHourKey { param($At) return ([datetime]$At).ToString('yyyy-MM-ddTHH') }

function Get-TcPpcHourLandings {
  <# Landings per UTC clock hour, keyed 'yyyy-MM-ddTHH'. From reflog landings (objects with Ts), or, with
     -FromRows, from the landed push-main rows' ts, which is the fallback when the reflog cannot be read and misses
     every plain push. #>
  param($Landings, [switch]$FromRows)
  $h = @{}
  foreach ($l in @($Landings)) {
    if ($null -eq $l) { continue }
    if ($FromRows) {
      if (-not (Test-TcPpcLanded $l)) { continue }
      $t = ConvertTo-TcPpcUtc (Get-TcPpcProp $l 'ts')
    } else { $t = $l.Ts }
    if ($null -eq $t) { continue }
    $k = Get-TcPpcHourKey $t
    if ($h.ContainsKey($k)) { $h[$k] = [int]$h[$k] + 1 } else { $h[$k] = 1 }
  }
  return $h
}

function Get-TcPpcChangeStratum {
  <# W0.3b step 5: CONTENDED when any attempt of the change is a row inside a parallel run (its session, inside the
     run's first and last row), or began in a UTC clock hour with at least $script:TcPpcContendedHourLandings landings;
     QUIET otherwise. A hook-refused row carries no session, so only its hour can make a change contended. #>
  param($Change, $Runs, $HourLandings)
  foreach ($r in @($Change.Rows)) {
    $s = [string](Get-TcPpcProp $r 'session')
    $t = ConvertTo-TcPpcUtc (Get-TcPpcProp $r 'ts')
    if ($s -and $null -ne $t) {
      foreach ($x in @($Runs)) { if ($null -ne $x -and $x.Session -eq $s -and $t -ge $x.Start -and $t -le $x.End) { return 'contended' } }
    }
    if ($null -ne $HourLandings) {
      $k = Get-TcPpcHourKey (Get-TcPpcRowAnchor $r)
      if ($HourLandings.ContainsKey($k) -and [int]$HourLandings[$k] -ge $script:TcPpcContendedHourLandings) { return 'contended' }
    }
  }
  return 'quiet'
}

function Get-TcPpcNegBinCdf {
  <# P(n changes take at most $Attempts attempts in total | each attempt lands independently with probability $Q):
     the sum of n geometric counts on {1, 2, ...}, so the failures are negative binomial. It is the chance of a result
     this good or better if nothing had changed, which is what "P(result | old rate)" asks. A model, printed as one. #>
  param([int]$Changes, [int]$Attempts, [double]$Q)
  if ($Changes -le 0) { return 1.0 }
  $f = $Attempts - $Changes
  if ($f -lt 0) { return 0.0 }
  $term = [math]::Pow($Q, $Changes)
  $sum = $term
  for ($k = 0; $k -lt $f; $k++) { $term = $term * ($k + $Changes) / ($k + 1) * (1.0 - $Q); $sum += $term }
  if ($sum -gt 1.0) { $sum = 1.0 }
  return $sum
}

function Measure-TcPpcB6 {
  <# B6 (amended, 15.6) over landed chain-touching changes that did not cross checkouts, by stratum. (a) counted
     attempts per change: every attempt except the change's own reds and its genuine conflicts, because an exclusion
     needs evidence and an undecided red or an unrecorded conflict has none. (b) leg sets per change, over the changes
     whose every push-main row carries rounds. The bars are compared in INTEGERS (5A <= 6n is 1.2, 2A <= 3n is 1.5,
     5L <= 9n is 1.8), so a case at the bar is decided by the rule and never by a double. Under the minimum N there is
     NO VERDICT, never a pass. #>
  param($Changes, $Runs, $HourLandings)
  $landedChain = @(@($Changes) | Where-Object { $_.Landed -and $_.Population -eq 'chain-touching' })
  $cross = @($landedChain | Where-Object { $_.Crosses })
  $out = [ordered]@{}
  foreach ($st in @('quiet', 'contended')) {
    $cs = @($landedChain | Where-Object { -not $_.Crosses -and (Get-TcPpcChangeStratum -Change $_ -Runs $Runs -HourLandings $HourLandings) -eq $st })
    $cols = [ordered]@{}
    foreach ($k in $script:TcPpcAttemptColumns) { $cols[$k] = 0 }
    $n = $cs.Count; $att = 0; $counted = 0; $first = 0
    foreach ($c in $cs) { $att += $c.Attempts; $counted += $c.Counted; if ($c.FirstAttemptLanded) { $first++ }; foreach ($k in $script:TcPpcAttemptColumns) { $cols[$k] = [int]$cols[$k] + [int]$c.Classes[$k] } }
    $withLegs = @($cs | Where-Object { $null -ne $_.LegSets })
    $legs = 0; foreach ($c in $withLegs) { $legs += [int]$c.LegSets }
    $minN = if ($st -eq 'quiet') { $script:TcPpcB6QuietMinN } else { $script:TcPpcB6ContendedMinN }
    if ($n -lt $minN) { $va = ('no verdict (N={0} changes, under {1})' -f $n, $minN) }
    elseif ($st -eq 'quiet') { $va = $(if (5 * $counted -le 6 * $n) { 'pass' } else { 'fail' }) }
    else { $va = $(if (2 * $counted -le 3 * $n) { 'pass' } else { 'fail' }) }
    $nl = $withLegs.Count
    if ($st -ne 'quiet') { $vb = 'reported, no bar when contended' }
    elseif ($nl -lt $minN) { $vb = ('no verdict (N={0} changes carrying rounds, under {1})' -f $nl, $minN) }
    else { $vb = $(if (5 * $legs -le 9 * $nl) { 'pass' } else { 'fail' }) }
    $p = [ordered]@{}
    foreach ($rate in $script:TcPpcB6OldRates) { $p[([string]$rate)] = (Get-TcPpcNegBinCdf -Changes $n -Attempts $counted -Q (1.0 / $rate)) }
    $out[$st] = [pscustomobject]@{ Changes = $n; Attempts = $att; Counted = $counted; FirstAttempt = $first; Columns = $cols; LegChanges = $nl; LegSets = $legs; AVerdict = $va; BVerdict = $vb; P = $p }
  }
  return [pscustomobject]@{ Strata = $out; Crossing = $cross.Count; CrossingFirst = @($cross | Where-Object { $_.FirstAttemptLanded }).Count }
}

function Split-TcPpcFlushRows {
  <# The D7 input's split. A row is a FLUSH row when an ops/run-gates.ps1 commit landed after the previous row of its
     checkout began (or after the window opened, for its first row) and at or before this row began. #>
  param($Rows, $LandingTimes, [datetime]$WindowStartUtc)
  $flush = [Collections.Generic.List[object]]::new()
  $other = [Collections.Generic.List[object]]::new()
  $by = @{}
  foreach ($r in @($Rows)) {
    if ($null -eq $r) { continue }
    $co = Get-TcPpcCheckoutKey $r
    if (-not $by.ContainsKey($co)) { $by[$co] = [Collections.Generic.List[object]]::new() }
    $by[$co].Add($r)
  }
  foreach ($co in @($by.Keys | Sort-Object)) {
    $sorted = @($by[$co].ToArray() | Sort-Object { Get-TcPpcRowAnchor $_ })
    $prev = $WindowStartUtc
    foreach ($r in $sorted) {
      $a = Get-TcPpcRowAnchor $r
      $hit = $false
      foreach ($lt in @($LandingTimes)) { if ($null -ne $lt -and $lt -gt $prev -and $lt -le $a) { $hit = $true; break } }
      if ($hit) { $flush.Add($r) } else { $other.Add($r) }
      $prev = $a
    }
  }
  return [pscustomobject]@{ Flush = $flush.ToArray(); Other = $other.ToArray() }
}

function Find-TcPpcParallelRuns {
  <# W0.3 step 2: a PARALLEL RUN is at least $MinCheckouts distinct checkouts sharing one session that each wrote a
     push-main row within one window of $WindowSec (inclusive). Overlapping qualifying windows of one session merge
     into one run. Rows without a session cannot form one. #>
  param($Rows, [int]$MinCheckouts = $script:TcPpcParallelMinCheckouts, [int]$WindowSec = $script:TcPpcParallelWindowSec)
  $bySession = @{}
  foreach ($r in @($Rows)) {
    if ($null -eq $r) { continue }
    $s = [string](Get-TcPpcProp $r 'session')
    if (-not $s) { continue }
    if ($null -eq (ConvertTo-TcPpcUtc (Get-TcPpcProp $r 'ts'))) { continue }
    if (-not $bySession.ContainsKey($s)) { $bySession[$s] = [Collections.Generic.List[object]]::new() }
    $bySession[$s].Add($r)
  }
  $runs = [Collections.Generic.List[object]]::new()
  foreach ($s in @($bySession.Keys | Sort-Object)) {
    $sorted = @($bySession[$s].ToArray() | Sort-Object { ConvertTo-TcPpcUtc (Get-TcPpcProp $_ 'ts') })
    $n = $sorted.Count
    $tsArr = @($sorted | ForEach-Object { ConvertTo-TcPpcUtc (Get-TcPpcProp $_ 'ts') })
    $runStart = -1; $runEnd = -1
    for ($i = 0; $i -lt $n; $i++) {
      $set = @{}; $k = $i
      for ($j = $i; $j -lt $n; $j++) {
        if (($tsArr[$j] - $tsArr[$i]).TotalSeconds -gt $WindowSec) { break }
        $set[(Get-TcPpcCheckoutKey $sorted[$j])] = $true
        $k = $j
      }
      if ($set.Count -ge $MinCheckouts) {
        if ($runStart -ge 0 -and $i -le $runEnd) { if ($k -gt $runEnd) { $runEnd = $k } }
        else {
          if ($runStart -ge 0) { $runs.Add((New-TcPpcParallelRun -Session $s -Rows $sorted -From $runStart -To $runEnd)) }
          $runStart = $i; $runEnd = $k
        }
      }
    }
    if ($runStart -ge 0) { $runs.Add((New-TcPpcParallelRun -Session $s -Rows $sorted -From $runStart -To $runEnd)) }
  }
  return , ($runs.ToArray())
}

function New-TcPpcParallelRun {
  param([string]$Session, $Rows, [int]$From, [int]$To)
  $set = @{}
  for ($i = $From; $i -le $To; $i++) { $set[(Get-TcPpcCheckoutKey $Rows[$i])] = $true }
  return [pscustomobject]@{
    Session = $Session; Rows = ($To - $From + 1); Checkouts = $set.Count
    Start = (ConvertTo-TcPpcUtc (Get-TcPpcProp $Rows[$From] 'ts')); End = (ConvertTo-TcPpcUtc (Get-TcPpcProp $Rows[$To] 'ts'))
  }
}

function Measure-TcPpcHours {
  <# Landings per ACTIVE hour (a UTC clock hour with at least one push-main row) and the BUSY hours (at least
     $BusyRows push-main rows, B8's stratum). #>
  param($Rows, [int]$BusyRows = $script:TcPpcBusyHourRows)
  $h = @{}
  foreach ($r in @($Rows)) {
    if ($null -eq $r) { continue }
    $t = ConvertTo-TcPpcUtc (Get-TcPpcProp $r 'ts')
    if ($null -eq $t) { continue }
    $key = $t.ToString('yyyy-MM-ddTHH') + 'Z'
    if (-not $h.ContainsKey($key)) { $h[$key] = [pscustomobject]@{ Hour = $key; Rows = 0; Landings = 0 } }
    $e = $h[$key]
    $e.Rows = $e.Rows + 1
    if (Test-TcPpcLanded $r) { $e.Landings = $e.Landings + 1 }
  }
  $hours = @($h.Values | Sort-Object Hour)
  $busy = @($hours | Where-Object { $_.Rows -ge $BusyRows })
  $land = 0
  foreach ($e in $hours) { $land += $e.Landings }
  return [pscustomobject]@{ Active = $hours.Count; Landings = $land; Busy = $busy; Hours = $hours }
}

function Format-TcPpcWindow { param($Ctx) return ('{0} to {1} UTC' -f (Format-TcPpcUtc $Ctx.StartUtc), (Format-TcPpcUtc $Ctx.EndUtc)) }

function Format-TcPpcCounts {
  <# 'a 3, b 2' in a fixed order first, then the rest sorted; '(none)' for nothing. #>
  param($Table, $Order = @())
  $parts = [Collections.Generic.List[string]]::new()
  $done = @{}
  foreach ($k in @($Order)) { if ($Table.Contains($k)) { $parts.Add(('{0} {1}' -f $k, $Table[$k])); $done[$k] = $true } }
  foreach ($k in @($Table.Keys | Sort-Object)) { if (-not $done.ContainsKey($k)) { $parts.Add(('{0} {1}' -f $k, $Table[$k])) } }
  if (-not $parts.Count) { return '(none)' }
  return ($parts -join ', ')
}

function Add-TcPpcCount { param($Table, [string]$Key) if ($Table.Contains($Key)) { $Table[$Key] = [int]$Table[$Key] + 1 } else { $Table[$Key] = 1 } }

function Format-TcPpcShare {
  <# 'N of M (P%)', with the denominator always printed; 'N of 0' when there is none (W0.3b step 7). #>
  param([int]$Part, [int]$Whole)
  if ($Whole -le 0) { return ('{0} of 0' -f $Part) }
  return ('{0} of {1} ({2:N1}%)' -f $Part, $Whole, (100.0 * $Part / $Whole))
}

function Write-TcPpcCostHead {
  param($Rows, $Ctx)
  $s = $Ctx.Sel
  Write-TcPpcLine ('push-main cost over {0} (written by ops\probe-push-convergence.ps1 -Cost; cite its blob)' -f (Format-TcPpcWindow $Ctx))
  Write-TcPpcLine ('  ledger files read {0}; rows in the window {1}, of them malformed {2} (a malformed row is counted wherever it sat in a file read)' -f @($Ctx.Files).Count, $s.Read, $s.Malformed)
  Write-TcPpcLine ('  excluded {0} rows: test-prepush sandbox checkouts (%TEMP%\{1}*), {2} of them named with W0.2''s blob segment' -f $s.ExcludedSandbox, $script:TcPpcSandboxLeaf, $s.ExcludedSandboxBlob)
  Write-TcPpcLine ('  excluded {0} rows: other fixture checkouts under %TEMP%' -f $s.ExcludedTemp)
  Write-TcPpcLine ('  not costed {0} rows: hook-lock and other events that are not push-main' -f $s.OtherEvents)
  $hrN = @(Get-TcPpcProp $s 'HookRefused' | Where-Object { $null -ne $_ }).Count
  $hrU = [int](Get-TcPpcProp $s 'HookRefusedUnderPm')
  Write-TcPpcLine ('    of them hook-refused rows (W0.6): {0} of a plain push, kept as ATTEMPTS for section 3; {1} written under a push-main, whose own row records the attempt' -f $hrN, $hrU)
  Write-TcPpcLine ('  kept {0} push-main rows' -f @($s.Kept).Count)
  $pre = 0; $unk = 0; $withBlob = 0
  $by = [ordered]@{}
  foreach ($r in @($s.Kept)) {
    $pb = [string](Get-TcPpcProp $r 'pm_blob')
    if (-not $pb) { $pre++; continue }
    $withBlob++
    if ($null -ne $Ctx.Index -and $Ctx.Index.First.ContainsKey($pb)) {
      $e = $Ctx.Index.First[$pb]
      Add-TcPpcCount $by ((Format-TcPpcShort ([string]$e.Commit)) + ' ' + (Format-TcPpcUtc $e.Ts))
    } else { $unk++ }
  }
  Write-TcPpcLine ('  copies: {0} of them carry pm_blob (W0.1 or later), {1} are pre-W0.1 (no pm_blob), {2} carry a blob not on the push-main history (unknown-copy)' -f $withBlob, $pre, $unk)
  foreach ($k in @($by.Keys)) { Write-TcPpcLine ('    push-main first landed at {0}: {1} rows' -f $k, $by[$k]) }
  if (-not $Ctx.BlobOk) { Write-TcPpcLine '  the push-main blob history could not be read from git, so no pm_blob maps: every carrying row reads unknown-copy' }
  if ($null -ne $Ctx.Bar) {
    $b = $Ctx.Bar
    $c = Measure-TcPpcBarCopies -Rows $s.Kept -State $b -Index $Ctx.Index
    Write-TcPpcLine ('  BAR {0} ({1}): landed {2} at {3}; read-out {4}; the window runs from the landing to the read-out or now, whichever is first' -f $b.Id, (@($b.Def.Items) -join ', '), (Format-TcPpcShort ([string]$b.Landing.Sha)), (Format-TcPpcUtc $b.Landing.Ts), (Format-TcPpcUtc $b.Readout))
    Write-TcPpcLine ('    treated {0}; older-copy rows excluded {1}; unknown-copy rows excluded {2}; pre-W0.1 rows excluded {3}; no base {4}; base before the landing {5}; landing blob unmapped {6}' -f $c['treated'], (Format-TcPpcShare $c['older-copy'] @($s.Kept).Count), $c['unknown-copy'], $c['pre-w01'], $c['no-base'], $c['base-before-landing'], $c['unknown-landing'])
    Write-TcPpcLine ('    every section below is over the {0} treated rows only' -f @($Rows).Count)
  }
}

function Write-TcPpcCostOutcomes {
  param($Rows, $Ctx)
  Write-TcPpcLine ''
  Write-TcPpcLine ('1. push-main outcomes by UTC day ({0}), N={1} rows' -f (Format-TcPpcWindow $Ctx), @($Rows).Count)
  $dayTab = [ordered]@{}
  foreach ($r in @($Rows | Sort-Object { ConvertTo-TcPpcUtc (Get-TcPpcProp $_ 'ts') })) {
    $t = ConvertTo-TcPpcUtc (Get-TcPpcProp $r 'ts')
    $d = if ($null -eq $t) { '(no ts)' } else { $t.ToString('yyyy-MM-dd') }
    if (-not $dayTab.Contains($d)) { $dayTab[$d] = [ordered]@{} }
    $o = [string](Get-TcPpcProp $r 'outcome'); if (-not $o) { $o = '(none)' }
    Add-TcPpcCount $dayTab[$d] $o
  }
  if (-not $dayTab.Count) { Write-TcPpcLine '   no push-main row in this window' }
  foreach ($d in @($dayTab.Keys)) {
    $tot = 0; foreach ($v in $dayTab[$d].Values) { $tot += [int]$v }
    Write-TcPpcLine ('   {0}  total {1}: {2}' -f $d, $tot, (Format-TcPpcCounts $dayTab[$d] $script:TcPpcOutcomeOrder))
  }
}

function Write-TcPpcCostDurations {
  param($Rows, $Ctx)
  Write-TcPpcLine ''
  Write-TcPpcLine ('2. seconds from the push-main start (the start time in the row''s run id) to its row ({0})' -f (Format-TcPpcWindow $Ctx))
  $all = @($Rows)
  $with = @($all | Where-Object { $null -ne (Get-TcPpcRowSeconds $_) })
  Write-TcPpcLine ('   rows with a readable start: {0} of {1} (the rest carry no run id, from before backlog I171, or a fixture''s)' -f $with.Count, $all.Count)
  foreach ($axis in @('outcome', 'phase', 'population')) {
    $g = [ordered]@{}
    foreach ($r in $with) {
      $k = switch ($axis) {
        'outcome' { $o = [string](Get-TcPpcProp $r 'outcome'); if ($o) { $o } else { '(none)' } }
        'phase' { $p = [string](Get-TcPpcProp $r 'phase'); if ($p) { $p } else { '(none: a landing, or a row before W0.1)' } }
        'population' { Get-TcPpcChainClass $r }
        default { throw ('unknown duration axis: ' + $axis) }
      }
      if (-not $g.Contains($k)) { $g[$k] = [Collections.Generic.List[object]]::new() }
      $g[$k].Add((Get-TcPpcRowSeconds $r))
    }
    Write-TcPpcLine ('   by {0}:' -f $axis)
    if (-not $g.Count) { Write-TcPpcLine '     (no row)' }
    foreach ($k in @($g.Keys | Sort-Object)) { Write-TcPpcLine ('     {0,-40} {1}' -f $k, (Format-TcPpcStats (Get-TcPpcStats $g[$k].ToArray()))) }
  }
  $raw = [ordered]@{}
  foreach ($r in $all) {
    $v = Get-TcPpcProp $r 'chain_touching'
    if ($null -ne $v -and (Get-TcPpcChainClass $r) -eq 'unknown') { Add-TcPpcCount $raw ([string]$v) }
  }
  if ($raw.Count) { Write-TcPpcLine ('   chain_touching values this reader does not know, counted unknown: {0}' -f (Format-TcPpcCounts $raw)) }
}

function Write-TcPpcCostChanges {
  param($Rows, $Ctx)
  Write-TcPpcLine ''
  Write-TcPpcLine ('3. changes and their attempts ({0}). An ATTEMPT is a push-main row or a plain push''s hook-refused row (W0.6); a LEG SET is one push-main round (rounds, W0.1R); a change is (checkout, subjects_sha), else (checkout, change_id), else a 6-hour gap within one checkout' -f (Format-TcPpcWindow $Ctx))
  $hr = @(Get-TcPpcProp $Ctx.Sel 'HookRefused' | Where-Object { $null -ne $_ })
  $cs = Get-TcPpcChangeSet -Rows $Rows -HookRefused $hr
  $all = @($cs.Changes)
  $pmAtt = 0; $hkAtt = 0
  foreach ($c in $all) { $pmAtt += $c.PmRows; $hkAtt += $c.HookRows }
  Write-TcPpcLine ('   attempts {0}: push-main rows {1}, plain-push hook refusals attached to a change {2}; left out: plain-push hook refusals attached to no change {3}, dry runs {4} (they move nothing), hook refusals under a push-main {5} (its own row records them)' -f ($pmAtt + $hkAtt), $pmAtt, $hkAtt, $cs.Unattached, $cs.DryRuns, [int](Get-TcPpcProp $Ctx.Sel 'HookRefusedUnderPm'))
  $bySub = @($all | Where-Object { $_.How -eq 'subjects' }).Count
  $byCid = @($all | Where-Object { $_.How -eq 'change_id' }).Count
  $byGap = @($all | Where-Object { $_.How -eq 'gap' }).Count
  $landed = @($all | Where-Object { $_.Landed })
  $cross = @($all | Where-Object { $_.Crosses })
  Write-TcPpcLine ('   changes {0}: by subjects_sha {1}, by change_id {2} (rows before W0.1R), by a gap {3} (rows before W0.1, labelled so); landed {4}, not landed in the window {5}; crossing checkouts {6} (landed {7}, on its first attempt {8}), out of B6''s denominator' -f $all.Count, $bySub, $byCid, $byGap, $landed.Count, ($all.Count - $landed.Count), $cross.Count, @($cross | Where-Object { $_.Landed }).Count, @($cross | Where-Object { $_.FirstAttemptLanded }).Count)
  foreach ($pop in @('generic', 'chain-touching', 'unknown')) {
    $v = @($landed | Where-Object { $_.Population -eq $pop } | ForEach-Object { $_.Seconds })
    Write-TcPpcLine ('   {0,-15} first attempt to landing: {1} changes' -f $pop, (Format-TcPpcStats (Get-TcPpcStats $v)))
  }
  $att = @($landed | ForEach-Object { $_.Attempts })
  $attC = @($landed | Where-Object { $_.Population -eq 'chain-touching' } | ForEach-Object { $_.Attempts })
  Write-TcPpcLine ('   attempts per landed change, every attempt counted: {0}; chain-touching only: {1}' -f (Format-TcPpcStats (Get-TcPpcStats $att) -Unit ''), (Format-TcPpcStats (Get-TcPpcStats $attC) -Unit ''))
  $withLegs = @($landed | Where-Object { $null -ne $_.LegSets })
  $lg = @($withLegs | ForEach-Object { $_.LegSets })
  $lgC = @($withLegs | Where-Object { $_.Population -eq 'chain-touching' } | ForEach-Object { $_.LegSets })
  Write-TcPpcLine ('   leg sets per landed change, rounds summed over changes whose every push-main row carries rounds ({0}): {1}; chain-touching only: {2}' -f (Format-TcPpcShare $withLegs.Count $landed.Count), (Format-TcPpcStats (Get-TcPpcStats $lg) -Unit ''), (Format-TcPpcStats (Get-TcPpcStats $lgC) -Unit ''))
  $pre = @($landed | Where-Object { $null -eq $_.LegSets })
  if ($pre.Count) {
    # B6's OLD LINE, kept for rows that carry no rounds: W0.3's count of push-main rows per landed change.
    $preA = @($pre | ForEach-Object { $_.PmRows })
    $preC = @($pre | Where-Object { $_.Population -eq 'chain-touching' } | ForEach-Object { $_.PmRows })
    Write-TcPpcLine ('   B6''s old line, pre-W0.1 ({0} landed changes whose rows carry no rounds): push-main rows per landed change: {1}; chain-touching only (B6): {2}' -f $pre.Count, (Format-TcPpcStats (Get-TcPpcStats $preA) -Unit ''), (Format-TcPpcStats (Get-TcPpcStats $preC) -Unit ''))
  }
  $runs = Find-TcPpcParallelRuns -Rows $Rows
  $hl = Get-TcPpcProp $Ctx 'HourLandings'
  $hlFrom = [string](Get-TcPpcProp $Ctx 'HourSource')
  if ($null -eq $hl) { $hl = Get-TcPpcHourLandings -Landings $Rows -FromRows; $hlFrom = 'landed push-main rows only (no reflog was read), which misses every plain push' }
  Write-TcPpcB6Lines -Changes $all -Runs $runs -HourLandings $hl -HourFrom $hlFrom -Judge ($null -ne $Ctx.Bar -and $Ctx.Bar.Id -eq 'B6')
  Write-TcPpcB10Lines -Changes $all -Runs $runs -HourLandings $hl
}

function Write-TcPpcB6Lines {
  <# B6 (amended, 15.6) by stratum. -Judge prints the verdicts; without it the rows are not treated for B6, so the
     figures are reported and the verdict is withheld. #>
  param($Changes, $Runs, $HourLandings, [string]$HourFrom, [switch]$Judge)
  $m = Measure-TcPpcB6 -Changes $Changes -Runs $Runs -HourLandings $HourLandings
  Write-TcPpcLine ('   B6 (amended, 15.6), landed chain-touching changes not crossing checkouts; strata by parallel run and by landings in the hour (contended at {0} or more; hours read from {1}); crossing checkouts, counted apart: {2} (on its first attempt {3})' -f $script:TcPpcContendedHourLandings, $HourFrom, $m.Crossing, $m.CrossingFirst)
  Write-TcPpcLine '     columns: own red and genuine conflict are EXCLUDED from (a); every other column is COUNTED, an undecided red and an unrecorded conflict included, because an exclusion needs evidence. own against ambient is read from the patch (a red whose change_id equals the landing''s is ambient); mechanical means every conflict file is backlog-index or reread, so a header-line conflict in a .ps1 reads genuine'
  foreach ($st in @('quiet', 'contended')) {
    $s = $m.Strata[$st]
    $cols = (@($script:TcPpcAttemptColumns | ForEach-Object { '{0} {1}' -f $_, $s.Columns[$_] }) -join ', ')
    $bar = if ($st -eq 'quiet') { 'at most 1.2 over at least {0}' -f $script:TcPpcB6QuietMinN } else { 'at most 1.5 over at least {0}' -f $script:TcPpcB6ContendedMinN }
    $ratio = if ($s.Changes) { '{0:N2}' -f ($s.Counted / $s.Changes) } else { 'n/a' }
    $legR = if ($s.LegChanges) { '{0:N2}' -f ($s.LegSets / $s.LegChanges) } else { 'n/a' }
    $va = if ($Judge) { $s.AVerdict } else { 'not judged here: run -Cost -Bar B6, whose rows are treated' }
    $vb = if ($Judge) { $s.BVerdict } else { 'not judged here' }
    Write-TcPpcLine ('     {0,-9} changes {1} (landed on the first attempt {2}); attempts {3}: {4}' -f $st, $s.Changes, $s.FirstAttempt, $s.Attempts, $cols)
    Write-TcPpcLine ('               (a) counted attempts per change {0} ({1} over {2}); bar {3}; verdict {4}' -f $ratio, $s.Counted, $s.Changes, $bar, $va)
    Write-TcPpcLine ('               (b) leg sets per change {0} ({1} over {2} changes carrying rounds); bar {3}; verdict {4}' -f $legR, $s.LegSets, $s.LegChanges, $(if ($st -eq 'quiet') { 'at most 1.8' } else { 'none, reported' }), $vb)
    if ($st -eq 'quiet' -and -not $s.Changes) { Write-TcPpcLine '               P(result | old rate): no change in this stratum, so there is no result to weigh' }
    elseif ($st -eq 'quiet') {
      $ps = (@($s.P.Keys | ForEach-Object { 'at {0} per change {1:G4}' -f $_, $s.P[$_] }) -join '; ')
      Write-TcPpcLine ('               P(at most {0} counted attempts over {1} changes | old rate), each attempt landing independently with probability 1/rate: {2}' -f $s.Counted, $s.Changes, $ps)
    }
  }
  Write-TcPpcLine '     the plain-push share of chain landings, which B6 is read beside, is -History''s "chain landings by route"'
}

function Write-TcPpcB10Lines {
  <# B10, first attempt to landing per change, with the attempts and leg sets beside it (W0.3b step 1), by population
     and stratum. No old rate for B10 is recorded (its baseline is W0.3's first run), so no P is printed for it. #>
  param($Changes, $Runs, $HourLandings)
  $landed = @(@($Changes) | Where-Object { $_.Landed -and -not $_.Crosses })
  Write-TcPpcLine ('   B10, landed changes not crossing checkouts ({0}), by population and stratum: first attempt to landing, attempts per change, leg sets per change. P(result | old rate): none, because no old rate for B10 is recorded yet' -f $landed.Count)
  foreach ($pop in @('generic', 'chain-touching', 'unknown')) {
    foreach ($st in @('quiet', 'contended')) {
      $cs = @($landed | Where-Object { $_.Population -eq $pop -and (Get-TcPpcChangeStratum -Change $_ -Runs $Runs -HourLandings $HourLandings) -eq $st })
      if (-not $cs.Count) { Write-TcPpcLine ('     {0,-15} {1,-9} no change' -f $pop, $st); continue }
      $t = Get-TcPpcStats @($cs | ForEach-Object { $_.Seconds })
      $a = Get-TcPpcStats @($cs | ForEach-Object { $_.Attempts })
      $l = Get-TcPpcStats @($cs | Where-Object { $null -ne $_.LegSets } | ForEach-Object { $_.LegSets })
      Write-TcPpcLine ('     {0,-15} {1,-9} {2}; attempts {3}; leg sets {4}' -f $pop, $st, (Format-TcPpcStats $t), (Format-TcPpcStats $a -Unit ''), (Format-TcPpcStats $l -Unit ''))
    }
  }
}

function Write-TcPpcCostLegs {
  param($Rows, $Ctx)
  Write-TcPpcLine ''
  $all = @($Rows)
  $carry = @($all | Where-Object { $null -ne (Get-TcPpcProp $_ 'leg_sec') })
  Write-TcPpcLine ('4. leg seconds, from leg_sec ({0}); eligible rows {1} (every push-main row), rows carrying leg_sec {2}' -f (Format-TcPpcWindow $Ctx), $all.Count, $carry.Count)
  foreach ($leg in @(@('rg', 'run-gates'), @('ta', 'test-auditors'), @('rh', 'chain rehearsal'))) {
    $ran = [Collections.Generic.List[object]]::new(); $reused = 0; $notRun = 0
    foreach ($r in $carry) {
      $ls = Get-TcPpcProp $r 'leg_sec'
      $v = Get-TcPpcNum $ls $leg[0]
      if ($null -eq $v) { $notRun++ } elseif ($v -eq 0) { $reused++ } else { $ran.Add($v) }
    }
    $st = Get-TcPpcStats $ran.ToArray()
    $dist = if ($st.N) { ('median {0:N0} s, p75 {1:N0} s' -f $st.Median, $st.P75) } else { 'no distribution' }
    Write-TcPpcLine ('   {0} {1,-16} ran {2} ({3}); reused (0 s) {4}; did not run (null) {5}' -f $leg[0], $leg[1], $st.N, $dist, $reused, $notRun)
  }
  $rc = [ordered]@{}; $rcN = 0
  foreach ($r in $all) { $v = Get-TcPpcNum $r 'ta_rc'; if ($null -ne $v) { $rcN++; Add-TcPpcCount $rc ([string][int]$v) } }
  Write-TcPpcLine ('   ta_rc, test-auditors'' exit outside the lock (124 is its own 1200 s kill): {0} over {1} rows carrying it' -f (Format-TcPpcCounts $rc), $rcN)
  $tm = [ordered]@{}
  foreach ($r in $all) { $v = [string](Get-TcPpcProp $r 'ta_moved'); if ($v) { $k = if ($v -match 'kind=(\S+)') { $Matches[1] } else { $v }; Add-TcPpcCount $tm $k } }
  if ($tm.Count) { Write-TcPpcLine ('   ta_moved (W0.4) by kind: {0}' -f (Format-TcPpcCounts $tm)) }
  $hk = [ordered]@{}
  foreach ($r in $all) { $v = [string](Get-TcPpcProp $r 'hook_ta'); if ($v) { Add-TcPpcCount $hk $v } }
  Write-TcPpcLine ('   hook_ta, the in-lock test-auditors leg (B11): {0}' -f (Format-TcPpcCounts $hk @('reused', 'ran', 'not-needed', 'unknown')))
}

function Write-TcPpcCostLock {
  param($Rows, $Ctx)
  Write-TcPpcLine ''
  Write-TcPpcLine ('5. lock hold, lock_held_ms ({0})' -f (Format-TcPpcWindow $Ctx))
  $moved = [Collections.Generic.List[object]]::new(); $still = [Collections.Generic.List[object]]::new(); $none = 0
  foreach ($r in @($Rows)) {
    $v = Get-TcPpcNum $r 'lock_held_ms'
    if ($null -eq $v) { $none++; continue }
    $ph = Get-TcPpcList $r 'rebase_phases' -SplitComma
    if (@($ph | Where-Object { $_ -eq 'catchup' -or $_ -eq 'inlock' }).Count) { $moved.Add($v) } else { $still.Add($v) }
  }
  Write-TcPpcLine ('   main moved during the legs (rebase_phases names catchup or inlock): {0}' -f (Format-TcPpcStats (Get-TcPpcStats $moved.ToArray()) -Scale 1000))
  Write-TcPpcLine ('   main did not move:                                                {0}' -f (Format-TcPpcStats (Get-TcPpcStats $still.ToArray()) -Scale 1000))
  Write-TcPpcLine ('   rows without lock_held_ms: {0} (pre-W0.1, or the lock was never taken)' -f $none)
}

function Write-TcPpcCostConflicts {
  param($Rows, $Ctx)
  Write-TcPpcLine ''
  $cr = @(@($Rows) | Where-Object { [string](Get-TcPpcProp $_ 'outcome') -eq 'refused-rebase-conflict' })
  $withF = @($cr | Where-Object { (Get-TcPpcList $_ 'conflict_files').Count -gt 0 })
  Write-TcPpcLine ('6. conflict rows, outcome refused-rebase-conflict ({0}): {1}; with conflict_files {2}; without {3} (before W0.1; their attribution stays SCRATCH)' -f (Format-TcPpcWindow $Ctx), $cr.Count, $withF.Count, ($cr.Count - $withF.Count))
  $inst = [ordered]@{}; $rowsBy = [ordered]@{}; $outside = 0
  foreach ($r in $withF) {
    $seen = @{}
    foreach ($f in (Get-TcPpcList $r 'conflict_files')) { $c = Get-TcPpcFileClass $f; Add-TcPpcCount $inst $c; $seen[$c] = $true }
    foreach ($c in $seen.Keys) { Add-TcPpcCount $rowsBy $c }
    if (-not $seen.ContainsKey('backlog-index') -and -not $seen.ContainsKey('reread')) { $outside++ }
  }
  Write-TcPpcLine ('   file instances by class: {0}' -f (Format-TcPpcCounts $inst $script:TcPpcClassNames))
  Write-TcPpcLine ('   rows touching each class (a row counts once per class): {0}' -f (Format-TcPpcCounts $rowsBy $script:TcPpcClassNames))
  Write-TcPpcLine ('   rows with files outside the backlog-index and reread classes (the only conflicts the Row 2 bars count): {0} of {1}' -f $outside, $withF.Count)
  $anc = [ordered]@{}; $n = 0
  foreach ($e in @($Ctx.Ancestry)) { foreach ($x in @($e.Files)) { $n++; Add-TcPpcCount $anc ([string]$x.Ancestry) } }
  Write-TcPpcLine ('   ancestry of each colliding main commit against preflight_sha, over {0} file instances: {1}' -f $n, (Format-TcPpcCounts $anc @('before-preflight', 'after-preflight', 'unknown')))
  foreach ($e in @($Ctx.Ancestry)) {
    foreach ($x in @($e.Files)) {
      Write-TcPpcLine ('     {0} phase={1} {2} [{3}] collider {4} {5}{6}' -f (Format-TcPpcUtc (ConvertTo-TcPpcUtc (Get-TcPpcProp $e.Row 'ts'))), [string](Get-TcPpcProp $e.Row 'phase'), $x.File, $x.Class, (Format-TcPpcShort ([string]$x.Collider)), $x.Ancestry, $(if ($x.Why) { ' (' + $x.Why + ')' } else { '' }))
    }
  }
}

function Write-TcPpcCostRejects {
  param($Rows, $Ctx)
  Write-TcPpcLine ''
  $pr = @(@($Rows) | Where-Object { [string](Get-TcPpcProp $_ 'outcome') -eq 'push-rejected' })
  $t = [ordered]@{}; $unknownN = 0; $notRec = 0
  foreach ($r in $pr) {
    $c = [string](Get-TcPpcProp $r 'reject_class')
    if (-not $c) { $notRec++; $c = '(not recorded: before W0.1)' } elseif ($c -eq 'unknown') { $unknownN++ }
    Add-TcPpcCount $t $c
  }
  Write-TcPpcLine ('7. push-rejected rows ({0}): {1}; by reject_class: {2}' -f (Format-TcPpcWindow $Ctx), $pr.Count, (Format-TcPpcCounts $t))
  Write-TcPpcLine ('   unknown {0} of {1}; not recorded {2} of {1}. B2 gives no verdict while any in its window is unknown' -f $unknownN, $pr.Count, $notRec)
}

function Write-TcPpcCostCounters {
  param($Rows, $Ctx)
  Write-TcPpcLine ''
  Write-TcPpcLine ('8. counters ({0})' -f (Format-TcPpcWindow $Ctx))
  foreach ($name in @('backlog_direct', 'inbox_invalid', 'reread_doc_lines')) {
    $sum = 0.0; $n = 0; $pos = 0
    foreach ($r in @($Rows)) { $v = Get-TcPpcNum $r $name; if ($null -ne $v) { $n++; $sum += $v; if ($v -gt 0) { $pos++ } } }
    Write-TcPpcLine ('   {0,-17} total {1:N0} over {2} rows carrying it; rows over 0: {3}' -f $name, $sum, $n, $pos)
  }
}

function Write-TcPpcCostFlush {
  param($Rows, $Ctx)
  Write-TcPpcLine ''
  Write-TcPpcLine ('9. run-gates cache flush, the D7 input ({0})' -f (Format-TcPpcWindow $Ctx))
  if (-not $Ctx.RunGatesOk) { Write-TcPpcLine '   COULD NOT LOOK: git could not list the ops/run-gates.ps1 commits, so no row can be split'; return }
  $times = @(@($Ctx.RunGatesTimes) | Where-Object { $null -ne $_ -and $_ -ge $Ctx.StartUtc -and $_ -le $Ctx.EndUtc })
  Write-TcPpcLine ('   ops/run-gates.ps1 commits in the window: {0} (by committer date, which push-main''s rebase sets at landing; a plain push keeps its authoring time)' -f $times.Count)
  $rgRows = @(@($Rows) | Where-Object { $v = Get-TcPpcNum (Get-TcPpcProp $_ 'leg_sec') 'rg'; $null -ne $v -and $v -gt 0 })
  $sp = Split-TcPpcFlushRows -Rows $rgRows -LandingTimes $times -WindowStartUtc $Ctx.StartUtc
  $out = @{}
  foreach ($arm in @(@('flush', $sp.Flush), @('other', $sp.Other))) {
    $secs = @(@($arm[1]) | ForEach-Object { Get-TcPpcNum (Get-TcPpcProp $_ 'leg_sec') 'rg' })
    $st = Get-TcPpcStats $secs
    $re = 0.0; $tot = 0.0; $n = 0
    foreach ($r in @($arm[1])) { $a = Get-TcPpcNum $r 'rg_reused'; $b = Get-TcPpcNum $r 'rg_selftests'; if ($null -ne $a -and $null -ne $b) { $n++; $re += $a; $tot += $b } }
    $out[$arm[0]] = $st
    Write-TcPpcLine ('   {0,-5} rows (first in their checkout after such a commit, or the rest): run-gates {1}; reused {2:N0} of {3:N0} self-tests over {4} rows carrying both' -f $arm[0], (Format-TcPpcStats $st), $re, $tot, $n)
  }
  $spanDays = [math]::Max(1.0 / 24, ($Ctx.EndUtc - $Ctx.StartUtc).TotalDays)
  if ($out['flush'].N -and $out['other'].N) {
    $extra = ($out['flush'].Median - $out['other'].Median) * $out['flush'].N / $spanDays
    Write-TcPpcLine ('   extra run-gates seconds per day: (median flush - median other) x flush rows / days = ({0:N0} - {1:N0}) x {2} / {3:N2} = {4:N0} s/day. A first reading over medians, not a measured cost per flush' -f $out['flush'].Median, $out['other'].Median, $out['flush'].N, $spanDays, $extra)
  } else {
    Write-TcPpcLine '   extra run-gates seconds per day: no estimate, because one of the two arms holds no row'
  }
}

function Write-TcPpcCostLease {
  param($Rows, $Ctx)
  Write-TcPpcLine ''
  $lr = @(@($Rows) | Where-Object { [string](Get-TcPpcProp $_ 'lease') })
  $t = [ordered]@{}
  foreach ($r in $lr) { Add-TcPpcCount $t ([string](Get-TcPpcProp $r 'lease')) }
  Write-TcPpcLine ('10. the chain lease, W6.1 ({0}): rows carrying lease {1}; {2}' -f (Format-TcPpcWindow $Ctx), $lr.Count, (Format-TcPpcCounts $t @('held', 'off', 'timeout', 'error')))
  $hold = @($lr | ForEach-Object { Get-TcPpcNum $_ 'lease_hold_ms' })
  $wait = @($lr | ForEach-Object { Get-TcPpcNum $_ 'lease_wait_ms' })
  Write-TcPpcLine ('    lease_hold_ms: {0}; lease_wait_ms: {1}' -f (Format-TcPpcStats (Get-TcPpcStats $hold) -Scale 1000), (Format-TcPpcStats (Get-TcPpcStats $wait) -Scale 1000))
  $bad = @($lr | Where-Object { @('timeout', 'error') -contains [string](Get-TcPpcProp $_ 'lease') })
  Write-TcPpcLine ('    every lease=timeout or lease=error row ({0}):' -f $bad.Count)
  foreach ($r in $bad) {
    Write-TcPpcLine ('      {0} lease={1} wait_ms={2} holder={3} checkout={4}' -f (Format-TcPpcUtc (ConvertTo-TcPpcUtc (Get-TcPpcProp $r 'ts'))), [string](Get-TcPpcProp $r 'lease'), [string](Get-TcPpcProp $r 'lease_wait_ms'), [string](Get-TcPpcProp $r 'lease_holder'), [string](Get-TcPpcProp $r 'checkout'))
  }
}

function Write-TcPpcCostHours {
  param($Rows, $Ctx)
  Write-TcPpcLine ''
  $h = Measure-TcPpcHours -Rows $Rows
  $per = if ($h.Active) { '{0:N2}' -f ($h.Landings / $h.Active) } else { 'n/a' }
  Write-TcPpcLine ('11. landings per active hour ({0}): {1} landings over {2} active hours (a UTC clock hour with at least one push-main row) = {3} per active hour' -f (Format-TcPpcWindow $Ctx), $h.Landings, $h.Active, $per)
  Write-TcPpcLine ('    busy hours (at least {0} push-main rows): {1} of {2}' -f $script:TcPpcBusyHourRows, @($h.Busy).Count, $h.Active)
  foreach ($e in @($h.Busy)) { Write-TcPpcLine ('      {0}  rows {1}, landings {2}' -f $e.Hour, $e.Rows, $e.Landings) }
}

function Write-TcPpcCostParallel {
  param($Rows, $Ctx)
  Write-TcPpcLine ''
  $withS = @(@($Rows) | Where-Object { [string](Get-TcPpcProp $_ 'session') }).Count
  $runs = Find-TcPpcParallelRuns -Rows $Rows
  $inRuns = 0; foreach ($x in @($runs)) { $inRuns += $x.Rows }
  Write-TcPpcLine ('12. parallel runs: at least {0} distinct checkouts sharing one session, each writing a push-main row inside one {1}-hour window ({2})' -f $script:TcPpcParallelMinCheckouts, ($script:TcPpcParallelWindowSec / 3600), (Format-TcPpcWindow $Ctx))
  Write-TcPpcLine ('    rows carrying a session {0} of {1}; runs {2}; rows inside them {3}' -f $withS, @($Rows).Count, @($runs).Count, $inRuns)
  foreach ($x in @($runs)) { Write-TcPpcLine ('      {0} {1} to {2}: checkouts {3}, rows {4}' -f $x.Session, (Format-TcPpcUtc $x.Start), (Format-TcPpcUtc $x.End), $x.Checkouts, $x.Rows) }
}

function Write-TcPpcB1Lines {
  param($Rows, $Ancestry)
  $m = Measure-TcPpcB1 -Rows $Rows -Ancestry $Ancestry
  Write-TcPpcLine ('    B1(a): phase=preflight conflict refusals {0} (and {1} with no readable start); seconds from start {2}; bar: median at most {3} s over at least {4}; verdict {5}' -f $m.A.N, $m.ANoStart, (Format-TcPpcStats $m.A), $script:TcPpcB1aBarSec, $script:TcPpcB1aMinN, $m.AVerdict)
  Write-TcPpcLine ('    B1(b): catch-up or in-lock conflict rows with a collider on main before the pre-flight fetch (degraded=fetch left out) {0}; conflict rows of any phase {1}; bar: 0 over at least {2}; verdict {3}' -f $m.BBad, $m.BConflictRows, $script:TcPpcB1bMinN, $m.BVerdict)
}

function Write-TcPpcCostBars {
  param($Rows, $Ctx)
  Write-TcPpcLine ''
  Write-TcPpcLine ('13. the bars of the plan''s section 8 ({0})' -f (Format-TcPpcWindow $Ctx))
  if ($Ctx.PlanLogOk) {
    Write-TcPpcLine ('    landings read from {0}: {1} commits name the plan; {2} headers unreadable' -f $Ctx.RefName, $Ctx.PlanRecords, $Ctx.PlanMalformed)
  } else {
    Write-TcPpcLine ('    COULD NOT READ the landing log ({0}), so every bar reads NOT LANDED' -f $Ctx.PlanLogWhy)
  }
  if ($null -ne $Ctx.Bar) {
    Write-TcPpcLine ('    {0}: {1}' -f $Ctx.Bar.Id, $Ctx.Bar.Def.Metric)
    Write-TcPpcLine ('    minimum N {0}; bar {1}' -f $Ctx.Bar.Def.MinN, $Ctx.Bar.Def.Value)
    if ($Ctx.Bar.Id -eq 'B1') { Write-TcPpcB1Lines -Rows $Rows -Ancestry $Ctx.Ancestry }
    elseif ($Ctx.Bar.Id -eq 'B6') { Write-TcPpcLine '    B6''s verdicts are printed in section 3, over these treated rows; its result line goes in section 13' }
    else { Write-TcPpcLine '    this bar is read by a person from the sections above, which are over its treated rows, and its result line goes in section 13' }
    return
  }
  foreach ($b in @($Ctx.Bars)) {
    if (-not $b.Landed) {
      Write-TcPpcLine ('    {0,-4} {1}: NOT LANDED (no commit on the main ref carries the Plan line for {2})' -f $b.Id, (@($b.Def.Items) -join ', '), (@($b.Missing) -join ', '))
      continue
    }
    $c = Measure-TcPpcBarCopies -Rows $Rows -State $b -Index $Ctx.Index
    Write-TcPpcLine ('    {0,-4} {1}: landed {2} at {3}; read-out {4} ({5}); treated {6}, older-copy rows excluded {7}, unknown-copy rows excluded {8}, pre-W0.1 {9}, no base {10}, base before the landing {11}' -f $b.Id, (@($b.Def.Items) -join ', '), (Format-TcPpcShort ([string]$b.Landing.Sha)), (Format-TcPpcUtc $b.Landing.Ts), (Format-TcPpcUtc $b.Readout), $(if ($b.Due) { 'DUE' } else { 'not due' }), $c['treated'], (Format-TcPpcShare $c['older-copy'] @($Rows).Count), $c['unknown-copy'], $c['pre-w01'], $c['no-base'], $c['base-before-landing'])
    if ($b.Id -eq 'B1') {
      $tr = @(@($Rows) | Where-Object { (Resolve-TcPpcRowCopy -Row $_ -Index $Ctx.Index -LandingBlob ([string]$b.LandingBlob) -AfterLanding $b.AfterLanding) -eq 'treated' })
      $ta = @(@($Ctx.Ancestry) | Where-Object { $e = $_; @($tr | Where-Object { [object]::ReferenceEquals($_, $e.Row) }).Count })
      Write-TcPpcB1Lines -Rows $tr -Ancestry $ta
    }
  }
  Write-TcPpcLine '    run -Cost -Bar <id> for one bar with every section over its treated rows only'
}

function Write-TcPpcCostReport {
  <# The whole -Cost report from rows already selected and a context already gathered, so it runs no git and every
     section has a fixture. #>
  param($Rows, $Ctx)
  Write-TcPpcCostHead -Rows $Rows -Ctx $Ctx
  Write-TcPpcCostOutcomes -Rows $Rows -Ctx $Ctx
  Write-TcPpcCostDurations -Rows $Rows -Ctx $Ctx
  Write-TcPpcCostChanges -Rows $Rows -Ctx $Ctx
  Write-TcPpcCostLegs -Rows $Rows -Ctx $Ctx
  Write-TcPpcCostLock -Rows $Rows -Ctx $Ctx
  Write-TcPpcCostConflicts -Rows $Rows -Ctx $Ctx
  Write-TcPpcCostRejects -Rows $Rows -Ctx $Ctx
  Write-TcPpcCostCounters -Rows $Rows -Ctx $Ctx
  Write-TcPpcCostFlush -Rows $Rows -Ctx $Ctx
  Write-TcPpcCostLease -Rows $Rows -Ctx $Ctx
  Write-TcPpcCostHours -Rows $Rows -Ctx $Ctx
  Write-TcPpcCostParallel -Rows $Rows -Ctx $Ctx
  Write-TcPpcCostBars -Rows $Rows -Ctx $Ctx
}

function ConvertTo-TcPpcArg {
  <# One argument for a command line, quoted by the Windows rules only when it needs it. No shell sees it. #>
  param([string]$Value)
  if ($Value.Length -eq 0) { return '""' }
  if ($Value -notmatch '[\s"]') { return $Value }
  $e = [regex]::Replace($Value, '(\\*)"', { param($m) ($m.Groups[1].Value * 2) + '\"' })
  $e = [regex]::Replace($e, '(\\+)$', { param($m) $m.Groups[1].Value * 2 })
  return ('"' + $e + '"')
}

function Invoke-TcPpcGit {
  <# git with stdout and stderr kept apart, through the process API: under EAP=Stop a native child's first stderr line
     is a terminating throw, and a catch around it throws the answer away (ops-and-gates.md). Code -1 = could not run. #>
  param([string]$Dir, [string[]]$GitArgs, [int]$TimeoutMs = 120000)
  try {
    $parts = [Collections.Generic.List[string]]::new()
    $parts.Add('-C'); $parts.Add((ConvertTo-TcPpcArg $Dir))
    foreach ($a in @($GitArgs)) { $parts.Add((ConvertTo-TcPpcArg ([string]$a))) }
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = 'git'
    $psi.Arguments = ($parts -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    $psi.CreateNoWindow = $true
    $p = [Diagnostics.Process]::Start($psi)
    try {
      $o = $p.StandardOutput.ReadToEndAsync()
      $e = $p.StandardError.ReadToEndAsync()
      if (-not $p.WaitForExit($TimeoutMs)) {
        try { $p.Kill() } catch { }
        return [pscustomobject]@{ Code = -1; Out = @(); Text = ''; Err = 'git did not finish inside the wait' }
      }
      $p.WaitForExit()
      $txt = [string]$o.Result
      $lines = @($txt -split "`r?`n" | Where-Object { $_ -ne '' })
      return [pscustomobject]@{ Code = $p.ExitCode; Out = $lines; Text = $txt; Err = [string]$e.Result }
    } finally { $p.Dispose() }
  } catch {
    return [pscustomobject]@{ Code = -1; Out = @(); Text = ''; Err = [string]$_.Exception.Message }
  }
}

function Get-TcPpcPlanLogLines {
  <# The landing log's lines, from a frozen file (-PlanLogFile) or from git over the main ref. #>
  param([string]$Repo, [string]$RefName, [string]$LogPath)
  if ($LogPath) {
    if (-not (Test-Path -LiteralPath $LogPath)) { return [pscustomobject]@{ Ok = $false; Why = ('there is no landing log at ' + $LogPath); Lines = @() } }
    return [pscustomobject]@{ Ok = $true; Why = ''; Lines = @([IO.File]::ReadAllLines($LogPath)) }
  }
  $g = Invoke-TcPpcGit -Dir $Repo -GitArgs @('log', '--reverse', '--format=@@TC-COMMIT %H %cI%n%B', '--fixed-strings', ('--grep=' + [IO.Path]::GetFileName($script:TcPpcPlanRel)), $RefName)
  if ($g.Code -ne 0) { return [pscustomobject]@{ Ok = $false; Why = ('git log over ' + $RefName + ' exited ' + $g.Code + ': ' + $g.Err.Trim()); Lines = @() } }
  return [pscustomobject]@{ Ok = $true; Why = ''; Lines = @($g.Text -split "`r?`n") }
}

function Write-TcPpcBlind {
  param([string]$Mode, [string]$Why)
  Write-TcPpcLine ('probe-push-convergence -{0}: COULD NOT EVALUATE - {1}. That is never a clean read.' -f $Mode, $Why)
  Write-TcPpcLine ('PUSH-CONVERGENCE-{0}-COMPLETE blind=1' -f $Mode.ToUpperInvariant())
  return 3
}

function Invoke-TcPpcDue {
  <# -Due: print every bar's state and exit 0, 2 or 3 (header). #>
  param([string]$Repo, [string]$RefName, [string]$PlanPath, [string]$LogPath, [datetime]$AtUtc)
  $planText = ''; $planFrom = ''
  if ($PlanPath) {
    if (-not (Test-Path -LiteralPath $PlanPath)) { return (Write-TcPpcBlind 'Due' ('there is no plan file at ' + $PlanPath)) }
    $planText = [IO.File]::ReadAllText($PlanPath); $planFrom = $PlanPath
  } else {
    $g = Invoke-TcPpcGit -Dir $Repo -GitArgs @('show', ($RefName + ':' + $script:TcPpcPlanRel))
    if ($g.Code -ne 0) { return (Write-TcPpcBlind 'Due' ('git could not read ' + $script:TcPpcPlanRel + ' at ' + $RefName)) }
    $planText = $g.Text; $planFrom = ($RefName + ':' + $script:TcPpcPlanRel)
  }
  $log = Get-TcPpcPlanLogLines -Repo $Repo -RefName $RefName -LogPath $LogPath
  if (-not $log.Ok) { return (Write-TcPpcBlind 'Due' $log.Why) }
  $parsed = ConvertFrom-TcPpcPlanLog $log.Lines
  if ($parsed.Malformed) { return (Write-TcPpcBlind 'Due' ([string]$parsed.Malformed + ' landing-log header(s) could not be read')) }
  $res = Get-TcPpcResultBars -PlanText $planText
  if (-not $res.Found) { return (Write-TcPpcBlind 'Due' ('the plan read from ' + $planFrom + ' has no "## 13." heading, so no result line can be read')) }
  $states = Resolve-TcPpcBarStates -Bars $script:TcPpcBars -Records $parsed.Records -AtUtc $AtUtc
  $v = Get-TcPpcDueVerdict -States $states -ResultIds $res.Ids
  Write-TcPpcLine ('push convergence bars at {0}; plan read from {1}; {2} landing commit(s) name the plan' -f (Format-TcPpcUtc $AtUtc), $planFrom, @($parsed.Records).Count)
  foreach ($s in @($states)) {
    $items = (@($s.Def.Items) -join ', ')
    if (-not $s.Landed) { Write-TcPpcLine ('  {0,-4} {1}: NOT LANDED (no Plan line on the main ref names {2}), so never due' -f $s.Id, $items, (@($s.Missing) -join ', ')); continue }
    $head = ('  {0,-4} {1}: landed {2} at {3}; read-out {4}' -f $s.Id, $items, (Format-TcPpcShort ([string]$s.Landing.Sha)), (Format-TcPpcUtc $s.Landing.Ts), (Format-TcPpcUtc $s.Readout))
    if (-not $s.Due) { Write-TcPpcLine ($head + '; not due yet'); continue }
    $has = $res.Ids.ContainsKey([string]$s.Id)
    Write-TcPpcLine ($head + '; DUE; result line ' + $(if ($has) { 'present' } else { 'MISSING from section 13' }))
  }
  if ($v.Code -eq 2) { Write-TcPpcLine ('  {0} bar(s) past their read-out with no result line: {1}. Run -Cost -Bar <id>, judge it, and add "B<n>: result ..." to section 13.' -f @($v.Missing).Count, (@($v.Missing) -join ', ')) }
  Write-TcPpcLine ('PUSH-CONVERGENCE-DUE-COMPLETE bars={0} landed={1} due={2} missing={3}' -f @($states).Count, (@($states).Count - $v.NotLanded), $v.Due, @($v.Missing).Count)
  return $v.Code
}

function Read-TcPpcLedgerWindow {
  <# Every ledger row whose ts falls in [StartUtc, EndUtc]. The files are named by LOCAL day while ts is UTC, so the
     local days either side of the window are read too. A malformed line carries no ts and is kept, to be counted. #>
  param([string]$Root, [datetime]$StartUtc, [datetime]$EndUtc)
  $out = [Collections.Generic.List[object]]::new()
  $files = [Collections.Generic.List[string]]::new()
  $d = $StartUtc.ToLocalTime().Date.AddDays(-1)
  $last = $EndUtc.ToLocalTime().Date.AddDays(1)
  while ($d -le $last) {
    $path = Get-TcPushLedgerPath -Root $Root -Now $d
    if (Test-Path -LiteralPath $path) {
      $files.Add($path)
      $these = Read-TcPushRows -Path $path
      foreach ($r in @($these)) {
        if ($null -eq $r) { continue }
        if ($r.PSObject.Properties['malformed']) { $out.Add($r); continue }
        $t = ConvertTo-TcPpcUtc (Get-TcPpcProp $r 'ts')
        if ($null -ne $t -and $t -ge $StartUtc -and $t -le $EndUtc) { $out.Add($r) }
      }
    }
    $d = $d.AddDays(1)
  }
  return [pscustomobject]@{ Rows = $out.ToArray(); Files = $files.ToArray() }
}

function Invoke-TcPpcCost {
  <# -Cost: gather what needs git (the landing log, the push-main blob history, each landed bar's landing blob and the
     main commits after it, the conflict ancestry, the run-gates commit times), then print the pure report. #>
  param([string]$Repo, [string]$RefName, [string]$Root, [int]$WindowDays, [string]$BarWanted, [string]$SandboxRoot, [string]$LogPath, [datetime]$AtUtc)
  $log = Get-TcPpcPlanLogLines -Repo $Repo -RefName $RefName -LogPath $LogPath
  $records = @(); $malformed = 0
  if ($log.Ok) { $parsed = ConvertFrom-TcPpcPlanLog $log.Lines; $records = $parsed.Records; $malformed = $parsed.Malformed }
  $states = Resolve-TcPpcBarStates -Bars $script:TcPpcBars -Records $records -AtUtc $AtUtc
  $bl = Invoke-TcPpcGit -Dir $Repo -GitArgs @('log', '--reverse', '--format=@@TC-COMMIT %H %cI', '--raw', '--no-abbrev', $RefName, '--', 'ops/push-main.ps1')
  $index = $null
  if ($bl.Code -eq 0) { $entries = ConvertFrom-TcPpcBlobLog $bl.Out; $index = New-TcPpcBlobIndex $entries }
  foreach ($s in @($states)) {
    if (-not $s.Landed) { continue }
    $rp = Invoke-TcPpcGit -Dir $Repo -GitArgs @('rev-parse', ([string]$s.Landing.Sha + ':ops/push-main.ps1'))
    if ($rp.Code -eq 0 -and @($rp.Out).Count) { $s.LandingBlob = ([string]@($rp.Out)[0]).Trim() }
    $rl = Invoke-TcPpcGit -Dir $Repo -GitArgs @('rev-list', ([string]$s.Landing.Sha + '..' + $RefName))
    if ($rl.Code -eq 0) {
      $hs = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
      $null = $hs.Add([string]$s.Landing.Sha)
      foreach ($x in @($rl.Out)) { $null = $hs.Add(([string]$x).Trim()) }
      $s.AfterLanding = $hs
    }
  }
  $barState = $null
  if ($BarWanted) {
    $hit = @(@($states) | Where-Object { $_.Id -eq $BarWanted })
    if (-not $hit.Count) { return (Write-TcPpcBlind 'Cost' ('no bar is named ' + $BarWanted + '; the bars are ' + (@($states | ForEach-Object { $_.Id }) -join ', '))) }
    $barState = $hit[0]
    if (-not $barState.Landed) { return (Write-TcPpcBlind 'Cost' ('bar ' + $barState.Id + ' has not landed: no commit on ' + $RefName + ' carries the Plan line for ' + (@($barState.Missing) -join ', ') + ', so no row is treated yet')) }
    $startUtc = $barState.Landing.Ts
    $endUtc = $AtUtc
    if ($barState.Readout -lt $endUtc) { $endUtc = $barState.Readout }
  } else {
    $startUtc = $AtUtc.AddDays(-$WindowDays)
    $endUtc = $AtUtc
  }
  $raw = Read-TcPpcLedgerWindow -Root $Root -StartUtc $startUtc -EndUtc $endUtc
  $sel = Select-TcPpcRows -Rows $raw.Rows -SandboxRoot $SandboxRoot
  $rows = @($sel.Kept)
  if ($null -ne $barState) {
    $rows = @($rows | Where-Object { (Resolve-TcPpcRowCopy -Row $_ -Index $index -LandingBlob ([string]$barState.LandingBlob) -AfterLanding $barState.AfterLanding) -eq 'treated' })
  }
  $script:TcPpcGitDir = $Repo
  $gitSb = { param($GitArgs) Invoke-TcPpcGit -Dir $script:TcPpcGitDir -GitArgs $GitArgs }
  $anc = [Collections.Generic.List[object]]::new()
  foreach ($r in $rows) {
    if ([string](Get-TcPpcProp $r 'outcome') -ne 'refused-rebase-conflict') { continue }
    if (-not (Get-TcPpcList $r 'conflict_files').Count) { continue }
    $files = Resolve-TcPpcConflictAncestry -Row $r -Git $gitSb
    $anc.Add([pscustomobject]@{ Row = $r; Files = $files })
  }
  $rg = Invoke-TcPpcGit -Dir $Repo -GitArgs @('log', '--format=@@TC-COMMIT %H %cI', $RefName, '--', 'ops/run-gates.ps1')
  $rgTimes = [Collections.Generic.List[object]]::new()
  if ($rg.Code -eq 0) {
    foreach ($ln in @($rg.Out)) { if ($ln -match '^@@TC-COMMIT \S+ (\S+)') { $t = ConvertTo-TcPpcUtc $Matches[1]; if ($null -ne $t) { $rgTimes.Add($t) } } }
  }
  # W0.3b step 5: landings per clock hour for the B6 and B10 strata, from the shared reflog, which sees every landing
  # from this box and not only push-main's. When it cannot be read, section 3 falls back to push-main rows and says so.
  $hourL = $null; $hourFrom = ''
  $rfl = Invoke-TcPpcGit -Dir $Repo -GitArgs @('reflog', 'show', '--format=%H%x09%gd%x09%gs', '--date=iso-strict', $RefName)
  if ($rfl.Code -eq 0) {
    $rfe = ConvertFrom-TcPpcReflog $rfl.Out
    $rfLand = Get-TcPpcReflogLandings -Entries $rfe -StartUtc $startUtc.AddDays(-1) -EndUtc $endUtc
    $hourL = Get-TcPpcHourLandings -Landings $rfLand
    $hourFrom = ('the ' + $RefName + ' reflog, ' + @($rfLand).Count + ' landings from a day before the window to its end')
  }
  $ctx = [pscustomobject]@{
    StartUtc = $startUtc; EndUtc = $endUtc; RefName = $RefName; Sel = $sel; Files = $raw.Files
    Index = $index; BlobOk = ($bl.Code -eq 0); Bars = $states; Bar = $barState; Ancestry = $anc.ToArray()
    RunGatesTimes = $rgTimes.ToArray(); RunGatesOk = ($rg.Code -eq 0)
    PlanLogOk = $log.Ok; PlanLogWhy = $log.Why; PlanRecords = @($records).Count; PlanMalformed = $malformed
    HourLandings = $hourL; HourSource = $hourFrom
  }
  Write-TcPpcCostReport -Rows $rows -Ctx $ctx
  Write-TcPpcLine ''
  if (-not $rows.Count) {
    Write-TcPpcLine ('probe-push-convergence -Cost: COULD NOT EVALUATE - no push-main row survived the selection in {0}. That is not a quiet box; it is a report over nothing.' -f (Format-TcPpcWindow $ctx))
    Write-TcPpcLine ('PUSH-CONVERGENCE-COST-COMPLETE rows=0 excluded={0} blind=1' -f ($sel.ExcludedSandbox + $sel.ExcludedTemp))
    return 3
  }
  Write-TcPpcLine ('PUSH-CONVERGENCE-COST-COMPLETE rows={0} excluded={1} window={2}..{3}{4}' -f $rows.Count, ($sel.ExcludedSandbox + $sel.ExcludedTemp), (Format-TcPpcUtc $startUtc), (Format-TcPpcUtc $endUtc), $(if ($barState) { ' bar=' + $barState.Id } else { '' }))
  return 0
}

function ConvertFrom-TcPpcReflog {
  <# `git reflog show --format=%H%x09%gd%x09%gs --date=iso-strict <ref>` lines, newest first, as entries OLDEST first:
     Sha, Ts (UTC) and Kind (push for "update by push", fetch for a fetch or pull, other). #>
  param($Lines)
  $out = [Collections.Generic.List[object]]::new()
  foreach ($ln in @($Lines)) {
    $p = ([string]$ln) -split "`t"
    if ($p.Count -lt 3) { continue }
    $m = [regex]::Match($p[1], '@\{(.+)\}$')
    if (-not $m.Success) { continue }
    $ts = ConvertTo-TcPpcUtc $m.Groups[1].Value
    if ($null -eq $ts) { continue }
    $kind = if ($p[2] -match '^update by push') { 'push' } elseif ($p[2] -match '^(fetch|pull)') { 'fetch' } else { 'other' }
    $out.Add([pscustomobject]@{ Sha = $p[0].Trim(); Ts = $ts; Kind = $kind })
  }
  $arr = $out.ToArray()
  [Array]::Reverse($arr)
  return , $arr
}

function Get-TcPpcReflogLandings {
  <# The LANDINGS in a window: every push or fetch entry that moved the ref, with the sha it moved from. #>
  param($Entries, [datetime]$StartUtc, [datetime]$EndUtc)
  $out = [Collections.Generic.List[object]]::new()
  $prev = $null
  foreach ($e in @($Entries)) {
    if ($null -ne $prev -and $e.Ts -ge $StartUtc -and $e.Ts -le $EndUtc -and @('push', 'fetch') -contains $e.Kind -and -not [string]::Equals($e.Sha, $prev.Sha, [StringComparison]::OrdinalIgnoreCase)) {
      $out.Add([pscustomobject]@{ Sha = $e.Sha; Prev = $prev.Sha; Ts = $e.Ts; Kind = $e.Kind; Files = $null })
    }
    $prev = $e
  }
  return , ($out.ToArray())
}

function Measure-TcPpcTouchShare {
  <# How many landings (with a readable file list) changed one path. #>
  param($Landings, [string]$Path)
  $n = 0; $hit = 0
  foreach ($l in @($Landings)) {
    if ($null -eq $l -or $null -eq $l.Files) { continue }
    $n++
    foreach ($f in @($l.Files)) { if ([string]::Equals([string]$f, $Path, [StringComparison]::Ordinal)) { $hit++; break } }
  }
  return [pscustomobject]@{ Touching = $hit; Landings = $n }
}

function Measure-TcPpcSetShare {
  <# How many landings changed at least one path in a set. #>
  param($Landings, $Set)
  $n = 0; $hit = 0
  foreach ($l in @($Landings)) {
    if ($null -eq $l -or $null -eq $l.Files) { continue }
    $n++
    foreach ($f in @($l.Files)) { if ($Set.Contains([string]$f)) { $hit++; break } }
  }
  return [pscustomobject]@{ Touching = $hit; Landings = $n }
}

function Measure-TcPpcOverlapShare {
  <# For each landing, the share of the OTHER landings that changed at least one of its files; the median (nearest
     rank) over landings. $Remove takes one path out of every landing first. #>
  param($Landings, [string]$Remove = '')
  $ls = @(@($Landings) | Where-Object { $null -ne $_ -and $null -ne $_.Files })
  $n = $ls.Count
  if ($n -lt 2) { return [pscustomobject]@{ Median = -1; N = $n } }
  $inv = New-Object Collections.Hashtable ([StringComparer]::Ordinal)
  for ($i = 0; $i -lt $n; $i++) {
    foreach ($f in @($ls[$i].Files)) {
      $k = [string]$f
      if ($Remove -and [string]::Equals($k, $Remove, [StringComparison]::Ordinal)) { continue }
      if (-not $inv.ContainsKey($k)) { $inv[$k] = [Collections.Generic.List[int]]::new() }
      $inv[$k].Add($i)
    }
  }
  $shares = [Collections.Generic.List[double]]::new()
  for ($i = 0; $i -lt $n; $i++) {
    $hs = [Collections.Generic.HashSet[int]]::new()
    foreach ($f in @($ls[$i].Files)) {
      $k = [string]$f
      if (-not $inv.ContainsKey($k)) { continue }
      foreach ($j in $inv[$k]) { if ($j -ne $i) { $null = $hs.Add($j) } }
    }
    $shares.Add($hs.Count / ($n - 1))
  }
  $s = $shares.ToArray(); [Array]::Sort($s)
  return [pscustomobject]@{ Median = (Get-TcPushPercentile $s 0.5); N = $n }
}

function Measure-TcPpcClassCensus {
  <# Per class of the literal table: touches (landing, file) and how many were EXPOSED, landing within $WithinSec
     AFTER a DIFFERENT landing changed the same file (inclusive). The reflog names no pusher, so a different landing
     stands for a different pusher. #>
  param($Landings, [int]$WithinSec = $script:TcPpcExposedSec)
  $ls = @(@($Landings) | Where-Object { $null -ne $_ -and $null -ne $_.Files })
  $byFile = New-Object Collections.Hashtable ([StringComparer]::Ordinal)
  for ($i = 0; $i -lt $ls.Count; $i++) {
    foreach ($f in @($ls[$i].Files)) {
      $k = [string]$f
      if (-not $byFile.ContainsKey($k)) { $byFile[$k] = [Collections.Generic.List[int]]::new() }
      $byFile[$k].Add($i)
    }
  }
  $res = [ordered]@{}
  foreach ($c in $script:TcPpcClassNames) { $res[$c] = [pscustomobject]@{ Class = $c; Touches = 0; Exposed = 0 } }
  for ($i = 0; $i -lt $ls.Count; $i++) {
    foreach ($f in @($ls[$i].Files)) {
      $k = [string]$f
      $e = $res[(Get-TcPpcFileClass $k)]
      $e.Touches = $e.Touches + 1
      foreach ($j in $byFile[$k]) {
        if ($j -eq $i) { continue }
        $d = ($ls[$i].Ts - $ls[$j].Ts).TotalSeconds
        if ($d -ge 0 -and $d -le $WithinSec) { $e.Exposed = $e.Exposed + 1; break }
      }
    }
  }
  return , (@($res.Values))
}

function Measure-TcPpcMainRejects {
  <# W0.3b step 6, the first count, committed from the method of %TEMP%\pushgood-skeptic\mainland.py: a plain push
     from the MAIN checkout that passed every hook check writes a hook-lock row with state held, because the hook takes
     the push lock only after its checks (ops\hooks\pre-push, "TAKEN AFTER THE CHECKS"). Such a row is FOLLOWED when a
     reflog update of the main ref lands 0 to $WithinSec seconds after it, inclusive; one that is not followed was
     rejected after every check had passed, or is an update the reflog did not record, and the two cannot be told
     apart here. $Updates are reflog entries (objects with Ts). #>
  param($HookRows, [string]$MainCheckout, $Updates, [int]$WithinSec = $script:TcPpcFollowedSec)
  $mk = ([string]$MainCheckout).TrimEnd('\').ToLowerInvariant()
  $held = [Collections.Generic.List[object]]::new()
  $not = [Collections.Generic.List[object]]::new()
  $followed = 0
  foreach ($r in @($HookRows)) {
    if ($null -eq $r -or -not $mk) { continue }
    if ([string](Get-TcPpcProp $r 'state') -ne 'held') { continue }
    if ((Get-TcPpcCheckoutKey $r) -ne $mk) { continue }
    $t = ConvertTo-TcPpcUtc (Get-TcPpcProp $r 'ts')
    if ($null -eq $t) { continue }
    $held.Add($r)
    $hit = $false
    foreach ($u in @($Updates)) { if ($null -eq $u) { continue }; $d = ($u.Ts - $t).TotalSeconds; if ($d -ge 0 -and $d -le $WithinSec) { $hit = $true; break } }
    if ($hit) { $followed++ } else { $not.Add($r) }
  }
  return [pscustomobject]@{ Held = $held.Count; Followed = $followed; NotFollowed = $not.ToArray() }
}

function Resolve-TcPpcLandingRoutes {
  <# W0.3b step 6, the second count, committed from the method of %TEMP%\pushgood-residual\landings.py: which road each
     landing came by. Oldest first, each landing takes one unused row: a landed push-main row written from
     $script:TcPpcRoutePmBeforeSec before to $script:TcPpcRoutePmAfterSec after it whose base or grant is the sha main
     moved FROM, nearest first; else one written within $script:TcPpcRoutePmNearSec after it; else a hook-lock row written
     from $script:TcPpcRouteHookBeforeSec before to $script:TcPpcRouteHookAfterSec after it naming that sha, whose
     checkout makes it plain-main or plain-worktree (plain-unknown when the main checkout could not be named); else
     no-ledger-row. A push-main's own hook also writes hook-lock rows, which is why a push-main row is tried first. #>
  param($Landings, $PushMainRows, $HookRows, [string]$MainCheckout)
  $mk = ([string]$MainCheckout).TrimEnd('\').ToLowerInvariant()
  $pm = @(@($PushMainRows) | Where-Object { $null -ne $_ -and (Test-TcPpcLanded $_) -and $null -ne (ConvertTo-TcPpcUtc (Get-TcPpcProp $_ 'ts')) })
  $hk = @(@($HookRows) | Where-Object { $null -ne $_ -and $null -ne (ConvertTo-TcPpcUtc (Get-TcPpcProp $_ 'ts')) })
  $usedPm = @{}; $usedHk = @{}
  $out = [Collections.Generic.List[object]]::new()
  foreach ($l in @(@($Landings) | Sort-Object Ts)) {
    if ($null -eq $l) { continue }
    $prev = [string]$l.Prev
    $best = -1; $bestD = 0.0
    for ($i = 0; $i -lt $pm.Count; $i++) {
      if ($usedPm.ContainsKey($i)) { continue }
      $d = ((ConvertTo-TcPpcUtc (Get-TcPpcProp $pm[$i] 'ts')) - $l.Ts).TotalSeconds
      if ($d -lt -$script:TcPpcRoutePmBeforeSec -or $d -gt $script:TcPpcRoutePmAfterSec) { continue }
      $names = ($prev -and ([string]::Equals([string](Get-TcPpcProp $pm[$i] 'grant'), $prev, [StringComparison]::OrdinalIgnoreCase) -or [string]::Equals([string](Get-TcPpcProp $pm[$i] 'base'), $prev, [StringComparison]::OrdinalIgnoreCase)))
      if ($names -and ($best -lt 0 -or [math]::Abs($d) -lt [math]::Abs($bestD))) { $best = $i; $bestD = $d }
    }
    if ($best -lt 0) {
      for ($i = 0; $i -lt $pm.Count; $i++) {
        if ($usedPm.ContainsKey($i)) { continue }
        $d = ((ConvertTo-TcPpcUtc (Get-TcPpcProp $pm[$i] 'ts')) - $l.Ts).TotalSeconds
        if ($d -lt -$script:TcPpcRoutePmBeforeSec -or $d -gt $script:TcPpcRoutePmNearSec) { continue }
        if ($best -lt 0 -or [math]::Abs($d) -lt [math]::Abs($bestD)) { $best = $i; $bestD = $d }
      }
    }
    if ($best -ge 0) {
      $usedPm[$best] = $true
      $out.Add([pscustomobject]@{ Landing = $l; Route = 'push-main'; Checkout = [string](Get-TcPpcProp $pm[$best] 'checkout') })
      continue
    }
    $hb = -1; $hbD = 0.0
    for ($i = 0; $i -lt $hk.Count; $i++) {
      if ($usedHk.ContainsKey($i)) { continue }
      $d = ($l.Ts - (ConvertTo-TcPpcUtc (Get-TcPpcProp $hk[$i] 'ts'))).TotalSeconds
      if ($d -lt -$script:TcPpcRouteHookAfterSec -or $d -gt $script:TcPpcRouteHookBeforeSec) { continue }
      $names = ($prev -and ([string]::Equals([string](Get-TcPpcProp $hk[$i] 'grant'), $prev, [StringComparison]::OrdinalIgnoreCase) -or [string]::Equals([string](Get-TcPpcProp $hk[$i] 'base'), $prev, [StringComparison]::OrdinalIgnoreCase)))
      if ($names -and ($hb -lt 0 -or [math]::Abs($d) -lt [math]::Abs($hbD))) { $hb = $i; $hbD = $d }
    }
    if ($hb -ge 0) {
      $usedHk[$hb] = $true
      $route = if (-not $mk) { 'plain-unknown' } elseif ((Get-TcPpcCheckoutKey $hk[$hb]) -eq $mk) { 'plain-main' } else { 'plain-worktree' }
      $out.Add([pscustomobject]@{ Landing = $l; Route = $route; Checkout = [string](Get-TcPpcProp $hk[$hb] 'checkout') })
      continue
    }
    $out.Add([pscustomobject]@{ Landing = $l; Route = 'no-ledger-row'; Checkout = '' })
  }
  return , ($out.ToArray())
}

function Format-TcPpcRoutes {
  <# 'push-main a, plain-worktree b, ...' over a route list, every route named even at 0. #>
  param($Routes)
  $t = [ordered]@{}
  foreach ($k in $script:TcPpcRouteNames) { $t[$k] = 0 }
  foreach ($r in @($Routes)) { if ($null -ne $r) { $t[[string]$r.Route] = [int]$t[[string]$r.Route] + 1 } }
  return (@($t.Keys | ForEach-Object { '{0} {1}' -f $_, $t[$_] }) -join ', ')
}

function Get-TcPpcMainCheckout {
  <# The main checkout: the parent of the ABSOLUTE git common dir, when that is a `.git` folder; '' otherwise. #>
  param([string]$Repo)
  $g = Invoke-TcPpcGit -Dir $Repo -GitArgs @('rev-parse', '--path-format=absolute', '--git-common-dir')
  if ($g.Code -ne 0 -or -not @($g.Out).Count) { return '' }
  $c = ([string]@($g.Out)[0]).Trim() -replace '/', '\'
  if ($c -notmatch '\\\.git$') { return '' }
  return $c.Substring(0, $c.Length - 5)
}

function Test-TcPpcHasListSet {
  <# Does this rehearse-chain carry W0.5's -ListSet parameter? Read from its PARAM BLOCK, never by running it: without
     the switch, a run would be a real rehearsal. #>
  param([string]$ScriptPath)
  if (-not (Test-Path -LiteralPath $ScriptPath)) { return $false }
  $tokens = $null; $errs = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errs)
  if ($null -eq $ast -or $null -eq $ast.ParamBlock) { return $false }
  foreach ($p in $ast.ParamBlock.Parameters) { if ([string]::Equals($p.Name.VariablePath.UserPath, 'ListSet', [StringComparison]::OrdinalIgnoreCase)) { return $true } }
  return $false
}

function ConvertFrom-TcPpcListSet {
  <# W0.5's listing: one repo path per line, then CHAIN-REHEARSAL-LISTSET-COMPLETE files=<n> as the last line. The
     listing is accepted only when its path count equals its own marker's. #>
  param($Lines)
  $ls = @(@($Lines) | ForEach-Object { ([string]$_).TrimEnd() } | Where-Object { $_ })
  if (-not $ls.Count) { return [pscustomobject]@{ Ok = $false; Why = 'the listing printed nothing'; Files = @() } }
  $m = [regex]::Match($ls[$ls.Count - 1], '^CHAIN-REHEARSAL-LISTSET-COMPLETE\s+files=(\d+)\b')
  if (-not $m.Success) { return [pscustomobject]@{ Ok = $false; Why = 'its last line is not CHAIN-REHEARSAL-LISTSET-COMPLETE files=<n>'; Files = @() } }
  $want = [int]$m.Groups[1].Value
  $paths = [Collections.Generic.List[string]]::new()
  for ($i = 0; $i -lt $ls.Count - 1; $i++) {
    $t = $ls[$i].Trim()
    if ($t -match '^[^\s:]+$' -and $t -match '[\\/.]') { $paths.Add(($t -replace '\\', '/')) }
  }
  if ($paths.Count -ne $want) { return [pscustomobject]@{ Ok = $false; Why = ('it listed {0} paths and its marker says {1}' -f $paths.Count, $want); Files = @() } }
  return [pscustomobject]@{ Ok = $true; Why = ''; Files = $paths.ToArray() }
}

function Get-TcPpcChainSet {
  <# The chain manifest set at one commit, through ops\rehearse-chain.ps1 -ListSet. BLIND, with why, until W0.5. #>
  param([string]$Repo, [string]$Commit)
  $rh = Join-Path $Repo 'ops\rehearse-chain.ps1'
  if (-not (Test-Path -LiteralPath $rh)) { return [pscustomobject]@{ Ok = $false; Why = ('there is no ' + $rh); Files = @() } }
  if (-not (Test-TcPpcHasListSet -ScriptPath $rh)) { return [pscustomobject]@{ Ok = $false; Why = 'ops\rehearse-chain.ps1 in this checkout has no -ListSet parameter (W0.5 adds it), so it was not run'; Files = @() } }
  try {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = (Join-Path $PSHOME 'powershell.exe')
    $psi.Arguments = ('-NoProfile -ExecutionPolicy Bypass -File ' + (ConvertTo-TcPpcArg $rh) + ' -ListSet -Commit ' + (ConvertTo-TcPpcArg $Commit))
    $psi.WorkingDirectory = $Repo
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $p = [Diagnostics.Process]::Start($psi)
    try {
      $o = $p.StandardOutput.ReadToEndAsync()
      $e = $p.StandardError.ReadToEndAsync()
      if (-not $p.WaitForExit(180000)) { try { $p.Kill() } catch { }; return [pscustomobject]@{ Ok = $false; Why = '-ListSet did not finish inside 180 s'; Files = @() } }
      $p.WaitForExit()
      $null = $e.Result
      if ($p.ExitCode -ne 0) { return [pscustomobject]@{ Ok = $false; Why = ('-ListSet exited ' + $p.ExitCode); Files = @() } }
      return (ConvertFrom-TcPpcListSet (([string]$o.Result) -split "`r?`n"))
    } finally { $p.Dispose() }
  } catch {
    return [pscustomobject]@{ Ok = $false; Why = ('-ListSet could not be run: ' + $_.Exception.Message); Files = @() }
  }
}

function Invoke-TcPpcHistory {
  <# -History: the reflog's landings over 14 days, each with the files git says it changed, then the four figures. #>
  param([string]$Repo, [string]$RefName, [datetime]$AtUtc, [string]$Root = '', [string]$SandboxRoot = '')
  $rl = Invoke-TcPpcGit -Dir $Repo -GitArgs @('reflog', 'show', '--format=%H%x09%gd%x09%gs', '--date=iso-strict', $RefName)
  if ($rl.Code -ne 0) { return (Write-TcPpcBlind 'History' ('git could not read the reflog of ' + $RefName)) }
  $entries = ConvertFrom-TcPpcReflog $rl.Out
  $start14 = $AtUtc.AddDays(-14); $start7 = $AtUtc.AddDays(-7)
  $l14 = Get-TcPpcReflogLandings -Entries $entries -StartUtc $start14 -EndUtc $AtUtc
  if (@($l14).Count -lt 2) { return (Write-TcPpcBlind 'History' ('the reflog of ' + $RefName + ' holds ' + @($l14).Count + ' landing(s) in 14 days')) }
  $noFiles = 0
  foreach ($l in $l14) {
    $d = Invoke-TcPpcGit -Dir $Repo -GitArgs @('diff', '--name-only', $l.Prev, $l.Sha)
    if ($d.Code -eq 0) { $l.Files = @($d.Out | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ }) } else { $noFiles++ }
  }
  $l7 = @(@($l14) | Where-Object { $_.Ts -ge $start7 })
  $pushN = @(@($l14) | Where-Object { $_.Kind -eq 'push' }).Count
  Write-TcPpcLine ('push history re-derived from the {0} reflog and git, at {1} (written by ops\probe-push-convergence.ps1 -History; cite its blob)' -f $RefName, (Format-TcPpcUtc $AtUtc))
  Write-TcPpcLine ('  landings in 14 days ({0} to {1}): {2} (update by push {3}, fetch moves {4}); in 7 days: {5}' -f (Format-TcPpcUtc $start14), (Format-TcPpcUtc $AtUtc), @($l14).Count, $pushN, (@($l14).Count - $pushN), $l7.Count)
  Write-TcPpcLine ('  landings whose file list git could not produce: {0} (left out of every figure below)' -f $noFiles)
  Write-TcPpcLine ''
  $mainSha = ''
  $ms = Invoke-TcPpcGit -Dir $Repo -GitArgs @('rev-parse', $RefName)
  if ($ms.Code -eq 0 -and @($ms.Out).Count) { $mainSha = ([string]@($ms.Out)[0]).Trim() }
  $chain = Get-TcPpcChainSet -Repo $Repo -Commit $mainSha
  $chainTok = 'blind'
  Write-TcPpcLine '1. the chain share of landings, 7 days'
  if (-not $chain.Ok) {
    Write-TcPpcLine ('   BLIND: {0}. The scratch figure the plan cites (79 of 299) stays SCRATCH until this prints a share.' -f $chain.Why)
  } else {
    $set = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($f in $chain.Files) { $null = $set.Add([string]$f) }
    $cs = Measure-TcPpcSetShare -Landings $l7 -Set $set
    $chainTok = [string]$cs.Touching
    Write-TcPpcLine ('   the chain set at {0}: {1} files (the set at each landing''s own commit is not re-read); landings touching it: {2} of {3} ({4:N1}%)' -f (Format-TcPpcShort $mainSha), $set.Count, $cs.Touching, $cs.Landings, $(if ($cs.Landings) { 100.0 * $cs.Touching / $cs.Landings } else { 0 }))
  }
  Write-TcPpcLine ''
  $bk = 'design/BACKLOG-course-findings.md'
  $ts = Measure-TcPpcTouchShare -Landings $l7 -Path $bk
  Write-TcPpcLine ('2. the backlog touch share, 7 days: landings changing {0}: {1} of {2} ({3:N1}%)' -f $bk, $ts.Touching, $ts.Landings, $(if ($ts.Landings) { 100.0 * $ts.Touching / $ts.Landings } else { 0 }))
  Write-TcPpcLine ''
  $o1 = Measure-TcPpcOverlapShare -Landings $l7
  $o2 = Measure-TcPpcOverlapShare -Landings $l7 -Remove $bk
  Write-TcPpcLine ('3. the median overlap share, 7 days: for each landing, the share of the OTHER landings that change one of its files; median {0:N3} over {1} landings; with {2} removed from every landing: {3:N3}' -f $o1.Median, $o1.N, $bk, $o2.Median)
  Write-TcPpcLine ''
  Write-TcPpcLine ('4. the class census, 14 days: a touch is EXPOSED when a different landing changed the same file in the {0} minutes before it (the reflog names no pusher, so a different landing stands for one)' -f ($script:TcPpcExposedSec / 60))
  $cc = Measure-TcPpcClassCensus -Landings $l14
  foreach ($e in @($cc)) { Write-TcPpcLine ('   {0,-14} exposed {1} of {2} touches' -f $e.Class, $e.Exposed, $e.Touches) }
  Write-TcPpcLine '   These classes are W0.3''s literal table, not the scratch census''s (section 2.3 A3), so the two do not compare row for row.'
  Write-TcPpcLine ''
  # W0.3b step 6: the two counts the amendment measured by scratch, committed. Both read the push ledger over 7 days.
  $led = Read-TcPpcLedgerWindow -Root $Root -StartUtc $start7.AddHours(-1) -EndUtc $AtUtc
  $lsel = Select-TcPpcRows -Rows $led.Rows -SandboxRoot $SandboxRoot
  $mainCo = Get-TcPpcMainCheckout -Repo $Repo
  $heldTok = 'blind'; $rejTok = 'blind'; $routeTok = 'blind'
  Write-TcPpcLine ('5. main-checkout plain pushes that passed every hook check and were then rejected, 7 days (a held hook-lock row from the main checkout with no {0} update 0 to {1} s after it; the method of %TEMP%\pushgood-skeptic\mainland.py, committed)' -f $RefName, $script:TcPpcFollowedSec)
  if (-not @($led.Files).Count) { Write-TcPpcLine ('   BLIND: no push ledger file in the window under {0}' -f $(if ($Root) { $Root } else { '%LOCALAPPDATA%\ThriftyCrew\push-ledger' })) }
  elseif (-not $mainCo) { Write-TcPpcLine '   BLIND: git could not name the main checkout (its common dir is not a .git folder)' }
  else {
    $held7 = @(@($lsel.HookLock) | Where-Object { $t = ConvertTo-TcPpcUtc (Get-TcPpcProp $_ 'ts'); $null -ne $t -and $t -ge $start7 -and $t -le $AtUtc })
    $mr = Measure-TcPpcMainRejects -HookRows $held7 -MainCheckout $mainCo -Updates $entries
    $heldTok = [string]$mr.Held; $rejTok = [string]@($mr.NotFollowed).Count
    Write-TcPpcLine ('   main checkout {0}; held hook-lock rows from it {1} (ledger files read {2}); followed by an update {3}; NOT followed {4} (rejected after every check passed, or an update the reflog did not record)' -f $mainCo, $mr.Held, @($led.Files).Count, (Format-TcPpcShare $mr.Followed $mr.Held), (Format-TcPpcShare @($mr.NotFollowed).Count $mr.Held))
    foreach ($r in @($mr.NotFollowed)) { Write-TcPpcLine ('     {0} waitMs={1} base={2} grant={3}' -f (Format-TcPpcUtc (ConvertTo-TcPpcUtc (Get-TcPpcProp $r 'ts'))), [string](Get-TcPpcProp $r 'waitMs'), (Format-TcPpcShort ([string](Get-TcPpcProp $r 'base'))), (Format-TcPpcShort ([string](Get-TcPpcProp $r 'grant')))) }
  }
  Write-TcPpcLine ''
  Write-TcPpcLine '6. landings by route, 7 days: each landing matched to a landed push-main row, else a hook-lock row, else none (the method of %TEMP%\pushgood-residual\landings.py, committed)'
  if (-not @($led.Files).Count) { Write-TcPpcLine '   BLIND: no push ledger file in the window, so no landing can be matched to a row' }
  else {
    $routes = Resolve-TcPpcLandingRoutes -Landings $l7 -PushMainRows $lsel.Kept -HookRows $lsel.HookLock -MainCheckout $mainCo
    Write-TcPpcLine ('   every landing, {0}: {1}' -f @($routes).Count, (Format-TcPpcRoutes $routes))
    if (-not $chain.Ok) { Write-TcPpcLine ('   chain landings BLIND: {0}' -f $chain.Why) }
    else {
      $cset = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
      foreach ($f in $chain.Files) { $null = $cset.Add([string]$f) }
      $cr = @(@($routes) | Where-Object { $x = $_; $null -ne $x.Landing.Files -and @(@($x.Landing.Files) | Where-Object { $cset.Contains([string]$_) }).Count })
      $notPm = @($cr | Where-Object { $_.Route -ne 'push-main' }).Count
      $routeTok = [string]$cr.Count
      Write-TcPpcLine ('   chain landings (touching the set at {0}, the counterfactual over today''s set), {1}: {2}; not through push-main {3} (B6 is read beside this; B14 bars it at 10%)' -f (Format-TcPpcShort $mainSha), $cr.Count, (Format-TcPpcRoutes $cr), (Format-TcPpcShare $notPm $cr.Count))
    }
  }
  Write-TcPpcLine ''
  Write-TcPpcLine '7. not re-derivable: the conflict attribution before W0.1 needed transcripts, so it stays SCRATCH wherever the plan uses it.'
  Write-TcPpcLine ('PUSH-CONVERGENCE-HISTORY-COMPLETE landings14={0} landings7={1} chain={2} nofiles={3} mainheld={4} mainrejected={5} chainrouted={6}' -f @($l14).Count, $l7.Count, $chainTok, $noFiles, $heldTok, $rejTok, $routeTok)
  return 0
}

if ($SelfTest) {
  $f = 0; $cases = 0
  # THE LITERAL CASE COUNT. A literal-case suite knows its own number, so a case that never ran is a defect, never a
  # smaller tree (ops-and-gates.md). Move this with every case added or removed.
  $expectedCases = 91
  $kMF = 'MUST' + ' FIRE'; $kMNF = 'MUST' + ' NOT FIRE'; $kCT = 'CLEAN' + ' TWIN'
  function T($m, $cond, $got) {
    $script:cases++
    if ($cond) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $got); $script:f++ }
  }
  function Invoke-TcPpcCaptured {
    <# Run a body with [Console]::Out captured, so a report's lines can be asserted. The writer is restored in finally. #>
    param([scriptblock]$Body)
    $sw = New-Object IO.StringWriter
    $old = [Console]::Out
    [Console]::SetOut($sw)
    $ret = $null; $err = ''
    try { $ret = & $Body } catch { $err = [string]$_.Exception.Message } finally { [Console]::SetOut($old) }
    return [pscustomobject]@{ Text = $sw.ToString(); Ret = $ret; Error = $err }
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
    $capAll = Invoke-TcPpcCaptured { Write-TcConvergenceReport -Ledger $ledMeasure -Landings $iv -Logs $lg -Days 1 }
    T ($kCT + '  a report with all three sources present resolves all three') ($capAll.Ret -eq 3) ("resolved={0} error={1}" -f $capAll.Ret, $capAll.Error)
    # NOTHING TO LOOK AT IS NOT A HEALTHY BOX. Without this, a run on a machine with no ledger, no landings and no
    # logs would print three reassuring paragraphs and exit 0.
    $emptyLed = Measure-TcPushRows @()
    $capNone = Invoke-TcPpcCaptured { Write-TcConvergenceReport -Ledger $emptyLed -Landings $none -Logs $lgMissing -Days 1 }
    T ($kMF + '  a report whose every source is empty resolves NOTHING, which its caller turns into an exit 3') `
      ($capNone.Ret -eq 0) ("resolved={0}" -f $capNone.Ret)

    # ---- W0.3: the convergence sections are UNCHANGED, pinned to the original's own output ----
    # The expected text below was printed by the version of this file BEFORE W0.3 (blob 651dbcf3a), over exactly these
    # frozen rows, landings and logs. W0.3 added modes around the report and must not have moved a byte of it.
    $tw1 = '{"ts":"2026-09-12T10:00:00Z","pid":1,"run":"1@2026-09-12T09:40:00.0000000Z","event":"hook-lock","waitMs":1130000,"state":"held","base":"' + $A + '","grant":"' + $B + '","outcome":"","checkout":"C:\\wt\\a"}'
    $tw2 = '{"ts":"2026-09-12T10:05:00Z","pid":2,"run":"2@2026-09-12T10:04:00.0000000Z","event":"hook-lock","waitMs":4000,"state":"held","base":"' + $A + '","grant":"' + $A + '","outcome":"","checkout":"C:\\wt\\b"}'
    $twRows = @(($tw1 | ConvertFrom-Json), ($tw2 | ConvertFrom-Json))
    $kNone = '(no blind token: a red gate, or still running)'
    $twLogs = [pscustomobject]@{ Blind = $false; Why = ''; Total = 3; Classes = @{ 'push-cannot-land' = 2; $kNone = 1 }; Latest = @{ 'push-cannot-land' = [datetime]'2026-09-12 10:30:00'; $kNone = [datetime]'2026-09-12 09:00:00' } }
    $twLed = Measure-TcPushRows $twRows
    $capTw = Invoke-TcPpcCaptured { Write-TcConvergenceReport -Ledger $twLed -Landings $iv -Logs $twLogs -Days 1 }
    $twWant = @(
      'push convergence over the last 1 day(s), on this box'
      ''
      '1. THE PUSH LEDGER - the only source that can say whether the remote moved WHILE a push waited.'
      '   rows=2 (malformed=0), of which 2 actually queued for the lock'
      '   wait for the push lock: median 4.0s, p90 1,130.0s, max 1,130.0s over 2 queued push(es)'
      '   the remote MOVED while the push waited in 1 of 2 queued push(es) that could be compared (50%)'
      ''
      '2. LANDINGS on origin/main, from the .git every worktree on this box shares.'
      '   3 landing(s) over 0.32h = 9.26 per hour'
      '   a freshly fetched base stays fresh for: median 124s, p90 1,042s, shortest 124s, over 2 gap(s)'
      '   READ THIS AGAINST THE WAIT ABOVE. A push whose critical window is longer than the median gap is'
      '   more likely than not to come out of it stale, and retrying restarts the same clock.'
      ''
      '3. RETAINED pre-push gate logs - REFUSALS ONLY. The hook deletes its log when the gate passed, so a push'
      '   that landed is absent by construction and these counts are over refusals, never over pushes.'
      '   3 retained log(s) in this window'
      '        1  (no blind token: a red gate, or still running)   last seen 2026-09-12 09:00'
      '        2  push-cannot-land   last seen 2026-09-12 10:30'
      ''
    )
    $twGot = @(($capTw.Text -replace "`r", '') -split "`n")
    if ($twGot.Count -and $twGot[$twGot.Count - 1] -eq '') { $twGot = @($twGot | Select-Object -SkipLast 1) }
    $twSame = ($twGot.Count -eq $twWant.Count)
    $twFirstDiff = -1
    for ($i = 0; $twSame -and $i -lt $twWant.Count; $i++) { if (-not [string]::Equals($twGot[$i], $twWant[$i], [StringComparison]::Ordinal)) { $twSame = $false; $twFirstDiff = $i } }
    T ($kCT + '  the existing convergence sections print UNCHANGED for the frozen rows, line for line against the pre-W0.3 output') `
      ($twSame -and $capTw.Ret -eq 3 -and -not $capTw.Error) ("lines={0} want={1} firstDiff={2} got='{3}'" -f $twGot.Count, $twWant.Count, $twFirstDiff, $(if ($twFirstDiff -ge 0) { $twGot[$twFirstDiff] } else { '' }))

    # ---- W0.3 step 3: the class table ----
    T ($kMF + '  design/BACKLOG-course-findings.md is classed backlog-index') `
      ((Get-TcPpcFileClass 'design/BACKLOG-course-findings.md') -eq 'backlog-index') ("class={0}" -f (Get-TcPpcFileClass 'design/BACKLOG-course-findings.md'))
    # FIRST MATCH WINS, in the table's order: a hub is not code, a ruling json is not a baseline, a baseline json is
    # not other, and a path with backslashes is read with forward ones.
    $clsGot = @((Get-TcPpcFileClass 'ops/run-gates.ps1'), (Get-TcPpcFileClass 'grocery/known-wrong.json'), (Get-TcPpcFileClass 'ops/mustfire-census-baseline.json'), (Get-TcPpcFileClass 'design\MEASURE-push-lock-2026-09-11.md'), (Get-TcPpcFileClass '.claude/rules/grocery.md')) -join ','
    T ($kCT + '  first match wins in table order: run-gates is hub, known-wrong is ruling, a -baseline.json is baseline, a MEASURE doc is reread, a rules file is rules') `
      ($clsGot -eq 'hub,ruling,baseline,reread,rules') ("classes={0}" -f $clsGot)
    $clsOther = @((Get-TcPpcFileClass 'ops/probe-push-convergence.ps1'), (Get-TcPpcFileClass 'public/board.json'), (Get-TcPpcFileClass 'design/backlog-notes.md')) -join ','
    T ($kMNF + '  a .ps1 outside the hubs is code not hub, a plain json is other, and a lower-case design/backlog- file is not backlog-index (the table is case-sensitive)') `
      ($clsOther -eq 'code,other,other') ("classes={0}" -f $clsOther)

    # ---- W0.3 step 2: row selection ----
    $sbRoot = 'C:\ppc-fixture\Temp'
    $sel1 = '{"ts":"2026-09-23T12:42:54Z","pid":41860,"run":"41860@2026-09-23T12:42:54.3469037Z","event":"hook-lock","waitMs":15,"state":"held","base":"","grant":"","outcome":"","checkout":"C:\\ppc-fixture\\Temp\\tc-prepush-selftest-38948-7a378753\\main"}'
    $sel2 = '{"ts":"2026-09-24T12:00:00Z","pid":5,"run":"5@2026-09-24T11:59:00.0000000Z","event":"push-main","waitMs":15,"state":"held","base":"","grant":"","outcome":"landed","checkout":"C:\\ppc-fixture\\Temp\\tc-prepush-selftest-651dbcf3-5-0a1b2c3d\\main"}'
    $sel3 = '{"ts":"2026-09-24T12:00:00Z","pid":6,"run":"6@2026-09-24T11:59:00.0000000Z","event":"push-main","waitMs":15,"state":"held","base":"","grant":"","outcome":"landed","checkout":"C:\\ppc-fixture\\Temp\\tc-opsl-1234"}'
    $sel4 = '{"ts":"2026-09-24T12:00:00Z","pid":7,"run":"7@2026-09-24T11:59:00.0000000Z","event":"push-main","waitMs":15,"state":"held","base":"","grant":"","outcome":"landed","checkout":"C:\\Codex\\ThriftyCrew\\.claude\\worktrees\\wt-a"}'
    $sel5 = '{"ts":"2026-09-24T12:00:00Z","pid":8,"run":"8@2026-09-24T11:59:00.0000000Z","event":"hook-lock","waitMs":15,"state":"held","base":"","grant":"","outcome":"","checkout":"C:\\Codex\\ThriftyCrew\\.claude\\worktrees\\wt-a"}'
    $selRows = @(($sel1 | ConvertFrom-Json), ($sel2 | ConvertFrom-Json), ($sel3 | ConvertFrom-Json), ($sel4 | ConvertFrom-Json), ($sel5 | ConvertFrom-Json), [pscustomobject]@{ malformed = $true; text = 'x' })
    $sel = Select-TcPpcRows -Rows $selRows -SandboxRoot $sbRoot
    T ($kMNF + '  a test-prepush sandbox row is EXCLUDED and counted in excluded (both name shapes), another %TEMP% fixture row is excluded on its own line, and only the worktree push-main row is kept') `
      ($sel.ExcludedSandbox -eq 2 -and $sel.ExcludedSandboxBlob -eq 1 -and $sel.ExcludedTemp -eq 1 -and $sel.OtherEvents -eq 1 -and $sel.Malformed -eq 1 -and @($sel.Kept).Count -eq 1 -and [int]$sel.Kept[0].pid -eq 7) `
      ("sandbox={0} withBlob={1} temp={2} other={3} malformed={4} kept={5}" -f $sel.ExcludedSandbox, $sel.ExcludedSandboxBlob, $sel.ExcludedTemp, $sel.OtherEvents, $sel.Malformed, @($sel.Kept).Count)

    # ---- W0.3 step 2: which rows a bar judges (pm_blob, the landing's own blob, and the base) ----
    $bE = 'e' * 40; $bA = 'a' * 40; $bB = 'b' * 40; $bX = 'f' * 40
    $c1 = '1' * 40; $c2 = '2' * 40; $c3 = '3' * 40; $c4 = '4' * 40
    $blog1 = '@@TC-COMMIT ' + $c1 + ' 2026-09-20T10:00:00Z'
    $blog2 = ':100644 100644 ' + $bE + ' ' + $bA + " M`tops/push-main.ps1"
    $blog3 = '@@TC-COMMIT ' + $c2 + ' 2026-09-25T10:00:00Z'
    $blog4 = ':100644 100644 ' + $bA + ' ' + $bB + " M`tops/push-main.ps1"
    $blogEntries = ConvertFrom-TcPpcBlobLog @($blog1, $blog2, $blog3, $blog4)
    $bix = New-TcPpcBlobIndex $blogEntries
    T ($kCT + '  the push-main blob history maps each blob to the FIRST commit carrying it, in history order') `
      ($bix.Count -eq 2 -and $bix.First[$bA].Commit -eq $c1 -and $bix.First[$bB].Commit -eq $c2 -and $bix.Order[$c2] -eq 1) ("count={0}" -f $bix.Count)
    # A push-main item landing AT c2 (it changed push-main to blob B); main after it holds c2 and c3.
    $after2 = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase); $null = $after2.Add($c2); $null = $after2.Add($c3)
    $stPm = [pscustomobject]@{ LandingBlob = $bB; AfterLanding = $after2 }
    $rOld = ('{"ts":"2026-09-26T10:00:00Z","event":"push-main","pm_blob":"' + $bA + '","branch_base":"' + $c3 + '"}') | ConvertFrom-Json
    $rNew = ('{"ts":"2026-09-26T10:00:00Z","event":"push-main","pm_blob":"' + $bB + '","branch_base":"' + $c3 + '"}') | ConvertFrom-Json
    $rOwn = ('{"ts":"2026-09-24T10:00:00Z","event":"push-main","pm_blob":"' + $bB + '","branch_base":"' + $c1 + '"}') | ConvertFrom-Json
    $rUnk = ('{"ts":"2026-09-26T10:00:00Z","event":"push-main","pm_blob":"' + $bX + '","branch_base":"' + $c3 + '"}') | ConvertFrom-Json
    $rPre = '{"ts":"2026-09-26T10:00:00Z","event":"push-main","outcome":"landed"}' | ConvertFrom-Json
    $rPf = ('{"ts":"2026-09-26T10:00:00Z","event":"push-main","pm_blob":"' + $bB + '","branch_base":"' + $c1 + '","preflight_sha":"' + $c3 + '"}') | ConvertFrom-Json
    $cp = Measure-TcPpcBarCopies -Rows @($rOld, $rNew, $rOwn, $rUnk, $rPre) -State $stPm -Index $bix
    T ($kMF + '  a row whose pm_blob maps to a commit BEFORE the item''s landing is excluded from that bar and counted as older-copy') `
      ((Resolve-TcPpcRowCopy -Row $rOld -Index $bix -LandingBlob $bB -AfterLanding $after2) -eq 'older-copy' -and $cp['older-copy'] -eq 1 -and $cp['treated'] -eq 1) `
      ("old={0} counts: treated {1}, older {2}" -f (Resolve-TcPpcRowCopy -Row $rOld -Index $bix -LandingBlob $bB -AfterLanding $after2), $cp['treated'], $cp['older-copy'])
    # AN ITEM'S OWN ATTEMPTS BEFORE IT LANDED ran the new push-main on a branch based before the landing. Its blob maps
    # at the landing, so the pm_blob rule alone would count them as treated.
    T ($kMF + '  a row running the item''s own new push-main on a base from BEFORE the landing is base-before-landing, not treated') `
      ((Resolve-TcPpcRowCopy -Row $rOwn -Index $bix -LandingBlob $bB -AfterLanding $after2) -eq 'base-before-landing') `
      ("own={0}" -f (Resolve-TcPpcRowCopy -Row $rOwn -Index $bix -LandingBlob $bB -AfterLanding $after2))
    T ($kMNF + '  a blob not on the push-main history is unknown-copy and a row with no pm_blob is pre-W0.1; neither is treated') `
      ($cp['unknown-copy'] -eq 1 -and $cp['pre-w01'] -eq 1) ("unknown={0} pre={1}" -f $cp['unknown-copy'], $cp['pre-w01'])
    T ($kCT + '  a row rebased at pre-flight onto a main holding the landing is treated: preflight_sha outranks an older branch_base') `
      ((Resolve-TcPpcRowCopy -Row $rPf -Index $bix -LandingBlob $bB -AfterLanding $after2) -eq 'treated') ("pf={0}" -f (Resolve-TcPpcRowCopy -Row $rPf -Index $bix -LandingBlob $bB -AfterLanding $after2))
    # AN ITEM THAT DOES NOT CHANGE PUSH-MAIN (W1.1, W3.x, W4.x) lands at c3 with push-main still at blob B. Read
    # literally, the plan's rule maps blob B to c2, before c3, and excludes every row for ever. Against the landing's
    # own blob, an updated row counts.
    $after3 = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase); $null = $after3.Add($c3); $null = $after3.Add($c4)
    $rUpd = ('{"ts":"2026-09-27T10:00:00Z","event":"push-main","pm_blob":"' + $bB + '","branch_base":"' + $c4 + '"}') | ConvertFrom-Json
    $rStale = ('{"ts":"2026-09-27T10:00:00Z","event":"push-main","pm_blob":"' + $bB + '","branch_base":"' + $c2 + '"}') | ConvertFrom-Json
    T ($kCT + '  for an item that did not change push-main, a row on the push-main current at its landing and a base holding it is treated') `
      ((Resolve-TcPpcRowCopy -Row $rUpd -Index $bix -LandingBlob $bB -AfterLanding $after3) -eq 'treated') ("upd={0}" -f (Resolve-TcPpcRowCopy -Row $rUpd -Index $bix -LandingBlob $bB -AfterLanding $after3))
    T ($kMF + '  for that item, a row on the same push-main but a base before the landing has not rebased onto it and is excluded') `
      ((Resolve-TcPpcRowCopy -Row $rStale -Index $bix -LandingBlob $bB -AfterLanding $after3) -eq 'base-before-landing') ("stale={0}" -f (Resolve-TcPpcRowCopy -Row $rStale -Index $bix -LandingBlob $bB -AfterLanding $after3))

    # ---- W0.3 step 2: parallel runs, at the bar in both directions ----
    function New-PpcSessionRow([string]$co, [string]$ts) { return (('{"ts":"' + $ts + '","event":"push-main","session":"s1","checkout":"C:\\wt\\' + $co + '","outcome":"landed"}') | ConvertFrom-Json) }
    $p4 = @((New-PpcSessionRow 'a' '2026-09-19T10:00:00Z'), (New-PpcSessionRow 'b' '2026-09-19T10:10:00Z'), (New-PpcSessionRow 'c' '2026-09-19T10:20:00Z'), (New-PpcSessionRow 'd' '2026-09-19T10:30:00Z'))
    $pr4 = Find-TcPpcParallelRuns -Rows $p4
    T ($kMF + '  four distinct checkouts with one session inside 2 hours form a parallel run (the count bar is 4)') `
      (@($pr4).Count -eq 1 -and $pr4[0].Checkouts -eq 4 -and $pr4[0].Rows -eq 4) ("runs={0}" -f @($pr4).Count)
    $p3 = @((New-PpcSessionRow 'a' '2026-09-19T10:00:00Z'), (New-PpcSessionRow 'b' '2026-09-19T10:10:00Z'), (New-PpcSessionRow 'c' '2026-09-19T10:20:00Z'), (New-PpcSessionRow 'a' '2026-09-19T10:30:00Z'))
    $pr3 = Find-TcPpcParallelRuns -Rows $p3
    T ($kMNF + '  three distinct checkouts (four rows, one checkout twice) do not form a parallel run: it counts checkouts, not rows') `
      (@($pr3).Count -eq 0) ("runs={0}" -f @($pr3).Count)
    $pAt = @((New-PpcSessionRow 'a' '2026-09-19T10:00:00Z'), (New-PpcSessionRow 'b' '2026-09-19T10:00:01Z'), (New-PpcSessionRow 'c' '2026-09-19T10:00:02Z'), (New-PpcSessionRow 'd' '2026-09-19T12:00:00Z'))
    $pPast = @((New-PpcSessionRow 'a' '2026-09-19T10:00:00Z'), (New-PpcSessionRow 'b' '2026-09-19T10:00:01Z'), (New-PpcSessionRow 'c' '2026-09-19T10:00:02Z'), (New-PpcSessionRow 'd' '2026-09-19T12:00:01Z'))
    $prAt = Find-TcPpcParallelRuns -Rows $pAt
    $prPast = Find-TcPpcParallelRuns -Rows $pPast
    T ($kMF + '  AT the 2-hour bar: the fourth checkout exactly 7200 s after the first is inside the window') (@($prAt).Count -eq 1) ("runs={0}" -f @($prAt).Count)
    T ($kMNF + '  a step PAST the 2-hour bar: with the fourth checkout 7201 s after the first, no 7200 s window holds all four') (@($prPast).Count -eq 0) ("runs={0}" -f @($prPast).Count)

    # ---- B1 at the bar, from a row's own run start (integer seconds, binary exact) ----
    function New-PpcPreRow([int]$sec, [string]$id) {
      $ts = ([datetime]'2026-09-30T10:00:00').AddSeconds($sec).ToString('yyyy-MM-ddTHH:mm:ss') + 'Z'
      return (('{"ts":"' + $ts + '","pid":' + $id + ',"run":"' + $id + '@2026-09-30T10:00:00.0000000Z","event":"push-main","outcome":"refused-rebase-conflict","phase":"preflight","checkout":"C:\\wt\\p' + $id + '"}') | ConvertFrom-Json)
    }
    $r60 = New-PpcPreRow 60 '1'; $r61 = New-PpcPreRow 61 '2'
    T ($kMNF + '  AT the B1 bar (60 s): a preflight refusal 60 s after its run start counts as within B1') `
      ((Get-TcPpcRowSeconds $r60) -eq 60 -and (Test-TcPpcWithinB1 (Get-TcPpcRowSeconds $r60))) ("sec={0}" -f (Get-TcPpcRowSeconds $r60))
    T ($kMF + '  a step PAST the B1 bar: a refusal 61 s after its run start does not count as within B1') `
      ((Get-TcPpcRowSeconds $r61) -eq 61 -and -not (Test-TcPpcWithinB1 (Get-TcPpcRowSeconds $r61))) ("sec={0}" -f (Get-TcPpcRowSeconds $r61))
    $five60 = @(1..5 | ForEach-Object { New-PpcPreRow 60 ([string]$_) })
    $five61 = @(1..5 | ForEach-Object { New-PpcPreRow 61 ([string]$_) })
    $four60 = @(1..4 | ForEach-Object { New-PpcPreRow 60 ([string]$_) })
    $m60 = Measure-TcPpcB1 -Rows $five60 -Ancestry @()
    $m61 = Measure-TcPpcB1 -Rows $five61 -Ancestry @()
    $m4 = Measure-TcPpcB1 -Rows $four60 -Ancestry @()
    T ($kCT + '  B1(a) over five refusals at 60 s (AT the minimum N of 5 and the 60 s bar) passes') ($m60.AVerdict -eq 'pass' -and $m60.A.N -eq 5) ("verdict={0} n={1}" -f $m60.AVerdict, $m60.A.N)
    T ($kMF + '  B1(a) over five refusals at 61 s fails') ($m61.AVerdict -eq 'fail') ("verdict={0}" -f $m61.AVerdict)
    T ($kMNF + '  B1(a) over four refusals (a step under the minimum N) gives NO verdict, never a pass') ($m4.AVerdict -like 'no verdict*') ("verdict={0}" -f $m4.AVerdict)

    # ---- B1(b): conflict ancestry through a FAKE git, so no repository is needed ----
    $script:ppcFakeAns = @{
      'log -1 --format=%H b0..g0 -- design/BACKLOG-course-findings.md' = @(0, 'c0')
      'merge-base --is-ancestor c0 p0' = @(0)
      'log -1 --format=%H b1..g1 -- ops/x.ps1' = @(0, 'c1')
      'merge-base --is-ancestor c1 p1' = @(1)
      'log -1 --format=%H b2..g2 -- ops/y.ps1' = @(0, 'c2')
    }
    $fakeGit = {
      param($GitArgs)
      $k = (@($GitArgs) -join ' ')
      if ($script:ppcFakeAns.ContainsKey($k)) { $v = $script:ppcFakeAns[$k]; return [pscustomobject]@{ Code = [int]$v[0]; Out = @($v | Select-Object -Skip 1) } }
      return [pscustomobject]@{ Code = 128; Out = @() }
    }
    $ra = '{"ts":"2026-09-30T11:00:00Z","event":"push-main","outcome":"refused-rebase-conflict","phase":"inlock","branch_base":"b0","grant":"g0","preflight_sha":"p0","conflict_files":["design/BACKLOG-course-findings.md"]}' | ConvertFrom-Json
    $rb = '{"ts":"2026-09-30T11:00:00Z","event":"push-main","outcome":"refused-rebase-conflict","phase":"inlock","branch_base":"b1","grant":"g1","preflight_sha":"p1","conflict_files":["ops/x.ps1"]}' | ConvertFrom-Json
    $rc = '{"ts":"2026-09-30T11:00:00Z","event":"push-main","outcome":"refused-rebase-conflict","phase":"inlock","branch_base":"b2","grant":"g2","conflict_files":["ops/y.ps1"]}' | ConvertFrom-Json
    $rd = '{"ts":"2026-09-30T11:00:00Z","event":"push-main","outcome":"refused-rebase-conflict","phase":"inlock","branch_base":"b0","grant":"g0","preflight_sha":"p0","degraded":"fetch","conflict_files":["design/BACKLOG-course-findings.md"]}' | ConvertFrom-Json
    $aa = Resolve-TcPpcConflictAncestry -Row $ra -Git $fakeGit
    $ab = Resolve-TcPpcConflictAncestry -Row $rb -Git $fakeGit
    $ac = Resolve-TcPpcConflictAncestry -Row $rc -Git $fakeGit
    $ad = Resolve-TcPpcConflictAncestry -Row $rd -Git $fakeGit
    $ancGot = ('{0}/{1},{2},{3}' -f $aa[0].Ancestry, $aa[0].Class, $ab[0].Ancestry, $ac[0].Ancestry)
    T ($kMF + '  an in-lock conflict whose collider is an ancestor of preflight_sha reads before-preflight; one that is not reads after-preflight; no preflight_sha reads unknown') `
      ($ancGot -eq 'before-preflight/backlog-index,after-preflight,unknown' -and $aa[0].Collider -eq 'c0') ("ancestry={0}" -f $ancGot)
    $ancList = @(
      [pscustomobject]@{ Row = $ra; Files = $aa }
      [pscustomobject]@{ Row = $rb; Files = $ab }
      [pscustomobject]@{ Row = $rc; Files = $ac }
      [pscustomobject]@{ Row = $rd; Files = $ad }
    )
    $mb = Measure-TcPpcB1 -Rows @($ra, $rb, $rc, $rd) -Ancestry $ancList
    T ($kMF + '  B1(b) counts the before-preflight in-lock conflict and leaves out the same shape on a row with degraded=fetch') `
      ($mb.BBad -eq 1 -and $mb.BConflictRows -eq 4 -and $mb.BVerdict -like 'no verdict*') ("bad={0} rows={1} verdict={2}" -f $mb.BBad, $mb.BConflictRows, $mb.BVerdict)

    # ---- landing resolution: the Plan line, as a whole token ----
    $planLead = 'Plan: design/PLAN-push-derived-' + 'conflicts-2026-09-23.md'
    $sA = 'a1' * 20; $sB = 'b1' * 20; $sC = 'c1' * 20; $sD = 'd1' * 20; $sE = 'e1' * 20
    $logFull = @(
      ('@@TC-COMMIT ' + $sA + ' 2026-09-23T07:28:37-05:00'), 'Plan 2026-09-23: the plan', ($planLead + ' (this commit adds it)')
      ('@@TC-COMMIT ' + $sB + ' 2026-09-24T07:00:00-05:00'), 'the tenth item of row 2', ($planLead + ' W2.10')
      ('@@TC-COMMIT ' + $sC + ' 2026-09-25T07:00:00-05:00'), 'pre-flight lands', ($planLead + ' W2.1')
      ('@@TC-COMMIT ' + $sD + ' 2026-09-26T07:00:00-05:00'), 'a follow-up that names it again', ($planLead + ' W2.1')
      ('@@TC-COMMIT ' + $sE + ' 2026-09-27T07:00:00-05:00'), 'two items and another plan', ($planLead + ' W0.2, W1.1.'), 'Plan: design/PLAN-other-2026-09-23.md W3.1'
    )
    $plFull = ConvertFrom-TcPpcPlanLog $logFull
    $hitC = Find-TcPpcItemLanding -Records $plFull.Records -ItemId 'W2.1'
    T ($kMF + '  a frozen log carrying the Plan line resolves the landing, and the FIRST such commit wins over a later one') `
      ($null -ne $hitC -and $hitC.Sha -eq $sC -and $plFull.Malformed -eq 0 -and @($plFull.Records).Count -eq 5) ("sha={0} records={1}" -f $(if ($hitC) { $hitC.Sha } else { '(none)' }), @($plFull.Records).Count)
    $logTen = @(('@@TC-COMMIT ' + $sB + ' 2026-09-24T07:00:00-05:00'), ($planLead + ' W2.10'))
    $plTen = ConvertFrom-TcPpcPlanLog $logTen
    $hitTen = Find-TcPpcItemLanding -Records $plTen.Records -ItemId 'W2.1'
    T ($kMNF + '  W2.1 does not match a Plan line naming W2.10: the id is a whole token') ($null -eq $hitTen) ("sha={0}" -f $(if ($hitTen) { $hitTen.Sha } else { '(none)' }))
    $hitTwo = Find-TcPpcItemLanding -Records $plFull.Records -ItemId 'W1.1'
    $hitOther = Find-TcPpcItemLanding -Records $plFull.Records -ItemId 'W3.1'
    $hitSelf = Find-TcPpcItemLanding -Records $plFull.Records -ItemId 'W0.1'
    T ($kCT + '  a Plan line naming two items (with a trailing full stop) resolves each of them') ($null -ne $hitTwo -and $hitTwo.Sha -eq $sE) ("sha={0}" -f $(if ($hitTwo) { $hitTwo.Sha } else { '(none)' }))
    T ($kMNF + '  a Plan line for ANOTHER plan, and the plan''s own "(this commit adds it)" line, resolve no item') ($null -eq $hitOther -and $null -eq $hitSelf) ("other={0} self={1}" -f [bool]$hitOther, [bool]$hitSelf)

    # ---- read-out dates, at the bar ----
    $oneBar = @([pscustomobject]@{ Id = 'B1'; Items = @('W2.1'); ReadoutDays = 14 })
    $roAt = ConvertTo-TcPpcUtc '2026-10-09T12:00:00Z'
    $stAt = Resolve-TcPpcBarStates -Bars $oneBar -Records $plFull.Records -AtUtc $roAt
    $stBefore = Resolve-TcPpcBarStates -Bars $oneBar -Records $plFull.Records -AtUtc $roAt.AddSeconds(-1)
    T ($kMF + '  AT the read-out (landing plus 14 days, to the second) a bar is due') ($stAt[0].Due -and (Format-TcPpcUtc $stAt[0].Readout) -eq '2026-10-09T12:00:00Z') ("due={0} readout={1}" -f $stAt[0].Due, (Format-TcPpcUtc $stAt[0].Readout))
    T ($kMNF + '  one second before its read-out a bar is not due') (-not $stBefore[0].Due) ("due={0}" -f $stBefore[0].Due)
    $multiBar = @([pscustomobject]@{ Id = 'B8'; Items = @('W2.1', 'W2.2'); ReadoutDays = 14 })
    $stMulti = Resolve-TcPpcBarStates -Bars $multiBar -Records $plFull.Records -AtUtc $roAt
    T ($kMNF + '  a bar judging two items is NOT LANDED while one of them has no Plan line, and is never due') (-not $stMulti[0].Landed -and -not $stMulti[0].Due -and (@($stMulti[0].Missing) -join ',') -eq 'W2.2') ("landed={0} missing={1}" -f $stMulti[0].Landed, (@($stMulti[0].Missing) -join ','))

    # ---- result lines: section 13 only, outside fences, B2 is not B2b ----
    $rl13 = 'B1: ' + 'result pass over 7'
    $planT = @('# PLAN', '## 12. Decisions', 'B2: result pass (section 12, does not count)', '## 13. Results against the bars', 'Each bar''s result is one line, `B<n>: result <verdict>`.', '```', 'B3: result inside a fence', '```', ('- ' + $rl13), 'B2b: result pass over 3', '## 14. Review dispositions', 'B4: result pass (section 14, does not count)') -join "`n"
    $rb13 = Get-TcPpcResultBars -PlanText $planT
    T ($kCT + '  a result line in section 13, list marker or not, is read, and B2b is its own id') ($rb13.Found -and $rb13.Ids.ContainsKey('B1') -and $rb13.Ids.ContainsKey('B2b')) ("ids={0}" -f (@($rb13.Ids.Keys | Sort-Object) -join ','))
    T ($kMNF + '  a result line in another section or inside a fence does not count, and B2b does not satisfy B2') (-not $rb13.Ids.ContainsKey('B2') -and -not $rb13.Ids.ContainsKey('B3') -and -not $rb13.Ids.ContainsKey('B4')) ("ids={0}" -f (@($rb13.Ids.Keys | Sort-Object) -join ','))

    # ---- -Due, run as a CHILD so its exit code is the one a scheduled task reads ----
    $psExe = Join-Path $PSHOME 'powershell.exe'
    $planNo = Join-Path $tmp 'plan-no-result.md'
    $planYes = Join-Path $tmp 'plan-with-result.md'
    $plan13 = @('# PLAN', '## 13. Results against the bars', 'Empty until the items run.')
    [IO.File]::WriteAllText($planNo, (($plan13 + @('', '## 14. Review dispositions', ('- ' + $rl13 + ' (section 14 does not count)'))) -join "`n"))
    [IO.File]::WriteAllText($planYes, (($plan13 + @(('- ' + $rl13 + ' (2026-09-25 to 2026-10-09, W0.3 blob x)'), '', '## 14. Review dispositions')) -join "`n"))
    $logW21 = Join-Path $tmp 'log-w21.txt'
    $logNone = Join-Path $tmp 'log-none.txt'
    [IO.File]::WriteAllText($logW21, ((@(('@@TC-COMMIT ' + $sC + ' 2026-09-25T12:00:00Z'), 'pre-flight lands', ($planLead + ' W2.1'))) -join "`n"))
    [IO.File]::WriteAllText($logNone, ((@(('@@TC-COMMIT ' + $sB + ' 2026-09-24T12:00:00Z'), ($planLead + ' W2.10'))) -join "`n"))
    $dueNow = '2026-10-10T00:00:00Z'
    $o1 = @(& $psExe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Due -PlanFile $planNo -PlanLogFile $logW21 -NowUtc $dueNow); $rc1 = $LASTEXITCODE
    T ($kMF + '  -Due with a bar past its read-out and no result line in section 13 exits 2 and names the bar') `
      ($rc1 -eq 2 -and @($o1 | Where-Object { $_ -match '^\s*B1\s.*DUE; result line MISSING' }).Count -eq 1 -and ([string]$o1[$o1.Count - 1]) -match '^PUSH-CONVERGENCE-DUE-COMPLETE .*missing=1$') `
      ("rc={0} last={1}" -f $rc1, $(if ($o1.Count) { $o1[$o1.Count - 1] } else { '' }))
    $o2 = @(& $psExe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Due -PlanFile $planYes -PlanLogFile $logW21 -NowUtc $dueNow); $rc2 = $LASTEXITCODE
    T ($kCT + '  -Due with the result line in section 13 exits 0 and reads it as present') `
      ($rc2 -eq 0 -and @($o2 | Where-Object { $_ -match '^\s*B1\s.*DUE; result line present' }).Count -eq 1) ("rc={0}" -f $rc2)
    $o3 = @(& $psExe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Due -PlanFile $planNo -PlanLogFile $logNone -NowUtc $dueNow); $rc3 = $LASTEXITCODE
    T ($kMNF + '  -Due over a log where W2.1 never landed (only W2.10) prints B1 NOT LANDED and exits 0: a bar not landed is never due') `
      ($rc3 -eq 0 -and @($o3 | Where-Object { $_ -match '^\s*B1\s.*NOT LANDED' }).Count -eq 1) ("rc={0}" -f $rc3)

    # ---- -Cost over OLD-shape rows and one W0.1-shape row: every section runs, absent fields read absent ----
    $oc1 = '{"ts":"2026-09-18T20:00:00Z","pid":11,"event":"push-main","waitMs":14,"state":"held","base":"","grant":"","outcome":"landed","checkout":"C:\\wt\\x"}'
    $oc2 = '{"ts":"2026-09-18T20:30:00Z","pid":12,"run":"12@2026-09-18T20:10:00.0000000Z","event":"push-main","waitMs":14,"state":"held","base":"","grant":"","outcome":"refused-rebase-conflict","checkout":"C:\\wt\\x"}'
    $oc3 = '{"ts":"2026-09-18T21:00:00Z","pid":13,"run":"13@2026-09-18T20:40:00.0000000Z","event":"push-main","waitMs":14,"state":"held","base":"","grant":"","outcome":"landed","checkout":"C:\\wt\\y","schema":2,"pm_blob":"' + $bB + '","session":"s9","chain_touching":false,"leg_sec":{"rg":60,"ta":0,"rh":null},"rg_reused":10,"rg_selftests":40,"ta_rc":0,"hook_ta":"reused","lock_held_ms":25000,"rebase_phases":["inlock"]}'
    $ocRows = @(($oc1 | ConvertFrom-Json), ($oc2 | ConvertFrom-Json), ($oc3 | ConvertFrom-Json))
    $ocSel = Select-TcPpcRows -Rows $ocRows -SandboxRoot $sbRoot
    $ocStates = Resolve-TcPpcBarStates -Bars $script:TcPpcBars -Records @() -AtUtc (ConvertTo-TcPpcUtc '2026-09-19T00:00:00Z')
    $ocCtx = [pscustomobject]@{
      StartUtc = (ConvertTo-TcPpcUtc '2026-09-18T00:00:00Z'); EndUtc = (ConvertTo-TcPpcUtc '2026-09-19T00:00:00Z'); RefName = 'fixture'
      Sel = $ocSel; Files = @('fixture'); Index = $bix; BlobOk = $true; Bars = $ocStates; Bar = $null; Ancestry = @()
      RunGatesTimes = @(); RunGatesOk = $true; PlanLogOk = $true; PlanLogWhy = ''; PlanRecords = 0; PlanMalformed = 0
    }
    $capCost = Invoke-TcPpcCaptured { Write-TcPpcCostReport -Rows $ocSel.Kept -Ctx $ocCtx }
    $ct = $capCost.Text
    T ($kMNF + '  a row in the OLD shape (no W0.1 field, even no run id) parses through every -Cost section without throwing and is counted pre-W0.1') `
      (-not $capCost.Error -and $ct -match '2 are pre-W0\.1' -and $ct -match 'rows with a readable start: 2 of 3' -and $ct -match '(?m)^13\. ') `
      ("error={0}" -f $capCost.Error)
    T ($kCT + '  the W0.1-shape row''s fields reach their sections: its run-gates leg ran, its test-auditors leg was reused, and its lock hold counts as moved') `
      ($ct -match 'rg run-gates\s+ran 1 \(median 60 s' -and $ct -match 'reused \(0 s\) 1' -and $ct -match 'moved during the legs[^\r\n]*N=1' -and $ct -match 'hook_ta[^\r\n]*reused 1') `
      ("text had rg={0} lock={1}" -f ($ct -match 'rg run-gates\s+ran 1'), ($ct -match 'moved during the legs[^\r\n]*N=1'))
    T ($kCT + '  a bar whose item has not landed is printed NOT LANDED in the -Cost bars section, never with a read-out') `
      ($ct -match '(?m)^\s+B1\s+W2\.1: NOT LANDED') ("had={0}" -f ($ct -match 'B1\s+W2\.1: NOT LANDED'))

    # ---- changes: the 6-hour gap, at the bar ----
    $cg1 = '{"ts":"2026-09-20T10:00:00Z","run":"21@2026-09-20T09:59:00.0000000Z","event":"push-main","outcome":"refused-gate-red","checkout":"C:\\wt\\g"}' | ConvertFrom-Json
    $cgAt = '{"ts":"2026-09-20T16:01:40Z","run":"22@2026-09-20T16:00:00.0000000Z","event":"push-main","outcome":"landed","checkout":"C:\\wt\\g"}' | ConvertFrom-Json
    $cgPast = '{"ts":"2026-09-20T16:01:41Z","run":"23@2026-09-20T16:00:01.0000000Z","event":"push-main","outcome":"landed","checkout":"C:\\wt\\g"}' | ConvertFrom-Json
    $gAt = Group-TcPpcChanges -Rows @($cg1, $cgAt)
    $gPast = Group-TcPpcChanges -Rows @($cg1, $cgPast)
    T ($kMNF + '  AT the 6-hour bar: an attempt starting exactly 21600 s after the previous row is the same change, landed after 2 attempts') `
      (@($gAt).Count -eq 1 -and $gAt[0].Landed -and $gAt[0].Attempts -eq 2 -and $gAt[0].Seconds -eq 21760 -and $gAt[0].How -eq 'gap') ("changes={0} sec={1}" -f @($gAt).Count, $(if (@($gAt).Count) { $gAt[0].Seconds } else { '' }))
    T ($kMF + '  a step PAST the 6-hour bar (21601 s) starts a new change, and the first is counted not landed') `
      (@($gPast).Count -eq 2 -and @(@($gPast) | Where-Object { -not $_.Landed }).Count -eq 1) ("changes={0}" -f @($gPast).Count)
    $cid1 = '{"ts":"2026-09-20T10:00:00Z","run":"31@2026-09-20T09:50:00.0000000Z","event":"push-main","outcome":"refused-rebase-conflict","checkout":"C:\\wt\\h","change_id":"pid1"}' | ConvertFrom-Json
    $cid2 = '{"ts":"2026-09-21T10:00:00Z","run":"32@2026-09-21T09:55:00.0000000Z","event":"push-main","outcome":"landed","checkout":"C:\\wt\\h","change_id":"pid1"}' | ConvertFrom-Json
    $gCid = Group-TcPpcChanges -Rows @($cid1, $cid2)
    T ($kCT + '  two attempts sharing a change_id a day apart are ONE change, timed from the first attempt''s start') `
      (@($gCid).Count -eq 1 -and $gCid[0].How -eq 'change_id' -and $gCid[0].Seconds -eq 87000) ("changes={0} sec={1}" -f @($gCid).Count, $(if (@($gCid).Count) { $gCid[0].Seconds } else { '' }))

    # ---- busy hours, at the bar ----
    function New-PpcHourRow([string]$ts) { return (('{"ts":"' + $ts + '","event":"push-main","outcome":"landed","checkout":"C:\\wt\\z"}') | ConvertFrom-Json) }
    $hr = @(0..5 | ForEach-Object { New-PpcHourRow ('2026-09-19T14:{0:00}:00Z' -f ($_ * 5)) }) + @(0..4 | ForEach-Object { New-PpcHourRow ('2026-09-19T15:{0:00}:00Z' -f ($_ * 5)) })
    $mh = Measure-TcPpcHours -Rows $hr
    T ($kMF + '  AT the busy bar: an hour with 6 push-main rows is busy') (@(@($mh.Busy) | Where-Object { $_.Hour -eq '2026-09-19T14Z' }).Count -eq 1) ("busy={0}" -f (@($mh.Busy | ForEach-Object { $_.Hour }) -join ','))
    T ($kMNF + '  a step under the busy bar: an hour with 5 rows is not busy, and both hours are active') (@($mh.Busy).Count -eq 1 -and $mh.Active -eq 2 -and $mh.Landings -eq 11) ("busy={0} active={1} landings={2}" -f @($mh.Busy).Count, $mh.Active, $mh.Landings)

    # ---- the flush split ----
    $fl1 = '{"ts":"2026-09-20T10:05:00Z","run":"41@2026-09-20T10:00:00.0000000Z","event":"push-main","checkout":"C:\\wt\\f","leg_sec":{"rg":300}}' | ConvertFrom-Json
    $fl2 = '{"ts":"2026-09-20T11:05:00Z","run":"42@2026-09-20T11:00:00.0000000Z","event":"push-main","checkout":"C:\\wt\\f","leg_sec":{"rg":60}}' | ConvertFrom-Json
    $spl = Split-TcPpcFlushRows -Rows @($fl1, $fl2) -LandingTimes @((ConvertTo-TcPpcUtc '2026-09-20T09:30:00Z')) -WindowStartUtc (ConvertTo-TcPpcUtc '2026-09-20T00:00:00Z')
    T ($kMF + '  the first row of a checkout after a run-gates commit is a flush row') (@($spl.Flush).Count -eq 1 -and [string]$spl.Flush[0].run -like '41@*') ("flush={0}" -f @($spl.Flush).Count)
    T ($kMNF + '  the next row of that checkout, with no run-gates commit in between, is not a flush row') (@($spl.Other).Count -eq 1 -and [string]$spl.Other[0].run -like '42@*') ("other={0}" -f @($spl.Other).Count)

    # ---- -History's pure measures ----
    function New-PpcLanding([string]$sha, [string]$ts, $files) { return [pscustomobject]@{ Sha = $sha; Prev = ''; Ts = (ConvertTo-TcPpcUtc $ts); Kind = 'push'; Files = @($files) } }
    $bk = 'design/BACKLOG-course-findings.md'
    $hl = @(
      (New-PpcLanding 'h1' '2026-09-20T10:00:00Z' @($bk, 'ops/a.ps1'))
      (New-PpcLanding 'h2' '2026-09-20T11:00:00Z' @($bk))
      (New-PpcLanding 'h3' '2026-09-20T12:00:01Z' @('ops/b.ps1'))
      (New-PpcLanding 'h4' '2026-09-20T12:01:40Z' @('ops/b.ps1', 'design/MEASURE-x.md'))
    )
    $tsh = Measure-TcPpcTouchShare -Landings $hl -Path $bk
    T ($kCT + '  the backlog touch share counts landings that changed the file, over landings with a file list') ($tsh.Touching -eq 2 -and $tsh.Landings -eq 4) ("touch={0} of {1}" -f $tsh.Touching, $tsh.Landings)
    $ov1 = Measure-TcPpcOverlapShare -Landings $hl
    $ov2 = Measure-TcPpcOverlapShare -Landings $hl -Remove $bk
    T ($kMF + '  removing the one shared file drops the median overlap share (1/3 to 0 over four landings)') `
      ([math]::Abs($ov1.Median - (1.0 / 3)) -lt 1e-9 -and $ov2.Median -eq 0 -and $ov1.N -eq 4) ("with={0} without={1}" -f $ov1.Median, $ov2.Median)
    $cc = Measure-TcPpcClassCensus -Landings $hl
    $ccB = @($cc | Where-Object { $_.Class -eq 'backlog-index' })[0]
    $ccC = @($cc | Where-Object { $_.Class -eq 'code' })[0]
    T ($kMF + '  AT the 60-minute bar: a backlog touch exactly 3600 s after another landing touched it is EXPOSED; the first touch is not') `
      ($ccB.Touches -eq 2 -and $ccB.Exposed -eq 1 -and $ccC.Touches -eq 3 -and $ccC.Exposed -eq 1) ("backlog {0} of {1}; code {2} of {3}" -f $ccB.Exposed, $ccB.Touches, $ccC.Exposed, $ccC.Touches)
    $hlPast = @((New-PpcLanding 'h1' '2026-09-20T10:00:00Z' @($bk)), (New-PpcLanding 'h2' '2026-09-20T11:00:01Z' @($bk)))
    $ccP = Measure-TcPpcClassCensus -Landings $hlPast
    $ccPB = @($ccP | Where-Object { $_.Class -eq 'backlog-index' })[0]
    T ($kMNF + '  a step PAST the 60-minute bar (3601 s) is not exposed') ($ccPB.Exposed -eq 0 -and $ccPB.Touches -eq 2) ("exposed={0}" -f $ccPB.Exposed)
    $rfl = @(
      ('3333333333333333333333333333333333333333' + "`t" + 'origin/main@{2026-09-20T12:00:00-05:00}' + "`t" + 'update by push')
      ('2222222222222222222222222222222222222222' + "`t" + 'origin/main@{2026-09-20T11:00:00-05:00}' + "`t" + 'fetch -q origin: fast-forward')
      ('1111111111111111111111111111111111111111' + "`t" + 'origin/main@{2026-09-20T10:00:00-05:00}' + "`t" + 'update by push')
    )
    $rfe = ConvertFrom-TcPpcReflog $rfl
    $rfLand = Get-TcPpcReflogLandings -Entries $rfe -StartUtc (ConvertTo-TcPpcUtc '2026-09-20T00:00:00Z') -EndUtc (ConvertTo-TcPpcUtc '2026-09-21T00:00:00Z')
    T ($kCT + '  the reflog reads oldest first, and each landing after the first entry carries the sha it moved from (a fetch move is a landing from elsewhere)') `
      (@($rfLand).Count -eq 2 -and $rfLand[0].Prev -eq ('1' * 40) -and $rfLand[0].Kind -eq 'fetch' -and $rfLand[1].Kind -eq 'push') ("landings={0}" -f @($rfLand).Count)

    # ---- the -ListSet read: never run without the parameter, and a listing is checked against its own marker ----
    $lsGood = ConvertFrom-TcPpcListSet @('ops/a.ps1', 'grocery/b.ps1', 'CHAIN-REHEARSAL-LISTSET-COMPLETE files=2')
    $lsBad = ConvertFrom-TcPpcListSet @('ops/a.ps1', 'CHAIN-REHEARSAL-LISTSET-COMPLETE files=2')
    T ($kCT + '  a listing whose path count equals its marker is read as the set') ($lsGood.Ok -and @($lsGood.Files).Count -eq 2) ("ok={0} files={1}" -f $lsGood.Ok, @($lsGood.Files).Count)
    T ($kMF + '  a listing whose count disagrees with its own marker is refused, never read as a smaller set') (-not $lsBad.Ok -and $lsBad.Why -match 'marker says 2') ("ok={0} why={1}" -f $lsBad.Ok, $lsBad.Why)
    $fr = Join-Path $tmp 'fakerepo'
    $null = New-Item -ItemType Directory -Force -ErrorAction Stop (Join-Path $fr 'ops')
    $ran = Join-Path $tmp 'rehearsal-ran.txt'
    $noLs = "param([switch]`$Other)`n[IO.File]::WriteAllText('" + $ran + "', 'ran')`n"
    [IO.File]::WriteAllText((Join-Path $fr 'ops\rehearse-chain.ps1'), $noLs)
    $csNo = Get-TcPpcChainSet -Repo $fr -Commit 'abc'
    T ($kMNF + '  a rehearse-chain with no -ListSet parameter is reported BLIND and is NOT RUN, because a run would be a real rehearsal') `
      (-not $csNo.Ok -and $csNo.Why -match 'no -ListSet' -and -not (Test-Path -LiteralPath $ran)) ("ok={0} ran={1}" -f $csNo.Ok, (Test-Path -LiteralPath $ran))
    $withLs = "param([switch]`$ListSet, [string]`$Commit = '')`nif (`$ListSet) { 'ops/a.ps1'; 'ops/b.ps1'; 'CHAIN-REHEARSAL-LISTSET-COMPLETE files=2'; exit 0 }`nexit 9`n"
    [IO.File]::WriteAllText((Join-Path $fr 'ops\rehearse-chain.ps1'), $withLs)
    $csYes = Get-TcPpcChainSet -Repo $fr -Commit 'abc'
    T ($kCT + '  a rehearse-chain WITH -ListSet is run as a child and its set is read') ($csYes.Ok -and (@($csYes.Files) -join ',') -eq 'ops/a.ps1,ops/b.ps1') ("ok={0} why={1} files={2}" -f $csYes.Ok, $csYes.Why, (@($csYes.Files) -join ','))

    # ==== W0.3b (15.5): attempts, changes and leg sets, over frozen literal rows ====
    function New-PpcAttRow {
      <# One push-main row as the ledger holds it. Every argument is a literal, so no case is fed a fragment. #>
      param([string]$Co, [string]$Ts, [string]$RunStart, [string]$Outcome, [string]$Sub = '', [string]$Cid = '', [string]$Extra = '')
      $j = '{"ts":"' + $Ts + '","run":"9@' + $RunStart + '","event":"push-main","outcome":"' + $Outcome + '","checkout":"C:\\wt\\' + $Co + '"'
      if ($Sub) { $j += ',"subjects_sha":"' + $Sub + '"' }
      if ($Cid) { $j += ',"change_id":"' + $Cid + '"' }
      if ($Extra) { $j += ',' + $Extra }
      return (($j + '}') | ConvertFrom-Json)
    }
    # THE HOUSEKEEPING LANE, from the ledger rows the planner re-read (section 2.1): three attempts, one subject set,
    # three change_ids because it regenerated a baseline after each rebase. By change_id, B6 read 1.0 where it took 3.
    $hk1 = New-PpcAttRow 'housekeeping' '2026-09-23T09:34:59Z' '2026-09-23T08:57:01.0000000Z' 'refused-rebase-conflict' 'hsubj' '67c869cf9e76' '"chain_touching":true'
    $hk2 = New-PpcAttRow 'housekeeping' '2026-09-23T10:11:46Z' '2026-09-23T09:41:15.0000000Z' 'refused-rebase-conflict' 'hsubj' '2f849964be2f' '"chain_touching":true'
    $hk3 = New-PpcAttRow 'housekeeping' '2026-09-23T10:48:53Z' '2026-09-23T10:16:17.0000000Z' 'landed-after-rebase' 'hsubj' '81a788cbef31' '"chain_touching":true'
    $gHk = Group-TcPpcChanges -Rows @($hk1, $hk2, $hk3)
    T ($kMF + '  three attempts of one lane with three different change_ids and one subjects_sha are ONE change with 3 attempts, timed from the first') `
      (@($gHk).Count -eq 1 -and $gHk[0].Attempts -eq 3 -and $gHk[0].How -eq 'subjects' -and $gHk[0].Landed -and -not $gHk[0].FirstAttemptLanded -and $gHk[0].Seconds -eq 6712) `
      ("changes={0} attempts={1} sec={2}" -f @($gHk).Count, $(if (@($gHk).Count) { $gHk[0].Attempts }), $(if (@($gHk).Count) { $gHk[0].Seconds }))
    $sevenRows = @(1..7 | ForEach-Object { New-PpcAttRow 'seven' ('2026-09-22T1{0}:05:00Z' -f $_) ('2026-09-22T1{0}:00:00.0000000Z' -f $_) 'landed' ('sub' + $_) ('cid' + $_) })
    $gSeven = Group-TcPpcChanges -Rows $sevenRows
    T ($kMNF + '  seven changes in one checkout with different subjects stay SEVEN changes, each landed on its first attempt') `
      (@($gSeven).Count -eq 7 -and @(@($gSeven) | Where-Object { $_.Attempts -eq 1 -and $_.FirstAttemptLanded }).Count -eq 7) ("changes={0}" -f @($gSeven).Count)

    # ---- the tie-break: change_id splits one (checkout, subjects_sha) only after a landing ----
    $tb1 = New-PpcAttRow 'tie' '2026-09-22T12:05:00Z' '2026-09-22T12:00:00.0000000Z' 'landed' 'tsub' 'k1'
    $tb2 = New-PpcAttRow 'tie' '2026-09-22T13:05:00Z' '2026-09-22T13:00:00.0000000Z' 'landed' 'tsub' 'k2'
    $tb3 = New-PpcAttRow 'tie' '2026-09-22T13:05:00Z' '2026-09-22T13:00:00.0000000Z' 'refused-already-on-main' 'tsub' 'k1'
    $gSplit = Group-TcPpcChanges -Rows @($tb1, $tb2)
    $gSame = Group-TcPpcChanges -Rows @($tb1, $tb3)
    T ($kMF + '  the same subjects after a LANDING over a different patch (change_id) is a new change: two changes') (@($gSplit).Count -eq 2) ("changes={0}" -f @($gSplit).Count)
    T ($kCT + '  the same subjects after a landing over the SAME patch is that change pushed again: one change with 2 attempts') `
      (@($gSame).Count -eq 1 -and $gSame[0].Attempts -eq 2) ("changes={0} attempts={1}" -f @($gSame).Count, $(if (@($gSame).Count) { $gSame[0].Attempts }))

    # ---- a change that lands from ANOTHER checkout crosses checkouts ----
    $xa = New-PpcAttRow 'lanea' '2026-09-22T11:00:00Z' '2026-09-22T10:50:00.0000000Z' 'refused-gate-red' 'xsub' 'xa' '"chain_touching":true'
    $xb = New-PpcAttRow 'laneb' '2026-09-22T11:30:00Z' '2026-09-22T11:20:00.0000000Z' 'landed' 'xsub' 'xb' '"chain_touching":true'
    $gX = Group-TcPpcChanges -Rows @($xa, $xb)
    $mX = Measure-TcPpcB6 -Changes $gX -Runs @() -HourLandings @{}
    T ($kMF + '  a change whose only push-main row was refused and which landed from another checkout crosses checkouts, is not a first-attempt landing, and stays out of B6''s denominator') `
      (@($gX).Count -eq 1 -and $gX[0].Crosses -and $gX[0].Checkouts -eq 2 -and $gX[0].Landed -and -not $gX[0].FirstAttemptLanded -and $mX.Crossing -eq 1 -and $mX.CrossingFirst -eq 0 -and $mX.Strata['quiet'].Changes -eq 0 -and $mX.Strata['contended'].Changes -eq 0) `
      ("changes={0} crosses={1} crossing={2} quiet={3}" -f @($gX).Count, $(if (@($gX).Count) { $gX[0].Crosses }), $mX.Crossing, $mX.Strata['quiet'].Changes)

    # ---- B6's columns: own against ambient is read from the patch, and only own reds and genuine conflicts are left out ----
    $colRows = @(
      (New-PpcAttRow 'cols' '2026-09-24T14:01:30Z' '2026-09-24T14:01:00.0000000Z' 'refused-gate-red' 'csub' 'p1' '"chain_touching":true')
      (New-PpcAttRow 'cols' '2026-09-24T14:02:30Z' '2026-09-24T14:02:00.0000000Z' 'refused-gate-red' 'csub' 'p2' '"chain_touching":true')
      (New-PpcAttRow 'cols' '2026-09-24T14:03:30Z' '2026-09-24T14:03:00.0000000Z' 'refused-rebase-conflict' 'csub' 'p2' '"chain_touching":true,"conflict_files":["ops/x.ps1"]')
      (New-PpcAttRow 'cols' '2026-09-24T14:04:30Z' '2026-09-24T14:04:00.0000000Z' 'refused-rebase-conflict' 'csub' 'p2' '"chain_touching":true,"conflict_files":["design/BACKLOG-course-findings.md"]')
      (New-PpcAttRow 'cols' '2026-09-24T14:05:30Z' '2026-09-24T14:05:00.0000000Z' 'refused-not-ready' 'csub' 'p2' '"chain_touching":true,"dirty_since":"start"')
      (New-PpcAttRow 'cols' '2026-09-24T14:06:30Z' '2026-09-24T14:06:00.0000000Z' 'refused-not-ready' 'csub' 'p2' '"chain_touching":true,"dirty_since":"during-legs"')
      (New-PpcAttRow 'cols' '2026-09-24T14:07:30Z' '2026-09-24T14:07:00.0000000Z' 'push-rejected' 'csub' 'p2' '"chain_touching":true,"reject_class":"rehearsal"')
      (New-PpcAttRow 'cols' '2026-09-24T14:08:30Z' '2026-09-24T14:08:00.0000000Z' 'landed-after-rebase' 'csub' 'p2' '"chain_touching":true')
    )
    $gCol = Group-TcPpcChanges -Rows $colRows
    $cc0 = $(if (@($gCol).Count) { $gCol[0].Classes } else { [ordered]@{} })
    $colGot = (@('landed', 'own-red', 'ambient-red', 'conflict-genuine', 'conflict-mechanical', 'not-ready-start', 'not-ready-legs', 'other') | ForEach-Object { '{0}={1}' -f $_, $cc0[$_] }) -join ','
    T ($kMF + '  a red on a patch that later landed unchanged is AMBIENT and counted, a red on a patch the lane then changed is OWN and left out, a code conflict is genuine and left out, a backlog conflict is mechanical and counted: 6 of 8 counted') `
      (@($gCol).Count -eq 1 -and $colGot -eq 'landed=1,own-red=1,ambient-red=1,conflict-genuine=1,conflict-mechanical=1,not-ready-start=1,not-ready-legs=1,other=1' -and $gCol[0].Counted -eq 6 -and $gCol[0].Attempts -eq 8) `
      ("changes={0} {1} counted={2}" -f @($gCol).Count, $colGot, $(if (@($gCol).Count) { $gCol[0].Counted }))

    # ---- a plain push's hook-refused row is an attempt; one under a push-main is not counted twice ----
    $hrA = '{"ts":"2026-09-24T09:00:00Z","event":"hook-refused","cause":"run-gates","gate":"ops\\audit-x.ps1","under_push_main":false,"checkout":"C:\\wt\\plain"}' | ConvertFrom-Json
    $hrB = '{"ts":"2026-09-24T09:20:00Z","event":"hook-refused","cause":"rehearsal","under_push_main":true,"checkout":"C:\\wt\\plain"}' | ConvertFrom-Json
    $hrC = '{"ts":"2026-09-24T09:00:00Z","event":"hook-refused","cause":"rehearsal","under_push_main":false,"checkout":"C:\\wt\\nowhere"}' | ConvertFrom-Json
    $hrPm = New-PpcAttRow 'plain' '2026-09-24T09:40:00Z' '2026-09-24T09:30:00.0000000Z' 'landed' 'psub' 'pp'
    $hrSel = Select-TcPpcRows -Rows @($hrA, $hrB, $hrC, $hrPm) -SandboxRoot $sbRoot
    $hrSet = Get-TcPpcChangeSet -Rows $hrSel.Kept -HookRefused $hrSel.HookRefused
    $hrCh = @($hrSet.Changes)
    T ($kMF + '  a plain push''s hook refusal joins the change its checkout lands next as an attempt, one under a push-main is not counted again, and one with no change is counted unattached') `
      (@($hrSel.HookRefused).Count -eq 2 -and $hrSel.HookRefusedUnderPm -eq 1 -and $hrCh.Count -eq 1 -and $hrCh[0].Attempts -eq 2 -and $hrCh[0].HookRows -eq 1 -and $hrCh[0].Classes['red-undecided'] -eq 1 -and -not $hrCh[0].FirstAttemptLanded -and $hrSet.Unattached -eq 1) `
      ("plain={0} underPm={1} changes={2} attempts={3} unattached={4}" -f @($hrSel.HookRefused).Count, $hrSel.HookRefusedUnderPm, $hrCh.Count, $(if ($hrCh.Count) { $hrCh[0].Attempts }), $hrSet.Unattached)

    # The attach window, at its bar: a plain push's refusal up to 6 hours before the change's first attempt joins it.
    $hwAt = '{"ts":"2026-09-24T03:30:00Z","event":"hook-refused","cause":"rehearsal","under_push_main":false,"checkout":"C:\\wt\\plain"}' | ConvertFrom-Json
    $hwPast = '{"ts":"2026-09-24T03:29:59Z","event":"hook-refused","cause":"rehearsal","under_push_main":false,"checkout":"C:\\wt\\plain"}' | ConvertFrom-Json
    $hwSetAt = Get-TcPpcChangeSet -Rows @($hrPm) -HookRefused @($hwAt)
    $hwSetPast = Get-TcPpcChangeSet -Rows @($hrPm) -HookRefused @($hwPast)
    T ($kMF + '  AT the 6-hour attach bar a plain push''s refusal exactly 21600 s before the change''s first attempt joins it, and one 21601 s before joins nothing') `
      ($hwSetAt.Unattached -eq 0 -and @($hwSetAt.Changes)[0].Attempts -eq 2 -and $hwSetPast.Unattached -eq 1 -and @($hwSetPast.Changes)[0].Attempts -eq 1) `
      ("at: unattached {0}; past: unattached {1}" -f $hwSetAt.Unattached, $hwSetPast.Unattached)
    $dryRow = New-PpcAttRow 'plain' '2026-09-24T09:10:00Z' '2026-09-24T09:05:00.0000000Z' 'dry-run' 'psub' 'pp'
    $drySet = Get-TcPpcChangeSet -Rows @($dryRow, $hrPm)
    T ($kMNF + '  a dry run moves nothing, so it is no attempt: the change keeps one attempt, landed on its first, and the dry run is counted apart') `
      ($drySet.DryRuns -eq 1 -and @($drySet.Changes).Count -eq 1 -and @($drySet.Changes)[0].Attempts -eq 1 -and @($drySet.Changes)[0].FirstAttemptLanded) ("dry={0} changes={1}" -f $drySet.DryRuns, @($drySet.Changes).Count)

    # ---- the strata, at the bar: 8 landings in the hour is contended, 7 is quiet; a parallel run is contended ----
    $stRow = New-PpcAttRow 'strat' '2026-09-24T15:20:00Z' '2026-09-24T15:10:00.0000000Z' 'landed' 'ssub' 'sc'
    $stChG = Group-TcPpcChanges -Rows @($stRow); $stCh = @($stChG)
    $st8 = Get-TcPpcChangeStratum -Change $stCh[0] -Runs @() -HourLandings @{ '2026-09-24T15' = 8 }
    $st7 = Get-TcPpcChangeStratum -Change $stCh[0] -Runs @() -HourLandings @{ '2026-09-24T15' = 7 }
    T ($kMF + '  AT the stratum bar: an attempt begun in an hour with 8 landings makes its change CONTENDED') ($st8 -eq 'contended') ("stratum={0}" -f $st8)
    T ($kMNF + '  a step under the stratum bar: 7 landings in the hour leaves the change QUIET') ($st7 -eq 'quiet') ("stratum={0}" -f $st7)
    $prRows = @(
      (New-PpcAttRow 'pa' '2026-09-24T16:00:00Z' '2026-09-24T15:55:00.0000000Z' 'landed' 'pas' 'pac' '"session":"sp"')
      (New-PpcAttRow 'pb' '2026-09-24T16:10:00Z' '2026-09-24T16:05:00.0000000Z' 'landed' 'pbs' 'pbc' '"session":"sp"')
      (New-PpcAttRow 'pc' '2026-09-24T16:20:00Z' '2026-09-24T16:15:00.0000000Z' 'landed' 'pcs' 'pcc' '"session":"sp"')
      (New-PpcAttRow 'pd' '2026-09-24T16:30:00Z' '2026-09-24T16:25:00.0000000Z' 'landed' 'pds' 'pdc' '"session":"sp"')
    )
    $prRuns = Find-TcPpcParallelRuns -Rows $prRows
    $prAll = Group-TcPpcChanges -Rows $prRows; $prCh = @(@($prAll) | Where-Object { $_.Rows[0].checkout -like '*\pa' })
    $stPr = Get-TcPpcChangeStratum -Change $prCh[0] -Runs $prRuns -HourLandings @{}
    T ($kMF + '  a change with an attempt inside a parallel run is CONTENDED, whatever the hour') (@($prRuns).Count -eq 1 -and $stPr -eq 'contended') ("runs={0} stratum={1}" -f @($prRuns).Count, $stPr)

    # ---- B6 at its bars, compared in integers ----
    function New-PpcChainSet {
      <# $N landed chain-touching changes in one checkout; the first $Extra of them take one refused attempt first (a
         rehearsal void, counted); $Rounds gives each change's landed row its rounds, and every refused row has 1. #>
      param([string]$Pre, [int]$N, [int]$Extra, [int[]]$Rounds)
      $out = [Collections.Generic.List[object]]::new()
      for ($i = 1; $i -le $N; $i++) {
        $t0 = ([datetime]'2026-09-25T10:00:00').AddMinutes(3 * $i)
        if ($i -le $Extra) {
          $ts = $t0.ToString('yyyy-MM-ddTHH:mm:ss') + 'Z'; $rs = $t0.AddSeconds(-10).ToString('yyyy-MM-ddTHH:mm:ss') + '.0000000Z'
          $out.Add((New-PpcAttRow $Pre $ts $rs 'push-rejected' ($Pre + 's' + $i) ($Pre + 'c' + $i) '"chain_touching":true,"reject_class":"rehearsal","rounds":1'))
        }
        $t1 = $t0.AddMinutes(1)
        $ts = $t1.ToString('yyyy-MM-ddTHH:mm:ss') + 'Z'; $rs = $t1.AddSeconds(-10).ToString('yyyy-MM-ddTHH:mm:ss') + '.0000000Z'
        $out.Add((New-PpcAttRow $Pre $ts $rs 'landed' ($Pre + 's' + $i) ($Pre + 'c' + $i) ('"chain_touching":true,"rounds":' + $Rounds[$i - 1])))
      }
      return , ($out.ToArray())
    }
    $ones = @(1, 1, 1, 1, 1, 1, 1, 1, 1, 1)
    $b6At = Measure-TcPpcB6 -Changes (Group-TcPpcChanges -Rows (New-PpcChainSet 'ba' 10 2 $ones)) -Runs @() -HourLandings @{}
    $b6Past = Measure-TcPpcB6 -Changes (Group-TcPpcChanges -Rows (New-PpcChainSet 'bp' 10 3 $ones)) -Runs @() -HourLandings @{}
    $b6Nine = Measure-TcPpcB6 -Changes (Group-TcPpcChanges -Rows (New-PpcChainSet 'bn' 9 0 $ones)) -Runs @() -HourLandings @{}
    T ($kCT + '  AT the B6(a) bar and its minimum N: 12 counted attempts over 10 quiet changes (1.2) passes') ($b6At.Strata['quiet'].Changes -eq 10 -and $b6At.Strata['quiet'].Counted -eq 12 -and $b6At.Strata['quiet'].AVerdict -eq 'pass') ("n={0} counted={1} verdict={2}" -f $b6At.Strata['quiet'].Changes, $b6At.Strata['quiet'].Counted, $b6At.Strata['quiet'].AVerdict)
    T ($kMF + '  a step PAST the B6(a) bar: 13 counted attempts over 10 quiet changes fails') ($b6Past.Strata['quiet'].Counted -eq 13 -and $b6Past.Strata['quiet'].AVerdict -eq 'fail') ("counted={0} verdict={1}" -f $b6Past.Strata['quiet'].Counted, $b6Past.Strata['quiet'].AVerdict)
    T ($kMNF + '  9 quiet changes (a step under the minimum N of 10) give NO verdict, never a pass') ($b6Nine.Strata['quiet'].Changes -eq 9 -and $b6Nine.Strata['quiet'].AVerdict -like 'no verdict*') ("verdict={0}" -f $b6Nine.Strata['quiet'].AVerdict)
    $leg18 = Measure-TcPpcB6 -Changes (Group-TcPpcChanges -Rows (New-PpcChainSet 'la' 10 0 @(2, 2, 2, 2, 2, 2, 2, 2, 1, 1))) -Runs @() -HourLandings @{}
    $leg19 = Measure-TcPpcB6 -Changes (Group-TcPpcChanges -Rows (New-PpcChainSet 'lb' 10 0 @(2, 2, 2, 2, 2, 2, 2, 2, 2, 1))) -Runs @() -HourLandings @{}
    T ($kMF + '  AT the B6(b) bar 18 leg sets over 10 quiet changes (1.8) passes, and a step PAST it, 19, fails') `
      ($leg18.Strata['quiet'].LegSets -eq 18 -and $leg18.Strata['quiet'].BVerdict -eq 'pass' -and $leg19.Strata['quiet'].LegSets -eq 19 -and $leg19.Strata['quiet'].BVerdict -eq 'fail') `
      ("18: {0} {1}; 19: {2} {3}" -f $leg18.Strata['quiet'].LegSets, $leg18.Strata['quiet'].BVerdict, $leg19.Strata['quiet'].LegSets, $leg19.Strata['quiet'].BVerdict)
    $lgA = New-PpcAttRow 'legs' '2026-09-25T12:05:00Z' '2026-09-25T12:00:00.0000000Z' 'refused-gate-red' 'lsub' 'lc' '"rounds":2'
    $lgB = New-PpcAttRow 'legs' '2026-09-25T12:35:00Z' '2026-09-25T12:30:00.0000000Z' 'landed' 'lsub' 'lc'
    $gLgG = Group-TcPpcChanges -Rows @($lgA, $lgB); $gLg = @($gLgG)
    T ($kMF + '  a change with one push-main row missing rounds gets NO leg count, never the partial sum of the rows that carry it') `
      ($gLg.Count -eq 1 -and $null -eq $gLg[0].LegSets -and $gLg[0].RoundsRows -eq 1) ("legs={0} roundsRows={1}" -f $(if ($gLg.Count) { $gLg[0].LegSets }), $(if ($gLg.Count) { $gLg[0].RoundsRows }))
    $nb1 = Get-TcPpcNegBinCdf -Changes 1 -Attempts 2 -Q 0.4
    $nb2 = Get-TcPpcNegBinCdf -Changes 2 -Attempts 2 -Q 0.4
    T ($kCT + '  P(result | old rate): one change in at most 2 attempts at a 0.4 landing chance is 0.64, and two changes in exactly 2 attempts is 0.16') `
      ([math]::Abs($nb1 - 0.64) -lt 1e-12 -and [math]::Abs($nb2 - 0.16) -lt 1e-12) ("p1={0} p2={1}" -f $nb1, $nb2)

    # ---- -History: main-checkout pushes that passed the hook and were rejected, at the 15 s bar ----
    $mcPath = 'C:\ppc-fixture\ThriftyCrew'
    $mHeld = '{"ts":"2026-09-21T11:48:21Z","event":"hook-lock","state":"held","waitMs":0,"base":"b","grant":"g","checkout":"C:\\ppc-fixture\\ThriftyCrew"}' | ConvertFrom-Json
    $mWt = '{"ts":"2026-09-21T11:48:21Z","event":"hook-lock","state":"held","waitMs":0,"checkout":"C:\\wt\\other"}' | ConvertFrom-Json
    $mInh = '{"ts":"2026-09-21T11:48:21Z","event":"hook-lock","state":"inherited","waitMs":0,"checkout":"C:\\ppc-fixture\\ThriftyCrew"}' | ConvertFrom-Json
    $t15 = [pscustomobject]@{ Ts = (ConvertTo-TcPpcUtc '2026-09-21T11:48:36Z') }
    $t16 = [pscustomobject]@{ Ts = (ConvertTo-TcPpcUtc '2026-09-21T11:48:37Z') }
    $mr15 = Measure-TcPpcMainRejects -HookRows @($mHeld, $mWt, $mInh) -MainCheckout $mcPath -Updates @($t15)
    $mr16 = Measure-TcPpcMainRejects -HookRows @($mHeld, $mWt, $mInh) -MainCheckout $mcPath -Updates @($t16)
    T ($kMNF + '  AT the 15 s bar: a held main-checkout hook-lock row followed by an update 15 s later is FOLLOWED, and worktree and inherited rows are not counted') `
      ($mr15.Held -eq 1 -and $mr15.Followed -eq 1 -and @($mr15.NotFollowed).Count -eq 0) ("held={0} followed={1}" -f $mr15.Held, $mr15.Followed)
    T ($kMF + '  a step PAST the 15 s bar: an update 16 s later does not follow it, so the push is counted as rejected after every check passed') `
      ($mr16.Held -eq 1 -and $mr16.Followed -eq 0 -and @($mr16.NotFollowed).Count -eq 1) ("held={0} followed={1}" -f $mr16.Held, $mr16.Followed)

    # ---- -History: landings by route ----
    function New-PpcLand([string]$prev, [string]$ts) { return [pscustomobject]@{ Sha = ('n' + $prev); Prev = $prev; Ts = (ConvertTo-TcPpcUtc $ts); Kind = 'push'; Files = @('ops/a.ps1') } }
    $rtL = @((New-PpcLand 'p1' '2026-09-26T10:00:00Z'), (New-PpcLand 'p2' '2026-09-26T11:00:00Z'), (New-PpcLand 'p3' '2026-09-26T12:00:00Z'), (New-PpcLand 'p4' '2026-09-26T13:00:00Z'))
    $rtPm = '{"ts":"2026-09-26T10:01:00Z","event":"push-main","outcome":"landed","base":"p0","grant":"p1","checkout":"C:\\wt\\r1"}' | ConvertFrom-Json
    $rtHm = '{"ts":"2026-09-26T10:58:00Z","event":"hook-lock","state":"held","base":"p2","grant":"p2","checkout":"C:\\ppc-fixture\\ThriftyCrew"}' | ConvertFrom-Json
    $rtHw = '{"ts":"2026-09-26T11:59:30Z","event":"hook-lock","state":"held","base":"pz","grant":"p3","checkout":"C:\\wt\\r3"}' | ConvertFrom-Json
    $rt = Resolve-TcPpcLandingRoutes -Landings $rtL -PushMainRows @($rtPm) -HookRows @($rtHm, $rtHw) -MainCheckout $mcPath
    T ($kCT + '  each landing takes its road: a push-main row naming the sha main moved from, a main-checkout hook-lock row, a worktree one, and none') `
      ((Format-TcPpcRoutes $rt) -eq 'push-main 1, plain-worktree 1, plain-main 1, plain-unknown 0, no-ledger-row 1') ("routes={0}" -f (Format-TcPpcRoutes $rt))
    $rtX = @(New-PpcLand 'q1' '2026-09-27T10:00:00Z')
    $rtAt = '{"ts":"2026-09-27T10:15:00Z","event":"push-main","outcome":"landed","base":"q0","grant":"q1","checkout":"C:\\wt\\q"}' | ConvertFrom-Json
    $rtPast = '{"ts":"2026-09-27T10:15:01Z","event":"push-main","outcome":"landed","base":"q0","grant":"q1","checkout":"C:\\wt\\q"}' | ConvertFrom-Json
    $rAt = Resolve-TcPpcLandingRoutes -Landings $rtX -PushMainRows @($rtAt) -HookRows @() -MainCheckout $mcPath
    $rPast = Resolve-TcPpcLandingRoutes -Landings $rtX -PushMainRows @($rtPast) -HookRows @() -MainCheckout $mcPath
    T ($kMF + '  AT the 900 s route window a push-main row written 900 s after the landing is its road, and one 901 s after is not') `
      ($rAt[0].Route -eq 'push-main' -and $rPast[0].Route -eq 'no-ledger-row') ("at={0} past={1}" -f $rAt[0].Route, $rPast[0].Route)

    # ---- the older-copy count beside a bar is a share, and a plain -Cost prints the attempt and leg-set lines ----
    $shState = [pscustomobject]@{
      Id = 'B2b'; Def = [pscustomobject]@{ Items = @('W1.1'); Metric = 'm'; MinN = 'n'; Value = 'v' }; Landed = $true; Missing = @()
      Landing = [pscustomobject]@{ Sha = $c2; Ts = (ConvertTo-TcPpcUtc '2026-09-25T10:00:00Z') }; Readout = (ConvertTo-TcPpcUtc '2026-10-09T10:00:00Z'); Due = $false
      LandingBlob = $bB; AfterLanding = $after2
    }
    $shCtx = [pscustomobject]@{ StartUtc = (ConvertTo-TcPpcUtc '2026-09-25T00:00:00Z'); EndUtc = (ConvertTo-TcPpcUtc '2026-09-27T00:00:00Z'); RefName = 'fixture'; Index = $bix; Bars = @($shState); Bar = $null; Ancestry = @(); PlanLogOk = $true; PlanLogWhy = ''; PlanRecords = 1; PlanMalformed = 0 }
    $capSh = Invoke-TcPpcCaptured { Write-TcPpcCostBars -Rows @($rOld, $rNew) -Ctx $shCtx }
    T ($kCT + '  the older-copy count beside a bar is printed as a share of the rows it was taken from') ($capSh.Text -match 'older-copy rows excluded 1 of 2 \(50\.0%\)' -and -not $capSh.Error) ("error={0} had={1}" -f $capSh.Error, ($capSh.Text -match 'older-copy rows excluded 1 of 2'))
    T ($kCT + '  rows without rounds still print B6''s old line, labelled pre-W0.1, beside the attempt and leg-set lines a plain -Cost prints') `
      ($ct -match 'B6''s old line, pre-W0\.1 \(2 landed changes whose rows carry no rounds\)' -and $ct -match 'attempts per landed change, every attempt counted' -and $ct -match 'leg sets per landed change' -and $ct -match 'B6 \(amended, 15\.6\)') `
      ("old={0} attempts={1} legs={2}" -f ($ct -match 'B6''s old line, pre-W0\.1'), ($ct -match 'attempts per landed change'), ($ct -match 'leg sets per landed change'))
  } catch {
    $f++
    Write-Output ("FAIL  the suite threw, so the cases after this point did not run: " + $_.Exception.Message + ' at line ' + $_.InvocationInfo.ScriptLineNumber)
  } finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }
  if ($cases -ne $expectedCases) {
    $f++
    Write-Output ("FAIL  the suite ran {0} case(s) and lists {1}: a case was skipped or added without moving the count" -f $cases, $expectedCases)
  }
  if ($f) { Write-Output ("probe-push-convergence self-test FAIL: {0} of {1} check(s)" -f $f, $cases); exit 1 }
  Write-Output ("probe-push-convergence self-test PASS: {0} cases - led by a report whose every source is empty resolving NOTHING rather than printing a healthy box, a fetch entry never being counted as a landing, -Due exiting 2 for a bar past its read-out with no result line, W2.1 never matching W2.10, and three attempts of one lane under three change_ids counting as ONE change" -f $cases)
  exit 0
}

$modeN = @(@($Cost.IsPresent, $History.IsPresent, $Due.IsPresent) | Where-Object { $_ }).Count
if ($modeN -gt 1) {
  [Console]::Out.WriteLine('probe-push-convergence: COULD NOT EVALUATE - -Cost, -History and -Due are separate reports; pass one of them.')
  [Console]::Out.WriteLine('PUSH-CONVERGENCE-COMPLETE blind=modes')
  exit 3
}
if ($Cost -or $History -or $Due) {
  $atUtc = [datetime]::UtcNow
  if ($NowUtc) {
    $parsedNow = ConvertTo-TcPpcUtc $NowUtc
    if ($null -eq $parsedNow) {
      [Console]::Out.WriteLine(('probe-push-convergence: COULD NOT EVALUATE - -NowUtc ''{0}'' is not a time.' -f $NowUtc))
      [Console]::Out.WriteLine('PUSH-CONVERGENCE-COMPLETE blind=clock')
      exit 3
    }
    $atUtc = $parsedNow
  }
  if ($Due) {
    $rcDue = Invoke-TcPpcDue -Repo $repo -RefName $MainRef -PlanPath $PlanFile -LogPath $PlanLogFile -AtUtc $atUtc
    exit ([int]$rcDue)
  }
  $sandboxDir = $(if ($TempRoot) { $TempRoot } else { [IO.Path]::GetTempPath() })
  if ($History) {
    $rcHist = Invoke-TcPpcHistory -Repo $repo -RefName $MainRef -AtUtc $atUtc -Root $LedgerRoot -SandboxRoot $sandboxDir
    exit ([int]$rcHist)
  }
  $costDays = $(if ($PSBoundParameters.ContainsKey('Days')) { [math]::Max(1, $Days) } else { 7 })
  $rcCost = Invoke-TcPpcCost -Repo $repo -RefName $MainRef -Root $LedgerRoot -WindowDays $costDays -BarWanted $Bar -SandboxRoot $sandboxDir -LogPath $PlanLogFile -AtUtc $atUtc
  exit ([int]$rcCost)
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
