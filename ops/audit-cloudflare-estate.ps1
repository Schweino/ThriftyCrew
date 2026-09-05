<#
  audit-cloudflare-estate.ps1 - the Cloudflare estate is CODE too. Declare it, and prove live still matches.

  WHY (2026-08-20). Four R2 buckets, a 4GB D1 database and three Workers were created 2026-08-09/10 by the
  V3 platform estate. V3's code was deleted from this repo on 2026-08-14 (commit f5e187a0). Its RUNTIME was
  not deleted, and nothing in this tree referenced any of it - not a bucket name, not a binding, not a
  lifecycle rule. wrangler.jsonc describes only smp-feed. So for eleven days the estate had infrastructure
  that no file in git described, no gate checked, and no one could diff.

  It cost money in exactly the way you would expect. Nine lifecycle rules quietly moved objects into R2's
  Infrequent Access class. R2 bills operations per WHOLE MILLION with no proration and IA has no free tier,
  so the 499 transitions that fired on 2026-08-19 bought a full $9.00 block - about 95% of the entire
  Cloudflare bill, to save roughly six cents of storage. Nobody could have caught that by reading the repo,
  because the repo did not know the buckets existed.

  This gate closes that. ops\cloudflare-estate.json is the declared state; this script reads live and
  reports drift. The check that matters most is the cheapest one: ANY InfrequentAccess transition, on any
  bucket, is a failure. It is one $9.00 block per cycle regardless of volume, so a single stray rule
  anywhere costs the whole $9.00 - there is no such thing as a small IA regression.

  It also watches the one D1 limit that is actually close: storage, at ~81% of the 5GB included allowance.
  Rows are not close and reads are nowhere near.

  CRON TRIGGERS, added 2026-08-25. The first version of this gate could describe buckets and a database
  but not the one thing that was actually EXECUTING. tc-grocery-v3 carried a '*/15 * * * *' trigger that
  outlived the deletion of its own code on 2026-08-14 and went on running scheduled stages - and emailing
  Brad through smp-feed's /ops-alert every time D1 evicted its connection mid-stage - for eleven days.
  It also flattered its own request count enough to be recorded here as "the busiest worker on the
  account": 725 invocations in the 7 days to 08-25, of which ~672 were the cron at 96/day. Every worker
  now declares a crons[] list, and a live schedule matching no declaration is drift.

  Needs CLOUDFLARE_API_TOKEN (Account.R2:read, Account.D1:read, Account.Workers Scripts:read). Without it
  the script reports BLIND and exits 3 rather than passing - a check that cannot see is not a check that
  passed, which is the standing rule for every guard in this estate. That applies per-signal: if the token
  reads R2 but cannot read schedules, this reports BLIND rather than a clean estate.

  Exit 0 = live matches declared. 2 = drift. 3 = BLIND (no token, or the API would not answer).
  -SelfTest runs frozen fixtures offline (must-fire bugs plus their clean twin) and needs no token.
  -CompareFile <path> audits a captured snapshot instead of calling the API - the shape is
  { "bucket-name": [ <rule>, ... ], "_d1SizeGB": 4.03 }, exactly what the lifecycle endpoint returns.
  Useful when the only credential available is a browser session rather than an API token.
#>
param([switch]$SelfTest, [switch]$Quiet, [string]$CompareFile)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\ops' }
# A detector that runs in the chain must be able to PROVE it ran to the end, or a crash halfway reads as a
# pass. Same helper, same contract as opsudit-prompt-backup.ps1. Deliberately NOT emitted on the BLIND
# path: exit 3 means it evaluated nothing, and a completion marker there would vouch for an examination
# that never happened.
. (Join-Path (Split-Path $here -Parent) 'lib\guard-contract.ps1')
$declaredPath = Join-Path $here 'cloudflare-estate.json'

# ---------------------------------------------------------------------------------------------------
# The comparison itself. Pure: declared object + live object -> list of findings. No network, no globals,
# so -SelfTest can drive it against frozen fixtures.
# ---------------------------------------------------------------------------------------------------
function Get-EstateDrift {
  param($Declared, $LiveLifecycle, $LiveD1SizeGB, $LiveCrons)
  $findings = New-Object System.Collections.ArrayList

  foreach ($bp in $Declared.buckets.PSObject.Properties) {
    $bucket = $bp.Name
    $want   = $bp.Value
    if (-not $LiveLifecycle.ContainsKey($bucket)) {
      [void]$findings.Add("MISSING BUCKET: $bucket is declared but not present live")
      continue
    }
    $liveRules = @($LiveLifecycle[$bucket])

    # THE check. Any IA transition anywhere is a $9.00/cycle regression on its own.
    foreach ($lr in $liveRules) {
      if ($lr.storageClassTransitions -and @($lr.storageClassTransitions).Count -gt 0) {
        [void]$findings.Add("INFREQUENT ACCESS: $bucket/'$($lr.id)' has a storageClassTransition - that is a full `$9.00 Class A block per cycle. See policy.infrequentAccessWhy.")
      }
    }

    $liveById = @{}
    foreach ($lr in $liveRules) { $liveById[[string]$lr.id] = $lr }

    foreach ($wr in @($want.rules)) {
      $live = $liveById[[string]$wr.id]
      if (-not $live) {
        [void]$findings.Add("MISSING RULE: $bucket/'$($wr.id)' is declared but not live")
        continue
      }
      if ([bool]$live.enabled -ne [bool]$wr.enabled) {
        [void]$findings.Add("ENABLED DRIFT: $bucket/'$($wr.id)' live=$($live.enabled) declared=$($wr.enabled)")
      }
      # retention is the dangerous field - a shortened delete rule destroys data early, a lengthened
      # one silently grows the bill. Compare it exactly, in days.
      if ($null -ne $wr.deleteAfterDays) {
        $liveDays = $null
        if ($live.deleteObjectsTransition -and $live.deleteObjectsTransition.condition) {
          $liveDays = [math]::Round($live.deleteObjectsTransition.condition.maxAge / 86400, 4)
        }
        if ($null -eq $liveDays) {
          [void]$findings.Add("RETENTION LOST: $bucket/'$($wr.id)' should delete after $($wr.deleteAfterDays)d, live has no delete transition")
        } elseif ([double]$liveDays -ne [double]$wr.deleteAfterDays) {
          [void]$findings.Add("RETENTION DRIFT: $bucket/'$($wr.id)' live=${liveDays}d declared=$($wr.deleteAfterDays)d")
        }
      }
      if ($null -ne $wr.abortMultipartAfterDays) {
        $liveAbort = $null
        if ($live.abortMultipartUploadsTransition -and $live.abortMultipartUploadsTransition.condition) {
          $liveAbort = [math]::Round($live.abortMultipartUploadsTransition.condition.maxAge / 86400, 4)
        }
        if ($null -eq $liveAbort -or [double]$liveAbort -ne [double]$wr.abortMultipartAfterDays) {
          [void]$findings.Add("ABORT-MPU DRIFT: $bucket/'$($wr.id)' live=$liveAbort declared=$($wr.abortMultipartAfterDays)d")
        }
      }
    }

    # a rule that appeared live but is in no declaration is how the last one arrived
    foreach ($lr in $liveRules) {
      $known = $false
      foreach ($wr in @($want.rules)) { if ([string]$wr.id -eq [string]$lr.id) { $known = $true; break } }
      if (-not $known) { [void]$findings.Add("UNDECLARED RULE: $bucket/'$($lr.id)' exists live but is in no declaration") }
    }
  }

  # Cron triggers. $LiveCrons is a hashtable of scriptName -> string[] of cron expressions. $null means
  # this run did not gather them (snapshot mode), and a signal that was not gathered is not compared -
  # the live path refuses to run at all rather than pass blind, so silence here can only mean snapshot.
  if ($null -ne $LiveCrons -and $Declared.workers) {
    foreach ($wp in $Declared.workers.PSObject.Properties) {
      $script = $wp.Name
      # a worker with no crons key declares NO schedule; that default is what makes a new trigger fire
      $want = @()
      if ($null -ne $wp.Value.crons) { $want = @($wp.Value.crons | ForEach-Object { [string]$_ }) }
      if (-not $LiveCrons.ContainsKey($script)) {
        [void]$findings.Add("CRONS UNREAD: $script - live schedules were not read, so its triggers are unverified")
        continue
      }
      $live = @($LiveCrons[$script] | ForEach-Object { [string]$_ })
      foreach ($lc in $live) {
        if ($want -notcontains $lc) {
          [void]$findings.Add("UNDECLARED CRON: $script runs '$lc' but declares no such schedule - something is EXECUTING that this repo does not describe. See _cronsComment.")
        }
      }
      foreach ($wc in $want) {
        if ($live -notcontains $wc) {
          [void]$findings.Add("MISSING CRON: $script declares '$wc' but it is not live - a schedule this repo relies on is not running")
        }
      }
    }
  }

  if ($null -ne $LiveD1SizeGB) {
    foreach ($dp in $Declared.d1.PSObject.Properties) {
      $warn = [double]$dp.Value.warnAtGB
      $inc  = [double]$dp.Value.includedStorageGB
      if ([double]$LiveD1SizeGB -ge $inc) {
        [void]$findings.Add("D1 OVER ALLOWANCE: $($dp.Name) at ${LiveD1SizeGB}GB, past the ${inc}GB included - billing at `$0.75/GB-month")
      } elseif ([double]$LiveD1SizeGB -ge $warn) {
        [void]$findings.Add("D1 APPROACHING LIMIT: $($dp.Name) at ${LiveD1SizeGB}GB of ${inc}GB included (warn ${warn}GB)")
      }
    }
  }
  return $findings
}

# ---------------------------------------------------------------------------------------------------
# Self-test: frozen fixtures of the founding bug and its clean twin. No token, no network.
# ---------------------------------------------------------------------------------------------------
if ($SelfTest) {
  $declared = @'
{ "buckets": { "b1": { "rules": [
      { "id": "keep", "enabled": true, "prefix": "x/", "deleteAfterDays": 45 },
      { "id": "mpu",  "enabled": true, "prefix": null, "abortMultipartAfterDays": 7 } ] } },
  "d1": { "db1": { "includedStorageGB": 5, "warnAtGB": 4.5 } },
  "workers": { "w-quiet": { "crons": [] }, "w-scheduled": { "crons": ["0 6 * * *"] } } }
'@ | ConvertFrom-Json

  # the estate as declared: one worker deliberately silent, one deliberately scheduled
  $cleanCrons = @{ 'w-quiet' = @(); 'w-scheduled' = @('0 6 * * *') }

  $cleanLive = @{ b1 = @(
    [pscustomobject]@{ id='keep'; enabled=$true; deleteObjectsTransition=[pscustomobject]@{ condition=[pscustomobject]@{ maxAge=3888000 } } },
    [pscustomobject]@{ id='mpu';  enabled=$true; abortMultipartUploadsTransition=[pscustomobject]@{ condition=[pscustomobject]@{ maxAge=604800 } } } ) }

  $fail = 0
  # CLEAN TWIN - must find nothing, or every finding below is meaningless. Carries the cron signal too:
  # a declared-empty worker and a declared-scheduled one, both matching live.
  $r = Get-EstateDrift -Declared $declared -LiveLifecycle $cleanLive -LiveD1SizeGB 4.0 -LiveCrons $cleanCrons
  if ($r.Count -ne 0) { Write-Output "  FAIL clean twin produced $($r.Count) finding(s): $($r -join '; ')"; $fail++ }
  else { Write-Output "  ok   clean twin is silent" }

  # MUST FIRE 1 - the founding bug: an IA transition reappears
  $iaLive = @{ b1 = @(
    [pscustomobject]@{ id='keep'; enabled=$true; deleteObjectsTransition=[pscustomobject]@{ condition=[pscustomobject]@{ maxAge=3888000 } };
                       storageClassTransitions=@([pscustomobject]@{ storageClass='InfrequentAccess'; condition=[pscustomobject]@{ maxAge=604800 } }) },
    [pscustomobject]@{ id='mpu';  enabled=$true; abortMultipartUploadsTransition=[pscustomobject]@{ condition=[pscustomobject]@{ maxAge=604800 } } } ) }
  $r = Get-EstateDrift -Declared $declared -LiveLifecycle $iaLive -LiveD1SizeGB 4.0
  if (-not ($r -match 'INFREQUENT ACCESS')) { Write-Output '  FAIL IA transition was not detected'; $fail++ }
  else { Write-Output '  ok   IA transition fires' }

  # MUST FIRE 2 - retention shortened (this one would destroy data, not just cost money)
  $shortLive = @{ b1 = @(
    [pscustomobject]@{ id='keep'; enabled=$true; deleteObjectsTransition=[pscustomobject]@{ condition=[pscustomobject]@{ maxAge=86400 } } },
    [pscustomobject]@{ id='mpu';  enabled=$true; abortMultipartUploadsTransition=[pscustomobject]@{ condition=[pscustomobject]@{ maxAge=604800 } } } ) }
  $r = Get-EstateDrift -Declared $declared -LiveLifecycle $shortLive -LiveD1SizeGB 4.0
  if (-not ($r -match 'RETENTION DRIFT')) { Write-Output '  FAIL shortened retention was not detected'; $fail++ }
  else { Write-Output '  ok   shortened retention fires' }

  # MUST FIRE 3 - a rule vanishes entirely
  $goneLive = @{ b1 = @(
    [pscustomobject]@{ id='mpu'; enabled=$true; abortMultipartUploadsTransition=[pscustomobject]@{ condition=[pscustomobject]@{ maxAge=604800 } } } ) }
  $r = Get-EstateDrift -Declared $declared -LiveLifecycle $goneLive -LiveD1SizeGB 4.0
  if (-not ($r -match 'MISSING RULE')) { Write-Output '  FAIL deleted rule was not detected'; $fail++ }
  else { Write-Output '  ok   deleted rule fires' }

  # MUST FIRE 4 - an undeclared rule appears (how the IA rules got here in the first place)
  $extraLive = @{ b1 = @(
    [pscustomobject]@{ id='keep'; enabled=$true; deleteObjectsTransition=[pscustomobject]@{ condition=[pscustomobject]@{ maxAge=3888000 } } },
    [pscustomobject]@{ id='mpu';  enabled=$true; abortMultipartUploadsTransition=[pscustomobject]@{ condition=[pscustomobject]@{ maxAge=604800 } } },
    [pscustomobject]@{ id='surprise'; enabled=$true; deleteObjectsTransition=[pscustomobject]@{ condition=[pscustomobject]@{ maxAge=86400 } } } ) }
  $r = Get-EstateDrift -Declared $declared -LiveLifecycle $extraLive -LiveD1SizeGB 4.0
  if (-not ($r -match 'UNDECLARED RULE')) { Write-Output '  FAIL undeclared rule was not detected'; $fail++ }
  else { Write-Output '  ok   undeclared rule fires' }

  # MUST FIRE 5 - D1 crosses its included allowance
  $r = Get-EstateDrift -Declared $declared -LiveLifecycle $cleanLive -LiveD1SizeGB 5.2
  if (-not ($r -match 'D1 OVER ALLOWANCE')) { Write-Output '  FAIL D1 overage was not detected'; $fail++ }
  else { Write-Output '  ok   D1 overage fires' }

  # MUST FIRE 6 - THE FOUNDING CRON BUG, frozen. A worker that declares no schedule is found running one.
  # This is tc-grocery-v3's '*/15' exactly: code deleted 2026-08-14, trigger still executing on 2026-08-25.
  $cronLive = @{ 'w-quiet' = @('*/15 * * * *'); 'w-scheduled' = @('0 6 * * *') }
  $r = Get-EstateDrift -Declared $declared -LiveLifecycle $cleanLive -LiveD1SizeGB 4.0 -LiveCrons $cronLive
  if (-not ($r -match 'UNDECLARED CRON')) { Write-Output '  FAIL an undeclared cron was not detected'; $fail++ }
  else { Write-Output '  ok   undeclared cron fires' }

  # MUST FIRE 7 - the opposite failure: a schedule this repo RELIES on has stopped existing. Silent, and
  # invisible in output, because nothing failing is exactly what a dead scheduler looks like.
  $cronGone = @{ 'w-quiet' = @(); 'w-scheduled' = @() }
  $r = Get-EstateDrift -Declared $declared -LiveLifecycle $cleanLive -LiveD1SizeGB 4.0 -LiveCrons $cronGone
  if (-not ($r -match 'MISSING CRON')) { Write-Output '  FAIL a vanished declared cron was not detected'; $fail++ }
  else { Write-Output '  ok   vanished declared cron fires' }

  # CLEAN TWIN 2 - the signal simply was not gathered (snapshot mode). Must stay silent rather than
  # inventing drift; the live path refuses to run blind, so absence here can only mean "not applicable".
  $r = Get-EstateDrift -Declared $declared -LiveLifecycle $cleanLive -LiveD1SizeGB 4.0 -LiveCrons $null
  if ($r.Count -ne 0) { Write-Output "  FAIL ungathered crons invented $($r.Count) finding(s)"; $fail++ }
  else { Write-Output '  ok   ungathered cron signal stays silent' }

  if ($fail) { Write-Output "SELFTEST FAILED ($fail)"; exit 2 }
  Write-Output 'SELFTEST OK (9 fixtures)'
  exit 0
}

# ---------------------------------------------------------------------------------------------------
# Live run
# ---------------------------------------------------------------------------------------------------
if (-not (Test-Path $declaredPath)) { Write-Output "BLIND: no declaration at $declaredPath"; exit 3 }
$declared = Read-JsonFile $declaredPath

if ($CompareFile) {
  if (-not (Test-Path $CompareFile)) { Write-Output "BLIND: snapshot not found at $CompareFile"; exit 3 }
  $snap = Read-JsonFile $CompareFile
  $live = @{}
  $snapD1 = $null
  foreach ($p in $snap.PSObject.Properties) {
    if ($p.Name -eq '_d1SizeGB') { $snapD1 = $p.Value; continue }
    $live[$p.Name] = @($p.Value)
  }
  $findings = Get-EstateDrift -Declared $declared -LiveLifecycle $live -LiveD1SizeGB $snapD1
  if (-not $Quiet) {
    Write-Output "Cloudflare estate audit - SNAPSHOT $CompareFile"
    Write-Output ("  buckets checked : {0}" -f $live.Keys.Count)
    if ($null -ne $snapD1) { Write-Output ("  D1 size         : {0}GB" -f $snapD1) }
  }
  if ($findings.Count -eq 0) { Write-Output 'CLEAN: snapshot matches ops\cloudflare-estate.json'; Write-GuardComplete -Name 'cloudflare-estate' -Summary 'snapshot findings=0'; exit 0 }
  foreach ($f in $findings) { Write-Output "  DRIFT  $f" }
  Write-Output "DRIFT: $($findings.Count) finding(s)"
Write-GuardComplete -Name 'cloudflare-estate' -Summary "findings=$($findings.Count)"
  exit 2
}

$token = $env:CLOUDFLARE_API_TOKEN
if ([string]::IsNullOrWhiteSpace($token)) {
  Write-Output 'BLIND: CLOUDFLARE_API_TOKEN not set - cannot read live state, so this reports nothing rather than a false pass.'
  exit 3
}
$acct = $declared.accountId
$hdr  = @{ Authorization = "Bearer $token" }
$base = "https://api.cloudflare.com/client/v4/accounts/$acct"

$live = @{}
foreach ($bp in $declared.buckets.PSObject.Properties) {
  try {
    $resp = Invoke-RestMethod -Uri "$base/r2/buckets/$($bp.Name)/lifecycle" -Headers $hdr -Method GET
    $live[$bp.Name] = @($resp.result.rules)
  } catch {
    Write-Output "BLIND: could not read lifecycle for $($bp.Name) - $($_.Exception.Message)"
    exit 3
  }
}

$d1GB = $null
try {
  $d1 = Invoke-RestMethod -Uri "$base/d1/database?per_page=100" -Headers $hdr -Method GET
  foreach ($dp in $declared.d1.PSObject.Properties) {
    $match = @($d1.result) | Where-Object { $_.uuid -eq $dp.Value.databaseId }
    if ($match -and $null -ne $match[0].file_size) { $d1GB = [math]::Round($match[0].file_size / 1e9, 3) }
  }
} catch { $d1GB = $null }   # D1 unreadable is not fatal; the R2 checks still mean something

# Cron triggers. Unlike D1 size, an unreadable schedule is NOT survivable: the whole reason this section
# exists is that a trigger nobody could see kept executing for eleven days. Reporting a clean estate while
# unable to see what runs on it would rebuild exactly that blind spot, so this exits 3 instead.
$liveCrons = @{}
if ($declared.workers) {
  foreach ($wp in $declared.workers.PSObject.Properties) {
    try {
      $resp = Invoke-RestMethod -Uri "$base/workers/scripts/$($wp.Name)/schedules" -Headers $hdr -Method GET
      $liveCrons[$wp.Name] = @(@($resp.result.schedules) | ForEach-Object { [string]$_.cron } | Where-Object { $_ })
    } catch {
      Write-Output "BLIND: could not read cron triggers for $($wp.Name) - $($_.Exception.Message)"
      Write-Output '       the token needs Account -> Workers Scripts -> Read. Reporting BLIND rather than a clean estate.'
      exit 3
    }
  }
} else { $liveCrons = $null }

$findings = Get-EstateDrift -Declared $declared -LiveLifecycle $live -LiveD1SizeGB $d1GB -LiveCrons $liveCrons

if (-not $Quiet) {
  Write-Output "Cloudflare estate audit - account $acct"
  Write-Output ("  buckets checked : {0}" -f $live.Keys.Count)
  if ($null -ne $d1GB) { Write-Output ("  D1 size         : {0}GB" -f $d1GB) } else { Write-Output '  D1 size         : unread' }
  if ($null -ne $liveCrons) {
    $cronTotal = 0; foreach ($k in $liveCrons.Keys) { $cronTotal += @($liveCrons[$k]).Count }
    Write-Output ("  workers/crons   : {0} worker(s), {1} live trigger(s)" -f $liveCrons.Keys.Count, $cronTotal)
  }
}
if ($findings.Count -eq 0) { Write-Output 'CLEAN: live matches ops\cloudflare-estate.json'; Write-GuardComplete -Name 'cloudflare-estate' -Summary 'live findings=0'; exit 0 }
foreach ($f in $findings) { Write-Output "  DRIFT  $f" }
Write-Output "DRIFT: $($findings.Count) finding(s)"
Write-GuardComplete -Name 'cloudflare-estate' -Summary "findings=$($findings.Count)"
exit 2
