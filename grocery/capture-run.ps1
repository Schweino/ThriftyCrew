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
. (Join-Path $root 'capture-policy.ps1')

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

if ($WhatIf) { Write-Output "`nWhatIf: nothing launched."; exit 0 }

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
  }
  Remove-Job $j -Force -ErrorAction SilentlyContinue
}

# ---- browser handoff flag ---------------------------------------------------
if ($browser.Count) {
  $flag = Join-Path $OutDir ("browser-capture-due-$todayS.flag")
  $body = @{
    date = $todayS; kind = $Kind; stores = $browser
    note = ('Open ONE CHROME TAB PER STORE and work each store worklist in ' +
            'out\worklists\capture-<store>-<date>.json. These stores are bot-walled ' +
            'and cannot be captured headlessly. Advance the cursor with ' +
            'Save-CaptureCursor only AFTER the capture lands.')
  } | ConvertTo-Json -Depth 4
  Set-Content -Path $flag -Value $body -Encoding UTF8
  Write-Output ''
  Write-Output ("BROWSER WORK OUTSTANDING: " + ($browser -join ', '))
  Write-Output ("  worklists in $OutDir\worklists ; flag: " + (Split-Path $flag -Leaf))
}

Write-Output ''
Write-Output ("capture-run [$Kind] captures done. lanes run={0} failed={1} browser-pending={2}" -f $jobs.Count, $failed.Count, $browser.Count)

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
    & powershell -NoProfile -ExecutionPolicy Bypass -File $cac -NoPull 2>&1 | ForEach-Object { Write-Output ("  " + $_) }
    $dsRc = $LASTEXITCODE
    Write-Output ("downstream rc=$dsRc")
    if ($dsRc -ne 0) { $failed += 'downstream' }
  } else {
    Write-Warning "check-ad-cycles.ps1 not found - captures landed but NOTHING WAS PUBLISHED"
    $failed += 'downstream-missing'
  }
}

Write-Output 'CAPTURE-RUN-COMPLETE'
if ($failed.Count) { exit 1 } else { exit 0 }
