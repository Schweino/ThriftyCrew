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
$repo = Split-Path $root -Parent
$now  = Get-Date
$cfg  = Get-Content (Join-Path $root 'expected-automations.json') -Raw | ConvertFrom-Json
$issues = New-Object System.Collections.Generic.List[string]
$okLines = New-Object System.Collections.Generic.List[string]
$TASK_NOT_YET_RUN = 267011   # 0x00041303 SCHED_S_TASK_HAS_NOT_RUN

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
  if ($ageH -gt [double]$t.max_age_hours) { $issues.Add(("TASK STALE: '{0}' last ran {1}h ago (> {2}h) - did its trigger stop? {3}" -f $name, $ageH, $t.max_age_hours, $t.why)) }
  elseif ($res -ne 0) { $issues.Add(("TASK FAILED: '{0}' last result {1} (nonzero) - {2}" -f $name, $res, $t.why)) }
  else { $okLines.Add(("{0,-38} ran {1}h ago, result 0" -f $name, $ageH)) }
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
      & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'send-alert.ps1') -Subject ("Automation silent-death: " + $issues.Count + " issue(s)") -Body ("health-heartbeat.ps1 found automations/outputs that stopped WITHOUT a loud failure (a task got deleted/disabled or an output went stale). This is the class the GitHub-failure email + local-watchdog do not cover. Issues: " + (($issues | Select-Object -First 12) -join ' | ') + ". Fix the task/trigger or the job that writes the output.") | Out-Null
      if ($LASTEXITCODE -eq 0) { Set-Content $sigF -Value $sig -Encoding ASCII }
    } catch {}
  }
}
exit 2
