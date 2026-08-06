<#
  run-daily-local.ps1 - LOCAL-PRIMARY daily grocery pipeline (2026-07-23).

  WHY: the cloud (daily.yml) ran this on a Windows GitHub runner at 2x billing, ~78 billed min/day
  (~2,300/mo) against a 2,000-min free-tier cap. Brad's PC is already awake every morning for the
  browser agents, so the pipeline now runs HERE for free and the cloud is the BACKUP: its cron moved
  to 16:00 UTC and its gate stands down whenever a bot commit already landed (i.e. whenever this ran).
  The heartbeat watches bot commits regardless of who made them, so coverage is unchanged.

  Mirrors daily.yml's hardened commit step, with the one difference that MATTERS locally:
  *** THE CLOUD RUNS git add -A IN A THROWAWAY CLONE; THIS SHARES BRAD'S REAL WORKING TREE. ***
  A blind add -A here would sweep half-finished code edits into a bot commit and PUSH them. So this
  wrapper stages ONLY pipeline-owned data paths (the exact set real bot commits touch - verified from
  git history 2026-07-23): grocery/out, public, and the grocery-root data/log files listed below.
  Anything else the pipeline may someday write stays uncommitted here and is picked up by the cloud
  backup's clean-clone add -A - never lost, never mixed with human WIP.

  Scheduled task: "SMP Grocery Daily Pipeline (local)" daily 8:30am, WakeToRun + StartWhenAvailable
  (fires late if the PC was asleep at 8:30; the gate below makes any double-fire a no-op).
  Alerts: runs WITHOUT -NoAlert (this machine holds the Gmail token; send-alert's per-type daily
  de-dup caps the volume). The feed-freshness assert emails instead of failing a CI job.
#>
$ErrorActionPreference = 'Continue'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
# Alerts go out through Send-Alert (alert-lib.ps1), never as `powershell -File send-alert.ps1 -Body $long`:
# Windows refuses to start a process whose command line passes 32767 chars, so an oversized body did not
# arrive truncated - it did not arrive at all, and the launch error read like the CHECK had crashed. Three
# consecutive guard-blind days went unpaged that way on 2026-08-03/04/05. See alert-lib.ps1.
. (Join-Path $root 'alert-lib.ps1')
$repo = Split-Path -Parent $root
$log  = Join-Path $root 'local-daily-log.txt'
# a locked log file must never kill the run it is logging - see the note in check-ad-cycles.ps1 (2026-07-28).
# BUT IT MUST NOT SILENCE IT EITHER (2026-07-30). Some process took an exclusive handle on
# local-daily-log.txt at 2026-07-25T08:30:03, mid-run, and never let go. Add-Content has failed on every
# retry every day since; the fallback below was Write-Host, which in a wscript/scheduled-task run goes
# NOWHERE. So the pipeline kept working and committing (bot commits landed 07-26 through 07-29) while the one
# file that answers "did the 8:30 job run, and how far did it get" froze on the line "running
# check-ad-cycles" - five days of a job that looked, from its own log, like it hung at the first stage.
# A log nobody can write to is a job nobody can audit. Fall back to a DATED sidecar the run can always
# create, name the failure in it, and let the once-per-day alert say so out loud.
function Log($m) {
  $line = ("[" + (Get-Date).ToString('s') + "] ") + $m
  for ($i = 0; $i -lt 5; $i++) { try { Add-Content -Path $log -Value $line -ErrorAction Stop; return } catch { Start-Sleep -Milliseconds 120 } }
  # primary log unavailable: use a sidecar named for today, so a locked log costs one file, not the record
  if (-not $script:logFallback) {
    $script:logFallback = Join-Path $root ('local-daily-log.LOCKED-' + (Get-Date -Format 'yyyy-MM-dd') + '.txt')
    try {
      Add-Content -Path $script:logFallback -Value ("[" + (Get-Date).ToString('s') + "] local-daily-log.txt is LOCKED by another process - this run's log lives here. Find the holder (handle.exe / Get-Process) and release it, or the primary log stays frozen.") -ErrorAction Stop
      Send-Alert -Subject 'Grocery: local-daily-log.txt is locked - the daily pipeline cannot log' -Body ("run-daily-local.ps1 could not append to grocery\local-daily-log.txt (exclusive lock held by another process). The run itself continues and the board is unaffected, but the wrapper's audit trail is going to " + $script:logFallback + " instead. This exact lock sat unnoticed from 2026-07-25 to 2026-07-30 because the old fallback was Write-Host, which a scheduled task discards. Find and kill the holding process. Do NOT simply delete the sidecar: it holds the only trail of this run. The next run that can write the primary log folds it back in and clears it by itself (SIDECAR RECOVERY block, 2026-08-02); merge by hand only if you need it sooner.") | Out-Null
    } catch { }
  }
  try { Add-Content -Path $script:logFallback -Value $line -ErrorAction Stop } catch { try { Write-Host ('[log locked, not written] ' + $line) } catch {} }
}

# ---- SIDECAR RECOVERY: a locked log costs one file, not the record - but only if someone puts the -------
# record BACK. Until 2026-08-02 nothing did: the alert told a human to "delete the sidecar", which throws
# away the only trail of the run it describes, and the 08-02 sidecar had to be folded in by hand. So before
# this run writes a line, fold any PRIOR day's LOCKED-* sidecar into the primary log and clear it. Runs
# before the rotation block on purpose: on the 1st, last month's recovered lines belong in last month's
# archived log. TODAY's sidecar is deliberately left alone - a same-day double-fire may still be appending
# to it, and tomorrow's run collects it. Append is retried the same way Log does; if the primary log is
# still locked, nothing is deleted and the sidecar simply waits for a run that can write. Non-fatal.
# >>> SIDECAR-RECOVERY (self-test extracts between these sentinels; see test-log-sidecar-recovery.ps1)
$script:sidecarsMerged = @()
try {
  $todayStamp = (Get-Date -Format 'yyyy-MM-dd')
  foreach ($sc in @(Get-ChildItem (Join-Path $root 'local-daily-log.LOCKED-*.txt') -ErrorAction SilentlyContinue | Sort-Object Name)) {
    if ($sc.BaseName -match 'LOCKED-(\d{4}-\d{2}-\d{2})$') { $scDay = $Matches[1] } else { continue }
    if ($scDay -ge $todayStamp) { continue }
    $scBody = @(Get-Content $sc.FullName -ErrorAction SilentlyContinue)
    if ($scBody.Count -eq 0) { Remove-Item $sc.FullName -Force -ErrorAction SilentlyContinue; continue }
    $scMark = ("[" + (Get-Date).ToString('s') + "] --- recovered from " + $sc.Name + " (" + $scBody.Count + " lines): the primary log was locked during that run, so its trail went to the lock sidecar. Those lines are folded back here in order; the sidecar is removed. ---")
    $scOk = $false
    for ($i = 0; $i -lt 5; $i++) { try { Add-Content -Path $log -Value (@($scMark) + $scBody) -ErrorAction Stop; $scOk = $true; break } catch { Start-Sleep -Milliseconds 120 } }
    if ($scOk) { Remove-Item $sc.FullName -Force -ErrorAction SilentlyContinue; $script:sidecarsMerged += $sc.Name }
  }
} catch { }
# <<< SIDECAR-RECOVERY
if ($script:sidecarsMerged.Count) { Log ('sidecar recovery: merged and cleared ' + ($script:sidecarsMerged -join ', ')) }

# ---- LOG ROTATION (1st of the month): the pipeline logs grow forever and every line rides every bot ----
# commit. Roll last month's logs into a gitignored archive; git history keeps the old content anyway.
if ((Get-Date).Day -eq 1) {
  $arch = Join-Path $root 'logs-archive'
  if (-not (Test-Path $arch)) { New-Item -ItemType Directory -Path $arch -Force | Out-Null }
  $stamp = (Get-Date).AddMonths(-1).ToString('yyyy-MM')
  # triage plans accumulate one (or three) per day and are pure history once shipped - the fixes they
  # describe are in the commits. Archive last month's alongside the logs; git keeps the content either way.
  try {
    $tp = Join-Path $root 'triage-plans'
    if (Test-Path $tp) {
      $tpArch = Join-Path $arch 'triage-plans'
      if (-not (Test-Path $tpArch)) { New-Item -ItemType Directory -Path $tpArch -Force | Out-Null }
      $cutM = (Get-Date).AddMonths(-1).ToString('yyyy-MM')
      $moved = 0
      foreach ($pf in @(Get-ChildItem (Join-Path $tp 'plan-*.json') -ErrorAction SilentlyContinue)) {
        if ($pf.BaseName -match '^plan-(\d{4}-\d{2})' -and $Matches[1] -le $cutM) { Move-Item $pf.FullName $tpArch -Force -ErrorAction SilentlyContinue; $moved++ }
      }
      if ($moved) { Log ("triage-plan rotation: archived $moved plan file(s) to logs-archive\triage-plans") }
    }
  } catch { Log ('triage-plan rotation threw: ' + $_.Exception.Message) }
  foreach ($lf in @('ad-cycle-log.txt', 'alert-log.txt', 'local-daily-log.txt', 'ff-sweep-log.txt')) {
    $src = Join-Path $root $lf
    $dst = Join-Path $arch ($lf -replace '\.txt$', "-$stamp.txt")
    if ((Test-Path $src) -and -not (Test-Path $dst)) { Move-Item $src $dst -Force -ErrorAction SilentlyContinue }
  }
  # ---- OUT RETENTION: daily candidates-*.json snapshots pile up in out\ forever. Keep 30 days hot, ----
  # park older ones in out\archive (gitignored), drop archived files after 120 days. Non-fatal by design.
  try {
    $outDir = Join-Path $root 'out'; $outArch = Join-Path $outDir 'archive'
    if (-not (Test-Path $outArch)) { New-Item -ItemType Directory -Path $outArch -Force | Out-Null }
    $aged = @(Get-ChildItem (Join-Path $outDir 'candidates-*.json') -ErrorAction SilentlyContinue |
      Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) })
    $aged | Move-Item -Destination $outArch -Force -ErrorAction SilentlyContinue
    $old = @(Get-ChildItem $outArch -File -ErrorAction SilentlyContinue |
      Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-120) })
    $old | Remove-Item -Force -ErrorAction SilentlyContinue
    Log ("out-retention: archived " + $aged.Count + ", purged " + $old.Count)
  } catch { Log ("out-retention threw: " + $_.Exception.Message) }
  # monthly off-Ghost content backup (read-only; see ghost-export.ps1). Non-fatal: a backup hiccup must
  # never block the day's prices.
  try { & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'ghost-export.ps1') 2>&1 | ForEach-Object { Log ("ghost-export: " + $_) } } catch { Log ("ghost-export threw: " + $_.Exception.Message) }
}

# Did the CLOUD side fail? Cloud workflow failures email Brad via the Worker relay, which bypasses the local
# triage queue - this check routes them through send-alert so the triage agent owns them too (2026-07-25,
# "no issue email waits for a human"). Non-fatal and fails open: no credential / no network just logs.
try { & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'check-cloud-runs.ps1') 2>&1 | ForEach-Object { Log ("cloud-runs: " + $_) } } catch { Log ("check-cloud-runs threw: " + $_.Exception.Message) }

# ---- LOCK: never two of these at once (StartWhenAvailable + a manual run could overlap) ----------
$lock = Join-Path $env:LOCALAPPDATA 'smp-daily-local.lock'
if (Test-Path $lock) {
  $age = (Get-Date) - (Get-Item $lock).LastWriteTime
  if ($age.TotalHours -lt 2) { Log "SKIP: another run holds the lock ($([int]$age.TotalMinutes) min old)"; exit 0 }
  Log "stale lock ($([int]$age.TotalHours)h) - taking over"
}
Set-Content -Path $lock -Value (Get-Date).ToString('s')
try {

# ---- GATE: once-daily by definition (same rule as the cloud). If the bot already committed today ----
# (an earlier local run, a manual cloud dispatch, or the cloud backup), a second pass would only
# re-throttle Freshop and re-fire alerts. Manual override: set SMP_FORCE=1 in the environment.
$today = (Get-Date -Format 'yyyy-MM-dd')
$last = (git -C $repo log --author="smp-pipeline-bot" -1 --format=%cd --date=format:'%Y-%m-%d' 2>$null)
if ($last -eq $today -and $env:SMP_FORCE -ne '1') {
  Log "STAND DOWN: the pipeline already committed today ($last). Nothing to do."
  exit 0
}

# ---- GATE 2: is the WEEKLY browser refresh in flight? (2026-07-30) -------------------------------
# Measured 2026-07-29: this job pulled at 08:31:06 and ran to 09:17:48 (46m42s) while the weekly agent's
# -Phase publish ran 08:46:24-08:51:39 on the same out\ files, writing verified-2026-07-29.json and
# PUBLISHING the live board. This job then graded that board with its own guards (09:14:18 GUARDS FAILED),
# started a link auto-repair and republish on top of it (09:14:23), and threw all 46 minutes away.
# GATE 1 above cannot see the weekly at all: the weekly ends in push-data.ps1, which commits under Brad's
# own identity, so "the bot committed today" is false the whole time the weekly is running.
# STANDING DOWN IS NOT A LOST DAY, but be precise about why (corrected by the post-batch review
# 2026-07-30 - the first version of this comment claimed the backup runs "hours after the weekly is done",
# and that is false). daily.yml fires at 16:00 UTC = 11:00 CDT, which on 2026-07-29 was INSIDE the weekly
# window (that run's phases spanned 07:17 to 19:07). So the backup is not guaranteed to land after the
# weekly finishes. What actually makes standing down safe is narrower and still true: the backup runs in a
# CLEAN CLONE, so it cannot collide with the local tree the weekly is editing, and it re-derives the board
# from whatever the weekly has pushed by then. If it lands mid-weekly it may publish a board the weekly
# later supersedes - wasteful, not wrong - and the weekly's own publish phase is the authority either way.
# The real cost of standing down is therefore at most one redundant cloud run, never lost prices.
# THE LOCK EXPIRES ON ITS OWN TERMS: weekly-run-lock.ps1 stamps expires INTO the file and reads it back, so
# a weekly that crashes costs at most one daily tick and never disables this job. exit 3 = could-not-read,
# and we run anyway (fail open). SMP_FORCE=1 overrides, same as GATE 1.
$wl = & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'weekly-run-lock.ps1') 2>&1 | ForEach-Object { [string]$_ }
$wlRc = $LASTEXITCODE
@($wl) | ForEach-Object { Log ("weekly-lock: " + $_) }
if ($wlRc -eq 2 -and $env:SMP_FORCE -ne '1') {
  Log "STAND DOWN: the weekly browser refresh holds grocery\out. Not starting a second full pipeline on the same files; the 16:00 UTC cloud backup covers today."
  exit 0
}
if ($wlRc -eq 0 -and (@($wl) -match 'STALE')) {
  # debris from a weekly that never reached a successful -Phase links: reported above, now swept, so the
  # same dead lock is not re-reported every morning for the rest of its life.
  & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'weekly-run-lock.ps1') -Release 2>&1 | ForEach-Object { Log ("weekly-lock: " + $_) }
}

# ---- SYNC: build on the latest (the browser agents push their data before 8:30) ------------------
Log "start: syncing repo"
# --autostash pops on success and SILENTLY LEAVES the stash when the pop conflicts: git prints one
# warning line into a log nobody reads, and the run continues green. Six had piled up by 2026-08-04
# (back to 07-24), each parking local edits to v2-perserving / free-rotation / costed / recipes-db
# where no guard looks. Count the entries instead of trusting the log line.
$stashBefore = @(git -C $repo stash list).Count
git -C $repo pull --rebase --autostash origin main 2>&1 | ForEach-Object { Log ("pull: " + $_) }
$stashAfter = @(git -C $repo stash list).Count
if ($stashAfter -gt $stashBefore) {
  $msg = "git pull --rebase --autostash could not restore local changes: " +
         "$($stashAfter - $stashBefore) stash entry left behind, $stashAfter total. " +
         "Local edits are parked, not lost. Inspect with: git -C $repo stash list, " +
         "then git stash show -p on the newest entry."
  Log ("ALERT: " + $msg)
  Send-Alert `
      -Subject 'Daily run: autostash not restored' -Body $msg 2>&1 | ForEach-Object { Log ("alert: " + $_) }
}

# ---- RUN the pipeline (WITH alerts - send-alert's per-type daily gate caps the volume) ------------
Log "running check-ad-cycles"
& powershell -ExecutionPolicy Bypass -File (Join-Path $root 'check-ad-cycles.ps1') 2>&1 | Out-Null
Log ("check-ad-cycles exit " + $LASTEXITCODE)

# ---- COMMIT pipeline-owned paths ONLY, as the bot (identity via -c flags: never touches Brad's ----
# global git config). Stages mods+deletions+untracked under each path; paths filtered to existing.
$paths = @('grocery/out', 'public',
           'grocery/ad-cycle-log.txt', 'grocery/alert-log.txt', 'grocery/local-daily-log.txt',
           'grocery/ff-sweep-log.txt',
           'grocery/ad-schedule.json', 'grocery/price-history.json', 'grocery/product-urls.json',
           'grocery/sale-windows.json') | Where-Object { Test-Path (Join-Path $repo $_) }
# alert-sent-*.txt rotate (created+deleted daily) - stage the pattern only if any exist or were deleted
git -C $repo add -A -- 'grocery/alert-sent-*.txt' 2>$null
git -C $repo add -A -- $paths 2>&1 | ForEach-Object { Log ("add: " + $_) }
git -C $repo diff --cached --quiet
if ($LASTEXITCODE -eq 0) { Log "no pipeline changes to commit"; exit 0 }
git -C $repo -c user.name="smp-pipeline-bot" -c user.email="actions@users.noreply.github.com" `
  commit -m "Daily pipeline: refresh prices + feed ($today) [local]" 2>&1 | ForEach-Object { Log ("commit: " + $_) }

# ---- PUSH with the same conflict-survival the cloud learned on 2026-07-16: -X theirs prefers the --
# freshly regenerated derived files; abort on unresolvable so we NEVER strand a detached HEAD;
# rebase.autoStash carries any human WIP across the rebase untouched.
$pushed = $false
foreach ($attempt in 1..4) {
  git -C $repo fetch origin main 2>$null
  git -C $repo -c rebase.autoStash=true rebase -X theirs origin/main 2>&1 | ForEach-Object { Log ("rebase[$attempt]: " + $_) }
  if ($LASTEXITCODE -ne 0) { Log "rebase attempt $attempt conflicted; aborting (never detached)"; git -C $repo rebase --abort 2>$null; Start-Sleep -Seconds 10; continue }
  git -C $repo push origin HEAD:main 2>&1 | ForEach-Object { Log ("push[$attempt]: " + $_) }
  if ($LASTEXITCODE -eq 0) { $pushed = $true; Log "pushed on attempt $attempt"; break }
  Start-Sleep -Seconds 10
}
if (-not $pushed) {
  Log "PUSH FAILED after 4 attempts - the run's data is committed locally but NOT on main"
  try { Send-Alert -Subject "Grocery local pipeline could not push - $today" -Body "run-daily-local.ps1 committed today's refresh locally but could not push to main after 4 rebase attempts. The cloud backup will regenerate at 16:00 UTC, but check for a rebase conflict in C:\Codex\income (see grocery/local-daily-log.txt)." | Out-Null } catch {}
}

# ---- ASSERT the feed refreshed today (the cloud's red-X assert, as a deduped email) ---------------
try {
  $feed = Get-Content (Join-Path $repo 'public\smp-feed.json') -Raw | ConvertFrom-Json
  $gen = ([datetime]$feed.generated).ToString('yyyy-MM-dd')
  if ($gen -ne $today) {
    Log "FEED STALE: generated $gen, expected $today"
    try { Send-Alert -Subject "Grocery local pipeline did NOT refresh the feed - $today" -Body "run-daily-local.ps1 finished but public/smp-feed.json is still dated $gen. A store pull likely failed; nothing bad was published (guards fail closed). See grocery/ad-cycle-log.txt + local-daily-log.txt. The cloud backup will retry at 16:00 UTC." | Out-Null } catch {}
  } else { Log "feed fresh: week $($feed.week_of), $($feed.recipe_count) recipes, $($feed.ingredient_count) ingredients" }
} catch { Log ("feed assert threw: " + $_.Exception.Message) }

Log "done"
} finally { Remove-Item $lock -Force -ErrorAction SilentlyContinue }
