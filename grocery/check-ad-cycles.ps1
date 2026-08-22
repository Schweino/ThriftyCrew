<#
  check-ad-cycles.ps1 - Runs DAILY (Windows Task Scheduler). Pulls a store's ad only the day AFTER its
  current ad expires, tracks each store's cycle in ad-schedule.json, and keeps the comparison + price
  history fresh when a new ad drops.

  Logic per run:
    * Server stores (Hy-Vee/Aldi/Family Fare): if any is DUE (today >= its next_pull), run the server pull,
      read the live ad windows, and per store:
        - live ad window advanced  -> NEW AD: record the flip, set next_pull = new_to + 1 day.
        - past its 'to' but not reposted -> AWAITING: retry tomorrow.
        - still inside its window -> CURRENT: leave it.
      If any store flipped, re-run compare-deals + update-history so downstream stays current.
    * Browser stores (Baker's/Sam's): can't pull headless -> if DUE, FLAG for a Chrome pull (agent/manual).

  Params: -Today <yyyy-MM-dd> (override for testing), -Force (pull regardless), -NoPull (use latest ads file),
          -NoDownstream (skip compare/history), -ScheduleFile <path> (default ad-schedule.json).
#>
param(
  [string]$Today = "",
  [switch]$Force,
  [switch]$NoPull,
  [switch]$NoDownstream,
  [switch]$NoAlert,
  [switch]$NoPublish,
  [string]$ScheduleFile = ""
)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$OutDir = Join-Path $root 'out'
if (-not $ScheduleFile) { $ScheduleFile = Join-Path $root 'ad-schedule.json' }
$LogFile = Join-Path $root 'ad-cycle-log.txt'
$asof = if ($Today) { ([datetime]$Today).Date } else { (Get-Date).Date }
$asofS = $asof.ToString('yyyy-MM-dd')
function DT([string]$s) { try { return ([datetime]$s).Date } catch { return $null } }
# LOGGING MUST NEVER KILL THE RUN (2026-07-28). $ErrorActionPreference is 'Stop', so a plain Add-Content
# turns any transient lock on the log file into a TERMINATING error: the pipeline dies mid-flight, and the
# one thing that would explain why - the log - is the thing that failed, so it stops with no reason recorded.
# Proved the hard way twice in one afternoon by a `tail -f` on this file; an editor with the log open, a
# backup, or an antivirus scan does exactly the same. Retry briefly, then carry on WITHOUT the line: a lost
# log line is a small loss, an abandoned board pull halfway through publishing is a real one.
# ON A RUNNER, ALSO SAY IT OUT LOUD (2026-08-08). Every Log line goes to a FILE, which is the right default
# on Brad's machine and useless in the cloud: the GitHub Actions run is 68 minutes of blank console followed
# by a green tick, and the log file it wrote is inside a container that is then destroyed. There is no way to
# see where a slow run is, and no way to read the trail of one that failed. Mirroring to the console when
# GITHUB_ACTIONS is set makes the cloud run legible without changing a single line of local behaviour.
# Write-Host, not Write-Output: this script's stdout is captured by callers in places, and a narration line
# leaking into a captured result is how a parser starts reading log text as data.
$script:EchoLog = ($env:GITHUB_ACTIONS -eq 'true' -or $env:CI -eq 'true')
function Log([string]$m) {
  $line = ("[" + (Get-Date).ToString('s') + "] ") + $m
  if ($script:EchoLog) { try { Write-Host $line } catch {} }
  for ($i = 0; $i -lt 5; $i++) {
    try { Add-Content -Path $LogFile -Value $line -ErrorAction Stop; return } catch { Start-Sleep -Milliseconds 120 }
  }
  # A LOCKED LOG MUST NOT GO MUTE (2026-08-22). On 08-21 and again on 08-22 another process (a git stash in
  # an interactive session; a tail -f) held this file, the five retries failed, and the line was DROPPED -
  # so three complete runs looked, from the only record they have, like they died after guard-contract.
  # Same class the old 8:30 runner fixed for itself on 07-30. Fall back to a dated sidecar the run can
  # always create; the next run that can write the primary folds it back in (SIDECAR RECOVERY below).
  if (-not $script:LogSidecar) { $script:LogSidecar = ($LogFile -replace '\.txt$', '') + '.LOCKED-' + (Get-Date -Format 'yyyy-MM-dd') + '.txt' }
  try { Add-Content -Path $script:LogSidecar -Value $line -ErrorAction Stop } catch { try { Write-Host ('[log locked, not written] ' + $line) } catch {} }
}
# SIDECAR RECOVERY: fold any PRIOR day's LOCKED-* sidecar into the primary log, in order, and remove it.
# Today's is left alone (a concurrent run may still be appending). If the primary is still locked nothing
# is deleted - the sidecar simply waits for a run that can write. Non-fatal.
# >>> SIDECAR-RECOVERY (self-test extracts between these sentinels; see test-log-sidecar-recovery.ps1)
try {
  $todayStamp = (Get-Date -Format 'yyyy-MM-dd')
  foreach ($sc in @(Get-ChildItem (($LogFile -replace '\.txt$', '') + '.LOCKED-*.txt') -ErrorAction SilentlyContinue | Sort-Object Name)) {
    if ($sc.BaseName -notmatch 'LOCKED-(\d{4}-\d{2}-\d{2})$' -or $Matches[1] -ge $todayStamp) { continue }
    $scBody = @(Get-Content $sc.FullName -ErrorAction SilentlyContinue)
    if ($scBody.Count -eq 0) { Remove-Item $sc.FullName -Force -ErrorAction SilentlyContinue; continue }
    $scMark = "[" + (Get-Date).ToString('s') + "] --- recovered from " + $sc.Name + " (" + $scBody.Count + " lines): the primary log was held by another process during that run, so its trail went to the lock sidecar. Folded back here in order; the sidecar is removed. ---"
    $scOk = $false
    for ($i = 0; $i -lt 5; $i++) { try { Add-Content -Path $LogFile -Value (@($scMark) + $scBody) -ErrorAction Stop; $scOk = $true; break } catch { Start-Sleep -Milliseconds 120 } }
    if ($scOk) { Remove-Item $sc.FullName -Force -ErrorAction SilentlyContinue }
  }
} catch { }
# <<< SIDECAR-RECOVERY

# ---- SEND AN ALERT WITHOUT LOSING IT (2026-08-06) -------------------------------------------------------
# Send-Alert is the only way this file may page anybody. Every alert below used to be
# `& powershell -File send-alert.ps1 -Body $long`, and Windows refuses to START a process whose command
# line exceeds 32767 characters - so the watchers alert, whose body is the whole test-auditors output
# (43,030 / 43,283 / 43,718 chars on 2026-08-03/04/05), never launched the mailer on any of the three
# consecutive days a guard was blind. No email, no triage-queue entry, and a swallowed launch error logged
# as "test-auditors threw: ...", which reads like the test crashed rather than like the page never went
# out. The helper sends the body BY FILE and makes a failed send its own loud log line. Full account, and
# the reason every caller goes through it even when today's body looks short, in alert-lib.ps1.
. (Join-Path $root 'alert-lib.ps1')

# ---- BOUNDED CHILDREN, RUN ONE AT A TIME (2026-08-22) --------------------------------------------------
# THE PARALLEL EXPERIMENT IS REVERTED, ON THE MEASUREMENT. Earlier today four advisory audits (coverage-gaps,
# semantic, match-soundness, discover-hyvee) were launched side by side on the reasoning that none blocks a
# publish, none reads another's output, and this box has 32 threads. Measured end to end it was WORSE, not
# better: serial 30.9 min vs parallel 41.7 min. Under concurrency match-soundness went 111 s -> 904 s,
# graph-gates 22 s -> killed at its 600 s budget, db-build 2 s -> killed at 300 s, while the CPU sat at 14%.
# They do not contend on the CPU; they contend on I/O, each re-parsing the same ~40 MB of JSON from disk.
# So: plain serial invocation, at the exact spot each audit's result is read.
# WHAT ACTUALLY BOUGHT THE TIME is the ship/inspect split further down - the board now publishes before any
# of these runs at all, so their cost no longer sits between a price and a shopper.
# THE TIMEOUT STAYS, and it is the half that earned its keep (it caught three real hangs). Every child here
# used to be synchronous and unbounded: on 2026-08-14
# audit-coverage-gaps sat in a ReDoS for 11 hours and the board never published; the two Python steps
# (the GPU sweep, graph gates) could hang a CUDA init or a SQLite lock forever and "BLIND never blocks"
# covers only a non-zero EXIT, not a process that never exits. A job that outruns its budget is stopped,
# logged by name with its budget, and reported as the estate rc 3 (could-not-evaluate) so its caller takes
# the same BLIND/advisory path it already has for a failure. The chain keeps moving; the board still ships.
# Start-AuditJob / Receive-AuditJob are NOT called directly any more - Invoke-Bounded is the only entry
# point, and it starts and collects in one breath. They stay split because that is what makes the budget
# enforceable: you cannot kill a child you never named.
$script:AuditJobs = @{}
function Start-AuditJob([string]$Name, [string[]]$Arguments) {
  # $Arguments is the full powershell argument list (e.g. -ExecutionPolicy, Bypass, -File, <path>, ...)
  # one string, quoted where needed, built HERE where the types are known: an array does not cross
  # the job boundary as [string[]] (measured: it arrives flattened, and re-splitting it is guesswork)
  $argStr = (@($Arguments) | ForEach-Object { $t = [string]$_; if ($t -match '\s') { '"' + $t + '"' } else { $t } }) -join ' '
  $script:AuditJobs[$Name] = [pscustomobject]@{
    Job = (Start-Job -Name ("audit-" + $Name) -ScriptBlock {
      param($argStr, $pidFile)
      # a real process we can name: Stop-Job alone would orphan the child and leave a hung audit holding
      # the GPU or a file lock, which is the exact failure the budget exists to end
      $so = [IO.Path]::GetTempFileName(); $se = [IO.Path]::GetTempFileName()
      $p = Start-Process -FilePath 'powershell' -ArgumentList $argStr -PassThru -NoNewWindow -RedirectStandardOutput $so -RedirectStandardError $se
      $null = $p.Handle   # PS 5.1: without touching Handle first, ExitCode reads null after the exit
      Set-Content -Path $pidFile -Value $p.Id
      $p.WaitForExit()
      $o = @(Get-Content $so -ErrorAction SilentlyContinue) + @(Get-Content $se -ErrorAction SilentlyContinue)
      Remove-Item $so, $se -Force -ErrorAction SilentlyContinue
      [pscustomobject]@{ ExitCode = $p.ExitCode; Output = @($o | ForEach-Object { [string]$_ }) }
    } -ArgumentList $argStr, (Join-Path $env:TEMP ("tc-audit-" + $Name + "-" + $PID + ".pid")))
    PidFile = (Join-Path $env:TEMP ("tc-audit-" + $Name + "-" + $PID + ".pid"))
    Started = Get-Date
  }
}
function Stop-ProcessTree([int]$procId) {
  foreach ($c in @(Get-CimInstance Win32_Process -Filter ("ParentProcessId = " + $procId) -ErrorAction SilentlyContinue)) { Stop-ProcessTree ([int]$c.ProcessId) }
  Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
}
function Receive-AuditJob([string]$Name, [int]$TimeoutSec = 900) {
  # returns @{ ExitCode; Output[]; TimedOut; Elapsed }. ExitCode 124 = stopped at the budget.
  $e = $script:AuditJobs[$Name]
  if (-not $e) { return [pscustomobject]@{ ExitCode = 125; Output = @("audit job '$Name' was never started"); TimedOut = $false; Elapsed = 0 } }
  $remaining = [Math]::Max(1, $TimeoutSec - [int]((Get-Date) - $e.Started).TotalSeconds)
  $null = Wait-Job -Job $e.Job -Timeout $remaining
  $elapsed = [int]((Get-Date) - $e.Started).TotalSeconds
  if ($e.Job.State -eq 'Running') {
    try { $cp = [int](Get-Content $e.PidFile -ErrorAction Stop | Select-Object -First 1); if ($cp) { Stop-ProcessTree $cp } } catch { }
    Stop-Job $e.Job -ErrorAction SilentlyContinue; Remove-Job $e.Job -Force -ErrorAction SilentlyContinue
    Remove-Item $e.PidFile -Force -ErrorAction SilentlyContinue
    $script:AuditJobs.Remove($Name)
    # RETURN THE ESTATE'S OWN COULD-NOT-EVALUATE CODE (2026-08-22). The first version returned 124 and the
    # commit claimed callers would "take the same BLIND path they already have for a failure". They do not:
    # every collector tests for 3 (or for a specific failure code) and 124 fell through the ELSE - so a
    # killed coverage-gaps re-read YESTERDAY's json and deduped against it as today's, a killed semantic
    # sweep logged "no invisible products found" and cleared its alert signature, and a killed db-build,
    # the foreign-key gate, logged clean. A timeout must mean what it is: nothing was proven. The distinct
    # fact that we KILLED it rather than the script exiting 3 lives in TimedOut and in this log line.
    Log ("TIMED OUT: $Name exceeded its $TimeoutSec s budget and was stopped - reported as BLIND (could-not-evaluate); the board still ships")
    return [pscustomobject]@{ ExitCode = 3; Output = @("$Name TIMED OUT after $TimeoutSec s - BLIND, nothing proven"); TimedOut = $true; Elapsed = $elapsed }
  }
  $r = Receive-Job $e.Job -ErrorAction SilentlyContinue
  Remove-Job $e.Job -Force -ErrorAction SilentlyContinue
  Remove-Item $e.PidFile -Force -ErrorAction SilentlyContinue
  $script:AuditJobs.Remove($Name)
  # no exit code = the job itself broke before the child ever reported. That is not a clean 0 and it is not
  # a verdict either: it is BLIND, for the same reason as the timeout above.
  $rc = if ($r -and $null -ne $r.ExitCode) { [int]$r.ExitCode } else { 3 }
  $out = if ($r) { @($r.Output) } else { @() }
  if (-not $r) { $out += @('the audit job produced no result object - BLIND') + @(($e.Job.ChildJobs[0].Error | ForEach-Object { [string]$_ })) }
  Log ("{0}: {1} s (rc={2})" -f $Name, $elapsed, $rc)
  return [pscustomobject]@{ ExitCode = $rc; Output = $out; TimedOut = $false; Elapsed = $elapsed }
}
function Invoke-Bounded([string]$Name, [string[]]$Arguments, [int]$TimeoutSec = 600) {
  # synchronous child with a hard stop; same result shape as Receive-AuditJob
  Start-AuditJob $Name $Arguments
  return (Receive-AuditJob $Name $TimeoutSec)
}

# Price signature of the current board: sorted id|store|per_unit|type over the latest comparison, hashed.
# Used to re-publish only when a price actually changed (a new ad, a flash sale ending, a mid-cycle fix),
# so the daily pull can run every day without needlessly re-pushing an unchanged page.
function BoardSignature() {
  $cf = Get-ChildItem (Join-Path $OutDir 'comparison-*.json') -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
  if (-not $cf) { return '' }
  $cmp = (Get-Content $cf.FullName -Raw | ConvertFrom-Json).comparison
  $parts = @()
  foreach ($it in $cmp) { foreach ($s in $it.stores) { $parts += ('{0}|{1}|{2}|{3}' -f $it.id, $s.store, $s.per_unit, $s.type) } }
  # Fold each store's CURRENT ad window into the signature so a same-price ad repost with a NEW window still
  # triggers a republish - otherwise a "Sale thru <date>" badge could show an expired date after the window
  # rolls (the badge is recomputed from the ad window at build time).
  try { $sc = Get-Content $ScheduleFile -Raw | ConvertFrom-Json; foreach ($s in @($sc.stores)) { if ($s.current -and $s.current.to) { $parts += ('WIN|{0}|{1}|{2}' -f $s.store, $s.current.from, $s.current.to) } } } catch {}
  # also hash the recipe board (everyday floors + any overlaid ad-sales) so a recipe-item sale starting or
  # ending triggers a republish too.
  try { $rbf = Join-Path $OutDir 'recipe-board.json'; if (Test-Path $rbf) { $rb = (Get-Content $rbf -Raw | ConvertFrom-Json).comparison; foreach ($it in $rb) { foreach ($s in $it.stores) { $parts += ('R|{0}|{1}|{2}|{3}' -f $it.id, $s.store, $s.per_unit, $s.type) } } } } catch {}
  # and the VERIFIED board when present - publish PREFERS it, so a verdicts-only change (a wrong-product
  # winner dropped mid-week with no raw price move) must also count as a board change or it never ships.
  try { if ($cf) { $wkS = (Get-Content $cf.FullName -Raw | ConvertFrom-Json).week_of; $vf = Join-Path $OutDir ("verified-" + $wkS + ".json"); if (Test-Path $vf) { $vb = (Get-Content $vf -Raw | ConvertFrom-Json).comparison; foreach ($it in $vb) { foreach ($s in $it.stores) { $parts += ('V|{0}|{1}|{2}' -f $it.id, $s.store, $s.per_unit) } } } } } catch {}
  $joined = ($parts | Sort-Object) -join ';'
  $md5 = [System.Security.Cryptography.MD5]::Create()
  $bytes = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($joined))
  return ([BitConverter]::ToString($bytes) -replace '-','')
}

$sched  = Get-Content $ScheduleFile -Raw | ConvertFrom-Json
$stores = @($sched.stores)
$summary = @()
$flips = @()
# SHIP-PATH CLOCK (2026-08-22). The point of the ship/inspect split is that the board reaches shoppers fast;
# a claim like that has to be measurable from the log alone, on any day, without a stopwatch. Started here
# - before the pulls, which ARE ship work - and read once at the ship/inspect boundary.
$script:ShipStart = Get-Date
# Set true at the boundary. Retention (prune-out / prune-intermediates) moved OUT of the downstream block so
# it can run after the last reader of the newest comparison-*; this flag keeps its old condition exactly.
$script:DownstreamRan = $false

# ---- pull server ads EVERY day (not just on the weekly ad-flip day) so pricing always reflects today's
#      ad dates: a flash/weekend sale that ended, or any mid-cycle correction, is caught the next morning.
#      next_pull is still used below purely to detect a NEW AD WINDOW (for the schedule + history). ----
$serverDue = $false
foreach ($s in $stores) { if ($s.method -eq 'server') { $serverDue = $true } }

# ---- pull live server ad windows if due (retry once; a healthy pull ALWAYS yields >=1 PASS store) ----
$verif = $null
$hardFail = $false
# DID THE PULL ACTUALLY HAPPEN? Measured here, at the call site - never inferred from $serverDue. $serverDue
# only means "a server store's next_pull has arrived"; whether the pull RUNS is decided a few lines down, and
# under -NoPull it never does. The report header used to word itself from $serverDue alone, so every -NoPull
# run (bakers-daily-scan.ps1:74, the Fareway daily check) printed "(server pull ran)" while nothing had been
# pulled - a line that ASSERTS an action instead of reporting one, same class as a date written rather than
# measured. Observed 2026-08-03. Set this flag, and only this flag, drive the header note.
$pullRan = $false
$adsToday = Join-Path $OutDir ("ads-" + $asofS + ".json")
if ($serverDue) {
  $pullOk = $NoPull   # in NoPull test mode we don't judge health
  if (-not $NoPull) {
    for ($attempt=1; $attempt -le 2 -and -not $pullOk; $attempt++) {
      try {
        & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'pull-grocery-ads.ps1') | Out-Null
        $pullRan = $true   # the child was launched and returned; health is judged separately, just below
        # Assert a FRESH, today-dated ads file with >=1 PASS store. If the pull crashed before writing
        # today's file, this stays false (we do NOT trust yesterday's ads-*.json) -> retry -> HARD FAILURE.
        if (Test-Path $adsToday) { $vv = @((Get-Content $adsToday -Raw | ConvertFrom-Json).verification); if (@($vv | Where-Object { $_.status -eq 'PASS' }).Count -gt 0) { $pullOk = $true } }
        Log ("pull attempt $attempt ok=$pullOk")
      } catch { Log ("pull attempt $attempt FAILED: " + $_.Exception.Message) }
    }
    # HARD failure = no current ad data from ANY server store after a retry (API/network down, not "ad not posted yet")
    if (-not $pullOk) {
      $hardFail = $true
      Log "HARD FAILURE: server pull returned no current TODAY data after 2 attempts -> alerting, downstream skipped"
      if (-not $NoAlert) {
        $bdy = "The daily server-side grocery pull (Hy-Vee / Aldi / Family Fare) returned NO current ad data after 2 attempts on $asofS. Likely an API or network issue. The board was left at its last good state - nothing was republished. Check pull-grocery-ads.ps1 and ad-cycle-log.txt on the machine."
        try { Send-Alert -Subject "Grocery pull FAILED (server stores) - $asofS" -Body $bdy | Out-Null } catch { Log ("alert send threw: " + $_.Exception.Message) }
      }
    }
    # Family Fare EVERYDAY column (headless Freshop catalog) - refresh alongside the ad pull; nothing else pulls it.
    # NOTE: this writes ALL search results and lets compare-deals apply the full include/exclude+per-unit filter and
    # pick the cheapest VALID one. Do NOT swap in a "pick one cheapest here" researcher - pre-filtering with a lesser
    # rule dropped FF from milk/butter/blueberries (it picked Butter Beans / Blueberry Soda). Non-fatal.
    try { & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'pull-regular-familyfare.ps1') | Out-Null; Log 'FF everyday refreshed' } catch { Log ('FF everyday pull threw: ' + $_.Exception.Message) }

    # HY-VEE, DAILY. Hy-Vee used to be the one priced store with no automated pull: a human refreshed it through
    # a browser, it went stale in between, and the capture read basePrice (the REGULAR price) rather than what
    # the store actually charges. That is how sirloin sat on the board at $13.99/lb while Omaha #01 was charging
    # $11.99, and how ~110 live markdowns went unseen. Its GraphQL takes storeId as a request VARIABLE (not a
    # cookie), so it runs headless right here, every day, like Family Fare's. Non-fatal: a bad run keeps the
    # last good file (throttle-wipeout guard) and the price guards still gate the publish.
    # CAPTURE, THEN LOG, THEN CHECK THE EXIT CODE - the same shape as the ff-carry caller below, and for the
    # same reason. This line used to pipe the whole pull to Out-Null and then log 'Hy-Vee everyday refreshed'
    # UNCONDITIONALLY, so all four of these were indistinguishable in the log: a clean 1,010-product refresh,
    # a run truncated by the wall-clock cap, a run that refreshed three products, and the THROTTLE-WIPEOUT
    # guard tripping (the pull collapsing below half its normal size and being quarantined to out\throttled\
    # instead of written). The puller had no `exit` statement at all, so the wipeout path's bare `return`
    # exited ZERO; it now exits 2. A native child's crash is not a PowerShell exception, so the catch never
    # saw that either. No 2>&1: this file runs under EAP=Stop, where redirecting a native child's stderr turns
    # its first stderr line into a terminating throw that would skip the very check being added here.
    try {
      $hvOut = & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'pull-regular-hyvee.ps1')
      $hvRc  = $LASTEXITCODE
      foreach ($l in @($hvOut)) { Log ('Hy-Vee: ' + $l) }
      if ($hvRc -eq 2) {
        Log 'Hy-Vee: THROTTLE-WIPEOUT - the pull collapsed and was quarantined; the last good file still serves'
        $summary += 'REVIEW    Hy-Vee pull tripped the throttle-wipeout guard - board is serving the previous capture'
      }
      elseif ($hvRc -ne 0 -or @($hvOut).Count -eq 0) {
        Log ("Hy-Vee: DID NOT RUN - exit $hvRc with " + @($hvOut).Count + ' output line(s); today''s Hy-Vee prices are whatever the last capture held')
        $summary += 'REVIEW    Hy-Vee pull did not complete - its prices were not refreshed this cycle'
      }
    } catch { Log ('Hy-Vee pull threw: ' + $_.Exception.Message) }
    # Baker's via Kroger's sanctioned public API (2026-07-24): daily headless current+promo prices for the
    # Saddlecreek store, replacing the browser scan that needed the Claude app awake. Credentials are the
    # gitignored grocery\.krogerkey locally (env vars in CI); WHERE THE KEY IS ABSENT (the cloud backup
    # runner, unless Brad adds the secrets) the pull throws, we log it, and the newest committed capture
    # keeps serving - same graceful degradation as any other store having an off day. The link snapshots
    # refresh from the SAME pull (the Hy-Vee lesson) so guard 4 compares like against like.
    try {
      & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'pull-regular-bakers-api.ps1') | Out-Null
      if ($LASTEXITCODE -eq 0) {
        & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'refresh-bakers-links.ps1') | Out-Null
        Log "Baker's everyday+promo refreshed via Kroger API (Saddlecreek) + link snapshots synced"
      } else { Log ("Baker's API pull rc=$LASTEXITCODE (thin or failed) - keeping newest existing capture") }
    } catch { Log ("Baker's API pull threw: " + $_.Exception.Message + ' - keeping newest existing capture') }
    # and re-point Hy-Vee's stored link snapshots at those same fresh numbers, so the board and its "See item"
    # link quote one number. Skip this and yesterday's snapshots become override pins that drag the board back.
    try { & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'refresh-hyvee-links.ps1') | Out-Null; Log 'Hy-Vee link snapshots refreshed' } catch { Log ('Hy-Vee link refresh threw: ' + $_.Exception.Message) }
    # FF PULL-COMPLETENESS GUARD: catch a term the Freshop pull silently dropped (rate-limit -> 0 items) for a
    # product FF actually carries (the 2026-07-13 ground-pork bug; coverage-gaps can't see a never-pulled item).
    try {
      $fcArgs = @('-ExecutionPolicy','Bypass','-File',(Join-Path $root 'audit-ff-carry.ps1'),'-OutDir',$OutDir)
      if (-not $NoAlert) { $fcArgs += '-Alert' }
      # CAPTURE, THEN LOG, THEN CHECK THE EXIT CODE. Piping the child straight into Log means a child that
      # dies before its first Write-Output logs NOTHING - and a guard that says nothing is indistinguishable
      # from one that was never wired up. That is not hypothetical: audit-ff-carry threw on its report line
      # on every run from 2026-07-13, and the string 'ff-carry' appears 0 times in 2,716 lines of
      # ad-cycle-log.txt. A native child's crash is not a PowerShell exception, so the catch below never saw
      # it either. This guard prints exactly one line whenever it completes, so zero lines IS the failure.
      # No 2>&1: $ErrorActionPreference is 'Stop' here, and redirecting a native child's stderr under Stop
      # turns its first stderr line into a terminating throw that would skip this very check.
      $fcOut = & powershell @fcArgs
      $fcRc  = $LASTEXITCODE
      foreach ($l in @($fcOut)) { Log ('ff-carry: ' + $l) }
      # Exit 3 is the estate's could-not-evaluate code and must NOT be reported as a crash. ff-carry returns
      # it when Freshop answered none of the terms it needed to probe: the script ran fine and said so, it
      # just proved nothing. Both cases leave the watch blind for the cycle, but only one of them means
      # "go read stderr", and sending someone to an empty stderr is how a real crash stops being believed.
      if ($fcRc -eq 3) {
        $summary += 'REVIEW    audit-ff-carry could not evaluate (Freshop refused every probe) - FF pull-drop victims went unchecked this cycle'
      }
      elseif ($fcRc -ne 0 -or @($fcOut).Count -eq 0) {
        Log ("ff-carry: DID NOT RUN - exit $fcRc with " + @($fcOut).Count + ' output line(s); the FF pull-drop watch is blind this cycle (see stderr)')
        $summary += 'REVIEW    audit-ff-carry did not complete - FF pull-drop victims went unchecked this cycle'
      }
    } catch { Log ('ff-carry guard threw: ' + $_.Exception.Message) }
  }
  # read verification from TODAY's file (real runs); in -NoPull test mode fall back to the newest ads file
  if (Test-Path $adsToday) { $verif = @((Get-Content $adsToday -Raw | ConvertFrom-Json).verification) }
  elseif ($NoPull) { $af = Get-ChildItem (Join-Path $OutDir 'ads-*.json') -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1; if ($af) { $verif = @((Get-Content $af.FullName -Raw | ConvertFrom-Json).verification) } }
}

# ---- rebuild each store record ----
$newStores = @()
foreach ($s in $stores) {
  $store = [string]$s.store
  $rec = [ordered]@{ store=$store; method=$s.method; cadence_days=$s.cadence_days; current=$s.current; next_pull=$s.next_pull; history=@($s.history) }
  if ($s.PSObject.Properties['note']) { $rec.note = $s.note }

  if ($s.method -eq 'server' -and $serverDue -and $verif) {
    $mine = @($verif | Where-Object { $_.store -eq $store -and $_.status -eq 'PASS' -and $_.ad_to })
    if (@($mine).Count -gt 0) {
      $primary   = $mine | Sort-Object { [datetime]$_.ad_to } | Select-Object -First 1   # soonest-expiring = the weekly cycle
      $liveTo    = [string]$primary.ad_to; $liveFrom = [string]$primary.ad_from
      $recordedTo = if ($s.current) { [string]$s.current.to } else { $null }
      if ((-not $recordedTo) -or ((DT $liveTo) -gt (DT $recordedTo))) {
        # NEW AD detected
        $hist = @($s.history) + ,([ordered]@{ from=$liveFrom; to=$liveTo; detected=$asofS })
        $rec.current   = [ordered]@{ from=$liveFrom; to=$liveTo }
        $rec.history   = $hist
        $rec.next_pull = ((DT $liveTo).AddDays(1)).ToString('yyyy-MM-dd')
        $flips += $store
        $summary += ("NEW AD    {0,-13} {1} -> {2}   next pull {3}" -f $store, $liveFrom, $liveTo, $rec.next_pull)
        Log ("NEW AD $store $liveFrom..$liveTo")
      } elseif ($asof -gt (DT $recordedTo)) {
        # expired but not reposted yet -> retry tomorrow
        $rec.next_pull = $asof.AddDays(1).ToString('yyyy-MM-dd')
        $summary += ("AWAITING  {0,-13} expired {1}, new ad not live yet; retry {2}" -f $store, $recordedTo, $rec.next_pull)
        Log ("AWAITING $store (expired $recordedTo)")
      } else {
        $rec.next_pull = ((DT $recordedTo).AddDays(1)).ToString('yyyy-MM-dd')
        $summary += ("CURRENT   {0,-13} still valid thru {1}" -f $store, $recordedTo)
      }
    }
  }
  elseif ($s.method -eq 'server') {
    $summary += ("waiting   {0,-13} next flip {1}" -f $store, $s.next_pull)
  }
  elseif ($s.method -eq 'browser') {
    if ($s.next_pull -and ($asof -ge (DT $s.next_pull))) {
      $expTo = if ($s.current) { $s.current.to } else { '?' }
      $summary += ("DUE-CHROME {0,-12} ad expired {1} -> needs a browser pull (run the agent)" -f $store, $expTo)
      Log ("DUE-CHROME $store")
    } elseif ($s.next_pull) {
      $summary += ("waiting   {0,-13} next flip {1} (browser)" -f $store, $s.next_pull)
    } else {
      $summary += ("n/a       {0,-13} no ad cycle (national); weekly browser refresh" -f $store)
    }
  }
  $newStores += ,$rec
}

# ---- SCHEDULE vs DATA: is the window this file claims is current actually backed by a capture? ----------
# THE 2026-08-02 FAREWAY MISS. The ad window a store's schedule records and the deals file that prices the
# board are written by DIFFERENT steps, and nothing ever compared them. On 08-03 the browser refresh
# advanced Fareway's current window from 2026-07-26..08-01 to 08-02..08-08 and next_pull to 08-09, while
# no fareway-deals file for that window was ever built - the tell is that history_last stayed 2026-08-01,
# because a genuinely DETECTED flip appends to history and this advance did not.
#
# The damage was not a wrong date, it was a wrong PRICE: the ad supplement overrides the everyday storefront
# whenever it is cheaper, so the dead 07-26..08-01 ad kept crowning cells. Six days later the live board
# still sold "All-Natural Iowa Pork Chops" at $1.99/lb against a real Fareway everyday near $4.00, and 15
# recipes were costed off it.
#
# It also could not self-heal: fareway-daily-due.ps1 fires on next_pull, and once next_pull had advanced to
# 08-09 the missed 08-02 pull became unreachable. A gate that can only arm on a date already behind it is
# the gates-that-can-never-arm shape, so the check has to be on the DATA, not on the calendar.
$adSupplement = @{ "Baker's" = 'bakers\bakers-deals-*.json'; 'Fareway' = 'fareway\fareway-deals-*.json' }
foreach ($rec in $newStores) {
  $g = $adSupplement[[string]$rec.store]
  if (-not $g -or -not $rec.current -or -not $rec.current.to) { continue }
  $newest = Get-ChildItem (Join-Path $OutDir $g) -ErrorAction SilentlyContinue |
            Where-Object { $_.BaseName -match '\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending | Select-Object -First 1
  $fileTo = $null
  if ($newest) { try { $j = Get-Content $newest.FullName -Raw -Encoding UTF8 | ConvertFrom-Json; if ($j.ad_to) { $fileTo = [datetime]$j.ad_to } } catch {} }
  $schedTo = $null; try { $schedTo = [datetime]$rec.current.to } catch {}
  if (-not $schedTo) { continue }
  if ((-not $newest) -or ($fileTo -and $fileTo -lt $schedTo)) {
    $have = if ($newest) { $newest.Name + ' (window ends ' + $(if($fileTo){$fileTo.ToString('yyyy-MM-dd')}else{'undeclared'}) + ')' } else { 'no deals file at all' }
    $summary += ("REVIEW    {0}'s schedule says its ad runs to {1}, but the newest ad capture is {2} - the window advanced without the data. Its board prices come from the OLD ad until a pull lands." -f $rec.store, $rec.current.to, $have)
    Log ("SCHEDULE-AHEAD-OF-DATA $($rec.store): current.to=$($rec.current.to) but capture is $have")
    if (-not $NoAlert) { try { Send-Alert -Subject ("$($rec.store) ad window advanced with no capture behind it") -Body ("ad-schedule.json records $($rec.store)'s current ad window ending $($rec.current.to), but the newest ad capture on disk is $have.`n`nThese are written by two different steps and only one ran. The ad supplement OVERRIDES the everyday storefront price whenever it is cheaper, so until a pull lands the board keeps pricing cells from the PREVIOUS ad - a sale that is over. That is how Fareway published `$1.99/lb pork chops for six days after the sale ended.`n`nFix: run the browser agent for this store so the ad capture catches up.") | Out-Null } catch {} }
  }
}

# ---- persist schedule ----
([ordered]@{ updated=$asofS; note=$sched.note; stores=$newStores } | ConvertTo-Json -Depth 8) | Set-Content $ScheduleFile -Encoding UTF8

# ---- (retired 2026-08-22) the Wednesday browser-refresh watchdog. It paged when the weekly Chrome agent
#      missed its week; that agent is disabled (Brad: the three TC tasks are the only routines) and the
#      walled stores are captured on demand from out\browser-capture-due-<date>.flag, which
#      capture-watchdog watches. A weekly clock nobody is on would have alerted every Thursday forever. ----
# ---- refresh downstream if a server store flipped ----
# Re-compare DAILY (server ads were just re-pulled) so the board reflects today's ad dates, then re-publish
# ONLY when a price actually changed (new ad, flash sale ended, or a mid-cycle correction) - detected by the
# board price signature, so an unchanged day is a no-op. This is what keeps pricing current relative to ad
# dates every day, not just on the weekly ad flip.
if ($serverDue -and (-not $NoDownstream) -and (-not $hardFail)) {
  # ---- REPAIR PACK SIZES BEFORE COMPARING (2026-08-01) ----------------------------------------------
  # A store's own feed can return ONE unit of a pack it already counted in the product name - Family Fare
  # returned size "50.5 oz" for "Heinz Tomato Ketchup, 2 Pack 50.5 Oz" at $14.99, which prices at $0.2968/oz
  # against $0.1484 for the real 101 oz. Guard 5 hard-fails those, correctly, and that blocked the whole
  # nightly publish with no honest way to clear it: a multipack-allowlist entry asserts a human checked the
  # size IS the pack total, which here it is not. So repair the arithmetic the store's own name proves, and
  # refuse everything else. Must run BEFORE compare-deals or the board prices the unrepaired size (same
  # ordering rule heal-degraded-sizes.ps1 states). Shares multipack-lib with the guard, so the repair and
  # the verdict cannot drift apart. Non-fatal and LOUD: a repair that throws must not take the cycle down,
  # but it must never pass silently either - the row it left behind is a 2x price.
  try {
    $mpOut = @(& powershell -ExecutionPolicy Bypass -File (Join-Path $root 'repair-multipack-sizes.ps1') -Apply)
    @($mpOut | Where-Object { $_ -match 'REPAIR |REFUSED |^repair-multipack-sizes:' }) | ForEach-Object { Log ('multipack-repair: ' + $_) }
    $mpRep = @($mpOut | Where-Object { $_ -match '^\s*REPAIR ' }).Count
    $mpRef = @($mpOut | Where-Object { $_ -match '^\s*REFUSED ' }).Count
    if ($mpRep -gt 0) { $summary += ('REVIEW    multipack-repair rewrote ' + $mpRep + ' pack size(s) the store reported as ONE unit - each was a ' + [char]0x2248 + 'Nx per-unit price before the fix') }
    if ($mpRef -gt 0) { $summary += ('REVIEW    multipack-repair REFUSED ' + $mpRef + ' row(s) it could not prove (name counts a pack but states no per-unit weight) - these stay a guard-5 HARD FAIL until a human rules in multipack-allowlist.json') }
  } catch { Log ('multipack-repair threw: ' + $_.Exception.Message); $summary += 'REVIEW    multipack-repair threw - any pack-size defect in today''s feeds is unrepaired and guard 5 will block the publish' }

  $bakers = Get-ChildItem (Join-Path $OutDir 'bakers\bakers-deals-*.json') -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
  $fareway = Get-ChildItem (Join-Path $OutDir 'fareway\fareway-deals-*.json') -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
  $args = @('-ExecutionPolicy','Bypass','-File',(Join-Path $root 'compare-deals.ps1'),'-MinStores','1')
  if ($bakers)  { $args += @('-BakersFile',  $bakers.FullName) }
  if ($fareway) { $args += @('-FarewayFile', $fareway.FullName) }
  # Sam's is deliberately NOT pinned here. Its club catalog is CAPTCHA-walled, so each capture only covers the
  # categories that run got through - pinning "the newest file" made every night's board only as broad as the
  # last partial capture (the 07-15 Omaha capture covered 118 commodities where 07-08 covered 251: 167 priced
  # cells vanished, chicken-breast among them). compare-deals loads EVERY capture inside its age window and
  # lets the freshest one that covers a commodity win it, so leaving -SamsFile off is what keeps coverage whole.
  # "Newest file wins" lived in two places; this was the copy that would have silently overridden the fix.
  try {
    $sigBefore = BoardSignature
    & powershell @args | Out-Null
    $cmprc = $LASTEXITCODE
    if ($cmprc -ne 0) {
      # A crashed re-compare must NOT be treated as "board current" - leave the last-good board up and alert.
      Log ("COMPARE FAILED rc=$cmprc - board left at last good, NOT republished")
      $summary += "ERROR     compare-deals failed (rc=$cmprc) - live page left at last good, not updated"
      if (-not $NoAlert) { try { Send-Alert -Subject "Grocery compare FAILED - $asofS" -Body "compare-deals.ps1 exited $cmprc on $asofS. The board was NOT recomputed or republished (left at last good). Check ad-cycle-log.txt." | Out-Null } catch {} }
    } else {
      # BANK THE VERIFIED BOARD, NOT THE RAW ONE (2026-07-30). This ran update-history against the raw
      # comparison that compare-deals had just written - the exact bug fixed in the WEEKLY path on 2026-07-29
      # and left in place here, so the daily job kept doing it every single day.
      # Why it matters: the week's "cheapest" is written into price-history BEFORE the semantic verify drops
      # wrong-product winners, so every one of them sets a RECORD LOW on its way out (strawberries $0.0833
      # from an applesauce, honey $0.1244 from hot dog buns). record_low is what the buy/wait badge reads, and
      # update-history's compaction deliberately keeps each old week's MINIMUM forever - so a corrupt low
      # never ages out on its own. It has to be hand-purged, which is what purge-bad-lows.ps1 is for.
      # If the week has a verdict file, apply it and bank THAT. If it does not, no product has been judged, so
      # the raw board IS the verified board and banking it directly is equivalent rather than a shortcut.
      $histTarget = $null
      try {
        $cmpH = Get-ChildItem (Join-Path $OutDir 'comparison-*.json') -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
        if ($cmpH) {
          $wkH = [string](Get-Content $cmpH.FullName -Raw | ConvertFrom-Json).week_of
          if ($wkH -and (Test-Path (Join-Path $OutDir ("verify-verdicts-" + $wkH + ".json")))) {
            # -MinStores 1 so the ~24 single-store long-tail commodities keep their history even though
            # MinStores 2 keeps them off the published page - same reasoning as weekly-post-capture.
            & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'verify-apply.ps1') -MinStores 1 -OutFile 'verified-history.json' | Out-Null
            $vh = Join-Path $OutDir 'verified-history.json'
            if (Test-Path $vh) { $histTarget = $vh }
            else { Log 'verify-apply produced no verified-history.json - banking history from the RAW board this run' }
          }
        }
      } catch { Log ('verify-for-history threw, banking from the raw board: ' + $_.Exception.Message) }
      if ($histTarget) {
        & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'update-history.ps1') -CompareFile $histTarget | Out-Null
        Log 'history banked from the VERIFIED board'
      } else {
        & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'update-history.ps1') | Out-Null
        Log 'history banked from the raw board (no verdict file for this week - nothing judged, so raw == verified)'
      }
      # "raw == verified" is only true for products nobody has judged YET. The raw path above skips verify-apply
      # entirely, so it also skips verdict-suppressions.json - every standing DROP is inert on that branch and a
      # product judged wrong in an earlier week can bank a fresh history row (and a fresh record low) any day the
      # current week has no verdict file. Measured: the raw boards on 2026-07-25..28 each carried 15-17 cells
      # whose product a verdict had already rejected, 10-12 of them CROWNING their commodity. Sweep it back out.
      # Evidence-driven and idempotent, so a day that banked nothing rejected changes nothing and costs ~3s.
      & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'purge-verdict-lows.ps1') -Apply | Out-Null
      # Refresh the per-item sale-window log (sale price + start/end dates from the fresh board) so the daily
      # Baker's guard fires only when a sale actually reverts/starts, not blindly. Headless-safe, non-fatal.
      # RECORD TODAY'S LANDED RE-PRICES FIRST (2026-08-22). build-sale-windows prunes a window
      # only once refresh_on is past AND repriced_for matches it - so this reconcile is what
      # lets the ledger drain. It must run BEFORE the build: after it, a re-price that landed
      # looks unprocessed and is asked for again tomorrow (wasteful, safe). It writes only for
      # stores whose everyday file actually landed today, so a blind day retires nothing. The
      # lanes that know their own outcome (Family Fare, Hy-Vee, the four walled builders via
      # commit-capture-cursor) have already written theirs; this catches the rest.
      try { & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'capture-policy.ps1') -Reconcile | Out-Null; Log 'sale-expiry re-prices reconciled' } catch { Log ('capture-policy -Reconcile threw: ' + $_.Exception.Message) }
      try { & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'build-sale-windows.ps1') | Out-Null; Log 'sale-windows refreshed' } catch { Log ('build-sale-windows threw: ' + $_.Exception.Message) }
      # Re-apply the weekly semantic verdicts (wrong-product drops / de-crowns) to TODAY's fresh board so
      # build/publish's verified-<week> board reflects both the fresh prices AND the wrong-product removals.
      # Deterministic PS (no LLM); only runs when this week's verdicts exist. Non-fatal.
      $cmpNow = Get-ChildItem (Join-Path $OutDir 'comparison-*.json') -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
      if ($cmpNow) { try { $wkNow = (Get-Content $cmpNow.FullName -Raw | ConvertFrom-Json).week_of; if (Test-Path (Join-Path $OutDir ("verify-verdicts-" + $wkNow + ".json"))) { & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'verify-apply.ps1') | Out-Null; Log 'verify-apply re-applied verdicts to fresh board' } } catch { Log ('verify-apply threw: ' + $_.Exception.Message) } }
      # overlay this week's ad-sales onto the everyday recipe-ingredient board (catches recipe items on sale;
      # reverts automatically when a sale ends). MUST run BEFORE resolve-worklist so the link worklist reflects
      # TODAY's recipe board, not yesterday's. Non-fatal - only runs once the recipe rule-set exists.
      try { & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'recipe-overlay.ps1') | Out-Null; Log 'recipe-overlay applied' } catch { Log ('recipe-overlay threw: ' + $_.Exception.Message) }
      # UNIFIED ENGINE (2026-07-26 consolidation): re-cost the whole catalog from today's boards into
      # db\costed.json, then recompute the v2 per-serving manifest (everyday + cheapest whole-package)
      # that top5-weekly reads. MUST run before top5-weekly or per_serving falls back to the legacy
      # basis. Feed path = the local smp-feed, which is now exported immediately below rather than 270
      # lines later - the one-day lag this comment used to describe was the bug fixed on 2026-08-22.
      # Non-fatal.
      try { & powershell -ExecutionPolicy Bypass -File (Join-Path (Split-Path $root -Parent) 'meal-prep\engine\cost-recipes.ps1') | Out-Null; Log 'engine cost-recipes refreshed db\costed' } catch { Log ('engine cost-recipes threw: ' + $_.Exception.Message) }
      # EXPORT THE FEED BEFORE ANYTHING RESOLVES IT (2026-08-22). compute-v2-perserving.ps1 is invoked with
      # -FeedPath out\smp-feed.json and export-feed.ps1 is what WRITES that file - and until today it wrote
      # it ~270 lines LATER in this same run. So compute-v2 resolved YESTERDAY's feed every single day and
      # its freshness rule refused the manifest: the 2026-08-22 08:12 run logged
      # "compute-v2 REFUSED to recompute the manifest - stale price feed: ... freshness: STALE_VS_CLOCK".
      # export-feed reads the comparison, the recipe board, sale-windows, product-urls and recipe-costs -
      # all final by this point - and reads NOTHING compute-v2 writes, so there is no cycle to create.
      try { & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'export-feed.ps1') | Out-Null; Log 'smp-feed exported' } catch { Log ('export-feed threw: ' + $_.Exception.Message) }
      # compute-v2 now SKIPS bad recipes and exits 1 with the list (was: throw -> whole manifest stale,
      # and a child exit-1 does NOT raise in this parent, so the old code logged success falsely). Check
      # the exit code explicitly and alert on any skipped recipe.
      # $cv2Ok is captured HERE, at the call site, and nowhere else. It used to be re-read 60 lines below as a
      # bare $LASTEXITCODE, by which point three more `& powershell` children had overwritten it - so the
      # close-the-loop gate was testing batch-ledger's exit code and calling it compute-v2's. It failed both
      # ways: a partial manifest (rc 1) sailed through whenever batch-ledger was clean, and a stalled batch
      # (rc 1) skipped the loop while logging "compute-v2 did not succeed". Start it FALSE so a throw before
      # the assignment leaves the gate shut; the old `-or $null -eq $cv2` arm did the exact opposite and let
      # a compute-v2 that died at launch pass as success.
      $cv2Ok = $false
      try {
        $cv2   = & powershell -ExecutionPolicy Bypass -File (Join-Path (Split-Path $root -Parent) 'meal-prep\pipeline\compute-v2-perserving.ps1') -FeedPath (Join-Path $OutDir 'smp-feed.json')
        $cv2Rc = $LASTEXITCODE
        $cv2Ok = ($cv2Rc -eq 0)
        # rc 2 is the 2026-08-15 staleness refusal, NOT a bad-recipe skip. It has to read as itself: the
        # manifest was deliberately NOT rewritten (so the surfaces keep their previous numbers instead of
        # gaining wrong ones), and the fix is upstream in the feed, not in any recipe's cost data. Reporting
        # it as "skipped recipe(s) with bad cost data" would send triage looking at specs for a problem that
        # is not there. compute-v2 alerts on its own for this case, so no second email from here.
        if ($cv2Rc -eq 2) {
          $cv2Why = (($cv2 | Where-Object { $_ -match 'REFUSING|freshness:' }) -join ' ')
          Log ('compute-v2 REFUSED to recompute the manifest - stale price feed: ' + $cv2Why)
          $summary += 'REVIEW    v2 per-serving manifest was NOT recomputed - the price feed it resolved is stale (surfaces keep their previous numbers; fix the feed, not the recipes)'
        }
        elseif ($cv2Rc -ne 0) {
          $cv2Bad = @($cv2 | Where-Object { $_ -match '^\s+\S' -or $_ -match 'SKIPPED' })
          Log ('compute-v2 SKIPPED recipe(s) with bad cost data: ' + (($cv2Bad | Select-Object -First 6) -join ' | '))
          $summary += 'REVIEW    v2 per-serving manifest skipped recipe(s) with bad cost data - top5/rotation may be stale for them (see compute-v2 output)'
          if (-not $NoAlert) { try { Send-Alert -Subject "Recipe per-serving manifest: skipped recipe(s)" -Body ("compute-v2-perserving.ps1 could not compute per-serving cost for some recipes and skipped them (the rest still updated). Their top5/rotation/site numbers are stale until fixed. Detail: " + (($cv2Bad | Select-Object -First 15) -join ' | ')) | Out-Null } catch {} }
        } else { Log 'v2 per-serving manifest recomputed' }
      } catch { Log ('compute-v2-perserving threw: ' + $_.Exception.Message) }
      # DERIVED ingredient-map refresh (2026-07-26): regenerate meal-prep\ingredient-map.json from the spec
      # scaler payloads + live feed (it was a hand-authored file frozen since 07-07, missing 58 items). Runs
      # BEFORE top5 (which reads it for sale badges); dinner/protein tool builders read it on their own runs.
      try { & powershell -ExecutionPolicy Bypass -File (Join-Path (Split-Path $root -Parent) 'meal-prep\pipeline\regenerate-ingredient-map.ps1') | Out-Null; Log 'ingredient-map regenerated (derived from specs + feed)' } catch { Log ('regenerate-ingredient-map threw: ' + $_.Exception.Message) }
      # ---- CLOSE THE LOOP: re-anchor the specs and republish the cards the board just moved ------------
      # THE GAP THIS FILLS (2026-08-07, Brad approved unattended republish). This chain recomputed prices
      # every day and never propagated them: reanchor + build-cards + publish were manual, so every baked
      # number on 542 live pages drifted by exactly the daily board move. Measured before this landed: 471
      # cards showed a per-serving cost their own spec no longer held, 452 of them TOO HIGH by up to $1.26
      # on a site whose whole promise is cheap. That was the steady-state error of the design, not a bug.
      #
      # Guards on it:
      #  * SKIPPED ENTIRELY if compute-v2 failed - re-anchoring to a partial manifest would stamp bad numbers.
      #  * reanchor-all runs BOTH halves (machine fields + prose). Running machine-fields alone leaves every
      #    touched spec quoting two different prices; that happened twice by hand on 2026-08-07.
      #  * A SANITY CAP: normal daily drift is a handful to a few dozen slugs. A number far above that means
      #    something systemic moved (a gpu, a shared row, a DB rename) and a human should look before 500
      #    live pages are rewritten unattended. Over the cap we alert and skip rather than publish.
      #  * -Slugs is passed IN-PROCESS. engine\README.md: `powershell -File` marshals an array as one
      #    command-line string, so a 300-slug run binds as one slug and reports a cheerful "built 1/1".
      #  * The publish only runs if reanchor-all printed its REANCHOR-COMPLETE marker. Its exit code cannot
      #    carry that: under EAP=Stop a throw exits 1, the same code it uses for "some specs still disagree".
      #    Without the marker a crash between the two halves would have republished cards from half-anchored
      #    specs - and reanchor-all now empties its slug list before starting, so a crash publishes nothing.
      if ($cv2Ok) {
        try {
          $mp = Split-Path $root -Parent
          $raOut = & powershell -ExecutionPolicy Bypass -File (Join-Path $mp 'meal-prep\pipeline\reanchor-all.ps1')
          foreach ($l in @($raOut)) { Log ('reanchor: ' + $l) }
          $raDone = @($raOut | Where-Object { $_ -match 'REANCHOR-COMPLETE' }).Count -gt 0
          $staleList = Join-Path $mp 'meal-prep\pipeline\reanchor-stale-cards.txt'
          $stale = @()
          if ($raDone -and (Test-Path $staleList)) { $stale = @(Get-Content $staleList | Where-Object { $_.Trim() -ne '' }) }
          $CAP = 150
          if (-not $raDone) {
            Log 'loop NOT closed: reanchor-all did not finish (no completion marker) - specs may be half-anchored, nothing republished'
            $summary += 'REVIEW    reanchor-all did not complete - the specs may be half re-anchored (quoting two prices) and no cards were republished'
            if (-not $NoAlert) { try { Send-Alert -Subject "Re-anchor did not complete - cards not republished" -Body ("reanchor-all.ps1 exited without its REANCHOR-COMPLETE marker, which means it died part-way through. Machine fields may be stamped while the prose still quotes the old price. Nothing was rebuilt or published. Run meal-prep\pipeline\reanchor-all.ps1 by hand and read the output.`n`nLast lines:`n" + ((@($raOut) | Select-Object -Last 10) -join "`n")) | Out-Null } catch {} }
          }
          elseif ($stale.Count -eq 0) { Log 'loop closed: no card cost moved today' }
          elseif ($stale.Count -gt $CAP) {
            Log ("loop NOT closed: $($stale.Count) cards moved, over the $CAP sanity cap - not republishing unattended")
            $summary += "REVIEW    $($stale.Count) recipe cards moved cost today (cap $CAP). Something systemic changed; review then run build-cards + publish for meal-prep\pipeline\reanchor-stale-cards.txt"
            if (-not $NoAlert) { try { Send-Alert -Subject "Recipe cards: $($stale.Count) moved, over the daily cap" -Body ("The daily chain re-anchored the specs but did NOT republish, because $($stale.Count) cards changed cost and the sanity cap is $CAP. A number this large usually means a shared row, a gpu, or a DB rename moved rather than ordinary price drift. Slug list: meal-prep\pipeline\reanchor-stale-cards.txt") | Out-Null } catch {} }
          } else {
            # A FAILED PUBLISH MUST SURVIVE THE RUN. Staleness is measured spec-vs-BUILT-card, and build-cards
            # runs first - so the moment the cards are rebuilt the spec and the card agree and tomorrow reports
            # a clean loop, while the LIVE page keeps the old number forever. The failure erases its own
            # evidence. Slugs therefore go into a pending file BEFORE the publish and are only cleared once it
            # actually succeeds, so a bad night retries on the next run instead of going quiet.
            $pendPath = Join-Path $mp 'meal-prep\pipeline\republish-pending.txt'
            if (Test-Path $pendPath) { $stale = @(@($stale) + @(Get-Content $pendPath | Where-Object { $_.Trim() -ne '' }) | Select-Object -Unique) }
            $stale | Out-File $pendPath -Encoding utf8
            $pubOk = $false
            try {
              Push-Location (Join-Path $mp 'meal-prep')
              try {
                & '.\engine\build-cards.ps1' -Slugs $stale | Select-Object -Last 1 | ForEach-Object { Log ('build-cards: ' + $_) }
                $bcRc = $LASTEXITCODE
                $pubOut = & '.\engine\publish.ps1' -Slugs $stale
                $pubRc  = $LASTEXITCODE
                foreach ($l in (@($pubOut) | Select-Object -Last 1)) { Log ('publish: ' + $l) }
                $pubOk = ($bcRc -eq 0 -and $pubRc -eq 0 -and @($pubOut).Count -gt 0)
                if (-not $pubOk) { Log ("publish did NOT succeed: build-cards rc=$bcRc, publish rc=$pubRc, " + @($pubOut).Count + ' output line(s)') }
              } finally { Pop-Location }   # without this a throw leaks CWD to meal-prep for the rest of the run
            } catch { Log ('build/publish threw: ' + $_.Exception.Message) }
            if ($pubOk) {
              Remove-Item $pendPath -ErrorAction SilentlyContinue
              Log ("loop closed: $($stale.Count) card(s) re-anchored and republished")
            } else {
              Log ("loop NOT closed: $($stale.Count) card(s) rebuilt but the publish failed - slugs held in republish-pending.txt for the next run")
              $summary += "REVIEW    $($stale.Count) recipe card(s) were rebuilt but did NOT publish - the live pages still show the old cost (meal-prep\pipeline\republish-pending.txt)"
              if (-not $NoAlert) { try { Send-Alert -Subject "Recipe cards rebuilt but publish failed" -Body ("The daily loop re-anchored $($stale.Count) card(s) and rebuilt them, but the publish step failed. The LIVE pages still show the old per-serving cost. Because staleness is measured spec-vs-built-card, this would otherwise read as clean from tomorrow on - the slugs are held in meal-prep\pipeline\republish-pending.txt and retried on the next run.") | Out-Null } catch {} }
            }
          }
        } catch { Log ('close-the-loop threw: ' + $_.Exception.Message) }
      } else { Log 'loop NOT closed: compute-v2 did not succeed, so the manifest is not trustworthy to re-anchor from' }
      # ---- CLOSE FAMILY FARE'S NO-LINK GAP, A LITTLE EVERY DAY. -------------------------------------------
      # resolve-worklist above only DETECTS; it has never added a link. The note further up claiming "the API
      # stores already self-heal in the daily job" was half true: refresh-hyvee-links re-points Hy-Vee's price
      # SNAPSHOTS, but nothing here ever filled a MISSING link. That is why 58 priced Family Fare tiles were
      # published with no "See item" link at all.
      # Family Fare is the one store resolvable without a browser (Freshop REST). Its documented budget is
      # ~40 calls before it 400s everything, so this takes 30/day and no more - the backlog grinds down over a
      # few days and then stays at zero as new items appear. Two steps because the resolver splits plan from
      # apply: the plan does the searching, -Apply writes it with zero network calls.
      # Safety: it links ONLY when the found product's name matches the board's own item AND its per-unit
      # equals the board's. Anything less confident is refused and left exactly as it was, because a link that
      # disagrees with the price does not fix the tile - it just moves the lie somewhere a shopper will find it.
      # Non-fatal, and guards still gate the publish.
      # ---- DERIVE LINKS FROM THE PRICE ROWS, BEFORE ANY SEARCH. -------------------------------------------
      # A price was fetched FROM a product; that product's id/URL is on the row. Deriving the link from the same
      # record the board priced makes price and link ONE fact that cannot drift. Searching the store to re-find
      # the product is a SECOND pipeline for the same fact, and every wrong link we have ever shipped came from
      # the two disagreeing ("Hy Vee Almondmilk" priced, "Blue Diamond Almond Breeze" linked).
      # This runs FIRST so the searchers only ever work on what identity could not cover.
      try {
        $dlOut = & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'derive-links-from-prices.ps1') -Apply
        Log ('derive-links-from-prices: ' + ((@($dlOut) | Where-Object { $_ -match 'APPLIED' })[-1]))
      } catch { Log ('derive-links-from-prices threw: ' + $_.Exception.Message) }
      try {
        & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'audit-tile-integrity.ps1') -Quiet | Out-Null
        if ($LASTEXITCODE -eq 3) { Log 'tile-integrity BLIND (zero links graded) - the link layer is empty/unreadable; fix-links-ff is about to run against nothing' }
        & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'fix-links-ff.ps1') -Fresh -MaxCalls 30 | Out-Null
        $ffOut = & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'fix-links-ff.ps1') -Apply
        Log ('family-fare link fill: ' + (@($ffOut | Where-Object { $_ -match 'APPLIED' })[-1]))
      } catch { Log ('fix-links-ff threw: ' + $_.Exception.Message) }
      # ---- NEVER SHIP A LINK WE CANNOT PROVE. --------------------------------------------------------------
      # Brad's bar is 100% ACCURATE, and accuracy and coverage are different promises. A tile with a price and
      # no link is incomplete; a tile whose link opens a DIFFERENT product is a lie - the shopper clicks, sees
      # $4.99 where we said $2.98, and concludes the board inflates its deals. Prices move daily, links go
      # stale, and merge-product-urls can resurrect old ones, so this has to run EVERY day, not once.
      # It removes any link that is not positively verified against the board (wrong product, wrong price,
      # unverifiable per-unit, or no price to check). The tile falls back to a price with no link, which is
      # honest. name-drift must run FIRST - it is the product-identity check the pruner reads.
      try {
        & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'audit-name-drift.ps1') | Out-Null
        if ($LASTEXITCODE -eq 3) { Log 'name-drift BLIND: examined ZERO cells - its count=0 output is not clean; prune-bad-links and the builder link suppression are running with no product-identity input'; $summary += 'REVIEW    audit-name-drift examined ZERO cells (product-urls/board mismatch) - wrong-product links are unguarded this run' }
        # -Tol 0.32, SAME as the repair path below and as guard 4's factor rule (>=1.5x / <=0.67x). I first
        # wired this with the default 2%, which deletes a RIGHT-product link the moment the store nudges its
        # price - eroding coverage a little every day to enforce a threshold the accuracy gate itself does not
        # use. One tolerance, everywhere: a link is removed for being a different PRODUCT (any drift counts as
        # a factor error), never for its snapshot being a few cents old.
        $pbOut = & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'prune-bad-links.ps1') -Tol 0.32
        Log ('prune-bad-links: ' + ((@($pbOut) | Where-Object { $_ -match 'DROPPED' }) -join ' | '))
      } catch { Log ('prune-bad-links threw: ' + $_.Exception.Message) }
      # ---- RE-DERIVE THE DRIFT VERDICTS OVER THE PRUNED LINK SET (2026-08-22) -------------------------
      # THIS IS A REAL CYCLE, AND IT BLOCKED THE BOARD THREE TIMES TODAY. prune-bad-links READS
      # out
ame-drift.json (it is how it knows which links are the wrong PRODUCT) and then WRITES
      # product-urls.json - which makes name-drift.json older than the links it describes. audit-tile-
      # integrity refuses to grade in that state, on purpose and correctly: "a green from a stale flags
      # file is exactly the false green this assertion exists to prevent". So on every day the pruner
      # actually drops a link, guards hard-failed and NOTHING PUBLISHED - measured 2026-08-22, three runs,
      # name-drift.json 2 seconds older than product-urls.json. On quiet days the pruner writes nothing,
      # the timestamps hold, and the gate passes - which is why this looked intermittent rather than
      # structural. The chain's own auto-repair loop already resolves the cycle exactly this way (it
      # re-runs name-drift after its prune); the ship path simply never did.
      # Conditional on the file actually moving, so a quiet day does not pay for a second pass.
      try {
        $ndF = Join-Path $OutDir 'name-drift.json'
        $puF = Join-Path $root 'product-urls.json'
        if ((Test-Path $ndF) -and (Test-Path $puF) -and ((Get-Item $puF).LastWriteTimeUtc -gt (Get-Item $ndF).LastWriteTimeUtc)) {
          & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'audit-name-drift.ps1') | Out-Null
          Log 'name-drift re-derived over the pruned link set (the pruner rewrote product-urls, which stales the drift table tile-integrity grades against)'
        }
      } catch { Log ('name-drift re-derive threw: ' + $_.Exception.Message) }
      $sigAfter = BoardSignature
      $sigFile  = Join-Path $OutDir 'published-board.sig'
      $prevPub  = if (Test-Path $sigFile) { ((Get-Content $sigFile -Raw) + '').Trim() } else { '' }
      # republish when the price/type/ad-window signature moved OR a new ad window flipped (belt-and-suspenders)
      $boardChanged = ($sigAfter -ne $sigBefore) -or ($sigAfter -ne $prevPub) -or (@($flips).Count -gt 0)
      if (@($flips).Count -gt 0) { Log ("downstream refreshed after flips: " + ($flips -join ',')) }
      # AUTO-PUBLISH only when the board changed. publish-deals-page.ps1 self-gates on coverage, rebuilds
      # (recomputing the sale-window badges), and republishes preserving visibility.
      # ---- HARD INVARIANT GATE ------------------------------------------------------------------
      # guards.ps1 blocks the publish if any invariant that is ALWAYS a bug is violated: a mode-sensitive
      # store off the in-store catalogue, a cleaning product priced as food, an override pin that beats the
      # engine, a board cell that differs from its own linked product by a FACTOR (the 2x/3x/12x/24x
      # quantity bugs - ordinary price drift is ignored), or a multipack priced as a single unit.
      # These are exactly the classes that shipped wrong prices on 2026-07-14 while every existing gate
      # stayed green, so a failure here must stop the board going live, not just log.

      # Pins are minted HERE, before guards, so every number the build can apply passes the gate first.
      # (Until 2026-07-23 publish-deals-page regenerated them post-gate; a carried-row day minted 37
      # wrong-basis pins the guards never saw. Publish now only APPLIES the pins file.)
      try { & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'generate-board-overrides.ps1') | ForEach-Object { Log ('pins: ' + $_) } } catch { Log ('WARN generate-board-overrides threw: ' + $_.Exception.Message) }
      $guardsRc = 0
      try {
        & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'guards.ps1') | ForEach-Object { Log ('guards: ' + $_) }
        $guardsRc = $LASTEXITCODE
      } catch { $guardsRc = 2; Log ('guards threw: ' + $_.Exception.Message) }
      $guardsBlocked = ($guardsRc -ne 0)
      # ---- THE VERDICT AS A VALUE, NOT A SIDE EFFECT (2026-08-22) --------------------------------------
      # Guards holding the Ghost publish is only half a gate: export-feed has ALREADY written
      # public\smp-feed.json by this point (it runs in the recipe lane above), and capture-run's publish
      # stage commits public\** to git, which is what Cloudflare deploys. So a board this gate rejected
      # could still reach every recipe card on the site while the board POST correctly stayed at last-good.
      # This file cannot answer that with an exit code - bakers-daily-scan and daily.yml both read its rc
      # and would change meaning - so it states the verdict where the publisher can read it.
      try {
        ([ordered]@{
          date = $asofS; written = (Get-Date).ToString('s'); guards_rc = $guardsRc
          guards_blocked = [bool]$guardsBlocked
          note = 'Written by check-ad-cycles after guards. capture-run reads guards_blocked before it stages public\** or meal-prep\** - a board the gate rejected must never reach the edge.'
        } | ConvertTo-Json -Depth 4) | Set-Content -Path (Join-Path $OutDir 'chain-verdict.json') -Encoding UTF8
      } catch { Log ('chain-verdict write threw: ' + $_.Exception.Message) }
      if ($guardsBlocked) {
        # Do NOT reuse $boardChanged here: that would log "no price change today", which is a lie -
        # the board DID change, we refused to ship it. A misleading log is how an outage goes unnoticed.
        Log 'GUARDS FAILED - board NOT republished (left at last good state)'
        $summary += 'BLOCKED   guards failed a hard invariant - live page left at last good, NOT updated'
        if (-not $NoAlert) {
          try { Send-Alert -Subject "Grocery: GUARDS FAILED - board not published - $asofS" -Body "guards.ps1 found a hard invariant violation on $asofS (wrong-mode store, cleaner priced as food, a pin overriding the engine, a cell off its linked product by a FACTOR, or a multipack priced as one unit). The live page was left at its last good state. See grocery/ad-cycle-log.txt." | Out-Null } catch {}
        }
      }

      # weekly shareable drops graphic (also the board post's og:image). Refresh BEFORE publish so the
      # og:image step sees today's png. Non-fatal: a share graphic must never block prices.
      try { & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'build-share-image.ps1') | ForEach-Object { Log ('share: ' + $_) } } catch { Log ('share-image threw: ' + $_.Exception.Message) }

      if ($guardsBlocked) {
        # already logged + alerted above; fall through without publishing
      } elseif (-not $boardChanged) {
        Log 'no price change today - board already current, nothing republished'
        $summary += 'CURRENT   no price change today - live page already current'
      } elseif (-not $NoPublish) {
        & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'publish-deals-page.ps1') | Out-Null
        $pubrc = $LASTEXITCODE
        if ($pubrc -eq 0)     { Set-Content -Path $sigFile -Value $sigAfter -Encoding ASCII; Log ('AUTO-PUBLISH: live page updated (price change' + $(if (@($flips).Count -gt 0) { '/new ad' } else { ' mid-cycle' }) + ')'); $summary += 'PUBLISHED live page updated (price change detected)' }
        elseif ($pubrc -eq 2) {
          Log 'AUTO-PUBLISH HELD: coverage gate failed - live page NOT updated'
          $summary += 'HELD      coverage gate failed - live page NOT updated (a store pull is thin/missing)'
          if (-not $NoAlert) { try { Send-Alert -Subject "Grocery page HELD (coverage) - $asofS" -Body "A refreshed board failed the coverage gate on $asofS (a store's pull produced too few commodities), so the live page was NOT updated - nothing bad was published. Check the store pulls." | Out-Null } catch { Log ('held-alert threw: ' + $_.Exception.Message) } }
        }
        else { Log "AUTO-PUBLISH ERROR (rc=$pubrc) - Ghost upsert or build failed; live page NOT updated"; $summary += 'ERROR     auto-publish failed (page NOT updated) - see ad-cycle-log.txt'; if (-not $NoAlert) { try { Send-Alert -Subject "Grocery publish FAILED (rc=$pubrc) - $asofS" -Body "publish-deals-page.ps1 returned $pubrc on $asofS (Ghost upsert or page build failed). The live page was NOT updated with today's price change. Check ad-cycle-log.txt." | Out-Null } catch {} } }
      }

      # ---- CONSISTENCY GUARD: enforce "the price shown == the product the 'See item' link opens", every day.
      # audit-board-consistency.ps1 returns 2 when too many chips fall back to a name (a link was suppressed
      # because its price no longer matches - divergence or a stale board price). On breach we AUTO-REPAIR the
      # Family Fare links (re-point each to the exact product the board priced, at today's price - the API path
      # that can run headless in the cloud), re-merge, republish, and re-audit. A breach that survives repair =
      # a browser-store shelf price drifted from the board (needs a re-pull); we alert Brad ONCE per distinct
      # drift set (signature de-dup, so a stable backlog never spams) even under -NoAlert.
      if (-not $NoPublish) {
        try {
          & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'audit-board-consistency.ps1') | Out-Null
          if ($LASTEXITCODE -eq 2) {
            Log 'consistency BREACH - auto-repairing Family Fare + Hy-Vee links + republishing'
            try {
              & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'resolve-ff-boardmatch.ps1') | Out-Null
              # Hy-Vee no-link + wrong-size chips self-heal the SAME way, headless via Hy-Vee's search API.
              # Added 2026-07-14: this repair ran Family Fare ONLY, so Hy-Vee no-link gaps never closed on their
              # own and the board sat at 25 linkless Hy-Vee chips. resolve-hyvee-links board-matches by
              # size+brand+price and writes product-urls.json directly, so it runs BEFORE the merge; the
              # prune-bad-links + guards gate below still catch anything it produces that drifts by a factor.
              & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'resolve-hyvee-links.ps1') | Out-Null
              # CAUTION: merge-product-urls re-merges EVERY store-*-urls.json still sitting in
              # out\url-inputs\, so a stale resolver file left behind can RESURRECT an old link and
              # overwrite a good one (it silently corrupted ~226 links on 2026-07-14). Old resolver
              # outputs therefore live in out\url-inputs-archive\, NOT out\url-inputs\.
              & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'merge-product-urls.ps1')     | Out-Null
              # Prune at a FACTOR tolerance, NOT the strict 2%. Rationale:
              #   - strict 2% would delete a perfectly good link the moment a store nudged its price
              #     (the board refreshes daily; the link's price snapshot does not), eroding coverage;
              #   - but a link left off by a FACTOR (a wrong SKU / a pack counted as one unit) would
              #     trip guards.ps1 below and BLOCK the board every single day.
              # 0.32 drops everything guards would hard-fail on (ratio >=1.5x or <=0.67x) and nothing
              # else, so the repair is self-healing and the gate can never deadlock the daily publish.
              & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'prune-bad-links.ps1') -Tol 0.32 | Out-Null
              # THE PERMANENT FIX for browser-store link regression: prune just dropped any link that drifted by
              # a factor (a wrong SKU/size), which would leave a no-link gap. sync-browser-links immediately
              # re-creates any browser link that is now missing but whose row still carries the product identity
              # (item_id for Walmart/Sam's, a captured URL for Baker's), board-ANCHORED so it matches by
              # construction. Net: a browser link pruned for drift is healed in the SAME pass and never stays a
              # gap. Heal-only (never overwrites a healthy link, so guard 4 keeps checking those independently).
              & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'sync-browser-links.ps1') | Out-Null
              # A MATCH FIX THAT MOVED A PRICE ORPHANED THAT CELL'S LINK (wired 2026-08-21).
              # sync-browser-links heals a link that is MISSING; it does not notice one that is merely
              # pointing at last week's winner. When a rule change moves which product holds a cell, the
              # pin in product-urls.json still opens the old one, and nothing finds out until tile-integrity
              # fails on the next pass. relink-drifted-cells.ps1 was written for exactly that on 2026-08-21,
              # after the same manual remedy was applied four times in one day (cloves $11.92 -> $2.99 with
              # the link still opening the McCormick jar, and three siblings). It shipped with NO production
              # caller, so the step it was built to stop forgetting was still being forgotten - the census
              # caught it as an orphan. It belongs HERE: after the links are healed, before name-drift forms
              # the identity verdict that guards and the pins both read. Non-fatal by design.
              # -Apply IS LOAD-BEARING. Without it the script is READ-ONLY and exits 1 having repaired
              # nothing - so a caller that omits it reports drift daily and fixes it never, which is a
              # wired-but-inert guard and no better than the orphan it replaced. It re-derives per STORE,
              # only the stores that actually drifted (a global -Apply once re-pointed ~40 Fareway links
              # onto pack prices while fixing Sam's - that scar is why the script groups by store).
              try { & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'relink-drifted-cells.ps1') -Apply | ForEach-Object { Log ('relink: ' + $_) } }
              catch { Log ('relink-drifted-cells threw: ' + $_.Exception.Message) }
              # REFRESH THE IDENTITY INPUT BEFORE ANYTHING READS IT. name-drift.json is the product-identity
              # verdict that BOTH generate-board-overrides (it refuses to pin a flagged cell) and guards'
              # tile-integrity WRONG-PRODUCT gate consume - and the prune+sync above just rewrote the links it
              # describes. Left stale, every link the heal just CORRECTED still reads as wrong: measured
              # 2026-07-30, five Walmart cells (balsamic-vinegar, hominy, diapers, oat-milk, tampons) whose
              # healed link matched the board byte-for-byte kept failing the hard gate until name-drift was
              # re-run, and it cleared to ACCURACY 0 the moment it was. A heal that fixes links must not leave
              # the gate holding yesterday's opinion of them. -Phase links in weekly-post-capture.ps1 has
              # always done this; this path is the one that was missing it.
              & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'audit-name-drift.ps1') | Out-Null
              if ($LASTEXITCODE -eq 3) { Log 'name-drift BLIND after link repair - guards will grade WRONG-PRODUCT with no identity input' }
              # This repair path used to publish DIRECTLY, which would have bypassed the invariant gate.
              # Links just changed, so pins derived from them must be re-minted BEFORE guards re-check
              # (same publish-never-mints rule as the main gate above).
              try { & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'generate-board-overrides.ps1') | Out-Null } catch {}
              & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'guards.ps1') -Quiet | Out-Null
              if ($LASTEXITCODE -eq 0) {
                & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'publish-deals-page.ps1')   | Out-Null
              } else {
                Log 'GUARDS FAILED after consistency auto-repair - NOT republished (left at last good)'
                $summary += 'BLOCKED   guards failed after consistency auto-repair - live page left at last good'
              }
            } catch { Log ('consistency auto-repair threw: ' + $_.Exception.Message) }
            & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'audit-board-consistency.ps1') | Out-Null
            if ($LASTEXITCODE -eq 2) {
              $cr = try { Get-Content (Join-Path $OutDir 'consistency-report.json') -Raw | ConvertFrom-Json } catch { $null }
              $nl = if ($cr) { [string]$cr.no_link_count } else { '?' }
              # signature covers BOTH failure kinds: price-drift mismatches AND no-link chips (a pure no-link
              # breach used to hash to '' and could never de-dup properly)
              $driftSig = if ($cr) { (@(@($cr.mismatch) + @($cr.no_link) | Where-Object { $_ } | ForEach-Object { $_.id + '|' + $_.store } | Sort-Object -Unique) -join ';') } else { '' }
              $csigF = Join-Path $OutDir 'consistency-alert.sig'
              $prevSig = if (Test-Path $csigF) { ((Get-Content $csigF -Raw) + '').Trim() } else { '' }
              Log ("consistency STILL breached after repair - no-link=$nl (browser-store price drift, needs re-pull)")
              $summary += "REVIEW    board-link drift: $nl chips show a name not a link - see consistency-report.json"
              if ($driftSig -ne $prevSig -and (-not $NoAlert)) {
                try { Send-Alert -Subject "Grocery: board-link price drift ($nl chips) - $asofS" -Body "$nl priced chips fall back to a product name (no 'See item' link) after auto-repair on $asofS, because a store's shelf price drifted from the board. NO misleading link is shown. Re-pull the flagged store(s). Details: grocery/out/consistency-report.json." | Out-Null
                      if ($LASTEXITCODE -eq 0) { Set-Content -Path $csigF -Value $driftSig -Encoding UTF8; Log 'consistency drift alert sent' } } catch { Log ('consistency alert threw: ' + $_.Exception.Message) }
              } else { Log 'consistency drift unchanged since last alert - not re-alerting' }
            } else { Log 'consistency repaired - all shown links match their price'; if (Test-Path (Join-Path $OutDir 'consistency-alert.sig')) { Remove-Item (Join-Path $OutDir 'consistency-alert.sig') -ErrorAction SilentlyContinue } }
          } elseif ($LASTEXITCODE -eq 3) {
            # exit 3 = could-not-evaluate (P6). Before 2026-07-30 this branch did not exist, so a consistency
            # run that examined ZERO chips - feed missing, or the pg-chip markup drifted - fell into the else
            # below and was logged as "consistency OK": the guard's blindest state wearing its healthiest label.
            Log 'consistency BLIND - the auditor examined 0 priced chips; "no-link=0" today means nothing (see chips_examined in out\consistency-report.json)'
            $summary += 'REVIEW    board-consistency examined 0 chips - the price/link check is not running; check public\board.json and the pg-chip markup in build-deals-page.ps1'
          } else { Log 'consistency OK - every shown link matches its price' }
        } catch { Log ('consistency guard threw: ' + $_.Exception.Message) }
      }

      # ================================================================================================
      # SHIP / INSPECT BOUNDARY (2026-08-22). Everything ABOVE this line is the SHIP path: the work that
      # decides what the live board, the public feed and the recipe cards say, ending at the publish and
      # its consistency auto-repair. Everything BELOW is INSPECT: advisory auditing that reports, alerts
      # and queues, and CANNOT change what has already shipped.
      # Why the split exists: measured on 2026-08-22 the whole chain ran 31-42 minutes, of which the
      # product path was ~6-7. Under Task Scheduler's 2h ceiling - and under any late throw - the day's
      # prices were held hostage by auditing that could never block a publish anyway. Ship first, inspect
      # after: a crash below this line now costs a report, not a board.
      # KEEP THE ORDER ABOVE. It is a dependency chain, not a preference: export-feed BEFORE compute-v2
      # (it writes the feed compute-v2 resolves), and audit-name-drift BEFORE guards - guard 3's
      # WRONG-PRODUCT hard fail reads out\name-drift.json and generate-board-overrides refuses pins from
      # links it flags, so moving name-drift below makes that gate structurally unfirable.
      # ================================================================================================
      $script:DownstreamRan = $true
      $shipSecs = [int]((Get-Date) - $script:ShipStart).TotalSeconds
      Log ('---- SHIP PATH COMPLETE in ' + $shipSecs + ' s (' + [math]::Round($shipSecs/60.0,1) + ' min): the board, the feed and the cards are published. INSPECT (advisory audits) starts now and cannot change what shipped. ----')
      $summary += ('SHIP      ship path completed in ' + $shipSecs + ' s (' + [math]::Round($shipSecs/60.0,1) + ' min) - the board published before any advisory audit ran')

      # ---------------------------------------------------------------------------------------------
      # INSPECT PATH - ADVISORY ONLY. Nothing below may hold, change or unpublish today's board. Several
      # of these stages take minutes each and used to run BEFORE the publish, which is exactly what made
      # a killed or late-throwing chain cost the day's prices.
      # ---------------------------------------------------------------------------------------------
      # THESE TWO PUBLISH SITE CONTENT, so they lead the inspect path rather than trailing it: everything
      # they read (the v2 manifest, the ingredient map) is a SHIP output that is already final, and if this
      # phase is ever cut short they should be the first thing that got done, not the last thing that did not.
      # re-cost the recipes from today's board + refresh the hub's Top 5 (only publishes on change). Non-fatal.
      # Brad's final call 2026-07-25: the ORIGINAL SMP-TOP5 hub section stays (he preferred it over the
      # green free-week grid, which was removed same day). The free ROTATION still runs below - it just
      # renders nothing on the hub; the Top 5 section is the display.
      try { & powershell -ExecutionPolicy Bypass -File (Join-Path (Split-Path $root -Parent) 'meal-prep\top5-weekly.ps1') | Out-Null; Log 'top5-weekly refreshed' } catch { Log ('top5-weekly threw: ' + $_.Exception.Message) }
      # Free-dinner rotation (Brad, 2026-07-25): top 5 cheapest dinners per protein go FREE for the board
      # week; they revert to members-only when the week re-ranks them. Runs daily right after re-costing but
      # no-ops until the board week (or the set) changes, so flips happen on the ad flip. Non-fatal.
      try { (Invoke-Bounded 'free-rotation' @('-ExecutionPolicy','Bypass','-File',(Join-Path (Split-Path $root -Parent) 'meal-prep\rotate-free-dinners.ps1')) 900).Output | ForEach-Object { Log ('free-rotation: ' + $_) } } catch { Log ('rotate-free-dinners threw: ' + $_.Exception.Message) }

      # NOTE: the coverage-REGRESSION check (a store quietly shrinking between boards) is NOT run here. It is a
      # hard invariant, so it lives in guards.ps1 where a failure actually stops the publish. Setting $hardFail
      # at this point would not: the publish (now ABOVE, on the ship path) gates on $guardsBlocked, and $hardFail
      # was already read at the top of this block - so it would log "publish HELD" while the board shipped anyway.
      # ---- COVERAGE GAP GUARD: a store SILENTLY dropped from a commodity it actually carries (a too-strict
      # include regex not matching that store's real product name - the Hy-Vee "Pork Loin TOP Loin Chops" bug).
      # audit-coverage-gaps.ps1 scans each missing store's raw pull for a loosened-include match; a hit = fix the
      # commodity's include (or allowlist it). Alert Brad ONCE per distinct gap-set (signature de-dup) so it is
      # never silent but never spams. Advisory (we still publish the current board).
      try {
        $cgRc = (Invoke-Bounded 'coverage-gaps' @('-ExecutionPolicy','Bypass','-File',(Join-Path $root 'audit-coverage-gaps.ps1')) 900).ExitCode
        if ($cgRc -eq 3) {
          # BLIND: the file on disk is a PREVIOUS day's. Reading it here would dedupe today against
          # yesterday's gap set and report "unchanged" about a scan that never happened.
          Log 'coverage-gaps BLIND (killed at its budget or the job broke) - no gap opinion on this board'
          $summary += 'REVIEW    audit-coverage-gaps could not evaluate - the store-dropped-a-commodity check did not run this cycle'
          throw 'CG-BLIND'
        }
        $cg = try { Get-Content (Join-Path $OutDir 'coverage-gaps.json') -Raw | ConvertFrom-Json } catch { $null }
        # ---- ALERT ON THE ACTIONABLE SUBSET ONLY (2026-08-06, triage plan-2026-08-06 item 2026-08-03-f4fb91).
        # The audit already separates a gap it can act on (CLAIMED-BY / RULE-INVISIBLE / PRICED) from one the
        # ENGINE ITSELF explains and refuses on purpose (BASIS-NULL: an each-priced commodity whose only rows at
        # that store are cut trays or weights; BAND-DROPPED: the sanity band saving us from a moisturiser called
        # "Orchid & Plum"). Those are permanent, correct refusals - 44 of the 51 rows on 2026-08-05, 35 of 43 the
        # next morning. Counting and signaturing the FULL set meant any churn in a quiet row re-paged the whole
        # list, and the 7 real rows arrived buried in it. Count, list and signature the ACTIONABLE subset; the
        # quiet rows stay in coverage-gaps.json for the record and are still reported in the Log line.
        # <<COVERAGE-GAP-ALERT-BEGIN>> test-auditors.ps1 extracts this region and runs it against a frozen file.
        $cgAll = @($cg.gaps | Where-Object { $_ })     # @($null).Count is 1 in PS 5.1 - filter, never assume
        $cgHasFlag = @($cgAll | Where-Object { $_.PSObject.Properties['actionable'] }).Count -gt 0
        # FAIL OPEN on an old coverage-gaps.json with no actionable field: alert on everything rather than
        # silently on nothing. A detector that goes quiet because a field was renamed is the worst outcome here.
        $cgAct = if ($cgHasFlag) { @($cgAll | Where-Object { $_.actionable }) } else { $cgAll }
        if ($cg -and $cgAct.Count -gt 0) {
          $cgSig = (@($cgAct | ForEach-Object { $_.commodity + '|' + $_.store } | Sort-Object) -join ';')
          $cgF = Join-Path $OutDir 'coverage-gap-alert.sig'
          $cgPrev = if (Test-Path $cgF) { ((Get-Content $cgF -Raw) + '').Trim() } else { '' }
          $cgList = (@($cgAct | ForEach-Object { $_.commodity + ' @ ' + $_.store }) -join '; ')
          Log ("coverage-gaps: $($cgAll.Count) gap(s), $($cgAct.Count) actionable - $cgList")
          $summary += "REVIEW    coverage gaps: $($cgAct.Count) actionable of $($cgAll.Count) store(s) dropped despite carrying the item - see coverage-gaps.json"
          if ($cgSig -ne $cgPrev -and (-not $NoAlert)) {
            try { Send-Alert -Subject "Grocery: $($cgAct.Count) store(s) dropped from a commodity they carry - $asofS" -Body "audit-coverage-gaps found stores that HAVE a matching product but are missing from the board (usually a too-strict include regex): $cgList. Fix that commodity's include in commodities.json (or add a reviewed exception to coverage-gap-allowlist.json). $($cgAll.Count - $cgAct.Count) further gap(s) are engine-explained (BASIS-NULL / BAND-DROPPED) and are listed in the report without paging. Details: grocery/out/coverage-gaps.json." | Out-Null
                  if ($LASTEXITCODE -eq 0) { Set-Content -Path $cgF -Value $cgSig -Encoding UTF8; Log 'coverage-gap alert sent' } } catch { Log ('coverage-gap alert threw: ' + $_.Exception.Message) }
          } else { Log 'coverage-gaps unchanged since last alert - not re-alerting' }
        }
        # <<COVERAGE-GAP-ALERT-END>>
        elseif ($cg -and $cgAll.Count -gt 0) {
          Log ("coverage-gaps: $($cgAll.Count) gap(s), 0 actionable - every one is engine-explained (BASIS-NULL / BAND-DROPPED); reported, not paged")
          $summary += "REVIEW    coverage gaps: 0 actionable of $($cgAll.Count) - all engine-explained, see coverage-gaps.json"
          if (Test-Path (Join-Path $OutDir 'coverage-gap-alert.sig')) { Remove-Item (Join-Path $OutDir 'coverage-gap-alert.sig') -ErrorAction SilentlyContinue }
        }
        elseif ($cg -and @($cg.stores_not_scanned | Where-Object { $_ }).Count) {
          $ns = (@($cg.stores_not_scanned | Where-Object { $_ }) -join ', ')
          Log ("coverage-gaps BLIND for: " + $ns + " - zero raw products parsed; those stores were never checked")
          $summary += "REVIEW    coverage-gaps scanned 0 products for $ns - the 'no gaps' result does not cover those stores"
        } else { if (Test-Path (Join-Path $OutDir 'coverage-gap-alert.sig')) { Remove-Item (Join-Path $OutDir 'coverage-gap-alert.sig') -ErrorAction SilentlyContinue } }
      } catch {
        # CG-BLIND is this block's own deliberate exit (the audit could not evaluate); it has already
        # logged and summarised, so do not re-report it as a crash - that would read like a code fault.
        if ($_.Exception.Message -ne 'CG-BLIND') { Log ('coverage-gap guard threw: ' + $_.Exception.Message) }
      }
      # ---- SEMANTIC SWEEP (added 2026-08-01): the coverage guard above is REGEX reasoning about regex - it can
      # only find a store that a LOOSENED version of the same include would have matched. It cannot see a product
      # whose name shares no vocabulary with the rule at all, which is how a $45 spice jar won ground-cloves
      # unopposed: Family Fare writes "Cloves, Ground" and every include read "ground cloves". This scans the raw
      # pulls with an embedding model instead, so it reads MEANING and finds what the words hide.
      # Strictly advisory, and BLIND-not-block: exit 3 (no GPU, no python, no corpus) must never stop the daily
      # publish, and findings never change a price, a crown, a rule or a link on their own. Signature de-dup so
      # a standing backlog is reported ONCE and only genuinely NEW findings speak up again.
      try {
        $semRc = (Invoke-Bounded 'semantic' @('-ExecutionPolicy','Bypass','-File',(Join-Path $root 'audit-semantic-identity.ps1')) 900).ExitCode
        if ($semRc -eq 3) {
          Log 'semantic sweep BLIND (no sidecar/GPU available) - the board still ships; no coverage opinion today'
          $summary += 'REVIEW    semantic sweep could not run (BLIND) - no semantic coverage check on this board'
        } else {
          $sf = try { Get-Content (Join-Path $OutDir 'semantic-findings.json') -Raw | ConvertFrom-Json } catch { $null }
          $semRows = @($sf.coverage)
          if ($semRows.Count -gt 0) {
            $semSig = (@($semRows | ForEach-Object { [string]$_.id + '|' + [string]$_.store + '|' + [string]$_.product } | Sort-Object) -join ';')
            $semF = Join-Path $OutDir 'semantic-alert.sig'
            $semPrev = if (Test-Path $semF) { ((Get-Content $semF -Raw) + '').Trim() } else { '' }
            $semIds = (@($semRows | ForEach-Object { [string]$_.id } | Sort-Object -Unique) -join ', ')
            Log ("semantic sweep: $($semRows.Count) product(s) invisible to the rules across $(@($semRows | Group-Object id).Count) commodit(y/ies) - $semIds")
            $summary += "REVIEW    semantic sweep: $($semRows.Count) real product(s) no rule can see - see semantic-findings.json"
            if ($semSig -ne $semPrev -and (-not $NoAlert)) {
              try { Send-Alert -Subject "Grocery: semantic sweep found $($semRows.Count) product(s) no rule can see - $asofS" -Body "The embedding sweep found real store products that look like a tracked commodity but match NO include pattern, so they can never win a cell - not this week and not any future week. Commodities: $semIds. Work them with explain-coverage-gap.ps1 (diagnose WHY: NO-INCLUDE / EXCLUDED / CLAIMED / MATCHES) then apply-coverage-batch.ps1 (applies and gates one batch). Anything that is genuinely a different product gets a ruling via add-known-wrong.ps1 instead of a rule. Details: grocery/out/semantic-findings.json." | Out-Null
                    if ($LASTEXITCODE -eq 0) { Set-Content -Path $semF -Value $semSig -Encoding UTF8; Log 'semantic sweep alert sent' } } catch { Log ('semantic alert threw: ' + $_.Exception.Message) }
            } else { Log 'semantic findings unchanged since last alert - not re-alerting' }
          } else {
            Log 'semantic sweep: no invisible products found'
            if (Test-Path (Join-Path $OutDir 'semantic-alert.sig')) { Remove-Item (Join-Path $OutDir 'semantic-alert.sig') -ErrorAction SilentlyContinue }
          }
        }
      } catch { Log ('semantic sweep threw: ' + $_.Exception.Message) }
      # ---- AISLE TEST ON THE LIVE BOARD (added 2026-08-01). The sweep above finds products no rule can
      # SEE. This finds the opposite defect: a product the rules DID match that the STORE files in a
      # department the commodity has no business occupying. First live run read 406 Family Fare cells and
      # found five wrong products, TWO holding the cheapest-price crown - cat litter as `baking-soda` at
      # $0.0375/oz, teriyaki brats as `pineapple` at $1.3725. Neither is a pricing error, which is exactly
      # why no price guard could see them, and audit-food-category caught 0 of the 26 browse-test flips.
      # Advisory + signature-deduped: ~22 known department-map false positives (spices shelved in produce,
      # canned milks in dairy) would otherwise shout every day, so only a CHANGED block-set speaks. The
      # gate is deliberately NOT loosened to silence them - that would trade a real defect class for quiet.
      try {
        & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'aisle-test.ps1') -LiveBoard *>&1 | Out-Null
        $atRc = $LASTEXITCODE
        if ($atRc -eq 3) {
          Log 'aisle test BLIND (no board or no Family Fare feed) - no shelf opinion on this board'
        } else {
          $atJ = try { Get-Content (Join-Path $OutDir 'aisle-test.json') -Raw | ConvertFrom-Json } catch { $null }
          $atBlocked = @($atJ | Where-Object { [string]$_.verdict -eq 'BLOCK' })
          if ($atBlocked.Count -gt 0) {
            $atSig = (@($atBlocked | ForEach-Object { [string]$_.id + '|' + [string]$_.product } | Sort-Object) -join ';')
            $atF = Join-Path $OutDir 'aisle-alert.sig'
            $atPrev = if (Test-Path $atF) { ((Get-Content $atF -Raw) + '').Trim() } else { '' }
            $atIds = (@($atBlocked | ForEach-Object { [string]$_.id } | Sort-Object -Unique) -join ', ')
            Log ("aisle test: $($atBlocked.Count) live cell(s) sit in a department their commodity does not occupy - $atIds")
            $summary += "REVIEW    aisle test: $($atBlocked.Count) live cell(s) in the wrong store department - see out\aisle-test.json"
            if ($atSig -ne $atPrev -and (-not $NoAlert)) {
              try { Send-Alert -Subject "Grocery: $($atBlocked.Count) board cell(s) sit in the wrong store department - $asofS" -Body "aisle-test judged the LIVE board against Family Fare's own shelf paths and found cells whose product the STORE files in a department the commodity never occupies. This is the class that finds cat litter priced as baking soda and teriyaki brats priced as pineapple - real prices on the wrong product, so no price guard can see them. Commodities: $atIds. Check the CROWN rows first (a wrong crown is the cheapest-price verdict shoppers see). Fix by tightening that commodity's exclude, then record the product via add-known-wrong.ps1. NOTE: a standing ~22 are known department-map false positives (spices shelved in produce, canned milks in dairy) - compare against the previous set. Details: grocery/out/aisle-test.json." | Out-Null
                    if ($LASTEXITCODE -eq 0) { Set-Content -Path $atF -Value $atSig -Encoding UTF8; Log 'aisle-test alert sent' } } catch { Log ('aisle alert threw: ' + $_.Exception.Message) }
            } else { Log 'aisle-test block-set unchanged since last alert - not re-alerting' }
          } else {
            Log 'aisle test: no live cell sits in a wrong department'
            if (Test-Path (Join-Path $OutDir 'aisle-alert.sig')) { Remove-Item (Join-Path $OutDir 'aisle-alert.sig') -ErrorAction SilentlyContinue }
          }
        }
      } catch { Log ('aisle test threw: ' + $_.Exception.Message) }
      # ---- MATCHING-SOUNDNESS GUARD: a WRONG product landing in a commodity, or a rule change quietly moving/
      # dropping an existing product vs the reviewed baseline (the 2026-07-13 matching-audit class). No other
      # guard catches theft-IN. audit-match-soundness -Alert self-dedups and emails on a NEW issue-set; a
      # MOVED/DROPPED also makes it exit 2 so the publish gate holds. Advisory here (the daily board still ships).
      try {
        $msArgs = @('-ExecutionPolicy','Bypass','-File',(Join-Path $root 'audit-match-soundness.ps1'),'-OutDir',$OutDir)
        if (-not $NoAlert) { $msArgs += '-Alert' }
        $msJ = Invoke-Bounded 'match-soundness' $msArgs 900
        $msJ.Output | ForEach-Object { Log ('match-soundness: ' + $_) }
        if ($msJ.ExitCode -eq 2) { $summary += 'REVIEW    commodity matching changed vs baseline (a product MOVED/DROPPED) - see out\audit\soundness-report.json; publish will HOLD until reviewed + audit-match-soundness.ps1 -Accept' }
        elseif ($msJ.ExitCode -eq 3) { $summary += 'REVIEW    audit-match-soundness could not evaluate - commodity matching is UNGUARDED this run'; Log 'match-soundness BLIND: ingested ZERO products - no store feed reached this audit, so its silence is not a clean board'; $summary += 'REVIEW    audit-match-soundness ingested ZERO products - commodity matching is UNGUARDED this run (check out\regular\ and out\ads-*.json)' }
      } catch { Log ('match-soundness guard threw: ' + $_.Exception.Message) }
      # ---- SALE WITHOUT AN AD (wired 2026-08-21, Brad: "Items that we show on 'sale' but no
      # matching 'ad' keep note of"). Every cell published as a sale that matches no row in any ad we
      # hold. Not automatically wrong - a store can cut a shelf price without advertising it - but it
      # is the one class we cannot DATE, so it is the class that cannot expire by itself. The ledger
      # keeps first_seen so "unexplained for three weeks" becomes visible; a count alone would not.
      # Advisory: it reports a question, not a defect, so the board still ships.
      try {
        & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'audit-sale-without-ad.ps1') -Quiet | ForEach-Object { Log ('sale-without-ad: ' + $_) }
      } catch { Log ('sale-without-ad threw: ' + $_.Exception.Message) }
      # ---- HY-VEE STORE BLEND (wired 2026-08-21). Brad moved the board from Omaha #01 to Omaha #02.
      # The code switched in one commit; the DATA cannot, because capture policy refreshes 7 Hy-Vee
      # products a day against 1554 rows. So the everyday file is a two-store mixture for up to a full
      # quarter, and a mixture is invisible to every other guard - each row is real and each price
      # reproduces against the store that supplied it. The two stores disagree on roughly a third of
      # everyday rows and most sale rows, so this prints how far through the switch we actually are
      # instead of leaving it as a thing nobody is tracking. Advisory: the blend is a known, accepted
      # migration state; what must not happen is it becoming an unknown one.
      try {
        & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'audit-hyvee-store-blend.ps1') | ForEach-Object { Log ('hyvee-store-blend: ' + $_) }
      } catch { Log ('hyvee-store-blend threw: ' + $_.Exception.Message) }
      # ---- PRICE CAPTURE REACH (wired 2026-08-21, Brad: "make sure that when we pull pricing, from
      # ANY part of our codebase, its populating the table correctly"). Every OTHER guard here starts
      # from the board and asks whether what is on it is right. This asks the opposite: is anything we
      # already know MISSING from it? A price that never arrives cannot be wrong, cannot be stale and
      # cannot fail parity - it is invisible to a system that only audits its own output. The Recipe
      # Hunter's pricing agent had 99 captured store prices sitting in ingredient-queue.json, 97 of
      # which had reached nothing at all since 2026-08-16.
      try {
        & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'audit-price-capture-reach.ps1') | ForEach-Object { Log ('price-capture-reach: ' + $_) }
      } catch { Log ('price-capture-reach threw: ' + $_.Exception.Message) }
      # ---- GRAPH GATES (graduated 2026-08-21 on Brad's call: "Im confident to graduate this system
      # and well work out the kinks as it's live"). graph\ stops being a bystander and starts CHECKING
      # the finished board - it cannot invent a cell, move a crown or change a number, so the worst it
      # can do is complain. It has earned this once already: on its first run it flagged that Fareway's
      # weekly ad window had expired 2026-08-15 while next_pull said 2026-08-16.
      # ADVISORY, and the reason is concrete rather than cautious: graph reads some of its rules out of
      # THIS estate's source text, and the capture-policy split earlier the same day turned its row_age
      # gate red. It refused to guess, which is right, but it means a reasonable refactor here can turn
      # it red there. While that is true it must not be able to stop a publish. Promotion to blocking
      # is per-gate, after a clean record of real days, and it is Brad's call.
      try {
        (Invoke-Bounded 'graph-gates' @('-ExecutionPolicy','Bypass','-File',(Join-Path $root 'audit-graph-gates.ps1')) 600).Output | ForEach-Object { Log ('graph-gates: ' + $_) }
      } catch { Log ('graph-gates threw: ' + $_.Exception.Message) }
      # ---- MATCHER PARITY (wired 2026-08-21): the auditors' COPIES of Match-Category must still assign
      # product names exactly as the engine does. audit-household-in-food is a HARD gate built on one of
      # those copies, so a divergence means a hard guard is judging cells under the wrong commodity while
      # reporting clean. test-matcher-parity.ps1 was written on 2026-08-21 and shipped with no caller at
      # all; wiring it into test-auditors alone would NOT have fixed that, because test-auditors is a
      # TESTER_FILE and the chain does not run it - naming a guard in a test proves it is tested, not that
      # it runs, which is the audit-unit-basis-outlier lesson this contract exists to enforce. So it runs
      # HERE, against live product names. Sampled (the full sweep is ~28.5k names); a copy that drifts does
      # so for a whole rule, not one unlucky name. Advisory: it reports, the board still ships.
      try {
        & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'test-matcher-parity.ps1') -Sample 400 | ForEach-Object { Log ('matcher-parity: ' + $_) }
        if ($LASTEXITCODE -eq 2) { $summary += 'REVIEW    an auditor copy of Match-Category no longer agrees with the engine - audit-household-in-food is a HARD gate built on one of those copies, so it may be judging cells under the wrong commodity' }
      } catch { Log ('matcher-parity threw: ' + $_.Exception.Message) }
      # ---- CATEGORY-COVERAGE GUARD: a commodity filed into NO category renders in no department/filter (invisible).
      # HARD publish gate + daily alert so adding a new item can never silently skip a filter.
      try {
        $ccArgs = @('-ExecutionPolicy','Bypass','-File',(Join-Path $root 'audit-category-coverage.ps1'),'-OutDir',$OutDir)
        if (-not $NoAlert) { $ccArgs += '-Alert' }
        & powershell @ccArgs | ForEach-Object { Log ('category-coverage: ' + $_) }
        if ($LASTEXITCODE -eq 2) { $summary += 'REVIEW    a commodity is in no category (renders in no filter) - see out\category-coverage-report.json; publish will HOLD until it is filed into a category' }
      } catch { Log ('category-coverage guard threw: ' + $_.Exception.Message) }
      # ---- STORE-REGISTRY GUARD (2026-07-26): a hardcoded store list drifting from stores.json (the
      # publish-store-guide/publish-deals-page Fareway class - a store silently missing from ONE surface).
      # Advisory: alerts + summary, board still ships (drift is a surface bug, not a data bug).
      try {
        $srArgs = @('-ExecutionPolicy','Bypass','-File',(Join-Path $root 'audit-store-registry.ps1'))
        if (-not $NoAlert) { $srArgs += '-Alert' }
        & powershell @srArgs | ForEach-Object { Log ('store-registry: ' + $_) }
        if ($LASTEXITCODE -eq 2) { $summary += 'REVIEW    store-registry drift: a hardcoded store list disagrees with stores.json - fix the script or document the subset in stores.json allowed_subsets' }
                  } catch { Log ('store-registry guard threw: ' + $_.Exception.Message) }
      # Advisory: the same food priced under two ids lets the two prices DISAGREE while every per-file check
      # reads green - bread-crumbs vs breadcrumbs sat 2.9x apart across the weekly and recipe boards until
      # Brad spotted it by eye on 2026-08-15 (two recipes paid $0.218/oz against a live $0.0743/oz). The id
      # namespace spans three files, so only a cross-namespace scan can see it. Review, not a gate: a suspect
      # needs a human merge-or-allowlist ruling, and blocking the publish would not make that happen faster.
      try {
        & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'audit-commodity-dupes.ps1') | ForEach-Object { Log ('commodity-dupes: ' + $_) }
        if ($LASTEXITCODE -eq 2) { $summary += 'REVIEW    commodity-dupes: the same food may be priced under two ids (see out\commodity-dupes.json) - merge the real ones, allowlist the reviewed ones' }
      } catch { Log ('commodity-dupes audit threw: ' + $_.Exception.Message) }
      # ---- ARRIVALS DESK (REVIEW QUEUE, NEVER A GATE). The 47-of-99 bug class - a commodity's include regex
      # matching a product that is NOT the commodity - is invisible to every hard invariant above it: those
      # products carry a real first-party product id, a real price and a working link, so identity, basis,
      # band, freshness and link checks all pass them. Measured 2026-07-30: 85% of cells trace to a first-party
      # id and all four of that morning's wrong products were top-of-ladder verified. NOTHING on the board
      # records "this product belongs to this commodity", so nothing can check it - only a reader can.
      # The delta is small enough to read: 99.3% of cells are byte-identical day to day, ~196 products arrive
      # per cycle and ~44 take a crown, and a wrong product is 4x more likely to hold a crown. This ranks the
      # day's new (commodity, store, product) triples by how far each name diverges from its own cohort,
      # crowns first, and writes out\arrivals-docket.json.
      # ADVISORY BY CONSTRUCTION. Measured precision on the flag tier is 5-15% (2026-07-30: 14 flags, 1 real
      # defect), so it is a queue for an agent, not a gate. The script exits only 0 or 3 and this block turns
      # every outcome into a $summary line. Do NOT promote it to a publish hold on that precision.
      # ---- DISCOVERY, BEFORE THE DESK THAT READS IT (F1(b), 2026-08-01) -------------------------------
      # pull-regular-hyvee is a REFRESH, not a pull: its work list is two closed sets, so 1,538 rows is a
      # fixed point and 89.3% of the Hy-Vee catalogue is absent. discover-hyvee is the only door in, and it
      # writes a DOCKET rather than the feed because Hy-Vee publishes no per-product department and its
      # CATEGORY facet is silently ignored as a filter - so ~14% of what it finds is a wrong product and a
      # human has to rule on every one.
      # AFFORDABLE, measured rather than assumed: 2.14s per term (one search per TERM, not per product), so
      # the 40-term slice below costs ~85s and walks all 526 terms in about 13 days. The plan's earlier
      # caution quoted ~598 ms/PRODUCT, which is the per-product GraphQL cost of the PULLER and does not
      # apply here.
      # ORDER MATTERS: it runs BEFORE build-arrivals-docket, because the desk's PROSPECTS section reads the
      # docket this writes. Reversed, the desk would always show yesterday's findings.
      # Non-fatal and advisory - it can never touch a board.
      try {
        $dhJ = Invoke-Bounded 'discover-hyvee' @('-ExecutionPolicy','Bypass','-File',(Join-Path $root 'discover-hyvee.ps1'),'-Slice','40') 900
        if ($dhJ.ExitCode -eq 3) { Log 'discover-hyvee BLIND (killed at its budget or the job broke) - no NEW Hy-Vee products were looked for today' }
        $dhOut = @($dhJ.Output)
        @($dhOut | Where-Object { $_ -match '^DOCKET:|^  \(|SEARCH FAILED|^BLIND' }) | ForEach-Object { Log ('discover-hyvee: ' + $_) }
      } catch { Log ('discover-hyvee threw: ' + $_.Exception.Message); $summary += 'REVIEW    discover-hyvee threw - no NEW Hy-Vee products were looked for today (the refresh-only puller cannot find any on its own)' }

      try {
        # No 2>&1 on the child: under EAP=Stop a native child's first stderr line becomes a TERMINATING throw,
        # which would swallow the docket into the catch below and log it as "threw" with no docket written.
        $adOut = @(& powershell -ExecutionPolicy Bypass -File (Join-Path $root 'build-arrivals-docket.ps1'))
        $adRc  = $LASTEXITCODE
        @($adOut | Where-Object { $_ -match 'ARRIVALS |FLAGGED at|DEGRADED|^  FLAG#' }) | ForEach-Object { Log ('arrivals: ' + $_) }
        if ($adRc -eq 3) {
          Log 'arrivals-docket BLIND: no usable baseline (missing, or too thin to diff against) - the day''s NEW products were NOT reviewed against history, and its arrival count is the board growing rather than products arriving'
          $summary += 'REVIEW    arrivals-docket could not evaluate the delta (no/thin baseline) - the day''s NEW products are unreviewed'
        } else {
          $adF = Join-Path $OutDir 'arrivals-docket.json'
          if (-not (Test-Path $adF)) {
            $summary += 'REVIEW    arrivals-docket exited 0 but wrote no docket - the day''s NEW products are unreviewed'
          } else {
            # ((Get-Content -Raw) + '') - [string]$null is $null so .Trim() THROWS on a zero-byte file, and
            # '' | ConvertFrom-Json returns $null WITHOUT throwing. Both have produced silent wrong answers here.
            $adJ = ((Get-Content $adF -Raw) + '').Trim() | ConvertFrom-Json
            if ($null -eq $adJ) { $summary += 'REVIEW    out\arrivals-docket.json is empty or unparseable - the day''s NEW products are unreviewed' }
            elseif ([int]$adJ.flagged_count -gt 0 -or [int]$adJ.blind_count -gt 0) {
              $summary += ('REVIEW    arrivals-docket: ' + [int]$adJ.flagged_count + ' of ' + [int]$adJ.arrivals + ' new product(s) diverge from their own cohort, ' + [int]$adJ.blind_count + ' unscorable - read out\arrivals-docket.json, CROWN rows first (review queue, ~1 in 7 is real)')
            }
            # PROSPECTS get their OWN summary line, always, and separately from the arrivals count. They are
            # the opposite question - products NOT on the board that would beat what we hold - and discovery
            # pays nothing at all until a human rules on them, so a silent zero here is the whole failure.
            if ($null -ne $adJ) {
              if ([string]$adJ.prospects_state -ne 'ok' -and [string]$adJ.prospects_state -ne '') {
                $summary += ('REVIEW    arrivals-docket PROSPECTS section is BLIND: ' + [string]$adJ.prospects_state)
              } elseif ([int]$adJ.prospects_open -gt 0) {
                $summary += ('REVIEW    ' + [int]$adJ.prospects_open + ' Hy-Vee discovery prospect(s) await a ruling (' +
                  [int]$adJ.prospects_crown_takers + ' would take a crown) - read the PROSPECTS section of out\arrivals-docket.json and rule each with adjudicate-discovery.ps1. ~1 in 7 is a WRONG PRODUCT and nothing machine-vetted them.')
              }
            }
          }
        }
      } catch { Log ('arrivals-docket threw: ' + $_.Exception.Message) }
      # ---- STORE-TAXONOMY SECOND OPINION (2026-07-30): the ONLY check in the estate that does not inherit the
      # include regex's premise. It compares what OUR rules say a product is against what the STORE'S OWN feed
      # says (Family Fare's canonical_url carries /shop/<department>/... on 3489 products today). 47 of the 99
      # wrong numbers that reached shoppers in 22 days were the include matching a product that is not the
      # commodity, and no name rule, band, or SKU check can see that class - the store's own shelf can.
      # ADVISORY, AND DELIBERATELY NOT A GATE. Measured 2026-07-30: 17 disagreements, 17/17 adjudicated wrong
      # by hand, but ZERO of them were rankable and ZERO were live board cells (same on 07-25 and 07-26). It
      # has 100% precision and no proven catch on a PUBLISHED number, so it earns a review queue, not a hold.
      # -FailOnFlag exists for the day that record changes and is deliberately not passed here.
      # NO EMAIL, DELIBERATELY. The queue is ~17 near-identical items that barely move day to day; a daily
      # alert would be the Family Fare throttle spam all over again (seven identical triage items in one day).
      # The queue lives in the log and in out\taxonomy-disagreements-<date>.json. Only a LIVE CELL - a wrong
      # product actually on the board - earns a line in the summary Brad reads.
      try {
        $txArgs = @('-ExecutionPolicy','Bypass','-File',(Join-Path $root 'audit-store-taxonomy.ps1'),'-OutDir',$OutDir)
        # capture FIRST, then read $LASTEXITCODE, then log - piping the call straight into ForEach-Object
        # loses the child's exit code (the audit-ff-carry lesson, pinned in test-auditors).
        $txOut = & powershell @txArgs
        $txRc = $LASTEXITCODE
        foreach ($l in @($txOut)) { Log ('taxonomy: ' + $l) }
        if ($txRc -eq 3) {
          Log 'store-taxonomy BLIND: judged ZERO rows - no store feed carried a department, so its silence says nothing about the board'
          $summary += 'REVIEW    audit-store-taxonomy judged ZERO rows - the wrong-product second opinion is UNAVAILABLE this run (check Family Fare canonical_url coverage in out\regular\)'
        } else {
          $txM = [regex]::Match(([string[]]@($txOut) -join "`n"), '(\d+) LIVE CELL disagreement')
          if ($txM.Success -and ([int]$txM.Groups[1].Value) -gt 0) {
            $summary += ('REVIEW    ' + $txM.Groups[1].Value + ' live board cell(s) hold a product the STORE ITSELF files in a non-food department - see out\taxonomy-disagreements-*.json')
          }
        }
      } catch { Log ('store-taxonomy guard threw: ' + $_.Exception.Message) }
      # ---- SALE-FALLBACK GUARD: an on-sale cell with NO everyday item to revert to VANISHES when the sale ends.
      # audit-sale-fallback flags them; FF self-heals daily (researched above), browser-store gaps go to
      # research-worklist.json for the weekly agent to research the next-cheapest everyday item. De-duped alert.
      try {
        & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'audit-sale-fallback.ps1') | Out-Null
        $sf = try { Get-Content (Join-Path $OutDir 'sale-fallback-gaps.json') -Raw | ConvertFrom-Json } catch { $null }
        if ($sf -and [int]$sf.gap_count -gt 0) {
          $sfSig = (@($sf.gaps | ForEach-Object { $_.commodity + '|' + $_.store } | Sort-Object) -join ';')
          $sfF = Join-Path $OutDir 'sale-fallback-alert.sig'
          $sfPrev = if (Test-Path $sfF) { ((Get-Content $sfF -Raw) + '').Trim() } else { '' }
          $sfList = (@($sf.gaps | ForEach-Object { $_.commodity + ' @ ' + $_.store }) -join '; ')
          Log ("sale-fallback: $($sf.gap_count) on-sale cell(s) with no everyday fallback - $sfList")
          $summary += "REVIEW    sale-fallback: $($sf.gap_count) on-sale cell(s) would vanish when the sale ends - see sale-fallback-gaps.json"
          if ($sfSig -ne $sfPrev -and (-not $NoAlert)) {
            try { Send-Alert -Subject "Grocery: $($sf.gap_count) on-sale item(s) have no everyday fallback - $asofS" -Body "These commodity+store cells are on SALE with no everyday item to revert to, so the store DROPS OFF that commodity when the sale ends: $sfList. Browser stores are queued in grocery/out/research-worklist.json for the weekly agent to research the next-cheapest everyday item; Family Fare self-heals daily." | Out-Null
                  if ($LASTEXITCODE -eq 0) { Set-Content -Path $sfF -Value $sfSig -Encoding UTF8; Log 'sale-fallback alert sent' } } catch { Log ('sale-fallback alert threw: ' + $_.Exception.Message) }
          } else { Log 'sale-fallback gaps unchanged - not re-alerting' }
        } else { if (Test-Path (Join-Path $OutDir 'sale-fallback-alert.sig')) { Remove-Item (Join-Path $OutDir 'sale-fallback-alert.sig') -ErrorAction SilentlyContinue } }
      } catch { Log ('sale-fallback guard threw: ' + $_.Exception.Message) }
      # Keep the product-URL worklist current: after prices move, flag any "See item" link whose board price
      # changed (stale) or whose linked product no longer matches (mismatch), so the weekly browser agent
      # re-resolves it. Headless-safe (detection only); the actual re-resolution needs Chrome. Non-fatal.
      # ORDER: it reads research-worklist.json, which audit-sale-fallback directly above writes, and it must
      # see TODAY's recipe board - recipe-overlay is on the ship path, so it is already applied by here.
      try { & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'resolve-worklist.ps1') | Out-Null } catch { Log ('resolve-worklist threw: ' + $_.Exception.Message) }
      # COST-FLAG ALERT (2026-07-26 scale hardening): an unpriced ingredient line silently makes a recipe
      # look CHEAPER (the line is dropped from the batch cost). cost-recipes records these to db\cost-flags.txt
      # but nothing read it. Alert on a NEW flag-set (signature de-dup so a persistent flag does not spam).
      try {
        $cfFile = Join-Path (Split-Path $root -Parent) 'meal-prep\db\cost-flags.txt'
        $cf = if (Test-Path $cfFile) { ((Get-Content $cfFile -Raw) + '').Trim() } else { '' }
        if ($cf) {
          $cfLines = @($cf -split "`n" | Where-Object { $_.Trim() })
          Log ("cost-flags: $($cfLines.Count) unpriced recipe line(s) - a recipe is priced too cheap; see db\cost-flags.txt")
          $summary += "REVIEW    cost-flags: $($cfLines.Count) unpriced recipe line(s) - a bid lost its price; recipe reads too cheap (db\cost-flags.txt)"
          $cfSig = [BitConverter]::ToString([Security.Cryptography.MD5]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes(($cfLines | Sort-Object) -join ';'))) -replace '-',''
          $cfSigF = Join-Path $OutDir 'cost-flags-alert.sig'
          $cfPrev = if (Test-Path $cfSigF) { ((Get-Content $cfSigF -Raw) + '').Trim() } else { '' }
          if ($cfSig -ne $cfPrev -and (-not $NoAlert)) {
            try { Send-Alert -Subject "Recipe pricing: $($cfLines.Count) unpriced ingredient line(s)" -Body ("engine\cost-recipes.ps1 could not price some recipe ingredient lines this run - each dropped line makes that recipe's cost read LOWER than reality (usually a bid pointing at a renamed/removed board commodity). Fix the bid in db\ingredients.json or register the commodity. Lines: " + (($cfLines | Select-Object -First 15) -join ' | ')) | Out-Null; if ($LASTEXITCODE -eq 0) { Set-Content $cfSigF -Value $cfSig -Encoding ASCII } } catch {}
          }
        } elseif (Test-Path (Join-Path $OutDir 'cost-flags-alert.sig')) { Remove-Item (Join-Path $OutDir 'cost-flags-alert.sig') -ErrorAction SilentlyContinue }
      } catch { Log ('cost-flag alert threw: ' + $_.Exception.Message) }
      # GOLDEN TEST (2026-08-06): the cost engine's regression suite, run against the file cost-recipes
      # just wrote. It had been unrunnable for eleven days because its baseline was a frozen OUTPUT that
      # every price move invalidated; it now asserts (a) the catalogue against its own specs, which reads
      # no price board and so cannot age, and (b) the engine over frozen INPUTS, byte for byte. Running it
      # here is the point: the eleven-day gap happened because nothing ever invoked it. Non-fatal; alerts.
      try {
        # through the bounded helper: stderr captured by file (no 2>&1 under EAP=Stop - see the rule at the
        # test-guards call), and a budget so a hung test cannot hold the chain
        $gtJ = Invoke-Bounded 'golden-test' @('-ExecutionPolicy','Bypass','-File',(Join-Path (Split-Path $root -Parent) 'meal-prep\engine\golden-test.ps1')) 600
        $gt = $gtJ.Output
        if ($gtJ.ExitCode -ne 0) {
          $gtFail = @($gt | Where-Object { $_ -match '^\s+(FAIL|C\d+)' })
          Log ('golden-test FAILED: ' + (($gtFail | Select-Object -First 3) -join ' | '))
          $summary += "REVIEW    golden-test: the cost engine's regression suite failed - run meal-prep\engine\golden-test.ps1"
          try { Send-Alert -Subject "Cost engine: golden test failed" -Body ("meal-prep\engine\golden-test.ps1 failed after today's recost. A STRUCTURAL failure means db\costed.json disagrees with the specs or the ingredient db (usually a package/grams edit that never got a recost). A FROZEN failure means the engine's output over pinned inputs moved - if that change was intended, accept it with golden-test.ps1 -Rebaseline. Lines: " + (($gtFail | Select-Object -First 15) -join ' | ')) | Out-Null } catch {}
        } else { Log 'golden-test: clean' }
      } catch { Log ('golden-test threw: ' + $_.Exception.Message) }
      # RECIPE-CARD PRICING RULE (2026-08-15). The golden test above pins the cost ENGINE; this pins the
      # rule that decides every price a reader actually sees on a card, which is client JS and so was
      # outside every existing guard. It runs the shipped template (minified, generated from the real file
      # so there is no second copy of the rule to drift) against a frozen mini feed in jsdom, and demands
      # BOTH verdicts: the live template must pass, and the same fixture with the cheapest lane reverted to
      # minimum-per-unit selection must still fail on the butter assertions. A guard that only ever passes
      # has not been shown to discriminate. Non-fatal; alerts.
      try {
        $spJ = Invoke-Bounded 'scaler-pricing' @('-ExecutionPolicy','Bypass','-File',(Join-Path (Split-Path $root -Parent) 'meal-prep\pipeline\run-scaler-pricing-test.ps1'),'-Quiet') 600
        $sp = $spJ.Output
        if ($spJ.ExitCode -ne 0) {
          Log ('scaler-pricing FAILED: ' + (($sp | Select-Object -First 3) -join ' | '))
          $summary += "REVIEW    scaler-pricing: the recipe cards' store-selection rule failed its fixture - run meal-prep\pipeline\run-scaler-pricing-test.ps1"
          try { Send-Alert -Subject "Recipe cards: pricing rule guard failed" -Body ("meal-prep\pipeline\run-scaler-pricing-test.ps1 failed. This guard pins the rule that each ingredient is priced at the store where the PACKAGE YOU HAVE TO BUY costs least, not the store with the lowest per-unit price - the defect that once billed `$10.22 for 20 cents of butter and `$40.00 for a 50 lb sack of rice. A POSITIVE-lane failure means tpl2-scaler-prefix.html no longer satisfies the fixture. A NEGATIVE-lane failure means the fixture has stopped reproducing the founding bug, so it is no longer testing anything. Lines: " + (($sp | Select-Object -First 15) -join ' | ')) | Out-Null } catch {}
        } else { Log 'scaler-pricing: clean' }
      } catch { Log ('scaler-pricing threw: ' + $_.Exception.Message) }
      # drift guard: recipes-db index vs db\recipes specs vs db\ingredients (2026-07-26). Non-fatal; alerts.
      try {
        & powershell -ExecutionPolicy Bypass -File (Join-Path (Split-Path $root -Parent) 'meal-prep\engine\audit-db-agreement.ps1') | Out-Null
        if ($LASTEXITCODE -ne 0) {
          Log 'db-agreement guard found DRIFT (see its output)'
          try { Send-Alert -Subject "Recipe db drift (index vs specs)" -Body "meal-prep\engine\audit-db-agreement.ps1 found drift between recipes-db.json and db\recipes specs (or missing db\ingredients items). Run it for the list; fix the lagging side." | Out-Null } catch {}
        } else { Log 'db-agreement guard: clean' }
      } catch { Log ('db-agreement guard threw: ' + $_.Exception.Message) }
      # self-contradiction guard: a spec that disagrees with ITSELF (2026-08-04). Ratchets per class
      # against out\spec-contradictions-baseline.json, so this only fires when a class gets WORSE.
      # test-auditors already proves the matcher still sees its founding bugs; this runs the real audit
      # over the live catalogue every day, next to the drift guard, so a NEW contradiction is named the
      # day it lands instead of at the next manual pass. Non-fatal; alerts. The class that motivated it
      # is PHANTOM - a step naming an ingredient the list never buys, which is how
      # slow-cooker-dr-pepper-pulled-pork-bowls shipped a Dr Pepper braise with no soda in the cost list.
      try {
        $scJ = Invoke-Bounded 'spec-contradictions' @('-ExecutionPolicy','Bypass','-File',(Join-Path (Split-Path $root -Parent) 'meal-prep\pipeline\audit-spec-contradictions.ps1'),'-Quiet') 600
        $sc = $scJ.Output
        if ($scJ.ExitCode -ne 0) {
          $scWorse = (($sc | Where-Object { $_ -match 'FAIL' }) -join ' ')
          Log ('spec-contradiction guard got WORSE: ' + $scWorse)
          $summary += 'REVIEW    a spec-contradiction class got worse than its baseline - see meal-prep\out\spec-contradictions.json'
          try { Send-Alert -Subject "Recipe spec contradictions got worse" -Body ("meal-prep\pipeline\audit-spec-contradictions.ps1 found MORE of a contradiction class than the recorded baseline. One of the two disagreeing statements is on a live card. Full list in meal-prep\out\spec-contradictions.json. " + $scWorse) | Out-Null } catch {}
        } else { Log 'spec-contradiction guard: no class worse than baseline' }
      } catch { Log ('spec-contradiction guard threw: ' + $_.Exception.Message) }
      # ---- CROSS-STORE INTEGRITY (2026-08-07) ------------------------------------------------------------
      # audit-db-agreement owns the two RECIPE masters. This owns the INGREDIENT stores, which nothing
      # compared until now: every defect in the 29-burrito batch was a seam, not a value. 6 items had macros
      # but no price row and dropped silently out of recipe cost; 1 had a price row but no macros and made
      # the spec builder throw; Rice was 185 g/cup in densities and 200 in the food DB; Turkey Bacon's bid
      # pointed at PORK and mispriced a live recipe for weeks. HARD findings mean a wrong number or a dropped
      # line is already live; WARN means a disagreement worth fixing that is not yet producing one.
      # No 2>&1 (the file's own rule, lines 148 and 190): under EAP=Stop a native child's first stderr line
      # becomes a terminating throw, so the guard would land in catch as one log line - and since the caller
      # greps stdout for '^\s*!' and ignored the exit code, a CRASH was indistinguishable from CLEAN. This
      # guard prints a summary line on every completion, so zero output is itself the failure.
      try {
        $si   = & powershell -ExecutionPolicy Bypass -File (Join-Path (Split-Path $root -Parent) 'meal-prep\pipeline\audit-store-integrity.ps1')
        $siRc = $LASTEXITCODE
        $siHard = @($si | Where-Object { $_ -match '^\s*!' })
        if (@($si).Count -eq 0) {
          Log ("store-integrity DID NOT RUN - exit $siRc with no output; the ingredient stores were not compared this cycle")
          $summary += 'REVIEW    store-integrity produced no output - the cross-store guard did not run (it is silent-clean and silent-crashed the same way otherwise)'
        }
        elseif ($siHard.Count) {
          Log ('store-integrity HARD: ' + (($siHard | Select-Object -First 4) -join ' | '))
          $summary += "REVIEW    store-integrity found $($siHard.Count) HARD finding(s) - an ingredient store disagrees with another and a live number is wrong (run meal-prep\pipeline\audit-store-integrity.ps1 -ShowAll)"
          if (-not $NoAlert) { try { Send-Alert -Subject "Ingredient stores disagree: $($siHard.Count) hard finding(s)" -Body ("meal-prep\pipeline\audit-store-integrity.ps1 found cross-store defects. Each of these means a published number is wrong or a cost line is silently missing.`n`n" + (($siHard | Select-Object -First 15) -join "`n")) | Out-Null } catch {} }
        } else { Log ('store-integrity: no hard findings (' + (@($si | Where-Object { $_ -match '^\s*~' }).Count) + ' warn)') }
      } catch { Log ('audit-store-integrity threw: ' + $_.Exception.Message) }
      # ---- GUARD CONTRACT (2026-08-08) -------------------------------------------------------------------
      # Can each DETECTOR in this chain prove it ran to the END? test-auditors once threw 242 checks early,
      # printed 176 lines of PASS and exited 1 - indistinguishable from an ordinary findings-exit, and the
      # zero-output rule could not see it because it had produced plenty of output. Detectors now end with a
      # NAME-COMPLETE line (lib\guard-contract.ps1); this reports the retrofit backlog and hard-fails when a
      # detector LOSES its marker or a new one joins the chain without one.
      try {
        $gc = & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'audit-guard-contract.ps1')
        $gcBad = @($gc | Where-Object { $_ -match '^\s*!' })
        if ($gcBad.Count) {
          Log ('guard-contract: ' + ($gcBad -join ' | '))
          $summary += "REVIEW    $($gcBad.Count) detector(s) can no longer prove they ran to the end (grocery\audit-guard-contract.ps1)"
        } else { Log ('guard-contract: ' + (@($gc | Where-Object { $_ -match 'chain detector' }) -join '')) }
      } catch { Log ('audit-guard-contract threw: ' + $_.Exception.Message) }
      # ---- CLOUD READINESS (2026-08-08) ------------------------------------------------------------------
      # Static check that no script in this chain can ONLY read a gitignored key file. Key files do not exist
      # on a runner, so such a script is a cloud failure waiting for its first real run - and the cloud
      # backup has never had one (13 straight stand-downs from a PS 5.1 array bug, all reported SUCCESS).
      # meal-prep\engine\publish.ps1 was exactly that until today. Cheap, and it holds the fix in place.
      try {
        $cr = & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'audit-cloud-readiness.ps1')
        if ($LASTEXITCODE -ne 0) {
          $crBad = @($cr | Where-Object { $_ -match '^\s*!' })
          Log ('cloud-readiness: ' + ($crBad -join ' | '))
          $summary += 'REVIEW    a daily-chain script can only read a local key file - it would fail on the cloud runner (grocery\audit-cloud-readiness.ps1)'
        }
      } catch { Log ('audit-cloud-readiness threw: ' + $_.Exception.Message) }
      # ---- DATABASE REBUILD (2026-08-08) -----------------------------------------------------------------
      # db\thriftycrew.db is rebuilt from the JSON stores with PRAGMA foreign_keys=ON. A reference that does
      # not resolve does not "produce a finding" here - it REFUSES the write and names the row, which is the
      # difference between detecting the Turkey Bacon bid class and preventing it. Exit 3 is the estate's
      # could-not-evaluate code (no interpreter) and must not read as clean.
      try {
        $dbJ   = Invoke-Bounded 'db-build' @('-ExecutionPolicy','Bypass','-File',(Join-Path (Split-Path $root -Parent) 'meal-prep\pipeline\db-build.ps1')) 300
        $dbOut = $dbJ.Output; $dbRc = $dbJ.ExitCode
        if ($dbRc -eq 1) {
          $bad = @($dbOut | Where-Object { $_ -match 'CONSTRAINT REFUSED|!' })
          Log ('db-build REFUSED: ' + (($bad | Select-Object -First 3) -join ' | '))
          $summary += 'REVIEW    the recipe/ingredient database REFUSED a write - a reference does not resolve (meal-prep\pipeline\db-build.ps1)'
          if (-not $NoAlert) { try { Send-Alert -Subject 'Database constraint refused a write' -Body ("db\thriftycrew.db could not be rebuilt: a foreign key does not resolve. Some JSON store now points at something that does not exist - the class that pointed Turkey Bacon at PORK and dropped Garlic Powder from a recipe total.`n`n" + (@($dbOut) -join "`n")) | Out-Null } catch {} }
        }
        elseif ($dbRc -eq 3) { Log 'db-build: SKIPPED - no interpreter (proves nothing this cycle)'; $summary += 'REVIEW    db-build could not run (no Python) - cross-store constraints were not enforced this cycle' }
        else { Log ('db-build: ' + (@($dbOut | Where-Object { $_ -match 'OK:' }) -join '')) }
      } catch { Log ('db-build threw: ' + $_.Exception.Message) }
      # ---- SCHEMA CONSTRAINTS (2026-08-08) ---------------------------------------------------------------
      # What a relational engine would refuse to store, checked against the eight JSON stores that must agree
      # about the same nouns. The structural classes (broken bid, orphan macro/density row, duplicate key,
      # a macro line with no cost line) all stand at ZERO, so their baseline is zero and one new one is hard
      # immediately - the same verdict a foreign key would give, without the migration. Value disagreements
      # (two files holding different grams for one unit) ratchet against db\schema-constraint-baseline.json:
      # deciding a gram figure needs the SOURCE, not a sweep, so the known dozen stay visible without paging.
      try {
        $sc   = & powershell -ExecutionPolicy Bypass -File (Join-Path (Split-Path $root -Parent) 'meal-prep\pipeline\audit-schema-constraints.ps1')
        $scRc = $LASTEXITCODE
        $scBad = @($sc | Where-Object { $_ -match '^\s*!' })
        if (@($sc).Count -eq 0) {
          Log ("schema-constraints DID NOT RUN - exit $scRc with no output")
          $summary += 'REVIEW    audit-schema-constraints produced no output - the cross-store integrity check did not run'
        }
        elseif ($scBad.Count) {
          Log ('schema-constraints HARD: ' + (($scBad | Select-Object -First 4) -join ' | '))
          $summary += "REVIEW    $($scBad.Count) NEW cross-store constraint violation(s) - a write landed that a real database would have rejected (meal-prep\pipeline\audit-schema-constraints.ps1 -ShowAll)"
          if (-not $NoAlert) { try { Send-Alert -Subject "A write broke cross-store integrity" -Body ("audit-schema-constraints found violation(s) beyond the recorded baseline. These are references that do not resolve, rows with no partner, or duplicate keys - the classes that mispriced Turkey Bacon against PORK and dropped Garlic Powder's cost line.`n`n" + ($scBad -join "`n")) | Out-Null } catch {} }
        } else { Log 'schema-constraints: no new violations (structural classes at zero)' }
      } catch { Log ('audit-schema-constraints threw: ' + $_.Exception.Message) }
      # ---- UNFINISHED RECIPE BATCHES (2026-08-07) --------------------------------------------------------
      # The 29-burrito batch's stage 8 - the independent post-publish review - was interrupted before it
      # reported and NOTHING NOTICED. 29 pages were live and unverified, and it only surfaced hours later by
      # accident. A batch now carries a ledger stamped after each stage completes, and an open batch that has
      # gone quiet is a finding rather than silence.
      # No 2>&1, and zero output is a failure, for the same reason as store-integrity above.
      try {
        $bl   = & powershell -ExecutionPolicy Bypass -File (Join-Path (Split-Path $root -Parent) 'meal-prep\pipeline\batch-ledger.ps1') -Verify
        $blRc = $LASTEXITCODE
        $blBad = @($bl | Where-Object { $_ -match '^\s*!' })
        if (@($bl).Count -eq 0) {
          Log ("batch-ledger DID NOT RUN - exit $blRc with no output; unfinished batches were not checked this cycle")
          $summary += 'REVIEW    batch-ledger produced no output - the unfinished-batch check did not run'
        }
        elseif ($blBad.Count) {
          Log ('batch-ledger: ' + ($blBad -join ' | '))
          $summary += "REVIEW    $($blBad.Count) recipe batch(es) stalled part-way - a stage never completed (meal-prep\pipeline\batch-ledger.ps1 -Verify)"
          if (-not $NoAlert) { try { Send-Alert -Subject "Recipe batch stalled with stages unfinished" -Body ("A recipe batch was opened, ran part-way, and went quiet. Whatever it published is live WITHOUT the stages below having completed - the post-publish review is the one that has silently failed before.`n`n" + ($blBad -join "`n")) | Out-Null } catch {} }
        } else { Log 'batch-ledger: no stalled batches' }
      } catch { Log ('batch-ledger threw: ' + $_.Exception.Message) }

      # ---- COUNT-UNIT gpu guard (2026-08-08). Existed since 08-06 and NOTHING called it: the shared
      # "Tortilla" row carried gpu 45 with unit 'each' against a 300 g 10ct pack, and "each == each" passes
      # the gpu reconciler unconditionally, so count-priced gpu was never checked by anything that runs.
      try {
        $cg = (& powershell -ExecutionPolicy Bypass -File (Join-Path (Split-Path $root -Parent) 'meal-prep\pipeline\audit-count-gpu.ps1') | ForEach-Object { [string]$_ }) -join "`n"
        $cgRc = $LASTEXITCODE
        if ($cg -notmatch '(?m)^COUNT-GPU-COMPLETE') {
          Log ('count-gpu DID NOT RUN TO THE END (rc=' + $cgRc + ') - no completion marker, so its verdict proves nothing')
          $summary += 'REVIEW    count-gpu did not finish - count-unit gpu rows went unchecked'
        } elseif ($cgRc -eq 0) { Log 'count-gpu: every count-unit row agrees with its package' }
        else {
          Log ('count-gpu rc=' + $cgRc)
          $summary += 'REVIEW    a count-unit ingredient row disagrees with its own package size'
        }
      } catch { Log ('count-gpu threw: ' + $_.Exception.Message) }
      # ---- PER-ROW STALENESS (2026-08-07) ----------------------------------------------------------------
      # guards.ps1 guard 9 tests the AGE OF THE FILE, and every puller rewrites its file daily, so that check
      # passes every run while the rows INSIDE age independently - each store carries forward whatever it could
      # not re-verify. Measured the day this landed: Hy-Vee 414 rows past 14 days (oldest 24d), and Walmart's
      # 11,092 rows plus Sam's 1,808 carried no date AT ALL, so neither store could be age-checked by anything.
      # Those prices are on 542 live recipe pages. No 2>&1 and zero-output-is-failure, same as the guards above.
      try {
        $ra   = & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'audit-row-age.ps1') -OutDir $OutDir
        $raRc = $LASTEXITCODE
        $raBad = @($ra | Where-Object { $_ -match '^\s*!' })
        if (@($ra).Count -eq 0) {
          Log ("row-age DID NOT RUN - exit $raRc with no output; per-row price staleness was not measured this cycle")
          $summary += 'REVIEW    audit-row-age produced no output - per-row price staleness was not measured'
        }
        elseif ($raBad.Count) {
          Log ('row-age: ' + (($raBad | Select-Object -First 4) -join ' | '))
          $summary += "REVIEW    $($raBad.Count) per-row staleness finding(s) - prices are aging faster than a puller refreshes them, or a store stopped dating its rows (grocery\audit-row-age.ps1)"
          if (-not $NoAlert) { try { Send-Alert -Subject "Board prices aging inside a fresh file" -Body ("audit-row-age.ps1 found rows aging past the window, or a store that stopped stamping as_of. The FILE dates look fine either way, which is why guard 9 stays quiet. These prices are what 542 live recipe pages quote.`n`n" + ($raBad -join "`n")) | Out-Null } catch {} }
        } else { Log ('row-age: no findings (' + (@($ra | Where-Object { $_ -match 'rows' }).Count) + ' store(s) profiled)') }
      } catch { Log ('audit-row-age threw: ' + $_.Exception.Message) }
      # price alerts: email label:alert-<id> subscribers when an item hits a tracked low (self-gates via alert-state.json)
      try { $paOut = & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'send-price-alerts.ps1'); Log ('price-alerts: ' + (@($paOut)[-1])) } catch { Log ('send-price-alerts threw: ' + $_.Exception.Message) }

      # ---- THE REVIEW-FLAG UNIT: sanity-check -> basis-reconcile -> pack-basis -> the alert block. ----
      # These move together and in this order. sanity-check writes out\guards-<week>.json and the two basis
      # audits write their own reports; the block below is the SINGLE consumer of all three ($flagParts /
      # $flagKeys and the alerted-flags.json write). Split them and the alert block reads a PREVIOUS day's
      # flags and stamps them as today's. All of it is advisory - none of it has ever gated a publish -
      # so the whole unit sits after the board has shipped.
      & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'sanity-check.ps1') | Out-Null   # exit 1 = flags (expected), not a crash -> guards-<week>.json

      # ---- REVIEW FLAGS: a likely-wrong in-band price (sanity outlier / WoW) or an unpriced tracked BOGO is
      #      advisory (we still publish so the board stays current) but must NOT be silent. Alert Brad ONCE per
      #      distinct flag-set (de-duped via alerted-flags.sig) so a daily re-run doesn't spam. ----
      $flagParts = @()
      # STABLE KEYS, deliberately excluding prices (2026-07-28). See the differential alert block below:
      # a flag's identity is WHICH commodity/store is flagged, not what today's numbers happen to be.
      $flagKeys  = @()
      $gf = Get-ChildItem (Join-Path $OutDir 'guards-*.json') -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
      # @(Get-Content|ConvertFrom-Json) does NOT unroll in PS 5.1: ConvertFrom-Json writes a JSON array to the
      # pipeline as ONE object, so @() wraps it into a 1-element array. Every sanity outlier therefore collapsed
      # into a single flagPart whose fields were arrays - the 2026-07-28 email said "16 price(s) to review" for
      # 54 outliers + 15 multibuys (69), and printed all 54 commodity names mashed into one unreadable line.
      # Worse, the whole set shared one dedupe signature. Assign first, THEN wrap, so each outlier is its own flag.
      if ($gf) { $gj = Get-Content $gf.FullName -Raw | ConvertFrom-Json; foreach ($x in @($gj)) { $flagParts += ('SANITY|' + $x.commodity + '|' + $x.type + '|' + $x.detail); $flagKeys += ('SANITY|' + $x.commodity + '|' + $x.type) } }
      $ff = Get-ChildItem (Join-Path $OutDir 'flagged-*.json') -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
      if ($ff) { $mb = @((Get-Content $ff.FullName -Raw | ConvertFrom-Json).multibuy_unpriced); foreach ($m in $mb) { $flagParts += ('MULTIBUY|' + $m.store + '|' + $m.label); $flagKeys += ('MULTIBUY|' + $m.store + '|' + $m.id) } }
      # ---- BASIS CHECKS (2026-07-28). Bands and freshness cannot see a basis error: the price is real and
      # only the arithmetic is wrong, which is precisely what wins a "cheapest store" verdict. Both audits
      # write their own report; their findings ride the same review-flag channel so they land in the triage
      # queue instead of a log nobody reads. Advisory here by design - a store's own unit price is evidence,
      # not gospel (Walmart's is provably wrong sometimes), so these ask for a decision, they do not block.
      try {
        # SURFACE THE FINDINGS. This was piped to Out-Null, so a genuine basis conflict - the class that moves
        # a price by a FACTOR and therefore lands preferentially on the cheapest-store verdict - was computed
        # and then discarded. It is also the ONLY independent price proof Baker's has (see guards.ps1 invariant
        # 11, retired 2026-07-30 in its favour), so throwing its output away left the board's largest store
        # effectively unwatched. Advisory by design; what changes is that it is now READ.
        $brOut = & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'audit-basis-reconcile.ps1') 2>$null
        $brSummary = @($brOut) | Where-Object { $_ -match 'basis-reconcile:' } | Select-Object -First 1
        if ($brSummary) { Log ([string]$brSummary) }
        $brFindings = @($brOut) | Where-Object { $_ -match 'CONFLICT|disagree' }
        if ($brFindings.Count) {
          Log ('basis-reconcile: ' + $brFindings.Count + ' factor-level conflict(s) between our per-unit and the store''s own')
          $summary += ('REVIEW    basis-reconcile: ' + $brFindings.Count + ' cell(s) disagree with the store''s own unit price by a FACTOR - see out\basis-reconcile-report.json')
        }
        $brF = Join-Path $OutDir 'basis-reconcile.json'
        if (Test-Path $brF) {
          $brJ = Get-Content $brF -Raw | ConvertFrom-Json
          foreach ($b in @($brJ.findings)) { $flagKeys += ('BASIS|' + $b.id + '|' + $b.store); $flagParts += ('BASIS|' + $b.id + '|' + $b.store + '|ours ' + $b.ours + '/' + $b.unit + ' vs the store''s own ' + $b.store_says + ' (x' + $b.factor + ') - ' + $b.item) }
        }
      } catch { Log ('audit-basis-reconcile threw: ' + $_.Exception.Message) }
      try {
        & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'audit-pack-basis.ps1') | Out-Null
        $pbF = Join-Path $OutDir 'pack-basis-audit.json'
        if (Test-Path $pbF) {
          $pbJ = Get-Content $pbF -Raw | ConvertFrom-Json
          foreach ($p in @($pbJ.findings)) { $flagKeys += ('PACKBASIS|' + $p.id + '|' + $p.store); $flagParts += ('PACKBASIS|' + $p.id + '|' + $p.store + '|cheapest only because a ' + $p.count + '-pack count was multiplied into the size (' + $p.published + ' vs ' + $p.as_pack_total + ' as a pack total) - ' + $p.item) }
        }
      } catch { Log ('audit-pack-basis threw: ' + $_.Exception.Message) }
      # ---- DIFFERENTIAL ALERTING (2026-07-28). The old dedupe hashed the WHOLE flag text into one
      # signature, and that text embeds prices - so ordinary price movement changed the hash and re-emailed
      # all 68 flags every single day. About 48 of them are the same benign warehouse-bulk economics
      # recurring forever, which is precisely how a real flag hides. Measured on this data: keying on
      # commodity+type instead, 07-27 had 54 and 07-28 had 53, of which only 5 were NEW.
      # 68 lines a day becomes 5, and nothing is lost - the full set still goes to the report files, each
      # flag is just shown to a human ONCE.
      # Deliberately NOT auto-classifying "benign bulk" by heuristic: that can hide a real bug.
      # "New or returning" is lossless; classification is not.
      $fstateFile = Join-Path $OutDir 'alerted-flags.json'
      $fstate = @{}
      if (Test-Path $fstateFile) {
        try { foreach ($p in ((Get-Content $fstateFile -Raw | ConvertFrom-Json).PSObject.Properties)) { $fstate[[string]$p.Name] = $p.Value } } catch { $fstate = @{} }
      }
      # AN ACK IS HOW A REVIEWED FLAG GOES QUIET - not by being ignored long enough.
      # out\review-ack.json: { "acks": [ { "key": "...", "reason": "...", "expires": "yyyy-MM-dd" } ] }
      # An ack with no expires, or an unparseable one, is treated as EXPIRED: silencing a price flag forever
      # on the strength of a typo is exactly the failure this whole block exists to prevent. The estate already
      # works this way for coverage (coverage-ack.json), which re-arms on expiry.
      # <<REVIEW-ACKLOAD-BEGIN>> test-auditors.ps1 extracts this region too and runs it against frozen state.
      # It used to sit OUTSIDE the extracted region while the fixture kept its own transcribed copy of the
      # loop, so deleting the $ackUntil line below reverted half of DEFECT 2 in production while all ten
      # checks stayed green - measured by the post-batch review. $REARM_DAYS lives in here for the same
      # reason: the harness hard-coded 14, so changing production's window was equally invisible.
      $REARM_DAYS = 14
      $ackOpen = @{}; $ackUntil = @{}; $ackExpired = 0; $ackHit = 0; $reArmed = 0; $ackReArmed = 0
      $ackFile = Join-Path $OutDir 'review-ack.json'
      if (Test-Path $ackFile) {
        try {
          foreach ($a in @((Get-Content $ackFile -Raw | ConvertFrom-Json).acks)) {
            if (-not $a.key) { continue }
            $exp = $null; try { $exp = [datetime]$a.expires } catch { $exp = $null }
            if ($null -ne $exp -and $exp.Date -ge (Get-Date).Date) { $ackOpen[[string]$a.key] = $true }
            else {
              $ackExpired++
              # A DATED ack that has run out is a RE-ARM POINT, not just an absent ack. Undated/unparseable
              # acks get no date and fall through to the 14-day clock: using "now" for them would re-page
              # every single day forever, which is the cry-wolf this block exists to prevent.
              if ($null -ne $exp) { $ackUntil[[string]$a.key] = $exp.Date }
            }
          }
        } catch { Log ('review-ack.json unreadable - treating every flag as unacknowledged: ' + $_.Exception.Message) }
      }
      # <<REVIEW-ACKLOAD-END>>
      if ($flagParts.Count -gt 0) {
        Log ("REVIEW FLAGS: " + $flagParts.Count + " -> " + (($flagParts | Select-Object -First 4) -join ' ; '))
        $newIdx = @()
        # <<REVIEW-DECISION-BEGIN>> test-auditors.ps1 extracts this region and runs it against frozen state.
        for ($fi = 0; $fi -lt $flagParts.Count; $fi++) {
          $k = if ($fi -lt $flagKeys.Count) { [string]$flagKeys[$fi] } else { [string]$flagParts[$fi] }
          $isNew = $true
          if ($ackOpen.ContainsKey($k)) { $isNew = $false; $ackHit++ }      # explicitly acknowledged, not expired
          elseif ($fstate.ContainsKey($k)) {
            # a flag that CLEARED and came back must page again - it is a new event, not the same one
            $gap = $null
            try { $gap = ((Get-Date) - [datetime]$fstate[$k].last_seen).TotalDays } catch { $gap = $null }
            if ($null -eq $gap) { $isNew = $true }          # FAIL OPEN: see the note below
            elseif ($gap -gt 7) { $isNew = $true }          # genuinely cleared and returned
            else {
              # STILL CONTINUOUSLY OPEN. This used to be an unconditional $isNew = $false, which made the
              # 7-day test above unreachable: line ~542 refreshes last_seen for EVERY currently-flagged key on
              # EVERY run, so the gap is always 0 and can never exceed 7. A flag present day after day paged
              # exactly ONCE, ever, and then went quiet forever - no expiry, no escalation, nothing. A genuine
              # parse bug flagged once and never fixed simply disappeared into the "already seen" count.
              # Re-arm off last_alerted (which is NOT refreshed by mere presence) so an open flag pages again.
              # Clock preference: last_alerted, else first_seen. The fallback matters - every one of the 63
              # keys in alerted-flags.json today predates this field, and failing OPEN on a missing
              # last_alerted would have paged all 63 in a single mail on the next run. An alert that dumps
              # 63 items trains the reader to ignore it, which is the same wolf-crying this fix is meant to
              # stop. first_seen is when the key was first recorded and therefore first paged, so it is an
              # honest clock for keys created before the field existed: they re-arm 14 days after they
              # appeared, not all at once tonight.
              # Kept as a DATE, not a day count, because the ack expiry below is a date and the two must be
              # comparable: an ack that ran out yesterday has to out-rank a 14-day clock that has not.
              $lastPage = $null
              try { if ($fstate[$k].last_alerted) { $lastPage = [datetime]$fstate[$k].last_alerted } } catch { $lastPage = $null }
              if ($null -eq $lastPage) { try { $lastPage = [datetime]$fstate[$k].first_seen } catch { $lastPage = $null } }
              if ($null -eq $lastPage) { $isNew = $true }                            # no usable clock -> fail OPEN
              # THE ACK'S OWN EXPIRY IS THE RE-ARM MOMENT. Without this the expiry date is decorative: the
              # flag drops back onto the parallel 14-day clock, which has been ticking the whole time the ack
              # was open, so any ack SHORTER than 14 days is silently rounded up to 14. Measured 2026-07-30 on
              # the live files: the 7 MULTIBUY acks expire 08-06 and the flags stay silent 08-07..08-12,
              # paging only on 08-13 - six days of silence nobody asked for. review-ack.json tells the reader
              # "keep expiries short (weeks, not months): the expiry is the whole point"; this makes that true.
              # Fires ONCE: the page stamps last_alerted past the expiry date, so the next run falls through.
              elseif ($ackUntil.ContainsKey($k) -and $lastPage.Date -le $ackUntil[$k]) { $isNew = $true; $ackReArmed++ }
              elseif (((Get-Date) - $lastPage).TotalDays -ge $REARM_DAYS) { $isNew = $true; $reArmed++ }
              else { $isNew = $false }
            }
          }
          if ($isNew) { $newIdx += $fi }
        }
        # <<REVIEW-DECISION-END>>
        $stillOpen = $flagParts.Count - $newIdx.Count
        $extra = ''
        if ($ackHit)     { $extra += ", $ackHit acknowledged" }
        if ($reArmed)    { $extra += ", $reArmed RE-ARMED after $REARM_DAYS days open" }
        if ($ackReArmed) { $extra += ", $ackReArmed RE-ARMED the day their ack expired" }
        if ($ackExpired) { $extra += ", $ackExpired ack(s) EXPIRED" }
        $summary += ("REVIEW    $($flagParts.Count) price flag(s) on the board ($($newIdx.Count) new, $stillOpen already seen$extra) - see guards-/flagged- json")
        if ($newIdx.Count -gt 0 -and -not $NoAlert) {
          $newLines = @($newIdx | ForEach-Object { $flagParts[$_] })
          $body = "$($newIdx.Count) NEW price flag(s) on $asofS (these still published; verify they are real):`n`n" + ($newLines -join "`n") +
                  "`n`n$stillOpen other flag(s) were already reported and are still open - the full set is in guards-*.json / flagged-*.json in $OutDir ."
          Send-Alert -Subject "Grocery: $($newIdx.Count) NEW price flag(s) - $asofS" -Body $body | Out-Null
          if ($LASTEXITCODE -eq 0) { Log ("review-flag alert sent (" + $newIdx.Count + " new of " + $flagParts.Count + ")") }
          else { Log 'review-flag alert FAILED to send (will retry next run)'; $newIdx = @() }   # do not mark as seen if it never sent
        }
        # <<REVIEW-STAMP-BEGIN>> test-auditors.ps1 extracts this region and runs it against frozen state;
        # it makes no external calls, so it is the behavioural self-test for a block with no entry point.
        # AN ALERT NOBODY RECEIVED MUST NOT CONSUME THE RE-ARM (2026-07-30). Exactly the situation the
        # send-failure line above already handles, and it was missed one case over. The GitHub Actions daily
        # backup runs this script as `check-ad-cycles.ps1 -NoAlert` (.github\workflows\daily.yml line 79) and
        # then `git add -A` commits the result; out\alerted-flags.json is TRACKED (it is not in the
        # /grocery/out/ ignore list) and the commit step rebases -X theirs, so the runner's copy wins and
        # comes back down to this machine. Without this line, every flag that came DUE on a day the cloud
        # backup ran was stamped last_alerted, restarting the 14-day clock, while no mail was ever sent -
        # and the cloud only runs on the days Brad's machine was off, which are the days the mail matters
        # most. That is this block's own founding bug one level up: a clock advanced by something that is
        # not a page. -NoAlert must leave the flag DUE, not mark it delivered.
        if ($NoAlert -and $newIdx.Count -gt 0) { Log ("review-flag alert SUPPRESSED by -NoAlert (" + $newIdx.Count + " due) - left DUE so the next alerting run pages"); $newIdx = @() }
        # mark everything currently flagged as seen (only the ones we actually alerted on get first_seen)
        $nowS = (Get-Date).ToString('s')
        # last_alerted is the clock the re-arm above reads, so it must be stamped ONLY on keys this run
        # actually paged about - never by mere presence, or it would refresh itself daily and reproduce the
        # exact bug being fixed (last_seen does that, which is why it cannot be the re-arm clock).
        $alertedKeys = @{}
        if ($newIdx.Count -gt 0) {
          foreach ($ai in $newIdx) { $alertedKeys[$(if ($ai -lt $flagKeys.Count) { [string]$flagKeys[$ai] } else { [string]$flagParts[$ai] })] = $true }
        }
        for ($fi = 0; $fi -lt $flagParts.Count; $fi++) {
          $k = if ($fi -lt $flagKeys.Count) { [string]$flagKeys[$fi] } else { [string]$flagParts[$fi] }
          if (-not $fstate.ContainsKey($k)) { $fstate[$k] = [pscustomobject]@{ first_seen = $nowS; last_seen = $nowS; last_detail = [string]$flagParts[$fi] } }
          else { $fstate[$k].last_seen = $nowS; $fstate[$k].last_detail = [string]$flagParts[$fi] }
          if ($alertedKeys.ContainsKey($k)) {
            if ($fstate[$k].PSObject.Properties['last_alerted']) { $fstate[$k].last_alerted = $nowS }
            else { $fstate[$k] | Add-Member -NotePropertyName last_alerted -NotePropertyValue $nowS -Force }
          }
        }
        # <<REVIEW-STAMP-END>>
      }
      # prune anything unseen for 30 days so the state file cannot grow forever
      $cutoff = (Get-Date).AddDays(-30)
      foreach ($k in @($fstate.Keys)) { try { if ([datetime]$fstate[$k].last_seen -lt $cutoff) { $fstate.Remove($k) } } catch { $fstate.Remove($k) } }
      try {
        $tmpF = $fstateFile + '.tmp'
        ([pscustomobject]$fstate | ConvertTo-Json -Depth 4) | Set-Content $tmpF -Encoding UTF8
        Move-Item $tmpF $fstateFile -Force
      } catch { Log ('alerted-flags state write failed: ' + $_.Exception.Message) }
      # retire the old blob signature - it only ever caused the daily re-alert this replaced
      $fsigFile = Join-Path $OutDir 'alerted-flags.sig'
      if (Test-Path $fsigFile) { Remove-Item $fsigFile -ErrorAction SilentlyContinue }

      # WARN-ONLY: are the weekly-ad landing pages (the flyer-only pills' link targets, ad-urls.json) still
      # alive? Never blocks - a store site outage must not stop OUR publish - but a dead ad link is the same
      # lie class as a dead product link, so it gets said out loud the day it breaks. Baker's is skipped
      # headless (Akamai walls non-browser fetches; the Wednesday browser agent exercises that URL for real).
      try {
        $adDoc = Get-Content (Join-Path $root 'ad-urls.json') -Raw | ConvertFrom-Json
        $skip = @($adDoc.headless_check_skip)
        foreach ($p in $adDoc.urls.PSObject.Properties) {
          if ($skip -contains [string]$p.Name) { continue }
          try {
            $ar = Invoke-WebRequest -UseBasicParsing -Uri ([string]$p.Value) -TimeoutSec 20 -Headers @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' }
            if ([int]$ar.StatusCode -ne 200) { Log ('WARN ad-url ' + $p.Name + ' returned HTTP ' + $ar.StatusCode + ' - the flyer-only pill links there: ' + $p.Value) }
          } catch { Log ('WARN ad-url ' + $p.Name + ' unreachable (' + $_.Exception.Message + ') - the flyer-only pill links there: ' + $p.Value) }
        }
      } catch { Log ('WARN ad-url check skipped: ' + $_.Exception.Message) }

      # ---- Walmart full-capture aging watch (2026-07-23 incident follow-up). The union in compare-deals
      # absorbs partial Walmart pulls only while a COMPREHENSIVE capture sits in its 14-day window. Daily
      # partials keep every OTHER freshness signal green (guard 9 watches file age; the Wednesday watchdog
      # watches mtimes), so this is the one condition with no early warning - it would surface only as a
      # coverage HOLD on the day the window expires. audit-walmart-fullpull.ps1 owns the logic (one copy);
      # exit 1 = advisory. Emails even under -NoAlert, same precedent as the consistency-drift alert: only a
      # LOCAL browser pull can fix it, and send-alert's per-type daily gate caps it at one email per day.
      # Non-fatal by construction.
      try {
        $wfpOut = & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'audit-walmart-fullpull.ps1') 2>$null
        if ($LASTEXITCODE -eq 1) {
          Log ('walmart-fullpull ADVISORY: ' + [string]$wfpOut)
          try { Send-Alert -Subject "Grocery: Walmart full capture aging - $asofS" -Body ("Early warning, nothing is broken yet: " + [string]$wfpOut + " When the last comprehensive capture leaves the 14-day union window, the coverage guard will HOLD the board (safe, but that day's Walmart refresh is lost). Run the full-worklist Walmart browser pull to reset the clock.") | Out-Null } catch {}
        } elseif ($LASTEXITCODE -eq 3) {
          Log ('walmart-fullpull BLIND: ' + [string]$wfpOut)
          try { Send-Alert -Subject "Grocery: a union store has NO captures in its window - $asofS" -Body ("Not an early warning - the fullpull watch examined ZERO capture files for at least one union store (Walmart/Sam's): " + [string]$wfpOut + " The coverage guard will HOLD that store at the cliff; run the full-worklist browser pull now.") | Out-Null } catch {}
        } else { Log ('walmart-fullpull: ' + [string]$wfpOut) }
      } catch { Log ('walmart-fullpull audit threw: ' + $_.Exception.Message) }

      # ---- Capture-eviction outcome watch (rostered 2026-08-06, triage plan-2026-08-06-2 / queue acb66b).
      # audit-capture-eviction.ps1 is the ONLY check that can see a thin capture evicting a rich one under
      # Select-FreshestCaptureRows - the class that shipped Sam's baby formula at +87% with every existing
      # guard green. Until today nothing RAN it: test-auditors only exercises its -SelfTest, so the live
      # pass was hand-cranked. On 2026-08-06 it was run by hand at 10:22:08 against the 10:21:49 board and
      # would never have re-checked the 11:23:15 rebuild on its own, in an estate where the Walmart bot wall
      # has made partial captures routine. That is a guard that exists but never arms (gates-that-can-never-
      # arm), so it gets rostered here, next to the fullpull watch, on every generation.
      # ADVISORY ONLY and deliberately placed AFTER the publish branch: the engine's own eligibility rule
      # already decides which row wins and guards.ps1 already fails closed, so this is the OUTCOME watch,
      # not a gate. It must never hold a board.
      # Exit 0 = clean or advisory findings (the count is in the summary line), 3 = BLIND (no src_date in
      # candidates, or no board to read) which is NOT a clean result and says so. Output is captured first
      # and 2>$null keeps a child stderr line from killing the cycle under EAP=Stop (the audit-ff-carry /
      # logger-kills-pipeline lesson); the whole block is wrapped so a crash here cannot cost the cycle.
      try {
        $ceOut = & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'audit-capture-eviction.ps1') 2>$null
        $ceRc = $LASTEXITCODE
        $ceLine = [string](@($ceOut) -match '^audit-capture-eviction: ' | Select-Object -First 1)
        if (-not $ceLine) { $ceLine = (@($ceOut) | ForEach-Object { [string]$_ }) -join ' ' }
        if ($ceRc -eq 3) {
          Log ('capture-eviction: BLIND - ' + $ceLine)
          $summary += 'REVIEW    audit-capture-eviction could not evaluate (no src_date in candidates, or no board) - a thin-capture eviction is INVISIBLE this cycle'
        } elseif ($ceRc -ne 0 -or $ceLine -notmatch '^audit-capture-eviction: ') {
          # A CRASH MUST NOT READ AS A CLEAN BOARD. Measured while shipping this hunk: with the child
          # throwing, 2>$null swallows the message and $ceLine comes back empty; with the script missing,
          # powershell -File prints its own banner instead. Both used to land in the else branch below,
          # parse to zero findings and log a blank line, which is indistinguishable from a clean pass -
          # the exact shape of the dead-guard class this whole roster exists to close. Same precedent and
          # same wording as audit-ff-carry's did-not-complete line above. test-auditors catches it on the
          # NEXT cycle too (the stamp stops advancing past the board), but it gets said out loud today.
          Log ('capture-eviction DID NOT COMPLETE (rc=' + $ceRc + '): ' + $ceLine)
          $summary += 'REVIEW    audit-capture-eviction did not complete - the thin-capture eviction check produced no verdict this cycle, so a cell dearer than the engine rule allows would go unseen'
        } else {
          Log ('capture-eviction: ' + $ceLine)
          $ceN = 0
          if ($ceLine -match '(\d+) cell\(s\) dearer') { $ceN = [int]$Matches[1] }
          if ($ceN -gt 0) { $summary += ('REVIEW    audit-capture-eviction: ' + $ceN + " cell(s) dearer than the engine's own eligibility rule allows - a thinner capture may have evicted a richer one; see out\capture-evictions.json") }
        }
      } catch { Log ('capture-eviction audit threw: ' + $_.Exception.Message) }

      # ---- Friday digest: the weekly board email the capture CTAs promise. Only when guards passed (never
      # email prices the gates would not publish), Fridays only, idempotent inside the script. Non-fatal.
      if (-not $guardsBlocked) {
        try { & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'send-friday-digest.ps1') | ForEach-Object { Log ('digest: ' + $_) } } catch { Log ('digest threw: ' + $_.Exception.Message) }
      }

      # ---- ALL-STORES-SHOWN MONITOR: re-assert on the freshly BUILT board that every staple commodity shows a
      # tile for all 7 stores (a price, or a "Doesn't carry / No price yet - See it? Let us know!" card). This is
      # the blueberries drop-off invariant. build-deals-page renders it by construction + publish HARD-GATES on
      # it, so a failure here means a render regression slipped through; we name the exact commodity+store and
      # alert ONCE per distinct violation set (sig de-dup) even under -NoAlert, so a silent store-drop can't recur.
      if (-not $NoPublish) {
        try {
          & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'audit-store-coverage.ps1') | Out-Null
          if ($LASTEXITCODE -eq 2) {
            $sc = try { Get-Content (Join-Path $OutDir 'store-coverage-report.json') -Raw | ConvertFrom-Json } catch { $null }
            $scList = if ($sc) { (@($sc.violations | ForEach-Object { $_.commodity + ' [missing: ' + $_.missing + ']' }) -join '; ') } else { '?' }
            $scSig  = if ($sc) { (@($sc.violations | ForEach-Object { $_.commodity + '|' + $_.missing } | Sort-Object) -join ';') } else { '' }
            $scF = Join-Path $OutDir 'store-coverage-alert.sig'
            $scPrev = if (Test-Path $scF) { ((Get-Content $scF -Raw) + '').Trim() } else { '' }
            Log ("store-coverage FAIL: $($sc.violations.Count) commodity(ies) missing a store tile - $scList")
            $summary += "REVIEW    store-coverage: $($sc.violations.Count) commodity(ies) not showing all 7 stores - see store-coverage-report.json"
            if ($scSig -ne $scPrev -and (-not $NoAlert)) {
              try { Send-Alert -Subject "Grocery: a store dropped off a commodity tile - $asofS" -Body "audit-store-coverage found staple commodities NOT showing all 7 stores (a store tile is missing entirely - not even a 'Doesn't carry' card): $scList. The board is built to render all 7 by construction, so this is a render regression - check MissingCells / storeOrder in build-deals-page.ps1. Details: grocery/out/store-coverage-report.json." | Out-Null
                    if ($LASTEXITCODE -eq 0) { Set-Content -Path $scF -Value $scSig -Encoding UTF8; Log 'store-coverage alert sent' } } catch { Log ('store-coverage alert threw: ' + $_.Exception.Message) }
            } else { Log 'store-coverage violation unchanged since last alert - not re-alerting' }
          } else { Log 'store-coverage OK - every staple commodity shows all 7 stores'; if (Test-Path (Join-Path $OutDir 'store-coverage-alert.sig')) { Remove-Item (Join-Path $OutDir 'store-coverage-alert.sig') -ErrorAction SilentlyContinue } }
        } catch { Log ('store-coverage guard threw: ' + $_.Exception.Message) }
      }

      # ---- ITEM-REQUEST NOTIFICATIONS: when a NEW commodity appears on the board, email any /suggest-an-item/
      # requester who asked for it (one-off via the Worker's Gmail; requesters are NOT members). Driven purely
      # by the notify-known-ids.json state diff, so it is a no-op every day nothing new was added - and it runs
      # regardless of -NoAlert (these are requester-facing, not Brad-alerts). Never fatal to the pipeline.
      try {
        $niOut = (Invoke-Bounded 'notify-item-added' @('-ExecutionPolicy','Bypass','-File',(Join-Path $root 'notify-item-added.ps1')) 300).Output
        foreach ($ln in @($niOut)) { Log ("notify-item-added: " + $ln) }
        $niSent = @($niOut | Where-Object { "$_" -match '^NOTIFIED ' }).Count
        if ($niSent -gt 0) { $summary += ("NOTIFIED  $niSent item-request follower(s) emailed - their suggested item is now on the board") }
      } catch { Log ('notify-item-added threw: ' + $_.Exception.Message) }
    }
  } catch { Log ("downstream FAILED: " + $_.Exception.Message) }
} elseif ($hardFail -and (-not $NoDownstream)) {
  Log 'HARD FAILURE - skipped re-compare/publish; board left at last good (alert already sent)'
  $summary += 'HELD      server pull hard-failed - board left at last good, not republished'
}

# ---- THE BOARD vs ITS OWN LINKS (everyday cells only) ----
# WAS AN ORPHAN. audit-everyday-mismatch.ps1 is the only check that asks "does the number we published agree
# with the product page we linked to?", it works, and until now NOTHING invoked it - not guards.ps1, not this
# file. It could find real defects every day and no one would ever read them. (Found 5 on 2026-07-31.)
# STRICTLY ADVISORY, and that is measured, not assumed: on a 43-finding day only 3 were wrong NUMBERS, and in
# the other 40 the BOARD was right and the LINK was stale. Gating a publish on this would hold correct boards
# hostage to stale links. Exit 1 means "found disagreements", not "failed"; only exit 3 (could-not-evaluate)
# and an unexpected code are worth a REVIEW line of their own.
# Placed here, at the end of the cycle: it reads the newest comparison-*.json and product-urls.json, so it
# must run after compare-deals AND after the link repairs above, and before the coverage ratchet below so its
# row is on the ledger when the ratchet reads it. No 2>&1 (EAP=Stop turns a child's stderr into a throw).
try {
  $emPath = Join-Path $root 'audit-everyday-mismatch.ps1'
  if (Test-Path $emPath) {
    $emOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $emPath -OutDir $OutDir
    $emRc  = $LASTEXITCODE
    foreach ($l in @($emOut)) { Log ('everyday-mismatch: ' + $l) }
    if ($emRc -eq 1) {
      # [regex]::Match, NOT -match + $Matches. $Matches is GLOBAL in PowerShell, so reading it downstream of a
      # -match inside a pipeline both depends on and clobbers state this file uses elsewhere - a trap this
      # repo has already been bitten by. A local Match object carries its own groups and touches nothing.
      $emM = [regex]::Match((@($emOut) -join "`n"), 'EVERYDAY MISMATCHES[^:]*:\s*(\d+)')
      $emN = if ($emM.Success) { $emM.Groups[1].Value } else { 'some' }
      $summary += ('REVIEW    everyday-mismatch: ' + $emN + ' board cell(s) disagree with their own linked product - usually a stale LINK, not a wrong price; see out\everyday-mismatches.json')
    }
    elseif ($emRc -eq 3) {
      $summary += 'REVIEW    everyday-mismatch could not evaluate - the board/link agreement check proved nothing this cycle'
    }
    elseif ($emRc -ne 0) {
      Log ("everyday-mismatch: DID NOT RUN - exit $emRc with " + @($emOut).Count + ' output line(s)')
      $summary += 'REVIEW    everyday-mismatch did not complete - board/link agreement went unchecked this cycle'
    }
  }
} catch { Log ('everyday-mismatch threw: ' + $_.Exception.Message) }

# ---- THE SAME COMMODITY MUST NOT BE PUBLISHED ON BOTH BOARDS ----
# recipe-overlay (line ~699) drops any recipe row whose commodity also lives on the weekly board, and since
# 2026-08-08 it resolves the two id spellings through recipe-floor-id-map.json. This is the independent
# second opinion on that, and it exists because the de-dup was silently half-blind for 9 days: it compared
# raw ids, the namespaces spell 33 shared commodities differently, and the site served two prices for the
# same product (beef chuck roast at Family Fare, $8.49 against $10.99). Re-deriving the collision set from
# the data every run means the next mapping added without teaching the de-dup about it fires HERE instead
# of reaching a shopper.
# ADVISORY IN THE CHAIN, on purpose and against my instinct. The condition is a genuine correctness defect
# and the script exits 2 for it, but this gate is one day old and runs inside the unattended 6:30am job; a
# brand-new check that can halt that run is the failure this estate has already had once. It reports loudly
# now, and can be promoted to a hold once it has a clean history behind it.
# Placed after everyday-mismatch so the comparison is final, and before the coverage ratchet so its row is
# on the ledger when the ratchet reads it. No 2>&1 (EAP=Stop turns a child's first stderr line into a throw).
try {
  $brPath = Join-Path $root 'audit-board-reconciliation.ps1'
  if (Test-Path $brPath) {
    $brOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $brPath -OutDir $OutDir
    $brRc  = $LASTEXITCODE
    foreach ($l in @($brOut)) { Log ('board-reconciliation: ' + $l) }
    if ($brRc -eq 2) {
      # [regex]::Match, NOT -match + $Matches: $Matches is GLOBAL and this file reads it elsewhere.
      $brM = [regex]::Match((@($brOut) -join "`n"), 'PUBLISHED ON BOTH BOARDS:\s*(\d+)')
      $brN = if ($brM.Success) { $brM.Groups[1].Value } else { 'some' }
      $summary += ('REVIEW    board-reconciliation: ' + $brN + ' commodity(ies) are published on BOTH boards - the site is showing two prices for the same product; see out\board-reconciliation.json')
    }
    elseif ($brRc -eq 1) {
      $summary += 'REVIEW    board-reconciliation: the boards are de-duplicated but a price or basis contradiction remains; see out\board-reconciliation.json'
    }
    elseif ($brRc -eq 3) {
      $summary += 'REVIEW    board-reconciliation could not evaluate - nothing proved this cycle about the same fact being published twice'
    }
    elseif ($brRc -ne 0) {
      Log ("board-reconciliation: DID NOT RUN - exit $brRc with " + @($brOut).Count + ' output line(s)')
      $summary += 'REVIEW    board-reconciliation did not complete - duplicate-commodity publishing went unchecked this cycle'
    }
  }
} catch { Log ('board-reconciliation threw: ' + $_.Exception.Message) }

# ---- RESCUE WORKLIST FOR THE WALLED STORES (Walmart, Sam's, Aldi, Fareway) ----
# The four walled stores are captured by hand through a browser, and compare-deals hands each commodity to
# the FRESHEST capture in a 14-day window OUTRIGHT. Two things fall out of that and nothing used to turn
# either into a to-do list: cells silently counting down to the day their only source leaves the window
# (21 Walmart produce cells on 2026-07-31, all of them renamed products newer captures missed by name),
# and a re-capture that is BIGGER overall but narrower on some terms (Aldi's 1,664-row 07-29 pass still
# cost 7 staple cells). audit-walmart-fullpull COUNTS the first; audit-cell-drops reports the second AFTER
# the loss. This turns both, plus the already-past-the-window pocket at Sam's, into per-store search lists.
# ADVISORY AND NOTHING ELSE: exit 1 means "capture work exists", never "hold the board". The output is a
# to-do list for the next browser session.
# Placed after the everyday-mismatch block so the comparison is final, and before the coverage ratchet so
# this tool's coverage row is on the ledger when the ratchet reads it. No 2>&1 / 2>$null on the child (under
# EAP=Stop a native child's first stderr line becomes a terminating throw), capture then read $LASTEXITCODE.
try {
  $rwPath = Join-Path $root 'build-rescue-worklist.ps1'
  if (Test-Path $rwPath) {
    $rwOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $rwPath -OutDir $OutDir
    $rwRc  = $LASTEXITCODE
    foreach ($l in @($rwOut)) { Log ('rescue-worklist: ' + $l) }
    if ($rwRc -eq 1) {
      # [regex]::Match, NOT -match + $Matches: $Matches is GLOBAL and this file reads it elsewhere.
      $rwWork = 0
      foreach ($rwM in [regex]::Matches((@($rwOut) -join "`n"), 'DROPPED (\d+)\s+UNTRACEABLE (\d+)\s+EXPIRING (\d+)\s+STALE (\d+)')) {
        for ($rwG = 1; $rwG -le 4; $rwG++) { $rwWork += [int]$rwM.Groups[$rwG].Value }
      }
      $rwN = if ($rwWork -gt 0) { [string]$rwWork } else { 'some' }
      $summary += ('REVIEW    rescue-worklist: capture work exists for the walled stores (' + $rwN + ' cell(s)) - see out\rescue-terms-*.txt (DROPPED/EXPIRING cells will leave the board if not captured)')
    }
    elseif ($rwRc -eq 3) {
      $summary += 'REVIEW    rescue-worklist could not evaluate - the walled-store freshness check proved nothing this cycle, so no browser worklist can be trusted'
    }
    elseif ($rwRc -ne 0) {
      Log ("rescue-worklist: DID NOT RUN - exit $rwRc with " + @($rwOut).Count + ' output line(s)')
      $summary += 'REVIEW    rescue-worklist did not complete - walled-store capture priorities went uncomputed this cycle'
    }
  }
} catch { Log ('rescue-worklist threw: ' + $_.Exception.Message) }

# ---- RETENTION, AFTER EVERY READER OF "THE NEWEST comparison-*" HAS RUN ----------------------------
# Moved here 2026-08-22 with the ship/inspect split. prune-out and prune-intermediates DELETE dated files;
# arrivals-docket, capture-eviction, board-reconciliation and everyday-mismatch each resolve "the newest
# comparison-*" (and their own dated inputs), so retention now runs after all four - and still BEFORE
# test-auditors, because a deletion that blinds a watcher has to say so the same day it happened.
# Gated on $script:DownstreamRan so the condition is unchanged from when it lived inside the downstream
# block: it prunes only on a day the downstream actually ran, never after a hard-failed pull.
if ($script:DownstreamRan) {
  # ---- RETENTION (2026-08-08): cap out\'s dated-family growth. Conservative per-family windows set past
  # the deepest historical reader (see prune-out.ps1's header); evidence dirs are never listed. Non-fatal.
  try {
    $pr = & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'prune-out.ps1') -Apply
    foreach ($l in (@($pr) | Select-Object -Last 1)) { Log ('prune-out: ' + $l) }
  } catch { Log ('prune-out threw: ' + $_.Exception.Message) }
  # THE OTHER HALF OF RETENTION (wired 2026-08-21). prune-out caps the dated FAMILIES in out\;
  # prune-intermediates caps the gitignored per-run scratch (candidates-<date>.json and siblings),
  # which no reader ever opens except the newest. It was written on 2026-08-21 against 408 MB growing
  # ~19 MB/day and shipped with NO production caller, so the growth it was written to stop carried
  # right on - the script census caught it as an orphan. Keep 3, matching its own default. Non-fatal.
  try {
    $pi = & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'prune-intermediates.ps1') -Keep 3
    foreach ($l in (@($pi) | Select-Object -Last 1)) { Log ('prune-intermediates: ' + $l) }
  } catch { Log ('prune-intermediates threw: ' + $_.Exception.Message) }
}

# ---- WATCH THE WATCHERS - ALWAYS, outside the downstream branch (hoisted 2026-07-28) ----
# A guard that reports nothing looks exactly like a guard that is broken, and on 2026-07-28 three of them
# were broken at once while "passing" for days. test-auditors.ps1 replays each watcher's founding bug
# against a frozen fixture and asserts it still fires (and stays silent on the clean twin).
# This deliberately sits OUTSIDE `if ($serverDue -and ... -and (-not $hardFail))`. It used to live inside,
# which meant it was skipped on exactly the days a guard hard-failed - the days you most need to know
# whether the guards themselves can still be trusted. It depends on nothing but its own fixtures, so there
# is no reason for it ever to be conditional. A blind watcher has to be LOUDER than the thing it watches:
# if this fails, every quiet guard above it becomes unproven, including a clean board.
try {
  # ONE RUN, OUTPUT KEPT (2026-08-22). This used to run the suite once to get the exit code and then, on a
  # failure, run it AGAIN to get the text - and it failed on 10 of the previous 14 days, so the ~3-minute
  # suite cost ~7.5 minutes per chain, the single largest item in the stage profile. Capture once.
  $taJ = Invoke-Bounded 'test-auditors' @('-ExecutionPolicy','Bypass','-File',(Join-Path $root 'test-auditors.ps1')) 1200
  $ta = ($taJ.Output -join "`n")
  if ($taJ.ExitCode -ne 0) {
    Log 'WATCHERS FAILED: test-auditors could not prove a guard still sees its own bug'
    $summary += 'WATCHERS  a guard can no longer see its own founding bug - see test-auditors output'
    # PERSIST THE WHOLE THING BEFORE ALERTING (2026-07-31). send-alert used to truncate its body, and on
    # 2026-07-31T06:20 that truncation ate the only copy of WHICH case failed: the email carried the first
    # ~28 PASS lines and stopped, the log line says only "a guard has gone blind", and by the time anyone
    # read it the mid-edit working tree that produced the failure had been committed over. The failing case
    # was unrecoverable - a page about a blind guard that cannot say which guard. The file is written first
    # so it survives even if the send throws, and it is dated so consecutive failures do not overwrite each
    # other's evidence.
    #
    # THE FILE IS ALSO THE EMAIL BODY NOW (2026-08-06). This output is the one alert body in the estate with
    # no bound on it - 43 KB on each of 2026-08-03/04/05 - and passing it as a command-line -Body meant the
    # send never launched on any of those days (see Send-Alert above). It already has to be written here, so
    # hand send-alert THAT PATH: nothing on this path can be too long, and the mail carries the whole run
    # instead of the first 28 PASS lines. The explanatory header goes into the file rather than only into
    # the email, which also makes the artefact self-describing for whoever finds it days later.
    $taF = Join-Path $OutDir ('test-auditors-fail-' + (Get-Date -Format 'yyyy-MM-dd') + '.txt')
    $taBody = "test-auditors.ps1 replays each watcher's founding bug against a frozen fixture. At least one watcher no longer fires on it, which means any quiet report from that guard is unproven - including a clean board.`n`n" +
              "Saved copy of this run: " + $taF + "`n" +
              "FULL test-auditors OUTPUT FOLLOWS - look for the BAD lines.`n" + ('-' * 78) + "`n" + $ta
    $taSaved = $false
    try { Set-Content -Path $taF -Value $taBody -Encoding UTF8; $taSaved = $true; Log ('WATCHERS: full test-auditors output saved to ' + $taF) }
    catch { Log ('WATCHERS: could not save test-auditors output: ' + $_.Exception.Message) }
    if (-not $NoAlert) {
      # normal path: the evidence file IS the body. If it could not be written, Send-Alert spools the same
      # text to %TEMP% instead - a failed evidence write must not also cost us the page.
      if ($taSaved) { Send-Alert -Subject 'Grocery: a GUARD has gone blind (test-auditors failed)' -BodyFile $taF -What 'WATCHERS' | Out-Null }
      else          { Send-Alert -Subject 'Grocery: a GUARD has gone blind (test-auditors failed)' -Body $taBody -What 'WATCHERS' | Out-Null }
    }
  } else { Log 'watchers ok: every guard still fires on its own founding bug' }
} catch { Log ('test-auditors threw: ' + $_.Exception.Message) }

# ---- WEEKLY: prove each BLOCKING invariant can still FAIL (test-guards, hermetically) ----
# test-auditors above proves the watchers fire on frozen fixtures; test-guards proves guards.ps1 itself
# still exits 2 when an invariant is broken on purpose. It mutates live data to do it (16 windows, 9
# git-tracked files; measured 2026-07-30: a hard kill runs neither finally nor PowerShell.Exiting, and a
# foreign commit landed DURING the measured run), so it must never run against production. The runner
# copies the whole tree to %TEMP% (1.1s for 658 MB; every script roots at $PSScriptRoot) and runs there.
# Stamp-gated on >=7 days, not a weekday, so a missed week self-heals on the next daily run.
try {
  $tgStampF = Join-Path $root 'test-guards-weekly-stamp.txt'
  $tgLast = [datetime]'2000-01-01'
  if (Test-Path $tgStampF) { try { $tgLast = [datetime](Get-Content $tgStampF -TotalCount 1) } catch {} }
  if (((Get-Date) - $tgLast).TotalDays -ge 7) {
    # NO 2>&1: this script runs under EAP=Stop, and in PS 5.1 redirecting a native child's stderr wraps the
    # first line in an ErrorRecord that THROWS - jumping past $tgRc, past the stamp, past the alert, into the
    # catch. The crash case (the runner or its grandchildren dying with a stderr record) is EXACTLY the case
    # this alert exists for, and the throw also re-opened the >=7-day gate so the 658 MB copy re-ran daily.
    # The same batch commit measured and removed this exact trap inside test-guards.ps1, then reintroduced it
    # here - caught by the post-batch review. Everything the alert body needs is stdout.
    $tg = (& powershell -ExecutionPolicy Bypass -File (Join-Path $root 'run-test-guards-weekly.ps1') | ForEach-Object { [string]$_ }) -join "`n"
    $tgRc = $LASTEXITCODE
    (Get-Date -Format 'yyyy-MM-dd') | Set-Content $tgStampF -Encoding ascii   # stamp even on failure: one alert per week, not one per day
    if ($tgRc -eq 0) { Log 'test-guards weekly: every hard invariant can still fail (hermetic run passed)' }
    else {
      Log ('test-guards weekly rc=' + $tgRc)
      $summary += 'INVARIANTS a blocking guard may no longer be able to fire - see test-guards weekly alert'
      if (-not $NoAlert) {
        $tgSubject = if ($tgRc -eq 3) { 'Grocery: test-guards could not evaluate (guards already red on the unmutated board)' } elseif ($tgRc -eq 4) { 'Grocery: test-guards weekly did not run (hermetic copy failed)' } else { 'Grocery: a BLOCKING invariant can no longer fail (test-guards weekly)' }
        Send-Alert -Subject $tgSubject -Body ("run-test-guards-weekly.ps1 breaks each hard invariant inside a scratch COPY of the grocery tree and asserts guards.ps1 exits 2 with that guard's own failure text. Exit " + $tgRc + ": 1 = a broken invariant did NOT fail guards (that guard is decorative until fixed - do not trust a quiet board on it); 3 = baseline already red, nothing proven (the daily run is already alerting on the real failure); 4 = the hermetic copy failed. Production files are never touched by this job.`n`n" + $tg) | Out-Null
      }
    }
  }
} catch { Log ('test-guards weekly threw: ' + $_.Exception.Message) }

# ---- WEEKLY: does each live tool page still match the local source it was published from? ----
# The 16 tool posts are a single lexical html card whose body is a local *-tool.html. publish-tool-post.ps1
# now refuses to overwrite a live body that differs from local, which covers the dangerous path - but only
# the path that goes THROUGH the publisher. A hand-edit in Ghost admin never touches it, so that edit would
# sit unnoticed until someone republished and silently deleted it. This is the sweep for that second path.
# WEEKLY, not daily: it is 16 admin-API round trips, and a tool page changes on the scale of someone editing
# it, not a day. Stamp-gated on >=7 days like test-guards above, so a missed week self-heals on the next
# daily run. ADVISORY - drift on a tool page is never a reason to hold the grocery board.
# NO 2>&1, for the reason spelled out at the test-guards call above.
try {
  $gdStampF = Join-Path $root 'ghost-drift-weekly-stamp.txt'
  $gdLast = [datetime]'2000-01-01'
  if (Test-Path $gdStampF) { try { $gdLast = [datetime](Get-Content $gdStampF -TotalCount 1) } catch {} }
  if (((Get-Date) - $gdLast).TotalDays -ge 7) {
    $gd = (& powershell -ExecutionPolicy Bypass -File (Join-Path $root 'audit-ghost-drift.ps1') -ShowDiff | ForEach-Object { [string]$_ }) -join "`n"
    $gdRc = $LASTEXITCODE
    # ...and the 542 recipe cards, against the publish ledger rather than a local file (a rebuilt card carries
    # today's prices, so build-vs-live is not the question; ledger-vs-live is). Same weekly cadence, same
    # advisory posture. Appended to the same body so one alert covers both surfaces.
    $gdR = (& powershell -ExecutionPolicy Bypass -File (Join-Path $root 'audit-ghost-drift.ps1') -Recipes | ForEach-Object { [string]$_ }) -join "`n"
    $gdRRc = $LASTEXITCODE
    if ($gdRRc -ne 0) { $gdRc = $gdRRc }
    $gd = $gd + "`n`n" + $gdR
    (Get-Date -Format 'yyyy-MM-dd') | Set-Content $gdStampF -Encoding ascii   # stamp even on failure: one alert per week
    # THE COMPLETION CONTRACT, PER SURFACE. Both halves must prove they finished, checked SEPARATELY: the two
    # outputs are concatenated for the alert body, and a single search over the joined text would accept one
    # marker as covering both - so a dead tools sweep would be alibied by a healthy recipes sweep. That is the
    # exact "found nothing and never ran look identical" hole this contract exists to close, reintroduced by
    # the convenience of one string.
    $gdToolsDone   = ($gd  -match '(?m)^GHOST-DRIFT-COMPLETE')
    $gdRecipesDone = ($gdR -match '(?m)^GHOST-DRIFT-COMPLETE')
    if (-not ($gdToolsDone -and $gdRecipesDone)) {
      $which = if (-not $gdToolsDone -and -not $gdRecipesDone) { 'neither sweep' } elseif (-not $gdToolsDone) { 'the TOOLS sweep' } else { 'the RECIPE-CARD sweep' }
      Log ('ghost-drift weekly DID NOT RUN TO THE END (rc=' + $gdRc + ') - no completion marker from ' + $which + ', so its verdict proves nothing')
      $summary += ('REVIEW    ghost-drift weekly did not finish (' + $which + ') - those live pages went unchecked this week')
    } elseif ($gdRc -eq 0) { Log 'ghost-drift weekly: every live tool page and recipe card still matches what we published' }
    else {
      Log ('ghost-drift weekly rc=' + $gdRc)
      $summary += 'REVIEW    a live tool page no longer matches its local source - republishing it would delete the difference'
      if (-not $NoAlert) {
        $gdSubject = if ($gdRc -eq 3) { 'Tools: ghost-drift could not evaluate (no key, or a page could not be read)' } else { 'Tools: a live page has drifted from its local source' }
        Send-Alert -Subject $gdSubject -Body ("audit-ghost-drift.ps1 compares each live Ghost html card against the local *-tool.html it was published from. Exit " + $gdRc + ": 1 = at least one page differs, so republishing it from local would DELETE the live-only content (fold the change into the local source, or record it with -Accept <slug> and a reason); 3 = could not evaluate, nothing was proven. publish-tool-post.ps1 already refuses to overwrite an unreviewed difference, so this is the sweep for edits made directly in Ghost admin.`n`n" + $gd) | Out-Null
      }
    }
  }
} catch { Log ('ghost-drift weekly threw: ' + $_.Exception.Message) }

# ---- WEEKLY: are the agent prompts and scheduled-task SKILLs still backed up and current? ----
# ops\audit-prompt-backup.ps1 existed since 2026-07-31 and NOTHING called it. The prompts the triage agents
# run on are code, they live outside this repo in ~\.claude\, and the only thing proving they are backed up
# was a script nobody invoked. Weekly, because prompts change on the scale of someone editing one.
try {
  $pbStampF = Join-Path $root 'prompt-backup-weekly-stamp.txt'
  $pbLast = [datetime]'2000-01-01'
  if (Test-Path $pbStampF) { try { $pbLast = [datetime](Get-Content $pbStampF -TotalCount 1) } catch {} }
  if (((Get-Date) - $pbLast).TotalDays -ge 7) {
    $pb = (& powershell -ExecutionPolicy Bypass -File (Join-Path (Split-Path $root -Parent) 'ops\audit-prompt-backup.ps1') | ForEach-Object { [string]$_ }) -join "`n"
    $pbRc = $LASTEXITCODE
    (Get-Date -Format 'yyyy-MM-dd') | Set-Content $pbStampF -Encoding ascii
    if ($pb -notmatch '(?m)^PROMPT-BACKUP-COMPLETE') {
      Log ('prompt-backup weekly DID NOT RUN TO THE END (rc=' + $pbRc + ') - no completion marker')
      $summary += 'REVIEW    prompt-backup weekly did not finish - agent prompt backups went unverified'
    } elseif ($pbRc -eq 0) { Log 'prompt-backup weekly: every live agent prompt and scheduled-task SKILL is backed up and current' }
    else {
      Log ('prompt-backup weekly rc=' + $pbRc)
      $summary += 'REVIEW    an agent prompt or scheduled-task SKILL is not backed up (or the backup is stale)'
      if (-not $NoAlert) { Send-Alert -Subject 'Ops: an agent prompt is not backed up' -Body ("ops\audit-prompt-backup.ps1 proves the agent prompts and scheduled-task SKILLs - which are CODE and live outside this repo - are backed up to ops\prompt-backup and identical across scopes. Exit " + $pbRc + ": 2 = drift or missing, 3 = BLIND (found nothing to check, which is a pass that proves nothing).`n`n" + $pb) | Out-Null }
    }
  }
} catch { Log ('prompt-backup weekly threw: ' + $_.Exception.Message) }

# ---- WEEKLY: does the live Cloudflare estate still match what this repo declares? ----
# ops\audit-cloudflare-estate.ps1 landed 2026-08-20 and NOTHING in production called it - the same shape
# audit-prompt-backup.ps1 sat in above, and the same shape that let nine unseen R2 lifecycle rules bill
# ~$9/mo for months. ops\run-gates.ps1 DISCOVERS it, but only ever runs its -SelfTest: that proves the
# comparison logic works and checks nothing live. Weekly, because lifecycle rules change when a human
# changes them, not on a schedule.
#
# THIS NEVER BLOCKS THE PUBLISH. It is Cloudflare ops, not a board invariant - a drifted lifecycle rule is
# expensive, not wrong, and holding the board hostage to it would be the wrong trade.
try {
  $cfStampF = Join-Path $root 'cloudflare-estate-weekly-stamp.txt'
  $cfLast = [datetime]'2000-01-01'
  if (Test-Path $cfStampF) { try { $cfLast = [datetime](Get-Content $cfStampF -TotalCount 1) } catch {} }
  if (((Get-Date) - $cfLast).TotalDays -ge 7) {
    $cf = (& powershell -ExecutionPolicy Bypass -File (Join-Path (Split-Path $root -Parent) 'ops\audit-cloudflare-estate.ps1') | ForEach-Object { [string]$_ }) -join "`n"
    $cfRc = $LASTEXITCODE
    (Get-Date -Format 'yyyy-MM-dd') | Set-Content $cfStampF -Encoding ascii
    if ($cfRc -eq 3) {
      # BLIND IS NOT A PASS, and as of 2026-08-20 it is the EXPECTED state: no CLOUDFLARE_API_TOKEN exists
      # on this machine, so the drift this gate was written to catch is currently invisible. Saying so every
      # week is the point - a gate that cannot see must never read as a gate that saw nothing wrong.
      Log 'cloudflare-estate weekly: BLIND - no CLOUDFLARE_API_TOKEN, so R2 lifecycle drift would not be seen'
      $summary += 'REVIEW    cloudflare estate check is BLIND (no CLOUDFLARE_API_TOKEN) - lifecycle drift unwatched'
    } elseif ($cf -notmatch '(?m)^CLOUDFLARE-ESTATE-COMPLETE') {
      Log ('cloudflare-estate weekly DID NOT RUN TO THE END (rc=' + $cfRc + ') - no completion marker')
      $summary += 'REVIEW    cloudflare estate check did not finish - the estate went unverified'
    } elseif ($cfRc -eq 0) {
      Log 'cloudflare-estate weekly: live Cloudflare estate matches ops\cloudflare-estate.json'
    } else {
      Log ('cloudflare-estate weekly rc=' + $cfRc)
      $summary += 'REVIEW    the live Cloudflare estate drifted from ops\cloudflare-estate.json'
      if (-not $NoAlert) { Send-Alert -Subject 'Ops: the Cloudflare estate drifted from its declaration' -Body ("ops\audit-cloudflare-estate.ps1 compares the live R2 buckets, their lifecycle rules and the D1 size against ops\cloudflare-estate.json. Exit " + $cfRc + ": 2 = drift, 3 = BLIND (no token, which proves nothing).`n`nIA transitions are the expensive class: R2 bills operations per whole million with no proration and no IA free tier, which is how 499 transitions bought a full 9.00 dollar block on 2026-08-19.`n`n" + $cf) | Out-Null }
    }
  }
} catch { Log ('cloudflare-estate weekly threw: ' + $_.Exception.Message) }

# ---- WEEKLY: do the store SEARCH templates still resolve? ----
# The all-3 rule guarantees every priced chip carries a link; nothing guaranteed the link WORKED. Family
# Fare's search template 404'd on 20 live chips in public/board.json (2026-08-02) and no guard could see it,
# because every link check in this estate looks at PRODUCT urls. This fetches each store's search template.
# WEEKLY, not daily: it is seven outbound requests to stores we otherwise only read data from, and a
# template rots on the scale of a site redesign, not a day. Stamp-gated on >=7 days like test-guards, so a
# missed week self-heals on the next daily run rather than waiting for a weekday to come round again.
# ADVISORY: it alerts and adds a REVIEW line, it never holds the board. A dead fallback link is a real
# defect, but every PRICE on that board is still correct, and holding a correct board over a link is the
# wrong trade. Exit 3 (every store bot-walled) gets its own line - a blocked probe proved nothing, and
# silence from it must never be read as seven healthy templates.
try {
  $slStampF = Join-Path $root 'search-links-weekly-stamp.txt'
  $slLast = [datetime]'2000-01-01'
  if (Test-Path $slStampF) { try { $slLast = [datetime](Get-Content $slStampF -TotalCount 1) } catch {} }
  if (((Get-Date) - $slLast).TotalDays -ge 7) {
    # No 2>&1 on the child: under EAP=Stop a native child's first stderr line becomes a terminating throw
    # that would jump past the exit-code read and the stamp (the same trap measured in test-guards above).
    $slArgs = @('-ExecutionPolicy','Bypass','-File',(Join-Path $root 'audit-search-links.ps1'),'-OutDir',$OutDir)
    if (-not $NoAlert) { $slArgs += '-Alert' }
    & powershell @slArgs | ForEach-Object { Log ('search-links: ' + $_) }
    $slRc = $LASTEXITCODE
    (Get-Date -Format 'yyyy-MM-dd') | Set-Content $slStampF -Encoding ascii   # stamp even on failure: one alert per week
    if ($slRc -eq 2) { $summary += 'REVIEW    a store SEARCH link is DEAD - every chip falling back to it sends a shopper to a 404; see out\search-links-report.json' }
    elseif ($slRc -eq 3) { Log 'search-links BLIND: every store was bot-walled or unreachable - NO template was checked, so this week proved nothing about the fallback links'; $summary += 'REVIEW    audit-search-links could not evaluate (every store blocked) - the fallback search links are UNCHECKED this week' }
  }
} catch { Log ('search-links weekly threw: ' + $_.Exception.Message) }


# ---- COVERAGE RATCHET FOR THE CYCLE PHASE ----
# THE HOOK THAT WAS NEVER BUILT. coverage-baseline.json's own audit-ff-carry entry has carried the note
# "nothing yet runs the ratchet with -Phase cycle, so those two verdicts fire only on a manual run until
# check-ad-cycles.ps1 gets its own hook" since the ledger shipped. guards.ps1 runs the ratchet with
# -Phase publish, so every cycle-phase row was being WRITTEN faithfully and never COMPARED to anything -
# a gate that cannot arm, which is the exact class the ledger itself exists to catch. This is that hook.
# It sits at the very end, after every cycle-phase producer has recorded (the Hy-Vee pull near the top,
# ff-carry, everyday-mismatch), and it is ADVISORY: a coverage regression means a check got quieter, which
# is worth an eye, not a reason to hold a board whose own guards passed.
# No 2>&1 (EAP=Stop turns a native child's first stderr line into a terminating throw), capture then read
# $LASTEXITCODE, and treat exit 3 as could-not-evaluate rather than as a pass.
try {
  $clPath = Join-Path $root 'audit-coverage-ledger.ps1'
  if (Test-Path $clPath) {
    $clOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $clPath -Phase cycle
    $clRc  = $LASTEXITCODE
    foreach ($l in @($clOut)) { Log ('coverage-cycle: ' + $l) }
    if ($clRc -eq 1) {
      $summary += 'REVIEW    a cycle-phase check examined materially fewer rows than its baseline - see coverage-cycle lines in the log'
    } elseif ($clRc -eq 3) {
      $summary += 'REVIEW    cycle-phase coverage could not be evaluated - no rostered cycle check recorded a row this run'
    }
  }
} catch { Log ('coverage-cycle ratchet threw: ' + $_.Exception.Message) }

# ---- report ----
# The header reports what the run DID, read off $pullRan / $hardFail (both set at the pull site near the top),
# not off $serverDue - which says only that a store was due. Order matters: a pull that ran and came back with
# no current ad data is a FAILED pull, not a pull that "ran", so $hardFail is worded before $pullRan.
$pullNote =
  if     (-not $serverDue) { '   (nothing due)' }
  elseif ($NoPull)         { '   (no pull - -NoPull; latest ads file reused)' }
  elseif ($hardFail)       { '   (server pull FAILED - no current ad data)' }
  elseif ($pullRan)        { '   (server pull ran)' }
  else                     { '   (server pull did not run)' }
Write-Output ("Ad-cycle check  -  " + $asofS + $pullNote)
Write-Output ('-'*74)
foreach ($line in $summary) { Write-Output $line }
if (@($flips).Count -gt 0) { Write-Output ""; Write-Output ("Flipped this run: " + ($flips -join ', ') + "  -> comparison + price history refreshed") }
# TOTAL vs SHIP, both on one line, so the split's value is readable from the log alone on any day - no
# stopwatch, no cross-referencing two timestamps. shipSecs is 0 on a run that never reached the boundary
# (hard-failed pull, -NoDownstream), and saying "ship not reached" is the honest wording for that.
$totalSecs = [int]((Get-Date) - $script:ShipStart).TotalSeconds
$shipNote = if ($script:DownstreamRan) { "ship=" + $shipSecs + "s" } else { "ship=not reached" }
Log ("run complete; flips=" + (@($flips).Count) + "; pull=" + $pullNote.Trim() + "; " + $shipNote + "; total=" + $totalSecs + "s")

