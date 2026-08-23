<#
  capture-run.ps1 - run the capture policy across ALL SEVEN STORES CONCURRENTLY.

  TWO KINDS, on two schedules:
    -Kind ad      07:00. Pulls the weekly ad for every store whose ad rolled over
                  TODAY (capture-policy decides; a store not due is skipped, not
                  pulled "just in case").
    -Kind daily   08:00. The quarterly rotation slice plus any sale reverting
                  today - total terms / 90 days, per store.

  CONCURRENT, NOT SEQUENTIAL. Every store starts at once as its own background
  job. Running them one at a time meant a slow or wedged store delayed every
  store behind it, and the whole point of a small daily budget is that it should
  finish in a couple of minutes.

  THE BROWSER STORES ARE A HANDOFF, NOT A JOB. Walmart, Sam's Club and Fareway's
  storefront sit behind bot walls that need a real logged-in Chrome, and no
  scheduled task can drive Brad's browser. For those this writes a WORKLIST and
  raises a flag file; the Chrome agent opens ONE TAB PER STORE and works its list.
  Saying that plainly here is deliberate: a runner that silently "succeeded"
  while three stores did nothing is the confident-ok-over-an-empty-examination
  shape this estate keeps rediscovering.

  Exit 0 = every lane that COULD run did. Exit 1 = a lane failed.
  Browser work outstanding is reported, never counted as a failure.
#>
[CmdletBinding()]
param(
  [ValidateSet('ad', 'daily')][string]$Kind = 'daily',
  [string]$OutDir = '',
  [string]$Today = '',
  [int]$TimeoutMinutes = 25,
  # Skip the compare/guards/publish/commit chain. For testing only - a scheduled
  # run must ALWAYS publish, or the captures never reach the live board.
  [switch]$NoDownstream,
  # -Kind ad never runs downstream unless this is passed (ONE CHAIN A DAY, Brad 2026-08-22: the 07:00 ad
  # run captures only; the 08:00 daily run is the one that builds and publishes. Before this, any morning
  # both fired ran the same 20-40 minute audit chain twice - three times on 08-21 with a manual run.)
  [switch]$Downstream,
  [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
$todayS = if ($Today) { $Today } else { (Get-Date).ToString('yyyy-MM-dd') }
. (Join-Path $root 'capture-policy-lib.ps1')
. (Join-Path $root 'run-log-lib.ps1')
. (Join-Path $root 'alert-lib.ps1')   # Send-Alert: the ONLY way this file may page (32 KB command-line trap)

# The scheduled task runs this hidden with no redirect, so without a transcript
# the exit code is the ONLY thing that survives a run. Guarded: never fatal.
$runLog = Start-RunLog -Name ("capture-run-" + $Kind) -OutDir $OutDir -Today $todayS


# ---- THE RUN'S STRUCTURED RECORD (2026-08-22) ----------------------------------------------------------
# The transcript above says what happened; this says HOW FAR IT GOT, in a form capture-watchdog can read
# without parsing prose: out\logs\capture-run-status.json = { ad|daily: { date, pid, started, updated,
# stage, exit_code, log } }, rewritten whole at each stage. A run that sits in 'downstream' for hours, or
# never reaches 'complete', is a finding even when Task Scheduler says rc=0. Guarded: never fatal.
$script:RunStart = Get-Date
$script:StatusFile = Join-Path (Join-Path $OutDir 'logs') 'capture-run-status.json'
function Write-RunStatus([string]$Stage, [object]$ExitCode = $null) {
  # A REHEARSAL MUST NOT WRITE THE RECORD OF A REAL RUN (2026-08-22). Two -WhatIf runs at 08:27 and 08:43
  # overwrote what the real 07:00 and 08:00 runs had written, and capture-watchdog then printed
  # "ok  capture-run [ad] in stage 'whatif'" on a morning when BOTH tasks had failed (0xC000013A and 1).
  # The check added to catch "reported rc=0 but never finished" reported ok on the worst day it has seen.
  if ($WhatIf) { return }
  try {
    $doc = @{}
    if (Test-Path $script:StatusFile) { try { (Get-Content $script:StatusFile -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $doc[$_.Name] = $_.Value } } catch { } }
    $doc[$Kind] = [ordered]@{
      date = $todayS; pid = $PID; started = $script:RunStart.ToString('s'); updated = (Get-Date).ToString('s')
      stage = $Stage; exit_code = $ExitCode; log = [string]$runLog
    }
    $dir = Split-Path $script:StatusFile -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = $script:StatusFile + '.tmp'
    ($doc | ConvertTo-Json -Depth 5) | Set-Content -Path $tmp -Encoding UTF8
    Move-Item -Path $tmp -Destination $script:StatusFile -Force
  } catch { }
}
function Release-RunMutex {
  if ($script:HoldsMutex) { try { $script:RunMutex.ReleaseMutex() } catch { }; $script:HoldsMutex = $false }
}
# ---- ONE CAPTURE-RUN AT A TIME (2026-08-22) -----------------------------------------------------------
# Task Scheduler's MultipleInstances=IgnoreNew is PER TASK, so it does not stop the 07:00 ad run (2h limit)
# from overlapping the 08:00 daily one, and it does not see a manual run at all - both happened today.
# Two runs reach the same git index and the same out\regular files: concurrent rebases either die on
# index.lock or autostash each other's staged work, and an audit reading out\regular while the other run
# rewrites it is a torn read by construction. The old 8:30 runner held a lock for exactly this reason and
# the cutover did not carry it over. Named mutex, same pattern as send-alert's queue writer.
$script:RunMutex = New-Object System.Threading.Mutex($false, 'Global\tc-capture-run')
$script:HoldsMutex = $false
try { $script:HoldsMutex = $script:RunMutex.WaitOne([TimeSpan]::FromMinutes(1)) } catch [System.Threading.AbandonedMutexException] { $script:HoldsMutex = $true }
if (-not $script:HoldsMutex) {
  Write-Output 'SKIP: another capture-run holds the lock (a scheduled run overlapping, or a manual one). Nothing started - two runs on one working tree corrupt each other.'
  Write-RunStatus 'skipped-locked' 0
  Stop-RunLog -ExitCode 0 -Path $runLog
  exit 0
}

Write-RunStatus 'started'

# ---- 1st-OF-MONTH HOUSEKEEPING (moved here 2026-08-22 from the retired run-daily-local.ps1) ----------
# The pipeline logs grow forever and every line rides every bot commit; triage plans are pure history
# once shipped; the Ghost content backup is the only off-Ghost copy. All three lived in the old 8:30
# runner and would have stopped with it. Daily kind only, non-fatal by design: housekeeping must never
# cost the day's prices.
if ($Kind -eq 'daily' -and (Get-Date).Day -eq 1 -and -not $WhatIf) {
  try {
    $arch = Join-Path $root 'logs-archive'
    if (-not (Test-Path $arch)) { New-Item -ItemType Directory -Path $arch -Force | Out-Null }
    $stamp = (Get-Date).AddMonths(-1).ToString('yyyy-MM')
    foreach ($lf in @('ad-cycle-log.txt', 'alert-log.txt', 'ff-sweep-log.txt')) {
      $src = Join-Path $root $lf; $dst = Join-Path $arch ($lf -replace '[.]txt$', "-$stamp.txt")
      if ((Test-Path $src) -and -not (Test-Path $dst)) { Move-Item $src $dst -Force -ErrorAction SilentlyContinue; Write-Output "rotation: $lf -> logs-archive" }
    }
    $tp = Join-Path $root 'triage-plans'; $tpArch = Join-Path $arch 'triage-plans'
    if (Test-Path $tp) {
      if (-not (Test-Path $tpArch)) { New-Item -ItemType Directory -Path $tpArch -Force | Out-Null }
      $moved = 0
      foreach ($pf in @(Get-ChildItem (Join-Path $tp 'plan-*.json') -ErrorAction SilentlyContinue)) {
        if ($pf.BaseName -match '^plan-([0-9]{4}-[0-9]{2})' -and $Matches[1] -le $stamp) { Move-Item $pf.FullName $tpArch -Force -ErrorAction SilentlyContinue; $moved++ }
      }
      if ($moved) { Write-Output "rotation: archived $moved triage plan(s)" }
    }
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'ghost-export.ps1') | ForEach-Object { Write-Output ("ghost-export: " + $_) }
  } catch { Write-Output ("monthly housekeeping threw (not fatal): " + $_.Exception.Message) }
}

# store -> how its EVERYDAY rotation is captured. $null = browser handoff.
$DAILY_LANE = @{
  'Hy-Vee'      = 'pull-regular-hyvee.ps1'
  # Aldi's everyday file is BUILT from a raw aldi.us browser sweep -
  # build-aldi-regular.ps1 consumes the agent's CSV. There is no headless lane.
  'Aldi'        = $null
  "Baker's"     = 'pull-regular-bakers-api.ps1'
  'Family Fare' = 'pull-regular-familyfare.ps1'
  'Fareway'     = $null      # shop.fareway.com is bot-walled
  'Walmart'     = $null
  "Sam's Club"  = $null
}
# store -> how its weekly AD is pulled. $null = browser handoff.
$AD_LANE = @{
  'Hy-Vee'      = 'pull-grocery-ads.ps1'   # combined server pull, all three at once
  'Aldi'        = 'pull-grocery-ads.ps1'
  'Family Fare' = 'pull-grocery-ads.ps1'
  'Fareway'     = 'pull-fareway-ads.ps1'   # own CDN, fully server-side
  "Baker's"     = $null                    # Akamai-walled, agent captures page URLs
  'Walmart'     = $null
  "Sam's Club"  = $null
}

$stores = @('Hy-Vee', 'Aldi', "Baker's", 'Family Fare', 'Fareway', 'Walmart', "Sam's Club")
$lanes = if ($Kind -eq 'ad') { $AD_LANE } else { $DAILY_LANE }

Write-Output ("capture-run [$Kind] $todayS  -  deciding per store from capture-policy")
Write-Output ''

$toRun = @{}          # store -> script
$browser = @()        # stores needing the Chrome agent
$skipped = @()

foreach ($s in $stores) {
  $plan = Get-CapturePlan -Store $s -Today $todayS

  if ($Kind -eq 'ad') {
    if (-not $plan.AdRollover) { $skipped += "$s (ad not due: $($plan.AdNote))"; continue }
  }

  # Always leave the worklist, even for a store we are about to run headlessly -
  # one shape for every store means an audit can ask "what was this store asked
  # for that day?" and get an answer regardless of how it was fetched.
  try { $null = Write-CaptureWorklist -Store $s -Today $todayS -OutDir $OutDir } catch { }

  $script = $lanes[$s]
  if (-not $script) { $browser += $s; continue }
  $toRun[$s] = $script
}

# pull-grocery-ads covers Hy-Vee + Aldi + Family Fare in ONE call; running it
# three times would triple the request cost for identical data.
if ($Kind -eq 'ad') {
  $combined = @($toRun.Keys | Where-Object { $toRun[$_] -eq 'pull-grocery-ads.ps1' })
  if ($combined.Count -gt 1) {
    foreach ($extra in ($combined | Select-Object -Skip 1)) { $toRun.Remove($extra) }
    Write-Output ("  note: " + ($combined -join ', ') + " share pull-grocery-ads.ps1 - running it ONCE")
  }
}

foreach ($s in $skipped) { Write-Output "  skip     $s" }
foreach ($s in $browser) {
  $wl = Get-CaptureWorklist -Store $s -Today $todayS -OutDir $OutDir
  Write-Output ("  BROWSER  {0,-13} {1} term(s) queued - needs a Chrome tab" -f $s, @($wl.Terms).Count)
}
foreach ($s in $toRun.Keys) { Write-Output ("  run      {0,-13} {1}" -f $s, $toRun[$s]) }

if ($WhatIf) { Write-Output "`nWhatIf: nothing launched."; Release-RunMutex; Stop-RunLog -ExitCode 0 -Path $runLog; exit 0 }
Write-RunStatus 'capturing'

# ---- launch every headless lane AT ONCE ------------------------------------
$jobs = @()
foreach ($s in $toRun.Keys) {
  $path = Join-Path $root $toRun[$s]
  if (-not (Test-Path $path)) { Write-Warning "missing $path"; continue }
  $jobs += Start-Job -Name $s -ScriptBlock {
    param($p, $o)
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $p -OutDir $o 2>&1
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($out | Out-String) }
  } -ArgumentList $path, $OutDir
}

if ($jobs.Count) {
  Write-Output ''
  Write-Output ("launched {0} lane(s) concurrently; waiting up to {1} min" -f $jobs.Count, $TimeoutMinutes)
  $null = Wait-Job -Job $jobs -Timeout ($TimeoutMinutes * 60)
}

$failed = @()
foreach ($j in $jobs) {
  $name = $j.Name
  if ($j.State -eq 'Running') {
    Stop-Job $j -ErrorAction SilentlyContinue
    Write-Warning "$name : TIMED OUT after $TimeoutMinutes min - stopped"
    $failed += $name
  } else {
    $r = Receive-Job $j -ErrorAction SilentlyContinue
    $rc = if ($r -and $r.ExitCode -ne $null) { $r.ExitCode } else { 0 }
    $tail = if ($r) { ($r.Output -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 1) } else { '' }
    if ($rc -ne 0 -and $rc -ne $null) { $failed += $name }
    Write-Output ("  {0,-13} rc={1}  {2}" -f $name, $rc, ($tail -replace '\s+', ' ').Trim())
    # A one-line tail is enough to see that a lane WORKED; it is never enough to
    # see why one FAILED - the error is usually 20 lines above the last line.
    # Dump the whole lane on failure, indented, so the transcript answers "why"
    # without a re-run (a re-run costs the store's request budget twice).
    if ($rc -ne 0 -and $r -and $r.Output) {
      Write-Output ("  ---- {0} full output (rc={1}) ----" -f $name, $rc)
      ($r.Output -split "`r?`n") | ForEach-Object { Write-Output ("    | " + $_) }
      Write-Output ("  ---- end {0} ----" -f $name)
    }
  }
  Remove-Job $j -Force -ErrorAction SilentlyContinue
}

# ---- BROWSER STORES: DRIVE THEM, DO NOT JUST ASK SOMEONE TO ---------------------------------
# THIS USED TO BE A FLAG AND NOTHING ELSE (rewritten 2026-08-22 on Brad's instruction: "the job
# should automatically be using Chrome tabs to do the job/pull. If it's not set up to do that, we
# need to fix it."). The old block wrote out\browser-capture-due-<date>.flag saying "open one Chrome
# tab per store" and stopped. The only thing that ever read that flag was a 6:15am Claude agent, and
# when the schedule was cut to three Windows tasks these stores lost their capture path completely -
# Sam's Club had already gone 21 days without a row and Walmart 11.
# pull-browser-stores.py drives a real Chrome over CDP on a persistent per-store profile and runs the
# SAME pull agents (pull-agent-lib.js + pull-<store>-instore.js) an operator would paste by hand, over
# today's worklist only. A bot wall raises Brad's Windows prompt and stops that store cleanly; the
# terms already settled are kept in the page's localStorage so the next run resumes exactly there.
# The flag is still written for whatever the driver could NOT do, so nothing goes quietly undone.
$BROWSER_DRIVER_KEYS = @{ 'Walmart' = 'walmart'; "Sam's Club" = 'samsclub'; 'Fareway' = 'fareway' }
# store -> the builder that turns its raw capture into out\regular\*. The driver deliberately stops at
# the capture file: these builders own the unit-price reconciliation and basis rules, and hand-writing
# their output is the exact mistake that caused the 2026-07-23 Walmart partial-pull incident.
$BROWSER_BUILDERS = @{
  'walmart'  = @{ Script = 'build-walmart-deals.ps1'; In = 'out\captures\walmart-capture-{0}.csv' }
  'samsclub' = @{ Script = 'build-sams-deals.ps1';    In = 'out\captures\sams-capture-{0}.csv' }
  # FAREWAY IS A TWO-STAGE CHAIN, and it is wired up here as of 2026-08-22.
  # It used to stop at the capture because -ModeVerified was understood to mean "a HUMAN confirmed
  # the header said In-Store", and stamping that from a script would have been a claim nobody made.
  # That reasoning is now obsolete: the driver refuses to capture Fareway at all unless
  # farewayIdentity() passes, and that function asserts BOTH retailerLocation == 531573 (Omaha,
  # 17070 Audrey Street) AND fulfillment mode == In-Store, read out of the Apollo cache rather than
  # off the on-screen label - which is strictly stronger evidence than a person glancing at a header,
  # since a fresh session reads plausibly while sitting on Des Moines. The flag is earned, not assumed.
  # Leaving it unwired had a real cost: without -ModeVerified the builder stamps price_mode
  # 'unverified' and compare-deals drops all ~433 Fareway cells, with only a Write-Warning to say so.
  'fareway'  = @{ Script = 'select-fareway-shop.ps1'; In = 'out\fareway\fareway-shop-{0}.jsonl'
                  Then = 'build-fareway-regular.ps1' }
}
$browserUndone = @()
if ($browser.Count) {
  $drivable = @($browser | Where-Object { $BROWSER_DRIVER_KEYS.ContainsKey($_) })
  $browserUndone = @($browser | Where-Object { -not $BROWSER_DRIVER_KEYS.ContainsKey($_) })

  if ($drivable.Count) {
    $py = 'C:\Codex\Python312\python.exe'
    $driver = Join-Path $root 'pull-browser-stores.py'
    if (-not (Test-Path $py) -or -not (Test-Path $driver)) {
      Write-Warning "browser driver unavailable (python or pull-browser-stores.py missing) - these stores fall back to the flag"
      $browserUndone += $drivable
    } else {
      $storeArgs = @()
      foreach ($s in $drivable) { $storeArgs += @('--store', $BROWSER_DRIVER_KEYS[$s]) }
      Write-Output ''
      Write-Output ("browser: driving " + ($drivable -join ', ') + " in Chrome")
      # No 2>&1 - same EAP=Stop rule as the downstream call below.
      # TIMEOUT SIZED TO THE BIGGEST SLICE, NOT THE TYPICAL ONE (raised 10 -> 20, 2026-08-22).
      # "~7 terms a day" is the QUARTERLY ROTATION only. Expiring sales ride on top of it, and
      # capture-policy caps each store rather than trimming: a dry-run for 2026-08-23 showed Fareway
      # at 45 terms - its whole ceiling - because 111 Fareway sale windows refresh that morning.
      # Fareway's navigate lane spends ~8-12s per term (goto, hydrate, extract, pace), so 45 terms is
      # 6-9 minutes and a 10-minute cap would have half-captured it. A half-capture is worse than a
      # skip here: compare-deals hands a commodity to the FRESHEST capture outright, so a thin pass
      # can move a cell onto a worse product.
      # Still bounded well under the task's own 2h limit, so one wedged store cannot hold the morning.
      $bpOut = & $py $driver @storeArgs '--date' $todayS '--timeout-min' '20'
      $bpRc = $LASTEXITCODE
      foreach ($l in @($bpOut)) { Write-Output ("  " + $l) }
      Write-Output ("browser driver rc=$bpRc")

      # A store whose capture landed gets BUILT here, so its rows reach compare-deals in the very
      # same run. Building is judged per store, not on the driver's overall exit code: one walled
      # store must not discard another store's good capture.
      foreach ($s in $drivable) {
        $key = $BROWSER_DRIVER_KEYS[$s]
        # DID THE CAPTURE LAND? Asked for EVERY drivable store, including the ones this script does
        # not build. Fareway used to skip straight to "builder runs separately" without ever checking
        # whether a capture existed, so a Fareway that failed or was never seeded vanished from the
        # outstanding list entirely - reported as neither captured nor pending.
        $capRel = if ($BROWSER_BUILDERS.ContainsKey($key)) { $BROWSER_BUILDERS[$key].In -f $todayS }
                  else { "out\captures\$key-capture-$todayS.csv" }
        if (-not (Test-Path (Join-Path $root $capRel))) {
          Write-Output ("  {0}: no capture file ({1}) - still outstanding" -f $s, $capRel)
          $browserUndone += $s
          continue
        }
        if (-not $BROWSER_BUILDERS.ContainsKey($key)) {
          Write-Output ("  {0}: captured {1} - no builder wired for this store yet" -f $s, $capRel)
          continue
        }
        $bScript = Join-Path $root $BROWSER_BUILDERS[$key].Script
        # Fareway's selector takes -Today, the CSV builders take -Date. Passing the wrong one binds
        # nothing and the script silently dates itself to the wall clock, which on a -Today replay
        # would file a rebuild of an old capture under today.
        # ABSOLUTE -In, NOT $capRel (fixed 2026-08-23). The existence check 20 lines up asks
        # `Test-Path (Join-Path $root $capRel)` - an ABSOLUTE path, which passes - and then this
        # handed the child the RELATIVE one. The child resolves it against ITS OWN working directory,
        # which for a scheduled task is not the repo, so it threw "input not found" on a file sitting
        # right there. Measured on the 2026-08-23 08:00 run, the first day both browser lanes actually
        # delivered: Fareway wrote 45 of 45 terms at 08:14 and Sam's Club 7 MATCHES at 08:15, both
        # builders exited 1, and the whole capture was dropped. Proving a path one way and passing it
        # another is the bug; proving and passing the SAME absolute path is the fix.
        $capAbs = Join-Path $root $capRel
        $bOut = if ($key -eq 'fareway') {
          & powershell -NoProfile -ExecutionPolicy Bypass -File $bScript -In $capAbs -Today $todayS
        } else {
          & powershell -NoProfile -ExecutionPolicy Bypass -File $bScript -In $capAbs -Date $todayS
        }
        $bRc = $LASTEXITCODE
        foreach ($l in @($bOut)) { Write-Output ("    " + $l) }
        if ($bRc -ne 0) { Write-Warning ("{0}: builder exited {1}" -f $s, $bRc); $failed += ("build-" + $key) }

        # SECOND STAGE, only if the first one worked. -ModeVerified is passed because the driver
        # already proved In-Store (see the note on $BROWSER_BUILDERS); without it every Fareway cell
        # is dropped by compare-deals.
        if ($bRc -eq 0 -and $BROWSER_BUILDERS[$key].ContainsKey('Then')) {
          $b2 = Join-Path $root $BROWSER_BUILDERS[$key].Then
          $b2Out = & powershell -NoProfile -ExecutionPolicy Bypass -File $b2 -Today $todayS -ModeVerified $todayS
          $b2Rc = $LASTEXITCODE
          foreach ($l in @($b2Out)) { Write-Output ("    " + $l) }
          if ($b2Rc -ne 0) {
            # A SECOND RUN IN ONE DAY IS NOT A FAILED RUN. build-fareway-regular REFUSES to overwrite
            # today's file when a rebuild would shrink it - correct, because the file on disk has
            # carry-forward applied (912 rows) while a rebuild from the shop capture alone starts at
            # 461, and clobbering it would drop every carried row. But the refusal exits 1, so a
            # re-run (a manual build earlier, or the 07:00 and 08:00 jobs overlapping) marked the
            # whole store FAILED while today's prices were sitting on disk, correct and complete.
            # So judge it on the evidence rather than the exit code: if today's file exists AND holds
            # rows captured today, the store is fine and the guard did its job.
            $fwOut = Join-Path $root ("out\regular\fareway-regular-$todayS.json")
            $freshToday = 0
            if (Test-Path $fwOut) {
              try {
                $fwDoc = Get-Content $fwOut -Raw -Encoding UTF8 | ConvertFrom-Json
                $freshToday = @($fwDoc.deals | Where-Object { ([string]$_.as_of) -like "$todayS*" }).Count
              } catch { }
            }
            if ($freshToday -gt 0) {
              Write-Output ("  {0}: {1} declined to rebuild (exit {2}) but today's file already holds {3} row(s) captured today - not a failure." -f $s, $BROWSER_BUILDERS[$key].Then, $b2Rc, $freshToday)
            } else {
              Write-Warning ("{0}: {1} exited {2} and no rows dated {3} are on disk" -f $s, $BROWSER_BUILDERS[$key].Then, $b2Rc, $todayS)
              $failed += ("build2-" + $key)
            }
          }
        }
      }
    }
  }
}

# The flag now means "what the driver could NOT do", which is a much smaller and more honest claim
# than the old "all browser stores are outstanding". Written only when something really is left.
if ($browserUndone.Count) {
  $flag = Join-Path $OutDir ("browser-capture-due-$todayS.flag")
  $body = @{
    date = $todayS; kind = $Kind; stores = $browserUndone
    note = ('These stores could NOT be driven automatically. Open ONE CHROME TAB PER STORE and work ' +
            'each store worklist in out\worklists\capture-<store>-<date>.json. Advance the cursor ' +
            'with Save-CaptureCursor only AFTER the capture lands. (Aldi is here by design: its pull ' +
            'agent walks product slugs, not search terms - see pull-browser-stores.py ALDI_NOTE.)')
  } | ConvertTo-Json -Depth 4
  Set-Content -Path $flag -Value $body -Encoding UTF8
  Write-Output ''
  Write-Output ("BROWSER WORK OUTSTANDING: " + ($browserUndone -join ', '))
  Write-Output ("  worklists in $OutDir\worklists ; flag: " + (Split-Path $flag -Leaf))
}

Write-Output ''
# browser-pending counts what is STILL outstanding after the driver ran, not how many browser stores
# exist. Reporting the latter would say "4 pending" on a run that successfully captured three of them.
Write-Output ("capture-run [$Kind] captures done. lanes run={0} failed={1} browser-pending={2}" -f $jobs.Count, $failed.Count, $browserUndone.Count)

# ---- DOWNSTREAM: capture is only half the job -------------------------------
# Capturing prices without recomputing and publishing leaves the new numbers
# sitting in out\ while the live site keeps yesterday's board. check-ad-cycles
# owns that whole chain - compare-deals, the guard suite, the deals page, the
# recipe re-cost, compute-v2, top5-weekly, rotate-free-dinners, commit+push - and
# it must run after EVERY capture, not just the ad one: ads land on different
# days per store, but everyday prices move daily.
#
# -NoPull is the important flag. This script has already done the pulling, under
# the capture policy's budget. Letting check-ad-cycles pull again would both
# double the request cost and bypass the budget that exists to stop us being
# rate-limited in the first place.
$runDownstream = (-not $NoDownstream) -and (($Kind -ne 'ad') -or $Downstream)
if ((-not $NoDownstream) -and (-not $runDownstream)) {
  Write-Output ''
  Write-Output 'downstream: SKIPPED - the ad run captures only; the 08:00 daily run builds and publishes (pass -Downstream to override)'
}
if ($runDownstream) {
  Write-RunStatus 'downstream'
  Write-Output ''
  Write-Output 'downstream: check-ad-cycles -NoPull (compare -> guards -> publish -> recipes -> commit)'
  $cac = Join-Path $root 'check-ad-cycles.ps1'
  if (Test-Path $cac) {
    # NO 2>&1 ON THE CHILD (fixed 2026-08-22). This line used to read:
    #     & powershell ... -File $cac -NoPull 2>&1 | ForEach-Object { ... }
    # and this script sets $ErrorActionPreference='Stop'. In PS 5.1 that combination
    # is fatal: redirecting a native child's stderr wraps each line in an ErrorRecord
    # (NativeCommandError), and under EAP=Stop the FIRST such line becomes a
    # TERMINATING throw. capture-run then died right here - after the downstream
    # child had already done its work - so the run never printed its rc, never
    # printed the browser handoff, never printed CAPTURE-RUN-COMPLETE, and exited 1.
    # That is the whole of the 'TC Grocery Ad Pulls 0700' and 'Daily Capture 0800'
    # exit-1 mystery: check-ad-cycles emits ordinary warnings, and one was enough.
    # Reproduced 2026-08-22 with a 3-line probe before changing anything.
    # check-ad-cycles.ps1 already carries this exact rule in its own comments
    # ("No 2>&1 / 2>$null on the child ... capture then read $LASTEXITCODE") - this
    # caller simply did not follow it. Same rule, same file, one copy of the lesson.
    # STREAMED, NOT COLLECTED. A first version of this fix captured the child into a variable and
    # printed it afterwards. That fixed the crash and broke the diagnosis: the downstream chain runs
    # for ~25 minutes, so the transcript showed nothing at all until it finished - and when the
    # 2026-08-22 07:00 run was killed part-way through, every line it had produced went with it.
    # Piping to ForEach-Object streams each line as it arrives, so a killed run still leaves a
    # transcript that says how far it got. Verified: with no 2>&1 the child's stderr passes straight
    # through untouched (no NativeCommandError, no throw) and $LASTEXITCODE still reads the child's
    # real exit code through the pipeline.
    & powershell -NoProfile -ExecutionPolicy Bypass -File $cac -NoPull | ForEach-Object { Write-Output ("  " + $_) }
    $dsRc = $LASTEXITCODE
    Write-Output ("downstream rc=$dsRc")
    if ($dsRc -ne 0) { $failed += 'downstream' }
  } else {
    Write-Warning "check-ad-cycles.ps1 not found - captures landed but NOTHING WAS PUBLISHED"
    $failed += 'downstream-missing'
  }
}

# ---- COMMIT + PUSH + PROVE THE EDGE TOOK IT (re-homed 2026-08-22) --------------------------------------
# THE LAST MILE WAS SEVERED AND NOTHING NOTICED. Cloudflare serves public\** from the git repo, so a price
# only reaches a reader once it is COMMITTED AND PUSHED. That step lived in run-daily-local.ps1, and the
# 2026-08-20 cutover to the three TC tasks did not carry it over: the last smp-pipeline-bot commit was
# 2026-08-18, while public\board.json and public\smp-feed.json were regenerated every morning and left
# sitting in the working tree. For four days the live site served whatever a HUMAN commit had last swept
# in (2026-08-21 12:38). The pipeline was healthy and the product was stale, which is the worst shape a
# failure can take: every check green, every number right, nobody looking at them.
#
# *** STAGE PIPELINE-OWNED PATHS ONLY - NEVER git add -A. *** The cloud backup runs in a throwaway clone;
# this shares Brad's REAL working tree, where interactive sessions and other agents are editing code at
# the same time (today: pull-browser-stores.py and media\reels\cdp.py, mid-edit, in this very tree). A
# blind add -A would sweep half-finished work into a bot commit and push it. The list below is the exact
# set real bot commits have ever touched, plus rollback-first-seen.json (the TTL ledger added today).
# Anything else the pipeline may someday write stays uncommitted here and is reported, never guessed at.
# -NoDownstream is the TESTING flag (its own param comment says so). A test run must never commit or push
# real data to main, so publishing is gated on it exactly as the chain is. -WhatIf already exited above.
$today = $todayS
$repo = Split-Path -Parent $root
if ($NoDownstream) { Write-Output 'publish: SKIPPED (-NoDownstream is a testing flag - no commit, no push)' }
else {
# TWO SETS, BECAUSE THEY CARRY DIFFERENT PROOF (2026-08-22).
# INPUTS are what a store told us: raw captures, the schedules and ledgers derived from them, the logs.
# They are evidence and are always worth committing - a capture-only ad run has nothing else to say.
# SERVED are what a READER gets: public\** (Cloudflare deploys it from the repo) and the meal-prep files
# the recipe cards price from. Those may be staged ONLY by a run that actually built them AND passed the
# gate. Two ways that was wrong before this split:
#   - the 07:00 ad run runs no chain at all, yet staged public\ and nine meal-prep paths - so whatever an
#     overnight session had left mid-edit in them would be committed as smp-pipeline-bot and pushed;
#   - export-feed writes public\smp-feed.json BEFORE guards run, so a board guards REJECTED still shipped
#     its feed to the edge while the board post correctly stayed at last-good. Every recipe card prices
#     off that feed: the one path where this system could publish confidently wrong numbers.
$inputPaths = @('grocery/out',
                'grocery/ad-cycle-log.txt', 'grocery/alert-log.txt', 'grocery/ff-sweep-log.txt',
                'grocery/ad-schedule.json', 'grocery/price-history.json', 'grocery/product-urls.json',
                'grocery/sale-windows.json', 'grocery/rollback-first-seen.json',
                # THE PRODUCT IDENTITY TABLE. It is regenerated every morning, so if it is not staged here
                # it never leaves this PC - which is exactly the last-mile failure found on 2026-08-22
                # (public\board.json rebuilt daily, last bot commit four days old). It also has to be
                # tracked for the table to exist in the cloud at all: daily.yml clones clean and rebuilds
                # graph.db from tracked JSON, so an untracked table means an empty index there.
                # On a quiet day the emitter writes identical bytes and this stages nothing.
                'graph/identity')
$servedPaths = @('public',
                 'meal-prep/db/costed.json', 'meal-prep/db/cost-flags.txt',
                 'meal-prep/pipeline/v2-perserving.json', 'meal-prep/pipeline/v2-perserving.prev.json',
                 'meal-prep/pipeline/v2-inversions.json',
                 'meal-prep/free-rotation.json', 'meal-prep/ingredient-map.json',
                 'meal-prep/recipes-db.json')
# the gate's own verdict, written by check-ad-cycles right after guards ran (never inferred from a log)
$guardsBlocked = $false
$verdictSeen = $false
try {
  $vf = Join-Path $OutDir 'chain-verdict.json'
  if (Test-Path $vf) {
    $v = Get-Content $vf -Raw | ConvertFrom-Json
    if ([string]$v.date -eq $todayS) { $verdictSeen = $true; $guardsBlocked = [bool]$v.guards_blocked }
  }
} catch { Write-Output ('chain-verdict unreadable: ' + $_.Exception.Message) }
$shipServed = $runDownstream -and $verdictSeen -and (-not $guardsBlocked)
if ($runDownstream -and -not $shipServed) {
  $why = if (-not $verdictSeen) { 'the chain wrote no verdict for today (it did not reach the guard stage)' } else { 'guards BLOCKED this board' }
  Write-Output ("publish: staging INPUTS only - $why, so public\** and the recipe files are NOT shipped. Readers keep the last good board.")
  $failed += 'guards-blocked'
}
$paths = @($inputPaths + $(if ($shipServed) { $servedPaths } else { @() })) | Where-Object { Test-Path (Join-Path $repo $_) }
Write-RunStatus 'publishing'
$pushed = $false
try {
  # alert-sent-*.txt rotate (created+deleted daily). Two traps in one line, both hit on 2026-08-22, the
  # first real run of this stage: git EXITS NONZERO on a pathspec that matches nothing, and `2>$null` on a
  # native child under EAP=Stop makes its first stderr line a TERMINATING error - the exact class
  # test-native-stderr-eap.ps1 exists to catch, which I reintroduced here while fixing it elsewhere. So:
  # no redirect, and only pass the pathspec when git itself says there is something under it (tracked or
  # untracked). The whole publish threw on this and nothing shipped.
  $alertSent = @(& git -C $repo status --porcelain --untracked-files=all -- 'grocery/alert-sent-*.txt' | Where-Object { $_ })
  if ($alertSent.Count) { & git -C $repo add -A -- 'grocery/alert-sent-*.txt' | ForEach-Object { Write-Output ("add: " + $_) } }
  & git -C $repo add -A -- $paths | ForEach-Object { Write-Output ("add: " + $_) }
  & git -C $repo diff --cached --quiet
  if ($LASTEXITCODE -eq 0) {
    Write-Output 'commit: no pipeline changes to commit'
    $pushed = $true      # nothing to ship is not a failed ship
  } else {
    $msg = "Daily pipeline: refresh prices + feed ($today) [$Kind]"
    & git -C $repo -c user.name="smp-pipeline-bot" -c user.email="actions@users.noreply.github.com" commit -m $msg |
      ForEach-Object { Write-Output ("commit: " + $_) }
    # PUSH with the conflict-survival the cloud learned on 2026-07-16: -X theirs prefers the freshly
    # regenerated derived files; abort on unresolvable so we NEVER strand a detached HEAD; autoStash
    # carries any human WIP across the rebase untouched.
    foreach ($attempt in 1..4) {
      # NO REDIRECT ON git fetch. `git fetch` writes its ordinary progress ("From https://github.com/...")
      # to STDERR on every fetch that moves a ref, and under EAP=Stop a native child's stderr becomes a
      # TERMINATING error even with `2>$null` - the same trap documented 20 lines above for the add stage
      # and fixed 2026-08-22 for the downstream child. It hit here on the 2026-08-23 07:00 ad run: both
      # captures succeeded, the commit landed, and then fetch's first stderr line threw out of the whole
      # try block, so push was NEVER ATTEMPTED and the run exited 1 with FAILED LANES: push.
      & git -C $repo fetch origin main | ForEach-Object { Write-Output ("fetch[$attempt]: " + $_) }
      & git -C $repo -c rebase.autoStash=true rebase -X theirs origin/main | ForEach-Object { Write-Output ("rebase[$attempt]: " + $_) }
      if ($LASTEXITCODE -ne 0) {
        Write-Output "rebase attempt $attempt conflicted; aborting (never detached)"
        & git -C $repo rebase --abort | ForEach-Object { Write-Output ("abort[$attempt]: " + $_) }   # no redirect: same EAP=Stop rule
        Start-Sleep -Seconds 10; continue
      }
      & git -C $repo push origin HEAD:main | ForEach-Object { Write-Output ("push[$attempt]: " + $_) }
      if ($LASTEXITCODE -eq 0) { $pushed = $true; Write-Output "pushed on attempt $attempt"; break }
      Start-Sleep -Seconds 10
    }
    if (-not $pushed) {
      Write-Output 'PUSH FAILED after 4 attempts - this run''s data is committed locally but NOT on main, so the live site still serves the previous board'
      $failed += 'push'
      try { Send-Alert -Subject "Grocery pipeline could not push - $today" -Body ("capture-run.ps1 [$Kind] committed today's refresh locally but could not push to main after 4 rebase attempts. Cloudflare deploys from the repo, so the live board and feed are STALE until this lands. Check for a rebase conflict in $repo (see grocery\out\logs\capture-run-$Kind-$today.log).") | Out-Null } catch {}
    }
  }
} catch { Write-Output ("commit/push threw: " + $_.Exception.Message); $failed += 'push' }

# ---- READ-AFTER-WRITE: prove the EDGE serves what we just pushed (was run-daily-local's check) ---------
# A successful push is NOT a successful deploy: if the Cloudflare build fails afterwards the edge keeps
# serving the OLD feed indefinitely and nothing in the estate notices. Cache-busted on purpose - the
# response carries max-age=1800, and reading through the edge cache would only confirm the cache. Only
# after a run that actually rebuilt the feed (the chain), and never fatal: this is a watcher, not a gate.
if ($runDownstream -and $pushed) {
  try {
    $repoFeed = Get-Content (Join-Path $repo 'public\smp-feed.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    # POLL, DO NOT GUESS. A Workers asset deploy takes 1-3 minutes; the single 30-second check this
    # replaced would have reported EDGE STALE on most days, and an alert that cries wolf about the one
    # thing a reader actually sees is worse than no alert. Give it 5 minutes, then say so.
    $live = $null
    foreach ($try in 1..10) {
      Start-Sleep -Seconds 30
      try { $live = ((Invoke-WebRequest -Uri ("https://feed.thriftycrew.com/smp-feed.json?deploycheck=" + [guid]::NewGuid().ToString('N')) -UseBasicParsing -TimeoutSec 45).Content | ConvertFrom-Json) } catch { continue }
      if ([string]$live.generated -eq [string]$repoFeed.generated) { break }
    }
    if ($null -eq $live -or [string]$live.generated -ne [string]$repoFeed.generated) {
      $m = "The edge is serving a feed generated $($live.generated) but the repo pushed $($repoFeed.generated). The push succeeded, so this is a Cloudflare deploy that has not landed. Live recipe prices are stale until it does. Check the CF dashboard build log."
      Write-Output ("EDGE STALE: " + $m)
      try { Send-Alert -Subject "smp-feed edge did not pick up today's push - $today" -Body $m | Out-Null } catch {}
    } else {
      Write-Output ("edge verified: serving generated $($live.generated), $($live.recipe_count) recipes")
      # board.json is 2.5 MB of store chips - every price a shopper reads on the board page - and had no
      # read-after-write at all. Same question, second file.
      try {
        $repoBoard = (Get-Content (Join-Path $repo 'public\board.json') -Raw -Encoding UTF8)
        $liveBoard = (Invoke-WebRequest -Uri ("https://feed.thriftycrew.com/board.json?deploycheck=" + [guid]::NewGuid().ToString('N')) -UseBasicParsing -TimeoutSec 45).Content
        $norm = { param($t) ($t -replace "`r`n", "`n").Trim() }
        if ((& $norm $liveBoard) -ne (& $norm $repoBoard)) {
          $bm = 'The edge is serving a board.json that does not match the one just pushed (' + (& $norm $liveBoard).Length + ' vs ' + (& $norm $repoBoard).Length + ' chars). smp-feed deployed, so this is board.json specifically - the store chips on the board page are stale.'
          Write-Output ('EDGE STALE (board): ' + $bm)
          try { Send-Alert -Subject "board.json edge did not pick up today's push - $today" -Body $bm | Out-Null } catch {}
        } else { Write-Output 'edge verified: board.json matches the pushed copy' }
      } catch { Write-Output ("board edge verify threw (not fatal): " + $_.Exception.Message) }
    }
  } catch { Write-Output ("edge verify threw (not fatal): " + $_.Exception.Message) }
}

# ---- ASSERT THE FEED TRULY REFRESHED (was run-daily-local's assert) ------------------------------------
# `generated` ALONE CANNOT DETECT THE FAILURE THIS EXISTS FOR: export-feed stamps that field itself, at the
# moment it runs. Every recipe-lane stage upstream is non-fatal try/catch, so if one throws, export-feed
# still runs happily over YESTERDAY's costed.json and stamps TODAY on the output - green assert, stale
# prices, the dates-written-not-measured class. So check the INPUTS the feed's numbers derive from, and
# ask by NAME whether every published recipe is in it. Only meaningful after the chain ran.
if ($runDownstream) {
  try {
    $feed = Get-Content (Join-Path $repo 'public\smp-feed.json') -Raw | ConvertFrom-Json
    $problems = New-Object System.Collections.Generic.List[string]
    $gen = ([datetime]$feed.generated).ToString('yyyy-MM-dd')
    if ($gen -ne $today) { [void]$problems.Add("smp-feed.generated is $gen, expected $today") }
    foreach ($dep in @('meal-prep\db\costed.json', 'meal-prep\pipeline\v2-perserving.json')) {
      $dp = Join-Path $repo $dep
      if (-not (Test-Path $dp)) { [void]$problems.Add("$dep missing"); continue }
      $mt = (Get-Item $dp).LastWriteTime.ToString('yyyy-MM-dd')
      if ($mt -ne $today) { [void]$problems.Add("$dep last written $mt, not today - a recipe-lane stage threw and the feed re-exported stale numbers") }
    }
    # WHICH SET THE FEED IS MEASURED AGAINST: THE PUBLISHED ONE, NOT THE SPEC FOLDER (2026-08-23).
    # This used to compare recipe_count against the number of files in meal-prep\db\recipes, and those two
    # have never counted the same thing. A spec exists the moment a recipe is WRITTEN; it enters the feed
    # only once top5-weekly costs it, and top5-weekly costs a recipe only when it is PUBLISHED (its own
    # `if (-not ("" + $r.published -match '^\d{4}')) { continue }`). Ten finished-but-unpublished specs were
    # sitting in that folder on 2026-08-23, so the assert reported "feed carries 564 recipes but 570 specs
    # exist" about a feed that was in fact covering all 560 published recipes.
    #
    # A COUNT CANNOT ASK THIS QUESTION IN EITHER DIRECTION. It reads green whenever two unrelated numbers
    # happen to match - drop one published recipe from the feed on a day one draft is authored and the tally
    # is perfect - and the failure this assert exists for is feed-covers-published's founding bug: a
    # PUBLISHED recipe whose card fetches a feed that has never heard of its slug, rendering an empty cost
    # section to a paying reader. That is MEMBERSHIP, not a tally. So ask it by name, off the same authority
    # feed-covers-published reads (db\published-hashes.json), rather than a second copy of "what counts as
    # published".
    #
    # AND NOTHING ELSE ASKS IT DAILY: feed-covers-published runs only in the PUBLISH chain
    # (propagate-recipes, wave-publish), scoped to the wave being shipped. This is the daily check.
    $specCount = @(Get-ChildItem (Join-Path $repo 'meal-prep\db\recipes\*.json') -ErrorAction SilentlyContinue).Count
    $pubFile  = Join-Path $repo 'meal-prep\db\published-hashes.json'
    $pubSlugs = @()
    if (-not (Test-Path $pubFile)) {
      # NOT a silent pass. "Could not evaluate" has to look different from "evaluated clean", or this
      # becomes one more guard that is quiet because it is blind.
      [void]$problems.Add('meal-prep\db\published-hashes.json is missing, so the feed was NOT checked against the published set')
    } else {
      try { foreach ($pp in ((Get-Content $pubFile -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties)) { $pubSlugs += [string]$pp.Name } }
      catch { [void]$problems.Add('meal-prep\db\published-hashes.json is unreadable, so the feed was NOT checked against the published set') }
      # AN EMPTY PUBLISHED SET IS BLINDNESS, NOT COVERAGE (2026-08-23). The missing and unreadable cases
      # above are both reported, and then this one slipped through: a published-hashes.json that PARSES
      # but holds no slugs left $pubSlugs empty, skipped the whole membership check, added no problem, and
      # printed the green "feed fresh ... covering all 0 published" line. Could-not-evaluate has to look
      # different from evaluated-clean in every direction, or the guard is quiet exactly when it is blind.
      if (-not $pubSlugs.Count) {
        [void]$problems.Add('meal-prep\db\published-hashes.json parsed but names NO published recipes, so the feed was NOT checked against anything - this is a blind assert, not a clean one')
      }
      if ($pubSlugs.Count) {
        $feedSlugs = @{}
        foreach ($fp in $feed.recipes.PSObject.Properties) { $feedSlugs[[string]$fp.Name] = $true }
        $absent = @($pubSlugs | Where-Object { -not $feedSlugs.ContainsKey($_) })
        if ($absent.Count) { [void]$problems.Add(("{0} PUBLISHED recipe(s) absent from the feed their own cards fetch - each one renders an empty cost section to readers right now: {1}" -f $absent.Count, ((@($absent) | Select-Object -First 8) -join ', '))) }
        # THE OTHER DIRECTION IS NOT A FAILURE, and failing on it would put this assert red for a day every
        # time a recipe comes down. export-feed runs on check-ad-cycles' SHIP path; top5-weekly, which
        # writes the recipe-costs.json the feed's recipe list is built from, runs on the INSPECT path after
        # it. So the feed always carries the PREVIOUS run's slug list, and a recipe unpublished today
        # lingers in it for exactly one more run before dropping out on its own - dead weight nothing links
        # to, not a broken page. Printed anyway, on its own line: a lag nobody can see is a lag nobody
        # notices growing.
        $stale = @($feedSlugs.Keys | Where-Object { $pubSlugs -notcontains $_ })
        if ($stale.Count) { Write-Output ("feed note: {0} feed slug(s) are no longer published and drop out on the next run - export-feed runs before top5-weekly, so the recipe list is one run behind: {1}" -f $stale.Count, ((@($stale) | Select-Object -First 8) -join ', ')) }
      }
    }
    if ($problems.Count) {
      Write-Output ("FEED ASSERT FAILED: " + ($problems -join ' | '))
      try { Send-Alert -Subject "Grocery pipeline: feed did not truly refresh - $today" -Body ("capture-run.ps1 finished but the feed is not trustworthy:`n`n" + ($problems -join "`n") + "`n`nNote ``generated`` alone is self-stamped by export-feed and cannot detect an upstream stage throwing. See grocery\ad-cycle-log.txt.") | Out-Null } catch {}
    } else { Write-Output ("feed fresh: week $($feed.week_of), $($feed.recipe_count) recipes covering all $($pubSlugs.Count) published, $($feed.ingredient_count) ingredients; $specCount spec file(s) on disk - drafts included, and not expected in the feed (inputs verified same-day)") }
  } catch { Write-Output ("feed assert threw: " + $_.Exception.Message) }
}

}   # end publish gate

Write-Output 'CAPTURE-RUN-COMPLETE'

if ($failed.Count) { Write-Output ("FAILED LANES: " + ($failed -join ', ')) }
$rcFinal = if ($failed.Count) { 1 } else { 0 }
Write-Output ("elapsed " + [int]((Get-Date) - $script:RunStart).TotalSeconds + " s")
Write-RunStatus 'complete' $rcFinal
Release-RunMutex
Stop-RunLog -ExitCode $rcFinal -Path $runLog
exit $rcFinal

