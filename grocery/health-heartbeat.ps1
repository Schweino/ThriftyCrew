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
    - each critical output file / glob exists and is fresher than max_age_hours.

  Exit 0 = all healthy, 2 = one or more silently dead/stale. -Alert emails Brad (de-duped by signature so
  a persistent outage is one email). Meant to run INDEPENDENTLY of the pipeline it watches - it is invoked
  from local-watchdog.ps1 (its own WakeToRun task), so a dead main pipeline cannot suppress its own alarm.
#>
param([switch]$Alert)
$ErrorActionPreference = 'Continue'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
# Alerts go out through Send-Alert (alert-lib.ps1), never as `powershell -File send-alert.ps1 -Body $long`:
# Windows refuses to start a process whose command line passes 32767 chars, so an oversized body did not
# arrive truncated - it did not arrive at all, and the launch error read like the CHECK had crashed. Three
# consecutive guard-blind days went unpaged that way on 2026-08-03/04/05. See alert-lib.ps1.
. (Join-Path $root 'alert-lib.ps1')
$repo = Split-Path $root -Parent
$now  = Get-Date
$cfg  = Get-Content (Join-Path $root 'expected-automations.json') -Raw | ConvertFrom-Json
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
foreach ($f in @($cfg.output_files)) { Check-Age (Join-Path $repo ([string]$f.path)) $f.max_age_hours $f.why ([IO.Path]::GetFileName([string]$f.path)) }
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
