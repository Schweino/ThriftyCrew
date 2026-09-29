<#
  queue-depth.ps1 - how much work is waiting, and how long it has waited.

  WHY THIS EXISTS (2026-09-07, PLAN-drain-architecture). On 2026-09-02 `propagate-recipes.ps1` last
  ran. Five days later 120 recipe specs carried corrections - the scaler fix, seventeen wrong-panel
  macro repairs, the Shop Smart bullet change - that no reader had been served. Nothing was broken:
  every component worked, the dirty set was exactly right, and the corrections were simply never
  shipped.

  AND NOTHING COULD HAVE TOLD US. `expected-automations.json` exists precisely to catch silent death
  and `health-heartbeat.ps1` reads it daily, but it models three things:

      windows_tasks   did the producer run?
      output_files    is this artefact fresh?
      output_globs    is this artefact family fresh?

  A QUEUE IS NONE OF THOSE. When a drain does not run it produces no stale artefact - it produces
  NOTHING, and the pending set grows in silence. There is no failed producer and no aged file. The
  registry was structurally blind to it.

      The estate modelled PRODUCERS and ARTEFACTS, and had no model for a BACKLOG.

  TWO NUMBERS, BECAUSE NEITHER IS ENOUGH ALONE. Depth without age cannot tell a busy day from a stuck
  drain; age without depth reports a drain that has had nothing to do. A queue is only interesting
  when work is waiting AND has been waiting.

  IT MEASURES AND NEVER DRAINS. Draining is a decision with a policy attached - see the plan - and a
  measurement that also acts is one nobody can run to find out where they stand.

    grocery\queue-depth.ps1              # every declared queue
    grocery\queue-depth.ps1 -Json        # the same, machine-readable
    grocery\queue-depth.ps1 -SelfTest

  Exit 0 always: this reports. `health-heartbeat.ps1` is what turns a report into an issue.

  THE PROPAGATE QUEUE IS AGED BY ITS OLDEST WAITING SPEC, NOT BY A FILE (2026-09-28, queue 2026-09-26-62b170).
  Its age used to be the LastWriteTime of propagate-stamps.json, so ANY write to that file (a -SlugsFile run
  that stamps 7 of 70 dirty specs, a -Baseline) read as a full drain and reset the clock for specs that had
  waited far longer. The stamps carry no time, so this file keeps grocery\out\queue-wait-ledger.json
  (gitignored, local state): the time each dirty spec was FIRST SEEN dirty. A spec leaves the ledger when it
  is clean again; the queue's age is the oldest first-seen among the specs still dirty. With no ledger yet,
  the specs dirty on the first run inherit the stamps file's mtime, which is what the old measure read, so
  arming never ages a backlog younger than before. Writing that ledger is bookkeeping, not draining.
#>
# WHAT THE SELF-TEST READS: only in-file fixture depths and fixed dates; the live queues are read below the self-test branch.
# gate-inputs: grocery\queue-depth.ps1
param([switch]$SelfTest, [switch]$Json)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\grocery' }
$repo = Split-Path $here -Parent

function Get-TcQueueVerdict {
  <# What a depth and a wait mean together. Pure, so the fixtures drive it.

     Verdicts:
       empty     nothing is waiting; the age of the last drain does not matter
       draining  work is waiting and the drain ran recently enough
       STUCK     work is waiting and the drain has not run inside its window
       unknown   the queue could not be measured - reported, NEVER read as empty #>
  param($Depth, $HoursSinceDrain, [double]$MaxAgeHours)
  # AN UNMEASURED DEPTH IS NOT A DEPTH OF ZERO, and typing this parameter [int] made it one: $null
  # coerced silently to 0 and a queue whose probe had FAILED reported 'empty'. That is the estate's
  # oldest failure shape - a check that could not look reporting the same thing as a check that looked
  # and found nothing - inside the very file written to stop it.
  if ($null -eq $Depth) {
    return [pscustomobject]@{ Verdict = 'unknown'; Line = 'the depth probe failed - that is not the same as empty' }
  }
  # EMPTY WINS OVER AN UNKNOWN DRAIN TIME. A queue with nothing in it is fine whether or not anything
  # ever drained it, and reporting 'unknown' for a queue that has simply never had work is noise -
  # which is how a report like this gets ignored.
  if ([int]$Depth -le 0) {
    return [pscustomobject]@{ Verdict = 'empty'
      Line = $(if ($null -eq $HoursSinceDrain) { 'nothing waiting, and nothing has ever needed draining' }
               else { "nothing waiting (last drained {0:N1}h ago)" -f $HoursSinceDrain }) }
  }
  if ($null -eq $HoursSinceDrain) {
    return [pscustomobject]@{ Verdict = 'unknown'; Line = 'work is waiting and this queue has NEVER been drained' }
  }
  if ([double]$HoursSinceDrain -le $MaxAgeHours) {
    return [pscustomobject]@{ Verdict = 'draining'; Line = ("{0} item(s) waiting, drained {1:N1}h ago (within {2}h)" -f $Depth, $HoursSinceDrain, $MaxAgeHours) }
  }
  return [pscustomobject]@{ Verdict = 'STUCK'
    Line = ("{0} item(s) have been waiting {1:N1}h, past the {2}h this queue tolerates" -f $Depth, $HoursSinceDrain, $MaxAgeHours) }
}

function Get-TcHoursSince {
  <# Hours between two times, or $null when the marker does not exist.

     $null RATHER THAN A LARGE NUMBER. "never drained" and "drained a long time ago" look identical
     as a float and want different answers - the first is a queue nobody has ever run. #>
  param($MarkerTime, $Now)
  if ($null -eq $MarkerTime) { return $null }
  return [math]::Round((New-TimeSpan -Start $MarkerTime -End $Now).TotalHours, 2)
}

function Measure-TcQueue {
  <# One queue's depth and last-drain time, by name. The per-queue knowledge lives here so
     health-heartbeat stays generic and the registry stays data.

     ReadDepth / ReadDrain are injected so the fixtures never touch the live tree. #>
  param([string]$Name, [scriptblock]$ReadDepth, [scriptblock]$ReadDrain)
  $depth = $null; $drain = $null
  try { $depth = [int](& $ReadDepth $Name) } catch { $depth = $null }
  try { $drain = & $ReadDrain $Name } catch { $drain = $null }
  return [pscustomobject]@{ Name = $Name; Depth = $depth; DrainedAt = $drain }
}

function Update-TcWaitLedger {
  <# When each waiting item was FIRST SEEN waiting, carried across runs. Pure, so the fixtures drive it.

     $Ledger  hashtable item -> [datetime] first seen waiting (from the previous run; empty when new)
     $Dirty   the items waiting NOW
     $ArmedAt the first-seen time for items on a run with NO previous ledger ($null otherwise): the old
              whole-file measure, so arming never makes a backlog read younger than it did before.
     Returns Ledger (only the items still waiting) and Oldest (the earliest first-seen, $null when none). #>
  param([hashtable]$Ledger, [string[]]$Dirty, [datetime]$Now, $ArmedAt = $null)
  $next = @{}
  foreach ($d in @($Dirty | Where-Object { $_ })) {
    if ($Ledger -and $Ledger.ContainsKey($d)) { $next[$d] = [datetime]$Ledger[$d] }
    elseif ($null -ne $ArmedAt) { $next[$d] = [datetime]$ArmedAt }
    else { $next[$d] = $Now }
  }
  $oldest = $null
  foreach ($v in $next.Values) { if ($null -eq $oldest -or $v -lt $oldest) { $oldest = $v } }
  return [pscustomobject]@{ Ledger = $next; Oldest = $oldest }
}

# ------------------------------------------------------------------------------------- live probes
$script:TcPropagateDirty = $null
function Get-TcLiveDepth {
  param([string]$Name)
  switch ($Name) {
    'recipe-specs-awaiting-propagate' {
      # The same comparison propagate makes: spec hash against the stamp it last wrote.
      $stampFile = Join-Path $repo 'meal-prep\pipeline\propagate-stamps.json'
      if (-not (Test-Path $stampFile)) { throw 'no propagate-stamps.json' }
      $stamps = Get-Content $stampFile -Raw -Encoding UTF8 | ConvertFrom-Json
      $h = @{}
      foreach ($p in $stamps.PSObject.Properties) { $h[$p.Name] = [string]$p.Value }
      # LIFTED, NOT REIMPLEMENTED: propagate-recipes.ps1 owns the hash and a second copy of it would
      # drift into reporting a depth the drain does not agree with.
      $src = Get-Content (Join-Path $repo 'meal-prep\pipeline\propagate-recipes.ps1') -Raw -Encoding UTF8
      $m = [regex]::Match($src, '(?s)\$script:MACHINE_FIELD_PATTERNS\s*=\s*@\(.*?\n\)')
      $m2 = [regex]::Match($src, '(?s)\$script:UNRENDERED_FIELD_PATTERNS\s*=\s*@\(.*?\n\)')
      $fn = [regex]::Match($src, '(?s)function Get-SpecHash\(\[string\]\$Path\)\s*\{.*?\n\}')
      if (-not ($m.Success -and $fn.Success)) { throw 'could not lift Get-SpecHash from propagate-recipes.ps1' }
      Invoke-Expression ($m.Value + "`n" + $(if ($m2.Success) { $m2.Value } else { '$script:UNRENDERED_FIELD_PATTERNS = @()' }) + "`n" + $fn.Value)
      $dirty = New-Object System.Collections.Generic.List[string]
      foreach ($f in (Get-ChildItem (Join-Path $repo 'meal-prep\db\recipes') -Filter *.json -ErrorAction SilentlyContinue)) {
        if (-not $h.ContainsKey($f.BaseName) -or $h[$f.BaseName] -ne (Get-SpecHash $f.FullName)) { $dirty.Add($f.BaseName) }
      }
      # Get-TcLiveDrain ages this queue by these names; Measure-TcQueue always reads depth first.
      $script:TcPropagateDirty = $dirty.ToArray()
      return $dirty.Count
    }
    'staged-ghost-writes' {
      $q = Join-Path $repo 'ops\staged-writes.jsonl'
      if (-not (Test-Path $q)) { return 0 }
      return @(Get-Content $q -ErrorAction SilentlyContinue | Where-Object { $_.Trim() }).Count
    }
    'open-triage-items' {
      $q = Join-Path $repo 'grocery\triage-queue.json'
      if (-not (Test-Path $q)) { throw 'no triage-queue.json' }
      $doc = Get-Content $q -Raw -Encoding UTF8 | ConvertFrom-Json
      return @(@($doc.items) | Where-Object { [string]$_.status -eq 'open' }).Count
    }
    default { throw ("no probe for queue '{0}'" -f $Name) }
  }
}

function Get-TcLiveDrain {
  param([string]$Name)
  if ($Name -eq 'recipe-specs-awaiting-propagate') { return (Get-TcPropagateOldestWait) }
  $p = switch ($Name) {
    'recipe-specs-awaiting-propagate' { Join-Path $repo 'meal-prep\pipeline\propagate-stamps.json' }
    'staged-ghost-writes'             { Join-Path $repo 'ops\staged-writes.jsonl' }
    'open-triage-items'               { Join-Path $repo 'grocery\triage-queue.json' }
    default { $null }
  }
  if (-not $p -or -not (Test-Path $p)) { return $null }
  return (Get-Item $p).LastWriteTime
}

function Get-TcPropagateOldestWait {
  <# The time the OLDEST still-dirty spec was first seen dirty (see the header). With nothing dirty, the stamps
     file's mtime, which is when the queue last drained. Read-modify-write under the ledger lock (og-26). #>
  $stampFile = Join-Path $repo 'meal-prep\pipeline\propagate-stamps.json'
  if ($null -eq $script:TcPropagateDirty) { throw 'the depth probe did not name the dirty specs' }
  $stampsAt = if (Test-Path $stampFile) { (Get-Item $stampFile).LastWriteTime } else { $null }
  $qname = 'recipe-specs-awaiting-propagate'
  $path = Join-Path $repo 'grocery\out\queue-wait-ledger.json'
  $lock = Enter-TcLedgerLock -Path $path
  try {
    $doc = @{}; $prev = @{}; $armedAt = $stampsAt
    if (Test-Path $path) {
      $raw = [IO.File]::ReadAllText($path) | ConvertFrom-Json
      foreach ($qp in $raw.PSObject.Properties) { $doc[$qp.Name] = $qp.Value }
      if ($doc.ContainsKey($qname)) {
        $armedAt = $null
        foreach ($sp in $doc[$qname].PSObject.Properties) { $prev[$sp.Name] = [datetime]::Parse([string]$sp.Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) }
      }
    }
    $u = Update-TcWaitLedger -Ledger $prev -Dirty $script:TcPropagateDirty -Now (Get-Date) -ArmedAt $armedAt
    $out = [ordered]@{}
    foreach ($k in ($u.Ledger.Keys | Sort-Object)) { $out[$k] = $u.Ledger[$k].ToString('o') }
    $doc[$qname] = $out
    [void](Write-TcAtomicFile -Path $path -Text ($doc | ConvertTo-Json -Depth 4) -NoBom)
  } finally { Exit-TcLedgerLock $lock }
  if ($null -eq $u.Oldest) { return $stampsAt }
  return $u.Oldest
}

# ------------------------------------------------------------------------------------- self-test
if ($SelfTest) {
  $f = 0
  function T($m, $cond, $got) { if ($cond) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $got); $script:f++ } }

  T 'MUST FIRE  THE ONE THIS FILE EXISTS FOR - work waiting past the window is STUCK, which is what five days of unshipped corrections looked like' `
    ((Get-TcQueueVerdict -Depth 120 -HoursSinceDrain 120 -MaxAgeHours 72).Verdict -eq 'STUCK') `
    (Get-TcQueueVerdict -Depth 120 -HoursSinceDrain 120 -MaxAgeHours 72).Verdict
  T 'MUST FIRE  the STUCK line carries BOTH numbers - depth alone cannot tell a busy day from a stuck drain' `
    ((Get-TcQueueVerdict -Depth 120 -HoursSinceDrain 120 -MaxAgeHours 72).Line -like '*120 item(s)*120.0h*') `
    (Get-TcQueueVerdict -Depth 120 -HoursSinceDrain 120 -MaxAgeHours 72).Line
  T 'MUST FIRE  work waiting on a queue that has NEVER been drained is unknown, not draining' `
    ((Get-TcQueueVerdict -Depth 5 -HoursSinceDrain $null -MaxAgeHours 72).Verdict -eq 'unknown') `
    (Get-TcQueueVerdict -Depth 5 -HoursSinceDrain $null -MaxAgeHours 72).Verdict
  T 'MUST FIRE  A FAILED DEPTH PROBE IS UNKNOWN, NEVER EMPTY - typing this parameter [int] coerced $null to 0 and reported a broken probe as a clean queue, inside the file written to stop exactly that' `
    ((Get-TcQueueVerdict -Depth $null -HoursSinceDrain 4 -MaxAgeHours 72).Verdict -eq 'unknown') `
    (Get-TcQueueVerdict -Depth $null -HoursSinceDrain 4 -MaxAgeHours 72).Verdict
  T 'MUST NOT FIRE  a queue that is empty and has never been drained is EMPTY - a drain that never had work is not a problem, and reporting it is how a report gets ignored' `
    ((Get-TcQueueVerdict -Depth 0 -HoursSinceDrain $null -MaxAgeHours 72).Verdict -eq 'empty') `
    (Get-TcQueueVerdict -Depth 0 -HoursSinceDrain $null -MaxAgeHours 72).Verdict

  T 'MUST NOT FIRE  an EMPTY queue is fine however long since the drain ran - a drain with nothing to do is not stuck' `
    ((Get-TcQueueVerdict -Depth 0 -HoursSinceDrain 900 -MaxAgeHours 72).Verdict -eq 'empty') `
    (Get-TcQueueVerdict -Depth 0 -HoursSinceDrain 900 -MaxAgeHours 72).Verdict
  T 'MUST NOT FIRE  work waiting INSIDE the window is draining, not stuck' `
    ((Get-TcQueueVerdict -Depth 30 -HoursSinceDrain 5 -MaxAgeHours 72).Verdict -eq 'draining') `
    (Get-TcQueueVerdict -Depth 30 -HoursSinceDrain 5 -MaxAgeHours 72).Verdict
  T 'MUST NOT FIRE  exactly at the boundary is still draining - a window is inclusive or it fires a day early forever' `
    ((Get-TcQueueVerdict -Depth 1 -HoursSinceDrain 72 -MaxAgeHours 72).Verdict -eq 'draining') `
    (Get-TcQueueVerdict -Depth 1 -HoursSinceDrain 72 -MaxAgeHours 72).Verdict

  $now = Get-Date '2026-09-07T12:00:00'
  T 'CLEAN TWIN hours-since is measured from the marker, not guessed' `
    ((Get-TcHoursSince (Get-Date '2026-09-07T06:00:00') $now) -eq 6) ([string](Get-TcHoursSince (Get-Date '2026-09-07T06:00:00') $now))
  T 'CLEAN TWIN a queue with NO drain marker answers $null, because "never drained" and "drained long ago" want different answers' `
    ($null -eq (Get-TcHoursSince $null $now)) 'invented an age'
  $r = Measure-TcQueue -Name 'q' -ReadDepth { 7 } -ReadDrain { Get-Date '2026-09-07T06:00:00' }
  T 'CLEAN TWIN the measurer reports what the probes returned' (($r.Depth -eq 7) -and ($r.DrainedAt)) ([string]$r.Depth)
  $rBad = Measure-TcQueue -Name 'q' -ReadDepth { throw 'no such file' } -ReadDrain { throw 'nope' }
  T 'CLEAN TWIN a probe that throws yields nulls rather than taking the run down - a broken probe must not stop the other queues being reported' `
    (($null -eq $rBad.Depth) -and ($null -eq $rBad.DrainedAt)) 'a throwing probe escaped'

  # ---- AGED BY THE OLDEST WAITING ITEM (2026-09-28, queue 2026-09-26-62b170). Founding shape: 70 specs dirty from
  #      2026-09-19 06:18; a -SlugsFile run stamps 7 of them on 09-26 17:00, which rewrote the stamps file, so the old
  #      whole-file age read 1h and 'draining' while 63 specs had waited about 180h.
  $w0 = Get-Date '2026-09-19T06:18:00'; $wNow = Get-Date '2026-09-26T18:00:00'
  $w70 = @(1..70 | ForEach-Object { 'spec-' + $_ }); $wL = @{}; foreach ($s in $w70) { $wL[$s] = $w0 }
  $wPart = Update-TcWaitLedger -Ledger $wL -Dirty @($w70 | Select-Object -Skip 7) -Now $wNow
  $wHrs = Get-TcHoursSince $wPart.Oldest $wNow
  $wOld = Get-TcHoursSince (Get-Date '2026-09-26T17:00:00') $wNow
  T 'MUST FIRE  A PARTIAL DRAIN DOES NOT RESET THE CLOCK: 7 of 70 stamped, the 63 left keep their 09-19 first-seen and the queue is STUCK (the stamps-file mtime would have read 1h, draining)' `
    (($wPart.Ledger.Count -eq 63) -and ($wPart.Oldest -eq $w0) -and ((Get-TcQueueVerdict -Depth 63 -HoursSinceDrain $wHrs -MaxAgeHours 72).Verdict -eq 'STUCK') -and ((Get-TcQueueVerdict -Depth 63 -HoursSinceDrain $wOld -MaxAgeHours 72).Verdict -eq 'draining')) `
    ("ledger=" + $wPart.Ledger.Count + " oldest=" + $wPart.Oldest + " hrs=" + $wHrs)
  $wArm = Update-TcWaitLedger -Ledger @{} -Dirty @('a', 'b') -Now $wNow -ArmedAt $w0
  T 'MUST FIRE  arming with no ledger inherits the stamps-file time, so the first run never ages a backlog younger than the old measure did' `
    (($wArm.Oldest -eq $w0) -and ($wArm.Ledger['b'] -eq $w0)) ([string]$wArm.Oldest)
  $wBar = Update-TcWaitLedger -Ledger @{ 'x' = $wNow.AddHours(-72) } -Dirty @('x') -Now $wNow
  $wPast = Update-TcWaitLedger -Ledger @{ 'x' = $wNow.AddHours(-72.25) } -Dirty @('x') -Now $wNow
  T 'MUST NOT FIRE  AT THE BAR: the oldest spec first seen exactly 72h ago (bar 72h) is still draining' `
    ((Get-TcQueueVerdict -Depth 1 -HoursSinceDrain (Get-TcHoursSince $wBar.Oldest $wNow) -MaxAgeHours 72).Verdict -eq 'draining') ([string](Get-TcHoursSince $wBar.Oldest $wNow))
  T 'MUST FIRE  ONE STEP PAST THE BAR: first seen 72.25h ago (bar 72h) is STUCK' `
    ((Get-TcQueueVerdict -Depth 1 -HoursSinceDrain (Get-TcHoursSince $wPast.Oldest $wNow) -MaxAgeHours 72).Verdict -eq 'STUCK') ([string](Get-TcHoursSince $wPast.Oldest $wNow))
  $wFull = Update-TcWaitLedger -Ledger $wL -Dirty @('new-1', 'new-2') -Now $wNow
  T 'CLEAN TWIN  a FULL drain followed by new dirt: the old entries leave, the new ones start at now, and the queue is draining' `
    (($wFull.Ledger.Count -eq 2) -and ($wFull.Oldest -eq $wNow) -and (-not $wFull.Ledger.ContainsKey('spec-1'))) ("ledger=" + $wFull.Ledger.Count + " oldest=" + $wFull.Oldest)
  $wNone = Update-TcWaitLedger -Ledger $wL -Dirty @() -Now $wNow
  T 'CLEAN TWIN  nothing dirty empties the ledger and names no oldest' (($wNone.Ledger.Count -eq 0) -and ($null -eq $wNone.Oldest)) ([string]$wNone.Ledger.Count)

  if ($f) { Write-Output ("SELF-TEST FAIL: {0} check(s)" -f $f); exit 1 }
  Write-Output 'SELF-TEST PASS: 7 must-fire cases led by the five-day backlog this file was written for, a failed probe never reading as empty and a partial drain never resetting the clock, 5 must-not-fire cases including two inclusive boundaries, and 6 clean twins'
  exit 0
}

# ------------------------------------------------------------------------------------- live run
. (Join-Path $repo 'lib\atomic-write.ps1')
. (Join-Path $repo 'lib\ledger-lock.ps1')
$cfgPath = Join-Path $here 'expected-automations.json'
$cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
$rows = @()
foreach ($q in @($cfg.queues)) {
  $m = Measure-TcQueue -Name ([string]$q.name) -ReadDepth { param($n) Get-TcLiveDepth $n } -ReadDrain { param($n) Get-TcLiveDrain $n }
  $hrs = Get-TcHoursSince $m.DrainedAt (Get-Date)
  $v = Get-TcQueueVerdict -Depth $m.Depth -HoursSinceDrain $hrs -MaxAgeHours ([double]$q.max_age_hours)
  if ([string]$q.name -eq 'recipe-specs-awaiting-propagate' -and $v.Verdict -eq 'draining') {
    $v.Line = $v.Line -replace 'drained ([0-9.,]+)h ago', 'the oldest has waited $1h'
  }
  $rows +=[pscustomobject]@{ name = $q.name; depth = $m.Depth; hours_since_drain = $hrs
                              verdict = $v.Verdict; line = $v.Line; cost_if_undrained = [string]$q.cost_if_undrained }
}
if ($Json) { $rows | ConvertTo-Json -Depth 4; exit 0 }
foreach ($r in $rows) {
  Write-Output ("  {0,-9} {1,-34} {2}" -f $r.verdict, $r.name, $r.line)
  if ($r.verdict -eq 'STUCK') { Write-Output ("            what that costs: " + $r.cost_if_undrained) }
}
Write-Output ("queue-depth: {0} declared queue(s), {1} STUCK." -f $rows.Count, @($rows | Where-Object { $_.verdict -eq 'STUCK' }).Count)
Write-Output 'QUEUE-DEPTH-COMPLETE'
exit 0
