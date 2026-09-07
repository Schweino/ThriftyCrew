<#
  run-log-lib.ps1 - the run-record rule for the THREE TC Grocery tasks. NOT for all five.

  READ THIS FIRST (corrected 2026-09-06, backlog E29). This header used to open "ONE
  copy of the 'write this run down' rule" and that was false. Five scheduled tasks run
  -WindowStyle Hidden and they use THREE different hand-rolled conventions:

    TC Grocery ad 07:00 / daily 08:00 / watchdog 09:30 -> THIS FILE, dot-sourced by
                                                          capture-run.ps1 and
                                                          capture-watchdog.ps1
    nightly matching chain                             -> its own
                                                          grocery\out\logs\graph-nightly-status.json
    TC Recipe Harvest Crawl                            -> ad-hoc Out-File -Append at
                                                          four sites in harvest-crawl.ps1

  A file that claims to be the single copy of a rule and is not is worse than no claim,
  because the next person to add a hidden task reads that line, sees a library, and has
  no way to know two other tasks route around it. NOTHING IS UNLOGGED - this is an
  ergonomics defect, not a blind task - but the two rules below are ENFORCED for three
  tasks and merely hoped for in the other two.

  ops\audit-run-log-claims.ps1 keeps this header honest. If you bring the graph or
  harvest wrapper onto this library, update the table above and that audit will agree.

  WHY THIS EXISTS. The three TC Grocery tasks run with -WindowStyle Hidden and no
  redirect, so every line they printed went to a console nobody ever saw. On
  2026-08-22 all three showed LastTaskResult=1 for the previous day and there was
  no way at all to learn WHY: the exit code was the entire diagnostic surface.
  A scheduled job that can only say "1" is a job you cannot operate.

  TWO RULES THIS FILE OBEYS, both learned the hard way in this estate:

  1. LOGGING MUST NEVER KILL THE RUN. These scripts set $ErrorActionPreference =
     'Stop', so an unguarded Add-Content/Start-Transcript against a locked or
     missing file terminates the whole pipeline and reads as a hang. Every call
     here is wrapped and swallows its own failure. A run with no log is a
     degraded run; a run KILLED BY its logger is a lost one.
  2. ONE COPY FOR THE CALLERS IT HAS. Both capture callers dot-source this rather
     than inlining it, because an inline duplicate in each script is how a fix ships
     to one caller and silently misses the other. That argument applies just as well
     to the two conventions listed above, which is the open half of E29.

  Logs land in out\logs\ , which *.log already gitignores, and rotate by age so
  the folder cannot grow without bound.
#>

function Start-RunLog {
  <#
    Begins a transcript for this run. Returns the log path, or $null if logging
    could not start - callers must treat $null as "carry on without a log",
    never as an error.
  #>
  param(
    [Parameter(Mandatory)][string]$Name,   # e.g. 'capture-run-ad'
    [Parameter(Mandatory)][string]$OutDir,
    [string]$Today = '',
    [int]$KeepDays = 30
  )
  try {
    # NAMED BY THE WALL CLOCK, NEVER BY $Today. A replay ("-Today 2026-08-21") is a
    # thing that happened TODAY, and filing its transcript under the pinned date
    # appends a replay into the historical record of a day it did not run on - the
    # next reader cannot tell the real 08-21 run from an 08-22 rehearsal of it.
    # Same reasoning as Step-CaptureCursor's replay guard: "is this a replay?" is
    # exactly the question a pinned date cannot answer. $Today is kept in the
    # signature (callers pass it) but deliberately not used for the filename.
    $stamp = (Get-Date).ToString('yyyy-MM-dd')
    $dir = Join-Path $OutDir 'logs'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    # Age-out old logs first, so a failure to rotate never blocks today's log.
    try {
      $cut = (Get-Date).AddDays(-$KeepDays)
      Get-ChildItem -Path $dir -Filter '*.log' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cut } |
        Remove-Item -Force -ErrorAction SilentlyContinue
    } catch { }

    $path = Join-Path $dir ("{0}-{1}.log" -f $Name, $stamp)

    # A transcript already running (nested invocation) would throw; stop it first.
    try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch { }

    Start-Transcript -Path $path -Append -Force -ErrorAction Stop | Out-Null
    Write-Output ("--- run-log: {0} | {1} | pid {2} ---" -f $Name, (Get-Date).ToString('s'), $PID)
    return $path
  } catch {
    Write-Warning ("run-log: could not start logging ({0}) - continuing without a log." -f $_.Exception.Message)
    return $null
  }
}

function Stop-RunLog {
  <#
    Ends the transcript and stamps the run's exit code as the LAST line, so
    "what happened on the 21st" is answerable by reading one line from the tail
    rather than by re-deriving it from the task scheduler.
  #>
  param([int]$ExitCode = 0, [string]$Path = '')
  try {
    Write-Output ("--- run-log: finished {0} rc={1} ---" -f (Get-Date).ToString('s'), $ExitCode)
    Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
  } catch { }
}
