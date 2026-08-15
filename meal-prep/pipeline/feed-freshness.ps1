# feed-freshness.ps1 - THE rule for which price feed a pricing stage is allowed to compute on, and the
# guard that refuses a stale one.
#
# WHY THIS EXISTS (2026-08-15, found by the recipe-batch-auditor during the Recipe Hunter v2 shakedown).
# compute-v2-perserving.ps1 downloaded the feed to meal-prep\scratch-smpfeed.json IF THE FILE WAS MISSING,
# and never again. The file was written 2026-07-27 and was still being priced against nineteen days later.
# Nothing reported it, because a present-but-old file looks exactly like a fresh one and the output is a
# plausible dollar figure either way - the dates-written-not-measured shape, on the estate's headline
# per-serving number.
#
# MEASURED at the moment of the fix, July 27 snapshot vs that morning's live feed:
#   264 of 564 shared ingredient prices had moved (47%), mean |27%|, 174 down / 90 up
#   196 items had changed store-of-record; 41 items existed live that the snapshot had never heard of
#   534 of 544 recipes' cheapest_ps moved; 304 by >= $0.10, 80 by >= $0.25, 12 by >= $0.50
#   21 recipes tripped the cheapest>everyday inversion clamp under the snapshot and ZERO under the live
#      feed - so the stale feed was also manufacturing phantom price-inversion alerts to triage
#   3 of 6 protein classes had a different top-5 set, which is the free-dinner rotation's selection
# and the manifest sitting on disk matched the JULY computation on 534 of 544 rows and the live feed on
# none of them. This was not a latent risk; it was live.
#
# THE ROOT CAUSE WAS NOT "it never refreshes". It was that the default fed a PRIVATE CACHE while the estate
# already had a canonical feed on disk. Two callers were passing two different feeds at the same source:
# check-ad-cycles passed grocery\out\smp-feed.json (correct, daily), wave-publish passed nothing (the July
# cache). Both write the same manifest, so last writer wins, and the stale writer ran last.
#
# ---- THE WINDOWS, AND WHY THEY ARE THESE NUMBERS ---------------------------------------------------
# Writer cadence: "SMP Grocery Daily Pipeline (local)", daily 08:30; export-feed stamps `generated` ~09:10.
# Period = 24h. Per the standing lesson (tolerance wider than period lets yesterday's output alibi a run
# that never happened) the FRESHNESS PROOF here is deliberately NOT a clock window at all:
#
#   1. RUN-TIED PROOF, no window: the feed being priced on may not be OLDER than the canonical feed
#      already on disk. That is a comparison against the run, not against the clock, so it cannot be
#      widened into uselessness and it fires the instant a cache goes behind. It is what catches the
#      founding bug, and it would have caught it on 2026-07-28.
#   2. CACHE REUSE 6h - strictly narrower than the 24h period ON PURPOSE, so a reused download can only
#      ever come from the same day's export. This is the number the founding bug got wrong (it was
#      infinite), and the one the lesson's inequality applies to: 6 < 24.
#   3. CLOCK FLOOR 30h - a floor on data quality, NOT the freshness proof. It is wider than the period
#      deliberately: a feed legitimately reaches ~24h old every morning just before the next export, so
#      anything at or below the period would go red daily for a correct reason, and a permanently-red
#      light stops being read (the regression-test.ps1 lesson). It only bites when there is no canonical
#      feed to compare against AND the data is old enough to be meaningless - it catches a fully dead
#      daily pipeline by mid-afternoon of the missed day.
#
# ---- HOW AGE IS MEASURED ----------------------------------------------------------------------------
# From the OLDER of the file's mtime and its own `generated` field, because each one alone can be
# laundered in the opposite direction: a Copy-Item / restore refreshes mtime over old data (mtime lies
# young), and git does not preserve mtimes at all; while a re-export over stale inputs stamps a new
# `generated` on unmoved prices (generated lies young - that is run-daily-local.ps1's assert to catch, not
# this one's). Taking the older stamp means a lie in either field cannot buy freshness.
#
# Dot-source:  . (Join-Path $mpPipe 'feed-freshness.ps1')
# Self-test:   powershell -File meal-prep\pipeline\feed-freshness.ps1 -SelfTest
#
# THIS FILE DECLARES NO param() BLOCK, DELIBERATELY - the same trap guard-contract.ps1 carries. In PS 5.1
# dot-sourcing a script runs its param() block in the CALLER's scope, and compute-v2-perserving.ps1 (the
# production caller) has its own [switch]$SelfTest. A param block here would silently reset the caller's
# switch on the line after it bound. Read -SelfTest off $args, and only when RUN.
$__ffSelfTest = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-SelfTest')

$script:FEED_PERIOD_HOURS      = 24    # SMP Grocery Daily Pipeline (local), 08:30 daily
$script:FEED_CACHE_REUSE_HOURS = 6     # < period, so a reused download is same-day by construction
$script:FEED_MAX_AGE_HOURS     = 30    # floor, not proof - see the block comment above
# Derived from THIS file's location (income\meal-prep\pipeline\ -> income\), not hardcoded to C:\Codex.
# A worktree session that resolved the canonical feed to the MAIN tree would be checking one tree's
# freshness while pricing another's - and this estate has already been bitten by paths that silently
# reached across trees. $PSScriptRoot is the dot-sourced file's own directory, which is what we want here.
$script:FEED_ROOT              = if ($PSScriptRoot) { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent } else { 'C:\Codex\income' }
$script:FEED_CANONICAL_PATH    = Join-Path $script:FEED_ROOT 'grocery\out\smp-feed.json'
$script:FEED_CACHE_PATH        = Join-Path $script:FEED_ROOT 'meal-prep\scratch-smpfeed.json'
$script:FEED_URL               = 'https://feed.thriftycrew.com/smp-feed.json'

# Read a feed's two independent timestamps. Returns $null stamps rather than throwing, so an unreadable or
# undated feed reaches the verdict as UNDATED (refused) instead of as an exception the caller swallows -
# "could not evaluate" must never read as "clean".
function Get-FeedStamp {
  param([string]$Path)
  $out = [pscustomobject]@{ path = $Path; exists = $false; mtime = $null; generated = $null }
  if (-not $Path -or -not (Test-Path $Path)) { return $out }
  $out.exists = $true
  try { $out.mtime = (Get-Item $Path).LastWriteTime } catch { }
  try {
    $raw = Get-Content $Path -Raw -Encoding utf8 | ConvertFrom-Json
    if ($raw.PSObject.Properties.Name -contains 'generated' -and $raw.generated) {
      $out.generated = [datetime]::Parse([string]$raw.generated)
    }
  } catch { }
  return $out
}

# PURE. The whole verdict, with every input injected - including $Now and the canonical stamp - so the
# frozen fixtures below are deterministic forever and cannot rot into a false verdict as the calendar moves.
# Verdicts: OK | WARN_AGING | STALE_VS_CANONICAL | STALE_VS_CLOCK | UNDATED
function Test-FeedStaleness {
  param(
    [datetime]$Now,
    $FeedGenerated,           # [datetime] or $null
    $FeedMTime,               # [datetime] or $null
    $CanonicalGenerated,      # [datetime] or $null - the run-tied reference
    [double]$MaxAgeHours = $script:FEED_MAX_AGE_HOURS,
    [double]$PeriodHours = $script:FEED_PERIOD_HOURS
  )
  $stamps = @()
  if ($null -ne $FeedGenerated) { $stamps += [datetime]$FeedGenerated }
  if ($null -ne $FeedMTime)     { $stamps += [datetime]$FeedMTime }
  if ($stamps.Count -eq 0) {
    return [pscustomobject]@{ verdict = 'UNDATED'; age_hours = $null; effective = $null
      reason = 'the feed carries no readable `generated` field and no mtime - its age cannot be established, so it cannot be trusted' }
  }
  # the OLDER stamp governs: a lie in either field must not buy freshness
  $eff = ($stamps | Sort-Object)[0]
  $age = [math]::Round(($Now - $eff).TotalHours, 2)

  # (1) RUN-TIED, no window. 5 minutes of slack absorbs write/copy skew between two files of the same run.
  if ($null -ne $CanonicalGenerated -and $eff -lt ([datetime]$CanonicalGenerated).AddMinutes(-5)) {
    return [pscustomobject]@{ verdict = 'STALE_VS_CANONICAL'; age_hours = $age; effective = $eff
      reason = ("the feed being priced on is dated {0} but the estate's canonical feed on disk is dated {1} - this run would price on data the estate has already replaced" -f $eff.ToString('yyyy-MM-dd HH:mm'), ([datetime]$CanonicalGenerated).ToString('yyyy-MM-dd HH:mm')) }
  }
  # (2) CLOCK FLOOR. Only reachable when there is no canonical feed to compare against, or when the
  # canonical feed IS the stale one (a dead daily pipeline).
  if ($age -gt $MaxAgeHours) {
    return [pscustomobject]@{ verdict = 'STALE_VS_CLOCK'; age_hours = $age; effective = $eff
      reason = ("the feed is {0}h old (dated {1}), past the {2}h floor - the daily export has not landed and these prices are not this week's" -f $age, $eff.ToString('yyyy-MM-dd HH:mm'), $MaxAgeHours) }
  }
  # (3) Aging but legitimate - a feed reaches ~24h every morning before the next export. Visible, not fatal.
  if ($age -gt $PeriodHours) {
    return [pscustomobject]@{ verdict = 'WARN_AGING'; age_hours = $age; effective = $eff
      reason = ("the feed is {0}h old, past its {1}h refresh period but inside the {2}h floor - normal right before an export, worth a look if it persists" -f $age, $PeriodHours, $MaxAgeHours) }
  }
  return [pscustomobject]@{ verdict = 'OK'; age_hours = $age; effective = $eff
    reason = ("feed dated {0}, {1}h old" -f $eff.ToString('yyyy-MM-dd HH:mm'), $age) }
}

# PURE. Which feed a pricing stage should read, and whether it must download first. This is the half that
# fixes the founding bug's ROOT: the canonical feed on disk outranks the private cache, and the cache is
# reused only inside a window narrower than the writer's period - never merely because it exists.
# Returns { path; action = 'use'|'download'; why }.
function Resolve-FeedSource {
  param(
    [string]$Explicit,          # -FeedPath from the caller; wins outright when given
    [bool]$ExplicitExists,
    [string]$CanonicalPath,
    [bool]$CanonicalExists,
    [string]$CachePath,
    $CacheAgeHours,             # [double] or $null when the cache is absent
    [double]$ReuseHours = $script:FEED_CACHE_REUSE_HOURS
  )
  if ($Explicit) {
    # An explicit path is the caller's declared choice and is used as given - but it is NOT exempt from the
    # staleness verdict, which runs on whatever this returns.
    return [pscustomobject]@{ path = $Explicit; action = 'use'
      why = if ($ExplicitExists) { 'caller passed -FeedPath' } else { 'caller passed -FeedPath (missing - the freshness gate will refuse it)' } }
  }
  if ($CanonicalExists) {
    return [pscustomobject]@{ path = $CanonicalPath; action = 'use'
      why = "the estate's canonical feed on disk, written by the daily pipeline" }
  }
  if ($null -ne $CacheAgeHours -and [double]$CacheAgeHours -le $ReuseHours) {
    return [pscustomobject]@{ path = $CachePath; action = 'use'
      why = ("cached download {0}h old, inside the {1}h reuse window" -f [math]::Round([double]$CacheAgeHours, 2), $ReuseHours) }
  }
  return [pscustomobject]@{ path = $CachePath; action = 'download'
    why = if ($null -eq $CacheAgeHours) { 'no canonical feed and no cache - downloading' }
          else { ("no canonical feed and the cache is {0}h old, past the {1}h reuse window - re-downloading" -f [math]::Round([double]$CacheAgeHours, 2), $ReuseHours) } }
}

# The production entry point. Resolves the source, downloads when the rule says to, and returns the
# resolved path plus the verdict. It performs the I/O; the two functions above hold all the judgement, and
# they are what the fixtures pin.
function Resolve-AndCheckFeed {
  param(
    [string]$Explicit = '',
    $Now = $null,
    [string]$CanonicalPath = $script:FEED_CANONICAL_PATH,
    [string]$CachePath = $script:FEED_CACHE_PATH
  )
  if ($null -eq $Now) { $Now = Get-Date }
  $cacheAge = $null
  if (Test-Path $CachePath) { $cacheAge = ($Now - (Get-Item $CachePath).LastWriteTime).TotalHours }
  $src = Resolve-FeedSource -Explicit $Explicit -ExplicitExists ([bool]($Explicit -and (Test-Path $Explicit))) `
           -CanonicalPath $CanonicalPath -CanonicalExists ([bool](Test-Path $CanonicalPath)) `
           -CachePath $CachePath -CacheAgeHours $cacheAge
  if ($src.action -eq 'download') {
    Invoke-WebRequest -Uri $script:FEED_URL -OutFile $src.path -TimeoutSec 40 -UseBasicParsing
  }
  $stamp = Get-FeedStamp -Path $src.path
  # The run-tied reference is the canonical feed - EXCEPT when it IS the file we are about to price on,
  # in which case comparing it to itself proves nothing and the clock floor is the only check left.
  # BOTH Test-Path guards are load-bearing. Resolve-Path THROWS on a path that does not exist, and under
  # $ErrorActionPreference='Stop' in the caller that is terminating - so a caller passing a -FeedPath that
  # is missing used to die here with exit 1 instead of reaching the UNDATED refusal and exiting 2. Measured:
  # the founding snapshot was removed from disk between two runs of this very check, and the guard crashed
  # rather than refusing. A gate that cannot survive its own bad input is not a gate.
  $canonGen = $null
  $isCanonical = $false
  if ((Test-Path $CanonicalPath) -and (Test-Path $src.path)) {
    $isCanonical = ((Resolve-Path $src.path).Path -eq (Resolve-Path $CanonicalPath).Path)
  }
  if ((Test-Path $CanonicalPath) -and -not $isCanonical) {
    $canonGen = (Get-FeedStamp -Path $CanonicalPath).generated
  }
  $verdict = Test-FeedStaleness -Now $Now -FeedGenerated $stamp.generated -FeedMTime $stamp.mtime -CanonicalGenerated $canonGen
  return [pscustomobject]@{ path = $src.path; source_why = $src.why; action = $src.action
    verdict = $verdict.verdict; age_hours = $verdict.age_hours; reason = $verdict.reason }
}

function Test-FeedVerdictFatal { param([string]$Verdict) return @('STALE_VS_CANONICAL','STALE_VS_CLOCK','UNDATED') -contains $Verdict }

# ======================================================================================================
# FIXTURES. Frozen, and every clock injected, so none of them can rot into a false verdict.
# ======================================================================================================
if ($__ffSelfTest) {
  # EAP=Stop FOR THE SUITE ITSELF. Without it a case that cannot RUN (a typo, a renamed function) prints a
  # red error and the loop carries on to a cheerful "SELFTEST: n/n pass" - the case never counted, so
  # nothing was missing from the tally. Measured while writing this file: a malformed case did exactly that
  # and the suite still exited 0. A test that cannot fail out loud is the thing it exists to prevent.
  # test-auditors additionally pins the EXPECTED COUNT, so a case that silently stops running is caught
  # there too even if it never errors.
  $ErrorActionPreference = 'Stop'
  $fx = 'C:\Codex\income\grocery\regression-inputs\guard-fixtures'
  $n = 0; $bad = 0
  function TT($m, $cond, $got) { $script:n++; if ($cond) { Write-Output ("  ok    " + $m) } else { Write-Output ("  FAIL  " + $m + "   got: " + $got); $script:bad++ } }

  # -- THE FOUNDING BUG, frozen. A present-but-stale snapshot, at the exact stamps the real one carried.
  $JUL = [datetime]'2026-07-27T07:13:44'
  $AUG = [datetime]'2026-08-15T09:10:16'
  $NOW = [datetime]'2026-08-15T12:51:00'      # the moment the stale manifest was actually written

  $v = Test-FeedStaleness -Now $NOW -FeedGenerated $JUL -FeedMTime $JUL -CanonicalGenerated $AUG
  TT 'MUST FIRE  the July 27 snapshot, present on disk, is refused against the live feed' `
     ($v.verdict -eq 'STALE_VS_CANONICAL') $v.verdict

  # the same snapshot with NO canonical feed to compare to still cannot pass - the clock floor holds
  $v = Test-FeedStaleness -Now $NOW -FeedGenerated $JUL -FeedMTime $JUL -CanonicalGenerated $null
  TT 'MUST FIRE  the same snapshot is refused on the clock floor when there is no canonical feed' `
     ($v.verdict -eq 'STALE_VS_CLOCK' -and $v.age_hours -gt 450) ("$($v.verdict) age=$($v.age_hours)")

  # mtime laundering: touched today, data still July. This is what defeats an mtime-only check.
  $v = Test-FeedStaleness -Now $NOW -FeedGenerated $JUL -FeedMTime $NOW -CanonicalGenerated $AUG
  TT 'MUST FIRE  a stale feed touched today (fresh mtime, July data) is still refused' `
     ($v.verdict -eq 'STALE_VS_CANONICAL') $v.verdict

  # -- THE CLEAN TWIN. Same shape, same clock, fresh data - must pass, or the guard is just a refuser.
  $v = Test-FeedStaleness -Now $NOW -FeedGenerated $AUG -FeedMTime $AUG -CanonicalGenerated $AUG
  TT 'CLEAN TWIN  that morning''s live feed passes at the same instant' ($v.verdict -eq 'OK') $v.verdict

  # the canonical feed priced against itself (check-ad-cycles' path): equal stamps must not self-refuse
  $v = Test-FeedStaleness -Now $NOW -FeedGenerated $AUG -FeedMTime $AUG -CanonicalGenerated $null
  TT 'CLEAN TWIN  the canonical feed priced against itself passes' ($v.verdict -eq 'OK') $v.verdict

  # PROVE THE RUN-TIED CHECK DOES INDEPENDENT WORK. Every case above is old enough that the clock floor
  # would refuse it anyway, so they cannot tell whether the canonical comparison is live or vacuous. This
  # one is 8h old - comfortably INSIDE the 30h floor, so the clock says fine - while the canonical feed on
  # disk is 1h old. Only the run-tied check can refuse it, and this is the shape a cache goes wrong in
  # long before it is nineteen days old.
  $v = Test-FeedStaleness -Now $AUG.AddHours(9) -FeedGenerated $AUG.AddHours(1) -FeedMTime $AUG.AddHours(1) `
        -CanonicalGenerated $AUG.AddHours(8)
  TT 'MUST FIRE  an 8h cache is refused while a 1h canonical feed exists (the clock alone says OK)' `
     ($v.verdict -eq 'STALE_VS_CANONICAL') $v.verdict

  # -- the boundary the lesson is about: legitimately aging must NOT go red, or the light stops being read
  $v = Test-FeedStaleness -Now $AUG.AddHours(23.5) -FeedGenerated $AUG -FeedMTime $AUG -CanonicalGenerated $null
  TT 'a 23.5h feed the morning before the next export is not refused' ($v.verdict -eq 'OK') $v.verdict
  $v = Test-FeedStaleness -Now $AUG.AddHours(25) -FeedGenerated $AUG -FeedMTime $AUG -CanonicalGenerated $null
  TT 'a 25h feed warns (past period, inside floor) but does not refuse' ($v.verdict -eq 'WARN_AGING') $v.verdict
  $v = Test-FeedStaleness -Now $AUG.AddHours(31) -FeedGenerated $AUG -FeedMTime $AUG -CanonicalGenerated $null
  TT 'MUST FIRE  a 31h feed (a fully missed daily export) is refused' ($v.verdict -eq 'STALE_VS_CLOCK') $v.verdict

  # -- an undated feed is refused, never waved through
  $v = Test-FeedStaleness -Now $NOW -FeedGenerated $null -FeedMTime $null -CanonicalGenerated $AUG
  TT 'MUST FIRE  a feed whose age cannot be established is refused, not assumed fresh' ($v.verdict -eq 'UNDATED') $v.verdict

  # a feed dated a few minutes before canonical (same run, write skew) must not trip the run-tied check
  $v = Test-FeedStaleness -Now $NOW -FeedGenerated $AUG.AddMinutes(-2) -FeedMTime $AUG -CanonicalGenerated $AUG
  TT 'two files from the same export minutes apart do not read as stale' ($v.verdict -eq 'OK') $v.verdict

  # -- RESOLVER: the founding bug's actual code path. "present" must stop meaning "reusable".
  $r = Resolve-FeedSource -Explicit '' -ExplicitExists $false -CanonicalPath 'CANON' -CanonicalExists $false `
        -CachePath 'CACHE' -CacheAgeHours 456
  TT 'MUST FIRE  a 456h-old cache is re-downloaded, not reused because it exists' `
     ($r.action -eq 'download') ("$($r.action) $($r.path)")

  $r = Resolve-FeedSource -Explicit '' -ExplicitExists $false -CanonicalPath 'CANON' -CanonicalExists $true `
        -CachePath 'CACHE' -CacheAgeHours 456
  TT 'MUST FIRE  the canonical feed on disk outranks a stale private cache' `
     ($r.action -eq 'use' -and $r.path -eq 'CANON') ("$($r.action) $($r.path)")

  $r = Resolve-FeedSource -Explicit '' -ExplicitExists $false -CanonicalPath 'CANON' -CanonicalExists $false `
        -CachePath 'CACHE' -CacheAgeHours 2
  TT 'CLEAN TWIN  a 2h-old cache is reused (no canonical feed present)' `
     ($r.action -eq 'use' -and $r.path -eq 'CACHE') ("$($r.action) $($r.path)")

  $r = Resolve-FeedSource -Explicit '' -ExplicitExists $false -CanonicalPath 'CANON' -CanonicalExists $false `
        -CachePath 'CACHE' -CacheAgeHours 7
  TT 'a 7h cache is past the 6h reuse window and re-downloads' ($r.action -eq 'download') $r.action

  $r = Resolve-FeedSource -Explicit 'GIVEN' -ExplicitExists $true -CanonicalPath 'CANON' -CanonicalExists $true `
        -CachePath 'CACHE' -CacheAgeHours 1
  TT 'an explicit -FeedPath still wins (check-ad-cycles passes one)' `
     ($r.action -eq 'use' -and $r.path -eq 'GIVEN') ("$($r.action) $($r.path)")

  $r = Resolve-FeedSource -Explicit '' -ExplicitExists $false -CanonicalPath 'CANON' -CanonicalExists $false `
        -CachePath 'CACHE' -CacheAgeHours $null
  TT 'a missing cache downloads (the one case the old code got right)' ($r.action -eq 'download') $r.action

  # -- END TO END over the two FROZEN FIXTURE FILES. The pure cases above prove the judgement; these prove
  # the file is actually read and dated. Deliberately independent of mtime (git does not preserve it), so
  # the verdict rides the `generated` field a checkout cannot touch.
  $mf = Join-Path $fx 'feedfresh-mustfire.json'
  $cl = Join-Path $fx 'feedfresh-clean.json'
  if ((Test-Path $mf) -and (Test-Path $cl)) {
    $sMf = Get-FeedStamp -Path $mf
    $sCl = Get-FeedStamp -Path $cl
    $vMf = Test-FeedStaleness -Now $NOW -FeedGenerated $sMf.generated -FeedMTime $sMf.mtime -CanonicalGenerated $sCl.generated
    TT 'MUST FIRE  the frozen stale-snapshot fixture FILE is refused' (Test-FeedVerdictFatal $vMf.verdict) $vMf.verdict
    $vCl = Test-FeedStaleness -Now $NOW -FeedGenerated $sCl.generated -FeedMTime $sCl.mtime -CanonicalGenerated $sCl.generated
    TT 'CLEAN TWIN  the frozen fresh-feed fixture FILE passes' ($vCl.verdict -eq 'OK') $vCl.verdict
    TT 'the stale fixture still carries the July 27 stamp it was frozen with' `
       ($sMf.generated -eq $JUL) ([string]$sMf.generated)
  } else {
    TT 'the frozen feed fixtures exist' $false "missing $mf / $cl"
  }

  # -- A MISSING FEED MUST REFUSE, NOT CRASH. Shipped broken and caught end-to-end on 2026-08-15: a caller
  # passing a -FeedPath that does not exist hit Resolve-Path, which throws, and under the caller's
  # EAP='Stop' that exited 1 (read downstream as "skipped recipes") instead of the intended 2. A guard that
  # dies on bad input has not refused anything - it has just failed in a way that looks like a different
  # problem. Drives the REAL I/O entry point, because the bug was in the I/O half, not the judgement.
  $missing = Join-Path $env:TEMP ('ff-nonexistent-' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.json')
  $threw = $false; $res = $null
  try { $res = Resolve-AndCheckFeed -Explicit $missing -Now $NOW } catch { $threw = $true; $res = $_.Exception.Message }
  TT 'MUST FIRE  a -FeedPath that does not exist is REFUSED (UNDATED), never crashes the caller' `
     ((-not $threw) -and $res.verdict -eq 'UNDATED') $(if ($threw) { "threw: $res" } else { $res.verdict })

  # -- the seal: the production caller must still ROUTE THROUGH this file. A guard cannot detect its own
  # unsealing, so assert the precondition in source (the regression-test.ps1 lesson). test-auditors runs
  # this daily, which is what makes this file's only caller not be its own test.
  $prod = 'C:\Codex\income\meal-prep\pipeline\compute-v2-perserving.ps1'
  $src = if (Test-Path $prod) { Get-Content $prod -Raw } else { '' }
  TT 'the production caller dot-sources this file' ($src -match 'feed-freshness\.ps1') 'not dot-sourced'
  TT 'the production caller calls Resolve-AndCheckFeed' ($src -match 'Resolve-AndCheckFeed') 'not called'
  TT 'MUST FIRE  the founding "download only if missing" shape has not come back' `
     ($src -notmatch '(?s)if\s*\(\s*-not\s*\(Test-Path\s+\$FeedPath\s*\)\s*\)\s*\{\s*[^}]*Invoke-WebRequest') 'the download-if-missing branch is back'

  # MUST FIRE, borrowed from lib\guard-contract.ps1's own regression. compute-v2-perserving.ps1 declares
  # [switch]$SelfTest and dot-sources this file; if this file ever grows a colliding param() block, PS 5.1
  # runs it in the CALLER's scope and silently resets that switch to $false on the next line. The header
  # warns about it, which is worth nothing unless something proves it. Out-of-process, because the bug IS
  # scope behaviour.
  $probe = Join-Path $env:TEMP 'ff-clobber-probe.ps1'
  ("param([switch]`$SelfTest)`r`n. '" + $PSCommandPath + "'`r`nWrite-Output ('SelfTest=' + `$SelfTest)") |
    Set-Content $probe -Encoding UTF8
  $probeOut = ((& powershell -NoProfile -ExecutionPolicy Bypass -File $probe -SelfTest 2>&1 |
                 ForEach-Object { [string]$_ }) -join ' ').Trim()
  Remove-Item $probe -Force -ErrorAction SilentlyContinue
  TT 'MUST FIRE  dot-sourcing this must not clobber the caller''s own -SelfTest switch' `
     ($probeOut -match 'SelfTest=True') $probeOut

  if ($bad -eq 0) { Write-Output ("SELFTEST: {0}/{0} pass" -f $n); exit 0 }
  Write-Output ("SELFTEST: {0}/{1} pass - {2} FAILED" -f ($n - $bad), $n, $bad); exit 1
}
