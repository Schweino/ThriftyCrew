<#
  event-bus.ps1 - ONE writer for "something happened", so the learning loop has senses.

  WS 1b of design\PLAN-brain-v2-2026-09-09.md.

  WHY IT EXISTS. This estate produces objective outcome events all day and no learning stage
  reads any of them. A gate goes red and prints to a terminal; nothing counts it, nothing
  turns it into a fixture, and there is no gate-failure history anywhere. An alert is closed
  with a disposition and the precision is computed daily into an 8,000-line log that no
  parameter reads. A known-wrong ruling is made and nothing asks whether that class keeps
  recurring. Every one of those is a nerve ending that fires into nothing.

  WHAT AN EVENT IS. A fact with a time, written by the thing that already knew it. Not a
  judgement, not a metric, not a report. `gate-red` says which gate and at what commit; it
  does not say whether that is bad. Deciding is the reader's job and the readers are
  ops\brain-report.ps1, the incident trigger and the morning digest.

  *** IT MUST NEVER BREAK ITS PRODUCER. *** Every path swallows every error and returns.
  A bus that can take down a gate, a publish or a capture run would cost more than every
  signal it carries. This is the same rule the recall hooks live under and for the same
  reason: an observer that can break the thing it observes is worse than no observer.

  ONE ROW PER EVENT, RAW, APPEND ONLY. No aggregation at write time.
  `.claude\rules\measurement.md` E24: a pair of totals cannot be un-aggregated, and the
  comparison you did not keep is gone forever.

  SEVERAL PROCESSES WRITE IT AT ONCE, SO THE APPEND GOES THROUGH lib\append-line.ps1 (2026-09-11).
  Refusals from lib\ledger-lock.ps1 and
  meal-prep\pipeline\source-domains.ps1 are written exactly when writers contend, harvest's pool runs
  source-domains eight wide, and several sessions' run-gates share this box. Until that day the append was a
  StreamWriter, which opens sharing Read only, so a process appending at the same moment as another was
  refused and its event dropped behind a $false that every producer discards. Measured through the real
  Write-TcEvent, W processes x 200 events, overlap proven by rendezvous, 5 trials a cell
  (design\MEASURE-event-bus-concurrent-append-2026-09-11.md): 1 writer landed 1,000 of 1,000, 2 writers
  1,878 of 2,000, 4 writers 3,205 of 4,000, 8 writers 4,792 of 8,000. Every lost event returned $false;
  none returned $true. Through Add-TcLine, alternated trial by trial with the old code in a second run: 15,000 of
  15,000 over all 20 trials, while the old code lost events in 15 of its 15 multi-writer trials.
  THE COST: where a StreamWriter returned $false at once, Add-TcLine retries the OPEN for about 7.3 s when a
  handle that denies writers holds the bus, so a producer can now stall that long before it gets its $false.
  Read-TcEvents below is such a handle for the length of one read ([IO.File]::ReadAllLines shares Read only).
  The MUST FIRE for concurrent producers is in ops\audit-event-bus.ps1's self-test.

  IT IS GITIGNORED, like every other high-churn local log. The bus is evidence about this
  machine, not source, and committing it would put a write in every gate run's diff.

  SCOPE OF A CLEAN REPORT: this file makes no report. An EMPTY bus means nothing was
  written, which is either a quiet estate or a dead producer, and only
  ops\audit-event-bus.ps1 can tell those apart - it carries the floor.
#>

$script:TcEventBusPath = $null

# Add-TcLine. Loaded inside a try because a bus that cannot find its appender must still not break the
# producer that dot-sourced it: Write-TcEvent then fails its own try and returns $false.
try { . (Join-Path $(if ($PSScriptRoot) { $PSScriptRoot } else { Join-Path 'C:\Codex\ThriftyCrew' 'lib' }) 'append-line.ps1') } catch { }

function Get-TcEventBusPath {
  <# The bus for this repo. Resolved from THIS file's location, never from the caller's
     working directory: a producer invoked from a worktree or from C:\ must not silently
     start a second bus somewhere else. #>
  param([string]$Override = '')
  if ($Override) { return $Override }
  if ($env:TC_EVENT_BUS) { return $env:TC_EVENT_BUS }
  $libDir = if ($PSScriptRoot) { $PSScriptRoot } else { Join-Path 'C:\Codex\ThriftyCrew' 'lib' }
  $repo = Split-Path -Parent $libDir
  return (Join-Path $repo 'ops\out\events.jsonl')
}

function Write-TcEvent {
  <#
    .SYNOPSIS Append one event. Returns $true if it landed, $false if it could not. Never throws.
    .PARAMETER Kind     the event class, e.g. 'gate-red', 'alert-closed', 'known-wrong-added'
    .PARAMETER Producer the file that knew it happened, repo-relative
    .PARAMETER Data     flat facts. Values are written as-is; keep them small and scalar.
  #>
  param(
    [Parameter(Mandatory=$true)][string]$Kind,
    [Parameter(Mandatory=$true)][string]$Producer,
    [hashtable]$Data = @{},
    [string]$Path = ''
  )
  try {
    $p = Get-TcEventBusPath -Override $Path
    $dir = Split-Path -Parent $p
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
      $null = New-Item -ItemType Directory -Force -Path $dir -ErrorAction Stop
    }
    # EPOCH FROM [DateTimeOffset]::UtcNow, NEVER FROM `Get-Date -UFormat %s`.
    # `[CORRECTED 2026-09-10]` The first version used -UFormat %s and PowerShell 5.1
    # returns LOCAL wall-clock seconds from it, not UTC: measured against two independent
    # clocks it read 1789004941 while [DateTimeOffset] and Python's time.time() both read
    # 1789022941 - exactly 18,000 s, the CDT offset. Every Python writer in the recall
    # store stamps real UTC epoch, so a reader comparing the two was 5 hours wrong in a
    # direction that makes fresh evidence look stale. `iso` is UTC with a Z for the same
    # reason: an offset-less local time cannot be joined to anything.
    $row = [ordered]@{
      t        = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
      iso      = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
      kind     = $Kind
      producer = $Producer
    }
    foreach ($k in @($Data.Keys)) {
      # The four reserved keys are never overwritten by a producer: an event that could
      # rewrite its own timestamp or claim another producer's name is not evidence.
      if ($row.Contains($k)) { continue }
      $row[$k] = $Data[$k]
    }
    $json = ($row | ConvertTo-Json -Depth 4 -Compress)
    # ONE LINE, UTF-8 with NO BOM, CRLF - the same bytes the StreamWriter wrote - appended as ONE write through an
    # append-only open that shares ReadWrite, so a concurrent producer's append can neither refuse this one nor be
    # refused by it. NOT a StreamWriter: that opens sharing Read only, and a second process appending at the same
    # moment was refused and its event silently dropped (the header has the counts). Add-TcLine retries only the
    # OPEN, and throws when a writer-denying handle outlasts its budget; the catch below turns that into $false.
    # -Compress escapes any line break inside a value, so one event is always one line.
    $null = Add-TcLine -Path $p -Text $json
    return $true
  } catch {
    return $false
  }
}

function Read-TcEvents {
  <# Every event, newest last. A torn line is SKIPPED and counted by the caller rather than
     killing the read: a log being appended to while it is read is the normal case. #>
  param([string]$Path = '', [int]$SinceEpoch = 0)
  $out = @()
  try {
    $p = Get-TcEventBusPath -Override $Path
    if (-not (Test-Path -LiteralPath $p)) { return ,$out }
    foreach ($line in [IO.File]::ReadAllLines($p)) {
      if (-not "$line".Trim()) { continue }
      try {
        $row = $line | ConvertFrom-Json
        if ($row -and ([int]$row.t) -ge $SinceEpoch) { $out += $row }
      } catch { continue }
    }
  } catch { }
  return ,$out
}
