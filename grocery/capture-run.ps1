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
  [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
$todayS = if ($Today) { $Today } else { (Get-Date).ToString('yyyy-MM-dd') }
. (Join-Path $root 'capture-policy-lib.ps1')
. (Join-Path $root 'run-log-lib.ps1')

# The scheduled task runs this hidden with no redirect, so without a transcript
# the exit code is the ONLY thing that survives a run. Guarded: never fatal.
$runLog = Start-RunLog -Name ("capture-run-" + $Kind) -OutDir $OutDir -Today $todayS

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

if ($WhatIf) { Write-Output "`nWhatIf: nothing launched."; Stop-RunLog -ExitCode 0 -Path $runLog; exit 0 }

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
      # TIMEOUT SIZED TO THE WORK, NOT TO THE WORST CASE. Under the quarterly policy a store gets
      # ~7 terms, and the slowest pacing profile (Walmart, 3.5s +/- 2s, 3 retries) settles that in
      # a couple of minutes. The driver's own default is 40 min, which across three stores would let
      # one wedged store hold the 08:00 job for two hours and collide with the next day's run.
      $bpOut = & $py $driver @storeArgs '--date' $todayS '--timeout-min' '10'
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
          # Fareway's capture feeds select-fareway-shop -> build-fareway-regular, a two-stage path
          # whose -ModeVerified flag means "a human confirmed the header said In-Store". Running it
          # blind from here would stamp that claim without the confirmation, and without the flag
          # compare-deals drops all 433 Fareway cells - so this stops at the capture, on purpose.
          Write-Output ("  {0}: captured {1} - its builder chain is run separately (-ModeVerified needs a human's In-Store confirmation)" -f $s, $capRel)
          continue
        }
        $bScript = Join-Path $root $BROWSER_BUILDERS[$key].Script
        $bOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $bScript -In $capRel -Date $todayS
        $bRc = $LASTEXITCODE
        foreach ($l in @($bOut)) { Write-Output ("    " + $l) }
        if ($bRc -ne 0) { Write-Warning ("{0}: builder exited {1}" -f $s, $bRc); $failed += ("build-" + $key) }
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
if (-not $NoDownstream) {
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

Write-Output 'CAPTURE-RUN-COMPLETE'
if ($failed.Count) { Write-Output ("FAILED LANES: " + ($failed -join ', ')) }
$rcFinal = if ($failed.Count) { 1 } else { 0 }
Stop-RunLog -ExitCode $rcFinal -Path $runLog
exit $rcFinal

