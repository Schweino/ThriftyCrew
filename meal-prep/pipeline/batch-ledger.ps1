# batch-ledger.ps1 - a recipe batch is a TRANSACTION, not a to-do list held in one session's head.
#
# WHY THIS EXISTS (2026-08-07). The 29-burrito batch's stage 8 - the independent post-publish review that
# runs AFTER everything claims to be done - was interrupted before it reported, and NOTHING NOTICED.
# 29 pages went live unverified and the only reason it surfaced was a stray notification hours later.
# Every other stage had the same hole: the process lived in a playbook and in a session's memory, so an
# unfinished batch was indistinguishable from a finished one the moment the session ended.
#
# The estate already invented the cure on the grocery side (proof tied to the run, expected-automations
# paging on a missing task, test-proof-freshness). This applies it to recipe batches:
#   * a stage is stamped only AFTER it completes, never before  (checkpoint-before-durable lesson)
#   * the stamp records WHAT was done, so it cannot alibi a different run
#   * an open batch older than -MaxAgeHours is a finding, not silence
#
# Usage:
#   .\batch-ledger.ps1 -Start -Batch burrito-2026-08-07 -Slugs a,b,c
#   .\batch-ledger.ps1 -Stamp -Batch burrito-2026-08-07 -Stage publish -Detail '29/29 verified'
#   .\batch-ledger.ps1 -Close -Batch burrito-2026-08-07 -Detail 'stage 8 GO'
#   .\batch-ledger.ps1 -Verify                 (exit 1 if any open batch is stale or missing a stage)
#   .\batch-ledger.ps1 -SelfTest
param(
  [switch]$Start,[switch]$Stamp,[switch]$Close,[switch]$Verify,[switch]$SelfTest,
  [string]$Batch,[string[]]$Slugs,[string]$Stage,[string]$Detail,
  [int]$MaxAgeHours = 24,
  [string]$LedgerPath
)
$ErrorActionPreference='Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$mp   = Split-Path -Parent $here
if(-not $LedgerPath){ $LedgerPath = Join-Path $mp 'db\batch-ledger.json' }

# every stage a batch must pass through. Stage 8 is in the list precisely because it is the one that
# silently did not run.
$script:REQUIRED = @('select','map','write','build-specs','audit','recipes-db','build-cards','publish','post-publish-review')

function Test-BatchComplete { param($Batch)
  $have = @($Batch.stages | ForEach-Object { [string]$_.stage })
  return @($script:REQUIRED | Where-Object { $have -notcontains $_ })
}
function Test-BatchStale { param($Batch,[datetime]$Now,[int]$MaxAgeHours)
  if($Batch.closed){ return $false }
  $last = [datetime]$Batch.last_activity
  return (($Now - $last).TotalHours -gt $MaxAgeHours)
}

# A last_activity AHEAD of now is corrupt, and it is the one value that makes Test-BatchStale unable to fire:
# elapsed hours go negative and can never exceed the limit, so the batch is exempt for as long as the stamp
# stays in the future. Clamping it to now is NOT the fix - that just makes it silently "fresh", which is the
# same exemption wearing a different hat. It has to be its own finding.
function Test-FutureStamp { param($Batch,[datetime]$Now)
  if(-not $Batch.last_activity){ return $false }
  return ([datetime]$Batch.last_activity -gt $Now.AddMinutes(5))   # 5 min of clock slop
}

# A CLOSED batch is not automatically a finished one. -Verify used to `continue` on every closed row, so the
# founding bug - closing a batch whose post-publish review never ran - became invisible the instant someone
# closed it. Closing is a claim; this is the check on the claim.
function Test-ClosedIncomplete { param($Batch)
  if(-not $Batch.closed){ return @() }
  return (Test-BatchComplete $Batch)
}

if($SelfTest){
  $f=0
  function T($m,$c,$g){ if($c){ Write-Output ("ok    "+$m) } else { Write-Output ("FAIL  "+$m+"   got: "+$g); $script:f++ } }
  $now = [datetime]'2026-08-08T09:00:00'
  # FROZEN FIXTURE: the real burrito batch as it stood when the session ended - everything done through
  # publish, stage 8 interrupted and never stamped. This must be reported, not read as finished.
  $interrupted = [pscustomobject]@{ closed=$false; last_activity='2026-08-07T06:40:00'
    stages=@(@{stage='select'},@{stage='map'},@{stage='write'},@{stage='build-specs'},@{stage='audit'},@{stage='recipes-db'},@{stage='build-cards'},@{stage='publish'}) }
  T 'MUST FIRE  a batch that published but never stamped the post-publish review' ((Test-BatchComplete $interrupted) -contains 'post-publish-review') 'not reported'
  T 'MUST FIRE  an open batch idle past the age limit'                            (Test-BatchStale $interrupted $now 24) 'not stale'
  $done = [pscustomobject]@{ closed=$true; last_activity='2026-08-07T06:40:00'
    stages=@($script:REQUIRED | ForEach-Object { @{stage=$_} }) }
  T 'CLEAN TWIN a batch with every stage stamped'                                 ((Test-BatchComplete $done).Count -eq 0) 'spurious finding'
  T 'CLEAN TWIN a CLOSED batch is never stale, however old'                       (-not (Test-BatchStale $done $now 24)) 'spurious finding'
  $fresh = [pscustomobject]@{ closed=$false; last_activity=$now.AddHours(-2).ToString('s'); stages=@(@{stage='select'}) }
  T 'CLEAN TWIN an open batch still inside the window is not yet a finding'       (-not (Test-BatchStale $fresh $now 24)) 'spurious finding'
  T 'MUST FIRE  that same young batch is still INCOMPLETE'                        ((Test-BatchComplete $fresh).Count -gt 0) 'not reported'

  # FROZEN FIXTURE: the founding bug AFTER someone closes it. -Verify used to `continue` on every closed row,
  # so closing an unfinished batch made it permanently invisible - the one action most likely to happen when
  # a session ends and somebody tidies up.
  $closedBad = [pscustomobject]@{ closed=$true; closed_at='2026-08-07T14:00:00'; last_activity='2026-08-07T14:00:00'
    stages=@(@{stage='select'},@{stage='map'},@{stage='write'},@{stage='build-specs'},@{stage='audit'},@{stage='recipes-db'},@{stage='build-cards'},@{stage='publish'}) }
  T 'MUST FIRE  a batch CLOSED while the post-publish review was never stamped'   ((Test-ClosedIncomplete $closedBad) -contains 'post-publish-review') 'invisible once closed'
  T 'CLEAN TWIN a properly closed batch reports nothing'                          ((Test-ClosedIncomplete $done).Count -eq 0) 'spurious finding'

  # FROZEN FIXTURE: a last_activity in the FUTURE. Test-BatchStale structurally CANNOT fire on it (negative
  # elapsed), so it is exempt for as long as the stamp stays ahead - the gates-that-can-never-arm class.
  $future = [pscustomobject]@{ closed=$false; last_activity=$now.AddDays(30).ToString('s'); stages=@(@{stage='select'}) }
  T 'MUST FIRE  a future-dated last_activity is reported as corrupt'              (Test-FutureStamp $future $now) 'exempt forever, silently'
  T 'the staleness test genuinely cannot catch it (which is WHY the check above exists)' `
    (-not (Test-BatchStale $future $now 24)) 'staleness caught it after all'
  T 'CLEAN TWIN an ordinary past stamp is not called corrupt'                     (-not (Test-FutureStamp $interrupted $now)) 'spurious finding'

  if($f -eq 0){ Write-Output 'SELF-TEST PASS'; exit 0 } else { Write-Output "SELF-TEST FAIL: $f case(s)"; exit 1 }
}

# Use the estate's own array IO. Rolling my own here failed immediately on the PS5.1 single-element
# collapse: a one-row ledger round-tripped to something -Stamp could not find, so the very first stamp
# reported "no ledger row - run -Start first" on a ledger it had just written. lib\json-db-io.ps1 exists
# to defeat exactly that (top-level array always, wrap + 1-element-collapse handled on read).
. (Join-Path $mp 'lib\json-db-io.ps1')
$ledger = @()
if(Test-Path $LedgerPath){ $ledger = @(Read-JsonArrayFile -Path $LedgerPath) }
function Save-Ledger($rows){ Save-JsonArray -Array $rows -Path $LedgerPath -Depth 8 | Out-Null }
$now = (Get-Date).ToString('s')

if($Start){
  if(-not $Batch){ throw '-Batch required' }
  if(@($ledger | Where-Object { $_.batch -eq $Batch }).Count){ throw "batch '$Batch' already exists" }
  # the FULL shape up front, including the fields only -Close sets: PowerShell cannot assign a property a
  # PSCustomObject does not already have, so a row created without them throws on close.
  $ledger += [pscustomobject]@{ batch=$Batch; opened=$now; last_activity=$now; closed=$false
                                closed_at=$null; close_detail=$null; slugs=@($Slugs); stages=@() }
  Save-Ledger $ledger
  Write-Output ("ledger opened: {0} ({1} slug(s))" -f $Batch, @($Slugs).Count); exit 0
}
if($Stamp -or $Close){
  if(-not $Batch){ throw '-Batch required' }
  $row = $ledger | Where-Object { $_.batch -eq $Batch } | Select-Object -First 1
  if(-not $row){ throw "no ledger row for '$Batch' - run -Start first" }
  if($Stamp){
    if(-not $Stage){ throw '-Stage required' }
    # stamped AFTER the work, with what it did: a stamp written before the work turns a failure into a
    # silently-skipped stage (the checkpoint-before-durable lesson)
    $row.stages = @($row.stages) + @([pscustomobject]@{ stage=$Stage; at=$now; detail=[string]$Detail })
  }
  if($Close){ $row.closed = $true; $row.closed_at = $now; if($Detail){ $row.close_detail = $Detail } }
  $row.last_activity = $now
  Save-Ledger $ledger
  Write-Output ("{0}: {1}{2}" -f $Batch, $(if($Close){'CLOSED'}else{"stamped '$Stage'"}), $(if($Detail){" - $Detail"}else{''}))
  $miss = Test-BatchComplete $row
  # EXIT 1, not 0. This printed a WARNING and returned success, so a caller (or a human reading rc) could not
  # tell "batch finished" from "batch closed with the post-publish review never run" - which is the exact
  # failure this ledger was built for. The close still LANDS: refusing it would leave the batch open and
  # double-count as stale. It just stops reporting success it does not have.
  if($Close -and $miss.Count){
    Write-Output ("  WARNING closed with unstamped stage(s): " + ($miss -join ', '))
    Write-Output '  (recorded, but this is NOT a clean close - -Verify will keep reporting it)'
    exit 1
  }
  exit 0
}
if($Verify){
  $now2 = Get-Date; $findings = @()
  foreach($b in $ledger){
    if($b.closed){
      # a closed batch still owes an answer if it was closed with stages unstamped
      $ci = Test-ClosedIncomplete $b
      if($ci.Count){ $findings += ("CLOSED INCOMPLETE: batch '{0}' was closed on {1} without ever stamping: {2}" -f $b.batch, $b.closed_at, ($ci -join ', ')) }
      continue
    }
    $miss = Test-BatchComplete $b
    if(Test-FutureStamp $b $now2){
      $findings += ("FUTURE STAMP: batch '{0}' claims last_activity {1}, which is ahead of now - the staleness check cannot fire on it, so it is exempt until that time passes. Missing: {2}" -f $b.batch, $b.last_activity, ($miss -join ', '))
    }
    elseif(Test-BatchStale $b $now2 $MaxAgeHours){
      $findings += ("OPEN+STALE: batch '{0}' last touched {1} ({2}h ago), missing: {3}" -f $b.batch, $b.last_activity, [int]($now2-[datetime]$b.last_activity).TotalHours, ($miss -join ', '))
    } elseif($miss.Count){
      Write-Output ("  in flight: '{0}' still owes {1}" -f $b.batch, ($miss -join ', '))
    }
  }
  if($findings.Count){ Write-Output ("batch-ledger: {0} unfinished batch(es)" -f $findings.Count); $findings | ForEach-Object { Write-Output ("  ! " + $_) }; exit 1 }
  Write-Output 'batch-ledger: no stalled batches'; exit 0
}
Write-Output 'nothing to do - pass -Start, -Stamp, -Close, -Verify or -SelfTest'
