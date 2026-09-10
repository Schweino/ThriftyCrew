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

  IT IS GITIGNORED, like every other high-churn local log. The bus is evidence about this
  machine, not source, and committing it would put a write in every gate run's diff.

  SCOPE OF A CLEAN REPORT: this file makes no report. An EMPTY bus means nothing was
  written, which is either a quiet estate or a dead producer, and only
  ops\audit-event-bus.ps1 can tell those apart - it carries the floor.
#>

$script:TcEventBusPath = $null

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
    # UTF-8 with NO BOM, and one line. Add-Content under $ErrorActionPreference='Stop'
    # would throw on a locked file, which is exactly what must not happen here.
    $sw = New-Object IO.StreamWriter($p, $true, (New-Object Text.UTF8Encoding($false)))
    try { $sw.WriteLine($json) } finally { $sw.Dispose() }
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
