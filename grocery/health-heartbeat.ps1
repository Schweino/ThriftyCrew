<#
  health-heartbeat.ps1 - SILENT-DEATH detector for the estate's automations + critical outputs.

  The existing safety net catches LOUD failures: a GitHub Actions run that errors emails Brad, and
  local-watchdog flags browser-store data going stale. The gap this closes: an automation that stops
  running WITHOUT failing - a Windows task that got deleted/disabled, a trigger that quietly broke, or a
  recipe-side output (v2 manifest, rotation, feed) that no watchdog covered. Nothing "fails"; things just
  silently stop, and the first sign is a shopper seeing week-old prices.

  Reads grocery\expected-automations.json (the registry - add new daily automations there) and checks:
    - each Windows task EXISTS, is not Disabled, and ran within max_age_hours (a missing/disabled task =
      silent death; LastTaskResult "not yet run" is OK only when allow_pending);
    - each critical output file / glob exists and is fresher than max_age_hours, EXCEPT an output_files row
      that declares currency_field: that one is rewritten only when it changes, so its mtime proves nothing
      and it is judged on the currency stamp inside it instead (see the CONTENT-CURRENCY block);
    - each task row that declares run_log is judged on its RUN'S OWN TRANSCRIPT, whatever LastTaskResult says: the
      last session of the newest <name>-<date>.log must carry rc=0, a committed or nothing-changed commit verdict in
      that name, and a start inside max_age_hours (see the RUN-LOG-VERDICT block).

  Exit 0 = all healthy, 2 = one or more silently dead/stale. -SelfTest runs the frozen RUN-LOG-VERDICT fixtures and
  touches no scheduler and no mail: exit 0 pass, 1 a case failed, 3 could not run. -Alert emails Brad (de-duped by signature so
  a persistent outage is one email). Meant to run INDEPENDENTLY of the pipeline it watches - it is invoked
  from local-watchdog.ps1 (its own WakeToRun task), so a dead main pipeline cannot suppress its own alarm.
#>
param([switch]$Alert, [switch]$SelfTest)
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$ErrorActionPreference = 'Continue'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
# Alerts go out through Send-Alert (alert-lib.ps1), never as `powershell -File send-alert.ps1 -Body $long`:
# Windows refuses to start a process whose command line passes 32767 chars, so an oversized body did not
# arrive truncated - it did not arrive at all, and the launch error read like the CHECK had crashed. Three
# consecutive guard-blind days went unpaged that way on 2026-08-03/04/05. See alert-lib.ps1.
. (Join-Path $root 'alert-lib.ps1')
$repo = Split-Path $root -Parent
# lib\pipeline-commit.ps1 for Get-PipelineCommitOutcome, the classifier that sits beside the commit sentences it reads
# (RUN-LOG-VERDICT below). Loaded under Stop inside a try because this file runs under Continue, and swallowed on
# failure because the verdict reader checks for the classifier itself: a library that did not load becomes a NAMED
# REASON on every run_log row, never a landed run. A try block is not a scope, so the functions land in this one.
try { $ErrorActionPreference = 'Stop'; . (Join-Path $repo 'lib\pipeline-commit.ps1') } catch { } finally { $ErrorActionPreference = 'Continue' }
$now  = Get-Date
$cfg  = Read-JsonFile (Join-Path $root 'expected-automations.json')
# AN EMPTY REGISTRY IS BLIND, NOT HEALTHY (2026-09-06, PLAN-top5 area 5 §5.2.4). This file sets
# EAP='Continue', so before the 2026-09-05 reader sweep an unreadable expected-automations.json left $cfg
# NULL and the run carried on: all four loops below iterate `@($cfg.windows_tasks)` and friends, every one
# of them empty, $issues stays at 0, and the last lines print "HEALTHY: 0 automation(s)/output(s) all
# fresh" and exit 0. The one check whose entire job is to notice things that died SILENTLY would have
# died silently and said everything was fine.
# Read-JsonFile now THROWS on a missing or unreadable file, which closes half of it. The other half is a
# file that parses and declares nothing - a truncated edit, a merge that lost the arrays - and no throw
# can catch that. So count what was declared, and refuse to grade an empty exam.
$declared = @($cfg.windows_tasks).Count + @($cfg.output_files).Count + @($cfg.output_globs).Count
if ($declared -eq 0) {
  Write-Output 'health-heartbeat: BLIND - expected-automations.json declares no tasks, files or globs, so a clean report here would mean nothing. Exit 3 (could-not-evaluate), never 0.'
  exit 3
}
$issues = New-Object System.Collections.Generic.List[string]
$okLines = New-Object System.Collections.Generic.List[string]
$TASK_NOT_YET_RUN = 267011   # 0x00041303 SCHED_S_TASK_HAS_NOT_RUN
$TASK_RUNNING     = 267009   # 0x00041301 SCHED_S_TASK_RUNNING (transient: reported as LastTaskResult while a run is in flight)

# >>> PROOF-FRESHNESS  (test-proof-freshness.ps1 extracts and executes THIS text verbatim - keep the sentinels)
function Test-ProofLanded {
  param([string]$ProvesGlob, [string]$RepoRoot, [double]$MaxAgeHours, $LastRunTime, [datetime]$Now)
  # Decides whether a NONZERO task result is excused because the work landed anyway. Two conditions, and
  # the second one is the whole point (added 2026-08-06):
  #   1. the proof output is younger than max_age_hours, AND
  #   2. the proof output is NOT OLDER THAN the run it is supposed to prove.
  #
  # Condition 2 exists because max_age_hours (30h, sized to tolerate a late run plus a weekend gap) is WIDER
  # than a daily task's own 24h period, so YESTERDAY's output always satisfies condition 1 on its own. On
  # 2026-08-06 the Baker's task never started at all (PC went back to sleep at 05:52, the 06:00 trigger fired
  # into a sleeping machine, result 0x800710E0) and produced nothing - but bakers-regular-2026-08-05.json was
  # 23.5h old, inside the 30h window, so this check reported "work landed, not dead" and the entire missed day
  # went unpaged. A proof written BEFORE the run cannot be evidence about that run.
  #
  # The founding case for 'proves' still passes: 2026-07-28, Baker's was terminated by a battery condition
  # AFTER its data had refreshed. That proof was written DURING the run, so it is >= LastRunTime.
  if (-not $ProvesGlob) { return @{ fresh = $false; ageH = $null; why = '' } }
  $newest = @(Get-ChildItem (Join-Path $RepoRoot $ProvesGlob) -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
  if ($newest.Count -eq 0) { return @{ fresh = $false; ageH = $null; why = ' (nothing matches its proves glob)' } }
  $stamp = $newest[0].LastWriteTime
  $ageH  = [math]::Round(($Now - $stamp).TotalHours, 1)
  if ($ageH -gt $MaxAgeHours) { return @{ fresh = $false; ageH = $ageH; why = (' (its newest output is ' + $ageH + 'h old)') } }
  if ($LastRunTime -and $stamp -lt $LastRunTime) {
    return @{ fresh = $false; ageH = $ageH; why = (' (its newest output ' + $newest[0].Name + ' PREDATES the run that was supposed to write it, so that run produced nothing)') }
  }
  return @{ fresh = $true; ageH = $ageH; why = '' }
}
# <<< PROOF-FRESHNESS

# >>> CONTENT-CURRENCY  (test-auditors.ps1 extracts and executes THIS text verbatim - keep the sentinels)
# AN OUTPUT THAT IS REWRITTEN ONLY WHEN IT CHANGES HAS NO mtime LIVENESS SIGNAL AT ALL.
# Founding case 2026-09-04, queue 2026-09-04-2feb5c. rotate-free-dinners.ps1 ran at 08:12:48 and exited 0,
# as it had every morning; it writes public\free-dinners.json only when the free set actually flips (an
# early return at rotate-free-dinners.ps1:129-130 sits before the write at line 228). So the file's mtime
# tracks the WEEKLY rotation while this registry asserted a 30h DAILY window over it, and the heartbeat
# paged every day from roughly 30h after each flip until the next one, which is most of every week. The
# content was correct throughout: week_of=2026-09-02, matching the board week. Nothing a reader saw was wrong.
#
# TWO REMEDIES WERE CONSIDERED AND REJECTED. Both are the obvious answer and both are wrong, so the reasons
# live here rather than in a report, to stop the next reader re-proposing them:
#   1. RAISE max_age_hours PAST A WEEK. That is the tolerance-wider-than-period defect: a staleness window
#      wider than the cadence it watches can never fire on time, so a genuinely DEAD rotation would sit
#      unnoticed for a full week and the alert would only arrive after the damage. The estate has already
#      been bitten by exactly this shape. Do not widen the number on a row that uses this form.
#   2. TOUCH THE FILE ON A NO-OP so its mtime refreshes. That is date laundering: the file would read fresh
#      with nothing whatsoever proving the rotation ran, and the check would be measuring its own write.
# The answer is to prove currency from the CONTENT instead: the file itself says which week it describes.
#
# IT IS OPT-IN, AND THAT IS LOAD-BEARING. Four of the five output_files rows (grocery\out\smp-feed.json,
# public\smp-feed.json, meal-prep\pipeline\v2-perserving.json, meal-prep\ingredient-map.json) are rewritten
# on EVERY run and cannot no-op, so mtime is a true liveness signal for them. A default-on content check
# would silently disarm the mtime rule on all four. A row uses this form only by declaring currency_field.
#
# max_age_hours STAYS ON THE ROW and is deliberately NOT consulted while currency_field is present. It is
# kept so that deleting the two currency_* fields restores exactly the old behaviour (that is the rollback),
# and so nobody "fixes" a false positive here by widening it. The mtime age is still printed, as context.
#
# A DEAD ROTATION STILL PAGES: when the board week moves and the rotation does not run, week_of falls behind
# and this reports. And if the BOARD stops rebuilding, the comparison-*.json output_globs row pages, so the
# reference this check leans on cannot go stale unnoticed either. Every ambiguity below FAILS CLOSED.
function Get-BoardWeek {
  param([string]$RepoRoot)
  # THE SAME DERIVATION THE WRITER USES (rotate-free-dinners.ps1:93-94): the newest comparison-<date>.json
  # BY NAME, not by mtime - an older board rebuilt today must not become "this week". If this check derived
  # the week any other way, a disagreement between two derivations would page as a dead rotation.
  $wk = @(Get-ChildItem (Join-Path $RepoRoot 'grocery\out\comparison-*.json') -ErrorAction SilentlyContinue |
          Where-Object { $_.BaseName -match '^comparison-\d{4}-\d{2}-\d{2}$' } |
          Sort-Object Name -Descending | Select-Object -First 1)
  if ($wk.Count -eq 0) { return '' }
  return [regex]::Match($wk[0].BaseName, '\d{4}-\d{2}-\d{2}').Value
}
function Test-ContentCurrency {
  param($Row, [string]$Path, [string]$BoardWeek, [datetime]$Now)
  # applies=$false means "this row is not on the content form" and the caller uses the plain mtime rule.
  $r = @{ applies = $false; current = $false; detail = '' }
  if (-not $Row) { return $r }
  $field = if ($Row.PSObject.Properties['currency_field']) { [string]$Row.currency_field } else { '' }
  if (-not $field) { return $r }
  $r.applies = $true
  $equals = if ($Row.PSObject.Properties['currency_equals']) { [string]$Row.currency_equals } else { '' }
  if ($equals -ne 'board_week') {
    # ALLOWLIST, NOT DENYLIST. A form this code has never heard of is unproven, not fine.
    $r.detail = "declares currency_field '$field' but currency_equals '$equals' is not a form this check knows, so its currency is UNPROVEN"
    return $r
  }
  if (-not (Test-Path $Path)) { $r.detail = 'does not exist'; return $r }
  # THE AGE IS REPORTED, NEVER GATED, and every detail below quotes it in the SAME shape, "mtime <n>h",
  # because the fixtures read that number back out to prove they are not passing for the wrong reason
  # (the must-fire must be provably FRESH, the clean twin provably past the window). Reword it and both
  # go blind while still reporting PASS.
  $ageH = [math]::Round(($Now - (Get-Item $Path).LastWriteTime).TotalHours, 1)
  if (-not $BoardWeek) {
    $r.detail = "carries $field, but no grocery\out\comparison-<date>.json exists to compare it against, so this check is BLIND rather than clean (mtime ${ageH}h)"
    return $r
  }
  $doc = $null
  try { $doc = Read-JsonFile $Path } catch { $doc = $null }
  if (-not $doc) { $r.detail = "could not be read as JSON, so its $field proves nothing (mtime ${ageH}h)"; return $r }
  $stamp = if ($doc.PSObject.Properties[$field]) { [string]$doc.$field } else { '' }
  if (-not $stamp) { $r.detail = "has no $field field, so nothing in it says which week it describes (mtime ${ageH}h)"; return $r }
  if ($stamp -ne $BoardWeek) {
    $r.detail = "carries $field=$stamp but the current board week is $BoardWeek, so the job that writes it has not run for this week (mtime ${ageH}h, which is NOT the tell here)"
    return $r
  }
  $r.current = $true
  $r.detail  = "$field=$stamp matches the board week (mtime ${ageH}h, not gated: this output is rewritten only when it changes)"
  return $r
}
# <<< CONTENT-CURRENCY

# >>> RUN-LOG-VERDICT  (this file's own -SelfTest drives THIS text against frozen transcripts - keep the sentinels)
# A TASK CAN READ 0 BY MORNING WHILE ITS WORK DID NOT LAND (2026-09-11). Founding case: TC Graph Nightly Matching,
# 2026-09-07 to 09-10. graph-nightly's commit was refused on every night it ran, and nothing paged for four days:
#   1. the task repeats hourly 21:30 to 05:30, and after a completed run every repetition takes the skip path and
#      exits 0, so LastTaskResult reads 0 by morning whatever the real run returned;
#   2. its 'proves' output is graph-nightly-status.json, which the chain writes in its finally block BEFORE the
#      commit, so the proof is fresh on exactly the nights the commit was refused;
#   3. that stamp carries no commit verdict, and must not be rewritten to carry one after the commit: the catch-up
#      guard (Test-AlreadyRanThisWindow in graph\pipeline\nightly.ps1) reads it.
# The record that outlives the repetitions is the RUN'S OWN TRANSCRIPT. Start-RunLog files it by wall-clock date under
# a name the skip path never uses (it writes <name>-skipped-<date>.log), and it holds both the lane's commit verdict
# and Stop-RunLog's rc stamp. So a row that declares run_log is judged on the LAST session of its newest dated
# transcript, and all three of these must hold:
#   * the rc stamp is present and 0. Absent means the run ended before Done() could stamp it;
#   * a line in the lane's own name classifies as committed or nothing, by lib\pipeline-commit.ps1's
#     Get-PipelineCommitOutcome. NOT THE rc ALONE: every founding transcript says "commit refused" and then "rc=0",
#     because nightly.ps1 still ends in a typed zero (checked on main at 740c82af6, 2026-09-12), so an rc-only reader
#     passes the founding case and would keep passing the next one. The rc is kept as a second signal, for the day it
#     is earned rather than typed, and because it is the only thing that speaks for a run killed before its commit;
#   * the session began inside the row's max_age_hours. WHEN THE PRODUCER STOPS the newest transcript only ages, so
#     this fires on absence too, not only on a bad verdict. No new constant: it is the row's own number. Known gap:
#     a night caught up at 05:30 followed by a night lost whole reads 29 h at the 10:30 heartbeat and fires a day late.
# SCOPE OF A CLEAN VERDICT: UNSOUND. "landed" means the last session says rc=0 and a committed or nothing-changed
# verdict in the lane's name. It does not prove the push reached origin (a failed push is still 'committed', by the
# lib's own promise), nor that the commit held the right files.
function Get-NewestRunLogName {
  # The newest <Name>-yyyy-MM-dd.log among $Names BY THE DATE IN THE NAME, or ''. <Name>-skipped-<date>.log does not
  # match, on purpose: a skipped repetition is dated later than the run it skipped and always stamps rc=0.
  param([string[]]$Names, [string]$Name)
  $rx = '^' + [regex]::Escape($Name) + '-(\d{4}-\d{2}-\d{2})\.log$'
  $best = ''; $bestDay = ''
  foreach ($n in @($Names)) {
    $m = [regex]::Match([string]$n, $rx, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $m.Success) { continue }
    if ([string]::CompareOrdinal($m.Groups[1].Value, $bestDay) -gt 0) { $best = [string]$n; $bestDay = $m.Groups[1].Value }
  }
  return $best
}
function Test-RunLogVerdict {
  # PURE over the transcript TEXT. Returns @{ landed; file; started; ageH; rc; outcome; verdict; reasons }, and every
  # reason the run did not land is listed, so a stale night that was also refused says both.
  param([string]$Text, [string]$Name, [double]$MaxAgeHours, [datetime]$Now)
  $r = @{ landed = $false; file = ''; started = $null; ageH = $null; rc = $null; outcome = 'unknown'; verdict = ''; reasons = @() }
  $reasons = New-Object System.Collections.Generic.List[string]
  $lines = @(([string]$Text) -split "\r?\n")
  $from = -1
  for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i].Trim() -eq 'Windows PowerShell transcript start') { $from = $i } }
  if ($from -lt 0) { $reasons.Add('it holds no transcript session'); $r.reasons = $reasons.ToArray(); return $r }
  $session = @($lines[$from..($lines.Count - 1)])
  $pfx = $Name + ': '
  $pfxRefused = 'REFUSED: ' + $Name + ' '
  $haveOc = [bool](Get-Command Get-PipelineCommitOutcome -ErrorAction SilentlyContinue)
  $lastNamed = ''
  foreach ($l in $session) {
    if ($null -eq $r.started -and $l -match '^Start time: (\d{14})\s*$') {
      $r.started = [datetime]::ParseExact($matches[1], 'yyyyMMddHHmmss', [Globalization.CultureInfo]::InvariantCulture)
    }
    if ($l -match '^--- run-log: finished \S+ rc=(-?\d+) ---\s*$') { $r.rc = [int]$matches[1] }
    if (-not ($l.StartsWith($pfx, [StringComparison]::Ordinal) -or $l.StartsWith($pfxRefused, [StringComparison]::Ordinal))) { continue }
    $lastNamed = $l
    if ($haveOc) {
      $oc = Get-PipelineCommitOutcome -Verdict $l
      if ($oc -ne 'unknown') { $r.outcome = $oc; $r.verdict = $l }
    }
  }
  if (-not $r.verdict -and $lastNamed) { $r.verdict = $lastNamed }
  if ($null -ne $r.started) { $r.ageH = [math]::Round(($Now - $r.started).TotalHours, 1) }

  if ($null -eq $r.started) { $reasons.Add('its session carries no Start time, so its age is unknown') }
  elseif ($r.ageH -gt $MaxAgeHours) {
    $reasons.Add(("its run began {0}, {1}h before this check (> the row's {2}h): the chain has not run since" -f $r.started.ToString('yyyy-MM-ddTHH:mm:ss'), $r.ageH, $MaxAgeHours))
  }
  if ($null -eq $r.rc) { $reasons.Add('it carries no rc stamp, so the run ended before Done() stamped one (killed, or cut off by the task time limit)') }
  elseif ($r.rc -ne 0) { $reasons.Add(("it stamped rc={0}" -f $r.rc)) }
  if (-not $haveOc) { $reasons.Add('lib\pipeline-commit.ps1 did not load, so no commit verdict could be classified') }
  elseif (@('committed', 'nothing') -notcontains $r.outcome) {
    if ($r.verdict) {
      $short = if ($r.verdict.Length -gt 240) { $r.verdict.Substring(0, 240) + '...' } else { $r.verdict }
      $reasons.Add(("its commit verdict is {0}: {1}" -f $r.outcome, $short))
    } else { $reasons.Add(("no commit verdict under the name '{0}' is in the session" -f $Name)) }
  }
  $r.reasons = $reasons.ToArray()
  $r.landed = ($reasons.Count -eq 0)
  return $r
}
function Get-RunLogVerdict {
  # The live half, kept thin: list the run_log directory, pick the newest dated transcript, judge it. Every miss is a
  # reason, never a pass. Opened with ReadWrite sharing so a transcript another process still holds can be read.
  param([string]$RunLog, [string]$RepoRoot, [double]$MaxAgeHours, [datetime]$Now)
  $rel  = ([string]$RunLog) -replace '/', '\'
  $dir  = Join-Path $RepoRoot (Split-Path $rel -Parent)
  $name = Split-Path $rel -Leaf
  $names = @()
  try { $names = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction Stop | ForEach-Object { $_.Name }) } catch { $names = @() }
  $file = Get-NewestRunLogName -Names $names -Name $name
  if (-not $file) {
    return @{ landed = $false; file = ''; started = $null; ageH = $null; rc = $null; outcome = 'unknown'; verdict = ''
              reasons = @(("no {0}-<date>.log exists under {1}" -f $name, $dir)) }
  }
  $text = ''
  try {
    $fs = [IO.File]::Open((Join-Path $dir $file), 'Open', 'Read', 'ReadWrite')
    try { $text = (New-Object IO.StreamReader($fs, $true)).ReadToEnd() } finally { $fs.Dispose() }
  } catch { $text = '' }
  $v = Test-RunLogVerdict -Text $text -Name $name -MaxAgeHours $MaxAgeHours -Now $Now
  $v.file = $file
  return $v
}
# <<< RUN-LOG-VERDICT

if ($SelfTest) {
  # HERMETIC. Frozen transcripts under regression-inputs\, no scheduler, no mail. The two live reads at the end are
  # labelled. Every case runs under Stop inside a try whose catch is a counted failure.
  $hbFail = 0; $hbCases = 0
  function HbCase([string]$n, [bool]$c, [string]$got = '') {
    $script:hbCases++
    if ($c) { Write-Output ('  ok    ' + $n) } else { Write-Output ('  FAIL  ' + $n + '   got: ' + $got); $script:hbFail++ }
  }
  function HbShow($v) { return ('landed=' + $v.landed + ' rc=' + $v.rc + ' outcome=' + $v.outcome + ' started=' + $v.started + ' ageH=' + $v.ageH + ' reasons=' + (@($v.reasons) -join ' | ')) }
  try {
    $ErrorActionPreference = 'Stop'
    if (-not (Get-Command Get-PipelineCommitOutcome -ErrorAction SilentlyContinue)) { throw 'lib\pipeline-commit.ps1 did not load, so Get-PipelineCommitOutcome is missing' }
    $fx0909 = [IO.File]::ReadAllText((Join-Path $root 'regression-inputs\graph-nightly-2026-09-09.transcript.txt'))
    $fxTwin = [IO.File]::ReadAllText((Join-Path $root 'regression-inputs\graph-nightly-committed-twin.transcript.txt'))
  } catch { Write-Output ('health-heartbeat self-test: COULD NOT RUN - ' + $_.Exception.Message); exit 3 }

  try {
    # ---- MUST FIRE, THE FOUNDING NIGHT: 2026-09-09 21:30, commit refused by the hook, last line rc=0. Judged at the
    #      first 10:30 heartbeat after it, which is where four days of silence would have become one page.
    $v1 = Test-RunLogVerdict -Text $fx0909 -Name 'graph-nightly' -MaxAgeHours 30 -Now ([datetime]'2026-09-10T10:30:00')
    HbCase 'MUST FIRE  2026-09-09 21:30: the commit was refused and the transcript says rc=0, and it pages' ((-not $v1.landed) -and $v1.outcome -eq 'refused' -and $v1.rc -eq 0) (HbShow $v1)
    HbCase 'MUST FIRE  it judged the LAST session (21:30:01), not the -WhatIfOnly or -StopOnly sessions above it' ($v1.started -eq [datetime]'2026-09-09T21:30:01') (HbShow $v1)
    HbCase 'MUST FIRE  it fires on the VERDICT, not on age: 13h old, inside the row''s 30h' ($null -ne $v1.ageH -and $v1.ageH -le 30 -and ((@($v1.reasons) -join ';') -match 'commit refused') -and ((@($v1.reasons) -join ';') -notmatch 'has not run since')) (HbShow $v1)

    # ---- CLEAN TWIN: a night whose commit landed reads landed. Built from the real 2026-09-10 session; see its header.
    $tw0 = [datetime]'2026-09-10T21:30:02'
    $v2 = Test-RunLogVerdict -Text $fxTwin -Name 'graph-nightly' -MaxAgeHours 30 -Now $tw0.AddHours(13)
    HbCase 'CLEAN TWIN a committed night (rc=0, "committed 23 file(s) and pushed") reads landed, with its start and outcome' ($v2.landed -and $v2.outcome -eq 'committed' -and $v2.rc -eq 0 -and $v2.started -eq $tw0) (HbShow $v2)
    $v9 = Test-RunLogVerdict -Text ($fxTwin -replace '(?m)^graph-nightly: committed 23 file\(s\) and pushed', 'graph-nightly: nothing changed under its owned paths') -Name 'graph-nightly' -MaxAgeHours 30 -Now $tw0.AddHours(13)
    HbCase 'CLEAN TWIN a night with nothing to commit reads landed' ($v9.landed -and $v9.outcome -eq 'nothing') (HbShow $v9)

    # ---- MUST FIRE, THE PRODUCER STOPPED: that same clean night read 37 h later, which is a lost night at 10:30.
    $v3 = Test-RunLogVerdict -Text $fxTwin -Name 'graph-nightly' -MaxAgeHours 30 -Now $tw0.AddHours(37)
    HbCase 'MUST FIRE  a clean last run that is 37h old pages on age alone - silence is not health' ((-not $v3.landed) -and $v3.outcome -eq 'committed' -and $v3.rc -eq 0 -and ((@($v3.reasons) -join ';') -match 'has not run since')) (HbShow $v3)

    # ---- MUST FIRE, the other ways a run does not land. Each is the twin with ONE thing changed, and each change is
    #      asserted to have happened, so a fixture edit that stops matching turns the case red instead of green.
    $killed = (@($fxTwin -split "\r?\n") | Where-Object { $_ -notmatch '^--- run-log: finished ' }) -join "`n"
    $v4 = Test-RunLogVerdict -Text $killed -Name 'graph-nightly' -MaxAgeHours 30 -Now $tw0.AddHours(13)
    # The REASON is asserted, not only the verdict (mutation probe, 2026-09-11): with the no-stamp branch deleted, the
    # rc -ne 0 branch below it still fires on a null rc and pages "it stamped rc=", which is a page that lies.
    HbCase 'MUST FIRE  a run killed before Done() (no rc stamp) pages, even with a committed verdict line, and SAYS there was no stamp' ((-not $v4.landed) -and $null -eq $v4.rc -and $v4.outcome -eq 'committed' -and ((@($v4.reasons) -join ';') -match 'no rc stamp') -and ((@($v4.reasons) -join ';') -notmatch 'stamped rc=')) (HbShow $v4)
    $held = ((@($fxTwin -split "\r?\n") | Where-Object { -not $_.StartsWith('graph-nightly: ') }) -join "`n") -replace 'rc=0 ---', 'rc=3 ---'
    $v5 = Test-RunLogVerdict -Text $held -Name 'graph-nightly' -MaxAgeHours 30 -Now $tw0.AddHours(13)
    HbCase 'MUST FIRE  a held card (rc=3, the chain never reached its commit) pages' ((-not $v5.landed) -and $v5.rc -eq 3 -and $v5.outcome -eq 'unknown' -and $v5.verdict -eq '') (HbShow $v5)
    $v6 = Test-RunLogVerdict -Text ($fxTwin -replace 'rc=0 ---', 'rc=1 ---') -Name 'graph-nightly' -MaxAgeHours 30 -Now $tw0.AddHours(13)
    HbCase 'MUST FIRE  rc=1 with a landed commit pages: a chain body that threw is not a good night' ((-not $v6.landed) -and $v6.rc -eq 1 -and $v6.outcome -eq 'committed') (HbShow $v6)
    $v7 = Test-RunLogVerdict -Text ($fxTwin -replace '(?m)^graph-nightly: committed 23 file\(s\) and pushed', 'graph-nightly: the commit did something nobody has a word for') -Name 'graph-nightly' -MaxAgeHours 30 -Now $tw0.AddHours(13)
    HbCase 'MUST FIRE  a verdict the classifier does not recognise is not a landed run' ((-not $v7.landed) -and $v7.outcome -eq 'unknown' -and $v7.verdict -match 'nobody has a word') (HbShow $v7)
    $v8 = Test-RunLogVerdict -Text ($fxTwin -replace '(?m)^graph-nightly: committed', 'harvest-crawl: committed') -Name 'graph-nightly' -MaxAgeHours 30 -Now $tw0.AddHours(13)
    HbCase 'MUST FIRE  another lane''s committed verdict does not land this lane' ((-not $v8.landed) -and $v8.verdict -eq '' -and ((@($v8.reasons) -join ';') -match "no commit verdict under the name 'graph-nightly'")) (HbShow $v8)
    $v10 = Test-RunLogVerdict -Text '' -Name 'graph-nightly' -MaxAgeHours 30 -Now $tw0
    HbCase 'MUST FIRE  an empty transcript is not a landed run' ((-not $v10.landed) -and ((@($v10.reasons) -join ';') -match 'no transcript session')) (HbShow $v10)

    # ---- WHICH FILE. The skip path writes a later-dated transcript that always says rc=0.
    $sel = Get-NewestRunLogName -Names @('graph-nightly-2026-09-09.log', 'graph-nightly-skipped-2026-09-11.log', 'graph-nightly-status.json', 'graph-nightly-2026-09-10.log', 'graph-nightly-2026-09-06.log') -Name 'graph-nightly'
    HbCase 'MUST FIRE  the newest REAL run is chosen by the date in its name; graph-nightly-skipped-2026-09-11.log does not win' ($sel -eq 'graph-nightly-2026-09-10.log') $sel
    $none = Get-NewestRunLogName -Names @('graph-nightly-skipped-2026-09-11.log', 'graph-nightly-status.json') -Name 'graph-nightly'
    HbCase 'MUST FIRE  only skip transcripts resolves to no run at all, which the live reader turns into a page' ($none -eq '') $none

    # ---- THE JOIN. LIVE-TWIN, both reads, on purpose: the registry row and nightly.ps1 must name the same transcript
    #      and the same committer. A rename on either side would leave this check reading a file that no longer
    #      grows, or a prefix no verdict carries, and it would page every morning for the wrong reason or never.
    $reg = Read-JsonFile (Join-Path $root 'expected-automations.json')
    $rows = @(@($reg.windows_tasks) | Where-Object { [string]$_.name -eq 'TC Graph Nightly Matching' })
    $decl = if ($rows.Count -eq 1 -and $rows[0].PSObject.Properties['run_log']) { [string]$rows[0].run_log } else { '' }
    HbCase 'MUST FIRE  the TC Graph Nightly Matching row declares run_log, or this check is disarmed for the lane it was written for' ($decl -ne '') $decl
    $leaf = if ($decl) { Split-Path ($decl -replace '/', '\') -Leaf } else { '' }
    $parent = if ($decl) { Split-Path ($decl -replace '/', '\') -Parent } else { '' }
    $nightSrc = [IO.File]::ReadAllText((Join-Path $repo 'graph\pipeline\nightly.ps1'))
    HbCase 'MUST FIRE  nightly.ps1 opens its run transcript under the row''s run_log name, in grocery\out\logs' ($leaf -and $parent -eq 'grocery\out\logs' -and $nightSrc.Contains("Start-RunLog -Name '" + $leaf + "' -OutDir (Join-Path `$grocery 'out')")) ($decl)
    HbCase 'MUST FIRE  nightly.ps1 commits under that same name, so its verdict line carries the prefix this check reads' ($leaf -and $nightSrc.Contains("-Name '" + $leaf + "' -Push")) ($decl)

    # ---- THE WIRING. Needles built by concatenation, so these lines are not their own matches.
    $hbSrc = [IO.File]::ReadAllText($PSCommandPath)
    HbCase 'MUST FIRE  the task loop reads the run-log verdict for a row that declares one' ($hbSrc.Contains('Get-RunLog' + 'Verdict -RunLog $rlDecl'))
    HbCase 'MUST FIRE  a nonzero result whose run did not land is not excused as "work landed" by a fresh proves output' ($hbSrc.Contains('if ($rv -and ' + '-not $rv.landed)'))
  } catch { HbCase ('a case threw: ' + $_.Exception.Message) $false }

  Write-Output ("health-heartbeat self-test: {0} case(s), {1} failed" -f $hbCases, $hbFail)
  if ($hbFail) { exit 1 }
  exit 0
}

# ---- Windows scheduled tasks (silent death = deleted / disabled / long-since-run) ----
foreach ($t in @($cfg.windows_tasks)) {
  $name = [string]$t.name
  $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
  if (-not $task) { $issues.Add("TASK MISSING: '$name' is not registered any more (deleted?) - $($t.why)"); continue }
  if ([string]$task.State -eq 'Disabled') { $issues.Add("TASK DISABLED: '$name' exists but is disabled - $($t.why)"); continue }
  $info = $task | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
  $res = if ($info) { [int64]$info.LastTaskResult } else { -1 }
  $last = if ($info -and $info.LastRunTime -and $info.LastRunTime.Year -gt 2000) { $info.LastRunTime } else { $null }
  if ($res -eq $TASK_NOT_YET_RUN -or -not $last) {
    if ($t.allow_pending) { $okLines.Add(("{0,-38} pending first run (OK)" -f $name)) }
    else { $issues.Add("TASK NEVER RAN: '$name' is scheduled but has never run - $($t.why)") }
    continue
  }
  $ageH = [math]::Round(($now - $last).TotalHours, 1)
  # RUN-LOG VERDICT (2026-09-11): a row that declares run_log is judged on its run's own transcript WHATEVER
  # LastTaskResult says (see the RUN-LOG-VERDICT block). Not while the task is mid-run, when its session is still open.
  $rv = $null
  $rlDecl = if ($t.PSObject.Properties['run_log'] -and $t.run_log) { [string]$t.run_log } else { '' }
  if ($rlDecl -and -not ([string]$task.State -eq 'Running' -or $res -eq $TASK_RUNNING)) {
    $rv = Get-RunLogVerdict -RunLog $rlDecl -RepoRoot $repo -MaxAgeHours ([double]$t.max_age_hours) -Now $now
  }
  # A task caught mid-run reports LastTaskResult 267009 (SCHED_S_TASK_RUNNING); that is alive, not failed.
  # This fires whenever the heartbeat's check races the watched task's own run (both scheduled 06:45).
  if ([string]$task.State -eq 'Running' -or $res -eq $TASK_RUNNING) { $okLines.Add(("{0,-38} currently running (OK)" -f $name)) }
  elseif ($ageH -gt [double]$t.max_age_hours) { $issues.Add(("TASK STALE: '{0}' last ran {1}h ago (> {2}h) - did its trigger stop? {3}" -f $name, $ageH, $t.max_age_hours, $t.why)) }
  elseif ($res -ne 0 -and $t.allow_nonzero_exit) {
    # SOME TASKS REPORT FINDINGS THROUGH THEIR EXIT CODE (2026-08-22). capture-watchdog exits 1 whenever it
    # has findings - that is it working, not dying - and it is also the script that runs THIS heartbeat, so
    # without this branch the heartbeat pages about the watchdog every single day the watchdog does its job,
    # permanently, from its first real finding. A task flagged here is still watched for STALE and for
    # NEVER RAN above; only the exit code stops being read as death.
    $okLines.Add(("{0,-38} result {1} (nonzero BY DESIGN - it reports findings that way)" -f $name, $res))
  }
  elseif ($res -ne 0) {
    # A nonzero exit is only a SILENT DEATH if the work also failed to land. When the registry names a
    # 'proves' output and that output is fresh AND was written by this run, the task's job got done (a
    # killed-at-the-end run, a battery stop, a retry that succeeded downstream) - report it, do not page it.
    # Without 'proves' nothing changes: a nonzero result pages. See Test-ProofLanded for why both halves.
    if ($rv -and -not $rv.landed) {
      # A fresh proves output must not print "work landed" for a run whose own transcript says it did not; the RUN DID
      # NOT LAND issue below pages it with the reason. graph-nightly's stamp is written BEFORE its commit.
    } else {
      $glob = if ($t.PSObject.Properties['proves'] -and $t.proves) { [string]$t.proves } else { '' }
      $v = Test-ProofLanded -ProvesGlob $glob -RepoRoot $repo -MaxAgeHours ([double]$t.max_age_hours) -LastRunTime $last -Now $now
      if ($v.fresh) { $okLines.Add(("{0,-38} result {1} BUT its output is {2}h fresh - work landed, not dead" -f $name, $res, $v.ageH)) }
      else { $issues.Add(("TASK FAILED: '{0}' last result {1} (nonzero) - {2}{3}" -f $name, $res, $t.why, $v.why)) }
    }
  }
  else { $okLines.Add(("{0,-38} ran {1}h ago, result 0" -f $name, $ageH)) }
  if ($rv) {
    $rvWhen = if ($null -ne $rv.started) { ([datetime]$rv.started).ToString('yyyy-MM-ddTHH:mm:ss') } else { 'an unknown time' }
    if ($rv.landed) { $okLines.Add(("{0,-38} run of {1} landed: commit {2}, rc=0 ({3})" -f $name, $rvWhen, $rv.outcome, $rv.file)) }
    else {
      $rvFile = if ($rv.file) { [string]$rv.file } else { 'no run transcript' }
      $issues.Add(("RUN DID NOT LAND: '{0}' run of {1} ({2}) - {3}. The task's LastTaskResult cannot show this: later repetitions overwrite it." -f $name, $rvWhen, $rvFile, (@($rv.reasons) -join '; ')))
    }
  }
}

# ---- REGISTRY DRIFT (2026-08-06): a task that exists on the machine but is in nobody's registry is invisible
# to every check above - it can die silently forever and nothing here notices, because this loop only walks
# what the JSON already lists. That is exactly how "SMP Daily Facebook Reel", "SMP Family Fare Term Sweep" and
# "SMP Friday Email (draft)" ran unwatched until they were found by hand. This catches the NEXT one.
$known = @(@($cfg.windows_tasks) | ForEach-Object { [string]$_.name })
foreach ($wt in @(@(Get-ScheduledTask -TaskName 'SMP *' -ErrorAction SilentlyContinue) + @(Get-ScheduledTask -TaskName 'TC *' -ErrorAction SilentlyContinue))) {
  if ($known -notcontains [string]$wt.TaskName) {
    $issues.Add(("TASK UNWATCHED: '{0}' is registered in Windows Task Scheduler but missing from expected-automations.json - nothing checks whether it still runs. Add it to windows_tasks." -f $wt.TaskName))
  }
}

# ---- QUEUES: work that is waiting, and how long it has waited (2026-09-07) ------------------------
# The three kinds above answer "did the producer run" and "is the artefact fresh". A QUEUE is neither:
# when a drain does not run it produces no stale artefact, it produces NOTHING, and the pending set
# grows in silence. That is how 120 corrected recipe cards sat unshipped for five days on 2026-09-02
# with every component working - no failed task, no aged file, nothing for this script to see.
#
# grocery\queue-depth.ps1 owns the per-queue probes so this stays generic and the registry stays data.
# A queue that could not be measured is UNKNOWN and is reported; it is never allowed to read as empty.
if (@($cfg.queues).Count) {
  $qd = Join-Path $PSScriptRoot 'queue-depth.ps1'
  if (-not (Test-Path $qd)) {
    $issues.Add('QUEUES UNWATCHED: expected-automations.json declares queues and grocery\queue-depth.ps1 is missing, so none of them was measured.')
  } else {
    try {
      $qrows = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $qd -Json | ConvertFrom-Json)
      foreach ($r in $qrows) {
        if ([string]$r.verdict -eq 'STUCK') {
          $issues.Add(("QUEUE STUCK: {0} - {1}. What that costs: {2}" -f $r.name, $r.line, $r.cost_if_undrained))
        } elseif ([string]$r.verdict -eq 'unknown') {
          $issues.Add(("QUEUE UNMEASURED: {0} - {1}. An unmeasured queue is not an empty one." -f $r.name, $r.line))
        }
      }
    } catch {
      $issues.Add(("QUEUES UNMEASURED: queue-depth.ps1 could not be run ({0}) - no queue was checked, which is not the same as every queue being empty." -f $_.Exception.Message))
    }
  }
}

# ---- critical output files (silent death = missing / stale) ----
function Check-Age($path, $maxH, $why, $label) {
  if (-not (Test-Path $path)) { $issues.Add("OUTPUT MISSING: $label ($path) does not exist - $why"); return }
  $ageH = [math]::Round(($now - (Get-Item $path).LastWriteTime).TotalHours, 1)
  if ($ageH -gt [double]$maxH) { $issues.Add(("OUTPUT STALE: {0} is {1}h old (> {2}h) - the job that writes it stopped? {3}" -f $label, $ageH, $maxH, $why)) }
  else { $okLines.Add(("{0,-38} {1}h fresh" -f $label, $ageH)) }
}
# A row that declares currency_field proves its currency from its own CONTENT and the mtime rule is not
# applied to it; every other row takes exactly the path it always took. See the CONTENT-CURRENCY block above
# for why this is opt-in and why widening max_age_hours or touching the file are both the wrong answer.
$boardWeek = Get-BoardWeek $repo
foreach ($f in @($cfg.output_files)) {
  $fPath  = Join-Path $repo ([string]$f.path)
  $fLabel = [IO.Path]::GetFileName([string]$f.path)
  $cc = Test-ContentCurrency -Row $f -Path $fPath -BoardWeek $boardWeek -Now $now
  if (-not $cc.applies) { Check-Age $fPath $f.max_age_hours $f.why $fLabel; continue }
  if ($cc.current) { $okLines.Add(("{0,-38} {1}" -f $fLabel, $cc.detail)) }
  else { $issues.Add(("OUTPUT NOT CURRENT: {0} {1} - {2}" -f $fLabel, $cc.detail, $f.why)) }
}
foreach ($g in @($cfg.output_globs)) {
  $newest = Get-ChildItem (Join-Path $repo ([string]$g.glob)) -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if (-not $newest) { $issues.Add("OUTPUT MISSING: no file matches $($g.glob) - $($g.why)") }
  else { Check-Age $newest.FullName $g.max_age_hours $g.why $newest.Name }
}

# EXTERNAL_FILES - outputs of automations that run on this box but write OUTSIDE the repo (2026-09-08,
# backlog I78). The recall hooks are the case that forced it: they are the estate's newest automated
# loop, they write only under %USERPROFILE%\.claude, and they appeared in no watch list at all, so the
# whole loop could stop firing and nothing anywhere would go red.
#
# WHY A SEPARATE ARRAY RATHER THAN A PATH IN output_files. Every other row is resolved with
# `Join-Path $repo`, and Join-Path against an absolute second argument produces `C:\repo\C:\Users\...`
# - a path that never matches, so the row would read as a permanent MISSING and be muted within a week.
# These rows are resolved with ExpandEnvironmentVariables and used as given.
#
# THEY ARE NOT COUNTED IN $declared ON PURPOSE. $declared refuses to grade an empty exam, and the exam
# it is protecting is the repo's own chain; a registry that lost windows_tasks but kept these must
# still report BLIND rather than grading two log files and calling the estate healthy.
foreach ($x in @($cfg.external_files)) {
  $xPath  = [Environment]::ExpandEnvironmentVariables([string]$x.path)
  $xLabel = if ($x.label) { [string]$x.label } else { [IO.Path]::GetFileName($xPath) }
  if (-not (Test-Path -LiteralPath $xPath)) {
    $issues.Add(("EXTERNAL OUTPUT MISSING: {0} does not exist at {1} - {2}" -f $xLabel, $xPath, $x.why))
    continue
  }
  Check-Age $xPath $x.max_age_hours $x.why $xLabel
}

# ---- report ----
Write-Output ("health-heartbeat  " + $now.ToString('yyyy-MM-dd HH:mm'))
$okLines | ForEach-Object { Write-Output ("  ok    " + $_) }
if ($issues.Count -eq 0) { Write-Output ("HEALTHY: {0} automation(s)/output(s) all fresh." -f $okLines.Count); exit 0 }
Write-Output ("SILENT-DEATH / STALE: {0} issue(s):" -f $issues.Count)
$issues | ForEach-Object { Write-Output ("  !! " + $_) }
if ($Alert) {
  $sig = [BitConverter]::ToString([Security.Cryptography.MD5]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes((($issues | Sort-Object) -join ';')))) -replace '-',''
  $sigF = Join-Path $root 'out\health-heartbeat.sig'
  $prev = if (Test-Path $sigF) { (Get-Content $sigF -Raw).Trim() } else { '' }
  if ($sig -ne $prev) {
    try {
      Send-Alert -Subject ("Automation silent-death: " + $issues.Count + " issue(s)") -Body ("health-heartbeat.ps1 found automations/outputs that stopped WITHOUT a loud failure (a task got deleted/disabled or an output went stale). This is the class the GitHub-failure email + local-watchdog do not cover. Issues: " + (($issues | Select-Object -First 12) -join ' | ') + ". Fix the task/trigger or the job that writes the output.") | Out-Null
      if ($LASTEXITCODE -eq 0) { Set-Content $sigF -Value $sig -Encoding ASCII }
    } catch {}
  }
}
exit 2
