<#
  report-checkout-sync.ps1 - one committed harness for every bar of design\PLAN-bot-checkout-self-heal-2026-09-23.md
  section 8, with read-out dates. A REPORT, NEVER A GATE: a plain run exits 0 whatever the bars say.

  WHY (2026-09-23, plan item W1.2). The plan wrote its bars before any run, in their own units, so that nobody picks a
  threshold after seeing the number. A bar measured by a scratch probe has to be written again when its read-out comes
  round, and a rewritten probe is a second harness however faithful it is (measurement.md, "NAMING A SCRATCH HARNESS IS
  NOT NAMING A HARNESS"). This is the one harness, committed, and -Due turns a read-out date into an exit code instead
  of a reminder (memory an-intention-has-no-exit-code).

  SCOPE OF A CLEAN REPORT: UNSOUND. It counts only syncs that WROTE A LOG ROW, so a sync that died before its row is
    invisible to every row-based bar (B1a, B2, B4, B7, B8). B1b's denominator is therefore ARMED RUNS read from
    capture-run's own logs, never log rows: a run with no start-sync row reads as SILENT there rather than vanishing.
    B5 sees only what the sync itself detected, so a marker the sync missed is outside it. B6a reads W2.2's verdict
    line and counts a refusal without one as unmeasured, never as a pass. B9 reads the watchdog's own CHECKOUT-FLOOR
    line, so it checks that the floor fired whenever its own numbers said it should, and a run with no line is counted
    as unmeasured. A PASS is a statement about the rows and logs on this box and nothing else.

  INPUTS, all read, none written:
    <git common dir>\tc-checkout-sync-log.jsonl      one row per sync (lib\checkout-sync.ps1, W3.1): B1a B1b B2 B4 B5 B7 B8
    <git common dir>\tc-commit-carry.json            the carry ledger (grocery\commit-size-lib.ps1, W2.1): B6a's context
    grocery\out\logs\capture-run-{ad,daily}-*.log    run blocks, their args, Created autostash, the size gate, FAILED LANES
    grocery\out\logs\capture-watchdog-*.log          the CHECKOUT-FLOOR line capture-watchdog prints each run (B9)
    git, refs/remotes/origin/main                    the bot's [daily] commits (B6b) and each item's landing commit
    git, design/PLAN-bot-checkout-self-heal-2026-09-23.md at refs/remotes/origin/main, else at HEAD: section 13's
         result lines (-Due). Origin first, because a result line lands by push and the checkout may be behind.

  WHAT IT READS IN THE LOGS, so a writer that changes a line knows this reader exists:
    run block      '--- run-log: capture-run-<kind> | <iso> | pid <n> ---' to '--- run-log: finished <iso> rc=<n> ---'
                   (lib run-log-lib), with the transcript's 'Host Application:' line for its arguments. A block opened
                   inside another block is a CHILD (the re-exec handoff, W4.1) and is not counted as a run of its own.
    armed          no -WhatIf, -NoDownstream, -NoSync or -SelfTest in its arguments (an unreadable line counts as armed)
    B1b            a run's start-sync row is the phase=start row with its pid, stamped inside its window; a run with no
                   such row, or a non-ok row with no why or with paged=false, is SILENT
    B2             'handing off to' in the run that synced with startup_changed (W4.1 step 5)
    B3             'Created autostash' anywhere in a capture-run block
    B5             'launched <n> lane(s)', the line that says captures started
    B6a            'commit REFUSED: this run would ADD' (the gate's refusal, kept byte-exact by W2.2) and W2.2's verdict
                   'commit-size: own + unvouched ... : within caps|OVER caps'
    B6b            'FAILED LANES:' naming commit-size-gate or commit-refused, for the refused days
    B9             'CHECKOUT-FLOOR behind=<n> oldest_age_s=<n> bar_s=<n> stale=<0|1>' and 'FIND  BOT CHECKOUT STALE:'

  LANDING AND READ-OUT DATES ARE DERIVED FROM THE LANDING COMMIT, never typed as a hash. The plan says each bar's
    landing commit and read-out date are "filled by the landing commit of the item the bar judges". A commit cannot
    carry its own id, and ops\push-main.ps1 rebases before it pushes, so a hash written in the commit that lands would
    name nothing on main. So each row of the literal bars table holds its ITEM and its read-out interval, and the
    landing is the earliest commit on refs/remotes/origin/main whose message carries the line
    `Plan: design/PLAN-bot-checkout-self-heal-2026-09-23.md <item>`, which every commit of this plan carries (plan
    section 5). Only the id list right after the path counts (Get-CsPlanLineItems): prose after it, in a parenthesis or
    not, names no item, because 1d59fbfba's `W4.2 (... W4.1 owns it)` once landed W4.1 six hours early. The read-out is that commit's local date plus the interval. A row's `landing` and `readout` fields,
    empty today, pin either one when filled (yyyy-MM-dd). An item that has not landed has no read-out and is never due.

  Usage:
    powershell -File grocery\report-checkout-sync.ps1            print every bar; exit 0 (3 when the checkout cannot be read)
    powershell -File grocery\report-checkout-sync.ps1 -Due       exit 2 when any bar's read-out date has passed and
                                                                 section 13 of the committed plan has no 'B<n>:' line for
                                                                 it; exit 0 otherwise; 3 when the plan cannot be read
    powershell -File grocery\report-checkout-sync.ps1 -SelfTest  frozen JSONL rows and log snippets, plus -Due and a plain
                                                                 run against a temp repo
    -Repo <checkout>  -Today yyyy-MM-dd                          seams: which checkout, and which day is today
#>
# gate-inputs: grocery\report-checkout-sync.ps1, lib\git-blob-lib.ps1, lib\git-repo-env.ps1
param([switch]$SelfTest, [switch]$Due, [string]$Repo = '', [string]$Today = '')

$ErrorActionPreference = 'Stop'
$csHere = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path (Split-Path $csHere -Parent) 'lib\git-blob-lib.ps1')   # Invoke-GitCaptured: both streams kept, never a redirect

$script:CsPlanPath = 'design/PLAN-bot-checkout-self-heal-2026-09-23.md'
$script:CsInv = [Globalization.CultureInfo]::InvariantCulture

# ---- THE BARS, as written in the plan's section 8 before any run -------------------------------------------------------
# kind: 'deterministic' - any defect is FAIL at any N, and no defect below the minimum N is NO-VERDICT;
#       'rate' - no verdict below the minimum N, then the bar's own comparison.
# item: the item whose landing opens the bar's window (for a bar naming several, the one that makes it observable).
# landing / readout: '' = derived from origin/main (see the header); a yyyy-MM-dd pins it.
$script:CsBars = @(
  [pscustomobject]@{ id = 'B1a'; item = 'W4.1'; kind = 'deterministic'; min = 10; readout_days = 14; landing = ''; readout = ''
    metric = 'start syncs with outcome current or synced whose behind_after is not 0'; bar = '0 (deterministic: any such row is a defect)' }
  [pscustomobject]@{ id = 'B1b'; item = 'W4.1'; kind = 'rate'; min = 20; readout_days = 14; landing = ''; readout = ''
    metric = 'armed runs whose start sync ended current or synced, of all armed runs'; bar = 'at least 18 of 20 (90%), and 0 silent (every other run has an outcome, a why and a page)' }
  [pscustomobject]@{ id = 'B2'; item = 'W4.1'; kind = 'deterministic'; min = 10; readout_days = 14; landing = ''; readout = ''
    metric = 'runs whose start sync was current or synced and that executed without a fix origin already had'; bar = '0 (deterministic)' }
  [pscustomobject]@{ id = 'B3'; item = 'W4.2'; kind = 'deterministic'; min = 14; readout_days = 14; landing = ''; readout = ''
    metric = 'Created autostash lines in capture-run logs'; bar = '0' }
  [pscustomobject]@{ id = 'B4'; item = 'W4.1'; kind = 'deterministic'; min = 10; readout_days = 14; landing = ''; readout = ''
    metric = 'dirty paths outside the write set whose fingerprint changed across a sync, summed over syncs that moved HEAD'; bar = '0 paths (deterministic)' }
  [pscustomobject]@{ id = 'B5'; item = 'W4.1'; kind = 'deterministic'; min = 20; readout_days = 14; landing = ''; readout = ''
    metric = 'armed runs whose captures started with unmerged entries or new marker triples in a dirty tracked file'; bar = '0 (deterministic); blocked-checkout exits reported beside it' }
  [pscustomobject]@{ id = 'B6a'; item = 'W2.2'; kind = 'deterministic'; min = 1; readout_days = 14; landing = ''; readout = ''
    metric = 'size-gate refusals where own plus unvouched were within 300 files / 25.0 MB and every carried record was within-caps'; bar = '0 (deterministic), over every refusal' }
  [pscustomobject]@{ id = 'B6b'; item = 'W2.2'; kind = 'rate'; min = 1; readout_days = 30; landing = ''; readout = ''
    metric = 'longest run of consecutive calendar days with no bot [daily] commit on origin/main, within 30 days of W2.2 landing'; bar = 'at most 1; no verdict if no refused day occurs in those 30 days' }
  [pscustomobject]@{ id = 'B7'; item = 'W4.1'; kind = 'rate'; min = 20; readout_days = 14; landing = ''; readout = ''
    metric = 'start-sync seconds (sec), a live report'; bar = 'median at most 30 s and p90 at most 120 s' }
  [pscustomobject]@{ id = 'B8'; item = 'W3.1'; kind = 'deterministic'; min = 3; readout_days = 14; landing = ''; readout = ''
    metric = 'syncs whose read-tree hit unable to unlink, ending verified (synced, or blocked class held-file), of all such syncs'; bar = 'all of them, and 0 mixed-tree outcomes (deterministic); reported at any N, judged at 3' }
  [pscustomobject]@{ id = 'B9'; item = 'W1.1'; kind = 'deterministic'; min = 1; readout_days = 14; landing = ''; readout = ''
    metric = 'watchdog runs where check 7''s own numbers held (oldest missing commit past 93,600 s) and no BOT CHECKOUT STALE finding was raised'; bar = '0 (deterministic)' }
)

# ---- small readers -----------------------------------------------------------------------------------------------------
function Get-CsField($Obj, [string]$Name) {
  # A presence question is asked of PSObject.Properties; an absent field and a null one both answer $null here.
  if ($null -eq $Obj) { return $null }
  $p = $Obj.PSObject.Properties[$Name]
  if ($p) { return $p.Value }
  return $null
}
function Get-CsDate([string]$Text) {
  # An ISO timestamp as a LOCAL datetime, or $null. The logs and rows are written on this box in local time.
  if (-not $Text) { return $null }
  $o = [DateTimeOffset]::MinValue
  if ([DateTimeOffset]::TryParse($Text, $script:CsInv, [Globalization.DateTimeStyles]::AssumeLocal, [ref]$o)) { return $o.LocalDateTime }
  return $null
}
function Test-CsOkOutcome([string]$Outcome) { return (@('current', 'synced') -contains $Outcome) }

function ConvertFrom-CsSyncLog {
  <# The sync log's JSONL lines as typed rows. A line that does not parse is counted, never guessed at. #>
  param([string[]]$Lines)
  $rows = [System.Collections.Generic.List[object]]::new()
  $bad = 0
  foreach ($ln in @($Lines)) {
    if (-not ([string]$ln).Trim()) { continue }
    $o = $null
    try { $o = ([string]$ln) | ConvertFrom-Json } catch { $bad++; continue }
    if ($null -eq $o) { $bad++; continue }
    $ba = Get-CsField $o 'behind_after'
    $baN = $null; if ($null -ne $ba -and [string]$ba -match '^-?\d+$') { $baN = [int]$ba }
    $sec = Get-CsField $o 'sec'
    $secN = $null; $secD = 0.0
    if ($null -ne $sec -and [double]::TryParse([string]$sec, [Globalization.NumberStyles]::Float, $script:CsInv, [ref]$secD)) { $secN = $secD }
    $fp = Get-CsField $o 'fingerprint_changed'
    $fpN = $null; if ($null -ne $fp -and [string]$fp -match '^\d+$') { $fpN = [int]$fp }
    $held = Get-CsField $o 'held'
    $heldOn = $false
    if ($null -ne $held) { if ($held -is [array]) { $heldOn = (@($held | Where-Object { $_ }).Count -gt 0) } else { $heldOn = [bool]([string]$held).Trim() -and ([string]$held -ne 'False') -and ([string]$held -ne '0') } }
    $sc = Get-CsField $o 'startup_changed'
    $scB = $null; if ($null -ne $sc) { $scB = ([string]$sc -eq 'True') }
    $pg = Get-CsField $o 'paged'
    $pgB = $null; if ($null -ne $pg) { $pgB = ([string]$pg -eq 'True') }
    $rows.Add([pscustomobject]@{
      ts = (Get-CsDate ([string](Get-CsField $o 'ts'))); pid = [string](Get-CsField $o 'pid'); phase = [string](Get-CsField $o 'phase')
      outcome = [string](Get-CsField $o 'outcome'); class = [string](Get-CsField $o 'class'); why = [string](Get-CsField $o 'why')
      H0 = [string](Get-CsField $o 'H0'); NEW = [string](Get-CsField $o 'NEW'); behind_after = $baN; sec = $secN
      fingerprint_changed = $fpN; held = $heldOn; startup_changed = $scB; paged = $pgB })
  }
  return [pscustomobject]@{ rows = $rows.ToArray(); unreadable = $bad }
}

function ConvertFrom-CsRunLog {
  <# One log file's text as run blocks (see the header for the lines it reads). -Name is the run-log name stem:
     'capture-run' matches capture-run-ad and capture-run-daily, 'capture-watchdog' matches only the 10:30 run (the
     -SlotClose run logs as capture-watchdog-slotclose and is not one). Blocks nest: a banner inside an open block is a
     child, and every line goes to the innermost open block. #>
  param([string[]]$Lines, [string]$Name, [string]$File = '')
  $bannerRx = if ($Name -eq 'capture-watchdog') { '^--- run-log: (capture-watchdog) \| (\S+) \| pid (\d+) ---\s*$' } else { '^--- run-log: capture-run-(ad|daily) \| (\S+) \| pid (\d+) ---\s*$' }
  $out = [System.Collections.Generic.List[object]]::new()
  $stack = [System.Collections.Generic.List[object]]::new()
  $host1 = $null
  foreach ($ln in @($Lines)) {
    $s = [string]$ln
    if ($s -match '^Windows PowerShell transcript start') { $host1 = $null }
    if ($s -match '^Host Application:\s*(.*)$') { $host1 = $Matches[1] }
    $bm = [regex]::Match($s, $bannerRx)
    if ($bm.Success) {
      $argsTxt = $host1
      $armed = $true
      if ($null -ne $argsTxt -and $argsTxt -match '(?i)(^|\s)-(WhatIf|NoDownstream|NoSync|SelfTest)\b') { $armed = $false }
      $b = [pscustomobject]@{ kind = $bm.Groups[1].Value; start = (Get-CsDate $bm.Groups[2].Value); pid = $bm.Groups[3].Value
        args = $argsTxt; armed = $armed; child = ($stack.Count -gt 0); finish = $null; rc = $null; file = $File
        lines = [System.Collections.Generic.List[string]]::new() }
      $out.Add($b); $stack.Add($b); $host1 = $null
      continue
    }
    $fm = [regex]::Match($s, '^--- run-log: finished (\S+) rc=(-?\d+) ---\s*$')
    if ($fm.Success -and $stack.Count) {
      $top = $stack[$stack.Count - 1]
      $top.finish = Get-CsDate $fm.Groups[1].Value; $top.rc = [int]$fm.Groups[2].Value
      $stack.RemoveAt($stack.Count - 1)
      continue
    }
    if ($stack.Count) { $stack[$stack.Count - 1].lines.Add($s) }
  }
  return , $out.ToArray()   # comma: an empty or one-block file still arrives as an array, never $null or a bare object
}

function Find-CsStartRow {
  <# The start-sync row a run wrote: phase start, the run's pid, stamped inside the run's window. $null when none. #>
  param($Run, $Rows)
  $lo = $Run.start.AddMinutes(-5)
  $hi = if ($Run.finish) { $Run.finish.AddMinutes(5) } else { $Run.start.AddDays(1) }
  foreach ($r in @($Rows)) {
    if ($r.phase -ne 'start' -or -not [string]::Equals($r.pid, $Run.pid, [StringComparison]::Ordinal)) { continue }
    if ($null -eq $r.ts -or $r.ts -lt $lo -or $r.ts -gt $hi) { continue }
    return $r
  }
  return $null
}
function Test-CsLine($Run, [string]$Pattern) {
  foreach ($l in $Run.lines) { if ($l -match $Pattern) { return $true } }
  return $false
}
function Get-CsArmedRuns($Runs, $Since) {
  # Returned with a comma, so ONE run is still an array: under PS 5.1 a lone [pscustomobject] has no .Count at all,
  # and a window holding exactly one armed run read as N=0 (caught by this file's own B3 case).
  if ($null -eq $Since) { return , @() }
  return , @(@($Runs) | Where-Object { $_.armed -and -not $_.child -and $null -ne $_.start -and $_.start -ge $Since })
}
function Get-CsDeterministicVerdict([int]$Defects, [int]$N, [int]$Min) {
  if ($Defects -gt 0) { return 'FAIL' }
  if ($N -lt $Min) { return 'NO-VERDICT (N below minimum)' }
  return 'PASS'
}
function New-CsMeasure([int]$N, [int]$Defects, [int]$Unmeasured, [string]$Verdict, [string]$Detail) {
  return [pscustomobject]@{ n = $N; defects = $Defects; unmeasured = $Unmeasured; verdict = $Verdict; detail = $Detail }
}

# ---- ONE PURE FUNCTION PER BAR ------------------------------------------------------------------------------------------
# Each takes the parsed inputs and the time its window opens ($null = the item has not landed, so N is 0).
function Measure-CsB1a { param($Rows, $Since, [int]$Min = 10)
  $pop = @(); if ($null -ne $Since) { $pop = @(@($Rows) | Where-Object { $_.phase -eq 'start' -and (Test-CsOkOutcome $_.outcome) -and $null -ne $_.ts -and $_.ts -ge $Since }) }
  $def = @($pop | Where-Object { $null -ne $_.behind_after -and $_.behind_after -ne 0 }).Count
  $un = @($pop | Where-Object { $null -eq $_.behind_after }).Count
  return (New-CsMeasure $pop.Count $def $un (Get-CsDeterministicVerdict $def $pop.Count $Min) ('rows with no behind_after: ' + $un))
}
function Measure-CsB1b { param($Runs, $Rows, $Since, [int]$Min = 20)
  $armedRuns = Get-CsArmedRuns $Runs $Since
  $okN = 0; $silent = 0; $noRow = 0
  foreach ($r in $armedRuns) {
    $row = Find-CsStartRow $r $Rows
    if ($null -eq $row) { $noRow++; $silent++; continue }
    if (Test-CsOkOutcome $row.outcome) { $okN++; continue }
    if (-not $row.why.Trim() -or ($null -ne $row.paged -and -not $row.paged)) { $silent++ }
  }
  $n = @($armedRuns).Count
  $v = if ($silent -gt 0) { 'FAIL' } elseif ($n -lt $Min) { 'NO-VERDICT (N below minimum)' } elseif (($okN * 10) -ge ($n * 9)) { 'PASS' } else { 'FAIL' }
  return (New-CsMeasure $n $silent $noRow $v ('current or synced: ' + $okN + ' of ' + $n + '; silent: ' + $silent + ' (' + $noRow + ' with no start-sync row)'))
}
function Measure-CsB2 { param($Runs, $Rows, $Since, [int]$Min = 10)
  $pop = @(); if ($null -ne $Since) { $pop = @(@($Rows) | Where-Object { $_.phase -eq 'start' -and (Test-CsOkOutcome $_.outcome) -and $null -ne $_.ts -and $_.ts -ge $Since }) }
  $def = 0; $un = 0
  foreach ($row in $pop) {
    if ($null -ne $row.behind_after -and $row.behind_after -gt 0) { $def++; continue }
    if ($row.startup_changed -eq $true) {
      $run = $null
      foreach ($r in @($Runs)) { if ([string]::Equals($r.pid, $row.pid, [StringComparison]::Ordinal) -and -not $r.child) { $run = $r; break } }
      if ($null -eq $run) { $un++; continue }
      if (-not (Test-CsLine $run 'handing off to ')) { $def++ }
    }
  }
  return (New-CsMeasure $pop.Count $def $un (Get-CsDeterministicVerdict $def $pop.Count $Min) ('startup changed with no run log to check the handoff: ' + $un))
}
function Measure-CsB3 { param($Runs, $Since, [int]$Min = 14)
  $n = (Get-CsArmedRuns $Runs $Since).Count
  $lines = 0
  if ($null -ne $Since) {
    foreach ($r in @($Runs)) {
      if ($null -eq $r.start -or $r.start -lt $Since) { continue }
      foreach ($l in $r.lines) { if ($l -match 'Created autostash') { $lines++ } }
    }
  }
  return (New-CsMeasure $n $lines 0 (Get-CsDeterministicVerdict $lines $n $Min) ('Created autostash lines: ' + $lines))
}
function Measure-CsB4 { param($Rows, $Since, [int]$Min = 10)
  $pop = @(); if ($null -ne $Since) { $pop = @(@($Rows) | Where-Object { $_.H0 -and $_.NEW -and -not [string]::Equals($_.H0, $_.NEW, [StringComparison]::Ordinal) -and $null -ne $_.ts -and $_.ts -ge $Since }) }
  $def = 0; $un = 0
  foreach ($r in $pop) {
    if ($null -ne $r.fingerprint_changed) { $def += $r.fingerprint_changed; continue }
    if ($r.outcome -eq 'failed' -and (($r.class + ' ' + $r.why) -match '(?i)fingerprint')) { $def++; continue }
    $un++
  }
  return (New-CsMeasure $pop.Count $def $un (Get-CsDeterministicVerdict $def $pop.Count $Min) ('moving syncs with no fingerprint_changed count, judged by the step 10 verdict alone: ' + $un))
}
function Measure-CsB5 { param($Runs, $Rows, $Since, [int]$Min = 20)
  $armedRuns = Get-CsArmedRuns $Runs $Since
  $def = 0; $blocked = 0
  foreach ($r in $armedRuns) {
    $row = Find-CsStartRow $r $Rows
    if ($null -eq $row -or @('conflict', 'mixed-tree') -notcontains $row.class) { continue }
    $blocked++
    if (Test-CsLine $r '^\s*launched \d+ lane\(s\)') { $def++ }
  }
  return (New-CsMeasure @($armedRuns).Count $def 0 (Get-CsDeterministicVerdict $def @($armedRuns).Count $Min) ('blocked-checkout exits (conflict or mixed-tree at start, no lane launched): ' + ($blocked - $def)))
}
function Measure-CsB6a { param($Runs, $Since, [int]$Min = 1, [string]$Context = '')
  $n = 0; $def = 0; $un = 0; $over = 0
  if ($null -ne $Since) {
    foreach ($r in @($Runs)) {
      if ($null -eq $r.start -or $r.start -lt $Since) { continue }
      if (-not (Test-CsLine $r 'commit REFUSED: this run would ADD')) { continue }
      $n++
      $within = Test-CsLine $r '^\s*commit-size: own \+ unvouched .*: within caps\s*$'
      $overL = Test-CsLine $r '^\s*commit-size: own \+ unvouched .*: OVER caps\s*$'
      if ($within) { $def++ } elseif ($overL) { $over++ } else { $un++ }
    }
  }
  $v = if ($def -gt 0) { 'FAIL' } elseif ($n -lt $Min) { 'NO-VERDICT (N below minimum)' } elseif ($un -gt 0) { 'NO-VERDICT (a refusal carries no verdict line)' } else { 'PASS' }
  return (New-CsMeasure $n $def $un $v ('refusals over caps: ' + $over + '; refusals with no verdict line: ' + $un + $(if ($Context) { '; ' + $Context } else { '' })))
}
function Measure-CsB6b { param([string[]]$DailyDates, [string[]]$RefusedDates, $Since, [datetime]$TodayDate, [int]$Min = 1, [int]$WindowDays = 30)
  if ($null -eq $Since) { return (New-CsMeasure 0 0 0 'NO-VERDICT (N below minimum)' 'window not open') }
  $d0 = $Since.Date
  $d1 = $d0.AddDays($WindowDays - 1)
  if ($d1 -ge $TodayDate.Date) { $d1 = $TodayDate.Date.AddDays(-1) }
  $daily = @{}; foreach ($d in @($DailyDates)) { if ($d) { $daily[[string]$d] = $true } }
  $refused = @{}; foreach ($d in @($RefusedDates)) { if ($d) { $refused[[string]$d] = $true } }
  $longest = 0; $cur = 0; $refN = 0; $days = 0
  for ($d = $d0; $d -le $d1; $d = $d.AddDays(1)) {
    $days++
    $k = $d.ToString('yyyy-MM-dd')
    if ($refused.ContainsKey($k)) { $refN++ }
    if ($daily.ContainsKey($k)) { $cur = 0 } else { $cur++; if ($cur -gt $longest) { $longest = $cur } }
  }
  $v = if ($refN -lt $Min) { 'NO-VERDICT (N below minimum)' } elseif ($longest -le 1) { 'PASS' } else { 'FAIL' }
  return (New-CsMeasure $refN $(if ($longest -gt 1) { 1 } else { 0 }) 0 $v ('longest run of days with no [daily] commit: ' + $longest + ' over ' + $days + ' complete day(s); refused days: ' + $refN))
}
function Measure-CsB7 { param($Rows, $Since, [int]$Min = 20)
  $s = @(); if ($null -ne $Since) { $s = @(@($Rows) | Where-Object { $_.phase -eq 'start' -and $null -ne $_.sec -and $null -ne $_.ts -and $_.ts -ge $Since } | ForEach-Object { [double]$_.sec }) }
  $n = $s.Count
  if ($n -lt $Min) { return (New-CsMeasure $n 0 0 'NO-VERDICT (N below minimum)' ('start syncs with sec: ' + $n)) }
  [double[]]$a = $s; [Array]::Sort($a)
  $med = if ($n % 2) { $a[($n - 1) / 2] } else { ($a[$n / 2 - 1] + $a[$n / 2]) / 2.0 }
  $p90 = $a[[int][math]::Ceiling(0.9 * $n) - 1]
  $v = if ($med -le 30 -and $p90 -le 120) { 'PASS' } else { 'FAIL' }
  return (New-CsMeasure $n 0 0 $v ('median ' + $med.ToString($script:CsInv) + ' s, p90 ' + $p90.ToString($script:CsInv) + ' s (nearest rank)'))
}
function Measure-CsB8 { param($Rows, $Since, [int]$Min = 3)
  $pop = @(); $mixed = 0
  if ($null -ne $Since) {
    $inWin = @(@($Rows) | Where-Object { $null -ne $_.ts -and $_.ts -ge $Since })
    $pop = @($inWin | Where-Object { $_.held })
    $mixed = @($inWin | Where-Object { $_.class -eq 'mixed-tree' }).Count
  }
  $ver = @($pop | Where-Object { $_.outcome -eq 'synced' -or ($_.outcome -eq 'blocked' -and $_.class -eq 'held-file') }).Count
  $unver = $pop.Count - $ver
  $def = $unver + $mixed
  return (New-CsMeasure $pop.Count $def 0 (Get-CsDeterministicVerdict $def $pop.Count $Min) ('held syncs verified: ' + $ver + ' of ' + $pop.Count + '; mixed-tree outcomes: ' + $mixed))
}
function Measure-CsB9 { param($WdRuns, $Since, [int]$Min = 1)
  $n = 0; $def = 0; $un = 0
  if ($null -ne $Since) {
    foreach ($r in @($WdRuns)) {
      if ($null -eq $r.start -or $r.start -lt $Since -or $r.child) { continue }
      $mk = $null
      foreach ($l in $r.lines) { $m = [regex]::Match($l, 'CHECKOUT-FLOOR behind=(-?\d+) oldest_age_s=(-?\d+) bar_s=(\d+) stale=([01])'); if ($m.Success) { $mk = $m } }
      if ($null -eq $mk) { $un++; continue }
      $n++
      $held = ([long]$mk.Groups[1].Value -gt 0) -and ([long]$mk.Groups[2].Value -gt [long]$mk.Groups[3].Value)
      $raised = Test-CsLine $r '^\s*FIND\s+BOT CHECKOUT STALE:'
      if (($held -or $mk.Groups[4].Value -eq '1') -and -not $raised) { $def++ }
    }
  }
  return (New-CsMeasure $n $def $un (Get-CsDeterministicVerdict $def $n $Min) ('watchdog runs with no CHECKOUT-FLOOR line: ' + $un))
}

# ---- LANDINGS, READ-OUTS AND SECTION 13 ---------------------------------------------------------------------------------
function Get-CsPlanLineItems {
  <# The item ids a commit message LANDS for this plan, in order. Only a `Plan: <this plan's path> <ids>` line counts,
     and only the ID LIST that follows the path: the text is cut at the first `(`, the first `:` and the first `.` that
     ends a word (a full stop, never the dot inside W4.1), split into segments on `,`, `;` and a spaced `and`, and each
     segment's FIRST word, with a trailing `)` trimmed, is an id only when it is a whole W<n>.<n> token (so W2.1 is never
     read out of W2.10). The first segment that does not open with an id ends the list, so prose after the ids names
     nothing. Founding case (2026-09-23): 1d59fbfba's line is `... W4.2 (complements it: ... no start sync here, W4.1
     owns it)`, and reading every token anywhere on the line landed W4.1 six hours before it reached origin/main. Second
     case (2026-09-24): a colon or full stop was only TRIMMED off the id, so `W4.2: ..., W4.1 owns it` landed W4.1; it
     now ends the list wherever it falls, on the id or on a word after it (`W4.1 step 7: ..., W4.2 owns it`).
     `W4.1 step 7, W4.2` still reads both ids; `(this commit adds it)` and another plan's line read none.
     ops\probe-push-convergence.ps1's Get-TcPpcPlanLineItems applies this grammar to its own plan (2026-09-24)
     and is deliberately NOT shared: that plan writes a replacement beside its original, space-separated and suffixed
     (`W2.1R W2.1 W8.1`, `W3.2 W3.4a`), so it takes a segment's leading RUN of ids, which this plan never writes (its
     27 landing commits on origin/main at 2026-09-24 separate ids with commas and mint no suffixed id). That reader ends
     the list only at an id written with a trailing `.` or `:`, so a colon on a later word does not stop it. #>
  param([string]$Message)
  $ids = [Collections.Generic.List[string]]::new()
  $lineRx = '(?m)^[ \t]*Plan:[ \t]*' + [regex]::Escape($script:CsPlanPath) + '(?:[ \t]+([^\r\n]*?))?[ \t]*\r?$'
  foreach ($m in [regex]::Matches([string]$Message, $lineRx)) {
    $rest = $m.Groups[1].Value
    $stop = [regex]::Match($rest, '[(:]|\.(?=\s|$)')
    if ($stop.Success) { $rest = $rest.Substring(0, $stop.Index) }
    foreach ($seg in ($rest -split '\s*[,;]\s*|\s+and\s+')) {
      $s = $seg.Trim()
      if (-not $s) { continue }
      $first = ($s -split '\s+')[0].TrimEnd(')')
      if ($first -cnotmatch '^W\d+\.\d+$') { break }
      if (-not $ids.Contains($first)) { $ids.Add($first) }
    }
  }
  return ,$ids.ToArray()
}
function Get-CsLandings {
  <# item -> @{ sha; at } for the EARLIEST commit on refs/remotes/origin/main whose message has the plan's `Plan:` line
     naming the item. Returns @{ map; note }. #>
  param([string]$Repo)
  $map = @{}
  $r = Invoke-GitCaptured -Repo $Repo -GitArgs @('log', 'refs/remotes/origin/main', '--fixed-strings', ('--grep=Plan: ' + $script:CsPlanPath), '--format=%H%x1f%ct%x1f%B%x1e')
  if ($r.rc -ne 0) { return [pscustomobject]@{ map = $map; note = ('git log refs/remotes/origin/main exited ' + $r.rc + ': no item reads as landed') } }
  foreach ($rec in (([string]$r.stdout) -split [char]0x1e)) {
    $p = $rec.Trim() -split [char]0x1f
    if ($p.Count -lt 3) { continue }
    [long]$ct = 0
    if (-not [long]::TryParse($p[1].Trim(), [ref]$ct)) { continue }
    $items = Get-CsPlanLineItems $p[2]
    foreach ($k in $items) {
      $at = [DateTimeOffset]::FromUnixTimeSeconds($ct).LocalDateTime
      if (-not $map.ContainsKey($k) -or $at -lt $map[$k].at) { $map[$k] = [pscustomobject]@{ sha = $p[0].Trim(); at = $at } }
    }
  }
  return [pscustomobject]@{ map = $map; note = '' }
}
function Get-CsSchedule {
  <# One bar's window and read-out: its landing (pinned or derived), the time its window opens, and its read-out date. #>
  param($Bar, $Landings)
  $landAt = $null; $landTxt = ''
  if ($Bar.landing) {
    $landAt = [datetime]::ParseExact($Bar.landing, 'yyyy-MM-dd', $script:CsInv); $landTxt = $Bar.landing + ' (pinned in the bars table)'
  } elseif ($Landings.ContainsKey($Bar.item)) {
    $landAt = $Landings[$Bar.item].at; $landTxt = ($Landings[$Bar.item].sha.Substring(0, 9) + ' at ' + $landAt.ToString('yyyy-MM-dd HH:mm'))
  }
  $ro = $null
  if ($Bar.readout) { $ro = [datetime]::ParseExact($Bar.readout, 'yyyy-MM-dd', $script:CsInv) }
  elseif ($null -ne $landAt) { $ro = $landAt.Date.AddDays([int]$Bar.readout_days) }
  return [pscustomobject]@{ since = $landAt; landing = $landTxt; readout = $ro }
}
function Get-CsResultIds {
  <# The bar ids with a result line in section 13 of the plan text: from its '## 13.' heading to the next '## ' heading,
     a line 'B<n>: <something>'. A line anywhere else in the plan does not count. #>
  param([string]$PlanText)
  $ids = @{}
  $m = [regex]::Match([string]$PlanText, '(?ms)^## 13\..*?(?=^## |\z)')
  if (-not $m.Success) { return $ids }
  foreach ($x in [regex]::Matches($m.Value, '(?m)^[ \t>*\-]*(B\d+[a-z]?):[ \t]*\S')) { $ids[$x.Groups[1].Value] = $true }
  return $ids
}
function Get-CsDueBars {
  <# The bars whose read-out date has PASSED (strictly before -TodayDate) and that section 13 does not answer. #>
  param($Bars, $Schedules, [hashtable]$ResultIds, [datetime]$TodayDate)
  $due = @()
  foreach ($b in @($Bars)) {
    $s = $Schedules[$b.id]
    if ($null -eq $s -or $null -eq $s.readout) { continue }
    if ($s.readout -lt $TodayDate.Date -and -not $ResultIds.ContainsKey($b.id)) { $due += $b.id }
  }
  return , $due
}

# ---- THE REPORT ---------------------------------------------------------------------------------------------------------
function Invoke-CsReport {
  <# The whole run over one checkout. Returns @{ rc; lines }. -DueMode adds the section 13 check and its exit code. #>
  param([string]$RepoRoot, [datetime]$TodayDate, [switch]$DueMode)
  $L = [System.Collections.Generic.List[string]]::new()
  $cdR = Invoke-GitCaptured -Repo $RepoRoot -GitArgs @('rev-parse', '--path-format=absolute', '--git-common-dir')
  $cd = if ($cdR.rc -eq 0) { (([string]$cdR.stdout).Trim() -replace '/', '\') } else { '' }
  if (-not $cd) {
    $L.Add('report-checkout-sync: BLIND - git could not name the common dir of ' + $RepoRoot + ' (rev-parse exited ' + $cdR.rc + ')')
    $L.Add('REPORT-CHECKOUT-SYNC-COMPLETE bars=0 pass=0 fail=0 no_verdict=0 due=0 blind=1')
    return [pscustomobject]@{ rc = 3; lines = $L.ToArray() }
  }
  # rows
  $logF = Join-Path $cd 'tc-checkout-sync-log.jsonl'
  $rowsP = [pscustomobject]@{ rows = @(); unreadable = 0 }
  if (Test-Path -LiteralPath $logF) { $rowsP = ConvertFrom-CsSyncLog -Lines ([IO.File]::ReadAllLines($logF, [Text.Encoding]::UTF8)) }
  $rows = @($rowsP.rows)
  # the carry ledger, context for B6a
  $carryF = Join-Path $cd 'tc-commit-carry.json'
  $carryTxt = 'carry ledger absent'
  if (Test-Path -LiteralPath $carryF) {
    try {
      $cj = ConvertFrom-Json ([IO.File]::ReadAllText($carryF, [Text.Encoding]::UTF8))
      $cjRuns = Get-CsField $cj 'runs'
      $cjN = if ($null -eq $cjRuns) { 0 } else { @($cjRuns).Count }   # an absent field is 0 records, never @($null).Count
      $carryTxt = ('carry ledger holds ' + $cjN + ' record(s) now')
    }
    catch { $carryTxt = ('carry ledger unreadable (' + $_.Exception.Message + ')') }
  }
  # logs
  $logDir = Join-Path $RepoRoot 'grocery\out\logs'
  $runs = @(); $wdRuns = @(); $refusedDays = @()
  if (Test-Path -LiteralPath $logDir) {
    foreach ($f in @(Get-ChildItem -LiteralPath $logDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^capture-run-(ad|daily)-\d{4}-\d{2}-\d{2}\.log$' } | Sort-Object Name)) {
      $blocks = ConvertFrom-CsRunLog -Lines ([IO.File]::ReadAllLines($f.FullName, [Text.Encoding]::UTF8)) -Name 'capture-run' -File $f.Name
      $runs += @($blocks)
      $fd = [regex]::Match($f.Name, '(\d{4}-\d{2}-\d{2})').Groups[1].Value
      foreach ($b in @($blocks)) { if (Test-CsLine $b '^FAILED LANES:.*\b(commit-size-gate|commit-refused)\b') { $refusedDays += $fd } }
    }
    foreach ($f in @(Get-ChildItem -LiteralPath $logDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^capture-watchdog-\d{4}-\d{2}-\d{2}\.log$' } | Sort-Object Name)) {
      # Assigned first, then wrapped: @( ) around the call itself would read its comma-returned array as ONE element.
      $wdBlocks = ConvertFrom-CsRunLog -Lines ([IO.File]::ReadAllLines($f.FullName, [Text.Encoding]::UTF8)) -Name 'capture-watchdog' -File $f.Name
      $wdRuns += @($wdBlocks)
    }
  }
  # the bot's [daily] commits on origin/main, by author and subject stem
  $dailyDates = @()
  $dl = Invoke-GitCaptured -Repo $RepoRoot -GitArgs @('log', 'refs/remotes/origin/main', '--author=smp-pipeline-bot', '--fixed-strings', '--grep=Daily pipeline: refresh prices + feed (', '--format=%s')
  if ($dl.rc -eq 0) { foreach ($m in [regex]::Matches([string]$dl.stdout, '\((\d{4}-\d{2}-\d{2})\) \[daily\]')) { $dailyDates += $m.Groups[1].Value } }
  $land = Get-CsLandings -Repo $RepoRoot
  $L.Add('REPORT CHECKOUT SYNC - ' + $TodayDate.ToString('yyyy-MM-dd') + ' over ' + $RepoRoot)
  $L.Add(('  inputs: {0} sync row(s) ({1} unreadable) in {2}; {3} capture-run block(s), {4} watchdog block(s) under grocery\out\logs; {5} [daily] bot commit(s) on origin/main; {6}' -f $rows.Count, $rowsP.unreadable, $logF, $runs.Count, $wdRuns.Count, @($dailyDates).Count, $carryTxt))
  $L.Add('  landed items: ' + $(if ($land.map.Count) { (@($land.map.Keys | Sort-Object) | ForEach-Object { $_ + ' ' + $land.map[$_].sha.Substring(0, 9) }) -join ', ' } else { 'none on origin/main yet' }) + $(if ($land.note) { ' (' + $land.note + ')' } else { '' }))
  $sched = @{}
  $pass = 0; $fail = 0; $nov = 0
  foreach ($b in $script:CsBars) {
    $s = Get-CsSchedule $b $land.map
    $sched[$b.id] = $s
    $since = $s.since
    $mz = switch ($b.id) {
      'B1a' { Measure-CsB1a $rows $since $b.min }
      'B1b' { Measure-CsB1b $runs $rows $since $b.min }
      'B2'  { Measure-CsB2 $runs $rows $since $b.min }
      'B3'  { Measure-CsB3 $runs $since $b.min }
      'B4'  { Measure-CsB4 $rows $since $b.min }
      'B5'  { Measure-CsB5 $runs $rows $since $b.min }
      'B6a' { Measure-CsB6a $runs $since $b.min $carryTxt }
      'B6b' { Measure-CsB6b $dailyDates $refusedDays $since $TodayDate $b.min }
      'B7'  { Measure-CsB7 $rows $since $b.min }
      'B8'  { Measure-CsB8 $rows $since $b.min }
      'B9'  { Measure-CsB9 $wdRuns $since $b.min }
      default { throw ('unknown bar id in the bars table: ' + $b.id) }
    }
    if ($mz.verdict -eq 'PASS') { $pass++ } elseif ($mz.verdict -eq 'FAIL') { $fail++ } else { $nov++ }
    $win = if ($null -ne $since) { 'since ' + $b.item + ' landed ' + $s.landing } else { $b.item + ' has not landed on origin/main, so the window is not open' }
    $ro = if ($null -ne $s.readout) { $s.readout.ToString('yyyy-MM-dd') + ' (' + $b.readout_days + ' days after landing)' } else { 'not scheduled' }
    $L.Add('')
    $L.Add(('{0,-4} {1}' -f $b.id, $mz.verdict))
    $L.Add('     metric   ' + $b.metric)
    $L.Add(('     N        {0} (minimum {1})   defects {2}   {3}' -f $mz.n, $b.min, $mz.defects, $mz.detail))
    $L.Add('     stratum  ' + $win)
    $L.Add('     bar      ' + $b.bar)
    $L.Add('     read-out ' + $ro)
  }
  $rc = 0; $dueIds = @()
  if ($DueMode) {
    # The committed plan as ORIGIN holds it first, then HEAD: a result line lands by push, and the checkout this runs in
    # may be behind (on 2026-09-23 the main checkout's HEAD did not hold this plan at all, hours after it landed).
    $plRef = 'refs/remotes/origin/main'
    $pl = Invoke-GitCaptured -Repo $RepoRoot -GitArgs @('cat-file', 'blob', ($plRef + ':' + $script:CsPlanPath))
    if ($pl.rc -ne 0) { $plRef = 'HEAD'; $pl = Invoke-GitCaptured -Repo $RepoRoot -GitArgs @('cat-file', 'blob', ($plRef + ':' + $script:CsPlanPath)) }
    if ($pl.rc -ne 0) {
      $L.Add('')
      $L.Add('DUE: BLIND - ' + $script:CsPlanPath + ' could not be read at refs/remotes/origin/main or HEAD (cat-file exited ' + $pl.rc + '), so whether a read-out is owed is unknown')
      $rc = 3
    } else {
      $L.Add('')
      $L.Add('DUE: section 13 read from ' + $plRef + ':' + $script:CsPlanPath)
      $ids = Get-CsResultIds ([string]$pl.stdout)
      $dueIds = Get-CsDueBars $script:CsBars $sched $ids $TodayDate
      foreach ($d in @($dueIds)) { $L.Add(('DUE  {0}: its read-out date {1} has passed and section 13 of the committed plan has no ''{0}:'' result line. Add one: {0}: <result> (N=<n>, report blob <id>, window <from>..<to>).' -f $d, $sched[$d].readout.ToString('yyyy-MM-dd'))) }
      if (@($dueIds).Count) { $rc = 2 } else { $L.Add('DUE  none: no bar''s read-out date has passed without a section 13 result line') }
    }
  }
  $L.Add(('REPORT-CHECKOUT-SYNC-COMPLETE bars={0} pass={1} fail={2} no_verdict={3} due={4} blind=0' -f @($script:CsBars).Count, $pass, $fail, $nov, @($dueIds).Count))
  return [pscustomobject]@{ rc = $rc; lines = $L.ToArray() }
}

if ($SelfTest) {
  $script:csFail = 0; $script:csCases = 0
  function Test-CsCase([string]$Label, [string]$What, [bool]$Cond, [string]$Got = '') {
    $script:csCases++
    if ($Cond) { Write-Output ('ok    ' + $Label + '  ' + $What) }
    else { Write-Output ('FAIL  ' + $Label + '  ' + $What + '   got: ' + $Got); $script:csFail++ }
  }
  # A LITERAL-CASE SUITE ASSERTS HOW MANY RAN: every Test-CsCase call below is counted against this.
  $CS_SELFTEST_CASES = 48
  $csRoot = Join-Path $env:TEMP ('rcs-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
  $csPrevCd = $env:GIT_COMMITTER_DATE; $csPrevAd = $env:GIT_AUTHOR_DATE
  try {
    # ---- the bars table itself ----
    Test-CsCase 'CLEAN TWIN' 'the bars table holds the plan''s 11 bars, B1a to B9, each with an item, a minimum N and a read-out interval' ((@($script:CsBars).Count -eq 11) -and ((@($script:CsBars | ForEach-Object { $_.id }) -join ',') -eq 'B1a,B1b,B2,B3,B4,B5,B6a,B6b,B7,B8,B9') -and (@($script:CsBars | Where-Object { $_.item -and $_.min -ge 1 -and $_.readout_days -ge 1 }).Count -eq 11)) ((@($script:CsBars | ForEach-Object { $_.id }) -join ','))

    $since = [datetime]'2026-10-01 00:00'
    # ---- frozen sync rows ----
    $rowSyncedBehind = '{"ts":"2026-10-02T08:00:31","pid":4101,"kind":"daily","phase":"start","outcome":"synced","class":"","why":"","H0":"a1","NEW":"b1","behind":3,"behind_after":1,"sec":4}'
    $rowPartialPaged = '{"ts":"2026-10-02T08:00:31","pid":4102,"kind":"daily","phase":"start","outcome":"partial","class":"foreign","why":"notes.md is dirty on a path origin changed","paged":true,"H0":"a1","NEW":"b2","behind":3,"behind_after":2,"sec":5}'
    $rowSyncedClean = '{"ts":"2026-10-02T08:00:31","pid":4103,"kind":"daily","phase":"start","outcome":"synced","class":"","why":"","H0":"a1","NEW":"b3","behind":3,"behind_after":0,"sec":5}'
    $p1 = ConvertFrom-CsSyncLog -Lines @($rowSyncedBehind, 'not json at all', '')
    $m1 = Measure-CsB1a $p1.rows $since
    Test-CsCase 'MUST FIRE' 'B1a: a start sync with outcome synced whose behind_after is 1 is a defect and the bar FAILs, at any N' ($m1.defects -eq 1 -and $m1.verdict -eq 'FAIL') ("defects=$($m1.defects) verdict=$($m1.verdict)")
    Test-CsCase 'CLEAN TWIN' 'an unparseable sync-log line is counted as unreadable, never read as a row' ($p1.unreadable -eq 1 -and @($p1.rows).Count -eq 1) ("unreadable=$($p1.unreadable) rows=$(@($p1.rows).Count)")
    $m2 = Measure-CsB1a (ConvertFrom-CsSyncLog -Lines @($rowPartialPaged)).rows $since
    Test-CsCase 'MUST NOT FIRE' 'B1a: a partial row with a page is not a B1a defect (it is outside current and synced)' ($m2.defects -eq 0 -and $m2.n -eq 0 -and $m2.verdict -ne 'FAIL') ("defects=$($m2.defects) n=$($m2.n) verdict=$($m2.verdict)")
    $m3 = Measure-CsB1a (ConvertFrom-CsSyncLog -Lines @($rowSyncedClean)).rows $since
    Test-CsCase 'CLEAN TWIN' 'B1a: a synced row with behind_after 0 is counted in N and is no defect' ($m3.n -eq 1 -and $m3.defects -eq 0 -and $m3.verdict -eq 'NO-VERDICT (N below minimum)') ("n=$($m3.n) verdict=$($m3.verdict)")
    $m4 = Measure-CsB1a $p1.rows $null
    Test-CsCase 'MUST NOT FIRE' 'B1a: before the item lands the window is shut, so N is 0 and nothing is a defect' ($m4.n -eq 0 -and $m4.defects -eq 0) ("n=$($m4.n) defects=$($m4.defects)")

    # ---- B1b at the bar: 20 armed runs, parsed from a generated log, joined to their start rows by pid ----
    function New-CsRunText([int]$RunPid, [string]$At, [string]$ArgsTxt, [string[]]$Body) {
      $t = @('**********************', 'Windows PowerShell transcript start', ('Host Application: powershell.exe -NoProfile -File C:\x\grocery\capture-run.ps1 ' + $ArgsTxt), '**********************')
      $t += ('--- run-log: capture-run-daily | ' + $At + ' | pid ' + $RunPid + ' ---')
      $t += @($Body)
      $t += ('--- run-log: finished ' + $At.Substring(0, 11) + '09:30:00 rc=0 ---')
      return $t
    }
    $b1Log = @(); $b1Rows18 = @(); $b1Rows17 = @()
    for ($i = 1; $i -le 20; $i++) {
      $rp = 5000 + $i
      $at = ('2026-10-{0:00}T08:00:01' -f $i)
      $b1Log += (New-CsRunText $rp $at '-Kind daily' @('capture-run [daily]', 'launched 3 lane(s) concurrently; waiting up to 25 min'))
      $okRow = ('{"ts":"2026-10-' + ('{0:00}' -f $i) + 'T08:00:20","pid":' + $rp + ',"phase":"start","outcome":"current","why":"","behind_after":0,"sec":3}')
      $pRow = ('{"ts":"2026-10-' + ('{0:00}' -f $i) + 'T08:00:20","pid":' + $rp + ',"phase":"start","outcome":"partial","class":"foreign","why":"a session file","paged":true,"behind_after":1,"sec":3}')
      $b1Rows18 += $(if ($i -le 18) { $okRow } else { $pRow })
      $b1Rows17 += $(if ($i -le 17) { $okRow } else { $pRow })
    }
    $b1Runs = ConvertFrom-CsRunLog -Lines $b1Log -Name 'capture-run'
    $mb18 = Measure-CsB1b $b1Runs (ConvertFrom-CsSyncLog -Lines $b1Rows18).rows $since
    Test-CsCase 'AT THE BAR' 'B1b: 18 of 20 armed runs current or synced, the other 2 partial with a why and a page, PASSes (bar 18 of 20, 90%)' ($mb18.n -eq 20 -and $mb18.verdict -eq 'PASS') ("n=$($mb18.n) verdict=$($mb18.verdict) $($mb18.detail)")
    $mb17 = Measure-CsB1b $b1Runs (ConvertFrom-CsSyncLog -Lines $b1Rows17).rows $since
    Test-CsCase 'ONE PAST' 'B1b: 17 of 20 FAILs, one run short of the 90% bar' ($mb17.n -eq 20 -and $mb17.verdict -eq 'FAIL' -and $mb17.defects -eq 0) ("n=$($mb17.n) verdict=$($mb17.verdict) $($mb17.detail)")
    $mbSilent = Measure-CsB1b $b1Runs (ConvertFrom-CsSyncLog -Lines @($b1Rows18 | Select-Object -Skip 1)).rows $since
    Test-CsCase 'MUST FIRE' 'B1b: an armed run with no start-sync row at all is SILENT, and a silent run FAILs the bar' ($mbSilent.verdict -eq 'FAIL' -and $mbSilent.defects -eq 1 -and $mbSilent.unmeasured -eq 1) ("verdict=$($mbSilent.verdict) $($mbSilent.detail)")
    $b1WhatIf = ConvertFrom-CsRunLog -Lines (New-CsRunText 6001 '2026-10-03T08:00:01' '-Kind daily -WhatIf' @('capture-run [daily]')) -Name 'capture-run'
    Test-CsCase 'MUST NOT FIRE' 'a -WhatIf run is not an armed run, so it is outside every run-based denominator' (@($b1WhatIf).Count -eq 1 -and -not $b1WhatIf[0].armed -and (Get-CsArmedRuns $b1WhatIf $since).Count -eq 0) ("blocks=$(@($b1WhatIf).Count)")

    # ---- the run-log parser: a nested child block (the re-exec handoff) ----
    $nest = @(New-CsRunText 7001 '2026-10-04T08:00:01' '-Kind daily' @('handing off to b9', '--- run-log: capture-run-daily | 2026-10-04T08:00:09 | pid 7002 ---', 'launched 3 lane(s) concurrently', '--- run-log: finished 2026-10-04T08:40:00 rc=0 ---', 'parent after child'))
    $nb = ConvertFrom-CsRunLog -Lines $nest -Name 'capture-run'
    Test-CsCase 'CLEAN TWIN' 'a block opened inside another is a CHILD, and the parent keeps the lines written after the child finished' (@($nb).Count -eq 2 -and -not $nb[0].child -and $nb[1].child -and (Test-CsLine $nb[0] 'parent after child') -and (Test-CsLine $nb[1] 'launched 3') -and -not (Test-CsLine $nb[0] 'launched 3') -and (Get-CsArmedRuns $nb $since).Count -eq 1) ("blocks=$(@($nb).Count)")

    # ---- B3 ----
    $b3Log = @(New-CsRunText 8001 '2026-09-28T08:00:01' '-Kind daily' @('rebase[1]: Created autostash: ee791d9e5')) + @(New-CsRunText 8002 '2026-10-05T08:00:01' '-Kind daily' @('rebase[1]: Created autostash: a27d910f3', 'rebase[1]: Applied autostash.'))
    $b3Runs = ConvertFrom-CsRunLog -Lines $b3Log -Name 'capture-run'
    $m3a = Measure-CsB3 $b3Runs $since
    Test-CsCase 'MUST FIRE' 'B3: a Created autostash line in a run after the landing commit is a defect, and the bar FAILs' ($m3a.defects -eq 1 -and $m3a.verdict -eq 'FAIL' -and $m3a.n -eq 1) ("defects=$($m3a.defects) n=$($m3a.n) verdict=$($m3a.verdict)")
    $m3b = Measure-CsB3 @($b3Runs[0]) $since
    Test-CsCase 'MUST NOT FIRE' 'B3: the same line in a run BEFORE the landing is outside the window and counts nothing' ($m3b.defects -eq 0 -and $m3b.n -eq 0) ("defects=$($m3b.defects) n=$($m3b.n)")

    # ---- B2 ----
    $b2Runs = ConvertFrom-CsRunLog -Lines (@(New-CsRunText 9001 '2026-10-06T08:00:01' '-Kind daily' @('capture-run [daily]')) + @(New-CsRunText 9002 '2026-10-07T08:00:01' '-Kind daily' @('handing off to b9d1'))) -Name 'capture-run'
    $b2Rows = (ConvertFrom-CsSyncLog -Lines @('{"ts":"2026-10-06T08:00:20","pid":9001,"phase":"start","outcome":"synced","behind_after":0,"startup_changed":true}', '{"ts":"2026-10-07T08:00:20","pid":9002,"phase":"start","outcome":"synced","behind_after":0,"startup_changed":true}')).rows
    $m2a = Measure-CsB2 $b2Runs @($b2Rows[0]) $since
    Test-CsCase 'MUST FIRE' 'B2: a synced start whose startup code changed and whose run never handed off ran the old code, a defect' ($m2a.defects -eq 1 -and $m2a.verdict -eq 'FAIL') ("defects=$($m2a.defects)")
    $m2b = Measure-CsB2 $b2Runs @($b2Rows[1]) $since
    Test-CsCase 'MUST NOT FIRE' 'B2: the same start with a handing off to line in its run is no defect' ($m2b.defects -eq 0 -and $m2b.n -eq 1) ("defects=$($m2b.defects) n=$($m2b.n)")

    # ---- B4 ----
    $m4a = Measure-CsB4 (ConvertFrom-CsSyncLog -Lines @('{"ts":"2026-10-02T08:00:31","pid":1,"phase":"start","outcome":"failed","class":"fingerprint","H0":"a","NEW":"b","fingerprint_changed":2}')).rows $since
    Test-CsCase 'MUST FIRE' 'B4: a moving sync that changed 2 fingerprints outside its write set sums 2 defects' ($m4a.defects -eq 2 -and $m4a.verdict -eq 'FAIL') ("defects=$($m4a.defects)")
    $m4b = Measure-CsB4 (ConvertFrom-CsSyncLog -Lines @('{"ts":"2026-10-02T08:00:31","pid":1,"phase":"start","outcome":"current","H0":"a","NEW":"a"}')).rows $since
    Test-CsCase 'MUST NOT FIRE' 'B4: a sync that did not move HEAD (H0 equals NEW) is outside the moving-sync population' ($m4b.n -eq 0 -and $m4b.defects -eq 0) ("n=$($m4b.n)")

    # ---- B5 ----
    $b5Runs = ConvertFrom-CsRunLog -Lines (@(New-CsRunText 9101 '2026-10-06T08:00:01' '-Kind daily' @('launched 3 lane(s) concurrently; waiting up to 25 min')) + @(New-CsRunText 9102 '2026-10-07T08:00:01' '-Kind daily' @('Grocery bot BLOCKED'))) -Name 'capture-run'
    $b5Rows = (ConvertFrom-CsSyncLog -Lines @('{"ts":"2026-10-06T08:00:20","pid":9101,"phase":"start","outcome":"blocked","class":"conflict","why":"markers in x.json"}', '{"ts":"2026-10-07T08:00:20","pid":9102,"phase":"start","outcome":"blocked","class":"conflict","why":"markers in x.json"}')).rows
    $m5 = Measure-CsB5 $b5Runs $b5Rows $since
    Test-CsCase 'MUST FIRE' 'B5: captures launched after a start sync that found conflict markers is a defect; the run that stopped is a blocked-checkout exit' ($m5.defects -eq 1 -and $m5.n -eq 2 -and $m5.detail -match 'exits .*: 1$') ("defects=$($m5.defects) n=$($m5.n) $($m5.detail)")

    # ---- B6a ----
    $refuse = 'WARNING: commit REFUSED: this run would ADD 40 new file(s) totalling 28.8 MB (caps: 300 files / 25 MB).'
    $b6Runs = ConvertFrom-CsRunLog -Lines (@(New-CsRunText 9201 '2026-10-06T08:00:01' '-Kind daily' @($refuse, 'commit-size: own + unvouched 21 file(s) / 11.3 MB against 300 files / 25 MB: within caps')) + @(New-CsRunText 9202 '2026-10-07T08:00:01' '-Kind daily' @($refuse, 'commit-size: own + unvouched 350 file(s) / 40.0 MB against 300 files / 25 MB: OVER caps')) + @(New-CsRunText 9203 '2026-10-08T08:00:01' '-Kind daily' @($refuse))) -Name 'capture-run'
    $m6a = Measure-CsB6a @($b6Runs[0]) $since
    Test-CsCase 'MUST FIRE' 'B6a: a size-gate refusal whose own plus unvouched were within caps is a defect' ($m6a.defects -eq 1 -and $m6a.verdict -eq 'FAIL') ("defects=$($m6a.defects)")
    $m6b = Measure-CsB6a @($b6Runs[1]) $since
    Test-CsCase 'MUST NOT FIRE' 'B6a: a refusal whose own plus unvouched were OVER caps is the gate working, and PASSes' ($m6b.defects -eq 0 -and $m6b.verdict -eq 'PASS') ("verdict=$($m6b.verdict)")
    $m6c = Measure-CsB6a @($b6Runs[2]) $since
    Test-CsCase 'MUST NOT FIRE' 'B6a: a refusal with no verdict line is unmeasured and gives no verdict, never a pass' ($m6c.unmeasured -eq 1 -and $m6c.verdict -like 'NO-VERDICT*') ("verdict=$($m6c.verdict)")

    # ---- B6b, at the bar: consecutive days with no [daily] commit ----
    $m6d = Measure-CsB6b @('2026-10-01', '2026-10-02', '2026-10-04', '2026-10-05') @('2026-10-03') $since ([datetime]'2026-10-06')
    Test-CsCase 'AT THE BAR' 'B6b: a single missing day (the bar allows at most 1) with one refused day PASSes' ($m6d.verdict -eq 'PASS' -and $m6d.n -eq 1 -and $m6d.detail -match 'no \[daily\] commit: 1 over 5 ') ("verdict=$($m6d.verdict) $($m6d.detail)")
    $m6e = Measure-CsB6b @('2026-10-01', '2026-10-04', '2026-10-05') @('2026-10-02') $since ([datetime]'2026-10-06')
    Test-CsCase 'ONE PAST' 'B6b: two consecutive missing days FAIL' ($m6e.verdict -eq 'FAIL') ("verdict=$($m6e.verdict) $($m6e.detail)")
    $m6f = Measure-CsB6b @('2026-10-01', '2026-10-04') @() $since ([datetime]'2026-10-06')
    Test-CsCase 'MUST NOT FIRE' 'B6b: with no refused day in the window there is no verdict, whatever the gaps' ($m6f.verdict -like 'NO-VERDICT*') ("verdict=$($m6f.verdict)")

    # ---- B7, at the bar: 20 start syncs, integer seconds ----
    $secs = @(10, 10, 10, 10, 10, 10, 10, 10, 10, 30, 30, 60, 60, 60, 60, 60, 60, 120, 500, 500)
    $r7 = @(); for ($i = 0; $i -lt 20; $i++) { $r7 += ('{"ts":"2026-10-02T08:00:31","pid":' + (100 + $i) + ',"phase":"start","outcome":"current","sec":' + $secs[$i] + '}') }
    $m7a = Measure-CsB7 (ConvertFrom-CsSyncLog -Lines $r7).rows $since
    Test-CsCase 'AT THE BAR' 'B7: median exactly 30 s and p90 exactly 120 s over 20 start syncs PASS' ($m7a.verdict -eq 'PASS' -and $m7a.detail -eq 'median 30 s, p90 120 s (nearest rank)') ("verdict=$($m7a.verdict) $($m7a.detail)")
    $r7b = @($r7[0..16]) + ('{"ts":"2026-10-02T08:00:31","pid":117,"phase":"start","outcome":"current","sec":121}') + @($r7[18..19])
    $m7b = Measure-CsB7 (ConvertFrom-CsSyncLog -Lines $r7b).rows $since
    Test-CsCase 'ONE PAST' 'B7: p90 of 121 s, one second past the 120 s bar, FAILs' ($m7b.verdict -eq 'FAIL' -and $m7b.detail -match 'p90 121 s') ("verdict=$($m7b.verdict) $($m7b.detail)")

    # ---- B8 ----
    $m8 = Measure-CsB8 (ConvertFrom-CsSyncLog -Lines @('{"ts":"2026-10-02T08:00:31","pid":1,"phase":"start","outcome":"failed","class":"mixed-tree","held":["held.json"]}')).rows $since
    Test-CsCase 'MUST FIRE' 'B8: a mixed-tree outcome is a defect at any N' ($m8.verdict -eq 'FAIL' -and $m8.defects -ge 1) ("verdict=$($m8.verdict) $($m8.detail)")
    $m8b = Measure-CsB8 (ConvertFrom-CsSyncLog -Lines @('{"ts":"2026-10-02T08:00:31","pid":1,"phase":"start","outcome":"blocked","class":"held-file","held":["held.json"]}')).rows $since
    Test-CsCase 'CLEAN TWIN' 'B8: a held file restored and verified (blocked class held-file) is reported below the judging N of 3 without a verdict' ($m8b.n -eq 1 -and $m8b.defects -eq 0 -and $m8b.verdict -like 'NO-VERDICT*' -and $m8b.detail -match 'verified: 1 of 1') ("verdict=$($m8b.verdict) $($m8b.detail)")

    # ---- B9: the watchdog's own numbers against its own findings ----
    $wd1 = @('--- run-log: capture-watchdog | 2026-10-02T10:30:06 | pid 24416 ---', 'CAPTURE WATCHDOG - 2026-10-02', '  CHECKOUT-FLOOR behind=12 oldest_age_s=95000 bar_s=93600 stale=0 remote=same blind=0', 'CAPTURE-WATCHDOG-COMPLETE findings=0 not_yet=0', '--- run-log: finished 2026-10-02T10:36:02 rc=0 ---')
    $m9a = Measure-CsB9 (ConvertFrom-CsRunLog -Lines $wd1 -Name 'capture-watchdog') $since
    Test-CsCase 'MUST FIRE' 'B9: a watchdog run whose own numbers are past the bar with no BOT CHECKOUT STALE finding is a defect' ($m9a.defects -eq 1 -and $m9a.verdict -eq 'FAIL') ("defects=$($m9a.defects)")
    $wd2 = @($wd1[0], $wd1[1], '  FIND  BOT CHECKOUT STALE: 12 commits behind, oldest missing 03a79922 committed 95,000 s (26.4 h) ago', '  CHECKOUT-FLOOR behind=12 oldest_age_s=95000 bar_s=93600 stale=1 remote=same blind=0', $wd1[3], $wd1[4])
    $m9b = Measure-CsB9 (ConvertFrom-CsRunLog -Lines $wd2 -Name 'capture-watchdog') $since
    Test-CsCase 'CLEAN TWIN' 'B9: the same run with its STALE finding raised counts in N with no defect' ($m9b.n -eq 1 -and $m9b.defects -eq 0 -and $m9b.verdict -eq 'PASS') ("n=$($m9b.n) verdict=$($m9b.verdict)")

    # ---- section 13 ----
    $plan13 = "# P`n`n## 8. Bars`n`nB7: this is section 8, not a result`n`n## 13. Results against the bars`n`nB1a: PASS (N=12, report blob abc, window 2026-10-01..2026-10-14)`n  - B9: FAIL (N=3, report blob abc, window x..y)`nB2:`n`n## 14. Evidence`n`nB8: this is section 14, not a result`n"
    $ids13 = Get-CsResultIds $plan13
    Test-CsCase 'CLEAN TWIN' 'section 13 answers B1a and B9 and nothing else: a B<n> line in section 8 or 14 (B7, B8), or one with nothing after the colon (B2), answers nothing' ($ids13.Count -eq 2 -and $ids13.ContainsKey('B1a') -and $ids13.ContainsKey('B9')) ((@($ids13.Keys) -join ','))

    # ---- which items a Plan line lands: only the id list after the plan path ----
    # 1d59fbfba's Plan line, frozen byte for byte from `git show -s --format=%B 1d59fbfba` (2026-09-23).
    $pl1d59 = 'Plan: design/PLAN-bot-checkout-self-heal-2026-09-23.md W4.2 (complements it: the push-time stale-artifact check sits after the push stage''s rebase and must move with that stage when W4.2 replaces the rebase; no start sync here, W4.1 owns it)'
    $it1d59 = Get-CsPlanLineItems ("daily chain stale code`n`n" + $pl1d59 + "`n")
    Test-CsCase 'MUST FIRE' '1d59fbfba''s Plan line lands W4.2 and NOT W4.1: an id inside the prose after the id list names nothing' ((@($it1d59) -join ',') -eq 'W4.2') ((@($it1d59) -join ','))
    # Two defences hold that rule, so each has its own case (ops-and-gates.md, TWO GUARDS OVER ONE RULE): the cut at the
    # first "(" and the stop at the first segment that does not open with an id.
    $itParen = Get-CsPlanLineItems ('Plan: ' + $script:CsPlanPath + ' W4.2 (the start sync is elsewhere, W4.1 owns it)')
    Test-CsCase 'MUST FIRE' 'an id that opens a comma segment INSIDE a parenthesis names nothing: the list ends at the first "("' ((@($itParen) -join ',') -eq 'W4.2') ((@($itParen) -join ','))
    $itProse = Get-CsPlanLineItems ('Plan: ' + $script:CsPlanPath + ' W4.2; no start sync here, W4.1 owns it')
    Test-CsCase 'MUST FIRE' 'with no parenthesis, the first segment that does not open with an id ends the list, so a later "W4.1 owns it" names nothing' ((@($itProse) -join ',') -eq 'W4.2') ((@($itProse) -join ','))
    $itTen = Get-CsPlanLineItems ('Plan: ' + $script:CsPlanPath + ' W2.10')
    Test-CsCase 'MUST NOT FIRE' 'a Plan line naming W2.10 lands W2.10 and never W2.1: the id is a whole token' (@($itTen).Count -eq 1 -and [string]::Equals([string]$itTen[0], 'W2.10', [StringComparison]::Ordinal)) ((@($itTen) -join ','))
    $itNone = Get-CsPlanLineItems ('Plan: ' + $script:CsPlanPath + " (this commit adds it)`nPlan: design/PLAN-other-2026-09-23.md W3.1`nnot a Plan: " + $script:CsPlanPath + ' W3.2')
    Test-CsCase 'MUST NOT FIRE' 'the plan''s own "(this commit adds it)" line, another plan''s line and a Plan: not at line start land nothing' (@($itNone).Count -eq 0) ((@($itNone) -join ','))
    $itReal = Get-CsPlanLineItems ("W0.2 and friends`n`nPlan: " + $script:CsPlanPath + " W0.2, W3.2, W4.1 step 7, W4.2, W5.1.`nPlan: " + $script:CsPlanPath + " W2.2 step 3 and 4`n")
    Test-CsCase 'CLEAN TWIN' 'real landing lines still resolve: a five-item list with a step note and a full stop, and an id followed by its step, read W0.2 W3.2 W4.1 W4.2 W5.1 W2.2' ((@($itReal) -join ',') -eq 'W0.2,W3.2,W4.1,W4.2,W5.1,W2.2') ((@($itReal) -join ','))
    # A colon or a full stop ends the id list wherever it falls (2026-09-24). Until then the colon was only trimmed off
    # the first word, so the segment after it still opened a new id. The cut is one rule reached three ways, so each
    # way has its own case: a colon on the id, a colon on a later word, a full stop on a later word.
    $plColon = 'Plan: ' + $script:CsPlanPath + ' W4.2: the stale check moves with the push stage, W4.1 owns it'
    $itColon = Get-CsPlanLineItems $plColon
    Test-CsCase 'MUST FIRE' 'a colon on the id ends the list: "W4.2: ..., W4.1 owns it" lands W4.2 and NOT W4.1' ((@($itColon) -join ',') -eq 'W4.2') ((@($itColon) -join ','))
    $plStepColon = 'Plan: ' + $script:CsPlanPath + ' W4.1 step 7: the start sync, W4.2 owns it'
    $itStepColon = Get-CsPlanLineItems $plStepColon
    Test-CsCase 'MUST FIRE' 'a colon on a word after the id ends the list: "W4.1 step 7: ..., W4.2 owns it" lands W4.1 and NOT W4.2' ((@($itStepColon) -join ',') -eq 'W4.1') ((@($itStepColon) -join ','))
    $plStop = 'Plan: ' + $script:CsPlanPath + ' W4.1 step 7. Next, W4.2 owns the rebase'
    $itStop = Get-CsPlanLineItems $plStop
    Test-CsCase 'MUST FIRE' 'a full stop after the ids ends the list: "W4.1 step 7. Next, W4.2 owns ..." lands W4.1 and NOT W4.2' ((@($itStop) -join ',') -eq 'W4.1') ((@($itStop) -join ','))
    $plPlain = 'Plan: ' + $script:CsPlanPath + ' W0.2, W3.2; W4.1 and W4.2'
    $itPlain = Get-CsPlanLineItems $plPlain
    Test-CsCase 'CLEAN TWIN' 'a plain id list with no colon or full stop still lands every id, across all three separators: W0.2 W3.2 W4.1 W4.2 (the dot inside an id is never a stop)' ((@($itPlain) -join ',') -eq 'W0.2,W3.2,W4.1,W4.2') ((@($itPlain) -join ','))

    # ---- END TO END through the real script: -Due, and a plain run, against a temp repo ----
    New-Item -ItemType Directory -Path $csRoot -ErrorAction Stop | Out-Null
    . (Join-Path (Split-Path $csHere -Parent) 'lib\git-repo-env.ps1')
    Clear-TcGitRepoEnv
    $csUtf8 = New-Object Text.UTF8Encoding($false)
    function CsFxGit([string]$Dir, [string[]]$A) {
      $r = Invoke-GitCaptured -Repo $Dir -GitArgs $A
      if ($r.rc -ne 0) { throw ('fixture git ' + ($A -join ' ') + ' exited ' + $r.rc + ': ' + ([string]$r.stderr).Trim()) }
      return ([string]$r.stdout).Trim()
    }
    function CsFxCommitPlan([string]$Dir, [string]$Body, [string]$Msg, [long]$At) {
      $pp = Join-Path $Dir 'design\PLAN-bot-checkout-self-heal-2026-09-23.md'
      [IO.File]::WriteAllText($pp, $Body, $csUtf8)
      [IO.File]::WriteAllText((Join-Path $Dir 'msg.txt'), $Msg, $csUtf8)
      $env:GIT_COMMITTER_DATE = ('@' + $At + ' +0000'); $env:GIT_AUTHOR_DATE = $env:GIT_COMMITTER_DATE
      try {
        $null = CsFxGit $Dir @('add', '--', 'design/PLAN-bot-checkout-self-heal-2026-09-23.md')
        $null = CsFxGit $Dir @('-c', 'user.name=rcs', '-c', 'user.email=rcs@t', '-c', 'commit.gpgsign=false', 'commit', '-q', '-F', 'msg.txt')
        $null = CsFxGit $Dir @('update-ref', 'refs/remotes/origin/main', 'HEAD')
      } finally { $env:GIT_COMMITTER_DATE = $csPrevCd; $env:GIT_AUTHOR_DATE = $csPrevAd }
    }
    $fx = Join-Path $csRoot 'repo'
    $null = CsFxGit $csRoot @('init', '-q', '-b', 'main', 'repo')
    $null = CsFxGit $fx @('config', 'core.autocrlf', 'false')
    New-Item -ItemType Directory -Path (Join-Path $fx 'design') -ErrorAction Stop | Out-Null
    # W1.1 lands at 2026-10-01 12:00 local; its read-out (B9, 14 days) is 2026-10-15.
    $landEpoch = ([DateTimeOffset]([datetime]'2026-10-01 12:00')).ToUnixTimeSeconds()
    $planEmpty = "# P`n`n## 13. Results against the bars`n`nEmpty until read-outs.`n`n## 14. Evidence register`n"
    CsFxCommitPlan $fx $planEmpty ("W1.1 lands`n`nPlan: " + $script:CsPlanPath + " W1.1`n") $landEpoch
    $csSelf = $PSCommandPath
    $e1 = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $csSelf -Due -Repo $fx -Today '2026-10-16'); $e1rc = $LASTEXITCODE
    Test-CsCase 'MUST FIRE' '-Due: B9''s read-out 2026-10-15 has passed on 2026-10-16 and section 13 has no B9 line, so it exits 2 naming B9' ($e1rc -eq 2 -and @($e1 | Where-Object { $_ -like 'DUE  B9:*' }).Count -eq 1 -and @($e1 | Where-Object { $_ -like 'DUE  B*' }).Count -eq 1) ("rc=$e1rc " + (@($e1 | Where-Object { $_ -like 'DUE*' }) -join ' | '))
    $e2 = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $csSelf -Due -Repo $fx -Today '2026-10-15'); $e2rc = $LASTEXITCODE
    Test-CsCase 'AT THE BAR' '-Due: ON the read-out date itself (2026-10-15) nothing has passed yet, so it exits 0' ($e2rc -eq 0 -and @($e2 | Where-Object { $_ -like 'DUE  none*' }).Count -eq 1) ("rc=$e2rc")
    $p0 = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $csSelf -Repo $fx -Today '2026-10-16'); $p0rc = $LASTEXITCODE
    $p0Verdicts = @($p0 | Where-Object { $_ -match '^B\d+[a-z]?\s+\S' })
    Test-CsCase 'CLEAN TWIN' 'a plain run exits 0 whatever is due, prints all 11 bars as NO-VERDICT with N=0 over no rows and no logs, and ends on its COMPLETE line' ($p0rc -eq 0 -and $p0Verdicts.Count -eq 11 -and @($p0Verdicts | Where-Object { $_ -match 'NO-VERDICT \(N below minimum\)$' }).Count -eq 11 -and @($p0 | Where-Object { $_ -match '^\s+N\s+0 \(minimum' }).Count -eq 11 -and ([string]$p0[$p0.Count - 1]) -eq 'REPORT-CHECKOUT-SYNC-COMPLETE bars=11 pass=0 fail=0 no_verdict=11 due=0 blind=0') ("rc=$p0rc verdicts=$($p0Verdicts.Count) last=" + $p0[$p0.Count - 1])
    # The same plain run over real log FILES: two watchdog runs in one file (the read path the pure cases above skip).
    $fxLogs = Join-Path $fx 'grocery\out\logs'
    New-Item -ItemType Directory -Path $fxLogs -Force -ErrorAction Stop | Out-Null
    [IO.File]::WriteAllLines((Join-Path $fxLogs 'capture-watchdog-2026-10-02.log'), [string[]](@($wd1) + @($wd2)), $csUtf8)
    $p1 = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $csSelf -Repo $fx -Today '2026-10-16'); $p1rc = $LASTEXITCODE
    $p1B9 = @($p1 | Where-Object { $_ -match '^B9\s+' })
    Test-CsCase 'MUST FIRE' 'a plain run over a watchdog log holding one run past the bar with no STALE finding, and one with it, reads B9 FAIL over N=2 with 1 defect, and still exits 0' ($p1rc -eq 0 -and $p1B9.Count -eq 1 -and $p1B9[0] -match 'FAIL$' -and @($p1 | Where-Object { $_ -match '^\s+N\s+2 \(minimum 1\)\s+defects 1' }).Count -eq 1 -and @($p1 | Where-Object { $_ -match '2 watchdog block\(s\)' }).Count -eq 1) ("rc=$p1rc b9=" + ($p1B9 -join '|'))
    $planOutside = "# P`n`n## 8. Bars`n`nB9: PASS (N=3, report blob abc, window x..y)`n`n## 13. Results against the bars`n`nEmpty until read-outs.`n`n## 14. Evidence register`n"
    CsFxCommitPlan $fx $planOutside "a result line in the wrong section`n" ($landEpoch + 86400)
    $e3 = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $csSelf -Due -Repo $fx -Today '2026-10-16'); $e3rc = $LASTEXITCODE
    Test-CsCase 'MUST FIRE' '-Due: a B9 result line written in section 8 answers nothing, so B9 is still due (exit 2)' ($e3rc -eq 2) ("rc=$e3rc")
    $planDone = "# P`n`n## 13. Results against the bars`n`nB9: PASS (N=14, report blob abc123, window 2026-10-01..2026-10-15)`n`n## 14. Evidence register`n"
    CsFxCommitPlan $fx $planDone "the B9 read-out`n" ($landEpoch + 172800)
    $e4 = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $csSelf -Due -Repo $fx -Today '2026-10-16'); $e4rc = $LASTEXITCODE
    Test-CsCase 'CLEAN TWIN' '-Due: the same day with a B9 result line in section 13 of the committed plan exits 0 and says nothing is owed' ($e4rc -eq 0 -and @($e4 | Where-Object { $_ -like 'DUE  none*' }).Count -eq 1) ("rc=$e4rc")
    # The same grammar through Get-CsLandings over real git: 1d59fbfba's message on origin/main lands W4.2 only.
    CsFxCommitPlan $fx ($planDone + "`n") ("daily chain stale code`n`n" + $pl1d59 + "`n") ($landEpoch + 259200)
    $lnd = Get-CsLandings -Repo $fx
    Test-CsCase 'MUST FIRE' 'Get-CsLandings over a repo carrying 1d59fbfba''s message reads W1.1 and W4.2 as landed and W4.1 as not' ($lnd.map.ContainsKey('W1.1') -and $lnd.map.ContainsKey('W4.2') -and -not $lnd.map.ContainsKey('W4.1') -and $lnd.map.Count -eq 2) ((@($lnd.map.Keys | Sort-Object) -join ',') + ' note=' + $lnd.note)
  } catch {
    Write-Output ('FAIL  the self-test threw: ' + $_.Exception.Message); $script:csFail++
  } finally {
    $env:GIT_COMMITTER_DATE = $csPrevCd; $env:GIT_AUTHOR_DATE = $csPrevAd
    Remove-Item -LiteralPath $csRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
  if ($script:csCases -ne $CS_SELFTEST_CASES) { Write-Output ('FAIL  the suite ran ' + $script:csCases + ' case(s) against its literal ' + $CS_SELFTEST_CASES + ' - a case was lost or added without the count'); $script:csFail++ }
  Write-Output ('REPORT-CHECKOUT-SYNC SELF-TEST ' + $(if ($script:csFail) { 'FAILED (' + $script:csFail + ' of ' + $script:csCases + ' failed)' } else { 'PASSED (' + $script:csCases + ' of ' + $CS_SELFTEST_CASES + ' cases)' }))
  exit $(if ($script:csFail) { 1 } else { 0 })
}

# ---- A LIVE RUN -----------------------------------------------------------------------------------------------------------
$csRepo = if ($Repo) { [IO.Path]::GetFullPath($Repo) } else { Split-Path $csHere -Parent }
$csToday = if ($Today) { [datetime]::ParseExact($Today, 'yyyy-MM-dd', $script:CsInv) } else { (Get-Date).Date }
$csRes = Invoke-CsReport -RepoRoot $csRepo -TodayDate $csToday -DueMode:$Due
foreach ($l in $csRes.lines) { Write-Output $l }
if ($Due) { exit $csRes.rc }
exit $(if ($csRes.rc -eq 3) { 3 } else { 0 })
