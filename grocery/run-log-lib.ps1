<#
  run-log-lib.ps1 - ONE copy of the "write this run down" rule.

  WHY THIS EXISTS. The three TC Windows tasks run with -WindowStyle Hidden and no
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
  2. ONE COPY, NOT TWO. Both callers dot-source this. An inline duplicate in each
     script is how a fix ships to one caller and silently misses the other.

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
