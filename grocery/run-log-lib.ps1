<#
  run-log-lib.ps1 - the run-record rule for ALL FIVE hidden scheduled tasks.

  READ THIS FIRST (2026-09-06, backlog E29). This header used to open "ONE copy of the
  'write this run down' rule" and that was false when it was written: five tasks run
  -WindowStyle Hidden and only three used this file. All five now do:

    TC Grocery ad 07:00 / daily 08:00 / watchdog 10:30 -> capture-run.ps1,
                                                          capture-watchdog.ps1
    TC Graph Nightly Matching                          -> graph\pipeline\nightly.ps1
    TC Recipe Harvest Crawl                            -> meal-prep\pipeline\harvest-crawl.ps1

  The last two KEEP their own artefacts - graph-nightly-status.json and crawl-<date>.log
  - because those persist SUBPROCESS output captured into a variable, which never reaches
  a transcript. What they gained is the run record itself: a transcript, and the exit code
  stamped as the LAST line. Neither had one. Nightly's status file is written at the very
  end, so a run that died before it left nothing at all, which is indistinguishable from a
  run that never started.

  ops\audit-run-log-claims.ps1 keeps this true. It reads the committed task definitions in
  ops\scheduled-tasks\*.xml and fails when a hidden task's target script does not
  dot-source this file. That gate was impossible before those definitions were committed:
  three of the five registrations lived only in the Windows registry, where no static
  detector could reach them.

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
    # WRITE-HOST, NOT WRITE-OUTPUT (2026-09-10). Write-Output put this banner into the PIPELINE, so every
    # caller's `$runLog = Start-RunLog ...` captured the banner AND the path as a two-element array: no
    # transcript ever showed its start line (0 in brain-digest's log of 2026-09-10), and capture-run.ps1
    # wrote `log = [string]$runLog` into its status file as the banner glued to the path. The host stream
    # still lands in the transcript, and the function now returns the path alone.
    Write-Host ("--- run-log: {0} | {1} | pid {2} ---" -f $Name, (Get-Date).ToString('s'), $PID)
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
