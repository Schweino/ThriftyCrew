<#
  triage-close.ps1 - the one way to close an alert, so what it MEANT gets recorded.

  WHY THIS EXISTS (2026-09-07, backlog E22's open half). Triage closes queue items by hand-editing
  `status` and `notes` into `grocery/triage-queue.json`. That records that somebody dealt with it and
  loses the only fact E22 needs: whether the alert was RIGHT. "RESOLVED on re-measurement, the signal
  no longer holds" and "Rolling condition by design" are opposite outcomes in identical prose, and 124
  closed items are written that way.

  Closing through this script instead makes the disposition unforgettable, because it is a required
  argument rather than a field somebody remembers. `grocery/audit-alert-precision.ps1` then counts them
  and reports a per-type live precision - the number E22 says nobody currently knows.

  IT WRITES THE WHOLE QUEUE BACK, so it refuses on anything it cannot parse rather than rebuilding.
  send-alert.ps1 carries the same refusal for the same reason: an empty read is not an empty queue,
  and overwriting on that assumption is how the entire backlog would disappear.

  IT TAKES THE QUEUE LOCK send-alert.ps1 TAKES (2026-09-11). Until today this read the queue, closed the item and
  wrote the whole file back in place with no lock at all, while send-alert.ps1 rewrites the same file under the
  named mutex Global\smp-grocery-triage-queue. Those two are the only writers of the queue. Unlocked, that loses work
  three ways:
    * A LOST UPDATE, EITHER WAY ROUND. An alert send-alert queues between this script's read and its write is
      written over, and a close whose write lands between send-alert's read and its write is undone. On a copy of
      the live queue (517 KB, 173 items) this script's read-to-write window measured 112 to 672 ms over 5 runs,
      while alerts fire all day from capture-run's lanes, check-ad-cycles' fanout and the sidecar watchdog.
    * DRIVEN, NOT JUST ARGUED. A scratch harness (not committed) ran this script at 87bae2d6b against the fixed one,
      each beside a real send-alert.ps1 in a muted temp tree, on that live-size queue copy reset every trial:
      20 paired trials, send-alert launched -400 to +400 ms from the close. The bar was set before the run - take
      the lock if the unlocked arm loses one update. It lost 5 of 20: two alerts send-alert had reported "queued to
      triage-queue.json" were gone, two closes that printed "closed as confirmed" were undone, and one close died
      with exit 1 and no verdict line. Under the lock: 0 of 20, every close exit 0. One run, no variant re-tried.
    * AN IN-PLACE Set-Content TRUNCATES AND THEN FILLS, so a send-alert reading in that instant finds an empty
      queue, refuses to overwrite it, and spools: the 2026-07-28 shape send-alert's own header records.
  So the read, the close and the write happen inside the lock, the write goes through lib\atomic-write.ps1, and a
  lock not taken within -QueueLockTimeoutMs is exit 3 with NOTHING written. Run the close again.

    grocery\triage-close.ps1 -Id 2026-09-07-ab12cd -Disposition confirmed -Notes "what was established"
    grocery\triage-close.ps1 -SelfTest

  Exit 0 = closed. 1 = refused (bad id, bad disposition, thin notes). 3 = could not read the queue, take its lock or
  write it back, and nothing was closed.
  Read the verdict LINE, not the number (backlog E2).
#>
param(
  [string]$Id,
  [string]$Disposition,
  [string]$Notes,
  [string]$QueueFile,
  # THE QUEUE LOCK (2026-09-11): the name send-alert.ps1 takes around its own rewrite. Every live close takes the
  # default; -SelfTest passes a fresh fixture name, so a lock it holds on purpose never stalls a real alert.
  [string]$QueueMutexName = 'Global\smp-grocery-triage-queue',
  # 30 s is the first plausible number, not the survivor of a sweep. A close is run by triage, not by the pipeline,
  # so waiting longer than send-alert's 10 s costs nothing, and a send holds the lock for a read, a rebuild and a
  # replace whose retry budget is about 7 s. What it does when the producer stops: nothing - it runs only on a close.
  [int]$QueueLockTimeoutMs = 30000,
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\grocery' }
. (Join-Path $here 'triage-lib.ps1')
. (Join-Path (Split-Path -Parent $here) 'lib\atomic-write.ps1')   # Write-TcAtomicFile: a lock-free reader must not cost a close its write
if (-not $QueueFile) { $QueueFile = Join-Path $here 'triage-queue.json' }

# ------------------------------------------------------------------------------------- self-test
if ($SelfTest) {
  $f = 0
  function T($m, $cond, $got) { if ($cond) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $got); $script:f++ } }
  $NOTE = 'the alert named a real board cell and the fix is committed'

  function NewItems {
    return @(
      [pscustomobject]@{ id = 'a1'; type = 'grocery new price flag s'; status = 'open'; resolved_ts = $null; notes = $null },
      [pscustomobject]@{ id = 'a2'; type = 'grocery new price flag s'; status = 'open'; resolved_ts = $null; notes = $null }
    )
  }

  # MUST FIRE - the refusals. Every fixture is a single-quoted literal; built by concatenation these
  # would be three positional arguments and the case would run on a fragment.
  $items = NewItems
  T 'MUST FIRE  an unknown id is refused rather than silently doing nothing' `
    ((Close-TcQueueItem -Items $items -Id 'nope' -Disposition 'confirmed' -Notes $NOTE) -like "*no queue item*") `
    (Close-TcQueueItem -Items $items -Id 'nope' -Disposition 'confirmed' -Notes $NOTE)
  T 'MUST FIRE  a disposition outside the vocabulary is refused, and the message names the vocabulary' `
    ((Close-TcQueueItem -Items $items -Id 'a1' -Disposition 'fixed' -Notes $NOTE) -like '*false-alarm*') `
    (Close-TcQueueItem -Items $items -Id 'a1' -Disposition 'fixed' -Notes $NOTE)
  T 'MUST FIRE  THE ONE THAT KEEPS THIS FROM BECOMING A RUBBER STAMP - a close with no real notes is refused' `
    ((Close-TcQueueItem -Items $items -Id 'a1' -Disposition 'confirmed' -Notes 'ok') -like '*notes are required*') `
    (Close-TcQueueItem -Items $items -Id 'a1' -Disposition 'confirmed' -Notes 'ok')
  T 'MUST FIRE  a refused close leaves the item OPEN - a refusal that half-wrote would be worse than no gate' `
    (([string]$items[0].status -eq 'open') -and (-not $items[0].PSObject.Properties['disposition'])) `
    ([string]$items[0].status)

  # MUST NOT FIRE - the legal closes.
  $items = NewItems
  $why = Close-TcQueueItem -Items $items -Id 'a1' -Disposition 'false-alarm' -Notes $NOTE -Now '2026-09-07T09:00:00'
  T 'MUST NOT FIRE  a legal close is accepted and stamps status, disposition and the close time' `
    (($why -eq '') -and ([string]$items[0].status -eq 'resolved') -and ([string]$items[0].disposition -eq 'false-alarm') -and ([string]$items[0].resolved_ts -eq '2026-09-07T09:00:00')) `
    ($why + ' / ' + [string]$items[0].status + ' / ' + [string]$items[0].disposition)
  T 'MUST NOT FIRE  closing one item leaves its siblings untouched' `
    (([string]$items[1].status -eq 'open') -and (-not $items[1].PSObject.Properties['disposition'])) ([string]$items[1].status)
  # ASSIGN, THEN ITERATE. `foreach ($d in @(Get-TcDispositions))` binds the WHOLE comma-returned
  # array to $d on the first pass, so this reported one case named 'confirmed false-alarm superseded
  # by-design wont-fix'. [[ps-json-array-collapse]]
  $vocab = Get-TcDispositions
  foreach ($d in @($vocab)) {
    T ('MUST NOT FIRE  ' + $d + ' is a legal disposition') ((Test-TcDisposition $d) -eq '') (Test-TcDisposition $d)
  }

  # CLEAN TWIN - adjacent behaviour that still works.
  $why2 = Close-TcQueueItem -Items $items -Id 'a1' -Disposition 'confirmed' -Notes 'AMENDED - round one was wrong and this is why' -Now '2026-09-08T09:00:00'
  T 'CLEAN TWIN an AMENDED verdict is accepted, because the live queue already carries one' `
    (($why2 -eq '') -and ([string]$items[0].disposition -eq 'confirmed')) ($why2 + ' / ' + [string]$items[0].disposition)
  T 'CLEAN TWIN the amendment keeps the FIRST close time, so the queue history stays readable' `
    ([string]$items[0].resolved_ts -eq '2026-09-07T09:00:00') ([string]$items[0].resolved_ts)

  # The precision read, and the reason it refuses small numbers.
  $many = @()
  foreach ($n in 1..6) { $many += [pscustomobject]@{ id = "h$n"; type = 't'; status = 'resolved'; disposition = 'confirmed' } }
  $many += [pscustomobject]@{ id = 'm1'; type = 't'; status = 'resolved'; disposition = 'false-alarm' }
  $many += [pscustomobject]@{ id = 's1'; type = 't'; status = 'resolved'; disposition = 'superseded' }
  $p = Get-TcPrecision -Items $many
  T 'MUST FIRE  precision is hits over JUDGED closes, and superseded is excluded rather than folded in' `
    (($p[0].Judged -eq 7) -and ($p[0].Rate -eq 85.7) -and ($p[0].Neither -eq 1)) `
    ("judged=" + $p[0].Judged + " rate=" + $p[0].Rate + " neither=" + $p[0].Neither)
  T 'MUST FIRE  THE E20 RULE - the reported line always carries its denominator, never a bare rate' `
    ($p[0].Line -like '*over 7 judged close(s)*') $p[0].Line
  $few = @([pscustomobject]@{ id = 'x'; type = 'u'; status = 'resolved'; disposition = 'confirmed' },
           [pscustomobject]@{ id = 'y'; type = 'u'; status = 'resolved'; disposition = 'false-alarm' })
  $p2 = Get-TcPrecision -Items $few
  T 'MUST NOT FIRE  THE E21 RULE - two closes do not make a 50% precision, and none is stated' `
    (($null -eq $p2[0].Rate) -and ($p2[0].Line -like '*too few*')) $p2[0].Line
  $unjudged = Get-TcPrecision -Items @([pscustomobject]@{ id = 'z'; type = 'v'; status = 'resolved' })
  T 'CLEAN TWIN an item with no disposition at all is not counted in either direction' `
    (@($unjudged).Count -eq 0) 'counted an unjudged item'

  # The gate's own predicate.
  $old = @([pscustomobject]@{ id = 'o'; type = 't'; status = 'resolved'; resolved_ts = '2026-08-30T10:00:00' })
  $oldBad = Get-TcUndispositioned -Items $old
  T 'MUST NOT FIRE  THE ONE THAT KEEPS THIS GREEN ON DAY ONE - an item closed before the cutoff owes no disposition' `
    (@($oldBad).Count -eq 0) 'the 124 historical closes would all be red'
  $new = @([pscustomobject]@{ id = 'n'; type = 't'; status = 'resolved'; resolved_ts = '2026-09-08T10:00:00' })
  $newBad = Get-TcUndispositioned -Items $new
  T 'MUST FIRE  an item closed AFTER the cutoff with no disposition is a finding' `
    (@($newBad).Count -eq 1) 'missed an undispositioned close'
  $openItem = @([pscustomobject]@{ id = 'p'; type = 't'; status = 'open'; resolved_ts = $null })
  $openBad = Get-TcUndispositioned -Items $openItem
  T 'MUST NOT FIRE  an OPEN item owes no disposition - it has not been judged yet' `
    (@($openBad).Count -eq 0) 'flagged an open item'
  $u = Get-TcUndispositioned -Items $new
  T 'CLEAN TWIN a single finding comes back as an ARRAY, not unrolled to one object' ($u -is [array]) ($u.GetType().FullName)

  # ---- THE QUEUE LOCK (2026-09-11) ----
  # Out of process, against the REAL script copied into a temp tree that has no lib\event-bus.ps1, so no case here can
  # put an alert-closed event on the live bus. The lock is a fresh fixture name, never the live one.
  . (Join-Path (Split-Path -Parent $here) 'lib\mutex-hold.ps1')
  $lkDir = Join-Path ([IO.Path]::GetTempPath()) ('tc-close-lock-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
  $lkG = Join-Path $lkDir 'grocery'
  $lkL = Join-Path $lkDir 'lib'
  New-Item -ItemType Directory -Force -Path $lkG, $lkL | Out-Null
  $u8 = New-Object Text.UTF8Encoding($false)
  try {
    Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $lkG 'triage-close.ps1')
    Copy-Item -LiteralPath (Join-Path $here 'triage-lib.ps1') -Destination (Join-Path $lkG 'triage-lib.ps1')
    Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $here) 'lib\atomic-write.ps1') -Destination (Join-Path $lkL 'atomic-write.ps1')
    $lkQ = Join-Path $lkG 'triage-queue.json'
    [IO.File]::WriteAllText($lkQ, '{ "readme": "frozen fixture", "items": [ { "id": "2026-09-11-lk0001", "date": "2026-09-11", "ts": "2026-09-11T08:00:00", "type": "grocery new price flag s", "subject": "Grocery: 1 NEW price flag(s) - 2026-09-11", "body": "Hy-Vee canned-mushrooms flagged at 3 rows", "status": "open", "count": 1, "resolved_ts": null, "notes": null } ] }', $u8)
    $lkMutex = New-TcFixtureMutexName 'tc-close-selftest-queue'
    function _Close([int]$TimeoutMs) {
      $o = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $lkG 'triage-close.ps1') -Id '2026-09-11-lk0001' -Disposition 'confirmed' -Notes $NOTE -QueueFile $lkQ -QueueMutexName $lkMutex -QueueLockTimeoutMs $TimeoutMs
      $rc = $LASTEXITCODE
      return [pscustomobject]@{ out = ((@($o) | ForEach-Object { [string]$_ }) -join ' | '); rc = $rc }
    }
    # MUST FIRE, the founding shape: another process holds the queue lock through this close's whole wait. Before the
    # fix the close never asked for the lock and wrote the queue anyway. The holder keeps the lock until released, so
    # no clock decides this case.
    $lkBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($lkQ))
    $c1 = $null
    $lkHold = Start-TcMutexHold -Name $lkMutex
    try { if ($lkHold.Held) { $c1 = _Close 1000 } } finally { Stop-TcMutexHold -Hold $lkHold }
    T 'the lock fixture really held the queue lock from another process' ([bool]$lkHold.Held) $lkHold.Detail
    T 'MUST FIRE  a close whose queue lock is held by another process exits 3 and says nothing was written' `
      (($null -ne $c1) -and $c1.rc -eq 3 -and $c1.out -like '*lock*NOTHING was written*') $(if ($c1) { 'rc=' + $c1.rc + ' ' + $c1.out } else { 'not run' })
    T 'MUST FIRE  and the queue file is byte-identical, so the item is still open' `
      (($null -ne $c1) -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($lkQ)) -eq $lkBefore) 'the queue bytes changed'
    # CLEAN TWIN: the lock free, the same close lands, in the bytes the old in-place Set-Content -Encoding utf8 wrote.
    $c2 = _Close 1000
    $lkBytes = [IO.File]::ReadAllBytes($lkQ)
    $lkDoc = [IO.File]::ReadAllText($lkQ) | ConvertFrom-Json
    $lkItems = @($lkDoc.items)
    T 'CLEAN TWIN with the lock free the same close lands: exit 0, the item resolved as confirmed' `
      ($c2.rc -eq 0 -and $lkItems.Count -eq 1 -and [string]$lkItems[0].status -eq 'resolved' -and [string]$lkItems[0].disposition -eq 'confirmed') ('rc=' + $c2.rc + ' ' + $c2.out)
    T 'CLEAN TWIN and the queue is written as before: a UTF-8 BOM first and CRLF last' `
      ($lkBytes.Length -gt 5 -and $lkBytes[0] -eq 0xEF -and $lkBytes[1] -eq 0xBB -and $lkBytes[2] -eq 0xBF -and $lkBytes[$lkBytes.Length - 2] -eq 13 -and $lkBytes[$lkBytes.Length - 1] -eq 10) 'bytes differ from Set-Content -Encoding utf8'
  } finally {
    Stop-TcMutexHold
    Remove-Item -LiteralPath $lkDir -Recurse -Force -ErrorAction SilentlyContinue
  }

  if ($f) { Write-Output ("SELF-TEST FAIL: {0} check(s)" -f $f); exit 1 }
  Write-Output 'SELF-TEST PASS: four refusals including the rubber-stamp guard, the five legal dispositions, the amendment twin, the E20 denominator rule and the E21 too-few-cases rule, the cutoff that keeps the gate green on day one, and the queue lock refusal'
  exit 0
}

# ------------------------------------------------------------------------------------- live run
foreach ($req in @(@{ n = 'Id'; v = $Id }, @{ n = 'Disposition'; v = $Disposition }, @{ n = 'Notes'; v = $Notes })) {
  if (-not $req.v) {
    Write-Output ("TRIAGE CLOSE REFUSED: -{0} is required. Dispositions: {1}" -f $req.n, ((Get-TcDispositions) -join ', '))
    exit 1
  }
}
if (-not (Test-Path -LiteralPath $QueueFile)) {
  Write-Output ("TRIAGE CLOSE COULD NOT EVALUATE: {0} does not exist." -f $QueueFile)
  exit 3
}
# THE READ, THE CLOSE AND THE WRITE ARE ONE STEP UNDER THE QUEUE LOCK (2026-09-11) - the header says why. A lock not
# taken is exit 3 with nothing written, never a write without it.
$qMutex = New-Object System.Threading.Mutex($false, $QueueMutexName)
$qHeld = $false
try { $qHeld = $qMutex.WaitOne($QueueLockTimeoutMs) } catch [System.Threading.AbandonedMutexException] { $qHeld = $true }
try {
  if (-not $qHeld) {
    Write-Output ("TRIAGE CLOSE COULD NOT EVALUATE: the queue lock {0} was not acquired in {1} ms - another writer holds it. NOTHING was written; run the close again." -f $QueueMutexName, $QueueLockTimeoutMs)
    exit 3
  }
  $raw = Get-Content $QueueFile -Raw -Encoding UTF8
  if (-not ($raw -and $raw.Trim())) {
    Write-Output 'TRIAGE CLOSE COULD NOT EVALUATE: the queue read back empty. Refusing to write over it - an empty read is not an empty queue.'
    exit 3
  }
  $q = $null
  try { $q = $raw | ConvertFrom-Json } catch { }
  if (-not $q) {
    Write-Output 'TRIAGE CLOSE COULD NOT EVALUATE: the queue did not parse. Refusing to rebuild it.'
    exit 3
  }
  # ASSIGN, THEN WRAP. @($q.items) inline on a one-item queue reads as one element either way, but the
  # habit is what stops the next reader writing @(Get-Thing ...). [[ps-json-array-collapse]]
  $items = @($q.items)
  $why = Close-TcQueueItem -Items $items -Id $Id -Disposition $Disposition -Notes $Notes
  if ($why) {
    Write-Output ("TRIAGE CLOSE REFUSED: " + $why)
    exit 1
  }
  $q.items = $items
  # A temp file and a retried replace rather than Set-Content in place, so no reader ever sees a truncated queue.
  try { [void](Write-TcAtomicFile -Path $QueueFile -Text ($q | ConvertTo-Json -Depth 12)) }
  catch {
    Write-Output ('TRIAGE CLOSE COULD NOT EVALUATE: the queue could not be replaced, so ' + $Id + ' is NOT closed. ' + $_.Exception.Message)
    exit 3
  }
} finally {
  # Runs on every exit above. A process that dies holding the lock leaves it ABANDONED, and the next waiter takes it.
  if ($qHeld) { try { $qMutex.ReleaseMutex() } catch { } }
  try { $qMutex.Dispose() } catch { }
}

# THE CLOSE IS AN EVENT (WS 1b), written AFTER the queue is saved so the bus never claims a
# close that did not land. `audit-alert-precision.ps1` already computes precision per type
# from the queue and prints it into an 8,000-line log that nothing joins to anything; the bus
# is what lets the alert-tuning actuator, the incident trigger and the morning digest see a
# disposition without re-reading the queue and re-deriving what a close meant.
#
# It cannot fail this script: Write-TcEvent swallows every error and returns a boolean. A
# close that succeeded must not be reported as failed because a log was locked.
$busLib = Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\event-bus.ps1'
if (Test-Path -LiteralPath $busLib) {
  . $busLib
  $closed = $null
  foreach ($it in $items) { if ("$($it.id)" -eq "$Id") { $closed = $it } }
  $null = Write-TcEvent -Kind 'alert-closed' -Producer 'grocery\triage-close.ps1' -Data @{
    id          = "$Id"
    disposition = "$Disposition"
    type        = "$(if ($closed) { $closed.type } else { '' })"
  }
}
Write-Output ("triage-close: {0} closed as {1}. What it meant is now countable, which is what makes a live precision knowable at all." -f $Id, $Disposition)
exit 0
