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

    grocery\triage-close.ps1 -Id 2026-09-07-ab12cd -Disposition confirmed -Notes "what was established"
    grocery\triage-close.ps1 -SelfTest

  Exit 0 = closed. 1 = refused (bad id, bad disposition, thin notes). 3 = could not read the queue.
  Read the verdict LINE, not the number (backlog E2).
#>
param(
  [string]$Id,
  [string]$Disposition,
  [string]$Notes,
  [string]$QueueFile,
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\grocery' }
. (Join-Path $here 'triage-lib.ps1')
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

  if ($f) { Write-Output ("SELF-TEST FAIL: {0} check(s)" -f $f); exit 1 }
  Write-Output 'SELF-TEST PASS: four refusals including the rubber-stamp guard, the five legal dispositions, the amendment twin, the E20 denominator rule and the E21 too-few-cases rule, and the cutoff that keeps the gate green on day one'
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
$q | ConvertTo-Json -Depth 12 | Set-Content $QueueFile -Encoding UTF8
Write-Output ("triage-close: {0} closed as {1}. What it meant is now countable, which is what makes a live precision knowable at all." -f $Id, $Disposition)
exit 0
