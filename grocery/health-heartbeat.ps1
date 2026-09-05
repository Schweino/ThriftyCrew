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
      and it is judged on the currency stamp inside it instead (see the CONTENT-CURRENCY block).

  Exit 0 = all healthy, 2 = one or more silently dead/stale. -Alert emails Brad (de-duped by signature so
  a persistent outage is one email). Meant to run INDEPENDENTLY of the pipeline it watches - it is invoked
  from local-watchdog.ps1 (its own WakeToRun task), so a dead main pipeline cannot suppress its own alarm.
#>
param([switch]$Alert)
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$ErrorActionPreference = 'Continue'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
# Alerts go out through Send-Alert (alert-lib.ps1), never as `powershell -File send-alert.ps1 -Body $long`:
# Windows refuses to start a process whose command line passes 32767 chars, so an oversized body did not
# arrive truncated - it did not arrive at all, and the launch error read like the CHECK had crashed. Three
# consecutive guard-blind days went unpaged that way on 2026-08-03/04/05. See alert-lib.ps1.
. (Join-Path $root 'alert-lib.ps1')
$repo = Split-Path $root -Parent
$now  = Get-Date
$cfg  = Read-JsonFile (Join-Path $root 'expected-automations.json')
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
  try { $doc = Get-Content $Path -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $doc = $null }
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
    $glob = if ($t.PSObject.Properties['proves'] -and $t.proves) { [string]$t.proves } else { '' }
    $v = Test-ProofLanded -ProvesGlob $glob -RepoRoot $repo -MaxAgeHours ([double]$t.max_age_hours) -LastRunTime $last -Now $now
    if ($v.fresh) { $okLines.Add(("{0,-38} result {1} BUT its output is {2}h fresh - work landed, not dead" -f $name, $res, $v.ageH)) }
    else { $issues.Add(("TASK FAILED: '{0}' last result {1} (nonzero) - {2}{3}" -f $name, $res, $t.why, $v.why)) }
  }
  else { $okLines.Add(("{0,-38} ran {1}h ago, result 0" -f $name, $ageH)) }
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
